# Quality Spec Configuration Tool — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the standalone `/quality-specs` master-detail authoring screen (versioned Draft/Published/Deprecated editor with attribute grid) over the existing `Quality.QualitySpec*` SQL layer, add the Phase 7 "Go to spec →" cross-nav from Item Master, and bring every quality-spec mutation proc onto the audit-readability convention.

**Architecture:** SQL-first. A contained SQL delta (UomId FK migration, bundled `QualitySpecVersion_SaveDraft`, `QualitySpec_Deprecate`, read-proc UOM joins, audit-readability rework) lands and is verified against `sql/tests/0011_Quality_Spec/` before any Ignition work. The front-end mirrors the BOMs versioned-editor reference impl (`BlueRidge.Parts.Bom` + `Components/Parts/ItemMaster/Boms` + `BomLineRow`) — per-section state `view.custom.state = {selected, editDraft}` with atomic writes, binding-based dirty, input-only embeds crossing the boundary via page-scoped messages — but in a standalone master-detail shell (like `LocationTypeEditor`) rather than an Item Master tab. Lifecycle is date-resolved: Publish does NOT auto-deprecate prior Published versions.

**Tech Stack:** SQL Server 2022 (T-SQL stored procs, `sqlcmd` test harness via `Reset-DevDatabase.ps1`), Ignition 8.3 file-based Perspective project (Jython script-python, named queries, `view.json`), `scan.ps1` gateway scan.

**Spec:** `docs/superpowers/specs/2026-05-28-quality-spec-config-tool-design.md`

---

## Conventions reference (read before starting)

- **Proc shape:** `SET NOCOUNT ON; SET XACT_ABORT ON;` → declare `@Status BIT=0, @Message NVARCHAR(500), @NewId BIGINT=NULL` → `@ProcName` + `@Params` (FOR JSON PATH, WITHOUT_ARRAY_WRAPPER) → `BEGIN TRY` validation (each failure path EXECs `Audit.Audit_LogFailure` then `SELECT @Status, @Message[, @NewId]; RETURN;`) → `BEGIN TRANSACTION` mutation + `Audit.Audit_LogConfigChange` → `COMMIT` → success `SELECT`. `BEGIN CATCH` rolls back, logs failure, `SELECT`, `RAISERROR`. Timestamps via `SYSUTCDATETIME()`. Copy the exact skeleton from `sql/migrations/repeatable/R__Quality_QualitySpec_Create.sql`.
- **NQ resource.json:** `scope:"DG"`, `version:2`, mutations AND reads both use `attributes.type:"Query"` (status-row procs throw under `UpdateQuery` — memory `feedback_ignition_nq_type_for_status_row_procs`). `sqlType`: BIGINT=3, NVARCHAR/JSON=7, DateTime=8, Boolean=6, DECIMAL=5. Clone shape from an existing `named-query/quality/QualitySpec_ListForItem/resource.json`.
- **Entity script:** all DB access via `BlueRidge.Common.Db.{execList,execOne,execMutation}`; `@AppUserId` via `BlueRidge.Common.Util._currentAppUserId()`; deep-unwrap every entry point with `_u(x) = BlueRidge.Common.Util.extractQualifiedValues(x)`; JSON via `system.util.jsonEncode`.
- **View:** root `meta.name:"root"`; atomic state writes (`view.custom.state = {"selected":…,"editDraft":…}` in ONE assignment); `position.display` for flex visibility; embed sub-view params `paramDirection:"input"` only — edits cross via `scope:"page"` messages; event-script bodies start with `\t`; `system.perspective.*` from dom-event scripts need `scope:"G"`; no `forEach` in expressions (use property binding + script transform); Designer writes `=`→`=` etc.
- **After any new/changed Ignition resource:** run `.\scan.ps1` at repo root.
- **SQL test loop:** `.\Reset-DevDatabase.ps1` rebuilds dev DB from all migrations + repeatable procs + runs all test files; a non-zero exit / `Msg` line = failure.

---

## Phase A — SQL

### Task A1: Migration — add `UomId` FK + `QualitySpec.DeprecatedAt`

**Files:**
- Create: `sql/migrations/versioned/0017_qualityspec_attribute_uom_fk.sql`

- [ ] **Step 1: Write the migration**

```sql
-- =============================================
-- Migration: 0017_qualityspec_attribute_uom_fk
-- Adds UomId FK to Quality.QualitySpecAttribute (replaces free-text Uom usage
-- by the Config Tool editor) and a soft-delete marker to Quality.QualitySpec
-- so specs can be deprecated at the header level.
-- =============================================

-- 1. QualitySpecAttribute.UomId -> Parts.Uom
IF NOT EXISTS (SELECT 1 FROM sys.columns
              WHERE object_id = OBJECT_ID(N'Quality.QualitySpecAttribute') AND name = N'UomId')
BEGIN
    ALTER TABLE Quality.QualitySpecAttribute ADD UomId BIGINT NULL;
END
GO

IF NOT EXISTS (SELECT 1 FROM sys.foreign_keys WHERE name = N'FK_QualitySpecAttribute_Uom')
BEGIN
    ALTER TABLE Quality.QualitySpecAttribute
        ADD CONSTRAINT FK_QualitySpecAttribute_Uom
        FOREIGN KEY (UomId) REFERENCES Parts.Uom(Id);
END
GO

-- 2. QualitySpec soft-delete columns
IF NOT EXISTS (SELECT 1 FROM sys.columns
              WHERE object_id = OBJECT_ID(N'Quality.QualitySpec') AND name = N'DeprecatedAt')
BEGIN
    ALTER TABLE Quality.QualitySpec ADD DeprecatedAt DATETIME2(3) NULL;
    ALTER TABLE Quality.QualitySpec ADD DeprecatedByUserId BIGINT NULL;
END
GO

IF NOT EXISTS (SELECT 1 FROM sys.foreign_keys WHERE name = N'FK_QualitySpec_DeprecatedByUser')
BEGIN
    ALTER TABLE Quality.QualitySpec
        ADD CONSTRAINT FK_QualitySpec_DeprecatedByUser
        FOREIGN KEY (DeprecatedByUserId) REFERENCES Audit.AppUser(Id);
END
GO
```

> Confirm `Audit.AppUser` is the correct user table name during build (grep an existing `DeprecatedByUserId` FK, e.g. in `Parts.Item`). Adjust the referenced table if the project uses a different name.

- [ ] **Step 2: Run reset to apply**

Run: `.\Reset-DevDatabase.ps1`
Expected: migration 0017 applied, `SchemaVersion` row added, no `Msg` errors. (Procs that still reference free-text `Uom` keep working — the column is untouched.)

- [ ] **Step 3: Commit**

```bash
git add sql/migrations/versioned/0017_qualityspec_attribute_uom_fk.sql
git commit -m "feat(sql): add UomId FK to QualitySpecAttribute + DeprecatedAt to QualitySpec"
```

---

### Task A2: Rework `QualitySpecVersion_CreateNewVersion` to clone `UomId` + readable audit

**Files:**
- Modify: `sql/migrations/repeatable/R__Quality_QualitySpecVersion_CreateNewVersion.sql`

- [ ] **Step 1: Update the attribute-clone INSERT to carry UomId**

Replace the clone block (currently copying `Uom`) so it copies BOTH `Uom` (legacy) and `UomId`:

```sql
        -- Clone attributes from source version
        INSERT INTO Quality.QualitySpecAttribute
            (QualitySpecVersionId, AttributeName, DataType, Uom, UomId,
             TargetValue, LowerLimit, UpperLimit, IsRequired, SortOrder)
        SELECT
            @NewId, AttributeName, DataType, Uom, UomId,
            TargetValue, LowerLimit, UpperLimit, IsRequired, SortOrder
        FROM Quality.QualitySpecAttribute
        WHERE QualitySpecVersionId = @SourceVersionId
        ORDER BY SortOrder;
```

- [ ] **Step 2: Replace the audit `@Description` with the readable convention**

Add subject resolution near the top of `BEGIN TRY` (after `@SourceExists`/`@QualitySpecId` are known), then compose Description. Insert before the `EXEC Audit.Audit_LogConfigChange`:

```sql
        DECLARE @MidDot NCHAR(1) = NCHAR(183);
        DECLARE @SpecName NVARCHAR(200), @ItemId BIGINT, @PartNumber NVARCHAR(50), @ItemDesc NVARCHAR(500);
        SELECT @SpecName = qs.Name, @ItemId = qs.ItemId,
               @PartNumber = i.PartNumber, @ItemDesc = i.Description
        FROM Quality.QualitySpec qs
        LEFT JOIN Parts.Item i ON i.Id = qs.ItemId
        WHERE qs.Id = @QualitySpecId;

        DECLARE @Subject NVARCHAR(400) =
            CASE WHEN @PartNumber IS NOT NULL
                 THEN @PartNumber + N' ' + @MidDot + N' '
                 ELSE N'' END;
        DECLARE @AuditDesc NVARCHAR(500) =
            @Subject + N'Quality Spec "' + @SpecName + N'" v' +
            CAST(@NewVersionNumber AS NVARCHAR(10)) +
            N' (Draft) ' + @MidDot + N' Created (cloned from source; ' +
            CAST(@AttrCount AS NVARCHAR(10)) + N' attributes)';
```

