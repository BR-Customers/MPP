# Arc 2 Phase 8 — Downtime + Shift Boundary — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deliver manual + PLC downtime entry, end-of-shift time entry, the shift-end summary, and a supervisor dashboard for the plant floor — closing Arc 2 Phase 8.

**Architecture:** SQL-first. Migration `0026` creates `Oee.DowntimeEvent` + a `DowntimeReasonCode.StandardDurationMinutes` delta + a `Break` reason type/codes seed + audit seeds. Four entry/mutation procs + three summary reads mirror the `Lots.LotPause_*` lifecycle pattern (open/close event, one-open-per-location, read-by-location). Ignition: one entity-script module (`BlueRidge.Oee.DowntimeEvent`, in **Core**) + Named Queries (**Core**) + four Perspective operator views and two Gateway scripts (in the **MPP** project, alongside the existing plant-floor views). PLC ingestion is verified against a tag simulator; the dashboard's AIM-pool + print-failure tiles are Phase-7 stubs.

**Tech Stack:** SQL Server 2022 (T-SQL, `CREATE OR ALTER` repeatable procs, `test.Assert_*` framework), Ignition 8.3 Perspective (file-based project), Jython 2.7 entity scripts via `BlueRidge.Common.Db`.

**Spec:** `docs/superpowers/specs/2026-06-16-arc2-phase8-downtime-shift-design.md` (read it first — contracts, decisions, divergences).

**Conventions (every SQL task):** FDS-11-011 (no `OUTPUT`; `@Status`/`@Message`[/`@NewId`] locals; single terminal `SELECT`); three-tier validation; `Audit.Audit_LogFailure` on each early exit + in CATCH; `Audit.Audit_LogOperation` inside the transaction (entity `DowntimeEvent` → `Audit.OperationLog`); audit `Description` via `Audit.ufn_MidDot()` + `Audit.ufn_TruncateActivity()`; resolved-FK JSON via `JSON_QUERY((… FOR JSON PATH, WITHOUT_ARRAY_WRAPPER))`; `RAISERROR` (not THROW) in CATCH. **Mirror `sql/migrations/repeatable/R__Lots_LotPause_Place.sql` exactly.**

**Reset/test loop:** `.\Reset-DevDatabase.ps1` applies all migrations; `.\sql\tests\Run-Tests.ps1` runs the suite. NQ pickup: `.\scan.ps1` (no gateway restart). New project views need the gateway to notice them (already linked via junction).

> **⚠️ Build-time verification (Phase-3 stale-base lesson):** before writing migration `0026`, run the audit-ID high-water query in Task 1 Step 1 and use the ACTUAL next-free Ids. The plan assumes `LogEventType` 37–41 and `LogEntityType` 47 from the disk high-water at spec time — confirm, don't trust.

---

## File Structure

**SQL (project-agnostic, under `sql/`):**
- Create: `sql/migrations/versioned/0026_arc2_phase8_downtime_shift.sql` — table + delta + seeds + audit seeds.
- Create: `sql/migrations/repeatable/R__Oee_DowntimeEvent_Start.sql`
- Create: `sql/migrations/repeatable/R__Oee_DowntimeEvent_End.sql`
- Create: `sql/migrations/repeatable/R__Oee_DowntimeReasonCode_Assign.sql`
- Create: `sql/migrations/repeatable/R__Oee_EndOfShiftEntry_Submit.sql`
- Create: `sql/migrations/repeatable/R__Oee_DowntimeEvent_GetOpenByLocation.sql`
- Create: `sql/migrations/repeatable/R__Oee_Lot_GetInProcessByLocation.sql`
- Create: `sql/tests/0026_PlantFloor_Downtime_Shift/010_DowntimeEvent_lifecycle.sql`
- Create: `…/020_DowntimeReasonCode_Assign.sql`, `…/030_DowntimeEvent_PLC_pattern.sql`, `…/040_DowntimeEvent_warmup_shotcount.sql`, `…/050_EndOfShiftEntry_Submit.sql`, `…/060_ShiftEndSummary_reads.sql`, `…/070_OpenEvents_span_boundary.sql`, `…/080_audit_shape.sql`

**Ignition entity script + NQs (Core — inheritable):**
- Create: `ignition/projects/Core/ignition/script-python/BlueRidge/Oee/DowntimeEvent/code.py` (+ `resource.json`)
- Create NQ folders under `ignition/projects/Core/ignition/named-query/oee/`: `DowntimeEvent_Start`, `DowntimeEvent_End`, `DowntimeReasonCode_Assign`, `EndOfShiftEntry_Submit`, `DowntimeEvent_GetOpenByLocation`, `Lot_GetInProcessByLocation` (each: `query.sql` + `resource.json`)

**Ignition views + gateway (MPP):**
- Create views under `ignition/projects/MPP/com.inductiveautomation.perspective/views/BlueRidge/Views/ShopFloor/`: `DowntimeEntry/`, `EndOfShiftEntry/`, `ShiftEndSummary/`, `SupervisorDashboard/` (+ row sub-views under `…/Components/PlantFloor/`)
- Create timer: `ignition/projects/MPP/ignition/timer/DowntimePlcWatcher/` (handleTimerEvent.py + resource.json) — mirror `ShiftBoundaryTicker`
- Modify: `ignition/projects/MPP/com.inductiveautomation.perspective/page-config/config.json` (4 routes)

---

## Task 1: Migration 0026 — table + delta + seeds

**Files:**
- Create: `sql/migrations/versioned/0026_arc2_phase8_downtime_shift.sql`

- [ ] **Step 1: Confirm the audit-ID high-water marks**

