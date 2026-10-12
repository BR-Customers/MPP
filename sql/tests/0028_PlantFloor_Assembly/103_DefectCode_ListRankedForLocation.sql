-- =============================================
-- File:         0028_PlantFloor_Assembly/103_DefectCode_ListRankedForLocation.sql
-- Author:       Blue Ridge Automation
-- Created:      2026-10-12
-- Description:  Quality.DefectCode_ListRankedForLocation -- the Scrap Entry
--               popup's tile order: a line's scrap reasons, most used first.
--               Fixture: four test codes (two MachiningAssembly, one
--               plant-wide, one Trim) and reject rows stamped with a terminal
--               under the line, the line itself, and an unrelated location.
--               Covers:
--                 - order = pieces scrapped at the line, descending
--                 - a terminal directly under the line counts; so does the
--                   line itself; another location's scrap does not
--                 - rows older than the window do not count
--                 - unused codes follow, the operation's own ahead of
--                   plant-wide, then by Code
--                 - another category's codes are not offered; deprecated
--                   codes are not offered
--                 - scope matches Quality.DefectCode_List for the same
--                   operation type
--               EXEC args are pre-assigned @variables (no inline CAST).
-- =============================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0028_PlantFloor_Assembly/103_DefectCode_ListRankedForLocation.sql';
GO

-- ---- cleanup ----
DELETE FROM Workorder.RejectEvent WHERE DefectCodeId IN (SELECT Id FROM Quality.DefectCode WHERE Code LIKE N'TEST-RK-%');
DELETE FROM Quality.DefectCode    WHERE Code LIKE N'TEST-RK-%';
GO

-- ---- fixture ----
DECLARE @Now  DATETIME2(3) = SYSUTCDATETIME();
DECLARE @Old  DATETIME2(3) = DATEADD(DAY, -200, @Now);
-- A terminal and the line above it: any location that has a parent.
DECLARE @Term BIGINT = (SELECT TOP 1 c.Id FROM Location.Location c
                        INNER JOIN Location.Location p ON p.Id = c.ParentLocationId
                        WHERE p.ParentLocationId IS NOT NULL
                        ORDER BY c.Id DESC);
DECLARE @Line BIGINT = (SELECT ParentLocationId FROM Location.Location WHERE Id = @Term);
-- Somewhere that is neither the line nor one of its children.
DECLARE @Else BIGINT = (SELECT TOP 1 Id FROM Location.Location
                        WHERE Id <> @Line AND ISNULL(ParentLocationId, 0) <> @Line
                        ORDER BY Id);
DECLARE @MachAsm BIGINT = (SELECT Id FROM Parts.OperationCategory WHERE Code = N'MachiningAssembly');
DECLARE @Trim    BIGINT = (SELECT Id FROM Parts.OperationCategory WHERE Code = N'Trim');

INSERT INTO Quality.DefectCode (Code, Description, OperationCategoryId, IsExcused, CreatedAt) VALUES
    (N'TEST-RK-A', N'Rank test A (machining)',  @MachAsm, 0, @Now),
    (N'TEST-RK-B', N'Rank test B (machining)',  @MachAsm, 0, @Now),
    (N'TEST-RK-C', N'Rank test C (plant-wide)', NULL,     0, @Now),
    (N'TEST-RK-D', N'Rank test D (machining, unused)', @MachAsm, 0, @Now),
    (N'TEST-RK-T', N'Rank test T (trim)',       @Trim,    0, @Now);
INSERT INTO Quality.DefectCode (Code, Description, OperationCategoryId, IsExcused, CreatedAt, DeprecatedAt) VALUES
    (N'TEST-RK-X', N'Rank test X (deprecated)', @MachAsm, 0, @Now, @Now);

