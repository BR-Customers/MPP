# Terminal Mint Model — Plan 1: SQL Foundation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Lay the SQL foundation for the terminal-mint redesign — preserve the live validation dataset, add the Advance/Mint role-kind, retire the cell-coupling path, and rebase the terminal WIP queue on the route ("next unsatisfied step") — without yet changing mint behavior.

**Architecture:** Route becomes the single source of truth for which terminal a line-resident LOT queues at. A terminal of `OperationType` role R shows open LOTs at the line whose lowest-`SequenceNumber` route step with no matching `ProductionEvent` has role R. This plan delivers that queue engine + the schema it needs; the mint-behavior reworks (Machining OUT, Assembly ranked default) are Plan 2.

**Tech Stack:** SQL Server 2022, T-SQL stored procs (repeatable `R__` + versioned migrations), the repo's `Run-Tests` / `Reset-DevDatabase` harness, `sqlcmd`.

**Design source:** `docs/superpowers/specs/2026-07-07-terminal-mint-model-and-rename-bom-removal-design.md` (§3.2 queue rule, §3.10 mint-step placement, §4.1 role-kind, §5 cleanup inventory B1/B7, §5.5 data preservation).

## Global Constraints

- **Branch:** `jacques/working`. Confirm `git branch --show-current` before committing. Explicit path staging only (never `git add -A`/`-u`). Omit the `Co-Authored-By: Claude` trailer.
- **SQL conventions:** `UpperCamelCase` tables/columns; `BIGINT IDENTITY` PK; `BIGINT` FKs; `NVARCHAR` (never `VARCHAR`); `DATETIME2(3)`; UTC via `SYSUTCDATETIME()`; displayed times converted `AT TIME ZONE 'UTC' AT TIME ZONE 'Eastern Standard Time'`; all enum/status columns code-table-backed with FK; append-only events; `DeprecatedAt` soft deletes.
- **JDBC (FDS-11-011):** no `OUTPUT` params. Read procs: empty rowset = not found. Mutation procs end every exit path with `SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;`. `RAISERROR` (not `THROW`) in CATCH.
- **Seed/data strings ASCII-only** (sqlcmd codepage → mojibake otherwise); resolve every reference by natural key, never a hardcoded `Id`.
- **DATA PRESERVATION (spec §5.5):** the live dev DB holds 4 configured parts (Items + Routes + BOMs + `ItemLocation`) in active use for testing. **Never reset the DB before Task 1 has captured them into a re-runnable seed** kept current with this plan's schema changes.
- **Migration numbering:** repo is at `0033`; new versioned migrations take the next free numbers. This plan assumes `0034` (role-kind) and `0035` (drop coupling) — confirm the next free number at build with `ls sql/migrations/versioned`.
- **Run-Tests:** the suite must stay green (exit 0) after every task. Reset with `.\Reset-DevDatabase.ps1 -SkipDemoSeed` for test runs.

---

### Task 1: Capture the JP validation dataset to a seed file

Preserve Jacques's 4 configured parts before any schema change can force a reset. The seed re-creates their `Item` + `RouteTemplate`/`RouteStep` + `Bom`/`BomLine` + `ItemLocation` rows by natural key.

**Files:**
- Create: `sql/seeds/030_seed_jp_validation.sql`
- Reference (structure to mirror): `sql/seeds/020_seed_items.sql` (natural-key Item inserts), `sql/scratch/seed_demo.sql` (proc-driven BOM build via `Bom_Create`/`BomLine_Add`/`Bom_Publish`)

**Interfaces:**
- Produces: a re-runnable, idempotent seed `sql/seeds/030_seed_jp_validation.sql` that reproduces the 4-part config on a freshly reset DB.

- [ ] **Step 1: Enumerate the 4 parts and their config from the live DB**

Run and capture the output (these are read-only inventory queries):

```bash
sqlcmd -S localhost -d MPP_MES_Dev -E -b -I -C -Q "SET NOCOUNT ON;
SELECT i.Id, i.PartNumber, it.Code AS ItemType, i.Description, i.DefaultSubLotQty, u.Code AS Uom
FROM Parts.Item i
JOIN Parts.ItemType it ON it.Id=i.ItemTypeId
JOIN Parts.Uom u ON u.Id=i.UomId
WHERE i.DeprecatedAt IS NULL ORDER BY i.Id;"
```

Then, for each part, dump its routes, BOM lines, and eligibility:

```bash
sqlcmd -S localhost -d MPP_MES_Dev -E -b -I -C -Q "SET NOCOUNT ON;
SELECT rt.ItemId, i.PartNumber, rt.VersionNumber, rt.Name, rt.PublishedAt, rs.SequenceNumber, ot.Code AS OpTemplate, oty.Code AS OpType, rs.IsRequired
FROM Parts.RouteTemplate rt JOIN Parts.Item i ON i.Id=rt.ItemId
JOIN Parts.RouteStep rs ON rs.RouteTemplateId=rt.Id
JOIN Parts.OperationTemplate ot ON ot.Id=rs.OperationTemplateId
JOIN Parts.OperationType oty ON oty.Id=ot.OperationTypeId
WHERE rt.DeprecatedAt IS NULL ORDER BY rt.ItemId, rt.VersionNumber, rs.SequenceNumber;
SELECT b.ParentItemId, p.PartNumber AS Parent, bl.ChildItemId, c.PartNumber AS Child, bl.QtyPer, u.Code AS Uom
FROM Parts.Bom b JOIN Parts.Item p ON p.Id=b.ParentItemId
JOIN Parts.BomLine bl ON bl.BomId=b.Id JOIN Parts.Item c ON c.Id=bl.ChildItemId JOIN Parts.Uom u ON u.Id=bl.UomId
WHERE b.PublishedAt IS NOT NULL AND b.DeprecatedAt IS NULL ORDER BY b.ParentItemId;
SELECT il.ItemId, i.PartNumber, loc.Code AS Location, il.IsConsumptionPoint
FROM Parts.ItemLocation il JOIN Parts.Item i ON i.Id=il.ItemId JOIN Location.Location loc ON loc.Id=il.LocationId
ORDER BY il.ItemId;"
```

Expected: rows for the 4 configured parts. Record the exact `PartNumber`/`Code` natural keys.

- [ ] **Step 2: Write the idempotent seed from the captured data**

Author `sql/seeds/030_seed_jp_validation.sql` using the captured natural keys. Structure (fill the `VALUES` from Step 1 output — ASCII only, guarded inserts, natural-key lookups):

```sql
-- ============================================================
-- 030_seed_jp_validation.sql
-- Jacques's validation fixture: 4 configured parts (Item + Route +
-- BOM + ItemLocation), preserved from the live dev DB (spec §5.5).
-- Idempotent + natural-key resolved. Run AFTER migrations, BEFORE tests
-- that need the fixture. Distinct from seed_demo.sql (demo threads).
--   sqlcmd -S localhost -d MPP_MES_Dev -E -b -I -C -i sql/seeds/030_seed_jp_validation.sql
-- ============================================================
SET NOCOUNT ON; SET XACT_ABORT ON; USE MPP_MES_Dev;
GO
DECLARE @U BIGINT = (SELECT Id FROM Location.AppUser WHERE Initials = N'DEV');
DECLARE @UomEA BIGINT = (SELECT Id FROM Parts.Uom WHERE Code = N'EA');
-- ---- Items (one guarded INSERT per captured part; ItemType by Code) ----
-- <one block per part, e.g.:>
IF NOT EXISTS (SELECT 1 FROM Parts.Item WHERE PartNumber = N'<PN>')
    INSERT INTO Parts.Item (ItemTypeId, PartNumber, Description, DefaultSubLotQty, UomId, CreatedAt, CreatedByUserId)
    VALUES ((SELECT Id FROM Parts.ItemType WHERE Code = N'<ItemType>'), N'<PN>', N'<Desc>', <qty>, @UomEA, SYSUTCDATETIME(), @U);
GO
-- ---- Routes: build each via the production procs so lifecycle is authentic ----
-- (RouteTemplate_Create -> RouteTemplate_SaveAll(stepsJson) -> RouteTemplate_Publish),
--  resolving OperationTemplateId by OperationTemplate.Code. Guard on existing published route.
-- ---- BOMs: Bom_Create -> BomLine_Add(by ChildItemId, QtyPer) -> Bom_Publish, guarded. ----
-- ---- ItemLocation: guarded INSERT (ItemId by PartNumber, LocationId by Code, IsConsumptionPoint). ----
```

Reference `sql/scratch/seed_demo.sql` Step 3 for the exact `INSERT … EXEC Parts.Bom_Create/@bl/@bp` capture pattern with table variables.

- [ ] **Step 3: Verify the seed reproduces the dataset on a clean DB**

```bash
powershell -File .\Reset-DevDatabase.ps1 -SkipDemoSeed
sqlcmd -S localhost -d MPP_MES_Dev -E -b -I -C -i sql/seeds/030_seed_jp_validation.sql
sqlcmd -S localhost -d MPP_MES_Dev -E -b -I -C -Q "SELECT COUNT(*) AS Parts FROM Parts.Item WHERE DeprecatedAt IS NULL; SELECT COUNT(*) AS Routes FROM Parts.RouteTemplate WHERE PublishedAt IS NOT NULL; SELECT COUNT(*) AS Boms FROM Parts.Bom WHERE PublishedAt IS NOT NULL;"
```
Expected: counts match the 4-part fixture from Step 1. Re-run the seed a second time → no duplicates, no errors (idempotent).

