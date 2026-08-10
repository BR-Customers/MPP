# Assembly-OUT multi-printer FG routing ("printer cards") — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let a By-Count assembly-out station bind each finished good to its own child printer via a card panel, so completing an FG's box routes that box's shipping label to the FG's printer.

**Architecture:** New `Location.PrinterFgAssignment` table stores the FG↔printer binding (1:1 per station, by identity). A card panel in `AssemblyNonSerialized` is both setup (assign/swap/reorder + validate endpoint) and run surface (per-card Complete Tray + Complete box). `ShippingDispatcher.dispatch` gains a `printerLocationId` override so the box's shipping label prints on the card's printer (endpoint derived at dispatch from the new `Location.Printer_GetById`).

**Tech Stack:** SQL Server 2022 (versioned + repeatable migrations, `test.*` T-SQL harness), Ignition Perspective (file-based `view.json`), Jython script modules under `BlueRidge.*`, Core named queries.

## Global Constraints

- SQL: `UpperCamelCase`; `BIGINT IDENTITY` `Id` PKs; `NVARCHAR`; `DATETIME2(3)` UTC via `GETUTCDATETIME()`; enum/status columns FK to code tables; append-only where applicable. Source: `sql_best_practices_mes.md`.
- FDS-11-011: **no OUTPUT params.** Read procs = one result set (empty = not found). Mutation procs end every exit path with `SELECT @Status AS Status, @Message AS Message[, @NewId AS NewId];` (`@Status` BIT 1/0). Audit writers emit no result set.
- Mutation NQ `resource.json` `type` = `"Query"` (proc ends in a `SELECT @Status…`); read NQ `type` = `"Query"`. `sqlType`: `3` = BIGINT, `7` = NVARCHAR, `2` = INT (Designer enum, per `ignition-context-pack/04_named_queries.md`). Hand-authored NQ resource.json use `version: 2`.
- Scripts: views call entity scripts; entity scripts call `BlueRidge.Common.Db.*`; only Common calls `system.db.*`. Never-throw guards catch `(Exception, java.lang.Exception)`.
- Ignition: after any resource change run `.\scan.ps1`. Existing-view file edits only while Designer is CLOSED. Event-script bodies start with a leading `\t`. No drag-and-drop (up/down arrows). ASCII-only in any SQL string literal / ZPL.
- Git: branch `jacques/working`; stage explicit paths only (never `-A`/`-u`); no `Co-Authored-By` trailer.
- DB validation: reset a **uniquely-named throwaway** (e.g. `MPP_MES_PrinterCards`) via `sql/tests/Run-Tests.ps1 -DatabaseName MPP_MES_PrinterCards -Filter <name>`; never reset `MPP_MES_Dev`. Repeatable procs/functions may be applied to live `MPP_MES_Dev` with `sqlcmd -S localhost -d MPP_MES_Dev -C -b -I -i <file>` (idempotent CREATE OR ALTER).
- **Versioned migration number:** use the next free ≥ `0052` (`0051` is taken). Confirm no collision at execution — `ls sql/migrations/versioned/`.
- Reference audit call args from `R__Location_LocationTypeDefinition_SaveAll.sql`. Confirmed code-table values: `Audit.LogEntityType` has `(Id, Code, Name, Description)`; event code `Updated` exists; `Location.AppUser(Id)` is the user table; `Parts.v_EffectiveItemLocation` exists; FinishedGood `ItemType.Code = N'FinishedGood'`.

---

## Task 1: `Location.PrinterFgAssignment` table + audit entity type (migration 0052)

**Files:**
- Create: `sql/migrations/versioned/0052_printer_fg_assignment.sql`
- Test: `sql/tests/0029_AssemblyPrinterCards/010_PrinterFgAssignment_schema.sql`

**Interfaces:**
- Produces: table `Location.PrinterFgAssignment (Id, PrinterLocationId, ItemId, SortOrder, CreatedAt, CreatedByAppUserId, LastEditedAt, LastEditedByAppUserId)`; `UNIQUE(PrinterLocationId)`; index `IX_PrinterFgAssignment_Item`; `Audit.LogEntityType` code `PrinterFgAssignment`.

- [ ] **Step 1: Write the failing test**

Create `sql/tests/0029_AssemblyPrinterCards/010_PrinterFgAssignment_schema.sql`:

```sql
SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0029_AssemblyPrinterCards/010_PrinterFgAssignment_schema.sql';
GO
DECLARE @tbl NVARCHAR(1) = CASE WHEN OBJECT_ID(N'Location.PrinterFgAssignment') IS NOT NULL THEN N'1' ELSE N'0' END;
EXEC test.Assert_IsEqual @TestName = N'[Schema] PrinterFgAssignment table exists', @Expected = N'1', @Actual = @tbl;
DECLARE @ux NVARCHAR(1) = CASE WHEN EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'UX_PrinterFgAssignment_Printer' AND is_unique = 1) THEN N'1' ELSE N'0' END;
EXEC test.Assert_IsEqual @TestName = N'[Schema] UNIQUE(PrinterLocationId) exists', @Expected = N'1', @Actual = @ux;
DECLARE @et NVARCHAR(1) = CASE WHEN EXISTS (SELECT 1 FROM Audit.LogEntityType WHERE Code = N'PrinterFgAssignment') THEN N'1' ELSE N'0' END;
EXEC test.Assert_IsEqual @TestName = N'[Schema] audit entity type seeded', @Expected = N'1', @Actual = @et;
GO
EXEC test.EndTestFile;
GO
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd sql/tests && powershell -File Run-Tests.ps1 -DatabaseName MPP_MES_PrinterCards -Filter "010_PrinterFgAssignment_schema"`
Expected: reset succeeds, 3 FAILs (`Actual: 0`) — the table/index/entity-type don't exist yet.

- [ ] **Step 3: Write the migration**

Create `sql/migrations/versioned/0052_printer_fg_assignment.sql`:

