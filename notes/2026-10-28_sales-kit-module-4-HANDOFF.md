# Sales-kit module 4 (Quality & containment) -- handoff, 2026-10-28 (updated 2026-10-29)

Written so a fresh Claude session (another account, no memory of this one) can carry on from the
two repos alone. Nothing below is in auto-memory or a session scratchpad.

## Read first, in this order

1. `notes/2026-10-26_mes-sales-kit-SOURCE.md` -- what the kit is, where it lives, the anonymization rules, build record.
2. `docs/superpowers/specs/2026-10-27-mes-sales-kit-module-4-quality-design.md` -- the approved design (the authority).
3. `docs/superpowers/plans/2026-10-27-mes-sales-kit-module-4-quality.md` -- the approved plan, 10 tasks.
4. `notes/2026-10-27_super-lot-refusal-facts.md` -- fact sheet F1..F49. Every refusal / tagging claim in the kit cites a row.
5. This note -- what is done, the decisions taken while building, and exactly where to resume.
6. `notes/2026-10-27_super-lot-gateway-walk-bugs.md` -- bug log for the capture session (header written, no bugs yet).

Execution method Jacques chose: **native** (one session implements every task, TDD per task, then
ONE fresh review of the whole work on the most capable model at the end). Skills used:
`superpowers:executing-plans` + `superpowers:test-driven-development`.

## Where things are

