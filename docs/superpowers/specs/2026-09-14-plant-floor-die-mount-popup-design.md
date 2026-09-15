# Plant-Floor Die Mount Popup — Design Spec

**Date:** 2026-09-14
**Status:** Built and **verified in Dev** 2026-09-14 — `3616026e` (SQL + Ignition), `bf377911` (DieCastBody), `860d4d83` (elevation replay fix). All three §9 decisions closed, §6.3's prerequisite confirmed, and the §10 click-through exercised by Jacques: one-tap open through AD, the open-basket block disabling and re-enabling Release, and a non-Die-Mount elevated action proving the shared `Common.Session` fix. Ready for prod; handoff for the release agent in `notes/2026-09-14_die-mount-prod-handoff.md`.
**Author:** Blue Ridge (with Claude)
**Arc / Phase:** Arc 2 (Plant Floor) — Die Cast.
**Origin:** Jacques, 2026-09-14. The Die Cast screen's **Tool Config** button navigates to a different Perspective project; an operator doing a die changeover at the press cannot practically use it.
**Related:** `docs/superpowers/specs/2026-06-16-cell-mount-card-design.md` (the Config Tool card this ports from), `docs/superpowers/specs/2026-09-09-diecast-shot-reading-chain-design.md` (the invariant §5 is about), `docs/superpowers/specs/2026-09-10-diecast-counter-anchor-design.md`, `docs/superpowers/specs/2026-09-14-cutover-machine-eligibility-design.md` (the eligibility predicate §4 inverts), `notes/2026-08-04_fat-testing-notes.md` items #9 / #12.

---

## 1. Motivation

The Die Cast screen shows the die mounted on the selected press and a row of open accumulator baskets under it. Beside the die it has a **Tool Config** button:

```
BlueRidge/Views/ShopFloor/DieCastBody/view.json → ToolRow → ToolConfigButton
  onActionPerformed (scope G):
      system.perspective.navigate(
          url="/data/perspective/client/MPP_Config/parts/tools", newTab=True)
  props.enabled (expr):
      !isNull({session.custom.elevatedUntil}) && {session.custom.elevatedUntil} > now(5000)
  tooltip: "Supervisor access required"
```

Four things make that unusable at a press.

1. **It is a different application.** `MPP_Config` is a separate Perspective project on a separate URL. It does not inherit the terminal session — not `session.custom.cell`, not the operator, not the terminal registration. It logs in on its own, against AD, at a machine-side touch panel with no keyboard.
2. **It lands on the wrong screen.** `/parts/tools` is the full Tools configuration surface: die list, identity, cavities, attributes, shot limits, die ranks, assignment history. Mounting is one card buried inside it, and the card is *tool*-anchored — you pick the die, then pick the cell. The operator at the press already knows the cell; it is the one fact the screen makes them re-supply.
3. **It opens in a new browser tab.** On a kiosk-mode plant-floor panel that is either blocked or unrecoverable without a keyboard.
4. **The elevation gate is the wrong shape.** The button is *disabled* until a window is already open, so the operator must first find the header's **Supervisor Access** button, elevate, then come back. That gate came from FAT #9 / #12 ("Tool config on die cast should require elevated login to launch the config app") and it answered the question that was asked. Nobody asked whether the destination was right.

The ask is a popup at the press: the eligible dies for **this** cell, a **Mount** button, and a **Release** button for whatever is mounted now.

### 1.1 What this spec is really about

Mounting and releasing are already built, end to end, and §3 says so plainly — the UI is a port, not a build. Two questions carried the review, and one of them was load-bearing. Both are closed (§9):

- **What "eligible" means** (§4). The existing read proc's filter is coarser than the word suggests.
- **What happens to open baskets when a die is released** (§5). Three separate subsystems assume a changeover closes the baskets. Nothing enforces it. Putting a Release button at the press is exactly what turns that assumption into a defect.

The §5 review also turned up a defect the guard would otherwise have inherited: the "the operator can always clear the baskets" premise the block rests on is **false today**, in two ways, and closing that is part of this change rather than a follow-up (§5.4.1).

---

## 2. Scope

**In:** one new plant-floor popup; the Die Cast screen's button repointed at it; an eligibility read proc; one guard added to the release proc and one to `ToolCavity_Deprecate`; one column appended to the mount-context proc; one entity-script method; one elevation replay-map entry.

**Out, deliberately:**

- Creating, editing, duplicating or deprecating dies; cavities; attributes; shot limits; die ranks. Those stay in the Config Tool. This popup mounts and releases; it does not configure.
- Mounting on anything but the die cast machine the operator is standing at. The popup is cell-anchored by construction.
- Any change to what a release does to production, pieces, shot counts, or the counter chain. §5 decides whether a mount-release is *allowed*, never what it writes.
- The `Lots.Lot_GetOpenByTool` press-scoping gap (§5.4) — a real finding, a separate change.
- Elevation's replaced-identity semantics (`Common.Session.beginElevatedWindow` swapping `session.custom.user` for the supervisor). That is by design, not a defect, and this popup relies on it.
- A die-changeover *workflow* — preheat, checklists, first-article. Not asked for, not invented.

---

## 3. What already exists (and contradicts the premise that this is a build)

The whole mount/release stack is present and reusable without modification. This matters because it converts a feature into a port and moves the review effort onto the two questions that deserve it.