Run:
```
sqlcmd -S localhost -d MPP_MES -E -Q "SELECT 'EventType' k, MAX(Id) m FROM Audit.LogEventType UNION ALL SELECT 'EntityType', MAX(Id) FROM Audit.LogEntityType UNION ALL SELECT 'ReasonType', MAX(Id) FROM Oee.DowntimeReasonType;"
```
Expected (as of spec): EventType=36, EntityType=46, ReasonType=6. Use `EventType+1 … +5` (37–41), `EntityType+1` (47), `ReasonType+1` (7). If different, adjust the literals below.

- [ ] **Step 2: Write the migration**

```sql
-- ============================================================
-- Migration:   0026_arc2_phase8_downtime_shift.sql
-- Author:      Blue Ridge Automation
-- Description: Arc 2 Phase 8 — Downtime + Shift Boundary.
--              1. Oee.DowntimeEvent (append-only event table).
--              2. Oee.DowntimeReasonCode += StandardDurationMinutes (break durations).
--              3. Seed: Break reason type (7) + Lunch/Break 1/Break 2 codes
--                 (Site-scoped; uniform durations) — spec §3.2.
--              4. Audit seeds: LogEntityType DowntimeEvent (47);
--                 LogEventType 37-41 (Downtime*/EndOfShift*/ShiftHandover*).
-- ============================================================
SET XACT_ABORT ON;
BEGIN TRANSACTION;

IF EXISTS (SELECT 1 FROM dbo.SchemaVersion WHERE MigrationId = '0026_arc2_phase8_downtime_shift')
BEGIN
    PRINT 'Migration 0026 already applied — skipping.';
    COMMIT; RETURN;
END

-- ---- 1. Oee.DowntimeEvent ----
CREATE TABLE Oee.DowntimeEvent (
    Id                    BIGINT        NOT NULL IDENTITY(1,1) PRIMARY KEY,
    LocationId            BIGINT        NOT NULL,
    DowntimeReasonCodeId  BIGINT        NULL,
    ShiftId               BIGINT        NULL,
    StartedAt             DATETIME2(3)  NOT NULL,
    EndedAt               DATETIME2(3)  NULL,
    DowntimeSourceCodeId  BIGINT        NOT NULL,
    AppUserId             BIGINT        NULL,
    ShotCount             INT           NULL,
    Remarks               NVARCHAR(500) NULL,
    CreatedAt             DATETIME2(3)  NOT NULL DEFAULT SYSUTCDATETIME(),
    CONSTRAINT FK_DowntimeEvent_Location   FOREIGN KEY (LocationId)           REFERENCES Location.Location(Id),
    CONSTRAINT FK_DowntimeEvent_Reason     FOREIGN KEY (DowntimeReasonCodeId) REFERENCES Oee.DowntimeReasonCode(Id),
    CONSTRAINT FK_DowntimeEvent_Shift      FOREIGN KEY (ShiftId)              REFERENCES Oee.Shift(Id),
    CONSTRAINT FK_DowntimeEvent_Source     FOREIGN KEY (DowntimeSourceCodeId) REFERENCES Oee.DowntimeSourceCode(Id),
    CONSTRAINT FK_DowntimeEvent_AppUser    FOREIGN KEY (AppUserId)            REFERENCES Location.AppUser(Id)
);
-- B3: at most one OPEN downtime event per Location.
CREATE UNIQUE INDEX UX_DowntimeEvent_OneOpenPerLocation
    ON Oee.DowntimeEvent (LocationId) WHERE EndedAt IS NULL;
-- Shift availability rollup.
CREATE INDEX IX_DowntimeEvent_Shift ON Oee.DowntimeEvent (ShiftId, StartedAt);

-- ---- 2. DowntimeReasonCode delta ----
ALTER TABLE Oee.DowntimeReasonCode ADD StandardDurationMinutes INT NULL;
GO
-- (GO so the new column is visible to the seed batch below.)
SET XACT_ABORT ON;

-- ---- 3. Break reason type + codes (Site-scoped, uniform durations) ----
DECLARE @SiteId BIGINT = (SELECT TOP 1 l.Id FROM Location.Location l
    INNER JOIN Location.LocationType lt ON lt.Id = l.LocationTypeId
    WHERE lt.HierarchyLevel = 1 AND l.DeprecatedAt IS NULL ORDER BY l.Id);

IF NOT EXISTS (SELECT 1 FROM Oee.DowntimeReasonType WHERE Code = N'Break')
BEGIN
    SET IDENTITY_INSERT Oee.DowntimeReasonType ON;
    INSERT INTO Oee.DowntimeReasonType (Id, Code, Name) VALUES (7, N'Break', N'Break');
    SET IDENTITY_INSERT Oee.DowntimeReasonType OFF;
END

DECLARE @BreakTypeId BIGINT = (SELECT Id FROM Oee.DowntimeReasonType WHERE Code = N'Break');
-- Placeholder durations (MPP seed data point): Lunch 30, Break 1/2 = 15.
INSERT INTO Oee.DowntimeReasonCode (Code, Description, AreaLocationId, DowntimeReasonTypeId, IsExcused, StandardDurationMinutes, CreatedByUserId)
SELECT v.Code, v.Descr, @SiteId, @BreakTypeId, 1, v.Mins, 1
FROM (VALUES (N'LUNCH', N'Scheduled lunch', 30), (N'BREAK1', N'Scheduled break 1', 15), (N'BREAK2', N'Scheduled break 2', 15)) v(Code, Descr, Mins)
WHERE NOT EXISTS (SELECT 1 FROM Oee.DowntimeReasonCode rc WHERE rc.Code = v.Code);

-- ---- 4. Audit seeds (Ids confirmed in Step 1) ----
SET IDENTITY_INSERT Audit.LogEntityType ON;
INSERT INTO Audit.LogEntityType (Id, Code, Name, Description) VALUES
    (47, N'DowntimeEvent', N'Downtime Event', N'Oee.DowntimeEvent — machine downtime span (manual or PLC).');
SET IDENTITY_INSERT Audit.LogEntityType OFF;

SET IDENTITY_INSERT Audit.LogEventType ON;
INSERT INTO Audit.LogEventType (Id, Code, Name, Description) VALUES
    (37, N'DowntimeStarted',        N'Downtime Started',         N'A downtime event was opened.'),
    (38, N'DowntimeEnded',          N'Downtime Ended',           N'A downtime event was closed.'),
    (39, N'DowntimeReasonAssigned', N'Downtime Reason Assigned', N'A reason code was late-bound to an open downtime event (B7).'),
    (40, N'EndOfShiftSubmitted',    N'End-of-Shift Submitted',   N'An operator submitted end-of-shift lunch/break time entry.'),
    (41, N'ShiftHandoverAcknowledged', N'Shift Handover Acknowledged', N'An operator acknowledged the shift-end summary.');
SET IDENTITY_INSERT Audit.LogEventType OFF;

INSERT INTO dbo.SchemaVersion (MigrationId, Description)
VALUES ('0026_arc2_phase8_downtime_shift',
    'Phase 8: Oee.DowntimeEvent + DowntimeReasonCode.StandardDurationMinutes + Break type/codes seed + audit seeds (LogEntityType 47, LogEventType 37-41).');

COMMIT TRANSACTION;
PRINT 'Migration 0026 completed.';
```

