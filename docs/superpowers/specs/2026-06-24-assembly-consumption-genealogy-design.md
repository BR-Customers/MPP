# Assembly IN + Non-Serialized Consumption & Genealogy — Design Spec (rev 2)

**Date:** 2026-06-24
**Author:** Blue Ridge Automation
**Status:** Draft rev 2 — **supersedes the rev-1 "output LOT at completion" model**, which was misaligned with FDS-06-013/06-014. (rev 1 preserved in git history.)
**Scope tag:** MVP-EXPANDED (Arc 2 Phase 6, Assembly)

## 1. Why rev 2 (corrected understanding)

Rev 1 proposed minting an **output LOT** at `Container_Complete` and consuming there. Review of FDS §6.6 / §7.2, the live schema, and the plant-floor task list shows the intended model is different:

- **FDS-06-013 / FDS-06-014:** non-serialized consumption is **per tray**. Each tray close writes a `Workorder.ConsumptionEvent` per BOM component, decrementing sources by `PartsPerTray × QtyPer`, **producing into the container** — *not* a minted LOT.
- **Schema confirms it:** `Workorder.ConsumptionEvent` has `ProducedContainerId`, `TrayId`, and `ProducedSerialNumber`. The produced side is the **container** (or a serial); there is no output-LOT requirement.
- **Task `T116`:** *"ContainerTray_Close (ByCount/ByWeight/ByVision) … per-tray Workorder.ConsumptionEvent emit."* That behavior was specified for Phase 6 but never implemented — the current proc only records the tray (+ the coarse availability gate added recently).
- **FDS-06-008 (machining→assembly handoff):** two paths — **auto-coupled** (the Machining Cell's `CoupledDownstreamCellLocationId` is set; PLC completion auto-moves the machined LOT to the paired Assembly Cell) and **uncoupled** (operator moves the LOT). The assembly cell therefore needs an **Assembly IN** operator surface for the scan-in path. No such screen exists today.

**Decisions captured from review (2026-06-24):** non-ser demo line = **6B2 Cam Holder** (D-Q1); **build an Assembly IN screen** with auto-couple + operator-scan paths (D-Q2); container-level trace via `ConsumptionEvent.ProducedContainerId`, **no** `LotGenealogy` LOT-row for the container (D-Q3).

## 2. Goal / non-goals

**Goal — complete the non-serialized assembly flow for the 6B2 Cam Holder line:**
1. **Assembly IN screen** (new): a FIFO queue of component LOTs at the Assembly Cell. Auto-populated on coupled lines; operator scans a LOT's LTT to bring it into the queue on uncoupled lines.
2. **Per-tray consumption** in `ContainerTray_Close`: one `ConsumptionEvent` per BOM component into the container, decrementing the source component LOTs, with per-component availability rejection.
3. **Trace** via `ConsumptionEvent.ProducedContainerId` (containers are a valid trace entry point per FDS-05-017).
4. Fix the **machining-rename BOM stage** so it is `machined ← cast` (FDS-05-033).

**Non-goals:** serialized/PLC consumption (already scaffolded — FDS-06-010, PLC-gated); the PLC auto-couple *firing* (`MachiningOut_AutoComplete` exists; it's PLC-driven and not exercisable in dev — we ensure the move target/queue works, not the PLC trigger); trim changes.

## 3. Chain + item model (6B2)

Production chain: **cast → trim → machine → assemble**. For 6B2:

| Stage | Item | Transition |
|---|---|---|
| Cast | `6B2-C` (cast component) | LOT born |
| Trim | `6B2-C` (same item) | whole-LOT move (no rename) |
| Machine | `6B2-MACH` | Machining-IN 1-line rename `6B2-MACH ← 6B2-C` (FDS-05-033) |
| Assemble | `6B2` (non-ser finished good) | container filled, consuming BOM `6B2 ← 6B2-MACH ×1 + …` |

The same correction applies to the existing 5G0 family: machining-rename BOM should be `5G0-MACH ← 5G0-C` (the seed currently has `5G0-MACH ← 5G0`, wrong).

## 4. Design

### 4.1 Assembly IN — new view + proc
- **View** `BlueRidge/Views/ShopFloor/AssemblyIn` (mirror `MachiningIn`): FIFO queue of open component LOTs at the Assembly Cell, ordered by `LotMovement.MovedAt`. Dedicated terminal (cell from `session.custom.cell`), operator-initials gate.
- **Scan-in proc** `Workorder.Assembly_ScanIn(@LotId | @LotName, @CellLocationId, @AppUserId)`: writes a `LotMovement` bringing the (machined) component LOT into this Assembly Cell's queue — **no rename**, the machined LOT keeps its identity. Validates the LOT's item is a BOM component of an assembly item produced at this cell (reject otherwise — D-Q3 confirms validate).
- **Auto-coupled lines: DEFERRED (D2)** — pending Jacques on how coupled lines work. This spec builds only the operator scan-in path. (`MachiningOut_AutoComplete` already exists; wiring it to populate the Assembly IN queue, plus the `CoupledDownstreamCellLocationId` attribute, is a later increment — do not seed or wire it here.)

### 4.2 Per-tray consumption — extend `ContainerTray_Close`
After the existing open/full/position validations, **inside the transaction**:
1. Resolve the container item's **active published BOM** + child lines. Reject if none.
2. For each child line: `needed = PartsPerTray × QtyPer`. **FIFO-consume** from the cell's open LOTs of that child item (oldest `CreatedAt` first): decrement `PieceCount`; set `Closed` + `LotStatusHistory` at zero. **Reject + roll back if any child is short.** (This replaces the coarse item-agnostic availability gate with a precise per-component check.)
3. Per consumed source LOT, inline `INSERT Workorder.ConsumptionEvent (SourceLotId, ProducedContainerId = container, ConsumedItemId = child, ProducedItemId = container item, PieceCount, TrayId = the just-closed tray, LocationId = cell, AppUserId, ConsumedAt)`. (Inlined, not `EXEC`-ed — the proc returns a status row, same INSERT-EXEC rule as `Lot_Split`/`Lot_Merge`.)
4. Existing tray `INSERT` + running-count accumulation unchanged.

No output LOT. No `LotGenealogy` LOT-row (the produced side is a container, not a LOT). `ClosureMethod` stays config-driven (recent change).

### 4.3 Backward trace (Honda)
`ShippingLabel → Container → ConsumptionEvent.ProducedContainerId (one set per tray) → SourceLotId (machined 6B2-MACH) → [machining Consumption edge] → cast LOT (6B2-C) → Die Cast ProductionEvent`. Forward + backward both satisfied (FDS-05-017): containers, serials, and child LOTs are all trace entry points.

### 4.4 Data / seed
- **No schema migration needed** — the consumption columns (`ProducedContainerId`, `TrayId`) already exist, no output-LOT column is required, and the coupled-path attribute is deferred (D2). All work is repeatable procs + seed + views + tests.
- Fix machining-rename BOMs to `machined ← cast` (`5G0-MACH ← 5G0-C`, `6B2-MACH ← 6B2-C`).
- Create the **6B2 family**: items `6B2-C`, `6B2-MACH`, `6B2` (+ component(s)); published BOMs (rename + assembly); a **non-serialized** `ContainerConfig` for `6B2`; eligibility.
- Smoke seed: stage machined component LOTs (`6B2-MACH` + component) at the 6B2 Assembly Cell; an open `6B2` container; a couple of component LOTs in the Assembly IN queue (one pre-moved = "auto-coupled", one to scan in).

### 4.5 Tests
- **Assembly IN scan-in:** `Assembly_ScanIn` moves a component LOT into the cell queue; rejects a non-BOM-component LOT; queue ordering.
- **Tray-close consumption:** per-tray `ConsumptionEvent` per BOM component; sources decremented by `PartsPerTray × QtyPer`; `ProducedContainerId`/`TrayId` set; short-component rejects + full rollback; BOM-check.
- **Backward trace:** from a completed 6B2 container, the genealogy/consumption walk reaches the machined + cast ancestors.
- **Update** existing assembly tray-close/complete tests (`0028/020,040,050,060`) for the BOM-component model (their container item now needs a BOM + staged component LOTs).

## 5. Decisions (resolved 2026-06-24)
- **D1 — 6B2 assembly BOM.** RESOLVED: define a representative BOM now — `6B2 ← 6B2-MACH ×1 + 6B2-PIN ×2` (a mounting fastener). Remap to real MPP components later.
- **D2 — 6B2 cell + coupling.** RESOLVED: build the **uncoupled** (operator scan-in) path only. The coupled / PLC auto-move path is **deferred pending Jacques** — do NOT seed the coupling attribute or wire `MachiningOut_AutoComplete` in this work.
- **D3 — coarse gate.** RESOLVED: **remove** the recently-added item-agnostic tray-close availability gate; the precise per-BOM-component check in §4.2 supersedes it.

## 6. Risks
- `ContainerTray_Close` grows materially; the per-component FIFO consume + reject-rollback (inlined) is the main care-point. Validations before `BEGIN TRANSACTION`; `ROLLBACK` only in `CATCH`.
- Existing complete/ship tests assume tray close has no BOM consumption — they regress unless their container item gains a BOM + staged components (caught by the suite).
- Assembly IN is a new operator screen + a new movement proc; it must not rename the machined LOT (unlike Machining IN, which does).
