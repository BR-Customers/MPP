-- =============================================
-- Procedure:   Parts.Item_Deprecate
-- Author:      Blue Ridge Automation
-- Created:     2026-04-14
-- Version:     3.0
--
-- Description:
--   Soft-deletes an active Item by setting DeprecatedAt, and CASCADE-deprecates
--   the config artifacts owned by the part:
--     - Parts.RouteTemplate    (ItemId)
--     - Parts.Bom              (ParentItemId — the part's own BOMs)
--     - Parts.ItemLocation     (ItemId — eligibility rows)
--     - Parts.ContainerConfig  (ItemId)
--
--   The ONLY hard stop is live inventory: the proc rejects iff a non-terminal
--   LOT of the part exists (LotStatusCode NOT IN ('Closed','Scrap')). Config
--   artifacts are definitions and travel with the part; a live LOT is physical
--   WIP on the floor (Jacques 2026-07-07 — refined rule superseding the old
--   reject-on-any-dependent guards).
--
--   NOT cascaded / NOT blocked: the part used as a BomLine CHILD in ANOTHER
--   part's BOM. Those foreign BOMs are left untouched — they simply reference a
--   now-deprecated child; deprecating them would silently retire other parts'
--   BOMs (almost always wrong). This case no longer blocks either.
--
--   Each cascaded row is stamped DeprecatedAt and gets its own audit row
--   (traceable in that entity's history); the Item's own 'Deprecated' audit row
--   carries the cascade counts in NewValue.
--
--   Object references are existence-guarded (sys.tables) so the proc runs
--   cleanly in earlier phases where the dependent tables may not exist; SQL
--   Server deferred name resolution keeps the proc creatable regardless.
--
-- Parameters (input):
--   @Id BIGINT        - Required.
--   @AppUserId BIGINT - Required for audit.
--
-- Result set:
--   Single row with Status (BIT), Message (NVARCHAR).
--   Status=1 on success, 0 on failure.
--
-- Dependencies:
--   Tables: Parts.Item; optionally Parts.RouteTemplate, Parts.Bom,
--           Parts.ItemLocation, Parts.ContainerConfig, Lots.Lot,
--           Lots.LotStatusCode (all existence-guarded)
--   Procs:  Audit.Audit_LogConfigChange, Audit.Audit_LogFailure
--   Funcs:  Audit.ufn_MidDot, Audit.ufn_TruncateActivity
--
-- Change Log:
--   2026-04-14 - 1.0 - Initial version (OUTPUT params)
--   2026-04-15 - 2.0 - SELECT result for Named Query compatibility
--   2026-05-29 - 2.1 - Audit-readability convention (Slice 5 Item core):
--                       SUBJECT . Deprecated narrative Description +
--                       resolved-FK OldValue JSON (ItemType, Uom), NewValue NULL.
--   2026-07-07 - 3.0 - Cascade-deprecate owned config dependents (RouteTemplate,
--                       Bom-as-parent, ItemLocation, ContainerConfig); replace all
--                       dependent-reject guards with a single active-LOT hard stop.
-- =============================================
CREATE OR ALTER PROCEDURE Parts.Item_Deprecate
    @Id        BIGINT,
    @AppUserId BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Status  BIT           = 0;
    DECLARE @Message NVARCHAR(500) = N'Unknown error';

    DECLARE @ProcName NVARCHAR(200) = N'Parts.Item_Deprecate';
    DECLARE @Params   NVARCHAR(MAX) =
        (SELECT @Id AS Id FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

    BEGIN TRY
        -- Parameter validation
        IF @Id IS NULL OR @AppUserId IS NULL
        BEGIN
            SET @Message = N'Required parameter missing.';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'Item',
                @EntityId = @Id, @LogEventTypeCode = N'Deprecated',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message;
            RETURN;
        END

        -- Business rule: must exist and be active
        IF NOT EXISTS (SELECT 1 FROM Parts.Item WHERE Id = @Id AND DeprecatedAt IS NULL)
        BEGIN
            SET @Message = N'Item not found or already deprecated.';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'Item',
                @EntityId = @Id, @LogEventTypeCode = N'Deprecated',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message;
            RETURN;
        END

        -- ===== The one hard stop: a live (non-terminal) LOT of this part =====
        -- Terminal statuses ('Closed','Scrap') are history and do not block.
        -- Guarded — Lots.Lot / LotStatusCode may not exist in earlier phases.
        IF EXISTS (SELECT 1 FROM sys.tables t INNER JOIN sys.schemas s ON s.schema_id = t.schema_id
                   WHERE s.name = N'Lots' AND t.name = N'Lot')
           AND EXISTS (SELECT 1 FROM sys.tables t INNER JOIN sys.schemas s ON s.schema_id = t.schema_id
                   WHERE s.name = N'Lots' AND t.name = N'LotStatusCode')
        BEGIN
            DECLARE @ActiveLots INT = 0;
            EXEC sp_executesql
                N'SELECT @cnt = COUNT(*)
                  FROM Lots.Lot l
                  INNER JOIN Lots.LotStatusCode sc ON sc.Id = l.LotStatusId
                  WHERE l.ItemId = @id AND sc.Code NOT IN (N''Closed'', N''Scrap'');',
                N'@id BIGINT, @cnt INT OUTPUT',
                @id = @Id, @cnt = @ActiveLots OUTPUT;
            IF @ActiveLots > 0
            BEGIN
                SET @Message = N'Cannot deprecate: active LOTs of this part still exist.';
                EXEC Audit.Audit_LogFailure
                    @AppUserId = @AppUserId, @LogEntityTypeCode = N'Item',
                    @EntityId = @Id, @LogEventTypeCode = N'Deprecated',
                    @FailureReason = @Message, @ProcedureName = @ProcName,
                    @AttemptedParameters = @Params;
                SELECT @Status AS Status, @Message AS Message;
                RETURN;
            END
        END

        -- ===== Pre-mutation audit snapshot (built before any UPDATE) =====
        DECLARE @PartNumber NVARCHAR(50);
        DECLARE @ItemDesc   NVARCHAR(500);

        SELECT @PartNumber = PartNumber, @ItemDesc = Description
        FROM Parts.Item WHERE Id = @Id;

        DECLARE @OldValueResolved NVARCHAR(MAX) = (
            SELECT
                i.Id,
                i.PartNumber,
                i.Description,
                JSON_QUERY((SELECT it.Id, it.Name
                            FROM Parts.ItemType it WHERE it.Id = i.ItemTypeId
                            FOR JSON PATH, WITHOUT_ARRAY_WRAPPER))     AS ItemType,
                i.MacolaPartNumber,
                i.DefaultSubLotQty,
                i.MaxLotSize,
                JSON_QUERY((SELECT u.Id, u.Code, u.Name
                            FROM Parts.Uom u WHERE u.Id = i.UomId
                            FOR JSON PATH, WITHOUT_ARRAY_WRAPPER))     AS Uom,
                i.UnitWeight,
                i.CountryOfOrigin,
                i.MaxParts
            FROM Parts.Item i
            WHERE i.Id = @Id
            FOR JSON PATH, WITHOUT_ARRAY_WRAPPER
        );

        -- Cascade capture (each holds the Ids actually deprecated this call).
        DECLARE @RouteIds TABLE (Id BIGINT);
        DECLARE @BomIds   TABLE (Id BIGINT);
        DECLARE @EligIds  TABLE (Id BIGINT);
        DECLARE @CfgIds   TABLE (Id BIGINT);

        BEGIN TRANSACTION;

        -- ---- Cascade-deprecate owned config dependents ----
        IF EXISTS (SELECT 1 FROM sys.tables t INNER JOIN sys.schemas s ON s.schema_id = t.schema_id
                   WHERE s.name = N'Parts' AND t.name = N'RouteTemplate')
            UPDATE Parts.RouteTemplate
            SET DeprecatedAt = SYSUTCDATETIME()
            OUTPUT inserted.Id INTO @RouteIds
            WHERE ItemId = @Id AND DeprecatedAt IS NULL;

        IF EXISTS (SELECT 1 FROM sys.tables t INNER JOIN sys.schemas s ON s.schema_id = t.schema_id
                   WHERE s.name = N'Parts' AND t.name = N'Bom')
            UPDATE Parts.Bom
            SET DeprecatedAt = SYSUTCDATETIME()
            OUTPUT inserted.Id INTO @BomIds
            WHERE ParentItemId = @Id AND DeprecatedAt IS NULL;

        IF EXISTS (SELECT 1 FROM sys.tables t INNER JOIN sys.schemas s ON s.schema_id = t.schema_id
                   WHERE s.name = N'Parts' AND t.name = N'ItemLocation')
            UPDATE Parts.ItemLocation
            SET DeprecatedAt = SYSUTCDATETIME()
            OUTPUT inserted.Id INTO @EligIds
            WHERE ItemId = @Id AND DeprecatedAt IS NULL;

        IF EXISTS (SELECT 1 FROM sys.tables t INNER JOIN sys.schemas s ON s.schema_id = t.schema_id
                   WHERE s.name = N'Parts' AND t.name = N'ContainerConfig')
            UPDATE Parts.ContainerConfig
            SET DeprecatedAt = SYSUTCDATETIME(),
                UpdatedAt    = SYSUTCDATETIME()
            OUTPUT inserted.Id INTO @CfgIds
            WHERE ItemId = @Id AND DeprecatedAt IS NULL;

        -- ---- Deprecate the Item itself ----
        UPDATE Parts.Item
        SET DeprecatedAt    = SYSUTCDATETIME(),
            UpdatedAt       = SYSUTCDATETIME(),
            UpdatedByUserId = @AppUserId
        WHERE Id = @Id;

        -- ---- Cascade counts + Item audit narrative ----
        DECLARE @nRoutes INT = (SELECT COUNT(*) FROM @RouteIds);
        DECLARE @nBoms   INT = (SELECT COUNT(*) FROM @BomIds);
        DECLARE @nElig   INT = (SELECT COUNT(*) FROM @EligIds);
        DECLARE @nCfg    INT = (SELECT COUNT(*) FROM @CfgIds);
        DECLARE @nCascade INT = @nRoutes + @nBoms + @nElig + @nCfg;

        DECLARE @ActivityRaw NVARCHAR(MAX) =
            @PartNumber
            + CASE WHEN @ItemDesc IS NOT NULL
                   THEN N' ' + NCHAR(8212) + N' ' + @ItemDesc ELSE N'' END
            + N' ' + Audit.ufn_MidDot() + N' Deprecated'
            + CASE WHEN @nCascade > 0
                   THEN N' (cascade: ' + CAST(@nRoutes AS NVARCHAR(10)) + N' routes, '
                        + CAST(@nBoms AS NVARCHAR(10)) + N' BOMs, '
                        + CAST(@nElig AS NVARCHAR(10)) + N' eligibility, '
                        + CAST(@nCfg AS NVARCHAR(10)) + N' configs)'
                   ELSE N'' END;

        DECLARE @Activity NVARCHAR(500) = Audit.ufn_TruncateActivity(@ActivityRaw);

        DECLARE @NewValueCascade NVARCHAR(MAX) = CASE WHEN @nCascade > 0 THEN (
            SELECT @nRoutes AS RoutesDeprecated,
                   @nBoms   AS BomsDeprecated,
                   @nElig   AS EligibilityDeprecated,
                   @nCfg    AS ContainerConfigsDeprecated
            FOR JSON PATH, WITHOUT_ARRAY_WRAPPER
        ) ELSE NULL END;

        EXEC Audit.Audit_LogConfigChange
            @AppUserId         = @AppUserId,
            @LogEntityTypeCode = N'Item',
            @EntityId          = @Id,
            @LogEventTypeCode  = N'Deprecated',
            @LogSeverityCode   = N'Info',
            @Description        = @Activity,
            @OldValue          = @OldValueResolved,
            @NewValue          = @NewValueCascade;

        -- ---- Per-dependent cascade audit rows (each entity's own history) ----
        DECLARE @CascadeDesc NVARCHAR(500) =
            Audit.ufn_TruncateActivity(
                N'Cascade-deprecated with parent Item ' + @PartNumber
                + N' ' + Audit.ufn_MidDot() + N' Deprecated');
        DECLARE @cid BIGINT;

        WHILE EXISTS (SELECT 1 FROM @RouteIds)
        BEGIN
            SELECT TOP 1 @cid = Id FROM @RouteIds;
            EXEC Audit.Audit_LogConfigChange
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'Route',
                @EntityId = @cid, @LogEventTypeCode = N'Deprecated',
                @LogSeverityCode = N'Info', @Description = @CascadeDesc,
                @OldValue = NULL, @NewValue = NULL;
            DELETE FROM @RouteIds WHERE Id = @cid;
        END

        WHILE EXISTS (SELECT 1 FROM @BomIds)
        BEGIN
            SELECT TOP 1 @cid = Id FROM @BomIds;
            EXEC Audit.Audit_LogConfigChange
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'Bom',
                @EntityId = @cid, @LogEventTypeCode = N'Deprecated',
                @LogSeverityCode = N'Info', @Description = @CascadeDesc,
                @OldValue = NULL, @NewValue = NULL;
            DELETE FROM @BomIds WHERE Id = @cid;
        END

        WHILE EXISTS (SELECT 1 FROM @EligIds)
        BEGIN
            SELECT TOP 1 @cid = Id FROM @EligIds;
            EXEC Audit.Audit_LogConfigChange
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'ItemLocation',
                @EntityId = @cid, @LogEventTypeCode = N'Deprecated',
                @LogSeverityCode = N'Info', @Description = @CascadeDesc,
                @OldValue = NULL, @NewValue = NULL;
            DELETE FROM @EligIds WHERE Id = @cid;
        END

        WHILE EXISTS (SELECT 1 FROM @CfgIds)
        BEGIN
            SELECT TOP 1 @cid = Id FROM @CfgIds;
            EXEC Audit.Audit_LogConfigChange
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'ContainerConfig',
                @EntityId = @cid, @LogEventTypeCode = N'Deprecated',
                @LogSeverityCode = N'Info', @Description = @CascadeDesc,
                @OldValue = NULL, @NewValue = NULL;
            DELETE FROM @CfgIds WHERE Id = @cid;
        END

        COMMIT TRANSACTION;

        SET @Status  = 1;
        SET @Message = N'Item deprecated successfully.';
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
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'Item',
                @EntityId = @Id, @LogEventTypeCode = N'Deprecated',
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
