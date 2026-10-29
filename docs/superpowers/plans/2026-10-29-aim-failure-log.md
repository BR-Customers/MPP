# AIM Failure Log Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Every failed AIM attempt made while posting is switched on writes one `Audit.FailureLog` row
carrying Location, LOT and metadata, and the Audit Browser can filter and show them.

**Architecture:** FailureLog gains nullable `LocationId`/`LotId` FKs. A new status-row proc,
`Audit.FailureLog_Record`, is the Ignition write path, through a never-raising `BlueRidge.Audit.FailureLog.record`.
`AimHttp` stays transport-only and returns richer outcomes; the callers that hold the context (`postOne`,
`topupTick`, `Container`) write the row.

**Tech Stack:** SQL Server 2022 (T-SQL tests through `sql/tests/Run-Tests.ps1`), Ignition 8.3 Jython 2.7
project library, Perspective view JSON.

**Spec:** `docs/superpowers/specs/2026-10-29-aim-failure-log-design.md`

## Global Constraints

- Migration `0116_failurelog_location_lot.sql`. Re-check that `sql/migrations/versioned` has no `0116`
  before committing.
- Indexes on `Audit.FailureLog` are `ON ps_MonthlyUtc(AttemptedAt)`; FKs point out of the table only.
- `Audit.Audit_LogFailure` and `Audit.Audit_LogInterfaceCall` keep emitting no result set.
- New mutation procs:
  - no `OUTPUT` params;
  - every exit `SELECT @Status AS Status, @Message AS Message, @NewId AS NewId`;
  - every rejection runs before any transaction;
  - `RAISERROR` in CATCH.
- NQs live in Core only. Status-row NQs are `type: "Query"`.
- `appUserId` is always caller-supplied. Timers pass `Common.Util.systemAppUserId()`. No fallback.
- No FailureLog row when `AimPostingEnabled = 0`, from any caller or outcome.
- The endpoint written anywhere is the path with the token replaced by the literal `<token>` and the
  query string dropped.
- Seed strings are ASCII-only.
- Event codes: `AimPostFailed`, `AimSerialFetchFailed`. Entity codes: `Container` (post),
  `AimShipperIdPool` (fetch).
- Stage explicit paths only; no `Co-Authored-By` trailer. Apply to `MPP_MES_Dev` additively only.

## Review Focus

1. A `FailureLog.record` write that throws (DB down, bad code) must not change the outcome `postOne`
   returns. Covered by the Task 6 gateway check: point the NQ at a bad event code once and confirm that
   Complete still returns.
2. A JSON `meta` value containing quotes, backslashes or a non-ASCII customer part must still produce
   valid JSON. Covered by Task 5's `system.util.jsonEncode` (no hand-built JSON) and a Task 1 SQL test
   with `ISJSON` on a quoted value.
