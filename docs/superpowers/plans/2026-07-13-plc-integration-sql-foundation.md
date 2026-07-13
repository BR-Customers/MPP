# PLC Integration — SQL Foundation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the SQL layer that lets a terminal declare which PLC device(s) it drives and lets the MES resolve/validate the line-local PLC part-codes and PLC-reported serial numbers.

**Architecture:** One versioned migration (`0037`) adds a `Location.PlcDeviceType` code table (4 seeded UDT types), a `Location.TerminalPlcDevice` 1-to-many mapping table (terminal → device instances), and a `Parts.ItemLocation.PlcPartCode` column. Repeatable stored procs provide CRUD over the mapping, resolve/validate the PLC part-code both directions, and extend `SerializedPart_Mint` to accept a PLC-reported serial (plus a `_GetBySerial` lookup). All procs follow the mandated status-row contract (no OUTPUT params) and the readable-audit convention.

**Tech Stack:** SQL Server 2022, T-SQL. Migrations under `sql/migrations/`, tests under `sql/tests/`, run via `sql/tests/Run-Tests.ps1` (PowerShell). This is the design spec's SQL scope: `docs/superpowers/specs/2026-07-10-plc-udt-terminal-mapping-design.md` §4 + §5 (serial surface).

## Global Constraints

- **No OUTPUT parameters** anywhere (FDS-11-011 / Ignition JDBC). Mutation procs declare `@Status BIT`, `@Message NVARCHAR(500)`, and (Create/Add only) `@NewId BIGINT` as **locals**; every exit path ends with `SELECT @Status AS Status, @Message AS Message[, @NewId AS NewId];`. Read procs take no status params and emit no status row (empty result = not found).
- **`RAISERROR` (not `THROW`)** in CATCH blocks, after emitting the status-row SELECT; nested TRY/CATCH around the failure-log write.
- **Success audit inside the transaction** (`Audit.Audit_LogConfigChange`); **failure audit outside** the rolled-back transaction (`Audit.Audit_LogFailure`).
- **Audit Description** shape `<SUBJECT> · <CATEGORY?> · <ACTION>` using `Audit.ufn_MidDot()` separator + `Audit.ufn_TruncateActivity()` 500-char cap; `OldValue`/`NewValue` JSON carry resolved-FK sub-objects.
- **Naming:** `Schema.Entity_Verb`; repeatable proc file `R__Schema_Entity_Verb.sql` in `sql/migrations/repeatable/`.
- **Types:** `BIGINT IDENTITY` surrogate `Id` PKs; `BIGINT` FKs; `NVARCHAR` (never `VARCHAR`); `DATETIME2(3)`; `SYSUTCDATETIME()` for stored timestamps. Every mutating proc takes `@AppUserId BIGINT`.
- **ASCII-only** string literals in seed/migration data (em-dash/middle-dot become mojibake through `sqlcmd`); the middle-dot in audit prose comes from `Audit.ufn_MidDot()` at runtime, never a literal.
- **Migration idempotency:** guard object creation (`IF OBJECT_ID(...) IS NULL`, `IF NOT EXISTS`), end with the `dbo.SchemaVersion` insert.
- **Run tests:** `cd sql/tests; ./Run-Tests.ps1 -Filter "<name>"` (filtered) or `./Run-Tests.ps1` (full). Pass = final summary `Failed: 0` / `Test run PASSED.`

---

## File Structure

**Created:**
- `sql/migrations/versioned/0037_plc_integration_foundation.sql` — `PlcDeviceType` (+seed), `TerminalPlcDevice`, `ItemLocation.PlcPartCode`, `LogEntityType` seed row, SchemaVersion.
- `sql/migrations/repeatable/R__Location_TerminalPlcDevice_Save.sql`
- `sql/migrations/repeatable/R__Location_TerminalPlcDevice_GetByTerminal.sql`
- `sql/migrations/repeatable/R__Location_TerminalPlcDevice_Deprecate.sql`
- `sql/migrations/repeatable/R__Parts_ItemLocation_SetPlcPartCode.sql`
- `sql/migrations/repeatable/R__Parts_ItemLocation_GetByPlcPartCode.sql`
- `sql/migrations/repeatable/R__Parts_ItemLocation_GetPlcPartCode.sql`
- `sql/migrations/repeatable/R__Lots_SerializedPart_GetBySerial.sql`
- `sql/tests/0037_PlcIntegration/010_schema.sql`
- `sql/tests/0037_PlcIntegration/020_TerminalPlcDevice_crud.sql`
- `sql/tests/0037_PlcIntegration/030_ItemLocation_PlcPartCode.sql`
- `sql/tests/0037_PlcIntegration/040_SerializedPart_serial.sql`

**Modified:**
- `sql/migrations/repeatable/R__Lots_SerializedPart_Mint.sql` — add optional `@SerialNumber` param.

---

## Reference conventions (verbatim, for the implementer)

**Proc template** (`sql/scripts/_TEMPLATE_stored_procedure.sql`) and **reference audit proc** (`sql/migrations/repeatable/R__Location_LocationAttribute_Set.sql`) — copy their structure exactly: `SET NOCOUNT ON; SET XACT_ABORT ON;` → locals → `@ProcName`/`@Params` (FOR JSON PATH, WITHOUT_ARRAY_WRAPPER) → `BEGIN TRY` (param validation → business rules, each failure does `Audit.Audit_LogFailure` + status SELECT + `RETURN`) → `BEGIN TRANSACTION` → mutate + `Audit.Audit_LogConfigChange` → `COMMIT` → status SELECT → `END TRY BEGIN CATCH` (rollback, capture `ERROR_MESSAGE/SEVERITY/STATE`, nested-try failure log, status SELECT, `RAISERROR`).

**Audit signatures:**
```sql
EXEC Audit.Audit_LogConfigChange
    @AppUserId=@AppUserId, @LogEntityTypeCode=N'...', @EntityId=@Id,
    @LogEventTypeCode=N'Created'|N'Updated'|N'Deprecated', @LogSeverityCode=N'Info',
    @Description=@Activity, @OldValue=@OldJson, @NewValue=@NewJson;

EXEC Audit.Audit_LogFailure
    @AppUserId=@AppUserId, @LogEntityTypeCode=N'...', @EntityId=NULL,
    @LogEventTypeCode=N'Created', @FailureReason=@Message,
    @ProcedureName=@ProcName, @AttemptedParameters=@Params;
```
`@LogEntityTypeCode` values used here: `N'TerminalPlcDevice'` (new, Id 25), `N'ItemLocation'` (existing 19), `N'SerializedPart'` (existing 24). `@LogEventTypeCode` values `Created`/`Updated`/`Deprecated` already seeded.

**Test pattern** (`sql/tests/0003_Location/010_Location_crud.sql`): each file opens with `EXEC test.BeginTestFile @FileName=N'...';` then per test — `CREATE TABLE #R (Status BIT, Message NVARCHAR(500), NewId BIGINT); INSERT INTO #R EXEC <proc> ...; SELECT @S=Status,... FROM #R; DROP TABLE #R;` then `EXEC test.Assert_IsEqual @TestName=N'...', @Expected=N'...', @Actual=<nvarchar>;`. Each `GO`-separated batch re-declares its locals. Cleanup deletes test rows bottom-up (FK-safe). End with `EXEC test.PrintSummary;`. Assertion procs: `test.Assert_IsEqual`, `test.Assert_IsTrue`, `test.Assert_IsNull`, `test.Assert_IsNotNull`, `test.Assert_RowCount`, `test.Assert_Contains`.

---

### Task 1: Migration 0037 — schema + seed

**Files:**
- Create: `sql/migrations/versioned/0037_plc_integration_foundation.sql`
- Test: `sql/tests/0037_PlcIntegration/010_schema.sql`

**Interfaces:**
- Produces: table `Location.PlcDeviceType(Id, Code, Name, Description, CreatedAt, DeprecatedAt)` seeded 4 rows (`ScaleStation`, `SerializedMipStation`, `NonSerializedMipStation`, `TrayInspectionStation`); table `Location.TerminalPlcDevice` (columns per DDL below); column `Parts.ItemLocation.PlcPartCode INT NULL`; `Audit.LogEntityType` row `(25, N'TerminalPlcDevice', ...)`.

- [ ] **Step 1: Write the failing test** — `sql/tests/0037_PlcIntegration/010_schema.sql`

