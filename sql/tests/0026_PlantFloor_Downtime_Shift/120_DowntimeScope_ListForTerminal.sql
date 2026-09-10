-- =============================================
-- File:         0026_PlantFloor_Downtime_Shift/120_DowntimeScope_ListForTerminal.sql
-- Author:       Blue Ridge Automation
-- Created:      2026-09-09
-- Description:  Oee.DowntimeScope_ListForTerminal -- the downtime units an
--               operator at a terminal may log against, and which one the
--               Downtime Manager preselects (day-one feedback item 3).
--               Asserts, per zone tier of the terminal's parent:
--                 * Area WITH equipment cells (die cast) -> one row per press,
--                   infrastructure (Terminal/Printer) excluded, NO default
--                   until an active cell is supplied.
--                 * Active cell inside the list -> exactly that row IsDefault.
--                 * Active cell OUTSIDE the list -> still no default.
--                 * Area WITHOUT active equipment cells (the live trim shop
--                   configuration: its presses were deprecated 2026-07-30) ->
--                   the AREA itself, IsDefault=1  ("scoped to the Trim shop").
--                   Also asserts the rule flips back to per-machine the moment
--                   an ACTIVE equipment cell appears under the area.
--                 * WorkCenter zone (M&A)   -> the line itself, IsDefault=1.
--                 * Cell zone (dedicated press terminal) -> that cell.
--                 * Site zone (fallback terminal) / unknown / NULL -> empty.
--                 * An AREA-tier scope is a usable downtime location end to
--                   end (Start/End accept it; a missing shift schedule at that
--                   tier does not reject the event -- ShiftId is nullable).
--               Plant-seed fixtures are STRUCTURAL (resolved by zone tier +
--               equipment-cell presence), never by hard-coded Location.Id or
--               Code. The empty-area case is a SYNTHETIC area/terminal built
--               and torn down here, because 011_seed_locations_mpp_plant.sql
--               still seeds TRIM1-P01..P03 that the live plant model has since
--               deprecated -- the seed drift must not decide what this rule is.
--               Pure read proc apart from that last case; the synthetic
--               locations and the one downtime event are torn down at the end.
-- =============================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0026_PlantFloor_Downtime_Shift/120_DowntimeScope_ListForTerminal.sql';
GO

-- ---- shared fixtures ----
IF OBJECT_ID(N'tempdb..#ScFix') IS NOT NULL DROP TABLE #ScFix;
IF OBJECT_ID(N'tempdb..#ScOut') IS NOT NULL DROP TABLE #ScOut;
CREATE TABLE #ScFix (Tag NVARCHAR(20) PRIMARY KEY, Val BIGINT);
CREATE TABLE #ScOut (
    ScopeLocationId BIGINT        NULL,
    Code            NVARCHAR(50)  NULL,
    Name            NVARCHAR(200) NULL,
    Kind            NVARCHAR(100) NULL,
    IsDefault       BIT           NULL
);
GO

-- Every active Terminal-kind Location with the tier of its parent (its "zone"),
-- plus how many EQUIPMENT cells hang beneath that zone. Mirrors the proc's own
-- classification so the fixtures pick genuinely representative terminals.
IF OBJECT_ID(N'tempdb..#ScTerm') IS NOT NULL DROP TABLE #ScTerm;
SELECT t.Id            AS TerminalId,
       p.Id            AS ZoneId,
       plt.Code        AS ZoneTier,
       (SELECT COUNT(*)
        FROM Location.Location e
        INNER JOIN Location.LocationTypeDefinition eltd ON eltd.Id = e.LocationTypeDefinitionId
        INNER JOIN Location.LocationType elt            ON elt.Id  = eltd.LocationTypeId
        WHERE e.ParentLocationId = p.Id
          AND e.DeprecatedAt IS NULL
          AND elt.Code = N'Cell'
          AND eltd.Code NOT IN (N'Terminal', N'Printer', N'InventoryLocation', N'Scale')) AS EquipCells