3. An overlong `FailureReason` (AIM's error body can be long) is truncated, not refused. Task 1 test.
4. A `LotNumber` that matches no `Lots.Lot` (renamed or typo) gives `LotId` NULL, not an error.
   Task 2 test.
5. Posting switched off yields zero rows even when the pool row is incomplete. Task 8 Dev check.

---

### Task 1: FailureLog columns, writer procs and event codes

**Files:**
- Create: `sql/migrations/versioned/0116_failurelog_location_lot.sql`
- Modify: `sql/migrations/repeatable/R__Audit_Audit_LogFailure.sql` (v1.1)
- Create: `sql/migrations/repeatable/R__Audit_FailureLog_Record.sql`
- Test: `sql/tests/0116_FailureLogAim/010_FailureLog_Record.sql`

**Interfaces:**
- Produces:
  - `Audit.FailureLog.LocationId`, `.LotId`;
  - `Audit.Audit_LogFailure(..., @LocationId BIGINT = NULL, @LotId BIGINT = NULL)`;
  - `Audit.FailureLog_Record(@AppUserId BIGINT, @LogEntityTypeCode NVARCHAR(50), @EntityId BIGINT = NULL,
    @LogEventTypeCode NVARCHAR(50), @FailureReason NVARCHAR(MAX), @ProcedureName NVARCHAR(200),
    @AttemptedParameters NVARCHAR(MAX) = NULL, @LocationId BIGINT = NULL, @LotId BIGINT = NULL)`,
    which returns `Status, Message, NewId`;
  - event codes `AimPostFailed`, `AimSerialFetchFailed`.

- [ ] **Step 1: Write the failing tests.** Capture with INSERT-EXEC into `#R (Status BIT, Message
  NVARCHAR(500), NewId BIGINT)`. Assertions:
  - The happy path with `LocationId` / `LotId` from a dynamic lookup (any `Location.Location` row; a LOT
    created with the existing test helpers, or NULL if no LOT fixture is available) gives `Status = 1`.
    The row has both ids and `ISJSON(AttemptedParameters) = 1` for `N'{"q":"a\"b"}'`.
  - Missing `@AppUserId` gives `Status = 0` and no row.
  - An unknown `@LogEventTypeCode` gives `Status = 0`, with a message naming the code.
  - An unknown `@LogEntityTypeCode` gives `Status = 0`.
  - A 900-char `@FailureReason` gives `Status = 1` and a stored `LEN(FailureReason) <= 500`.
  - `Audit_LogFailure` with `@LocationId` stores it and emits no result set. Check with INSERT-EXEC into
    a one-column table, which must raise nothing and capture 0 rows.
  - Both new event codes exist.
- [ ] **Step 2: Run and confirm it fails.** Run `.\sql\tests\Run-Tests.ps1 -DatabaseName MPP_MES_AimFL
  -Filter "0116_FailureLogAim"`. It should fail because the proc doesn't exist.
- [ ] **Step 3: Write the migration.** It holds the columns, the two filtered aligned indexes
  (`IX_FailureLog_Location_AttemptedAt`, `IX_FailureLog_Lot_AttemptedAt`), the event codes (next free Id,
  `0113` pattern), the post-condition THROW and the `SchemaVersion` row.
- [ ] **Step 4: Update the procs.** `Audit_LogFailure` goes to v1.1. `FailureLog_Record` follows
  `sql/scripts/_TEMPLATE_stored_procedure.sql`:
  - it inlines the insert, with a comment that it mirrors `Audit_LogFailure`;
  - it truncates the reason with `Audit.ufn_TruncateActivity`;
  - it does not log its own refusals to FailureLog, to avoid recursion.
- [ ] **Step 5: Run and confirm it passes.** The same command should report 0 failed.
- [ ] **Step 6: Commit.**

### Task 2: `InterfaceLog_Record` and pool context in `GetForPost`

**Files:**
- Create: `sql/migrations/repeatable/R__Audit_InterfaceLog_Record.sql`
- Modify: `sql/migrations/repeatable/R__Lots_AimShipperIdPool_GetForPost.sql`
- Modify: `sql/tests/0049_AimIntegration/030_postback_procs.sql` (widen the `GetForPost` capture table)
- Test: `sql/tests/0116_FailureLogAim/020_InterfaceLog_Record_and_GetForPost.sql`

**Interfaces:**
- Produces:
  - `Audit.InterfaceLog_Record`, with the same parameters as `Audit_LogInterfaceCall`, returning
    `Status, Message, NewId` (the InterfaceLog Id);
  - `GetForPost` gains trailing columns `LocationId` (container `CurrentLocationId`) and `LotId`
    (`Lots.Lot` where `LotName = p.LotNumber`).

- [ ] **Step 1: Write the failing tests.**
  - `InterfaceLog_Record` returns `Status = 1` and a `NewId` that matches an `Audit.InterfaceLog` row with
    the passed `LocationId` / `LotId`.
  - `GetForPost` on a pool row whose `LotNumber` names a real LOT returns that `LotId` and the container's
    location.
  - A `LotNumber` naming no LOT gives `LotId` NULL.
  - A row with no container gives both NULL.
- [ ] **Step 2: Run and confirm it fails.**
- [ ] **Step 3: Implement both procs.** Bump the version and change-log lines in the headers.
- [ ] **Step 4: Run** `-Filter "0049_AimIntegration|0116_FailureLogAim"`. Expect 0 failed.
- [ ] **Step 5: Commit.**

### Task 3: Audit Browser reads

**Files:**
- Modify:
  - `sql/migrations/repeatable/R__Audit_FailureLog_List.sql` (v3.1)
  - `sql/migrations/repeatable/R__Audit_FailureLog_GetByEntity.sql` (v2.1)
  - `sql/tests/02_audit_readers/070_FailureLog_List.sql`
  - `sql/tests/02_audit_readers/060_FailureLog_GetByEntity.sql` (widen captures)
- Test: those two files, plus a new `sql/tests/0116_FailureLogAim/030_FailureLog_List_filters.sql`

**Interfaces:**
- Produces:
  - both reads gain trailing `LocationId, LocationName, LotId, LotName`;
  - `FailureLog_List` gains `@LocationId BIGINT = NULL` and `@LotNameLike NVARCHAR(50) = NULL`, placed
    after `@FailureReasonLike` and before nothing else.

- [ ] **Step 1: Write the failing tests.**
  - The location filter returns only rows at that location.
  - A LOT-name substring returns only rows with that LOT.
  - A NULL filter leaves results unchanged.
  - The new columns resolve names.
- [ ] **Step 2: Run, then implement (LEFT JOINs), then run** `-Filter "02_audit_readers|0116"`. Expect 0
  failed.
- [ ] **Step 3: Commit.**

### Task 4: Full suite and Data Model doc

**Files:**
- Modify:
  - `MPP_MES_DATA_MODEL.md` (FailureLog columns; new procs; revision row);
  - the extended-properties output of `node sql/scripts/gen_extended_properties.js`.

- [ ] **Step 1: Run the full suite** with `.\sql\tests\Run-Tests.ps1 -DatabaseName MPP_MES_AimFL`.
  Expect exit 0, 0 failed, and an assertion count above the last recorded baseline (5,301 plus later
  additions; read the latest figure in `PROJECT_STATUS.md` first). Compare the count, not just the failures.
- [ ] **Step 2: Update the doc, regenerate the extended properties, and run the suite again.** Expect it
  still green.
- [ ] **Step 3: Commit.**

### Task 5: Ignition write path (NQs, `FailureLog.record`, `AimHttp`)

**Files:**
- Create: `ignition/projects/Core/ignition/named-query/audit/FailureLog_Record/{query.sql,resource.json}`
- Create: `ignition/projects/Core/ignition/named-query/audit/InterfaceLog_Record/{query.sql,resource.json}`
- Modify: `ignition/projects/Core/ignition/named-query/audit/FailureLog_List/*` (two new params)
- Modify: `ignition/projects/Core/ignition/script-python/BlueRidge/Audit/FailureLog/code.py`
- Modify: `ignition/projects/Core/ignition/script-python/BlueRidge/Lots/AimHttp/code.py`

**Interfaces:**
- Produces:
  - `BlueRidge.Audit.FailureLog.record(procedureName, failureReason, entityTypeCode, eventTypeCode,
    appUserId, entityId=None, locationId=None, lotId=None, meta=None) -> dict|None`, which never raises;
  - `AimHttp.postingEnabled() -> bool`;
  - `AimHttp.nextSerial()` returns `{ok, serial, error, disabled, httpStatus, endpoint, interfaceLogId}`;
  - `AimHttp.postSerial(serial, customerPart, qty, lot, locationId=None, itemId=None, lotId=None)` returns
    `{ok, error, disabled, httpStatus, endpoint, interfaceLogId}`;
  - `FailureLog.search(filter)` reads `filter.locationId` and `filter.lotName`.

- [ ] **Step 1: Write the NQs.** Copy the shape of an existing Core status-row NQ (`type: "Query"`) and
  pass parameters by name; `sqlType` follows each proc parameter.
- [ ] **Step 2: Write `record`.**
  - Use `requireAppUserId` and `system.util.jsonEncode(meta)` when `meta` is not None.
  - Call through `BlueRidge.Common.Db.execMutation("audit/FailureLog_Record", ...)`.
  - Catch `(Exception, java.lang.Exception)`. On a caught error or a `Status = 0` row, write a gateway-log
    `error` that names `procedureName` and the reason.
- [ ] **Step 3: Change `AimHttp`.**
  - `_post` returns `(ok, reply, error, httpStatus)`.
  - Add `_redactEndpoint(base, company, action)` returning `"%s/mes/floor/%s/<token>/%s" % (base,
    company, action)`.
  - `_logAim(action, detail, ok, err, locationId=None, itemId=None, lotId=None)` calls
    `audit/InterfaceLog_Record` through `execMutation` and returns `NewId` or `None`. It is still best
    effort.
  - Disabled returns carry `disabled: True`; not-configured returns carry `disabled: False` and the
    redacted endpoint where it can be built.
- [ ] **Step 4: Check the syntax in memory** (not `py_compile` in the tree, per memory
  `feedback_ignition_no_pycompile_in_project_tree`): `python -c "import ast,sys;
  [ast.parse(open(f).read()) for f in sys.argv[1:]]" <files>` with Python 2-compatible syntax eyeballed
  (Jython 2.7 uses `except X, e`).
- [ ] **Step 5: Commit.**

### Task 6: Callers write the rows

**Files:**
- Modify:
  - `ignition/projects/Core/ignition/script-python/BlueRidge/Lots/AimPost/code.py`;
  - `ignition/projects/Core/ignition/script-python/BlueRidge/Lots/Container/code.py`;
  - `ignition/projects/Core/ignition/script-python/BlueRidge/Lots/AimPoolGateway/code.py`.

**Interfaces:**
- Consumes everything Task 5 produces.
- Produces `AimPost.postOne(aimShipperId, appUserId, terminalLocationId=None, caller="complete")` with
  the same return shape as today.

- [ ] **Step 1: `postOne`.**
  - Add a private `_logFailure(row, reason, httpRes, appUserId, terminalLocationId, caller)` that returns
    straight away when `not AimHttp.postingEnabled()`. Otherwise it calls `FailureLog.record`:
    - procedure `BlueRidge.Lots.AimPost.postOne`;
    - entity `Container`, `row ContainerId`, event `AimPostFailed`;
    - the `LocationId` / `LotId` from the row;
    - meta keys `aimShipperId, containerId, endpoint, httpStatus, attempt, terminalLocationId,
      interfaceLogId, caller`. `attempt` is `(PostAttempts or 0) + 1` for an HTTP attempt, else
      `PostAttempts`.
  - Call `_logFailure` on `not_found`, `incomplete_payload`, `failed` (non-disabled) and both exception
    branches.
  - Pass `locationId` / `itemId` / `lotId` into `postSerial`. `itemId` isn't in `GetForPost`; pass None
    unless it is already cheap to add.
- [ ] **Step 2: The other callers.**
  - `retryTick` calls `postOne(serial, BlueRidge.Common.Util.systemAppUserId(), None, "retry")`.
  - `Container.complete` passes `appUserId, terminalLocationId, "complete"`.
  - `validateCrt` passes `appUserId, terminalLocationId, "validateCrt"`.
  - The `except` branches around `postOne` in both call `FailureLog.record` when posting is on: entity
    `Container`, `containerId`, event `AimPostFailed`, no location or LOT, meta `{aimShipperId, caller,
    terminalLocationId}`.
- [ ] **Step 3: `topupTick`.** When a fetch fails and `not res.get("disabled")`, call `record`:
  - procedure `BlueRidge.Lots.AimPoolGateway.topupTick`;
  - entity `AimShipperIdPool`, event `AimSerialFetchFailed`, system user;
  - meta `{endpoint, httpStatus, interfaceLogId, depth, target, fetchedThisTick}`.

  Then break. The exception branch also records when posting is on. Pass
  `fetchedInterfaceLogId=res.get("interfaceLogId")` to `AimPool.topup`, after checking its signature.
- [ ] **Step 4: Grep that no other `postOne(` call site exists** (`ContainerRework` goes through
  `Container.complete`). Then run the in-memory syntax check.
- [ ] **Step 5: Commit.**

### Task 7: Audit Browser view and detail popup

**Files:**
- Modify: `ignition/projects/MPP_Config/com.inductiveautomation.perspective/views/BlueRidge/Views/Audit/FailureLog/view.json`
- Modify: the `FailureDetail` popup `view.json` (find it under `Components/Popups/FailureDetail` in
  whichever project holds it)

- [ ] **Step 1: Edit the grid and filters.**
  - Add `LocationName` and `LotName` grid columns, using the full column schema (memory
    `feedback_ignition_table_column_full_schema`).
  - Add a Location dropdown (options `{label, value}`, sourced from an existing location-list
    NQ/script) and a LOT text input with `deferUpdates: false` to the filter panel.
  - Both write into the existing filter custom prop, pre-declared with defaults `locationId: null,
    lotName: ""`.
  - Reset clears both.
  - Add `locationName` and `lotName` to the row-click popup params.
  - Use byte-level edits that respect the file's unicode escapes and check that the JSON parses.
- [ ] **Step 2: Edit the popup.** Add `locationName` / `lotName` params and two label rows.
- [ ] **Step 3: Commit.**

### Task 8: Apply to Dev, scan, verify, status

- [ ] **Step 1: Apply to `MPP_MES_Dev` additively.** Run `0116`, then the changed repeatables (sqlcmd with
  `-C` for the dev cert). Check `dbo.SchemaVersion` for the `0116` row.
- [ ] **Step 2: Scan the gateway.** Run `.\scan.ps1`. Expect no errors in `wrapper.log` for Core or
  MPP_Config. The Audit Browser loads with the Location and LOT columns and filters (browser pane).
- [ ] **Step 3: Run a deliberate failure on Dev.**
  1. Snapshot `Lots.AimPoolConfig`.
  2. Set `AimPostingEnabled = 1` and `AimBaseUrl = 'http://127.0.0.1:9'`.
  3. Run `AimPost.postOne` for a Dev completed container's serial through the gateway: the script
     console isn't available, so use a temporary Perspective button or WebDev, or invoke through a
     message handler. If none is practical, run the equivalent `FailureLog_Record` NQ call and say so.
  4. Expect exactly one new FailureLog row, with Location, LOT and meta including `interfaceLogId`.
  5. Set `AimPostingEnabled = 0` and repeat. Expect no new row.
  6. Restore the snapshot.
- [ ] **Step 4: Update `PROJECT_STATUS.md`.** Replace the OPEN TODO entry with a dated "built, not
  deployed" entry. Commit.
