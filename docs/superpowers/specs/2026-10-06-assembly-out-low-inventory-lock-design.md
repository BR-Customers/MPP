# Assembly OUT low-inventory lock -- design

**Date:** 2026-10-06
**Status:** Built 2026-10-06 on Dev (non-serialized Assembly OUT); checked on the Dev gateway; not deployed to prod
**Requested by:** Jacques (2026-10-06)
**Screens:** Assembly OUT, non-serialized. Serialized is not covered (see 2.1).

## Revision history

| Rev | Date | Change |
|---|---|---|
| 1 | 2026-10-06 | Initial design. |
| 2 | 2026-10-06 | **As built.** Two errors in rev 1 corrected. (a) The running part is not a session property: it lives in the non-serialized view's `view.custom.selectedFinishedGoodItemId`, which a dock cannot read, so the view now mirrors it to `session.custom.selectedFinishedGoodItemId` (Jacques chose this over resolving it server-side, which picks the station's oldest open box and is wrong where METTs keeps several open). (b) The serialized screen has no part selection and never calls `Assembly_CompleteTray`, so it is out of scope. Also: the proc always emits a result set; the downtime event is ended only on a short-to-clear transition seen by the terminal; the operator's tray close now sends `inventoryChanged`. |

---

## 1. Problem

Assembly OUT runs out of purchased parts without warning that anyone acts on. The Line Inventory
sidebar turns a row red at 10% of the line's Max, but a red row in a sidebar is easy to ignore, and
the first hard signal is `Assembly_CompleteTray` refusing a tray.

## 2. What we are building

When the finished good running at an Assembly OUT terminal is **3 trays or fewer** from running out
of any purchased part, a full-screen banner locks the terminal. It names the part, embeds the
add-inventory form, and stays until stock is added or a supervisor releases it. A downtime event
with the reason **Low Inventory** runs from the moment the banner opens until stock is added.

### 2.1 Out of scope

- **Stopping the line itself.** The banner blocks the terminal's touch screen only. On ByWeight and
  ByVision stations trays are closed by the scale or camera through the gateway
  (`plcCompleteTray`), and those keep closing behind the banner. A PLC hold flag that MES sets when
  inventory is low and clears when it is added has been requested from MPP's automation engineer
  and is a separate, later feature.
- **The serialized Assembly OUT screen.** It has no part selection and its parts are minted one at a
  time by the MIP watcher (`SerializedPart_Mint`), not by `Assembly_CompleteTray`. Whether that path
  draws purchased parts has not been traced, so "3 trays left" has no defined meaning there yet.
- **Castings and sub-assemblies.** Only parts the operator can add from this terminal trigger the
  lock. A casting shortage still surfaces as it does today.
- **The sidebar colours.** Red stays "10% of Max". The lock is a separate rule, so a row can be red
  with no lock, or the terminal can lock on a row that is not red.

## 3. Rules

### 3.1 The calc

For the finished good selected in the screen's part dropdown (mirrored by the view to
`session.custom.selectedFinishedGoodItemId`) and the terminal's closure method, `PartsPerTray` comes from the part's `Parts.ContainerConfig`.

| Finished good | Parts checked | Pieces per tray | Stock counted |
|---|---|---|---|
| Has a published BOM | Each BOM line whose child is `PassThrough` | `CAST(QtyPer * PartsPerTray AS INT)` | Child part's LOTs at the cell, `BlocksProduction = 0`, not `Closed` / `Open` |
| No published BOM (pass-through repack) | The finished good itself | `PartsPerTray` | Same, **and** origin `Received` / `ReceivedOffsite` only |

`TraysLeft = Available / PiecesPerTray`, integer division. A part is **short** when
`TraysLeft <= 3`. The terminal locks when any part is short.

The stock predicate is the one `Workorder.Assembly_CompleteTray` uses for its pre-check and its
FIFO walk, so the lock and the tray-complete gate cannot disagree. The received-only filter for
repack is load-bearing there and is copied, not relaxed.