Then change the `EXEC Audit.Audit_LogConfigChange ... @Description = N'Quality spec version created from clone (Draft).'` to `@Description = @AuditDesc`. (`@AttrCount` is already declared after the clone INSERT — move the `@AttrCount` declaration above this block, or reference it after the INSERT; ensure declaration precedes use.)

- [ ] **Step 3: Run reset + tests**

Run: `.\Reset-DevDatabase.ps1`
Expected: all existing `0011_Quality_Spec` tests still pass (clone now also copies UomId; existing tests don't assert UomId yet so they stay green).

- [ ] **Step 4: Commit**

```bash
git add sql/migrations/repeatable/R__Quality_QualitySpecVersion_CreateNewVersion.sql
git commit -m "feat(sql): clone UomId in QualitySpecVersion_CreateNewVersion + readable audit"
```

---

### Task A3: New proc — `QualitySpecVersion_SaveDraft` (bundled attribute reconciliation)

**Files:**
- Create: `sql/migrations/repeatable/R__Quality_QualitySpecVersion_SaveDraft.sql`
- Test: `sql/tests/0011_Quality_Spec/050_QualitySpecVersion_SaveDraft.sql`

- [ ] **Step 1: Write the failing test**

```sql
-- 050_QualitySpecVersion_SaveDraft.sql
SET NOCOUNT ON;
DECLARE @User BIGINT = (SELECT TOP 1 Id FROM Audit.AppUser ORDER BY Id);
DECLARE @Item BIGINT = (SELECT TOP 1 Id FROM Parts.Item WHERE DeprecatedAt IS NULL ORDER BY Id);
DECLARE @Ea   BIGINT = (SELECT TOP 1 Id FROM Parts.Uom ORDER BY Id);

-- Arrange: spec + v1 draft
DECLARE @SpecRes TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO @SpecRes EXEC Quality.QualitySpec_Create
    @Name = N'TEST SaveDraft Spec', @ItemId = @Item, @AppUserId = @User;
DECLARE @SpecId BIGINT = (SELECT NewId FROM @SpecRes);

DECLARE @VerRes TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO @VerRes EXEC Quality.QualitySpecVersion_Create
    @QualitySpecId = @SpecId, @EffectiveFrom = NULL, @AppUserId = @User;
DECLARE @VerId BIGINT = (SELECT NewId FROM @VerRes);

-- Act: SaveDraft with 2 attributes (both Id null = INSERT)
DECLARE @Json NVARCHAR(MAX) = N'[
  {"Id":null,"AttributeName":"Bore Dia","DataType":"Numeric","UomId":' + CAST(@Ea AS NVARCHAR(20)) + ',"TargetValue":25.40,"LowerLimit":25.38,"UpperLimit":25.42,"IsRequired":1},
  {"Id":null,"AttributeName":"Porosity","DataType":"Boolean","UomId":null,"TargetValue":null,"LowerLimit":null,"UpperLimit":null,"IsRequired":1}
]';
DECLARE @SaveRes TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO @SaveRes EXEC Quality.QualitySpecVersion_SaveDraft
    @QualitySpecVersionId = @VerId, @EffectiveFrom = NULL, @AttributesJson = @Json, @AppUserId = @User;

-- Assert: status 1, 2 attributes, SortOrder 1/2
IF (SELECT Status FROM @SaveRes) <> 1 RAISERROR('FAIL: SaveDraft Status not 1', 16, 1);
IF (SELECT COUNT(*) FROM Quality.QualitySpecAttribute WHERE QualitySpecVersionId = @VerId) <> 2
    RAISERROR('FAIL: expected 2 attributes after SaveDraft', 16, 1);
IF NOT EXISTS (SELECT 1 FROM Quality.QualitySpecAttribute
               WHERE QualitySpecVersionId = @VerId AND AttributeName = N'Bore Dia' AND SortOrder = 1 AND UomId = @Ea)
    RAISERROR('FAIL: Bore Dia attribute not reconciled with UomId/SortOrder', 16, 1);

-- Act 2: SaveDraft again — keep Bore Dia (by Id), drop Porosity, add Surface
DECLARE @BoreId BIGINT = (SELECT Id FROM Quality.QualitySpecAttribute WHERE QualitySpecVersionId = @VerId AND AttributeName = N'Bore Dia');
DECLARE @Json2 NVARCHAR(MAX) = N'[
  {"Id":' + CAST(@BoreId AS NVARCHAR(20)) + ',"AttributeName":"Bore Dia","DataType":"Numeric","UomId":' + CAST(@Ea AS NVARCHAR(20)) + ',"TargetValue":25.40,"LowerLimit":25.38,"UpperLimit":25.42,"IsRequired":1},
  {"Id":null,"AttributeName":"Surface","DataType":"Text","UomId":null,"TargetValue":null,"LowerLimit":null,"UpperLimit":null,"IsRequired":0}
]';
INSERT INTO @SaveRes EXEC Quality.QualitySpecVersion_SaveDraft
    @QualitySpecVersionId = @VerId, @EffectiveFrom = NULL, @AttributesJson = @Json2, @AppUserId = @User;

IF (SELECT COUNT(*) FROM Quality.QualitySpecAttribute WHERE QualitySpecVersionId = @VerId) <> 2
    RAISERROR('FAIL: expected 2 attributes after reconcile (drop Porosity, add Surface)', 16, 1);
IF EXISTS (SELECT 1 FROM Quality.QualitySpecAttribute WHERE QualitySpecVersionId = @VerId AND AttributeName = N'Porosity')
    RAISERROR('FAIL: Porosity should have been deleted', 16, 1);

PRINT 'PASS: 050_QualitySpecVersion_SaveDraft';
```

- [ ] **Step 2: Run reset to verify the test fails**

Run: `.\Reset-DevDatabase.ps1`
Expected: FAIL — `Could not find stored procedure 'Quality.QualitySpecVersion_SaveDraft'`.

- [ ] **Step 3: Write the proc**

```sql
-- =============================================
-- Procedure:   Quality.QualitySpecVersion_SaveDraft
-- Bundled attribute reconciliation for a Draft version. Desired-state
-- JSON: Id-null=INSERT, Id-match=UPDATE, active Id absent=DELETE.
-- SortOrder = 1-based array index. Only operates on a Draft version.
-- =============================================
CREATE OR ALTER PROCEDURE Quality.QualitySpecVersion_SaveDraft
    @QualitySpecVersionId BIGINT,
    @EffectiveFrom        DATETIME2(3)  = NULL,
    @AttributesJson       NVARCHAR(MAX) = N'[]',
    @AppUserId            BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Status  BIT           = 0;
    DECLARE @Message NVARCHAR(500) = N'Unknown error';
    DECLARE @NewId   BIGINT        = NULL;   -- echoes version id

    DECLARE @ProcName NVARCHAR(200) = N'Quality.QualitySpecVersion_SaveDraft';
    DECLARE @Params   NVARCHAR(MAX) =
        (SELECT @QualitySpecVersionId AS QualitySpecVersionId, @EffectiveFrom AS EffectiveFrom
         FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

    BEGIN TRY
        IF @QualitySpecVersionId IS NULL OR @AppUserId IS NULL
        BEGIN
            SET @Message = N'Required parameter missing.';
            EXEC Audit.Audit_LogFailure @AppUserId=@AppUserId, @LogEntityTypeCode=N'QualitySpecVersion',
                @EntityId=@QualitySpecVersionId, @LogEventTypeCode=N'Updated',
                @FailureReason=@Message, @ProcedureName=@ProcName, @AttemptedParameters=@Params;
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId; RETURN;
        END

        DECLARE @PublishedAt DATETIME2(3), @DeprecatedAt DATETIME2(3),
                @SpecId BIGINT, @VersionNumber INT, @RowExists BIT = 0;
        SELECT @PublishedAt = PublishedAt, @DeprecatedAt = DeprecatedAt,
               @SpecId = QualitySpecId, @VersionNumber = VersionNumber, @RowExists = 1
        FROM Quality.QualitySpecVersion WHERE Id = @QualitySpecVersionId;

        IF @RowExists = 0
        BEGIN
            SET @Message = N'Version not found.';
            EXEC Audit.Audit_LogFailure @AppUserId=@AppUserId, @LogEntityTypeCode=N'QualitySpecVersion',
                @EntityId=@QualitySpecVersionId, @LogEventTypeCode=N'Updated',
                @FailureReason=@Message, @ProcedureName=@ProcName, @AttemptedParameters=@Params;
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId; RETURN;
        END
        IF @PublishedAt IS NOT NULL OR @DeprecatedAt IS NOT NULL
        BEGIN
            SET @Message = N'Only Draft versions can be saved.';
            EXEC Audit.Audit_LogFailure @AppUserId=@AppUserId, @LogEntityTypeCode=N'QualitySpecVersion',
                @EntityId=@QualitySpecVersionId, @LogEventTypeCode=N'Updated',
                @FailureReason=@Message, @ProcedureName=@ProcName, @AttemptedParameters=@Params;
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId; RETURN;
        END

        -- Shred incoming JSON into a typed temp table with 1-based ordinal
        DECLARE @Incoming TABLE (
            Ord INT, Id BIGINT, AttributeName NVARCHAR(100), DataType NVARCHAR(50),
            UomId BIGINT, TargetValue DECIMAL(18,6), LowerLimit DECIMAL(18,6),
            UpperLimit DECIMAL(18,6), IsRequired BIT);
        INSERT INTO @Incoming (Ord, Id, AttributeName, DataType, UomId, TargetValue, LowerLimit, UpperLimit, IsRequired)
        SELECT
            ([key] + 1),
            JSON_VALUE(value, '$.Id'),
            JSON_VALUE(value, '$.AttributeName'),
            JSON_VALUE(value, '$.DataType'),
            JSON_VALUE(value, '$.UomId'),
            JSON_VALUE(value, '$.TargetValue'),
            JSON_VALUE(value, '$.LowerLimit'),
            JSON_VALUE(value, '$.UpperLimit'),
            ISNULL(JSON_VALUE(value, '$.IsRequired'), 1)
        FROM OPENJSON(@AttributesJson);

        BEGIN TRANSACTION;

        UPDATE Quality.QualitySpecVersion
            SET EffectiveFrom = ISNULL(@EffectiveFrom, EffectiveFrom)
        WHERE Id = @QualitySpecVersionId;

        -- DELETE: active attrs whose Id is not in incoming
        DELETE a FROM Quality.QualitySpecAttribute a
        WHERE a.QualitySpecVersionId = @QualitySpecVersionId
          AND NOT EXISTS (SELECT 1 FROM @Incoming i WHERE i.Id = a.Id);

        -- UPDATE: incoming rows with a matching Id
        UPDATE a SET
            a.AttributeName = i.AttributeName, a.DataType = i.DataType,
            a.UomId = i.UomId, a.TargetValue = i.TargetValue,
            a.LowerLimit = i.LowerLimit, a.UpperLimit = i.UpperLimit,
            a.IsRequired = i.IsRequired, a.SortOrder = i.Ord
        FROM Quality.QualitySpecAttribute a
        INNER JOIN @Incoming i ON i.Id = a.Id
        WHERE a.QualitySpecVersionId = @QualitySpecVersionId;

        -- INSERT: incoming rows with Id null
        INSERT INTO Quality.QualitySpecAttribute
            (QualitySpecVersionId, AttributeName, DataType, UomId, TargetValue, LowerLimit, UpperLimit, IsRequired, SortOrder)
        SELECT @QualitySpecVersionId, i.AttributeName, i.DataType, i.UomId,
               i.TargetValue, i.LowerLimit, i.UpperLimit, i.IsRequired, i.Ord
        FROM @Incoming i WHERE i.Id IS NULL;

        -- Readable audit
        DECLARE @MidDot NCHAR(1) = NCHAR(183);
        DECLARE @SpecName NVARCHAR(200), @PartNumber NVARCHAR(50);
        SELECT @SpecName = qs.Name, @PartNumber = pi.PartNumber
        FROM Quality.QualitySpec qs LEFT JOIN Parts.Item pi ON pi.Id = qs.ItemId
        WHERE qs.Id = @SpecId;
        DECLARE @AttrTotal INT = (SELECT COUNT(*) FROM Quality.QualitySpecAttribute WHERE QualitySpecVersionId = @QualitySpecVersionId);
        DECLARE @AuditDesc NVARCHAR(500) =
            CASE WHEN @PartNumber IS NOT NULL THEN @PartNumber + N' ' + @MidDot + N' ' ELSE N'' END
            + N'Quality Spec "' + @SpecName + N'" v' + CAST(@VersionNumber AS NVARCHAR(10))
            + N' (Draft) ' + @MidDot + N' Saved; ' + CAST(@AttrTotal AS NVARCHAR(10)) + N' attributes';
        DECLARE @NewValue NVARCHAR(MAX) = (
            SELECT a.Id, a.AttributeName, a.DataType,
                   (SELECT u.Id, u.Code, u.Name FROM Parts.Uom u WHERE u.Id = a.UomId
                    FOR JSON PATH, WITHOUT_ARRAY_WRAPPER) AS Uom,
                   a.TargetValue, a.LowerLimit, a.UpperLimit, a.IsRequired, a.SortOrder
            FROM Quality.QualitySpecAttribute a
            WHERE a.QualitySpecVersionId = @QualitySpecVersionId
            ORDER BY a.SortOrder FOR JSON PATH);

        EXEC Audit.Audit_LogConfigChange
            @AppUserId=@AppUserId, @LogEntityTypeCode=N'QualitySpecVersion',
            @EntityId=@QualitySpecVersionId, @LogEventTypeCode=N'Updated',
            @LogSeverityCode=N'Info', @Description=@AuditDesc,
            @OldValue=NULL, @NewValue=@NewValue;

        COMMIT TRANSACTION;

        SET @Status = 1; SET @NewId = @QualitySpecVersionId;
        SET @Message = N'Draft saved (' + CAST(@AttrTotal AS NVARCHAR(10)) + N' attributes).';
        SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        DECLARE @ErrMsg NVARCHAR(4000)=ERROR_MESSAGE(), @ErrSev INT=ERROR_SEVERITY(), @ErrState INT=ERROR_STATE();
        SET @Status=0; SET @NewId=NULL; SET @Message=N'Unexpected error: ' + LEFT(@ErrMsg,400);
        BEGIN TRY
            EXEC Audit.Audit_LogFailure @AppUserId=@AppUserId, @LogEntityTypeCode=N'QualitySpecVersion',
                @EntityId=@QualitySpecVersionId, @LogEventTypeCode=N'Updated',
                @FailureReason=@Message, @ProcedureName=@ProcName, @AttemptedParameters=@Params;
        END TRY BEGIN CATCH END CATCH
        SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
        RAISERROR(@ErrMsg, @ErrSev, @ErrState);
    END CATCH
END
GO
```

- [ ] **Step 4: Run reset + tests to verify pass**

Run: `.\Reset-DevDatabase.ps1`
Expected: `PASS: 050_QualitySpecVersion_SaveDraft`, all other tests still green.

- [ ] **Step 5: Commit**

```bash
git add sql/migrations/repeatable/R__Quality_QualitySpecVersion_SaveDraft.sql sql/tests/0011_Quality_Spec/050_QualitySpecVersion_SaveDraft.sql
git commit -m "feat(sql): QualitySpecVersion_SaveDraft bundled attribute reconciliation"
```

---

### Task A4: New proc — `QualitySpec_Deprecate` (header soft-delete + cascade)

**Files:**
- Create: `sql/migrations/repeatable/R__Quality_QualitySpec_Deprecate.sql`
- Test: `sql/tests/0011_Quality_Spec/060_QualitySpec_Deprecate.sql`

- [ ] **Step 1: Write the failing test**

```sql
-- 060_QualitySpec_Deprecate.sql
SET NOCOUNT ON;
DECLARE @User BIGINT = (SELECT TOP 1 Id FROM Audit.AppUser ORDER BY Id);
DECLARE @SpecRes TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO @SpecRes EXEC Quality.QualitySpec_Create @Name=N'TEST Deprecate Spec', @AppUserId=@User;
DECLARE @SpecId BIGINT = (SELECT NewId FROM @SpecRes);
DECLARE @VerRes TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO @VerRes EXEC Quality.QualitySpecVersion_Create @QualitySpecId=@SpecId, @AppUserId=@User;

DECLARE @DepRes TABLE (Status BIT, Message NVARCHAR(500));
INSERT INTO @DepRes EXEC Quality.QualitySpec_Deprecate @QualitySpecId=@SpecId, @AppUserId=@User;

IF (SELECT Status FROM @DepRes) <> 1 RAISERROR('FAIL: deprecate status not 1', 16, 1);
IF (SELECT DeprecatedAt FROM Quality.QualitySpec WHERE Id=@SpecId) IS NULL
    RAISERROR('FAIL: spec DeprecatedAt not set', 16, 1);
IF EXISTS (SELECT 1 FROM Quality.QualitySpecVersion WHERE QualitySpecId=@SpecId AND DeprecatedAt IS NULL)
    RAISERROR('FAIL: child versions not cascade-deprecated', 16, 1);
PRINT 'PASS: 060_QualitySpec_Deprecate';
```

- [ ] **Step 2: Run reset to verify it fails**

Run: `.\Reset-DevDatabase.ps1`
Expected: FAIL — `Could not find stored procedure 'Quality.QualitySpec_Deprecate'`.

- [ ] **Step 3: Write the proc**

```sql
-- =============================================
-- Procedure:   Quality.QualitySpec_Deprecate
-- Soft-deletes a QualitySpec header and cascade-deprecates its
-- non-deprecated versions. Idempotent on already-deprecated specs.
-- =============================================
CREATE OR ALTER PROCEDURE Quality.QualitySpec_Deprecate
    @QualitySpecId BIGINT,
    @AppUserId     BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    DECLARE @Status BIT = 0, @Message NVARCHAR(500) = N'Unknown error';
    DECLARE @ProcName NVARCHAR(200) = N'Quality.QualitySpec_Deprecate';
    DECLARE @Params NVARCHAR(MAX) = (SELECT @QualitySpecId AS QualitySpecId FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

    BEGIN TRY
        IF @QualitySpecId IS NULL OR @AppUserId IS NULL
        BEGIN
            SET @Message = N'Required parameter missing.';
            EXEC Audit.Audit_LogFailure @AppUserId=@AppUserId, @LogEntityTypeCode=N'QualitySpec',
                @EntityId=@QualitySpecId, @LogEventTypeCode=N'Deprecated',
                @FailureReason=@Message, @ProcedureName=@ProcName, @AttemptedParameters=@Params;
            SELECT @Status AS Status, @Message AS Message; RETURN;
        END

        DECLARE @SpecName NVARCHAR(200), @PartNumber NVARCHAR(50), @RowExists BIT = 0;
        SELECT @SpecName = qs.Name, @PartNumber = pi.PartNumber, @RowExists = 1
        FROM Quality.QualitySpec qs LEFT JOIN Parts.Item pi ON pi.Id = qs.ItemId
        WHERE qs.Id = @QualitySpecId;

        IF @RowExists = 0
        BEGIN
            SET @Message = N'Quality spec not found.';
            EXEC Audit.Audit_LogFailure @AppUserId=@AppUserId, @LogEntityTypeCode=N'QualitySpec',
                @EntityId=@QualitySpecId, @LogEventTypeCode=N'Deprecated',
                @FailureReason=@Message, @ProcedureName=@ProcName, @AttemptedParameters=@Params;
            SELECT @Status AS Status, @Message AS Message; RETURN;
        END

        BEGIN TRANSACTION;
        UPDATE Quality.QualitySpec
            SET DeprecatedAt = SYSUTCDATETIME(), DeprecatedByUserId = @AppUserId
        WHERE Id = @QualitySpecId AND DeprecatedAt IS NULL;

        UPDATE Quality.QualitySpecVersion
            SET DeprecatedAt = SYSUTCDATETIME()
        WHERE QualitySpecId = @QualitySpecId AND DeprecatedAt IS NULL;

        DECLARE @MidDot NCHAR(1) = NCHAR(183);
        DECLARE @AuditDesc NVARCHAR(500) =
            CASE WHEN @PartNumber IS NOT NULL THEN @PartNumber + N' ' + @MidDot + N' ' ELSE N'' END
            + N'Quality Spec "' + @SpecName + N'" ' + @MidDot + N' Deprecated';
        EXEC Audit.Audit_LogConfigChange
            @AppUserId=@AppUserId, @LogEntityTypeCode=N'QualitySpec',
            @EntityId=@QualitySpecId, @LogEventTypeCode=N'Deprecated',
            @LogSeverityCode=N'Info', @Description=@AuditDesc, @OldValue=NULL, @NewValue=@Params;
        COMMIT TRANSACTION;

        SET @Status = 1; SET @Message = N'Quality spec deprecated.';
        SELECT @Status AS Status, @Message AS Message;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        DECLARE @ErrMsg NVARCHAR(4000)=ERROR_MESSAGE(), @ErrSev INT=ERROR_SEVERITY(), @ErrState INT=ERROR_STATE();
        SET @Status=0; SET @Message=N'Unexpected error: ' + LEFT(@ErrMsg,400);
        BEGIN TRY
            EXEC Audit.Audit_LogFailure @AppUserId=@AppUserId, @LogEntityTypeCode=N'QualitySpec',
                @EntityId=@QualitySpecId, @LogEventTypeCode=N'Deprecated',
                @FailureReason=@Message, @ProcedureName=@ProcName, @AttemptedParameters=@Params;
        END TRY BEGIN CATCH END CATCH
        SELECT @Status AS Status, @Message AS Message;
        RAISERROR(@ErrMsg, @ErrSev, @ErrState);
    END CATCH
END
GO
```

- [ ] **Step 4: Run reset + tests to verify pass**

Run: `.\Reset-DevDatabase.ps1`
Expected: `PASS: 060_QualitySpec_Deprecate`, all others green.

- [ ] **Step 5: Commit**

```bash
git add sql/migrations/repeatable/R__Quality_QualitySpec_Deprecate.sql sql/tests/0011_Quality_Spec/060_QualitySpec_Deprecate.sql
git commit -m "feat(sql): QualitySpec_Deprecate header soft-delete + cascade"
```

---

### Task A5: `QualitySpecAttribute_ListByVersion` — join `Parts.Uom` for display

**Files:**
- Modify: `sql/migrations/repeatable/R__Quality_QualitySpecAttribute_ListByVersion.sql`

- [ ] **Step 1: Add UomId + UomCode/UomName to the SELECT**

Open the file; add the FK join + columns to the existing SELECT (keep all current columns; add these):

```sql
        a.UomId,
        u.Code AS UomCode,
        u.Name AS UomName,
```

and `LEFT JOIN Parts.Uom u ON u.Id = a.UomId` to the FROM. Keep the existing free-text `Uom` column in the SELECT for backward compatibility. Preserve `ORDER BY a.SortOrder`.

- [ ] **Step 2: Run reset to verify no regression**

Run: `.\Reset-DevDatabase.ps1`
Expected: all `0011_Quality_Spec` tests still pass.

- [ ] **Step 3: Commit**

```bash
git add sql/migrations/repeatable/R__Quality_QualitySpecAttribute_ListByVersion.sql
git commit -m "feat(sql): QualitySpecAttribute_ListByVersion joins Parts.Uom"
```

---

### Task A6: Readable-audit rework on remaining quality mutation procs

**Files:**
- Modify: `R__Quality_QualitySpec_Create.sql`, `R__Quality_QualitySpec_Update.sql`, `R__Quality_QualitySpecVersion_Create.sql`, `R__Quality_QualitySpecVersion_Publish.sql`, `R__Quality_QualitySpecVersion_Deprecate.sql`, `R__Quality_QualitySpecVersion_DiscardDraft.sql` (create the DiscardDraft proc if it does not exist — see note)

> **Discard check:** grep `sql/migrations/repeatable/` for `QualitySpecVersion_DiscardDraft`. If absent, create it mirroring `Bom_DiscardDraft` (hard-DELETE the Draft version + cascade its attributes; reject non-Draft). Use the same proc skeleton + readable audit pattern below.

For EACH proc, apply the same two-part change used in A2/A3:
1. Add subject resolution (`@MidDot`, `@SpecName`, `@PartNumber`) before the `Audit.Audit_LogConfigChange` call.
2. Replace the generic `@Description` literal with the composed `@AuditDesc` per the §7 catalog in the spec, and (for OldValue/NewValue) replace bare `@Params` with FK-resolved JSON where the change involves attributes or links.

- [ ] **Step 1: QualitySpec_Create — readable Created line**

Replace `@Description = N'Quality specification created.'` with:

```sql
        DECLARE @MidDot NCHAR(1) = NCHAR(183);
        DECLARE @PartNumber NVARCHAR(50), @ItemDesc NVARCHAR(500);
        SELECT @PartNumber = PartNumber, @ItemDesc = Description FROM Parts.Item WHERE Id = @ItemId;
        DECLARE @AuditDesc NVARCHAR(500) =
            CASE WHEN @PartNumber IS NOT NULL
                 THEN @PartNumber + N' ' + @MidDot + N' ' + @MidDot + N' '  -- subject + spacing
                 ELSE N'' END
            + N'Quality Spec "' + LTRIM(RTRIM(@Name)) + N'" ' + @MidDot + N' Created';
```

and set `@Description = @AuditDesc`. (Simplify the subject spacing to one `· ` separator; the doubled form above is illustrative — use `@PartNumber + N' — ' + ISNULL(@ItemDesc,N'') + N' ' + @MidDot + N' '` for the `5G0 — Front Cover ·` form.)

- [ ] **Step 2: QualitySpec_Update — field-diff Updated line**

Capture old Name/Description before the UPDATE; compose `~`-style field diffs (`Name "old"→"new"`). Set `@OldValue`/`@NewValue` to the old/new header field JSON.

- [ ] **Step 3: QualitySpecVersion_Create — readable Created (v1 Draft)**

Compose `<subject> · Quality Spec "<name>" v1 (Draft) · Created`.

- [ ] **Step 4: QualitySpecVersion_Publish — readable Published (no auto-deprecate suffix)**

Compose `<subject> · Quality Spec "<name>" v<N> · Published; <attrCount> attributes; effective <date>`. **Do NOT** add a "(deprecated vN)" suffix — the date-resolved model keeps prior Published versions. Resolve `@SpecId`/`@SpecName`/`@PartNumber` via join through `QualitySpecId`.

- [ ] **Step 5: QualitySpecVersion_Deprecate — readable Deprecated**

Compose `<subject> · Quality Spec "<name>" v<N> · Deprecated`.

- [ ] **Step 6: QualitySpecVersion_DiscardDraft — readable Discarded**

Compose `<subject> · Quality Spec "<name>" v<N> (Draft) · Discarded`.

- [ ] **Step 7: Add audit-assertion tests**

Append to `sql/tests/0011_Quality_Spec/020_QualitySpecVersion_lifecycle.sql` (or a new `070_QualitySpec_audit.sql`) assertions that the latest `Audit.ConfigLog` row for a publish contains the spec name and `Published` and does NOT contain `deprecated v`:

```sql
DECLARE @Desc NVARCHAR(MAX) = (SELECT TOP 1 Description FROM Audit.ConfigLog
    WHERE LogEntityTypeCode = N'QualitySpecVersion' ORDER BY Id DESC);
IF @Desc NOT LIKE N'%Published%' RAISERROR('FAIL: publish audit not readable', 16, 1);
IF @Desc LIKE N'%deprecated v%' RAISERROR('FAIL: publish should not auto-deprecate', 16, 1);
PRINT 'PASS: 070_QualitySpec_audit';
```

- [ ] **Step 8: Run reset + tests**

Run: `.\Reset-DevDatabase.ps1`
Expected: all `0011_Quality_Spec` tests pass including the new audit assertions. Note the full project test count for the commit message.

- [ ] **Step 9: Commit**

```bash
git add sql/migrations/repeatable/R__Quality_*.sql sql/tests/0011_Quality_Spec/
git commit -m "feat(sql): readable-audit convention across quality-spec mutation procs"
```

---

## Phase B — Named Queries

### Task B1: Create the `quality/` named queries

**Files (each is a folder with `query.sql` + `resource.json`):**
- Create under `ignition/projects/MPP_Config/ignition/named-query/quality/`:
  `QualitySpec_List`, `QualitySpec_Get`, `QualitySpec_Create`, `QualitySpec_Update`, `QualitySpec_Deprecate`, `QualitySpecVersion_ListBySpec`, `QualitySpecVersion_Get`, `QualitySpecVersion_Create`, `QualitySpecVersion_CreateNewVersion`, `QualitySpecVersion_SaveDraft`, `QualitySpecVersion_Publish`, `QualitySpecVersion_Deprecate`, `QualitySpecVersion_DiscardDraft`, `QualitySpecAttribute_ListByVersion`

> `Uom_List` already exists at `named-query/parts/Uom_List` — reuse it (entity script calls `"parts/Uom_List"`). `QualitySpec_ListForItem` already exists — leave it.

- [ ] **Step 1: Write each `query.sql`** (thin EXEC wrappers)

```sql
-- QualitySpec_List/query.sql
EXEC Quality.QualitySpec_List @ItemId = :itemId, @OperationTemplateId = :operationTemplateId
```
```sql
-- QualitySpec_Get/query.sql
EXEC Quality.QualitySpec_Get @Id = :id
```
```sql
-- QualitySpec_Create/query.sql
EXEC Quality.QualitySpec_Create @Name = :name, @ItemId = :itemId,
    @OperationTemplateId = :operationTemplateId, @Description = :description, @AppUserId = :appUserId
```
```sql
-- QualitySpec_Update/query.sql
EXEC Quality.QualitySpec_Update @Id = :id, @Name = :name, @Description = :description, @AppUserId = :appUserId
```
```sql
-- QualitySpec_Deprecate/query.sql
EXEC Quality.QualitySpec_Deprecate @QualitySpecId = :qualitySpecId, @AppUserId = :appUserId
```
```sql
-- QualitySpecVersion_ListBySpec/query.sql
EXEC Quality.QualitySpecVersion_ListBySpec @QualitySpecId = :qualitySpecId
```
```sql
-- QualitySpecVersion_Get/query.sql
EXEC Quality.QualitySpecVersion_Get @Id = :id
```
```sql
-- QualitySpecVersion_Create/query.sql
EXEC Quality.QualitySpecVersion_Create @QualitySpecId = :qualitySpecId,
    @EffectiveFrom = :effectiveFrom, @AppUserId = :appUserId
```
```sql
-- QualitySpecVersion_CreateNewVersion/query.sql
EXEC Quality.QualitySpecVersion_CreateNewVersion @SourceVersionId = :sourceVersionId,
    @EffectiveFrom = :effectiveFrom, @AppUserId = :appUserId
```
```sql
-- QualitySpecVersion_SaveDraft/query.sql
EXEC Quality.QualitySpecVersion_SaveDraft @QualitySpecVersionId = :qualitySpecVersionId,
    @EffectiveFrom = :effectiveFrom, @AttributesJson = :attributesJson, @AppUserId = :appUserId
```
```sql
-- QualitySpecVersion_Publish/query.sql
EXEC Quality.QualitySpecVersion_Publish @Id = :id, @AppUserId = :appUserId
```
```sql
-- QualitySpecVersion_Deprecate/query.sql
EXEC Quality.QualitySpecVersion_Deprecate @Id = :id, @AppUserId = :appUserId
```
```sql
-- QualitySpecVersion_DiscardDraft/query.sql
EXEC Quality.QualitySpecVersion_DiscardDraft @Id = :id, @AppUserId = :appUserId
```
```sql
-- QualitySpecAttribute_ListByVersion/query.sql
EXEC Quality.QualitySpecAttribute_ListByVersion @QualitySpecVersionId = :qualitySpecVersionId
```

> Confirm proc param names against the built procs for `QualitySpec_Get`, `QualitySpecVersion_Get`, `QualitySpecVersion_ListBySpec`, `QualitySpecVersion_Deprecate`, `QualitySpecVersion_Create` (e.g. `_Get` may use `@Id`; `_ListBySpec` may use `@QualitySpecId`). Match the wrapper to the actual signature.

- [ ] **Step 2: Write each `resource.json`** — `type:"Query"` for every one (reads + mutations). Template (adjust `parameters[]` per the query's `:params`):

```json
{
  "scope": "DG",
  "version": 2,
  "restricted": false,
  "overridable": true,
  "files": ["query.sql"],
  "attributes": {
    "type": "Query",
    "enabled": true,
    "database": "MPP",
    "useMaxReturnSize": false,
    "maxReturnSize": 100,
    "autoBatchEnabled": false,
    "cacheEnabled": false,
    "cacheAmount": 1,
    "cacheUnit": "SEC",
    "fallbackEnabled": false,
    "fallbackValue": "",
    "permissions": [{ "zone": "", "role": "" }],
    "parameters": [
      { "type": "Parameter", "identifier": "qualitySpecVersionId", "sqlType": 3 },
      { "type": "Parameter", "identifier": "effectiveFrom", "sqlType": 8 },
      { "type": "Parameter", "identifier": "attributesJson", "sqlType": 7 },
      { "type": "Parameter", "identifier": "appUserId", "sqlType": 3 }
    ]
  }
}
```

`sqlType` per param: ids → 3, names/json/description → 7, dates → 8. For `QualitySpec_List` set `itemId`/`operationTemplateId` → 3. Confirm `database` value matches the project default (clone from `QualitySpec_ListForItem/resource.json`).

- [ ] **Step 3: Scan + verify NQs load**

Run: `.\scan.ps1`
Then check the gateway log has no `Named query` parse errors. (Per `feedback_check_nq_files_first`: verify every NEW NQ folder exists on disk before wiring the UI.)

- [ ] **Step 4: Commit**

```bash
git add ignition/projects/MPP_Config/ignition/named-query/quality/
git commit -m "feat(ignition): quality-spec named queries (reads + mutations, type:Query)"
```

---

## Phase C — Entity Script

### Task C1: Extend `BlueRidge.Quality.QualitySpec`

**Files:**
- Modify: `ignition/projects/MPP_Config/ignition/script-python/BlueRidge/Quality/QualitySpec/code.py`

- [ ] **Step 1: Add reads + mutations mirroring `BlueRidge.Parts.Bom`**

Keep the existing `listForItem`. Add (preserving the `_u` / `_isoDate` helper pattern from `Parts/Bom/code.py`):

```python
def getAllForList(filter=None):
    """Library list rows. filter = {searchText, type} where type in
    All|Item-Linked|Op-Linked|Unlinked. Returns list[dict] with a
    derived state badge resolved client-side, plus link sublines."""
    f = _u(filter) or {}
    rows = BlueRidge.Common.Db.execList("quality/QualitySpec_List",
        {"itemId": None, "operationTemplateId": None}) or []
    search = (f.get("searchText") or "").strip().lower()
    typ = f.get("type") or "All"
    out = []
    for r in rows:
        name = (r.get("Name") or "")
        itemId = r.get("ItemId")
        opId = r.get("OperationTemplateId")
        if typ == "Item-Linked" and not itemId: continue
        if typ == "Op-Linked" and not opId: continue
        if typ == "Unlinked" and (itemId or opId): continue
        if search and search not in name.lower(): continue
        out.append({
            "id": r.get("Id"), "name": name,
            "itemId": itemId, "itemCode": r.get("ItemCode") or "",
            "operationTemplateId": opId, "opCode": r.get("OperationTemplateCode") or "",
            "versionCount": r.get("VersionCount") or 0,
            "activeVersionCount": r.get("ActiveVersionCount") or 0,
        })
    return out

def getSpecHeader(specId):
    """Header dict (name, description, link display) or empty shape."""
    specId = _u(specId)
    empty = {"id": None, "name": "", "description": "",
             "itemId": None, "itemCode": "", "itemDesc": "",
             "operationTemplateId": None, "opCode": "", "deprecatedAt": None}
    if not specId:
        return empty
    h = BlueRidge.Common.Db.execOne("quality/QualitySpec_Get", {"id": specId})
    if h is None:
        return empty
    return {
        "id": h.get("Id"), "name": h.get("Name") or "",
        "description": h.get("Description") or "",
        "itemId": h.get("ItemId"), "itemCode": h.get("ItemCode") or "",
        "itemDesc": h.get("ItemName") or "",
        "operationTemplateId": h.get("OperationTemplateId"),
        "opCode": h.get("OperationTemplateCode") or "",
        "deprecatedAt": h.get("DeprecatedAt"),
    }

def listVersions(specId, includeDeprecated=True):
    specId = _u(specId)
    if not specId:
        return []
    rows = BlueRidge.Common.Db.execList("quality/QualitySpecVersion_ListBySpec",
        {"qualitySpecId": specId}) or []
    out = []
    for r in rows:
        d = dict(r)
        d["effectiveFromDisplay"] = _isoDate(r.get("EffectiveFrom"))
        out.append(d)
    return out

def getVersionFull(versionId):
    """{version header + attributes[] + derived status} or empty shape."""
    versionId = _u(versionId)
    empty = {"id": None, "specId": None, "versionNumber": None,
             "effectiveFrom": None, "effectiveFromDisplay": "",
             "publishedAt": None, "deprecatedAt": None, "status": None,
             "attributes": []}
    if not versionId:
        return empty
    h = BlueRidge.Common.Db.execOne("quality/QualitySpecVersion_Get", {"id": versionId})
    if h is None:
        return empty
    attrs = BlueRidge.Common.Db.execList("quality/QualitySpecAttribute_ListByVersion",
        {"qualitySpecVersionId": versionId}) or []
    pub, dep = h.get("PublishedAt"), h.get("DeprecatedAt")
    status = "Deprecated" if dep is not None else ("Draft" if pub is None else "Published")
    return {
        "id": h.get("Id"), "specId": h.get("QualitySpecId"),
        "versionNumber": h.get("VersionNumber"),
        "effectiveFrom": h.get("EffectiveFrom"),
        "effectiveFromDisplay": _isoDate(h.get("EffectiveFrom")),
        "publishedAt": pub, "deprecatedAt": dep, "status": status,
        "attributes": _mapAttrs(attrs),
    }

def _mapAttrs(rows):
    out = []
    for r in rows or []:
        out.append({
            "id": r.get("Id"),
            "attributeName": r.get("AttributeName") or "",
            "dataType": r.get("DataType") or "Numeric",
            "uomId": r.get("UomId"), "uomCode": r.get("UomCode") or "",
            "targetValue": r.get("TargetValue"),
            "lowerLimit": r.get("LowerLimit"), "upperLimit": r.get("UpperLimit"),
            "isRequired": bool(r.get("IsRequired")),
            "sortOrder": r.get("SortOrder"),
        })
    return out

def listUoms():
    try:
        return BlueRidge.Common.Db.execList("parts/Uom_List", {"includeDeprecated": False}) or []
    except Exception as e:
        BlueRidge.Common.Util.log("listUoms failed: %s" % str(e))
        return []

def emptyAttribute():
    return {"id": None, "attributeName": "", "dataType": "Numeric",
            "uomId": None, "uomCode": "", "targetValue": None,
            "lowerLimit": None, "upperLimit": None, "isRequired": True,
            "sortOrder": None}

# ---------- mutations ----------

def createSpec(data):
    data = _u(data) or {}
    return BlueRidge.Common.Db.execMutation("quality/QualitySpec_Create", {
        "name": data.get("name"), "itemId": data.get("itemId"),
        "operationTemplateId": data.get("operationTemplateId"),
        "description": data.get("description"),
        "appUserId": BlueRidge.Common.Util._currentAppUserId()})

def updateSpecHeader(data):
    data = _u(data) or {}
    return BlueRidge.Common.Db.execMutation("quality/QualitySpec_Update", {
        "id": data.get("id"), "name": data.get("name"),
        "description": data.get("description"),
        "appUserId": BlueRidge.Common.Util._currentAppUserId()})

def deprecateSpec(specId):
    return BlueRidge.Common.Db.execMutation("quality/QualitySpec_Deprecate", {
        "qualitySpecId": _u(specId),
        "appUserId": BlueRidge.Common.Util._currentAppUserId()})

def createNewVersion(specId):
    """Routes: no versions -> QualitySpecVersion_Create (v1); else clone
    latest non-deprecated via _CreateNewVersion. Refuses if a Draft exists."""
    specId = _u(specId)
    if not specId:
        return {"Status": False, "Message": "No spec selected.", "NewId": None}
    vers = listVersions(specId, True)
    if len(vers) == 0:
        return BlueRidge.Common.Db.execMutation("quality/QualitySpecVersion_Create",
            {"qualitySpecId": specId, "effectiveFrom": None,
             "appUserId": BlueRidge.Common.Util._currentAppUserId()})
    for v in vers:
        if v.get("PublishedAt") is None and v.get("DeprecatedAt") is None:
            return {"Status": False, "Message":
                    "A draft already exists for this spec. Open or discard it first.",
                    "NewId": None}
    nonDep = [v for v in vers if v.get("DeprecatedAt") is None]
    source = (nonDep[0] if nonDep else vers[0]).get("Id")
    return BlueRidge.Common.Db.execMutation("quality/QualitySpecVersion_CreateNewVersion",
        {"sourceVersionId": source, "effectiveFrom": None,
         "appUserId": BlueRidge.Common.Util._currentAppUserId()})

def saveDraft(versionId, effectiveFrom, attributes):
    payload = []
    for a in (_u(attributes) or []):
        a = _u(a) or {}
        payload.append({
            "Id": a.get("id"), "AttributeName": a.get("attributeName"),
            "DataType": a.get("dataType"), "UomId": a.get("uomId"),
            "TargetValue": a.get("targetValue"), "LowerLimit": a.get("lowerLimit"),
            "UpperLimit": a.get("upperLimit"),
            "IsRequired": 1 if a.get("isRequired") else 0})
    return BlueRidge.Common.Db.execMutation("quality/QualitySpecVersion_SaveDraft", {
        "qualitySpecVersionId": _u(versionId),
        "effectiveFrom": _u(effectiveFrom),
        "attributesJson": system.util.jsonEncode(payload),
        "appUserId": BlueRidge.Common.Util._currentAppUserId()})

def publish(versionId, effectiveFrom, attributes):
    """Save-then-publish (the proc _Publish takes only @Id). Saves draft
    first so attribute + EffectiveFrom edits commit, then flips state."""
    saved = saveDraft(versionId, effectiveFrom, attributes)
    if not saved.get("Status"):
        return saved
    return BlueRidge.Common.Db.execMutation("quality/QualitySpecVersion_Publish", {
        "id": _u(versionId), "appUserId": BlueRidge.Common.Util._currentAppUserId()})

def discardDraft(versionId):
    return BlueRidge.Common.Db.execMutation("quality/QualitySpecVersion_DiscardDraft", {
        "id": _u(versionId), "appUserId": BlueRidge.Common.Util._currentAppUserId()})

def deprecateVersion(versionId):
    return BlueRidge.Common.Db.execMutation("quality/QualitySpecVersion_Deprecate", {
        "id": _u(versionId), "appUserId": BlueRidge.Common.Util._currentAppUserId()})
```

Add the `_u` and `_isoDate` helpers at the top if not already present (copy from `Parts/Bom/code.py` lines 45–55). Update the module header docstring + Change Log.

- [ ] **Step 2: Scan + Script Console smoke**

Run: `.\scan.ps1`
Then in Designer Script Console: `print BlueRidge.Quality.QualitySpec.getAllForList({"type":"All"})` → returns a list (possibly empty) without exception.

- [ ] **Step 3: Commit**

```bash
git add ignition/projects/MPP_Config/ignition/script-python/BlueRidge/Quality/QualitySpec/code.py
git commit -m "feat(ignition): extend Quality.QualitySpec entity script (reads + version mutations)"
```

---

## Phase D — Attribute Row sub-view

### Task D1: Create `Components/Quality/QualitySpecAttributeRow`

**Files:**
- Create: `.../com.inductiveautomation.perspective/views/BlueRidge/Components/Quality/QualitySpecAttributeRow/view.json` (+ `resource.json`)
- Reference: `.../views/BlueRidge/Components/Parts/ItemMaster/BomLineRow/view.json`

- [ ] **Step 1: Copy BomLineRow as the starting point, then adapt**

Copy `BomLineRow/view.json` → the new path. Rename root + retarget params/controls:

- `params` (all `paramDirection:"input"`): `rowIndex` (BIGINT), `attrCount` (BIGINT), `mode` (string: `draft|published|deprecated`), `attribute` (object), `uoms` (array), `dataTypes` (array, e.g. `[{"label":"Numeric","value":"Numeric"},…]`).
- Controls (draft mode editable, otherwise display labels via `position.display` on `mode == "draft"`):
  - AttributeName `ia.input.text-field` → fires `qsAttrNameChanged` on `dom.onBlur`.
  - DataType `ia.input.dropdown` (options = `view.params.dataTypes`) → fires `qsAttrDataTypeChanged` on `component.onActionPerformed`.
  - UOM `ia.input.dropdown` (options = `view.params.uoms` mapped to `{label:Code,value:Id}` via script transform) → `qsAttrUomChanged`. Disabled (`props.enabled` expr) when DataType ∈ {Boolean,Text}.
  - Target / Lower / Upper `ia.input.numeric-entry` → `qsAttrTargetChanged` / `qsAttrLowerChanged` / `qsAttrUpperChanged` on blur. Same disable expr as UOM.
  - Required `ia.input.checkbox` → `qsAttrRequiredChanged` on `component.onActionPerformed`.
  - ▲/▼ move buttons (disabled at first/last via `rowIndex`/`attrCount`) → `qsAttrMoveUp` / `qsAttrMoveDown`.
  - ✕ remove button → `qsAttrRemove`.
- Disable expr (reused on UOM + 3 numerics): `props.enabled` binding `type:"expr"`, `{view.params.attribute.dataType} = "Numeric"` (Ignition expr `=`, single-quoted strings → Designer rewrites to `=`/`'`). Reserve slot width via `meta.visible` (not `position.display`) so rows stay uniform — per `feedback_ignition_meta_visible_in_tables`.
- Every message script: `scope:"G"`, body starts with `\t`, payload `{"rowIndex": self.view.params.rowIndex, ...newValue}`, `scope="page"`. Example onBlur for name:

```
\tsystem.perspective.sendMessage("qsAttrNameChanged", {"rowIndex": self.view.params.rowIndex, "value": self.props.text}, scope="page")
```

- [ ] **Step 2: Scan + verify the row renders standalone**

Run: `.\scan.ps1`. In Designer, open the view; confirm no Component Error, controls visible.

- [ ] **Step 3: Commit**

```bash
git add ".../views/BlueRidge/Components/Quality/QualitySpecAttributeRow/"
git commit -m "feat(ignition): QualitySpecAttributeRow sub-view (mirrors BomLineRow)"
```

---

## Phase E — Standalone screen

### Task E1: Build the master-detail shell + state

**Files:**
- Modify: `.../views/BlueRidge/Views/Quality/QualitySpecs/view.json` (extend the existing wireframe shell)
- Reference: `.../views/BlueRidge/Components/Parts/ItemMaster/Boms/view.json` (versioning mechanics) + `.../Views/.../LocationTypeEditor` (standalone master-detail + ConfirmUnsaved)

- [ ] **Step 1: Define `view.custom` state**

```
specs: []                       # library rows (getAllForList)
filter: {searchText: "", type: "All"}
selectedSpecId: null
incomingSpecId: null            # cross-nav preselect (set from page param)
specHeader: {selected: {…empty…}, editDraft: {…empty…}}
state: {selected: {…empty version bundle…}, editDraft: {…same…}}
isDirty: false
activeVersionId: null
versions: []
uoms: []
dataTypes: [{label:"Numeric",value:"Numeric"},{label:"Boolean",value:"Boolean"},{label:"Text",value:"Text"}]
```

Seed every nested key with the full empty shape (per `feedback_ignition_bidi_nested_path_init`): `specHeader.editDraft` has `name/description/itemCode/opCode/…`; `state.editDraft` has `id/specId/versionNumber/effectiveFromDisplay/status/attributes:[]`.

- [ ] **Step 2: Library list binding + filter**

`view.custom.specs` ← expr `runScript("BlueRidge.Quality.QualitySpec.getAllForList", 0, {view.custom.filter})`. Left-rail `flex-repeater` over `specs` (or `ia.display.table`); each row click sets `view.custom.selectedSpecId` via page-scoped message `qsSpecRowClicked` gated by `isDirty` (open ConfirmUnsaved if dirty, else select).

- [ ] **Step 3: `selectedSpecId.onChange` → load header + versions atomically**

`root.scripts.customMethods.loadSpec()`:
```
\tspecId = self.view.custom.selectedSpecId
\theader = BlueRidge.Quality.QualitySpec.getSpecHeader(specId)
\tself.view.custom.specHeader = {"selected": dict(header), "editDraft": dict(header)}
\tself.view.custom.versions = BlueRidge.Quality.QualitySpec.listVersions(specId, True)
\tself.view.custom.uoms = BlueRidge.Quality.QualitySpec.listUoms()
\t# pick newest version as active
\tself.view.custom.activeVersionId = self.view.custom.versions[0]["Id"] if self.view.custom.versions else None
```
(Atomic single write to `specHeader`.) Wire `selectedSpecId` `propConfig.onChange` to call `self.loadSpec()` (per `feedback_ignition_view_customMethods_scope`).

- [ ] **Step 4: Commit**

```bash
git add ".../views/BlueRidge/Views/Quality/QualitySpecs/"
git commit -m "feat(ignition): quality-spec standalone shell + library list + spec load"
```

---

### Task E2: Spec header card (Name/Description edit, Save, Deprecate Spec)

- [ ] **Step 1:** Header card: Name `text-field` bidi → `specHeader.editDraft.name`; Description bidi → `specHeader.editDraft.description`; Linked Item + Linked Op Template as read-only labels bound to `specHeader.selected.itemCode` / `.opCode`.
- [ ] **Step 2:** Header Save button → `root.scripts.customMethods.handleSaveHeader()`:
```
\tres = BlueRidge.Quality.QualitySpec.updateSpecHeader(self.view.custom.specHeader.editDraft)
\tBlueRidge.Common.Ui.notifyResult(res, successTitle="Spec saved")
\tif res.get("Status"):
\t\tself.view.custom.specHeader = {"selected": dict(self.view.custom.specHeader.editDraft), "editDraft": dict(self.view.custom.specHeader.editDraft)}
\t\tself.view.custom.specs = BlueRidge.Quality.QualitySpec.getAllForList(self.view.custom.filter)
```
- [ ] **Step 3:** Deprecate Spec button → opens `ConfirmDestructive`; reply handler `qsConfirmDeprecateSpecResult` (act on `payload.action=="confirm"`) calls `deprecateSpec(selectedSpecId)`, then clears selection + refreshes `specs`.
- [ ] **Step 4: Scan + commit**
```bash
.\scan.ps1
git add ".../views/BlueRidge/Views/Quality/QualitySpecs/"
git commit -m "feat(ignition): quality-spec header edit/save + deprecate spec"
```

---

### Task E3: Version bar + lifecycle (New Version / Save Draft / Publish / Discard / Deprecate)

- [ ] **Step 1:** Version dropdown: options via script transform on `view.custom.versions` → `v{N} — {status} (Eff {date})` with derived Active/Scheduled/Superseded label; `props.value` bidi → `view.custom.activeVersionId`.
- [ ] **Step 2:** `activeVersionId.onChange` → `loadActiveVersion()`:
```
\tbundle = BlueRidge.Quality.QualitySpec.getVersionFull(self.view.custom.activeVersionId)
\tself.view.custom.state = {"selected": bundle, "editDraft": BlueRidge.Quality.QualitySpec.getVersionFull(self.view.custom.activeVersionId)}
```
(Two independent fetches guarantee distinct dict identities; OR deep-copy via `system.util.jsonDecode(system.util.jsonEncode(bundle))`. Single atomic write to `state`.)
- [ ] **Step 3:** `isDirty` binding (expr): header-diff OR version-diff:
```
runScript("BlueRidge.Common.Util.convertWrapperObjectToJson", 0, {view.custom.state.editDraft.attributes}) != runScript("BlueRidge.Common.Util.convertWrapperObjectToJson", 0, {view.custom.state.selected.attributes}) || {view.custom.state.editDraft.effectiveFromDisplay} != {view.custom.state.selected.effectiveFromDisplay} || {view.custom.specHeader.editDraft.name} != {view.custom.specHeader.selected.name} || {view.custom.specHeader.editDraft.description} != {view.custom.specHeader.selected.description}
```
- [ ] **Step 4:** Lifecycle buttons (all `dom` scripts `scope:"G"` → rootContainer customMethods), gated by `state.editDraft.status`:
  - `+ New Version` (enabled when `!isDirty`) → `handleNewVersion()`: calls `createNewVersion(selectedSpecId)`, on success refreshes `versions` + sets `activeVersionId` to NewId.
  - `Save Draft` (visible when status `Draft`, enabled when `isDirty`) → `handleSaveDraft()`: `saveDraft(state.editDraft.id, state.editDraft.effectiveFromDisplay, state.editDraft.attributes)` → notifyResult → on success reload version + reset `state`.
  - `Publish` (visible when Draft) → `handlePublish()`: `publish(...)` → notifyResult → reload versions/state.
  - `Discard Draft` (visible when Draft) → opens `ConfirmDestructive` → reply `qsConfirmDiscardResult` → `discardDraft()` → refresh versions, select newest.
  - `Deprecate Version` (visible when Published) → `ConfirmDestructive` → reply `qsConfirmDeprecateVersionResult` → `deprecateVersion()` → refresh.
- [ ] **Step 5:** `sectionSave/Discard`-equivalent for the self-contained ConfirmUnsaved: reuse the `confirmUnsavedResult` page-scoped handler (Save → handleSaveDraft + handleSaveHeader; Discard → reseed both editDrafts from selected; Cancel → drop `pendingSwitch`). Stage spec-switch in `view.custom.pendingSwitch` when a row is clicked while dirty.
- [ ] **Step 6: Scan + commit**
```bash
.\scan.ps1
git add ".../views/BlueRidge/Views/Quality/QualitySpecs/"
git commit -m "feat(ignition): quality-spec version lifecycle (new/save/publish/discard/deprecate)"
```

---

### Task E4: Attribute grid + Version History tab

- [ ] **Step 1:** Tab container: tab 1 Attributes, tab 2 Version History (typed `props.tabs` objects; `runWhileHidden:true`).
- [ ] **Step 2:** Attributes grid = `flex-repeater`, `props.path` = `BlueRidge/Components/Quality/QualitySpecAttributeRow`. `props.instances` ← property binding on `view.custom.state.editDraft.attributes` + script transform emitting per-row `{rowIndex, attribute, attrCount, mode, uoms, dataTypes}` where `mode` = `state.editDraft.status` lowercased.
- [ ] **Step 3:** `+ Add Attribute` (visible when Draft) → `handleAddAttribute()`: appends `QualitySpec.emptyAttribute()` to a fresh `state.editDraft` dict, atomic reassign.
- [ ] **Step 4:** Parent message handlers (all `pageScope:true`) mutating `state.editDraft.attributes` then atomic reassign of `state.editDraft`:
  - `qsAttrMoveUp` / `qsAttrMoveDown` → `_swapAttrs(rowIndex, delta)`
  - `qsAttrRemove` → `_removeAttr(rowIndex)`
  - `qsAttrNameChanged` / `qsAttrDataTypeChanged` / `qsAttrUomChanged` / `qsAttrTargetChanged` / `qsAttrLowerChanged` / `qsAttrUpperChanged` / `qsAttrRequiredChanged` → `_applyAttrField(rowIndex, field, value)`
  Pattern (mirror BOMs `_applyQtyChange`):
```
\tdraft = dict(self.view.custom.state.editDraft)
\tattrs = list(draft.get("attributes") or [])
\trow = dict(attrs[payload["rowIndex"]]); row["attributeName"] = payload["value"]; attrs[payload["rowIndex"]] = row
\tdraft["attributes"] = attrs
\tself.view.custom.state.editDraft = draft
```
- [ ] **Step 5:** Version History tab: read-only `ia.display.table` (full ~25-key column schema per `feedback_ignition_table_column_full_schema`) bound to `view.custom.versions`; columns Version / EffectiveFrom / DeprecatedAt / State / CreatedBy / CreatedAt.
- [ ] **Step 6: Scan + commit**
```bash
.\scan.ps1
git add ".../views/BlueRidge/Views/Quality/QualitySpecs/" ".../Components/Quality/QualitySpecAttributeRow/"
git commit -m "feat(ignition): quality-spec attribute grid + version history tab"
```

---

## Phase F — New Spec modal

### Task F1: New Spec modal

**Files:**
- Create: `.../views/BlueRidge/Components/Quality/NewSpecModal/view.json` (+ resource.json)

- [ ] **Step 1:** Modal fields bidi → its own `view.custom.draft`: Name (text), Linked Item dropdown (optional; options from an Item list NQ/entity — reuse `BlueRidge.Parts.Item.getForDropdown` or similar; include `— none —`), Linked Op Template dropdown (optional), Description, Initial Effective Date (`date-time-input`, format `YYYY-MM-DD`). Cancel + Create buttons.
- [ ] **Step 2:** Create → `BlueRidge.Quality.QualitySpec.createSpec(draft)` → notifyResult → on success send page-scoped `qsSpecCreated` with `{specId: NewId}` and close modal. Standalone screen handler `qsSpecCreated` refreshes `specs` + sets `selectedSpecId` to the new id (which has no versions → user clicks New Version).
- [ ] **Step 3:** `+ New Spec` button on the screen opens this popup (`system.perspective.openPopup`, `scope:"G"`).
- [ ] **Step 4: Scan + commit**
```bash
.\scan.ps1
git add ".../views/BlueRidge/Components/Quality/NewSpecModal/" ".../Views/Quality/QualitySpecs/"
git commit -m "feat(ignition): new quality spec modal"
```

---

## Phase G — Page registration + nav

### Task G1: Register `/quality-specs` + sidebar entry

**Files:**
- Modify: `.../com.inductiveautomation.perspective/page-config/config.json`
- Modify: the sidebar/nav view that lists Quality category entries (locate via grep for an existing route like `/downtime-codes` or `/defect-codes`)

- [ ] **Step 1:** Add to `page-config/config.json` `pages`:
```json
"/quality-specs": { "title": "Quality Specs", "viewPath": "BlueRidge/Views/Quality/QualitySpecs" }
```
- [ ] **Step 2:** Add a "Quality Specs" entry under the Quality nav category (mirror an existing Quality entry's shape — icon, label, route). Use a verified icon path (e.g. `material/rule` or an `mpp/` sprite confirmed in `ignition/icons/mpp/mpp.svg` per `feedback_mpp_icon_paths_verify`).
- [ ] **Step 3: Scan + verify the route loads**
```
.\scan.ps1
```
Browse to `/quality-specs` in a Perspective session — page renders with the library list.
- [ ] **Step 4: Commit**
```bash
git add ".../com.inductiveautomation.perspective/page-config/config.json" "<sidebar view path>"
git commit -m "feat(ignition): register /quality-specs route + sidebar nav"
```

---

## Phase H — Phase 7 cross-nav from Item Master

### Task H1: Wire "Go to spec →" on the Item Master Quality Specs embed

**Files:**
- Modify: `.../views/BlueRidge/Components/Parts/ItemMaster/QualitySpecs/view.json`

- [ ] **Step 1:** Remove the placeholder "GoToSpecHint" label.
- [ ] **Step 2:** Add a per-row "Go to spec →" button to the `SpecsTable` (or a button column). On click (`scope:"G"`), navigate to `/quality-specs` passing the spec id:
```
\tsystem.perspective.navigate(page="/quality-specs", params={"specId": <row spec id>})
```
(Use the table's selected-row spec id. If passing params via page route is awkward, set `session.custom.qsIncomingSpecId` then navigate, and have the standalone screen read it on startup.)
- [ ] **Step 3:** In the standalone `QualitySpecs` view, on view startup read the incoming `specId` page param (or `session.custom.qsIncomingSpecId`) into `view.custom.selectedSpecId` so the spec preselects; clear the session value after consuming.
- [ ] **Step 4: Scan + commit**
```bash
.\scan.ps1
git add ".../views/BlueRidge/Components/Parts/ItemMaster/QualitySpecs/" ".../Views/Quality/QualitySpecs/"
git commit -m "feat(ignition): Phase 7 'Go to spec' cross-nav from Item Master"
```

---

## Phase I — Full smoke test

### Task I1: End-to-end Designer smoke

- [ ] **Step 1:** `.\Reset-DevDatabase.ps1` (clean DB with all procs) → `.\scan.ps1`.
- [ ] **Step 2:** In a Perspective session, walk the full flow and confirm each:
  - `/quality-specs` library renders; search + type filter work.
  - `+ New Spec` → modal → Create → new spec appears + auto-selected.
  - `+ New Version` → v1 Draft created; attribute grid editable.
  - `+ Add Attribute` → row added; DataType=Boolean disables UOM/limits; ▲▼ reorder; ✕ remove; dirty dot appears; tab/spec-switch gated by ConfirmUnsaved.
  - `Save Draft` → reload persists attributes + UomId.
  - `Publish` → state flips to Published; **prior Published version NOT auto-deprecated**; future EffectiveFrom shows "Scheduled" badge.
  - `Deprecate Version` / `Discard Draft` → ConfirmDestructive → state changes.
  - `Deprecate Spec` → spec leaves the active list.
  - Item Master `/items` → Quality Specs tab → "Go to spec →" → lands on `/quality-specs` with the spec preselected.
  - `/audit` → every action above produced a readable Activity row (`5G0 · Quality Spec "…" v… · …`); row click opens `ConfirmChangeDetail` with resolved-name JSON (`Uom: {Id,Code,Name}`).
- [ ] **Step 3:** Record results + any deviations in `PROJECT_STATUS.md` "Recently closed". Commit any fixes found during smoke.

---

## Self-Review notes

- **Spec coverage:** §3 lifecycle → A2/A3/E3; §4 SQL delta → A1–A6; §5 NQs → B1; §6.1 entity → C1; §6.2 screen → E1–E4; §6.3 attribute row → D1; §6.4 modal → F1; §6.5 page/nav → G1; §6.6 cross-nav → H1; §7 audit catalog → A2/A3/A4/A6.
- **Open spec questions surfaced as build-time confirmations:** AppUser table name (A1), publish validation rules (enforce in `_Publish` if A6 reveals gaps), `DiscardDraft` proc existence (A6 note), exact built-proc param names for read NQs (B1 note).
- **Type consistency:** entity-script keys (`attributeName/dataType/uomId/targetValue/lowerLimit/upperLimit/isRequired/sortOrder/id`) are identical across `_mapAttrs`, `emptyAttribute`, `saveDraft` payload, and the AttributeRow params. SaveDraft JSON keys (`Id/AttributeName/DataType/UomId/TargetValue/LowerLimit/UpperLimit/IsRequired`) match the proc's `OPENJSON` paths.
