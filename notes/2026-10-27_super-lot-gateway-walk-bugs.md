# Super-lot gateway walk -- bug log (sales-kit module 4 capture session)

The first time the super-lot screens were driven on a gateway. Written during the capture session
of `docs/superpowers/plans/2026-10-27-mes-sales-kit-module-4-quality.md` (Task 6) so another agent
can pick each bug up cold. **Nothing here was fixed in the session**: the application was not
changed. Each entry: screen and route; steps from a named state; expected; actual; `wrapper.log`
excerpt; screenshot (`tools/sales-kit/captures/m4/raw/<step>.png`, gitignored); likely proc / view.

## Scenario state

`MPP_MES_Demo` built with `tools\sales-kit\demo-db\Build-DemoDatabase.ps1 -WithQualityScenario`
(`sql/seeds_demo/opt/060_demo_quality_scenario.sql`): casting `520100004` on a hard Hold; super-lot
`CR000001` open with "keep adding new production" on for HSG-410; members as listed in the seed
header; results recorded for `520100006` only. The sample Quality user `EN` (E. Novak) has its
`AdAccount` set to the presenter's login with `Set-QualityAdAccount.ps1`.

## How elevation authenticates (checked before the session)

`BlueRidge.Location.AppUser.elevate` (Core) checks the password with
`system.security.validateUser(account, password, "Active Directory")` -- the user source named
`_ELEVATION_USER_SOURCE` -- then resolves the account through `Location.AppUser_AuthenticateAd`,
which needs an ACTIVE `AppUser` whose `AdAccount` equals the typed account. Signing (release,
deviation) additionally needs `Quality.ufn_SignatureAllowed`: any active user with a non-empty
`AdAccount`. So on this gateway an "Active Directory" user source must exist, and the account name
typed at sign-in must match what `Set-QualityAdAccount.ps1` stored, character for character.

Checked 2026-10-29: on this gateway "Active Directory" is an INTERNAL user source (a test stand-in),
so the presenter login was a local test account. Elevation, the deviation signature and the release
signature all resolved to the sample user EN as designed.

## How the walk was driven (2026-10-29)

Not with `capture.js --steps all`: `tools/sales-kit/capture/drive_session.js` kept one headed Chrome open
(`--remote-debugging-port`) and ran capture.js's own `act` / `snapshotHtml` / `bundleCss` step by
step, so sign-ins could be done and steps adjusted live. Two harness lessons for the next walk:

- **Launch Chrome with `--disable-background-timer-throttling --disable-renderer-backgrounding
  --disable-backgrounding-occluded-windows`.** Without them the backgrounded window let Perspective
  drop its websocket between commands (`WebSocket disconnected`, then `MessageChannelException:
  Channel is not set` in wrapper.log), and the first click after each reconnect was silently lost.
  That looked like several app bugs (wizard won't open, Save does nothing, terminal tree click
  ignored); none of them were.
- **The terminal tree only navigates on a selection CHANGE.** Clicking the already-selected
  terminal does nothing; select another node first.
- `capture.js` now also exports `selectTerminal`, `bundleCss`, `clickText` (used by the driver).
- `steps_m4.js` would throw at load: `PULLED_LABEL` selects `Lots.ShippingLabel.LabelSerial`, which
  does not exist (the column is `AimShipperId`). And Ship Container wants the label's row **Id**
  (`1` for Container 1), not the printed serial. Fix both before steps_m4.js is run again.

State at walk end (changed from 060): results recorded for every member with pieces (EN), deviation
`DV000001` signed (2 pcs Use as is on `520100003-02`), 10 members released; `520100003-01` and
`520100009` (0 pcs) still tagged; window still open; `520100004` still on hard Hold. Rebuild
`MPP_MES_Demo` before another walk.

## Bugs

### BUG-1 -- Reports: Print PDF throws for the Super-lot report (no PDF is produced) -- FIXED `523867a0`

