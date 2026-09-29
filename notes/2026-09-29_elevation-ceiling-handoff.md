# Elevation window: activity-extended, with a ceiling — handoff

**Date:** 2026-09-29
**Branch:** `jacques/working`
**Status:** SQL + Core scripts done and green. **Two Designer edits owed** (below). Not deployed.

Pulled forward out of Plan 2 (die cast reconciliation screen) because it fixes existing
flows too — Die Mount, CRT toggle, downtime edit/void, sort-cage migrate all sit behind
the same window.

---

## The bug this fixes

There are **two independent clocks**, and nothing connects them:

| Clock | Set by | Resets on | Governs |
|---|---|---|---|
| `session.props.lastActivity` | Perspective itself | real user interaction | the idle reset / reconfirm in `AppHeaderLarge` |
| `session.custom.elevatedUntil` | `beginElevatedWindow`, **once** | never | `isElevated()` — whether protected actions pass |

So somebody working **continuously** for longer than `ElevationTimeoutSeconds` (300 s) is
never idle — no reset fires, the screen looks fine — but their elevation has silently
lapsed and protected actions start refusing. That is the normal shape of reconciling a
die cast shift off a paper press sheet, and it is why `touchElevation` was written. It
has been in `Common/Session/code.py` since the elevation work and **is called from
nowhere**.

## Why it needed a ceiling before it could be wired

`beginElevatedWindow` **replaces `session.custom.user` with the supervisor**. An
elevation that activity alone could extend without limit would attribute an operator's
entire shift to a supervisor who elevated once and walked off — the terminal stays busy,
so the window never lapses. The 300 s hard cap is what bounds that today.

`ElevationMaxSeconds` replaces that bound: activity buys time **up to the ceiling** and
no further.

Walk-away was already safe and still is — `lastActivity` goes stale, the idle poll fires,
`resetTerminal` runs.

---

## What is done

**SQL** — migration `0100_session_policy_elevation_max.sql`

- `Location.SessionPolicy.ElevationMaxSeconds INT NOT NULL DEFAULT 1800`
- `CK_SessionPolicy_ElevationMax`: `30..28800` **and** `>= ElevationTimeoutSeconds`
- Range is wider at the top than the rolling timeout's 3600 (a real reconciliation can
  outlast an hour) but stops at one 8-hour shift, so the window cannot be configured
  into "forever".
- One row, so `ADD ... NOT NULL ... DEFAULT` is trivial here — unlike `0099`.

`Location.SessionPolicy_Get` v1.1 projects it. `Location.SessionPolicy_Update` v1.1 takes
`@ElevationMaxSeconds`, validates both bounds and the ordering rule, and names a ceiling
change in its own clause of the audit description.

**Tests** — `sql/tests/0020_PlantFloor_Foundation/030_SessionPolicy_crud.sql`, 6 → 15
assertions. Covers the ceiling in `_Get`, persistence, the runaway upper bound, the
below-the-rolling-timeout refusal, **equality is legal** (the rollback lever), and the
audit naming.

**Core scripts**

- `Common.Session.loadPolicyIntoSession` carries `elevationMaxSeconds`.
- `beginElevatedWindow` stamps `session.custom.elevatedHardUntil`.
- `touchElevation` extends the rolling deadline, **clamped** to the ceiling.
- `isElevated` tests **both** clocks, so an `elevatedUntil` written by an older build —
  or by any future caller that forgets the clamp — still cannot outlive the ceiling. A
  session with no ceiling (pre-0100 state, mid-upgrade) falls back to the old behaviour.
- `_elevationMaxSeconds` takes `max(ceiling, rollingTimeout)` — third line of defence
  behind the proc and the CHECK.
- Both places that clear elevation now clear the ceiling too
  (`Common.Session` reset path, `Location.Terminal.applyToSession`).
- `Location.SessionPolicy.updatePolicy`: **omitting `elevationMaxSeconds` means "leave it
  as it is"** — the stored value is read back and passed through. See the regression note
  below. The *proc* stays strict; only the script fills an omitted key.

**Ignition resources** — `location/SessionPolicy_Update` NQ gains `elevationMaxSeconds`
(`sqlType: 3`, matching its siblings); MPP `session-props` declares
`elevatedHardUntil: null`.

**Verified:** `030_SessionPolicy_crud` 15/15 on a throwaway (`MPP_MES_Test_SP`) — red
first (`Msg 213`, column-count mismatch), then green. Migration + both procs applied to
`MPP_MES_Dev` apply-only; the row reads `1800 | 300 | 1800`.

