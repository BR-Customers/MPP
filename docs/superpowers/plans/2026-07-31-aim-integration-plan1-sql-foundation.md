# AIM Integration — Plan 1: SQL Foundation

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the database able to hand out part-agnostic AIM shipper IDs and to record, for every completed container, exactly what must be reported to AIM and whether it has been.

**Architecture:** One versioned migration (`0049`) genericizes `Lots.AimShipperIdPool`, adds post-back payload + status columns to it, extends `Lots.AimPoolConfig` with connection and escalation settings, and adds `Parts.Item.AimCustomerPartNumber`. Existing pool procs lose their `@PartNumber` parameter; `Container_Complete` writes the post-back payload inside its existing claim transaction; four new procs serve the post/retry loop and two new accessors serve the Item Master field.

**Tech Stack:** SQL Server 2022, `sqlcmd`, the repo's own SQL test harness (`sql/tests/Run-Tests.ps1`).

**Spec:** `docs/superpowers/specs/2026-07-31-aim-integration-ignition-design.md`
**Interface contract:** `notes/2026-07-28_aim-interface-contract.md`
**Plan 2 (Ignition layer)** depends on every proc signature produced here.

## Global Constraints

- `UpperCamelCase` tables and columns; `BIGINT IDENTITY` surrogate `Id` PKs; `NVARCHAR` never `VARCHAR`; `DATETIME2(3)` never `DATETIME`; `DECIMAL` never `FLOAT`.
- **Timestamps stored UTC, displayed Eastern.** Persist with `SYSUTCDATETIME()`. Any operator-facing read converts at the boundary: `CAST(<col> AT TIME ZONE 'UTC' AT TIME ZONE 'Eastern Standard Time' AS DATETIME2(3))`. **The `CAST` back to `DATETIME2(3)` is mandatory** — a raw `datetimeoffset` breaks the Ignition JDBC read.
- **FDS-11-011 — no `OUTPUT` parameters, ever.** Mutation procs use local variables and end **every** exit path with `SELECT @Status AS Status, @Message AS Message, ...`. **One result set per proc.** Read procs return an empty rowset for not-found; they never invent a 404.
- `RAISERROR` (not `THROW`) in `CATCH` blocks. Schema-qualify every DB reference. `EXEC` parameters must be literals or `@variables` — never inline `CAST` / arithmetic / `CASE`.
- Procs live in `sql/migrations/repeatable/R__<Schema>_<Proc>.sql` as `CREATE OR ALTER`, with the standard header block. Template: `sql/scripts/_TEMPLATE_stored_procedure.sql`.
- Audit `Description` shape: `<SUBJECT> · <CATEGORY?> · <ACTION>` using `Audit.ufn_MidDot()`, wrapped in `Audit.ufn_TruncateActivity(@text)`. `OldValue`/`NewValue` JSON carries resolved-name FK sub-objects.
- **Seed/data string values are ASCII-only.** `sqlcmd` reads `.sql` in the Windows codepage, so em-dashes and middle-dots become mojibake.
- Tests run against **`MPP_MES_Test`** (the runner's default). **Never** point the runner at a `*_Dev` database.
- **Run the suite from Bash, not the PowerShell tool** (sandbox-blocked this session):
  `powershell.exe -NoProfile -File "sql	ests\Run-Tests.ps1" -Filter "<pattern>"`. The runner
  resets `MPP_MES_Test` and applies migrations itself — you do not call `Reset-DevDatabase.ps1`
  separately.

## Test fixture pattern (FIXTURE BLOCK)

`Run-Tests.ps1` resets with `-SkipDemoSeed`, so **`Lots.Container`, `Lots.Lot` and `Parts.Item` are
empty of demo data.** A fixture that does `SELECT TOP 1 Id FROM Lots.Container` gets `NULL` and the
test fails for the wrong reason. Every task below that needs a container **builds its own**, following
`sql/tests/0028_PlantFloor_Assembly/040_Container_Complete_happy.sql` — read that file first.

Where a task says "open with the FIXTURE BLOCK, PART = `X`", paste this verbatim and substitute `X`:

```sql
DECLARE @Now DATETIME2(3) = SYSUTCDATETIME();
IF NOT EXISTS (SELECT 1 FROM Parts.Item WHERE PartNumber = N'X')
    INSERT INTO Parts.Item (ItemTypeId, PartNumber, Description, UomId, CreatedAt, CreatedByUserId)
    VALUES (3, N'X', N'AIM plan-1 test part', 1, @Now, 1);
DECLARE @Item BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'X');

IF NOT EXISTS (SELECT 1 FROM Parts.ContainerConfig WHERE ItemId = @Item AND DeprecatedAt IS NULL)
    INSERT INTO Parts.ContainerConfig (ItemId, TraysPerContainer, PartsPerTray, IsSerialized, ClosureMethod, CreatedAt)
    VALUES (@Item, 1, 15, 0, N'ByCount', @Now);
DECLARE @Config BIGINT = (SELECT TOP 1 Id FROM Parts.ContainerConfig WHERE ItemId = @Item AND DeprecatedAt IS NULL);

DECLARE @Cell BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MA1-COMPBR-AOUT');
DECLARE @UserId BIGINT = 1;

DECLARE @O TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO @O EXEC Lots.Container_Open
    @ItemId = @Item, @ContainerConfigId = @Config, @CellLocationId = @Cell, @AppUserId = @UserId;
DECLARE @ContainerId BIGINT = (SELECT NewId FROM @O);
```

A single-tray `ByCount` config keeps the fixture minimal — no BOM, no staged component LOT, no
per-tray loop. If a task needs the container **full** (Task 3), close its one tray:

```sql
DECLARE @TC TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT, ContainerAccumulatedParts INT);
INSERT INTO @TC EXEC Lots.ContainerTray_Close
    @ContainerId = @ContainerId, @TrayPosition = 1, @PartsCount = 15,
    @ClosureMethod = N'ByCount', @AppUserId = @UserId;
```

Delete your fixture's rows at the top of the file (see `040_Container_Complete_happy.sql`'s opening
`DELETE` block) so re-runs are idempotent.

---

## Baseline warning — read before Task 1

This branch has **7 pre-existing `ERROR running` test files** (`077_Lot_Search`, `050_Lot_GetShiftCavityTally`, `060_Lot_GetWipQueueByLocation`, `070_MachiningOut_Mint`, `100_Lot_GetLineInventoryByPart`, `076_Assembly_ScanIn`, `060_OperatorChange_Log`). The runner already exits non-zero before you start.

**Capture that baseline in Task 0 and diff against it at the end.** An assertion count alone will hide new breakage — a prior status header reported "2151/0" while these seven were already failing.

---

### Task 0: Establish the test baseline

**Files:**
- Create: `sql/scratch/aim_baseline_before.txt` (scratch, not committed)

- [ ] **Step 1: Run the full suite and capture output**

```bash
powershell -File sql/tests/Run-Tests.ps1 > sql/scratch/aim_baseline_before.txt 2>&1
```

- [ ] **Step 2: Extract the failing-file list**

```bash
grep -E "ERROR running|FAIL:" sql/scratch/aim_baseline_before.txt | sort > sql/scratch/aim_baseline_failures.txt
cat sql/scratch/aim_baseline_failures.txt
```

Expected: 7 `ERROR running` lines, 0 `FAIL:` lines. If you see a different set, record it — that is your baseline, not the list above.

- [ ] **Step 3: Do not commit**

`sql/scratch/` holds working files. Leave these two uncommitted; they are compared against in Task 8.

---

### Task 1: Migration 0049 — schema

**Files:**
- Create: `sql/migrations/versioned/0049_aim_pool_generic_and_postback.sql`
- Create: `sql/tests/0049_AimIntegration/010_schema.sql`

**Interfaces:**
- Produces: `Lots.AimShipperIdPool` without `PartNumber`, with `CustomerPartNumber`/`Quantity`/`LotNumber`/`PostedAt`/`PostAttempts`/`LastPostAttemptAt`/`LastPostError`; `Lots.AimPoolConfig` with `AimBaseUrl`/`AimCompanyCode`/`AimPathToken`/`PostWarningAgeMinutes`/`PostCriticalAgeMinutes`; `Parts.Item.AimCustomerPartNumber`.

- [ ] **Step 1: Write the failing test**

Create `sql/tests/0049_AimIntegration/010_schema.sql`:

```sql
-- =============================================
-- File: 0049_AimIntegration/010_schema.sql
-- Desc: Migration 0049 - pool genericized, post-back columns, config columns,
--       Parts.Item.AimCustomerPartNumber.
-- =============================================
EXEC test.BeginTestFile @FileName = N'0049_AimIntegration/010_schema.sql';
GO

DECLARE @Gone NVARCHAR(10) =
    CASE WHEN COL_LENGTH(N'Lots.AimShipperIdPool', N'PartNumber') IS NULL THEN N'1' ELSE N'0' END;
EXEC test.Assert_IsEqual
    @TestName = N'[0049] AimShipperIdPool.PartNumber dropped',
    @Expected = N'1', @Actual = @Gone;

DECLARE @Cols NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10))
    FROM sys.columns WHERE object_id = OBJECT_ID(N'Lots.AimShipperIdPool')
      AND name IN (N'CustomerPartNumber', N'Quantity', N'LotNumber', N'PostedAt',
                   N'PostAttempts', N'LastPostAttemptAt', N'LastPostError'));
EXEC test.Assert_IsEqual
    @TestName = N'[0049] seven post-back columns present',
    @Expected = N'7', @Actual = @Cols;

DECLARE @OldIx NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM sys.indexes
    WHERE object_id = OBJECT_ID(N'Lots.AimShipperIdPool')
      AND name = N'IX_AimShipperIdPool_AvailableByPart');
EXEC test.Assert_IsEqual
    @TestName = N'[0049] per-part index dropped',
    @Expected = N'0', @Actual = @OldIx;

DECLARE @NewIx NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM sys.indexes
    WHERE object_id = OBJECT_ID(N'Lots.AimShipperIdPool')
      AND name IN (N'IX_AimShipperIdPool_Available', N'IX_AimShipperIdPool_Unposted'));
EXEC test.Assert_IsEqual
    @TestName = N'[0049] generic + unposted indexes present',
    @Expected = N'2', @Actual = @NewIx;

DECLARE @Cfg NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10))
    FROM sys.columns WHERE object_id = OBJECT_ID(N'Lots.AimPoolConfig')
      AND name IN (N'AimBaseUrl', N'AimCompanyCode', N'AimPathToken',
                   N'PostWarningAgeMinutes', N'PostCriticalAgeMinutes'));
EXEC test.Assert_IsEqual
    @TestName = N'[0049] five AimPoolConfig columns present',
    @Expected = N'5', @Actual = @Cfg;

DECLARE @ItemCol NVARCHAR(10) =
    CASE WHEN COL_LENGTH(N'Parts.Item', N'AimCustomerPartNumber') IS NOT NULL THEN N'1' ELSE N'0' END;
EXEC test.Assert_IsEqual
    @TestName = N'[0049] Parts.Item.AimCustomerPartNumber present',
    @Expected = N'1', @Actual = @ItemCol;

DECLARE @Defaults NVARCHAR(20) = (SELECT
    CAST(PostWarningAgeMinutes AS NVARCHAR(10)) + N'/' + CAST(PostCriticalAgeMinutes AS NVARCHAR(10))
    FROM Lots.AimPoolConfig WHERE Id = 1);
EXEC test.Assert_IsEqual
    @TestName = N'[0049] escalation defaults 30/120 on the config row',
    @Expected = N'30/120', @Actual = @Defaults;
GO

EXEC test.EndTestFile;
GO
```

