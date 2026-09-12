# Inventory Cutover Scan Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Status (2026-09-12):** Tasks 1-8 complete and committed on `jacques/working`; suite green at 3487 assertions. Tasks 9-12 remain.

**Goal:** Build a mobile scan surface that counts existing plant inventory into the new MES line-by-line, backed by a LOT-level route entry point so migrated stock lands at the terminal where it physically sits.

**Architecture:** Three phases. **Phase A** extracts the pending-route-step predicate — currently copy-pasted seven times across five procs — into one inline table-valued function, with zero behaviour change, proven by the existing test suite passing unmodified. **Phase B** adds `Lots.Lot.EntryRouteSequence` (where a migrated LOT joined its route), `Lots.Lot.CastDate` (real FIFO), and `Location.DefaultStockLocationId` (where a line's scanned stock lands) — each nullable, so every existing row keeps today's behaviour. **Phase C** builds the Perspective view.

**Tech Stack:** SQL Server 2022, T-SQL stored procedures + inline TVF, `sqlcmd`-driven test suite, Ignition 8.3 Perspective (file-authored views), Jython script modules, named queries.

**Spec:** `docs/superpowers/specs/2026-09-12-inventory-cutover-scan-design.md`
**Blast radius:** `notes/2026-09-12_entry-route-sequence-blast-radius.md`
**Mockups:** https://claude.ai/code/artifact/b198811e-e705-4754-98b7-fec93aeddafb

---

## Global Constraints

Every task's requirements implicitly include this section.

**Git**
- Work on branch `jacques/working`. Never commit to `main`.
- **Stage explicit paths only.** Never `git add -u` or `git add -A` — a concurrent user may have unrelated files in the working tree.
- **Omit the `Co-Authored-By: Claude` trailer** from commit messages.

**SQL**
- `UpperCamelCase` tables and columns. `BIGINT` FKs. `NVARCHAR`, never `VARCHAR`. `DATETIME2(3)`, never `FLOAT` for decimals.
- **No `OUTPUT` parameters** (FDS-11-011). Mutation procs use local `@Status`, `@Message`, `@NewId` and end every exit path with `SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;`. Read procs return an empty result set for "not found".
- **One result set per proc.**
- **All rejecting validations run BEFORE `BEGIN TRANSACTION`** — each selects the status row and `RETURN`s with no open transaction. A `ROLLBACK` inside a proc invoked via `INSERT-EXEC` throws Msg 3915. `CATCH` is the only legal `ROLLBACK` site.
- `RAISERROR` (not `THROW`) in `CATCH` blocks.
- Schema-qualify every database reference. `EXEC` parameters must be literals or `@variables` — never inline `CAST` / arithmetic / `CASE`.
- **ASCII-only** in all string literals, seed values and descriptions. `sqlcmd` reads `.sql` in the Windows codepage; an em-dash becomes mojibake. Use `--` and `->`.
- Timestamps stored UTC (`SYSUTCDATETIME()`), displayed Eastern via `CAST(<col> AT TIME ZONE 'UTC' AT TIME ZONE 'Eastern Standard Time' AS DATETIME2(3))`.
- Repeatable migrations (`R__*.sql`) use `CREATE OR ALTER`. Versioned migrations are idempotent-guarded against `dbo.SchemaVersion` and end by inserting their own row.

**Tests**
- Run with `.\Run-Tests.ps1` from `sql/tests/`. It **resets (DROPs)** its target, which defaults to `MPP_MES_Test`. **Never point it at `MPP_MES_Dev`** — that is Jacques's hand-built working data with no backups.
- Capture a status-row proc via `INSERT ... EXEC` into a temp table matching the `SELECT` shape.
- Teardown order: `LotEventLog` -> `LotMovement` -> `LotStatusHistory` -> `LotGenealogyClosure` -> `Lot`. Deleting a LOT before its closure rows raises Msg 547.
- Every test file opens with `EXEC test.BeginTestFile @FileName = N'<relative path>';` and asserts through `test.Assert_IsEqual` / `Assert_IsTrue` / `Assert_IsNull` / `Assert_IsNotNull` / `Assert_RowCount` / `Assert_Contains` (takes `@HaystackStr` + `@NeedleStr`).
- An exit code of 1 with zero reported failures means a test's `sqlcmd` errored outright — usually a teardown FK ordering mistake.

**Ignition**
- **All named queries live in the `Core` project.** `MPP` and `MPP_Config` have none of their own; sibling projects cannot see each other's.
- NQ `sqlType` is **Designer's own enum, NOT `java.sql.Types`**: `0` TINYINT, `1` SMALLINT, `2` INTEGER, `3` BIGINT, `4` REAL, `5` FLOAT/DOUBLE, `6` BIT, `7` NVARCHAR/String, `8` DateTime, `20` ByteArray. There is **no DATE code** -- a `DATE` proc parameter is carried as `8` (DateTime). Never hand-author a JDBC code such as `-5` or `91`; Designer rewrites it on its next save.
- A proc returning a status row needs NQ `"type": "Query"` and `execMutation`. A silent proc needs `"type": "UpdateQuery"` and `execNonQuery`.
- **All Ignition work in this plan is file-authored — new views and existing ones alike.** Jacques is keeping Designer closed for the duration, so the usual filesystem-vs-Designer reconciliation race does not apply and there is no Designer cache to fight. Edit `view.json` directly and run `.\scan.ps1`. (The standing repo rule — edit existing views in Designer — remains correct outside this plan.)
- When a file edit reports "String not found" on text that visibly matches, the file has mixed line endings or Designer-era 6-char unicode escapes -- a literal backslash-u-0-0-3-d in place of `=`, and the equivalents for `'`, `<` and `>`. Anchor edits on escape-free text, or do a byte-level replace in Python.
- A view folder needs both `view.json` and `resource.json` (`"scope": "G"`) or the page reports "View Not Found".
- After adding any new resource, run `.\scan.ps1` from the repo root. Never `pull.ps1` (it overwrites local work from the gateway).
- Event-script bodies in `view.json` start with a tab — Designer wraps them in `def runAction(self, event):`. Column-0 content is an `IndentationError`.
- `system.perspective.*` called from a dom event needs `scope: "G"`; at `"C"` it silently no-ops.
- Every `view.custom.*` property a binding reads must be declared in the `custom` block with a fully-shaped default, and the binding source must itself always return that full shape — including on the empty path.
- Use `mpp/<icon>` icons only after verifying the name exists in `ignition/icons/mpp/mpp.svg`.
- Colors come from the `--mpp-*` tokens in the Core stylesheet. Never add an MPP-local override.

**Domain**
- **No business logic in Python.** Domain rules (matrices, thresholds, transitions, eligibility) live in SQL. Perspective and Jython are thin glue.
- No drag-and-drop anywhere. Up/down arrow buttons for sortable lists.
- Audit `Description` shape: `<SUBJECT> · <CATEGORY?> · <ACTION>` via `Audit.ufn_MidDot()`, with resolved-name FK sub-objects in `OldValue`/`NewValue` JSON, capped by `Audit.ufn_TruncateActivity()`.

---

# PHASE A — Extract the pending-step predicate (behaviour-neutral)

Phase A changes no behaviour. Its proof is the existing suite passing **unmodified**.

---

### Task 1: Create `Lots.ufn_NextPendingRouteStep`

**Files:**
- Create: `sql/migrations/repeatable/R__Lots_ufn_NextPendingRouteStep.sql`
- Test: `sql/tests/0070_Cutover_EntryRoute/010_ufn_NextPendingRouteStep.sql`

**Interfaces:**
- Consumes: nothing.
- Produces: `Lots.ufn_NextPendingRouteStep(@LotId BIGINT)` — an **inline** TVF returning at most one row with columns `SequenceNumber INT`, `OperationTemplateId BIGINT`, `OperationTypeCode NVARCHAR(30)`. Returns **zero rows** when the LOT has no active published route, or when no step is pending.

> **Critical scoping note.** The function answers *only* "what is this LOT's next pending route step". It does **not** filter by LOT status or location — those predicates differ per caller (`Lot_GetWipQueueByLocation` excludes `Closed` **and** `Open`; the others exclude only `Closed`) and must stay in the calling query. Moving them into the function would change behaviour.

- [ ] **Step 1: Write the failing test**

Create `sql/tests/0070_Cutover_EntryRoute/010_ufn_NextPendingRouteStep.sql`:

```sql
-- =============================================
-- File:         0070_Cutover_EntryRoute/010_ufn_NextPendingRouteStep.sql
-- Description:  Tests for Lots.ufn_NextPendingRouteStep -- the extracted
--               next-pending-route-step predicate (Phase A, behaviour-neutral).
--               Fixture: casting 5G0-c, route DieCast(OriginMint) -> TrimIn ->
--               TrimOut -> MachiningIn (all Advance) -> MachiningOut (ConsumeMint),
--               line-resident at MA1-5GOF.
-- =============================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0070_Cutover_EntryRoute/010_ufn_NextPendingRouteStep.sql';
GO

DECLARE @U BIGINT = (SELECT Id FROM Location.AppUser WHERE Initials = N'DEV');
DECLARE @Item BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'5G0-c');
DECLARE @Line BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MA1-5GOF');
DECLARE @Origin BIGINT = (SELECT Id FROM Lots.LotOriginType WHERE Code = N'Manufactured');

DECLARE @Lot BIGINT;
CREATE TABLE #C (Status BIT, Message NVARCHAR(500), NewId BIGINT, MintedLotName NVARCHAR(50));
INSERT INTO #C EXEC Lots.Lot_Create @ItemId = @Item, @LotOriginTypeId = @Origin,
    @CurrentLocationId = @Line, @PieceCount = 10, @AppUserId = @U;
SELECT @Lot = NewId FROM #C; DROP TABLE #C;

-- (1) A fresh LOT: DieCast is OriginMint (never pending), so the next pending
--     step is TrimIn.
DECLARE @a1 NVARCHAR(30) = (SELECT OperationTypeCode FROM Lots.ufn_NextPendingRouteStep(@Lot));
EXEC test.Assert_IsEqual @TestName = N'[ufn] fresh LOT next pending = TrimIn',
    @Expected = N'TrimIn', @Actual = @a1;

-- (2) Exactly one row is ever returned.
DECLARE @a2 NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM Lots.ufn_NextPendingRouteStep(@Lot));
EXEC test.Assert_IsEqual @TestName = N'[ufn] returns exactly one row',
    @Expected = N'1', @Actual = @a2;

-- (3) Stamp TrimIn + TrimOut -> advances to MachiningIn.
INSERT INTO Workorder.ProductionEvent (LotId, OperationTemplateId, EventAt, ShotCount, AppUserId)
SELECT @Lot, rs.OperationTemplateId, SYSUTCDATETIME(), 10, @U
FROM Parts.RouteTemplate rt
JOIN Parts.RouteStep rs ON rs.RouteTemplateId = rt.Id
JOIN Parts.OperationTemplate ot ON ot.Id = rs.OperationTemplateId
JOIN Parts.OperationType oty ON oty.Id = ot.OperationTypeId
WHERE rt.ItemId = @Item AND rt.PublishedAt IS NOT NULL AND rt.DeprecatedAt IS NULL
  AND oty.Code IN (N'TrimIn', N'TrimOut');

DECLARE @a3 NVARCHAR(30) = (SELECT OperationTypeCode FROM Lots.ufn_NextPendingRouteStep(@Lot));
EXEC test.Assert_IsEqual @TestName = N'[ufn] after Trim events next pending = MachiningIn',
    @Expected = N'MachiningIn', @Actual = @a3;

-- (4) Stamp MachiningIn -> the ConsumeMint MachiningOut step, which is
--     unconditionally pending while the LOT is open.
INSERT INTO Workorder.ProductionEvent (LotId, OperationTemplateId, EventAt, ShotCount, AppUserId)
SELECT @Lot, rs.OperationTemplateId, SYSUTCDATETIME(), 10, @U
FROM Parts.RouteTemplate rt
JOIN Parts.RouteStep rs ON rs.RouteTemplateId = rt.Id
JOIN Parts.OperationTemplate ot ON ot.Id = rs.OperationTemplateId
JOIN Parts.OperationType oty ON oty.Id = ot.OperationTypeId
WHERE rt.ItemId = @Item AND rt.PublishedAt IS NOT NULL AND rt.DeprecatedAt IS NULL
  AND oty.Code = N'MachiningIn';

DECLARE @a4 NVARCHAR(30) = (SELECT OperationTypeCode FROM Lots.ufn_NextPendingRouteStep(@Lot));
EXEC test.Assert_IsEqual @TestName = N'[ufn] ConsumeMint step stays pending while open',
    @Expected = N'MachiningOut', @Actual = @a4;

-- (5) The function does NOT filter by status: a Closed LOT still reports its
--     ConsumeMint step. Status filtering is the caller's job.
DECLARE @ClosedId BIGINT = (SELECT Id FROM Lots.LotStatusCode WHERE Code = N'Closed');
UPDATE Lots.Lot SET LotStatusId = @ClosedId WHERE Id = @Lot;
DECLARE @a5 NVARCHAR(30) = (SELECT OperationTypeCode FROM Lots.ufn_NextPendingRouteStep(@Lot));
EXEC test.Assert_IsEqual @TestName = N'[ufn] does not filter by LOT status',
    @Expected = N'MachiningOut', @Actual = @a5;

-- (6) A LOT id that does not exist returns zero rows.
DECLARE @a6 NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM Lots.ufn_NextPendingRouteStep(-1));
EXEC test.Assert_IsEqual @TestName = N'[ufn] unknown LotId returns no rows',
    @Expected = N'0', @Actual = @a6;

-- Teardown
DELETE FROM Workorder.ProductionEvent WHERE LotId = @Lot;
DELETE FROM Lots.LotEventLog WHERE LotId = @Lot;
DELETE FROM Lots.LotMovement WHERE LotId = @Lot;
DELETE FROM Lots.LotStatusHistory WHERE LotId = @Lot;
DELETE FROM Lots.LotGenealogyClosure WHERE AncestorLotId = @Lot OR DescendantLotId = @Lot;
DELETE FROM Lots.Lot WHERE Id = @Lot;
GO
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
cd sql/tests && ./Run-Tests.ps1 -Filter "ufn_NextPendingRouteStep"
```

Expected: FAIL — `Invalid object name 'Lots.ufn_NextPendingRouteStep'`.

- [ ] **Step 3: Write the function**

Create `sql/migrations/repeatable/R__Lots_ufn_NextPendingRouteStep.sql`:

```sql
-- ============================================================
-- Repeatable:  R__Lots_ufn_NextPendingRouteStep.sql
-- Author:      Blue Ridge Automation
-- Modified:    2026-09-12
-- Version:     1.0
-- Description: THE single definition of "what is this LOT's next pending route
--              step". Extracted from seven copy-pasted CTEs across five procs
--              (Lot_GetWipQueueByLocation, Lot_GetComponentsAtCell,
--              Lot_GetTrimStorageQueueForLine, Lot_MoveToValidated, and three
--              inside MachiningOut_Mint). Behaviour is byte-identical to those
--              copies -- this is a pure extraction.
--
--              Pending depends on the step's OperationRoleKind:
--                * Advance     -> pending until a matching Workorder.ProductionEvent
--                                 exists for the LOT on that step's OperationTemplateId.
--                * OriginMint  -> never pending (the LOT exists => it was minted there).
--                * ConsumeMint -> always pending while the LOT is open; it is the
--                                 terminal step and the LOT leaves only by closing.
--
--              SCOPE. This function answers ONLY the route question. It does NOT
--              filter by LOT status or location -- those differ per caller
--              (Lot_GetWipQueueByLocation excludes Closed AND Open; the others
--              exclude only Closed) and MUST stay in the calling query. Folding
--              them in here would change behaviour.
--
--              INLINE TVF on purpose (not scalar, not multi-statement) so the
--              optimiser folds it into the caller's plan. These procs run on every
--              terminal refresh; a multi-statement TVF would put a row-by-row
--              barrier in the hot path.
-- ============================================================
CREATE OR ALTER FUNCTION Lots.ufn_NextPendingRouteStep (@LotId BIGINT)
RETURNS TABLE
AS RETURN
    SELECT TOP (1)
           rs.SequenceNumber        AS SequenceNumber,
           rs.OperationTemplateId   AS OperationTemplateId,
           oty.Code                 AS OperationTypeCode
    FROM Lots.Lot l
    INNER JOIN Parts.RouteTemplate rt      ON rt.ItemId = l.ItemId
         AND rt.PublishedAt IS NOT NULL AND rt.DeprecatedAt IS NULL
    INNER JOIN Parts.RouteStep rs          ON rs.RouteTemplateId = rt.Id
    INNER JOIN Parts.OperationTemplate ot  ON ot.Id  = rs.OperationTemplateId
    INNER JOIN Parts.OperationType oty     ON oty.Id = ot.OperationTypeId
    INNER JOIN Parts.OperationRoleKind rk  ON rk.Id  = oty.OperationRoleKindId
    WHERE l.Id = @LotId
      AND (
              rk.Code = N'ConsumeMint'
           OR (rk.Code = N'Advance' AND NOT EXISTS (
                  SELECT 1 FROM Workorder.ProductionEvent pe
                  WHERE pe.LotId = l.Id AND pe.OperationTemplateId = rs.OperationTemplateId))
          )
    ORDER BY rs.SequenceNumber ASC;
GO
```

- [ ] **Step 4: Run the test to verify it passes**

```bash
cd sql/tests && ./Run-Tests.ps1 -Filter "ufn_NextPendingRouteStep"
```

Expected: PASS, 6 assertions, 0 failures, exit code 0.

- [ ] **Step 5: Commit**

```bash
git add sql/migrations/repeatable/R__Lots_ufn_NextPendingRouteStep.sql sql/tests/0070_Cutover_EntryRoute/010_ufn_NextPendingRouteStep.sql
git commit -m "feat(sql): Lots.ufn_NextPendingRouteStep -- one definition of the pending route step

Inline TVF extracted from seven copy-pasted CTEs. Status and location
filtering deliberately stay in the callers; they differ per caller."
```

---

### Task 2: Rewire the three read procs and `Lot_MoveToValidated`

**Files:**
- Modify: `sql/migrations/repeatable/R__Lots_Lot_GetWipQueueByLocation.sql`
- Modify: `sql/migrations/repeatable/R__Lots_Lot_GetComponentsAtCell.sql`
- Modify: `sql/migrations/repeatable/R__Lots_Lot_GetTrimStorageQueueForLine.sql`
- Modify: `sql/migrations/repeatable/R__Lots_Lot_MoveToValidated.sql`
- Test: the existing suite, unmodified

**Interfaces:**
- Consumes: `Lots.ufn_NextPendingRouteStep(@LotId)` from Task 1.
- Produces: no signature or result-shape change to any of the four procs.

- [ ] **Step 1: Capture the pre-change baseline**

```bash
cd sql/tests && ./Run-Tests.ps1 2>&1 | tee ../../notes/_phaseA_baseline.txt
tail -20 ../../notes/_phaseA_baseline.txt
```

Expected: the full suite passes. Record the total assertion count — the post-change run must match it exactly.

- [ ] **Step 2: Rewire `Lot_GetWipQueueByLocation`**

In `R__Lots_Lot_GetWipQueueByLocation.sql`, replace the entire `NextStep AS (...)` CTE and its downstream join.

Delete this CTE:

```sql
    NextStep AS (
        SELECT l.Id AS LotId, rs.SequenceNumber, rs.OperationTemplateId,
               ROW_NUMBER() OVER (PARTITION BY l.Id ORDER BY rs.SequenceNumber ASC) AS rn
        FROM Lots.Lot l
        INNER JOIN Lots.LotStatusCode sc ON sc.Id = l.LotStatusId AND sc.Code NOT IN (N'Closed', N'Open')
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
                  rk.Code = N'ConsumeMint'
               OR (rk.Code = N'Advance' AND NOT EXISTS (
                      SELECT 1 FROM Workorder.ProductionEvent pe
                      WHERE pe.LotId = l.Id AND pe.OperationTemplateId = rs.OperationTemplateId))
              )
    )
```

Replace it with a CTE that selects the LOTs (status + location filtering retained here, as required):

```sql
    Eligible AS (
        SELECT l.Id AS LotId
        FROM Lots.Lot l
        INNER JOIN Lots.LotStatusCode sc ON sc.Id = l.LotStatusId AND sc.Code NOT IN (N'Closed', N'Open')
        WHERE (
                  (@IncludeDescendants = 1 AND l.CurrentLocationId IN (SELECT Id FROM Descendants))
               OR (@IncludeDescendants = 0 AND l.CurrentLocationId = @LocationId)
              )
    )
```

Then change the final `SELECT`'s `FROM` clause from:

```sql
    FROM NextStep ns
    INNER JOIN Lots.Lot l               ON l.Id = ns.LotId AND ns.rn = 1
```

to:

```sql
    FROM Eligible e
    CROSS APPLY Lots.ufn_NextPendingRouteStep(e.LotId) ns
    INNER JOIN Lots.Lot l               ON l.Id = e.LotId
```

Bump the header to `Version: 3.2` and add this line to the description block:

```
--              v3.2 (2026-09-12): the pending-step CTE is replaced by
--              Lots.ufn_NextPendingRouteStep. Status + location filtering stays
--              here (this proc excludes Closed AND Open; siblings exclude only
--              Closed), so the extraction is behaviour-neutral.
```

- [ ] **Step 3: Rewire `Lot_GetComponentsAtCell` (Leg 1 only)**

Leg 2 is routeless and untouched. In `R__Lots_Lot_GetComponentsAtCell.sql`, delete the `NextStep AS (...)` CTE entirely and change Leg 1's `FROM`:

```sql
    FROM NextStep ns
    INNER JOIN Lots.Lot l                 ON l.Id = ns.LotId AND ns.rn = 1
```

to:

```sql
    FROM AtCell ac
    CROSS APPLY Lots.ufn_NextPendingRouteStep(ac.Id) ns
    INNER JOIN Lots.Lot l                 ON l.Id = ac.Id
```

`AtCell` already carries the status and location filtering. Bump to `Version: 1.1` with the same v3.2-style note.

- [ ] **Step 4: Rewire `Lot_GetTrimStorageQueueForLine`**

Same shape. Replace the `NextStep` CTE with an `Eligible` CTE holding the status and `TrimStores` location filter:

```sql
    Eligible AS (
        SELECT l.Id AS LotId
        FROM Lots.Lot l
        INNER JOIN Lots.LotStatusCode sc ON sc.Id = l.LotStatusId AND sc.Code <> N'Closed'
        WHERE l.CurrentLocationId IN (SELECT Id FROM TrimStores)
    )
```

and change the final `FROM`:

```sql
    FROM Eligible e
    CROSS APPLY Lots.ufn_NextPendingRouteStep(e.LotId) ns
    INNER JOIN Lots.Lot l               ON l.Id = e.LotId
```

- [ ] **Step 5: Rewire `Lot_MoveToValidated`**

Replace the whole `@NextPendingSeq` assignment block:

```sql
            DECLARE @NextPendingSeq INT = (
                SELECT MIN(rs.SequenceNumber)
                FROM Parts.RouteTemplate rt
                INNER JOIN Parts.RouteStep rs        ON rs.RouteTemplateId = rt.Id
                INNER JOIN Parts.OperationTemplate ot ON ot.Id = rs.OperationTemplateId
                INNER JOIN Parts.OperationType oty   ON oty.Id = ot.OperationTypeId
                INNER JOIN Parts.OperationRoleKind rk ON rk.Id = oty.OperationRoleKindId
                WHERE rt.ItemId = @ItemId AND rt.PublishedAt IS NOT NULL AND rt.DeprecatedAt IS NULL
                  AND (
                        rk.Code = N'ConsumeMint'
                     OR (rk.Code = N'Advance' AND NOT EXISTS (
                            SELECT 1 FROM Workorder.ProductionEvent pe
                            WHERE pe.LotId = @LotId AND pe.OperationTemplateId = rs.OperationTemplateId))
                      ));
```

with:

```sql
            DECLARE @NextPendingSeq INT = (
                SELECT SequenceNumber FROM Lots.ufn_NextPendingRouteStep(@LotId));
```

`@AttemptedSeq` above it is a plain "does this route have a step with this code" lookup — **leave it exactly as it is**.

- [ ] **Step 6: Run the full suite and diff against the baseline**

```bash
cd sql/tests && ./Run-Tests.ps1 2>&1 | tee ../../notes/_phaseA_after.txt
diff <(grep -oE '^(PASS|FAIL).*' ../../notes/_phaseA_baseline.txt) <(grep -oE '^(PASS|FAIL).*' ../../notes/_phaseA_after.txt)
```

Expected: **empty diff**, exit code 0. Any difference means the extraction changed behaviour — stop and fix it before proceeding.

- [ ] **Step 7: Commit**

```bash
rm notes/_phaseA_baseline.txt notes/_phaseA_after.txt
git add sql/migrations/repeatable/R__Lots_Lot_GetWipQueueByLocation.sql sql/migrations/repeatable/R__Lots_Lot_GetComponentsAtCell.sql sql/migrations/repeatable/R__Lots_Lot_GetTrimStorageQueueForLine.sql sql/migrations/repeatable/R__Lots_Lot_MoveToValidated.sql
git commit -m "refactor(sql): read procs use ufn_NextPendingRouteStep

Four of seven pending-step copies removed. Status/location filtering stays
per-caller. Full suite diffed against baseline -- no behaviour change."
```

---

### Task 3: Rewire `MachiningOut_Mint` (the three riskiest copies)

**Files:**
- Modify: `sql/migrations/repeatable/R__Workorder_MachiningOut_Mint.sql`
- Test: the existing suite, unmodified

**Interfaces:**
- Consumes: `Lots.ufn_NextPendingRouteStep(@LotId)`.
- Produces: no signature change.

> Separate from Task 2 because this proc computes **quantities**. If the availability count and the FIFO walk disagree, the failure is a wrong number rather than an error. A reviewer should be able to reject this task while accepting Task 2.

- [ ] **Step 1: Capture the baseline for the machining tests**

```bash
cd sql/tests && ./Run-Tests.ps1 -Filter "MachiningOut" 2>&1 | tee ../../notes/_mo_baseline.txt
```

Expected: PASS.

- [ ] **Step 2: Replace copy 1 — the `@TotalAvail` computation**

Delete the `;WITH NextStep AS (...)` block immediately above the `SELECT @TotalAvail` and rewrite the statement as:

```sql
        SELECT @TotalAvail = ISNULL(SUM(CASE WHEN l.InventoryAvailable < l.PieceCount THEN l.InventoryAvailable ELSE l.PieceCount END),0)
        FROM Lots.Lot l
        CROSS APPLY Lots.ufn_NextPendingRouteStep(l.Id) ns
        WHERE l.ItemId=@SrcItem AND l.CurrentLocationId=@SrcLoc AND l.LotStatusId=@GoodStatusId
          AND l.InventoryAvailable > 0 AND l.PieceCount > 0
          AND ns.OperationTypeCode = @OpTypeCode;
```

- [ ] **Step 3: Replace copy 2 — the `@SrcEligible` computation**

Delete its `;WITH NextStep AS (...)` block and rewrite as:

```sql
        SELECT @SrcEligible = CASE WHEN EXISTS (
            SELECT 1 FROM Lots.Lot l
            CROSS APPLY Lots.ufn_NextPendingRouteStep(l.Id) ns
            WHERE l.Id=@SourceLotId AND l.LotStatusId=@GoodStatusId
              AND l.InventoryAvailable > 0 AND l.PieceCount > 0
              AND ns.OperationTypeCode = @OpTypeCode
        ) THEN 1 ELSE 0 END;
```

- [ ] **Step 4: Replace copy 3 — the FIFO `@Queue` walk**

Delete its `;WITH NextStep AS (...)` block and rewrite the insert as:

```sql
        INSERT INTO @Queue (LotId)
        SELECT l.Id
        FROM Lots.Lot l
        CROSS APPLY Lots.ufn_NextPendingRouteStep(l.Id) ns
        LEFT JOIN (SELECT LotId, MAX(MovedAt) AS LastMovementAt FROM Lots.LotMovement GROUP BY LotId) lm ON lm.LotId=l.Id
        WHERE l.ItemId=@SrcItem AND l.CurrentLocationId=@SrcLoc AND l.LotStatusId=@GoodStatusId
          AND l.InventoryAvailable > 0 AND l.PieceCount > 0
          AND ns.OperationTypeCode = @OpTypeCode
        ORDER BY lm.LastMovementAt ASC, l.Id ASC;
```

> The old `NextStep` CTEs carried `sc.Code <> N'Closed'`. The outer queries already require `l.LotStatusId = @GoodStatusId`, which is strictly narrower, so dropping it changes nothing. Do not add a status filter to the function.

- [ ] **Step 5: Bump the header**

Add to the description block:

```
--              v2.3 (2026-09-12): all three inline pending-step CTEs replaced by
--              CROSS APPLY Lots.ufn_NextPendingRouteStep. The three copies had to
--              agree exactly -- availability, source eligibility and the FIFO walk
--              -- and now cannot drift.
```

- [ ] **Step 6: Run the full suite**

```bash
cd sql/tests && ./Run-Tests.ps1
```

Expected: PASS, 0 failures, exit code 0. Machining tests `0027/070`, `0027/080`, `0027/090` and CRT `0064/050` are the ones that matter here.

- [ ] **Step 7: Commit**

```bash
rm notes/_mo_baseline.txt
git add sql/migrations/repeatable/R__Workorder_MachiningOut_Mint.sql
git commit -m "refactor(sql): MachiningOut_Mint uses ufn_NextPendingRouteStep

Final three of seven copies. Availability, source eligibility and the FIFO
walk now share one definition and cannot drift apart."
```

---

# PHASE B — Entry point, cast date, stock destination

---

### Task 4: Migration 0080 — the three columns

**Files:**
- Create: `sql/migrations/versioned/0080_cutover_entry_route_and_cast_date.sql`
- Modify: `sql/migrations/repeatable/R__Descriptions_ExtendedProperties.sql`

**Interfaces:**
- Produces: `Lots.Lot.EntryRouteSequence INT NULL`, `Lots.Lot.CastDate DATE NULL`, `Location.Location.DefaultStockLocationId BIGINT NULL` (self-FK).

- [ ] **Step 1: Write the migration**

Create `sql/migrations/versioned/0080_cutover_entry_route_and_cast_date.sql`:

```sql
-- ============================================================
-- Migration:   0080_cutover_entry_route_and_cast_date.sql
-- Author:      Blue Ridge Automation
-- Date:        2026-09-12
-- Description: Inventory cutover scan support. Three nullable columns; every
--              existing row keeps today's behaviour with no backfill.
--
--              Lots.Lot.EntryRouteSequence -- where a LOT joined its route.
--              Route steps with SequenceNumber < this value are NOT part of the
--              LOT's journey and are never pending. NULL = entered at the start
--              (today's behaviour). Set for inventory scanned in at cutover, so a
--              casting counted at Machining IN does not surface in the Trim
--              queues. The alternative -- writing synthetic TrimIn/TrimOut
--              ProductionEvent rows -- would assert operations we never performed
--              and would pollute OEE and operator attribution.
--
--              Lots.Lot.CastDate -- the date on the physical LTT, keyed at scan
--              time. Drives real FIFO for migrated stock. NULL for normally
--              minted LOTs, whose arrival order already is their FIFO order.
--              NOT backdated onto Lots.LotMovement.MovedAt: that table is
--              partitioned on MovedAt under the sliding-window TRUNCATE
--              retention, so a backdated row lands in a partition maintenance is
--              designed to sweep, and the LOT's FIFO position would then change
--              silently. Lots.Lot is not partitioned.
--
--              Location.Location.DefaultStockLocationId -- where a line's scanned
--              stock is deposited. Self-FK; NULL = the line itself, which is how
--              M&A inventory works today. Present so warehouse stock for a line
--              is expressible later without reworking the scan surface.
--
--              Idempotent-guarded; no explicit transaction (repo convention).
--              ASCII-only.
-- ============================================================
IF EXISTS (SELECT 1 FROM dbo.SchemaVersion WHERE MigrationId = N'0080_cutover_entry_route_and_cast_date')
BEGIN PRINT 'Migration 0080 already applied -- skipping.'; RETURN; END
GO

IF COL_LENGTH('Lots.Lot', 'EntryRouteSequence') IS NULL
    ALTER TABLE Lots.Lot ADD EntryRouteSequence INT NULL;
GO

IF COL_LENGTH('Lots.Lot', 'CastDate') IS NULL
    ALTER TABLE Lots.Lot ADD CastDate DATE NULL;
GO

IF COL_LENGTH('Location.Location', 'DefaultStockLocationId') IS NULL
    ALTER TABLE Location.Location ADD DefaultStockLocationId BIGINT NULL;
GO

IF NOT EXISTS (SELECT 1 FROM sys.foreign_keys WHERE name = N'FK_Location_DefaultStockLocation')
    ALTER TABLE Location.Location
        ADD CONSTRAINT FK_Location_DefaultStockLocation
        FOREIGN KEY (DefaultStockLocationId) REFERENCES Location.Location(Id);
GO

IF NOT EXISTS (SELECT 1 FROM dbo.SchemaVersion WHERE MigrationId = N'0080_cutover_entry_route_and_cast_date')
    INSERT INTO dbo.SchemaVersion (MigrationId, Description)
    VALUES (N'0080_cutover_entry_route_and_cast_date',
            N'Lots.Lot.EntryRouteSequence + Lots.Lot.CastDate + Location.Location.DefaultStockLocationId. All nullable, no backfill. Inventory cutover scan support.');
GO
PRINT 'Migration 0080 (cutover_entry_route_and_cast_date) applied.';
GO
```

- [ ] **Step 2: Add the extended properties**

In `R__Descriptions_ExtendedProperties.sql`, follow the existing add-or-update pattern for each of the three columns. Descriptions (ASCII-only):

- `Lots.Lot.EntryRouteSequence` — `Route step SequenceNumber at which this LOT joined its route. Steps below this value are NOT part of the LOT journey and are never pending (Lots.ufn_NextPendingRouteStep). NULL = entered at the route start, which is every normally minted LOT. Set by the inventory cutover scan so physically counted stock surfaces at the terminal where it actually sits instead of at the first route step. Migration 0080.`
- `Lots.Lot.CastDate` — `Cast date read off the physical LTT at cutover scan time. Drives FIFO ordering for migrated stock via COALESCE(CastDate, last LotMovement). NULL for normally minted LOTs, whose arrival order already is their FIFO order. Deliberately not backdated onto LotMovement.MovedAt, which is partitioned under sliding-window TRUNCATE retention. Migration 0080.`
- `Location.Location.DefaultStockLocationId` — `On a Line, the Location where inventory scanned for this line is deposited. NULL = the line itself, which is how M&A inventory works today (LOTs are line-resident). Present so warehouse-held stock for a line is expressible without reworking the cutover scan. Self-FK. Migration 0080.`

- [ ] **Step 3: Apply and verify**

```bash
cd sql/tests && ./Run-Tests.ps1
```

Expected: PASS, 0 failures. `Run-Tests.ps1` rebuilds `MPP_MES_Test` from migrations, so a green run proves 0080 applies cleanly.

- [ ] **Step 4: Verify the columns exist and are nullable**

```bash
sqlcmd -S localhost -d MPP_MES_Test -E -b -I -C -Q "SELECT OBJECT_SCHEMA_NAME(c.object_id) s, OBJECT_NAME(c.object_id) t, c.name, c.is_nullable FROM sys.columns c WHERE c.name IN ('EntryRouteSequence','CastDate','DefaultStockLocationId');"
```

Expected: three rows, all `is_nullable = 1`.

- [ ] **Step 5: Commit**

```bash
git add sql/migrations/versioned/0080_cutover_entry_route_and_cast_date.sql sql/migrations/repeatable/R__Descriptions_ExtendedProperties.sql
git commit -m "feat(sql): 0080 -- EntryRouteSequence, CastDate, DefaultStockLocationId

Three nullable columns, no backfill, every existing row unchanged."
```

---

### Task 5: Teach the function the entry point, and `Lot_Create` to set it

**Files:**
- Modify: `sql/migrations/repeatable/R__Lots_ufn_NextPendingRouteStep.sql`
- Modify: `sql/migrations/repeatable/R__Lots_Lot_Create.sql`
- Test: `sql/tests/0070_Cutover_EntryRoute/020_EntryRouteSequence.sql`

**Interfaces:**
- Consumes: migration 0080 columns.
- Produces: `Lots.Lot_Create` gains `@EntryRouteSequence INT = NULL` and `@CastDate DATE = NULL`, both after `@DepositToStorage` in the parameter list. Result shape is unchanged: `Status`, `Message`, `NewId`, `MintedLotName`.

- [ ] **Step 1: Write the failing test**

Create `sql/tests/0070_Cutover_EntryRoute/020_EntryRouteSequence.sql`:

```sql
-- =============================================
-- File:         0070_Cutover_EntryRoute/020_EntryRouteSequence.sql
-- Description:  A casting created with EntryRouteSequence past TrimOut is absent
--               from the Trim queues and present at Machining IN -- without any
--               synthetic ProductionEvent rows. Also covers the NULL regression
--               and Lot_Create's new validations.
-- =============================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0070_Cutover_EntryRoute/020_EntryRouteSequence.sql';
GO

DECLARE @U BIGINT = (SELECT Id FROM Location.AppUser WHERE Initials = N'DEV');
DECLARE @Item BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'5G0-c');
DECLARE @Line BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MA1-5GOF');
DECLARE @Origin BIGINT = (SELECT Id FROM Lots.LotOriginType WHERE Code = N'Manufactured');

-- The MachiningIn step's SequenceNumber on this item's active route.
DECLARE @MinSeq INT = (SELECT rs.SequenceNumber
    FROM Parts.RouteTemplate rt
    JOIN Parts.RouteStep rs ON rs.RouteTemplateId = rt.Id
    JOIN Parts.OperationTemplate ot ON ot.Id = rs.OperationTemplateId
    JOIN Parts.OperationType oty ON oty.Id = ot.OperationTypeId
    WHERE rt.ItemId = @Item AND rt.PublishedAt IS NOT NULL AND rt.DeprecatedAt IS NULL
      AND oty.Code = N'MachiningIn');

CREATE TABLE #C (Status BIT, Message NVARCHAR(500), NewId BIGINT, MintedLotName NVARCHAR(50));

-- (1) Migrated LOT: entry point at MachiningIn, no ProductionEvents at all.
DECLARE @Mig BIGINT;
DELETE FROM #C;
INSERT INTO #C EXEC Lots.Lot_Create @ItemId = @Item, @LotOriginTypeId = @Origin,
    @CurrentLocationId = @Line, @PieceCount = 3298, @AppUserId = @U,
    @LotName = N'10625131', @EntryRouteSequence = @MinSeq, @CastDate = '2026-08-04';
SELECT @Mig = NewId FROM #C;

EXEC test.Assert_IsNotNull @TestName = N'[Entry] migrated LOT created', @Actual = @Mig;

DECLARE @b1 NVARCHAR(30) = (SELECT OperationTypeCode FROM Lots.ufn_NextPendingRouteStep(@Mig));
EXEC test.Assert_IsEqual @TestName = N'[Entry] next pending skips to MachiningIn',
    @Expected = N'MachiningIn', @Actual = @b1;

DECLARE @b2 NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10))
    FROM Workorder.ProductionEvent WHERE LotId = @Mig);
EXEC test.Assert_IsEqual @TestName = N'[Entry] no synthetic events were written',
    @Expected = N'0', @Actual = @b2;

-- (2) Absent from the Trim queues, present at Machining IN.
CREATE TABLE #Q (Id BIGINT, LotName NVARCHAR(50), ItemId BIGINT, ItemPartNumber NVARCHAR(50), ItemDescription NVARCHAR(500),
    PieceCount INT, LotStatusId BIGINT, LotStatusCode NVARCHAR(20), LastMovementAt DATETIME2(3),
    NextOperationTypeCode NVARCHAR(20), NextSequenceNumber INT);

DELETE FROM #Q; INSERT INTO #Q EXEC Lots.Lot_GetWipQueueByLocation @LocationId = @Line, @OperationTypeCode = N'TrimIn';
DECLARE @b3 NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM #Q WHERE Id = @Mig);
EXEC test.Assert_IsEqual @TestName = N'[Entry] absent from TrimIn queue', @Expected = N'0', @Actual = @b3;

DELETE FROM #Q; INSERT INTO #Q EXEC Lots.Lot_GetWipQueueByLocation @LocationId = @Line, @OperationTypeCode = N'TrimOut';
DECLARE @b4 NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM #Q WHERE Id = @Mig);
EXEC test.Assert_IsEqual @TestName = N'[Entry] absent from TrimOut queue', @Expected = N'0', @Actual = @b4;

DELETE FROM #Q; INSERT INTO #Q EXEC Lots.Lot_GetWipQueueByLocation @LocationId = @Line, @OperationTypeCode = N'MachiningIn';
DECLARE @b5 NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM #Q WHERE Id = @Mig);
EXEC test.Assert_IsEqual @TestName = N'[Entry] present in MachiningIn queue', @Expected = N'1', @Actual = @b5;

-- (3) NULL EntryRouteSequence behaves exactly as before (explicit regression).
DECLARE @Plain BIGINT;
DELETE FROM #C;
INSERT INTO #C EXEC Lots.Lot_Create @ItemId = @Item, @LotOriginTypeId = @Origin,
    @CurrentLocationId = @Line, @PieceCount = 10, @AppUserId = @U;
SELECT @Plain = NewId FROM #C;
DECLARE @b6 NVARCHAR(30) = (SELECT OperationTypeCode FROM Lots.ufn_NextPendingRouteStep(@Plain));
EXEC test.Assert_IsEqual @TestName = N'[Entry] NULL entry point unchanged (TrimIn)',
    @Expected = N'TrimIn', @Actual = @b6;

-- (4) An EntryRouteSequence matching no step on the route is rejected.
DELETE FROM #C;
INSERT INTO #C EXEC Lots.Lot_Create @ItemId = @Item, @LotOriginTypeId = @Origin,
    @CurrentLocationId = @Line, @PieceCount = 10, @AppUserId = @U,
    @EntryRouteSequence = 9999;
DECLARE @b7 NVARCHAR(10) = (SELECT CAST(Status AS NVARCHAR(10)) FROM #C);
EXEC test.Assert_IsEqual @TestName = N'[Entry] bogus EntryRouteSequence rejected',
    @Expected = N'0', @Actual = @b7;

-- (5) A future CastDate is rejected.
DELETE FROM #C;
INSERT INTO #C EXEC Lots.Lot_Create @ItemId = @Item, @LotOriginTypeId = @Origin,
    @CurrentLocationId = @Line, @PieceCount = 10, @AppUserId = @U,
    @CastDate = '2099-01-01';
DECLARE @b8 NVARCHAR(10) = (SELECT CAST(Status AS NVARCHAR(10)) FROM #C);
EXEC test.Assert_IsEqual @TestName = N'[Entry] future CastDate rejected',
    @Expected = N'0', @Actual = @b8;

-- (6) A duplicate LTT is rejected with a readable message, not a constraint error.
DELETE FROM #C;
INSERT INTO #C EXEC Lots.Lot_Create @ItemId = @Item, @LotOriginTypeId = @Origin,
    @CurrentLocationId = @Line, @PieceCount = 10, @AppUserId = @U,
    @LotName = N'10625131';
DECLARE @b9 NVARCHAR(500) = (SELECT Message FROM #C);
EXEC test.Assert_Contains @TestName = N'[Entry] duplicate LTT message names the tag',
    @Expected = N'10625131', @Actual = @b9;

DROP TABLE #Q; DROP TABLE #C;

-- Teardown
DELETE FROM Lots.LotEventLog WHERE LotId IN (@Mig, @Plain);
DELETE FROM Lots.LotMovement WHERE LotId IN (@Mig, @Plain);
DELETE FROM Lots.LotStatusHistory WHERE LotId IN (@Mig, @Plain);
DELETE FROM Lots.LotGenealogyClosure WHERE AncestorLotId IN (@Mig, @Plain) OR DescendantLotId IN (@Mig, @Plain);
DELETE FROM Lots.Lot WHERE Id IN (@Mig, @Plain);
GO
```

- [ ] **Step 2: Run it to verify it fails**

```bash
cd sql/tests && ./Run-Tests.ps1 -Filter "EntryRouteSequence"
```

Expected: FAIL — `@EntryRouteSequence is not a parameter for procedure Lot_Create`.

- [ ] **Step 3: Add the entry-point clause to the function**

In `R__Lots_ufn_NextPendingRouteStep.sql`, add one line to the `WHERE`, immediately after `WHERE l.Id = @LotId`:

```sql
    WHERE l.Id = @LotId
      AND rs.SequenceNumber >= ISNULL(l.EntryRouteSequence, 0)
      AND (
```

Bump to `Version: 1.1` and add to the description:

```
--              v1.1 (2026-09-12): honours Lots.Lot.EntryRouteSequence. Steps below
--              a LOT's entry point are not part of its journey and are never
--              pending. NULL (every pre-cutover row) means entry at the route
--              start, so this is inert for existing data.
```

- [ ] **Step 4: Add the parameters to `Lot_Create`**

Append to the parameter list, after `@DepositToStorage`:

```sql
    @DepositToStorage   BIT           = 0,      -- (existing)
    @EntryRouteSequence INT           = NULL,   -- cutover: route step at which this LOT joined
    @CastDate           DATE          = NULL    -- cutover: date off the physical LTT, drives FIFO
```

- [ ] **Step 5: Add the three validations**

Place these with the other rejecting validations, **before `BEGIN TRANSACTION`**. Each selects the status row and returns with no open transaction.

```sql
    -- Cutover: an entry point must name a real step on this item's active route,
    -- or the LOT would be invisible at every terminal.
    IF @EntryRouteSequence IS NOT NULL
       AND NOT EXISTS (SELECT 1
                       FROM Parts.RouteTemplate rt
                       INNER JOIN Parts.RouteStep rs ON rs.RouteTemplateId = rt.Id
                       WHERE rt.ItemId = @ItemId
                         AND rt.PublishedAt IS NOT NULL AND rt.DeprecatedAt IS NULL
                         AND rs.SequenceNumber = @EntryRouteSequence)
    BEGIN
        SET @Message = N'Entry route step ' + CAST(@EntryRouteSequence AS NVARCHAR(10))
                     + N' does not exist on this part''s active route.';
        EXEC Audit.Audit_LogFailure
            @AppUserId = @AppUserId, @LogEntityTypeCode = N'Lot',
            @EntityId = NULL, @LogEventTypeCode = N'LotCreated',
            @FailureReason = @Message, @ProcedureName = @ProcName,
            @AttemptedParameters = @Params;
        SELECT @Status AS Status, @Message AS Message, @NewId AS NewId, @MintedLotName AS MintedLotName;
        RETURN;
    END

    -- Cutover: nothing was cast in the future.
    DECLARE @Today DATE = CAST(SYSUTCDATETIME() AS DATE);
    IF @CastDate IS NOT NULL AND @CastDate > @Today
    BEGIN
        SET @Message = N'Cast date is in the future.';
        EXEC Audit.Audit_LogFailure
            @AppUserId = @AppUserId, @LogEntityTypeCode = N'Lot',
            @EntityId = NULL, @LogEventTypeCode = N'LotCreated',
            @FailureReason = @Message, @ProcedureName = @ProcName,
            @AttemptedParameters = @Params;
        SELECT @Status AS Status, @Message AS Message, @NewId AS NewId, @MintedLotName AS MintedLotName;
        RETURN;
    END

    -- A caller-supplied LTT that is already in use: reject readably rather than
    -- letting UQ_Lot_LotName surface as a constraint violation. Mirrors the
    -- existing guard in Lots.DieCastLot_Open.
    IF @LotName IS NOT NULL
       AND EXISTS (SELECT 1 FROM Lots.Lot WHERE LotName = @LotName)
    BEGIN
        SET @Message = N'LTT ' + @LotName + N' is already in use.';
        EXEC Audit.Audit_LogFailure
            @AppUserId = @AppUserId, @LogEntityTypeCode = N'Lot',
            @EntityId = NULL, @LogEventTypeCode = N'LotCreated',
            @FailureReason = @Message, @ProcedureName = @ProcName,
            @AttemptedParameters = @Params;
        SELECT @Status AS Status, @Message AS Message, @NewId AS NewId, @MintedLotName AS MintedLotName;
        RETURN;
    END
```

- [ ] **Step 6: Write the two columns in the INSERT**

Add `EntryRouteSequence` and `CastDate` to the `INSERT INTO Lots.Lot` column list and `@EntryRouteSequence`, `@CastDate` to its `VALUES`. Add both to the `@Params` JSON so a failure log records what was attempted.

- [ ] **Step 7: Run the test to verify it passes**

```bash
cd sql/tests && ./Run-Tests.ps1 -Filter "EntryRouteSequence"
```

Expected: PASS, 10 assertions, 0 failures.

- [ ] **Step 8: Run the full suite**

```bash
cd sql/tests && ./Run-Tests.ps1
```

Expected: PASS, 0 failures, exit code 0.

- [ ] **Step 9: Commit**

```bash
git add sql/migrations/repeatable/R__Lots_ufn_NextPendingRouteStep.sql sql/migrations/repeatable/R__Lots_Lot_Create.sql sql/tests/0070_Cutover_EntryRoute/020_EntryRouteSequence.sql
git commit -m "feat(sql): EntryRouteSequence honoured; Lot_Create accepts it and CastDate

A migrated casting surfaces at Machining IN with zero synthetic events.
New validations: entry step must exist on the route, cast date cannot be
in the future, a duplicate LTT is rejected readably."
```

---

### Task 6: Cast-date FIFO ordering

**Files:**
- Modify: `sql/migrations/repeatable/R__Lots_Lot_GetWipQueueByLocation.sql`
- Modify: `sql/migrations/repeatable/R__Lots_Lot_GetComponentsAtCell.sql`
- Modify: `sql/migrations/repeatable/R__Lots_Lot_GetTrimStorageQueueForLine.sql`
- Modify: `sql/migrations/repeatable/R__Workorder_MachiningOut_Mint.sql`
- Test: `sql/tests/0070_Cutover_EntryRoute/030_CastDate_fifo.sql`

**Interfaces:**
- Consumes: `Lots.Lot.CastDate`.
- Produces: no signature change. FIFO ordering becomes `COALESCE(CAST(l.CastDate AS DATETIME2(3)), lm.LastMovementAt)`.

- [ ] **Step 1: Write the failing test**

Create `sql/tests/0070_Cutover_EntryRoute/030_CastDate_fifo.sql`:

```sql
-- =============================================
-- File:         0070_Cutover_EntryRoute/030_CastDate_fifo.sql
-- Description:  Migrated stock consumes oldest-cast-first. Two LOTs are created
--               in an order that makes LotMovement.MovedAt the OPPOSITE of true
--               age; CastDate must win. A NULL CastDate keeps arrival ordering.
-- =============================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0070_Cutover_EntryRoute/030_CastDate_fifo.sql';
GO

DECLARE @U BIGINT = (SELECT Id FROM Location.AppUser WHERE Initials = N'DEV');
DECLARE @Item BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'5G0-c');
DECLARE @Line BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MA1-5GOF');
DECLARE @Origin BIGINT = (SELECT Id FROM Lots.LotOriginType WHERE Code = N'Manufactured');
DECLARE @MinSeq INT = (SELECT rs.SequenceNumber
    FROM Parts.RouteTemplate rt
    JOIN Parts.RouteStep rs ON rs.RouteTemplateId = rt.Id
    JOIN Parts.OperationTemplate ot ON ot.Id = rs.OperationTemplateId
    JOIN Parts.OperationType oty ON oty.Id = ot.OperationTypeId
    WHERE rt.ItemId = @Item AND rt.PublishedAt IS NOT NULL AND rt.DeprecatedAt IS NULL
      AND oty.Code = N'MachiningIn');

CREATE TABLE #C (Status BIT, Message NVARCHAR(500), NewId BIGINT, MintedLotName NVARCHAR(50));

-- Created FIRST (earlier MovedAt) but cast LATER.
DECLARE @Newer BIGINT;
DELETE FROM #C;
INSERT INTO #C EXEC Lots.Lot_Create @ItemId = @Item, @LotOriginTypeId = @Origin,
    @CurrentLocationId = @Line, @PieceCount = 100, @AppUserId = @U,
    @LotName = N'CASTFIFO-NEW', @EntryRouteSequence = @MinSeq, @CastDate = '2026-08-20';
SELECT @Newer = NewId FROM #C;

-- Created SECOND (later MovedAt) but cast EARLIER. This one must sort first.
DECLARE @Older BIGINT;
DELETE FROM #C;
INSERT INTO #C EXEC Lots.Lot_Create @ItemId = @Item, @LotOriginTypeId = @Origin,
    @CurrentLocationId = @Line, @PieceCount = 100, @AppUserId = @U,
    @LotName = N'CASTFIFO-OLD', @EntryRouteSequence = @MinSeq, @CastDate = '2026-08-01';
SELECT @Older = NewId FROM #C;

CREATE TABLE #Q (Id BIGINT, LotName NVARCHAR(50), ItemId BIGINT, ItemPartNumber NVARCHAR(50), ItemDescription NVARCHAR(500),
    PieceCount INT, LotStatusId BIGINT, LotStatusCode NVARCHAR(20), LastMovementAt DATETIME2(3),
    NextOperationTypeCode NVARCHAR(20), NextSequenceNumber INT);

INSERT INTO #Q EXEC Lots.Lot_GetWipQueueByLocation @LocationId = @Line, @OperationTypeCode = N'MachiningIn';

-- The queue is ordered; the earlier-cast LOT must appear ahead of the later-cast one.
DECLARE @PosOld INT = (SELECT rn FROM (SELECT Id, ROW_NUMBER() OVER (ORDER BY (SELECT 1)) rn FROM #Q) x WHERE Id = @Older);
DECLARE @PosNew INT = (SELECT rn FROM (SELECT Id, ROW_NUMBER() OVER (ORDER BY (SELECT 1)) rn FROM #Q) x WHERE Id = @Newer);
DECLARE @c1 NVARCHAR(10) = CASE WHEN @PosOld < @PosNew THEN N'1' ELSE N'0' END;
EXEC test.Assert_IsEqual @TestName = N'[CastDate] earlier cast date sorts first',
    @Expected = N'1', @Actual = @c1;

-- A LOT with NULL CastDate still orders by arrival: create one now (latest arrival)
-- and confirm it lands after both migrated LOTs.
DECLARE @Plain BIGINT;
DELETE FROM #C;
INSERT INTO #C EXEC Lots.Lot_Create @ItemId = @Item, @LotOriginTypeId = @Origin,
    @CurrentLocationId = @Line, @PieceCount = 100, @AppUserId = @U,
    @EntryRouteSequence = @MinSeq;
SELECT @Plain = NewId FROM #C;

DELETE FROM #Q;
INSERT INTO #Q EXEC Lots.Lot_GetWipQueueByLocation @LocationId = @Line, @OperationTypeCode = N'MachiningIn';
DECLARE @PosPlain INT = (SELECT rn FROM (SELECT Id, ROW_NUMBER() OVER (ORDER BY (SELECT 1)) rn FROM #Q) x WHERE Id = @Plain);
DECLARE @PosOld2  INT = (SELECT rn FROM (SELECT Id, ROW_NUMBER() OVER (ORDER BY (SELECT 1)) rn FROM #Q) x WHERE Id = @Older);
DECLARE @c2 NVARCHAR(10) = CASE WHEN @PosOld2 < @PosPlain THEN N'1' ELSE N'0' END;
EXEC test.Assert_IsEqual @TestName = N'[CastDate] NULL CastDate orders by arrival, after migrated stock',
    @Expected = N'1', @Actual = @c2;

DROP TABLE #Q; DROP TABLE #C;

-- Teardown
DELETE FROM Lots.LotEventLog WHERE LotId IN (@Newer, @Older, @Plain);
DELETE FROM Lots.LotMovement WHERE LotId IN (@Newer, @Older, @Plain);
DELETE FROM Lots.LotStatusHistory WHERE LotId IN (@Newer, @Older, @Plain);
DELETE FROM Lots.LotGenealogyClosure WHERE AncestorLotId IN (@Newer, @Older, @Plain) OR DescendantLotId IN (@Newer, @Older, @Plain);
DELETE FROM Lots.Lot WHERE Id IN (@Newer, @Older, @Plain);
GO
```

- [ ] **Step 2: Run it to verify it fails**

```bash
cd sql/tests && ./Run-Tests.ps1 -Filter "CastDate_fifo"
```

Expected: FAIL on `[CastDate] earlier cast date sorts first` — Expected `1`, Actual `0`.

- [ ] **Step 3: Change the four ordering sites**

In `Lot_GetWipQueueByLocation`, `Lot_GetComponentsAtCell` (both legs, so the `UNION ALL`'s single trailing `ORDER BY` stays consistent) and `Lot_GetTrimStorageQueueForLine`, change:

```sql
    ORDER BY lm.LastMovementAt ASC, l.Id ASC
```

to:

```sql
    ORDER BY COALESCE(CAST(l.CastDate AS DATETIME2(3)), lm.LastMovementAt) ASC, l.Id ASC
```

> `Lot_GetComponentsAtCell`'s final `ORDER BY LastMovementAt ASC, Id ASC` applies to the whole `UNION ALL`. Add a `FifoAt` column to **both** legs — `COALESCE(CAST(l.CastDate AS DATETIME2(3)), lm.LastMovementAt)` in Leg 1 and Leg 2 alike — and order by it. Do **not** add `FifoAt` to the result set the callers read; select it in an inner derived table and order the outer query by it, so the public column shape stays identical to `Lot_GetWipQueueByLocation`.

In `MachiningOut_Mint`, change the `@Queue` insert's ordering:

```sql
        ORDER BY COALESCE(CAST(l.CastDate AS DATETIME2(3)), lm.LastMovementAt) ASC, l.Id ASC;
```

- [ ] **Step 4: Run the test to verify it passes**

```bash
cd sql/tests && ./Run-Tests.ps1 -Filter "CastDate_fifo"
```

Expected: PASS, 2 assertions, 0 failures.

- [ ] **Step 5: Run the full suite**

```bash
cd sql/tests && ./Run-Tests.ps1
```

Expected: PASS, 0 failures. `CastDate` is NULL on every fixture LOT, so no existing ordering assertion moves.

- [ ] **Step 6: Commit**

```bash
git add sql/migrations/repeatable/R__Lots_Lot_GetWipQueueByLocation.sql sql/migrations/repeatable/R__Lots_Lot_GetComponentsAtCell.sql sql/migrations/repeatable/R__Lots_Lot_GetTrimStorageQueueForLine.sql sql/migrations/repeatable/R__Workorder_MachiningOut_Mint.sql sql/tests/0070_Cutover_EntryRoute/030_CastDate_fifo.sql
git commit -m "feat(sql): FIFO honours CastDate for migrated stock

COALESCE(CastDate, last movement) at the four ordering sites. NULL on every
existing row, so ordering is unchanged until migrated stock exists."
```

---

### Task 7: Die and cavity resolution read procs

**Files:**
- Create: `sql/migrations/repeatable/R__Tools_Tool_ListForItem.sql`
- Create: `sql/migrations/repeatable/R__Tools_ToolCavity_ListForItemTool.sql`
- Test: `sql/tests/0070_Cutover_EntryRoute/040_Tool_cavity_lookups.sql`

**Interfaces:**
- Produces:
  - `Tools.Tool_ListForItem @ItemId BIGINT` -> rows of `Id BIGINT`, `Code NVARCHAR(50)`, `Name NVARCHAR(100)`. One row means the scan screen resolves the die automatically.
  - `Tools.ToolCavity_ListForItemTool @ItemId BIGINT, @ToolId BIGINT` -> rows of `Id BIGINT`, `CavityCode NVARCHAR(4)`, `Description NVARCHAR(500)`, ordered by `CavityCode`.

- [ ] **Step 1: Write the failing test**

Create `sql/tests/0070_Cutover_EntryRoute/040_Tool_cavity_lookups.sql`:

```sql
-- =============================================
-- File:         0070_Cutover_EntryRoute/040_Tool_cavity_lookups.sql
-- Description:  Part -> die and (part, die) -> cavity lookups that drive the
--               cutover scan screen. Tools.ToolCavity is keyed (ToolId, ItemId,
--               CavityCode), so both are single indexed reads.
-- =============================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0070_Cutover_EntryRoute/040_Tool_cavity_lookups.sql';
GO

-- Any item that has at least one configured cavity.
DECLARE @Item BIGINT = (SELECT TOP 1 ItemId FROM Tools.ToolCavity WHERE DeprecatedAt IS NULL ORDER BY ItemId);

CREATE TABLE #T (Id BIGINT, Code NVARCHAR(50), Name NVARCHAR(100));
INSERT INTO #T EXEC Tools.Tool_ListForItem @ItemId = @Item;

DECLARE @d1 NVARCHAR(10) = CASE WHEN (SELECT COUNT(*) FROM #T) >= 1 THEN N'1' ELSE N'0' END;
EXEC test.Assert_IsEqual @TestName = N'[Tools] part resolves at least one die',
    @Expected = N'1', @Actual = @d1;

DECLARE @Tool BIGINT = (SELECT TOP 1 Id FROM #T ORDER BY Id);

CREATE TABLE #V (Id BIGINT, CavityCode NVARCHAR(4), Description NVARCHAR(500));
INSERT INTO #V EXEC Tools.ToolCavity_ListForItemTool @ItemId = @Item, @ToolId = @Tool;

DECLARE @d2 NVARCHAR(10) = CASE WHEN (SELECT COUNT(*) FROM #V) BETWEEN 1 AND 4 THEN N'1' ELSE N'0' END;
EXEC test.Assert_IsEqual @TestName = N'[Tools] (part,die) yields 1-4 cavities',
    @Expected = N'1', @Actual = @d2;

-- Cavity codes are the lowercase alphabetic per-part codes from migration 0076.
DECLARE @d3 NVARCHAR(10) = CASE WHEN NOT EXISTS (
    SELECT 1 FROM #V WHERE CavityCode IS NULL OR CavityCode <> LOWER(CavityCode))
    THEN N'1' ELSE N'0' END;
EXEC test.Assert_IsEqual @TestName = N'[Tools] cavity codes are lowercase and non-null',
    @Expected = N'1', @Actual = @d3;

-- An item with no cavities returns an empty set, not an error (FDS-11-011).
DELETE FROM #T; INSERT INTO #T EXEC Tools.Tool_ListForItem @ItemId = -1;
DECLARE @d4 NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM #T);
EXEC test.Assert_IsEqual @TestName = N'[Tools] unknown item returns empty set',
    @Expected = N'0', @Actual = @d4;

DROP TABLE #T; DROP TABLE #V;
GO
```

- [ ] **Step 2: Run it to verify it fails**

```bash
cd sql/tests && ./Run-Tests.ps1 -Filter "Tool_cavity_lookups"
```

Expected: FAIL — `Could not find stored procedure 'Tools.Tool_ListForItem'`.

- [ ] **Step 3: Write `Tool_ListForItem`**

Create `sql/migrations/repeatable/R__Tools_Tool_ListForItem.sql`:

```sql
-- ============================================================
-- Repeatable:  R__Tools_Tool_ListForItem.sql
-- Author:      Blue Ridge Automation
-- Modified:    2026-09-12
-- Version:     1.0
-- Description: Which dies can run this part. Tools.ToolCavity is keyed
--              (ToolId, ItemId, CavityCode), so this is one indexed read.
--
--              Under the family-die model a die runs several part numbers, but
--              a part almost always maps to exactly ONE die -- measured in Dev,
--              13 of 14 parts. The cutover scan screen relies on that: a single
--              row means the die is resolved and shown, not chosen; more than
--              one means show a picker.
--
--              Read proc: no OUTPUT params, empty result set = nothing found
--              (FDS-11-011).
-- ============================================================
CREATE OR ALTER PROCEDURE Tools.Tool_ListForItem
    @ItemId BIGINT
AS
BEGIN
    SET NOCOUNT ON;

    SELECT DISTINCT
           t.Id,
           t.Code,
           t.Name
    FROM Tools.ToolCavity tc
    INNER JOIN Tools.Tool t ON t.Id = tc.ToolId
    WHERE tc.ItemId = @ItemId
      AND tc.DeprecatedAt IS NULL
      AND t.DeprecatedAt IS NULL
    ORDER BY t.Code;
END;
GO
```

- [ ] **Step 4: Write `ToolCavity_ListForItemTool`**

Create `sql/migrations/repeatable/R__Tools_ToolCavity_ListForItemTool.sql`:

```sql
-- ============================================================
-- Repeatable:  R__Tools_ToolCavity_ListForItemTool.sql
-- Author:      Blue Ridge Automation
-- Modified:    2026-09-12
-- Version:     1.0
-- Description: The cavities of one die that produce one part. Drives the cutover
--              scan screen's cavity buttons -- measured spread is 1 to 4 per
--              (part, die), which is why they are buttons and not a dropdown.
--
--              CavityCode is the per-part lowercase alphabetic code introduced by
--              migration 0076. The floor writes cavity on the LTT as e.g. 'Da' --
--              capital letter = die revision, lowercase = cavity -- so the
--              lowercase code here is exactly what the operator reads off the tag.
--
--              Read proc: no OUTPUT params, empty result set = nothing found
--              (FDS-11-011).
-- ============================================================
CREATE OR ALTER PROCEDURE Tools.ToolCavity_ListForItemTool
    @ItemId BIGINT,
    @ToolId BIGINT
AS
BEGIN
    SET NOCOUNT ON;

    SELECT tc.Id,
           tc.CavityCode,
           tc.Description
    FROM Tools.ToolCavity tc
    WHERE tc.ItemId = @ItemId
      AND tc.ToolId = @ToolId
      AND tc.DeprecatedAt IS NULL
    ORDER BY tc.CavityCode;
END;
GO
```

- [ ] **Step 5: Run the test to verify it passes**

```bash
cd sql/tests && ./Run-Tests.ps1 -Filter "Tool_cavity_lookups"
```

Expected: PASS, 4 assertions, 0 failures.

- [ ] **Step 6: Commit**

```bash
git add sql/migrations/repeatable/R__Tools_Tool_ListForItem.sql sql/migrations/repeatable/R__Tools_ToolCavity_ListForItemTool.sql sql/tests/0070_Cutover_EntryRoute/040_Tool_cavity_lookups.sql
git commit -m "feat(sql): part -> die and (part,die) -> cavity lookups for cutover scan

One row from Tool_ListForItem means the scan screen resolves the die with no
operator input -- true for 13 of 14 parts under the family-die model."
```

---

### Task 8: Session-context and entry-step resolution reads

**Files:**
- Create: `sql/migrations/repeatable/R__Parts_RouteStep_GetSequenceForItemRole.sql`
- Create: `sql/migrations/repeatable/R__Location_Location_GetStockDestination.sql`
- Test: `sql/tests/0070_Cutover_EntryRoute/050_Session_context_reads.sql`

**Interfaces:**
- Produces:
  - `Parts.RouteStep_GetSequenceForItemRole @ItemId BIGINT, @OperationTypeCode NVARCHAR(30)` -> one row `SequenceNumber INT`, or empty. This is what the scan screen passes as `@EntryRouteSequence`. **Never computed in Python.**
  - `Location.Location_GetStockDestination @LineLocationId BIGINT` -> one row `DestinationLocationId BIGINT`, `DestinationCode NVARCHAR(50)`, `DestinationName NVARCHAR(100)` — resolving `ISNULL(DefaultStockLocationId, Id)`.

- [ ] **Step 1: Write the failing test**

Create `sql/tests/0070_Cutover_EntryRoute/050_Session_context_reads.sql`:

```sql
-- =============================================
-- File:         0070_Cutover_EntryRoute/050_Session_context_reads.sql
-- Description:  The two session-context reads behind the cutover scan header:
--               which route sequence a role sits at (-> EntryRouteSequence), and
--               where a line's scanned stock is deposited.
-- =============================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0070_Cutover_EntryRoute/050_Session_context_reads.sql';
GO

DECLARE @Item BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'5G0-c');
DECLARE @Line BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MA1-5GOF');

CREATE TABLE #S (SequenceNumber INT);
INSERT INTO #S EXEC Parts.RouteStep_GetSequenceForItemRole @ItemId = @Item, @OperationTypeCode = N'MachiningIn';

DECLARE @e1 NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM #S);
EXEC test.Assert_IsEqual @TestName = N'[Session] MachiningIn sequence resolves',
    @Expected = N'1', @Actual = @e1;

-- The resolved sequence must be usable as an EntryRouteSequence: it names a real step.
DECLARE @Seq INT = (SELECT SequenceNumber FROM #S);
DECLARE @e2 NVARCHAR(10) = CASE WHEN EXISTS (
    SELECT 1 FROM Parts.RouteTemplate rt
    JOIN Parts.RouteStep rs ON rs.RouteTemplateId = rt.Id
    WHERE rt.ItemId = @Item AND rt.PublishedAt IS NOT NULL AND rt.DeprecatedAt IS NULL
      AND rs.SequenceNumber = @Seq) THEN N'1' ELSE N'0' END;
EXEC test.Assert_IsEqual @TestName = N'[Session] resolved sequence names a real step',
    @Expected = N'1', @Actual = @e2;

-- A role the route does not carry returns an empty set, not an error.
DELETE FROM #S;
INSERT INTO #S EXEC Parts.RouteStep_GetSequenceForItemRole @ItemId = @Item, @OperationTypeCode = N'NoSuchRole';
DECLARE @e3 NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM #S);
EXEC test.Assert_IsEqual @TestName = N'[Session] unknown role returns empty set',
    @Expected = N'0', @Actual = @e3;

-- Stock destination: NULL DefaultStockLocationId -> the line itself.
CREATE TABLE #D (DestinationLocationId BIGINT, DestinationCode NVARCHAR(50), DestinationName NVARCHAR(100));
UPDATE Location.Location SET DefaultStockLocationId = NULL WHERE Id = @Line;
INSERT INTO #D EXEC Location.Location_GetStockDestination @LineLocationId = @Line;
DECLARE @e4 NVARCHAR(20) = (SELECT CAST(DestinationLocationId AS NVARCHAR(20)) FROM #D);
EXEC test.Assert_IsEqual @TestName = N'[Session] NULL destination resolves to the line itself',
    @Expected = CAST(@Line AS NVARCHAR(20)), @Actual = @e4;

-- Set it -> the named location wins.
DECLARE @Whse BIGINT = (SELECT TOP 1 Id FROM Location.Location WHERE Code = N'WHSE' AND DeprecatedAt IS NULL ORDER BY Id);
UPDATE Location.Location SET DefaultStockLocationId = @Whse WHERE Id = @Line;
DELETE FROM #D; INSERT INTO #D EXEC Location.Location_GetStockDestination @LineLocationId = @Line;
DECLARE @e5 NVARCHAR(20) = (SELECT CAST(DestinationLocationId AS NVARCHAR(20)) FROM #D);
EXEC test.Assert_IsEqual @TestName = N'[Session] configured destination wins',
    @Expected = CAST(@Whse AS NVARCHAR(20)), @Actual = @e5;

-- Restore
UPDATE Location.Location SET DefaultStockLocationId = NULL WHERE Id = @Line;
DROP TABLE #S; DROP TABLE #D;
GO
```

- [ ] **Step 2: Run it to verify it fails**

```bash
cd sql/tests && ./Run-Tests.ps1 -Filter "Session_context_reads"
```

Expected: FAIL — `Could not find stored procedure 'Parts.RouteStep_GetSequenceForItemRole'`.

- [ ] **Step 3: Write `RouteStep_GetSequenceForItemRole`**

Create `sql/migrations/repeatable/R__Parts_RouteStep_GetSequenceForItemRole.sql`:

```sql
-- ============================================================
-- Repeatable:  R__Parts_RouteStep_GetSequenceForItemRole.sql
-- Author:      Blue Ridge Automation
-- Modified:    2026-09-12
-- Version:     1.0
-- Description: The SequenceNumber at which an OperationType ROLE sits on a part's
--              active published route. The inventory cutover scan passes the
--              result as Lots.Lot_Create @EntryRouteSequence.
--
--              Resolution is by ROLE ('MachiningIn', 'AssemblyIn', ...), never by
--              OperationTemplate CODE -- template codes are 'M-In-A' / 'T-Out-A'
--              and a by-code lookup on a role name always misses.
--
--              This is domain logic and therefore lives in SQL, not in a
--              Perspective binding: the screen asks, it does not compute.
--
--              Read proc: no OUTPUT params, empty result set = the route carries
--              no step with that role (FDS-11-011).
-- ============================================================
CREATE OR ALTER PROCEDURE Parts.RouteStep_GetSequenceForItemRole
    @ItemId            BIGINT,
    @OperationTypeCode NVARCHAR(30)
AS
BEGIN
    SET NOCOUNT ON;

    SELECT MIN(rs.SequenceNumber) AS SequenceNumber
    FROM Parts.RouteTemplate rt
    INNER JOIN Parts.RouteStep rs         ON rs.RouteTemplateId = rt.Id
    INNER JOIN Parts.OperationTemplate ot ON ot.Id  = rs.OperationTemplateId
    INNER JOIN Parts.OperationType oty    ON oty.Id = ot.OperationTypeId
    WHERE rt.ItemId = @ItemId
      AND rt.PublishedAt IS NOT NULL AND rt.DeprecatedAt IS NULL
      AND oty.Code = @OperationTypeCode
    HAVING MIN(rs.SequenceNumber) IS NOT NULL;
END;
GO
```

- [ ] **Step 4: Write `Location_GetStockDestination`**

Create `sql/migrations/repeatable/R__Location_Location_GetStockDestination.sql`:

```sql
-- ============================================================
-- Repeatable:  R__Location_Location_GetStockDestination.sql
-- Author:      Blue Ridge Automation
-- Modified:    2026-09-12
-- Version:     1.0
-- Description: Where inventory scanned for a Line is deposited. Resolves
--              ISNULL(Location.DefaultStockLocationId, Id) and returns the
--              destination with its Code and Name so the cutover scan header can
--              show the operator where stock is actually landing.
--
--              NULL DefaultStockLocationId means the line itself, which is how
--              M&A inventory works today -- LOTs are line-resident. The column
--              exists so warehouse-held stock for a line becomes expressible
--              without reworking the scan surface. Migration 0080.
--
--              Read proc: no OUTPUT params, empty result set = unknown line
--              (FDS-11-011).
-- ============================================================
CREATE OR ALTER PROCEDURE Location.Location_GetStockDestination
    @LineLocationId BIGINT
AS
BEGIN
    SET NOCOUNT ON;

    SELECT d.Id   AS DestinationLocationId,
           d.Code AS DestinationCode,
           d.Name AS DestinationName
    FROM Location.Location l
    INNER JOIN Location.Location d ON d.Id = ISNULL(l.DefaultStockLocationId, l.Id)
    WHERE l.Id = @LineLocationId
      AND l.DeprecatedAt IS NULL;
END;
GO
```

- [ ] **Step 5: Run the test to verify it passes**

```bash
cd sql/tests && ./Run-Tests.ps1 -Filter "Session_context_reads"
```

Expected: PASS, 5 assertions, 0 failures.

- [ ] **Step 6: Run the full suite**

```bash
cd sql/tests && ./Run-Tests.ps1
```

Expected: PASS, 0 failures, exit code 0. This is the end of the SQL work — the whole suite must be green before any Ignition change.

- [ ] **Step 7: Commit**

```bash
git add sql/migrations/repeatable/R__Parts_RouteStep_GetSequenceForItemRole.sql sql/migrations/repeatable/R__Location_Location_GetStockDestination.sql sql/tests/0070_Cutover_EntryRoute/050_Session_context_reads.sql
git commit -m "feat(sql): session-context reads for the cutover scan

Route-role sequence resolution (-> EntryRouteSequence) and line stock
destination. Both are domain questions and answered in SQL, not Python."
```

---

# PHASE C — The scan surface

---

### Task 9: Named queries and Python wrappers

**Files:**
- Modify: `ignition/projects/Core/ignition/named-query/lots/Lot_Create/query.sql`
- Modify: `ignition/projects/Core/ignition/named-query/lots/Lot_Create/resource.json`
- Create: `ignition/projects/Core/ignition/named-query/tools/Tool_ListForItem/{query.sql,resource.json}`
- Create: `ignition/projects/Core/ignition/named-query/tools/ToolCavity_ListForItemTool/{query.sql,resource.json}`
- Create: `ignition/projects/Core/ignition/named-query/parts/RouteStep_GetSequenceForItemRole/{query.sql,resource.json}`
- Create: `ignition/projects/Core/ignition/named-query/location/Location_GetStockDestination/{query.sql,resource.json}`
- Modify: `ignition/projects/Core/ignition/script-python/BlueRidge/Lots/Lot/code.py`
- Modify: `ignition/projects/Core/ignition/script-python/BlueRidge/Tools/Tool/code.py`
- Modify: `ignition/projects/Core/ignition/script-python/BlueRidge/Parts/RouteTemplate/code.py`
- Modify: `ignition/projects/Core/ignition/script-python/BlueRidge/Location/Location/code.py`

**Interfaces:**
- Consumes: the procs from Tasks 5, 7, 8.
- Produces:
  - `BlueRidge.Lots.Lot.create(data, appUserId, terminalLocationId, lotName)` — `data` gains optional `entryRouteSequence` and `castDate` keys.
  - `BlueRidge.Tools.Tool.listForItem(itemId)` -> `list[dict]` with `Id`, `Code`, `Name`.
  - `BlueRidge.Tools.Tool.listCavitiesForItemTool(itemId, toolId)` -> `list[dict]` with `Id`, `CavityCode`, `Description`.
  - `BlueRidge.Parts.RouteTemplate.getSequenceForItemRole(itemId, roleCode)` -> `int` or `None`.
  - `BlueRidge.Location.Location.getStockDestination(lineLocationId)` -> `dict` with `DestinationLocationId`, `DestinationCode`, `DestinationName`, or `None`.

- [ ] **Step 1: Extend the `Lot_Create` named query**

Append to `query.sql`:

```sql
EXEC Lots.Lot_Create
    @ItemId             = :itemId,
    @LotOriginTypeId    = :lotOriginTypeId,
    @CurrentLocationId  = :currentLocationId,
    @PieceCount         = :pieceCount,
    @Weight             = :weight,
    @WeightUomId        = :weightUomId,
    @ToolId             = :toolId,
    @ToolCavityId       = :toolCavityId,
    @VendorLotNumber    = :vendorLotNumber,
    @MinSerialNumber    = :minSerialNumber,
    @MaxSerialNumber    = :maxSerialNumber,
    @AppUserId          = :appUserId,
    @TerminalLocationId = :terminalLocationId,
    @LotName            = :lotName,
    @DepositToStorage   = :depositToStorage,
    @EntryRouteSequence = :entryRouteSequence,
    @CastDate           = :castDate
```

In `resource.json`, append two entries to `attributes.parameters`:

```json
      {
        "type": "Parameter",
        "identifier": "entryRouteSequence",
        "sqlType": 2
      },
      {
        "type": "Parameter",
        "identifier": "castDate",
        "sqlType": 8
      }
```

`sqlType: 2` = INTEGER (Designer's `Int4`). `sqlType: 8` = DateTime -- Designer's enum has no
DATE code, and SQL Server widens a DateTime bind to `DATE` on the proc parameter without
complaint. `91` is a `java.sql.Types` constant and is **wrong** here.

- [ ] **Step 2: Create the four new named queries**

Each folder gets a `query.sql` and a `resource.json`. Copy the `resource.json` shape from `lots/Lot_Create/resource.json`, changing only `parameters` and — for read procs — nothing else (`"type": "Query"` is correct for all four; all return a result set).

`tools/Tool_ListForItem/query.sql`:

```sql
EXEC Tools.Tool_ListForItem @ItemId = :itemId
```
parameters: `itemId` sqlType `3`.

`tools/ToolCavity_ListForItemTool/query.sql`:

```sql
EXEC Tools.ToolCavity_ListForItemTool @ItemId = :itemId, @ToolId = :toolId
```
parameters: `itemId` sqlType `3`, `toolId` sqlType `3`.

`parts/RouteStep_GetSequenceForItemRole/query.sql`:

```sql
EXEC Parts.RouteStep_GetSequenceForItemRole @ItemId = :itemId, @OperationTypeCode = :operationTypeCode
```
parameters: `itemId` sqlType `3`, `operationTypeCode` sqlType `7`.

`location/Location_GetStockDestination/query.sql`:

```sql
EXEC Location.Location_GetStockDestination @LineLocationId = :lineLocationId
```
parameters: `lineLocationId` sqlType `3`.

- [ ] **Step 3: Extend `BlueRidge.Lots.Lot.create`**

In `code.py`, add two keys to the `params` dict, after `depositToStorage`:

```python
        # Cutover scan: where this LOT joined its route, and the date off the
        # physical LTT. Both None for every normal mint.
        "entryRouteSequence": d.get("entryRouteSequence"),
        "castDate":           d.get("castDate"),
```

and extend the docstring's field list with `entryRouteSequence, castDate`.

- [ ] **Step 4: Add the four read wrappers**

In `BlueRidge/Tools/Tool/code.py`:

```python
def listForItem(itemId):
    """Dies that can run this part. One row means the cutover scan screen
       resolves the die with no operator input. Returns list[dict] with
       Id, Code, Name -- never None."""
    if itemId is None:
        return []
    try:
        return BlueRidge.Common.Db.execList("tools/Tool_ListForItem",
                                            {"itemId": itemId}) or []
    except (Exception, java.lang.Exception) as e:
        BlueRidge.Common.Util.log("listForItem failed: %s" % str(e))
        return []


def listCavitiesForItemTool(itemId, toolId):
    """The cavities of one die that produce one part. CavityCode is the per-part
       lowercase alphabetic code (migration 0076) -- exactly the lowercase letter
       the operator reads off the LTT. Returns list[dict], never None."""
    if itemId is None or toolId is None:
        return []
    try:
        return BlueRidge.Common.Db.execList("tools/ToolCavity_ListForItemTool",
                                            {"itemId": itemId, "toolId": toolId}) or []
    except (Exception, java.lang.Exception) as e:
        BlueRidge.Common.Util.log("listCavitiesForItemTool failed: %s" % str(e))
        return []
```

In `BlueRidge/Parts/RouteTemplate/code.py`:

```python
def getSequenceForItemRole(itemId, roleCode):
    """The route SequenceNumber at which an OperationType ROLE sits on this
       part's active published route -- the value the cutover scan passes as
       Lot_Create @EntryRouteSequence. Resolution is by ROLE, never by
       OperationTemplate code. Returns int, or None when the route has no such
       step."""
    if itemId is None or not roleCode:
        return None
    try:
        rows = BlueRidge.Common.Db.execList("parts/RouteStep_GetSequenceForItemRole",
                                            {"itemId": itemId,
                                             "operationTypeCode": roleCode}) or []
    except (Exception, java.lang.Exception) as e:
        BlueRidge.Common.Util.log("getSequenceForItemRole failed: %s" % str(e))
        return None
    if not rows:
        return None
    return rows[0].get("SequenceNumber")
```

In `BlueRidge/Location/Location/code.py`:

```python
_EMPTY_STOCK_DEST = {"DestinationLocationId": None,
                     "DestinationCode": "",
                     "DestinationName": ""}


def getStockDestination(lineLocationId):
    """Where inventory scanned for this line is deposited. Returns a dict with
       DestinationLocationId / DestinationCode / DestinationName, or None when the
       line is unknown. Use getStockDestinationOrEmpty for binding sources."""
    if lineLocationId is None:
        return None
    try:
        rows = BlueRidge.Common.Db.execList("location/Location_GetStockDestination",
                                            {"lineLocationId": lineLocationId}) or []
    except (Exception, java.lang.Exception) as e:
        BlueRidge.Common.Util.log("getStockDestination failed: %s" % str(e))
        return None
    if not rows:
        return None
    return rows[0]


def getStockDestinationOrEmpty(lineLocationId):
    """Binding-safe getStockDestination: always returns the full shape so a
       nested-path binding never reads a non-existent property."""
    row = getStockDestination(lineLocationId)
    if not row:
        return dict(_EMPTY_STOCK_DEST)
    return row
```

> Each module must already `import java.lang` for the `except (Exception, java.lang.Exception)` guard. If it does not, add the import at the top — a Jython bare `except Exception` does not catch Java exceptions, and these are never-throw guards.

- [ ] **Step 5: Scan the new resources into the gateway**

```bash
./scan.ps1
```

Expected: the four new named queries and the modified scripts are picked up. Check the output names each one.

- [ ] **Step 6: Verify the wrappers against the live gateway**

In the Designer script console:

```python
print BlueRidge.Parts.RouteTemplate.getSequenceForItemRole(
    BlueRidge.Parts.Item.getByPartNumber("5G0-c").get("Id"), "MachiningIn")
```

Expected: an integer (the MachiningIn step's sequence), not `None`.

- [ ] **Step 7: Commit**

```bash
git add ignition/projects/Core/ignition/named-query/lots/Lot_Create ignition/projects/Core/ignition/named-query/tools/Tool_ListForItem ignition/projects/Core/ignition/named-query/tools/ToolCavity_ListForItemTool ignition/projects/Core/ignition/named-query/parts/RouteStep_GetSequenceForItemRole ignition/projects/Core/ignition/named-query/location/Location_GetStockDestination ignition/projects/Core/ignition/script-python/BlueRidge/Lots/Lot/code.py ignition/projects/Core/ignition/script-python/BlueRidge/Tools/Tool/code.py ignition/projects/Core/ignition/script-python/BlueRidge/Parts/RouteTemplate/code.py ignition/projects/Core/ignition/script-python/BlueRidge/Location/Location/code.py
git commit -m "feat(ignition): named queries + wrappers for the cutover scan

Lot_Create gains entryRouteSequence + castDate. Four new reads for die,
cavity, route-role sequence and line stock destination."
```

---

### Task 10: Scan logic as a Core script module

> **Phase C was re-planned on 2026-09-12** after Jacques delivered the
> `Breakpoint Example` view (MPP project). It is a **nested `ia.container.breakpt`**:
> an outer container at `breakpoint: 900` whose `large` child is the desktop view, and
> whose small side is an inner container at `breakpoint: 500` with a phone child and a
> `large` tablet child. Net: `<500` phone, `500-899` tablet, `>=900` desktop, under ONE
> page configuration. `position.size: "large"` marks the large-side child; a child
> without it is the small-side one.
>
> Two consequences drove the re-plan:
>
> 1. **Only the active branch renders.** State held in a size view's own
>    `view.custom` would be lost the moment the viewport crossed a breakpoint. The
>    scan session is genuinely session-scoped anyway (one operator, one line, one
>    walk of the rack), so it lives in `session.custom.cutover`.
> 2. **Three size views must not triplicate the logic.** All behaviour goes into a
>    Core script module; each size view is presentation plus one-line calls. That is
>    the repo's standing three-layer rule (View -> entity script -> Common helpers),
>    not a special case.

**Files:**
- Create: `ignition/projects/Core/ignition/script-python/BlueRidge/Cutover/Scan/{code.py,resource.json}`
- Modify: `ignition/projects/Core/com.inductiveautomation.perspective/session-props/props.json`

**Interfaces:**
- Consumes: the named queries and wrappers from Task 9.
- Produces `BlueRidge.Cutover.Scan`:
  - `loadSession(lineLocationId, itemId, entryRoleCode, machineNumber)` -> writes
    `session.custom.cutover.session`; returns `{Status, Message}`.
  - `addBasket(draft, appUserId, terminalLocationId)` -> `{Status, Message, NewId}`;
    appends to `session.custom.cutover.rows` and recomputes totals.
  - `addBox(draft, appUserId, terminalLocationId)` -> same shape, purchased path.
  - `voidEntry(lotId, appUserId)` -> `{Status, Message}`; closes the LOT, drops the row.
  - `stepCastDate(days)` -> the new date, capped at today.
  - `getState()` -> the full `session.custom.cutover` shape, every key present.

`session.custom.cutover` default shape, declared in `session-props/props.json` fully
shaped -- a binding that traverses a nested path against a missing property renders a
Component Error:

```json
"cutover": {
  "session": {
    "lineLocationId": null, "lineName": "", "destinationLocationId": null,
    "destinationName": "", "entryRoleCode": "MachiningIn", "entryRouteSequence": null,
    "itemId": null, "partNumber": "", "partDescription": "",
    "toolId": null, "toolCode": "", "toolIsAmbiguous": false, "machineNumber": ""
  },
  "entry":     {"lotName": "", "toolCavityId": null, "cavityCode": "", "castDate": null, "pieceCount": ""},
  "purchased": {"partNumber": "", "partDescription": "", "itemId": null, "qty": "", "vendorLot": ""},
  "cavityOptions": [], "toolOptions": [], "rows": [],
  "totals": {"baskets": 0, "pieces": 0}, "mode": "cast"
}
```

- [ ] **Step 1: Declare the session-prop shape**

Add the `cutover` block above under `custom` in `session-props/props.json`, every key
present. Run `.\scan.ps1` and confirm a session starts with no Component Error.

- [ ] **Step 2: Write `getState` / `_write` and `loadSession`**

`_write` assigns the whole dict in ONE statement. Never key by key -- a binding
re-evaluates between sequential writes and sees half-built state.

```python
_EMPTY = {
    "session": {"lineLocationId": None, "lineName": "", "destinationLocationId": None,
                "destinationName": "", "entryRoleCode": "MachiningIn",
                "entryRouteSequence": None, "itemId": None, "partNumber": "",
                "partDescription": "", "toolId": None, "toolCode": "",
                "toolIsAmbiguous": False, "machineNumber": ""},
    "entry": {"lotName": "", "toolCavityId": None, "cavityCode": "",
              "castDate": None, "pieceCount": ""},
    "purchased": {"partNumber": "", "partDescription": "", "itemId": None,
                  "qty": "", "vendorLot": ""},
    "cavityOptions": [], "toolOptions": [], "rows": [],
    "totals": {"baskets": 0, "pieces": 0}, "mode": "cast",
}


def getState():
    """The whole cutover session state, always fully shaped."""
    raw = system.perspective.getSessionInfo()["custom"].get("cutover")
    st = BlueRidge.Common.Util.extractQualifiedValues(raw) or {}
    out = dict(_EMPTY)
    for k, v in st.items():
        out[k] = v
    return out


def _write(state, session):
    """ONE assignment. Key-by-key writes let a binding see half-built state."""
    session.custom.cutover = state


def loadSession(lineLocationId, itemId, entryRoleCode, machineNumber, session):
    """Latch the scan session. Every domain question is asked of SQL; this only
       assembles the answers. Returns {Status, Message}."""
    item = BlueRidge.Parts.Item.getById(itemId) or {}
    line = BlueRidge.Location.Location.getById(lineLocationId) or {}
    dest = BlueRidge.Location.Location.getStockDestinationOrEmpty(lineLocationId)
    seq = BlueRidge.Parts.RouteTemplate.getSequenceForItemRole(itemId, entryRoleCode)
    if seq is None:
        return {"Status": 0,
                "Message": "%s has no %s step on its active route."
                           % (item.get("PartNumber"), entryRoleCode)}

    tools = BlueRidge.Tools.Tool.listForItem(itemId)
    toolId, toolCode, ambiguous = None, "", False
    if len(tools) == 1:
        toolId, toolCode = tools[0].get("Id"), tools[0].get("Code")
    elif len(tools) > 1:
        ambiguous = True

    cavities = BlueRidge.Tools.Tool.listCavitiesForItemTool(itemId, toolId) if toolId else []

    st = getState()
    st["session"] = {
        "lineLocationId": lineLocationId, "lineName": line.get("Name") or "",
        "destinationLocationId": dest.get("DestinationLocationId"),
        "destinationName": dest.get("DestinationName") or "",
        "entryRoleCode": entryRoleCode, "entryRouteSequence": seq,
        "itemId": itemId, "partNumber": item.get("PartNumber") or "",
        "partDescription": item.get("Description") or "",
        "toolId": toolId, "toolCode": toolCode, "toolIsAmbiguous": ambiguous,
        "machineNumber": machineNumber or "",
    }
    st["toolOptions"], st["cavityOptions"] = tools, cavities
    st["rows"], st["totals"] = [], {"baskets": 0, "pieces": 0}
    _write(st, session)
    return {"Status": 1, "Message": "Session ready"}
```

- [ ] **Step 3: Write `addBasket`**

```python
def addBasket(appUserId, terminalLocationId, session):
    """Create one migrated casting LOT. The scanned LTT becomes the LOT name
       verbatim -- no re-tagging. Returns {Status, Message, NewId}."""
    st = getState()
    s, e = st["session"], st["entry"]

    lotName = (e.get("lotName") or "").strip()
    if not lotName:
        return {"Status": 0, "Message": "Scan the LTT barcode."}
    if e.get("toolCavityId") is None:
        return {"Status": 0, "Message": "Tap the cavity shown on the tag."}
    if e.get("castDate") is None:
        return {"Status": 0, "Message": "Set the cast date from the tag."}
    try:
        pieces = int(("%s" % e.get("pieceCount")).strip())
    except (ValueError, TypeError):
        return {"Status": 0, "Message": "Enter a whole number."}
    if pieces <= 0:
        return {"Status": 0, "Message": "Enter how many are in the basket."}

    res = BlueRidge.Lots.Lot.create({
        "itemId": s.get("itemId"),
        "lotOriginTypeId": BlueRidge.Lots.Lot.getOriginTypeIdByCode("Manufactured"),
        "currentLocationId": s.get("destinationLocationId"),
        "pieceCount": pieces,
        "toolId": s.get("toolId"),
        "toolCavityId": e.get("toolCavityId"),
        "entryRouteSequence": s.get("entryRouteSequence"),
        "castDate": e.get("castDate"),
    }, appUserId, terminalLocationId, lotName)
    if not (res and res.get("Status")):
        return res

    # Only the LTT and the count clear. Cavity and cast date LATCH, because
    # baskets come off the rack grouped by both.
    e["lotName"], e["pieceCount"] = "", ""
    rows = list(st.get("rows") or [])
    rows.insert(0, {"LotId": res.get("NewId"), "LotName": lotName,
                    "PartNumber": s.get("partNumber"), "CavityCode": e.get("cavityCode"),
                    "CastDate": e.get("castDate"), "PieceCount": pieces})
    st["entry"], st["rows"] = e, rows
    st["totals"] = {"baskets": len(rows),
                    "pieces": sum([r.get("PieceCount") or 0 for r in rows])}
    _write(st, session)
    return res
```

- [ ] **Step 4: Write `addBox`, `voidEntry`, `stepCastDate`**

```python
def addBox(appUserId, terminalLocationId, session):
    """Create one received purchased-component LOT. The box has no LTT, so the
       LOT name is minted server-side and the supplier lot goes to
       VendorLotNumber. Returns {Status, Message, NewId}."""
    st = getState()
    s, p = st["session"], st["purchased"]

    itemId = p.get("itemId")
    if itemId is None:
        row = BlueRidge.Parts.Item.getByPartNumber((p.get("partNumber") or "").strip())
        if row is None:
            return {"Status": 0,
                    "Message": "No active item matches '%s'." % p.get("partNumber")}
        itemId = row.get("Id")
    try:
        qty = int(("%s" % p.get("qty")).strip())
    except (ValueError, TypeError):
        return {"Status": 0, "Message": "Enter a whole number."}
    if qty <= 0:
        return {"Status": 0, "Message": "Enter how many are in the box."}

    res = BlueRidge.Lots.Lot.create({
        "itemId": itemId,
        "lotOriginTypeId": BlueRidge.Lots.Lot.getOriginTypeIdByCode("Received"),
        "currentLocationId": s.get("destinationLocationId"),
        "pieceCount": qty,
        "vendorLotNumber": (p.get("vendorLot") or "").strip() or None,
    }, appUserId, terminalLocationId)
    if not (res and res.get("Status")):
        return res

    rows = list(st.get("rows") or [])
    rows.insert(0, {"LotId": res.get("NewId"), "LotName": res.get("MintedLotName"),
                    "PartNumber": p.get("partNumber"), "CavityCode": "",
                    "CastDate": None, "PieceCount": qty})
    st["purchased"] = {"partNumber": "", "partDescription": "", "itemId": None,
                       "qty": "", "vendorLot": ""}
    st["rows"] = rows
    st["totals"] = {"baskets": len(rows),
                    "pieces": sum([r.get("PieceCount") or 0 for r in rows])}
    _write(st, session)
    return res


def voidEntry(lotId, appUserId, session):
    """Undo a mis-scanned entry. The LOT is CLOSED with a cutover-correction
       reason, never deleted -- nothing in the plant holds trustworthy inventory
       to reconcile against, so the correction itself is the record."""
    res = BlueRidge.Lots.Lot.updateStatus(
        lotId, "Closed",
        "Voided during inventory cutover scan (mis-scan correction).", appUserId)
    if not (res and res.get("Status")):
        return res
    st = getState()
    rows = [r for r in (st.get("rows") or []) if r.get("LotId") != lotId]
    st["rows"] = rows
    st["totals"] = {"baskets": len(rows),
                    "pieces": sum([r.get("PieceCount") or 0 for r in rows])}
    _write(st, session)
    return res


def stepCastDate(days, session):
    """Move the cast date by whole days, capped at today. Seeded from the last
       basket scanned, so consecutive baskets are zero or one tap."""
    st = getState()
    cur = st["entry"].get("castDate") or system.date.now()
    nxt = system.date.addDays(cur, days)
    if system.date.isAfter(system.date.midnight(nxt),
                           system.date.midnight(system.date.now())):
        return cur
    st["entry"]["castDate"] = nxt
    _write(st, session)
    return nxt
```

- [ ] **Step 5: Verify from the Designer script console**

```python
print BlueRidge.Cutover.Scan.getState()["session"]["entryRouteSequence"]
```

Expected: the full shape returns with every key present even before any session is
loaded -- that is what keeps the first paint free of Component Errors.

- [ ] **Step 6: Commit**

```bash
git add ignition/projects/Core/ignition/script-python/BlueRidge/Cutover ignition/projects/Core/com.inductiveautomation.perspective/session-props
git commit -m "feat(ignition): cutover scan logic as a Core script module

State lives in session.custom.cutover because only the active breakpoint branch
renders -- per-view state would be lost crossing a breakpoint."
```

---

### Task 11: The three size views and the breakpoint host

**Files:**
- Create: `.../views/BlueRidge/Views/ShopFloor/CutoverScan/{view.json,resource.json}` (host)
- Create: `.../views/BlueRidge/Views/ShopFloor/_CutoverScan/Phone/{view.json,resource.json}`
- Create: `.../views/BlueRidge/Views/ShopFloor/_CutoverScan/Tablet/{view.json,resource.json}`
- Create: `.../views/BlueRidge/Views/ShopFloor/_CutoverScan/Desktop/{view.json,resource.json}`
- Modify: `.../page-config/config.json`

> `_<Name>/` is the repo convention for "internals of `<Name>`" -- these three are not
> independently addressable pages.

**Interfaces:**
- Consumes: `BlueRidge.Cutover.Scan` (Task 10).
- Produces: the page `/shop-floor/cutover-scan`.

- [ ] **Step 1: Build the host, mirroring `Breakpoint Example`**

```json
{
  "custom": {}, "params": {}, "props": {},
  "root": {
    "type": "ia.container.breakpt",
    "meta": { "name": "root" },
    "props": { "breakpoint": 900, "currentBreakpoint": "large" },
    "children": [
      { "type": "ia.container.breakpt",
        "meta": { "name": "BreakpointContainer" },
        "props": { "breakpoint": 500, "currentBreakpoint": "large" },
        "children": [
          { "type": "ia.display.view", "meta": { "name": "phone" },
            "props": { "path": "BlueRidge/Views/ShopFloor/_CutoverScan/Phone" } },
          { "type": "ia.display.view", "meta": { "name": "tablet" },
            "position": { "size": "large" },
            "props": { "path": "BlueRidge/Views/ShopFloor/_CutoverScan/Tablet" } }
        ] },
      { "type": "ia.display.view", "meta": { "name": "desktop" },
        "position": { "size": "large" },
        "props": { "path": "BlueRidge/Views/ShopFloor/_CutoverScan/Desktop" } }
    ]
  }
}
```

`Breakpoint Example`'s embeds carry no `props.path` -- it is a skeleton; add them. Keep
`meta.name` exactly `root` on the outer container. Each view folder needs its own
`resource.json` with `"scope": "G"` or the page reports "View Not Found".

- [ ] **Step 2: Build the three size views**

All three bind to `session.custom.cutover.*` and call `BlueRidge.Cutover.Scan.*` as
one-liners. Layout per the mockups
(https://claude.ai/code/artifact/b198811e-e705-4754-98b7-fec93aeddafb):

| View | Layout |
|---|---|
| Phone | single column; session list collapsed to a pinned summary bar |
| Tablet | two columns -- entry left (~390px), session panel right |
| Desktop | latched header full width; entry (~420px) + session side by side |

Rules that apply to all three:

- Style classes by **suffix only** (`pf-panel`, not `psc-pf-panel`). Reuse the existing
  vocabulary: `pf-terminal*`, `pf-tab-strip`/`pf-tab`/`pf-tab-active`, `pf-panel`,
  `pf-field`/`pf-field-label`/`pf-field-input`/`pf-field-input-mono`,
  `pf-toggle-group`/`pf-toggle-btn`/`pf-toggle-btn-selected`,
  `pf-btn pf-btn-primary`, `pf-kpi*`, `pf-queue*`, `pf-empty-state`.
- Conditional mode containers bind **`position.display`**, never `meta.visible`.
- Inputs set `props.deferUpdates: false` -- they otherwise commit on blur and a button
  press reads an empty value.
- `ia.input.numeric-entry-field` is the numeric input; `numeric-entry` does not exist.
- Any `ia.display.table` column needs the FULL ~25-key schema; `header` is an object,
  not a string.
- Expression bindings are C-style: `=` for equality, `!` / `&&` / `||`.

- [ ] **Step 3: Register the page**

```json
"/shop-floor/cutover-scan": {
  "title": "Inventory Cutover Scan",
  "viewPath": "BlueRidge/Views/ShopFloor/CutoverScan",
  "viewParams": {}
}
```

- [ ] **Step 4: Scan and verify all three sizes**

```bash
./scan.ps1
```

Open `/shop-floor/cutover-scan` and resize across 500 and 900. Expected: the layout
swaps at both boundaries, and **the session list survives the swap** -- that is the
check proving state is in `session.custom`, not per-view.

- [ ] **Step 5: Scan one basket and verify in SQL**

```bash
sqlcmd -S localhost -d MPP_MES_Dev -E -b -I -C -Q "SELECT LotName, EntryRouteSequence, CastDate, ToolCavityId, PieceCount FROM Lots.Lot WHERE LotName = 'TESTLTT-001';"
```

Expected: one row with non-NULL `EntryRouteSequence`, the cast date entered, and a
non-NULL `ToolCavityId`. Verify through SQL, not by reading the screen back -- the
in-app browser cannot reliably commit Perspective input bindings.

Clean up afterwards:

```bash
sqlcmd -S localhost -d MPP_MES_Dev -E -b -I -C -Q "DECLARE @L BIGINT=(SELECT Id FROM Lots.Lot WHERE LotName='TESTLTT-001'); DELETE FROM Lots.LotEventLog WHERE LotId=@L; DELETE FROM Lots.LotMovement WHERE LotId=@L; DELETE FROM Lots.LotStatusHistory WHERE LotId=@L; DELETE FROM Lots.LotGenealogyClosure WHERE AncestorLotId=@L OR DescendantLotId=@L; DELETE FROM Lots.Lot WHERE Id=@L;"
```

- [ ] **Step 6: Commit**

```bash
git add ignition/projects/MPP/com.inductiveautomation.perspective/views/BlueRidge/Views/ShopFloor/CutoverScan ignition/projects/MPP/com.inductiveautomation.perspective/views/BlueRidge/Views/ShopFloor/_CutoverScan ignition/projects/MPP/com.inductiveautomation.perspective/page-config/config.json
git commit -m "feat(ignition): cutover scan -- breakpoint host and three size views"
```

---

### Task 12: Pre-cutover verification script

**Files:**
- Create: `sql/scratch/2026-09-12_cutover_readiness_check.sql`

**Interfaces:**
- Consumes: nothing. Read-only.
- Produces: one result grid per check. An empty grid means ready.

> Spec section 10 as runnable SQL, to be run against **production** before each line is
> scanned. **Check 3 changed on 2026-09-12:** `Item.MaxLotSize` is now INFORMATIONAL, not
> a rejection -- an over-size basket creates successfully and `Lot_Create` returns a note
> in `Message`. So check 3 no longer finds a blocker; it finds parts whose configured cap
> is far below their real basket size, which will make every scan carry an advisory toast.
> Keep it, and label it as noise-reduction rather than a gate.

- [ ] **Step 1: Write the script**

```sql
-- =============================================
-- File:        sql/scratch/2026-09-12_cutover_readiness_check.sql
-- Purpose:     READ-ONLY pre-cutover checks for ONE line. Run against production
--              before that line is scanned. Every grid should come back EMPTY;
--              a row is a problem to fix before anyone scans a basket.
-- Usage:       Set @LineCode and @EntryRole, then run. No writes, no transaction.
-- =============================================
SET NOCOUNT ON;

DECLARE @LineCode  NVARCHAR(50) = N'MA1-5GOF';      -- <<< set per line
DECLARE @EntryRole NVARCHAR(30) = N'MachiningIn';   -- MachiningIn | AssemblyIn

DECLARE @Line BIGINT = (SELECT Id FROM Location.Location WHERE Code = @LineCode AND DeprecatedAt IS NULL);
IF @Line IS NULL BEGIN PRINT 'UNKNOWN LINE CODE -- stop.'; RETURN; END

PRINT '=== 1. Parts eligible here with NO entry step for the role ===';
SELECT DISTINCT i.Id, i.PartNumber, i.Description
FROM Parts.v_EffectiveItemLocation e
INNER JOIN Parts.Item i ON i.Id = e.ItemId
WHERE e.LocationId IN (SELECT LocationId FROM Location.ufn_AncestorLocationIds(@Line))
  AND NOT EXISTS (
      SELECT 1 FROM Parts.RouteTemplate rt
      INNER JOIN Parts.RouteStep rs         ON rs.RouteTemplateId = rt.Id
      INNER JOIN Parts.OperationTemplate ot ON ot.Id  = rs.OperationTemplateId
      INNER JOIN Parts.OperationType oty    ON oty.Id = ot.OperationTypeId
      WHERE rt.ItemId = i.Id AND rt.PublishedAt IS NOT NULL AND rt.DeprecatedAt IS NULL
        AND oty.Code = @EntryRole);

PRINT '=== 2. Castings eligible here with NO configured cavities ===';
SELECT DISTINCT i.Id, i.PartNumber
FROM Parts.v_EffectiveItemLocation e
INNER JOIN Parts.Item i      ON i.Id = e.ItemId
INNER JOIN Parts.ItemType it ON it.Id = i.ItemTypeId
WHERE e.LocationId IN (SELECT LocationId FROM Location.ufn_AncestorLocationIds(@Line))
  AND it.Code = N'Casting'
  AND NOT EXISTS (SELECT 1 FROM Tools.ToolCavity tc WHERE tc.ItemId = i.Id AND tc.DeprecatedAt IS NULL);

PRINT '=== 3. Parts whose MaxLotSize is below a real basket (advisory noise, not a blocker) ===';
SELECT DISTINCT i.Id, i.PartNumber, i.MaxLotSize
FROM Parts.v_EffectiveItemLocation e
INNER JOIN Parts.Item i ON i.Id = e.ItemId
WHERE e.LocationId IN (SELECT LocationId FROM Location.ufn_AncestorLocationIds(@Line))
  AND i.MaxLotSize IS NOT NULL AND i.MaxLotSize < 4000;

PRINT '=== 4. Stock destination configured for this line (expect ONE row) ===';
EXEC Location.Location_GetStockDestination @LineLocationId = @Line;

PRINT '=== 5. Parts with MORE THAN ONE die (operator must pick) ===';
SELECT i.PartNumber, COUNT(DISTINCT tc.ToolId) AS DieCount
FROM Tools.ToolCavity tc
INNER JOIN Parts.Item i ON i.Id = tc.ItemId
WHERE tc.DeprecatedAt IS NULL
GROUP BY i.PartNumber
HAVING COUNT(DISTINCT tc.ToolId) > 1;

PRINT '=== 6. SubAssembly LOTs where a Machining OUT terminal can see them ===';
SELECT l.Id, l.LotName, i.PartNumber, loc.Code AS AtLocation
FROM Lots.Lot l
INNER JOIN Parts.Item i          ON i.Id  = l.ItemId
INNER JOIN Parts.ItemType it     ON it.Id = i.ItemTypeId
INNER JOIN Location.Location loc ON loc.Id = l.CurrentLocationId
INNER JOIN Lots.LotStatusCode sc ON sc.Id = l.LotStatusId AND sc.Code <> N'Closed'
WHERE it.Code = N'SubAssembly'
  AND EXISTS (SELECT 1 FROM Lots.ufn_NextPendingRouteStep(l.Id) ns
              WHERE ns.OperationTypeCode = N'MachiningOut');
```

- [ ] **Step 2: Run it against Dev**

```bash
sqlcmd -S localhost -d MPP_MES_Dev -E -b -I -C -i sql/scratch/2026-09-12_cutover_readiness_check.sql
```

Expected: six labelled sections. Check 4 returns exactly one row (the destination).
Check 5 lists the one known multi-die part.

- [ ] **Step 3: Commit**

```bash
git add sql/scratch/2026-09-12_cutover_readiness_check.sql
git commit -m "chore(cutover): read-only per-line readiness check"
```

---

## Self-Review

**Spec coverage**

| Spec section | Task |
|---|---|
| §3.1 `EntryRouteSequence` | 4, 5 |
| §3.2 `CastDate` + FIFO expression | 4, 6 |
| §3.3 why not backdate `LotMovement` | documented in the 0080 header (Task 4) |
| §3.4 castings-only scope | Tasks 5, 13 (check 6) |
| §3.5 `DefaultStockLocationId` | 4, 8 |
| §4 Phase A extraction | 1, 2, 3 |
| §5.4 `Lot_Create` params | 5 |
| §5.5 three validations | 5 |
| §6.2 latched session context | 10 |
| §6.3 die resolution | 7, 10 |
| §6.4 per-basket loop, latching | 10 |
| §6.5 date stepper | 10 (`stepCastDate`) |
| §6.6 purchased flow | 11 |
| §6.7 session list + void | 10, 11 |
| §6.8 breakpoints | 12 |
| §8.1 regression set | 2 (baseline diff), 3, 5, 6 |
| §8.2 new coverage items 1–10 | 1, 5, 6, 7, 8 |
| §10 pre-cutover checklist | 13 |
| §11 wart — no code change | 13 (check 6 surfaces it) |

No gaps.

**Type consistency**

- `Lots.ufn_NextPendingRouteStep` returns `SequenceNumber` / `OperationTemplateId` / `OperationTypeCode` in Task 1 and is consumed by that exact column set in Tasks 2, 3, 5, 6, 13.
- `@EntryRouteSequence INT` (SQL) -> `entryRouteSequence` NQ `sqlType: 2` (INTEGER) -> `entryRouteSequence` Python key. Consistent.
- `@CastDate DATE` -> `castDate` NQ `sqlType: 91` (DATE) -> `castDate` Python key. Consistent.
- `Tools.Tool_ListForItem` -> `Id`/`Code`/`Name`, read as those keys in `loadSession`.
- `Tools.ToolCavity_ListForItemTool` -> `Id`/`CavityCode`/`Description`, read as those keys.
- `Location_GetStockDestination` -> `DestinationLocationId`/`DestinationCode`/`DestinationName` in Task 8, matched by `_EMPTY_STOCK_DEST` in Task 9 and read in Task 10.
- `sessionRows` entries carry `LotId`/`LotName`/`PartNumber`/`CavityCode`/`CastDate`/`PieceCount` in both `addBasket` (Task 10) and `addBox` (Task 11), and `voidEntry` filters on `LotId`.

**Placeholder scan:** none. Every code step carries the code; every command carries its expected output.
