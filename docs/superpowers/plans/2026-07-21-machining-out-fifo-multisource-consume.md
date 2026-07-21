# Machining OUT Multi-Source FIFO Consume — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make Machining OUT consume castings across the FIFO queue (strict oldest-first), so one machined sub-assembly LOT can be sourced from multiple castings, never drives a casting negative, and offers a partial mint on shortfall.

**Architecture:** Rework `Workorder.MachiningOut_Mint` to walk the FIFO queue of same-part castings at the cell (arrival order), consuming each under a row lock bounded by its live availability, writing one ConsumptionEvent + genealogy edge per source. Add `@AllowPartial` + a 4th result column `@Available`. Thin Python/NQ/UI changes surface the shortfall as a confirm popup.

**Tech Stack:** SQL Server 2022 stored procs (repeatable migrations), tSQL test harness (`.\Run-Tests.ps1`), Ignition Perspective (Jython Core scripts + `view.json`).

## Global Constraints

- **DB safety:** run tests ONLY as `.\Run-Tests.ps1 -DatabaseName "MPP_MES_Test"` (or `-Filter`). NEVER a bare `.\Run-Tests.ps1`, NEVER `MPP_MES_Dev` (a guardrail defaults the runner to Test and blocks dropping `*_Dev`, but pass the flag anyway).
- **INSERT-EXEC safety** (this proc is captured via INSERT-EXEC): all rejecting validations run BEFORE `BEGIN TRANSACTION`; the CATCH is the only `ROLLBACK` site; `RAISERROR` not `THROW`; no OUTPUT params.
- **Result shape:** every exit ends `SELECT @Status AS Status, @Message AS Message, @NewId AS NewId, @Available AS Available;` (4 columns — the new `@Available` is the blast-radius item).
- **FIFO source set:** OPEN (`LotStatusCode <> 'Closed'`) LOTs with `ItemId = @SrcItem` at `CurrentLocationId = @SrcLoc`, ordered **arrival-first: `LastMovementAt ASC, Id ASC`** (matches `Lots.Lot_GetWipQueueByLocation`). Consumable per casting = `InventoryAvailable` (`InventoryAvailable <= PieceCount`, so bounding by it keeps PieceCount ≥ 0).
- **Traceability is mandatory:** one `ConsumptionEvent` + one `LotGenealogy` Consumption edge (RelationshipTypeId=3) + closure ancestors **per source casting**.
- ASCII-only SQL literals. Stage EXPLICIT git paths only (never `git add -A`). Omit `Co-Authored-By`.
- Baseline: the suite has ~8 pre-existing failures (`0027` MachiningIN `[MachIn]/[MachInGuard]/[Rework]` cluster) + `077_Lot_Search` script error + `0022` fixture-isolation throwers — NOT ours; the bar is ZERO NEW failures + all `[MoMint]`/new FIFO tests green.

---

### Task 1: Rework `MachiningOut_Mint` to multi-source FIFO consume

**Files:**
- Modify: `sql/migrations/repeatable/R__Workorder_MachiningOut_Mint.sql`
- Test: `sql/tests/0027_PlantFloor_Machining/070_MachiningOut_Mint.sql` (extend)

**Interfaces:**
- Produces: `Workorder.MachiningOut_Mint(@SourceLotId, @OperationTemplateId, @PieceCount, @ProducedItemId=NULL, @AppUserId, @TerminalLocationId=NULL, @AllowPartial BIT=0)` → result `Status, Message, NewId, Available`. `@SourceLotId` is the FIFO handle (cell + part). Consumes strict oldest-first across all open same-part castings at that cell. Shortfall + `@AllowPartial=0` → reject, `Available` = max producible. `@AllowPartial=1` → mint `floor(totalAvail/QtyPer)`.

- [ ] **Step 1: Add the FIFO test fixtures/assertions (failing)**

