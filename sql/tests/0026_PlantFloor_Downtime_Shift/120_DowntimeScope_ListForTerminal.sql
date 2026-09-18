-- =============================================
-- File:         0026_PlantFloor_Downtime_Shift/120_DowntimeScope_ListForTerminal.sql
-- Author:       Blue Ridge Automation
-- Created:      2026-09-09
-- Rewritten:    2026-09-17 (OEE-enabled locations spec)
-- Description:  Oee.DowntimeScope_ListForTerminal -- the downtime units an
--               operator at a terminal may log against, and which one the
--               Downtime Manager preselects.
--
--               The rule is now one sentence: the OEE-ENABLED locations in the
--               terminal's zone subtree, the zone included. Asserted per shape:
--                 * shared area terminal (die cast)  -> one row per flagged press
--                 * dedicated machine terminal       -> that machine
--                 * plain line terminal              -> the line
--                 * SPLIT line terminal (6MA shape)  -> the line + its stations,
--                                                       in tree order
--                 * area with nothing flagged        -> empty
--                 * fallback terminal (Site zone)    -> empty
--               Plus the three default rules: single row defaults to itself;
--               an active cell that is a LEAF unit preselects; an active cell
--               that is a ROLL-UP (a line with stations) preselects NOTHING,
--               because defaulting to the line would charge a side-A jam to
--               every station on the line.
--
--               All fixtures come from test.OeeFixture_Build -- structural, no
--               dependency on plant-seed codes (Dev's trim shop and prod's
--               disagree until Dev is re-synced).
-- =============================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0026_PlantFloor_Downtime_Shift/120_DowntimeScope_ListForTerminal.sql';
GO

EXEC test.OeeFixture_Build;
GO

IF OBJECT_ID(N'tempdb..#ScOut') IS NOT NULL DROP TABLE #ScOut;
CREATE TABLE #ScOut (
    Seq             INT           IDENTITY(1,1) NOT NULL,
    ScopeLocationId BIGINT        NULL,
    Code            NVARCHAR(50)  NULL,
    Name            NVARCHAR(200) NULL,
    Kind            NVARCHAR(100) NULL,
    IsDefault       BIT           NULL
);
GO

-- =============================================
-- Test 1: shared area terminal -> one row per ACTIVE flagged press, no default.
-- =============================================
DECLARE @DcT BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'ZZ-OEE-DC-T1');
TRUNCATE TABLE #ScOut;
INSERT INTO #ScOut (ScopeLocationId, Code, Name, Kind, IsDefault) EXEC Oee.DowntimeScope_ListForTerminal @TerminalLocationId = @DcT;

DECLARE @c1 NVARCHAR(200) = (SELECT STUFF((SELECT N',' + Code FROM #ScOut ORDER BY Code
    FOR XML PATH(''), TYPE).value('.', 'NVARCHAR(MAX)'), 1, 1, N''));
EXEC test.Assert_IsEqual @TestName = N'[DtScope] shared area terminal lists its flagged presses, deprecated excluded',
     @Expected = N'ZZ-OEE-DC-M1,ZZ-OEE-DC-M2', @Actual = @c1;

DECLARE @d1 INT = (SELECT COUNT(*) FROM #ScOut WHERE IsDefault = 1);
EXEC test.Assert_RowCount @TestName = N'[DtScope] more than one option and no active cell -> no default',
     @ExpectedCount = 0, @ActualCount = @d1;
GO

-- =============================================
-- Test 2: an active cell inside the list preselects exactly that row.
-- =============================================
DECLARE @DcT BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'ZZ-OEE-DC-T1');
DECLARE @M2  BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'ZZ-OEE-DC-M2');
TRUNCATE TABLE #ScOut;
INSERT INTO #ScOut (ScopeLocationId, Code, Name, Kind, IsDefault) EXEC Oee.DowntimeScope_ListForTerminal @TerminalLocationId = @DcT, @ActiveCellLocationId = @M2;
DECLARE @d2 NVARCHAR(50) = (SELECT Code FROM #ScOut WHERE IsDefault = 1);
EXEC test.Assert_IsEqual @TestName = N'[DtScope] the active press is preselected',
     @Expected = N'ZZ-OEE-DC-M2', @Actual = @d2;
GO

-- =============================================
-- Test 3: an active cell OUTSIDE the list leaves no default.
-- =============================================
DECLARE @DcT BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'ZZ-OEE-DC-T1');
DECLARE @A   BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'ZZ-OEE-L-A');
TRUNCATE TABLE #ScOut;
INSERT INTO #ScOut (ScopeLocationId, Code, Name, Kind, IsDefault) EXEC Oee.DowntimeScope_ListForTerminal @TerminalLocationId = @DcT, @ActiveCellLocationId = @A;
DECLARE @d3 INT = (SELECT COUNT(*) FROM #ScOut WHERE IsDefault = 1);
EXEC test.Assert_RowCount @TestName = N'[DtScope] an active cell outside the list gives no default',
     @ExpectedCount = 0, @ActualCount = @d3;
GO

-- =============================================
-- Test 4: dedicated machine terminal -> that machine, preselected.
-- =============================================
DECLARE @M1T BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'ZZ-OEE-DC-M1-T1');
TRUNCATE TABLE #ScOut;
INSERT INTO #ScOut (ScopeLocationId, Code, Name, Kind, IsDefault) EXEC Oee.DowntimeScope_ListForTerminal @TerminalLocationId = @M1T;
DECLARE @c4 NVARCHAR(200) = (SELECT STUFF((SELECT N',' + Code FROM #ScOut ORDER BY Code
    FOR XML PATH(''), TYPE).value('.', 'NVARCHAR(MAX)'), 1, 1, N''));