- [ ] **Step 2: Run it and verify it fails**

```bash
powershell -File sql/tests/Run-Tests.ps1 -Filter "0049_AimIntegration"
```

Expected: FAIL on every assertion (the columns do not exist yet).

- [ ] **Step 3: Write the migration**

Create `sql/migrations/versioned/0049_aim_pool_generic_and_postback.sql`:

```sql
-- =============================================
-- Migration:   0049_aim_pool_generic_and_postback.sql
-- Author:      Blue Ridge Automation
-- Date:        2026-07-31
-- Description: Makes the AIM shipper-ID pool part-agnostic and gives it a post-back
--              ledger, per the verified AIM contract.
--                * AIM's nextserial.csv accepts NO part parameter - serials are unique
--                  per company code - so the per-part pool (and FDS-07-010's per-part
--                  topup loop) is unimplementable. PartNumber and its filtered index go.
--                * postserial.csv is what actually creates the label in AIM, so every
--                  completed container owes AIM a payload. Those columns plus a posted
--                  flag and retry bookkeeping land on the pool row.
--                * AimPoolConfig gains connection settings (base URL, company code,
--                  path token) and post-backlog age thresholds, distinct from the
--                  existing depth thresholds which mean pool supply.
--                * Parts.Item gains AimCustomerPartNumber - AIM matches on its Customer
--                  Part, which is NOT derivable from our PartNumber.
--              Contract + evidence: notes/2026-07-28_aim-interface-contract.md
-- =============================================

-- ---- 1. Genericize the pool ----
IF EXISTS (SELECT 1 FROM sys.indexes
           WHERE object_id = OBJECT_ID(N'Lots.AimShipperIdPool')
             AND name = N'IX_AimShipperIdPool_AvailableByPart')
    DROP INDEX IX_AimShipperIdPool_AvailableByPart ON Lots.AimShipperIdPool;
GO

IF COL_LENGTH(N'Lots.AimShipperIdPool', N'PartNumber') IS NOT NULL
    ALTER TABLE Lots.AimShipperIdPool DROP COLUMN PartNumber;
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes
               WHERE object_id = OBJECT_ID(N'Lots.AimShipperIdPool')
                 AND name = N'IX_AimShipperIdPool_Available')
    CREATE INDEX IX_AimShipperIdPool_Available
        ON Lots.AimShipperIdPool (FetchedAt) WHERE ConsumedAt IS NULL;
GO

-- ---- 2. Post-back payload + status ----
IF COL_LENGTH(N'Lots.AimShipperIdPool', N'CustomerPartNumber') IS NULL
    ALTER TABLE Lots.AimShipperIdPool ADD
        CustomerPartNumber NVARCHAR(50)  NULL,
        Quantity           INT           NULL,
        LotNumber          NVARCHAR(50)  NULL,
        PostedAt           DATETIME2(3)  NULL,
        PostAttempts       INT           NOT NULL
            CONSTRAINT DF_AimShipperIdPool_PostAttempts DEFAULT 0,
        LastPostAttemptAt  DATETIME2(3)  NULL,
        LastPostError      NVARCHAR(500) NULL;
GO

-- Sweep read: consumed but not yet reported to AIM. Rows leave this index on
-- success, so it stays small.
IF NOT EXISTS (SELECT 1 FROM sys.indexes
               WHERE object_id = OBJECT_ID(N'Lots.AimShipperIdPool')
                 AND name = N'IX_AimShipperIdPool_Unposted')
    CREATE INDEX IX_AimShipperIdPool_Unposted
        ON Lots.AimShipperIdPool (ConsumedAt)
        WHERE ConsumedAt IS NOT NULL AND PostedAt IS NULL;
GO

-- ---- 3. AimPoolConfig: connection + escalation ----
IF COL_LENGTH(N'Lots.AimPoolConfig', N'AimBaseUrl') IS NULL
    ALTER TABLE Lots.AimPoolConfig ADD
        AimBaseUrl             NVARCHAR(200) NULL,
        AimCompanyCode         NVARCHAR(10)  NULL,
        AimPathToken           NVARCHAR(50)  NULL,
        PostWarningAgeMinutes  INT NOT NULL
            CONSTRAINT DF_AimPoolConfig_PostWarnAge DEFAULT 30,
        PostCriticalAgeMinutes INT NOT NULL
            CONSTRAINT DF_AimPoolConfig_PostCritAge DEFAULT 120;
GO

-- ---- 4. Parts.Item: AIM customer part ----
-- NOT derivable from Item.PartNumber. AIM's X-Ref shows 11300R70 A000 -> 11300R7- A000
-- and 112006FBAA000 -> 112006FB A000. Must be stored per item, sourced from AIM.
IF COL_LENGTH(N'Parts.Item', N'AimCustomerPartNumber') IS NULL
    ALTER TABLE Parts.Item ADD AimCustomerPartNumber NVARCHAR(50) NULL;
GO

IF NOT EXISTS (SELECT 1 FROM dbo.SchemaVersion
               WHERE MigrationId = N'0049_aim_pool_generic_and_postback')
    INSERT INTO dbo.SchemaVersion (MigrationId, Description)
    VALUES (N'0049_aim_pool_generic_and_postback',
        N'AIM pool genericized (PartNumber dropped); post-back payload/status columns; AimPoolConfig connection + escalation settings; Parts.Item.AimCustomerPartNumber.');
GO
```

- [ ] **Step 4: Apply and re-run the test**

```bash
powershell -File sql/scripts/Reset-DevDatabase.ps1 -DatabaseName MPP_MES_Test -SkipDemoSeed
powershell -File sql/tests/Run-Tests.ps1 -Filter "0049_AimIntegration"
```

Expected: PASS, 7 assertions.

- [ ] **Step 5: Commit**

```bash
git add sql/migrations/versioned/0049_aim_pool_generic_and_postback.sql sql/tests/0049_AimIntegration/010_schema.sql
git commit -m "feat(sql): migration 0049 - generic AIM pool, post-back ledger, Item.AimCustomerPartNumber"
```

---

### Task 2: Genericize the pool procs

**Files:**
- Modify: `sql/migrations/repeatable/R__Lots_AimShipperIdPool_Claim.sql`
- Modify: `sql/migrations/repeatable/R__Lots_AimShipperIdPool_Topup.sql`
- Modify: `sql/migrations/repeatable/R__Lots_AimShipperIdPool_GetDepth.sql`
- Modify (ALL SEVEN call sites — `@PartNumber` no longer exists):
  - `sql/tests/0028_PlantFloor_Assembly/035_AimPool_claim_topup.sql`
  - `sql/tests/0028_PlantFloor_Assembly/040_Container_Complete_happy.sql`
  - `sql/tests/0028_PlantFloor_Assembly/045_Container_Complete_over_target.sql`
  - `sql/tests/0028_PlantFloor_Assembly/050_Container_Complete_empty_pool_hard_fail.sql`
  - `sql/tests/0028_PlantFloor_Assembly/060_Container_Complete_with_completion_confirm.sql`
  - `sql/tests/0029_PlantFloor_Hold_Sort_Shipping_Aim/030_Container_Ship.sql`
  - `sql/tests/0029_PlantFloor_Hold_Sort_Shipping_Aim/080_ShippingLabel_Void_Reprint.sql`
- Modify (seed/scratch — same reason):
  - `sql/seeds/028_seed_aim_pool_dev.sql`
  - `sql/scratch/seed_demo.sql`
  - `sql/scratch/clear_demo.sql`
  - `sql/scratch/smoke_seed_shipping.sql`

In each caller: drop `@PartNumber = N'...'` from `AimShipperIdPool_Topup` / `_Claim` / `_GetDepth`
calls, and drop `PartNumber` from any direct `INSERT INTO Lots.AimShipperIdPool` or
`WHERE PartNumber = ...` cleanup. `050_Container_Complete_empty_pool_hard_fail.sql` needs care — it
proves the empty-pool hard fail, which is now **global** rather than per-part, so its setup must
leave the *whole* pool empty rather than just one part's rows.

**Interfaces:**
- Consumes: Task 1's schema.
- Produces:
  - `Lots.AimShipperIdPool_Claim @ContainerId BIGINT, @AppUserId BIGINT` -> `SELECT Status BIT, Message NVARCHAR(500), AimShipperId NVARCHAR(50)`
  - `Lots.AimShipperIdPool_Topup @AimShipperId NVARCHAR(50), @FetchedInterfaceLogId BIGINT = NULL` -> `SELECT Status, Message, NewId`
  - `Lots.AimShipperIdPool_GetDepth` (no parameters) -> `SELECT Depth INT, OldestAvailableAt DATETIME2(3)` (one row, ET)

- [ ] **Step 1: Rewrite the existing test for the new signatures**

Replace the body of `sql/tests/0028_PlantFloor_Assembly/035_AimPool_claim_topup.sql` between `BeginTestFile` and `EndTestFile`:

```sql
-- Topup with no part dimension.
DECLARE @T TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO @T EXEC Lots.AimShipperIdPool_Topup
    @AimShipperId = N'000900001', @FetchedInterfaceLogId = NULL;
DECLARE @TopupOk NVARCHAR(10) = (SELECT CAST(Status AS NVARCHAR(10)) FROM @T);
EXEC test.Assert_IsEqual
    @TestName = N'[AimPool] topup accepts an ID with no part number',
    @Expected = N'1', @Actual = @TopupOk;

INSERT INTO @T EXEC Lots.AimShipperIdPool_Topup
    @AimShipperId = N'000900002', @FetchedInterfaceLogId = NULL;

-- Depth is a single global number.
DECLARE @D TABLE (Depth INT, OldestAvailableAt DATETIME2(3));
INSERT INTO @D EXEC Lots.AimShipperIdPool_GetDepth;
DECLARE @DepthRows NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM @D);
EXEC test.Assert_IsEqual
    @TestName = N'[AimPool] GetDepth returns exactly one row',
    @Expected = N'1', @Actual = @DepthRows;

DECLARE @DepthAtLeast NVARCHAR(10) =
    (SELECT CASE WHEN Depth >= 2 THEN N'1' ELSE N'0' END FROM @D);
EXEC test.Assert_IsEqual
    @TestName = N'[AimPool] depth counts both seeded IDs',
    @Expected = N'1', @Actual = @DepthAtLeast;

-- Claim takes no part number and returns the FIFO-oldest available ID.
-- -SkipDemoSeed leaves Lots.Container empty, so open one (FIXTURE BLOCK, PART = 'AIM-P1-T2').
DECLARE @Now DATETIME2(3) = SYSUTCDATETIME();
DECLARE @UserId BIGINT = 1;
IF NOT EXISTS (SELECT 1 FROM Parts.Item WHERE PartNumber = N'AIM-P1-T2')
    INSERT INTO Parts.Item (ItemTypeId, PartNumber, Description, UomId, CreatedAt, CreatedByUserId)
    VALUES (3, N'AIM-P1-T2', N'AIM plan-1 claim fixture part', 1, @Now, 1);
DECLARE @T2Item BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'AIM-P1-T2');
IF NOT EXISTS (SELECT 1 FROM Parts.ContainerConfig WHERE ItemId = @T2Item AND DeprecatedAt IS NULL)
    INSERT INTO Parts.ContainerConfig (ItemId, TraysPerContainer, PartsPerTray, IsSerialized, ClosureMethod, CreatedAt)
    VALUES (@T2Item, 1, 15, 0, N'ByCount', @Now);
DECLARE @T2Config BIGINT = (SELECT TOP 1 Id FROM Parts.ContainerConfig WHERE ItemId = @T2Item AND DeprecatedAt IS NULL);
DECLARE @T2Cell BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MA1-COMPBR-AOUT');
DECLARE @O2 TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO @O2 EXEC Lots.Container_Open
    @ItemId = @T2Item, @ContainerConfigId = @T2Config, @CellLocationId = @T2Cell, @AppUserId = @UserId;
DECLARE @ContainerId BIGINT = (SELECT NewId FROM @O2);
DECLARE @C TABLE (Status BIT, Message NVARCHAR(500), AimShipperId NVARCHAR(50));
INSERT INTO @C EXEC Lots.AimShipperIdPool_Claim
    @ContainerId = @ContainerId, @AppUserId = @UserId;
DECLARE @ClaimOk NVARCHAR(10) = (SELECT CAST(Status AS NVARCHAR(10)) FROM @C);
EXEC test.Assert_IsEqual
    @TestName = N'[AimPool] claim succeeds with no part number',
    @Expected = N'1', @Actual = @ClaimOk;

DECLARE @Claimed NVARCHAR(50) = (SELECT AimShipperId FROM @C);
EXEC test.Assert_IsNotNull
    @TestName = N'[AimPool] claim returns an AimShipperId',
    @Actual = @Claimed;

DECLARE @Consumed NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10))
    FROM Lots.AimShipperIdPool
    WHERE AimShipperId = @Claimed AND ConsumedAt IS NOT NULL
      AND ConsumedByContainerId = @ContainerId);
EXEC test.Assert_IsEqual
    @TestName = N'[AimPool] claimed row is marked consumed and bound to the container',
    @Expected = N'1', @Actual = @Consumed;
```

- [ ] **Step 2: Run it and verify it fails**

```bash
powershell -File sql/tests/Run-Tests.ps1 -Filter "035_AimPool"
```

Expected: `ERROR running` — the procs still require `@PartNumber`.

- [ ] **Step 3: Genericize `_Topup`**

In `R__Lots_AimShipperIdPool_Topup.sql`, the parameter block and insert become:

```sql
CREATE OR ALTER PROCEDURE Lots.AimShipperIdPool_Topup
    @AimShipperId          NVARCHAR(50),
    @FetchedInterfaceLogId BIGINT = NULL
AS
```

```sql
        IF @AimShipperId IS NULL
        BEGIN
            SET @Message = N'Required parameter missing (AimShipperId).';
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
            RETURN;
        END

        IF EXISTS (SELECT 1 FROM Lots.AimShipperIdPool WHERE AimShipperId = @AimShipperId)
        BEGIN
            SET @Message = N'That AIM shipper ID is already in the pool.';
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
            RETURN;
        END

        INSERT INTO Lots.AimShipperIdPool (AimShipperId, FetchedAt, FetchedInterfaceLogId)
        VALUES (@AimShipperId, SYSUTCDATETIME(), @FetchedInterfaceLogId);
        SET @NewId = SCOPE_IDENTITY();
```

Delete the `@PartNumber` parameter and any `@PartNumber IS NULL` validation block. Update the header `Description` to record that the pool is part-agnostic because `nextserial.csv` accepts no part parameter. Keep the existing `UQ_AimShipperIdPool_ShipperId` duplicate guard behaviour — the pre-check above turns a constraint violation into a clean status row.

- [ ] **Step 4: Genericize `_GetDepth`**

Replace the body's `SELECT` with a single-row global read:

```sql
    SELECT
        COUNT(*) AS Depth,
        CAST(MIN(FetchedAt) AT TIME ZONE 'UTC' AT TIME ZONE 'Eastern Standard Time'
             AS DATETIME2(3)) AS OldestAvailableAt
    FROM Lots.AimShipperIdPool
    WHERE ConsumedAt IS NULL;
```

Delete the `@PartNumber` parameter and any `WHERE PartNumber = ...` predicate. The `CAST` back to `DATETIME2(3)` is mandatory — a raw `datetimeoffset` breaks the Ignition JDBC read.

- [ ] **Step 5: Genericize `_Claim`**

In `R__Lots_AimShipperIdPool_Claim.sql`: delete the `@PartNumber NVARCHAR(50),` parameter and its `IS NULL` validation block. Change the empty-pool pre-check and the claim CTE to drop the part predicate:

```sql
        -- OI-33 hard-fail: empty pool -> reject BEFORE opening a tran (no ROLLBACK hazard).
        IF NOT EXISTS (SELECT 1 FROM Lots.AimShipperIdPool WHERE ConsumedAt IS NULL)
        BEGIN
            SET @Message = N'AIM shipper ID pool is empty.';
            SELECT @Status AS Status, @Message AS Message, @AimShipperId AS AimShipperId;
            RETURN;
        END

        BEGIN TRANSACTION;

        ;WITH c AS (
            SELECT TOP 1 Id, AimShipperId, ConsumedAt, ConsumedByContainerId, ConsumedByUserId
            FROM Lots.AimShipperIdPool WITH (ROWLOCK, UPDLOCK, READPAST)
            WHERE ConsumedAt IS NULL
            ORDER BY FetchedAt, Id)
        UPDATE c
            SET ConsumedAt = SYSUTCDATETIME(), ConsumedByContainerId = @ContainerId,
                ConsumedByUserId = @AppUserId
        OUTPUT inserted.Id, inserted.AimShipperId INTO @claimed (Id, AimShipperId);
```

Leave the `READPAST` hint and the lost-race handling exactly as they are — concurrency behaviour is unchanged, only the filter narrows.

- [ ] **Step 6: Apply and re-run**

```bash
powershell -File sql/scripts/Reset-DevDatabase.ps1 -DatabaseName MPP_MES_Test -SkipDemoSeed
powershell -File sql/tests/Run-Tests.ps1 -Filter "035_AimPool"
```

Expected: PASS, 6 assertions.

- [ ] **Step 7: Commit**

```bash
git add sql/migrations/repeatable/R__Lots_AimShipperIdPool_Claim.sql sql/migrations/repeatable/R__Lots_AimShipperIdPool_Topup.sql sql/migrations/repeatable/R__Lots_AimShipperIdPool_GetDepth.sql sql/tests/0028_PlantFloor_Assembly/035_AimPool_claim_topup.sql
git commit -m "feat(sql): AIM pool procs go part-agnostic (nextserial.csv takes no part)"
```

---

### Task 3: `Container_Complete` — drop the part predicate, write the payload

**Files:**
- Modify: `sql/migrations/repeatable/R__Lots_Container_Complete.sql`
- Create: `sql/tests/0049_AimIntegration/020_Container_Complete_payload.sql`

**Interfaces:**
- Consumes: Task 1 columns; Task 2's genericized claim semantics.
- Produces: `Lots.Container_Complete` **result-set shape unchanged** — still `SELECT Status, Message, ShippingLabelId, AimShipperId`. Side effect added: the claimed pool row carries `CustomerPartNumber`, `Quantity`, `LotNumber`.

> **Do not add columns to this proc's terminal `SELECT`.** Every fixed-shape `INSERT-EXEC` capture in the suite would break for no benefit — the post path re-reads what it needs.

- [ ] **Step 1: Write the failing test**

Create `sql/tests/0049_AimIntegration/020_Container_Complete_payload.sql`:

```sql
-- =============================================
-- File: 0049_AimIntegration/020_Container_Complete_payload.sql
-- Desc: Container_Complete stamps the AIM post-back payload onto the claimed
--       pool row, inside the claim transaction, without changing its result shape.
-- =============================================
EXEC test.BeginTestFile @FileName = N'0049_AimIntegration/020_Container_Complete_payload.sql';
GO

-- Arrange: build our own container (Run-Tests resets with -SkipDemoSeed, so
-- Lots.Container is EMPTY). FIXTURE BLOCK, PART = 'AIM-P1-T3'.
DELETE FROM Lots.AimShipperIdPool WHERE AimShipperId LIKE N'0009%';
DELETE tr FROM Lots.ContainerTray tr INNER JOIN Lots.Container ct ON ct.Id = tr.ContainerId
    INNER JOIN Parts.Item i ON i.Id = ct.ItemId WHERE i.PartNumber = N'AIM-P1-T3';
DELETE FROM Lots.Container WHERE ItemId IN (SELECT Id FROM Parts.Item WHERE PartNumber = N'AIM-P1-T3');

DECLARE @Now DATETIME2(3) = SYSUTCDATETIME();
IF NOT EXISTS (SELECT 1 FROM Parts.Item WHERE PartNumber = N'AIM-P1-T3')
    INSERT INTO Parts.Item (ItemTypeId, PartNumber, Description, UomId, CreatedAt, CreatedByUserId)
    VALUES (3, N'AIM-P1-T3', N'AIM plan-1 test part', 1, @Now, 1);
DECLARE @ItemId BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'AIM-P1-T3');
UPDATE Parts.Item SET AimCustomerPartNumber = N'112006FB A000' WHERE Id = @ItemId;

IF NOT EXISTS (SELECT 1 FROM Parts.ContainerConfig WHERE ItemId = @ItemId AND DeprecatedAt IS NULL)
    INSERT INTO Parts.ContainerConfig (ItemId, TraysPerContainer, PartsPerTray, IsSerialized, ClosureMethod, CreatedAt)
    VALUES (@ItemId, 1, 15, 0, N'ByCount', @Now);
DECLARE @Config BIGINT = (SELECT TOP 1 Id FROM Parts.ContainerConfig WHERE ItemId = @ItemId AND DeprecatedAt IS NULL);

DECLARE @Cell BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MA1-COMPBR-AOUT');
DECLARE @UserId BIGINT = 1;

DECLARE @O TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO @O EXEC Lots.Container_Open
    @ItemId = @ItemId, @ContainerConfigId = @Config, @CellLocationId = @Cell, @AppUserId = @UserId;
DECLARE @ContainerId BIGINT = (SELECT NewId FROM @O);

DECLARE @TC TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT, ContainerAccumulatedParts INT);
INSERT INTO @TC EXEC Lots.ContainerTray_Close
    @ContainerId = @ContainerId, @TrayPosition = 1, @PartsCount = 15,
    @ClosureMethod = N'ByCount', @AppUserId = @UserId;

INSERT INTO Lots.AimShipperIdPool (AimShipperId, FetchedAt)
VALUES (N'000900101', SYSUTCDATETIME());

-- Act
DECLARE @R TABLE (Status BIT, Message NVARCHAR(500), ShippingLabelId BIGINT, AimShipperId NVARCHAR(50));
INSERT INTO @R EXEC Lots.Container_Complete
    @ContainerId = @ContainerId, @AppUserId = @UserId, @TerminalLocationId = NULL;

DECLARE @Ok NVARCHAR(10) = (SELECT CAST(Status AS NVARCHAR(10)) FROM @R);
EXEC test.Assert_IsEqual
    @TestName = N'[0049] Container_Complete succeeds',
    @Expected = N'1', @Actual = @Ok;

DECLARE @Serial NVARCHAR(50) = (SELECT AimShipperId FROM @R);

-- Assert: payload written on the claimed pool row.
DECLARE @Part NVARCHAR(50) = (SELECT CustomerPartNumber FROM Lots.AimShipperIdPool
                              WHERE AimShipperId = @Serial);
EXEC test.Assert_IsEqual
    @TestName = N'[0049] claimed row carries the AIM customer part',
    @Expected = N'112006FB A000', @Actual = @Part;

DECLARE @QtyOk NVARCHAR(10) = (SELECT CASE WHEN p.Quantity =
        (SELECT ISNULL(SUM(t.PartsClosedCount), 0) FROM Lots.ContainerTray t
         WHERE t.ContainerId = @ContainerId AND t.ClosedAt IS NOT NULL)
    THEN N'1' ELSE N'0' END
    FROM Lots.AimShipperIdPool p WHERE p.AimShipperId = @Serial);
EXEC test.Assert_IsEqual
    @TestName = N'[0049] quantity equals the sum of closed tray counts',
    @Expected = N'1', @Actual = @QtyOk;

DECLARE @Lot NVARCHAR(50) = (SELECT LotNumber FROM Lots.AimShipperIdPool
                             WHERE AimShipperId = @Serial);
EXEC test.Assert_IsNotNull
    @TestName = N'[0049] lot number captured from the first tray FG LOT',
    @Actual = @Lot;

DECLARE @NotPosted NVARCHAR(10) = (SELECT CASE WHEN PostedAt IS NULL AND PostAttempts = 0
    THEN N'1' ELSE N'0' END FROM Lots.AimShipperIdPool WHERE AimShipperId = @Serial);
EXEC test.Assert_IsEqual
    @TestName = N'[0049] row starts owed - PostedAt null, attempts zero',
    @Expected = N'1', @Actual = @NotPosted;
GO

EXEC test.EndTestFile;
GO
```

- [ ] **Step 2: Run it and verify it fails**

```bash
powershell -File sql/tests/Run-Tests.ps1 -Filter "020_Container_Complete_payload"
```

Expected: FAIL — `CustomerPartNumber` is null; the proc does not write it yet.

- [ ] **Step 3: Update the proc**

In `R__Lots_Container_Complete.sql`, change the empty-pool pre-check to drop the part predicate:

```sql
        IF NOT EXISTS (SELECT 1 FROM Lots.AimShipperIdPool WHERE ConsumedAt IS NULL)
        BEGIN
            SET @Message = N'AIM shipper ID pool is empty.';
            SELECT @Status AS Status, @Message AS Message, @ShippingLabelId AS ShippingLabelId, @AimShipperId AS AimShipperId;
            RETURN;
        END
```

Drop `AND PartNumber = @PartNumber` from the claim CTE's `WHERE`. Then, immediately after `SELECT @ClaimedPoolId = Id, @AimShipperId = AimShipperId FROM @claimed;` and **inside the open transaction**, add:

```sql
        -- AIM post-back payload, frozen at completion. Written in the same transaction
        -- as the claim: a rolled-back container never leaves a row owed to AIM.
        DECLARE @PostQty  INT = (SELECT ISNULL(SUM(t.PartsClosedCount), 0)
                                 FROM Lots.ContainerTray t
                                 WHERE t.ContainerId = @ContainerId AND t.ClosedAt IS NOT NULL);
        DECLARE @PostLot  NVARCHAR(50) = (SELECT TOP 1 l.LotName
                                          FROM Lots.ContainerTray t
                                          INNER JOIN Lots.Lot l ON l.Id = t.FinishedGoodLotId
                                          WHERE t.ContainerId = @ContainerId
                                          ORDER BY t.TrayPosition);
        DECLARE @PostPart NVARCHAR(50) = (SELECT i.AimCustomerPartNumber
                                          FROM Lots.Container c
                                          INNER JOIN Parts.Item i ON i.Id = c.ItemId
                                          WHERE c.Id = @ContainerId);

        UPDATE Lots.AimShipperIdPool
           SET CustomerPartNumber = @PostPart,
               Quantity           = @PostQty,
               LotNumber          = @PostLot
         WHERE Id = @ClaimedPoolId;
```

`@PostPart` may legitimately be `NULL` — that is the config-gap case, surfaced by Plan 2 as a modal. It must **not** block completion.

- [ ] **Step 4: Apply and re-run**

```bash
powershell -File sql/scripts/Reset-DevDatabase.ps1 -DatabaseName MPP_MES_Test -SkipDemoSeed
powershell -File sql/tests/Run-Tests.ps1 -Filter "0049_AimIntegration"
```

Expected: PASS, 12 assertions across both files.

- [ ] **Step 5: Run the neighbouring container suite for shape regressions**

```bash
powershell -File sql/tests/Run-Tests.ps1 -Filter "0028_PlantFloor_Assembly"
```

Expected: no new `ERROR running` beyond the Task 0 baseline. If one appears, a fixed-shape `INSERT-EXEC` capture broke — fix the capture, not the proc.

- [ ] **Step 6: Commit**

```bash
git add sql/migrations/repeatable/R__Lots_Container_Complete.sql sql/tests/0049_AimIntegration/020_Container_Complete_payload.sql
git commit -m "feat(sql): Container_Complete writes the AIM post-back payload in-transaction"
```

---

### Task 4: Post-back read/write procs

**Files:**
- Create: `sql/migrations/repeatable/R__Lots_AimShipperIdPool_GetForPost.sql`
- Create: `sql/migrations/repeatable/R__Lots_AimShipperIdPool_RecordPostResult.sql`
- Create: `sql/migrations/repeatable/R__Lots_AimShipperIdPool_ListUnposted.sql`
- Create: `sql/tests/0049_AimIntegration/030_postback_procs.sql`

**Interfaces:**
- Produces:
  - `Lots.AimShipperIdPool_GetForPost @AimShipperId NVARCHAR(50)` -> `SELECT Id, AimShipperId, CustomerPartNumber, Quantity, LotNumber, PostedAt, PostAttempts` (empty rowset = not found)
  - `Lots.AimShipperIdPool_RecordPostResult @Id BIGINT, @Success BIT, @Error NVARCHAR(500) = NULL` -> `SELECT Status, Message`
  - `Lots.AimShipperIdPool_ListUnposted @Top INT = 50` -> `SELECT Id, AimShipperId, ContainerId, CustomerPartNumber, Quantity, LotNumber, PostAttempts, LastPostError, ConsumedAtEt, LastPostAttemptAtEt, AgeMinutes`

- [ ] **Step 1: Write the failing test**

Create `sql/tests/0049_AimIntegration/030_postback_procs.sql`:

```sql
-- =============================================
-- File: 0049_AimIntegration/030_postback_procs.sql
-- Desc: GetForPost / RecordPostResult / ListUnposted round-trip.
-- =============================================
EXEC test.BeginTestFile @FileName = N'0049_AimIntegration/030_postback_procs.sql';
GO

-- Run-Tests resets with -SkipDemoSeed: Lots.Container is EMPTY. Open our own
-- (FIXTURE BLOCK, PART = 'AIM-P1-FK'); this task only needs a valid container FK.
DECLARE @Now DATETIME2(3) = SYSUTCDATETIME();
DECLARE @UserId BIGINT = 1;
IF NOT EXISTS (SELECT 1 FROM Parts.Item WHERE PartNumber = N'AIM-P1-FK')
    INSERT INTO Parts.Item (ItemTypeId, PartNumber, Description, UomId, CreatedAt, CreatedByUserId)
    VALUES (3, N'AIM-P1-FK', N'AIM plan-1 FK fixture part', 1, @Now, 1);
DECLARE @FkItem BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'AIM-P1-FK');
IF NOT EXISTS (SELECT 1 FROM Parts.ContainerConfig WHERE ItemId = @FkItem AND DeprecatedAt IS NULL)
    INSERT INTO Parts.ContainerConfig (ItemId, TraysPerContainer, PartsPerTray, IsSerialized, ClosureMethod, CreatedAt)
    VALUES (@FkItem, 1, 15, 0, N'ByCount', @Now);
DECLARE @FkConfig BIGINT = (SELECT TOP 1 Id FROM Parts.ContainerConfig WHERE ItemId = @FkItem AND DeprecatedAt IS NULL);
DECLARE @FkCell BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MA1-COMPBR-AOUT');
DECLARE @O TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO @O EXEC Lots.Container_Open
    @ItemId = @FkItem, @ContainerConfigId = @FkConfig, @CellLocationId = @FkCell, @AppUserId = @UserId;
DECLARE @ContainerId BIGINT = (SELECT NewId FROM @O);

INSERT INTO Lots.AimShipperIdPool
    (AimShipperId, FetchedAt, ConsumedAt, ConsumedByContainerId, ConsumedByUserId,
     CustomerPartNumber, Quantity, LotNumber)
VALUES
    (N'000900201', SYSUTCDATETIME(), SYSUTCDATETIME(), @ContainerId, @UserId,
     N'112006FB A000', 15, N'000900201');
DECLARE @PoolId BIGINT = SCOPE_IDENTITY();

-- GetForPost returns the payload.
DECLARE @G TABLE (Id BIGINT, AimShipperId NVARCHAR(50), CustomerPartNumber NVARCHAR(50),
                  Quantity INT, LotNumber NVARCHAR(50), PostedAt DATETIME2(3), PostAttempts INT);
INSERT INTO @G EXEC Lots.AimShipperIdPool_GetForPost @AimShipperId = N'000900201';
DECLARE @GotPart NVARCHAR(50) = (SELECT CustomerPartNumber FROM @G);
EXEC test.Assert_IsEqual
    @TestName = N'[0049] GetForPost returns the customer part',
    @Expected = N'112006FB A000', @Actual = @GotPart;

-- Unknown serial returns an empty rowset, not an error.
DELETE FROM @G;
INSERT INTO @G EXEC Lots.AimShipperIdPool_GetForPost @AimShipperId = N'999999999';
DECLARE @NoRows NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM @G);
EXEC test.Assert_IsEqual
    @TestName = N'[0049] GetForPost returns empty for an unknown serial',
    @Expected = N'0', @Actual = @NoRows;

-- ListUnposted sees it.
DECLARE @L TABLE (Id BIGINT, AimShipperId NVARCHAR(50), ContainerId BIGINT,
                  CustomerPartNumber NVARCHAR(50), Quantity INT, LotNumber NVARCHAR(50),
                  PostAttempts INT, LastPostError NVARCHAR(500),
                  ConsumedAtEt DATETIME2(3), LastPostAttemptAtEt DATETIME2(3), AgeMinutes INT);
INSERT INTO @L EXEC Lots.AimShipperIdPool_ListUnposted @Top = 50;
DECLARE @Listed NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM @L WHERE Id = @PoolId);
EXEC test.Assert_IsEqual
    @TestName = N'[0049] ListUnposted includes an owed row',
    @Expected = N'1', @Actual = @Listed;

-- Failure path: attempts increment, error recorded, still owed.
DECLARE @RR TABLE (Status BIT, Message NVARCHAR(500));
INSERT INTO @RR EXEC Lots.AimShipperIdPool_RecordPostResult
    @Id = @PoolId, @Success = 0, @Error = N'AIM rejected: echo';
DECLARE @Attempts NVARCHAR(10) = (SELECT CAST(PostAttempts AS NVARCHAR(10))
    FROM Lots.AimShipperIdPool WHERE Id = @PoolId);
EXEC test.Assert_IsEqual
    @TestName = N'[0049] failed post increments PostAttempts',
    @Expected = N'1', @Actual = @Attempts;

DECLARE @Err NVARCHAR(500) = (SELECT LastPostError FROM Lots.AimShipperIdPool WHERE Id = @PoolId);
EXEC test.Assert_IsEqual
    @TestName = N'[0049] failed post records the error',
    @Expected = N'AIM rejected: echo', @Actual = @Err;

DECLARE @StillOwed NVARCHAR(10) = (SELECT CASE WHEN PostedAt IS NULL THEN N'1' ELSE N'0' END
    FROM Lots.AimShipperIdPool WHERE Id = @PoolId);
EXEC test.Assert_IsEqual
    @TestName = N'[0049] failed post leaves the row owed',
    @Expected = N'1', @Actual = @StillOwed;

-- Success path: PostedAt stamped, row leaves the unposted list.
DELETE FROM @RR;
INSERT INTO @RR EXEC Lots.AimShipperIdPool_RecordPostResult
    @Id = @PoolId, @Success = 1, @Error = NULL;
DECLARE @Posted NVARCHAR(10) = (SELECT CASE WHEN PostedAt IS NOT NULL THEN N'1' ELSE N'0' END
    FROM Lots.AimShipperIdPool WHERE Id = @PoolId);
EXEC test.Assert_IsEqual
    @TestName = N'[0049] successful post stamps PostedAt',
    @Expected = N'1', @Actual = @Posted;

DELETE FROM @L;
INSERT INTO @L EXEC Lots.AimShipperIdPool_ListUnposted @Top = 50;
DECLARE @GoneFromList NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM @L WHERE Id = @PoolId);
EXEC test.Assert_IsEqual
    @TestName = N'[0049] posted row leaves the unposted list',
    @Expected = N'0', @Actual = @GoneFromList;
GO

EXEC test.EndTestFile;
GO
```

- [ ] **Step 2: Run it and verify it fails**

```bash
powershell -File sql/tests/Run-Tests.ps1 -Filter "030_postback_procs"
```

Expected: `ERROR running` — the procs do not exist.

- [ ] **Step 3: Create `_GetForPost`**

```sql
-- ============================================================
-- Repeatable:  R__Lots_AimShipperIdPool_GetForPost.sql
-- Author:      Blue Ridge Automation
-- Version:     1.0
-- Description: Reads one pool row's AIM post-back payload by shipper ID, for
--              BlueRidge.Lots.AimPost.postOne. Re-read on EVERY attempt (not
--              cached by the caller) so a config-gap row self-heals the moment
--              Parts.Item.AimCustomerPartNumber is filled in. Read proc: empty
--              rowset = not found, no invented 404. No OUTPUT params.
-- ============================================================
CREATE OR ALTER PROCEDURE Lots.AimShipperIdPool_GetForPost
    @AimShipperId NVARCHAR(50)
AS
BEGIN
    SET NOCOUNT ON;

    IF @AimShipperId IS NULL
        RETURN;

    SELECT
        p.Id                 AS Id,
        p.AimShipperId       AS AimShipperId,
        p.CustomerPartNumber AS CustomerPartNumber,
        p.Quantity           AS Quantity,
        p.LotNumber          AS LotNumber,
        p.PostedAt           AS PostedAt,
        p.PostAttempts       AS PostAttempts
    FROM Lots.AimShipperIdPool p
    WHERE p.AimShipperId = @AimShipperId;
END;
GO
```

- [ ] **Step 4: Create `_RecordPostResult`**

```sql
-- ============================================================
-- Repeatable:  R__Lots_AimShipperIdPool_RecordPostResult.sql
-- Author:      Blue Ridge Automation
-- Version:     1.0
-- Description: Records the outcome of one AIM postserial.csv attempt. Success
--              stamps PostedAt (the row leaves the unposted index); failure
--              increments PostAttempts and stores the reply text. Always bumps
--              LastPostAttemptAt. No OUTPUT params; single terminal SELECT.
--              RAISERROR in the CATCH.
-- ============================================================
CREATE OR ALTER PROCEDURE Lots.AimShipperIdPool_RecordPostResult
    @Id      BIGINT,
    @Success BIT,
    @Error   NVARCHAR(500) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Status  BIT           = 0;
    DECLARE @Message NVARCHAR(500) = N'Unknown error';

    BEGIN TRY
        IF @Id IS NULL
        BEGIN
            SET @Message = N'Required parameter missing (Id).';
            SELECT @Status AS Status, @Message AS Message;
            RETURN;
        END

        IF NOT EXISTS (SELECT 1 FROM Lots.AimShipperIdPool WHERE Id = @Id)
        BEGIN
            SET @Message = N'AIM pool row not found.';
            SELECT @Status AS Status, @Message AS Message;
            RETURN;
        END

        UPDATE Lots.AimShipperIdPool
           SET PostedAt          = CASE WHEN @Success = 1 THEN SYSUTCDATETIME() ELSE PostedAt END,
               PostAttempts      = PostAttempts + 1,
               LastPostAttemptAt = SYSUTCDATETIME(),
               LastPostError     = CASE WHEN @Success = 1 THEN NULL ELSE @Error END
         WHERE Id = @Id;

        SET @Status  = 1;
        SET @Message = CASE WHEN @Success = 1
                            THEN N'AIM post recorded as successful.'
                            ELSE N'AIM post failure recorded.' END;
        SELECT @Status AS Status, @Message AS Message;
    END TRY
    BEGIN CATCH
        DECLARE @ErrMsg NVARCHAR(2000) = ERROR_MESSAGE();
        SET @Status  = 0;
        SET @Message = N'Failed to record AIM post result.';
        SELECT @Status AS Status, @Message AS Message;
        RAISERROR (@ErrMsg, 16, 1);
    END CATCH
END;
GO
```

- [ ] **Step 5: Create `_ListUnposted`**

```sql
-- ============================================================
-- Repeatable:  R__Lots_AimShipperIdPool_ListUnposted.sql
-- Author:      Blue Ridge Automation
-- Version:     1.0
-- Description: Rows owed to AIM - consumed but not yet reported. Serves BOTH the
--              retry sweep (BlueRidge.Lots.AimPost.retryTick) and the supervisor
--              list on /aim-pool. Oldest-first; order is a fairness choice only,
--              NOT a requirement - AIM accepts serials in any order (verified
--              2026-07-31). Timestamps returned in ET for display. Read proc:
--              empty rowset when nothing is owed.
-- ============================================================
CREATE OR ALTER PROCEDURE Lots.AimShipperIdPool_ListUnposted
    @Top INT = 50
AS
BEGIN
    SET NOCOUNT ON;

    IF @Top IS NULL OR @Top < 1
        SET @Top = 50;

    SELECT TOP (@Top)
        p.Id                    AS Id,
        p.AimShipperId          AS AimShipperId,
        p.ConsumedByContainerId AS ContainerId,
        p.CustomerPartNumber    AS CustomerPartNumber,
        p.Quantity              AS Quantity,
        p.LotNumber             AS LotNumber,
        p.PostAttempts          AS PostAttempts,
        p.LastPostError         AS LastPostError,
        CAST(p.ConsumedAt AT TIME ZONE 'UTC' AT TIME ZONE 'Eastern Standard Time'
             AS DATETIME2(3)) AS ConsumedAtEt,
        CAST(p.LastPostAttemptAt AT TIME ZONE 'UTC' AT TIME ZONE 'Eastern Standard Time'
             AS DATETIME2(3)) AS LastPostAttemptAtEt,
        DATEDIFF(MINUTE, p.ConsumedAt, SYSUTCDATETIME()) AS AgeMinutes
    FROM Lots.AimShipperIdPool p
    WHERE p.ConsumedAt IS NOT NULL AND p.PostedAt IS NULL
    ORDER BY p.ConsumedAt, p.Id;
END;
GO
```

- [ ] **Step 6: Apply and re-run**

```bash
powershell -File sql/scripts/Reset-DevDatabase.ps1 -DatabaseName MPP_MES_Test -SkipDemoSeed
powershell -File sql/tests/Run-Tests.ps1 -Filter "0049_AimIntegration"
```

Expected: PASS, 21 assertions across the three files.

- [ ] **Step 7: Commit**

```bash
git add sql/migrations/repeatable/R__Lots_AimShipperIdPool_GetForPost.sql sql/migrations/repeatable/R__Lots_AimShipperIdPool_RecordPostResult.sql sql/migrations/repeatable/R__Lots_AimShipperIdPool_ListUnposted.sql sql/tests/0049_AimIntegration/030_postback_procs.sql
git commit -m "feat(sql): AIM post-back read/record/list procs"
```

---

### Task 5: `_MarkPosted` — human-confirmed resolution

**Files:**
- Create: `sql/migrations/repeatable/R__Lots_AimShipperIdPool_MarkPosted.sql`
- Create: `sql/tests/0049_AimIntegration/040_MarkPosted.sql`

