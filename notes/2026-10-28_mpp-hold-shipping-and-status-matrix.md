# MPP questions: hold parts vs shipping, and a part status matrix (2026-10-27/28)

**Status (2026-10-29):** Jacques ruled on the open questions (see "Rulings" at the end). The
reply email (below) and the matrix doc
([MES Part Status Matrix and Hold Controls](https://claude.ai/artifact/4oj5aZFBjVRxNsLbgCymgs))
are **ready for Jacques to send. Nothing sent to MPP.** The tray-hold fix is built (Rulings 1). Prod untouched;
everything below came from reading the SQL and read-only queries on `MPP_MES_Dev`.

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

## Rulings (Jacques, 2026-10-29)

1. **Tray-hold gap: a LOT hold should block its containers.** Re-verified against the procs on
   2026-10-29 (`Container_Ship` line 54 checks only container holds, line 67 only `CrtActive`;
   `Container_Complete` lines 222-230 skip a held tray but still complete; `Hold_Place` accepts a
   Closed LOT). Told to MPP as a small, separately quoted change. Write-up:
   `notes/2026-10-29_followon-tray-lot-hold-blocks-container.md`. **Built the same day**
   (`Container_Ship` v1.1 + test `035_Container_Ship_lot_hold.sql`); not in prod yet.
2. **"Documentation": ask MPP what they mean.** If it is a missing-paperwork hold (certs, PPAP),
   it is one new `HoldTypeCode` row.
3. **High inventory on pass-through parts + daily order-vs-inventory monitor: new projects.**
   MES has no integration with MPP's ERP, no production orders and no shipping tie-in beyond AIM.
   Both need ERP / production-scheduling integration and deeper AIM integration -- doable, but an
   engineering effort to scope.
   *Correction to the earlier draft:* MES has no "low-inventory lock". What exists is the
   consumption-point cap (`Parts.ItemLocation.MaxQuantity`; `Lots.Lot_Create` refuses a Received
   LOT past it) and the M&A Line Inventory panel colouring (orange <= 30 % of Max, red <= 10 %).
   The low-inventory toast was retired 2026-09-17 (migration 0095).
4. **Format:** email text + a one-page matrix doc for their meeting.

Still open in the doc: whether to keep the container "Rework" row (Controlled Run release, not
in prod yet) -- comment left for Jacques on the doc.

## Reply email (draft, Jacques's voice -- ready to paste)

> Subject: MES -- held parts and part status matrix
>
> Hi all,
>
> Following up on the two items from the business plan. The detail and the matrix are in the
> attached one-pager; the short version:
>
> **1. Can held parts ship?** No, as long as shipments are scanned out in MES. Quality can hold a
> LOT or a container in MES. A held LOT cannot be moved, consumed, machined, assembled or packed,
> and the Shipping Dock scan refuses a held container. Release restores the previous status, and
> both steps are recorded with who and when.
>
> One case is not covered yet: holding a single finished-good tray does not stop the container
> it is packed in, unless the container is held as well. We recommend closing that with a small
> change, which we will quote separately.
>
> To retire the manual hold tags, MPP would need to (a) place holds in MES instead of on paper,
> and (b) scan every shipment out at the MES Shipping Dock, since that scan is where the block
> is enforced. Lines still running in parallel with the legacy system keep the current hold
> process until they cut over.
>
> **2. Part status matrix.** DC, TS, MS and FG are stages in the process rather than statuses.
> MES tracks the part type, the process stage, the LOT status (Open, Good, Hold, Scrap, Closed),
> the hold reason and the container status (which decides whether it can ship). The one-pager
> maps your terms to those and lists what each status allows. We left the ownership column for
> you to fill in.
>
> Two questions back to you:
> - "Documentation" -- we could not find an equivalent in MES. What does it mean for you? If it
>   is a hold for missing paperwork (certs, PPAP), that is a new hold type and a configuration
>   change.
> - The high-inventory comment for pass-through parts and the daily order-versus-inventory
>   monitor both need data MES does not have today: MES is not connected to your ERP,
>   production orders or schedule. Those would be new projects (ERP and scheduling integration
>   plus a deeper AIM integration). Very doable, but an engineering effort we should scope
>   together.
>
> Happy to walk through it on Thursday's call.
>
> Jacques

Cost figures are deliberately absent -- pricing is Jacques's call.
