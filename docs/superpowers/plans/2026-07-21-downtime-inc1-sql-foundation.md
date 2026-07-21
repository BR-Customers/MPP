# Downtime Increment 1 — SQL Foundation — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the SQL foundation for terminal-scoped, fully-audited downtime CRUD: a scope resolver, a schema change for soft-void, a scope+shift read, and four new audited mutations, plus their named queries and Python wrappers.

**Architecture:** One versioned migration (`0043`) adds void columns + audit event-type seeds + the scalar resolver function. Repeatable procs add the read and mutations, following the existing `Oee.DowntimeEvent_*` patterns and the stored-proc template. Core named queries + a Python module expose them. No UI in this increment.

**Tech Stack:** SQL Server 2022, `sqlcmd`, Ignition named queries + Jython wrappers, `scan.ps1`.

## Global Constraints

- Follow `sql/scripts/_TEMPLATE_stored_procedure.sql`: three-tier error hierarchy, `RAISERROR` (not `THROW`) in CATCH, schema-qualify everything, `EXEC` params are literals/`@vars` only.
- **No OUTPUT params (FDS-11-011).** Mutations end every path with `SELECT @Status AS Status, @Message AS Message[, @NewId AS NewId];`. Reads = one result set; empty = none.
- **Timestamps stored UTC (`SYSUTCDATETIME()`), displayed/entered ET.** Read: `CAST(<col> AT TIME ZONE 'UTC' AT TIME ZONE 'Eastern Standard Time' AS DATETIME2(3))`. Write from ET input: `CAST(@Et AT TIME ZONE 'Eastern Standard Time' AT TIME ZONE 'UTC' AS DATETIME2(3))`.
- **Every mutation audits to `Audit.OperationLog`** via `Audit.Audit_LogOperation` (success) / `Audit.Audit_LogFailure` (rejects + CATCH), with resolved-name Old/New JSON and `Audit.ufn_TruncateActivity` + `Audit.ufn_MidDot()`. LogEntityType code = `DowntimeEvent`.
- **A proc captured by INSERT-EXEC must not EXEC another status-row proc**; all rejects run BEFORE `BEGIN TRANSACTION` (ROLLBACK only in CATCH) — Msg 3915 rule.
- ASCII-only in seed strings. Migrations idempotent + `GO`-separated; record in `dbo.SchemaVersion`.
- Named queries live in **Core** (`ignition/projects/Core/ignition/named-query/oee/`); status-row mutation NQs need `attributes.type: "Query"`.
- Test on `MPP_MES_Dev` via `sqlcmd -S localhost -d MPP_MES_Dev -E -C`. Commit to `jacques/working`, explicit paths.

## Reference (read before starting)
- `sql/migrations/versioned/0026_arc2_phase8_downtime_shift.sql` (DowntimeEvent table + audit-seed idiom)
- `sql/migrations/repeatable/R__Oee_DowntimeEvent_Start.sql`, `_End.sql`, `R__Oee_DowntimeReasonCode_Assign.sql` (proc patterns, audit calls)
- `sql/migrations/repeatable/R__Oee_DowntimeEvent_GetOpenByLocation.sql` (read shape, ET conversion)
- `sql/migrations/repeatable/R__Lots_Lot_GetWipQueueByLocation.sql` lines 37-40, 87 (Descendants CTE)

`Oee.DowntimeEvent` today: `Id, LocationId, DowntimeReasonCodeId(NULL), ShiftId(NULL), StartedAt, EndedAt(NULL), DowntimeSourceCodeId, AppUserId(NULL), ShotCount(NULL), Remarks(NULL), CreatedAt`. Filtered-unique `UX_DowntimeEvent_OneOpenPerLocation (LocationId) WHERE EndedAt IS NULL`.

---

## Task 1: Migration 0043 — void columns, audit seeds, scope resolver

**Files:** Create `sql/migrations/versioned/0043_downtime_void_scope_resolver.sql`

**Interfaces — Produces:** columns `Oee.DowntimeEvent.VoidedAt/VoidedByUserId/VoidReason`; `Oee.ufn_ResolveDowntimeScope(@CellLocationId)→BIGINT`; `Audit.LogEventType` 67-70.

- [ ] **Step 1: Write the migration**

