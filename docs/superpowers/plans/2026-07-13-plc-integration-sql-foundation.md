# PLC Integration — SQL Foundation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the SQL layer that lets a terminal point at its PLC UDT instance(s), lets the MES resolve a part's PLC ID (validated at run time against the assembly-out FIFO queue), and validates PLC-reported serial numbers.

**Architecture:** One versioned migration (`0037`) adds a `Location.PlcDeviceType` code table (4 seeded UDT types), a `Location.TerminalPlcDevice` 1-to-many **thin-pointer** table (terminal → UDT instance path; OPC addressing lives on the instance params, not the DB), and a `Parts.Item.PlcId` column. Repeatable stored procs provide CRUD over the mapping, get/set `Item.PlcId`, and extend `SerializedPart_Mint` to accept a PLC-reported serial (plus a `_GetBySerial` lookup). All procs follow the mandated status-row contract (no OUTPUT params) and the readable-audit convention.

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
- **Run tests against a THROWAWAY `MPP_MES_Test` — NEVER the default `MPP_MES_Dev`** (that is Jacques's hand-built validation DB; `Run-Tests.ps1` reset-nukes its target). Every Run step in this plan means: `cd sql/tests; ./Run-Tests.ps1 -DatabaseName MPP_MES_Test -Filter "0037"` (filtered) or `./Run-Tests.ps1 -DatabaseName MPP_MES_Test` (full). Pass = final summary `Failed: 0` / `Test run PASSED`.
- **Test fixtures are self-contained.** A clean reset seeds Items (`020_seed_items`) but **no LOTs** (`seed_demo` is skipped). Any test needing a producing LOT must **create its own** via `Lots.Lot_Create` and tear it down FK-safe (SerializedPart → LotGenealogyClosure self-row → Lot → ItemLocation → Item) — mirror the proven pattern in `sql/tests/0028_PlantFloor_Assembly/030_ContainerSerial_Add_with_bypass.sql`. This supersedes any "borrow an existing LOT" shortcut written in a task's test.

---

## File Structure

**Created:**
- `sql/migrations/versioned/0037_plc_integration_foundation.sql` — `PlcDeviceType` (+seed), `TerminalPlcDevice`, `Item.PlcId`, `LogEntityType` seed row, SchemaVersion.
- `sql/migrations/repeatable/R__Location_TerminalPlcDevice_Save.sql`
- `sql/migrations/repeatable/R__Location_TerminalPlcDevice_GetByTerminal.sql`
- `sql/migrations/repeatable/R__Location_TerminalPlcDevice_Deprecate.sql`
- `sql/migrations/repeatable/R__Parts_Item_SetPlcId.sql`
- `sql/migrations/repeatable/R__Parts_Item_GetPlcId.sql`
- `sql/migrations/repeatable/R__Lots_SerializedPart_GetBySerial.sql`
- `sql/tests/0037_PlcIntegration/010_schema.sql`
- `sql/tests/0037_PlcIntegration/020_TerminalPlcDevice_crud.sql`
- `sql/tests/0037_PlcIntegration/030_Item_PlcId.sql`
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
`@LogEntityTypeCode` values used here: `N'TerminalPlcDevice'` (new, Id 25), `N'Item'` (existing 5), `N'SerializedPart'` (existing 24). `@LogEventTypeCode` values `Created`/`Updated`/`Deprecated` already seeded.

**Test pattern** (`sql/tests/0003_Location/010_Location_crud.sql`): each file opens with `EXEC test.BeginTestFile @FileName=N'...';` then per test — `CREATE TABLE #R (Status BIT, Message NVARCHAR(500), NewId BIGINT); INSERT INTO #R EXEC <proc> ...; SELECT @S=Status,... FROM #R; DROP TABLE #R;` then `EXEC test.Assert_IsEqual @TestName=N'...', @Expected=N'...', @Actual=<nvarchar>;`. Each `GO`-separated batch re-declares its locals. Cleanup deletes test rows bottom-up (FK-safe). End with `EXEC test.PrintSummary;`. Assertion procs: `test.Assert_IsEqual`, `test.Assert_IsTrue`, `test.Assert_IsNull`, `test.Assert_IsNotNull`, `test.Assert_RowCount`, `test.Assert_Contains`.

---

### Task 1: Migration 0037 — schema + seed

**Files:**
- Create: `sql/migrations/versioned/0037_plc_integration_foundation.sql`
- Test: `sql/tests/0037_PlcIntegration/010_schema.sql`

**Interfaces:**
- Produces: table `Location.PlcDeviceType(Id, Code, Name, Description, CreatedAt, DeprecatedAt)` seeded 4 rows (`ScaleStation`, `SerializedMipStation`, `NonSerializedMipStation`, `TrayInspectionStation`); table `Location.TerminalPlcDevice` (columns per DDL below); column `Parts.Item.PlcId INT NULL`; `Audit.LogEntityType` row `(25, N'TerminalPlcDevice', ...)`.

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

-- TerminalPlcDevice table + key columns (thin pointer)
DECLARE @colOk NVARCHAR(1) = CASE WHEN
    COL_LENGTH('Location.TerminalPlcDevice','UdtInstancePath') IS NOT NULL
    AND COL_LENGTH('Location.TerminalPlcDevice','DeviceCode') IS NOT NULL
    AND COL_LENGTH('Location.TerminalPlcDevice','PlcDeviceTypeId') IS NOT NULL
    THEN N'1' ELSE N'0' END;
EXEC test.Assert_IsEqual @TestName=N'TerminalPlcDevice has expected columns',
    @Expected=N'1', @Actual=@colOk;
GO

-- Item.PlcId column
DECLARE @plcCol NVARCHAR(1) = CASE WHEN
    COL_LENGTH('Parts.Item','PlcId') IS NOT NULL THEN N'1' ELSE N'0' END;
EXEC test.Assert_IsEqual @TestName=N'Item has PlcId column',
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
--              * Location.TerminalPlcDevice - 1-to-many thin pointer: terminal ->
--                UDT instance (UdtInstancePath). OPC addressing lives on the UDT
--                instance's params in the tag provider, NOT in this table.
--              * Parts.Item.PlcId - stable per-part PLC/vision recipe integer
--                (validated at run time against the assembly-out FIFO queue).
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

-- Thin pointer: terminal -> UDT instance. OPC addressing lives on the UDT
-- instance's params in the MPP tag provider, NOT here.
IF OBJECT_ID(N'Location.TerminalPlcDevice') IS NULL
CREATE TABLE Location.TerminalPlcDevice (
    Id                  BIGINT IDENTITY(1,1) NOT NULL CONSTRAINT PK_TerminalPlcDevice PRIMARY KEY,
    TerminalLocationId  BIGINT        NOT NULL CONSTRAINT FK_TerminalPlcDevice_Terminal   REFERENCES Location.Location(Id),
    PlcDeviceTypeId     BIGINT        NOT NULL CONSTRAINT FK_TerminalPlcDevice_DeviceType REFERENCES Location.PlcDeviceType(Id),
    DeviceCode          NVARCHAR(100) NOT NULL,
    UdtInstancePath     NVARCHAR(400) NOT NULL,
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

-- Item.PlcId: stable per-part PLC/vision recipe integer. Not globally unique
-- (FIFO fixes the expected part at run time), so no unique index.
IF COL_LENGTH(N'Parts.Item', N'PlcId') IS NULL
    ALTER TABLE Parts.Item ADD PlcId INT NULL;
GO

IF NOT EXISTS (SELECT 1 FROM Audit.LogEntityType WHERE Code = N'TerminalPlcDevice')
INSERT INTO Audit.LogEntityType (Id, Code, Name, Description) VALUES
    (25, N'TerminalPlcDevice', N'Terminal PLC Device', N'Terminal-to-PLC-device mapping row');
GO

IF NOT EXISTS (SELECT 1 FROM dbo.SchemaVersion WHERE MigrationId = N'0037_plc_integration_foundation')
    INSERT INTO dbo.SchemaVersion (MigrationId, Description)
    VALUES (N'0037_plc_integration_foundation',
        N'PLC integration foundation: PlcDeviceType (+seed), TerminalPlcDevice, Item.PlcId, TerminalPlcDevice audit entity.');
GO
```

- [ ] **Step 4: Run to verify it passes**

Run: `cd sql/tests; ./Run-Tests.ps1 -Filter "0037"`
Expected: PASS — `010_schema.sql` shows 5 passed, 0 failed. (`Run-Tests.ps1` resets the DB, applying 0037.)

- [ ] **Step 5: Commit**

```bash
git add sql/migrations/versioned/0037_plc_integration_foundation.sql sql/tests/0037_PlcIntegration/010_schema.sql
git commit -m "feat(plc): migration 0037 - PlcDeviceType, TerminalPlcDevice, Item.PlcId"
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
  - `Location.TerminalPlcDevice_Save(@Id BIGINT=NULL, @TerminalLocationId BIGINT, @PlcDeviceTypeId BIGINT, @DeviceCode NVARCHAR(100), @UdtInstancePath NVARCHAR(400), @SortOrder INT=NULL, @AppUserId BIGINT)` → status row `Status,Message,NewId`. `@Id` NULL = insert, non-null = update.
  - `Location.TerminalPlcDevice_GetByTerminal(@TerminalLocationId BIGINT)` → rows `Id, TerminalLocationId, PlcDeviceTypeId, DeviceTypeCode, DeviceTypeName, DeviceCode, UdtInstancePath, SortOrder` (active only, ordered by SortOrder).

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
    @DeviceCode=N'5G0_A1', @UdtInstancePath=N'[MPP]PlcDevices/5G0_A1', @AppUserId=1;
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
    @DeviceCode=N'5G0_A1', @UdtInstancePath=N'[MPP]PlcDevices/5G0_A1', @AppUserId=1;
SELECT @S=Status, @M=Message FROM #R2; DROP TABLE #R2;
EXEC test.Assert_IsEqual @TestName=N'Save dup DeviceCode: status 0', @Expected=N'0', @Actual=CAST(@S AS NVARCHAR(1));
EXEC test.Assert_Contains @TestName=N'Save dup DeviceCode: message mentions exists',
    @HaystackStr=@M, @NeedleStr=N'already';
GO

-- Test 3: Update existing row (repoint instance path via @Id)
DECLARE @S BIT, @M NVARCHAR(500);
DECLARE @termId BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'TEST-TPD-TERM');
DECLARE @typeId BIGINT = (SELECT Id FROM Location.PlcDeviceType WHERE Code = N'SerializedMipStation');
DECLARE @rowId BIGINT = (SELECT Id FROM Location.TerminalPlcDevice WHERE DeviceCode=N'5G0_A1' AND TerminalLocationId=@termId);
CREATE TABLE #R3 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #R3 EXEC Location.TerminalPlcDevice_Save
    @Id=@rowId, @TerminalLocationId=@termId, @PlcDeviceTypeId=@typeId,
    @DeviceCode=N'5G0_A1', @UdtInstancePath=N'[MPP]PlcDevices/5G0_A1_v2', @AppUserId=1;
SELECT @S=Status, @M=Message FROM #R3; DROP TABLE #R3;
EXEC test.Assert_IsEqual @TestName=N'Save update: status 1', @Expected=N'1', @Actual=CAST(@S AS NVARCHAR(1));
EXEC test.Assert_IsEqual @TestName=N'Save update: UdtInstancePath repointed',
    @Expected=N'[MPP]PlcDevices/5G0_A1_v2', @Actual=(SELECT UdtInstancePath FROM Location.TerminalPlcDevice WHERE Id=@rowId);
GO

-- Test 4: GetByTerminal returns the active row joined to type
DECLARE @termId BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'TEST-TPD-TERM');
CREATE TABLE #G (Id BIGINT, TerminalLocationId BIGINT, PlcDeviceTypeId BIGINT,
    DeviceTypeCode NVARCHAR(50), DeviceTypeName NVARCHAR(100), DeviceCode NVARCHAR(100),
    UdtInstancePath NVARCHAR(400), SortOrder INT);
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
-- Description: Upsert a terminal->UDT-instance pointer row. @Id NULL = insert,
--   non-null = update. Validates terminal exists + is a Terminal (DefId 7),
--   device type exists, DeviceCode unique among the terminal's active devices.
--   Auto-assigns SortOrder = MAX(active peers)+1 on insert. OPC addressing is
--   NOT stored here - it lives on the UDT instance's params in the tag provider.
-- Result set: Status BIT, Message NVARCHAR(500), NewId BIGINT.
-- =============================================
CREATE OR ALTER PROCEDURE Location.TerminalPlcDevice_Save
    @Id                  BIGINT        = NULL,
    @TerminalLocationId  BIGINT,
    @PlcDeviceTypeId     BIGINT,
    @DeviceCode          NVARCHAR(100),
    @UdtInstancePath     NVARCHAR(400),
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
                @DeviceCode AS DeviceCode, @UdtInstancePath AS UdtInstancePath
         FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

    BEGIN TRY
        IF @TerminalLocationId IS NULL OR @PlcDeviceTypeId IS NULL OR @DeviceCode IS NULL
           OR @UdtInstancePath IS NULL OR @AppUserId IS NULL
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
            + N' (' + @UdtInstancePath + N')');

        BEGIN TRANSACTION;

        IF @Id IS NULL
        BEGIN
            DECLARE @Next INT = COALESCE(@SortOrder,
                (SELECT ISNULL(MAX(SortOrder),0)+1 FROM Location.TerminalPlcDevice
                 WHERE TerminalLocationId=@TerminalLocationId AND DeprecatedAt IS NULL));

            INSERT INTO Location.TerminalPlcDevice
                (TerminalLocationId, PlcDeviceTypeId, DeviceCode, UdtInstancePath, SortOrder, CreatedAt)
            VALUES
                (@TerminalLocationId, @PlcDeviceTypeId, @DeviceCode, @UdtInstancePath, @Next, SYSUTCDATETIME());

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
                UdtInstancePath=@UdtInstancePath,
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
        d.UdtInstancePath,
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
    UdtInstancePath NVARCHAR(400), SortOrder INT);
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

