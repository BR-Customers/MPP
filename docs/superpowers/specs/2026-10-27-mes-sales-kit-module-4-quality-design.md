# MES sales kit -- module 4, Quality & containment (design)

**Date:** 2026-10-27
**Status:** Draft for Jacques's review (maturity decided; target deck file open, section 9)
**Builds on:** `docs/superpowers/specs/2026-10-22-mes-sales-kit-design.md` (the kit) and
`docs/superpowers/specs/2026-10-26-mes-sales-kit-real-screens-design.md` (real screens, the sample
plant database `MPP_MES_Demo`, the capture and sanitize pipeline). Everything in those stays in
force except what this document changes.
**Kit:** `C:\Users\JacquesPotgieter\Documents\Dev\Marketing\MES Track & Trace\`.
**The feature it shows:** the controlled run / super-lot and nonconformance work, pieces 1-6 --
`notes/2026-10-12_crt-super-lot-and-nonconformance-overview.md` and the six
`docs/superpowers/specs/2026-10-12-controlled-run-*.md` specs (each ends with build notes).

## 1. Why

Modules 1-3 of the kit show the plant making and tracing parts. Menu tile 04, "Quality &
containment", is "available on request". Jacques wants it built next, because it answers the
question a quality-minded prospect actually asks: **does the system practically prevent bad parts
from making it through production** -- not just record that they were bad?

So module 4 is built around refusals. Held or suspect material cannot be consumed, moved into
production, packed or shipped until Quality clears it, and every step of finding, containing,
inspecting and releasing it leaves a signed record.

A second purpose: most of the super-lot screens have **never been rendered on a gateway** (pieces
2-6 were SQL-tested; the screens after a Quality sign-in, the Repack popup and the Genealogy /
Trace markers were never driven). Capturing them for the kit is also their first walk, and the bugs
it turns up are logged for another agent to fix (section 7).

## 2. Decisions taken with Jacques (2026-10-27)

- **Story:** the prospect's takeaway is prevention. Holds and controlled-run tags block every route
  out; Quality inspects, dispositions and signs; the record follows the part.
- **Hero screen:** the super-lot page (`/shop-floor/controlled-runs`), the screen Quality runs this
  from. Jacques: "quality management".
- **Quality checks are supporting, not leading.** Per-part quality specs (Config Tool, `Quality/QualitySpecs`)
  and `ShopFloor/InspectionEntry` are Quality's own checks, not a production step. One mention in
  the module, never a tour headline.
- **The "from this time forward" concept is central:** a super-lot with auto-join on tags every new
  LOT of its part and line as it is made, until Quality closes the window. The 200% inspection is
  not forced by the system; release confirms it was done.
- **Sign-ins are done by Jacques, live.** Wherever a step needs a username and password, the builder
  stops, flags Jacques, and he types it. What follows is then captured. Doing these through the real
  UI (not in the scenario script) means the signed paths are walked for real.
- **Bugs are logged, not fixed** in the capture session (section 7).
- **Reports:** the Super-lot PDF report is rendered on the gateway against the sample plant, saved,
  and sanitized as a PDF (section 8). Same treatment is then open to the Reports page dropped from
  modules 1-3.
- **Deck:** four slides plus the menu tile made live. **Demo:** a module 4 section with live views
  and a guided tour. Same build as modules 1-3.

## 3. Goals, non-goals, anti-goals

**Goals**
- Four deck slides and a demo module whose every screen is a real capture on the sample plant.
- The tour lets the prospect try to push suspect material through and watch it refused.
- Every super-lot screen the module uses has been rendered and exercised on the gateway at least
  once, with a bug log of what did not work.

**Non-goals**
- No change to the MPP application (views, scripts, SQL) during this work -- not even to fix a bug
  the walk finds. Bugs go to the log.
- No change to `MPP_MES_Dev` or prod. Only `MPP_MES_Demo` is written.
- Modules 5-7 stay "available on request".
- Quality specs / inspection entry are not given their own tour.

**Anti-goals**
- Claiming the super-lot feature is live at a customer (section 10, maturity).
- Any MPP / Honda / Madison / AIM text, any real person's name or login, any date in the kit.
- A refusal shown in the kit that the application does not actually make. Every "refused" claim is
  captured from the real screen or traced to the proc that refuses it.
- Leaving the gateway pointed at the demo database.

## 4. The story, beat by beat

| # | Beat | Where it is shown (real screen) |
|---|---|---|
| 1 | **Define** -- Quality's checks are built per part, versioned. | Config Tool Quality Specs (one deck mention / notes) |
| 2 | **Detect** -- a problem is found on one casting LOT. | LOT Detail (hard Hold placed) / Hold Management |
| 3 | **Contain** -- Quality opens a super-lot from it: everything made from that LOT and that part / line since, auto-join on. | New super-lot wizard, super-lot page Members tab, super-lot label |
| 4 | **Catch new production** -- baskets made after the window opened join the run and are born tagged; anything made from a tagged input is born tagged. | Members tab growing; LOT Detail CRT pill + run chip |
| 5 | **Pull back finished stock** -- completed containers in the warehouse join the run. | Members tab ("Pulled back from finished stock") |
| 6 | **Prevent** -- every route out refuses: Machining IN pick, Machining OUT mint, Assembly check-in, a move to a production location, the shipping dock. Each refusal names the super-lot. | The station screens with their refusal message |
| 7 | **Inspect & disposition** -- per member: good, scrap, rework at trim, return to vendor; a container repacked with a new serial. | Results tab, Repack popup |
| 8 | **Sign** -- signed release confirming the 200% inspection; a Use-As-Is deviation (the nonconformance) signed separately. | Sign-off tab, release popup, deviation popup |
| 9 | **The record follows the part** -- LOT history, super-lot chip and tab, genealogy and trace markers, dashboard tile, Super-lot PDF report. | LOT Detail, Genealogy Viewer, Global Trace, Supervisor Dashboard, report PDF |

Beat 6 is the climax of both the deck and the demo tour.

**Refusal facts the builder confirms against the procs before writing any slide or tour text**
(from `notes/2026-10-12_...overview.md` section 4; the 2026-07-24 consume-hold-guard spec):
hard Hold blocks every move / advance / consume through `Lot_AssertNotBlocked` and the inline
guards; CRT blocks production-destination moves (`ufn_CrtBlocksMoveTo`), advance
(`ufn_CrtBlocksAdvance`), `Assembly_ScanIn`, `MachiningIn_RecordPick`, `MachiningOut_Mint` (scan),
split / merge; `Container_Ship` refuses a held container and a container with a CRT tray LOT;
`AimShipperIdPool_ListUnposted` holds the shipper ID back. **What `Assembly_CompleteTray` does with
a CRT input (refuse, or consume and mint a CRT finished good) is checked in the proc, and the kit
says exactly that.** Line scrap by part spreading across CRT and clean LOTs is a known open
question -- not shown.

## 5. Scenario data (`MPP_MES_Demo`)

A new seed `sql/seeds_demo/060_demo_quality_scenario.sql`, run after `050`, through the
application's procs only (as `050` does), ASCII-only, each call checking its status row:

- One casting LOT from the existing shift is the "problem" LOT; a **hard Hold** is placed on it.
- A super-lot is opened (reason in sample wording, e.g. "Porosity found at customer"), members
  picked by genealogy from that LOT plus part / line since a time, **auto-join on**.
- More production is then run through the procs so new baskets join by auto-join, and at least one
  machined part / finished good is minted from a tagged input (born tagged).
- At least one **completed container** joins (pulled back), and one container goes to Repack state
  if the capture order needs it before Jacques's sign-in.
- A **received-origin LOT** exists among the members, so Return to vendor is offered.
- Some results are recorded by the script; the rest are left for the live session.

Steps that need a Quality sign-in are **not** done in the script when the capture should show them
being done in the UI (section 6). Anything that only sets up state may use the procs directly
(`@AppUserId` = the sample Quality user).

**The Quality user.** Elevation authenticates an AD login and resolves it to an `AppUser` by
`AdAccount`. The demo database gets a sample Quality user (sample name and initials) whose
`AdAccount` is Jacques's login, added at session time, so his sign-in resolves to the sample name
and the signature records show the sample name. Jacques's login is added to the MPP repo's
`substitutions.json` / `banned_terms.txt` so it can never reach the kit. Builder confirms on the
gateway which user source elevation uses before the session.

`Build-DemoDatabase.ps1` gains the new seed; the text-dump gate runs over it as before.

## 6. Capture session

Same pipeline as modules 1-3 (`tools/sales-kit/capture/capture.js` + `steps.js`, `sanitize.py`,
headless-Chrome PNGs). Jacques switches the gateway's `MPP` connection to `MPP_MES_Demo` and back
the same session, as last time (`Check-GatewayDb.ps1`).

Capture list (names prefixed `m4-`), in scenario order:
- the super-lot list and page: Members (open, auto-join on, growing), Results, Sign-off, History;
- the New super-lot wizard (at least the preview step) and the super-lot label;
- the refusals, one capture each, at Machining IN, Machining OUT, Assembly check-in and the
  shipping dock (and a validated move if it reads differently);
- Hold Management and LOT Detail with a hard Hold;
- LOT Detail of a member: CRT pill, super-lot chip, Super-lots tab, History tab;
- Genealogy Viewer and Global Trace with super-lot markers;
- Supervisor Dashboard with the Open super-lots tile;
- the Repack popup; the release and deviation popups; the Sign-off tab after release;
- Config Tool Quality Specs (for beat 1) -- the `MPP_Config` project, same connection.

**Sign-in steps -- builder stops and flags Jacques** (each listed in the plan with what he will
type into and what happens next): the Quality sign-in that opens the super-lot page's editing
window, Save results, Mark the rest, Sign and release, Sign deviation, Repack, the CRT clear on LOT
Detail, and the New super-lot wizard's last step. Anything the capture browser cannot type (the
built-in browser cannot commit some Perspective inputs) is also handed to Jacques rather than
forced.

## 7. Bug log

`notes/2026-10-27_super-lot-gateway-walk-bugs.md`, written during the session. One entry per bug:
screen and route, the steps from a named scenario state, expected, actual, the `wrapper.log`
excerpt (gateway logs), a screenshot path, and the proc / view it likely lives in. Written so
another agent can pick each up cold. Also listed: what was walked and worked, what could not be
reached and why. A bug that blocks a capture is logged and worked around (different state, or the
beat is dropped from the kit and noted); the session does not stop for it.

## 8. The Super-lot PDF report

- Rendered on the gateway (Reports page, Super-lot report) for the scenario's super-lot and saved
  as the raw PDF in the gitignored `tools/sales-kit/captures/`.
- Sanitized by a new `tools/sales-kit/capture/sanitize_pdf.py`: every text span is run through the
  same `substitutions.json` + date rules as the screens and rewritten in place (redact the span,
  write the replacement in the same font size and position); the document metadata (title, author,
  producer, dates) is rewritten; the result's extracted text goes through `check_terms.py`. If
  customer text is in an image rather than text, that image region is covered with the replacement
  wording. Zero gate hits required.
- The cleaned PDF goes into the kit as a file the demo can open ("View the report") and as a deck
  slide image (page 1 rendered to PNG).

## 9. Deck

- **Target deck file -- OPEN, for Jacques.** The kit's committed deck is `MES Track & Trace -
  Overview.pptx`; on 2026-10-27 the working tree has it deleted and an untracked
  `MES Track & Trace - MPP.pptx` in its place. Which file module 4 goes into is settled before the
  deck task starts. (A kit file name may not contain "MPP" -- the term gate bans it.)
- Four slides after the menu, structured like modules 1-3 and ending with "Back to the menu":
  1. **Suspect material is caught automatically** -- super-lot page, window open, members growing.
  2. **Nothing suspect gets through** -- the refusals side by side, each naming the run.
  3. **Inspect, disposition, sign** -- Results and Sign-off; signed release; Use-As-Is deviation;
     one line on Quality's per-part checks.
  4. **The record follows the part** -- LOT Detail chip and tab, genealogy markers, the PDF.
- Menu tile 04 hyperlinks to its section; its "Available on request" becomes "Click the title to go
  there".
- The add-ons slide drops "controlled runs with e-signed release" (it is now a module).
- `check_deck.py` gains the module 4 slides; `validate.py`, `check_terms.py` as before.

## 10. Maturity

**Decided (Jacques, 2026-10-27): show super-lots in the kit now, with no in-production wording.**
Module 4's slides, captions, notes and tour describe what each screen does, never whether it is
live anywhere. The 2026-10-22 design's line that super-lots are "not shown" is superseded for
module 4 only; modules 1-3 are unchanged. The background that was weighed:

The kit's rule (2026-10-22 design, section 5): "proven in production" is said once, about the
system; feature text describes what a screen does, never whether it is live; **super-lots are named
there as pending and not shown in modules 1-3.** Reuse was cleared for *delivered* features in
anonymized form. The super-lot work is a change order for MPP that is built but **not yet deployed
to MPP's prod** (prod at `0108`; release bundled, not run).


## 10a. Demo

- New views (registered under module `m4`, rail group "Quality & containment"): `super-lots` (the
  super-lot page: Members / Results / Sign-off / History tabs), `holds` (Hold Management),
  refusal states on the existing `machining-in`, `machining-out`, `assembly` views, `shipping`
  (the dock, if captured), and the LOT Detail super-lot chip / tab on the existing `lot-detail`.
- **Model:** `lot.crt` and `lot.hold`; a super-lot `{number, reason, part, line, from, autoJoin,
  members, results, released}`; `newLot` tags a LOT that matches an open auto-join run, and tags any
  LOT minted from a tagged input; the station actions refuse a held or tagged LOT with the
  application's own wording ("... (super-lot CR000001)"). Results per member; release clears tags
  and closes the window; a deviation number `DV000001`. Unit tests for each rule.
- **Tour (m4):** open a super-lot from a casting -> watch the next baskets join -> try Machining IN
  with a tagged LOT (refused) -> Assembly (refused) -> the dock (refused) -> record results ->
  supervisor sign-off (the existing elevation dialog) -> tags clear, the LOT moves again ->
  LOT Detail shows the history.
- Key actions work: open super-lot (short form), the refused scans, recording an outcome, sign and
  release, opening the report PDF. Other controls on the captured screens are inert.
- Welcome menu: tile 04 becomes live.
- Verification as modules 1-3 (tests, tours at 10x with RESET, viewports, iframe, `file://`, zero
  errors, zero requests).

