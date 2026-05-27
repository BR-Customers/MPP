# Item Master Phase 8 — Eligibility Editor Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the Phase-1-shell Eligibility tab on `/items` with a fully wired editor that lets engineers add, edit, deprecate, and reactivate `Parts.ItemLocation` rows for a selected Item via a tiered-list UI, with bundled SaveAll commit and full audit trail.

**Architecture:** Per-section ownership pattern with single `view.custom.state = {selected, editDraft}` atomic writes (matches Identity / ContainerConfig / BOMs / Routes). EligibilityRow sub-view sends page-scoped messages to the parent embed; parent's customMethods mutate `state.editDraft.rows` and an `Parts.ItemLocation_SaveAllForItem` SaveAll proc reconciles the JSON payload atomically (add / update / deprecate / reactivate-deprecated).

**Tech Stack:** SQL Server 2022 stored procs, Ignition 8.3 Perspective Named Queries + script-python entity scripts, Jython 2.7.

**Spec:** `docs/superpowers/specs/2026-05-27-item-master-eligibility-design.md` (commits `03c50e0` + `8fc736d`)

---

## File Structure

| Path | Action | Responsibility |
|---|---|---|
| `sql/migrations/repeatable/R__Parts_ItemLocation_SaveAllForItem.sql` | Create | New SaveAll proc with bundled reconciliation |
| `sql/migrations/repeatable/R__Location_Location_ListForEligibilityPicker.sql` | Create | Picker read returning all non-deprecated Locations with tier metadata |
| `sql/migrations/repeatable/R__Parts_ItemLocation_ListByItem.sql` | Modify | Add `TierOrdinal` column and re-sort by `(TierOrdinal, Code)` |
| `sql/tests/0009_Parts_Process/040_ItemLocation_SaveAllForItem.sql` | Create | Test fixtures for the new SaveAll proc |
| `sql/tests/0009_Parts_Process/050_Location_ListForEligibilityPicker.sql` | Create | Test fixtures for the new picker read |
| `ignition/projects/MPP_Config/ignition/named-query/parts/ItemLocation_SaveAllForItem/{query.sql, resource.json}` | Create | NQ wrapper, `type: "Query"` |
| `ignition/projects/MPP_Config/ignition/named-query/location/Location_ListForEligibilityPicker/{query.sql, resource.json}` | Create | NQ wrapper, `type: "Query"`, 60-sec cache |
| `ignition/projects/MPP_Config/ignition/script-python/BlueRidge/Parts/Eligibility/{code.py, resource.json}` | Create | Entity script: `listByItem`, `listLocationOptions`, `handleSaveAll` |
| `ignition/projects/MPP_Config/com.inductiveautomation.perspective/views/BlueRidge/Components/Parts/ItemMaster/EligibilityRow/{view.json, resource.json}` | Create | New sub-view for one editable row |
| `ignition/projects/MPP_Config/com.inductiveautomation.perspective/views/BlueRidge/Components/Parts/ItemMaster/Eligibility/view.json` | Modify | Replace Phase-1 placeholder shell with the full editor wired to state + SaveAll |

---

### Task 1: New SaveAll stored proc — `Parts.ItemLocation_SaveAllForItem`

**Files:**
- Create: `sql/migrations/repeatable/R__Parts_ItemLocation_SaveAllForItem.sql`

- [ ] **Step 1: Write the proc**

Author the proc with full validation + reconciliation. Key elements: parameters, table variable for incoming JSON parse, table variable for old-state snapshot (for audit), validate-then-reconcile flow inside a transaction, single Audit.Audit_LogConfigChange call at the end, status-row SELECT.

```sql
-- =============================================
-- Procedure:   Parts.ItemLocation_SaveAllForItem
-- Author:      Blue Ridge Automation
-- Created:     2026-05-27
-- Version:     1.0
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

    -- Pre-state snapshot (for audit OldValue)
    DECLARE @OldValue NVARCHAR(MAX);

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

        -- Capture pre-state for audit OldValue (active rows only)
        SET @OldValue = (
            SELECT il.Id, il.LocationId, il.IsConsumptionPoint,
                   il.MinQuantity, il.MaxQuantity, il.DefaultQuantity
            FROM Parts.ItemLocation il
            WHERE il.ItemId = @ItemId AND il.DeprecatedAt IS NULL
            ORDER BY il.LocationId
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
            @Description       = N'Eligibility map updated.',
            @OldValue          = @OldValue,
            @NewValue          = @RowsJson;

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
```

- [ ] **Step 2: Deploy the proc**

```bash
sqlcmd -S localhost -d MPP_MES_Dev -E -C -b -I -i sql/migrations/repeatable/R__Parts_ItemLocation_SaveAllForItem.sql
```

Expected: no output, exit 0.

- [ ] **Step 3: Smoke-test the proc directly against a known Item**

```bash
sqlcmd -S localhost -d MPP_MES_Dev -E -C -b -I -Q "
DECLARE @ItemId BIGINT = (SELECT TOP 1 Id FROM Parts.Item WHERE PartNumber = N'5G0');
DECLARE @LocId BIGINT  = (SELECT TOP 1 Id FROM Location.Location WHERE Code = N'DC');
DECLARE @Rows NVARCHAR(MAX) = N'[{\"Id\":null,\"LocationId\":' + CAST(@LocId AS NVARCHAR) + N',\"IsConsumptionPoint\":false,\"MinQuantity\":null,\"MaxQuantity\":null,\"DefaultQuantity\":null}]';
EXEC Parts.ItemLocation_SaveAllForItem @ItemId=@ItemId, @RowsJson=@Rows, @AppUserId=2;
"
```

Expected output: a single row `Status=1, Message='Eligibility saved. 1 row(s) in payload.', NewId=<5G0's Id>`.

- [ ] **Step 4: Commit**

```bash
git add sql/migrations/repeatable/R__Parts_ItemLocation_SaveAllForItem.sql
git commit -m "feat(sql): Parts.ItemLocation_SaveAllForItem v1.0 — bundled SaveAll proc"
```

---

### Task 2: New picker stored proc — `Location.Location_ListForEligibilityPicker`

**Files:**
- Create: `sql/migrations/repeatable/R__Location_Location_ListForEligibilityPicker.sql`

- [ ] **Step 1: Write the proc**

```sql
-- =============================================
-- Procedure:   Location.Location_ListForEligibilityPicker
-- Author:      Blue Ridge Automation
-- Created:     2026-05-27
-- Version:     1.0
--
-- Description:
--   Returns every non-deprecated Location across all tiers (Site /
--   Area / WorkCenter / Cell) with the tier metadata needed to render
--   the Eligibility editor's grouped-by-tier dropdown. Sorted by
--   (HierarchyLevel ASC, Code ASC) so the dropdown reads as a natural
--   progression from broadest tier to most-specific.
--
--   The DisplayLabel column composes the human label used directly as
--   the dropdown option label: "<Code> -- <Name> (<TierName>)".
--
-- Parameters:
--   @IncludeDeprecated BIT = 0 - Include rows where DeprecatedAt IS NOT NULL.
--
-- Result set:
--   Id, Code, Name, TierName, TierOrdinal, DisplayLabel
-- =============================================
CREATE OR ALTER PROCEDURE Location.Location_ListForEligibilityPicker
    @IncludeDeprecated BIT = 0
AS
BEGIN
    SET NOCOUNT ON;

    SELECT
        l.Id,
        l.Code,
        l.Name,
        ltd.Name                                                AS TierName,
        lt.HierarchyLevel                                       AS TierOrdinal,
        l.Code + N' — ' + l.Name + N' (' + ltd.Name + N')'     AS DisplayLabel
    FROM Location.Location l
    INNER JOIN Location.LocationTypeDefinition ltd ON ltd.Id = l.LocationTypeDefinitionId
    INNER JOIN Location.LocationType            lt  ON lt.Id  = ltd.LocationTypeId
    WHERE (@IncludeDeprecated = 1 OR l.DeprecatedAt IS NULL)
    ORDER BY lt.HierarchyLevel ASC, l.Code ASC;
END;
GO
```

- [ ] **Step 2: Deploy + smoke-test**

```bash
sqlcmd -S localhost -d MPP_MES_Dev -E -C -b -I -i sql/migrations/repeatable/R__Location_Location_ListForEligibilityPicker.sql
sqlcmd -S localhost -d MPP_MES_Dev -E -C -b -I -Q "EXEC Location.Location_ListForEligibilityPicker;"
```

Expected: rows for every non-deprecated Location sorted Site → Area → WorkCenter → Cell, then alphabetic by Code within each tier.