```sql
-- ============================================================
-- Migration: 0052_printer_fg_assignment.sql
-- Author:    Blue Ridge Automation
-- Date:      2026-08-06
-- Description: FG<->printer binding for multi-printer assembly-out stations
--   (printer-cards feature). One row per child Printer that has an assigned
--   finished good; UNIQUE(PrinterLocationId) = one FG per printer. Adds the
--   'PrinterFgAssignment' audit entity type. Idempotent-guarded.
-- ============================================================
IF EXISTS (SELECT 1 FROM dbo.SchemaVersion WHERE MigrationId = N'0052_printer_fg_assignment')
BEGIN PRINT 'Migration 0052 already applied -- skipping.'; RETURN; END
GO

IF OBJECT_ID(N'Location.PrinterFgAssignment') IS NULL
BEGIN
    CREATE TABLE Location.PrinterFgAssignment (
        Id                     BIGINT IDENTITY(1,1) NOT NULL
            CONSTRAINT PK_PrinterFgAssignment PRIMARY KEY,
        PrinterLocationId      BIGINT NOT NULL
            CONSTRAINT FK_PrinterFgAssignment_Printer REFERENCES Location.Location(Id),
        ItemId                 BIGINT NOT NULL
            CONSTRAINT FK_PrinterFgAssignment_Item REFERENCES Parts.Item(Id),
        SortOrder              INT NOT NULL
            CONSTRAINT DF_PrinterFgAssignment_SortOrder DEFAULT (1),
        CreatedAt              DATETIME2(3) NOT NULL
            CONSTRAINT DF_PrinterFgAssignment_CreatedAt DEFAULT (GETUTCDATETIME()),
        CreatedByAppUserId     BIGINT NULL
            CONSTRAINT FK_PrinterFgAssignment_CreatedBy REFERENCES Location.AppUser(Id),
        LastEditedAt           DATETIME2(3) NULL,
        LastEditedByAppUserId  BIGINT NULL
            CONSTRAINT FK_PrinterFgAssignment_EditedBy REFERENCES Location.AppUser(Id),
        CONSTRAINT UX_PrinterFgAssignment_Printer UNIQUE (PrinterLocationId)
    );
END
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_PrinterFgAssignment_Item')
    CREATE INDEX IX_PrinterFgAssignment_Item ON Location.PrinterFgAssignment (ItemId);
GO

IF NOT EXISTS (SELECT 1 FROM Audit.LogEntityType WHERE Code = N'PrinterFgAssignment')
    INSERT INTO Audit.LogEntityType (Code, Name, Description)
    VALUES (N'PrinterFgAssignment', N'Printer FG Assignment', N'FG-to-printer binding at a multi-printer assembly-out station');
GO

INSERT INTO dbo.SchemaVersion (MigrationId, Description)
VALUES (N'0052_printer_fg_assignment', N'Location.PrinterFgAssignment (FG<->printer binding, UNIQUE per printer) + audit entity type.');
GO
PRINT 'Migration 0052 (printer_fg_assignment) applied.';
GO
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `cd sql/tests && powershell -File Run-Tests.ps1 -DatabaseName MPP_MES_PrinterCards -Filter "010_PrinterFgAssignment_schema"`
Expected: 3 PASS, `Failed: 0`.

- [ ] **Step 5: Apply the migration to live dev DB**

Run: `sqlcmd -S localhost -d MPP_MES_Dev -C -b -I -i sql/migrations/versioned/0052_printer_fg_assignment.sql`
Expected: `Migration 0052 (printer_fg_assignment) applied.`

- [ ] **Step 6: Commit**

```bash
git add sql/migrations/versioned/0052_printer_fg_assignment.sql sql/tests/0029_AssemblyPrinterCards/010_PrinterFgAssignment_schema.sql
git commit -m "feat(assembly): PrinterFgAssignment table + audit entity type (printer cards)"
```

---

## Task 2: `Location.Printer_GetById` read proc + NQ + script

**Files:**
- Create: `sql/migrations/repeatable/R__Location_Printer_GetById.sql`
- Create: `ignition/projects/Core/ignition/named-query/location/Printer_GetById/query.sql`
- Create: `ignition/projects/Core/ignition/named-query/location/Printer_GetById/resource.json`
- Modify: `ignition/projects/Core/ignition/script-python/BlueRidge/Location/Printer/code.py`
- Test: `sql/tests/0029_AssemblyPrinterCards/020_Printer_GetById.sql`

**Interfaces:**
- Consumes: Task 1 (none of its schema, but same DB). Printer = `Location.Location` with `LocationTypeDefinitionId = 16`, attrs `Endpoint`/`Model`/`ConnectionKind`.
- Produces: proc `Location.Printer_GetById(@PrinterLocationId BIGINT)` → one row `{LocationId, Code, Name, Endpoint, Model, ConnectionKind}` (empty if not a printer / not found); NQ `location/Printer_GetById`; script `BlueRidge.Location.Printer.getById(printerLocationId)` → dict or `{}`.

- [ ] **Step 1: Write the failing test**

Create `sql/tests/0029_AssemblyPrinterCards/020_Printer_GetById.sql`:

```sql
SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0029_AssemblyPrinterCards/020_Printer_GetById.sql';
GO
-- fixture: a printer with an Endpoint under an arbitrary terminal
DELETE la FROM Location.LocationAttribute la INNER JOIN Location.Location l ON l.Id = la.LocationId WHERE l.Code = N'TEST-PRN-1';
DELETE FROM Location.Location WHERE Code = N'TEST-PRN-1';
DECLARE @Parent BIGINT = (SELECT TOP 1 Id FROM Location.Location WHERE LocationTypeDefinitionId = 7 AND DeprecatedAt IS NULL ORDER BY Id);
INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
VALUES (16, @Parent, N'Test Printer 1', N'TEST-PRN-1', N'test', 950);
DECLARE @Pid BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'TEST-PRN-1');
DECLARE @EpDef BIGINT = (SELECT Id FROM Location.LocationAttributeDefinition WHERE LocationTypeDefinitionId = 16 AND AttributeName = N'Endpoint' AND DeprecatedAt IS NULL);
INSERT INTO Location.LocationAttribute (LocationId, LocationAttributeDefinitionId, AttributeValue) VALUES (@Pid, @EpDef, N'10.20.30.40:9100');
GO
DECLARE @Ep NVARCHAR(200), @Code NVARCHAR(50), @Rows INT;
CREATE TABLE #P (LocationId BIGINT, Code NVARCHAR(50), Name NVARCHAR(200), Endpoint NVARCHAR(200), Model NVARCHAR(200), ConnectionKind NVARCHAR(50));
INSERT INTO #P EXEC Location.Printer_GetById @PrinterLocationId = (SELECT Id FROM Location.Location WHERE Code = N'TEST-PRN-1');
SELECT @Ep = Endpoint, @Code = Code, @Rows = COUNT(*) OVER() FROM #P;
DROP TABLE #P;
EXEC test.Assert_IsEqual @TestName = N'[PrinterById] endpoint resolves', @Expected = N'10.20.30.40:9100', @Actual = @Ep;
EXEC test.Assert_IsEqual @TestName = N'[PrinterById] code resolves', @Expected = N'TEST-PRN-1', @Actual = @Code;
GO
DECLARE @Rows2 INT;
CREATE TABLE #U (LocationId BIGINT, Code NVARCHAR(50), Name NVARCHAR(200), Endpoint NVARCHAR(200), Model NVARCHAR(200), ConnectionKind NVARCHAR(50));
INSERT INTO #U EXEC Location.Printer_GetById @PrinterLocationId = -999;
SELECT @Rows2 = COUNT(*) FROM #U;
DROP TABLE #U;
EXEC test.Assert_RowCount @TestName = N'[PrinterById] unknown id -> empty set', @ExpectedCount = 0, @ActualCount = @Rows2;
GO
DELETE la FROM Location.LocationAttribute la INNER JOIN Location.Location l ON l.Id = la.LocationId WHERE l.Code = N'TEST-PRN-1';
DELETE FROM Location.Location WHERE Code = N'TEST-PRN-1';
GO
EXEC test.EndTestFile;
GO
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd sql/tests && powershell -File Run-Tests.ps1 -DatabaseName MPP_MES_PrinterCards -Filter "020_Printer_GetById"`
Expected: ERROR (`Could not find stored procedure 'Location.Printer_GetById'`) — proc missing.

- [ ] **Step 3: Write the proc**

Create `sql/migrations/repeatable/R__Location_Printer_GetById.sql`:

```sql
-- ============================================================
-- Repeatable:  R__Location_Printer_GetById.sql
-- Author:      Blue Ridge Automation
-- Modified:    2026-08-06
-- Version:     1.0
-- Description: Resolve one Printer Location (DefId 16) by its own Id + its
--   Endpoint/Model/ConnectionKind attribute values. Unlike Terminal_GetPrinter
--   (TOP 1 child of a terminal), this addresses a SPECIFIC printer -- used to
--   derive a shipping-label dispatch endpoint from a printer id (printer-cards).
--   Read proc: one row, or empty set when the id is not an active Printer.
-- ============================================================
CREATE OR ALTER PROCEDURE Location.Printer_GetById
    @PrinterLocationId BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    SELECT
        p.Id                AS LocationId,
        p.Code              AS Code,
        p.Name              AS Name,
        epv.AttributeValue  AS Endpoint,
        mdv.AttributeValue  AS Model,
        ckv.AttributeValue  AS ConnectionKind
    FROM Location.Location p
    LEFT JOIN Location.LocationAttributeDefinition epd
        ON epd.LocationTypeDefinitionId = 16 AND epd.AttributeName = N'Endpoint' AND epd.DeprecatedAt IS NULL
    LEFT JOIN Location.LocationAttribute epv ON epv.LocationId = p.Id AND epv.LocationAttributeDefinitionId = epd.Id
    LEFT JOIN Location.LocationAttributeDefinition mdd
        ON mdd.LocationTypeDefinitionId = 16 AND mdd.AttributeName = N'Model' AND mdd.DeprecatedAt IS NULL
    LEFT JOIN Location.LocationAttribute mdv ON mdv.LocationId = p.Id AND mdv.LocationAttributeDefinitionId = mdd.Id
    LEFT JOIN Location.LocationAttributeDefinition ckd
        ON ckd.LocationTypeDefinitionId = 16 AND ckd.AttributeName = N'ConnectionKind' AND ckd.DeprecatedAt IS NULL
    LEFT JOIN Location.LocationAttribute ckv ON ckv.LocationId = p.Id AND ckv.LocationAttributeDefinitionId = ckd.Id
    WHERE p.Id = @PrinterLocationId
      AND p.LocationTypeDefinitionId = 16
      AND p.DeprecatedAt IS NULL;