**Interfaces:**
- Produces: `Lots.AimShipperIdPool_MarkPosted @Id BIGINT, @AppUserId BIGINT, @Note NVARCHAR(500)` -> `SELECT Status, Message`

**Why this exists:** if AIM accepts a post but the reply is lost, retry gets the rejection echo forever — safe, but never self-healing, and AIM exposes no query endpoint. A supervisor confirms the label on AIM's Unshipped Labels report and marks it posted. It asserts something the MES cannot verify, so it is audited as a human decision.

- [ ] **Step 1: Write the failing test**

Create `sql/tests/0049_AimIntegration/040_MarkPosted.sql`:

```sql
-- =============================================
-- File: 0049_AimIntegration/040_MarkPosted.sql
-- Desc: MarkPosted stamps PostedAt with audit attribution and rejects re-marking.
-- =============================================
EXEC test.BeginTestFile @FileName = N'0049_AimIntegration/040_MarkPosted.sql';
GO

-- Run-Tests resets with -SkipDemoSeed: Lots.Container is EMPTY. Open our own
-- (FIXTURE BLOCK, PART = 'AIM-P1-FK'); this task only needs a valid container FK.
DECLARE @Now DATETIME2(3) = SYSUTCDATETIME();
DECLARE @UserId BIGINT = 1;
IF NOT EXISTS (SELECT 1 FROM Parts.Item WHERE PartNumber = N'AIM-P1-FK')
    INSERT INTO Parts.Item (ItemTypeId, PartNumber, Description, UomId, CreatedAt, CreatedByUserId)
    VALUES (3, N'AIM-P1-FK', N'AIM plan-1 FK fixture part', 1, @Now, 1);
DECLARE @FkItem BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'AIM-P1-FK');
IF NOT EXISTS (SELECT 1 FROM Parts.ContainerConfig WHERE ItemId = @FkItem AND DeprecatedAt IS NULL)
    INSERT INTO Parts.ContainerConfig (ItemId, TraysPerContainer, PartsPerTray, IsSerialized, ClosureMethod, CreatedAt)
    VALUES (@FkItem, 1, 15, 0, N'ByCount', @Now);
DECLARE @FkConfig BIGINT = (SELECT TOP 1 Id FROM Parts.ContainerConfig WHERE ItemId = @FkItem AND DeprecatedAt IS NULL);
DECLARE @FkCell BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MA1-COMPBR-AOUT');
DECLARE @O TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO @O EXEC Lots.Container_Open
    @ItemId = @FkItem, @ContainerConfigId = @FkConfig, @CellLocationId = @FkCell, @AppUserId = @UserId;
DECLARE @ContainerId BIGINT = (SELECT NewId FROM @O);

INSERT INTO Lots.AimShipperIdPool
    (AimShipperId, FetchedAt, ConsumedAt, ConsumedByContainerId, ConsumedByUserId,
     CustomerPartNumber, Quantity, LotNumber, PostAttempts, LastPostError)
VALUES
    (N'000900301', SYSUTCDATETIME(), SYSUTCDATETIME(), @ContainerId, @UserId,
     N'112006FB A000', 15, N'000900301', 12, N'AIM rejected: echo');
DECLARE @PoolId BIGINT = SCOPE_IDENTITY();

DECLARE @M TABLE (Status BIT, Message NVARCHAR(500));
INSERT INTO @M EXEC Lots.AimShipperIdPool_MarkPosted
    @Id = @PoolId, @AppUserId = @UserId,
    @Note = N'Confirmed on AIM Unshipped Labels report';
DECLARE @Ok NVARCHAR(10) = (SELECT CAST(Status AS NVARCHAR(10)) FROM @M);
EXEC test.Assert_IsEqual
    @TestName = N'[0049] MarkPosted succeeds on an owed row',
    @Expected = N'1', @Actual = @Ok;

DECLARE @Posted NVARCHAR(10) = (SELECT CASE WHEN PostedAt IS NOT NULL THEN N'1' ELSE N'0' END
    FROM Lots.AimShipperIdPool WHERE Id = @PoolId);
EXEC test.Assert_IsEqual
    @TestName = N'[0049] MarkPosted stamps PostedAt',
    @Expected = N'1', @Actual = @Posted;

DECLARE @Audited NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10))
    FROM Audit.ConfigLog
    WHERE Description LIKE N'%000900301%' AND Description LIKE N'%Marked Posted%');
EXEC test.Assert_IsEqual
    @TestName = N'[0049] MarkPosted writes an audit row naming the serial',
    @Expected = N'1', @Actual = @Audited;

-- Re-marking an already-posted row is rejected.
DELETE FROM @M;
INSERT INTO @M EXEC Lots.AimShipperIdPool_MarkPosted
    @Id = @PoolId, @AppUserId = @UserId, @Note = N'again';
DECLARE @Rejected NVARCHAR(10) = (SELECT CAST(Status AS NVARCHAR(10)) FROM @M);
EXEC test.Assert_IsEqual
    @TestName = N'[0049] MarkPosted rejects an already-posted row',
    @Expected = N'0', @Actual = @Rejected;
GO

EXEC test.EndTestFile;
GO
```

- [ ] **Step 2: Run it and verify it fails**

```bash
powershell -File sql/tests/Run-Tests.ps1 -Filter "040_MarkPosted"
```

Expected: `ERROR running` — the proc does not exist.

- [ ] **Step 3: Create the proc**

```sql
-- ============================================================
-- Repeatable:  R__Lots_AimShipperIdPool_MarkPosted.sql
-- Author:      Blue Ridge Automation
-- Version:     1.0
-- Description: Human-confirmed resolution for a row stuck owed to AIM. If AIM
--              accepted a post but the reply was lost, retry gets the rejection
--              echo forever and AIM has no query endpoint to disambiguate - so a
--              supervisor confirms the label on AIM's Unshipped Labels report and
--              marks it posted here. Asserts something the MES cannot verify, so
--              it is audited as a human decision with the supervisor's note.
--              Rejects an already-posted row. No OUTPUT params; single terminal
--              SELECT. RAISERROR in the CATCH.
-- ============================================================
CREATE OR ALTER PROCEDURE Lots.AimShipperIdPool_MarkPosted
    @Id        BIGINT,
    @AppUserId BIGINT,
    @Note      NVARCHAR(500)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Status   BIT           = 0;
    DECLARE @Message  NVARCHAR(500) = N'Unknown error';
    DECLARE @Serial   NVARCHAR(50);
    DECLARE @Activity NVARCHAR(500);
    DECLARE @NewValue NVARCHAR(MAX);

    BEGIN TRY
        IF @Id IS NULL OR @AppUserId IS NULL
        BEGIN
            SET @Message = N'Required parameter missing (Id, AppUserId).';
            SELECT @Status AS Status, @Message AS Message;
            RETURN;
        END

        SELECT @Serial = AimShipperId FROM Lots.AimShipperIdPool WHERE Id = @Id;

        IF @Serial IS NULL
        BEGIN
            SET @Message = N'AIM pool row not found.';
            SELECT @Status AS Status, @Message AS Message;
            RETURN;
        END

        IF EXISTS (SELECT 1 FROM Lots.AimShipperIdPool WHERE Id = @Id AND PostedAt IS NOT NULL)
        BEGIN
            SET @Message = N'This shipper ID is already recorded as posted to AIM.';
            SELECT @Status AS Status, @Message AS Message;
            RETURN;
        END

        BEGIN TRANSACTION;

        UPDATE Lots.AimShipperIdPool
           SET PostedAt      = SYSUTCDATETIME(),
               LastPostError = NULL
         WHERE Id = @Id;

        SET @Activity = Audit.ufn_TruncateActivity(
            N'AIM ' + @Serial + N' ' + Audit.ufn_MidDot()
            + N' Post-back ' + Audit.ufn_MidDot() + N' Marked Posted (manual): ' + ISNULL(@Note, N''));
        SET @NewValue = (SELECT @Id AS AimShipperIdPoolId, @Serial AS AimShipperId,
                                @Note AS Note
                         FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

        EXEC Audit.Audit_LogConfigChange
            @AppUserId         = @AppUserId,
            @LogEntityTypeCode = N'AimShipperIdPool',
            @EntityId          = @Id,
            @LogEventTypeCode  = N'Updated',
            @Description       = @Activity,
            @OldValue          = NULL,
            @NewValue          = @NewValue;

        COMMIT TRANSACTION;

        SET @Status  = 1;
        SET @Message = N'Shipper ID ' + @Serial + N' marked posted to AIM.';
        SELECT @Status AS Status, @Message AS Message;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
        DECLARE @ErrMsg NVARCHAR(2000) = ERROR_MESSAGE();
        SET @Status  = 0;
        SET @Message = N'Failed to mark the shipper ID posted.';
        SELECT @Status AS Status, @Message AS Message;
        RAISERROR (@ErrMsg, 16, 1);
    END CATCH
END;
GO
```

- [ ] **Step 4: Check the audit entity type exists**

`@LogEntityTypeCode = N'AimShipperIdPool'` must resolve in `Audit.LogEntityType`. Check:

```bash
sqlcmd -S localhost -d MPP_MES_Test -Q "SELECT Id, Code FROM Audit.LogEntityType WHERE Code = 'AimShipperIdPool'"
```

If it returns no row, add a seed block to migration `0049` (before the `SchemaVersion` insert) using the **next free Id** — verify the maximum first, exactly as migration `0044` documents:

```sql
DECLARE @NextEntityId INT = (SELECT MAX(Id) + 1 FROM Audit.LogEntityType);
IF NOT EXISTS (SELECT 1 FROM Audit.LogEntityType WHERE Code = N'AimShipperIdPool')
    INSERT INTO Audit.LogEntityType (Id, Code, Name, Description)
    VALUES (@NextEntityId, N'AimShipperIdPool', N'AIM Shipper ID Pool',
            N'Lots.AimShipperIdPool - pooled Honda AIM shipper IDs and their post-back state.');
GO
```

Record the Id you used in the migration header. Two concurrent branches picking the same Id is a known collision in this repo (see the `0038` PLC note in PROJECT_STATUS).

- [ ] **Step 5: Apply and re-run**

```bash
powershell -File sql/scripts/Reset-DevDatabase.ps1 -DatabaseName MPP_MES_Test -SkipDemoSeed
powershell -File sql/tests/Run-Tests.ps1 -Filter "0049_AimIntegration"
```

Expected: PASS, 25 assertions.

- [ ] **Step 6: Commit**

```bash
git add sql/migrations/repeatable/R__Lots_AimShipperIdPool_MarkPosted.sql sql/tests/0049_AimIntegration/040_MarkPosted.sql sql/migrations/versioned/0049_aim_pool_generic_and_postback.sql
git commit -m "feat(sql): AimShipperIdPool_MarkPosted - audited human-confirmed resolution"
```

---

### Task 6: `Parts.Item` AIM customer-part accessors

