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
-- WorkOrder family (DM v1.9q section 4) + Parts.v_EffectiveItemLocation
-- (FDS-02-012, Direct UNION BOM-derived). Placed BEFORE Section B because
-- Lot_Create (Section B) reads v_EffectiveItemLocation and
-- v_LotDerivedQuantities (Section B) reads the event tables created here.
--
-- FORWARD-REFERENCE NOTE (Lots.Lot / Parts.Container / Parts.ContainerTray):
--   The DM sec 4 specifies hard FKs LotId/SourceLotId/ProducedLotId -> Lots.Lot.Id
--   and ProducedContainerId -> Parts.Container, TrayId -> Parts.ContainerTray on
--   the event tables. Lots.Lot is created in Section B, which runs AFTER this
--   section in the SAME migration file (a forward reference that would fail at
--   apply time), and Parts.Container / Parts.ContainerTray do NOT exist yet (a
--   later Arc 2 Container-management phase creates them). Therefore the Lot /
--   Container / ContainerTray FK CONSTRAINTS are INTENTIONALLY OMITTED here; the
--   columns are kept as correctly-typed BIGINT (NOT NULL / NULL per the DM) so
--   the relationship is preserved structurally and the FK can be added by a
--   later migration once those parent tables exist. All FK targets that DO exist
--   today (Parts.Item / OperationTemplate / DataCollectionField / Uom,
--   Location.Location / AppUser, Workorder.WorkOrderType / WorkOrderStatus /
--   OperationStatus / ScrapSource / WorkOrder / WorkOrderOperation /
--   ProductionEvent, Parts.RouteTemplate / RouteStep, Quality.DefectCode) ARE
--   enforced as hard FKs below.
--
-- PK rule (see PARTITIONED-TABLE PK CORRECTION at top of file):
--   * ProductionEvent - clustered (LotId, EventAt) ON ps_MonthlyUtc(EventAt);
--     referenced by ProductionEventValue on bare Id, so it KEEPS a NON-aligned
--     NONCLUSTERED PK (Id) and is NOT registered for TRUNCATE age-out (deferred).
--   * ConsumptionEvent / RejectEvent - no incoming Id-FK -> aligned composite
--     PK NONCLUSTERED (Id, EventAt) ON ps_MonthlyUtc(EventAt) + clustered
--     (LotId, EventAt) ON ps_MonthlyUtc(EventAt).
--   * WorkOrder / WorkOrderOperation / ProductionEventValue - NOT partitioned;
--     normal bare-Id NONCLUSTERED/clustered PK.

-- ---- Workorder.WorkOrder (header; NOT partitioned; + A2 BIT flags) ----
-- Auto-generated internal WO (operators never see it). WorkOrderTypeId defaults
-- to the single seeded Production row (Id=1 after migration 0013). ToolId is a
-- nullable FUTURE hook for Maintenance WOs. A2 BIT/attribute flags (FDS-06-030,
-- T004 confirmed-live set): camera/scale processing toggles, group target weight
-- + tolerance + UOM, recipe number, tray quantity, returnable dunnage, customer.
IF OBJECT_ID(N'Workorder.WorkOrder', N'U') IS NULL
BEGIN
    CREATE TABLE Workorder.WorkOrder (
        Id                        BIGINT         NOT NULL IDENTITY(1,1),
        WoNumber                  NVARCHAR(50)   NOT NULL,
        WorkOrderTypeId           BIGINT         NOT NULL
            CONSTRAINT DF_WorkOrder_WorkOrderTypeId DEFAULT (1)
            REFERENCES Workorder.WorkOrderType(Id),
        ItemId                    BIGINT         NOT NULL REFERENCES Parts.Item(Id),
        RouteTemplateId           BIGINT         NOT NULL REFERENCES Parts.RouteTemplate(Id),
        WorkOrderStatusId         BIGINT         NOT NULL REFERENCES Workorder.WorkOrderStatus(Id),
        ToolId                    BIGINT         NULL     REFERENCES Tools.Tool(Id),
        -- A2 BIT-flag / attribute set (FDS-06-030)
        IsCameraProcessingEnabled BIT            NOT NULL CONSTRAINT DF_WorkOrder_IsCameraProcessingEnabled DEFAULT (0),
        IsScaleProcessingEnabled  BIT            NOT NULL CONSTRAINT DF_WorkOrder_IsScaleProcessingEnabled DEFAULT (0),
        GroupTargetWeight         DECIMAL(12,4)  NULL,
        GroupTargetWeightTolerance DECIMAL(12,4) NULL,
        TargetWeightUomId         BIGINT         NULL     REFERENCES Parts.Uom(Id),
        RecipeNumber              NVARCHAR(50)   NULL,
        TrayQuantity              INT            NULL,
        ReturnableDunnageCode     NVARCHAR(50)   NULL,
        Customer                  NVARCHAR(100)  NULL,
        CreatedAt                 DATETIME2(3)   NOT NULL DEFAULT SYSUTCDATETIME(),
        CompletedAt               DATETIME2(3)   NULL,
        CONSTRAINT PK_WorkOrder PRIMARY KEY NONCLUSTERED (Id),
        CONSTRAINT UQ_WorkOrder_WoNumber UNIQUE (WoNumber)
    );

    CREATE INDEX IX_WorkOrder_ItemId          ON Workorder.WorkOrder (ItemId);
    CREATE INDEX IX_WorkOrder_WorkOrderStatusId ON Workorder.WorkOrder (WorkOrderStatusId);
    CREATE INDEX IX_WorkOrder_ToolId          ON Workorder.WorkOrder (ToolId) WHERE ToolId IS NOT NULL;
END
GO

-- ---- Workorder.WorkOrderOperation (NOT partitioned) ----
-- Individual operation execution - the actual step that happened.
IF OBJECT_ID(N'Workorder.WorkOrderOperation', N'U') IS NULL
BEGIN
    CREATE TABLE Workorder.WorkOrderOperation (
        Id                BIGINT         NOT NULL IDENTITY(1,1),
        WorkOrderId       BIGINT         NOT NULL REFERENCES Workorder.WorkOrder(Id),
        RouteStepId       BIGINT         NOT NULL REFERENCES Parts.RouteStep(Id),
        LocationId        BIGINT         NULL     REFERENCES Location.Location(Id),
        OperationStatusId BIGINT         NOT NULL REFERENCES Workorder.OperationStatus(Id),
        SequenceNumber    INT            NOT NULL,
        StartedAt         DATETIME2(3)   NULL,
        CompletedAt       DATETIME2(3)   NULL,
        AppUserId         BIGINT         NULL     REFERENCES Location.AppUser(Id),
        CONSTRAINT PK_WorkOrderOperation PRIMARY KEY NONCLUSTERED (Id)
    );

    CREATE INDEX IX_WorkOrderOperation_WorkOrderId ON Workorder.WorkOrderOperation (WorkOrderId);
    CREATE INDEX IX_WorkOrderOperation_RouteStepId ON Workorder.WorkOrderOperation (RouteStepId);
END
GO

