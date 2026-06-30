# Assembly IN + Non-Serialized Per-Tray Consumption — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: use superpowers:executing-plans (or subagent-driven-development) to implement task-by-task. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Per FDS-06-013/06-014 and the rev-2 spec — make `ContainerTray_Close` emit per-tray `ConsumptionEvent`s into the container (decrementing BOM-component source LOTs), add an **Assembly IN** operator scan-in screen, model the **6B2** line, and fix the machining-rename BOM stage. Coupled/PLC path deferred (D2).

**Architecture:** Repeatable SQL procs + Ignition named-query/entity/view + smoke seed + T-SQL tests. **No schema migration** — `ConsumptionEvent.ProducedContainerId`/`TrayId` already exist; no output LOT; coupling deferred.

**Tech stack:** SQL Server 2022 T-SQL (status-row procs, INSERT-EXEC capture, inline sub-mutations per the `Lot_Split`/`Lot_Merge` rule), Ignition Perspective 8.3 file-based views + Jython entities + named queries.

**Source of truth:** `docs/superpowers/specs/2026-06-24-assembly-consumption-genealogy-design.md` (rev 2).

---

## File structure

| File | Responsibility | Action |
|---|---|---|
| `sql/migrations/repeatable/R__Lots_ContainerTray_Close.sql` | Per-tray close + **new** per-component consumption; **remove** coarse gate | Modify |
| `sql/migrations/repeatable/R__Workorder_Assembly_ScanIn.sql` | Move a component LOT into an Assembly Cell's queue (BOM-validated, no rename) | Create |
| `ignition/projects/MPP/.../named-queries/workorder/Assembly_ScanIn.sql` (+ `.../*.json` meta) | Thin EXEC wrapper NQ | Create |
| `ignition/projects/Core/ignition/script-python/BlueRidge/Workorder/Assembly/code.py` | `scanIn(...)` entity wrapper | Create |
| `ignition/projects/MPP/.../ShopFloor/AssemblyIn/{view.json,resource.json}` | Assembly IN screen (FIFO queue + scan-in), mirror `MachiningIn` | Create |
| `sql/scratch/smoke_seed_phase5_7.sql` | 6B2 family + BOM-stage fix + staged component LOTs + open 6B2 container | Modify |
| `sql/tests/0028_PlantFloor_Assembly/075_ContainerTray_Close_consumes_bom.sql` | Per-tray consumption assertions | Create |
| `sql/tests/0028_PlantFloor_Assembly/076_Assembly_ScanIn.sql` | Scan-in move + BOM-component validation | Create |
| `sql/tests/0028_PlantFloor_Assembly/077_Container_backward_trace.sql` | Container → ConsumptionEvent → machined → cast | Create |
| `sql/tests/0028_PlantFloor_Assembly/070_ContainerTray_Close_insufficient_material.sql` | Rework: per-component short → reject+rollback | Modify |
| `sql/tests/0028_PlantFloor_Assembly/{020,040,050,060}*.sql` | Give test container a BOM + stage component LOTs | Modify |

---

## Task 1: `ContainerTray_Close` — remove coarse gate, add per-tray BOM consumption

**Files:** Modify `R__Lots_ContainerTray_Close.sql`; Create test `075_*`.

- [ ] **Step 1 — Write the failing test `075_ContainerTray_Close_consumes_bom.sql`.**
  Create assembly test item `P6-ASMB-OUT` (non-ser), config `2×24`, with a published BOM `P6-ASMB-OUT ← P6-CHILD-A ×1 + P6-CHILD-B ×2`. Stage open child LOTs at the cell (`P6-CHILD-A` ≥48, `P6-CHILD-B` ≥96). Open a container, close tray 1 (24). Assert:
  - Status 1; `ContainerAccumulatedParts = 24`.
  - `Workorder.ConsumptionEvent`: 1 row for `P6-CHILD-A` (`PieceCount = 24×1 = 24`) + 1 for `P6-CHILD-B` (`24×2 = 48`), each with `ProducedContainerId = container`, `TrayId = the closed tray`, `ProducedItemId = P6-ASMB-OUT`.
  - Source LOTs decremented: `P6-CHILD-A` by 24, `P6-CHILD-B` by 48.
