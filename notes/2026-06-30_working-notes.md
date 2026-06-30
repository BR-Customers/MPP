# Working Notes

**Date:** 2026-06-30
**Author:** Jacques Potgieter (working session)

---

## Plant Floor — Trim eligibility evaluating against terminal vs. parent

**Issue:** Moving a part into the Trim press fails — the Trim terminal reports the part as **not eligible**, even though its eligibility is set to the trim area. Question raised: is eligibility evaluated against the **terminal** itself, or the **parent** location the terminal presides over?

**Finding (code-traced):** It evaluates against the **parent**, by design — not the terminal location:
- The Trim view passes `session.custom.terminal.zoneLocationId` as the move destination (`TrimBody/view.json` ~line 329; the dedicated Trim/DieCast flavor views copy `zoneLocationId` into `session.custom.cell`).
- `zoneLocationId` resolves to the terminal's **immediate parent Location** — `Location.Terminal_GetByIpAddress` projects `p.Id = t.ParentLocationId AS ZoneLocationId`.
- `Lots.Lot_MoveToValidated` (step 4) gates on `Parts.v_EffectiveItemLocation WHERE ItemId = @ItemId AND LocationId = @ToLocationId` — an **exact LocationId match, no ancestor/descendant walk**. `Parts.ItemLocation_CheckEligibility` (the advisory UI read) matches the same way; its header states "Trim IN resolves at the Trim Shop Area."

**Likely root cause — tier mismatch:** the location where the eligibility (`Parts.ItemLocation` Direct) row was recorded ≠ the trim terminal's immediate parent (`zoneLocationId`). E.g. the terminal's `ParentLocationId` points at a Line/Cell *beneath* the Trim Area (so `zoneLocationId` = that line, not the Area), or eligibility was set on the Area while the parent is a Cell (or vice-versa). Because the match is exact, the recorded eligibility location must equal `zoneLocationId` precisely.

**Diagnostic next step (read-only against `MPP_MES_Dev`):**
1. Read the trim terminal's `ParentLocationId` + that parent's tier/name.
2. Check whether an Active `Parts.ItemLocation` row exists for (ItemId, that-parent-LocationId).
3. Compare to where eligibility was actually set.

**Fix candidates (pick after diagnostic):** (a) re-anchor the eligibility row to the terminal's parent tier; (b) re-parent the terminal under the correct Area; (c) design change — make eligibility resolution walk the hierarchy instead of exact-match. Ties into the terminal shared/dedicated flavor model.

---

## Design — Part type (`ItemType`) constrained to specific Areas

**Idea:** An Item's `Parts.ItemType` should constrain which production **Areas** (and therefore which routes/operations) it may flow through — e.g. a **Finished Good cannot be assigned a Die Cast route** (die cast produces raw castings, not finished goods).

**Context:** `Parts.ItemType` today (migration `0004`, Id-stable): 1 RawMaterial · 2 Component · 3 SubAssembly · 4 FinishedGood · 5 PassThrough. The constraint must cover all five, not just raw/passthrough/finished good. **Not designed or built today** — routes are currently assignable regardless of item type.

**Proposed mechanism:** Hold the "acceptable part types" on `LocationTypeDefinition` (LTD), maintained in the existing LocationTypeEditor Config-Tool surface. Add a `Rank` (ordinal) column to `Parts.ItemType`; the LTD edit UI selects a single threshold ("accepts part types {≥|≤} rank N") instead of multi-selecting types — collapses an N×N map to one number per location type.

