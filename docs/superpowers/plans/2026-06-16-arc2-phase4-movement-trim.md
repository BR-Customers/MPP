# Arc 2 Phase 4 — Movement + Trim + Receiving Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the operator-facing Movement Scan, tabbed Trim Station (IN/OUT), and Receiving Dock surfaces — server-authoritative validated moves, whole-LOT Trim OUT into the Machining FIFO queue, vendor pass-through receiving, and synchronous LTT label dispatch to networked Zebra printers.

**Architecture:** SQL-first. Two versioned migrations (`0024` movement/trim audit seeds, `0025` label-dispatch delta) + one seed (`024` Trim OperationTemplates) + six net-new procs + three label-proc deltas, all tested by the `0024`/`0025` suites. Then the thin Ignition layer (Core NQs + entity scripts, MPP views + `onStartup`/session extension + routes) — business-logic-free callers over the proc contracts. Enforcement (eligibility FDS-02-012, MaxParts OI-12, not-blocked B2) lives in `Lot_MoveToValidated`; the UI only surfaces.

**Tech Stack:** SQL Server 2022 (versioned + repeatable migrations, `test.Assert_IsEqual` harness), Ignition 8.3 file-based Perspective (`Core` parent project = entity scripts + named queries; `MPP` child = views + session + startup), Jython entity scripts, raw-TCP 9100 ZPL dispatch.

---

## Source specs (read both before starting)

- SQL foundation: `docs/superpowers/specs/2026-06-15-arc2-phase4-movement-trim-sql-design.md`
- Gateway + front-end: `docs/superpowers/specs/2026-06-15-arc2-phase4-gateway-frontend-design.md`

## Ground-truth confirmed against disk (2026-06-16)

| Fact | Value |
|---|---|
| Migration high-water | `0023_arc2_phase3_sql_deltas.sql` exists → Phase 4 takes `0024` + `0025` (contiguous) |
| `Audit.LogEventType` MAX Id | **33** (`RejectEventRecorded`, seeded in `0022`) → Phase 4 seeds **34**, **35** (`0024`), **36** (`0025`) |
| `Audit.LogEntityType` MAX Id | **46** (`RejectEvent`) → Phase 4 needs **no** new LogEntityType (`Lot`, `ProductionEvent`, `RejectEvent`, `LotLabel` all exist) |
| `Parts.Item.MaxParts` | EXISTS — `INT NULL`, added in `0013` (OI-12). `Item_Get` already returns it. |
| `Parts.Item.MaxLotSize` | EXISTS — the per-LOT/basket cap used by `Lot_Create` (distinct from `MaxParts` lineside cap) |
| `Lots.LotLabel.PrinterName` | EXISTS — `NVARCHAR(100) NULL` (seeded in `0021` CREATE) |
| `Lots.LotLabel.DispatchedAt` | DOES NOT EXIST — `0025` ALTERs it in |
| `Parts.v_EffectiveItemLocation` | columns `ItemId, LocationId, Source ('Direct'/'BomDerived'), ParentItemId, BomId` — **`Source`, not `Path`**; alias `Source AS Path` in the new read |
| MPP project root | `ignition/projects/MPP/com.inductiveautomation.perspective/` |
| Core project root | `ignition/projects/Core/ignition/` (script-python + named-query) |
| Local sync | `.\scan.ps1` only (localhost:8088). New Core NQs need a **gateway restart** (scan insufficient — `project_mpp_nq_core_topology`). NEVER touch `pull.ps1`/`C:\MPP`. |

## Runner commands

- Build/reset dev DB (applies versioned → repeatable → seeds in numeric/alpha order): `sql/scripts/Reset-DevDatabase.ps1`
- Run SQL suite (resets first, then every `sql/tests/NNNN_*/`): `sql/tests/Run-Tests.ps1` (filter with `-Filter "Movement"` or `-Filter "0024"`)
- Register Ignition file changes: `.\scan.ps1` (gateway **restart** after new Core NQs)

## Conventions locked for this plan

- Every mutation proc: `SET NOCOUNT ON; SET XACT_ABORT ON;`, `@Status BIT`/`@Message`/`@NewId` locals, **all rejecting validations before `BEGIN TRANSACTION`**, sub-mutations **inlined** (never `EXEC`'d — INSERT-EXEC/Msg-3915 rule), `CATCH` is the only `ROLLBACK` site, `RAISERROR` (not `THROW`) in nested CATCH, every exit ends `SELECT @Status AS Status, @Message AS Message[, @NewId AS NewId];`. No OUTPUT params (FDS-11-011).
- Audit: `Lot`-entity events → `Lots.LotEventLog`; `ProductionEvent`/`LotLabel`-entity events → `Audit.OperationLog` (the `Audit_LogOperation` proc routes by entity type). Description = `<SUBJECT> · <CATEGORY> · <ACTION>` via `Audit.ufn_MidDot()` + `Audit.ufn_TruncateActivity()`, resolved-FK JSON via `JSON_QUERY(... FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)`.
- ASCII-only seed/migration strings (byte-scan before applying — `feedback_ascii_only_seed_data`).
- NQ `resource.json`: `version: 2`, `scope: "DG"`, `database: "MPP"`, `sqlType` Designer enum (`3`=BIGINT, `7`=NVARCHAR, `2`=INT, `6`=BIT). Mutation NQs are `type: "Query"` (status-row; `UpdateQuery` would throw — `feedback_ignition_nq_type_for_status_row_procs`).
- Entity scripts: `BlueRidge.Common.Db.execList/execOne/execMutation` only; never `system.db.*`; `_currentAppUserId()` for `@AppUserId`; `_u()`/`extractQualifiedValues` at boundaries.
- Views: `meta.name:"root"`; pre-declare every binding-read `view.custom.*` with a shaped default; `position.display` for conditional flex visibility; event-script bodies start with `\t`; `system.perspective.*` from dom events needs `scope:"G"`; page-scoped messages (`scope="page"` + handler `pageScope:true`) for embed→parent; `ia.input.dropdown` + `props.allowCustomOptions:true` for scan-or-dropdown; ≥44px targets, portrait (FDS-02-013).

## Open flags to confirm during build (none block starting)

1. **`TrimCheckpointRecorded` (LogEventType 34) is seeded but vestigial in Phase 4.** Trim IN reuses Phase 3 `Workorder.ProductionEvent_Record` unchanged (spec §2/§5.2), which hardcodes the `DieCastCheckpointRecorded` audit event. So a Trim IN checkpoint audits as `DieCastCheckpointRecorded` (the `TrimIn` template Code is in the Description, so it's still legible). We seed `34 TrimCheckpointRecorded` per spec §3.1 and reserve it for a future Trim-specific checkpoint proc. Confirm with Jacques whether that mislabel is acceptable or whether `ProductionEvent_Record` should take a parameterized `@LogEventTypeCode` (would touch a shipped Phase 3 proc — out of this plan's "reuse unchanged" scope).
2. **`Audit.Audit_LogInterfaceCall` exact signature** — read `sql/migrations/repeatable/R__Audit_*InterfaceCall*.sql` before writing the entity-script `_logDispatch`. Spec §2 lists columns `Direction, LogEventTypeId, RequestPayload, ResponsePayload, ErrorCondition, ErrorDescription`; confirm param names + whether it needs `@LocationId`/`@AppUserId`.
3. **`Location.Location` parent-FK column name** for the `Lot_GetWipQueueByLocation @IncludeDescendants=1` recursive CTE — confirm it's `ParentLocationId` (mirror `Location.Terminal_ListContextCells`'s CTE). `@IncludeDescendants=0` (the Phase 4 path) does not need it.

---

# PHASE A — SQL: migration `0024` + Trim seed + six procs + test suite

## Task A1: Migration `0024` (audit-lookup seeds only)

**Files:**
- Create: `sql/migrations/versioned/0024_arc2_phase4_movement_trim_receiving.sql`

- [ ] **Step 1: Write the migration** (mirrors the `0023` header + SchemaVersion + the `0022` LogEventType idempotent-insert pattern; no tables, no ALTERs)

