-- =============================================
-- File:         0028_PlantFloor_Assembly/099_Lot_GetLineInventorySummary.sql
-- Author:       Blue Ridge Automation
-- Created:      2026-09-17 (rewritten for v2.0, spec revision 2)
-- Description:  Lots.Lot_GetLineInventorySummary v2.0. Line MA1-COMPBR, called
--   with its terminal MA1-COMPBR-AOUT. Consumption rows (Parts.ItemLocation,
--   IsConsumptionPoint = 1) decide membership; % of the nearest row's MaxQuantity
--   decides the level (Critical: Avail*10 <= Max; Low: Avail*10 <= 3*Max).
--   Fixture (all at the line unless noted):
--     CAST1..CAST5  Component   consumption, Max 100, available 5/30/31/10/11
--     PIN           PassThrough consumption, Box 5000; Max 10000 on the AREA (MA1)
--                   and 2000 on the LINE -> nearest (2000) wins; available 60,
--                   plus a HELD LOT of 1000 (excluded) and a CLOSED LOT (excluded)
--     GASKET        PassThrough consumption, no Box, no Max; nothing on hand
--     SA            SubAssembly NOT consumption; 7 on hand
--     FG            FinishedGood on hand (never listed)
--   Every assertion filters to the fixture's own descriptions ('T099 %'), because
--   the line is shared with other suites.
-- =============================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0028_PlantFloor_Assembly/099_Lot_GetLineInventorySummary.sql';
GO

-- ---- cleanup (LOTs -> ItemLocation -> Item) ----
DELETE FROM Lots.Lot WHERE LotName LIKE N'T099-%';
DELETE il FROM Parts.ItemLocation il INNER JOIN Parts.Item i ON i.Id = il.ItemId WHERE i.PartNumber LIKE N'T099-%';
DELETE FROM Parts.Item WHERE PartNumber LIKE N'T099-%';
GO

-- ---- fixture ----
DECLARE @Now DATETIME2(3) = SYSUTCDATETIME();
DECLARE @TCo BIGINT = (SELECT Id FROM Parts.ItemType WHERE Code = N'Component');
DECLARE @TPt BIGINT = (SELECT Id FROM Parts.ItemType WHERE Code = N'PassThrough');
DECLARE @TSa BIGINT = (SELECT Id FROM Parts.ItemType WHERE Code = N'SubAssembly');
DECLARE @TFg BIGINT = (SELECT Id FROM Parts.ItemType WHERE Code = N'FinishedGood');
INSERT INTO Parts.Item (ItemTypeId, PartNumber, Description, UomId, CreatedAt, CreatedByUserId, BoxQuantity) VALUES
    (@TCo, N'T099-CAST1',  N'T099 cast 1',       1, @Now, 1, NULL),
    (@TCo, N'T099-CAST2',  N'T099 cast 2',       1, @Now, 1, NULL),
    (@TCo, N'T099-CAST3',  N'T099 cast 3',       1, @Now, 1, NULL),
    (@TCo, N'T099-CAST4',  N'T099 cast 4',       1, @Now, 1, NULL),
    (@TCo, N'T099-CAST5',  N'T099 cast 5',       1, @Now, 1, NULL),
    (@TPt, N'T099-PIN',    N'T099 dowel pin',    1, @Now, 1, 5000),
    (@TPt, N'T099-GASKET', N'T099 gasket',       1, @Now, 1, NULL),
    (@TSa, N'T099-SA',     N'T099 sub assembly', 1, @Now, 1, NULL),
    (@TFg, N'T099-FG',     N'T099 finished',     1, @Now, 1, NULL);

DECLARE @Line BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MA1-COMPBR');
DECLARE @Area BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MA1');

-- consumption rows (line tier), plus an AREA-tier row for PIN that must LOSE to the line row
INSERT INTO Parts.ItemLocation (ItemId, LocationId, MaxQuantity, IsConsumptionPoint, CreatedAt)
SELECT i.Id, @Line, v.MaxQ, 1, @Now
FROM (VALUES (N'T099-CAST1', 100), (N'T099-CAST2', 100), (N'T099-CAST3', 100), (N'T099-CAST4', 100),
             (N'T099-CAST5', 100), (N'T099-PIN', 2000), (N'T099-GASKET', NULL)) v(Pn, MaxQ)