END;
GO
```

- [ ] **Step 4: Create the named query**

Create `ignition/projects/Core/ignition/named-query/location/Printer_GetById/query.sql`:

```sql
EXEC Location.Printer_GetById
    @PrinterLocationId = :printerLocationId
```

Create `ignition/projects/Core/ignition/named-query/location/Printer_GetById/resource.json`:

```json
{
  "scope": "DG",
  "version": 2,
  "files": ["query.sql"],
  "attributes": {
    "type": "Query",
    "enabled": true,
    "database": "",
    "useMaxReturnSize": false,
    "maxReturnSize": 100,
    "autoBatchEnabled": false,
    "cacheEnabled": false,
    "cacheAmount": 1,
    "cacheUnit": "SEC",
    "fallbackEnabled": false,
    "fallbackValue": "",
    "permissions": [{ "zone": "", "role": "" }],
    "lastModification": { "actor": "claude", "timestamp": "2026-08-06T12:00:00Z" },
    "parameters": [
      { "type": "Parameter", "identifier": "printerLocationId", "sqlType": 3 }
    ]
  }
}
```

- [ ] **Step 5: Add the script function**

Append to `ignition/projects/Core/ignition/script-python/BlueRidge/Location/Printer/code.py`:

```python
def getById(printerLocationId):
    """Resolve one Printer (by its own LocationId) + Endpoint/Model/ConnectionKind.
       Returns a dict, or {} when the id is not an active printer."""
    pid = BlueRidge.Common.Util.extractQualifiedValues(printerLocationId)
    if pid is None:
        return {}
    return BlueRidge.Common.Db.execOne("location/Printer_GetById", {"printerLocationId": pid}) or {}
```

- [ ] **Step 6: Apply proc to dev, scan, run the test to verify it passes**

Run:
```bash
sqlcmd -S localhost -d MPP_MES_Dev -C -b -I -i sql/migrations/repeatable/R__Location_Printer_GetById.sql
powershell -File scan.ps1
cd sql/tests && powershell -File Run-Tests.ps1 -DatabaseName MPP_MES_PrinterCards -Filter "020_Printer_GetById"
```
Expected: 3 PASS, `Failed: 0`.

- [ ] **Step 7: Commit**

```bash
git add sql/migrations/repeatable/R__Location_Printer_GetById.sql ignition/projects/Core/ignition/named-query/location/Printer_GetById/query.sql ignition/projects/Core/ignition/named-query/location/Printer_GetById/resource.json ignition/projects/Core/ignition/script-python/BlueRidge/Location/Printer/code.py
git commit -m "feat(location): Printer_GetById + NQ + script (resolve a specific printer)"
```

---

## Task 3: `PrinterFgAssignment_ListForStation` read proc + NQ + script

**Files:**
- Create: `sql/migrations/repeatable/R__Location_PrinterFgAssignment_ListForStation.sql`
- Create: `ignition/projects/Core/ignition/named-query/location/PrinterFgAssignment_ListForStation/{query.sql,resource.json}`
- Create: `ignition/projects/Core/ignition/script-python/BlueRidge/Location/PrinterFgAssignment/{code.py,resource.json}`
- Test: `sql/tests/0029_AssemblyPrinterCards/030_PrinterFgAssignment_ListForStation.sql`

**Interfaces:**
- Consumes: Task 1 table; Task 2 nothing.
- Produces: proc `Location.PrinterFgAssignment_ListForStation(@StationTerminalLocationId BIGINT)` → one row per active child Printer of the terminal: `{PrinterLocationId, PrinterCode, PrinterName, Endpoint, ConnectionKind, AssignedItemId, PartNumber, Description, SortOrder}` (assignment LEFT-joined; unassigned printers appear with NULLs), ordered `SortOrder, PrinterLocationId`. NQ `location/PrinterFgAssignment_ListForStation`. Script module `BlueRidge.Location.PrinterFgAssignment.listForStation(stationTerminalLocationId)` → list[dict].

- [ ] **Step 1: Write the failing test**

Create `sql/tests/0029_AssemblyPrinterCards/030_PrinterFgAssignment_ListForStation.sql`:

```sql
SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0029_AssemblyPrinterCards/030_PrinterFgAssignment_ListForStation.sql';
GO
-- fixtures: a terminal with two child printers; one printer assigned to an FG.
DELETE pfa FROM Location.PrinterFgAssignment pfa INNER JOIN Location.Location l ON l.Id = pfa.PrinterLocationId WHERE l.Code IN (N'TEST-LST-P1', N'TEST-LST-P2');
DELETE FROM Location.Location WHERE Code IN (N'TEST-LST-P1', N'TEST-LST-P2', N'TEST-LST-TERM');
DECLARE @AnyParent BIGINT = (SELECT TOP 1 ParentLocationId FROM Location.Location WHERE LocationTypeDefinitionId = 7 AND ParentLocationId IS NOT NULL ORDER BY Id);
INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, SortOrder) VALUES (7, @AnyParent, N'Test Term', N'TEST-LST-TERM', 960);
DECLARE @T BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'TEST-LST-TERM');
INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, SortOrder) VALUES
    (16, @T, N'P1', N'TEST-LST-P1', 1),(16, @T, N'P2', N'TEST-LST-P2', 2);
