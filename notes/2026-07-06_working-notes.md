# Working Notes

**Date:** 2026-07-06
**Author:** Jacques Potgieter (working session)

---

## ✅ Resolution log — 2026-07-07 session (worked through all items)

Landed on `jacques/working` (after merging `origin/main`, which carried Hunter's
`97310ac` Route-Category cascade). Original prose below is preserved.

- **Op-Template filter → CATEGORY + Reset (§1–2):** DONE. Management filter dropdown
  repointed to `getOperationCategoriesForDropdown` / `filter.operationCategoryId`,
  `noSelectionText: "All Categories"` (the dropdown's clear `×` is the one-click reset);
  `OperationTemplate.search()` now filters by `operationCategoryId`
  (`OperationTemplate_List` already had the `@OperationCategoryId` param).
- **Creation popup cascade Category→Type (§3):** DONE. `NewOperationTemplate` popup gains a
  Category dropdown; the Operation dropdown cascades via new
  `OperationTemplate.getOperationTypesByCategory(catId)` and is gated until a category is
  chosen; a category with exactly one type (Die Cast) auto-selects it. No backend change.
- **Selection section order DieCast→Trim→M&A (§4):** DONE. `search()` orders category groups
  by `OperationCategory.Id` (1/2/3), not alphabetically.
- **Route config Category→Operation cascade (§5):** ALREADY BUILT on `main` (`97310ac`),
  now merged into `jacques/working`.
- **Stale `OperationAreaName` in `_mapSteps` (§6):** DONE. `RouteTemplate._mapSteps` no longer
  reads the dropped `OperationAreaName` (always `""`); it now surfaces
  `OperationCategoryName` / `OperationTypeName` from the v4.1 proc.
- **Terminal-FIFO rule + `CoupledDownstreamCellLocationId` (§7):** RESOLVED / OBE. The
  2026-07-07 terminal-mint redesign already answered every open question here: the WIP queue
  is now **route-driven** (`Lot_GetWipQueueByLocation` v3.0 keys off the next-pending route
  step's `OperationRoleKind`; `HasRenameBom` / `HasLineEvent` are gone), and
  `CoupledDownstreamCellLocationId` + `MachiningOut_AutoComplete` were **dropped** (migration
  `0036`). "Which terminal FIFO" = the terminal whose `OperationType` role matches the LOT's
  lowest-`SequenceNumber` pending route step. No further work; this note is historical.
- **Cascade-deprecate a part (§8):** DONE. `Parts.Item_Deprecate` v3.0 cascade-deprecates the
  part's owned config (RouteTemplate / Bom-as-parent / ItemLocation / ContainerConfig) and
  blocks ONLY on a live (non-terminal: not Closed/Scrap) LOT; a part used as a BomLine child
  in another BOM is neither blocked nor cascaded. Each cascade row gets its own audit row +
  the Item audit NewValue carries the counts. New tests `0008/020` (15 assertions, green).
  Item Master deprecate now routes through a `ConfirmDestructive` popup warning about the
  cascade (was an immediate, unconfirmed deprecate).

---

## Config — Operation Template management: type filter needs a Reset / Select-All

**Observation:** On the Operation Template management screen, the dropdown that filters
templates by **type** has no **Reset / Select-All** option. Once a type is picked there's no
single-click way to clear the filter and see all template types again.

**Wanted:** add a Reset / "All types" selection to that filter dropdown so the operator can
return to the unfiltered (all-types) view in one action.

**Notes for build:**
- Likely a placeholder-style "All types" option with `value: null` (mirrors the existing
  `(Unassigned)` vs "All Types" `value:None` dropdown ambiguity called out in the eligibility
  editors — pick a distinct sentinel so "show all" is unambiguous vs "no type").
- If the filter drives a bound list, the reset selection should clear the filter binding, not
  just the dropdown's own value.

## Config — Operation Template management: filter should be by CATEGORY, not type

**Correction to the above:** that filter dropdown should filter by **Operation Category**
(`Parts.OperationCategory`, the 3 groups), **not** by Operation Type (`Parts.OperationType`,
the 8 roles). Category is the right grain for filtering the template list.

**Wanted:** repoint the filter dropdown to the OperationCategory options (options sourced from
`Parts.OperationCategory`), and filter the template list by the selected category. The
Reset / "All categories" selection from the note above still applies — just at the category
grain.

## Config — Operation Template CREATION popup: type selection feels weird

**Observation:** the creation popup's single flat "operation type" dropdown (8 options) feels
awkward. **Idea (Jacques):** select the **category** first, then choose **In / Out** — is that
just a UI change, not a backend redesign?

**Assessment: UI-only, no backend change.** The Category→Type relationship already exists in
the schema (`Parts.OperationType.OperationCategoryId` FK → `Parts.OperationCategory`); a
cascading picker just reads those two tables and still stores the chosen `OperationTypeId` on
the template. Nothing in SQL/procs changes.

**But "In / Out" as the second step does NOT cover all categories uniformly** (the 8 types):
- **DieCast** → one type only (`DieCast`). No In/Out — category alone picks it (auto-select /
  no second step).
- **Trim** → `TrimIn` / `TrimOut`. ✓ the "In/Out" model fits cleanly.
- **Machining & Assembly** → FIVE types: `MachiningIn`, `MachiningOut`, `AssemblyIn`,
  `AssemblyOut`, **`CNC`**. Not a simple In/Out — CNC isn't In/Out at all, and you also need
  Machining-vs-Assembly.

**Recommendation:** do a **cascading Category → Type** picker where the second dropdown is
simply "the OperationTypes in the selected category" (filtered from `Parts.OperationType` by
`OperationCategoryId`). That delivers the progressive-disclosure feel Jacques wants, handles
all 3 categories with one uniform mechanism (DieCast shows 1, Trim shows 2, M&A shows 5), and
subsumes the "In / Out" framing without hardcoding it (In/Out is just how the Trim type names
read). Pure front-end change to the creation popup. Optional polish: auto-select + skip the
second step when a category has exactly one type (DieCast).

## Config — Operation Templates management: selection section category order

**Observation:** the selection section lists the categories out of order. **Wanted order
(categorical):** Die Cast → Trim → Machining & Assembly.

**Notes for build:** that is the category seed order (`Parts.OperationCategory` Ids 1/2/3 =
DieCast/Trim/MachiningAssembly, migration 0032), i.e. process flow, not alphabetical. Order the
selection list by the category's natural order — currently `OperationCategory.Id` gives it, but
a dedicated `SortOrder` column on `Parts.OperationCategory` would be the robust fix if we don't
want to lean on Id ordering. Whatever read feeds this section should `ORDER BY` that, not by
Name.

## Config — Route configuration: cascade Category → Operation for step selection

**Observation / wanted:** in Route configuration (the route-step operation picker), the first
dropdown should be **Operation Category** (not operation type). The dropdown next to it then
lists **all available operations for that category** for the actual operation selection.

**Notes for build:** same cascading pattern as the creation-popup note above — first dropdown
`Parts.OperationCategory`, second dropdown the OperationTemplates/Types available under the
selected category (filter by `OperationCategoryId`). The route step still persists the chosen
operation (`OperationTemplateId` / its `OperationTypeId`); this is a front-end change to the
route-step editor. Keep the Category list in the process-flow order (DieCast → Trim → M&A) per
the note above. NOTE: main just rebuilt the Routes tab on the BOMs-tab architecture
(`8e8c6ea`) — apply this against that new Routes implementation, not the old table-based one.

## Config — Route steps: stale `OperationAreaName` leftover from the operation-type restructure

**Observation (2026-07-07):** the operation-type restructure migrated the SQL but left the
Ignition script layer half-repointed. `Parts.RouteStep_ListByRoute` is at **v4.0** and already
returns `OperationTypeCode / OperationTypeName / OperationCategoryName` (Area was dropped), but
`BlueRidge.Parts.RouteTemplate._mapSteps` still reads `r.get("OperationAreaName")` into
`areaName` — a column the proc no longer emits, so that field is now always `""`. The route-step
picker `getOperationTemplatesByType` also still filters by a single OperationType / "all", and
does NOT offer Category as the grouping dimension the way the template-creation dropdown does.

**Why it matters:** route steps used to organize/display by the template's **Area**. The
restructure removed Area from the template, and **Category is its natural successor** for that
grouping slot — which is exactly the Category→Operation cascade wanted in the note above. So this
is the same thread: the data is already served (v4.0 proc), the front-end/script layer just
hasn't consumed it.

**Design guardrail to keep in mind while doing it:** Category is a *grouping/display* dimension
only — **OperationType stays the selection + runtime-resolution key** (the terminal resolver
`OperationTemplate_GetForRouteRole` matches on `OperationType.Code`, and Category is too coarse:
MachiningIn/Out, AssemblyIn/Out, CNC all share the one `MachiningAssembly` category). Use Category
to group/narrow the picker; never as the key a step or terminal binds to.

**TODO:** repoint the route-step display/picker off the dead `OperationAreaName` onto the v4.0
proc's `OperationCategoryName` / `OperationTypeName`; drop the `areaName` read in `_mapSteps`;
fold this into the Category→Operation cascade rework for the route-step editor (new BOMs-tab
Routes architecture, `8e8c6ea`).

## Plant floor — how does a line-resident LOT know which terminal FIFO to appear in? + `CoupledDownstreamCellLocationId` seems vestigial

**Observation (2026-07-07):** `CoupledDownstreamCellLocationId` is not surfaced anywhere in the
UI and its purpose is unclear. In the flow we actually run, **all inventory is checked into the
parent LINE** and operated against at the terminal (terminals zone UP to the line). Given that,
the puzzle: if a line has all 4 terminals (Machining IN/OUT, Assembly IN/OUT) and every LOT sits
at the same parent line (not at the 4 terminals), **what determines which terminal's FIFO a LOT
shows up in?**

**Answer (grounded in the built proc, not the FDS narrative):** `Lots.Lot_GetWipQueueByLocation`
(v2.0, 2026-07-06) returns **all open LOTs whose `CurrentLocationId` = the line** (exact match, or
subtree if `@IncludeDescendants=1`), ordered by arrival. It does NOT sort LOTs into 4 terminal
queues. It tags each LOT with two discriminators:
- `HasRenameBom` — the LOT's Item is the child of a 1-line rename BOM (a cast/trim part that
  renames to a machined part) → a Machining-IN candidate.
- `HasLineEvent` — a `Workorder.ProductionEvent` is already stamped to a terminal UNDER this line
  → the LOT has been worked here.

So **which terminal FIFO a LOT appears in is decided by `(Item stage) + (event state)`, NOT by
location and NOT by any coupling attribute.** Each terminal screen filters the line's WIP by its
`OperationType` role:
- Machining IN = LOTs at the line with `HasLineEvent=0` AND `HasRenameBom=1` (unworked arrivals);
  RecordPick stamps a ProductionEvent → `HasLineEvent` flips to 1 → LOT drops off the queue.
- Machining OUT = the machined-Item LOT, worked but not yet split/extracted.
- Assembly IN / OUT = machined-Item LOTs available to consume / the FG-completion point.

**The gap this exposes:** only Machining IN has a concrete, in-proc discriminator
(`HasLineEvent` + `HasRenameBom`). The finer 4-way split (Mach OUT vs Assembly IN vs Assembly OUT
— all dealing with the machined part at the same line) is NOT a single documented mechanism; it's
per-screen filtering on Item-stage + event-state. For a genuine 4-terminal line where the machined
part is the subject of three of those terminals, we do NOT currently have an explicit rule for
"which queue" — it's derived, and under-specified. **This needs settling.**

**`CoupledDownstreamCellLocationId` is a leftover of the CELL-resident topology.** Added in
migration `0019` (FDS-06-008) for the model where LOTs live at individual CELLS and auto-move
cell -> cell on PLC completion. Still wired into the PLC auto-complete path
(`Workorder.MachiningOut_AutoComplete`, `BlueRidge.Workorder.MachiningPlc`), but that path
presupposes cell-resident LOTs, whereas the manual flow we run is LINE-resident (all inventory at
the line). That mismatch is why it reads as purposeless and isn't in the UI — it belongs to a
topology the manual flow abandoned. Two models coexist uneasily.

**TODO / open design questions:**
1. Define the explicit "which terminal FIFO" rule for a full 4-terminal line where the machined
   part is the subject of Mach OUT + Assembly IN + Assembly OUT — what `(Item stage, event state,
   OperationType role)` predicate each terminal's queue filters on. Right now only Machining IN is
   concretely specified.
2. Decide the fate of `CoupledDownstreamCellLocationId` + the cell-resident auto-couple path
   (FDS-06-008): keep it (and reconcile with the line-resident model + surface it in the UI), or
   retire it as superseded by the line-resident identity/event-state discrimination.
3. Ties to the earlier note (consumption belongs to the consuming part's route/BOM) and the
   FDS-says-machined-created-at-IN vs build-mints-at-OUT divergence — all three are the same
   underlying question: **what is the canonical M&A line/terminal/identity model**, and does the
   FDS still describe it. Worth one consolidated design pass rather than piecemeal fixes.

## Config — a part with route templates (and other active dependents) can't be deprecated; it SHOULD be

**Observation / want (Jacques, emphatic):** an Item that has route templates **cannot** be
deprecated, but it **should** be — if I want to deprecate a part I should be able to, cascading
the dependents if that's what it takes.

**Grounding:** this is by-design guard-and-refuse. `Parts.Item_Deprecate` REJECTS deprecation
when the Item has ANY active dependent, with a specific message per case:
- active BOMs referencing it as **parent**;
- BOM **lines** referencing it as a **child** component (used in someone else's BOM);
- active **RouteTemplates** (the one hit here);
- active **ItemLocation** eligibility rows;
- active **ContainerConfig**.

**Wanted change (BACKEND, not UI-only):** flip `Item_Deprecate` from reject-on-dependents to
**cascade-deprecate** — deprecating the Item also soft-deletes its owned dependents.

**Key decision (don't cascade blindly):**
- **Natural children to cascade** (owned by this Item): its `RouteTemplate`s, `Bom`s where it's
  the parent, `ItemLocation` eligibility rows, `ContainerConfig`. These clearly go with the part.
- **The one that's NOT a child:** the Item used as a **BOM-line child in ANOTHER part's BOM**.
  Silently deprecating that would deprecate *other* parts' BOMs — almost certainly wrong. Options:
  still block on that specific case (with a clear "used as a component in X, Y" message), or warn
  and require confirmation. **Flag for a decision before build.**
- Audit every cascaded deprecation (stamp `DeprecatedAt` + audit rows) so it's traceable; the
  UI should confirm first ("this also deprecates N routes, M BOMs, …"). Soft-delete = recoverable,
  but there's no modeled "un-deprecate" flow — note that.

**REFINED RULE (Jacques):** the ONLY thing that should block deprecating a part is an
**active LOT** of that part. Everything else — RouteTemplates, BOMs, ItemLocation eligibility,
ContainerConfig — is config/definition and should **cascade-deprecate**, not block. Config
artifacts are just definitions; a live LOT is physical inventory/WIP on the floor, so that's the
one hard stop.

**Build shape for `Item_Deprecate`:**
- **Remove** the RouteTemplate / BOM-parent / ItemLocation / ContainerConfig rejection guards;
  cascade-deprecate those instead.
- **Add** a single hard guard: reject iff an active LOT exists for the Item —
  `EXISTS (SELECT 1 FROM Lots.Lot l JOIN Lots.LotStatusCode sc ON sc.Id = l.LotStatusId
  WHERE l.ItemId = @id AND sc.Code <> N'Closed')` (confirm whether Scrapped/other terminal
  statuses also count as "not active" — likely only non-terminal statuses block). Message e.g.
  "Cannot deprecate: active LOTs of this part still exist."
- The **BOM-line-as-child** case (part used as a component in ANOTHER part's BOM) from the note
  above is now moot as a *block* — but still decide whether deprecating the child should touch
  those foreign BOMs at all (probably leave them; they just reference a now-deprecated child).

