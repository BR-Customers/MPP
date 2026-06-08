# Eligibility-Style Config Editors Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Port the Item Master Eligibility editing model (inline draft rows + dirty-gated Save/Discard + atomic `…SaveAll` proc) onto Tools → Attributes, Tools → Cavities, Operation-Templates → Fields, and convert Tools → Assignments to an inline (non-draft) mount surface — retiring three add-popups and all per-row immediate writes.

**Architecture:** Three new bundled `…SaveAll` stored procs (insert / update / remove-or-deprecate reconcile, audit-readable, value-validating) front a thin Named-Query layer, two extended entity-script modules, and rewritten Perspective sub-views that mirror `BlueRidge/Components/Parts/ItemMaster/Eligibility` + `EligibilityRow`. Each draft section owns `view.custom.state = {selected, editDraft}` written atomically, broadcasts `sectionDirtyChanged`, and is gated by the reusable `ConfirmUnsaved` popup on the parent view. Assignments keeps immediate audited mount/release with no draft.

**Tech Stack:** SQL Server 2022 (stored procs, `OPENJSON` reconcile, `test.Assert_*` framework), Ignition 8.3 Perspective (file-based view.json, Jython entity scripts, Named Queries), PowerShell (`Reset-DevDatabase.ps1`, `scan.ps1`).

**Source spec:** `docs/superpowers/specs/2026-06-05-eligibility-style-config-editors-design.md` (commit `7f41a2d`).

---

## Conventions every task must follow