DECLARE @P1 BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'TEST-LST-P1');
DECLARE @Fg BIGINT = (SELECT TOP 1 i.Id FROM Parts.Item i JOIN Parts.ItemType it ON it.Id = i.ItemTypeId AND it.Code = N'FinishedGood' WHERE i.DeprecatedAt IS NULL ORDER BY i.Id);
INSERT INTO Location.PrinterFgAssignment (PrinterLocationId, ItemId, SortOrder) VALUES (@P1, @Fg, 1);
GO
DECLARE @Cnt INT, @Assigned INT, @Unassigned INT;
CREATE TABLE #L (PrinterLocationId BIGINT, PrinterCode NVARCHAR(50), PrinterName NVARCHAR(200), Endpoint NVARCHAR(200), ConnectionKind NVARCHAR(50), AssignedItemId BIGINT, PartNumber NVARCHAR(50), Description NVARCHAR(500), SortOrder INT);
INSERT INTO #L EXEC Location.PrinterFgAssignment_ListForStation @StationTerminalLocationId = (SELECT Id FROM Location.Location WHERE Code = N'TEST-LST-TERM');
SELECT @Cnt = COUNT(*), @Assigned = SUM(CASE WHEN AssignedItemId IS NOT NULL THEN 1 ELSE 0 END), @Unassigned = SUM(CASE WHEN AssignedItemId IS NULL THEN 1 ELSE 0 END) FROM #L;
DROP TABLE #L;
EXEC test.Assert_RowCount @TestName = N'[List] one row per child printer (2)', @ExpectedCount = 2, @ActualCount = @Cnt;
EXEC test.Assert_RowCount @TestName = N'[List] one assigned', @ExpectedCount = 1, @ActualCount = @Assigned;
EXEC test.Assert_RowCount @TestName = N'[List] one unassigned', @ExpectedCount = 1, @ActualCount = @Unassigned;
GO
DELETE pfa FROM Location.PrinterFgAssignment pfa INNER JOIN Location.Location l ON l.Id = pfa.PrinterLocationId WHERE l.Code IN (N'TEST-LST-P1', N'TEST-LST-P2');
DELETE FROM Location.Location WHERE Code IN (N'TEST-LST-P1', N'TEST-LST-P2', N'TEST-LST-TERM');
GO
EXEC test.EndTestFile;
GO
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd sql/tests && powershell -File Run-Tests.ps1 -DatabaseName MPP_MES_PrinterCards -Filter "030_PrinterFgAssignment_ListForStation"`
Expected: ERROR — proc missing.

- [ ] **Step 3: Write the proc**

Create `sql/migrations/repeatable/R__Location_PrinterFgAssignment_ListForStation.sql`:

```sql
-- ============================================================
-- Repeatable:  R__Location_PrinterFgAssignment_ListForStation.sql
-- Author:      Blue Ridge Automation
-- Modified:    2026-08-06
-- Version:     1.0
-- Description: One row per active child Printer (DefId 16) of a station terminal,
--   LEFT-joined to its FG assignment (unassigned printers appear with NULLs) +
--   the printer's Endpoint/ConnectionKind. Drives the printer-card panel. Ordered
--   by the assignment SortOrder then printer Id. Empty set = no child printers.
-- ============================================================
CREATE OR ALTER PROCEDURE Location.PrinterFgAssignment_ListForStation
    @StationTerminalLocationId BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    SELECT
        p.Id                AS PrinterLocationId,
        p.Code              AS PrinterCode,
        p.Name              AS PrinterName,
        epv.AttributeValue  AS Endpoint,
        ckv.AttributeValue  AS ConnectionKind,
        pfa.ItemId          AS AssignedItemId,
        i.PartNumber        AS PartNumber,
        i.Description        AS Description,
        ISNULL(pfa.SortOrder, p.SortOrder) AS SortOrder
    FROM Location.Location p
    LEFT JOIN Location.LocationAttributeDefinition epd
        ON epd.LocationTypeDefinitionId = 16 AND epd.AttributeName = N'Endpoint' AND epd.DeprecatedAt IS NULL
    LEFT JOIN Location.LocationAttribute epv ON epv.LocationId = p.Id AND epv.LocationAttributeDefinitionId = epd.Id
    LEFT JOIN Location.LocationAttributeDefinition ckd
        ON ckd.LocationTypeDefinitionId = 16 AND ckd.AttributeName = N'ConnectionKind' AND ckd.DeprecatedAt IS NULL
    LEFT JOIN Location.LocationAttribute ckv ON ckv.LocationId = p.Id AND ckv.LocationAttributeDefinitionId = ckd.Id
    LEFT JOIN Location.PrinterFgAssignment pfa ON pfa.PrinterLocationId = p.Id
    LEFT JOIN Parts.Item i ON i.Id = pfa.ItemId
    WHERE p.ParentLocationId = @StationTerminalLocationId
      AND p.LocationTypeDefinitionId = 16
      AND p.DeprecatedAt IS NULL
    ORDER BY ISNULL(pfa.SortOrder, p.SortOrder), p.Id;
END;
GO
```

- [ ] **Step 4: Create the named query**

Create `ignition/projects/Core/ignition/named-query/location/PrinterFgAssignment_ListForStation/query.sql`:

```sql
EXEC Location.PrinterFgAssignment_ListForStation
    @StationTerminalLocationId = :stationTerminalLocationId
```

Create `ignition/projects/Core/ignition/named-query/location/PrinterFgAssignment_ListForStation/resource.json` (identical shape to Task 2's read NQ, one param):

```json
{
  "scope": "DG",
  "version": 2,
  "files": ["query.sql"],
  "attributes": {
    "type": "Query",
    "enabled": true,
    "database": "",
    "useMaxReturnSize": false,
    "maxReturnSize": 100,
    "autoBatchEnabled": false,
    "cacheEnabled": false,
    "cacheAmount": 1,
    "cacheUnit": "SEC",
    "fallbackEnabled": false,
    "fallbackValue": "",
    "permissions": [{ "zone": "", "role": "" }],
    "lastModification": { "actor": "claude", "timestamp": "2026-08-06T12:00:00Z" },
    "parameters": [
      { "type": "Parameter", "identifier": "stationTerminalLocationId", "sqlType": 3 }
    ]
  }
}
```

- [ ] **Step 5: Create the entity script module**

Create `ignition/projects/Core/ignition/script-python/BlueRidge/Location/PrinterFgAssignment/code.py`:

```python
"""BlueRidge.Location.PrinterFgAssignment - FG<->printer bindings for a
   multi-printer assembly-out station (printer-cards). Thin wrappers; no
   business logic (validation/reconcile is in the SaveAll proc).

   Change Log:
       2026-08-06 - Initial version (printer-cards feature)."""


def listForStation(stationTerminalLocationId):
    """One row per child Printer of the station terminal, LEFT-joined to its FG
       assignment (unassigned printers appear). Always a list."""
    tid = BlueRidge.Common.Util.extractQualifiedValues(stationTerminalLocationId)
    BlueRidge.Common.Util.log("listForStation stationTerminalLocationId=%s" % tid)
    if tid is None:
        return []
    return BlueRidge.Common.Db.execList(
        "location/PrinterFgAssignment_ListForStation", {"stationTerminalLocationId": tid})


def childPrinterCount(stationTerminalLocationId):
    """Number of child printers at the station (>1 activates the card panel)."""
    return len(listForStation(stationTerminalLocationId) or [])
