# Arc 2 Phase 1 — SQL Foundation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deliver the Arc 2 Phase 1 SQL foundation — migration `0020_arc2_phase1_shop_floor_foundation.sql`, all Phase 1 stored procedures, and the `sql/tests/0020_PlantFloor_Foundation/` test suite green (target 80–105 tests).

**Architecture:** SQL-first. One versioned migration creates the plant-floor core tables (WorkOrder family, Lot family, IdentifierSequence, closure, LotEventLog, eligibility view) born partitioned where applicable, plus the OI-35 scaling infrastructure (monthly RANGE-RIGHT partitioning with `TRUNCATE`-based sliding-window, singleton `Id` PK preserved). Stored procs follow the project's no-OUTPUT-param / status-row / nested-CATCH conventions. The Ignition layer (Gateway scripts + Perspective views) is a separate follow-on push.

**Tech Stack:** SQL Server 2022, `sqlcmd`-applied migrations, `test.Assert_*` framework, `Reset-DevDatabase.ps1` discovery.

**Authoritative source docs (read before each task):**
- Design spec: `docs/superpowers/specs/2026-06-09-arc2-phase1-sql-foundation-design.md`
- Column contracts: `MPP_MES_DATA_MODEL.md` v1.9q (§3 Lots, §4 Workorder, §1 Location, §2 Parts)
- Proc contracts: `MPP_MES_PHASED_PLAN_PLANT_FLOOR.md` Phase 1 §"API Layer (Named Queries → Stored Procedures)"
- Conventions: `sql_best_practices_mes.md`, `sql_version_control_guide.md`, `CLAUDE.md` (no-OUTPUT-param rule, audit-readable Description, ASCII-only seeds)
- Proc template: `sql/scripts/_TEMPLATE_stored_procedure.sql`
- Phase 0 decisions: `Meeting_Notes/2026-06-08_Phase0_Decision_Log.md`

**Conventions every task obeys (do not restate per-proc):**
- `UpperCamelCase`; `BIGINT IDENTITY Id` PK; `BIGINT` FKs; `NVARCHAR`; `DATETIME2(3)`; `DECIMAL` not `FLOAT`.
- Mutation procs: `@Status`/`@Message`/`@NewId` are **local variables**; every exit path ends `SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;` (drop `@NewId` for Update/Status/Move). **No OUTPUT params.**
- Read procs: empty result set = not found. **No OUTPUT params.** One result set per proc.
- `RAISERROR` (not `THROW`) in nested CATCH with failure-logging.
- Audit-writer procs emit **no** result set.
- Mutation procs take `@AppUserId BIGINT`, `@TerminalLocationId BIGINT` (B1); LOT-advancing procs call `Lots.Lot_AssertNotBlocked` first (B2).
- Audit `Description` uses `Audit.ufn_MidDot()` + `Audit.ufn_TruncateActivity()`; resolved-FK JSON via `JSON_QUERY((... FOR JSON PATH, WITHOUT_ARRAY_WRAPPER))`.
- Seed strings ASCII-only (byte-scan before apply).
- Repeatable procs live in `sql/migrations/repeatable/R__<Schema>_<Proc>.sql`, one proc per file, header comment with version.

---

## File Structure

**Migration (versioned, single file, applied once):**
- Create: `sql/migrations/versioned/0020_arc2_phase1_shop_floor_foundation.sql`

**Repeatable procs (one file each):**
- `sql/migrations/repeatable/R__Location_Terminal_GetByIpAddress.sql`
- `sql/migrations/repeatable/R__Location_Terminal_List.sql`
- `sql/migrations/repeatable/R__Location_AppUser_GetByInitials.sql`
- `sql/migrations/repeatable/R__Location_AppUser_AuthenticateAd.sql`
- `sql/migrations/repeatable/R__Location_AppUser_GetRoles.sql`
- `sql/migrations/repeatable/R__Oee_Shift_Start.sql`, `_End`, `_GetActive`, `_GetOpen`
- `sql/migrations/repeatable/R__Lots_IdentifierSequence_Next.sql`
- `sql/migrations/repeatable/R__Lots_Lot_Create.sql`
- `sql/migrations/repeatable/R__Lots_Lot_Get.sql`, `_List`, `_UpdateStatus`, `_MoveTo`, `_AssertNotBlocked`
- `sql/migrations/repeatable/R__Audit_Audit_LogOperation.sql` (MODIFY existing — add B7 routing)
- `sql/migrations/repeatable/R__Audit_Partition_MaintainWindow.sql`

