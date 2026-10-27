# Super-lot / hold refusal and inheritance facts (sales-kit module 4)

Task 1 of `docs/superpowers/plans/2026-10-27-mes-sales-kit-module-4-quality.md`. Every refusal or
tagging claim in module 4 (deck caption, note, tour step, demo error message) cites a row here.
A claim with no row is not made. Read from the repeatables on `jacques/working`, 2026-10-27.
Paths are under `sql/migrations/repeatable/`; tests under `sql/tests/`.

Terms: **hard Hold** = LOT status `Hold` (`LotStatusCode.BlocksProduction = 1`; `Scrap` is the other
blocking status). **CRT / tagged** = `Lots.Lot.CrtActive = 1`; status stays `Good`. `<RN>` = the
open super-lot's run number (`Quality.ufn_OpenControlledRunForLot`); when the LOT is in no open
super-lot the ` (super-lot <RN>)` part is simply absent.

## Refusals at the stations

| Id | Action | Proc (file:line) | Refuses when | Message | Test |
|---|---|---|---|---|---|
| F1 | Machining IN pick of a held LOT | `R__Workorder_MachiningIn_RecordPick.sql:115` | status blocks production (or Closed / Open) | `LOT is Hold (status Hold) and cannot be picked; release the hold first.` | `0027_PlantFloor_Machining/030_MachiningIn_NoTrimRoute.sql` |
| F2 | Machining IN pick of a tagged LOT | `R__Workorder_MachiningIn_RecordPick.sql:133` (`ufn_CrtBlocksAdvance`) | `CrtActive = 1` | `LOT <name> is marked CRT (super-lot <RN>) and cannot be used until Quality clears it.` | `0064_Crt_PartScoped/060_enforcement.sql` |
| F3 | Machining OUT mint from a held casting | `R__Workorder_MachiningOut_Mint.sql:138` | status blocks production | `Source LOT is Hold and cannot be consumed.` | `0027_PlantFloor_Machining/070_MachiningOut_Mint.sql` |
| F4 | Machining OUT mint from a tagged casting (the scanned source) | `R__Workorder_MachiningOut_Mint.sql:149` | `CrtActive = 1` on `@SourceLotId` | `LOT <name> is marked CRT (super-lot <RN>) and cannot be used until Quality clears it.` | `0064_Crt_PartScoped/060_enforcement.sql` |
| F5 | Assembly scan-in of a held LOT | `R__Workorder_Assembly_ScanIn.sql:66` | status blocks production | `LOT <name> is Hold and cannot be scanned in.` | untested (show only if captured) |
| F6 | Assembly scan-in of a tagged LOT | `R__Workorder_Assembly_ScanIn.sql:115` (`ufn_CrtBlocksMoveTo`) | `CrtActive = 1` and the cell is a production destination | `LOT <name> is marked CRT (super-lot <RN>) and cannot be moved to a production location until Quality clears it.` | `0064_Crt_PartScoped/060_enforcement.sql` |
| F7 | Move (plain or validated) of a held LOT | `R__Lots_Lot_MoveTo.sql:88`; `Lot_MoveToValidated` inline mirror (`:91`) | status blocks production | `LOT is Hold (status Hold) and cannot be moved.` | `0029_.../010_Hold_Place_release.sql` |
| F8 | Move of a tagged LOT to a production location | `R__Lots_Lot_MoveTo.sql:136`, `R__Lots_Lot_MoveToValidated.sql:265` (`ufn_CrtBlocksMoveTo`) | `CrtActive = 1` and destination `IsProductionDestination = 1` (not for a rework move) | `LOT <name> is marked CRT (super-lot <RN>) and cannot be moved to a production location until Quality clears it.` | `0064_Crt_PartScoped/060_enforcement.sql` |
| F9 | Move of a tagged LOT to inspection / inventory / receiving / support | same | **not refused** -- suspect material can still be taken to quarantine | -- | `0064_Crt_PartScoped/030_crt_blocks.sql` |
| F10 | Split / merge of a tagged or held LOT | `R__Lots_Lot_Split.sql:247,310`, `R__Lots_Lot_Merge.sql:331` | hold: `... cannot be split; release the hold first.`; CRT: `LOT <name> is marked CRT (super-lot <RN>) ...` (merge names every tagged source) | (as left) | `0064_Crt_PartScoped/060_enforcement.sql` |
| F11 | Ship a container with an open hold | `R__Lots_Container_Ship.sql:54` | open `Quality.HoldEvent` on the container | `Container is on hold (cannot ship).` | `0029_.../030_Container_Ship.sql` |
| F12 | Ship a container holding a tagged tray LOT | `R__Lots_Container_Ship.sql:69` | any tray's finished-good LOT `CrtActive = 1` | `Container is pending Controlled Run Tag validation (cannot ship).` | `0056_CrtValidation/070_Ship_blocked_when_pending.sql` |
| F13 | Shipper ID / serial held back for a tagged container | `R__Lots_AimShipperIdPool_ListUnposted.sql:73` | a tray FG LOT `CrtActive = 1` | (no message: the container is left out of the unposted list) | `0056_CrtValidation/040_ListUnposted_excludes_held.sql` |

## Tagging (born tagged) and consumption

