# 6MA Cam Holder Line 1 — Assembly OUT terminal observations

**Date:** 2026-09-15
**Source:** Jacques, screenshot of the Assembly OUT (Non-Serialized, BY VISION)
terminal at 6MA Cam Holder Line 1, 11:17 ET, plus three remarks:
"tray complete should update the screen totals", "what the heck happened to the
spacing / view / layout", "6MA cam rockers are 11 trays ahead of what the system says".

**Status:** Diagnosed from source. **Not fixed.** Nothing verified against a live
gateway — the local Ignition Perspective client trial had expired when this was
written, so `localhost:8088` would not render a session.

---

## 1. The sidebar layout blowout — diagnosed, high confidence

**Nothing changed in the code. The data got bigger.**

`Views/ShopFloor/AssemblyNonSerialized/view.json` → `InventorySidebar/SidebarList`
is a **single `ia.display.label`** carrying the whole components list as one
`\n`-joined string:

```
SidebarList | ia.display.label
  props.text  ← view.custom.queueByPartVertical   (transform joins rows with "\n")
  style.classes = "pf-field-input-mono"
  style.lineHeight = "2.0"
  style.whiteSpace = "pre-line"
```

`psc-pf-field-input-mono` is a **single-line input-field style**
(`stylesheet.css:2354`): `min-height: var(--pf-touch-min)` — a 44px touch target —
plus `padding: 0 14px`, a border and a radius. It was written for a one-line scan
field and is being used to render a multi-line block.

The parent `psc-pf-panel` (`stylesheet.css:2600`) sets `display:flex; flex-direction:
column` with **no `overflow` and no `min-height: 0`**, so nothing clips and nothing
scrolls.

Result: the box stays at input height while the text renders at
8 rows × lineHeight 2.0. The label centres its text in the box, so the overflow
spills **both upward and downward** — over `SidebarLabel` ("Components at this cell")
above and `ProjectionHeader` ("Projected to finish container") below. That is exactly
the screenshot, right down to the rounded input border visible *behind* the
overflowing rows.

This was invisible until now because Dev carried one or two components at a cell.
6MA Cam Holder Line 1 has **eight**.

**Fix direction:** stop rendering a list as one label. Make it a flex-repeater of
rows (the `Trim/InventoryRow` card already exists and `getLineInventoryCards` already
builds repeater instances), or at minimum give `SidebarList` its own scroll box
(`overflow-y:auto`, `min-height:0` on the panel) and drop the input-field class for a
real block style. Either way this is an **existing** view → Designer, per the
file-edit boundary.

The top-of-screen overlap in the same screenshot — the view's "Assembly ·
Non-Serialized Line" header riding under the 88px `AppHeader` top dock — was **not**
diagnosed. It could be the same overflow class or simply the page scrolled under a
`anchor: fixed` dock. Needs a live session to confirm; do not guess a fix.

---

## 2. "Tray complete should update the screen totals" — the wiring is all there

Traced end to end, and every link exists:

`TrayInspectionWatcher._pulseOnTrayPassed` → `_closeTray` →
`Assembly.plcCompleteTray` → on success calls **`notifyInventoryChanged(cell, terminal)`**
(`Workorder/Assembly/code.py:313`) → `PlcWatcher.broadcastPageMessage` sends the
page-scoped `inventoryChanged` message to every open session/page → the view's
handler bumps `view.custom.refreshToken` → and **every** stale binding on that screen
consumes `refreshToken`: `container` (the "accumulated N / M" and tray counter),
`getStationOpenBoxesText` ("Open boxes"), `componentProjection`, `queueByPartVertical`,
`crtPending`, `printerCards`.

So if the totals are not moving, the cause is **upstream of the refresh**, and there
are only three candidates:

1. **The tray was never booked.** See §3 — this is the one that also explains the
   11-tray gap, and it is by far the most likely.
2. **The message is filtered out at the handler.** The guard is
   `loc == self.session.custom.cell.locationId`, and the payload's `cellLocationId`
   comes from `resolvePlcCloseContext(terminalLocationId)`. If the terminal resolves
   to a different cell than the session is pinned to, the message is silently
   dropped. Worth checking these two agree for this terminal.
3. **The broadcast throws before reaching the session.** Historically real —
   `broadcastPageMessage` exists because a malformed session/page entry threw
   `java.lang.IllegalArgumentException` on every call (2026-08-20). Gateway logs
   would show it.

Diagnose in that order. Do not "fix" the refresh wiring before ruling out §3 —
there is nothing wrong with it that source inspection can find.

---

## 3. 6MA cam rockers 11 trays ahead of the system

Could not be investigated from here: `Audit.InterfaceLog` in `MPP_MES_Dev` holds only
three `ByWeight tray close` rows from 2026-07-22 on `59B_1_FP_1`. There is no 6MA tray
history in Dev — this observation is from the plant.

**The good news: every non-booked tray leaves a row.** 6MA_CH runs the
`SlcPassPulse` protocol, and `_pulseOnTrayPassed` has four exits that log to
`Audit.InterfaceLog` with a distinct `Description` and never book the tray:

| `Description` | Meaning |
|---|---|
| `Tray passed -> NOT booked (no finished good)` | `_expectedRecipe` could not resolve an FG at the cell |
| `Tray passed -> NOT booked (vision program unreadable)` | `VisionPartNumber` (N16:2) read returned nothing |
| `Tray passed -> NOT booked (vision program mismatch)` | camera passed the tray on a different vision program — treated as a master tray / rabbit / HMI override |
| `Container completion refused` | tray booked, but a full container could not complete (e.g. empty AIM pool) — the *next* tray then fails as "Container is full" |

Run this on the plant DB to see whether the 11 are sitting there:

```sql
SELECT TOP 100
       CAST(LoggedAt AT TIME ZONE 'UTC' AT TIME ZONE 'Eastern Standard Time'
            AS DATETIME2(0)) AS ET,
       SystemName, Description, ErrorDescription, RequestPayload
FROM   Audit.InterfaceLog
WHERE  Description LIKE '%tray%'
  AND  LoggedAt >= DATEADD(DAY, -2, SYSUTCDATETIME())
ORDER BY Id DESC;
```

A count of 11 `NOT booked (vision program mismatch)` rows would close this outright.

**If the log is empty instead, the gap is a start-of-run offset, not lost trays** —
the line was already part-way through a container when the MES started counting. That
is the *hot start* problem: see
[2026-09-15_hot-start-a-running-line.md](2026-09-15_hot-start-a-running-line.md).

One structural note either way: `_pulseOnTrayPassed` is documented as **not
replay-safe** — an `N7:10` already high at gateway start is *dropped* rather than
double-booked. A gateway restart while a tray sat passed therefore loses that tray
silently. Deliberate, and the right trade, but it is a systematic source of
undercounting that will never appear in the interface log.

---

## Related

- Parts-labelling requirement from the same screenshot:
  [2026-09-15_parts-dropdowns-label-by-description.md](2026-09-15_parts-dropdowns-label-by-description.md)
- 6MA_CH ladder decode: `notes/2026-09-11_6ma-ch-real-ladder-slcpasspulse.md`
- 6MA parallel run: `notes/2026-09-11_prod-release-runbook-6ma-parallel-run.md`
