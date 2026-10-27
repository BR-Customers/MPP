# MES Track & Trace sales kit -- SOURCE (internal, never shared)

The shareable kit lives at `C:\Users\JacquesPotgieter\Documents\Dev\Marketing\MES Track & Trace\`
(its own local git repo). It was built from **this project (MPP MES)** using Aaron's
`ignition-sales-kit` skill. This note is the only place the link between the two is written down.

- Design: `docs/superpowers/specs/2026-10-22-mes-sales-kit-design.md`
- Plan: `docs/superpowers/plans/2026-10-26-mes-sales-kit.md`
- Term checker: `tools/sales-kit/check_terms.py` + `banned_terms.txt` (the list names the customer,
  so it never goes into the kit). Run before anything leaves Blue Ridge:
  `python -I tools/sales-kit/check_terms.py "C:\Users\JacquesPotgieter\Documents\Dev\Marketing\MES Track & Trace"`

## Concept mapping (real behaviour -> sample plant)

Names are invented; the behaviour is MPP's.

| MPP behaviour | Sample plant |
|---|---|
| Die cast machine with a mounted die, a basket per cavity, LOT named from its pre-printed ticket | Presses P-01..P-03, dies D-210 / D-220 / D-240, basket LOTs `LT######` |
| Family die: cavity letter unique per (tool, part, letter), grouped part-then-letter | D-220 makes CVR-220 and BRK-230, both with cavities a / b |
| Additive die-cast scrap; basketless cavity is pending, outside the identity | Same rules in `model.js` `recordScrap` / `reconcile` |
| Shift reconciliation: net shots = good + scrap + unaccounted; mandatory disposition, `Unknown` always allowed | Same; reasons: Warm-up shots, Counter error, Short shot not logged, Unknown |
| Trim IN/OUT, subtractive scrap | One trim area, `TRIM` |
| Line-resident LOTs, FIFO Machining IN pick by ticket scan | `lineQueue` / `machiningInPick` |
| Machining OUT consume-mint (casting -> SubAssembly, `Consumption` genealogy) | `machiningOutMint`, `-M` items, line L-1 |
| Line without Machining OUT: Assembly OUT consumes castings directly (Model Y) | Line L-2 |
| Low-inventory lock, purchased box check-in by supplier lot | `isLocked` / `checkInBox`, SEAL-01 |
| Tray completion, containers | `assemblyCompleteTray` / `packContainer` |
| PIN sign-in (5 digits, leading zeros kept), per-action AD elevation | PIN pad + "needs a supervisor" modal |
| Genealogy Viewer, LOT Detail, Global Trace, LOT Detail PDF | Module 1 views + printable trace report |

Not carried over, on purpose: the known wart where a minted SubAssembly stays in the Machining OUT
queue (CLAUDE.md, verified 2026-08-12). The demo's model has a regression test against it.

## Maturity snapshot used for the kit (2026-10-22)

Everything shown in modules 1-3 is in MPP prod except the Assembly Out scale station (left out).
Controlled runs / super-lots are packaged, not deployed (left out of modules 1-3; on the add-ons
slide). No OEE dashboard exists (add-on only). The kit claims "proven in production at a
manufacturer" once, for the system as a whole.

## Study material (read, never copied into the kit)

`notes/2026-10-22_mpp-mes-walkthrough.html` (DOM captures of the live app),
`mockup/diecast_reconcile_mock.html`, `mockup/diecast_shift_reconciliation_mock.html`.

## Build record

Built 2026-10-26 in the kit's own git repo (`Dev\Marketing\MES Track & Trace`, no remote).

- Demo: `MES Track & Trace - Interactive Demo.html`, ~190 KB, one file. Domain model + simulation
  unit-tested in Node (`demo-build/test`, 30 tests). Verified in the browser at 1600x900, 1024x768
  and 700x900, inside an iframe, and from `file://`; all four tours at 10x with a reset mid-tour;
  no console errors; no network requests beyond the page.
- Deck: `MES Track & Trace - Overview.pptx`, 27 slides (core 6, three modules of 5, close 6).
  `check_deck.py` 10/10, pptx `validate.py` passes, PowerPoint COM confirms the menu tiles jump to
  slides 7 / 12 / 17 and every module slide links back to slide 6.