| Layer | Object | State |
|---|---|---|
| Proc — list mountable | `Tools.Tool_ListMountableForCell @CellLocationId` | Exists. Returns `Id, Code, Name`. See §4 — the filter is coarse. |
| Proc — mount | `Tools.ToolAssignment_Assign @ToolId, @CellLocationId, @Notes, @AppUserId` | Exists. Status row. Header already reads *"Elevated action (FDS-04-007) — caller passes the authenticating supervisor's AppUserId."* |
| Proc — release | `Tools.ToolAssignment_Release @ToolId, @AppUserId, @Notes` | Exists. Status row. **Knows nothing about open LOTs** — §5. |
| Proc — mount context | `Tools.ToolAssignment_GetCellContext @CellLocationId` | Exists. Always exactly one row; `AssignedAt` already converted to ET at the boundary. |
| NQ (Core) | `parts/Tool_ListMountableForCell`, `parts/ToolAssignment_Assign`, `parts/ToolAssignment_Release`, `parts/ToolAssignment_GetCellContext` | All four exist, all in **Core**, none change signature. |
| Python (Core) | `BlueRidge.Parts.Tool.getMountableToolsForCell` / `.getCellMountContextOrEmpty` / `.assignToCell` / `.releaseAssignment` | Exist. The mutations already pass `BlueRidge.Common.Util._currentAppUserId()`. |
| Reference UI | `MPP_Config/.../Components/Location/CellMountCard/view.json` | A working cell-anchored mount/release card: occupied state with a Release button, empty state with a `{label, value}` dropdown + notes + Mount, `refresh()` / `handleMount()` / `handleRelease()` on the root. |
| Popup shape | `MPP/.../Components/Popups/DieCastRelease/view.json` | The plant-floor popup contract: `popupId` / `replyMessage` params, `pf-btn pf-btn-secondary pf-btn-large` on Cancel, page-scoped reply on both exits. |
| Elevation | `Common.Session.requireElevation` / `dispatchElevatedAction` / `_ELEVATED_REPLAY_MESSAGES` | Exists, with three live consumers (`DowntimeReason`, `SortCageMigrate`, `CrtToggle`). |

**Attribution needs no work.** `assignToCell` / `releaseAssignment` pass `_currentAppUserId()`, and `beginElevatedWindow` replaces `session.custom.user` with the supervisor for the life of the window. So a mount performed under elevation is already attributed to the supervisor, in `ToolAssignment.AssignedByUserId` and in the `Audit.ConfigLog` row, with no change to any of it — *provided* the elevation actually happened. §6 is about making sure it did.

---

## 4. What "eligible" means today, and what it should mean

### 4.1 The finding

`Tools.Tool_ListMountableForCell` qualifies a die on three tests: active, not currently mounted anywhere, and

```sql
(tt.CompatibleLocationTypeDefinitionId = @DefId OR tt.CompatibleLocationTypeDefinitionId IS NULL)
```

`CompatibleLocationTypeDefinitionId` comes from migration `0018`, which seeds exactly one mapping: **`ToolType 'Die' → LocationTypeDefinition 'DieCastMachine'`**. Every die in the plant is a `Die`; every press is a `DieCastMachine`. So on a die cast machine the filter reduces to *"every active die that is not already mounted somewhere"* — the same list on all 22 presses.

In Dev, with a handful of dies, that reads like a shortlist and nobody noticed. Against the real MPP tooling list it is a flat alphabetical roll of every die in the building, on a touch screen, at 2am, mid-changeover. The word "eligible" in the ask is not what the proc means.

The filter is not wrong — it is doing the job it was written for, which is keeping a die off a trim press. It is simply the only filter there is.

### 4.2 The signal that already exists

`Parts.ItemLocation` records which parts run on which machines, and `Tools.ToolCavity` is keyed `(ToolId, ItemId, CavityCode)` — so a die reaches a press through the parts it cuts:

```sql
EXISTS (SELECT 1
        FROM Tools.ToolCavity tc
        INNER JOIN Parts.ItemLocation il ON il.ItemId = tc.ItemId
        WHERE tc.ToolId = t.Id
          AND tc.DeprecatedAt IS NULL
          AND il.LocationId = @CellLocationId
          AND il.DeprecatedAt IS NULL)
```

This is the exact inverse of `Location.Location_ListDieCastMachinesForItem`, shipped yesterday for the cutover screen, and it must inherit that proc's two hard-won rules:

- **Exact match at the machine tier**, never the FDS-03-014 ancestor cascade. Measured against Dev 2026-09-14 the cascade returns eleven machines for *every* part in the plant, because eligibility is recorded overwhelmingly at Area (135 rows) and Line (272 rows). The nine machine-tier rows are the deliberate signal.
- **Fallback, never a gate.** A press with no machine-tier mapping gets **every** compatible unmounted die, flagged `IsEligible = 0`. A die setter must always be able to mount the die that is physically in their hands. Eligibility shortens a list; it never refuses one.

### 4.3 `Tools.Tool_ListEligibleForCell` (new read proc)

```
Tools.Tool_ListEligibleForCell
    @CellLocationId BIGINT
→ Id, Code, Name, IsEligible BIT
  ORDER BY IsEligible DESC, Code
```

Read proc: no `@Status` / `@Message`, no OUTPUT params, one result set; unknown or deprecated cell → empty rowset (FDS-11-011). Same two-pass shape as `Location_ListDieCastMachinesForItem`: decide the fallback **once** with a `COUNT(*)`, not per row, so a press either returns its mapped dies (all `IsEligible = 1`) or every compatible die (all `IsEligible = 0`) and never a confusing mix.

It layers *on top of* the existing type-compatibility and not-already-mounted predicates — it does not replace them. A die mounted on another press stays out of the list in both branches, which is what keeps the `Assign` proc's 1:1 invariant from ever being the thing that rejects.

**`Tool_ListMountableForCell` is left untouched.** The Config Tool's `CellMountCard` is a supervisor-at-a-desk surface where "every unmounted die" is a defensible list, and changing a shared read proc to serve one new caller is how a filter acquires a second meaning. Two purpose-named read procs, one caller each.

The eligibility rule lives in SQL. No part of it may be reconstructed in a Perspective binding or an entity script.

---

## 5. The load-bearing question: open baskets on release

### 5.1 The invariant nobody enforces

Three separate subsystems are written against the same sentence.

`Lots.DieCastLot_Release` v2.0, on why release must advance `Tools.Tool.ShotCount`:

> "a changeover always closes the lots, so the OUTGOING die may never see a shift-output entry at all. Its shots since the last entry would then be lost from its life — a die silently running past ShotLimit."

`Workorder.ufn_CavityShotWatermark`, on why the watermark is scoped by press:

> "Both cases reset with no special-casing, matching the floor reality that a changeover always closes the lots, opens new ones, and resets the counter."

`Workorder.ufn_DieShotWatermark`, on the same scoping, for the same reason.

The shot-reading chain is *built* on "a changeover closes the baskets." And `Tools.ToolAssignment_Release` contains not one line about LOTs. The invariant has survived only because the sole way to release a mount is a Config Tool screen that no floor operator ever opens. A **Release** button at the press is precisely the change that makes it reachable.