```sql
-- =============================================
-- File: 0037_PlcIntegration/010_schema.sql
-- Asserts migration 0037 objects exist + PlcDeviceType seed is correct.
-- =============================================
EXEC test.BeginTestFile @FileName = N'0037_PlcIntegration/010_schema.sql';
GO

-- PlcDeviceType table + 4-row seed
DECLARE @cnt INT = (SELECT COUNT(*) FROM Location.PlcDeviceType WHERE DeprecatedAt IS NULL);
EXEC test.Assert_IsEqual @TestName=N'PlcDeviceType seeded 4 active rows',
    @Expected=N'4', @Actual=CAST(@cnt AS NVARCHAR(10));

DECLARE @hasTray NVARCHAR(1) = CASE WHEN EXISTS
    (SELECT 1 FROM Location.PlcDeviceType WHERE Code=N'TrayInspectionStation') THEN N'1' ELSE N'0' END;
EXEC test.Assert_IsEqual @TestName=N'PlcDeviceType has TrayInspectionStation',
    @Expected=N'1', @Actual=@hasTray;
GO

-- TerminalPlcDevice table + key columns
DECLARE @colOk NVARCHAR(1) = CASE WHEN
    COL_LENGTH('Location.TerminalPlcDevice','OpcServerConnection') IS NOT NULL
    AND COL_LENGTH('Location.TerminalPlcDevice','DeviceName') IS NOT NULL
    AND COL_LENGTH('Location.TerminalPlcDevice','BasePath') IS NOT NULL
    AND COL_LENGTH('Location.TerminalPlcDevice','WriteDisplayEnabled') IS NOT NULL
    THEN N'1' ELSE N'0' END;
EXEC test.Assert_IsEqual @TestName=N'TerminalPlcDevice has expected columns',
    @Expected=N'1', @Actual=@colOk;
GO

-- ItemLocation.PlcPartCode column
DECLARE @plcCol NVARCHAR(1) = CASE WHEN
    COL_LENGTH('Parts.ItemLocation','PlcPartCode') IS NOT NULL THEN N'1' ELSE N'0' END;
EXEC test.Assert_IsEqual @TestName=N'ItemLocation has PlcPartCode column',
    @Expected=N'1', @Actual=@plcCol;
GO

-- Audit entity type seeded
DECLARE @auditOk NVARCHAR(1) = CASE WHEN EXISTS
    (SELECT 1 FROM Audit.LogEntityType WHERE Code=N'TerminalPlcDevice') THEN N'1' ELSE N'0' END;
EXEC test.Assert_IsEqual @TestName=N'LogEntityType TerminalPlcDevice seeded',
    @Expected=N'1', @Actual=@auditOk;
GO

EXEC test.PrintSummary;
GO
```

- [ ] **Step 2: Run to verify it fails**

Run: `cd sql/tests; ./Run-Tests.ps1 -Filter "0037"`
Expected: FAIL — `Invalid object name 'Location.PlcDeviceType'` (migration not yet created).

- [ ] **Step 3: Write the migration** — `sql/migrations/versioned/0037_plc_integration_foundation.sql`

```sql
-- =============================================
-- Migration:   0037_plc_integration_foundation.sql
-- Author:      Blue Ridge Automation
-- Date:        2026-07-13
-- Description: PLC-integration SQL foundation (spec 2026-07-10 §4).
--              * Location.PlcDeviceType  - 4 UDT device types (fixed seed).
--              * Location.TerminalPlcDevice - 1-to-many terminal -> PLC device
--                mapping; the 3 OPC columns feed the UDT {OpcServer}/{Device}/
--                {BasePath} params; WriteDisplayEnabled gates HMI-display writes.
--              * Parts.ItemLocation.PlcPartCode - line-local integer part-code
--                (PLC/vision type-code <-> Item, per line).
--              * Audit.LogEntityType += TerminalPlcDevice (Id 25).
--              Idempotent-guarded; no explicit transaction (repo convention).
-- =============================================

IF OBJECT_ID(N'Location.PlcDeviceType') IS NULL
CREATE TABLE Location.PlcDeviceType (
    Id           BIGINT IDENTITY(1,1) NOT NULL CONSTRAINT PK_PlcDeviceType PRIMARY KEY,
    Code         NVARCHAR(50)  NOT NULL CONSTRAINT UQ_PlcDeviceType_Code UNIQUE,
    Name         NVARCHAR(100) NOT NULL,
    Description  NVARCHAR(500) NULL,
    CreatedAt    DATETIME2(3)  NOT NULL CONSTRAINT DF_PlcDeviceType_CreatedAt DEFAULT SYSUTCDATETIME(),
    DeprecatedAt DATETIME2(3)  NULL
);
GO

IF NOT EXISTS (SELECT 1 FROM Location.PlcDeviceType)
INSERT INTO Location.PlcDeviceType (Code, Name, Description) VALUES
    (N'ScaleStation',           N'Scale Station',            N'OmniServer weight indicator (NET_/TRG_ members)'),
    (N'SerializedMipStation',   N'Serialized MIP Station',   N'Serialized assembly MIP handshake (5G0 - PartSN, container)'),
    (N'NonSerializedMipStation',N'Non-Serialized MIP Station',N'LOT-tracked MIP handshake (5A2 - DataReady, no serial)'),
    (N'TrayInspectionStation',  N'Tray Inspection Station',  N'Tray lock/inspection (disposition/vision/sort variants)');
GO

IF OBJECT_ID(N'Location.TerminalPlcDevice') IS NULL
CREATE TABLE Location.TerminalPlcDevice (
    Id                  BIGINT IDENTITY(1,1) NOT NULL CONSTRAINT PK_TerminalPlcDevice PRIMARY KEY,
    TerminalLocationId  BIGINT        NOT NULL CONSTRAINT FK_TerminalPlcDevice_Terminal   REFERENCES Location.Location(Id),
    PlcDeviceTypeId     BIGINT        NOT NULL CONSTRAINT FK_TerminalPlcDevice_DeviceType REFERENCES Location.PlcDeviceType(Id),
    DeviceCode          NVARCHAR(100) NOT NULL,
    OpcServerConnection NVARCHAR(200) NOT NULL CONSTRAINT DF_TerminalPlcDevice_OpcServer DEFAULT N'Ignition OPC UA Server',
    DeviceName          NVARCHAR(200) NOT NULL,
    BasePath            NVARCHAR(400) NOT NULL CONSTRAINT DF_TerminalPlcDevice_BasePath DEFAULT N'',
    IsSimulated         BIT           NOT NULL CONSTRAINT DF_TerminalPlcDevice_IsSim DEFAULT 0,
    WriteDisplayEnabled BIT           NOT NULL CONSTRAINT DF_TerminalPlcDevice_WriteDisp DEFAULT 0,
    SortOrder           INT           NOT NULL CONSTRAINT DF_TerminalPlcDevice_SortOrder DEFAULT 0,
    CreatedAt           DATETIME2(3)  NOT NULL CONSTRAINT DF_TerminalPlcDevice_CreatedAt DEFAULT SYSUTCDATETIME(),
    UpdatedAt           DATETIME2(3)  NULL,
    UpdatedByUserId     BIGINT        NULL CONSTRAINT FK_TerminalPlcDevice_User REFERENCES Location.AppUser(Id),
    DeprecatedAt        DATETIME2(3)  NULL
);
GO

IF OBJECT_ID(N'Location.TerminalPlcDevice') IS NOT NULL
   AND NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'UQ_TerminalPlcDevice_ActiveDeviceCode')
CREATE UNIQUE INDEX UQ_TerminalPlcDevice_ActiveDeviceCode
    ON Location.TerminalPlcDevice (TerminalLocationId, DeviceCode)
    WHERE DeprecatedAt IS NULL;
GO

IF OBJECT_ID(N'Location.TerminalPlcDevice') IS NOT NULL
   AND NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_TerminalPlcDevice_Terminal')
CREATE INDEX IX_TerminalPlcDevice_Terminal
    ON Location.TerminalPlcDevice (TerminalLocationId);
GO

IF COL_LENGTH(N'Parts.ItemLocation', N'PlcPartCode') IS NULL
    ALTER TABLE Parts.ItemLocation ADD PlcPartCode INT NULL;
GO

IF OBJECT_ID(N'Parts.ItemLocation') IS NOT NULL
   AND NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'UQ_ItemLocation_PlcPartCode')
CREATE UNIQUE INDEX UQ_ItemLocation_PlcPartCode
    ON Parts.ItemLocation (LocationId, PlcPartCode)
    WHERE PlcPartCode IS NOT NULL AND DeprecatedAt IS NULL;
GO

IF NOT EXISTS (SELECT 1 FROM Audit.LogEntityType WHERE Code = N'TerminalPlcDevice')
INSERT INTO Audit.LogEntityType (Id, Code, Name, Description) VALUES
    (25, N'TerminalPlcDevice', N'Terminal PLC Device', N'Terminal-to-PLC-device mapping row');
GO

IF NOT EXISTS (SELECT 1 FROM dbo.SchemaVersion WHERE MigrationId = N'0037_plc_integration_foundation')
    INSERT INTO dbo.SchemaVersion (MigrationId, Description)
    VALUES (N'0037_plc_integration_foundation',
        N'PLC integration foundation: PlcDeviceType (+seed), TerminalPlcDevice, ItemLocation.PlcPartCode, TerminalPlcDevice audit entity.');
GO
```

- [ ] **Step 4: Run to verify it passes**

Run: `cd sql/tests; ./Run-Tests.ps1 -Filter "0037"`
Expected: PASS — `010_schema.sql` shows 5 passed, 0 failed. (`Run-Tests.ps1` resets the DB, applying 0037.)

- [ ] **Step 5: Commit**

```bash
git add sql/migrations/versioned/0037_plc_integration_foundation.sql sql/tests/0037_PlcIntegration/010_schema.sql
git commit -m "feat(plc): migration 0037 - PlcDeviceType, TerminalPlcDevice, ItemLocation.PlcPartCode"
```

---

### Task 2: `Location.TerminalPlcDevice_Save` (upsert) + `_GetByTerminal` (read)

**Files:**
- Create: `sql/migrations/repeatable/R__Location_TerminalPlcDevice_Save.sql`
- Create: `sql/migrations/repeatable/R__Location_TerminalPlcDevice_GetByTerminal.sql`
- Test: `sql/tests/0037_PlcIntegration/020_TerminalPlcDevice_crud.sql`