**Tests:**
- `sql/tests/0020_PlantFloor_Foundation/010_Terminal_GetByIpAddress.sql` … `090_Partition_MaintainWindow.sql`

---

## Task A: Partitioning infrastructure + migration skeleton (IN-SESSION / dedicated agent — novel)

**Files:**
- Create: `sql/migrations/versioned/0020_arc2_phase1_shop_floor_foundation.sql` (skeleton + partitioning section)
- Create: `sql/migrations/repeatable/R__Audit_Partition_MaintainWindow.sql`
- Test: `sql/tests/0020_PlantFloor_Foundation/090_Partition_MaintainWindow.sql`

**Read first:** design spec §3 (partitioning design), Risk items 1–3.

- [ ] **Step 1: Confirm dev edition supports partitioning**

Run:
```sql
SELECT SERVERPROPERTY('EngineEdition') AS EngineEdition, SERVERPROPERTY('ProductVersion') AS Version;
```
Expected: `EngineEdition` ∈ {2 (Standard), 3 (Enterprise/Developer)} — NOT 4 (Express). If Express, STOP and escalate (partitioning unavailable).

- [ ] **Step 2: Write the partition function + scheme (migration top section)**

In `0020_…sql`, after the standard migration header (copy the header shape from `0019_location_coupled_downstream_cell.sql`), add. Use a **fixed anchor constant**, not `GETDATE()` (Risk 2 — deterministic reset):

```sql
-- ============ OI-35 B2: monthly partitioning infrastructure ============
-- Anchor is fixed (NOT GETDATE) so dev reset is deterministic. Window: anchor-2mo .. anchor+13mo.
-- Sliding-window mechanism is TRUNCATE WITH (PARTITIONS) — destructive age-out, no aligned-index
-- requirement, singleton Id PK preserved. See design spec 2026-06-09 §3.
DECLARE @Anchor DATE = '2026-06-01';   -- cutover-month anchor; boundaries are month-firsts UTC

-- Build the boundary value list: 16 monthly boundaries (anchor-2 .. anchor+13)
DECLARE @bv NVARCHAR(MAX) = N'';
DECLARE @i INT = -2;
WHILE @i <= 13
BEGIN
    SET @bv = @bv + CASE WHEN @bv = N'' THEN N'' ELSE N', ' END
            + N'''' + CONVERT(NVARCHAR(10), DATEADD(MONTH, @i, @Anchor), 23) + N'''';
    SET @i += 1;
END

DECLARE @sql NVARCHAR(MAX) =
    N'CREATE PARTITION FUNCTION pf_MonthlyUtc (DATETIME2(3)) AS RANGE RIGHT FOR VALUES (' + @bv + N');';
EXEC sys.sp_executesql @sql;

CREATE PARTITION SCHEME ps_MonthlyUtc AS PARTITION pf_MonthlyUtc ALL TO ([PRIMARY]);
```

- [ ] **Step 3: Write the maintenance proc**

`R__Audit_Partition_MaintainWindow.sql`. Drives SPLIT (ensure next month exists) + TRUNCATE-oldest-past-retention + MERGE. Parameterized on `@AsOfUtc` for deterministic tests. Per-table retention class drives whether the oldest partition is purged (general 7-yr / Honda 20-yr — in dev, tests use a short synthetic `@RetentionMonths` override).

