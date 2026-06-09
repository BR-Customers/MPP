-- ============================================================
-- Migration:   0020_arc2_phase1_shop_floor_foundation.sql
-- Author:      Blue Ridge Automation
-- Date:        2026-06-09
-- Description: Arc 2 Phase 1 — Shop Floor Foundation. The cross-cutting
--              SQL foundation every downstream plant-floor phase depends
--              on. Single versioned migration that creates:
--
--                * OI-35 B2 monthly RANGE-RIGHT partitioning infrastructure
--                  (pf_MonthlyUtc / ps_MonthlyUtc) + the retention catalog
--                  (Audit.PartitionRetention) that drives the sliding-window
--                  maintenance proc (Audit.Partition_MaintainWindow, repeatable).
--                * WorkOrder family (WorkOrder, WorkOrderOperation,
--                  ProductionEvent, ProductionEventValue, ConsumptionEvent,
--                  RejectEvent) + Parts.v_EffectiveItemLocation.   [Task E]
--                * Lot family (Lot, LotStatusHistory, LotMovement,
--                  IdentifierSequence, LotGenealogyClosure,
--                  v_LotDerivedQuantities).                          [Task B]
--                * B7 audit split: Lots.LotEventLog (born partitioned, 20-yr)
--                  + repartition of Audit.OperationLog/InterfaceLog/FailureLog
--                  onto ps_MonthlyUtc.                               [Task F]
--                * Terminal resolution seeds.                        [Task C]
--                * AppUser presence / AD-elevation seeds.            [Task D]
--
--              See design spec docs/superpowers/specs/2026-06-09-arc2-phase1-
--              sql-foundation-design.md and plan docs/superpowers/plans/
--              2026-06-09-arc2-phase1-sql-foundation.md.
--
-- ------------------------------------------------------------
-- STRUCTURE NOTE (multi-task assembly):
--   This file is assembled by several subagent tasks (A/E/B/F/C/D). Each
--   task owns ONE clearly-delimited "== SECTION x ==" block below. Do NOT
--   edit another task's section. Sections are GO-separated batches (own
--   variable scope) and each object is created under an idempotency guard
--   (IF NOT EXISTS ... / OBJECT_ID ...). There is intentionally NO single
--   wrapping transaction: the partitioning section uses dynamic SQL +
--   WHILE loops that do not compose with the 0001/0010 single-batch
--   transaction pattern, and Reset-DevDatabase always drops/recreates the
--   DB. The dependency order of the sections (A -> E -> B -> F -> C -> D)
--   is load-bearing: Lot_Create (B) reads v_EffectiveItemLocation (E),
--   v_LotDerivedQuantities (B) reads the event tables (E), and LotEventLog
--   (F) FKs to Lots.Lot (B).
--
-- ------------------------------------------------------------
-- *** PARTITIONED-TABLE PK CORRECTION (verified 2026-06-09, Task A) ***
--   Design spec section 3.2 is WRONG: partition-level
--   TRUNCATE ... WITH (PARTITIONS(n)) requires EVERY index on the table
--   (including the PK) to be partition-ALIGNED. A bare-(Id) NONCLUSTERED PK
--   is non-aligned and makes TRUNCATE fail ("Index ... is not partitioned").
--   Empirically confirmed. Therefore every BORN-PARTITIONED table that must
--   age out via TRUNCATE uses:
--       CONSTRAINT PK_x PRIMARY KEY NONCLUSTERED (Id, <partitionCol>)
--           ON ps_MonthlyUtc(<partitionCol>)        -- aligned, Id still unique via IDENTITY
--       + CREATE CLUSTERED INDEX ... (<hot path incl partitionCol>)
--           ON ps_MonthlyUtc(<partitionCol>)        -- aligned hot path
--   EXCEPTION: a table referenced by an incoming bare-(Id) FK CANNOT have an
--   aligned unique key on (Id) alone, so it keeps a NON-aligned NONCLUSTERED
--   PK (Id) and is simply NOT registered in Audit.PartitionRetention (its
--   age-out is deferred). In Phase 1 this is ProductionEvent (child:
--   ProductionEventValue). ConsumptionEvent / RejectEvent / LotMovement /
--   LotStatusHistory / LotEventLog have no incoming Id-FK -> aligned composite PK.
--
-- ------------------------------------------------------------
-- AUDIT-LOOKUP Id ALLOCATION (manual Ids; reserve before adding, no clash):
--   Audit.LogEventType  (max existing = 21 'Deleted'):
--       22  PartitionMaintained          [Task A]  (this section)
--       23  PartitionMaintenanceFailed   [Task A]  (this section)
--       24  ShiftStarted                 [Task F]
--       25  ShiftEnded                   [Task F]
--       26  LotStatusChanged             [Task F]  (LotCreated=5, LotMoved=6 exist)
--       27  ElevationGranted             [Task D]
--       28  ElevationDenied              [Task D]
--   Audit.LogEntityType (max existing = 39 'ScrapSource'):
--       40  Partition                    [Task A]  (this section)
--       41  Shift                        [Task F]
--       (Terminal / AppUser already exist as Location-tier entities; AppUser=16)
-- ============================================================