| What | Where |
|---|---|
| MPP repo | `C:\Users\JacquesPotgieter\Documents\Dev\MPP`, branch `jacques/working` (commit there; explicit paths only; no Co-Authored-By) |
| Kit repo (own git, no remote) | `C:\Users\JacquesPotgieter\Documents\Dev\Marketing\MES Track & Trace\` |
| Demo database | `MPP_MES_Demo` on `localhost` (currently built WITH the quality scenario) |
| Raw captures (gitignored) | `MPP\tools\sales-kit\captures\` -- module 4 goes in `captures\m4\` |
| Term lists (MPP repo only, never into the kit) | `MPP\tools\sales-kit\substitutions.json`, `banned_terms.txt` |

## Status by task

| Task | State | Commits |
|---|---|---|
| 1 Fact sheet | done | MPP `816e08d..2fcc735` |
| 2 Quality scenario (`sql/seeds_demo/opt/060_demo_quality_scenario.sql`, `verify_demo_quality.sql`, `Build-DemoDatabase.ps1 -WithQualityScenario`, `Set-QualityAdAccount.ps1`) | done; both builds (with / without the switch) pass | MPP `2fcc735..d9160a0` |
| 3 Headed capture + password safety (`capture.js`, `sanitize.py`, `test_capture_password.js`) | done | MPP `d9160a0..01a655f` |
| 4 Module 4 steps (`tools/sales-kit/capture/steps_m4.js`, 29 steps, 10 sign-in pauses) | done | MPP `01a655f..65e37f7` |
| 5 PDF sanitizer (`sanitize_pdf.py` + 6 tests) | done | MPP `65e37f7..433d3bf` |
| 8 Demo model (holds, tags, super-lots) | done, 50/50 tests (37 old + 13 new) -- done before 6 on purpose | KIT `56472f9..92158cb` |
| 6 Capture session (gateway walk) | done 2026-10-29: 23 captures in the kit, bug log written, gateway back on Dev (checked) | MPP `924469a`, KIT `e464f8d` |
| 7 Deck module 4 | done: 4 slides + menu tile live; `check_deck.py` 14/14, `validate.py` passes, kit gate 0 hits | KIT `9eb207e` |
| 9 Demo module 4 views + tour | done 2026-10-29: super-lot page, Hold Management, dock, refusals, 9-step tour; 50/50 tests, all five tours pass at 3 viewports + iframe, 0 errors, 0 outside requests | KIT `5bc4e2f` |
| **10 Verify, document, final review** | **not started -- resume here** | -- |

## Resume here: Task 10 (verify, document, review)

Follow the plan's Task 10. Task 9 is built and checked; its rulings are below. Still open from the plan:
`KIT/README.md` and the SOURCE note's module 4 section, the claim-by-claim walk of every module 4 caption /
note / tour step against its capture and fact id, deleting `KIT/MES Track & Trace - MPP.pptx` (PowerPoint
held it on 2026-10-29), and the whole-work review on the most capable model.

Verification scripts: `KIT/tools/verify_demo.js` (now runs the m4 tour too) and a deeper m4 check kept
in the session scratchpad (refusal wording, release frees the LOT, 10x with RESET, a form open across ticks) --
its checks are listed in the Task 9 commit message if it needs rebuilding.

## Rulings taken 2026-10-29 (Task 9)

- **No "View the report".** There is no Super-lot PDF (BUG-1); Print report on the super-lot page says the PDF
  is part of the live engineer demo.
- **Tour step 4 is "Assembly carries the tag onto the tray"**, not "Assembly refuses" (F23/F24): the tour builds a
  tray from a tagged machined part and the toast says the tray carries the tag and joins the super-lot.
- **LOT Detail's Super-lots tab opens the super-lot page** for that LOT's run rather than mounting the captured
  tab; the CRT / super-lot / on-hold pills already in the m1 capture are shown and filled.
- **Tour step 8** releases every READY member and ends the window (F46: release and ending the window are
  separate; the tour does both and says so). The casting refused at step 3 is picked at Machining IN.
- **The demo shows the signature card un-clipped** (BUG-2 lives in the application; the demo lets the card grow).
- **Build embeds only captures the code names**, so deck-only m4 captures stay out: demo 5.6 MB (was 2.6 MB before
  module 4). Most of the growth is the four super-lot page captures (~0.9 MB each, the per-member scrap-reason
  grids); trimming those bodies at build time would roughly halve it if size matters.
- Fixed in passing: the model logs a super-lot release with kind `Released`, the same kind as a basket release;
  LOT Detail history now tells them apart.

## (Done) Task 9 brief -- captures available

Captures available in `KIT\demo-build\captures\` (all sanitized, same `bundle.css` as modules 1-3, so
no second bundle): `m4-superlot-list`, `-members` (1904x1100), `-history`, `-results` (1100),
`-results-saved` (1100), `m4-wizard-preview`, `m4-holds`, `m4-lot-held`, `m4-lot-member`,
`-superlots-tab`, `-member-history`, `m4-lot-released-history` (1904x1400), `m4-genealogy`, `m4-trace`,
`m4-dashboard`, `m4-refuse-machining-in`, `-in-hold`, `-machining-out`, `m4-refuse-dock`, `m4-repack`,
`m4-deviation`, `m4-signoff-release`, `m4-history-after` (1100). Not captured: the label, the
Super-lot PDF (BUG-1), the Assembly check-in refusal, Config Tool specs, the CRT clear, and a usable
Sign-off-after-release (`m4-signoff-done` was removed: it caught the page deselected). The demo's
"View the report" action and its sign-off-after-release state therefore have no capture to mount --
draw them from the `m4-signoff-release` / `m4-history-after` captures or leave them out (rule it).

## Rulings taken 2026-10-29 (capture session and Task 7)

- Jacques (2026-10-29): this gateway is a test bed; the builder signs in itself with the test
  logins he gave in chat (never written to a file). The "Active Directory" user source here is an
  INTERNAL test source; the presenter login `admin1` is in `banned_terms.txt` / `substitutions.json`
  (-> `quality.sample`). The Config Tool's own login (default IdP) does not know `admin1`.
- The deck's last module 4 slide shows LOT Detail's Super-lots tab + the genealogy, not the PDF
  (BUG-1). Slide 2 (refusals) shows Machining IN tagged / held, Machining OUT and the dock; Assembly
  is described in the notes as "carries the tag onto the tray" (F23/F24). Slide 3 uses the release
  popup, not the after-release Sign-off tab.
- The dock's refusal (F12) does not name the super-lot; the deck says "a station's refusal names the
  super-lot", which is true for F2 / F4.
- The Sign-off tab's own banner ("Any network account registered in the MES can sign today...") is
  visible in the capture; the notes answer "who can sign" from it (F47). Not a live claim.
- `check_deck.py`'s continuous-wording regex held literal backspace characters and never matched;
  fixed with the new checks.

## (Done) Task 6 as it was briefed

Already true: `MPP_MES_Demo` is built with `-WithQualityScenario` (rebuild if in doubt:
`.\tools\sales-kit\demo-db\Build-DemoDatabase.ps1 -WithQualityScenario`, expect 46 PASS and
"MPP_MES_Demo built, sanitized and verified."). The sample Quality user `EN` (E. Novak, PIN 61030)
has `AdAccount = quality.sample`.

1. (done) Ask Jacques to: reset the Perspective trial; switch the gateway's `MPP` connection to
   `MPP_MES_Demo` (he does it himself); tell you the AD login he will sign in with.
2. Add that login to `banned_terms.txt` (word pattern) and `substitutions.json` (-> `quality.sample`),
   then `.\tools\sales-kit\demo-db\Set-QualityAdAccount.ps1 -Login <it>`; `.\tools\sales-kit\demo-db\Check-GatewayDb.ps1 -Expect Demo` -> PASS.
3. **Elevation precondition** (bug-log header): `BlueRidge.Location.AppUser.elevate` checks the
   password against an Ignition user source named **"Active Directory"**, then needs the typed
   account to equal `AppUser.AdAccount` exactly. If that user source does not exist on this gateway,
   sign-in fails -- log it as the first finding and ask Jacques how he wants to proceed.
4. In a terminal tab Jacques can see (he presses Enter there at each pause), from `tools\sales-kit\capture`:
   `node capture.js --headed --steps-file steps_m4.js --steps all --out ..\captures\m4`
   At each `>>> SIGN-IN` pause, tell Jacques in chat which step it is and what to do (the prompt text
   is in `steps_m4.js`). **Never type, store or log a password.** Re-run single steps with
   `--steps <name>`; adjust a step's actions live (labels in `steps_m4.js` came from the view JSON and
   were never driven -- expect some to need tweaking). Bugs -> the bug log, never fix the app.
5. Then follow the plan's Task 6 steps 4-10 (save the Super-lot PDF, Jacques switches back + `-Expect Dev`
   PASS, `sanitize.py`, `sanitize_pdf.py`, bug-log walked/not-walked lists, kit gate, commits).
   Known substitution to add after capture: the Deviation popup label **"MPP reference (optional)"**.

Then Tasks 7, 9, 10 as written in the plan, applying the rulings below.

## Rulings taken while building (decisions made on Jacques's behalf -- carry them forward)

The plan's ledger lives in the gitignored `.superpowers/sdd/2026-10-27-mes-sales-kit-module-4-quality/progress.md`;
it is copied here in full because that folder does not travel.

- **T1:** the procs differ from the plan's assumptions; T8/T9 follow the fact sheet: Rework is not
  an outcome (F40 -- it is a move back to trim); release covers the *ticked* members (F44); release
  does not end the window or close the run (F46); `Assembly_CompleteTray` tags the tray instead of
  refusing (F23) -- only Assembly *scan-in* refuses (F6). Kit wording: assembly "carries the tag onto
  the tray", never "Assembly refuses it". Cost if wrong: demo rework.
- **T2:** base verifies run BEFORE the opt seed (seeds -> sanitize -> base verifies -> opt seed ->
  sanitize -> quality verify -> gate); `verify_demo_scenario.sql` asserts no ControlledRun/HoldEvent
  unconditionally. 060 changes state the base verifies check.
- **T2:** super-lot window names part HSG-410 and **no line** -- auto-join arm 4 matches only a line
  at/above the minting terminal, so naming L-1 would never tag a new die-cast basket. The kit says
  "part" where the spec said "part / line".
- **T2:** problem LOT = `520100004` (hard Hold, waiting for Machining IN); born-from-tagged-input =
  the FG-4100 tray, because Machining OUT refuses a tagged source (F4). Born-tagged basket = `520100009`.
- **T3:** the "old headless path still works" check could not run while the gateway is on Dev (the
  committed capture.js fails identically: on Dev this machine's IP is a registered terminal). The
  first headless step on `MPP_MES_Demo` in Task 6 is the real check.
- **T4:** steps resolve names / ids / the pulled-back container's label from `MPP_MES_Demo` via
  sqlcmd at load; `m4-refuse-move` dropped (F8 reads like F6); added `m4-history-after` and
  `m4-lot-released-history`; `m4-refuse-assembly` hands the scan to Jacques.
- **T5:** rewrite is per text LINE (date and time often sit in separate spans); the unmatched-term
  test uses "Flexware"; the font-name rule is unit-tested via `font_problems()`.
- **T6:** Task 8 ran before Task 6 so Jacques is called once.
- **T8:** model API follows the fact sheet: `recordResult(st, run, memberId, outcome, qty, who)` with
  outcomes `Accepted | Scrap | ReturnToSupplier | UseAsIs`; `releaseSuperLot(st, run, memberIds, who)`;
  `endWindow`, `closeSuperLot` added; `raiseDeviation(st, run, reason, who)` (no memberId, F43);
  container members are `'C' + containerId`; trays built from tagged parts are tagged and listed.
  F6 (Assembly scan-in) is not modelled -- the demo has no scan-in.
- **T8:** FIFO at Machining IN = oldest UNBLOCKED LOT; held/tagged LOTs stay in `lineQueue` (F30)
  and the sim skips them.
- **T8:** demo selection = anchor + `traceForward` (open LOTs + unshipped containers) + open LOTs of
  the anchor's part made since; part-only window, like 060.

## Machine-specific things a new account must find again

- **pptx skill scripts** (deck build and validation) live under the Claude account's skill install,
  so the path changes with the account. Find them with:
  `find /c/Users/JacquesPotgieter/AppData/Local/Claude-Data -name apply_theme.js` (and `validate.py`
  under the same `skills/pptx/scripts/office/`). Deck build, in `KIT\deck-build`:
  `APPLY_THEME="<.../skills/pptx/scripts/apply_theme.js>" NODE_PATH="$PWD/node_modules" node build_deck.js`.
  Checks: `python -I deck-build/check_deck.py "<KIT>/MES Track & Trace - Overview.pptx"` and
  `python "<.../skills/pptx/scripts/office/validate.py>" <deck>` (validate.py without `-I`).
- **Demo browser check** is now in the kit: `node tools/verify_demo.js <MPP>\tools\sales-kit\capture\node_modules\puppeteer-core <KIT> <out folder>`.
  Demo tests: in `KIT\demo-build`, `node --test test/*.test.js` (50). Build: `python -I build_demo.py`.
- **superpowers ledger scripts** (`task-start`, `task-done`, `sdd-workspace`) come from the
  superpowers plugin; a new ledger can be started from this note (first line
  `# SDD ledger — plan: docs/superpowers/plans/2026-10-27-mes-sales-kit-module-4-quality.md`, then one
  `Task N: complete` line for each of 1, 2, 3, 4, 5, 8).

## Gotchas learned this session

- Several files are **CRLF** (`capture.js`, `sim.js`, `config.js`): exact-string edits miss; normalise
  `\r\n` -> `\n`, edit, write back with `\r\n`.
- A bare `cat > file` with no heredoc waits on stdin forever and hangs the shell command.
- Python run with `-I` drops the script's own folder from `sys.path`; `sanitize_pdf.py` inserts it.
- Writing a Python string with `\b` inside a non-raw literal stores a backspace character (it broke
  a regex once); use raw strings.
- `MPP_MES_Demo` must always be rebuilt with `Build-DemoDatabase.ps1`; never point a demo script at
  `MPP_MES_Dev` or prod.

## Loose ends outside the plan

- `KIT\MES Track & Trace - MPP.pptx` is a stray copy of the Overview deck (content identical). Delete
  it once PowerPoint no longer holds it (`~$` lock files show it was open). Its file name carries the customer abbreviation, so it must not travel with the kit.