**Interfaces:**
- Consumes: `Location.PlcDeviceType`, `Location.TerminalPlcDevice`, `Location.Location` (Terminal = LocationTypeDefinitionId 7), `Audit.Audit_LogConfigChange`/`_LogFailure`.
- Produces:
  - `Location.TerminalPlcDevice_Save(@Id BIGINT=NULL, @TerminalLocationId BIGINT, @PlcDeviceTypeId BIGINT, @DeviceCode NVARCHAR(100), @OpcServerConnection NVARCHAR(200)=N'Ignition OPC UA Server', @DeviceName NVARCHAR(200), @BasePath NVARCHAR(400)=N'', @IsSimulated BIT=0, @WriteDisplayEnabled BIT=0, @SortOrder INT=NULL, @AppUserId BIGINT)` → status row `Status,Message,NewId`. `@Id` NULL = insert, non-null = update.
  - `Location.TerminalPlcDevice_GetByTerminal(@TerminalLocationId BIGINT)` → rows `Id, TerminalLocationId, PlcDeviceTypeId, DeviceTypeCode, DeviceTypeName, DeviceCode, OpcServerConnection, DeviceName, BasePath, IsSimulated, WriteDisplayEnabled, SortOrder` (active only, ordered by SortOrder).

- [ ] **Step 1: Write the failing test** — `sql/tests/0037_PlcIntegration/020_TerminalPlcDevice_crud.sql`

```sql
-- =============================================
-- File: 0037_PlcIntegration/020_TerminalPlcDevice_crud.sql
-- Tests TerminalPlcDevice_Save (insert/update), _GetByTerminal, _Deprecate.
-- Self-contained: creates a throwaway Terminal location, cleans up at the end.
-- =============================================
EXEC test.BeginTestFile @FileName = N'0037_PlcIntegration/020_TerminalPlcDevice_crud.sql';
GO

-- Fixture: a throwaway Terminal (LocationTypeDefinitionId 7) under the plant root.
DECLARE @rootId BIGINT = (SELECT TOP 1 Id FROM Location.Location WHERE DeprecatedAt IS NULL ORDER BY Id);
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'TEST-TPD-TERM')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code)
    VALUES (7, @rootId, N'Test TPD Terminal', N'TEST-TPD-TERM');
GO

-- Test 1: Insert a device mapping
DECLARE @S BIT, @M NVARCHAR(500), @NewId BIGINT;
DECLARE @termId BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'TEST-TPD-TERM');
DECLARE @typeId BIGINT = (SELECT Id FROM Location.PlcDeviceType WHERE Code = N'SerializedMipStation');

CREATE TABLE #R1 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #R1 EXEC Location.TerminalPlcDevice_Save
    @Id=NULL, @TerminalLocationId=@termId, @PlcDeviceTypeId=@typeId,
    @DeviceCode=N'5G0_A1', @OpcServerConnection=N'TopServer', @DeviceName=N'5G0_A1',
    @BasePath=N'5G0_A1.5G0_A1', @IsSimulated=0, @WriteDisplayEnabled=0, @AppUserId=1;
SELECT @S=Status, @M=Message, @NewId=NewId FROM #R1; DROP TABLE #R1;

EXEC test.Assert_IsEqual @TestName=N'Save insert: status 1', @Expected=N'1', @Actual=CAST(@S AS NVARCHAR(1));
EXEC test.Assert_IsEqual @TestName=N'Save insert: NewId returned', @Expected=N'1',
    @Actual=CASE WHEN @NewId IS NOT NULL THEN N'1' ELSE N'0' END;
EXEC test.Assert_IsEqual @TestName=N'Save insert: SortOrder auto = 1',
    @Expected=N'1', @Actual=CAST((SELECT SortOrder FROM Location.TerminalPlcDevice WHERE Id=@NewId) AS NVARCHAR(10));
GO

-- Test 2: Duplicate DeviceCode on same terminal is rejected
DECLARE @S BIT, @M NVARCHAR(500);
DECLARE @termId BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'TEST-TPD-TERM');
DECLARE @typeId BIGINT = (SELECT Id FROM Location.PlcDeviceType WHERE Code = N'SerializedMipStation');
CREATE TABLE #R2 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #R2 EXEC Location.TerminalPlcDevice_Save
    @Id=NULL, @TerminalLocationId=@termId, @PlcDeviceTypeId=@typeId,
    @DeviceCode=N'5G0_A1', @DeviceName=N'5G0_A1', @AppUserId=1;
SELECT @S=Status, @M=Message FROM #R2; DROP TABLE #R2;
EXEC test.Assert_IsEqual @TestName=N'Save dup DeviceCode: status 0', @Expected=N'0', @Actual=CAST(@S AS NVARCHAR(1));
EXEC test.Assert_Contains @TestName=N'Save dup DeviceCode: message mentions exists',
    @HaystackStr=@M, @NeedleStr=N'already';
GO

-- Test 3: Update existing row (swing sim -> real via @Id)
DECLARE @S BIT, @M NVARCHAR(500);
DECLARE @termId BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'TEST-TPD-TERM');
DECLARE @typeId BIGINT = (SELECT Id FROM Location.PlcDeviceType WHERE Code = N'SerializedMipStation');
DECLARE @rowId BIGINT = (SELECT Id FROM Location.TerminalPlcDevice WHERE DeviceCode=N'5G0_A1' AND TerminalLocationId=@termId);
CREATE TABLE #R3 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #R3 EXEC Location.TerminalPlcDevice_Save
    @Id=@rowId, @TerminalLocationId=@termId, @PlcDeviceTypeId=@typeId,
    @DeviceCode=N'5G0_A1', @OpcServerConnection=N'Ignition OPC UA Server',
    @DeviceName=N'MPP_Sim', @BasePath=N'5G0_A1', @IsSimulated=1, @AppUserId=1;
SELECT @S=Status, @M=Message FROM #R3; DROP TABLE #R3;
EXEC test.Assert_IsEqual @TestName=N'Save update: status 1', @Expected=N'1', @Actual=CAST(@S AS NVARCHAR(1));
EXEC test.Assert_IsEqual @TestName=N'Save update: DeviceName now MPP_Sim',
    @Expected=N'MPP_Sim', @Actual=(SELECT DeviceName FROM Location.TerminalPlcDevice WHERE Id=@rowId);
GO

-- Test 4: GetByTerminal returns the active row joined to type
DECLARE @termId BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'TEST-TPD-TERM');
CREATE TABLE #G (Id BIGINT, TerminalLocationId BIGINT, PlcDeviceTypeId BIGINT,
    DeviceTypeCode NVARCHAR(50), DeviceTypeName NVARCHAR(100), DeviceCode NVARCHAR(100),
    OpcServerConnection NVARCHAR(200), DeviceName NVARCHAR(200), BasePath NVARCHAR(400),
    IsSimulated BIT, WriteDisplayEnabled BIT, SortOrder INT);
INSERT INTO #G EXEC Location.TerminalPlcDevice_GetByTerminal @TerminalLocationId=@termId;
DECLARE @rc INT = (SELECT COUNT(*) FROM #G);
DECLARE @tc NVARCHAR(50) = (SELECT TOP 1 DeviceTypeCode FROM #G);
DROP TABLE #G;
EXEC test.Assert_IsEqual @TestName=N'GetByTerminal: 1 active row', @Expected=N'1', @Actual=CAST(@rc AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName=N'GetByTerminal: type code resolved',
    @Expected=N'SerializedMipStation', @Actual=@tc;
GO

-- Cleanup
DELETE FROM Location.TerminalPlcDevice WHERE TerminalLocationId IN
    (SELECT Id FROM Location.Location WHERE Code = N'TEST-TPD-TERM');
DELETE FROM Location.Location WHERE Code = N'TEST-TPD-TERM';
GO

EXEC test.PrintSummary;
GO
```

- [ ] **Step 2: Run to verify it fails**

Run: `cd sql/tests; ./Run-Tests.ps1 -Filter "0037"`
Expected: FAIL — `Could not find stored procedure 'Location.TerminalPlcDevice_Save'`.

- [ ] **Step 3: Write `R__Location_TerminalPlcDevice_Save.sql`**

