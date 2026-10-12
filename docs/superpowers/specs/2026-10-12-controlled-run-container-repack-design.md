# Super-lot piece 4 — container repack: scrap, top-up, new serial, relabel

> **Status: DRAFT 2026-10-12. NOT APPROVED. NOT BUILT.** Handoff for another agent.
> Fourth of six pieces, and the one with the most unknowns. **This is a problem statement
> and a set of options more than a design.** Section 7 has to be answered — several items
> by MPP, not by reading code — before a plan is worth writing.

**Read first:** `notes/2026-10-12_crt-super-lot-and-nonconformance-overview.md`; the piece
1, 2 and 3 specs in this folder; `CLAUDE.md` (the "Pass-through repack" and "Terminal-mint
model" sections matter here); FDS 7.7 Sort Cage (FDS-07-017 to -019).
**Branch:** `jacques/controlled-run-super-lot`. Nothing deploys until all six pieces are in.

**Neither change order mentions this piece.** It exists because MPP's own example cannot
finish without it. That is worth raising commercially before it is built.

---

## 1. Problem

When a super-lot covers finished goods, MPP pull the completed containers out of the
warehouse and take every part out for inspection, one at a time. Bad parts are removed.
Then, in Jacques's words (2026-10-12): **all containers are reused and relabelled; a
container is topped back up with good parts, by consolidation or by new production; it
gets a NEW shipper serial and the old one is voided.**

The system can do none of that today:

- A completed container's tray LOTs are **Closed**, and `Workorder.RejectEvent_Record`
  refuses a Closed LOT. Bad parts found in a finished container cannot be scrapped.
- No proc reopens a completed container. Statuses are `Open`, `Complete`, `Shipped`,
  `Hold`, `Void`.
- `Lots.SortCage_MigrateSerial` moves **one serialized part** between containers. There
  is nothing for non-serialized pieces. The Sort Cage view is partly stubbed.
- A container's AIM serial is consumed permanently (decision of 2026-08-14). Nothing
  voids one and issues another.

## 2. What exists

| Existing | Notes |
|---|---|
| `Lots.Container`, `Lots.ContainerTray` (`FinishedGoodLotId`, one tray = one FG LOT), `Lots.ContainerSerial`, `Lots.ContainerSerialHistory` | A container is already a set of tray LOTs, so mixed sources per container are legal at tray level |
| `Lots.Container_Open(@ItemId, @ContainerConfigId, @CellLocationId, …)`, `Lots.Container_Complete(@ContainerId, …)` | Complete closes the tray LOTs, claims an AIM serial, creates the shipping label |
| `Workorder.Assembly_CompleteTray(@FinishedGoodItemId, @PieceCount, @CellLocationId, …)` | Mints a tray LOT into the cell's open container. **Takes no container id** — it finds the open container itself. Whether it can be pointed at a specific part-full container is unverified |
| `Lots.ShippingLabel_Void(@ShippingLabelId, @VoidReason, …)`, `Lots.ShippingLabel_Reprint` | Label void and reprint exist |
| `Lots.AimShipperIdPool` (`ConsumedByContainerId`), `AimShipperIdPool_Claim` | One serial per container today |
| `BlueRidge.Lots.AimPoolGateway.update(aimShipperId, serialsJson)`, `placeOnHold`, `releaseFromHold` | AIM calls; simulated in dev. FDS-07-012 anticipates `UpdateAim` with a `previousSerial` |
| `Lots.PrintReasonCode` | `Initial`, `ReprintDamaged`, `Split`, `Merge`, `SortCageReIdentify` |
| Piece 3 | Records a Scrap result against a completed container as **intent only**; this piece makes it real |
| Pass-through repack (`Assembly_CompleteTray` v1.5) | Precedent for same-part 1:1 consumption with `Consumption` genealogy. Its origin filter is load-bearing — read the CLAUDE.md section before touching it |

## 3. The work, in the order it happens on the floor

1. **Open the container for rework.** It must stop being shippable and become editable,
   without losing what it was. *(Piece 2 already blocks shipping through the tag.)*
2. **Take bad parts out.** Scrap against the right tray LOT, with a defect code.
3. **Top it back up** to full count — from another container in the super-lot
   (consolidation) or from new production.
4. **Void the old serial**, claim a new one, tell AIM.
5. **Relabel**, and close the container again.
6. **Account for the containers that are emptied** by consolidation.

## 4. Design options to put to Jacques

### 4.1 How a container is "reopened"

- **(a) New status `Rework`** on `Lots.ContainerStatusCode`. Explicit, queryable,
  blocks shipping by status as well as by tag. Every proc and view that switches on
  container status must be checked.
- **(b) Reuse `Hold`.** `Quality.Hold_Place` already moves a container to `Hold` and
  remembers the prior status. But a hold has its own lifecycle and its own AIM call, and
  CRT and hold are separate axes by design.
- **(c) Leave it `Complete`** and let the tag carry the meaning. No status churn; but
  "Complete" would then be true of a container with parts missing.

Recommended: **(a)**, because a container that is physically open on a bench should not
read as complete anywhere.

### 4.2 The tray LOTs

Scrapping needs a LOT that is not Closed. Options: **reopen** the tray LOT (Closed →
Good) for the duration of the rework; or allow scrap against a Closed LOT under a narrow
flag, as `@AllowHeldLot` did for holds. Reopening is the more honest statement of state
but touches the LOT status history and whatever assumes Closed is terminal
(`IX_Lot_Active`, the WIP queue's pending rule, `Lot_RectifyPieceCount` / `Lot_Update`
guards — CLAUDE.md warns about those). Verify each before choosing.

### 4.3 Top-up and genealogy — the hard part

- **Serialized parts** are tractable: the serial carries its ancestry
  (`SerializedPart.ProducingLotId`), and `SortCage_MigrateSerial` already moves a serial
  between containers with a history row and no merge genealogy (FDS-07-019).
- **Non-serialized parts** are not. A good piece moved from container B's tray LOT into
  container A changes which LOT A's pieces came from. Honda requires full genealogy for
  every part. Options:
  - Mint a **new tray LOT** in the receiving container for the moved quantity, consuming
    from the donor tray LOT with `Consumption` genealogy — the pass-through repack shape.
  - Treat it as a `Lot_Split` of the donor + a move. Split is exception-only by project
    rule and currently refuses CRT LOTs.
  - Decide the unit of repack is the **tray**, never the piece: whole trays move between
    containers, short trays are topped up only from new production.
  Which of these matches what MPP physically do is a question for MPP.
- **Top-up from new production** means a line finishes a container it did not open.
  `Assembly_CompleteTray` finds the cell's open container itself; check whether a
  reworked container can be made that open container, and what happens to the one the
  line was already filling.

### 4.4 Serial and label

Settled: **new serial, old one voided** (Jacques, 2026-10-12). To design:

- `AimShipperIdPool` ties one serial to one container. A reworked container will have
  had two. Either allow several pool rows per container (one current) or add a history
  table, mirroring `ContainerSerialHistory`.
- What AIM must be told for the old serial (`update` with a previous serial? a delete? a
  hold that is never released?) is **MPP / Honda's answer**, and it interacts with piece
  2's decision about what AIM is told when the container is tagged.
- A new `PrintReasonCode` for the relabel (e.g. `SuperLotRepack`), ASCII-only.
- The old paper label is still on the container. The system voids the record; a person
  removes the label. Say so in the procedure.

### 4.5 Emptied containers

A container emptied by consolidation is `Void`? Returned to stock as dunnage? Its serial
is voided either way. Its tray LOTs end at zero pieces — closed by the existing
close-at-zero path, or by this piece explicitly.

## 5. Where it lives

A **Repack** area reached from a container member on the super-lot view, not the Sort
Cage view. Whether Sort Cage and this should converge is worth one question to Jacques:
they do the same physical job for two different triggers (hold vs CRT).

## 6. Constraints

As pieces 2 and 3. In addition: AIM calls are asynchronous, gateway-side and never inside
a database transaction (FDS-01-014), so the serial swap is a sequence with a failure
state in the middle — design what "old voided, new not yet posted" looks like and how it
is retried, the way `AimPost.retryTick` does for a normal completion.

## 7. Questions that must be answered first

For MPP (through Jacques):

1. When parts are consolidated, do they move as **whole trays** or as loose pieces?
2. For non-serialized parts, what does Honda need to be able to trace afterwards — the
   container, the tray, or the original LOT of each piece?
3. What must AIM be told about the old serial, and when?
4. What happens to a container that ends up empty?
5. Is top-up from new production done at the line, or are finished parts brought to the
   inspection area?

For Jacques:

6. Container status for rework (4.1), and reopening tray LOTs versus a narrow scrap flag
   (4.2).
7. Should this and the Sort Cage workflow be one thing?
8. Is this piece in scope commercially? It is in neither change order.

## Revision History

| Date | Change |
|---|---|
| 2026-10-12 | Initial draft: problem statement and options, written as a handoff. Not approved. |
