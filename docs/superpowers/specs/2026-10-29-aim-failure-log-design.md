# AIM integration failures in the Failure Log -- design

**Date:** 2026-10-29 · **Requested by:** MPP (2026-09-16) · **Status:** design agreed with Jacques, not built.
**Background:** `notes/2026-09-17_handoff-aim-failure-log-and-shipping-reprint.md` section 1 (findings with
file and line references). Paths are relative to the repo root; script modules live under
`ignition/projects/Core/ignition/script-python/BlueRidge/`.

## Intent

MPP wants every AIM (Honda EDI) failure to land in `Audit.FailureLog`, carrying **what** failed, **where**
(the Location), **which LOT**, and **why** (the reason plus the metadata). Today nothing in Ignition can
write `Audit.FailureLog`. AIM failures reach only `Audit.InterfaceLog`, and some reach nothing but the
gateway log, so a supervisor can't answer "which containers at this cell didn't make it to AIM, and why?"
from the Audit Browser.

Jacques's test for the design: "so long as we have what, where and why covered."

## Goals

- One `Audit.FailureLog` row for **every failed AIM attempt made while AIM posting is switched on**:
  - a post from Complete, from CRT validation, or from the timer retry;
  - a pool top-up serial fetch;
  - a non-2xx reply, an unexpected reply, or a mismatched echo;
  - "not configured" (posting is on but the URL, company or token is missing);
  - an incomplete payload or a missing pool row;
  - an exception.
- Real, filterable `LocationId` and `LotId` columns on `Audit.FailureLog`, shown by name in the Audit
  Browser.
- Everything else in the `AttemptedParameters` JSON: container id, AIM serial, endpoint without the path
  token, HTTP status, attempt count, terminal, and the matching `InterfaceLog` id.
- A general-purpose way for Ignition to write a Failure Log row (proc, NQ and Python writer). AIM is the
  first caller, but nothing in it is AIM-specific.

## Non-goals and anti-goals

- **No row when AIM posting is switched off** (`Lots.AimPoolConfig.AimPostingEnabled = 0`), from any
  caller: timer, Complete or CRT. Jacques decided this on 2026-10-29. Posting ships switched off and has
  been switched off on purpose, so a row per owed container per minute would flood the table with no end
  date. **An outage with posting switched on is different and is logged in full.** Jacques accepted that
  `retryTick` writes up to 50 rows a minute, and the top-up timer one more, while AIM is down. There is no
  dedup or throttle. This applies to the "no AIM call was made" outcomes too (incomplete payload, missing pool row): if
  posting is off, nothing is logged.
- **No duplicate rows.** One failed attempt is one row. The transport layer (`AimHttp`) does not write
  FailureLog; it returns the details to the caller that knows the context.
- A FailureLog write must **never** break or slow down a container completion, a CRT validation or a
  timer. The writer never raises.
- Not in scope (side notes from the handoff, raised separately, not fixed here):
  - the `aim-pool-alarm` message that no view listens for;
  - the unused `placeOnHold` / `releaseFromHold` / `update` stubs;
  - the synchronous post on Complete (FDS-01-014 says async).
- Not a change to the AIM retry behaviour, to timer enablement, or to `InterfaceLog`'s existing callers.

## Constraints

- `CLAUDE.md` conventions apply:
  - the proc template;
  - no `OUTPUT` params, and mutation procs end in a single status row;
  - the caller passes `appUserId`, with no fallback inside entity functions;
  - NQs live in Core only;
  - ASCII-only seed strings;
  - audit Description convention where relevant.
- `Audit.FailureLog` is partitioned on `ps_MonthlyUtc(AttemptedAt)` (migration `0020`), with
  `PK_FailureLog (Id, AttemptedAt)` and a clustered `CIX_FailureLog_AttemptedAt`. Any new index must be
  partition-aligned (`ON ps_MonthlyUtc(AttemptedAt)`). FKs pointing **out** of the table are fine; that's
  the `0113` InterfaceLog pattern.
- `Audit.Audit_LogFailure` must keep emitting **no** result set, because mutation procs call it inside
  transactions.
- `Audit.Audit_LogInterfaceCall` must keep emitting no result set, because `Lots.LotLabel_RecordDispatch`
  calls it from inside SQL.
- Dev (`MPP_MES_Dev`) and the gateway are shared with other sessions. Apply additively; never reset.

## Decided

### SQL