**Files:**
- Create: `sql/migrations/repeatable/R__Parts_Item_GetAimCustomerPartNumber.sql`
- Create: `sql/migrations/repeatable/R__Parts_Item_SetAimCustomerPartNumber.sql`
- Create: `sql/tests/0049_AimIntegration/050_Item_accessors.sql`

**Interfaces:**
- Produces:
  - `Parts.Item_GetAimCustomerPartNumber @ItemId BIGINT` -> `SELECT ItemId, AimCustomerPartNumber` (empty rowset = not found)
  - `Parts.Item_SetAimCustomerPartNumber @ItemId BIGINT, @Value NVARCHAR(50), @AppUserId BIGINT` -> `SELECT Status, Message`

> **Mirror of `Item_GetPlcId` / `Item_SetPlcId` (migration `0038`).** Separate accessors deliberately keep `Item_Get` / `Item_Update` result shapes stable so no fixed-shape `INSERT-EXEC` capture breaks. Read those two files first and match their structure.

- [ ] **Step 1: Write the failing test**

Create `sql/tests/0049_AimIntegration/050_Item_accessors.sql`:

```sql
-- =============================================
-- File: 0049_AimIntegration/050_Item_accessors.sql
-- Desc: Item AIM customer-part accessors round-trip, allow clearing, and audit.
-- =============================================
EXEC test.BeginTestFile @FileName = N'0049_AimIntegration/050_Item_accessors.sql';
GO

-- -SkipDemoSeed leaves Parts.Item without demo rows; create our own.
DECLARE @Now DATETIME2(3) = SYSUTCDATETIME();
DECLARE @UserId BIGINT = 1;
IF NOT EXISTS (SELECT 1 FROM Parts.Item WHERE PartNumber = N'AIM-P1-T6')
    INSERT INTO Parts.Item (ItemTypeId, PartNumber, Description, UomId, CreatedAt, CreatedByUserId)
    VALUES (3, N'AIM-P1-T6', N'AIM plan-1 accessor test part', 1, @Now, 1);
DECLARE @ItemId BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'AIM-P1-T6');

DECLARE @S TABLE (Status BIT, Message NVARCHAR(500));
INSERT INTO @S EXEC Parts.Item_SetAimCustomerPartNumber
    @ItemId = @ItemId, @Value = N'112006FB A000', @AppUserId = @UserId;
DECLARE @SetOk NVARCHAR(10) = (SELECT CAST(Status AS NVARCHAR(10)) FROM @S);
EXEC test.Assert_IsEqual
    @TestName = N'[0049] Item_SetAimCustomerPartNumber succeeds',
    @Expected = N'1', @Actual = @SetOk;

DECLARE @G TABLE (ItemId BIGINT, AimCustomerPartNumber NVARCHAR(50));
INSERT INTO @G EXEC Parts.Item_GetAimCustomerPartNumber @ItemId = @ItemId;
DECLARE @Got NVARCHAR(50) = (SELECT AimCustomerPartNumber FROM @G);
EXEC test.Assert_IsEqual
    @TestName = N'[0049] Item_GetAimCustomerPartNumber round-trips the value',
    @Expected = N'112006FB A000', @Actual = @Got;

-- The embedded space is significant to AIM's lookup and must survive.
DECLARE @Len NVARCHAR(10) = (SELECT CAST(LEN(AimCustomerPartNumber + N'.') - 1 AS NVARCHAR(10)) FROM @G);
EXEC test.Assert_IsEqual
    @TestName = N'[0049] embedded space preserved (13 characters)',
    @Expected = N'13', @Actual = @Len;

-- Clearing is legal - an item may stop shipping to Honda.
DELETE FROM @S;
INSERT INTO @S EXEC Parts.Item_SetAimCustomerPartNumber
    @ItemId = @ItemId, @Value = NULL, @AppUserId = @UserId;
DECLARE @Cleared NVARCHAR(10) = (SELECT CASE WHEN AimCustomerPartNumber IS NULL THEN N'1' ELSE N'0' END
    FROM Parts.Item WHERE Id = @ItemId);
EXEC test.Assert_IsEqual
    @TestName = N'[0049] setting NULL clears the value',
    @Expected = N'1', @Actual = @Cleared;

-- Unknown item is rejected, not silently ignored.
DELETE FROM @S;
INSERT INTO @S EXEC Parts.Item_SetAimCustomerPartNumber
    @ItemId = 99999999, @Value = N'X', @AppUserId = @UserId;
DECLARE @Bad NVARCHAR(10) = (SELECT CAST(Status AS NVARCHAR(10)) FROM @S);
EXEC test.Assert_IsEqual
    @TestName = N'[0049] unknown item rejected',
    @Expected = N'0', @Actual = @Bad;

DELETE FROM @G;
INSERT INTO @G EXEC Parts.Item_GetAimCustomerPartNumber @ItemId = 99999999;
DECLARE @NoRow NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM @G);
EXEC test.Assert_IsEqual
    @TestName = N'[0049] get on unknown item returns empty rowset',
    @Expected = N'0', @Actual = @NoRow;
GO

EXEC test.EndTestFile;
GO
```

- [ ] **Step 2: Run it and verify it fails**

```bash
powershell -File sql/tests/Run-Tests.ps1 -Filter "050_Item_accessors"
```

Expected: `ERROR running` — the procs do not exist.

- [ ] **Step 3: Read the precedent**

```bash
cat sql/migrations/repeatable/R__Parts_Item_GetPlcId.sql sql/migrations/repeatable/R__Parts_Item_SetPlcId.sql
```

Match their header style, validation order, and audit shape. Deviating here creates two ways to do the same thing on the same table.

- [ ] **Step 4: Create `_GetAimCustomerPartNumber`**

```sql
-- ============================================================
-- Repeatable:  R__Parts_Item_GetAimCustomerPartNumber.sql
-- Author:      Blue Ridge Automation
-- Version:     1.0
-- Description: Reads Parts.Item.AimCustomerPartNumber - the Customer Part that
--              AIM's postserial.csv matches on. NOT derivable from Item.PartNumber
--              (AIM X-Ref: 11300R70 A000 -> 11300R7- A000), so it is stored per
--              item and sourced from AIM. Separate accessor rather than extending
--              Item_Get, mirroring Item_GetPlcId - keeps Item_Get's result shape
--              stable so no fixed-shape INSERT-EXEC capture breaks. Read proc:
--              empty rowset = not found.
-- ============================================================
CREATE OR ALTER PROCEDURE Parts.Item_GetAimCustomerPartNumber
    @ItemId BIGINT
AS
BEGIN
    SET NOCOUNT ON;

    IF @ItemId IS NULL
        RETURN;

    SELECT
        i.Id                    AS ItemId,
        i.AimCustomerPartNumber AS AimCustomerPartNumber
    FROM Parts.Item i
    WHERE i.Id = @ItemId;
END;
GO
```

- [ ] **Step 5: Create `_SetAimCustomerPartNumber`**

```sql
-- ============================================================
-- Repeatable:  R__Parts_Item_SetAimCustomerPartNumber.sql
-- Author:      Blue Ridge Automation
-- Version:     1.0
-- Description: Sets (or clears, with NULL) Parts.Item.AimCustomerPartNumber from
--              the Item Master Identity field. Mirrors Item_SetPlcId. NULL is
--              legal - not every item ships to Honda. Audited. No OUTPUT params;
--              single terminal SELECT. RAISERROR in the CATCH.
-- ============================================================
CREATE OR ALTER PROCEDURE Parts.Item_SetAimCustomerPartNumber
    @ItemId    BIGINT,
    @Value     NVARCHAR(50),
    @AppUserId BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Status   BIT           = 0;
    DECLARE @Message  NVARCHAR(500) = N'Unknown error';
    DECLARE @PartNo   NVARCHAR(50);
    DECLARE @Old      NVARCHAR(50);
    DECLARE @Activity NVARCHAR(500);
    DECLARE @OldValue NVARCHAR(MAX);
    DECLARE @NewValue NVARCHAR(MAX);

    BEGIN TRY
        IF @ItemId IS NULL OR @AppUserId IS NULL
        BEGIN
            SET @Message = N'Required parameter missing (ItemId, AppUserId).';
            SELECT @Status AS Status, @Message AS Message;
            RETURN;
        END

        SELECT @PartNo = PartNumber, @Old = AimCustomerPartNumber
        FROM Parts.Item WHERE Id = @ItemId;

        IF @PartNo IS NULL
        BEGIN
            SET @Message = N'Item not found.';
            SELECT @Status AS Status, @Message AS Message;
            RETURN;
        END

        BEGIN TRANSACTION;

        UPDATE Parts.Item
           SET AimCustomerPartNumber = @Value,
               UpdatedAt             = SYSUTCDATETIME(),
               UpdatedByUserId       = @AppUserId
         WHERE Id = @ItemId;

        SET @Activity = Audit.ufn_TruncateActivity(
            @PartNo + N' ' + Audit.ufn_MidDot() + N' AIM ' + Audit.ufn_MidDot()
            + N' Customer part ' + CASE WHEN @Value IS NULL THEN N'cleared' ELSE N'set' END);
        SET @OldValue = (SELECT @ItemId AS ItemId, @Old AS AimCustomerPartNumber
                         FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);
        SET @NewValue = (SELECT @ItemId AS ItemId, @Value AS AimCustomerPartNumber
                         FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

        EXEC Audit.Audit_LogConfigChange
            @AppUserId         = @AppUserId,
            @LogEntityTypeCode = N'Item',
            @EntityId          = @ItemId,
            @LogEventTypeCode  = N'Updated',
            @Description       = @Activity,
            @OldValue          = @OldValue,
            @NewValue          = @NewValue;

        COMMIT TRANSACTION;

        SET @Status  = 1;
        SET @Message = N'AIM customer part number updated.';
        SELECT @Status AS Status, @Message AS Message;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
        DECLARE @ErrMsg NVARCHAR(2000) = ERROR_MESSAGE();
        SET @Status  = 0;
        SET @Message = N'Failed to update the AIM customer part number.';
        SELECT @Status AS Status, @Message AS Message;
        RAISERROR (@ErrMsg, 16, 1);
    END CATCH
END;
GO
```

- [ ] **Step 6: Apply and re-run**

```bash
powershell -File sql/scripts/Reset-DevDatabase.ps1 -DatabaseName MPP_MES_Test -SkipDemoSeed
powershell -File sql/tests/Run-Tests.ps1 -Filter "0049_AimIntegration"
```

Expected: PASS, 31 assertions.

- [ ] **Step 7: Commit**

```bash
git add sql/migrations/repeatable/R__Parts_Item_GetAimCustomerPartNumber.sql sql/migrations/repeatable/R__Parts_Item_SetAimCustomerPartNumber.sql sql/tests/0049_AimIntegration/050_Item_accessors.sql
git commit -m "feat(sql): Parts.Item AIM customer-part accessors (mirrors PlcId pattern)"
```

