-- =============================================
-- File:         0128_LotToolNotClosed/010_per_die_open_basket_reads.sql
-- Author:       Blue Ridge Automation
-- Created:      2026-11-16
-- Description:  Migration 0128 (IX_Lot_Tool_NotClosed) + Lots.Lot_GetOpenByTool v2.2
--               + Workorder.DieCast_GetShiftOutputBreakdown v3.3
--               + Tools.ToolAssignment_GetCellContext v1.2 (stored-procedure review).
--               The reads now reach a die's LOTs through an index filtered on the
--               literal LotStatusId <> 4, and the breakdown resolves its LOT set as the
--               UNION of "Open on the tool" and "credited this shift". This file pins
--               the status edges those rewrites could get wrong. It passes on the
--               previous versions too (same rows, same order):
--                 * the index exists with that filter, and Closed IS Id 4;
--                 * breakdown keeps a CLOSED basket credited this shift (it never
--                   reaches the index -- only the contribution half finds it), and a
--                   released (Good) one; drops Good / Hold / Closed baskets credited
--                   in another shift or never; drops another die's baskets credited
--                   this shift; row order unchanged;
--                 * open-by-tool and the cell's OpenBasketCount see Open only.
--               Fixture: hand-built (statuses are the point): die A with cavities a, b
--               mounted on a free die-cast cell, die B with one cavity, nine LOTs, one
--               open and one closed shift, contributions inserted directly.
-- =============================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0128_LotToolNotClosed/010_per_die_open_basket_reads.sql';
GO

-- ---- cleanup (idempotent, FK-safe) ----
DELETE c FROM Workorder.DieCastContribution c INNER JOIN Lots.Lot l ON l.Id = c.LotId WHERE l.LotName LIKE N'T0128-%';
DELETE FROM Lots.Lot WHERE LotName LIKE N'T0128-%';
DELETE ta FROM Tools.ToolAssignment ta INNER JOIN Tools.Tool t ON t.Id = ta.ToolId WHERE t.Code IN (N'TEST-0128-A', N'TEST-0128-B');
DELETE tc FROM Tools.ToolCavity tc INNER JOIN Tools.Tool t ON t.Id = tc.ToolId WHERE t.Code IN (N'TEST-0128-A', N'TEST-0128-B');
DELETE FROM Tools.Tool WHERE Code IN (N'TEST-0128-A', N'TEST-0128-B');
DELETE FROM Oee.Shift WHERE Remarks = N'TEST-0128';
GO

-- ---- the index and the literal it depends on ----
DECLARE @f NVARCHAR(200) = (SELECT filter_definition FROM sys.indexes
    WHERE object_id = OBJECT_ID(N'Lots.Lot') AND name = N'IX_Lot_Tool_NotClosed');
EXEC test.Assert_IsEqual N'[0128] IX_Lot_Tool_NotClosed filters die-cast, not Closed',
    N'([ToolId] IS NOT NULL AND [LotStatusId]<>(4))', @f;
DECLARE @closed NVARCHAR(20) = (SELECT Code FROM Lots.LotStatusCode WHERE Id = 4);
EXEC test.Assert_IsEqual N'[0128] LotStatusId 4 is Closed', N'Closed', @closed;
GO

-- ---- fixture + assertions (one batch so the locals stay in scope) ----
DECLARE @Cell BIGINT = (
    SELECT TOP 1 c.Id FROM Location.Location c
    INNER JOIN Location.LocationTypeDefinition d ON d.Id = c.LocationTypeDefinitionId
    WHERE d.Code = N'DieCastMachine' AND c.DeprecatedAt IS NULL
      AND NOT EXISTS (SELECT 1 FROM Tools.ToolAssignment ta WHERE ta.CellLocationId = c.Id AND ta.ReleasedAt IS NULL)
    ORDER BY c.Id);
DECLARE @Item BIGINT = (SELECT TOP 1 Id FROM Parts.Item WHERE DeprecatedAt IS NULL ORDER BY Id);
IF @Cell IS NULL OR @Item IS NULL
    RAISERROR(N'0128/010 fixture: no free die-cast cell or no item -- BLOCKED.', 16, 1);