-- ---- Workorder.ProductionEvent (BORN PARTITIONED on EventAt) ----
-- Checkpoint-shape event: one row per checkpoint carrying CUMULATIVE counters
-- (ShotCount / ScrapCount, both NULL-able per A4); reader derives deltas via
-- LAG() over (LotId, EventAt). LotId FK to Lots.Lot OMITTED (forward ref - see
-- note above). EXCEPTION to the composite-PK rule: ProductionEvent is referenced
-- by ProductionEventValue on its bare Id, so an aligned unique key on (Id) alone
-- is impossible -> it KEEPS a NON-aligned NONCLUSTERED PK (Id) and is NOT
-- registered in Audit.PartitionRetention (TRUNCATE age-out deferred). The hot
-- "previous event for this LOT" path is the partition-aligned clustered index
-- (LotId, EventAt) ON ps_MonthlyUtc(EventAt).
IF OBJECT_ID(N'Workorder.ProductionEvent', N'U') IS NULL
BEGIN
    CREATE TABLE Workorder.ProductionEvent (
        Id                   BIGINT         NOT NULL IDENTITY(1,1),
        LotId                BIGINT         NOT NULL,   -- FK -> Lots.Lot.Id omitted (Section B forward ref)
        OperationTemplateId  BIGINT         NOT NULL REFERENCES Parts.OperationTemplate(Id),
        WorkOrderOperationId BIGINT         NULL     REFERENCES Workorder.WorkOrderOperation(Id),
        EventAt              DATETIME2(3)   NOT NULL DEFAULT SYSUTCDATETIME(),
        ShotCount            INT            NULL,
        ScrapCount           INT            NULL,
        ScrapSourceId        BIGINT         NULL     REFERENCES Workorder.ScrapSource(Id),
        WeightValue          DECIMAL(12,4)  NULL,
        WeightUomId          BIGINT         NULL     REFERENCES Parts.Uom(Id),
        AppUserId            BIGINT         NOT NULL REFERENCES Location.AppUser(Id),
        TerminalLocationId   BIGINT         NULL     REFERENCES Location.Location(Id),
        Remarks              NVARCHAR(500)  NULL,
        CONSTRAINT PK_ProductionEvent PRIMARY KEY NONCLUSTERED (Id)
    );

    -- Partition-aligned clustered hot path (also serves "previous event for LOT").
    CREATE CLUSTERED INDEX CIX_ProductionEvent_LotEventAt
        ON Workorder.ProductionEvent (LotId, EventAt)
        ON ps_MonthlyUtc(EventAt);
END
GO

-- ---- Workorder.ProductionEventValue (child; NOT partitioned) ----
-- Holds DataCollectionField values configured on the operation template but not
-- promoted to typed columns on ProductionEvent. FK -> ProductionEvent.Id (bare
-- Id, ON DELETE CASCADE) - the reason ProductionEvent keeps a NON-aligned PK.
IF OBJECT_ID(N'Workorder.ProductionEventValue', N'U') IS NULL
BEGIN
    CREATE TABLE Workorder.ProductionEventValue (
        Id                    BIGINT         NOT NULL IDENTITY(1,1),
        ProductionEventId     BIGINT         NOT NULL
            REFERENCES Workorder.ProductionEvent(Id) ON DELETE CASCADE,
        DataCollectionFieldId BIGINT         NOT NULL REFERENCES Parts.DataCollectionField(Id),
        Value                 NVARCHAR(255)  NOT NULL,
        NumericValue          DECIMAL(18,4)  NULL,
        UomId                 BIGINT         NULL     REFERENCES Parts.Uom(Id),
        CreatedAt             DATETIME2(3)   NOT NULL DEFAULT SYSUTCDATETIME(),
        CONSTRAINT PK_ProductionEventValue PRIMARY KEY NONCLUSTERED (Id),
        CONSTRAINT UQ_ProductionEventValue_EventField UNIQUE (ProductionEventId, DataCollectionFieldId)
    );
    -- NOTE: no standalone IX on (ProductionEventId) - the unique constraint
    -- UQ_ProductionEventValue_EventField (ProductionEventId, DataCollectionFieldId)
    -- has ProductionEventId as its leading key, so lookups / joins / FK-cascade
    -- on ProductionEventId are already covered.
END
GO

-- ---- Workorder.ConsumptionEvent (BORN PARTITIONED on ConsumedAt) ----
-- Records which source LOTs were consumed to produce output. No incoming Id-FK
-- -> aligned composite PK NONCLUSTERED (Id, ConsumedAt) + clustered
-- (LotId, ConsumedAt). "LotId" for the partition hot path is SourceLotId (the
-- consumed LOT - the natural query axis). Lot / Container / ContainerTray FKs
-- OMITTED (forward ref / not-yet-created - see note above).
IF OBJECT_ID(N'Workorder.ConsumptionEvent', N'U') IS NULL
BEGIN
    CREATE TABLE Workorder.ConsumptionEvent (
        Id                  BIGINT         NOT NULL IDENTITY(1,1),
        WorkOrderOperationId BIGINT        NULL     REFERENCES Workorder.WorkOrderOperation(Id),
        SourceLotId         BIGINT         NOT NULL,   -- FK -> Lots.Lot.Id omitted (Section B forward ref)
        ProducedLotId       BIGINT         NULL,       -- FK -> Lots.Lot.Id omitted (Section B forward ref)
        ProducedContainerId BIGINT         NULL,       -- FK -> Parts.Container omitted (table not yet created)
        ConsumedItemId      BIGINT         NOT NULL REFERENCES Parts.Item(Id),
        ProducedItemId      BIGINT         NOT NULL REFERENCES Parts.Item(Id),
        PieceCount          INT            NOT NULL,
        LocationId          BIGINT         NOT NULL REFERENCES Location.Location(Id),
        AppUserId           BIGINT         NOT NULL REFERENCES Location.AppUser(Id),
        TerminalLocationId  BIGINT         NULL     REFERENCES Location.Location(Id),
        TrayId              BIGINT         NULL,       -- FK -> Parts.ContainerTray omitted (table not yet created)
        ProducedSerialNumber NVARCHAR(50)  NULL,
        ConsumedAt          DATETIME2(3)   NOT NULL DEFAULT SYSUTCDATETIME(),
        CONSTRAINT PK_ConsumptionEvent PRIMARY KEY NONCLUSTERED (Id, ConsumedAt)
            ON ps_MonthlyUtc(ConsumedAt)
    );

    CREATE CLUSTERED INDEX CIX_ConsumptionEvent_SourceLotConsumedAt
        ON Workorder.ConsumptionEvent (SourceLotId, ConsumedAt)
        ON ps_MonthlyUtc(ConsumedAt);

    CREATE INDEX IX_ConsumptionEvent_ProducedLotId
        ON Workorder.ConsumptionEvent (ProducedLotId, ConsumedAt)
        WHERE ProducedLotId IS NOT NULL
        ON ps_MonthlyUtc(ConsumedAt);
END
GO

