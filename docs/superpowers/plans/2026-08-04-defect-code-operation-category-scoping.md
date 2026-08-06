# Defect codes scoped by OperationCategory — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace `Quality.DefectCode`'s single physical-Area FK with a nullable `OperationCategoryId` (DieCast / Trim / MachiningAssembly; NULL = plant-wide), so a die-cast code shows at every die-cast terminal and non-process codes apply everywhere.

**Architecture:** `Parts.OperationCategory` already exists (migration 0032) with the three rows we need, and every `Parts.OperationType` maps to one. We add `OperationCategoryId` to `Quality.DefectCode`, backfill from `AreaLocationId`, drop `AreaLocationId`, and update the four CRUD procs + their NQs + the seed + the Core entity script. The plant-floor reject dropdown resolves its terminal's `OperationTypeCode` → category in SQL. Existing views are updated in Designer (file edits to existing `view.json` are unreliable here).

**Tech Stack:** SQL Server 2022 (versioned + repeatable migrations, `sqlcmd` test harness under `sql/tests/`), Ignition 8.3 Named Queries, Jython project scripts, Perspective `view.json`.

**Spec:** `docs/superpowers/specs/2026-08-04-defect-code-operation-category-scoping-design.md`

## Global Constraints

- SQL: `UpperCamelCase` tables/columns; `BIGINT` FKs; `NVARCHAR`; `DATETIME2(3)`; enum/status columns FK-backed. UTC stored, ET displayed.
- Procs obey FDS-11-011: no `OUTPUT` params; mutation procs end every exit path with `SELECT @Status AS Status, @Message AS Message[, @NewId AS NewId]`; one result set per proc; `RAISERROR` (not `THROW`) in CATCH.
- Audit writers emit no result set. Description shape `<SUBJECT> · <CATEGORY?> · <ACTION>` via `Audit.ufn_MidDot()`, capped by `Audit.ufn_TruncateActivity()`, with resolved-name FK sub-objects in `OldValue`/`NewValue` JSON.
- Seed strings ASCII-only. Explicit `git add <paths>` only (never `-A`/`-u`). Commit to `jacques/working`. No `Co-Authored-By` trailer.
- No business logic in Python: the OperationType→OperationCategory resolution lives in SQL (`DefectCode_List`), not the entity script.
- After any Ignition resource change: `.\scan.ps1`.
- Test DB for destructive validation is a throwaway `MPP_MES_Test`; do not destructively reset `MPP_MES_Dev`.

---

### Task 1: Schema migration `0047` — add `OperationCategoryId`, backfill, drop `AreaLocationId`

**Files:**
- Create: `sql/migrations/versioned/0047_defect_code_operation_category.sql`

**Interfaces:**
- Produces: `Quality.DefectCode.OperationCategoryId BIGINT NULL` (FK → `Parts.OperationCategory(Id)`), index `IX_DefectCode_OperationCategoryId`. Column `AreaLocationId` and index `IX_DefectCode_AreaLocationId` removed.

- [ ] **Step 1: Write the migration file**

```sql
-- ============================================================
-- Migration:   0047_defect_code_operation_category.sql
-- Author:      Blue Ridge Automation
-- Date:        2026-08-04
-- Description: Scope defect codes by process, not physical Area.
--              1. Add Quality.DefectCode.OperationCategoryId (nullable FK ->
--                 Parts.OperationCategory) + index.
--              2. Backfill from AreaLocationId by process family:
--                 DC1-4 -> DieCast, TRIM1/2 -> Trim, MA1/2 -> MachiningAssembly,
--                 site/other -> NULL (plant-wide). No-op on a fresh reset where
--                 DefectCode is empty (seed 030 runs later and inserts categories
--                 directly); matters only on an in-place upgrade.
--              3. Drop AreaLocationId (FK resolved dynamically + index + column).
--              NULL OperationCategoryId = plant-wide (applies everywhere).
--              Idempotent-guarded; no explicit transaction (repo convention).
-- ============================================================

IF EXISTS (SELECT 1 FROM dbo.SchemaVersion WHERE MigrationId = N'0047_defect_code_operation_category')
BEGIN
    PRINT 'Migration 0047 already applied -- skipping.';
    RETURN;
END
GO

-- 1. Add nullable OperationCategoryId + FK
IF COL_LENGTH(N'Quality.DefectCode', N'OperationCategoryId') IS NULL
    ALTER TABLE Quality.DefectCode ADD OperationCategoryId BIGINT NULL
        CONSTRAINT FK_DefectCode_OperationCategory REFERENCES Parts.OperationCategory(Id);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_DefectCode_OperationCategoryId')
    CREATE INDEX IX_DefectCode_OperationCategoryId ON Quality.DefectCode (OperationCategoryId);
GO

-- 2. Backfill from AreaLocationId (only if the old column still exists -- guards re-run)
IF COL_LENGTH(N'Quality.DefectCode', N'AreaLocationId') IS NOT NULL
BEGIN
    DECLARE @DieCast BIGINT = (SELECT Id FROM Parts.OperationCategory WHERE Code = N'DieCast');
    DECLARE @Trim    BIGINT = (SELECT Id FROM Parts.OperationCategory WHERE Code = N'Trim');
    DECLARE @MachAsm BIGINT = (SELECT Id FROM Parts.OperationCategory WHERE Code = N'MachiningAssembly');

    UPDATE dc
    SET OperationCategoryId =
        CASE
            WHEN loc.Code LIKE N'DC%'   THEN @DieCast
            WHEN loc.Code LIKE N'TRIM%' THEN @Trim
            WHEN loc.Code LIKE N'MA%'   THEN @MachAsm
            ELSE NULL   -- MPP-MAD / site-level / logistics -> plant-wide
        END
    FROM Quality.DefectCode dc
    LEFT JOIN Location.Location loc ON dc.AreaLocationId = loc.Id
    WHERE dc.OperationCategoryId IS NULL;
END
GO

-- 3. Drop AreaLocationId: FK (name resolved dynamically), index, column
DECLARE @fk SYSNAME = (
    SELECT fk.name FROM sys.foreign_keys fk
    INNER JOIN sys.foreign_key_columns fkc ON fkc.constraint_object_id = fk.object_id
    INNER JOIN sys.columns c ON c.object_id = fkc.parent_object_id AND c.column_id = fkc.parent_column_id
    WHERE fk.parent_object_id = OBJECT_ID(N'Quality.DefectCode') AND c.name = N'AreaLocationId');
IF @fk IS NOT NULL EXEC(N'ALTER TABLE Quality.DefectCode DROP CONSTRAINT ' + @fk);
GO

IF EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_DefectCode_AreaLocationId')
    DROP INDEX IX_DefectCode_AreaLocationId ON Quality.DefectCode;
GO

IF COL_LENGTH(N'Quality.DefectCode', N'AreaLocationId') IS NOT NULL
    ALTER TABLE Quality.DefectCode DROP COLUMN AreaLocationId;
GO

INSERT INTO dbo.SchemaVersion (MigrationId, Description)
VALUES (N'0047_defect_code_operation_category',
    N'Defect codes scoped by OperationCategory: add DefectCode.OperationCategoryId (nullable FK, plant-wide=NULL) + index, backfill from AreaLocationId by process family, drop AreaLocationId (FK + index + column).');
GO

PRINT 'Migration 0047 (defect_code_operation_category) applied.';
GO
```

