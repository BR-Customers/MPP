-- =============================================
-- File:         0067_Lot_SearchAdvanced/030_origin_conditional.sql
-- Author:       Blue Ridge Automation
-- Description:  Die / Cavity are die-cast-origin dimensions. Lot.ToolId and
--               Lot.ToolCavityId are NULL on merged LOTs (OI-05) and on
--               non-cast origins, so ANY @ToolId filter implicitly narrows to
--               die-cast-origin LOTs. That is intended behaviour, and this file
--               pins it so a future "helpful" OR-NULL relaxation is caught.
--
--               The reset database has no Tools, so the tooled LOT's fixture
--               creates its own Tool + ToolCavity via the Tools procs.
-- =============================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0067_Lot_SearchAdvanced/030_origin_conditional.sql';
GO

IF OBJECT_ID(N'tempdb..#SF') IS NOT NULL DROP TABLE #SF;
CREATE TABLE #SF (Tag NVARCHAR(30) PRIMARY KEY, Val BIGINT);

IF OBJECT_ID(N'tempdb..#LS') IS NOT NULL DROP TABLE #LS;
CREATE TABLE #LS (
    Id BIGINT, LotName NVARCHAR(50), ItemId BIGINT, LotOriginTypeId BIGINT,
    LotStatusId BIGINT, PieceCount INT, VendorLotNumber NVARCHAR(100),
    CurrentLocationId BIGINT, CreatedAt DATETIME2(3), ItemPartNumber NVARCHAR(100),
    LotStatusCode NVARCHAR(50), LotOriginTypeCode NVARCHAR(50),
    CurrentLocationName NVARCHAR(200), LastOperationName NVARCHAR(100),
    ToolCode NVARCHAR(50), CavityNumber INT, OriginMachineName NVARCHAR(200),
    TotalCount INT
);
GO

-- ---- Fixture: a Tool + Cavity, one tooled LOT, one NULL-Tool LOT ----
DECLARE @ItemId BIGINT, @CellA BIGINT, @ToolId BIGINT, @CavityId BIGINT;
DECLARE @OriginRcv  BIGINT = (SELECT Id FROM Lots.LotOriginType WHERE Code = N'Received');
DECLARE @StatusGood BIGINT = (SELECT Id FROM Lots.LotStatusCode WHERE Code = N'Good');
DECLARE @UserId     BIGINT = (SELECT MIN(Id) FROM Location.AppUser);
DECLARE @ToolTypeId BIGINT = (SELECT MIN(Id) FROM Tools.ToolType);
DECLARE @ToolStatus BIGINT = (SELECT MIN(Id) FROM Tools.ToolStatusCode);

SELECT TOP 1 @ItemId = eil.ItemId, @CellA = eil.LocationId
FROM Parts.v_EffectiveItemLocation eil
ORDER BY eil.LocationId;

DECLARE @res TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);

INSERT INTO @res EXEC Tools.Tool_Create @ToolTypeId = @ToolTypeId, @Code = N'TEST-ADV-DIE',
    @Name = N'Search Advanced Test Die', @StatusCodeId = @ToolStatus, @AppUserId = @UserId;
SELECT @ToolId = NewId FROM @res;
DELETE FROM @res;

INSERT INTO @res EXEC Tools.ToolCavity_Create @ToolId = @ToolId, @CavityNumber = 1,
    @AppUserId = @UserId;
SELECT @CavityId = NewId FROM @res;

INSERT INTO Lots.Lot (LotName, ItemId, LotOriginTypeId, LotStatusId, PieceCount,
                      CurrentLocationId, CreatedByUserId, ToolId, ToolCavityId, VendorLotNumber)
VALUES (N'TEST-TOOLED-01', @ItemId, @OriginRcv, @StatusGood, 1, @CellA, @UserId,
        @ToolId, @CavityId, N'VND-OC-001');
INSERT INTO #SF (Tag, Val) VALUES (N'LotTooled', SCOPE_IDENTITY());

INSERT INTO Lots.Lot (LotName, ItemId, LotOriginTypeId, LotStatusId, PieceCount,
                      CurrentLocationId, CreatedByUserId, ToolId, ToolCavityId, VendorLotNumber)
VALUES (N'TEST-NULLTOOL-01', @ItemId, @OriginRcv, @StatusGood, 1, @CellA, @UserId,
        NULL, NULL, N'VND-OC-002');
INSERT INTO #SF (Tag, Val) VALUES (N'LotNullTool', SCOPE_IDENTITY());

INSERT INTO #SF (Tag, Val) VALUES (N'ToolId', @ToolId), (N'CavityId', @CavityId);
GO