---

## The regression I nearly shipped, and how it is handled

The Configuration Tool's **Users → Session timeouts** panel saves with

```python
BlueRidge.Location.SessionPolicy.updatePolicy(
    {"operatorPresenceTimeoutSeconds": op * 60, "elevationTimeoutSeconds": el * 60}, ...)
```

— **no `elevationMaxSeconds`**. With a strict pass-through that becomes a NULL, the proc's
required-parameter guard refuses, and every save on that panel reports *"Not saved"*.

`updatePolicy` therefore treats an omitted key as *unchanged*, not as *default*: it reads
the stored ceiling and passes it through. A caller that omits the key gets the value
already in force, never a widened one.

**Consequence while the Designer edit is outstanding:** the panel works, but raising the
elevation timeout **above 30 minutes** will be refused ("The elevation ceiling must be at
least the elevation timeout…") with no way to raise the ceiling from that screen. Nobody
is likely to do that, but it is the reason the Designer edit should not sit for long.

---

## OWED — two Designer edits

File-editing an existing view risks the Designer-vs-disk reconciliation race, so these
are deliberately **not** done as file edits.

### 1. `MPP` → `Views/ShopFloor/AppHeaderLarge` — wire the touch

Binding: `view.custom.idleTick` (expression `now(10000)`), its **onChange** script. Add an
`else` to the existing idle test:

```python
	try:
		idleMs = system.date.toMillis(system.date.now()) - self.session.props.lastActivity
		secs = BlueRidge.Common.Session.activeTimeoutSeconds(self.session)
		if idleMs > secs * 1000:
			if BlueRidge.Common.Session.isElevated(self.session):
				BlueRidge.Common.Session.resetTerminal(self.session)
			else:
				u = self.session.custom.user
				if u and u.get("appUserId"):
					system.perspective.openPopup("mpp-idle-reconfirm", "BlueRidge/Components/PlantFloor/IdleReconfirmModal", params={"initials": u.get("initials"), "displayName": u.get("displayName"), "popupId": "mpp-idle-reconfirm", "replyMessage": "idleReconfirmResult"}, modal=True, showCloseIcon=False)
		else:
			# Not idle: keep an in-progress elevation alive, up to the ceiling
			# stamped at grant. No-op unless elevated.
			BlueRidge.Common.Session.touchElevation(self.session)
	except:
		pass
```

Two lines. Nothing else in that script changes. The event body must start with a **tab**.

### 2. `MPP_Config` → `Views/Audit/Users` (`SessionPolicyPanel`) — expose the ceiling

Storage is **seconds**, the panel presents whole **minutes** — convert at the boundary, as
the existing two fields do.

- `load()` (≈ line 689): add
  `"elevationMaxMinutes": int(round((p.get("ElevationMaxSeconds") or 1800) / 60.0))`
- Save (≈ line 699): read it, guard `None`, and pass
  `"elevationMaxSeconds": mx * 60` into `updatePolicy`.
- Add the numeric input bound to `view.custom.policy.elevationMaxMinutes`
  (`deferUpdates: false`, per the input-commit rule — the Save reads what is typed).
- Label it as the ceiling, not a third timeout. Suggested helper text:
  *"The longest a supervisor's elevated session can last, even while they keep working.
  Must be at least the elevation timeout."*

---

## Rollback

Set `ElevationMaxSeconds = ElevationTimeoutSeconds`. The window then cannot be extended at
all, reproducing pre-0100 behaviour exactly. That equivalence is asserted by
*"[SessionPolicy] ceiling may equal the rolling timeout"*, so it is a tested lever rather
than a hopeful one.

---

## Known gap, pre-existing, NOT fixed here

`AppHeader`'s root is a **breakpoint container at 800 px**. The idle poll lives only in
`AppHeaderLarge`, so **below 800 px viewport width there is no idle poll at all** — no
reset, no reconfirm, and `touchElevation` will not run either. Laptops and plant terminals
are all above it, so the reconciliation screen is unaffected, but idle handling generally
has this hole. `AppHeaderSmall` has no `idleTick` binding.

---

## Release notes

Migration `0100` is a one-row `ADD COLUMN` plus a `CHECK` on a one-row table — no `Sch-M`
concern, unlike `0098`/`0099`. Ships with the Core script changes and the NQ; the two
Designer edits must be in the same window, or the Config Tool panel keeps working but the
touch never fires. Full release contract applies (`prod-release-context-pack/`).
