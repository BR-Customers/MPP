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
- Detail the **shipped containers** the LOT reached — the subject LOT's own
  containers if it is a finished good, otherwise the containers of its finished-good
  **descendants** — surfacing the Honda **AIM shipper ID** on each container's
  shipping label. This is the recall-traceability view: "which containers/shipments
  did this LOT reach?"
- Add a chronological **Lifecycle** band: every event with location, operator, and
  Eastern-time timestamp.

## 3. Non-Goals

- No schema changes. All required data already exists.
- No synthetic "shipment" node in the descendant *genealogy tree*. Shipment/AIM
  identity is surfaced through the Containers band (which reads off the descendant FG
  LOTs' containers), not as a genealogy edge.
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
| Lifecycle events | `Lots.LotEventLog` (+ `Audit.LogEventType` / `Location.Location` / `Location.AppUser` joins) | Append-only per-LOT audit event stream; carries `LocationId` **and** `TerminalLocationId` on every row (so a discrete Location column is available per event), plus `UserId`, `LoggedAt`, `Description`. Timestamps converted to ET at the read boundary (OI-36 convention). Distinct from the curated `Lots.Lot_GetAttributeHistory` timeline, which embeds location inside its Detail string rather than a discrete column. |

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

Projects the subject LOT's event stream from `Lots.LotEventLog`, joined to
`Audit.LogEventType`, `Location.Location`, and `Location.AppUser`, ordered
chronologically. `LotEventLog` (not the curated `Lot_GetAttributeHistory`) is chosen
because it carries a discrete `LocationId`/`TerminalLocationId` on every row — the
report wants a Location *column*, not location baked into a Detail string.

- **Params:** `@LotId BIGINT`
- **Result columns:** `EventAtEt DATETIME2(3)` (UTC → ET at the boundary),
  `EventTypeName NVARCHAR(100)` (`Audit.LogEventType.Name`),
  `LocationName NVARCHAR(200)` (`COALESCE(LocationId, TerminalLocationId)` → `Location.Name`),
  `OperatorName NVARCHAR(200)` (`Location.AppUser.DisplayName`),
  `Description NVARCHAR(1000)`.
  (`Description` is carried for future use even though the report renders only
  timestamp / event / location / operator per §6.)
- **Ordering:** `LoggedAt ASC` (order on raw UTC; project the ET cast).

### 5.3 `Lots.Lot_GetShippedContainers`

Returns every finished-good container the LOT reached — the subject LOT's own
container if it is a finished good, plus the containers of all its finished-good
descendants. Built on the same descendant edge-walk as §5.1: collect the descendant
LOT set (plus the subject), then join each to `Lots.ContainerTray.FinishedGoodLotId`
→ `Lots.Container` → `Lots.ShippingLabel` (the joins already in
`Lot_GetLinkedContainer`). Each row names the FG LOT it belongs to so the band stays
legible when containers span several descendants.

- **Params:** `@LotId BIGINT`
- **Result columns:** `FinishedGoodLotId BIGINT`, `FinishedGoodLotName NVARCHAR(50)`,
  `FinishedGoodPartNumber NVARCHAR(50)`, `ContainerId BIGINT`,
  `AimShipperId NVARCHAR(50)`, `Quantity INT`, `ContainerStatusName NVARCHAR(100)`,
  `CurrentLocationName NVARCHAR(200)`, `CompletedAt DATETIME2(3)` (ET at the boundary).
- **Ordering:** `FinishedGoodLotName, ContainerId`.
- Empty result set = the LOT has reached no finished-good container yet (still
  in-process). `Lot_GetLinkedContainer` remains for the single-LOT container lookup
  used elsewhere; this proc is the report-specific descendant-aware view.

## 6. Report Layout (bands, top to bottom)

1. **LOT identity** — unchanged from current Lot Detail (LOT number, part,
   description, type, quantity, status).
2. **Made From · Ancestors** — indented tree keyed on `Depth`. Columns: Related LOT /
   Part / Relationship / **Consumed** (`PieceCount` + `UomCode`).
3. **Used In · Descendants** — indented tree keyed on `Depth`. Columns: Related LOT /
   Part / Relationship / **Contributed** (`PieceCount` + `UomCode`).
4. **Containers** — one row per shipped finished-good container the LOT reached
   (subject's own if it is an FG, else its FG descendants'): FG LOT / FG Part /
   container id / AIM shipper id / quantity / status / location. Empty when the LOT
   has reached no finished-good container yet.
5. **Lifecycle** — chronological: Timestamp (ET) / Event / Location / Operator.

Visual style follows the existing report chrome (teal section accent bar + heading,
navy uppercase column headers, hairline row separators, right-aligned quantities).
Report parameter stays the subject-LOT selector already on Lot Detail.

## 7. Verification Note — consumed quantity provenance

The read-side fix assumes the mint procs that create Consumption edges
(`Workorder.MachiningOut_Mint`, `Workorder.Assembly_CompleteTray`, and
`Lots.LotGenealogy_RecordConsumption`) persist the **actual consumed count** into
`Lots.LotGenealogy.PieceCount` — not the whole source-lot quantity. **Confirmed
2026-08-11:** `LotGenealogy_RecordConsumption` writes `@ConsumedPieceCount`, and
`Workorder.MachiningOut_Mint` writes `@take` (the per-casting FIFO draw amount) into
the edge `PieceCount`. The consumed-qty fix is therefore **report-side only** — the
report band currently binds to the related LOT's own quantity instead of the edge
`PieceCount`. (`Workorder.Assembly_CompleteTray` follows the same pattern; a test in
the plan covers a full mint→consume chain end-to-end.)

## 8. Assumptions & Open Questions

1. **Containers band follows descendants to shipped FG containers** (resolved
   2026-08-11). The band shows every finished-good container the LOT reached — its own
   if it is an FG, otherwise its FG descendants' — so it answers the Honda recall
   question ("which containers/shipments did this LOT reach?") regardless of where the
   subject sits in the genealogy. A subject that is itself an FG degenerates correctly
   (its descendants-with-containers is just itself). For a widely-used component LOT
   the container set can be large, but that is the correct recall scope.
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
- `Lot_GetShippedContainers`: (a) subject that is an FG with an AIM-labeled container
  (assert its own container + AIM id surface); (b) upstream sub-assembly whose FG
  descendants have shipped containers (assert descendants' containers surface, each
  tagged with its FG LOT); (c) in-process LOT with no FG container anywhere in its
  descendants (assert empty band).
- Report render: deploy via `scan.ps1`, render against the running gateway, verify all
  five bands populate and quantities/indentation are correct (per the
  `ignition-reporting` skill's render-verify step).

## 10. Revision History

| Date | Version | Change |
|---|---|---|
| 2026-08-11 | 0.1 | Initial draft. |
| 2026-08-11 | 0.2 | Containers band follows descendants to shipped FG containers (§8.1 resolved); new `Lot_GetShippedContainers` proc; container rows tagged with FG LOT. |
| 2026-08-11 | 0.3 | Corrected lifecycle source to `Lots.LotEventLog` (was `Audit.*`); `Lot_GetLifecycle` result columns finalized against real schema; §7 consumed-qty provenance confirmed report-side-only (mint procs write real `PieceCount`). |
