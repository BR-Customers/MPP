# Assembly OUT -- elevated shipping-label reprint

**Date:** 2026-09-17 · **Requested by:** MPP (2026-09-16) · **Status:** built, not live-verified, not deployed.
Source: section 2 of `notes/2026-09-17_handoff-aim-failure-log-and-shipping-reprint.md`. Section 1 (AIM
failure logging) is an OPEN TODO in `PROJECT_STATUS.md`; section 3 (remove the Shipping Dock) is benched.

## What MPP asked for

A reprint button at Assembly OUT that reprints the **shipping label** (not a LOT label) and needs elevated
access.

## Decisions (Jacques, 2026-09-17)

| Question | Decision |
|---|---|
| Who may approve | Any authenticated AD user -- today's elevation rule. **No role gate now**; AD roles come in a week or two. |
| Reason storage | Free text in the existing `Lots.ShippingLabel.PrintReasonCode NVARCHAR(50)`, no validation. The `Lots.PrintReasonCode` code table is not used. |
| Reason values | `printer jam`, `network error`, `damaged label`, `print failed`, `smudged` |
| Which labels are offered | Last 10 at the cell, scoped by the **container's** location at or under the cell (not by the printing terminal) |
| Where the button goes | A new footer bar on both Assembly OUT views |
| Shipping Dock | Not touched this session |

## Design

### Read: `Lots.ShippingLabel_ListRecentByCell @CellLocationId, @TopN = 10`

- Recursive descendants of the cell (MAXRECURSION 8, same shape as `Lots.Lot_GetComponentsAtCell`);
  filter `Container.CurrentLocationId`. This catches PLC-completed containers (no terminal) and gives both
  terminals on a line the same list.
- **One row per container**: its newest non-void label. Void labels are removed *before* the newest is
  picked; Void-status containers are excluded. Which row is reprinted does not matter --
  `ShippingLabel_Reprint` re-renders the ZPL from the container.
- Returns `Serial` (`'13218001' + RIGHT(AimShipperId, 8)`, as printed), `Quantity` (closed trays, as
  printed), `PrintStatus` (Printed / Failed / Pending), times in Eastern.
- Read proc: one result set, no OUTPUT params. NULL cell -> empty; `@TopN` NULL or < 1 -> 10.
- NQ `lots/ShippingLabel_ListRecentByCell` (Core, type Query).

### Elevation: the stateless one-shot form

The handoff proposed `Common.Session.requireElevation` + a `_ELEVATED_REPLAY_MESSAGES` entry. That path
runs `beginElevatedWindow`, which **makes the supervisor the session user for 300 s** -- every operator
action at the terminal in that window would be attributed to the supervisor. For a one-off reprint that is
wrong, so the popup uses the form `Popups/CrtValidation` uses: its own AD account + password fields,
`AppUser.elevate(..., "ShippingLabelReprint", terminalLocationId)`, and the returned `appUserId` passed
straight into the reprint. The operator stays signed in; `PrintedByUserId` is the approver.

`actionCode` already travels from `elevate()` through `authenticateAd` and its NQ into
`Location.AppUser_AuthenticateAd`, which records it on the `ElevationGranted` / `ElevationDenied` row. A
future role rule is therefore a SQL-only change keyed on `ShippingLabelReprint`.

### Reprint must dispatch

`Lots.Shipping.reprintLabel` only inserts the `Initial=0` row. Nothing sent it to the printer; it waited
for `PrintFailureGateway.sweepTick` (every ~5 min, rows older than ~60 s). New
`Lots.Shipping.reprintAndDispatch` calls `ShippingDispatcher.dispatch(newId, terminalLocationId)` right
after the insert and reports `Dispatched`. The Shipping Dock's own reprint still has the delay (section 3
is parked).

### Python (`BlueRidge.Lots.Shipping`)

- `listRecentByCell(cellLocationId, topN=10)` -- thin `execList`.
- `reprintAndDispatch(shippingLabelId, printReasonCode, appUserId, terminalLocationId)` -- reprint then
  dispatch; `appUserId` required.
- `reprintFromPopup(adAccount, password, shippingLabelId, printReasonCode, terminalLocationId)` -- the
  popup's submit: checks selection + reason first (no credential challenge for an incomplete form),
  elevates, reprints, toasts every outcome, returns True when the row was written.

### Views

- `Components/PlantFloor/ShippingLabelReprint` (new popup, id `mpp-shipping-reprint`): label list, reason
  dropdown, AD account, password, Cancel / Reprint. Reprint is disabled until a label and a reason are
  chosen. The password is cleared after every attempt.
- `Components/PlantFloor/ShippingLabelReprintRow` (new repeater row): serial, part, qty, time, reprint
  marker, status pill, Select. Selection travels as the page message `shippingReprintRowSelected`; the popup
  records the id and each row highlights itself, so picking a row does not re-query.
- `AssemblySerialized` / `AssemblyNonSerialized`: a `Footer` flex row (last child of root) with
  **Reprint Shipping Label**, opening the popup with `session.custom.cell.locationId` and
  `session.custom.terminal.terminalLocationId`. Added by `tools/add_assembly_out_reprint_footer.py`, a text
  splice verified by re-parse.
- Print-failure toast in `Lots/Container`: "Reprint it from Assembly OUT."

## Tests

`sql/tests/0029_PlantFloor_Hold_Sort_Shipping_Aim/082_ShippingLabel_ListRecentByCell.sql` (22 assertions):
scope at / under / outside the cell, one-row-per-container, void label and Void container exclusion,
fallback past a newer void label, serial, quantity, status, ET conversion, ordering, `@TopN`, NULL cell.

## Found, not changed

- The Shipping Dock reprint button never dispatches (see above).
- `Lots.PrintReasonCode` seed row 2 is `N'Reprint — Damaged'` with an em-dash (ASCII-only seed rule).
- `Lots.Container_ListShipped` and `Lots.Lot_GetShippedContainers` have no NQ and no caller.
