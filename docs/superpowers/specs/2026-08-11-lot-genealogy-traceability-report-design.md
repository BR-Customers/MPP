# LOT Genealogy & Traceability Report — Design

- **Date:** 2026-08-11
- **Author:** Blue Ridge Automation
- **Status:** Draft (pending user review)
- **Scope tag:** MVP (traceability reporting; Honda genealogy requirement)

## 1. Problem

The existing **Lot Detail** report
(`ignition/projects/MPP/com.inductiveautomation.reporting/reports/Lot Detail/`)
carries a Genealogy band, but it has three gaps:

1. **Wrong quantity.** The Genealogy band's Qty column shows the *related LOT's own
   quantity*, not the quantity actually consumed into / contributed by the subject
   LOT. If an ancestor contributed 96 of its 1,000 pieces, the report must show
   **96**.
2. **One level deep.** The band shows only immediate parents ("Made from"). Honda
   genealogy requires tracing **all the way back to the component parts** — and, for
   this report, **all the way forward** to the finished goods the LOT ended up in.
3. **No life history.** There is no section describing what happened to the LOT over
   its life — created, acted on, moved, closed — with location and timestamp.

## 2. Goals

- Fix the consumed-quantity column to display the **per-edge** consumed count.
- Trace genealogy **both directions**, recursing as deep as the data goes:
  - **Made From (Ancestors)** — up to the die-cast casting (raw aluminum is not in
    the system, so ancestors naturally bottom out at the origin-mint casting LOT).
  - **Used In (Descendants)** — down to the finished-good LOTs.
- Detail the **containers** that make up the subject LOT, surfacing the Honda **AIM
  shipper ID** carried on each container's shipping label.
- Add a chronological **Lifecycle** band: every event with location, operator, and
  Eastern-time timestamp.

## 3. Non-Goals

- No schema changes. All required data already exists.
- No synthetic "shipment" node in the descendant tree. Shipment/AIM identity is
  surfaced through the Containers band, not as a genealogy edge.
- No change to how consumption is *recorded* — the fix is read-side only (see the
  verification note in §7).
- Not a new report. This **extends the existing Lot Detail report**.

## 4. Data Sources (all pre-existing tables)

| Concern | Source | Notes |
|---|---|---|
| Per-edge consumed qty | `Lots.LotGenealogy.PieceCount` | Actual consumed count per Consumption edge (`RelationshipTypeId = 3`). |
| Genealogy edges | `Lots.LotGenealogy` (ParentLotId → ChildLotId) | Walked recursively. **Not** the closure table — the edge table preserves tree structure and per-edge qty at every depth; the closure flattens both. |
| Part identity / UOM | `Parts.Item.PartNumber`, `Parts.Item.UomId → Parts.Uom.Code` | UOM column shows the part's preferred UOM; default `pcs`. |
| Containers + AIM ID | `Lots.ContainerTray.FinishedGoodLotId`, `Lots.Container`, `Lots.ShippingLabel.AimShipperId` | Existing `Lots.Lot_GetLinkedContainer` already joins these (1:1 on `FinishedGoodLotId`). |
| Lifecycle events | `Audit.LotEventLog` (+ event-type / location / user joins) | Append-only per-LOT event stream; timestamps converted to ET at the read boundary (OI-36 convention). |

## 5. New SQL (read procs — FDS-11-011 read-proc convention: one result set, no
status row, no OUTPUT params, empty set = not found)

### 5.1 `Lots.Lot_GetGenealogyEdgeTree`

Recursive CTE over `Lots.LotGenealogy` **edges** (not the closure), returning the
full ancestor or descendant tree with per-edge consumed quantity and depth.

- **Params:** `@LotId BIGINT`, `@Direction NVARCHAR(20) = N'Both'`
  (Ancestors / Descendants / Both; normalized case-insensitively, singular/plural
  accepted, unrecognized → `Both`, mirroring `Lot_GetGenealogyTree`).
- **Walk:**
  - *Ancestors*: seed on edges where `ChildLotId = @LotId`; recurse up via
    `ChildLotId = parent.ParentLotId`. The projected LOT is the **parent** (the
    source that was consumed); `PieceCount` is what that parent contributed.
  - *Descendants*: seed on edges where `ParentLotId = @LotId`; recurse down via
    `ParentLotId = child.ChildLotId`. The projected LOT is the **child** (what the
    subject went into); `PieceCount` is what the subject contributed to it.
- **Result columns:** `RelatedLotId BIGINT`, `RelatedLotName NVARCHAR(50)`,
  `ItemId BIGINT`, `PartNumber NVARCHAR(50)`, `RelationshipName NVARCHAR(100)`,
  `PieceCount INT`, `UomCode NVARCHAR(20)`, `Depth INT`, `Direction NVARCHAR(20)`.
