# Terminal Mint Model — Plan 2: Mint Behavior & Route Validation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn Machining OUT into a consume-mint (mint a SubAssembly LOT by consuming the casting, `Consumption` genealogy, flexible operator quantity), add a ranked finished-good default for Assembly OUT, enforce route-legality at publish, scope the sublot framework to exception-only, and rebuild the demo seed on the mint model.

**Architecture:** A mint terminal creates a new part-number LOT by consuming input(s) per the produced part's BOM, at the line (line-resident, no destination move). The produced part is *derived* (BOM child→parent + line-eligibility), operator-overridable. Everything mirrors the established INSERT-EXEC-safe inline-mutation pattern (`R__Workorder_Assembly_CompleteTray.sql`).

**Tech Stack:** SQL Server 2022 T-SQL, repeatable `R__` procs, `Run-Tests`/`Reset-DevDatabase`, `sqlcmd`.

**Design source:** `docs/superpowers/specs/2026-07-07-terminal-mint-model-and-rename-bom-removal-design.md` — §3.4 mint derivation, §3.5 flexible qty, §3.6 `Consumption`-only, §3.8 line-resident, §3.10 mint-step placement, §4.2 route-legality (option C), §5 B3/B5/B8/B9.

**Depends on:** **Plan 1 must be landed first** — this plan consumes `Parts.OperationRoleKind` (Task 2 there) and the route-driven queue (Task 4 there). The role-kind is `Advance`/`OriginMint`/`ConsumeMint`.

## Global Constraints

- **Branch** `jacques/working`; confirm before commit; explicit path staging; no `Co-Authored-By` trailer.
- **SQL conventions** as Plan 1 (UpperCamelCase, BIGINT IDENTITY PK, NVARCHAR, DATETIME2(3), `SYSUTCDATETIME()`, ET display via `AT TIME ZONE`, code-table FKs, append-only, `DeprecatedAt`).
- **JDBC (FDS-11-011):** no OUTPUT params. Mutation procs end every exit path with `SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;`. `RAISERROR` (not `THROW`) in CATCH.
- **INSERT-EXEC rule (CLAUDE.md):** a status-row proc captured via INSERT-EXEC must NOT `EXEC` another status-row proc and must NOT `ROLLBACK` inside an open caller txn. **Inline** each sub-mutation (mint / consume) as a commented mirror of its source-of-truth proc; run **all rejecting validations before `BEGIN TRANSACTION`**; the CATCH is the only legal ROLLBACK site. Reference impl: `R__Workorder_Assembly_CompleteTray.sql`.
- **ASCII-only** strings; natural-key resolution.
- **Run-Tests** green after every task; reset with `.\Reset-DevDatabase.ps1 -SkipDemoSeed` (then apply `030_seed_jp_validation.sql` when a test needs the fixture).

---

### Task 1: Machining OUT → consume-mint (`MachiningOut_Mint`)

Replace the split proc with a consume-mint: mint a SubAssembly LOT of the operator quantity, consume that quantity from the casting per the SubAssembly's BOM, write `Consumption` genealogy, decrement the casting (close at zero). Derive the produced part; allow an operator override.

**Files:**
- Create: `sql/migrations/repeatable/R__Workorder_MachiningOut_Mint.sql`
- Delete: `sql/migrations/repeatable/R__Workorder_MachiningOut_RecordSplit.sql`
- Rewrite: `sql/tests/0027_PlantFloor_Machining/070_MachiningOut_RecordSplit.sql` → `070_MachiningOut_Mint.sql`; delete `075_MachiningOut_RecordSplit_same_destination.sql`, `080_MachiningOut_RecordSplit_validation.sql` (their scenarios fold into the new 070/080)
- Reference (mirror): `sql/migrations/repeatable/R__Workorder_Assembly_CompleteTray.sql` (inline IdentifierSequence mint B1, inline consume + `Consumption` edge B4)

**Interfaces:**
- Consumes: `Parts.OperationRoleKind` (Plan 1), `Parts.v_EffectiveItemLocation`, `Location.ufn_AncestorLocationIds`, `Lots.IdentifierSequence`.
- Produces: `Workorder.MachiningOut_Mint(@SourceLotId BIGINT, @OperationTemplateId BIGINT, @PieceCount INT, @ProducedItemId BIGINT = NULL, @AppUserId BIGINT, @TerminalLocationId BIGINT = NULL)` → `(Status, Message, NewId)` where `NewId` = the minted SubAssembly `Lot.Id`.

- [ ] **Step 1: Write the failing test (`070_MachiningOut_Mint.sql`)**

Create `sql/tests/0027_PlantFloor_Machining/070_MachiningOut_Mint.sql`:

```sql
-- MachiningOut_Mint: mints a SubAssembly LOT by consuming the casting;
-- Consumption genealogy; casting decrements and stays open on a partial mint.
SET NOCOUNT ON;
DECLARE @U BIGINT=(SELECT Id FROM Location.AppUser WHERE Initials=N'DEV');
-- Fixture: a casting Item with a SubAssembly whose 1-line BOM consumes it, the SubAssembly
-- direct-eligible at a line. Use the JP validation parts (run 030_seed_jp_validation first)
-- OR the demo parts. Resolve by natural key:
DECLARE @Casting BIGINT=(SELECT Id FROM Parts.Item WHERE PartNumber=N'6MA-C');
DECLARE @Machined BIGINT=(SELECT Id FROM Parts.Item WHERE PartNumber=N'6MA-M');
DECLARE @Line BIGINT=(SELECT Id FROM Location.Location WHERE Code=N'MA1-FPRPY');
DECLARE @Origin BIGINT=(SELECT Id FROM Lots.LotOriginType WHERE Code=N'Manufactured');
DECLARE @MoTpl BIGINT=(SELECT Id FROM Parts.OperationTemplate WHERE Code=N'MachiningOut');
IF @Casting IS NULL OR @Machined IS NULL RAISERROR('Fixture: 6MA-C/6MA-M required.',16,1);
-- Mint a 24-pc casting at the line:
DECLARE @r TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT, MintedLotName NVARCHAR(50));
INSERT INTO @r EXEC Lots.Lot_Create @ItemId=@Casting, @LotOriginTypeId=@Origin, @CurrentLocationId=@Line, @PieceCount=24, @AppUserId=@U;
DECLARE @CastLot BIGINT=(SELECT NewId FROM @r);
-- Mint 10 machined parts (partial): casting -> 14 remaining, machined LOT of 10 born at the line.
DECLARE @m TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO @m EXEC Workorder.MachiningOut_Mint @SourceLotId=@CastLot, @OperationTemplateId=@MoTpl, @PieceCount=10, @AppUserId=@U, @TerminalLocationId=@Line;
IF (SELECT Status FROM @m) <> 1 RAISERROR('Mint should succeed.',16,1);
DECLARE @MachLot BIGINT=(SELECT NewId FROM @m);
-- Assertions:
IF (SELECT ItemId FROM Lots.Lot WHERE Id=@MachLot) <> @Machined RAISERROR('Minted LOT must be the SubAssembly item.',16,1);
IF (SELECT PieceCount FROM Lots.Lot WHERE Id=@MachLot) <> 10 RAISERROR('Minted LOT should be 10 pcs.',16,1);
IF (SELECT CurrentLocationId FROM Lots.Lot WHERE Id=@MachLot) <> @Line RAISERROR('Minted LOT must be line-resident.',16,1);
IF (SELECT PieceCount FROM Lots.Lot WHERE Id=@CastLot) <> 14 RAISERROR('Casting should decrement to 14.',16,1);
IF (SELECT sc.Code FROM Lots.Lot l JOIN Lots.LotStatusCode sc ON sc.Id=l.LotStatusId WHERE l.Id=@CastLot) = N'Closed' RAISERROR('Casting must stay OPEN on partial mint.',16,1);
-- Consumption genealogy (RelationshipTypeId=3), NOT Split(1):
IF NOT EXISTS (SELECT 1 FROM Lots.LotGenealogy WHERE ParentLotId=@CastLot AND ChildLotId=@MachLot AND RelationshipTypeId=3) RAISERROR('Expected a Consumption edge casting->machined.',16,1);
IF EXISTS (SELECT 1 FROM Lots.LotGenealogy WHERE ChildLotId=@MachLot AND RelationshipTypeId=1) RAISERROR('Must NOT write a Split edge.',16,1);
-- ConsumptionEvent recorded:
IF NOT EXISTS (SELECT 1 FROM Workorder.ConsumptionEvent WHERE SourceLotId=@CastLot AND ProducedLotId=@MachLot AND ConsumedItemId=@Casting AND ProducedItemId=@Machined AND PieceCount=10) RAISERROR('Expected ConsumptionEvent 10 casting->machined.',16,1);
-- Mint the remaining 14 -> casting closes:
DELETE FROM @m; INSERT INTO @m EXEC Workorder.MachiningOut_Mint @SourceLotId=@CastLot, @OperationTemplateId=@MoTpl, @PieceCount=14, @AppUserId=@U, @TerminalLocationId=@Line;
IF (SELECT Status FROM @m) <> 1 RAISERROR('Second mint should succeed.',16,1);
IF (SELECT sc.Code FROM Lots.Lot l JOIN Lots.LotStatusCode sc ON sc.Id=l.LotStatusId WHERE l.Id=@CastLot) <> N'Closed' RAISERROR('Casting should Close when fully consumed.',16,1);
-- Over-mint rejected:
DELETE FROM @r; INSERT INTO @r EXEC Lots.Lot_Create @ItemId=@Casting, @LotOriginTypeId=@Origin, @CurrentLocationId=@Line, @PieceCount=5, @AppUserId=@U;
DECLARE @Small BIGINT=(SELECT NewId FROM @r);
DELETE FROM @m; INSERT INTO @m EXEC Workorder.MachiningOut_Mint @SourceLotId=@Small, @OperationTemplateId=@MoTpl, @PieceCount=99, @AppUserId=@U, @TerminalLocationId=@Line;
IF (SELECT Status FROM @m) <> 0 RAISERROR('Over-mint must be rejected.',16,1);
PRINT 'MachiningOut_Mint OK.';
-- (Teardown omitted for brevity: a full-suite reset precedes the next test file.)
```

- [ ] **Step 2: Run it to verify it fails**

Run: `powershell -File .\Reset-DevDatabase.ps1 -SkipDemoSeed; sqlcmd -S localhost -d MPP_MES_Dev -E -b -I -C -i sql/tests/0027_PlantFloor_Machining/070_MachiningOut_Mint.sql`
Expected: FAIL — `Could not find stored procedure 'Workorder.MachiningOut_Mint'`.

- [ ] **Step 3: Write the `MachiningOut_Mint` proc**

