# Handoff: AIM failure logging + Assembly OUT shipping-label reprint (+ benched Shipping Dock removal)

**Date:** 2026-09-17 · **Requested by:** MPP (2026-09-16) · **Status:** investigated and designed, not built.
The line inventory sidebar from the same request is being built separately; see
`docs/superpowers/specs/2026-09-17-line-inventory-sidebar-design.md`.

Paths are relative to the repo root. Script modules are under
`ignition/projects/Core/ignition/script-python/BlueRidge/`. The findings come from reading the code; nothing
was tested against a gateway.

**Migration numbers:** `0090` (OEE spec) and `0091`/`0092` (line inventory) are claimed. Take the next free
one and re-check before building.

---

## 1. AIM failure logging

### The request (verbatim intent)
Add Failure Log auditing to the AIM integration stack. Each failure row should include the Location, the LOT
and any "meta data".

### Decisions already made with Jacques
- **Log every failed attempt:**
  - post;
  - timer retry;
  - pool top-up fetch;
  - bad or mismatched reply;
  - AIM disabled or not configured;
  - exceptions.

  Not just "retries exhausted".
- **Add real columns.** `Audit.FailureLog` gets nullable `LocationId` and `LotId` (FKs), so both can be
  filtered and shown by name in the Audit Browser. Everything else goes into the existing JSON
  `AttemptedParameters` column: container id, AIM serial, endpoint without the token, HTTP status, attempt
  count, terminal, and the matching InterfaceLog id.
- **Attribution:**
  - the operator when there is one;
  - **AppUser 1** (the bootstrap System user) when the failure comes from a gateway timer, because
    `FailureLog.AppUserId` is NOT NULL.
- **Known volume:** while AIM is down, the retry timer writes a row per owed container on every tick. Jacques
  accepted "every failed attempt" knowing this.

### What exists today
- **AIM HTTP calls.** The only place they happen is `Lots/AimHttp`.
  - `nextSerial()` (L225) and `postSerial()` (L250) both check `AimPostingEnabled` (L232, L260), and neither
    raises.
  - Each call is logged to `Audit.InterfaceLog` by `_logAim` (L192), via the NQ
    `audit/Audit_LogInterfaceCall`.
  - The log write swallows its own errors (`except: pass`, L208).
  - The disabled and not-configured returns (L232-235, L260-263) are **not logged at all**.
- **`Lots/AimPost`:**
  - `postOne()` (L22) reads the payload, calls `postSerial`, then `AimPool.recordPostResult`. An incomplete
    payload stores `LastPostError` with no HTTP call (L64-74).
  - Exceptions go to the gateway log only (L85-90).
  - `retryTick()` (L93) is the retry sweep; each row's failure is caught and written to the gateway log only.
- **`Lots/AimPoolGateway`:**
  - `topupTick()` (L26) stops on the first failure with a warning in the gateway log (L52).
  - `alarmTick()` (L81) sends `aim-pool-alarm`, but **no view listens for it**.
  - `placeOnHold` / `releaseFromHold` / `update` (L147-161) are simulation stubs (a failed InterfaceLog row,
    Status 0) and **nothing calls them**.
  - The docstring's "AimHold/AimUpdate message handlers" don't exist.
- **Gateway timers** (MPP project `ignition/timer/`): `AimPostTimer` (runs `retryTick`), `AimPoolTopupTimer`,
  `AimPoolAlarmTimer`.
- **Call chain from the operator:**
  1. The operator presses Complete (`AssemblySerialized/view.json:1000`, `AssemblyNonSerialized:1352`). The
     PLC path goes through `Workorder/Assembly/code.py:159/307/394`.
  2. `Lots/Container.complete()` (L55) runs `Lots.Container_Complete`, which claims an `AimShipperId` from
     `Lots.AimShipperIdPool`.
  3. `ShippingDispatcher.dispatch` prints the label. This is the only step that is actually async
     (`invokeAsynchronous`, `ShippingDispatcher/code.py:120`).
  4. If the container isn't held for CRT, `AimPost.postOne` runs **synchronously** (L128, 5 s timeout), and
     the result goes into `result["AimPost"]`.
  5. The CRT path is `validateCrt` (L157) followed by `postOne` (L191).
  6. `Container.complete` / `validateCrt` catch exceptions and return `outcome: "failed"` (L129-134,
     L192-197).
- **UI:**
  - AssemblySerialized toasts "AIM not updated ... will retry automatically".
  - `Popups/CrtValidation:341` toasts "AIM post pending retry".
  - The PLC path gets nothing.
  - The supervisor surface is `MPP/.../ShopFloor/AimPoolConfig`, which shows the backlog and `LastPostError`.
