-- =============================================
-- Procedure:   Tools.ToolAssignment_Release
-- Author:      Blue Ridge Automation
-- Created:     2026-04-22
-- Version:     1.1
-- Changelog:   1.1 (2026-09-14) OPEN-BASKET GUARD. Rejects while the die
--              still carries an Open LOT. Three subsystems are written
--              against the sentence "a changeover always closes the lots" --
--              Lots.DieCastLot_Release's shot-delta recovery,
--              Workorder.ufn_CavityShotWatermark and ufn_DieShotWatermark's
--              per-press scoping -- and NOTHING enforced it. The invariant
--              survived only because the sole way to release a mount was a
--              Config Tool screen no floor operator ever opens; the Die Mount
--              popup puts a Release button at the press and makes it
--              reachable. Releasing with baskets open strands them (they
--              vanish from the Die Cast screen the instant activeTool.ToolId
--              goes NULL, and that screen is the only path to releasing one),
--              lets them reappear on the next press credited from the wrong
--              counter, and silently under-counts the die's life.
--
--   Description:
--   Releases the currently-active assignment for a Tool. Sets
--   ReleasedAt and ReleasedByUserId on the single active row (filtered
--   UNIQUE guarantees there's at most one). Elevated action
--   (FDS-04-007) -- caller passes the authenticating supervisor's AppUserId.
--   Rejects if the Tool has no active assignment, or if it still holds an
--   open basket.
--
--   THE GUARD IS CAVITY-SCOPED, AND THAT IS LOAD-BEARING. A hard block lets a
--   data condition stop a physical changeover, which is only acceptable
--   because the operator can always clear it without a supervisor: Release a
--   basket that holds pieces, Void an empty one, both on the Die Cast screen
--   they are already standing at. That promise holds ONLY if the guard counts
--   exactly what Lots.Lot_GetOpenByTool shows -- and that proc is
--   cavity-driven (FROM Tools.ToolCavity ... WHERE tc.DeprecatedAt IS NULL,
--   open LOT LEFT JOINed on ToolCavityId). Lots.Lot.ToolCavityId is nullable
--   and Tools.ToolCavity_Deprecate could, before its v1.1, deprecate a cavity
--   holding an open basket. A naive die-wide EXISTS would therefore count
--   baskets the operator cannot see: the screen says three, lists two, and the
--   die never comes off. Hence the ToolCavity join here.
--
--   GOVERNING RULE: whatever the guard counts, the screen must show. This
--   binds the Lot_GetOpenByTool press-filter follow-up too -- narrowing that
--   proc without narrowing this predicate re-opens the same mismatch from the
--   other side. Change both or neither.
--
--   Pre-transaction, like every other rejection here: this proc returns a
--   status row and is captured via INSERT-EXEC by its tests, and a ROLLBACK
--   under INSERT-EXEC throws Msg 3915.
--
--   Spec: docs/superpowers/specs/
--         2026-09-14-plant-floor-die-mount-popup-design.md (5.4, 5.4.1)
-- =============================================
CREATE OR ALTER PROCEDURE Tools.ToolAssignment_Release
    @ToolId    BIGINT,
    @AppUserId BIGINT,
    @Notes     NVARCHAR(500) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Status  BIT           = 0;
    DECLARE @Message NVARCHAR(500) = N'Unknown error';

    DECLARE @ProcName NVARCHAR(200) = N'Tools.ToolAssignment_Release';
    DECLARE @Params   NVARCHAR(MAX) =
        (SELECT @ToolId AS ToolId, @Notes AS Notes
         FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

    BEGIN TRY
        IF @ToolId IS NULL OR @AppUserId IS NULL
        BEGIN
            SET @Message = N'Required parameter missing.';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'ToolAssignment',
                @EntityId = @ToolId, @LogEventTypeCode = N'Updated',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message;
            RETURN;
        END

        DECLARE @AssignmentId BIGINT, @CellLocationId BIGINT;
        SELECT @AssignmentId = Id, @CellLocationId = CellLocationId
        FROM Tools.ToolAssignment
        WHERE ToolId = @ToolId AND ReleasedAt IS NULL;

        IF @AssignmentId IS NULL
        BEGIN
            SET @Message = N'No active assignment found for this Tool.';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'ToolAssignment',
                @EntityId = @ToolId, @LogEventTypeCode = N'Updated',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message;
            RETURN;
        END

        -- ---- v1.1: open-basket guard (cavity-scoped -- see header) ----
        DECLARE @OpenBaskets INT = (
            SELECT COUNT(*)
            FROM Lots.Lot l
            INNER JOIN Lots.LotStatusCode sc ON sc.Id = l.LotStatusId
            INNER JOIN Tools.ToolCavity   tc ON tc.Id = l.ToolCavityId
            WHERE l.ToolId = @ToolId
              AND sc.Code = N'Open'
              AND tc.ToolId = @ToolId
              AND tc.DeprecatedAt IS NULL);

        IF @OpenBaskets > 0
        BEGIN
            SET @Message = N'This die still has '
                         + CAST(@OpenBaskets AS NVARCHAR(10))
                         + N' open basket(s). Release or void them before unmounting the die.';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'ToolAssignment',
                @EntityId = @ToolId, @LogEventTypeCode = N'Updated',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message;
            RETURN;
        END

        DECLARE @OldValue NVARCHAR(MAX) =
            (SELECT @AssignmentId AS AssignmentId, @CellLocationId AS CellLocationId
             FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

        BEGIN TRANSACTION;

        UPDATE Tools.ToolAssignment
        SET ReleasedAt       = SYSUTCDATETIME(),
            ReleasedByUserId = @AppUserId,
            Notes            = ISNULL(@Notes, Notes)
        WHERE Id = @AssignmentId;

        EXEC Audit.Audit_LogConfigChange
            @AppUserId         = @AppUserId,
            @LogEntityTypeCode = N'ToolAssignment',
            @EntityId          = @AssignmentId,
            @LogEventTypeCode  = N'Updated',
            @LogSeverityCode   = N'Info',
            @Description       = N'Tool assignment released.',
            @OldValue          = @OldValue,
            @NewValue          = @Params;

        COMMIT TRANSACTION;

        SET @Status  = 1;
        SET @Message = N'Tool assignment released successfully.';
        SELECT @Status AS Status, @Message AS Message;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;

        DECLARE @ErrMsg   NVARCHAR(4000) = ERROR_MESSAGE();
        DECLARE @ErrSev   INT            = ERROR_SEVERITY();
        DECLARE @ErrState INT            = ERROR_STATE();

        SET @Status  = 0;
        SET @Message = N'Unexpected error: ' + LEFT(@ErrMsg, 400);

        BEGIN TRY
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'ToolAssignment',
                @EntityId = @ToolId, @LogEventTypeCode = N'Updated',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
        END TRY
        BEGIN CATCH END CATCH

        SELECT @Status AS Status, @Message AS Message;
        RAISERROR(@ErrMsg, @ErrSev, @ErrState);
    END CATCH
END;
GO