```sql
-- 0043_downtime_void_scope_resolver.sql — Downtime CRUD foundation.
IF COL_LENGTH(N'Oee.DowntimeEvent', N'VoidedAt') IS NULL
    ALTER TABLE Oee.DowntimeEvent ADD
        VoidedAt        DATETIME2(3)  NULL,
        VoidedByUserId  BIGINT        NULL CONSTRAINT FK_DowntimeEvent_VoidedBy REFERENCES Location.AppUser(Id),
        VoidReason      NVARCHAR(500) NULL;
GO

IF NOT EXISTS (SELECT 1 FROM Audit.LogEventType WHERE Id = 67 OR Code = N'DowntimeReasonChanged')
    INSERT INTO Audit.LogEventType (Id, Code, Name, Description) VALUES
        (67, N'DowntimeReasonChanged', N'Downtime Reason Changed', N'A downtime event reason was changed (manager edit).');
GO
IF NOT EXISTS (SELECT 1 FROM Audit.LogEventType WHERE Id = 68 OR Code = N'DowntimeTimesEdited')
    INSERT INTO Audit.LogEventType (Id, Code, Name, Description) VALUES
        (68, N'DowntimeTimesEdited', N'Downtime Times Edited', N'A downtime event start/end time was retroactively corrected.');
GO
IF NOT EXISTS (SELECT 1 FROM Audit.LogEventType WHERE Id = 69 OR Code = N'DowntimeRecordedHistorical')
    INSERT INTO Audit.LogEventType (Id, Code, Name, Description) VALUES
        (69, N'DowntimeRecordedHistorical', N'Downtime Recorded (Historical)', N'A fully-past downtime event was entered after the fact.');
GO
IF NOT EXISTS (SELECT 1 FROM Audit.LogEventType WHERE Id = 70 OR Code = N'DowntimeVoided')
    INSERT INTO Audit.LogEventType (Id, Code, Name, Description) VALUES
        (70, N'DowntimeVoided', N'Downtime Voided', N'A downtime event was soft-voided.');
GO

CREATE OR ALTER FUNCTION Oee.ufn_ResolveDowntimeScope (@CellLocationId BIGINT)
RETURNS BIGINT
AS
BEGIN
    -- Downtime "unit": if the cell's parent is a WorkCenter (a production line),
    -- downtime is logged against that line; otherwise (die-cast press directly under
    -- an Area) against the cell itself. NULL in -> NULL out (caller handles fallback).
    IF @CellLocationId IS NULL RETURN NULL;
    DECLARE @ParentId BIGINT, @ParentType NVARCHAR(30);
    SELECT @ParentId = p.Id, @ParentType = lt.Code
    FROM Location.Location c
    INNER JOIN Location.Location p                 ON p.Id = c.ParentLocationId
    INNER JOIN Location.LocationTypeDefinition ltd ON ltd.Id = p.LocationTypeDefinitionId
    INNER JOIN Location.LocationType lt            ON lt.Id = ltd.LocationTypeId
    WHERE c.Id = @CellLocationId;
    RETURN CASE WHEN @ParentType = N'WorkCenter' THEN @ParentId ELSE @CellLocationId END;
END
GO

IF NOT EXISTS (SELECT 1 FROM dbo.SchemaVersion WHERE MigrationId = N'0043_downtime_void_scope_resolver')
    INSERT INTO dbo.SchemaVersion (MigrationId, Description)
    VALUES (N'0043_downtime_void_scope_resolver', N'Downtime CRUD: void columns + audit event-types 67-70 + Oee.ufn_ResolveDowntimeScope.');
GO
PRINT 'Migration 0043 applied.';
GO
```

- [ ] **Step 2: Apply + verify the resolver on real data**

Run:
```
sqlcmd -S localhost -d MPP_MES_Dev -E -C -i sql/migrations/versioned/0043_downtime_void_scope_resolver.sql
sqlcmd -S localhost -d MPP_MES_Dev -E -C -W -Q "SELECT Oee.ufn_ResolveDowntimeScope(76) AS MachIn_Scope; SELECT c.Code, lt.Code AS ParentType FROM Location.Location c JOIN Location.Location p ON p.Id=c.ParentLocationId JOIN Location.LocationTypeDefinition ltd ON ltd.Id=p.LocationTypeDefinitionId JOIN Location.LocationType lt ON lt.Id=ltd.LocationTypeId WHERE c.Id=76;"
```
Expected: `MachIn_Scope` = the parent line id of cell 76 (parent type `WorkCenter`); the second query shows cell 76's parent is a `WorkCenter`. (If cell 76's parent is NOT a WorkCenter in seed data, note the actual scope returned — the function is still correct; pick a genuine M&A cell + a die-cast press for Step-through.)

