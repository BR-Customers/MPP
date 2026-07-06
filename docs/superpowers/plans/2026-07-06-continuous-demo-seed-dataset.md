# Continuous Demo Seed Dataset — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the bloated product-config seeds and the five siloed `smoke_seed_phase*` scripts with (a) a clean, minimal, purpose-built parts config and (b) one idempotent demo-thread builder, so an engineer gets a coherent, connected, end-to-end dataset — clean config + WIP-at-every-terminal + completed threads — from a single `Reset-DevDatabase`.

**Architecture:** Two layers. The **clean parts config** (items, routes, BOMs, ContainerConfig, eligibility, operation templates, quality specs) is rewritten in `sql/seeds/` and loaded by `Reset-DevDatabase`. The **transactional threads** live in a new `sql/scratch/seed_demo.sql`, built via the production procs (real genealogy/audit), idempotent, wired into `Reset-DevDatabase` by default (with `Run-Tests` opting out to keep the DB LOT-free).

**Tech Stack:** SQL Server 2022 (T-SQL seed scripts + `sqlcmd`), PowerShell (`Reset-DevDatabase.ps1`, `Run-Tests.ps1`, new `Seed-Demo.ps1`). Governed by `sql_best_practices_mes.md`, `sql_version_control_guide.md`, and the design spec `docs/superpowers/specs/2026-07-06-continuous-demo-seed-dataset-design.md`.

## Global Constraints

