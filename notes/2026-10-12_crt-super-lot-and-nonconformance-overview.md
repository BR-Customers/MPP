# CRT super-lot + nonconformance: what the two change orders really are

**Date:** 2026-10-12
**Branch:** `jacques/working`
**Status:** Exploration complete. Nothing built. Spec for piece 1 drafted:
`docs/superpowers/specs/2026-10-12-controlled-run-super-lot-design.md`.
**Audience:** a future session picking this up cold. Read this before touching CRT,
holds, scrap-from-container, or anything called "nonconformance".

---

## 1. The two requests

MPP raised two change orders. They were written separately; they are one feature.

| | Change order A: "Super-lot" | Change order B: "Nonconformance" |
|---|---|---|
| Asks for | Group soft-held LOTs into a super-lot; super-lot label; FIFO rolling start/end boundary; bulk release | Deviation + approval workflow with dispositions (Pending, Use-As-Is, Rework, Scrap, Return to Vendor); elevated e-signature for Quality; status visible on Lot Detail, genealogy, dashboards |
| Says the baseline is | Per-LOT CRT hold and release (design approved 2026-08-19) | NCM/Failure Analysis is FUTURE; a "placeholder" exists in the data model; Intelex integration out of scope |

## 2. Vocabulary (settled with Jacques 2026-10-12)

- **Soft-held** = `Lots.Lot.CrtActive = 1`. Not a `Quality.HoldEvent`. The LOT's status
  stays `Good`.
- **Super-lot** = any set of LOTs and/or containers grouped for one quality action, picked
  by time, production line, part, genealogy, or by hand. MPP's example: a customer reports
  a problem traced to one LOT; MPP puts everything produced from that LOT up to now on
  CRT. That grouping is the super-lot.
- **200% / double inspection** is NOT forced by the system. Practically, Quality confirms
  on release that the CRT was acted on and the inspection was completed.
- **Nonconformance** (as MPP uses the word) = the outcome where Quality decides the issue
  does not affect part performance and accepts a deviation. It is issued AFTER the CRT
  inspection, as one possible result of it.
- **Rework / Scrap / Return to Vendor** are needed, but Jacques did not think of them as
  part of "the nonconformance". They are the other outcomes of the same inspection.

## 3. The real-world sequence

1. A problem is recognised (customer notification, line finding, equipment down).
2. Quality puts a set of material on CRT. That set is the super-lot.
3. Material is inspected on the floor. Finished containers are pulled from the warehouse
   and every part is taken out and inspected, one at a time. ("It's gnarly.")
4. Per unit inspected, the outcome is one of: good, scrap, rework, return to vendor.
5. Quality releases the group, confirming the CRT was acted on.
6. If a deviation was found and judged acceptable, Quality issues the nonconformance
   (Use-As-Is with a signed deviation).
7. Containers that lost parts are topped back up to full count, by consolidating good
   parts from other containers or with new production. Containers are reused and
   **relabelled with a NEW Honda shipper serial; the old serial is voided.**

So: change order A is "open and group"; change order B is "disposition and sign".
"Pending" in B's disposition list is simply a super-lot that is still open.

## 4. What exists today (verified in code 2026-10-12)

### CRT

- One bit: `Lots.Lot.CrtActive` (migration `0020`).
- Set at mint by `Lots.ufn_CrtForMint` (part flag `Parts.Item.CrtEnabled`, OR terminal
  attribute `CrtEnabled`, OR any consumed input is CRT-active). Called from
  `DieCastLot_Open`, `DieCastLot_Mint`, `Lot_Create`, `MachiningOut_Mint`,
  `Assembly_CompleteTray`, `Lot_Split`, `Lot_Merge`.
- Set/cleared by hand: `Lots.Lot_SetCrt` / `Lots.Lot_ClearCrt` (Lot Detail toggle,
  elevation action `CrtToggle`). **`Lot_SetCrt` refuses a Closed LOT. `Lot_ClearCrt`
  allows one.**
