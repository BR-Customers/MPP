# Route-Driven Terminal Queues — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the read-side foundation for route-driven terminal queues — a lot's *next required route operation* determines which line terminal shows it — without changing any existing write behavior.

**Architecture:** Lots (later) live at the line; a terminal shows the line's open lots whose next uncompleted route step is the op that terminal performs. This plan delivers the *derivation + read* layer: new assembly operation templates, a screen→op registry, a `ufn_LotNextOp` route-position function, and a `Lot_GetLineQueueForOp` queue read, all additive and independently testable. The write-side procs that revise FDS (Trim-OUT/MachiningIn/MachiningOut/assembly) are Plan 2, gated on OQ-COUPLE sign-off.

**Tech Stack:** SQL Server 2022 (T-SQL), the repo's `test.*` T-SQL test framework, `sqlcmd`, Ignition named queries + Jython wrappers.

**Source spec:** `docs/superpowers/specs/2026-07-01-line-resident-lots-route-driven-terminal-queues-design.md`

## Global Constraints

- **SQL style:** `UpperCamelCase` tables/columns; `BIGINT IDENTITY` PKs; `NVARCHAR` (never `VARCHAR`); `DATETIME2(3)`; `DECIMAL` not `FLOAT`. Timestamps stored UTC (`SYSUTCDATETIME()`), displayed ET.
- **FDS-11-011 (no OUTPUT params):** read procs return a single result set, empty = not found (no invented 404); no `OUTPUT` parameters anywhere.
- **CATCH blocks:** `RAISERROR` (not `THROW`); schema-qualify every DB reference; `EXEC` params are literals or `@variables` only (no inline `CAST`/arithmetic/`CASE`).
- **Migrations:** repeatable objects (functions/procs) → `sql/migrations/repeatable/R__<Schema>_<Name>.sql` (idempotent `CREATE OR ALTER`); schema/seed changes → `sql/migrations/versioned/NNNN_*.sql`; standalone seeds → `sql/seeds/NNN_*.sql`. ASCII-only seed strings.
- **Tests:** `sql/tests/NNNN_<Area>/NNN_*.sql` using the `test.*` framework (`test.BeginTestFile`, `test.Assert_IsEqual`, `test.EndTestFile`); `EXEC` assert params must be pre-assigned `@variables` (no inline `CAST`). `sql/tests/Run-Tests.ps1` **resets the dev DB** — only run against a disposable DB, never the working `MPP_MES_Dev` during dev unless intended.
- **Ignition JDBC:** named queries are thin `EXEC` wrappers; Jython wrappers route reads through `BlueRidge.Common.Db.execList`.
- **This plan is additive.** No existing proc/view behavior changes. Nothing here depends on OQ-COUPLE.

---

## File structure

| File | Responsibility |
|---|---|
| `sql/seeds/030_seed_assembly_operation_templates.sql` | Seed `AssemblyIn` / `AssemblyOut` OperationTemplates |
| `sql/migrations/versioned/00NN_view_op_registry.sql` | `Location.ViewOpRegistry` table (screen path → station op) + seed |
| `sql/migrations/repeatable/R__Lots_ufn_LotNextOp.sql` | Route-position function: lot → next uncompleted route op |
| `sql/migrations/repeatable/R__Lots_Lot_GetLineQueueForOp.sql` | Queue read: line lots whose next op = the terminal op |
| `sql/migrations/versioned/00NN_productionevent_nextop_index.sql` | Index supporting completed-ops-per-lot |
| `sql/seeds/031_seed_station_level_routes.sql` | Demo station-level routes (5G0, RPY cam) referencing station ops |
| `ignition/projects/Core/ignition/named-query/lots/Lot_GetLineQueueForOp/query.sql` | NQ wrapper |
| `ignition/projects/Core/ignition/script-python/BlueRidge/Lots/Lot/code.py` | `getLineQueueForOp` wrapper (append) |
| `sql/tests/0030_RouteDriven_Queues/*.sql` | Tests for the function + queue read |

---

## Task 1: `AssemblyIn` / `AssemblyOut` operation templates