- [ ] **Step 3: Verify columns + audit seeds**

Run: `sqlcmd ... -Q "SELECT COL_LENGTH('Oee.DowntimeEvent','VoidedAt') AS VoidedAt; SELECT Id,Code FROM Audit.LogEventType WHERE Id BETWEEN 67 AND 70;"`
Expected: non-null `VoidedAt`; 4 rows 67-70.

- [ ] **Step 4: Commit**
```bash
git add sql/migrations/versioned/0043_downtime_void_scope_resolver.sql
git commit -m "feat(oee): migration 0043 - downtime void columns, audit event-types, scope resolver fn"
```

---

## Task 2: `Oee.DowntimeEvent_GetByScope` (read)

**Files:** Create `sql/migrations/repeatable/R__Oee_DowntimeEvent_GetByScope.sql`

**Interfaces — Consumes:** `ufn_ResolveDowntimeScope` (caller passes an already-resolved `@ScopeLocationId`). **Produces:** result set with columns listed below (consumed by Task 7 NQ + Increment 3).

- [ ] **Step 1: Write the proc**

```sql
CREATE OR ALTER PROCEDURE Oee.DowntimeEvent_GetByScope
    @ScopeLocationId    BIGINT,
    @IncludeDescendants BIT    = 1,
    @ShiftId            BIGINT = NULL   -- NULL => current open shift (if any)
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Shift BIGINT = @ShiftId;
    IF @Shift IS NULL
        SELECT TOP 1 @Shift = Id FROM Oee.Shift WHERE ActualEnd IS NULL ORDER BY ActualStart DESC;

    ;WITH Scope AS (
        SELECT @ScopeLocationId AS Id
        UNION ALL
        SELECT c.Id FROM Location.Location c INNER JOIN Scope s ON c.ParentLocationId = s.Id
        WHERE @IncludeDescendants = 1
    )
    SELECT de.Id                    AS DowntimeEventId,
           de.LocationId            AS LocationId,
           loc.Code                 AS LocationCode,
           @ScopeLocationId         AS ScopeLocationId,
           de.DowntimeReasonCodeId  AS DowntimeReasonCodeId,
           rc.Code                  AS ReasonCode,
           rc.Description           AS ReasonDescription,
           src.Code                 AS SourceCode,
           CAST(de.StartedAt AT TIME ZONE 'UTC' AT TIME ZONE 'Eastern Standard Time' AS DATETIME2(3)) AS StartedAtEt,
           CAST(de.EndedAt   AT TIME ZONE 'UTC' AT TIME ZONE 'Eastern Standard Time' AS DATETIME2(3)) AS EndedAtEt,
           CASE WHEN de.EndedAt IS NULL THEN NULL ELSE DATEDIFF(MINUTE, de.StartedAt, de.EndedAt) END AS DurationMinutes,
           de.Remarks               AS Remarks,
           de.AppUserId             AS AppUserId,
           u.Initials               AS OperatorInitials,
           CAST(CASE WHEN de.EndedAt IS NULL THEN 1 ELSE 0 END AS BIT) AS IsOpen,
           CAST(CASE WHEN de.VoidedAt IS NULL THEN 0 ELSE 1 END AS BIT) AS IsVoided,
           de.VoidReason            AS VoidReason
    FROM Oee.DowntimeEvent de
    INNER JOIN Location.Location loc      ON loc.Id = de.LocationId
    INNER JOIN Oee.DowntimeSourceCode src ON src.Id = de.DowntimeSourceCodeId
    LEFT  JOIN Oee.DowntimeReasonCode rc  ON rc.Id  = de.DowntimeReasonCodeId
    LEFT  JOIN Location.AppUser u         ON u.Id   = de.AppUserId
    WHERE de.LocationId IN (SELECT Id FROM Scope)
      AND (@Shift IS NULL OR de.ShiftId = @Shift)
    ORDER BY de.StartedAt DESC, de.Id DESC
    OPTION (MAXRECURSION 8);
END;
GO
```
(Note: `AppUser` column for initials is `Initials` — verify against `Location.AppUser`; if the column differs, use the actual name. Newest-first so recent events show on top in the popup.)

- [ ] **Step 2: Apply + smoke-test against the Task-1 test data**

