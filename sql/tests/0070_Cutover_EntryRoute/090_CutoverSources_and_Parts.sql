-- =============================================
-- File:         0070_Cutover_EntryRoute/090_CutoverSources_and_Parts.sql
-- Description:  The cutover scan's first pick -- WHERE the stock is -- and the
--               part list that pick drives (2026-09-17).
--
--               Location_ListCutoverSources: the warehouse (the default), the
--               two trim stores under their floor names, then every active
--               production line. IsLine tells the screen whether to ask for an
--               entry step and a destination: a store is its own destination.
--
--               Item_ListForCutoverLocation: a line or trim store lists the
--               parts eligible there (ancestor cascade, as today). A cutover
--               destination with NOTHING eligible up its chain -- the
--               warehouse -- lists every active part: it can hold anything.
--               Components only (v1.1): other part types have no die/cavity.
-- =============================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0070_Cutover_EntryRoute/090_CutoverSources_and_Parts.sql';
GO

CREATE TABLE #S (Rn INT IDENTITY(1,1), Id BIGINT, Code NVARCHAR(100), Name NVARCHAR(400),
                 DisplayName NVARCHAR(800), IsLine BIT, IsDefault BIT);
INSERT INTO #S (Id, Code, Name, DisplayName, IsLine, IsDefault)
EXEC Location.Location_ListCutoverSources;

-- (1) Warehouse first, and the only default.
DECLARE @a1 NVARCHAR(100) = (SELECT Code FROM #S WHERE Rn = 1);
EXEC test.Assert_IsEqual @TestName = N'[Src] warehouse sorts first',
    @Expected = N'WHSE', @Actual = @a1;
DECLARE @a2 NVARCHAR(100) = (SELECT STRING_AGG(Code, N',') FROM #S WHERE IsDefault = 1);
EXEC test.Assert_IsEqual @TestName = N'[Src] warehouse is the only default',
    @Expected = N'WHSE', @Actual = @a2;

-- (2) The trim stores follow, under their floor names, and are not lines.
DECLARE @a3 NVARCHAR(800) = (SELECT DisplayName + N'|' + CAST(IsLine AS NVARCHAR(1)) FROM #S WHERE Code = N'TRIM1-STORE');
EXEC test.Assert_IsEqual @TestName = N'[Src] Trim Shop 1 store is Tumble, not a line',
    @Expected = N'Tumble Trim Storage|0', @Actual = @a3;
DECLARE @a4 NVARCHAR(800) = (SELECT DisplayName + N'|' + CAST(IsLine AS NVARCHAR(1)) FROM #S WHERE Code = N'TRIM2-STORE');
EXEC test.Assert_IsEqual @TestName = N'[Src] Trim Shop 2 store is Blast, not a line',
    @Expected = N'Blast Trim Storage|0', @Actual = @a4;

-- (3) The three stores come before every line.
DECLARE @a5 NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM #S
                            WHERE Rn <= 3 AND Code IN (N'WHSE', N'TRIM1-STORE', N'TRIM2-STORE'));
EXEC test.Assert_IsEqual @TestName = N'[Src] the three stores come before the lines',
    @Expected = N'3', @Actual = @a5;

-- (4) Every active production line is offered once, flagged IsLine, labelled
--     '<Code> - <Name>' as the old line dropdown was. Nothing else is offered.
CREATE TABLE #L (Id BIGINT, Code NVARCHAR(100), Name NVARCHAR(400), ParentLocationId BIGINT, SortOrder INT);
INSERT INTO #L EXEC Location.Location_ListProductionLines;
DECLARE @a6 NVARCHAR(20) = (SELECT CAST(COUNT(*) AS NVARCHAR(20)) FROM #S s INNER JOIN #L l ON l.Id = s.Id
                            WHERE s.IsLine = 1 AND s.DisplayName = l.Code + N' - ' + l.Name);
DECLARE @nLines INT = (SELECT COUNT(*) FROM #L);
DECLARE @a6e NVARCHAR(20) = CAST(@nLines AS NVARCHAR(20));
EXEC test.Assert_IsEqual @TestName = N'[Src] every production line is offered as a line',
    @Expected = @a6e, @Actual = @a6;
DECLARE @a7 NVARCHAR(20) = (SELECT CAST(COUNT(*) AS NVARCHAR(20)) FROM #S);
DECLARE @a7e NVARCHAR(20) = CAST(@nLines + 3 AS NVARCHAR(20));
EXEC test.Assert_IsEqual @TestName = N'[Src] nothing else is offered',
    @Expected = @a7e, @Actual = @a7;

DROP TABLE #S;
DROP TABLE #L;
GO

-- ---- Item_ListForCutoverLocation ----
DECLARE @Whse BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'WHSE');
DECLARE @T1   BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'TRIM1');
DECLARE @T1S  BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'TRIM1-STORE');
DECLARE @Line BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MA1-5GOF');

-- A Component and a Finished Good, neither already eligible at Trim Shop 1,
-- both made eligible there for this file.
DECLARE @Item BIGINT = (
    SELECT TOP 1 i.Id FROM Parts.Item i
    INNER JOIN Parts.ItemType it ON it.Id = i.ItemTypeId
    WHERE i.DeprecatedAt IS NULL AND it.Code = N'Component'
      AND NOT EXISTS (SELECT 1 FROM Parts.v_EffectiveItemLocation e
                      WHERE e.ItemId = i.Id
                        AND e.LocationId IN (SELECT LocationId FROM Location.ufn_AncestorLocationIds(@T1S)))
    ORDER BY i.Id);
DECLARE @Fg BIGINT = (
    SELECT TOP 1 i.Id FROM Parts.Item i
    INNER JOIN Parts.ItemType it ON it.Id = i.ItemTypeId
    WHERE i.DeprecatedAt IS NULL AND it.Code = N'FinishedGood'
      AND NOT EXISTS (SELECT 1 FROM Parts.v_EffectiveItemLocation e
                      WHERE e.ItemId = i.Id
                        AND e.LocationId IN (SELECT LocationId FROM Location.ufn_AncestorLocationIds(@T1S)))
    ORDER BY i.Id);
INSERT INTO Parts.ItemLocation (ItemId, LocationId, CreatedAt)
VALUES (@Item, @T1, SYSUTCDATETIME()), (@Fg, @T1, SYSUTCDATETIME());

CREATE TABLE #I (Id BIGINT, PartNumber NVARCHAR(100), Description NVARCHAR(1000),
                 MaxLotSize INT, MaxParts INT);
CREATE TABLE #E (Id BIGINT, PartNumber NVARCHAR(100), Description NVARCHAR(1000),
                 MaxLotSize INT, MaxParts INT);