- **FDS-01-014 gap** (`MPP_MES_FDS.md:340`): the FDS says `sendRequestAsync` to a gateway handler, with a
  FailureLog write on exhaustion. Neither is implemented. The pool is the documented "pre-fetched buffer"
  exception (L352). This is only for context: Jacques did **not** ask to make the post async.
- **`Audit.InterfaceLog`** (`0001...sql:201`), written by `Audit.Audit_LogInterfaceCall`
  (`R__Audit_Audit_LogInterfaceCall.sql:12`).
  - The proc does not return the new Id (`SCOPE_IDENTITY` is set but never selected).
  - `AimPool.topup` accepts `fetchedInterfaceLogId`, but `topupTick` never passes it.
  - The request payload is the full URL **including the path token**, so do not copy it into FailureLog.
- **`Audit.FailureLog`** (`0001...sql:219`) has these columns:
  - `Id`, `AttemptedAt`;
  - `AppUserId` (NOT NULL FK);
  - `LogEntityTypeId`, `EntityId`, `LogEventTypeId`;
  - `FailureReason NVARCHAR(500)`, `ProcedureName NVARCHAR(200)`;
  - `AttemptedParameters NVARCHAR(MAX)`.

  It has no LocationId and no LotId.
  - **Writer proc:** `Audit.Audit_LogFailure` (`R__Audit_Audit_LogFailure.sql:17`). It emits no result set
    because it runs inside mutation transactions (FDS-11-011).
  - **Nothing can write it from Ignition today:** there is no NQ and no Python writer.
    `Audit/FailureLog/code.py` is read-only.
- **Audit Browser:** `MPP_Config/.../Views/Audit/FailureLog/view.json`.
  - Grid columns (L739-775): Timestamp, User, Entity Type, Procedure, Failure Reason.
  - `FailureLog_List` (`R__Audit_FailureLog_List.sql:44`, TOP 1000) already returns `AttemptedParameters`,
    but the grid doesn't show it.

### Proposed build
1. **Migration:** `ALTER TABLE Audit.FailureLog ADD LocationId BIGINT NULL FK -> Location.Location,
   LotId BIGINT NULL FK -> Lots.Lot`.
   - FailureLog may be partitioned (OI-35 B2): check its index alignment before adding FKs or indexes. See
     memory `project_mpp_partition_aligned_pk`.
   - Document the columns in `MPP_MES_DATA_MODEL.md` and regenerate the extended properties
     (`node sql/scripts/gen_extended_properties.js`).
2. **`Audit.Audit_LogFailure`:** add optional `@LocationId`, `@LotId` (default NULL, so existing callers are
   untouched).
3. **New status-row wrapper proc** that Ignition can call, e.g. `Audit.FailureLog_Record`.
   - It returns `SELECT Status, Message`.
   - It needs an NQ of type `Query` in Core: `audit/FailureLog_Record`.
   - Reason: the silent `Audit_LogFailure` can't be an NQ query, and must keep emitting nothing.
4. **Python writer:** `BlueRidge.Audit.FailureLog.record(procedureName, reason, entityTypeCode, entityId=None,
   locationId=None, lotId=None, appUserId=None, meta=None)`.
   - It never raises: use `except (Exception, java.lang.Exception)`.
   - It defaults `appUserId` to the session user, or to 1 in gateway scope.
   - It JSON-encodes `meta`.
5. **Call it from every failure path listed above:**
   - `AimHttp` transport, non-2xx, bad-reply and echo-mismatch returns, plus the currently-unlogged disabled
     and not-configured returns;
   - `AimPost.postOne` (incomplete payload, failed post, exception);
   - `AimPost.retryTick` (per row);
   - `AimPoolGateway.topupTick`;
   - `Container.complete` / `validateCrt` exception branches.

   LOT = the container's LOT. Location = the terminal or cell. `LogEntityTypeCode` should probably be
   `Container` (check `Audit.LogEntityType` seeds); add a `LogEventType` such as `AimPostFailed` if needed.
6. **Audit Browser:**
   - `FailureLog_List` / `_GetByEntity` return the resolved location and LOT codes/names (add them at the end
     of the column list and widen the test captures).
   - The grid gains Location and LOT columns.
   - The detail popup shows the JSON.
   - Existing views are Designer edits.
7. **Tests:** SQL tests for the new columns, the wrapper proc and the list read. Verify manually by pointing
   AIM at a bad endpoint in Dev.

### Side notes (not asked for)
The alarm nobody listens to, the unused hold/release stubs, and the synchronous post are all worth raising
with Jacques; do not fix them silently.

---

## 2. Reprint the shipping label at Assembly OUT (elevated)