Run: `sqlcmd ... -i sql/migrations/repeatable/R__Oee_DowntimeEvent_GetByScope.sql`
Then (using the closed event 10 created earlier at loc 76, or create one): `sqlcmd ... -W -Q "EXEC Oee.DowntimeEvent_GetByScope @ScopeLocationId=<line-id-from-Task1>, @IncludeDescendants=1, @ShiftId=NULL;"`
Expected: returns event(s) under the line incl. the descendant cell 76, ET timestamps, `IsOpen/IsVoided` flags. Empty set if none in the current shift — pass `@ShiftId=NULL` and confirm no error.

- [ ] **Step 3: Commit**
```bash
git add sql/migrations/repeatable/R__Oee_DowntimeEvent_GetByScope.sql
git commit -m "feat(oee): DowntimeEvent_GetByScope - scope+descendants+shift read (open/closed/voided)"
```

---

## Task 3: `Oee.DowntimeEvent_UpdateReason` (change reason, audited)

**Files:** Create `sql/migrations/repeatable/R__Oee_DowntimeEvent_UpdateReason.sql`

**Interfaces — Produces:** `SELECT @Status, @Message`.

- [ ] **Step 1: Write the proc** (mirror `R__Oee_DowntimeReasonCode_Assign.sql` structure, but ALLOW overwrite; audit `DowntimeReasonChanged`).

```sql
CREATE OR ALTER PROCEDURE Oee.DowntimeEvent_UpdateReason
    @DowntimeEventId      BIGINT,
    @DowntimeReasonCodeId BIGINT,          -- NULL clears the reason
    @AppUserId            BIGINT,
    @TerminalLocationId   BIGINT = NULL
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;
    DECLARE @Status BIT = 0, @Message NVARCHAR(500) = N'Unknown error';
    DECLARE @ProcName NVARCHAR(200) = N'Oee.DowntimeEvent_UpdateReason';
    DECLARE @Params NVARCHAR(MAX) = (SELECT @DowntimeEventId AS DowntimeEventId, @DowntimeReasonCodeId AS DowntimeReasonCodeId FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);
    DECLARE @LocationId BIGINT, @LocCode NVARCHAR(50), @OldReasonId BIGINT, @VoidedAt DATETIME2(3);

    BEGIN TRY
        IF @DowntimeEventId IS NULL OR @AppUserId IS NULL
        BEGIN SET @Message=N'Required parameter missing.'; SELECT @Status AS Status,@Message AS Message; RETURN; END

        SELECT @LocationId=de.LocationId, @OldReasonId=de.DowntimeReasonCodeId, @VoidedAt=de.VoidedAt
        FROM Oee.DowntimeEvent de WHERE de.Id=@DowntimeEventId;

        IF @LocationId IS NULL
        BEGIN SET @Message=N'Downtime event not found.';
            EXEC Audit.Audit_LogFailure @AppUserId=@AppUserId,@LogEntityTypeCode=N'DowntimeEvent',@EntityId=@DowntimeEventId,@LogEventTypeCode=N'DowntimeReasonChanged',@FailureReason=@Message,@ProcedureName=@ProcName,@AttemptedParameters=@Params;
            SELECT @Status AS Status,@Message AS Message; RETURN; END
        IF @VoidedAt IS NOT NULL
        BEGIN SET @Message=N'Cannot edit a voided event.';
            EXEC Audit.Audit_LogFailure @AppUserId=@AppUserId,@LogEntityTypeCode=N'DowntimeEvent',@EntityId=@DowntimeEventId,@LogEventTypeCode=N'DowntimeReasonChanged',@FailureReason=@Message,@ProcedureName=@ProcName,@AttemptedParameters=@Params;
            SELECT @Status AS Status,@Message AS Message; RETURN; END
        IF @DowntimeReasonCodeId IS NOT NULL AND NOT EXISTS (SELECT 1 FROM Oee.DowntimeReasonCode WHERE Id=@DowntimeReasonCodeId AND DeprecatedAt IS NULL)
        BEGIN SET @Message=N'Reason code not found or deprecated.';
            EXEC Audit.Audit_LogFailure @AppUserId=@AppUserId,@LogEntityTypeCode=N'DowntimeEvent',@EntityId=@DowntimeEventId,@LogEventTypeCode=N'DowntimeReasonChanged',@FailureReason=@Message,@ProcedureName=@ProcName,@AttemptedParameters=@Params;
            SELECT @Status AS Status,@Message AS Message; RETURN; END

        SELECT @LocCode=Code FROM Location.Location WHERE Id=@LocationId;
        DECLARE @Activity NVARCHAR(500) = Audit.ufn_TruncateActivity(@LocCode + N' ' + Audit.ufn_MidDot() + N' Downtime ' + Audit.ufn_MidDot() + N' Reason changed');
        DECLARE @OldValue NVARCHAR(MAX) = (SELECT JSON_QUERY((SELECT rc.Id,rc.Code,rc.Description AS Name FROM Oee.DowntimeReasonCode rc WHERE rc.Id=@OldReasonId FOR JSON PATH,WITHOUT_ARRAY_WRAPPER)) AS DowntimeReasonCode FOR JSON PATH,WITHOUT_ARRAY_WRAPPER);
        DECLARE @NewValue NVARCHAR(MAX) = (SELECT JSON_QUERY((SELECT rc.Id,rc.Code,rc.Description AS Name FROM Oee.DowntimeReasonCode rc WHERE rc.Id=@DowntimeReasonCodeId FOR JSON PATH,WITHOUT_ARRAY_WRAPPER)) AS DowntimeReasonCode FOR JSON PATH,WITHOUT_ARRAY_WRAPPER);

        BEGIN TRANSACTION;
        UPDATE Oee.DowntimeEvent SET DowntimeReasonCodeId=@DowntimeReasonCodeId WHERE Id=@DowntimeEventId;
        EXEC Audit.Audit_LogOperation @AppUserId=@AppUserId,@TerminalLocationId=@TerminalLocationId,@LocationId=@LocationId,@LogEntityTypeCode=N'DowntimeEvent',@EntityId=@DowntimeEventId,@LogEventTypeCode=N'DowntimeReasonChanged',@LogSeverityCode=N'Info',@Description=@Activity,@OldValue=@OldValue,@NewValue=@NewValue;
        COMMIT TRANSACTION;
        SET @Status=1; SET @Message=N'Reason updated.'; SELECT @Status AS Status,@Message AS Message;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT>0 ROLLBACK TRANSACTION;
        DECLARE @ErrMsg NVARCHAR(4000)=ERROR_MESSAGE(),@ErrSev INT=ERROR_SEVERITY(),@ErrState INT=ERROR_STATE();
        SET @Status=0; SET @Message=N'Unexpected error: '+LEFT(@ErrMsg,400);
        BEGIN TRY EXEC Audit.Audit_LogFailure @AppUserId=@AppUserId,@LogEntityTypeCode=N'DowntimeEvent',@EntityId=@DowntimeEventId,@LogEventTypeCode=N'DowntimeReasonChanged',@FailureReason=@Message,@ProcedureName=@ProcName,@AttemptedParameters=@Params; END TRY BEGIN CATCH END CATCH
        SELECT @Status AS Status,@Message AS Message; RAISERROR(@ErrMsg,@ErrSev,@ErrState);
    END CATCH
END;
GO
```

