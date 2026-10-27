# MES sales kit -- real screens from the real application (design)

**Date:** 2026-10-26
**Status:** Draft for Jacques's review
**Builds on:** `docs/superpowers/specs/2026-10-22-mes-sales-kit-design.md` (the kit as built:
`C:\Users\JacquesPotgieter\Documents\Dev\Marketing\MES Track & Trace\`). Everything in that design
stays in force -- anonymization, maturity rule, menu structure, deliverable names -- except what
this document changes.

## 1. Why

Jacques's verdict on the first kit: the deck looks right, but **none of the screens look like the
application we built** -- they are a lookalike drawn in the demo, and so is the HTML. A prospect
who later sees the real Ignition application should recognise every screen from the kit.

So the kit's screens come from the real MPP Perspective application, running against a database
of fictional sample-plant data, captured step by step.

## 2. Decisions taken with Jacques (2026-10-26)

- **Database:** build a new, sanitized database (`MPP_MES_Demo`) and **temporarily repoint the
  shared Dev gateway's `MPP` connection** at it for the capture session, then point it back to
  `MPP_MES_Dev`.
- **HTML demo:** **real screens, live data** -- keep the live simulation, tours and scene hooks,
  but every screen is rebuilt from the captured Perspective DOM and the gateway's own stylesheet,
  with the simulation filling in the numbers, rows and LOT numbers.

Answered after the builder check (2026-10-26):

- **App version:** capture `jacques/working` **as it runs on the Dev gateway now**, untrimmed. Newer
  elements (super-lot chips/tabs, controlled-run and hold navigation) appear as they are; the kit
  still makes no per-feature production claim, so nothing on screen needs removing.
- **Interaction:** **tours plus key actions.** Every tour step works, and so do the actions the
  tours talk about -- PIN pad, supervisor approval, open / release basket, scrap, trim check-out,
  Machining IN scan, Machining OUT mint, check-in, complete tray, LOT detail tabs, genealogy
  expand / collapse, LOT search. Other controls on the captured screens are visible but inert.
- **Gateway quiet:** nothing running on Dev would write into the demo database or show non-demo
  numbers; telling Jacques before and after the switch is enough. No timers are changed.

## 3. Goals, non-goals, anti-goals

**Goals**
- Every deck screenshot is a capture of the real MPP application showing sample-plant data.
- Every demo screen is the real application's markup and styling, alive with simulated data.
- The walk follows the existing tours: core (PIN sign-in, protected action), module 1
  (traceability), module 2 (casting), module 3 (line flow).

**Non-goals**
- No change to the MPP application itself (views, scripts, SQL) to make captures easier.
- No change to `MPP_MES_Dev` or prod. `MPP_MES_Demo` is new and disposable.
- Modules 4-7 stay "available on request".

**Anti-goals**
- Anything MPP-, Honda- or Madison-identifying in the kit -- now harder, because real screens
  carry real labels (section 7).
- Leaving the shared gateway pointed at the demo database, or touching the `MPP_Prod` connection.
- A demo that becomes a frozen slideshow: the live simulation must survive the restyle.

## 4. The sanitized database (`MPP_MES_Demo`)

- Built with the repo's own migrations, so the schema is exactly what the application expects.
  `Reset-DevDatabase.ps1 -DatabaseName MPP_MES_Demo -SkipDemoSeed` is the starting point; the
  MPP-specific seed files it loads (`011` plant locations, `012` terminals, `020` items, `028` AIM
  pool, `029` routes, `032` label templates, `033` cutover destinations, and any others found to
  carry real data) are **replaced** by a demo seed set, not loaded and then edited.
- **Demo seed set** (new, under `sql/seeds_demo/`, never loaded into Dev or prod): the sample plant
  of the first kit -- "Sample Components Plant"; die cast area with presses P-01..P-03 and dies
  D-210 (two cavities), D-220 (family die: CVR-220 a/b + BRK-230 a/b), D-240; a trim area; the
  housing line (Machining IN, Machining OUT, Assembly OUT) and the cover line (Machining IN,
  Assembly OUT, no Machining OUT); items, routes, BOMs and line eligibility exactly as the demo's
  `config.js`; operators with the demo PINs; supervisors; terminals registered so the browser used
  for capture resolves to the right station (loopback normalisation per `ufn_NormalizeIpAddress`).
  Code tables and operation templates are reused from the migrations where they are generic.
- **Production history** is created by running the application's own stored procedures in a
  scenario script (open baskets, shots, release, trim, Machining IN pick, Machining OUT mint,
  check-in of purchased parts, assembly trays, containers, scrap, a shift with a variance) -- the
  same procs the screens call, so every row is real. Not raw INSERTs.
- **Sanitized gate before any capture:** every text column in `MPP_MES_Demo` is dumped and run
  through `tools/sales-kit/check_terms.py`; zero hits required.

## 5. The gateway switch

- The `MPP` connection's target is one setting: `connectionProps = databaseName=MPP_MES_Dev` in
  `<Ignition>/data/config/resources/core/ignition/database-connection/MPP/config.json`. The switch
  changes it to `MPP_MES_Demo` (via the gateway's web UI or that file plus a config reload --
  builder confirms which the gateway honours), and the switch back restores it exactly.
- Before the switch: tell Jacques, record the original value, confirm the `ignition` SQL login
  can read and execute in `MPP_MES_Demo`. After the switch back: confirm on the gateway status
  page that `MPP` is Valid and a known Dev query returns Dev data.
- The switch-back is done the same session as the switch, and is the last step of the capture
  phase even if a capture fails. `MPP_Prod` is never opened or edited.

## 6. Capture

- Drive the real `MPP` Perspective project in the built-in browser
  (`http://localhost:8088/data/perspective/client/MPP/...`), screen by screen, along the tours.
  State changes go through the scenario script's procs (the built-in browser cannot commit
  Perspective input bindings reliably); the browser is used to **show** each state and, where the
  interaction works, to perform it.