### 5.2 What actually happens if a die is released with baskets open

**(a) The baskets vanish from every operator screen.** `DieCastBody` binds

```
custom.activeTool          ← getMountedToolForCellOrEmpty({session.custom.cell.locationId}, refreshToken)
custom.openBasketInstances ← getOpenByToolInstances({view.custom.activeTool.ToolId}, refreshToken)
```

Release the mount and `activeTool.ToolId` goes `NULL`, so the Currently Open list renders empty. The LOTs are still `Open`, still `CurrentLocationId` = the press, still holding their pieces. And the *only* path to releasing one is `requestRelease` → the `DieCastRelease` popup → reached from that now-empty list. The operator has stranded their own production with a button press, and nothing on screen says so.

**(b) Re-mount the die elsewhere and they reappear on the wrong press, credited from the wrong counter.** `Lots.Lot_GetOpenByTool` takes `@ToolId` only — no cell. Mount that die on press B and press B's screen lists press A's baskets with press A's accumulated counts. Release one there and `DieCastLot_Release` stamps `@CellLocationId` = press B; `ufn_CavityShotWatermark` is press-scoped, so the watermark for that cavity on press B is `0`, and the basket is credited the **entire** press-B counter reading. A basket cast on press A absorbs press B's shift.

**(c) The die's life silently under-counts.** The delta mechanism in `DieCastLot_Release` v2.0 exists to recover the outgoing die's shots at changeover. A mount-release that does not close the lots skips it: the shots run on press A between the last contribution and the unmount are never added to `Tools.Tool.ShotCount`. The die runs past `ShotLimit` with the badge showing green.

**(d) The counter anchor cannot help.** `Workorder.DieCastCounterAnchor` is keyed `(ToolId, ShiftId, CellLocationId)`. It corrects a reading; it does not close a basket or move a LOT.

### 5.3 The options

| Option | Verdict |
|---|---|
| **Warn and proceed** | Rejected. (a)–(c) all still happen; the warning simply moves the blame. A toast at a press does not survive a changeover. |
| **Leave alone** (no check at all) | Rejected — this *is* "warn" minus the warning, and it is the status quo whose latency is the only thing protecting it. |
| **Cascade-release the open baskets** | Rejected, and it is the worst of the four. `DieCastLot_Release` derives its piece delta from a **press counter reading the operator writes down at the press**. A cascade has no reading to pass. Passing `NULL` takes the branch the Release popup itself describes as *"Releasing now closes the basket at its current count and credits this cavity nothing further"* — so a cascade would silently under-credit both the shift's production and the die's life, inside a button whose label says "Release die". A hidden write that loses production is worse than a refusal. |
| **Supervisor-elevated override** (block, but a supervisor may authorize past it) | Rejected — see §5.3.1. |
| **Block** | **Adopted** (decision 2, 2026-09-14), scoped as §5.4. |

### 5.3.1 Why not an elevated override

The override reads like a softer block, and it is not: skipping the check does not make (a)–(c) go away, it **authorizes** them. The baskets stay `Open`, still pointed at a die that is now unmounted, and they leave the Die Cast screen the instant `activeTool.ToolId` goes `NULL` — which is the only surface they were reachable from. So an override cannot be a guard clause with a signature on it; it has to say what becomes of the baskets, and that answer is the whole cost:

| Shape | Cost |
|---|---|
| **Bypass only** — release, leave the LOTs | Cheapest to build, worst to own: orphans created deliberately, with an audit row proving it was on purpose. The flow that closes a die-cast basket correctly is press-anchored, so recovery becomes an admin job rather than an operator one. |
| **Bypass + forced disposition** — the supervisor disposes of every basket inside the override modal | The existing Release / Void flow wearing a hat. It still needs the press counter reading a cascade cannot supply (§5.3), so it either re-implements the Release popup or silently under-credits. Buys nothing over the block. |
| **Bypass + quarantine** — move the LOTs to a recovery state | The honest version, and a subsystem: a new LOT state or flag, a reason-code table, a recovery queue, and a rule for the die's lost shot delta. |

A block is only cruel when it can be reached in a state the operator cannot clear. §5.4.1 is about making sure it cannot be — which is the correct answer to the pressure an override was meant to relieve. If the floor later produces a real case where a die must physically come off and its baskets genuinely cannot be cleared, that is evidence for the quarantine shape, specified then with the actual case in hand rather than guessed now.

### 5.4 The decision: block, in SQL, scoped to what the operator can see

`Tools.ToolAssignment_Release` → **v1.1**: a new pre-transaction validation rejecting when the die carries any `Open` LOT **on a non-deprecated cavity**.

```
Reject when EXISTS (Lots.Lot l
                    INNER JOIN Lots.LotStatusCode sc ON sc.Id = l.LotStatusId
                    INNER JOIN Tools.ToolCavity   tc ON tc.Id = l.ToolCavityId
                    WHERE l.ToolId = @ToolId AND sc.Code = N'Open'
                      AND tc.ToolId = @ToolId AND tc.DeprecatedAt IS NULL)
Message: "This die still has <n> open basket(s). Release or void them before
          unmounting the die."
```

The cavity join is not incidental — it is what makes the count equal to what the Die Cast screen shows. See §5.4.1.

Three properties make this the right shape:

- **In the proc, not in Python.** The rule is a domain invariant of the shot-reading chain, so it belongs in SQL. Enforcing it in the proc also means the Config Tool's `CellMountCard` inherits the same guarantee for free, and closes the path (b) leak from *both* directions rather than from the new one only.
- **Pre-transaction.** `ToolAssignment_Release` returns a status row and is captured via `INSERT-EXEC` by its tests, so every rejecting validation must `SELECT` the status row and `RETURN` with no transaction open — a `ROLLBACK` under `INSERT-EXEC` throws Msg 3915. The proc already has exactly this shape for its two existing rejections; the new check goes beside them.
- **Always resolvable by the operator, on the same screen.** This is what makes a hard block acceptable at 2am with no supervisor in the building. A basket with pieces in it is released through the existing Release flow; a basket with zero pieces is voided through the existing `requestVoid` flow. Both are on the Die Cast screen, both are in front of the operator, and neither needs elevation. The block does not strand anyone; it sends them four inches up the screen. **This property did not actually hold when the spec was drafted** — §5.4.1 is what makes it true, and it is a prerequisite of the guard rather than a nicety beside it.