## 11. Anonymization additions

Run numbers (`CR000001`) and deviation numbers (`DV000001`) are the application's formats and stay.
New substitutions as the captures demand (the super-lot label template, the report header, any
"Honda"/"AIM" wording on the dock and the repack serial text); Jacques's AD login (section 5). Date
rule already in `sanitize.py`; the report gets the same rules (section 8).

## 12. Verification

- Database text gate, capture gate and kit gate: zero hits.
- Gateway back on `MPP_MES_Dev`, confirmed.
- Every module 4 slide's claims checked against its capture and the procs (section 4).
- Demo verification list (section 10a); deck checks (section 9).
- Bug log written, with walked / not-walked lists.

## 12a. Calls made by the designer (from the builder check)

- **How Jacques signs in.** `capture.js` today runs headless and reloads per step. For module 4 it
  gains a **headed, continuous-session mode**: one visible Chrome window, steps run in order without
  reloading between steps that share a page, and a step marked `signIn: 'jacques'` pauses the script
  with a console prompt until Jacques has typed his credentials in that window and pressed Enter.
  **Password inputs are never saved:** `capture.js` skips `input[type=password]` when it copies live
  input values, and drops any elevation / login popup still open when a step is saved; `sanitize.py`
  fails a capture that still carries a password-type input with a value. The Config Tool
  (`MPP_Config`, AD login) is on the sign-in list.
- **Modules 1-3 stay as captured.** `060` is opt-in (`Build-DemoDatabase.ps1 -WithQualityScenario`)
  so modules 1-3 can still be recaptured without CRT pills, hold banners or super-lot chips; the
  problem LOT is one no module 1-3 step shows (not LOT 1 or 28). Module 1-3 captures are not redone.
- **Demo state:** the m4 super-lot exists only once the m4 tour or the "open super-lot" action
  creates it; RESET clears it. A tagged LOT then shows its tag on the other modules' screens too
  (that is what the application does).
- **Reports page for modules 1-3:** not in this plan. The PDF sanitizer built here makes it a small
  follow-on.

## 13. Left to the builder

The exact scenario script and its capture order; which refusals read differently enough to merit
their own capture; how the demo templates the super-lot page's accordion rows; the capture-tool
details for the PDF and the Config Tool project.
