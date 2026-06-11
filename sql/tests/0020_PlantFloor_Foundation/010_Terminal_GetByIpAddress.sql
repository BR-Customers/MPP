-- =============================================
-- File:         0020_PlantFloor_Foundation/010_Terminal_GetByIpAddress.sql
-- Author:       Blue Ridge Automation
-- Created:      2026-06-09
-- Description:  Tests for Location.Terminal_GetByIpAddress (Phase 1 Task C).
--               Asserts:
--                 * Known IP (Cell-parented Terminal) -> correct Terminal +
--                   Zone + DefaultScreen.
--                 * Known IP (Area-parented Terminal) -> resolves; NULL
--                   DefaultScreen when unset.
--                 * Unknown IP -> the global FALLBACK Terminal (IsFallback=1),
--                   never an error / empty set.
--                 * Deprecated Terminal's IP -> NOT returned; falls through to
--                   the fallback Terminal instead.
--
--               Fixtures created here:
--                 * TEST-TERM-CELL  (DefId 7) parented at Cell  'DC1-M01'
--                   (a die-cast machine = Cell tier), IpAddress '10.99.0.1',
--                   DefaultScreen 'perspective:DieCast'.
--                 * TEST-TERM-AREA  (DefId 7) parented at Area  'DC1',
--                   IpAddress '10.99.0.2', NO DefaultScreen.
--                 * TEST-TERM-DEPR  (DefId 7, DeprecatedAt set) parented at Cell
--                   'DC1-M01', IpAddress '10.99.0.3'.
-- =============================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0020_PlantFloor_Foundation/010_Terminal_GetByIpAddress.sql';
GO

-- ---- teardown any prior fixtures (FK-safe: attributes -> locations) ----
DELETE la
FROM Location.LocationAttribute la
INNER JOIN Location.Location l ON l.Id = la.LocationId
WHERE l.Code IN (N'TEST-TERM-CELL', N'TEST-TERM-AREA', N'TEST-TERM-DEPR');
DELETE FROM Location.Location WHERE Code IN (N'TEST-TERM-CELL', N'TEST-TERM-AREA', N'TEST-TERM-DEPR');
GO

-- ---- create the three Terminal fixtures ----
DECLARE @CellParentId BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'DC1-M01');  -- Cell tier (die-cast machine)
DECLARE @AreaParentId BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'DC1');      -- Area tier

INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
VALUES
    (7, @CellParentId, N'Test Terminal Cell', N'TEST-TERM-CELL', N'Cell-parented test terminal', 900),
    (7, @AreaParentId, N'Test Terminal Area', N'TEST-TERM-AREA', N'Area-parented test terminal', 901);

-- deprecated terminal (DeprecatedAt set) parented at the same Cell
INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder, DeprecatedAt)
VALUES
    (7, @CellParentId, N'Test Terminal Deprecated', N'TEST-TERM-DEPR', N'Deprecated test terminal', 902, SYSUTCDATETIME());
GO

-- ---- attach IpAddress + DefaultScreen attribute values ----
DECLARE @IpDefId BIGINT = (
    SELECT Id FROM Location.LocationAttributeDefinition
    WHERE LocationTypeDefinitionId = 7 AND AttributeName = N'IpAddress' AND DeprecatedAt IS NULL);
DECLARE @ScreenDefId BIGINT = (
    SELECT Id FROM Location.LocationAttributeDefinition
    WHERE LocationTypeDefinitionId = 7 AND AttributeName = N'DefaultScreen' AND DeprecatedAt IS NULL);

DECLARE @CellTermId BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'TEST-TERM-CELL');
DECLARE @AreaTermId BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'TEST-TERM-AREA');
DECLARE @DeprTermId BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'TEST-TERM-DEPR');

INSERT INTO Location.LocationAttribute (LocationId, LocationAttributeDefinitionId, AttributeValue)
VALUES
    (@CellTermId, @IpDefId,     N'10.99.0.1'),
    (@CellTermId, @ScreenDefId, N'perspective:DieCast'),
    (@AreaTermId, @IpDefId,     N'10.99.0.2'),   -- no DefaultScreen on this one
    (@DeprTermId, @IpDefId,     N'10.99.0.3');
GO

-- =============================================
-- Test 1: Known IP, Cell parent -> correct Terminal, Zone, DefaultScreen
-- =============================================
DECLARE @TermCode NVARCHAR(50), @ZoneCode NVARCHAR(50), @Screen NVARCHAR(255),
        @Fallback BIT, @FbStr NVARCHAR(1);
CREATE TABLE #C (TerminalLocationId BIGINT, TerminalCode NVARCHAR(50), TerminalName NVARCHAR(200),
                 ZoneLocationId BIGINT, ZoneCode NVARCHAR(50), ZoneName NVARCHAR(200),
                 DefaultScreen NVARCHAR(255), IsFallback BIT);
INSERT INTO #C EXEC Location.Terminal_GetByIpAddress @IpAddress = N'10.99.0.1';
SELECT @TermCode = TerminalCode, @ZoneCode = ZoneCode, @Screen = DefaultScreen,
       @Fallback = IsFallback FROM #C;
