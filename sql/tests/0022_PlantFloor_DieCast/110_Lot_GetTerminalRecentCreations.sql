-- =============================================
-- File:         0022_PlantFloor_DieCast/110_Lot_GetTerminalRecentCreations.sql
-- Author:       Blue Ridge Automation
-- Created:      2026-11-13
-- Description:  Lots.Lot_GetTerminalRecentCreations (the die-cast right-rail activity log) had no
--               test. This file pins what it returns, and migration 0122's index (stored-procedure
--               review) that makes it a seek instead of a heap scan.
--               Behaviour: only die-cast LOTs (ToolId NOT NULL) created AT the given terminal,
--               newest first by CreatedAt then Id DESC, TOP @TopN (default 15 when NULL / <= 0),
--               CreatedAt converted UTC to Eastern, CavityText '-' when the LOT has no cavity.
--               Index: IX_Lot_DieCastByTerminal is NONCLUSTERED, non-unique, filtered on
--               ToolId IS NOT NULL, keyed (CreatedAtTerminalId, CreatedAt DESC, Id DESC), with NO
--               included columns (PieceCount is rewritten on every cavity credit, so it must not be
--               in this index).
--               Fixture terminals: DC1-M05 (A) and DC1-M01 (B).
-- =============================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0022_PlantFloor_DieCast/110_Lot_GetTerminalRecentCreations.sql';
GO

-- ---- cleanup ----
DELETE FROM Lots.Lot WHERE LotName LIKE N'STG-RC-%';
DELETE FROM Tools.Tool WHERE Code = N'TEST-RC-TOOL';
GO

-- ---- fixture ----
DECLARE @Now DATETIME2(3) = SYSUTCDATETIME();
DECLARE @A BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'DC1-M05');
DECLARE @B BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'DC1-M01');
DECLARE @Item BIGINT = (SELECT TOP 1 Id FROM Parts.Item ORDER BY Id);
DECLARE @ToolTypeId BIGINT = (SELECT Id FROM Tools.ToolType WHERE Code = N'Die');
DECLARE @ToolStatusActive BIGINT = (SELECT Id FROM Tools.ToolStatusCode WHERE Code = N'Active');
INSERT INTO Tools.Tool (ToolTypeId, Code, Name, StatusCodeId, CreatedAt, CreatedByUserId)
VALUES (@ToolTypeId, N'TEST-RC-TOOL', N'Recent-creations test die', @ToolStatusActive, SYSUTCDATETIME(), 1);
DECLARE @Tool BIGINT = SCOPE_IDENTITY();

-- At terminal A, die-cast: L1 14:00 UTC; L2a and L2b both 15:00 UTC (a tie: higher Id first); L3 16:00 UTC (newest).
-- At terminal A, NOT die-cast (ToolId NULL), 17:00 UTC -> excluded.  At terminal B, die-cast, 15:30 UTC -> not A's.
INSERT INTO Lots.Lot (LotName, ItemId, LotOriginTypeId, LotStatusId, PieceCount, InventoryAvailable, CurrentLocationId, ToolId, CreatedAtTerminalId, CreatedByUserId, CreatedAt) VALUES
    (N'STG-RC-L1',   @Item, 1, 1, 11, 11, @A, @Tool, @A,   1, '2026-01-15 14:00:00.000'),
    (N'STG-RC-L2a',  @Item, 1, 1, 12, 12, @A, @Tool, @A,   1, '2026-01-15 15:00:00.000'),
    (N'STG-RC-L2b',  @Item, 1, 1, 13, 13, @A, @Tool, @A,   1, '2026-01-15 15:00:00.000'),
    (N'STG-RC-L3',   @Item, 1, 1, 14, 14, @A, @Tool, @A,   1, '2026-01-15 16:00:00.000'),
    (N'STG-RC-NODC', @Item, 1, 1, 15, 15, @A, NULL,  @A,   1, '2026-01-15 17:00:00.000'),
    (N'STG-RC-B1',   @Item, 1, 1, 16, 16, @B, @Tool, @B,   1, '2026-01-15 15:30:00.000');
GO

DECLARE @A BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'DC1-M05');
DECLARE @R TABLE (RowNo INT IDENTITY(1,1), LotId BIGINT, LotName NVARCHAR(50), PieceCount INT, CavityText NVARCHAR(200), CreatedAt DATETIME2(3));
DECLARE @S NVARCHAR(200);

INSERT INTO @R (LotId, LotName, PieceCount, CavityText, CreatedAt) EXEC Lots.Lot_GetTerminalRecentCreations @TerminalLocationId = @A, @TopN = 15;
SET @S = ISNULL((SELECT STRING_AGG(LotName, N',') WITHIN GROUP (ORDER BY RowNo) FROM @R WHERE LotName LIKE N'STG-RC-%'), N'<none>');
EXEC test.Assert_IsEqual @TestName = N'[RecentCreations] die-cast LOTs of THIS terminal only, newest first, a CreatedAt tie broken by higher Id first',
    @Expected = N'STG-RC-L3,STG-RC-L2b,STG-RC-L2a,STG-RC-L1', @Actual = @S;