```sql
-- ============================================================
-- Migration:   0024_arc2_phase4_movement_trim_receiving.sql
-- Author:      Blue Ridge Automation
-- Date:        2026-06-16
-- Description: Arc 2 Phase 4 (Movement + Trim + Receiving) audit-lookup seeds.
--              Schema-free: NO tables, NO ALTERs (the six Phase 4 procs are
--              repeatable migrations; the Trim OperationTemplates are a SEED —
--              024 — because OperationTemplate.AreaLocationId FKs the
--              seed-loaded plant hierarchy).
--                + Audit.LogEventType 34 TrimCheckpointRecorded (reserved;
--                  Trim IN currently reuses ProductionEvent_Record =>
--                  DieCastCheckpointRecorded -- see plan flag 1)
--                + Audit.LogEventType 35 TrimOutRecorded
--              No new LogEntityType (Lot / ProductionEvent / RejectEvent exist).
--              No ReceivingScan event (Receiving = Lot_Create => LotCreated).
--              Idempotent. ASCII-only strings.
-- ============================================================

IF NOT EXISTS (SELECT 1 FROM Audit.LogEventType WHERE Id = 34 OR Code = N'TrimCheckpointRecorded')
    INSERT INTO Audit.LogEventType (Id, Code, Name, Description) VALUES
        (34, N'TrimCheckpointRecorded', N'Trim Checkpoint Recorded', N'A trim-station production checkpoint was recorded (reserved; Trim IN currently records via ProductionEvent_Record).');
GO

IF NOT EXISTS (SELECT 1 FROM Audit.LogEventType WHERE Id = 35 OR Code = N'TrimOutRecorded')
    INSERT INTO Audit.LogEventType (Id, Code, Name, Description) VALUES
        (35, N'TrimOutRecorded', N'Trim Out Recorded', N'A whole-LOT Trim OUT move into a Machining-line FIFO queue (closing checkpoint + move).');
GO

IF NOT EXISTS (SELECT 1 FROM dbo.SchemaVersion WHERE MigrationId = N'0024_arc2_phase4_movement_trim_receiving')
    INSERT INTO dbo.SchemaVersion (MigrationId, Description)
    VALUES (N'0024_arc2_phase4_movement_trim_receiving',
            N'Arc 2 Phase 4 audit-lookup seeds: LogEventType 34 TrimCheckpointRecorded (reserved) + 35 TrimOutRecorded. No tables/ALTERs; procs are repeatable; Trim OperationTemplates are seed 024.');
GO

PRINT 'Migration 0024 (Arc 2 Phase 4 movement/trim/receiving audit seeds) applied.';
GO
```

- [ ] **Step 2: Apply + verify** — `sql/scripts/Reset-DevDatabase.ps1`; expect `Migration 0024 ... applied.` and no errors. Confirm `SELECT MAX(Id) FROM Audit.LogEventType` = 35.

- [ ] **Step 3: Commit** — `git add sql/migrations/versioned/0024_arc2_phase4_movement_trim_receiving.sql && git commit -m "feat(arc2): Phase 4 migration 0024 - movement/trim audit seeds"`

## Task A2: Seed `024` — Trim IN / Trim OUT OperationTemplates (no fields)

**Files:**
- Create: `sql/seeds/024_seed_trim_operation_templates.sql`

- [ ] **Step 1: Write the seed** (mirrors `022_seed_die_cast_operation_template.sql` Area-resolution + idempotent-on-Code pattern; **no `OperationTemplateField` children** per Confirm C). Resolve the Trim Shop Area by Code (`TS1` — confirm against `011_seed_locations_mpp_plant.sql`; fall back to first active Area-tier).

```sql
-- ============================================================
-- Seed:        024_seed_trim_operation_templates.sql
-- Author:      Blue Ridge Automation
-- Date:        2026-06-16
-- Description: Arc 2 Phase 4. The TrimIn + TrimOut OperationTemplates that the
--              Trim Station records checkpoints against. NO OperationTemplateField
--              children (Confirm C: Trim uses the promoted ProductionEvent
--              ShotCount/ScrapCount columns only). TWO-state versioned entity
--              (VersionNumber=1, DeprecatedAt IS NULL = active). Idempotent on Code.
--              Lives in a SEED (not migration 0024) because
--              OperationTemplate.AreaLocationId NOT NULL FKs the seed-loaded plant
--              hierarchy (011). ASCII-only. Dependency: 011 (Trim Shop Area).
-- ============================================================
DECLARE @Now DATETIME2(3) = SYSUTCDATETIME();

DECLARE @TrimAreaId BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'TS1' AND DeprecatedAt IS NULL);
IF @TrimAreaId IS NULL
    SET @TrimAreaId = (
        SELECT TOP 1 l.Id
        FROM Location.Location l
        INNER JOIN Location.LocationTypeDefinition ltd ON ltd.Id = l.LocationTypeDefinitionId
        INNER JOIN Location.LocationType lt ON lt.Id = ltd.LocationTypeId
        WHERE l.DeprecatedAt IS NULL AND lt.Code = N'Area'
        ORDER BY l.Id);

IF @TrimAreaId IS NOT NULL AND NOT EXISTS (SELECT 1 FROM Parts.OperationTemplate WHERE Code = N'TrimIn')
    INSERT INTO Parts.OperationTemplate (Code, VersionNumber, Name, AreaLocationId, Description, CreatedAt)
    VALUES (N'TrimIn', 1, N'Trim In', @TrimAreaId,
            N'Trim-station IN checkpoint template (Arc 2 Phase 4). Carried-forward cumulative shot/scrap counters; yield-loss only, no rename.', @Now);

IF @TrimAreaId IS NOT NULL AND NOT EXISTS (SELECT 1 FROM Parts.OperationTemplate WHERE Code = N'TrimOut')
    INSERT INTO Parts.OperationTemplate (Code, VersionNumber, Name, AreaLocationId, Description, CreatedAt)
    VALUES (N'TrimOut', 1, N'Trim Out', @TrimAreaId,
            N'Trim-station OUT template (Arc 2 Phase 4). Closing checkpoint for a 1:1 whole-LOT move into a Machining-line FIFO queue.', @Now);
GO
PRINT 'Seed 024 (Trim IN/OUT OperationTemplates) loaded.';
GO
```

- [ ] **Step 2: Apply + verify** — `Reset-DevDatabase.ps1`; `SELECT Code, VersionNumber FROM Parts.OperationTemplate WHERE Code IN (N'TrimIn', N'TrimOut')` returns 2 rows.
- [ ] **Step 3: Commit** — `git commit -m "feat(arc2): Phase 4 seed 024 - Trim IN/OUT OperationTemplates"`

## Task A3: Read proc — `Parts.ItemLocation_CheckEligibility`

**Files:**
- Create: `sql/migrations/repeatable/R__Parts_ItemLocation_CheckEligibility.sql`
- Test: `sql/tests/0024_PlantFloor_Movement_Trim/010_ItemLocation_CheckEligibility.sql`

- [ ] **Step 1: Write the failing test** (harness pattern from `0022`/`0023`: `test.BeginTestFile`, fixtures, INSERT-EXEC into a temp table matching the SELECT shape, `test.Assert_IsEqual`, FK-safe teardown). Cover: Direct match → `IsEligible=1, Path='Direct'`; BomDerived match → `Path='BomDerived'`; ineligible → `IsEligible=0, Path=NULL`.