### The request (verbatim intent)
Add a reprint button to Assembly OUT. It reprints the **shipping label**, NOT a LOT label, and requires
elevated access. AD roles are being added next week, and the reprint must need elevation **above team lead**.

### Decisions already made with Jacques
- **The role check** (the first real one in the system) is a table of allowed roles per action code.
  - With **no roles listed for the action**, any valid AD user may approve, which is today's behaviour.
  - Next week the rule becomes a data change, not a code change.
- **Picking the label:** a popup lists the **recent shipping labels at this cell** (the last ~10 that aren't
  voided: serial, part description, time). The operator picks one and gives a reason, then elevation runs.

### What exists today
- **Shipping label print:**
  - `R__Lots_Container_Complete.sql` claims the AIM id (L146-161) and inserts `Lots.ShippingLabel` with
    `Initial=1` (L210-214).
  - The ZPL comes from `R__Lots_ufn_ShippingLabelZpl.sql` (L63: serial = `N'13218001' + RIGHT(@Aim, 8)`);
    the template seed is `0054_shipping_label_zpl_and_template.sql`.
  - Dispatch goes through `Lots/ShippingDispatcher.dispatch(shippingLabelId, terminalLocationId)` (L101),
    which calls `LabelTransport` and the NQs `lots/ShippingLabel_RecordDispatch` / `_MarkDispatch`.
  - The multi-printer station uses `Workorder/Assembly.completeBoxToPrinter` (L385).
- **A reprint already exists in SQL:** `R__Lots_ShippingLabel_Reprint.sql`, called by the NQ
  `lots/ShippingLabel_Reprint` and by `Lots/Shipping.reprintLabel(shippingLabelId, printReasonCode=None,
  appUserId=None, terminalLocationId=None)` (L34).
  - It inserts a **new** `Lots.ShippingLabel` row with `Initial=0`, `PrintReasonCode`, `PrintedByUserId`,
    `TerminalLocationId` and freshly rendered ZPL (L50-51). The original row is not changed.
  - It reuses the **same `AimShipperId`**, so the serial is the same.
  - It audits `ShippingLabelReprinted` via `Audit.Audit_LogOperation` (L53-56).
  - The table is defined in `0028_arc2_phase6_assembly.sql:109-129`. There is no PrintCount column; it has
    `PrintAttempts`, `LastPrintError`, `IsVoid`, `ZplContent` (0054) and `RfidTag` (0070).
  - **Check before building:** does `reprintLabel` also dispatch to a printer, or only insert the row? If it
    only inserts, call `ShippingDispatcher.dispatch(newId, terminalLocationId)` afterwards.
- **The only reprint UI today** is `ShippingDock/view.json:423` (`ReprintButton`). The operator types or
  scans a ShippingLabelId; there is no elevation and no reason.
- **Assembly OUT is two views:** `Views/ShopFloor/AssemblySerialized` and `AssemblyNonSerialized`. The button
  goes on both (header row, next to `BtnCrtValidation`). Existing views are Designer edits.
- **How elevation works** (`Common/Session/code.py`):
  1. The handler checks `isElevated(session)`; otherwise it calls `requireElevation(session, code, label,
     params)` (L192). That stores `session.custom.pendingElevatedAction` for 120 s and opens
     `Components/PlantFloor/ElevationModal`.
  2. The modal calls `Location/AppUser.elevate(...)` (L317), which runs `system.security.validateUser` against
     the `"Active Directory"` user source (L278) and then `Location.AppUser_AuthenticateAd`.
  3. The `AppHeaderLarge:462` `elevationResult` handler runs `beginElevatedWindow` (L99, which makes the
     supervisor the session user for 300 s by design) and then `dispatchElevatedAction`. That replays the
     request as a page message registered in `_ELEVATED_REPLAY_MESSAGES` (L212).

  Reference implementation: `LotDetail/view.json` L2309 (gate) and L2338 (replay handler). A new protected
  action needs two things: an entry in `_ELEVATED_REPLAY_MESSAGES` and the guard at the top of the handler.
  There is also a stateless one-shot form, `elevate()` followed by the mutation with the returned
  `appUserId` (`Location/ClosureMode` L30/L51, `Popups/MoveOverride:256`, `Popups/CrtValidation:209`).
- **No role is checked anywhere.**
  - `R__Location_AppUser_AuthenticateAd.sql` (L11-21) only checks that the AD account maps to an active
    AppUser, returns `IgnitionRole`, and audits `ElevationGranted`/`ElevationDenied`. Its comment says the UI
    should decide by role, but no UI code does.
  - `IgnitionRole` is free text on AppUser (edited in `MPP_Config/.../Popups/OperatorEditor:420`).
  - There are no role constants and no tiers. **Today any active AD-mapped user can approve every protected
    action.**