- For each step capture, as the 2026-10-22 walkthrough did: the rendered DOM of the page, the full
  stylesheet set the gateway served (Perspective base CSS, theme, the Core and MPP project
  stylesheets), the icon sprite(s) and fonts it references, and the viewport size.
- Deck PNGs are rendered from those captures in headless Chrome at 1904x882 (same pipeline as
  now), so screenshot and HTML come from the same capture.
- Text replacements for anonymization are applied to the captures (section 7), never to the
  application.

## 7. Anonymization of real screens

Real screens carry labels the first kit never had. A substitution list, kept **in the MPP repo**
(it names the customer), is applied to every capture and checked by `check_terms.py`:
- product/brand text in the app header ("MPP MES" -> "MES Track & Trace"), any Madison/Honda/AIM
  wording (field help, tiles, Honda audit text), "LTT" -> "LOT ticket", template codes, real
  location names that migrations themselves seed;
- anything else `check_terms.py` finds in a capture is added to the list, never waved through.
The kit itself contains only replaced text. Fonts, icons and CSS are inlined so the demo still
makes no external request.

## 8. Rebuilding the demo on real screens

- Keep `model.js`, `sim.js`, tests, tours, scene hooks, CONFIG.
- Each demo view becomes the captured DOM of the matching real screen, served with the captured
  stylesheet; its live regions (counts, rows, LOT numbers, status pills, banners) are filled from
  the simulation through small template functions cut from the captured markup.
- The demo's own invented screens are replaced by the real ones: the Plant overview becomes the
  real Supervisor Dashboard (or the real landing page); the trace report becomes the real LOT
  Detail report view; Trim, reconciliation, LOT search, LOT detail, genealogy, Machining IN/OUT,
  line inventory, assembly, the PIN pad and the elevation modal are their real counterparts.
- The tour drawer, welcome menu, SAMPLE PROJECT chip and CTA stay as the demo's own chrome around
  the real screens (they are not part of the application).
- Size: captured Perspective markup is verbose (~100 KB a screen). The single file may grow to a
  few MB; that is accepted (limit 16 MB). Repeated rows are templated, not stored N times.

## 9. Deck

Same 27-slide structure and checks. Every tour slide's screenshot is replaced by the real-screen
capture; slide titles and captions are re-read against what the real screen shows and adjusted
where they describe something the real screen does not. Render, contact sheets, `check_deck.py`,
`validate.py`, PowerPoint link check, `check_terms.py` -- as before.

## 10. Verification

- Sanitized gate on the database (section 4) and on every capture (section 7): zero hits.
- Gateway restored to `MPP_MES_Dev`, confirmed.
- Demo: the first kit's full verification list (tests, all tours at 1x/10x with RESET, viewports,
  iframe, `file://`, zero console errors, zero network requests).
- Side-by-side check per screen: real capture vs. demo screen at the same step look the same.

## 11. Calls made by the designer (from the builder check)

- **Number formats:** the real application's LOT and container number formats win; `config.js`
  and the simulation adopt them so captures and demo agree. Fields the simulation does not model
  (UOM, template, hold columns) carry fixed, plausible sample values from the demo database.
- **SubAssembly routes end at Assembly OUT** (as `config.js` has them), not the single
  `MachiningOut` step of `029_seed_item_routes.sql`. CLAUDE.md names this shape as the fix for the
  known wart where a minted SubAssembly reappears in the Machining OUT pick-list, so the sales
  captures do not show that defect. Route legality (ConsumeMint last) still holds.
- **Raw captures** (before substitution) live in a gitignored folder in the MPP repo
  (`tools/sales-kit/captures/`); only substituted captures enter the kit.
- **Theme:** the demo's own chrome follows whatever theme the real application renders.

## 12. Left to the builder

The exact scenario script; which seeds are MPP-specific beyond those named; how live regions are
templated; capture tooling details; whether the Supervisor Dashboard or the landing page replaces
the Plant overview.