No calc, and so no lock, when: no finished good is selected; the part has no container config for
the closure method; `PartsPerTray` is NULL; or a BOM line's pieces per tray rounds to 0.

The threshold (3) is a constant in the proc. Making it configurable per line is not built.

### 3.2 The lock

- Opens when the calc reports a short part and no release is in force.
- Shows the **worst** short part (fewest trays left; ties by description). After each add the calc
  re-runs and the banner moves to the next short part, or closes when none remain.
- Cannot be dismissed: modal, no close icon, no overlay dismiss.
- The embedded form is the existing `PlantFloor/AddLotBox`, given the short part, the cell, and
  the part's box quantity. Supplier-lot capture is unchanged.

### 3.3 Supervisor release

- A **Supervisor release** button goes through `Common.Session.requireElevation` (per-action AD
  credential, FDS-04-007) with a new action code `LowInventoryRelease`.
- A release closes the banner until the next `inventoryChanged` message on the page. Tray
  completion already sends one, so the banner returns after the next tray if the part is still
  short. Nothing is persisted: a page reload also re-evaluates.
- As everywhere, the elevation window attributes what follows to the supervisor.
- A release does **not** end the downtime event.

### 3.4 Downtime

- **Unit:** `Oee.ufn_ResolveDowntimeScope(cell)` -- the terminal's downtime unit.
- **Start:** when the banner opens. Source `System`, reason `Low Inventory`. If any event is
  already open at the unit, nothing is started (`DowntimeEvent_Start` already refuses, and the
  refusal is not surfaced to the operator).