```sql
-- =============================================
-- Procedure:   Location.TerminalPlcDevice_Save
-- Author:      Blue Ridge Automation
-- Version:     1.0
-- Description: Upsert a terminal->PLC-device mapping row. @Id NULL = insert,
--   non-null = update. Validates terminal exists + is a Terminal (DefId 7),
--   device type exists, DeviceCode unique among the terminal's active devices.
--   Auto-assigns SortOrder = MAX(active peers)+1 on insert.
-- Result set: Status BIT, Message NVARCHAR(500), NewId BIGINT.
-- =============================================
CREATE OR ALTER PROCEDURE Location.TerminalPlcDevice_Save
    @Id                  BIGINT        = NULL,
    @TerminalLocationId  BIGINT,
    @PlcDeviceTypeId     BIGINT,
    @DeviceCode          NVARCHAR(100),
    @OpcServerConnection NVARCHAR(200) = N'Ignition OPC UA Server',
    @DeviceName          NVARCHAR(200),
    @BasePath            NVARCHAR(400) = N'',
    @IsSimulated         BIT           = 0,
    @WriteDisplayEnabled BIT           = 0,
    @SortOrder           INT           = NULL,
    @AppUserId           BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Status  BIT           = 0;
    DECLARE @Message NVARCHAR(500) = N'Unknown error';
    DECLARE @NewId   BIGINT        = NULL;

    DECLARE @ProcName NVARCHAR(200) = N'Location.TerminalPlcDevice_Save';
    DECLARE @Params   NVARCHAR(MAX) =
        (SELECT @Id AS Id, @TerminalLocationId AS TerminalLocationId, @PlcDeviceTypeId AS PlcDeviceTypeId,
                @DeviceCode AS DeviceCode, @OpcServerConnection AS OpcServerConnection,
                @DeviceName AS DeviceName, @BasePath AS BasePath, @IsSimulated AS IsSimulated,
                @WriteDisplayEnabled AS WriteDisplayEnabled
         FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

    BEGIN TRY
        IF @TerminalLocationId IS NULL OR @PlcDeviceTypeId IS NULL OR @DeviceCode IS NULL
           OR @DeviceName IS NULL OR @AppUserId IS NULL
        BEGIN
            SET @Message = N'Required parameter missing.';
            EXEC Audit.Audit_LogFailure @AppUserId=@AppUserId, @LogEntityTypeCode=N'TerminalPlcDevice',
                @EntityId=NULL, @LogEventTypeCode=N'Created', @FailureReason=@Message,
                @ProcedureName=@ProcName, @AttemptedParameters=@Params;
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId; RETURN;
        END

        -- Terminal must exist, be active, and be a Terminal (LocationTypeDefinitionId 7)
        IF NOT EXISTS (SELECT 1 FROM Location.Location
                       WHERE Id=@TerminalLocationId AND DeprecatedAt IS NULL AND LocationTypeDefinitionId=7)
        BEGIN
            SET @Message = N'TerminalLocationId is not an active Terminal location.';
            EXEC Audit.Audit_LogFailure @AppUserId=@AppUserId, @LogEntityTypeCode=N'TerminalPlcDevice',
                @EntityId=NULL, @LogEventTypeCode=N'Created', @FailureReason=@Message,
                @ProcedureName=@ProcName, @AttemptedParameters=@Params;
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId; RETURN;
        END

        IF NOT EXISTS (SELECT 1 FROM Location.PlcDeviceType WHERE Id=@PlcDeviceTypeId AND DeprecatedAt IS NULL)
        BEGIN
            SET @Message = N'PlcDeviceTypeId not found or deprecated.';
            EXEC Audit.Audit_LogFailure @AppUserId=@AppUserId, @LogEntityTypeCode=N'TerminalPlcDevice',
                @EntityId=NULL, @LogEventTypeCode=N'Created', @FailureReason=@Message,
                @ProcedureName=@ProcName, @AttemptedParameters=@Params;
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId; RETURN;
        END

        -- DeviceCode unique among the terminal's active devices (excluding the row being updated)
        IF EXISTS (SELECT 1 FROM Location.TerminalPlcDevice
                   WHERE TerminalLocationId=@TerminalLocationId AND DeviceCode=@DeviceCode
                     AND DeprecatedAt IS NULL AND (@Id IS NULL OR Id <> @Id))
        BEGIN
            SET @Message = N'A device with this DeviceCode already exists on this terminal.';
            EXEC Audit.Audit_LogFailure @AppUserId=@AppUserId, @LogEntityTypeCode=N'TerminalPlcDevice',
                @EntityId=NULL, @LogEventTypeCode=N'Created', @FailureReason=@Message,
                @ProcedureName=@ProcName, @AttemptedParameters=@Params;
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId; RETURN;
        END

        DECLARE @Activity NVARCHAR(500) = Audit.ufn_TruncateActivity(
            N'Terminal device ' + @DeviceCode + N' ' + Audit.ufn_MidDot()
            + CASE WHEN @Id IS NULL THEN N' Created' ELSE N' Updated' END
            + N' (' + @DeviceName + N')');

        BEGIN TRANSACTION;

        IF @Id IS NULL
        BEGIN
            DECLARE @Next INT = COALESCE(@SortOrder,
                (SELECT ISNULL(MAX(SortOrder),0)+1 FROM Location.TerminalPlcDevice
                 WHERE TerminalLocationId=@TerminalLocationId AND DeprecatedAt IS NULL));

            INSERT INTO Location.TerminalPlcDevice
                (TerminalLocationId, PlcDeviceTypeId, DeviceCode, OpcServerConnection, DeviceName,
                 BasePath, IsSimulated, WriteDisplayEnabled, SortOrder, CreatedAt)
            VALUES
                (@TerminalLocationId, @PlcDeviceTypeId, @DeviceCode, @OpcServerConnection, @DeviceName,
                 @BasePath, @IsSimulated, @WriteDisplayEnabled, @Next, SYSUTCDATETIME());

            SET @NewId = CAST(SCOPE_IDENTITY() AS BIGINT);

            EXEC Audit.Audit_LogConfigChange @AppUserId=@AppUserId, @LogEntityTypeCode=N'TerminalPlcDevice',
                @EntityId=@NewId, @LogEventTypeCode=N'Created', @LogSeverityCode=N'Info',
                @Description=@Activity, @OldValue=NULL, @NewValue=@Params;

            SET @Message = N'Terminal device created.';
        END
        ELSE
        BEGIN
            IF NOT EXISTS (SELECT 1 FROM Location.TerminalPlcDevice WHERE Id=@Id AND DeprecatedAt IS NULL)
                RAISERROR(N'TerminalPlcDevice Id not found or deprecated.', 16, 1);

            UPDATE Location.TerminalPlcDevice
            SET PlcDeviceTypeId=@PlcDeviceTypeId, DeviceCode=@DeviceCode,
                OpcServerConnection=@OpcServerConnection, DeviceName=@DeviceName, BasePath=@BasePath,
                IsSimulated=@IsSimulated, WriteDisplayEnabled=@WriteDisplayEnabled,
                SortOrder=COALESCE(@SortOrder, SortOrder),
                UpdatedAt=SYSUTCDATETIME(), UpdatedByUserId=@AppUserId
            WHERE Id=@Id;

            SET @NewId = @Id;

            EXEC Audit.Audit_LogConfigChange @AppUserId=@AppUserId, @LogEntityTypeCode=N'TerminalPlcDevice',
                @EntityId=@Id, @LogEventTypeCode=N'Updated', @LogSeverityCode=N'Info',
                @Description=@Activity, @OldValue=NULL, @NewValue=@Params;

            SET @Message = N'Terminal device updated.';
        END

        COMMIT TRANSACTION;
        SET @Status = 1;
        SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        DECLARE @ErrMsg NVARCHAR(4000)=ERROR_MESSAGE(), @ErrSev INT=ERROR_SEVERITY(), @ErrState INT=ERROR_STATE();
        SET @Status=0; SET @Message=N'Unexpected error: ' + LEFT(@ErrMsg,400); SET @NewId=NULL;
        BEGIN TRY
            EXEC Audit.Audit_LogFailure @AppUserId=@AppUserId, @LogEntityTypeCode=N'TerminalPlcDevice',
                @EntityId=NULL, @LogEventTypeCode=N'Created', @FailureReason=@Message,
                @ProcedureName=@ProcName, @AttemptedParameters=@Params;
        END TRY BEGIN CATCH END CATCH
        SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
        RAISERROR(@ErrMsg, @ErrSev, @ErrState);
    END CATCH
END;
GO
```

- [ ] **Step 4: Write `R__Location_TerminalPlcDevice_GetByTerminal.sql`**

```sql
-- =============================================
-- Procedure:   Location.TerminalPlcDevice_GetByTerminal
-- Description: All active PLC-device mappings for a terminal, joined to type.
--   Read proc - no status row; empty result = none. Feeds onStartup /
--   session.custom.plcDevices.
-- =============================================
CREATE OR ALTER PROCEDURE Location.TerminalPlcDevice_GetByTerminal
    @TerminalLocationId BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    SELECT
        d.Id,
        d.TerminalLocationId,
        d.PlcDeviceTypeId,
        t.Code                  AS DeviceTypeCode,
        t.Name                  AS DeviceTypeName,
        d.DeviceCode,
        d.OpcServerConnection,
        d.DeviceName,
        d.BasePath,
        d.IsSimulated,
        d.WriteDisplayEnabled,
        d.SortOrder
    FROM Location.TerminalPlcDevice d
    INNER JOIN Location.PlcDeviceType t ON t.Id = d.PlcDeviceTypeId
    WHERE d.TerminalLocationId = @TerminalLocationId
      AND d.DeprecatedAt IS NULL
    ORDER BY d.SortOrder ASC, d.Id ASC;
END;
GO
```

- [ ] **Step 5: Run to verify it passes**

Run: `cd sql/tests; ./Run-Tests.ps1 -Filter "0037"`
Expected: PASS — `020_TerminalPlcDevice_crud.sql` shows 9 passed, 0 failed (schema file still green too).

- [ ] **Step 6: Commit**

```bash
git add sql/migrations/repeatable/R__Location_TerminalPlcDevice_Save.sql sql/migrations/repeatable/R__Location_TerminalPlcDevice_GetByTerminal.sql sql/tests/0037_PlcIntegration/020_TerminalPlcDevice_crud.sql
git commit -m "feat(plc): TerminalPlcDevice_Save (upsert) + _GetByTerminal"
```

