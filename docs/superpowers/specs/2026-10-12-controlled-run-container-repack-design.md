# Super-lot piece 4 — container repack: scrap, top-up, new serial, relabel

> **Status: BUILT 2026-10-13. SQL tested (83 assertions); the Repack popup and the line pick have NOT been rendered on the gateway. See section 11.**
> Fourth of six pieces. Sections marked *verified* were checked against the code.
> **Neither change order mentions this piece.** It exists because MPP's own example cannot
> finish without it; worth raising commercially.

**Read first:** `notes/2026-10-12_crt-super-lot-and-nonconformance-overview.md`; the piece 1,
2 and 3 specs in this folder; `CLAUDE.md` ("Pass-through repack", "Terminal-mint model",
"Ignition JDBC compatibility").
**Branch:** `jacques/controlled-run-super-lot`. Nothing deploys until all six pieces are in.

---

## 1. Problem

When a super-lot covers finished goods, MPP pull the completed containers out of the
warehouse and take every part out for inspection. Bad parts are removed. Then (Jacques,
2026-10-12): **all containers are reused and relabelled; a container is topped back up
with good parts, by consolidation or by new production; it gets a NEW shipper serial and
the old one is voided.**

Before this piece the system can do none of that: a completed container's tray LOTs are
Closed and cannot be scrapped; nothing reopens a container; nothing moves non-serialized
pieces between containers; nothing voids a serial and issues another. Piece 3 can only
*record* scrap against a container.

## 2. Decisions (Jacques, 2026-10-13)

| # | Decision |
|---|---|
| D1 | **Top-up moves loose pieces.** Any quantity moves from a donor tray into a receiving container. Each move is recorded against the donor tray LOT, so every piece still traces to its original LOT. Moving a whole tray is just moving all its pieces. |
| D2 | **"New production" comes from a finished container.** The line packs and completes containers as normal; good parts are taken out of a finished, unshipped container of the same part, whether or not it is in a super-lot. One mechanism for consolidation and new production. |
| D3 | **AIM is told nothing about the old serial, for now.** The MES voids the serial and its label and keeps a list of voided-but-posted serials. Jacques is discussing a cancellation post with MPP / AIM; that list is what it would work from. The new serial posts when the container completes again, as any completion does. |
| D4 | **A container emptied by consolidation is voided.** Its serial and label are voided, its tray LOTs end at zero and it leaves the super-lot. |
| D5 | **Two rework statuses; tray LOTs stay Closed.** `ReworkProcessing` (parts being taken out and scrapped; not fillable) and `ReworkFilling` (refill-ready). The repack procs take pieces off the Closed tray LOTs directly, allowed only while the container is in rework. Nothing reappears in a WIP queue or anything that treats Closed as final. |
| D6 | **Serialized containers are included**: scrap and moves are per serial. |
| D7 | **Sort Cage stays separate.** Repack is reached from a container on the super-lot page; the procs are written so Sort Cage could call them later. |
| D8 | **A reworked container can be finished at a line.** Quality sends a refill-ready container to a line. The line's inventory card shows a button only while one is there; the operator picks it and it becomes the line's open container, so normal full-tray production carries on into it and the line's own container waits (*verified*: `Workorder.Assembly_CompleteTray` fills the oldest open container at the cell first). No change to the line's packing proc. |
| D9 | **BOM-component partial fill is a FOLLOW-ON piece, not built here** (section 9). |

Decided by me while completing the spec; say if any is wrong:

- **Any Complete, unshipped container can be opened for rework**, member of a super-lot or
  not, because a clean finished container is a legal donor (D2). A container on a real hold
  is refused: release the hold first.
- **A donor must itself be opened for rework before pieces leave it.** Opening voids its
  serial and label. A donor left part-full stays in rework until it is refilled or
  emptied and voided; there will usually be one remainder container at the end.
- **A member that is being reworked cannot be released** (new block reason on the Sign-off
  tab), and cannot be validated one at a time.
- **Scrap in a repack is real** and, when the container is a super-lot member, is also a
  result entry. A scrap already *recorded* on the Results tab (piece 3, "not yet applied")
  can be applied to a tray instead of entered twice.
- **Completing a reworked container reuses the existing completion** (`Lots.Container_
  Complete` through `BlueRidge.Lots.Container.complete`): new serial claimed, new label
  printed, new serial posted. No second copy of that logic.
- **A voided container's membership ends as `ContainerVoided`** and counts as cleared.

## 3. What a set part can and cannot do here

A 6MA cam holder finished good is a set of 12 pieces that the system counts as ONE part.
This piece works in the units the LOT is counted in, so for a set part it scraps and moves
whole sets. Making a short set whole again from sub-components is the follow-on (section 9).

## 4. Data model — migration `0111_container_rework`

