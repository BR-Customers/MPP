-- =============================================
-- Procedure:   Parts.ItemLocation_SaveAllForItem
-- Author:      Blue Ridge Automation
-- Created:     2026-05-27
-- Version:     1.3
--
-- Description:
--   Bundled SaveAll for an Item's eligibility map. Accepts the Item's
--   complete desired-state JSON array of ItemLocation rows and
--   atomically reconciles against current rows:
--     - Incoming row with non-NULL Id matching active row -> UPDATE
--     - Incoming row Id=NULL, no existing pairing            -> INSERT
--     - Incoming row Id=NULL, deprecated pairing exists       -> REACTIVATE
--     - Incoming row Id=NULL, active pairing exists           -> reject
--     - Active row not in incoming                            -> DEPRECATE
--
--   When IsConsumptionPoint=1: MinQuantity, MaxQuantity, and
--   DefaultQuantity are all required, and must satisfy
--   0 <= Min <= Default <= Max. When IsConsumptionPoint=0, the
--   metadata columns are forced to NULL on persist (defensive --
--   caller may leave stale values from a toggled checkbox).
--
--   No Item-Type x Location-Type compatibility check is performed.
--   Engineer is trusted; runtime scan-in enforces eligibility via
--   Parts.ItemLocation_IsEligible (FDS-03-014).
--
-- Parameters (input):
--   @ItemId    BIGINT          - Required.
--   @RowsJson  NVARCHAR(MAX)   - JSON array, see body for schema.
--   @AppUserId BIGINT          - Required for audit.
--
-- Result set:
--   Single row: Status (BIT), Message (NVARCHAR), NewId (BIGINT echoes @ItemId).
--
-- Change Log:
--   2026-05-27 - 1.0 - Initial (Phase 8 Eligibility editor).
--   2026-05-29 - 1.1 - Audit-readability convention: SUBJECT . Eligibility
--                       . ACTION narrative Description + resolved-FK
--                       OldValue/NewValue JSON (Location {Id, Code, Name}).
--                       Slice 2 reference impl.
-- =============================================
CREATE OR ALTER PROCEDURE Parts.ItemLocation_SaveAllForItem
    @ItemId    BIGINT,
    @RowsJson  NVARCHAR(MAX),
    @AppUserId BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Status  BIT           = 0;
    DECLARE @Message NVARCHAR(500) = N'Unknown error';
    DECLARE @NewId   BIGINT        = @ItemId;

    DECLARE @ProcName NVARCHAR(200) = N'Parts.ItemLocation_SaveAllForItem';
    DECLARE @Params   NVARCHAR(MAX) =
        (SELECT @ItemId AS ItemId,
                JSON_QUERY(@RowsJson) AS Rows
         FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

    -- Incoming row buffer
    DECLARE @Incoming TABLE (
        RowIndex            INT PRIMARY KEY,
        Id                  BIGINT NULL,
        LocationId          BIGINT NULL,
        IsConsumptionPoint  BIT    NULL,
        MinQuantity         INT    NULL,
        MaxQuantity         INT    NULL,
        DefaultQuantity     INT    NULL
    );

    BEGIN TRY
        IF @ItemId IS NULL OR @AppUserId IS NULL
        BEGIN
            SET @Message = N'Required parameter missing.';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'ItemLocation',
                @EntityId = @ItemId, @LogEventTypeCode = N'Updated',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
            RETURN;
        END

        IF NOT EXISTS (SELECT 1 FROM Parts.Item WHERE Id = @ItemId AND DeprecatedAt IS NULL)
        BEGIN
            SET @Message = N'Item not found or deprecated.';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'ItemLocation',
                @EntityId = @ItemId, @LogEventTypeCode = N'Updated',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
            RETURN;
        END

        -- Parse @RowsJson into @Incoming. Default IsConsumptionPoint=0 on parse failure.
        INSERT INTO @Incoming (RowIndex, Id, LocationId, IsConsumptionPoint,
                               MinQuantity, MaxQuantity, DefaultQuantity)
        SELECT
            CAST([key] AS INT) + 1,
            TRY_CAST(JSON_VALUE([value], '$.Id')                 AS BIGINT),
            TRY_CAST(JSON_VALUE([value], '$.LocationId')         AS BIGINT),
            COALESCE(TRY_CAST(JSON_VALUE([value], '$.IsConsumptionPoint') AS BIT), 0),
            TRY_CAST(JSON_VALUE([value], '$.MinQuantity')        AS INT),
            TRY_CAST(JSON_VALUE([value], '$.MaxQuantity')        AS INT),
            TRY_CAST(JSON_VALUE([value], '$.DefaultQuantity')    AS INT)
        FROM OPENJSON(ISNULL(@RowsJson, N'[]'));

        -- Per-row validations -----------------------------------------------

        IF EXISTS (SELECT 1 FROM @Incoming WHERE LocationId IS NULL)
        BEGIN
            SET @Message = N'One or more rows are missing LocationId.';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'ItemLocation',
                @EntityId = @ItemId, @LogEventTypeCode = N'Updated',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
            RETURN;
        END

        IF EXISTS (
            SELECT 1 FROM @Incoming i
            WHERE NOT EXISTS (
                SELECT 1 FROM Location.Location l
                WHERE l.Id = i.LocationId AND l.DeprecatedAt IS NULL
            )
        )
        BEGIN
            SET @Message = N'One or more LocationId values are invalid or deprecated.';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'ItemLocation',
                @EntityId = @ItemId, @LogEventTypeCode = N'Updated',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
            RETURN;
        END

        -- Consumption-point qty requirements
        IF EXISTS (
            SELECT 1 FROM @Incoming
            WHERE IsConsumptionPoint = 1
              AND (MinQuantity IS NULL OR MaxQuantity IS NULL OR DefaultQuantity IS NULL)
        )
        BEGIN
            SET @Message = N'Min/Max/Default required when consumption point is enabled.';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'ItemLocation',
                @EntityId = @ItemId, @LogEventTypeCode = N'Updated',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
            RETURN;
        END

        IF EXISTS (
            SELECT 1 FROM @Incoming
            WHERE IsConsumptionPoint = 1
              AND (MinQuantity < 0 OR MinQuantity > DefaultQuantity OR DefaultQuantity > MaxQuantity)
        )
        BEGIN
            SET @Message = N'Min must be >= 0 and Min <= Default <= Max.';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'ItemLocation',
                @EntityId = @ItemId, @LogEventTypeCode = N'Updated',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
            RETURN;
        END

        -- Uniqueness inside the incoming set
        IF EXISTS (
            SELECT LocationId FROM @Incoming GROUP BY LocationId HAVING COUNT(*) > 1
        )
        BEGIN
            SET @Message = N'Duplicate Item+Location pairing in submitted rows.';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'ItemLocation',
                @EntityId = @ItemId, @LogEventTypeCode = N'Updated',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
            RETURN;
        END

        -- Force NULL on the qty columns when IsConsumptionPoint=0 (defensive)
        UPDATE @Incoming
        SET MinQuantity = NULL, MaxQuantity = NULL, DefaultQuantity = NULL
        WHERE IsConsumptionPoint = 0;

        -- ===== Audit narrative + resolved JSON (built from PRE-mutation state) =====

        -- Subject resolution (convention SUBJECT)
        DECLARE @PartNumber NVARCHAR(50);
        DECLARE @ItemDesc   NVARCHAR(500);

        SELECT @PartNumber = PartNumber, @ItemDesc = Description
        FROM Parts.Item
        WHERE Id = @ItemId;

        DECLARE @Subject NVARCHAR(600) =
            @PartNumber + CASE WHEN @ItemDesc IS NOT NULL THEN N' ' + NCHAR(8212) + N' ' + @ItemDesc ELSE N'' END;

        -- Change-set classification (drives Activity prose + resolved JSON)
        DECLARE @Changes TABLE (
            ChangeKind          NCHAR(1) NOT NULL,  -- '+' / '-' / '~'
            SortKey             INT NOT NULL,       -- canonical order within kind
            ExistingId          BIGINT NULL,        -- present for - and ~
            LocationId          BIGINT NOT NULL,
            LocationCode        NVARCHAR(50) NOT NULL,
            LocationName        NVARCHAR(200) NOT NULL,
            TierDefName         NVARCHAR(100) NOT NULL,
            OldIsConsumption    BIT NULL,
            NewIsConsumption    BIT NULL,
            OldMin              INT NULL, NewMin INT NULL,
            OldMax              INT NULL, NewMax INT NULL,
            OldDefault          INT NULL, NewDefault INT NULL
        );

        -- ADDS: incoming Id IS NULL, no active or deprecated pairing
        INSERT INTO @Changes
            (ChangeKind, SortKey, LocationId, LocationCode, LocationName, TierDefName,
             NewIsConsumption, NewMin, NewMax, NewDefault)
        SELECT N'+',
               ROW_NUMBER() OVER (ORDER BY l.Code),
               l.Id, l.Code, l.Name, ltd.Name,
               i.IsConsumptionPoint, i.MinQuantity, i.MaxQuantity, i.DefaultQuantity
        FROM @Incoming i
        INNER JOIN Location.Location l ON l.Id = i.LocationId
        INNER JOIN Location.LocationTypeDefinition ltd ON ltd.Id = l.LocationTypeDefinitionId
        WHERE i.Id IS NULL
          AND NOT EXISTS (SELECT 1 FROM Parts.ItemLocation il
                          WHERE il.ItemId = @ItemId AND il.LocationId = i.LocationId);

        -- ADDS via REACTIVATION (incoming Id IS NULL, deprecated pairing exists)
        -- These render as ADD in the audit narrative; the reactivation is a DB detail
        INSERT INTO @Changes
            (ChangeKind, SortKey, ExistingId, LocationId, LocationCode, LocationName,
             TierDefName, NewIsConsumption, NewMin, NewMax, NewDefault)
        SELECT N'+',
               100 + ROW_NUMBER() OVER (ORDER BY l.Code),
               il.Id, l.Id, l.Code, l.Name, ltd.Name,
               i.IsConsumptionPoint, i.MinQuantity, i.MaxQuantity, i.DefaultQuantity
        FROM @Incoming i
        INNER JOIN Parts.ItemLocation il
            ON il.ItemId = @ItemId AND il.LocationId = i.LocationId AND il.DeprecatedAt IS NOT NULL
        INNER JOIN Location.Location l ON l.Id = i.LocationId
        INNER JOIN Location.LocationTypeDefinition ltd ON ltd.Id = l.LocationTypeDefinitionId
        WHERE i.Id IS NULL;

        -- UPDATES: Id matched + at least one field differs
        INSERT INTO @Changes
            (ChangeKind, SortKey, ExistingId, LocationId, LocationCode, LocationName,
             TierDefName,
             OldIsConsumption, NewIsConsumption,
             OldMin, NewMin, OldMax, NewMax, OldDefault, NewDefault)
        SELECT N'~',
               ROW_NUMBER() OVER (ORDER BY l.Code),
               il.Id, l.Id, l.Code, l.Name, ltd.Name,
               il.IsConsumptionPoint, i.IsConsumptionPoint,
               il.MinQuantity, i.MinQuantity,
               il.MaxQuantity, i.MaxQuantity,
               il.DefaultQuantity, i.DefaultQuantity
        FROM @Incoming i
        INNER JOIN Parts.ItemLocation il ON il.Id = i.Id
        INNER JOIN Location.Location l ON l.Id = il.LocationId
        INNER JOIN Location.LocationTypeDefinition ltd ON ltd.Id = l.LocationTypeDefinitionId
        WHERE il.DeprecatedAt IS NULL
          AND (il.IsConsumptionPoint <> i.IsConsumptionPoint
               OR ISNULL(il.MinQuantity, -1) <> ISNULL(i.MinQuantity, -1)
               OR ISNULL(il.MaxQuantity, -1) <> ISNULL(i.MaxQuantity, -1)
               OR ISNULL(il.DefaultQuantity, -1) <> ISNULL(i.DefaultQuantity, -1));

        -- REMOVES: active row whose Id is not in incoming
        INSERT INTO @Changes
            (ChangeKind, SortKey, ExistingId, LocationId, LocationCode, LocationName,
             TierDefName, OldIsConsumption, OldMin, OldMax, OldDefault)
        SELECT N'-',
               ROW_NUMBER() OVER (ORDER BY l.Code),
               il.Id, l.Id, l.Code, l.Name, ltd.Name,
               il.IsConsumptionPoint, il.MinQuantity, il.MaxQuantity, il.DefaultQuantity
        FROM Parts.ItemLocation il
        INNER JOIN Location.Location l ON l.Id = il.LocationId
        INNER JOIN Location.LocationTypeDefinition ltd ON ltd.Id = l.LocationTypeDefinitionId
        WHERE il.ItemId = @ItemId AND il.DeprecatedAt IS NULL
          AND NOT EXISTS (SELECT 1 FROM @Incoming i WHERE i.Id = il.Id);

        -- ----- Compose the Activity prose -----

        -- Per-operation specific lists (cap at 3 each per convention)
        DECLARE @AddSpecifics    NVARCHAR(MAX) = N'';
        DECLARE @AddOverflow     INT = 0;
        DECLARE @UpdateSpecifics NVARCHAR(MAX) = N'';
        DECLARE @UpdateOverflow  INT = 0;
        DECLARE @RemoveSpecifics NVARCHAR(MAX) = N'';
        DECLARE @RemoveOverflow  INT = 0;
        DECLARE @TotalRows       INT = (SELECT COUNT(*) FROM @Incoming);

        -- Adds: render as "+CODE (TierDefName)" -- TierDef gives spatial context
        ;WITH ranked AS (
            SELECT *, ROW_NUMBER() OVER (ORDER BY SortKey) AS rn
            FROM @Changes WHERE ChangeKind = N'+'
        )
        SELECT @AddSpecifics = STRING_AGG(
            N'+' + LocationCode + N' (' + TierDefName + N')',
            N', '
        ) WITHIN GROUP (ORDER BY rn)
        FROM ranked WHERE rn <= 3;
        SELECT @AddOverflow = COUNT(*) - 3 FROM @Changes WHERE ChangeKind = N'+';
        IF @AddOverflow < 0 SET @AddOverflow = 0;

        -- Updates: render the changed fields as Field old->new tuples
        ;WITH ranked AS (
            SELECT *, ROW_NUMBER() OVER (ORDER BY SortKey) AS rn
            FROM @Changes WHERE ChangeKind = N'~'
        )
        SELECT @UpdateSpecifics = STRING_AGG(
            N'~' + LocationCode + N' ' +
            STUFF(
                CONCAT(
                    CASE WHEN OldIsConsumption <> NewIsConsumption
                         THEN N', IsConsumptionPoint ' + CASE WHEN OldIsConsumption = 1 THEN N'true' ELSE N'false' END + NCHAR(8594) + CASE WHEN NewIsConsumption = 1 THEN N'true' ELSE N'false' END
                         ELSE N'' END,
                    CASE WHEN ISNULL(OldMin, -1) <> ISNULL(NewMin, -1)
                         THEN N', MinQuantity ' + ISNULL(CAST(OldMin AS NVARCHAR), N'null') + NCHAR(8594) + ISNULL(CAST(NewMin AS NVARCHAR), N'null')
                         ELSE N'' END,
                    CASE WHEN ISNULL(OldMax, -1) <> ISNULL(NewMax, -1)
                         THEN N', MaxQuantity ' + ISNULL(CAST(OldMax AS NVARCHAR), N'null') + NCHAR(8594) + ISNULL(CAST(NewMax AS NVARCHAR), N'null')
                         ELSE N'' END,
                    CASE WHEN ISNULL(OldDefault, -1) <> ISNULL(NewDefault, -1)
                         THEN N', DefaultQuantity ' + ISNULL(CAST(OldDefault AS NVARCHAR), N'null') + NCHAR(8594) + ISNULL(CAST(NewDefault AS NVARCHAR), N'null')
                         ELSE N'' END
                ),
                1, 2, N''  -- strip the leading ", "
            ),
            N'; '
        ) WITHIN GROUP (ORDER BY rn)
        FROM ranked WHERE rn <= 3;
        SELECT @UpdateOverflow = COUNT(*) - 3 FROM @Changes WHERE ChangeKind = N'~';
        IF @UpdateOverflow < 0 SET @UpdateOverflow = 0;

        -- Removes: render as "-CODE"
        ;WITH ranked AS (
            SELECT *, ROW_NUMBER() OVER (ORDER BY SortKey) AS rn
            FROM @Changes WHERE ChangeKind = N'-'
        )
        SELECT @RemoveSpecifics = STRING_AGG(N'-' + LocationCode, N', ')
                                  WITHIN GROUP (ORDER BY rn)
        FROM ranked WHERE rn <= 3;
        SELECT @RemoveOverflow = COUNT(*) - 3 FROM @Changes WHERE ChangeKind = N'-';
        IF @RemoveOverflow < 0 SET @RemoveOverflow = 0;

        -- Compose the Activity prose: SUBJECT . CATEGORY . ACTION; N rows
        DECLARE @ActionParts NVARCHAR(MAX) = N'';

        IF NULLIF(@AddSpecifics, N'') IS NOT NULL
            SET @ActionParts = @ActionParts + @AddSpecifics +
                               CASE WHEN @AddOverflow > 0 THEN N', +' + CAST(@AddOverflow AS NVARCHAR) + N' more' ELSE N'' END +
                               N'; ';

        IF NULLIF(@UpdateSpecifics, N'') IS NOT NULL
            SET @ActionParts = @ActionParts + @UpdateSpecifics +
                               CASE WHEN @UpdateOverflow > 0 THEN N'; ~' + CAST(@UpdateOverflow AS NVARCHAR) + N' more' ELSE N'' END +
                               N'; ';

        IF NULLIF(@RemoveSpecifics, N'') IS NOT NULL
            SET @ActionParts = @ActionParts + @RemoveSpecifics +
                               CASE WHEN @RemoveOverflow > 0 THEN N', -' + CAST(@RemoveOverflow AS NVARCHAR) + N' more' ELSE N'' END +
                               N'; ';

        -- Strip trailing "; " (use DATALENGTH: LEN() ignores trailing spaces and
        -- would eat one real character off the last specific)
        IF DATALENGTH(@ActionParts) >= 4
            SET @ActionParts = LEFT(@ActionParts, DATALENGTH(@ActionParts) / 2 - 2);

        IF @ActionParts = N''
            SET @ActionParts = N'No-op save';

        DECLARE @ActivityRaw NVARCHAR(MAX) =
            @Subject + N' ' + Audit.ufn_MidDot() + N' Eligibility ' + Audit.ufn_MidDot() +
            N' ' + @ActionParts +
            N'; ' + CAST(@TotalRows AS NVARCHAR) + N' rows';

        DECLARE @Activity NVARCHAR(500) = Audit.ufn_TruncateActivity(@ActivityRaw);

        -- ----- Resolved-FK OldValue / NewValue JSON -----

        -- OldValue: pre-state active rows with resolved Location names
        DECLARE @OldValueResolved NVARCHAR(MAX) = (
            SELECT
                il.Id,
                JSON_QUERY((SELECT l.Id, l.Code, l.Name
                 FROM Location.Location l WHERE l.Id = il.LocationId
                 FOR JSON PATH, WITHOUT_ARRAY_WRAPPER))            AS Location,
                il.IsConsumptionPoint,
                il.MinQuantity, il.MaxQuantity, il.DefaultQuantity
            FROM Parts.ItemLocation il
            WHERE il.ItemId = @ItemId AND il.DeprecatedAt IS NULL
            ORDER BY il.LocationId
            FOR JSON PATH
        );

        -- NewValue: post-state intent from @Incoming, with resolved Location names
        DECLARE @NewValueResolved NVARCHAR(MAX) = (
            SELECT
                i.Id,
                JSON_QUERY((SELECT l.Id, l.Code, l.Name
                 FROM Location.Location l WHERE l.Id = i.LocationId
                 FOR JSON PATH, WITHOUT_ARRAY_WRAPPER))            AS Location,
                i.IsConsumptionPoint,
                i.MinQuantity, i.MaxQuantity, i.DefaultQuantity
            FROM @Incoming i
            ORDER BY i.LocationId
            FOR JSON PATH
        );

        -- ----- Mutation (atomic) -----
        BEGIN TRANSACTION;

        -- 1. DEPRECATE active rows whose Id is not in incoming
        UPDATE Parts.ItemLocation
        SET DeprecatedAt = SYSUTCDATETIME()
        WHERE ItemId = @ItemId
          AND DeprecatedAt IS NULL
          AND NOT EXISTS (
              SELECT 1 FROM @Incoming i WHERE i.Id = Parts.ItemLocation.Id
          );

        -- 2. UPDATE Id-matched rows
        UPDATE il
        SET LocationId          = i.LocationId,
            IsConsumptionPoint  = i.IsConsumptionPoint,
            MinQuantity         = i.MinQuantity,
            MaxQuantity         = i.MaxQuantity,
            DefaultQuantity     = i.DefaultQuantity
        FROM Parts.ItemLocation il
        INNER JOIN @Incoming i ON i.Id = il.Id
        WHERE il.ItemId = @ItemId AND il.DeprecatedAt IS NULL;

        -- 3. REACTIVATE deprecated rows where (ItemId, LocationId) pairing matches an incoming Id=NULL row
        UPDATE il
        SET DeprecatedAt        = NULL,
            IsConsumptionPoint  = i.IsConsumptionPoint,
            MinQuantity         = i.MinQuantity,
            MaxQuantity         = i.MaxQuantity,
            DefaultQuantity     = i.DefaultQuantity
        FROM Parts.ItemLocation il
        INNER JOIN @Incoming i
            ON i.Id IS NULL
            AND i.LocationId = il.LocationId
        WHERE il.ItemId = @ItemId AND il.DeprecatedAt IS NOT NULL;

        -- 4. INSERT new pairings (Id=NULL incoming rows without an existing pairing)
        INSERT INTO Parts.ItemLocation (
            ItemId, LocationId, IsConsumptionPoint,
            MinQuantity, MaxQuantity, DefaultQuantity
        )
        SELECT @ItemId, i.LocationId, i.IsConsumptionPoint,
               i.MinQuantity, i.MaxQuantity, i.DefaultQuantity
        FROM @Incoming i
        WHERE i.Id IS NULL
          AND NOT EXISTS (
              SELECT 1 FROM Parts.ItemLocation il
              WHERE il.ItemId = @ItemId AND il.LocationId = i.LocationId
          );

        DECLARE @RowCount INT = (SELECT COUNT(*) FROM @Incoming);

        EXEC Audit.Audit_LogConfigChange
            @AppUserId         = @AppUserId,
            @LogEntityTypeCode = N'ItemLocation',
            @EntityId          = @ItemId,
            @LogEventTypeCode  = N'Updated',
            @LogSeverityCode   = N'Info',
            @Description       = @Activity,
            @OldValue          = @OldValueResolved,
            @NewValue          = @NewValueResolved;

        COMMIT TRANSACTION;

        SET @Status  = 1;
        SET @Message = N'Eligibility saved. ' + CAST(@RowCount AS NVARCHAR(10)) + N' row(s) in payload.';
        SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
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
                @EntityId = @ItemId, @LogEventTypeCode = N'Updated',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
        END TRY
        BEGIN CATCH
        END CATCH

        SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
        RAISERROR(@ErrMsg, @ErrSev, @ErrState);
    END CATCH
END;
GO