---

### Task 3: `Location.TerminalPlcDevice_Deprecate`

**Files:**
- Create: `sql/migrations/repeatable/R__Location_TerminalPlcDevice_Deprecate.sql`
- Modify: `sql/tests/0037_PlcIntegration/020_TerminalPlcDevice_crud.sql` (add a deprecate test before Cleanup)

**Interfaces:**
- Produces: `Location.TerminalPlcDevice_Deprecate(@Id BIGINT, @AppUserId BIGINT)` → status row `Status, Message` (no NewId).

- [ ] **Step 1: Add the failing test** — insert this block into `020_TerminalPlcDevice_crud.sql` immediately **before** the `-- Cleanup` block:

```sql
-- Test 5: Deprecate the row; GetByTerminal no longer returns it
DECLARE @S BIT, @M NVARCHAR(500);
DECLARE @termId BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'TEST-TPD-TERM');
DECLARE @rowId BIGINT = (SELECT Id FROM Location.TerminalPlcDevice WHERE TerminalLocationId=@termId AND DeviceCode=N'5G0_A1');
CREATE TABLE #R5 (Status BIT, Message NVARCHAR(500));
INSERT INTO #R5 EXEC Location.TerminalPlcDevice_Deprecate @Id=@rowId, @AppUserId=1;
SELECT @S=Status, @M=Message FROM #R5; DROP TABLE #R5;
EXEC test.Assert_IsEqual @TestName=N'Deprecate: status 1', @Expected=N'1', @Actual=CAST(@S AS NVARCHAR(1));
EXEC test.Assert_IsNotNull @TestName=N'Deprecate: DeprecatedAt set',
    @Value=(SELECT DeprecatedAt FROM Location.TerminalPlcDevice WHERE Id=@rowId);

CREATE TABLE #G5 (Id BIGINT, TerminalLocationId BIGINT, PlcDeviceTypeId BIGINT,
    DeviceTypeCode NVARCHAR(50), DeviceTypeName NVARCHAR(100), DeviceCode NVARCHAR(100),
    OpcServerConnection NVARCHAR(200), DeviceName NVARCHAR(200), BasePath NVARCHAR(400),
    IsSimulated BIT, WriteDisplayEnabled BIT, SortOrder INT);
INSERT INTO #G5 EXEC Location.TerminalPlcDevice_GetByTerminal @TerminalLocationId=@termId;
DECLARE @rc5 INT = (SELECT COUNT(*) FROM #G5); DROP TABLE #G5;
EXEC test.Assert_IsEqual @TestName=N'Deprecate: GetByTerminal now 0 rows', @Expected=N'0', @Actual=CAST(@rc5 AS NVARCHAR(10));
GO
```

- [ ] **Step 2: Run to verify it fails**

Run: `cd sql/tests; ./Run-Tests.ps1 -Filter "0037"`
Expected: FAIL — `Could not find stored procedure 'Location.TerminalPlcDevice_Deprecate'`.

- [ ] **Step 3: Write `R__Location_TerminalPlcDevice_Deprecate.sql`**

```sql
-- =============================================
-- Procedure:   Location.TerminalPlcDevice_Deprecate
-- Description: Soft-delete a terminal->PLC-device mapping (sets DeprecatedAt).
-- Result set: Status BIT, Message NVARCHAR(500).
-- =============================================
CREATE OR ALTER PROCEDURE Location.TerminalPlcDevice_Deprecate
    @Id        BIGINT,
    @AppUserId BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Status BIT = 0, @Message NVARCHAR(500) = N'Unknown error';
    DECLARE @ProcName NVARCHAR(200) = N'Location.TerminalPlcDevice_Deprecate';
    DECLARE @Params NVARCHAR(MAX) = (SELECT @Id AS Id FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);
    DECLARE @DeviceCode NVARCHAR(100);

    BEGIN TRY
        IF @Id IS NULL OR @AppUserId IS NULL
        BEGIN
            SET @Message = N'Required parameter missing.';
            EXEC Audit.Audit_LogFailure @AppUserId=@AppUserId, @LogEntityTypeCode=N'TerminalPlcDevice',
                @EntityId=@Id, @LogEventTypeCode=N'Deprecated', @FailureReason=@Message,
                @ProcedureName=@ProcName, @AttemptedParameters=@Params;
            SELECT @Status AS Status, @Message AS Message; RETURN;
        END

        SELECT @DeviceCode = DeviceCode FROM Location.TerminalPlcDevice WHERE Id=@Id AND DeprecatedAt IS NULL;
        IF @DeviceCode IS NULL
        BEGIN
            SET @Message = N'TerminalPlcDevice not found or already deprecated.';
            EXEC Audit.Audit_LogFailure @AppUserId=@AppUserId, @LogEntityTypeCode=N'TerminalPlcDevice',
                @EntityId=@Id, @LogEventTypeCode=N'Deprecated', @FailureReason=@Message,
                @ProcedureName=@ProcName, @AttemptedParameters=@Params;
            SELECT @Status AS Status, @Message AS Message; RETURN;
        END

        DECLARE @Activity NVARCHAR(500) = Audit.ufn_TruncateActivity(
            N'Terminal device ' + @DeviceCode + N' ' + Audit.ufn_MidDot() + N' Deprecated');

        BEGIN TRANSACTION;
        UPDATE Location.TerminalPlcDevice
        SET DeprecatedAt=SYSUTCDATETIME(), UpdatedAt=SYSUTCDATETIME(), UpdatedByUserId=@AppUserId
        WHERE Id=@Id;

        EXEC Audit.Audit_LogConfigChange @AppUserId=@AppUserId, @LogEntityTypeCode=N'TerminalPlcDevice',
            @EntityId=@Id, @LogEventTypeCode=N'Deprecated', @LogSeverityCode=N'Info',
            @Description=@Activity, @OldValue=NULL, @NewValue=NULL;
        COMMIT TRANSACTION;

        SET @Status=1; SET @Message=N'Terminal device deprecated.';
        SELECT @Status AS Status, @Message AS Message;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        DECLARE @ErrMsg NVARCHAR(4000)=ERROR_MESSAGE(), @ErrSev INT=ERROR_SEVERITY(), @ErrState INT=ERROR_STATE();
        SET @Status=0; SET @Message=N'Unexpected error: ' + LEFT(@ErrMsg,400);
        BEGIN TRY
            EXEC Audit.Audit_LogFailure @AppUserId=@AppUserId, @LogEntityTypeCode=N'TerminalPlcDevice',
                @EntityId=@Id, @LogEventTypeCode=N'Deprecated', @FailureReason=@Message,
                @ProcedureName=@ProcName, @AttemptedParameters=@Params;
        END TRY BEGIN CATCH END CATCH
        SELECT @Status AS Status, @Message AS Message;
        RAISERROR(@ErrMsg, @ErrSev, @ErrState);
    END CATCH
END;
GO
```

- [ ] **Step 4: Run to verify it passes**

Run: `cd sql/tests; ./Run-Tests.ps1 -Filter "0037"`
Expected: PASS — `020_...` now shows 12 passed, 0 failed.

- [ ] **Step 5: Commit**

```bash
git add sql/migrations/repeatable/R__Location_TerminalPlcDevice_Deprecate.sql sql/tests/0037_PlcIntegration/020_TerminalPlcDevice_crud.sql
git commit -m "feat(plc): TerminalPlcDevice_Deprecate"
```

---

### Task 4: `Parts.ItemLocation_SetPlcPartCode` + the two resolve reads

**Files:**
- Create: `sql/migrations/repeatable/R__Parts_ItemLocation_SetPlcPartCode.sql`
- Create: `sql/migrations/repeatable/R__Parts_ItemLocation_GetByPlcPartCode.sql`
- Create: `sql/migrations/repeatable/R__Parts_ItemLocation_GetPlcPartCode.sql`
- Test: `sql/tests/0037_PlcIntegration/030_ItemLocation_PlcPartCode.sql`

**Interfaces:**
- Consumes: `Parts.ItemLocation` (active row per (ItemId, LocationId)), `Parts.Item`.
- Produces:
  - `Parts.ItemLocation_SetPlcPartCode(@ItemId BIGINT, @LocationId BIGINT, @PlcPartCode INT, @AppUserId BIGINT)` → status row `Status, Message`. Requires an active ItemLocation row; enforces uniqueness of `@PlcPartCode` per location.
  - `Parts.ItemLocation_GetByPlcPartCode(@LocationId BIGINT, @PlcPartCode INT)` → row `ItemId, PartNumber, Name` (the Item that the PLC integer code maps to at that line — vision-validation read). Empty = unmapped.
  - `Parts.ItemLocation_GetPlcPartCode(@ItemId BIGINT, @LocationId BIGINT)` → row `PlcPartCode` (write-path read: MES resolves the code to send to the PLC). Empty = unset.

Assume `Parts.Item` has columns `Id`, `PartNumber`, `Name` (confirm the display-name column name; if it is `Description`, substitute in the SELECT of `GetByPlcPartCode`).

- [ ] **Step 1: Write the failing test** — `sql/tests/0037_PlcIntegration/030_ItemLocation_PlcPartCode.sql`

