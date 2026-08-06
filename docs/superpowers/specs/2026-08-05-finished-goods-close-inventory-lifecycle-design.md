# Finished-Goods Close / Inventory Lifecycle — Design

**Date:** 2026-08-05
**Status:** Approved (design) — plan pending
**FAT item:** #21 (Handoff E, `docs/handoffs/2026-08-05-fat-remaining-handoffs.md`)
**Author:** Blue Ridge Automation

## 1. Problem

A finished-goods (FG) LOT is minted `Good` at the assembly cell by `Workorder.Assembly_CompleteTray`
(tray = LOT, 1:1 via `Lots.ContainerTray.FinishedGoodLotId`; migration `0034`). Unlike component,
casting, and sub-assembly LOTs — which close automatically the moment their `PieceCount` reaches 0
(the "close-at-zero" rule, inline in `MachiningOut_Mint`, `Assembly_CompleteTray`,
`RejectEvent_Record`, `Lot_Split`, `Lot_Merge`) — an **FG LOT is terminal in the flow: nothing
consumes it downstream, so it never self-closes.**

`Lots.Container_Complete` and `Lots.Container_Ship` change only *container* status
(Open → Complete → Shipped) and container location — they never touch LOT status. The linked FG LOT
therefore stays `Good` **indefinitely** after its container completes and ships.

Consequence: line-inventory reads (`Lots.Lot_GetLineInventoryByPart`, `Lots.Lot_GetWipQueueByLocation`
and siblings) filter `LotStatusCode <> 'Closed'` and (for on-hand) `InventoryAvailable > 0`. Because a
shipped-out FG LOT is still `Good` with `InventoryAvailable > 0` at the cell where it was minted, it
**lingers in that cell's inventory reads forever** — clutter that misrepresents on-hand stock.

## 2. Goal

Close an FG LOT (`Good → Closed`) at the correct lifecycle point so it drops out of line-inventory and
WIP reads, **without ghosting it** — the LOT must remain fully genealogy-queryable (closure table,
consumption edges, status history all intact).

## 3. Decisions (from brainstorm 2026-08-05)

| # | Decision | Choice |
|---|----------|--------|
| D1 | **Close trigger** | On **Container Complete** — automatic side-effect of `Lots.Container_Complete`; the operator's "final action" is completing the container. No separate operator close step. |
| D2 | **Inventory filtering** | **Rely on `Closed` status only.** No changes to inventory-read procs; no item-type filter. FG shows as on-hand at the cell while `Good` (pre-Complete), disappears once `Closed` (post-Complete). |
| D3 | **Held-tray edge** | **Close the loop on hold-release.** A held FG LOT is skipped by the completion close; when its hold is later released and its container is already Complete/Shipped, close it then. |
| D4 | **Backstop timer** | **None.** Ship the atomic inline close only. A reconciliation timer can be added later if drift is ever observed. |
| D5 | **Mechanism** | **Inline the close** in the mutating procs (mirror `Lots.Lot_UpdateStatus`). Required because both procs are INSERT-EXEC-captured orchestrating procs and cannot `EXEC` a sibling status-row proc (CLAUDE.md § FDS-11-011 / INSERT-EXEC rule). Matches the existing close-at-zero idiom. |

**Rejected alternatives:**
- *Separate `Container_CloseFinishedGoods` proc called by the view after Complete* — two round-trips
  and **non-atomic**: a failure between the two calls leaves the container Complete while its FG LOTs
  stay `Good`, which is exactly the ghost this design eliminates.
- *Item-type filter on inventory reads* — rejected per D2; status-only keeps a single mechanism.
- *Expanding the `Lot_UpdateStatus` transition matrix* — unnecessary; we inline, matching every other
  close site.

## 4. Design

Two touch points, both **inline** and both matching the reference close-at-zero blocks already in
`Assembly_CompleteTray` / `MachiningOut_Mint`.

### 4.1 `Lots.Container_Complete` — primary close

`sql/migrations/repeatable/R__Lots_Container_Complete.sql`

Inside the existing transaction, **immediately after** the container status flip
(`UPDATE Lots.Container SET ContainerStatusCodeId = 2, CompletedAt = SYSUTCDATETIME()`, currently
line 157) and before `COMMIT`:

1. Select the close set: the FG LOTs linked to this container that are still `Good`.

   ```sql
   -- FG LOTs (tray = LOT) to close on container completion
   SELECT l.Id
   FROM   Lots.ContainerTray t
   INNER JOIN Lots.Lot l ON l.Id = t.FinishedGoodLotId
   WHERE  t.ContainerId = @ContainerId
     AND  t.FinishedGoodLotId IS NOT NULL
     AND  l.LotStatusId = @GoodStatusId;     -- 1
   ```

   No `RowVersion` / optimistic-lock check is needed — this is a server-side cascade inside the
   completion transaction, not a client-submitted edit.

2. For each such LOT, **inline** the `Good → Closed` transition (mirror of `Lots.Lot_UpdateStatus`):
   - `UPDATE Lots.Lot SET LotStatusId = @ClosedStatusId (4) WHERE Id = <lotId>;`
   - `INSERT INTO Lots.LotStatusHistory` (OldStatusId = Good, NewStatusId = Closed, changed-by =
     `@AppUserId`, changed-at = `SYSUTCDATETIME()`, Reason =
     `N'Closed on container completion (finished-goods packed & shipping-ready).'`).
   - `EXEC Audit.Audit_LogOperation … @LogEntityTypeCode = N'Lot', @LogEventTypeCode = N'LotStatusChanged'`
     with resolved-name Old/New value JSON per the audit Description convention.

   A set-based `UPDATE` + set-based `INSERT … SELECT` into `LotStatusHistory` is preferred over a cursor
   (all target LOTs take the identical Good→Closed transition). **Audit granularity: one
   `LotStatusChanged` entry per LOT** — consistent with how every other status change is audited and
   keeping per-LOT traceability; emit via a per-LOT loop over the close set (the audit writer is the
   only per-row step).

**Skips (no action, not an error):**
- Trays with `FinishedGoodLotId IS NULL` — pre-`0034` containers and container/shipping test flows that
  fill a container without minting a LOT (`ContainerTray_Close` thin-insert path). Nothing to close.
- FG LOTs not in `Good` status (on `Hold` = 2, or `Scrap` = 3) — a held LOT cannot legally take a
  `Hold → Closed` transition, and closing a held or scrapped LOT would be wrong. Held LOTs are handled
  by §4.2; scrapped LOTs are already terminal.

**Quantities untouched** — `PieceCount` and `InventoryAvailable` are **not** modified. The `Closed`
status alone removes the LOT from `Lot_GetLineInventoryByPart` (filters `<> 'Closed'`) and the WIP
queue (filters `NOT IN ('Closed','Open')`). Preserving the quantities keeps the LOT's produced count
available for traceability and reporting. `LotGenealogyClosure` and `ConsumptionEvent` rows are never
touched by a status change, so genealogy stays fully queryable.

**Transaction / error semantics** — the close runs inside `Container_Complete`'s existing single
transaction under `SET XACT_ABORT ON`. Any failure rolls back the whole completion (container flip +
label + AIM claim + FG closes together) via the existing CATCH `ROLLBACK`. This is what makes the ghost
window unreachable: completion and FG-close are atomic — all-or-nothing. No new terminal SELECT or
OUTPUT param is introduced; the proc's contract
(`SELECT @Status, @Message, @ShippingLabelId, @AimShipperId`) is unchanged.

### 4.2 `Quality.Hold_Release` — close the held-tray loop

`sql/migrations/repeatable/R__Quality_Hold_Release.sql`

`Hold_Release` already restores a released LOT to its prior status (typically `Good`) inline, writes a
`LotStatusHistory` row, and audits `HoldReleased`. Extend it: after the status restore, if **all** of
the following hold, inline-close the LOT:

- the released hold targets a **LOT** (`LotId` set, not a container hold), **and**
- that LOT is an FG tray LOT: `EXISTS (SELECT 1 FROM Lots.ContainerTray WHERE FinishedGoodLotId = @LotId)`, **and**
- its container is **Complete (2)** or **Shipped (3)**
  (join `ContainerTray → Container.ContainerStatusCodeId`), **and**
- the restore left the LOT in `Good` status.

Then inline `Good → Closed` exactly as §4.1 (status flip + `LotStatusHistory` Old=Good/New=Closed,
Reason `N'Closed on hold-release (container already complete).'` + `LotStatusChanged` audit).

