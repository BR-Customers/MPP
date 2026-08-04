# Plant-floor session, identity & time-boxed elevation — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace per-action AD elevation with a time-boxed elevated mode on the plant-floor terminal (supervisor becomes the session user for a rolling 5-min window), make the operator-presence + elevation timeouts globally configurable, add a Reset Terminal control, and give AD supervisors a clean User-Management link to an `AppUser.Id`.

**Architecture:** A new global `Location.SessionPolicy` (single row) holds the two durations, loaded into `session.custom.policy` at terminal bind. Elevation state lives in `session.custom.elevatedUntil`; `isElevated` gates protected controls (Style 1: bind `enabled`/`visible`) with a `requireElevation` escape hatch (Style 2) for param-carrying actions. One app-shell `elevationResult` handler sets the window; one idle watcher drives both timeouts off `session.props.lastActivity`. All session mutation runs in view scope or via `Common.Session` helpers that **take the session object as a parameter** (never `getSessionInfo()` — that helper is broken).

**Tech Stack:** SQL Server 2022 (versioned + repeatable migrations, `sqlcmd` test harness), Ignition 8.3 Named Queries, Jython project scripts, Perspective `view.json`.

**Spec:** `docs/superpowers/specs/2026-08-04-plant-floor-session-elevation-design.md`

## Global Constraints

- SQL: `UpperCamelCase`; `BIGINT` FKs; `NVARCHAR`; `DATETIME2(3)`; enum/status FK-backed; UTC stored. Procs obey FDS-11-011 (no OUTPUT params; mutation procs end every path with `SELECT @Status AS Status, @Message AS Message[, @NewId AS NewId]`; one result set; `RAISERROR` in CATCH). Audit writers emit no result set; Description `<SUBJECT> · <CATEGORY?> · <ACTION>` via `Audit.ufn_MidDot()` + `Audit.ufn_TruncateActivity()`.
- **No business logic in Python.** Bounds/validation for durations live in the `SessionPolicy_Update` proc. `Common.Session` helpers are session-state plumbing, not domain rules.
- **Never call `system.perspective.getSessionInfo()` to resolve the current session** (returns a list; the existing `_currentAppUserId` bug). Session helpers take the `session` object as a parameter, passed from a view script that has `self.session`.
- Existing `view.json` edits are **Designer** work (GSON unicode-escape + cache-race boundary). New Core NQs / Python / SQL are safe file edits. Run `.\scan.ps1` after any Ignition resource change.
- Explicit `git add <paths>` only. Commit to `jacques/working`. No `Co-Authored-By` trailer.
- Test DB is throwaway `MPP_MES_Test` (Run-Tests resets it). Never reset `MPP_MES_Dev`.
- **Migration number:** this plan uses `0049`. Before creating it, confirm the highest committed+untracked versioned migration (an untracked `0047_lot_bom_asbuilt.sql` and committed `0048_defect_code_operation_category.sql` exist); if `0049` is taken, use the next free number consistently.

## File Structure

- `sql/migrations/versioned/0049_session_policy.sql` — new `Location.SessionPolicy` table + single-row seed + `SessionPolicy` LogEntityType.
- `sql/migrations/repeatable/R__Location_SessionPolicy_Get.sql`, `R__Location_SessionPolicy_Update.sql` — procs.
- `sql/tests/0020_PlantFloor_Foundation/030_SessionPolicy_crud.sql` — proc tests.
- `ignition/projects/Core/ignition/named-query/location/SessionPolicy_Get/`, `SessionPolicy_Update/` — NQs.
- `ignition/projects/Core/ignition/script-python/BlueRidge/Location/SessionPolicy/code.py` — thin read/write wrappers.
- `ignition/projects/Core/ignition/script-python/BlueRidge/Common/Session/code.py` — elevation/timeout helpers (extend existing module).
- `ignition/projects/Core/ignition/script-python/BlueRidge/Location/Terminal/code.py` — load policy into session at bind (extend `applyToSession`).
- `ignition/projects/MPP/com.inductiveautomation.perspective/session-props/props.json` — declare new `session.custom` keys.
- Designer view edits: `ShopFloor/AppHeader`, `Components/PlantFloor/NavigationTree`, `Components/PlantFloor/CellContextSelector`, `Components/Popups/MoveOverride`, `MPP_Config Views/Audit/Users`, plus whichever control launches the config app / tool config.

---

### Task 1: `Location.SessionPolicy` table + seed (migration 0049)

**Files:** Create `sql/migrations/versioned/0049_session_policy.sql`

**Interfaces:** Produces `Location.SessionPolicy` (single row, Id 1) with `OperatorPresenceTimeoutSeconds`, `ElevationTimeoutSeconds`; an `Audit.LogEntityType` code `SessionPolicy`.