**Open questions (for discussion before spec):**
1. **Comparison direction (the crux, undecided).** With ranks Raw < Component < SubAssembly < FinishedGood, the "Finished Good can't enter Die Cast" rule needs a **ceiling (≤)** on the LTD (accepts items not processed *past* this stage). A **floor (≥)** ("at least this far along") fits late areas (assembly won't take raw ingot) but does **not** keep a Finished Good out of Die Cast. *Recommendation: ceiling (≤), or both bounds (min + max) for a contiguous band.*
2. **PassThrough is orthogonal** to a linear rank — likely needs a special-case / always-accept.
3. **A single threshold assumes acceptable types are contiguous in rank** — confirm no LTD needs a non-contiguous set.

**Build note:** enforce in SQL (curated rank + threshold columns + proc check), never in Python/UI. Mirror the existing `Parts.ItemLocation` eligibility model. Formalize in FDS + Data Model; likely raise as an OI before build.

---

## Plant Floor — Die Cast LOT creation should land in the Warehouse, not the Area

**Issue:** On die-cast LOT creation, the new LOT should be moved into the **warehouse** location, NOT the die-cast area/cell.

**Context:** Die-cast LOT creation (`DieCastBody` → `BlueRidge.Lots.Lot.create`) currently stamps the new LOT's `currentLocationId` from `session.custom.cell.locationId` — i.e. the die-cast cell/area the terminal is bound to. So the LOT is born at the press area rather than in WIP/finished-goods warehouse storage.

**Fix candidate:** on create, set the LOT's location to the appropriate warehouse location instead of the die-cast cell — either by passing the warehouse `currentLocationId` to `Lot_Create`, or by a post-create move. Open question: *which* warehouse location, and how it's resolved (a fixed WIP/storage Location, or derived from the cell/area?). Needs a decision before build.

---

## LOT identifier — pre-printed LTT # vs. internally minted id (capture both)

**Issue:** On LOT creation the app currently **discards any entered LOT id and uses an internally minted one**. We need both options captured because the decision isn't made:
- **Option A — leverage the pre-printed LTT #** (the number already on the physical ticket). Pro: operator + Honda format continuity, no double-identity. **Unknown: where the pre-printed LTT numbers originate / who assigns them** — must understand their source before we can rely on them (uniqueness, format, collision risk).
- **Option B — internally minted id** (current behavior). Pro: gap-free, format-controlled, and likely **more performant** (sequential, controlled, no dependence on external scan input).

**Context:** The SQL seam for this already exists — `Lots.Lot_Create @LotName` (D4): when supplied, the id is used verbatim with no `IdentifierSequence` burn (duplicate/blank rejected); when NULL, the server mints (the current default the UI passes). So switching to Option A is a one-line flip (`lotName = scannedLtt`) with no rebuild. This is the open **D4 "is the pre-printed LTT # the canonical LOT id?"** question (was ⏳ pending MPP).

**Next step:** find out the origin/authority of the pre-printed LTT numbers (who/what prints them, format, uniqueness guarantee), then decide A vs B. Server-mint stays the default until decided.

---

## Plant Floor — LOT Detail history "x hours ago" over-precise

**Issue:** In LOT Detail, the history-item tab's "x hours ago" relative time shows far more precision than needed. Round it to the **hundredth** (2 decimal places).

**Context:** `Components/PlantFloor/LotDetail/HistoryRow/view.json` (~line 155) builds the label with `toStr(dateDiff({row.EventAt}, now(60000), "hour"))` — `dateDiff` returns a long fractional value, so `toStr` renders full precision (e.g. `3.847562h ago`). The minute/day branches have the same shape.

**Fix candidate:** wrap the fractional `dateDiff` value(s) in `numberFormat(..., "0.00")` (or `round(..., 2)`) so it reads e.g. `3.85h ago`. UI-only. Edit to an existing view → do in Designer per the file-edit boundary (or a careful file-level splice + `scan.ps1`).

---

## Plant Floor — Trim OUT should check LOTs into the LINE; terminals self-filter their FIFO queue by sort order

**Issue:** A machining/assembly line has N terminals beneath it. On Trim OUT a LOT is checked out of trim and into a FIFO queue for machining/assembly. **Currently the Trim-OUT dropdown moves the LOT into a specific terminal** (the line's "Machining In" receiving cell). It **should just check the LOT into the LINE**; then each terminal under the line decides whether to show the LOT in *its* FIFO queue based on the terminal's **location sort order** — a terminal at position *n* displays lots queued from position *n-1*.

**Context (current build):**
- `Location.Location_ListMachiningDestinations` (the Trim-OUT dropdown source) returns **Cell-tier (HL4) 'Machining In' terminals** — one receiving cell per line (e.g. `MA1-COMPBR-MIN` under WorkCenter line `MA1-COMPBR`). `Workorder.TrimOut_Record` (whole-LOT move) deposits the LOT at that specific cell.
- Machining IN (Phase 5) reads the queue via `Lots.Lot_GetWipQueueByLocation(locationId, includeDescendants)` from that cell.
- So today the destination is the terminal/cell, **not** the line.

**Proposed change:**
- Trim OUT deposits the whole LOT at the **LINE** (WorkCenter / ProductionLine, HL3), not a specific terminal cell. The OUT dropdown lists lines, not Machining-In cells.
- Each terminal under the line derives its FIFO queue from the line's lots using the terminal's **SortOrder** (n-1 rule): a terminal at sequence position *n* shows lots whose progress sits at the prior station's output (position *n-1*). Likely `Lot_GetWipQueueByLocation` reads at the line (with descendants) and routes/filters by terminal sort order.

**Open questions / dependencies:**
- **Does `Location.Location` carry a `SortOrder`?** The mechanism needs a per-terminal sort order under the line. Current schema has `SortOrder` on `LocationAttributeDefinition` (not confirmed on `Location.Location`) — may need a schema add.
- Exact semantics of the n-1 rule: what "previous station's output" maps to in a lot's location/status, and how a lot advances terminal-to-terminal along the line.
- This reconciles/replaces the `Location_ListMachiningDestinations` "Machining In cell" model and the Phase-4 owed note that the OUT dropdown should be machining-line-scoped.

---

## Validation — does Trim OUT have a location eligibility check? → YES

**Answer:** Yes. `Workorder.TrimOut_Record` step 5 (~lines 137-150) rejects with *"Item is not eligible at the destination location"* when `NOT EXISTS (SELECT 1 FROM Parts.v_EffectiveItemLocation WHERE ItemId = @ItemId AND LocationId = @DestinationCellLocationId)`. Same **exact-LocationId match, no hierarchy walk** as `Lots.Lot_MoveToValidated`. (No MaxParts at Trim OUT — Confirm B: it's a FIFO deposit, not a lineside cap.)

**Implication for the "deposit at the LINE not the terminal" change above:** the eligibility check runs against `@DestinationCellLocationId`. If Trim OUT switches to depositing at the LINE (HL3), an eligibility row would have to exist at the *line* location — or the check would need adjusting. Same exact-match caveat as the Trim-IN "terminal vs parent" item above. Cross-reference both when designing the line-deposit change.

---

## Plant Floor — Trim OUT should offer a selectable FIFO queue, restricted to the terminal's parent location

**Issue:** Trim Station Trim OUT should present a **selectable FIFO queue of the LOTs currently at that location** to pick from, and should **only allow moving LOTs that are at the terminal's parent location** (the area the terminal presides over).

**Context (current build):** `TrimBody` Trim OUT is **scan-only** — `view.custom.outScan` → `resolveOutScan()` → `BlueRidge.Lots.Lot.getByName(code)` resolves the LOT by its scanned LTT. There is **no queue to pick from**, and **no check that the resolved LOT is actually at this terminal's location** — any valid LTT resolves regardless of where the LOT physically sits.

**Proposed change:**
- Drive a selectable FIFO list from `Lots.Lot_GetWipQueueByLocation(locationId)` at the terminal's parent location (`session.custom.terminal.zoneLocationId`) — operator selects from the queue instead of (or in addition to) scanning.
- Gate the OUT action so only LOTs whose `CurrentLocationId` = the terminal's parent location can be trimmed-out; reject a scanned LTT that isn't at this location rather than resolving it as the active LOT.

**Cross-refs:** consistent with the "terminal presides over its parent (zoneLocationId)" finding and the Trim-OUT eligibility validation above. `Lot_GetWipQueueByLocation` is the existing read for the queue.

---

## Plant Floor — Machining IN appears to double-consume / double-create (duplicate LOT) 🐞

**Observation:** Picking a LOT in Machining IN appeared to: consume the picked LOT, create another LOT, then *immediately* create yet another LOT consuming that intermediate one. Suspected duplicate — unclear whether there's a consumption event at the end of Trim OUT that shouldn't be there, plus the one at Machining IN that should be (= the duplicate).

**Findings (code-traced 2026-06-30, no DB diagnostics run):**
- **Trim OUT does NOT consume or create a LOT.** `Workorder.TrimOut_Record` only writes a closing `ProductionEvent` checkpoint + a whole-LOT move; **no `ConsumptionEvent`, no new LOT, no genealogy**. So the "consumption event at the end of Trim OUT" hypothesis isn't supported by the proc — the duplicate is on the Machining-IN side.
- **Machining IN legitimately does ONE consume + ONE create per pick, by design.** `Workorder.MachiningIn_PickAndConsume` atomically: mints a new machined LOT (BOM rename), writes a `ConsumptionEvent` (source→produced), genealogy edge + closure, a `MachiningIn` checkpoint, and **closes the source LOT**. One pick = one consume + one create is expected, not a bug.
- **Likely cause of the *duplicate* — the machined output lands back in the same Machining-IN queue.** The minted machined LOT is inserted with `CurrentLocationId = @CellLocationId` (`R__Workorder_MachiningIn_PickAndConsume.sql` line ~320) — i.e. the **same** Machining-IN cell it was just picked from. So it immediately reappears in that cell's FIFO queue (`Lot_GetWipQueueByLocation(@CellLocationId)`) and is re-pickable. A second pick (auto-refresh re-pick, double-tap/double-fire of the handler, or a BOM-rename chain where the machined Item is itself a child in another active BOM at that cell) would then consume the just-minted LOT and create another — exactly the observed "consume → create → immediately consume the intermediate → create another."

**Hypotheses to check (next session):**
1. Where *should* the machined LOT land? It probably should move to a Machining **OUT / WIP** location, not stay at the Machining-IN cell. If it stays, it pollutes the IN queue and invites re-pick.
2. Is the UI handler double-firing (scope, double-tap, queue auto-refresh re-selecting)?
3. Does the machined Item resolve as a child in a second active BOM (rename chain)?

**Resolution (Jacques, 2026-06-30): handle via the planned line-deposit + terminal/action filtering change — not as a standalone fix.** This is subsumed by the *"Trim OUT → deposit at the LINE, not the terminal cell"* + *terminals filter selectable LOTs by terminal + action* change (see the note above). Under that model, LOTs live at the **line** and each terminal/action surfaces only the LOTs valid for it, so a just-machined **output** LOT will not reappear as a selectable Machining-**IN** input — the re-pick/duplicate cannot occur. The hypotheses above (post-pick destination = `@CellLocationId`, re-entrancy) become moot once selection is filtered by terminal + action against line-resident LOTs. Track + verify this as part of that design work, not separately.

---

## Plant Floor — Auto-open the next container at an assembly line (no operator push)

**Goal:** an assembly (and machining) line should always have a container available; the operator should never have to manually open the first/next container.

**Assembly OUT process (current build, Phase 6) — for context:** a Container is the shippable packaging unit, opened **at a Cell** (`Lots.Container.CurrentLocationId`). Lifecycle:
1. **Open** — `Lots.Container_Open(@ItemId, @ContainerConfigId, @CellLocationId, …)` → status Open. **Operator action today.**
2. **Scan components in** — `Assembly_ScanIn` moves machined component LOTs into the cell queue (consumed at the fill).
3. **Close trays** — `Lots.ContainerTray_Close(...)` per tray; each writes a `ConsumptionEvent` per BOM component (FIFO-decrements source LOTs) + accumulates parts. Produced side is the container (no output LOT).
4. **Complete** — `Lots.Container_Complete(...)` when accumulated ≥ `TraysPerContainer × PartsPerTray`; enforces `RequiresCompletionConfirm` (OI-16), claims an AIM shipper id (FIFO), writes the ShippingLabel, flips to Complete.
5. **Ship** — `Lots.Container_Ship`.
- `Lots.Container_GetOpenByCell(@CellLocationId)` already answers "does this cell/line have an open container?".

**Decision (Jacques, 2026-06-30) — Approach A (event-driven):**
- **Open the next container the moment the current one completes** — `Container_Complete` triggers opening the next container for the same cell/line (in-txn or immediate follow-on). Primary mechanism, zero steady-state polling.
- **Backstop:** a slow **Ignition Gateway timer** (~30–60s, scope G) calls a thin proc (e.g. `Lots.Container_EnsureOpenForCell` / `…ForActiveLines`) that opens a container at any active assembly line/cell that has none — covers cold start / missed events. **Gateway timer + proc, NOT a SQL Server Agent job** (stack convention: timers like `ShiftBoundaryTicker`/`PartitionMaintenance`; business logic stays in SQL).
- **Attribution:** auto-created containers are attributed to a dedicated **`system` AppUser** (not a real operator). Couples with the already-owed "seed a dedicated system AppUser before cutover" item in PROJECT_STATUS.

**⚠️ Open question (unresolved) — what determines the next container's `@ItemId` + `@ContainerConfigId`?** Auto-open must know which part the line is currently producing — a work order / schedule, the in-process LOTs feeding the cell, or a per-line "currently running" setting. Easy if a line runs one part at a time; ambiguous if mixed. **Must resolve before build.**

**Cross-refs:** couples with the line-vs-cell theme (is the container anchored at the *line* or a specific assembly *cell/terminal*?). Don't auto-*complete* — only auto-*open* (completion keeps its OI-16 confirm gate).