- **Existing elevated actions:** `DowntimeReason/Edit/Void`, `SortCageMigrate`, `CrtToggle`, `DieMount`,
  `Changeover`, `MoveOverride`, `CrtValidation`, `SupervisorAccess`. None of them is role-gated.
- **LOT label reprint** (`R__Lots_LotLabel_Reprint.sql`, `Lots/LotLabel.reprint`) is a different thing. It is
  on LotDetail and ReceivingDock, and is not gated either. Don't touch it.
- Memory `project_mpp_ad_account_coverage`: die setters do have AD accounts.

### Proposed build
1. **Migration:** a new table `Location.ElevationActionRole (Id BIGINT IDENTITY PK, ActionCode NVARCHAR(50),
   IgnitionRole NVARCHAR(100), DeprecatedAt DATETIME2(3) NULL, UNIQUE (ActionCode, IgnitionRole))`.
   - Seed nothing, so the reprint is open until next week.
   - Consider a code table for action codes if that fits the conventions (no free-text enums: check
     `sql_best_practices_mes.md`).
2. **`Location.AppUser_AuthenticateAd`:** add an optional `@ActionCode`.
   - When active rows exist for that action and the user's `IgnitionRole` is not among them, deny with a
     clear message and audit `ElevationDenied`.
   - With no rows, or no `@ActionCode`, behave exactly as today.
   - Thread `actionCode` through `AppUser.elevate(...)` and `ElevationModal` (from
     `pendingElevatedAction.code`).
3. **New read proc:** `Lots.ShippingLabel_ListRecentByCell @CellLocationId, @TopN = 10`, returning
   non-voided labels at or under the cell with ET times. Plus its NQ and a script wrapper.
4. **New popup:** `Components/PlantFloor/ShippingLabelReprint`, with the list, a reason dropdown (existing
   `PrintReasonCode` values; check the code table) and a Reprint button.
   - The button gates with `requireElevation(session, "ShippingLabelReprint", ...)`.
   - The replay handler calls `Shipping.reprintLabel(...)`, then dispatches.
   - Register `ShippingLabelReprint` in `_ELEVATED_REPLAY_MESSAGES`.
5. **Assembly OUT screens:** a *Reprint Shipping Label* button on both views that opens the popup (Designer).
6. **Change** the print-failure toast in `Lots/Container/code.py:103` from "Reprint from the Shipping Dock"
   to "Reprint from Assembly OUT".
7. **Tests:** SQL for the role gate (no rows = allow; rows + wrong role = deny + audit; rows + right role =
   allow) and for the recent-list proc.
8. **Next week:** once IT names the AD groups, insert the allowed roles for `ShippingLabelReprint`, a data
   change only. Jacques must say which roles count as "above team lead".

---

## 3. BENCHED -- remove the Shipping Dock screen

Jacques asked to remove the Shipping Dock screen entirely, then benched it (2026-09-17). **Do not act
without asking him.** What removal would take away:
- **Ship Container** (`Lots/Shipping.ship`): scan, check the container is complete, not on hold and has a
  valid label, then mark it shipped. It is the **only** UI that marks a container shipped.
- **Void Label** (`Shipping.voidLabel`, `R__Lots_ShippingLabel_Void.sql`): the only UI that voids a shipping
  label.
- **Reprint Label:** replaced by section 2 above.
- Its queue, manifest and stats panels are still placeholders ("read pending in dev").

References:
- the route in `MPP/.../page-config/config.json:115`;
- the terminal-screen option in `Location/AttributeOptions/code.py:36` (`/shop-floor/shipping`);
- the print-failure toast in `Container/code.py:103`;
- `PrintFailureBanner` uses `Shipping.ackBanner`, which is independent of the screen.

**Open question for Jacques:** drop Ship/Void entirely, or move Void into the elevated reprint popup?

---

## Project rules the next agent must follow
- Read `CLAUDE.md` and `PROJECT_STATUS.md`.
- **SQL:**
  - No OUTPUT params.
  - Status-row mutation procs; the NQ for one is `type: Query`.
  - `EXEC` arguments are literals or variables only.
  - Seeds and data strings are ASCII only.
  - Business rules live in SQL, never Python.
- **Views:**
  - Existing `view.json` files are Designer edits; new views are files followed by `.\scan.ps1`.
  - NQs live in the Core project only.
- **Tests:** run only against `MPP_MES_Test` (`.\sql\tests\Run-Tests.ps1`). Never reset `MPP_MES_Dev`.
- **Git:**
  - Branch `jacques/working`.
  - Explicit `git add` paths only.
  - No Claude co-author trailer.
- **Prod:** deploys follow `prod-release-context-pack/`.
- Before building, brainstorm and confirm with Jacques. Several design points above are proposals, not
  approvals.