- [ ] **Step 1: Write the migration**

```sql
-- ============================================================
-- Migration: 0049_session_policy.sql
-- Description: Global plant-floor session policy (single row): operator-presence
--              + elevation idle timeouts (seconds). Seeds Id=1 defaults 180/300.
--              Adds Audit.LogEntityType 'SessionPolicy'. Idempotent-guarded.
-- ============================================================
IF EXISTS (SELECT 1 FROM dbo.SchemaVersion WHERE MigrationId = N'0049_session_policy')
BEGIN PRINT 'Migration 0049 already applied -- skipping.'; RETURN; END
GO

IF OBJECT_ID(N'Location.SessionPolicy') IS NULL
CREATE TABLE Location.SessionPolicy (
    Id                             BIGINT IDENTITY(1,1) NOT NULL CONSTRAINT PK_SessionPolicy PRIMARY KEY,
    OperatorPresenceTimeoutSeconds INT          NOT NULL CONSTRAINT DF_SessionPolicy_OpTimeout  DEFAULT 180,
    ElevationTimeoutSeconds        INT          NOT NULL CONSTRAINT DF_SessionPolicy_ElevTimeout DEFAULT 300,
    UpdatedAt                      DATETIME2(3) NOT NULL CONSTRAINT DF_SessionPolicy_UpdatedAt   DEFAULT SYSUTCDATETIME(),
    UpdatedByUserId                BIGINT       NOT NULL CONSTRAINT FK_SessionPolicy_UpdatedBy   REFERENCES Location.AppUser(Id),
    CONSTRAINT CK_SessionPolicy_OpBounds   CHECK (OperatorPresenceTimeoutSeconds BETWEEN 30 AND 3600),
    CONSTRAINT CK_SessionPolicy_ElevBounds CHECK (ElevationTimeoutSeconds        BETWEEN 30 AND 3600)
);
GO

-- Single-row seed (Id 1), attributed to the bootstrap system user (AppUser 1).
IF NOT EXISTS (SELECT 1 FROM Location.SessionPolicy)
    INSERT INTO Location.SessionPolicy (OperatorPresenceTimeoutSeconds, ElevationTimeoutSeconds, UpdatedByUserId)
    VALUES (180, 300, 1);
GO

-- Audit entity type (dynamic next Id -- no magic number / collision).
IF NOT EXISTS (SELECT 1 FROM Audit.LogEntityType WHERE Code = N'SessionPolicy')
    INSERT INTO Audit.LogEntityType (Id, Code, Name, Description)
    SELECT ISNULL(MAX(Id),0)+1, N'SessionPolicy', N'Session Policy',
           N'Global plant-floor operator-presence + elevation idle timeouts'
    FROM Audit.LogEntityType;
GO

INSERT INTO dbo.SchemaVersion (MigrationId, Description)
VALUES (N'0049_session_policy', N'Location.SessionPolicy single-row global timeouts + SessionPolicy LogEntityType.');
GO
PRINT 'Migration 0049 (session_policy) applied.';
GO
```

- [ ] **Step 2: Apply on the test DB, verify**

Run: `.\sql\tests\Run-Tests.ps1 -Filter "__nofile__"` resets `MPP_MES_Test`; then:
```bash
sqlcmd -S localhost -d MPP_MES_Test -Q "SELECT Id, OperatorPresenceTimeoutSeconds, ElevationTimeoutSeconds FROM Location.SessionPolicy;"
```
Expected: one row `1 | 180 | 300`.

- [ ] **Step 3: Commit** — `git add sql/migrations/versioned/0049_session_policy.sql && git commit -m "feat(session): migration 0049 — Location.SessionPolicy global timeouts"`

---

### Task 2: `SessionPolicy_Get` + `SessionPolicy_Update` procs + tests

**Files:** Create `sql/migrations/repeatable/R__Location_SessionPolicy_Get.sql`, `R__Location_SessionPolicy_Update.sql`, `sql/tests/0020_PlantFloor_Foundation/030_SessionPolicy_crud.sql`

**Interfaces:** `SessionPolicy_Get()` → one row `{Id, OperatorPresenceTimeoutSeconds, ElevationTimeoutSeconds, UpdatedAt}`. `SessionPolicy_Update @OperatorPresenceTimeoutSeconds, @ElevationTimeoutSeconds, @AppUserId` → `Status, Message`.

- [ ] **Step 1: Write the failing test** `030_SessionPolicy_crud.sql`