DECLARE @d4 NVARCHAR(10) = (SELECT CAST(IsDefault AS NVARCHAR(10)) FROM #ScOut);
EXEC test.Assert_IsEqual @TestName = N'[DtScope] dedicated terminal lists only its machine',
     @Expected = N'ZZ-OEE-DC-M1', @Actual = @c4;
EXEC test.Assert_IsEqual @TestName = N'[DtScope] a single option is preselected',
     @Expected = N'1', @Actual = @d4;
GO

-- =============================================
-- Test 5: plain line terminal -> the line, preselected (today's M&A behaviour).
-- =============================================
DECLARE @PT BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'ZZ-OEE-P-T1');
DECLARE @P  BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'ZZ-OEE-P');
TRUNCATE TABLE #ScOut;
INSERT INTO #ScOut (ScopeLocationId, Code, Name, Kind, IsDefault) EXEC Oee.DowntimeScope_ListForTerminal @TerminalLocationId = @PT, @ActiveCellLocationId = @P;
DECLARE @c5 NVARCHAR(200) = (SELECT STUFF((SELECT N',' + Code FROM #ScOut ORDER BY Code
    FOR XML PATH(''), TYPE).value('.', 'NVARCHAR(MAX)'), 1, 1, N''));
DECLARE @d5 NVARCHAR(10) = (SELECT CAST(IsDefault AS NVARCHAR(10)) FROM #ScOut);
EXEC test.Assert_IsEqual @TestName = N'[DtScope] an unsplit line terminal still lists just the line',
     @Expected = N'ZZ-OEE-P', @Actual = @c5;
EXEC test.Assert_IsEqual @TestName = N'[DtScope] and preselects it',
     @Expected = N'1', @Actual = @d5;
GO

-- =============================================
-- Test 6: SPLIT line terminal -> line + stations in TREE order, no default
-- even though the session cell is the line (it is a roll-up).
-- =============================================
DECLARE @LT BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'ZZ-OEE-L-T1');
DECLARE @L  BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'ZZ-OEE-L');
TRUNCATE TABLE #ScOut;
INSERT INTO #ScOut (ScopeLocationId, Code, Name, Kind, IsDefault) EXEC Oee.DowntimeScope_ListForTerminal @TerminalLocationId = @LT, @ActiveCellLocationId = @L;

-- Tree order is assertable because the proc returns rows in it; #ScOut's Seq
-- IDENTITY column captures INSERT-EXEC capture order (physical read order is
-- not guaranteed), so ORDER BY Seq below reads back what the proc returned.
DECLARE @c6 NVARCHAR(400) = (SELECT STUFF((SELECT N',' + Code FROM #ScOut ORDER BY Seq
    FOR XML PATH(''), TYPE).value('.', 'NVARCHAR(MAX)'), 1, 1, N''));
EXEC test.Assert_IsEqual @TestName = N'[DtScope] split line lists the line then its stations, in tree order',
     @Expected = N'ZZ-OEE-L,ZZ-OEE-L-MI,ZZ-OEE-L-A,ZZ-OEE-L-B', @Actual = @c6;