DECLARE @Die BIGINT = (SELECT Id FROM Tools.ToolType WHERE Code = N'Die');
DECLARE @ToolActive BIGINT = (SELECT Id FROM Tools.ToolStatusCode WHERE Code = N'Active');
DECLARE @CavActive BIGINT = (SELECT Id FROM Tools.ToolCavityStatusCode WHERE Code = N'Active');
INSERT INTO Tools.Tool (ToolTypeId, Code, Name, StatusCodeId, CreatedAt, CreatedByUserId)
VALUES (@Die, N'TEST-0128-A', N'0128 die A', @ToolActive, SYSUTCDATETIME(), 1);
DECLARE @ToolA BIGINT = SCOPE_IDENTITY();
INSERT INTO Tools.Tool (ToolTypeId, Code, Name, StatusCodeId, CreatedAt, CreatedByUserId)
VALUES (@Die, N'TEST-0128-B', N'0128 die B', @ToolActive, SYSUTCDATETIME(), 1);
DECLARE @ToolB BIGINT = SCOPE_IDENTITY();
INSERT INTO Tools.ToolCavity (ToolId, CavityCode, StatusCodeId, ItemId, CreatedAt, CreatedByUserId)
VALUES (@ToolA, N'a', @CavActive, @Item, SYSUTCDATETIME(), 1);
DECLARE @CavA BIGINT = SCOPE_IDENTITY();
INSERT INTO Tools.ToolCavity (ToolId, CavityCode, StatusCodeId, ItemId, CreatedAt, CreatedByUserId)
VALUES (@ToolA, N'b', @CavActive, @Item, SYSUTCDATETIME(), 1);
DECLARE @CavB BIGINT = SCOPE_IDENTITY();
INSERT INTO Tools.ToolCavity (ToolId, CavityCode, StatusCodeId, ItemId, CreatedAt, CreatedByUserId)
VALUES (@ToolB, N'a', @CavActive, @Item, SYSUTCDATETIME(), 1);
DECLARE @CavBa BIGINT = SCOPE_IDENTITY();
INSERT INTO Tools.ToolAssignment (ToolId, CellLocationId, AssignedAt, AssignedByUserId)
VALUES (@ToolA, @Cell, SYSUTCDATETIME(), 1);

-- shifts: the open one (resolve or mint -- Oee.Shift allows one open) and a closed one
DECLARE @ScheduleId BIGINT = (SELECT TOP 1 Id FROM Oee.ShiftSchedule ORDER BY Id);
IF @ScheduleId IS NULL
BEGIN
    INSERT INTO Oee.ShiftSchedule (Name, StartTime, EndTime, DaysOfWeekBitmask, EffectiveFrom, CreatedByUserId)
    VALUES (N'0128/010 Test Schedule', '06:00', '14:00', 31, '2026-01-01', 1);
    SET @ScheduleId = SCOPE_IDENTITY();
END
DECLARE @Shift BIGINT = (SELECT TOP 1 Id FROM Oee.Shift WHERE ActualEnd IS NULL ORDER BY ActualStart DESC);
IF @Shift IS NULL
BEGIN
    INSERT INTO Oee.Shift (ShiftScheduleId, ActualStart, Remarks) VALUES (@ScheduleId, DATEADD(HOUR, -2, SYSUTCDATETIME()), N'TEST-0128');
    SET @Shift = SCOPE_IDENTITY();
END
INSERT INTO Oee.Shift (ShiftScheduleId, ActualStart, ActualEnd, Remarks)
VALUES (@ScheduleId, DATEADD(DAY, -30, SYSUTCDATETIME()), DATEADD(HOUR, 8, DATEADD(DAY, -30, SYSUTCDATETIME())), N'TEST-0128');
DECLARE @OldShift BIGINT = SCOPE_IDENTITY();

-- nine LOTs. Status ids by code, never by number.
DECLARE @Open BIGINT = (SELECT Id FROM Lots.LotStatusCode WHERE Code = N'Open');
DECLARE @Good BIGINT = (SELECT Id FROM Lots.LotStatusCode WHERE Code = N'Good');
DECLARE @Hold BIGINT = (SELECT Id FROM Lots.LotStatusCode WHERE Code = N'Hold');
DECLARE @Clsd BIGINT = (SELECT Id FROM Lots.LotStatusCode WHERE Code = N'Closed');
DECLARE @Mfg  BIGINT = (SELECT Id FROM Lots.LotOriginType WHERE Code = N'Manufactured');
INSERT INTO Lots.Lot (LotName, ItemId, LotOriginTypeId, LotStatusId, PieceCount, MaxPieceCount, CurrentLocationId,
                      ToolId, ToolCavityId, CreatedAtTerminalId, CreatedByUserId, CreatedAt)
