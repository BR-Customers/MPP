# Machining IN Route-Driven Claim — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let a Machining IN operator see and claim a casting whose route skips the trim shop, by replacing the Trim-Storage *location* gate with the LOT's own route.

**Architecture:** Two repeatable stored procedures change. The queue read (`Lots.Lot_GetTrimStorageQueueForLine`) drops its trim-storage location predicate and tightens its status filter; the claim proc (`Workorder.MachiningIn_RecordPick`) replaces its location test with a `Lots.ufn_NextPendingRouteStep` lookup that supplies both the gate and the operation template. No schema migration, no Perspective view changes. One comment-only Python docstring fix.

**Tech Stack:** SQL Server 2022, T-SQL repeatable migrations (`CREATE OR ALTER`), the in-repo `test.*` T-SQL assertion framework, PowerShell test runner, Ignition 8.3 file-based project resources.

**Spec:** `docs/superpowers/specs/2026-09-15-machining-in-route-driven-claim-design.md`

## Global Constraints

- **Names do not change.** `Lots.Lot_GetTrimStorageQueueForLine`, the `lots/Lot_GetTrimStorageQueueForLine` NQ, and `BlueRidge.Lots.Lot.getTrimStorageQueueForLine` keep their current names at every layer (spec D6). Do not rename anything.
- **`@StorageLocationId` stays on both procs**, accepted and ignored, documented like `@DestinationCellLocationId` in `R__Workorder_TrimOut_Record.sql:60` (spec D7). Do not drop it — the NQ passes it and must stay byte-identical.
- **FDS-11-011:** no `OUTPUT` parameters. Read procs return one result set. Mutation procs end every exit path with `SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;`.
- **Msg-3915:** every rejecting validation runs **before** `BEGIN TRANSACTION`, each SELECTing its status row and `RETURN`ing with no open transaction. `CATCH` is the only `ROLLBACK` site.
- **`RAISERROR`, not `THROW`**, in CATCH blocks.
- **ASCII-only** in any string that reaches SQL seed/proc literals.
- **Timestamps** stored UTC, displayed ET via `AT TIME ZONE` at the read boundary. The existing `LastMovementAt` conversion in the read proc is correct — do not touch it.
- **Test database is `MPP_MES_Test`** (the throwaway). `Run-Tests.ps1` DROPs and rebuilds its target. Never point it at `MPP_MES_Dev`.
- **Git:** commit to the current branch (`jacques/working`). Stage explicit paths only — never `git add -u` or `git add -A`. No `Co-Authored-By: Claude` trailer.

---

## File Structure

| File | Responsibility | Task |
|---|---|---|
| `sql/tests/0027_PlantFloor_Machining/030_MachiningIn_NoTrimRoute.sql` | **New.** The regression test: a trim-skipping route, a LOT in `WHSE`, read-side then claim-side assertions. | 1, 2 |
| `sql/migrations/repeatable/R__Lots_Lot_GetTrimStorageQueueForLine.sql` | Queue read. Drop the location predicate, exclude `Open`. | 1 |
| `sql/migrations/repeatable/R__Workorder_MachiningIn_RecordPick.sql` | Claim proc. Route gate + template from one lookup. | 2 |
| `sql/tests/0027_PlantFloor_Machining/020_MachiningIn_RecordPick_guards.sql` | Guard 1 becomes a route guard; Guard 2 gains a pre-advance so it still reaches the terminal check. | 2 |
| `sql/tests/0024_PlantFloor_Movement_Trim/065_Lot_GetTrimStorageQueueForLine.sql` | Two test *labels* corrected — assertions unchanged. | 3 |
| `ignition/projects/Core/ignition/script-python/BlueRidge/Lots/Lot/code.py` | `getTrimStorageQueueForLine` docstring — currently asserts the LOT is "sitting in Trim Storage", which this change makes false. | 3 |

---

### Task 1: Queue read stops gating on location

**Files:**
- Create: `sql/tests/0027_PlantFloor_Machining/030_MachiningIn_NoTrimRoute.sql`
- Modify: `sql/migrations/repeatable/R__Lots_Lot_GetTrimStorageQueueForLine.sql`

**Interfaces:**
- Consumes: `Lots.ufn_NextPendingRouteStep(@LotId)` → `(SequenceNumber INT, OperationTemplateId BIGINT, OperationTypeCode NVARCHAR(20))`; `Parts.v_EffectiveItemLocation(ItemId, LocationId, Source, ParentItemId, BomId)`; `Location.ufn_AncestorLocationIds(@LocationId)` → `(LocationId BIGINT)`.
- Produces: `Lots.Lot_GetTrimStorageQueueForLine @LineLocationId BIGINT, @StorageLocationId BIGINT = NULL` — **unchanged signature and unchanged 11-column result shape**: `Id, LotName, ItemId, ItemPartNumber, ItemDescription, PieceCount, LotStatusId, LotStatusCode, LastMovementAt, NextOperationTypeCode, NextSequenceNumber`. Task 2's test file reuses the same fixture item `TSKIP-C` and LOT names `TSK-030-*`.

- [ ] **Step 1: Write the failing test**

Create `sql/tests/0027_PlantFloor_Machining/030_MachiningIn_NoTrimRoute.sql`.

The fixture is a **new** part `TSKIP-C` with a published v1 route `DieCast(1) → MachiningIn(2) → AssemblyOut(3)` — legal under `RouteTemplate_Publish`'s structural rules (OriginMint first, exactly one ConsumeMint and it is last). It is made eligible at line `MA1-5GOF` only, so `MA1-6MD` serves as the ineligible control. Three LOTs exercise the three status paths: `Good` in `WHSE` (claimable), `Open` at a press (must not appear), `Hold` in `WHSE` (appears, but refused at claim).

A brand-new part is used rather than a seeded one so this file cannot perturb any other test's fixture — every seeded route runs through trim, and changing one would ripple into `0024/060`, `0024/065`, `0027/010` and `0064/060`.