-- ---- Workorder.RejectEvent (BORN PARTITIONED on RecordedAt) ----
-- Detailed reject/scrap records. No incoming Id-FK -> aligned composite PK
-- NONCLUSTERED (Id, RecordedAt) + clustered (LotId, RecordedAt). LotId FK to
-- Lots.Lot OMITTED (forward ref). ProductionEventId FK to ProductionEvent is
-- safe (created above) but ProductionEvent is partitioned with a NON-aligned PK
-- on (Id) - a FK referencing that bare-Id unique PK is permitted, so we keep it.
IF OBJECT_ID(N'Workorder.RejectEvent', N'U') IS NULL
BEGIN
    CREATE TABLE Workorder.RejectEvent (
        Id                BIGINT         NOT NULL IDENTITY(1,1),
        ProductionEventId BIGINT         NULL     REFERENCES Workorder.ProductionEvent(Id),
        LotId             BIGINT         NOT NULL,   -- FK -> Lots.Lot.Id omitted (Section B forward ref)
        DefectCodeId      BIGINT         NOT NULL REFERENCES Quality.DefectCode(Id),
        Quantity          INT            NOT NULL,
        ChargeToArea      NVARCHAR(100)  NULL,
        Remarks           NVARCHAR(500)  NULL,
        AppUserId         BIGINT         NOT NULL REFERENCES Location.AppUser(Id),
        RecordedAt        DATETIME2(3)   NOT NULL DEFAULT SYSUTCDATETIME(),
        CONSTRAINT PK_RejectEvent PRIMARY KEY NONCLUSTERED (Id, RecordedAt)
            ON ps_MonthlyUtc(RecordedAt)
    );

    CREATE CLUSTERED INDEX CIX_RejectEvent_LotRecordedAt
        ON Workorder.RejectEvent (LotId, RecordedAt)
        ON ps_MonthlyUtc(RecordedAt);

    -- FK index: "rejects for a production event" path (nullable FK -> filtered).
    CREATE INDEX IX_RejectEvent_ProductionEventId
        ON Workorder.RejectEvent (ProductionEventId, RecordedAt)
        WHERE ProductionEventId IS NOT NULL
        ON ps_MonthlyUtc(RecordedAt);

    CREATE INDEX IX_RejectEvent_DefectCodeId
        ON Workorder.RejectEvent (DefectCodeId, RecordedAt)
        ON ps_MonthlyUtc(RecordedAt);
END
GO