```sql
-- =============================================
-- File: 0037_PlcIntegration/030_ItemLocation_PlcPartCode.sql
-- Tests SetPlcPartCode + GetByPlcPartCode + GetPlcPartCode.
-- Uses the two lowest-Id active Items + a throwaway Location.
-- =============================================
EXEC test.BeginTestFile @FileName = N'0037_PlcIntegration/030_ItemLocation_PlcPartCode.sql';
GO

-- Fixture: a throwaway WorkCenter location + two ItemLocation rows for two items.
DECLARE @rootId BIGINT = (SELECT TOP 1 Id FROM Location.Location WHERE DeprecatedAt IS NULL ORDER BY Id);
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'TEST-PPC-LINE')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code)
    VALUES (5, @rootId, N'Test PPC Line', N'TEST-PPC-LINE');
GO
DECLARE @locId BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'TEST-PPC-LINE');
DECLARE @item1 BIGINT = (SELECT Id FROM Parts.Item WHERE DeprecatedAt IS NULL ORDER BY Id OFFSET 0 ROWS FETCH NEXT 1 ROWS ONLY);
DECLARE @item2 BIGINT = (SELECT Id FROM Parts.Item WHERE DeprecatedAt IS NULL ORDER BY Id OFFSET 1 ROWS FETCH NEXT 1 ROWS ONLY);
INSERT INTO Parts.ItemLocation (ItemId, LocationId) VALUES (@item1, @locId), (@item2, @locId);
GO

-- Test 1: set code 1 on item1
DECLARE @S BIT, @M NVARCHAR(500);
DECLARE @locId BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'TEST-PPC-LINE');
DECLARE @item1 BIGINT = (SELECT Id FROM Parts.Item WHERE DeprecatedAt IS NULL ORDER BY Id OFFSET 0 ROWS FETCH NEXT 1 ROWS ONLY);
CREATE TABLE #R1 (Status BIT, Message NVARCHAR(500));
INSERT INTO #R1 EXEC Parts.ItemLocation_SetPlcPartCode @ItemId=@item1, @LocationId=@locId, @PlcPartCode=1, @AppUserId=1;
SELECT @S=Status, @M=Message FROM #R1; DROP TABLE #R1;
EXEC test.Assert_IsEqual @TestName=N'SetPlcPartCode item1=1: status 1', @Expected=N'1', @Actual=CAST(@S AS NVARCHAR(1));
GO

-- Test 2: duplicate code 1 on item2 (same location) rejected
DECLARE @S BIT, @M NVARCHAR(500);
DECLARE @locId BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'TEST-PPC-LINE');
DECLARE @item2 BIGINT = (SELECT Id FROM Parts.Item WHERE DeprecatedAt IS NULL ORDER BY Id OFFSET 1 ROWS FETCH NEXT 1 ROWS ONLY);
CREATE TABLE #R2 (Status BIT, Message NVARCHAR(500));
INSERT INTO #R2 EXEC Parts.ItemLocation_SetPlcPartCode @ItemId=@item2, @LocationId=@locId, @PlcPartCode=1, @AppUserId=1;
SELECT @S=Status, @M=Message FROM #R2; DROP TABLE #R2;
EXEC test.Assert_IsEqual @TestName=N'SetPlcPartCode dup code: status 0', @Expected=N'0', @Actual=CAST(@S AS NVARCHAR(1));
GO

-- Test 3: GetByPlcPartCode(loc,1) -> item1
DECLARE @locId BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'TEST-PPC-LINE');
DECLARE @item1 BIGINT = (SELECT Id FROM Parts.Item WHERE DeprecatedAt IS NULL ORDER BY Id OFFSET 0 ROWS FETCH NEXT 1 ROWS ONLY);
CREATE TABLE #G (ItemId BIGINT, PartNumber NVARCHAR(100), Name NVARCHAR(200));
INSERT INTO #G EXEC Parts.ItemLocation_GetByPlcPartCode @LocationId=@locId, @PlcPartCode=1;
DECLARE @got BIGINT = (SELECT TOP 1 ItemId FROM #G); DROP TABLE #G;
EXEC test.Assert_IsEqual @TestName=N'GetByPlcPartCode(1) resolves to item1',
    @Expected=CAST(@item1 AS NVARCHAR(20)), @Actual=CAST(@got AS NVARCHAR(20));
GO

-- Test 4: GetPlcPartCode(item1,loc) -> 1
DECLARE @locId BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'TEST-PPC-LINE');
DECLARE @item1 BIGINT = (SELECT Id FROM Parts.Item WHERE DeprecatedAt IS NULL ORDER BY Id OFFSET 0 ROWS FETCH NEXT 1 ROWS ONLY);
CREATE TABLE #C (PlcPartCode INT);
INSERT INTO #C EXEC Parts.ItemLocation_GetPlcPartCode @ItemId=@item1, @LocationId=@locId;
DECLARE @code INT = (SELECT TOP 1 PlcPartCode FROM #C); DROP TABLE #C;
EXEC test.Assert_IsEqual @TestName=N'GetPlcPartCode(item1) = 1', @Expected=N'1', @Actual=CAST(@code AS NVARCHAR(10));
GO

-- Cleanup
DELETE FROM Parts.ItemLocation WHERE LocationId IN (SELECT Id FROM Location.Location WHERE Code=N'TEST-PPC-LINE');
DELETE FROM Location.Location WHERE Code = N'TEST-PPC-LINE';
GO

EXEC test.PrintSummary;
GO
```

- [ ] **Step 2: Run to verify it fails**

Run: `cd sql/tests; ./Run-Tests.ps1 -Filter "0037"`
Expected: FAIL — `Could not find stored procedure 'Parts.ItemLocation_SetPlcPartCode'`.

- [ ] **Step 3: Write `R__Parts_ItemLocation_SetPlcPartCode.sql`**

```sql
-- =============================================
-- Procedure:   Parts.ItemLocation_SetPlcPartCode
-- Description: Set the line-local integer PLC part-code on an existing active
--   ItemLocation row. Enforces per-location uniqueness of the code. The PLC/
--   vision reports this integer; the MES resolves it to/from the real Item.
-- Result set: Status BIT, Message NVARCHAR(500).
-- =============================================
CREATE OR ALTER PROCEDURE Parts.ItemLocation_SetPlcPartCode
    @ItemId      BIGINT,
    @LocationId  BIGINT,
    @PlcPartCode INT,
    @AppUserId   BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Status BIT = 0, @Message NVARCHAR(500) = N'Unknown error';
    DECLARE @ProcName NVARCHAR(200) = N'Parts.ItemLocation_SetPlcPartCode';
    DECLARE @Params NVARCHAR(MAX) = (SELECT @ItemId AS ItemId, @LocationId AS LocationId,
        @PlcPartCode AS PlcPartCode FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);
    DECLARE @ItemLocationId BIGINT;

    BEGIN TRY
        IF @ItemId IS NULL OR @LocationId IS NULL OR @PlcPartCode IS NULL OR @AppUserId IS NULL
        BEGIN
            SET @Message = N'Required parameter missing.';
            EXEC Audit.Audit_LogFailure @AppUserId=@AppUserId, @LogEntityTypeCode=N'ItemLocation',
                @EntityId=NULL, @LogEventTypeCode=N'Updated', @FailureReason=@Message,
                @ProcedureName=@ProcName, @AttemptedParameters=@Params;
            SELECT @Status AS Status, @Message AS Message; RETURN;
        END

        SELECT @ItemLocationId = Id FROM Parts.ItemLocation
        WHERE ItemId=@ItemId AND LocationId=@LocationId AND DeprecatedAt IS NULL;

        IF @ItemLocationId IS NULL
        BEGIN
            SET @Message = N'No active ItemLocation for this Item + Location (add eligibility first).';
            EXEC Audit.Audit_LogFailure @AppUserId=@AppUserId, @LogEntityTypeCode=N'ItemLocation',
                @EntityId=NULL, @LogEventTypeCode=N'Updated', @FailureReason=@Message,
                @ProcedureName=@ProcName, @AttemptedParameters=@Params;
            SELECT @Status AS Status, @Message AS Message; RETURN;
        END

        -- Per-location uniqueness (excluding this row)
        IF EXISTS (SELECT 1 FROM Parts.ItemLocation
                   WHERE LocationId=@LocationId AND PlcPartCode=@PlcPartCode
                     AND DeprecatedAt IS NULL AND Id <> @ItemLocationId)
        BEGIN
            SET @Message = N'PlcPartCode already assigned to another item at this location.';
            EXEC Audit.Audit_LogFailure @AppUserId=@AppUserId, @LogEntityTypeCode=N'ItemLocation',
                @EntityId=@ItemLocationId, @LogEventTypeCode=N'Updated', @FailureReason=@Message,
                @ProcedureName=@ProcName, @AttemptedParameters=@Params;
            SELECT @Status AS Status, @Message AS Message; RETURN;
        END

        DECLARE @Activity NVARCHAR(500) = Audit.ufn_TruncateActivity(
            N'ItemLocation ' + CAST(@ItemLocationId AS NVARCHAR(20)) + N' ' + Audit.ufn_MidDot()
            + N' Set PlcPartCode = ' + CAST(@PlcPartCode AS NVARCHAR(10)));

        BEGIN TRANSACTION;
        UPDATE Parts.ItemLocation SET PlcPartCode=@PlcPartCode WHERE Id=@ItemLocationId;

        EXEC Audit.Audit_LogConfigChange @AppUserId=@AppUserId, @LogEntityTypeCode=N'ItemLocation',
            @EntityId=@ItemLocationId, @LogEventTypeCode=N'Updated', @LogSeverityCode=N'Info',
            @Description=@Activity, @OldValue=NULL, @NewValue=@Params;
        COMMIT TRANSACTION;

        SET @Status=1; SET @Message=N'PLC part-code set.';
        SELECT @Status AS Status, @Message AS Message;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        DECLARE @ErrMsg NVARCHAR(4000)=ERROR_MESSAGE(), @ErrSev INT=ERROR_SEVERITY(), @ErrState INT=ERROR_STATE();
        SET @Status=0; SET @Message=N'Unexpected error: ' + LEFT(@ErrMsg,400);
        BEGIN TRY
            EXEC Audit.Audit_LogFailure @AppUserId=@AppUserId, @LogEntityTypeCode=N'ItemLocation',
                @EntityId=@ItemLocationId, @LogEventTypeCode=N'Updated', @FailureReason=@Message,
                @ProcedureName=@ProcName, @AttemptedParameters=@Params;
        END TRY BEGIN CATCH END CATCH
        SELECT @Status AS Status, @Message AS Message;
        RAISERROR(@ErrMsg, @ErrSev, @ErrState);
    END CATCH
END;
GO
```