```sql
EXEC test.BeginTestFile @FileName = N'0020_PlantFloor_Foundation/030_SessionPolicy_crud.sql';
GO
-- Get returns the single row
CREATE TABLE #G (Id BIGINT, OperatorPresenceTimeoutSeconds INT, ElevationTimeoutSeconds INT, UpdatedAt DATETIME2(3));
INSERT INTO #G EXEC Location.SessionPolicy_Get;
DECLARE @n NVARCHAR(10) = CAST((SELECT COUNT(*) FROM #G) AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName=N'[SessionPolicy] Get returns 1 row', @Expected=N'1', @Actual=@n;
DROP TABLE #G;
GO
-- Update happy path
DECLARE @S BIT, @M NVARCHAR(500);
CREATE TABLE #U (Status BIT, Message NVARCHAR(500));
INSERT INTO #U EXEC Location.SessionPolicy_Update @OperatorPresenceTimeoutSeconds=120, @ElevationTimeoutSeconds=240, @AppUserId=1;
SELECT @S=Status, @M=Message FROM #U; DROP TABLE #U;
DECLARE @Ss NVARCHAR(1)=CAST(@S AS NVARCHAR(1));
EXEC test.Assert_IsEqual @TestName=N'[SessionPolicy] Update Status 1', @Expected=N'1', @Actual=@Ss;
DECLARE @op NVARCHAR(10)=CAST((SELECT OperatorPresenceTimeoutSeconds FROM Location.SessionPolicy) AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName=N'[SessionPolicy] Update persisted', @Expected=N'120', @Actual=@op;
GO
-- Update rejects out-of-bounds
DECLARE @S2 BIT, @M2 NVARCHAR(500);
CREATE TABLE #U2 (Status BIT, Message NVARCHAR(500));
INSERT INTO #U2 EXEC Location.SessionPolicy_Update @OperatorPresenceTimeoutSeconds=5, @ElevationTimeoutSeconds=240, @AppUserId=1;
SELECT @S2=Status, @M2=Message FROM #U2; DROP TABLE #U2;
DECLARE @S2s NVARCHAR(1)=CAST(@S2 AS NVARCHAR(1));
EXEC test.Assert_IsEqual @TestName=N'[SessionPolicy] Update rejects <30s', @Expected=N'0', @Actual=@S2s;
EXEC test.Assert_Contains @TestName=N'[SessionPolicy] bounds message', @HaystackStr=@M2, @NeedleStr=N'between 30';
GO
-- restore defaults for downstream tests
DECLARE @R BIT; CREATE TABLE #R (Status BIT, Message NVARCHAR(500));
INSERT INTO #R EXEC Location.SessionPolicy_Update @OperatorPresenceTimeoutSeconds=180, @ElevationTimeoutSeconds=300, @AppUserId=1;
DROP TABLE #R;
GO
EXEC test.EndTestFile;
GO
```

- [ ] **Step 2: Run it — expect FAIL** (`Run-Tests.ps1 -Filter "030_SessionPolicy_crud"`): "Could not find stored procedure 'Location.SessionPolicy_Get'".

- [ ] **Step 3: Write `R__Location_SessionPolicy_Get.sql`**

```sql
CREATE OR ALTER PROCEDURE Location.SessionPolicy_Get
AS
BEGIN
    SET NOCOUNT ON;
    SELECT TOP 1 Id, OperatorPresenceTimeoutSeconds, ElevationTimeoutSeconds, UpdatedAt
    FROM Location.SessionPolicy ORDER BY Id;
END
GO
```

- [ ] **Step 4: Write `R__Location_SessionPolicy_Update.sql`**

