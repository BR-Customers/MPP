-- =============================================
-- File:         helpers/0117_fixture_oee_dashboard.sql
-- Author:       Blue Ridge Automation
-- Created:      2026-10-29
-- Description:  Location fixture for the OEE dashboard suites
--               (sql/tests/0117_Oee_Dashboard). One small plant with every
--               shape the dashboard groups and pools:
--
--   ZZ-DSH-DC          ProductionArea   (a press shop -> diecast)
--     ZZ-DSH-DC-M1     DieCastMachine   FLAGGED
--       ZZ-DSH-DC-M1-T1 Terminal
--     ZZ-DSH-DC-M2     DieCastMachine   FLAGGED
--   ZZ-DSH-TR          ProductionArea   (a trim shop -> trim; scrap lands here)
--     ZZ-DSH-TR-P1     TrimPress        FLAGGED
--     ZZ-DSH-TR-P2     TrimPress        FLAGGED
--     ZZ-DSH-TR-T1     Terminal         (shop terminal)
--   ZZ-DSH-MA          ProductionArea   (-> ma)
--     ZZ-DSH-MA-L      ProductionLine   FLAGGED   (a split line)
--       ZZ-DSH-MA-L-T1 Terminal
--       ZZ-DSH-MA-L-MI CNCMachine       FLAGGED   (station)
--       ZZ-DSH-MA-L-A  AssemblyStation  FLAGGED   (station)
--     ZZ-DSH-MA-P      ProductionLine   FLAGGED   (a plain line)
--   ZZ-DSH-IN          ProductionArea   (inspection -> ma, Jacques 2026-10-29)
--     ZZ-DSH-IN-L      InspectionLine   FLAGGED
--   ZZ-DSH-SUP         SupportArea      (no OEE unit anywhere beneath)
--     ZZ-DSH-SUP-T1    Terminal
--
--               Every code starts ZZ-DSH so teardown is a prefix sweep. The
--               teardown also clears the dashboard rows tests hang on these
--               locations (downtime, rejects, contributions, production events).
-- =============================================
IF OBJECT_ID(N'test.OeeDashFixture_Teardown', N'P') IS NOT NULL DROP PROCEDURE test.OeeDashFixture_Teardown;
GO
CREATE PROCEDURE test.OeeDashFixture_Teardown
AS
BEGIN
    SET NOCOUNT ON;

    DELETE re FROM Workorder.RejectEvent re
    WHERE re.CellLocationId     IN (SELECT Id FROM Location.Location WHERE Code LIKE N'ZZ-DSH%')
       OR re.TerminalLocationId IN (SELECT Id FROM Location.Location WHERE Code LIKE N'ZZ-DSH%')
       OR re.Remarks LIKE N'ZZ-DSH%';

    DELETE de FROM Oee.DowntimeEvent de
    INNER JOIN Location.Location l ON l.Id = de.LocationId
    WHERE l.Code LIKE N'ZZ-DSH%';

    DELETE so FROM Oee.ShiftOverride so
    INNER JOIN Location.Location l ON l.Id = so.LocationId
    WHERE l.Code LIKE N'ZZ-DSH%';

    WHILE EXISTS (SELECT 1 FROM Location.Location WHERE Code LIKE N'ZZ-DSH%')
    BEGIN
        DELETE l
        FROM Location.Location l
        WHERE l.Code LIKE N'ZZ-DSH%'
          AND NOT EXISTS (SELECT 1 FROM Location.Location c WHERE c.ParentLocationId = l.Id);
        IF @@ROWCOUNT = 0 BREAK;   -- something else references a row; stop rather than spin
    END
END
GO

