# MPP questions: hold parts vs shipping, and a part status matrix (2026-10-27/28)

**Status:** investigation done, answer drafted, **nothing sent to MPP and nothing built**. Two
questions are waiting on Jacques (end of this note) before the reply goes out. Dev and prod
untouched; everything below came from reading the SQL and read-only queries on `MPP_MES_Dev`.

## The ask

From MPP's monthly business plan (PC section of their slide):

> - Confirm with new MES system that hold parts cannot be shipped. Eliminate Manual hold tags
> - Centralized location monitor for daily order versus inventory
> - Make a matrix for each part status on MES (DC, TS, MS, FG, documentation, etc.)
> - For passthrough parts include high inventory parts comment also

Their follow-up email (paraphrased): (1) can MES prevent held parts from shipping, what
functionality exists, and what MPP would need to do to drop manual hold tags; (2) a brief
explanation of each part status (DC, TS, MS, FG, Documentation, ...) leading to a simple matrix
of status, ownership, transaction limits and shipment authorization; plus any cost /
programming / configuration effort for either. A catch-up call on MES status was proposed for
Thursday. Jacques wants a **data-driven** answer.

## 1. Can a part on hold be shipped?

**No, provided the container is shipped by scanning it in MES.**

What is enforced (file references are `sql/migrations/repeatable/`):

- `R__Quality_Hold_Place.sql` -- holds one LOT or one container; LOT -> status `Hold` (2,
  `BlocksProduction=1`) + `LotStatusHistory`; container -> status `Hold` (4). One open hold per
  target. Hold types (`Quality.HoldTypeCode`): Quality, CustomerComplaint, Precautionary,
  Changeover.
- A held LOT is stopped in production: 19 procs check `Lot_AssertNotBlocked` / `BlocksProduction`
  (MoveTo, MoveToValidated, Split, Update, UpdateAttribute, RectifyPieceCount, LotPause_Place,
  LotGenealogy_RecordConsumption, TrimOut/TrimPartial, MachiningIn_RecordPick, MachiningOut_Mint,
  Assembly_ScanIn, Assembly_CompleteTray, ProductionEvent_Record, RejectEvent_Record, ...).
- `R__Lots_Container_Ship.sql` refuses: not Complete; an open `HoldEvent` on the container
  ("Container is on hold (cannot ship)"); a tray FG LOT with `CrtActive = 1`; a void label.
- `R__Quality_Hold_Release.sql` restores the prior LOT status (from `LotStatusHistory`) or the
  container's pre-hold status, audited.

What MPP must do to drop manual hold tags (mostly process, not code):

- **Every shipment is scanned out at the Shipping Dock screen** (`ShopFloor/ShippingDock`,
  `BlueRidge.Lots.Shipping.ship`). It is the only UI that marks a container shipped. Its queue /
  manifest / stats panels are still placeholders. Jacques had asked to remove that screen and
  benched it on 2026-09-17 (`notes/2026-09-17_handoff-aim-failure-log-and-shipping-reprint.md` §3);
  this answer depends on keeping it.
- Terminals with `SuppressAimAndLabel` (parallel run beside legacy) issue no MES label / AIM
  number, so the block only applies where MES does the shipping.
- AIM `PlaceOnHold` / `ReleaseFromHold` for already-shipped containers are SIM stubs in
  `BlueRidge/Lots/AimPoolGateway/code.py`; contract detail still open.

**Suspected gap -- raise with Jacques as a question, do not fix on spec:** `Container_Ship`
checks only holds placed on the *container*. A hold on a finished-good tray LOT does not block
its container: `Container_Complete` still completes (it just skips closing the held tray), and
`Container_Ship` then ships it unless someone also held the container.
`Quality.Hold_ListAssociatedContainers` only warns on the Hold Management screen. From reading
the code, not run. Open question: is holding the container too meant to be the operator's job,
or should a LOT hold block the containers it is in (small SQL change + tests)?

## 2. Part status matrix

Key message for MPP: **DC / TS / MS / FG are process stages, not statuses.** MES records
separate pieces of information; the matrix should have a column for each.

| Piece of information | Values (Dev, 2026-10-27) | Answers |
|---|---|---|
| Part type (`Parts.ItemType`) | Component 69, SubAssembly 27, FinishedGood 48, PassThrough 32 (active items) | What the part is |
| Process stage (route `OperationType`) | DieCast, TrimIn/Out, MachiningIn/Out, AssemblyIn/Out (+ CNC) | Where it is (DC/TS/MS/FG) |
| LOT status (`Lots.LotStatusCode`) | Open, Good, Hold, Scrap, Closed | Can it be worked on |
| Hold type (`Quality.HoldTypeCode`) | Quality, Customer Complaint, Precautionary, Changeover Freeze | Why it is stopped |
| Container status (`Lots.ContainerStatusCode`) | Open, Complete, Shipped, Hold, Void, ReworkProcessing, ReworkFilling | Can it ship |

Mapping MPP's terms:
- **DC:** casting LOT created at the press (OriginMint); **Open** while the basket fills, **Good**
  on release.
- **TS:** same casting LOT through TrimIn/TrimOut (Advance); status unchanged.
- **MS:** MachiningIn (Advance) then MachiningOut, which mints a SubAssembly LOT only on lines
  with a Machining OUT terminal.
- **FG:** AssemblyOut mints the FG tray LOT; trays go into a container Open -> Complete ->
  Shipped. Only containers ship.
- **Pass-through:** received finished, inspected, repacked under the same part number
  (`Assembly_CompleteTray` no-BOM path). Note the open part-type recategorization TODO at the top
  of `PROJECT_STATUS.md` -- today's `PassThrough` code is really "Components"; the matrix wording
  should follow whatever that lands on.

What each LOT status allows (from the code):

| Status | Worked on / moved? | Ships? |
|---|---|---|
| Good | Yes | Yes, in a Complete, unheld, CRT-validated, validly labelled container |
| Open | Only by die cast while the basket fills | No |
| Hold | No | No (see gap above) |
| Scrap | No | No |
| Closed | No (consumed or packed) | As part of its container |

Ownership is not modelled in MES -- MPP fills that column (e.g. Quality owns holds).

## Effort / cost (as framed so far)

- Item 1: mostly process (dock scan discipline, keep the Shipping Dock screen). Optional code:
  LOT hold blocks its containers; finish AIM hold notifications.
- Item 2: documentation only; every row already exists in the system.
- Pricing is Jacques's call -- no figures given.

## Waiting on Jacques

1. The suspected gap above: operator job, or should LOT holds block containers?
2. "Documentation" in MPP's list -- no MES equivalent found. Missing-paperwork hold (certs, PPAP)?
   That would be a fifth `HoldTypeCode` row.
3. (Side item) "high inventory" comment for pass-through parts -- MES has a low-inventory lock
   only; high-inventory would be new work. Also "centralized location monitor for daily order
   versus inventory" on the slide was not investigated.

## Next steps once answered

Turn sections 1-2 into the reply to MPP (and optionally a one-page matrix document for their
meeting), in Jacques's voice. Do not build anything without agreement.