| Id | Fact | Source | Test |
|---|---|---|---|
| F20 | A new LOT is tagged at mint if ANY of: (1) its part has `CrtEnabled`; (2) the minting terminal has the `CrtEnabled` attribute; (3) any consumed input LOT is tagged ("sticky"); (4) an OPEN super-lot with "keep adding new production" covers this part and names no line or a location at/above the minting terminal. Evaluated at mint time only; nothing re-derives it later. | `R__Lots_ufn_zz_CrtForMint.sql` header | `0064_Crt_PartScoped/020_crt_for_mint.sql`, `0109_ControlledRun/070_resolver_arm.sql` |
| F21 | Mint points that use F20: Die Cast basket open, Machining OUT mint, Assembly complete-tray. | same header | `0064_Crt_PartScoped/050_mint_procs.sql` |
| F22 | Membership of an auto-joined LOT is recorded afterwards by `Quality.ControlledRun_SyncInternal`; the LOT is tagged in the mint transaction itself. | F20 header | `0109_ControlledRun/080_sync.sql` |
| F23 | **`Assembly_CompleteTray` with a tagged input does NOT refuse.** It consumes the tagged sub-assembly / component and mints the finished-good tray LOT tagged (arm 3, re-resolved after consumption: `R__Workorder_Assembly_CompleteTray.sql:545-554`). Held (`BlocksProduction`) sources are skipped, not consumed (`:250`, `:279`, `:490`). | as cited | `0064_Crt_PartScoped/040_propagation.sql`, `0028_PlantFloor_Assembly/097_Assembly_CompleteTray_skips_held_source.sql` |
| F24 | So a tagged part that reaches a tray makes the tray tagged, and the container it is packed into cannot ship (F12) and its shipper ID is held (F13). Kit wording: assembly "carries the tag onto the tray", never "Assembly refuses it" -- except at scan-in (F6). | F12, F13, F23 | -- |

## Queues

| Id | Fact | Source |
|---|---|---|
| F30 | `Lot_GetWipQueueByLocation` still lists held and tagged LOTs (it filters only `Closed` / `Open`). The operator sees them and the pick / mint refuses (F1-F4). | `R__Lots_Lot_GetWipQueueByLocation.sql:76` |

## Results, deviation, release, close

| Id | Fact | Source | Test |
|---|---|---|---|
| F40 | Recordable outcomes: `Accepted`, `Scrap`, `ReturnToSupplier`, `UseAsIs`. **Rework is not an outcome**: rework is the LOT's move back into trim, and an open trim rework blocks release ("At trim rework"). | `R__Quality_ControlledRunResult_Record.sql` v1.1 | `0109_ControlledRun/130_results.sql`, `0112_ReworkReturn/` |
| F41 | Scrap on a LOT member is real: a reject event, the LOT decremented and closed at zero. | same | `0109_ControlledRun/130_results.sql` |
| F42 | `ReturnToSupplier` is refused on a container member and on a non-received LOT (`Lots.ufn_LotReturnableToVendor`); applied when recorded (vendor-return row). | same, v1.2-1.3 | `0112_ReworkReturn/` |
| F43 | A deviation is SIGNED (signature meaning `DeviationApproval`), gets a `DV` number, covers every member still in the super-lot when signed. It is what lets a Use-As-Is member be released. Message: `Deviation <DV> signed on super-lot <RN>.` | `R__Quality_ControlledRunDeviation_Raise.sql:187` | `0109_ControlledRun/140_deviation_signature.sql` |
| F44 | Release is a SIGNED bulk release of the **ticked** members (not necessarily all), carrying "the 200% inspection was completed" as a fact. Refusals: `Confirm that the 200% inspection was completed. Nothing was released.`; `Tick at least one member to release.`; `This user cannot sign a release.`; per member `<member>: <reason>. Nothing was released.` where reason is `No results yet` / `Use as is needs a deviation` / `At trim rework` / `Being reworked`. | `R__Quality_ControlledRun_Release.sql:122-137`; reasons `R__Quality_ufn_zzz_ControlledRunMemberResults.sql:71-87` | `0109_ControlledRun/150_release.sql` |
| F45 | Release clears the tag on every tagged LOT of the released members (a container's tray LOTs included), one audit row per LOT, and writes `Released . signed <initials>[ . Deviation <DV>]` into each LOT's history. | Release header v1.1 | `0109_ControlledRun/150_release.sql` |
| F46 | Release does **not** end the auto-join window or close the super-lot. Close is separate and refused with `End the window before closing.` while the window is open, and `<n> of <m> members are still CRT-tagged.` while tagged members remain. | `R__Quality_ufn_zzz_ControlledRunCloseCheck.sql` | `0109_ControlledRun/090_close.sql` |
| F47 | Who may sign (release or deviation): any active `AppUser` with a non-empty `AdAccount` -- the person whose network password was just checked. No role gate yet (the Sign-off tab says so). | `R__Quality_ufn_zz_SignatureAllowed.sql` | `0109_ControlledRun/140_deviation_signature.sql` |
| F48 | A single LOT's tag can also be cleared on LOT Detail (`Lots.Lot_ClearCrt`): `CRT cleared on LOT <name>.` | `R__Lots_Lot_ClearCrt.sql:125` | `0037_PlantFloor_Quality_Capture/040_Crt_workflow.sql` |
| F49 | Opening a super-lot with "keep adding new production" while another open super-lot already does so for this part here is refused: `Super-lot <RN> is already adding new production of this part here. End its window first.` | `R__Quality_ControlledRun_Open.sql:162` | `0109_ControlledRun/040_open.sql` |

## Not shown

- Line scrap by part spreading across tagged and clean LOTs (open question in the overview note).
- Anything the walk (Task 6) shows behaving differently from this sheet: the capture wins, the
  difference goes into `notes/2026-10-27_super-lot-gateway-walk-bugs.md`, and the kit says what
  the capture shows.