**Files:**
- Create: `sql/seeds/030_seed_assembly_operation_templates.sql`
- Test: `sql/tests/0030_RouteDriven_Queues/010_assembly_ops_seeded.sql`

**Interfaces:**
- Produces: two `Parts.OperationTemplate` rows with `Code = N'AssemblyIn'` and `Code = N'AssemblyOut'`, `AreaLocationId` = the assembly (machining) Area, `VersionNumber = 1`, `DeprecatedAt = NULL`. Later tasks reference them by `Code`.

- [ ] **Step 1: Write the failing test**

```sql
-- sql/tests/0030_RouteDriven_Queues/010_assembly_ops_seeded.sql
SET NOCOUNT ON; SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0030_RouteDriven_Queues/010_assembly_ops_seeded.sql';
GO
DECLARE @In  NVARCHAR(10) = CASE WHEN EXISTS (SELECT 1 FROM Parts.OperationTemplate WHERE Code = N'AssemblyIn'  AND DeprecatedAt IS NULL) THEN N'1' ELSE N'0' END;
DECLARE @Out NVARCHAR(10) = CASE WHEN EXISTS (SELECT 1 FROM Parts.OperationTemplate WHERE Code = N'AssemblyOut' AND DeprecatedAt IS NULL) THEN N'1' ELSE N'0' END;
EXEC test.Assert_IsEqual @TestName = N'[AsmOps] AssemblyIn seeded',  @Expected = N'1', @Actual = @In;
EXEC test.Assert_IsEqual @TestName = N'[AsmOps] AssemblyOut seeded', @Expected = N'1', @Actual = @Out;
GO
EXEC test.EndTestFile;
GO
```

- [ ] **Step 2: Run test to verify it fails**

Run: `sqlcmd -S localhost -d MPP_MES_TestScratch -b -I -C -i sql/tests/0030_RouteDriven_Queues/010_assembly_ops_seeded.sql`
Expected: both asserts FAIL (Actual `0`).

- [ ] **Step 3: Write the seed**

```sql
-- sql/seeds/030_seed_assembly_operation_templates.sql
SET NOCOUNT ON;
DECLARE @AsmArea BIGINT = (SELECT AreaLocationId FROM Parts.OperationTemplate WHERE Code = N'MachiningIn');  -- assembly runs in the machining Area (49) per seed
IF NOT EXISTS (SELECT 1 FROM Parts.OperationTemplate WHERE Code = N'AssemblyIn')
    INSERT INTO Parts.OperationTemplate (Code, VersionNumber, Name, AreaLocationId, Description, CreatedAt, RequiresSubLotSplit)
    VALUES (N'AssemblyIn', 1, N'Assembly In', @AsmArea, N'Assembly-line IN station checkpoint (route-driven queues).', SYSUTCDATETIME(), 0);
IF NOT EXISTS (SELECT 1 FROM Parts.OperationTemplate WHERE Code = N'AssemblyOut')
    INSERT INTO Parts.OperationTemplate (Code, VersionNumber, Name, AreaLocationId, Description, CreatedAt, RequiresSubLotSplit)
    VALUES (N'AssemblyOut', 1, N'Assembly Out', @AsmArea, N'Assembly-line OUT station checkpoint / container consume (route-driven queues).', SYSUTCDATETIME(), 0);
```

- [ ] **Step 4: Apply the seed + run the test**

Run: `sqlcmd -S localhost -d MPP_MES_TestScratch -b -I -C -i sql/seeds/030_seed_assembly_operation_templates.sql` then re-run the test from Step 2.
Expected: both asserts PASS.

- [ ] **Step 5: Commit**

```bash
git add sql/seeds/030_seed_assembly_operation_templates.sql sql/tests/0030_RouteDriven_Queues/010_assembly_ops_seeded.sql
git commit -m "feat(routes): seed AssemblyIn/AssemblyOut operation templates"
```

---

## Task 2: `Location.ViewOpRegistry` (screen → station op)

**Files:**
- Create: `sql/migrations/versioned/0030_view_op_registry.sql`
- Test: `sql/tests/0030_RouteDriven_Queues/020_view_op_registry.sql`