- [ ] **Step 3: Apply + verify**

Run: `.\Reset-DevDatabase.ps1`
Expected: ends clean; `SELECT * FROM Oee.DowntimeReasonCode WHERE DowntimeReasonTypeId = 7` returns 3 rows with `StandardDurationMinutes` 30/15/15.

- [ ] **Step 4: Commit**
```bash
git add sql/migrations/versioned/0026_arc2_phase8_downtime_shift.sql
git commit -m "feat(arc2-p8-sql): migration 0026 - DowntimeEvent table + break seed + audit seeds"
```

---

## Task 2: `Oee.DowntimeEvent_Start` + test

**Files:**
- Create: `sql/migrations/repeatable/R__Oee_DowntimeEvent_Start.sql`
- Test: `sql/tests/0026_PlantFloor_Downtime_Shift/010_DowntimeEvent_lifecycle.sql` (Start portion)

- [ ] **Step 1: Write the proc** (mirror `LotPause_Place`; entity `DowntimeEvent` → OperationLog)

```sql
-- ============================================================
-- Repeatable:  R__Oee_DowntimeEvent_Start.sql
-- Description: Opens a downtime event at a machine/Cell. B3: rejects if an open
--              event already exists for @LocationId. Resolves the active Shift.
--              Reason may be NULL (late-binding, B7). Source = Manual or PLC.
--              Audits 'DowntimeStarted'. Returns SELECT @Status, @Message, @NewId.
-- ============================================================
CREATE OR ALTER PROCEDURE Oee.DowntimeEvent_Start
    @LocationId           BIGINT,
    @DowntimeReasonCodeId BIGINT = NULL,
    @DowntimeSourceCodeId BIGINT,
    @ShotCount            INT    = NULL,
    @AppUserId            BIGINT = NULL,
    @TerminalLocationId   BIGINT = NULL
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;
    DECLARE @Status BIT = 0, @Message NVARCHAR(500) = N'Unknown error', @NewId BIGINT = NULL;
    DECLARE @ProcName NVARCHAR(200) = N'Oee.DowntimeEvent_Start';
    DECLARE @Params NVARCHAR(MAX) = (SELECT @LocationId AS LocationId, @DowntimeSourceCodeId AS DowntimeSourceCodeId,
        @AppUserId AS AppUserId, @TerminalLocationId AS TerminalLocationId FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);
    DECLARE @LocCode NVARCHAR(50), @ShiftId BIGINT;

    BEGIN TRY
        IF @LocationId IS NULL OR @DowntimeSourceCodeId IS NULL
        BEGIN
            SET @Message = N'Required parameter missing (LocationId, DowntimeSourceCodeId).';
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId; RETURN;
        END

        SELECT @LocCode = Code FROM Location.Location WHERE Id = @LocationId AND DeprecatedAt IS NULL;
        IF @LocCode IS NULL
        BEGIN
            SET @Message = N'Location not found or deprecated.';
            EXEC Audit.Audit_LogFailure @AppUserId=@AppUserId, @LogEntityTypeCode=N'DowntimeEvent', @EntityId=NULL,
                @LogEventTypeCode=N'DowntimeStarted', @FailureReason=@Message, @ProcedureName=@ProcName, @AttemptedParameters=@Params;
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId; RETURN;
        END

        -- B3: one open event per Location (clean pre-check before the filtered-unique).
        IF EXISTS (SELECT 1 FROM Oee.DowntimeEvent WHERE LocationId = @LocationId AND EndedAt IS NULL)
        BEGIN
            SET @Message = N'An open downtime event already exists at this location.';
            EXEC Audit.Audit_LogFailure @AppUserId=@AppUserId, @LogEntityTypeCode=N'DowntimeEvent', @EntityId=NULL,
                @LogEventTypeCode=N'DowntimeStarted', @FailureReason=@Message, @ProcedureName=@ProcName, @AttemptedParameters=@Params;
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId; RETURN;
        END

        -- Active shift (may be NULL — downtime still records).
        SELECT TOP 1 @ShiftId = Id FROM Oee.Shift WHERE ActualEnd IS NULL ORDER BY ActualStart DESC;

        DECLARE @Activity NVARCHAR(500) = Audit.ufn_TruncateActivity(
            @LocCode + N' ' + Audit.ufn_MidDot() + N' Downtime ' + Audit.ufn_MidDot() + N' Started');
        DECLARE @NewValue NVARCHAR(MAX) = (
            SELECT JSON_QUERY((SELECT loc.Id, loc.Code, loc.Name FROM Location.Location loc WHERE loc.Id = @LocationId
                               FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)) AS Location,
                   JSON_QUERY((SELECT sc.Id, sc.Code, sc.Name FROM Oee.DowntimeSourceCode sc WHERE sc.Id = @DowntimeSourceCodeId
                               FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)) AS Source,
                   @ShotCount AS ShotCount
            FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

        BEGIN TRANSACTION;
        INSERT INTO Oee.DowntimeEvent (LocationId, DowntimeReasonCodeId, ShiftId, StartedAt, DowntimeSourceCodeId, AppUserId, ShotCount)
        VALUES (@LocationId, @DowntimeReasonCodeId, @ShiftId, SYSUTCDATETIME(), @DowntimeSourceCodeId, @AppUserId, @ShotCount);
        SET @NewId = SCOPE_IDENTITY();

        EXEC Audit.Audit_LogOperation @AppUserId=@AppUserId, @TerminalLocationId=@TerminalLocationId, @LocationId=@LocationId,
            @LogEntityTypeCode=N'DowntimeEvent', @EntityId=@NewId, @LogEventTypeCode=N'DowntimeStarted',
            @LogSeverityCode=N'Info', @Description=@Activity, @OldValue=NULL, @NewValue=@NewValue;
        COMMIT TRANSACTION;

        SET @Status = 1; SET @Message = N'Downtime started.';
        SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        DECLARE @ErrMsg NVARCHAR(4000)=ERROR_MESSAGE(), @ErrSev INT=ERROR_SEVERITY(), @ErrState INT=ERROR_STATE();
        SET @Status=0; SET @Message=N'Unexpected error: ' + LEFT(@ErrMsg, 400); SET @NewId=NULL;
        BEGIN TRY
            EXEC Audit.Audit_LogFailure @AppUserId=@AppUserId, @LogEntityTypeCode=N'DowntimeEvent', @EntityId=NULL,
                @LogEventTypeCode=N'DowntimeStarted', @FailureReason=@Message, @ProcedureName=@ProcName, @AttemptedParameters=@Params;
        END TRY BEGIN CATCH END CATCH
        SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
        RAISERROR(@ErrMsg, @ErrSev, @ErrState);
    END CATCH
END;
GO
```