- [ ] **Step 2: Apply on a throwaway test DB and verify the column swap**

Run (PowerShell, adjust the runner to the repo's reset script — the same one `sql_version_control_guide.md` documents):
```bash
# Reset MPP_MES_Test through migrations only, then inspect the column set.
sqlcmd -S localhost -d MPP_MES_Test -Q "SELECT COL_LENGTH('Quality.DefectCode','OperationCategoryId') AS HasCat, COL_LENGTH('Quality.DefectCode','AreaLocationId') AS HasArea;"
```
Expected: `HasCat` non-NULL, `HasArea` NULL.

- [ ] **Step 3: Commit**

```bash
git add sql/migrations/versioned/0047_defect_code_operation_category.sql
git commit -m "feat(quality): migration 0047 — DefectCode.OperationCategoryId replaces AreaLocationId"
```

---

### Task 2: `DefectCode_Create` + `DefectCode_Update` procs — category param + Category audit JSON

**Files:**
- Modify: `sql/migrations/repeatable/R__Quality_DefectCode_Create.sql`
- Modify: `sql/migrations/repeatable/R__Quality_DefectCode_Update.sql`

**Interfaces:**
- Produces: `Quality.DefectCode_Create @Code, @Description, @OperationCategoryId BIGINT = NULL, @IsExcused BIT = 0, @AppUserId` → `Status, Message, NewId`. `Quality.DefectCode_Update @Id, @Description, @OperationCategoryId BIGINT = NULL, @IsExcused, @AppUserId` → `Status, Message`. Audit `OldValue`/`NewValue` JSON carry a `Category` sub-object (`{Id, Code, Name}`) or `null` for plant-wide.

- [ ] **Step 1: Rewrite `R__Quality_DefectCode_Create.sql`**

Replace the whole `CREATE OR ALTER` body with:

```sql
-- =============================================
-- Procedure:   Quality.DefectCode_Create
-- Version:     3.0
-- Change Log:
--   2026-08-04 - 3.0 - Scope by Parts.OperationCategory (nullable = plant-wide)
--                       instead of AreaLocationId. Audit JSON carries a Category
--                       sub-object; NULL renders as "Plant-wide".
-- =============================================
CREATE OR ALTER PROCEDURE Quality.DefectCode_Create
    @Code                NVARCHAR(20),
    @Description         NVARCHAR(500),
    @OperationCategoryId BIGINT          = NULL,
    @IsExcused           BIT             = 0,
    @AppUserId           BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Status  BIT           = 0;
    DECLARE @Message NVARCHAR(500) = N'Unknown error';
    DECLARE @NewId   BIGINT        = NULL;

    DECLARE @ProcName NVARCHAR(200) = N'Quality.DefectCode_Create';
    DECLARE @Params   NVARCHAR(MAX) =
        (SELECT @Code AS Code, @Description AS Description,
                @OperationCategoryId AS OperationCategoryId, @IsExcused AS IsExcused
         FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

    BEGIN TRY
        -- Required params (OperationCategoryId is OPTIONAL: NULL = plant-wide)
        IF @Code IS NULL OR LTRIM(RTRIM(@Code)) = N''
           OR @Description IS NULL OR LTRIM(RTRIM(@Description)) = N''
           OR @AppUserId IS NULL
        BEGIN
            SET @Message = N'Required parameter missing.';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'DefectCode',
                @EntityId = NULL, @LogEventTypeCode = N'Created',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
            RETURN;
        END

        -- FK check only when a category is supplied
        IF @OperationCategoryId IS NOT NULL
           AND NOT EXISTS (SELECT 1 FROM Parts.OperationCategory
                           WHERE Id = @OperationCategoryId AND DeprecatedAt IS NULL)
        BEGIN
            SET @Message = N'Invalid or deprecated OperationCategoryId.';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'DefectCode',
                @EntityId = NULL, @LogEventTypeCode = N'Created',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
            RETURN;
        END

        IF EXISTS (SELECT 1 FROM Quality.DefectCode WHERE Code = LTRIM(RTRIM(@Code)))
        BEGIN
            SET @Message = N'A defect code with this Code already exists.';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'DefectCode',
                @EntityId = NULL, @LogEventTypeCode = N'Created',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
            RETURN;
        END

        BEGIN TRANSACTION;

        INSERT INTO Quality.DefectCode
            (Code, Description, OperationCategoryId, IsExcused, CreatedAt)
        VALUES
            (LTRIM(RTRIM(@Code)), LTRIM(RTRIM(@Description)), @OperationCategoryId, ISNULL(@IsExcused, 0), SYSUTCDATETIME());

        SET @NewId = CAST(SCOPE_IDENTITY() AS BIGINT);

        DECLARE @CatName NVARCHAR(100) =
            ISNULL((SELECT Name FROM Parts.OperationCategory WHERE Id = @OperationCategoryId), N'Plant-wide');

        DECLARE @Subject NVARCHAR(600) =
            N'Defect Code ' + LTRIM(RTRIM(@Code)) + N' ' + NCHAR(8212) + N' ' + LTRIM(RTRIM(@Description))
            + N' (' + @CatName + N')';

        DECLARE @Activity NVARCHAR(500) = Audit.ufn_TruncateActivity(
            @Subject + N' ' + Audit.ufn_MidDot() + N' Created');

        DECLARE @NewValueResolved NVARCHAR(MAX) = (
            SELECT
                dc.Code,
                dc.Description,
                JSON_QUERY((SELECT oc.Id, oc.Code, oc.Name
                            FROM Parts.OperationCategory oc WHERE oc.Id = dc.OperationCategoryId
                            FOR JSON PATH, WITHOUT_ARRAY_WRAPPER))            AS Category,
                dc.IsExcused
            FROM Quality.DefectCode dc
            WHERE dc.Id = @NewId
            FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

        EXEC Audit.Audit_LogConfigChange
            @AppUserId         = @AppUserId,
            @LogEntityTypeCode = N'DefectCode',
            @EntityId          = @NewId,
            @LogEventTypeCode  = N'Created',
            @LogSeverityCode   = N'Info',
            @Description        = @Activity,
            @OldValue          = NULL,
            @NewValue          = @NewValueResolved;

        COMMIT TRANSACTION;

        SET @Status  = 1;
        SET @Message = N'Defect code created successfully.';
        SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        DECLARE @ErrMsg NVARCHAR(4000) = ERROR_MESSAGE();
        DECLARE @ErrSev INT = ERROR_SEVERITY();
        DECLARE @ErrState INT = ERROR_STATE();
        SET @Status = 0; SET @NewId = NULL;
        SET @Message = N'Unexpected error: ' + LEFT(@ErrMsg, 400);
        BEGIN TRY
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'DefectCode',
                @EntityId = NULL, @LogEventTypeCode = N'Created',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
        END TRY BEGIN CATCH END CATCH
        SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
        RAISERROR(@ErrMsg, @ErrSev, @ErrState);
    END CATCH
END
GO
```

- [ ] **Step 2: Rewrite `R__Quality_DefectCode_Update.sql`**

Replace the whole `CREATE OR ALTER` body with:

```sql
-- =============================================
-- Procedure:   Quality.DefectCode_Update
-- Version:     3.0
-- Change Log:
--   2026-08-04 - 3.0 - Scope by Parts.OperationCategory (nullable = plant-wide).
--                       Field-diff + resolved JSON use Category, not Area.
-- =============================================
CREATE OR ALTER PROCEDURE Quality.DefectCode_Update
    @Id                  BIGINT,
    @Description         NVARCHAR(500),
    @OperationCategoryId BIGINT          = NULL,
    @IsExcused           BIT,
    @AppUserId           BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Status  BIT           = 0;
    DECLARE @Message NVARCHAR(500) = N'Unknown error';

    DECLARE @ProcName NVARCHAR(200) = N'Quality.DefectCode_Update';
    DECLARE @Params   NVARCHAR(MAX) =
        (SELECT @Id AS Id, @Description AS Description,
                @OperationCategoryId AS OperationCategoryId, @IsExcused AS IsExcused
         FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

    BEGIN TRY
        IF @Id IS NULL OR @Description IS NULL OR LTRIM(RTRIM(@Description)) = N''
           OR @IsExcused IS NULL OR @AppUserId IS NULL
        BEGIN
            SET @Message = N'Required parameter missing.';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'DefectCode',
                @EntityId = @Id, @LogEventTypeCode = N'Updated',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message;
            RETURN;
        END

        DECLARE @Code         NVARCHAR(20);
        DECLARE @OldDesc      NVARCHAR(500);
        DECLARE @OldCatId     BIGINT;
        DECLARE @OldIsExcused BIT;
        DECLARE @DeprecatedAt DATETIME2(3);
        DECLARE @RowExists    BIT = 0;

        SELECT @Code = Code, @OldDesc = Description, @OldCatId = OperationCategoryId,
               @OldIsExcused = IsExcused, @DeprecatedAt = DeprecatedAt, @RowExists = 1
        FROM Quality.DefectCode WHERE Id = @Id;

        IF @RowExists = 0
        BEGIN
            SET @Message = N'Defect code not found.';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'DefectCode',
                @EntityId = @Id, @LogEventTypeCode = N'Updated',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message;
            RETURN;
        END

        IF @DeprecatedAt IS NOT NULL
        BEGIN
            SET @Message = N'Cannot update a deprecated defect code.';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'DefectCode',
                @EntityId = @Id, @LogEventTypeCode = N'Updated',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message;
            RETURN;
        END

        IF @OperationCategoryId IS NOT NULL
           AND NOT EXISTS (SELECT 1 FROM Parts.OperationCategory
                           WHERE Id = @OperationCategoryId AND DeprecatedAt IS NULL)
        BEGIN
            SET @Message = N'Invalid or deprecated OperationCategoryId.';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'DefectCode',
                @EntityId = @Id, @LogEventTypeCode = N'Updated',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message;
            RETURN;
        END

        DECLARE @NewDesc NVARCHAR(500) = LTRIM(RTRIM(@Description));
        DECLARE @OldCatName NVARCHAR(100) = ISNULL((SELECT Name FROM Parts.OperationCategory WHERE Id = @OldCatId), N'Plant-wide');
        DECLARE @NewCatName NVARCHAR(100) = ISNULL((SELECT Name FROM Parts.OperationCategory WHERE Id = @OperationCategoryId), N'Plant-wide');

        DECLARE @Arrow NCHAR(1) = NCHAR(8594);
        DECLARE @Fields NVARCHAR(MAX) = STUFF(
            CONCAT(
                CASE WHEN ISNULL(@OldCatId, -1) <> ISNULL(@OperationCategoryId, -1)
                     THEN N', Category "' + @OldCatName + N'" ' + @Arrow + N' "' + @NewCatName + N'"'
                     ELSE N'' END,
                CASE WHEN @OldDesc <> @NewDesc
                     THEN N', Description "' + @OldDesc + N'" ' + @Arrow + N' "' + @NewDesc + N'"'
                     ELSE N'' END,
                CASE WHEN ISNULL(@OldIsExcused, 0) <> ISNULL(@IsExcused, 0)
                     THEN N', Excused ' + CASE WHEN @OldIsExcused = 1 THEN N'true' ELSE N'false' END + N' ' + @Arrow + N' ' + CASE WHEN @IsExcused = 1 THEN N'true' ELSE N'false' END
                     ELSE N'' END
            ), 1, 2, N'');
        IF @Fields IS NULL OR @Fields = N'' SET @Fields = N'no changes';

        DECLARE @Activity NVARCHAR(500) = Audit.ufn_TruncateActivity(
            N'Defect Code ' + @Code + N' ' + Audit.ufn_MidDot() + N' Updated ' + @Fields);

        DECLARE @OldValueResolved NVARCHAR(MAX) =
            (SELECT @OldDesc AS Description,
                 JSON_QUERY((SELECT oc.Id, oc.Code, oc.Name
                             FROM Parts.OperationCategory oc WHERE oc.Id = @OldCatId
                             FOR JSON PATH, WITHOUT_ARRAY_WRAPPER))   AS Category,
                 @OldIsExcused AS IsExcused
             FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

        BEGIN TRANSACTION;

        UPDATE Quality.DefectCode SET
            Description         = @NewDesc,
            OperationCategoryId = @OperationCategoryId,
            IsExcused           = @IsExcused
        WHERE Id = @Id;

        DECLARE @NewValueResolved NVARCHAR(MAX) =
            (SELECT @NewDesc AS Description,
                 JSON_QUERY((SELECT oc.Id, oc.Code, oc.Name
                             FROM Parts.OperationCategory oc WHERE oc.Id = @OperationCategoryId
                             FOR JSON PATH, WITHOUT_ARRAY_WRAPPER))   AS Category,
                 @IsExcused AS IsExcused
             FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

        EXEC Audit.Audit_LogConfigChange
            @AppUserId         = @AppUserId,
            @LogEntityTypeCode = N'DefectCode',
            @EntityId          = @Id,
            @LogEventTypeCode  = N'Updated',
            @LogSeverityCode   = N'Info',
            @Description        = @Activity,
            @OldValue          = @OldValueResolved,
            @NewValue          = @NewValueResolved;

        COMMIT TRANSACTION;

        SET @Status  = 1;
        SET @Message = N'Defect code updated successfully.';
        SELECT @Status AS Status, @Message AS Message;
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
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'DefectCode',
                @EntityId = @Id, @LogEventTypeCode = N'Updated',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
        END TRY BEGIN CATCH END CATCH
        SELECT @Status AS Status, @Message AS Message;
        RAISERROR(@ErrMsg, @ErrSev, @ErrState);
    END CATCH
END
GO
```

- [ ] **Step 3: Commit** (procs verified together with tests in Task 6)

```bash
git add sql/migrations/repeatable/R__Quality_DefectCode_Create.sql sql/migrations/repeatable/R__Quality_DefectCode_Update.sql
git commit -m "feat(quality): DefectCode Create/Update scope by OperationCategory"
```

---

### Task 3: `DefectCode_Get` + `DefectCode_List` procs — return Category; List resolves OperationType → category with plant-wide

**Files:**
- Modify: `sql/migrations/repeatable/R__Quality_DefectCode_Get.sql`
- Modify: `sql/migrations/repeatable/R__Quality_DefectCode_List.sql`

**Interfaces:**
- Produces: both procs return columns `Id, Code, Description, OperationCategoryId, CategoryName, IsExcused, CreatedAt, DeprecatedAt` (Area columns gone). `DefectCode_List @IncludeDeprecated BIT = 0, @OperationCategoryId BIGINT = NULL, @OperationTypeCode NVARCHAR(20) = NULL`. When a category is requested directly or resolved from the type, the result is `that category OR plant-wide (NULL)`; unresolved type ⇒ plant-wide only; no filter ⇒ all.

- [ ] **Step 1: Rewrite `R__Quality_DefectCode_Get.sql`**

```sql
CREATE OR ALTER PROCEDURE Quality.DefectCode_Get
    @Id BIGINT
AS
BEGIN
    SET NOCOUNT ON;

    SELECT
        dc.Id,
        dc.Code,
        dc.Description,
        dc.OperationCategoryId,
        oc.Name                AS CategoryName,
        dc.IsExcused,
        dc.CreatedAt,
        dc.DeprecatedAt
    FROM Quality.DefectCode dc
    LEFT JOIN Parts.OperationCategory oc ON dc.OperationCategoryId = oc.Id
    WHERE dc.Id = @Id;
END
GO
```

- [ ] **Step 2: Rewrite `R__Quality_DefectCode_List.sql`**

```sql
-- =============================================
-- Procedure:   Quality.DefectCode_List
-- Version:     2.0
-- Change Log:
--   2026-08-04 - 2.0 - Scope by OperationCategory. @OperationCategoryId (config
--                       tool) OR @OperationTypeCode (plant floor, resolved to
--                       category in SQL). A requested category always ALSO
--                       returns plant-wide (NULL) codes. No filter -> all.
-- =============================================
CREATE OR ALTER PROCEDURE Quality.DefectCode_List
    @IncludeDeprecated   BIT           = 0,
    @OperationCategoryId BIGINT        = NULL,
    @OperationTypeCode   NVARCHAR(20)  = NULL
AS
BEGIN
    SET NOCOUNT ON;

    -- A filter is "requested" if either input was supplied. Resolve the effective
    -- category: explicit id wins; else derive from the operation-type code.
    DECLARE @FilterRequested BIT =
        CASE WHEN @OperationCategoryId IS NOT NULL OR @OperationTypeCode IS NOT NULL THEN 1 ELSE 0 END;

    DECLARE @EffCatId BIGINT = @OperationCategoryId;
    IF @EffCatId IS NULL AND @OperationTypeCode IS NOT NULL
        SELECT @EffCatId = ot.OperationCategoryId
        FROM Parts.OperationType ot
        WHERE ot.Code = @OperationTypeCode;

    SELECT
        dc.Id,
        dc.Code,
        dc.Description,
        dc.OperationCategoryId,
        oc.Name                AS CategoryName,
        dc.IsExcused,
        dc.CreatedAt,
        dc.DeprecatedAt
    FROM Quality.DefectCode dc
    LEFT JOIN Parts.OperationCategory oc ON dc.OperationCategoryId = oc.Id
    WHERE (@IncludeDeprecated = 1 OR dc.DeprecatedAt IS NULL)
      AND (@FilterRequested = 0
           OR dc.OperationCategoryId = @EffCatId       -- matches requested category
           OR dc.OperationCategoryId IS NULL)          -- plant-wide always included
    ORDER BY CASE WHEN dc.OperationCategoryId IS NULL THEN 1 ELSE 0 END, oc.Name, dc.Code;
END
GO
```

- [ ] **Step 3: Commit**

```bash
git add sql/migrations/repeatable/R__Quality_DefectCode_Get.sql sql/migrations/repeatable/R__Quality_DefectCode_List.sql
git commit -m "feat(quality): DefectCode Get/List return Category; List resolves OperationType + plant-wide"
```

---

### Task 4: Core Named Query `query.sql` files

**Files:**
- Modify: `ignition/projects/Core/ignition/named-query/quality/DefectCode_Create/query.sql`
- Modify: `ignition/projects/Core/ignition/named-query/quality/DefectCode_Update/query.sql`
- Modify: `ignition/projects/Core/ignition/named-query/quality/DefectCode_List/query.sql`
- Modify: `ignition/projects/Core/ignition/named-query/quality/DefectCode_Get/query.sql` (no change — verify only)

**Interfaces:**
- Consumes: the proc signatures from Tasks 2–3.
- Produces: NQ parameter names `operationCategoryId`, `operationTypeCode` (the entity script in Task 7 passes these keys).

- [ ] **Step 1: `DefectCode_Create/query.sql`**

```sql
EXEC Quality.DefectCode_Create
    @Code                = :code,
    @Description         = :description,
    @OperationCategoryId = :operationCategoryId,
    @IsExcused           = :isExcused,
    @AppUserId           = :appUserId
```

- [ ] **Step 2: `DefectCode_Update/query.sql`**

```sql
EXEC Quality.DefectCode_Update
    @Id                  = :id,
    @Description         = :description,
    @OperationCategoryId = :operationCategoryId,
    @IsExcused           = :isExcused,
    @AppUserId           = :appUserId
```

- [ ] **Step 3: `DefectCode_List/query.sql`**

```sql
EXEC Quality.DefectCode_List
    @IncludeDeprecated   = :includeDeprecated,
    @OperationCategoryId = :operationCategoryId,
    @OperationTypeCode   = :operationTypeCode
```

Each of these NQ params must be declared in the NQ's `resource.json`. Open each NQ's `resource.json` and ensure the `parameters` block matches: `Create`/`Update` swap `areaLocationId` (Int8) → `operationCategoryId` (Int8, nullable); `List` swaps `areaLocationId` → `operationCategoryId` (Int8, nullable) and adds `operationTypeCode` (String, nullable). `Get` unchanged.

- [ ] **Step 4: Scan + commit**

```bash
./scan.ps1
git add ignition/projects/Core/ignition/named-query/quality/DefectCode_Create ignition/projects/Core/ignition/named-query/quality/DefectCode_Update ignition/projects/Core/ignition/named-query/quality/DefectCode_List
git commit -m "feat(quality): DefectCode NQs pass operationCategoryId/operationTypeCode"
```

---

### Task 5: Rewrite seed `030_seed_defect_codes.sql`

**Files:**
- Modify: `sql/seeds/030_seed_defect_codes.sql`

**Interfaces:**
- Consumes: `Parts.OperationCategory` codes `DieCast` / `Trim` / `MachiningAssembly`; the new `Quality.DefectCode.OperationCategoryId` column.

- [ ] **Step 1: Replace the location-lookup DECLAREs and the temp-table shape**

Replace the four `Location.Location` lookups with category lookups, and rename the temp column:

```sql
DECLARE @DieCast BIGINT = (SELECT Id FROM Parts.OperationCategory WHERE Code = N'DieCast');
DECLARE @Trim    BIGINT = (SELECT Id FROM Parts.OperationCategory WHERE Code = N'Trim');
DECLARE @MachAsm BIGINT = (SELECT Id FROM Parts.OperationCategory WHERE Code = N'MachiningAssembly');
-- Plant-wide codes (shipping / labels / ISO / inventory) use NULL.

DECLARE @Defects TABLE (Code NVARCHAR(20), Description NVARCHAR(500), OperationCategoryId BIGINT, IsExcused BIT);
```

- [ ] **Step 2: Remap the VALUES tokens (mechanical find-replace on the 3rd column)**

In the `INSERT INTO @Defects ... VALUES` block, replace each area token with a category variable (these are the only four tokens present today):
- `@DC1` → `@DieCast`
- `@MA1` → `@MachAsm`
- `@TRM` → `@Trim`
- `@SIT` → `NULL`   (the MPP-MAD / logistics bucket — now plant-wide)

- [ ] **Step 3: Replace the final INSERT (column name + drop the NOT-NULL filter)**

NULL is now a valid value (plant-wide), so drop the `WHERE d.AreaLocationId IS NOT NULL` guard; keep only the dedupe:

```sql
INSERT INTO Quality.DefectCode (Code, Description, OperationCategoryId, IsExcused)
SELECT d.Code, d.Description, d.OperationCategoryId, d.IsExcused
FROM @Defects d
WHERE NOT EXISTS (SELECT 1 FROM Quality.DefectCode dc WHERE dc.Code = d.Code);
```

Update the file header comment: remove the FDS-08-017 "die-cast codes attach to DC1 only" caveat; state that codes are scoped by OperationCategory and the logistics bucket is plant-wide (NULL).

- [ ] **Step 4: Byte-scan for non-ASCII, then reset the test DB and verify the mapping**

```bash
python -c "b=open(r'sql/seeds/030_seed_defect_codes.sql','rb').read(); print('NON-ASCII' if any(x>127 for x in b) else 'ASCII-OK')"
# after a full MPP_MES_Test reset (migrations + seeds):
sqlcmd -S localhost -d MPP_MES_Test -Q "SELECT oc.Code AS Cat, COUNT(*) AS N FROM Quality.DefectCode dc LEFT JOIN Parts.OperationCategory oc ON dc.OperationCategoryId=oc.Id GROUP BY oc.Code ORDER BY oc.Code;"
```
Expected: buckets for `DieCast`, `MachiningAssembly`, `Trim`, and a `NULL` (plant-wide) group; die-cast codes like `100`,`111` resolve to `DieCast`; `225`,`247` resolve to NULL.

- [ ] **Step 5: Commit**

```bash
git add sql/seeds/030_seed_defect_codes.sql
git commit -m "seed(quality): defect codes scoped by OperationCategory (logistics = plant-wide)"
```

---

### Task 6: Rewrite SQL test `040_DefectCode_crud.sql`

**Files:**
- Modify: `sql/tests/0011_Quality_Spec/040_DefectCode_crud.sql`

**Interfaces:**
- Consumes: procs from Tasks 2–3. This task is the green-bar gate for those procs.

- [ ] **Step 1: Replace the setup block — fetch a category, not an Area**

```sql
-- Setup: capture the DieCast OperationCategory id
DECLARE @CatId BIGINT = (SELECT Id FROM Parts.OperationCategory WHERE Code = N'DieCast');
IF @CatId IS NULL
BEGIN
    RAISERROR('Test requires Parts.OperationCategory seed (DieCast)', 16, 1);
    RETURN;
END
CREATE TABLE #TestContext (CatId BIGINT);
INSERT INTO #TestContext VALUES (@CatId);
GO
```

- [ ] **Step 2: Global find-replace across the test body**

- Every `@AreaLocationId = @AreaId` (Create/Update calls) → `@OperationCategoryId = @CatId`.
- Every `SELECT @AreaId = AreaId FROM #TestContext;` → `SELECT @CatId = CatId FROM #TestContext;` and rename the local `@AreaId` decls to `@CatId`.
- The three `#GetResult` / `#ListResult` / `#ActiveList` / `#AllList` temp-table shapes: replace `AreaLocationId BIGINT, AreaName NVARCHAR(200)` with `OperationCategoryId BIGINT, CategoryName NVARCHAR(200)`.

- [ ] **Step 3: Fix Test 5 (invalid FK) — assert on the new param name**

```sql
CREATE TABLE #QR5 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #QR5 EXEC Quality.DefectCode_Create
    @Code                = N'TEST-DEF-X',
    @Description         = N'Invalid category',
    @OperationCategoryId = 999999,
    @AppUserId           = 1;
SELECT @S = Status, @M = Message, @NewId = NewId FROM #QR5;
DROP TABLE #QR5;

SET @SStr = CAST(@S AS NVARCHAR(1));
EXEC test.Assert_IsEqual
    @TestName = N'[DefectCreateInvalidCat] Status is 0', @Expected = N'0', @Actual = @SStr;
EXEC test.Assert_Contains
    @TestName = N'[DefectCreateInvalidCat] Message mentions OperationCategoryId',
    @HaystackStr = @M, @NeedleStr = N'OperationCategoryId';
```

- [ ] **Step 4: Update the Slice-8 audit assertions — Category, not Area**

In the three Slice-8 blocks: the Create pattern `... Blowhole (%) · Created` still holds (parens now wrap the category name). Change every `JSON_VALUE(@NewVal, '$.Area.Name')` / `'$.Old...$.Area.Name'` assertion to `'$.Category.Name'`, and the Update field-diff pattern stays `Description "Blowhole" → "Surface blowhole"` (category unchanged in that test, so only the Description diff appears).

- [ ] **Step 5: Add new tests — plant-wide create + type-resolution filtering**

Append before the cleanup:

```sql
-- Plant-wide create (NULL category) succeeds
DECLARE @S BIT, @M NVARCHAR(500), @NewId BIGINT;
CREATE TABLE #QPW (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #QPW EXEC Quality.DefectCode_Create
    @Code = N'TEST-DEF-PW', @Description = N'Plant-wide defect',
    @OperationCategoryId = NULL, @IsExcused = 0, @AppUserId = 1;
SELECT @S = Status, @NewId = NewId FROM #QPW; DROP TABLE #QPW;
DECLARE @PWStr NVARCHAR(1) = CAST(@S AS NVARCHAR(1));
EXEC test.Assert_IsEqual @TestName = N'[DefectPlantWide] Status is 1', @Expected = N'1', @Actual = @PWStr;
GO

-- List by OperationTypeCode 'DieCast' returns the die-cast code AND the plant-wide code,
-- and EXCLUDES a Trim-scoped code.
DECLARE @TrimId BIGINT = (SELECT Id FROM Parts.OperationCategory WHERE Code = N'Trim');
DECLARE @S BIT, @M NVARCHAR(500), @NewId BIGINT;
CREATE TABLE #QT (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #QT EXEC Quality.DefectCode_Create
    @Code = N'TEST-DEF-TRIM', @Description = N'Trim only',
    @OperationCategoryId = @TrimId, @IsExcused = 0, @AppUserId = 1;
DROP TABLE #QT;

CREATE TABLE #LT (Id BIGINT, Code NVARCHAR(20), Description NVARCHAR(500),
    OperationCategoryId BIGINT, CategoryName NVARCHAR(200),
    IsExcused BIT, CreatedAt DATETIME2(3), DeprecatedAt DATETIME2(3));
INSERT INTO #LT EXEC Quality.DefectCode_List
    @IncludeDeprecated = 0, @OperationCategoryId = NULL, @OperationTypeCode = N'DieCast';

DECLARE @HasDC   NVARCHAR(1) = CASE WHEN EXISTS(SELECT 1 FROM #LT WHERE Code = N'TEST-DEF-001')  THEN N'1' ELSE N'0' END;
DECLARE @HasPW   NVARCHAR(1) = CASE WHEN EXISTS(SELECT 1 FROM #LT WHERE Code = N'TEST-DEF-PW')   THEN N'1' ELSE N'0' END;
DECLARE @HasTrim NVARCHAR(1) = CASE WHEN EXISTS(SELECT 1 FROM #LT WHERE Code = N'TEST-DEF-TRIM') THEN N'1' ELSE N'0' END;
DROP TABLE #LT;

EXEC test.Assert_IsEqual @TestName = N'[DefectListByType] die-cast code present',  @Expected = N'1', @Actual = @HasDC;
EXEC test.Assert_IsEqual @TestName = N'[DefectListByType] plant-wide code present', @Expected = N'1', @Actual = @HasPW;
EXEC test.Assert_IsEqual @TestName = N'[DefectListByType] trim code excluded',      @Expected = N'0', @Actual = @HasTrim;
GO

-- Cleanup the extra rows
DELETE FROM Quality.DefectCode WHERE Code IN (N'TEST-DEF-PW', N'TEST-DEF-TRIM');
GO
```

Note: `TEST-DEF-001` was updated in Test 6 to category `@CatId` (DieCast), so it is a valid die-cast member for the by-type assertion.

- [ ] **Step 6: Run the test file, expect all green**

```bash
# Run the repo's test runner against MPP_MES_Test (see sql_version_control_guide.md).
# Expected: 0011_Quality_Spec/040_DefectCode_crud.sql — all assertions pass, exit 0.
```
If the runner exits 1 with 0 failures, check for a cleanup FK/order issue (see the Run-Tests memory).

- [ ] **Step 7: Commit**

```bash
git add sql/tests/0011_Quality_Spec/040_DefectCode_crud.sql
git commit -m "test(quality): DefectCode crud covers OperationCategory + plant-wide + type-resolution"
```

---

### Task 7: Core entity script `BlueRidge.Quality.DefectCode`

**Files:**
- Modify: `ignition/projects/Core/ignition/script-python/BlueRidge/Quality/DefectCode/code.py`

**Interfaces:**
- Consumes: NQ param names from Task 4.
- Produces: `getForDropdown(operationTypeCode=None)`; `search`/`getAll`/`add`/`update` keyed on `operationCategoryId` / `OperationCategoryId`; row maps expose `category` + `operationCategoryId`.

- [ ] **Step 1: `getAll` — rename the filter param and NQ key**

```python
def getAll(includeDeprecated=False, operationCategoryId=None):
    """List defect codes, optionally including deprecated and/or filtered by
    OperationCategory. SQL ORDER BY guarantees (plant-wide last, CategoryName, Code)."""
    BlueRidge.Common.Util.log("includeDeprecated=%s operationCategoryId=%s"
                              % (includeDeprecated, operationCategoryId))
    try:
        return BlueRidge.Common.Db.execList(
            "quality/DefectCode_List",
            {
                "includeDeprecated": 1 if includeDeprecated else 0,
                "operationCategoryId": operationCategoryId,
                "operationTypeCode":   None,
            },
        )
    except Exception as e:
        BlueRidge.Common.Util.log("getAll failed: %s" % str(e))
        BlueRidge.Common.Notify.toast("Could not load defect codes", str(e), "error")
        return []
```

- [ ] **Step 2: `search` — remap filter keys + row shape**

```python
def search(filter=None):
    f = _u(filter) or {}
    rows = getAll(
        bool(f.get("includeDeprecated", False)),
        f.get("operationCategoryId"),
    )
    needle = (f.get("searchText") or "").strip().lower()
    out = []
    for r in rows:
        code        = r.get("Code") or ""
        description = r.get("Description") or ""
        if needle and needle not in code.lower() and needle not in description.lower():
            continue
        out.append({
            "id":                  r.get("Id"),
            "code":                code,
            "description":         description,
            "category":            r.get("CategoryName") or "Plant-wide",
            "operationCategoryId": r.get("OperationCategoryId"),
            "excused":             bool(r.get("IsExcused")),
            "deprecated":          r.get("DeprecatedAt") is not None,
            "selected":            False,
        })
    return out
```

- [ ] **Step 3: `getForDropdown` — accept the operation-type code (plant-floor path)**

```python
def getForDropdown(operationTypeCode=None):
    """Active defect codes as [{label, value}] for a reject panel dropdown,
    scoped to the terminal's operation category (+ plant-wide) when a type code
    is given. label = 'CODE - Description', value = DefectCode.Id."""
    try:
        rows = BlueRidge.Common.Db.execList(
            "quality/DefectCode_List",
            {"includeDeprecated": 0, "operationCategoryId": None,
             "operationTypeCode": operationTypeCode},
        ) or []
    except Exception as e:
        BlueRidge.Common.Util.log("getForDropdown failed: %s" % str(e))
        return []
    out = []
    for r in rows:
        code = r.get("Code") or ""
        desc = r.get("Description") or ""
        label = ("%s - %s" % (code, desc)) if desc else code
        out.append({"label": label, "value": r.get("Id")})
    return out
```

- [ ] **Step 4: `add` / `update` — swap the mutation key**

In `add`, replace the `areaLocationId` entry with:
```python
            "operationCategoryId": data.get("OperationCategoryId"),
```
In `update`, same replacement. (Both read `data.get("OperationCategoryId")`; a missing/None value is a valid plant-wide code.)

- [ ] **Step 5: Update the module header docstring** — `getAll(includeDeprecated=False, operationCategoryId=None)`, `getForDropdown(operationTypeCode=None)`, and `add`/`update` data shapes now say `OperationCategoryId`. Leave `derivePrefix` as-is (still a name-based prefix helper; now receives a category name).

- [ ] **Step 6: Scan + commit**

```bash
./scan.ps1
git add ignition/projects/Core/ignition/script-python/BlueRidge/Quality/DefectCode/code.py
git commit -m "feat(quality): DefectCode entity script scopes by OperationCategory + type-resolved dropdown"
```

---

### Task 8: Designer view updates (config tool + plant floor)

**Files (edited in Designer, NOT as file edits):**
- `ignition/projects/MPP_Config/.../Components/Popups/DefectCodeEditor/view.json`
- `ignition/projects/MPP_Config/.../Components/DefectCodeRow/view.json`
- `ignition/projects/MPP_Config/.../Views/Quality/DefectCodes/view.json`
- `ignition/projects/MPP/.../Components/PlantFloor/DieCastEntry/RejectPanel/view.json`

**Interfaces:**
- Consumes: entity script surface from Task 7 (`getForDropdown("DieCast")`, `search`, `add`, `update`).

Per the Ignition view-edit boundary rule, these are Designer changes. Do them in one Designer session, then `.\scan.ps1` to write the files back.

- [ ] **Step 1: `DefectCodeEditor`** — replace the Area dropdown with an "Applies to" dropdown. Options = the 3 `Parts.OperationCategory` rows plus a literal `{"label": "Plant-wide (all areas)", "value": null}` entry. Bind `props.value` bidirectionally to `editDraft.OperationCategoryId`. Selecting "Plant-wide" writes `null`. Remove any `AreaLocationId` references and the Area-derived code-prefix behavior (or repoint `derivePrefix` at the category name).

- [ ] **Step 2: `DefectCodeRow`** — the Area column now shows `{instance.category}` (already "Plant-wide" fallback from Task 7). Rename the column label from "Area" to "Applies to".

- [ ] **Step 3: `DefectCodes` list view** — if it has an Area filter dropdown, repoint it to categories (+ "All") and pass `operationCategoryId` into `search`'s filter. Update the column header.

- [ ] **Step 4: `RejectPanel`** — change the dropdown options binding from
  `runScript("BlueRidge.Quality.DefectCode.getForDropdown", 0)` to
  `runScript("BlueRidge.Quality.DefectCode.getForDropdown", 0, "DieCast")`.
  The die-cast reject screen then lists die-cast + plant-wide codes only.

- [ ] **Step 5: Scan, smoke-test in the running app, commit**

```bash
./scan.ps1
git add ignition/projects/MPP_Config/com.inductiveautomation.perspective/views/BlueRidge/Components/Popups/DefectCodeEditor ignition/projects/MPP_Config/com.inductiveautomation.perspective/views/BlueRidge/Components/DefectCodeRow ignition/projects/MPP_Config/com.inductiveautomation.perspective/views/BlueRidge/Views/Quality/DefectCodes ignition/projects/MPP/com.inductiveautomation.perspective/views/BlueRidge/Components/PlantFloor/DieCastEntry/RejectPanel
git commit -m "feat(quality): defect-code editor + die-cast reject dropdown scope by OperationCategory"
```

Smoke checks: config-tool editor shows 3 categories + Plant-wide; saving a plant-wide code round-trips; die-cast RejectPanel dropdown no longer lists trim/machining-only codes but does list plant-wide ones.

---

## Self-Review

**Spec coverage:**
- Schema swap (add/backfill/drop) → Task 1. ✓
- Create/Update category param + audit Category JSON → Task 2. ✓
- Get/List return category; List type-resolution + plant-wide filter → Task 3. ✓
- NQs → Task 4. ✓
- Seed rewrite → Task 5. ✓
- Entity script → Task 7. ✓
- Views (editor, row, list, RejectPanel) → Task 8. ✓
- Tests (incl. plant-wide + type-resolution) → Task 6. ✓
- Decision 3 (requested category also returns plant-wide) → List `WHERE ... OR OperationCategoryId IS NULL`, asserted in Task 6 Step 5. ✓
- Decision 2 (nullable = plant-wide) → nullable column (Task 1), optional param (Task 2), plant-wide create test (Task 6). ✓
- "Deferred: only die-cast RejectPanel gets a type code" → Task 8 Step 4. ✓

**Type consistency:** result columns `OperationCategoryId` + `CategoryName` used identically across Get, List, temp tables (Task 6), and the entity script map (`r.get("CategoryName")`, `r.get("OperationCategoryId")`). NQ param keys `operationCategoryId` / `operationTypeCode` match between Task 4 and Task 7. Proc param `@OperationCategoryId` consistent across Create/Update/List.

**Placeholder scan:** none — every code step carries full content or a precise mechanical rule (Task 5 Step 2 lists the exact four token substitutions present in the current seed).
