-- =============================================
-- File:         0069_Aggregate_Reports/060_reject_detail_page.sql
-- Author:       Blue Ridge Automation
-- Description:  FDS-12-006 Rejects -- Transaction Detail: the page shape.
--
--               Pins what Quality.Reject_SearchDetail v1.2 had to keep when
--               it moved the LOT join and the shift OUTER APPLY after the
--               TOP (they used to run for every row in the window):
--                 * TotalCount counts the WHOLE window, not the page;
--                 * the page is the newest @LimitRows rows, ordered
--                   RecordedAt DESC then Id DESC (the tie-break is pinned);
--                 * ShiftName comes from the LOT's LATEST DieCastContribution
--                   (EventAt DESC, Id DESC), and is NULL for a LOT with none
--                   and for a lot-free row;
--                 * LotName resolves for a LOT row and is NULL lot-free.
--               Passes on v1.1 and v1.2.
--
--               All fixture rejects sit in one dedicated past window
--               (2001-03-15 Eastern) so nothing else in the database is
--               counted.
-- =============================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0069_Aggregate_Reports/060_reject_detail_page.sql';
GO

IF OBJECT_ID(N'tempdb..#SF') IS NOT NULL DROP TABLE #SF;
CREATE TABLE #SF (Tag NVARCHAR(30) PRIMARY KEY, Val BIGINT);
IF OBJECT_ID(N'tempdb..#RD') IS NOT NULL DROP TABLE #RD;
CREATE TABLE #RD (
    RejectEventId BIGINT, LotId BIGINT, LotName NVARCHAR(50), ItemPartNumber NVARCHAR(100),
    RecordedAt DATETIME2(3), OperatorName NVARCHAR(200), ShiftName NVARCHAR(100),
    DefectCode NVARCHAR(20), DefectDescription NVARCHAR(500), ChargeToPartyName NVARCHAR(100),
    Quantity INT, IsNonRejectScrap BIT, RecordedAtLocationName NVARCHAR(200), TotalCount INT,
    Seq INT IDENTITY(1, 1)
);
GO

-- ---- Fixture -----------------------------------------------------------
DECLARE @ItemId BIGINT, @CellA BIGINT, @LotA BIGINT, @LotB BIGINT;
DECLARE @OriginRcv BIGINT = (SELECT Id FROM Lots.LotOriginType WHERE Code = N'Received');
DECLARE @UserId    BIGINT = (SELECT MIN(Id) FROM Location.AppUser);
DECLARE @Dc        BIGINT = (SELECT Id FROM Quality.DefectCode WHERE Code = N'001');
DECLARE @Derived   BIGINT = (SELECT Id FROM Oee.ShiftAttributionSource WHERE Code = N'Derived');

SELECT TOP 1 @ItemId = eil.ItemId, @CellA = eil.LocationId
FROM Parts.v_EffectiveItemLocation eil
WHERE eil.ItemId IN (SELECT Id FROM Parts.Item WHERE MaxLotSize IS NULL)
ORDER BY eil.LocationId;

DECLARE @cr TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT, MintedLotName NVARCHAR(50));
INSERT INTO @cr EXEC Lots.Lot_Create @ItemId = @ItemId, @LotOriginTypeId = @OriginRcv,
    @CurrentLocationId = @CellA, @PieceCount = 100, @AppUserId = @UserId,
    @VendorLotNumber = N'VND-RJP-A';
SELECT @LotA = NewId FROM @cr;
DELETE FROM @cr;
INSERT INTO @cr EXEC Lots.Lot_Create @ItemId = @ItemId, @LotOriginTypeId = @OriginRcv,
    @CurrentLocationId = @CellA, @PieceCount = 100, @AppUserId = @UserId,
    @VendorLotNumber = N'VND-RJP-B';
SELECT @LotB = NewId FROM @cr;