- [ ] **Step 2: Write the failing lifecycle test (Start asserts)** — file `010_DowntimeEvent_lifecycle.sql`, mirroring `060_LotPause_lifecycle.sql` structure (`test.BeginTestFile`, GO-batched, fixtures via a Cell location + Manual source, teardown sweeps `Audit.OperationLog` + `Oee.DowntimeEvent`):

```sql
SET NOCOUNT ON; SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0026_PlantFloor_Downtime_Shift/010_DowntimeEvent_lifecycle.sql';
GO
IF OBJECT_ID(N'tempdb..#DtFix') IS NOT NULL DROP TABLE #DtFix;
CREATE TABLE #DtFix (Tag NVARCHAR(20) PRIMARY KEY, Val BIGINT);
GO
DECLARE @CellId BIGINT = (SELECT TOP 1 l.Id FROM Location.Location l
    INNER JOIN Location.LocationType lt ON lt.Id = l.LocationTypeId
    WHERE lt.HierarchyLevel = 4 AND l.DeprecatedAt IS NULL ORDER BY l.Id);
DECLARE @ManualId BIGINT = (SELECT Id FROM Oee.DowntimeSourceCode WHERE Code = N'Manual');
INSERT INTO #DtFix VALUES (N'CELL', @CellId), (N'MANUAL', @ManualId);
GO
-- Test 1: start opens an event
DECLARE @Cell BIGINT=(SELECT Val FROM #DtFix WHERE Tag=N'CELL'), @Src BIGINT=(SELECT Val FROM #DtFix WHERE Tag=N'MANUAL');
DECLARE @s1 TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO @s1 EXEC Oee.DowntimeEvent_Start @LocationId=@Cell, @DowntimeSourceCodeId=@Src, @AppUserId=1;
DECLARE @ok1 BIT=(SELECT Status FROM @s1), @id1 BIGINT=(SELECT NewId FROM @s1);
EXEC test.Assert_IsTrue @TestName=N'[Downtime] start succeeds', @Condition=@ok1;
EXEC test.Assert_IsNotNull @TestName=N'[Downtime] start returns NewId', @Value=@id1;
DECLARE @open1 INT=(SELECT COUNT(*) FROM Oee.DowntimeEvent WHERE Id=@id1 AND EndedAt IS NULL);
EXEC test.Assert_RowCount @TestName=N'[Downtime] event is open', @ExpectedCount=1, @ActualCount=@open1;
INSERT INTO #DtFix VALUES (N'EVT', @id1);
GO
-- Test 2: double-start at same Location rejected (B3)
DECLARE @Cell BIGINT=(SELECT Val FROM #DtFix WHERE Tag=N'CELL'), @Src BIGINT=(SELECT Val FROM #DtFix WHERE Tag=N'MANUAL');
DECLARE @s2 TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO @s2 EXEC Oee.DowntimeEvent_Start @LocationId=@Cell, @DowntimeSourceCodeId=@Src, @AppUserId=1;
DECLARE @s2cond BIT=CASE WHEN (SELECT Status FROM @s2)=0 THEN 1 ELSE 0 END;
EXEC test.Assert_IsTrue @TestName=N'[Downtime] double-start rejected (B3)', @Condition=@s2cond;
GO
-- (Test 3 End + Test 4 end-already-closed land in Task 3.)
-- ---- teardown ----
DELETE ol FROM Audit.OperationLog ol INNER JOIN #DtFix f ON f.Tag=N'EVT' AND f.Val=ol.EntityId
    WHERE ol.LogEntityTypeId=(SELECT Id FROM Audit.LogEntityType WHERE Code=N'DowntimeEvent');
DELETE FROM Oee.DowntimeEvent WHERE LocationId=(SELECT Val FROM #DtFix WHERE Tag=N'CELL');
IF OBJECT_ID(N'tempdb..#DtFix') IS NOT NULL DROP TABLE #DtFix;
GO
```