```sql
CREATE OR ALTER PROCEDURE Location.SessionPolicy_Update
    @OperatorPresenceTimeoutSeconds INT,
    @ElevationTimeoutSeconds        INT,
    @AppUserId                      BIGINT
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;
    DECLARE @Status BIT = 0, @Message NVARCHAR(500) = N'Unknown error';
    DECLARE @ProcName NVARCHAR(200) = N'Location.SessionPolicy_Update';
    DECLARE @Params NVARCHAR(MAX) = (SELECT @OperatorPresenceTimeoutSeconds AS Op, @ElevationTimeoutSeconds AS Elev FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);
    BEGIN TRY
        IF @AppUserId IS NULL OR @OperatorPresenceTimeoutSeconds IS NULL OR @ElevationTimeoutSeconds IS NULL
        BEGIN SET @Message = N'Required parameter missing.'; SELECT @Status AS Status, @Message AS Message; RETURN; END

        IF @OperatorPresenceTimeoutSeconds NOT BETWEEN 30 AND 3600
           OR @ElevationTimeoutSeconds NOT BETWEEN 30 AND 3600
        BEGIN
            SET @Message = N'Timeouts must be between 30 and 3600 seconds.';
            EXEC Audit.Audit_LogFailure @AppUserId=@AppUserId, @LogEntityTypeCode=N'SessionPolicy',
                @EntityId=1, @LogEventTypeCode=N'Updated', @FailureReason=@Message,
                @ProcedureName=@ProcName, @AttemptedParameters=@Params;
            SELECT @Status AS Status, @Message AS Message; RETURN;
        END

        DECLARE @OldOp INT, @OldElev INT;
        SELECT TOP 1 @OldOp = OperatorPresenceTimeoutSeconds, @OldElev = ElevationTimeoutSeconds
        FROM Location.SessionPolicy ORDER BY Id;

        DECLARE @Arrow NCHAR(1) = NCHAR(8594);
        DECLARE @Fields NVARCHAR(MAX) = STUFF(CONCAT(
            CASE WHEN @OldOp <> @OperatorPresenceTimeoutSeconds THEN N', Operator presence ' + CAST(@OldOp AS NVARCHAR(10)) + N's ' + @Arrow + N' ' + CAST(@OperatorPresenceTimeoutSeconds AS NVARCHAR(10)) + N's' ELSE N'' END,
            CASE WHEN @OldElev <> @ElevationTimeoutSeconds THEN N', Elevation ' + CAST(@OldElev AS NVARCHAR(10)) + N's ' + @Arrow + N' ' + CAST(@ElevationTimeoutSeconds AS NVARCHAR(10)) + N's' ELSE N'' END),
            1, 2, N'');
        IF @Fields = N'' SET @Fields = N'no changes';
        DECLARE @Activity NVARCHAR(500) = Audit.ufn_TruncateActivity(N'Session Policy ' + Audit.ufn_MidDot() + N' Updated ' + @Fields);
        DECLARE @OldJson NVARCHAR(MAX) = (SELECT @OldOp AS OperatorPresenceTimeoutSeconds, @OldElev AS ElevationTimeoutSeconds FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);
        DECLARE @NewJson NVARCHAR(MAX) = (SELECT @OperatorPresenceTimeoutSeconds AS OperatorPresenceTimeoutSeconds, @ElevationTimeoutSeconds AS ElevationTimeoutSeconds FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

        BEGIN TRANSACTION;
        UPDATE Location.SessionPolicy
        SET OperatorPresenceTimeoutSeconds = @OperatorPresenceTimeoutSeconds,
            ElevationTimeoutSeconds        = @ElevationTimeoutSeconds,
            UpdatedAt = SYSUTCDATETIME(), UpdatedByUserId = @AppUserId;
        EXEC Audit.Audit_LogConfigChange @AppUserId=@AppUserId, @LogEntityTypeCode=N'SessionPolicy',
            @EntityId=1, @LogEventTypeCode=N'Updated', @LogSeverityCode=N'Info',
            @Description=@Activity, @OldValue=@OldJson, @NewValue=@NewJson;
        COMMIT TRANSACTION;
        SET @Status = 1; SET @Message = N'Session policy updated.';
        SELECT @Status AS Status, @Message AS Message;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        DECLARE @ErrMsg NVARCHAR(4000)=ERROR_MESSAGE(), @ErrSev INT=ERROR_SEVERITY(), @ErrState INT=ERROR_STATE();
        SET @Status=0; SET @Message=N'Unexpected error: ' + LEFT(@ErrMsg,400);
        BEGIN TRY EXEC Audit.Audit_LogFailure @AppUserId=@AppUserId, @LogEntityTypeCode=N'SessionPolicy',
            @EntityId=1, @LogEventTypeCode=N'Updated', @FailureReason=@Message, @ProcedureName=@ProcName, @AttemptedParameters=@Params; END TRY BEGIN CATCH END CATCH
        SELECT @Status AS Status, @Message AS Message;
        RAISERROR(@ErrMsg, @ErrSev, @ErrState);
    END CATCH
END
GO
```

Note: `Audit.LogEventType` code `Updated` already exists (used by DefectCode/DowntimeReasonCode). If a run reports it missing, seed it the same dynamic-Id way as Task 1's entity type.

- [ ] **Step 5: Run tests — expect PASS** (`Run-Tests.ps1 -Filter "030_SessionPolicy_crud"`). All assertions pass.

- [ ] **Step 6: Commit** — `git add sql/migrations/repeatable/R__Location_SessionPolicy_Get.sql sql/migrations/repeatable/R__Location_SessionPolicy_Update.sql sql/tests/0020_PlantFloor_Foundation/030_SessionPolicy_crud.sql && git commit -m "feat(session): SessionPolicy Get/Update procs + tests"`