```sql
CREATE OR ALTER PROCEDURE Audit.Partition_MaintainWindow
    @AsOfUtc        DATETIME2(3),
    @AppUserId      BIGINT = NULL,
    @TerminalLocationId BIGINT = NULL,
    @RetentionMonths INT = NULL   -- NULL = use per-table class; tests pass a small number
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @Status BIT = 1, @Message NVARCHAR(500) = N'OK';
    BEGIN TRY
        -- 1. Ensure boundary for the month AFTER @AsOfUtc exists (SPLIT).
        DECLARE @nextBoundary DATETIME2(3) =
            DATEFROMPARTS(YEAR(@AsOfUtc), MONTH(@AsOfUtc), 1);
        SET @nextBoundary = DATEADD(MONTH, 1, @nextBoundary);
        IF NOT EXISTS (
            SELECT 1 FROM sys.partition_range_values prv
            JOIN sys.partition_functions pf ON pf.function_id = prv.function_id
            WHERE pf.name = N'pf_MonthlyUtc' AND CAST(prv.value AS DATETIME2(3)) = @nextBoundary)
        BEGIN
            ALTER PARTITION SCHEME ps_MonthlyUtc NEXT USED [PRIMARY];
            ALTER PARTITION FUNCTION pf_MonthlyUtc() SPLIT RANGE (@nextBoundary);
        END
        -- 2. (Age-out per table is exercised by tests via TRUNCATE WITH (PARTITIONS) + MERGE;
        --    implement the per-table purge loop here against the partitioned-table catalog.)
        --    Keep the body minimal + table-driven; full retention-class wiring is a Phase 1 deliverable.
        SET @Message = N'Partition window maintained as of ' + CONVERT(NVARCHAR(23), @AsOfUtc, 121);
    END TRY
    BEGIN CATCH
        SET @Status = 0; SET @Message = ERROR_MESSAGE();
        BEGIN TRY EXEC Audit.Audit_LogFailure
            @AppUserId=@AppUserId, @TerminalLocationId=@TerminalLocationId,
            @LogEventTypeCode=N'PartitionMaintenanceFailed', @Description=@Message; END TRY BEGIN CATCH END CATCH;
        RAISERROR(@Message, 16, 1);
    END CATCH
    SELECT @Status AS Status, @Message AS Message;
END
```

> Implementer note: flesh out the per-table purge loop (step 2 comment) to iterate the tables on `ps_MonthlyUtc`, compute each one's oldest in-scope partition vs `@RetentionMonths`/class, `TRUNCATE TABLE … WITH (PARTITIONS(<n>))`, then `MERGE RANGE`. Log each op to `OperationLog`.

- [ ] **Step 4: Write the failing test `090_Partition_MaintainWindow.sql`**