-- ---- Parts.v_EffectiveItemLocation (FDS-02-012: Direct UNION BOM-derived) ----
-- Resolves Part <-> Cell eligibility for Lot_Create (Section B) and the
-- ItemLocation_CheckEligibility proc. Two legs, UNION ALL'd, with a Source
-- discriminator so callers can distinguish (the legs differ on Source so they
-- cannot collide cross-leg; the BomDerived leg cannot emit intra-leg dups
-- because UQ_BomLine_Bom_ChildItem and UQ_ItemLocation_ActiveItemLocation both
-- guarantee single-row joins -> set-UNION dedup would be pure wasted cost):
--   * 'Direct'     - a Parts.ItemLocation row exists for the Item at the
--                    Location (active rows only: DeprecatedAt IS NULL).
--   * 'BomDerived' - the Item is a child line on the ACTIVE published BOM
--                    (PublishedAt IS NOT NULL AND DeprecatedAt IS NULL) of some
--                    parent Item that is itself Direct-eligible at the Location.
-- NOTE: the ancestor-tier hierarchy cascade (Cell -> WorkCenter -> Area -> Site)
-- described in FDS-02-012 is applied by the consuming ItemLocation_CheckEligibility
-- proc (which expands the scanned Cell's ancestor chain); this view exposes the
-- raw configured (Item, Location) eligibility pairs from both legs.
IF OBJECT_ID(N'Parts.v_EffectiveItemLocation', N'V') IS NOT NULL
    DROP VIEW Parts.v_EffectiveItemLocation;
GO
CREATE VIEW Parts.v_EffectiveItemLocation
AS
    -- Direct leg: explicitly configured (Item, Location) eligibility.
    SELECT
        il.ItemId                       AS ItemId,
        il.LocationId                   AS LocationId,
        CAST(N'Direct' AS NVARCHAR(20)) AS Source,
        CAST(NULL AS BIGINT)            AS ParentItemId,
        CAST(NULL AS BIGINT)            AS BomId
    FROM Parts.ItemLocation il
    WHERE il.DeprecatedAt IS NULL

    UNION ALL

    -- BOM-derived leg: child Item is eligible wherever its parent Item is
    -- Direct-eligible, via the parent's active published BOM.
    SELECT
        bl.ChildItemId                      AS ItemId,
        il.LocationId                       AS LocationId,
        CAST(N'BomDerived' AS NVARCHAR(20)) AS Source,
        b.ParentItemId                      AS ParentItemId,
        b.Id                                AS BomId
    FROM Parts.BomLine bl
    INNER JOIN Parts.Bom b
        ON b.Id = bl.BomId
       AND b.PublishedAt IS NOT NULL
       AND b.DeprecatedAt IS NULL
    INNER JOIN Parts.ItemLocation il
        ON il.ItemId = b.ParentItemId
       AND il.DeprecatedAt IS NULL;
GO


-- ============================================================
-- == SECTION B - Lot core tables (Task B) ====================
-- ============================================================
-- Lot family per Data Model v1.9q section 3 + the v1.9q deltas in the
-- Phase 1 plan / design spec (materialized B5 columns + Tool/Cavity FKs +
-- CrtActive). Ordering inside this section: IdentifierSequence (+ seeds)
-- -> Lot (header, not partitioned) -> LotStatusHistory + LotMovement (born
-- partitioned) -> LotGenealogyClosure -> v_LotDerivedQuantities (reads the
-- Section E event tables, created above). Audit lookup LotStatusChanged (26)
-- seeded here (guarded; Task F won't double-insert).
--
-- PK rule (see PARTITIONED-TABLE PK CORRECTION at top of file):
--   * Lots.Lot - header, NOT partitioned -> bare NONCLUSTERED PK (Id).
--   * LotStatusHistory - aligned composite PK NONCLUSTERED (Id, ChangedAt)
--     ON ps_MonthlyUtc(ChangedAt) + clustered (LotId, ChangedAt) ON the scheme.
--   * LotMovement - aligned composite PK NONCLUSTERED (Id, MovedAt)
--     ON ps_MonthlyUtc(MovedAt) + clustered (LotId, MovedAt) ON the scheme.
--   (No incoming bare-Id FK on either history table, so the composite PK is safe.)
--
-- DM-vs-build reconciliations (resolved, documented):
--   * DM section 3 IdentifierSequence carries FormatString / StartingValue / EndingValue
--     / LastValue (NOT Prefix/Padding - the plan's draft proc skeleton named
--     Prefix/Padding; DM section 3 is authoritative). IdentifierSequence_Next parses
--     the .NET-style FormatString (e.g. 'MESL{0:D7}') for prefix + pad width.
--   * DM section 3 (line 496) describes v_LotDerivedQuantities as the SOLE source (no
--     materialized columns). The v1.9q decision (design section 2 B5, migration TODO,
--     plan B-CREATE) supersedes that line: Lot carries materialized
--     TotalInProcess / InventoryAvailable, with the view kept as a diagnostic
--     fallback. This build follows v1.9q.
--   * Lots.Lot gains a RowVersion ROWVERSION column (not in the DM column list)
--     to back the @RowVersion optimistic-lock contract of Lot_UpdateStatus
--     (plan section "API Layer"). Lot is a high-concurrency shop-floor entity; this is
--     the one place the project adopts optimistic locking (config tables remain
--     last-write-wins per the Item-Master design precedent).

-- ---- Lots.IdentifierSequence (+ B-SEED) ----
-- Row-locked gap-free identifier minting (B6). DM section 3 columns. Seeded with the
-- Lot (MESL) + SerializedItem (MESI) counters. Seed LastValue sits at the
-- ~3,000,000 integration floor; the EXACT cutover seed is owed from Ben and is
-- a cutover gate, NOT a build gate - these values are PROVISIONAL.
IF OBJECT_ID(N'Lots.IdentifierSequence', N'U') IS NULL
BEGIN
    CREATE TABLE Lots.IdentifierSequence (
        Id                   BIGINT         NOT NULL IDENTITY(1,1),
        Code                 NVARCHAR(30)   NOT NULL,
        Name                 NVARCHAR(100)  NOT NULL,
        Description          NVARCHAR(500)  NULL,
        FormatString         NVARCHAR(50)   NOT NULL,
        StartingValue        BIGINT         NOT NULL CONSTRAINT DF_IdentifierSequence_StartingValue DEFAULT (1),
        EndingValue          BIGINT         NOT NULL CONSTRAINT DF_IdentifierSequence_EndingValue   DEFAULT (9999999),
        LastValue            BIGINT         NOT NULL CONSTRAINT DF_IdentifierSequence_LastValue      DEFAULT (0),
        ResetIntervalMinutes INT            NULL,
        LastResetAt          DATETIME2(3)   NULL,
        UpdatedAt            DATETIME2(3)   NOT NULL CONSTRAINT DF_IdentifierSequence_UpdatedAt      DEFAULT SYSUTCDATETIME(),
        CONSTRAINT PK_IdentifierSequence PRIMARY KEY NONCLUSTERED (Id),
        CONSTRAINT UQ_IdentifierSequence_Code UNIQUE (Code)
    );
END
GO

-- B-SEED: the two MPP-internal counters. LastValue = 3,000,000 floor
-- (PROVISIONAL - re-sampled from live Flexware at cutover; see DM section 3 / OI-31).
IF NOT EXISTS (SELECT 1 FROM Lots.IdentifierSequence WHERE Code = N'Lot')
    INSERT INTO Lots.IdentifierSequence (Code, Name, Description, FormatString, StartingValue, EndingValue, LastValue)
    VALUES (N'Lot', N'LOT Tracking Ticket', N'LTT barcode counter (MESL). PROVISIONAL seed at the 3,000,000 integration floor - exact cutover value owed from Ben.', N'MESL{0:D7}', 1, 9999999, 3000000);
GO
IF NOT EXISTS (SELECT 1 FROM Lots.IdentifierSequence WHERE Code = N'SerializedItem')
    INSERT INTO Lots.IdentifierSequence (Code, Name, Description, FormatString, StartingValue, EndingValue, LastValue)
    VALUES (N'SerializedItem', N'Serialized Item ID', N'Serialized-part identifier counter (MESI). PROVISIONAL seed at the 3,000,000 integration floor - exact cutover value owed from Ben.', N'MESI{0:D7}', 1, 9999999, 3000000);
GO

-- ---- Lots.Lot (header; NOT partitioned) ----
-- Central tracking entity (DM section 3) + v1.9q deltas: ToolId / ToolCavityId NULL
-- FKs, CrtActive (FDS-10-012), materialized B5 TotalInProcess / InventoryAvailable,
-- RowVersion optimistic-lock token. Legacy DieNumber / CavityNumber retained per
-- DM (cutover transition; removed once all writers use the Tool FKs).
IF OBJECT_ID(N'Lots.Lot', N'U') IS NULL
BEGIN
    CREATE TABLE Lots.Lot (
        Id                  BIGINT         NOT NULL IDENTITY(1,1),
        LotName             NVARCHAR(50)   NOT NULL,
        ItemId              BIGINT         NOT NULL REFERENCES Parts.Item(Id),
        LotOriginTypeId     BIGINT         NOT NULL REFERENCES Lots.LotOriginType(Id),
        LotStatusId         BIGINT         NOT NULL REFERENCES Lots.LotStatusCode(Id),
        PieceCount          INT            NOT NULL,
        MaxPieceCount       INT            NULL,
        Weight              DECIMAL(12,4)  NULL,
        WeightUomId         BIGINT         NULL     REFERENCES Parts.Uom(Id),
        ToolId              BIGINT         NULL     REFERENCES Tools.Tool(Id),
        ToolCavityId        BIGINT         NULL     REFERENCES Tools.ToolCavity(Id),
        DieNumber           NVARCHAR(50)   NULL,     -- legacy as of v1.9 (superseded by ToolId)
        CavityNumber        NVARCHAR(50)   NULL,     -- legacy as of v1.9 (superseded by ToolCavityId)
        VendorLotNumber     NVARCHAR(100)  NULL,
        MinSerialNumber     INT            NULL,
        MaxSerialNumber     INT            NULL,
        ParentLotId         BIGINT         NULL     REFERENCES Lots.Lot(Id),
        CurrentLocationId   BIGINT         NOT NULL REFERENCES Location.Location(Id),
        CrtActive           BIT            NOT NULL CONSTRAINT DF_Lot_CrtActive          DEFAULT (0),  -- v1.9q FDS-10-012
        TotalInProcess      INT            NOT NULL CONSTRAINT DF_Lot_TotalInProcess     DEFAULT (0),  -- v1.9q B5 materialized
        InventoryAvailable  INT            NOT NULL CONSTRAINT DF_Lot_InventoryAvailable DEFAULT (0),  -- v1.9q B5 materialized
        CreatedByUserId     BIGINT         NOT NULL REFERENCES Location.AppUser(Id),
        CreatedAtTerminalId BIGINT         NULL     REFERENCES Location.Location(Id),
        CreatedAt           DATETIME2(3)   NOT NULL CONSTRAINT DF_Lot_CreatedAt DEFAULT SYSUTCDATETIME(),
        UpdatedAt           DATETIME2(3)   NULL,
        UpdatedByUserId     BIGINT         NULL     REFERENCES Location.AppUser(Id),
        RowVersion          ROWVERSION     NOT NULL,  -- optimistic-lock token (Lot_UpdateStatus / Lot_Update)
        CONSTRAINT PK_Lot PRIMARY KEY NONCLUSTERED (Id),
        CONSTRAINT UQ_Lot_LotName UNIQUE (LotName)
    );

    CREATE INDEX IX_Lot_ItemId          ON Lots.Lot (ItemId);
    CREATE INDEX IX_Lot_CurrentLocationId ON Lots.Lot (CurrentLocationId);
    CREATE INDEX IX_Lot_ToolId          ON Lots.Lot (ToolId) WHERE ToolId IS NOT NULL;

    -- B8 filtered index: active (in-process) lots by current location. Active =
    -- not in a terminal LotStatus (Closed=4 / Scrap=3); the hot dashboard query
    -- is "lots currently at / advancing through a location". LotStatus ids are
    -- the stable seeded code-table ids (Good=1, Hold=2, Scrap=3, Closed=4).
    CREATE INDEX IX_Lot_Active
        ON Lots.Lot (CurrentLocationId, LotStatusId)
        INCLUDE (ItemId, PieceCount)
        WHERE LotStatusId IN (1, 2);  -- Good, Hold (still on the floor); excludes Scrap/Closed
END
GO

-- ---- Lots.LotStatusHistory (BORN PARTITIONED on ChangedAt) ----
-- Immutable log of every status transition (DM section 3). Written by Lot_Create
-- (Old=NULL,New='Good') + Lot_UpdateStatus. No incoming bare-Id FK -> aligned
-- composite PK NONCLUSTERED (Id, ChangedAt) + clustered (LotId, ChangedAt).
IF OBJECT_ID(N'Lots.LotStatusHistory', N'U') IS NULL
BEGIN
    CREATE TABLE Lots.LotStatusHistory (
        Id                 BIGINT         NOT NULL IDENTITY(1,1),
        LotId              BIGINT         NOT NULL REFERENCES Lots.Lot(Id),
        OldStatusId        BIGINT         NULL     REFERENCES Lots.LotStatusCode(Id),  -- NULL on first (create) row
        NewStatusId        BIGINT         NOT NULL REFERENCES Lots.LotStatusCode(Id),
        Reason             NVARCHAR(500)  NULL,
        ChangedByUserId    BIGINT         NOT NULL REFERENCES Location.AppUser(Id),
        TerminalLocationId BIGINT         NULL     REFERENCES Location.Location(Id),
        ChangedAt          DATETIME2(3)   NOT NULL CONSTRAINT DF_LotStatusHistory_ChangedAt DEFAULT SYSUTCDATETIME(),
        CONSTRAINT PK_LotStatusHistory PRIMARY KEY NONCLUSTERED (Id, ChangedAt)
            ON ps_MonthlyUtc(ChangedAt)
    );

    CREATE CLUSTERED INDEX CIX_LotStatusHistory_LotChangedAt
        ON Lots.LotStatusHistory (LotId, ChangedAt)
        ON ps_MonthlyUtc(ChangedAt);
END
GO

-- ---- Lots.LotMovement (BORN PARTITIONED on MovedAt) ----
-- Append-only location-change log (DM section 3). Written by Lot_Create (first
-- placement, From=NULL) + Lot_MoveTo. No incoming bare-Id FK -> aligned
-- composite PK NONCLUSTERED (Id, MovedAt) + clustered (LotId, MovedAt).
IF OBJECT_ID(N'Lots.LotMovement', N'U') IS NULL
BEGIN
    CREATE TABLE Lots.LotMovement (
        Id                 BIGINT         NOT NULL IDENTITY(1,1),
        LotId              BIGINT         NOT NULL REFERENCES Lots.Lot(Id),
        FromLocationId     BIGINT         NULL     REFERENCES Location.Location(Id),  -- NULL on first placement
        ToLocationId       BIGINT         NOT NULL REFERENCES Location.Location(Id),
        MovedByUserId      BIGINT         NOT NULL REFERENCES Location.AppUser(Id),
        TerminalLocationId BIGINT         NULL     REFERENCES Location.Location(Id),
        MovedAt            DATETIME2(3)   NOT NULL CONSTRAINT DF_LotMovement_MovedAt DEFAULT SYSUTCDATETIME(),
        CONSTRAINT PK_LotMovement PRIMARY KEY NONCLUSTERED (Id, MovedAt)
            ON ps_MonthlyUtc(MovedAt)
    );

    CREATE CLUSTERED INDEX CIX_LotMovement_LotMovedAt
        ON Lots.LotMovement (LotId, MovedAt)
        ON ps_MonthlyUtc(MovedAt);
END
GO

-- ---- Lots.LotGenealogyClosure (B4; NOT partitioned) ----
-- Materialized closure of the genealogy graph for O(1) Honda trace. Keyed by
-- the (ancestor, descendant) lot pair. Lot_Create writes only the self-row
-- (Depth=0); Split/Merge maintenance is Phase 2. Indexed both directions.
IF OBJECT_ID(N'Lots.LotGenealogyClosure', N'U') IS NULL
BEGIN
    CREATE TABLE Lots.LotGenealogyClosure (
        AncestorLotId   BIGINT NOT NULL REFERENCES Lots.Lot(Id),
        DescendantLotId BIGINT NOT NULL REFERENCES Lots.Lot(Id),
        Depth           INT    NOT NULL,
        CONSTRAINT PK_LotGenealogyClosure PRIMARY KEY (AncestorLotId, DescendantLotId),
        CONSTRAINT CK_LotGenealogyClosure_Depth CHECK (Depth >= 0)
    );

    CREATE INDEX IX_Closure_Descendant
        ON Lots.LotGenealogyClosure (DescendantLotId, AncestorLotId);
END
GO

-- ---- Lots.v_LotDerivedQuantities (B5 diagnostic fallback) ----
-- Derives in-process / available per LOT from the Section E event tables at
-- read time. Diagnostic fallback only; the authoritative values are the
-- materialized Lot.TotalInProcess / Lot.InventoryAvailable columns (v1.9q B5).
-- Derivation (FDS-05-031 intent): a LOT's pieces are reduced by what was
-- consumed FROM it (ConsumptionEvent.SourceLotId) and increased by what was
-- produced INTO it (ConsumptionEvent.ProducedLotId). TotalInProcess is the
-- net still-open quantity at downstream operations; InventoryAvailable is the
-- LOT's seed PieceCount net of consumption. Phase 1 ships the structural view;
-- precise OEE-grade formulas are refined when the event writers land (Phase 3+).
IF OBJECT_ID(N'Lots.v_LotDerivedQuantities', N'V') IS NOT NULL
    DROP VIEW Lots.v_LotDerivedQuantities;
GO
CREATE VIEW Lots.v_LotDerivedQuantities
AS
    SELECT
        l.Id AS LotId,
        -- Produced into this LOT (downstream output) minus consumed from it.
        CAST(ISNULL(prod.Produced, 0) - ISNULL(cons.Consumed, 0) AS INT) AS TotalInProcess,
        -- Seed pieces net of what has been consumed out of this LOT.
        CAST(l.PieceCount - ISNULL(cons.Consumed, 0) AS INT)             AS InventoryAvailable
    FROM Lots.Lot l
    LEFT JOIN (
        SELECT ce.SourceLotId AS LotId, SUM(ce.PieceCount) AS Consumed
        FROM Workorder.ConsumptionEvent ce
        GROUP BY ce.SourceLotId
    ) cons ON cons.LotId = l.Id
    LEFT JOIN (
        SELECT ce.ProducedLotId AS LotId, SUM(ce.PieceCount) AS Produced
        FROM Workorder.ConsumptionEvent ce
        WHERE ce.ProducedLotId IS NOT NULL
        GROUP BY ce.ProducedLotId
    ) prod ON prod.LotId = l.Id;
GO

-- ---- Audit lookup: LotStatusChanged (Id 26) ----
-- Seeded here (guarded) for Lot_UpdateStatus. LotCreated(5) / LotMoved(6) exist.
-- Task F's guard on the same Id makes a double-insert a no-op either order.
IF NOT EXISTS (SELECT 1 FROM Audit.LogEventType WHERE Id = 26)
    INSERT INTO Audit.LogEventType (Id, Code, Name, Description) VALUES
        (26, N'LotStatusChanged', N'LOT Status Changed', N'A LOT status transition was recorded.');
GO


-- ============================================================
-- == SECTION F — Audit split + LotEventLog + repartition (Task F)
-- ============================================================
-- B7 (OI-35 Phase 0 decision): split the single Audit.OperationLog into a
-- 7-yr general OperationLog + a 20-yr Honda-class Lots.LotEventLog. Lot-relevant
-- audit events (Phase 1: entity 'Lot'; container-close / ShippingLabel-mint
-- arrive in later phases) route to LotEventLog via Audit.Audit_LogOperation
-- (the routing change lives in the repeatable proc, not here). Everything else
-- stays in OperationLog. This section:
--   1. CREATEs Lots.LotEventLog (OperationLog row shape + LotId FK -> Lots.Lot),
--      born partitioned on LoggedAt, registered at the 240-month (20-yr) class.
--   2. Repartitions the three existing audit log tables (OperationLog,
--      InterfaceLog, FailureLog) onto ps_MonthlyUtc so the whole family is
--      partition-uniform and TRUNCATE-ready.
--   3. Seeds LogEventType 24/25 (ShiftStarted/ShiftEnded) + LogEntityType 41
--      (Shift). (LogEventType 26 LotStatusChanged was already seeded by Task B;
--      re-seeded here only under an IF NOT EXISTS guard -> no-op either order.)
--
-- TIMESTAMP COLUMN (resolved): LotEventLog mirrors Audit.OperationLog exactly,
-- whose timestamp column is LoggedAt (0001). The DM describes LotEventLog only
-- as "the OperationLog row shape" (B7), so LoggedAt is authoritative. The
-- partition key is LoggedAt.
--
-- PK rule (see PARTITIONED-TABLE PK CORRECTION at top of file):
--   * LotEventLog — no incoming bare-Id FK -> aligned composite
--     PK NONCLUSTERED (Id, LoggedAt) ON ps_MonthlyUtc(LoggedAt) + aligned
--     CLUSTERED INDEX (LotId, LoggedAt) ON the scheme (the natural "events for
--     this LOT" hot path). Registered in Audit.PartitionRetention @ 240 months.
--   * OperationLog / InterfaceLog / FailureLog — their original 0001 PK is a
--     bare-Id CLUSTERED PK with an AUTO-GENERATED name (PK__Operatio__...).
--     We DROP it (looked up dynamically by parent table, since the name is not
--     deterministic), re-add it as the aligned composite PK NONCLUSTERED
--     (Id, <ts>) ON ps_MonthlyUtc(<ts>) named PK_<Table>, add an aligned
--     CLUSTERED INDEX on (<ts>) ON the scheme, and rebuild the three/four
--     secondary indexes ONTO the scheme (each already carries the partition
--     column as a key, so alignment is free). No incoming FK references their
--     Id (verified via sys.foreign_keys 2026-06-09), and no Arc-1 proc/test
--     depends on the clustered-key shape (only Audit.Audit_LogOperation /
--     Audit_LogFailure INSERT, and the ConfigLog/FailureLog reader procs read
--     OTHER tables). The deferred outgoing FKs added to OperationLog by 0002
--     (FK_OperationLog_TerminalLocationId / _LocationId) are unaffected by
--     clustered-index changes and survive the rebuild. These three are NOT
--     registered in PartitionRetention in Phase 1 (age-out deferred); aligning
--     them now keeps the family uniform + TRUNCATE-ready for later.
--   Every DDL below is guarded on current state so a re-run is a no-op.

-- ---- Lots.LotEventLog (BORN PARTITIONED on LoggedAt; 20-yr Honda class) ----
IF OBJECT_ID(N'Lots.LotEventLog', N'U') IS NULL
BEGIN
    CREATE TABLE Lots.LotEventLog (
        Id                  BIGINT          NOT NULL IDENTITY(1,1),
        LoggedAt            DATETIME2(3)    NOT NULL CONSTRAINT DF_LotEventLog_LoggedAt DEFAULT SYSUTCDATETIME(),
        UserId              BIGINT          NULL     REFERENCES Location.AppUser(Id),
        TerminalLocationId  BIGINT          NULL     REFERENCES Location.Location(Id),
        LocationId          BIGINT          NULL     REFERENCES Location.Location(Id),
        LogSeverityId       BIGINT          NOT NULL REFERENCES Audit.LogSeverity(Id),
        LogEventTypeId      BIGINT          NOT NULL REFERENCES Audit.LogEventType(Id),
        LogEntityTypeId     BIGINT          NOT NULL REFERENCES Audit.LogEntityType(Id),
        EntityId            BIGINT          NULL,
        LotId               BIGINT          NOT NULL REFERENCES Lots.Lot(Id),
        Description         NVARCHAR(1000)  NOT NULL,
        OldValue            NVARCHAR(MAX)   NULL,
        NewValue            NVARCHAR(MAX)   NULL,
        CONSTRAINT PK_LotEventLog PRIMARY KEY NONCLUSTERED (Id, LoggedAt)
            ON ps_MonthlyUtc(LoggedAt)
    );

    -- Partition-aligned clustered hot path: "all audit events for this LOT".
    CREATE CLUSTERED INDEX CIX_LotEventLog_LotLoggedAt
        ON Lots.LotEventLog (LotId, LoggedAt)
        ON ps_MonthlyUtc(LoggedAt);

    -- Aligned secondary: entity-type browse (mirrors OperationLog's EntityType index).
    CREATE INDEX IX_LotEventLog_EntityType
        ON Lots.LotEventLog (LogEntityTypeId, EntityId, LoggedAt)
        ON ps_MonthlyUtc(LoggedAt);
END
GO

-- Register LotEventLog for 240-month (20-yr Honda) sliding-window age-out.
IF NOT EXISTS (SELECT 1 FROM Audit.PartitionRetention WHERE SchemaName = N'Lots' AND TableName = N'LotEventLog')
    INSERT INTO Audit.PartitionRetention (SchemaName, TableName, RetentionMonths, Description)
    VALUES (N'Lots', N'LotEventLog', 240, N'B7 LOT audit-event split. Honda 20-yr traceability retention class.');
GO

-- ---- Repartition Audit.OperationLog onto ps_MonthlyUtc(LoggedAt) ----
-- Idempotency: only act if the clustered index is NOT already on the scheme.
IF EXISTS (
    SELECT 1 FROM sys.indexes i
    WHERE i.object_id = OBJECT_ID(N'Audit.OperationLog')
      AND i.type_desc = N'CLUSTERED'
      AND i.data_space_id = (SELECT data_space_id FROM sys.partition_schemes WHERE name = N'ps_MonthlyUtc')
)
    PRINT 'Audit.OperationLog already repartitioned onto ps_MonthlyUtc - skipping.';
ELSE
BEGIN
    DECLARE @opPk NVARCHAR(128) = (
        SELECT kc.name FROM sys.key_constraints kc
        WHERE kc.type = N'PK' AND kc.parent_object_id = OBJECT_ID(N'Audit.OperationLog'));
    IF @opPk IS NOT NULL
        EXEC(N'ALTER TABLE Audit.OperationLog DROP CONSTRAINT ' + @opPk + N';');

    -- Drop the original non-aligned secondary indexes (recreated aligned below).
    IF EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID(N'Audit.OperationLog') AND name = N'IX_OperationLog_LoggedAt')
        DROP INDEX IX_OperationLog_LoggedAt ON Audit.OperationLog;
    IF EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID(N'Audit.OperationLog') AND name = N'IX_OperationLog_EntityType')
        DROP INDEX IX_OperationLog_EntityType ON Audit.OperationLog;
    IF EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID(N'Audit.OperationLog') AND name = N'IX_OperationLog_User')
        DROP INDEX IX_OperationLog_User ON Audit.OperationLog;

    ALTER TABLE Audit.OperationLog
        ADD CONSTRAINT PK_OperationLog PRIMARY KEY NONCLUSTERED (Id, LoggedAt)
            ON ps_MonthlyUtc(LoggedAt);

    CREATE CLUSTERED INDEX CIX_OperationLog_LoggedAt
        ON Audit.OperationLog (LoggedAt)
        ON ps_MonthlyUtc(LoggedAt);

    -- Each secondary index individually guarded so a partial re-apply (crash
    -- after the clustered index but before the secondaries) still recreates the
    -- missing ones — the outer "already repartitioned" guard would otherwise skip
    -- this whole block and leave them permanently absent. DESC on the timestamp
    -- key matches the 0001 originals' recent-first intent.
    IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_OperationLog_EntityType' AND object_id = OBJECT_ID(N'Audit.OperationLog'))
    CREATE INDEX IX_OperationLog_EntityType
        ON Audit.OperationLog (LogEntityTypeId, EntityId, LoggedAt DESC)
        ON ps_MonthlyUtc(LoggedAt);
    IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_OperationLog_User' AND object_id = OBJECT_ID(N'Audit.OperationLog'))
    CREATE INDEX IX_OperationLog_User
        ON Audit.OperationLog (UserId, LoggedAt DESC)
        ON ps_MonthlyUtc(LoggedAt);
END
GO

-- ---- Repartition Audit.InterfaceLog onto ps_MonthlyUtc(LoggedAt) ----
IF EXISTS (
    SELECT 1 FROM sys.indexes i
    WHERE i.object_id = OBJECT_ID(N'Audit.InterfaceLog')
      AND i.type_desc = N'CLUSTERED'
      AND i.data_space_id = (SELECT data_space_id FROM sys.partition_schemes WHERE name = N'ps_MonthlyUtc')
)
    PRINT 'Audit.InterfaceLog already repartitioned onto ps_MonthlyUtc - skipping.';
ELSE
BEGIN
    DECLARE @ifPk NVARCHAR(128) = (
        SELECT kc.name FROM sys.key_constraints kc
        WHERE kc.type = N'PK' AND kc.parent_object_id = OBJECT_ID(N'Audit.InterfaceLog'));
    IF @ifPk IS NOT NULL
        EXEC(N'ALTER TABLE Audit.InterfaceLog DROP CONSTRAINT ' + @ifPk + N';');

    IF EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID(N'Audit.InterfaceLog') AND name = N'IX_InterfaceLog_LoggedAt')
        DROP INDEX IX_InterfaceLog_LoggedAt ON Audit.InterfaceLog;
    IF EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID(N'Audit.InterfaceLog') AND name = N'IX_InterfaceLog_System')
        DROP INDEX IX_InterfaceLog_System ON Audit.InterfaceLog;

    ALTER TABLE Audit.InterfaceLog
        ADD CONSTRAINT PK_InterfaceLog PRIMARY KEY NONCLUSTERED (Id, LoggedAt)
            ON ps_MonthlyUtc(LoggedAt);

    CREATE CLUSTERED INDEX CIX_InterfaceLog_LoggedAt
        ON Audit.InterfaceLog (LoggedAt)
        ON ps_MonthlyUtc(LoggedAt);

    -- Individually guarded (partial-re-apply safe) + DESC matches 0001 original.
    IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_InterfaceLog_System' AND object_id = OBJECT_ID(N'Audit.InterfaceLog'))
    CREATE INDEX IX_InterfaceLog_System
        ON Audit.InterfaceLog (SystemName, LoggedAt DESC)
        ON ps_MonthlyUtc(LoggedAt);
