# Sales-kit module 4 (Quality & containment) -- handoff, 2026-10-28

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
| **6 Capture session with Jacques** | **step 1 done; resume at step 2** | -- |
| 7 Deck module 4 | not started (needs Task 6 captures) | -- |
| 9 Demo module 4 views + tour | not started (needs Task 6 captures + Task 8 API) | -- |
| 10 Verify, document, final review | not started | -- |

## Resume here: Task 6, step 2 (needs Jacques at the gateway)

Already true: `MPP_MES_Demo` is built with `-WithQualityScenario` (rebuild if in doubt:
`.\tools\sales-kit\demo-db\Build-DemoDatabase.ps1 -WithQualityScenario`, expect 46 PASS and
"MPP_MES_Demo built, sanitized and verified."). The sample Quality user `EN` (E. Novak, PIN 61030)
has `AdAccount = quality.sample`.

1. Ask Jacques to: reset the Perspective trial; switch the gateway's `MPP` connection to
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
