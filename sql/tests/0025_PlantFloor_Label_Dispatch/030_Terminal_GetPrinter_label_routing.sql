-- =============================================
-- File:         0025_PlantFloor_Label_Dispatch/030_Terminal_GetPrinter_label_routing.sql
-- Author:       Blue Ridge Automation
-- Created:      2026-07-28
-- Description:  Location.Terminal_GetPrinter v2.0 label-type routing.
--               Asserts:
--                 * @LabelTypeCode matches a printer whose LabelTypes CSV contains it
--                 * no match -> falls back to the terminal's TOP 1 by SortOrder
--                 * blank LabelTypes -> always the fallback (backward compatible)
--                 * @LabelTypeCode NULL -> v1 behaviour exactly (TOP 1 by SortOrder)
--                 * terminal with no printer child -> empty rowset
--
--               Fixture subtree under the Site (MPP-MAD):
--                 TEST-LTR-TERM (Terminal, DefId 7)
--                   +- TEST-LTR-P1 (Printer, DefId 16, SortOrder 1, LabelTypes 'Primary')
--                   +- TEST-LTR-P2 (Printer, DefId 16, SortOrder 2, LabelTypes 'Container')
--                 TEST-LTR-TERM2 (Terminal, DefId 7)
--                   +- TEST-LTR-P3 (Printer, DefId 16, SortOrder 1, LabelTypes blank)
--                 TEST-LTR-TERM3 (Terminal, DefId 7, NO printer)
-- =============================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0025_PlantFloor_Label_Dispatch/030_Terminal_GetPrinter_label_routing.sql';
GO

-- ---- teardown (attributes, then children, then parents) ----
DELETE FROM Location.LocationAttribute
WHERE LocationId IN (SELECT Id FROM Location.Location
                     WHERE Code IN (N'TEST-LTR-P1', N'TEST-LTR-P2', N'TEST-LTR-P3'));
DELETE FROM Location.Location WHERE Code IN (N'TEST-LTR-P1', N'TEST-LTR-P2', N'TEST-LTR-P3');
DELETE FROM Location.Location WHERE Code IN (N'TEST-LTR-TERM', N'TEST-LTR-TERM2', N'TEST-LTR-TERM3');
GO

-- ---- fixture ----
DECLARE @SiteId BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MPP-MAD');

INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
VALUES (7, @SiteId, N'LTR Terminal',   N'TEST-LTR-TERM',  N'Label routing test terminal', 960),
       (7, @SiteId, N'LTR Terminal 2', N'TEST-LTR-TERM2', N'Blank LabelTypes terminal',   961),
       (7, @SiteId, N'LTR Terminal 3', N'TEST-LTR-TERM3', N'No printer terminal',         962);

DECLARE @T1 BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'TEST-LTR-TERM');
DECLARE @T2 BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'TEST-LTR-TERM2');

INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
VALUES (16, @T1, N'LTR Printer 1', N'TEST-LTR-P1', N'Primary label printer',   1),
       (16, @T1, N'LTR Printer 2', N'TEST-LTR-P2', N'Container label printer', 2),
       (16, @T2, N'LTR Printer 3', N'TEST-LTR-P3', N'Blank LabelTypes',        1);

DECLARE @EpDef BIGINT = (SELECT Id FROM Location.LocationAttributeDefinition
                         WHERE LocationTypeDefinitionId = 16 AND AttributeName = N'Endpoint');
DECLARE @LtDef BIGINT = (SELECT Id FROM Location.LocationAttributeDefinition
                         WHERE LocationTypeDefinitionId = 16 AND AttributeName = N'LabelTypes');

INSERT INTO Location.LocationAttribute (LocationId, LocationAttributeDefinitionId, AttributeValue)
SELECT Id, @EpDef, N'10.0.0.1:9100' FROM Location.Location WHERE Code = N'TEST-LTR-P1'
UNION ALL SELECT Id, @EpDef, N'10.0.0.2:9100' FROM Location.Location WHERE Code = N'TEST-LTR-P2'
UNION ALL SELECT Id, @EpDef, N'10.0.0.3:9100' FROM Location.Location WHERE Code = N'TEST-LTR-P3'
UNION ALL SELECT Id, @LtDef, N'Primary'       FROM Location.Location WHERE Code = N'TEST-LTR-P1'
UNION ALL SELECT Id, @LtDef, N'Container,Master' FROM Location.Location WHERE Code = N'TEST-LTR-P2';
GO

-- =============================================
-- Test 1: 'Container' routes to P2, not the SortOrder-1 printer
-- =============================================
DECLARE @T1 BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'TEST-LTR-TERM');
DECLARE @Code NVARCHAR(50);
CREATE TABLE #R1 (LocationId BIGINT, Code NVARCHAR(50), Name NVARCHAR(200),
                  Endpoint NVARCHAR(200), Model NVARCHAR(200), LabelTypes NVARCHAR(200));
