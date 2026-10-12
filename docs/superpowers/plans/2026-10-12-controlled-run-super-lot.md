# Controlled Run (Super-lot) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give Quality a stored "super-lot" (a Controlled Run): a numbered case with a member list of LOTs and containers, selected by part / line / time / genealogy, with a rolling window, a stand-out label, and a dedicated view to manage it.

**Architecture:** Two tables in `Quality` (run + member) plus a label print log. Membership never blocks anything on its own: joining a run sets the existing `Lots.Lot.CrtActive` bit, so every CRT block already in the plant applies unchanged. One inline function resolves and judges candidate members for both the preview and the writers; one silent internal proc applies members for every writer. The rolling window is a fourth arm in `Lots.ufn_CrtForMint` plus a sync proc.

**Tech Stack:** SQL Server 2022 (T-SQL, repeatable procs, versioned migration), Ignition 8.3 Perspective (file-authored new views, Jython 2.7 script modules, named queries in Core), ZPL.

**Spec:** `docs/superpowers/specs/2026-10-12-controlled-run-super-lot-design.md` (approved 2026-10-12). Mockup: `mockup/controlled_run_super_lot_mock.html` — the visual authority for Task 12. Context: `notes/2026-10-12_crt-super-lot-and-nonconformance-overview.md`.

## Global Constraints

- **This is piece 1 of 6 and MUST NOT be deployed to production on its own** (spec 9.2). A completed container is an eligible member here but only a later piece can block it at the dock. Build and merge to the feature branch only.
- Branch: `jacques/controlled-run-super-lot`. Stage **explicit paths** only (never `git add -A` / `-u`). No `Co-Authored-By` trailer.
- **Never run tests against `MPP_MES_Dev` or `MPP_MES_Test`.** `Run-Tests.ps1` DROPS its target. Use the private database `MPP_MES_Test_CtrlRun` in every command below.
- After every test run check the **assertion count** against the count the task states, not only the failure count: exit 1 with 0 failures means a file threw and every batch after it never ran.
- SQL: `UpperCamelCase`; `BIGINT` ids; `NVARCHAR`; `DATETIME2(3)`; times stored UTC (`SYSUTCDATETIME()`), displayed Eastern via `CAST(<col> AT TIME ZONE 'UTC' AT TIME ZONE 'Eastern Standard Time' AS DATETIME2(3))`.
- Procs (FDS-11-011): **no `OUTPUT` parameters; exactly one result set; every rejecting validation before `BEGIN TRANSACTION`; `CATCH` is the only `ROLLBACK` site; `RAISERROR` not `THROW`.** A proc that returns a status row must NOT `EXEC` another status-row proc. `EXEC` arguments are literals or `@variables` only.
- Seed strings and ZPL are **ASCII-only**. Byte-scan before applying.
- `RunNumber` is `NVARCHAR(15)`, format `CR{0:D6}`.
- Label: one design per run, **four copies per print request**, on demand only.
- Audit `Description` = `<SUBJECT> · <CATEGORY?> · <ACTION>` using `Audit.ufn_MidDot()`, truncated with `Audit.ufn_TruncateActivity()`, `NewValue` JSON with resolved-name sub-objects.
- Python: thin wrappers only — no rule lives in Python. Every mutation takes `appUserId` from its caller and passes it through `BlueRidge.Common.Util.requireAppUserId`. Catch `(Exception, java.lang.Exception)` in never-throw guards. **Never run `py_compile` inside `ignition/`.**
- Named queries live in **Core only**. Status-row procs use NQ `"type": "Query"`. PIN-like strings are `sqlType: 7`; ids `sqlType: 3`.
- Views: new view folders are file-authored then `.\scan.ps1`. Every folder needs `view.json` + `resource.json` (scope `G`). **Never nest a view folder inside a view folder.** Event scripts start with a tab and carry `"scope": "G"`. Every `view.custom.*` a binding reads is pre-declared with a fully shaped default. No drag and drop. Text inputs set `deferUpdates: false`.
- Existing views (`AppMenu`) are edited in Designer, not by file edit.

## Review Focus

Inputs the spec implies but does not spell out. Each has a pinning test in the task named.

1. **A reason typed with `^` or `~`, or pasted with a non-ASCII character** would corrupt the ZPL stream or print mojibake. Expected: the label prints with those characters replaced by a space / `?`. → Task 10.
2. **Scanning a finished-good tray LOT's LTT into "Add"** must add its container once, not the LOT, and adding two tray LOTs of the same container must add it once. → Task 2, Task 6.
3. **Two people opening super-lots over the same LOT at the same moment.** Expected: one wins, the other gets a clean Status 0 naming the unit, not a raw unique-index error. → Task 4.
4. **A LOT with no `CreatedAtTerminalId`** (older or manually created) is invisible to the "made at line" filter. Expected: it is still found by genealogy and can be scanned in; the line filter silently skipping it is pinned so nobody assumes otherwise. → Task 3.
5. **Opening a super-lot whose every candidate is ineligible, or with an empty list.** Expected: refused with a message unless "keep adding new production" is on, in which case an empty run is legal. → Task 4.

---

## File Structure

**SQL — created**

| File | Responsibility |
|---|---|
| `sql/migrations/versioned/0109_controlled_run.sql` | Tables, code tables, sequence row, label type + template, audit codes |
| `sql/migrations/repeatable/R__Quality_ufn_zz_ControlledRunResolveMembers.sql` | The ONE place a candidate is folded (tray LOT → container), described and judged eligible |
| `sql/migrations/repeatable/R__Quality_ControlledRun_ApplyMembersInternal.sql` | Silent helper: insert members, set `CrtActive`, per-LOT audit |
| `sql/migrations/repeatable/R__Quality_ControlledRun_SyncInternal.sql` | Silent helper: find auto-join + descendant members, apply |
| `sql/migrations/repeatable/R__Quality_ControlledRun_PreviewSelection.sql` | Read: candidates for a set of criteria |
| `sql/migrations/repeatable/R__Quality_ControlledRun_Open.sql` | Bundled create |
| `sql/migrations/repeatable/R__Quality_ControlledRun_AddMembers.sql` / `_RemoveMember.sql` | Member maintenance |
| `sql/migrations/repeatable/R__Quality_ControlledRun_SyncAutoJoin.sql` / `_SetAutoJoin.sql` | Rolling window |
| `sql/migrations/repeatable/R__Quality_ControlledRun_Close.sql` / `_Cancel.sql` | Lifecycle end |
| `sql/migrations/repeatable/R__Quality_ControlledRun_List.sql` / `_Get.sql` / `_GetByNumber.sql` / `_ListMembers.sql` / `_GetOpenByMember.sql` | Reads |
| `sql/migrations/repeatable/R__Quality_ControlledRunLabel_Print.sql` | Render + log the label |
| `sql/tests/0109_ControlledRun/010..100_*.sql` | One test file per task |

**SQL — modified:** `sql/migrations/repeatable/R__Lots_ufn_zz_CrtForMint.sql` (fourth arm).

**Ignition — created (all NEW folders):**

| Path | Responsibility |
|---|---|
| `ignition/projects/Core/ignition/named-query/quality/ControlledRun_*/`, `ControlledRunLabel_Print/` | 14 named queries |
| `ignition/projects/Core/ignition/script-python/BlueRidge/Quality/ControlledRun/code.py` | Thin wrappers + label dispatch |
| `ignition/projects/MPP/.../views/BlueRidge/Views/ShopFloor/ControlledRuns/` | The page |
| `ignition/projects/MPP/.../views/BlueRidge/Components/Popups/ControlledRunNew/` | Three-step wizard |
| `ignition/projects/MPP/.../views/BlueRidge/Components/Popups/ControlledRunConfirm/` | Credential + remarks confirm for every other mutation |
| `ignition/projects/MPP/ignition/timer/ControlledRunSyncTimer/` | Background sync, committed disabled |

**Ignition — modified:** `ignition/projects/MPP/com.inductiveautomation.perspective/page-config/config.json` (new route, file edit), `Components/Popups/AppMenu` (menu button, Designer).

**Docs — modified:** `MPP_MES_DATA_MODEL.md`, `PROJECT_STATUS.md`, `sql/migrations/repeatable/R__Descriptions_ExtendedProperties.sql` (regenerated).

### Proc skeleton (referred to as **SKELETON** below)

Every mutation proc in this plan has this shape. Tasks give the signature, the validations (in order, with exact messages), the mutation block and the audit line; wrap them in this. `<ENT>` is `ControlledRun`, `<EVT>` is the task's event code, `<ID>` is the entity id variable (`NULL` when not yet known). Procs that create return `Status, Message, NewId`; all others return `Status, Message`.

```sql
CREATE OR ALTER PROCEDURE Quality.<Name>
    <params>
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Status  BIT           = 0;
    DECLARE @Message NVARCHAR(500) = N'Unknown error';
    DECLARE @NewId   BIGINT        = NULL;          -- create procs only

    DECLARE @ProcName NVARCHAR(200) = N'Quality.<Name>';
    DECLARE @Params   NVARCHAR(MAX) = (SELECT <every param> FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

    BEGIN TRY
        -- ---- validations: each one is this block ----
        IF <condition>
        BEGIN
            SET @Message = N'<message>';
            IF @AppUserId IS NOT NULL AND EXISTS (SELECT 1 FROM Location.AppUser WHERE Id = @AppUserId)
                EXEC Audit.Audit_LogFailure
                    @AppUserId = @AppUserId, @LogEntityTypeCode = N'<ENT>',
                    @EntityId = <ID>, @LogEventTypeCode = N'<EVT>',
                    @FailureReason = @Message, @ProcedureName = @ProcName,
                    @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message /*, @NewId AS NewId */;
            RETURN;
        END

        BEGIN TRANSACTION;
        -- ---- mutation + Audit.Audit_LogOperation ----
        COMMIT TRANSACTION;

        SET @Status = 1;
        SET @Message = N'<success message>';
        SELECT @Status AS Status, @Message AS Message /*, @NewId AS NewId */;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0
            ROLLBACK TRANSACTION;

        DECLARE @ErrMsg   NVARCHAR(4000) = ERROR_MESSAGE();
        DECLARE @ErrSev   INT            = ERROR_SEVERITY();
        DECLARE @ErrState INT            = ERROR_STATE();

        SET @Status  = 0;
        SET @Message = N'Unexpected error: ' + LEFT(@ErrMsg, 400);

        BEGIN TRY
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'<ENT>',
                @EntityId = <ID>, @LogEventTypeCode = N'<EVT>',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
        END TRY
        BEGIN CATCH
        END CATCH

        SELECT @Status AS Status, @Message AS Message /*, @NewId AS NewId */;
        RAISERROR(@ErrMsg, @ErrSev, @ErrState);
    END CATCH
END;
GO
```

Every file starts with the standard header comment block (Repeatable / Author `Blue Ridge Automation` / Modified `2026-10-12` / Version `1.0` / Description), as in `sql/migrations/repeatable/R__Lots_Lot_ClearCrt.sql`.

### Test commands

Run one folder (rebuilds the private DB first, ~2–4 min):

```powershell
.\sql\tests\Run-Tests.ps1 -DatabaseName MPP_MES_Test_CtrlRun -Filter "0109_ControlledRun"
```

Regression folders used in Tasks 7 and 15:

```powershell
.\sql\tests\Run-Tests.ps1 -DatabaseName MPP_MES_Test_CtrlRun -Filter "Crt"
.\sql\tests\Run-Tests.ps1 -DatabaseName MPP_MES_Test_CtrlRun
```

### Shared test fixture (paste at the top of every test file's first batch after `BeginTestFile`)

Test files build their own LOTs by direct insert, as `sql/tests/0064_Crt_PartScoped/020_crt_for_mint.sql` does. Every LOT name starts `TEST-CR-` so teardown is one predicate.

```sql
-- ---- teardown (FK-safe): everything this suite creates ----
DELETE FROM Quality.ControlledRunLabel;
DELETE FROM Quality.ControlledRunMember;
DELETE FROM Quality.ControlledRun;
DELETE tr FROM Lots.ContainerTray tr WHERE tr.FinishedGoodLotId IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'TEST-CR-%');
DELETE FROM Lots.Container WHERE Id NOT IN (SELECT ContainerId FROM Lots.ContainerTray)
    AND CreatedByUserId = (SELECT TOP 1 Id FROM Location.AppUser WHERE Initials = N'SYS')
    AND OpenedAt >= DATEADD(DAY, -1, SYSUTCDATETIME()) AND ItemId IN (SELECT ItemId FROM Lots.Lot WHERE LotName LIKE N'TEST-CR-%');
DELETE FROM Lots.LotGenealogyClosure WHERE AncestorLotId IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'TEST-CR-%')
                                        OR DescendantLotId IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'TEST-CR-%');
DELETE FROM Lots.LotEventLog WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'TEST-CR-%');
DELETE FROM Lots.Lot WHERE LotName LIKE N'TEST-CR-%';
UPDATE Lots.IdentifierSequence SET LastValue = 0 WHERE Code = N'ControlledRun';
GO
```

`Run-Tests.ps1` rebuilds the database, so this block is belt and braces between files in the same run. If the `Lots.Container` delete trips an FK on a rebuilt database, narrow it rather than widening it.

Fixture variables used throughout (declare per batch as needed):

```sql
DECLARE @App  BIGINT = (SELECT TOP 1 Id FROM Location.AppUser WHERE Initials = N'SYS');
DECLARE @Item BIGINT = (SELECT TOP 1 Id FROM Parts.Item WHERE DeprecatedAt IS NULL ORDER BY Id);
DECLARE @Item2 BIGINT = (SELECT TOP 1 Id FROM Parts.Item WHERE DeprecatedAt IS NULL AND Id <> @Item ORDER BY Id);
DECLARE @Term BIGINT = (SELECT TOP 1 l.Id FROM Location.Location l
    JOIN Location.LocationTypeDefinition d ON d.Id = l.LocationTypeDefinitionId
    WHERE d.Code = N'Terminal' AND l.DeprecatedAt IS NULL AND l.ParentLocationId IS NOT NULL ORDER BY l.Id);
DECLARE @Line BIGINT = (SELECT ParentLocationId FROM Location.Location WHERE Id = @Term);
DECLARE @TermOther BIGINT = (SELECT TOP 1 l.Id FROM Location.Location l
    JOIN Location.LocationTypeDefinition d ON d.Id = l.LocationTypeDefinitionId
    WHERE d.Code = N'Terminal' AND l.DeprecatedAt IS NULL AND l.ParentLocationId <> @Line ORDER BY l.Id);
```

A LOT is inserted with:

```sql
INSERT INTO Lots.Lot (LotName, ItemId, LotOriginTypeId, LotStatusId, PieceCount, CurrentLocationId,
                      CreatedByUserId, CreatedAtTerminalId, CreatedAt, CrtActive)
VALUES (N'TEST-CR-A', @Item, 1 /*Manufactured*/, 1 /*Good*/, 10, @Line, @App, @Term, DATEADD(HOUR, -3, SYSUTCDATETIME()), 0);
```

`LotStatusId`: 1 Good, 2 Hold, 3 Scrap, 4 Closed. A container with one tray LOT:

```sql
DECLARE @Cfg BIGINT = (SELECT TOP 1 Id FROM Parts.ContainerConfig WHERE ItemId = @Item);
IF @Cfg IS NULL SET @Cfg = (SELECT TOP 1 Id FROM Parts.ContainerConfig);
INSERT INTO Lots.Container (ItemId, ContainerConfigId, CurrentLocationId, ContainerStatusCodeId, CreatedByUserId)
VALUES (@Item, @Cfg, @Line, 2 /*Complete*/, @App);
DECLARE @Con BIGINT = SCOPE_IDENTITY();
INSERT INTO Lots.ContainerTray (ContainerId, TrayPosition, FinishedGoodLotId) VALUES (@Con, 1, @LotFg);
```

`ContainerStatusCodeId`: 1 Open, 2 Complete, 3 Shipped, 4 Hold, 5 Void.

---

### Task 0: Preflight

**Files:** none.

- [ ] **Step 1: Confirm branch and that `main` carries nothing newer**

```powershell
git branch --show-current
git fetch origin
git log --oneline HEAD..origin/main | Select-Object -First 5
Get-ChildItem sql\migrations\versioned | Select-Object -Last 3 -ExpandProperty Name
```

Expected: `jacques/controlled-run-super-lot`; no commits listed from `origin/main`; last migration `0108_downtime_reason_low_inventory.sql`. If a `0109_*.sql` exists, take the next free number and use it everywhere this plan says `0109`.

- [ ] **Step 2: Establish the baseline assertion count**

```powershell
.\sql\tests\Run-Tests.ps1 -DatabaseName MPP_MES_Test_CtrlRun -Filter "Crt"
```

Expected: 0 failures. **Write down the assertion total** — Task 7 must reproduce it exactly.

---

### Task 1: Schema

**Files:**
- Create: `sql/migrations/versioned/0109_controlled_run.sql`
- Test: `sql/tests/0109_ControlledRun/010_schema.sql`

**Interfaces:**
- Produces: tables `Quality.ControlledRun`, `Quality.ControlledRunMember`, `Quality.ControlledRunLabel`; code tables `Quality.ControlledRunStatusCode` (1 `Open`, 2 `Closed`, 3 `Cancelled`), `Quality.ControlledRunJoinMethod` (1 `Selected`, 2 `Manual`, 3 `AutoJoined`, 4 `Descendant`), `Quality.ControlledRunMemberEndReason` (1 `Removed`, 2 `RunClosed`, 3 `RunCancelled`); sequence code `ControlledRun`; label type code `ControlledRun`; audit entity `ControlledRun`; audit events `ControlledRunOpened`, `ControlledRunMemberAdded`, `ControlledRunMemberRemoved`, `ControlledRunWindowChanged`, `ControlledRunClosed`, `ControlledRunCancelled`, `ControlledRunLabelPrinted`.

- [ ] **Step 1: Write the failing test**

`sql/tests/0109_ControlledRun/010_schema.sql`:

```sql
-- =============================================
-- File:        0109_ControlledRun/010_schema.sql
-- Author:      Blue Ridge Automation
-- Description: Migration 0109 landed: tables, constraints, seeds.
-- =============================================
EXEC test.BeginTestFile @FileName = N'0109_ControlledRun/010_schema.sql';
GO
DECLARE @n NVARCHAR(10);

SET @n = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM sys.tables t JOIN sys.schemas s ON s.schema_id = t.schema_id
          WHERE s.name = N'Quality' AND t.name IN (N'ControlledRun', N'ControlledRunMember', N'ControlledRunLabel',
              N'ControlledRunStatusCode', N'ControlledRunJoinMethod', N'ControlledRunMemberEndReason'));
EXEC test.Assert_IsEqual @TestName = N'[Schema] six tables exist', @Expected = N'6', @Actual = @n;

SET @n = (SELECT CAST(max_length / 2 AS NVARCHAR(10)) FROM sys.columns
          WHERE object_id = OBJECT_ID(N'Quality.ControlledRun') AND name = N'RunNumber');
EXEC test.Assert_IsEqual @TestName = N'[Schema] RunNumber is NVARCHAR(15)', @Expected = N'15', @Actual = @n;

SET @n = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM Quality.ControlledRunStatusCode WHERE Code IN (N'Open', N'Closed', N'Cancelled'));
EXEC test.Assert_IsEqual @TestName = N'[Schema] 3 status codes', @Expected = N'3', @Actual = @n;
SET @n = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM Quality.ControlledRunJoinMethod WHERE Code IN (N'Selected', N'Manual', N'AutoJoined', N'Descendant'));
EXEC test.Assert_IsEqual @TestName = N'[Schema] 4 join methods', @Expected = N'4', @Actual = @n;
SET @n = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM Quality.ControlledRunMemberEndReason WHERE Code IN (N'Removed', N'RunClosed', N'RunCancelled'));
EXEC test.Assert_IsEqual @TestName = N'[Schema] 3 end reasons', @Expected = N'3', @Actual = @n;

SET @n = (SELECT FormatString FROM Lots.IdentifierSequence WHERE Code = N'ControlledRun');
EXEC test.Assert_IsEqual @TestName = N'[Schema] sequence format', @Expected = N'CR{0:D6}', @Actual = @n;

SET @n = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM Lots.LabelTemplate t JOIN Lots.LabelTypeCode c ON c.Id = t.LabelTypeCodeId
          WHERE c.Code = N'ControlledRun' AND t.DeprecatedAt IS NULL);
EXEC test.Assert_IsEqual @TestName = N'[Schema] one active ControlledRun label template', @Expected = N'1', @Actual = @n;

-- ASCII-only template (sqlcmd codepage rule)
SET @n = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM Lots.LabelTemplate t JOIN Lots.LabelTypeCode c ON c.Id = t.LabelTypeCodeId
          WHERE c.Code = N'ControlledRun' AND t.ZplBody LIKE N'%[^ -~]%' COLLATE Latin1_General_BIN2);
EXEC test.Assert_IsEqual @TestName = N'[Schema] label template is ASCII-only', @Expected = N'0', @Actual = @n;

SET @n = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM Audit.LogEventType WHERE Code LIKE N'ControlledRun%');
EXEC test.Assert_IsEqual @TestName = N'[Schema] 7 audit event codes', @Expected = N'7', @Actual = @n;
SET @n = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM Audit.LogEntityType WHERE Code = N'ControlledRun');
EXEC test.Assert_IsEqual @TestName = N'[Schema] audit entity type', @Expected = N'1', @Actual = @n;

-- XOR check: a member row with both ids is refused
DECLARE @App BIGINT = (SELECT TOP 1 Id FROM Location.AppUser WHERE Initials = N'SYS');
INSERT INTO Quality.ControlledRun (RunNumber, ControlledRunStatusId, Reason, OpenedByUserId) VALUES (N'CRTEST1', 1, N'schema test', @App);
DECLARE @Run BIGINT = SCOPE_IDENTITY();
DECLARE @err NVARCHAR(10) = N'0';
BEGIN TRY
    INSERT INTO Quality.ControlledRunMember (ControlledRunId, LotId, ContainerId, ControlledRunJoinMethodId, CrtSetByRun, AddedByUserId)
    VALUES (@Run, NULL, NULL, 1, 0, @App);
END TRY BEGIN CATCH SET @err = N'1'; END CATCH
EXEC test.Assert_IsEqual @TestName = N'[Schema] member with neither LotId nor ContainerId refused', @Expected = N'1', @Actual = @err;

-- auto-join without a part is refused
SET @err = N'0';
BEGIN TRY
    INSERT INTO Quality.ControlledRun (RunNumber, ControlledRunStatusId, Reason, OpenedByUserId, AutoJoinEnabled) VALUES (N'CRTEST2', 1, N'x', @App, 1);
END TRY BEGIN CATCH SET @err = N'1'; END CATCH
EXEC test.Assert_IsEqual @TestName = N'[Schema] AutoJoinEnabled without SelectionItemId refused', @Expected = N'1', @Actual = @err;

DELETE FROM Quality.ControlledRun WHERE RunNumber LIKE N'CRTEST%';
GO
EXEC test.EndTestFile;
GO
```

