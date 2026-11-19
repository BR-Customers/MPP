-- =============================================
-- File:         0134_ScaleDigi/020_pending_press.sql
-- Author:       Blue Ridge Automation
-- Created:      2026-11-19
-- Description:
--   Workorder.ScalePendingPress_*: hold a press whose scale part code matched
--   no MES part, read it, claim it (once), release it on a failed close,
--   complete it, discard it. One Pending per terminal.
--   Spec: docs/superpowers/specs/2026-11-19-digi-scale-feed-design.md section 7.
-- =============================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0134_ScaleDigi/020_pending_press.sql';
GO

CREATE TABLE #S (Status BIT, Message NVARCHAR(500), NewId BIGINT NULL);
CREATE TABLE #S2 (Status BIT, Message NVARCHAR(500));
CREATE TABLE #P (Id BIGINT, TerminalLocationId BIGINT, ReceivedAtEt DATETIME2(3), NetWeight DECIMAL(10,3),
                 Uom NVARCHAR(10), ScalePartCode NVARCHAR(50));
GO

DECLARE @Term BIGINT = (SELECT TOP 1 Id FROM Location.Location WHERE LocationTypeDefinitionId = 7 AND DeprecatedAt IS NULL ORDER BY Id);
DELETE FROM Workorder.ScalePendingPress WHERE TerminalLocationId = @Term;
GO

