# Blast radius — `Lots.Lot.EntryRouteSequence` (inventory cutover scan-in)

**Date:** 2026-09-12
**Context:** Cutting MPP inventory over line-by-line by physically scanning baskets at
Machining IN / Assembly IN (legacy `MES` on `EXCSRV05` has no usable LOT/qty records).
A migrated LOT must not appear in the queues for route steps that happened before it
entered our system. Chosen mechanism (over synthetic `ProductionEvent` rows): a
nullable LOT-level entry point.

---

## 1. The finding that dominates everything else

The "is this route step pending?" predicate is **not** centralised. It is literally
copy-pasted **7 times across 5 procs**:

| Proc | Copies | Line(s) |
|---|---|---|
| `Lots.Lot_GetWipQueueByLocation` | 1 | ~81 |
| `Lots.Lot_GetComponentsAtCell` | 1 | ~68 |
| `Lots.Lot_GetTrimStorageQueueForLine` | 1 | ~58 |
| `Lots.Lot_MoveToValidated` (`@NextPendingSeq`) | 1 | ~176 |
| `Workorder.MachiningOut_Mint` | **3** | ~176 (`@TotalAvail`), ~205 (`@SrcEligible`), ~275 (FIFO `@Queue`) |

Every copy is the same `NextStep` CTE: join Lot -> published RouteTemplate -> RouteStep ->
OperationTemplate -> OperationType -> OperationRoleKind, filter
`ConsumeMint OR (Advance AND NOT EXISTS ProductionEvent)`, `ROW_NUMBER() ... ORDER BY
SequenceNumber`, take `rn = 1`.

Adding an entry-point predicate means making the **same edit in 7 places identically**.
Miss one and the failure is silent and location-specific: a migrated LOT shows in the
Trim queue but not the Machining queue, or `MachiningOut_Mint`'s availability count
disagrees with the FIFO walk it then performs — the two most dangerous inconsistencies
in the system, because they produce wrong *quantities*, not error messages.

**This is the same fragmentation already logged as the OPEN TODO at the top of
`PROJECT_STATUS.md`** (operation-template resolution implemented five ways). Same root
cause, same schema area, adjacent procs.

### Recommendation

Do the extraction first, as its own change, with no behaviour change:

```
Lots.ufn_NextPendingRouteStep(@LotId)   -- inline TVF -> (SequenceNumber, OperationTemplateId, OperationTypeCode)
```

Replace all 7 CTEs with it, run the existing 19 affected tests green, commit. **Then**
add `EntryRouteSequence` as a one-line change inside the TVF. That converts a 7-site
risky edit into a 1-site trivial one, and leaves the codebase better than the cutover
found it.

Inline TVF (not scalar, not multi-statement) so the optimiser still inlines it into the
queue plans — these run on every terminal refresh.

---

## 2. Schema change

`sql/migrations/versioned/00XX_lot_entry_route_sequence.sql`:

```sql
ALTER TABLE Lots.Lot ADD EntryRouteSequence INT NULL;   -- NULL = entered at route start (normal)
```

- Nullable, no default -> **online, zero-downtime, no table rewrite**. Every existing
  row stays `NULL` and behaves exactly as today.
- Semantics: route steps with `SequenceNumber < EntryRouteSequence` are **not part of
  this LOT's journey** and are never pending.
- Predicate added in exactly one place (post-extraction):
  `AND rs.SequenceNumber >= ISNULL(l.EntryRouteSequence, 0)`
- Extended-property description required in `R__Descriptions_ExtendedProperties.sql`
  (feeds the generated ERD).
- No index needed: always accessed alongside an already-fetched `Lot` row.

`Lots.Lot_Create` gains `@EntryRouteSequence INT = NULL`, passed straight through to the
INSERT. Default NULL means **every existing caller is unaffected**.

---

## 3. Tier 1 — MUST change (pending-step computation)

The 5 procs / 7 sites in section 1. Post-extraction this is one TVF.

## 4. Tier 2 — reviewed, NO change required

| Proc | Why it's safe |
|---|---|
| `Lots.DieCastLot_Open` | Only asserts the route *has* a `DieCast` step. Existence check, not pending. |
| `Parts.Item_ListEligibleForLocation` | Only asserts the route *has* a step with a given `OperationType.Code`. Existence check. |
| `Workorder.MachiningIn_RecordPick` | Uses the route for **template resolution by role**, not pending computation. A migrated LOT entering at `MachiningIn` still resolves its `MachiningIn` template normally (the step exists in the route). |
| `Workorder.TrimOut_Record`, `ProductionEvent_Record` | Write events; do not compute a pending step. |
| `Lots.Lot_Search`, `Lot_SearchAdvanced`, `Lot_GetAttributeHistory`, `Lot_GetScrapSummary` | Read event *history*. A migrated LOT simply shows no pre-entry operations — correct, and honest. |
| All `Parts.RouteStep_*` / `RouteTemplate_*` config procs | Author routes; know nothing about LOTs. **The Config Tool routing UI is completely untouched.** |
| Quality reject rollups, serialized trace | Event-history reads. |