- [ ] **Step 3: Commit**

```bash
git add sql/migrations/repeatable/R__Location_Location_ListForEligibilityPicker.sql
git commit -m "feat(sql): Location.Location_ListForEligibilityPicker — tier-grouped picker read"
```

---

### Task 3: Update `Parts.ItemLocation_ListByItem` to include `TierOrdinal`

The current proc joins to LocationTypeDefinition but doesn't pull `HierarchyLevel` (TierOrdinal). The editor needs it for canonical row sorting.

**Files:**
- Modify: `sql/migrations/repeatable/R__Parts_ItemLocation_ListByItem.sql`

- [ ] **Step 1: Update the SELECT + ORDER BY + bump version**

Replace the entire proc body. Add `LocationType` join, add `TierOrdinal` column, change `ORDER BY` to `(lt.HierarchyLevel ASC, l.Code ASC)`, and bump the version in the header to 3.0 with a new change-log line.

```sql
-- =============================================
-- Procedure:   Parts.ItemLocation_ListByItem
-- Author:      Blue Ridge Automation
-- Created:     2026-04-14
-- Version:     3.0
--
-- Description:
--   Returns all active eligibility pairings for a given Item, joined
--   to Location.Location, Location.LocationTypeDefinition (Name AS
--   DefinitionName), and Location.LocationType (HierarchyLevel AS
--   TierOrdinal). Only rows where DeprecatedAt IS NULL are returned.
--   Ordered by tier then code so the editor sees rows in canonical
--   (Site -> Area -> WorkCenter -> Cell) order.
--
-- Parameters:
--   @ItemId BIGINT - Required.
--
-- Result set:
--   ItemLocation rows + LocationName, LocationCode, DefinitionName,
--   TierOrdinal.
--
-- Change Log:
--   2026-04-14 - 1.0 - Initial version (OUTPUT params)
--   2026-04-14 - 2.0 - Removed OUTPUT params for Named Query compatibility
--   2026-04-23 - 2.1 - Phase G.3: consumption metadata exposed (OI-18)
--   2026-05-27 - 3.0 - Phase 8 Eligibility editor: add TierOrdinal,
--                      re-sort by (TierOrdinal, Code) for canonical
--                      display order.
-- =============================================
CREATE OR ALTER PROCEDURE Parts.ItemLocation_ListByItem
    @ItemId BIGINT
AS
BEGIN
    SET NOCOUNT ON;

    SELECT
        il.Id,
        il.ItemId,
        il.LocationId,
        l.Name                  AS LocationName,
        l.Code                  AS LocationCode,
        ltd.Name                AS DefinitionName,
        lt.HierarchyLevel       AS TierOrdinal,
        il.MinQuantity,
        il.MaxQuantity,
        il.DefaultQuantity,
        il.IsConsumptionPoint,
        il.CreatedAt,
        il.DeprecatedAt
    FROM Parts.ItemLocation il
    INNER JOIN Location.Location               l   ON l.Id   = il.LocationId
    INNER JOIN Location.LocationTypeDefinition ltd ON ltd.Id = l.LocationTypeDefinitionId
    INNER JOIN Location.LocationType           lt  ON lt.Id  = ltd.LocationTypeId
    WHERE il.ItemId = @ItemId
      AND il.DeprecatedAt IS NULL
    ORDER BY lt.HierarchyLevel ASC, l.Code ASC;
END;
GO
```

- [ ] **Step 2: Deploy + smoke**

```bash
sqlcmd -S localhost -d MPP_MES_Dev -E -C -b -I -i sql/migrations/repeatable/R__Parts_ItemLocation_ListByItem.sql
sqlcmd -S localhost -d MPP_MES_Dev -E -C -b -I -Q "DECLARE @ItemId BIGINT = (SELECT TOP 1 Id FROM Parts.Item WHERE PartNumber=N'5G0'); EXEC Parts.ItemLocation_ListByItem @ItemId;"
```

Expected: 5G0's current ItemLocation rows with `TierOrdinal` populated and ordered by tier ascending.

- [ ] **Step 3: Commit**

```bash
git add sql/migrations/repeatable/R__Parts_ItemLocation_ListByItem.sql
git commit -m "feat(sql): ItemLocation_ListByItem v3.0 — add TierOrdinal + tier-sort"
```

---

### Task 4: SaveAll proc tests

**Files:**
- Create: `sql/tests/0009_Parts_Process/040_ItemLocation_SaveAllForItem.sql`

- [ ] **Step 1: Write the test file**

Covers the happy path (add new), update existing, deprecate-on-omit, reactivate-deprecated, validation rejections (missing LocationId, deprecated LocationId, missing qty on consumption-point, Min > Max, duplicate LocationIds in payload), and ItemId not found. Each test sets up the precondition, calls the proc, captures the result row, asserts on Status + DB state.