```sql
-- =============================================
-- File:         0027_PlantFloor_Machining/030_MachiningIn_NoTrimRoute.sql
-- Author:       Blue Ridge Automation
-- Created:      2026-09-15
-- Description:  Route-driven Machining IN claim (spec 2026-09-15). Some oil pans skip
--               the trim shop; their route runs DieCast -> MachiningIn -> AssemblyOut and
--               a released basket sits in WHSE, never in Trim Storage. Such a LOT MUST
--               surface in the Machining IN queue of an eligible line and MUST be
--               claimable from the warehouse.
--               Also guards the one hazard the old location gate was covering: an OPEN
--               die-cast basket (still being filled) must NOT appear in the queue, even
--               though DieCast is OriginMint and MachiningIn is therefore "next".
--               And pins visible-but-not-claimable: a HELD LOT stays IN the queue (the
--               screen's "On Hold" indicator counts it) but the claim still refuses it.
--               Fixture: new part TSKIP-C, published route DieCast->MachiningIn->
--               AssemblyOut, eligible at MA1-5GOF only (MA1-6MD = ineligible control);
--               three LOTs -- Good in WHSE, Open at a press, Hold in WHSE.
-- =============================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0027_PlantFloor_Machining/030_MachiningIn_NoTrimRoute.sql';
GO

-- ---- teardown from any previous run (closure BEFORE lots: FK) ----
DELETE pe FROM Workorder.ProductionEvent pe INNER JOIN Lots.Lot l ON l.Id = pe.LotId WHERE l.LotName LIKE N'TSK-030-%';
DELETE m  FROM Lots.LotMovement m        INNER JOIN Lots.Lot l ON l.Id = m.LotId  WHERE l.LotName LIKE N'TSK-030-%';
DELETE h  FROM Lots.LotStatusHistory h   INNER JOIN Lots.Lot l ON l.Id = h.LotId  WHERE l.LotName LIKE N'TSK-030-%';
DELETE eg FROM Lots.LotEventLog eg       INNER JOIN Lots.Lot l ON l.Id = eg.LotId WHERE l.LotName LIKE N'TSK-030-%';
DELETE c  FROM Lots.LotGenealogyClosure c INNER JOIN Lots.Lot l ON l.Id = c.AncestorLotId OR l.Id = c.DescendantLotId WHERE l.LotName LIKE N'TSK-030-%';
DELETE FROM Lots.Lot WHERE LotName LIKE N'TSK-030-%';
GO

-- ---- fixture: the trim-skipping part + its published route ----
DECLARE @Dev   BIGINT = (SELECT Id FROM Location.AppUser WHERE Initials = N'DEV');
DECLARE @TComp BIGINT = (SELECT Id FROM Parts.ItemType WHERE Code = N'Component');
DECLARE @EA    BIGINT = (SELECT Id FROM Parts.Uom WHERE Code = N'EA');

IF NOT EXISTS (SELECT 1 FROM Parts.Item WHERE PartNumber = N'TSKIP-C')
    INSERT INTO Parts.Item (ItemTypeId, PartNumber, Description, DefaultSubLotQty, MaxLotSize, UomId, CreatedAt, CreatedByUserId)
    VALUES (@TComp, N'TSKIP-C', N'Trim-skipping oil pan casting (test fixture)', 12, 24, @EA, SYSUTCDATETIME(), @Dev);

DECLARE @Item BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'TSKIP-C');
DECLARE @Line BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MA1-5GOF');

-- eligible at MA1-5GOF only
IF NOT EXISTS (SELECT 1 FROM Parts.ItemLocation WHERE ItemId = @Item AND LocationId = @Line AND DeprecatedAt IS NULL)
    INSERT INTO Parts.ItemLocation (ItemId, LocationId, IsConsumptionPoint, CreatedAt)
    VALUES (@Item, @Line, 0, SYSUTCDATETIME());

-- published v1 route: DieCast -> MachiningIn -> AssemblyOut (no trim steps)
IF NOT EXISTS (SELECT 1 FROM Parts.RouteTemplate WHERE ItemId = @Item AND VersionNumber = 1)
    INSERT INTO Parts.RouteTemplate (ItemId, VersionNumber, Name, EffectiveFrom, PublishedAt, DeprecatedAt, CreatedByUserId, CreatedAt)
    VALUES (@Item, 1, N'TSKIP-C Cast->Machine Route v1', '2026-01-15', '2026-01-14', NULL, @Dev, SYSUTCDATETIME());

DECLARE @Rt BIGINT = (SELECT Id FROM Parts.RouteTemplate WHERE ItemId = @Item AND VersionNumber = 1);

DECLARE @Steps TABLE (Seq INT, Role NVARCHAR(30), Descr NVARCHAR(120));
INSERT INTO @Steps (Seq, Role, Descr) VALUES
 (1, N'DieCast',     N'Die cast'),
 (2, N'MachiningIn', N'Machining in'),
 (3, N'AssemblyOut', N'Assembly out (mints the finished good)');

INSERT INTO Parts.RouteStep (RouteTemplateId, OperationTemplateId, SequenceNumber, IsRequired, Description)
SELECT @Rt, op.Id, s.Seq, 1, s.Descr
FROM @Steps s
CROSS APPLY (
    SELECT TOP 1 o.Id FROM Parts.OperationTemplate o
    JOIN Parts.OperationType oty ON oty.Id = o.OperationTypeId
    WHERE oty.Code = s.Role AND o.DeprecatedAt IS NULL ORDER BY o.Id
) op
WHERE NOT EXISTS (SELECT 1 FROM Parts.RouteStep x WHERE x.RouteTemplateId = @Rt AND x.SequenceNumber = s.Seq);
GO

-- ---- fixture: the LOTs ----
DECLARE @Item   BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'TSKIP-C');
DECLARE @Whse   BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'WHSE');
DECLARE @Press  BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'DC1-M05');
DECLARE @Origin BIGINT = (SELECT Id FROM Lots.LotOriginType WHERE Code = N'Manufactured');
DECLARE @Good   BIGINT = (SELECT Id FROM Lots.LotStatusCode WHERE Code = N'Good');
DECLARE @Open   BIGINT = (SELECT Id FROM Lots.LotStatusCode WHERE Code = N'Open');
DECLARE @Hold   BIGINT = (SELECT Id FROM Lots.LotStatusCode WHERE Code = N'Hold');   -- BlocksProduction = 1

-- A: a released basket in the WAREHOUSE. Next pending step is MachiningIn because
-- DieCast is OriginMint (never pending) and there are no trim steps at all.
INSERT INTO Lots.Lot (LotName, ItemId, LotOriginTypeId, LotStatusId, PieceCount, InventoryAvailable, CurrentLocationId, CreatedByUserId, CreatedAt)
VALUES (N'TSK-030-A', @Item, @Origin, @Good, 24, 24, @Whse, 1, SYSUTCDATETIME());
DECLARE @LotA BIGINT = SCOPE_IDENTITY();
INSERT INTO Lots.LotGenealogyClosure (AncestorLotId, DescendantLotId, Depth) VALUES (@LotA, @LotA, 0);
INSERT INTO Lots.LotMovement (LotId, FromLocationId, ToLocationId, MovedByUserId, MovedAt) VALUES (@LotA, NULL, @Whse, 1, SYSUTCDATETIME());

-- B: an OPEN basket still being filled at the press. Same route, so its next pending
-- step is ALSO MachiningIn -- only the status keeps it out of the queue.
INSERT INTO Lots.Lot (LotName, ItemId, LotOriginTypeId, LotStatusId, PieceCount, InventoryAvailable, CurrentLocationId, CreatedByUserId, CreatedAt)
VALUES (N'TSK-030-OPEN', @Item, @Origin, @Open, 6, 6, @Press, 1, SYSUTCDATETIME());
DECLARE @LotO BIGINT = SCOPE_IDENTITY();
INSERT INTO Lots.LotGenealogyClosure (AncestorLotId, DescendantLotId, Depth) VALUES (@LotO, @LotO, 0);
INSERT INTO Lots.LotMovement (LotId, FromLocationId, ToLocationId, MovedByUserId, MovedAt) VALUES (@LotO, NULL, @Press, 1, SYSUTCDATETIME());

-- C: a HELD basket in the warehouse. BlocksProduction = 1, so the claim will refuse it --
-- but it MUST stay VISIBLE in the queue, because the Machining IN screen counts every row
-- whose status is not 'Good' into its "On Hold" indicator. Visible-but-not-claimable is
-- deliberate (spec D5); dropping it would silently blank that indicator.
INSERT INTO Lots.Lot (LotName, ItemId, LotOriginTypeId, LotStatusId, PieceCount, InventoryAvailable, CurrentLocationId, CreatedByUserId, CreatedAt)
VALUES (N'TSK-030-HOLD', @Item, @Origin, @Hold, 18, 18, @Whse, 1, SYSUTCDATETIME());
DECLARE @LotH BIGINT = SCOPE_IDENTITY();
INSERT INTO Lots.LotGenealogyClosure (AncestorLotId, DescendantLotId, Depth) VALUES (@LotH, @LotH, 0);
INSERT INTO Lots.LotMovement (LotId, FromLocationId, ToLocationId, MovedByUserId, MovedAt) VALUES (@LotH, NULL, @Whse, 1, SYSUTCDATETIME());
GO

-- ---- assertions: the READ ----
DECLARE @LotA  BIGINT = (SELECT Id FROM Lots.Lot WHERE LotName = N'TSK-030-A');
DECLARE @LotO  BIGINT = (SELECT Id FROM Lots.Lot WHERE LotName = N'TSK-030-OPEN');
DECLARE @LotH  BIGINT = (SELECT Id FROM Lots.Lot WHERE LotName = N'TSK-030-HOLD');
DECLARE @Line  BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MA1-5GOF');
DECLARE @LineX BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MA1-6MD');   -- TSKIP-C NOT eligible here

DECLARE @Q TABLE (Id BIGINT, LotName NVARCHAR(50), ItemId BIGINT, ItemPartNumber NVARCHAR(50), ItemDescription NVARCHAR(500),
    PieceCount INT, LotStatusId BIGINT, LotStatusCode NVARCHAR(20), LastMovementAt DATETIME2(3), NextOperationTypeCode NVARCHAR(20), NextSequenceNumber INT);

-- A1: the warehouse LOT is visible at the eligible line (this is the bug being fixed)
DELETE FROM @Q; INSERT INTO @Q EXEC Lots.Lot_GetTrimStorageQueueForLine @LineLocationId = @Line;
DECLARE @a1 NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM @Q WHERE Id = @LotA);
EXEC test.Assert_IsEqual @TestName = N'[NoTrim] trim-skipping LOT in WHSE is visible at the eligible line', @Expected = N'1', @Actual = @a1;

-- A2: its next step really is MachiningIn (proves the route, not an accident of the join)
DECLARE @a2 NVARCHAR(20) = (SELECT TOP 1 ISNULL(NextOperationTypeCode, N'(none)') FROM @Q WHERE Id = @LotA);
EXEC test.Assert_IsEqual @TestName = N'[NoTrim] queue row reports MachiningIn as the next step', @Expected = N'MachiningIn', @Actual = @a2;

-- A3: the OPEN basket is NOT in the queue (the hazard the location gate used to cover)
DECLARE @a3 NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM @Q WHERE Id = @LotO);
EXEC test.Assert_IsEqual @TestName = N'[NoTrim] an OPEN die-cast basket is NOT in the Machining IN queue', @Expected = N'0', @Actual = @a3;

-- A4: a HELD LOT stays VISIBLE (spec D5 -- the screen's "On Hold" indicator depends on it)
DECLARE @a4 NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM @Q WHERE Id = @LotH);
EXEC test.Assert_IsEqual @TestName = N'[NoTrim] a HELD LOT is still visible in the queue', @Expected = N'1', @Actual = @a4;

-- A5: eligibility still gates -- absent at a line where the part is not eligible
DELETE FROM @Q; INSERT INTO @Q EXEC Lots.Lot_GetTrimStorageQueueForLine @LineLocationId = @LineX;
DECLARE @a5 NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM @Q WHERE Id = @LotA);
EXEC test.Assert_IsEqual @TestName = N'[NoTrim] LOT NOT visible at an ineligible line', @Expected = N'0', @Actual = @a5;
GO

-- ---- cleanup (closure BEFORE lots) ----
DELETE pe FROM Workorder.ProductionEvent pe INNER JOIN Lots.Lot l ON l.Id = pe.LotId WHERE l.LotName LIKE N'TSK-030-%';
DELETE m  FROM Lots.LotMovement m        INNER JOIN Lots.Lot l ON l.Id = m.LotId  WHERE l.LotName LIKE N'TSK-030-%';
DELETE h  FROM Lots.LotStatusHistory h   INNER JOIN Lots.Lot l ON l.Id = h.LotId  WHERE l.LotName LIKE N'TSK-030-%';
DELETE eg FROM Lots.LotEventLog eg       INNER JOIN Lots.Lot l ON l.Id = eg.LotId WHERE l.LotName LIKE N'TSK-030-%';
DELETE c  FROM Lots.LotGenealogyClosure c INNER JOIN Lots.Lot l ON l.Id = c.AncestorLotId OR l.Id = c.DescendantLotId WHERE l.LotName LIKE N'TSK-030-%';
DELETE FROM Lots.Lot WHERE LotName LIKE N'TSK-030-%';
GO

EXEC test.EndTestFile;
GO
```

