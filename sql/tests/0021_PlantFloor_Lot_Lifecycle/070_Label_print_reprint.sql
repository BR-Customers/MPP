-- =============================================
-- File:         0021_PlantFloor_Lot_Lifecycle/070_Label_print_reprint.sql
-- Author:       Blue Ridge Automation
-- Created:      2026-06-11
-- Description:  Tests for Lots.LotLabel_Print + Lots.LotLabel_Reprint (Phase 2
--               Task 6 / G4). Asserts: initial print succeeds and returns the
--               rendered ZPL; ALL FIVE placeholder tokens are substituted (no
--               leftover '{...}'); the LotName is rendered into the ZPL; a sublot
--               (split-child) label carries LotLabel.ParentLotId + the parent's
--               LotName in the ZPL; reprint appends a SECOND append-only LotLabel
--               row carrying the supplied reprint reason; and a print against a
--               label type with NO active LabelTemplate is rejected (Status=0).
--
--               Fixtures use a NON-DieCast 'Received' origin on an eligible
--               (Item, Cell) pair with NO active ToolAssignment, so no Tool /
--               Cavity setup is required (mirrors 020_Lot_Split). The sublot
--               fixture is minted via Lots.Lot_Split so it carries a real
--               ParentLotId + parent-derived '-NN' name.
--
--               Audit: LotLabel-entity operations route to Audit.OperationLog
--               (NOT Lots.LotEventLog -- only the 'Lot' entity routes there).
--               Teardown deletes those OperationLog rows (by LotLabel entity type
--               + the minted label ids) before the LOTs, plus the split
--               genealogy/closure rows, per feedback_runtests_exit1_zero_failures.
--
--               The missing-active-template case deprecates the 'Void' (type 4)
--               LabelTemplate inside the test, then restores it (clears
--               DeprecatedAt) at the end so other suites/runs see the seed intact.
-- =============================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0021_PlantFloor_Lot_Lifecycle/070_Label_print_reprint.sql';
GO

-- ---- shared fixtures ----
-- Track every LOT id + minted LotLabel id this suite touches so the FK-safe
-- cleanup at the end can sweep them all (and their audit rows).
IF OBJECT_ID(N'tempdb..#LblFix')   IS NOT NULL DROP TABLE #LblFix;
IF OBJECT_ID(N'tempdb..#LblIds')   IS NOT NULL DROP TABLE #LblIds;
CREATE TABLE #LblFix (Tag NVARCHAR(20) PRIMARY KEY, LotId BIGINT, LotName NVARCHAR(50));
CREATE TABLE #LblIds (LabelId BIGINT PRIMARY KEY);
GO

DECLARE @OriginRcv BIGINT = (SELECT Id FROM Lots.LotOriginType WHERE Code = N'Received');
DECLARE @ItemId BIGINT, @CellId BIGINT;
SELECT TOP 1 @ItemId = eil.ItemId, @CellId = eil.LocationId
FROM Parts.v_EffectiveItemLocation eil
WHERE eil.ItemId IN (SELECT Id FROM Parts.Item WHERE MaxLotSize IS NULL)   -- uncapped: fixture PieceCounts exceed the 24-30 seed basket caps
  AND NOT EXISTS (SELECT 1 FROM Tools.ToolAssignment ta
                  WHERE ta.CellLocationId = eil.LocationId AND ta.ReleasedAt IS NULL)
ORDER BY eil.LocationId;

DECLARE @cr TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT, MintedLotName NVARCHAR(50));

-- L_PRIMARY: a primary LOT (no parent) for the basic print + reprint tests.
DELETE FROM @cr;
INSERT INTO @cr EXEC Lots.Lot_Create
    @ItemId = @ItemId, @LotOriginTypeId = @OriginRcv, @CurrentLocationId = @CellId,
    @PieceCount = 40, @AppUserId = 1;
INSERT INTO #LblFix (Tag, LotId, LotName) SELECT N'L_PRIMARY', NewId, MintedLotName FROM @cr;

-- L_PARENT: a parent LOT that we split to produce a sublot child for the
-- ParentLotId / {ParentLotNumber} test.
DELETE FROM @cr;
INSERT INTO @cr EXEC Lots.Lot_Create
    @ItemId = @ItemId, @LotOriginTypeId = @OriginRcv, @CurrentLocationId = @CellId,
    @PieceCount = 30, @AppUserId = 1;
INSERT INTO #LblFix (Tag, LotId, LotName) SELECT N'L_PARENT', NewId, MintedLotName FROM @cr;
GO