---

### Task 7: `AimPoolConfig` connection + escalation settings

**Files:**
- Modify: `sql/migrations/repeatable/R__Lots_AimPoolConfig_Get.sql`
- Modify: `sql/migrations/repeatable/R__Lots_AimPoolConfig_Update.sql`
- Modify: `sql/tests/0029_PlantFloor_Hold_Sort_Shipping_Aim/040_AimPoolConfig.sql`
- Modify: `sql/seeds/028_seed_aim_pool_dev.sql`

**Interfaces:**
- Produces:
  - `Lots.AimPoolConfig_Get` -> `SELECT Id, TargetBufferDepth, TopupThreshold, AlarmWarningDepth, AlarmCriticalDepth, AimBaseUrl, AimCompanyCode, AimPathToken, PostWarningAgeMinutes, PostCriticalAgeMinutes, UpdatedAtEt, UpdatedByUserId`
  - `Lots.AimPoolConfig_Update @TargetBufferDepth, @TopupThreshold, @AlarmWarningDepth, @AlarmCriticalDepth, @AimBaseUrl, @AimCompanyCode, @AimPathToken, @PostWarningAgeMinutes, @PostCriticalAgeMinutes, @AppUserId` -> `SELECT Status, Message`

- [ ] **Step 1: Extend the existing test**

Append inside `sql/tests/0029_PlantFloor_Hold_Sort_Shipping_Aim/040_AimPoolConfig.sql`, before `EndTestFile`:

```sql
DECLARE @CfgUser BIGINT = (SELECT TOP 1 Id FROM Location.AppUser ORDER BY Id);
DECLARE @U TABLE (Status BIT, Message NVARCHAR(500));
INSERT INTO @U EXEC Lots.AimPoolConfig_Update
    @TargetBufferDepth = 50, @TopupThreshold = 30,
    @AlarmWarningDepth = 20, @AlarmCriticalDepth = 10,
    @AimBaseUrl = N'http://172.17.10.86:8080', @AimCompanyCode = N'01',
    @AimPathToken = N'636652666553236784',
    @PostWarningAgeMinutes = 45, @PostCriticalAgeMinutes = 90,
    @AppUserId = @CfgUser;
DECLARE @UpdOk NVARCHAR(10) = (SELECT CAST(Status AS NVARCHAR(10)) FROM @U);
EXEC test.Assert_IsEqual
    @TestName = N'[AimPoolConfig] update accepts connection + escalation settings',
    @Expected = N'1', @Actual = @UpdOk;

DECLARE @Round NVARCHAR(60) = (SELECT AimCompanyCode + N'/' + AimPathToken + N'/'
    + CAST(PostWarningAgeMinutes AS NVARCHAR(10))
    FROM Lots.AimPoolConfig WHERE Id = 1);
EXEC test.Assert_IsEqual
    @TestName = N'[AimPoolConfig] connection + escalation settings round-trip',
    @Expected = N'01/636652666553236784/45', @Actual = @Round;
```

- [ ] **Step 2: Run it and verify it fails**

```bash
powershell -File sql/tests/Run-Tests.ps1 -Filter "040_AimPoolConfig"
```

Expected: `ERROR running` — `_Update` has no such parameters.

- [ ] **Step 3: Extend `_Get`**

Replace the `SELECT` in `R__Lots_AimPoolConfig_Get.sql` with:

```sql
    SELECT
        c.Id                     AS Id,
        c.TargetBufferDepth      AS TargetBufferDepth,
        c.TopupThreshold         AS TopupThreshold,
        c.AlarmWarningDepth      AS AlarmWarningDepth,
        c.AlarmCriticalDepth     AS AlarmCriticalDepth,
        c.AimBaseUrl             AS AimBaseUrl,
        c.AimCompanyCode         AS AimCompanyCode,
        c.AimPathToken           AS AimPathToken,
        c.PostWarningAgeMinutes  AS PostWarningAgeMinutes,
        c.PostCriticalAgeMinutes AS PostCriticalAgeMinutes,
        CAST(c.UpdatedAt AT TIME ZONE 'UTC' AT TIME ZONE 'Eastern Standard Time'
             AS DATETIME2(3))    AS UpdatedAtEt,
        c.UpdatedByUserId        AS UpdatedByUserId
    FROM Lots.AimPoolConfig c
    WHERE c.Id = 1;
```

- [ ] **Step 4: Extend `_Update`**

In `R__Lots_AimPoolConfig_Update.sql`, the parameter block becomes:

```sql
CREATE OR ALTER PROCEDURE Lots.AimPoolConfig_Update
    @TargetBufferDepth      INT,
    @TopupThreshold         INT,
    @AlarmWarningDepth      INT,
    @AlarmCriticalDepth     INT,
    @AimBaseUrl             NVARCHAR(200) = NULL,
    @AimCompanyCode         NVARCHAR(10)  = NULL,
    @AimPathToken           NVARCHAR(50)  = NULL,
    @PostWarningAgeMinutes  INT           = 30,
    @PostCriticalAgeMinutes INT           = 120,
    @AppUserId              BIGINT
AS
```

and the `UPDATE` becomes:

```sql
        UPDATE Lots.AimPoolConfig
           SET TargetBufferDepth      = @TargetBufferDepth,
               TopupThreshold         = @TopupThreshold,
               AlarmWarningDepth      = @AlarmWarningDepth,
               AlarmCriticalDepth     = @AlarmCriticalDepth,
               AimBaseUrl             = @AimBaseUrl,
               AimCompanyCode         = @AimCompanyCode,
               AimPathToken           = @AimPathToken,
               PostWarningAgeMinutes  = @PostWarningAgeMinutes,
               PostCriticalAgeMinutes = @PostCriticalAgeMinutes,
               UpdatedAt              = SYSUTCDATETIME(),
               UpdatedByUserId        = @AppUserId
         WHERE Id = 1;
```

The new parameters carry defaults so any existing caller that passes only the original four still compiles. Keep the existing validation and audit block; extend the audit `NewValue` JSON to include the five new fields.

- [ ] **Step 5: Seed the dev connection settings**

In `sql/seeds/028_seed_aim_pool_dev.sql`: remove `PartNumber` from the pool `INSERT` (it no longer exists), and set the dev connection settings on the config row:

```sql
UPDATE Lots.AimPoolConfig
   SET AimBaseUrl     = N'http://172.17.10.86:8080',
       AimCompanyCode = N'01',
       AimPathToken   = N'636652666553236784'
 WHERE Id = 1;
GO
```

Company `01` is the **test** company. Production runs on `99` from the legacy MES box; MES traffic must never target it.

- [ ] **Step 6: Apply and re-run**

```bash
powershell -File sql/scripts/Reset-DevDatabase.ps1 -DatabaseName MPP_MES_Test -SkipDemoSeed
powershell -File sql/tests/Run-Tests.ps1 -Filter "040_AimPoolConfig"
```

Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add sql/migrations/repeatable/R__Lots_AimPoolConfig_Get.sql sql/migrations/repeatable/R__Lots_AimPoolConfig_Update.sql sql/tests/0029_PlantFloor_Hold_Sort_Shipping_Aim/040_AimPoolConfig.sql sql/seeds/028_seed_aim_pool_dev.sql
git commit -m "feat(sql): AimPoolConfig carries AIM connection + post-backlog escalation settings"
```

---

### Task 8: Full-suite regression against the baseline

**Files:**
- Create: `sql/scratch/aim_baseline_after.txt` (scratch, not committed)

- [ ] **Step 1: Reset and run everything**

```bash
powershell -File sql/scripts/Reset-DevDatabase.ps1 -DatabaseName MPP_MES_Test -SkipDemoSeed
powershell -File sql/tests/Run-Tests.ps1 > sql/scratch/aim_baseline_after.txt 2>&1
```

- [ ] **Step 2: Diff the failure sets**

```bash
grep -E "ERROR running|FAIL:" sql/scratch/aim_baseline_after.txt | sort > sql/scratch/aim_after_failures.txt
diff sql/scratch/aim_baseline_failures.txt sql/scratch/aim_after_failures.txt
```

Expected: **no output** — the same 7 pre-existing failures, nothing new.

Any added line is a regression you caused. The overwhelmingly likely cause is a fixed-shape `INSERT-EXEC` capture in a test whose proc gained or lost a parameter — fix the capture in the test, not the proc.

- [ ] **Step 3: Confirm a clean full build**

```bash
grep -cE "^\s*PASS" sql/scratch/aim_baseline_after.txt
```

Record the number in the commit message so the next session has a comparable figure. Note that an assertion count alone hides `ERROR running` files — always report it alongside the diff result.

- [ ] **Step 4: Commit the plan-completion marker**

```bash
git commit --allow-empty -m "test(sql): AIM Plan 1 complete - full suite green against baseline

Migration 0049 + 6 modified procs + 6 new procs + 5 test files.
Pre-existing failures unchanged (7 ERROR running, see PROJECT_STATUS 2026-07-28).
Plan 2 (Ignition layer) consumes the proc signatures produced here."
```

---

## What Plan 2 consumes from this plan

Plan 2 (Ignition layer) is written against these exact signatures. If any changes during implementation, update this list and tell whoever picks up Plan 2:

| Proc | Signature |
|---|---|
| `Lots.AimShipperIdPool_Claim` | `@ContainerId, @AppUserId` -> `Status, Message, AimShipperId` |
| `Lots.AimShipperIdPool_Topup` | `@AimShipperId, @FetchedInterfaceLogId = NULL` -> `Status, Message, NewId` |
| `Lots.AimShipperIdPool_GetDepth` | (none) -> `Depth, OldestAvailableAt` |
| `Lots.AimShipperIdPool_GetForPost` | `@AimShipperId` -> `Id, AimShipperId, CustomerPartNumber, Quantity, LotNumber, PostedAt, PostAttempts` |
| `Lots.AimShipperIdPool_RecordPostResult` | `@Id, @Success, @Error = NULL` -> `Status, Message` |
| `Lots.AimShipperIdPool_ListUnposted` | `@Top = 50` -> 11 columns incl. `AgeMinutes` |
| `Lots.AimShipperIdPool_MarkPosted` | `@Id, @AppUserId, @Note` -> `Status, Message` |
| `Lots.AimPoolConfig_Get` | (none) -> config incl. `AimBaseUrl, AimCompanyCode, AimPathToken, PostWarningAgeMinutes, PostCriticalAgeMinutes` |
| `Lots.AimPoolConfig_Update` | 9 settings + `@AppUserId` -> `Status, Message` |
| `Parts.Item_GetAimCustomerPartNumber` | `@ItemId` -> `ItemId, AimCustomerPartNumber` |
| `Parts.Item_SetAimCustomerPartNumber` | `@ItemId, @Value, @AppUserId` -> `Status, Message` |
| `Lots.Container_Complete` | **unchanged** -> `Status, Message, ShippingLabelId, AimShipperId` |