Cleanup removes the LOTs but deliberately leaves the `TSKIP-C` item, its route and its `ItemLocation` row behind — the same thing `020` and `065` do with their `ItemLocation` inserts. `Run-Tests.ps1` drops and rebuilds the database each run, so nothing accumulates, and with no `TSK-030-%` LOTs left the leftover part cannot appear in any other file's queue read. Do not add teardown for them: deleting a `RouteTemplate` means unpicking `RouteStep` first, and it buys nothing.

- [ ] **Step 2: Run the test to verify it fails**

```bash
cd sql/tests && powershell -File ./Run-Tests.ps1 -Filter "NoTrimRoute"
```

Expected: **3 failures** — `[NoTrim] trim-skipping LOT in WHSE is visible at the eligible line` (expected `1`, actual `0`), `[NoTrim] queue row reports MachiningIn as the next step` (expected `MachiningIn`, actual `(none)`), and `[NoTrim] a HELD LOT is still visible in the queue` (expected `1`, actual `0`). All three are the same root cause: the LOTs sit in `WHSE`, which the location gate excludes.

The other two pass already. `[NoTrim] LOT NOT visible at an ineligible line` is a genuine pass. `[NoTrim] an OPEN die-cast basket is NOT in the Machining IN queue` passes **vacuously** for now — the basket is at a press, which the location gate rejects anyway — and only becomes meaningful after Step 3 removes that gate. That is expected; do not treat its green as coverage yet.