INNER JOIN Parts.Item i ON i.PartNumber = v.Pn;
INSERT INTO Parts.ItemLocation (ItemId, LocationId, MaxQuantity, IsConsumptionPoint, CreatedAt)
SELECT Id, @Area, 10000, 1, @Now FROM Parts.Item WHERE PartNumber = N'T099-PIN';

DECLARE @Hold   BIGINT = (SELECT Id FROM Lots.LotStatusCode WHERE Code = N'Hold');
DECLARE @Closed BIGINT = (SELECT Id FROM Lots.LotStatusCode WHERE Code = N'Closed');
DECLARE @Good   BIGINT = (SELECT Id FROM Lots.LotStatusCode WHERE Code = N'Good');
INSERT INTO Lots.Lot (LotName, ItemId, LotOriginTypeId, LotStatusId, PieceCount, InventoryAvailable, CurrentLocationId, CreatedByUserId, CreatedAt)
SELECT N'T099-' + v.Tag, i.Id, 2, v.St, v.Q, v.Q, @Line, 1, @Now
FROM (VALUES (N'T099-CAST1', N'C1', @Good, 5), (N'T099-CAST2', N'C2', @Good, 30), (N'T099-CAST3', N'C3', @Good, 31),
             (N'T099-CAST4', N'C4', @Good, 10), (N'T099-CAST5', N'C5', @Good, 11),
             (N'T099-PIN', N'P1', @Good, 60), (N'T099-PIN', N'PH', @Hold, 1000), (N'T099-PIN', N'PX', @Closed, 99),
             (N'T099-SA', N'S1', @Good, 7), (N'T099-FG', N'F1', @Good, 30)) v(Pn, Tag, St, Q)
INNER JOIN Parts.Item i ON i.PartNumber = v.Pn;
GO

-- =============================================
-- Phase 1: line-wide -- membership, FG excluded, held/closed excluded, nearest Max
-- =============================================
DECLARE @Term BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MA1-COMPBR-AOUT');
CREATE TABLE #R (Seq INT IDENTITY(1,1), ItemId BIGINT, Description NVARCHAR(500), Available INT, MaxQuantity INT,
                 Level NVARCHAR(10), BoxQuantity INT, AddLotMode NVARCHAR(10), ItemLocationId BIGINT, ScopeCode NVARCHAR(20));
INSERT INTO #R (ItemId, Description, Available, MaxQuantity, Level, BoxQuantity, AddLotMode, ItemLocationId, ScopeCode)
EXEC Lots.Lot_GetLineInventorySummary @LocationId = @Term, @LineWide = 1;
DELETE FROM #R WHERE Description NOT LIKE N'T099 %';