- [ ] **Step 3: Run** — `.\Reset-DevDatabase.ps1; .\sql\tests\Run-Tests.ps1 -File 0026_PlantFloor_Downtime_Shift/010_DowntimeEvent_lifecycle.sql`. Expected: Tests 1–2 PASS.
- [ ] **Step 4: Commit** — `git commit -am "feat(arc2-p8-sql): DowntimeEvent_Start + lifecycle test (start/B3)"`

---

## Task 3: `Oee.DowntimeEvent_End` + test

**Files:** Create `sql/migrations/repeatable/R__Oee_DowntimeEvent_End.sql`; extend `010_DowntimeEvent_lifecycle.sql`.

- [ ] **Step 1: Write the proc** — `@DowntimeEventId, @Remarks NULL, @AppUserId, @TerminalLocationId`. Mirror `LotPause_Resume`: validate the event exists + is open (`EndedAt IS NULL`); reject if already closed; `UPDATE … SET EndedAt = SYSUTCDATETIME(), Remarks = @Remarks, AppUserId = COALESCE(AppUserId, @AppUserId)`; audit `DowntimeEnded` (resolved `Location` + the duration in the narrative). Output `@Status, @Message`.
- [ ] **Step 2: Extend the test** — add to `010_*.sql` before teardown: start an event, End it, assert `Status=1` + `EndedAt IS NOT NULL`; then End it again, assert `Status=0` (already-closed reject).
- [ ] **Step 3: Run** that file → all PASS.
- [ ] **Step 4: Commit** — `git commit -am "feat(arc2-p8-sql): DowntimeEvent_End + close/already-closed tests"`

---

## Task 4: `Oee.DowntimeReasonCode_Assign` + test

**Files:** Create `R__Oee_DowntimeReasonCode_Assign.sql`; create `020_DowntimeReasonCode_Assign.sql`.

- [ ] **Step 1: Write the proc** — `@DowntimeEventId, @DowntimeReasonCodeId, @AppUserId, @TerminalLocationId`. Validate event open; **refuse if `DowntimeReasonCodeId IS NOT NULL` already (B7)** with message `'Reason already assigned; cannot overwrite.'`; else `UPDATE … SET DowntimeReasonCodeId=@DowntimeReasonCodeId`; audit `DowntimeReasonAssigned` (old NULL → new resolved `DowntimeReasonCode {Id,Code,Name}`). Output `@Status, @Message`.
- [ ] **Step 2: Test** — open a PLC-source event with NULL reason; assign → `Status=1` + reason set; assign again with a different code → `Status=0` (B7 overwrite reject) + reason unchanged.
- [ ] **Step 3: Run → PASS. Step 4: Commit** — `git commit -am "feat(arc2-p8-sql): DowntimeReasonCode_Assign (B7 late-binding) + test"`

---

## Task 5: `Oee.EndOfShiftEntry_Submit` + test

**Files:** Create `R__Oee_EndOfShiftEntry_Submit.sql`; create `050_EndOfShiftEntry_Submit.sql`.

- [ ] **Step 1: Write the proc** — `@ShiftId BIGINT, @CellLocationId BIGINT, @BreaksSelectedJson NVARCHAR(MAX), @AppUserId BIGINT, @TerminalLocationId BIGINT`.
  Logic: validate the shift exists + is open (`ActualEnd IS NULL`); parse `@BreaksSelectedJson` (array of DowntimeReasonCode Ids) via `OPENJSON`; for each selected break code, insert a **closed** `DowntimeEvent` — `StartedAt = (shift ActualStart)`, `EndedAt = DATEADD(MINUTE, rc.StandardDurationMinutes, ActualStart)`, `DowntimeReasonCodeId = code`, `ShiftId=@ShiftId`, `LocationId=@CellLocationId`, `DowntimeSourceCodeId = Manual`, `AppUserId=@AppUserId`. Zero selected (`@BreaksSelectedJson` empty/`'[]'`) = valid → insert nothing. Single audit `EndOfShiftSubmitted` with the inserted count in the narrative. Output `@Status, @Message, @EventCountInserted` (use `@NewId` slot renamed — return as `EventCountInserted`).
  Guard: a break code with NULL `StandardDurationMinutes` is rejected (`'Break code <Code> has no standard duration configured.'`).
- [ ] **Step 2: Test** — create a shift via `Oee.Shift_Start`; submit `'[<lunchId>,<break1Id>]'` → `Status=1`, `EventCountInserted=2`, two closed DowntimeEvent rows with durations 30 + 15; submit `'[]'` → `Status=1`, count 0, no rows; submit against a closed shift → `Status=0`.
- [ ] **Step 3: Run → PASS. Step 4: Commit** — `git commit -am "feat(arc2-p8-sql): EndOfShiftEntry_Submit (fixed-duration break rows) + test"`

---

## Task 6: Summary reads + test