```

Create `ignition/projects/Core/ignition/script-python/BlueRidge/Location/PrinterFgAssignment/resource.json`:

```json
{
  "scope": "A",
  "version": 1,
  "restricted": false,
  "overridable": true,
  "files": ["code.py"],
  "attributes": {
    "lastModification": { "actor": "claude", "timestamp": "2026-08-06T12:00:00Z" },
    "hintScope": 2,
    "lastModificationSignature": ""
  }
}
```

- [ ] **Step 6: Apply proc, scan, run the test to verify it passes**

Run:
```bash
sqlcmd -S localhost -d MPP_MES_Dev -C -b -I -i sql/migrations/repeatable/R__Location_PrinterFgAssignment_ListForStation.sql
powershell -File scan.ps1
cd sql/tests && powershell -File Run-Tests.ps1 -DatabaseName MPP_MES_PrinterCards -Filter "030_PrinterFgAssignment_ListForStation"
```
Expected: 3 PASS, `Failed: 0`.

- [ ] **Step 7: Commit**

```bash
git add sql/migrations/repeatable/R__Location_PrinterFgAssignment_ListForStation.sql ignition/projects/Core/ignition/named-query/location/PrinterFgAssignment_ListForStation/query.sql ignition/projects/Core/ignition/named-query/location/PrinterFgAssignment_ListForStation/resource.json ignition/projects/Core/ignition/script-python/BlueRidge/Location/PrinterFgAssignment/code.py ignition/projects/Core/ignition/script-python/BlueRidge/Location/PrinterFgAssignment/resource.json sql/tests/0029_AssemblyPrinterCards/030_PrinterFgAssignment_ListForStation.sql sql/tests/0029_AssemblyPrinterCards/020_Printer_GetById.sql
git commit -m "feat(location): PrinterFgAssignment_ListForStation read + script"
```

---

## Task 4: `PrinterFgAssignment_SaveAll` mutation proc + NQ + script

**Files:**
- Create: `sql/migrations/repeatable/R__Location_PrinterFgAssignment_SaveAll.sql`
- Create: `ignition/projects/Core/ignition/named-query/location/PrinterFgAssignment_SaveAll/{query.sql,resource.json}`
- Modify: `ignition/projects/Core/ignition/script-python/BlueRidge/Location/PrinterFgAssignment/code.py`
- Test: `sql/tests/0029_AssemblyPrinterCards/040_PrinterFgAssignment_SaveAll.sql`

**Interfaces:**
- Consumes: Task 1 table, Task 3 module.
- Produces: proc `Location.PrinterFgAssignment_SaveAll(@StationTerminalLocationId BIGINT, @AppUserId BIGINT, @AssignmentsJson NVARCHAR(MAX))` — full-replace of the station's assignments from a desired-state array `[{PrinterLocationId, ItemId|null, SortOrder}]`. Status row `{Status, Message, NewId=NULL}`. Script `BlueRidge.Location.PrinterFgAssignment.saveAll(stationTerminalLocationId, assignments)`.

**Behavior (full-replace, validate-before-transaction per the ROLLBACK-safety rule):**
- Reject (Status=0, no open txn) if: any `PrinterLocationId` is not an active child Printer (DefId 16) of `@StationTerminalLocationId`; any non-null `ItemId` is not an active FinishedGood Item; the same `ItemId` appears on two printers.
- On success: DELETE every assignment whose printer is a child of the station, then INSERT one row per incoming element **with a non-null `ItemId`** (SortOrder from the element). One `Audit_LogConfigChange` row (`LogEntityTypeCode=N'PrinterFgAssignment'`, `LogEventTypeCode=N'Updated'`, `EntityId=@StationTerminalLocationId`). Full eligibility (BOM/inventory) is a UI concern — the proc validates FinishedGood type + structural rules only.

- [ ] **Step 1: Write the failing test**

Create `sql/tests/0029_AssemblyPrinterCards/040_PrinterFgAssignment_SaveAll.sql`:

```sql
SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0029_AssemblyPrinterCards/040_PrinterFgAssignment_SaveAll.sql';
GO
-- fixtures: station terminal + 2 child printers; a valid AppUser + 2 FGs
DELETE pfa FROM Location.PrinterFgAssignment pfa INNER JOIN Location.Location l ON l.Id = pfa.PrinterLocationId WHERE l.Code IN (N'TEST-SA-P1', N'TEST-SA-P2');
DELETE FROM Location.Location WHERE Code IN (N'TEST-SA-P1', N'TEST-SA-P2', N'TEST-SA-TERM');
DECLARE @AnyParent BIGINT = (SELECT TOP 1 ParentLocationId FROM Location.Location WHERE LocationTypeDefinitionId = 7 AND ParentLocationId IS NOT NULL ORDER BY Id);
INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, SortOrder) VALUES (7, @AnyParent, N'Test SA Term', N'TEST-SA-TERM', 970);
DECLARE @T BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'TEST-SA-TERM');
INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, SortOrder) VALUES (16, @T, N'P1', N'TEST-SA-P1', 1),(16, @T, N'P2', N'TEST-SA-P2', 2);
GO
DECLARE @T BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'TEST-SA-TERM');
DECLARE @P1 BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'TEST-SA-P1');
DECLARE @P2 BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'TEST-SA-P2');
DECLARE @U BIGINT = (SELECT TOP 1 Id FROM Location.AppUser ORDER BY Id);
DECLARE @Fg1 BIGINT = (SELECT TOP 1 i.Id FROM Parts.Item i JOIN Parts.ItemType it ON it.Id = i.ItemTypeId AND it.Code = N'FinishedGood' WHERE i.DeprecatedAt IS NULL ORDER BY i.Id);
DECLARE @Fg2 BIGINT = (SELECT TOP 1 i.Id FROM Parts.Item i JOIN Parts.ItemType it ON it.Id = i.ItemTypeId AND it.Code = N'FinishedGood' WHERE i.DeprecatedAt IS NULL AND i.Id <> @Fg1 ORDER BY i.Id);

-- Test 1: assign FG1->P1, FG2->P2
DECLARE @Json NVARCHAR(MAX) = N'[{"PrinterLocationId":' + CAST(@P1 AS NVARCHAR(20)) + N',"ItemId":' + CAST(@Fg1 AS NVARCHAR(20)) + N',"SortOrder":1},{"PrinterLocationId":' + CAST(@P2 AS NVARCHAR(20)) + N',"ItemId":' + CAST(@Fg2 AS NVARCHAR(20)) + N',"SortOrder":2}]';
DECLARE @St BIT, @Msg NVARCHAR(500);
CREATE TABLE #R (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #R EXEC Location.PrinterFgAssignment_SaveAll @StationTerminalLocationId=@T, @AppUserId=@U, @AssignmentsJson=@Json;
SELECT @St = Status FROM #R; DELETE FROM #R;
EXEC test.Assert_IsEqual @TestName=N'[SaveAll] assign two -> Status 1', @Expected=N'1', @Actual=CAST(@St AS NVARCHAR(1));
DECLARE @Rows INT = (SELECT COUNT(*) FROM Location.PrinterFgAssignment WHERE PrinterLocationId IN (@P1,@P2));
EXEC test.Assert_RowCount @TestName=N'[SaveAll] two rows persisted', @ExpectedCount=2, @ActualCount=@Rows;

-- Test 2: swap (FG2->P1, FG1->P2) is still Status 1 and count stays 2
SET @Json = N'[{"PrinterLocationId":' + CAST(@P1 AS NVARCHAR(20)) + N',"ItemId":' + CAST(@Fg2 AS NVARCHAR(20)) + N',"SortOrder":1},{"PrinterLocationId":' + CAST(@P2 AS NVARCHAR(20)) + N',"ItemId":' + CAST(@Fg1 AS NVARCHAR(20)) + N',"SortOrder":2}]';
INSERT INTO #R EXEC Location.PrinterFgAssignment_SaveAll @StationTerminalLocationId=@T, @AppUserId=@U, @AssignmentsJson=@Json;
SELECT @St = Status FROM #R; DELETE FROM #R;
DECLARE @P1Item BIGINT = (SELECT ItemId FROM Location.PrinterFgAssignment WHERE PrinterLocationId=@P1);
EXEC test.Assert_IsEqual @TestName=N'[SaveAll] swap -> P1 now has FG2', @Expected=CAST(@Fg2 AS NVARCHAR(20)), @Actual=CAST(@P1Item AS NVARCHAR(20));

-- Test 3: duplicate ItemId on two printers -> Status 0 (rejected)
SET @Json = N'[{"PrinterLocationId":' + CAST(@P1 AS NVARCHAR(20)) + N',"ItemId":' + CAST(@Fg1 AS NVARCHAR(20)) + N',"SortOrder":1},{"PrinterLocationId":' + CAST(@P2 AS NVARCHAR(20)) + N',"ItemId":' + CAST(@Fg1 AS NVARCHAR(20)) + N',"SortOrder":2}]';
INSERT INTO #R EXEC Location.PrinterFgAssignment_SaveAll @StationTerminalLocationId=@T, @AppUserId=@U, @AssignmentsJson=@Json;
SELECT @St = Status FROM #R; DELETE FROM #R;
EXEC test.Assert_IsEqual @TestName=N'[SaveAll] duplicate FG -> Status 0', @Expected=N'0', @Actual=CAST(@St AS NVARCHAR(1));