DROP TABLE #C;
SET @FbStr = CAST(@Fallback AS NVARCHAR(1));
EXEC test.Assert_IsEqual
    @TestName = N'[TermCell] Known IP resolves the Cell terminal',
    @Expected = N'TEST-TERM-CELL', @Actual = @TermCode;
EXEC test.Assert_IsEqual
    @TestName = N'[TermCell] Zone is the parent Cell (DC1-M01)',
    @Expected = N'DC1-M01', @Actual = @ZoneCode;
EXEC test.Assert_IsEqual
    @TestName = N'[TermCell] DefaultScreen returned',
    @Expected = N'perspective:DieCast', @Actual = @Screen;
EXEC test.Assert_IsEqual
    @TestName = N'[TermCell] IsFallback=0 for a real match',
    @Expected = N'0', @Actual = @FbStr;
GO

-- =============================================
-- Test 2: Known IP, Area parent -> resolves + NULL DefaultScreen
-- =============================================
DECLARE @TermCode NVARCHAR(50), @Screen NVARCHAR(255);
CREATE TABLE #A (TerminalLocationId BIGINT, TerminalCode NVARCHAR(50), TerminalName NVARCHAR(200),
                 ZoneLocationId BIGINT, ZoneCode NVARCHAR(50), ZoneName NVARCHAR(200),
                 DefaultScreen NVARCHAR(255), IsFallback BIT);
INSERT INTO #A EXEC Location.Terminal_GetByIpAddress @IpAddress = N'10.99.0.2';
SELECT @TermCode = TerminalCode, @Screen = DefaultScreen FROM #A;
DROP TABLE #A;
EXEC test.Assert_IsEqual
    @TestName = N'[TermArea] Known IP resolves the Area terminal',
    @Expected = N'TEST-TERM-AREA', @Actual = @TermCode;
EXEC test.Assert_IsNull
    @TestName = N'[TermArea] DefaultScreen is NULL when unset',
    @Value = @Screen;
GO

-- =============================================
-- Test 3: Unknown IP -> fallback Terminal (never empty / error)
-- =============================================
DECLARE @TermCode NVARCHAR(50), @Fallback BIT, @FbStr NVARCHAR(1), @Rows INT;
CREATE TABLE #U (TerminalLocationId BIGINT, TerminalCode NVARCHAR(50), TerminalName NVARCHAR(200),
                 ZoneLocationId BIGINT, ZoneCode NVARCHAR(50), ZoneName NVARCHAR(200),
                 DefaultScreen NVARCHAR(255), IsFallback BIT);
INSERT INTO #U EXEC Location.Terminal_GetByIpAddress @IpAddress = N'203.0.113.250';
SELECT @Rows = COUNT(*) FROM #U;
SELECT @TermCode = TerminalCode, @Fallback = IsFallback FROM #U;
DROP TABLE #U;
SET @FbStr = CAST(@Fallback AS NVARCHAR(1));
EXEC test.Assert_RowCount
    @TestName = N'[TermUnknown] Exactly one row returned (never empty)',
    @ExpectedCount = 1, @ActualCount = @Rows;
EXEC test.Assert_IsEqual
    @TestName = N'[TermUnknown] Unknown IP returns the FALLBACK terminal',
    @Expected = N'FALLBACK-TERMINAL', @Actual = @TermCode;
EXEC test.Assert_IsEqual
    @TestName = N'[TermUnknown] IsFallback=1 for an unknown IP',
    @Expected = N'1', @Actual = @FbStr;
GO

-- =============================================
-- Test 4: Deprecated Terminal's IP -> NOT returned; falls through to fallback
-- =============================================
DECLARE @TermCode NVARCHAR(50), @Fallback BIT, @FbStr NVARCHAR(1);
CREATE TABLE #D (TerminalLocationId BIGINT, TerminalCode NVARCHAR(50), TerminalName NVARCHAR(200),
                 ZoneLocationId BIGINT, ZoneCode NVARCHAR(50), ZoneName NVARCHAR(200),
                 DefaultScreen NVARCHAR(255), IsFallback BIT);
INSERT INTO #D EXEC Location.Terminal_GetByIpAddress @IpAddress = N'10.99.0.3';
SELECT @TermCode = TerminalCode, @Fallback = IsFallback FROM #D;
DROP TABLE #D;
SET @FbStr = CAST(@Fallback AS NVARCHAR(1));
EXEC test.Assert_IsEqual
    @TestName = N'[TermDepr] Deprecated terminal IP not matched -> fallback',
    @Expected = N'FALLBACK-TERMINAL', @Actual = @TermCode;
EXEC test.Assert_IsEqual
    @TestName = N'[TermDepr] IsFallback=1 (deprecated excluded)',
    @Expected = N'1', @Actual = @FbStr;
GO

-- ---- cleanup (FK-safe: attributes -> locations) ----
DELETE la
FROM Location.LocationAttribute la
INNER JOIN Location.Location l ON l.Id = la.LocationId
WHERE l.Code IN (N'TEST-TERM-CELL', N'TEST-TERM-AREA', N'TEST-TERM-DEPR');
DELETE FROM Location.Location WHERE Code IN (N'TEST-TERM-CELL', N'TEST-TERM-AREA', N'TEST-TERM-DEPR');
GO

EXEC test.EndTestFile;
GO