-- ============================================================
-- == SECTION A — Partitioning infrastructure (Task A) ========
-- ============================================================
-- OI-35 B2: monthly RANGE-RIGHT partitioning. Anchor is a FIXED constant
-- (NOT GETDATE()) so a dev reset is byte-for-byte deterministic and the
-- 090 partition test is stable (design Risk 2). Seed window spans
-- anchor-2 months .. anchor+13 months => 16 monthly boundaries at
-- month-firsts (UTC). RANGE RIGHT => boundary b is the inclusive lower
-- bound of the partition to its right; values < b fall to the left.
--
-- Sliding-window mechanism is destructive age-out via
-- TRUNCATE ... WITH (PARTITIONS(n)) (SQL 2016+): instant, minimally
-- logged, and (unlike SWITCH OUT) needs NO aligned unique index — so the
-- project's singleton NONCLUSTERED BIGINT IDENTITY Id PK convention is
-- preserved on every partitioned table. See design spec section 3.

IF NOT EXISTS (SELECT 1 FROM sys.partition_functions WHERE name = N'pf_MonthlyUtc')
BEGIN
    DECLARE @Anchor DATE = '2026-06-01';   -- cutover-month anchor; boundaries are month-firsts (UTC)

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
END
GO

IF NOT EXISTS (SELECT 1 FROM sys.partition_schemes WHERE name = N'ps_MonthlyUtc')
BEGIN
    -- All partitions map to PRIMARY: keeps dev reset trivial and stays
    -- design-compatible with a later remap of cold partitions to cheaper
    -- storage / columnstore (a scheme change, not a table rebuild).
    CREATE PARTITION SCHEME ps_MonthlyUtc AS PARTITION pf_MonthlyUtc ALL TO ([PRIMARY]);
END
GO

-- ---- Retention catalog (drives Partition_MaintainWindow purge loop) ----
-- The maintenance proc purges ONLY tables registered here. This is
-- deliberate: partition-level TRUNCATE is rejected outright on a table
-- referenced by a FOREIGN KEY (e.g. ProductionEventValue -> ProductionEvent),
-- so a blind "every table on the scheme" purge would fail. Registering
-- tables explicitly also gives each one its retention class (general
-- 7-yr = 84 months / Honda 20-yr = 240 months). Production registration
-- of the real born-partitioned tables (and FK-child-purge ordering for
-- ProductionEvent) is a later deliverable — no data ages out for 7+ years,
-- so Phase 1 ships the mechanism + catalog unpopulated by real tables.
IF OBJECT_ID(N'Audit.PartitionRetention', N'U') IS NULL
BEGIN
    CREATE TABLE Audit.PartitionRetention (
        Id              BIGINT          NOT NULL IDENTITY(1,1) PRIMARY KEY,
        SchemaName      NVARCHAR(128)   NOT NULL,
        TableName       NVARCHAR(128)   NOT NULL,
        RetentionMonths INT             NOT NULL,
        Description     NVARCHAR(500)   NULL,
        CreatedAt       DATETIME2(3)    NOT NULL DEFAULT SYSUTCDATETIME(),
        CONSTRAINT UQ_PartitionRetention_Table UNIQUE (SchemaName, TableName),
        CONSTRAINT CK_PartitionRetention_Months CHECK (RetentionMonths > 0)
    );
