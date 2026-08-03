# Die Cast Per-Cavity Open/Accumulate/Release Lifecycle — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the die-cast one-basket-per-create origin mint with a per-cavity LOT open → accumulate → release lifecycle: each cavity of a mounted die owns an independent `Open` basket LOT that accumulates good parts across operators and shifts and is released to storage (its first route movement) when full.

**Architecture:** New SQL surface (one migration + five new procs + one new read + three changed reads) drives the lifecycle; die-cast scrap stays additive (already built in `RejectEvent_Record`); a new `Workorder.DieCastContribution` ledger records each shift's net-good delta per cavity LOT. Ignition adds Core NQs + inert entity glue; the `DieCastBody` view is reworked in Designer (Shape-1 die-wide shift entry + per-cavity scrap + release/void). Spec: `docs/superpowers/specs/2026-07-28-diecast-per-cavity-lifecycle-design.md`.

**Tech Stack:** SQL Server 2022 (T-SQL, repeatable + versioned migrations, `test.*` assertion framework), Ignition 8.3 Perspective (file-based views, Core Named Queries, Jython script modules).

## Global Constraints

- **Branch:** `jacques/working` (never `main`). A concurrent session sometimes leaves uncommitted work (e.g. `Core/…/Location/Location/code.py`) — stage explicit paths only, never `git add -A`/`-u`.
- **Validate on throwaway `MPP_MES_Test`** via `sql/tests/Run-Tests.ps1` (it resets that DB). Never destructively reset `MPP_MES_Dev`; apply repeatable procs to Dev with `sqlcmd -d MPP_MES_Dev -i <file>` (CREATE OR ALTER = data-safe).
- **FDS-11-011:** no `OUTPUT` params. Mutation procs end every exit path with `SELECT @Status AS Status, @Message AS Message[, @NewId AS NewId];`. Read procs return one result set, empty = not found.
- **Msg-3915 / INSERT-EXEC:** all rejecting validations run **before** `BEGIN TRANSACTION`; the CATCH is the only legal `ROLLBACK` site; `RAISERROR` (not `THROW`) in CATCH. A status-row proc must **inline** sub-mutations, never `EXEC` a sibling status-row proc.
- **Time:** store UTC via `SYSUTCDATETIME()`; convert to ET at read boundaries via `CAST(<col> AT TIME ZONE 'UTC' AT TIME ZONE 'Eastern Standard Time' AS DATETIME2(3))`.
- **Codes/enums:** code-table-backed FKs, no magic integers. Seeds ASCII-only (byte-scan). Append new status/audit Ids — never renumber existing.
- **Audit:** Description shape `<SUBJECT> · <CATEGORY> · <ACTION>` via `Audit.ufn_MidDot()` + `Audit.ufn_TruncateActivity()`; resolved-name FK JSON (`{Id, Code, Name}`) in Old/NewValue.
- **NQ typing:** status-row procs → NQ `type: "Query"`; reads → `type: "Query"`. After any Ignition resource change run `.\scan.ps1`.
- **No business logic in Python:** all lifecycle rules live in SQL; entity scripts are inert glue. Operation template resolved by **role** (`DieCast`), never by template code.
- **Migration number:** current max applied is `0044`; this plan's versioned migration is **`0045`**. Re-verify `SELECT MAX(...)` of `LogEventType` Ids at build time (PLC-merge collision lesson) before hardcoding audit Ids.

---

## File Structure

**New — SQL:**
- `sql/migrations/versioned/0045_diecast_per_cavity_lifecycle.sql` — `Open` LotStatusCode, `Workorder.DieCastContribution` table, 4 audit `LogEventType` seeds.
- `sql/migrations/repeatable/R__Lots_DieCastLot_Open.sql`
- `sql/migrations/repeatable/R__Workorder_DieCast_GetShiftOutputBreakdown.sql` (read)
- `sql/migrations/repeatable/R__Workorder_DieCastShiftOutput_Record.sql` (write)
- `sql/migrations/repeatable/R__Lots_DieCastLot_Release.sql`
- `sql/migrations/repeatable/R__Lots_DieCastLot_Void.sql`
- `sql/migrations/repeatable/R__Lots_Lot_GetOpenByTool.sql` (read)
- `sql/tests/0045_DieCast_Lifecycle/010_migration_and_schema.sql`
- `sql/tests/0045_DieCast_Lifecycle/020_DieCastLot_Open.sql`
- `sql/tests/0045_DieCast_Lifecycle/030_ShiftOutput_Record.sql`
- `sql/tests/0045_DieCast_Lifecycle/040_Release_and_queue.sql`
- `sql/tests/0045_DieCast_Lifecycle/050_Void.sql`
- `sql/tests/0045_DieCast_Lifecycle/060_Tally_history_openbytool.sql`

**Modified — SQL:**
- `sql/migrations/repeatable/R__Lots_Lot_GetWipQueueByLocation.sql` (exclude `Open`)
- `sql/migrations/repeatable/R__Lots_Lot_GetShiftCavityTally.sql` (per-cavity-LOT rework, additive-scrap fix)
- `sql/migrations/repeatable/R__Lots_Lot_GetAttributeHistory.sql` (add Stream 10 `Contribution`)

**New — Ignition (Core):**
- `ignition/projects/Core/ignition/named-query/lots/DieCastLot_Open/{query.sql,resource.json}`
- `.../named-query/workorder/DieCast_GetShiftOutputBreakdown/…`
- `.../named-query/workorder/DieCastShiftOutput_Record/…`
- `.../named-query/lots/DieCastLot_Release/…`
- `.../named-query/lots/DieCastLot_Void/…`
- `.../named-query/lots/Lot_GetOpenByTool/…`
- `ignition/projects/Core/ignition/script-python/BlueRidge/Workorder/DieCast/code.py` (new module)

**Modified — Ignition:**
- `ignition/projects/Core/ignition/script-python/BlueRidge/Lots/Lot/code.py` (add `openDieCast`/`releaseDieCast`/`voidDieCast`/`getOpenByTool`)
- `ignition/projects/MPP/.../Views/ShopFloor/DieCastBody/view.json` + `Components/PlantFloor/DieCastEntry/*` (**Designer** — Phase 6)

---

## Phase 0 — Foundation (migration)

### Task 1: Migration — `Open` status, `DieCastContribution` table, audit seeds

**Files:**
- Create: `sql/migrations/versioned/0045_diecast_per_cavity_lifecycle.sql`
- Test: `sql/tests/0045_DieCast_Lifecycle/010_migration_and_schema.sql`

**Interfaces:**
- Produces: `Lots.LotStatusCode` row `Open` (BlocksProduction 0); `Workorder.DieCastContribution(Id, LotId, ShiftId, PieceDelta, AppUserId, TerminalLocationId, EventAt)`; `Audit.LogEventType` codes `DieCastLotOpened`, `DieCastPieceContributed`, `DieCastLotReleased`, `DieCastLotVoided`.

- [ ] **Step 1: Write the failing test**

```sql
-- sql/tests/0045_DieCast_Lifecycle/010_migration_and_schema.sql
SET NOCOUNT ON; SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0045_DieCast_Lifecycle/010_migration_and_schema.sql';
GO
DECLARE @openId NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM Lots.LotStatusCode WHERE Code = N'Open' AND BlocksProduction = 0);
EXEC test.Assert_IsEqual @TestName = N'[0045] Open status seeded, BlocksProduction 0', @Expected = N'1', @Actual = @openId;
DECLARE @orig NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM Lots.LotStatusCode WHERE Id IN (1,2,3,4) AND Code IN (N'Good',N'Hold',N'Scrap',N'Closed'));
EXEC test.Assert_IsEqual @TestName = N'[0045] existing status Ids 1-4 unchanged', @Expected = N'4', @Actual = @orig;
DECLARE @tbl NVARCHAR(10) = (SELECT CASE WHEN OBJECT_ID(N'Workorder.DieCastContribution',N'U') IS NOT NULL THEN N'1' ELSE N'0' END);
EXEC test.Assert_IsEqual @TestName = N'[0045] DieCastContribution table exists', @Expected = N'1', @Actual = @tbl;
DECLARE @cols NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM sys.columns
    WHERE object_id = OBJECT_ID(N'Workorder.DieCastContribution')
      AND name IN (N'Id',N'LotId',N'ShiftId',N'PieceDelta',N'AppUserId',N'TerminalLocationId',N'EventAt'));
EXEC test.Assert_IsEqual @TestName = N'[0045] DieCastContribution has 7 expected columns', @Expected = N'7', @Actual = @cols;
DECLARE @evt NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM Audit.LogEventType
    WHERE Code IN (N'DieCastLotOpened',N'DieCastPieceContributed',N'DieCastLotReleased',N'DieCastLotVoided'));
EXEC test.Assert_IsEqual @TestName = N'[0045] 4 audit LogEventTypes seeded', @Expected = N'4', @Actual = @evt;
GO
EXEC test.EndTestFile;
GO
```

- [ ] **Step 2: Run test to verify it fails**

Run: `.\sql\tests\Run-Tests.ps1 -Filter "0045"`
Expected: FAIL (migration not written — `Open` absent, table missing).

- [ ] **Step 3: Write the migration**

