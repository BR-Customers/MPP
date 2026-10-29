# Follow-on: a held finished-good tray LOT should block its container from shipping (2026-10-29)

**Status:** agreed by Jacques 2026-10-29 ("LOT hold should block"). **Built 2026-10-29 on
`jacques/working`, uncommitted at time of writing; not in prod** (needs the normal prod release). Raised from the MPP hold/shipping question
(`notes/2026-10-28_mpp-hold-shipping-and-status-matrix.md`). Quoted to MPP as a small, separately
priced change.

## The gap (verified 2026-10-29 against `jacques/working` @ a7a857ad)

- `Lots.Container_Ship` (`sql/migrations/repeatable/R__Lots_Container_Ship.sql:54`) refuses only
  when an open `Quality.HoldEvent` has `ContainerId = @ContainerId`. Its only per-tray check is
  `CrtActive = 1` (line 67). It never looks at the tray LOT's `LotStatusId`.
- `Lots.Container_Complete` (`R__Lots_Container_Complete.sql:222-230`) closes only tray LOTs with
  `LotStatusId = 1` (Good). A held tray is skipped, but the container still goes Complete.
- `Quality.Hold_Place` does not refuse a Closed LOT, so a tray can be held after its container
  completed. The container stays Complete and still ships.
- The Hold panel (`Components/PlantFloor/Quality/HoldPanel`) only toasts "N associated
  container(s) - review whether they need holding too" via `Quality.Hold_ListAssociatedContainers`.

Reproduced 2026-10-29 by the new test on a throwaway DB (see "What was built"); Dev untouched.

## Design rulings (Jacques, 2026-10-29)

1. **Enforce at ship.** `Lots.Container_Ship` v1.1 refuses when any LOT packed in the container
   has an open hold, and names that LOT in the refusal ("LOT <name> in this container is on hold
   (cannot ship)."). No hold cascade; the container still shows Complete.
2. **Reach = tray LOT + packed serials' producing LOT** -- the same two paths as
   `Quality.Hold_ListAssociatedContainers`. Serials with `RemovedAt` set are ignored. Upstream
   ancestors (a held casting whose parts are already packed) are deliberately not followed.
3. **`Container_Complete` unchanged.** It still completes with a held tray; `Hold_Release`
   already closes the tray afterwards (FAT #21 block), so release needed no change.

## What was built

- `sql/migrations/repeatable/R__Lots_Container_Ship.sql` v1.1 -- the check, placed after the
  container-hold check and before the CRT check.
- `sql/tests/0029_PlantFloor_Hold_Sort_Shipping_Aim/035_Container_Ship_lot_hold.sql` -- tray held
  before completion (completes, ship refused and names the LOT, stays Complete, ships after
  release); tray held after completion (recall) blocks; a packed serial's held producing LOT
  blocks; once that serial is removed it no longer blocks. Before the change the file failed
  6 of 11 asserts on a throwaway DB (container A shipped with a held tray), which confirmed the gap
  live.

## Left open

- The Hold panel toast ("review whether they need holding too") is now slightly misleading --
  the containers can no longer ship. Wording change is Ignition-side, not done.
- Prod: ships with the next release (repeatable proc only, no migration).