- `check_terms.py` against the whole kit folder (deck XML included): 0 hits.

Machine notes: headless Edge writes no screenshot on this machine (exit 0, no file), so captures
use headless Chrome (`tools/capture_scenes.py`). `capture_scenes.ps1` / `render_pptx.ps1` were run
as inline commands rather than with a relaxed execution policy.

Open: the booking link for "Schedule a live demo with one of our engineers" is a placeholder in
`demo-build/src/config.js` (`cta`) - set it there and rebuild.

## Real screens (2026-10-27)

The first kit's screens were a lookalike drawn in the demo. Both deliverables now show the real
application, captured against a sample-plant database. Spec
`docs/superpowers/specs/2026-10-26-mes-sales-kit-real-screens-design.md`, plan
`docs/superpowers/plans/2026-10-26-mes-sales-kit-real-screens.md`.

- **Database.** `tools/sales-kit/demo-db/Build-DemoDatabase.ps1` builds `MPP_MES_Demo` from the
  migrations (`Reset-DevDatabase.ps1 -SkipSeeds`), the generic code-table seeds, `sql/seeds_demo/`
  (sample plant, people, parts, dies) and a one-shift scenario run through the real procs, then
  `sanitize_db.py` and the text-dump gate. Never loaded into Dev or prod.
- **Capture.** Jacques points the gateway's `MPP` connection at `MPP_MES_Demo`,
  `capture/capture.js` drives Chrome through 16 steps (terminal chosen through the location tree,
  since the capture browser's IP is not a registered terminal), and the connection is switched
  back to `MPP_MES_Dev` the same session (`demo-db/Check-GatewayDb.ps1 -Expect Dev`). Raw output
  stays in the gitignored `tools/sales-kit/captures/`.
- **Sanitize.** `capture/sanitize.py` applies `substitutions.json`, renames the project token in
  classes, styles, ids and popup component paths, strips CSS comments and drops the Perspective
  client chrome (session panel with the gateway host name, trial notice, banners), renders the deck
  PNGs and gates the result. It also drops the capture date from on-screen text and keeps the time
  (terminal clock "Tue Oct 27", LOT timestamps "10/27/26 08:49" / "10/27 08:49", the shift picker's
  "First Shift - 10/27 (current)"); a date is recognised only beside a time or "(current)", so
  counts like "12/48" survive. The kit-wide `check_terms.py` gate catches those formats too, plus
  ISO timestamps and plural `LTTs`.
- **Demo.** `demo-build/src/ui/rs.js` mounts each captured screen in a same-origin iframe at its
  captured width, scaled to fit, and the module files fill live regions by `data-component-path`.
  Numbers follow the application: baskets `520` + press + sequence, sub-LOTs `<parent>-NN`, trays
  and received boxes `MESL…`, containers `Container #N`. 37 Node tests. Verified at 1600x900,
  1024x768, 700x900, in an iframe and from `file://` (headless Chrome: no console errors, no
  outside requests, every tour highlight found); all four tours at 10x with a reset mid-tour;
  half-typed PIN, open elevation dialog, LOT detail tab and trim selection survive ticks.
- **Deck.** 26 slides on `deck-build/screens-real/`; `check_deck.py` 10/10, `validate.py` passes.

Rulings taken while building (not customer-visible):

- Dropped: the Reports page (the rendered PDF carried the customer name in its pixels) and the
  assembly low-inventory lock capture (could not be triggered on the sample data). The demo shows
  the lock with the application's own station banner, worded for the lock, and a check-in dialog
  of the demo's own.
- Supervisor Dashboard: the three tiles the application still shows as placeholders
  ("pending", "Phase 7") are hidden in the demo; "Paused LOTs" is relabelled "Open Baskets".
- Assembly's printer banner ("No printer set up for this station") is a dev-environment artifact:
  hidden in the demo, still visible on deck slide "Trays and containers at the line".
- The unknown-PIN and register dialogs, the trim/press scrap dialogs and the reason picker are the
  demo's own (the real popups were not captured).
- Seen in passing, not investigated: Complete Tray with nobody signed in shows the expected refusal
  plus a second "Required parameter missing (AppUserId)" toast.