### Task 4: `Parts.Item_SetPlcId` + `Parts.Item_GetPlcId`

**Files:**
- Create: `sql/migrations/repeatable/R__Parts_Item_SetPlcId.sql`
- Create: `sql/migrations/repeatable/R__Parts_Item_GetPlcId.sql`
- Test: `sql/tests/0037_PlcIntegration/030_Item_PlcId.sql`

**Interfaces:**
- Consumes: `Parts.Item` (with the new `PlcId INT NULL` column from Task 1).
- Produces:
  - `Parts.Item_SetPlcId(@ItemId BIGINT, @PlcId INT, @AppUserId BIGINT)` → status row `Status, Message`. Requires an active Item. Sets `Item.PlcId` (the stable per-part PLC/vision recipe integer). **No uniqueness constraint** — the assembly-out FIFO queue fixes the expected part at run time (spec §4.3).
  - `Parts.Item_GetPlcId(@ItemId BIGINT)` → row `PlcId`. Empty = unset / not found.

The watcher's FIFO validation (front-of-assembly-out-queue → expected LOT → `Item_GetPlcId` → compare vision code) is **Plan 3**; the FIFO read (`Lots.Lot_GetWipQueueByLocation`) already exists. This task only adds the column's set/get.

- [ ] **Step 1: Write the failing test** — `sql/tests/0037_PlcIntegration/030_Item_PlcId.sql`