```
Lots.ContainerStatusCode  + ReworkProcessing (6), ReworkFilling (7)

Lots.ContainerRework            (one row each time a container is opened for rework)
  Id, ContainerId (FK), OpenedByUserId (FK), OpenedAt, OpenedAtTerminalId (FK, NULL),
  OriginalCompletedAt, OriginalAimShipperId NVARCHAR(50) NULL, OriginalShippingLabelId NULL,
  OriginalPieceCount INT,
  ResumedAt NULL, ResumedByUserId (FK, NULL), ResumedAtLocationId (FK, NULL),
  VoidedAt NULL, VoidedByUserId (FK, NULL), VoidRemarks NVARCHAR(500) NULL

Lots.AimShipperIdPool   + VoidedAt NULL, VoidedByUserId (FK, NULL), VoidReason NVARCHAR(200) NULL
Lots.ContainerSerial    + RemovedAt NULL, RemovedRejectEventId BIGINT NULL   (a scrapped serial)
Quality.ControlledRunMemberEndReason + ContainerVoided (5)
Audit.LogEventType + ContainerReworkOpened, ContainerReworkScrapped, ContainerPiecesMoved,
                     ContainerReworkStageChanged, ContainerReworkResumed, ContainerVoided
```

No piece-move table: a move IS a `Workorder.ConsumptionEvent` (donor tray LOT -> new tray
LOT, same Item) with `Consumption` genealogy, exactly the shape the pass-through repack
writes. "The current rework" of a container is its latest `ContainerRework` row.

## 5. Behaviour

Every proc follows FDS-11-011 (no OUTPUT params, one result set, rejections before
`BEGIN TRANSACTION`, no status-row proc calls another).

| Proc | Does |
|---|---|
| `Lots.ContainerRework_Open(@ContainerId, …)` | `Complete` -> `ReworkProcessing`. Writes the `ContainerRework` row, voids the container's live shipping label(s) and its AIM pool row (posted or not), clears `CompletedAt`. Refuses anything not `Complete`. |
| `Lots.ContainerRework_Scrap(@ContainerTrayId, @DefectCodeId, @Quantity, @ContainerSerialId, @ControlledRunResultId, @Remarks, …)` | Real scrap out of a tray: `Workorder.RejectEvent`, tray LOT and `ContainerTray.PartsClosedCount` decremented. Serialized config: one serial per call, marked `RemovedAt`. If the container is a super-lot member the scrap is a result entry: `@ControlledRunResultId` applies an existing recorded scrap (same defect, same quantity); without it a new applied entry is written. |
| `Lots.ContainerRework_MovePieces(@FromContainerTrayId, @ToContainerId, @Quantity, @ContainerSerialId, …)` | Donor in rework, receiver `ReworkFilling`, same Item, receiver not over target. Mints a tray LOT in the receiver for the moved quantity, consuming the donor tray LOT (`ConsumptionEvent` + `Consumption` genealogy + closure). The new LOT inherits the donor's CRT tag. Serialized: the serial moves with a `ContainerSerialHistory` row. |
| `Lots.ContainerRework_SetStage(@ContainerId, @StageCode, @LocationId, …)` | `Processing` <-> `Filling`; optionally sends the container to a location (a line). |
| `Lots.ContainerRework_Resume(@ContainerId, @CellLocationId, …)` | `ReworkFilling` -> `Open` at that cell. The container is then an ordinary open container: the line fills it, and the existing completion gives it a new serial and label. |
| `Lots.ContainerRework_Void(@ContainerId, @Remarks, …)` | A rework container with ZERO pieces -> `Void`. Clears the tag on its (empty) tray LOTs and ends its super-lot membership (`ContainerVoided`). Refused while pieces remain. |
| Reads | `ContainerRework_Get`, `_ListTrays`, `_ListSerials`, `_ListTargets` (where pieces can go), `_ListAtLocation` (refill-ready containers at a line), `Lots.AimShipperIdPool_ListVoided` (the D3 list) |

Changes to existing objects:

| Object | Change |
|---|---|
| `Lots.AimShipperIdPool_ListUnposted`, `Lots.Container_ListPendingValidation`, `Lots.AimShipperIdPool_GetForPost` | Ignore / report voided pool rows, so a voided serial is never posted and a container's "serial" is its live one. `AimPost.postOne` refuses a voided row. |
| Readers of `Lots.ContainerSerial` | Skip `RemovedAt IS NOT NULL` |
| `Quality.ufn_ControlledRunMemberResults` | `ReleaseBlockReason` gains "Being reworked" |
| `Quality.ControlledRun_Get` / `_List` | Members ended as `ContainerVoided` count, as cleared |
| `Quality.ufn_ControlledRunResolveMembers` | A container in rework is still eligible (not Shipped / Void) - no change, tested |

## 6. Completing a reworked container

Two places, one mechanism (`Resume` then the existing completion):

- **At a line (D8):** the operator picks the waiting container on the inventory card. It
  becomes the cell's oldest open container; trays packed by the line go into it; the line
  completes it as it completes any container.
- **At Quality:** when the container is full, "Complete here" resumes it at the Quality
  terminal's location and completes it in the same action. If the completion is refused
  (not full, serial pool empty) the container goes back to `ReworkFilling`.