END
GO

-- ---- Partition-maintenance audit lookups (Ids 22/23 event, 40 entity) ----
IF NOT EXISTS (SELECT 1 FROM Audit.LogEventType WHERE Id = 22)
    INSERT INTO Audit.LogEventType (Id, Code, Name, Description) VALUES
        (22, N'PartitionMaintained',        N'Partition Maintained',         N'Partition sliding-window maintenance completed (split/truncate/merge).');
GO
IF NOT EXISTS (SELECT 1 FROM Audit.LogEventType WHERE Id = 23)
    INSERT INTO Audit.LogEventType (Id, Code, Name, Description) VALUES
        (23, N'PartitionMaintenanceFailed', N'Partition Maintenance Failed',  N'Partition sliding-window maintenance raised an error.');
GO
IF NOT EXISTS (SELECT 1 FROM Audit.LogEntityType WHERE Id = 40)
    INSERT INTO Audit.LogEntityType (Id, Code, Name, Description) VALUES
        (40, N'Partition', N'Partition', N'Partitioned-table sliding-window maintenance (Audit.Partition_MaintainWindow).');
GO


-- ============================================================
-- == SECTION E — WorkOrder family + eligibility view (Task E) =
-- ============================================================
-- TODO[Task E]: CREATE Workorder.WorkOrder (+ A2 BIT flags), WorkOrderOperation,
--   ProductionEvent, ProductionEventValue, ConsumptionEvent, RejectEvent, and
--   Parts.v_EffectiveItemLocation (Direct UNION BOM-derived). Per Data Model
--   v1.9q section 4. Place this section BEFORE Section B (Lot_Create reads
--   v_EffectiveItemLocation; v_LotDerivedQuantities reads the events).
--   PK rule (see PARTITIONED-TABLE PK CORRECTION at top of file):
--     * ProductionEvent — clustered (LotId, EventAt) ON ps_MonthlyUtc(EventAt).
--       Referenced by ProductionEventValue on bare Id, so it KEEPS a NON-aligned
--       NONCLUSTERED PK (Id) and is NOT registered for TRUNCATE age-out (deferred).
--     * ConsumptionEvent / RejectEvent — no incoming Id-FK -> aligned composite
--       PK NONCLUSTERED (Id, EventAt) ON ps_MonthlyUtc(EventAt) + clustered
--       (LotId, EventAt) ON ps_MonthlyUtc(EventAt).
--     * ProductionEventValue — NOT partitioned.


-- ============================================================
-- == SECTION B — Lot core tables (Task B) ====================
-- ============================================================
-- TODO[Task B]: CREATE Lots.Lot (NONCLUSTERED PK Id — Lot is a header, NOT
--   partitioned; ToolId/ToolCavityId NULL FKs; CrtActive/TotalInProcess/
--   InventoryAvailable; B8 filtered index), Lots.LotStatusHistory +
--   Lots.LotMovement (born partitioned on ps_MonthlyUtc), Lots.IdentifierSequence
--   (+ seeds, B-SEED), Lots.LotGenealogyClosure, Lots.v_LotDerivedQuantities
--   (after Section E events exist). Per Data Model v1.9q section 3.
--   PK rule (see PARTITIONED-TABLE PK CORRECTION at top of file):
--     * Lots.Lot — NOT partitioned -> bare NONCLUSTERED PK (Id) as usual.
--     * LotStatusHistory — aligned composite PK NONCLUSTERED (Id, ChangedAt)
--       ON ps_MonthlyUtc(ChangedAt) + clustered (LotId, ChangedAt) ON the scheme.
--     * LotMovement — aligned composite PK NONCLUSTERED (Id, MovedAt)
--       ON ps_MonthlyUtc(MovedAt) + clustered (LotId, MovedAt) ON the scheme.
--   (No incoming bare-Id FK on either history table, so the composite PK is safe.)