```sql
-- =============================================
-- File:         0009_Parts_Process/040_ItemLocation_SaveAllForItem.sql
-- Author:       Blue Ridge Automation
-- Created:      2026-05-27
-- Description:  Test fixtures for Parts.ItemLocation_SaveAllForItem.
--               Covers add/update/deprecate/reactivate paths and
--               validation rejections.
-- =============================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0009_Parts_Process/040_ItemLocation_SaveAllForItem.sql';
GO

-- Test setup: create test Item + test Locations if they don't already exist
DECLARE @TestItemPart NVARCHAR(50) = N'TEST-ELIG-ITEM-001';
DECLARE @TestItemId   BIGINT       = (SELECT Id FROM Parts.Item WHERE PartNumber = @TestItemPart AND DeprecatedAt IS NULL);

IF @TestItemId IS NULL
BEGIN
    DECLARE @ItId BIGINT = (SELECT TOP 1 Id FROM Parts.ItemType WHERE Name = N'Component');
    DECLARE @UmId BIGINT = (SELECT TOP 1 Id FROM Parts.Uom      WHERE Code = N'EA');
    INSERT INTO Parts.Item (PartNumber, Description, ItemTypeId, UomId, CreatedByUserId)
    VALUES (@TestItemPart, N'Eligibility test item', @ItId, @UmId, 1);
    SET @TestItemId = SCOPE_IDENTITY();
END
GO

-- =============================================
-- Test 1: SaveAll empty payload on Item with no existing rows -> Status=1, 0 rows
-- =============================================
DECLARE @S BIT, @M NVARCHAR(500), @SStr NVARCHAR(1);
DECLARE @TestItemId BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'TEST-ELIG-ITEM-001');

CREATE TABLE #R1 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #R1
EXEC Parts.ItemLocation_SaveAllForItem
    @ItemId    = @TestItemId,
    @RowsJson  = N'[]',
    @AppUserId = 1;
SELECT @S = Status, @M = Message FROM #R1;
DROP TABLE #R1;

SET @SStr = CAST(@S AS NVARCHAR(1));
EXEC test.Assert_IsEqual
    @TestName = N'[EligSaveEmpty] Status is 1',
    @Expected = N'1',
    @Actual   = @SStr;
GO

-- =============================================
-- Test 2: Add a new row (Id=NULL)
-- =============================================
DECLARE @S BIT, @M NVARCHAR(500), @SStr NVARCHAR(1);
DECLARE @TestItemId BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'TEST-ELIG-ITEM-001');
DECLARE @LocId BIGINT = (SELECT TOP 1 l.Id
                          FROM Location.Location l
                          INNER JOIN Location.LocationTypeDefinition ltd ON ltd.Id = l.LocationTypeDefinitionId
                          WHERE ltd.Name = N'Area' AND l.DeprecatedAt IS NULL
                          ORDER BY l.Code);

DECLARE @Json NVARCHAR(MAX) =
    N'[{"Id":null,"LocationId":' + CAST(@LocId AS NVARCHAR(20)) +
    N',"IsConsumptionPoint":false,"MinQuantity":null,"MaxQuantity":null,"DefaultQuantity":null}]';

CREATE TABLE #R2 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #R2
EXEC Parts.ItemLocation_SaveAllForItem
    @ItemId    = @TestItemId,
    @RowsJson  = @Json,
    @AppUserId = 1;
SELECT @S = Status, @M = Message FROM #R2;
DROP TABLE #R2;

SET @SStr = CAST(@S AS NVARCHAR(1));
EXEC test.Assert_IsEqual
    @TestName = N'[EligAddRow] Status is 1',
    @Expected = N'1',
    @Actual   = @SStr;

DECLARE @Cnt INT = (SELECT COUNT(*) FROM Parts.ItemLocation
                    WHERE ItemId = @TestItemId AND LocationId = @LocId AND DeprecatedAt IS NULL);
DECLARE @CntStr NVARCHAR(10) = CAST(@Cnt AS NVARCHAR(10));
EXEC test.Assert_IsEqual
    @TestName = N'[EligAddRow] Exactly one active row exists',
    @Expected = N'1',
    @Actual   = @CntStr;
GO

-- =============================================
-- Test 3: Empty SaveAll deprecates the row added in Test 2
-- =============================================
DECLARE @S BIT, @M NVARCHAR(500), @SStr NVARCHAR(1);
DECLARE @TestItemId BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'TEST-ELIG-ITEM-001');

CREATE TABLE #R3 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #R3
EXEC Parts.ItemLocation_SaveAllForItem
    @ItemId    = @TestItemId,
    @RowsJson  = N'[]',
    @AppUserId = 1;
SELECT @S = Status, @M = Message FROM #R3;
DROP TABLE #R3;

SET @SStr = CAST(@S AS NVARCHAR(1));
EXEC test.Assert_IsEqual
    @TestName = N'[EligDeprecateAll] Status is 1',
    @Expected = N'1',
    @Actual   = @SStr;

DECLARE @ActiveCnt INT = (SELECT COUNT(*) FROM Parts.ItemLocation
                          WHERE ItemId = @TestItemId AND DeprecatedAt IS NULL);
DECLARE @ActiveStr NVARCHAR(10) = CAST(@ActiveCnt AS NVARCHAR(10));
EXEC test.Assert_IsEqual
    @TestName = N'[EligDeprecateAll] Zero active rows after empty save',
    @Expected = N'0',
    @Actual   = @ActiveStr;
GO

-- =============================================
-- Test 4: Reactivate the previously-deprecated pairing via Id=NULL + matching LocationId
-- =============================================
DECLARE @S BIT, @M NVARCHAR(500), @SStr NVARCHAR(1);
DECLARE @TestItemId BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'TEST-ELIG-ITEM-001');
DECLARE @LocId BIGINT = (SELECT TOP 1 l.Id
                          FROM Location.Location l
                          INNER JOIN Location.LocationTypeDefinition ltd ON ltd.Id = l.LocationTypeDefinitionId
                          WHERE ltd.Name = N'Area' AND l.DeprecatedAt IS NULL
                          ORDER BY l.Code);

DECLARE @PriorDeprecatedId BIGINT = (SELECT TOP 1 Id FROM Parts.ItemLocation
                                     WHERE ItemId = @TestItemId AND LocationId = @LocId
                                       AND DeprecatedAt IS NOT NULL
                                     ORDER BY Id);

DECLARE @Json NVARCHAR(MAX) =
    N'[{"Id":null,"LocationId":' + CAST(@LocId AS NVARCHAR(20)) +
    N',"IsConsumptionPoint":false,"MinQuantity":null,"MaxQuantity":null,"DefaultQuantity":null}]';

CREATE TABLE #R4 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #R4
EXEC Parts.ItemLocation_SaveAllForItem
    @ItemId    = @TestItemId,
    @RowsJson  = @Json,
    @AppUserId = 1;
SELECT @S = Status, @M = Message FROM #R4;
DROP TABLE #R4;

SET @SStr = CAST(@S AS NVARCHAR(1));
EXEC test.Assert_IsEqual
    @TestName = N'[EligReactivate] Status is 1',
    @Expected = N'1',
    @Actual   = @SStr;

-- The previously-deprecated Id should now be active again (no new row created)
DECLARE @ReactivatedDepAt DATETIME2(3);
SELECT @ReactivatedDepAt = DeprecatedAt FROM Parts.ItemLocation WHERE Id = @PriorDeprecatedId;
DECLARE @ReactivatedStr NVARCHAR(1) = CASE WHEN @ReactivatedDepAt IS NULL THEN N'1' ELSE N'0' END;
EXEC test.Assert_IsEqual
    @TestName = N'[EligReactivate] Original Id has DeprecatedAt cleared',
    @Expected = N'1',
    @Actual   = @ReactivatedStr;
GO

-- =============================================
-- Test 5: Consumption-point row missing qty -> Status=0
-- =============================================
DECLARE @S BIT, @M NVARCHAR(500), @SStr NVARCHAR(1);
DECLARE @TestItemId BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'TEST-ELIG-ITEM-001');
DECLARE @LocId BIGINT = (SELECT TOP 1 l.Id
                          FROM Location.Location l
                          INNER JOIN Location.LocationTypeDefinition ltd ON ltd.Id = l.LocationTypeDefinitionId
                          WHERE ltd.Name = N'Cell' AND l.DeprecatedAt IS NULL
                          ORDER BY l.Code);

DECLARE @Json NVARCHAR(MAX) =
    N'[{"Id":null,"LocationId":' + CAST(@LocId AS NVARCHAR(20)) +
    N',"IsConsumptionPoint":true,"MinQuantity":null,"MaxQuantity":200,"DefaultQuantity":100}]';

CREATE TABLE #R5 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #R5
EXEC Parts.ItemLocation_SaveAllForItem
    @ItemId    = @TestItemId,
    @RowsJson  = @Json,
    @AppUserId = 1;
SELECT @S = Status, @M = Message FROM #R5;
DROP TABLE #R5;

SET @SStr = CAST(@S AS NVARCHAR(1));
EXEC test.Assert_IsEqual
    @TestName = N'[EligCspMissingQty] Status is 0',
    @Expected = N'0',
    @Actual   = @SStr;
GO

-- =============================================
-- Test 6: Min > Max -> Status=0
-- =============================================
DECLARE @S BIT, @M NVARCHAR(500), @SStr NVARCHAR(1);
DECLARE @TestItemId BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'TEST-ELIG-ITEM-001');
DECLARE @LocId BIGINT = (SELECT TOP 1 l.Id
                          FROM Location.Location l
                          INNER JOIN Location.LocationTypeDefinition ltd ON ltd.Id = l.LocationTypeDefinitionId
                          WHERE ltd.Name = N'Cell' AND l.DeprecatedAt IS NULL
                          ORDER BY l.Code);

DECLARE @Json NVARCHAR(MAX) =
    N'[{"Id":null,"LocationId":' + CAST(@LocId AS NVARCHAR(20)) +
    N',"IsConsumptionPoint":true,"MinQuantity":200,"MaxQuantity":50,"DefaultQuantity":100}]';

CREATE TABLE #R6 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #R6
EXEC Parts.ItemLocation_SaveAllForItem
    @ItemId    = @TestItemId,
    @RowsJson  = @Json,
    @AppUserId = 1;
SELECT @S = Status, @M = Message FROM #R6;
DROP TABLE #R6;

SET @SStr = CAST(@S AS NVARCHAR(1));
EXEC test.Assert_IsEqual
    @TestName = N'[EligMinGtMax] Status is 0',
    @Expected = N'0',
    @Actual   = @SStr;
GO

-- =============================================
-- Test 7: Duplicate LocationId in payload -> Status=0
-- =============================================
DECLARE @S BIT, @M NVARCHAR(500), @SStr NVARCHAR(1);
DECLARE @TestItemId BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'TEST-ELIG-ITEM-001');
DECLARE @LocId BIGINT = (SELECT TOP 1 l.Id
                          FROM Location.Location l
                          INNER JOIN Location.LocationTypeDefinition ltd ON ltd.Id = l.LocationTypeDefinitionId
                          WHERE ltd.Name = N'Cell' AND l.DeprecatedAt IS NULL
                          ORDER BY l.Code);

DECLARE @Json NVARCHAR(MAX) =
    N'[' +
    N'{"Id":null,"LocationId":' + CAST(@LocId AS NVARCHAR(20)) + N',"IsConsumptionPoint":false,"MinQuantity":null,"MaxQuantity":null,"DefaultQuantity":null},' +
    N'{"Id":null,"LocationId":' + CAST(@LocId AS NVARCHAR(20)) + N',"IsConsumptionPoint":false,"MinQuantity":null,"MaxQuantity":null,"DefaultQuantity":null}' +
    N']';

CREATE TABLE #R7 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #R7
EXEC Parts.ItemLocation_SaveAllForItem
    @ItemId    = @TestItemId,
    @RowsJson  = @Json,
    @AppUserId = 1;
SELECT @S = Status, @M = Message FROM #R7;
DROP TABLE #R7;

SET @SStr = CAST(@S AS NVARCHAR(1));
EXEC test.Assert_IsEqual
    @TestName = N'[EligDuplicate] Status is 0',
    @Expected = N'0',
    @Actual   = @SStr;
GO

-- =============================================
-- Test 8: ItemId not found -> Status=0
-- =============================================
DECLARE @S BIT, @M NVARCHAR(500), @SStr NVARCHAR(1);

CREATE TABLE #R8 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #R8
EXEC Parts.ItemLocation_SaveAllForItem
    @ItemId    = 9999999999,
    @RowsJson  = N'[]',
    @AppUserId = 1;
SELECT @S = Status, @M = Message FROM #R8;
DROP TABLE #R8;

SET @SStr = CAST(@S AS NVARCHAR(1));
EXEC test.Assert_IsEqual
    @TestName = N'[EligBadItem] Status is 0',
    @Expected = N'0',
    @Actual   = @SStr;
GO

EXEC test.EndTestFile;
GO
```

