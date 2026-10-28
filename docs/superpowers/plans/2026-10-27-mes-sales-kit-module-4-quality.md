# MES Sales Kit -- Module 4, Quality & Containment Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add module 4, "Quality & containment", to the MES Track & Trace kit (four deck slides, a live demo module with a tour) on real screens captured from the super-lot feature against the sample plant, and log every bug that first gateway walk turns up.

**Architecture:** An opt-in seed (`060`) puts a hold, an open auto-join super-lot and its members into `MPP_MES_Demo` through the procs. `capture.js` gets a headed, continuous-session mode that pauses wherever Jacques must sign in. The captures and a saved Super-lot PDF go through the existing sanitizer and a new PDF sanitizer. The kit's deck gains a fourth module in `build_deck.js`. The demo's model learns holds, tags and super-lots, and a new `m4.js` mounts the captures. Every refusal the kit claims is first written into a fact sheet traced to the proc that makes it.

**Tech Stack:** SQL Server 2022 + sqlcmd; PowerShell; Node 24 + `puppeteer-core` driving the installed Chrome; Python 3.14 + PyMuPDF 1.28 (`import pymupdf`); the kit's vanilla-JS demo build (`build_demo.py`, `node --test`) and its pptxgenjs deck (`build_deck.js`, `check_deck.py`).

> **Progress (2026-10-28):** Tasks 1-5 and 8 are done; resume at Task 6 step 2 (capture session with Jacques). State, rulings taken while building, and machine-specific paths: `notes/2026-10-28_sales-kit-module-4-HANDOFF.md`. Read it before continuing.

**Spec:** `docs/superpowers/specs/2026-10-27-mes-sales-kit-module-4-quality-design.md`. Read it first, together with its parents: `2026-10-26-mes-sales-kit-real-screens-design.md` and `2026-10-22-mes-sales-kit-design.md`. The super-lot feature itself is described in `notes/2026-10-12_crt-super-lot-and-nonconformance-overview.md`.

## Global Constraints