This produces **two** `LotStatusHistory` rows for the single release (Hold→Good restore, then
Good→Closed) — deliberate and traceable: the record shows the hold was released to Good and the LOT was
then closed because its container had already shipped.

**Unaffected:**
- **Container-hold releases** — no `LotId`, no FG LOT; the new block is skipped.
- **Non-FG LOT holds** — the `ContainerTray.FinishedGoodLotId` existence check fails; skipped.
- **Recall scenario** (`Closed` FG LOT → hold placed → later released): `Hold_Release` restores the LOT
  to its **prior** status, which was `Closed`, so it returns to `Closed` naturally; the new block's
  "restored to `Good`" precondition is false, so no double action.

Like §4.1, this is inline (mirror of `Lot_UpdateStatus`) because `Hold_Release` is INSERT-EXEC-captured
and returns its own status row (`SELECT @Status, @Message`) — it cannot `EXEC Lot_UpdateStatus`. Runs
inside the proc's existing transaction; no contract change.

## 5. No reversal handling

There is no Complete → Open transition anywhere. `Lots.ShippingLabel_Void` only marks a label
`IsVoid = 1`; it does **not** reopen the container or reverse its status. The FG close is therefore a
safe one-way transition aligned with the container's one-way Open → Complete → Shipped lifecycle. No
un-close path is designed.

## 6. Testing

New test file(s) under `sql/tests/0029_PlantFloor_Hold_Sort_Shipping_Aim/` (alongside the existing
Hold and Container-Complete/Ship tests). Assertions:

1. **Full-container complete closes all Good FG LOTs.** Complete a full container with N linked FG-LOT
   trays → every FG LOT is now `Closed`, each with a `LotStatusHistory` row (Good→Closed) and a
   `LotStatusChanged` audit entry.
2. **Dropped from line inventory.** After completion, `Lot_GetLineInventoryByPart` at the mint cell no
   longer returns the closed FG LOTs.
3. **Genealogy intact.** `LotGenealogyClosure` / consumption edges for a closed FG LOT still resolve
   (the LOT remains queryable).
4. **NULL-tray untouched.** A tray with `FinishedGoodLotId IS NULL` in the same container is unaffected
   and does not error the completion.
5. **Held-tray skip + re-close.** Place a hold on one tray's FG LOT, complete the container → that FG
   LOT stays open (Hold), the others close. Release the hold → the FG LOT closes (`Good → Closed`),
   two `LotStatusHistory` rows present.
6. **Container-hold release unaffected.** Releasing a container-level hold performs no FG close.
7. **Atomicity (optional).** Force a failure after the status flip (e.g. a broken audit dependency in a
   throwaway DB) and assert the whole completion rolls back — container stays Open, FG LOTs stay Good.

## 7. Files

| File | Change |
|------|--------|
| `sql/migrations/repeatable/R__Lots_Container_Complete.sql` | Add inline FG-close loop after the container status flip, inside the existing transaction. Bump proc version + header note. |
| `sql/migrations/repeatable/R__Quality_Hold_Release.sql` | Add inline re-close block after status restore for FG tray LOTs whose container is Complete/Shipped. Bump proc version + header note. |
| `sql/tests/0029_PlantFloor_Hold_Sort_Shipping_Aim/…` | New/extended test(s) per §6. |
| (migration number) | **Likely none** — both changes are to *repeatable* procs, which redeploy without a versioned migration. Confirm during planning; if a versioned migration is needed only to carry test seed, take the next free number (highest committed `0050`, `0051` reserved for #3 → `0052`) and confirm no collision. |

## 8. Out of scope

- Item-type-based inventory filtering (D2 chose status-only).
- Expanding the `Lots.Lot_UpdateStatus` transition matrix (we inline, matching existing procs).
- A dedicated FG-staging inventory read.
- A nightly reconciliation backstop timer (D4).
- Any AIM / Honda hold notification work (that is FAT #17, Handoff D — separate spec).
- Closing FG LOTs on `Container_Ship` rather than `Container_Complete` (D1 chose Complete).

## 9. Revision History

| Date | Change | Author |
|------|--------|--------|
| 2026-08-05 | Initial design from brainstorm (decisions D1–D5). | Blue Ridge Automation |