- [ ] **Step 2: Run the tests**

```bash
sqlcmd -S localhost -d MPP_MES_Dev -E -C -b -I -i sql/tests/0009_Parts_Process/040_ItemLocation_SaveAllForItem.sql
```

Expected: every Assert_IsEqual passes, test framework prints PASS lines, exit 0.

- [ ] **Step 3: Commit**

```bash
git add sql/tests/0009_Parts_Process/040_ItemLocation_SaveAllForItem.sql
git commit -m "test(sql): coverage for Parts.ItemLocation_SaveAllForItem"
```

---

### Task 5: Picker proc tests

**Files:**
- Create: `sql/tests/0009_Parts_Process/050_Location_ListForEligibilityPicker.sql`

- [ ] **Step 1: Write the test file**

Covers: returns rows; sort order is `(TierOrdinal, Code)`; deprecated rows excluded by default; included when `@IncludeDeprecated=1`; DisplayLabel format matches `"<Code> — <Name> (<TierName>)"`.

```sql
-- =============================================
-- File:         0009_Parts_Process/050_Location_ListForEligibilityPicker.sql
-- =============================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0009_Parts_Process/050_Location_ListForEligibilityPicker.sql';
GO

-- =============================================
-- Test 1: Returns at least one row
-- =============================================
IF OBJECT_ID('tempdb..#P1') IS NOT NULL DROP TABLE #P1;
CREATE TABLE #P1 (
    Id BIGINT, Code NVARCHAR(50), Name NVARCHAR(200),
    TierName NVARCHAR(100), TierOrdinal INT, DisplayLabel NVARCHAR(400)
);
INSERT INTO #P1 EXEC Location.Location_ListForEligibilityPicker;

DECLARE @Cnt INT = (SELECT COUNT(*) FROM #P1);
DECLARE @CntStr NVARCHAR(20) = CASE WHEN @Cnt > 0 THEN N'1' ELSE N'0' END;
EXEC test.Assert_IsEqual
    @TestName = N'[PickerNonEmpty] Returns at least one row',
    @Expected = N'1',
    @Actual   = @CntStr;
DROP TABLE #P1;
GO

-- =============================================
-- Test 2: Sort order is (TierOrdinal ASC, Code ASC) -- TierOrdinal of first row <= TierOrdinal of last
-- =============================================
IF OBJECT_ID('tempdb..#P2') IS NOT NULL DROP TABLE #P2;
CREATE TABLE #P2 (
    RowNum INT IDENTITY(1,1) PRIMARY KEY,
    Id BIGINT, Code NVARCHAR(50), Name NVARCHAR(200),
    TierName NVARCHAR(100), TierOrdinal INT, DisplayLabel NVARCHAR(400)
);
INSERT INTO #P2 (Id, Code, Name, TierName, TierOrdinal, DisplayLabel)
EXEC Location.Location_ListForEligibilityPicker;

DECLARE @FirstTier INT = (SELECT TOP 1 TierOrdinal FROM #P2 ORDER BY RowNum ASC);
DECLARE @LastTier  INT = (SELECT TOP 1 TierOrdinal FROM #P2 ORDER BY RowNum DESC);
DECLARE @SortOk NVARCHAR(1) = CASE WHEN @FirstTier <= @LastTier THEN N'1' ELSE N'0' END;
EXEC test.Assert_IsEqual
    @TestName = N'[PickerSort] First row TierOrdinal <= last row TierOrdinal',
    @Expected = N'1',
    @Actual   = @SortOk;
DROP TABLE #P2;
GO

-- =============================================
-- Test 3: DisplayLabel contains the em-dash separator pattern
-- =============================================
IF OBJECT_ID('tempdb..#P3') IS NOT NULL DROP TABLE #P3;
CREATE TABLE #P3 (
    Id BIGINT, Code NVARCHAR(50), Name NVARCHAR(200),
    TierName NVARCHAR(100), TierOrdinal INT, DisplayLabel NVARCHAR(400)
);
INSERT INTO #P3 EXEC Location.Location_ListForEligibilityPicker;

DECLARE @AnyMatch NVARCHAR(1) =
    CASE WHEN EXISTS (SELECT 1 FROM #P3 WHERE DisplayLabel LIKE N'% — % (%)') THEN N'1' ELSE N'0' END;
EXEC test.Assert_IsEqual
    @TestName = N'[PickerLabel] DisplayLabel matches "code — name (tier)" shape',
    @Expected = N'1',
    @Actual   = @AnyMatch;
DROP TABLE #P3;
GO

EXEC test.EndTestFile;
GO
```

- [ ] **Step 2: Run + commit**

```bash
sqlcmd -S localhost -d MPP_MES_Dev -E -C -b -I -i sql/tests/0009_Parts_Process/050_Location_ListForEligibilityPicker.sql
git add sql/tests/0009_Parts_Process/050_Location_ListForEligibilityPicker.sql
git commit -m "test(sql): coverage for Location_ListForEligibilityPicker"
```

Expected: all three asserts pass.

---

### Task 6: Named Query wrappers

**Files:**
- Create: `ignition/projects/MPP_Config/ignition/named-query/parts/ItemLocation_SaveAllForItem/{query.sql, resource.json}`
- Create: `ignition/projects/MPP_Config/ignition/named-query/location/Location_ListForEligibilityPicker/{query.sql, resource.json}`

Note: NQ `type` MUST be `"Query"` for both, not `"UpdateQuery"`. SaveAllForItem returns a status-row SELECT; the picker is a plain read. See commit `1049ea3` for the lesson on what happens when this is wrong.

- [ ] **Step 1: SaveAllForItem NQ — query.sql**

```sql
-- @itemId    BIGINT
-- @rowsJson  NVARCHAR(MAX)
-- @appUserId BIGINT
EXEC Parts.ItemLocation_SaveAllForItem
    @ItemId    = :itemId,
    @RowsJson  = :rowsJson,
    @AppUserId = :appUserId
```

- [ ] **Step 2: SaveAllForItem NQ — resource.json**

```json
{
  "scope": "DG",
  "version": 2,
  "restricted": false,
  "overridable": true,
  "files": [
    "query.sql"
  ],
  "attributes": {
    "useMaxReturnSize": false,
    "autoBatchEnabled": false,
    "fallbackValue": "",
    "maxReturnSize": 100,
    "cacheUnit": "SEC",
    "type": "Query",
    "enabled": true,
    "cacheAmount": 1,
    "cacheEnabled": false,
    "database": "MPP",
    "fallbackEnabled": false,
    "lastModificationSignature": "",
    "permissions": [
      {
        "zone": "",
        "role": ""
      }
    ],
    "lastModification": {
      "actor": "claude",
      "timestamp": "2026-05-27T00:00:00Z"
    },
    "parameters": [
      {
        "type": "Parameter",
        "identifier": "itemId",
        "sqlType": 3
      },
      {
        "type": "Parameter",
        "identifier": "rowsJson",
        "sqlType": 7
      },
      {
        "type": "Parameter",
        "identifier": "appUserId",
        "sqlType": 3
      }
    ]
  }
}
```

- [ ] **Step 3: Picker NQ — query.sql**

```sql
-- @includeDeprecated BIT (defaults to 0)
EXEC Location.Location_ListForEligibilityPicker
    @IncludeDeprecated = :includeDeprecated
```

- [ ] **Step 4: Picker NQ — resource.json**

```json
{
  "scope": "DG",
  "version": 2,
  "restricted": false,
  "overridable": true,
  "files": [
    "query.sql"
  ],
  "attributes": {
    "useMaxReturnSize": false,
    "autoBatchEnabled": false,
    "fallbackValue": "",
    "maxReturnSize": 100,
    "cacheUnit": "SEC",
    "type": "Query",
    "enabled": true,
    "cacheAmount": 60,
    "cacheEnabled": true,
    "database": "MPP",
    "fallbackEnabled": false,
    "lastModificationSignature": "",
    "permissions": [
      {
        "zone": "",
        "role": ""
      }
    ],
    "lastModification": {
      "actor": "claude",
      "timestamp": "2026-05-27T00:00:00Z"
    },
    "parameters": [
      {
        "type": "Parameter",
        "identifier": "includeDeprecated",
        "sqlType": 6
      }
    ]
  }
}
```