- [ ] **Step 4: Write `R__Parts_ItemLocation_GetByPlcPartCode.sql`**

```sql
-- =============================================
-- Procedure:   Parts.ItemLocation_GetByPlcPartCode
-- Description: Resolve a line-local PLC integer part-code to its Item at a
--   location (vision-validation read). Read proc - empty result = unmapped.
-- =============================================
CREATE OR ALTER PROCEDURE Parts.ItemLocation_GetByPlcPartCode
    @LocationId  BIGINT,
    @PlcPartCode INT
AS
BEGIN
    SET NOCOUNT ON;
    SELECT i.Id AS ItemId, i.PartNumber, i.Name
    FROM Parts.ItemLocation il
    INNER JOIN Parts.Item i ON i.Id = il.ItemId
    WHERE il.LocationId = @LocationId
      AND il.PlcPartCode = @PlcPartCode
      AND il.DeprecatedAt IS NULL;
END;
GO
```

- [ ] **Step 5: Write `R__Parts_ItemLocation_GetPlcPartCode.sql`**

```sql
-- =============================================
-- Procedure:   Parts.ItemLocation_GetPlcPartCode
-- Description: Resolve an Item + Location to its line-local PLC integer part-code
--   (write-path read - MES sends this code to the PLC). Empty result = unset.
-- =============================================
CREATE OR ALTER PROCEDURE Parts.ItemLocation_GetPlcPartCode
    @ItemId     BIGINT,
    @LocationId BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    SELECT il.PlcPartCode
    FROM Parts.ItemLocation il
    WHERE il.ItemId = @ItemId
      AND il.LocationId = @LocationId
      AND il.DeprecatedAt IS NULL
      AND il.PlcPartCode IS NOT NULL;
END;
GO
```

- [ ] **Step 6: Run to verify it passes**

Run: `cd sql/tests; ./Run-Tests.ps1 -Filter "0037"`
Expected: PASS — `030_...` shows 4 passed, 0 failed.

- [ ] **Step 7: Commit**

```bash
git add sql/migrations/repeatable/R__Parts_ItemLocation_SetPlcPartCode.sql sql/migrations/repeatable/R__Parts_ItemLocation_GetByPlcPartCode.sql sql/migrations/repeatable/R__Parts_ItemLocation_GetPlcPartCode.sql sql/tests/0037_PlcIntegration/030_ItemLocation_PlcPartCode.sql
git commit -m "feat(plc): ItemLocation PlcPartCode set + both resolve reads"
```

---

### Task 5: `SerializedPart_Mint` accepts a PLC serial + `SerializedPart_GetBySerial`

**Files:**
- Modify: `sql/migrations/repeatable/R__Lots_SerializedPart_Mint.sql` (add `@SerialNumber` param + branch)
- Create: `sql/migrations/repeatable/R__Lots_SerializedPart_GetBySerial.sql`
- Test: `sql/tests/0037_PlcIntegration/040_SerializedPart_serial.sql`

**Interfaces:**
- Consumes: `Lots.SerializedPart` (UNIQUE `SerialNumber`), `Lots.IdentifierSequence` (Code `SerializedItem`), `Parts.Item`, `Lots.Lot`.
- Produces:
  - `Lots.SerializedPart_Mint(@ItemId, @ProducingLotId, @AppUserId, @TerminalLocationId=NULL, @SerialNumber NVARCHAR(50)=NULL)` → status row `Status, Message, NewId, SerialNumber`. `@SerialNumber` NULL/empty → auto-generate from sequence (existing behavior). Non-empty → use it; duplicate returns a friendly failure.
  - `Lots.SerializedPart_GetBySerial(@SerialNumber NVARCHAR(50))` → row `Id, SerialNumber, ItemId, ProducingLotId, EtchedAt`. Empty = not found (validate/dedup a PLC-reported serial).

The **existing** proc body is at `sql/migrations/repeatable/R__Lots_SerializedPart_Mint.sql`. The change is: (a) add the `@SerialNumber` param, (b) inside the transaction, branch — if a serial was supplied use it (after a duplicate pre-check), else run the existing sequence-allocation block.

- [ ] **Step 1: Write the failing test** — `sql/tests/0037_PlcIntegration/040_SerializedPart_serial.sql`

```sql
-- =============================================
-- File: 0037_PlcIntegration/040_SerializedPart_serial.sql
-- Tests SerializedPart_Mint with a supplied serial + auto-gen + GetBySerial.
-- Uses the lowest-Id active Item + a throwaway open LOT.
-- =============================================
EXEC test.BeginTestFile @FileName = N'0037_PlcIntegration/040_SerializedPart_serial.sql';
GO

-- Fixture: reuse the lowest-Id item + lowest-Id lot (any existing lot works for the FK).
-- Test 1: mint with a supplied serial
DECLARE @S BIT, @M NVARCHAR(500), @NewId BIGINT, @Serial NVARCHAR(50);
DECLARE @itemId BIGINT = (SELECT TOP 1 Id FROM Parts.Item WHERE DeprecatedAt IS NULL ORDER BY Id);
DECLARE @lotId BIGINT = (SELECT TOP 1 Id FROM Lots.Lot ORDER BY Id);
CREATE TABLE #R1 (Status BIT, Message NVARCHAR(500), NewId BIGINT, SerialNumber NVARCHAR(50));
INSERT INTO #R1 EXEC Lots.SerializedPart_Mint @ItemId=@itemId, @ProducingLotId=@lotId,
    @AppUserId=1, @SerialNumber=N'TESTSN-000001';
SELECT @S=Status, @M=Message, @NewId=NewId, @Serial=SerialNumber FROM #R1; DROP TABLE #R1;
EXEC test.Assert_IsEqual @TestName=N'Mint supplied serial: status 1', @Expected=N'1', @Actual=CAST(@S AS NVARCHAR(1));
EXEC test.Assert_IsEqual @TestName=N'Mint supplied serial: serial echoed',
    @Expected=N'TESTSN-000001', @Actual=@Serial;
GO

-- Test 2: duplicate supplied serial rejected
DECLARE @S BIT, @M NVARCHAR(500);
DECLARE @itemId BIGINT = (SELECT TOP 1 Id FROM Parts.Item WHERE DeprecatedAt IS NULL ORDER BY Id);
DECLARE @lotId BIGINT = (SELECT TOP 1 Id FROM Lots.Lot ORDER BY Id);
CREATE TABLE #R2 (Status BIT, Message NVARCHAR(500), NewId BIGINT, SerialNumber NVARCHAR(50));
INSERT INTO #R2 EXEC Lots.SerializedPart_Mint @ItemId=@itemId, @ProducingLotId=@lotId,
    @AppUserId=1, @SerialNumber=N'TESTSN-000001';
SELECT @S=Status, @M=Message FROM #R2; DROP TABLE #R2;
EXEC test.Assert_IsEqual @TestName=N'Mint dup serial: status 0', @Expected=N'0', @Actual=CAST(@S AS NVARCHAR(1));
EXEC test.Assert_Contains @TestName=N'Mint dup serial: message mentions exists',
    @HaystackStr=@M, @NeedleStr=N'already';
GO

-- Test 3: auto-gen when @SerialNumber NULL (existing behavior preserved)
DECLARE @S BIT, @Serial NVARCHAR(50);
DECLARE @itemId BIGINT = (SELECT TOP 1 Id FROM Parts.Item WHERE DeprecatedAt IS NULL ORDER BY Id);
DECLARE @lotId BIGINT = (SELECT TOP 1 Id FROM Lots.Lot ORDER BY Id);
CREATE TABLE #R3 (Status BIT, Message NVARCHAR(500), NewId BIGINT, SerialNumber NVARCHAR(50));
INSERT INTO #R3 EXEC Lots.SerializedPart_Mint @ItemId=@itemId, @ProducingLotId=@lotId, @AppUserId=1;
SELECT @S=Status, @Serial=SerialNumber FROM #R3; DROP TABLE #R3;
EXEC test.Assert_IsEqual @TestName=N'Mint auto-gen: status 1', @Expected=N'1', @Actual=CAST(@S AS NVARCHAR(1));
EXEC test.Assert_IsNotNull @TestName=N'Mint auto-gen: serial generated', @Value=@Serial;
GO

-- Test 4: GetBySerial finds the supplied one
CREATE TABLE #G (Id BIGINT, SerialNumber NVARCHAR(50), ItemId BIGINT, ProducingLotId BIGINT, EtchedAt DATETIME2(3));
INSERT INTO #G EXEC Lots.SerializedPart_GetBySerial @SerialNumber=N'TESTSN-000001';
DECLARE @rc INT = (SELECT COUNT(*) FROM #G); DROP TABLE #G;
EXEC test.Assert_IsEqual @TestName=N'GetBySerial finds TESTSN-000001', @Expected=N'1', @Actual=CAST(@rc AS NVARCHAR(10));
GO

-- Cleanup
DELETE FROM Lots.SerializedPart WHERE SerialNumber = N'TESTSN-000001';
GO

EXEC test.PrintSummary;
GO
```