---

### Task 3: Core Named Queries for SessionPolicy

**Files:** Create `ignition/projects/Core/ignition/named-query/location/SessionPolicy_Get/{query.sql,resource.json}` and `.../SessionPolicy_Update/{query.sql,resource.json}`

**Interfaces:** Consumes Task 2 procs. `SessionPolicy_Get` type `Query`; `SessionPolicy_Update` type `Query` (ends in a SELECT status row — mirror the DefectCode NQ resource.json shape for a status-row proc).

- [ ] **Step 1: `SessionPolicy_Get/query.sql`** → `EXEC Location.SessionPolicy_Get`
- [ ] **Step 2: `SessionPolicy_Update/query.sql`**
```sql
EXEC Location.SessionPolicy_Update
    @OperatorPresenceTimeoutSeconds = :operatorPresenceTimeoutSeconds,
    @ElevationTimeoutSeconds        = :elevationTimeoutSeconds,
    @AppUserId                      = :appUserId
```
- [ ] **Step 3: `resource.json` for each** — copy a sibling `location/*` NQ resource.json; `Get` has no params, `Update` declares `operatorPresenceTimeoutSeconds` (Int4), `elevationTimeoutSeconds` (Int4), `appUserId` (Int8). Both `type: "Query"` (status-row proc → `Query`, per the NQ-type memory).
- [ ] **Step 4: Scan + commit** — `.\scan.ps1`; `git add ignition/projects/Core/ignition/named-query/location/SessionPolicy_Get ignition/projects/Core/ignition/named-query/location/SessionPolicy_Update && git commit -m "feat(session): SessionPolicy NQs"`

---

### Task 4: `BlueRidge.Location.SessionPolicy` entity script (Core)

**Files:** Create `ignition/projects/Core/ignition/script-python/BlueRidge/Location/SessionPolicy/code.py`

**Interfaces:** Produces `getPolicy()` → dict; `updatePolicy(data)` → `{Status, Message}`.

- [ ] **Step 1: Write the module**

```python
# BlueRidge.Location.SessionPolicy - global session-timeout policy accessors.

def getPolicy():
    """Single global row: {OperatorPresenceTimeoutSeconds, ElevationTimeoutSeconds, ...}.
    Returns a shaped fallback if the row is missing so callers never see None."""
    try:
        row = BlueRidge.Common.Db.execOne("location/SessionPolicy_Get", {})
        if row:
            return row
    except Exception as e:
        BlueRidge.Common.Util.log("getPolicy failed: %s" % str(e))
    return {"OperatorPresenceTimeoutSeconds": 180, "ElevationTimeoutSeconds": 300}

def updatePolicy(data):
    """data: {operatorPresenceTimeoutSeconds, elevationTimeoutSeconds}. Returns {Status, Message}."""
    d = BlueRidge.Common.Util.extractQualifiedValues(data) or {}
    return BlueRidge.Common.Db.execMutation("location/SessionPolicy_Update", {
        "operatorPresenceTimeoutSeconds": BlueRidge.Common.Util.toIntOrNone(d.get("operatorPresenceTimeoutSeconds")),
        "elevationTimeoutSeconds":        BlueRidge.Common.Util.toIntOrNone(d.get("elevationTimeoutSeconds")),
        "appUserId":                      BlueRidge.Common.Util._currentAppUserId(),
    })
```
Note: `updatePolicy` runs from the config app where the caller passes `appUserId` explicitly if the `_currentAppUserId` fix hasn't landed — the User-Management save (Task 12) passes `self.session.custom.appUserId`; adjust the wrapper to accept an explicit `appUserId` param if that fix is still pending at build time.

- [ ] **Step 2: Scan + commit** — `.\scan.ps1`; `git add .../BlueRidge/Location/SessionPolicy/code.py && git commit -m "feat(session): SessionPolicy entity script"`

---

### Task 5: `Common.Session` elevation + timeout helpers (Core)

**Files:** Modify `ignition/projects/Core/ignition/script-python/BlueRidge/Common/Session/code.py`

**Interfaces:** Produces (all take the `session` object — never `getSessionInfo`):
- `nowMs()` → long
- `isElevated(session)` → bool
- `beginElevatedWindow(session, payload)` — set replaced identity + `elevatedUntil`
- `touchElevation(session)` — push the rolling deadline on activity
- `resetTerminal(session)` — clear identity + elevation, return to default screen + prompt initials
- `loadPolicyIntoSession(session)` — seed `session.custom.policy`
- `activeTimeoutSeconds(session)` → int (elevation vs presence, per `isElevated`)
- `requireElevation(session, code, label, params)` — Style-2 gate
- `dispatchElevatedAction(session, code, params)` — explicit code→action map

