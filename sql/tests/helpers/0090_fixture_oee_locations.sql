-- =============================================
-- Helper: test.OeeFixture_Build / test.OeeFixture_Teardown
-- A synthetic plant branch for the OEE-flag tests, covering every shape the
-- rules have to handle. All codes start ZZ-OEE so teardown is a prefix sweep.
--
--   ZZ-OEE            Area
--     ZZ-OEE-L        ProductionLine   FLAGGED   (a split line)
--       ZZ-OEE-L-T1   Terminal
--       ZZ-OEE-L-MI   CNCMachine       FLAGGED
--       ZZ-OEE-L-A    AssemblyStation  FLAGGED
--       ZZ-OEE-L-B    AssemblyStation  FLAGGED
--     ZZ-OEE-P        ProductionLine   FLAGGED   (a plain line)
--       ZZ-OEE-P-T1   Terminal
--   ZZ-OEE-DC         Area                       (a press shop)
--     ZZ-OEE-DC-M1    DieCastMachine   FLAGGED
--       ZZ-OEE-DC-M1-T1 Terminal                 (dedicated terminal)
--     ZZ-OEE-DC-M2    DieCastMachine   FLAGGED
--     ZZ-OEE-DC-M3    DieCastMachine   FLAGGED but DEPRECATED
--     ZZ-OEE-DC-T1    Terminal                   (shared terminal)
--   ZZ-OEE-E          Area                       (a shop with no equipment)
--     ZZ-OEE-E-T1     Terminal
--     ZZ-OEE-E-STORE  InventoryLocation
--
-- Rows are inserted directly (not through Location_SaveAll) so the fixture can
-- create the deprecated-but-flagged press that no write path would allow.
-- =============================================
IF OBJECT_ID(N'test.OeeFixture_Teardown', N'P') IS NOT NULL DROP PROCEDURE test.OeeFixture_Teardown;
GO
CREATE PROCEDURE test.OeeFixture_Teardown
AS
BEGIN
    SET NOCOUNT ON;

    DELETE ol
    FROM Audit.OperationLog ol
    INNER JOIN Oee.DowntimeEvent de ON de.Id = ol.EntityId
    INNER JOIN Location.Location l  ON l.Id  = de.LocationId
    WHERE l.Code LIKE N'ZZ-OEE%'
      AND ol.LogEntityTypeId = (SELECT Id FROM Audit.LogEntityType WHERE Code = N'DowntimeEvent');

    DELETE de FROM Oee.DowntimeEvent de
    INNER JOIN Location.Location l ON l.Id = de.LocationId
    WHERE l.Code LIKE N'ZZ-OEE%';

    DELETE so FROM Oee.ShiftOverride so
    INNER JOIN Location.Location l ON l.Id = so.LocationId
    WHERE l.Code LIKE N'ZZ-OEE%';

    DELETE la FROM Location.LocationAttribute la
    INNER JOIN Location.Location l ON l.Id = la.LocationId
    WHERE l.Code LIKE N'ZZ-OEE%';

    -- Leaf-first: each pass deletes the rows that have no children left.
    WHILE EXISTS (SELECT 1 FROM Location.Location WHERE Code LIKE N'ZZ-OEE%')
    BEGIN
        DELETE l
        FROM Location.Location l
        WHERE l.Code LIKE N'ZZ-OEE%'
          AND NOT EXISTS (SELECT 1 FROM Location.Location c WHERE c.ParentLocationId = l.Id);
        IF @@ROWCOUNT = 0 BREAK;   -- something else references a row; stop rather than spin
    END
END
GO