The count is not cell-scoped. `Lots.Lot_GetOpenByTool` takes `@ToolId` only, so every open basket on the die renders on whichever press the die is mounted to — the very press-scoping gap §5.5 flags as a defect is what keeps the guard's count and the screen's list in agreement. **Whatever the guard counts, the screen must show.** That sentence is the governing constraint on this guard, and it binds the §5.5 follow-up too: adding a press filter to `Lot_GetOpenByTool` without revisiting the guard re-opens the mismatch from the other side.

### 5.4.1 The premise was false — two holes, closed here

"Always resolvable by the operator, on the same screen" is what makes a hard block acceptable at 2am. Verified against the live procs on 2026-09-14, it was **not true**:

- **`Lots.Lot.ToolCavityId` is nullable** — `sql/migrations/versioned/0020_arc2_phase1_shop_floor_foundation.sql:540`.
- **`Lots.Lot_GetOpenByTool` v2.1 is cavity-driven.** It selects `FROM Tools.ToolCavity tc … WHERE tc.ToolId = @ToolId AND tc.DeprecatedAt IS NULL` and LEFT-JOINs the open LOT on `ToolCavityId`. A basket whose cavity has been deprecated, or whose `ToolCavityId` is `NULL`, does not appear.
- **`Tools.ToolCavity_Deprecate` v1.0 has no open-LOT guard.** Its only pre-transaction rejections are missing-parameter and not-found-or-already-deprecated. A cavity holding an open basket can be deprecated from the Config Tool right now, and the basket vanishes from the Die Cast screen while staying `Open` on the die.

A naive die-wide `EXISTS` would therefore count baskets the operator cannot see: the screen says "3 open", two are listed, and the die does not come off. That is precisely the unresolvable block an elevated override would have been bought to relieve (§5.3.1) — a bug, not a reason to build an exception path. Two changes close it, and both ship with this spec:

1. **The guard counts only what the screen can show** — the cavity join above, mirroring `Lot_GetOpenByTool`'s own `FROM` / `WHERE`. This gives up the die-wide count's incidental ability to catch a pre-existing cross-press orphan; that property was only ever buying a block nobody could clear, and §10's pre-deploy data check is the right home for orphans.
2. **`Tools.ToolCavity_Deprecate` → v1.1** — a third pre-transaction rejection when the cavity holds an `Open` LOT (*"This cavity still has an open basket. Release or void it before deprecating the cavity."*), placed immediately after the existing not-found check and before `BEGIN TRANSACTION`, following the same `Audit.Audit_LogFailure` + `SELECT` + `RETURN` shape as its two siblings. This stops the hole being re-opened from the Config Tool, and it is the same class of invariant as the release guard rather than a new idea.

**The popup pre-flights it.** `ToolAssignment_GetCellContext` → **v1.1** appends `OpenBasketCount INT` (`0` when nothing is mounted), so the popup disables **Release** and states the reason inline instead of firing a mutation to be told no. **It must use the §5.4 predicate verbatim, cavity join included** — a pre-flight that counts differently from the guard gives you either an enabled button that fails, or a disabled button with nothing on screen to act on. The proc is the enforcement; the disabled button is the courtesy. Appending a trailing column is additive for `getCellMountContextOrEmpty`, which builds from the row dict — but any test capturing this proc via `INSERT-EXEC` must add the column to its temp table.

### 5.5 A consequence, and a separate finding

With the guard in place a die can no longer be unmounted while it holds open baskets, which makes the cross-press credit leak in (b) **prospectively unreachable through either path**. That does not retire it: `Lots.Lot_GetOpenByTool @ToolId` still has no press filter, and any orphan created before this ships is still out there. Both are out of scope here. §10 puts a data check in the verification plan and the press filter belongs in a follow-up.

**That follow-up is now coupled to this guard.** The press filter would narrow the Die Cast screen's basket list without narrowing the guard, which re-breaks §5.4's *whatever the guard counts, the screen must show* from the opposite direction: a basket stranded on another press would block the changeover here and be invisible here. Whoever picks up the press filter changes both predicates or neither. A note to that effect belongs in the follow-up's own ticket, not only in this spec.

---

## 6. Auth posture

### 6.1 The facts

- The current button is gated on `session.custom.elevatedUntil > now()` — AD per-action elevation, FDS-04-007 — because FAT #9 / #12 asked for it.
- A **PIN grants presence only, never privilege.** Nothing in the codebase reads `session.custom.user.ignitionRole` as an authorization gate, so there is no middle tier between "signed in" and "AD-elevated" to reach for.
- `ToolAssignment_Assign` and `_Release` already document themselves as elevated actions taking the authenticating supervisor's `AppUserId`, and elevation's replaced-identity behaviour already delivers it.
- A die changeover changes what part a press produces and what every downstream genealogy record will say. It is performed by a die setter, not by the press operator running the shift.

### 6.2 Three postures

| | Posture | Assessment |
|---|---|---|
| **P1** | Keep the button-level gate — the Die Mount button is enabled only while a window is already open. | Zero new code. Keeps today's poor UX intact: the operator must find Supervisor Access in the header, elevate, then come back and hope the 300s window has not lapsed. It also gates *looking*, which is the part that needs no gate. |
| **P2** | **Style-2 per-action elevation.** Button always enabled; the popup opens read-only for anyone signed in; `handleMount` and `handleRelease` each call `Common.Session.requireElevation(...)`, which stashes the intent, opens `ElevationModal`, and lets the AppHeader's `elevationResult` handler replay it. | Drafted as the recommendation; **not adopted.** It matches the three live consumers exactly and it authorizes on the action rather than on a screen — but it gates the two mutations while leaving the screen itself open, which reads the FAT ask more loosely than Jacques intended. Its per-action `requireElevation` survives in P4 as the re-assert. |
| **P3** | No elevation; any PIN-signed-in operator. | Rejected as a default. It reverses FAT #9 / #12 without anybody asking, and it makes an action that rewrites the plant's part-to-press mapping as cheap as opening a basket. |
| **P4** | **Gate at the door.** Button always enabled; pressing it raises `ElevationModal` immediately when no window is open, and the popup opens only once AD has passed. | **Adopted** (decision 1, 2026-09-14). Keeps P1's "authorize before you get in" posture — which is what FAT #9 / #12 actually asked for — while removing the part that made P1 unusable, namely that the operator had to go and find Supervisor Access in the header first. Less code than P2: the popup carries no elevation logic of its own. |