- [ ] **Step 2: Apply + test** — open an event, change its reason, assert Status=1 + row updated + an `Audit.OperationLog` row with event-type `DowntimeReasonChanged`.
```
sqlcmd ... -i sql/migrations/repeatable/R__Oee_DowntimeEvent_UpdateReason.sql
sqlcmd ... -W -Q "SET NOCOUNT ON; EXEC Oee.DowntimeEvent_Start @LocationId=<line>,@AppUserId=1; DECLARE @id BIGINT=SCOPE_IDENTITY(); EXEC Oee.DowntimeEvent_UpdateReason @DowntimeEventId=@id,@DowntimeReasonCodeId=8,@AppUserId=1; SELECT DowntimeReasonCodeId FROM Oee.DowntimeEvent WHERE Id=@id; EXEC Oee.DowntimeEvent_End @DowntimeEventId=@id,@AppUserId=1;"
```
Expected: `Status=1`, reason = 8.

- [ ] **Step 3: Commit**
```bash
git add sql/migrations/repeatable/R__Oee_DowntimeEvent_UpdateReason.sql
git commit -m "feat(oee): DowntimeEvent_UpdateReason - change reason (audited)"
```

---

## Task 4: `Oee.DowntimeEvent_UpdateTimes` (retroactive time correction)

**Files:** Create `sql/migrations/repeatable/R__Oee_DowntimeEvent_UpdateTimes.sql`