INSERT INTO #R1 EXEC Location.Terminal_GetPrinter @TerminalLocationId = @T1, @LabelTypeCode = N'Container';
SELECT @Code = Code FROM #R1; DROP TABLE #R1;
EXEC test.Assert_IsEqual @TestName = N'[LabelRouting] Container routes to the Container printer',
    @Expected = N'TEST-LTR-P2', @Actual = @Code;
GO

-- =============================================
-- Test 2: second CSV entry ('Master') also matches P2
-- =============================================
DECLARE @T1 BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'TEST-LTR-TERM');
DECLARE @Code NVARCHAR(50);
CREATE TABLE #R2 (LocationId BIGINT, Code NVARCHAR(50), Name NVARCHAR(200),
                  Endpoint NVARCHAR(200), Model NVARCHAR(200), LabelTypes NVARCHAR(200));
INSERT INTO #R2 EXEC Location.Terminal_GetPrinter @TerminalLocationId = @T1, @LabelTypeCode = N'Master';
SELECT @Code = Code FROM #R2; DROP TABLE #R2;
EXEC test.Assert_IsEqual @TestName = N'[LabelRouting] Second CSV entry matches',
    @Expected = N'TEST-LTR-P2', @Actual = @Code;
GO

-- =============================================
-- Test 3: unmatched label type falls back to TOP 1 by SortOrder
-- =============================================
DECLARE @T1 BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'TEST-LTR-TERM');
DECLARE @Code NVARCHAR(50);
CREATE TABLE #R3 (LocationId BIGINT, Code NVARCHAR(50), Name NVARCHAR(200),
                  Endpoint NVARCHAR(200), Model NVARCHAR(200), LabelTypes NVARCHAR(200));
INSERT INTO #R3 EXEC Location.Terminal_GetPrinter @TerminalLocationId = @T1, @LabelTypeCode = N'Void';
SELECT @Code = Code FROM #R3; DROP TABLE #R3;
EXEC test.Assert_IsEqual @TestName = N'[LabelRouting] Unmatched type falls back to SortOrder 1',
    @Expected = N'TEST-LTR-P1', @Actual = @Code;
GO

-- =============================================
-- Test 4: blank LabelTypes -> fallback (backward compatible)
-- =============================================
DECLARE @T2 BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'TEST-LTR-TERM2');
DECLARE @Code NVARCHAR(50);
CREATE TABLE #R4 (LocationId BIGINT, Code NVARCHAR(50), Name NVARCHAR(200),
                  Endpoint NVARCHAR(200), Model NVARCHAR(200), LabelTypes NVARCHAR(200));
INSERT INTO #R4 EXEC Location.Terminal_GetPrinter @TerminalLocationId = @T2, @LabelTypeCode = N'Container';
SELECT @Code = Code FROM #R4; DROP TABLE #R4;
EXEC test.Assert_IsEqual @TestName = N'[LabelRouting] Blank LabelTypes still resolves via fallback',
    @Expected = N'TEST-LTR-P3', @Actual = @Code;
GO

-- =============================================
-- Test 5: NULL label type reproduces v1 behaviour (regression guard)
-- =============================================
DECLARE @T1 BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'TEST-LTR-TERM');
DECLARE @Code NVARCHAR(50);
CREATE TABLE #R5 (LocationId BIGINT, Code NVARCHAR(50), Name NVARCHAR(200),
                  Endpoint NVARCHAR(200), Model NVARCHAR(200), LabelTypes NVARCHAR(200));
INSERT INTO #R5 EXEC Location.Terminal_GetPrinter @TerminalLocationId = @T1;
SELECT @Code = Code FROM #R5; DROP TABLE #R5;
EXEC test.Assert_IsEqual @TestName = N'[LabelRouting] NULL label type = v1 TOP 1 by SortOrder',
    @Expected = N'TEST-LTR-P1', @Actual = @Code;
GO

-- =============================================
-- Test 6: terminal with no printer child -> empty rowset
-- =============================================
DECLARE @T3 BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'TEST-LTR-TERM3');
DECLARE @Rows INT;
CREATE TABLE #R6 (LocationId BIGINT, Code NVARCHAR(50), Name NVARCHAR(200),
                  Endpoint NVARCHAR(200), Model NVARCHAR(200), LabelTypes NVARCHAR(200));
INSERT INTO #R6 EXEC Location.Terminal_GetPrinter @TerminalLocationId = @T3, @LabelTypeCode = N'Primary';
SELECT @Rows = COUNT(*) FROM #R6; DROP TABLE #R6;
EXEC test.Assert_RowCount @TestName = N'[LabelRouting] Terminal with no printer -> empty set',
    @ExpectedCount = 0, @ActualCount = @Rows;
GO