**Files:** Create `R__Oee_DowntimeEvent_GetOpenByLocation.sql`, `R__Oee_Lot_GetInProcessByLocation.sql`; create `060_ShiftEndSummary_reads.sql`.

- [ ] **Step 1: `DowntimeEvent_GetOpenByLocation`** (read; mirror `LotPause_GetByLocation`) — `@LocationId`. Returns open events at the Cell subtree: `DowntimeEventId, LocationId, LocationCode, DowntimeReasonCodeId, ReasonCode, StartedAtEt, AppUserId`. Apply ET: `StartedAt AT TIME ZONE 'UTC' AT TIME ZONE 'Eastern Standard Time' AS StartedAtEt` (OI-36). Scope: `WHERE EndedAt IS NULL AND LocationId IN (subtree of @LocationId)` — use the existing location-subtree pattern (verify helper; otherwise `LocationId = @LocationId` for MVP + note).
- [ ] **Step 2: `Lot_GetInProcessByLocation`** (read) — `@LocationId`. Latest-movement-per-LOT into the Cell, joined to `Lots.v_LotDerivedQuantities`: `LotId, LotName, ItemCode, InProcessPieceCount, MovedAtEt`. Uses the `LotMovement (ToLocationId, MovedAt DESC)` index.
- [ ] **Step 3: Test** — seed an open downtime + an in-process LOT at a Cell; assert each read returns the expected row(s); assert `StartedAtEt`/`MovedAtEt` differ from UTC by the ET offset. (Open pauses reuse the tested `LotPause_GetByLocation`.)
- [ ] **Step 4: Commit** — `git commit -am "feat(arc2-p8-sql): shift-end summary reads (open downtime + in-process LOT, ET) + test"`

---

## Task 7: Remaining test files + full suite gate

**Files:** Create `030_DowntimeEvent_PLC_pattern.sql`, `040_DowntimeEvent_warmup_shotcount.sql`, `070_OpenEvents_span_boundary.sql`, `080_audit_shape.sql`.

- [ ] **Step 1: `030`** — start with `DowntimeSourceCode=PLC`, NULL reason, `AppUserId=NULL`; assert row has PLC source + NULL reason + NULL user; then assign reason later (Task 4 proc).
- [ ] **Step 2: `040`** — start a Setup-type downtime with `@ShotCount=12`; assert `ShotCount=12` persisted (UJ-14).
- [ ] **Step 3: `070`** — open a downtime event; call `Oee.Shift_End`; assert the open `DowntimeEvent` row is untouched (`EndedAt` still NULL) — UJ-10/OI-03.
- [ ] **Step 4: `080`** — after a Start + an EndOfShift submit, assert the `Audit.OperationLog.Description` contains the mid-dot (`NCHAR(183)`) and the `NewValue` JSON has a resolved `Location` object with `Id`/`Code`/`Name` (convention shape).
- [ ] **Step 5: Full gate** — `.\Reset-DevDatabase.ps1; .\sql\tests\Run-Tests.ps1`. Expected: existing suite count + the new `0026_*` assertions, **all green**.
- [ ] **Step 6: Commit** — `git commit -am "test(arc2-p8): PLC/warmup/boundary/audit-shape + full suite green"`

---

## Task 8: Entity script `BlueRidge.Oee.DowntimeEvent` (Core)

**Files:** Create `ignition/projects/Core/ignition/script-python/BlueRidge/Oee/DowntimeEvent/code.py` + `resource.json`.

- [ ] **Step 1: Write `code.py`** (mirror `BlueRidge/Lots/LotPause/code.py` — `Common.Db` + `Common.Util`):

```python
"""BlueRidge.Oee.DowntimeEvent - downtime lifecycle + end-of-shift entry + shift-end summary."""
import BlueRidge.Common.Db
import BlueRidge.Common.Util
import system.util


def start(locationId, downtimeSourceCodeId, downtimeReasonCodeId=None, shotCount=None, appUserId=None, terminalLocationId=None):
    if appUserId is None:
        appUserId = BlueRidge.Common.Util._currentAppUserId()
    params = {"locationId": locationId, "downtimeReasonCodeId": downtimeReasonCodeId,
              "downtimeSourceCodeId": downtimeSourceCodeId, "shotCount": shotCount,
              "appUserId": appUserId, "terminalLocationId": terminalLocationId}
    return BlueRidge.Common.Db.execMutation("oee/DowntimeEvent_Start", params)


def end(downtimeEventId, remarks=None, appUserId=None, terminalLocationId=None):
    if appUserId is None:
        appUserId = BlueRidge.Common.Util._currentAppUserId()
    params = {"downtimeEventId": downtimeEventId, "remarks": remarks,
              "appUserId": appUserId, "terminalLocationId": terminalLocationId}
    return BlueRidge.Common.Db.execMutation("oee/DowntimeEvent_End", params)


def assignReason(downtimeEventId, downtimeReasonCodeId, appUserId=None, terminalLocationId=None):
    if appUserId is None:
        appUserId = BlueRidge.Common.Util._currentAppUserId()
    params = {"downtimeEventId": downtimeEventId, "downtimeReasonCodeId": downtimeReasonCodeId,
              "appUserId": appUserId, "terminalLocationId": terminalLocationId}
    return BlueRidge.Common.Db.execMutation("oee/DowntimeReasonCode_Assign", params)


def getOpenByLocation(locationId):
    return BlueRidge.Common.Db.execList("oee/DowntimeEvent_GetOpenByLocation", {"locationId": locationId})


def submitEndOfShift(shiftId, cellLocationId, breaksSelectedJson, appUserId=None, terminalLocationId=None):
    if appUserId is None:
        appUserId = BlueRidge.Common.Util._currentAppUserId()
    params = {"shiftId": shiftId, "cellLocationId": cellLocationId,
              "breaksSelectedJson": breaksSelectedJson, "appUserId": appUserId,
              "terminalLocationId": terminalLocationId}
    return BlueRidge.Common.Db.execMutation("oee/EndOfShiftEntry_Submit", params)


def getEndOfShiftSummary(cellLocationId):
    """Bundle the three lists for the Shift-end Summary view."""
    return {
        "openDowntime": BlueRidge.Common.Db.execList("oee/DowntimeEvent_GetOpenByLocation", {"locationId": cellLocationId}),
        "openPauses":   BlueRidge.Common.Db.execList("lots/LotPause_GetByLocation", {"locationId": cellLocationId}),
        "inProcessLots":BlueRidge.Common.Db.execList("oee/Lot_GetInProcessByLocation", {"locationId": cellLocationId}),
    }
```