```sql
-- sql/migrations/versioned/0045_diecast_per_cavity_lifecycle.sql
SET NOCOUNT ON; SET XACT_ABORT ON;
BEGIN TRANSACTION;

-- 1. Open status (append; do NOT renumber 1-4). Let IDENTITY assign the next Id.
IF NOT EXISTS (SELECT 1 FROM Lots.LotStatusCode WHERE Code = N'Open')
    INSERT INTO Lots.LotStatusCode (Code, Name, BlocksProduction, Description)
    VALUES (N'Open', N'Open', 0, N'Accumulating at the press; not yet on its route (die-cast basket).');

-- 2. DieCastContribution ledger
IF OBJECT_ID(N'Workorder.DieCastContribution', N'U') IS NULL
BEGIN
    CREATE TABLE Workorder.DieCastContribution (
        Id                 BIGINT       NOT NULL IDENTITY(1,1) PRIMARY KEY,
        LotId              BIGINT       NOT NULL REFERENCES Lots.Lot(Id),
        ShiftId            BIGINT       NULL     REFERENCES Oee.Shift(Id),
        PieceDelta         INT          NOT NULL,
        AppUserId          BIGINT       NOT NULL REFERENCES Location.AppUser(Id),
        TerminalLocationId BIGINT       NULL     REFERENCES Location.Location(Id),
        EventAt            DATETIME2(3) NOT NULL DEFAULT SYSUTCDATETIME(),
        CONSTRAINT CK_DieCastContribution_DeltaNonNeg CHECK (PieceDelta >= 0)
    );
    CREATE INDEX IX_DieCastContribution_Lot   ON Workorder.DieCastContribution (LotId);
    CREATE INDEX IX_DieCastContribution_Shift ON Workorder.DieCastContribution (ShiftId, LotId);
END

-- 3. Audit LogEventTypes (Id-or-Code guarded; take the next free ids at build time)
DECLARE @nextId INT = (SELECT ISNULL(MAX(Id),0) + 1 FROM Audit.LogEventType);
INSERT INTO Audit.LogEventType (Id, Code, Name, Description)
SELECT @nextId + rn, v.Code, v.Name, v.Descr
FROM (VALUES
    (N'DieCastLotOpened',        N'Die Cast LOT Opened',       N'A die-cast accumulator basket LOT was opened (status Open).'),
    (N'DieCastPieceContributed', N'Die Cast Piece Contributed',N'Good pieces added to an open die-cast basket for a shift.'),
    (N'DieCastLotReleased',      N'Die Cast LOT Released',      N'An open die-cast basket was released to storage (Open->Good).'),
    (N'DieCastLotVoided',        N'Die Cast LOT Voided',        N'An empty open die-cast basket was voided (Open->Scrap).')
) v(Code, Name, Descr)
CROSS APPLY (SELECT (ROW_NUMBER() OVER (ORDER BY (SELECT 1))) - 1 AS rn) r
WHERE NOT EXISTS (SELECT 1 FROM Audit.LogEventType e WHERE e.Code = v.Code);

INSERT INTO dbo.SchemaVersion (MigrationId, Description)
VALUES ('0045_diecast_per_cavity_lifecycle',
        'Die-cast per-cavity lifecycle: Open LotStatusCode, Workorder.DieCastContribution ledger, 4 audit LogEventTypes.');
COMMIT TRANSACTION;
PRINT 'Migration 0045 completed.';
```

- [ ] **Step 4: Run test to verify it passes**

Run: `.\sql\tests\Run-Tests.ps1 -Filter "0045"`
Expected: 5 assertions PASS.

- [ ] **Step 5: Commit**

```bash
git add sql/migrations/versioned/0045_diecast_per_cavity_lifecycle.sql sql/tests/0045_DieCast_Lifecycle/010_migration_and_schema.sql
git commit -m "feat(diecast): 0045 migration - Open status, DieCastContribution table, audit seeds"
```

---

## Phase 1 — Open

### Task 2: `Lots.DieCastLot_Open`

**Files:**
- Create: `sql/migrations/repeatable/R__Lots_DieCastLot_Open.sql`
- Test: `sql/tests/0045_DieCast_Lifecycle/020_DieCastLot_Open.sql`

**Interfaces:**
- Consumes: `Lots.LotStatusCode.Open` (Task 1); `Tools.ToolAssignment`, `Tools.ToolCavity`, `Parts.RouteTemplate`/`RouteStep`/`OperationType` (`OperationRoleKind='OriginMint'`, code `DieCast`), `Lots.ufn_IsValidExternalLtt`.
- Produces: `EXEC Lots.DieCastLot_Open @ItemId, @CurrentLocationId, @ToolId, @ToolCavityId, @LotName, @AppUserId, @TerminalLocationId` → result set `Status BIT, Message NVARCHAR(500), NewId BIGINT`.

- [ ] **Step 1: Write the failing test**

```sql
-- sql/tests/0045_DieCast_Lifecycle/020_DieCastLot_Open.sql
SET NOCOUNT ON; SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0045_DieCast_Lifecycle/020_DieCastLot_Open.sql';
GO
-- cleanup (FK-safe)
DELETE cl FROM Lots.LotGenealogyClosure cl INNER JOIN Lots.Lot l ON l.Id IN (cl.AncestorLotId, cl.DescendantLotId) WHERE l.LotName LIKE N'DCO-020-%';
DELETE m  FROM Lots.LotMovement m INNER JOIN Lots.Lot l ON l.Id = m.LotId WHERE l.LotName LIKE N'DCO-020-%';
DELETE h  FROM Lots.LotStatusHistory h INNER JOIN Lots.Lot l ON l.Id = h.LotId WHERE l.LotName LIKE N'DCO-020-%';
DELETE le FROM Lots.LotEventLog le INNER JOIN Lots.Lot l ON l.Id = le.LotId WHERE l.LotName LIKE N'DCO-020-%';
DELETE FROM Lots.Lot WHERE LotName LIKE N'DCO-020-%';
GO
-- Fixture: reuse an existing die-cast-eligible Item+Tool+Cavity+cell with a published DieCast route.
-- Resolve the demo/seed die-cast setup dynamically (no legacy-seed coupling).
DECLARE @Cavity BIGINT = (SELECT TOP 1 tc.Id FROM Tools.ToolCavity tc
    INNER JOIN Tools.ToolCavityStatusCode sc ON sc.Id = tc.StatusCodeId AND sc.Code = N'Active'
    INNER JOIN Tools.ToolAssignment ta ON ta.ToolId = tc.ToolId AND ta.ReleasedAt IS NULL
    ORDER BY tc.Id);
DECLARE @Tool BIGINT = (SELECT ToolId FROM Tools.ToolCavity WHERE Id = @Cavity);
DECLARE @Cell BIGINT = (SELECT TOP 1 ta.CellLocationId FROM Tools.ToolAssignment ta WHERE ta.ToolId = @Tool AND ta.ReleasedAt IS NULL);
DECLARE @Item BIGINT = (SELECT TOP 1 rt.ItemId FROM Parts.RouteTemplate rt
    INNER JOIN Parts.RouteStep rs ON rs.RouteTemplateId = rt.Id
    INNER JOIN Parts.OperationTemplate ot ON ot.Id = rs.OperationTemplateId
    INNER JOIN Parts.OperationType oty ON oty.Id = ot.OperationTypeId
    INNER JOIN Parts.OperationRoleKind rk ON rk.Id = oty.OperationRoleKindId AND rk.Code = N'OriginMint'
    WHERE rt.PublishedAt IS NOT NULL AND rt.DeprecatedAt IS NULL
      AND EXISTS (SELECT 1 FROM Parts.v_EffectiveItemLocation eil WHERE eil.ItemId = rt.ItemId
                  AND eil.LocationId IN (SELECT LocationId FROM Location.ufn_AncestorLocationIds(@Cell)))
    ORDER BY rt.ItemId);

-- Test 1: happy open
DECLARE @R1 TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO @R1 EXEC Lots.DieCastLot_Open @ItemId=@Item, @CurrentLocationId=@Cell, @ToolId=@Tool,
    @ToolCavityId=@Cavity, @LotName=N'DCO-020-1', @AppUserId=1, @TerminalLocationId=NULL;
DECLARE @s1 NVARCHAR(10) = (SELECT CAST(Status AS NVARCHAR(10)) FROM @R1);
EXEC test.Assert_IsEqual @TestName=N'[Open] happy path Status 1', @Expected=N'1', @Actual=@s1;
DECLARE @newId BIGINT = (SELECT NewId FROM @R1);
DECLARE @openState NVARCHAR(20) = (SELECT sc.Code FROM Lots.Lot l INNER JOIN Lots.LotStatusCode sc ON sc.Id=l.LotStatusId WHERE l.Id=@newId);
EXEC test.Assert_IsEqual @TestName=N'[Open] LOT status Open', @Expected=N'Open', @Actual=@openState;
DECLARE @pc NVARCHAR(10) = (SELECT CAST(PieceCount AS NVARCHAR(10)) FROM Lots.Lot WHERE Id=@newId);
EXEC test.Assert_IsEqual @TestName=N'[Open] PieceCount 0', @Expected=N'0', @Actual=@pc;
DECLARE @cav NVARCHAR(20) = (SELECT CAST(ToolCavityId AS NVARCHAR(20)) FROM Lots.Lot WHERE Id=@newId);
DECLARE @cavExp NVARCHAR(20) = CAST(@Cavity AS NVARCHAR(20));
EXEC test.Assert_IsEqual @TestName=N'[Open] cavity FK stamped', @Expected=@cavExp, @Actual=@cav;

-- Test 2: one-open-per-(tool,cavity) guard
DECLARE @R2 TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO @R2 EXEC Lots.DieCastLot_Open @ItemId=@Item, @CurrentLocationId=@Cell, @ToolId=@Tool,
    @ToolCavityId=@Cavity, @LotName=N'DCO-020-2', @AppUserId=1, @TerminalLocationId=NULL;
DECLARE @s2 BIT = (SELECT Status FROM @R2); DECLARE @s2c BIT = CASE WHEN @s2=0 THEN 1 ELSE 0 END;
EXEC test.Assert_IsTrue @TestName=N'[Open] second open on same cavity rejected', @Condition=@s2c;
DECLARE @m2 NVARCHAR(500) = (SELECT Message FROM @R2);
EXEC test.Assert_Contains @TestName=N'[Open] guard message mentions open', @HaystackStr=@m2, @NeedleStr=N'open';

-- Test 3: invalid LTT format rejected
DECLARE @R3 TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO @R3 EXEC Lots.DieCastLot_Open @ItemId=@Item, @CurrentLocationId=@Cell, @ToolId=@Tool,
    @ToolCavityId=@Cavity, @LotName=N'DCO-020-1', @AppUserId=1, @TerminalLocationId=NULL;
-- (also a duplicate LotName; either invalid-format OR duplicate must reject)
DECLARE @s3 BIT = (SELECT Status FROM @R3); DECLARE @s3c BIT = CASE WHEN @s3=0 THEN 1 ELSE 0 END;
EXEC test.Assert_IsTrue @TestName=N'[Open] invalid/duplicate LTT rejected', @Condition=@s3c;

-- Test 4: opened LOT is NOT on the Trim WIP queue (excluded while Open)
DECLARE @Q TABLE (Position INT, LotId BIGINT, LotName NVARCHAR(50), ItemPartNumber NVARCHAR(50), PieceCount INT, ArrivedAt DATETIME2(3));
INSERT INTO @Q EXEC Lots.Lot_GetWipQueueByLocation @LocationId=@Cell, @OperationTypeCode=N'TrimIn', @IncludeDescendants=1;
DECLARE @inQ NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM @Q WHERE LotId=@newId);
EXEC test.Assert_IsEqual @TestName=N'[Open] Open LOT not on Trim queue', @Expected=N'0', @Actual=@inQ;
GO
-- cleanup (repeat block from top)
DELETE cl FROM Lots.LotGenealogyClosure cl INNER JOIN Lots.Lot l ON l.Id IN (cl.AncestorLotId, cl.DescendantLotId) WHERE l.LotName LIKE N'DCO-020-%';
DELETE m  FROM Lots.LotMovement m INNER JOIN Lots.Lot l ON l.Id = m.LotId WHERE l.LotName LIKE N'DCO-020-%';
DELETE h  FROM Lots.LotStatusHistory h INNER JOIN Lots.Lot l ON l.Id = h.LotId WHERE l.LotName LIKE N'DCO-020-%';
DELETE le FROM Lots.LotEventLog le INNER JOIN Lots.Lot l ON l.Id = le.LotId WHERE l.LotName LIKE N'DCO-020-%';
DELETE FROM Lots.Lot WHERE LotName LIKE N'DCO-020-%';
GO
EXEC test.EndTestFile;
GO
```