DECLARE @A BIGINT = (SELECT Id FROM Quality.DefectCode WHERE Code = N'TEST-RK-A');
DECLARE @B BIGINT = (SELECT Id FROM Quality.DefectCode WHERE Code = N'TEST-RK-B');
DECLARE @C BIGINT = (SELECT Id FROM Quality.DefectCode WHERE Code = N'TEST-RK-C');
DECLARE @X BIGINT = (SELECT Id FROM Quality.DefectCode WHERE Code = N'TEST-RK-X');

-- Quantities are large so the test codes outrank anything already in the DB.
INSERT INTO Workorder.RejectEvent (LotId, DefectCodeId, Quantity, AppUserId, RecordedAt, TerminalLocationId) VALUES
    (NULL, @B, 500000, 1, @Now, @Term),   -- B: 500000 + 100000 at a terminal under the line
    (NULL, @B, 100000, 1, @Now, @Term),
    (NULL, @A, 200000, 1, @Now, @Term),   -- A: 200000 in the window ...
    (NULL, @A, 900000, 1, @Old, @Term),   --    ... 900000 outside it (ignored)
    (NULL, @C, 100000, 1, @Now, @Line),   -- C: 100000 stamped with the line itself ...
    (NULL, @C, 900000, 1, @Now, @Else),   --    ... 900000 somewhere else (ignored)
    (NULL, @X, 900000, 1, @Now, @Term);   -- deprecated: never offered
GO

-- =============================================
-- Test 1: order + counts for a MachiningAssembly operation
-- =============================================
DECLARE @Term BIGINT = (SELECT TOP 1 TerminalLocationId FROM Workorder.RejectEvent
                        WHERE DefectCodeId = (SELECT Id FROM Quality.DefectCode WHERE Code = N'TEST-RK-B'));
DECLARE @Line BIGINT = (SELECT ParentLocationId FROM Location.Location WHERE Id = @Term);
CREATE TABLE #T (RankOrder INT, Id BIGINT, Code NVARCHAR(50), Description NVARCHAR(500),
                 OperationCategoryId BIGINT, IsExcused BIT, UseCount INT);
INSERT INTO #T EXEC Quality.DefectCode_ListRankedForLocation @LocationId = @Line, @OperationTypeCode = N'MachiningOut';

DECLARE @Top NVARCHAR(200) = (SELECT STRING_AGG(Code + N'=' + CAST(UseCount AS NVARCHAR(20)), N',') WITHIN GROUP (ORDER BY RankOrder)
                              FROM #T WHERE RankOrder <= 3);
EXEC test.Assert_IsEqual @TestName = N'[Rank] most used first: line + its terminal, window only',
    @Expected = N'TEST-RK-B=600000,TEST-RK-A=200000,TEST-RK-C=100000', @Actual = @Top;
DECLARE @DCount NVARCHAR(10) = (SELECT CAST(UseCount AS NVARCHAR(10)) FROM #T WHERE Code = N'TEST-RK-D');
EXEC test.Assert_IsEqual @TestName = N'[Rank] an unused code is still offered, at 0', @Expected = N'0', @Actual = @DCount;
DECLARE @Trim NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM #T WHERE Code = N'TEST-RK-T');
EXEC test.Assert_IsEqual @TestName = N'[Rank] another category''s code is not offered', @Expected = N'0', @Actual = @Trim;
DECLARE @Dep NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM #T WHERE Code = N'TEST-RK-X');
EXEC test.Assert_IsEqual @TestName = N'[Rank] a deprecated code is not offered', @Expected = N'0', @Actual = @Dep;

-- unused codes: the operation's own ahead of plant-wide, then by Code
DECLARE @BadOrder NVARCHAR(10) = (
    SELECT CAST(COUNT(*) AS NVARCHAR(10))
    FROM #T a INNER JOIN #T b ON b.RankOrder = a.RankOrder + 1
    WHERE a.UseCount = 0 AND b.UseCount = 0
      AND (   (a.OperationCategoryId IS NULL AND b.OperationCategoryId IS NOT NULL)
           OR (CASE WHEN a.OperationCategoryId IS NULL THEN 1 ELSE 0 END
               = CASE WHEN b.OperationCategoryId IS NULL THEN 1 ELSE 0 END AND a.Code > b.Code)));
EXEC test.Assert_IsEqual @TestName = N'[Rank] unused codes: own category first, then Code', @Expected = N'0', @Actual = @BadOrder;
DECLARE @Desc NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10))
                              FROM #T a INNER JOIN #T b ON b.RankOrder = a.RankOrder + 1 WHERE b.UseCount > a.UseCount);