- [ ] **Step 1: Append the helpers**

```python
import system

def nowMs():
    return system.date.toMillis(system.date.now())

def loadPolicyIntoSession(session):
    p = BlueRidge.Location.SessionPolicy.getPolicy() or {}
    session.custom.policy = {
        "operatorPresenceTimeoutSeconds": p.get("OperatorPresenceTimeoutSeconds") or 180,
        "elevationTimeoutSeconds":        p.get("ElevationTimeoutSeconds") or 300,
    }

def isElevated(session):
    try:
        until = session.custom.elevatedUntil
        return until is not None and until > nowMs()
    except Exception:
        return False

def beginElevatedWindow(session, payload):
    """payload = elevate() result {appUserId, displayName, ignitionRole}. Replaced identity."""
    p = BlueRidge.Common.Util.extractQualifiedValues(payload) or {}
    session.custom.user = {"appUserId": p.get("appUserId"), "displayName": p.get("displayName") or "",
                           "ignitionRole": p.get("ignitionRole") or "", "initials": ""}
    session.custom.appUserId = p.get("appUserId")
    secs = (session.custom.policy or {}).get("elevationTimeoutSeconds") or 300
    session.custom.elevatedUntil = nowMs() + secs * 1000

def touchElevation(session):
    if isElevated(session):
        secs = (session.custom.policy or {}).get("elevationTimeoutSeconds") or 300
        session.custom.elevatedUntil = nowMs() + secs * 1000

def activeTimeoutSeconds(session):
    pol = session.custom.policy or {}
    if isElevated(session):
        return pol.get("elevationTimeoutSeconds") or 300
    return pol.get("operatorPresenceTimeoutSeconds") or 180

def resetTerminal(session):
    """Drop elevation AND operator; return to default screen + prompt initials."""
    try:
        old = session.custom.user
        oldId = old["appUserId"] if old else None
    except Exception:
        oldId = None
    try:
        term = session.custom.terminal
        termId = term["terminalLocationId"] if term else None
    except Exception:
        termId = None
    try:
        BlueRidge.Location.AppUser.logOperatorChange(oldId, None, termId)
    except (Exception, java.lang.Exception):
        pass
    session.custom.user = {"appUserId": None, "displayName": "", "ignitionRole": "", "initials": ""}
    session.custom.appUserId = None
    session.custom.elevatedUntil = None
    session.custom.pendingElevatedAction = None
    try:
        dflt = (session.custom.terminal or {}).get("defaultScreen") or "/shop-floor"
    except Exception:
        dflt = "/shop-floor"
    system.perspective.navigate(dflt)
    system.perspective.openPopup("mpp-initials", "BlueRidge/Components/Popups/InitialsEntry",
        params={"popupId": "mpp-initials"}, modal=True, showCloseIcon=False, overlayDismiss=False)

def requireElevation(session, code, label, params=None):
    if isElevated(session):
        dispatchElevatedAction(session, code, params)
    else:
        session.custom.pendingElevatedAction = {"code": code, "params": params}
        system.perspective.openPopup("mpp-elevation-modal", "BlueRidge/Components/PlantFloor/ElevationModal",
            params={"actionCode": code, "actionLabel": label, "popupId": "mpp-elevation-modal",
                    "replyMessage": "elevationResult"}, modal=True, showCloseIcon=True, overlayDismiss=True)

def dispatchElevatedAction(session, code, params):
    """Explicit code -> action map. NEVER eval. Extend as protected param-actions are added."""
    p = BlueRidge.Common.Util.extractQualifiedValues(params) or {}
    if code == "MoveOverride":
        BlueRidge.Lots.Lot.moveToValidatedOverride(p)   # existing override path; wire to the real fn
    # else: access-only codes (SupervisorAccess/nav/config) have no follow-up action.
```
`import java.lang` at module top for the `java.lang.Exception` guard. Replace `moveToValidatedOverride(p)` with the actual override entry the current `MoveOverride` popup calls (confirm during Task 10).

- [ ] **Step 2: Scan + commit** — `.\scan.ps1`; `git add .../BlueRidge/Common/Session/code.py && git commit -m "feat(session): elevation + timeout session helpers"`

---

### Task 6: Load policy at terminal bind + declare session keys

**Files:** Modify `ignition/projects/Core/ignition/script-python/BlueRidge/Location/Terminal/code.py` (`applyToSession`); Modify `ignition/projects/MPP/com.inductiveautomation.perspective/session-props/props.json`