**Interfaces:**
- Produces: table `Location.ViewOpRegistry (Id BIGINT IDENTITY PK, ScreenPath NVARCHAR(200) UNIQUE, StationOpCode NVARCHAR(30) NOT NULL, DeprecatedAt DATETIME2(3) NULL)` mapping a terminal's `DefaultScreen` to a station op code. Consumed by `Lot_GetLineQueueForOp` (a terminal resolves its op from its screen) and by the op-chain health-check.

- [ ] **Step 1: Write the failing test**

```sql
-- sql/tests/0030_RouteDriven_Queues/020_view_op_registry.sql
SET NOCOUNT ON; SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0030_RouteDriven_Queues/020_view_op_registry.sql';
GO
DECLARE @Exists NVARCHAR(10) = CASE WHEN OBJECT_ID('Location.ViewOpRegistry') IS NOT NULL THEN N'1' ELSE N'0' END;
EXEC test.Assert_IsEqual @TestName = N'[Reg] table exists', @Expected = N'1', @Actual = @Exists;
DECLARE @Min NVARCHAR(30) = (SELECT TOP 1 StationOpCode FROM Location.ViewOpRegistry WHERE ScreenPath = N'BlueRidge/Views/ShopFloor/MachiningIn');
EXEC test.Assert_IsEqual @TestName = N'[Reg] MachiningIn screen maps to MachiningIn op', @Expected = N'MachiningIn', @Actual = @Min;
GO
EXEC test.EndTestFile;
GO
```

- [ ] **Step 2: Run test to verify it fails**

Run: `sqlcmd -S localhost -d MPP_MES_TestScratch -b -I -C -i sql/tests/0030_RouteDriven_Queues/020_view_op_registry.sql`
Expected: FAIL — `Invalid object name 'Location.ViewOpRegistry'`.

- [ ] **Step 3: Create the table + seed**

```sql
-- sql/migrations/versioned/0030_view_op_registry.sql
IF OBJECT_ID('Location.ViewOpRegistry') IS NULL
BEGIN
    CREATE TABLE Location.ViewOpRegistry (
        Id            BIGINT IDENTITY(1,1) NOT NULL CONSTRAINT PK_ViewOpRegistry PRIMARY KEY,
        ScreenPath    NVARCHAR(200) NOT NULL CONSTRAINT UQ_ViewOpRegistry_ScreenPath UNIQUE,
        StationOpCode NVARCHAR(30)  NOT NULL,
        DeprecatedAt  DATETIME2(3)  NULL
    );
END
GO
MERGE Location.ViewOpRegistry AS t
USING (VALUES
    (N'BlueRidge/Views/ShopFloor/MachiningIn',  N'MachiningIn'),
    (N'BlueRidge/Views/ShopFloor/MachiningOut', N'MachiningOut'),
    (N'BlueRidge/Views/ShopFloor/AssemblyIn',   N'AssemblyIn'),
    (N'BlueRidge/Views/ShopFloor/AssemblySerialized',    N'AssemblyOut'),
    (N'BlueRidge/Views/ShopFloor/AssemblyNonSerialized', N'AssemblyOut')
) AS s(ScreenPath, StationOpCode) ON t.ScreenPath = s.ScreenPath
WHEN NOT MATCHED THEN INSERT (ScreenPath, StationOpCode) VALUES (s.ScreenPath, s.StationOpCode);
GO
```

- [ ] **Step 4: Apply + run the test**

Run: apply `0030_view_op_registry.sql`, then re-run the Step 2 test.
Expected: both asserts PASS.

- [ ] **Step 5: Commit**

```bash
git add sql/migrations/versioned/0030_view_op_registry.sql sql/tests/0030_RouteDriven_Queues/020_view_op_registry.sql
git commit -m "feat(routes): add Location.ViewOpRegistry (screen -> station op)"
```

---

## Task 3: `Lots.ufn_LotNextOp` — route-position function

**Files:**
- Create: `sql/migrations/repeatable/R__Lots_ufn_LotNextOp.sql`
- Test: `sql/tests/0030_RouteDriven_Queues/030_ufn_LotNextOp.sql`