END
GO

-- ---- Repartition Audit.FailureLog onto ps_MonthlyUtc(AttemptedAt) ----
IF EXISTS (
    SELECT 1 FROM sys.indexes i
    WHERE i.object_id = OBJECT_ID(N'Audit.FailureLog')
      AND i.type_desc = N'CLUSTERED'
      AND i.data_space_id = (SELECT data_space_id FROM sys.partition_schemes WHERE name = N'ps_MonthlyUtc')
)
    PRINT 'Audit.FailureLog already repartitioned onto ps_MonthlyUtc - skipping.';
ELSE
BEGIN
    DECLARE @flPk NVARCHAR(128) = (
        SELECT kc.name FROM sys.key_constraints kc
        WHERE kc.type = N'PK' AND kc.parent_object_id = OBJECT_ID(N'Audit.FailureLog'));
    IF @flPk IS NOT NULL
        EXEC(N'ALTER TABLE Audit.FailureLog DROP CONSTRAINT ' + @flPk + N';');

    IF EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID(N'Audit.FailureLog') AND name = N'IX_FailureLog_AttemptedAt')
        DROP INDEX IX_FailureLog_AttemptedAt ON Audit.FailureLog;
    IF EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID(N'Audit.FailureLog') AND name = N'IX_FailureLog_AppUser')
        DROP INDEX IX_FailureLog_AppUser ON Audit.FailureLog;
    IF EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID(N'Audit.FailureLog') AND name = N'IX_FailureLog_EntityEvent')
        DROP INDEX IX_FailureLog_EntityEvent ON Audit.FailureLog;
    IF EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID(N'Audit.FailureLog') AND name = N'IX_FailureLog_ProcedureName')
        DROP INDEX IX_FailureLog_ProcedureName ON Audit.FailureLog;

    ALTER TABLE Audit.FailureLog
        ADD CONSTRAINT PK_FailureLog PRIMARY KEY NONCLUSTERED (Id, AttemptedAt)
            ON ps_MonthlyUtc(AttemptedAt);

    CREATE CLUSTERED INDEX CIX_FailureLog_AttemptedAt
        ON Audit.FailureLog (AttemptedAt)
        ON ps_MonthlyUtc(AttemptedAt);

    -- Each secondary index individually guarded (partial-re-apply safe) +
    -- DESC on AttemptedAt matches the 0001 originals' recent-first intent.
    IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_FailureLog_AppUser' AND object_id = OBJECT_ID(N'Audit.FailureLog'))
    CREATE INDEX IX_FailureLog_AppUser
        ON Audit.FailureLog (AppUserId, AttemptedAt DESC)
        ON ps_MonthlyUtc(AttemptedAt);
    IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_FailureLog_EntityEvent' AND object_id = OBJECT_ID(N'Audit.FailureLog'))
    CREATE INDEX IX_FailureLog_EntityEvent
        ON Audit.FailureLog (LogEntityTypeId, LogEventTypeId, AttemptedAt DESC)
        ON ps_MonthlyUtc(AttemptedAt);
    IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_FailureLog_ProcedureName' AND object_id = OBJECT_ID(N'Audit.FailureLog'))
    CREATE INDEX IX_FailureLog_ProcedureName
        ON Audit.FailureLog (ProcedureName, AttemptedAt DESC)
        ON ps_MonthlyUtc(AttemptedAt);