-- Split L_PARENT off one child of 10 -> a real sublot with ParentLotId + '-01' name.
DECLARE @ParentId  BIGINT = (SELECT LotId FROM #LblFix WHERE Tag = N'L_PARENT');
DECLARE @ParentLoc BIGINT = (SELECT CurrentLocationId FROM Lots.Lot WHERE Id = @ParentId);
DECLARE @childJson NVARCHAR(MAX) =
    N'[{"pieceCount":10,"currentLocationId":' + CAST(@ParentLoc AS NVARCHAR(20)) + N'}]';
CREATE TABLE #child (Status BIT, Message NVARCHAR(500), ChildLotId BIGINT, ChildLotName NVARCHAR(50), PieceCount INT);
INSERT INTO #child EXEC Lots.Lot_Split
    @ParentLotId = @ParentId, @ChildrenJson = @childJson, @AppUserId = 1;
INSERT INTO #LblFix (Tag, LotId, LotName)
    SELECT N'L_SUBLOT', ChildLotId, ChildLotName FROM #child WHERE ChildLotId IS NOT NULL;
DROP TABLE #child;
GO

-- =============================================
-- Test 1: initial print succeeds + returns ZPL; all tokens substituted;
--         LotName rendered into the ZPL; a LotLabel row was created.
--   Print a Primary (type 1) label, Initial (reason 1) on L_PRIMARY.
-- =============================================
DECLARE @LotId   BIGINT = (SELECT LotId   FROM #LblFix WHERE Tag = N'L_PRIMARY');
DECLARE @LotName NVARCHAR(50) = (SELECT LotName FROM #LblFix WHERE Tag = N'L_PRIMARY');

CREATE TABLE #l (Status BIT, Message NVARCHAR(500), NewId BIGINT, ZplContent NVARCHAR(MAX));
INSERT INTO #l EXEC Lots.LotLabel_Print
    @LotId = @LotId, @LabelTypeCodeId = 1, @PrintReasonCodeId = 1, @AppUserId = 1;

INSERT INTO #LblIds (LabelId) SELECT NewId FROM #l WHERE NewId IS NOT NULL;

DECLARE @ok1 BIT = (SELECT TOP 1 Status FROM #l);
EXEC test.Assert_IsTrue @TestName = N'[Label] initial print succeeds (Status=1)', @Condition = @ok1;

DECLARE @zpl NVARCHAR(MAX) = (SELECT TOP 1 ZplContent FROM #l);
EXEC test.Assert_IsNotNull @TestName = N'[Label] print returns ZplContent', @Value = @zpl;

-- No leftover '{Token}' anywhere in the rendered ZPL.
DECLARE @noToken BIT = CASE WHEN CHARINDEX(N'{', ISNULL(@zpl, N'{')) = 0 THEN 1 ELSE 0 END;
EXEC test.Assert_IsTrue @TestName = N'[Label] all tokens substituted (no leftover {)', @Condition = @noToken;

EXEC test.Assert_Contains @TestName = N'[Label] LotName rendered into ZPL',
    @HaystackStr = @zpl, @NeedleStr = @LotName;

-- A LotLabel row exists for the LOT.
DECLARE @rows1 INT = (SELECT COUNT(*) FROM Lots.LotLabel WHERE LotId = @LotId);
EXEC test.Assert_RowCount @TestName = N'[Label] one LotLabel row created for primary LOT',
    @ExpectedCount = 1, @ActualCount = @rows1;

DROP TABLE #l;
GO

-- =============================================
-- Test 2: sublot label carries ParentLotId + the parent's LotName in the ZPL.
--   Print a Container (type 2) label on the split child L_SUBLOT.
-- =============================================
DECLARE @SubId    BIGINT = (SELECT LotId FROM #LblFix WHERE Tag = N'L_SUBLOT');
DECLARE @ParId    BIGINT = (SELECT LotId   FROM #LblFix WHERE Tag = N'L_PARENT');
DECLARE @ParName  NVARCHAR(50) = (SELECT LotName FROM #LblFix WHERE Tag = N'L_PARENT');

CREATE TABLE #l2 (Status BIT, Message NVARCHAR(500), NewId BIGINT, ZplContent NVARCHAR(MAX));
INSERT INTO #l2 EXEC Lots.LotLabel_Print
    @LotId = @SubId, @LabelTypeCodeId = 2, @PrintReasonCodeId = 1, @AppUserId = 1;
INSERT INTO #LblIds (LabelId) SELECT NewId FROM #l2 WHERE NewId IS NOT NULL;

DECLARE @subOk BIT = (SELECT TOP 1 Status FROM #l2);
EXEC test.Assert_IsTrue @TestName = N'[Label] sublot print succeeds (Status=1)', @Condition = @subOk;

-- The inserted LotLabel row carries ParentLotId = the parent LOT.
DECLARE @subLabelId BIGINT = (SELECT TOP 1 NewId FROM #l2);
DECLARE @labelParent BIGINT = (SELECT ParentLotId FROM Lots.LotLabel WHERE Id = @subLabelId);
DECLARE @labelParentStr NVARCHAR(20) = CAST(@labelParent AS NVARCHAR(20));
DECLARE @parIdStr NVARCHAR(20) = CAST(@ParId AS NVARCHAR(20));
EXEC test.Assert_IsEqual @TestName = N'[Label] sublot label ParentLotId = parent LOT',
    @Expected = @parIdStr, @Actual = @labelParentStr;

-- The rendered ZPL contains the parent's LotName ({ParentLotNumber} token).
DECLARE @subZpl NVARCHAR(MAX) = (SELECT TOP 1 ZplContent FROM #l2);
EXEC test.Assert_Contains @TestName = N'[Label] sublot ZPL contains parent LotName',
    @HaystackStr = @subZpl, @NeedleStr = @ParName;

DROP TABLE #l2;
GO

-- =============================================
-- Test 3: reprint records a SECOND append-only row carrying the reprint reason.
--   L_PRIMARY already has its initial Primary print (Test 1). Reprint with
--   ReprintDamaged (reason 2) -> 2 rows total; the newest carries reason 2 and
--   resolves the SAME label type (Primary=1) from the prior row.
-- =============================================
DECLARE @RpLotId BIGINT = (SELECT LotId FROM #LblFix WHERE Tag = N'L_PRIMARY');

CREATE TABLE #lr (Status BIT, Message NVARCHAR(500), NewId BIGINT, ZplContent NVARCHAR(MAX));
INSERT INTO #lr EXEC Lots.LotLabel_Reprint
    @LotId = @RpLotId, @PrintReasonCodeId = 2, @AppUserId = 1;
INSERT INTO #LblIds (LabelId) SELECT NewId FROM #lr WHERE NewId IS NOT NULL;

DECLARE @rpOk BIT = (SELECT TOP 1 Status FROM #lr);
EXEC test.Assert_IsTrue @TestName = N'[Label] reprint succeeds (Status=1)', @Condition = @rpOk;

DECLARE @rpRows INT = (SELECT COUNT(*) FROM Lots.LotLabel WHERE LotId = @RpLotId);
EXEC test.Assert_RowCount @TestName = N'[Label] reprint appends second row (2 total)',
    @ExpectedCount = 2, @ActualCount = @rpRows;

-- The newest row carries the reprint reason (2) ...
DECLARE @newLabelId BIGINT = (SELECT TOP 1 NewId FROM #lr);
DECLARE @rpReason BIGINT = (SELECT PrintReasonCodeId FROM Lots.LotLabel WHERE Id = @newLabelId);
DECLARE @rpReasonStr NVARCHAR(20) = CAST(@rpReason AS NVARCHAR(20));
EXEC test.Assert_IsEqual @TestName = N'[Label] reprint row carries the reprint reason (2)',
    @Expected = N'2', @Actual = @rpReasonStr;

-- ... and resolves the same label type as the prior row (Primary = 1).
DECLARE @rpType BIGINT = (SELECT LabelTypeCodeId FROM Lots.LotLabel WHERE Id = @newLabelId);
DECLARE @rpTypeStr NVARCHAR(20) = CAST(@rpType AS NVARCHAR(20));
EXEC test.Assert_IsEqual @TestName = N'[Label] reprint resolves prior label type (Primary=1)',
    @Expected = N'1', @Actual = @rpTypeStr;

DROP TABLE #lr;
GO

-- =============================================
-- Test 3b: reprint with the Initial reason is rejected (Initial is reserved
--          for the first print via LotLabel_Print).
-- =============================================
DECLARE @RiLotId BIGINT = (SELECT LotId FROM #LblFix WHERE Tag = N'L_PRIMARY');
CREATE TABLE #lri (Status BIT, Message NVARCHAR(500), NewId BIGINT, ZplContent NVARCHAR(MAX));
INSERT INTO #lri EXEC Lots.LotLabel_Reprint
    @LotId = @RiLotId, @PrintReasonCodeId = 1 /*Initial*/, @AppUserId = 1;
DECLARE @riStatus BIT = (SELECT TOP 1 Status FROM #lri);
DECLARE @riCond BIT = CASE WHEN @riStatus = 0 THEN 1 ELSE 0 END;
EXEC test.Assert_IsTrue @TestName = N'[Label] reprint with Initial reason rejected', @Condition = @riCond;
-- no new row written on the rejected reprint (still 2 from Test 1 + Test 3)
DECLARE @riRows INT = (SELECT COUNT(*) FROM Lots.LotLabel WHERE LotId = @RiLotId);
EXEC test.Assert_RowCount @TestName = N'[Label] rejected Initial-reprint writes no row (still 2)',
    @ExpectedCount = 2, @ActualCount = @riRows;
DROP TABLE #lri;
GO

-- =============================================
-- Test 4: missing active template rejected (Status=0).
--   Deprecate the active 'Void' (type 4) LabelTemplate, then print a type-4
--   label -> reject. Restore the template afterward so the seed stays intact.
-- =============================================
DECLARE @NoTplLot BIGINT = (SELECT LotId FROM #LblFix WHERE Tag = N'L_PRIMARY');

UPDATE Lots.LabelTemplate SET DeprecatedAt = SYSUTCDATETIME()
    WHERE LabelTypeCodeId = 4 AND DeprecatedAt IS NULL;

CREATE TABLE #lm (Status BIT, Message NVARCHAR(500), NewId BIGINT, ZplContent NVARCHAR(MAX));
INSERT INTO #lm EXEC Lots.LotLabel_Print
    @LotId = @NoTplLot, @LabelTypeCodeId = 4, @PrintReasonCodeId = 1, @AppUserId = 1;

DECLARE @mStatus BIT = (SELECT TOP 1 Status FROM #lm);
DECLARE @mCond BIT = CASE WHEN @mStatus = 0 THEN 1 ELSE 0 END;
EXEC test.Assert_IsTrue @TestName = N'[Label] missing active template rejected (Status=0)', @Condition = @mCond;

-- No NewId / ZplContent on the rejected exit.
DECLARE @mNewId BIGINT = (SELECT TOP 1 NewId FROM #lm);
DECLARE @mNewIdStr NVARCHAR(20) = CAST(@mNewId AS NVARCHAR(20));
EXEC test.Assert_IsNull @TestName = N'[Label] rejected print returns NULL NewId', @Value = @mNewIdStr;

-- Restore the Void template (clear DeprecatedAt).
UPDATE Lots.LabelTemplate SET DeprecatedAt = NULL WHERE LabelTypeCodeId = 4;

DROP TABLE #lm;
GO

-- ---- cleanup (FK-safe) ----
-- Delete the LotLabel audit rows (LotLabel entity -> Audit.OperationLog) by the
-- minted label ids, then the LotLabel rows, then the split genealogy/closure +
-- movement/status rows, then the LOTs (null self-ref ParentLotId first).
DECLARE @lblEntityId BIGINT = (SELECT Id FROM Audit.LogEntityType WHERE Code = N'LotLabel');

DELETE FROM Audit.OperationLog
    WHERE LogEntityTypeId = @lblEntityId
      AND EntityId IN (SELECT LabelId FROM #LblIds);

DECLARE @ids TABLE (Id BIGINT);
INSERT INTO @ids SELECT LotId FROM #LblFix WHERE LotId IS NOT NULL;

DELETE FROM Lots.LotLabel WHERE LotId IN (SELECT Id FROM @ids);
DELETE FROM Lots.LotGenealogy
    WHERE ParentLotId IN (SELECT Id FROM @ids) OR ChildLotId IN (SELECT Id FROM @ids);
DELETE FROM Lots.LotGenealogyClosure
    WHERE AncestorLotId IN (SELECT Id FROM @ids) OR DescendantLotId IN (SELECT Id FROM @ids);
DELETE FROM Lots.LotAttributeChange WHERE LotId IN (SELECT Id FROM @ids);
DELETE FROM Lots.LotEventLog WHERE LotId IN (SELECT Id FROM @ids);
DELETE FROM Lots.LotMovement WHERE LotId IN (SELECT Id FROM @ids);
DELETE FROM Lots.LotStatusHistory WHERE LotId IN (SELECT Id FROM @ids);

UPDATE Lots.Lot SET ParentLotId = NULL WHERE Id IN (SELECT Id FROM @ids);
DELETE FROM Lots.Lot WHERE Id IN (SELECT Id FROM @ids);

IF OBJECT_ID(N'tempdb..#LblFix') IS NOT NULL DROP TABLE #LblFix;
IF OBJECT_ID(N'tempdb..#LblIds') IS NOT NULL DROP TABLE #LblIds;
GO

EXEC test.EndTestFile;
GO