-- Two schedules, one shift each. LOT A's latest contribution is in the
-- "late" shift; its earlier one is in the "early" shift. LOT B has none.
DECLARE @SchEarly BIGINT, @SchLate BIGINT, @ShEarly BIGINT, @ShLate BIGINT;
INSERT INTO Oee.ShiftSchedule (Name, StartTime, EndTime, DaysOfWeekBitmask, EffectiveFrom, CreatedByUserId)
VALUES (N'RJP-Early', '06:00', '14:00', 127, '2001-01-01', @UserId);
SET @SchEarly = SCOPE_IDENTITY();
INSERT INTO Oee.ShiftSchedule (Name, StartTime, EndTime, DaysOfWeekBitmask, EffectiveFrom, CreatedByUserId)
VALUES (N'RJP-Late', '14:00', '22:00', 127, '2001-01-01', @UserId);
SET @SchLate = SCOPE_IDENTITY();
INSERT INTO Oee.Shift (ShiftScheduleId, ActualStart, ActualEnd, CreatedAt)
VALUES (@SchEarly, '2001-03-15T11:00:00', '2001-03-15T19:00:00', SYSUTCDATETIME());
SET @ShEarly = SCOPE_IDENTITY();
INSERT INTO Oee.Shift (ShiftScheduleId, ActualStart, ActualEnd, CreatedAt)
VALUES (@SchLate, '2001-03-15T19:00:00', '2001-03-16T03:00:00', SYSUTCDATETIME());
SET @ShLate = SCOPE_IDENTITY();

-- Inserted latest-first so the latest row does NOT have the highest Id:
-- the pick must follow EventAt, not insertion order.
INSERT INTO Workorder.DieCastContribution (LotId, ShiftId, PieceDelta, AppUserId, EventAt, ShiftAttributionSourceId)
VALUES (@LotA, @ShLate,  5, @UserId, '2001-03-15T20:00:00', @Derived);
INSERT INTO Workorder.DieCastContribution (LotId, ShiftId, PieceDelta, AppUserId, EventAt, ShiftAttributionSourceId)
VALUES (@LotA, @ShEarly, 5, @UserId, '2001-03-15T12:00:00', @Derived);

-- Five rejects, all on 2001-03-15 Eastern (EST = UTC-5). R3 and R4 share a
-- timestamp, so their order is the Id DESC tie-break.
DECLARE @R1 BIGINT, @R2 BIGINT, @R3 BIGINT, @R4 BIGINT, @R5 BIGINT;
INSERT INTO Workorder.RejectEvent (LotId, ItemId, DefectCodeId, Quantity, AppUserId, RecordedAt)
VALUES (@LotA, @ItemId, @Dc, 1, @UserId, '2001-03-15T13:00:00');
SET @R1 = SCOPE_IDENTITY();
INSERT INTO Workorder.RejectEvent (LotId, ItemId, DefectCodeId, Quantity, AppUserId, RecordedAt)
VALUES (@LotB, @ItemId, @Dc, 2, @UserId, '2001-03-15T14:00:00');
SET @R2 = SCOPE_IDENTITY();
INSERT INTO Workorder.RejectEvent (LotId, ItemId, DefectCodeId, Quantity, AppUserId, RecordedAt)
VALUES (@LotA, @ItemId, @Dc, 3, @UserId, '2001-03-15T21:00:00');
SET @R3 = SCOPE_IDENTITY();
INSERT INTO Workorder.RejectEvent (LotId, ItemId, DefectCodeId, Quantity, AppUserId, RecordedAt)
VALUES (NULL,  @ItemId, @Dc, 4, @UserId, '2001-03-15T21:00:00');
SET @R4 = SCOPE_IDENTITY();
INSERT INTO Workorder.RejectEvent (LotId, ItemId, DefectCodeId, Quantity, AppUserId, RecordedAt)
VALUES (@LotB, @ItemId, @Dc, 5, @UserId, '2001-03-15T22:00:00');
SET @R5 = SCOPE_IDENTITY();