END
GO

-- ---- Audit lookups: ShiftStarted (24) / ShiftEnded (25) + LotStatusChanged (26) ----
IF NOT EXISTS (SELECT 1 FROM Audit.LogEventType WHERE Id = 24)
    INSERT INTO Audit.LogEventType (Id, Code, Name, Description) VALUES
        (24, N'ShiftStarted', N'Shift Started', N'A production shift instance was opened (Oee.Shift_Start).');
GO
IF NOT EXISTS (SELECT 1 FROM Audit.LogEventType WHERE Id = 25)
    INSERT INTO Audit.LogEventType (Id, Code, Name, Description) VALUES
        (25, N'ShiftEnded', N'Shift Ended', N'A production shift instance was closed (Oee.Shift_End).');
GO
-- LotStatusChanged (26) is normally seeded by Task B (Section B); guarded here so
-- a Section-F-first apply still has it and a Section-B-first apply is a no-op.
IF NOT EXISTS (SELECT 1 FROM Audit.LogEventType WHERE Id = 26)
    INSERT INTO Audit.LogEventType (Id, Code, Name, Description) VALUES
        (26, N'LotStatusChanged', N'LOT Status Changed', N'A LOT status transition was recorded.');
GO

-- ---- Audit lookup: Shift entity type (41) ----
IF NOT EXISTS (SELECT 1 FROM Audit.LogEntityType WHERE Id = 41)
    INSERT INTO Audit.LogEntityType (Id, Code, Name, Description) VALUES
        (41, N'Shift', N'Shift', N'Runtime production shift instance (Oee.Shift).');