```sql
SET NOCOUNT ON; SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0024_PlantFloor_Movement_Trim/010_ItemLocation_CheckEligibility.sql';
GO
-- Direct-eligible pair from the view
DECLARE @ItemId BIGINT, @LocId BIGINT;
SELECT TOP 1 @ItemId = ItemId, @LocId = LocationId FROM Parts.v_EffectiveItemLocation WHERE Source = N'Direct' ORDER BY LocationId;

CREATE TABLE #E (IsEligible BIT, Path NVARCHAR(20));
INSERT INTO #E EXEC Parts.ItemLocation_CheckEligibility @ItemId = @ItemId, @LocationId = @LocId;
DECLARE @Elig NVARCHAR(10) = (SELECT CAST(IsEligible AS NVARCHAR(10)) FROM #E);
DECLARE @Path NVARCHAR(20) = (SELECT Path FROM #E);
EXEC test.Assert_IsEqual @TestName = N'[Elig] Direct IsEligible=1', @Expected = N'1', @Actual = @Elig;
EXEC test.Assert_IsEqual @TestName = N'[Elig] Direct Path', @Expected = N'Direct', @Actual = @Path;
DROP TABLE #E;

-- Ineligible: a real Item id at a location with no eligibility row
DECLARE @BadLoc BIGINT = (SELECT TOP 1 l.Id FROM Location.Location l
    WHERE l.DeprecatedAt IS NULL AND NOT EXISTS (SELECT 1 FROM Parts.v_EffectiveItemLocation v WHERE v.ItemId = @ItemId AND v.LocationId = l.Id)
    ORDER BY l.Id);
CREATE TABLE #N (IsEligible BIT, Path NVARCHAR(20));
INSERT INTO #N EXEC Parts.ItemLocation_CheckEligibility @ItemId = @ItemId, @LocationId = @BadLoc;
DECLARE @NElig NVARCHAR(10) = (SELECT CAST(IsEligible AS NVARCHAR(10)) FROM #N);
EXEC test.Assert_IsEqual @TestName = N'[Elig] Ineligible IsEligible=0', @Expected = N'0', @Actual = @NElig;
DROP TABLE #N;
GO
```

- [ ] **Step 2: Run it, expect FAIL** — `sql/tests/Run-Tests.ps1 -Filter "0024"` → fails ("Could not find stored procedure Parts.ItemLocation_CheckEligibility").
- [ ] **Step 3: Write the proc** (thin wrapper over the view; alias `Source AS Path`; prefer Direct over BomDerived; no status row — read proc):

```sql
-- ============================================================
-- Repeatable:  R__Parts_ItemLocation_CheckEligibility.sql
-- Description: Arc 2 Phase 4 (spec sec 4.1). Advisory eligibility read over
--              Parts.v_EffectiveItemLocation (Direct U BomDerived, FDS-02-012).
--              Returns one row: IsEligible BIT, Path NVARCHAR(20)
--              ('Direct'/'BomDerived'/NULL). Direct preferred over BomDerived.
--              Read proc: no status row, no OUTPUT params. @LocationId is generic
--              (Cell OR Area resolution). The authoritative gate is
--              Lots.Lot_MoveToValidated; this only drives UI pre-commit feedback.
-- ============================================================
CREATE OR ALTER PROCEDURE Parts.ItemLocation_CheckEligibility
    @ItemId     BIGINT,
    @LocationId BIGINT
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Path NVARCHAR(20) = (
        SELECT TOP 1 v.Source
        FROM Parts.v_EffectiveItemLocation v
        WHERE v.ItemId = @ItemId AND v.LocationId = @LocationId
        ORDER BY CASE WHEN v.Source = N'Direct' THEN 0 ELSE 1 END);

    SELECT CASE WHEN @Path IS NULL THEN CAST(0 AS BIT) ELSE CAST(1 AS BIT) END AS IsEligible,
           @Path AS Path;
END;
GO
```

- [ ] **Step 4: Run, expect PASS** — `Run-Tests.ps1 -Filter "0024"`.
- [ ] **Step 5: Commit** — `git commit -m "feat(arc2): Phase 4 ItemLocation_CheckEligibility read + test"`

## Task A4: Read procs — `Parts.Item_GetMaxParts` + `Lots.Lot_GetCellLineQuantity`

**Files:**
- Create: `sql/migrations/repeatable/R__Parts_Item_GetMaxParts.sql`
- Create: `sql/migrations/repeatable/R__Lots_Lot_GetCellLineQuantity.sql`
- Test: `sql/tests/0024_PlantFloor_Movement_Trim/020_Item_GetMaxParts_and_Lot_GetCellLineQuantity.sql`

- [ ] **Step 1: Write the failing test** — `Item_GetMaxParts` returns the set value and NULL when unset; `Lot_GetCellLineQuantity` sums `PieceCount` across **open** (`LotStatusCode <> 'Closed'`) LOTs of one Item at one Location, excluding Closed LOTs. Build two open LOTs of the same Item at one Cell via `Lots.Lot_Create`, assert the sum; close one (`Lots.Lot_UpdateStatus` to `Closed` if a valid transition exists, else direct status flip in fixture) and re-assert. Teardown FK order: `LotEventLog`/`OperationLog` → `LotMovement` → `LotStatusHistory` → `ProductionEvent`/`RejectEvent` → `LotGenealogyClosure` → `Lot`.

- [ ] **Step 2: Run, expect FAIL.**
- [ ] **Step 3: Write `Item_GetMaxParts`** (thin read):

```sql
-- ============================================================
-- Repeatable:  R__Parts_Item_GetMaxParts.sql
-- Description: Arc 2 Phase 4 (spec sec 4.1). Dedicated thin read of the OI-12
--              per-Item lineside cap. Returns one row: MaxParts INT NULL
--              (NULL = uncapped). The cap is enforced server-side in
--              Lots.Lot_MoveToValidated; this read shows remaining capacity in UI.
-- ============================================================
CREATE OR ALTER PROCEDURE Parts.Item_GetMaxParts
    @ItemId BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    SELECT MaxParts AS MaxParts FROM Parts.Item WHERE Id = @ItemId;
END;
GO
```

- [ ] **Step 4: Write `Lot_GetCellLineQuantity`** (sum open LOTs; generic location id):

```sql
-- ============================================================
-- Repeatable:  R__Lots_Lot_GetCellLineQuantity.sql
-- Description: Arc 2 Phase 4 (spec sec 4.1). Sums PieceCount across OPEN LOTs
--              (LotStatusCode <> 'Closed') of @ItemId whose CurrentLocationId =
--              @LocationId. Generic location id (sums at whatever tier the
--              destination is). One row: ExistingPieceCount INT (0 when none).
-- ============================================================
CREATE OR ALTER PROCEDURE Lots.Lot_GetCellLineQuantity
    @LocationId BIGINT,
    @ItemId     BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    SELECT ISNULL(SUM(l.PieceCount), 0) AS ExistingPieceCount
    FROM Lots.Lot l
    INNER JOIN Lots.LotStatusCode sc ON sc.Id = l.LotStatusId
    WHERE l.CurrentLocationId = @LocationId
      AND l.ItemId = @ItemId
      AND sc.Code <> N'Closed';
END;
GO
```

- [ ] **Step 5: Run, expect PASS. Step 6: Commit** — `git commit -m "feat(arc2): Phase 4 Item_GetMaxParts + Lot_GetCellLineQuantity reads + tests"`

## Task A5: Read proc — `Lots.Lot_GetWipQueueByLocation`

**Files:**
- Create: `sql/migrations/repeatable/R__Lots_Lot_GetWipQueueByLocation.sql`
- Test: `sql/tests/0024_PlantFloor_Movement_Trim/060_Lot_GetWipQueueByLocation.sql`

- [ ] **Step 1: Write the failing test** — arrival order (latest `LotMovement.MovedAt ASC`); Closed LOTs excluded; empty → 0 rows; `@IncludeDescendants=1` rolls up child locations. Move two LOTs into a Cell at different times (insert `LotMovement` with controlled `MovedAt`, or `Lot_MoveTo` sequentially), assert ordering by `LastMovementAt`.
- [ ] **Step 2: Run, expect FAIL.**
- [ ] **Step 3: Write the proc** — open LOTs at `@LocationId` (or descendants when `@IncludeDescendants=1`), ordered by latest `LotMovement.MovedAt ASC`. `@IncludeDescendants=0` is the Phase 4 path; the recursive branch uses `Location.Location`'s parent FK (confirm column name — flag 3 — mirror `Location.Terminal_ListContextCells`'s CTE with `OPTION (MAXRECURSION 8)`).