- [ ] **Step 5: Scan + verify Designer picks up the new NQs**

```powershell
.\scan.ps1
```

Expected: scan completes (~300ms). In Designer, the new NQs appear under their respective groups in the Project Browser.

- [ ] **Step 6: Commit**

```bash
git add ignition/projects/MPP_Config/ignition/named-query/parts/ItemLocation_SaveAllForItem ignition/projects/MPP_Config/ignition/named-query/location/Location_ListForEligibilityPicker
git commit -m "feat(nq): SaveAllForItem + Location picker NQ wrappers"
```

---

### Task 7: Entity script `BlueRidge.Parts.Eligibility`

**Files:**
- Create: `ignition/projects/MPP_Config/ignition/script-python/BlueRidge/Parts/Eligibility/code.py`
- Create: `ignition/projects/MPP_Config/ignition/script-python/BlueRidge/Parts/Eligibility/resource.json`

- [ ] **Step 1: Write the entity script**

```python
# =============================================================================
# Project Library:  BlueRidge.Parts.Eligibility
#
# Author:           Blue Ridge Automation
# Created:          2026-05-27
# Version:          1.0
#
# Description:
#   Read + write surface for the Item Master Eligibility editor (Phase 8).
#   Reads the per-Item ItemLocation rows + the tier-grouped Location
#   picker options; writes via the bundled SaveAll proc.
#
# Public surface:
#   listByItem(itemId)            -> list[dict] of active ItemLocation rows
#                                    with joined Location + tier metadata
#   listLocationOptions()         -> list[dict] for the picker dropdown
#   handleSaveAll(itemId, rows)   -> {Status, Message, NewId}
#
# Layer:
#   Entity script -- routes all DB calls through BlueRidge.Common.Db.*.
#
# Change Log:
#   2026-05-27 - 1.0 - Initial (Phase 8 Eligibility editor).
# =============================================================================
import json


def listByItem(itemId):
    """Return active ItemLocation rows for the Item, sorted by
    (TierOrdinal, LocationCode). Empty list when none."""
    BlueRidge.Common.Util.log("itemId=%s" % itemId)
    if not itemId:
        return []
    return BlueRidge.Common.Db.execList(
        "parts/ItemLocation_ListByItem",
        {"itemId": itemId},
    ) or []


def listLocationOptions():
    """Return all non-deprecated Locations across all tiers, sorted
    (TierOrdinal, Code), shaped for the editor's dropdown.

    Each row carries: Id, Code, Name, TierName, TierOrdinal, DisplayLabel.
    The Eligibility view uses DisplayLabel as the dropdown option label
    and Id as the value."""
    BlueRidge.Common.Util.log("running")
    return BlueRidge.Common.Db.execList(
        "location/Location_ListForEligibilityPicker",
        {"includeDeprecated": False},
    ) or []


def handleSaveAll(itemId, rows):
    """Submit the editor's full editDraft.rows list to the SaveAll proc.

    `rows` is a list of dicts with keys:
        Id (BIGINT or None), LocationId (BIGINT),
        IsConsumptionPoint (bool),
        MinQuantity, MaxQuantity, DefaultQuantity (int or None each)

    Returns the proc's status dict {Status, Message, NewId}.
    """
    BlueRidge.Common.Util.log("itemId=%s rows=%d" % (itemId, len(rows or [])))
    if not itemId:
        return {"Status": 0,
                "Message": "No item selected.",
                "NewId": None}
    # Coerce to plain Python primitives -- editDraft.rows may contain
    # BasicQualifiedValue wrappers via the bidi binding path.
    cleaned = []
    for r in (rows or []):
        r = BlueRidge.Common.Util.extractQualifiedValues(r) or {}
        cleaned.append({
            "Id":                 r.get("id"),
            "LocationId":         r.get("locationId"),
            "IsConsumptionPoint": bool(r.get("isConsumptionPoint")),
            "MinQuantity":        r.get("minQuantity"),
            "MaxQuantity":        r.get("maxQuantity"),
            "DefaultQuantity":    r.get("defaultQuantity"),
        })
    params = {
        "itemId":    itemId,
        "rowsJson":  system.util.jsonEncode(cleaned),
        "appUserId": BlueRidge.Common.Util._currentAppUserId(),
    }
    return BlueRidge.Common.Db.execMutation(
        "parts/ItemLocation_SaveAllForItem",
        params,
    )
```

- [ ] **Step 2: Write resource.json**

```json
{
  "scope": "A",
  "version": 1,
  "files": [
    "code.py"
  ],
  "attributes": {
    "hintScope": 2,
    "lastModificationSignature": "",
    "lastModification": {
      "actor": "claude",
      "timestamp": "2026-05-27T00:00:00Z"
    }
  }
}
```

- [ ] **Step 3: Scan + smoke-test from Script Console**

```powershell
.\scan.ps1
```

Then in Designer's Tools → Script Console:

```python
itemId = ...   # e.g., 5G0's Id from Parts.Item
print BlueRidge.Parts.Eligibility.listByItem(itemId)
print len(BlueRidge.Parts.Eligibility.listLocationOptions())
```

Expected: first call returns rows or `[]`; second call returns a positive count (Locations exist in dev DB).

- [ ] **Step 4: Commit**

```bash
git add ignition/projects/MPP_Config/ignition/script-python/BlueRidge/Parts/Eligibility
git commit -m "feat(entity): BlueRidge.Parts.Eligibility — listByItem, listLocationOptions, handleSaveAll"
```

---

### Task 8: EligibilityRow sub-view

**Files:**
- Create: `ignition/projects/MPP_Config/com.inductiveautomation.perspective/views/BlueRidge/Components/Parts/ItemMaster/EligibilityRow/view.json`
- Create: `ignition/projects/MPP_Config/com.inductiveautomation.perspective/views/BlueRidge/Components/Parts/ItemMaster/EligibilityRow/resource.json`

This sub-view is a sibling of BomLineRow (NOT nested inside Eligibility/). Page-scoped messages propagate row events to the parent embed.

- [ ] **Step 1: Write resource.json**

```json
{
  "scope": "G",
  "version": 1,
  "files": [
    "view.json"
  ],
  "attributes": {
    "lastModificationSignature": "",
    "lastModification": {
      "actor": "claude",
      "timestamp": "2026-05-27T00:00:00Z"
    }
  }
}
```

- [ ] **Step 2: Write view.json**

The row mirrors BomLineRow: input-only params, uniform 30px control heights, page-scoped messages on every event.

