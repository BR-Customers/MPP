-- =============================================
-- Procedure:   Parts.ItemLocation_SetMaxQuantity
-- Author:      Blue Ridge Automation
-- Created:     2026-09-17
-- Version:     1.0
--
-- Description:
--   Sets ONLY MaxQuantity on an active, consumption-point ItemLocation row.
--   This is the proc behind the shop-floor Line Inventory "Tolerances" popup
--   (spec docs/superpowers/specs/2026-09-17-line-inventory-sidebar-design.md,
--   Task R3) -- any signed-in operator can raise or lower the ceiling that
--   colours a part Critical/Low/Ok on the Line Inventory panel.
--
--   This is deliberately NOT Parts.ItemLocation_SetConsumptionMetadata:
--   that proc full-replaces MinQuantity/MaxQuantity/DefaultQuantity/
--   IsConsumptionPoint together (it is an Engineering/Config-Tool proc,
--   called with every field every time). An operator at a terminal should
--   never be able to move Min or Default as a side effect of adjusting a
--   Max from a plant-floor popup, so this proc touches MaxQuantity alone
--   and leaves every other column untouched.
--
--   MaxQuantity is also the cap Lots.Lot_Create enforces at check-in
--   (section 6b, nearest active IsConsumptionPoint row walking up from the
--   line) -- raising or lowering it here changes what a check-in will
--   accept, not just the sidebar's colour.
--
-- Parameters (input):
--   @ItemLocationId BIGINT     - Parts.ItemLocation.Id. Required.
--   @MaxQuantity    INT NULL   - New ceiling. NULL clears it. Must be > 0
--                                 when supplied, and not below MinQuantity.
--   @AppUserId      BIGINT     - User performing the action. Required for audit.
--
-- Result set:
--   Single row with Status (BIT), Message (NVARCHAR).
--   Status=1 on success (including the no-op "No change." path), 0 on failure.
--
-- Dependencies:
--   Tables: Parts.ItemLocation, Parts.Item, Location.Location
--   Procs:  Audit.Audit_LogConfigChange, Audit.Audit_LogFailure
--   Funcs:  Audit.ufn_MidDot, Audit.ufn_TruncateActivity
--
-- Change Log:
--   2026-09-17 - 1.0 - Initial version (Line Inventory Tolerances popup, Task R3)
-- =============================================
CREATE OR ALTER PROCEDURE Parts.ItemLocation_SetMaxQuantity
    @ItemLocationId BIGINT,
    @MaxQuantity    INT    = NULL,
    @AppUserId      BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Status  BIT           = 0;
    DECLARE @Message NVARCHAR(500) = N'Unknown error';

    DECLARE @ProcName NVARCHAR(200) = N'Parts.ItemLocation_SetMaxQuantity';
    DECLARE @Params   NVARCHAR(MAX) =
        (SELECT @ItemLocationId AS ItemLocationId, @MaxQuantity AS MaxQuantity
         FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

    BEGIN TRY
        -- ====================
        -- Parameter validation
        -- ====================
        IF @ItemLocationId IS NULL OR @AppUserId IS NULL
        BEGIN
            SET @Message = N'Required parameter missing.';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'ItemLocation',
                @EntityId = @ItemLocationId, @LogEventTypeCode = N'Updated',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message;
            RETURN;
        END

        -- Target must exist and be active
        IF NOT EXISTS (SELECT 1 FROM Parts.ItemLocation
                       WHERE Id = @ItemLocationId AND DeprecatedAt IS NULL)
        BEGIN
            SET @Message = N'ItemLocation not found or deprecated.';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'ItemLocation',
                @EntityId = @ItemLocationId, @LogEventTypeCode = N'Updated',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message;
            RETURN;
        END

        -- Pull the row + resolved names, needed by every remaining check and the audit trail
        DECLARE @OldMax      INT;
        DECLARE @MinQty      INT;
        DECLARE @IsConsPoint BIT;
        DECLARE @ItemId      BIGINT;
        DECLARE @LocationId  BIGINT;
        DECLARE @PartNumber  NVARCHAR(50);
        DECLARE @ItemDesc    NVARCHAR(500);
        DECLARE @LocCode     NVARCHAR(50);
        DECLARE @LocName     NVARCHAR(200);

        SELECT
            @OldMax      = il.MaxQuantity,
            @MinQty      = il.MinQuantity,
            @IsConsPoint = il.IsConsumptionPoint,
            @ItemId      = il.ItemId,
            @LocationId  = il.LocationId,
            @PartNumber  = i.PartNumber,
            @ItemDesc    = i.Description,
            @LocCode     = loc.Code,
            @LocName     = loc.Name
        FROM Parts.ItemLocation il
        INNER JOIN Parts.Item i         ON i.Id = il.ItemId
        INNER JOIN Location.Location loc ON loc.Id = il.LocationId
        WHERE il.Id = @ItemLocationId;

        -- Business rule: only a consumption point carries a meaningful Max
        IF ISNULL(@IsConsPoint, 0) = 0
        BEGIN
            SET @Message = N'This part is not a consumption point at this location.';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'ItemLocation',
                @EntityId = @ItemLocationId, @LogEventTypeCode = N'Updated',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message;
            RETURN;
        END

        -- Business rule: a supplied Max must be positive
        IF @MaxQuantity IS NOT NULL AND @MaxQuantity <= 0
        BEGIN
            SET @Message = N'Max must be greater than zero, or blank to clear it.';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'ItemLocation',
                @EntityId = @ItemLocationId, @LogEventTypeCode = N'Updated',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message;
            RETURN;
        END

        -- Business rule: Max cannot drop below the configured Min
        IF @MaxQuantity IS NOT NULL AND @MinQty IS NOT NULL AND @MaxQuantity < @MinQty
        BEGIN
            SET @Message = N'Max cannot be below the Min configured for this part here ('
                + CAST(@MinQty AS NVARCHAR(10)) + N').';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'ItemLocation',
                @EntityId = @ItemLocationId, @LogEventTypeCode = N'Updated',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message;
            RETURN;
        END

        -- No-op: nothing to change, nothing to audit
        IF ISNULL(@OldMax, -1) = ISNULL(@MaxQuantity, -1)
        BEGIN
            SET @Status  = 1;
            SET @Message = N'No change.';
            SELECT @Status AS Status, @Message AS Message;
            RETURN;
        END

        -- Resolved-FK OldValue / NewValue snapshots
        DECLARE @OldValue NVARCHAR(MAX) = (
            SELECT
                @OldMax AS MaxQuantity,
                JSON_QUERY((SELECT @ItemId AS Id, @PartNumber AS PartNumber, @ItemDesc AS Description
                            FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)) AS Item,
                JSON_QUERY((SELECT @LocationId AS Id, @LocCode AS Code, @LocName AS Name
                            FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)) AS Location
            FOR JSON PATH, WITHOUT_ARRAY_WRAPPER
        );
        DECLARE @NewValue NVARCHAR(MAX) = (
            SELECT
                @MaxQuantity AS MaxQuantity,
                JSON_QUERY((SELECT @ItemId AS Id, @PartNumber AS PartNumber, @ItemDesc AS Description
                            FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)) AS Item,
                JSON_QUERY((SELECT @LocationId AS Id, @LocCode AS Code, @LocName AS Name
                            FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)) AS Location
            FOR JSON PATH, WITHOUT_ARRAY_WRAPPER
        );

        DECLARE @Arrow NCHAR(1) = NCHAR(8594);
        DECLARE @ActivityRaw NVARCHAR(MAX) =
            @PartNumber + N' ' + Audit.ufn_MidDot() + N' Eligibility ' + Audit.ufn_MidDot()
            + N' Updated MaxQuantity ' + ISNULL(CAST(@OldMax AS NVARCHAR(10)), N'null')
            + @Arrow + ISNULL(CAST(@MaxQuantity AS NVARCHAR(10)), N'null')
            + N' @ ' + @LocCode;
        DECLARE @Activity NVARCHAR(500) = Audit.ufn_TruncateActivity(@ActivityRaw);

        -- ====================
        -- Mutation (atomic) -- touches ONLY MaxQuantity
        -- ====================
        BEGIN TRANSACTION;

        UPDATE Parts.ItemLocation
        SET MaxQuantity = @MaxQuantity
        WHERE Id = @ItemLocationId;

        EXEC Audit.Audit_LogConfigChange
            @AppUserId         = @AppUserId,
            @LogEntityTypeCode = N'ItemLocation',
            @EntityId          = @ItemLocationId,
            @LogEventTypeCode  = N'Updated',
            @LogSeverityCode   = N'Info',
            @Description       = @Activity,
            @OldValue          = @OldValue,
            @NewValue          = @NewValue;

        COMMIT TRANSACTION;

        SET @Status  = 1;
        SET @Message = N'Max updated.';
        SELECT @Status AS Status, @Message AS Message;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0
            ROLLBACK TRANSACTION;

        DECLARE @ErrMsg   NVARCHAR(4000) = ERROR_MESSAGE();
        DECLARE @ErrSev   INT            = ERROR_SEVERITY();
        DECLARE @ErrState INT            = ERROR_STATE();

        SET @Status  = 0;
        SET @Message = N'Unexpected error: ' + LEFT(@ErrMsg, 400);

        BEGIN TRY
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'ItemLocation',
                @EntityId = @ItemLocationId, @LogEventTypeCode = N'Updated',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
        END TRY
        BEGIN CATCH
        END CATCH

        SELECT @Status AS Status, @Message AS Message;
        RAISERROR(@ErrMsg, @ErrSev, @ErrState);
    END CATCH
END;
GO