-- ============================================================
-- == SECTION F — Audit split + LotEventLog + repartition (Task F)
-- ============================================================
-- TODO[Task F]: CREATE Lots.LotEventLog (OperationLog row shape + LotId FK
--   -> Lots.Lot, born partitioned ON ps_MonthlyUtc, 20-yr class).
--   Repartition Audit.OperationLog / InterfaceLog / FailureLog clustered
--   index onto ps_MonthlyUtc(<timestamp col>). Seed LogEventType 24/25/26
--   (ShiftStarted/ShiftEnded/LotStatusChanged) + LogEntityType 41 (Shift).
--   PK rule (see PARTITIONED-TABLE PK CORRECTION at top of file):
--     * LotEventLog — aligned composite PK NONCLUSTERED (Id, <LoggedAt/CreatedAt>)
--       ON ps_MonthlyUtc(<ts>); confirm the timestamp col name vs DM. If it
--       should age out via TRUNCATE, register it in Audit.PartitionRetention
--       (240 months). No incoming bare-Id FK -> composite PK is safe.
--     * Repartitioning OperationLog/InterfaceLog/FailureLog: their existing PK
--       is a bare-Id CLUSTERED PK (from 0001). To put the CLUSTERED index on
--       ps_MonthlyUtc you must drop that clustered PK and re-add it either as
--       the aligned composite clustered PK (Id, LoggedAt/AttemptedAt) ON the
--       scheme, OR as a NONCLUSTERED PK + aligned clustered index on the ts.
--       Verify no Arc-1 proc/test depends on the bare-Id clustered key (grep).
--       Note these three are NOT in the PartitionRetention catalog yet, so a
--       non-aligned PK would not break TRUNCATE today — but align them now to
--       keep the family uniform and TRUNCATE-ready.


-- ============================================================
-- == SECTION C — Terminal resolution seeds (Task C) ==========
-- ============================================================
-- TODO[Task C]: Seed LocationAttributeDefinition on the Terminal type
--   (DefaultScreen NVARCHAR, RequiresCompletionConfirm BIT). Insert the
--   fallback Terminal Location row (global default for unregistered IP).
--   Ensure an IpAddress index on Location.LocationAttribute. ASCII-only.


-- ============================================================
-- == SECTION D — AppUser / AD-elevation seeds (Task D) =======
-- ============================================================
-- TODO[Task D]: Seed Audit.LogEventType 27/28 (ElevationGranted /
--   ElevationDenied). (Procs are repeatable files.)


-- ============================================================
-- == Record migration ========================================
-- ============================================================
IF NOT EXISTS (SELECT 1 FROM dbo.SchemaVersion WHERE MigrationId = N'0020_arc2_phase1_shop_floor_foundation')
    INSERT INTO dbo.SchemaVersion (MigrationId, Description)
    VALUES (
        N'0020_arc2_phase1_shop_floor_foundation',
        N'Arc 2 Phase 1 shop-floor foundation: OI-35 monthly partitioning (pf/ps_MonthlyUtc) + PartitionRetention catalog, WorkOrder family + v_EffectiveItemLocation, Lot family + genealogy closure, B7 LotEventLog split + audit repartition, Terminal/AppUser seeds.'
    );
GO
PRINT 'Migration 0020 (Arc 2 Phase 1 shop-floor foundation) applied.';
GO