1. **Migration `0116_failurelog_location_lot.sql`** (re-check that `0116` is still free just before
   committing):
   - `Audit.FailureLog` gets nullable `LocationId BIGINT` (FK to `Location.Location`) and `LotId BIGINT`
     (FK to `Lots.Lot`). Guard each with `COL_LENGTH`; no backfill.
   - Two filtered, partition-aligned indexes for the browser filters:
     - `(LocationId, AttemptedAt DESC) WHERE LocationId IS NOT NULL`;
     - `(LotId, AttemptedAt DESC) WHERE LotId IS NOT NULL`;
     - both `ON ps_MonthlyUtc(AttemptedAt)`.
   - Seed two `Audit.LogEventType` codes, inserting the next free Id directly (the `0113` pattern):
     - `AimPostFailed` -- "An attempt to post a container's serial to AIM failed";
     - `AimSerialFetchFailed` -- "An attempt to fetch a new serial from AIM for the pool failed".
   - Post-condition `THROW` if the columns did not land, then the `SchemaVersion` row.
2. **`Audit.Audit_LogFailure` v1.1:** optional `@LocationId BIGINT = NULL`, `@LotId BIGINT = NULL`,
   written to the new columns. Existing callers are untouched. It still emits nothing.
3. **New `Audit.FailureLog_Record`:** a status-row wrapper Ignition can call. Its parameters mirror
   `Audit_LogFailure`, including the two new ones.
   - It validates that `@AppUserId`, `@LogEntityTypeCode`, `@LogEventTypeCode`, `@FailureReason` and
     `@ProcedureName` are present, and that both codes resolve. A bad code is **refused**, not defaulted
     to 1 the way the silent proc does.
   - It inserts directly. It is the same insert as `Audit_LogFailure`, inlined per the
     INSERT-EXEC/status-row rule, with a comment saying which proc it mirrors.
   - It truncates `@FailureReason` to 500 characters with `Audit.ufn_TruncateActivity` rather than
     failing on overflow.
   - It ends with `SELECT @Status AS Status, @Message AS Message, @NewId AS NewId`.
4. **New `Audit.InterfaceLog_Record`:** a status-row wrapper of `Audit_LogInterfaceCall` (same
   parameters, insert inlined, with a mirror comment) that returns the new InterfaceLog `Id` as `NewId`.
   Only `AimHttp` uses it. Every other InterfaceLog caller is unchanged.