-- Test 4: unassign P2 (null ItemId) -> only P1 row remains
SET @Json = N'[{"PrinterLocationId":' + CAST(@P1 AS NVARCHAR(20)) + N',"ItemId":' + CAST(@Fg2 AS NVARCHAR(20)) + N',"SortOrder":1},{"PrinterLocationId":' + CAST(@P2 AS NVARCHAR(20)) + N',"ItemId":null,"SortOrder":2}]';
INSERT INTO #R EXEC Location.PrinterFgAssignment_SaveAll @StationTerminalLocationId=@T, @AppUserId=@U, @AssignmentsJson=@Json;
DELETE FROM #R;
DECLARE @Rows2 INT = (SELECT COUNT(*) FROM Location.PrinterFgAssignment WHERE PrinterLocationId IN (@P1,@P2));
EXEC test.Assert_RowCount @TestName=N'[SaveAll] unassign one -> one row', @ExpectedCount=1, @ActualCount=@Rows2;
DROP TABLE #R;
GO
DELETE pfa FROM Location.PrinterFgAssignment pfa INNER JOIN Location.Location l ON l.Id = pfa.PrinterLocationId WHERE l.Code IN (N'TEST-SA-P1', N'TEST-SA-P2');
DELETE FROM Location.Location WHERE Code IN (N'TEST-SA-P1', N'TEST-SA-P2', N'TEST-SA-TERM');
GO
EXEC test.EndTestFile;
GO
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd sql/tests && powershell -File Run-Tests.ps1 -DatabaseName MPP_MES_PrinterCards -Filter "040_PrinterFgAssignment_SaveAll"`
Expected: ERROR — proc missing.

- [ ] **Step 3: Write the proc**

Create `sql/migrations/repeatable/R__Location_PrinterFgAssignment_SaveAll.sql`:

```sql
-- ============================================================
-- Repeatable:  R__Location_PrinterFgAssignment_SaveAll.sql
-- Author:      Blue Ridge Automation
-- Modified:    2026-08-06
-- Version:     1.0
-- Description: Full-replace of a station terminal's FG<->printer assignments from
--   a desired-state JSON array [{PrinterLocationId, ItemId|null, SortOrder}]. The
--   panel always submits every card, so this deletes the station's rows and
--   re-inserts the non-null assignments in one transaction. Validate-before-
--   transaction (rejections SELECT the status row + RETURN with no open txn);
--   ROLLBACK only in CATCH. No OUTPUT params. Status row {Status, Message, NewId}.
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

    DECLARE @Incoming TABLE (RowIndex INT, PrinterLocationId BIGINT, ItemId BIGINT NULL, SortOrder INT);
    INSERT INTO @Incoming (RowIndex, PrinterLocationId, ItemId, SortOrder)
    SELECT [key],
           JSON_VALUE(value, '$.PrinterLocationId'),
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

        DELETE pfa
        FROM Location.PrinterFgAssignment pfa
        INNER JOIN Location.Location p ON p.Id = pfa.PrinterLocationId
        WHERE p.ParentLocationId = @StationTerminalLocationId
          AND p.LocationTypeDefinitionId = 16;

        INSERT INTO Location.PrinterFgAssignment (PrinterLocationId, ItemId, SortOrder, CreatedByAppUserId)
        SELECT PrinterLocationId, ItemId, SortOrder, @AppUserId
        FROM @Incoming
        WHERE ItemId IS NOT NULL;

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
            @OldValue          = NULL,
            @NewValue          = @AssignmentsJson;

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
                @AppUserId = @AppUserId, @ProcedureName = N'Location.PrinterFgAssignment_SaveAll',
                @ErrorMessage = @Message, @Parameters = @AssignmentsJson;
        END TRY BEGIN CATCH END CATCH;
        SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
    END CATCH
END;
GO
```

> **Note for implementer:** confirm `Audit.Audit_LogFailure`'s parameter names by opening `R__Location_LocationTypeDefinition_SaveAll.sql` (it calls it) — adjust `@ProcedureName`/`@Parameters` to the actual signature if they differ. The `ufn_MidDot`/`ufn_TruncateActivity` helpers are the audit-Description convention (repeatables `R__Audit_ufn_*`).

- [ ] **Step 4: Create the named query**

Create `ignition/projects/Core/ignition/named-query/location/PrinterFgAssignment_SaveAll/query.sql`:

```sql
EXEC Location.PrinterFgAssignment_SaveAll
    @StationTerminalLocationId = :stationTerminalLocationId,
    @AppUserId                 = :appUserId,
    @AssignmentsJson           = :assignmentsJson
```

Create `ignition/projects/Core/ignition/named-query/location/PrinterFgAssignment_SaveAll/resource.json`:

```json
{
  "scope": "DG",
  "version": 2,
  "files": ["query.sql"],
  "attributes": {
    "type": "Query",
    "enabled": true,
    "database": "",
    "useMaxReturnSize": false,
    "maxReturnSize": 100,
    "autoBatchEnabled": false,
    "cacheEnabled": false,
    "cacheAmount": 1,
    "cacheUnit": "SEC",
    "fallbackEnabled": false,
    "fallbackValue": "",
    "permissions": [{ "zone": "", "role": "" }],
    "lastModification": { "actor": "claude", "timestamp": "2026-08-06T12:00:00Z" },
    "parameters": [
      { "type": "Parameter", "identifier": "stationTerminalLocationId", "sqlType": 3 },
      { "type": "Parameter", "identifier": "appUserId", "sqlType": 3 },
      { "type": "Parameter", "identifier": "assignmentsJson", "sqlType": 7 }
    ]
  }
}
```

- [ ] **Step 5: Add the script function**

Append to `ignition/projects/Core/ignition/script-python/BlueRidge/Location/PrinterFgAssignment/code.py`:

```python
def saveAll(stationTerminalLocationId, assignments, appUserId=None):
    """Full-replace the station's FG<->printer assignments. `assignments` is a
       list of {PrinterLocationId, ItemId|None, SortOrder}. Returns {Status,
       Message, NewId}."""
    if appUserId is None:
        appUserId = BlueRidge.Common.Util._currentAppUserId()
    tid = BlueRidge.Common.Util.extractQualifiedValues(stationTerminalLocationId)
    rows = BlueRidge.Common.Util.extractQualifiedValues(assignments) or []
    params = {
        "stationTerminalLocationId": tid,
        "appUserId": appUserId,
        "assignmentsJson": system.util.jsonEncode(rows),
    }
    return BlueRidge.Common.Db.execMutation("location/PrinterFgAssignment_SaveAll", params)
```

- [ ] **Step 6: Apply proc, scan, run the test to verify it passes**

Run:
```bash
sqlcmd -S localhost -d MPP_MES_Dev -C -b -I -i sql/migrations/repeatable/R__Location_PrinterFgAssignment_SaveAll.sql
powershell -File scan.ps1
cd sql/tests && powershell -File Run-Tests.ps1 -DatabaseName MPP_MES_PrinterCards -Filter "040_PrinterFgAssignment_SaveAll"
```
Expected: all PASS, `Failed: 0`. (If Task-3's list test regressed, run `-Filter "0029"` to run the whole dir.)

- [ ] **Step 7: Commit**

```bash
git add sql/migrations/repeatable/R__Location_PrinterFgAssignment_SaveAll.sql ignition/projects/Core/ignition/named-query/location/PrinterFgAssignment_SaveAll/query.sql ignition/projects/Core/ignition/named-query/location/PrinterFgAssignment_SaveAll/resource.json ignition/projects/Core/ignition/script-python/BlueRidge/Location/PrinterFgAssignment/code.py sql/tests/0029_AssemblyPrinterCards/040_PrinterFgAssignment_SaveAll.sql
git commit -m "feat(location): PrinterFgAssignment_SaveAll (full-replace, validated) + script"
```

---

## Task 5: `ShippingDispatcher.dispatch` printer override

**Files:**
- Modify: `ignition/projects/Core/ignition/script-python/BlueRidge/Lots/ShippingDispatcher/code.py` (the `dispatch` function, ~line 84)

**Interfaces:**
- Consumes: `BlueRidge.Location.Printer.getById` (Task 2).
- Produces: `ShippingDispatcher.dispatch(aimShipperId, terminalLocationId=None, printerLocationId=None)` — when `printerLocationId` is set, resolve the endpoint via `Printer.getById` instead of the session/terminal printer; otherwise unchanged.

- [ ] **Step 1: Modify `dispatch` to accept and honor the override**

Replace the `dispatch` function body's printer-resolution block. New function:

```python
def dispatch(aimShipperId, terminalLocationId=None, printerLocationId=None):
    """Render + synchronously dispatch a container shipping label for a claimed AIM
       Shipper ID. When printerLocationId is given, the endpoint is resolved from
       that specific printer (printer-cards routing); otherwise from the session /
       terminal printer as before. Returns {Status, Message}."""
    BlueRidge.Common.Util.log("dispatch aimShipperId=%s printerLocationId=%s" % (aimShipperId, printerLocationId))
    pid = BlueRidge.Common.Util.extractQualifiedValues(printerLocationId)
    if pid is not None:
        printer = BlueRidge.Location.Printer.getById(pid) or {}
        endpoint = (printer.get("endpoint") or printer.get("Endpoint") or "").strip()
    else:
        printer = _sessionPrinter()
        endpoint = (printer.get("endpoint") or "").strip()
        if not endpoint and terminalLocationId is not None:
            printer = BlueRidge.Location.Terminal.getPrinter(terminalLocationId) or {}
            endpoint = (printer.get("endpoint") or "").strip()

    zpl = _renderZpl(aimShipperId)
    if not endpoint:
        return {"Status": 0, "Message": "No printer endpoint resolved for this label."}

    outcome = _dispatchZpl(endpoint, zpl)
    _logDispatch(endpoint, zpl, outcome)
    if outcome.get("ok"):
        return {"Status": 1, "Message": "Shipping label printed."}
    return {"Status": 0, "Message": "Print failed: %s." % (outcome.get("error") or "unknown")}