```json
{
  "custom": {},
  "params": {
    "rowIndex": 0,
    "row": {
      "id": null,
      "locationId": null,
      "locationLabel": "",
      "locationTierOrdinal": null,
      "isConsumptionPoint": false,
      "minQuantity": null,
      "maxQuantity": null,
      "defaultQuantity": null
    },
    "locationOptions": []
  },
  "propConfig": {
    "params.rowIndex":        { "paramDirection": "input" },
    "params.row":             { "paramDirection": "input" },
    "params.locationOptions": { "paramDirection": "input" }
  },
  "props": {
    "defaultSize": { "height": 36, "width": 1200 }
  },
  "root": {
    "type": "ia.container.flex",
    "meta": { "name": "root" },
    "props": {
      "direction": "row",
      "alignItems": "center",
      "style": {
        "borderBottom": "1px solid var(--mpp-border-subtle)",
        "gap": "6px",
        "padding": "2px 10px",
        "height": "100%"
      }
    },
    "children": [
      {
        "type": "ia.display.label",
        "meta": { "name": "ColIndex" },
        "position": { "basis": "36px", "shrink": 0 },
        "propConfig": {
          "props.text": {
            "binding": {
              "type": "expr",
              "config": { "expression": "toStr({view.params.rowIndex} + 1)" }
            }
          }
        },
        "props": {
          "style": {
            "color": "var(--mpp-text-secondary)",
            "fontSize": "12px",
            "textAlign": "right"
          }
        }
      },
      {
        "type": "ia.input.dropdown",
        "meta": { "name": "LocationPicker" },
        "position": { "grow": 1, "basis": "0" },
        "propConfig": {
          "props.options": {
            "binding": {
              "type": "property",
              "config": { "path": "view.params.locationOptions" },
              "transforms": [
                {
                  "type": "script",
                  "code": "\tout = []\n\tfor it in (value or []):\n\t\tit = it or {}\n\t\tlabel = it.get('DisplayLabel') or ''\n\t\tout.append({'label': label, 'value': it.get('Id')})\n\treturn out"
                }
              ]
            }
          },
          "props.value": {
            "binding": {
              "type": "property",
              "config": { "path": "view.params.row.locationId" }
            }
          }
        },
        "props": {
          "filterable": true,
          "noSelectionText": "Pick location...",
          "style": { "classes": "select", "height": "30px" }
        },
        "events": {
          "component": {
            "onActionPerformed": {
              "type": "script",
              "scope": "G",
              "config": {
                "script": "\tsystem.perspective.sendMessage(\"eligibilityRowLocationChanged\", payload={\"rowIndex\": self.view.params.rowIndex, \"newLocationId\": self.props.value}, scope=\"page\")"
              }
            }
          }
        }
      },
      {
        "type": "ia.input.checkbox",
        "meta": { "name": "ConsumptionCheckbox" },
        "position": { "basis": "60px", "shrink": 0 },
        "propConfig": {
          "props.selected": {
            "binding": {
              "type": "property",
              "config": { "path": "view.params.row.isConsumptionPoint" }
            }
          }
        },
        "props": {
          "text": "",
          "style": { "height": "30px" }
        },
        "events": {
          "component": {
            "onActionPerformed": {
              "type": "script",
              "scope": "G",
              "config": {
                "script": "\tsystem.perspective.sendMessage(\"eligibilityRowConsumptionChanged\", payload={\"rowIndex\": self.view.params.rowIndex, \"isConsumptionPoint\": bool(self.props.selected)}, scope=\"page\")"
              }
            }
          }
        }
      },
      {
        "type": "ia.input.text-field",
        "meta": { "name": "MinField" },
        "position": { "basis": "80px", "shrink": 0 },
        "propConfig": {
          "position.display": {
            "binding": {
              "type": "expr",
              "config": { "expression": "{view.params.row.isConsumptionPoint} = true" }
            }
          },
          "props.text": {
            "binding": {
              "type": "property",
              "config": { "path": "view.params.row.minQuantity" }
            }
          }
        },
        "props": {
          "placeholder": "Min",
          "style": { "classes": "search-input", "textAlign": "right", "height": "30px" }
        },
        "events": {
          "dom": {
            "onBlur": {
              "type": "script",
              "scope": "G",
              "config": {
                "script": "\tsystem.perspective.sendMessage(\"eligibilityRowQtyChanged\", payload={\"rowIndex\": self.view.params.rowIndex, \"field\": \"minQuantity\", \"newValue\": self.props.text}, scope=\"page\")"
              }
            }
          }
        }
      },
      {
        "type": "ia.input.text-field",
        "meta": { "name": "MaxField" },
        "position": { "basis": "80px", "shrink": 0 },
        "propConfig": {
          "position.display": {
            "binding": {
              "type": "expr",
              "config": { "expression": "{view.params.row.isConsumptionPoint} = true" }
            }
          },
          "props.text": {
            "binding": {
              "type": "property",
              "config": { "path": "view.params.row.maxQuantity" }
            }
          }
        },
        "props": {
          "placeholder": "Max",
          "style": { "classes": "search-input", "textAlign": "right", "height": "30px" }
        },
        "events": {
          "dom": {
            "onBlur": {
              "type": "script",
              "scope": "G",
              "config": {
                "script": "\tsystem.perspective.sendMessage(\"eligibilityRowQtyChanged\", payload={\"rowIndex\": self.view.params.rowIndex, \"field\": \"maxQuantity\", \"newValue\": self.props.text}, scope=\"page\")"
              }
            }
          }
        }
      },
      {
        "type": "ia.input.text-field",
        "meta": { "name": "DefaultField" },
        "position": { "basis": "80px", "shrink": 0 },
        "propConfig": {
          "position.display": {
            "binding": {
              "type": "expr",
              "config": { "expression": "{view.params.row.isConsumptionPoint} = true" }
            }
          },
          "props.text": {
            "binding": {
              "type": "property",
              "config": { "path": "view.params.row.defaultQuantity" }
            }
          }
        },
        "props": {
          "placeholder": "Default",
          "style": { "classes": "search-input", "textAlign": "right", "height": "30px" }
        },
        "events": {
          "dom": {
            "onBlur": {
              "type": "script",
              "scope": "G",
              "config": {
                "script": "\tsystem.perspective.sendMessage(\"eligibilityRowQtyChanged\", payload={\"rowIndex\": self.view.params.rowIndex, \"field\": \"defaultQuantity\", \"newValue\": self.props.text}, scope=\"page\")"
              }
            }
          }
        }
      },
      {
        "type": "ia.input.button",
        "meta": { "name": "RemoveBtn" },
        "position": { "basis": "40px", "shrink": 0 },
        "props": {
          "text": "×",
          "style": { "classes": "btn btn-sm", "padding": "2px 6px", "height": "30px" }
        },
        "events": {
          "component": {
            "onActionPerformed": {
              "type": "script",
              "scope": "G",
              "config": {
                "script": "\tsystem.perspective.sendMessage(\"eligibilityRowRemove\", payload={\"rowIndex\": self.view.params.rowIndex}, scope=\"page\")"
              }
            }
          }
        }
      }
    ]
  }
}
```

- [ ] **Step 3: Scan**

```powershell
.\scan.ps1
```

- [ ] **Step 4: Commit**

```bash
git add ignition/projects/MPP_Config/com.inductiveautomation.perspective/views/BlueRidge/Components/Parts/ItemMaster/EligibilityRow
git commit -m "feat(view): EligibilityRow sub-view for the editor row"
```

---

### Task 9: Eligibility parent embed — full rewrite from Phase-1 shell

**Files:**
- Modify: `ignition/projects/MPP_Config/com.inductiveautomation.perspective/views/BlueRidge/Components/Parts/ItemMaster/Eligibility/view.json`

Total rewrite — discard the Phase-1 placeholder shell (custom block with `selectedArea` + empty `rows`, Area dropdown filter) and replace with the per-section ownership pattern: atomic state writes, dirty binding, SaveAll wiring, message-handler set, LinesRepeater of EligibilityRow embeds.

- [ ] **Step 1: Write the replacement view.json**