IF OBJECT_ID(N'test.OeeDashFixture_Build', N'P') IS NOT NULL DROP PROCEDURE test.OeeDashFixture_Build;
GO
CREATE PROCEDURE test.OeeDashFixture_Build
AS
BEGIN
    SET NOCOUNT ON;
    EXEC test.OeeDashFixture_Teardown;

    DECLARE @Site BIGINT = (SELECT TOP 1 l.Id FROM Location.Location l
        INNER JOIN Location.LocationTypeDefinition ltd ON ltd.Id = l.LocationTypeDefinitionId
        INNER JOIN Location.LocationType lt            ON lt.Id  = ltd.LocationTypeId
        WHERE lt.Code = N'Site' AND l.DeprecatedAt IS NULL ORDER BY l.Id);

    DECLARE @Spec TABLE (
        Lvl INT, DefCode NVARCHAR(50), ParentCode NVARCHAR(50), Name NVARCHAR(200),
        Code NVARCHAR(50), SortOrder INT, Flag BIT);

    INSERT INTO @Spec (Lvl, DefCode, ParentCode, Name, Code, SortOrder, Flag) VALUES
        (1, N'ProductionArea',  NULL,          N'DSH Die Cast',      N'ZZ-DSH-DC',       980, 0),
        (1, N'ProductionArea',  NULL,          N'DSH Trim Shop',     N'ZZ-DSH-TR',       981, 0),
        (1, N'ProductionArea',  NULL,          N'DSH M and A',       N'ZZ-DSH-MA',       982, 0),
        (1, N'ProductionArea',  NULL,          N'DSH Inspection',    N'ZZ-DSH-IN',       983, 0),
        (1, N'SupportArea',     NULL,          N'DSH Support',       N'ZZ-DSH-SUP',      984, 0),
        (2, N'DieCastMachine',  N'ZZ-DSH-DC',  N'DSH Press 1',       N'ZZ-DSH-DC-M1',      1, 1),
        (2, N'DieCastMachine',  N'ZZ-DSH-DC',  N'DSH Press 2',       N'ZZ-DSH-DC-M2',      2, 1),
        (2, N'TrimPress',       N'ZZ-DSH-TR',  N'DSH Trim Press 1',  N'ZZ-DSH-TR-P1',      1, 1),
        (2, N'TrimPress',       N'ZZ-DSH-TR',  N'DSH Trim Press 2',  N'ZZ-DSH-TR-P2',      2, 1),
        (2, N'Terminal',        N'ZZ-DSH-TR',  N'Trim Terminal',     N'ZZ-DSH-TR-T1',      9, 0),
        (2, N'ProductionLine',  N'ZZ-DSH-MA',  N'DSH Split Line',    N'ZZ-DSH-MA-L',       1, 1),
        (2, N'ProductionLine',  N'ZZ-DSH-MA',  N'DSH Plain Line',    N'ZZ-DSH-MA-P',       2, 1),
        (2, N'InspectionLine',  N'ZZ-DSH-IN',  N'DSH Inspect Line',  N'ZZ-DSH-IN-L',       1, 1),
        (2, N'Terminal',        N'ZZ-DSH-SUP', N'Support Terminal',  N'ZZ-DSH-SUP-T1',     1, 0),
        (3, N'Terminal',        N'ZZ-DSH-DC-M1', N'Press Terminal',  N'ZZ-DSH-DC-M1-T1',   1, 0),
        (3, N'Terminal',        N'ZZ-DSH-MA-L',  N'Line Terminal',   N'ZZ-DSH-MA-L-T1',    1, 0),
        (3, N'CNCMachine',      N'ZZ-DSH-MA-L',  N'Machining',       N'ZZ-DSH-MA-L-MI',    2, 1),
        (3, N'AssemblyStation', N'ZZ-DSH-MA-L',  N'Assembly A',      N'ZZ-DSH-MA-L-A',     3, 1);

    DECLARE @Lvl INT = 1;
    WHILE @Lvl <= 3
    BEGIN
        INSERT INTO Location.Location
            (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder, IsOeeEnabled)
        SELECT d.Id, COALESCE(p.Id, @Site), s.Name, s.Code, N'OEE dashboard test fixture', s.SortOrder, s.Flag
        FROM @Spec s
        INNER JOIN Location.LocationTypeDefinition d ON d.Code = s.DefCode
        LEFT  JOIN Location.Location p               ON p.Code = s.ParentCode AND p.DeprecatedAt IS NULL
        WHERE s.Lvl = @Lvl;
        SET @Lvl = @Lvl + 1;
    END
END
GO
