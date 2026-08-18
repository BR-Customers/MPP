# CRT Container Validation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let an assembly-out terminal run in Controlled Run Tag mode so completed containers claim their AIM Shipper ID but do not post it to Honda until a second person validates the container behind elevated access.

**Architecture:** A `CrtEnabled` attribute on the terminal makes `Assembly_CompleteTray` mint the finished-good LOT with the existing `Lots.Lot.CrtActive` flag set. That flag is the pending-validation marker. The AIM claim is untouched; the post is suppressed in two places — the synchronous call in `Container.complete`, and `AimShipperIdPool_ListUnposted`, which is the single query behind the 60-second retry sweep, the owed-backlog screen and the age escalation. Validating clears the flag via the existing `Lot_ClearCrt` and then posts.

**Tech Stack:** SQL Server 2022 (versioned + repeatable migrations, `test.Assert_*` suite), Ignition 8.3 Perspective (file-based views, Jython project scripts, named queries).

**Spec:** `docs/superpowers/specs/2026-08-14-crt-container-validation-design.md`

## Global Constraints

- **No new tables and no new columns.** The only schema-adjacent change permitted is one `Location.LocationAttributeDefinition` *row* (a data insert into the existing polymorphic model).
- All stored procedures follow `sql/scripts/_TEMPLATE_stored_procedure.sql`: three-tier error hierarchy, `RAISERROR` (not `THROW`) in CATCH, nested TRY/CATCH for failure logging, schema-qualified references.
- **FDS-11-011:** no `OUTPUT` parameters. Mutations declare `@Status` / `@Message` as locals and end **every** exit path with `SELECT @Status AS Status, @Message AS Message;`. Reads return one result set; empty means not found.
- **All rejecting validations run BEFORE `BEGIN TRANSACTION`.** A `ROLLBACK` inside a proc invoked via `INSERT-EXEC` throws Msg 3915.
- A proc captured via `INSERT … EXEC` must NOT `EXEC` another status-row proc. Where that would be needed, inline the sub-mutation and comment it as a mirror of its source.
- Timestamps stored UTC, displayed Eastern: `CAST(<col> AT TIME ZONE 'UTC' AT TIME ZONE 'Eastern Standard Time' AS DATETIME2(3))`. **Cast to `DATETIME2(3)`** — a raw `datetimeoffset` breaks the Ignition JDBC result read.
- Seed/data string values are **ASCII-only**.
- Audit descriptions use the `<SUBJECT> · <CATEGORY> · <ACTION>` shape via `Audit.ufn_MidDot()`, with resolved-name FK sub-objects in Old/New JSON, capped by `Audit.ufn_TruncateActivity()`.
- SQL is applied with `sqlcmd -S localhost -d <db> -E -b -I -C -i <file>`. The `-I` flag is mandatory (filtered indexes reject `QUOTED_IDENTIFIER OFF`).
- Perspective conditional visibility uses `position.display`, never `meta.visible` — `meta.visible:false` still occupies flex space.
- **`EXEC` parameters must be literals or `@variables` - never an inline subquery.** `@Actual = (SELECT ...)` is invalid T-SQL and fails regardless of whether the target proc exists. Hoist the value into a local first: `DECLARE @Act NVARCHAR(10) = (SELECT ...);` then `@Actual = @Act`. (Found during Task 1; every test fixture in this plan has been corrected.)
- Run the SQL suite with `sql\tests\Run-Tests.ps1` (defaults to `MPP_MES_Test`). A green run is `Failed: 0` **and** zero `ERROR running` lines.

---

## Task 1: `CrtEnabled` terminal attribute and its setter

**Files:**
- Create: `sql/migrations/versioned/0058_crt_terminal_attribute.sql`
- Create: `sql/migrations/repeatable/R__Location_Terminal_SetCrtEnabled.sql`
- Create: `ignition/projects/Core/ignition/named-query/location/Terminal_SetCrtEnabled/query.sql`
- Create: `ignition/projects/Core/ignition/named-query/location/Terminal_SetCrtEnabled/resource.json`
- Modify: `ignition/projects/Core/ignition/script-python/BlueRidge/Location/ClosureMode/code.py`
- Test: `sql/tests/0056_CrtValidation/010_schema.sql`
- Test: `sql/tests/0056_CrtValidation/020_Terminal_SetCrtEnabled.sql`

**Interfaces:**
- Produces: `Location.Terminal_SetCrtEnabled(@TerminalLocationId BIGINT, @Enabled BIT, @AppUserId BIGINT)` returning one row `(Status BIT, Message NVARCHAR(500))`.
- Produces: `BlueRidge.Location.ClosureMode.setCrt(terminalLocationId, enabled, adAccount, password) -> {Status, Message}`.
- Consumes: `BlueRidge.Location.AppUser.elevate(adAccount, password, actionCode, terminalLocationId) -> {success, appUserId, message}` (existing).

- [ ] **Step 1: Write the failing schema test**

Create `sql/tests/0056_CrtValidation/010_schema.sql`:

```sql
-- =============================================
-- File: 0056_CrtValidation/010_schema.sql
-- Desc: Migration 0058 - CrtEnabled terminal attribute definition (LTD 7).
-- =============================================
EXEC test.BeginTestFile @FileName = N'0056_CrtValidation/010_schema.sql';
GO

DECLARE @Exists NVARCHAR(10) = CASE WHEN EXISTS (
    SELECT 1 FROM Location.LocationAttributeDefinition
    WHERE LocationTypeDefinitionId = 7 AND AttributeName = N'CrtEnabled' AND DeprecatedAt IS NULL)
    THEN N'1' ELSE N'0' END;
EXEC test.Assert_IsEqual
    @TestName = N'[0058] CrtEnabled attribute definition exists on LTD 7',
    @Expected = N'1', @Actual = @Exists;

DECLARE @Default NVARCHAR(20) = (SELECT DefaultValue FROM Location.LocationAttributeDefinition
    WHERE LocationTypeDefinitionId = 7 AND AttributeName = N'CrtEnabled' AND DeprecatedAt IS NULL);
EXEC test.Assert_IsEqual
    @TestName = N'[0058] CrtEnabled defaults to 0 (off)',
    @Expected = N'0', @Actual = @Default;

DECLARE @Type NVARCHAR(20) = (SELECT DataType FROM Location.LocationAttributeDefinition
    WHERE LocationTypeDefinitionId = 7 AND AttributeName = N'CrtEnabled' AND DeprecatedAt IS NULL);
EXEC test.Assert_IsEqual
    @TestName = N'[0058] CrtEnabled is NVARCHAR (0/1 like HasBarcodeScanner)',
    @Expected = N'NVARCHAR', @Actual = @Type;
GO

EXEC test.EndTestFile;
```

- [ ] **Step 2: Run it to verify it fails**

Run: `sqlcmd -S localhost -d MPP_MES_Test -E -b -I -C -i sql/tests/0056_CrtValidation/010_schema.sql`
Expected: three `FAIL:` lines (attribute does not exist yet).

- [ ] **Step 3: Write the migration**

Create `sql/migrations/versioned/0058_crt_terminal_attribute.sql`:

```sql
-- ============================================================
-- Migration: 0058_crt_terminal_attribute.sql
-- Author:    Blue Ridge Automation
-- Date:      2026-08-14
-- Description: Controlled Run Tag capability on an assembly-out terminal.
--   Adds ONE Location.LocationAttributeDefinition row (LTD 7 = Terminal) --
--   a data insert into the existing polymorphic location model, NOT DDL.
--   Mirrors 0041, which added CurrentClosureMethod and VisionAppUrl the same way.
--
--   '0' / '1' like HasBarcodeScanner. An absent attribute reads as '0'.
-- ============================================================
IF EXISTS (SELECT 1 FROM dbo.SchemaVersion WHERE MigrationId = N'0058_crt_terminal_attribute')
BEGIN PRINT 'Migration 0058 already applied -- skipping.'; RETURN; END
GO

IF NOT EXISTS (SELECT 1 FROM Location.LocationAttributeDefinition
               WHERE LocationTypeDefinitionId = 7 AND AttributeName = N'CrtEnabled' AND DeprecatedAt IS NULL)
    INSERT INTO Location.LocationAttributeDefinition
        (LocationTypeDefinitionId, AttributeName, DataType, IsRequired, DefaultValue, Uom, SortOrder, Description)
    VALUES
        (7, N'CrtEnabled', N'NVARCHAR', 0, N'0', NULL,
         (SELECT ISNULL(MAX(SortOrder), 0) + 1 FROM Location.LocationAttributeDefinition WHERE LocationTypeDefinitionId = 7),
         N'Controlled Run Tag active at this assembly-out terminal: containers complete pending a second-person validation before their AIM Shipper ID is posted.');
GO

-- Guarded like 0053/0054: the top-of-file RETURN only exits its OWN batch, so after
-- the next GO the remaining batches run regardless.
IF NOT EXISTS (SELECT 1 FROM dbo.SchemaVersion WHERE MigrationId = N'0058_crt_terminal_attribute')
    INSERT INTO dbo.SchemaVersion (MigrationId, Description)
    VALUES (N'0058_crt_terminal_attribute', N'Location.LocationAttributeDefinition row: CrtEnabled on LTD 7 (Terminal).');
GO
PRINT 'Migration 0058 (crt_terminal_attribute) applied.';
GO
```

- [ ] **Step 4: Apply it and re-run the test**

Run:
```bash
sqlcmd -S localhost -d MPP_MES_Test -E -b -I -C -i sql/migrations/versioned/0058_crt_terminal_attribute.sql
sqlcmd -S localhost -d MPP_MES_Test -E -b -I -C -i sql/tests/0056_CrtValidation/010_schema.sql
```
Expected: `Migration 0058 (crt_terminal_attribute) applied.` then three `PASS:` lines.

- [ ] **Step 5: Write the failing setter test**

Create `sql/tests/0056_CrtValidation/020_Terminal_SetCrtEnabled.sql`:

```sql
-- =============================================
-- File: 0056_CrtValidation/020_Terminal_SetCrtEnabled.sql
-- Desc: Location.Terminal_SetCrtEnabled - upsert the CrtEnabled attribute, audited.
-- =============================================
EXEC test.BeginTestFile @FileName = N'0056_CrtValidation/020_Terminal_SetCrtEnabled.sql';
GO

DECLARE @Term BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MA1-FP6NA-AOUT');
DECLARE @Base INT = (SELECT COUNT(*) FROM Audit.ConfigLog);

DECLARE @R1 TABLE (Status BIT, Message NVARCHAR(500));
INSERT INTO @R1 EXEC Location.Terminal_SetCrtEnabled @TerminalLocationId = @Term, @Enabled = 1, @AppUserId = 1;
DECLARE @Act1 NVARCHAR(10) = (SELECT CAST(Status AS NVARCHAR(10)) FROM @R1);
EXEC test.Assert_IsEqual @TestName = N'[SetCrt] enable returns Status 1',
    @Expected = N'1', @Actual = @Act1;

DECLARE @V1 NVARCHAR(20) = (SELECT la.AttributeValue FROM Location.LocationAttribute la
    JOIN Location.LocationAttributeDefinition ad ON ad.Id = la.LocationAttributeDefinitionId
    WHERE la.LocationId = @Term AND ad.AttributeName = N'CrtEnabled');
EXEC test.Assert_IsEqual @TestName = N'[SetCrt] attribute value is 1', @Expected = N'1', @Actual = @V1;

DECLARE @Audited NVARCHAR(10) = CASE WHEN (SELECT COUNT(*) FROM Audit.ConfigLog) > @Base THEN N'1' ELSE N'0' END;
EXEC test.Assert_IsEqual @TestName = N'[SetCrt] writes a ConfigLog row', @Expected = N'1', @Actual = @Audited;

DECLARE @R2 TABLE (Status BIT, Message NVARCHAR(500));
INSERT INTO @R2 EXEC Location.Terminal_SetCrtEnabled @TerminalLocationId = @Term, @Enabled = 0, @AppUserId = 1;
DECLARE @V2 NVARCHAR(20) = (SELECT la.AttributeValue FROM Location.LocationAttribute la
    JOIN Location.LocationAttributeDefinition ad ON ad.Id = la.LocationAttributeDefinitionId
    WHERE la.LocationId = @Term AND ad.AttributeName = N'CrtEnabled');
EXEC test.Assert_IsEqual @TestName = N'[SetCrt] disable flips it back to 0', @Expected = N'0', @Actual = @V2;

DECLARE @R3 TABLE (Status BIT, Message NVARCHAR(500));
INSERT INTO @R3 EXEC Location.Terminal_SetCrtEnabled @TerminalLocationId = 999999999, @Enabled = 1, @AppUserId = 1;
DECLARE @Act2 NVARCHAR(10) = (SELECT CAST(Status AS NVARCHAR(10)) FROM @R3);
EXEC test.Assert_IsEqual @TestName = N'[SetCrt] unknown terminal rejected, Status 0',
    @Expected = N'0', @Actual = @Act2;
GO

EXEC test.EndTestFile;
```

- [ ] **Step 6: Run it to verify it fails**

Run: `sqlcmd -S localhost -d MPP_MES_Test -E -b -I -C -i sql/tests/0056_CrtValidation/020_Terminal_SetCrtEnabled.sql`
Expected: aborts with `Could not find stored procedure 'Location.Terminal_SetCrtEnabled'`.

- [ ] **Step 7: Write the setter proc**

Read `sql/migrations/repeatable/R__Location_Terminal_SetClosureMethod.sql` first and mirror its structure exactly — same validation order, same audit shape, same failure-logging nest. Create `sql/migrations/repeatable/R__Location_Terminal_SetCrtEnabled.sql`:

```sql
-- ============================================================
-- Repeatable:  R__Location_Terminal_SetCrtEnabled.sql
-- Author:      Blue Ridge Automation
-- Modified:    2026-08-14
-- Version:     1.0
-- Description: Sets the Controlled Run Tag capability on an assembly-out terminal
--              (Location.LocationAttribute 'CrtEnabled', '0'/'1'). Modelled on
--              Location.Terminal_SetClosureMethod. The AD elevation is the UI's
--              FDS-04-007 concern; this proc takes @AppUserId as attribution.
--
--              All rejects run BEFORE BEGIN TRANSACTION (INSERT-EXEC / Msg 3915).
-- ============================================================
CREATE OR ALTER PROCEDURE Location.Terminal_SetCrtEnabled
    @TerminalLocationId BIGINT,
    @Enabled            BIT,
    @AppUserId          BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Status  BIT           = 0;
    DECLARE @Message NVARCHAR(500) = N'Unknown error';
    DECLARE @ProcName NVARCHAR(200) = N'Location.Terminal_SetCrtEnabled';
    DECLARE @Params   NVARCHAR(MAX) = (
        SELECT @TerminalLocationId AS TerminalLocationId, @Enabled AS Enabled, @AppUserId AS AppUserId
        FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

    DECLARE @AttrDefId BIGINT, @ExistingId BIGINT, @OldValue NVARCHAR(255), @TermCode NVARCHAR(50);
    DECLARE @NewValue NVARCHAR(20) = CASE WHEN @Enabled = 1 THEN N'1' ELSE N'0' END;

    BEGIN TRY
        IF @TerminalLocationId IS NULL OR @Enabled IS NULL OR @AppUserId IS NULL
        BEGIN
            SET @Message = N'Required parameter missing (TerminalLocationId, Enabled, AppUserId).';
            SELECT @Status AS Status, @Message AS Message; RETURN;
        END

        SELECT @TermCode = Code FROM Location.Location
        WHERE Id = @TerminalLocationId AND LocationTypeDefinitionId = 7 AND DeprecatedAt IS NULL;
        IF @TermCode IS NULL
        BEGIN
            SET @Message = N'Terminal not found (or not a Terminal location).';
            SELECT @Status AS Status, @Message AS Message; RETURN;
        END

        SELECT TOP 1 @AttrDefId = Id FROM Location.LocationAttributeDefinition
        WHERE LocationTypeDefinitionId = 7 AND AttributeName = N'CrtEnabled' AND DeprecatedAt IS NULL
        ORDER BY Id;
        IF @AttrDefId IS NULL
        BEGIN
            SET @Message = N'CrtEnabled attribute definition missing (migration 0058 not applied).';
            SELECT @Status AS Status, @Message AS Message; RETURN;
        END

        SELECT @ExistingId = Id, @OldValue = AttributeValue FROM Location.LocationAttribute
        WHERE LocationId = @TerminalLocationId AND LocationAttributeDefinitionId = @AttrDefId;

        BEGIN TRANSACTION;

        IF @ExistingId IS NULL
            INSERT INTO Location.LocationAttribute (LocationId, LocationAttributeDefinitionId, AttributeValue, CreatedAt)
            VALUES (@TerminalLocationId, @AttrDefId, @NewValue, SYSUTCDATETIME());
        ELSE
            UPDATE Location.LocationAttribute
            SET AttributeValue = @NewValue, UpdatedAt = SYSUTCDATETIME(), UpdatedByUserId = @AppUserId
            WHERE Id = @ExistingId;

        DECLARE @Descr NVARCHAR(500) = Audit.ufn_TruncateActivity(
            @TermCode + N' ' + Audit.ufn_MidDot() + N' Controlled Run Tag ' + Audit.ufn_MidDot() + N' '
            + CASE WHEN @Enabled = 1 THEN N'Enabled' ELSE N'Disabled' END);
        DECLARE @OldJson NVARCHAR(MAX) = (SELECT ISNULL(@OldValue, N'0') AS CrtEnabled FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);
        DECLARE @NewJson NVARCHAR(MAX) = (SELECT @NewValue AS CrtEnabled FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

        EXEC Audit.Audit_LogConfigChange
            @AppUserId = @AppUserId, @LogEntityTypeCode = N'Location', @EntityId = @TerminalLocationId,
            @LogEventTypeCode = N'Updated', @LogSeverityCode = N'Info',
            @Description = @Descr, @OldValue = @OldJson, @NewValue = @NewJson;

        COMMIT TRANSACTION;

        SET @Status = 1;
        SET @Message = N'Controlled Run Tag ' + CASE WHEN @Enabled = 1 THEN N'enabled.' ELSE N'disabled.' END;
        SELECT @Status AS Status, @Message AS Message;
        RETURN;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        DECLARE @ErrMsg NVARCHAR(4000) = ERROR_MESSAGE();
        DECLARE @ErrSev INT = ERROR_SEVERITY();
        DECLARE @ErrState INT = ERROR_STATE();
        SET @Status = 0;
        SET @Message = N'Unexpected error: ' + LEFT(@ErrMsg, 400);
        BEGIN TRY
            EXEC Audit.Audit_LogFailure @AppUserId = @AppUserId, @LogEntityTypeCode = N'Location',
                @EntityId = @TerminalLocationId, @LogEventTypeCode = N'Updated', @FailureReason = @Message,
                @ProcedureName = @ProcName, @AttemptedParameters = @Params;
        END TRY
        BEGIN CATCH
        END CATCH
        SELECT @Status AS Status, @Message AS Message;
        RAISERROR(@ErrMsg, @ErrSev, @ErrState);
    END CATCH
END;
GO
```

**Before writing:** confirm the exact `Audit.Audit_LogConfigChange` parameter list and the valid `@LogEntityTypeCode` / `@LogEventTypeCode` values by reading `sql/migrations/repeatable/R__Location_Terminal_SetClosureMethod.sql`. Match it; do not invent codes.

- [ ] **Step 8: Apply and re-run both tests**

Run:
```bash
sqlcmd -S localhost -d MPP_MES_Test -E -b -I -C -i sql/migrations/repeatable/R__Location_Terminal_SetCrtEnabled.sql
sqlcmd -S localhost -d MPP_MES_Test -E -b -I -C -i sql/tests/0056_CrtValidation/020_Terminal_SetCrtEnabled.sql
```
Expected: 5 `PASS:`, `Failed: 0`.

- [ ] **Step 9: Add the named query**

Create `ignition/projects/Core/ignition/named-query/location/Terminal_SetCrtEnabled/query.sql`:

```sql
EXEC Location.Terminal_SetCrtEnabled
    @TerminalLocationId = :terminalLocationId,
    @Enabled            = :enabled,
    @AppUserId          = :appUserId
```