- Blocks: `Lots.ufn_CrtBlocksAdvance`, `Lots.ufn_CrtBlocksMoveTo` (production
  destinations only, via `LocationTypeDefinition.IsProductionDestination`). Wired into
  `Lot_MoveTo(Validated)`, `Assembly_ScanIn`, `MachiningIn_RecordPick`,
  `MachiningOut_Mint` (scan only), `Lot_Split`, `Lot_Merge`. `Container_Ship` refuses a
  CRT-active FG LOT. `AimShipperIdPool_ListUnposted` holds the AIM post back.
- Container path: a container has NO CRT flag. It carries it on its trays'
  finished-good LOTs (`ContainerTray.FinishedGoodLotId`). `Lots.Container_ValidateCrt`
  releases one container; the `CrtValidation` popup elevates once for many rows.
- 200% surface: `Quality.Crt_GetRequiredInspections` and
  `Quality.Crt_FlagMissedInspection` exist. **No view calls either.**
- The only record of a release is a `CrtCleared` audit row (entity `Lot`, lands in
  `Lots.LotEventLog`).
- Label: `CrtBanner` template is the static word "CRT", appended as a second ZPL
  document by `LotLabel_Print` / `_Reprint`. No tokens.
- Specs: `docs/superpowers/specs/2026-08-14-crt-container-validation-design.md`,
  `2026-08-19-crt-part-scoped-design.md` (D6 there = "clearing is per-LOT only, a bulk
  action can be added later without reshaping anything").

### Holds

- `Quality.HoldEvent` (migration `0029`): `LotId` XOR `ContainerId`, one open hold per
  target, free-text release remarks. LOT status goes to `Hold` (`BlocksProduction = 1`).
- **Built WITHOUT** the documented `NonConformanceId` column and without the
  `ReleaseDispositionCode` that FDS-10-012 describes.
- `BlueRidge.Quality.Hold.placeBulk` loops the per-LOT proc in Python (one audit row
  per LOT).

### Nonconformance

- **`Quality.NonConformance` does not exist in the database.** It is described in
  `MPP_MES_DATA_MODEL.md` and FDS 8.6 only. `notes/2026-09-03_data-model-doc-drift.md`
  already lists it as "described but never built".
- `Quality.QualityAttachment` was built without `NonConformanceId`.
- `Quality.DispositionCode` exists with FOUR rows: `UseAsIs`, `Rework`, `Scrap`,
  `ReturnToSupplier`. No `Pending`. The change order says "Return to Vendor".
- So change order B's "placeholder in the underlying data model" is a spec, not a table.
  Relevant to estimating, not to design.

### Scrap

- `Workorder.RejectEvent_Record`: one LOT, one defect code + quantity. Refuses status
  `Hold` (unless `@AllowHeldLot = 1`), `Scrap`, `Closed`, `Open`. **No CRT guard**, so a
  CRT-active WIP LOT can be scrapped today.
- `Workorder.RejectEvent_RecordByPartFifo` (in progress in the working tree, v1.1):
  scrap by part at a line, spread FIFO across `Good` LOTs. It does not look at
  `CrtActive`, so it spreads across CRT and clean LOTs alike.
- **A finished-good LOT in a completed container cannot be scrapped** — it is Closed.

### Containers / repack

- Statuses: `Open`, `Complete`, `Shipped`, `Hold`, `Void`. No proc reopens a completed
  container.
- `Lots.SortCage_MigrateSerial` moves ONE serialized part between containers
  (`ContainerSerialHistory` trail). Nothing handles non-serialized pieces.
- `ShippingLabel_Void` / `_Reprint` exist. AIM serials are consumed permanently
  (2026-08-14 decision); FDS-07-012 anticipates `UpdateAim` with `previousSerial`.

### Elevation / signature

- Per-action AD credential check (`BlueRidge.Location.AppUser.elevate`, stateless) or a
  windowed form (`Common.Session.requireElevation` -> `beginElevatedWindow`, which makes
  the supervisor the session user). Audit row from `AppUser_AuthenticateAd`.
- **No role gate.** Any active AD-mapped `AppUser` passes. "Quality-only" is not
  enforceable today. Jacques intends to add AD roles.
- Nothing stores a signature as a durable record of who approved what, with what meaning.

### Views

No existing view works on a group. Nearest: `ShopFloor/HoldManagement` (real holds, per
LOT), `ShopFloor/SortCageWorkflow` (serial migration; partly stubbed),
`ShopFloor/InspectionEntry` (one LOT, spec-driven), `ShopFloor/LotDetail` (one LOT).
`ShopFloor/ThirdPartyInspection` was not inspected.

## 5. Decisions landed

| # | Decision | Source |
|---|---|---|
| 1 | The two change orders are designed as one feature with a shared core: a quality case covering many LOTs/containers, closed by a signed disposition. | Agreed in discussion |
| 2 | The super-lot is a STORED MEMBER LIST, not a rule. The "FIFO rolling window" is only how members get picked, so it can be time, line, part, shift, count or genealogy without the structure changing. MPP has not said which. | Jacques asked "could it be any of those?" — yes |
| 3 | The system does not force the 200% inspection. Release records a confirmation that it was done. | Jacques |
| 4 | Retroactive CRT on already-completed containers must be made possible. Today it is not. | Jacques: "we certainly have to repair that" |
| 5 | Scrap, Rework, Return to Vendor and Use-As-Is are outcomes of the super-lot inspection, recorded per member. The nonconformance is the Use-As-Is outcome with a signed deviation. | Agreed in discussion |
| 6 | Scrap is entered per member (the inspector knows which container the bad part came from), on one screen, one submit. Not spread across the group. | Recommended; Jacques did not object |
| 7 | All of this lives in a NEW dedicated Quality view, not in an existing one. | Jacques |
| 8 | A topped-up container is relabelled with a NEW shipper serial; the old one is voided. | Jacques |
| 9 | **All six pieces are built before any of it is released.** Pieces must not be deployed apart (piece 1 lists completed containers that only piece 2 can block). | Jacques |
| 10 | The super-lot label is per super-lot, not per member: four copies per request, on demand, made to stand out. Its barcode opens the full super-lot in the Quality view, where all management happens. | Jacques |
| 11 | The generic CRT banner still prints for a LOT that is in a super-lot. | Jacques |
| 12 | "Produced at a line" means where the LOT was minted. Run number is `NVARCHAR(15)`. | Jacques |

## 6. The six pieces, in dependency order

1. **The case (super-lot):** header, member list, selection, open-ended auto-join, label,
   the dedicated view. *Spec drafted.*
2. **Retroactive CRT on completed containers**, including what happens to an AIM serial
   that has already been posted.
3. **Results and sign-off:** per-member counts, scrap including Closed LOTs, bulk signed
   release with the "200% done" confirmation, the Use-As-Is deviation record, a
   Quality-only gate.
4. **Container repack:** remove bad parts, top up by consolidation or new production,
   void the old serial, issue and post a new one.
5. **Rework and Return to Vendor** as dispositions with real material effects.
6. **Visibility:** Lot Detail, genealogy, reports, dashboards.

Mapping to the change orders: A = pieces 1 + the bulk-release half of 3. B = the rest of
3, plus 5 and 6. **Piece 2 and piece 4 are in neither change order's wording**, but the
warehouse example cannot finish without them. Worth raising before the change orders are
priced.

## 7. Open questions (not yet asked or not yet answered)

- What actually opens and closes the rolling window at MPP (they do not know yet).
- When a posted AIM serial's container goes on CRT retroactively, what does Honda need
  (`PlaceOnHold`? nothing until it is voided?).
- Rework: does a reworked part stay in its LOT, or leave and come back?
- Return to Vendor: received material only? What is the paperwork?
- Does top-up by new production mean an assembly line finishing a container it did not
  open? Not checked whether Assembly OUT can target an existing part-full container.
- Non-serialized piece moves between tray LOTs: how to keep genealogy honest.
- `Assembly_CompleteTray` does write `CreatedAtTerminalId` on the FG LOT (it is in the
  INSERT column list), so containers can be selected by production line through their
  tray LOTs. Whether it is always non-NULL in practice was not checked against data.
- Do MPP also raise an Intelex record for a CRT today? Asked, not answered directly.

## Revision History

| Date | Change |
|---|---|
| 2026-10-12 | Initial write-up from the exploration session. |