- [ ] **Step 4: Commit**

```bash
git add sql/seeds/030_seed_jp_validation.sql
git commit -m "feat(seed): capture JP 4-part validation dataset (spec 5.5 data preservation)"
```

---

### Task 2: Add the Advance/Mint role-kind to OperationType

**Files:**
- Create: `sql/migrations/versioned/0034_operation_role_kind.sql`
- Reference: `sql/migrations/versioned/0032_operation_type_expand.sql` (MERGE-seed + nullable-add-then-NOT-NULL pattern)
- Test: `sql/tests/0009_Parts_Process/006_OperationRoleKind_seed.sql`

**Interfaces:**
- Produces: `Parts.OperationRoleKind (Id, Code, Name, …)` seeded `Advance`/`OriginMint`/`ConsumeMint`; `Parts.OperationType.OperationRoleKindId BIGINT NOT NULL FK`, backfilled per the §4.1 seed mapping.

- [ ] **Step 1: Write the failing test**

Create `sql/tests/0009_Parts_Process/006_OperationRoleKind_seed.sql` (follow the sibling `005_OperationType_seed.sql` shape — `SET NOCOUNT ON`, `RAISERROR` on mismatch):

```sql
-- Asserts the role-kind table + column seed/backfill (3 kinds per spec §4.1).
SET NOCOUNT ON;
IF (SELECT COUNT(*) FROM Parts.OperationRoleKind) <> 3 RAISERROR('Expected 3 OperationRoleKind rows.',16,1);
IF NOT EXISTS (SELECT 1 FROM Parts.OperationRoleKind WHERE Code=N'Advance')     RAISERROR('Missing Advance kind.',16,1);
IF NOT EXISTS (SELECT 1 FROM Parts.OperationRoleKind WHERE Code=N'OriginMint')  RAISERROR('Missing OriginMint kind.',16,1);
IF NOT EXISTS (SELECT 1 FROM Parts.OperationRoleKind WHERE Code=N'ConsumeMint') RAISERROR('Missing ConsumeMint kind.',16,1);
-- Every OperationType mapped, NOT NULL:
IF EXISTS (SELECT 1 FROM Parts.OperationType WHERE OperationRoleKindId IS NULL) RAISERROR('OperationType.OperationRoleKindId has NULLs.',16,1);
-- Spot-check the mapping:
IF (SELECT rk.Code FROM Parts.OperationType t JOIN Parts.OperationRoleKind rk ON rk.Id=t.OperationRoleKindId WHERE t.Code=N'DieCast')     <> N'OriginMint'  RAISERROR('DieCast must be OriginMint.',16,1);
IF (SELECT rk.Code FROM Parts.OperationType t JOIN Parts.OperationRoleKind rk ON rk.Id=t.OperationRoleKindId WHERE t.Code=N'MachiningIn') <> N'Advance'     RAISERROR('MachiningIn must be Advance.',16,1);
IF (SELECT rk.Code FROM Parts.OperationType t JOIN Parts.OperationRoleKind rk ON rk.Id=t.OperationRoleKindId WHERE t.Code=N'MachiningOut')<> N'ConsumeMint' RAISERROR('MachiningOut must be ConsumeMint.',16,1);
IF (SELECT rk.Code FROM Parts.OperationType t JOIN Parts.OperationRoleKind rk ON rk.Id=t.OperationRoleKindId WHERE t.Code=N'AssemblyOut') <> N'ConsumeMint' RAISERROR('AssemblyOut must be ConsumeMint.',16,1);
PRINT 'OperationRoleKind seed OK.';
```

- [ ] **Step 2: Run it to verify it fails**

Run: `sqlcmd -S localhost -d MPP_MES_Dev -E -b -I -C -i sql/tests/0009_Parts_Process/006_OperationRoleKind_seed.sql`
Expected: FAIL — `Invalid object name 'Parts.OperationRoleKind'`.

- [ ] **Step 3: Write the migration**

Create `sql/migrations/versioned/0034_operation_role_kind.sql`:

```sql
-- 0034_operation_role_kind.sql — add Advance/Mint role-kind (spec §4.1).
-- Idempotent-guarded; no explicit txn (repo convention).
IF OBJECT_ID(N'Parts.OperationRoleKind') IS NULL
CREATE TABLE Parts.OperationRoleKind (
    Id           BIGINT IDENTITY(1,1) NOT NULL CONSTRAINT PK_OperationRoleKind PRIMARY KEY,
    Code         NVARCHAR(20)  NOT NULL CONSTRAINT UQ_OperationRoleKind_Code UNIQUE,
    Name         NVARCHAR(100) NOT NULL,
    Description  NVARCHAR(500) NULL,
    CreatedAt    DATETIME2(3)  NOT NULL CONSTRAINT DF_OperationRoleKind_CreatedAt DEFAULT SYSUTCDATETIME(),
    DeprecatedAt DATETIME2(3)  NULL
);
GO
MERGE Parts.OperationRoleKind AS t
USING (VALUES (N'Advance',N'Advance'),(N'OriginMint',N'Origin Mint'),(N'ConsumeMint',N'Consume Mint')) AS s(Code,Name) ON t.Code=s.Code
WHEN NOT MATCHED THEN INSERT (Code,Name) VALUES (s.Code,s.Name);
GO
IF COL_LENGTH(N'Parts.OperationType', N'OperationRoleKindId') IS NULL
    ALTER TABLE Parts.OperationType ADD OperationRoleKindId BIGINT NULL
        CONSTRAINT FK_OperationType_RoleKind REFERENCES Parts.OperationRoleKind(Id);
GO
-- Backfill per spec §4.1 mapping: DieCast=OriginMint; MachiningOut/AssemblyOut=ConsumeMint; else Advance.
UPDATE t SET OperationRoleKindId = (SELECT Id FROM Parts.OperationRoleKind WHERE Code =
    CASE WHEN t.Code = N'DieCast' THEN N'OriginMint'
         WHEN t.Code IN (N'MachiningOut',N'AssemblyOut') THEN N'ConsumeMint'
         ELSE N'Advance' END)
FROM Parts.OperationType t WHERE t.OperationRoleKindId IS NULL;
GO
IF EXISTS (SELECT 1 FROM Parts.OperationType WHERE OperationRoleKindId IS NULL)
    RAISERROR(N'0034: OperationType rows unmapped to a role-kind.',16,1);
GO
ALTER TABLE Parts.OperationType ALTER COLUMN OperationRoleKindId BIGINT NOT NULL;
GO
IF NOT EXISTS (SELECT 1 FROM dbo.SchemaVersion WHERE MigrationId=N'0034_operation_role_kind')
    INSERT INTO dbo.SchemaVersion (MigrationId, Description)
    VALUES (N'0034_operation_role_kind', N'Add Parts.OperationRoleKind (Advance/OriginMint/ConsumeMint) + OperationType.OperationRoleKindId (NOT NULL, backfilled).');
GO
PRINT 'Migration 0034 (operation_role_kind) applied.';
GO
```

- [ ] **Step 4: Apply the migration and run the test to verify it passes**

Run: `powershell -File .\Reset-DevDatabase.ps1 -SkipDemoSeed` then the Step-1 test command.
Expected: PASS — `OperationRoleKind seed OK.`

- [ ] **Step 5: Commit**

```bash
git add sql/migrations/versioned/0034_operation_role_kind.sql sql/tests/0009_Parts_Process/006_OperationRoleKind_seed.sql
git commit -m "feat(parts): add Advance/Mint OperationRoleKind + OperationType FK"
```

---

### Task 3: Retire the cell-coupling auto-move path (spec §5 B7)

**Files:**
- Create: `sql/migrations/versioned/0035_drop_coupled_downstream_cell.sql`
- Delete: `sql/migrations/repeatable/R__Workorder_MachiningOut_AutoComplete.sql`
- Delete: `sql/tests/0027_PlantFloor_Machining/040_MachiningOut_AutoComplete_coupled.sql`, `050_MachiningOut_AutoComplete_uncoupled.sql`, `060_MachiningOut_blocked_lot.sql`
- Modify: `sql/migrations/versioned/0027_arc2_phase5_machining.sql` is immutable (already applied) — do NOT edit; the drop migration removes the `MachiningOutAutoMoved` audit event instead.

**Interfaces:**
- Produces: `Location.Location` without `CoupledDownstreamCellLocationId`; no `MachiningOut_AutoComplete` proc; no `MachiningOutAutoMoved` (LogEventType 44) event.

- [ ] **Step 1: Write the drop migration**

Create `sql/migrations/versioned/0035_drop_coupled_downstream_cell.sql`:

```sql
-- 0035_drop_coupled_downstream_cell.sql — retire the cell-resident auto-couple
-- path (spec §3.8/§5 B7); mints are line-resident, no cell->cell auto-move.
-- Drop the FK + index + column, and deprecate the MachiningOutAutoMoved event.
DECLARE @fk SYSNAME = (
    SELECT fk.name FROM sys.foreign_keys fk
    JOIN sys.foreign_key_columns fkc ON fkc.constraint_object_id=fk.object_id
    JOIN sys.columns c ON c.object_id=fkc.parent_object_id AND c.column_id=fkc.parent_column_id
    WHERE fk.parent_object_id=OBJECT_ID(N'Location.Location') AND c.name=N'CoupledDownstreamCellLocationId');
IF @fk IS NOT NULL EXEC(N'ALTER TABLE Location.Location DROP CONSTRAINT ' + @fk);
GO
IF EXISTS (SELECT 1 FROM sys.indexes WHERE name=N'IX_Location_CoupledDownstreamCellLocationId')
    DROP INDEX IX_Location_CoupledDownstreamCellLocationId ON Location.Location;
GO
IF COL_LENGTH(N'Location.Location', N'CoupledDownstreamCellLocationId') IS NOT NULL
    ALTER TABLE Location.Location DROP COLUMN CoupledDownstreamCellLocationId;
GO
-- Drop the now-dead proc if present (repeatable file is deleted; this covers an already-applied DB).
IF OBJECT_ID(N'Workorder.MachiningOut_AutoComplete') IS NOT NULL
    DROP PROCEDURE Workorder.MachiningOut_AutoComplete;
GO
-- Soft-retire the audit event type (keep the row for historical FK integrity; mark deprecated).
UPDATE Audit.LogEventType SET DeprecatedAt = SYSUTCDATETIME()
WHERE Code = N'MachiningOutAutoMoved' AND DeprecatedAt IS NULL;
GO
IF NOT EXISTS (SELECT 1 FROM dbo.SchemaVersion WHERE MigrationId=N'0035_drop_coupled_downstream_cell')
    INSERT INTO dbo.SchemaVersion (MigrationId, Description)
    VALUES (N'0035_drop_coupled_downstream_cell', N'Retire cell-coupling: drop Location.CoupledDownstreamCellLocationId + MachiningOut_AutoComplete + deprecate MachiningOutAutoMoved event.');
GO
PRINT 'Migration 0035 (drop_coupled_downstream_cell) applied.';
GO
```

> Note: verify the exact index name via `sqlcmd … -Q "SELECT name FROM sys.indexes WHERE object_id=OBJECT_ID('Location.Location') AND name LIKE '%Coupled%'"`; adjust the `DROP INDEX` name if it differs. Confirm the `Audit.LogEventType` table + `DeprecatedAt` column exist (`0027_arc2_phase5_machining.sql` seeded event 44); if the table has no `DeprecatedAt`, delete the row instead (guarded on no FK references in `Audit.OperationLog`).

- [ ] **Step 2: Delete the repeatable proc + its tests**

```bash
git rm sql/migrations/repeatable/R__Workorder_MachiningOut_AutoComplete.sql \
       sql/tests/0027_PlantFloor_Machining/040_MachiningOut_AutoComplete_coupled.sql \
       sql/tests/0027_PlantFloor_Machining/050_MachiningOut_AutoComplete_uncoupled.sql \
       sql/tests/0027_PlantFloor_Machining/060_MachiningOut_blocked_lot.sql
```

- [ ] **Step 3: Grep for stragglers**

Run: `grep -rn "CoupledDownstreamCellLocationId\|MachiningOut_AutoComplete\|MachiningOutAutoMoved" sql/`
Expected: only `0019_…`, `0027_…`, and the new `0035_…` (immutable historical migrations + the drop). Any live proc/seed/test reference is a straggler — remove it. (`seed_demo.sql` should not reference these; if it does, clean it.)

- [ ] **Step 4: Reset + full suite green**

Run: `powershell -File .\Reset-DevDatabase.ps1 -SkipDemoSeed` then `powershell -File .\Run-Tests.ps1`
Expected: exit 0, 0 failures (the deleted AutoComplete tests no longer run; nothing else references the dropped column).

- [ ] **Step 5: Commit**

```bash
git add sql/migrations/versioned/0035_drop_coupled_downstream_cell.sql
git commit -m "feat(location): retire cell-coupling (drop CoupledDownstreamCellLocationId + AutoComplete)"
```

---

### Task 4: Rebase the WIP queue on the route ("next unsatisfied step")

Rewrite `Lots.Lot_GetWipQueueByLocation` to return, for a given terminal role, the line-resident open LOTs whose next unsatisfied route step carries that role. Drop `HasRenameBom` and `HasLineEvent`.

**Files:**
- Modify: `sql/migrations/repeatable/R__Lots_Lot_GetWipQueueByLocation.sql`
- Test: `sql/tests/0024_PlantFloor_Movement_Trim/060_Lot_GetWipQueueByLocation.sql` (rewrite)