GO

-- ---- B3 single-open-Shift invariant: DB-level backstop ----
-- Oee.Shift_Start rejects (friendly status row) when ANY open shift exists
-- (WHERE ActualEnd IS NULL — GLOBAL, not scoped to a schedule/line/location).
-- That proc-level EXISTS check can race under concurrency, so a UNIQUE FILTERED
-- index on ActualEnd (filtered to the open rows) backs the invariant at the DB:
-- a unique index treats the all-NULL filtered rows as mutually equal, permitting
-- exactly one row where ActualEnd IS NULL. The proc's status-row rejection still
-- fires first on the happy path; this index is the concurrency backstop.
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'UIX_Shift_SingleOpen' AND object_id = OBJECT_ID(N'Oee.Shift'))
    CREATE UNIQUE INDEX UIX_Shift_SingleOpen ON Oee.Shift (ActualEnd) WHERE ActualEnd IS NULL;
GO


-- ============================================================
-- == SECTION C — Terminal resolution seeds (Task C) ==========
-- ============================================================
-- Backs Location.Terminal_GetByIpAddress / Terminal_List (repeatable procs).
-- The Terminal kind is LocationTypeDefinition DefId 7 (Cell-tier, seeded in
-- 0002). Terminals carry an EAV IpAddress attribute (already seeded in 0002:
-- LocationAttributeDefinition DefId-7 'IpAddress' NVARCHAR). The resolver reads
-- Location.LocationAttribute.AttributeValue (NOT a bare AttributeName/Value pair
-- — the value lives on LocationAttribute and the name lives on its
-- LocationAttributeDefinition) joined through the IpAddress attr-def to find the
-- Terminal Location for a connecting IP.
--
-- This section adds:
--   1. Two NEW LocationAttributeDefinition rows on the Terminal type:
--      'DefaultScreen' (NVARCHAR) + 'RequiresCompletionConfirm' (BIT, OI-16).
--      Guarded against the 0014 filtered-unique (LocationTypeDefinitionId,
--      AttributeName) WHERE DeprecatedAt IS NULL.
--   2. A covering index on Location.LocationAttribute (LocationAttributeDefinitionId,
--      AttributeValue) for the reverse IP lookup (existing indexes only cover the
--      forward LocationId / (LocationId, DefinitionId) paths).
--
-- The global FALLBACK Terminal Location ('FALLBACK-TERMINAL') — returned by the
-- resolver when an unregistered IP connects (the resolver NEVER errors) — is NOT
-- seeded here: it is a Location row whose parent is the plant Site (MPP-MAD),
-- which only exists after the plant-hierarchy seed runs. Migrations run BEFORE
-- seeds, so the row lives in sql/seeds/011_seed_locations_mpp_plant.sql (emitted
-- by gen_locations_mpp.js), parented at the Site for a 'Shared'-mode default.
--
-- NOT seeded (per Task C contract): TerminalMode (DERIVED from the parent tier in
-- the resolver), IdleTimeoutSeconds / RequiresReauthForSensitive (Perspective /
-- per-action AD elevation — out of SQL scope). ASCII-only strings throughout.