Use the `test.Assert_*` framework (mirror an existing test file's harness boilerplate, e.g. `sql/tests/0009_Parts_Process/040_*`). Assertions:
```
-- After CALL with @AsOfUtc in month M: a boundary for M+1 exists in sys.partition_range_values.
-- Calling twice for the same month is idempotent (no duplicate boundary, no error).
-- A partitioned test table loaded with rows in an out-of-window month, then maintained with a small
--   @RetentionMonths, has that partition emptied (COUNT = 0) while in-window rows survive.
```

- [ ] **Step 5: Run test, verify FAIL** — Run: `pwsh sql/tests/Run-Tests.ps1 -Suite 0020_PlantFloor_Foundation` → Expected: 090 fails (objects not yet applied).

- [ ] **Step 6: Apply migration to dev + re-run** — `pwsh sql/scripts/Reset-DevDatabase.ps1` then the suite. Expected: 090 PASS.

- [ ] **Step 7: Commit**
```bash
git add sql/migrations/versioned/0020_arc2_phase1_shop_floor_foundation.sql \
        sql/migrations/repeatable/R__Audit_Partition_MaintainWindow.sql \
        sql/tests/0020_PlantFloor_Foundation/090_Partition_MaintainWindow.sql
git commit -m "feat(plant-floor-sql): OI-35 monthly partitioning infra + maintenance proc (Phase 1 Task A)"
```

---

## Task B: Lot core tables + procs (depends on A; needs E's view — stub if E not landed)

**Files:**
- Modify: `0020_…sql` (add Lot-family CREATEs)
- Create: `R__Lots_IdentifierSequence_Next.sql`, `R__Lots_Lot_Create.sql`, `R__Lots_Lot_Get.sql`, `R__Lots_Lot_List.sql`, `R__Lots_Lot_UpdateStatus.sql`, `R__Lots_Lot_MoveTo.sql`, `R__Lots_Lot_AssertNotBlocked.sql`
- Test: `035_IdentifierSequence.sql`, `040_Lot_Create.sql`, `045_LotGenealogyClosure_self.sql`, `050_Lot_Get_List.sql`, `060_Lot_UpdateStatus.sql`, `070_Lot_MoveTo.sql`, `080_Lot_AssertNotBlocked.sql`

**Read first:** Data Model §3 (Lot, LotStatusHistory, LotMovement, IdentifierSequence, LotGenealogyClosure); plan §"Lot core skeleton" + §"API Layer" Lot rows; design spec §3.2 (index/PK), §4.

### B-CREATE: tables (add to migration)

- [ ] **Step 1: Add the Lot-family CREATEs**, exactly per Data Model v1.9q with these explicit deltas:
  - `Lots.Lot` — full v1.9q column contract **including** `ToolId BIGINT NULL FK → Tools.Tool(Id)`, `ToolCavityId BIGINT NULL FK → Tools.ToolCavity(Id)`, `CrtActive BIT NOT NULL DEFAULT 0`, `TotalInProcess INT NOT NULL DEFAULT 0`, `InventoryAvailable INT NOT NULL DEFAULT 0`. NONCLUSTERED PK on `Id`. (Lot itself is not partitioned — it is a header, not an event log.) B8 filtered index: `CREATE INDEX IX_Lot_Active ON Lots.Lot(CurrentLocationId) WHERE LotStatusId IN (active codes)` — resolve active code ids via a subquery comment, or a filtered index on `WHERE DeprecatedAt IS NULL` per the table's actual columns.
  - `Lots.LotStatusHistory` — v1.9q columns (`Id, LotId, OldStatusId, NewStatusId, Reason, ChangedByUserId, TerminalLocationId, ChangedAt`). **Born partitioned:** clustered `(LotId, ChangedAt)` ON `ps_MonthlyUtc(ChangedAt)`; NONCLUSTERED PK on `Id`.
  - `Lots.LotMovement` — v1.9q columns (`…, FromLocationId, ToLocationId, MovedByUserId, TerminalLocationId, MovedAt`). **Born partitioned:** clustered `(LotId, MovedAt)` ON `ps_MonthlyUtc(MovedAt)`; NONCLUSTERED PK on `Id`.
  - `Lots.IdentifierSequence` — v1.9q §3 (`Code`, `Prefix`, `LastValue`, `Padding`, `EndingValue`, …). Seed two rows in the seeds section (see B-SEED).
  - `Lots.LotGenealogyClosure` — `AncestorLotId BIGINT NOT NULL FK → Lot.Id`, `DescendantLotId BIGINT NOT NULL FK → Lot.Id`, `Depth INT NOT NULL`, PK `(AncestorLotId, DescendantLotId)`; plus `IX_Closure_Descendant (DescendantLotId, AncestorLotId)`. NOT partitioned (closure is keyed by lot pair).
  - `Lots.v_LotDerivedQuantities` — view aggregating `ConsumptionEvent` / `ProductionEvent` to derive in-process/available per Lot (B5 diagnostic fallback; depends on E's event tables — if E not yet applied, create the view in a later migration step ordered after E's CREATEs).

- [ ] **Step 2: Add the IdentifierSequence seeds** (B-SEED, see below) and apply migration. Verify CREATEs succeed: `Reset-DevDatabase.ps1`.

### B-1: `IdentifierSequence_Next` (novel — row-locked, gap-free, B6)

- [ ] **Step 1: Write failing test `035_IdentifierSequence.sql`** — assert: returns `MESL0000001`-shaped string formatted from seed; consecutive calls strictly increase; unknown `@Code` raises; value at `EndingValue` raises rollover. (Concurrency assertion: two sequential calls never return the same value.)

- [ ] **Step 2: Run, verify FAIL.**

- [ ] **Step 3: Implement the proc** (row-lock pattern; mints inside caller's tx):
```sql
CREATE OR ALTER PROCEDURE Lots.IdentifierSequence_Next
    @Code NVARCHAR(30)
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @Prefix NVARCHAR(10), @Last BIGINT, @Pad INT, @End BIGINT;
    UPDATE s WITH (ROWLOCK, UPDLOCK, HOLDLOCK)
        SET @Last = s.LastValue + 1, s.LastValue = s.LastValue + 1,
            @Prefix = s.Prefix, @Pad = s.Padding, @End = s.EndingValue
        FROM Lots.IdentifierSequence s
        WHERE s.Code = @Code;
    IF @Last IS NULL
    BEGIN RAISERROR('Unknown identifier sequence code: %s', 16, 1, @Code); RETURN; END
    IF @Last > @End
    BEGIN RAISERROR('Identifier sequence %s exhausted at %I64d', 16, 1, @Code, @End); RETURN; END
    SELECT @Prefix + RIGHT(REPLICATE('0', @Pad) + CAST(@Last AS NVARCHAR(20)), @Pad) AS Value;
END
```
> Confirm exact column names (`Prefix`/`Padding`/`EndingValue`) against Data Model §3 before finalizing.

- [ ] **Step 4: Run, verify PASS. Step 5: Commit** (`feat(lots-sql): IdentifierSequence_Next row-locked minting (B6)`).

### B-2: `Lot_AssertNotBlocked` (B2 shared guard) — `080`

- [ ] **Step 1: Failing test `080`** — Good → `IsBlocked=0`; Hold/Scrap/Closed → `IsBlocked=1` + message naming the status; non-existent lot → `IsBlocked=1` + 'LOT not found'.
- [ ] **Step 2: FAIL. Step 3: Implement** — read `Lot.LotStatusId → LotStatusCode.BlocksProduction`; return single row `IsBlocked BIT, Message NVARCHAR(500)`; no audit. **Step 4: PASS. Step 5: Commit.**

### B-3: `Lot_Create` (novel — full validation flow) — `040`, `045`

- [ ] **Step 1: Failing test `040`** (assertions, each its own `test.Assert_*`):
```
valid manufacture → Lot + LotStatusHistory row, ToolId/ToolCavityId set, MintedLotName ~ 'MESL%'
die-cast-origin (Manufactured + active ToolAssignment on cell) with NULL @ToolId → reject
@ToolId not mounted on @CurrentLocationId → reject
@ToolCavityId not belonging to @ToolId → reject
cavity StatusCode <> 'Active' → reject
non-die-cast origin with NULL Tool/Cavity → accept
Item ineligible at location (v_EffectiveItemLocation Direct ∪ BomDerived) → reject
piece count > Parts.Item.MaxLotSize → reject
missing @AppUserId → reject
```
- [ ] **Step 2: Failing test `045`** — `Lot_Create` inserts `LotGenealogyClosure (Ancestor=New, Descendant=New, Depth=0)`; rolled-back create leaves no closure row.
- [ ] **Step 3: Run, verify FAIL.**
- [ ] **Step 4: Implement `Lot_Create`** per plan §"Lot core skeleton" steps 1–12: validate params/FKs → validate business rules (eligibility via `Parts.v_EffectiveItemLocation`; `MaxLotSize`; die-cast Tool/Cavity per FDS-05-034) → `BEGIN TRAN` → `IdentifierSequence_Next @Code='Lot'` (inside tx) → insert `Lot` (status 'Good', Tool/Cavity, materialized cols `0`/`@PieceCount`) → insert `LotStatusHistory` (Old=NULL,New='Good') → insert closure self-row → `Audit_LogOperation` (`LogEntityTypeCode='Lot'`, `LogEventTypeCode='LotCreated'`) → `COMMIT` → `SELECT @Status, @Message, @NewId, @MintedLotName`. On any validation fail: no tran, `Audit_LogFailure` with attempted params, early return. Follow `_TEMPLATE_stored_procedure.sql` error hierarchy.
- [ ] **Step 5: Run, verify PASS (040 + 045). Step 6: Commit** (`feat(lots-sql): Lot_Create + genealogy closure self-row (Phase 1 Task B)`).

### B-4: `Lot_Get` / `Lot_List` / `Lot_UpdateStatus` / `Lot_MoveTo` — `050`, `060`, `070`

- [ ] **Step 1–N (per proc, TDD):** failing test → FAIL → implement per plan §"API Layer" Lot rows → PASS → commit. Key points: `Lot_Get` returns materialized `TotalInProcess`/`InventoryAvailable` directly (B5); `Lot_UpdateStatus` optimistic-lock via `@RowVersion`, rejects no-op, Phase 1 accepts only Good→Closed, inserts `LotStatusHistory`; `Lot_MoveTo` calls `Lot_AssertNotBlocked` first, updates `CurrentLocationId`, inserts `LotMovement`. Test `070` includes the blocked-lot rejection path.

---

## Task C: Terminal resolution + Terminal seeds

**Files:** Modify `0020_…sql` (Terminal attr-def seeds + fallback Terminal + IP index); Create `R__Location_Terminal_GetByIpAddress.sql`, `R__Location_Terminal_List.sql`; Test `010_Terminal_GetByIpAddress.sql`.

**Read first:** plan §"Session establishment" + §"API Layer" Terminal rows; design spec §4 seeds.

- [ ] **Step 1: Add seeds to migration** — LocationAttributeDefinition on `Terminal` type: `DefaultScreen` (NVARCHAR), `RequiresCompletionConfirm` (BIT). Fallback `Terminal` Location row (global default). `IpAddress` attribute index on `Location.LocationAttribute` if absent. (NO `TerminalMode` seed — derived; NO `IdleTimeoutSeconds`/`RequiresReauthForSensitive`.) ASCII-only.
- [ ] **Step 2: Failing test `010`** — known IP → correct Terminal + Zone + DefaultScreen + derived `TerminalMode` (`Dedicated` for Cell parent, `Shared` for WorkCenter/Area parent); unknown IP → fallback Terminal; Terminal w/o DefaultScreen → NULL DefaultScreen; deprecated Terminal → not returned.
- [ ] **Step 3: FAIL.**
- [ ] **Step 4: Implement `Terminal_GetByIpAddress`** — read `LocationAttribute WHERE AttributeName='IpAddress' AND Value=@IpAddress`; join parent Terminal Location + its parent Area; compute `TerminalMode` from parent tier; return fallback if no match (never error). `Terminal_List` = admin rowset. Both NO OUTPUT params, single result set.
- [ ] **Step 5: PASS. Step 6: Commit** (`feat(location-sql): Terminal_GetByIpAddress + seeds (Phase 1 Task C)`).

---

## Task D: AppUser presence + AD elevation + elevation seeds

**Files:** Modify `0020_…sql` (`Audit.LogEventType` rows `ElevationGranted`/`ElevationDenied`); Create `R__Location_AppUser_GetByInitials.sql`, `R__Location_AppUser_AuthenticateAd.sql`, `R__Location_AppUser_GetRoles.sql`; Test `020_AppUser_GetByInitials.sql`, `025_AppUser_AuthenticateAd.sql`.

**Read first:** plan §"Operator presence" + §"Elevated actions" + §"API Layer" AppUser rows.

- [ ] **Step 1: Failing test `020`** — known initials → AppUser row (`Id, Initials, DisplayName, UserClass, IgnitionRole`); unknown → empty set; deprecated AppUser → empty; operator + interactive class both covered.
- [ ] **Step 2: FAIL. Step 3: Implement `AppUser_GetByInitials`** (no audit on lookup; empty set = unknown). **Step 4: PASS.**
- [ ] **Step 5: Failing test `025`** — valid AD account + permitted role + valid `@ActionCode` → `Status=1` + AppUserId + `OperationLog 'ElevationGranted'`; wrong role → `Status=0` + `FailureLog 'ElevationDenied'`; deprecated AD user → reject; unknown `@ActionCode` → reject; missing `@AdAccount` → reject.
- [ ] **Step 6: FAIL. Step 7: Implement `AppUser_AuthenticateAd`** (post-AD-validation role check + audit; returns `Status, Message, AppUserId`) and `AppUser_GetRoles`. **Step 8: PASS. Step 9: Commit** (`feat(location-sql): AppUser presence + AD elevation (Phase 1 Task D)`).

> Grep gate (carry to Task G): no `ClockNumber`/`PinHash` anywhere.

---

## Task E: WorkOrder family + eligibility view

**Files:** Modify `0020_…sql` (WorkOrder family CREATEs + `Parts.v_EffectiveItemLocation`). No procs in Phase 1 (events written Phase 3+). No dedicated test file beyond migration-apply verification + the eligibility-path coverage exercised inside `040_Lot_Create`.

**Read first:** Data Model §4 (Workorder.*); plan §"Data Model Changes" WorkOrder/ProductionEvent contracts; design spec §4; Phase 0 T004 (A2 BIT flags).

- [ ] **Step 1: Add CREATEs** per Data Model v1.9q with deltas:
  - `Workorder.WorkOrder` — v1.9o/q contract + **A2 BIT flags** (`IsCameraProcessingEnabled`, `IsScaleProcessingEnabled`, `GroupTargetWeight` + tolerance + UOM, `RecipeNumber`, `TrayQuantity`, `ReturnableDunnageCode`, `Customer`). `WorkOrderTypeId` defaults to seeded `Production`; `ToolId BIGINT NULL` (FUTURE hook).
  - `Workorder.WorkOrderOperation` — §4, `AppUserId BIGINT NULL`.
  - `Workorder.ProductionEvent` — v1.9q checkpoint shape (`ShotCount`/`ScrapCount` cumulative NULL per A4; `AppUserId NOT NULL`; `TerminalLocationId`; no `LocationId`/`ItemId`/`DieIdentifier`/`CavityNumber`/`GoodCount`/`StartedAt`/`EndedAt`). **Born partitioned:** clustered `(LotId, EventAt)` ON `ps_MonthlyUtc(EventAt)`; NONCLUSTERED PK `Id`.
  - `Workorder.ProductionEventValue` — §4 child; FK references `ProductionEvent.Id` (singleton). NOT partitioned (or partition-align with parent only if needed — keep simple: not partitioned in Phase 1).
  - `Workorder.ConsumptionEvent`, `Workorder.RejectEvent` — §4, `AppUserId NOT NULL`, born partitioned on `EventAt` (clustered `(LotId, EventAt)`).
  - `Parts.v_EffectiveItemLocation` — Direct ∪ BOM-derived eligibility (FDS-02-012). This view is READ by `Lot_Create`; create it **before** Task B's `Lot_Create` tests run (migration ordering: place this CREATE ahead of the Lot procs' first use, or land Task E's migration section before Task B executes).
- [ ] **Step 2: Apply migration** — `Reset-DevDatabase.ps1`; verify all CREATEs succeed, no partition-scheme errors.
- [ ] **Step 3: Smoke the view** — insert a known eligible Item/Location pair, `SELECT * FROM Parts.v_EffectiveItemLocation WHERE ItemId=… AND LocationId=…` returns the row via both Direct and BomDerived legs.
- [ ] **Step 4: Commit** (`feat(workorder-sql): WorkOrder family + v_EffectiveItemLocation (Phase 1 Task E)`).

---

## Task F: Audit split (B7) + Shift runtime

**Files:** Modify `0020_…sql` (`Lots.LotEventLog` CREATE born-partitioned + repartition existing `Audit.OperationLog`/`InterfaceLog`/`FailureLog` + remaining `LogEventType` seeds); Modify `R__Audit_Audit_LogOperation.sql` (routing); Create `R__Oee_Shift_Start.sql`, `_End`, `_GetActive`, `_GetOpen`; Test `030_Shift_lifecycle.sql`.

**Read first:** Phase 0 B7 + B1 retention table; plan §"Shift runtime" + §"API Layer" Shift + Audit rows; design spec §3.4 (repartition note).

- [ ] **Step 1: Add `Lots.LotEventLog` CREATE** — same row shape as `Audit.OperationLog` + `LotId BIGINT NOT NULL FK → Lots.Lot.Id`. Born partitioned on its timestamp column (confirm name vs DM — `CreatedAt`/`LoggedAt`) ON `ps_MonthlyUtc`. 20-yr class.
- [ ] **Step 2: Repartition existing audit tables** — for `Audit.OperationLog`, `InterfaceLog`, `FailureLog`: confirm each existing clustered-index shape (from `0001`); rebuild clustered index ONTO `ps_MonthlyUtc(<timestamp col>)`. Trivial on empty tables. Verify no Arc-1 proc/test depends on the prior clustered key (grep).
- [ ] **Step 3: Modify `Audit_LogOperation`** — add B7 routing: LOT-event entity types (`Lot`, container-close, ShippingLabel mint — Phase 1: just `Lot`) route the insert to `Lots.LotEventLog` (with `LotId`); everything else → `OperationLog`. Still emits **no result set**. Resolve code strings → FK ids internally.
- [ ] **Step 4: Apply migration; verify repartition + LotEventLog.** Re-run existing audit-infra tests (`01_audit_infrastructure`, `02_audit_readers`) — must stay green (low blast radius, but confirm).
- [ ] **Step 5: Failing test `030`** — `Shift_Start` creates row; rejects when open Shift exists (B3 invariant); `Shift_End` closes; rejects when no open Shift; `Shift_GetActive` returns schedule by day-of-week bitmask; **no auto-carryover** of open events on `Shift_End`.
- [ ] **Step 6: FAIL. Step 7: Implement Shift procs** per plan §"API Layer" Shift rows. **Step 8: PASS. Step 9: Commit** (`feat(audit+oee-sql): OperationLog→LotEventLog split + Shift runtime (Phase 1 Task F)`).

---

## Task G: Integration, full-suite green, sign-off gates

**Files:** none new — verification + holistic review.

- [ ] **Step 1: Clean reset** — `pwsh sql/scripts/Reset-DevDatabase.ps1`. Expected: discovers + applies `0020`, runs all suites, exits 0.
- [ ] **Step 2: Full suite green** — `pwsh sql/tests/Run-Tests.ps1`. Expected: prior suites still pass; `0020_PlantFloor_Foundation` passes; total at the new high-water mark with 80–105 new tests in 0020.
- [ ] **Step 3: Sign-off gates:**
```bash
grep -ri 'ClockNumber\|PinHash' sql/        # expect zero hits in active code
```
  - `Audit_LogOperation` code-string→FK resolution verified for `ShiftStarted`/`ShiftEnded`/`LotCreated`/`LotStatusChanged`/`LotMoved`/`ElevationGranted`; `Audit_LogFailure` for `ElevationDenied`. Any missing `Audit.LogEventType` rows seeded.
  - Byte-scan the migration's seed strings for non-ASCII (mojibake guard).
  - `git diff --stat` on any touched view.json — N/A this push (SQL only).
- [ ] **Step 4: Downstream-contract smoke** — confirm a caller can invoke `Lot_Create` (Tool/Cavity), `IdentifierSequence_Next`, `AppUser_GetByInitials`, `AppUser_AuthenticateAd`, `Lot_MoveTo`, `Lot_UpdateStatus`, `Lot_AssertNotBlocked` against the delivered signatures (the Phase 1 "complete when" integration checklist, SQL portions).
- [ ] **Step 5: Holistic cross-cutting review** (subagent-driven final review) — convention compliance across all new procs (no OUTPUT params, status-row shape, nested CATCH, audit-readable Descriptions, B1/B2 params), partition correctness, FK integrity.
- [ ] **Step 6: Final commit / branch state** — all on `jacques/working`. Do NOT merge to `main` (deliberate, per branch convention).

---

## Out of scope (follow-on push — do NOT build here)

Gateway scripts (`Terminal_ResolveFromSession`, `ShiftBoundaryTicker`, `PartitionMaintenance`) + 7 Perspective views. Also non-blocking: the Phase 0 T009 staged sign-off Blocks 1–5 paste into canonical docs (DM/FDS/OIR) — documentation hygiene, decisions already captured in the decision log.

---

## Self-Review notes (author)

- **Spec coverage:** design §3 → Task A; §4 tables → B-CREATE/E/F; §5 procs → B/C/D/F; §6 tests → per-task test files + G; §7 decomposition → Tasks A–G; §8 risks → Task A steps 1–2 (edition + anchor), E ordering note, F repartition step. ✓
- **Ordering dependency:** `Lot_Create` (B) reads `v_EffectiveItemLocation` (E) and `IdentifierSequence`/`Lot_AssertNotBlocked` (B). Migration section order: partitioning (A) → WorkOrder + view (E) → Lot family (B) → audit split + LotEventLog + repartition (F) → Terminal/AppUser seeds (C/D). Procs are repeatable (order-independent at apply). Dispatch may run E before B's proc tests; the migration file is assembled across tasks but is ONE file — coordinate edits to avoid clobber (each task edits its own clearly-delimited section).
- **Type consistency:** `Status`/`Message`/`NewId`/`MintedLotName` result-row names consistent; `IsBlocked` from `Lot_AssertNotBlocked`; partition objects `pf_MonthlyUtc`/`ps_MonthlyUtc` consistent A→F.
- **Known confirm-against-DM items (not placeholders — concrete refs):** exact `IdentifierSequence` column names; `LotEventLog` timestamp column name; per-table B8 filtered-index predicates against actual columns.