**Interfaces:**
- Consumes: `Parts.RouteTemplate`, `Parts.RouteStep`, `Parts.OperationTemplate`, `Workorder.ProductionEvent`, `Lots.Lot`.
- Produces: `Lots.ufn_LotNextOp(@LotId BIGINT)` inline TVF returning one row `(NextOpCode NVARCHAR(30), NextOpTemplateId BIGINT)` — the first route step (by `SequenceNumber`) of the lot's item's active published route whose op is NOT among the lot's own `ProductionEvent` op codes. Returns **no rows** when the route is complete or the item has no published route.

- [ ] **Step 1: Write the failing test** (fixture built + rolled back; uses seeded 5G0-family lots)

```sql
-- sql/tests/0030_RouteDriven_Queues/030_ufn_LotNextOp.sql
SET NOCOUNT ON; SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0030_RouteDriven_Queues/030_ufn_LotNextOp.sql';
GO
BEGIN TRAN;
-- a machined lot that has completed MachiningIn should have NextOp = MachiningOut (route: MachiningIn->MachiningOut->AssemblyIn->AssemblyOut)
DECLARE @Item BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'5G0-MACH');
DECLARE @Line BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MA1-5GOF');
DECLARE @Rc TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO @Rc EXEC Lots.Lot_Create @ItemId=@Item, @LotOriginTypeId=1, @CurrentLocationId=@Line, @PieceCount=10, @AppUserId=1;
DECLARE @Lot BIGINT = (SELECT NewId FROM @Rc);
-- stamp a MachiningIn ProductionEvent for this lot
DECLARE @MinOt BIGINT = (SELECT Id FROM Parts.OperationTemplate WHERE Code=N'MachiningIn');
INSERT INTO Workorder.ProductionEvent (LotId, OperationTemplateId, EventAt, AppUserId) VALUES (@Lot, @MinOt, SYSUTCDATETIME(), 1);
DECLARE @Next NVARCHAR(30) = (SELECT NextOpCode FROM Lots.ufn_LotNextOp(@Lot));
EXEC test.Assert_IsEqual @TestName = N'[NextOp] after MachiningIn -> MachiningOut', @Expected = N'MachiningOut', @Actual = @Next;
ROLLBACK;
GO
EXEC test.EndTestFile;
GO
```

- [ ] **Step 2: Run test to verify it fails**