**Interfaces — Consumes:** ET inputs. **Produces:** `SELECT @Status,@Message`.

- [ ] **Step 1: Write the proc** — same skeleton as Task 3. Params `@DowntimeEventId, @StartedAtEt DATETIME2(3), @EndedAtEt DATETIME2(3) = NULL, @Remarks NVARCHAR(500) = NULL, @AppUserId, @TerminalLocationId=NULL`. (The `@StartedAtEt/@EndedAtEt` values arrive as **ET wall-clock strings** `'yyyy-MM-dd HH:mm:ss'` from the NQ (sqlType String) and coerce to `DATETIME2` as literal wall-clock — no tz — before the `AT TIME ZONE` conversion; this avoids the date-picker tz trap. `@Remarks` lets the editor save times + remarks in one call.) Validations (before txn): event exists; not voided; `@StartedAtEt` not null; if `@EndedAtEt` not null then `@EndedAtEt > @StartedAtEt`. Convert ET→UTC:
```sql
DECLARE @StartUtc DATETIME2(3) = CAST(@StartedAtEt AT TIME ZONE 'Eastern Standard Time' AT TIME ZONE 'UTC' AS DATETIME2(3));
DECLARE @EndUtc   DATETIME2(3) = CASE WHEN @EndedAtEt IS NULL THEN NULL ELSE CAST(@EndedAtEt AT TIME ZONE 'Eastern Standard Time' AT TIME ZONE 'UTC' AS DATETIME2(3)) END;
```
Old/New JSON = the ET start/end before and after (use `CONVERT(NVARCHAR(30), <utc> AT TIME ZONE 'UTC' AT TIME ZONE 'Eastern Standard Time', 126)`). `UPDATE Oee.DowntimeEvent SET StartedAt=@StartUtc, EndedAt=@EndUtc, Remarks=COALESCE(@Remarks, Remarks) WHERE Id=@DowntimeEventId;`. Audit `DowntimeTimesEdited`. **Guard the one-open invariant:** if setting `@EndUtc` NULL (reopening) would create a second open event at the same LocationId, reject before txn.

- [ ] **Step 2: Apply + test** — start→end an event, then UpdateTimes to shift StartedAt back 30 min; assert Status=1 and `DATEDIFF` reflects the new duration; assert an `Audit.OperationLog` `DowntimeTimesEdited` row. Also assert reject on `@EndedAtEt < @StartedAtEt`.

- [ ] **Step 3: Commit**
```bash
git add sql/migrations/repeatable/R__Oee_DowntimeEvent_UpdateTimes.sql
git commit -m "feat(oee): DowntimeEvent_UpdateTimes - retroactive ET time correction (audited)"
```

---

## Task 5: `Oee.DowntimeEvent_RecordHistorical` (past event)

**Files:** Create `sql/migrations/repeatable/R__Oee_DowntimeEvent_RecordHistorical.sql`

**Interfaces — Produces:** `SELECT @Status,@Message,@NewId`.

- [ ] **Step 1: Write the proc** — params `@ScopeLocationId, @StartedAtEt, @EndedAtEt, @DowntimeReasonCodeId=NULL, @Remarks=NULL, @AppUserId, @TerminalLocationId=NULL`. Validations (before txn): location exists + not deprecated; both times present; `@EndedAtEt > @StartedAtEt`; reason (if given) valid. Convert ET→UTC (as Task 4). Resolve `@SourceId = (SELECT Id FROM Oee.DowntimeSourceCode WHERE Code=N'Operator')`. Stamp the shift covering the start: `@ShiftId = (SELECT TOP 1 Id FROM Oee.Shift WHERE ActualStart <= @StartUtc AND (ActualEnd IS NULL OR ActualEnd >= @StartUtc) ORDER BY ActualStart DESC)`. INSERT a **closed** event (`StartedAt=@StartUtc, EndedAt=@EndUtc, DowntimeSourceCodeId=@SourceId, ...`). `SET @NewId=SCOPE_IDENTITY();`. Audit `DowntimeRecordedHistorical` (New = resolved location + reason + ET times). Note: the one-open filtered-unique index does not fire (EndedAt not null).

- [ ] **Step 2: Apply + test** — record a past event (yesterday 08:00–08:20 ET) at the line; assert Status=1, NewId, EndedAt not null, ShiftId stamped (or NULL if no covering shift), and audit row.