- [ ] **Step 2: `resource.json`** — copy `BlueRidge/Lots/LotPause/resource.json` (script module manifest).
- [ ] **Step 3: Scan + sanity** — `.\scan.ps1`; in Designer Script Console: `BlueRidge.Oee.DowntimeEvent.getOpenByLocation(<cellId>)` returns a list.
- [ ] **Step 4: Commit** — `git commit -am "feat(arc2-p8-ignition): BlueRidge.Oee.DowntimeEvent entity script (Core)"`

---

## Task 9: Named Queries (Core)

**Files:** Six NQ folders under `ignition/projects/Core/ignition/named-query/oee/` — each `query.sql` (thin `EXEC`, named `:params`) + `resource.json` (copy `oee/Shift_Start/resource.json`; set `type: "Query"`, `database: "MPP"`, `scope: "DG"`; sqlType per param — BIGINT=3, NVARCHAR=7, INT=2, datetime=8).

- [ ] **Step 1:** `DowntimeEvent_Start` (params: locationId 3, downtimeReasonCodeId 3, downtimeSourceCodeId 3, shotCount 2, appUserId 3, terminalLocationId 3).
- [ ] **Step 2:** `DowntimeEvent_End` (downtimeEventId 3, remarks 7, appUserId 3, terminalLocationId 3).
- [ ] **Step 3:** `DowntimeReasonCode_Assign` (downtimeEventId 3, downtimeReasonCodeId 3, appUserId 3, terminalLocationId 3).
- [ ] **Step 4:** `EndOfShiftEntry_Submit` (shiftId 3, cellLocationId 3, breaksSelectedJson 7, appUserId 3, terminalLocationId 3).
- [ ] **Step 5:** `DowntimeEvent_GetOpenByLocation` (locationId 3).
- [ ] **Step 6:** `Lot_GetInProcessByLocation` (locationId 3).
- [ ] **Step 7: Scan + commit** — `.\scan.ps1`; `git commit -am "feat(arc2-p8-ignition): oee Named Queries (Core)"`

---

## Task 10: Downtime Entry view (MPP)

**Files:** Create `ignition/projects/MPP/.../views/BlueRidge/Views/ShopFloor/DowntimeEntry/` (+ `Components/PlantFloor/DowntimeEntry/EventRow/`). **Mirror** the structure of an existing plant-floor operator view (`MPP/.../Views/ShopFloor/DieCastEntry/`) and the Downtime Codes list/repeater pattern (`MPP_Config/.../Views/Oee/DowntimeCodes`).

- [ ] **Step 1:** Build the view: header (terminal Cell context) + an open-events flex-repeater (`EventRow` sub-view: machine, source, reason-or-`Assign`, `StartedAt` ET, `End` button) bound via `runScript("BlueRidge.Oee.DowntimeEvent.getOpenByLocation", 0, {cellId})`; a Start-new form (machine scoped, optional reason area-filtered per FDS-09-005, `ShotCount` visible only when reason type = Setup via `position.display`). Row sub-view fires page-scoped messages (`feedback_ignition_embed_params_input_only`); End/Assign call the entity script. Mutation buttons `scope: "G"`.
- [ ] **Step 2:** Conventions: flex-repeater row is a **sibling** sub-view (not nested under the view); `useDefaultViewHeight:true` + pixel basis; no BOM in `view.json`.
- [ ] **Step 3: Commit** — `git commit -am "feat(arc2-p8-ignition): Downtime Entry view (MPP)"`

---

## Task 11: End-of-Shift Time Entry view (MPP)

**Files:** Create `…/Views/ShopFloor/EndOfShiftEntry/`. Mirror `DieCastEntry` + reuse `Components/PlantFloor/InitialsField`.

- [ ] **Step 1:** One toggle button per break code (read break codes: `Oee.DowntimeReasonCode` where type=Break — add a thin `BlueRidge.Oee.DowntimeReasonCode.getBreaks()` if not present, or reuse the existing list filtered client-side). Track selected ids in `view.custom.selected` (list). Dedicated flavor: tap + Submit (operator from `BlueRidge.Location.Terminal` presence). Shared flavor: `InitialsField` → AppUser before Submit. Submit → `BlueRidge.Oee.DowntimeEvent.submitEndOfShift(shiftId, cellId, system.util.jsonEncode(selected), appUserId)`; on success route to Shift-end Summary.
- [ ] **Step 2:** Visibility gated by the window flag from `EndOfShiftWindowTrigger` (Task 14).
- [ ] **Step 3: Commit** — `git commit -am "feat(arc2-p8-ignition): End-of-Shift Time Entry view (MPP)"`

---

## Task 12: Shift-end Summary view (MPP)

**Files:** Create `…/Views/ShopFloor/ShiftEndSummary/` (+ three row sub-views or reuse `LotDetail/PauseRow`).