Create `sql/migrations/repeatable/R__Workorder_MachiningOut_Mint.sql`. Full proc (mirrors `Assembly_CompleteTray`'s inline mint B1 + inline consume B4; single source LOT, not FIFO):

```sql
-- ============================================================
-- Repeatable:  R__Workorder_MachiningOut_Mint.sql
-- Description: Machining OUT consume-mint (spec §3.4/§3.6/§3.8/§3.10). Mints a
--              SubAssembly LOT of @PieceCount at the source's line, consuming
--              @PieceCount x BOM.QtyPer from the casting (@SourceLotId), writing a
--              Consumption genealogy edge (RelationshipTypeId=3) + closure, a
--              Workorder.ConsumptionEvent, and a MachiningOut ProductionEvent on the
--              casting. The casting decrements and Closes only when fully consumed.
--              Produced part is derived (published BOM whose child = casting item AND
--              parent direct-eligible at the line); @ProducedItemId overrides. Flexible
--              qty (input size irrelevant). No destination (line-resident). INSERT-EXEC
--              safe: all rejects pre-txn; inline sub-mutations; CATCH is the only ROLLBACK.
-- ============================================================
CREATE OR ALTER PROCEDURE Workorder.MachiningOut_Mint
    @SourceLotId         BIGINT,
    @OperationTemplateId BIGINT,
    @PieceCount          INT,
    @ProducedItemId      BIGINT = NULL,
    @AppUserId           BIGINT,
    @TerminalLocationId  BIGINT = NULL
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;
    DECLARE @Status BIT = 0, @Message NVARCHAR(500) = N'Unknown error', @NewId BIGINT = NULL;
    DECLARE @ProcName NVARCHAR(200) = N'Workorder.MachiningOut_Mint';
    DECLARE @Params NVARCHAR(MAX) = (SELECT @SourceLotId AS SourceLotId, @OperationTemplateId AS OperationTemplateId,
        @PieceCount AS PieceCount, @ProducedItemId AS ProducedItemId, @AppUserId AS AppUserId, @TerminalLocationId AS TerminalLocationId
        FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);
    DECLARE @GoodStatusId BIGINT = (SELECT Id FROM Lots.LotStatusCode WHERE Code=N'Good');
    DECLARE @ClosedStatusId BIGINT = (SELECT Id FROM Lots.LotStatusCode WHERE Code=N'Closed');
    DECLARE @ManufacturedOriginId BIGINT = (SELECT Id FROM Lots.LotOriginType WHERE Code=N'Manufactured');
    DECLARE @SrcItem BIGINT, @SrcAvail INT, @SrcPc INT, @SrcStatus BIGINT, @SrcLoc BIGINT, @SrcName NVARCHAR(50), @Blocks BIT, @SrcStatusCode NVARCHAR(20);
    DECLARE @BomId BIGINT, @QtyPer DECIMAL(18,4), @Consumed INT, @CandCount INT;
    DECLARE @MintedName NVARCHAR(50), @SeqLast BIGINT, @SeqEnd BIGINT, @SeqFormat NVARCHAR(50), @SeqPrefix NVARCHAR(50), @SeqPad INT;
    DECLARE @ProducedPn NVARCHAR(50), @CellCode NVARCHAR(50), @Activity NVARCHAR(500), @NewValue NVARCHAR(MAX);

    BEGIN TRY
        -- ===== Pre-transaction validations (no open txn) =====
        IF @SourceLotId IS NULL OR @OperationTemplateId IS NULL OR @PieceCount IS NULL OR @AppUserId IS NULL
        BEGIN SET @Message=N'Required parameter missing.';
            IF @AppUserId IS NOT NULL EXEC Audit.Audit_LogFailure @AppUserId=@AppUserId, @LogEntityTypeCode=N'Lot', @EntityId=@SourceLotId, @LogEventTypeCode=N'MachiningOutCompleted', @FailureReason=@Message, @ProcedureName=@ProcName, @AttemptedParameters=@Params;
            GOTO Reply; END
        IF @PieceCount <= 0 BEGIN SET @Message=N'PieceCount must be positive.';
            EXEC Audit.Audit_LogFailure @AppUserId=@AppUserId, @LogEntityTypeCode=N'Lot', @EntityId=@SourceLotId, @LogEventTypeCode=N'MachiningOutCompleted', @FailureReason=@Message, @ProcedureName=@ProcName, @AttemptedParameters=@Params; GOTO Reply; END
        -- OperationTemplate exists + is a ConsumeMint role (this proc executes consume-mints only).
        IF NOT EXISTS (SELECT 1 FROM Parts.OperationTemplate ot JOIN Parts.OperationType oty ON oty.Id=ot.OperationTypeId
                       JOIN Parts.OperationRoleKind rk ON rk.Id=oty.OperationRoleKindId
                       WHERE ot.Id=@OperationTemplateId AND ot.DeprecatedAt IS NULL AND rk.Code=N'ConsumeMint')
        BEGIN SET @Message=N'OperationTemplate not found, deprecated, or not a consume-mint role.';
            EXEC Audit.Audit_LogFailure @AppUserId=@AppUserId, @LogEntityTypeCode=N'Lot', @EntityId=@SourceLotId, @LogEventTypeCode=N'MachiningOutCompleted', @FailureReason=@Message, @ProcedureName=@ProcName, @AttemptedParameters=@Params; GOTO Reply; END
        -- Source LOT read + not-blocked/open guard.
        SELECT @SrcItem=l.ItemId, @SrcAvail=l.InventoryAvailable, @SrcPc=l.PieceCount, @SrcStatus=l.LotStatusId,
               @SrcLoc=l.CurrentLocationId, @SrcName=l.LotName, @Blocks=sc.BlocksProduction, @SrcStatusCode=sc.Code
        FROM Lots.Lot l JOIN Lots.LotStatusCode sc ON sc.Id=l.LotStatusId WHERE l.Id=@SourceLotId;
        IF @SrcItem IS NULL BEGIN SET @Message=N'Source LOT not found.';
            EXEC Audit.Audit_LogFailure @AppUserId=@AppUserId, @LogEntityTypeCode=N'Lot', @EntityId=@SourceLotId, @LogEventTypeCode=N'MachiningOutCompleted', @FailureReason=@Message, @ProcedureName=@ProcName, @AttemptedParameters=@Params; GOTO Reply; END
        IF @Blocks=1 OR @SrcStatusCode=N'Closed' BEGIN SET @Message=N'Source LOT is '+@SrcStatusCode+N' and cannot be consumed.';
            EXEC Audit.Audit_LogFailure @AppUserId=@AppUserId, @LogEntityTypeCode=N'Lot', @EntityId=@SourceLotId, @LogEventTypeCode=N'MachiningOutCompleted', @FailureReason=@Message, @ProcedureName=@ProcName, @AttemptedParameters=@Params; GOTO Reply; END
        -- Derive/validate the produced part: published BOM whose child = source item AND parent direct-eligible at the line.
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
        -- Resolve produced part's active BOM + the QtyPer of the source component.
        SET @BomId = (SELECT TOP 1 Id FROM Parts.Bom WHERE ParentItemId=@ProducedItemId AND PublishedAt IS NOT NULL AND DeprecatedAt IS NULL ORDER BY VersionNumber DESC);
        SET @QtyPer = (SELECT QtyPer FROM Parts.BomLine WHERE BomId=@BomId AND ChildItemId=@SrcItem);
        IF @BomId IS NULL OR @QtyPer IS NULL BEGIN SET @Message=N'Produced part has no active BOM consuming this component.';
            EXEC Audit.Audit_LogFailure @AppUserId=@AppUserId, @LogEntityTypeCode=N'Lot', @EntityId=@SourceLotId, @LogEventTypeCode=N'MachiningOutCompleted', @FailureReason=@Message, @ProcedureName=@ProcName, @AttemptedParameters=@Params; GOTO Reply; END
        SET @Consumed = CAST(@QtyPer * @PieceCount AS INT);
        IF @Consumed > @SrcAvail BEGIN SET @Message=N'Requested mint consumes '+CAST(@Consumed AS NVARCHAR(20))+N' but only '+CAST(@SrcAvail AS NVARCHAR(20))+N' available on the source LOT.';
            EXEC Audit.Audit_LogFailure @AppUserId=@AppUserId, @LogEntityTypeCode=N'Lot', @EntityId=@SourceLotId, @LogEventTypeCode=N'MachiningOutCompleted', @FailureReason=@Message, @ProcedureName=@ProcName, @AttemptedParameters=@Params; GOTO Reply; END
        SET @ProducedPn = (SELECT PartNumber FROM Parts.Item WHERE Id=@ProducedItemId);
        SET @CellCode   = (SELECT Code FROM Location.Location WHERE Id=@SrcLoc);

        -- ===== Mutation (atomic) =====
        BEGIN TRANSACTION;
        -- B1. Mint the SubAssembly LOT (mirror R__Lots_Lot_Create inline IdentifierSequence 'Lot').
        SELECT @SeqLast=s.LastValue+1, @SeqEnd=s.EndingValue, @SeqFormat=s.FormatString FROM Lots.IdentifierSequence s WITH (ROWLOCK,UPDLOCK,HOLDLOCK) WHERE s.Code=N'Lot';
        IF @SeqLast IS NULL RAISERROR(N'Identifier sequence ''Lot'' not configured.',16,1);
        IF @SeqLast > @SeqEnd RAISERROR(N'Identifier sequence ''Lot'' exhausted.',16,1);
        UPDATE Lots.IdentifierSequence SET LastValue=@SeqLast, UpdatedAt=SYSUTCDATETIME() WHERE Code=N'Lot';
        SET @SeqPrefix = CASE WHEN CHARINDEX(N'{',@SeqFormat)>0 THEN LEFT(@SeqFormat,CHARINDEX(N'{',@SeqFormat)-1) ELSE @SeqFormat END;
        SET @SeqPad = TRY_CAST(SUBSTRING(@SeqFormat, CHARINDEX(N'D',@SeqFormat,CHARINDEX(N'{',@SeqFormat))+1,
                          CHARINDEX(N'}',@SeqFormat,CHARINDEX(N'{',@SeqFormat))-CHARINDEX(N'D',@SeqFormat,CHARINDEX(N'{',@SeqFormat))-1) AS INT);
        SET @MintedName = CASE WHEN @SeqPad IS NULL OR @SeqPad<1 THEN @SeqPrefix+CAST(@SeqLast AS NVARCHAR(20))
                               ELSE @SeqPrefix+RIGHT(REPLICATE(N'0',@SeqPad)+CAST(@SeqLast AS NVARCHAR(20)),@SeqPad) END;
        INSERT INTO Lots.Lot (LotName, ItemId, LotOriginTypeId, LotStatusId, PieceCount, MaxPieceCount,
            Weight, WeightUomId, ToolId, ToolCavityId, CavityNumber, VendorLotNumber, MinSerialNumber, MaxSerialNumber,
            CurrentLocationId, TotalInProcess, InventoryAvailable, CreatedByUserId, CreatedAtTerminalId, CreatedAt)
        VALUES (@MintedName, @ProducedItemId, @ManufacturedOriginId, @GoodStatusId, @PieceCount, (SELECT MaxLotSize FROM Parts.Item WHERE Id=@ProducedItemId),
            NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL,
            @SrcLoc, 0, @PieceCount, @AppUserId, @TerminalLocationId, SYSUTCDATETIME());
        SET @NewId = SCOPE_IDENTITY();
        INSERT INTO Lots.LotStatusHistory (LotId, OldStatusId, NewStatusId, Reason, ChangedByUserId, TerminalLocationId, ChangedAt)
        VALUES (@NewId, NULL, @GoodStatusId, N'SubAssembly LOT minted at Machining OUT.', @AppUserId, @TerminalLocationId, SYSUTCDATETIME());
        INSERT INTO Lots.LotGenealogyClosure (AncestorLotId, DescendantLotId, Depth) VALUES (@NewId, @NewId, 0);
        INSERT INTO Lots.LotMovement (LotId, FromLocationId, ToLocationId, MovedByUserId, TerminalLocationId, MovedAt)
        VALUES (@NewId, NULL, @SrcLoc, @AppUserId, @TerminalLocationId, SYSUTCDATETIME());
        -- B2. MachiningOut ProductionEvent on the casting (checkpoint; ShotCount = pieces produced this mint).
        INSERT INTO Workorder.ProductionEvent (LotId, OperationTemplateId, WorkOrderOperationId, EventAt, ShotCount, ScrapCount, AppUserId, TerminalLocationId)
        VALUES (@SourceLotId, @OperationTemplateId, NULL, SYSUTCDATETIME(), @PieceCount, NULL, @AppUserId, @TerminalLocationId);
        -- B3. Consume @Consumed from the casting; close at zero (mirror Assembly_CompleteTray B4 single-source).
        UPDATE Lots.Lot SET PieceCount=PieceCount-@Consumed, InventoryAvailable=InventoryAvailable-@Consumed, UpdatedAt=SYSUTCDATETIME(), UpdatedByUserId=@AppUserId WHERE Id=@SourceLotId;
        IF (@SrcPc - @Consumed) = 0
        BEGIN
            UPDATE Lots.Lot SET LotStatusId=@ClosedStatusId WHERE Id=@SourceLotId;
            INSERT INTO Lots.LotStatusHistory (LotId, OldStatusId, NewStatusId, Reason, ChangedByUserId, TerminalLocationId, ChangedAt)
            VALUES (@SourceLotId, @SrcStatus, @ClosedStatusId, N'Closed by Machining OUT mint (all pieces consumed).', @AppUserId, @TerminalLocationId, SYSUTCDATETIME());
        END
        -- B4. ConsumptionEvent + Consumption genealogy edge (RelationshipTypeId=3) + closure ancestors -> minted LOT.
        INSERT INTO Workorder.ConsumptionEvent (SourceLotId, ProducedLotId, ProducedContainerId, ConsumedItemId, ProducedItemId, PieceCount, LocationId, AppUserId, TerminalLocationId, TrayId, ConsumedAt)
        VALUES (@SourceLotId, @NewId, NULL, @SrcItem, @ProducedItemId, @Consumed, @SrcLoc, @AppUserId, @TerminalLocationId, NULL, SYSUTCDATETIME());
        INSERT INTO Lots.LotGenealogy (ParentLotId, ChildLotId, RelationshipTypeId, PieceCount, EventUserId, TerminalLocationId)
        VALUES (@SourceLotId, @NewId, 3, @Consumed, @AppUserId, @TerminalLocationId);
        INSERT INTO Lots.LotGenealogyClosure (AncestorLotId, DescendantLotId, Depth)
        SELECT c.AncestorLotId, @NewId, c.Depth+1 FROM Lots.LotGenealogyClosure c
        WHERE c.DescendantLotId=@SourceLotId
          AND NOT EXISTS (SELECT 1 FROM Lots.LotGenealogyClosure x WHERE x.AncestorLotId=c.AncestorLotId AND x.DescendantLotId=@NewId);
        -- B5. Audit (subject = casting; minted machined LOT in NewValue).
        SET @Activity = Audit.ufn_TruncateActivity(@SrcName+N' '+Audit.ufn_MidDot()+N' Machining OUT '+Audit.ufn_MidDot()
            +N' Minted '+@ProducedPn+N' LOT '+@MintedName+N' ('+CAST(@PieceCount AS NVARCHAR(10))+N' pcs, consumed '+CAST(@Consumed AS NVARCHAR(10))+N')');
        SET @NewValue = (SELECT @NewId AS MintedLotId, @MintedName AS MintedLotName, @PieceCount AS MintedPieceCount, @Consumed AS ConsumedPieceCount,
            JSON_QUERY((SELECT i.Id, i.PartNumber AS Code, i.Description AS Name FROM Parts.Item i WHERE i.Id=@ProducedItemId FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)) AS ProducedItem
            FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);
        EXEC Audit.Audit_LogOperation @AppUserId=@AppUserId, @TerminalLocationId=@TerminalLocationId, @LocationId=@SrcLoc,
            @LogEntityTypeCode=N'Lot', @EntityId=@SourceLotId, @LogEventTypeCode=N'MachiningOutCompleted', @LogSeverityCode=N'Info',
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
        SELECT @Status AS Status, @Message AS Message, @NewId AS NewId; RAISERROR(@ErrMsg,@ErrSev,@ErrState); RETURN;
    END CATCH
Reply:
    SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
END;
GO
```

> Implementer notes: confirm `Workorder.ProductionEvent` column list against B2 of `Assembly_CompleteTray` (this repo uses `EventAt`, `ShotCount`, `AppUserId`, `TerminalLocationId`). Confirm `LotGenealogy.RelationshipTypeId=3` is `Consumption` (`SELECT Id,Code FROM Lots.LotGenealogyRelationshipType`) — it is the value `Assembly_CompleteTray` uses. Confirm `MachiningOutCompleted` exists in `Audit.LogEventType` (seeded by `0027`).

- [ ] **Step 4: Delete the old split proc + its now-obsolete tests, run the new test**

```bash
git rm sql/migrations/repeatable/R__Workorder_MachiningOut_RecordSplit.sql \
       sql/tests/0027_PlantFloor_Machining/075_MachiningOut_RecordSplit_same_destination.sql \
       sql/tests/0027_PlantFloor_Machining/080_MachiningOut_RecordSplit_validation.sql
git rm sql/tests/0027_PlantFloor_Machining/070_MachiningOut_RecordSplit.sql
```
Then reset + run the new test (Step 2 command with `070_MachiningOut_Mint.sql`).
Expected: PASS — `MachiningOut_Mint OK.`

- [ ] **Step 5: Full suite green + commit**

Run: `powershell -File .\Reset-DevDatabase.ps1 -SkipDemoSeed; powershell -File .\Run-Tests.ps1`
Expected: exit 0. (The demo-seed rebuild that still calls `MachiningOut_RecordSplit` is fixed in Task 5; `Run-Tests` uses `-SkipDemoSeed`, so it does not run `seed_demo.sql` — but grep `grep -rn "MachiningOut_RecordSplit" sql/` and confirm only `seed_demo.sql` (Task 5) references remain.)

```bash
git add sql/migrations/repeatable/R__Workorder_MachiningOut_Mint.sql sql/tests/0027_PlantFloor_Machining/070_MachiningOut_Mint.sql
git commit -m "feat(workorder): Machining OUT consume-mint (Consumption genealogy); retire split"
```

---

### Task 2: Route-legality validation at publish (spec §4.2 option C)

Add the in-scope structural checks to `Parts.RouteTemplate_Publish` (the activation gate, alongside the existing zero-steps guard).

**Files:**
- Modify: `sql/migrations/repeatable/R__Parts_RouteTemplate_Publish.sql` (insert validations after the zero-steps guard, before the audit-narrative build / `BEGIN TRANSACTION`)
- Test: `sql/tests/0009_Parts_Process/032_RouteTemplate_Publish_legality.sql`

**Interfaces:**
- Consumes: `Parts.OperationRoleKind` (Plan 1), `Parts.ItemType`.
- Produces: `RouteTemplate_Publish` rejects (Status 0) an illegal route with a clear message; legal routes publish unchanged.

- [ ] **Step 1: Write the failing test**

Create `sql/tests/0009_Parts_Process/032_RouteTemplate_Publish_legality.sql` — build a Draft route on a non-FinishedGood part ending in an Advance step and assert publish is rejected; then make the last step a ConsumeMint and assert publish succeeds. (Mirror the fixture style of `030_RouteTemplate_SaveAll.sql` — create Item, `RouteTemplate_Create`, `RouteTemplate_SaveAll` with a steps JSON, then `RouteTemplate_Publish`.) Assertions:

```sql
SET NOCOUNT ON;
-- ... build a Draft route for a Component part whose only step is MachiningIn (Advance) ...
DECLARE @p TABLE (Status BIT, Message NVARCHAR(500));
DELETE FROM @p; INSERT INTO @p EXEC Parts.RouteTemplate_Publish @Id=@DraftId, @AppUserId=@U;
IF (SELECT Status FROM @p) <> 0 RAISERROR('Non-FG route ending on an Advance step must be rejected.',16,1);
IF (SELECT Message FROM @p) NOT LIKE N'%mint%' RAISERROR('Rejection message should mention the mint requirement.',16,1);
-- ... SaveAll a route [MachiningIn, MachiningOut] (ends ConsumeMint) ...
DELETE FROM @p; INSERT INTO @p EXEC Parts.RouteTemplate_Publish @Id=@DraftId2, @AppUserId=@U;
IF (SELECT Status FROM @p) <> 1 RAISERROR('Route ending in a ConsumeMint step should publish.',16,1);
-- ... a route with TWO ConsumeMint steps must be rejected ...
DELETE FROM @p; INSERT INTO @p EXEC Parts.RouteTemplate_Publish @Id=@DraftId3, @AppUserId=@U;
IF (SELECT Status FROM @p) <> 0 RAISERROR('Two consume-mint steps must be rejected.',16,1);
PRINT 'Route legality OK.';
```

- [ ] **Step 2: Run it to verify it fails**

Run: `powershell -File .\Reset-DevDatabase.ps1 -SkipDemoSeed; sqlcmd … -i sql/tests/0009_Parts_Process/032_RouteTemplate_Publish_legality.sql`
Expected: FAIL — the non-FG advance-terminated route currently publishes (Status 1).

- [ ] **Step 3: Insert the validations into `RouteTemplate_Publish`**

In `R__Parts_RouteTemplate_Publish.sql`, immediately after the zero-steps guard block (the `IF NOT EXISTS (SELECT 1 FROM Parts.RouteStep …)` that returns "Cannot publish: route has no steps.") and before the `-- ===== Audit narrative …` comment, insert:

```sql
        -- ===== Route-legality structural validation (spec §4.2 option C) =====
        DECLARE @ItemTypeCode NVARCHAR(20) = (
            SELECT it.Code FROM Parts.RouteTemplate rt
            JOIN Parts.Item i ON i.Id = rt.ItemId JOIN Parts.ItemType it ON it.Id = i.ItemTypeId WHERE rt.Id = @Id);
        DECLARE @Steps TABLE (SequenceNumber INT, KindCode NVARCHAR(20));
        INSERT INTO @Steps (SequenceNumber, KindCode)
        SELECT rs.SequenceNumber, rk.Code
        FROM Parts.RouteStep rs
        JOIN Parts.OperationTemplate ot ON ot.Id = rs.OperationTemplateId
        JOIN Parts.OperationType oty ON oty.Id = ot.OperationTypeId
        JOIN Parts.OperationRoleKind rk ON rk.Id = oty.OperationRoleKindId
        WHERE rs.RouteTemplateId = @Id;
        DECLARE @MaxSeq INT = (SELECT MAX(SequenceNumber) FROM @Steps);
        DECLARE @MinSeq INT = (SELECT MIN(SequenceNumber) FROM @Steps);
        DECLARE @LastKind NVARCHAR(20) = (SELECT KindCode FROM @Steps WHERE SequenceNumber = @MaxSeq);
        DECLARE @ConsumeCount INT = (SELECT COUNT(*) FROM @Steps WHERE KindCode = N'ConsumeMint');
        DECLARE @OriginMinSeq INT = (SELECT MIN(SequenceNumber) FROM @Steps WHERE KindCode = N'OriginMint');

        -- V1: a non-FinishedGood part must be consumed — its last step is a ConsumeMint.
        IF @ItemTypeCode <> N'FinishedGood' AND @LastKind <> N'ConsumeMint'
        BEGIN
            SET @Message = N'Route must end at a consume-mint step (Machining/Assembly OUT) for a '
                         + @ItemTypeCode + N' part; only a Finished Good may terminate without one.';
            EXEC Audit.Audit_LogFailure @AppUserId=@AppUserId, @LogEntityTypeCode=N'Route', @EntityId=@Id, @LogEventTypeCode=N'Updated', @FailureReason=@Message, @ProcedureName=@ProcName, @AttemptedParameters=@Params;
            SELECT @Status AS Status, @Message AS Message; RETURN;
        END
        -- V2: at most one consume-mint, and it must be the last step (a part is consumed once, at the end).
        IF @ConsumeCount > 1 OR (@ConsumeCount = 1 AND @LastKind <> N'ConsumeMint')
        BEGIN
            SET @Message = N'A route may contain at most one consume-mint step, and it must be the final step.';
            EXEC Audit.Audit_LogFailure @AppUserId=@AppUserId, @LogEntityTypeCode=N'Route', @EntityId=@Id, @LogEventTypeCode=N'Updated', @FailureReason=@Message, @ProcedureName=@ProcName, @AttemptedParameters=@Params;
            SELECT @Status AS Status, @Message AS Message; RETURN;
        END
        -- V3: an origin-mint (Die Cast), if present, must be the first step.
        IF @OriginMinSeq IS NOT NULL AND @OriginMinSeq <> @MinSeq
        BEGIN
            SET @Message = N'An origin-mint step (Die Cast) must be the first step of the route.';
            EXEC Audit.Audit_LogFailure @AppUserId=@AppUserId, @LogEntityTypeCode=N'Route', @EntityId=@Id, @LogEventTypeCode=N'Updated', @FailureReason=@Message, @ProcedureName=@ProcName, @AttemptedParameters=@Params;
            SELECT @Status AS Status, @Message AS Message; RETURN;
        END
```

Bump the proc header to v3.3 with a changelog line describing the legality checks.

- [ ] **Step 4: Run the test to verify it passes; full suite green**

Run the Step-2 chain, then `Run-Tests`.
Expected: PASS — `Route legality OK.`; suite exit 0. **Watch for fallout:** the JP validation routes (Task 1 of Plan 1) and demo routes must themselves be legal (end in a consume-mint for non-FG parts). If `030_seed_jp_validation.sql` or `seed_demo`/`020`-seeded routes now fail to publish, that is a *correct* catch — fix those routes to end in a consume-mint (or mark the part FinishedGood). Note any such fix in the seed.

- [ ] **Step 5: Commit**

```bash
git add sql/migrations/repeatable/R__Parts_RouteTemplate_Publish.sql sql/tests/0009_Parts_Process/032_RouteTemplate_Publish_legality.sql
git commit -m "feat(parts): route-legality validation at publish (mint-terminated, single consume-mint, origin-first)"
```

---

### Task 3: Ranked eligible-finished-good read for Assembly OUT (spec §5 B5)

**Files:**
- Create: `sql/migrations/repeatable/R__Parts_Item_ListEligibleFinishedGoodsRanked.sql`
- Test: `sql/tests/0028_PlantFloor_Assembly/096_Item_ListEligibleFinishedGoodsRanked.sql`

**Interfaces:**
- Produces: `Parts.Item_ListEligibleFinishedGoodsRanked(@LocationId BIGINT)` → `(Id, PartNumber, Description, LinesSatisfied, IsRecommended)`, ordered so the recommended FG (most BOM lines satisfiable by ready line inventory, FIFO tie-break) is first with `IsRecommended = 1`.

- [ ] **Step 1: Write the failing test**

Create `sql/tests/0028_PlantFloor_Assembly/096_Item_ListEligibleFinishedGoodsRanked.sql`: at a line eligible for one FG whose component is present, assert exactly one row `IsRecommended = 1` and it is that FG; with two eligible FGs and only one's component staged, assert the staged one ranks first.

```sql
SET NOCOUNT ON;
DECLARE @Line BIGINT=(SELECT Id FROM Location.Location WHERE Code=N'MA1-FPRPY-AFIN');
DECLARE @q TABLE (Id BIGINT, PartNumber NVARCHAR(50), Description NVARCHAR(500), LinesSatisfied INT, IsRecommended BIT);
INSERT INTO @q EXEC Parts.Item_ListEligibleFinishedGoodsRanked @LocationId=@Line;
IF (SELECT COUNT(*) FROM @q WHERE IsRecommended=1) <> 1 RAISERROR('Exactly one FG must be recommended.',16,1);
PRINT 'Ranked FG default OK.';
```
(Expand with a staged-component scenario mirroring `092_Assembly_CompleteTray.sql`'s fixture — mint a component LOT of the recommended FG's BOM child at the line, assert that FG sorts first.)

- [ ] **Step 2: Run it to verify it fails**

Run: reset + apply `030_seed_jp_validation.sql` + the test.
Expected: FAIL — `Could not find stored procedure 'Parts.Item_ListEligibleFinishedGoodsRanked'`.

- [ ] **Step 3: Write the proc**

Create `sql/migrations/repeatable/R__Parts_Item_ListEligibleFinishedGoodsRanked.sql`:

```sql
-- Ranked eligible finished goods for the Assembly OUT dropdown (spec decision 6/B5).
-- Eligible FinishedGood Items at @LocationId (direct/ancestor) that have an active BOM,
-- ranked by (# BOM lines satisfiable by ready line inventory DESC, earliest satisfying WIP ASC).
-- IsRecommended = 1 on the top row. Read proc; empty rowset = none eligible.
CREATE OR ALTER PROCEDURE Parts.Item_ListEligibleFinishedGoodsRanked
    @LocationId BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    ;WITH Elig AS (
        SELECT DISTINCT i.Id AS ItemId, i.PartNumber, i.Description
        FROM Parts.v_EffectiveItemLocation eil
        JOIN Parts.Item i     ON i.Id = eil.ItemId AND i.DeprecatedAt IS NULL
        JOIN Parts.ItemType it ON it.Id = i.ItemTypeId AND it.Code = N'FinishedGood'
        WHERE eil.LocationId IN (SELECT LocationId FROM Location.ufn_AncestorLocationIds(@LocationId))
          AND EXISTS (SELECT 1 FROM Parts.Bom b WHERE b.ParentItemId = i.Id AND b.PublishedAt IS NOT NULL AND b.DeprecatedAt IS NULL)
    ),
    ActiveBom AS (
        SELECT e.ItemId, (SELECT TOP 1 b.Id FROM Parts.Bom b WHERE b.ParentItemId = e.ItemId AND b.PublishedAt IS NOT NULL AND b.DeprecatedAt IS NULL ORDER BY b.VersionNumber DESC) AS BomId
        FROM Elig e
    ),
    LineSat AS (
        SELECT ab.ItemId, bl.ChildItemId, bl.QtyPer,
               ISNULL((SELECT SUM(l.InventoryAvailable) FROM Lots.Lot l JOIN Lots.LotStatusCode sc ON sc.Id=l.LotStatusId
                       WHERE l.ItemId=bl.ChildItemId AND l.CurrentLocationId=@LocationId AND sc.Code<>N'Closed'),0) AS Avail,
               (SELECT MIN(m.MovedAt) FROM Lots.Lot l JOIN Lots.LotStatusCode sc ON sc.Id=l.LotStatusId
                       JOIN Lots.LotMovement m ON m.LotId=l.Id
                       WHERE l.ItemId=bl.ChildItemId AND l.CurrentLocationId=@LocationId AND sc.Code<>N'Closed' AND l.InventoryAvailable>0) AS EarliestReady
        FROM ActiveBom ab JOIN Parts.BomLine bl ON bl.BomId = ab.BomId
    ),
    Agg AS (
        SELECT ItemId, SUM(CASE WHEN Avail >= QtyPer THEN 1 ELSE 0 END) AS LinesSatisfied, MIN(EarliestReady) AS EarliestReady
        FROM LineSat GROUP BY ItemId
    )
    SELECT e.ItemId AS Id, e.PartNumber, e.Description, ISNULL(a.LinesSatisfied,0) AS LinesSatisfied,
           CASE WHEN ROW_NUMBER() OVER (ORDER BY ISNULL(a.LinesSatisfied,0) DESC, a.EarliestReady ASC, e.PartNumber ASC) = 1 THEN 1 ELSE 0 END AS IsRecommended
    FROM Elig e LEFT JOIN Agg a ON a.ItemId = e.ItemId
    ORDER BY ISNULL(a.LinesSatisfied,0) DESC, a.EarliestReady ASC, e.PartNumber ASC;
END;
GO
```

> Implementer note: confirm `Parts.v_EffectiveItemLocation` surfaces the FG as eligible at the assembly cell in the JP/demo data; if only *direct* (non-BOM-derived) eligibility should qualify a produced FG, restrict via `Parts.ItemLocation` instead of the union view (verify the `IsConsumptionPoint` semantics before narrowing).

- [ ] **Step 4: Pass + commit**

Run the Step-2 chain (now PASS) then `Run-Tests` (exit 0).

```bash
git add sql/migrations/repeatable/R__Parts_Item_ListEligibleFinishedGoodsRanked.sql sql/tests/0028_PlantFloor_Assembly/096_Item_ListEligibleFinishedGoodsRanked.sql
git commit -m "feat(parts): ranked eligible-FG read for Assembly OUT default"
```

---

### Task 4: Scope the sublot framework to exception-only (spec §5 B8)

**Files:**
- Modify (header comment only): `sql/migrations/repeatable/R__Lots_Lot_Split.sql`
- Modify (header comment): `sql/tests/0021_PlantFloor_Lot_Lifecycle/020_Lot_Split.sql`

- [ ] **Step 1: Prove no standard M&A path calls `Lot_Split`**

Run: `grep -rn "Lot_Split\|RelationshipTypeId = 1\|RelationshipTypeId=1" sql/migrations sql/scratch`
Expected: after Task 1, the only `Split` (`RelationshipTypeId=1`) writers are `R__Lots_Lot_Split.sql` itself and `R__Lots_Lot_Merge.sql` (reverses a split); no Machining/Assembly proc. If any standard-path caller remains, it is a Task-1 miss — fix it. Record the grep output in the commit message.

- [ ] **Step 2: Document the exception-only status**

Add to the `R__Lots_Lot_Split.sql` header a line: `-- SCOPE (2026-07-07): EXCEPTION-ONLY. The standard M&A flow uses consume-mints`
`-- (MachiningOut_Mint / Assembly_CompleteTray, Consumption genealogy), NOT Split. Lot_Split`
`-- remains for same-part-number divisions with no identity change (quality dispositions, holds, logistics).`
Add the mirror note to `020_Lot_Split.sql`'s header.

- [ ] **Step 3: Commit**

```bash
git add sql/migrations/repeatable/R__Lots_Lot_Split.sql sql/tests/0021_PlantFloor_Lot_Lifecycle/020_Lot_Split.sql
git commit -m "docs(lots): mark Lot_Split exception-only (standard M&A path uses consume-mints)"
```

---

### Task 5: Rebuild the demo seed on the mint model (spec §5 B9)

**Files:**
- Modify: `sql/scratch/seed_demo.sql`

**Interfaces:**
- Consumes: `Workorder.MachiningOut_Mint` (Task 1).

- [ ] **Step 1: Replace the external machined-LOT mint + `RecordSplit` with `MachiningOut_Mint`**

In `seed_demo.sql`, for each 6MA thread (Thread A ~lines 293–309, Thread B ~lines 394–434) and the 5G0 thread (~lines 508–517): **delete** the block that (a) `Lot_Create`s the machined `6MA-M`/`5G0-M` LOT externally and (b) `EXEC Workorder.MachiningOut_RecordSplit`. **Replace** with a single `MachiningOut_Mint` call that consumes the (already RecordPick'd) casting LOT and mints the machined SubAssembly, capturing `NewId` as the machined LOT for the downstream assembly step. Concrete replacement for Thread A:

```sql
-- Machining OUT: mint the machined 6MA-M by consuming the cast LOT (Consumption
-- genealogy casting->machined; closes the "not genealogy-linked" gap in the old seed).
DECLARE @rMintA TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO @rMintA EXEC Workorder.MachiningOut_Mint @SourceLotId=@A_Cast, @OperationTemplateId=@OT_MachiningOut, @PieceCount=24, @AppUserId=@U, @TerminalLocationId=@L_FPRPY_MOUT;
IF (SELECT Status FROM @rMintA) <> 1 BEGIN SET @ErrMsg=N'6MA-A MachiningOut_Mint failed: '+ISNULL((SELECT Message FROM @rMintA),N'?'); THROW 51000,@ErrMsg,1; END
DECLARE @A_Machined BIGINT = (SELECT NewId FROM @rMintA);
```

The subsequent `Assembly_CompleteTray` (consuming `6MA-M` sublots) now consumes the minted machined LOT's downstream split/whole quantity as before — but since Machining OUT no longer splits to AFIN, the machined LOT is line-resident; adjust the assembly step to consume from the machined LOT at the line (the assembly cell), consistent with the line-resident model. Update the header topology comment (lines ~20–39) to describe mint-at-OUT with a real casting→machined `Consumption` edge (delete the "cast LOTs are NOT genealogy-linked" note).

- [ ] **Step 2: Run the seed end-to-end on a fresh DB**

```bash
powershell -File .\Reset-DevDatabase.ps1 -SkipDemoSeed
sqlcmd -S localhost -d MPP_MES_Dev -E -b -I -C -i sql/scratch/seed_demo.sql
```
Expected: completes without error; the "WHAT TO SMOKE" block prints. Verify the genealogy edge now exists:

```bash
sqlcmd … -Q "SELECT COUNT(*) AS CastToMachinedEdges FROM Lots.LotGenealogy g JOIN Parts.Item pi ON pi.Id=(SELECT ItemId FROM Lots.Lot WHERE Id=g.ParentLotId) JOIN Parts.Item ci ON ci.Id=(SELECT ItemId FROM Lots.Lot WHERE Id=g.ChildLotId) WHERE pi.PartNumber LIKE '%-C' AND ci.PartNumber LIKE '%-M' AND g.RelationshipTypeId=3;"
```
Expected: `CastToMachinedEdges` > 0 (was 0 in the old seed).

- [ ] **Step 3: Confirm `Reset-DevDatabase` default path still works**

Run: `powershell -File .\Reset-DevDatabase.ps1` (default runs `seed_demo.sql`).
Expected: succeeds end-to-end.

- [ ] **Step 4: Commit**

```bash
git add sql/scratch/seed_demo.sql
git commit -m "feat(seed): rebuild demo machining thread on MachiningOut_Mint (authentic cast->machined genealogy)"
```

---

## Self-Review

- **Spec coverage:** §3.4/§3.6/§3.8/§3.10 Machining OUT consume-mint → Task 1. §4.2 route-legality (option C, the three structural checks) → Task 2. Decision 6 / B5 ranked FG → Task 3. §3.7/B8 sublot exception-only → Task 4. B9 demo seed → Task 5. `Consumption`-only genealogy verified in Task 1 (asserts no `Split` edge) + Task 4 (grep). Assembly OUT already mints + `Consumption` (verified no-change, U-side ranked default is Plan 3).
- **Placeholder scan:** the ranked-FG and route-legality tests carry concrete assertion skeletons; the fixture-building lines reference the exact sibling test to mirror (`030_RouteTemplate_SaveAll.sql`, `092_Assembly_CompleteTray.sql`) rather than restating 60 lines of fixture — acceptable since those are existing, readable patterns. No `TODO`/"handle errors".
- **Type consistency:** `MachiningOut_Mint(@SourceLotId,@OperationTemplateId,@PieceCount,@ProducedItemId,@AppUserId,@TerminalLocationId)`→`(Status,Message,NewId)` used identically in Task 1's test, Task 5's seed. `RelationshipTypeId=3` (Consumption) consistent with `Assembly_CompleteTray`. Role-kind codes (`Advance`/`OriginMint`/`ConsumeMint`) match Plan 1.

## Deferred (roadmap, unchanged)

- **Plan 3 — Ignition UI (Designer):** MachiningOutSplit → mint UI (drop `HasRenameBom` filter + destination dropdown; qty prefilled from `DefaultSubLotQty`; call `MachiningOut_Mint`); Assembly FG dropdown bound to `Item_ListEligibleFinishedGoodsRanked` with the recommended default preselected; repoint all 6 shop-floor views to the `@OperationTypeCode` queue read; rename/replace the `workorder/MachiningOut_RecordSplit` NQ → `MachiningOut_Mint`; new NQs for the ranked-FG read. Designer-executed per the view-edit boundary.
- **Plan 4 — Docs (D1–D8):** FDS-06-007/05-033 et al., Data Model (`OperationRoleKind`, `DefaultSubLotQty` relabel, `Split` demotion), User Journeys, task list / phased plan; supersede the 2026-07-06 intermediate spec.