- [ ] **Step 3: Change the read proc**

In `sql/migrations/repeatable/R__Lots_Lot_GetTrimStorageQueueForLine.sql`, **delete the entire `TrimStores` CTE** and replace the `Eligible` CTE. Replace this block:

```sql
    ;WITH TrimStores AS (
        SELECT s.Id
        FROM Location.Location s
        WHERE s.DeprecatedAt IS NULL
          AND ( (@StorageLocationId IS NOT NULL AND s.Id = @StorageLocationId)
                OR (@StorageLocationId IS NULL
                    AND s.LocationTypeDefinitionId = 14   -- InventoryLocation
                    AND EXISTS (SELECT 1 FROM Location.Location a
                                WHERE a.Id = s.ParentLocationId AND a.Code LIKE N'TRIM%')) )
    ),
    LineAncestors AS (
```

with:

```sql
    ;WITH LineAncestors AS (
```

then replace the `Eligible` CTE:

```sql
    -- Open LOTs in a trim store. Status + location filtering stays HERE (this
    -- proc excludes only Closed); the shared pending-step function filters neither.
    Eligible AS (
        SELECT l.Id AS LotId
        FROM Lots.Lot l
        INNER JOIN Lots.LotStatusCode sc ON sc.Id = l.LotStatusId AND sc.Code <> N'Closed'
        WHERE l.CurrentLocationId IN (SELECT Id FROM TrimStores)
    )
```

with:

```sql
    -- Candidate LOTs, ANYWHERE. v2.0 (2026-09-15): location is no longer a gate --
    -- see the header. Status filtering stays HERE (the shared pending-step function
    -- filters neither status nor location):
    --   Closed -> finished, nothing pending.
    --   Open   -> a die-cast basket still being FILLED. It must not be claimable, and
    --             without this it WOULD surface on a trim-skipping route (DieCast is
    --             OriginMint, so MachiningIn is already "next" while the basket fills).
    --             Mirrors Lot_GetWipQueueByLocation, which excludes both.
    -- Held/blocked LOTs are deliberately NOT excluded: the Machining IN screen shows
    -- them and counts them in its "On Hold" indicator. MachiningIn_RecordPick refuses
    -- the claim, which is the intended visible-but-not-claimable behaviour.
    Eligible AS (
        SELECT l.Id AS LotId
        FROM Lots.Lot l
        INNER JOIN Lots.LotStatusCode sc ON sc.Id = l.LotStatusId
                                        AND sc.Code NOT IN (N'Closed', N'Open')
    )
```

Then replace the whole header comment block (everything from `-- Description:` down to the line before `-- ====` that closes it) with:

```sql
-- Description: THE Machining IN queue read for ONE machining line.
--
--              *** THE NAME IS HISTORIC. This proc no longer looks at Trim Storage. ***
--              It was written for the Trim-Storage model (2026-07-23), when every part
--              went through a trim shop and "claimable stock" and "stock in Trim Storage"
--              were the same set. Some oil pans skip trim entirely; their route is
--              DieCast -> MachiningIn -> AssemblyOut and a released basket sits in WHSE.
--              The name is kept only because renaming it would force an edit to the
--              MachiningIn view's binding expression (a Designer change). See spec
--              2026-09-15-machining-in-route-driven-claim-design.md section 5.
--
--              v2.0 (2026-09-15): THE ROUTE IS THE GATE. Returns the LOTs -- wherever
--              they physically sit -- whose next PENDING route step is MachiningIn and
--              whose Item is ELIGIBLE at @LineLocationId (ancestor cascade). Trim Storage
--              is now just one of several places such a LOT may be; WHSE is another.
--
--              A part eligible at two lines appears in both lines' reads. Claiming it
--              (Workorder.MachiningIn_RecordPick) writes the MachiningIn ProductionEvent,
--              which SATISFIES that Advance step -- so the LOT drops off every line's
--              read by route, not by having been moved out of a storage location.
--
--              @StorageLocationId is ACCEPTED AND IGNORED (v2.0). It restricted the read
--              to one shop's trim store under the old model and is meaningless now; it
--              is retained so the named query's signature stays byte-identical. Compare
--              @DestinationCellLocationId on Workorder.TrimOut_Record.
--
--              Same column shape as Lots.Lot_GetWipQueueByLocation so the view row
--              transform is unchanged. Read proc: no OUTPUT params, single result set,
--              empty set = nothing to show (FDS-11-011). Pending logic lives in
--              Lots.ufn_NextPendingRouteStep (Advance pending until a matching
--              ProductionEvent; ConsumeMint always pending while open; OriginMint never
--              pending). FIFO by CastDate then arrival.
```

