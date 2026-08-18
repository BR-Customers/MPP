# CRT Container Validation — Design

**Date:** 2026-08-14
**Author:** Blue Ridge Automation
**Status:** Approved for planning

## Problem

When a piece of assembly-line equipment breaks — the scale or the vision camera — the
station loses its ability to prove a container was filled correctly. MPP's real-world
answer is to keep running on an operator count and have a second person check the
container over later.

Today the MES has no way to express that. A container completes, claims an AIM Shipper
ID, and posts it to Honda's AIM within seconds. Once posted, the container is
effectively declared good. There is no window in which a human can intervene.

MPP will configure a ByCount closure entry for most parts themselves; that is not our
work. What we owe them is the controlled-run mechanism around it.

## Scope

**In:** a CRT switch on the changeover popup; a terminal `CrtEnabled` attribute;
marking containers completed under CRT; holding their AIM post back; a line-scoped
pending-validation list behind elevation, with Validate and Hold per container.

**Out:** the ByCount container configs themselves (MPP's job); any change to how AIM
serials are claimed; any change to the AIM wire format.

## Constraint: no data-model changes

Explicit requirement. This design adds **no tables and no columns**. It uses:

* `Lots.Lot.CrtActive` — a `BIT NOT NULL DEFAULT 0` column shipped in migration
  `0020`, already served by a built CRT subsystem: `Lots.Lot_SetCrt`,
  `Lots.Lot_ClearCrt`, `Quality.Crt_GetRequiredInspections` and
  `Quality.Crt_FlagMissedInspection` (Arc 2 Phase 9, FDS-10-011/012).
* One `Location.LocationAttributeDefinition` row — a *data* insert into the existing
  polymorphic three-tier location model, which exists precisely so terminal
  capabilities grow without DDL. Follows the `0041` precedent that added
  `CurrentClosureMethod` and `VisionAppUrl`.

## Why `Lot.CrtActive` is the right home

CRT already means something specific here. `MPP_MES_DATA_MODEL.md` (rev 1.9q,
FDS-10-012) defines **Controlled Run Tag**:

> When 1, downstream operations require 200% inspection (every part) until cleared by
> a supervisor-elevated release.

That is this workflow. Equipment is down, so the run is controlled; every container
gets a second look; a supervisor with elevated access clears it.

The container's finished-good LOT is the natural carrier: `Assembly_CompleteTray`
already mints exactly one FG LOT per tray, and `ContainerTray.FinishedGoodLotId` ties
it to the container.

### It does not inflict 200% inspection

The obvious risk of reusing `CrtActive` is dragging in the 200%-inspection prompt,
which MPP did not ask for. It does not happen, and the reason is precise:

* `Lots.Container_Complete` **closes** the finished-good LOT on completion
  ("Closed on container completion (finished-goods packed & shipping-ready)").
* `Quality.Crt_GetRequiredInspections` filters `CrtActive = 1 AND sc.Code <> 'Closed'`.

So a CRT-marked FG LOT is Closed within the same operation that marks it, and is
therefore never surfaced to the inspection prompt. The flag serves purely as the
container-validation marker. **This is load-bearing: if the FG LOT ever stops being
closed at completion, these containers would begin demanding 200% inspection.** The
test suite pins it.

### Which existing proc goes where

* **Setting** cannot use `Lots.Lot_SetCrt` — it rejects Closed LOTs, and the FG LOT is
  closed moments later in the same call chain. The flag is set at mint time, inside
  `Assembly_CompleteTray`'s existing `INSERT INTO Lots.Lot`, before the close.
* **Clearing** reuses `Lots.Lot_ClearCrt` as-is. It explicitly permits Closed LOTs
  ("releasing a tag from a finished LOT is a bookkeeping correction") and is already
  the documented supervisor-elevated release with its own audit.

## Three problems this design has to solve

Discovered while investigating; each would silently defeat the feature.

### 1. The 60-second sweep would post the serial anyway

`BlueRidge.Lots.AimPost.retryTick` runs on a timer and sweeps every row where
`ConsumedAt IS NOT NULL AND PostedAt IS NULL` — precisely the state a held container
sits in. Suppressing only the synchronous post in `Container.complete` would delay the
post by at most one minute.

### 2. `PostedAt IS NULL` already means "owed to AIM"

It drives the owed-backlog list on `/shop-floor/aim-pool-config` and the backlog-age
escalation in `alarmTick`. If it also meant "awaiting validation", a container parked
across a shift would be indistinguishable from a failed post and would raise backlog
alarms.

### 3. Both read through one proc

`Lots.AimShipperIdPool_ListUnposted` is the single query behind the sweep, the backlog
screen, and the escalation. Excluding held serials **there** fixes all three at once.
This is the load-bearing change; without it the feature does not work.

## Components

### A. `CrtEnabled` terminal attribute

Migration `0058_crt_terminal_attribute.sql`. One guarded
`LocationAttributeDefinition` insert, mirroring `0041`:

```
(7, N'CrtEnabled', N'NVARCHAR', 0, N'0', NULL,
 (SELECT ISNULL(MAX(SortOrder),0)+1 FROM Location.LocationAttributeDefinition WHERE LocationTypeDefinitionId = 7),
 N'Controlled Run Tag active at this assembly-out terminal: containers complete
   pending a second-person validation before their AIM Shipper ID is posted.')
```

Values `'0'` / `'1'`, matching `HasBarcodeScanner`. An absent attribute reads as `'0'`.

### B. `Location.Terminal_SetCrtEnabled`

New repeatable proc `(@TerminalLocationId BIGINT, @Enabled BIT, @AppUserId BIGINT)`,
modelled on `Location.Terminal_SetClosureMethod`, upserts the attribute, writes
`Audit.ConfigLog` in the `<SUBJECT> · <CATEGORY> · <ACTION>` convention with
resolved-name JSON. FDS-11-011 compliant — no OUTPUT params, single terminal
`SELECT @Status, @Message`, all rejects before `BEGIN TRANSACTION`.

### C. Changeover popup

`BlueRidge/Components/Popups/ChangeoverElevation` keeps its closure-method picker and
gains an independent CRT on/off switch. The two are orthogonal: either can change
alone. One elevation (`elevate(..., "Changeover", terminalLocationId)`) authorises the
submit; only the controls that actually changed fire their mutation.

### D. Marking the container

`Workorder.Assembly_CompleteTray` reads the terminal's `CrtEnabled` and mints the FG
LOT with `CrtActive = 1` when it is `'1'`. One extra attribute read; the existing
`INSERT INTO Lots.Lot` gains a column *value*, not a column.

The AIM claim in `Lots.Container_Complete` is **unchanged** — the serial is still
consumed at completion, as required.

### E. Holding the post back

1. `BlueRidge.Lots.Container.complete` skips `AimPost.postOne` when the container's FG
   LOT is `CrtActive = 1`.
2. `Lots.AimShipperIdPool_ListUnposted` excludes serials whose
   `ConsumedByContainerId` resolves to a container with a `CrtActive = 1` FG LOT.

(2) is what makes it real: sweep, backlog screen and alarm all inherit the exclusion.

### F. The pending list

`Lots.Container_ListPendingValidation(@LocationId)` — containers whose
`CurrentLocationId` sits at or under the terminal's **parent line**, with a
`CrtActive = 1` FG LOT. Returns container id, part number, description, piece count,
completed-at (ET), AIM Shipper ID, age in minutes. Read proc: no OUTPUT params, an
empty result set means none.

### G. Assembly OUT button

On `AssemblyNonSerialized`, visible when the terminal's `CrtEnabled = '1'` **OR** the
pending count is greater than zero — so a backlog stays reachable after CRT is
switched back off. Uses `position.display`, not `meta.visible`, so it does not hold
flex space when hidden.

### H. Validation popup

New `BlueRidge/Components/Popups/CrtValidation`. Elevates on open
(`elevate(..., "CrtValidation", terminalLocationId)`); a failed or cancelled elevation
closes without showing the list. **That one elevation covers both row actions** — no
second prompt per container.

Per row:

* **Validate** → `Lots.Container_ValidateCrt` resolves the container's FG LOT, calls
  the existing `Lots.Lot_ClearCrt` for the flag and its audit, then Python calls
  `AimPost.postOne` for that serial. The wrapper exists to turn a *container* id into
  the right LOT id and to reject a container that is not pending; the flag clear
  itself is not reimplemented.
* **Hold** → the existing `Quality.Hold_Place` against the container.

## Data flow

```
changeover popup --elevated--> Terminal_SetCrtEnabled --> LocationAttribute CrtEnabled='1'
                                                              |
tray completes --> Assembly_CompleteTray reads it --> FG LOT minted CrtActive=1
                                                              |
container full --> Container_Complete CLAIMS an AIM serial (unchanged)
                                                              |
                   Container.complete sees CrtActive=1 -----> SKIPS postOne
                   ListUnposted excludes it --------------->  sweep/backlog/alarm skip it
                                                              |
validation popup --elevated--> Container_ValidateCrt clears CrtActive
                                                              |
                               postOne --> PostedAt set, container declared good
```

A validated container whose post then fails falls into the normal owed backlog and is
swept like any other failure. **Clearing `CrtActive` is exactly what hands the serial
back to the existing retry machinery** — held-for-validation and failed-to-post never
occupy the same state.

A held container keeps `CrtActive = 1` and stays listed until released and validated.

## Error handling

* Elevation failure anywhere → `{Status: 0, Message}`, no mutation, popup stays closed.
* `Container_ValidateCrt` on a container with no `CrtActive` FG LOT → Status 0,
  "Container is not pending validation" (guards double-validate races).
* `postOne` failure after a successful validate → `CrtActive` stays cleared and the
  serial is owed; the sweep retries. Reported in the popup but not rolled back — the
  human decision is recorded regardless of whether AIM was reachable.
* All rejects precede `BEGIN TRANSACTION`, per the INSERT-EXEC rule.

## Testing

New SQL test folder `sql/tests/0058_CrtValidation/`:

1. `010_schema.sql` — `CrtEnabled` definition exists on LTD 7 with default `'0'`.
2. `020_Terminal_SetCrtEnabled.sql` — set/clear, audit row written, bad terminal
   rejected.
3. `030_CompleteTray_marks_crt.sql` — FG LOT minted `CrtActive=1` when the terminal
   has CRT on, `0` when off. The behavioural core. Also asserts the FG LOT ends
   **Closed** and therefore does **not** appear in `Quality.Crt_GetRequiredInspections`
   — the guard that keeps 200% inspection out of this feature.
4. `040_ListUnposted_excludes_held.sql` — **the regression guard for problem 1**: a
   held container's serial must not appear in `ListUnposted`, and must appear once
   validated.
5. `050_Container_ListPendingValidation.sql` — line scoping, and that a validated
   container drops out.
6. `060_Container_ValidateCrt.sql` — clears the flag, audits, rejects a non-pending
   container.

Gateway smoke (no automated coverage): drive the changeover popup, complete a
container under CRT, confirm nothing posts, validate it, confirm it posts.

## Decisions (settled 2026-08-14)

* **A held container's AIM serial stays consumed** against that container
  permanently. It is never returned to the pool. Serials are cheap; reuse risks
  double-shipping a number to Honda.
* **No age escalation.** An unvalidated container may sit indefinitely. It is
  deliberately excluded from `alarmTick`'s backlog-age escalation, and nothing
  replaces that. If MPP later wants a ceiling, it belongs in the validation list as
  its own ordering/warning concern, not in the AIM owed backlog.