- **Branch:** `jacques/working`. Confirm `git branch --show-current` before committing. Explicit path staging only (never `git add -A`/`-u`). Omit the `Co-Authored-By: Claude` trailer.
- **Keep untouched:** plant location model (`Location.*`), all code/reference tables, and tools/dies (`Tools.*`). Only the "parts content" is rewritten.
- **Preserve operation-template codes verbatim:** `DieCastShot`, `TrimIn`, `TrimOut`, `MachiningIn`, `MachiningOut`, `AssemblyIn`, `AssemblyOut` (6 test files match `OperationTemplate WHERE Code = N'…'`). New instances may be added but these codes must exist post-rewrite.
- **The 1910-assertion SQL suite MUST stay green with zero test edits.** Verify with `Run-Tests.ps1` after Task 1 and Task 3. If a test regresses, fix it within the task.
- **ASCII-only** strings in all seed/demo SQL (em-dash / middle-dot become mojibake via sqlcmd's codepage). Use `-` and `.`.
- **Resolve everything by code, never a hardcoded Id** — parts by `PartNumber`, locations by `Code`, tools by `Code`, users by initials — so seeds survive identity reseeds.
- **`sqlcmd` flags for Lots.* work:** `-b -I -C` (the `-I` matters — `Lots.*` carry filtered indexes → Msg 1934 without QUOTED_IDENTIFIER ON).
- **Idempotent:** every seed/demo script re-runnable; guard config inserts with `IF NOT EXISTS`, and the demo script wipes its transactional footprint first.

---

## Task 1: Clean parts config

**Files:**
- Rewrite: `sql/seeds/020_seed_items.sql`
- Rewrite: `sql/seeds/022_seed_die_cast_operation_template.sql`, `sql/seeds/024_seed_trim_operation_templates.sql`, `sql/seeds/026_seed_machining_operation_templates.sql` (only if they carry stale part-specific bindings; otherwise leave — they seed the op-templates by code, which we keep)
- Add (if not already seeded): AssemblyIn / AssemblyOut operation templates (currently referenced from `020` — fold into `020` or a new `027_seed_assembly_operation_templates.sql`)

**Interfaces:**
- Produces (relied on by Task 2 + the whole app): the clean parts, resolvable by `PartNumber`; per-item routes resolvable by the M3 resolver (`RouteTemplate.ItemId` → `RouteStep` → `OperationTemplate` by `OperationType.Code`); published BOMs; `ContainerConfig` per finished-good; `ItemLocation` eligibility at the cells named below; a `QualitySpec` on `6MA`.

### The matrix (exact values)

**Items** (`Parts.Item`; `ItemTypeId`: 2=Component, 3=SubAssembly, 4=FinishedGood, 5=PassThrough; UomId 1; resolve `CreatedByUserId` by an existing AppUser initials):

| PartNumber | ItemTypeId | Description | Role |
|---|---|---|---|
| `6MA` | 4 | 6MA Cam Holder Assembly | primary FG (non-serialized) |
| `6MA-C` | 2 | 6MA Cam Holder Casting | 6MA casting |
| `6MA-M` | 3 | 6MA Machined Cam Holder | 6MA machined |
| `PIN-A` | 2 | Mounting Pin (purchased) | 6MA BOM 2nd line |
| `5G0` | 4 | 5G0 Front Cover Assembly | serialized FG |
| `5G0-C` | 2 | 5G0 Front Cover Casting | 5G0 casting |
| `5G0-M` | 3 | 5G0 Machined Front Cover | 5G0 machined |
| `RD-BRKT` | 5 | RD Mounting Bracket | pass-through |

**Routes** (`Parts.RouteTemplate` per item + ordered `Parts.RouteStep` referencing the op-templates by their code; published, `EffectiveFrom` = a fixed past date, `DeprecatedAt` NULL):

| Item | Route steps (in `SequenceNumber` order, by OperationTemplate Code) |
|---|---|
| `6MA-C` | `DieCastShot`, `TrimIn`, `TrimOut` |
| `6MA-M` | `MachiningIn`, `MachiningOut` |
| `6MA` | `AssemblyIn`, `AssemblyOut` |
| `5G0-C` | `DieCastShot` |
| `5G0-M` | `MachiningIn`, `MachiningOut` |
| `5G0` | `AssemblyIn`, `AssemblyOut` |
| `RD-BRKT` | (none — pass-through) |

**BOMs** (`Parts.Bom` published + `Parts.BomLine`):

| Parent (FG) | Line: Child ×QtyPer |
|---|---|
| `6MA` | `6MA-M` ×1, `PIN-A` ×2 |
| `5G0` | `5G0-M` ×1 |

**ContainerConfig** (`Parts.ContainerConfig`):

| Item | TraysPerContainer | PartsPerTray | IsSerialized | ClosureMethod |
|---|---|---|---|---|
| `6MA` | 2 | 12 | 0 | `ByCount` |
| `5G0` | 2 | 8 | 1 | `ByVision` |

**Eligibility** (`Parts.ItemLocation`, resolve LocationId by Code; `IsConsumptionPoint` 0 unless noted):

| Item | Eligible at (Location Code) |
|---|---|
| `6MA-C` | `DC1-M01` (die-cast), a trim cell |
| `6MA-M` | `MA1-6MD-MIN`, `MA1-6MD-MOUT` (if present, else the 6MD-line machining cells) |
| `6MA`, `PIN-A` | `MA1-6MD-AOUT` (assembly-out cell); `PIN-A` also consumption-point 1 here |
| `5G0-C` | `DC1-M02` |
| `5G0-M` | `MA1-5GOF-MIN`, `MA1-5GOF-MOUT` |
| `5G0` | `MA1-5GOF-AFIN` (or the 5GOF assembly cell) |
| `RD-BRKT` | the receiving dock + shipping dock location codes |

> At build time, confirm the exact machining/assembly cell codes with `SELECT Code FROM Location.Location WHERE Code LIKE 'MA1-6MD-%' OR Code LIKE 'MA1-5GOF-%'` and use whichever `MIN`/`MOUT`/`AOUT`/`AFIN` cells exist for those lines (the grounding shows `MA1-6MD-MIN`, `MA1-6MD-AOUT`, `MA1-5GOF-MIN`, `MA1-5GOF-MOUT`; pick the assembly cell that exists for each line).

**QualitySpec** (`Quality.QualitySpec` on `6MA`) with two numeric attributes, e.g. `Flatness` (UOM mm, target 0.05, lower 0, upper 0.10) and `Diameter` (UOM mm, target 25.0, lower 24.9, upper 25.1). Follow the existing `Quality.QualitySpec` + attribute insert shape in the current `020`.

- [ ] **Step 1: Snapshot the current config shape**

Read the current `sql/seeds/020_seed_items.sql` fully to learn the exact column lists for `Parts.Item`, `RouteTemplate`, `RouteStep`, `Bom`, `BomLine`, `ContainerConfig`, `ItemLocation`, `Quality.QualitySpec` (+ attributes), and how AssemblyIn/AssemblyOut templates are currently seeded. You will reuse these column lists verbatim.

- [ ] **Step 2: Rewrite `020_seed_items.sql` to the clean matrix**

Replace the item/route/BOM/containerconfig/eligibility/quality content with the matrix above. Requirements:
- Keep the file's existing preamble/guards (`SET NOCOUNT/XACT_ABORT/QUOTED_IDENTIFIER ON`, the `@Now`/user resolution).
- Every insert guarded `IF NOT EXISTS (…)` so a re-run is a no-op.
- Resolve all FKs by natural key (ItemType by code, Location by Code, OperationTemplate by Code, UoM by code).
- Ensure AssemblyIn + AssemblyOut `OperationTemplate` rows exist (add them here or in `027_…` if the die-cast/trim/machining seed files don't).
- ASCII-only strings.

- [ ] **Step 3: Reset with config only (no demo yet) + run the suite**

Run:
```
powershell -NoProfile -ExecutionPolicy Bypass -File sql/scripts/Reset-DevDatabase.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File sql/tests/Run-Tests.ps1
```
Expected: Reset completes; `Test run PASSED`-equivalent — **Total 1910, Failed 0**, and the ONLY `ERROR running` line is the pre-existing `010_Parts_codes_crud.sql`. (At this point `seed_demo.sql` does not exist, so a plain Reset loads config only — the DB is LOT-free, exactly what the tests need.)

- [ ] **Step 4: If any test regressed, fix it**

Only expected if an operation-template code was dropped or renamed. Restore the code. Re-run Step 3. Do not proceed until green.

- [ ] **Step 5: Commit**

```bash
git add sql/seeds/020_seed_items.sql sql/seeds/022_seed_die_cast_operation_template.sql sql/seeds/024_seed_trim_operation_templates.sql sql/seeds/026_seed_machining_operation_templates.sql
# add sql/seeds/027_seed_assembly_operation_templates.sql if you created it
git commit -m "feat(seed): clean minimal parts config (6MA/5G0/RD-BRKT matrix)"
```

---

## Task 2: Demo-thread builder (`seed_demo.sql`)

**Files:**
- Create: `sql/scratch/seed_demo.sql`

**Interfaces:**
- Consumes: the clean config from Task 1 (parts by `PartNumber`, cells by `Code`); the production procs (`Lots.Lot_Create`, `Workorder.MachiningIn_PickAndConsume`, `Workorder.MachiningOut_RecordSplit`, `Workorder.Assembly_CompleteTray`, `Lots.Container_Complete`, `Lots.LotPause_Place`, `Quality.Hold_Place`, `Workorder.RejectEvent_Record`, `Oee.DowntimeEvent_Start`, `Lots.SerializedPart_Mint`, `Lots.ContainerSerial_Add`).
- Produces: a connected transactional dataset (WIP at every terminal + one completed/shipped thread per FG + cross-cutting exercisers) and a printed "what to smoke" checklist.

**Reference:** model the proc-call flow on the existing `sql/scratch/smoke_seed_phase5_7.sql` and `smoke_seed_phase3_diecast.sql` (they already call the real procs correctly — mount tool, create cast LOT, consume, split, assemble). This task consolidates + connects them into the matrix.

- [ ] **Step 1: Header + idempotent transactional wipe block**

Create `sql/scratch/seed_demo.sql` starting with the run-instructions header (usage: `sqlcmd -S localhost -d MPP_MES_Dev -E -b -I -C -i sql/scratch/seed_demo.sql`) and `SET NOCOUNT/XACT_ABORT/QUOTED_IDENTIFIER ON`. Then a wipe block that deletes ALL transactional data in FK-safe order (mirror the deletion order proven in `sql/tests/0028_PlantFloor_Assembly/092_Assembly_CompleteTray.sql`):

```sql
DELETE FROM Workorder.ConsumptionEvent;
DELETE FROM Workorder.ProductionEventValue;   -- if present
DELETE FROM Workorder.ProductionEvent;
DELETE FROM Workorder.RejectEvent;             -- if present
DELETE FROM Oee.DowntimeEvent;
DELETE FROM Quality.HoldEvent;
DELETE FROM Lots.PauseEvent;
DELETE FROM Lots.ShippingLabel;
DELETE FROM Lots.ContainerSerial;
DELETE FROM Lots.ContainerTray;
DELETE FROM Lots.Container;
DELETE FROM Lots.SerializedPart;
DELETE FROM Lots.LotLabel;
DELETE FROM Lots.LotAttributeChange;
DELETE FROM Lots.LotMovement;
DELETE FROM Lots.LotStatusHistory;
DELETE FROM Lots.LotGenealogy;
DELETE FROM Lots.LotGenealogyClosure;
DELETE FROM Lots.LotEventLog;
UPDATE Lots.AimShipperIdPool SET ConsumedAt = NULL, ConsumedByContainerId = NULL, ConsumedByUserId = NULL WHERE ConsumedAt IS NOT NULL;  -- release claimed AIM ids
DELETE FROM Lots.Lot;
-- reset any claimed tool assignments the demo will re-create, if applicable
```
Verify the exact table set against the schema at build time (`SELECT name FROM sys.tables WHERE schema_name(schema_id) IN ('Lots','Workorder','Oee','Quality')`); include only tables that exist. The wipe must leave config (`Parts.*`, `Location.*`, `Tools.Tool`/`ToolCavity`, code tables) intact.

- [ ] **Step 2: Ensure a die-cast tool is mounted for the cast threads**

Die-cast `Lot_Create` requires an active `Tools.ToolAssignment` on the cell. Resolve an existing `Tools.Tool` + one Active `Tools.ToolCavity`, and if no active assignment exists on `DC1-M01`, insert one (mirror `smoke_seed_phase3_diecast.sql`'s mount block). Capture `@ToolId`, `@ToolCavityId`.

- [ ] **Step 3: Build the `6MA` primary thread — one COMPLETED/shipped run**

Using the procs, in order (resolve all ids by code; `@AppUserId` = an existing operator):
1. `Lot_Create` a `6MA-C` cast LOT at `DC1-M01`, PieceCount 24, origin `Manufactured`, `@ToolId`/`@ToolCavityId` set → cast LOT.
2. Move it to trim then to `MA1-6MD-MIN` (via `Lot_MoveToValidated` / `Lot_MoveTo` as the flow requires), record trim checkpoints if the flow needs them.
3. `MachiningIn_PickAndConsume` the cast LOT at `MA1-6MD-MIN` → machined `6MA-M` LOT.
4. `MachiningOut_RecordSplit` (extract-one) the machined LOT at `MA1-6MD-MOUT`, extracting sublots totalling the full count so the parent closes → two `6MA-M` sublots routed to `MA1-6MD-AOUT`.
5. Stage `PIN-A` component stock at `MA1-6MD-AOUT` (`Lot_Create`, PieceCount 48, InventoryAvailable 48).
6. `Assembly_CompleteTray` for `6MA` at `MA1-6MD-AOUT`, PieceCount 12, twice (two trays) → mints two `6MA` FG LOTs, consumes `6MA-M` + `PIN-A` FIFO, fills the container.
7. `Container_Complete` the full container → AIM shipper id claimed + ShippingLabel (requires an AIM pool id for `6MA` — ensure `Lots.AimShipperIdPool` has an unconsumed id for PartNumber `6MA`; seed one if `028_seed_aim_pool_dev.sql` doesn't cover it).
8. Ship it (`Container_Ship` if that is the flow's final step).

- [ ] **Step 4: Build the `6MA` WIP state (live-operable at every terminal)**

Leave, un-completed:
- A `6MA-M` machined LOT sitting at `MA1-6MD-MOUT` (created via steps 1-3 again, NOT split) → operator can extract-one live on the Machining OUT screen.
- `6MA-M` sublots + `PIN-A` stock staged at `MA1-6MD-AOUT` with an OPEN container (one tray closed, one to go) → operator can complete a tray live and watch the container fill.
- A `6MA-C` cast LOT at `DC1-M01` and one at trim → die-cast / trim screens have WIP.

- [ ] **Step 5: Build the `5G0` serialized variant (mid-flow) + a hold**

1. Cast `5G0-C` at `DC1-M02` → machining-in → `5G0-M` machined LOT at `MA1-5GOF-MOUT`.
2. Open a container for `5G0` at the 5GOF assembly cell; `SerializedPart_Mint` a few serials against a `5G0` producing LOT; `ContainerSerial_Add` them into the tray (serialized placement — FG-LOT completion is deferred A4).
3. `Hold_Place` a hold on one `5G0` LOT → Hold management screen has an active hold; the hold-blocks-production guard is exercised.

- [ ] **Step 6: Build the pass-through + cross-cutting exercisers**

- `RD-BRKT`: `Lot_Create` one Received LOT on the receiving dock (origin `Received`, VendorLotNumber set); create + ship one so shipping has a completed pass-through.
- `LotPause_Place` a pause on a `6MA` WIP LOT (Paused-LOT indicator + resume).
- `RejectEvent_Record` a small reject at `6MA` machining (defect/scrap trail on LOT history).
- `DowntimeEvent_Start` an open downtime on the 6MD line (Downtime + Supervisor screens).

- [ ] **Step 7: Print the "what to smoke" checklist**

End the script with `PRINT` lines: per screen, the route/URL + the cell Code + operator initials + the exact action (e.g. "Machining OUT `/shop-floor/die-cast`... at `MA1-6MD-MOUT`: extract a sub-LOT of 6 from `<6MA-M LotName>` -> parent stays open"). Mirror the guide style in `smoke_seed_phase5_7.sql`.

- [ ] **Step 8: Run it against a fresh config DB + verify**

Run:
```
powershell -NoProfile -ExecutionPolicy Bypass -File sql/scripts/Reset-DevDatabase.ps1
sqlcmd -S localhost -d MPP_MES_Dev -E -b -I -C -i sql/scratch/seed_demo.sql
```
Expected: no errors; the checklist prints. Then verify the connected dataset with a query file:
```sql
-- expect: 6MA FG LOTs > 0, a shipped container with a ShippingLabel, a full genealogy chain
SELECT (SELECT COUNT(*) FROM Lots.Lot l INNER JOIN Parts.Item i ON i.Id=l.ItemId WHERE i.PartNumber='6MA')            AS FG_6MA,
       (SELECT COUNT(*) FROM Lots.ContainerTray WHERE FinishedGoodLotId IS NOT NULL)                                   AS TraysWithFgLot,
       (SELECT COUNT(*) FROM Lots.ShippingLabel)                                                                       AS ShippingLabels,
       (SELECT COUNT(*) FROM Lots.LotGenealogyClosure)                                                                 AS ClosureRows,
       (SELECT COUNT(*) FROM Lots.PauseEvent WHERE ResumedAt IS NULL)                                                  AS OpenPauses,
       (SELECT COUNT(*) FROM Quality.HoldEvent WHERE ReleasedAt IS NULL)                                               AS OpenHolds,
       (SELECT COUNT(*) FROM Oee.DowntimeEvent WHERE EndedAt IS NULL)                                                  AS OpenDowntime;
```
Expected: every count > 0. Fix the thread steps until it does. **Re-run `seed_demo.sql` a second time and confirm the counts are identical** (idempotency).

- [ ] **Step 9: Confirm the suite is still LOT-free-green**

Run `sql/tests/Run-Tests.ps1` (it Resets first — no demo yet in the Reset path) → **1910, Failed 0**. This proves `seed_demo.sql` living in `sql/scratch/` does not touch the test path.

- [ ] **Step 10: Commit**

```bash
git add sql/scratch/seed_demo.sql
git commit -m "feat(seed): consolidated demo-thread builder (matrix, production procs, idempotent)"
```

---

## Task 3: Wire into the default flow + retire the silos

**Files:**
- Modify: `sql/scripts/Reset-DevDatabase.ps1`
- Modify: `sql/tests/Run-Tests.ps1:76`
- Create: `Seed-Demo.ps1` (repo root, mirroring the existing wrapper style)
- Delete: `sql/scratch/smoke_seed_phase2.sql`, `smoke_seed_phase3_diecast.sql`, `smoke_seed_phase4.sql`, `smoke_seed_phase5_7.sql`, `smoke_seed_phase8.sql`, `smoke_cleanup_phase2.sql`

**Interfaces:**
- Produces: `.\Reset-DevDatabase.ps1` (default) = clean config + demo threads; `.\Reset-DevDatabase.ps1 -SkipDemoSeed` = config only; `.\Run-Tests.ps1` = internally `-SkipDemoSeed` → 1910 green.

- [ ] **Step 1: Add the `-SkipDemoSeed` switch to `Reset-DevDatabase.ps1`**

Add `[switch]$SkipDemoSeed` to the `param(...)` block. After the seed-loading step (STEP 6), append:
```powershell
if (-not $SkipDemoSeed) {
    $demo = Join-Path $SqlRoot "scratch/seed_demo.sql"
    if (Test-Path $demo) {
        Write-Host "[7/7] Seeding demo threads (seed_demo.sql)..." -ForegroundColor Cyan
        Invoke-SqlFile -FilePath $demo    # reuse the script's existing sqlcmd helper (ensure it passes -I -C)
        Write-Host "  demo threads seeded." -ForegroundColor Green
    }
} else {
    Write-Host "  -SkipDemoSeed set: config only, no demo threads (LOT-free)." -ForegroundColor DarkYellow
}
```
Confirm the script's sqlcmd invocation helper passes `-I -C` (needed for `Lots.*` filtered indexes); if it does not, add them for the demo call.

- [ ] **Step 2: Make `Run-Tests.ps1` opt out**

At `sql/tests/Run-Tests.ps1:76`, change the Reset invocation to pass the switch:
```powershell
& $ResetScript -ServerInstance $ServerInstance -DatabaseName $DatabaseName -SkipDemoSeed
```

- [ ] **Step 3: Create `Seed-Demo.ps1`**

A thin wrapper at the repo root (mirror `sql/scratch/Seed-SmokeData.ps1` if it exists) that runs `sqlcmd -S localhost -d MPP_MES_Dev -E -b -I -C -i sql/scratch/seed_demo.sql` (params for `-ServerInstance`/`-DatabaseName` with the same defaults as the other scripts). For re-seeding threads without a full reset.

- [ ] **Step 4: Delete the superseded silo scripts**

```bash
git rm sql/scratch/smoke_seed_phase2.sql sql/scratch/smoke_seed_phase3_diecast.sql sql/scratch/smoke_seed_phase4.sql sql/scratch/smoke_seed_phase5_7.sql sql/scratch/smoke_seed_phase8.sql sql/scratch/smoke_cleanup_phase2.sql
```
(If `Seed-SmokeData.ps1` only drove those, delete it too; if it is generic, leave it.)

- [ ] **Step 5: Verify all three entry points**

Run and confirm:
```
powershell -NoProfile -ExecutionPolicy Bypass -File sql/scripts/Reset-DevDatabase.ps1              # default
```
→ then `SELECT COUNT(*) FROM Lots.Lot;` returns **> 0** (demo threads present).
```
powershell -NoProfile -ExecutionPolicy Bypass -File sql/scripts/Reset-DevDatabase.ps1 -SkipDemoSeed
```
→ then `SELECT COUNT(*) FROM Lots.Lot;` returns **0**.
```
powershell -NoProfile -ExecutionPolicy Bypass -File sql/tests/Run-Tests.ps1
```
→ **Total 1910, Failed 0**, only the pre-existing `010_Parts_codes_crud.sql` thrower.

- [ ] **Step 6: Commit**

```bash
git add sql/scripts/Reset-DevDatabase.ps1 sql/tests/Run-Tests.ps1 Seed-Demo.ps1
git add -- sql/scratch/smoke_seed_phase2.sql sql/scratch/smoke_seed_phase3_diecast.sql sql/scratch/smoke_seed_phase4.sql sql/scratch/smoke_seed_phase5_7.sql sql/scratch/smoke_seed_phase8.sql sql/scratch/smoke_cleanup_phase2.sql
git commit -m "feat(seed): run seed_demo by default in Reset-DevDatabase (-SkipDemoSeed for tests); retire phase smoke silos"
```

---

## Task 4: Smoke the golden environment

**Files:** none (manual verification).

- [ ] **Step 1: Reset to the full environment**

Run `.\sql\scripts\Reset-DevDatabase.ps1` (default). Read the printed "what to smoke" checklist.

- [ ] **Step 2: Run `.\scan.ps1`** (register any resources; no gateway restart).

- [ ] **Step 3: Walk the checklist in a Perspective session**

Confirm, per the printout: the `6MA` Machining OUT extract-one (parent stays open); a live `6MA` tray completion (FG LOT mints, container fills, Complete → ShippingLabel); the Inventory popup lists `PIN-A` on-hand + check-in; the Genealogy Viewer shows the full `6MA` cast→machined→sublots→FG→container tree; a paused LOT, an active `5G0` hold, an open downtime all render on their screens; the pass-through `RD-BRKT` shows on receiving + shipping.

- [ ] **Step 4: Record results**

Note any screen that renders empty or errors against the seeded data; file follow-ups. (No commit — verification only.)

---

## Self-Review

**Spec coverage:**
- Two-layer structure (config in `sql/seeds`, threads in `sql/scratch/seed_demo.sql`) → Tasks 1 + 2. ✔
- KEEP plant/locations/code-tables/tools; CLEAR + purpose-build parts content → Task 1 (rewrite scope) + Global Constraints. ✔
- Matrix (6MA non-serial primary, 5G0 serialized variant, RD-BRKT pass-through) + genealogy chain → Task 1 (config) + Task 2 (threads). ✔
- Built via production procs, idempotent, code-resolved, minimal volume → Task 2 (proc-call steps + wipe block + Step 8 idempotency re-run). ✔
- Cross-cutting exercisers (pause/hold/reject/downtime) → Task 2 Steps 5-6. ✔
- Preserve op-template codes; 1910 green with zero edits → Task 1 Steps 3-4, Task 3 Step 5. ✔
- Default-flow wiring (`-SkipDemoSeed` default-on; Run-Tests opts out; `Seed-Demo.ps1`; retire silos) → Task 3. ✔
- "What to smoke" printout → Task 2 Step 7; smoke walkthrough → Task 4. ✔
- Out-of-scope (raw-al lot-linking, serialized FG completion/A4, load volume, view changes) → respected (genealogy starts at cast LOT; 5G0 stops at serial placement). ✔

**Placeholder scan:** the two "confirm the exact cell code at build time" notes are grounded lookups (the grep already lists the candidate codes), not TBDs — the implementer runs one `SELECT` to pick the extant cell. No "add error handling"/"similar to Task N"/TODO placeholders.

**Type/name consistency:** op-template codes (`DieCastShot`/`TrimIn`/`TrimOut`/`MachiningIn`/`MachiningOut`/`AssemblyIn`/`AssemblyOut`), part numbers (`6MA`/`6MA-C`/`6MA-M`/`PIN-A`/`5G0`/`5G0-C`/`5G0-M`/`RD-BRKT`), cell codes (`DC1-M01`/`DC1-M02`/`MA1-6MD-MIN`/`MA1-6MD-MOUT`/`MA1-6MD-AOUT`/`MA1-5GOF-*`), and proc names are used consistently across Tasks 1-4 and match the grounded schema.

**Ordering:** Task 1 (config; verify with plain Reset since no demo exists yet) → Task 2 (demo builder; run manually) → Task 3 (wire default + retire silos; the `-SkipDemoSeed` switch is what makes Reset run the demo) → Task 4 (smoke). Each task ends green + committed.