- [ ] **Step 1: `applyToSession`** — after `session.custom.cell = {...}` (both the fallback `tid is None` branch and the normal path), add:
```python
    BlueRidge.Common.Session.loadPolicyIntoSession(session)
    session.custom.elevatedUntil = None
    session.custom.pendingElevatedAction = None
```

- [ ] **Step 2: `session-props/props.json`** — add to the `custom` block defaults:
```json
    "elevatedUntil": null,
    "pendingElevatedAction": null,
    "policy": { "operatorPresenceTimeoutSeconds": 180, "elevationTimeoutSeconds": 300 }
```
(session-props is not a view — safe file edit; validate JSON parses, then scan.)

- [ ] **Step 3: Scan + commit** — `.\scan.ps1`; `git add .../BlueRidge/Location/Terminal/code.py ignition/projects/MPP/com.inductiveautomation.perspective/session-props/props.json && git commit -m "feat(session): load policy + init elevation state at terminal bind"`

---

### Task 7 (Designer): AppHeader — Supervisor access, Reset Terminal, elevationResult handler, idle watcher

**File (Designer):** `ignition/projects/MPP/.../Views/ShopFloor/AppHeader/view.json`

- [ ] **Step 1: "Supervisor access" button** — header control. `props.enabled` bound (expr) to `!BlueRidge.Common.Session.isElevated` is not expressible directly; instead bind to `isNull({session.custom.elevatedUntil}) || {session.custom.elevatedUntil} < now(5000)` (show it when NOT elevated). `onActionPerformed` (scope G): `self.view.getChild(...)` not needed — call `system.perspective.openPopup("mpp-elevation-modal", "BlueRidge/Components/PlantFloor/ElevationModal", params={"actionCode":"SupervisorAccess","actionLabel":"Supervisor access","popupId":"mpp-elevation-modal","replyMessage":"elevationResult"}, modal=True, showCloseIcon=True, overlayDismiss=True)`.
- [ ] **Step 2: An "Elevated" indicator + "Reset Terminal" button** — visible when elevated (`{session.custom.elevatedUntil} > now(5000)`), OR keep Reset Terminal always visible. Reset `onActionPerformed` (scope G): `BlueRidge.Common.Session.resetTerminal(self.session)`.
- [ ] **Step 3: `elevationResult` page-scoped message handler** on AppHeader (root, `pageScope: true`):
```python
if payload and payload.get("success"):
    BlueRidge.Common.Session.beginElevatedWindow(self.session, payload)
    pend = self.session.custom.pendingElevatedAction
    if pend:
        BlueRidge.Common.Session.dispatchElevatedAction(self.session, pend.get("code"), pend.get("params"))
    self.session.custom.pendingElevatedAction = None
else:
    self.session.custom.pendingElevatedAction = None
```
- [ ] **Step 4: Idle watcher** — a hidden `ia.display.label` (or the root) with a `custom.idleTick` bound (expr) to `now(10000)` (recomputes every 10 s). Add a `propConfig.custom.idleTick.onChange` script:
```python
idleMs = system.date.toMillis(system.date.now()) - self.session.props.lastActivity
secs = BlueRidge.Common.Session.activeTimeoutSeconds(self.session)
if idleMs > secs * 1000:
    if BlueRidge.Common.Session.isElevated(self.session):
        BlueRidge.Common.Session.resetTerminal(self.session)   # elevation expiry
    else:
        # operator-presence: open the existing re-confirm if an operator is signed in
        u = self.session.custom.user
        if u and u.get("appUserId"):
            system.perspective.openPopup("mpp-idle-reconfirm","BlueRidge/Components/PlantFloor/IdleReconfirmModal",
                params={"initials":u.get("initials"),"displayName":u.get("displayName"),
                        "popupId":"mpp-idle-reconfirm","replyMessage":"idleReconfirmResult"}, modal=True, showCloseIcon=False)
```
Guard the whole body in `try/except (Exception, java.lang.Exception)` so a watcher error never freezes the terminal. Ensure only one watcher instance exists (AppHeader is the single always-mounted shell).
- [ ] **Step 5: Scan, smoke-test, commit** — elevate → button hides + indicator shows; Reset returns to default + initials prompt; shorten policy to 60 s (Task 12 or SQL) and confirm expiry.

---

### Task 8 (Designer): NavigationTree gated by elevation (#10)

**File (Designer):** `Components/PlantFloor/NavigationTree/view.json`

- [ ] **Step 1:** Bind the nav control's `props.enabled` (or the interactive tree/menu component) to `{session.custom.elevatedUntil} > now(5000)`. Add a disabled-state affordance (tooltip "Supervisor access required" via `meta.tooltip`). Leaving the default screen is only possible while elevated.
- [ ] **Step 2: Scan + commit.**

---

