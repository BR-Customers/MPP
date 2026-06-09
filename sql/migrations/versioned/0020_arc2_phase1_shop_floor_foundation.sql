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