VALUES (N'T0128-1', @Item, @Mfg, @Open, 10, 100, @Cell, @ToolA, @CavA,  @Cell, 1, SYSUTCDATETIME()),  -- A/a Open, credited this shift  -> in
       (N'T0128-2', @Item, @Mfg, @Clsd, 90, 100, @Cell, @ToolA, @CavA,  @Cell, 1, SYSUTCDATETIME()),  -- A/a Closed, credited this shift -> in
       (N'T0128-3', @Item, @Mfg, @Clsd, 90, 100, @Cell, @ToolA, @CavA,  @Cell, 1, SYSUTCDATETIME()),  -- A/a Closed, credited old shift  -> out (this shift)
       (N'T0128-4', @Item, @Mfg, @Good, 95, 100, @Cell, @ToolA, @CavB,  @Cell, 1, SYSUTCDATETIME()),  -- A/b Good, credited this shift   -> in
       (N'T0128-5', @Item, @Mfg, @Good, 95, 100, @Cell, @ToolA, @CavB,  @Cell, 1, SYSUTCDATETIME()),  -- A/b Good, never credited       -> out
       (N'T0128-6', @Item, @Mfg, @Hold, 95, 100, @Cell, @ToolA, @CavB,  @Cell, 1, SYSUTCDATETIME()),  -- A/b Hold, credited old shift   -> out (this shift)
       (N'T0128-7', @Item, @Mfg, @Open,  0, 100, @Cell, @ToolA, @CavB,  @Cell, 1, SYSUTCDATETIME()),  -- A/b Open, never credited       -> in
       (N'T0128-8', @Item, @Mfg, @Open, 20, 100, @Cell, @ToolB, @CavBa, @Cell, 1, SYSUTCDATETIME()),  -- B Open, credited this shift    -> never on A
       (N'T0128-9', @Item, @Mfg, @Clsd, 90, 100, @Cell, @ToolB, @CavBa, @Cell, 1, SYSUTCDATETIME());  -- B Closed, credited this shift  -> never on A

DECLARE @Src BIGINT = (SELECT Id FROM Oee.ShiftAttributionSource WHERE Code = N'Derived');
INSERT INTO Workorder.DieCastContribution (LotId, ShiftId, PieceDelta, AppUserId, EventAt, CellLocationId,
                                           ShotCounterReading, ToolCavityId, ShiftAttributionSourceId)
SELECT l.Id, x.ShiftId, 10, 1, SYSUTCDATETIME(), @Cell, 50, l.ToolCavityId, @Src
FROM (VALUES (N'T0128-1', @Shift), (N'T0128-2', @Shift), (N'T0128-3', @OldShift), (N'T0128-4', @Shift),
             (N'T0128-6', @OldShift), (N'T0128-8', @Shift), (N'T0128-9', @Shift)) x(LotName, ShiftId)
INNER JOIN Lots.Lot l ON l.LotName = x.LotName;

-- ---- breakdown, this shift ----
DECLARE @BD TABLE (ToolCavityId BIGINT, CavityCode NVARCHAR(4), LotId BIGINT, LotName NVARCHAR(50), IsOpen BIT,
    PriorGoodThisShift INT, ProposedGood INT, MaxHeadroom INT, ItemId BIGINT, CavityDescription NVARCHAR(500),
    CreditedThrough INT, NewShots INT, CavityStatusCode NVARCHAR(30), ConfiguredItemId BIGINT, ConfiguredPartNumber NVARCHAR(50),
    PriorScrapThisShift INT, DieWideShots INT, IsPending BIT, CreditedWithoutReading INT, IsCavityCarrier BIT,
    RowNo INT IDENTITY(1,1));
INSERT INTO @BD (ToolCavityId, CavityCode, LotId, LotName, IsOpen, PriorGoodThisShift, ProposedGood, MaxHeadroom, ItemId,
    CavityDescription, CreditedThrough, NewShots, CavityStatusCode, ConfiguredItemId, ConfiguredPartNumber,
    PriorScrapThisShift, DieWideShots, IsPending, CreditedWithoutReading, IsCavityCarrier)