Create `resource.json` by copying `ignition/projects/Core/ignition/named-query/location/Terminal_SetClosureMethod/resource.json` verbatim, then adjust only the parameter list to `terminalLocationId` (Int8), `enabled` (Int2/Boolean per that file's convention for BIT), `appUserId` (Int8). Read the sibling file to get the exact `sqlType` codes — do not guess them.

- [ ] **Step 10: Add the Python wrapper**

Append to `ignition/projects/Core/ignition/script-python/BlueRidge/Location/ClosureMode/code.py`:

```python
def setCrt(terminalLocationId, enabled, adAccount, password):
    """Elevate for 'Changeover', then set the terminal's Controlled Run Tag flag.
       Same stateless per-action elevation as changeover(): the elevated appUserId is
       passed straight to the proc, never stored on the session."""
    terminalLocationId = BlueRidge.Common.Util.extractQualifiedValues(terminalLocationId)
    enabled = BlueRidge.Common.Util.extractQualifiedValues(enabled)

    el = BlueRidge.Location.AppUser.elevate(adAccount, password, "Changeover", terminalLocationId)
    if not el or not el.get("success"):
        return {"Status": 0, "Message": (el or {}).get("message") or "Elevation failed."}

    return BlueRidge.Common.Db.execMutation(
        "location/Terminal_SetCrtEnabled",
        {
            "terminalLocationId": terminalLocationId,
            "enabled":            1 if enabled else 0,
            "appUserId":          el.get("appUserId"),
        },
    )
```

Do **not** add an `import BlueRidge...` line — a local import shadows the package and breaks earlier `BlueRidge.*` references in the same module.

- [ ] **Step 11: Commit**

```bash
git add sql/migrations/versioned/0058_crt_terminal_attribute.sql sql/migrations/repeatable/R__Location_Terminal_SetCrtEnabled.sql sql/tests/0056_CrtValidation ignition/projects/Core/ignition/named-query/location/Terminal_SetCrtEnabled ignition/projects/Core/ignition/script-python/BlueRidge/Location/ClosureMode/code.py
git commit -m "feat(crt): CrtEnabled terminal attribute + elevated setter"
```

---

## Task 2: Mark the finished-good LOT at tray completion

**Files:**
- Modify: `sql/migrations/repeatable/R__Workorder_Assembly_CompleteTray.sql` (the `INSERT INTO Lots.Lot` around line 270)
- Test: `sql/tests/0056_CrtValidation/030_CompleteTray_marks_crt.sql`

**Interfaces:**
- Consumes: the `CrtEnabled` attribute from Task 1.
- Produces: finished-good LOTs carrying `Lots.Lot.CrtActive = 1` when the completing terminal has CRT on. Every later task keys off this flag.

- [ ] **Step 1: Write the failing test**

Create `sql/tests/0056_CrtValidation/030_CompleteTray_marks_crt.sql`. This is the behavioural core, and it also pins the interaction that keeps 200% inspection out of the feature.

```sql
-- =============================================
-- File: 0056_CrtValidation/030_CompleteTray_marks_crt.sql
-- Desc: Assembly_CompleteTray mints the FG LOT with CrtActive = 1 when the
--       terminal has CrtEnabled = '1', and 0 when it does not.
--
--       This file does NOT complete a container, so the FG LOT is still open here.
--       The guard that CRT never drags in 200% inspection lives in 040 (below),
--       where Container_Complete actually runs and closes the LOT.
-- =============================================
EXEC test.BeginTestFile @FileName = N'0056_CrtValidation/030_CompleteTray_marks_crt.sql';
GO

DELETE FROM Lots.AimShipperIdPool;
GO

-- Fixture: reuse the seeded 6NA assembly chain at MA1-FP6NA.
DECLARE @Cell BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MA1-FP6NA');
DECLARE @Term BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MA1-FP6NA-AOUT');
DECLARE @Fg   BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'12270-6NA -0001');

-- CRT OFF -> CrtActive 0
DECLARE @Off TABLE (Status BIT, Message NVARCHAR(500), FinishedGoodLotId BIGINT,
                    ContainerId BIGINT, ContainerTrayId BIGINT, ContainerFull BIT);
DECLARE @R0 TABLE (Status BIT, Message NVARCHAR(500));
INSERT INTO @R0 EXEC Location.Terminal_SetCrtEnabled @TerminalLocationId = @Term, @Enabled = 0, @AppUserId = 1;

INSERT INTO @Off EXEC Workorder.Assembly_CompleteTray
    @FinishedGoodItemId = @Fg, @PieceCount = 1, @CellLocationId = @Cell,
    @ClosureMethod = N'ByCount', @AppUserId = 1, @TerminalLocationId = @Term;
DECLARE @LotOff BIGINT = (SELECT FinishedGoodLotId FROM @Off);
DECLARE @Act3 NVARCHAR(10) = (SELECT CAST(CrtActive AS NVARCHAR(10)) FROM Lots.Lot WHERE Id = @LotOff);
EXEC test.Assert_IsEqual @TestName = N'[CrtMint] CRT off -> FG LOT CrtActive = 0',
    @Expected = N'0', @Actual = @Act3;

-- CRT ON -> CrtActive 1
DECLARE @R1 TABLE (Status BIT, Message NVARCHAR(500));
INSERT INTO @R1 EXEC Location.Terminal_SetCrtEnabled @TerminalLocationId = @Term, @Enabled = 1, @AppUserId = 1;

DECLARE @On TABLE (Status BIT, Message NVARCHAR(500), FinishedGoodLotId BIGINT,
                   ContainerId BIGINT, ContainerTrayId BIGINT, ContainerFull BIT);
INSERT INTO @On EXEC Workorder.Assembly_CompleteTray
    @FinishedGoodItemId = @Fg, @PieceCount = 1, @CellLocationId = @Cell,
    @ClosureMethod = N'ByCount', @AppUserId = 1, @TerminalLocationId = @Term;
DECLARE @LotOn BIGINT = (SELECT FinishedGoodLotId FROM @On);
DECLARE @Act4 NVARCHAR(10) = (SELECT CAST(CrtActive AS NVARCHAR(10)) FROM Lots.Lot WHERE Id = @LotOn);
EXEC test.Assert_IsEqual @TestName = N'[CrtMint] CRT on -> FG LOT CrtActive = 1',
    @Expected = N'1', @Actual = @Act4;

-- reset the terminal so later files start clean
DECLARE @R2 TABLE (Status BIT, Message NVARCHAR(500));
INSERT INTO @R2 EXEC Location.Terminal_SetCrtEnabled @TerminalLocationId = @Term, @Enabled = 0, @AppUserId = 1;
GO

EXEC test.EndTestFile;
```

- [ ] **Step 2: Run it to verify it fails**

Run: `sqlcmd -S localhost -d MPP_MES_Test -E -b -I -C -i sql/tests/0056_CrtValidation/030_CompleteTray_marks_crt.sql`
Expected: the `CRT on` assert FAILs with `Expected: 1  Actual: 0`.

- [ ] **Step 3: Read the CrtEnabled attribute in the proc**

In `sql/migrations/repeatable/R__Workorder_Assembly_CompleteTray.sql`, add this declaration alongside the other `DECLARE`s near the top of the proc body (with the `@FinishedGoodLotId` group around line 63):

```sql
    -- Controlled Run Tag: when the completing terminal has CrtEnabled = '1', the FG LOT
    -- is minted CRT-active so the container's AIM post is held for a second-person
    -- validation. Absent attribute reads as '0'. NULL @TerminalLocationId -> off.
    DECLARE @CrtActive BIT = 0;
```

- [ ] **Step 4: Populate it before the INSERT**

Immediately **before** the `INSERT INTO Lots.Lot` block (the one that sets `@FinishedGoodLotId`), add:

```sql
        SELECT @CrtActive = CASE WHEN la.AttributeValue = N'1' THEN 1 ELSE 0 END
        FROM Location.LocationAttribute la
        JOIN Location.LocationAttributeDefinition ad ON ad.Id = la.LocationAttributeDefinitionId
        WHERE la.LocationId = @TerminalLocationId
          AND ad.LocationTypeDefinitionId = 7
          AND ad.AttributeName = N'CrtEnabled'
          AND ad.DeprecatedAt IS NULL;
        SET @CrtActive = ISNULL(@CrtActive, 0);
```

- [ ] **Step 5: Add the column value to the INSERT**

Change the `INSERT INTO Lots.Lot` column list and VALUES to carry `CrtActive`. The column list gains `CrtActive` after `BomId`, and the VALUES list gains `@CrtActive` in the same position:

```sql
        INSERT INTO Lots.Lot (
            LotName, ItemId, LotOriginTypeId, LotStatusId, PieceCount, MaxPieceCount,
            Weight, WeightUomId, ToolId, ToolCavityId, CavityNumber, VendorLotNumber,
            MinSerialNumber, MaxSerialNumber, CurrentLocationId,
            TotalInProcess, InventoryAvailable,
            CreatedByUserId, CreatedAtTerminalId, CreatedAt, BomId, CrtActive)
        VALUES (
            @MintedName, @FinishedGoodItemId, @ManufacturedOriginId, @GoodStatusId, @PieceCount, @MaxLotSize,
            NULL, NULL, NULL, NULL, NULL, NULL,
            NULL, NULL, @CellLocationId,
            0, @PieceCount,
            @AppUserId, @TerminalLocationId, SYSUTCDATETIME(), @BomId, @CrtActive);
```

- [ ] **Step 6: Apply and re-run**

Run:
```bash
sqlcmd -S localhost -d MPP_MES_Test -E -b -I -C -i sql/migrations/repeatable/R__Workorder_Assembly_CompleteTray.sql
sqlcmd -S localhost -d MPP_MES_Test -E -b -I -C -i sql/tests/0056_CrtValidation/030_CompleteTray_marks_crt.sql
```
Expected: both asserts PASS, `Failed: 0`.

- [ ] **Step 7: Run the existing assembly suite for regressions**

Run: `sqlcmd -S localhost -d MPP_MES_Test -E -b -I -C -i sql/tests/0028_PlantFloor_Assembly/076_Assembly_ScanIn.sql`
Expected: `Failed: 0`. Then run the whole folder's files the same way; any `Msg 213` means a fixed-shape `INSERT-EXEC` capture needs widening because the proc's result shape changed (it should not have — only the LOT insert changed, not the SELECT).

- [ ] **Step 8: Commit**

```bash
git add sql/migrations/repeatable/R__Workorder_Assembly_CompleteTray.sql sql/tests/0056_CrtValidation/030_CompleteTray_marks_crt.sql
git commit -m "feat(crt): mint the FG LOT CRT-active when the terminal has CRT on"
```

---

## Task 3: Hold the AIM post back

**Files:**
- Modify: `sql/migrations/repeatable/R__Lots_AimShipperIdPool_ListUnposted.sql`
- Modify: `ignition/projects/Core/ignition/script-python/BlueRidge/Lots/Container/code.py` (the `postOne` block at ~line 100)
- Test: `sql/tests/0056_CrtValidation/040_ListUnposted_excludes_held.sql`

**Interfaces:**
- Consumes: `Lots.Lot.CrtActive` on the FG LOT (Task 2).
- Produces: `Lots.AimShipperIdPool_ListUnposted` no longer returns serials belonging to CRT-held containers. `retryTick`, the owed-backlog screen and `alarmTick` all inherit this because they read through it.

**This is the load-bearing task.** Without the `ListUnposted` change, the 60-second sweep posts held serials within a minute and the feature does nothing.

- [ ] **Step 1: Write the failing test**

Create `sql/tests/0056_CrtValidation/040_ListUnposted_excludes_held.sql`:

```sql
-- =============================================
-- File: 0056_CrtValidation/040_ListUnposted_excludes_held.sql
-- Desc: THE regression guard. AimShipperIdPool_ListUnposted is the single query
--       behind AimPost.retryTick, the owed-to-AIM backlog screen and alarmTick's
--       age escalation. A CRT-held container's serial must not appear there, or
--       the 60s sweep posts it and the whole feature is silently defeated.
--
--       Pool convention: blanket-DELETE on entry and top up our own IDs - the
--       seeded pool is destroyed by earlier pool-touching files in a full run.
-- =============================================
EXEC test.BeginTestFile @FileName = N'0056_CrtValidation/040_ListUnposted_excludes_held.sql';
GO

DELETE FROM Lots.AimShipperIdPool;
GO

DECLARE @Cell BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MA1-FP6NA');
DECLARE @Term BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MA1-FP6NA-AOUT');
DECLARE @Fg   BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'12270-6NA -0001');

DECLARE @TP TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO @TP EXEC Lots.AimShipperIdPool_Topup @AimShipperId = N'AIM-CRT-1';

DECLARE @On TABLE (Status BIT, Message NVARCHAR(500));
INSERT INTO @On EXEC Location.Terminal_SetCrtEnabled @TerminalLocationId = @Term, @Enabled = 1, @AppUserId = 1;

-- complete a tray + container under CRT so a serial is CLAIMED but held
DECLARE @AT TABLE (Status BIT, Message NVARCHAR(500), FinishedGoodLotId BIGINT,
                   ContainerId BIGINT, ContainerTrayId BIGINT, ContainerFull BIT);
INSERT INTO @AT EXEC Workorder.Assembly_CompleteTray
    @FinishedGoodItemId = @Fg, @PieceCount = 1, @CellLocationId = @Cell,
    @ClosureMethod = N'ByCount', @AppUserId = 1, @TerminalLocationId = @Term;
DECLARE @Con BIGINT = (SELECT ContainerId FROM @AT);
DECLARE @Lot BIGINT = (SELECT FinishedGoodLotId FROM @AT);

DECLARE @CC TABLE (Status BIT, Message NVARCHAR(500), ShippingLabelId BIGINT, AimShipperId NVARCHAR(50));
INSERT INTO @CC EXEC Lots.Container_Complete @ContainerId = @Con, @AppUserId = 1, @TerminalLocationId = @Term;

-- the serial IS consumed (that part of the behaviour is unchanged)
DECLARE @Claimed NVARCHAR(10) = CASE WHEN EXISTS (
    SELECT 1 FROM Lots.AimShipperIdPool WHERE ConsumedByContainerId = @Con) THEN N'1' ELSE N'0' END;
EXEC test.Assert_IsEqual @TestName = N'[Held] serial is still CLAIMED at completion',
    @Expected = N'1', @Actual = @Claimed;

-- ...but must NOT be offered to the sweep
DECLARE @U1 TABLE (Id BIGINT, AimShipperId NVARCHAR(50), ContainerId BIGINT, CustomerPartNumber NVARCHAR(50),
    Quantity INT, LotNumber NVARCHAR(50), PostAttempts INT, LastPostError NVARCHAR(500),
    ConsumedAtEt DATETIME2(3), LastPostAttemptAtEt DATETIME2(3), AgeMinutes INT);
INSERT INTO @U1 EXEC Lots.AimShipperIdPool_ListUnposted @Top = 50;
DECLARE @Held NVARCHAR(10) = CASE WHEN EXISTS (SELECT 1 FROM @U1 WHERE ContainerId = @Con) THEN N'1' ELSE N'0' END;
EXEC test.Assert_IsEqual @TestName = N'[Held] CRT-held serial is EXCLUDED from ListUnposted',
    @Expected = N'0', @Actual = @Held;

-- THE 200%-INSPECTION GUARD. Reusing Lots.Lot.CrtActive is only safe because
-- Container_Complete closes the FG LOT and Quality.Crt_GetRequiredInspections filters
-- sc.Code <> 'Closed'. If the FG LOT ever stops closing at completion, every CRT
-- container would silently start demanding 200% inspection. Assert both halves.
DECLARE @Act9 NVARCHAR(10) = (SELECT sc.Code FROM Lots.Lot l
    JOIN Lots.LotStatusCode sc ON sc.Id = l.LotStatusId WHERE l.Id = @Lot);
EXEC test.Assert_IsEqual @TestName = N'[Held] FG LOT is Closed after container completion',
    @Expected = N'Closed', @Actual = @Act9;

DECLARE @Insp TABLE (LotId BIGINT, LotName NVARCHAR(50), ItemPartNumber NVARCHAR(50),
    PieceCount INT, SampleCount INT, LastSampledAt DATETIME2(3), LastResultCode NVARCHAR(20));
INSERT INTO @Insp EXEC Quality.Crt_GetRequiredInspections @LocationId = @Cell;
DECLARE @Act10 NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM @Insp WHERE LotId = @Lot);
EXEC test.Assert_IsEqual @TestName = N'[Held] CRT-active but Closed -> NOT in the 200% inspection surface',
    @Expected = N'0', @Actual = @Act10;

-- clearing CRT hands it straight back to the normal retry machinery
DECLARE @CL TABLE (Status BIT, Message NVARCHAR(500));
INSERT INTO @CL EXEC Lots.Lot_ClearCrt @LotId = @Lot, @AppUserId = 1, @TerminalLocationId = @Term;

DECLARE @U2 TABLE (Id BIGINT, AimShipperId NVARCHAR(50), ContainerId BIGINT, CustomerPartNumber NVARCHAR(50),
    Quantity INT, LotNumber NVARCHAR(50), PostAttempts INT, LastPostError NVARCHAR(500),
    ConsumedAtEt DATETIME2(3), LastPostAttemptAtEt DATETIME2(3), AgeMinutes INT);
INSERT INTO @U2 EXEC Lots.AimShipperIdPool_ListUnposted @Top = 50;
DECLARE @Freed NVARCHAR(10) = CASE WHEN EXISTS (SELECT 1 FROM @U2 WHERE ContainerId = @Con) THEN N'1' ELSE N'0' END;
EXEC test.Assert_IsEqual @TestName = N'[Held] cleared CRT -> serial reappears for the sweep',
    @Expected = N'1', @Actual = @Freed;

DECLARE @Off TABLE (Status BIT, Message NVARCHAR(500));
INSERT INTO @Off EXEC Location.Terminal_SetCrtEnabled @TerminalLocationId = @Term, @Enabled = 0, @AppUserId = 1;
DELETE FROM Lots.AimShipperIdPool;
GO

EXEC test.EndTestFile;
```

- [ ] **Step 2: Run it to verify it fails**

Run: `sqlcmd -S localhost -d MPP_MES_Test -E -b -I -C -i sql/tests/0056_CrtValidation/040_ListUnposted_excludes_held.sql`
Expected: the `EXCLUDED` assert FAILs with `Expected: 0  Actual: 1`.

- [ ] **Step 3: Exclude held serials from ListUnposted**

In `sql/migrations/repeatable/R__Lots_AimShipperIdPool_ListUnposted.sql`, change the `WHERE` clause. Bump the header `Version:` and add a note explaining why:

```sql
    WHERE p.ConsumedAt IS NOT NULL AND p.PostedAt IS NULL
      -- Controlled Run Tag hold. This proc is the SINGLE query behind AimPost.retryTick,
      -- the owed-to-AIM backlog screen and alarmTick's age escalation, so excluding held
      -- serials here holds the post back in all three at once. Without this the 60s sweep
      -- posts a CRT container within a minute of completion.
      AND NOT EXISTS (
          SELECT 1
          FROM Lots.ContainerTray ct
          JOIN Lots.Lot fgl ON fgl.Id = ct.FinishedGoodLotId
          WHERE ct.ContainerId = p.ConsumedByContainerId
            AND fgl.CrtActive = 1)
    ORDER BY p.ConsumedAt, p.Id;
```

- [ ] **Step 4: Apply and re-run**

Run:
```bash
sqlcmd -S localhost -d MPP_MES_Test -E -b -I -C -i sql/migrations/repeatable/R__Lots_AimShipperIdPool_ListUnposted.sql
sqlcmd -S localhost -d MPP_MES_Test -E -b -I -C -i sql/tests/0056_CrtValidation/040_ListUnposted_excludes_held.sql
```
Expected: three PASS, `Failed: 0`.

- [ ] **Step 5: Skip the synchronous post for held containers**

In `ignition/projects/Core/ignition/script-python/BlueRidge/Lots/Container/code.py`, replace the post block in `complete()` (currently `if result and result.get("Status") and result.get("AimShipperId"):`) with:

```python
    # Report the completed container to AIM. Runs AFTER the proc committed and is fully
    # guarded: complete, print and post are three separate steps (FDS-07-005/006a/012).
    # A failure leaves the row owed; AimPostTimer retries it. NEVER lose the container.
    #
    # Controlled Run Tag: a container whose finished-good LOT is CRT-active is awaiting a
    # second-person validation, so its serial stays CLAIMED but UNPOSTED. Validating it
    # clears the flag and posts. AimShipperIdPool_ListUnposted excludes it meanwhile, so
    # the retry sweep leaves it alone too - both halves are needed.
    if result and result.get("Status") and result.get("AimShipperId"):
        if _isCrtHeld(containerId):
            result["AimPost"] = {"ok": False, "outcome": "held",
                                 "error": "Container is pending Controlled Run Tag validation."}
            return result
        try:
            result["AimPost"] = BlueRidge.Lots.AimPost.postOne(result.get("AimShipperId"))
        except Throwable as t:
            BlueRidge.Common.Util.log("AIM post-back failed: %s" % t, level="error")
            result["AimPost"] = {"ok": False, "outcome": "failed", "error": str(t)}
        except Exception as e:
            BlueRidge.Common.Util.log("AIM post-back failed: %s" % e, level="error")
            result["AimPost"] = {"ok": False, "outcome": "failed", "error": str(e)}
    return result


def _isCrtHeld(containerId):
    """True when any of the container's trays carries a CRT-active finished-good LOT."""
    rows = BlueRidge.Common.Db.execList(
        "lots/Container_ListPendingValidation", {"locationId": None, "containerId": containerId}) or []
    return len(rows) > 0
```

**Note:** `_isCrtHeld` depends on the read proc built in Task 4. Implement Task 4 first, or write `_isCrtHeld` as a `return False` stub here and replace it in Task 4 — do not leave a call to a named query that does not exist.

- [ ] **Step 6: Commit**

```bash
git add sql/migrations/repeatable/R__Lots_AimShipperIdPool_ListUnposted.sql sql/tests/0056_CrtValidation/040_ListUnposted_excludes_held.sql ignition/projects/Core/ignition/script-python/BlueRidge/Lots/Container/code.py
git commit -m "feat(crt): hold the AIM post back for CRT-marked containers"
```

---

## Task 4: The pending-validation read

**Files:**
- Create: `sql/migrations/repeatable/R__Lots_Container_ListPendingValidation.sql`
- Create: `ignition/projects/Core/ignition/named-query/lots/Container_ListPendingValidation/query.sql`
- Create: `ignition/projects/Core/ignition/named-query/lots/Container_ListPendingValidation/resource.json`
- Modify: `ignition/projects/Core/ignition/script-python/BlueRidge/Lots/Container/code.py`
- Test: `sql/tests/0056_CrtValidation/050_Container_ListPendingValidation.sql`

**Interfaces:**
- Produces: `Lots.Container_ListPendingValidation(@LocationId BIGINT = NULL, @ContainerId BIGINT = NULL)` returning `ContainerId, ItemPartNumber, ItemDescription, PieceCount, CompletedAtEt, AimShipperId, AgeMinutes, FinishedGoodLotId`.
- Produces: `BlueRidge.Lots.Container.listPendingValidation(locationId, _refreshToken=None) -> list[dict]`.
- Consumed by: Task 3's `_isCrtHeld` (via `@ContainerId`), Task 7's popup and button (via `@LocationId`).

- [ ] **Step 1: Write the failing test**

Create `sql/tests/0056_CrtValidation/050_Container_ListPendingValidation.sql`:

```sql
-- =============================================
-- File: 0056_CrtValidation/050_Container_ListPendingValidation.sql
-- Desc: The pending list - line-scoped, drops a container once validated.
-- =============================================
EXEC test.BeginTestFile @FileName = N'0056_CrtValidation/050_Container_ListPendingValidation.sql';
GO

DELETE FROM Lots.AimShipperIdPool;
GO

DECLARE @Cell BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MA1-FP6NA');
DECLARE @Term BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MA1-FP6NA-AOUT');
DECLARE @Fg   BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'12270-6NA -0001');
DECLARE @Other BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MA2-59B');

DECLARE @TP TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO @TP EXEC Lots.AimShipperIdPool_Topup @AimShipperId = N'AIM-CRT-LIST-1';

DECLARE @On TABLE (Status BIT, Message NVARCHAR(500));
INSERT INTO @On EXEC Location.Terminal_SetCrtEnabled @TerminalLocationId = @Term, @Enabled = 1, @AppUserId = 1;

DECLARE @AT TABLE (Status BIT, Message NVARCHAR(500), FinishedGoodLotId BIGINT,
                   ContainerId BIGINT, ContainerTrayId BIGINT, ContainerFull BIT);
INSERT INTO @AT EXEC Workorder.Assembly_CompleteTray
    @FinishedGoodItemId = @Fg, @PieceCount = 1, @CellLocationId = @Cell,
    @ClosureMethod = N'ByCount', @AppUserId = 1, @TerminalLocationId = @Term;
DECLARE @Con BIGINT = (SELECT ContainerId FROM @AT);
DECLARE @Lot BIGINT = (SELECT FinishedGoodLotId FROM @AT);

DECLARE @CC TABLE (Status BIT, Message NVARCHAR(500), ShippingLabelId BIGINT, AimShipperId NVARCHAR(50));
INSERT INTO @CC EXEC Lots.Container_Complete @ContainerId = @Con, @AppUserId = 1, @TerminalLocationId = @Term;

DECLARE @L1 TABLE (ContainerId BIGINT, ItemPartNumber NVARCHAR(50), ItemDescription NVARCHAR(500),
    PieceCount INT, CompletedAtEt DATETIME2(3), AimShipperId NVARCHAR(50), AgeMinutes INT, FinishedGoodLotId BIGINT);
INSERT INTO @L1 EXEC Lots.Container_ListPendingValidation @LocationId = @Cell, @ContainerId = NULL;
DECLARE @Act5 NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM @L1 WHERE ContainerId = @Con);
EXEC test.Assert_IsEqual @TestName = N'[Pending] held container is listed for its line',
    @Expected = N'1', @Actual = @Act5;

DECLARE @L2 TABLE (ContainerId BIGINT, ItemPartNumber NVARCHAR(50), ItemDescription NVARCHAR(500),
    PieceCount INT, CompletedAtEt DATETIME2(3), AimShipperId NVARCHAR(50), AgeMinutes INT, FinishedGoodLotId BIGINT);
INSERT INTO @L2 EXEC Lots.Container_ListPendingValidation @LocationId = @Other, @ContainerId = NULL;
DECLARE @Act6 NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM @L2 WHERE ContainerId = @Con);
EXEC test.Assert_IsEqual @TestName = N'[Pending] a different line does NOT see it',
    @Expected = N'0', @Actual = @Act6;

-- @ContainerId probe (the path Container.complete uses)
DECLARE @L3 TABLE (ContainerId BIGINT, ItemPartNumber NVARCHAR(50), ItemDescription NVARCHAR(500),
    PieceCount INT, CompletedAtEt DATETIME2(3), AimShipperId NVARCHAR(50), AgeMinutes INT, FinishedGoodLotId BIGINT);
INSERT INTO @L3 EXEC Lots.Container_ListPendingValidation @LocationId = NULL, @ContainerId = @Con;
DECLARE @Act7 NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM @L3);
EXEC test.Assert_IsEqual @TestName = N'[Pending] container probe finds the held container',
    @Expected = N'1', @Actual = @Act7;

-- validated -> drops out
DECLARE @CL TABLE (Status BIT, Message NVARCHAR(500));
INSERT INTO @CL EXEC Lots.Lot_ClearCrt @LotId = @Lot, @AppUserId = 1, @TerminalLocationId = @Term;
DECLARE @L4 TABLE (ContainerId BIGINT, ItemPartNumber NVARCHAR(50), ItemDescription NVARCHAR(500),
    PieceCount INT, CompletedAtEt DATETIME2(3), AimShipperId NVARCHAR(50), AgeMinutes INT, FinishedGoodLotId BIGINT);
INSERT INTO @L4 EXEC Lots.Container_ListPendingValidation @LocationId = @Cell, @ContainerId = NULL;
DECLARE @Act8 NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM @L4 WHERE ContainerId = @Con);
EXEC test.Assert_IsEqual @TestName = N'[Pending] validated container drops out of the list',
    @Expected = N'0', @Actual = @Act8;

DECLARE @Off TABLE (Status BIT, Message NVARCHAR(500));
INSERT INTO @Off EXEC Location.Terminal_SetCrtEnabled @TerminalLocationId = @Term, @Enabled = 0, @AppUserId = 1;
DELETE FROM Lots.AimShipperIdPool;
GO

EXEC test.EndTestFile;
```

- [ ] **Step 2: Run it to verify it fails**

Run: `sqlcmd -S localhost -d MPP_MES_Test -E -b -I -C -i sql/tests/0056_CrtValidation/050_Container_ListPendingValidation.sql`
Expected: aborts with `Could not find stored procedure 'Lots.Container_ListPendingValidation'`.

- [ ] **Step 3: Write the read proc**

Create `sql/migrations/repeatable/R__Lots_Container_ListPendingValidation.sql`:

```sql
-- ============================================================
-- Repeatable:  R__Lots_Container_ListPendingValidation.sql
-- Author:      Blue Ridge Automation
-- Modified:    2026-08-14
-- Version:     1.0
-- Description: Containers awaiting Controlled Run Tag validation: their finished-good
--              LOT is still CrtActive, so their AIM Shipper ID is claimed but held.
--
--              @LocationId scopes to that location and every descendant (mirrors
--              Lot_GetWipQueueByLocation's Descendants CTE) - callers pass the
--              terminal's PARENT LINE. @ContainerId probes one container instead
--              (used by the completion path to decide whether to post).
--              Exactly one of the two should be supplied.
--
--              Read proc: no OUTPUT params, empty result set = nothing pending.
--              Times are ET-converted and CAST to DATETIME2(3) - a raw
--              datetimeoffset breaks the Ignition JDBC result read.
-- ============================================================
CREATE OR ALTER PROCEDURE Lots.Container_ListPendingValidation
    @LocationId  BIGINT = NULL,
    @ContainerId BIGINT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    ;WITH Descendants AS (
        SELECT @LocationId AS Id
        UNION ALL
        SELECT c.Id FROM Location.Location c INNER JOIN Descendants d ON c.ParentLocationId = d.Id
    )
    SELECT
        c.Id                                AS ContainerId,
        i.PartNumber                        AS ItemPartNumber,
        i.Description                       AS ItemDescription,
        ISNULL(SUM(ct.PartsClosedCount), 0) AS PieceCount,
        CAST(c.CompletedAt AT TIME ZONE 'UTC' AT TIME ZONE 'Eastern Standard Time'
             AS DATETIME2(3))               AS CompletedAtEt,
        MAX(p.AimShipperId)                 AS AimShipperId,
        DATEDIFF(MINUTE, c.CompletedAt, SYSUTCDATETIME()) AS AgeMinutes,
        MAX(fgl.Id)                         AS FinishedGoodLotId
    FROM Lots.Container c
    INNER JOIN Lots.ContainerTray ct ON ct.ContainerId = c.Id
    INNER JOIN Lots.Lot fgl          ON fgl.Id = ct.FinishedGoodLotId AND fgl.CrtActive = 1
    INNER JOIN Parts.Item i          ON i.Id = c.ItemId
    LEFT  JOIN Lots.AimShipperIdPool p ON p.ConsumedByContainerId = c.Id
    WHERE (@ContainerId IS NOT NULL AND c.Id = @ContainerId)
       OR (@ContainerId IS NULL AND @LocationId IS NOT NULL
           AND c.CurrentLocationId IN (SELECT Id FROM Descendants))
    GROUP BY c.Id, i.PartNumber, i.Description, c.CompletedAt
    ORDER BY c.CompletedAt, c.Id
    OPTION (MAXRECURSION 8);
END;
GO
```

- [ ] **Step 4: Apply and re-run**

Run:
```bash
sqlcmd -S localhost -d MPP_MES_Test -E -b -I -C -i sql/migrations/repeatable/R__Lots_Container_ListPendingValidation.sql
sqlcmd -S localhost -d MPP_MES_Test -E -b -I -C -i sql/tests/0056_CrtValidation/050_Container_ListPendingValidation.sql
```
Expected: four PASS, `Failed: 0`.

- [ ] **Step 5: Add the named query**

Create `ignition/projects/Core/ignition/named-query/lots/Container_ListPendingValidation/query.sql`:

```sql
EXEC Lots.Container_ListPendingValidation
    @LocationId  = :locationId,
    @ContainerId = :containerId
```

Create `resource.json` by copying `ignition/projects/Core/ignition/named-query/lots/Lot_GetWipQueueByLocation/resource.json` and replacing its parameters with `locationId` and `containerId`, both Int8 and both nullable. Read that sibling file for the exact `sqlType` codes.

- [ ] **Step 6: Add the Python wrapper and replace the Task 3 stub**

In `ignition/projects/Core/ignition/script-python/BlueRidge/Lots/Container/code.py`, add:

```python
def listPendingValidation(locationId, _refreshToken=None):
    """Containers at or under locationId awaiting CRT validation. _refreshToken is
       ignored - it exists so a runScript binding can force a re-read (runScript
       caches on its ARGUMENTS, so the token must be passed as one)."""
    locationId = BlueRidge.Common.Util.extractQualifiedValues(locationId)
    return BlueRidge.Common.Db.execList(
        "lots/Container_ListPendingValidation",
        {"locationId": locationId, "containerId": None}) or []
```

Then confirm `_isCrtHeld` from Task 3 reads:

```python
def _isCrtHeld(containerId):
    """True when any of the container's trays carries a CRT-active finished-good LOT."""
    containerId = BlueRidge.Common.Util.extractQualifiedValues(containerId)
    rows = BlueRidge.Common.Db.execList(
        "lots/Container_ListPendingValidation",
        {"locationId": None, "containerId": containerId}) or []
    return len(rows) > 0
```

- [ ] **Step 7: Commit**

```bash
git add sql/migrations/repeatable/R__Lots_Container_ListPendingValidation.sql sql/tests/0056_CrtValidation/050_Container_ListPendingValidation.sql ignition/projects/Core/ignition/named-query/lots/Container_ListPendingValidation ignition/projects/Core/ignition/script-python/BlueRidge/Lots/Container/code.py
git commit -m "feat(crt): pending-validation read proc, NQ and wrapper"
```

---

## Task 5: Validate a container

**Files:**
- Create: `sql/migrations/repeatable/R__Lots_Container_ValidateCrt.sql`
- Create: `ignition/projects/Core/ignition/named-query/lots/Container_ValidateCrt/query.sql`
- Create: `ignition/projects/Core/ignition/named-query/lots/Container_ValidateCrt/resource.json`
- Modify: `ignition/projects/Core/ignition/script-python/BlueRidge/Lots/Container/code.py`
- Test: `sql/tests/0056_CrtValidation/060_Container_ValidateCrt.sql`

**Interfaces:**
- Produces: `Lots.Container_ValidateCrt(@ContainerId BIGINT, @AppUserId BIGINT, @TerminalLocationId BIGINT = NULL)` returning `(Status BIT, Message NVARCHAR(500))`.
- Produces: `BlueRidge.Lots.Container.validateCrt(containerId, appUserId, terminalLocationId) -> {Status, Message, AimPost}`. Takes an ALREADY-ELEVATED `appUserId`: the popup elevates once and both row actions reuse it, so this wrapper never prompts.
- Consumes: `Lots.Lot_ClearCrt(@LotId, @AppUserId, @TerminalLocationId)` (existing), `BlueRidge.Lots.AimPost.postOne(aimShipperId)` (existing).

- [ ] **Step 1: Write the failing test**

Create `sql/tests/0056_CrtValidation/060_Container_ValidateCrt.sql`:

```sql
-- =============================================
-- File: 0056_CrtValidation/060_Container_ValidateCrt.sql
-- Desc: Container_ValidateCrt - clears the FG LOT's CRT flag, rejects a container
--       that is not pending. The AIM post itself is the Python caller's step.
-- =============================================
EXEC test.BeginTestFile @FileName = N'0056_CrtValidation/060_Container_ValidateCrt.sql';
GO

DELETE FROM Lots.AimShipperIdPool;
GO

DECLARE @Cell BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MA1-FP6NA');
DECLARE @Term BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MA1-FP6NA-AOUT');
DECLARE @Fg   BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'12270-6NA -0001');

DECLARE @TP TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO @TP EXEC Lots.AimShipperIdPool_Topup @AimShipperId = N'AIM-CRT-VAL-1';

DECLARE @On TABLE (Status BIT, Message NVARCHAR(500));
INSERT INTO @On EXEC Location.Terminal_SetCrtEnabled @TerminalLocationId = @Term, @Enabled = 1, @AppUserId = 1;

DECLARE @AT TABLE (Status BIT, Message NVARCHAR(500), FinishedGoodLotId BIGINT,
                   ContainerId BIGINT, ContainerTrayId BIGINT, ContainerFull BIT);
INSERT INTO @AT EXEC Workorder.Assembly_CompleteTray
    @FinishedGoodItemId = @Fg, @PieceCount = 1, @CellLocationId = @Cell,
    @ClosureMethod = N'ByCount', @AppUserId = 1, @TerminalLocationId = @Term;
DECLARE @Con BIGINT = (SELECT ContainerId FROM @AT);
DECLARE @Lot BIGINT = (SELECT FinishedGoodLotId FROM @AT);

DECLARE @CC TABLE (Status BIT, Message NVARCHAR(500), ShippingLabelId BIGINT, AimShipperId NVARCHAR(50));
INSERT INTO @CC EXEC Lots.Container_Complete @ContainerId = @Con, @AppUserId = 1, @TerminalLocationId = @Term;

DECLARE @V1 TABLE (Status BIT, Message NVARCHAR(500));
INSERT INTO @V1 EXEC Lots.Container_ValidateCrt @ContainerId = @Con, @AppUserId = 1, @TerminalLocationId = @Term;
DECLARE @Act9 NVARCHAR(10) = (SELECT CAST(Status AS NVARCHAR(10)) FROM @V1);
EXEC test.Assert_IsEqual @TestName = N'[Validate] returns Status 1',
    @Expected = N'1', @Actual = @Act9;

DECLARE @Act10 NVARCHAR(10) = (SELECT CAST(CrtActive AS NVARCHAR(10)) FROM Lots.Lot WHERE Id = @Lot);
EXEC test.Assert_IsEqual @TestName = N'[Validate] FG LOT CrtActive cleared to 0',
    @Expected = N'0', @Actual = @Act10;

-- second call must reject: nothing pending any more
DECLARE @V2 TABLE (Status BIT, Message NVARCHAR(500));
INSERT INTO @V2 EXEC Lots.Container_ValidateCrt @ContainerId = @Con, @AppUserId = 1, @TerminalLocationId = @Term;
DECLARE @Act11 NVARCHAR(10) = (SELECT CAST(Status AS NVARCHAR(10)) FROM @V2);
EXEC test.Assert_IsEqual @TestName = N'[Validate] double-validate rejected, Status 0',
    @Expected = N'0', @Actual = @Act11;

DECLARE @V3 TABLE (Status BIT, Message NVARCHAR(500));
INSERT INTO @V3 EXEC Lots.Container_ValidateCrt @ContainerId = 999999999, @AppUserId = 1, @TerminalLocationId = @Term;
DECLARE @Act12 NVARCHAR(10) = (SELECT CAST(Status AS NVARCHAR(10)) FROM @V3);
EXEC test.Assert_IsEqual @TestName = N'[Validate] unknown container rejected, Status 0',
    @Expected = N'0', @Actual = @Act12;

DECLARE @Off TABLE (Status BIT, Message NVARCHAR(500));
INSERT INTO @Off EXEC Location.Terminal_SetCrtEnabled @TerminalLocationId = @Term, @Enabled = 0, @AppUserId = 1;
DELETE FROM Lots.AimShipperIdPool;
GO

EXEC test.EndTestFile;
```

- [ ] **Step 2: Run it to verify it fails**

Run: `sqlcmd -S localhost -d MPP_MES_Test -E -b -I -C -i sql/tests/0056_CrtValidation/060_Container_ValidateCrt.sql`
Expected: aborts with `Could not find stored procedure 'Lots.Container_ValidateCrt'`.

- [ ] **Step 3: Write the validate proc**

Create `sql/migrations/repeatable/R__Lots_Container_ValidateCrt.sql`. Note the INSERT-EXEC constraint: this proc returns a status row and is captured by tests, so it must **not** `EXEC Lots.Lot_ClearCrt` — that would pollute the single result set. The flag clear is inlined and commented as a mirror.

```sql
-- ============================================================
-- Repeatable:  R__Lots_Container_ValidateCrt.sql
-- Author:      Blue Ridge Automation
-- Modified:    2026-08-14
-- Version:     1.0
-- Description: A second person has validated a container that completed under a
--              Controlled Run Tag. Clears the CRT flag on the container's
--              finished-good LOT(s), which releases the container's AIM Shipper ID
--              back to the normal post path (AimShipperIdPool_ListUnposted stops
--              excluding it). The POST itself is the Python caller's next step.
--
--              INSERT-EXEC: this proc returns a status row and is captured by
--              callers, so it must NOT EXEC Lots.Lot_ClearCrt - a nested status-row
--              proc would pollute the single result set and nesting INSERT-EXEC is
--              illegal. The flag clear below MIRRORS Lots.Lot_ClearCrt; keep them
--              in step.
--
--              All rejects run BEFORE BEGIN TRANSACTION (Msg 3915).
-- ============================================================
CREATE OR ALTER PROCEDURE Lots.Container_ValidateCrt
    @ContainerId        BIGINT,
    @AppUserId          BIGINT,
    @TerminalLocationId BIGINT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Status  BIT           = 0;
    DECLARE @Message NVARCHAR(500) = N'Unknown error';
    DECLARE @ProcName NVARCHAR(200) = N'Lots.Container_ValidateCrt';
    DECLARE @Params   NVARCHAR(MAX) = (
        SELECT @ContainerId AS ContainerId, @AppUserId AS AppUserId,
               @TerminalLocationId AS TerminalLocationId
        FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

    BEGIN TRY
        IF @ContainerId IS NULL OR @AppUserId IS NULL
        BEGIN
            SET @Message = N'Required parameter missing (ContainerId, AppUserId).';
            SELECT @Status AS Status, @Message AS Message; RETURN;
        END

        IF NOT EXISTS (SELECT 1 FROM Lots.Container WHERE Id = @ContainerId)
        BEGIN
            SET @Message = N'Container not found.';
            SELECT @Status AS Status, @Message AS Message; RETURN;
        END

        IF NOT EXISTS (
            SELECT 1 FROM Lots.ContainerTray ct
            JOIN Lots.Lot fgl ON fgl.Id = ct.FinishedGoodLotId
            WHERE ct.ContainerId = @ContainerId AND fgl.CrtActive = 1)
        BEGIN
            SET @Message = N'Container is not pending validation.';
            SELECT @Status AS Status, @Message AS Message; RETURN;
        END

        BEGIN TRANSACTION;

        -- MIRRORS Lots.Lot_ClearCrt (see header): clear the tag + attribution.
        UPDATE fgl
        SET fgl.CrtActive = 0,
            fgl.UpdatedAt = SYSUTCDATETIME(),
            fgl.UpdatedByUserId = @AppUserId
        FROM Lots.Lot fgl
        JOIN Lots.ContainerTray ct ON ct.FinishedGoodLotId = fgl.Id
        WHERE ct.ContainerId = @ContainerId AND fgl.CrtActive = 1;

        DECLARE @Descr NVARCHAR(500) = Audit.ufn_TruncateActivity(
            N'Container ' + CAST(@ContainerId AS NVARCHAR(20)) + N' ' + Audit.ufn_MidDot()
            + N' Controlled Run Tag ' + Audit.ufn_MidDot() + N' Validated');

        EXEC Audit.Audit_LogOperation
            @AppUserId = @AppUserId, @TerminalLocationId = @TerminalLocationId, @LocationId = NULL,
            @LogEntityTypeCode = N'Container', @EntityId = @ContainerId,
            @LogEventTypeCode = N'Updated', @LogSeverityCode = N'Info',
            @Description = @Descr, @OldValue = NULL, @NewValue = NULL;

        COMMIT TRANSACTION;

        SET @Status = 1;
        SET @Message = N'Container validated.';
        SELECT @Status AS Status, @Message AS Message;
        RETURN;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        DECLARE @ErrMsg NVARCHAR(4000) = ERROR_MESSAGE();
        DECLARE @ErrSev INT = ERROR_SEVERITY();
        DECLARE @ErrState INT = ERROR_STATE();
        SET @Status = 0;
        SET @Message = N'Unexpected error: ' + LEFT(@ErrMsg, 400);
        BEGIN TRY
            EXEC Audit.Audit_LogFailure @AppUserId = @AppUserId, @LogEntityTypeCode = N'Container',
                @EntityId = @ContainerId, @LogEventTypeCode = N'Updated', @FailureReason = @Message,
                @ProcedureName = @ProcName, @AttemptedParameters = @Params;
        END TRY
        BEGIN CATCH
        END CATCH
        SELECT @Status AS Status, @Message AS Message;
        RAISERROR(@ErrMsg, @ErrSev, @ErrState);
    END CATCH
END;
GO
```

**Before writing:** verify `Audit.Audit_LogOperation`'s exact parameter list and that `Container` is a valid `LogEntityTypeCode` by reading `sql/migrations/repeatable/R__Lots_Container_Complete.sql`. If `Container` is not a seeded entity type, use whatever that proc uses for container audits — do not invent a code.

- [ ] **Step 4: Apply and re-run**

Run:
```bash
sqlcmd -S localhost -d MPP_MES_Test -E -b -I -C -i sql/migrations/repeatable/R__Lots_Container_ValidateCrt.sql
sqlcmd -S localhost -d MPP_MES_Test -E -b -I -C -i sql/tests/0056_CrtValidation/060_Container_ValidateCrt.sql
```
Expected: four PASS, `Failed: 0`.

- [ ] **Step 5: Add the named query**

Create `ignition/projects/Core/ignition/named-query/lots/Container_ValidateCrt/query.sql`:

```sql
EXEC Lots.Container_ValidateCrt
    @ContainerId        = :containerId,
    @AppUserId          = :appUserId,
    @TerminalLocationId = :terminalLocationId
```

Create `resource.json` by copying a sibling mutation NQ under `ignition/projects/Core/ignition/named-query/lots/` (e.g. `Container_Complete`) and replacing the parameter list with the three above, all Int8.

- [ ] **Step 6: Add the Python wrapper**

Add to `ignition/projects/Core/ignition/script-python/BlueRidge/Lots/Container/code.py`:

```python
def validateCrt(containerId, appUserId, terminalLocationId):
    """Clear the container's Controlled Run Tag, then post its AIM serial.

       appUserId is ALREADY ELEVATED - the CrtValidation popup elevates once on open
       and both row actions reuse it, so there is no prompt here.

       The post is deliberately NOT rolled back on failure: the human validation
       decision is recorded regardless of whether AIM was reachable, and clearing the
       flag is exactly what hands the serial to AimPost.retryTick."""
    from java.lang import Throwable
    containerId = BlueRidge.Common.Util.extractQualifiedValues(containerId)
    appUserId = BlueRidge.Common.Util.extractQualifiedValues(appUserId)
    terminalLocationId = BlueRidge.Common.Util.extractQualifiedValues(terminalLocationId)

    serial = None
    for r in (BlueRidge.Common.Db.execList("lots/Container_ListPendingValidation",
                                           {"locationId": None, "containerId": containerId}) or []):
        serial = r.get("AimShipperId")
        break

    result = BlueRidge.Common.Db.execMutation(
        "lots/Container_ValidateCrt",
        {"containerId": containerId, "appUserId": appUserId,
         "terminalLocationId": terminalLocationId})

    if result and result.get("Status") and serial:
        try:
            result["AimPost"] = BlueRidge.Lots.AimPost.postOne(serial)
        except Throwable as t:
            BlueRidge.Common.Util.log("CRT validate post failed: %s" % t, level="error")
            result["AimPost"] = {"ok": False, "outcome": "failed", "error": str(t)}
        except Exception as e:
            BlueRidge.Common.Util.log("CRT validate post failed: %s" % e, level="error")
            result["AimPost"] = {"ok": False, "outcome": "failed", "error": str(e)}
    return result
```

- [ ] **Step 7: Run the whole new folder, then the full suite**

Run:
```bash
sqlcmd -S localhost -d MPP_MES_Test -E -b -I -C -i sql/tests/0056_CrtValidation/010_schema.sql
sqlcmd -S localhost -d MPP_MES_Test -E -b -I -C -i sql/tests/0056_CrtValidation/020_Terminal_SetCrtEnabled.sql
sqlcmd -S localhost -d MPP_MES_Test -E -b -I -C -i sql/tests/0056_CrtValidation/030_CompleteTray_marks_crt.sql
sqlcmd -S localhost -d MPP_MES_Test -E -b -I -C -i sql/tests/0056_CrtValidation/040_ListUnposted_excludes_held.sql
sqlcmd -S localhost -d MPP_MES_Test -E -b -I -C -i sql/tests/0056_CrtValidation/050_Container_ListPendingValidation.sql
sqlcmd -S localhost -d MPP_MES_Test -E -b -I -C -i sql/tests/0056_CrtValidation/060_Container_ValidateCrt.sql
```
Then the full suite: `sql\tests\Run-Tests.ps1`
Expected: `Failed: 0` and **zero** `ERROR running` lines. Pay attention to `sql/tests/0049_AimIntegration/*` — the `ListUnposted` change could affect its fixed-shape captures.

- [ ] **Step 8: Commit**

```bash
git add sql/migrations/repeatable/R__Lots_Container_ValidateCrt.sql sql/tests/0056_CrtValidation/060_Container_ValidateCrt.sql ignition/projects/Core/ignition/named-query/lots/Container_ValidateCrt ignition/projects/Core/ignition/script-python/BlueRidge/Lots/Container/code.py
git commit -m "feat(crt): Container_ValidateCrt clears the tag and posts to AIM"
```

---

## Task 6: CRT switch on the changeover popup

**Files:**
- Modify: `ignition/projects/MPP/com.inductiveautomation.perspective/views/BlueRidge/Components/Popups/ChangeoverElevation/view.json`

**Interfaces:**
- Consumes: `BlueRidge.Location.ClosureMode.setCrt(...)` and the existing `changeover(...)` (Task 1).

**⚠️ This modifies an EXISTING view.** Per `CLAUDE.md`, edits to existing `view.json` files default to Designer, because Designer serialises `=` `'` `<` `>` as `=`-style escapes that the Edit tool decodes in transit and corrupts, and because Designer's in-memory model can overwrite disk. **Either** make this change in Designer, **or** verify the target region is escape-free first and edit via PowerShell with runtime-built strings:

```bash
grep -c '\\u00' "ignition/projects/MPP/com.inductiveautomation.perspective/views/BlueRidge/Components/Popups/ChangeoverElevation/view.json"
```

If that count is greater than zero, confirm the exact lines you intend to change contain no `\u00` sequence before touching them, and re-check the count is unchanged afterwards.

- [ ] **Step 1: Extend the draft custom property**

The popup's `custom.draft` is currently `{"newMethod": "", "adAccount": "", "password": ""}`. Add `crtEnabled` and a baseline so the submit can tell what actually changed:

```json
"draft": { "newMethod": "", "adAccount": "", "password": "", "crtEnabled": false },
"crtBaseline": false
```

Pre-populating the full shape matters: a bidirectional binding to a nested path that does not exist renders validation-error borders and literal `"null"` text on first paint.

- [ ] **Step 2: Add the CRT field to the Body**

Add a `CrtField` flex container between `MethodField` and `AccountField`, matching `MethodField`'s structure — a label plus an `ia.input.checkbox` whose `props.selected` is bidirectionally bound to `view.custom.draft.crtEnabled`.

The `bidirectional: true` flag must sit **inside** the binding's `config` block next to `path`; at the binding level it is silently ignored and the input never writes back.

```json
{
  "children": [
    { "meta": { "name": "CrtLabel" }, "props": { "text": "Controlled Run Tag" }, "type": "ia.display.label" },
    { "meta": { "name": "CrtCheckbox" },
      "propConfig": {
        "props.selected": {
          "binding": { "config": { "bidirectional": true, "path": "view.custom.draft.crtEnabled" },
                       "type": "property" } } },
      "props": { "text": "Hold containers for second-person validation" },
      "type": "ia.input.checkbox" }
  ],
  "meta": { "name": "CrtField" },
  "position": { "shrink": 0 },
  "props": { "style": { "gap": "8px", "overflow": "hidden" } },
  "type": "ia.container.flex"
}
```

- [ ] **Step 3: Seed the baseline when the popup opens**

Add an `onStartup` event on the root container that reads the terminal's current `CrtEnabled` into both `draft.crtEnabled` and `crtBaseline`, so an unchanged switch fires no mutation:

```python
	tid = self.view.params.terminalLocationId
	cur = BlueRidge.Location.Terminal.getCrtEnabled(tid)
	self.view.custom.draft.crtEnabled = bool(cur)
	self.view.custom.crtBaseline = bool(cur)
```

This needs a small reader. Add to `ignition/projects/Core/ignition/script-python/BlueRidge/Location/Terminal/code.py`:

```python
def getCrtEnabled(terminalLocationId):
    """The terminal's CrtEnabled attribute as a bool. Absent attribute -> False."""
    terminalLocationId = BlueRidge.Common.Util.extractQualifiedValues(terminalLocationId)
    for r in (BlueRidge.Common.Db.execList("location/Terminal_GetAttributes",
                                           {"terminalLocationId": terminalLocationId}) or []):
        if r.get("AttributeName") == "CrtEnabled":
            return str(r.get("AttributeValue") or "0") == "1"
    return False
```

**Before writing this:** check whether a terminal-attribute read NQ already exists (`ls ignition/projects/Core/ignition/named-query/location/`). If one does, use its real name and result columns instead of `Terminal_GetAttributes`. If none exists, reuse whatever `BlueRidge.Location.Terminal.applyToSession` already calls to load terminal attributes rather than adding a new query.

- [ ] **Step 4: Update the Confirm handler**

`ConfirmButton`'s `onActionPerformed` currently calls `ClosureMode.changeover(...)`. Change it to fire only what changed, under one elevation:

```python
	d = self.view.custom.draft
	tid = self.view.params.terminalLocationId
	msgs = []
	ok = True
	if d.newMethod:
		r = BlueRidge.Location.ClosureMode.changeover(tid, d.newMethod, d.adAccount, d.password)
		ok = ok and bool(r.get("Status"))
		msgs.append(r.get("Message") or "")
	if bool(d.crtEnabled) != bool(self.view.custom.crtBaseline):
		r = BlueRidge.Location.ClosureMode.setCrt(tid, d.crtEnabled, d.adAccount, d.password)
		ok = ok and bool(r.get("Status"))
		msgs.append(r.get("Message") or "")
	system.perspective.sendMessage("changeoverResult",
		payload={"ok": ok, "message": " ".join([m for m in msgs if m])}, scope="page")
	if ok:
		system.perspective.closePopup("ChangeoverElevation")
```

Confirm the popup's real id by reading the existing `CancelButton` handler; use whatever string it passes to `closePopup`.

- [ ] **Step 5: Verify the view still parses and scan the gateway**

Run:
```bash
python -c "import json;json.load(open('ignition/projects/MPP/com.inductiveautomation.perspective/views/BlueRidge/Components/Popups/ChangeoverElevation/view.json',encoding='utf-8'));print('valid JSON')"
./scan.ps1
```
Expected: `valid JSON`, and the scan completes without error.

- [ ] **Step 6: Commit**

```bash
git add ignition/projects/MPP/com.inductiveautomation.perspective/views/BlueRidge/Components/Popups/ChangeoverElevation/view.json ignition/projects/Core/ignition/script-python/BlueRidge/Location/Terminal/code.py
git commit -m "feat(crt): CRT switch on the changeover popup"
```

---

## Task 7: Assembly OUT button and the validation popup

**Files:**
- Create: `ignition/projects/MPP/com.inductiveautomation.perspective/views/BlueRidge/Components/Popups/CrtValidation/view.json`
- Create: `ignition/projects/MPP/com.inductiveautomation.perspective/views/BlueRidge/Components/Popups/CrtValidation/resource.json`
- Create: `ignition/projects/MPP/com.inductiveautomation.perspective/views/BlueRidge/Components/PlantFloor/CrtContainerRow/view.json`
- Create: `ignition/projects/MPP/com.inductiveautomation.perspective/views/BlueRidge/Components/PlantFloor/CrtContainerRow/resource.json`
- Modify: `ignition/projects/MPP/com.inductiveautomation.perspective/views/BlueRidge/Views/ShopFloor/AssemblyNonSerialized/view.json`

**Interfaces:**
- Consumes: `BlueRidge.Lots.Container.listPendingValidation(locationId, _refreshToken)` (Task 4), `BlueRidge.Lots.Container.validateCrt(...)` (Task 5), `Quality.Hold_Place` via the existing `BlueRidge.Quality.Hold` wrapper.

**A `resource.json` is mandatory** for every new view folder — a folder with only `view.json` is invisible to the gateway and never renders.

- [ ] **Step 1: Create the row component**

`CrtContainerRow/view.json`: a flex row, `props.defaultSize` `{"height": 44, "width": 1200}`, root style carrying `overflow: hidden`. Params: `containerId`, `partNumber`, `description`, `pieceCount`, `completedAt`, `aimShipperId`, `ageMinutes`. Two buttons on the right — `BtnValidate` (`classes: "btn btn-primary btn-sm"`) and `BtnHold` (`classes: "btn btn-sm"`) — each sending a page-scoped message rather than acting directly, so the popup owns the credentials:

```python
	system.perspective.sendMessage("crtRowAction",
		payload={"action": "validate", "containerId": self.view.params.containerId}, scope="page")
```

Precompute nothing date-shaped in the row: pass `completedAt` in already-formatted, because date values serialise to strings inside a repeater child and `dateFormat` misrenders there.

Create `resource.json` by copying `ignition/projects/MPP/com.inductiveautomation.perspective/views/BlueRidge/Components/PlantFloor/PrinterCard/resource.json`.

- [ ] **Step 2: Create the popup shell**

`CrtValidation/view.json`, `defaultSize` `{"height": 620, "width": 900}`. Params: `terminalLocationId`, `lineLocationId`. Custom block, fully shaped so first paint has no nested-path errors:

```json
"custom": {
  "elevated": false,
  "elevatedAppUserId": null,
  "adAccount": "",
  "password": "",
  "refreshToken": 0,
  "rows": []
}
```

Structure: `Header` (title + close X) / `ElevationGate` (AD account + password + Unlock button) / `ListPanel` (column header + flex-repeater over `CrtContainerRow`) / `Footer`.

`ElevationGate` and `ListPanel` toggle on `view.custom.elevated` via **`position.display`**, not `meta.visible`.

The repeater must use `useDefaultViewHeight: true` with `elementPosition` `{"basis": "44px", "shrink": 0}` and `elementStyle` `{"overflow": "hidden"}` — `basis: "auto"` with `useDefaultViewHeight: false` lets rows compress into each other.

Bind `custom.rows`:

```
runScript("BlueRidge.Lots.Container.listPendingValidation", 0, {view.params.lineLocationId}, {view.custom.refreshToken})
```

The refresh token must be an **argument**, not just referenced in a condition — `runScript` caches on its arguments.

- [ ] **Step 3: Wire the elevation gate**

`Unlock`'s `onActionPerformed`:

```python
	el = BlueRidge.Location.AppUser.elevate(self.view.custom.adAccount, self.view.custom.password,
		"CrtValidation", self.view.params.terminalLocationId)
	if el and el.get("success"):
		self.view.custom.elevated = True
		self.view.custom.elevatedAppUserId = el.get("appUserId")
		self.view.custom.password = ""   # credentials are not retained; the id is
	else:
		system.perspective.sendMessage("toast",
			payload={"kind": "error", "text": (el or {}).get("message") or "Elevation failed."}, scope="session")
```

Confirm the real toast message name and payload shape by reading an existing plant-floor view that raises one; use that shape rather than inventing one.

- [ ] **Step 4: Handle the row actions**

Add a page-scoped `crtRowAction` message handler on the popup root. **One elevation covers both buttons** — the operator is not prompted again per row, so the stored credentials are reused:

```python
	cid = payload.get("containerId")
	if payload.get("action") == "validate":
		r = BlueRidge.Lots.Container.validateCrt(cid, self.view.custom.elevatedAppUserId,
			self.view.params.terminalLocationId)
	else:
		r = BlueRidge.Quality.Hold.placeOnContainer(cid, self.view.params.terminalLocationId)
	system.perspective.sendMessage("toast",
		payload={"kind": "info" if r.get("Status") else "error", "text": r.get("Message") or ""}, scope="session")
	self.view.custom.refreshToken = self.view.custom.refreshToken + 1
```

The popup is the **only** elevation site: Step 3 captures `elevatedAppUserId` and discards the password, and both row actions pass that id down. Nothing below this popup re-prompts.

Confirm `BlueRidge.Quality.Hold.placeOnContainer` exists with that name by reading `ignition/projects/Core/ignition/script-python/BlueRidge/Quality/Hold/code.py`. If the real wrapper takes different arguments (it needs a `HoldTypeCodeId`), use the real signature and pick the seeded hold type the Hold Management screen uses for a container hold.

- [ ] **Step 5: Add the button to Assembly OUT**

In `AssemblyNonSerialized/view.json`, add a `BtnCrtValidation` button to the existing header/action row. Bind `position.display`:

```
{view.custom.crtEnabled} || len({view.custom.crtPending}) > 0
```

Declare **both** custom properties with fully-shaped defaults (`false` and `[]`) in the view's `custom` block — a binding that measures a property which does not yet exist renders a Component Error.

`onActionPerformed` opens the popup:

```python
	system.perspective.openPopup("CrtValidation",
		"BlueRidge/Components/Popups/CrtValidation",
		params={"terminalLocationId": self.session.custom.terminal.terminalLocationId,
		        "lineLocationId": self.session.custom.cell.locationId},
		modal=True)
```

Confirm the real session paths for the terminal and cell ids by reading how a neighbouring button in the same view reads them.

- [ ] **Step 6: Verify and scan**

Run:
```bash
python -c "import json,glob;[json.load(open(f,encoding='utf-8')) for f in glob.glob('ignition/projects/MPP/com.inductiveautomation.perspective/views/BlueRidge/Components/Popups/CrtValidation/view.json')+glob.glob('ignition/projects/MPP/com.inductiveautomation.perspective/views/BlueRidge/Components/PlantFloor/CrtContainerRow/view.json')+glob.glob('ignition/projects/MPP/com.inductiveautomation.perspective/views/BlueRidge/Views/ShopFloor/AssemblyNonSerialized/view.json')];print('all valid JSON')"
./scan.ps1
```
Expected: `all valid JSON`, scan clean.

- [ ] **Step 7: Add the plantFloor CSS rules**

Any new plant-floor route or component needs an explicit rule in the Core stylesheet or it renders unstyled. Add rules for the new row and popup classes alongside the existing `pf-*` entries.

- [ ] **Step 8: Full suite and commit**

Run: `sql\tests\Run-Tests.ps1`
Expected: `Failed: 0`, zero `ERROR running`.

```bash
git add ignition/projects/MPP/com.inductiveautomation.perspective/views/BlueRidge/Components/Popups/CrtValidation ignition/projects/MPP/com.inductiveautomation.perspective/views/BlueRidge/Components/PlantFloor/CrtContainerRow ignition/projects/MPP/com.inductiveautomation.perspective/views/BlueRidge/Views/ShopFloor/AssemblyNonSerialized/view.json
git commit -m "feat(crt): assembly-out validation button and elevated container popup"
```

---

## Gateway smoke (no automated coverage)

None of the Perspective work has automated tests. After Task 7, drive it for real:

1. Open the changeover popup at an assembly-out terminal, enable CRT, confirm the audit row.
2. Complete a container. Confirm the AIM serial is **claimed** (`ConsumedByContainerId` set) and **not posted** (`PostedAt` NULL).
3. Wait past 60 seconds. Confirm `PostedAt` is **still** NULL — this proves the sweep exclusion works, and is the single most important observation in the smoke.
4. Open the validation popup, confirm it demands elevation, validate the container.
5. Confirm `PostedAt` is now set and the container has left the list.
6. Complete another container under CRT and **Hold** it. Confirm it stays listed and unposted.