- **Proc shape (Ignition-safe):** No `OUTPUT` params. Local `@Status BIT`, `@Message NVARCHAR(500)`, `@NewId BIGINT`. Every exit path ends `SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;`. Failures log `Audit.Audit_LogFailure` (outside any transaction); success logs `Audit.Audit_LogConfigChange` (inside the transaction). `RAISERROR` (never `THROW`) in the CATCH block. Reference: `R__Parts_ItemLocation_SaveAllForItem.sql` and `sql/scripts/_TEMPLATE_stored_procedure.sql`.
- **Audit Description convention:** `<SUBJECT> · <CATEGORY> · <ACTION>` using `Audit.ufn_MidDot()` separator and `Audit.ufn_TruncateActivity()` for the 500-char cap. `+`/`~`/`-` symbols inline, cap 3 specifics per kind with `+N more` overflow. Resolved-FK sub-objects in `OldValue`/`NewValue` JSON via `JSON_QUERY((… FOR JSON PATH, WITHOUT_ARRAY_WRAPPER))` (a **bare** aliased `FOR JSON` subquery double-encodes — always wrap in `JSON_QUERY`). Strip trailing separators with `LEFT(x, DATALENGTH(x)/2 - 2)`, never `LEN()`. Render `BIT` diffs as `true`/`false` words.
- **Reused audit `LogEntityType` codes (already seeded — do NOT add new ones):** `ToolAttribute`, `ToolCavity`, `OpTemplateField` (note: `OpTemplateField`, not `OperationTemplateField`).
- **NQ resources:** `version: 2`, `"type": "Query"` (status-row mutation; `UpdateQuery` throws "A result set was generated for update"), `"database": "MPP"`. Params use Designer's enum: BIGINT id → `sqlType: 3`, NVARCHAR json → `sqlType: 7`. Identifiers camelCase.
- **Ignition three-layer rule:** View → entity script (`BlueRidge.Parts.*`) → `BlueRidge.Common.Db.*`. No `system.db.*` in views. No business rules in Jython (validation lives in the procs).
- **Atomic state writes (normative):** `load()` / reseed writes `self.view.custom.state = {"selected": dict(x), "editDraft": dict(x)}` in ONE assignment — never two sequential writes (causes stuck-dirty popup bug).
- **Pre-declare bound custom props** with fully-shaped defaults; type-aware value rows must seed every input's bound path; binding sources return `_EMPTY` shapes never `None`/`{}`.
- **View-edit boundary:** New / fully-rewritten sub-views are file-edited + `.\scan.ps1`. Parent-view wiring edits (`Tools`, `OperationTemplates`) are done in **Designer** (reconciliation race + Designer's `=` escapes). Commit work to `jacques/working`; stage explicit paths only (never `git add -A/-u`); omit the `Co-Authored-By: Claude` trailer.
- **Run the SQL suite** after each SQL phase: `.\Reset-DevDatabase.ps1` rebuilds `MPP_MES_Dev` from migrations + repeatable procs + runs every `sql/tests/**` file. Baseline is **1165/1165**; each new test file raises the total.

---

## File Structure

**SQL — new repeatable procs**
- `sql/migrations/repeatable/R__Tools_ToolAttribute_SaveAll.sql` — bundled attribute reconcile (insert/update/**hard-DELETE on absent**) + per-DataType value validation.
- `sql/migrations/repeatable/R__Tools_ToolCavity_SaveAll.sql` — bundled cavity reconcile (insert + **update only**, no deprecate-on-absent); number immutable; Scrapped-lock.
- `sql/migrations/repeatable/R__Parts_OperationTemplateField_SaveAll.sql` — bundled field reconcile (insert/update `IsRequired`/**deprecate-on-absent** + reactivate).

**SQL — new test files**
- `sql/tests/0017_Tools_Attribute/020_ToolAttribute_SaveAll.sql`
- `sql/tests/0015_Tools_Cavity/020_ToolCavity_SaveAll.sql`
- `sql/tests/0009_Parts_Process/050_OperationTemplateField_SaveAll.sql`

**Ignition — new Named Queries**
- `ignition/projects/MPP_Config/ignition/named-query/parts/ToolAttribute_SaveAll/{query.sql,resource.json}`
- `…/named-query/parts/ToolCavity_SaveAll/{query.sql,resource.json}`
- `…/named-query/parts/OperationTemplateField_SaveAll/{query.sql,resource.json}`

**Ignition — entity scripts (modify)**
- `…/script-python/BlueRidge/Parts/Tool/code.py` — add `saveAttributesAll`, `saveCavitiesAll`, `getAttributeDefinitionOptions` (now carrying `dataType`); existing per-row mutations kept in module but no longer called from the UI.
- `…/script-python/BlueRidge/Parts/OperationTemplate/code.py` — add `saveFieldsAll`; `getAvailableDataCollectionFields` already exists.

**Ignition — sub-views (rewrite, file-edit + scan)**
- `…/views/BlueRidge/Components/Parts/Tools/Attributes/view.json` + `…/Tools/_Tools/AttributeRow/view.json`
- `…/Tools/Cavities/view.json` + `…/Tools/_Tools/CavityRow/view.json`
- `…/Tools/Assignments/view.json` + `…/Tools/_Tools/AssignmentRow/view.json`
- `…/Components/Parts/OperationTemplates/_OperationTemplates/FieldRow/view.json`

**Ignition — parent wiring (Designer)**
- `…/views/BlueRidge/Views/Parts/Tools/view.json` — `sectionDirty` map + tab/tool-switch gating.
- `…/views/BlueRidge/Views/Parts/OperationTemplates/view.json` — Fields-section dirty gating folded into existing metadata-dirty gate.

**Ignition — delete (retired)**
- `…/Components/Popups/MountToCell/`, `…/Popups/AddAttribute/`, `…/Popups/AddCavity/`. **Keep** `…/Popups/AddAttributeDefinition/`.

---

## Phase A — SQL: three SaveAll procs + tests (SQL-first, fully testable)

Reference implementation for all three procs: `sql/migrations/repeatable/R__Parts_ItemLocation_SaveAllForItem.sql` (v1.3). Copy its TRY/CATCH skeleton, `@Incoming` buffer, `@Changes` classification, STRING_AGG prose composition, resolved-FK JSON, and 4-step (deprecate/update/reactivate/insert) mutation block; adapt columns per proc below.

### Task A1: `Tools.ToolAttribute_SaveAll` proc

**Files:**
- Create: `sql/migrations/repeatable/R__Tools_ToolAttribute_SaveAll.sql`

Table facts: `Tools.ToolAttribute(Id, ToolId, ToolAttributeDefinitionId, Value NVARCHAR(500) NOT NULL, UpdatedAt, UpdatedByUserId)` — **no `DeprecatedAt`** (removal is a hard `DELETE`). Unique `UQ_ToolAttribute_ToolDefinition(ToolId, ToolAttributeDefinitionId)`. Definition table carries `DataType IN ('String','Integer','Decimal','Boolean','Date')`.

RowsJson element schema: `{"Id": long|null, "ToolAttributeDefinitionId": long, "Value": string}`.

- [ ] **Step 1: Write the proc**

```sql
-- =============================================
-- Procedure:   Tools.ToolAttribute_SaveAll
-- Author:      Blue Ridge Automation
-- Created:     2026-06-08
-- Version:     1.0
--
-- Description:
--   Bundled SaveAll for a Tool's attribute values. Reconciles the
--   desired-state JSON array against current ToolAttribute rows:
--     - Incoming Id matches existing row -> UPDATE Value
--     - Incoming Id = NULL                -> INSERT
--     - Existing row Id not in incoming   -> hard DELETE (no DeprecatedAt)
--   Validates each Value against its definition's DataType. Audit-readable
--   Description: <Tool> . Attributes . ACTION.
--
-- Parameters (input):
--   @ToolId    BIGINT        - Required.
--   @RowsJson  NVARCHAR(MAX) - [{Id, ToolAttributeDefinitionId, Value}]
--   @AppUserId BIGINT        - Required for audit.
--
-- Result set: Status (BIT), Message (NVARCHAR), NewId (BIGINT echoes @ToolId).
--
-- Change Log:
--   2026-06-08 - 1.0 - Initial (eligibility-style config editors).
-- =============================================
CREATE OR ALTER PROCEDURE Tools.ToolAttribute_SaveAll
    @ToolId    BIGINT,
    @RowsJson  NVARCHAR(MAX),
    @AppUserId BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Status  BIT           = 0;
    DECLARE @Message NVARCHAR(500) = N'Unknown error';
    DECLARE @NewId   BIGINT        = @ToolId;

    DECLARE @ProcName NVARCHAR(200) = N'Tools.ToolAttribute_SaveAll';
    DECLARE @Params   NVARCHAR(MAX) =
        (SELECT @ToolId AS ToolId, JSON_QUERY(@RowsJson) AS Rows
         FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

    DECLARE @Incoming TABLE (
        RowIndex                  INT PRIMARY KEY,
        Id                        BIGINT NULL,
        ToolAttributeDefinitionId BIGINT NULL,
        Value                     NVARCHAR(500) NULL
    );

    BEGIN TRY
        IF @ToolId IS NULL OR @AppUserId IS NULL
        BEGIN
            SET @Message = N'Required parameter missing.';
            EXEC Audit.Audit_LogFailure
                @AppUserId=@AppUserId, @LogEntityTypeCode=N'ToolAttribute',
                @EntityId=@ToolId, @LogEventTypeCode=N'Updated',
                @FailureReason=@Message, @ProcedureName=@ProcName,
                @AttemptedParameters=@Params;
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId; RETURN;
        END

        DECLARE @ToolTypeId BIGINT;
        SELECT @ToolTypeId = ToolTypeId
        FROM Tools.Tool WHERE Id = @ToolId AND DeprecatedAt IS NULL;

        IF @ToolTypeId IS NULL
        BEGIN
            SET @Message = N'Tool not found or deprecated.';
            EXEC Audit.Audit_LogFailure
                @AppUserId=@AppUserId, @LogEntityTypeCode=N'ToolAttribute',
                @EntityId=@ToolId, @LogEventTypeCode=N'Updated',
                @FailureReason=@Message, @ProcedureName=@ProcName,
                @AttemptedParameters=@Params;
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId; RETURN;
        END

        INSERT INTO @Incoming (RowIndex, Id, ToolAttributeDefinitionId, Value)
        SELECT CAST([key] AS INT) + 1,
               TRY_CAST(JSON_VALUE([value], '$.Id')                        AS BIGINT),
               TRY_CAST(JSON_VALUE([value], '$.ToolAttributeDefinitionId') AS BIGINT),
               JSON_VALUE([value], '$.Value')
        FROM OPENJSON(ISNULL(@RowsJson, N'[]'));

        -- Validation: definition id present
        IF EXISTS (SELECT 1 FROM @Incoming WHERE ToolAttributeDefinitionId IS NULL)
        BEGIN
            SET @Message = N'One or more rows are missing ToolAttributeDefinitionId.';
            EXEC Audit.Audit_LogFailure
                @AppUserId=@AppUserId, @LogEntityTypeCode=N'ToolAttribute',
                @EntityId=@ToolId, @LogEventTypeCode=N'Updated',
                @FailureReason=@Message, @ProcedureName=@ProcName,
                @AttemptedParameters=@Params;
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId; RETURN;
        END

        -- Validation: every definition belongs to this tool's type and is active
        IF EXISTS (
            SELECT 1 FROM @Incoming i
            WHERE NOT EXISTS (
                SELECT 1 FROM Tools.ToolAttributeDefinition d
                WHERE d.Id = i.ToolAttributeDefinitionId
                  AND d.ToolTypeId = @ToolTypeId
                  AND d.DeprecatedAt IS NULL))
        BEGIN
            SET @Message = N'One or more attribute definitions are invalid for this tool type.';
            EXEC Audit.Audit_LogFailure
                @AppUserId=@AppUserId, @LogEntityTypeCode=N'ToolAttribute',
                @EntityId=@ToolId, @LogEventTypeCode=N'Updated',
                @FailureReason=@Message, @ProcedureName=@ProcName,
                @AttemptedParameters=@Params;
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId; RETURN;
        END

        -- Validation: no duplicate definition in the submitted set
        IF EXISTS (SELECT ToolAttributeDefinitionId FROM @Incoming
                   GROUP BY ToolAttributeDefinitionId HAVING COUNT(*) > 1)
        BEGIN
            SET @Message = N'Duplicate attribute in submitted rows.';
            EXEC Audit.Audit_LogFailure
                @AppUserId=@AppUserId, @LogEntityTypeCode=N'ToolAttribute',
                @EntityId=@ToolId, @LogEventTypeCode=N'Updated',
                @FailureReason=@Message, @ProcedureName=@ProcName,
                @AttemptedParameters=@Params;
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId; RETURN;
        END

        -- Validation: per-DataType value conformance (first offender names the field)
        DECLARE @BadField NVARCHAR(200) = NULL;
        DECLARE @BadType  NVARCHAR(20)  = NULL;
        SELECT TOP 1 @BadField = d.Name, @BadType = d.DataType
        FROM @Incoming i
        INNER JOIN Tools.ToolAttributeDefinition d ON d.Id = i.ToolAttributeDefinitionId
        WHERE (d.DataType = N'Integer' AND TRY_CAST(i.Value AS INT)            IS NULL)
           OR (d.DataType = N'Decimal' AND TRY_CAST(i.Value AS DECIMAL(38,10)) IS NULL)
           OR (d.DataType = N'Date'    AND TRY_CAST(i.Value AS DATE)           IS NULL)
           OR (d.DataType = N'Boolean' AND i.Value NOT IN (N'true', N'false'))
           OR (d.DataType = N'String'  AND i.Value IS NULL)
        ORDER BY i.RowIndex;

        IF @BadField IS NOT NULL
        BEGIN
            SET @Message = N'Value for "' + @BadField + N'" is not a valid ' + @BadType + N'.';
            EXEC Audit.Audit_LogFailure
                @AppUserId=@AppUserId, @LogEntityTypeCode=N'ToolAttribute',
                @EntityId=@ToolId, @LogEventTypeCode=N'Updated',
                @FailureReason=@Message, @ProcedureName=@ProcName,
                @AttemptedParameters=@Params;
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId; RETURN;
        END

        -- ===== Audit narrative (built from PRE-mutation state) =====
        DECLARE @ToolCode NVARCHAR(50), @ToolName NVARCHAR(200);
        SELECT @ToolCode = Code, @ToolName = Name FROM Tools.Tool WHERE Id = @ToolId;
        DECLARE @Subject NVARCHAR(600) =
            @ToolCode + CASE WHEN @ToolName IS NOT NULL
                             THEN N' ' + NCHAR(8212) + N' ' + @ToolName ELSE N'' END;

        DECLARE @Changes TABLE (
            ChangeKind NCHAR(1) NOT NULL, SortKey INT NOT NULL,
            DefCode NVARCHAR(50) NOT NULL,
            OldValue NVARCHAR(500) NULL, NewValue NVARCHAR(500) NULL
        );

        INSERT INTO @Changes (ChangeKind, SortKey, DefCode, NewValue)
        SELECT N'+', ROW_NUMBER() OVER (ORDER BY d.Code), d.Code, i.Value
        FROM @Incoming i
        INNER JOIN Tools.ToolAttributeDefinition d ON d.Id = i.ToolAttributeDefinitionId
        WHERE i.Id IS NULL;

        INSERT INTO @Changes (ChangeKind, SortKey, DefCode, OldValue, NewValue)
        SELECT N'~', ROW_NUMBER() OVER (ORDER BY d.Code), d.Code, ta.Value, i.Value
        FROM @Incoming i
        INNER JOIN Tools.ToolAttribute ta ON ta.Id = i.Id AND ta.ToolId = @ToolId
        INNER JOIN Tools.ToolAttributeDefinition d ON d.Id = ta.ToolAttributeDefinitionId
        WHERE ISNULL(ta.Value, N'') <> ISNULL(i.Value, N'');

        INSERT INTO @Changes (ChangeKind, SortKey, DefCode, OldValue)
        SELECT N'-', ROW_NUMBER() OVER (ORDER BY d.Code), d.Code, ta.Value
        FROM Tools.ToolAttribute ta
        INNER JOIN Tools.ToolAttributeDefinition d ON d.Id = ta.ToolAttributeDefinitionId
        WHERE ta.ToolId = @ToolId
          AND NOT EXISTS (SELECT 1 FROM @Incoming i WHERE i.Id = ta.Id);

        DECLARE @AddSpec NVARCHAR(MAX) = N'', @AddOv INT = 0;
        DECLARE @UpdSpec NVARCHAR(MAX) = N'', @UpdOv INT = 0;
        DECLARE @RemSpec NVARCHAR(MAX) = N'', @RemOv INT = 0;
        DECLARE @TotalRows INT = (SELECT COUNT(*) FROM @Incoming);

        ;WITH r AS (SELECT *, ROW_NUMBER() OVER (ORDER BY SortKey) rn FROM @Changes WHERE ChangeKind=N'+')
        SELECT @AddSpec = STRING_AGG(N'+' + DefCode + N'=' + ISNULL(NewValue,N''), N', ')
                          WITHIN GROUP (ORDER BY rn) FROM r WHERE rn <= 3;
        SELECT @AddOv = COUNT(*) - 3 FROM @Changes WHERE ChangeKind=N'+'; IF @AddOv<0 SET @AddOv=0;

        ;WITH r AS (SELECT *, ROW_NUMBER() OVER (ORDER BY SortKey) rn FROM @Changes WHERE ChangeKind=N'~')
        SELECT @UpdSpec = STRING_AGG(N'~' + DefCode + N' ' + ISNULL(OldValue,N'null')
                              + NCHAR(8594) + ISNULL(NewValue,N'null'), N'; ')
                          WITHIN GROUP (ORDER BY rn) FROM r WHERE rn <= 3;
        SELECT @UpdOv = COUNT(*) - 3 FROM @Changes WHERE ChangeKind=N'~'; IF @UpdOv<0 SET @UpdOv=0;

        ;WITH r AS (SELECT *, ROW_NUMBER() OVER (ORDER BY SortKey) rn FROM @Changes WHERE ChangeKind=N'-')
        SELECT @RemSpec = STRING_AGG(N'-' + DefCode, N', ')
                          WITHIN GROUP (ORDER BY rn) FROM r WHERE rn <= 3;
        SELECT @RemOv = COUNT(*) - 3 FROM @Changes WHERE ChangeKind=N'-'; IF @RemOv<0 SET @RemOv=0;

        DECLARE @ActionParts NVARCHAR(MAX) = N'';
        IF NULLIF(@AddSpec,N'') IS NOT NULL
            SET @ActionParts += @AddSpec + CASE WHEN @AddOv>0 THEN N', +' + CAST(@AddOv AS NVARCHAR) + N' more' ELSE N'' END + N'; ';
        IF NULLIF(@UpdSpec,N'') IS NOT NULL
            SET @ActionParts += @UpdSpec + CASE WHEN @UpdOv>0 THEN N'; ~' + CAST(@UpdOv AS NVARCHAR) + N' more' ELSE N'' END + N'; ';
        IF NULLIF(@RemSpec,N'') IS NOT NULL
            SET @ActionParts += @RemSpec + CASE WHEN @RemOv>0 THEN N', -' + CAST(@RemOv AS NVARCHAR) + N' more' ELSE N'' END + N'; ';
        IF DATALENGTH(@ActionParts) >= 4 SET @ActionParts = LEFT(@ActionParts, DATALENGTH(@ActionParts)/2 - 2);
        IF @ActionParts = N'' SET @ActionParts = N'No-op save';

        DECLARE @Activity NVARCHAR(500) = Audit.ufn_TruncateActivity(
            @Subject + N' ' + Audit.ufn_MidDot() + N' Attributes ' + Audit.ufn_MidDot() +
            N' ' + @ActionParts + N'; ' + CAST(@TotalRows AS NVARCHAR) + N' rows');

        DECLARE @OldValueResolved NVARCHAR(MAX) = (
            SELECT ta.Id,
                   JSON_QUERY((SELECT d.Id, d.Code, d.Name
                               FROM Tools.ToolAttributeDefinition d
                               WHERE d.Id = ta.ToolAttributeDefinitionId
                               FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)) AS Definition,
                   ta.Value
            FROM Tools.ToolAttribute ta
            WHERE ta.ToolId = @ToolId
            ORDER BY ta.ToolAttributeDefinitionId
            FOR JSON PATH);

        DECLARE @NewValueResolved NVARCHAR(MAX) = (
            SELECT i.Id,
                   JSON_QUERY((SELECT d.Id, d.Code, d.Name
                               FROM Tools.ToolAttributeDefinition d
                               WHERE d.Id = i.ToolAttributeDefinitionId
                               FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)) AS Definition,
                   i.Value
            FROM @Incoming i
            ORDER BY i.ToolAttributeDefinitionId
            FOR JSON PATH);

        -- ===== Mutation (atomic) =====
        BEGIN TRANSACTION;

        DELETE ta
        FROM Tools.ToolAttribute ta
        WHERE ta.ToolId = @ToolId
          AND NOT EXISTS (SELECT 1 FROM @Incoming i WHERE i.Id = ta.Id);

        UPDATE ta
        SET Value = i.Value, UpdatedAt = SYSUTCDATETIME(), UpdatedByUserId = @AppUserId
        FROM Tools.ToolAttribute ta
        INNER JOIN @Incoming i ON i.Id = ta.Id
        WHERE ta.ToolId = @ToolId;

        INSERT INTO Tools.ToolAttribute (ToolId, ToolAttributeDefinitionId, Value, UpdatedAt, UpdatedByUserId)
        SELECT @ToolId, i.ToolAttributeDefinitionId, i.Value, SYSUTCDATETIME(), @AppUserId
        FROM @Incoming i
        WHERE i.Id IS NULL;

        EXEC Audit.Audit_LogConfigChange
            @AppUserId=@AppUserId, @LogEntityTypeCode=N'ToolAttribute',
            @EntityId=@ToolId, @LogEventTypeCode=N'Updated', @LogSeverityCode=N'Info',
            @Description=@Activity, @OldValue=@OldValueResolved, @NewValue=@NewValueResolved;

        COMMIT TRANSACTION;

        SET @Status  = 1;
        SET @Message = N'Attributes saved. ' + CAST(@TotalRows AS NVARCHAR(10)) + N' row(s) in payload.';
        SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        DECLARE @ErrMsg NVARCHAR(4000) = ERROR_MESSAGE();
        DECLARE @ErrSev INT = ERROR_SEVERITY();
        DECLARE @ErrState INT = ERROR_STATE();
        SET @Status = 0;
        SET @Message = N'Unexpected error: ' + LEFT(@ErrMsg, 400);
        BEGIN TRY
            EXEC Audit.Audit_LogFailure
                @AppUserId=@AppUserId, @LogEntityTypeCode=N'ToolAttribute',
                @EntityId=@ToolId, @LogEventTypeCode=N'Updated',
                @FailureReason=@Message, @ProcedureName=@ProcName,
                @AttemptedParameters=@Params;
        END TRY BEGIN CATCH END CATCH
        SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
        RAISERROR(@ErrMsg, @ErrSev, @ErrState);
    END CATCH
END;
GO
```

- [ ] **Step 2: Commit** (proc + its test land together in Task A2's commit; do not commit alone).

### Task A2: `Tools.ToolAttribute_SaveAll` tests

**Files:**
- Create: `sql/tests/0017_Tools_Attribute/020_ToolAttribute_SaveAll.sql`

Mirror the framework in `sql/tests/0009_Parts_Process/040_ItemLocation_SaveAllForItem.sql`: `test.BeginTestFile` → fixtures → per-test `GO` batches with `CREATE TABLE #Rn (Status BIT, Message NVARCHAR(500), NewId BIGINT); INSERT INTO #Rn EXEC …; SELECT @S=Status …; test.Assert_IsEqual` → `test.EndTestFile`. Fixture needs a Die-type tool + two of its `ToolAttributeDefinition` rows (one `String`, one `Integer`) — resolve them dynamically (do not hardcode Ids).

- [ ] **Step 1: Write the failing test**

```sql
-- =============================================
-- File:         0017_Tools_Attribute/020_ToolAttribute_SaveAll.sql
-- Description:  Tests for Tools.ToolAttribute_SaveAll (bundled reconcile +
--               per-DataType value validation + hard-delete on absent).
-- =============================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0017_Tools_Attribute/020_ToolAttribute_SaveAll.sql';
GO

-- Fixture: a Die-type tool + two attribute definitions (String + Integer).
DECLARE @ToolTypeId BIGINT = (SELECT Id FROM Tools.ToolType WHERE Code = N'Die');
DECLARE @ToolId BIGINT = (SELECT Id FROM Tools.Tool WHERE Code = N'SA-ATTR-TOOL' AND DeprecatedAt IS NULL);
IF @ToolId IS NULL
BEGIN
    DECLARE @ActiveStatus BIGINT = (SELECT Id FROM Tools.ToolStatusCode WHERE Code = N'Active');
    INSERT INTO Tools.Tool (ToolTypeId, Code, Name, StatusCodeId, CreatedAt, CreatedByUserId)
    VALUES (@ToolTypeId, N'SA-ATTR-TOOL', N'SaveAll attr test tool', @ActiveStatus, SYSUTCDATETIME(), 1);
    SET @ToolId = SCOPE_IDENTITY();
END
IF NOT EXISTS (SELECT 1 FROM Tools.ToolAttributeDefinition WHERE ToolTypeId=@ToolTypeId AND Code=N'SA_STR' AND DeprecatedAt IS NULL)
    INSERT INTO Tools.ToolAttributeDefinition (ToolTypeId, Code, Name, DataType) VALUES (@ToolTypeId, N'SA_STR', N'SaveAll String', N'String');
IF NOT EXISTS (SELECT 1 FROM Tools.ToolAttributeDefinition WHERE ToolTypeId=@ToolTypeId AND Code=N'SA_INT' AND DeprecatedAt IS NULL)
    INSERT INTO Tools.ToolAttributeDefinition (ToolTypeId, Code, Name, DataType) VALUES (@ToolTypeId, N'SA_INT', N'SaveAll Integer', N'Integer');
GO

-- Test 1: add a String + Integer attribute (Id=NULL) -> Status=1, 2 rows persist
DECLARE @S BIT, @SStr NVARCHAR(1);
DECLARE @ToolId BIGINT = (SELECT Id FROM Tools.Tool WHERE Code = N'SA-ATTR-TOOL');
DECLARE @StrDef BIGINT = (SELECT Id FROM Tools.ToolAttributeDefinition WHERE Code=N'SA_STR' AND DeprecatedAt IS NULL);
DECLARE @IntDef BIGINT = (SELECT Id FROM Tools.ToolAttributeDefinition WHERE Code=N'SA_INT' AND DeprecatedAt IS NULL);
DECLARE @Json NVARCHAR(MAX) =
    N'[{"Id":null,"ToolAttributeDefinitionId":' + CAST(@StrDef AS NVARCHAR(20)) + N',"Value":"hello"},' +
    N'{"Id":null,"ToolAttributeDefinitionId":' + CAST(@IntDef AS NVARCHAR(20)) + N',"Value":"42"}]';
CREATE TABLE #R1 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #R1 EXEC Tools.ToolAttribute_SaveAll @ToolId=@ToolId, @RowsJson=@Json, @AppUserId=1;
SELECT @S = Status FROM #R1; DROP TABLE #R1;
SET @SStr = CAST(@S AS NVARCHAR(1));
EXEC test.Assert_IsEqual @TestName=N'[AttrSaveAdd] Status is 1', @Expected=N'1', @Actual=@SStr;
DECLARE @Cnt INT = (SELECT COUNT(*) FROM Tools.ToolAttribute WHERE ToolId=@ToolId);
DECLARE @CntStr NVARCHAR(10) = CAST(@Cnt AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName=N'[AttrSaveAdd] Two rows persist', @Expected=N'2', @Actual=@CntStr;
GO

-- Test 2: update a value + remove the other -> 1 row remains with new value
DECLARE @S BIT, @SStr NVARCHAR(1);
DECLARE @ToolId BIGINT = (SELECT Id FROM Tools.Tool WHERE Code = N'SA-ATTR-TOOL');
DECLARE @StrDef BIGINT = (SELECT Id FROM Tools.ToolAttributeDefinition WHERE Code=N'SA_STR' AND DeprecatedAt IS NULL);
DECLARE @StrRowId BIGINT = (SELECT Id FROM Tools.ToolAttribute WHERE ToolId=@ToolId AND ToolAttributeDefinitionId=@StrDef);
DECLARE @Json NVARCHAR(MAX) =
    N'[{"Id":' + CAST(@StrRowId AS NVARCHAR(20)) + N',"ToolAttributeDefinitionId":' + CAST(@StrDef AS NVARCHAR(20)) + N',"Value":"world"}]';
CREATE TABLE #R2 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #R2 EXEC Tools.ToolAttribute_SaveAll @ToolId=@ToolId, @RowsJson=@Json, @AppUserId=1;
SELECT @S = Status FROM #R2; DROP TABLE #R2;
SET @SStr = CAST(@S AS NVARCHAR(1));
EXEC test.Assert_IsEqual @TestName=N'[AttrSaveUpdRem] Status is 1', @Expected=N'1', @Actual=@SStr;
DECLARE @Val NVARCHAR(500) = (SELECT Value FROM Tools.ToolAttribute WHERE Id=@StrRowId);
EXEC test.Assert_IsEqual @TestName=N'[AttrSaveUpdRem] Value updated to world', @Expected=N'world', @Actual=@Val;
DECLARE @Cnt INT = (SELECT COUNT(*) FROM Tools.ToolAttribute WHERE ToolId=@ToolId);
DECLARE @CntStr NVARCHAR(10) = CAST(@Cnt AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName=N'[AttrSaveUpdRem] Absent row hard-deleted (1 remains)', @Expected=N'1', @Actual=@CntStr;
GO

-- Test 3: bad Integer value -> Status=0
DECLARE @S BIT, @SStr NVARCHAR(1);
DECLARE @ToolId BIGINT = (SELECT Id FROM Tools.Tool WHERE Code = N'SA-ATTR-TOOL');
DECLARE @IntDef BIGINT = (SELECT Id FROM Tools.ToolAttributeDefinition WHERE Code=N'SA_INT' AND DeprecatedAt IS NULL);
DECLARE @Json NVARCHAR(MAX) =
    N'[{"Id":null,"ToolAttributeDefinitionId":' + CAST(@IntDef AS NVARCHAR(20)) + N',"Value":"notanumber"}]';
CREATE TABLE #R3 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #R3 EXEC Tools.ToolAttribute_SaveAll @ToolId=@ToolId, @RowsJson=@Json, @AppUserId=1;
SELECT @S = Status FROM #R3; DROP TABLE #R3;
SET @SStr = CAST(@S AS NVARCHAR(1));
EXEC test.Assert_IsEqual @TestName=N'[AttrSaveBadInt] Status is 0', @Expected=N'0', @Actual=@SStr;
GO

-- Test 4: empty payload clears all rows -> Status=1, 0 rows
DECLARE @S BIT, @SStr NVARCHAR(1);
DECLARE @ToolId BIGINT = (SELECT Id FROM Tools.Tool WHERE Code = N'SA-ATTR-TOOL');
CREATE TABLE #R4 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #R4 EXEC Tools.ToolAttribute_SaveAll @ToolId=@ToolId, @RowsJson=N'[]', @AppUserId=1;
SELECT @S = Status FROM #R4; DROP TABLE #R4;
SET @SStr = CAST(@S AS NVARCHAR(1));
EXEC test.Assert_IsEqual @TestName=N'[AttrSaveEmpty] Status is 1', @Expected=N'1', @Actual=@SStr;
DECLARE @Cnt INT = (SELECT COUNT(*) FROM Tools.ToolAttribute WHERE ToolId=@ToolId);
DECLARE @CntStr NVARCHAR(10) = CAST(@Cnt AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName=N'[AttrSaveEmpty] Zero rows after clear', @Expected=N'0', @Actual=@CntStr;
GO

-- Test 5: Description carries SUBJECT mid-dot Attributes mid-dot prefix
DECLARE @ToolId BIGINT = (SELECT Id FROM Tools.Tool WHERE Code = N'SA-ATTR-TOOL');
DECLARE @TypeId BIGINT = (SELECT Id FROM Audit.LogEntityType WHERE Code = N'ToolAttribute');
DECLARE @StrDef BIGINT = (SELECT Id FROM Tools.ToolAttributeDefinition WHERE Code=N'SA_STR' AND DeprecatedAt IS NULL);
DECLARE @Json NVARCHAR(MAX) =
    N'[{"Id":null,"ToolAttributeDefinitionId":' + CAST(@StrDef AS NVARCHAR(20)) + N',"Value":"audit"}]';
CREATE TABLE #R5 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #R5 EXEC Tools.ToolAttribute_SaveAll @ToolId=@ToolId, @RowsJson=@Json, @AppUserId=1;
DROP TABLE #R5;
DECLARE @Desc NVARCHAR(500) = (SELECT TOP 1 Description FROM Audit.ConfigLog
                               WHERE EntityId=@ToolId AND LogEntityTypeId=@TypeId ORDER BY Id DESC);
DECLARE @Pat NVARCHAR(200) = N'SA-ATTR-TOOL%' + Audit.ufn_MidDot() + N' Attributes ' + Audit.ufn_MidDot() + N'%';
DECLARE @Match NVARCHAR(1) = CASE WHEN @Desc LIKE @Pat THEN N'1' ELSE N'0' END;
EXEC test.Assert_IsEqual @TestName=N'[AttrSaveAudit] Description has SUBJECT mid-dot Attributes prefix', @Expected=N'1', @Actual=@Match;
GO

EXEC test.EndTestFile;
GO
```

- [ ] **Step 2: Run the suite to confirm new tests pass**

Run (PowerShell, repo root): `.\Reset-DevDatabase.ps1`
Expected: rebuild completes; test summary shows the previous total **+ 7** new assertions, all passing (e.g. `1172/1172`). The five `[AttrSave*]` test names appear with PASS.

- [ ] **Step 3: Commit**

```bash
git add sql/migrations/repeatable/R__Tools_ToolAttribute_SaveAll.sql sql/tests/0017_Tools_Attribute/020_ToolAttribute_SaveAll.sql
git commit -m "feat(tools-sql): ToolAttribute_SaveAll bundled reconcile + DataType validation + tests"
```

### Task A3: `Tools.ToolCavity_SaveAll` proc

**Files:**
- Create: `sql/migrations/repeatable/R__Tools_ToolCavity_SaveAll.sql`

Table facts: `Tools.ToolCavity(Id, ToolId, CavityNumber INT, StatusCodeId FK Tools.ToolCavityStatusCode, Description NVARCHAR(500) NULL, CreatedAt, UpdatedAt, CreatedByUserId NOT NULL, UpdatedByUserId, DeprecatedAt)`. Unique active `UQ_ToolCavity_ActiveToolCavity(ToolId, CavityNumber) WHERE DeprecatedAt IS NULL`. Status seed: `Active`=1, `Closed`=2, `Scrapped`=3. Tool's ToolType must have `HasCavities=1`.

RowsJson element: `{"Id": long|null, "CavityNumber": int, "Description": string|null, "StatusCode": "Active"|"Closed"|"Scrapped"}`.

Reconcile: **insert + update only** (NO deprecate-on-absent — cavities persist; end-of-life is `Scrapped`). Rules enforced: number immutable on existing rows; reject transition out of `Scrapped`; `HasCavities`; CavityNumber ≥ 1; unique active number; valid StatusCode.

- [ ] **Step 1: Write the proc**

```sql
-- =============================================
-- Procedure:   Tools.ToolCavity_SaveAll
-- Author:      Blue Ridge Automation
-- Created:     2026-06-08
-- Version:     1.0
--
-- Description:
--   Bundled SaveAll for a Tool's cavities. Insert + update ONLY -- cavities
--   persist (no deprecate-on-absent; end-of-life via Scrapped status). On
--   existing rows CavityNumber is immutable and a row already Scrapped may
--   not transition to another status. Audit: <Tool> . Cavities . ACTION.
--
-- Parameters: @ToolId BIGINT, @RowsJson NVARCHAR(MAX), @AppUserId BIGINT
--   RowsJson element: {Id, CavityNumber, Description, StatusCode}
-- Result set: Status (BIT), Message (NVARCHAR), NewId (echoes @ToolId).
--
-- Change Log:
--   2026-06-08 - 1.0 - Initial (eligibility-style config editors).
-- =============================================
CREATE OR ALTER PROCEDURE Tools.ToolCavity_SaveAll
    @ToolId    BIGINT,
    @RowsJson  NVARCHAR(MAX),
    @AppUserId BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Status  BIT           = 0;
    DECLARE @Message NVARCHAR(500) = N'Unknown error';
    DECLARE @NewId   BIGINT        = @ToolId;

    DECLARE @ProcName NVARCHAR(200) = N'Tools.ToolCavity_SaveAll';
    DECLARE @Params   NVARCHAR(MAX) =
        (SELECT @ToolId AS ToolId, JSON_QUERY(@RowsJson) AS Rows
         FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

    DECLARE @Incoming TABLE (
        RowIndex     INT PRIMARY KEY,
        Id           BIGINT NULL,
        CavityNumber INT NULL,
        Description  NVARCHAR(500) NULL,
        StatusCode   NVARCHAR(20) NULL,
        StatusCodeId BIGINT NULL
    );

    BEGIN TRY
        IF @ToolId IS NULL OR @AppUserId IS NULL
        BEGIN
            SET @Message = N'Required parameter missing.';
            EXEC Audit.Audit_LogFailure @AppUserId=@AppUserId, @LogEntityTypeCode=N'ToolCavity', @EntityId=@ToolId, @LogEventTypeCode=N'Updated', @FailureReason=@Message, @ProcedureName=@ProcName, @AttemptedParameters=@Params;
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId; RETURN;
        END

        DECLARE @HasCavities BIT;
        SELECT @HasCavities = tt.HasCavities
        FROM Tools.Tool t INNER JOIN Tools.ToolType tt ON tt.Id = t.ToolTypeId
        WHERE t.Id = @ToolId AND t.DeprecatedAt IS NULL;

        IF @HasCavities IS NULL
        BEGIN
            SET @Message = N'Tool not found or deprecated.';
            EXEC Audit.Audit_LogFailure @AppUserId=@AppUserId, @LogEntityTypeCode=N'ToolCavity', @EntityId=@ToolId, @LogEventTypeCode=N'Updated', @FailureReason=@Message, @ProcedureName=@ProcName, @AttemptedParameters=@Params;
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId; RETURN;
        END
        IF @HasCavities = 0
        BEGIN
            SET @Message = N'This Tool''s type does not support cavities.';
            EXEC Audit.Audit_LogFailure @AppUserId=@AppUserId, @LogEntityTypeCode=N'ToolCavity', @EntityId=@ToolId, @LogEventTypeCode=N'Updated', @FailureReason=@Message, @ProcedureName=@ProcName, @AttemptedParameters=@Params;
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId; RETURN;
        END

        INSERT INTO @Incoming (RowIndex, Id, CavityNumber, Description, StatusCode)
        SELECT CAST([key] AS INT) + 1,
               TRY_CAST(JSON_VALUE([value], '$.Id') AS BIGINT),
               TRY_CAST(JSON_VALUE([value], '$.CavityNumber') AS INT),
               JSON_VALUE([value], '$.Description'),
               JSON_VALUE([value], '$.StatusCode')
        FROM OPENJSON(ISNULL(@RowsJson, N'[]'));

        -- Resolve StatusCode -> StatusCodeId; default missing to 'Active'
        UPDATE i SET StatusCode = N'Active' FROM @Incoming i WHERE i.StatusCode IS NULL OR i.StatusCode = N'';
        UPDATE i SET StatusCodeId = sc.Id
        FROM @Incoming i INNER JOIN Tools.ToolCavityStatusCode sc ON sc.Code = i.StatusCode;

        IF EXISTS (SELECT 1 FROM @Incoming WHERE StatusCodeId IS NULL)
        BEGIN
            SET @Message = N'One or more rows have an invalid cavity status.';
            EXEC Audit.Audit_LogFailure @AppUserId=@AppUserId, @LogEntityTypeCode=N'ToolCavity', @EntityId=@ToolId, @LogEventTypeCode=N'Updated', @FailureReason=@Message, @ProcedureName=@ProcName, @AttemptedParameters=@Params;
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId; RETURN;
        END

        IF EXISTS (SELECT 1 FROM @Incoming WHERE CavityNumber IS NULL OR CavityNumber < 1)
        BEGIN
            SET @Message = N'CavityNumber must be >= 1 on every row.';
            EXEC Audit.Audit_LogFailure @AppUserId=@AppUserId, @LogEntityTypeCode=N'ToolCavity', @EntityId=@ToolId, @LogEventTypeCode=N'Updated', @FailureReason=@Message, @ProcedureName=@ProcName, @AttemptedParameters=@Params;
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId; RETURN;
        END

        IF EXISTS (SELECT CavityNumber FROM @Incoming GROUP BY CavityNumber HAVING COUNT(*) > 1)
        BEGIN
            SET @Message = N'Duplicate cavity number in submitted rows.';
            EXEC Audit.Audit_LogFailure @AppUserId=@AppUserId, @LogEntityTypeCode=N'ToolCavity', @EntityId=@ToolId, @LogEventTypeCode=N'Updated', @FailureReason=@Message, @ProcedureName=@ProcName, @AttemptedParameters=@Params;
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId; RETURN;
        END

        -- Existing rows referenced by Id must belong to this tool (and be active)
        IF EXISTS (
            SELECT 1 FROM @Incoming i WHERE i.Id IS NOT NULL
            AND NOT EXISTS (SELECT 1 FROM Tools.ToolCavity c WHERE c.Id = i.Id AND c.ToolId = @ToolId AND c.DeprecatedAt IS NULL))
        BEGIN
            SET @Message = N'One or more cavity rows do not belong to this tool.';
            EXEC Audit.Audit_LogFailure @AppUserId=@AppUserId, @LogEntityTypeCode=N'ToolCavity', @EntityId=@ToolId, @LogEventTypeCode=N'Updated', @FailureReason=@Message, @ProcedureName=@ProcName, @AttemptedParameters=@Params;
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId; RETURN;
        END

        -- CavityNumber immutable on existing rows
        IF EXISTS (
            SELECT 1 FROM @Incoming i INNER JOIN Tools.ToolCavity c ON c.Id = i.Id
            WHERE i.Id IS NOT NULL AND c.CavityNumber <> i.CavityNumber)
        BEGIN
            SET @Message = N'Cavity number is immutable on existing cavities.';
            EXEC Audit.Audit_LogFailure @AppUserId=@AppUserId, @LogEntityTypeCode=N'ToolCavity', @EntityId=@ToolId, @LogEventTypeCode=N'Updated', @FailureReason=@Message, @ProcedureName=@ProcName, @AttemptedParameters=@Params;
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId; RETURN;
        END

        -- No transition OUT of Scrapped
        IF EXISTS (
            SELECT 1 FROM @Incoming i
            INNER JOIN Tools.ToolCavity c ON c.Id = i.Id
            INNER JOIN Tools.ToolCavityStatusCode sc ON sc.Id = c.StatusCodeId
            WHERE i.Id IS NOT NULL AND sc.Code = N'Scrapped' AND i.StatusCode <> N'Scrapped')
        BEGIN
            SET @Message = N'A scrapped cavity cannot change status.';
            EXEC Audit.Audit_LogFailure @AppUserId=@AppUserId, @LogEntityTypeCode=N'ToolCavity', @EntityId=@ToolId, @LogEventTypeCode=N'Updated', @FailureReason=@Message, @ProcedureName=@ProcName, @AttemptedParameters=@Params;
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId; RETURN;
        END

        -- New cavity number must not collide with an existing active cavity
        IF EXISTS (
            SELECT 1 FROM @Incoming i WHERE i.Id IS NULL
            AND EXISTS (SELECT 1 FROM Tools.ToolCavity c
                        WHERE c.ToolId = @ToolId AND c.CavityNumber = i.CavityNumber AND c.DeprecatedAt IS NULL))
        BEGIN
            SET @Message = N'A cavity with this number already exists on the tool.';
            EXEC Audit.Audit_LogFailure @AppUserId=@AppUserId, @LogEntityTypeCode=N'ToolCavity', @EntityId=@ToolId, @LogEventTypeCode=N'Updated', @FailureReason=@Message, @ProcedureName=@ProcName, @AttemptedParameters=@Params;
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId; RETURN;
        END

        -- ===== Audit narrative (PRE-mutation) =====
        DECLARE @ToolCode NVARCHAR(50), @ToolName NVARCHAR(200);
        SELECT @ToolCode = Code, @ToolName = Name FROM Tools.Tool WHERE Id = @ToolId;
        DECLARE @Subject NVARCHAR(600) =
            @ToolCode + CASE WHEN @ToolName IS NOT NULL THEN N' ' + NCHAR(8212) + N' ' + @ToolName ELSE N'' END;

        DECLARE @Changes TABLE (
            ChangeKind NCHAR(1) NOT NULL, SortKey INT NOT NULL,
            CavityNumber INT NOT NULL,
            OldStatus NVARCHAR(20) NULL, NewStatus NVARCHAR(20) NULL,
            OldDesc NVARCHAR(500) NULL, NewDesc NVARCHAR(500) NULL
        );

        INSERT INTO @Changes (ChangeKind, SortKey, CavityNumber, NewStatus, NewDesc)
        SELECT N'+', ROW_NUMBER() OVER (ORDER BY i.CavityNumber), i.CavityNumber, i.StatusCode, i.Description
        FROM @Incoming i WHERE i.Id IS NULL;

        INSERT INTO @Changes (ChangeKind, SortKey, CavityNumber, OldStatus, NewStatus, OldDesc, NewDesc)
        SELECT N'~', ROW_NUMBER() OVER (ORDER BY c.CavityNumber), c.CavityNumber,
               oldsc.Code, i.StatusCode, c.Description, i.Description
        FROM @Incoming i
        INNER JOIN Tools.ToolCavity c ON c.Id = i.Id
        INNER JOIN Tools.ToolCavityStatusCode oldsc ON oldsc.Id = c.StatusCodeId
        WHERE oldsc.Code <> i.StatusCode OR ISNULL(c.Description,N'') <> ISNULL(i.Description,N'');

        DECLARE @AddSpec NVARCHAR(MAX)=N'', @AddOv INT=0, @UpdSpec NVARCHAR(MAX)=N'', @UpdOv INT=0;
        DECLARE @TotalRows INT = (SELECT COUNT(*) FROM @Incoming);

        ;WITH r AS (SELECT *, ROW_NUMBER() OVER (ORDER BY SortKey) rn FROM @Changes WHERE ChangeKind=N'+')
        SELECT @AddSpec = STRING_AGG(N'+#' + CAST(CavityNumber AS NVARCHAR) + N' (' + ISNULL(NewStatus,N'Active') + N')', N', ')
                          WITHIN GROUP (ORDER BY rn) FROM r WHERE rn <= 3;
        SELECT @AddOv = COUNT(*) - 3 FROM @Changes WHERE ChangeKind=N'+'; IF @AddOv<0 SET @AddOv=0;

        ;WITH r AS (SELECT *, ROW_NUMBER() OVER (ORDER BY SortKey) rn FROM @Changes WHERE ChangeKind=N'~')
        SELECT @UpdSpec = STRING_AGG(N'~#' + CAST(CavityNumber AS NVARCHAR) + N' ' + ISNULL(OldStatus,N'null') + NCHAR(8594) + ISNULL(NewStatus,N'null'), N'; ')
                          WITHIN GROUP (ORDER BY rn) FROM r WHERE rn <= 3;
        SELECT @UpdOv = COUNT(*) - 3 FROM @Changes WHERE ChangeKind=N'~'; IF @UpdOv<0 SET @UpdOv=0;

        DECLARE @ActionParts NVARCHAR(MAX) = N'';
        IF NULLIF(@AddSpec,N'') IS NOT NULL
            SET @ActionParts += @AddSpec + CASE WHEN @AddOv>0 THEN N', +' + CAST(@AddOv AS NVARCHAR) + N' more' ELSE N'' END + N'; ';
        IF NULLIF(@UpdSpec,N'') IS NOT NULL
            SET @ActionParts += @UpdSpec + CASE WHEN @UpdOv>0 THEN N'; ~' + CAST(@UpdOv AS NVARCHAR) + N' more' ELSE N'' END + N'; ';
        IF DATALENGTH(@ActionParts) >= 4 SET @ActionParts = LEFT(@ActionParts, DATALENGTH(@ActionParts)/2 - 2);
        IF @ActionParts = N'' SET @ActionParts = N'No-op save';

        DECLARE @Activity NVARCHAR(500) = Audit.ufn_TruncateActivity(
            @Subject + N' ' + Audit.ufn_MidDot() + N' Cavities ' + Audit.ufn_MidDot() +
            N' ' + @ActionParts + N'; ' + CAST(@TotalRows AS NVARCHAR) + N' rows');

        DECLARE @OldValueResolved NVARCHAR(MAX) = (
            SELECT c.Id, c.CavityNumber, sc.Code AS Status, c.Description
            FROM Tools.ToolCavity c INNER JOIN Tools.ToolCavityStatusCode sc ON sc.Id = c.StatusCodeId
            WHERE c.ToolId = @ToolId AND c.DeprecatedAt IS NULL
            ORDER BY c.CavityNumber FOR JSON PATH);
        DECLARE @NewValueResolved NVARCHAR(MAX) = (
            SELECT i.Id, i.CavityNumber, i.StatusCode AS Status, i.Description
            FROM @Incoming i ORDER BY i.CavityNumber FOR JSON PATH);

        -- ===== Mutation (atomic) -- insert + update only =====
        BEGIN TRANSACTION;

        UPDATE c
        SET StatusCodeId = i.StatusCodeId, Description = i.Description,
            UpdatedAt = SYSUTCDATETIME(), UpdatedByUserId = @AppUserId
        FROM Tools.ToolCavity c INNER JOIN @Incoming i ON i.Id = c.Id
        WHERE c.ToolId = @ToolId AND c.DeprecatedAt IS NULL;

        INSERT INTO Tools.ToolCavity (ToolId, CavityNumber, StatusCodeId, Description, CreatedAt, CreatedByUserId)
        SELECT @ToolId, i.CavityNumber, i.StatusCodeId, i.Description, SYSUTCDATETIME(), @AppUserId
        FROM @Incoming i WHERE i.Id IS NULL;

        EXEC Audit.Audit_LogConfigChange
            @AppUserId=@AppUserId, @LogEntityTypeCode=N'ToolCavity',
            @EntityId=@ToolId, @LogEventTypeCode=N'Updated', @LogSeverityCode=N'Info',
            @Description=@Activity, @OldValue=@OldValueResolved, @NewValue=@NewValueResolved;

        COMMIT TRANSACTION;

        SET @Status  = 1;
        SET @Message = N'Cavities saved. ' + CAST(@TotalRows AS NVARCHAR(10)) + N' row(s) in payload.';
        SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        DECLARE @ErrMsg NVARCHAR(4000) = ERROR_MESSAGE();
        DECLARE @ErrSev INT = ERROR_SEVERITY();
        DECLARE @ErrState INT = ERROR_STATE();
        SET @Status = 0;
        SET @Message = N'Unexpected error: ' + LEFT(@ErrMsg, 400);
        BEGIN TRY
            EXEC Audit.Audit_LogFailure @AppUserId=@AppUserId, @LogEntityTypeCode=N'ToolCavity', @EntityId=@ToolId, @LogEventTypeCode=N'Updated', @FailureReason=@Message, @ProcedureName=@ProcName, @AttemptedParameters=@Params;
        END TRY BEGIN CATCH END CATCH
        SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
        RAISERROR(@ErrMsg, @ErrSev, @ErrState);
    END CATCH
END;
GO
```

### Task A4: `Tools.ToolCavity_SaveAll` tests

**Files:**
- Create: `sql/tests/0015_Tools_Cavity/020_ToolCavity_SaveAll.sql`

- [ ] **Step 1: Write the test** (same framework; fixture = Die-type tool with `HasCavities=1`)

```sql
SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0015_Tools_Cavity/020_ToolCavity_SaveAll.sql';
GO

DECLARE @ToolTypeId BIGINT = (SELECT Id FROM Tools.ToolType WHERE Code = N'Die');
DECLARE @ToolId BIGINT = (SELECT Id FROM Tools.Tool WHERE Code = N'SA-CAV-TOOL' AND DeprecatedAt IS NULL);
IF @ToolId IS NULL
BEGIN
    DECLARE @ActiveStatus BIGINT = (SELECT Id FROM Tools.ToolStatusCode WHERE Code = N'Active');
    INSERT INTO Tools.Tool (ToolTypeId, Code, Name, StatusCodeId, CreatedAt, CreatedByUserId)
    VALUES (@ToolTypeId, N'SA-CAV-TOOL', N'SaveAll cavity test tool', @ActiveStatus, SYSUTCDATETIME(), 1);
    SET @ToolId = SCOPE_IDENTITY();
END
-- Clear any cavities from prior runs (hard delete: test isolation only)
DELETE FROM Tools.ToolCavity WHERE ToolId = @ToolId;
GO

-- Test 1: add cavity #1 (Active) -> Status=1, one active row
DECLARE @S BIT, @SStr NVARCHAR(1);
DECLARE @ToolId BIGINT = (SELECT Id FROM Tools.Tool WHERE Code = N'SA-CAV-TOOL');
DECLARE @Json NVARCHAR(MAX) = N'[{"Id":null,"CavityNumber":1,"Description":"Cav one","StatusCode":"Active"}]';
CREATE TABLE #R1 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #R1 EXEC Tools.ToolCavity_SaveAll @ToolId=@ToolId, @RowsJson=@Json, @AppUserId=1;
SELECT @S = Status FROM #R1; DROP TABLE #R1;
SET @SStr = CAST(@S AS NVARCHAR(1));
EXEC test.Assert_IsEqual @TestName=N'[CavSaveAdd] Status is 1', @Expected=N'1', @Actual=@SStr;
DECLARE @Cnt INT = (SELECT COUNT(*) FROM Tools.ToolCavity WHERE ToolId=@ToolId AND DeprecatedAt IS NULL);
DECLARE @CntStr NVARCHAR(10) = CAST(@Cnt AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName=N'[CavSaveAdd] One active cavity', @Expected=N'1', @Actual=@CntStr;
GO

-- Test 2: change #1 to Scrapped -> Status=1, status persists
DECLARE @S BIT, @SStr NVARCHAR(1);
DECLARE @ToolId BIGINT = (SELECT Id FROM Tools.Tool WHERE Code = N'SA-CAV-TOOL');
DECLARE @CavId BIGINT = (SELECT Id FROM Tools.ToolCavity WHERE ToolId=@ToolId AND CavityNumber=1 AND DeprecatedAt IS NULL);
DECLARE @Json NVARCHAR(MAX) = N'[{"Id":' + CAST(@CavId AS NVARCHAR(20)) + N',"CavityNumber":1,"Description":"Cav one","StatusCode":"Scrapped"}]';
CREATE TABLE #R2 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #R2 EXEC Tools.ToolCavity_SaveAll @ToolId=@ToolId, @RowsJson=@Json, @AppUserId=1;
SELECT @S = Status FROM #R2; DROP TABLE #R2;
SET @SStr = CAST(@S AS NVARCHAR(1));
EXEC test.Assert_IsEqual @TestName=N'[CavSaveScrap] Status is 1', @Expected=N'1', @Actual=@SStr;
DECLARE @StatusCode NVARCHAR(20) = (SELECT sc.Code FROM Tools.ToolCavity c INNER JOIN Tools.ToolCavityStatusCode sc ON sc.Id=c.StatusCodeId WHERE c.Id=@CavId);
EXEC test.Assert_IsEqual @TestName=N'[CavSaveScrap] Status is Scrapped', @Expected=N'Scrapped', @Actual=@StatusCode;
GO

-- Test 3: try to un-scrap #1 -> Status=0 (Scrapped lock)
DECLARE @S BIT, @SStr NVARCHAR(1);
DECLARE @ToolId BIGINT = (SELECT Id FROM Tools.Tool WHERE Code = N'SA-CAV-TOOL');
DECLARE @CavId BIGINT = (SELECT Id FROM Tools.ToolCavity WHERE ToolId=@ToolId AND CavityNumber=1);
DECLARE @Json NVARCHAR(MAX) = N'[{"Id":' + CAST(@CavId AS NVARCHAR(20)) + N',"CavityNumber":1,"Description":"Cav one","StatusCode":"Active"}]';
CREATE TABLE #R3 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #R3 EXEC Tools.ToolCavity_SaveAll @ToolId=@ToolId, @RowsJson=@Json, @AppUserId=1;
SELECT @S = Status FROM #R3; DROP TABLE #R3;
SET @SStr = CAST(@S AS NVARCHAR(1));
EXEC test.Assert_IsEqual @TestName=N'[CavSaveUnscrap] Status is 0', @Expected=N'0', @Actual=@SStr;
GO

-- Test 4: change CavityNumber on existing row -> Status=0 (immutable)
DECLARE @S BIT, @SStr NVARCHAR(1);
DECLARE @ToolId BIGINT = (SELECT Id FROM Tools.Tool WHERE Code = N'SA-CAV-TOOL');
DECLARE @CavId BIGINT = (SELECT Id FROM Tools.ToolCavity WHERE ToolId=@ToolId AND CavityNumber=1);
DECLARE @Json NVARCHAR(MAX) = N'[{"Id":' + CAST(@CavId AS NVARCHAR(20)) + N',"CavityNumber":99,"Description":"Cav one","StatusCode":"Scrapped"}]';
CREATE TABLE #R4 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #R4 EXEC Tools.ToolCavity_SaveAll @ToolId=@ToolId, @RowsJson=@Json, @AppUserId=1;
SELECT @S = Status FROM #R4; DROP TABLE #R4;
SET @SStr = CAST(@S AS NVARCHAR(1));
EXEC test.Assert_IsEqual @TestName=N'[CavSaveImmutableNum] Status is 0', @Expected=N'0', @Actual=@SStr;
GO

-- Test 5: empty payload does NOT delete cavities (insert+update only)
DECLARE @S BIT, @SStr NVARCHAR(1);
DECLARE @ToolId BIGINT = (SELECT Id FROM Tools.Tool WHERE Code = N'SA-CAV-TOOL');
CREATE TABLE #R5 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #R5 EXEC Tools.ToolCavity_SaveAll @ToolId=@ToolId, @RowsJson=N'[]', @AppUserId=1;
SELECT @S = Status FROM #R5; DROP TABLE #R5;
SET @SStr = CAST(@S AS NVARCHAR(1));
EXEC test.Assert_IsEqual @TestName=N'[CavSaveEmpty] Status is 1', @Expected=N'1', @Actual=@SStr;
DECLARE @Cnt INT = (SELECT COUNT(*) FROM Tools.ToolCavity WHERE ToolId=@ToolId);
DECLARE @CntStr NVARCHAR(10) = CAST(@Cnt AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName=N'[CavSaveEmpty] Cavity persists (not deleted on absent)', @Expected=N'1', @Actual=@CntStr;
GO

EXEC test.EndTestFile;
GO
```

- [ ] **Step 2: Run `.\Reset-DevDatabase.ps1`** — expect the 7 new `[CavSave*]` assertions PASS, running total rises again.
- [ ] **Step 3: Commit**

```bash
git add sql/migrations/repeatable/R__Tools_ToolCavity_SaveAll.sql sql/tests/0015_Tools_Cavity/020_ToolCavity_SaveAll.sql
git commit -m "feat(tools-sql): ToolCavity_SaveAll insert+update reconcile (number immutable, Scrapped-lock) + tests"
```

### Task A5: `Parts.OperationTemplateField_SaveAll` proc

**Files:**
- Create: `sql/migrations/repeatable/R__Parts_OperationTemplateField_SaveAll.sql`

Table facts: `Parts.OperationTemplateField(Id, OperationTemplateId, DataCollectionFieldId, IsRequired BIT default 1, CreatedAt, DeprecatedAt)`. Unique active `UQ_OperationTemplateField_ActiveTemplateField(OperationTemplateId, DataCollectionFieldId) WHERE DeprecatedAt IS NULL`. `Parts.DataCollectionField` is global (no tool-type scoping).

RowsJson element: `{"Id": long|null, "DataCollectionFieldId": long, "IsRequired": bool}`.

Reconcile (4-step, mirrors eligibility): **deprecate-on-absent / update `IsRequired` / reactivate (Id=NULL + deprecated pairing) / insert**. Audit code `OpTemplateField`, Category `Fields`. Subject resolved from the OperationTemplate (`Code` v`VersionNumber` — `Name`).

- [ ] **Step 1: Write the proc**

```sql
-- =============================================
-- Procedure:   Parts.OperationTemplateField_SaveAll
-- Author:      Blue Ridge Automation
-- Created:     2026-06-08
-- Version:     1.0
--
-- Description:
--   Bundled SaveAll for an OperationTemplate's data-collection fields.
--   Reconciles desired-state JSON against active junction rows:
--     - Id matches active row        -> UPDATE IsRequired
--     - Id = NULL, no pairing         -> INSERT
--     - Id = NULL, deprecated pairing -> REACTIVATE
--     - Active row not in incoming    -> DEPRECATE
--   Audit: <Template Code vN - Name> . Fields . ACTION.
--
-- Parameters: @OperationTemplateId BIGINT, @RowsJson NVARCHAR(MAX), @AppUserId BIGINT
--   RowsJson element: {Id, DataCollectionFieldId, IsRequired}
-- Result set: Status (BIT), Message (NVARCHAR), NewId (echoes @OperationTemplateId).
--
-- Change Log:
--   2026-06-08 - 1.0 - Initial (eligibility-style config editors).
-- =============================================
CREATE OR ALTER PROCEDURE Parts.OperationTemplateField_SaveAll
    @OperationTemplateId BIGINT,
    @RowsJson            NVARCHAR(MAX),
    @AppUserId           BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Status  BIT           = 0;
    DECLARE @Message NVARCHAR(500) = N'Unknown error';
    DECLARE @NewId   BIGINT        = @OperationTemplateId;

    DECLARE @ProcName NVARCHAR(200) = N'Parts.OperationTemplateField_SaveAll';
    DECLARE @Params   NVARCHAR(MAX) =
        (SELECT @OperationTemplateId AS OperationTemplateId, JSON_QUERY(@RowsJson) AS Rows
         FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

    DECLARE @Incoming TABLE (
        RowIndex              INT PRIMARY KEY,
        Id                    BIGINT NULL,
        DataCollectionFieldId BIGINT NULL,
        IsRequired            BIT NULL
    );

    BEGIN TRY
        IF @OperationTemplateId IS NULL OR @AppUserId IS NULL
        BEGIN
            SET @Message = N'Required parameter missing.';
            EXEC Audit.Audit_LogFailure @AppUserId=@AppUserId, @LogEntityTypeCode=N'OpTemplateField', @EntityId=@OperationTemplateId, @LogEventTypeCode=N'Updated', @FailureReason=@Message, @ProcedureName=@ProcName, @AttemptedParameters=@Params;
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId; RETURN;
        END

        IF NOT EXISTS (SELECT 1 FROM Parts.OperationTemplate WHERE Id = @OperationTemplateId AND DeprecatedAt IS NULL)
        BEGIN
            SET @Message = N'Operation template not found or deprecated.';
            EXEC Audit.Audit_LogFailure @AppUserId=@AppUserId, @LogEntityTypeCode=N'OpTemplateField', @EntityId=@OperationTemplateId, @LogEventTypeCode=N'Updated', @FailureReason=@Message, @ProcedureName=@ProcName, @AttemptedParameters=@Params;
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId; RETURN;
        END

        INSERT INTO @Incoming (RowIndex, Id, DataCollectionFieldId, IsRequired)
        SELECT CAST([key] AS INT) + 1,
               TRY_CAST(JSON_VALUE([value], '$.Id') AS BIGINT),
               TRY_CAST(JSON_VALUE([value], '$.DataCollectionFieldId') AS BIGINT),
               COALESCE(TRY_CAST(JSON_VALUE([value], '$.IsRequired') AS BIT), 1)
        FROM OPENJSON(ISNULL(@RowsJson, N'[]'));

        IF EXISTS (SELECT 1 FROM @Incoming WHERE DataCollectionFieldId IS NULL)
        BEGIN
            SET @Message = N'One or more rows are missing DataCollectionFieldId.';
            EXEC Audit.Audit_LogFailure @AppUserId=@AppUserId, @LogEntityTypeCode=N'OpTemplateField', @EntityId=@OperationTemplateId, @LogEventTypeCode=N'Updated', @FailureReason=@Message, @ProcedureName=@ProcName, @AttemptedParameters=@Params;
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId; RETURN;
        END

        IF EXISTS (SELECT 1 FROM @Incoming i WHERE NOT EXISTS (
            SELECT 1 FROM Parts.DataCollectionField f WHERE f.Id = i.DataCollectionFieldId AND f.DeprecatedAt IS NULL))
        BEGIN
            SET @Message = N'One or more data collection fields are invalid or deprecated.';
            EXEC Audit.Audit_LogFailure @AppUserId=@AppUserId, @LogEntityTypeCode=N'OpTemplateField', @EntityId=@OperationTemplateId, @LogEventTypeCode=N'Updated', @FailureReason=@Message, @ProcedureName=@ProcName, @AttemptedParameters=@Params;
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId; RETURN;
        END

        IF EXISTS (SELECT DataCollectionFieldId FROM @Incoming GROUP BY DataCollectionFieldId HAVING COUNT(*) > 1)
        BEGIN
            SET @Message = N'Duplicate field in submitted rows.';
            EXEC Audit.Audit_LogFailure @AppUserId=@AppUserId, @LogEntityTypeCode=N'OpTemplateField', @EntityId=@OperationTemplateId, @LogEventTypeCode=N'Updated', @FailureReason=@Message, @ProcedureName=@ProcName, @AttemptedParameters=@Params;
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId; RETURN;
        END

        -- ===== Audit narrative (PRE-mutation) =====
        DECLARE @TCode NVARCHAR(50), @TVer INT, @TName NVARCHAR(200);
        SELECT @TCode = Code, @TVer = VersionNumber, @TName = Name
        FROM Parts.OperationTemplate WHERE Id = @OperationTemplateId;
        DECLARE @Subject NVARCHAR(600) =
            @TCode + N' v' + CAST(@TVer AS NVARCHAR(10))
            + CASE WHEN @TName IS NOT NULL THEN N' ' + NCHAR(8212) + N' ' + @TName ELSE N'' END;

        DECLARE @Changes TABLE (
            ChangeKind NCHAR(1) NOT NULL, SortKey INT NOT NULL,
            FieldCode NVARCHAR(50) NOT NULL,
            OldRequired BIT NULL, NewRequired BIT NULL
        );

        -- ADDS (Id NULL, no existing pairing)
        INSERT INTO @Changes (ChangeKind, SortKey, FieldCode, NewRequired)
        SELECT N'+', ROW_NUMBER() OVER (ORDER BY f.Code), f.Code, i.IsRequired
        FROM @Incoming i INNER JOIN Parts.DataCollectionField f ON f.Id = i.DataCollectionFieldId
        WHERE i.Id IS NULL
          AND NOT EXISTS (SELECT 1 FROM Parts.OperationTemplateField j
                          WHERE j.OperationTemplateId = @OperationTemplateId AND j.DataCollectionFieldId = i.DataCollectionFieldId);
        -- ADDS via reactivation render as + too
        INSERT INTO @Changes (ChangeKind, SortKey, FieldCode, NewRequired)
        SELECT N'+', 100 + ROW_NUMBER() OVER (ORDER BY f.Code), f.Code, i.IsRequired
        FROM @Incoming i
        INNER JOIN Parts.OperationTemplateField j
            ON j.OperationTemplateId = @OperationTemplateId AND j.DataCollectionFieldId = i.DataCollectionFieldId AND j.DeprecatedAt IS NOT NULL
        INNER JOIN Parts.DataCollectionField f ON f.Id = i.DataCollectionFieldId
        WHERE i.Id IS NULL;

        -- UPDATES (Id matched, IsRequired differs)
        INSERT INTO @Changes (ChangeKind, SortKey, FieldCode, OldRequired, NewRequired)
        SELECT N'~', ROW_NUMBER() OVER (ORDER BY f.Code), f.Code, j.IsRequired, i.IsRequired
        FROM @Incoming i
        INNER JOIN Parts.OperationTemplateField j ON j.Id = i.Id AND j.OperationTemplateId = @OperationTemplateId
        INNER JOIN Parts.DataCollectionField f ON f.Id = j.DataCollectionFieldId
        WHERE j.DeprecatedAt IS NULL AND j.IsRequired <> i.IsRequired;

        -- REMOVES (active row not in incoming)
        INSERT INTO @Changes (ChangeKind, SortKey, FieldCode, OldRequired)
        SELECT N'-', ROW_NUMBER() OVER (ORDER BY f.Code), f.Code, j.IsRequired
        FROM Parts.OperationTemplateField j INNER JOIN Parts.DataCollectionField f ON f.Id = j.DataCollectionFieldId
        WHERE j.OperationTemplateId = @OperationTemplateId AND j.DeprecatedAt IS NULL
          AND NOT EXISTS (SELECT 1 FROM @Incoming i WHERE i.Id = j.Id);

        DECLARE @AddSpec NVARCHAR(MAX)=N'', @AddOv INT=0, @UpdSpec NVARCHAR(MAX)=N'', @UpdOv INT=0, @RemSpec NVARCHAR(MAX)=N'', @RemOv INT=0;
        DECLARE @TotalRows INT = (SELECT COUNT(*) FROM @Incoming);

        ;WITH r AS (SELECT *, ROW_NUMBER() OVER (ORDER BY SortKey) rn FROM @Changes WHERE ChangeKind=N'+')
        SELECT @AddSpec = STRING_AGG(N'+' + FieldCode, N', ') WITHIN GROUP (ORDER BY rn) FROM r WHERE rn <= 3;
        SELECT @AddOv = COUNT(*) - 3 FROM @Changes WHERE ChangeKind=N'+'; IF @AddOv<0 SET @AddOv=0;

        ;WITH r AS (SELECT *, ROW_NUMBER() OVER (ORDER BY SortKey) rn FROM @Changes WHERE ChangeKind=N'~')
        SELECT @UpdSpec = STRING_AGG(N'~' + FieldCode + N' IsRequired '
                              + CASE WHEN OldRequired=1 THEN N'true' ELSE N'false' END + NCHAR(8594)
                              + CASE WHEN NewRequired=1 THEN N'true' ELSE N'false' END, N'; ')
                          WITHIN GROUP (ORDER BY rn) FROM r WHERE rn <= 3;
        SELECT @UpdOv = COUNT(*) - 3 FROM @Changes WHERE ChangeKind=N'~'; IF @UpdOv<0 SET @UpdOv=0;

        ;WITH r AS (SELECT *, ROW_NUMBER() OVER (ORDER BY SortKey) rn FROM @Changes WHERE ChangeKind=N'-')
        SELECT @RemSpec = STRING_AGG(N'-' + FieldCode, N', ') WITHIN GROUP (ORDER BY rn) FROM r WHERE rn <= 3;
        SELECT @RemOv = COUNT(*) - 3 FROM @Changes WHERE ChangeKind=N'-'; IF @RemOv<0 SET @RemOv=0;

        DECLARE @ActionParts NVARCHAR(MAX) = N'';
        IF NULLIF(@AddSpec,N'') IS NOT NULL
            SET @ActionParts += @AddSpec + CASE WHEN @AddOv>0 THEN N', +' + CAST(@AddOv AS NVARCHAR) + N' more' ELSE N'' END + N'; ';
        IF NULLIF(@UpdSpec,N'') IS NOT NULL
            SET @ActionParts += @UpdSpec + CASE WHEN @UpdOv>0 THEN N'; ~' + CAST(@UpdOv AS NVARCHAR) + N' more' ELSE N'' END + N'; ';
        IF NULLIF(@RemSpec,N'') IS NOT NULL
            SET @ActionParts += @RemSpec + CASE WHEN @RemOv>0 THEN N', -' + CAST(@RemOv AS NVARCHAR) + N' more' ELSE N'' END + N'; ';
        IF DATALENGTH(@ActionParts) >= 4 SET @ActionParts = LEFT(@ActionParts, DATALENGTH(@ActionParts)/2 - 2);
        IF @ActionParts = N'' SET @ActionParts = N'No-op save';

        DECLARE @Activity NVARCHAR(500) = Audit.ufn_TruncateActivity(
            @Subject + N' ' + Audit.ufn_MidDot() + N' Fields ' + Audit.ufn_MidDot() +
            N' ' + @ActionParts + N'; ' + CAST(@TotalRows AS NVARCHAR) + N' rows');

        DECLARE @OldValueResolved NVARCHAR(MAX) = (
            SELECT j.Id,
                   JSON_QUERY((SELECT f.Id, f.Code, f.Name FROM Parts.DataCollectionField f
                               WHERE f.Id = j.DataCollectionFieldId FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)) AS Field,
                   j.IsRequired
            FROM Parts.OperationTemplateField j
            WHERE j.OperationTemplateId = @OperationTemplateId AND j.DeprecatedAt IS NULL
            ORDER BY j.DataCollectionFieldId FOR JSON PATH);
        DECLARE @NewValueResolved NVARCHAR(MAX) = (
            SELECT i.Id,
                   JSON_QUERY((SELECT f.Id, f.Code, f.Name FROM Parts.DataCollectionField f
                               WHERE f.Id = i.DataCollectionFieldId FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)) AS Field,
                   i.IsRequired
            FROM @Incoming i ORDER BY i.DataCollectionFieldId FOR JSON PATH);

        -- ===== Mutation (atomic, 4-step) =====
        BEGIN TRANSACTION;

        UPDATE Parts.OperationTemplateField
        SET DeprecatedAt = SYSUTCDATETIME()
        WHERE OperationTemplateId = @OperationTemplateId AND DeprecatedAt IS NULL
          AND NOT EXISTS (SELECT 1 FROM @Incoming i WHERE i.Id = Parts.OperationTemplateField.Id);

        UPDATE j SET IsRequired = i.IsRequired
        FROM Parts.OperationTemplateField j INNER JOIN @Incoming i ON i.Id = j.Id
        WHERE j.OperationTemplateId = @OperationTemplateId AND j.DeprecatedAt IS NULL;

        UPDATE j SET DeprecatedAt = NULL, IsRequired = i.IsRequired
        FROM Parts.OperationTemplateField j
        INNER JOIN @Incoming i ON i.Id IS NULL AND i.DataCollectionFieldId = j.DataCollectionFieldId
        WHERE j.OperationTemplateId = @OperationTemplateId AND j.DeprecatedAt IS NOT NULL;

        INSERT INTO Parts.OperationTemplateField (OperationTemplateId, DataCollectionFieldId, IsRequired, CreatedAt)
        SELECT @OperationTemplateId, i.DataCollectionFieldId, i.IsRequired, SYSUTCDATETIME()
        FROM @Incoming i
        WHERE i.Id IS NULL
          AND NOT EXISTS (SELECT 1 FROM Parts.OperationTemplateField j
                          WHERE j.OperationTemplateId = @OperationTemplateId AND j.DataCollectionFieldId = i.DataCollectionFieldId);

        EXEC Audit.Audit_LogConfigChange
            @AppUserId=@AppUserId, @LogEntityTypeCode=N'OpTemplateField',
            @EntityId=@OperationTemplateId, @LogEventTypeCode=N'Updated', @LogSeverityCode=N'Info',
            @Description=@Activity, @OldValue=@OldValueResolved, @NewValue=@NewValueResolved;

        COMMIT TRANSACTION;

        SET @Status  = 1;
        SET @Message = N'Fields saved. ' + CAST(@TotalRows AS NVARCHAR(10)) + N' row(s) in payload.';
        SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        DECLARE @ErrMsg NVARCHAR(4000) = ERROR_MESSAGE();
        DECLARE @ErrSev INT = ERROR_SEVERITY();
        DECLARE @ErrState INT = ERROR_STATE();
        SET @Status = 0;
        SET @Message = N'Unexpected error: ' + LEFT(@ErrMsg, 400);
        BEGIN TRY
            EXEC Audit.Audit_LogFailure @AppUserId=@AppUserId, @LogEntityTypeCode=N'OpTemplateField', @EntityId=@OperationTemplateId, @LogEventTypeCode=N'Updated', @FailureReason=@Message, @ProcedureName=@ProcName, @AttemptedParameters=@Params;
        END TRY BEGIN CATCH END CATCH
        SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
        RAISERROR(@ErrMsg, @ErrSev, @ErrState);
    END CATCH
END;
GO
```

### Task A6: `Parts.OperationTemplateField_SaveAll` tests

**Files:**
- Create: `sql/tests/0009_Parts_Process/050_OperationTemplateField_SaveAll.sql`

Fixture: an OperationTemplate (reuse an existing one or create) + use seeded `DataCollectionField` rows (Ids 1–7: `MaterialVerification`, `SerialNumber`, …).

- [ ] **Step 1: Write the test**

```sql
SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0009_Parts_Process/050_OperationTemplateField_SaveAll.sql';
GO

-- Fixture: an OperationTemplate to attach fields to.
DECLARE @TemplateId BIGINT = (SELECT Id FROM Parts.OperationTemplate WHERE Code = N'SA-OTF-TPL' AND DeprecatedAt IS NULL);
IF @TemplateId IS NULL
BEGIN
    DECLARE @AreaId BIGINT = (SELECT TOP 1 l.Id FROM Location.Location l
                              INNER JOIN Location.LocationTypeDefinition ltd ON ltd.Id = l.LocationTypeDefinitionId
                              INNER JOIN Location.LocationType lt ON lt.Id = ltd.LocationTypeId
                              WHERE lt.Code = N'Area' AND l.DeprecatedAt IS NULL ORDER BY l.Code);
    INSERT INTO Parts.OperationTemplate (Code, Name, VersionNumber, AreaLocationId, CreatedAt, CreatedByUserId)
    VALUES (N'SA-OTF-TPL', N'SaveAll field test template', 1, @AreaId, SYSUTCDATETIME(), 1);
    SET @TemplateId = SCOPE_IDENTITY();
END
-- Clean prior junctions for isolation
UPDATE Parts.OperationTemplateField SET DeprecatedAt = SYSUTCDATETIME()
WHERE OperationTemplateId = @TemplateId AND DeprecatedAt IS NULL;
GO

-- Test 1: add two fields (Id=NULL) -> Status=1, two active rows
DECLARE @S BIT, @SStr NVARCHAR(1);
DECLARE @TemplateId BIGINT = (SELECT Id FROM Parts.OperationTemplate WHERE Code = N'SA-OTF-TPL');
DECLARE @F1 BIGINT = (SELECT Id FROM Parts.DataCollectionField WHERE Code = N'Weight');
DECLARE @F2 BIGINT = (SELECT Id FROM Parts.DataCollectionField WHERE Code = N'GoodCount');
DECLARE @Json NVARCHAR(MAX) =
    N'[{"Id":null,"DataCollectionFieldId":' + CAST(@F1 AS NVARCHAR(20)) + N',"IsRequired":true},' +
    N'{"Id":null,"DataCollectionFieldId":' + CAST(@F2 AS NVARCHAR(20)) + N',"IsRequired":false}]';
CREATE TABLE #R1 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #R1 EXEC Parts.OperationTemplateField_SaveAll @OperationTemplateId=@TemplateId, @RowsJson=@Json, @AppUserId=1;
SELECT @S = Status FROM #R1; DROP TABLE #R1;
SET @SStr = CAST(@S AS NVARCHAR(1));
EXEC test.Assert_IsEqual @TestName=N'[OtfSaveAdd] Status is 1', @Expected=N'1', @Actual=@SStr;
DECLARE @Cnt INT = (SELECT COUNT(*) FROM Parts.OperationTemplateField WHERE OperationTemplateId=@TemplateId AND DeprecatedAt IS NULL);
DECLARE @CntStr NVARCHAR(10) = CAST(@Cnt AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName=N'[OtfSaveAdd] Two active fields', @Expected=N'2', @Actual=@CntStr;
GO

-- Test 2: flip one IsRequired + remove the other -> 1 active row, IsRequired flipped
DECLARE @S BIT, @SStr NVARCHAR(1);
DECLARE @TemplateId BIGINT = (SELECT Id FROM Parts.OperationTemplate WHERE Code = N'SA-OTF-TPL');
DECLARE @F1 BIGINT = (SELECT Id FROM Parts.DataCollectionField WHERE Code = N'Weight');
DECLARE @J1 BIGINT = (SELECT Id FROM Parts.OperationTemplateField WHERE OperationTemplateId=@TemplateId AND DataCollectionFieldId=@F1 AND DeprecatedAt IS NULL);
DECLARE @Json NVARCHAR(MAX) =
    N'[{"Id":' + CAST(@J1 AS NVARCHAR(20)) + N',"DataCollectionFieldId":' + CAST(@F1 AS NVARCHAR(20)) + N',"IsRequired":false}]';
CREATE TABLE #R2 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #R2 EXEC Parts.OperationTemplateField_SaveAll @OperationTemplateId=@TemplateId, @RowsJson=@Json, @AppUserId=1;
SELECT @S = Status FROM #R2; DROP TABLE #R2;
SET @SStr = CAST(@S AS NVARCHAR(1));
EXEC test.Assert_IsEqual @TestName=N'[OtfSaveUpdRem] Status is 1', @Expected=N'1', @Actual=@SStr;
DECLARE @Req BIT = (SELECT IsRequired FROM Parts.OperationTemplateField WHERE Id=@J1);
DECLARE @ReqStr NVARCHAR(1) = CAST(@Req AS NVARCHAR(1));
EXEC test.Assert_IsEqual @TestName=N'[OtfSaveUpdRem] IsRequired flipped to 0', @Expected=N'0', @Actual=@ReqStr;
DECLARE @Cnt INT = (SELECT COUNT(*) FROM Parts.OperationTemplateField WHERE OperationTemplateId=@TemplateId AND DeprecatedAt IS NULL);
DECLARE @CntStr NVARCHAR(10) = CAST(@Cnt AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName=N'[OtfSaveUpdRem] One active field after remove', @Expected=N'1', @Actual=@CntStr;
GO

-- Test 3: re-add the removed field (Id=NULL) reactivates rather than duplicating
DECLARE @S BIT, @SStr NVARCHAR(1);
DECLARE @TemplateId BIGINT = (SELECT Id FROM Parts.OperationTemplate WHERE Code = N'SA-OTF-TPL');
DECLARE @F1 BIGINT = (SELECT Id FROM Parts.DataCollectionField WHERE Code = N'Weight');
DECLARE @F2 BIGINT = (SELECT Id FROM Parts.DataCollectionField WHERE Code = N'GoodCount');
DECLARE @J1 BIGINT = (SELECT Id FROM Parts.OperationTemplateField WHERE OperationTemplateId=@TemplateId AND DataCollectionFieldId=@F1 AND DeprecatedAt IS NULL);
DECLARE @Json NVARCHAR(MAX) =
    N'[{"Id":' + CAST(@J1 AS NVARCHAR(20)) + N',"DataCollectionFieldId":' + CAST(@F1 AS NVARCHAR(20)) + N',"IsRequired":false},' +
    N'{"Id":null,"DataCollectionFieldId":' + CAST(@F2 AS NVARCHAR(20)) + N',"IsRequired":true}]';
CREATE TABLE #R3 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #R3 EXEC Parts.OperationTemplateField_SaveAll @OperationTemplateId=@TemplateId, @RowsJson=@Json, @AppUserId=1;
SELECT @S = Status FROM #R3; DROP TABLE #R3;
SET @SStr = CAST(@S AS NVARCHAR(1));
EXEC test.Assert_IsEqual @TestName=N'[OtfSaveReact] Status is 1', @Expected=N'1', @Actual=@SStr;
DECLARE @DistinctRows INT = (SELECT COUNT(*) FROM Parts.OperationTemplateField WHERE OperationTemplateId=@TemplateId AND DataCollectionFieldId=@F2);
DECLARE @DRStr NVARCHAR(10) = CAST(@DistinctRows AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName=N'[OtfSaveReact] GoodCount reactivated, not duplicated', @Expected=N'1', @Actual=@DRStr;
GO

-- Test 4: bad template id -> Status=0
DECLARE @S BIT, @SStr NVARCHAR(1);
CREATE TABLE #R4 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #R4 EXEC Parts.OperationTemplateField_SaveAll @OperationTemplateId=9999999999, @RowsJson=N'[]', @AppUserId=1;
SELECT @S = Status FROM #R4; DROP TABLE #R4;
SET @SStr = CAST(@S AS NVARCHAR(1));
EXEC test.Assert_IsEqual @TestName=N'[OtfSaveBadTpl] Status is 0', @Expected=N'0', @Actual=@SStr;
GO

EXEC test.EndTestFile;
GO
```

- [ ] **Step 2: Run `.\Reset-DevDatabase.ps1`** — expect the 8 new `[Otf*]` assertions PASS.
- [ ] **Step 3: Commit**

```bash
git add sql/migrations/repeatable/R__Parts_OperationTemplateField_SaveAll.sql sql/tests/0009_Parts_Process/050_OperationTemplateField_SaveAll.sql
git commit -m "feat(parts-sql): OperationTemplateField_SaveAll reconcile (insert/update/deprecate/reactivate) + tests"
```

### Task A7: Full-suite green checkpoint

- [ ] **Step 1:** Run `.\Reset-DevDatabase.ps1` from a clean state.
- [ ] **Step 2:** Confirm the summary line shows **all tests passing** with the new total (1165 baseline + the new assertions across the three files). No FAIL lines. If any fail, fix the proc/test before proceeding — do NOT move to Phase B with a red suite.

---

## Phase B — Named Queries (thin EXEC wrappers)

### Task B1: Three SaveAll NQs + scan

**Files (create each folder with both files):**
- `ignition/projects/MPP_Config/ignition/named-query/parts/ToolAttribute_SaveAll/query.sql` + `resource.json`
- `…/parts/ToolCavity_SaveAll/query.sql` + `resource.json`
- `…/parts/OperationTemplateField_SaveAll/query.sql` + `resource.json`

- [ ] **Step 1: Write `ToolAttribute_SaveAll/query.sql`**

```sql
-- @toolId    BIGINT
-- @rowsJson  NVARCHAR(MAX)
-- @appUserId BIGINT
EXEC Tools.ToolAttribute_SaveAll
    @ToolId    = :toolId,
    @RowsJson  = :rowsJson,
    @AppUserId = :appUserId
```

- [ ] **Step 2: Write `ToolAttribute_SaveAll/resource.json`**

```json
{
  "scope": "DG",
  "version": 2,
  "restricted": false,
  "overridable": true,
  "files": [ "query.sql" ],
  "attributes": {
    "useMaxReturnSize": false,
    "autoBatchEnabled": false,
    "fallbackValue": "",
    "maxReturnSize": 100,
    "cacheUnit": "SEC",
    "type": "Query",
    "enabled": true,
    "cacheAmount": 1,
    "cacheEnabled": false,
    "database": "MPP",
    "fallbackEnabled": false,
    "lastModificationSignature": "",
    "permissions": [ { "zone": "", "role": "" } ],
    "lastModification": { "actor": "claude", "timestamp": "2026-06-08T00:00:00Z" },
    "parameters": [
      { "type": "Parameter", "identifier": "toolId",    "sqlType": 3 },
      { "type": "Parameter", "identifier": "rowsJson",   "sqlType": 7 },
      { "type": "Parameter", "identifier": "appUserId",  "sqlType": 3 }
    ]
  }
}
```

- [ ] **Step 3: Write `ToolCavity_SaveAll/query.sql`** — identical shape, `EXEC Tools.ToolCavity_SaveAll @ToolId=:toolId, @RowsJson=:rowsJson, @AppUserId=:appUserId`. Its `resource.json` is identical to Step 2 (same three params `toolId`/`rowsJson`/`appUserId`).

- [ ] **Step 4: Write `OperationTemplateField_SaveAll/query.sql`**

```sql
-- @operationTemplateId BIGINT
-- @rowsJson            NVARCHAR(MAX)
-- @appUserId           BIGINT
EXEC Parts.OperationTemplateField_SaveAll
    @OperationTemplateId = :operationTemplateId,
    @RowsJson            = :rowsJson,
    @AppUserId           = :appUserId
```

Its `resource.json` is the Step 2 shape with `parameters` `operationTemplateId`(3) / `rowsJson`(7) / `appUserId`(3).

- [ ] **Step 5: Scan + commit**

Run: `.\scan.ps1`
Expected: HTTP 200, scan accepted. In Designer (or gateway log) the three NQs load without `version: 1` NPE.

```bash
git add ignition/projects/MPP_Config/ignition/named-query/parts/ToolAttribute_SaveAll/ ignition/projects/MPP_Config/ignition/named-query/parts/ToolCavity_SaveAll/ ignition/projects/MPP_Config/ignition/named-query/parts/OperationTemplateField_SaveAll/
git commit -m "feat(tools-nq): SaveAll named queries for ToolAttribute, ToolCavity, OperationTemplateField"
```

---

## Phase C — Entity scripts

### Task C1: `BlueRidge.Parts.Tool` — saveAttributesAll, saveCavitiesAll, typed definition options

**Files:**
- Modify: `…/script-python/BlueRidge/Parts/Tool/code.py`

Keep all existing functions (per-row `upsertAttribute`/`removeAttribute`/`createCavity`/`updateCavityStatus`/`deprecateCavity` stay defined; they're simply no longer called from the rewritten UI — leave them as the documented non-UI surface). Add three functions.

- [ ] **Step 1: Add `getAttributeDefinitionOptions` (typed) near `getAttributeDefinitionsForToolType`**

```python
def getAttributeDefinitionOptions(toolId):
    """Available + already-present attribute definitions for a tool, each
    carrying its DataType so the row can pick a type-aware value input.

    Returns list[dict]: {value: <defId>, label: <name>, code, dataType}.
    The Attributes editor uses this to (a) populate the new-row Definition
    dropdown (filtering out defs already on the tool happens in the view)
    and (b) resolve DataType for existing rows."""
    toolId = _u(toolId)
    BlueRidge.Common.Util.log("toolId=%s" % toolId)
    if toolId is None:
        return []
    toolTypeId = None
    row = BlueRidge.Common.Db.execOne("parts/Tool_Get", {"id": toolId})
    if row is not None:
        toolTypeId = row.get("ToolTypeId")
    if toolTypeId is None:
        return []
    try:
        rows = BlueRidge.Common.Db.execList(
            "parts/ToolAttributeDefinition_ListByType",
            {"toolTypeId": toolTypeId, "includeDeprecated": 0},
        )
    except Exception as e:
        BlueRidge.Common.Util.log("getAttributeDefinitionOptions failed: %s" % str(e))
        return []
    return [{"value": r.get("Id"),
             "label": r.get("Name") or r.get("Code"),
             "code":  r.get("Code"),
             "dataType": r.get("DataType")} for r in rows or []]
```

> Note: `Tool_Get` must return `ToolTypeId`. If it does not, resolve the tool type via `parts/Tool_List` filtered by id, or extend the read proc — verify the column is present before relying on it.

- [ ] **Step 2: Add `saveAttributesAll` in the per-tab mutations section**

```python
def saveAttributesAll(toolId, rows):
    """Bundled SaveAll for the Attributes section. `rows` is the editDraft
    rows list with keys: id (BIGINT|None), toolAttributeDefinitionId (BIGINT),
    value (string). Returns {Status, Message, NewId}."""
    toolId = _u(toolId)
    BlueRidge.Common.Util.log("toolId=%s rows=%d" % (toolId, len(rows or [])))
    if toolId is None:
        return {"Status": 0, "Message": "No tool selected.", "NewId": None}
    cleaned = []
    for r in (rows or []):
        r = _u(r) or {}
        v = r.get("value")
        cleaned.append({
            "Id":                        r.get("id"),
            "ToolAttributeDefinitionId": r.get("toolAttributeDefinitionId"),
            "Value":                     u"" if v is None else unicode(v),
        })
    return BlueRidge.Common.Db.execMutation(
        "parts/ToolAttribute_SaveAll",
        {
            "toolId":    toolId,
            "rowsJson":  BlueRidge.Common.Util.convertWrapperObjectToJson(cleaned),
            "appUserId": BlueRidge.Common.Util._currentAppUserId(),
        },
    )
```

- [ ] **Step 3: Add `saveCavitiesAll` in the same section**

```python
def saveCavitiesAll(toolId, rows):
    """Bundled SaveAll for the Cavities section. `rows` keys: id (BIGINT|None),
    cavityNumber (int), description (string|None), statusCode (str).
    Returns {Status, Message, NewId}."""
    toolId = _u(toolId)
    BlueRidge.Common.Util.log("toolId=%s rows=%d" % (toolId, len(rows or [])))
    if toolId is None:
        return {"Status": 0, "Message": "No tool selected.", "NewId": None}
    cleaned = []
    for r in (rows or []):
        r = _u(r) or {}
        num = r.get("cavityNumber")
        cleaned.append({
            "Id":           r.get("id"),
            "CavityNumber": None if num is None else int(num),
            "Description":  r.get("description"),
            "StatusCode":   r.get("statusCode") or "Active",
        })
    return BlueRidge.Common.Db.execMutation(
        "parts/ToolCavity_SaveAll",
        {
            "toolId":    toolId,
            "rowsJson":  BlueRidge.Common.Util.convertWrapperObjectToJson(cleaned),
            "appUserId": BlueRidge.Common.Util._currentAppUserId(),
        },
    )
```

- [ ] **Step 4: Scan + commit**

Run: `.\scan.ps1`

```bash
git add ignition/projects/MPP_Config/ignition/script-python/BlueRidge/Parts/Tool/
git commit -m "feat(tools-script): Tool.saveAttributesAll / saveCavitiesAll + typed attribute-definition options"
```

### Task C2: `BlueRidge.Parts.OperationTemplate` — saveFieldsAll

**Files:**
- Modify: `…/script-python/BlueRidge/Parts/OperationTemplate/code.py`

Keep `addField`/`removeField`/`setFieldRequired` defined (non-UI surface). `getAvailableDataCollectionFields` already exists. Add `saveFieldsAll`.

- [ ] **Step 1: Add `saveFieldsAll` in the Mutations section**

```python
def saveFieldsAll(operationTemplateId, rows):
    """Bundled SaveAll for the Fields panel. `rows` keys: id (BIGINT|None),
    dataCollectionFieldId (BIGINT), isRequired (bool).
    Returns {Status, Message, NewId}."""
    operationTemplateId = _u(operationTemplateId)
    BlueRidge.Common.Util.log("templateId=%s rows=%d" % (operationTemplateId, len(rows or [])))
    if operationTemplateId is None:
        return {"Status": 0, "Message": "No template selected.", "NewId": None}
    cleaned = []
    for r in (rows or []):
        r = _u(r) or {}
        cleaned.append({
            "Id":                    r.get("id"),
            "DataCollectionFieldId": r.get("dataCollectionFieldId"),
            "IsRequired":            bool(r.get("isRequired")),
        })
    return BlueRidge.Common.Db.execMutation(
        "parts/OperationTemplateField_SaveAll",
        {
            "operationTemplateId": operationTemplateId,
            "rowsJson":            BlueRidge.Common.Util.convertWrapperObjectToJson(cleaned),
            "appUserId":           BlueRidge.Common.Util._currentAppUserId(),
        },
    )
```

- [ ] **Step 2: Scan + commit**

Run: `.\scan.ps1`

```bash
git add ignition/projects/MPP_Config/ignition/script-python/BlueRidge/Parts/OperationTemplate/
git commit -m "feat(optemplate-script): OperationTemplate.saveFieldsAll bundled save"
```

---

## Phase D — Tools → Attributes section (draft editor)

Reference to copy: `BlueRidge/Components/Parts/ItemMaster/Eligibility/view.json` (section) + `…/EligibilityRow/view.json` (row). Both are file-rewritten + scanned (effectively new content). The Attributes section is the **type-aware** screen, so the row carries four value inputs gated by `position.display` on the row's `dataType`.

### Task D1: AttributeRow sub-view (type-aware)

**Files:**
- Rewrite: `…/views/BlueRidge/Components/Parts/Tools/_Tools/AttributeRow/view.json`

Mirror `EligibilityRow` structure. Component tree (root `ia.container.flex`, direction row, `meta.name: "root"`):
- `IndexLabel` (`ia.display.label`) — bound `{view.params.row.rowIndex}` style; basis ~`32px`.
- `DefinitionCell`:
  - `DefinitionDropdown` (`ia.input.dropdown`) — **visible only for NEW rows** (`position.display = "isNull({view.params.row.id})"`), `props.options` bound `{view.params.attributeOptions}`, value bidi `{view.params.row.toolAttributeDefinitionId}`. `onActionPerformed` → page msg `attrRowDefinitionChanged` `{rowIndex, newDefId: self.props.value}`.
  - `DefinitionLabel` (`ia.display.label`) — **visible only for EXISTING rows** (`position.display = "!isNull({view.params.row.id})"`), text `{view.params.row.definitionLabel}`.
- `ValueCell` — four mutually-exclusive inputs, each gated by `position.display`:
  - `ValueText` (`ia.input.text-field`) display `"{view.params.row.dataType} = \"String\""`; bidi `{view.params.row.value}`; `dom.onBlur` → page msg `attrRowValueChanged` `{rowIndex, newValue: self.props.text}`.
  - `ValueNumeric` (`ia.input.numeric-entry-field`) display `"{view.params.row.dataType} = \"Integer\" || {view.params.row.dataType} = \"Decimal\""`; bidi to a local then onChange → `attrRowValueChanged` `{rowIndex, newValue: toStr(self.props.value)}`. (numeric-entry-field stores numbers; coerce to string in the message.)
  - `ValueCheckbox` (`ia.input.checkbox`) display `"{view.params.row.dataType} = \"Boolean\""`; `onActionPerformed` → `attrRowValueChanged` `{rowIndex, newValue: if(self.props.selected, "true", "false")}`.
  - `ValueDate` (`ia.input.date-time-input`, `props.format: "YYYY-MM-DD"`) display `"{view.params.row.dataType} = \"Date\""`; `onActionPerformed`/onChange → `attrRowValueChanged` `{rowIndex, newValue: <formatted YYYY-MM-DD string>}`.
- `RemoveBtn` (`ia.input.button`, label `×`) — `onActionPerformed` (scope `"G"`) → page msg `attrRowRemove` `{rowIndex}`.

`params` block (input-only, fully shaped):
```json
"params": {
  "row": { "rowIndex": 0, "id": null, "toolAttributeDefinitionId": null,
           "definitionLabel": "", "value": "", "dataType": "String" },
  "attributeOptions": []
}
```

- [ ] **Step 1:** Author the view.json mirroring EligibilityRow (copy its `propConfig` binding shapes for the dropdown + text-field; add the three extra value inputs with `position.display` gates). All message sends use `scope: "G"` and `pageScope` handlers on the parent. Indent every event/handler script body with leading `\t`.
- [ ] **Step 2:** `.\scan.ps1`; confirm the view loads with no Component Error in Designer.

### Task D2: Attributes section view rewrite

**Files:**
- Rewrite: `…/views/BlueRidge/Components/Parts/Tools/Attributes/view.json`

Mirror `Eligibility/view.json`. Key elements:

`custom` block (pre-declared, shaped):
```json
"custom": {
  "state": { "selected": { "rows": [] }, "editDraft": { "rows": [] } },
  "isDirty": false,
  "attributeOptions": []
}
```

`params`: `{ "value": null }` (input-only BIGINT toolId).

`propConfig`:
- `custom.attributeOptions` ← `runScript("BlueRidge.Parts.Tool.getAttributeDefinitionOptions", 0, {view.params.value})`.
- `custom.isDirty` ← expr `runScript("BlueRidge.Common.Util.convertWrapperObjectToJson",0,{view.custom.state.editDraft.rows}) != runScript("BlueRidge.Common.Util.convertWrapperObjectToJson",0,{view.custom.state.selected.rows})`, with `onChange` sending page msg `sectionDirtyChanged` `{"section":"attributes","isDirty": bool(currentValue.value)}`.
- `params.value` `onChange` → calls `self.load()`.
- Save button `props.enabled` + Discard `meta.visible` gated on `if(isNull({view.custom.isDirty}),false,{view.custom.isDirty})`.

`root.scripts.customMethods` (mirror Eligibility, attribute-flavoured):
- `load()` — `rows = BlueRidge.Parts.Tool.getAttributeInstancesForTool(self.view.params.value)` → map each `inst["attr"]` into row shape `{id, toolAttributeDefinitionId, definitionLabel, value, dataType}` (DataType comes from the read proc's `DataType`; definitionLabel from `AttrName`). Then atomic write:
  ```python
  loaded = [ ...mapped... ]
  self.view.custom.state = {"selected": {"rows": loaded},
                            "editDraft": {"rows": [dict(r) for r in loaded]}}
  ```
- `handleSave()` — `result = BlueRidge.Parts.Tool.saveAttributesAll(self.view.params.value, self.view.custom.state.editDraft.rows)`; `BlueRidge.Common.Ui.notifyResult(result, successTitle="Attributes saved")`; on `Status` truthy call `self.load()`.
- `handleDiscard()` — reseed editDraft from selected atomically (same single-write rule).
- `addRow()` — append `{id:None, toolAttributeDefinitionId:None, definitionLabel:"", value:"", dataType:"String"}` to editDraft.rows (rewrite whole state).
- `_applyDefinitionChange(idx, newDefId)` — look up option in `attributeOptions`, set row's `toolAttributeDefinitionId`, `definitionLabel`, and **`dataType`** from the option; default `value` to type-appropriate empty (`""`/`"false"`); rewrite state atomically.
- `_applyValueChange(idx, newValue)` — set row.value; rewrite state.
- `_removeRow(idx)` — delete row; rewrite state.

`root.scripts.messageHandlers` (all `pageScope: true`):
- `sectionSaveRequested` → if `payload.section=="attributes"`: `self.handleSave()`.
- `sectionDiscardRequested` → if `=="attributes"`: `self.handleDiscard()`.
- `attrRowDefinitionChanged` → `self._applyDefinitionChange(payload["rowIndex"], payload["newDefId"])`.
- `attrRowValueChanged` → `self._applyValueChange(payload["rowIndex"], payload["newValue"])`.
- `attrRowRemove` → `self._removeRow(payload["rowIndex"])`.

Header row: title `Attributes` + `+ New definition` button (opens KEPT `AddAttributeDefinition` popup, id `mpp-add-attr-def`, scope `"G"`, params `{toolTypeId}` — resolve toolTypeId via a custom prop or the option list) + `Discard` + `Save`. A `RowsRepeater` (`ia.display.flex-repeater`, path `BlueRidge/Components/Parts/Tools/_Tools/AttributeRow`) whose `instances` is a property+script-transform over `view.custom.state.editDraft.rows` emitting `{"row": {rowIndex:i, ...r}, "attributeOptions": opts}` per element. `+ Add` button → `self.getChild(...).addRow()` (or a root custom method invoked from the button).

- [ ] **Step 1:** Author the view.json. Copy Eligibility's exact `isDirty` expression, Save/Discard binding shapes, repeater `instances` transform, and the `load()`/`handle*`/`_apply*` method bodies; swap entity calls + field names per above. Leading-`\t` on every script body.
- [ ] **Step 2:** `.\scan.ps1`.
- [ ] **Step 3: Commit** (D1 + D2 together)

```bash
git add ignition/projects/MPP_Config/com.inductiveautomation.perspective/views/BlueRidge/Components/Parts/Tools/Attributes/ ignition/projects/MPP_Config/com.inductiveautomation.perspective/views/BlueRidge/Components/Parts/Tools/_Tools/AttributeRow/
git commit -m "feat(tools-ui): Attributes section inline-draft editor with type-aware value inputs"
```

> Parent-wiring + smoke (the section embed receives `params.value`, dirty gating) lands in Phase H; sections are authored first, then wired.

---

## Phase E — Tools → Cavities section (draft editor)

Mirror Phase D. Differences captured below; everything else (state shape, isDirty, Save/Discard, message-handler pattern, atomic writes) is identical with `"section":"cavities"`.

### Task E1: CavityRow sub-view

**Files:**
- Rewrite: `…/views/BlueRidge/Components/Parts/Tools/_Tools/CavityRow/view.json`

Columns `# | Number | Description | Status | ×`. Row params: `{ "row": {rowIndex:0, id:null, cavityNumber:null, description:"", statusCode:"Active", isScrappedSaved:false} }`.
- `NumberCell`: `NumberInput` (`ia.input.numeric-entry-field`) bidi `{view.params.row.cavityNumber}`, **visible for NEW rows only** (`position.display="isNull({view.params.row.id})"`), onChange → `cavityRowNumberChanged` `{rowIndex,newNumber}`; `NumberLabel` for existing rows (read-only, immutable).
- `DescInput` (`ia.input.text-field`) bidi `{view.params.row.description}`; `dom.onBlur` → `cavityRowDescChanged` `{rowIndex, newDesc: self.props.text}`. Disabled when `{view.params.row.isScrappedSaved}` true.
- `StatusDropdown` (`ia.input.dropdown`) options `[{label:"Active",value:"Active"},{label:"Closed",value:"Closed"},{label:"Scrapped",value:"Scrapped"}]` (static), value bidi `{view.params.row.statusCode}`; `onActionPerformed` → `cavityRowStatusChanged` `{rowIndex, newStatus: self.props.value}`. **Disabled** when `{view.params.row.isScrappedSaved}` (locked).
- `RemoveBtn` (`×`) **visible only for unsaved NEW rows** (`position.display="isNull({view.params.row.id})"`) → `cavityRowRemove` `{rowIndex}`. Saved cavities have no delete (end-of-life via Scrapped).

### Task E2: Cavities section view rewrite

**Files:**
- Rewrite: `…/views/BlueRidge/Components/Parts/Tools/Cavities/view.json`

`load()` maps `getCavityInstancesForTool` rows (`Id, Number, StatusCode, Description`) → `{id, cavityNumber, description, statusCode, isScrappedSaved: (StatusCode=="Scrapped")}`. `addRow()` appends `{id:None, cavityNumber:None, description:"", statusCode:"Active", isScrappedSaved:False}`. `handleSave()` → `BlueRidge.Parts.Tool.saveCavitiesAll(...)`, notify, reload. Custom methods `_applyNumberChange`/`_applyDescChange`/`_applyStatusChange`/`_removeRow`. Message handlers `cavityRow*` + `sectionSaveRequested`/`sectionDiscardRequested` gated on `"section":"cavities"`. No `+ New definition` button (cavities have no definition table); just `+ Add cavity`, Discard, Save.

- [ ] **Step 1:** Author both view.json files (E1, E2) mirroring Phase D + Eligibility.
- [ ] **Step 2:** `.\scan.ps1`.
- [ ] **Step 3: Commit**

```bash
git add ignition/projects/MPP_Config/com.inductiveautomation.perspective/views/BlueRidge/Components/Parts/Tools/Cavities/ ignition/projects/MPP_Config/com.inductiveautomation.perspective/views/BlueRidge/Components/Parts/Tools/_Tools/CavityRow/
git commit -m "feat(tools-ui): Cavities section inline-draft editor (status dropdown, Scrapped-lock, number immutable)"
```

---

## Phase F — Tools → Assignments (non-draft inline mount)

Assignments is **NOT** a draft editor (D3). It adopts the eligibility chrome (column headers, row layout) but performs immediate audited mount/release. It never raises `sectionDirty` and never blocks navigation.

### Task F1: AssignmentRow sub-view (read-only history)

**Files:**
- Rewrite: `…/views/BlueRidge/Components/Parts/Tools/_Tools/AssignmentRow/view.json`

Read-only display row (no editing). Columns: `Cell | Assigned | Released/Active | By | Notes`. Params `{ "assignment": {Id, CellName, AssignedAt, ReleasedAt, AssignedByInitials, ReleasedByInitials, Notes, IsActive} }`. An "Active" badge when `{view.params.assignment.IsActive}`. No events.

### Task F2: Assignments section rewrite (inline mount zone)

**Files:**
- Rewrite: `…/views/BlueRidge/Components/Parts/Tools/Assignments/view.json`

`custom`: `{ "active": null, "rows": [], "cellOptions": [], "selectedCellId": null, "mountNotes": "" }` (all pre-declared, shaped: `rows`=`[]`, `active`=`null`, `cellOptions`=`[]`). `params`: `{ "value": null }`.

`propConfig`:
- `custom.rows` ← `runScript("BlueRidge.Parts.Tool.getAssignmentInstancesForTool",0,{view.params.value})`.
- `custom.active` ← `runScript("BlueRidge.Parts.Tool.getActiveAssignmentForTool",0,{view.params.value})` (entity returns `None`; for the binding, prefer adding `getActiveAssignmentForToolOrEmpty` returning a shaped empty dict per the pre-declare-bound-props rule, OR bind only primitive sub-reads guarded by `isNull`). **Author a `getActiveAssignmentForToolOrEmpty` helper** in `Tool/code.py` returning `{"Id":None,"CellName":"","AssignedAt":None,"AssignedByInitials":"","Notes":"","IsActive":False}` when no active mount, and bind `custom.active` to it to avoid nested-null Component Errors.
- `custom.cellOptions` ← `runScript("BlueRidge.Parts.Tool.getCellsForDropdown",0,{view.params.value})`.
- `params.value` `onChange` → `self.refresh()` (re-reads rows/active/cellOptions by reassigning each custom prop directly, since `refreshBinding` no-ops in handlers — use `self.view.custom.rows = BlueRidge.Parts.Tool.getAssignmentInstancesForTool(...)` etc.).

Layout:
- **Active-mount banner** (`position.display = "!isNull({view.custom.active.Id})"`): "Mounted on {active.CellName} — {active.AssignedAt} by {active.AssignedByInitials}" + **Release** button → `BlueRidge.Parts.Tool.releaseAssignment(self.view.params.value)`, notify, `self.refresh()`. (Optionally route through the existing `ConfirmDestructive` popup first, matching the current release UX.)
- **Inline mount zone** (`position.display = "isNull({view.custom.active.Id})"`): `CellDropdown` options `{view.custom.cellOptions}` value bidi `{view.custom.selectedCellId}`; optional `NotesField` bidi `{view.custom.mountNotes}`; **Mount** button (enabled when `!isNull({view.custom.selectedCellId})`) → `BlueRidge.Parts.Tool.assignToCell(self.view.params.value, self.view.custom.selectedCellId, self.view.custom.mountNotes)`, notify, clear selectedCellId/mountNotes, `self.refresh()`.
- **History table**: `RowsRepeater` over `view.custom.rows`, path `…/_Tools/AssignmentRow`, instance `{"assignment": r["assignment"]}`.

- [ ] **Step 1:** Add `getActiveAssignmentForToolOrEmpty` to `Tool/code.py`:
```python
def getActiveAssignmentForToolOrEmpty(toolId):
    """Binding-safe variant of getActiveAssignmentForTool: returns a fully
    shaped dict (never None) so nested-path bindings never Component-Error."""
    row = getActiveAssignmentForTool(toolId)
    if row is None:
        return {"Id": None, "CellName": "", "AssignedAt": None,
                "AssignedByInitials": "", "ReleasedByInitials": "",
                "Notes": "", "ReleasedAt": None, "IsActive": False}
    return row
```
- [ ] **Step 2:** Author both view.json files (F1, F2).
- [ ] **Step 3:** `.\scan.ps1`.
- [ ] **Step 4: Commit**

```bash
git add ignition/projects/MPP_Config/com.inductiveautomation.perspective/views/BlueRidge/Components/Parts/Tools/Assignments/ ignition/projects/MPP_Config/com.inductiveautomation.perspective/views/BlueRidge/Components/Parts/Tools/_Tools/AssignmentRow/ ignition/projects/MPP_Config/ignition/script-python/BlueRidge/Parts/Tool/
git commit -m "feat(tools-ui): Assignments inline mount/release (no draft) + binding-safe active helper"
```

---

## Phase G — Operation Templates → Fields panel (draft editor)

### Task G1: FieldRow sub-view rewrite

**Files:**
- Rewrite: `…/views/BlueRidge/Components/Parts/OperationTemplates/_OperationTemplates/FieldRow/view.json`

Columns `# | Code | Name | Required | ×`. Params `{ "row": {rowIndex:0, id:null, dataCollectionFieldId:null, code:"", name:"", isRequired:true}, "fieldOptions": [] }`.
- New row: `FieldDropdown` (visible when `isNull({view.params.row.id})`) options `{view.params.fieldOptions}`, value bidi `{view.params.row.dataCollectionFieldId}`, `onActionPerformed` → `fieldRowFieldChanged` `{rowIndex, newFieldId}`.
- Existing row: `CodeLabel` + `NameLabel` read-only (`!isNull(id)`).
- `RequiredCheckbox` bidi `{view.params.row.isRequired}` → `onActionPerformed` → `fieldRowRequiredChanged` `{rowIndex, isRequired: self.props.selected}`.
- `RemoveBtn` (`×`) → `fieldRowRemove` `{rowIndex}`.

### Task G2: Fields panel within OperationTemplates view → draft model

**Files:**
- Modify (Designer): `…/views/BlueRidge/Views/Parts/OperationTemplates/view.json`

This is a **parent view** (the Fields panel lives inside the OperationTemplates detail, not a standalone embed). Edit in **Designer** per the view-edit boundary. Replace the dropdown+button-add + per-row immediate mutations with a `state.editDraft.fields` draft section that mirrors Eligibility, scoped to the panel:
- Add `view.custom.fieldsState = {selected:{rows:[]}, editDraft:{rows:[]}}`, `view.custom.fieldsDirty`, `view.custom.fieldOptions` (pre-declared shaped).
- `loadFields()` custom method maps `BlueRidge.Parts.OperationTemplate.getFieldsForTemplate(selectedTemplateId)` rows (`Id, Code, Name, IsRequired`) → `{id, dataCollectionFieldId:None-for-existing?...}`. NOTE: the read proc returns `Id` (junction id), `Code`, `Name`, `IsRequired` but NOT `DataCollectionFieldId`. **Extend** the read path: either add `DataCollectionFieldId` to `OperationTemplateField_ListByTemplate` proc output, or have `getFieldsForTemplate` include it. Add `DataCollectionFieldId` so SaveAll update rows can carry it. (Verify `OperationTemplateField_ListByTemplate` selects it; if not, add the column to that read proc — a one-line SELECT add — and re-scan.)
- `+ Add field` appends `{id:None, dataCollectionFieldId:None, code:"", name:"", isRequired:True}`.
- `Save fields` → `BlueRidge.Parts.OperationTemplate.saveFieldsAll(selectedTemplateId, fieldsState.editDraft.rows)`, notify, reload.
- `fieldsDirty` folds into the existing template/version-switch ConfirmUnsaved gate (Phase H detail).

- [ ] **Step 1:** Verify/extend `OperationTemplateField_ListByTemplate` to emit `DataCollectionFieldId`; if changed, re-run `.\Reset-DevDatabase.ps1` (no new test needed — column add) and `.\scan.ps1`.
- [ ] **Step 2:** Author FieldRow (G1, file-edit + scan).
- [ ] **Step 3:** In Designer, convert the Fields panel to the draft model (G2). Save in Designer; do NOT file-edit the parent view.json.
- [ ] **Step 4:** `.\scan.ps1` (for FieldRow + any read-proc NQ); commit.

```bash
git add ignition/projects/MPP_Config/com.inductiveautomation.perspective/views/BlueRidge/Components/Parts/OperationTemplates/_OperationTemplates/FieldRow/ ignition/projects/MPP_Config/com.inductiveautomation.perspective/views/BlueRidge/Views/Parts/OperationTemplates/view.json
git commit -m "feat(optemplate-ui): Fields panel inline-draft editor with Save/Discard"
```

---

## Phase H — Parent wiring + dirty gating (Designer)

### Task H1: Tools parent — sectionDirty map + tab/tool-switch gating

**Files:**
- Modify (Designer): `…/views/BlueRidge/Views/Parts/Tools/view.json`

Mirror the Item Master parent (`ItemMaster/view.json`) per `project_mpp_item_master_pattern`:
- Add `view.custom.sectionDirty` (dict, default `{}`) and `view.custom.pendingSwitch` (default `null`).
- The three section embeds already receive `params.value`. Confirm each receives `view.custom.editDraft.meta.Id` (the selected tool id) input-only.
- Add `root.scripts.messageHandlers.sectionDirtyChanged` (pageScope) → `self.view.custom.sectionDirty[payload["section"]] = payload["isDirty"]` (rewrite the whole dict so the binding re-evaluates).
- Gate the **tab strip** and **tool-list-row click** (`toolRowClicked`) on `any(sectionDirty.values())`: if dirty, stage `pendingSwitch` and open `ConfirmUnsaved`; on `confirmUnsavedResult` save → page msg `sectionSaveRequested {section}` for each dirty section, discard → `sectionDiscardRequested {section}`, then complete the staged switch; cancel → drop `pendingSwitch`.
- Assignments is non-draft: it never sends `sectionDirtyChanged`, so its tab/section never participates in gating.

- [ ] **Step 1:** Implement in Designer mirroring `ItemMaster/view.json`'s `openConfirmUnsaved`/`completeSwitch`/`cancelSwitch` + `sectionDirtyChanged`/`confirmUnsavedResult` handlers (use `self.X()` addressing in `root.scripts`, per `feedback_ignition_view_customMethods_scope`).
- [ ] **Step 2:** Save in Designer; `.\scan.ps1`.

### Task H2: OperationTemplates parent — fold Fields dirty into existing gate

**Files:**
- Modify (Designer): `…/views/BlueRidge/Views/Parts/OperationTemplates/view.json`

The view already gates template/version switching on metadata-dirty. Extend the dirty predicate to `metadataDirty OR fieldsDirty`. On the ConfirmUnsaved "Save" path, save BOTH metadata (`update`) and fields (`saveFieldsAll`) before completing the switch.

- [ ] **Step 1:** In Designer, OR-in `view.custom.fieldsDirty` to the existing dirty expression; extend the save-then-switch handler to also call `saveFieldsAll`.
- [ ] **Step 2:** Save in Designer; `.\scan.ps1`; commit.

```bash
git add ignition/projects/MPP_Config/com.inductiveautomation.perspective/views/BlueRidge/Views/Parts/Tools/view.json ignition/projects/MPP_Config/com.inductiveautomation.perspective/views/BlueRidge/Views/Parts/OperationTemplates/view.json
git commit -m "feat(config-ui): parent dirty-gating for Tools sections + OperationTemplates Fields"
```

### Task H3: End-to-end Designer smoke (manual)

- [ ] Open a Perspective session. For **Tools → Attributes**: edit a value → `●` dirty appears, Save/Discard show; Save persists + clears dirty + toasts; Discard reverts; add a row picks a Definition and the value input matches its DataType (String text / Integer numeric / Boolean checkbox / Date picker); remove a row hard-deletes on Save; switching tools while dirty triggers `ConfirmUnsaved`.
- [ ] **Cavities**: add cavity (Active), set status via dropdown, save; saved-Scrapped row is locked (read-only, dimmed); number is read-only on existing rows; empty save does NOT delete cavities.
- [ ] **Assignments**: inline cell dropdown (compatible cells only); Mount mounts immediately + toasts + history updates + banner shows; Release works; NO dirty gating from this tab; MountToCell popup never opens.
- [ ] **Operation Templates → Fields**: add field via dropdown, toggle Required, remove, Save persists; switching template/version while Fields dirty triggers ConfirmUnsaved.
- [ ] `/audit`: confirm `Audit.ConfigLog` rows for each save carry the `<SUBJECT> · <Category> · <Action>` narrative + resolved-FK Old/New JSON.

---

## Phase I — Retire popups + final verification

### Task I1: Delete retired popups

**Files (delete entire folders):**
- `…/views/BlueRidge/Components/Popups/MountToCell/`
- `…/views/BlueRidge/Components/Popups/AddAttribute/`
- `…/views/BlueRidge/Components/Popups/AddCavity/`

Keep `…/Popups/AddAttributeDefinition/`.

- [ ] **Step 1:** Before deleting, grep the project for any remaining `openPopup` references to `mpp-mount-to-cell`, `mpp-add-attribute`, `mpp-add-cavity` and the view paths; the section rewrites (Phases D/E/F) should have removed them all. Fix any stragglers first.
```
Grep: "MountToCell|AddAttribute/|AddCavity|mpp-mount-to-cell|mpp-add-attribute|mpp-add-cavity" under views/
```
- [ ] **Step 2:** Delete the three folders. `.\scan.ps1`.
- [ ] **Step 3:** Confirm in Designer no dangling references / broken popups; the AddAttributeDefinition popup still opens from the Attributes header.
- [ ] **Step 4: Commit**

```bash
git rm -r "ignition/projects/MPP_Config/com.inductiveautomation.perspective/views/BlueRidge/Components/Popups/MountToCell" "ignition/projects/MPP_Config/com.inductiveautomation.perspective/views/BlueRidge/Components/Popups/AddAttribute" "ignition/projects/MPP_Config/com.inductiveautomation.perspective/views/BlueRidge/Components/Popups/AddCavity"
git commit -m "chore(tools-ui): retire MountToCell/AddAttribute/AddCavity popups (replaced by inline editing)"
```

### Task I2: Final verification + status update

- [ ] **Step 1:** `.\Reset-DevDatabase.ps1` — full SQL suite green (baseline 1165 + new assertions, no FAILs).
- [ ] **Step 2:** `.\scan.ps1` — clean scan.
- [ ] **Step 3:** Re-run the Phase H3 smoke checklist once more end-to-end on a clean session.
- [ ] **Step 4:** Update `PROJECT_STATUS.md` (Last-updated + Recently closed) and `MPP_MES_DATA_MODEL.md` only if a read-proc column was added in G2 (no schema change otherwise — D4 means no `SortOrder`). Commit docs separately.

```bash
git add PROJECT_STATUS.md
git commit -m "docs(status): eligibility-style config editors landed"
```

---

## Self-Review (performed against the spec)

- **D1 full eligibility model** → Phases D, E, G (draft sections); §3 reference pattern encoded in the Conventions + each section's `load`/`handle*`/`_apply*` + atomic-state rule. ✔
- **D2 cavity status inline dropdown, SaveAll insert+update only, Scrapped-lock, reversible-before-save** → Task A3 proc (no deprecate-on-absent; immutable number; Scrapped lock) + Task A4 tests (un-scrap rejected, empty-save keeps rows) + Phase E UI (dropdown + dimmed lock). ✔
- **D3 Assignments non-draft inline mount** → Phase F; immediate `assignToCell`/`releaseAssignment`, no `sectionDirty`, MountToCell popup deleted (I1), `Tool_ListCompatibleCells` reused via existing `getCellsForDropdown`. ✔
- **D4 no field ordering** → no `SortOrder`; proc reconciles by Id/DCF only; no schema change. ✔
- **D5 type-aware attribute value** → Task A1 per-DataType validation + Phase D row's four `position.display`-gated inputs + canonical string storage; `getAttributeDefinitionOptions` carries `dataType`. ✔
- **§6 SQL: three procs, status row, audit on success/failure, JSON_QUERY-wrapped resolved FK, reused SaveAll pattern, NQ version2/type Query/sqlType 3+7** → Phase A + B. ✔ (Audit codes `ToolAttribute`/`ToolCavity`/`OpTemplateField` confirmed pre-seeded — no new LogEntityType.)
- **§7 file inventory** → File Structure section matches; NQs under `parts/` group (entity scripts call `parts/…`); sub-views rewritten + parents in Designer; AddAttributeDefinition kept. ✔
- **§9 testing** → SQL proc tests per proc (reconcile + reject paths + immutability/lock + audit prefix); UI smoke H3; non-destructive apply via `Reset-DevDatabase.ps1` + `scan.ps1`. ✔
- **§10 risks** → view-edit boundary (new/rewritten sub-views file+scan; parents in Designer) called out in Conventions + Phases G2/H; cavity divergence flagged in A3; atomic-state rule normative; bound-prop shaping enforced (Assignments `getActiveAssignmentForToolOrEmpty`, pre-declared customs). ✔

**Open items the implementer must verify during execution (flagged, not gaps):**
1. `Tool_Get` returns `ToolTypeId` (Task C1 Step 1 note) — confirm or resolve type another way.
2. `OperationTemplateField_ListByTemplate` returns `DataCollectionFieldId` (Task G2 Step 1) — add the column to the read proc if absent so SaveAll update-rows carry it.
3. The exact `ConfirmUnsaved` reply-message contract + `sectionSaveRequested`/`sectionDiscardRequested` names — copy verbatim from `ItemMaster/view.json` (don't invent).