- **End:** when this terminal sees the calc go from short to clear (never on first page load, so
  another station's page opening cannot end an event that is still warranted). Only an open event at the unit whose source is
  `System` **and** whose reason is `Low Inventory` is ended; an operator's or the PLC's event is
  never touched. Remarks name the part that was short.
- **Attribution:** the signed-in operator, else the system user.
- **Known overstatement:** after a supervisor release the event keeps running while the last trays
  are packed. Accepted (Jacques, 2026-10-06).
- **Known gap:** if the terminal's browser dies while the banner is up, the event stays open until
  a terminal on that line next sees the calc clear, or someone ends it in the Downtime Manager.

Two stations on one line (METTs A / B) share a downtime unit, so they share one event; whichever
sees its own shortage clear ends it. If both were short on different parts, the first to clear ends
the event while the other is still short, and no second event starts until that station's state
changes again. Accepted as a known limit.

## 4. Build

### 4.1 SQL

- **Migration `0108_downtime_reason_low_inventory.sql`** -- seeds one internal reason code:
  `Code = N'MA-LOWINV'`, `Description = N'Low Inventory'`, operation category
  `MachiningAssembly`, source `System`, `IsExcused = 0`, type NULL. Idempotent on `Code`.
  ASCII only. This is an internal code baked into a migration, not a Seeding Registry item.
- **`Workorder.Assembly_GetTraysRemaining`** (new repeatable, read):
  `@CellLocationId BIGINT, @FinishedGoodItemId BIGINT, @ClosureMethod NVARCHAR(20) = NULL`.
  One row per checked part: `ItemId, PartNumber, Description, BoxQuantity, PiecesPerTray,
  Available, TraysLeft, IsShort, ThresholdTrays`, ordered `TraysLeft, Description, ItemId`.
  Empty set when there is no calc -- always a result set, never a bare `RETURN` (a proc that emits
  none makes an Ignition named query throw). No OUTPUT params (FDS-11-011).
- **Tests** in `sql/tests/0028_PlantFloor_Assembly/`: BOM part short / not short at exactly 3 and
  4 trays; non-PassThrough BOM children ignored; held LOT excluded; repack part counts received
  stock only (a minted tray LOT of the same item is not counted); no config -> empty set.

### 4.2 Core (named queries + script)

- NQ `workorder/Assembly_GetTraysRemaining` (type Query).
- `BlueRidge.Workorder.Assembly`:
  - `getTraysRemaining(cellLocationId, fgItemId, closureMethod)` -- rows.
  - `getLowInventoryLock(cellLocationId, fgItemId, closureMethod, _refreshToken=None)` -- binding
    reader. Always returns the full shape `{"short": bool, "itemId", "description", "available",
    "traysLeft", "piecesPerTray", "boxQuantity", "shortCount"}`; display shaping only, the proc
    decides `IsShort`.
  - `syncLowInventoryDowntime(cellLocationId, short, partDescription, appUserId,
    terminalLocationId)` -- start or end per 3.4. Same shape as `DowntimePlc.tickWatcher`.
- `BlueRidge.Common.Session._ELEVATED_REPLAY_MESSAGES`: add
  `"LowInventoryRelease": "lowInventoryReleaseRequested"`.

### 4.3 Views (MPP)

- **New `Components/Popups/LowInventoryLock`** -- the banner. Params `locationId`, `itemId`,
  `description`, `available`, `traysLeft`, `boxQuantity`. Red full-width header ("ADD INVENTORY"),
  part description, on-hand and trays-left figures, the embedded `AddLotBox`, and the Supervisor
  release button. Handles `lowInventoryReleaseRequested` (close + tell the watcher) and
  `inventoryChanged` (re-read; retarget or close).
- **`PlantFloor/AddLotBox`** -- gains an optional `embedded` param. When true the Cancel button is
  hidden and a successful add does not call `closePopup("mpp-add-lot-box")`. Default false, so the
  sidebar's use is unchanged.
- **`PlantFloor/LineInventory`** (the dock) -- gains the watcher: `custom.lock` bound to
  `getLowInventoryLock` (only when the new `params.lockEnabled` is true), `custom.released`, and
  `onChange` scripts that open or close the popup and call `syncLowInventoryDowntime`. Its existing
  `inventoryChanged` handler also clears `custom.released` when the message is for this line.
- **Page config** -- `lockEnabled: true` on the `/shop-floor/assembly-nonserialized` dock only.
- **`Views/ShopFloor/AssemblyNonSerialized`** -- a change script on
  `custom.selectedFinishedGoodItemId` mirrors it to the session (cleared in `onStartup`), and the
  tray-complete script sends a page-scoped `inventoryChanged`. Before this an operator's tray close
  did not refresh the dock until its 30-second poll.
- **Session props** -- `custom.selectedFinishedGoodItemId`.
- **Core stylesheet** -- `psc-pf-lock-*` classes for the banner.

`AssemblySerialized` is not edited.

## 5. Verification

- SQL suite green, with the assertion count up by the new tests.
- On the Dev gateway, at an Assembly OUT terminal with a finished good selected: drain a purchased
  part to 3 trays -> banner opens and a `System` / `Low Inventory` event is open at the unit; add a
  box -> banner closes and the event is ended; supervisor release -> banner closes, event stays
  open, banner returns after the next tray.
- The sidebar's own `+` add still opens and closes `AddLotBox` as before.

**Result, 2026-10-06 (Dev gateway, METTs Assembly Out A, part 1223A-6MA -J000):** banner opened at
965 pcs / 0 trays; a `System` / `MA-LOWINV` event opened at MA2-6MACH; adding 3,400 pcs through the
embedded form closed the banner and ended the event with the part in the remarks. The supervisor
prompt opens over the banner; the release itself was NOT exercised (it needs an AD credential). The
sidebar's own `+ LOT` popup still opens with its Cancel button and closes on Cancel; a completed add
from the sidebar was not repeated after the `AddLotBox` change.

## 6. Deployment

Not part of this work. A prod release follows the standard five-part shape (CLAUDE.md, Production
deployments): one migration, one new proc, Core + MPP scoped exports.