**Interfaces:**
- Consumes: `Parts.RouteTemplate`/`RouteStep`, `Parts.OperationTemplate`→`OperationType`, `Workorder.ProductionEvent`.
- Produces: `Lots.Lot_GetWipQueueByLocation(@LocationId BIGINT, @OperationTypeCode NVARCHAR(20) = NULL, @IncludeDescendants BIT = 0)` → rows `(Id, LotName, ItemId, ItemPartNumber, ItemDescription, PieceCount, LotStatusId, LotStatusCode, LastMovementAt, NextOperationTypeCode, NextSequenceNumber)`. When `@OperationTypeCode` is NULL, returns every open LOT at the location with its resolved next-step role (for inventory/debug reads); when supplied, filters to LOTs whose next step = that role.

- [ ] **Step 1: Rewrite the test first**

Replace `sql/tests/0024_PlantFloor_Movement_Trim/060_Lot_GetWipQueueByLocation.sql` with route-driven assertions. Use the fixture pattern from the existing file (create an AppUser/Item/Location as needed, or lean on the seeded plant). Concrete shape:

```sql
-- Route-driven WIP queue: a LOT surfaces at the terminal whose role = its
-- next-unsatisfied route step; a ProductionEvent on that step advances it.
SET NOCOUNT ON;
DECLARE @U BIGINT=(SELECT Id FROM Location.AppUser WHERE Initials=N'DEV');
-- Pick a JP-validation part with a route beginning at MachiningIn, and a line location.
DECLARE @Item BIGINT=(SELECT TOP 1 rt.ItemId FROM Parts.RouteTemplate rt
    JOIN Parts.RouteStep rs ON rs.RouteTemplateId=rt.Id AND rs.SequenceNumber=(SELECT MIN(SequenceNumber) FROM Parts.RouteStep WHERE RouteTemplateId=rt.Id)
    JOIN Parts.OperationTemplate ot ON ot.Id=rs.OperationTemplateId
    JOIN Parts.OperationType oty ON oty.Id=ot.OperationTypeId
    WHERE rt.PublishedAt IS NOT NULL AND rt.DeprecatedAt IS NULL AND oty.Code=N'MachiningIn');
IF @Item IS NULL RAISERROR('Fixture: need a published route starting at MachiningIn (run 030_seed_jp_validation).',16,1);
DECLARE @Line BIGINT=(SELECT Id FROM Location.Location WHERE Code=N'MA1-FPRPY');
DECLARE @Origin BIGINT=(SELECT Id FROM Lots.LotOriginType WHERE Code=N'Manufactured');
-- Mint a LOT at the line via the production proc:
DECLARE @r TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT, MintedLotName NVARCHAR(50));
INSERT INTO @r EXEC Lots.Lot_Create @ItemId=@Item, @LotOriginTypeId=@Origin, @CurrentLocationId=@Line, @PieceCount=10, @AppUserId=@U;
DECLARE @Lot BIGINT=(SELECT NewId FROM @r);
-- (1) With no events, it must appear for the MachiningIn terminal:
DECLARE @q TABLE (Id BIGINT, LotName NVARCHAR(50), ItemId BIGINT, ItemPartNumber NVARCHAR(50), ItemDescription NVARCHAR(500), PieceCount INT, LotStatusId BIGINT, LotStatusCode NVARCHAR(20), LastMovementAt DATETIME2(3), NextOperationTypeCode NVARCHAR(20), NextSequenceNumber INT);
DELETE FROM @q; INSERT INTO @q EXEC Lots.Lot_GetWipQueueByLocation @LocationId=@Line, @OperationTypeCode=N'MachiningIn';
IF NOT EXISTS (SELECT 1 FROM @q WHERE Id=@Lot) RAISERROR('LOT should be in the MachiningIn queue with no events.',16,1);
-- (2) It must NOT appear for a later role yet (e.g. AssemblyOut):
DELETE FROM @q; INSERT INTO @q EXEC Lots.Lot_GetWipQueueByLocation @LocationId=@Line, @OperationTypeCode=N'AssemblyOut';
IF EXISTS (SELECT 1 FROM @q WHERE Id=@Lot) RAISERROR('LOT must not be in AssemblyOut queue before MachiningIn is done.',16,1);
-- (3) Stamp a MachiningIn ProductionEvent -> it leaves the MachiningIn queue:
DECLARE @MinTpl BIGINT=(SELECT rs.OperationTemplateId FROM Parts.RouteTemplate rt JOIN Parts.RouteStep rs ON rs.RouteTemplateId=rt.Id JOIN Parts.OperationTemplate ot ON ot.Id=rs.OperationTemplateId JOIN Parts.OperationType oty ON oty.Id=ot.OperationTypeId WHERE rt.ItemId=@Item AND rt.PublishedAt IS NOT NULL AND rt.DeprecatedAt IS NULL AND oty.Code=N'MachiningIn');
INSERT INTO Workorder.ProductionEvent (LotId, OperationTemplateId, EventAt, ShotCount, AppUserId) VALUES (@Lot, @MinTpl, SYSUTCDATETIME(), 10, @U);
DELETE FROM @q; INSERT INTO @q EXEC Lots.Lot_GetWipQueueByLocation @LocationId=@Line, @OperationTypeCode=N'MachiningIn';
IF EXISTS (SELECT 1 FROM @q WHERE Id=@Lot) RAISERROR('LOT should leave MachiningIn queue after its MachiningIn event.',16,1);
-- Teardown (FK-safe): events -> movements/status/closure -> lot.
DELETE FROM Workorder.ProductionEvent WHERE LotId=@Lot;
DELETE FROM Lots.LotMovement WHERE LotId=@Lot; DELETE FROM Lots.LotStatusHistory WHERE LotId=@Lot;
DELETE FROM Lots.LotGenealogyClosure WHERE AncestorLotId=@Lot OR DescendantLotId=@Lot; DELETE FROM Lots.Lot WHERE Id=@Lot;
PRINT 'Route-driven WIP queue OK.';
```