SET @S = ISNULL((SELECT CONVERT(NVARCHAR(30), CreatedAt, 121) FROM @R WHERE LotName = N'STG-RC-L3'), N'<null>');
EXEC test.Assert_IsEqual @TestName = N'[RecentCreations] CreatedAt is converted UTC to Eastern', @Expected = N'2026-01-15 11:00:00.000', @Actual = @S;
SET @S = ISNULL((SELECT CavityText FROM @R WHERE LotName = N'STG-RC-L3'), N'<null>');
EXEC test.Assert_IsEqual @TestName = N'[RecentCreations] a LOT with no cavity shows the "-" floor', @Expected = N'-', @Actual = @S;

DELETE FROM @R;
INSERT INTO @R (LotId, LotName, PieceCount, CavityText, CreatedAt) EXEC Lots.Lot_GetTerminalRecentCreations @TerminalLocationId = @A, @TopN = 2;
SET @S = ISNULL((SELECT STRING_AGG(LotName, N',') WITHIN GROUP (ORDER BY RowNo) FROM @R WHERE LotName LIKE N'STG-RC-%'), N'<none>');
EXEC test.Assert_IsEqual @TestName = N'[RecentCreations] @TopN = 2 returns only the two newest', @Expected = N'STG-RC-L3,STG-RC-L2b', @Actual = @S;

DELETE FROM @R;
INSERT INTO @R (LotId, LotName, PieceCount, CavityText, CreatedAt) EXEC Lots.Lot_GetTerminalRecentCreations @TerminalLocationId = @A, @TopN = 0;
SET @S = CAST((SELECT COUNT(*) FROM @R WHERE LotName LIKE N'STG-RC-%') AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[RecentCreations] @TopN = 0 falls back to the default 15 (all four of A''s LOTs)', @Expected = N'4', @Actual = @S;
GO

-- ---- migration 0122: the index definition ----
DECLARE @IxId INT = (SELECT index_id FROM sys.indexes WHERE object_id = OBJECT_ID(N'Lots.Lot') AND name = N'IX_Lot_DieCastByTerminal');
DECLARE @S NVARCHAR(400);

SET @S = CAST(CASE WHEN @IxId IS NULL THEN 0 ELSE 1 END AS NVARCHAR(1));
EXEC test.Assert_IsEqual @TestName = N'[0122] IX_Lot_DieCastByTerminal exists', @Expected = N'1', @Actual = @S;

SET @S = ISNULL((SELECT type_desc + N'/unique=' + CAST(is_unique AS NVARCHAR(1)) + N'/filtered=' + CAST(has_filter AS NVARCHAR(1))
                 FROM sys.indexes WHERE object_id = OBJECT_ID(N'Lots.Lot') AND index_id = @IxId), N'<none>');
EXEC test.Assert_IsEqual @TestName = N'[0122] index is NONCLUSTERED, not unique, filtered', @Expected = N'NONCLUSTERED/unique=0/filtered=1', @Actual = @S;

SET @S = ISNULL((SELECT filter_definition FROM sys.indexes WHERE object_id = OBJECT_ID(N'Lots.Lot') AND index_id = @IxId), N'<none>');
EXEC test.Assert_IsEqual @TestName = N'[0122] filter is exactly ToolId IS NOT NULL (die-cast LOTs)', @Expected = N'([ToolId] IS NOT NULL)', @Actual = @S;

SET @S = ISNULL((SELECT STRING_AGG(c.name + CASE WHEN ic.is_descending_key = 1 THEN N' DESC' ELSE N'' END, N',') WITHIN GROUP (ORDER BY ic.key_ordinal)
                 FROM sys.index_columns ic JOIN sys.columns c ON c.object_id = ic.object_id AND c.column_id = ic.column_id
                 WHERE ic.object_id = OBJECT_ID(N'Lots.Lot') AND ic.index_id = @IxId AND ic.is_included_column = 0), N'<none>');
EXEC test.Assert_IsEqual @TestName = N'[0122] key is (CreatedAtTerminalId, CreatedAt DESC, Id DESC), the proc''s sort order',
    @Expected = N'CreatedAtTerminalId,CreatedAt DESC,Id DESC', @Actual = @S;

SET @S = CAST((SELECT COUNT(*) FROM sys.index_columns WHERE object_id = OBJECT_ID(N'Lots.Lot') AND index_id = @IxId AND is_included_column = 1) AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[0122] NO included columns (PieceCount is rewritten on every credit and must stay out)', @Expected = N'0', @Actual = @S;

SET @S = CAST((SELECT COUNT(*) FROM dbo.SchemaVersion WHERE MigrationId = N'0122_lot_diecast_by_terminal_index') AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[0122] migration recorded in dbo.SchemaVersion exactly once', @Expected = N'1', @Actual = @S;
GO

-- ---- cleanup ----
DELETE FROM Lots.Lot WHERE LotName LIKE N'STG-RC-%';
DELETE FROM Tools.Tool WHERE Code = N'TEST-RC-TOOL';
GO

EXEC test.EndTestFile;
GO
