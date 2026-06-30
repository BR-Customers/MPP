-- =============================================
-- File:         0020_PlantFloor_Foundation/015_Terminal_ContextCells_List.sql
-- Author:       Blue Ridge Automation
-- Created:      2026-06-10
-- Description:  Tests for Location.Terminal_ListContextCells (view-policy
--               model spec 2026-06-10) + Terminal_List v1.1 shape/HasPrinter.
--               Asserts:
--                 * Area-parented terminal -> exactly the active equipment
--                   cells under the parent (Terminal/Printer kinds and
--                   deprecated cells excluded).
--                 * Line-parented terminal whose parent has only
--                   terminals/printers beneath -> empty set.
--                 * Unknown / deprecated terminal id -> empty set.
--                 * Terminal_List: HasPrinter=1 with an active child Printer,
--                   0 without; result-set shape pins (no TerminalMode).
--
--               Self-contained fixture subtree under the Site (MPP-MAD):
--                 TEST-CTX-AREA (Area, DefId 3)
--                   +- TEST-CTX-M1 (DieCastMachine, DefId 8)
--                   +- TEST-CTX-M2 (DieCastMachine, DefId 8)
--                   +- TEST-CTX-MDEP (DieCastMachine, DefId 8, deprecated)
--                   +- TEST-CTX-TERM (Terminal, DefId 7)
--                        +- TEST-CTX-PRN (Printer, DefId 16)
--                   +- TEST-CTX-TERM2 (Terminal, DefId 7, NO printer)
--                   +- TEST-CTX-TDEP (Terminal, DefId 7, deprecated)
--                 TEST-CTX-LINE (Line, DefId 5)
--                   +- TEST-CTX-LTERM (Terminal, DefId 7)
--                        +- TEST-CTX-LPRN (Printer, DefId 16)
-- =============================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0020_PlantFloor_Foundation/015_Terminal_ContextCells_List.sql';
GO

-- ---- teardown any prior fixtures (children before parents) ----
DELETE FROM Location.Location WHERE Code IN (N'TEST-CTX-PRN', N'TEST-CTX-LPRN');
DELETE FROM Location.Location WHERE Code IN (N'TEST-CTX-M1', N'TEST-CTX-M2', N'TEST-CTX-MDEP', N'TEST-CTX-TERM', N'TEST-CTX-TERM2', N'TEST-CTX-LTERM', N'TEST-CTX-TDEP');
DELETE FROM Location.Location WHERE Code IN (N'TEST-CTX-AREA', N'TEST-CTX-LINE');
GO

-- ---- build the fixture subtree ----
DECLARE @SiteId BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MPP-MAD');

INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
VALUES (3, @SiteId, N'Test Ctx Area', N'TEST-CTX-AREA', N'ContextCells test area', 950),
       (5, @SiteId, N'Test Ctx Line', N'TEST-CTX-LINE', N'ContextCells test line', 951);

DECLARE @AreaId BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'TEST-CTX-AREA');
DECLARE @LineId BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'TEST-CTX-LINE');

INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
VALUES (8, @AreaId, N'Ctx Machine 1', N'TEST-CTX-M1',    N'Equipment cell', 1),
       (8, @AreaId, N'Ctx Machine 2', N'TEST-CTX-M2',    N'Equipment cell', 2),
       (7, @AreaId, N'Ctx Terminal',  N'TEST-CTX-TERM',  N'Area terminal', 3),
       (7, @AreaId, N'Ctx Terminal 2',N'TEST-CTX-TERM2', N'Area terminal no printer', 4),
       (7, @LineId, N'Ctx Line Term', N'TEST-CTX-LTERM', N'Line terminal', 1);

INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder, DeprecatedAt)
VALUES (8, @AreaId, N'Ctx Machine Depr', N'TEST-CTX-MDEP', N'Deprecated equipment cell', 5, SYSUTCDATETIME());

DECLARE @TermId  BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'TEST-CTX-TERM');
DECLARE @LTermId BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'TEST-CTX-LTERM');

INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
VALUES (16, @TermId,  N'Ctx Printer',      N'TEST-CTX-PRN',  N'Printer under terminal', 1),
       (16, @LTermId, N'Ctx Line Printer', N'TEST-CTX-LPRN', N'Printer under line terminal', 1);

-- deprecated terminal under the area (for the deprecated-id test)
INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder, DeprecatedAt)
VALUES (7, @AreaId, N'Ctx Terminal Depr', N'TEST-CTX-TDEP', N'Deprecated area terminal', 6, SYSUTCDATETIME());
GO