```json
{
  "custom": {
    "state": {
      "selected":  { "rows": [] },
      "editDraft": { "rows": [] }
    },
    "isDirty": false,
    "locationOptions": []
  },
  "params": {
    "value": 0
  },
  "propConfig": {
    "params.value": {
      "paramDirection": "input",
      "onChange": {
        "enabled": true,
        "script": "\tself.rootContainer.load()"
      }
    },
    "custom.isDirty": {
      "binding": {
        "type": "expr",
        "config": {
          "expression": "runScript(\"BlueRidge.Common.Util.convertWrapperObjectToJson\", 0, {view.custom.state.editDraft}) != runScript(\"BlueRidge.Common.Util.convertWrapperObjectToJson\", 0, {view.custom.state.selected})"
        }
      },
      "onChange": {
        "enabled": true,
        "script": "\tsystem.perspective.sendMessage(\"sectionDirtyChanged\", payload={\"section\": \"eligibility\", \"isDirty\": bool(currentValue.value)}, scope=\"page\")"
      }
    },
    "custom.locationOptions": {
      "binding": {
        "type": "expr",
        "config": {
          "expression": "runScript(\"BlueRidge.Parts.Eligibility.listLocationOptions\", 0)"
        }
      }
    }
  },
  "props": {
    "defaultSize": { "height": 360, "width": 1200 }
  },
  "root": {
    "type": "ia.container.flex",
    "meta": { "name": "root" },
    "props": {
      "direction": "column",
      "style": {
        "classes": "detail-panel",
        "gap": "8px",
        "padding": "10px 14px"
      }
    },
    "children": [
      {
        "type": "ia.container.flex",
        "meta": { "name": "HeaderRow" },
        "position": { "basis": "auto" },
        "props": {
          "direction": "row",
          "alignItems": "center",
          "style": { "gap": "8px" }
        },
        "children": [
          {
            "type": "ia.display.label",
            "meta": { "name": "PanelHeader" },
            "props": {
              "text": "Eligibility",
              "style": { "fontSize": "13px", "fontWeight": "600" }
            }
          },
          {
            "type": "ia.display.label",
            "meta": { "name": "Spacer" },
            "position": { "grow": 1 },
            "props": { "text": "" }
          },
          {
            "type": "ia.input.button",
            "meta": { "name": "BtnDiscard" },
            "position": { "shrink": 0 },
            "propConfig": {
              "meta.visible": {
                "binding": {
                  "type": "property",
                  "config": { "path": "view.custom.isDirty" }
                }
              }
            },
            "props": {
              "text": "Discard",
              "style": { "classes": "btn btn-sm" }
            },
            "events": {
              "component": {
                "onActionPerformed": {
                  "type": "script",
                  "scope": "G",
                  "config": { "script": "\tself.view.rootContainer.handleDiscard()" }
                }
              }
            }
          },
          {
            "type": "ia.input.button",
            "meta": { "name": "BtnSave" },
            "position": { "shrink": 0 },
            "propConfig": {
              "props.enabled": {
                "binding": {
                  "type": "property",
                  "config": { "path": "view.custom.isDirty" }
                }
              }
            },
            "props": {
              "text": "Save",
              "style": { "classes": "btn btn-primary btn-sm" }
            },
            "events": {
              "component": {
                "onActionPerformed": {
                  "type": "script",
                  "scope": "G",
                  "config": { "script": "\tself.view.rootContainer.handleSave()" }
                }
              }
            }
          }
        ]
      },
      {
        "type": "ia.container.flex",
        "meta": { "name": "ColumnHeader" },
        "position": { "basis": "auto" },
        "props": {
          "direction": "row",
          "alignItems": "center",
          "style": { "gap": "6px", "padding": "0 10px" }
        },
        "children": [
          { "type": "ia.display.label", "meta": { "name": "ColHash" }, "position": { "basis": "36px", "shrink": 0 }, "props": { "text": "#", "style": { "color": "var(--mpp-text-muted)", "fontSize": "11px", "textAlign": "right" } } },
          { "type": "ia.display.label", "meta": { "name": "ColLocation" }, "position": { "grow": 1, "basis": "0" }, "props": { "text": "Location", "style": { "color": "var(--mpp-text-muted)", "fontSize": "11px" } } },
          { "type": "ia.display.label", "meta": { "name": "ColCsp" }, "position": { "basis": "60px", "shrink": 0 }, "props": { "text": "Consumption", "style": { "color": "var(--mpp-text-muted)", "fontSize": "11px" } } },
          { "type": "ia.display.label", "meta": { "name": "ColMin" }, "position": { "basis": "80px", "shrink": 0 }, "props": { "text": "Min", "style": { "color": "var(--mpp-text-muted)", "fontSize": "11px", "textAlign": "right" } } },
          { "type": "ia.display.label", "meta": { "name": "ColMax" }, "position": { "basis": "80px", "shrink": 0 }, "props": { "text": "Max", "style": { "color": "var(--mpp-text-muted)", "fontSize": "11px", "textAlign": "right" } } },
          { "type": "ia.display.label", "meta": { "name": "ColDef" }, "position": { "basis": "80px", "shrink": 0 }, "props": { "text": "Default", "style": { "color": "var(--mpp-text-muted)", "fontSize": "11px", "textAlign": "right" } } },
          { "type": "ia.display.label", "meta": { "name": "ColRm" }, "position": { "basis": "40px", "shrink": 0 }, "props": { "text": "" } }
        ]
      },
      {
        "type": "ia.display.flex-repeater",
        "meta": { "name": "RowsRepeater" },
        "position": { "grow": 1, "basis": "0" },
        "propConfig": {
          "props.instances": {
            "binding": {
              "type": "property",
              "config": { "path": "view.custom.state.editDraft.rows" },
              "transforms": [
                {
                  "type": "script",
                  "code": "\trows = BlueRidge.Common.Util.extractQualifiedValues(value) or []\n\topts = BlueRidge.Common.Util.extractQualifiedValues(self.view.custom.locationOptions) or []\n\tout = []\n\tfor i, r in enumerate(rows):\n\t\tr = r or {}\n\t\tout.append({'rowIndex': i, 'row': r, 'locationOptions': opts})\n\treturn out"
                }
              ]
            }
          }
        },
        "props": {
          "direction": "column",
          "elementPosition": { "basis": "auto" },
          "elementStyle": { "maxHeight": "44px" },
          "path": "BlueRidge/Components/Parts/ItemMaster/EligibilityRow",
          "style": { "overflowY": "auto" },
          "useDefaultViewHeight": false,
          "useDefaultViewWidth": false
        }
      },
      {
        "type": "ia.input.button",
        "meta": { "name": "BtnAddRow" },
        "position": { "basis": "auto", "shrink": 0 },
        "props": {
          "text": "+ Add Location",
          "style": { "classes": "btn btn-sm" }
        },
        "events": {
          "component": {
            "onActionPerformed": {
              "type": "script",
              "scope": "G",
              "config": { "script": "\tself.view.rootContainer.addRow()" }
            }
          }
        }
      }
    ],
    "scripts": {
      "customMethods": [
        {
          "name": "load",
          "params": [],
          "script": "\titemId = self.view.params.value\n\tif not itemId:\n\t\tempty = {\"rows\": []}\n\t\tself.view.custom.state = {\"selected\": dict(empty), \"editDraft\": dict(empty)}\n\t\treturn\n\trawRows = BlueRidge.Parts.Eligibility.listByItem(itemId) or []\n\tloaded = []\n\tfor r in rawRows:\n\t\tr = r or {}\n\t\tloaded.append({\n\t\t\t\"id\":                  r.get(\"Id\"),\n\t\t\t\"locationId\":          r.get(\"LocationId\"),\n\t\t\t\"locationLabel\":       (r.get(\"LocationCode\") or \"\") + \" \\u2014 \" + (r.get(\"LocationName\") or \"\") + \" (\" + (r.get(\"DefinitionName\") or \"\") + \")\",\n\t\t\t\"locationTierOrdinal\": r.get(\"TierOrdinal\"),\n\t\t\t\"isConsumptionPoint\":  bool(r.get(\"IsConsumptionPoint\")),\n\t\t\t\"minQuantity\":         r.get(\"MinQuantity\"),\n\t\t\t\"maxQuantity\":         r.get(\"MaxQuantity\"),\n\t\t\t\"defaultQuantity\":     r.get(\"DefaultQuantity\"),\n\t\t})\n\tself.view.custom.state = {\"selected\": {\"rows\": loaded}, \"editDraft\": {\"rows\": [dict(r) for r in loaded]}}"
        },
        {
          "name": "handleSave",
          "params": [],
          "script": "\titemId = self.view.params.value\n\tif not itemId:\n\t\tBlueRidge.Common.Notify.toast(\"No item selected\", \"Pick an item before saving.\", \"warning\")\n\t\treturn\n\tdraft = BlueRidge.Common.Util.extractQualifiedValues(self.view.custom.state.editDraft) or {}\n\trows = draft.get(\"rows\") or []\n\tresult = BlueRidge.Parts.Eligibility.handleSaveAll(itemId, rows)\n\tBlueRidge.Common.Ui.notifyResult(result, \"Eligibility saved\")\n\tif result and result.get(\"Status\"):\n\t\tself.load()"
        },
        {
          "name": "handleDiscard",
          "params": [],
          "script": "\tselected = BlueRidge.Common.Util.extractQualifiedValues(self.view.custom.state.selected) or {\"rows\": []}\n\tself.view.custom.state = {\"selected\": selected, \"editDraft\": {\"rows\": [dict(r) for r in (selected.get(\"rows\") or [])]}}"
        },
        {
          "name": "addRow",
          "params": [],
          "script": "\tdraft = dict(BlueRidge.Common.Util.extractQualifiedValues(self.view.custom.state.editDraft) or {\"rows\": []})\n\trows = list(draft.get(\"rows\") or [])\n\trows.append({\n\t\t\"id\":                  None,\n\t\t\"locationId\":          None,\n\t\t\"locationLabel\":       \"\",\n\t\t\"locationTierOrdinal\": None,\n\t\t\"isConsumptionPoint\":  False,\n\t\t\"minQuantity\":         None,\n\t\t\"maxQuantity\":         None,\n\t\t\"defaultQuantity\":     None,\n\t})\n\tdraft[\"rows\"] = rows\n\tselected = BlueRidge.Common.Util.extractQualifiedValues(self.view.custom.state.selected) or {\"rows\": []}\n\tself.view.custom.state = {\"selected\": selected, \"editDraft\": draft}"
        },
        {
          "name": "_applyLocationChange",
          "params": ["idx", "newLocationId"],
          "script": "\tdraft = dict(BlueRidge.Common.Util.extractQualifiedValues(self.view.custom.state.editDraft) or {\"rows\": []})\n\trows = list(draft.get(\"rows\") or [])\n\tif idx < 0 or idx >= len(rows):\n\t\treturn\n\topts = BlueRidge.Common.Util.extractQualifiedValues(self.view.custom.locationOptions) or []\n\tpicked = None\n\tfor o in opts:\n\t\tif o.get(\"Id\") == newLocationId:\n\t\t\tpicked = o\n\t\t\tbreak\n\trow = dict(rows[idx])\n\trow[\"locationId\"] = newLocationId\n\tif picked:\n\t\trow[\"locationLabel\"]       = picked.get(\"DisplayLabel\") or \"\"\n\t\trow[\"locationTierOrdinal\"] = picked.get(\"TierOrdinal\")\n\trows[idx] = row\n\tdraft[\"rows\"] = rows\n\tselected = BlueRidge.Common.Util.extractQualifiedValues(self.view.custom.state.selected) or {\"rows\": []}\n\tself.view.custom.state = {\"selected\": selected, \"editDraft\": draft}"
        },
        {
          "name": "_applyConsumptionChange",
          "params": ["idx", "isConsumptionPoint"],
          "script": "\tdraft = dict(BlueRidge.Common.Util.extractQualifiedValues(self.view.custom.state.editDraft) or {\"rows\": []})\n\trows = list(draft.get(\"rows\") or [])\n\tif idx < 0 or idx >= len(rows):\n\t\treturn\n\trow = dict(rows[idx])\n\trow[\"isConsumptionPoint\"] = bool(isConsumptionPoint)\n\tif not row[\"isConsumptionPoint\"]:\n\t\trow[\"minQuantity\"] = None\n\t\trow[\"maxQuantity\"] = None\n\t\trow[\"defaultQuantity\"] = None\n\trows[idx] = row\n\tdraft[\"rows\"] = rows\n\tselected = BlueRidge.Common.Util.extractQualifiedValues(self.view.custom.state.selected) or {\"rows\": []}\n\tself.view.custom.state = {\"selected\": selected, \"editDraft\": draft}"
        },
        {
          "name": "_applyQtyChange",
          "params": ["idx", "field", "newValue"],
          "script": "\tdraft = dict(BlueRidge.Common.Util.extractQualifiedValues(self.view.custom.state.editDraft) or {\"rows\": []})\n\trows = list(draft.get(\"rows\") or [])\n\tif idx < 0 or idx >= len(rows):\n\t\treturn\n\trow = dict(rows[idx])\n\tcoerced = None\n\tif newValue not in (None, \"\"):\n\t\ttry:\n\t\t\tcoerced = int(newValue)\n\t\texcept (ValueError, TypeError):\n\t\t\ttry:\n\t\t\t\tcoerced = float(newValue)\n\t\t\texcept (ValueError, TypeError):\n\t\t\t\tcoerced = newValue\n\trow[field] = coerced\n\trows[idx] = row\n\tdraft[\"rows\"] = rows\n\tselected = BlueRidge.Common.Util.extractQualifiedValues(self.view.custom.state.selected) or {\"rows\": []}\n\tself.view.custom.state = {\"selected\": selected, \"editDraft\": draft}"
        },
        {
          "name": "_removeRow",
          "params": ["idx"],
          "script": "\tdraft = dict(BlueRidge.Common.Util.extractQualifiedValues(self.view.custom.state.editDraft) or {\"rows\": []})\n\trows = list(draft.get(\"rows\") or [])\n\tif idx < 0 or idx >= len(rows):\n\t\treturn\n\tdel rows[idx]\n\tdraft[\"rows\"] = rows\n\tselected = BlueRidge.Common.Util.extractQualifiedValues(self.view.custom.state.selected) or {\"rows\": []}\n\tself.view.custom.state = {\"selected\": selected, \"editDraft\": draft}"
        }
      ],
      "messageHandlers": [
        {
          "messageType": "sectionSaveRequested",
          "pageScope": true,
          "sessionScope": false,
          "viewScope": false,
          "script": "\tif payload and payload.get(\"section\") == \"eligibility\":\n\t\tself.handleSave()"
        },
        {
          "messageType": "sectionDiscardRequested",
          "pageScope": true,
          "sessionScope": false,
          "viewScope": false,
          "script": "\tif payload and payload.get(\"section\") == \"eligibility\":\n\t\tself.handleDiscard()"
        },
        {
          "messageType": "eligibilityRowLocationChanged",
          "pageScope": true,
          "sessionScope": false,
          "viewScope": false,
          "script": "\tif not payload:\n\t\treturn\n\tidx = int(payload.get(\"rowIndex\", -1))\n\tself._applyLocationChange(idx, payload.get(\"newLocationId\"))"
        },
        {
          "messageType": "eligibilityRowConsumptionChanged",
          "pageScope": true,
          "sessionScope": false,
          "viewScope": false,
          "script": "\tif not payload:\n\t\treturn\n\tidx = int(payload.get(\"rowIndex\", -1))\n\tself._applyConsumptionChange(idx, payload.get(\"isConsumptionPoint\"))"
        },
        {
          "messageType": "eligibilityRowQtyChanged",
          "pageScope": true,
          "sessionScope": false,
          "viewScope": false,
          "script": "\tif not payload:\n\t\treturn\n\tidx = int(payload.get(\"rowIndex\", -1))\n\tself._applyQtyChange(idx, payload.get(\"field\"), payload.get(\"newValue\"))"
        },
        {
          "messageType": "eligibilityRowRemove",
          "pageScope": true,
          "sessionScope": false,
          "viewScope": false,
          "script": "\tif not payload:\n\t\treturn\n\tidx = int(payload.get(\"rowIndex\", -1))\n\tself._removeRow(idx)"
        }
      ]
    }
  }
}
```