- [ ] **Step 2: Run it to verify it fails**

Run: `powershell -File .\Reset-DevDatabase.ps1 -SkipDemoSeed; sqlcmd -S localhost -d MPP_MES_Dev -E -b -I -C -i sql/seeds/030_seed_jp_validation.sql; sqlcmd -S localhost -d MPP_MES_Dev -E -b -I -C -i sql/tests/0024_PlantFloor_Movement_Trim/060_Lot_GetWipQueueByLocation.sql`
Expected: FAIL — the current proc has no `@OperationTypeCode` param / returns `HasRenameBom`, so the new assertions error.

- [ ] **Step 3: Rewrite the proc**

Replace the body of `sql/migrations/repeatable/R__Lots_Lot_GetWipQueueByLocation.sql` (bump header to v3.0, describe the route-driven rule). New body:

```sql
CREATE OR ALTER PROCEDURE Lots.Lot_GetWipQueueByLocation
    @LocationId         BIGINT,
    @OperationTypeCode  NVARCHAR(20) = NULL,
    @IncludeDescendants BIT = 0
AS
BEGIN
    SET NOCOUNT ON;
    ;WITH Descendants AS (
        SELECT @LocationId AS Id
        UNION ALL
        SELECT c.Id FROM Location.Location c INNER JOIN Descendants d ON c.ParentLocationId = d.Id
    ),
    LastMove AS (
        SELECT m.LotId, MAX(m.MovedAt) AS LastMovementAt FROM Lots.LotMovement m GROUP BY m.LotId
    ),
    -- Each open LOT at the location joined to the PENDING steps of its active
    -- (published, non-deprecated) route; rank by SequenceNumber to find the next one.
    -- "Pending" depends on the step's role-kind (spec §3.2/§4.1):
    --   Advance     -> pending until a matching ProductionEvent exists
    --   OriginMint  -> never pending (the LOT exists => it was minted there)
    --   ConsumeMint -> always pending while the LOT is open (terminal; leaves by closing)
    NextStep AS (
        SELECT l.Id AS LotId, rs.SequenceNumber, rs.OperationTemplateId,
               ROW_NUMBER() OVER (PARTITION BY l.Id ORDER BY rs.SequenceNumber ASC) AS rn
        FROM Lots.Lot l
        INNER JOIN Lots.LotStatusCode sc ON sc.Id = l.LotStatusId AND sc.Code <> N'Closed'
        INNER JOIN Parts.RouteTemplate rt ON rt.ItemId = l.ItemId
             AND rt.PublishedAt IS NOT NULL AND rt.DeprecatedAt IS NULL
        INNER JOIN Parts.RouteStep rs ON rs.RouteTemplateId = rt.Id
        INNER JOIN Parts.OperationTemplate ot2 ON ot2.Id = rs.OperationTemplateId
        INNER JOIN Parts.OperationType oty2    ON oty2.Id = ot2.OperationTypeId
        INNER JOIN Parts.OperationRoleKind rk  ON rk.Id  = oty2.OperationRoleKindId
        WHERE (
                  (@IncludeDescendants = 1 AND l.CurrentLocationId IN (SELECT Id FROM Descendants))
               OR (@IncludeDescendants = 0 AND l.CurrentLocationId = @LocationId)
              )
          AND (
                  rk.Code = N'ConsumeMint'                       -- terminal: pending while open
               OR (rk.Code = N'Advance' AND NOT EXISTS (
                      SELECT 1 FROM Workorder.ProductionEvent pe
                      WHERE pe.LotId = l.Id AND pe.OperationTemplateId = rs.OperationTemplateId))
                  -- OriginMint: never pending (omitted)
              )
    )
    SELECT
        l.Id, l.LotName, l.ItemId,
        i.PartNumber  AS ItemPartNumber,
        i.Description AS ItemDescription,
        l.PieceCount, l.LotStatusId, sc.Code AS LotStatusCode,
        CAST(lm.LastMovementAt AT TIME ZONE 'UTC' AT TIME ZONE 'Eastern Standard Time' AS DATETIME2(3)) AS LastMovementAt,
        oty.Code AS NextOperationTypeCode,
        ns.SequenceNumber AS NextSequenceNumber
    FROM NextStep ns
    INNER JOIN Lots.Lot l               ON l.Id = ns.LotId AND ns.rn = 1
    INNER JOIN Lots.LotStatusCode sc    ON sc.Id = l.LotStatusId
    INNER JOIN Parts.Item i             ON i.Id  = l.ItemId
    INNER JOIN Parts.OperationTemplate ot ON ot.Id = ns.OperationTemplateId
    INNER JOIN Parts.OperationType oty  ON oty.Id = ot.OperationTypeId
    LEFT  JOIN LastMove lm              ON lm.LotId = l.Id
    WHERE (@OperationTypeCode IS NULL OR oty.Code = @OperationTypeCode)
    ORDER BY lm.LastMovementAt ASC, l.Id ASC
    OPTION (MAXRECURSION 8);
END;
GO
```

