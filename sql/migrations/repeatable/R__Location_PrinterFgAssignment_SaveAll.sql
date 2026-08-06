-- ============================================================
-- Repeatable:  R__Location_PrinterFgAssignment_SaveAll.sql
-- Author:      Blue Ridge Automation
-- Modified:    2026-08-06
-- Version:     1.1
-- Description: Full-replace of a station terminal's FG<->printer assignments from
--   a desired-state JSON array [{PrinterLocationId, ItemId|null, SortOrder}]. The
--   panel always submits every card, so this deletes the station's rows and
--   re-inserts the non-null assignments in one transaction. Validate-before-
--   transaction (rejections SELECT the status row + RETURN with no open txn);
--   ROLLBACK only in CATCH. No OUTPUT params. Status row {Status, Message, NewId}.
--   Audit OldValue/NewValue are resolved-name JSON arrays (printer {Id,Code,Name},
--   item {Id,PartNumber}) per CLAUDE.md's Audit Log Description convention --
--   modeled on R__Location_LocationTypeDefinition_SaveAll's FOR JSON PATH approach.
--
-- Change Log:
--   2026-08-06 - 1.0 - Initial version
--   2026-08-06 - 1.1 - Review fixes: resolved-name audit OldValue/NewValue
--                       (was bare-ID @AssignmentsJson / NULL); dropped dead
--                       @Incoming.RowIndex column.
-- ============================================================
CREATE OR ALTER PROCEDURE Location.PrinterFgAssignment_SaveAll
    @StationTerminalLocationId BIGINT,
    @AppUserId                 BIGINT,
    @AssignmentsJson           NVARCHAR(MAX) = N'[]'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Status  BIT           = 0;
    DECLARE @Message NVARCHAR(500) = N'Unknown error';
    DECLARE @NewId   BIGINT        = NULL;
    DECLARE @OldValue NVARCHAR(MAX);
    DECLARE @NewValue NVARCHAR(MAX);

    DECLARE @Incoming TABLE (PrinterLocationId BIGINT, ItemId BIGINT NULL, SortOrder INT);
    INSERT INTO @Incoming (PrinterLocationId, ItemId, SortOrder)
    SELECT JSON_VALUE(value, '$.PrinterLocationId'),
           JSON_VALUE(value, '$.ItemId'),
           ISNULL(TRY_CAST(JSON_VALUE(value, '$.SortOrder') AS INT), 1)
    FROM OPENJSON(ISNULL(@AssignmentsJson, N'[]'));

    -- Validation 1: every PrinterLocationId is an active child Printer of the station.
    IF EXISTS (
        SELECT 1 FROM @Incoming inc
        WHERE NOT EXISTS (
            SELECT 1 FROM Location.Location p
            WHERE p.Id = inc.PrinterLocationId
              AND p.ParentLocationId = @StationTerminalLocationId
              AND p.LocationTypeDefinitionId = 16
              AND p.DeprecatedAt IS NULL))
    BEGIN
        SET @Message = N'One or more printers are not child printers of this station.';
        SELECT @Status AS Status, @Message AS Message, @NewId AS NewId; RETURN;
    END

    -- Validation 2: every non-null ItemId is an active FinishedGood.
    IF EXISTS (
        SELECT 1 FROM @Incoming inc
        WHERE inc.ItemId IS NOT NULL
          AND NOT EXISTS (
            SELECT 1 FROM Parts.Item i
            JOIN Parts.ItemType it ON it.Id = i.ItemTypeId AND it.Code = N'FinishedGood'
            WHERE i.Id = inc.ItemId AND i.DeprecatedAt IS NULL))
    BEGIN
        SET @Message = N'One or more assigned items are not active finished goods.';
        SELECT @Status AS Status, @Message AS Message, @NewId AS NewId; RETURN;
    END

    -- Validation 3: no ItemId assigned to two printers.
    IF EXISTS (SELECT ItemId FROM @Incoming WHERE ItemId IS NOT NULL GROUP BY ItemId HAVING COUNT(*) > 1)
    BEGIN
        SET @Message = N'A finished good is assigned to more than one printer.';
        SELECT @Status AS Status, @Message AS Message, @NewId AS NewId; RETURN;
    END

    BEGIN TRY
        BEGIN TRANSACTION;

        -- Pre-mutation state: the station's CURRENT assignments (about to be
        -- replaced), resolved-name JSON per the Audit Log Description convention.
        SET @OldValue = (
            SELECT
                JSON_QUERY((SELECT p.Id, p.Code, p.Name
                            FROM Location.Location p WHERE p.Id = pfa.PrinterLocationId
                            FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)) AS Printer,
                JSON_QUERY((SELECT i.Id, i.PartNumber
                            FROM Parts.Item i WHERE i.Id = pfa.ItemId
                            FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)) AS Item,
                pfa.SortOrder
            FROM Location.PrinterFgAssignment pfa
            INNER JOIN Location.Location p ON p.Id = pfa.PrinterLocationId
            WHERE p.ParentLocationId = @StationTerminalLocationId
              AND p.LocationTypeDefinitionId = 16
            ORDER BY pfa.SortOrder
            FOR JSON PATH
        );
        SET @OldValue = ISNULL(@OldValue, N'[]');

        DELETE pfa
        FROM Location.PrinterFgAssignment pfa
        INNER JOIN Location.Location p ON p.Id = pfa.PrinterLocationId
        WHERE p.ParentLocationId = @StationTerminalLocationId
          AND p.LocationTypeDefinitionId = 16;

        INSERT INTO Location.PrinterFgAssignment (PrinterLocationId, ItemId, SortOrder, CreatedByAppUserId)
        SELECT PrinterLocationId, ItemId, SortOrder, @AppUserId
        FROM @Incoming
        WHERE ItemId IS NOT NULL;

        -- Post-mutation state: the newly-saved (non-null) assignments, same
        -- resolved-name shape as @OldValue.
        SET @NewValue = (
            SELECT
                JSON_QUERY((SELECT p.Id, p.Code, p.Name
                            FROM Location.Location p WHERE p.Id = inc.PrinterLocationId
                            FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)) AS Printer,
                JSON_QUERY((SELECT i.Id, i.PartNumber
                            FROM Parts.Item i WHERE i.Id = inc.ItemId
                            FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)) AS Item,
                inc.SortOrder
            FROM @Incoming inc
            WHERE inc.ItemId IS NOT NULL
            ORDER BY inc.SortOrder
            FOR JSON PATH
        );
        SET @NewValue = ISNULL(@NewValue, N'[]');

        DECLARE @Cnt INT = (SELECT COUNT(*) FROM @Incoming WHERE ItemId IS NOT NULL);
        DECLARE @Activity NVARCHAR(500) =
            N'Printer FG Assignment ' + Audit.ufn_MidDot() + N' Updated ' + Audit.ufn_MidDot()
            + N' ' + CAST(@Cnt AS NVARCHAR(10)) + N' assignment(s) at terminal '
            + CAST(@StationTerminalLocationId AS NVARCHAR(20));
        SET @Activity = Audit.ufn_TruncateActivity(@Activity);

        EXEC Audit.Audit_LogConfigChange
            @AppUserId         = @AppUserId,
            @LogEntityTypeCode = N'PrinterFgAssignment',
            @EntityId          = @StationTerminalLocationId,
            @LogEventTypeCode  = N'Updated',
            @LogSeverityCode   = N'Info',
            @Description       = @Activity,
            @OldValue          = @OldValue,
            @NewValue          = @NewValue;

        COMMIT TRANSACTION;
        SET @Status  = 1;
        SET @Message = N'Printer assignments saved.';
        SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        SET @Status  = 0;
        SET @Message = ERROR_MESSAGE();
        BEGIN TRY
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId,
                @LogEntityTypeCode = N'PrinterFgAssignment',
                @EntityId = @StationTerminalLocationId,
                @LogEventTypeCode = N'Updated',
                @FailureReason = @Message,
                @ProcedureName = N'Location.PrinterFgAssignment_SaveAll',
                @AttemptedParameters = @AssignmentsJson;
        END TRY BEGIN CATCH END CATCH;
        SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
    END CATCH
END;
GO