**Decision: P4.** Concretely:

- `DieMountButton.props.enabled` loses its binding entirely; the button is always pressable. `onActionPerformed` (scope `G`) calls one root custom method, `openDieMount()`, which is: elevated already → open the popup; not elevated → `Common.Session.requireElevation(self.session, "DieMount", "Die Mount")`.
- One new entry in `_ELEVATED_REPLAY_MESSAGES`: **`"DieMount": "dieMountRequested"`**. The matching page-scoped handler lives on **`DieCastBody`, not on the popup** — the popup does not exist yet when the modal resolves. This is the one structural difference from the three live consumers (`DowntimeReason`, `SortCageMigrate`, `CrtToggle`), all of which replay into a surface that is already open.
- *"Launch or swap to"* needs no mechanism: `openPopup` with the fixed id `mpp-die-mount` does not stack a second instance.
- **Mount and Release keep a cheap `isElevated` re-assert.** The gate fires when the popup opens; the mutation happens some minutes later, and the window is a rolling 300 s. If it has lapsed, the handler re-raises the modal rather than mutating. This is not a second posture — it is the same gate refusing to trust a check it made in the past. In practice the terminal's idle-expiry path usually resets the session first, so the window is narrow; the re-assert is four lines and closes it anyway. Replay is discriminated by an `intent` key in the stashed params (`"open"` / `"mount"` / `"release"`), with `DieCastBody` handling `open` and the popup handling the other two — a page-scoped message reaches every handler of that name on the page, so one replay entry covers all three.
- Nothing about attribution changes (§3).

**What P4 gives up against P2**, stated plainly so nobody re-litigates it later: a press operator can no longer *look* at what die is mounted and what could go on it without a supervisor. That information is on the Die Cast screen's tool row already, so the loss is the eligible-die list only.

### 6.3 The prerequisite — CONFIRMED 2026-09-14

**Do die setters have AD accounts? Yes** (Jacques, 2026-09-14). P4 is therefore sound as built: the people who actually perform a changeover can authorize one at the press, and the popup removes the navigation problem without leaving an authorization problem behind it.

The question mattered because the failure would have been invisible. P4 requires AD at the door, so had die setters held only PINs, this change would have relocated the Config Tool's authorization wall to the press while *looking* solved — and there is no PIN-plus-role tier to fall back on, since nothing in the system reads `ignitionRole` as an authorization gate. Building one would have been a separate piece of work, not a tweak to this popup.

Recorded here rather than left in a meeting note because it is a fact about MPP's Active Directory that no part of the repo reveals, and it is load-bearing for **every** future decision to put an AD gate on a shop-floor action. If the population of AD account holders ever narrows, this posture is what has to be revisited first.

---

## 7. Resources

### 7.1 New view — file-authored

`ignition/projects/MPP/com.inductiveautomation.perspective/views/BlueRidge/Components/Popups/DieMount/` — `view.json` + `resource.json` (`scope: "G"`; a view folder without `resource.json` renders *View Not Found*). New view, no Designer cache, so the file-edit boundary permits authoring it on disk; `.\scan.ps1` afterwards.

**Params** — the `DieCastRelease` contract verbatim:

| Param | Default | Notes |
|---|---|---|
| `cellLocationId` | `null` | The press. From `session.custom.cell.locationId` at the caller. |
| `popupId` | `"mpp-die-mount"` | For `closePopup`. |
| `replyMessage` | `"dieMountResult"` | Page-scoped reply on both exits. |

**Custom props** — every one a binding reads is pre-declared with a **fully-shaped** default, and every binding source returns the same full shape on its empty path (never `None` / `{}`):

| Prop | Default | Source |
|---|---|---|
| `context` | `{IsMountTarget: false, ToolAssignmentId: null, ToolId: null, ToolCode: "", ToolName: "", ToolTypeCode: "", AssignedAt: null, AssignedBy: "", OpenBasketCount: 0}` | `runScript("BlueRidge.Parts.Tool.getCellMountContextOrEmpty", 0, {view.params.cellLocationId}, {view.custom.refreshToken})` |
| `picker` | `{options: [], isFallback: false, count: 0}` | `runScript("BlueRidge.Parts.Tool.getEligibleToolPicker", 0, {view.params.cellLocationId}, {view.custom.refreshToken})` |
| `selectedToolId` | `null` | Bidirectional from the dropdown (`bidirectional: true` **inside** the binding `config`). |
| `mountNotes` | `""` | Bidirectional from the notes field. |
| `refreshToken` | `0` | Bumped after each successful mutation; `runScript` caches on args, so the token is what forces a re-read. |

**Layout** — two states, mirroring `CellMountCard`, sized for touch and styled only with existing classes (`pf-btn`, `pf-btn-primary`, `pf-btn-secondary`, `pf-btn-danger`, `pf-btn-large`, `pf-field-label`, `pf-field-input-mono`, `pf-kpi-sub`). The `psc-pf-*` / `pf-*` CSS is canonical in the **Core** stylesheet; nothing is added to an MPP override.

- **Occupied** (`!isNull({view.custom.context.ToolId})`): die code + name, type badge, "Mounted <ET timestamp> by <name>", and **Release** (`pf-btn pf-btn-danger pf-btn-large`). When `context.OpenBasketCount > 0`, Release is disabled and a muted line reads *"<n> basket(s) still open on this die. Release or void them on the Die Cast screen first."*
- **Empty** (`isNull({view.custom.context.ToolId})`): "No die mounted", one `ia.input.dropdown` of eligible dies, an optional notes field, and **Mount** (`pf-btn pf-btn-primary pf-btn-large`), enabled on `!isNull({view.custom.selectedToolId})`. When `picker.isFallback`, a muted line reads *"No die is mapped to this press — showing all available dies."*
- A **Close** button (`pf-btn pf-btn-secondary pf-btn-large`) on both states: page-scoped reply `{action: "close"}` then `closePopup`.

