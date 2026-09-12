# Die Cast + Trim How To guide audit

**Date:** 2026-09-12
**Scope:** the five operator How To guides on the Die Cast and Trim shop-floor
screens, reviewed against the live views, script modules, and stored procs.
**Outcome:** all five rewritten in `tools/gen_howto_views.py`; one stale
on-screen label fixed in `TrimBody`.

## Why this was worth doing

Three capabilities shipped into Die Cast after the guides were written and none
of them reached the guides. Two of the guides did not merely omit the new
behaviour &mdash; they actively described the world as it was *before* it, and
in the worst case told the operator to do the one thing that cannot work.

The guides are generated, and the generated views matched the generator
byte-for-byte before this change, so the generator was the only thing to edit.

## Findings

### Die Cast

**1. The counter-anchor escape hatch was documented nowhere (material).**

`FixCounterButton` &mdash; *"Counter reset / wrong total?"* &mdash; sits on both
the Record Shift Output tab and inside the Release dialog, and opens
`Popups/DieCastCounterAnchor`. It exists because both shot watermarks are
`MAX(reading)` over the shift, so a mid-shift press-counter reset (or a wrong
number typed earlier) blocked the die for the rest of the shift with no way
out. Migration `0074_diecast_counter_anchor.sql`.

The Lot Release guide closed with *"a lower number means a digit went astray.
Check what you wrote down."* `ReleaseButton.props.enabled` is
`readingState != "Behind"`, so with a genuinely reset counter the operator was
hard-blocked and the remedy sat unmentioned beside the Cancel button.

The Shift Output guide asserted *"the counter resets at the end of every shift
&hellip; only ever climbs"* &mdash; the pre-anchor model.

Also undocumented: the `CounterContextLabel` line that is now the first thing on
the tab (`describeCounterContext`, three branches: nothing recorded / recorded
by entry / set by hand + reason).

**2. "Basket capacity exceeded" was undocumented (material).**

`SUBMIT SHIFT OUTPUT` opens `Popups/DieCastOverflow` whenever any open basket's
good count exceeds `MaxHeadroom`. Per cavity the operator must tick **Overfill
this basket** or scan a **new LTT**, then **Apply**. With standard pack
quantities this fires routinely at shift end. `CavityLotRow`'s *"Over basket
headroom"* warning was equally unexplained.

**3. Release-dialog advisories were undocumented (moderate).**

`ChainNote` (*"already credited through counter N &mdash; the system subtracts
it, you never do"*) and the three-state `Advisory`: **Behind** (red, blocks
release), **None** (*"closes the basket at its current count and credits this
cavity nothing further"*), **BelowStandard** (`< 95%` of `MaxPieceCount`, per
`R__Workorder_DieCast_GetReleasePreview.sql:101`). The Release button turns
danger-red in the latter two. The no-reading case is precisely the silent loss
the dialog was built to prevent.

**4. Shot-loss quantity was ambiguous (moderate).**

The guide said *"logged once for the die, not per cavity."*
`R__Workorder_DieCastShiftOutput_Record.sql:235` fans one `RejectEvent` of
`sl.quantity` across **every** Open LOT on the tool &mdash; qty 5 with four open
baskets is 20 pieces scrapped, 5 per basket. The semantics are right (the number
is *shots*), but "logged once" reads as a total, the field placeholder is just
`qty`, and the very next bullet says basketless cavities are listed so their
scrap can be recorded &mdash; which they cannot receive from here.

**5-7. Smaller.** The button reads `OPEN N BASKET(S)` whenever it is pressable
(it is disabled at zero), not `OPEN BASKETS`. Three Open-tab controls were
unmentioned: *Copy part to empty rows*, *Clear*, and *Tool Config*
(elevation-gated on `session.custom.elevatedUntil`).

### Trim

**8. The stale text was on the screen, not in the guide.**

`TrimBody` &rarr; `OutSub` still read *"&hellip; choose the production line,
record counters."* There is no line picker; the 2026-07-07 terminal-mint
redesign removed it. The generator comment above `trim_check_in_source()`
records that the *guide* was corrected against exactly this &mdash; the screen
label was missed. Same class as the `MachiningOutSplit` labels the generator
already flags.

**9-11.** The Check IN guide was two steps and dropped everything the screen
says: `MovementScan` reviews five fields (LOT / item / **pieces** / eligibility
/ **capacity**), `InSub` names the max-parts cap, `InNote` explains why no count
is entered at IN, and neither the *Currently in Trim* list nor the **Active
Cell** picker appeared. On the OUT side the button is *"More reasons (N)"* and
toggles to *"Show Trim reasons only"*, and the scrap grid is hidden until a LOT
is selected &mdash; which reads as a broken screen.

## What changed

| File | Change |
|---|---|
| `tools/gen_howto_views.py` | All five guide sources rewritten (findings 1-7, 9-11). |
| `Popups/DieCastOpenHowTo`, `DieCastShiftOutputHowTo`, `DieCastLotReleaseHowTo`, `TrimCheckInHowTo`, `TrimCheckOutHowTo` | Regenerated. |
| `Views/ShopFloor/TrimBody` | `OutSub` label corrected (finding 8). One-line diff. |

Shift Output is now seven steps: the counter-context line became step 1, so the
old 1-5 shifted to 2-6, and the overflow branch is step 7 (it happens *after*
Submit).

Verified: generator parses; its own verifier passes including
`112 openPopup viewPath(s) resolve`; every `div/table/tr/td/span` pair balances
in all five rendered guides; `TrimBody` still parses; `.\scan.ps1` clean.
Confirmed the new bytes are readable through the Gateway's own junctioned path.

## Left open deliberately

- **No anchor check in the generator's verifier.** It checks structure (empty
  source, string-in-`markdown`, `escapeHtml`, unbalanced tags, `resource.json`,
  popup viewPath resolution across the MPP&rarr;Core inheritance chain) but
  nothing that a guide's quoted UI strings still exist in the view it documents.
  A per-guide `anchors=[...]` list asserted against the target `view.json` would
  have caught findings 5, 8 and 10 mechanically. This is the fix that stops the
  drift recurring; everything above is a one-time correction.
- **`DieCastBody`'s SUBMIT handler is ~40 lines of inline Python in
  `view.json`** (overflow detection, line assembly, popup dispatch), against the
  3-line cap in `ignition-context-pack/07_conventions_and_antipatterns.md`. It
  belongs in `BlueRidge.Workorder.DieCast.handleSubmitShiftOutput(...)`. Raised,
  not changed &mdash; it decides whether the overflow popup opens.
- **Panel header vs tab name.** The tabs read *Open Basket / Record Shift Output
  / Lot Release*; the panel headers read *Open Baskets* / *Currently Open*. The
  guides use the tab labels (correct), but an operator on the Lot Release tab
  sees a panel titled something else.
- **`gen_howto_views.py:1539`** carries a literal `&rarr;` (U+2192), the only
  non-ASCII byte in the file. Pre-existing, renders fine as UTF-8 JSON, and the
  ASCII-only rule is scoped to SQL seeds and ZPL. Left alone.