EXEC Workorder.DieCast_GetShiftOutputBreakdown @ToolId = @ToolA, @ShiftId = @Shift, @CounterReading = 80, @CellLocationId = @Cell;
DECLARE @s NVARCHAR(400) = (SELECT STRING_AGG(CavityCode + N':' + LotName + N':' + CAST(IsOpen AS NVARCHAR(1)), N',') WITHIN GROUP (ORDER BY RowNo) FROM @BD);
EXEC test.Assert_IsEqual N'[Breakdown] this shift: Open + Closed-credited + Good-credited + Open-uncredited, in order',
    N'a:T0128-1:1,a:T0128-2:0,b:T0128-7:1,b:T0128-4:0', @s;
SET @s = (SELECT CAST(PriorGoodThisShift AS NVARCHAR(10)) FROM @BD WHERE LotName = N'T0128-2');
EXEC test.Assert_IsEqual N'[Breakdown] Closed basket credited this shift keeps its shift credit', N'10', @s;
SET @s = (SELECT STRING_AGG(LotName + N':' + CAST(IsCavityCarrier AS NVARCHAR(1)), N',') WITHIN GROUP (ORDER BY RowNo) FROM @BD);
EXEC test.Assert_IsEqual N'[Breakdown] this shift: the open basket carries each cavity',
    N'T0128-1:1,T0128-2:0,T0128-7:1,T0128-4:0', @s;

-- ---- breakdown, the old shift (no cell: falls back to the mounted cell) ----
DELETE FROM @BD;
INSERT INTO @BD (ToolCavityId, CavityCode, LotId, LotName, IsOpen, PriorGoodThisShift, ProposedGood, MaxHeadroom, ItemId,
    CavityDescription, CreditedThrough, NewShots, CavityStatusCode, ConfiguredItemId, ConfiguredPartNumber,
    PriorScrapThisShift, DieWideShots, IsPending, CreditedWithoutReading, IsCavityCarrier)
EXEC Workorder.DieCast_GetShiftOutputBreakdown @ToolId = @ToolA, @ShiftId = @OldShift, @CounterReading = 80;
SET @s = (SELECT STRING_AGG(CavityCode + N':' + LotName + N':' + CAST(IsOpen AS NVARCHAR(1)), N',') WITHIN GROUP (ORDER BY RowNo) FROM @BD);
EXEC test.Assert_IsEqual N'[Breakdown] old shift: Open baskets + Closed / Hold credited then',
    N'a:T0128-1:1,a:T0128-3:0,b:T0128-7:1,b:T0128-6:0', @s;

-- ---- breakdown, die B only sees its own ----
DELETE FROM @BD;
INSERT INTO @BD (ToolCavityId, CavityCode, LotId, LotName, IsOpen, PriorGoodThisShift, ProposedGood, MaxHeadroom, ItemId,
    CavityDescription, CreditedThrough, NewShots, CavityStatusCode, ConfiguredItemId, ConfiguredPartNumber,
    PriorScrapThisShift, DieWideShots, IsPending, CreditedWithoutReading, IsCavityCarrier)
EXEC Workorder.DieCast_GetShiftOutputBreakdown @ToolId = @ToolB, @ShiftId = @Shift, @CounterReading = 80, @CellLocationId = @Cell;
SET @s = (SELECT STRING_AGG(LotName + N':' + CAST(IsOpen AS NVARCHAR(1)), N',') WITHIN GROUP (ORDER BY RowNo) FROM @BD);
EXEC test.Assert_IsEqual N'[Breakdown] die B: its own Open + Closed-credited only', N'T0128-8:1,T0128-9:0', @s;

-- ---- open-by-tool: Open only, one row per cavity ----
DECLARE @OB TABLE (ToolCavityId BIGINT, CavityCode NVARCHAR(4), LotId BIGINT, LotName NVARCHAR(50), PieceCount INT, MaxPieceCount INT,
    BelowStandardRelease BIT, OpenedAt DATETIME2(3), ContributorCount INT, CavityDescription NVARCHAR(500),
    CavityStatusCode NVARCHAR(30), ConfiguredItemId BIGINT, ConfiguredPartNumber NVARCHAR(50), RowNo INT IDENTITY(1,1));
