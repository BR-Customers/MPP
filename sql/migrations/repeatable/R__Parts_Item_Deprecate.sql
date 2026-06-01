-- =============================================
-- Procedure:   Parts.Item_Deprecate
-- Author:      Blue Ridge Automation
-- Created:     2026-04-14
-- Version:     2.1
--
-- Description:
--   Soft-deletes an active Item by setting DeprecatedAt. Rejects if
--   the Item is referenced by any active dependent:
--     - Parts.Bom              (either as ParentItem or BomLine child)
--     - Parts.RouteTemplate    (ItemId)
--     - Parts.ItemLocation     (ItemId)
--     - Parts.ContainerConfig  (ItemId)
--
--   Each dependent check is guarded by sys.tables so the proc compiles
--   cleanly in earlier phases where those tables may not yet exist.
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
--   Tables: Parts.Item; optionally Parts.Bom, Parts.BomLine,
--           Parts.RouteTemplate, Parts.ItemLocation, Parts.ContainerConfig
--           (existence-guarded)
--   Procs:  Audit.Audit_LogConfigChange, Audit.Audit_LogFailure
--
-- Change Log:
--   2026-04-14 - 1.0 - Initial version (OUTPUT params)
--   2026-04-15 - 2.0 - SELECT result for Named Query compatibility
--   2026-05-29 - 2.1 - Audit-readability convention (Slice 5 Item core):
--                       SUBJECT . Deprecated narrative Description +
--                       resolved-FK OldValue JSON (ItemType, Uom), NewValue NULL.
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

        -- Dependency checks (each guarded — tables may not exist yet)
        DECLARE @DepCount INT = 0;

        -- Parts.Bom — parent role
        IF EXISTS (SELECT 1 FROM sys.tables t INNER JOIN sys.schemas s ON s.schema_id = t.schema_id
                   WHERE s.name = N'Parts' AND t.name = N'Bom')
        BEGIN
            EXEC sp_executesql
                N'SELECT @cnt = COUNT(*) FROM Parts.Bom WHERE ParentItemId = @id AND DeprecatedAt IS NULL;',
                N'@id BIGINT, @cnt INT OUTPUT',
                @id = @Id, @cnt = @DepCount OUTPUT;
            IF @DepCount > 0
            BEGIN
                SET @Message = N'Cannot deprecate: active BOMs reference this Item as parent.';
                EXEC Audit.Audit_LogFailure
                    @AppUserId = @AppUserId, @LogEntityTypeCode = N'Item',
                    @EntityId = @Id, @LogEventTypeCode = N'Deprecated',
                    @FailureReason = @Message, @ProcedureName = @ProcName,
                    @AttemptedParameters = @Params;
                SELECT @Status AS Status, @Message AS Message;
                RETURN;
            END
        END

        -- Parts.BomLine — child role
        IF EXISTS (SELECT 1 FROM sys.tables t INNER JOIN sys.schemas s ON s.schema_id = t.schema_id
                   WHERE s.name = N'Parts' AND t.name = N'BomLine')
        BEGIN
            EXEC sp_executesql
                N'SELECT @cnt = COUNT(*) FROM Parts.BomLine WHERE ChildItemId = @id;',
                N'@id BIGINT, @cnt INT OUTPUT',
                @id = @Id, @cnt = @DepCount OUTPUT;
            IF @DepCount > 0
            BEGIN
                SET @Message = N'Cannot deprecate: BOM lines reference this Item as a child component.';
                EXEC Audit.Audit_LogFailure
                    @AppUserId = @AppUserId, @LogEntityTypeCode = N'Item',
                    @EntityId = @Id, @LogEventTypeCode = N'Deprecated',
                    @FailureReason = @Message, @ProcedureName = @ProcName,
                    @AttemptedParameters = @Params;
                SELECT @Status AS Status, @Message AS Message;
                RETURN;
            END
        END

        -- Parts.RouteTemplate
        IF EXISTS (SELECT 1 FROM sys.tables t INNER JOIN sys.schemas s ON s.schema_id = t.schema_id
                   WHERE s.name = N'Parts' AND t.name = N'RouteTemplate')
        BEGIN
            EXEC sp_executesql
                N'SELECT @cnt = COUNT(*) FROM Parts.RouteTemplate WHERE ItemId = @id AND DeprecatedAt IS NULL;',
                N'@id BIGINT, @cnt INT OUTPUT',
                @id = @Id, @cnt = @DepCount OUTPUT;
            IF @DepCount > 0
            BEGIN
                SET @Message = N'Cannot deprecate: active RouteTemplates reference this Item.';
                EXEC Audit.Audit_LogFailure
                    @AppUserId = @AppUserId, @LogEntityTypeCode = N'Item',
                    @EntityId = @Id, @LogEventTypeCode = N'Deprecated',
                    @FailureReason = @Message, @ProcedureName = @ProcName,
                    @AttemptedParameters = @Params;
                SELECT @Status AS Status, @Message AS Message;
                RETURN;
            END
        END

        -- Parts.ItemLocation
        IF EXISTS (SELECT 1 FROM sys.tables t INNER JOIN sys.schemas s ON s.schema_id = t.schema_id
                   WHERE s.name = N'Parts' AND t.name = N'ItemLocation')
        BEGIN
            EXEC sp_executesql
                N'SELECT @cnt = COUNT(*) FROM Parts.ItemLocation WHERE ItemId = @id AND DeprecatedAt IS NULL;',
                N'@id BIGINT, @cnt INT OUTPUT',
                @id = @Id, @cnt = @DepCount OUTPUT;
            IF @DepCount > 0
            BEGIN
                SET @Message = N'Cannot deprecate: active ItemLocation eligibility entries reference this Item.';
                EXEC Audit.Audit_LogFailure
                    @AppUserId = @AppUserId, @LogEntityTypeCode = N'Item',
                    @EntityId = @Id, @LogEventTypeCode = N'Deprecated',
                    @FailureReason = @Message, @ProcedureName = @ProcName,
                    @AttemptedParameters = @Params;
                SELECT @Status AS Status, @Message AS Message;
                RETURN;
            END
        END

        -- Parts.ContainerConfig
        IF EXISTS (SELECT 1 FROM sys.tables t INNER JOIN sys.schemas s ON s.schema_id = t.schema_id
                   WHERE s.name = N'Parts' AND t.name = N'ContainerConfig')
        BEGIN
            EXEC sp_executesql
                N'SELECT @cnt = COUNT(*) FROM Parts.ContainerConfig WHERE ItemId = @id AND DeprecatedAt IS NULL;',
                N'@id BIGINT, @cnt INT OUTPUT',
                @id = @Id, @cnt = @DepCount OUTPUT;
            IF @DepCount > 0
            BEGIN
                SET @Message = N'Cannot deprecate: an active ContainerConfig references this Item.';
                EXEC Audit.Audit_LogFailure
                    @AppUserId = @AppUserId, @LogEntityTypeCode = N'Item',
                    @EntityId = @Id, @LogEventTypeCode = N'Deprecated',
                    @FailureReason = @Message, @ProcedureName = @ProcName,
                    @AttemptedParameters = @Params;
                SELECT @Status AS Status, @Message AS Message;
                RETURN;
            END
        END

        -- ===== Audit narrative + resolved JSON (built from PRE-mutation state) =====

        -- Subject: <PartNumber> — <Description>
        DECLARE @PartNumber NVARCHAR(50);
        DECLARE @ItemDesc   NVARCHAR(500);

        SELECT @PartNumber = PartNumber, @ItemDesc = Description
        FROM Parts.Item WHERE Id = @Id;

        DECLARE @ActivityRaw NVARCHAR(MAX) =
            @PartNumber
            + CASE WHEN @ItemDesc IS NOT NULL
                   THEN N' ' + NCHAR(8212) + N' ' + @ItemDesc ELSE N'' END
            + N' ' + Audit.ufn_MidDot() + N' Deprecated';

        DECLARE @Activity NVARCHAR(500) = Audit.ufn_TruncateActivity(@ActivityRaw);

        -- Resolved-FK OldValue snapshot (pre-deprecate state)
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

        BEGIN TRANSACTION;

        UPDATE Parts.Item
        SET DeprecatedAt    = SYSUTCDATETIME(),
            UpdatedAt       = SYSUTCDATETIME(),
            UpdatedByUserId = @AppUserId
        WHERE Id = @Id;

        EXEC Audit.Audit_LogConfigChange
            @AppUserId         = @AppUserId,
            @LogEntityTypeCode = N'Item',
            @EntityId          = @Id,
            @LogEventTypeCode  = N'Deprecated',
            @LogSeverityCode   = N'Info',
            @Description       = @Activity,
            @OldValue          = @OldValueResolved,
            @NewValue          = NULL;

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