Run: `sqlcmd -S localhost -d MPP_MES_TestScratch -b -I -C -i sql/tests/0030_RouteDriven_Queues/030_ufn_LotNextOp.sql`
Expected: FAIL — `Invalid object name 'Lots.ufn_LotNextOp'` (this test presupposes Task 6's station route seed for 5G0-MACH; run Task 6 first if the route is absent).

- [ ] **Step 3: Write the function**

```sql
-- sql/migrations/repeatable/R__Lots_ufn_LotNextOp.sql
CREATE OR ALTER FUNCTION Lots.ufn_LotNextOp(@LotId BIGINT)
RETURNS TABLE
AS
RETURN
    WITH LotItem AS (
        SELECT l.ItemId FROM Lots.Lot l WHERE l.Id = @LotId
    ),
    ActiveRoute AS (   -- the item's active published route (latest published, not deprecated)
        SELECT TOP 1 rt.Id
        FROM Parts.RouteTemplate rt
        JOIN LotItem li ON li.ItemId = rt.ItemId
        WHERE rt.PublishedAt IS NOT NULL AND rt.DeprecatedAt IS NULL
        ORDER BY rt.VersionNumber DESC
    ),
    Steps AS (
        SELECT rs.SequenceNumber, ot.Id AS OpId, ot.Code AS OpCode
        FROM Parts.RouteStep rs
        JOIN ActiveRoute ar ON ar.Id = rs.RouteTemplateId
        JOIN Parts.OperationTemplate ot ON ot.Id = rs.OperationTemplateId
    ),
    Done AS (
        SELECT DISTINCT pe.OperationTemplateId FROM Workorder.ProductionEvent pe WHERE pe.LotId = @LotId
    )
    SELECT TOP 1 s.OpCode AS NextOpCode, s.OpId AS NextOpTemplateId
    FROM Steps s
    WHERE s.OpId NOT IN (SELECT OperationTemplateId FROM Done)
    ORDER BY s.SequenceNumber;
GO
```

- [ ] **Step 4: Apply + run the test**

Run: apply `R__Lots_ufn_LotNextOp.sql`, then re-run the Step 2 test.
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add sql/migrations/repeatable/R__Lots_ufn_LotNextOp.sql sql/tests/0030_RouteDriven_Queues/030_ufn_LotNextOp.sql
git commit -m "feat(routes): add Lots.ufn_LotNextOp route-position function"
```

---

## Task 4: `Lots.Lot_GetLineQueueForOp` — the queue read

**Files:**
- Create: `sql/migrations/repeatable/R__Lots_Lot_GetLineQueueForOp.sql`
- Test: `sql/tests/0030_RouteDriven_Queues/040_Lot_GetLineQueueForOp.sql`

**Interfaces:**
- Consumes: `Lots.ufn_LotNextOp` (Task 3), `Lots.Lot`, `Lots.LotStatusCode`, `Parts.Item`.
- Produces: `Lots.Lot_GetLineQueueForOp(@LineLocationId BIGINT, @StationOpCode NVARCHAR(30))` read proc returning `(Id, LotName, ItemId, PartNumber, PieceCount, NextOpCode)` for open lots at the line whose `NextOp = @StationOpCode`, ordered FIFO by line-arrival then `Id`. No OUTPUT params; empty = none.

- [ ] **Step 1: Write the failing test**

```sql
-- sql/tests/0030_RouteDriven_Queues/040_Lot_GetLineQueueForOp.sql
SET NOCOUNT ON; SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0030_RouteDriven_Queues/040_Lot_GetLineQueueForOp.sql';
GO
BEGIN TRAN;
DECLARE @Item BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'5G0-MACH');
DECLARE @Line BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MA1-5GOF');
DECLARE @Rc TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO @Rc EXEC Lots.Lot_Create @ItemId=@Item, @LotOriginTypeId=1, @CurrentLocationId=@Line, @PieceCount=10, @AppUserId=1;
DECLARE @Lot BIGINT = (SELECT NewId FROM @Rc);
DECLARE @MinOt BIGINT = (SELECT Id FROM Parts.OperationTemplate WHERE Code=N'MachiningIn');
INSERT INTO Workorder.ProductionEvent (LotId, OperationTemplateId, EventAt, AppUserId) VALUES (@Lot, @MinOt, SYSUTCDATETIME(), 1);
CREATE TABLE #Q (Id BIGINT, LotName NVARCHAR(50), ItemId BIGINT, PartNumber NVARCHAR(50), PieceCount INT, NextOpCode NVARCHAR(30));
-- appears in the MachiningOut queue...
INSERT INTO #Q EXEC Lots.Lot_GetLineQueueForOp @LineLocationId=@Line, @StationOpCode=N'MachiningOut';
DECLARE @InMout NVARCHAR(10) = CASE WHEN EXISTS (SELECT 1 FROM #Q WHERE Id=@Lot) THEN N'1' ELSE N'0' END;
EXEC test.Assert_IsEqual @TestName = N'[Queue] machined lot shows at MachiningOut', @Expected = N'1', @Actual = @InMout;
-- ...and NOT in the MachiningIn queue (the dup-dissolution)
DELETE FROM #Q; INSERT INTO #Q EXEC Lots.Lot_GetLineQueueForOp @LineLocationId=@Line, @StationOpCode=N'MachiningIn';
DECLARE @InMin NVARCHAR(10) = CASE WHEN EXISTS (SELECT 1 FROM #Q WHERE Id=@Lot) THEN N'1' ELSE N'0' END;
EXEC test.Assert_IsEqual @TestName = N'[Queue] machined lot NOT at MachiningIn (dup dissolved)', @Expected = N'0', @Actual = @InMin;
DROP TABLE #Q;
ROLLBACK;
GO
EXEC test.EndTestFile;
GO
```

- [ ] **Step 2: Run test to verify it fails**

Run: `sqlcmd -S localhost -d MPP_MES_TestScratch -b -I -C -i sql/tests/0030_RouteDriven_Queues/040_Lot_GetLineQueueForOp.sql`
Expected: FAIL — proc not found.

- [ ] **Step 3: Write the proc**

```sql
-- sql/migrations/repeatable/R__Lots_Lot_GetLineQueueForOp.sql
CREATE OR ALTER PROCEDURE Lots.Lot_GetLineQueueForOp
    @LineLocationId BIGINT,
    @StationOpCode  NVARCHAR(30)
AS
BEGIN
    SET NOCOUNT ON;
    SELECT l.Id, l.LotName, l.ItemId, i.PartNumber, l.PieceCount, n.NextOpCode
    FROM Lots.Lot l
    JOIN Lots.LotStatusCode sc ON sc.Id = l.LotStatusId
    JOIN Parts.Item i ON i.Id = l.ItemId
    CROSS APPLY Lots.ufn_LotNextOp(l.Id) n
    OUTER APPLY (
        SELECT MIN(lm.MovedAt) AS ArrivedAt
        FROM Lots.LotMovement lm
        WHERE lm.LotId = l.Id AND lm.ToLocationId = @LineLocationId
    ) arr
    WHERE l.CurrentLocationId = @LineLocationId
      AND sc.Code <> N'Closed'
      AND n.NextOpCode = @StationOpCode
    ORDER BY COALESCE(arr.ArrivedAt, l.CreatedAt) ASC, l.Id ASC;
END;
GO
```

- [ ] **Step 4: Apply + run the test**

Run: apply `R__Lots_Lot_GetLineQueueForOp.sql`, then re-run the Step 2 test.
Expected: both asserts PASS.

- [ ] **Step 5: Commit**

```bash
git add sql/migrations/repeatable/R__Lots_Lot_GetLineQueueForOp.sql sql/tests/0030_RouteDriven_Queues/040_Lot_GetLineQueueForOp.sql
git commit -m "feat(routes): add Lots.Lot_GetLineQueueForOp queue read"
```

---

## Task 5: `ProductionEvent` completed-ops index

**Files:**
- Create: `sql/migrations/versioned/0031_productionevent_nextop_index.sql`
- Test: `sql/tests/0030_RouteDriven_Queues/050_index_present.sql`

**Interfaces:**
- Produces: nonclustered index `IX_ProductionEvent_LotId_Op` on `Workorder.ProductionEvent (LotId)` INCLUDE `(OperationTemplateId, EventAt)`.

- [ ] **Step 1: Write the failing test**

```sql
-- sql/tests/0030_RouteDriven_Queues/050_index_present.sql
SET NOCOUNT ON; SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0030_RouteDriven_Queues/050_index_present.sql';
GO
DECLARE @Has NVARCHAR(10) = CASE WHEN EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_ProductionEvent_LotId_Op' AND object_id = OBJECT_ID('Workorder.ProductionEvent')) THEN N'1' ELSE N'0' END;
EXEC test.Assert_IsEqual @TestName = N'[Idx] completed-ops index present', @Expected = N'1', @Actual = @Has;
GO
EXEC test.EndTestFile;
GO
```

- [ ] **Step 2: Run test to verify it fails** — Expected FAIL (Actual `0`).

- [ ] **Step 3: Create the index**

```sql
-- sql/migrations/versioned/0031_productionevent_nextop_index.sql
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_ProductionEvent_LotId_Op' AND object_id = OBJECT_ID('Workorder.ProductionEvent'))
    CREATE NONCLUSTERED INDEX IX_ProductionEvent_LotId_Op
    ON Workorder.ProductionEvent (LotId) INCLUDE (OperationTemplateId, EventAt);
GO
```

- [ ] **Step 4: Apply + run the test** — Expected PASS.

- [ ] **Step 5: Commit**

```bash
git add sql/migrations/versioned/0031_productionevent_nextop_index.sql sql/tests/0030_RouteDriven_Queues/050_index_present.sql
git commit -m "perf(routes): index ProductionEvent for completed-ops-per-lot"
```

---

## Task 6: Station-level demo routes

**Files:**
- Create: `sql/seeds/031_seed_station_level_routes.sql`
- Test: `sql/tests/0030_RouteDriven_Queues/060_station_routes.sql`

**Interfaces:**
- Produces: a published `RouteTemplate` for `5G0-MACH` (and the RPY cam item) whose steps reference the **station ops** `MachiningIn → MachiningOut → AssemblyIn → AssemblyOut`. This is what `ufn_LotNextOp` (Task 3) resolves against. **NOTE (P-A):** this establishes the route↔event op-alignment; existing coarse routes (`CNC-5G0`, etc.) are left in place for now and reconciled in Plan 2.

- [ ] **Step 1: Write the failing test**

```sql
-- sql/tests/0030_RouteDriven_Queues/060_station_routes.sql
SET NOCOUNT ON; SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0030_RouteDriven_Queues/060_station_routes.sql';
GO
DECLARE @Item BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'5G0-MACH');
DECLARE @Steps INT = (
    SELECT COUNT(*) FROM Parts.RouteStep rs
    JOIN Parts.RouteTemplate rt ON rt.Id = rs.RouteTemplateId AND rt.ItemId = @Item AND rt.PublishedAt IS NOT NULL AND rt.DeprecatedAt IS NULL
    JOIN Parts.OperationTemplate ot ON ot.Id = rs.OperationTemplateId
    WHERE ot.Code IN (N'MachiningIn', N'MachiningOut', N'AssemblyIn', N'AssemblyOut'));
DECLARE @StepsStr NVARCHAR(10) = CAST(@Steps AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[Route] 5G0-MACH has 4 station-op steps', @Expected = N'4', @Actual = @StepsStr;
GO
EXEC test.EndTestFile;
GO
```

- [ ] **Step 2: Run test to verify it fails** — Expected FAIL (`0`).

- [ ] **Step 3: Write the seed** (insert a published RouteTemplate + 4 RouteSteps for `5G0-MACH`)

```sql
-- sql/seeds/031_seed_station_level_routes.sql
SET NOCOUNT ON;
DECLARE @Item BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'5G0-MACH');
IF @Item IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM Parts.RouteTemplate rt JOIN Parts.RouteStep rs ON rs.RouteTemplateId = rt.Id
    JOIN Parts.OperationTemplate ot ON ot.Id = rs.OperationTemplateId
    WHERE rt.ItemId = @Item AND rt.DeprecatedAt IS NULL AND ot.Code = N'MachiningIn')