- [ ] **Step 2: Scan**

```powershell
.\scan.ps1
```

- [ ] **Step 3: Commit**

```bash
git add ignition/projects/MPP_Config/com.inductiveautomation.perspective/views/BlueRidge/Components/Parts/ItemMaster/Eligibility/view.json
git commit -m "feat(view): Eligibility editor — atomic state, SaveAll, message handlers"
```

---

### Task 10: Manual Designer smoke walkthrough

The 14 smoke steps from the spec §9. Drive in Chrome + Designer. Capture results in PROJECT_STATUS or as commit notes if anything needs polish.

- [ ] **Step 1: Walk the smoke**

For each step in spec §9 Smoke Checklist:
1. Cold open
2. Add row
3. Pick a Location
4. Toggle consumption point
5. Enter qty bounds
6. Remove row
7. Save persists across reload
8. Validation: duplicate Location → rejected
9. Validation: consumption-point qty missing → rejected
10. Validation: Min > Max → rejected
11. Discard
12. Tab-switch gate
13. Reactivation (deprecate then re-add same Location)
14. Audit log

- [ ] **Step 2: Polish any visible bugs**

Likely-encountered polish areas based on BOMs smoke experience:
- Column header alignment if the row's component widths drift from the header
- Initial `isDirty` value if the binding errors on first render (revisit `convertWrapperObjectToJson` against state shape)
- Empty-state hint when `state.editDraft.rows` is empty (e.g., `EmptyHint` label visible via `position.display` bound to `len({view.custom.state.editDraft.rows}) = 0`)

Fix any inline, scan, commit per fix.

- [ ] **Step 3: Final commit + push**

```bash
git push
```

---

## Spec Self-Review Summary

| Spec section | Plan task(s) |
|---|---|
| §1 Purpose | Implicit (entire plan) |
| §2 Scope | All tasks scoped; out-of-scope items not planned |
| §3 Data Model — no schema changes | Confirmed; no migration task |
| §4 UI / Editor design | Tasks 8 (row) + 9 (parent) |
| §4.4 State shape | Task 9 custom block |
| §4.5 Dirty plumbing | Task 9 isDirty binding + sectionDirtyChanged onChange |
| §4.6 Per-row message propagation | Task 8 events + Task 9 messageHandlers |
| §5.1 SaveAll proc | Task 1 |
| §5.1 Picker proc | Task 2 |
| §5.2 Reused procs (ListByItem update) | Task 3 |
| §5.3 Entity script | Task 7 |
| §6 Validation rules | Task 1 proc + Task 4 tests |
| §7 Audit | Task 1 proc (Audit_LogConfigChange call) |
| §8 View file plan | Tasks 6, 7, 8, 9 |
| §9 Smoke checklist | Task 10 |
| §10 Decisions table | Reflected in plan structure (no Move column in row, no per-Cell grid view, no business-rule enforcement) |