- **Ordering:** `Direction, Depth, RelatedLotName` — stable, readable, and gives the
  report the indentation level directly via `Depth`.
- **Cycle guard:** recursion is bounded by `OPTION (MAXRECURSION n)` and a visited-set
  guard so a mis-recorded cyclic edge cannot loop. (Genealogy is a DAG by
  construction; the guard is defensive.)

### 5.2 `Lots.Lot_GetLifecycle`

Projects the subject LOT's event stream from `Audit.LotEventLog`, joined to event
type, location, and `AppUser`, ordered chronologically.

- **Params:** `@LotId BIGINT`
- **Result columns:** `EventAtEt DATETIME2(3)` (UTC → ET at the boundary),
  `EventTypeName NVARCHAR(100)`, `LocationName NVARCHAR(200)`,
  `OperatorInitials NVARCHAR(50)` (or AppUser display name), `Description NVARCHAR(500)`.
  (`Description` is carried for future use even though the report renders only
  timestamp / event / location / operator per §6.)
- **Ordering:** `EventAtEt ASC`.

### 5.3 Containers band data

Reuse `Lots.Lot_GetLinkedContainer(@LotId)` as-is (it already returns container id,
status, location, opened/completed ET times, and `AimShipperId`). If the subject LOT
can be packed into more than one container, generalize the proc (or add
`Lots.Lot_GetContainers`) to return all matching rows rather than the current 1:1;
otherwise reuse directly.

## 6. Report Layout (bands, top to bottom)

1. **LOT identity** — unchanged from current Lot Detail (LOT number, part,
   description, type, quantity, status).
2. **Made From · Ancestors** — indented tree keyed on `Depth`. Columns: Related LOT /
   Part / Relationship / **Consumed** (`PieceCount` + `UomCode`).
3. **Used In · Descendants** — indented tree keyed on `Depth`. Columns: Related LOT /
   Part / Relationship / **Contributed** (`PieceCount` + `UomCode`).
4. **Containers** — one row per container of the subject LOT: LTT / container id, AIM
   shipper id, quantity, status, location. Empty when the subject LOT owns no
   containers (see §8 assumption).
5. **Lifecycle** — chronological: Timestamp (ET) / Event / Location / Operator.

Visual style follows the existing report chrome (teal section accent bar + heading,
navy uppercase column headers, hairline row separators, right-aligned quantities).
Report parameter stays the subject-LOT selector already on Lot Detail.

## 7. Verification Note — consumed quantity provenance

The read-side fix assumes the mint procs that create Consumption edges
(`Workorder.MachiningOut_Mint`, `Workorder.Assembly_CompleteTray`, and
`Lots.LotGenealogy_RecordConsumption`) persist the **actual consumed count** into
`Lots.LotGenealogy.PieceCount` — not the whole source-lot quantity. Confirmed for
`LotGenealogy_RecordConsumption` (it writes `@ConsumedPieceCount`). During
implementation, verify the two mint procs pass the real consumed amount; if either
writes the full lot quantity, the fix extends one layer down into that proc.

## 8. Assumptions & Open Questions

1. **"Containers of the concerned lot" = the subject LOT's own containers**
   (`ContainerTray.FinishedGoodLotId = subject`). If the subject is an upstream
   sub-assembly with no containers of its own, the Containers band is empty and the
   AIM IDs live on the *descendant* finished-good LOTs' containers. Open question for
   review: should the Containers band instead follow descendants to the shipped FG
   containers? Current design says no — keep it the subject LOT's containers.
2. **UOM display.** Genealogy quantities render in the related part's preferred UOM
   (`Parts.Item.UomId`), defaulting to `pcs` when absent.
3. **Depth cap.** Practical genealogy depth is small (die cast → trim → machining →
   assembly), but the recursive procs carry an explicit `MAXRECURSION` bound.

## 9. Testing

- `Lot_GetGenealogyEdgeTree`: fixtures with (a) a multi-level ancestor chain with
  partial consumption (assert `PieceCount` = actual consumed, e.g. 96 not 1,000),
  (b) a branching descendant (one sub-assembly LOT split across two FG trays; assert
  both edges + per-edge qty), (c) `@Direction` variants, (d) a not-found LOT (empty
  set), (e) UOM projection.
- `Lot_GetLifecycle`: fixture LOT with created / moved / inspected / consumed events;
  assert chronological order and ET conversion.
- Container band: FG LOT with an AIM-labeled container (assert AIM id surfaces);
  upstream LOT with no container (assert empty band).
- Report render: deploy via `scan.ps1`, render against the running gateway, verify all
  five bands populate and quantities/indentation are correct (per the
  `ignition-reporting` skill's render-verify step).

## 10. Revision History

| Date | Version | Change |
|---|---|---|
| 2026-08-11 | 0.1 | Initial draft. |