A re-completed container that is still a super-lot member is CRT-tagged, so its new serial
is held from AIM until the signed release (piece 2 behaviour, unchanged).

## 7. Views

- **Super-lot page, Members tab:** a container row gains a Repack button. It goes through
  the Quality sign-in window and opens `Popups/ControlledRunRepack`.
- **`ControlledRunRepack`:** the container (status, pieces of target, short by), its trays
  and, for a serialized part, its serials; a Scrap form (defect, quantity, or a recorded
  scrap to apply) and a Move form (destination, quantity); stage buttons (Open for rework,
  Refill-ready, Back to processing, Send to line, Complete here, Void).
- **Line inventory card:** a button, shown only while a refill-ready container is at the
  line, opening `Popups/ReworkContainerPick`; picking one resumes it at this cell. The
  operator is the signed-in PIN user; no elevation.

## 8. Tests

`sql/tests/0111_ContainerRework/`: open (status, label and serial voided, refusals);
scrap by quantity and by serial, with and without a super-lot result; apply a recorded
scrap; move pieces (new tray LOT, consumption genealogy, counts on both sides, CRT
inherited, capacity and same-part refusals) and move a serial; stage changes; resume and
re-complete through the existing `Container_Complete` (NEW serial, old one voided and
never offered to AIM); void an emptied container (membership ended, counts as cleared);
a member in rework cannot be released; the voided-serial list.

## 9. Follow-on (NOT in this piece): partial fill at the line

**BOM-component partial fill.** Jacques's example: a 6MA cam holder finished good is a
set of 12 pieces treated as a single part. If 3 of the 12 are pulled, a "consume partial"
action at the line would consume 3 replacement sub-components (machined, pass-through,
purchased or raw) to make the set whole, outside the normal full-tray rules.

Feasibility, from reading `Workorder.Assembly_CompleteTray` (*verified*):

- The line accepts only FULL trays (`@PieceCount` must equal `PartsPerTray`) and consumes
  the BOM for a full tray. A partial fill needs its own proc with its own copy of the
  component-consumption logic, scaled to the quantity chosen - a second copy of the most
  production-critical logic in the system, with its own tests.
- It bypasses vision and PLC counts on lines that have them. That is the point of
  "separate from the normal constraints", and must be a deliberate, audited action.
- It cannot be done by hand on serialized lines: each part gets its serial from the
  machine handshake.
- The entry point already exists after this piece: the rework container picked on the
  inventory card (D8). The follow-on adds a "Consume partial" action there, with buttons
  for the BOM elements of the part.

## 10. Known limitations

- AIM still believes a voided, already-posted serial is good until the cancellation post
  exists (D3). `Lots.AimShipperIdPool_ListVoided` is the worklist.
- The old paper label is still on the container. The system voids the record; a person
  removes the label.
- A loose-piece shortfall can only be filled from finished parts until the follow-on.
- One remainder container is normal at the end of a consolidation.

## 11. Build notes (2026-10-13)

**Differs from the sections above:**

- **Scrapped serials (section 5):** only `Lots.Container_ListSerials` and the new rework reads skip a removed serial. The trace readers (`Container_GetTraceDetail`, `SerializedPart_GetTraceDetail`, `GlobalTrace_Resolve`, `Container_ListShipped`, `Hold_ListAssociatedContainers`) still show it in the container it was packed in, with no "scrapped" marker. That is piece 6 (visibility).
- **No new print reason code.** The re-completion is an ordinary completion, so its label is an ordinary initial label.
- **"Complete here"** resumes the container at the location it is standing in, then completes it. The label prints on the printer of the terminal the Quality user is at.
- **A recorded scrap is applied whole** to one tray (same defect, same quantity). If the parts came out of two trays, void the recorded entry and scrap each tray directly.
- **The top-up tray LOT is minted Closed**, not Good, so it never appears in a WIP queue or a line's inventory.

**Verified:** `sql/tests/0111_ContainerRework/010_rework.sql`, 83 assertions, including re-completion through the unmodified `Lots.Container_Complete` (new serial claimed, old one voided and never offered to the AIM sweep, the live serial read by container is the new one).

**Not verified:** the Repack popup and the pick popup have not been rendered; no action has been driven from the UI; a real re-completion with label print and AIM post; how the line's own screens look while a resumed rework container is their open container (it will have more tray rows than the config's trays-per-container, with unequal counts).

## Revision History

| Date | Change |
|---|---|
| 2026-10-12 | Initial draft: problem statement and options, written as a handoff. Not approved. |
| 2026-10-13 | Completed with Jacques: all questions answered (loose pieces, donor is any finished container, no AIM call for the old serial, void an emptied container, two rework statuses with trays left Closed, serialized included, Sort Cage separate, finish at a line through the inventory card). BOM-component partial fill recorded as a follow-on with its feasibility. Data model and procs made concrete. |
| 2026-10-13 | Built. Section 11 added: differences from the spec, what was verified and what was not. |