- [ ] **Step 1:** Three read-only flex-repeaters bound to `BlueRidge.Oee.DowntimeEvent.getEndOfShiftSummary(cellId)` keys (`openDowntime`, `openPauses`, `inProcessLots`). Acknowledge button → writes `ShiftHandoverAcknowledged` (add a tiny `Oee.ShiftHandover_Acknowledge` proc + NQ, OR call `Audit.Audit_LogOperation` via a small mutation proc — prefer a proc for the FDS-11-001 contract). Read-only; optional/skippable.
- [ ] **Step 2: Commit** — `git commit -am "feat(arc2-p8-ignition): Shift-end Summary view (MPP)"`

> Note: Task 12 Step 1 needs a `ShiftHandover_Acknowledge` audit-only proc + NQ + entity method — add them here (mirror `LotPause_Place`'s audit-only tail; emits `ShiftHandoverAcknowledged`, returns `@Status, @Message`).

---

## Task 13: Supervisor Dashboard view (MPP)

**Files:** Create `…/Views/ShopFloor/SupervisorDashboard/` (+ tile sub-views).

- [ ] **Step 1:** Native tiles: **DowntimeOpenSummary** (open events with reason/no-reason split — add `Oee.DowntimeEvent_GetOpenSummaryByArea` read proc + NQ), **PausedLotsSummary** (reuse `LotPause_GetCountsByLocation`), **ShiftAvailabilityTile** (derived: `(scheduledEnd-scheduledStart) - Σ downtime` per OI-03 — add `Oee.Shift_GetAvailability` read proc + NQ). Stub tiles: **AimPoolWallboardTile**, **PrintFailureStrandedTile** — static "Phase 7" placeholder components.
- [ ] **Step 2: Commit** — `git commit -am "feat(arc2-p8-ignition): Supervisor Dashboard (native tiles + Phase-7 stubs) (MPP)"`

---

## Task 14: Gateway scripts (MPP)

**Files:** Create `ignition/projects/MPP/ignition/timer/DowntimePlcWatcher/` (handleTimerEvent.py + resource.json — mirror `MPP/ignition/timer/ShiftBoundaryTicker/`). `EndOfShiftWindowTrigger` is **view-side** (a timer/expression on the End-of-Shift view, not a gateway timer).

- [ ] **Step 1: `DowntimePlcWatcher`** — per configured machine, read the stop/run tag (simulated tag set defined here: a memory tag `[default]Sim/<machine>/Stopped` BIT per Cell). On rising stop edge → `BlueRidge.Oee.DowntimeEvent.start(cellId, PLC_sourceId, appUserId=None)`; on falling edge → resolve the open event (`getOpenByLocation`) and `end(...)`. Edge state held in a gateway-scoped dict.
- [ ] **Step 2: Simulator verification** — toggle the sim tag; assert a PLC-source DowntimeEvent opens then closes (`SELECT … FROM Oee.DowntimeEvent WHERE DowntimeSourceCodeId = PLC`).
- [ ] **Step 3: `EndOfShiftWindowTrigger`** — on the End-of-Shift view, an expression binding on `now(1000)` vs the active shift's scheduled end resolves a `view.custom.inWindow` bool (−15 to +15 min); the entry control's `position.display` binds to it.
- [ ] **Step 4: Commit** — `git commit -am "feat(arc2-p8-ignition): DowntimePlcWatcher (sim) + EndOfShift window trigger (MPP)"`

---

## Task 15: Routes + HomeRouter tiles (MPP)

**Files:** Modify `ignition/projects/MPP/com.inductiveautomation.perspective/page-config/config.json`.

- [ ] **Step 1:** Add four routes (mirror existing shop-floor route entries): `/shop-floor/downtime`, `/shop-floor/end-of-shift`, `/shop-floor/shift-summary`, `/shop-floor/supervisor` → the four views. Add HomeRouter tiles if the home page enumerates shop-floor screens.
- [ ] **Step 2: Verify** — no BOM written to `config.json` (`feedback_powershell_bom_writes`); `.\scan.ps1`.
- [ ] **Step 3: Commit** — `git commit -am "feat(arc2-p8-ignition): Phase 8 routes + home tiles (MPP)"`

---

## Task 16: Designer smoke + close-out

- [ ] **Step 1:** Restart the gateway (new MPP/Core junctions). In a Perspective session walk: Downtime Entry (start → open row → assign reason → End); End-of-Shift (toggle breaks → Submit → break rows written with durations) — exercise both dedicated + shared flavor; Shift-end Summary (three lists + acknowledge writes audit); Supervisor Dashboard (native tiles render, Phase-7 tiles show placeholder); PLC sim (toggle tag → event opens/closes); `/audit` shows readable narratives.
- [ ] **Step 2:** Raise the OIR item for the FDS-09-013 break-model divergence (spec §9); update `PROJECT_STATUS.md` Phase 8 entry + Build Status test count.
- [ ] **Step 3: Final commit** — `git commit -am "docs(arc2-p8): Phase 8 smoke notes + OIR divergence item + status update"`

---

## Phase 8 complete when
- [ ] Migration `0026` applied; `DowntimeEvent` + delta + seeds in place; full SQL suite green.
- [ ] Four entry/mutation procs + three summary reads (+ `ShiftHandover_Acknowledge`, dashboard reads) delivered to convention.
- [ ] Entity script + NQs scanned clean; four views routed; PLC watcher sim-verified; window trigger works.
- [ ] End-to-end Designer smoke passes (Step 1 above).
- [ ] `Audit.OperationLog` carries readable narrative + resolved-FK JSON for every mutation.
- [ ] FDS-09-013 divergence recorded in the OIR.
