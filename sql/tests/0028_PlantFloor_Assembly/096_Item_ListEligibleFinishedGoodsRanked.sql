-- =============================================
-- File:         0028_PlantFloor_Assembly/096_Item_ListEligibleFinishedGoodsRanked.sql
-- Description:  Parts.Item_ListEligibleFinishedGoodsRanked (terminal-mint decision 6/B5):
--               eligible FGs at the assembly cell, exactly one IsRecommended=1.
-- =============================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0028_PlantFloor_Assembly/096_Item_ListEligibleFinishedGoodsRanked.sql';
GO

DECLARE @Cell BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MA1-FPRPY-AFIN');
CREATE TABLE #Q (Id BIGINT, PartNumber NVARCHAR(50), Description NVARCHAR(500), LinesSatisfied INT, IsRecommended BIT);
INSERT INTO #Q EXEC Parts.Item_ListEligibleFinishedGoodsRanked @LocationId = @Cell;

DECLARE @recCnt NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM #Q WHERE IsRecommended = 1);
EXEC test.Assert_IsEqual @TestName = N'[RankedFG] exactly one FG recommended', @Expected = N'1', @Actual = @recCnt;

DECLARE @has6MA NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM #Q WHERE PartNumber = N'6MA');
EXEC test.Assert_IsEqual @TestName = N'[RankedFG] 6MA eligible at the assembly cell', @Expected = N'1', @Actual = @has6MA;
DROP TABLE #Q;
GO