BEGIN
    DECLARE @Rt BIGINT;
    INSERT INTO Parts.RouteTemplate (ItemId, VersionNumber, Name, PublishedAt, CreatedAt)
    VALUES (@Item, 1, N'5G0-MACH station route', SYSUTCDATETIME(), SYSUTCDATETIME());
    SET @Rt = SCOPE_IDENTITY();
    INSERT INTO Parts.RouteStep (RouteTemplateId, OperationTemplateId, SequenceNumber, IsRequired)
    SELECT @Rt, ot.Id, v.Seq, 1
    FROM (VALUES (N'MachiningIn',1),(N'MachiningOut',2),(N'AssemblyIn',3),(N'AssemblyOut',4)) v(Code, Seq)
    JOIN Parts.OperationTemplate ot ON ot.Code = v.Code AND ot.DeprecatedAt IS NULL;
END
```

*(Adjust `RouteTemplate` column list to the real schema — verify `Parts.RouteTemplate` columns before running; the design references `ItemId, VersionNumber, Name, PublishedAt, DeprecatedAt`.)*

- [ ] **Step 4: Apply + run the test** — Expected PASS.

- [ ] **Step 5: Commit**

```bash
git add sql/seeds/031_seed_station_level_routes.sql sql/tests/0030_RouteDriven_Queues/060_station_routes.sql
git commit -m "feat(routes): seed station-level demo route for 5G0-MACH"
```

---

## Task 7: Ignition read wrapper

**Files:**
- Create: `ignition/projects/Core/ignition/named-query/lots/Lot_GetLineQueueForOp/query.sql` (+ `resource.json` manifest)
- Modify: `ignition/projects/Core/ignition/script-python/BlueRidge/Lots/Lot/code.py` (append `getLineQueueForOp`)

**Interfaces:**
- Consumes: `Lots.Lot_GetLineQueueForOp` (Task 4).
- Produces: `BlueRidge.Lots.Lot.getLineQueueForOp(lineLocationId, stationOpCode, _refreshToken=None)` → `list[dict]`.

- [ ] **Step 1: Create the named query**

```sql
-- .../named-query/lots/Lot_GetLineQueueForOp/query.sql
EXEC Lots.Lot_GetLineQueueForOp @LineLocationId = :lineLocationId, @StationOpCode = :stationOpCode
```
(Author the `resource.json` manifest + params `lineLocationId` BIGINT, `stationOpCode` String, per `ignition-context-pack/04_named_queries.md`.)

- [ ] **Step 2: Append the Jython wrapper**

```python
def getLineQueueForOp(lineLocationId, stationOpCode, _refreshToken=None):
    """Route-driven terminal queue: line lots whose next route op == stationOpCode."""
    BlueRidge.Common.Util.log("getLineQueueForOp line=%s op=%s" % (lineLocationId, stationOpCode))
    return BlueRidge.Common.Db.execList(
        "lots/Lot_GetLineQueueForOp",
        {"lineLocationId": lineLocationId, "stationOpCode": stationOpCode})