- [ ] **Step 3: Commit**
```bash
git add sql/migrations/repeatable/R__Oee_DowntimeEvent_RecordHistorical.sql
git commit -m "feat(oee): DowntimeEvent_RecordHistorical - enter a fully-past event (audited)"
```

---

## Task 6: `Oee.DowntimeEvent_Void` (soft void)

**Files:** Create `sql/migrations/repeatable/R__Oee_DowntimeEvent_Void.sql`

**Interfaces — Produces:** `SELECT @Status,@Message`.

- [ ] **Step 1: Write the proc** — params `@DowntimeEventId, @VoidReason NVARCHAR(500)=NULL, @AppUserId, @TerminalLocationId=NULL`. Validations (before txn): event exists; `VoidedAt IS NULL` (reject double-void). `UPDATE ... SET VoidedAt=SYSUTCDATETIME(), VoidedByUserId=@AppUserId, VoidReason=@VoidReason`. Audit `DowntimeVoided` (`@LogSeverityCode=N'Warning'`, Old `{"VoidedAt":null}`, New = reason). **Design note:** voiding an *open* event also closes it — set `EndedAt=SYSUTCDATETIME()` when `EndedAt IS NULL` so it frees the one-open-per-location slot.

- [ ] **Step 2: Apply + test** — void an event; assert Status=1, `VoidedAt` set, `IsVoided=1` in `GetByScope`, double-void rejected, audit `DowntimeVoided` row.

- [ ] **Step 3: Commit**
```bash
git add sql/migrations/repeatable/R__Oee_DowntimeEvent_Void.sql
git commit -m "feat(oee): DowntimeEvent_Void - soft void (audited)"
```

---

## Task 7: Named queries + Python wrappers

**Files:**
- Create Core NQs `oee/DowntimeEvent_GetByScope`, `_UpdateReason`, `_UpdateTimes`, `_RecordHistorical`, `_Void` (+ `oee/ufn` not needed; resolver called inside a Get or via a tiny NQ `oee/ResolveDowntimeScope`). Each `query.sql` + `resource.json`.
- Create/extend `ignition/projects/Core/ignition/script-python/BlueRidge/Oee/Downtime/code.py` (new module; keep the existing `DowntimeEvent` module for Start/End/Assign).

**Interfaces — Produces:** Python `resolveScope`, `getByScope`, `updateReason`, `updateTimes`, `recordHistorical`, `void` (consumed by Increment 3).

- [ ] **Step 1: Write `oee/ResolveDowntimeScope` NQ** — `query.sql`: `SELECT Oee.ufn_ResolveDowntimeScope(:cellLocationId) AS ScopeLocationId` ; resource.json param `cellLocationId` sqlType 3, `type: "Query"`.

- [ ] **Step 2: Write the 5 event NQs** — mirror the shape of `oee/ShiftSchedule_Create/resource.json`. Params (sqlType: BIGINT=3, String=7, DateTime=8, BIT=6):
  - `DowntimeEvent_GetByScope`: `scopeLocationId`(3), `includeDescendants`(6), `shiftId`(3).
  - `_UpdateReason`: `downtimeEventId`(3), `downtimeReasonCodeId`(3), `appUserId`(3), `terminalLocationId`(3).
  - `_UpdateTimes`: `downtimeEventId`(3), `startedAtEt`(**7**, `'yyyy-MM-dd HH:mm:ss'` ET string), `endedAtEt`(**7**), `remarks`(7), `appUserId`(3), `terminalLocationId`(3).
  - `_RecordHistorical`: `scopeLocationId`(3), `startedAtEt`(**7** ET string), `endedAtEt`(**7**), `downtimeReasonCodeId`(3), `remarks`(7), `appUserId`(3), `terminalLocationId`(3).
  (ET datetimes are strings — sqlType 7 — so the picker's `java.util.Date` is formatted to a wall-clock string in Python before the proc's `AT TIME ZONE` conversion; avoids the tz trap.)
  - `_Void`: `downtimeEventId`(3), `voidReason`(7), `appUserId`(3), `terminalLocationId`(3).
  Each `query.sql` is `EXEC Oee.<Proc> @X = :x, ...`. All status-row procs → `type: "Query"`.