-- =============================================
-- Test 1: Area terminal -> exactly the two active equipment cells
-- =============================================
DECLARE @TermId BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'TEST-CTX-TERM');
DECLARE @Rows INT, @Codes NVARCHAR(200);
CREATE TABLE #CC (LocationId BIGINT, Code NVARCHAR(50), Name NVARCHAR(200), Kind NVARCHAR(100));
INSERT INTO #CC EXEC Location.Terminal_ListContextCells @TerminalId = @TermId;
SELECT @Rows = COUNT(*) FROM #CC;
SELECT @Codes = STRING_AGG(Code, N',') WITHIN GROUP (ORDER BY Code) FROM #CC;
DROP TABLE #CC;
EXEC test.Assert_RowCount
    @TestName = N'[CtxCells] Area terminal sees exactly the 2 active equipment cells',
    @ExpectedCount = 2, @ActualCount = @Rows;
EXEC test.Assert_IsEqual
    @TestName = N'[CtxCells] Cells are M1+M2 (terminal/printer/deprecated excluded)',
    @Expected = N'TEST-CTX-M1,TEST-CTX-M2', @Actual = @Codes;
GO

-- =============================================
-- Test 2: Line terminal (parent has only terminals/printers) -> empty
-- =============================================
DECLARE @LTermId BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'TEST-CTX-LTERM');
DECLARE @Rows INT;
CREATE TABLE #CL (LocationId BIGINT, Code NVARCHAR(50), Name NVARCHAR(200), Kind NVARCHAR(100));
INSERT INTO #CL EXEC Location.Terminal_ListContextCells @TerminalId = @LTermId;
SELECT @Rows = COUNT(*) FROM #CL;
DROP TABLE #CL;
EXEC test.Assert_RowCount
    @TestName = N'[CtxCells] Line terminal with no equipment cells -> empty set',
    @ExpectedCount = 0, @ActualCount = @Rows;
GO

-- =============================================
-- Test 3: Unknown terminal id -> empty set (never errors)
-- =============================================
DECLARE @Rows INT;
CREATE TABLE #CU (LocationId BIGINT, Code NVARCHAR(50), Name NVARCHAR(200), Kind NVARCHAR(100));
INSERT INTO #CU EXEC Location.Terminal_ListContextCells @TerminalId = -1;
SELECT @Rows = COUNT(*) FROM #CU;
DROP TABLE #CU;
EXEC test.Assert_RowCount
    @TestName = N'[CtxCells] Unknown terminal id -> empty set',
    @ExpectedCount = 0, @ActualCount = @Rows;
GO

-- =============================================
-- Test 3b: Deprecated terminal id -> empty set
-- =============================================
DECLARE @DepTermId BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'TEST-CTX-TDEP');
DECLARE @Rows INT;
CREATE TABLE #CD (LocationId BIGINT, Code NVARCHAR(50), Name NVARCHAR(200), Kind NVARCHAR(100));
INSERT INTO #CD EXEC Location.Terminal_ListContextCells @TerminalId = @DepTermId;
SELECT @Rows = COUNT(*) FROM #CD;
DROP TABLE #CD;
EXEC test.Assert_RowCount
    @TestName = N'[CtxCells] Deprecated terminal id -> empty set',
    @ExpectedCount = 0, @ActualCount = @Rows;
GO

-- =============================================
-- Test 4: Terminal_List v1.1 shape + HasPrinter flags
-- =============================================
DECLARE @HasPrn BIT, @NoPrn BIT, @HasStr NVARCHAR(1), @NoStr NVARCHAR(1);
CREATE TABLE #TL (TerminalId BIGINT, TerminalCode NVARCHAR(50), TerminalName NVARCHAR(200),
                  ZoneId BIGINT, ZoneCode NVARCHAR(50), ZoneName NVARCHAR(200),
                  IpAddress NVARCHAR(255), DefaultScreen NVARCHAR(255), IsFallback BIT, HasPrinter BIT);
INSERT INTO #TL EXEC Location.Terminal_List;
SELECT @HasPrn = HasPrinter FROM #TL WHERE TerminalCode = N'TEST-CTX-TERM';
SELECT @NoPrn  = HasPrinter FROM #TL WHERE TerminalCode = N'TEST-CTX-TERM2';
DROP TABLE #TL;
SET @HasStr = CAST(@HasPrn AS NVARCHAR(1));
SET @NoStr  = CAST(@NoPrn  AS NVARCHAR(1));
EXEC test.Assert_IsEqual
    @TestName = N'[TermList] HasPrinter=1 with an active child Printer',
    @Expected = N'1', @Actual = @HasStr;
EXEC test.Assert_IsEqual
    @TestName = N'[TermList] HasPrinter=0 without a child Printer',
    @Expected = N'0', @Actual = @NoStr;
GO

-- ---- cleanup (children before parents) ----
DELETE FROM Location.Location WHERE Code IN (N'TEST-CTX-PRN', N'TEST-CTX-LPRN');
DELETE FROM Location.Location WHERE Code IN (N'TEST-CTX-M1', N'TEST-CTX-M2', N'TEST-CTX-MDEP', N'TEST-CTX-TERM', N'TEST-CTX-TERM2', N'TEST-CTX-LTERM', N'TEST-CTX-TDEP');
DELETE FROM Location.Location WHERE Code IN (N'TEST-CTX-AREA', N'TEST-CTX-LINE');
GO

EXEC test.EndTestFile;
GO