EXEC test.Assert_IsEqual @TestName = N'[Rank] UseCount never rises down the list', @Expected = N'0', @Actual = @Desc;

-- same scope as the plain list
CREATE TABLE #L (Id BIGINT, Code NVARCHAR(50), Description NVARCHAR(500), OperationCategoryId BIGINT,
                 ChargeToPartyId BIGINT, ChargeToPartyName NVARCHAR(100), CategoryName NVARCHAR(100),
                 IsExcused BIT, CreatedAt DATETIME2(3), DeprecatedAt DATETIME2(3));
INSERT INTO #L EXEC Quality.DefectCode_List @IncludeDeprecated = 0, @OperationCategoryId = NULL, @OperationTypeCode = N'MachiningOut';
DECLARE @Diff NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM
    (SELECT Id FROM #T EXCEPT SELECT Id FROM #L UNION ALL SELECT Id FROM #L EXCEPT SELECT Id FROM #T) d);
EXEC test.Assert_IsEqual @TestName = N'[Rank] offers exactly the codes DefectCode_List offers', @Expected = N'0', @Actual = @Diff;
DROP TABLE #L;
DROP TABLE #T;
GO

-- =============================================
-- Test 2: a location with no stamped scrap falls back to the tie-break order
-- =============================================
DECLARE @Term BIGINT = (SELECT TOP 1 TerminalLocationId FROM Workorder.RejectEvent
                        WHERE DefectCodeId = (SELECT Id FROM Quality.DefectCode WHERE Code = N'TEST-RK-B'));
-- the terminal has no children and nothing is stamped BENEATH it; rows stamped
-- with the terminal itself do count, so use a location with no rows at all
DECLARE @Quiet BIGINT = (SELECT TOP 1 l.Id FROM Location.Location l
                         WHERE NOT EXISTS (SELECT 1 FROM Workorder.RejectEvent re
                                           INNER JOIN Location.Location x ON x.Id = re.TerminalLocationId
                                           WHERE x.Id = l.Id OR x.ParentLocationId = l.Id)
                         ORDER BY l.Id DESC);
CREATE TABLE #T (RankOrder INT, Id BIGINT, Code NVARCHAR(50), Description NVARCHAR(500),
                 OperationCategoryId BIGINT, IsExcused BIT, UseCount INT);
INSERT INTO #T EXEC Quality.DefectCode_ListRankedForLocation @LocationId = @Quiet, @OperationTypeCode = N'MachiningOut';
DECLARE @Used NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM #T WHERE UseCount <> 0);
EXEC test.Assert_IsEqual @TestName = N'[RankQuiet] no history -> every count is 0', @Expected = N'0', @Actual = @Used;
DECLARE @Order NVARCHAR(100) = (SELECT STRING_AGG(Code, N',') WITHIN GROUP (ORDER BY RankOrder)
                                FROM #T WHERE Code LIKE N'TEST-RK-%');
EXEC test.Assert_IsEqual @TestName = N'[RankQuiet] own category by Code, then plant-wide',
    @Expected = N'TEST-RK-A,TEST-RK-B,TEST-RK-D,TEST-RK-C', @Actual = @Order;
DROP TABLE #T;
GO

-- ---- cleanup ----
DELETE FROM Workorder.RejectEvent WHERE DefectCodeId IN (SELECT Id FROM Quality.DefectCode WHERE Code LIKE N'TEST-RK-%');
DELETE FROM Quality.DefectCode    WHERE Code LIKE N'TEST-RK-%';
GO

EXEC test.EndTestFile;
GO
