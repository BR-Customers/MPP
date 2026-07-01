# Line-Resident Lots + Route-Driven Terminal Queues — Design Spec

**Date:** 2026-07-01
**Author:** Blue Ridge Automation (Hunter)
**Status:** Design — reviewed. **Blocked on OQ-COUPLE + the FDS-05-009 incremental-split addition** — needs architecture + MPP sign-off before build. No code changes have been made.
**Scope tag:** MVP-EXPANDED (Arc 2 — Machining/Assembly, Plant Floor)
**Bundles:** #7 (Trim-OUT line-deposit + terminal self-filtering), #6 (selectable FIFO restricted to the terminal's parent), and dissolves the Machining-IN re-pick duplicate by construction.

---

## 1. Problem & goal

Trim OUT currently deposits a whole LOT into **one specific Machining-IN cell**, and each machining/assembly station reads its queue from its own cell. That forces the operator to pick a destination terminal, lets a just-machined output LOT reappear in the same Machining-IN queue it came from (the observed **duplicate**), and can't represent lines with multiple same-op terminals, optional MachiningOut, multi-station assembly, or parallel A/B cells.

**Goal:** LOTs live at the **LINE** (WorkCenter); each terminal derives its FIFO queue from the item's **route** — a terminal shows the line's lots whose *next required operation* is the one that terminal performs. The flow works uniformly across every real line shape (including `MA2-RPYCAM2`, the RPY Line 2 Cam Holders), and the duplicate cannot occur.

---

## 2. Decisions locked in

| # | Decision | Rationale |
|---|---|---|
| D1 | **Lots live at the line** (`CurrentLocationId` = WorkCenter) for in-process machining/assembly WIP | Shared pools + route-driven queues; dissolves the duplicate; station trail preserved in `ProductionEvent.TerminalLocationId`. Cast/warehouse lots unaffected. |
| D2 | **Route-driven queue key** — the item's published route is the authoritative op sequence; a terminal shows lots whose *next route op* = its op | Authoritative, per-item, config-authored, FDS-aligned (FDS-03-008/009). Handles multi-station assembly; replaces the terminal-SortOrder op-chain. |
| D3 | **Container per assembly cell**, consuming from the cell's parent **line** | Container anchors at the cell for station identity, draws inputs from the line pool. |
| D4 | **Within-WorkCenter coupled move becomes redundant** — line-resident advances the lot in place (proposes revising FDS-06-008; see §11 OQ-COUPLE) | The coupled cell is a sibling within the same WorkCenter, so under lots-live-at-line the move is redundant. 0 configured today. |
| D5 | **Parallel same-op cells share one FIFO pool** (incl. A/B side cells) — no pinning, no lane dimension | Confirmed with the floor: `MA2-RPYCAM2` MIN-A/MIN-B, MOUT-A/MOUT-B, AOUT1/2/3 are **parallel capacity**, so "collapse by op → shared pool" is correct, not a compromise. |
| D6 | **Auto-advance is display-only** — no physical machining→assembly move | Completing an op advances the lot's route position; the next station's queue picks it up. |
| D7 | **Three MachiningOut modes** — atomic split-and-close, **incremental draw-down**, PLC auto-move | Some lines peel sub-lots one at a time from a parent until it's empty (incremental), not all-at-once. New mode; see §5.6. |

---

## 3. The model (route-driven)

### 3.1 Definitions
- **Line** — a WorkCenter location; a lot's `CurrentLocationId` while in machining/assembly WIP.
- **Route** — the item's *published* `RouteTemplate`: ordered `RouteStep`s, each referencing an `OperationTemplate`. **For this design the machining/assembly route steps reference the *station checkpoint* ops** (`TrimOut`, `MachiningIn`, `MachiningOut`, `AssemblyIn`, `AssemblyOut`) — the same ops written to `ProductionEvent` — so a lot's events can be matched to its route position. (See P-A, the alignment prerequisite.)
- **CompletedOps(lot)** — the distinct `OperationTemplateId`s on the lot's **own** `ProductionEvent` rows.
- **NextOp(lot)** — the first `RouteStep` (by `SequenceNumber`) of the lot's item route whose op ∉ `CompletedOps(lot)`. Null when the route is complete.
- **Terminal op** — the op a terminal performs, resolved from its assigned view (`DefaultScreen` → op via the view→op registry, per FDS-02-010).