In `sql/tests/0027_PlantFloor_Machining/070_MachiningOut_Mint.sql`, after the existing final assertion and BEFORE the teardown block, append these tests (they exercise multi-casting FIFO; the fixture reuses the file's `@Casting`=`5G0-c`, `@Machined`=`5G0-SA`, `@Line`, `@MoTpl`, `@U`, `@Origin` from the top of the file — those DECLAREs are file-scoped per GO batch, so re-declare in each new batch):

```sql
-- =============================================
-- FIFO multi-source: two castings, mint spans both (oldest-first), 2 parents
-- =============================================
DECLARE @U BIGINT = (SELECT Id FROM Location.AppUser WHERE Initials = N'DEV');
DECLARE @Casting BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'5G0-c');
DECLARE @Machined BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'5G0-SA');
DECLARE @Line BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MA1-5GOF-MOUT');
DECLARE @Origin BIGINT = (SELECT Id FROM Lots.LotOriginType WHERE Code = N'Manufactured');
DECLARE @MoTpl BIGINT = (SELECT TOP 1 ot.Id FROM Parts.OperationTemplate ot
    JOIN Parts.OperationType oty ON oty.Id = ot.OperationTypeId
    JOIN Parts.OperationRoleKind rk ON rk.Id = oty.OperationRoleKindId
    WHERE oty.Code = N'MachiningOut' AND rk.Code = N'ConsumeMint' AND ot.DeprecatedAt IS NULL);

-- Oldest casting: 18 pcs. Newer casting: 30 pcs. (arrival order = creation order here)
DECLARE @Old BIGINT, @New BIGINT;
CREATE TABLE #FA (Status BIT, Message NVARCHAR(500), NewId BIGINT, MintedLotName NVARCHAR(50));
INSERT INTO #FA EXEC Lots.Lot_Create @ItemId=@Casting, @LotOriginTypeId=@Origin, @CurrentLocationId=@Line, @PieceCount=18, @AppUserId=@U;
SELECT @Old = NewId FROM #FA; DELETE FROM #FA;
INSERT INTO #FA EXEC Lots.Lot_Create @ItemId=@Casting, @LotOriginTypeId=@Origin, @CurrentLocationId=@Line, @PieceCount=30, @AppUserId=@U;
SELECT @New = NewId FROM #FA; DROP TABLE #FA;

-- Mint 24: should draw 18 from @Old (closes it) + 6 from @New (stays open at 24).
DECLARE @fm TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT, Available INT);
INSERT INTO @fm EXEC Workorder.MachiningOut_Mint @SourceLotId=@Old, @OperationTemplateId=@MoTpl, @PieceCount=24, @AppUserId=@U, @TerminalLocationId=@Line;
DECLARE @fmStatus NVARCHAR(10) = (SELECT CAST(Status AS NVARCHAR(10)) FROM @fm);
DECLARE @fmLot BIGINT = (SELECT NewId FROM @fm);
EXEC test.Assert_IsEqual @TestName = N'[FIFO] mint spanning two castings succeeds', @Expected = N'1', @Actual = @fmStatus;

DECLARE @oldPc NVARCHAR(10) = (SELECT CAST(PieceCount AS NVARCHAR(10)) FROM Lots.Lot WHERE Id=@Old);
EXEC test.Assert_IsEqual @TestName = N'[FIFO] oldest casting drained to 0', @Expected = N'0', @Actual = @oldPc;
DECLARE @oldSt NVARCHAR(20) = (SELECT sc.Code FROM Lots.Lot l JOIN Lots.LotStatusCode sc ON sc.Id=l.LotStatusId WHERE l.Id=@Old);
EXEC test.Assert_IsEqual @TestName = N'[FIFO] oldest casting Closed', @Expected = N'Closed', @Actual = @oldSt;
DECLARE @newPc NVARCHAR(10) = (SELECT CAST(PieceCount AS NVARCHAR(10)) FROM Lots.Lot WHERE Id=@New);
EXEC test.Assert_IsEqual N'[FIFO] next casting 30-6=24', N'24', @newPc;
DECLARE @newSt NVARCHAR(20) = (SELECT sc.Code FROM Lots.Lot l JOIN Lots.LotStatusCode sc ON sc.Id=l.LotStatusId WHERE l.Id=@New);
EXEC test.Assert_IsEqual N'[FIFO] next casting stays Good', N'Good', @newSt;
DECLARE @parents NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM Lots.LotGenealogy WHERE ChildLotId=@fmLot AND RelationshipTypeId=3);
EXEC test.Assert_IsEqual N'[FIFO] minted LOT has 2 Consumption parents', N'2', @parents;
DECLARE @ce NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM Workorder.ConsumptionEvent WHERE ProducedLotId=@fmLot);
EXEC test.Assert_IsEqual N'[FIFO] two ConsumptionEvents (one per source)', N'2', @ce;
DECLARE @never NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM Lots.Lot WHERE Id IN (@Old,@New) AND PieceCount < 0);
EXEC test.Assert_IsEqual N'[FIFO] no casting negative', N'0', @never;
GO

-- =============================================
-- Shortfall: reject (default) then partial (AllowPartial=1)
-- =============================================
DECLARE @U BIGINT = (SELECT Id FROM Location.AppUser WHERE Initials = N'DEV');
DECLARE @Casting BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'5G0-c');
DECLARE @Line BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MA1-5GOF-MOUT');
DECLARE @Origin BIGINT = (SELECT Id FROM Lots.LotOriginType WHERE Code = N'Manufactured');
DECLARE @MoTpl BIGINT = (SELECT TOP 1 ot.Id FROM Parts.OperationTemplate ot
    JOIN Parts.OperationType oty ON oty.Id = ot.OperationTypeId JOIN Parts.OperationRoleKind rk ON rk.Id = oty.OperationRoleKindId
    WHERE oty.Code = N'MachiningOut' AND rk.Code = N'ConsumeMint' AND ot.DeprecatedAt IS NULL);
-- clear leftover open 5G0-c castings from the prior FIFO test so the queue total is known
UPDATE Lots.Lot SET LotStatusId=(SELECT Id FROM Lots.LotStatusCode WHERE Code=N'Closed')
  WHERE ItemId=@Casting AND CurrentLocationId=@Line AND LotStatusId=(SELECT Id FROM Lots.LotStatusCode WHERE Code=N'Good');
DECLARE @S1 BIGINT;
CREATE TABLE #SF (Status BIT, Message NVARCHAR(500), NewId BIGINT, MintedLotName NVARCHAR(50));
INSERT INTO #SF EXEC Lots.Lot_Create @ItemId=@Casting, @LotOriginTypeId=@Origin, @CurrentLocationId=@Line, @PieceCount=20, @AppUserId=@U;
SELECT @S1 = NewId FROM #SF; DROP TABLE #SF;

-- request 24 with only 20 available, no partial -> reject, Available=20
DECLARE @sm TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT, Available INT);
INSERT INTO @sm EXEC Workorder.MachiningOut_Mint @SourceLotId=@S1, @OperationTemplateId=@MoTpl, @PieceCount=24, @AppUserId=@U, @TerminalLocationId=@Line;
DECLARE @smS NVARCHAR(10) = (SELECT CAST(Status AS NVARCHAR(10)) FROM @sm);
DECLARE @smA NVARCHAR(10) = (SELECT CAST(Available AS NVARCHAR(10)) FROM @sm);
EXEC test.Assert_IsEqual N'[Shortfall] rejected (no partial)', N'0', @smS;
EXEC test.Assert_IsEqual N'[Shortfall] Available reported = 20', N'20', @smA;
DECLARE @s1pc NVARCHAR(10) = (SELECT CAST(PieceCount AS NVARCHAR(10)) FROM Lots.Lot WHERE Id=@S1);
EXEC test.Assert_IsEqual N'[Shortfall] nothing consumed', N'20', @s1pc;

-- request 24 with AllowPartial=1 -> mint 20, drain the queue
DELETE FROM @sm;
INSERT INTO @sm EXEC Workorder.MachiningOut_Mint @SourceLotId=@S1, @OperationTemplateId=@MoTpl, @PieceCount=24, @AppUserId=@U, @TerminalLocationId=@Line, @AllowPartial=1;
DECLARE @smS2 NVARCHAR(10) = (SELECT CAST(Status AS NVARCHAR(10)) FROM @sm);
DECLARE @pmLot BIGINT = (SELECT NewId FROM @sm);
EXEC test.Assert_IsEqual N'[Partial] partial mint succeeds', N'1', @smS2;
DECLARE @pmPc NVARCHAR(10) = (SELECT CAST(PieceCount AS NVARCHAR(10)) FROM Lots.Lot WHERE Id=@pmLot);
EXEC test.Assert_IsEqual N'[Partial] minted 20 (all available)', N'20', @pmPc;
DECLARE @s1after NVARCHAR(10) = (SELECT CAST(PieceCount AS NVARCHAR(10)) FROM Lots.Lot WHERE Id=@S1);
EXEC test.Assert_IsEqual N'[Partial] source drained to 0', N'0', @s1after;
GO
```

- [ ] **Step 2: Run to verify the new tests fail**

Run: `.\Run-Tests.ps1 -DatabaseName "MPP_MES_Test"`
Expected: FAIL — `[FIFO] mint spanning two castings succeeds` fails (the current proc consumes only `@Old`, so it over-consumes `@Old` to −6 and never touches `@New`); the `@fm`/`@sm` INSERT-EXEC also errors because the current proc returns only 3 columns while the temp table has 4 (`Available`). Both confirm the rework is needed.

- [ ] **Step 3: Rework the proc**

Replace `sql/migrations/repeatable/R__Workorder_MachiningOut_Mint.sql` with the version below. It keeps the pre-transaction validations and produced-part derivation, replaces the single-source consume with the FIFO walk, and adds `@AllowPartial` + `@Available`:

```sql
-- ============================================================
-- Repeatable:  R__Workorder_MachiningOut_Mint.sql
-- Author:      Blue Ridge Automation
-- Version:     2.0 (2026-07-21) - MULTI-SOURCE FIFO consume.
-- Description: Machining OUT consume-mint. @SourceLotId is the FIFO HANDLE (its cell +
--              casting part). Consumes strict oldest-first (arrival order) across ALL
--              open same-part castings at that cell, rolling into the next as each
--              empties; each draw is bounded by the casting's lock-fresh
--              InventoryAvailable so NO casting can go negative. Mints ONE SubAssembly
--              LOT named <oldest-casting-LTT>-NN, with one ConsumptionEvent + Consumption
--              genealogy edge + closure PER source casting (multi-parent traceability).
--              Shortfall: @AllowPartial=0 -> reject + Available=max producible;
--              @AllowPartial=1 -> mint floor(totalAvail/QtyPer). INSERT-EXEC safe:
--              rejects before BEGIN TRAN; RAISERROR (not THROW) in CATCH. Result:
--              Status, Message, NewId, Available.
-- ============================================================
CREATE OR ALTER PROCEDURE Workorder.MachiningOut_Mint
    @SourceLotId         BIGINT,
    @OperationTemplateId BIGINT,
    @PieceCount          INT,
    @ProducedItemId      BIGINT = NULL,
    @AppUserId           BIGINT,
    @TerminalLocationId  BIGINT = NULL,
    @AllowPartial        BIT    = 0
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;
    DECLARE @Status BIT = 0, @Message NVARCHAR(500) = N'Unknown error', @NewId BIGINT = NULL, @Available INT = 0;
    DECLARE @ProcName NVARCHAR(200) = N'Workorder.MachiningOut_Mint';
    DECLARE @Params NVARCHAR(MAX) = (SELECT @SourceLotId AS SourceLotId, @OperationTemplateId AS OperationTemplateId,
        @PieceCount AS PieceCount, @ProducedItemId AS ProducedItemId, @AppUserId AS AppUserId,
        @TerminalLocationId AS TerminalLocationId, @AllowPartial AS AllowPartial FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);
    DECLARE @GoodStatusId BIGINT = (SELECT Id FROM Lots.LotStatusCode WHERE Code=N'Good');
    DECLARE @ClosedStatusId BIGINT = (SELECT Id FROM Lots.LotStatusCode WHERE Code=N'Closed');
    DECLARE @ManufacturedOriginId BIGINT = (SELECT Id FROM Lots.LotOriginType WHERE Code=N'Manufactured');
    DECLARE @SrcItem BIGINT, @SrcLoc BIGINT, @Blocks BIT, @SrcStatusCode NVARCHAR(20);
    DECLARE @BomId BIGINT, @QtyPer DECIMAL(18,4), @Consumed INT, @CandCount INT, @TotalAvail INT;
    DECLARE @MintedName NVARCHAR(50), @OldestName NVARCHAR(50), @NextOrd INT, @ProducedPn NVARCHAR(50);
    DECLARE @Activity NVARCHAR(500), @NewValue NVARCHAR(MAX);

    BEGIN TRY
        -- ===== Pre-transaction validations =====
        IF @SourceLotId IS NULL OR @OperationTemplateId IS NULL OR @PieceCount IS NULL OR @AppUserId IS NULL
        BEGIN SET @Message=N'Required parameter missing.';
            IF @AppUserId IS NOT NULL EXEC Audit.Audit_LogFailure @AppUserId=@AppUserId, @LogEntityTypeCode=N'Lot', @EntityId=@SourceLotId, @LogEventTypeCode=N'MachiningOutCompleted', @FailureReason=@Message, @ProcedureName=@ProcName, @AttemptedParameters=@Params;
            GOTO Reply; END
        IF @PieceCount <= 0 BEGIN SET @Message=N'PieceCount must be positive.';
            EXEC Audit.Audit_LogFailure @AppUserId=@AppUserId, @LogEntityTypeCode=N'Lot', @EntityId=@SourceLotId, @LogEventTypeCode=N'MachiningOutCompleted', @FailureReason=@Message, @ProcedureName=@ProcName, @AttemptedParameters=@Params; GOTO Reply; END
        IF NOT EXISTS (SELECT 1 FROM Parts.OperationTemplate ot JOIN Parts.OperationType oty ON oty.Id=ot.OperationTypeId
                       JOIN Parts.OperationRoleKind rk ON rk.Id=oty.OperationRoleKindId
                       WHERE ot.Id=@OperationTemplateId AND ot.DeprecatedAt IS NULL AND rk.Code=N'ConsumeMint')
        BEGIN SET @Message=N'OperationTemplate not found, deprecated, or not a consume-mint role.';
            EXEC Audit.Audit_LogFailure @AppUserId=@AppUserId, @LogEntityTypeCode=N'Lot', @EntityId=@SourceLotId, @LogEventTypeCode=N'MachiningOutCompleted', @FailureReason=@Message, @ProcedureName=@ProcName, @AttemptedParameters=@Params; GOTO Reply; END
        -- Source LOT = FIFO handle (cell + part); must be open/not-blocked.
        SELECT @SrcItem=l.ItemId, @SrcLoc=l.CurrentLocationId, @Blocks=sc.BlocksProduction, @SrcStatusCode=sc.Code
        FROM Lots.Lot l JOIN Lots.LotStatusCode sc ON sc.Id=l.LotStatusId WHERE l.Id=@SourceLotId;
        IF @SrcItem IS NULL BEGIN SET @Message=N'Source LOT not found.';
            EXEC Audit.Audit_LogFailure @AppUserId=@AppUserId, @LogEntityTypeCode=N'Lot', @EntityId=@SourceLotId, @LogEventTypeCode=N'MachiningOutCompleted', @FailureReason=@Message, @ProcedureName=@ProcName, @AttemptedParameters=@Params; GOTO Reply; END
        IF @Blocks=1 OR @SrcStatusCode=N'Closed' BEGIN SET @Message=N'Source LOT is '+@SrcStatusCode+N' and cannot be consumed.';
            EXEC Audit.Audit_LogFailure @AppUserId=@AppUserId, @LogEntityTypeCode=N'Lot', @EntityId=@SourceLotId, @LogEventTypeCode=N'MachiningOutCompleted', @FailureReason=@Message, @ProcedureName=@ProcName, @AttemptedParameters=@Params; GOTO Reply; END
        -- Derive produced part (published BOM whose child = @SrcItem, parent line-eligible).
        IF @ProducedItemId IS NULL
        BEGIN
            SELECT @CandCount = COUNT(DISTINCT b.ParentItemId)
            FROM Parts.Bom b JOIN Parts.BomLine bl ON bl.BomId=b.Id AND bl.ChildItemId=@SrcItem
            WHERE b.PublishedAt IS NOT NULL AND b.DeprecatedAt IS NULL
              AND EXISTS (SELECT 1 FROM Parts.v_EffectiveItemLocation eil WHERE eil.ItemId=b.ParentItemId
                          AND eil.LocationId IN (SELECT LocationId FROM Location.ufn_AncestorLocationIds(@SrcLoc)));
            IF @CandCount = 0 BEGIN SET @Message=N'No producible part at this line consumes this component.';
                EXEC Audit.Audit_LogFailure @AppUserId=@AppUserId, @LogEntityTypeCode=N'Lot', @EntityId=@SourceLotId, @LogEventTypeCode=N'MachiningOutCompleted', @FailureReason=@Message, @ProcedureName=@ProcName, @AttemptedParameters=@Params; GOTO Reply; END
            IF @CandCount > 1 BEGIN SET @Message=N'Multiple producible parts consume this component; specify ProducedItemId.';
                EXEC Audit.Audit_LogFailure @AppUserId=@AppUserId, @LogEntityTypeCode=N'Lot', @EntityId=@SourceLotId, @LogEventTypeCode=N'MachiningOutCompleted', @FailureReason=@Message, @ProcedureName=@ProcName, @AttemptedParameters=@Params; GOTO Reply; END
            SELECT @ProducedItemId = MIN(b.ParentItemId)
            FROM Parts.Bom b JOIN Parts.BomLine bl ON bl.BomId=b.Id AND bl.ChildItemId=@SrcItem
            WHERE b.PublishedAt IS NOT NULL AND b.DeprecatedAt IS NULL
              AND EXISTS (SELECT 1 FROM Parts.v_EffectiveItemLocation eil WHERE eil.ItemId=b.ParentItemId
                          AND eil.LocationId IN (SELECT LocationId FROM Location.ufn_AncestorLocationIds(@SrcLoc)));
        END
        SET @BomId = (SELECT TOP 1 Id FROM Parts.Bom WHERE ParentItemId=@ProducedItemId AND PublishedAt IS NOT NULL AND DeprecatedAt IS NULL ORDER BY VersionNumber DESC);
        SET @QtyPer = (SELECT QtyPer FROM Parts.BomLine WHERE BomId=@BomId AND ChildItemId=@SrcItem);
        IF @BomId IS NULL OR @QtyPer IS NULL OR @QtyPer <= 0 BEGIN SET @Message=N'Produced part has no active BOM consuming this component.';
            EXEC Audit.Audit_LogFailure @AppUserId=@AppUserId, @LogEntityTypeCode=N'Lot', @EntityId=@SourceLotId, @LogEventTypeCode=N'MachiningOutCompleted', @FailureReason=@Message, @ProcedureName=@ProcName, @AttemptedParameters=@Params; GOTO Reply; END
        SET @Consumed = CAST(@QtyPer * @PieceCount AS INT);

        -- FIFO source total (open, same part, same cell). @Available = max producible sub-assemblies.
        SELECT @TotalAvail = ISNULL(SUM(l.InventoryAvailable),0)
        FROM Lots.Lot l JOIN Lots.LotStatusCode sc ON sc.Id=l.LotStatusId
        WHERE l.ItemId=@SrcItem AND l.CurrentLocationId=@SrcLoc AND sc.Code<>N'Closed' AND l.InventoryAvailable > 0;
        SET @Available = CAST(FLOOR(@TotalAvail / @QtyPer) AS INT);

        IF @TotalAvail < @Consumed
        BEGIN
            IF @AllowPartial = 0
            BEGIN SET @Message=N'Only '+CAST(@Available AS NVARCHAR(10))+N' available in the FIFO queue (requested '+CAST(@PieceCount AS NVARCHAR(10))+N').';
                EXEC Audit.Audit_LogFailure @AppUserId=@AppUserId, @LogEntityTypeCode=N'Lot', @EntityId=@SourceLotId, @LogEventTypeCode=N'MachiningOutCompleted', @FailureReason=@Message, @ProcedureName=@ProcName, @AttemptedParameters=@Params; GOTO Reply; END
            SET @PieceCount = @Available;
            IF @PieceCount <= 0 BEGIN SET @Message=N'No castings available to consume.';
                EXEC Audit.Audit_LogFailure @AppUserId=@AppUserId, @LogEntityTypeCode=N'Lot', @EntityId=@SourceLotId, @LogEventTypeCode=N'MachiningOutCompleted', @FailureReason=@Message, @ProcedureName=@ProcName, @AttemptedParameters=@Params; GOTO Reply; END
            SET @Consumed = CAST(@QtyPer * @PieceCount AS INT);
        END
        SET @ProducedPn = (SELECT PartNumber FROM Parts.Item WHERE Id=@ProducedItemId);

        -- ===== Mutation (atomic) =====
        BEGIN TRANSACTION;
        -- Ordered FIFO list of candidate castings (arrival-first, matches Lot_GetWipQueueByLocation).
        DECLARE @Queue TABLE (Ord INT IDENTITY(1,1), LotId BIGINT);
        INSERT INTO @Queue (LotId)
        SELECT l.Id
        FROM Lots.Lot l JOIN Lots.LotStatusCode sc ON sc.Id=l.LotStatusId
        LEFT JOIN (SELECT LotId, MAX(MovedAt) AS LastMovementAt FROM Lots.LotMovement GROUP BY LotId) lm ON lm.LotId=l.Id
        WHERE l.ItemId=@SrcItem AND l.CurrentLocationId=@SrcLoc AND sc.Code<>N'Closed' AND l.InventoryAvailable > 0
        ORDER BY lm.LastMovementAt ASC, l.Id ASC;

        SET @OldestName = (SELECT LotName FROM Lots.Lot WHERE Id = (SELECT LotId FROM @Queue WHERE Ord=1));
        SET @NextOrd = ISNULL((SELECT MAX(TRY_CAST(RIGHT(LotName,2) AS INT)) FROM Lots.Lot WHERE LotName LIKE @OldestName + N'-[0-9][0-9]'),0)+1;
        IF @NextOrd > 99 RAISERROR(N'Casting already has 99 machined sublots.',16,1);
        SET @MintedName = @OldestName + N'-' + RIGHT(N'0'+CAST(@NextOrd AS NVARCHAR(2)),2);

        INSERT INTO Lots.Lot (LotName, ItemId, LotOriginTypeId, LotStatusId, PieceCount, MaxPieceCount,
            Weight, WeightUomId, ToolId, ToolCavityId, CavityNumber, VendorLotNumber, MinSerialNumber, MaxSerialNumber,
            CurrentLocationId, TotalInProcess, InventoryAvailable, CreatedByUserId, CreatedAtTerminalId, CreatedAt)
        VALUES (@MintedName, @ProducedItemId, @ManufacturedOriginId, @GoodStatusId, @PieceCount, (SELECT MaxLotSize FROM Parts.Item WHERE Id=@ProducedItemId),
            NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, @SrcLoc, 0, @PieceCount, @AppUserId, @TerminalLocationId, SYSUTCDATETIME());
        SET @NewId = SCOPE_IDENTITY();
        INSERT INTO Lots.LotStatusHistory (LotId, OldStatusId, NewStatusId, Reason, ChangedByUserId, TerminalLocationId, ChangedAt)
        VALUES (@NewId, NULL, @GoodStatusId, N'SubAssembly LOT minted at Machining OUT (FIFO).', @AppUserId, @TerminalLocationId, SYSUTCDATETIME());
        INSERT INTO Lots.LotGenealogyClosure (AncestorLotId, DescendantLotId, Depth) VALUES (@NewId, @NewId, 0);
        INSERT INTO Lots.LotMovement (LotId, FromLocationId, ToLocationId, MovedByUserId, TerminalLocationId, MovedAt)
        VALUES (@NewId, NULL, @SrcLoc, @AppUserId, @TerminalLocationId, SYSUTCDATETIME());

        -- FIFO walk: consume oldest-first, bounded per casting by lock-fresh availability.
        DECLARE @Need INT = @Consumed, @i INT = 1, @n INT = (SELECT ISNULL(MAX(Ord),0) FROM @Queue);
        DECLARE @cLot BIGINT, @cAvail INT, @cPc INT, @cStatus BIGINT, @take INT;
        WHILE @i <= @n AND @Need > 0
        BEGIN
            SELECT @cLot = LotId FROM @Queue WHERE Ord=@i;
            SELECT @cAvail=l.InventoryAvailable, @cPc=l.PieceCount, @cStatus=l.LotStatusId
            FROM Lots.Lot l WITH (UPDLOCK, HOLDLOCK) WHERE l.Id=@cLot;
            IF @cStatus <> @GoodStatusId OR @cAvail <= 0 BEGIN SET @i=@i+1; CONTINUE; END
            SET @take = CASE WHEN @Need < @cAvail THEN @Need ELSE @cAvail END;
            UPDATE Lots.Lot SET PieceCount=PieceCount-@take, InventoryAvailable=InventoryAvailable-@take, UpdatedAt=SYSUTCDATETIME(), UpdatedByUserId=@AppUserId WHERE Id=@cLot;
            IF (@cPc - @take) = 0
            BEGIN
                UPDATE Lots.Lot SET LotStatusId=@ClosedStatusId WHERE Id=@cLot;
                INSERT INTO Lots.LotStatusHistory (LotId, OldStatusId, NewStatusId, Reason, ChangedByUserId, TerminalLocationId, ChangedAt)
                VALUES (@cLot, @GoodStatusId, @ClosedStatusId, N'Closed by Machining OUT mint (fully consumed).', @AppUserId, @TerminalLocationId, SYSUTCDATETIME());
            END
            INSERT INTO Workorder.ProductionEvent (LotId, OperationTemplateId, WorkOrderOperationId, EventAt, ShotCount, ScrapCount, ScrapSourceId, WeightValue, WeightUomId, AppUserId, TerminalLocationId, Remarks)
            VALUES (@cLot, @OperationTemplateId, NULL, SYSUTCDATETIME(), @take, NULL, NULL, NULL, NULL, @AppUserId, @TerminalLocationId, NULL);
            INSERT INTO Workorder.ConsumptionEvent (SourceLotId, ProducedLotId, ProducedContainerId, ConsumedItemId, ProducedItemId, PieceCount, LocationId, AppUserId, TerminalLocationId, TrayId, ConsumedAt)
            VALUES (@cLot, @NewId, NULL, @SrcItem, @ProducedItemId, @take, @SrcLoc, @AppUserId, @TerminalLocationId, NULL, SYSUTCDATETIME());
            INSERT INTO Lots.LotGenealogy (ParentLotId, ChildLotId, RelationshipTypeId, PieceCount, EventUserId, TerminalLocationId)
            VALUES (@cLot, @NewId, 3, @take, @AppUserId, @TerminalLocationId);
            INSERT INTO Lots.LotGenealogyClosure (AncestorLotId, DescendantLotId, Depth)
            SELECT c.AncestorLotId, @NewId, c.Depth+1 FROM Lots.LotGenealogyClosure c
            WHERE c.DescendantLotId=@cLot AND NOT EXISTS (SELECT 1 FROM Lots.LotGenealogyClosure x WHERE x.AncestorLotId=c.AncestorLotId AND x.DescendantLotId=@NewId);
            SET @Need = @Need - @take;
            SET @i = @i + 1;
        END
        IF @Need > 0 RAISERROR(N'FIFO queue was consumed by a concurrent mint mid-operation; reload and retry.',16,1);

        -- Audit (subject = minted LOT; source castings summarized).
        SET @Activity = Audit.ufn_TruncateActivity(@MintedName+N' '+Audit.ufn_MidDot()+N' Machining OUT '+Audit.ufn_MidDot()
            +N' Minted '+@ProducedPn+N' ('+CAST(@PieceCount AS NVARCHAR(10))+N' pcs, consumed '+CAST(@Consumed AS NVARCHAR(10))+N' from '+CAST(@n AS NVARCHAR(10))+N' casting(s))');
        SET @NewValue = (SELECT @NewId AS MintedLotId, @MintedName AS MintedLotName, @PieceCount AS MintedPieceCount, @Consumed AS ConsumedPieceCount,
            JSON_QUERY((SELECT i.Id, i.PartNumber AS Code, i.Description AS Name FROM Parts.Item i WHERE i.Id=@ProducedItemId FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)) AS ProducedItem
            FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);
        EXEC Audit.Audit_LogOperation @AppUserId=@AppUserId, @TerminalLocationId=@TerminalLocationId, @LocationId=@SrcLoc,
            @LogEntityTypeCode=N'Lot', @EntityId=@NewId, @LogEventTypeCode=N'MachiningOutCompleted', @LogSeverityCode=N'Info',
            @Description=@Activity, @OldValue=NULL, @NewValue=@NewValue;
        COMMIT TRANSACTION;
        SET @Status=1; SET @Message=N'Minted '+@ProducedPn+N' LOT '+@MintedName+N' ('+CAST(@PieceCount AS NVARCHAR(10))+N' pcs).';
        GOTO Reply;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT>0 ROLLBACK TRANSACTION;
        DECLARE @ErrMsg NVARCHAR(4000)=ERROR_MESSAGE(), @ErrSev INT=ERROR_SEVERITY(), @ErrState INT=ERROR_STATE();
        SET @Status=0; SET @NewId=NULL; SET @Message=N'Unexpected error: '+LEFT(@ErrMsg,400);
        BEGIN TRY EXEC Audit.Audit_LogFailure @AppUserId=@AppUserId, @LogEntityTypeCode=N'Lot', @EntityId=@SourceLotId, @LogEventTypeCode=N'MachiningOutCompleted', @FailureReason=@Message, @ProcedureName=@ProcName, @AttemptedParameters=@Params; END TRY BEGIN CATCH END CATCH
        SELECT @Status AS Status, @Message AS Message, @NewId AS NewId, @Available AS Available; RAISERROR(@ErrMsg,@ErrSev,@ErrState); RETURN;
    END CATCH
Reply:
    SELECT @Status AS Status, @Message AS Message, @NewId AS NewId, @Available AS Available;
END;
GO
```

- [ ] **Step 4: Fix the existing 070 INSERT-EXEC captures for the 4th column**

The existing `070` tests capture the mint into 3-column temp tables (`@m`, `#C2`-derived). Update every `Workorder.MachiningOut_Mint` capture in this file to a 4-column shape. Find each `DECLARE @m TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);` (and any similar) and add `, Available INT`. There are captures at the "Mint 10 (partial)", "Mint the remaining 14", and "Over-mint rejected" blocks — add `Available INT` to each.

- [ ] **Step 5: Run to verify all machining tests pass**

Run: `.\Run-Tests.ps1 -DatabaseName "MPP_MES_Test"`
Expected: PASS — the new `[FIFO]`/`[Shortfall]`/`[Partial]` assertions pass; the pre-existing `[MoMint]` scenarios still pass; ZERO new failures vs the documented baseline (the `[MachIn]/[Rework]` cluster + `077` + `0022` throwers are unchanged).

- [ ] **Step 6: Commit**

```bash
git add sql/migrations/repeatable/R__Workorder_MachiningOut_Mint.sql sql/tests/0027_PlantFloor_Machining/070_MachiningOut_Mint.sql
git commit -m "feat(sql): MachiningOut_Mint multi-source FIFO consume - oldest-first, no-negative, partial-on-shortfall, multi-parent genealogy"
```

---

### Task 2: Thread `@AllowPartial` + the `Available` result through the Python wrapper + NQ

**Files:**
- Modify: `ignition/projects/Core/ignition/named-query/workorder/MachiningOut_Mint/query.sql`
- Modify: `ignition/projects/Core/ignition/named-query/workorder/MachiningOut_Mint/resource.json`
- Modify: `ignition/projects/Core/ignition/script-python/BlueRidge/Workorder/Machining/code.py`

**Interfaces:**
- Consumes: `Workorder.MachiningOut_Mint(..., @AllowPartial)` → `{Status, Message, NewId, Available}` (Task 1).
- Produces: `BlueRidge.Workorder.Machining.mint(sourceLotId, operationTemplateId, pieceCount, producedItemId=None, appUserId=None, terminalLocationId=None, allowPartial=False)` → returns `{Status, Message, NewId, Available}`; still auto-prints on success (reads `NewId`).

- [ ] **Step 1: Add `@AllowPartial` to the NQ query**

In `.../named-query/workorder/MachiningOut_Mint/query.sql`, add the param to the EXEC (append `, @AllowPartial = :allowPartial` to the parameter list — keep the existing params).

- [ ] **Step 2: Add the NQ param declaration**

In `.../named-query/workorder/MachiningOut_Mint/resource.json`, add to the `parameters` array: `{ "type": "Parameter", "identifier": "allowPartial", "sqlType": -7 }` (BIT). Keep the existing params.

- [ ] **Step 3: Thread `allowPartial` through the wrapper**

In `ignition/projects/Core/ignition/script-python/BlueRidge/Workorder/Machining/code.py`, update `mint(...)` to accept + pass `allowPartial` (add to the signature after `terminalLocationId=None` as `allowPartial=False`, and add `"allowPartial": bool(allowPartial),` to the `params` dict). The auto-print tail is unchanged (it reads `result.get("NewId")`, which is still present).

- [ ] **Step 4: Push + smoke**

Run: `.\scan.ps1`
Then, in the running app at a Machining-OUT terminal, mint within-queue (normal path unchanged) — confirm success + auto-print. (The shortfall path is exercised via the UI in Task 3.)

- [ ] **Step 5: Commit**

```bash
git add ignition/projects/Core/ignition/named-query/workorder/MachiningOut_Mint/query.sql ignition/projects/Core/ignition/named-query/workorder/MachiningOut_Mint/resource.json ignition/projects/Core/ignition/script-python/BlueRidge/Workorder/Machining/code.py
git commit -m "feat(ignition): MachiningOut mint wrapper/NQ thread @AllowPartial + Available result"
```

---

### Task 3: Machining-OUT view — shortfall confirm popup

**Files:**
- Modify (via Designer or careful file edit — this is an EXISTING view): the Machining-OUT view that calls `BlueRidge.Workorder.Machining.mint(...)` (locate with `grep -rl "Workorder.Machining.mint" ignition/projects/MPP/.../ShopFloor/`)

**Interfaces:**
- Consumes: `mint(..., allowPartial=...)` returning `{Status, Message, NewId, Available}` (Task 2).

- [ ] **Step 1: Locate the mint call + wrap the shortfall response**

Find the view's mint-submit customMethod. Change the result handling so that when `result.get("Status")` is falsy AND `result.get("Available")` is a positive number less than the requested pieceCount, instead of a plain error toast it opens a confirm popup:

```python
	avail = result.get("Available")
	if (not result.get("Status")) and avail and avail > 0:
		system.perspective.openPopup(
			id="mo-partial",
			view="BlueRidge/Components/Popups/ConfirmDestructive",
			modal=True, showCloseIcon=False,
			params={
				"title": "Not enough in the queue",
				"message": "Only %s available in the FIFO queue. Mint %s?" % (avail, avail),
				"confirmLabel": "Mint %s" % avail,
				"replyMessage": "moPartialConfirmed"
			})
		return
	BlueRidge.Common.Ui.notifyResult(result, successTitle="Machining OUT complete")
```

Add a page-scoped message handler `moPartialConfirmed` that, on `action == "confirm"`, re-calls `mint(...)` with `allowPartial=True` (same sourceLotId/pieceCount/etc.), then notifies the result. (Mirror the `itemDeprecateConfirmed` handler pattern in `Identity/view.json` for the popup reply wiring.)

- [ ] **Step 2: Push + verify in-app**

Run: `.\scan.ps1`
At a Machining-OUT terminal: request more than the queue holds → confirm the "Only N available — Mint N?" popup appears; tap **Mint N** → confirm a partial sub-assembly is minted and the queue drains; tap **Cancel** → nothing consumed.

- [ ] **Step 3: Commit**

```bash
git add <the machining-out view.json>
git commit -m "feat(ignition): Machining OUT shortfall confirm popup (mint available on confirm)"
```

---

### Task 4: Surgical data repair of `000000005` / `000000007`

**Files:**
- Create: `sql/scratch/repair_20260721_negative_castings.sql`

**Interfaces:** none (one-off repair against `MPP_MES_Dev`).

- [ ] **Step 1: Confirm the target state with Jacques FIRST**

These LOTs are `000000005` (12270-6NA, −6, 4 sublots `-01..-04`) and `000000007` (5G0-c, −2). The correct end state (which sublots are legitimate vs phantom, whether the castings should be Closed at 0 or restored to a positive count) is a judgment call. **Do not run any repair until Jacques confirms the intended state.** Capture his answer, then write the repair to match it.

- [ ] **Step 2: Write the guarded repair script**

Author `sql/scratch/repair_20260721_negative_castings.sql` (idempotent, `USE MPP_MES_Dev`, explicit LOT-name targeting, FK-safe delete order: `ConsumptionEvent`/`ProductionEvent`/`RejectEvent` → `LotEventLog`/`LotMovement`/`LotStatusHistory`/`LotGenealogy`/`LotGenealogyClosure` → `Lot`) implementing the confirmed target state — e.g. void phantom sublots + their genealogy and reset each casting to a non-negative count/status. Print before/after counts.

- [ ] **Step 3: Run against Dev + verify**

Run: `sqlcmd -S localhost -d MPP_MES_Dev -E -b -I -C -i sql/scratch/repair_20260721_negative_castings.sql`
Expected: no LOT has `PieceCount < 0`; `000000005`/`000000007` in the confirmed state.

- [ ] **Step 4: Commit**

```bash
git add sql/scratch/repair_20260721_negative_castings.sql
git commit -m "chore(sql): repair negative castings 000000005/000000007 (pre-FIFO-fix test artifacts)"
```

---

## Self-Review

**Spec coverage:**
- §2 behavior (strict oldest-first, roll-over, close-at-zero, one LOT, multi-parent, no-negative) → Task 1 proc + tests. ✓
- §3 proc (@SourceLotId FIFO handle, @AllowPartial, result +Available, FIFO set, per-casting consume, never-negative, INSERT-EXEC) → Task 1. ✓
- §3 blast radius (wrapper/NQ/tests/auto-print read 3-col) → Task 1 Step 4 (tests) + Task 2 (wrapper/NQ). ✓
- §4 UI shortfall popup → Task 3. ✓
- §5 traceability (per-casting ConsumptionEvent + genealogy edge + closure) → Task 1 proc + `[FIFO] 2 parents / 2 ConsumptionEvents` tests. ✓
- §6 scope (MachiningOut only; Assembly future) → not built (correct). ✓
- §7 verify-points (FIFO scoping = LastMovementAt arrival order; InventoryAvailable bound) → baked into Task 1 (arrival-ordered `@Queue`, InventoryAvailable-bounded draw). ✓
- §8 data repair → Task 4 (gated on Jacques's target-state confirmation). ✓
- §9 tests → Task 1 Steps 1/4. ✓

**Placeholder scan:** No TBDs in code steps. Task 3's "locate the view" is a concrete `grep` (the machining-out view path isn't pre-known); Task 4's target state is a genuine human decision, explicitly gated. Not placeholders.

**Type consistency:** `mint(..., allowPartial=False)` (Task 2) matches the proc's `@AllowPartial BIT=0` (Task 1) and the popup re-call `allowPartial=True` (Task 3). Result keys `Status/Message/NewId/Available` consistent across proc, wrapper, tests, UI. `@Available` = `floor(totalAvail/QtyPer)` consistent.

## Revision History

| Date | Change | Author |
|---|---|---|
| 2026-07-21 | Initial plan (4 tasks) from the 2026-07-21 FIFO consume design. | Blue Ridge Automation |