INSERT INTO @OB (ToolCavityId, CavityCode, LotId, LotName, PieceCount, MaxPieceCount, BelowStandardRelease, OpenedAt,
    ContributorCount, CavityDescription, CavityStatusCode, ConfiguredItemId, ConfiguredPartNumber)
EXEC Lots.Lot_GetOpenByTool @ToolId = @ToolA;
SET @s = (SELECT STRING_AGG(CavityCode + N':' + ISNULL(LotName, N'-') + N':' + CAST(PieceCount AS NVARCHAR(10)) + N':' + CAST(ContributorCount AS NVARCHAR(10)), N',') WITHIN GROUP (ORDER BY RowNo) FROM @OB);
EXEC test.Assert_IsEqual N'[OpenByTool] die A: the Open basket on each cavity, nothing Good / Hold / Closed',
    N'a:T0128-1:10:1,b:T0128-7:0:0', @s;

-- a cavity whose baskets are all released or closed shows as basketless
UPDATE Lots.Lot SET LotStatusId = @Good WHERE LotName = N'T0128-7';
DELETE FROM @OB;
INSERT INTO @OB (ToolCavityId, CavityCode, LotId, LotName, PieceCount, MaxPieceCount, BelowStandardRelease, OpenedAt,
    ContributorCount, CavityDescription, CavityStatusCode, ConfiguredItemId, ConfiguredPartNumber)
EXEC Lots.Lot_GetOpenByTool @ToolId = @ToolA;
SET @s = (SELECT STRING_AGG(CavityCode + N':' + ISNULL(LotName, N'-') + N':' + CAST(PieceCount AS NVARCHAR(10)), N',') WITHIN GROUP (ORDER BY RowNo) FROM @OB);
EXEC test.Assert_IsEqual N'[OpenByTool] die A after b is released: cavity b basketless',
    N'a:T0128-1:10,b:-:0', @s;

-- ---- cell context: OpenBasketCount counts Open only ----
DECLARE @CC TABLE (IsMountTarget BIT, ToolAssignmentId BIGINT, ToolId BIGINT, ToolCode NVARCHAR(50), ToolName NVARCHAR(100),
    ToolTypeCode NVARCHAR(50), AssignedAt DATETIME2(3), AssignedBy NVARCHAR(200), OpenBasketCount INT);
INSERT INTO @CC EXEC Tools.ToolAssignment_GetCellContext @CellLocationId = @Cell;
SET @s = (SELECT ToolCode + N':' + CAST(OpenBasketCount AS NVARCHAR(10)) FROM @CC);
EXEC test.Assert_IsEqual N'[CellContext] one Open basket left on die A (Good / Hold / Closed not counted)', N'TEST-0128-A:1', @s;

UPDATE Lots.Lot SET LotStatusId = @Open WHERE LotName = N'T0128-7';
DELETE FROM @CC;
INSERT INTO @CC EXEC Tools.ToolAssignment_GetCellContext @CellLocationId = @Cell;
SET @s = (SELECT CAST(OpenBasketCount AS NVARCHAR(10)) FROM @CC);
EXEC test.Assert_IsEqual N'[CellContext] two Open baskets on die A', N'2', @s;
GO

-- ---- cleanup ----
DELETE c FROM Workorder.DieCastContribution c INNER JOIN Lots.Lot l ON l.Id = c.LotId WHERE l.LotName LIKE N'T0128-%';
DELETE FROM Lots.Lot WHERE LotName LIKE N'T0128-%';
DELETE ta FROM Tools.ToolAssignment ta INNER JOIN Tools.Tool t ON t.Id = ta.ToolId WHERE t.Code IN (N'TEST-0128-A', N'TEST-0128-B');
DELETE tc FROM Tools.ToolCavity tc INNER JOIN Tools.Tool t ON t.Id = tc.ToolId WHERE t.Code IN (N'TEST-0128-A', N'TEST-0128-B');
DELETE FROM Tools.Tool WHERE Code IN (N'TEST-0128-A', N'TEST-0128-B');
DELETE FROM Oee.Shift WHERE Remarks = N'TEST-0128';
GO

EXEC test.EndTestFile;
GO