Leave `LineAncestors`, `LastMove`, the final `SELECT`, the `oty.Code = N'MachiningIn'` filter, the `Parts.v_EffectiveItemLocation` eligibility `EXISTS`, and the `ORDER BY` **exactly as they are**. Also bump `-- Version:` from `1.0` to `2.0`.

- [ ] **Step 4: Run the test to verify it passes**

```bash
cd sql/tests && powershell -File ./Run-Tests.ps1 -Filter "NoTrimRoute"
```

Expected: **PASS**, 5 assertions, 0 failures.

- [ ] **Step 5: Run the neighbouring read tests to prove nothing regressed**

```bash
cd sql/tests && powershell -File ./Run-Tests.ps1 -Filter "Queue"
```

Expected: **PASS**. `0024/060_Lot_GetWipQueueByLocation.sql` and `0024/065_Lot_GetTrimStorageQueueForLine.sql` both go green with no edits — `065`'s five assertions still hold because its fixture is pre-advanced past `DieCast`/`TrimIn`/`TrimOut`, so the route, not the location, was already carrying them.

- [ ] **Step 6: Commit**

```bash
git add sql/migrations/repeatable/R__Lots_Lot_GetTrimStorageQueueForLine.sql sql/tests/0027_PlantFloor_Machining/030_MachiningIn_NoTrimRoute.sql
git commit -F - <<'EOF'
fix(machining): the Machining IN queue stops gating on Trim Storage

An oil pan whose route skips the trim shop lands in WHSE and was invisible
to every machining line, because the queue selected only LOTs sitting in an
InventoryLocation under a TRIM* area. The route already knew the answer.

Also excludes Open, which the location gate was covering for free: on a
trim-skipping route DieCast is OriginMint, so MachiningIn is "next" while
the basket is still being filled.
EOF
```

---

### Task 2: The claim proc gates on the route, not the location

**Files:**
- Modify: `sql/migrations/repeatable/R__Workorder_MachiningIn_RecordPick.sql:131-180` (steps 3 and 4)
- Modify: `sql/tests/0027_PlantFloor_Machining/020_MachiningIn_RecordPick_guards.sql`
- Modify: `sql/tests/0027_PlantFloor_Machining/030_MachiningIn_NoTrimRoute.sql` (extend with claim assertions)

**Interfaces:**
- Consumes: `Lots.Lot_GetTrimStorageQueueForLine` as changed in Task 1; `Lots.ufn_NextPendingRouteStep(@LotId)` → `(SequenceNumber, OperationTemplateId, OperationTypeCode)`.
- Produces: `Workorder.MachiningIn_RecordPick @LotId, @LineLocationId, @AppUserId, @TerminalLocationId, @StorageLocationId = NULL` — **unchanged signature**, unchanged `(Status BIT, Message NVARCHAR(500), NewId BIGINT)` result shape, `NewId` = the new `Workorder.ProductionEvent.Id`. New rejection message shapes: `'...has no active published route step pending.'` and `'...is not ready for Machining IN; its next operation is <Role>.'`

- [ ] **Step 1: Write the failing tests**

**(a)** In `030_MachiningIn_NoTrimRoute.sql`, insert a claim-assertion batch **immediately before** the `-- ---- cleanup` block:

```sql
-- ---- assertions: the CLAIM ----
DECLARE @LotA2 BIGINT = (SELECT Id FROM Lots.Lot WHERE LotName = N'TSK-030-A');
DECLARE @Line2 BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MA1-5GOF');
DECLARE @Term2 BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MA1-5GOF-MIN');
DECLARE @Whse2 BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'WHSE');

CREATE TABLE #RC (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #RC EXEC Workorder.MachiningIn_RecordPick
    @LotId = @LotA2, @LineLocationId = @Line2, @AppUserId = 1, @TerminalLocationId = @Term2;
DECLARE @cS NVARCHAR(10), @cM NVARCHAR(500);
SELECT @cS = CAST(Status AS NVARCHAR(10)), @cM = Message FROM #RC; DROP TABLE #RC;

-- B1: the claim succeeds straight out of the warehouse
EXEC test.Assert_IsEqual @TestName = N'[NoTrim] claim succeeds from WHSE (never touched Trim Storage)', @Expected = N'1', @Actual = @cS;

-- B2: the LOT moved warehouse -> line
DECLARE @b2 NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM Lots.LotMovement
                            WHERE LotId = @LotA2 AND FromLocationId = @Whse2 AND ToLocationId = @Line2);
EXEC test.Assert_IsEqual @TestName = N'[NoTrim] movement row records WHSE -> line', @Expected = N'1', @Actual = @b2;

-- B3: exactly one MachiningIn checkpoint on the SAME LOT, stamped to the terminal
DECLARE @b3 NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM Workorder.ProductionEvent pe
    INNER JOIN Parts.OperationTemplate ot ON ot.Id = pe.OperationTemplateId
    INNER JOIN Parts.OperationType oty    ON oty.Id = ot.OperationTypeId
    WHERE pe.LotId = @LotA2 AND oty.Code = N'MachiningIn' AND pe.TerminalLocationId = @Term2);
EXEC test.Assert_IsEqual @TestName = N'[NoTrim] one MachiningIn checkpoint on the same LOT', @Expected = N'1', @Actual = @b3;

-- B4: the claim is what removes it from the queue -- by route, not by location
DECLARE @Q2 TABLE (Id BIGINT, LotName NVARCHAR(50), ItemId BIGINT, ItemPartNumber NVARCHAR(50), ItemDescription NVARCHAR(500),
    PieceCount INT, LotStatusId BIGINT, LotStatusCode NVARCHAR(20), LastMovementAt DATETIME2(3), NextOperationTypeCode NVARCHAR(20), NextSequenceNumber INT);
INSERT INTO @Q2 EXEC Lots.Lot_GetTrimStorageQueueForLine @LineLocationId = @Line2;
DECLARE @b4 NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM @Q2 WHERE Id = @LotA2);
EXEC test.Assert_IsEqual @TestName = N'[NoTrim] after the claim the LOT is gone from the queue', @Expected = N'0', @Actual = @b4;

-- B5: the other half of visible-but-not-claimable (spec D5). The HELD LOT is in that
-- same queue (asserted in A4), but the claim must still refuse it -- for the HOLD, not
-- for its location, and not for its route.
DECLARE @LotH2 BIGINT = (SELECT Id FROM Lots.Lot WHERE LotName = N'TSK-030-HOLD');
CREATE TABLE #RH (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #RH EXEC Workorder.MachiningIn_RecordPick
    @LotId = @LotH2, @LineLocationId = @Line2, @AppUserId = 1, @TerminalLocationId = @Term2;
DECLARE @hS BIT, @hM NVARCHAR(500);
SELECT @hS = Status, @hM = Message FROM #RH; DROP TABLE #RH;
DECLARE @hSc BIT = CASE WHEN @hS = 0 THEN 1 ELSE 0 END;
EXEC test.Assert_IsTrue @TestName = N'[NoTrim] a HELD LOT in the queue is still refused at claim', @Condition = @hSc;
EXEC test.Assert_Contains @TestName = N'[NoTrim] the hold rejection cites the hold, not the route', @HaystackStr = @hM, @NeedleStr = N'release the hold first';
GO
```

