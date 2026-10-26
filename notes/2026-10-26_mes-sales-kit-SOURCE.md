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

(filled in at hand-over)