### Task 9 (Designer): Config-app launch / tool config gated (#9/#12)

**File (Designer):** whichever control launches the config app / die-cast tool config (confirm during exploration — likely on `AppHeader` or the die-cast body).

- [ ] **Step 1:** Bind that button's `props.enabled` to `{session.custom.elevatedUntil} > now(5000)`; keep its existing launch/navigate action. (The config app then enforces its own standing AD gate — separate #7 work.)
- [ ] **Step 2: Scan + commit.**

---

### Task 10 (Designer): MoveOverride → `requireElevation` migration

**File (Designer):** `Components/Popups/MoveOverride/view.json` (and its trigger)

- [ ] **Step 1:** Find the current elevation entry (it opens `ElevationModal` directly and acts on `elevationResult`). Replace the trigger with `BlueRidge.Common.Session.requireElevation(self.session, "MoveOverride", "Move override", {<the move params>})`. Wire `dispatchElevatedAction`'s `MoveOverride` branch (Task 5) to the real override function this popup currently calls. Result: inside an open window, an override proceeds without re-prompting; cold, it prompts once.
- [ ] **Step 2:** Ensure MoveOverride no longer has its own `elevationResult` handler that double-sets state (the app-shell handler is now authoritative).
- [ ] **Step 3: Scan + commit.**

---

### Task 11 (Designer): Cell-context change → presence re-confirm (#6)

**File (Designer):** `Components/PlantFloor/CellContextSelector/view.json` (writes `session.custom.cell`)

- [ ] **Step 1:** On the cell-change commit (where `session.custom.cell` is set), after the change, if NOT elevated and an operator is signed in, open `IdleReconfirmModal` (same params as Task 7 Step 4). Do not fire while elevated.
- [ ] **Step 2: Scan + commit.**

---

### Task 12 (Designer): User Management view — global timeouts + AD link

**File (Designer):** `MPP_Config .../Views/Audit/Users/view.json` (+ its user editor popup)

- [ ] **Step 1: Global-policy panel above the operator table** — two numeric inputs (operator-presence, elevation) shown in minutes or seconds, bound to a `view.custom.policy` seeded from `runScript("BlueRidge.Location.SessionPolicy.getPolicy", 0)`; a Save button calls `BlueRidge.Location.SessionPolicy.updatePolicy(self.view.custom.policy)` then `notifyResult`. (If the `_currentAppUserId` fix is still pending, pass `self.session.custom.appUserId` explicitly per Task 4's note.)
- [ ] **Step 2: Per-user AD fields** — in the user create/edit editor, surface `AdAccount` + `IgnitionRole` inputs (procs `AppUser_Create`/`AppUser_Update` already accept them; note the `CK_AppUser_IgnitionRole_Requires_AdAccount` constraint — role requires an AD account, so gate the role input on AdAccount being non-empty). Add a column/badge in the operator table distinguishing "AD: domain\\user" from "Operator only" so the AD↔AppUser link is visible.
- [ ] **Step 3: Scan, smoke-test (save timeouts; set an AD account + role on a user; confirm that user can elevate), commit.**

---

## Self-Review

**Spec coverage:** SessionPolicy table/procs/NQs/script (Tasks 1–4) → configurable global timeouts (#8, #5). Session helpers + bind (Tasks 5–6) → elevation state, replaced identity, rolling deadline. AppHeader (Task 7) → Supervisor access, Reset Terminal (#11), elevationResult, idle watcher (both timeouts). NavigationTree (Task 8) → #10. Config/tool-config gating (Task 9) → #9/#12. MoveOverride (Task 10) → per-action→windowed migration. CellContextSelector (Task 11) → #6. User Management (Task 12) → global-timeout UI + AD↔AppUser link. #7 explicitly out of scope. ✓

**Placeholder scan:** the two "confirm during exploration" notes (Task 9 launch control, Task 10 override fn) are genuine lookups the implementer resolves in-view, not vague requirements — each names the file and the exact change. No TBD/TODO.

**Type consistency:** `session.custom.elevatedUntil` (epoch-ms) read identically in helpers (`isElevated`) and view exprs (`{session.custom.elevatedUntil} > now(5000)`); `policy.{operatorPresenceTimeoutSeconds,elevationTimeoutSeconds}` consistent across proc columns, NQ params, entity script, session helpers, and props.json. `elevationResult` payload `{success, appUserId, displayName, ignitionRole}` matches `AppUser.elevate`'s return and `beginElevatedWindow`'s reads.

**Attribution dependency:** noted in Tasks 4 & 12 — until the `getSessionInfo`/`_currentAppUserId` fix lands, config-app saves pass `session.custom.appUserId` explicitly.