- **Screen / route:** Reports (`/shop-floor/reports`), Super-lot report, `CR000001` picked.
- **Steps:** state above; pick Super-lot, pick `CR000001` (the viewer renders 3 pages fine), press
  **Print PDF**.
- **Expected:** a PDF download.
- **Actual:** nothing downloads; `Print failed` toast path. Other reports' Print PDF not tried.
- **wrapper.log (11:27:24):** `Error running action 'component.onActionPerformed' on
  BlueRidge/Views/Reports@C/root/Detail/Controls/PrintButton` ... `File "<custom-method printPdf>",
  line 18` ... `java.lang.ClassCastException: Cannot coerce value '<ObjectWrapper>: {u'ControlledRunId':
  1}' into type: org.python.core.PyDictionary` at `ReportScriptingFunctionsPyWrapper.executeReport`.
- **Likely place:** `Views/Reports` customMethod `printPdf`: `params =
  BlueRidge.Common.Util.extractQualifiedValues(self.view.custom.reportParams)` still hands
  `system.report.executeReport` a wrapper, not a plain dict (compare the ImmutableMap note in
  memory: a JSON round-trip or explicit `dict()` per key may be needed).
- **Effect on the kit:** no Super-lot PDF; the deck's last module 4 slide uses LOT Detail + genealogy
  instead. (The on-screen viewer is not usable either: it draws the report as an image and the
  customer name is in its pixels.)
- **Fixed 2026-10-29 (`523867a0`):** `view.custom.reportParams` reads back as a live
  `PropertyTreeScriptWrapper$ObjectWrapper`, which `extractQualifiedValues` passes through untouched.
  `printPdf` now copies it key by key into a plain dict (not a JSON round-trip, which would turn the
  date-range params into strings) and catches Java exceptions too, so a failure reaches the toast
  instead of only `wrapper.log`. The path is shared by every report on the page, so all of them were
  broken. **Verified** on the gateway against `MPP_MES_Dev`: Print PDF returned `application/pdf`
  (`%PDF-`) for Super-lot `CR000001` (44 KB, 3 pages) and Rejects - Plant Summary (14-day date range);
  no errors in `wrapper.log`.

### BUG-2 -- Super-lot Sign-off: the release signature card's text overlaps -- FIXED `523867a0`

- **Screen:** super-lot page, Sign-off tab, "Signatures on this super-lot", after a release.
- **Steps:** release ticked members with a signature.
- **Expected:** the card shows "Release of 10 members" and the confirmation statement on its own lines.
- **Actual:** the statement is squeezed into the title row: two lines drawn on top of each other and
  clipped. The deviation card below it renders fine.
- **Screenshot:** none kept -- seen live at 11:17; the saved `m4-signoff-done` capture caught the
  page after a websocket reconnect had deselected the super-lot, so it was removed from the kit.
  Reproduce: rebuild, release any member, look at the card. **Likely place:** the signature row
  template's fixed height / text wrap in the Sign-off tab view.
- **Fixed 2026-10-29 (`523867a0`):** the Sign-off tab's deviation and signature repeaters held each
  `Components/PlantFloor/ControlledRunInfoRow` at a fixed 84px (`useDefaultViewHeight`) with the
  statement label at `basis: 0; grow: 1`. Both repeaters now use `basis: auto` rows and the statement
  label sizes to its content. **Verified** on the gateway against `MPP_MES_Dev` (`CR000001`, its one
  signed release): the card shows the title, the full two-line statement and the signer line; the
  statement's height equals its content height, so nothing is clipped.

## Observations and questions (not called bugs -- Jacques to rule)

1. **Hold Management:** clicking a row in the open-holds list (LOT name drawn like a link) does not
   load it into the right panel; typing the LOT and pressing Load does. Intended?
2. **LOT Detail:** the status pill for a hard-held LOT reads `HOLD` in the same green as `GOOD`.
   The page also opens on the **Hold** tab for an un-held LOT ("No LOT or container selected.").