- [ ] **Step 2: Run test to verify it fails**

Run: `.\sql\tests\Run-Tests.ps1 -Filter "020_DieCastLot_Open"`
Expected: FAIL ("Could not find stored procedure 'Lots.DieCastLot_Open'").

- [ ] **Step 3: Write the proc**

Model it on `R__Lots_Lot_Create.sql` (mint mechanics, status-history/closure/first-movement) but with status `Open`, `PieceCount 0`, and the die-cast open validations. Full proc:

```sql
-- sql/migrations/repeatable/R__Lots_DieCastLot_Open.sql
CREATE OR ALTER PROCEDURE Lots.DieCastLot_Open
    @ItemId BIGINT, @CurrentLocationId BIGINT, @ToolId BIGINT, @ToolCavityId BIGINT,
    @LotName NVARCHAR(50), @AppUserId BIGINT, @TerminalLocationId BIGINT = NULL
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;
    DECLARE @Status BIT = 0, @Message NVARCHAR(500) = N'Unknown error', @NewId BIGINT = NULL;
    DECLARE @ProcName NVARCHAR(200) = N'Lots.DieCastLot_Open';
    DECLARE @Params NVARCHAR(MAX) = (SELECT @ItemId AS ItemId, @CurrentLocationId AS CurrentLocationId,
        @ToolId AS ToolId, @ToolCavityId AS ToolCavityId, @LotName AS LotName, @AppUserId AS AppUserId
        FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);
    DECLARE @OpenStatusId BIGINT = (SELECT Id FROM Lots.LotStatusCode WHERE Code = N'Open');
    DECLARE @ManufacturedOriginId BIGINT = (SELECT Id FROM Lots.LotOriginType WHERE Code = N'Manufactured');
    DECLARE @MaxLotSize INT, @CellCode NVARCHAR(50);

    BEGIN TRY
        -- ---- validations (all pre-transaction) ----
        IF @ItemId IS NULL OR @CurrentLocationId IS NULL OR @ToolId IS NULL OR @ToolCavityId IS NULL
           OR @LotName IS NULL OR @AppUserId IS NULL
        BEGIN SET @Message = N'Required parameter missing.'; GOTO Fail; END
        IF NOT EXISTS (SELECT 1 FROM Parts.Item WHERE Id = @ItemId AND DeprecatedAt IS NULL)
        BEGIN SET @Message = N'Item not found or deprecated.'; GOTO Fail; END
        IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Id = @CurrentLocationId)
        BEGIN SET @Message = N'Location not found.'; GOTO Fail; END
        IF NOT EXISTS (SELECT 1 FROM Location.AppUser WHERE Id = @AppUserId)
        BEGIN SET @Message = N'AppUser not found.'; GOTO Fail; END
        -- die-cast gate: active ToolAssignment for @ToolId on the cell
        IF NOT EXISTS (SELECT 1 FROM Tools.ToolAssignment WHERE ToolId = @ToolId AND CellLocationId = @CurrentLocationId AND ReleasedAt IS NULL)
        BEGIN SET @Message = N'No active die mounted for this tool at this cell.'; GOTO Fail; END
        -- cavity belongs to the tool and is Active
        IF NOT EXISTS (SELECT 1 FROM Tools.ToolCavity tc INNER JOIN Tools.ToolCavityStatusCode sc ON sc.Id = tc.StatusCodeId
                       WHERE tc.Id = @ToolCavityId AND tc.ToolId = @ToolId AND sc.Code = N'Active')
        BEGIN SET @Message = N'Cavity is not an active cavity of this tool.'; GOTO Fail; END
        -- LTT format + uniqueness
        IF Lots.ufn_IsValidExternalLtt(@LotName) = 0
        BEGIN SET @Message = N'LTT ' + @LotName + N' is not a valid external LTT (9 digits).'; GOTO Fail; END
        IF EXISTS (SELECT 1 FROM Lots.Lot WHERE LotName = @LotName)
        BEGIN SET @Message = N'LTT ' + @LotName + N' is already in use.'; GOTO Fail; END
        -- route has a DieCast (OriginMint) step
        IF NOT EXISTS (SELECT 1 FROM Parts.RouteTemplate rt
            INNER JOIN Parts.RouteStep rs ON rs.RouteTemplateId = rt.Id
            INNER JOIN Parts.OperationTemplate ot ON ot.Id = rs.OperationTemplateId
            INNER JOIN Parts.OperationType oty ON oty.Id = ot.OperationTypeId
            WHERE rt.ItemId = @ItemId AND rt.PublishedAt IS NOT NULL AND rt.DeprecatedAt IS NULL
              AND oty.Code = N'DieCast')
        BEGIN SET @Message = N'This part has no published route with a Die Cast step.'; GOTO Fail; END
        -- one-open-per-(tool,cavity)
        IF EXISTS (SELECT 1 FROM Lots.Lot l INNER JOIN Lots.LotStatusCode sc ON sc.Id = l.LotStatusId
                   WHERE l.ToolId = @ToolId AND l.ToolCavityId = @ToolCavityId AND sc.Code = N'Open')
        BEGIN SET @Message = N'An open basket already exists for this cavity; release it before opening another.'; GOTO Fail; END

        SET @MaxLotSize = (SELECT MaxLotSize FROM Parts.Item WHERE Id = @ItemId);
        SET @CellCode   = (SELECT Code FROM Location.Location WHERE Id = @CurrentLocationId);

        -- ===== mutation =====
        BEGIN TRANSACTION;
        INSERT INTO Lots.Lot (LotName, ItemId, LotOriginTypeId, LotStatusId, PieceCount, MaxPieceCount,
            ToolId, ToolCavityId, CurrentLocationId, TotalInProcess, InventoryAvailable,
            CreatedByUserId, CreatedAtTerminalId, CreatedAt)
        VALUES (@LotName, @ItemId, @ManufacturedOriginId, @OpenStatusId, 0, @MaxLotSize,
            @ToolId, @ToolCavityId, @CurrentLocationId, 0, 0, @AppUserId, @TerminalLocationId, SYSUTCDATETIME());
        SET @NewId = SCOPE_IDENTITY();
        INSERT INTO Lots.LotStatusHistory (LotId, OldStatusId, NewStatusId, Reason, ChangedByUserId, TerminalLocationId, ChangedAt)
        VALUES (@NewId, NULL, @OpenStatusId, N'Die-cast basket opened.', @AppUserId, @TerminalLocationId, SYSUTCDATETIME());
        INSERT INTO Lots.LotGenealogyClosure (AncestorLotId, DescendantLotId, Depth) VALUES (@NewId, @NewId, 0);
        INSERT INTO Lots.LotMovement (LotId, FromLocationId, ToLocationId, MovedByUserId, TerminalLocationId, MovedAt)
        VALUES (@NewId, NULL, @CurrentLocationId, @AppUserId, @TerminalLocationId, SYSUTCDATETIME());

        DECLARE @Activity NVARCHAR(500) = Audit.ufn_TruncateActivity(@LotName + N' ' + Audit.ufn_MidDot()
            + N' Die Cast ' + Audit.ufn_MidDot() + N' Basket opened at ' + ISNULL(@CellCode, N'?'));
        DECLARE @NewValue NVARCHAR(MAX) = (SELECT l.Id, l.LotName,
            JSON_QUERY((SELECT i.Id, i.PartNumber AS Code, i.Description AS Name FROM Parts.Item i WHERE i.Id = l.ItemId FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)) AS Item,
            JSON_QUERY((SELECT tc.Id, tc.CavityNumber AS Code, tc.CavityNumber AS Name FROM Tools.ToolCavity tc WHERE tc.Id = l.ToolCavityId FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)) AS Cavity
            FROM Lots.Lot l WHERE l.Id = @NewId FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);
        EXEC Audit.Audit_LogOperation @AppUserId=@AppUserId, @TerminalLocationId=@TerminalLocationId, @LocationId=@CurrentLocationId,
            @LogEntityTypeCode=N'Lot', @EntityId=@NewId, @LogEventTypeCode=N'DieCastLotOpened',
            @LogSeverityCode=N'Info', @Description=@Activity, @OldValue=NULL, @NewValue=@NewValue;
        COMMIT TRANSACTION;

        SET @Status = 1; SET @Message = N'Basket opened (' + @LotName + N').';
        SELECT @Status AS Status, @Message AS Message, @NewId AS NewId; RETURN;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        DECLARE @ErrMsg NVARCHAR(4000)=ERROR_MESSAGE(), @ErrSev INT=ERROR_SEVERITY(), @ErrState INT=ERROR_STATE();
        SET @Status=0; SET @NewId=NULL; SET @Message=N'Unexpected error: ' + LEFT(@ErrMsg,400);
        BEGIN TRY EXEC Audit.Audit_LogFailure @AppUserId=@AppUserId, @LogEntityTypeCode=N'Lot', @EntityId=NULL,
            @LogEventTypeCode=N'DieCastLotOpened', @FailureReason=@Message, @ProcedureName=@ProcName, @AttemptedParameters=@Params; END TRY BEGIN CATCH END CATCH
        SELECT @Status AS Status, @Message AS Message, @NewId AS NewId; RAISERROR(@ErrMsg,@ErrSev,@ErrState); RETURN;
    END CATCH
Fail:
    EXEC Audit.Audit_LogFailure @AppUserId=@AppUserId, @LogEntityTypeCode=N'Lot', @EntityId=NULL,
        @LogEventTypeCode=N'DieCastLotOpened', @FailureReason=@Message, @ProcedureName=@ProcName, @AttemptedParameters=@Params;
    SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
END;
GO
```