- [ ] **Step 2 — Run, expect FAIL** (no ConsumptionEvent today): `Run-Tests.ps1 -Filter "075"` (or run the file directly).
- [ ] **Step 3 — Remove the coarse availability gate** (the `@CellAvail`/`@ClosedParts` block added recently) from the proc.
- [ ] **Step 4 — Add BOM resolution + per-component availability validation (BEFORE `BEGIN TRANSACTION`).** After the existing open/full/position checks:
```sql
        -- ---- assembly consumption: resolve BOM + verify each component is available at the cell ----
        DECLARE @ItemId BIGINT, @CellId BIGINT;
        SELECT @ItemId = ItemId, @CellId = CurrentLocationId FROM Lots.Container WHERE Id = @ContainerId;
        DECLARE @BomId BIGINT = (SELECT TOP 1 Id FROM Parts.Bom
            WHERE ParentItemId = @ItemId AND PublishedAt IS NOT NULL AND DeprecatedAt IS NULL
            ORDER BY VersionNumber DESC);
        IF @BomId IS NULL
        BEGIN
            SET @Message = N'No active published BOM for the container item; cannot record assembly consumption.';
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId, @Accum AS ContainerAccumulatedParts;
            RETURN;
        END
        DECLARE @ShortChild NVARCHAR(50) =
            (SELECT TOP 1 ci.PartNumber
             FROM Parts.BomLine bl
             INNER JOIN Parts.Item ci ON ci.Id = bl.ChildItemId
             OUTER APPLY (SELECT ISNULL(SUM(l.PieceCount),0) AS Avail FROM Lots.Lot l
                          INNER JOIN Lots.LotStatusCode sc ON sc.Id = l.LotStatusId
                          WHERE l.CurrentLocationId = @CellId AND l.ItemId = bl.ChildItemId AND sc.Code <> N'Closed') a
             WHERE bl.BomId = @BomId AND a.Avail < (@PartsCount * bl.QtyPer));
        IF @ShortChild IS NOT NULL
        BEGIN
            SET @Message = N'Insufficient ' + @ShortChild + N' at this cell to fill the tray.';
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId, @Accum AS ContainerAccumulatedParts;
            RETURN;
        END
```
- [ ] **Step 5 — Add the in-txn consumption** after the tray `INSERT` (where `@NewId` = the new `ContainerTray.Id`). Cursor over BOM child lines; inner FIFO loop over the cell's open child LOTs (oldest `CreatedAt` first): decrement `PieceCount`, close at 0 (+`LotStatusHistory`), and `INSERT Workorder.ConsumptionEvent (SourceLotId, ProducedContainerId=@ContainerId, ConsumedItemId=child, ProducedItemId=@ItemId, PieceCount=consumed, LocationId=@CellId, AppUserId=@AppUserId, TerminalLocationId=@TerminalLocationId, TrayId=@NewId, ConsumedAt=SYSUTCDATETIME())`. (Inlined — do **not** `EXEC` `LotGenealogy_RecordConsumption`/`ConsumptionEvent_RecordWithBomCheck`; `ContainerTray_Close` returns a status row.) Decrement amount per child = `@PartsCount * QtyPer`, drawn FIFO across however many source LOTs are needed.
- [ ] **Step 6 — Run 075, expect PASS.**
- [ ] **Step 7 — Rework `070_*insufficient_material`** to stage a short *component* (not item-agnostic): one BOM child short → tray close rejects (Status 0, message names the child), container unchanged, no ConsumptionEvent, no decrement (full rollback).
- [ ] **Step 8 — Commit** (`feat(arc2-p6): per-tray BOM consumption in ContainerTray_Close`).

## Task 2: `Assembly_ScanIn` proc + NQ + entity

**Files:** Create `R__Workorder_Assembly_ScanIn.sql`, the `workorder/Assembly_ScanIn` NQ, `BlueRidge/Workorder/Assembly/code.py`; Create test `076_*`.

- [ ] **Step 1 — Write failing test `076_Assembly_ScanIn.sql`:** a machined component LOT not at the cell; `Assembly_ScanIn @LotId, @CellLocationId` → Status 1, `LotMovement` written into the cell, LOT `CurrentLocationId` updated, **no rename** (ItemId unchanged). A LOT whose item is **not** a BOM component of any assembly item at the cell → reject (Status 0). Run → FAIL (proc absent).
- [ ] **Step 2 — Write the proc** (status-row, no OUTPUT params; validations before `BEGIN TRANSACTION`; inline `Lot_MoveTo`-style move; `ROLLBACK` only in `CATCH`). Validation: the LOT exists, is Good, and its `ItemId` appears as a `BomLine.ChildItemId` of some active published BOM whose parent item is eligible (produced) at `@CellLocationId` (`Parts.ItemLocation`). Audit `Audit_LogOperation` (reuse an existing event code or add one in the seed migration if needed — confirm before adding).
- [ ] **Step 3 — Add the NQ** `workorder/Assembly_ScanIn` (thin `EXEC`, mirror `workorder/ConsumptionEvent_RecordWithBomCheck`).
- [ ] **Step 4 — Add entity** `BlueRidge.Workorder.Assembly.scanIn(lotId, cellLocationId, appUserId=None)` (wrapper, mirror `Workorder/Consumption/code.py`).
- [ ] **Step 5 — Run 076, expect PASS. Commit.**

## Task 3: Assembly IN view

**Files:** Create `ShopFloor/AssemblyIn/{view.json,resource.json}`.