**Dropdown**: `props.options` is a list of `{label, value}` **and nothing else** — `label` is `"<Code> - <Name>"`, `value` is `Tool.Id`. The eligibility flag never rides inside an option; it surfaces as the sibling muted line above. `props.placeholder` is an object. No `allowCustomOptions` — a die that is not in the list is a data problem, not something to type past. No drag-and-drop anywhere.

**Root custom methods**: `refresh()`, `handleMount()`, `handleRelease()`, `_doMount()`, `_doRelease()`. Under P4 the popup only opens inside an elevation window, so the `handle*` pair is the §6.2 re-assert and nothing more: test `Common.Session.isElevated`, call `requireElevation(..., params={"intent": "mount" | "release"})` when the window has lapsed, otherwise straight to `_do*`. Every event-script body starts with a tab.

**Message handler**: `dieMountRequested` (page-scoped) — the elevation replay hook, shared with `DieCastBody`. It reads `payload["intent"]` and acts only on `"mount"` / `"release"`, ignoring `"open"` (which belongs to `DieCastBody`). Page-scoped messages reach every handler of that name on the page, so both views subscribing to one message is the mechanism, not a collision.

### 7.2 Changed view — **Designer**, not a file edit

`ignition/projects/MPP/.../Views/ShopFloor/DieCastBody/view.json` has a Designer cache and Designer's `=`-style escapes, so this is a Designer edit per the file-edit boundary.

- `ToolConfigButton` → renamed **`DieMountButton`**, text **"Die Mount"**, tooltip dropped.
- `props.enabled` binding **removed** — the gate moves into the handler (§6).
- `onActionPerformed` → `self.view.rootContainer.openDieMount()` (scope `G`; `system.perspective.*` silently no-ops at scope `C`).
- New root custom method `openDieMount()` — the §6.2 gate. Elevated → open `BlueRidge/Components/Popups/DieMount` with `{cellLocationId: session.custom.cell.locationId, popupId: "mpp-die-mount", replyMessage: "dieMountResult"}`, `modal=True, showCloseIcon=True`. Not elevated → `Common.Session.requireElevation(self.session, "DieMount", "Die Mount", {"intent": "open"})` and nothing else; the popup opens on the replay.
- New page-scoped message handler `dieMountRequested` — the elevation replay. Acts only on `payload["intent"] == "open"` and calls `openDieMount()`, which now finds the window open and proceeds. The popup subscribes to the same message for its own two intents (§7.1).
- New page-scoped message handler `dieMountResult` — bumps `view.custom.refreshToken`, which re-reads `activeTool`, `openBasketInstances`, `shotStatus` and `cavityOptions` in one hop. (`refreshBinding` from a message handler fails silently; the token is the mechanism.)

**The navigate-to-Config-Tool affordance is removed outright** (decision 3, 2026-09-14) — not relocated to the popup footer, not kept alongside. Two buttons with overlapping meanings on a touch panel is worse than one, everything the Config Tool offers beyond mounting is a desk activity, and a footer link would have re-introduced every §1 problem (separate project, separate login, new browser tab on a kiosk panel) behind quieter styling. The `system.perspective.navigate` call to `/data/perspective/client/MPP_Config/parts/tools` leaves the plant-floor project entirely.

### 7.3 SQL

| File | Change |
|---|---|
| `sql/migrations/repeatable/R__Tools_Tool_ListEligibleForCell.sql` | **New** read proc (§4.3). |
| `sql/migrations/repeatable/R__Tools_ToolAssignment_Release.sql` | v1.0 → **v1.1** — open-basket rejection, pre-transaction, cavity-scoped (§5.4). Goes beside the two existing rejections (missing-parameter, no-active-assignment) and before `BEGIN TRANSACTION`. |
| `sql/migrations/repeatable/R__Tools_ToolAssignment_GetCellContext.sql` | **v1.1** — append `OpenBasketCount INT`, computed with the §5.4 predicate verbatim. |
| `sql/migrations/repeatable/R__Tools_ToolCavity_Deprecate.sql` | v1.0 → **v1.1** — reject while the cavity holds an `Open` LOT (§5.4.1). Third pre-transaction rejection, same `Audit_LogFailure` + `SELECT` + `RETURN` shape as its siblings. |

All four are repeatable (`CREATE OR ALTER`); **no versioned migration** — nothing about the schema changes. Every reference is schema-qualified; `EXEC` parameters stay literals or `@variables`. The audit `Description` on the release rejection follows `<SUBJECT> · <CATEGORY?> · <ACTION>` with `Audit.ufn_MidDot()`, as the proc's existing failure logging already does.

### 7.4 Named queries — **Core only**

`ignition/projects/Core/ignition/named-query/parts/Tool_ListEligibleForCell/` — `query.sql` + `resource.json` (`version: 2`, `type: "Query"`, one parameter `cellLocationId` at `sqlType: 3`).

Nothing else. `parts/ToolAssignment_Assign`, `parts/ToolAssignment_Release` and `parts/ToolAssignment_GetCellContext` already exist and keep their signatures — `GetCellContext` gains a column, not a parameter. **No named query is created in `MPP` or `MPP_Config`**; siblings cannot see each other's, and Core is where all of them live. A scan suffices; no gateway restart.

### 7.5 Python (Core)

`ignition/projects/Core/ignition/script-python/BlueRidge/Parts/Tool/code.py`:

- **`getEligibleToolPicker(cellLocationId, _refreshToken=None)` → `{"options": [{label, value}...], "isFallback": bool, "count": int}`.** One read, one binding. `isFallback` is `True` when the rowset is non-empty and every row has `IsEligible = 0` — a fact the proc already decided; the Python only reports it. Never `None`, never `{}` — the shaped dict on every path, including the exception path (`except (Exception, java.lang.Exception)`, because a Java exception slips a bare `except Exception`). ASCII source only.
- **`getCellMountContextOrEmpty`** — add `"OpenBasketCount": 0` to the `empty` shape and coerce a `None` to `0`.
- No new mutation wrappers. `assignToCell` and `releaseAssignment` are used as they stand.

`ignition/projects/Core/ignition/script-python/BlueRidge/Common/Session/code.py`:

- One entry in `_ELEVATED_REPLAY_MESSAGES`: **`"DieMount": "dieMountRequested"`**. Nothing else in that module changes — `requireElevation` already forwards arbitrary `params`, which is what carries the `intent` discriminator (§6.2), and `dispatchElevatedAction` already one-shots and time-boxes the stash.

**No business logic lands in Python.** Type compatibility, part-to-press eligibility, the fallback decision, the 1:1 mount invariant and the open-basket guard are all in SQL. The entity script shapes rows into `{label, value}` and nothing more.

---

## 8. Flow

```
Operator at DC1-M10, PIN signed in
  └─ taps "Die Mount"  →  DieCastBody.openDieMount()
       │
       ├─ isElevated? ── no ─→ requireElevation("DieMount", intent="open")
       │                        └─ ElevationModal
       │                             ├─ AD ok → beginElevatedWindow (supervisor
       │                             │           becomes session.custom.user)
       │                             │     └─ replay "dieMountRequested" {intent:"open"}
       │                             │          └─ DieCastBody handler → openDieMount()
       │                             └─ cancelled → nothing opens, nothing written
       │
       └─ yes ─→ popup opens  ── reads GetCellContext + Tool_ListEligibleForCell
            │
            ├─ die mounted, 0 open baskets
            │    └─ Release → isElevated re-assert (window may have lapsed)
            │         └─ _doRelease() → releaseAssignment
            │              → Tools.ToolAssignment_Release  (guard passes)
            │              → toast → refreshToken++ → context re-read → Empty state
            │
            ├─ die mounted, n open baskets
            │    └─ Release disabled + inline reason. Operator closes,
            │       releases/voids the baskets on the Die Cast screen, returns.
            │       (n is exactly what that screen lists -- §5.4.)
            │
            └─ no die mounted
                 └─ pick from eligible list → Mount → same re-assert
                      assignToCell → Tools.ToolAssignment_Assign
                      → toast → refreshToken++ → Occupied state
       └─ Close → page message "dieMountResult" → DieCastBody bumps its refreshToken
```

A changeover is Release then Mount, and both run inside the single window the button press opened — `touchElevation` rolls the deadline forward on activity, so one authorization covers the whole changeover. The re-assert on each mutation exists for the case where it does not: a supervisor who authorized, walked away, and came back past the window.

---

## 9. Decisions — closed 2026-09-14 (Jacques)

**1. Auth posture → P4, gate at the door (§6.2).**
Not the drafted P2. The button is always pressable; pressing it raises `ElevationModal` when no window is open, and the popup opens only once AD has passed. One replay entry, `"DieMount": "dieMountRequested"`, with the `open` handler on `DieCastBody` rather than on the popup. Mount and Release keep a cheap `isElevated` re-assert so a lapsed window cannot ride the gate's earlier decision into a mutation. Cost of the posture: a press operator can no longer browse the eligible-die list without a supervisor. **Prerequisite, confirmed 2026-09-14:** die setters hold AD accounts, so P4 authorizes the people who actually perform the changeover rather than walling them out (§6.3). No open questions remain on this spec.

**2. Open baskets on release → block, no override, and close the hole (§5.4, §5.4.1).**
`ToolAssignment_Release` rejects while the die holds an `Open` LOT, in SQL, so the Config Tool's `CellMountCard` inherits it. No supervisor-elevated override: it cannot be a guard clause with a signature on it — it has to say what becomes of the baskets, and every honest answer to that is a subsystem (§5.3.1). The block is acceptable only because the operator can always clear it, and **that was not true when the spec was drafted** — a basket on a deprecated cavity, or one with a `NULL` `ToolCavityId`, would have been counted by the guard and invisible on the screen. So the guard counts only what `Lot_GetOpenByTool` shows (cavity join), and `ToolCavity_Deprecate` gains the matching rejection. Governing rule, recorded for the §5.5 follow-up: *whatever the guard counts, the screen must show.*

**3. Eligibility → new `Tools.Tool_ListEligibleForCell` (§4.3); Config Tool link removed outright.**
A new part-driven read proc; `Tool_ListMountableForCell` left untouched for the Config Tool card. The navigate-to-`MPP_Config` button is **removed, not relocated** — no quiet secondary in the popup footer. A footer link would have carried every §1 problem (separate project, separate login, new tab on a kiosk panel) behind softer styling.

---

## 10. Verification

**SQL** — new cases under `sql/tests/0016_Tools_Assignment/` and `sql/tests/0026_Tools_CellMount/`, capturing status-row procs with `INSERT … EXEC` into a temp table matching the SELECT shape and asserting against the temp table:

1. Release **rejected** while the die has an `Open` LOT on a non-deprecated cavity; `Status = 0`, message names the count, assignment still active.
2. Release **succeeds** once the LOT closes.
3. Release still rejects its two existing cases (no active assignment; missing params) — the new check must not reorder them.
4. **The guard does not count what the screen cannot show.** Release **succeeds** with an `Open` LOT on a *deprecated* cavity of the die, and with an `Open` LOT whose `ToolCavityId` is `NULL`. These are the §5.4.1 holes; a test that asserts the block here has the polarity backwards.
5. **Guard count equals screen count.** For a die with a mixed set (open baskets on live cavities, one on a deprecated cavity, one with `NULL` cavity), `GetCellContext.OpenBasketCount` equals the number of non-`NULL` `LotId` rows from `Lots.Lot_GetOpenByTool` for the same die. Assert the two numbers against each other, not against a hard-coded literal — the literal is what rots when either predicate moves.
6. `GetCellContext` returns `OpenBasketCount` correctly for: nothing mounted (`0`), mounted with no open baskets (`0`), mounted with two (`2`). Existing `INSERT-EXEC` captures gain the trailing column.
7. **`ToolCavity_Deprecate` rejected** while the cavity holds an `Open` LOT; `Status = 0`, cavity still active. Succeeds once the LOT closes, and still rejects its two existing cases.
8. `Tool_ListEligibleForCell` shortlists on a press carrying a machine-tier `Parts.ItemLocation` row, all rows `IsEligible = 1`.
9. Same proc falls back to every compatible unmounted die, all rows `IsEligible = 0`, on a press with no mapping.
10. Same proc excludes a die mounted elsewhere, and returns empty for an unknown / deprecated cell.