-- ==== hold ====
DECLARE @Term BIGINT = (SELECT TOP 1 Id FROM Location.Location WHERE LocationTypeDefinitionId = 7 AND DeprecatedAt IS NULL ORDER BY Id);
DECLARE @Before BIGINT = ISNULL((SELECT MAX(Id) FROM Audit.OperationLog), 0);
DELETE FROM #S; INSERT INTO #S EXEC Workorder.ScalePendingPress_Hold @TerminalLocationId = @Term, @NetWeight = 15.5, @Uom = N'LB', @ScalePartCode = N'TEST3', @AppUserId = 1;
DECLARE @St NVARCHAR(5) = (SELECT CAST(Status AS NVARCHAR(5)) FROM #S);
EXEC test.Assert_IsEqual @TestName = N'[Pending] hold -> Status 1', @Expected = N'1', @Actual = @St;
DECLARE @HasId BIT = (SELECT CASE WHEN NewId IS NOT NULL THEN 1 ELSE 0 END FROM #S);
EXEC test.Assert_IsTrue @TestName = N'[Pending] hold returns NewId', @Condition = @HasId;
DECLARE @Aud NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM Audit.OperationLog ol JOIN Audit.LogEventType et ON et.Id = ol.LogEventTypeId
                             WHERE ol.Id > @Before AND et.Code = N'ScalePressHeld');
EXEC test.Assert_IsEqual @TestName = N'[Pending] hold audited', @Expected = N'1', @Actual = @Aud;

DELETE FROM #S; INSERT INTO #S EXEC Workorder.ScalePendingPress_Hold @TerminalLocationId = @Term, @NetWeight = 15.6, @Uom = N'LB', @ScalePartCode = N'TEST3', @AppUserId = 1;
SET @St = (SELECT CAST(Status AS NVARCHAR(5)) FROM #S);
EXEC test.Assert_IsEqual @TestName = N'[Pending] second hold at the terminal refused', @Expected = N'0', @Actual = @St;
DECLARE @Msg NVARCHAR(500) = (SELECT Message FROM #S);
EXEC test.Assert_Contains @TestName = N'[Pending] second hold says a tray is already waiting', @HaystackStr = @Msg, @NeedleStr = N'already waiting';

DELETE FROM #S; INSERT INTO #S EXEC Workorder.ScalePendingPress_Hold @TerminalLocationId = @Term, @NetWeight = NULL, @Uom = N'LB', @ScalePartCode = N'TEST3', @AppUserId = 1;
SET @St = (SELECT CAST(Status AS NVARCHAR(5)) FROM #S);
EXEC test.Assert_IsEqual @TestName = N'[Pending] hold with a missing weight refused', @Expected = N'0', @Actual = @St;
GO

-- ==== read ====
DECLARE @Term BIGINT = (SELECT TOP 1 Id FROM Location.Location WHERE LocationTypeDefinitionId = 7 AND DeprecatedAt IS NULL ORDER BY Id);
DELETE FROM #P; INSERT INTO #P EXEC Workorder.ScalePendingPress_GetForTerminal @TerminalLocationId = @Term;
DECLARE @R NVARCHAR(100) = (SELECT CONCAT(CAST(NetWeight AS DECIMAL(10,1)), N'|', Uom, N'|', ScalePartCode) FROM #P);
EXEC test.Assert_IsEqual @TestName = N'[Pending] read returns the held press', @Expected = N'15.5|LB|TEST3', @Actual = @R;
GO

-- ==== claim once, release, claim, complete ====
DECLARE @Term BIGINT = (SELECT TOP 1 Id FROM Location.Location WHERE LocationTypeDefinitionId = 7 AND DeprecatedAt IS NULL ORDER BY Id);
DECLARE @Id BIGINT = (SELECT Id FROM Workorder.ScalePendingPress WHERE TerminalLocationId = @Term AND StatusId = 1);
DELETE FROM #S2; INSERT INTO #S2 EXEC Workorder.ScalePendingPress_Claim @Id = @Id, @AppUserId = 1;
DECLARE @St NVARCHAR(5) = (SELECT CAST(Status AS NVARCHAR(5)) FROM #S2);
EXEC test.Assert_IsEqual @TestName = N'[Pending] claim -> Status 1', @Expected = N'1', @Actual = @St;
DELETE FROM #S2; INSERT INTO #S2 EXEC Workorder.ScalePendingPress_Claim @Id = @Id, @AppUserId = 1;
SET @St = (SELECT CAST(Status AS NVARCHAR(5)) FROM #S2);
EXEC test.Assert_IsEqual @TestName = N'[Pending] second claim refused (one tray per press)', @Expected = N'0', @Actual = @St;
DELETE FROM #P; INSERT INTO #P EXEC Workorder.ScalePendingPress_GetForTerminal @TerminalLocationId = @Term;
DECLARE @N NVARCHAR(5) = (SELECT CAST(COUNT(*) AS NVARCHAR(5)) FROM #P);
EXEC test.Assert_IsEqual @TestName = N'[Pending] a claimed press is no longer pending', @Expected = N'0', @Actual = @N;

DELETE FROM #S2; INSERT INTO #S2 EXEC Workorder.ScalePendingPress_Release @Id = @Id, @AppUserId = 1;
SET @St = (SELECT CAST(Status AS NVARCHAR(5)) FROM #S2);
EXEC test.Assert_IsEqual @TestName = N'[Pending] release after a failed close -> Status 1', @Expected = N'1', @Actual = @St;
DELETE FROM #P; INSERT INTO #P EXEC Workorder.ScalePendingPress_GetForTerminal @TerminalLocationId = @Term;
SET @N = (SELECT CAST(COUNT(*) AS NVARCHAR(5)) FROM #P);
EXEC test.Assert_IsEqual @TestName = N'[Pending] released press is pending again', @Expected = N'1', @Actual = @N;

DECLARE @Item BIGINT = (SELECT TOP 1 Id FROM Parts.Item WHERE DeprecatedAt IS NULL ORDER BY Id);
DELETE FROM #S2; INSERT INTO #S2 EXEC Workorder.ScalePendingPress_Complete @Id = @Id, @ItemId = @Item, @FinishedGoodLotId = NULL, @AppUserId = 1;
SET @St = (SELECT CAST(Status AS NVARCHAR(5)) FROM #S2);
EXEC test.Assert_IsEqual @TestName = N'[Pending] complete before claim refused', @Expected = N'0', @Actual = @St;

DECLARE @Before BIGINT = ISNULL((SELECT MAX(Id) FROM Audit.OperationLog), 0);
DELETE FROM #S2; INSERT INTO #S2 EXEC Workorder.ScalePendingPress_Claim @Id = @Id, @AppUserId = 1;
DELETE FROM #S2; INSERT INTO #S2 EXEC Workorder.ScalePendingPress_Complete @Id = @Id, @ItemId = @Item, @FinishedGoodLotId = NULL, @AppUserId = 1;
SET @St = (SELECT CAST(Status AS NVARCHAR(5)) FROM #S2);
EXEC test.Assert_IsEqual @TestName = N'[Pending] complete after claim -> Status 1', @Expected = N'1', @Actual = @St;
DECLARE @Row NVARCHAR(100) = (SELECT CONCAT(s.Code, N'|', CASE WHEN p.ResolvedItemId = @Item THEN N'item' END, N'|',
                                            CASE WHEN p.ResolvedAt IS NOT NULL AND p.ResolvedByAppUserId = 1 THEN N'by' END)
                              FROM Workorder.ScalePendingPress p JOIN Workorder.ScalePendingPressStatus s ON s.Id = p.StatusId WHERE p.Id = @Id);
EXEC test.Assert_IsEqual @TestName = N'[Pending] completed row: Closed, item, resolver', @Expected = N'Closed|item|by', @Actual = @Row;
DECLARE @Aud NVARCHAR(500) = (SELECT TOP 1 ol.Description FROM Audit.OperationLog ol JOIN Audit.LogEventType et ON et.Id = ol.LogEventTypeId
                              WHERE ol.Id > @Before AND et.Code = N'ScalePressPicked' ORDER BY ol.Id DESC);
EXEC test.Assert_Contains @TestName = N'[Pending] pick audited with the held weight', @HaystackStr = @Aud, @NeedleStr = N'15.5';

DELETE FROM #S2; INSERT INTO #S2 EXEC Workorder.ScalePendingPress_Release @Id = @Id, @AppUserId = 1;
SET @St = (SELECT CAST(Status AS NVARCHAR(5)) FROM #S2);
EXEC test.Assert_IsEqual @TestName = N'[Pending] release after complete refused', @Expected = N'0', @Actual = @St;
GO

-- ==== discard ====
DECLARE @Term BIGINT = (SELECT TOP 1 Id FROM Location.Location WHERE LocationTypeDefinitionId = 7 AND DeprecatedAt IS NULL ORDER BY Id);
DELETE FROM #S; INSERT INTO #S EXEC Workorder.ScalePendingPress_Hold @TerminalLocationId = @Term, @NetWeight = 16.0, @Uom = N'LB', @ScalePartCode = N'XYZ', @AppUserId = 1;
DECLARE @Id BIGINT = (SELECT NewId FROM #S);
DECLARE @Before BIGINT = ISNULL((SELECT MAX(Id) FROM Audit.OperationLog), 0);
DELETE FROM #S2; INSERT INTO #S2 EXEC Workorder.ScalePendingPress_Discard @Id = @Id, @AppUserId = 1;
DECLARE @St NVARCHAR(5) = (SELECT CAST(Status AS NVARCHAR(5)) FROM #S2);
EXEC test.Assert_IsEqual @TestName = N'[Pending] discard -> Status 1', @Expected = N'1', @Actual = @St;
DECLARE @Aud NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM Audit.OperationLog ol JOIN Audit.LogEventType et ON et.Id = ol.LogEventTypeId
                             WHERE ol.Id > @Before AND et.Code = N'ScalePressDiscarded');
EXEC test.Assert_IsEqual @TestName = N'[Pending] discard audited', @Expected = N'1', @Actual = @Aud;
DELETE FROM #S2; INSERT INTO #S2 EXEC Workorder.ScalePendingPress_Discard @Id = @Id, @AppUserId = 1;
SET @St = (SELECT CAST(Status AS NVARCHAR(5)) FROM #S2);
EXEC test.Assert_IsEqual @TestName = N'[Pending] second discard refused', @Expected = N'0', @Actual = @St;

DELETE FROM Workorder.ScalePendingPress WHERE TerminalLocationId = @Term;
GO

EXEC test.EndTestFile;
GO