> Design notes for the implementer: a LOT with no active published route produces no `NextStep` rows → it silently drops out of every terminal queue (correct — an unconfigured part isn't workable). A `ConsumeMint` terminal step keeps the LOT in that terminal's queue across repeated partial mints until it is fully consumed and `Closed` (then excluded). If a part legitimately has no route yet, "not in any queue" is prevented at authoring time by Plan 2's route-legality validation.

- [ ] **Step 4: Run the test to verify it passes**

Run the Step-2 command chain again.
Expected: PASS — `Route-driven WIP queue OK.`

- [ ] **Step 5: Full suite green**

Run: `powershell -File .\Run-Tests.ps1`
Expected: exit 0. If other tests referenced `HasRenameBom`/`HasLineEvent` columns from this proc, fix them to the new shape (the audit flagged `090_Rework_LOT_in_queue.sql`, `100_Lot_GetLineInventoryByPart.sql`, and any Machining/Assembly test asserting those columns — update their `INSERT … EXEC` temp-table shapes and drop the removed-column assertions).

- [ ] **Step 6: Commit**

```bash
git add sql/migrations/repeatable/R__Lots_Lot_GetWipQueueByLocation.sql sql/tests/0024_PlantFloor_Movement_Trim/060_Lot_GetWipQueueByLocation.sql
git commit -m "feat(lots): route-driven WIP queue (next unsatisfied step); drop rename/line hints"
```

---

## Self-Review

- **Spec coverage (this plan's slice):** §5.5 data preservation → Task 1. §4.1 role-kind → Task 2. §5 B7 coupling retire → Task 3. §3.2/§3.9 route-driven queue + drop `HasRenameBom`/`HasLineEvent` → Task 4. ✔ The remaining spec items are explicitly deferred to Plans 2–4 (below).
- **Placeholder scan:** Task 1's seed `VALUES` are filled from live-DB output at execution (unavoidable — the data lives in the DB, not the spec); the surrounding structure, queries, and verification are concrete. No `TODO`/"handle edge cases" left.
- **Type consistency:** `Lot_GetWipQueueByLocation` new signature `(@LocationId, @OperationTypeCode, @IncludeDescendants)` and result columns are used identically in Task 4's test and proc.

## Deferred to later plans (roadmap)

- **Plan 2 — Mint behavior + validation:** rework `MachiningOut_RecordSplit` → consume-mint (`Consumption` genealogy casting→machined, produced part derived via BOM + line-eligibility, flexible operator qty prefilled from `DefaultSubLotQty`, drop intra-line destination + `Split`); `Assembly_CompleteTray` ranked-FG default read proc (B5); route-legality structural validation (§4.2 option C) in the route-save proc; scope `Lot_Split` to exception-only (B8); rebuild `seed_demo.sql` machining thread on the mint model (B9); reworked `0027`/`0028` tests (B12).
- **Plan 3 — Ignition UI (Designer):** MachiningOutSplit (drop `HasRenameBom` filter + destination dropdown → mint UI), Assembly FG dropdown + ranked default, repoint all 6 views to the `@OperationTypeCode` queue read, new Core NQs (U5/U6/U7). Executed in Designer per the view-edit boundary, not file-edit TDD.
- **Plan 4 — Docs:** FDS-06-007/05-033 et al., Data Model, User Journeys, task list / phased plan, supersede the 2026-07-06 intermediate spec (D1–D8).