```sql
-- =============================================
-- File: 0037_PlcIntegration/030_Item_PlcId.sql
-- Tests Item_SetPlcId + Item_GetPlcId. Borrows the lowest-Id active Item and
-- resets its PlcId to NULL at the end (Item is a real seed row, not throwaway).
-- =============================================
EXEC test.BeginTestFile @FileName = N'0037_PlcIntegration/030_Item_PlcId.sql';
GO

-- Test 1: set PlcId = 2 on the lowest-Id item
DECLARE @S BIT, @M NVARCHAR(500);
DECLARE @itemId BIGINT = (SELECT TOP 1 Id FROM Parts.Item WHERE DeprecatedAt IS NULL ORDER BY Id);
CREATE TABLE #R1 (Status BIT, Message NVARCHAR(500));
INSERT INTO #R1 EXEC Parts.Item_SetPlcId @ItemId=@itemId, @PlcId=2, @AppUserId=1;
SELECT @S=Status, @M=Message FROM #R1; DROP TABLE #R1;
EXEC test.Assert_IsEqual @TestName=N'SetPlcId=2: status 1', @Expected=N'1', @Actual=CAST(@S AS NVARCHAR(1));
EXEC test.Assert_IsEqual @TestName=N'SetPlcId=2: column updated', @Expected=N'2',
    @Actual=CAST((SELECT PlcId FROM Parts.Item WHERE Id=@itemId) AS NVARCHAR(10));
GO

-- Test 2: GetPlcId returns 2
DECLARE @itemId BIGINT = (SELECT TOP 1 Id FROM Parts.Item WHERE DeprecatedAt IS NULL ORDER BY Id);
CREATE TABLE #G (PlcId INT);
INSERT INTO #G EXEC Parts.Item_GetPlcId @ItemId=@itemId;
DECLARE @code INT = (SELECT TOP 1 PlcId FROM #G); DROP TABLE #G;
EXEC test.Assert_IsEqual @TestName=N'GetPlcId = 2', @Expected=N'2', @Actual=CAST(@code AS NVARCHAR(10));
GO

-- Test 3: set on a non-existent item is rejected
DECLARE @S BIT, @M NVARCHAR(500);
CREATE TABLE #R3 (Status BIT, Message NVARCHAR(500));
INSERT INTO #R3 EXEC Parts.Item_SetPlcId @ItemId=999999999, @PlcId=1, @AppUserId=1;
SELECT @S=Status, @M=Message FROM #R3; DROP TABLE #R3;
EXEC test.Assert_IsEqual @TestName=N'SetPlcId bad item: status 0', @Expected=N'0', @Actual=CAST(@S AS NVARCHAR(1));
GO

-- Cleanup: reset the borrowed item's PlcId
DECLARE @itemId BIGINT = (SELECT TOP 1 Id FROM Parts.Item WHERE DeprecatedAt IS NULL ORDER BY Id);
UPDATE Parts.Item SET PlcId = NULL WHERE Id = @itemId;
GO

EXEC test.PrintSummary;
GO
```