INTO #ScTerm
FROM Location.Location t
INNER JOIN Location.LocationTypeDefinition tltd ON tltd.Id = t.LocationTypeDefinitionId
INNER JOIN Location.Location p                  ON p.Id    = t.ParentLocationId
INNER JOIN Location.LocationTypeDefinition pltd ON pltd.Id = p.LocationTypeDefinitionId
INNER JOIN Location.LocationType plt            ON plt.Id  = pltd.LocationTypeId
WHERE tltd.Code = N'Terminal'
  AND t.DeprecatedAt IS NULL
  AND p.DeprecatedAt IS NULL;

INSERT INTO #ScFix (Tag, Val)
SELECT N'DC_TERM',  (SELECT TOP 1 TerminalId FROM #ScTerm WHERE ZoneTier = N'Area'       AND EquipCells > 1 ORDER BY TerminalId)
UNION ALL SELECT N'DC_ZONE',  (SELECT TOP 1 ZoneId     FROM #ScTerm WHERE ZoneTier = N'Area'       AND EquipCells > 1 ORDER BY TerminalId)
UNION ALL SELECT N'DC_CELLS', (SELECT TOP 1 EquipCells FROM #ScTerm WHERE ZoneTier = N'Area'       AND EquipCells > 1 ORDER BY TerminalId)
UNION ALL SELECT N'MA_TERM',  (SELECT TOP 1 TerminalId FROM #ScTerm WHERE ZoneTier = N'WorkCenter' ORDER BY TerminalId)
UNION ALL SELECT N'MA_ZONE',  (SELECT TOP 1 ZoneId     FROM #ScTerm WHERE ZoneTier = N'WorkCenter' ORDER BY TerminalId)
UNION ALL SELECT N'DED_TERM', (SELECT TOP 1 TerminalId FROM #ScTerm WHERE ZoneTier = N'Cell'       ORDER BY TerminalId)
UNION ALL SELECT N'DED_ZONE', (SELECT TOP 1 ZoneId     FROM #ScTerm WHERE ZoneTier = N'Cell'       ORDER BY TerminalId)
UNION ALL SELECT N'FB_TERM',  (SELECT TOP 1 TerminalId FROM #ScTerm WHERE ZoneTier = N'Site'       ORDER BY TerminalId);
GO

-- =============================================
-- Test 1: shared area terminal (die cast) -> one row per equipment cell,
--         infrastructure excluded, no default without an active cell
-- =============================================
DECLARE @DcTerm  BIGINT = (SELECT Val FROM #ScFix WHERE Tag = N'DC_TERM');
DECLARE @DcZone  BIGINT = (SELECT Val FROM #ScFix WHERE Tag = N'DC_ZONE');
DECLARE @DcCells INT    = (SELECT CAST(Val AS INT) FROM #ScFix WHERE Tag = N'DC_CELLS');
EXEC test.Assert_IsNotNull @TestName = N'[DtScope] fixture: a shared Area terminal with equipment cells exists', @Value = @DcTerm;

DELETE FROM #ScOut;
INSERT INTO #ScOut EXEC Oee.DowntimeScope_ListForTerminal @TerminalLocationId = @DcTerm;

DECLARE @dcCount INT = (SELECT COUNT(*) FROM #ScOut);
EXEC test.Assert_RowCount @TestName = N'[DtScope] die cast: one row per equipment cell beneath the area',
    @ExpectedCount = @DcCells, @ActualCount = @dcCount;

DECLARE @dcZoneRow INT = (SELECT COUNT(*) FROM #ScOut WHERE ScopeLocationId = @DcZone);
EXEC test.Assert_RowCount @TestName = N'[DtScope] die cast: the AREA itself is not offered as a scope',
    @ExpectedCount = 0, @ActualCount = @dcZoneRow;

DECLARE @dcInfra INT = (SELECT COUNT(*) FROM #ScOut o
    INNER JOIN Location.Location l                  ON l.Id   = o.ScopeLocationId
    INNER JOIN Location.LocationTypeDefinition ltd  ON ltd.Id = l.LocationTypeDefinitionId
    WHERE ltd.Code IN (N'Terminal', N'Printer', N'InventoryLocation', N'Scale'));
EXEC test.Assert_RowCount @TestName = N'[DtScope] die cast: infrastructure cells (Terminal/Printer/Inventory/Scale) excluded',
    @ExpectedCount = 0, @ActualCount = @dcInfra;

DECLARE @dcDef INT = (SELECT COUNT(*) FROM #ScOut WHERE IsDefault = 1);
EXEC test.Assert_RowCount @TestName = N'[DtScope] die cast: no default when the operator has no active cell (never guess a press)',
    @ExpectedCount = 0, @ActualCount = @dcDef;
GO

-- =============================================
-- Test 2: active cell inside the list -> exactly that row is the default
-- =============================================
DECLARE @DcTerm BIGINT = (SELECT Val FROM #ScFix WHERE Tag = N'DC_TERM');
DECLARE @DcZone BIGINT = (SELECT Val FROM #ScFix WHERE Tag = N'DC_ZONE');
DECLARE @Press  BIGINT = (SELECT TOP 1 l.Id FROM Location.Location l
    INNER JOIN Location.LocationTypeDefinition ltd ON ltd.Id = l.LocationTypeDefinitionId
    INNER JOIN Location.LocationType lt            ON lt.Id  = ltd.LocationTypeId
    WHERE l.ParentLocationId = @DcZone AND l.DeprecatedAt IS NULL
      AND lt.Code = N'Cell' AND ltd.Code NOT IN (N'Terminal', N'Printer', N'InventoryLocation', N'Scale')
    ORDER BY l.Code DESC);
EXEC test.Assert_IsNotNull @TestName = N'[DtScope] fixture: a press under the die cast area exists', @Value = @Press;

DELETE FROM #ScOut;
INSERT INTO #ScOut EXEC Oee.DowntimeScope_ListForTerminal
    @TerminalLocationId = @DcTerm, @ActiveCellLocationId = @Press;

DECLARE @defCnt INT = (SELECT COUNT(*) FROM #ScOut WHERE IsDefault = 1);
EXEC test.Assert_RowCount @TestName = N'[DtScope] die cast: exactly one default when an active cell is supplied',
    @ExpectedCount = 1, @ActualCount = @defCnt;

DECLARE @defIsPress INT = (SELECT COUNT(*) FROM #ScOut WHERE IsDefault = 1 AND ScopeLocationId = @Press);
EXEC test.Assert_RowCount @TestName = N'[DtScope] die cast: the default IS the operator''s active press',
    @ExpectedCount = 1, @ActualCount = @defIsPress;
GO

-- =============================================
-- Test 3: active cell OUTSIDE the terminal's options -> still no default
-- =============================================
DECLARE @DcTerm  BIGINT = (SELECT Val FROM #ScFix WHERE Tag = N'DC_TERM');
DECLARE @Foreign BIGINT = (SELECT Val FROM #ScFix WHERE Tag = N'MA_ZONE');   -- an M&A line, never under the die cast area

DELETE FROM #ScOut;
INSERT INTO #ScOut EXEC Oee.DowntimeScope_ListForTerminal
    @TerminalLocationId = @DcTerm, @ActiveCellLocationId = @Foreign;

DECLARE @fgnDef INT = (SELECT COUNT(*) FROM #ScOut WHERE IsDefault = 1);
EXEC test.Assert_RowCount @TestName = N'[DtScope] an active cell outside the terminal''s scopes sets no default',
    @ExpectedCount = 0, @ActualCount = @fgnDef;
GO

-- =============================================
-- Test 4: area with NO ACTIVE equipment cells -> the AREA itself, defaulted.
--         This is the live trim shop: TRIM1's presses were deprecated
--         2026-07-30, so downtime is "scoped to the Trim shop". Built
--         synthetically so the (stale) trim-press seed cannot decide the rule.
-- =============================================
DECLARE @Facility BIGINT = (SELECT TOP 1 l.Id FROM Location.Location l
    INNER JOIN Location.LocationTypeDefinition ltd ON ltd.Id = l.LocationTypeDefinitionId
    INNER JOIN Location.LocationType lt            ON lt.Id  = ltd.LocationTypeId
    WHERE lt.Code = N'Site' AND l.DeprecatedAt IS NULL ORDER BY l.Id);
DECLARE @AreaDef  BIGINT = (SELECT Id FROM Location.LocationTypeDefinition WHERE Code = N'ProductionArea');
DECLARE @TermDef  BIGINT = (SELECT Id FROM Location.LocationTypeDefinition WHERE Code = N'Terminal');
DECLARE @PressDef BIGINT = (SELECT Id FROM Location.LocationTypeDefinition WHERE Code = N'TrimPress');
DECLARE @InvDef   BIGINT = (SELECT Id FROM Location.LocationTypeDefinition WHERE Code = N'InventoryLocation');
EXEC test.Assert_IsNotNull @TestName = N'[DtScope] fixture: the Facility (Site tier) exists', @Value = @Facility;

INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
VALUES (@AreaDef, @Facility, N'DtScope Test Shop', N'ZZ-DTSCOPE', N'120_DowntimeScope test fixture', 999);
DECLARE @SynArea BIGINT = SCOPE_IDENTITY();
INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
VALUES (@TermDef, @SynArea, N'Terminal', N'ZZ-DTSCOPE-T1', N'120_DowntimeScope test fixture', 1);
DECLARE @SynTerm BIGINT = SCOPE_IDENTITY();
-- Infrastructure that must NOT turn the shop into a machine list (the real
-- TRIM1-STORE inventory location is exactly this case).
INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
VALUES (@InvDef, @SynArea, N'Storage', N'ZZ-DTSCOPE-STORE', N'120_DowntimeScope test fixture', 2);
-- A DEPRECATED press: decommissioned equipment must not resurrect the dropdown.
INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder, DeprecatedAt)
VALUES (@PressDef, @SynArea, N'Old Press', N'ZZ-DTSCOPE-P01', N'120_DowntimeScope test fixture', 3, SYSUTCDATETIME());
INSERT INTO #ScFix (Tag, Val) VALUES (N'SYN_AREA', @SynArea), (N'SYN_TERM', @SynTerm);

DELETE FROM #ScOut;
INSERT INTO #ScOut EXEC Oee.DowntimeScope_ListForTerminal @TerminalLocationId = @SynTerm;

DECLARE @synCnt INT = (SELECT COUNT(*) FROM #ScOut);
EXEC test.Assert_RowCount @TestName = N'[DtScope] trim-shaped area: exactly one scope row',
    @ExpectedCount = 1, @ActualCount = @synCnt;

DECLARE @synIsArea INT = (SELECT COUNT(*) FROM #ScOut WHERE ScopeLocationId = @SynArea AND IsDefault = 1);
EXEC test.Assert_RowCount @TestName = N'[DtScope] trim-shaped area: the scope IS the shop (the Area) and is the default',
    @ExpectedCount = 1, @ActualCount = @synIsArea;
GO

-- =============================================
-- Test 5: the same area gains an ACTIVE equipment cell -> per-machine again
-- =============================================
DECLARE @SynArea BIGINT = (SELECT Val FROM #ScFix WHERE Tag = N'SYN_AREA');
DECLARE @SynTerm BIGINT = (SELECT Val FROM #ScFix WHERE Tag = N'SYN_TERM');
DECLARE @PressDef BIGINT = (SELECT Id FROM Location.LocationTypeDefinition WHERE Code = N'TrimPress');
INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
VALUES (@PressDef, @SynArea, N'Live Press', N'ZZ-DTSCOPE-P02', N'120_DowntimeScope test fixture', 4);
DECLARE @SynPress BIGINT = SCOPE_IDENTITY();
INSERT INTO #ScFix (Tag, Val) VALUES (N'SYN_PRESS', @SynPress);

DELETE FROM #ScOut;
INSERT INTO #ScOut EXEC Oee.DowntimeScope_ListForTerminal @TerminalLocationId = @SynTerm;

DECLARE @actCnt INT = (SELECT COUNT(*) FROM #ScOut);
EXEC test.Assert_RowCount @TestName = N'[DtScope] an ACTIVE equipment cell replaces the area scope with the machine list',
    @ExpectedCount = 1, @ActualCount = @actCnt;

DECLARE @actIsPress INT = (SELECT COUNT(*) FROM #ScOut WHERE ScopeLocationId = @SynPress AND IsDefault = 1);
EXEC test.Assert_RowCount @TestName = N'[DtScope] the lone active machine is the scope (and, being alone, the default)',
    @ExpectedCount = 1, @ActualCount = @actIsPress;
GO

-- =============================================
-- Test 6: WorkCenter zone (M&A) -> the line itself; contract unchanged
-- =============================================
DECLARE @MaTerm BIGINT = (SELECT Val FROM #ScFix WHERE Tag = N'MA_TERM');
DECLARE @MaZone BIGINT = (SELECT Val FROM #ScFix WHERE Tag = N'MA_ZONE');
EXEC test.Assert_IsNotNull @TestName = N'[DtScope] fixture: an M&A terminal on a WorkCenter line exists', @Value = @MaTerm;

DELETE FROM #ScOut;
INSERT INTO #ScOut EXEC Oee.DowntimeScope_ListForTerminal @TerminalLocationId = @MaTerm;

DECLARE @maCnt INT = (SELECT COUNT(*) FROM #ScOut);
EXEC test.Assert_RowCount @TestName = N'[DtScope] M&A: exactly one scope row (line-level downtime, unchanged)',
    @ExpectedCount = 1, @ActualCount = @maCnt;

DECLARE @maIsLine INT = (SELECT COUNT(*) FROM #ScOut WHERE ScopeLocationId = @MaZone AND IsDefault = 1);
EXEC test.Assert_RowCount @TestName = N'[DtScope] M&A: the scope IS the line and is the default',
    @ExpectedCount = 1, @ActualCount = @maIsLine;

-- The proc must agree with the existing resolver for every M&A terminal.
DECLARE @maResolved BIGINT = Oee.ufn_ResolveDowntimeScope(@MaTerm);
DECLARE @maAgrees INT = (SELECT COUNT(*) FROM #ScOut WHERE ScopeLocationId = @maResolved);
EXEC test.Assert_RowCount @TestName = N'[DtScope] M&A: agrees with Oee.ufn_ResolveDowntimeScope',
    @ExpectedCount = 1, @ActualCount = @maAgrees;
GO

-- =============================================
-- Test 7: Cell zone (dedicated machine terminal) -> that cell, defaulted
-- =============================================
DECLARE @DedTerm BIGINT = (SELECT Val FROM #ScFix WHERE Tag = N'DED_TERM');
DECLARE @DedZone BIGINT = (SELECT Val FROM #ScFix WHERE Tag = N'DED_ZONE');
EXEC test.Assert_IsNotNull @TestName = N'[DtScope] fixture: a dedicated machine terminal (Cell zone) exists', @Value = @DedTerm;

DELETE FROM #ScOut;
INSERT INTO #ScOut EXEC Oee.DowntimeScope_ListForTerminal @TerminalLocationId = @DedTerm;

DECLARE @dedCnt INT = (SELECT COUNT(*) FROM #ScOut);
EXEC test.Assert_RowCount @TestName = N'[DtScope] dedicated machine terminal: exactly one scope row',
    @ExpectedCount = 1, @ActualCount = @dedCnt;

DECLARE @dedIsCell INT = (SELECT COUNT(*) FROM #ScOut WHERE ScopeLocationId = @DedZone AND IsDefault = 1);
EXEC test.Assert_RowCount @TestName = N'[DtScope] dedicated machine terminal: the scope IS its own cell, defaulted',
    @ExpectedCount = 1, @ActualCount = @dedIsCell;
GO

-- =============================================
-- Test 8: fallback terminal (Site zone) / unknown id / NULL id -> empty set.
--         The fallback guard matters: its zone is the FACILITY, and returning
--         it would scope downtime plant-wide.
-- =============================================
DECLARE @FbTerm BIGINT = (SELECT Val FROM #ScFix WHERE Tag = N'FB_TERM');
EXEC test.Assert_IsNotNull @TestName = N'[DtScope] fixture: the fallback terminal (Site zone) exists', @Value = @FbTerm;

DELETE FROM #ScOut;
INSERT INTO #ScOut EXEC Oee.DowntimeScope_ListForTerminal @TerminalLocationId = @FbTerm;
DECLARE @fbCnt INT = (SELECT COUNT(*) FROM #ScOut);
EXEC test.Assert_RowCount @TestName = N'[DtScope] fallback terminal returns NO scope (never plant-wide downtime)',
    @ExpectedCount = 0, @ActualCount = @fbCnt;

DELETE FROM #ScOut;
INSERT INTO #ScOut EXEC Oee.DowntimeScope_ListForTerminal @TerminalLocationId = -999999;
DECLARE @unkCnt INT = (SELECT COUNT(*) FROM #ScOut);
EXEC test.Assert_RowCount @TestName = N'[DtScope] unknown terminal id returns an empty set',
    @ExpectedCount = 0, @ActualCount = @unkCnt;

DELETE FROM #ScOut;
INSERT INTO #ScOut EXEC Oee.DowntimeScope_ListForTerminal @TerminalLocationId = NULL;
DECLARE @nulCnt INT = (SELECT COUNT(*) FROM #ScOut);
EXEC test.Assert_RowCount @TestName = N'[DtScope] NULL terminal id returns an empty set',
    @ExpectedCount = 0, @ActualCount = @nulCnt;
GO

-- =============================================
-- Test 9: an AREA-tier scope is a usable downtime location end to end.
--         The trim shop is an Area, and until now every downtime row was written
--         against a Cell or a WorkCenter -- so prove Start/End accept an Area and
--         that a missing shift schedule at that tier does not reject the event
--         (Oee.DowntimeEvent.ShiftId is nullable by design).
-- =============================================
DECLARE @SynArea BIGINT = (SELECT Val FROM #ScFix WHERE Tag = N'SYN_AREA');
DECLARE @OpSrc   BIGINT = (SELECT Id FROM Oee.DowntimeSourceCode WHERE Code = N'Operator');
DECLARE @st TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO @st EXEC Oee.DowntimeEvent_Start
    @LocationId = @SynArea, @DowntimeSourceCodeId = @OpSrc, @AppUserId = 1;
DECLARE @stOk BIT    = (SELECT Status FROM @st);
DECLARE @stId BIGINT = (SELECT NewId  FROM @st);
EXEC test.Assert_IsTrue @TestName = N'[DtScope] downtime STARTS against an Area-tier scope (the trim shop)', @Condition = @stOk;

DECLARE @atArea INT = (SELECT COUNT(*) FROM Oee.DowntimeEvent WHERE Id = @stId AND LocationId = @SynArea AND EndedAt IS NULL);
EXEC test.Assert_RowCount @TestName = N'[DtScope] the open event is stamped with the Area LocationId',
    @ExpectedCount = 1, @ActualCount = @atArea;

DECLARE @en TABLE (Status BIT, Message NVARCHAR(500));
INSERT INTO @en EXEC Oee.DowntimeEvent_End @DowntimeEventId = @stId, @AppUserId = 1;
DECLARE @enOk BIT = (SELECT Status FROM @en);
EXEC test.Assert_IsTrue @TestName = N'[DtScope] downtime ENDS against an Area-tier scope', @Condition = @enOk;

-- And the manager read finds it through the same scope the picker offered.
DELETE FROM #ScOut;
DECLARE @seen INT = (SELECT COUNT(*) FROM Oee.DowntimeEvent WHERE LocationId = @SynArea);
EXEC test.Assert_RowCount @TestName = N'[DtScope] exactly one event now sits at the Area scope',
    @ExpectedCount = 1, @ActualCount = @seen;
GO

-- ---- cleanup: downtime + its audit rows, then locations (children first) ----
DECLARE @SynArea BIGINT = (SELECT Val FROM #ScFix WHERE Tag = N'SYN_AREA');
DELETE ol FROM Audit.OperationLog ol
    INNER JOIN Oee.DowntimeEvent de ON de.Id = ol.EntityId
    WHERE de.LocationId = @SynArea
      AND ol.LogEntityTypeId = (SELECT Id FROM Audit.LogEntityType WHERE Code = N'DowntimeEvent');
DELETE FROM Oee.DowntimeEvent WHERE LocationId = @SynArea;
DELETE FROM Location.Location WHERE Code LIKE N'ZZ-DTSCOPE-%';
DELETE FROM Location.Location WHERE Code = N'ZZ-DTSCOPE';
IF OBJECT_ID(N'tempdb..#ScFix')  IS NOT NULL DROP TABLE #ScFix;
IF OBJECT_ID(N'tempdb..#ScOut')  IS NOT NULL DROP TABLE #ScOut;
IF OBJECT_ID(N'tempdb..#ScTerm') IS NOT NULL DROP TABLE #ScTerm;
GO