Teardown deletes `LotGenealogyClosure` before LOTs (Msg 547 otherwise). `.\Run-Tests.ps1` — exit 1 with zero reported failures means a test's own `sqlcmd` errored, usually cleanup FK order, not a product failure.

**Data check before deploy** (Dev and Prod) — the orphans §5.5 leaves behind:

- `Open` LOTs whose `ToolId` has no active `ToolAssignment`.
- `Open` LOTs whose die's active assignment cell differs from the LOT's `CurrentLocationId`.
- `Open` LOTs on a **deprecated** `ToolCavity`, or with a `NULL` `ToolCavityId` — the §5.4.1 population. The cavity-scoped guard steps around these rather than freezing on them, so they are not release-blocking; they are still invisible production and they still under-count a die's life, which is reason enough to find them before the guard makes them permanent residents.

The first two sets must be resolved before the guard ships. The third should be counted and reported even if it is not cleared — a non-zero count here is the measure of how much the `ToolCavity_Deprecate` guard is arriving late.

**Ignition** — `.\scan.ps1` after the new view + NQ; check `wrapper.log` for GSON deserialize errors (valid JSON can still fail schema; `customMethods` params must be `list[str]`). Confirm the new NQ resolves — a missing read NQ shows up as *"Named query not found"* in the log and as a silently inert editor.

**Runtime click-through** at a die cast terminal, which is the only place several of these can be checked:

- Pressing **Die Mount** with no window open raises `ElevationModal` immediately; on AD success the popup opens by itself. Pressing it *with* a window open goes straight to the popup.
- Cancelling the elevation (close icon, overlay dismiss, bad credentials) opens nothing and writes nothing — and a *later, unrelated* elevation (e.g. the header's Supervisor Access) does not resurrect the dismissed popup. That is `dispatchElevatedAction`'s one-shot + `PENDING_ACTION_TTL_MS` behaviour; this is the test that proves it holds for a new `intent`-carrying code.
- Pressing Die Mount twice does not stack a second popup.
- The mounted die, its ET mount timestamp and the mounting user all render; the mounting user is the **supervisor** who authorized, which is `beginElevatedWindow`'s replaced-identity behaviour working as designed (§3), not a defect.
- Die with open baskets → Release disabled, reason line visible, **and the count matches the baskets listed on the Die Cast screen behind the popup**; after releasing/voiding them there, Release enables.
- Mount on an unmounted press → shortlist on a mapped press, fallback line on an unmapped one.
- A changeover — Release then Mount — raises the modal once, not twice (rolling window).
- Closing the popup refreshes the Die Cast screen's die, baskets and shot badge in one hop.
- No Component Errors / Quality-Bad on first paint with an empty cell, an unknown cell, and a cell with no compatible dies.

**Prod** ships as the five things: preview with plan fingerprint, rehearsal in a rolled-back transaction against live data, fingerprint-guarded execute after a verified `COPY_ONLY` backup, scoped exports built from git via `tools/Build-ChangeExport.ps1` (Core first — the NQ and both entity scripts live there), and a published runbook mirrored to `notes/`.

---

## 11. Revision history

| Version | Date | Author | Change |
|---|---|---|---|
| 0.1 | 2026-09-14 | Blue Ridge (with Claude) | Initial draft. Three decisions open (§9). |
| 0.5 | 2026-09-14 | Blue Ridge (with Claude) | Dev verification complete. The open-basket block was exercised (Release disabled with its reason line while a basket is open, enabled once cleared) and so was a non-Die-Mount elevated action from cold, which is the only check that covers the shared `Common.Session` replay fix for the other four elevated actions. Remaining risk is prod DATA, not code: the §6 pre-flight queries in the handoff, and especially §6B, which is expected to return rows on a running plant. |
| 0.4 | 2026-09-14 | Blue Ridge (with Claude) | Verified at a Dev terminal by Jacques: one tap on Die Mount raises the AD prompt and the popup opens itself on success. Also records `860d4d83` -- the elevation replay delivered a payload that was a live view into `session.custom.pendingElevatedAction`, cleared before `sendMessage`, so every param-carrying replay arrived empty and the first protected action of a session silently did nothing. Params are detached before the stash is cleared; this also repaired a latent `DowntimeEdit` bug. Remaining checks in `notes/2026-09-14_die-mount-prod-handoff.md` §7. |
| 0.3 | 2026-09-14 | Blue Ridge (with Claude) | Built and committed — `3616026e` (4 procs, 4 test suites, Core NQ + entity scripts, DieMount popup; 246/246 tests, 39 new) and `bf377911` (DieCastBody repointed). §6.3's prerequisite **confirmed**: die setters hold AD accounts, so P4 authorizes the people who perform the changeover. No open questions remain. Only the §10 runtime click-through is outstanding. |
| 0.2 | 2026-09-14 | Blue Ridge (with Claude) | All three §9 decisions closed by Jacques. **(1)** Auth posture is **P4 — gate at the door**, not the drafted P2: the button raises `ElevationModal` and the popup opens only after AD passes; replay code `"DieMount": "dieMountRequested"` with the `open` handler on `DieCastBody`, an `intent` discriminator in the stashed params, and an `isElevated` re-assert kept on Mount / Release (§6.2, §7.1, §7.2, §8). §6.3 recast from a gating question to a standing prerequisite. **(2)** Open baskets — **block, no override**; §5.3 gains an override row and §5.3.1 the reasoning against it. §5.4.1 is new and load-bearing: verification against the live procs showed the block's "always resolvable on the same screen" premise was **false** — `Lot.ToolCavityId` is nullable, `Lot_GetOpenByTool` v2.1 hides baskets on deprecated cavities, and `ToolCavity_Deprecate` v1.0 has no open-LOT guard. The release guard is therefore cavity-scoped to what the screen shows, and `ToolCavity_Deprecate` → v1.1 gains the matching rejection (§5.4, §7.3). Governing rule recorded and the §5.5 follow-up coupled to it. **(3)** Eligibility proc as drafted; Config Tool link **removed outright**, no footer link (§7.2). §10 verification extended: SQL cases 4/5/7 new, click-through rewritten for P4, data check gains the deprecated-cavity population. |
