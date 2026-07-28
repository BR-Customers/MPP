SET NOCOUNT ON; SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0045_DieCast_Lifecycle/010_migration_and_schema.sql';
GO
DECLARE @openId NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM Lots.LotStatusCode WHERE Code = N'Open' AND BlocksProduction = 0);
EXEC test.Assert_IsEqual @TestName = N'[0045] Open status seeded, BlocksProduction 0', @Expected = N'1', @Actual = @openId;
DECLARE @orig NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM Lots.LotStatusCode WHERE Id IN (1,2,3,4) AND Code IN (N'Good',N'Hold',N'Scrap',N'Closed'));
EXEC test.Assert_IsEqual @TestName = N'[0045] existing status Ids 1-4 unchanged', @Expected = N'4', @Actual = @orig;
DECLARE @tbl NVARCHAR(10) = (SELECT CASE WHEN OBJECT_ID(N'Workorder.DieCastContribution',N'U') IS NOT NULL THEN N'1' ELSE N'0' END);
EXEC test.Assert_IsEqual @TestName = N'[0045] DieCastContribution table exists', @Expected = N'1', @Actual = @tbl;
DECLARE @cols NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM sys.columns
    WHERE object_id = OBJECT_ID(N'Workorder.DieCastContribution')
      AND name IN (N'Id',N'LotId',N'ShiftId',N'PieceDelta',N'AppUserId',N'TerminalLocationId',N'EventAt'));
EXEC test.Assert_IsEqual @TestName = N'[0045] DieCastContribution has 7 expected columns', @Expected = N'7', @Actual = @cols;
DECLARE @evt NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM Audit.LogEventType
    WHERE Code IN (N'DieCastLotOpened',N'DieCastPieceContributed',N'DieCastLotReleased',N'DieCastLotVoided'));
EXEC test.Assert_IsEqual @TestName = N'[0045] 4 audit LogEventTypes seeded', @Expected = N'4', @Actual = @evt;
GO
EXEC test.EndTestFile;
GO