- [ ] **Step 4: Run test to verify it passes**

Run: `.\sql\tests\Run-Tests.ps1 -Filter "0045"`
Expected: all Task-1 + Task-2 assertions PASS.

- [ ] **Step 5: Commit**

```bash
git add sql/migrations/repeatable/R__Lots_DieCastLot_Open.sql sql/tests/0045_DieCast_Lifecycle/020_DieCastLot_Open.sql
git commit -m "feat(diecast): DieCastLot_Open - mint per-cavity Open basket + guards"
```

---

## Phase 2 — Record shift output (breakdown read + write)

### Task 3: `Workorder.DieCast_GetShiftOutputBreakdown` (read)

**Files:**
- Create: `sql/migrations/repeatable/R__Workorder_DieCast_GetShiftOutputBreakdown.sql`
- Test: `sql/tests/0045_DieCast_Lifecycle/030_ShiftOutput_Record.sql` (shared with Task 4; write the read-half assertions here)

**Interfaces:**
- Consumes: `Workorder.DieCastContribution` (Task 1), `Lots.Lot`, `Tools.ToolCavity`, `Oee.Shift`.
- Produces: `EXEC Workorder.DieCast_GetShiftOutputBreakdown @ToolId, @ShiftId, @GrossShots` → columns `ToolCavityId, CavityNumber, LotId, LotName, IsOpen BIT, PriorGoodThisShift INT, ProposedGood INT, MaxHeadroom INT`.

- [ ] **Step 1: Write the failing test (read half)**

```sql
-- sql/tests/0045_DieCast_Lifecycle/030_ShiftOutput_Record.sql  (Part A: breakdown read)
SET NOCOUNT ON; SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0045_DieCast_Lifecycle/030_ShiftOutput_Record.sql';
GO
-- Assumes a helper that opens an Open basket via Lots.DieCastLot_Open for a known tool/cavity.
-- Arrange: open one basket on cavity C for tool T; an open shift S with ActualStart in the past.
DECLARE @Cavity BIGINT = (SELECT TOP 1 tc.Id FROM Tools.ToolCavity tc
    INNER JOIN Tools.ToolCavityStatusCode sc ON sc.Id=tc.StatusCodeId AND sc.Code=N'Active'
    INNER JOIN Tools.ToolAssignment ta ON ta.ToolId=tc.ToolId AND ta.ReleasedAt IS NULL ORDER BY tc.Id);
DECLARE @Tool BIGINT = (SELECT ToolId FROM Tools.ToolCavity WHERE Id=@Cavity);
DECLARE @Cell BIGINT = (SELECT TOP 1 CellLocationId FROM Tools.ToolAssignment WHERE ToolId=@Tool AND ReleasedAt IS NULL);
DECLARE @Item BIGINT = (SELECT TOP 1 rt.ItemId FROM Parts.RouteTemplate rt
    INNER JOIN Parts.RouteStep rs ON rs.RouteTemplateId=rt.Id
    INNER JOIN Parts.OperationTemplate ot ON ot.Id=rs.OperationTemplateId
    INNER JOIN Parts.OperationType oty ON oty.Id=ot.OperationTypeId AND oty.Code=N'DieCast'
    WHERE rt.PublishedAt IS NOT NULL AND rt.DeprecatedAt IS NULL
      AND EXISTS (SELECT 1 FROM Parts.v_EffectiveItemLocation eil WHERE eil.ItemId=rt.ItemId
                  AND eil.LocationId IN (SELECT LocationId FROM Location.ufn_AncestorLocationIds(@Cell))));
DELETE FROM Lots.Lot WHERE LotName = N'303030301';  -- idempotent
DECLARE @O TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO @O EXEC Lots.DieCastLot_Open @ItemId=@Item, @CurrentLocationId=@Cell, @ToolId=@Tool,
    @ToolCavityId=@Cavity, @LotName=N'303030301', @AppUserId=1, @TerminalLocationId=NULL;
DECLARE @Lot BIGINT = (SELECT NewId FROM @O);
DECLARE @Shift BIGINT = (SELECT TOP 1 Id FROM Oee.Shift WHERE ActualEnd IS NULL ORDER BY ActualStart DESC);
IF @Shift IS NULL
BEGIN
    INSERT INTO Oee.Shift (ShiftScheduleId, ActualStart) VALUES ((SELECT TOP 1 Id FROM Oee.ShiftSchedule), DATEADD(HOUR,-2,SYSUTCDATETIME()));
    SET @Shift = SCOPE_IDENTITY();
END

DECLARE @B TABLE (ToolCavityId BIGINT, CavityNumber NVARCHAR(50), LotId BIGINT, LotName NVARCHAR(50),
    IsOpen BIT, PriorGoodThisShift INT, ProposedGood INT, MaxHeadroom INT);
INSERT INTO @B EXEC Workorder.DieCast_GetShiftOutputBreakdown @ToolId=@Tool, @ShiftId=@Shift, @GrossShots=100;
DECLARE @row NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM @B WHERE LotId=@Lot AND IsOpen=1);
EXEC test.Assert_IsEqual @TestName=N'[Breakdown] open basket row present', @Expected=N'1', @Actual=@row;
DECLARE @prop NVARCHAR(10) = (SELECT CAST(ProposedGood AS NVARCHAR(10)) FROM @B WHERE LotId=@Lot);
EXEC test.Assert_IsEqual @TestName=N'[Breakdown] proposed good = gross (no prior, no scrap yet)', @Expected=N'100', @Actual=@prop;
GO
```

- [ ] **Step 2: Run to verify it fails**

Run: `.\sql\tests\Run-Tests.ps1 -Filter "030_ShiftOutput"`
Expected: FAIL (proc missing).

- [ ] **Step 3: Write the read proc**

```sql
-- sql/migrations/repeatable/R__Workorder_DieCast_GetShiftOutputBreakdown.sql
CREATE OR ALTER PROCEDURE Workorder.DieCast_GetShiftOutputBreakdown
    @ToolId BIGINT, @ShiftId BIGINT, @GrossShots INT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @ShiftStart DATETIME2(3) = (SELECT ActualStart FROM Oee.Shift WHERE Id = @ShiftId);
    DECLARE @ShiftEnd   DATETIME2(3) = (SELECT ISNULL(ActualEnd, SYSUTCDATETIME()) FROM Oee.Shift WHERE Id = @ShiftId);

    -- All lots for this tool that were open at any point during the shift window: currently Open,
    -- OR released/closed with a contribution recorded in the shift window.
    ;WITH Lots AS (
        SELECT l.Id AS LotId, l.LotName, l.ToolCavityId, l.PieceCount, l.MaxPieceCount,
               CASE WHEN sc.Code = N'Open' THEN 1 ELSE 0 END AS IsOpen
        FROM Lots.Lot l
        INNER JOIN Lots.LotStatusCode sc ON sc.Id = l.LotStatusId
        WHERE l.ToolId = @ToolId
          AND ( sc.Code = N'Open'
                OR EXISTS (SELECT 1 FROM Workorder.DieCastContribution c
                           WHERE c.LotId = l.Id AND c.ShiftId = @ShiftId) )
    ),
    Prior AS (   -- good already credited to each lot IN THIS SHIFT
        SELECT c.LotId, SUM(c.PieceDelta) AS PriorGood
        FROM Workorder.DieCastContribution c WHERE c.ShiftId = @ShiftId GROUP BY c.LotId
    )
    SELECT
        lo.ToolCavityId,
        tc.CavityNumber,
        lo.LotId, lo.LotName, lo.IsOpen,
        ISNULL(p.PriorGood, 0) AS PriorGoodThisShift,
        -- proposed good: a closed lot keeps what it recorded; the open lot gets the remainder of gross
        CASE WHEN lo.IsOpen = 0 THEN ISNULL(p.PriorGood, 0)
             ELSE CASE WHEN @GrossShots - ISNULL((SELECT SUM(c2.PieceDelta) FROM Workorder.DieCastContribution c2
                          INNER JOIN Lots.Lot l2 ON l2.Id = c2.LotId
                          WHERE c2.ShiftId = @ShiftId AND l2.ToolCavityId = lo.ToolCavityId AND c2.LotId <> lo.LotId), 0) < 0
                       THEN 0
                       ELSE @GrossShots - ISNULL((SELECT SUM(c2.PieceDelta) FROM Workorder.DieCastContribution c2
                          INNER JOIN Lots.Lot l2 ON l2.Id = c2.LotId
                          WHERE c2.ShiftId = @ShiftId AND l2.ToolCavityId = lo.ToolCavityId AND c2.LotId <> lo.LotId), 0)
                  END
        END AS ProposedGood,
        CASE WHEN lo.MaxPieceCount IS NULL THEN 2147483647 ELSE lo.MaxPieceCount - lo.PieceCount END AS MaxHeadroom
    FROM Lots lo
    INNER JOIN Tools.ToolCavity tc ON tc.Id = lo.ToolCavityId
    ORDER BY tc.CavityNumber, lo.IsOpen DESC;
END;
GO
```

- [ ] **Step 4: Run to verify it passes**

Run: `.\sql\tests\Run-Tests.ps1 -Filter "0045"`
Expected: read-half assertions PASS.

- [ ] **Step 5: Commit**

```bash
git add sql/migrations/repeatable/R__Workorder_DieCast_GetShiftOutputBreakdown.sql sql/tests/0045_DieCast_Lifecycle/030_ShiftOutput_Record.sql
git commit -m "feat(diecast): DieCast_GetShiftOutputBreakdown - per-cavity shift split read"
```