3. **Refusal presentation differs:** a CRT refusal at Machining IN / OUT is a modal ("LOT is marked
   CRT", names the super-lot); a hard-Hold refusal at Machining IN is an error toast. Same at the
   dock: the CRT refusal (F12) does not name the super-lot.
4. **Queues do not show the tag:** Machining OUT FIFO and Assembly IN list a CRT-tagged LOT with
   only a `GOOD` pill; the operator learns at submit (consistent with F30, but no visual cue).
5. **Assembly IN** shows `arrived 2026-10-27 19:31:28.157` -- a raw timestamp with milliseconds
   (UTC or ET?) where other screens show `10/27 19:31`.
6. **Machining IN** "Active machined LOT (after pick)" shows `MESL3000015 FG-4100 12 pcs`, a finished
   good tray, on the demo data.
7. **Results:** Save when not signed in opens the Quality sign-in, but after Authenticate the save is
   not replayed -- the user presses Save again. The header badge then says `ELEVATED: SUPERVISOR`.
8. **Results:** "Mark the rest as all accepted (9)" records at once, with no confirmation, and it
   accepted the hard-held `520100004`; Sign-off then shows it `READY` to release (release clears the
   tag, the Hold stays). Intended?
9. **Zero-piece members** (`520100003-01`, closed at 0; `520100009`, a just-opened basket) stay
   "No results yet": Mark-the-rest skips them and "Accept the rest (0)" is disabled, so they cannot
   be released, which should then block Close (F46, "n of m still CRT-tagged"). Is Remove the
   intended path?
10. **Deviation signed:** the success toast shows the title "Super-lot CR000001" with an empty body
    (F43's message not shown). The signature itself recorded correctly.
11. **Auto-joined members have no History row:** the super-lot History tab lists "Opened: 8 LOTs" and
    the two scanned-in members, but not `520100009` (New production) or Container 3 (Made from a
    member), which the Members tab shows.

## Walked and worked

Super-lot list and page (Members with every join kind, Results, Sign-off, History); New super-lot
wizard to Preview (every candidate correctly "Already in CR000001"); Hold Management (load a held
LOT); LOT Detail with hard Hold + CRT + super-lot chip; LOT Detail Super-lots tab and History;
Genealogy Viewer with super-lot markers on every node; Global Trace with CRT / super-lot pills;
Supervisor Dashboard "Open super-lots" tile; refusals at Machining IN (CRT, F2 word for word; Hold,
F1), Machining OUT (F4) and the dock (F12); the Quality sign-in (elevation through the "Active
Directory" source resolving to EN); Results entry (Accepted, Use as is, accept-the-rest, mark the
rest); Repack popup on a pulled-back container (opened, not used); deviation raise + signature
(`DV000001`); signed release of 10 members (CRT cleared on each, LOT history shows result, deviation,
CRT cleared, released signed EN); Reports page rendering the Super-lot report in the viewer.

## Could not reach

- **Assembly check-in refusal (F6):** the Housing line has no Assembly IN terminal; on
  `/shop-floor/assembly-in` every tagged component LOT is already at the cell ("already at this cell
  (no-op)") and the tagged casting `520100005` is refused first as "not a configured component".
  Needs a tagged component LOT that is somewhere else. The kit keeps F23's wording ("carries the tag
  onto the tray").
- **Super-lot label (`m4-label`):** "Print 4 labels" prints directly, no preview; the die-cast terminal
  has no printer ("Not printed").
- **Super-lot PDF (`m4-report`):** BUG-1.
- **Config Tool Quality Specs (`m4-config-specs`):** `MPP_MES_Demo` has no `Quality.QualitySpec` rows,
  so the screen is empty. Also, the Config Tool's login (default IdP) does not know the presenter's
  "Active Directory" test account.
- **CRT clear on LOT Detail (`m4-crt-clear`):** skipped for the trial clock.
- **Validated move refusal (F8):** not attempted (reads like F6, ruled out in T4).