- [ ] **Step 2: Run to verify it fails**

Run: `cd sql/tests; ./Run-Tests.ps1 -Filter "0037"`
Expected: FAIL — `Could not find stored procedure 'Parts.Item_SetPlcId'`.

- [ ] **Step 3: Write `R__Parts_Item_SetPlcId.sql`**

```sql
-- =============================================
-- Procedure:   Parts.Item_SetPlcId
-- Description: Set the stable per-part PLC/vision recipe integer on an Item.
--   No uniqueness constraint - the assembly-out FIFO queue fixes the expected
--   part at run time (spec 4.3).
-- Result set: Status BIT, Message NVARCHAR(500).
-- =============================================
CREATE OR ALTER PROCEDURE Parts.Item_SetPlcId
    @ItemId    BIGINT,
    @PlcId     INT,
    @AppUserId BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Status BIT = 0, @Message NVARCHAR(500) = N'Unknown error';
    DECLARE @ProcName NVARCHAR(200) = N'Parts.Item_SetPlcId';
    DECLARE @Params NVARCHAR(MAX) = (SELECT @ItemId AS ItemId, @PlcId AS PlcId
        FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

    BEGIN TRY
        IF @ItemId IS NULL OR @PlcId IS NULL OR @AppUserId IS NULL
        BEGIN
            SET @Message = N'Required parameter missing.';
            EXEC Audit.Audit_LogFailure @AppUserId=@AppUserId, @LogEntityTypeCode=N'Item',
                @EntityId=@ItemId, @LogEventTypeCode=N'Updated', @FailureReason=@Message,
                @ProcedureName=@ProcName, @AttemptedParameters=@Params;
            SELECT @Status AS Status, @Message AS Message; RETURN;
        END

        IF NOT EXISTS (SELECT 1 FROM Parts.Item WHERE Id=@ItemId AND DeprecatedAt IS NULL)
        BEGIN
            SET @Message = N'Item not found or deprecated.';
            EXEC Audit.Audit_LogFailure @AppUserId=@AppUserId, @LogEntityTypeCode=N'Item',
                @EntityId=@ItemId, @LogEventTypeCode=N'Updated', @FailureReason=@Message,
                @ProcedureName=@ProcName, @AttemptedParameters=@Params;
            SELECT @Status AS Status, @Message AS Message; RETURN;
        END

        DECLARE @Activity NVARCHAR(500) = Audit.ufn_TruncateActivity(
            N'Item ' + CAST(@ItemId AS NVARCHAR(20)) + N' ' + Audit.ufn_MidDot()
            + N' Set PlcId = ' + CAST(@PlcId AS NVARCHAR(10)));

        BEGIN TRANSACTION;
        UPDATE Parts.Item SET PlcId=@PlcId WHERE Id=@ItemId;

        EXEC Audit.Audit_LogConfigChange @AppUserId=@AppUserId, @LogEntityTypeCode=N'Item',
            @EntityId=@ItemId, @LogEventTypeCode=N'Updated', @LogSeverityCode=N'Info',
            @Description=@Activity, @OldValue=NULL, @NewValue=@Params;
        COMMIT TRANSACTION;

        SET @Status=1; SET @Message=N'PLC ID set.';
        SELECT @Status AS Status, @Message AS Message;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        DECLARE @ErrMsg NVARCHAR(4000)=ERROR_MESSAGE(), @ErrSev INT=ERROR_SEVERITY(), @ErrState INT=ERROR_STATE();
        SET @Status=0; SET @Message=N'Unexpected error: ' + LEFT(@ErrMsg,400);
        BEGIN TRY
            EXEC Audit.Audit_LogFailure @AppUserId=@AppUserId, @LogEntityTypeCode=N'Item',
                @EntityId=@ItemId, @LogEventTypeCode=N'Updated', @FailureReason=@Message,
                @ProcedureName=@ProcName, @AttemptedParameters=@Params;
        END TRY BEGIN CATCH END CATCH
        SELECT @Status AS Status, @Message AS Message;
        RAISERROR(@ErrMsg, @ErrSev, @ErrState);
    END CATCH
END;
GO
```