### 3.2 The one rule
> A terminal's FIFO queue = the **line's open lots** (`CurrentLocationId` = the terminal's line) whose **`NextOp` = the terminal's op**, ordered by line-arrival time. A multi-action terminal shows the **union** over its ops, each row tagged with which op it's queued for.

No per-line op-chain, no SortOrder-predecessor — the route supplies the sequence per lot. `SortOrder` is no longer load-bearing for queue routing (it survives only for display ordering / the trim-side #6 gate).

### 3.3 Why this handles every shape — worked on `MA2-RPYCAM2` (RPY Line 2 Cam Holders)
Stations: `MIN-A`, `MIN-B` (parallel MachiningIn) · `MOUT-A`, `MOUT-B` (parallel MachiningOut) · `AIN` (AssemblyIn) · `AOUT1/2/3` (parallel AssemblyOut). Cam-holder route (machining/assembly portion): `TrimOut → MachiningIn → MachiningOut → AssemblyIn → AssemblyOut`.
- A trim-deposited lot has completed `TrimOut` → NextOp `MachiningIn` → shows at **both** `MIN-A` and `MIN-B` (shared pool; first pick closes the source, P4).
- After MachiningIn → NextOp `MachiningOut` → shows at both `MOUT-A`/`MOUT-B`.
- After MachiningOut → NextOp `AssemblyIn` → shows at `AIN`.
- After AssemblyIn → NextOp `AssemblyOut` → shows at all three `AOUT`s (shared pool, each with its own container).
- **Multi-station assembly** falls out because the route enumerates `AssemblyIn`/`AssemblyOut`. **Parallel A/B** falls out because parallel cells share the op's pool (D5). **Duplicate** is impossible: once `MachiningIn` is in the lot's CompletedOps, its NextOp is `MachiningOut`, so it can't reappear in the MIN queue.

Other shapes: a **no-MOUT** line's item route simply omits `MachiningOut` (`… MachiningIn → AssemblyIn …`), so the machined lot's NextOp is `AssemblyIn` and it advances to assembly with no move (D6). Multiple parallel MINs (`MA2-5PA`) share the `MachiningIn` pool.

### 3.4 FDS conformance
| Requirement | Status | Note |
|---|---|---|
| **FDS-03-008 / 03-009** — routes are ordered operation steps; steps reference an operation template, not a machine | **Upholds** | The route *is* the queue sequence; cell selection stays eligibility-driven. |
| **FDS-03-013** — operation templates drive screen behavior | **Upholds** | Terminal op = its view/op template. |
| **FDS-02-009** — machining/assembly tracked at **line resolution** | **Upholds** | Basis for lots-live-at-line. |
| **FDS-02-010** — terminal behavior follows its assigned view; no stored terminal-mode | **Upholds** | Op is view-driven, no new attribute. |
| **FDS-06-006** — Trim OUT deposits into the **line's** FIFO queue | **Upholds** | Restores current-code deviation. |
| **FDS-06-007** — each **Cell** surfaces its own queue | **Proposes to revise** | Queue derives from the line by route position. |
| **FDS-06-008** — non-sublotting lot **auto-moves to the coupled Assembly Cell** | **Proposes to revise** | Within-WorkCenter move is redundant under line-residence (OQ-COUPLE). |
| **FDS-05-009** — MachiningOut split is an **all-at-once even split** | **Proposes to extend** | Adds the **incremental draw-down** mode (D7 / §5.6). |
| **FDS-03-008 (routes coarse today)** — routes currently reference area-level product ops | **Proposes to revise** | Routes must reference the **station** ops so events ↔ route align (P-A). |

The "propose to revise/extend" rows are **normative deviations** needing architecture + MPP sign-off before build (tracked in §11 — not filed as an OI per instruction).

---

## 4. Data model changes
1. **Routes reference station ops (the alignment prerequisite, P-A).** Route steps for the machining/assembly portion reference `TrimOut`/`MachiningIn`/`MachiningOut`/`AssemblyIn`/`AssemblyOut` — the ops written to `ProductionEvent` — so `NextOp` is computable. Requires re-authoring routes off the coarse product ops (`CNC-5G0`, `ASSY-FRONT`, …).
2. **New `AssemblyIn` / `AssemblyOut` operation templates.** They don't exist today (only `MachiningIn/Out`, `Trim*`, `DieCastShot`). Needed so the multi-station assembly is route-representable and the stations can stamp events.
3. **Terminal → op: view-driven (FDS-02-010).** A small **view→op registry** (code table over the finite MPP per-workstation screen list) maps `DefaultScreen` → op. No `StationOperationCode` attribute.
4. **MachiningOut mode config (D7).** Replace the `OperationTemplate.RequiresSubLotSplit` BIT with a small enum — `AtomicSplit | IncrementalDrawDown | AutoMove` — carried per line (or per the MachiningOut route step). Determines which §5.6 path runs.
5. **No lot position column.** `NextOp` is derived from route + the lot's own events.
6. **`ProductionEvent` index (NEW).** For "ops completed per lot": index `(LotId)` INCLUDE `(OperationTemplateId, EventAt)`.
7. **`CoupledDownstreamCellLocationId` — dormant.** Within-line advance replaces it; keep nullable, document cross-line coupling as a future add (OQ-COUPLE).
8. **Line-arrival timestamp for FIFO** — `COALESCE(first LotMovement into this line, CreatedAt)`; no new column.

---

## 5. Component design

### 5.1 `Lots.ufn_LotNextOp(@LotId)` (NEW, inline TVF/scalar)
Given a lot → its item's published route steps (ordered) minus the ops already in the lot's `ProductionEvent`s → returns the next required op code (+ its OperationTemplateId), or null when complete. One place the route-position logic lives; consumed by the queue read.

### 5.2 `Lots.Lot_GetLineQueueForOp(@LineLocationId, @StationOpCode)` (NEW read)
Open lots at the line whose `ufn_LotNextOp` = `@StationOpCode`, FIFO by line-arrival. Returns lot + its next op (for multi-action labeling). Replaces `Lot_GetWipQueueByLocation` for machining/assembly screens.

### 5.3 `Workorder.TrimOut_Record` (CHANGE)
Destination → the **operator-selected line** (`@DestinationLineLocationId`); `Lot.CurrentLocationId = line`. The operator **still picks the destination at Trim OUT — but a *line*, not a specific Machining-IN cell** (which cell/station surfaces the lot afterward is decided by the route, §3.2). This is the operator-selected path of FDS-06-006; we do **not** auto-select the line by routing. Eligibility already cascade-aware (line→area→site). Still writes the `TrimOut` `ProductionEvent` (which becomes the "completed" step that makes NextOp = `MachiningIn`). Dropdown source → §5.4.

### 5.4 `Location.Location_ListMachiningLines` (REPLACES `Location_ListMachiningDestinations`)
Returns WorkCenter **lines** (not `Machining In` cells), filtered to lines that (a) have a `MachiningIn` station and (b) the trimmed item is eligible at (via the cascade). Feeds the Trim-OUT dropdown that the **operator picks from** — one choice, at line granularity. (Scan-a-line-barcode MAY be offered too, but a pick is required; the operator never picks a cell.)

### 5.5 `Workorder.MachiningIn_PickAndConsume` (CHANGE)
Mint the machined LOT with `CurrentLocationId = <the line>` (resolve line = the picking terminal's nearest WorkCenter ancestor). Keeps writing the `MachiningIn` event (→ NextOp advances to `MachiningOut`). Source close unchanged. Half the dup fix; the route queue is the other half.

### 5.6 `Workorder.MachiningOut` — three modes (D7)
Which mode runs is config (§4.4):
- **AtomicSplit** (existing `MachiningOut_RecordSplit`): one action, N children (`SUM == parent`), parent stamped `MachiningOut` + **closed**. Children born at the **line**, each stamped `MachiningOut` (→ NextOp `AssemblyIn`).
- **IncrementalDrawDown** (NEW proc — a *partial* `Lot_Split` at MachiningOut): peel **one** child per call; parent stays **open**, count decremented; **do NOT stamp `MachiningOut` on the parent** (so its NextOp stays `MachiningOut` and it **stays in the MOUT queue**); each child born at the line, stamped `MachiningOut` (→ Assembly). When the parent hits zero pieces → close it (it leaves the queue). "Move to the next in queue" is just the shared FIFO advancing.
- **AutoMove** (existing `MachiningOut_AutoComplete`): no operator, no physical move under line-residence; write the `MachiningOut` event **only if `MachiningOut` is in the item's route** (P14). On no-MOUT routes it writes nothing and the lot advances to `AssemblyIn`.

**Child-carries-completion rule:** the op that advances a lot to Assembly is stamped on the **child** that goes there; the incremental parent is never self-stamped `MachiningOut` while open.

### 5.7 Assembly stations + events (NEW)
`AssemblyIn` and `AssemblyOut` stations write their `ProductionEvent`s (they write none today). `AssemblyIn` marks a lot's arrival at assembly (→ NextOp `AssemblyOut`); `AssemblyOut` is the consume-into-container step (§5.8). This is what lets the multi-station assembly queue advance.

### 5.8 `Lots.ContainerTray_Close` (CHANGE)
The `AssemblyOut` consume step. Consume source component lots from the container cell's **parent line** whose `NextOp = AssemblyOut` and item = the BOM child — was `WHERE l.CurrentLocationId = @Cell`. Resolve line = the container cell's nearest WorkCenter ancestor. FIFO by line-arrival.

### 5.9 `Workorder.Assembly_ScanIn` (BECOMES the AssemblyIn step, or retires)
Either repurpose as the `AssemblyIn` station action (writing the `AssemblyIn` event) or retire if AssemblyIn is implicit. No more physical move — the lot's already at the line.

### 5.10 Views
- **Trim OUT:** dropdown lists lines (§5.4); OUT deposits at the line. **#6** (FDS-06-007 / FDS-02-009 scan-or-pick): operator MAY **scan an LTT** OR **select from a FIFO queue** of lots at the trim terminal's parent — one gate that only lets lots physically there trim out. Operator queue-order override allowed.
- **Machining-IN / -OUT / Assembly-IN / -OUT:** queue read = `Lot_GetLineQueueForOp(line, <this screen's op>)`; multi-action terminals show the union with per-row op labels. MachiningOut screen exposes the configured mode's action (atomic split dialog vs. incremental peel-one).

### 5.11 Route authoring
Engineering authors station-level routes in the **existing route editor** (versioned Draft/Published, CRUD + reorder already built). The machining/assembly portion uses the station ops. Seed the demo lines (5G0, 6B2, RPY cam) with station-level routes.

---

## 6. Worked scenarios
- **Sc1 `MA1-5GOF` (MIN→MOUT→ASER):** route `… MachiningIn → MachiningOut → AssemblyIn → AssemblyOut`. Trim→line (TrimOut done, NextOp MachiningIn) → MIN pick, mint at line (NextOp MachiningOut) → MOUT → AssemblyIn → AssemblyOut consume.
- **Sc2 `MA1-COMPBR` (no MOUT):** route omits MachiningOut; machined lot NextOp = `AssemblyIn`; auto-advance, no move, no MachiningOut event.
- **Sc3 `MA2-5PA` (parallel MINs):** all MINs share the NextOp=`MachiningIn` pool; first pick wins (P4).
- **Sc4 multi-action terminal:** union of its ops' queues, per-row labeled.
- **Sc5a MOUT atomic split:** parent stamped+closed; N children (NextOp AssemblyIn) → assembly.
- **Sc5b MOUT incremental draw-down (D7):** parent stays in MOUT queue (open, not self-stamped); each peel mints one child (NextOp AssemblyIn); parent closes when empty; queue advances to the next lot.
- **Sc6 duplicate:** machined lot has `MachiningIn` in CompletedOps → NextOp `MachiningOut` → never in the MIN queue.
- **Sc7 coupled line:** none configured; within-line advance covers it.
- **Sc8 `MA2-RPYCAM2`:** full multi-station + parallel A/B walk in §3.3.

---

## 7. Pitfalls & solutions

**P-A — Route↔event op-alignment (the critical prerequisite).** Today routes reference coarse product ops (`CNC-5G0`) while events record station ops (`MachiningIn`) — different `OperationTemplate` rows, so `NextOp` can't be computed by matching events to route steps.
*Solution:* re-author machining/assembly routes to reference the **station ops** (§4.1). Deprecate or repurpose the coarse product ops. This is the gating build item — nothing works without it.

**P-B — Missing assembly ops.** No `AssemblyIn`/`AssemblyOut` OperationTemplates exist; assembly writes no events.
*Solution:* create the two ops (§4.2) and have the assembly stations stamp them (§5.7). Without events, an assembly lot's NextOp never advances past `AssemblyIn`.

**P-C — Incremental parent self-evicts (D7).** If `IncrementalDrawDown` stamps `MachiningOut` on the open parent, its NextOp advances and it drops out of the MOUT queue after the first peel.
*Solution:* the child-carries-completion rule (§5.6) — stamp `MachiningOut` only on children; the open parent leaves the queue only by being closed (drawn empty). **Acceptance test required.**

**P1 — Route-execution state is empty scaffold.** `WorkOrder`/`WorkOrderOperation` have 0 rows (Work Orders are CONDITIONAL), so we can't use them for NextOp.
*Solution:* derive NextOp from the item's published route + the lot's own `ProductionEvent`s (§5.1). If Work Orders are later lit up, `WorkOrderOperation` gives explicit per-step status and can supersede the derivation.

**P4 — Concurrency: two parallel same-op cells grab the same lot.**
*Solution:* the mutation proc re-reads lot status inside its transaction and rejects a Closed/consumed lot cleanly; the UI refreshes. Never trust the stale queue row.

**P5 — NextOp derivation cost.** Computing completed-ops per lot on every refresh, on the append-only `ProductionEvent`.
*Solution:* the §4.6 index; scope to open lots at the line (tiny set); if it bites, materialize `Lot.NextOpCode` maintained by the station procs (a deliberate perf step, not the model).

**P6 — Unmapped screen / unrouted item ⇒ empty queue.** A terminal whose `DefaultScreen` isn't in the view→op registry, or a lot whose item has no published route, can't be placed.
*Solution:* seed the registry for every workstation screen + validate; require a published route for any item that reaches Trim OUT; a health-check flags both. Fail loud.

**P7 — Orphan lots.** A lot whose NextOp names an op with no terminal on its current line.
*Solution:* an "unrouted lots at this line" diagnostic/supervisor view + alarm past a threshold; nothing is silently lost.

**P8 — Eligibility tier mismatch.** Line-deposit eligibility needs line/area-tier rows.
*Solution:* the cascade (landed) walks line→area→site; verify/seed eligibility at the right tier; a check proc reports items configured only below the line.

**P9 — Multiple assembly cells share the line pool.** Confirmed **intended** (D5, parallel capacity) — shared FIFO. Resolve "line" as the **nearest WorkCenter ancestor** of the container cell (not the immediate parent). A future reservation layer only if a line ever needs pinning.

**P10 — Serialized assembly.** Per-piece PLC consumption is orthogonal; op-route governs only the lot queue. Keep the layers separate.

**P11 — Trim-OUT dropdown scope.** `Location_ListMachiningLines` filters to lines with a `MachiningIn` station + item eligibility.

**P12 — In-flight WIP migration at cutover.** Existing lots sit at cells.
*Solution:* one-time migration moving open machining/assembly lots to their line + relying on their events for NextOp; or a drained cutover. Ship the script + a WIP report. (FDS §14 treats in-flight-WIP-with-location migration as normal.)

**P13 — The cell-vs-line "muddle."** Views bind `cell = zoneLocationId (= line)` while procs use the cell.
*Solution:* audit every machining/assembly location read → all line-based in one pass; grep-gate in review.

**P14 — AutoMove writing MachiningOut off-route.** If `AutoMove` stamps `MachiningOut` on a lot whose route has no MachiningOut step, its NextOp can't be computed cleanly.
*Solution:* AutoMove stamps `MachiningOut` **only if the item's route contains it**; otherwise nothing (the lot's NextOp is already `AssemblyIn`). The route is the single source of truth for which ops occur.

**P15 — Re-versioning a route mid-flight.** Publishing a new route version changes NextOp for in-flight lots.
*Solution:* NextOp resolves against the route version the lot is on (or the item's active published route with documented semantics); warn on publish that it affects live queues.

**P16 — FIFO ordering for minted vs deposited lots.** `COALESCE(first LotMovement into this line, CreatedAt)`, tie-break `Id`; tested.

**P17 — Genealogy/audit granularity.** Line-level `CurrentLocationId` is coarser than cell; the station trail lives in `ProductionEvent.TerminalLocationId` + `ConsumptionEvent.LocationId`. Document that a WIP lot's "physical where" = its last station event, not `CurrentLocationId`.

---

## 8. Testing strategy
- **ufn_LotNextOp:** correct next op across routes (with/without MachiningOut; multi-station assembly); complete-route = null.
- **Lot_GetLineQueueForOp:** each station sees exactly its NextOp lots across Sc1–Sc8; multi-action union labeling.
- **Route↔event alignment (P-A):** a lot's events resolve against its route steps.
- **Dup dissolution (Sc6);** **incremental parent (P-C):** parent persists across peels, children go to assembly, parent closes at empty and leaves.
- **AutoMove off-route (P14);** **concurrency (P4);** **assembly consume-from-line (§5.8);** **migration (P12).**
- Non-destructive `test.*` framework; cascade-style rolled-back harness for read-only checks.

## 9. Rollout / order of work
1. New `AssemblyIn`/`AssemblyOut` ops + view→op registry.
2. Re-author machining/assembly routes to station ops (P-A) + seed demo lines.
3. `ufn_LotNextOp` + `Lot_GetLineQueueForOp` + index.
4. Trim OUT → line + `Location_ListMachiningLines`.
5. MachiningIn mint-at-line.
6. MachiningOut mode enum + incremental draw-down proc + AutoMove/atomic route-alignment.
7. Assembly stations write events; `ContainerTray_Close` consume-from-line.
8. Views (machining/assembly queues + Trim-OUT dropdown + #6).
9. Migration script + WIP report. Tests throughout.

## 10. Out of scope / deferred
- Cross-line coupling (a real move) — nothing configured.
- A reservation/pinning layer (parallel cells share pools per D5).
- Work-Order-backed route execution (`WorkOrderOperation`) — CONDITIONAL scope.
- Die-cast → warehouse change (#4) — separate spec.

## 11. Open questions

**Resolved:**
- ~~terminal→op modeling~~ → view-driven (FDS-02-010).
- ~~operator MachiningOut without sub-lotting~~ → covered by the three modes (D7).
- ~~#6 input model~~ → scan + selectable FIFO, gated to parent.
- ~~A/B lane pairing~~ → parallel capacity, shared pool (D5) — no lane dimension.

**Still open:**
- **OQ-COUPLE.** Line-residence makes FDS-06-008's within-WorkCenter coupled move redundant, and this design also **extends FDS-05-009** (incremental draw-down) and **revises route granularity** (station-level routes, P-A). All need architecture + MPP sign-off before build. FDS-02-009/03-008/03-009 are the supporting basis.
- **OQ3 — cutover (P12).** Drained boundary vs. live cell→line migration of in-flight WIP.
- **OQ5 — MachiningOut mode config placement.** Per line vs. per MachiningOut route step — which config surface owns the atomic/incremental/auto-move choice (§4.4)?