### Task 4: `Workorder.DieCastShiftOutput_Record` (write)

**Files:**
- Create: `sql/migrations/repeatable/R__Workorder_DieCastShiftOutput_Record.sql`
- Test: append to `sql/tests/0045_DieCast_Lifecycle/030_ShiftOutput_Record.sql`

**Interfaces:**
- Consumes: `Workorder.DieCastContribution`, `Workorder.RejectEvent` (additive path), `Parts.OperationType.ScrapIsAdditive` for the `DieCast` op-type, `Lots.Lot`.
- Produces: `EXEC Workorder.DieCastShiftOutput_Record @ShiftId, @ToolId, @LinesJson, @ShotLossJson, @AppUserId, @TerminalLocationId` → `Status, Message, NewId (NULL)`. `@LinesJson` = `[{"lotId":N,"pieceDelta":N,"scrapLines":[{"defectCodeId":N,"quantity":N}]}]`; `@ShotLossJson` = `[{"defectCodeId":N,"quantity":N}]`.

- [ ] **Step 1: Write the failing test (write half — append to 030 before EndTestFile)**

```sql
-- Part B: write. Uses @Lot / @Shift / @Tool / @Cavity from Part A (same file, same batch scope re-declared).
DECLARE @DefectCode BIGINT = (SELECT TOP 1 Id FROM Quality.DefectCode WHERE DeprecatedAt IS NULL ORDER BY Id);
DECLARE @Lines NVARCHAR(MAX) = N'[{"lotId":' + CAST(@Lot AS NVARCHAR(20))
    + N',"pieceDelta":95,"scrapLines":[{"defectCodeId":' + CAST(@DefectCode AS NVARCHAR(20)) + N',"quantity":5}]}]';
DECLARE @W TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO @W EXEC Workorder.DieCastShiftOutput_Record @ShiftId=@Shift, @ToolId=@Tool, @LinesJson=@Lines,
    @ShotLossJson=NULL, @AppUserId=1, @TerminalLocationId=NULL;
DECLARE @ws NVARCHAR(10) = (SELECT CAST(Status AS NVARCHAR(10)) FROM @W);
EXEC test.Assert_IsEqual @TestName=N'[Record] Status 1', @Expected=N'1', @Actual=@ws;
-- basket got the NET good (95), not decremented by the additive scrap
DECLARE @pcAfter NVARCHAR(10) = (SELECT CAST(PieceCount AS NVARCHAR(10)) FROM Lots.Lot WHERE Id=@Lot);
EXEC test.Assert_IsEqual @TestName=N'[Record] basket PieceCount += net good (95)', @Expected=N'95', @Actual=@pcAfter;
-- contribution row recorded with operator + shift
DECLARE @contrib NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM Workorder.DieCastContribution
    WHERE LotId=@Lot AND ShiftId=@Shift AND PieceDelta=95 AND AppUserId=1);
EXEC test.Assert_IsEqual @TestName=N'[Record] contribution row present', @Expected=N'1', @Actual=@contrib;
-- additive reject recorded, LOT not decremented, not closed
DECLARE @rej NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM Workorder.RejectEvent WHERE LotId=@Lot AND Quantity=5);
EXEC test.Assert_IsEqual @TestName=N'[Record] additive scrap RejectEvent present', @Expected=N'1', @Actual=@rej;
DECLARE @stillOpen NVARCHAR(20) = (SELECT sc.Code FROM Lots.Lot l INNER JOIN Lots.LotStatusCode sc ON sc.Id=l.LotStatusId WHERE l.Id=@Lot);
EXEC test.Assert_IsEqual @TestName=N'[Record] basket still Open (additive scrap never closes)', @Expected=N'Open', @Actual=@stillOpen;
GO
```

- [ ] **Step 2: Run to verify it fails**

Run: `.\sql\tests\Run-Tests.ps1 -Filter "030_ShiftOutput"`
Expected: FAIL (write proc missing).

- [ ] **Step 3: Write the write proc**

Shred `@LinesJson`/`@ShotLossJson`; validate each lot is `Open`; then per line insert the contribution + increment + inlined additive `RejectEvent` rows. Inline the additive reject (mirror `R__Workorder_RejectEvent_Record.sql` `@Additive=1` branch — record only, no decrement, no close). Full proc:

```sql
-- sql/migrations/repeatable/R__Workorder_DieCastShiftOutput_Record.sql
CREATE OR ALTER PROCEDURE Workorder.DieCastShiftOutput_Record
    @ShiftId BIGINT, @ToolId BIGINT, @LinesJson NVARCHAR(MAX),
    @ShotLossJson NVARCHAR(MAX) = NULL, @AppUserId BIGINT, @TerminalLocationId BIGINT = NULL
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;
    DECLARE @Status BIT = 0, @Message NVARCHAR(500) = N'Unknown error', @NewId BIGINT = NULL;
    DECLARE @ProcName NVARCHAR(200) = N'Workorder.DieCastShiftOutput_Record';
    DECLARE @Params NVARCHAR(MAX) = (SELECT @ShiftId AS ShiftId, @ToolId AS ToolId, LEFT(@LinesJson,2000) AS LinesJson, @AppUserId AS AppUserId FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

    BEGIN TRY
        IF @ShiftId IS NULL OR @ToolId IS NULL OR @LinesJson IS NULL OR @AppUserId IS NULL
        BEGIN SET @Message=N'Required parameter missing.'; GOTO Fail; END
        IF ISJSON(@LinesJson) <> 1 OR (@ShotLossJson IS NOT NULL AND ISJSON(@ShotLossJson) <> 1)
        BEGIN SET @Message=N'LinesJson/ShotLossJson not valid JSON.'; GOTO Fail; END
        IF NOT EXISTS (SELECT 1 FROM Location.AppUser WHERE Id=@AppUserId) BEGIN SET @Message=N'AppUser not found.'; GOTO Fail; END

        DECLARE @Lines TABLE (LotId BIGINT, PieceDelta INT, ScrapLines NVARCHAR(MAX));
        INSERT INTO @Lines (LotId, PieceDelta, ScrapLines)
        SELECT j.lotId, j.pieceDelta, j.scrapLines
        FROM OPENJSON(@LinesJson) WITH (lotId BIGINT N'$.lotId', pieceDelta INT N'$.pieceDelta', scrapLines NVARCHAR(MAX) N'$.scrapLines' AS JSON) j;

        -- every line lot must be Open and on this tool
        IF EXISTS (SELECT 1 FROM @Lines ln LEFT JOIN Lots.Lot l ON l.Id=ln.LotId
                   LEFT JOIN Lots.LotStatusCode sc ON sc.Id=l.LotStatusId
                   WHERE l.Id IS NULL OR sc.Code <> N'Open' OR l.ToolId <> @ToolId)
        BEGIN SET @Message=N'A submitted lot is not an open basket on this tool.'; GOTO Fail; END
        IF EXISTS (SELECT 1 FROM @Lines WHERE PieceDelta < 0) BEGIN SET @Message=N'pieceDelta cannot be negative.'; GOTO Fail; END

        -- ===== mutation =====
        BEGIN TRANSACTION;
        DECLARE @LotId BIGINT, @Delta INT, @Scrap NVARCHAR(MAX);
        DECLARE cur CURSOR LOCAL FAST_FORWARD FOR SELECT LotId, PieceDelta, ScrapLines FROM @Lines;
        OPEN cur; FETCH NEXT FROM cur INTO @LotId, @Delta, @Scrap;
        WHILE @@FETCH_STATUS = 0
        BEGIN
            IF @Delta > 0
            BEGIN
                INSERT INTO Workorder.DieCastContribution (LotId, ShiftId, PieceDelta, AppUserId, TerminalLocationId, EventAt)
                VALUES (@LotId, @ShiftId, @Delta, @AppUserId, @TerminalLocationId, SYSUTCDATETIME());
                UPDATE Lots.Lot WITH (UPDLOCK, HOLDLOCK)
                SET PieceCount = PieceCount + @Delta, InventoryAvailable = InventoryAvailable + @Delta,
                    UpdatedAt = SYSUTCDATETIME(), UpdatedByUserId = @AppUserId
                WHERE Id = @LotId;
                DECLARE @LotName NVARCHAR(50) = (SELECT LotName FROM Lots.Lot WHERE Id=@LotId);
                DECLARE @Act NVARCHAR(500) = Audit.ufn_TruncateActivity(@LotName + N' ' + Audit.ufn_MidDot()
                    + N' Die Cast ' + Audit.ufn_MidDot() + N' Added ' + CAST(@Delta AS NVARCHAR(10)) + N' pc');
                EXEC Audit.Audit_LogOperation @AppUserId=@AppUserId, @TerminalLocationId=@TerminalLocationId, @LocationId=NULL,
                    @LogEntityTypeCode=N'Lot', @EntityId=@LotId, @LogEventTypeCode=N'DieCastPieceContributed',
                    @LogSeverityCode=N'Info', @Description=@Act, @OldValue=NULL, @NewValue=NULL;
            END
            -- inlined ADDITIVE scrap rows (mirror RejectEvent_Record @Additive=1: record only, no decrement, no close)
            IF @Scrap IS NOT NULL AND ISJSON(@Scrap) = 1
                INSERT INTO Workorder.RejectEvent (ProductionEventId, LotId, DefectCodeId, Quantity, ChargeToArea, Remarks, AppUserId, RecordedAt)
                SELECT NULL, @LotId, s.defectCodeId, s.quantity, NULL, N'Die-cast per-cavity scrap', @AppUserId, SYSUTCDATETIME()
                FROM OPENJSON(@Scrap) WITH (defectCodeId BIGINT N'$.defectCodeId', quantity INT N'$.quantity') s;
            FETCH NEXT FROM cur INTO @LotId, @Delta, @Scrap;
        END
        CLOSE cur; DEALLOCATE cur;

        -- shot-loss fan-out: an additive reject on EVERY active cavity's open lot for this tool
        IF @ShotLossJson IS NOT NULL AND ISJSON(@ShotLossJson) = 1
            INSERT INTO Workorder.RejectEvent (ProductionEventId, LotId, DefectCodeId, Quantity, ChargeToArea, Remarks, AppUserId, RecordedAt)
            SELECT NULL, l.Id, sl.defectCodeId, sl.quantity, NULL, N'Die-cast shot loss (all cavities)', @AppUserId, SYSUTCDATETIME()
            FROM OPENJSON(@ShotLossJson) WITH (defectCodeId BIGINT N'$.defectCodeId', quantity INT N'$.quantity') sl
            CROSS JOIN Lots.Lot l INNER JOIN Lots.LotStatusCode sc ON sc.Id=l.LotStatusId
            WHERE l.ToolId=@ToolId AND sc.Code=N'Open';

        COMMIT TRANSACTION;
        SET @Status=1; SET @Message=N'Shift output recorded.';
        SELECT @Status AS Status, @Message AS Message, @NewId AS NewId; RETURN;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        DECLARE @ErrMsg NVARCHAR(4000)=ERROR_MESSAGE(), @ErrSev INT=ERROR_SEVERITY(), @ErrState INT=ERROR_STATE();
        SET @Status=0; SET @Message=N'Unexpected error: ' + LEFT(@ErrMsg,400);
        BEGIN TRY EXEC Audit.Audit_LogFailure @AppUserId=@AppUserId, @LogEntityTypeCode=N'Lot', @EntityId=NULL,
            @LogEventTypeCode=N'DieCastPieceContributed', @FailureReason=@Message, @ProcedureName=@ProcName, @AttemptedParameters=@Params; END TRY BEGIN CATCH END CATCH
        SELECT @Status AS Status, @Message AS Message, @NewId AS NewId; RAISERROR(@ErrMsg,@ErrSev,@ErrState); RETURN;
    END CATCH
Fail:
    EXEC Audit.Audit_LogFailure @AppUserId=@AppUserId, @LogEntityTypeCode=N'Lot', @EntityId=NULL,
        @LogEventTypeCode=N'DieCastPieceContributed', @FailureReason=@Message, @ProcedureName=@ProcName, @AttemptedParameters=@Params;
    SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
END;
GO
```