INSERT INTO #SF (Tag, Val) VALUES
    (N'LotA', @LotA), (N'LotB', @LotB), (N'SchEarly', @SchEarly), (N'SchLate', @SchLate),
    (N'ShEarly', @ShEarly), (N'ShLate', @ShLate),
    (N'R1', @R1), (N'R2', @R2), (N'R3', @R3), (N'R4', @R4), (N'R5', @R5);
GO

-- ---- Page of 3 out of 5 ------------------------------------------------
DECLARE @n INT, @s NVARCHAR(400);
DECLARE @R1 BIGINT = (SELECT Val FROM #SF WHERE Tag = N'R1'),
        @R2 BIGINT = (SELECT Val FROM #SF WHERE Tag = N'R2'),
        @R3 BIGINT = (SELECT Val FROM #SF WHERE Tag = N'R3'),
        @R4 BIGINT = (SELECT Val FROM #SF WHERE Tag = N'R4'),
        @R5 BIGINT = (SELECT Val FROM #SF WHERE Tag = N'R5'),
        @LotA BIGINT = (SELECT Val FROM #SF WHERE Tag = N'LotA');

INSERT INTO #RD (RejectEventId, LotId, LotName, ItemPartNumber, RecordedAt, OperatorName, ShiftName,
                 DefectCode, DefectDescription, ChargeToPartyName, Quantity, IsNonRejectScrap,
                 RecordedAtLocationName, TotalCount)
EXEC Quality.Reject_SearchDetail @FromEt = '2001-03-15', @ToEt = '2001-03-15', @LimitRows = 3;

SELECT @n = COUNT(*) FROM #RD;
EXEC test.Assert_IsEqual @TestName = N'[RejectDetailPage] @LimitRows = 3 returns 3 rows',
    @Expected = N'3', @Actual = @n;

SELECT @n = COUNT(*) FROM #RD WHERE TotalCount = 5;
EXEC test.Assert_IsEqual @TestName = N'[RejectDetailPage] TotalCount counts the whole window (5) on every row',
    @Expected = N'3', @Actual = @n;

-- Newest first; R3/R4 tie on RecordedAt and break on Id DESC (R4 > R3).
SELECT @s = STRING_AGG(CASE RejectEventId WHEN @R1 THEN N'R1' WHEN @R2 THEN N'R2' WHEN @R3 THEN N'R3'
                                          WHEN @R4 THEN N'R4' WHEN @R5 THEN N'R5' ELSE N'?' END, N',')
            WITHIN GROUP (ORDER BY Seq)
FROM #RD;
EXEC test.Assert_IsEqual @TestName = N'[RejectDetailPage] page is the newest rows, RecordedAt DESC then Id DESC',
    @Expected = N'R5,R4,R3', @Actual = @s;

-- Shift: LOT A -> its LATEST contribution's schedule; LOT B (none) and the
-- lot-free row -> NULL.
SELECT @s = ShiftName FROM #RD WHERE RejectEventId = @R3;
EXEC test.Assert_IsEqual @TestName = N'[RejectDetailPage] shift comes from the LOT''s latest die-cast contribution',
    @Expected = N'RJP-Late', @Actual = @s;

SELECT @n = COUNT(*) FROM #RD WHERE RejectEventId IN (@R4, @R5) AND ShiftName IS NULL;
EXEC test.Assert_IsEqual @TestName = N'[RejectDetailPage] no contribution / lot-free -> NULL shift',
    @Expected = N'2', @Actual = @n;

-- LOT name resolves inside the page; lot-free stays NULL.
SELECT @n = COUNT(*) FROM #RD rd INNER JOIN Lots.Lot l ON l.Id = rd.LotId AND l.LotName = rd.LotName
WHERE rd.RejectEventId IN (@R3, @R5);
EXEC test.Assert_IsEqual @TestName = N'[RejectDetailPage] LotName resolves for LOT rows on the page',
    @Expected = N'2', @Actual = @n;

SELECT @n = COUNT(*) FROM #RD WHERE RejectEventId = @R4 AND LotId IS NULL AND LotName IS NULL;
EXEC test.Assert_IsEqual @TestName = N'[RejectDetailPage] lot-free row on the page keeps LotId/LotName NULL',
    @Expected = N'1', @Actual = @n;

-- RecordedAt is displayed Eastern: R5 at 22:00 UTC is 17:00 EST.
SELECT @s = CONVERT(NVARCHAR(30), RecordedAt, 126) FROM #RD WHERE RejectEventId = @R5;
EXEC test.Assert_IsEqual @TestName = N'[RejectDetailPage] RecordedAt is converted to Eastern',
    @Expected = N'2001-03-15T17:00:00', @Actual = @s;

-- ---- Whole window -------------------------------------------------------
DELETE FROM #RD;
INSERT INTO #RD (RejectEventId, LotId, LotName, ItemPartNumber, RecordedAt, OperatorName, ShiftName,
                 DefectCode, DefectDescription, ChargeToPartyName, Quantity, IsNonRejectScrap,
                 RecordedAtLocationName, TotalCount)
EXEC Quality.Reject_SearchDetail @FromEt = '2001-03-15', @ToEt = '2001-03-15', @LimitRows = 100;

SELECT @s = STRING_AGG(CASE RejectEventId WHEN @R1 THEN N'R1' WHEN @R2 THEN N'R2' WHEN @R3 THEN N'R3'
                                          WHEN @R4 THEN N'R4' WHEN @R5 THEN N'R5' ELSE N'?' END, N',')
            WITHIN GROUP (ORDER BY Seq)
FROM #RD;
EXEC test.Assert_IsEqual @TestName = N'[RejectDetailPage] whole window, newest first',
    @Expected = N'R5,R4,R3,R2,R1', @Actual = @s;

-- R1 is LOT A too, but the shift is the LOT's latest contribution, not the
-- one nearest the reject: still RJP-Late.
SELECT @s = ShiftName FROM #RD WHERE RejectEventId = @R1;
EXEC test.Assert_IsEqual @TestName = N'[RejectDetailPage] every LOT A row shows the LOT''s latest shift',
    @Expected = N'RJP-Late', @Actual = @s;

SELECT @n = COUNT(*) FROM #RD WHERE TotalCount = 5;
EXEC test.Assert_IsEqual @TestName = N'[RejectDetailPage] TotalCount equals the rows returned when the page fits',
    @Expected = N'5', @Actual = @n;
GO

-- ---- Teardown ------------------------------------------------------------
DECLARE @LotA BIGINT = (SELECT Val FROM #SF WHERE Tag = N'LotA'),
        @LotB BIGINT = (SELECT Val FROM #SF WHERE Tag = N'LotB');
DELETE FROM Workorder.RejectEvent WHERE Id IN (SELECT Val FROM #SF WHERE Tag LIKE N'R_');
DELETE FROM Workorder.DieCastContribution WHERE LotId = @LotA;
DELETE FROM Oee.Shift WHERE Id IN (SELECT Val FROM #SF WHERE Tag IN (N'ShEarly', N'ShLate'));
DELETE FROM Oee.ShiftSchedule WHERE Id IN (SELECT Val FROM #SF WHERE Tag IN (N'SchEarly', N'SchLate'));
DELETE FROM Lots.LotGenealogyClosure WHERE AncestorLotId IN (@LotA, @LotB) OR DescendantLotId IN (@LotA, @LotB);
DELETE FROM Lots.LotGenealogy        WHERE ParentLotId IN (@LotA, @LotB) OR ChildLotId IN (@LotA, @LotB);
DELETE FROM Lots.LotEventLog         WHERE LotId IN (@LotA, @LotB);
DELETE FROM Lots.LotMovement         WHERE LotId IN (@LotA, @LotB);
DELETE FROM Lots.LotStatusHistory    WHERE LotId IN (@LotA, @LotB);
DELETE FROM Lots.Lot                 WHERE Id IN (@LotA, @LotB);
IF OBJECT_ID(N'tempdb..#RD') IS NOT NULL DROP TABLE #RD;
IF OBJECT_ID(N'tempdb..#SF') IS NOT NULL DROP TABLE #SF;
GO