- [ ] **Step 1 — Author the view by mirroring `MachiningIn`** (read `MachiningIn/view.json` first): dedicated terminal (cell from `session.custom.cell`), operator-initials gate + chip, FIFO queue bound to a WIP-style read of the cell's open component LOTs (reuse `Lot.getWipQueueByLocation` with the `refreshToken`-as-arg pattern), a scan/enter field + button that calls `BlueRidge.Workorder.Assembly.scanIn(...)` then bumps `refreshToken`. **Include `resource.json`** (the missing-manifest gotcha). Use `pf-*` plant-floor styling. No rename modal (unlike Machining IN).
- [ ] **Step 2 — Add a DEV NAV button** for Assembly IN in `Dev/TestNavHeader` and a route in `page-config/config.json` (+ a CSS rule in `plantFloor.css` for the new route).
- [ ] **Step 3 — Commit.**

## Task 4: 6B2 seed family + BOM-stage fix

**Files:** Modify `sql/scratch/smoke_seed_phase5_7.sql`.

- [ ] **Step 1 — Fix the machining-rename BOMs** to `machined ← cast`: change the seeded `5G0-MACH ← 5G0` to `5G0-MACH ← 5G0-C`; add `6B2-MACH ← 6B2-C`.
- [ ] **Step 2 — Create the 6B2 family** (idempotent `IF NOT EXISTS`): items `6B2-C` (Component), `6B2-MACH` (FinishedGood/machined), `6B2` (FinishedGood), `6B2-PIN` (Component); published BOMs `6B2-MACH ← 6B2-C ×1` and `6B2 ← 6B2-MACH ×1 + 6B2-PIN ×2`; a **non-serialized** `ContainerConfig` for `6B2` (e.g. `4×24`); eligibility (`6B2-MACH`,`6B2-PIN` at the chosen uncoupled 6B2 Assembly Cell — pick a real Cell Location, document it).
- [ ] **Step 3 — Stage the scenario:** open a `6B2` container at that cell; stage `6B2-MACH` + `6B2-PIN` component LOTs at the cell (≥ container target × QtyPer) — one pre-positioned (already in queue) and one `6B2-MACH` LOT at the feeding Machining Cell to scan in via Assembly IN. Update the printed WHAT-TO-SMOKE table.
- [ ] **Step 4 — Re-run `Seed-SmokeData.ps1`; confirm `phase5_7 OK`. Commit.**

## Task 5: Update existing assembly tests for the BOM-component model

**Files:** Modify `0028/{020,040,050,060}*.sql`.

- [ ] **Step 1 —** Each test's `P6-ASM-TEST` container item now needs a published BOM + staged child LOTs at the cell (else tray close rejects on the new BOM check). Give `P6-ASM-TEST` a 1-line BOM `← P6-ASM-CHILD ×1` and stage a `P6-ASM-CHILD` LOT (≥ target) at the cell (replacing the old single coarse `STG-*` LOT). Keep cleanup.
- [ ] **Step 2 —** Run `0028`+`0029` folders; fix any fallout.
- [ ] **Step 3 — Commit.**

## Task 6: Backward trace test + full-suite gate

**Files:** Create `077_Container_backward_trace.sql`.

- [ ] **Step 1 — Write `077`:** build a mini chain (cast LOT → machined LOT via `MachiningIn_PickAndConsume` → assembly container via tray closes), then assert the container's `ConsumptionEvent` rows reach the machined source, and the machined source's consumption edge reaches the cast LOT.
- [ ] **Step 2 — Run the FULL suite to a log; grep `ERROR running` AND `FAIL:`** (per the memory). Expect green except the pre-existing `010_Parts_codes_crud`. Fix any regressions (esp. fixed-shape `INSERT-EXEC` captures of changed read shapes).
- [ ] **Step 3 — Re-run `Seed-SmokeData.ps1`** to restore the UI demo state; remind to restart the gateway.
- [ ] **Step 4 — Final commit** + push.

---

## Self-review notes
- **Spec coverage:** §4.1 → Tasks 2–3; §4.2 → Task 1; §4.3 → Task 6; §4.4 → Task 4; §4.5 → Tasks 1/2/5/6. Covered.
- **No placeholders** beyond the deliberately representative 6B2 values (D1) and the "pick a real Cell Location" note (D2 — uncoupled, to be chosen during Task 4).
- **Naming consistency:** `Assembly_ScanIn` (proc) ↔ `workorder/Assembly_ScanIn` (NQ) ↔ `BlueRidge.Workorder.Assembly.scanIn` (entity). `ConsumptionEvent` columns match the verified schema (`ProducedContainerId`, `TrayId`, `ProducedItemId`, `ConsumedItemId`).
- **Risk:** Task 1's inlined per-component FIFO consume + reject-rollback is the care-point; validations sit before `BEGIN TRANSACTION`, `ROLLBACK` only in `CATCH`.