```sql
-- ============================================================
-- Repeatable:  R__Lots_Lot_GetWipQueueByLocation.sql
-- Description: Arc 2 Phase 4 (spec sec 4.1). The FIFO WIP queue at a location:
--              OPEN LOTs (LotStatusCode <> 'Closed') whose CurrentLocationId =
--              @LocationId (or a descendant when @IncludeDescendants=1), in
--              ARRIVAL order (latest LotMovement.MovedAt ASC). Consumed by Phase 5
--              Machining IN. Read proc; empty rowset = no WIP.
-- ============================================================
CREATE OR ALTER PROCEDURE Lots.Lot_GetWipQueueByLocation
    @LocationId         BIGINT,
    @IncludeDescendants BIT = 0
AS
BEGIN
    SET NOCOUNT ON;

    ;WITH Scope AS (
        SELECT @LocationId AS Id
        UNION ALL
        SELECT c.Id
        FROM Location.Location c
        INNER JOIN Scope s ON c.ParentLocationId = s.Id   -- confirm parent FK name (flag 3)
        WHERE @IncludeDescendants = 1
    ),
    LastMove AS (
        SELECT m.LotId, MAX(m.MovedAt) AS LastMovementAt
        FROM Lots.LotMovement m
        GROUP BY m.LotId
    )
    SELECT
        l.Id,
        l.LotName,
        l.ItemId,
        i.PartNumber       AS ItemPartNumber,
        i.Description      AS ItemDescription,
        l.PieceCount,
        l.LotStatusId,
        sc.Code            AS LotStatusCode,
        lm.LastMovementAt
    FROM Lots.Lot l
    INNER JOIN Lots.LotStatusCode sc ON sc.Id = l.LotStatusId
    INNER JOIN Parts.Item i          ON i.Id  = l.ItemId
    LEFT  JOIN LastMove lm           ON lm.LotId = l.Id
    WHERE l.CurrentLocationId IN (SELECT Id FROM Scope)
      AND sc.Code <> N'Closed'
    ORDER BY lm.LastMovementAt ASC, l.Id ASC
    OPTION (MAXRECURSION 8);
END;
GO
```

- [ ] **Step 4: Run, expect PASS. Step 5: Commit** — `git commit -m "feat(arc2): Phase 4 Lot_GetWipQueueByLocation read + test"`

## Task A6: Mutation proc — `Lots.Lot_MoveToValidated`

**Files:**
- Create: `sql/migrations/repeatable/R__Lots_Lot_MoveToValidated.sql`
- Test: `sql/tests/0024_PlantFloor_Movement_Trim/030_MoveToValidated.sql`

- [ ] **Step 1: Write the failing test** — eligible move succeeds + `LotMovement` row + `Lot.CurrentLocationId` updated + `LotMoved` audit row in `LotEventLog`; MaxParts overflow rejects with the OI-12 message; ineligible destination rejects (FDS-02-012); blocked LOT rejects; `MaxParts NULL` move is uncapped. Capture via `CREATE TABLE #M (Status BIT, Message NVARCHAR(500)); INSERT #M EXEC Lots.Lot_MoveToValidated ...`.
- [ ] **Step 2: Run, expect FAIL.**
- [ ] **Step 3: Write the proc** — validations BEFORE `BEGIN TRANSACTION`: (1) required params + LOT exists; (2) not-blocked (inlined mirror of `Lot_AssertNotBlocked` — read `LotStatusCode.BlocksProduction` + terminal `Closed`); (3) eligibility via `v_EffectiveItemLocation` at `@ToLocationId`; (4) MaxParts (when `Item.MaxParts IS NOT NULL`: reject when existing-open-pieces-at-dest + LOT.PieceCount > MaxParts; **NULL = uncapped**). Then one transaction: inline `LotMovement` insert + `Lot.CurrentLocationId` update + `Audit_LogOperation` `LotMoved` (entity `Lot` → `LotEventLog`; resolved From/To Location JSON). Full body mirrors `R__Lots_Lot_MoveTo.sql` (already read verbatim) with the eligibility + MaxParts gates inserted before the mutation. Reproduce the `Lot_MoveTo` structure exactly; add between the destination-exists check and `BEGIN TRANSACTION`:

```sql
        -- Eligibility (FDS-02-012): LOT's Item must resolve at the destination.
        DECLARE @ItemId BIGINT = (SELECT ItemId FROM Lots.Lot WHERE Id = @LotId);
        IF NOT EXISTS (SELECT 1 FROM Parts.v_EffectiveItemLocation
                       WHERE ItemId = @ItemId AND LocationId = @ToLocationId)
        BEGIN
            SET @Message = N'Item is not eligible at the destination location.';
            EXEC Audit.Audit_LogFailure @AppUserId=@AppUserId, @LogEntityTypeCode=N'Lot',
                 @EntityId=@LotId, @LogEventTypeCode=N'LotMoved', @FailureReason=@Message,
                 @ProcedureName=@ProcName, @AttemptedParameters=@Params;
            SELECT @Status AS Status, @Message AS Message; RETURN;
        END

        -- MaxParts cap (OI-12). NULL = uncapped (keeps Area-resolution Trim IN unconstrained).
        DECLARE @MaxParts INT = (SELECT MaxParts FROM Parts.Item WHERE Id = @ItemId);
        IF @MaxParts IS NOT NULL
        BEGIN
            DECLARE @Existing INT = (
                SELECT ISNULL(SUM(l2.PieceCount), 0)
                FROM Lots.Lot l2 INNER JOIN Lots.LotStatusCode s2 ON s2.Id = l2.LotStatusId
                WHERE l2.CurrentLocationId = @ToLocationId AND l2.ItemId = @ItemId AND s2.Code <> N'Closed');
            DECLARE @Incoming INT = (SELECT PieceCount FROM Lots.Lot WHERE Id = @LotId);
            IF @Existing + @Incoming > @MaxParts
            BEGIN
                SET @Message = N'Move would exceed Item MaxParts cap of ' + CAST(@MaxParts AS NVARCHAR(20))
                             + N' at the destination (' + CAST(@Existing AS NVARCHAR(20)) + N' existing + '
                             + CAST(@Incoming AS NVARCHAR(20)) + N' incoming).';
                EXEC Audit.Audit_LogFailure @AppUserId=@AppUserId, @LogEntityTypeCode=N'Lot',
                     @EntityId=@LotId, @LogEventTypeCode=N'LotMoved', @FailureReason=@Message,
                     @ProcedureName=@ProcName, @AttemptedParameters=@Params;
                SELECT @Status AS Status, @Message AS Message; RETURN;
            END
        END
```

Header documents: "validated sibling of `Lot_MoveTo`; the generic proc stays untouched for non-scan callers (Sort Cage, Area-resolution moves). Inlined move + inlined not-blocked guard (INSERT-EXEC/Msg-3915 rule)."

- [ ] **Step 4: Run, expect PASS. Step 5: Commit** — `git commit -m "feat(arc2): Phase 4 Lot_MoveToValidated (eligibility + MaxParts + move) + test"`

## Task A7: Mutation proc — `Workorder.TrimOut_Record`

**Files:**
- Create: `sql/migrations/repeatable/R__Workorder_TrimOut_Record.sql`
- Test: `sql/tests/0024_PlantFloor_Movement_Trim/040_TrimOut_Record_move_whole.sql`
- Test: `sql/tests/0024_PlantFloor_Movement_Trim/050_TrimOut_Record_validation.sql`

Signature: `@ParentLotId BIGINT, @OperationTemplateId BIGINT, @ShotCount INT = NULL, @ScrapCount INT = NULL, @DestinationCellLocationId BIGINT, @AppUserId BIGINT, @TerminalLocationId BIGINT = NULL → Status, Message, ProductionEventId` (`@ProductionEventId` returned in the `NewId` slot).