-- (5) The warehouse (nothing eligible up its chain) lists every active
--     Component, and nothing else.
INSERT INTO #I EXEC Parts.Item_ListForCutoverLocation @LocationId = @Whse;
DECLARE @b1 NVARCHAR(20) = (SELECT CAST(COUNT(*) AS NVARCHAR(20)) FROM #I);
DECLARE @b1e NVARCHAR(20) = (SELECT CAST(COUNT(*) AS NVARCHAR(20)) FROM Parts.Item i
                             INNER JOIN Parts.ItemType it ON it.Id = i.ItemTypeId
                             WHERE i.DeprecatedAt IS NULL AND it.Code = N'Component');
EXEC test.Assert_IsEqual @TestName = N'[Parts] warehouse lists every active Component',
    @Expected = @b1e, @Actual = @b1;
DECLARE @b1n NVARCHAR(20) = (SELECT CAST(COUNT(*) AS NVARCHAR(20)) FROM #I x
                             INNER JOIN Parts.Item i ON i.Id = x.Id
                             INNER JOIN Parts.ItemType it ON it.Id = i.ItemTypeId
                             WHERE it.Code <> N'Component');
EXEC test.Assert_IsEqual @TestName = N'[Parts] warehouse lists no other part type',
    @Expected = N'0', @Actual = @b1n;

-- (6) A trim store lists exactly the eligible Components there.
DELETE FROM #I;
INSERT INTO #I EXEC Parts.Item_ListForCutoverLocation @LocationId = @T1S;
INSERT INTO #E EXEC Parts.Item_ListEligibleForLocation @LocationId = @T1S;
DECLARE @b2 NVARCHAR(20) = (SELECT CAST(COUNT(*) AS NVARCHAR(20)) FROM #I);
DECLARE @b2e NVARCHAR(20) = (SELECT CAST(COUNT(*) AS NVARCHAR(20)) FROM #E e
                             INNER JOIN Parts.Item i ON i.Id = e.Id
                             INNER JOIN Parts.ItemType it ON it.Id = i.ItemTypeId
                             WHERE it.Code = N'Component');
EXEC test.Assert_IsEqual @TestName = N'[Parts] trim store lists its eligible Components',
    @Expected = @b2e, @Actual = @b2;
DECLARE @b3 NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM #I WHERE Id = @Item);
EXEC test.Assert_IsEqual @TestName = N'[Parts] trim store includes a shop-tier eligible Component',
    @Expected = N'1', @Actual = @b3;
DECLARE @b3f NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM #I WHERE Id = @Fg);
EXEC test.Assert_IsEqual @TestName = N'[Parts] an eligible Finished Good is not offered',
    @Expected = N'0', @Actual = @b3f;

-- (7) A line lists exactly its eligible Components -- no fallback, even if
--     that is nothing.
DELETE FROM #I; DELETE FROM #E;
INSERT INTO #I EXEC Parts.Item_ListForCutoverLocation @LocationId = @Line;
INSERT INTO #E EXEC Parts.Item_ListEligibleForLocation @LocationId = @Line;
DECLARE @b4 NVARCHAR(20) = (SELECT CAST(COUNT(*) AS NVARCHAR(20)) FROM #I);
DECLARE @b4e NVARCHAR(20) = (SELECT CAST(COUNT(*) AS NVARCHAR(20)) FROM #E e
                             INNER JOIN Parts.Item i ON i.Id = e.Id
                             INNER JOIN Parts.ItemType it ON it.Id = i.ItemTypeId
                             WHERE it.Code = N'Component');
EXEC test.Assert_IsEqual @TestName = N'[Parts] a line lists its eligible Components only',
    @Expected = @b4e, @Actual = @b4;

-- (8) NULL location lists nothing.
DELETE FROM #I;
INSERT INTO #I EXEC Parts.Item_ListForCutoverLocation @LocationId = NULL;
DECLARE @b5 NVARCHAR(20) = (SELECT CAST(COUNT(*) AS NVARCHAR(20)) FROM #I);
EXEC test.Assert_IsEqual @TestName = N'[Parts] NULL location lists nothing',
    @Expected = N'0', @Actual = @b5;

DROP TABLE #I;
DROP TABLE #E;
DELETE FROM Parts.ItemLocation WHERE ItemId IN (@Item, @Fg) AND LocationId = @T1;
GO

EXEC test.EndTestFile;
GO