- [ ] **Step 4: Write `R__Parts_Item_GetPlcId.sql`**

```sql
-- =============================================
-- Procedure:   Parts.Item_GetPlcId
-- Description: Read an Item's stable PLC/vision recipe integer. The watcher
--   resolves the expected LOT from the assembly-out FIFO queue
--   (Lots.Lot_GetWipQueueByLocation), then reads that LOT's Item PlcId via this
--   proc. Read proc - empty result = unset / not found.
-- =============================================
CREATE OR ALTER PROCEDURE Parts.Item_GetPlcId
    @ItemId BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    SELECT PlcId
    FROM Parts.Item
    WHERE Id = @ItemId
      AND DeprecatedAt IS NULL
      AND PlcId IS NOT NULL;
END;
GO
```

- [ ] **Step 5: Run to verify it passes**

Run: `cd sql/tests; ./Run-Tests.ps1 -Filter "0037"`
Expected: PASS — `030_Item_PlcId.sql` shows 4 passed, 0 failed.

- [ ] **Step 6: Commit**

```bash
git add sql/migrations/repeatable/R__Parts_Item_SetPlcId.sql sql/migrations/repeatable/R__Parts_Item_GetPlcId.sql sql/tests/0037_PlcIntegration/030_Item_PlcId.sql
git commit -m "feat(plc): Item.PlcId set + get (FIFO-validated part-code)"
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
- **Plan 3 — Watchers + onStartup + Config-Tool editor:** the 4 gateway watcher modules (edge-subscribed, mapped to procs — incl. the tray-inspection **FIFO validation**: front-of-assembly-out-queue → expected LOT → `Item_GetPlcId` → compare vision code), `onStartup` resolving `TerminalPlcDevice_GetByTerminal` into `session.custom.plcDevices`, and the Terminal→device mapping editor UI (per-terminal list; ConfirmUnsaved) + the `PlcId` field on the Item Master Identity surface.

---

## Self-Review

**Spec coverage (spec §4 + §5 SQL scope):** §4.1 PlcDeviceType → Task 1. §4.2 TerminalPlcDevice (thin pointer) + Save/Deprecate/GetByTerminal procs → Tasks 1–3. §4.3 `Item.PlcId` + set/get (FIFO-validated) → Tasks 1, 4; the FIFO validation *logic* is Plan 3 (it reuses the existing `Lot_GetWipQueueByLocation`). §5 serial validate surface (`SerializedPart_GetBySerial` + `@SerialNumber` on Mint) → Task 5. `onStartup`, watchers, UDTs, Config editor → deferred to Plans 2–3.

**Placeholder scan:** No TBD/TODO in steps. One documented verification point (not a placeholder): the exact text span in `SerializedPart_Mint` to replace (Task 5 identifies it by its start/end statements). Task 4 no longer depends on the `Parts.Item` display-column name (it only touches `Id` + the new `PlcId`).

**Type consistency:** `TerminalPlcDevice_Save` returns `Status,Message,NewId` and takes `@UdtInstancePath` (no addressing params); `_Deprecate` returns `Status,Message`; `_GetByTerminal` returns `Id, TerminalLocationId, PlcDeviceTypeId, DeviceTypeCode, DeviceTypeName, DeviceCode, UdtInstancePath, SortOrder` — matched by the tests' temp tables. `Item_SetPlcId` returns `Status,Message`; `Item_GetPlcId` returns `PlcId`. `SerializedPart_Mint` keeps its 4-column `Status,Message,NewId,SerialNumber` shape; test temp tables match. Audit entity codes `TerminalPlcDevice` (new, Id 25) / `Item` (existing 5) / `SerializedPart` (existing 24) match the seeded `Audit.LogEntityType`.