- [ ] **Step 3: Write `BlueRidge/Oee/Downtime/code.py`**
```python
"""BlueRidge.Oee.Downtime - terminal-scoped downtime CRUD wrappers (Increment 1)."""
import BlueRidge.Common.Db, BlueRidge.Common.Util
def _u(v): return BlueRidge.Common.Util.extractQualifiedValues(v)
def _uid(): return BlueRidge.Common.Util._currentAppUserId()

def resolveScope(cellLocationId):
    if cellLocationId is None: return None
    row = BlueRidge.Common.Db.execOne("oee/ResolveDowntimeScope", {"cellLocationId": _u(cellLocationId)})
    return row.get("ScopeLocationId") if row else None

def getByScope(scopeLocationId, includeDescendants=True, shiftId=None):
    return BlueRidge.Common.Db.execList("oee/DowntimeEvent_GetByScope",
        {"scopeLocationId": _u(scopeLocationId), "includeDescendants": bool(includeDescendants), "shiftId": _u(shiftId)})

def updateReason(downtimeEventId, downtimeReasonCodeId, terminalLocationId=None):
    return BlueRidge.Common.Db.execMutation("oee/DowntimeEvent_UpdateReason",
        {"downtimeEventId": _u(downtimeEventId), "downtimeReasonCodeId": _u(downtimeReasonCodeId), "appUserId": _uid(), "terminalLocationId": _u(terminalLocationId)})

def updateTimes(downtimeEventId, startedAtEt, endedAtEt=None, remarks=None, terminalLocationId=None):
    return BlueRidge.Common.Db.execMutation("oee/DowntimeEvent_UpdateTimes",
        {"downtimeEventId": _u(downtimeEventId), "startedAtEt": _u(startedAtEt), "endedAtEt": _u(endedAtEt), "remarks": _u(remarks), "appUserId": _uid(), "terminalLocationId": _u(terminalLocationId)})

def recordHistorical(scopeLocationId, startedAtEt, endedAtEt, downtimeReasonCodeId=None, remarks=None, terminalLocationId=None):
    return BlueRidge.Common.Db.execMutation("oee/DowntimeEvent_RecordHistorical",
        {"scopeLocationId": _u(scopeLocationId), "startedAtEt": _u(startedAtEt), "endedAtEt": _u(endedAtEt), "downtimeReasonCodeId": _u(downtimeReasonCodeId), "remarks": _u(remarks), "appUserId": _uid(), "terminalLocationId": _u(terminalLocationId)})

def void(downtimeEventId, voidReason=None, terminalLocationId=None):
    return BlueRidge.Common.Db.execMutation("oee/DowntimeEvent_Void",
        {"downtimeEventId": _u(downtimeEventId), "voidReason": _u(voidReason), "appUserId": _uid(), "terminalLocationId": _u(terminalLocationId)})
```
+ `resource.json` mirroring `BlueRidge/Oee/DowntimeEvent/resource.json`.

- [ ] **Step 4: Scan + verify** — `.\scan.ps1`; confirm the 6 NQs load (no "Named query not found") and `code.py` compiles (AST-parse + gateway log clean).

- [ ] **Step 5: Commit**
```bash
git add ignition/projects/Core/ignition/named-query/oee/DowntimeEvent_GetByScope ignition/projects/Core/ignition/named-query/oee/DowntimeEvent_UpdateReason ignition/projects/Core/ignition/named-query/oee/DowntimeEvent_UpdateTimes ignition/projects/Core/ignition/named-query/oee/DowntimeEvent_RecordHistorical ignition/projects/Core/ignition/named-query/oee/DowntimeEvent_Void ignition/projects/Core/ignition/named-query/oee/ResolveDowntimeScope ignition/projects/Core/ignition/script-python/BlueRidge/Oee/Downtime
git commit -m "feat(oee): named queries + python wrappers for downtime scope resolve + CRUD"
```

---

## Self-Review
- Scope resolver (Task 1), read (Task 2), UpdateReason (Task 3), UpdateTimes (Task 4), RecordHistorical (Task 5), Void (Task 6), NQ+Python (Task 7) — every spec §2 item covered. ✅
- Void columns + audit seeds + resolver in the migration; `IsVoided` surfaced in the read; every mutation audits Old/New. ✅
- No placeholders: full SQL for Task 1-3; Tasks 4-6 give exact params/validations/conversions + the one-open guard, modeled on the Task-3 skeleton (repeated structure, not "similar to"). Verify two data-dependent names during build: `Location.AppUser.Initials` and cell-76 parent type.
- Type consistency: NQ params ↔ proc params ↔ Python keys aligned; `getByScope` output keys consumed by Increment 3.