5. **`Lots.AimShipperIdPool_GetForPost`:** add `LocationId` and `LotId` **at the end** of the column
   list.
   - `LocationId` is the container's `CurrentLocationId`.
   - `LotId` is the LOT whose name was posted: resolve the pool row's frozen `LotNumber` against
     `Lots.Lot.LotName`. Don't re-derive it from the trays: the trays can change between completion and a
     retry, and the row must name the LOT AIM was told about. *(Claude's call.)*
   - Both are NULL when the pool row has no container or no `LotNumber`. An incomplete-payload row with no
     LOT is truthful: there was no LOT to send. *(Claude's call.)*
6. **`Audit.FailureLog_List` and `Audit.FailureLog_GetByEntity`:**
   - Add `LocationId`, `LocationName`, `LotId` and `LotName` at the end (LEFT JOINs).
   - `FailureLog_List` gains optional filters `@LocationId BIGINT = NULL` (exact) and
     `@LotNameLike NVARCHAR(50) = NULL` (substring).
   - Widen the existing test capture tables.

### Ignition (Core)

7. **NQs** in Core:
   - `audit/FailureLog_Record` and `audit/InterfaceLog_Record`, both type `Query` (status-row procs);
   - `audit/FailureLog_List` updated for the two new parameters;
   - `sqlType` per parameter as the proc declares.
8. **`BlueRidge.Audit.FailureLog.record(procedureName, failureReason, entityTypeCode, eventTypeCode,
   appUserId, entityId=None, locationId=None, lotId=None, meta=None)`:**
   - It never raises: `except (Exception, java.lang.Exception)`, and on failure it writes a gateway-log
     ERROR naming the procedure and reason.
   - `appUserId` is required and passed by the caller (`requireAppUserId`). There is no session or
     system default, per the 2026-09-18 attribution rule.
   - `meta` is a dict, JSON-encoded with `system.util.jsonEncode`. Any value that would carry the path
     token must already have been stripped by the caller.
   - It returns the status row, or `None`.
9. **`Lots.AimHttp`:**
   - Calls return richer outcome dicts with:
     - `disabled` (True only for the posting-switched-off return);
     - `httpStatus` (int or None);
     - `endpoint` (`{base}/mes/floor/{company}/<token>/postserial.csv`, or `nextserial.csv`, with the
       token replaced by the literal text `<token>` and the query string dropped);
     - `interfaceLogId`.
   - `_logAim` switches to `audit/InterfaceLog_Record` and returns the new id. It is still best effort.
   - `_post` returns the HTTP status code alongside `(ok, reply, error)`.
   - It writes **no** FailureLog rows and still never raises.
   - Expose a small `postingEnabled()` read so callers can apply the "switched off = no row" rule on
     paths that never reach an HTTP call.
   - `postSerial` gains optional `locationId=None, itemId=None, lotId=None` keyword arguments. `postOne`
     passes them, and `_logAim` writes them into the `InterfaceLog` columns `0113` added, which AIM leaves
     NULL today. Existing callers are unaffected. *(Claude's call.)*
10. **`Lots.AimPost.postOne(aimShipperId, appUserId, terminalLocationId=None)`:**
    - Writes one FailureLog row on every failing outcome **when posting is on**:
      - `failed` (non-2xx, unexpected or mismatched reply, not configured);
      - `incomplete_payload`;
      - `not_found`;
      - the exception branch.
    - Each row carries:
      - `ProcedureName = "BlueRidge.Lots.AimPost.postOne"`;
      - `FailureReason` = the same error text that goes to `LastPostError`;
      - entity `Container` (the pool row's `ContainerId`), event `AimPostFailed`;
      - `LocationId` / `LotId` from `GetForPost`;
      - meta:
        - `aimShipperId`, `containerId`, `endpoint`, `httpStatus`;
        - `attempt` (the pool row's `PostAttempts` after this attempt);
        - `terminalLocationId`, `interfaceLogId`;
        - `caller` (`complete` / `validateCrt` / `retry`).
    - Successful, `already_posted`, `voided` and `held` outcomes write nothing.
11. **Callers pass the user:**
    - `Container.complete` passes its `appUserId` and `terminalLocationId`;
    - `Container.validateCrt` passes the elevated `appUserId` and `terminalLocationId`;
    - `AimPost.retryTick` passes `Common.Util.systemAppUserId()` (AppUser 1).
    - The `except` branches in `complete` / `validateCrt` around `postOne` also call
      `FailureLog.record` (posting on, same entity/event, reason = the exception text). They are a
      second net that only fires if `postOne` itself raised past its own guard.
12. **`AimPoolGateway.topupTick`:** when `nextSerial()` fails and the outcome is not `disabled`, write one
    row and stop.
    - `ProcedureName = "BlueRidge.Lots.AimPoolGateway.topupTick"`.
    - Entity `AimShipperIdPool`, no `EntityId`, event `AimSerialFetchFailed`.
    - No Location or LOT (the pool is global).
    - Meta: `endpoint`, `httpStatus`, `interfaceLogId`, `depth`, `target`, `fetchedThisTick`.
    - User AppUser 1.
    - The exception branch also writes a row when posting is on.
    - It also starts passing `fetchedInterfaceLogId` to `AimPool.topup` now that the id is available.

### Ignition (MPP_Config Audit Browser)

13. **`Views/Audit/FailureLog/view.json`** (edited on disk by Claude, with Jacques's agreement, while the
    view is not open in Designer):
    - the grid gains **Location** and **LOT** columns;
    - the filter panel gains a **Location** dropdown and a **LOT** text filter, wired through
      `FailureLog.search()`;
    - the row-click popup params gain `locationName` and `lotName`.
    - **`Components/Popups/FailureDetail`** shows Location and LOT. It already shows
      `AttemptedParameters`.

## Left to the builder

- The exact JSON key names in `meta` (keep them camelCase and stable).
- Whether `postOne` reads `postingEnabled()` once at entry or uses the `disabled` flag from `AimHttp`.
  The rule is what matters: no row when posting is off.
- How the Location dropdown is populated. Reuse an existing location-list NQ; don't add a new proc
  unless none fits.
- Test shapes and file names under `sql/tests/` (new folder `0116_FailureLogAim/` plus updates to
  `02_audit_readers/070_FailureLog_List.sql` and any `GetForPost` capture tables).

## Done when

- The SQL suite is green on a clean private database, with the assertion count compared against the
  last baseline.
- `0116` and the changed repeatables are applied additively to `MPP_MES_Dev`.
- `.\scan.ps1` has run, and the NQs, script modules and view load on the Dev gateway with no errors in
  `wrapper.log`.
- The Audit Browser shows the new columns and filters.
- A deliberate failure on Dev produces exactly one row with Location, LOT and meta. To get one: posting
  on, a bad base URL (an unreachable local address, never a real AIM endpoint), and a completed Dev
  container whose pool row has a `LotNumber`. Switching posting off produces none.
- `MPP_MES_DATA_MODEL.md` (columns, procs, revision row) and its extended properties are updated, and
  `PROJECT_STATUS.md` is updated.
- No prod deploy.