-- ---- 1. Terminal attribute definitions: DefaultScreen + RequiresCompletionConfirm ----
IF NOT EXISTS (
    SELECT 1 FROM Location.LocationAttributeDefinition
    WHERE LocationTypeDefinitionId = 7 AND AttributeName = N'DefaultScreen' AND DeprecatedAt IS NULL)
    INSERT INTO Location.LocationAttributeDefinition
        (LocationTypeDefinitionId, AttributeName, DataType, IsRequired, DefaultValue, Uom, SortOrder, Description)
    VALUES
        (7, N'DefaultScreen', N'NVARCHAR', 0, NULL, NULL, 4, N'Perspective view path this terminal opens to on session start.');
GO
IF NOT EXISTS (
    SELECT 1 FROM Location.LocationAttributeDefinition
    WHERE LocationTypeDefinitionId = 7 AND AttributeName = N'RequiresCompletionConfirm' AND DeprecatedAt IS NULL)
    INSERT INTO Location.LocationAttributeDefinition
        (LocationTypeDefinitionId, AttributeName, DataType, IsRequired, DefaultValue, Uom, SortOrder, Description)
    VALUES
        (7, N'RequiresCompletionConfirm', N'BIT', 0, N'0', NULL, 5, N'OI-16: terminal prompts for explicit completion confirmation before advancing a LOT.');
GO

-- ---- 2. Reverse IP-lookup index on Location.LocationAttribute ----
-- The resolver filters LocationAttribute by (LocationAttributeDefinitionId =
-- <IpAddress def>, AttributeValue = @IpAddress). Existing 0002 indexes cover only
-- LocationId / (LocationId, DefinitionId); add the (DefinitionId, AttributeValue)
-- path so the IP resolve is a seek. Guarded so a re-apply is a no-op.
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_LocationAttribute_DefinitionValue' AND object_id = OBJECT_ID(N'Location.LocationAttribute'))
    CREATE INDEX IX_LocationAttribute_DefinitionValue
        ON Location.LocationAttribute (LocationAttributeDefinitionId, AttributeValue)
        INCLUDE (LocationId);
GO


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