- [ ] **Step 2: Run it and watch it fail**

Run the folder command. Expected: FAIL — `Invalid object name 'Quality.ControlledRunStatusCode'` (the file throws; that is the expected failure).

- [ ] **Step 3: Write the migration**

`sql/migrations/versioned/0109_controlled_run.sql`. Header comment: what it is, that it is piece 1 of 6 and must not deploy alone, and the D-numbers from the spec. Body:

```sql
IF EXISTS (SELECT 1 FROM dbo.SchemaVersion WHERE MigrationId = N'0109_controlled_run')
BEGIN PRINT 'Migration 0109 already applied -- skipping.'; RETURN; END
GO

-- ---- 1. Code tables (read-only) ----
IF OBJECT_ID(N'Quality.ControlledRunStatusCode', N'U') IS NULL
BEGIN
    CREATE TABLE Quality.ControlledRunStatusCode (
        Id   BIGINT        NOT NULL IDENTITY(1,1) CONSTRAINT PK_ControlledRunStatusCode PRIMARY KEY,
        Code NVARCHAR(20)  NOT NULL,
        Name NVARCHAR(100) NOT NULL,
        CONSTRAINT UQ_ControlledRunStatusCode_Code UNIQUE (Code));
    SET IDENTITY_INSERT Quality.ControlledRunStatusCode ON;
    INSERT INTO Quality.ControlledRunStatusCode (Id, Code, Name) VALUES
        (1, N'Open', N'Open'), (2, N'Closed', N'Closed'), (3, N'Cancelled', N'Cancelled');
    SET IDENTITY_INSERT Quality.ControlledRunStatusCode OFF;
END
GO
IF OBJECT_ID(N'Quality.ControlledRunJoinMethod', N'U') IS NULL
BEGIN
    CREATE TABLE Quality.ControlledRunJoinMethod (
        Id   BIGINT        NOT NULL IDENTITY(1,1) CONSTRAINT PK_ControlledRunJoinMethod PRIMARY KEY,
        Code NVARCHAR(20)  NOT NULL,
        Name NVARCHAR(100) NOT NULL,
        CONSTRAINT UQ_ControlledRunJoinMethod_Code UNIQUE (Code));
    SET IDENTITY_INSERT Quality.ControlledRunJoinMethod ON;
    INSERT INTO Quality.ControlledRunJoinMethod (Id, Code, Name) VALUES
        (1, N'Selected', N'Selected'), (2, N'Manual', N'Scanned in'),
        (3, N'AutoJoined', N'New production'), (4, N'Descendant', N'Made from a member');
    SET IDENTITY_INSERT Quality.ControlledRunJoinMethod OFF;
END
GO
IF OBJECT_ID(N'Quality.ControlledRunMemberEndReason', N'U') IS NULL
BEGIN
    CREATE TABLE Quality.ControlledRunMemberEndReason (
        Id   BIGINT        NOT NULL IDENTITY(1,1) CONSTRAINT PK_ControlledRunMemberEndReason PRIMARY KEY,
        Code NVARCHAR(20)  NOT NULL,
        Name NVARCHAR(100) NOT NULL,
        CONSTRAINT UQ_ControlledRunMemberEndReason_Code UNIQUE (Code));
    SET IDENTITY_INSERT Quality.ControlledRunMemberEndReason ON;
    INSERT INTO Quality.ControlledRunMemberEndReason (Id, Code, Name) VALUES
        (1, N'Removed', N'Removed'), (2, N'RunClosed', N'Super-lot closed'), (3, N'RunCancelled', N'Super-lot cancelled');
    SET IDENTITY_INSERT Quality.ControlledRunMemberEndReason OFF;
END
GO

-- ---- 2. Quality.ControlledRun ----
IF OBJECT_ID(N'Quality.ControlledRun', N'U') IS NULL
BEGIN
    CREATE TABLE Quality.ControlledRun (
        Id                    BIGINT        NOT NULL IDENTITY(1,1) CONSTRAINT PK_ControlledRun PRIMARY KEY,
        RunNumber             NVARCHAR(15)  NOT NULL,
        ControlledRunStatusId BIGINT        NOT NULL CONSTRAINT FK_ControlledRun_Status REFERENCES Quality.ControlledRunStatusCode(Id),
        Reason                NVARCHAR(500) NOT NULL,
        AnchorLotId           BIGINT        NULL CONSTRAINT FK_ControlledRun_AnchorLot REFERENCES Lots.Lot(Id),
        SelectionItemId       BIGINT        NULL CONSTRAINT FK_ControlledRun_Item REFERENCES Parts.Item(Id),
        SelectionLocationId   BIGINT        NULL CONSTRAINT FK_ControlledRun_Location REFERENCES Location.Location(Id),
        SelectionFromAt       DATETIME2(3)  NULL,
        SelectionToAt         DATETIME2(3)  NULL,
        IncludeDescendants    BIT           NOT NULL CONSTRAINT DF_ControlledRun_IncludeDescendants DEFAULT (0),
        AutoJoinEnabled       BIT           NOT NULL CONSTRAINT DF_ControlledRun_AutoJoinEnabled DEFAULT (0),
        AutoJoinEndedAt       DATETIME2(3)  NULL,
        AutoJoinEndedByUserId BIGINT        NULL CONSTRAINT FK_ControlledRun_AutoJoinEndedBy REFERENCES Location.AppUser(Id),
        OpenedByUserId        BIGINT        NOT NULL CONSTRAINT FK_ControlledRun_OpenedBy REFERENCES Location.AppUser(Id),
        OpenedAt              DATETIME2(3)  NOT NULL CONSTRAINT DF_ControlledRun_OpenedAt DEFAULT (SYSUTCDATETIME()),
        OpenedAtTerminalId    BIGINT        NULL CONSTRAINT FK_ControlledRun_Terminal REFERENCES Location.Location(Id),
        ClosedByUserId        BIGINT        NULL CONSTRAINT FK_ControlledRun_ClosedBy REFERENCES Location.AppUser(Id),
        ClosedAt              DATETIME2(3)  NULL,
        CloseRemarks          NVARCHAR(500) NULL,
        RowVersion            ROWVERSION    NOT NULL,
        CONSTRAINT UQ_ControlledRun_RunNumber UNIQUE (RunNumber),
        CONSTRAINT CK_ControlledRun_Reason CHECK (LEN(LTRIM(RTRIM(Reason))) > 0),
        CONSTRAINT CK_ControlledRun_ClosePaired CHECK (
            (ClosedByUserId IS NULL AND ClosedAt IS NULL) OR (ClosedByUserId IS NOT NULL AND ClosedAt IS NOT NULL)),
        CONSTRAINT CK_ControlledRun_AutoJoinNeedsItem CHECK (AutoJoinEnabled = 0 OR SelectionItemId IS NOT NULL));

    CREATE INDEX IX_ControlledRun_Open ON Quality.ControlledRun (ControlledRunStatusId, OpenedAt)
        WHERE ControlledRunStatusId = 1;
    -- Read by Lots.ufn_CrtForMint on EVERY mint in the plant. Keep it a seek on a tiny set.
    CREATE INDEX IX_ControlledRun_AutoJoin ON Quality.ControlledRun (SelectionItemId)
        INCLUDE (SelectionLocationId) WHERE ControlledRunStatusId = 1 AND AutoJoinEnabled = 1;

    EXEC sys.sp_addextendedproperty @name = N'MS_Description',
        @value = N'A super-lot: one quality case grouping LOTs and containers placed on a Controlled Run Tag for the same reason. Members are in Quality.ControlledRunMember. Membership never blocks by itself - joining sets Lots.Lot.CrtActive.',
        @level0type = N'SCHEMA', @level0name = N'Quality', @level1type = N'TABLE', @level1name = N'ControlledRun';
END
GO

-- ---- 3. Quality.ControlledRunMember ----
IF OBJECT_ID(N'Quality.ControlledRunMember', N'U') IS NULL
BEGIN
    CREATE TABLE Quality.ControlledRunMember (
        Id                             BIGINT        NOT NULL IDENTITY(1,1) CONSTRAINT PK_ControlledRunMember PRIMARY KEY,
        ControlledRunId                BIGINT        NOT NULL CONSTRAINT FK_ControlledRunMember_Run REFERENCES Quality.ControlledRun(Id),
        LotId                          BIGINT        NULL CONSTRAINT FK_ControlledRunMember_Lot REFERENCES Lots.Lot(Id),
        ContainerId                    BIGINT        NULL CONSTRAINT FK_ControlledRunMember_Container REFERENCES Lots.Container(Id),
        ControlledRunJoinMethodId      BIGINT        NOT NULL CONSTRAINT FK_ControlledRunMember_JoinMethod REFERENCES Quality.ControlledRunJoinMethod(Id),
        CrtSetByRun                    BIT           NOT NULL,
        AddedByUserId                  BIGINT        NOT NULL CONSTRAINT FK_ControlledRunMember_AddedBy REFERENCES Location.AppUser(Id),
        AddedAt                        DATETIME2(3)  NOT NULL CONSTRAINT DF_ControlledRunMember_AddedAt DEFAULT (SYSUTCDATETIME()),
        EndedAt                        DATETIME2(3)  NULL,
        EndedByUserId                  BIGINT        NULL CONSTRAINT FK_ControlledRunMember_EndedBy REFERENCES Location.AppUser(Id),
        ControlledRunMemberEndReasonId BIGINT        NULL CONSTRAINT FK_ControlledRunMember_EndReason REFERENCES Quality.ControlledRunMemberEndReason(Id),
        EndRemarks                     NVARCHAR(500) NULL,
        CONSTRAINT CK_ControlledRunMember_LotXorContainer CHECK (
            (LotId IS NOT NULL AND ContainerId IS NULL) OR (LotId IS NULL AND ContainerId IS NOT NULL)),
        CONSTRAINT CK_ControlledRunMember_EndPaired CHECK (
            (EndedAt IS NULL AND EndedByUserId IS NULL AND ControlledRunMemberEndReasonId IS NULL) OR
            (EndedAt IS NOT NULL AND EndedByUserId IS NOT NULL AND ControlledRunMemberEndReasonId IS NOT NULL)));

    -- D4: one OPEN membership per unit across ALL runs.
    CREATE UNIQUE INDEX UX_ControlledRunMember_OpenLot ON Quality.ControlledRunMember (LotId)
        WHERE EndedAt IS NULL AND LotId IS NOT NULL;
    CREATE UNIQUE INDEX UX_ControlledRunMember_OpenContainer ON Quality.ControlledRunMember (ContainerId)
        WHERE EndedAt IS NULL AND ContainerId IS NOT NULL;
    CREATE INDEX IX_ControlledRunMember_Run ON Quality.ControlledRunMember (ControlledRunId, EndedAt);

    EXEC sys.sp_addextendedproperty @name = N'MS_Description',
        @value = N'One LOT or one container in a super-lot (never both). WIP is listed as LOTs; packed finished goods as the container. EndedAt NULL = currently a member; a unit has at most one open membership.',
        @level0type = N'SCHEMA', @level0name = N'Quality', @level1type = N'TABLE', @level1name = N'ControlledRunMember';
END
GO

-- ---- 4. Quality.ControlledRunLabel (append-only print log) ----
IF OBJECT_ID(N'Quality.ControlledRunLabel', N'U') IS NULL
BEGIN
    CREATE TABLE Quality.ControlledRunLabel (
        Id                 BIGINT        NOT NULL IDENTITY(1,1) CONSTRAINT PK_ControlledRunLabel PRIMARY KEY,
        ControlledRunId    BIGINT        NOT NULL CONSTRAINT FK_ControlledRunLabel_Run REFERENCES Quality.ControlledRun(Id),
        Copies             INT           NOT NULL,
        ZplContent         NVARCHAR(MAX) NOT NULL,
        PrinterName        NVARCHAR(100) NULL,
        PrintedByUserId    BIGINT        NOT NULL CONSTRAINT FK_ControlledRunLabel_PrintedBy REFERENCES Location.AppUser(Id),
        TerminalLocationId BIGINT        NULL CONSTRAINT FK_ControlledRunLabel_Terminal REFERENCES Location.Location(Id),
        PrintedAt          DATETIME2(3)  NOT NULL CONSTRAINT DF_ControlledRunLabel_PrintedAt DEFAULT (SYSUTCDATETIME()));
    CREATE INDEX IX_ControlledRunLabel_Run ON Quality.ControlledRunLabel (ControlledRunId, PrintedAt);

    EXEC sys.sp_addextendedproperty @name = N'MS_Description',
        @value = N'Append-only log of super-lot label print requests (one row per request, Copies labels each).',
        @level0type = N'SCHEMA', @level0name = N'Quality', @level1type = N'TABLE', @level1name = N'ControlledRunLabel';
END
GO

-- ---- 5. Run-number sequence ----
IF NOT EXISTS (SELECT 1 FROM Lots.IdentifierSequence WHERE Code = N'ControlledRun')
    INSERT INTO Lots.IdentifierSequence (Code, Name, Description, FormatString, StartingValue, EndingValue, LastValue)
    VALUES (N'ControlledRun', N'Super-lot number', N'Quality.ControlledRun.RunNumber counter.', N'CR{0:D6}', 1, 999999, 0);
GO

-- ---- 6. Label type + template ----
IF NOT EXISTS (SELECT 1 FROM Lots.LabelTypeCode WHERE Code = N'ControlledRun')
    INSERT INTO Lots.LabelTypeCode (Code, Name) VALUES (N'ControlledRun', N'Super-lot Label');
GO
DECLARE @TypeId BIGINT = (SELECT Id FROM Lots.LabelTypeCode WHERE Code = N'ControlledRun');
DECLARE @Zpl NVARCHAR(MAX) =
      N'^XA^LH0,0^PW812'
    + N'^FO0,0^GB812,110,110^FS'
    + N'^FO0,20^A0N,84,84^FB812,1,0,C^FR^FDSUPER-LOT^FS'
    + N'^FO0,128^A0N,132,112^FB812,1,0,C^FD{RunNumber}^FS'
    + N'^FO200,272^BY3,3,110^BCN,110,N,N,N^FD{RunNumber}^FS'
    + N'^FO40,406^A0N,36,36^FD{PartNumber}^FS'
    + N'^FO40,450^A0N,26,26^FB730,2,0,L^FD{Reason}^FS'
    + N'^FO40,512^A0N,24,24^FDOpened {OpenedAt} by {OpenedBy}^FS'
    + N'^FO0,548^GB812,61,61^FS'
    + N'^FO0,562^A0N,34,34^FB812,1,0,C^FR^FDQUALITY - DO NOT USE - SCAN FOR STATUS^FS'
    + N'^PQ{Copies}^XZ';
IF @TypeId IS NOT NULL
   AND NOT EXISTS (SELECT 1 FROM Lots.LabelTemplate WHERE LabelTypeCodeId = @TypeId AND DeprecatedAt IS NULL)
    INSERT INTO Lots.LabelTemplate (LabelTypeCodeId, ZplBody) VALUES (@TypeId, @Zpl);
GO

-- ---- 7. Audit codes (plain PKs, not identity: next free id, guarded by Code) ----
IF NOT EXISTS (SELECT 1 FROM Audit.LogEntityType WHERE Code = N'ControlledRun')
BEGIN
    DECLARE @EntId BIGINT = (SELECT ISNULL(MAX(Id), 0) + 1 FROM Audit.LogEntityType);
    INSERT INTO Audit.LogEntityType (Id, Code, Name, Description)
    VALUES (@EntId, N'ControlledRun', N'Super-lot', N'Quality.ControlledRun - a super-lot (routes to OperationLog).');
END
GO
DECLARE @Ev TABLE (Code NVARCHAR(50), Name NVARCHAR(200), Description NVARCHAR(500), Ord INT IDENTITY(1,1));
INSERT INTO @Ev (Code, Name, Description) VALUES
    (N'ControlledRunOpened',        N'Super-lot Opened',         N'A super-lot was opened.'),
    (N'ControlledRunMemberAdded',   N'Super-lot Member Added',   N'LOTs or containers were added to a super-lot.'),
    (N'ControlledRunMemberRemoved', N'Super-lot Member Removed', N'A LOT or container was removed from a super-lot.'),
    (N'ControlledRunWindowChanged', N'Super-lot Window Changed', N'Automatic adding of new production was ended or resumed.'),
    (N'ControlledRunClosed',        N'Super-lot Closed',         N'A super-lot was closed.'),
    (N'ControlledRunCancelled',     N'Super-lot Cancelled',      N'A super-lot was cancelled.'),
    (N'ControlledRunLabelPrinted',  N'Super-lot Label Printed',  N'Super-lot labels were printed.');
DECLARE @Base BIGINT = (SELECT ISNULL(MAX(Id), 0) FROM Audit.LogEventType);
INSERT INTO Audit.LogEventType (Id, Code, Name, Description)
SELECT @Base + ROW_NUMBER() OVER (ORDER BY e.Ord), e.Code, e.Name, e.Description
FROM @Ev e
WHERE NOT EXISTS (SELECT 1 FROM Audit.LogEventType x WHERE x.Code = e.Code);
GO

IF OBJECT_ID(N'Quality.ControlledRunMember', N'U') IS NULL
    THROW 51000, 'Migration 0109: Quality.ControlledRunMember did not land.', 1;
GO
IF NOT EXISTS (SELECT 1 FROM dbo.SchemaVersion WHERE MigrationId = N'0109_controlled_run')
    INSERT INTO dbo.SchemaVersion (MigrationId, Description)
    VALUES (N'0109_controlled_run',
            N'Super-lot (Controlled Run): Quality.ControlledRun / ControlledRunMember / ControlledRunLabel + 3 code tables; ControlledRun sequence, label type + template, audit codes. Piece 1 of 6 - do NOT deploy alone.');
GO
PRINT 'Migration 0109 (controlled_run) applied.';
GO
```

Before saving, confirm the column lists of `Lots.IdentifierSequence`, `Lots.LabelTypeCode` and `Audit.LogEntityType` against their `CREATE TABLE` in migrations `0020`, `0004` and `0001`; adjust the INSERT column lists if any required column is missing.

- [ ] **Step 4: ASCII byte scan**

```powershell
$b = [IO.File]::ReadAllBytes("sql\migrations\versioned\0109_controlled_run.sql"); ($b | Where-Object { $_ -gt 126 }).Count
```

Expected: `0`.

- [ ] **Step 5: Run the test and watch it pass**

Run the folder command. Expected: 13 assertions, 0 failures.

- [ ] **Step 6: Commit**

```powershell
git add -- sql/migrations/versioned/0109_controlled_run.sql sql/tests/0109_ControlledRun/010_schema.sql
git commit -m "feat(quality): controlled run (super-lot) schema -- migration 0109"
```

---

### Task 2: Resolve and judge candidate members