- **Paths.**
  - `MPP` = the repo root.
  - `KIT` = `C:\Users\JacquesPotgieter\Documents\Dev\Marketing\MES Track & Trace\` (its own git repo).
  - `CAP` = `MPP\tools\sales-kit\captures\` (gitignored). Use a new run folder, `CAP\m4\`.
- **Databases.** Only `MPP_MES_Demo` is written.
  - Never drop, reseed or edit `MPP_MES_Dev`, and never open the `MPP_Prod` connection.
  - Demo SQL files carry no `USE` statement; `Build-DemoDatabase.ps1` refuses one. Grep any script for `USE ` before running it.
- **No MPP application change.** No views, scripts, named queries or procs change, not even to fix a bug the walk finds. Bugs go to the bug log (Task 6).
- **Gateway.**
  - Jacques switches the gateway's `MPP` connection to `MPP_MES_Demo` himself, and back again in the same session, even after a failure.
  - Confirm with `tools\sales-kit\demo-db\Check-GatewayDb.ps1 -Expect Demo` / `-Expect Dev`.
- **Sign-ins.** At every username/password step the builder stops and flags Jacques, and Jacques types the credentials.
  - The builder never types, stores or logs a password.
  - Password inputs are never saved in a capture.
- **Kit wording.**
  - No MPP, Honda, Madison or AIM text, no real person's name or login, and no dates, timelines, prices or PLC brands.
  - "Proven in production at a manufacturer" appears once in the deck, about the whole system.
  - Module 4 text describes what a screen does, never whether it is live anywhere: no "in production", "deployed", "live at" or "running at".
  - Run numbers `CR000001` and deviation numbers `DV000001` are the application's formats and stay.
- **Every refusal the kit claims** comes from the fact sheet (Task 1). That covers a deck caption, a note, a tour step and a demo error message, and each one is traced to the proc and message that make it.
- **ASCII-only** strings in seed SQL. Byte-scan `060` before applying it.
- **Zero hits** from `python -I tools/sales-kit/check_terms.py` on the demo DB text dump, on `KIT\demo-build\captures`, on the cleaned PDF's extracted text, and on the whole `KIT` folder. Run it on its own, never piped.
- **Modules 1-3 are not recaptured.** `060` is opt-in. Existing `steps.js` steps and the existing `captures/*.json` are not changed.
- **Git.**
  - MPP: commit on `jacques/working`, stage explicit paths only, no Co-Authored-By trailer.
  - KIT: commit in its own repo.
  - `substitutions.json` and `banned_terms.txt` are committed in MPP and never copied into KIT.

## Review Focus

These are the five failure modes most likely to bite. Each line names the task whose test pins it.

1. **A password in a capture or a log.** Jacques types into a login popup that is still open when a step is saved, or a `value=` is copied off a password input. Pinned in Task 3:
   - `test_capture_password.js` types into a password field and asserts the snapshot does not contain the text.
   - `test_sanitize.py::test_fails_on_password_value` covers the sanitizer side.
2. **The gateway left on the demo database** after a failed or abandoned capture. Pinned in Task 6: the switch-back steps run in a `finally` order, and `Check-GatewayDb.ps1 -Expect Dev` must print PASS before the task is complete.
3. **A refusal shown in the kit that the application does not make.** Example: the demo refuses an Assembly tray built from a tagged input when the proc actually mints a tagged finished good. Pinned in Task 8: `model.quality.test.js` asserts each refusal and each tag inheritance exactly as the fact sheet records it, and the fact sheet's rows are cited in the test names.
4. **Super-lot state leaking into modules 1-3**, either in the database or in the demo. Pinned in two places:
   - Task 2: `Build-DemoDatabase.ps1` without `-WithQualityScenario` leaves `Quality.ControlledRun` and `Quality.Hold` empty (asserted in `verify_demo_scenario.sql`).
   - Task 8: a fresh demo state with no super-lot opened tags nothing, and the existing 37 tests stay green.
5. **Customer text inside the PDF that is not in a text span**: a logo image, a vector header, a subset font name, or the metadata. Pinned in Task 5: `test_sanitize_pdf.py` covers each case, including a font name and an image region.

---

### Task 1: Refusal and inheritance fact sheet

**Files:**
- Create: `MPP/notes/2026-10-27_super-lot-refusal-facts.md`

**Interfaces:**
- Produces: one table row per fact, with ids `F1`..`Fn`. Each row gives:
  - the action;
  - the proc, as `file:line`;
  - the condition that refuses;
  - the exact `@Message` text, with its placeholders shown;
  - whether the LOT still shows in that station's queue.

  Tasks 7, 8 and 9 cite these ids. A claim with no row is not made.

- [ ] **Step 1: Read the procs and write the sheet.** Cover, at minimum:
  - **Hard Hold.** `Lot_AssertNotBlocked` and its callers among move, advance, pick, mint and consume.
  - **CRT.**
    - `ufn_CrtBlocksMoveTo` and `ufn_CrtBlocksAdvance` (both in `R__Lots_ufn_zz_CrtBlocks.sql`).
    - `Workorder.Assembly_ScanIn`, `Workorder.MachiningIn_RecordPick` and `Workorder.MachiningOut_Mint` (scan path).
    - `Lots.Lot_Split` / `Lot_Merge`.
  - **Shipping.** `Lots.Container_Ship`: open hold, and a CRT tray LOT. Also `AimShipperIdPool_ListUnposted` holding the serial back.
  - **Born tagged.** `ufn_CrtForMint`, all four arms.
  - **`Workorder.Assembly_CompleteTray` with a CRT input.** Record whether it refuses, or consumes and mints a CRT finished good, quoting the lines that decide it.
  - **Queue visibility.** Does `Lot_GetWipQueueByLocation` still list a held LOT or a tagged LOT?
  - **Release.** What `Quality.ControlledRun_Release` requires (all results recorded? a signature?), and what it clears.
  - **Deviation.** What `ControlledRunDeviation_Raise` needs, and what it lets through afterwards.
- [ ] **Step 2: Check each row against a test.** Find a `sql/tests` assertion that exercises it, and note the test file beside the row. Mark a row with no test "untested". It may still be shown, but only once the capture confirms it.
- [ ] **Step 3: Commit** (MPP): the note.

### Task 2: Quality scenario in `MPP_MES_Demo`

**Files:**
- Create: `MPP/sql/seeds_demo/opt/060_demo_quality_scenario.sql`. It lives in a subfolder (a planner's call; the spec named `sql/seeds_demo/`) so the default `*.sql` glob skips it and modules 1-3 stay as captured.
- Create: `MPP/tools/sales-kit/demo-db/verify_demo_quality.sql`. It runs only with the switch.
- Create: `MPP/tools/sales-kit/demo-db/Set-QualityAdAccount.ps1`
- Modify: `MPP/tools/sales-kit/demo-db/Build-DemoDatabase.ps1`. Add `[switch]$WithQualityScenario`. When set, run `seeds_demo\opt\*.sql` after the main seeds and before sanitize, and run `verify_demo_quality.sql` with the other verifies. Without the switch, the file glob for verifies must exclude `verify_demo_quality.sql`.
- Modify: `MPP/tools/sales-kit/demo-db/verify_demo_scenario.sql`. Add a check that `Quality.ControlledRun` and `Quality.Hold` are empty, but only when no `opt` seed ran. The script detects this from the absence of the sample Quality user, `Pin = N'61030'`.

**Interfaces:**
- Consumes: the fact sheet (Task 1), which says which states produce which refusal.
- Consumes: `050`'s LOTs, located by ticket and LOT name, never by `Id`.
- Reference for proc call shapes: `sql/scratch/2026-10-13_super_lot_walkthrough_seed.sql`.
- Produces:
  - **The sample Quality user** "E. Novak", initials `EN`, PIN `61030`, `AdAccount = N'quality.sample'`, created via `Location.AppUser_Create`.
  - **`Set-QualityAdAccount.ps1 -Login <name>`.** Calls `Location.AppUser_Update` on the `EN` row with `@AdAccount = <name>` against `MPP_MES_Demo` only, refusing any other `-DatabaseName`. Run at session time so Jacques's login is never in a committed file.
  - **One open hard Hold** on a casting LOT (the "problem LOT"). It is a basket LOT that is still open: not `520100001`, not `520100003`, and none of the LOT names that `steps.js` captures. It is placed via `Quality.Hold_Place`, with sample reason text "Porosity found at incoming inspection".
  - **One open controlled run `CR000001`.**
    - Opened via `Quality.ControlledRun_Open`, anchored on the problem LOT with `@IncludeDescendants = 1`.
    - Selection: its part at its line, from the start of the shift.
    - `@AutoJoinEnabled = 1`.
    - Reason "Porosity found at incoming inspection - contain and 200% inspect".
  - **After the run opens, through `050`'s procs:**
    - at least one new basket of the same part is opened and released, so it joins by auto-join;
    - at least one LOT is minted at Machining OUT from a tagged casting, so it is born tagged.
  - **Members added via `Quality.ControlledRun_AddMembers`:**
    - one completed container from `050` (pulled back from finished stock);
    - one Received-origin seal-kit LOT, so Return to vendor is offered.
  - **`Quality.ControlledRunResult_Record`** for about half the members, with a mix of good, scrap and rework outcomes. Nothing is released, no deviation is raised, and no repack is done. Those are done live in Task 6.
  - Every call checks its status row and `RAISERROR`s with its step name, as `050` does.

- [ ] **Step 1: Write `verify_demo_quality.sql`** (prints `PASS ...` / `FAIL ...` and raises on a FAIL, as the existing verifies do). Assert:
  - exactly one open Hold, on a LOT whose name is not in the module 1-3 list above;
  - `CR000001` is open with auto-join on;
  - its members include at least one each of:
    - a tagged casting in `Lot_GetWipQueueByLocation` for L-1 Machining IN;
    - a tagged casting in the Machining OUT queue;
    - a tagged LOT at L-1 Assembly OUT;
    - a LOT created after the run's open time that joined through auto-join;
    - a LOT minted from a tagged input with `CrtActive = 1`;
    - a completed container;
    - a `Received`-origin LOT;
  - results exist for at least one member and are missing for at least one;
  - the run is not released;
  - user `EN` exists.
- [ ] **Step 2: Run it against a build without the seed.** Run `Build-DemoDatabase.ps1 -WithQualityScenario` with `060` still empty. Expected: the build stops on the first `FAIL` line.
- [ ] **Step 3: Write `060`, byte-scan it for non-ASCII, rebuild with `-WithQualityScenario`.** Expected: every verify prints PASS, the sanitized gate passes, and the build prints "MPP_MES_Demo built, sanitized and verified."
- [ ] **Step 4: Rebuild without the switch.** Expected: every verify passes, including the new empty-Quality check. Then rebuild with the switch again, so the database is ready for Task 6.
- [ ] **Step 5: Commit** (MPP): `060`, both verifies, the build script and `Set-QualityAdAccount.ps1`.

### Task 3: Headed, continuous capture with sign-in pauses and password safety

**Files:**
- Modify: `MPP/tools/sales-kit/capture/capture.js`
- Modify: `MPP/tools/sales-kit/capture/sanitize.py`
- Create: `MPP/tools/sales-kit/capture/test_capture_password.js`
- Modify: `MPP/tools/sales-kit/capture/test_sanitize.py`

**Interfaces:**
- **New `capture.js` flags.**
  - `--headed` opens a visible Chrome window: `headless: false`, `defaultViewport: null`, window size from `VIEWPORT`.
  - `--steps-file <path>` loads the steps from that file. It defaults to `./steps.js`, so the module 1-3 behaviour is unchanged.
  - `--project <name>` sets the project. It defaults to `MPP`; a step may set `project: 'MPP_Config'`.
- **New step fields.**
  - `stay: true` skips the `goto` and continues on the current page.
  - `signIn: 'jacques'` runs after the step's `actions` and before `ready`. It prints `>>> SIGN-IN: <prompt>` (the step's `signInPrompt` text, saying what field Jacques will type into and what happens next), rings the terminal bell, and waits for Enter on stdin. It also lifts the 120 s step timeout for that step.
  - `noCapture: true` runs the step's actions without saving anything. Used for the setup steps between captures.
- **Exports.** When `require`d (not run as the main module), `capture.js` exports `{ snapshotHtml, act, settle, ready, url }` and does not launch anything. Wrap the main IIFE in `if (require.main === module)`.
- **`snapshotHtml` password rules.**
  - It never copies a value from an `input[type=password]`, and it removes any `value` attribute from password inputs in the clone.
  - If a visible password input on the live page has a non-empty value, it throws `'password field has a value - close the login popup before capturing'`.
- **`sanitize.py`.** Adds `PASSWORD_VALUE = re.compile(r'<input\b[^>]*type="password"[^>]*\bvalue="[^"]+"', re.I)`. A match is a problem: `"<name>: password input with a value"`.

- [ ] **Step 1: Write the failing tests.**
  - `test_capture_password.js` (`node --test`): launch headless Chrome via puppeteer-core and load a `data:` page with `<input type=password id=p><input id=t>`. Type `s3cret!` into `#t` and `hunter2` into `#p`.
    - Assert `snapshotHtml(page)` rejects with the password message.
    - Clear `#p`, call it again, and assert the result contains `s3cret!` and does not contain `hunter2`.
  - `test_sanitize.py::test_fails_on_password_value`: `sanitize_html` on markup with `<input type="password" value="x">`, run through `main()` on a temp raw folder, exits non-zero with "password input" in its output.
- [ ] **Step 2: Run both.** Run `node --test test_capture_password.js` and `python -I test_sanitize.py`. Expected: both FAIL (no export / no check yet).
- [ ] **Step 3: Implement the flags, the step fields, the export guard and the password rules.**
- [ ] **Step 4: Run both again.** Expected: PASS. Then run the full `python -I test_sanitize.py` (11 passed) and `python -I ..\test_check_terms.py` (12 passed).
- [ ] **Step 5: Check module 1-3 behaviour.** Run `node capture.js --steps m2-trim --out <scratchpad>` against whatever DB the gateway is on. It is headless, with no new flags. Expected: it captures as before. Then delete the output, since it is Dev data.
- [ ] **Step 6: Commit** (MPP): `capture.js`, `sanitize.py` and both tests.

### Task 4: Module 4 capture steps

**Files:**
- Create: `MPP/tools/sales-kit/capture/steps_m4.js`

**Interfaces:**
- Consumes: the step fields from Task 3, and the `050`/`060` LOT names from Task 2.
- Produces: the step names below, which Tasks 7 and 9 use as `<name>.png` / `cap-<name>`. Before writing each step, find the route and component labels in `ignition/projects/MPP/com.inductiveautomation.perspective/views/BlueRidge/Views/ShopFloor/...`. The view folder names give the routes. Read `page-config` for the URL.

| Step | Terminal | What it shows | Sign-in |
|---|---|---|---|
| `m4-superlot-list` | DC | `/shop-floor/controlled-runs`, the list with `CR000001` open | -- |
| `m4-superlot-members` | DC | `CR000001`, Members tab: auto-join on, members by origin, "Pulled back from finished stock" | -- |
| `m4-superlot-results` | DC | Results tab, partly recorded | Quality sign-in that opens the editing window (`signInPrompt`: the elevation dialog's username and password; the tab becomes editable) |
| `m4-superlot-results-saved` | DC | after Jacques marks the rest and saves | Save results / Mark the rest |
| `m4-repack` | DC | the Repack popup on the pulled-back container | Repack |
| `m4-signoff-release` | DC | the release popup, ready to sign | Sign and release (the popup is captured before Jacques signs; `snapshotHtml` refuses a filled password field, so nothing is captured mid-sign-in) |
| `m4-signoff-done` | DC | Sign-off tab after release | -- |
| `m4-deviation` | DC | the Use-As-Is deviation popup, then after signing | Sign deviation |
| `m4-superlot-history` | DC | History tab | -- |
| `m4-wizard-preview` | DC | New super-lot wizard at its preview step (a second run, cancelled before the last step unless Jacques chooses to finish it) | the wizard's last step, if finished |
| `m4-label` | DC | super-lot label preview | -- |
| `m4-holds` | DC | Hold Management with the problem LOT | -- |
| `m4-lot-held` | DC | LOT Detail of the problem LOT with the hard Hold | -- |
| `m4-lot-member` / `-superlots-tab` / `-history` | DC | LOT Detail of a tagged member: CRT pill, super-lot chip, Super-lots tab, History tab | -- |
| `m4-crt-clear` | DC | LOT Detail CRT clear on one member | CRT clear |
| `m4-refuse-machining-in` | L1-MIN | scan a tagged casting: the refusal message | -- |
| `m4-refuse-machining-in-hold` | L1-MIN | scan the held LOT, if the message differs (fact sheet) | -- |
| `m4-refuse-machining-out` | L1-MOUT | pick / scan a tagged casting: the refusal | -- |
| `m4-refuse-assembly` | L1-AOUT | check in a tagged LOT: the refusal | -- |
| `m4-refuse-move` | TRIM | a validated move of a tagged LOT to a production location, only if it reads differently | -- |
| `m4-refuse-dock` | DC (or the shipping terminal, if `001` has one) | ship the pulled-back container: the refusal | -- |
| `m4-genealogy` / `m4-trace` | DC | Genealogy Viewer and Global Trace with super-lot markers | -- |
| `m4-dashboard` | DC | Supervisor Dashboard, Open super-lots tile | -- |
| `m4-report` | DC | Reports page, Super-lot report for `CR000001` | -- |
| `m4-config-specs` | -- (project `MPP_Config`) | Quality Specs for one sample part | Config Tool AD login |

- [ ] **Step 1: Write `steps_m4.js`**, in the capture order the scenario needs.
  - Read-only steps come first.
  - Then the refusals. The release clears the tags, so the refusals must come before it.
  - Then the signed steps, in the order Results, Repack, Deviation, Release.
  - Then the record steps that show the outcome.
  - Every sign-in step carries a `signInPrompt` that names the field and the next screen.
- [ ] **Step 2: Syntax check.** Run `node --check steps_m4.js`, then `node -e "require('./steps_m4.js').forEach(s=>{if(!s.name)throw s})"`. Expected: no errors, and the step count matches the table.
- [ ] **Step 3: Commit** (MPP).

### Task 5: PDF sanitizer

**Files:**
- Create: `MPP/tools/sales-kit/capture/sanitize_pdf.py`
- Create: `MPP/tools/sales-kit/capture/test_sanitize_pdf.py`

**Interfaces:**
- **Command:** `python -I sanitize_pdf.py --in <raw.pdf> --out <clean.pdf> [--png <page1.png>] [--cover "x0,y0,x1,y1=Replacement text"]...`
- **Rules:** import `sub` from `sanitize.py`, so the PDF gets the same `substitutions.json` and date rules as the screens.
- **Text spans:** for every span, using `page.get_text("dict")`, whose text changes under `sub()`:
  - add a redaction annotation over its bbox and apply redactions with `images=PDF_REDACT_IMAGE_NONE`;
  - write the new text with `page.insert_text` at the span origin, in the span size;
  - use font `helv`, or `hebo` when the span font name contains "Bold".
- **Cover regions:** each `--cover` region is filled white and the text is written inside it. This is for logos and vector headers.
- **Metadata:** set to `{title: "Super-lot report", author: "", subject: "", keywords: "", creator: "", producer: "", creationDate: "", modDate: ""}`, and remove the XMP.
- **Fonts:** subset font names (`ABCDEF+FontName`) that match a banned term fail the run. The PDF is then re-made, so that font is no longer used.
- **Checks:** writes the extracted text of `--out` to a temp folder and runs `check_terms.py` on it (full rules, including dates). Exits 1 on any hit.
- **PNG:** with `--png`, renders page 1 at 2x zoom.

- [ ] **Step 1: Write the failing tests.** Fixture PDFs are built in the test with pymupdf.
  - A span "Madison Precision Products" becomes "Sample Components Co.", and the extracted text has no banned term.
  - The span "Printed 10/27/26 08:49" loses its date and keeps the time.
  - The metadata author "jpotgieter" is gone.
  - A `--cover` region removes an image's text: the gate passes, and the pixel at the region centre is white.
  - A fixture whose remaining text contains "Honda" outside any substitution rule makes the command exit 1.
- [ ] **Step 2: Run** `python -I test_sanitize_pdf.py`. Expected: FAIL (module missing).
- [ ] **Step 3: Implement `sanitize_pdf.py`.**
- [ ] **Step 4: Run.** Expected: all tests pass.
- [ ] **Step 5: Commit** (MPP).

### Task 6: The capture session with Jacques (gateway walk + bug log)

**Files:**
- Create: `MPP/notes/2026-10-27_super-lot-gateway-walk-bugs.md`
- Modify: `MPP/tools/sales-kit/substitutions.json` and `banned_terms.txt` (Jacques's login, plus new hits)
- Output: `CAP/m4/raw/*`, `CAP/m4/superlot-report.pdf`, `KIT/deck-build/screens-real/m4-*.png`, `KIT/demo-build/captures/m4-*.json`, `KIT/demo-build/assets/superlot-report.pdf`, `KIT/deck-build/screens-real/m4-report-page1.png`

- [ ] **Step 1: Prepare before calling Jacques.**
  - Rebuild `MPP_MES_Demo` with `-WithQualityScenario`.
  - Read on the gateway which user source elevation authenticates against: `BlueRidge.Common.Session` / the elevation popup script and the project's `auth` settings. Write the finding at the top of the bug log.
- [ ] **Step 2: Flag Jacques and ask him for three things.**
  - Reset the Perspective trial.
  - Switch the `MPP` connection to `MPP_MES_Demo`.
  - Tell the builder the AD login he will sign in with.

  Then run `Set-QualityAdAccount.ps1 -Login <it>`. Add that login, as an exact case-insensitive word pattern, to `banned_terms.txt` and to `substitutions.json` (→ `quality.sample`). Run `Check-GatewayDb.ps1 -Expect Demo` and expect PASS.
- [ ] **Step 3: Run the steps.** Run `node capture.js --headed --steps-file steps_m4.js --steps all --out CAP\m4`.
  - At each `>>> SIGN-IN` pause, tell Jacques in chat which step it is and what he will type into. He types, then presses Enter in the terminal. Run the command in a terminal tab Jacques can see (`mcp__terminal__run_in_terminal`) so he can press Enter there.
  - After each step, look at its PNG.
  - **A bug** gets a bug-log entry with: screen and route; steps from a named state (`060` + the steps before it); expected; actual; a `wrapper.log` excerpt; the PNG path; the likely proc or view. Work around it (a different state, or drop the beat and note it) and keep going. Never edit the application.
  - Re-run single steps with `--steps <name>` as needed.
- [ ] **Step 4: Save the Super-lot PDF.** On the `m4-report` screen, save the Super-lot report for `CR000001` as `CAP\m4\superlot-report.pdf`. Use the viewer's download, or render it with the report's own gateway call as the Reports page does. Ask Jacques if the browser's save dialog is in the way.
- [ ] **Step 5: Switch the gateway back.** Ask Jacques to switch the connection back to `MPP_MES_Dev`. Do this as soon as the last capture is in, or immediately after any failure that ends the session. Run `Check-GatewayDb.ps1 -Expect Dev` and expect PASS, then tell Jacques the gateway is back on Dev.
- [ ] **Step 6: Sanitize the captures.** Run `python -I capture\sanitize.py --raw CAP\m4\raw --out-screens KIT\deck-build\screens-real --out-captures KIT\demo-build\captures`. The `m4` raw folder holds its own `bundle.css`. If its CSS differs from the existing bundle, keep the module 1-3 bundle and confirm the `m4` screens render with it, by looking at the PNGs. Two bundles are not inlined in the demo. Add each gate hit to `substitutions.json` and re-run. Expected: exit 0.
- [ ] **Step 7: Sanitize the PDF.** Run `python -I capture\sanitize_pdf.py --in CAP\m4\superlot-report.pdf --out KIT\demo-build\assets\superlot-report.pdf --png KIT\deck-build\screens-real\m4-report-page1.png`, adding `--cover` regions after looking at the raw page. Expected: exit 0. Then look at the PNG: the layout should be intact and the replacement text legible.
- [ ] **Step 8: Finish the bug log.** Add the walked-and-worked list, and the could-not-reach list with reasons.
- [ ] **Step 9: Run the kit-wide gate.** Run `python -I tools\sales-kit\check_terms.py "KIT"`. Expected: `0 hit(s)`.
- [ ] **Step 10: Commit.**
  - MPP: the bug log, `substitutions.json`, `banned_terms.txt`.
  - KIT: the `m4` PNGs, captures and the PDF.

### Task 7: Deck module 4

**Files:**
- Modify: `KIT/deck-build/build_deck.js`
- Modify: `KIT/deck-build/check_deck.py`

**Interfaces:**
- Consumes: the `m4-*.png` files and `m4-report-page1.png` (Task 6), and the fact ids (Task 1).
- **`MODULES` gains a fourth entry**, "Quality & containment", with `pitch`, `inThis` (four items) and `notes`.
- **A slide entry is either the existing 5-tuple or an object `{title, caption, shots: [[file, label], ...], notes}`.** An object renders its shots side by side, two or four across, sized like the "operator's day" pair, with labels under each. `MODULES.forEach` dispatches on `Array.isArray`.
- **`LATER`** drops the "Quality & containment" row. The tile number for a `LATER` tile becomes `MODULES.length + i + 1`.
- **`PICKER`'s Quality line** loses "(available on request: show it in the live demo)".
- **The add-ons slide** drops the "Controlled runs" card. Lay out the remaining three cards in the same 2x2 grid, leaving the fourth cell empty, unless the gap looks wrong in the render; then centre the third.

The slides:

| # | Title | Caption idea | Shots |
|---|---|---|---|
| 1 | Suspect material is caught automatically | Quality opens a super-lot from one suspect LOT; everything made from it and of that part since joins - and new baskets join as they are made, until Quality closes the window. | `m4-superlot-members` |
| 2 | Nothing suspect gets through | Every route out refuses a held or tagged LOT and names the super-lot: Machining IN, Machining OUT, Assembly and the dock. | `m4-refuse-machining-in`, `m4-refuse-machining-out`, `m4-refuse-assembly`, `m4-refuse-dock` (only those the fact sheet and the captures support) |
| 3 | Inspect, disposition, sign | Each member gets an outcome; release is signed, confirming the 200% inspection; a Use-As-Is deviation is signed on its own. | `m4-superlot-results-saved`, `m4-signoff-done` (+ one line in notes on per-part quality checks, `m4-config-specs`) |
| 4 | The record follows the part | The super-lot shows on the LOT, in its genealogy and history, and as a printable report. | `m4-lot-member-superlots-tab`, `m4-report-page1` |

The module intro slide previews slide 1's shot. Captions and notes are written from the fact sheet and the captures. Notes start with `TALK TRACK:`.

- [ ] **Step 1: Make `check_deck.py` fail first.**
  - Add "Quality & containment" to `MODULES`.
  - Add a check: the add-ons slide's text has no "Controlled runs".
  - Add a check: the menu slide has exactly 3 "Available on request".
  - Add a check: no slide in the Quality section contains `in production|deployed|live at|running at` (case-insensitive).

  Run it against the current deck. Expected: FAIL on the new checks.
- [ ] **Step 2: Implement the deck changes and rebuild.** In `KIT\deck-build`, run `APPLY_THEME="<pptx skill>/scripts/apply_theme.js" NODE_PATH="$PWD/node_modules" node build_deck.js`. The `APPLY_THEME` path is recorded in the SOURCE note's build record. Add it there if it is missing.
- [ ] **Step 3: Check the deck.**
  - `python -I deck-build/check_deck.py "KIT/MES Track & Trace - Overview.pptx"`: all checks pass.
  - `python "<pptx skill>/scripts/office/validate.py" <deck>`: passes.
  - Render the deck through PowerPoint (only if PowerPoint is not running) and review the contact sheet for the new slides and the menu.
  - Check through COM that tile 04 jumps to the module start and that the module's last slide links back to slide 6.
- [ ] **Step 4: Run** `check_terms.py` on KIT. Expected: 0. Commit (KIT).

### Task 8: Demo model -- holds, tags, super-lots

**Files:**
- Modify: `KIT/demo-build/src/model.js`
- Modify: `KIT/demo-build/src/config.js` (run and deviation number prefixes, sample reasons)
- Create: `KIT/demo-build/test/model.quality.test.js`

**Interfaces:**
- **Consumes:** the fact sheet. The refusal messages use the application's wording from it, with the run number filled in.
- **State:**
  - `st.superLots = {}` and `st.nextRun = 1`, `st.nextDeviation = 1`.
  - Each lot gains `crt: null | runNumber` and `hold: null | {reason, who, t}`.
- **New exports** (all on `Model`):
  - `placeHold(st, lotId, reason, who) -> lot`
  - `releaseHold(st, lotId, who) -> lot`
  - `openSuperLot(st, {anchorLotId, reason, autoJoin}, who) -> run`
    - `run = {number: 'CR' + 6 digits, reason, item, line, from: st.clock, autoJoin, members: [lotId|containerId], results: {}, released: null, deviations: []}`.
    - Members are the anchor, its `traceForward` descendants, and open LOTs of the anchor's item at its line created at or after the anchor's `createdAt`. Each member gets `crt = run.number`.
  - `addMember(st, runNumber, lotOrContainerId, who)` for a pulled-back container or a received LOT.
  - `recordResult(st, runNumber, memberId, outcome, who)`, where outcome is one of `'Good' | 'Scrap' | 'Rework' | 'ReturnToVendor'`.
    - `ReturnToVendor` is allowed only for `origin === 'Received'`.
    - `Scrap` closes the LOT.
  - `releaseSuperLot(st, runNumber, who) -> run`.
    - Requires every member to have a result, otherwise it throws the fact-sheet message.
    - Sets `released = {who, t}`, clears `crt` on every member and closes the auto-join window.
  - `raiseDeviation(st, runNumber, memberId, reason, who) -> 'DV' + 6 digits`. Its effect is as the fact sheet records it.
  - `shipContainer(st, containerId, who)`.
- **Changed behaviour:**
  - **Auto-join:** `newLot` tags a new LOT when an open, unreleased run with `autoJoin` matches its item and location.
  - **Born tagged:** `machiningOutMint` tags its child when the parent is tagged.
  - **Assembly:** `assemblyCompleteTray` either refuses or tags its tray LOT, exactly as fact-sheet row "Assembly_CompleteTray with a CRT input" says.
  - **Refusals:** `machiningInPick`, `machiningOutMint`, the assembly check-in (`checkInBox` and `assemblyCompleteTray` sources), `packContainer` and `shipContainer` refuse a held or tagged LOT with the fact-sheet message.
  - **Queues:** `lineQueue` keeps or drops held and tagged LOTs as the fact sheet's queue-visibility column says.

- [ ] **Step 1: Write the failing tests** in `model.quality.test.js`. Name each test after its fact id, e.g. `'F7 machining IN refuses a tagged LOT'`.
  - A fresh state has no super-lot and no tagged LOT. `sim` runs 500 ticks without tagging anything.
  - `openSuperLot` on a casting tags it and its minted children. A basket of the same part opened afterwards at the same press and line is born tagged. A basket of a different part is not.
  - A tagged casting is refused at `machiningInPick`, and the error matches `/CR000001/`. The same casting after `releaseSuperLot` is picked.
  - A held LOT is refused at `machiningInPick` with the hold message, and accepted after `releaseHold`.
  - A tagged machined LOT: `assemblyCompleteTray` behaves as the Assembly fact-sheet row says.
  - `shipContainer` of a pulled-back container is refused with `/CR000001/`, and succeeds after release.
  - `recordResult(..., 'ReturnToVendor')` throws for a manufactured LOT and succeeds for a received one.
  - `releaseSuperLot` throws while a member has no result.
  - Run numbers go `CR000001`, `CR000002`; deviations go `DV000001`.
- [ ] **Step 2: Run** `node --test test/*.test.js`. Expected: the new tests FAIL, and the existing 37 pass.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run.** Expected: every test passes (37 + new).
- [ ] **Step 5: Commit** (KIT).

### Task 9: Demo module 4 -- views, refusal states, tour

**Files:**
- Create: `KIT/demo-build/src/ui/m4.js`
- Modify: `KIT/demo-build/src/ui/shell.js` (`MODULES.m4 = { label: 'Quality & containment', order: 4 }`)
- Modify: `KIT/demo-build/build_demo.py` (`ORDER` gets `ui/m4.js` before `ui/tour.js`; it embeds `assets/superlot-report.pdf` as `<script type="text/plain" id="asset-superlot-pdf">` base64)
- Modify: `KIT/demo-build/src/ui/m1.js` (the "Inspections ... Quality add-on" toast becomes "Part of the live engineer demo.")
- Modify: `KIT/demo-build/src/ui/m3.js` (machining-in, machining-out and assembly show the captured refusal message in a toast and in the station's message region when the model throws a hold or CRT error; `CRT Validation` stays inert)
- Modify: `KIT/demo-build/src/ui/m1.js` lot-detail (the CRT pill and super-lot chip, shown when `lot.crt`; the Super-lots tab mounted from `m4-lot-member-superlots-tab`)

**Interfaces:**
- **Consumes:** `RS.screen / text / rows / show / on / input` (`rs.js`), `UI.register`, `UI.requireSupervisor(label, onApprove)` (`core.js`), the Task 8 model exports, and the `cap-m4-*` captures.
- **Views registered:**
  - `super-lots`: list, then a page with the Members, Results, Sign-off and History tabs. Members, results and history are live from the model, with rows filled by `RS.rows` from the first captured row.
  - `holds`: Hold Management, live.
  - `shipping`: the dock capture. Shipping the pulled-back container calls `Model.shipContainer`.
- **Key actions:**
  - **Open super-lot:** a short form of the demo's own, from LOT Detail or the `super-lots` list. It calls `openSuperLot` on the chosen casting with auto-join on.
  - **Refused scans:** at stations already in m3.
  - **Record outcome:** a per-row outcome dropdown on Results.
  - **Sign and release:** `UI.requireSupervisor('Sign and release CR000001', ...)`, then `releaseSuperLot`.
  - **View the report:** opens the embedded PDF as a blob URL in a new tab.
  - Everything else on the captured screens is inert, with the existing `later()` toast.
- **`TOURS.m4`.** Title "Quality & containment"; blurb "Suspect material contained, refused at every route out, inspected and signed off." Steps, in order:
  1. open a super-lot from a casting;
  2. watch the next basket join;
  3. Machining IN refuses a tagged LOT;
  4. Assembly refuses;
  5. the dock refuses;
  6. record results;
  7. supervisor sign-off;
  8. the tags clear and the LOT moves again;
  9. LOT Detail shows the history.

  Step text comes from the fact sheet. Each step's `go()` must work from any state: it creates the run if the tour was entered mid-way. Add `SCENES['m4-*']` hooks matching the deck shots, as m3 does.
- **RESET** clears `st.superLots` and every tag and hold, because it rebuilds the state.

- [ ] **Step 1: Implement and build.** Run `python -I build_demo.py` in `demo-build`.
- [ ] **Step 2: Browser check** with headless Chrome (`verify_demo.js` from the scratchpad tools; module `puppeteer-core` from `MPP\tools\sales-kit\capture\node_modules`).
  - Tour m4 at 1x and at 10x, with RESET mid-tour: every highlight is found, no console errors, and no requests beyond the page.
  - The refused scans show the run number.
  - After release, the same LOT is picked at Machining IN.
  - An open Results dropdown and the super-lot page's active tab survive 10x ticks.
  - The report opens.
  - The welcome menu shows tile 04 as live.
- [ ] **Step 3: Side-by-side check.** Compare each `m4` demo screen with its capture PNG: same fonts, colours and layout.
- [ ] **Step 4: Run** `node --test test/*.test.js`: green. Run `check_terms.py` on KIT: 0. Commit (KIT).

### Task 10: Verify, document, review

**Files:**
- Modify: `KIT/README.md` (module 4; how to re-capture: `-WithQualityScenario`, `Set-QualityAdAccount.ps1`, `--headed --steps-file steps_m4.js`, `sanitize_pdf.py`)
- Modify: `MPP/notes/2026-10-26_mes-sales-kit-SOURCE.md` (a "Module 4 (2026-10-27)" section: the maturity ruling and its wording rule, the rulings taken while building, and a pointer to the bug log)

- [ ] **Step 1: Run the full verification.**
  - Demo at viewports 1600x900, 1024x768 and 700x900, inside an iframe, and from `file://`.
  - All five tours at 10x with RESET mid-tour.
  - Network shows the page only; zero console errors; `node --test` green.
  - Deck checks as in Task 7, Step 3.
  - `check_terms.py` on KIT: 0 hits, run standalone.
- [ ] **Step 2: Check every module 4 claim against its source.** Walk every module 4 slide caption, note and tour step against its capture and its fact id, and fix any claim with neither.
- [ ] **Step 3: Remove the stray deck copy.** Delete `KIT/MES Track & Trace - MPP.pptx` once PowerPoint no longer has it open. If it is still locked, tell Jacques.
- [ ] **Step 4: Commit both repos.**
- [ ] **Step 5: Whole-work review and hand-over.** Run a whole-work review on the most capable model and do a fix pass. Then hand over the deck, the demo and the bug log, giving the bug count and the location of the log.