```

- [ ] **Step 3: Verify** — load the project in Designer / gateway; confirm the NQ returns rows for a seeded line + `MachiningOut`. (No unit test harness for Jython in-repo; verification is manual per the Ignition file-edit boundary.)

- [ ] **Step 4: Commit**

```bash
git add ignition/projects/Core/ignition/named-query/lots/Lot_GetLineQueueForOp/ ignition/projects/Core/ignition/script-python/BlueRidge/Lots/Lot/code.py
git commit -m "feat(routes): Ignition wrapper for Lot_GetLineQueueForOp"
```

---

## Plan 2 (GATED on OQ-COUPLE + FDS-05-009 + route-granularity sign-off) — outline only

Do **not** detail or build these until sign-off; the FDS decisions can change the procs.

- **T2.1** `TrimOut_Record` → deposit at line; `Location_ListMachiningLines` dropdown source.
- **T2.2** `MachiningIn_PickAndConsume` → mint machined lot at the line.
- **T2.3** MachiningOut mode enum (replace `RequiresSubLotSplit`) + **incremental draw-down** proc (partial `Lot_Split`, child-carries-completion) + atomic/AutoMove route-alignment (P14).
- **T2.4** Assembly stations write `AssemblyIn`/`AssemblyOut` events; `Assembly_ScanIn` repurpose/retire.
- **T2.5** `ContainerTray_Close` → consume from the container cell's parent line at `AssemblyOut`.
- **T2.6** Views: machining/assembly queues → `getLineQueueForOp`; Trim-OUT dropdown → lines; #6 scan+pick gate.
- **T2.7** Retire the coupled auto-move; `CoupledDownstreamCellLocationId` dormant.
- **T2.8** In-flight WIP cell→line migration script + pre-cutover WIP report.
- **T2.9** Reconcile/deprecate the coarse product ops (`CNC-5G0`, `ASSY-FRONT`) now that station routes drive queues.

---

## Self-review notes
- **Spec coverage (Plan 1):** §4.2 assembly ops (T1), §4.3 view→op (T2), §5.1 `ufn_LotNextOp` (T3), §5.2 queue read (T4), §4.6 index (T5), §5.11 station routes / P-A (T6), views wrapper (T7). Plan-2 outline maps §5.3–5.10 + P12/P14.
- **Gaps deferred by design:** all write-side FDS deviations → Plan 2 (sign-off gated).
- **Type consistency:** `NextOpCode`/`NextOpTemplateId` (T3) consumed verbatim by T4; `StationOpCode` values match `ViewOpRegistry` seed (T2) and `OperationTemplate.Code`.
- **Verify-before-build:** confirm `Parts.RouteTemplate` real column list before T6; confirm `Lots.Lot_Create` param names before T3/T4 test fixtures.