**Reports: zero impact.** No report in `com.inductiveautomation.reporting` references
`RouteStep` or the WIP queue.

## 5. Ignition layer

| Layer | Impact |
|---|---|
| Named queries | **0 signature changes.** `Lot_Create`'s NQ needs one optional param added; the 6 queue/mint NQs are untouched (result shapes identical). |
| `BlueRidge.Lots.Lot` Python | `create()` already takes a `lotName` kwarg; add `entryRouteSequence`. `getWipQueueByLocation` / `getTrimStorageQueueForLine` / `getComponentsAtCell` / `moveToValidated` unchanged. |
| Perspective views | **0 changes.** 8 views consume these queues (`MachiningIn`, `MachiningOutSplit`, `TrimBody`, `AssemblyIn`, `AssemblyNonSerialized`, `AssemblySerialized`, `InventoryManager`, `MovementScan`) — all read the same result columns. |

## 6. Tests

19 existing test files exercise the affected procs:

```
0009_Parts_Process/060_Eligibility_hierarchy_cascade
0020_PlantFloor_Foundation/041_Lot_Create_maxparts
0024_PlantFloor_Movement_Trim/030, 031, 040, 060, 065
0027_PlantFloor_Machining/010, 020, 070, 080, 090
0028_PlantFloor_Assembly/096, 097
0045_DieCast_Lifecycle/020, 040, 080
0064_Crt_PartScoped/040, 050, 060
```

All must stay green **unchanged** through the extraction (that is the extraction's proof).
New coverage needed for the entry point itself: a LOT with `EntryRouteSequence` set past
`TrimOut` is absent from the Trim queues, present in the Machining IN queue, mintable at
Machining OUT, and blocked from a backward move by `Lot_MoveToValidated`.

---

## 7. Sharp edges found while tracing (independent of the mechanism)

1. **FIFO ordering of migrated stock.** `MachiningOut_Mint` orders its FIFO queue by
   `LotMovement.MovedAt ASC`. Every migrated LOT gets its first movement at cutover
   time, so migrated stock correctly precedes anything minted later — but *among
   themselves* the order is scan order, not true age. The LTT tag carries a handwritten
   **CAST DATE**; if true FIFO across migrated stock matters, capture it and backdate
   the initial `LotMovement`. **Decision needed.**

2. **Cavity traceability is lost unless captured.** `Lot_Create` requires `@ToolCavityId`
   only when origin is `Manufactured` **and** an active `ToolAssignment` exists at the
   Cell. A casting scanned in at a Machining line hits neither, so it passes with NULL
   Tool/Cavity. The tag *does* have **CAV** handwritten (`Da`, `D6`) and a Machine #.
   Whether cutover stock keeps die/cavity genealogy is a **decision**, not a default.

3. **`UQ_Lot_LotName` collision.** Legacy tags come off the *same pre-printed stock* die
   cast uses today, so a scanned tag may already exist in `Lots.Lot`. `DieCastLot_Open`
   already guards this ("LTT ... is already in use"); the scan-in path must guard it too
   and report it as a duplicate rather than failing on a constraint violation.

4. **`Lot_Create` caps will reject real baskets.** It enforces `Item.MaxLotSize`,
   `Item.MaxParts`, and consumption-point `ItemLocation.MaxQuantity`. Tag `10625131`
   shows **3298** pieces. Verify configured caps admit real cutover quantities, or the
   floor hits rejections mid-cutover.

5. **Item-location eligibility.** `Lot_Create` validates against
   `Parts.v_EffectiveItemLocation`. A *casting* must be eligible at the *Machining line*
   location or the create is refused. Verify per line before cutover day.

---

## 8. Verdict

**Schema risk: negligible** (nullable column, online, NULL = today's behaviour).
**Code risk: concentrated entirely in the duplicated predicate**, and removable by
extracting it first.
**Config Tool, reports, named-query signatures, and all 8 Perspective views: untouched.**

Sequence: extract TVF (behaviour-neutral, 19 tests prove it) -> add column + param ->
new tests -> build the mobile scan surface on top.