**Files:**
- Create: `sql/migrations/repeatable/R__Quality_ufn_zz_ControlledRunResolveMembers.sql`
- Test: `sql/tests/0109_ControlledRun/020_resolve_members.sql`

**Interfaces:**
- Produces: inline TVF `Quality.ufn_ControlledRunResolveMembers(@MembersJson NVARCHAR(MAX))`. Input: `[{"lotId":n} | {"containerId":n}, ...]`. One row per DISTINCT resolved unit: `LotId BIGINT NULL, ContainerId BIGINT NULL, Kind NVARCHAR(10) ('Lot'|'Container'), DisplayName NVARCHAR(60), ItemId BIGINT, CurrentLocationId BIGINT, StatusCode NVARCHAR(20), PieceCount INT, ProducedAt DATETIME2(3) (UTC), CrtActive BIT, IneligibleReason NVARCHAR(100) NULL`. `IneligibleReason IS NULL` means eligible.

- [ ] **Step 1: Write the failing test**

`020_resolve_members.sql` — after the shared teardown and fixture variables, build: `TEST-CR-A` (Good), `TEST-CR-SCRAP` (status 3), `TEST-CR-CLOSED` (status 4, not a tray), `TEST-CR-FG1` and `TEST-CR-FG2` (status 4) as trays 1 and 2 of one Complete container `@Con`, `TEST-CR-FGS` (status 4) as the tray of a Shipped container `@ConShipped`. Then:

```sql
DECLARE @j NVARCHAR(MAX) = (SELECT * FROM (VALUES (@LotA, NULL), (@LotScrap, NULL), (@LotClosed, NULL),
        (@LotFg1, NULL), (@LotFg2, NULL), (@LotFgS, NULL), (CAST(999999999 AS BIGINT), NULL), (NULL, @Con)) v(lotId, containerId)
    FOR JSON PATH);
DECLARE @r TABLE (LotId BIGINT, ContainerId BIGINT, Kind NVARCHAR(10), DisplayName NVARCHAR(60), ItemId BIGINT,
    CurrentLocationId BIGINT, StatusCode NVARCHAR(20), PieceCount INT, ProducedAt DATETIME2(3), CrtActive BIT, IneligibleReason NVARCHAR(100));
INSERT INTO @r SELECT * FROM Quality.ufn_ControlledRunResolveMembers(@j);
DECLARE @n NVARCHAR(100);

SET @n = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM @r);
EXEC test.Assert_IsEqual @TestName = N'[Resolve] 8 inputs fold to 6 units (two trays + the container itself = one container)', @Expected = N'6', @Actual = @n;
SET @n = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM @r WHERE ContainerId = @Con);
EXEC test.Assert_IsEqual @TestName = N'[Resolve] tray LOTs fold to their container exactly once', @Expected = N'1', @Actual = @n;
SET @n = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM @r WHERE LotId IN (@LotFg1, @LotFg2, @LotFgS));
EXEC test.Assert_IsEqual @TestName = N'[Resolve] a tray LOT is never returned as a LOT', @Expected = N'0', @Actual = @n;
SET @n = (SELECT ISNULL(IneligibleReason, N'(eligible)') FROM @r WHERE LotId = @LotA);
EXEC test.Assert_IsEqual @TestName = N'[Resolve] Good LOT eligible', @Expected = N'(eligible)', @Actual = @n;
SET @n = (SELECT ISNULL(IneligibleReason, N'(eligible)') FROM @r WHERE ContainerId = @Con);
EXEC test.Assert_IsEqual @TestName = N'[Resolve] completed unshipped container eligible (spec 9.2)', @Expected = N'(eligible)', @Actual = @n;
SET @n = (SELECT IneligibleReason FROM @r WHERE LotId = @LotScrap);
EXEC test.Assert_IsEqual @TestName = N'[Resolve] scrapped', @Expected = N'Scrapped', @Actual = @n;
SET @n = (SELECT IneligibleReason FROM @r WHERE LotId = @LotClosed);
EXEC test.Assert_IsEqual @TestName = N'[Resolve] closed non-tray LOT', @Expected = N'Closed', @Actual = @n;
SET @n = (SELECT IneligibleReason FROM @r WHERE ContainerId = @ConShipped);
EXEC test.Assert_IsEqual @TestName = N'[Resolve] shipped container', @Expected = N'Already shipped', @Actual = @n;
SET @n = (SELECT IneligibleReason FROM @r WHERE LotId = 999999999);
EXEC test.Assert_IsEqual @TestName = N'[Resolve] unknown LOT', @Expected = N'LOT not found', @Actual = @n;

-- already in an open run
INSERT INTO Quality.ControlledRun (RunNumber, ControlledRunStatusId, Reason, OpenedByUserId) VALUES (N'CR000900', 1, N'resolve test', @App);
DECLARE @Run BIGINT = SCOPE_IDENTITY();
INSERT INTO Quality.ControlledRunMember (ControlledRunId, LotId, ControlledRunJoinMethodId, CrtSetByRun, AddedByUserId) VALUES (@Run, @LotA, 1, 0, @App);
SET @n = (SELECT IneligibleReason FROM Quality.ufn_ControlledRunResolveMembers((SELECT @LotA AS lotId FOR JSON PATH)));
EXEC test.Assert_IsEqual @TestName = N'[Resolve] already in an open super-lot names it', @Expected = N'Already in CR000900', @Actual = @n;

SET @n = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM Quality.ufn_ControlledRunResolveMembers(NULL));
EXEC test.Assert_IsEqual @TestName = N'[Resolve] NULL json -> no rows, no error', @Expected = N'0', @Actual = @n;
SET @n = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM Quality.ufn_ControlledRunResolveMembers(N'[{"lotId":"abc"},{}]'));
EXEC test.Assert_IsEqual @TestName = N'[Resolve] junk entries are ignored, not errors', @Expected = N'0', @Actual = @n;
```

End with teardown batch + `EXEC test.EndTestFile;`. (12 assertions.)

- [ ] **Step 2: Run it and watch it fail**

Expected: `Invalid object name 'Quality.ufn_ControlledRunResolveMembers'`.

- [ ] **Step 3: Write the function**

```sql
CREATE OR ALTER FUNCTION Quality.ufn_ControlledRunResolveMembers (@MembersJson NVARCHAR(MAX))
RETURNS TABLE
AS
RETURN
(
    WITH Raw AS (
        SELECT TRY_CAST(JSON_VALUE(j.value, N'$.lotId')       AS BIGINT) AS LotId,
               TRY_CAST(JSON_VALUE(j.value, N'$.containerId') AS BIGINT) AS ContainerId
        FROM OPENJSON(CASE WHEN ISJSON(@MembersJson) = 1 THEN @MembersJson ELSE N'[]' END) j
    ),
    Folded AS (   -- D3: a finished-good tray LOT is represented by its container
        SELECT DISTINCT
               CASE WHEN r.ContainerId IS NULL AND t.ContainerId IS NULL THEN r.LotId END AS LotId,
               COALESCE(r.ContainerId, t.ContainerId)                                     AS ContainerId
        FROM Raw r
        LEFT JOIN Lots.ContainerTray t ON r.ContainerId IS NULL AND t.FinishedGoodLotId = r.LotId
        WHERE r.LotId IS NOT NULL OR r.ContainerId IS NOT NULL
    )
    SELECT
        f.LotId,
        f.ContainerId,
        CASE WHEN f.ContainerId IS NOT NULL THEN N'Container' ELSE N'Lot' END AS Kind,
        CAST(CASE WHEN f.ContainerId IS NOT NULL THEN N'Container ' + CAST(f.ContainerId AS NVARCHAR(20))
                  ELSE ISNULL(l.LotName, N'LOT ' + CAST(f.LotId AS NVARCHAR(20))) END AS NVARCHAR(60)) AS DisplayName,
        COALESCE(c.ItemId, l.ItemId)                       AS ItemId,
        COALESCE(c.CurrentLocationId, l.CurrentLocationId) AS CurrentLocationId,
        COALESCE(cs.Code, ls.Code)                         AS StatusCode,
        CASE WHEN f.ContainerId IS NOT NULL THEN ISNULL(ct.Pieces, 0) ELSE l.PieceCount END AS PieceCount,
        COALESCE(c.OpenedAt, l.CreatedAt)                  AS ProducedAt,
        CONVERT(BIT, CASE WHEN f.ContainerId IS NOT NULL THEN ISNULL(ct.AnyCrt, 0) ELSE ISNULL(l.CrtActive, 0) END) AS CrtActive,
        CAST(CASE
            WHEN f.ContainerId IS NOT NULL AND c.Id IS NULL THEN N'Container not found'
            WHEN f.ContainerId IS NULL     AND l.Id IS NULL THEN N'LOT not found'
            WHEN om.RunNumber IS NOT NULL THEN N'Already in ' + om.RunNumber
            WHEN cs.Code = N'Shipped' THEN N'Already shipped'
            WHEN cs.Code = N'Void'    THEN N'Voided'
            WHEN ls.Code = N'Scrap'   THEN N'Scrapped'
            WHEN ls.Code = N'Closed'  THEN N'Closed'
        END AS NVARCHAR(100)) AS IneligibleReason
    FROM Folded f
    LEFT JOIN Lots.Lot l                  ON f.ContainerId IS NULL AND l.Id = f.LotId
    LEFT JOIN Lots.LotStatusCode ls       ON ls.Id = l.LotStatusId
    LEFT JOIN Lots.Container c            ON c.Id = f.ContainerId
    LEFT JOIN Lots.ContainerStatusCode cs ON cs.Id = c.ContainerStatusCodeId
    OUTER APPLY (
        SELECT SUM(tl.PieceCount) AS Pieces, MAX(CAST(tl.CrtActive AS INT)) AS AnyCrt
        FROM Lots.ContainerTray t2 JOIN Lots.Lot tl ON tl.Id = t2.FinishedGoodLotId
        WHERE t2.ContainerId = f.ContainerId
    ) ct
    OUTER APPLY (
        SELECT TOP 1 r.RunNumber
        FROM Quality.ControlledRunMember m JOIN Quality.ControlledRun r ON r.Id = m.ControlledRunId
        WHERE m.EndedAt IS NULL
          AND ((f.ContainerId IS NOT NULL AND m.ContainerId = f.ContainerId)
            OR (f.ContainerId IS NULL     AND m.LotId = f.LotId))
    ) om
);
GO
```

Header comment must say: the `zz_` in the file name is a deploy-order marker (functions get no deferred name resolution), copy the wording from `R__Lots_ufn_zz_CrtBlocks.sql`.

- [ ] **Step 4: Run and pass** — 13 + 12 = 25 assertions, 0 failures.

- [ ] **Step 5: Commit**

```powershell
git add -- sql/migrations/repeatable/R__Quality_ufn_zz_ControlledRunResolveMembers.sql sql/tests/0109_ControlledRun/020_resolve_members.sql
git commit -m "feat(quality): resolve + judge super-lot candidate members in one function"
```

---

### Task 3: Preview a selection

**Files:**
- Create: `sql/migrations/repeatable/R__Quality_ControlledRun_PreviewSelection.sql`
- Test: `sql/tests/0109_ControlledRun/030_preview.sql`

**Interfaces:**
- Consumes: `Quality.ufn_ControlledRunResolveMembers`.
- Produces: `Quality.ControlledRun_PreviewSelection(@AnchorLotId BIGINT = NULL, @ItemId BIGINT = NULL, @LocationId BIGINT = NULL, @FromAtEastern DATETIME2(3) = NULL, @ToAtEastern DATETIME2(3) = NULL, @IncludeDescendants BIT = 0)`. Read proc. Columns: `Kind, LotId, ContainerId, DisplayName, PartNumber, CurrentLocationName, StatusCode, PieceCount, ProducedAt (ET), CrtActive, FoundBy, Eligible BIT, IneligibleReason`, ordered `ProducedAt` ascending.