DECLARE @n INT;
DECLARE @ToolId   BIGINT = (SELECT Val FROM #SF WHERE Tag = N'ToolId');
DECLARE @CavityId BIGINT = (SELECT Val FROM #SF WHERE Tag = N'CavityId');

-- 1. Both fixture LOTs are returned unfiltered.
INSERT INTO #LS EXEC Lots.Lot_SearchAdvanced @Query = N'VND-OC-';
SELECT @n = COUNT(*) FROM #LS;
EXEC test.Assert_IsEqual @TestName = N'[SearchAdv] both tooled and NULL-Tool LOTs returned unfiltered',
    @Expected = N'2', @Actual = @n;

-- 2. The NULL-Tool LOT renders NULL Die / Cavity rather than erroring.
SELECT @n = COUNT(*) FROM #LS
WHERE LotName = N'TEST-NULLTOOL-01' AND (ToolCode IS NOT NULL OR CavityNumber IS NOT NULL);
EXEC test.Assert_IsEqual @TestName = N'[SearchAdv] NULL-Tool LOT yields NULL ToolCode and CavityNumber',
    @Expected = N'0', @Actual = @n;

-- 3. The tooled LOT resolves its Die code and cavity number.
SELECT @n = COUNT(*) FROM #LS
WHERE LotName = N'TEST-TOOLED-01' AND ToolCode = N'TEST-ADV-DIE' AND CavityNumber = 1;
EXEC test.Assert_IsEqual @TestName = N'[SearchAdv] tooled LOT resolves ToolCode and CavityNumber',
    @Expected = N'1', @Actual = @n;
DELETE FROM #LS;

-- 4. @ToolId keeps the tooled LOT and drops the NULL-Tool one.
INSERT INTO #LS EXEC Lots.Lot_SearchAdvanced @Query = N'VND-OC-', @ToolId = @ToolId;
SELECT @n = COUNT(*) FROM #LS;
EXEC test.Assert_IsEqual @TestName = N'[SearchAdv] @ToolId returns only the tooled LOT',
    @Expected = N'1', @Actual = @n;
SELECT @n = COUNT(*) FROM #LS WHERE LotName = N'TEST-NULLTOOL-01';
EXEC test.Assert_IsEqual @TestName = N'[SearchAdv] NULL-Tool LOT excluded by any @ToolId',
    @Expected = N'0', @Actual = @n;
DELETE FROM #LS;

-- 5. @ToolCavityId behaves the same way.
INSERT INTO #LS EXEC Lots.Lot_SearchAdvanced @Query = N'VND-OC-', @ToolCavityId = @CavityId;
SELECT @n = COUNT(*) FROM #LS;
EXEC test.Assert_IsEqual @TestName = N'[SearchAdv] @ToolCavityId returns only the tooled LOT',
    @Expected = N'1', @Actual = @n;
DELETE FROM #LS;

-- 6. Neither fixture LOT has a die-cast contribution, so a machine filter drops both.
INSERT INTO #LS EXEC Lots.Lot_SearchAdvanced @Query = N'VND-OC-', @MachineLocationId = 999999;
SELECT @n = COUNT(*) FROM #LS;
EXEC test.Assert_IsEqual @TestName = N'[SearchAdv] @MachineLocationId excludes LOTs with no contribution',
    @Expected = N'0', @Actual = @n;
DELETE FROM #LS;

-- 7. Same for a shift filter.
INSERT INTO #LS EXEC Lots.Lot_SearchAdvanced @Query = N'VND-OC-', @ShiftId = 999999;
SELECT @n = COUNT(*) FROM #LS;
EXEC test.Assert_IsEqual @TestName = N'[SearchAdv] @ShiftId excludes LOTs with no contribution',
    @Expected = N'0', @Actual = @n;
GO

-- ---- Teardown (closure BEFORE the LOTs; cavity + tool last) ----
DECLARE @ids TABLE (Id BIGINT);
INSERT INTO @ids SELECT Val FROM #SF WHERE Tag IN (N'LotTooled', N'LotNullTool');

DELETE FROM Lots.LotGenealogyClosure
WHERE AncestorLotId IN (SELECT Id FROM @ids) OR DescendantLotId IN (SELECT Id FROM @ids);
DELETE FROM Lots.LotGenealogy
WHERE ParentLotId IN (SELECT Id FROM @ids) OR ChildLotId IN (SELECT Id FROM @ids);
DELETE FROM Lots.LotEventLog      WHERE LotId IN (SELECT Id FROM @ids);
DELETE FROM Lots.LotMovement      WHERE LotId IN (SELECT Id FROM @ids);
DELETE FROM Lots.LotStatusHistory WHERE LotId IN (SELECT Id FROM @ids);
DELETE FROM Lots.Lot              WHERE Id    IN (SELECT Id FROM @ids);

DECLARE @ToolId BIGINT = (SELECT Val FROM #SF WHERE Tag = N'ToolId');
DELETE FROM Tools.ToolCavity WHERE ToolId = @ToolId;
DELETE FROM Tools.Tool       WHERE Id     = @ToolId;

IF OBJECT_ID(N'tempdb..#LS') IS NOT NULL DROP TABLE #LS;
IF OBJECT_ID(N'tempdb..#SF') IS NOT NULL DROP TABLE #SF;
GO