- [ ] **Step 4: Run to verify it passes**

Run: `.\sql\tests\Run-Tests.ps1 -Filter "0045"`
Expected: all Part-A + Part-B assertions PASS.

- [ ] **Step 5: Commit**

```bash
git add sql/migrations/repeatable/R__Workorder_DieCastShiftOutput_Record.sql sql/tests/0045_DieCast_Lifecycle/030_ShiftOutput_Record.sql
git commit -m "feat(diecast): DieCastShiftOutput_Record - net-good contributions + additive scrap + shot-loss fan-out"
```

---

## Phase 3 — Release, Void, queue exclusion

### Task 5: `Lots.Lot_GetWipQueueByLocation` excludes `Open`

**Files:**
- Modify: `sql/migrations/repeatable/R__Lots_Lot_GetWipQueueByLocation.sql`
- Test: covered by Task 2 Test 4 (Open LOT not on queue) + a new released-lot-appears assertion in Task 6.

- [ ] **Step 1:** In `R__Lots_Lot_GetWipQueueByLocation.sql`, change **every** `sc.Code <> N'Closed'` to `sc.Code NOT IN (N'Closed', N'Open')` (both the main predicate and the `NextStep` CTE join — grep the file to catch all).
- [ ] **Step 2:** Run: `.\sql\tests\Run-Tests.ps1 -Filter "0045"` → Task-2 Test-4 (Open not on queue) still PASS. Run the existing machining queue suite: `.\sql\tests\Run-Tests.ps1 -Filter "0027"` → no regressions.
- [ ] **Step 3: Commit**

```bash
git add sql/migrations/repeatable/R__Lots_Lot_GetWipQueueByLocation.sql
git commit -m "feat(diecast): exclude Open baskets from the WIP queue"
```

### Task 6: `Lots.DieCastLot_Release` + `Lots.DieCastLot_Void`

**Files:**
- Create: `sql/migrations/repeatable/R__Lots_DieCastLot_Release.sql`, `sql/migrations/repeatable/R__Lots_DieCastLot_Void.sql`
- Test: `sql/tests/0045_DieCast_Lifecycle/040_Release_and_queue.sql`, `sql/tests/0045_DieCast_Lifecycle/050_Void.sql`

**Interfaces:**
- Produces:
  - `EXEC Lots.DieCastLot_Release @LotId, @StorageLocationId=NULL, @FinalPieceDelta=NULL, @ScrapLinesJson=NULL, @ShiftId, @AppUserId, @TerminalLocationId` → `Status, Message, NewId(NULL)`.
  - `EXEC Lots.DieCastLot_Void @LotId, @AppUserId, @TerminalLocationId` → `Status, Message, NewId(NULL)`.

- [ ] **Step 1: Write the failing tests**

```sql
-- 040_Release_and_queue.sql
SET NOCOUNT ON; SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0045_DieCast_Lifecycle/040_Release_and_queue.sql';
GO
-- Arrange: open a basket, contribute pieces, then release. (Resolve tool/cavity/cell/item/shift as in 020/030.)
-- ... (open @Lot via DieCastLot_Open with LotName '404040401'; contribute 50 via DieCastShiftOutput_Record) ...
-- Test: release moves Open->Good at storage; empty release rejects; missing-warehouse rejects.
DECLARE @Rel TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO @Rel EXEC Lots.DieCastLot_Release @LotId=@Lot, @StorageLocationId=NULL, @ShiftId=@Shift, @AppUserId=1, @TerminalLocationId=NULL;
DECLARE @rs NVARCHAR(10) = (SELECT CAST(Status AS NVARCHAR(10)) FROM @Rel);
EXEC test.Assert_IsEqual @TestName=N'[Release] Status 1', @Expected=N'1', @Actual=@rs;
DECLARE @afterState NVARCHAR(20) = (SELECT sc.Code FROM Lots.Lot l INNER JOIN Lots.LotStatusCode sc ON sc.Id=l.LotStatusId WHERE l.Id=@Lot);
EXEC test.Assert_IsEqual @TestName=N'[Release] Open->Good', @Expected=N'Good', @Actual=@afterState;
DECLARE @atWhse NVARCHAR(10) = (SELECT CASE WHEN CurrentLocationId = (SELECT Id FROM Location.Location WHERE Code=N'WHSE') THEN N'1' ELSE N'0' END FROM Lots.Lot WHERE Id=@Lot);
EXEC test.Assert_IsEqual @TestName=N'[Release] moved to WHSE', @Expected=N'1', @Actual=@atWhse;
-- released lot now appears in the Trim IN queue at storage
DECLARE @Q TABLE (Position INT, LotId BIGINT, LotName NVARCHAR(50), ItemPartNumber NVARCHAR(50), PieceCount INT, ArrivedAt DATETIME2(3));
INSERT INTO @Q EXEC Lots.Lot_GetWipQueueByLocation @LocationId=(SELECT Id FROM Location.Location WHERE Code=N'WHSE'), @OperationTypeCode=N'TrimIn', @IncludeDescendants=1;
DECLARE @inQ NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM @Q WHERE LotId=@Lot);
EXEC test.Assert_IsEqual @TestName=N'[Release] released lot visible in Trim IN queue', @Expected=N'1', @Actual=@inQ;
GO
EXEC test.EndTestFile;
GO
```

```sql
-- 050_Void.sql
SET NOCOUNT ON; SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0045_DieCast_Lifecycle/050_Void.sql';
GO
-- Arrange: open an EMPTY basket (LotName '505050501'), do not contribute.
-- Test 1: void empty succeeds Open->Scrap.
DECLARE @V TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO @V EXEC Lots.DieCastLot_Void @LotId=@Lot, @AppUserId=1, @TerminalLocationId=NULL;
DECLARE @vs NVARCHAR(10) = (SELECT CAST(Status AS NVARCHAR(10)) FROM @V);
EXEC test.Assert_IsEqual @TestName=N'[Void] empty basket voided Status 1', @Expected=N'1', @Actual=@vs;
DECLARE @vstate NVARCHAR(20) = (SELECT sc.Code FROM Lots.Lot l INNER JOIN Lots.LotStatusCode sc ON sc.Id=l.LotStatusId WHERE l.Id=@Lot);
EXEC test.Assert_IsEqual @TestName=N'[Void] Open->Scrap', @Expected=N'Scrap', @Actual=@vstate;
-- Test 2: void a NON-empty basket rejects (must release instead).
-- ... open '505050502', contribute 10, then: ...
DECLARE @V2 TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO @V2 EXEC Lots.DieCastLot_Void @LotId=@Lot2, @AppUserId=1, @TerminalLocationId=NULL;
DECLARE @v2 BIT = (SELECT Status FROM @V2); DECLARE @v2c BIT = CASE WHEN @v2=0 THEN 1 ELSE 0 END;
EXEC test.Assert_IsTrue @TestName=N'[Void] non-empty basket cannot be voided', @Condition=@v2c;
GO
EXEC test.EndTestFile;
GO
```

- [ ] **Step 2: Run to verify they fail**

Run: `.\sql\tests\Run-Tests.ps1 -Filter "0045"`
Expected: FAIL (procs missing).

- [ ] **Step 3: Write `DieCastLot_Release`**