IF OBJECT_ID(N'test.OeeFixture_Build', N'P') IS NOT NULL DROP PROCEDURE test.OeeFixture_Build;
GO
CREATE PROCEDURE test.OeeFixture_Build
AS
BEGIN
    SET NOCOUNT ON;
    EXEC test.OeeFixture_Teardown;

    DECLARE @Site BIGINT = (SELECT TOP 1 l.Id FROM Location.Location l
        INNER JOIN Location.LocationTypeDefinition ltd ON ltd.Id = l.LocationTypeDefinitionId
        INNER JOIN Location.LocationType lt            ON lt.Id  = ltd.LocationTypeId
        WHERE lt.Code = N'Site' AND l.DeprecatedAt IS NULL ORDER BY l.Id);

    DECLARE @Spec TABLE (
        Lvl INT, DefCode NVARCHAR(50), ParentCode NVARCHAR(50), Name NVARCHAR(200),
        Code NVARCHAR(50), SortOrder INT, Flag BIT, Deprecated BIT);

    INSERT INTO @Spec (Lvl, DefCode, ParentCode, Name, Code, SortOrder, Flag, Deprecated) VALUES
        (1, N'ProductionArea',    NULL,              N'OEE Test Assembly',    N'ZZ-OEE',          990, 0, 0),
        (1, N'ProductionArea',    NULL,              N'OEE Test Die Cast',    N'ZZ-OEE-DC',       991, 0, 0),
        (1, N'ProductionArea',    NULL,              N'OEE Test Empty Shop',  N'ZZ-OEE-E',        992, 0, 0),
        (2, N'ProductionLine',    N'ZZ-OEE',         N'OEE Split Line',       N'ZZ-OEE-L',          1, 1, 0),
        (2, N'ProductionLine',    N'ZZ-OEE',         N'OEE Plain Line',       N'ZZ-OEE-P',          2, 1, 0),
        (2, N'DieCastMachine',    N'ZZ-OEE-DC',      N'OEE Press 1',          N'ZZ-OEE-DC-M1',      1, 1, 0),
        (2, N'DieCastMachine',    N'ZZ-OEE-DC',      N'OEE Press 2',          N'ZZ-OEE-DC-M2',      2, 1, 0),
        (2, N'DieCastMachine',    N'ZZ-OEE-DC',      N'OEE Press 3 Retired',  N'ZZ-OEE-DC-M3',      3, 1, 1),
        (2, N'Terminal',          N'ZZ-OEE-DC',      N'Terminal',             N'ZZ-OEE-DC-T1',      9, 0, 0),
        (2, N'Terminal',          N'ZZ-OEE-E',       N'Terminal',             N'ZZ-OEE-E-T1',       1, 0, 0),
        (2, N'InventoryLocation', N'ZZ-OEE-E',       N'Storage',              N'ZZ-OEE-E-STORE',    2, 0, 0),
        (3, N'Terminal',          N'ZZ-OEE-L',       N'Assembly Out',         N'ZZ-OEE-L-T1',       1, 0, 0),
        (3, N'CNCMachine',        N'ZZ-OEE-L',       N'Machining',            N'ZZ-OEE-L-MI',       2, 1, 0),
        (3, N'AssemblyStation',   N'ZZ-OEE-L',       N'Assembly A',           N'ZZ-OEE-L-A',        3, 1, 0),
        (3, N'AssemblyStation',   N'ZZ-OEE-L',       N'Assembly B',           N'ZZ-OEE-L-B',        4, 1, 0),
        (3, N'Terminal',          N'ZZ-OEE-P',       N'Assembly Out',         N'ZZ-OEE-P-T1',       1, 0, 0),
        (3, N'Terminal',          N'ZZ-OEE-DC-M1',   N'Terminal',             N'ZZ-OEE-DC-M1-T1',   1, 0, 0);

    DECLARE @Lvl INT = 1;
    WHILE @Lvl <= 3
    BEGIN
        INSERT INTO Location.Location
            (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder, IsOeeEnabled, DeprecatedAt)
        SELECT d.Id,
               COALESCE(p.Id, @Site),
               s.Name, s.Code, N'OEE test fixture', s.SortOrder, s.Flag,
               CASE WHEN s.Deprecated = 1 THEN SYSUTCDATETIME() END
        FROM @Spec s
        INNER JOIN Location.LocationTypeDefinition d ON d.Code = s.DefCode
        LEFT  JOIN Location.Location p               ON p.Code = s.ParentCode AND p.DeprecatedAt IS NULL
        WHERE s.Lvl = @Lvl;
        SET @Lvl = @Lvl + 1;
    END
END
GO