- [ ] **Step 1: Write `040` (happy path)** — whole LOT moves to destination; closing `ProductionEvent` written (cumulative counters, `TrimOut` template); `LotMovement` row written; LOT visible via `Lot_GetWipQueueByLocation` at the destination; **parent stays open — no split, no children, no closure rows** (assert `LotGenealogyClosure` count for the LOT unchanged = just its self-row). Capture `CREATE TABLE #T (Status BIT, Message NVARCHAR(500), NewId BIGINT)`.
- [ ] **Step 2: Write `050` (validation)** — missing destination rejects; non-eligible destination rejects (FDS-02-012); blocked LOT rejects (B2); counter regression (`< prior cumulative`) rejects (D1).
- [ ] **Step 3: Run both, expect FAIL.**
- [ ] **Step 4: Write the proc.** All validations before `BEGIN TRANSACTION`: required params; LOT exists; not-blocked (inlined mirror of `Lot_AssertNotBlocked`); destination eligibility (`v_EffectiveItemLocation` at `@DestinationCellLocationId`) — **no MaxParts at TrimOut** (Confirm B); counter non-negative; D1 cumulative-monotonic guard (new counters ≥ the LOT's prior cumulative, mirrored from `ProductionEvent_Record`). Then one transaction: (1) inline closing `ProductionEvent` insert (mirror of `R__Workorder_ProductionEvent_Record.sql` — `OperationTemplateId=@OperationTemplateId`, cumulative `ShotCount`/`ScrapCount`, `EventAt=SYSUTCDATETIME()`, `@AppUserId`, `@TerminalLocationId`), capture `@ProductionEventId = SCOPE_IDENTITY()`; (2) inline whole-LOT move (mirror of `Lot_MoveTo` — `LotMovement` insert with `FromLocationId=current` + `Lot.CurrentLocationId` update); (3) one `Audit_LogOperation` `TrimOutRecorded`, entity `ProductionEvent` (→ `OperationLog`), `EntityId=@ProductionEventId`, `NewValue` carrying the production event + resolved destination Location JSON, readable Description (`<LotName> · Trim · OUT to <DestName> (Shots=…, Scrap=…)`). The LOT keeps its cast/trim `ItemId` (rename is Phase 5). Final `SELECT @Status, @Message, @ProductionEventId AS NewId;`.
- [ ] **Step 5: Run both, expect PASS. Step 6: Commit** — `git commit -m "feat(arc2): Phase 4 TrimOut_Record (closing checkpoint + whole-LOT move) + tests"`

## Task A8: Receiving pass-through test (no net-new SQL)

**Files:**
- Test: `sql/tests/0024_PlantFloor_Movement_Trim/070_Receiving_pass_through.sql`

- [ ] **Step 1: Write the test** — `Lots.Lot_Create` with the `Received` `LotOriginType`, a Receiving Dock `@CurrentLocationId`, NULL Tool/Cavity, `@VendorLotNumber`, `@MinSerialNumber`/`@MaxSerialNumber`; assert the LOT row captured vendor lot + serial range, NULL Tool/Cavity, and a `LotCreated` audit row. (Confirms reuse — no proc authored.) The Item must be eligible at the Receiving Dock location (use a `v_EffectiveItemLocation` Direct pair, or seed eligibility in the fixture).
- [ ] **Step 2: Run, expect PASS** (proc already exists). **Step 3: Commit** — `git commit -m "test(arc2): Phase 4 Receiving pass-through via Lot_Create"`

## Task A9: Phase A green gate

- [ ] **Step 1:** Run the full suite `sql/tests/Run-Tests.ps1` — confirm `0024_PlantFloor_Movement_Trim` passes (target 55–75 assertions) and the prior total stays green (no regressions). If exit 1 with 0 failures, a fixture threw — check FK teardown order (`feedback_runtests_exit1_zero_failures`).
- [ ] **Step 2: Commit** any test fixups — `git commit -m "test(arc2): Phase 4 0024 suite green"`

---

# PHASE B — SQL: migration `0025` label dispatch + proc deltas + tests

## Task B1: Migration `0025` (ALTER + LabelDispatched seed)

**Files:**
- Create: `sql/migrations/versioned/0025_arc2_phase4_label_dispatch.sql`

- [ ] **Step 1: Write the migration** — `ALTER TABLE Lots.LotLabel ADD DispatchedAt DATETIME2(3) NULL` (idempotent via `COL_LENGTH` guard, mirror `0013`); seed `Audit.LogEventType` **36** `LabelDispatched`; SchemaVersion row. (`PrinterName` already exists — no column add.)

```sql
-- ============================================================
-- Migration:   0025_arc2_phase4_label_dispatch.sql
-- Author:      Blue Ridge Automation
-- Date:        2026-06-16
-- Description: Arc 2 Phase 4 label-dispatch delta (gateway-coupled; kept out of
--              0024 per the Spec-1/Spec-2 split).
--                + Lots.LotLabel.DispatchedAt DATETIME2(3) NULL (dispatch-ack ts,
--                  distinct from PrintedAt). PrinterName already exists (0021).
--                + Audit.LogEventType 36 LabelDispatched (InterfaceLog rows).
--              The @PrinterName param on LotLabel_Print/_Reprint and the new
--              LotLabel_RecordDispatch proc are repeatable migrations (B2/B3).
--              Idempotent. ASCII-only.
-- ============================================================
IF COL_LENGTH('Lots.LotLabel', 'DispatchedAt') IS NULL
    ALTER TABLE Lots.LotLabel ADD DispatchedAt DATETIME2(3) NULL;
GO

IF NOT EXISTS (SELECT 1 FROM Audit.LogEventType WHERE Id = 36 OR Code = N'LabelDispatched')
    INSERT INTO Audit.LogEventType (Id, Code, Name, Description) VALUES
        (36, N'LabelDispatched', N'Label Dispatched', N'An LTT/label ZPL payload was dispatched to a networked printer over raw TCP (logged to InterfaceLog on every attempt).');
GO

IF NOT EXISTS (SELECT 1 FROM dbo.SchemaVersion WHERE MigrationId = N'0025_arc2_phase4_label_dispatch')
    INSERT INTO dbo.SchemaVersion (MigrationId, Description)
    VALUES (N'0025_arc2_phase4_label_dispatch',
            N'Arc 2 Phase 4 label dispatch: LotLabel.DispatchedAt added; LogEventType 36 LabelDispatched. @PrinterName params + LotLabel_RecordDispatch are repeatable.');
GO
PRINT 'Migration 0025 (Arc 2 Phase 4 label dispatch) applied.';
GO
```

- [ ] **Step 2: Apply + verify** — `Reset-DevDatabase.ps1`; `COL_LENGTH('Lots.LotLabel','DispatchedAt')` not null; `MAX(Id) FROM Audit.LogEventType` = 36. **Step 3: Commit.**

## Task B2: `@PrinterName` deltas on `LotLabel_Print` + `LotLabel_Reprint`

**Files:**
- Modify: `sql/migrations/repeatable/R__Lots_LotLabel_Print.sql`
- Modify: `sql/migrations/repeatable/R__Lots_LotLabel_Reprint.sql`
- Test: `sql/tests/0025_PlantFloor_Label_Dispatch/010_LotLabel_PrinterName_roundtrip.sql`

- [ ] **Step 1: Write the failing test** — call `LotLabel_Print` with `@PrinterName=N'DC1-PRN'`; assert the inserted `Lots.LotLabel` row has `PrinterName='DC1-PRN'`; same for `Reprint`.
- [ ] **Step 2: Run, expect FAIL.**
- [ ] **Step 3: Edit both procs** — add `@PrinterName NVARCHAR(100) = NULL` as the final param; add `PrinterName` to the `INSERT INTO Lots.LotLabel (...)` column list and `@PrinterName` to the `VALUES (...)`. (Both procs read verbatim already; the INSERT column list currently omits `PrinterName` — add it after `ZplContent`.) Update the header `DEFERRED` note to "delivered Phase 4."
- [ ] **Step 4: Run, expect PASS. Step 5: Commit** — `git commit -m "feat(arc2): Phase 4 @PrinterName on LotLabel_Print/_Reprint + test"`

## Task B3: New proc — `Lots.LotLabel_RecordDispatch`

**Files:**
- Create: `sql/migrations/repeatable/R__Lots_LotLabel_RecordDispatch.sql`
- Test: `sql/tests/0025_PlantFloor_Label_Dispatch/020_LotLabel_RecordDispatch.sql`

- [ ] **Step 1: Write the failing test** — print a label (capture `@LotLabelId`), call `LotLabel_RecordDispatch @LotLabelId, @PrinterName=N'DC1-PRN'`; assert `Status=1`, the row's `DispatchedAt IS NOT NULL` and `PrinterName='DC1-PRN'`; calling with a bad `@LotLabelId` returns `Status=0`.
- [ ] **Step 2: Run, expect FAIL.**
- [ ] **Step 3: Write the proc** (status-row mutation; sets `PrinterName` + `DispatchedAt = SYSUTCDATETIME()`):

```sql
-- ============================================================
-- Repeatable:  R__Lots_LotLabel_RecordDispatch.sql
-- Description: Arc 2 Phase 4 (Spec 2 sec 4). Dispatch-ack write-back: the gateway
--              records that a LotLabel's ZPL reached the printer. Sets PrinterName
--              + DispatchedAt on the existing row. Status-row proc (NQ type=Query).
--              No audit row here (the dispatch attempt itself logs to InterfaceLog
--              via the entity script + Audit_LogInterfaceCall). No OUTPUT params.
-- ============================================================
CREATE OR ALTER PROCEDURE Lots.LotLabel_RecordDispatch
    @LotLabelId  BIGINT,
    @PrinterName NVARCHAR(100)
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;
    DECLARE @Status BIT = 0;
    DECLARE @Message NVARCHAR(500) = N'Unknown error';
    BEGIN TRY
        IF @LotLabelId IS NULL
        BEGIN
            SET @Message = N'Required parameter missing (LotLabelId).';
            SELECT @Status AS Status, @Message AS Message; RETURN;
        END
        IF NOT EXISTS (SELECT 1 FROM Lots.LotLabel WHERE Id = @LotLabelId)
        BEGIN
            SET @Message = N'LotLabel not found.';
            SELECT @Status AS Status, @Message AS Message; RETURN;
        END
        UPDATE Lots.LotLabel
        SET PrinterName = @PrinterName, DispatchedAt = SYSUTCDATETIME()
        WHERE Id = @LotLabelId;
        SET @Status = 1; SET @Message = N'Dispatch recorded.';
        SELECT @Status AS Status, @Message AS Message;
    END TRY
    BEGIN CATCH
        DECLARE @ErrMsg NVARCHAR(4000) = ERROR_MESSAGE(), @ErrSev INT = ERROR_SEVERITY(), @ErrState INT = ERROR_STATE();
        SET @Status = 0; SET @Message = N'Unexpected error: ' + LEFT(@ErrMsg, 400);
        SELECT @Status AS Status, @Message AS Message;
        RAISERROR(@ErrMsg, @ErrSev, @ErrState);
    END CATCH
END;
GO
```

- [ ] **Step 4: Run, expect PASS. Step 5: Commit** — `git commit -m "feat(arc2): Phase 4 LotLabel_RecordDispatch + test"`

## Task B4: Phase B green gate

- [ ] Run `sql/tests/Run-Tests.ps1` — `0025_PlantFloor_Label_Dispatch` green, full total green. Commit any fixups.

---

# PHASE C — Core Named Queries (9)

All under `ignition/projects/Core/ignition/named-query/`. Each NQ is a folder `<group>/<name>/{query.sql, resource.json}`. Mirror the verified v2 `resource.json` shape (`scope:"DG"`, `database:"MPP"`, `type:"Query"`, alphabetical `attributes` ordering per Designer). `sqlType`: `3`=BIGINT, `7`=NVARCHAR, `2`=INT, `6`=BIT.

| # | NQ folder | `query.sql` (EXEC) | params (`identifier`:sqlType) | type |
|---|---|---|---|---|
| 1 | `parts/ItemLocation_CheckEligibility` | `Parts.ItemLocation_CheckEligibility @ItemId=:itemId, @LocationId=:locationId` | itemId:3, locationId:3 | Query |
| 2 | `parts/Item_GetMaxParts` | `Parts.Item_GetMaxParts @ItemId=:itemId` | itemId:3 | Query |
| 3 | `lots/Lot_GetCellLineQuantity` | `Lots.Lot_GetCellLineQuantity @LocationId=:locationId, @ItemId=:itemId` | locationId:3, itemId:3 | Query |
| 4 | `lots/Lot_GetWipQueueByLocation` | `Lots.Lot_GetWipQueueByLocation @LocationId=:locationId, @IncludeDescendants=:includeDescendants` | locationId:3, includeDescendants:6 | Query |
| 5 | `lots/Lot_MoveToValidated` | `Lots.Lot_MoveToValidated @LotId=:lotId, @ToLocationId=:toLocationId, @AppUserId=:appUserId, @TerminalLocationId=:terminalLocationId` | lotId:3, toLocationId:3, appUserId:3, terminalLocationId:3 | **Query (mutation)** |
| 6 | `workorder/TrimOut_Record` | `Workorder.TrimOut_Record @ParentLotId=:parentLotId, @OperationTemplateId=:operationTemplateId, @ShotCount=:shotCount, @ScrapCount=:scrapCount, @DestinationCellLocationId=:destinationCellLocationId, @AppUserId=:appUserId, @TerminalLocationId=:terminalLocationId` | parentLotId:3, operationTemplateId:3, shotCount:2, scrapCount:2, destinationCellLocationId:3, appUserId:3, terminalLocationId:3 | **Query (mutation)** |
| 7 | `lots/LotLabel_Print` (update existing NQ + add `@PrinterName=:printerName`) | `Lots.LotLabel_Print @LotId=:lotId, @LabelTypeCodeId=:labelTypeCodeId, @PrintReasonCodeId=:printReasonCodeId, @AppUserId=:appUserId, @TerminalLocationId=:terminalLocationId, @PrinterName=:printerName` | …, printerName:7 | **Query** |
| 8 | `lots/LotLabel_Reprint` (update existing NQ + add `@PrinterName=:printerName`) | `Lots.LotLabel_Reprint @LotId=:lotId, @PrintReasonCodeId=:printReasonCodeId, @AppUserId=:appUserId, @TerminalLocationId=:terminalLocationId, @PrinterName=:printerName` | …, printerName:7 | **Query** |
| 9 | `lots/LotLabel_RecordDispatch` | `Lots.LotLabel_RecordDispatch @LotLabelId=:lotLabelId, @PrinterName=:printerName` | lotLabelId:3, printerName:7 | **Query** |

- [ ] **Task C1:** Create NQ folders 1–6 (movement/trim). Reference `resource.json` template (clone from `Core/.../named-query/lots/Lot_MoveTo/resource.json`, verified shape):

```json
{
  "scope": "DG", "version": 2, "restricted": false, "overridable": true,
  "files": ["query.sql"],
  "attributes": {
    "useMaxReturnSize": false, "autoBatchEnabled": false, "fallbackValue": "",
    "maxReturnSize": 100, "cacheUnit": "SEC", "type": "Query", "enabled": true,
    "cacheAmount": 1, "cacheEnabled": false, "database": "MPP", "fallbackEnabled": false,
    "lastModificationSignature": "",
    "permissions": [{ "zone": "", "role": "" }],
    "lastModification": { "actor": "claude", "timestamp": "2026-06-16T12:00:00Z" },
    "parameters": [ { "type": "Parameter", "identifier": "<id>", "sqlType": <code> } ]
  }
}
```

- [ ] **Task C2:** Create NQ folder 9; **edit** NQs 7 + 8 (`lots/LotLabel_Print`, `lots/LotLabel_Reprint`) — append the `@PrinterName=:printerName` line to `query.sql` and a `{identifier:"printerName", sqlType:7}` entry to `parameters[]`. (These NQs exist from Phase 2 — confirm under `Core/.../named-query/lots/`; if absent, create them full.)
- [ ] **Task C3:** `.\scan.ps1`, then **restart the Ignition gateway** (new Core NQs need a restart to register for inherited visibility — `project_mpp_nq_core_topology`). Verify in Designer Script Console: `system.db.runNamedQuery("parts/Item_GetMaxParts", {"itemId": <id>})` returns a row.
- [ ] **Task C4: Commit** — `git commit -m "feat(arc2): Phase 4 Core named queries (9)"`

---

# PHASE D — Core entity scripts

All under `ignition/projects/Core/ignition/script-python/BlueRidge/`. Thin wrappers over `Common.Db.*`; log entry/exit; no `system.db.*`; no business logic. Add functions to existing modules where they exist.

- [ ] **Task D1: `Parts/ItemLocation/code.py`** (new module) —
  - `checkEligibility(itemId, locationId)` → `Common.Db.execOne("parts/ItemLocation_CheckEligibility", {"itemId": itemId, "locationId": locationId})` (returns `{IsEligible, Path}` or `None`).
  - `checkEligibilityOrEmpty(itemId, locationId)` → binding-safe variant returning `{"IsEligible": False, "Path": None}` when `None` (pre-declared-bound-prop rule).
  - Add `resource.json` (`scope:"A"`, `hintScope:2`).
- [ ] **Task D2: `Parts/Item/code.py`** — add `getMaxParts(itemId)` → `Common.Db.execOne("parts/Item_GetMaxParts", {"itemId": itemId})` (returns `{MaxParts}` or `None`).
- [ ] **Task D3: `Lots/Lot/code.py`** — add `moveToValidated(lotId, toLocationId, appUserId=None, terminalLocationId=None)` (defaults `appUserId` via `Common.Util._currentAppUserId()`; `Common.Db.execMutation`); `getCellLineQuantity(locationId, itemId)`; `getWipQueueByLocation(locationId, includeDescendants=False)`; confirm `getByName(lotName)` exists (it does — `get(lotName=...)`).
- [ ] **Task D4: `Workorder/TrimOut/code.py`** (new module) — `record(data, appUserId=None, terminalLocationId=None)`: shape params `{parentLotId, operationTemplateId, shotCount, scrapCount, destinationCellLocationId, appUserId, terminalLocationId}`, `Common.Db.execMutation("workorder/TrimOut_Record", params)`. Add `resource.json`.
- [ ] **Task D5: `Location/Terminal/code.py`** — add `getPrinter(terminalLocationId)`: resolve the terminal's child `Printer` Location + its `Endpoint`/`Model` LocationAttributes via existing Location attribute reads (or a thin new NQ if none fits — confirm against `Location/Location/code.py` attribute readers). Returns `{locationId, code, endpoint, model}` or `{}` (empty when no child Printer / `HasPrinter` false).
- [ ] **Task D6: `Lots/LotLabel/code.py`** (new module) — the dispatch orchestrator (spec §3/§4.2):
  - `_dispatchZpl(endpoint, zpl)` — pure transport: parse `host:port` (default `9100`); `java.net.Socket`; `connect((host,port), timeoutMs)` bounded 3–5 s; `getOutputStream().write(zpl.getBytes("US-ASCII"))`; `flush()`; `close()`; return `{"ok": bool, "error": str|None}`. No business logic.
  - `_logDispatch(endpoint, zpl, outcome, appUserId, terminalLocationId)` — wrap `Audit_LogInterfaceCall` (confirm signature — flag 2) with `Direction='Outbound'`, event `LabelDispatched`, `RequestPayload`=endpoint+ZPL head, `ResponsePayload`/`ErrorCondition`/`ErrorDescription`=outcome. Logged on **every** attempt.
  - `print(data, appUserId=None, terminalLocationId=None)` — orchestrates: `execMutation("lots/LotLabel_Print", {... , "printerName": <session printer code>})` → read `session.custom.printer.endpoint`; **fail-fast** `{"Status":0,"Message":"This terminal has no printer configured."}` when empty → `_dispatchZpl` → `_logDispatch` → on success `execMutation("lots/LotLabel_RecordDispatch", {...})` and return `{"Status":1,...}` → on failure: single re-resolve of endpoint from DB (`Terminal.getPrinter`), retry once + log, else `{"Status":0,"Message":<reason>}`. **Print failure never undoes the LOT.**
  - `reprint(lotId, printReasonCodeId, appUserId=None, terminalLocationId=None)` — same dispatch path over `lots/LotLabel_Reprint`.
  - Add `resource.json`.
- [ ] **Task D7:** `.\scan.ps1`; smoke each in Script Console (e.g. `BlueRidge.Parts.Item.getMaxParts(<id>)`). **Commit** — `git commit -m "feat(arc2): Phase 4 Core entity scripts (ItemLocation, Item, Lot, TrimOut, Terminal, LotLabel)"`

---

# PHASE E — `onStartup` printer resolution + session shape

- [ ] **Task E1: session-props** — `ignition/projects/MPP/com.inductiveautomation.perspective/session-props/props.json`: add to the `custom` block (after `terminal`):

```json
"printer": { "locationId": null, "code": "", "endpoint": "", "model": "" }
```

- [ ] **Task E2: `onStartup.py`** — `ignition/projects/MPP/com.inductiveautomation.perspective/startup/onStartup.py`: after `session.custom.terminal` is set, resolve the child printer and declare it:

```python
	# Resolve the terminal's child Printer into session.custom.printer (one DB
	# round-trip per session; the label-dispatch path reads it). Empty dict when
	# the terminal has no Printer (HasPrinter false / FALLBACK-TERMINAL).
	prn = BlueRidge.Location.Terminal.getPrinter(session.custom.terminal.get("terminalLocationId"))
	session.custom.printer = {
		"locationId": prn.get("locationId") if prn else None,
		"code":       (prn.get("code") if prn else "") or "",
		"endpoint":   (prn.get("endpoint") if prn else "") or "",
		"model":      (prn.get("model") if prn else "") or "",
	}
```

- [ ] **Task E3:** `.\scan.ps1`; open a Perspective session at a terminal with a child Printer → confirm `session.custom.printer.endpoint` populated; at `FALLBACK-TERMINAL` → empty. **Commit** — `git commit -m "feat(arc2): Phase 4 onStartup printer resolution + session.custom.printer"`

---

# PHASE F — MPP Perspective views (parallelizable)

Per `feedback_parallel_view_authoring_convergence`: these three NEW views can be authored by parallel subagents (each owns ONLY its folder; the controller converges routes + scan + commit). All under `ignition/projects/MPP/com.inductiveautomation.perspective/views/BlueRidge/...`. Flex-repeater ROW sub-views under `Components/PlantFloor/<Page>/<Row>` (never nested in a page-view folder). `meta.name:"root"`; pre-declare bound custom props with shaped defaults; ≥44px targets; portrait.

## Task F1: `Components/PlantFloor/MovementScan` (reusable embedded component) — MVP

Mirror `Components/PlantFloor/CellContextSelector` (verified pattern: `params` input, `view.custom` state, `customMethods`, page-scoped reply).

- **params:** `replyMessage` (string, input), `destinationLocationId` (BIGINT, input).
- **view.custom (shaped defaults):** `scanCode:""`, `lot:{}` (full Lot_Get shape with `Id`/`ItemId`/`PieceCount` keys = null), `eligibility:{"IsEligible":false,"Path":null}`, `maxParts:{"MaxParts":null}`, `existingQty:{"ExistingPieceCount":0}`, `phase:"scan"` (scan→review→done).
- **root (`ia.container.flex` column):** label "Scan LTT"; one `ia.input.text-field` bound bidi to `view.custom.scanCode` (`dom.onBlur` → `applyScan()`); a review panel (`position.display` gated on `phase != 'scan'`) showing LOT name/item/pieces + an eligibility message (FDS-02-012 reject text when `eligibility.IsEligible=false`) + "N of M capacity" (`existingQty + lot.PieceCount` vs `maxParts.MaxParts`); a **Move** button (`onActionPerformed` scope G → `commitMove()`), enabled only when `eligibility.IsEligible`.
- **customMethods:**
  - `applyScan()` → `lot = BlueRidge.Lots.Lot.get(lotName=scanCode)`; if found: `eligibility = BlueRidge.Parts.ItemLocation.checkEligibilityOrEmpty(lot.ItemId, params.destinationLocationId)`; `maxParts = BlueRidge.Parts.Item.getMaxParts(lot.ItemId)`; `existingQty = BlueRidge.Lots.Lot.getCellLineQuantity(params.destinationLocationId, lot.ItemId)`; set `phase="review"`.
  - `commitMove()` → `result = BlueRidge.Lots.Lot.moveToValidated(lot.Id, params.destinationLocationId)`; `Common.Ui.notifyResult(result, "Moved")`; on `Status` → `sendMessage(params.replyMessage, {"lotId": lot.Id, ...}, scope="page")` + reset to `phase="scan"`, `scanCode=""`.
- **Row sub-views:** none (single LOT at a time).

## Task F2: `Views/ShopFloor/TrimStation` (one tabbed top-level view) — MVP

Mirror `Views/ShopFloor/LotDetail` tab shell (`ia.container.tab`, `menuType:"modern"`, `menuStyle`/`contentStyle`/`tabStyle` slots). Header: `InitialsField` embed + `PausedLotIndicator` embed (`params.locationId` = Trim Shop Area id from `session.custom`). Shared context: `view.custom.activeLotId`.

- **IN tab (`position.tabIndex:0`):** `MovementScan` embed (`params.destinationLocationId` = Trim Shop **Area** id; `params.replyMessage="trimInMoved"`). A page-scoped handler `trimInMoved` sets `view.custom.activeLotId` then calls `BlueRidge.Workorder` `ProductionEvent.record` with the `TrimIn` template id + carried-forward cumulative counters (read prior via `Lot.getHistory`/a checkpoint read). Optional **Record scrap** button → `RejectEvent.record`; optional **Correct piece count** → `Lot.update` (FRS 2.2.3). Trim = yield-loss only; no rename/genealogy.
- **OUT tab (`position.tabIndex:1`):** one destination selector = `ia.input.dropdown` with `props.allowCustomOptions:true` + `props.search.enabled:true` (scan **or** pick, FDS-02-009; options = Machining-line destinations via a dropdown entity call); a LTT scan field to set `activeLotId`; shot/scrap inputs; **Trim OUT** button → `BlueRidge.Workorder.TrimOut.record({parentLotId: activeLotId, operationTemplateId: <TrimOut id>, shotCount, scrapCount, destinationCellLocationId, ...})` → `notifyResult` → on success `navigate("/shop-floor/lot-detail/<lotId>")`. No split/multi-destination UX (Phase 5).
- **Row sub-views:** `Components/PlantFloor/TrimStation/WipQueueRow` only if the OUT picker lists queue entries (else none).

## Task F3: `Views/ShopFloor/ReceivingDock` — MVP

`Lot.create` form; `currentLocationId = session.custom.cell.locationId` (Receiving Dock); no movement (creation).

- **Fields:** PartNumber = `ia.input.dropdown` `allowCustomOptions:true` (scan or pick, resolved via `BlueRidge.Parts.Item.getByPartNumber`); VendorLotNumber (text); PieceCount (`ia.input.text-field` + proc coercion); optional `MinSerialNumber`/`MaxSerialNumber` (text).
- **Create button** → `BlueRidge.Lots.Lot.create({itemId, lotOriginTypeId: <Received id>, currentLocationId, pieceCount, vendorLotNumber, minSerialNumber, maxSerialNumber})` → `notifyResult` → on success **print the LTT** via `BlueRidge.Lots.LotLabel.print({lotId: NewId, labelTypeCodeId: <Primary>, printReasonCodeId: <Initial>})` (the §3 dispatch path) → handle print-failure state (toast + **Reprint** button re-firing `LotLabel.reprint`) → `navigate("/shop-floor/lot-detail/<NewId>")`.

- [ ] **Task F4 (controller):** after the three views are authored — `.\scan.ps1`; create their `resource.json` + (gitignored) `thumbnail.png` handled by gateway. **Commit** — `git commit -m "feat(arc2): Phase 4 MovementScan + TrimStation + ReceivingDock views"`

---

# PHASE G — Routes, HomeRouter tiles, integration

- [ ] **Task G1: page-config** — `ignition/projects/MPP/com.inductiveautomation.perspective/page-config/config.json`: add

```json
"/shop-floor/trim":      { "title": "Trim",      "viewPath": "BlueRidge/Views/ShopFloor/TrimStation" },
"/shop-floor/receiving": { "title": "Receiving", "viewPath": "BlueRidge/Views/ShopFloor/ReceivingDock" }
```

- [ ] **Task G2: HomeRouter tiles** — `Views/ShopFloor/HomeRouter/view.json`: add Trim + Receiving nav tiles, gated by the terminal's resolved context (mirror existing tiles; no new session props beyond `session.custom.printer`).
- [ ] **Task G3:** `.\scan.ps1`. **Commit** — `git commit -m "feat(arc2): Phase 4 routes + HomeRouter tiles"`
- [ ] **Task G4: Smoke seed + walkthrough** — write `sql/scratch/smoke_seed_phase4.sql` (idempotent; prints LOT ids + the `/shop-floor/trim` and `/shop-floor/receiving` URLs; mirror `smoke_seed_phase2.sql`). Run the spec §10 walkthrough: Trim IN (eligibility + capacity + checkpoint + scrap), Trim OUT (→ FIFO queue visible in LOT Detail), Receiving (create + LTT print; pull endpoint → failure toast + Reprint; confirm an `Audit.InterfaceLog` row per attempt), empty-printer fail-fast.

---

# Final review (Phase H)

- [ ] **H1:** Full SQL suite green (`Run-Tests.ps1`), `0024` + `0025` included, no regressions.
- [ ] **H2:** `git diff --stat` every `view.json` before staging — guard against Designer pickling live data (`feedback_designer_pickles_live_data`); structural deltas only.
- [ ] **H3:** Verify no `view.custom.*` binding-read prop lacks a shaped default; no `system.perspective.*` dom-event handler missing `scope:"G"`; all event-script bodies start with `\t`.
- [ ] **H4:** `requesting-code-review` on the branch.
- [ ] **H5:** Update `PROJECT_STATUS.md` (Phase 4 built; migrations `0024`/`0025` taken; Phase 5 renumbers to `0026+`) and the Plant Floor plan's migration baseline note.

---

## Self-review (spec coverage)

| Spec requirement | Task |
|---|---|
| SQL `0024` audit seeds (34/35), drop ReceivingScan | A1 |
| Trim IN/OUT OperationTemplates, no fields (seed `024`) | A2 |
| `ItemLocation_CheckEligibility` | A3 |
| `Item_GetMaxParts`, `Lot_GetCellLineQuantity` | A4 |
| `Lot_GetWipQueueByLocation` (Phase 5 consumer) | A5 |
| `Lot_MoveToValidated` (eligibility + MaxParts + inline move) | A6 |
| `TrimOut_Record` (closing checkpoint + whole-LOT move, no split) | A7 |
| Receiving via `Lot_Create` reuse | A8 |
| `0024` suite 55–75 | A3–A9 |
| `0025` migration: `DispatchedAt` + LabelDispatched | B1 |
| `@PrinterName` on Print/Reprint | B2 |
| `LotLabel_RecordDispatch` | B3 |
| Core NQs (9, mutations type=Query) | C |
| Entity scripts (ItemLocation/Item/Lot/TrimOut/Terminal/LotLabel) | D |
| Synchronous ZPL dispatch + InterfaceLog every attempt + fail-fast | D6 |
| `onStartup` printer resolution + `session.custom.printer` | E |
| MovementScan / Trim Station (tabbed IN/OUT) / Receiving Dock | F |
| scan-or-dropdown = `allowCustomOptions` | F2/F3 |
| Print failure never rolls back LOT; Reprint path | D6/F3 |
| Routes + HomeRouter tiles | G1/G2 |
| Smoke seed + walkthrough | G4 |