Rules: the by-production arm runs only when `@ItemId` is given AND a from-time exists (explicit, or the anchor's `CreatedAt`). `@FromAtEastern` / `@ToAtEastern` are wall-clock Eastern and converted in the proc. The anchor is always a candidate. `FoundBy` is `Suspect LOT`, `Line + time`, or `Made from suspect LOT`, first match in that order.

- [ ] **Step 1: Write the failing test**

Fixture: `TEST-CR-ANCHOR` (@Item, minted at `@Term`, 3 h ago), `TEST-CR-IN` (@Item, `@Term`, 2 h ago), `TEST-CR-EARLY` (@Item, `@Term`, 5 h ago), `TEST-CR-OTHERLINE` (@Item, `@TermOther`, 2 h ago), `TEST-CR-OTHERPART` (@Item2, `@Term`, 2 h ago), `TEST-CR-NOTERM` (@Item, `CreatedAtTerminalId = NULL`, 2 h ago), `TEST-CR-CHILD` (@Item2, 1 h ago, descendant of anchor at depth 1), `TEST-CR-GRAND` (status 4, descendant at depth 2, tray 1 of Complete container `@Con`). Insert the closure rows:

```sql
INSERT INTO Lots.LotGenealogyClosure (AncestorLotId, DescendantLotId, Depth) VALUES
    (@LotAnchor, @LotAnchor, 0), (@LotChild, @LotChild, 0), (@LotGrand, @LotGrand, 0),
    (@LotAnchor, @LotChild, 1), (@LotChild, @LotGrand, 1), (@LotAnchor, @LotGrand, 2);
```

Capture into `@p` with the 13-column shape, then assert:

```sql
DECLARE @p TABLE (Kind NVARCHAR(10), LotId BIGINT, ContainerId BIGINT, DisplayName NVARCHAR(60), PartNumber NVARCHAR(100),
    CurrentLocationName NVARCHAR(200), StatusCode NVARCHAR(20), PieceCount INT, ProducedAt DATETIME2(3), CrtActive BIT,
    FoundBy NVARCHAR(40), Eligible BIT, IneligibleReason NVARCHAR(100));

-- A: part + line, window from the anchor, no genealogy
INSERT INTO @p EXEC Quality.ControlledRun_PreviewSelection @AnchorLotId = @LotAnchor, @ItemId = @Item, @LocationId = @Line;
-- expect ANCHOR + IN only
```

Assertions (15): A returns exactly 2 rows; A contains `TEST-CR-IN` with `FoundBy = 'Line + time'`; anchor `FoundBy = 'Suspect LOT'`; A excludes `EARLY` (before the window), `OTHERLINE`, `OTHERPART`; **A excludes `NOTERM` (Review Focus 4 — pinned)**; B (`@IncludeDescendants = 1`, no item) returns anchor + `CHILD` + container `@Con` = 3 rows; the container row has `Kind = 'Container'`, `FoundBy = 'Made from suspect LOT'`, `Eligible = 1`; `TEST-CR-GRAND` never appears as a LOT; C (`@ItemId` only, no anchor, no from) returns 0 rows; D (explicit `@FromAtEastern` 6 h ago converted to Eastern, `@ItemId`, no line) includes `EARLY`, `OTHERLINE` and `NOTERM`; rows are ordered oldest first; `ProducedAt` of the anchor equals its `CreatedAt` converted to Eastern; calling the proc writes nothing (`ControlledRunMember` count unchanged and `TEST-CR-IN.CrtActive` still 0).

For D compute the Eastern argument in the test with:
`DECLARE @FromEt DATETIME2(3) = CAST(DATEADD(HOUR, -6, SYSUTCDATETIME()) AT TIME ZONE 'UTC' AT TIME ZONE 'Eastern Standard Time' AS DATETIME2(3));`

- [ ] **Step 2: Run it and watch it fail** — proc does not exist.

- [ ] **Step 3: Write the proc**

```sql
CREATE OR ALTER PROCEDURE Quality.ControlledRun_PreviewSelection
    @AnchorLotId        BIGINT       = NULL,
    @ItemId             BIGINT       = NULL,
    @LocationId         BIGINT       = NULL,
    @FromAtEastern      DATETIME2(3) = NULL,
    @ToAtEastern        DATETIME2(3) = NULL,
    @IncludeDescendants BIT          = 0
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @FromUtc DATETIME2(3) = CAST(@FromAtEastern AT TIME ZONE 'Eastern Standard Time' AT TIME ZONE 'UTC' AS DATETIME2(3));
    DECLARE @ToUtc   DATETIME2(3) = CAST(@ToAtEastern   AT TIME ZONE 'Eastern Standard Time' AT TIME ZONE 'UTC' AS DATETIME2(3));
    IF @FromUtc IS NULL AND @AnchorLotId IS NOT NULL
        SET @FromUtc = (SELECT CreatedAt FROM Lots.Lot WHERE Id = @AnchorLotId);
    IF @ToUtc IS NULL SET @ToUtc = SYSUTCDATETIME();

    DECLARE @Cand TABLE (LotId BIGINT NOT NULL PRIMARY KEY, FoundRank INT NOT NULL);

    -- 1. the anchor itself
    IF @AnchorLotId IS NOT NULL AND EXISTS (SELECT 1 FROM Lots.Lot WHERE Id = @AnchorLotId)
        INSERT INTO @Cand (LotId, FoundRank) VALUES (@AnchorLotId, 1);

    -- 2. by production: part + (line) + window. Needs a part AND a start, or it is "everything".
    IF @ItemId IS NOT NULL AND @FromUtc IS NOT NULL
    BEGIN
        ;WITH Descendants AS (
            SELECT @LocationId AS Id WHERE @LocationId IS NOT NULL
            UNION ALL
            SELECT c.Id FROM Location.Location c INNER JOIN Descendants d ON c.ParentLocationId = d.Id
        )
        INSERT INTO @Cand (LotId, FoundRank)
        SELECT l.Id, 2
        FROM Lots.Lot l
        WHERE l.ItemId = @ItemId
          AND l.CreatedAt >= @FromUtc AND l.CreatedAt <= @ToUtc
          AND (@LocationId IS NULL OR l.CreatedAtTerminalId IN (SELECT Id FROM Descendants))
          AND NOT EXISTS (SELECT 1 FROM @Cand x WHERE x.LotId = l.Id)
        OPTION (MAXRECURSION 8);
    END

    -- 3. by genealogy: everything made from the anchor
    IF @IncludeDescendants = 1 AND @AnchorLotId IS NOT NULL
        INSERT INTO @Cand (LotId, FoundRank)
        SELECT gc.DescendantLotId, 3
        FROM Lots.LotGenealogyClosure gc
        WHERE gc.AncestorLotId = @AnchorLotId AND gc.Depth > 0
          AND NOT EXISTS (SELECT 1 FROM @Cand x WHERE x.LotId = gc.DescendantLotId);

    DECLARE @Json NVARCHAR(MAX) = (SELECT LotId AS lotId FROM @Cand FOR JSON PATH);

    SELECT
        r.Kind, r.LotId, r.ContainerId, r.DisplayName,
        i.PartNumber,
        loc.Name AS CurrentLocationName,
        r.StatusCode, r.PieceCount,
        CAST(r.ProducedAt AT TIME ZONE 'UTC' AT TIME ZONE 'Eastern Standard Time' AS DATETIME2(3)) AS ProducedAt,
        r.CrtActive,
        CASE fr.FoundRank WHEN 1 THEN N'Suspect LOT' WHEN 2 THEN N'Line + time' ELSE N'Made from suspect LOT' END AS FoundBy,
        CONVERT(BIT, CASE WHEN r.IneligibleReason IS NULL THEN 1 ELSE 0 END) AS Eligible,
        r.IneligibleReason
    FROM Quality.ufn_ControlledRunResolveMembers(@Json) r
    LEFT JOIN Parts.Item i          ON i.Id = r.ItemId
    LEFT JOIN Location.Location loc ON loc.Id = r.CurrentLocationId
    OUTER APPLY (
        -- a LOT keeps its own rank; a container takes the best rank of its tray LOTs
        SELECT MIN(c.FoundRank) AS FoundRank
        FROM @Cand c
        WHERE (r.ContainerId IS NULL AND c.LotId = r.LotId)
           OR (r.ContainerId IS NOT NULL AND c.LotId IN (SELECT t.FinishedGoodLotId FROM Lots.ContainerTray t WHERE t.ContainerId = r.ContainerId))
    ) fr
    ORDER BY r.ProducedAt ASC, r.ContainerId ASC, r.LotId ASC;
END;
GO
```

- [ ] **Step 4: Run and pass** — 25 + 15 = 40 assertions.

- [ ] **Step 5: Commit**

```powershell
git add -- sql/migrations/repeatable/R__Quality_ControlledRun_PreviewSelection.sql sql/tests/0109_ControlledRun/030_preview.sql
git commit -m "feat(quality): preview a super-lot selection by part, line, time and genealogy"
```

---

### Task 4: Apply members + open a super-lot

**Files:**
- Create: `sql/migrations/repeatable/R__Quality_ControlledRun_ApplyMembersInternal.sql`
- Create: `sql/migrations/repeatable/R__Quality_ControlledRun_Open.sql`
- Test: `sql/tests/0109_ControlledRun/040_open.sql`

**Interfaces:**
- Consumes: `Quality.ufn_ControlledRunResolveMembers`.
- Produces:
  - `Quality.ControlledRun_ApplyMembersInternal(@ControlledRunId BIGINT, @MembersJson NVARCHAR(MAX), @JoinMethodCode NVARCHAR(20), @AppUserId BIGINT, @TerminalLocationId BIGINT = NULL)` — **silent** (no result set, no status row). Inserts every ELIGIBLE resolved unit; silently skips ineligible ones. Must be called inside the caller's transaction. Never `ROLLBACK`s.
  - `Quality.ControlledRun_Open(@Reason NVARCHAR(500), @AnchorLotId BIGINT = NULL, @SelectionItemId BIGINT = NULL, @SelectionLocationId BIGINT = NULL, @SelectionFromAtEastern DATETIME2(3) = NULL, @SelectionToAtEastern DATETIME2(3) = NULL, @IncludeDescendants BIT = 0, @AutoJoinEnabled BIT = 0, @MembersJson NVARCHAR(MAX) = NULL, @AppUserId BIGINT, @TerminalLocationId BIGINT = NULL)` → `Status, Message, NewId`.

- [ ] **Step 1: Write the failing test**

Fixture: `TEST-CR-A` (Good, CrtActive 0), `TEST-CR-B` (Good, CrtActive 1), `TEST-CR-SCRAP`, an Open container `@ConOpen` with tray LOT `TEST-CR-FGO` (status 1 Good, CrtActive 0), a Complete container `@ConDone` with tray LOT `TEST-CR-FGD` (status 4, CrtActive 0). Result table `DECLARE @o TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);`

Assertions (20):

1. Open with A, B, both containers → Status 1.
2. `NewId` not null; `RunNumber = 'CR000001'`.
3. Four open members.
4. `TEST-CR-A.CrtActive = 1`.
5. Member A has `CrtSetByRun = 1`; member B has `CrtSetByRun = 0`.
6. `TEST-CR-FGO.CrtActive = 1` (open container's tray tagged).
7. `TEST-CR-FGD.CrtActive = 0` (Closed tray NOT tagged in this piece) and the `@ConDone` member has `CrtSetByRun = 0`.
8. `Lots.LotEventLog` has exactly one `CrtActivated` row for A, one for FGO, none for B.
9. One `ControlledRunOpened` row in `Audit.OperationLog` for the run, and its `Description` starts `CR000001`.
10. Join method of all four is `Selected`.
11. `SelectionFromAt` stored is the Eastern argument converted to UTC (pass a known value, compare).
12. Second Open naming A again → Status 0, message contains `Already in CR000001`, and **no second run row and the sequence did not advance** (`LastValue` still 1).
13. Open with one eligible + `TEST-CR-SCRAP` → Status 0, message contains `TEST-CR-SCRAP` and `Scrapped`; the eligible one was NOT added (all-or-nothing).
14. Open with blank reason → Status 0.
15. Open with `@MembersJson = NULL`, `@AutoJoinEnabled = 0` → Status 0, message `A super-lot needs at least one member.` **(Review Focus 5)**
16. Open with `@MembersJson = NULL`, `@AutoJoinEnabled = 1`, `@SelectionItemId = @Item` → Status 1, zero members **(Review Focus 5)**.
17. Open with `@AutoJoinEnabled = 1` and no item → Status 0, message `Keep adding new production needs a part.`
18. Open with unknown `@AnchorLotId` → Status 0.
19. Each rejection wrote an `Audit.FailureLog` row (count delta ≥ 5 across 12–18).
20. **Race (Review Focus 3):** simulate the loser by inserting an open membership for `TEST-CR-C` directly, then calling Open for C: Status 0 with a message naming it — never a raw error. (The pre-transaction eligibility check catches it; the unique index is the backstop and is covered by Task 1.)

- [ ] **Step 2: Run it and watch it fail.**

- [ ] **Step 3: Write `ControlledRun_ApplyMembersInternal`**

```sql
CREATE OR ALTER PROCEDURE Quality.ControlledRun_ApplyMembersInternal
    @ControlledRunId    BIGINT,
    @MembersJson        NVARCHAR(MAX),
    @JoinMethodCode     NVARCHAR(20),
    @AppUserId          BIGINT,
    @TerminalLocationId BIGINT = NULL
AS
BEGIN
    -- SILENT INTERNAL HELPER. No result set, no status row, no ROLLBACK: it runs
    -- inside the caller's transaction and an error dooms that transaction and
    -- surfaces in the caller's CATCH. That is what lets status-row procs
    -- (which may be captured by INSERT-EXEC) share it -- the same reason the
    -- Audit.Audit_Log* writers emit nothing.
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @JoinMethodId BIGINT = (SELECT Id FROM Quality.ControlledRunJoinMethod WHERE Code = @JoinMethodCode);
    DECLARE @RunNumber NVARCHAR(15) = (SELECT RunNumber FROM Quality.ControlledRun WHERE Id = @ControlledRunId);
    IF @JoinMethodId IS NULL OR @RunNumber IS NULL
        RAISERROR(N'ControlledRun_ApplyMembersInternal: unknown run or join method.', 16, 1);

    DECLARE @M TABLE (LotId BIGINT NULL, ContainerId BIGINT NULL);
    INSERT INTO @M (LotId, ContainerId)
    SELECT r.LotId, r.ContainerId
    FROM Quality.ufn_ControlledRunResolveMembers(@MembersJson) r
    WHERE r.IneligibleReason IS NULL;

    IF NOT EXISTS (SELECT 1 FROM @M) RETURN;

    -- ---- D5: set the tag. INLINED mirror of Lots.Lot_SetCrt (source of truth:
    --      R__Lots_Lot_SetCrt.sql). Same rule: a Closed LOT is never tagged here. ----
    DECLARE @Tagged TABLE (LotId BIGINT NOT NULL, LotName NVARCHAR(50) NOT NULL);
    UPDATE l
    SET CrtActive = 1, UpdatedAt = SYSUTCDATETIME(), UpdatedByUserId = @AppUserId
    OUTPUT inserted.Id, inserted.LotName INTO @Tagged (LotId, LotName)
    FROM Lots.Lot l
    INNER JOIN Lots.LotStatusCode sc ON sc.Id = l.LotStatusId
    WHERE l.CrtActive = 0
      AND sc.Code <> N'Closed'
      AND ( l.Id IN (SELECT LotId FROM @M WHERE LotId IS NOT NULL)
         OR l.Id IN (SELECT t.FinishedGoodLotId FROM Lots.ContainerTray t
                     WHERE t.ContainerId IN (SELECT ContainerId FROM @M WHERE ContainerId IS NOT NULL)) );

    INSERT INTO Quality.ControlledRunMember
        (ControlledRunId, LotId, ContainerId, ControlledRunJoinMethodId, CrtSetByRun, AddedByUserId)
    SELECT @ControlledRunId, m.LotId, m.ContainerId, @JoinMethodId,
           CONVERT(BIT, CASE
               WHEN m.LotId IS NOT NULL AND EXISTS (SELECT 1 FROM @Tagged g WHERE g.LotId = m.LotId) THEN 1
               WHEN m.ContainerId IS NOT NULL AND EXISTS (
                    SELECT 1 FROM @Tagged g JOIN Lots.ContainerTray t ON t.FinishedGoodLotId = g.LotId
                    WHERE t.ContainerId = m.ContainerId) THEN 1
               ELSE 0 END),
           @AppUserId
    FROM @M m;

    -- ---- one CrtActivated row per LOT tagged, so each LOT's own 20-year timeline
    --      is complete without knowing it was in a super-lot ----
    DECLARE @LotId BIGINT, @LotName NVARCHAR(50), @Activity NVARCHAR(500), @ActivityRaw NVARCHAR(MAX), @NewValue NVARCHAR(MAX);
    DECLARE tagged_cur CURSOR LOCAL FAST_FORWARD FOR SELECT LotId, LotName FROM @Tagged ORDER BY LotId;
    OPEN tagged_cur;
    FETCH NEXT FROM tagged_cur INTO @LotId, @LotName;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        SET @ActivityRaw = @LotName + N' ' + Audit.ufn_MidDot() + N' CRT ' + Audit.ufn_MidDot()
                         + N' Activated (super-lot ' + @RunNumber + N')';
        SET @Activity = Audit.ufn_TruncateActivity(@ActivityRaw);
        SET @NewValue = (
            SELECT CAST(1 AS BIT) AS CrtActive,
                   JSON_QUERY((SELECT @LotId AS Id, @LotName AS Code, @LotName AS Name FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)) AS Lot,
                   JSON_QUERY((SELECT @ControlledRunId AS Id, @RunNumber AS Code, @RunNumber AS Name FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)) AS ControlledRun
            FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);
        EXEC Audit.Audit_LogOperation
            @AppUserId = @AppUserId, @TerminalLocationId = @TerminalLocationId, @LocationId = NULL,
            @LogEntityTypeCode = N'Lot', @EntityId = @LotId, @LogEventTypeCode = N'CrtActivated',
            @LogSeverityCode = N'Info', @Description = @Activity,
            @OldValue = N'{"CrtActive":false}', @NewValue = @NewValue;
        FETCH NEXT FROM tagged_cur INTO @LotId, @LotName;
    END
    CLOSE tagged_cur; DEALLOCATE tagged_cur;
END;
GO
```

- [ ] **Step 4: Write `ControlledRun_Open`** using SKELETON (`<EVT>` = `ControlledRunOpened`, returns `NewId`).

Declarations before `BEGIN TRY`:

```sql
    DECLARE @FromUtc DATETIME2(3) = CAST(@SelectionFromAtEastern AT TIME ZONE 'Eastern Standard Time' AT TIME ZONE 'UTC' AS DATETIME2(3));
    DECLARE @ToUtc   DATETIME2(3) = CAST(@SelectionToAtEastern   AT TIME ZONE 'Eastern Standard Time' AT TIME ZONE 'UTC' AS DATETIME2(3));
    DECLARE @MemberCount INT, @Bad NVARCHAR(400);
```

Validations, in order (each is a SKELETON validation block):

| # | Condition | Message |
|---|---|---|
| 1 | `@AppUserId IS NULL OR @Reason IS NULL OR LTRIM(RTRIM(@Reason)) = N''` | `Required parameter missing (Reason, AppUserId).` |
| 2 | `NOT EXISTS (SELECT 1 FROM Location.AppUser WHERE Id = @AppUserId)` | `AppUser not found.` |
| 3 | `@AnchorLotId IS NOT NULL AND NOT EXISTS (SELECT 1 FROM Lots.Lot WHERE Id = @AnchorLotId)` | `Suspect LOT not found.` |
| 4 | `@SelectionItemId IS NOT NULL AND NOT EXISTS (SELECT 1 FROM Parts.Item WHERE Id = @SelectionItemId)` | `Part not found.` |
| 5 | `@SelectionLocationId IS NOT NULL AND NOT EXISTS (SELECT 1 FROM Location.Location WHERE Id = @SelectionLocationId)` | `Line or area not found.` |
| 6 | `@AutoJoinEnabled = 1 AND @SelectionItemId IS NULL` | `Keep adding new production needs a part.` |
| 7 | after `SELECT @MemberCount = COUNT(*) FROM Quality.ufn_ControlledRunResolveMembers(@MembersJson);` — `@MemberCount = 0 AND @AutoJoinEnabled = 0` | `A super-lot needs at least one member.` |
| 8 | after computing `@Bad` (below) — `@Bad IS NOT NULL` | `Cannot open: ` + `@Bad` |

`@Bad` (first three offenders, so the message fits 500 characters):

```sql
        SELECT @Bad = STRING_AGG(x.Txt, N'; ')
        FROM (SELECT TOP 3 r.DisplayName + N' (' + r.IneligibleReason + N')' AS Txt
              FROM Quality.ufn_ControlledRunResolveMembers(@MembersJson) r
              WHERE r.IneligibleReason IS NOT NULL
              ORDER BY r.DisplayName) x;
```

Mutation block:

```sql
        BEGIN TRANSACTION;

        -- Mint the run number INSIDE the tran (a rolled-back open does not burn a
        -- number). INLINED mirror of Lots.IdentifierSequence_Next: this proc is
        -- itself captured via INSERT-EXEC and nesting INSERT-EXEC is illegal. Same
        -- block as Lots.Lot_Create's LotName mint.
        DECLARE @SeqLast BIGINT, @SeqEnd BIGINT, @SeqFormat NVARCHAR(50), @SeqPrefix NVARCHAR(50), @SeqPad INT, @RunNumber NVARCHAR(15);
        SELECT @SeqLast = s.LastValue + 1, @SeqEnd = s.EndingValue, @SeqFormat = s.FormatString
        FROM Lots.IdentifierSequence s WITH (ROWLOCK, UPDLOCK, HOLDLOCK)
        WHERE s.Code = N'ControlledRun';
        IF @SeqLast IS NULL RAISERROR(N'Identifier sequence ''ControlledRun'' is not configured.', 16, 1);
        IF @SeqLast > @SeqEnd RAISERROR(N'Identifier sequence ''ControlledRun'' is exhausted.', 16, 1);
        UPDATE Lots.IdentifierSequence SET LastValue = @SeqLast, UpdatedAt = SYSUTCDATETIME() WHERE Code = N'ControlledRun';
        SET @SeqPrefix = CASE WHEN CHARINDEX(N'{', @SeqFormat) > 0 THEN LEFT(@SeqFormat, CHARINDEX(N'{', @SeqFormat) - 1) ELSE @SeqFormat END;
        SET @SeqPad = TRY_CAST(SUBSTRING(@SeqFormat,
                          CHARINDEX(N'D', @SeqFormat, CHARINDEX(N'{', @SeqFormat)) + 1,
                          CHARINDEX(N'}', @SeqFormat, CHARINDEX(N'{', @SeqFormat)) - CHARINDEX(N'D', @SeqFormat, CHARINDEX(N'{', @SeqFormat)) - 1) AS INT);
        SET @RunNumber = CASE WHEN @SeqPad IS NULL OR @SeqPad < 1 THEN @SeqPrefix + CAST(@SeqLast AS NVARCHAR(20))
                              ELSE @SeqPrefix + RIGHT(REPLICATE(N'0', @SeqPad) + CAST(@SeqLast AS NVARCHAR(20)), @SeqPad) END;

        INSERT INTO Quality.ControlledRun
            (RunNumber, ControlledRunStatusId, Reason, AnchorLotId, SelectionItemId, SelectionLocationId,
             SelectionFromAt, SelectionToAt, IncludeDescendants, AutoJoinEnabled, OpenedByUserId, OpenedAtTerminalId)
        VALUES
            (@RunNumber, 1, LTRIM(RTRIM(@Reason)), @AnchorLotId, @SelectionItemId, @SelectionLocationId,
             @FromUtc, @ToUtc, ISNULL(@IncludeDescendants, 0), ISNULL(@AutoJoinEnabled, 0), @AppUserId, @TerminalLocationId);
        SET @NewId = SCOPE_IDENTITY();

        EXEC Quality.ControlledRun_ApplyMembersInternal
            @ControlledRunId = @NewId, @MembersJson = @MembersJson, @JoinMethodCode = N'Selected',
            @AppUserId = @AppUserId, @TerminalLocationId = @TerminalLocationId;

        DECLARE @Lots INT = (SELECT COUNT(*) FROM Quality.ControlledRunMember WHERE ControlledRunId = @NewId AND LotId IS NOT NULL);
        DECLARE @Cons INT = (SELECT COUNT(*) FROM Quality.ControlledRunMember WHERE ControlledRunId = @NewId AND ContainerId IS NOT NULL);
        DECLARE @ActivityRaw NVARCHAR(MAX) = @RunNumber + N' ' + Audit.ufn_MidDot() + N' Opened: '
            + CAST(@Lots AS NVARCHAR(10)) + N' LOTs, ' + CAST(@Cons AS NVARCHAR(10)) + N' containers';
        DECLARE @Activity NVARCHAR(500) = Audit.ufn_TruncateActivity(@ActivityRaw);
        DECLARE @NewValue NVARCHAR(MAX) = (
            SELECT r.RunNumber, r.Reason, r.IncludeDescendants, r.AutoJoinEnabled, r.SelectionFromAt, r.SelectionToAt,
                   JSON_QUERY((SELECT l.Id, l.LotName AS Code, l.LotName AS Name FROM Lots.Lot l WHERE l.Id = r.AnchorLotId FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)) AS AnchorLot,
                   JSON_QUERY((SELECT i.Id, i.PartNumber AS Code, i.Description AS Name FROM Parts.Item i WHERE i.Id = r.SelectionItemId FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)) AS Item,
                   JSON_QUERY((SELECT lo.Id, lo.Code, lo.Name FROM Location.Location lo WHERE lo.Id = r.SelectionLocationId FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)) AS Location,
                   @Lots AS LotCount, @Cons AS ContainerCount
            FROM Quality.ControlledRun r WHERE r.Id = @NewId
            FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);
        EXEC Audit.Audit_LogOperation
            @AppUserId = @AppUserId, @TerminalLocationId = @TerminalLocationId, @LocationId = NULL,
            @LogEntityTypeCode = N'ControlledRun', @EntityId = @NewId, @LogEventTypeCode = N'ControlledRunOpened',
            @LogSeverityCode = N'Info', @Description = @Activity, @OldValue = NULL, @NewValue = @NewValue;

        COMMIT TRANSACTION;
```

Success message: `N'Super-lot ' + @RunNumber + N' opened with ' + CAST(@Lots + @Cons AS NVARCHAR(10)) + N' members.'`. In the CATCH set `@NewId = NULL` before the final SELECT.

`ControlledRun_Open` is deployed after `ControlledRun_ApplyMembersInternal` alphabetically (`A` < `O`), and procedures get deferred name resolution anyway, so no ordering marker is needed.

- [ ] **Step 5: Run and pass** — 40 + 20 = 60 assertions.

- [ ] **Step 6: Commit**

```powershell
git add -- sql/migrations/repeatable/R__Quality_ControlledRun_ApplyMembersInternal.sql sql/migrations/repeatable/R__Quality_ControlledRun_Open.sql sql/tests/0109_ControlledRun/040_open.sql
git commit -m "feat(quality): open a super-lot -- bundled header + members, tag on join"
```

---

### Task 5: Read procs

**Files:**
- Create: `R__Quality_ControlledRun_List.sql`, `_Get.sql`, `_GetByNumber.sql`, `_ListMembers.sql`, `_GetOpenByMember.sql` (all under `sql/migrations/repeatable/`)
- Test: `sql/tests/0109_ControlledRun/050_reads.sql`

**Interfaces:**
- Produces (all read procs: no status row, empty set = not found):
  - `ControlledRun_List(@StatusCode NVARCHAR(20) = N'Open', @Text NVARCHAR(100) = NULL)` — `@StatusCode` `NULL` or `N'All'` = every status. Columns: `Id, RunNumber, StatusCode, Reason, PartNumber, LocationName, OpenedAt (ET), ClosedAt (ET), MemberCount, ClearedCount, WindowOpen BIT`. Order: open runs oldest first, then the rest newest first. `@Text` matches `RunNumber`, `Reason` or `PartNumber` (`LIKE '%' + @Text + '%'`).
  - `ControlledRun_Get(@Id BIGINT)` and `ControlledRun_GetByNumber(@RunNumber NVARCHAR(15))` — one row: `Id, RunNumber, StatusCode, Reason, AnchorLotId, AnchorLotName, SelectionItemId, PartNumber, SelectionLocationId, LocationName, SelectionFromAt (ET), SelectionToAt (ET), IncludeDescendants, AutoJoinEnabled, AutoJoinEndedAt (ET), OpenedByInitials, OpenedAt (ET), ClosedByInitials, ClosedAt (ET), CloseRemarks, MemberCount, ClearedCount, PieceCount, CriteriaText`.
  - `ControlledRun_ListMembers(@Id BIGINT, @IncludeEnded BIT = 0)` — `MemberId, Kind, LotId, ContainerId, DisplayName, PartNumber, CurrentLocationName, PieceCount, CrtActive, JoinMethodName, AddedAt (ET), EndedAt (ET), EndReasonName`. Order `AddedAt`, `MemberId`.
  - `ControlledRun_GetOpenByMember(@LotId BIGINT = NULL, @ContainerId BIGINT = NULL)` — `Id, RunNumber` of the open run the unit is in. A tray LOT resolves through its container.

Definitions used by all of them — put this once in `ControlledRun_Get` and reuse the same expressions in `_List` and `_GetByNumber`:

```sql
    OUTER APPLY (
        SELECT COUNT(*) AS MemberCount,
               SUM(CASE WHEN x.CrtActive = 0 THEN 1 ELSE 0 END) AS ClearedCount,
               SUM(x.PieceCount) AS PieceCount
        FROM (
            SELECT CASE WHEN m.LotId IS NOT NULL THEN CAST(l.CrtActive AS INT)
                        ELSE ISNULL((SELECT MAX(CAST(tl.CrtActive AS INT)) FROM Lots.ContainerTray t
                                     JOIN Lots.Lot tl ON tl.Id = t.FinishedGoodLotId WHERE t.ContainerId = m.ContainerId), 0) END AS CrtActive,
                   CASE WHEN m.LotId IS NOT NULL THEN l.PieceCount
                        ELSE ISNULL((SELECT SUM(tl.PieceCount) FROM Lots.ContainerTray t
                                     JOIN Lots.Lot tl ON tl.Id = t.FinishedGoodLotId WHERE t.ContainerId = m.ContainerId), 0) END AS PieceCount
            FROM Quality.ControlledRunMember m
            LEFT JOIN Lots.Lot l ON l.Id = m.LotId
            WHERE m.ControlledRunId = r.Id
              AND (m.EndedAt IS NULL OR m.ControlledRunMemberEndReasonId = 2 /* RunClosed: keep the closed run's totals */)
        ) x
    ) tot
```

`WindowOpen` = `CONVERT(BIT, CASE WHEN r.ControlledRunStatusId = 1 AND r.AutoJoinEnabled = 1 THEN 1 ELSE 0 END)`.

`CriteriaText` is built in SQL (no sentence-building in Python):

```sql
    CAST(LTRIM(
        CASE WHEN i.PartNumber IS NOT NULL THEN i.PartNumber ELSE N'' END
      + CASE WHEN lo.Name IS NOT NULL THEN N' made on ' + lo.Name ELSE N'' END
      + CASE WHEN r.SelectionFromAt IS NOT NULL THEN N' since ' + FORMAT(CAST(r.SelectionFromAt AT TIME ZONE 'UTC' AT TIME ZONE 'Eastern Standard Time' AS DATETIME2(0)), 'ddd MM/dd HH:mm') ELSE N'' END
      + CASE WHEN r.IncludeDescendants = 1 AND al.LotName IS NOT NULL
             THEN CASE WHEN i.PartNumber IS NOT NULL THEN N', plus' ELSE N'' END + N' everything made from ' + al.LotName ELSE N'' END
      + CASE WHEN i.PartNumber IS NULL AND NOT (r.IncludeDescendants = 1 AND al.LotName IS NOT NULL) THEN N'Hand-picked' ELSE N'' END
    ) AS NVARCHAR(400)) AS CriteriaText
```

(`i` = `Parts.Item` on `SelectionItemId`, `lo` = `Location.Location` on `SelectionLocationId`, `al` = `Lots.Lot` on `AnchorLotId`.)

- [ ] **Step 1: Write the failing test** — `050_reads.sql`. Open one run through `ControlledRun_Open` with LOT A (Good), LOT B (Good) and a Complete container; then clear B's tag with `UPDATE Lots.Lot SET CrtActive = 0`. Capture each proc into a table variable with its exact column list. Assertions (14): `_List` default returns the run with `MemberCount = 3`, `ClearedCount = 2` (B, and the container whose Closed tray was never tagged); `_List @StatusCode = N'Closed'` returns 0 rows; `_List @Text = N'CR0000'` finds it and `@Text = N'zzz'` does not; `_Get` returns 1 row with `StatusCode = 'Open'` and `OpenedByInitials = 'SYS'`; `_Get` of an unknown id returns 0 rows; `_GetByNumber N'CR000001'` returns the same `Id`; `CriteriaText` for a part + line + anchor + descendants run contains the part number, `made on`, and `everything made from`; `CriteriaText` for a run with no criteria is `Hand-picked`; `_ListMembers` returns 3 rows, the container row has `Kind = 'Container'` and `JoinMethodName = 'Selected'`; `_ListMembers` `AddedAt` is Eastern (differs from the stored UTC by the current offset); `_GetOpenByMember @LotId = A` returns the run; `_GetOpenByMember` for the container's tray LOT id returns the run; `_GetOpenByMember` for an unrelated LOT returns 0 rows.

- [ ] **Step 2: Run and watch it fail.**

- [ ] **Step 3: Write the five procs.** Each is a single `SELECT` in a `SET NOCOUNT ON` proc, using the shared expressions above. `_GetOpenByMember`:

```sql
CREATE OR ALTER PROCEDURE Quality.ControlledRun_GetOpenByMember
    @LotId       BIGINT = NULL,
    @ContainerId BIGINT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    -- a finished-good tray LOT is represented by its container (D3)
    IF @ContainerId IS NULL AND @LotId IS NOT NULL
        SET @ContainerId = (SELECT TOP 1 ContainerId FROM Lots.ContainerTray WHERE FinishedGoodLotId = @LotId);

    SELECT TOP 1 r.Id, r.RunNumber
    FROM Quality.ControlledRunMember m
    INNER JOIN Quality.ControlledRun r ON r.Id = m.ControlledRunId
    WHERE m.EndedAt IS NULL
      AND ((@ContainerId IS NOT NULL AND m.ContainerId = @ContainerId)
        OR (@ContainerId IS NULL AND m.LotId = @LotId));
END;
GO
```

`_ListMembers` joins `Quality.ControlledRunJoinMethod`, `Quality.ControlledRunMemberEndReason`, `Lots.Lot`, `Lots.Container`, `Parts.Item` (on `COALESCE(c.ItemId, l.ItemId)`), `Location.Location` (on `COALESCE(c.CurrentLocationId, l.CurrentLocationId)`), filters `m.ControlledRunId = @Id AND (@IncludeEnded = 1 OR m.EndedAt IS NULL)`, and computes `CrtActive` / `PieceCount` with the same two sub-selects as the totals block.

- [ ] **Step 4: Run and pass** — 60 + 14 = 74 assertions.

- [ ] **Step 5: Commit**

```powershell
git add -- sql/migrations/repeatable/R__Quality_ControlledRun_List.sql sql/migrations/repeatable/R__Quality_ControlledRun_Get.sql sql/migrations/repeatable/R__Quality_ControlledRun_GetByNumber.sql sql/migrations/repeatable/R__Quality_ControlledRun_ListMembers.sql sql/migrations/repeatable/R__Quality_ControlledRun_GetOpenByMember.sql sql/tests/0109_ControlledRun/050_reads.sql
git commit -m "feat(quality): super-lot read procs"
```

---

### Task 6: Add and remove members

**Files:**
- Create: `sql/migrations/repeatable/R__Quality_ControlledRun_AddMembers.sql`, `R__Quality_ControlledRun_RemoveMember.sql`
- Test: `sql/tests/0109_ControlledRun/060_members.sql`

**Interfaces:**
- Consumes: `ControlledRun_ApplyMembersInternal`, `ufn_ControlledRunResolveMembers`.
- Produces: `ControlledRun_AddMembers(@Id BIGINT, @MembersJson NVARCHAR(MAX), @AppUserId BIGINT, @TerminalLocationId BIGINT = NULL)` → `Status, Message`; `ControlledRun_RemoveMember(@MemberId BIGINT, @Remarks NVARCHAR(500), @AppUserId BIGINT, @TerminalLocationId BIGINT = NULL)` → `Status, Message`.

- [ ] **Step 1: Write the failing test.** Assertions (14): add a Good LOT → Status 1, join method `Manual`, tag set; **add two tray LOT ids of the same container → exactly one container member (Review Focus 2)**; add a LOT already in this run → Status 0 `Already in CR…`; add a Scrap LOT → Status 0 and nothing added; add to a Closed run (set `ControlledRunStatusId = 2` directly) → Status 0 `Super-lot CR… is not open.`; add with empty JSON → Status 0 `Nothing to add.`; one `ControlledRunMemberAdded` audit row whose `Description` contains `+ ` and the LOT name; remove without remarks → Status 0 `A reason is required to remove a member.`; remove with remarks → Status 1, `EndedAt` set, end reason `Removed`, `EndRemarks` stored; **the removed LOT's `CrtActive` is still 1 (D6)** and the message contains `still CRT-tagged`; removing the same member again → Status 0 `Member is no longer in the super-lot.`; a removed LOT can be added back (new open membership); one `ControlledRunMemberRemoved` audit row whose `Description` contains `- ` and the remarks.

- [ ] **Step 2: Run and watch it fail.**

- [ ] **Step 3: Write `ControlledRun_AddMembers`** (SKELETON, `<EVT>` = `ControlledRunMemberAdded`, `<ID>` = `@Id`).

Validations: (1) `@Id IS NULL OR @AppUserId IS NULL` → `Required parameter missing (Id, AppUserId).`; (2) run not found → `Super-lot not found.`; (3) status not `Open` → `N'Super-lot ' + @RunNumber + N' is not open.'`; (4) resolved count = 0 → `Nothing to add.`; (5) `@Bad IS NOT NULL` (same `@Bad` query as Task 4) → `N'Cannot add: ' + @Bad`.

Mutation:

```sql
        DECLARE @Before INT = (SELECT COUNT(*) FROM Quality.ControlledRunMember WHERE ControlledRunId = @Id);
        DECLARE @Names NVARCHAR(MAX) = (SELECT STRING_AGG(N'+ ' + r.DisplayName, N', ') WITHIN GROUP (ORDER BY r.DisplayName)
                                        FROM Quality.ufn_ControlledRunResolveMembers(@MembersJson) r);
        BEGIN TRANSACTION;
        EXEC Quality.ControlledRun_ApplyMembersInternal
            @ControlledRunId = @Id, @MembersJson = @MembersJson, @JoinMethodCode = N'Manual',
            @AppUserId = @AppUserId, @TerminalLocationId = @TerminalLocationId;
        DECLARE @Added INT = (SELECT COUNT(*) FROM Quality.ControlledRunMember WHERE ControlledRunId = @Id) - @Before;
        DECLARE @ActivityRaw NVARCHAR(MAX) = @RunNumber + N' ' + Audit.ufn_MidDot() + N' Members ' + Audit.ufn_MidDot() + N' ' + @Names;
        DECLARE @Activity NVARCHAR(500) = Audit.ufn_TruncateActivity(@ActivityRaw);
        DECLARE @NewValue NVARCHAR(MAX) = (SELECT @Added AS Added, JSON_QUERY(@MembersJson) AS Members FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);
        EXEC Audit.Audit_LogOperation
            @AppUserId = @AppUserId, @TerminalLocationId = @TerminalLocationId, @LocationId = NULL,
            @LogEntityTypeCode = N'ControlledRun', @EntityId = @Id, @LogEventTypeCode = N'ControlledRunMemberAdded',
            @LogSeverityCode = N'Info', @Description = @Activity, @OldValue = NULL, @NewValue = @NewValue;
        COMMIT TRANSACTION;
```

`@Names` is computed BEFORE the transaction because after the insert the function reports those units as "already in". Success message: `CAST(@Added AS NVARCHAR(10)) + N' added to super-lot ' + @RunNumber + N'.'`.

- [ ] **Step 4: Write `ControlledRun_RemoveMember`** (SKELETON, `<EVT>` = `ControlledRunMemberRemoved`).

Load `@RunId, @RunNumber, @StatusId, @EndedAt, @DisplayName, @StillTagged` from the member row (display name and tag via the same expressions as `_ListMembers`). Validations: required (`MemberId`, `AppUserId`); member not found → `Member not found.`; `@EndedAt IS NOT NULL` → `Member is no longer in the super-lot.`; run not open → `N'Super-lot ' + @RunNumber + N' is not open.'`; blank remarks → `A reason is required to remove a member.`

Mutation: `UPDATE Quality.ControlledRunMember SET EndedAt = SYSUTCDATETIME(), EndedByUserId = @AppUserId, ControlledRunMemberEndReasonId = 1, EndRemarks = LTRIM(RTRIM(@Remarks)) WHERE Id = @MemberId AND EndedAt IS NULL;` then audit `@RunNumber · Members · - <DisplayName>: <Remarks>`. **No write to `Lots.Lot`.** Success message: `@DisplayName + N' removed from super-lot ' + @RunNumber + N'.'` + `CASE WHEN @StillTagged = 1 THEN N' It is still CRT-tagged; clear it on LOT Detail if it should be released.' ELSE N'' END`.

- [ ] **Step 5: Run and pass** — 74 + 14 = 88 assertions.

- [ ] **Step 6: Commit**

```powershell
git add -- sql/migrations/repeatable/R__Quality_ControlledRun_AddMembers.sql sql/migrations/repeatable/R__Quality_ControlledRun_RemoveMember.sql sql/tests/0109_ControlledRun/060_members.sql
git commit -m "feat(quality): add and remove super-lot members"
```

---

### Task 7: The mint resolver's fourth arm

This is the one change in the plan that runs on every mint in the plant. Treat the regression check as the main deliverable.

**Files:**
- Modify: `sql/migrations/repeatable/R__Lots_ufn_zz_CrtForMint.sql`
- Test: `sql/tests/0109_ControlledRun/070_resolver_arm.sql`

**Interfaces:**
- Produces: `Lots.ufn_CrtForMint(@ItemId, @TerminalLocationId, @InputLotIdsCsv)` v1.1 — same signature, same single-row `CrtActive BIT` result; additionally returns 1 when an Open run with `AutoJoinEnabled = 1` has `SelectionItemId = @ItemId` and either no `SelectionLocationId` or one that is `@TerminalLocationId` or an ancestor of it.

- [ ] **Step 1: Write the failing test.** Fixture: `Parts.Item.CrtEnabled = 0` for `@Item` and `@Item2`; no `CrtEnabled` attribute on `@Term` / `@TermOther`. Insert runs directly (faster than `_Open`):

```sql
INSERT INTO Quality.ControlledRun (RunNumber, ControlledRunStatusId, Reason, OpenedByUserId, SelectionItemId, SelectionLocationId, AutoJoinEnabled)
VALUES (N'CR000701', 1, N'arm test', @App, @Item, @Line, 1);
```

Assertions (10): before the run exists, `ufn_CrtForMint(@Item, @Term, NULL)` = 0; with the run: matching part at a terminal under the line = 1; matching part at `@TermOther` = 0; `@Item2` at `@Term` = 0; matching part with `@TerminalLocationId = NULL` = 0 (a run that names a line needs a terminal to match); after `UPDATE … SET SelectionLocationId = NULL`: matching part at `@TermOther` = 1 and with a NULL terminal = 1; after `AutoJoinEnabled = 0`: = 0; after `AutoJoinEnabled = 1, ControlledRunStatusId = 2`: = 0; the function still returns exactly one row for a nonexistent item (`COUNT(*) = 1`).

- [ ] **Step 2: Run and watch it fail** (4 of the 10 fail: the arm does not exist).

- [ ] **Step 3: Edit the function.** Change the header to Version 1.1 with a change-log line, add `Quality.ControlledRun` to Dependencies, and replace the body with:

```sql
RETURN
(
    WITH Anc AS (   -- @TerminalLocationId and every location above it (<= ~6 rows)
        SELECT l.Id, l.ParentLocationId FROM Location.Location l WHERE l.Id = @TerminalLocationId
        UNION ALL
        SELECT p.Id, p.ParentLocationId FROM Location.Location p INNER JOIN Anc a ON p.Id = a.ParentLocationId
    )
    SELECT CONVERT(BIT, CASE WHEN
        -- (1) Part flag.
        EXISTS (SELECT 1 FROM Parts.Item i
                 WHERE i.Id = @ItemId AND i.CrtEnabled = 1)
        -- (2) Terminal switch (migration 0058; absent row reads as '0').
     OR EXISTS (SELECT 1
                  FROM Location.LocationAttribute la
                  JOIN Location.LocationAttributeDefinition ad
                    ON ad.Id = la.LocationAttributeDefinitionId
                 WHERE la.LocationId = @TerminalLocationId
                   AND ad.AttributeName = N'CrtEnabled'
                   AND ad.DeprecatedAt IS NULL
                   AND la.AttributeValue = N'1')
        -- (3) D2 propagation: any consumed input LOT already CRT-active.
     OR EXISTS (SELECT 1
                  FROM STRING_SPLIT(ISNULL(@InputLotIdsCsv, N''), N',') s
                  JOIN Lots.Lot l ON l.Id = TRY_CAST(s.value AS BIGINT)
                 WHERE l.CrtActive = 1)
        -- (4) Super-lot rolling window (Quality.ControlledRun, migration 0109):
        --     an OPEN run with "keep adding new production" on covers this part,
        --     and either names no line or names one at/above the minting terminal.
        --     Seeks IX_ControlledRun_AutoJoin, which is normally empty.
     OR EXISTS (SELECT 1
                  FROM Quality.ControlledRun r
                 WHERE r.ControlledRunStatusId = 1
                   AND r.AutoJoinEnabled = 1
                   AND r.SelectionItemId = @ItemId
                   AND (r.SelectionLocationId IS NULL
                        OR r.SelectionLocationId IN (SELECT a.Id FROM Anc a)))
        THEN 1 ELSE 0 END) AS CrtActive
);
GO
```

- [ ] **Step 4: Run and pass** — 88 + 10 = 98 assertions.

- [ ] **Step 5: Regression — the existing CRT suites must be unchanged**

```powershell
.\sql\tests\Run-Tests.ps1 -DatabaseName MPP_MES_Test_CtrlRun -Filter "Crt"
```

Expected: 0 failures and an assertion total equal to **the Task 0 baseline plus the 0109 files that match the filter** (the filter `Crt` does not match `0109_ControlledRun`, so the total must equal the baseline exactly). If it differs, stop: a file threw.

- [ ] **Step 6: Confirm the plan stays a seek**

In SSMS against `MPP_MES_Test_CtrlRun`, with `SET STATISTICS IO ON`, run `SELECT CrtActive FROM Lots.ufn_CrtForMint(1, NULL, NULL);`. Expected: `ControlledRun` shows a handful of logical reads at most (index seek on `IX_ControlledRun_AutoJoin`), not a scan of a large table. Record the reads in the commit message.

- [ ] **Step 7: Commit**

```powershell
git add -- sql/migrations/repeatable/R__Lots_ufn_zz_CrtForMint.sql sql/tests/0109_ControlledRun/070_resolver_arm.sql
git commit -m "feat(crt): mint resolver arm 4 -- an open super-lot window tags new production"
```

---

### Task 8: Sync and the window switch

**Files:**
- Create: `sql/migrations/repeatable/R__Quality_ControlledRun_SyncInternal.sql`, `R__Quality_ControlledRun_SyncAutoJoin.sql`, `R__Quality_ControlledRun_SetAutoJoin.sql`
- Test: `sql/tests/0109_ControlledRun/080_sync.sql`

**Interfaces:**
- Consumes: `ControlledRun_ApplyMembersInternal`.
- Produces:
  - `ControlledRun_SyncInternal(@ControlledRunId BIGINT, @AppUserId BIGINT)` — **silent**. Idempotent. Does its own `BEGIN TRANSACTION … COMMIT` (legal when nested), never `ROLLBACK`s.
  - `ControlledRun_SyncAutoJoin(@Id BIGINT = NULL, @AppUserId BIGINT)` → `Status, Message`. `@Id NULL` = every open run.
  - `ControlledRun_SetAutoJoin(@Id BIGINT, @Enabled BIT, @AppUserId BIGINT, @TerminalLocationId BIGINT = NULL)` → `Status, Message`.

- [ ] **Step 1: Write the failing test.** Open a run through `_Open` with `@SelectionItemId = @Item`, `@SelectionLocationId = @Line`, `@AutoJoinEnabled = 1`, `@IncludeDescendants = 1`, one member `TEST-CR-A`. Then insert, with `CreatedAt = SYSUTCDATETIME()`: `TEST-CR-NEW` (@Item, `@Term`, CrtActive 1), `TEST-CR-NEWCLEAN` (@Item, `@Term`, CrtActive 0), `TEST-CR-NEWOTHER` (@Item, `@TermOther`, CrtActive 1), `TEST-CR-OLD` (@Item, `@Term`, CrtActive 1, `CreatedAt` 1 day ago), `TEST-CR-KID` (@Item2, CrtActive 1, closure descendant of A), `TEST-CR-KIDCLEAN` (@Item2, CrtActive 0, descendant of A).

Assertions (14): `_SyncAutoJoin @Id` → Status 1, message `2 added.`; `NEW` is a member with join method `AutoJoined`; `KID` is a member with `Descendant`; `NEWCLEAN`, `NEWOTHER`, `OLD`, `KIDCLEAN` are not members; second sync → `0 added.` (idempotent) and member count unchanged; `_SyncAutoJoin @Id = NULL` → Status 1; `_SetAutoJoin @Enabled = 0` → Status 1, `AutoJoinEnabled = 0`, `AutoJoinEndedAt` not null; one `ControlledRunWindowChanged` audit row containing `Ended`; a CRT LOT minted after the end (insert `TEST-CR-LATE`, CrtActive 1, `CreatedAt` = now + 1 second via `DATEADD`) is NOT picked up by a later sync; `_SetAutoJoin @Enabled = 0` again → Status 0 `Automatic adding is already off.`; `_SetAutoJoin @Enabled = 1` → Status 1 and `AutoJoinEndedAt` cleared; `_SetAutoJoin @Enabled = 1` on a run with no `SelectionItemId` → Status 0 `Keep adding new production needs a part.`; `_SetAutoJoin` on a closed run → Status 0.

- [ ] **Step 2: Run and watch it fail.**

- [ ] **Step 3: Write `ControlledRun_SyncInternal`**

```sql
CREATE OR ALTER PROCEDURE Quality.ControlledRun_SyncInternal
    @ControlledRunId BIGINT,
    @AppUserId       BIGINT
AS
BEGIN
    -- SILENT INTERNAL HELPER (see ControlledRun_ApplyMembersInternal). Records the
    -- membership of material the mint resolver already tagged (D7) and of CRT
    -- descendants of current members (D8). The BLOCK never waits on this: the
    -- tag was set in the mint transaction.
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @ItemId BIGINT, @LocationId BIGINT, @OpenedAt DATETIME2(3), @EndedAt DATETIME2(3),
            @AutoJoin BIT, @Desc BIT, @StatusId BIGINT;
    SELECT @ItemId = SelectionItemId, @LocationId = SelectionLocationId, @OpenedAt = OpenedAt,
           @EndedAt = AutoJoinEndedAt, @AutoJoin = AutoJoinEnabled, @Desc = IncludeDescendants,
           @StatusId = ControlledRunStatusId
    FROM Quality.ControlledRun WHERE Id = @ControlledRunId;
    IF @StatusId IS NULL OR @StatusId <> 1 RETURN;

    DECLARE @Json NVARCHAR(MAX);

    BEGIN TRANSACTION;

    -- (a) new production: only while the window is, or was, open
    IF @ItemId IS NOT NULL AND (@AutoJoin = 1 OR @EndedAt IS NOT NULL)
    BEGIN
        ;WITH Descendants AS (
            SELECT @LocationId AS Id WHERE @LocationId IS NOT NULL
            UNION ALL
            SELECT c.Id FROM Location.Location c INNER JOIN Descendants d ON c.ParentLocationId = d.Id
        )
        SELECT @Json = (
            SELECT l.Id AS lotId
            FROM Lots.Lot l
            WHERE l.ItemId = @ItemId
              AND l.CrtActive = 1
              AND l.CreatedAt >= @OpenedAt
              AND (@EndedAt IS NULL OR l.CreatedAt < @EndedAt)
              AND (@LocationId IS NULL OR l.CreatedAtTerminalId IN (SELECT Id FROM Descendants))
            FOR JSON PATH)
        OPTION (MAXRECURSION 8);

        IF @Json IS NOT NULL
            EXEC Quality.ControlledRun_ApplyMembersInternal
                @ControlledRunId = @ControlledRunId, @MembersJson = @Json, @JoinMethodCode = N'AutoJoined',
                @AppUserId = @AppUserId, @TerminalLocationId = NULL;
    END

    -- (b) CRT-active descendants of current LOT members
    IF @Desc = 1
    BEGIN
        SET @Json = (
            SELECT DISTINCT gc.DescendantLotId AS lotId
            FROM Quality.ControlledRunMember m
            INNER JOIN Lots.LotGenealogyClosure gc ON gc.AncestorLotId = m.LotId AND gc.Depth > 0
            INNER JOIN Lots.Lot d ON d.Id = gc.DescendantLotId
            WHERE m.ControlledRunId = @ControlledRunId AND m.EndedAt IS NULL AND m.LotId IS NOT NULL
              AND d.CrtActive = 1
            FOR JSON PATH);

        IF @Json IS NOT NULL
            EXEC Quality.ControlledRun_ApplyMembersInternal
                @ControlledRunId = @ControlledRunId, @MembersJson = @Json, @JoinMethodCode = N'Descendant',
                @AppUserId = @AppUserId, @TerminalLocationId = NULL;
    END

    COMMIT TRANSACTION;
END;
GO
```

`ApplyMembersInternal` skips anything ineligible (already in a run, scrapped, closed non-tray), which is what makes this idempotent.

- [ ] **Step 4: Write `ControlledRun_SyncAutoJoin`** (SKELETON, `<EVT>` = `ControlledRunMemberAdded`, no explicit transaction of its own — the helper owns it). Validations: `@AppUserId IS NULL` → `Required parameter missing (AppUserId).`; `@Id IS NOT NULL` and run not found → `Super-lot not found.` Body:

```sql
        DECLARE @Before INT = (SELECT COUNT(*) FROM Quality.ControlledRunMember);
        DECLARE @RunId BIGINT;
        DECLARE run_cur CURSOR LOCAL FAST_FORWARD FOR
            SELECT Id FROM Quality.ControlledRun
            WHERE ControlledRunStatusId = 1 AND (@Id IS NULL OR Id = @Id) ORDER BY Id;
        OPEN run_cur;
        FETCH NEXT FROM run_cur INTO @RunId;
        WHILE @@FETCH_STATUS = 0
        BEGIN
            EXEC Quality.ControlledRun_SyncInternal @ControlledRunId = @RunId, @AppUserId = @AppUserId;
            FETCH NEXT FROM run_cur INTO @RunId;
        END
        CLOSE run_cur; DEALLOCATE run_cur;
        DECLARE @Added INT = (SELECT COUNT(*) FROM Quality.ControlledRunMember) - @Before;
        SET @Status = 1;
        SET @Message = CAST(@Added AS NVARCHAR(10)) + N' added.';
        SELECT @Status AS Status, @Message AS Message;
```

No audit row from the wrapper: each tagged LOT already has its own, and an "auto-sync found nothing" row every minute would bury the log.

- [ ] **Step 5: Write `ControlledRun_SetAutoJoin`** (SKELETON, `<EVT>` = `ControlledRunWindowChanged`).

Validations: required (`Id`, `Enabled`, `AppUserId`); run not found; run not open → `N'Super-lot ' + @RunNumber + N' is not open.'`; `@Enabled = 1 AND @ItemId IS NULL` → `Keep adding new production needs a part.`; `@Enabled = @Current` → `N'Automatic adding is already ' + CASE WHEN @Enabled = 1 THEN N'on.' ELSE N'off.' END`.

Then, **before** `BEGIN TRANSACTION` and only when `@Enabled = 0`: `EXEC Quality.ControlledRun_SyncInternal @ControlledRunId = @Id, @AppUserId = @AppUserId;` — a final sync so nothing minted in the last minute is left out. (It is a self-contained, idempotent mutation; if the switch below then fails, the sync having happened is still correct.)

Mutation:

```sql
        BEGIN TRANSACTION;
        UPDATE Quality.ControlledRun
        SET AutoJoinEnabled       = @Enabled,
            AutoJoinEndedAt       = CASE WHEN @Enabled = 0 THEN SYSUTCDATETIME() ELSE NULL END,
            AutoJoinEndedByUserId = CASE WHEN @Enabled = 0 THEN @AppUserId ELSE NULL END
        WHERE Id = @Id;
```

Audit: `@RunNumber · Window · Ended` or `· Resumed`; `OldValue` / `NewValue` `{"AutoJoinEnabled": …}`. Success: `N'Super-lot ' + @RunNumber + CASE WHEN @Enabled = 1 THEN N' is adding new production again.' ELSE N' has stopped adding new production.' END`.

- [ ] **Step 6: Run and pass** — 98 + 14 = 112 assertions.

- [ ] **Step 7: Commit**

```powershell
git add -- sql/migrations/repeatable/R__Quality_ControlledRun_SyncInternal.sql sql/migrations/repeatable/R__Quality_ControlledRun_SyncAutoJoin.sql sql/migrations/repeatable/R__Quality_ControlledRun_SetAutoJoin.sql sql/tests/0109_ControlledRun/080_sync.sql
git commit -m "feat(quality): super-lot rolling window -- sync membership, end and resume"
```

---

### Task 9: Close and cancel

**Files:**
- Create: `sql/migrations/repeatable/R__Quality_ControlledRun_Close.sql`, `R__Quality_ControlledRun_Cancel.sql`
- Test: `sql/tests/0109_ControlledRun/090_close.sql`

**Interfaces:**
- Produces: `ControlledRun_Close(@Id BIGINT, @Remarks NVARCHAR(500) = NULL, @AppUserId BIGINT, @TerminalLocationId BIGINT = NULL)` → `Status, Message`; `ControlledRun_Cancel(@Id BIGINT, @Remarks NVARCHAR(500), @AppUserId BIGINT, @TerminalLocationId BIGINT = NULL)` → `Status, Message`.

- [ ] **Step 1: Write the failing test.** Assertions (15): close with the window on → Status 0 `End the window before closing.`; after ending the window, close with 2 of 3 members tagged → Status 0, message `2 of 3 members are still CRT-tagged.`; clear both via `Lots.Lot_ClearCrt` (the real proc, captured `INSERT INTO @c EXEC …`) → close → Status 1; status `Closed`, `ClosedAt` / `ClosedByUserId` set, `CloseRemarks` stored; every member `EndedAt` set with reason `RunClosed`; one `ControlledRunClosed` audit row; **a LOT from the closed run can be opened into a new run** (D4 frees it); close again → Status 0 `Super-lot CR… is not open.`; `_Get` on the closed run still reports `MemberCount = 3` (Task 5's totals keep `RunClosed` members); close runs a final sync — a CRT LOT minted in the window but never synced (insert it, then end the window by direct `UPDATE` of `AutoJoinEnabled = 0, AutoJoinEndedAt = SYSUTCDATETIME()`) becomes a member and the close is refused with `1 of N` outstanding; cancel without remarks → Status 0 `A reason is required to cancel a super-lot.`; cancel → Status 1, status `Cancelled`, members ended `RunCancelled`; **cancelled members keep `CrtActive = 1`** and the message contains `still CRT-tagged`; one `ControlledRunCancelled` audit row; cancel of a closed run → Status 0.

- [ ] **Step 2: Run and watch it fail.**

- [ ] **Step 3: Write `ControlledRun_Close`** (SKELETON, `<EVT>` = `ControlledRunClosed`).

Order matters and is the one place this plan runs a mutation before the validations finish — say so in the header:

1. Validations: required (`Id`, `AppUserId`); not found; not open; `@AutoJoin = 1` → `End the window before closing.`
2. `EXEC Quality.ControlledRun_SyncInternal @ControlledRunId = @Id, @AppUserId = @AppUserId;` (idempotent, self-contained).
3. Count: `@Total` = open members; `@Outstanding` = open members whose `CrtActive` (same expression as `_ListMembers`) is 1. Validation: `@Outstanding > 0` → `CAST(@Outstanding AS NVARCHAR(10)) + N' of ' + CAST(@Total AS NVARCHAR(10)) + N' members are still CRT-tagged.'`
4. Mutation:

```sql
        BEGIN TRANSACTION;
        UPDATE Quality.ControlledRun
        SET ControlledRunStatusId = 2, ClosedByUserId = @AppUserId, ClosedAt = SYSUTCDATETIME(),
            CloseRemarks = NULLIF(LTRIM(RTRIM(@Remarks)), N'')
        WHERE Id = @Id AND ControlledRunStatusId = 1;
        IF @@ROWCOUNT = 0 RAISERROR(N'Super-lot was closed by someone else.', 16, 1);

        UPDATE Quality.ControlledRunMember
        SET EndedAt = SYSUTCDATETIME(), EndedByUserId = @AppUserId, ControlledRunMemberEndReasonId = 2
        WHERE ControlledRunId = @Id AND EndedAt IS NULL;
```

Audit `@RunNumber · Closed` with `NewValue` `{MemberCount, CloseRemarks}`. Success: `N'Super-lot ' + @RunNumber + N' closed.'`

- [ ] **Step 4: Write `ControlledRun_Cancel`** (SKELETON, `<EVT>` = `ControlledRunCancelled`). Validations: required; not found; not open; blank remarks → `A reason is required to cancel a super-lot.` Mutation: status 3, `ClosedByUserId`, `ClosedAt`, `CloseRemarks = @Remarks`, `AutoJoinEnabled = 0`; members ended with reason 3. **No write to `Lots.Lot`.** Compute `@StillTagged` (count of members whose tag is set) before the transaction; success message: `N'Super-lot ' + @RunNumber + N' cancelled.'` + `CASE WHEN @StillTagged > 0 THEN N' ' + CAST(@StillTagged AS NVARCHAR(10)) + N' members are still CRT-tagged and must be cleared individually.' ELSE N'' END`.

Setting `AutoJoinEnabled = 0` on cancel is required: otherwise the `CK_ControlledRun_AutoJoinNeedsItem` row keeps satisfying the resolver's filter only by status, and a later re-open of the status column by hand would silently resume tagging.

- [ ] **Step 5: Run and pass** — 112 + 15 = 127 assertions.

- [ ] **Step 6: Commit**

```powershell
git add -- sql/migrations/repeatable/R__Quality_ControlledRun_Close.sql sql/migrations/repeatable/R__Quality_ControlledRun_Cancel.sql sql/tests/0109_ControlledRun/090_close.sql
git commit -m "feat(quality): close and cancel a super-lot"
```

---

### Task 10: The label

**Files:**
- Create: `sql/migrations/repeatable/R__Quality_ControlledRunLabel_Print.sql`
- Test: `sql/tests/0109_ControlledRun/100_label.sql`

**Interfaces:**
- Produces: `Quality.ControlledRunLabel_Print(@Id BIGINT, @AppUserId BIGINT, @TerminalLocationId BIGINT = NULL, @PrinterName NVARCHAR(100) = NULL)` → `Status, Message, NewId, ZplContent` (same four-column shape as `Lots.LotLabel_Print`). `Copies` is fixed at 4 inside the proc.

- [ ] **Step 1: Write the failing test.** Assertions (12): print for an open run → Status 1, `NewId` not null; one `ControlledRunLabel` row with `Copies = 4`; `ZplContent` contains `^PQ4`; contains the run number twice (text and barcode); contains the part number; contains `Opened ` and `by SYS`; **no unsubstituted token** (`ZplContent NOT LIKE N'%{%}%'`); a run with no part prints with no `{PartNumber}` left behind; **Review Focus 1:** a run whose `Reason` is `N'bore ^XZ~JA crack ' + NCHAR(8212) + N' line 2'` prints with no `^XZ` other than the final one (`LEN(Zpl) - LEN(REPLACE(Zpl, N'^XZ', N'')) = 3`), no `~`, and no character above 126; a reason of 500 characters is cut to 110 in the label; print for an unknown run → Status 0; with the template deprecated (`UPDATE Lots.LabelTemplate SET DeprecatedAt = SYSUTCDATETIME()` for the type, restored afterwards) → Status 0 `No active super-lot label template.`

- [ ] **Step 2: Run and watch it fail.**

- [ ] **Step 3: Write the proc** (SKELETON adapted: every exit `SELECT @Status AS Status, @Message AS Message, @NewId AS NewId, @Zpl AS ZplContent;`, `<EVT>` = `ControlledRunLabelPrinted`).

Validations: required (`Id`, `AppUserId`); run not found → `Super-lot not found.`; template missing → `No active super-lot label template.` Printing is allowed for a closed run (a reprint for the file is harmless).

Render:

```sql
        DECLARE @Copies INT = 4;   -- D11: four per request
        DECLARE @RunNumber NVARCHAR(15), @Reason NVARCHAR(500), @Part NVARCHAR(100), @OpenedAt NVARCHAR(16), @OpenedBy NVARCHAR(20);
        SELECT @RunNumber = r.RunNumber, @Reason = r.Reason, @Part = ISNULL(i.PartNumber, N''),
               @OpenedAt = CONVERT(NVARCHAR(16), CAST(r.OpenedAt AT TIME ZONE 'UTC' AT TIME ZONE 'Eastern Standard Time' AS DATETIME2(0)), 120),
               @OpenedBy = ISNULL(u.Initials, N'')
        FROM Quality.ControlledRun r
        LEFT JOIN Parts.Item i ON i.Id = r.SelectionItemId
        LEFT JOIN Location.AppUser u ON u.Id = r.OpenedByUserId
        WHERE r.Id = @Id;

        -- ZPL-safe free text: '^' and '~' are command prefixes and would end the label
        -- or fire a printer command; anything outside printable ASCII prints as
        -- mojibake. Replace, never reject -- a label that will not print stops work.
        DECLARE @Safe NVARCHAR(500) = REPLACE(REPLACE(LEFT(@Reason, 110), N'^', N' '), N'~', N' ');
        DECLARE @p INT = PATINDEX(N'%[^ -}]%' COLLATE Latin1_General_BIN2, @Safe);
        WHILE @p > 0
        BEGIN
            SET @Safe = STUFF(@Safe, @p, 1, N'?');
            SET @p = PATINDEX(N'%[^ -}]%' COLLATE Latin1_General_BIN2, @Safe);
        END
        SET @Safe = REPLACE(REPLACE(@Safe, N'{', N'('), N'}', N')');   -- cannot collide with a token
        SET @Part = REPLACE(REPLACE(@Part, N'^', N' '), N'~', N' ');

        -- {Reason} is substituted LAST so nothing typed into it can be read as a token.
        SET @Zpl = REPLACE(@Zpl, N'{RunNumber}',  @RunNumber);
        SET @Zpl = REPLACE(@Zpl, N'{PartNumber}', @Part);
        SET @Zpl = REPLACE(@Zpl, N'{OpenedAt}',   @OpenedAt);
        SET @Zpl = REPLACE(@Zpl, N'{OpenedBy}',   @OpenedBy);
        SET @Zpl = REPLACE(@Zpl, N'{Copies}',     CAST(@Copies AS NVARCHAR(5)));
        SET @Zpl = REPLACE(@Zpl, N'{Reason}',     @Safe);
```

`[^ -}]` matches anything outside space..`}` under a binary collation; `~` (126) was already replaced above.

Mutation: insert the `ControlledRunLabel` row (`Copies`, `ZplContent`, `PrinterName`, user, terminal), `SET @NewId = SCOPE_IDENTITY()`, audit `@RunNumber · Label · Printed (4)` with entity `ControlledRun`, `@EntityId = @Id`. Success message `4 super-lot labels sent.`

- [ ] **Step 4: Run and pass** — 127 + 12 = 139 assertions.

- [ ] **Step 5: Commit**

```powershell
git add -- sql/migrations/repeatable/R__Quality_ControlledRunLabel_Print.sql sql/tests/0109_ControlledRun/100_label.sql
git commit -m "feat(quality): super-lot label -- four copies, ZPL-safe reason"
```

---

### Task 11: Named queries and the script module

**Files:**
- Create: 14 folders under `ignition/projects/Core/ignition/named-query/quality/`, each with `query.sql` + `resource.json`
- Create: `ignition/projects/Core/ignition/script-python/BlueRidge/Quality/ControlledRun/code.py` + `resource.json`

**Interfaces:**
- Produces `BlueRidge.Quality.ControlledRun`:
  - `listRuns(statusCode, text, _refreshToken=None)` → `list[dict]`
  - `getRun(runId, _refreshToken=None)` → `dict | None`; `getRunOrEmpty(runId, _refreshToken=None)` → shaped dict, never `None`
  - `findByScan(text)` → `{"runId": int|None, "message": str}`
  - `listMembers(runId, _refreshToken=None)` → `list[dict]`
  - `preview(criteria)` → `list[dict]`
  - `open(criteria, memberRows, appUserId, terminalLocationId)` → `{Status, Message, NewId}`
  - `addByScan(runId, text, appUserId, terminalLocationId)` → `{Status, Message}`
  - `removeMember(memberId, remarks, appUserId, terminalLocationId)`; `setAutoJoin(runId, enabled, appUserId, terminalLocationId)`; `close(runId, remarks, appUserId, terminalLocationId)`; `cancel(runId, remarks, appUserId, terminalLocationId)` → `{Status, Message}`
  - `sync(runId, appUserId)` → `{Status, Message}`; `syncTick()` (gateway timer entry, never throws)
  - `printLabels(runId, appUserId, terminalLocationId)` → `{Status, Message, NewId}`

- [ ] **Step 1: Write the named queries.** For each row, `query.sql` is `EXEC Quality.<Proc>` with one `@Param = :param` line per parameter, and `resource.json` is a copy of `named-query/lots/Lot_ClearCrt/resource.json` with the `parameters` array replaced, `"type": "Query"`, `"lastModification": {"actor": "claude", "timestamp": "2026-10-12T12:00:00Z"}`.

| Folder | Parameters (identifier : sqlType) |
|---|---|
| `ControlledRun_List` | `statusCode`:7, `text`:7 |
| `ControlledRun_Get` | `id`:3 |
| `ControlledRun_GetByNumber` | `runNumber`:7 |
| `ControlledRun_ListMembers` | `id`:3, `includeEnded`:6 |
| `ControlledRun_GetOpenByMember` | `lotId`:3, `containerId`:3 |
| `ControlledRun_PreviewSelection` | `anchorLotId`:3, `itemId`:3, `locationId`:3, `fromAtEastern`:8, `toAtEastern`:8, `includeDescendants`:6 |
| `ControlledRun_Open` | `reason`:7, `anchorLotId`:3, `selectionItemId`:3, `selectionLocationId`:3, `selectionFromAtEastern`:8, `selectionToAtEastern`:8, `includeDescendants`:6, `autoJoinEnabled`:6, `membersJson`:7, `appUserId`:3, `terminalLocationId`:3 |
| `ControlledRun_AddMembers` | `id`:3, `membersJson`:7, `appUserId`:3, `terminalLocationId`:3 |
| `ControlledRun_RemoveMember` | `memberId`:3, `remarks`:7, `appUserId`:3, `terminalLocationId`:3 |
| `ControlledRun_SyncAutoJoin` | `id`:3, `appUserId`:3 |
| `ControlledRun_SetAutoJoin` | `id`:3, `enabled`:6, `appUserId`:3, `terminalLocationId`:3 |
| `ControlledRun_Close` | `id`:3, `remarks`:7, `appUserId`:3, `terminalLocationId`:3 |
| `ControlledRun_Cancel` | `id`:3, `remarks`:7, `appUserId`:3, `terminalLocationId`:3 |
| `ControlledRunLabel_Print` | `id`:3, `appUserId`:3, `terminalLocationId`:3, `printerName`:7 |

Before writing them, open one existing NQ that takes a BIT and one that takes a DATETIME (search `named-query` for `"sqlType": 6` and `"sqlType": 8`) and use the sqlType those use if it differs from 6 / 8 here.

Example, `ControlledRun_AddMembers/query.sql`:

```sql
EXEC Quality.ControlledRun_AddMembers
    @Id                 = :id,
    @MembersJson        = :membersJson,
    @AppUserId          = :appUserId,
    @TerminalLocationId = :terminalLocationId
```

- [ ] **Step 2: Write the script module**

`code.py` (tabs for indentation, matching the neighbouring modules):

```python
"""BlueRidge.Quality.ControlledRun - super-lots (Quality.ControlledRun).

   A super-lot is a stored list of LOTs and containers placed on a Controlled
   Run Tag for one reason. THIN WRAPPERS ONLY: eligibility, folding a tray LOT
   to its container, the rolling window, close rules and the label render all
   live in the Quality.ControlledRun_* procs.

   Elevation (FDS-04-007) is the calling view's concern; every mutation takes
   the already-resolved appUserId as attribution.

   Spec: docs/superpowers/specs/2026-10-12-controlled-run-super-lot-design.md"""

_EMPTY_RUN = {
	"Id": None, "RunNumber": "", "StatusCode": "", "Reason": "",
	"AnchorLotId": None, "AnchorLotName": "", "SelectionItemId": None, "PartNumber": "",
	"SelectionLocationId": None, "LocationName": "", "SelectionFromAt": None, "SelectionToAt": None,
	"IncludeDescendants": False, "AutoJoinEnabled": False, "AutoJoinEndedAt": None,
	"OpenedByInitials": "", "OpenedAt": None, "ClosedByInitials": "", "ClosedAt": None,
	"CloseRemarks": "", "MemberCount": 0, "ClearedCount": 0, "PieceCount": 0, "CriteriaText": "",
}


def _u(value):
	return BlueRidge.Common.Util.extractQualifiedValues(value)


def listRuns(statusCode, text, _refreshToken=None):
	"""Runs for the left-hand list. statusCode 'Open' | 'Closed' | 'Cancelled' | 'All'."""
	return BlueRidge.Common.Db.execList(
		"quality/ControlledRun_List",
		{"statusCode": _u(statusCode) or "Open", "text": (_u(text) or None)}) or []


def getRun(runId, _refreshToken=None):
	runId = _u(runId)
	if not runId:
		return None
	return BlueRidge.Common.Db.execOne("quality/ControlledRun_Get", {"id": runId})


def getRunOrEmpty(runId, _refreshToken=None):
	"""Binding-only twin of getRun: always the full shape, never None."""
	row = getRun(runId)
	if not row:
		return dict(_EMPTY_RUN)
	out = dict(_EMPTY_RUN)
	out.update(row)
	return out


def listMembers(runId, _refreshToken=None):
	runId = _u(runId)
	if not runId:
		return []
	return BlueRidge.Common.Db.execList(
		"quality/ControlledRun_ListMembers", {"id": runId, "includeEnded": 0}) or []


def _resolveScan(text):
	"""A scan is a super-lot label, an LTT, or a container id. Returns
	   {"kind": 'run'|'lot'|'container'|None, "id": int|None}. Resolve BY TYPE,
	   never int() first: an LTT and a container id can both look numeric."""
	t = (_u(text) or "").strip()
	if not t:
		return {"kind": None, "id": None}
	run = BlueRidge.Common.Db.execOne("quality/ControlledRun_GetByNumber", {"runNumber": t})
	if run:
		return {"kind": "run", "id": run.get("Id")}
	lot = BlueRidge.Lots.Lot.getByName(t)
	if lot:
		return {"kind": "lot", "id": lot.get("Id")}
	cid = BlueRidge.Common.Util.toIntOrNone(t)
	if cid is not None:
		return {"kind": "container", "id": cid}
	return {"kind": None, "id": None}


def findByScan(text):
	"""Which super-lot does this scan belong to? {"runId", "message"}."""
	hit = _resolveScan(text)
	if hit["kind"] == "run":
		return {"runId": hit["id"], "message": ""}
	if hit["kind"] in ("lot", "container"):
		row = BlueRidge.Common.Db.execOne("quality/ControlledRun_GetOpenByMember", {
			"lotId": hit["id"] if hit["kind"] == "lot" else None,
			"containerId": hit["id"] if hit["kind"] == "container" else None})
		if row:
			return {"runId": row.get("Id"), "message": ""}
		return {"runId": None, "message": "That is not in an open super-lot."}
	return {"runId": None, "message": "Scan not recognised."}


def preview(criteria):
	"""criteria: anchorLotId, itemId, locationId, fromAtEastern, toAtEastern, includeDescendants."""
	c = _u(criteria) or {}
	return BlueRidge.Common.Db.execList("quality/ControlledRun_PreviewSelection", {
		"anchorLotId":        c.get("anchorLotId"),
		"itemId":             c.get("itemId"),
		"locationId":         c.get("locationId"),
		"fromAtEastern":      c.get("fromAtEastern"),
		"toAtEastern":        c.get("toAtEastern"),
		"includeDescendants": 1 if c.get("includeDescendants") else 0,
	}) or []


def _membersJson(rows):
	"""Preview/selection rows -> the [{lotId}|{containerId}] the procs take."""
	out = []
	for r in (_u(rows) or []):
		if r.get("ContainerId"):
			out.append({"containerId": r.get("ContainerId")})
		elif r.get("LotId"):
			out.append({"lotId": r.get("LotId")})
	return system.util.jsonEncode(out)


def open(criteria, memberRows, appUserId, terminalLocationId):
	"""Open a super-lot. criteria as preview() plus reason, autoJoinEnabled."""
	BlueRidge.Common.Util.log("open criteria=%s members=%s" % (criteria, len(_u(memberRows) or [])))
	appUserId = BlueRidge.Common.Util.requireAppUserId(appUserId)
	c = _u(criteria) or {}
	return BlueRidge.Common.Db.execMutation("quality/ControlledRun_Open", {
		"reason":                 c.get("reason"),
		"anchorLotId":            c.get("anchorLotId"),
		"selectionItemId":        c.get("itemId"),
		"selectionLocationId":    c.get("locationId"),
		"selectionFromAtEastern": c.get("fromAtEastern"),
		"selectionToAtEastern":   c.get("toAtEastern"),
		"includeDescendants":     1 if c.get("includeDescendants") else 0,
		"autoJoinEnabled":        1 if c.get("autoJoinEnabled") else 0,
		"membersJson":            _membersJson(memberRows),
		"appUserId":              appUserId,
		"terminalLocationId":     _u(terminalLocationId),
	})


def addByScan(runId, text, appUserId, terminalLocationId):
	appUserId = BlueRidge.Common.Util.requireAppUserId(appUserId)
	hit = _resolveScan(text)
	if hit["kind"] == "lot":
		members = [{"lotId": hit["id"]}]
	elif hit["kind"] == "container":
		members = [{"containerId": hit["id"]}]
	else:
		return {"Status": 0, "Message": "Scan a LOT ticket or a container label."}
	return BlueRidge.Common.Db.execMutation("quality/ControlledRun_AddMembers", {
		"id": _u(runId), "membersJson": system.util.jsonEncode(members),
		"appUserId": appUserId, "terminalLocationId": _u(terminalLocationId)})


def removeMember(memberId, remarks, appUserId, terminalLocationId):
	appUserId = BlueRidge.Common.Util.requireAppUserId(appUserId)
	return BlueRidge.Common.Db.execMutation("quality/ControlledRun_RemoveMember", {
		"memberId": _u(memberId), "remarks": _u(remarks),
		"appUserId": appUserId, "terminalLocationId": _u(terminalLocationId)})


def setAutoJoin(runId, enabled, appUserId, terminalLocationId):
	appUserId = BlueRidge.Common.Util.requireAppUserId(appUserId)
	return BlueRidge.Common.Db.execMutation("quality/ControlledRun_SetAutoJoin", {
		"id": _u(runId), "enabled": 1 if _u(enabled) else 0,
		"appUserId": appUserId, "terminalLocationId": _u(terminalLocationId)})


def close(runId, remarks, appUserId, terminalLocationId):
	appUserId = BlueRidge.Common.Util.requireAppUserId(appUserId)
	return BlueRidge.Common.Db.execMutation("quality/ControlledRun_Close", {
		"id": _u(runId), "remarks": _u(remarks),
		"appUserId": appUserId, "terminalLocationId": _u(terminalLocationId)})


def cancel(runId, remarks, appUserId, terminalLocationId):
	appUserId = BlueRidge.Common.Util.requireAppUserId(appUserId)
	return BlueRidge.Common.Db.execMutation("quality/ControlledRun_Cancel", {
		"id": _u(runId), "remarks": _u(remarks),
		"appUserId": appUserId, "terminalLocationId": _u(terminalLocationId)})


def sync(runId, appUserId):
	appUserId = BlueRidge.Common.Util.requireAppUserId(appUserId)
	return BlueRidge.Common.Db.execMutation(
		"quality/ControlledRun_SyncAutoJoin", {"id": _u(runId), "appUserId": appUserId})


def syncTick():
	"""Gateway timer entry: record membership for anything the mint resolver
	   tagged since the last tick. The whole tick is guarded - a timer must never
	   throw. The BLOCK does not depend on this; only the member list does."""
	from java.lang import Throwable
	try:
		return BlueRidge.Common.Db.execMutation("quality/ControlledRun_SyncAutoJoin", {
			"id": None, "appUserId": BlueRidge.Common.Util.systemAppUserId()})
	except (Exception, Throwable) as e:
		BlueRidge.Common.Util.log("ControlledRun.syncTick failed: %s" % e, level="error")
		return {"Status": 0, "Message": "sync failed"}


def printLabels(runId, appUserId, terminalLocationId):
	"""Render four super-lot labels and send them to this terminal's printer.
	   Same transport as LTT labels (BlueRidge.Lots.LabelTransport - the one place
	   ZPL leaves the gateway). A failed print never undoes anything."""
	appUserId = BlueRidge.Common.Util.requireAppUserId(appUserId)
	tid = _u(terminalLocationId)
	printer = BlueRidge.Location.Terminal.getPrinter(tid) or {}
	res = BlueRidge.Common.Db.execMutation("quality/ControlledRunLabel_Print", {
		"id": _u(runId), "appUserId": appUserId, "terminalLocationId": tid,
		"printerName": printer.get("code") or None})
	if not res or not res.get("Status"):
		return res
	endpoint = (printer.get("endpoint") or "").strip()
	if not endpoint:
		return {"Status": 0, "Message": "This terminal has no printer configured.", "NewId": res.get("NewId")}
	zpl = res.get("ZplContent") or ""
	outcome = BlueRidge.Lots.LabelTransport.send(endpoint, zpl)
	BlueRidge.Lots.LabelTransport.logDispatch(endpoint, zpl, outcome, "SUPERLOT")
	if outcome.get("ok"):
		return {"Status": 1, "Message": "4 super-lot labels printed.", "NewId": res.get("NewId")}
	return {"Status": 0,
			"Message": "Print failed: %s. Press Print again to retry." % (outcome.get("error") or "unknown"),
			"NewId": res.get("NewId")}
```

`resource.json` for the module: copy `BlueRidge/Quality/Crt/resource.json`.

Before committing confirm three names this module leans on exist with these signatures: `BlueRidge.Lots.Lot.getByName(name)`, `BlueRidge.Common.Util.toIntOrNone(v)`, and `LabelTransport.logDispatch(endpoint, zpl, outcome, labelKind)`. If `logDispatch` restricts `labelKind` to a known set, read `_dispatchLogParams` and pass a kind it accepts.

- [ ] **Step 3: Scan and smoke the module**

```powershell
.\scan.ps1
```

Apply migration `0109` and the repeatables to `MPP_MES_Dev` first **only with Jacques's go-ahead** (Dev is hand-built; this is additive, but ask). Then in the Designer Script Console:

```python
print BlueRidge.Quality.ControlledRun.listRuns("Open", None)
print BlueRidge.Quality.ControlledRun.getRunOrEmpty(None)
print BlueRidge.Quality.ControlledRun.findByScan("CR999999")
```

Expected: `[]`; the full `_EMPTY_RUN` dict; `{'runId': None, 'message': 'Scan not recognised.'}`. Check the gateway log for `Named query not found` — there must be none.

- [ ] **Step 4: Commit**

```powershell
git add -- ignition/projects/Core/ignition/named-query/quality/ControlledRun_List ignition/projects/Core/ignition/named-query/quality/ControlledRun_Get ignition/projects/Core/ignition/named-query/quality/ControlledRun_GetByNumber ignition/projects/Core/ignition/named-query/quality/ControlledRun_ListMembers ignition/projects/Core/ignition/named-query/quality/ControlledRun_GetOpenByMember ignition/projects/Core/ignition/named-query/quality/ControlledRun_PreviewSelection ignition/projects/Core/ignition/named-query/quality/ControlledRun_Open ignition/projects/Core/ignition/named-query/quality/ControlledRun_AddMembers ignition/projects/Core/ignition/named-query/quality/ControlledRun_RemoveMember ignition/projects/Core/ignition/named-query/quality/ControlledRun_SyncAutoJoin ignition/projects/Core/ignition/named-query/quality/ControlledRun_SetAutoJoin ignition/projects/Core/ignition/named-query/quality/ControlledRun_Close ignition/projects/Core/ignition/named-query/quality/ControlledRun_Cancel ignition/projects/Core/ignition/named-query/quality/ControlledRunLabel_Print ignition/projects/Core/ignition/script-python/BlueRidge/Quality/ControlledRun
git commit -m "feat(quality): super-lot named queries + BlueRidge.Quality.ControlledRun"
```

---

### Task 12: The Quality view

The mockup is the visual authority. Open `mockup/controlled_run_super_lot_mock.html` beside the work and match it scene by scene. Before writing any JSON read `ignition-context-pack/02_perspective_views.md`, `06_component_quirks.md` and `07_conventions_and_antipatterns.md`, and open `Components/Popups/CrtValidation/view.json` — it is the reference for the stateless credential pattern used here.

**Files:**
- Create: `ignition/projects/MPP/com.inductiveautomation.perspective/views/BlueRidge/Views/ShopFloor/ControlledRuns/` (`view.json`, `resource.json`)
- Create: `.../views/BlueRidge/Components/Popups/ControlledRunNew/` (`view.json`, `resource.json`)
- Create: `.../views/BlueRidge/Components/Popups/ControlledRunConfirm/` (`view.json`, `resource.json`)
- Modify: `ignition/projects/MPP/com.inductiveautomation.perspective/page-config/config.json`
- Modify (Designer): `Components/Popups/AppMenu`

**Interfaces:**
- Consumes: everything in `BlueRidge.Quality.ControlledRun`; `BlueRidge.Location.AppUser.elevate(adAccount, password, actionCode, terminalLocationId)` → `{success, appUserId, message}`; `BlueRidge.Common.Ui.notifyResult(result, successTitle)`; `BlueRidge.Common.Notify.toast(title, msg, level)`; `session.custom.terminal.terminalLocationId`.
- Produces: route `/shop-floor/controlled-runs`; page-scoped messages `controlledRunChanged` `{runId}` and `controlledRunSelect` `{runId}`.

**Elevation model for this view.** Reading and printing need no credential. Every mutation takes a network credential at the moment it is made, the **stateless** form: `elevate(account, password, "ControlledRun", terminalLocationId)` returns the approver's `appUserId`, which is passed straight to the mutation and never stored on the session. The wizard's step 3 and the `ControlledRunConfirm` popup are the only two places a password is typed. Clear the password property immediately after the call, success or failure.

- [ ] **Step 1: `ControlledRunConfirm` popup** — one small popup for Add, Remove, End window, Resume window, Close and Cancel.

Params (input): `popupId`, `action` (`"add"|"remove"|"endWindow"|"resumeWindow"|"close"|"cancel"`), `runId`, `runNumber`, `memberId`, `memberName`, `terminalLocationId`.

Custom (all pre-declared): `adAccount: ""`, `password: ""`, `remarks: ""`, `scanText: ""`, `busy: false`.

Layout: header (title by action: `Add to CR…`, `Remove <memberName>`, `End window`, `Resume adding new production`, `Close super-lot CR…`, `Cancel super-lot CR…`); a scan/type text field shown only for `add` (`position.display` bound to `{view.params.action} = 'add'`); a remarks text area shown for `remove`, `close`, `cancel` (label `Reason (required)` for remove and cancel, `Remarks (optional)` for close); account field; password field (`type: "password"`); footer Cancel + Confirm. All inputs `deferUpdates: false`.

Confirm button script (`events.component.onActionPerformed`, scope `G`):

```python
	v = self.view
	if v.custom.busy:
		return
	v.custom.busy = True
	try:
		tid = v.params.terminalLocationId
		el = BlueRidge.Location.AppUser.elevate(v.custom.adAccount, v.custom.password, "ControlledRun", tid)
		v.custom.password = ""
		if not el or not el.get("success"):
			BlueRidge.Common.Notify.toast("Not authorised", (el or {}).get("message") or "Authentication failed.", "error")
			return
		uid = el.get("appUserId")
		CR = BlueRidge.Quality.ControlledRun
		a = v.params.action
		if a == "add":
			res = CR.addByScan(v.params.runId, v.custom.scanText, uid, tid)
		elif a == "remove":
			res = CR.removeMember(v.params.memberId, v.custom.remarks, uid, tid)
		elif a == "endWindow":
			res = CR.setAutoJoin(v.params.runId, False, uid, tid)
		elif a == "resumeWindow":
			res = CR.setAutoJoin(v.params.runId, True, uid, tid)
		elif a == "close":
			res = CR.close(v.params.runId, v.custom.remarks, uid, tid)
		elif a == "cancel":
			res = CR.cancel(v.params.runId, v.custom.remarks, uid, tid)
		else:
			res = {"Status": 0, "Message": "Unknown action."}
		BlueRidge.Common.Ui.notifyResult(res, "Super-lot %s" % v.params.runNumber)
		if res and res.get("Status"):
			system.perspective.sendMessage("controlledRunChanged", payload={"runId": v.params.runId}, scope="page")
			system.perspective.closePopup(v.params.popupId)
	finally:
		v.custom.busy = False
```

For `add`, keep the popup open after a successful add and clear `scanText` instead of closing, so Quality can scan several units on one credential entry — replace the last two lines of the success branch for `a == "add"` with `v.custom.scanText = ""` and leave the popup open; the credential fields stay filled except the password, which means a second scan needs the password again. That is deliberate: one password, one decision.

- [ ] **Step 2: `ControlledRunNew` popup** — the three-step wizard (mock scenes 2, 3, 4).

Params: `popupId`, `terminalLocationId`.

Custom, fully shaped:

```json
{
  "step": 1,
  "draft": {
    "reason": "", "anchorText": "", "anchorLotId": null, "anchorLotName": "",
    "itemId": null, "partNumber": "", "locationId": null, "locationName": "",
    "fromAtEastern": null, "toAtEastern": null,
    "includeDescendants": false, "autoJoinEnabled": false
  },
  "rows": [],
  "totals": {"lots": 0, "containers": 0, "pieces": 0, "ineligible": 0, "ticked": 0},
  "adAccount": "", "password": "", "busy": false
}
```

Step 1 fields bidi-bind to `view.custom.draft.*` with `"bidirectional": true` **inside** the binding `config`. Part and line are dropdowns (`options` are `{label, value}` only; `placeholder` is an object) fed by the existing item and location list wrappers — find them with a search for the dropdown bindings in `Views/ShopFloor/HoldManagement` and `LotSearch` and reuse the same script functions. From/To are `ia.input.date-time-input` writing wall-clock Eastern values.

The **Suspect LOT** field's commit script resolves the LTT and pre-fills the rest in ONE write (atomic, so no half-filled draft is ever bound):

```python
	t = (self.props.text or "").strip()
	d = dict(BlueRidge.Common.Util.extractQualifiedValues(self.view.custom.draft))
	lot = BlueRidge.Lots.Lot.getByName(t) if t else None
	if lot:
		d["anchorLotId"] = lot.get("Id")
		d["anchorLotName"] = lot.get("LotName")
		d["itemId"] = lot.get("ItemId")
		d["fromAtEastern"] = None      # blank = "from when this LOT was made" (the proc defaults it)
		d["includeDescendants"] = True
	else:
		d["anchorLotId"] = None
		d["anchorLotName"] = ""
		if t:
			BlueRidge.Common.Notify.toast("LOT not found", "No LOT named %s." % t, "warn")
	self.view.custom.draft = d
```

The line is NOT pre-filled from the LOT: the LOT row gives a terminal, not a line, and guessing the level is a rule. Leave it for Quality to pick. (This is a deliberate narrowing of the mock, which shows the line filled in — say so in the commit message.)

**Preview** button (step 1 → 2): requires a reason; calls `preview(draft)`; shapes rows for the table in ONE write:

```python
	v = self.view
	d = BlueRidge.Common.Util.extractQualifiedValues(v.custom.draft)
	if not (d.get("reason") or "").strip():
		BlueRidge.Common.Notify.toast("Reason needed", "Say why this super-lot is being opened.", "warn")
		return
	rows = BlueRidge.Quality.ControlledRun.preview(d)
	out = []
	for r in rows:
		r = dict(r)
		r["Ticked"] = bool(r.get("Eligible"))
		out.append(r)
	v.custom.rows = out
	v.rootContainer.recount()
	v.custom.step = 2
```

Root custom method `recount` (params `[]`):

```python
	rows = BlueRidge.Common.Util.extractQualifiedValues(self.view.custom.rows) or []
	t = {"lots": 0, "containers": 0, "pieces": 0, "ineligible": 0, "ticked": 0}
	for r in rows:
		if not r.get("Eligible"):
			t["ineligible"] += 1
			continue
		if not r.get("Ticked"):
			continue
		t["ticked"] += 1
		t["pieces"] += int(r.get("PieceCount") or 0)
		if r.get("Kind") == "Container":
			t["containers"] += 1
		else:
			t["lots"] += 1
	self.view.custom.totals = t
```

(Counting ticked rows is display arithmetic over rows SQL already judged; eligibility itself is never recomputed here.)

Step 2 lists rows in a flex repeater of a row template drawn inside this same view file's repeater `instances` (bind `instances` through a **script call** that returns the shaped list — never bind a `view.custom` list of dicts straight into a repeater transform). Each row: a tick button (toggles `Ticked`, disabled when `Eligible` is false), kind, name, part, where, status, pieces, made, found by, and the ineligible reason as a red pill. Toggling writes the whole `rows` list back in one assignment, then calls `recount`. **Tick all** / **Untick all** set `Ticked` on eligible rows only.

Step 3 shows the sentence from the mock using `totals`, the auto-join note when `draft.autoJoinEnabled`, and the two credential fields. **Open super-lot**:

```python
	v = self.view
	if v.custom.busy:
		return
	v.custom.busy = True
	try:
		tid = v.params.terminalLocationId
		el = BlueRidge.Location.AppUser.elevate(v.custom.adAccount, v.custom.password, "ControlledRun", tid)
		v.custom.password = ""
		if not el or not el.get("success"):
			BlueRidge.Common.Notify.toast("Not authorised", (el or {}).get("message") or "Authentication failed.", "error")
			return
		rows = [r for r in (BlueRidge.Common.Util.extractQualifiedValues(v.custom.rows) or []) if r.get("Ticked") and r.get("Eligible")]
		res = BlueRidge.Quality.ControlledRun.open(v.custom.draft, rows, el.get("appUserId"), tid)
		BlueRidge.Common.Ui.notifyResult(res, "Super-lot")
		if res and res.get("Status"):
			system.perspective.sendMessage("controlledRunSelect", payload={"runId": res.get("NewId")}, scope="page")
			system.perspective.closePopup(v.params.popupId)
	finally:
		v.custom.busy = False
```

- [ ] **Step 3: The `ControlledRuns` page** (mock scenes 1 and 6).

Custom, fully shaped:

```json
{
  "filter": {"statusCode": "Open", "text": ""},
  "selectedRunId": null,
  "selectedMemberId": null,
  "selectedMemberName": "",
  "scanText": "",
  "refreshToken": 0
}
```

Bound custom props, each with a `propConfig` binding AND a shaped default in the `custom` block:

- `runs` (default `[]`) ← `runScript("BlueRidge.Quality.ControlledRun.listRuns", 0, {view.custom.filter.statusCode}, {view.custom.filter.text}, {view.custom.refreshToken})`
- `run` (default: the full `_EMPTY_RUN` shape, every key) ← `runScript("BlueRidge.Quality.ControlledRun.getRunOrEmpty", 0, {view.custom.selectedRunId}, {view.custom.refreshToken})`
- `members` (default `[]`) ← `runScript("BlueRidge.Quality.ControlledRun.listMembers", 0, {view.custom.selectedRunId}, {view.custom.refreshToken})`

Layout: two columns, left 540 px. **Left:** scan field; a three-button status segment (`Open` / `Closed` / `All`) writing `filter.statusCode`; **+ New super-lot**; the run list (flex repeater, instances via a script call) — each card shows run number, window pill (`WindowOpen`), reason (one line, ellipsis), a progress bar of `ClearedCount / MemberCount`, part and line, and `"%d of %d cleared"`. Tapping a card sets `selectedRunId` and clears `selectedMemberId`. **Right** (hidden with `position.display` when `run.Id` is null, replaced by a "Select or scan a super-lot" hint): header (run number, status pill, window pill, reason, `CriteriaText`, `Opened by <initials>, <OpenedAt>`), three stat tiles (`MemberCount`, `ClearedCount`, `PieceCount`), the action row, the status note, the tab strip, the member table.

Tabs: `Members` only is live. Render `Results`, `Sign-off`, `History` as disabled labels exactly as the mock shows, each with the small "later piece" tag. They are placeholders for the next pieces of this feature — do not wire them.

Member table: `ia.display.table` with the **full column schema** on every column (copy a complete column object from the Audit Browser view), `props.data` bound to `view.custom.members`, columns `Kind`, `DisplayName`, `PartNumber`, `CurrentLocationName`, `PieceCount`, `CrtActive` (rendered `CRT` / `Cleared`), `JoinMethodName`, `AddedAt`. Row selection uses **`onSelectionChange`**, reading `self.props.selection.data`:

```python
	sel = self.props.selection.data
	if sel is None or len(sel) == 0:
		self.view.custom.selectedMemberId = None
		self.view.custom.selectedMemberName = ""
		return
	row = sel[0]
	self.view.custom.selectedMemberId = row["MemberId"]
	self.view.custom.selectedMemberName = row["DisplayName"]
```

Action row — enablement is by expression on `view.custom.run`:

| Button | Enabled when | Does |
|---|---|---|
| Add (scan) | `run.StatusCode = 'Open'` | opens `ControlledRunConfirm` `action: "add"` |
| Remove | open AND `selectedMemberId` not null | `action: "remove"` with `memberId`, `memberName` |
| Print 4 labels | `run.Id` not null | calls `printLabels` directly, no credential |
| End window | open AND `run.AutoJoinEnabled` | `action: "endWindow"` |
| Resume | open AND NOT `AutoJoinEnabled` AND `AutoJoinEndedAt` not null | `action: "resumeWindow"` |
| Close super-lot | open AND NOT `AutoJoinEnabled` AND `ClearedCount = MemberCount` | `action: "close"` |
| Cancel super-lot (in an overflow / secondary style, far right) | open | `action: "cancel"` |

Status note text (expression, C-style operators, no `forEach`):

```
if({view.custom.run.StatusCode} != 'Open', '',
 if({view.custom.run.AutoJoinEnabled}, 'Close is unavailable: the window is still open.',
  if({view.custom.run.ClearedCount} < {view.custom.run.MemberCount},
     'Close is unavailable: ' + toStr({view.custom.run.MemberCount} - {view.custom.run.ClearedCount}) + ' members are still CRT-tagged.',
     'Every member is cleared and the window has ended. This super-lot can be closed.')))
```

The enabled rule and the note mirror `ControlledRun_Close`'s guards for the operator's benefit only; the proc is the authority and its message is toasted if they ever disagree.

Print button script:

```python
	uid = BlueRidge.Common.Session.currentAppUserId(self.session)
	tid = self.session.custom.terminal.terminalLocationId
	res = BlueRidge.Quality.ControlledRun.printLabels(self.view.custom.selectedRunId, uid, tid)
	BlueRidge.Common.Ui.notifyPrintResult(res, "Super-lot labels")
```

Opening a popup from a button (scope `G`):

```python
	system.perspective.openPopup("mpp-controlled-run-confirm", "BlueRidge/Components/Popups/ControlledRunConfirm",
		params={"popupId": "mpp-controlled-run-confirm", "action": "add",
			"runId": self.view.custom.selectedRunId, "runNumber": self.view.custom.run.RunNumber,
			"memberId": None, "memberName": "",
			"terminalLocationId": self.session.custom.terminal.terminalLocationId},
		modal=True, showCloseIcon=True, overlayDismiss=False)
```

Scan field commit script:

```python
	t = (self.props.text or "").strip()
	if not t:
		return
	hit = BlueRidge.Quality.ControlledRun.findByScan(t)
	self.props.text = ""
	if hit.get("runId"):
		self.view.custom.filter = {"statusCode": "All", "text": ""}
		self.view.custom.selectedRunId = hit.get("runId")
		self.view.custom.selectedMemberId = None
	else:
		BlueRidge.Common.Notify.toast("Not found", hit.get("message") or "Scan not recognised.", "warn")
```

(Filter flips to `All` so a scanned closed super-lot is visible in the list it is selected in.)

Root message handlers (page scope, `pageScope: true`):

- `controlledRunChanged`: `self.view.custom.refreshToken = (self.view.custom.refreshToken or 0) + 1` — a direct write; do not call `refreshBinding` from a handler.
- `controlledRunSelect`: set `selectedRunId` from the payload, set the filter to `Open`, bump `refreshToken`.

`events.system.onStartup` on the root (NOT `events.component`): bump `refreshToken` once so the three bindings evaluate against a real token.

Selecting a run also triggers a sync so the member list is current. Put it in the card's click script, after setting `selectedRunId`, guarded so a failure never blocks selection:

```python
	from java.lang import Throwable
	try:
		BlueRidge.Quality.ControlledRun.sync(rid, BlueRidge.Common.Session.currentAppUserId(self.session))
	except (Exception, Throwable) as e:
		BlueRidge.Common.Util.log("sync on select failed: %s" % e, level="warn")
	self.view.custom.refreshToken = (self.view.custom.refreshToken or 0) + 1
```

Styling: use the existing `psc-pf-*` / `pf-btn` classes from the Core stylesheet for buttons, cards and pills; add no new stylesheet rules unless a mock element has no existing class, and then add them to the **Core** stylesheet only.

- [ ] **Step 4: Register the route** — file-edit `page-config/config.json`, adding beside `/shop-floor/hold-management`:

```json
    "/shop-floor/controlled-runs": {
      "title": "Super-lots",
      "viewPath": "BlueRidge/Views/ShopFloor/ControlledRuns"
    },
```

Match the neighbouring entries exactly; if they carry a `docks` block for the app header, copy it. Validate the file is still valid JSON with no trailing comma and no BOM:

```powershell
python -I -c "import json,io; json.load(io.open(r'ignition\projects\MPP\com.inductiveautomation.perspective\page-config\config.json', encoding='utf-8')); print('ok')"
```

- [ ] **Step 5: Scan and render-check**

```powershell
.\scan.ps1
```

Open `/shop-floor/controlled-runs` in the session. Expected: the page renders with an empty list and the "Select or scan a super-lot" hint; **no red Component Error on any element**; the gateway log shows no `expected string, got null`, no `Named query not found`. If the page is stuck on "loading", check for a trailing comma, a BOM, or an event object missing its `scope` key.

- [ ] **Step 6: Menu entry (Designer)** — in Designer, open `Components/Popups/AppMenu`, duplicate the `NavHold` button directly below it, rename it `NavSuperLots`, text `Super-lots`, and change its script's route to `/shop-floor/controlled-runs`. Save. Then check `git diff --stat` — if the diff touches more than that one button (Designer pickling live data), revert and redo.

- [ ] **Step 7: Walk the six mock scenes against the running page**

With `MPP_MES_Dev` carrying migration `0109` and a few seeded LOTs (`.\Seed-Demo.ps1` if Dev has none — ask first), walk: open the wizard; scan a suspect LOT; preview; untick one row and watch the totals change; confirm with a credential; see the new run selected; print labels; add by scan; remove with a reason; end the window; clear the members on LOT Detail; close. Because the in-app browser cannot commit input bindings, verify each **submit** in SQL:

```sql
SELECT TOP 5 Id, RunNumber, ControlledRunStatusId, AutoJoinEnabled, ClosedAt FROM Quality.ControlledRun ORDER BY Id DESC;
SELECT TOP 20 * FROM Quality.ControlledRunMember ORDER BY Id DESC;
SELECT TOP 10 Description FROM Audit.OperationLog ORDER BY Id DESC;
```

If elevation is denied for every credential, the gateway has no `Active Directory` user source (see the banner above `_ELEVATION_USER_SOURCE` in `BlueRidge/Location/AppUser/code.py`). Do not change that constant in a commit.

- [ ] **Step 8: Commit**

```powershell
git status --short
git add -- "ignition/projects/MPP/com.inductiveautomation.perspective/views/BlueRidge/Views/ShopFloor/ControlledRuns" "ignition/projects/MPP/com.inductiveautomation.perspective/views/BlueRidge/Components/Popups/ControlledRunNew" "ignition/projects/MPP/com.inductiveautomation.perspective/views/BlueRidge/Components/Popups/ControlledRunConfirm" "ignition/projects/MPP/com.inductiveautomation.perspective/page-config/config.json" "ignition/projects/MPP/com.inductiveautomation.perspective/views/BlueRidge/Components/Popups/AppMenu/view.json"
git commit -m "feat(quality): super-lot Quality view -- list, wizard, members, labels"
```

Do not stage `thumbnail.png` or any `data.bin`.

---

### Task 13: Background sync timer

**Files:**
- Create: `ignition/projects/MPP/ignition/timer/ControlledRunSyncTimer/handleTimerEvent.py`, `resource.json`

- [ ] **Step 1: Write the timer.** `handleTimerEvent.py` — `def handleTimerEvent():` MUST be line 1:

```python
def handleTimerEvent():
	# Every 60s: record super-lot membership for new production the mint resolver
	# already tagged. SHIPS DISABLED. The CRT block never depends on this timer -
	# only how soon a new LOT appears in the member list.
	BlueRidge.Quality.ControlledRun.syncTick()
```

`resource.json`: copy `ignition/projects/MPP/ignition/timer/AimPostTimer/resource.json`, keep `"delay": 60000`, `"fixedDelay": true`, `"sharedThread": true`, set `"enabled": false`, clear `"lastModificationSignature"` to `""`, set `lastModification` actor `claude`, timestamp `2026-10-12T12:00:00Z`.

- [ ] **Step 2: Scan, and prove the entry point by hand**

```powershell
.\scan.ps1
```

Script Console: `print BlueRidge.Quality.ControlledRun.syncTick()` → `{u'Status': True, u'Message': u'0 added.'}` (or a count). Confirm the timer shows as **disabled** in Designer.

- [ ] **Step 3: Commit**

```powershell
git add -- ignition/projects/MPP/ignition/timer/ControlledRunSyncTimer
git commit -m "feat(quality): super-lot background sync timer (committed disabled)"
```

---

### Task 14: Documents

**Files:**
- Modify: `MPP_MES_DATA_MODEL.md`, `PROJECT_STATUS.md`, `sql/migrations/repeatable/R__Descriptions_ExtendedProperties.sql`

- [ ] **Step 1: Data model.** In `MPP_MES_DATA_MODEL.md` § Quality add `ControlledRun`, `ControlledRunMember`, `ControlledRunLabel` and the three code tables, in the existing column-table format, with the descriptions from the spec § 5 and the migration. Tag them as a change-order addition, not MVP. Add a Revision History row. Write the descriptions ASCII-only — `gen_extended_properties.js` lifts them into the database.

- [ ] **Step 2: Regenerate extended properties**

```powershell
node sql/scripts/gen_extended_properties.js --stats
node sql/scripts/gen_extended_properties.js
git diff --stat -- sql/migrations/repeatable/R__Descriptions_ExtendedProperties.sql
```

Expected: the diff adds blocks for the six new tables and changes nothing else. Because migration `0109` already added table-level descriptions with `sp_addextendedproperty`, confirm the generated script uses add-or-update for those (it does for every object it emits).

- [ ] **Step 3: `PROJECT_STATUS.md`.** Append (never rewrite) a dated entry: what was built, that it is piece 1 of 6 and not deployable alone, the assertion count of `0109_ControlledRun`, that the sync timer is committed disabled, and the pointer to the overview note. Add its Revision History row.

- [ ] **Step 4: Regenerate the Word docs** only if the repo's convention is to keep `.docx` in step for the data model:

```powershell
pandoc MPP_MES_DATA_MODEL.md -o MPP_MES_DATA_MODEL.docx --reference-doc=reference.docx; if ($?) { node style_docx_tables.js MPP_MES_DATA_MODEL.docx }
```

- [ ] **Step 5: Commit**

```powershell
git add -- MPP_MES_DATA_MODEL.md PROJECT_STATUS.md sql/migrations/repeatable/R__Descriptions_ExtendedProperties.sql
git commit -m "docs(data-model,status): controlled run (super-lot) tables + status entry"
```

---

### Task 15: Whole-suite verification

**Files:** none.

- [ ] **Step 1: Run everything**

```powershell
.\sql\tests\Run-Tests.ps1 -DatabaseName MPP_MES_Test_CtrlRun *>&1 | Tee-Object -FilePath "$env:TEMP\ctrlrun_full.txt"
Select-String -Path "$env:TEMP\ctrlrun_full.txt" -Pattern "FAIL|ERROR running" | Select-Object -First 20
```

Expected: no `FAIL`, no `ERROR running`. The `0109_ControlledRun` folder contributes **139** assertions. Compare the grand total with a run of the same command on `jacques/working` at the branch point (`27eabc7c`): it must be exactly that total + 139. A smaller number means a file threw and the batches after it never ran — find it before going on.

- [ ] **Step 2: Byte-scan every new SQL file**

```powershell
Get-ChildItem sql\migrations\versioned\0109_controlled_run.sql, sql\migrations\repeatable\R__Quality_ControlledRun*.sql, sql\migrations\repeatable\R__Quality_ufn_zz_ControlledRun*.sql | ForEach-Object { $n = ([IO.File]::ReadAllBytes($_.FullName) | Where-Object { $_ -gt 126 }).Count; "{0}  {1}" -f $n, $_.Name }
```

Expected: `0` on every line. (The audit middle-dot comes from `Audit.ufn_MidDot()`, never a literal.)

- [ ] **Step 3: Report.** State plainly what passed, the assertion counts, anything skipped (the AD user source on the dev gateway is the likely one — if elevation could not be exercised, say the wizard's and popup's submit paths were verified only up to the credential check), and that nothing is deployable until the remaining pieces land.

---

## Self-review notes

- **Spec coverage:** §2 scope → Tasks 1–13; §4 D1–D12 → D1/D3/D4 Task 1, D2 Tasks 1+4, D5/D6 Tasks 4+6, D7 Tasks 7+8, D8/D9 Task 8, D10 Task 9, D11 Tasks 1+10+11, D12 Task 1; §6 procs → Tasks 2–10 (every proc in the spec's two tables has a task); §7 label → Tasks 1+10; §8 view → Task 12; §11 testing → each task plus Task 15. Extended properties → Tasks 1+14.
- **Departures from the spec, each deliberate:** (1) `ControlledRun_SyncAutoJoin` is a wrapper over a silent `ControlledRun_SyncInternal`, and member insertion lives in a silent `ControlledRun_ApplyMembersInternal`, because a status-row proc may not `EXEC` another status-row proc; the spec said "inlined in each proc" and this is one copy instead of three. (2) Preview and Open take **Eastern** wall-clock times and convert in SQL. (3) Event code `ControlledRunWindowChanged` replaces the spec's `ControlledRunWindowEnded` because the window can also be resumed; `ControlledRunCancelled` and `ControlledRunLabelPrinted` are added. (4) The wizard does not pre-fill the line from the suspect LOT.
- **Known soft spots for the executor:** the `sqlType` for BIT / DATETIME named-query parameters, the exact column lists of three seed tables, and three helper signatures in the script module are each called out at their step with what to check.