```

> **Note:** `Printer_GetById` aliases the column `Endpoint` (capital E); `_sessionPrinter()` uses lowercase `endpoint`. The `.get("endpoint") or .get("Endpoint")` covers both shapes.

- [ ] **Step 2: Scan**

Run: `powershell -File scan.ps1`

- [ ] **Step 3: Gateway-verify with a one-shot diagnostic timer**

Create `ignition/projects/MPP/ignition/timer/DiagDispatchOverride/handleTimerEvent.py`:

```python
def handleTimerEvent():
	L = BlueRidge.Common.Util.log
	try:
		p = BlueRidge.Location.Printer.getById(-999)
		L("DIAGDO getById(-999)=%s" % p)
	except Exception as e:
		L("DIAGDO getById FAILED: %s" % str(e))
```

Create `ignition/projects/MPP/ignition/timer/DiagDispatchOverride/resource.json`:

```json
{ "scope": "G", "version": 1, "files": ["handleTimerEvent.py"],
  "attributes": { "delay": 4000, "fixedDelay": true, "sharedThread": true, "enabled": true,
    "lastModification": { "actor": "claude", "timestamp": "2026-08-06T12:00:00Z" } } }
```

Run:
```bash
MARK=$(wc -l < "/c/Program Files/Inductive Automation/Ignition/logs/wrapper.log")
powershell -File scan.ps1 ; sleep 7
awk -v m="$MARK" 'NR>m' "/c/Program Files/Inductive Automation/Ignition/logs/wrapper.log" | grep DIAGDO
```
Expected: `DIAGDO getById(-999)={}` (empty dict, no exception → the new script + NQ resolve on the gateway).

- [ ] **Step 4: Remove the diagnostic timer + scan**

Run: `rm -rf ignition/projects/MPP/ignition/timer/DiagDispatchOverride && powershell -File scan.ps1`

- [ ] **Step 5: Commit**

```bash
git add ignition/projects/Core/ignition/script-python/BlueRidge/Lots/ShippingDispatcher/code.py
git commit -m "feat(shipping): ShippingDispatcher.dispatch printerLocationId override (printer cards)"
```

---

## Task 6: `Assembly.completeBoxToPrinter` helper (Complete box → routed shipping label)

**Files:**
- Modify: `ignition/projects/Core/ignition/script-python/BlueRidge/Workorder/Assembly/code.py`

**Interfaces:**
- Consumes: `BlueRidge.Lots.Container.complete` (returns `{Status, Message, ShippingLabelId, AimShipperId}`); `BlueRidge.Lots.ShippingDispatcher.dispatch` (Task 5).
- Produces: `Assembly.completeBoxToPrinter(containerId, terminalLocationId, printerLocationId)` → `{Status, Message}` — completes the container, then dispatches its shipping label to the given printer. Keeps the view handler to one line.

- [ ] **Step 1: Add the helper**

Append to `ignition/projects/Core/ignition/script-python/BlueRidge/Workorder/Assembly/code.py`:

```python
def completeBoxToPrinter(containerId, terminalLocationId, printerLocationId, appUserId=None):
    """Card 'Complete (box)': complete the container, then print its shipping label
       to the card's printer. Container.complete claims the AIM shipper + generates
       the ShippingLabel; the dispatch (routed to printerLocationId) does the ZPL.
       Returns {Status, Message}. On a completed-but-unprinted box the ShippingLabel
       row persists (re-dispatchable), so a print miss is never a lost record."""
    if appUserId is None:
        appUserId = BlueRidge.Common.Util._currentAppUserId()
    cid = BlueRidge.Common.Util.extractQualifiedValues(containerId)
    res = BlueRidge.Lots.Container.complete(cid, operatorConfirmed=True,
                                            appUserId=appUserId, terminalLocationId=terminalLocationId)
    if not res or not res.get("Status"):
        return res or {"Status": 0, "Message": "Container complete failed."}
    aim = res.get("AimShipperId")
    disp = BlueRidge.Lots.ShippingDispatcher.dispatch(
        aim, terminalLocationId=terminalLocationId, printerLocationId=printerLocationId)
    if disp and disp.get("Status"):
        return {"Status": 1, "Message": "Box completed and shipping label printed."}
    # Box IS complete; only the print missed -> surface the print message, not a hard failure.
    return {"Status": 1, "Message": "Box completed. " + ((disp or {}).get("Message") or "Label not printed - use Reprint.")}