DECLARE @d6 INT = (SELECT COUNT(*) FROM #ScOut WHERE IsDefault = 1);
EXEC test.Assert_RowCount @TestName = N'[DtScope] a roll-up active cell preselects NOTHING (a side jam must not be charged to the line)',
     @ExpectedCount = 0, @ActualCount = @d6;
GO

-- =============================================
-- Test 7: an active cell that is a LEAF station preselects.
-- =============================================
DECLARE @LT BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'ZZ-OEE-L-T1');
DECLARE @A  BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'ZZ-OEE-L-A');
TRUNCATE TABLE #ScOut;
INSERT INTO #ScOut (ScopeLocationId, Code, Name, Kind, IsDefault) EXEC Oee.DowntimeScope_ListForTerminal @TerminalLocationId = @LT, @ActiveCellLocationId = @A;
DECLARE @d7 NVARCHAR(50) = (SELECT Code FROM #ScOut WHERE IsDefault = 1);
EXEC test.Assert_IsEqual @TestName = N'[DtScope] an active station preselects itself',
     @Expected = N'ZZ-OEE-L-A', @Actual = @d7;
GO

-- =============================================
-- Test 8: un-flagging a station removes it from the list the moment it is off.
-- =============================================
UPDATE Location.Location SET IsOeeEnabled = 0 WHERE Code = N'ZZ-OEE-L-B';
DECLARE @LT BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'ZZ-OEE-L-T1');
TRUNCATE TABLE #ScOut;
INSERT INTO #ScOut (ScopeLocationId, Code, Name, Kind, IsDefault) EXEC Oee.DowntimeScope_ListForTerminal @TerminalLocationId = @LT;
DECLARE @c8 NVARCHAR(400) = (SELECT STUFF((SELECT N',' + Code FROM #ScOut ORDER BY Seq
    FOR XML PATH(''), TYPE).value('.', 'NVARCHAR(MAX)'), 1, 1, N''));
EXEC test.Assert_IsEqual @TestName = N'[DtScope] an un-flagged station leaves the dropdown',
     @Expected = N'ZZ-OEE-L,ZZ-OEE-L-MI,ZZ-OEE-L-A', @Actual = @c8;
UPDATE Location.Location SET IsOeeEnabled = 1 WHERE Code = N'ZZ-OEE-L-B';
GO

-- =============================================
-- Test 9: an area with nothing flagged, the fallback terminal, an unknown id
-- and NULL all return an empty set.
-- =============================================
DECLARE @ET BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'ZZ-OEE-E-T1');
TRUNCATE TABLE #ScOut;
INSERT INTO #ScOut (ScopeLocationId, Code, Name, Kind, IsDefault) EXEC Oee.DowntimeScope_ListForTerminal @TerminalLocationId = @ET;
DECLARE @c9 INT = (SELECT COUNT(*) FROM #ScOut);
EXEC test.Assert_RowCount @TestName = N'[DtScope] an area with no flagged equipment returns nothing',
     @ExpectedCount = 0, @ActualCount = @c9;

DECLARE @Fb BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'FALLBACK-TERMINAL');
TRUNCATE TABLE #ScOut;
INSERT INTO #ScOut (ScopeLocationId, Code, Name, Kind, IsDefault) EXEC Oee.DowntimeScope_ListForTerminal @TerminalLocationId = @Fb;
DECLARE @c9b INT = (SELECT COUNT(*) FROM #ScOut);
EXEC test.Assert_RowCount @TestName = N'[DtScope] the fallback terminal (Site zone) returns nothing',
     @ExpectedCount = 0, @ActualCount = @c9b;

TRUNCATE TABLE #ScOut;
INSERT INTO #ScOut (ScopeLocationId, Code, Name, Kind, IsDefault) EXEC Oee.DowntimeScope_ListForTerminal @TerminalLocationId = -1;
DECLARE @c9c INT = (SELECT COUNT(*) FROM #ScOut);
EXEC test.Assert_RowCount @TestName = N'[DtScope] an unknown terminal returns nothing',
     @ExpectedCount = 0, @ActualCount = @c9c;

TRUNCATE TABLE #ScOut;
INSERT INTO #ScOut (ScopeLocationId, Code, Name, Kind, IsDefault) EXEC Oee.DowntimeScope_ListForTerminal @TerminalLocationId = NULL;
DECLARE @c9d INT = (SELECT COUNT(*) FROM #ScOut);
EXEC test.Assert_RowCount @TestName = N'[DtScope] NULL terminal returns nothing',
     @ExpectedCount = 0, @ActualCount = @c9d;
GO

-- ---- cleanup ----
IF OBJECT_ID(N'tempdb..#ScOut') IS NOT NULL DROP TABLE #ScOut;
EXEC test.OeeFixture_Teardown;
GO

EXEC test.PrintSummary;
EXEC test.EndTestFile;
GO