Validations pre-txn: LOT is `Open`; resolve `@StorageLocationId` (well-known `WHSE` when NULL) — **hard reject if unresolved**; apply optional `@FinalPieceDelta` + `@ScrapLinesJson` (inline, mirroring Task 4's contribution + additive-reject blocks); after applying, `PieceCount > 0` (else reject — empty is Void). Mutation: `LotStatusHistory` Open→Good; `UPDATE Lot SET LotStatusId=Good, CurrentLocationId=@StorageLocationId`; `LotMovement` (cell→storage); audit `DieCastLotReleased`. Structure the error/CATCH/`Fail:` scaffold exactly like Task 2. Resolve `@GoodStatusId = (SELECT Id FROM Lots.LotStatusCode WHERE Code=N'Good')`.

- [ ] **Step 4: Write `DieCastLot_Void`**

Validations pre-txn: LOT is `Open` **and** `PieceCount = 0` (else reject: "Basket is not empty; release it instead."). Mutation: `LotStatusHistory` Open→Scrap; `UPDATE Lot SET LotStatusId=(Scrap Id)`; audit `DieCastLotVoided`. Same scaffold as Task 2.

- [ ] **Step 5: Run to verify they pass**

Run: `.\sql\tests\Run-Tests.ps1 -Filter "0045"`
Expected: 040 + 050 assertions PASS.

- [ ] **Step 6: Commit**

```bash
git add sql/migrations/repeatable/R__Lots_DieCastLot_Release.sql sql/migrations/repeatable/R__Lots_DieCastLot_Void.sql sql/tests/0045_DieCast_Lifecycle/040_Release_and_queue.sql sql/tests/0045_DieCast_Lifecycle/050_Void.sql
git commit -m "feat(diecast): DieCastLot_Release (Open->Good to storage) + DieCastLot_Void (empty->Scrap)"
```

---

## Phase 4 — Tally rework, history stream, open-by-tool read

### Task 7: `Lot_GetShiftCavityTally` rework + `Lot_GetOpenByTool` + history Stream 10

**Files:**
- Modify: `sql/migrations/repeatable/R__Lots_Lot_GetShiftCavityTally.sql`, `sql/migrations/repeatable/R__Lots_Lot_GetAttributeHistory.sql`
- Create: `sql/migrations/repeatable/R__Lots_Lot_GetOpenByTool.sql`
- Test: `sql/tests/0045_DieCast_Lifecycle/060_Tally_history_openbytool.sql`

**Interfaces:**
- Produces: `EXEC Lots.Lot_GetOpenByTool @ToolId` → `ToolCavityId, CavityNumber, LotId, LotName, PieceCount, OpenedAt (ET), ContributorCount`. `Lot_GetAttributeHistory` gains a `Contribution` `EventKind`.

- [ ] **Step 1: Write the failing test**

```sql
-- 060_Tally_history_openbytool.sql
SET NOCOUNT ON; SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0045_DieCast_Lifecycle/060_Tally_history_openbytool.sql';
GO
-- Arrange: open a basket ('606060601'), contribute 40 good + 5 additive scrap in the open shift.
-- Test 1: Lot_GetOpenByTool returns the open basket with PieceCount 40 + ContributorCount 1.
DECLARE @OB TABLE (ToolCavityId BIGINT, CavityNumber NVARCHAR(50), LotId BIGINT, LotName NVARCHAR(50), PieceCount INT, OpenedAt DATETIME2(3), ContributorCount INT);
INSERT INTO @OB EXEC Lots.Lot_GetOpenByTool @ToolId=@Tool;
DECLARE @obpc NVARCHAR(10) = (SELECT CAST(PieceCount AS NVARCHAR(10)) FROM @OB WHERE LotId=@Lot);
EXEC test.Assert_IsEqual @TestName=N'[OpenByTool] running PieceCount 40', @Expected=N'40', @Actual=@obpc;
-- Test 2: tally counts good WITHOUT double-counting the additive scrap.
DECLARE @T TABLE (ToolCavityId BIGINT, CavityNumber NVARCHAR(50), CavityLabel NVARCHAR(100), PieceSum INT, RejectSum INT, ShiftShots INT, ShiftGoodTotal INT, ShiftScrapTotal INT);
INSERT INTO @T EXEC Lots.Lot_GetShiftCavityTally @ToolId=@Tool;
DECLARE @good NVARCHAR(10) = (SELECT CAST(PieceSum AS NVARCHAR(10)) FROM @T WHERE ToolCavityId=@Cavity);
EXEC test.Assert_IsEqual @TestName=N'[Tally] good = 40 (additive scrap NOT double-counted)', @Expected=N'40', @Actual=@good;
DECLARE @scr NVARCHAR(10) = (SELECT CAST(RejectSum AS NVARCHAR(10)) FROM @T WHERE ToolCavityId=@Cavity);
EXEC test.Assert_IsEqual @TestName=N'[Tally] scrap tallied separately = 5', @Expected=N'5', @Actual=@scr;
-- Test 3: history shows a Contribution row.
DECLARE @H TABLE (EventAt DATETIME2(3), EventKind NVARCHAR(20), Detail NVARCHAR(500), ByUserId BIGINT, ByUserName NVARCHAR(200));
INSERT INTO @H EXEC Lots.Lot_GetAttributeHistory @LotId=@Lot;
DECLARE @hc NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM @H WHERE EventKind=N'Contribution');
EXEC test.Assert_IsEqual @TestName=N'[History] Contribution stream present', @Expected=N'1', @Actual=@hc;
GO
EXEC test.EndTestFile;
GO
```

- [ ] **Step 2: Run to verify it fails**

Run: `.\sql\tests\Run-Tests.ps1 -Filter "060_Tally"`
Expected: FAIL (`Lot_GetOpenByTool` missing; tally double-counts; no Contribution stream).

- [ ] **Step 3: Write `Lot_GetOpenByTool`**

```sql
-- sql/migrations/repeatable/R__Lots_Lot_GetOpenByTool.sql
CREATE OR ALTER PROCEDURE Lots.Lot_GetOpenByTool @ToolId BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    SELECT tc.Id AS ToolCavityId, tc.CavityNumber, l.Id AS LotId, l.LotName, l.PieceCount,
           CAST(l.CreatedAt AT TIME ZONE 'UTC' AT TIME ZONE 'Eastern Standard Time' AS DATETIME2(3)) AS OpenedAt,
           (SELECT COUNT(DISTINCT c.AppUserId) FROM Workorder.DieCastContribution c WHERE c.LotId = l.Id) AS ContributorCount
    FROM Lots.Lot l
    INNER JOIN Lots.LotStatusCode sc ON sc.Id = l.LotStatusId AND sc.Code = N'Open'
    INNER JOIN Tools.ToolCavity tc ON tc.Id = l.ToolCavityId
    WHERE l.ToolId = @ToolId
    ORDER BY tc.CavityNumber;
END;
GO
```

- [ ] **Step 4: Rework `Lot_GetShiftCavityTally`**

Replace the scrap-inclusive `PieceSum = SUM(PieceCount + RejectedQty)` with the additive-correct model: `PieceSum = SUM(l.PieceCount)` (good, which for die-cast is already net of scrap since scrap is additive and never decremented) and keep `RejectSum = SUM(RejectEvent.Quantity)` as the separate scrap metric. Include LOTs of any non-terminal status for the cavity in the shift window (Open + released this shift) via the existing `@ShiftStart` resolution. Update the header note (remove the "PieceCount + rejected quantity" as-cast rationale — that was the subtractive-era assumption).

- [ ] **Step 5: Add history Stream 10**

In `R__Lots_Lot_GetAttributeHistory.sql`, add a `UNION ALL` branch before the closing `) u`:

```sql
        UNION ALL
        -- ---- Stream 10: die-cast contributions ----
        SELECT
            c.EventAt                             AS EventAt,
            CAST(10 AS INT)                       AS SortRank,
            CAST(N'Contribution' AS NVARCHAR(20)) AS EventKind,
            CAST(N'Added ' + CAST(c.PieceDelta AS NVARCHAR(20)) + N' pc'
                 + ISNULL(N' (' + ss.Name + N')', N'') AS NVARCHAR(500)) AS Detail,
            CAST(c.AppUserId AS BIGINT)           AS ByUserId,
            CAST(au.DisplayName AS NVARCHAR(200))  AS ByUserName
        FROM Workorder.DieCastContribution c
        INNER JOIN Location.AppUser au ON au.Id = c.AppUserId
        LEFT  JOIN Oee.Shift s          ON s.Id = c.ShiftId
        LEFT  JOIN Oee.ShiftSchedule ss ON ss.Id = s.ShiftScheduleId
        WHERE c.LotId = @LotId
```

- [ ] **Step 6: Run to verify it passes**

Run: `.\sql\tests\Run-Tests.ps1 -Filter "0045"`
Expected: 060 assertions PASS. Also run `.\sql\tests\Run-Tests.ps1 -Filter "0022"` (existing die-cast tally tests) — update any that assumed the old `PieceCount + rejected` sum.

- [ ] **Step 7: Run the FULL suite (no regressions)**

Run: `.\sql\tests\Run-Tests.ps1` then query `test.TestResults` for `Failed = 0`.
Expected: 0 failed.

- [ ] **Step 8: Commit**

```bash
git add sql/migrations/repeatable/R__Lots_Lot_GetShiftCavityTally.sql sql/migrations/repeatable/R__Lots_Lot_GetAttributeHistory.sql sql/migrations/repeatable/R__Lots_Lot_GetOpenByTool.sql sql/tests/0045_DieCast_Lifecycle/060_Tally_history_openbytool.sql
git commit -m "feat(diecast): tally rework (additive-correct) + open-by-tool read + history Contribution stream"
```

### Task 8: Deploy the SQL to `MPP_MES_Dev`

- [ ] **Step 1:** Apply the migration + all new/changed repeatables to Dev (data-safe; migration is idempotent, procs are CREATE OR ALTER):

```bash
sqlcmd -S localhost -d MPP_MES_Dev -b -I -C -i sql/migrations/versioned/0045_diecast_per_cavity_lifecycle.sql
for f in R__Lots_DieCastLot_Open R__Workorder_DieCast_GetShiftOutputBreakdown R__Workorder_DieCastShiftOutput_Record R__Lots_DieCastLot_Release R__Lots_DieCastLot_Void R__Lots_Lot_GetOpenByTool R__Lots_Lot_GetWipQueueByLocation R__Lots_Lot_GetShiftCavityTally R__Lots_Lot_GetAttributeHistory; do sqlcmd -S localhost -d MPP_MES_Dev -b -I -C -i "sql/migrations/repeatable/$f.sql"; done
```

Expected: each exits 0.
- [ ] **Step 2: Commit** — nothing to commit (deploy only); note it in the session log.

---

## Phase 5 — Ignition backend (Core NQs + inert entity glue)

### Task 9: Core Named Queries for the six procs

**Files:**
- Create six NQ folders under `ignition/projects/Core/ignition/named-query/` each with `query.sql` + `resource.json` (`type: "Query"`).

**Interfaces:**
- Produces NQ paths: `lots/DieCastLot_Open`, `workorder/DieCast_GetShiftOutputBreakdown`, `workorder/DieCastShiftOutput_Record`, `lots/DieCastLot_Release`, `lots/DieCastLot_Void`, `lots/Lot_GetOpenByTool`.

- [ ] **Step 1:** For each proc, create `query.sql` calling it with `:param` bindings (mirror an existing status-row NQ like `quality/QualitySample_Record/query.sql` for shape). Example `lots/DieCastLot_Open/query.sql`:

```sql
EXEC Lots.DieCastLot_Open
    @ItemId=:itemId, @CurrentLocationId=:currentLocationId, @ToolId=:toolId,
    @ToolCavityId=:toolCavityId, @LotName=:lotName, @AppUserId=:appUserId, @TerminalLocationId=:terminalLocationId
```

And `resource.json` copied from an existing NQ folder, adjusting `type` to `Query` and declaring the parameters.

- [ ] **Step 2:** Run `.\scan.ps1`. Expected: clean scan, no NQ errors.
- [ ] **Step 3: Commit**

```bash
git add ignition/projects/Core/ignition/named-query/lots/DieCastLot_Open ignition/projects/Core/ignition/named-query/lots/DieCastLot_Release ignition/projects/Core/ignition/named-query/lots/DieCastLot_Void ignition/projects/Core/ignition/named-query/lots/Lot_GetOpenByTool ignition/projects/Core/ignition/named-query/workorder/DieCast_GetShiftOutputBreakdown ignition/projects/Core/ignition/named-query/workorder/DieCastShiftOutput_Record
git commit -m "feat(diecast): Core NQs for the lifecycle procs"
```

### Task 10: Entity glue — `BlueRidge.Lots.Lot` additions + new `BlueRidge.Workorder.DieCast`

**Files:**
- Modify: `ignition/projects/Core/ignition/script-python/BlueRidge/Lots/Lot/code.py`
- Create: `ignition/projects/Core/ignition/script-python/BlueRidge/Workorder/DieCast/code.py`

**Interfaces:**
- Produces: `BlueRidge.Lots.Lot.openDieCast(data)`, `.releaseDieCast(data)`, `.voidDieCast(lotId)`, `.getOpenByTool(toolId, _refreshToken=None)`; `BlueRidge.Workorder.DieCast.getShiftOutputBreakdown(toolId, shiftId, grossShots)`, `.recordShiftOutput(data)`, `.registerShotLoss(toolId, shiftId, defectCodeId, quantity)`.

- [ ] **Step 1:** Add to `Lots/Lot/code.py` thin wrappers (mirror the existing `create`/`moveToValidated` style — `execMutation`/`execList` through `BlueRidge.Common.Db`, `_currentAppUserId()` default). No business logic. Example:

```python
def openDieCast(data):
    d = BlueRidge.Common.Util.extractQualifiedValues(data) or {}
    params = {"itemId": d.get("itemId"), "currentLocationId": d.get("currentLocationId"),
              "toolId": d.get("toolId"), "toolCavityId": d.get("toolCavityId"),
              "lotName": d.get("lotName"), "appUserId": d.get("appUserId") or BlueRidge.Common.Util._currentAppUserId(),
              "terminalLocationId": d.get("terminalLocationId")}
    return BlueRidge.Common.Db.execMutation("lots/DieCastLot_Open", params)

def getOpenByTool(toolId, _refreshToken=None):
    toolId = BlueRidge.Common.Util.extractQualifiedValues(toolId)
    if not toolId: return []
    return BlueRidge.Common.Db.execList("lots/Lot_GetOpenByTool", {"toolId": toolId})
```

(Add `releaseDieCast`, `voidDieCast` following the same pattern against their NQs.)

- [ ] **Step 2:** Create `Workorder/DieCast/code.py` with `getShiftOutputBreakdown` (execList), `recordShiftOutput` (execMutation, passing `linesJson`/`shotLossJson` via `convertWrapperObjectToJson`), `registerShotLoss` (builds a one-line `shotLossJson` and calls `recordShiftOutput` with empty lines). Resolve the `DieCast` template by role only if a proc needs it (these don't — the procs resolve internally).
- [ ] **Step 3:** Run `.\scan.ps1`. Expected: clean.
- [ ] **Step 4: Commit**

```bash
git add ignition/projects/Core/ignition/script-python/BlueRidge/Lots/Lot/code.py ignition/projects/Core/ignition/script-python/BlueRidge/Workorder/DieCast/code.py
git commit -m "feat(diecast): inert entity glue for the lifecycle procs"
```

---

## Phase 6 — `DieCastBody` view rework (Designer)

> **Designer, not file edits** (`feedback_ignition_view_edit_boundary`): `DieCastBody` + the `DieCastEntry` components are existing views. Keep Designer closed on them until each change is saved there; run `.\scan.ps1` after. Smoke on a demo-seeded gateway.

### Task 11: Open surface

- [ ] **Step 1:** In `DieCastBody`, replace the "New LOT" create form with an **Open** panel: scan LTT field + Item dropdown (`Item_ListEligibleForLocationByRole` with `DieCast`) + auto Tool (from the cell's active `ToolAssignment`) + Cavity dropdown (active cavities of the tool) → **Open** button → `BlueRidge.Lots.Lot.openDieCast(...)` → `notifyResult`. Carry over the no-die-cast-template warning + InitialsEntry operator gate.
- [ ] **Step 2:** Save in Designer; `.\scan.ps1`.
- [ ] **Step 3: Smoke:** open a basket on a cavity → toast success; the basket appears in the Currently-Open list (Task 13). Confirm one-open-per-cavity: a second open on the same cavity is rejected with the guard toast.
- [ ] **Step 4: Commit** the `DieCastBody/view.json` (+ any component) after scan.

### Task 12: Shift-output entry (Shape 1) + scrap + shot-loss

- [ ] **Step 1:** Add the **Record shift output** panel: a die-wide **gross shots** field + **shift picker** defaulted per the spec §3.3 rule (first-hour → previous shift, else current; overridable), and a repeater over the open cavity-lots (from `getOpenByTool`) where each row shows the cavity, computed **good** (live: gross − row scrap − shot losses), and a **scrap flex repeater** (reason `DefectCode` + qty). On "Compute/Preview," call `BlueRidge.Workorder.DieCast.getShiftOutputBreakdown(toolId, shiftId, grossShots)` to pre-fill/override per-lot good (handles the multi-lot split). A **Register shot loss** button adds a die-wide loss (reason + qty). **Submit** → `recordShiftOutput({shiftId, toolId, lines:[...], shotLoss:[...]})` → `notifyResult` → refresh.
- [ ] **Step 2:** Soft-ceiling UX: when a row's good would exceed `MaxHeadroom`, show an inline warning with **auto-fill** / **close-and-open-next** (release → prompt scan next LTT → open) / **continue**. No hard block.
- [ ] **Step 3:** Save; `.\scan.ps1`.
- [ ] **Step 4: Smoke:** enter gross shots + per-cavity scrap + a shot loss → each basket's good = gross − its scrap − losses; baskets increment; scrap shows in each LOT's history as additive; nothing decrements the good.
- [ ] **Step 5: Commit.**

### Task 13: Release / Void / Currently-Open list; retire CheckpointPanel

- [ ] **Step 1:** Add the **Currently Open** list bound to `getOpenByTool` (LotName, cavity, running PieceCount, contributor count, OpenedAt ET). Add a **Release** button per open basket (final good+scrap entry + `ConfirmCreateLot`-style confirm → `releaseDieCast`) and a **Void** button (empty basket only → warn Continue/Cancel → `voidDieCast`). Wire **close-and-open-next** to chain release → scan-next-LTT → open.
- [ ] **Step 2:** Repoint the right-rail tally to the reworked `Lot_GetShiftCavityTally` (good + scrap, no double-count). Fold `RejectPanel` into the per-cavity scrap repeater; **retire `CheckpointPanel`** from this flow (remove its embed).
- [ ] **Step 3:** Save; `.\scan.ps1`.
- [ ] **Step 4: Smoke (end-to-end):** open baskets on ≥2 cavities; record a die-wide shift with per-cavity scrap + a shot loss; close one basket mid-shift (release with its totals); start a new shift entry → the mid-shift-closed lot is pre-populated and the open lot gets the remainder (auto-breakdown); release the rest; confirm each released basket appears in the Trim IN queue; void an empty basket; verify the tally + each LOT's history (Open → Contribution(s) → Released) and that scrap is never double-counted.
- [ ] **Step 5: Commit.**

### Task 14: Docs

- [ ] **Step 1:** Update `PROJECT_STATUS.md` (append-only session entry), `MPP_MES_DATA_MODEL.md` (`Open` status, `Workorder.DieCastContribution`, lifecycle prose + changelog row), and FDS-05 die-cast prose. Regenerate the `.docx` for any changed markdown doc (`pandoc … && node style_docx_tables.js …`).
- [ ] **Step 2: Commit.**

---

## Self-Review

**Spec coverage:** §2.1 lifecycle → Tasks 2/4/6; §2.2 `Open` status → Task 1; §3 Shape-1 entry + arithmetic + shift default + auto-breakdown → Tasks 3/4/12; §4.1 Open → Task 2; §4.2 breakdown+record → Tasks 3/4; §4.3 Release → Task 6; §4.4 Void → Task 6; §4.5 queue/tally/open-by-tool/history → Tasks 5/7; §4.6 migration → Task 1; §5.1 NQs → Task 9; §5.2 entity glue → Task 10; §5.3 view rework → Tasks 11–13; §5.4 Production Dashboard → **out of scope** (separate deliverable per spec, noted); §6 edge cases → covered across Open guard (3), additive scrap (4), release/void (6), soft ceiling (12); §7 phases → Phases 0–6. No uncovered in-scope requirement.

**Placeholder scan:** SQL proc bodies for Release/Void (Task 6 Steps 3–4) are described rather than fully reproduced — they are close mirrors of Task 2's fully-shown scaffold with the stated validation/mutation swaps; the tests fully pin their contracts. All other code steps show complete code.

**Type consistency:** proc names, params, and result columns match between the migration/procs (Tasks 1–7), the NQ bindings (Task 9), and the entity glue (Task 10): `DieCastLot_Open`/`DieCastShiftOutput_Record`/`DieCast_GetShiftOutputBreakdown`/`DieCastLot_Release`/`DieCastLot_Void`/`Lot_GetOpenByTool`. `@LinesJson` shape (`lotId`/`pieceDelta`/`scrapLines[defectCodeId,quantity]`) is identical in Task 4's proc, test, and Task 10's glue.