DECLARE @N NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM #R);
EXEC test.Assert_IsEqual @TestName = N'[LineWide] 8 parts (5 casts, pin, gasket, SA; FG excluded)', @Expected = N'8', @Actual = @N;
DECLARE @PinAv NVARCHAR(10) = (SELECT CAST(Available AS NVARCHAR(10)) FROM #R WHERE Description = N'T099 dowel pin');
EXEC test.Assert_IsEqual @TestName = N'[LineWide] PIN available 60 (held + closed excluded)', @Expected = N'60', @Actual = @PinAv;
DECLARE @PinMax NVARCHAR(10) = (SELECT CAST(MaxQuantity AS NVARCHAR(10)) FROM #R WHERE Description = N'T099 dowel pin');
EXEC test.Assert_IsEqual @TestName = N'[LineWide] PIN Max 2000 (nearest row beats the area row)', @Expected = N'2000', @Actual = @PinMax;
DECLARE @PinIl NVARCHAR(1) = (SELECT CASE WHEN r.ItemLocationId = il.Id THEN N'1' ELSE N'0' END
    FROM #R r INNER JOIN Parts.ItemLocation il ON il.ItemId = r.ItemId AND il.LocationId = (SELECT Id FROM Location.Location WHERE Code = N'MA1-COMPBR')
    WHERE r.Description = N'T099 dowel pin');
EXEC test.Assert_IsEqual @TestName = N'[LineWide] PIN ItemLocationId is the LINE row', @Expected = N'1', @Actual = @PinIl;
DECLARE @GaAv NVARCHAR(20) = (SELECT CAST(Available AS NVARCHAR(10)) + N'/' + Level FROM #R WHERE Description = N'T099 gasket');
EXEC test.Assert_IsEqual @TestName = N'[LineWide] GASKET listed at 0 with no Max -> None', @Expected = N'0/None', @Actual = @GaAv;
DECLARE @SaLv NVARCHAR(20) = (SELECT Level + N'/' + AddLotMode FROM #R WHERE Description = N'T099 sub assembly');
EXEC test.Assert_IsEqual @TestName = N'[LineWide] SA (on hand, not consumption) listed, None/None', @Expected = N'None/None', @Actual = @SaLv;
DECLARE @Scope NVARCHAR(20) = (SELECT TOP 1 ScopeCode FROM #R);
EXEC test.Assert_IsEqual @TestName = N'[LineWide] scope All', @Expected = N'All', @Actual = @Scope;
DROP TABLE #R;
GO

-- =============================================
-- Phase 2: levels at and either side of each boundary
-- =============================================
DECLARE @Term BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MA1-COMPBR-AOUT');
DECLARE @R TABLE (ItemId BIGINT, Description NVARCHAR(500), Available INT, MaxQuantity INT, Level NVARCHAR(10),
                  BoxQuantity INT, AddLotMode NVARCHAR(10), ItemLocationId BIGINT, ScopeCode NVARCHAR(20));
INSERT INTO @R EXEC Lots.Lot_GetLineInventorySummary @LocationId = @Term, @LineWide = 1;
DECLARE @Lv NVARCHAR(200) = (SELECT STRING_AGG(REPLACE(Description, N'T099 ', N'') + N'=' + Level, N',')
                                    WITHIN GROUP (ORDER BY Description)
                             FROM @R WHERE Description LIKE N'T099 cast %');
EXEC test.Assert_IsEqual @TestName = N'[Level] 5 Crit, 30 Low (at 30%), 31 Ok, 10 Crit (at 10%), 11 Low',
    @Expected = N'cast 1=Critical,cast 2=Low,cast 3=Ok,cast 4=Critical,cast 5=Low', @Actual = @Lv;
DECLARE @PinLv NVARCHAR(10) = (SELECT Level FROM @R WHERE Description = N'T099 dowel pin');
EXEC test.Assert_IsEqual @TestName = N'[Level] PIN 60 of 2000 = 3% -> Critical', @Expected = N'Critical', @Actual = @PinLv;
GO

-- =============================================
-- Phase 3: order (most urgent share first, then no-Max by description) + button modes
-- =============================================
DECLARE @Term BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MA1-COMPBR-AOUT');
CREATE TABLE #O (Seq INT IDENTITY(1,1), ItemId BIGINT, Description NVARCHAR(500), Available INT, MaxQuantity INT,
                 Level NVARCHAR(10), BoxQuantity INT, AddLotMode NVARCHAR(10), ItemLocationId BIGINT, ScopeCode NVARCHAR(20));
INSERT INTO #O (ItemId, Description, Available, MaxQuantity, Level, BoxQuantity, AddLotMode, ItemLocationId, ScopeCode)
EXEC Lots.Lot_GetLineInventorySummary @LocationId = @Term, @LineWide = 1;
DECLARE @Order NVARCHAR(400) = (SELECT STRING_AGG(REPLACE(Description, N'T099 ', N''), N',') WITHIN GROUP (ORDER BY Seq)
                                FROM #O WHERE Description LIKE N'T099 %');
EXEC test.Assert_IsEqual @TestName = N'[Order] pin 3%, cast1 5%, cast4 10%, cast5 11%, cast2 30%, cast3 31%, then gasket, sub assembly',
    @Expected = N'dowel pin,cast 1,cast 4,cast 5,cast 2,cast 3,gasket,sub assembly', @Actual = @Order;
DECLARE @Modes NVARCHAR(200) = (SELECT STRING_AGG(REPLACE(Description, N'T099 ', N'') + N'=' + AddLotMode, N',') WITHIN GROUP (ORDER BY Description)
                                FROM #O WHERE Description IN (N'T099 dowel pin', N'T099 gasket', N'T099 cast 1', N'T099 sub assembly'));
DROP TABLE #O;
EXEC test.Assert_IsEqual @TestName = N'[Mode] pin OneTap, gasket AskQty, cast/SA None',
    @Expected = N'cast 1=None,dowel pin=OneTap,gasket=AskQty,sub assembly=None', @Actual = @Modes;
GO

-- =============================================
-- Phase 4: terminal-role scope
-- =============================================
DECLARE @Term BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MA1-COMPBR-AOUT');
DECLARE @M TABLE (ItemId BIGINT, Description NVARCHAR(500), Available INT, MaxQuantity INT, Level NVARCHAR(10),
                  BoxQuantity INT, AddLotMode NVARCHAR(10), ItemLocationId BIGINT, ScopeCode NVARCHAR(20));
INSERT INTO @M EXEC Lots.Lot_GetLineInventorySummary @LocationId = @Term, @TerminalRole = N'MachiningIn';
DECLARE @MSet NVARCHAR(400) = (SELECT STRING_AGG(REPLACE(Description, N'T099 ', N''), N',') WITHIN GROUP (ORDER BY Description)
                               FROM @M WHERE Description LIKE N'T099 %');
EXEC test.Assert_IsEqual @TestName = N'[Scope] MachiningIn -> castings only', @Expected = N'cast 1,cast 2,cast 3,cast 4,cast 5', @Actual = @MSet;
DECLARE @MScope NVARCHAR(20) = (SELECT TOP 1 ScopeCode FROM @M);
EXEC test.Assert_IsEqual @TestName = N'[Scope] MachiningIn scope Castings', @Expected = N'Castings', @Actual = @MScope;

DECLARE @A TABLE (ItemId BIGINT, Description NVARCHAR(500), Available INT, MaxQuantity INT, Level NVARCHAR(10),
                  BoxQuantity INT, AddLotMode NVARCHAR(10), ItemLocationId BIGINT, ScopeCode NVARCHAR(20));
INSERT INTO @A EXEC Lots.Lot_GetLineInventorySummary @LocationId = @Term, @TerminalRole = N'AssemblyOut';
DECLARE @ASet NVARCHAR(400) = (SELECT STRING_AGG(REPLACE(Description, N'T099 ', N''), N',') WITHIN GROUP (ORDER BY Description)
                               FROM @A WHERE Description LIKE N'T099 %');
EXEC test.Assert_IsEqual @TestName = N'[Scope] AssemblyOut -> bought parts only', @Expected = N'dowel pin,gasket', @Actual = @ASet;
DECLARE @AScope NVARCHAR(20) = (SELECT TOP 1 ScopeCode FROM @A);
EXEC test.Assert_IsEqual @TestName = N'[Scope] AssemblyOut scope Purchased', @Expected = N'Purchased', @Actual = @AScope;

DECLARE @W TABLE (ItemId BIGINT, Description NVARCHAR(500), Available INT, MaxQuantity INT, Level NVARCHAR(10),
                  BoxQuantity INT, AddLotMode NVARCHAR(10), ItemLocationId BIGINT, ScopeCode NVARCHAR(20));
INSERT INTO @W EXEC Lots.Lot_GetLineInventorySummary @LocationId = @Term, @TerminalRole = N'AssemblyOut', @LineWide = 1;
DECLARE @WN NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM @W WHERE Description LIKE N'T099 %');
EXEC test.Assert_IsEqual @TestName = N'[Scope] LineWide overrides the role', @Expected = N'8', @Actual = @WN;
GO

-- =============================================
-- Phase 5: empty sets
-- =============================================
DECLARE @E TABLE (ItemId BIGINT, Description NVARCHAR(500), Available INT, MaxQuantity INT, Level NVARCHAR(10),
                  BoxQuantity INT, AddLotMode NVARCHAR(10), ItemLocationId BIGINT, ScopeCode NVARCHAR(20));
INSERT INTO @E EXEC Lots.Lot_GetLineInventorySummary @LocationId = NULL;
DECLARE @Area BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MA1');
INSERT INTO @E EXEC Lots.Lot_GetLineInventorySummary @LocationId = @Area;
DECLARE @EN NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM @E);
EXEC test.Assert_IsEqual @TestName = N'[Empty] NULL / area-level location -> empty', @Expected = N'0', @Actual = @EN;
GO

-- ---- cleanup ----
DELETE FROM Lots.Lot WHERE LotName LIKE N'T099-%';
DELETE il FROM Parts.ItemLocation il INNER JOIN Parts.Item i ON i.Id = il.ItemId WHERE i.PartNumber LIKE N'T099-%';
DELETE FROM Parts.Item WHERE PartNumber LIKE N'T099-%';
GO

EXEC test.EndTestFile;
GO