```

- [ ] **Step 2: Scan**

Run: `powershell -File scan.ps1`
(Behavioral verification happens in the Task-7 manual smoke — this helper needs an open full container to exercise.)

- [ ] **Step 3: Commit**

```bash
git add ignition/projects/Core/ignition/script-python/BlueRidge/Workorder/Assembly/code.py
git commit -m "feat(assembly): completeBoxToPrinter helper (complete + routed shipping-label dispatch)"
```

---

## Task 7: The printer-card panel in `AssemblyNonSerialized`

**Files:**
- Create: `ignition/projects/MPP/com.inductiveautomation.perspective/views/BlueRidge/Components/PlantFloor/PrinterCard/{view.json,resource.json}` (one card, a flex-repeater instance)
- Modify: `ignition/projects/MPP/com.inductiveautomation.perspective/views/BlueRidge/Views/ShopFloor/AssemblyNonSerialized/view.json` (add the panel, gated on child-printer count)

> **Designer-coordination gate:** editing the existing `AssemblyNonSerialized/view.json` is only safe as a file edit while Ignition **Designer is CLOSED** (per the Ignition file-edit boundary). Confirm with the human before this task, and run `.\scan.ps1` after. The new `PrinterCard` view is a brand-new file (safe to author). This task's SQL/entity-script dependencies (Tasks 1–6) are already TDD-verified; the panel itself is verified by manual smoke.

**Panel behavior (assembled from verified pieces):**

- **Activation:** in `AssemblyNonSerialized`, add `view.custom.printerCards` (default `[]`) bound (expr) to `runScript("BlueRidge.Location.PrinterFgAssignment.listForStation", 0, {session.custom.terminal.terminalLocationId})`. Add `view.custom.usePrinterCards` = expr `len({view.custom.printerCards}) > 1`. Bind the existing single-FG close form's `position.display` to `!{view.custom.usePrinterCards}` and the new panel's `position.display` to `{view.custom.usePrinterCards}` — so single-printer stations are untouched.

- **Panel container:** a flex-repeater over `view.custom.printerCards`, instance view `BlueRidge/Components/PlantFloor/PrinterCard`, passing per-instance params: `printerLocationId`, `printerCode`, `endpoint`, `connectionKind`, `assignedItemId`, `partNumber`, `description`, `sortOrder`, plus the shared `cellLocationId` (`{session.custom.cell.locationId}`) and `terminalLocationId` (`{session.custom.terminal.terminalLocationId}`).

- **PrinterCard view** (new) shows: printer code/name; the assigned FG (`partNumber` — description), or an "Unassigned" chip + an **Assign FG** dropdown bound to `runScript("BlueRidge.Parts.Item.getEligibleFinishedGoodsForDropdown", 0, {view.params.cellLocationId})` (add this dropdown-shaped wrapper over `Item_ListEligibleFinishedGoodsRanked` if not present); the FG's open-container fill from `runScript("BlueRidge.Lots.Container.getOpenByCell", 0, ...)` filtered to this FG's `assignedItemId`; a tray piece-count `numeric` field; **Complete Tray**, **Complete (box)** (shown when the FG's container is full), **Validate endpoint** (reuse the FAT #14 `BlueRidge.Location.Printer.validateEndpoint` → toast), and up/down reorder arrows.

- **Card event scripts** (each `events.component.onActionPerformed`, `scope: "G"`, body starts with `\t`):

  (Card-local customs on the `PrinterCard` view — not repeater params: `view.custom.partsCount`
  is the tray count input; `view.custom.openContainerId` is set from the container-fill lookup for
  this FG. Both default seeded per the "Pre-declare bound custom props" convention.)

  - **Complete Tray:**
    ```
    	result = BlueRidge.Workorder.Assembly.completeTray(self.view.params.assignedItemId, BlueRidge.Common.Util.toIntOrNone(self.view.custom.partsCount), self.view.params.cellLocationId, closureMethod="ByCount", terminalLocationId=self.view.params.terminalLocationId)
    	BlueRidge.Common.Ui.notifyResult(result, "Tray completed - FG LOT minted")
    	system.perspective.sendMessage("printerCardsRefresh", scope="page")
    ```
  - **Complete (box):**
    ```
    	result = BlueRidge.Workorder.Assembly.completeBoxToPrinter(self.view.custom.openContainerId, self.view.params.terminalLocationId, self.view.params.printerLocationId)
    	BlueRidge.Common.Ui.notifyResult(result, "Box completed")
    	system.perspective.sendMessage("printerCardsRefresh", scope="page")
    ```
  - **Validate endpoint:**
    ```
    	res = BlueRidge.Location.Printer.validateEndpoint(self.view.params.endpoint, self.view.params.connectionKind)
    	BlueRidge.Common.Notify.toast(res["title"], res["message"], res["level"])
    ```

- **Setup save:** a panel-level **Save layout** button collects the current card order + each card's assigned FG into a list of `{PrinterLocationId, ItemId, SortOrder}` and calls `BlueRidge.Location.PrinterFgAssignment.saveAll({session.custom.terminal.terminalLocationId}, rows)` → `notifyResult`. Assign/swap/reorder mutate a panel-local `view.custom.cardsDraft` (identity-preserving); Save persists. A page-scoped `printerCardsRefresh` handler on `AssemblyNonSerialized` re-reads `listForStation` into `view.custom.printerCards`.

- [ ] **Step 1: Author the `PrinterCard` component view**

Create `PrinterCard/view.json` (new file) with the params above, the display + inputs, and the three event scripts. Create its `PrinterCard/resource.json` (`scope: "G"`, `files: ["view.json"]` — copy the shape from any existing `Components/PlantFloor/*/resource.json`). Validate JSON parses: `python -c "import json;json.load(open(r'<path>/view.json',encoding='utf-8'));print('ok')"`.

- [ ] **Step 2: Add the dropdown wrapper if missing**

If `BlueRidge.Parts.Item.getEligibleFinishedGoodsForDropdown` does not exist, add it to `ignition/projects/Core/ignition/script-python/BlueRidge/Parts/Item/code.py`:

```python
def getEligibleFinishedGoodsForDropdown(cellLocationId):
    """[{label, value}] of eligible finished goods at a cell (for the printer-card
       Assign-FG picker). Wraps Item_ListEligibleFinishedGoodsRanked."""
    cid = BlueRidge.Common.Util.extractQualifiedValues(cellLocationId)
    if cid is None:
        return []
    rows = BlueRidge.Common.Db.execList("parts/Item_ListEligibleFinishedGoodsRanked", {"locationId": cid}) or []
    return [{"label": "%s - %s" % (r.get("PartNumber") or "", r.get("Description") or ""), "value": r.get("Id")} for r in rows]
```

(Confirm the NQ path `parts/Item_ListEligibleFinishedGoodsRanked` exists; if the NQ has a different name, use it. If the wrapper already exists, skip this step.)

- [ ] **Step 3: Wire the panel into `AssemblyNonSerialized`**

With Designer confirmed closed, add to `AssemblyNonSerialized/view.json`: the `view.custom.printerCards` / `usePrinterCards` customs + bindings; the `position.display` gate on the existing close form; the flex-repeater panel; and the page-scoped `printerCardsRefresh` message handler. Validate JSON parses. Run `.\scan.ps1`.

- [ ] **Step 4: Manual smoke (with real data)**

In `MPP_MES_Dev`: add ≥2 child printers under a test assembly-out terminal via the config app (`/plant`), give them Endpoints, and set the session terminal to it. Then in the plant-floor app on that terminal's `assembly-nonserialized` screen:
1. Panel shows one card per printer; assign/swap two FGs; reorder; **Save layout** → success toast; reload → layout restored.
2. **Validate endpoint** on a card → toast (success/unreachable per the endpoint).
3. **Complete Tray** on a card with count → "FG LOT minted"; fill advances.
4. Fill a card's container, **Complete (box)** → box completes and (if the printer endpoint is reachable) the shipping label dispatches to that printer's endpoint (check `wrapper.log` for `Shipping label dispatch to <that endpoint>`).
5. A single-printer terminal's `assembly-nonserialized` screen is unchanged (no panel).

- [ ] **Step 5: Commit**

```bash
git add ignition/projects/MPP/com.inductiveautomation.perspective/views/BlueRidge/Components/PlantFloor/PrinterCard/view.json ignition/projects/MPP/com.inductiveautomation.perspective/views/BlueRidge/Components/PlantFloor/PrinterCard/resource.json ignition/projects/MPP/com.inductiveautomation.perspective/views/BlueRidge/Views/ShopFloor/AssemblyNonSerialized/view.json
# add BlueRidge/Parts/Item/code.py only if Step 2 modified it
git commit -m "feat(assembly): printer-card panel for multi-printer by-count close (FG routing)"
```

---

## Notes for the executor

- **Task order:** 1 → 2 → 3 → 4 must be sequential (schema before procs). 5 depends on 2. 6 depends on 5. 7 depends on 3/4/5/6. None run in parallel safely (shared DB + gateway).
- **Concurrency with other agents:** `MPP_MES_Dev` and the one gateway are shared. Before editing `AssemblyNonSerialized` (Task 7) inspect `git status` — don't commit files you didn't create. Confirm migration number `0052` and test dir `0029_` are still free at start.
- **If the shipping-label dispatch (`_renderZpl`/AIM) turns out to be a skeleton** in this environment (the FAT notes flag shipping-dock commissioning is in flight), Task 6's Complete-box will complete the container and attempt a dispatch that no-ops on a missing endpoint — the routing seam (`printerLocationId` override) is still correct and testable via the endpoint resolution; note it in the smoke.