- [ ] **Step 2: Run to verify it fails**

Run: `cd sql/tests; ./Run-Tests.ps1 -Filter "0037"`
Expected: FAIL — `Procedure ... has no parameter named '@SerialNumber'` (or GetBySerial not found).

- [ ] **Step 3: Modify `R__Lots_SerializedPart_Mint.sql`** — add the param to the signature:

```sql
CREATE OR ALTER PROCEDURE Lots.SerializedPart_Mint
    @ItemId             BIGINT,
    @ProducingLotId     BIGINT,
    @AppUserId          BIGINT,
    @TerminalLocationId BIGINT       = NULL,
    @SerialNumber       NVARCHAR(50) = NULL
AS
```

Then, inside the `BEGIN TRANSACTION` block, **replace the sequence-allocation block** (the `SELECT @SeqLast = ... FROM Lots.IdentifierSequence ... ` through the `SET @SerialNumber = CASE ...` assignment) with this branch — supplied-serial path first, else the original auto-gen:

```sql
        IF @SerialNumber IS NOT NULL AND LTRIM(RTRIM(@SerialNumber)) <> N''
        BEGIN
            -- Supplied by the PLC/etch: use it, but reject duplicates cleanly
            IF EXISTS (SELECT 1 FROM Lots.SerializedPart WHERE SerialNumber = @SerialNumber)
                RAISERROR(N'Serial number %s already exists.', 16, 1, @SerialNumber);
        END
        ELSE
        BEGIN
            -- Auto-generate from the SerializedItem identifier sequence (original behavior)
            SELECT @SeqLast   = s.LastValue + 1,
                   @SeqEnd    = s.EndingValue,
                   @SeqFormat = s.FormatString
            FROM Lots.IdentifierSequence s WITH (ROWLOCK, UPDLOCK, HOLDLOCK)
            WHERE s.Code = N'SerializedItem';

            IF @SeqLast IS NULL
                RAISERROR(N'Identifier sequence ''SerializedItem'' is not configured.', 16, 1);
            IF @SeqLast > @SeqEnd
                RAISERROR(N'Identifier sequence ''SerializedItem'' is exhausted.', 16, 1);

            UPDATE Lots.IdentifierSequence
            SET LastValue = @SeqLast, UpdatedAt = SYSUTCDATETIME()
            WHERE Code = N'SerializedItem';

            SET @SeqPrefix = CASE WHEN CHARINDEX(N'{', @SeqFormat) > 0
                                  THEN LEFT(@SeqFormat, CHARINDEX(N'{', @SeqFormat) - 1)
                                  ELSE @SeqFormat END;
            SET @SeqPad = TRY_CAST(
                SUBSTRING(@SeqFormat,
                          CHARINDEX(N'D', @SeqFormat, CHARINDEX(N'{', @SeqFormat)) + 1,
                          CHARINDEX(N'}', @SeqFormat, CHARINDEX(N'{', @SeqFormat)) - CHARINDEX(N'D', @SeqFormat, CHARINDEX(N'{', @SeqFormat)) - 1)
                AS INT);
            SET @SerialNumber = CASE WHEN @SeqPad IS NULL OR @SeqPad < 1
                THEN @SeqPrefix + CAST(@SeqLast AS NVARCHAR(20))
                ELSE @SeqPrefix + RIGHT(REPLICATE(N'0', @SeqPad) + CAST(@SeqLast AS NVARCHAR(20)), @SeqPad) END;
        END
```

Leave the `INSERT INTO Lots.SerializedPart (...)`, `SET @NewId = SCOPE_IDENTITY();`, `COMMIT`, success-message, and the final 4-column `SELECT @Status, @Message, @NewId, @SerialNumber` exactly as they already are. The `RAISERROR` in the supplied-serial branch is caught by the existing CATCH, which emits the status row with `@Status=0` and a `Message` containing "already exists".

- [ ] **Step 4: Write `R__Lots_SerializedPart_GetBySerial.sql`**

```sql
-- =============================================
-- Procedure:   Lots.SerializedPart_GetBySerial
-- Description: Look up a serialized part by its serial number (validate/dedup a
--   PLC-reported serial). Read proc - empty result = not found.
-- =============================================
CREATE OR ALTER PROCEDURE Lots.SerializedPart_GetBySerial
    @SerialNumber NVARCHAR(50)
AS
BEGIN
    SET NOCOUNT ON;
    SELECT Id, SerialNumber, ItemId, ProducingLotId, EtchedAt
    FROM Lots.SerializedPart
    WHERE SerialNumber = @SerialNumber;
END;
GO
```

- [ ] **Step 5: Run to verify it passes**

Run: `cd sql/tests; ./Run-Tests.ps1 -Filter "0037"`
Expected: PASS — `040_...` shows 6 passed, 0 failed.

- [ ] **Step 6: Commit**

```bash
git add sql/migrations/repeatable/R__Lots_SerializedPart_Mint.sql sql/migrations/repeatable/R__Lots_SerializedPart_GetBySerial.sql sql/tests/0037_PlcIntegration/040_SerializedPart_serial.sql
git commit -m "feat(plc): SerializedPart_Mint accepts PLC serial + SerializedPart_GetBySerial"
```

---

### Task 6: Full-suite regression + docs touch

**Files:**
- Modify: `docs/superpowers/specs/2026-07-10-plc-udt-terminal-mapping-design.md` (tick §11 SQL items done — optional narrative)

- [ ] **Step 1: Run the ENTIRE suite** (not just the filter) to confirm no regression in the ~1900 existing assertions:

Run: `cd sql/tests; ./Run-Tests.ps1`
Expected: `Test run PASSED.` with `Failed: 0`. (The pre-existing `010_Parts_codes_crud` thrower noted in PROJECT_STATUS may still exit non-zero on its own file; confirm the new `0037_*` files are all green and no previously-green file regressed.)

- [ ] **Step 2: Commit any doc tick**

```bash
git add docs/superpowers/specs/2026-07-10-plc-udt-terminal-mapping-design.md
git commit -m "docs(plc): mark SQL-foundation items built"
```

---

## Downstream (separate plans — not in this plan)

- **Plan 2 — Ignition tags + sim:** generate the 4 UDT definition JSONs + `MPP_Sim` Programmable Device Simulator program CSV from the §3.3 member catalog; UDT instances; the Sim Panel view (§7.1). Consumes the `TerminalPlcDevice` columns → UDT params. Uses the NQ folder shape (`ignition/projects/Core/ignition/named-query/<domain>/<Proc>/` with `query.sql` + `resource.json`) to expose the Task-2..5 procs.
- **Plan 3 — Watchers + onStartup + Config-Tool editor:** the 4 gateway watcher modules (edge-subscribed, mapped to procs), `onStartup` resolving `TerminalPlcDevice_GetByTerminal` into `session.custom.plcDevices`, and the Terminal→device mapping editor UI (per-terminal list; ConfirmUnsaved) + `PlcPartCode` on the Item×Location surface.

---

## Self-Review

**Spec coverage (spec §4 + §5 SQL scope):** §4.1 PlcDeviceType → Task 1. §4.2 TerminalPlcDevice + Save/Deprecate/GetByTerminal procs → Tasks 1–3. §4.3 ItemLocation.PlcPartCode + resolve/validate → Tasks 1, 4. §5 serial validate surface (`SerializedPart_GetBySerial` + `@SerialNumber` on Mint) → Task 5. `onStartup`, watchers, UDTs, Config editor → explicitly deferred to Plans 2–3.

**Placeholder scan:** No TBD/TODO in steps. Two documented assumptions the implementer must confirm against the live schema (not placeholders — verification points): `Parts.Item` display column is `Name` (Task 4 GetByPlcPartCode SELECT — substitute if it is `Description`); and the exact text span in `SerializedPart_Mint` to replace (Task 5 identifies it by its start/end statements).

**Type consistency:** `TerminalPlcDevice_Save` returns `Status,Message,NewId`; `_Deprecate` returns `Status,Message`; reads return the column sets the tests' temp tables declare (matched exactly). `SerializedPart_Mint` keeps its 4-column `Status,Message,NewId,SerialNumber` shape; the test temp tables match. `@PlcDeviceTypeId` (BIGINT FK) used consistently in Save + tests. Audit entity codes `TerminalPlcDevice`/`ItemLocation` match the seeded `Audit.LogEntityType`.