**(b)** In `020_MachiningIn_RecordPick_guards.sql`, rewrite **Guard 1** so it proves the *route* rejects even when the LOT **is** in Trim Storage. Replace:

```sql
UPDATE Lots.Lot SET CurrentLocationId = @OffLoc WHERE Id = @Lot1;   -- not in Trim Storage
```

with:

```sql
-- Deliberately IN Trim Storage: under the route-driven model (2026-09-15) sitting in
-- the right place is not enough. This LOT has no ProductionEvents, so its next pending
-- route step is TrimIn -- and that, not its location, is what rejects the claim.
UPDATE Lots.Lot SET CurrentLocationId = @Store WHERE Id = @Lot1;
```

and replace Guard 1's two assertions:

```sql
EXEC test.Assert_IsTrue @TestName = N'[MachInGuard] LOT not in Trim Storage is rejected', @Condition = @S1c;
EXEC test.Assert_Contains @TestName = N'[MachInGuard] rejection cites not in Trim Storage', @HaystackStr = @M1, @NeedleStr = N'not in Trim Storage';
```

with:

```sql
EXEC test.Assert_IsTrue @TestName = N'[MachInGuard] LOT whose next route step is not MachiningIn is rejected', @Condition = @S1c;
EXEC test.Assert_Contains @TestName = N'[MachInGuard] rejection names the actual next operation', @HaystackStr = @M1, @NeedleStr = N'next operation is TrimIn';
```

**(c)** Still in `020`, **Guard 2 must be pre-advanced or it will stop testing what it claims to test.** `P5T-GUARD-B` is created with no `ProductionEvent`s, so the new route gate rejects it for the route *before* execution ever reaches step 5's terminal check. Insert this immediately after Guard 2's `UPDATE ... SET CurrentLocationId = @Store WHERE Id = @Lot2;` line:

```sql
-- Pre-advance past DieCast/TrimIn/TrimOut so the next pending step really is
-- MachiningIn. Without this the route gate (step 3) rejects first and this guard
-- would pass for the wrong reason, never reaching the terminal check it exists to test.
INSERT INTO Workorder.ProductionEvent (LotId, OperationTemplateId, EventAt, ShotCount, AppUserId)
SELECT @Lot2, rs.OperationTemplateId, SYSUTCDATETIME(), 20, 1
FROM Parts.RouteTemplate rt
JOIN Parts.RouteStep rs          ON rs.RouteTemplateId = rt.Id
JOIN Parts.OperationTemplate ot  ON ot.Id = rs.OperationTemplateId
JOIN Parts.OperationType oty     ON oty.Id = ot.OperationTypeId
WHERE rt.ItemId = @Item AND rt.PublishedAt IS NOT NULL AND rt.DeprecatedAt IS NULL
  AND oty.Code IN (N'DieCast', N'TrimIn', N'TrimOut');
```

Guard 3 (Closed LOT) needs no change — step 2's status guard still fires before the route gate.

Finally update the file's header block to describe the new Guard 1:

```sql
-- Rewritten:    2026-09-15 - route-driven claim. Rejection guards:
--                 - LOT whose next pending route step is not MachiningIn -> reject,
--                   EVEN WHEN IT IS SITTING IN TRIM STORAGE (location is no longer a gate)
--                 - terminal not part of the line -> reject (fixture pre-advanced to
--                   MachiningIn-pending so this guard reaches the terminal check)
--                 - Closed LOT -> reject (status guard precedes the route gate)
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
cd sql/tests && powershell -File ./Run-Tests.ps1 -Filter "MachiningIn"
```

Expected: **FAIL**. In `030`, `[NoTrim] claim succeeds from WHSE...` fails (expected `1`, actual `0`) and B2/B3/B4 fail with it. In `020`, `[MachInGuard] rejection names the actual next operation` fails — the message is still the old `not in Trim Storage` text.

The two B5 hold assertions pass both before and after, and that is the point of them: step 2's not-blocked guard already runs ahead of the location test, so a held LOT is refused for the **hold**. They are a pure regression guard — the `Assert_Contains` on `release the hold first` is what proves the new route gate did not get inserted ahead of the status guard and start rejecting held LOTs for the wrong reason.

- [ ] **Step 3: Change the claim proc**

In `sql/migrations/repeatable/R__Workorder_MachiningIn_RecordPick.sql`, add `@NextRole` to the declarations block. Replace:

```sql
    DECLARE @MachiningInOtId BIGINT;   -- resolved route-aware once the LOT's item is known (step 3)
```

with:

```sql
    DECLARE @MachiningInOtId BIGINT;   -- the pending step's template (step 3)
    DECLARE @NextRole        NVARCHAR(20);   -- the pending step's OperationType role (step 3)
```

Then replace **the whole of step 3 and the whole of step 4** — from the comment `-- ---- 3. Resolve the MachiningIn OperationTemplate off THIS LOT's route.` through the closing `END` of the `IF NOT EXISTS (SELECT 1 FROM Location.Location s ...)` trim-storage block — with:

```sql
        -- ---- 3. Resolve the LOT's NEXT PENDING ROUTE STEP. This one lookup is BOTH
        -- the gate and the template source (spec 2026-09-15 section 3.4): the step must
        -- carry the MachiningIn role, and that same row's OperationTemplateId is what the
        -- checkpoint is written against -- so the gate and the template cannot disagree.
        --
        -- This REPLACES the old Trim-Storage location test. The LOT may sit anywhere:
        -- a trim store, or WHSE for a casting whose route skips the trim shop entirely.
        -- It also replaces the old inline route query, which accepted a DRAFT route
        -- (DeprecatedAt IS NULL only) and ignored EntryRouteSequence; the shared function
        -- requires PublishedAt and honours the entry point, so what the operator sees in
        -- Lots.Lot_GetTrimStorageQueueForLine is exactly what this proc accepts.
        --
        -- "Already claimed by another line" needs NO separate test: MachiningIn is an
        -- Advance role, satisfied by the very ProductionEvent this proc writes below, so
        -- a claimed LOT's next pending step is no longer MachiningIn. The narrow
        -- concurrent window is caught by the conditional UPDATE in the transaction. ----
        SELECT @MachiningInOtId = ns.OperationTemplateId,
               @NextRole        = ns.OperationTypeCode
        FROM Lots.ufn_NextPendingRouteStep(@LotId) ns;

        IF @NextRole IS NULL
        BEGIN
            SET @Message = N'LOT ' + @LotName
                         + N' has no active published route step pending; check the part''s route.';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'Lot',
                @EntityId = @LotId, @LogEventTypeCode = N'MachiningInPicked',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
            RETURN;
        END

        IF @NextRole <> N'MachiningIn'
        BEGIN
            SET @Message = N'LOT ' + @LotName + N' is not ready for Machining IN; its next operation is '
                         + @NextRole + N'.';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'Lot',
                @EntityId = @LotId, @LogEventTypeCode = N'MachiningInPicked',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
            RETURN;
        END
```

Update the `@StorageLocationId` parameter comment. Replace:

```sql
    @StorageLocationId  BIGINT = NULL   -- v2 (2026-07-23): Trim Storage to claim FROM; NULL => any trim store
```

with:

```sql
    @StorageLocationId  BIGINT = NULL   -- v3 (2026-09-15): ACCEPTED AND IGNORED. The route
                                        -- decides what is claimable, not a storage location.
                                        -- Retained so callers' signatures stay unchanged;
                                        -- cf. TrimOut_Record.@DestinationCellLocationId.
```

Then replace the header's stale `Description:` paragraph — specifically the sentence that still refers to `HasLineEvent`:

```sql
--              The event's TerminalLocationId is REQUIRED and must sit at/under the
--              LINE: this is what Lots.Lot_GetWipQueueByLocation.HasLineEvent keys
--              on, so after this pick the LOT flips to HasLineEvent=1 at the line
--              and leaves the "unworked arrivals" queue (becomes the in-process LOT).
```

with:

```sql
--              v3.0 (2026-09-15): THE ROUTE IS THE GATE. The old "LOT must sit in Trim
--              Storage" test is gone -- it stranded castings whose route skips the trim
--              shop (released to WHSE, reachable by no line). A LOT is claimable when its
--              next PENDING route step carries the MachiningIn role; step 3 gets both
--              that gate and the OperationTemplate from one ufn_NextPendingRouteStep call.
--
--              The event's TerminalLocationId is REQUIRED and must sit at/under the LINE
--              so the checkpoint is attributable to it. Writing that checkpoint SATISFIES
--              the MachiningIn Advance step, which is what removes the LOT from every
--              line's Lots.Lot_GetTrimStorageQueueForLine read.
```

Bump `-- Version:` to `3.0` with a one-line summary in the same style as the existing `1.1` note. Leave step 2, step 2b (CRT), step 4b (eligibility), step 5 (terminal), the transaction body, the conditional `UPDATE` + `@@ROWCOUNT` race branch, the audit block, and the `CATCH` **exactly as they are**.

- [ ] **Step 4: Run the tests to verify they pass**

```bash
cd sql/tests && powershell -File ./Run-Tests.ps1 -Filter "MachiningIn"
```

Expected: **PASS** — `030` all 11 assertions (5 read + 6 claim), `020` all 6, `010` all unchanged assertions green.

- [ ] **Step 5: Run the full suite**

```bash
cd sql/tests && powershell -File ./Run-Tests.ps1
```

Expected: **0 failures**. Pay attention to `0027/090_Rework_LOT_in_queue.sql` and `0064_Crt_PartScoped/060_enforcement.sql` — both call `MachiningIn_RecordPick` and both already pre-advance their fixtures to MachiningIn-pending, so both should pass untouched. If either fails on a route message, it needs the same pre-advance treatment as Guard 2, not a proc change.

> Exit code 1 with **0 reported failures** means a test's `sqlcmd` errored rather than an assertion failing — usually cleanup FK ordering. Delete `Lots.LotGenealogyClosure` rows before their LOTs.

- [ ] **Step 6: Commit**

```bash
git add sql/migrations/repeatable/R__Workorder_MachiningIn_RecordPick.sql sql/tests/0027_PlantFloor_Machining/020_MachiningIn_RecordPick_guards.sql sql/tests/0027_PlantFloor_Machining/030_MachiningIn_NoTrimRoute.sql
git commit -F - <<'EOF'
fix(machining): claim a LOT by its route, not by where it is parked

MachiningIn_RecordPick required the LOT to be sitting in Trim Storage, so
a casting on a trim-skipping route could never be claimed even when the
queue showed it. The gate is now the LOT's next pending route step.

Steps 3 and 4 collapse into one ufn_NextPendingRouteStep call, so the gate
and the resolved OperationTemplate come from one definition. That also
drops the old inline query's two quirks: it accepted a Draft route and
ignored EntryRouteSequence.

Guard 2 in the test gains a pre-advance -- without it the route gate now
rejects first and the guard would never reach the terminal check.
EOF
```

---

### Task 3: Make the stale name safe to read

**Files:**
- Modify: `sql/tests/0024_PlantFloor_Movement_Trim/065_Lot_GetTrimStorageQueueForLine.sql` (two labels + header)
- Modify: `ignition/projects/Core/ignition/script-python/BlueRidge/Lots/Lot/code.py:443-457`

The procs now behave differently from what their names say. Spec section 5 makes the documentation a required part of the change, not a nicety — the Python docstring in particular currently asserts something that is now false.

**Interfaces:**
- Consumes: `Lots.Lot_GetTrimStorageQueueForLine` as changed in Task 1.
- Produces: no signature changes. `BlueRidge.Lots.Lot.getTrimStorageQueueForLine(lineLocationId, _refreshToken=None, storageLocationId=None)` keeps its exact name and parameters — the MachiningIn view's binding expression names it and must keep resolving.

- [ ] **Step 1: Correct the two misleading test labels**

In `065_Lot_GetTrimStorageQueueForLine.sql`, the assertions all still pass — only their stated *reasons* are now wrong. Replace:

```sql
EXEC test.Assert_IsEqual N'[TSQueue] after claim, LOT gone from line B queue (no longer in Trim Storage)', N'0', @b2;
```

with:

```sql
EXEC test.Assert_IsEqual N'[TSQueue] after claim, LOT gone from line B queue (MachiningIn step now satisfied)', N'0', @b2;
```

and replace the file header's `Description:` block with:

```sql
-- Description:  Tests for Lots.Lot_GetTrimStorageQueueForLine. NOTE THE NAME IS HISTORIC --
--               as of 2026-09-15 the read is route-driven and does not look at Trim
--               Storage (see the proc header). This fixture still STAGES the LOT in
--               TRIM1-STORE, which is now incidental rather than load-bearing: what makes
--               it visible is that its next pending route step is MachiningIn. A LOT shows
--               at a line ONLY when its Item is eligible there; a part eligible at two
--               lines appears in BOTH lines' reads; claiming it on one line satisfies the
--               MachiningIn step and removes it from both. Fixture: routed casting 5G0-c
--               staged in TRIM1-STORE, eligible at MA1-5GOF AND MA1-5GOR, NOT at MA1-6MD.
```

- [ ] **Step 2: Fix the Python docstring**

In `ignition/projects/Core/ignition/script-python/BlueRidge/Lots/Lot/code.py`, replace the `getTrimStorageQueueForLine` docstring. Replace:

```python
    """Trim-Storage model (2026-07-23) Machining IN queue for a LINE: the open LOTs sitting
       in Trim Storage whose next pending route step is MachiningIn AND whose Item is eligible
       at this line (ancestor cascade). A part eligible at two lines appears in both lines'
       queues; claiming it (Machining.recordPick) moves it onto the line and off the others.
       storageLocationId None => all trim stores (both shops). Same column shape as
       getWipQueueByLocation, so the MachiningIn view row transform is unchanged.
       Returns list[dict] (empty when no line bound)."""
```

with:

```python
    """Machining IN queue for a LINE. THE NAME IS HISTORIC -- as of 2026-09-15 this does
       NOT look at Trim Storage; the name is kept only because renaming it would force a
       Designer edit to the MachiningIn view's binding expression.

       Route-driven: the LOTs -- wherever they physically sit -- whose next pending route
       step is MachiningIn AND whose Item is eligible at this line (ancestor cascade).
       Trim Storage is one such place; WHSE is another, which is where a casting whose
       route skips the trim shop is released to. A part eligible at two lines appears in
       both lines' queues; claiming it (Machining.recordPick) writes the MachiningIn
       checkpoint, which satisfies that Advance step and drops it off both.

       storageLocationId is accepted and IGNORED (kept so the named query's signature is
       unchanged). Same column shape as getWipQueueByLocation, so the MachiningIn view row
       transform is unchanged. Returns list[dict] (empty when no line bound)."""
```

Change nothing else in the function — the name, the parameters, and the `execList` call all stay exactly as they are.

- [ ] **Step 3: Sync the gateway**

```bash
powershell -File ./scan.ps1
```

Expected: a success response from the gateway scan endpoint. This is a comment-only change, so nothing about runtime behaviour should differ — the scan just stops the repo and the gateway from diverging.

- [ ] **Step 4: Run the full suite one more time**

```bash
cd sql/tests && powershell -File ./Run-Tests.ps1
```

Expected: **0 failures.**

- [ ] **Step 5: Verify no unintended files are staged**

```bash
git status --short
```

Expected: only the two files from this task appear as modified. If `thumbnail.png`, `data.bin`, or `pull.log` files appear, do not stage them — they are gitignored build artefacts. If another developer's uncommitted work appears (the gateway and dev DB are shared), leave it alone and stage explicit paths only.

- [ ] **Step 6: Commit**

```bash
git add sql/tests/0024_PlantFloor_Movement_Trim/065_Lot_GetTrimStorageQueueForLine.sql ignition/projects/Core/ignition/script-python/BlueRidge/Lots/Lot/code.py
git commit -F - <<'EOF'
docs(machining): say plainly that the trim-storage names are historic

Lot_GetTrimStorageQueueForLine no longer looks at trim storage. The name
stays (renaming it means a Designer edit to the MachiningIn view binding),
so the header, the docstring and the test description have to carry the
warning instead.

The Python docstring was the urgent one: it asserted the LOTs are "sitting
in Trim Storage", which is now false rather than merely stale.
EOF
```

---

## Verification

After all three tasks, confirm each of these by running the command and reading the output — do not infer them:

1. `cd sql/tests && powershell -File ./Run-Tests.ps1` → 0 failures, and the summary names `030_MachiningIn_NoTrimRoute.sql` among the files that ran.
2. `git log --oneline -3` → the three commits above, on `jacques/working`.
3. `grep -n "LocationTypeDefinitionId = 14" sql/migrations/repeatable/R__Lots_Lot_GetTrimStorageQueueForLine.sql sql/migrations/repeatable/R__Workorder_MachiningIn_RecordPick.sql` → **no matches**. Both location gates are gone.
4. `grep -c "@StorageLocationId" ignition/projects/Core/ignition/named-query/lots/Lot_GetTrimStorageQueueForLine/query.sql` → still `1`. The NQ was not touched and still passes the parameter.

**Out of scope, deliberately:** renaming the procs/NQ/Python function (spec D6 — needs a Designer session); the `Parts.ufn_OperationTemplateForLotRole` convergence (the open TODO at the top of `PROJECT_STATUS.md`); the die-cast release destination (spec D9 — `WHSE` is correct); and any production deployment, which follows the five-part release contract in `prod-release-context-pack/` as its own exercise.
