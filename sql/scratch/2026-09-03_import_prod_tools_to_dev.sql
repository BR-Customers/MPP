-- ============================================================================
-- Script:  2026-09-03_import_prod_tools_to_dev.sql
-- Author:  Blue Ridge Automation
-- Purpose: Import the Tools configuration captured from MPP_MES_Prod
--          (MESDBSRV / 172.17.10.148) into a local MPP_MES_Dev.
--
--          SCRATCH, NOT A SEED. This is a point-in-time snapshot of the
--          customer's die configuration taken 2026-09-03. Do not promote it
--          to sql/seeds -- a seed would ship customer tooling to every DB.
--
-- Run as:  sqlcmd -S localhost -E -d MPP_MES_Dev -i <this file> -b -I
--
-- ---------------------------------------------------------------------------
-- WHAT IT CREATES (proc-driven -- full FK validation + Audit.ConfigLog rows,
-- exactly the path the Config Tool takes):
--   * 3 Tools.Tool rows   via Tools.Tool_Create
--       6MA-A    "6MA Family Die"      12 cavities   (no die rank)
--       6MA-B    "6MA IN 1&5 EX 1&5"   12 cavities   (die rank B)
--       5G0-F-A  "Front 5G0"            2 cavities   (die rank B)
--   * 26 Tools.ToolCavity rows via Tools.ToolCavity_SaveAll (number +
--     description + status carried whole)
--   * Tools.DieRank 'B' if absent, via Tools.DieRank_Create -- see NOTE 1
--
-- WHAT IT DELIBERATELY DOES NOT CREATE:
--   * Tools.ToolAssignment (cell mounts) -- excluded per instruction. Mount
--     history is per-physical-asset, and UQ_ToolAssignment_ActiveCell /
--     _ActiveTool would reject a second tool on an occupied dev cell anyway.
--   * Tools.ToolAttributeDefinition / ToolAttribute -- the SOURCE HAS NONE
--     (0 rows in both tables on MPP_MES_Prod as of 2026-09-03). Nothing to
--     carry. The loop below still handles ShotLimit if a later snapshot has
--     one; attribute support would be a further extension.
--   * Tools.DieRankCompatibility -- 0 rows in the source as well.
--
-- ---------------------------------------------------------------------------
-- NOTE 1 -- DIE RANKS EXIST IN PROD. CLAUDE.md records "MPP confirms die
--   ranks do not exist" (FAT #2b). That is NOT true of this database:
--   MPP_MES_Prod carries 4 ranks -- A/Premium, B/Good, C/Okay, D/Poor -- and
--   two of the three dies reference B. Dev's own DieRank rows are unrelated
--   test fixtures (A/'Rank A', DR-A, DR-B, DR-C), so rank codes do NOT line
--   up between the two databases and cannot be mapped by Id.
--   This script therefore CREATES the referenced rank by CODE so the copied
--   tools keep their real configuration. Set @CarryDieRank = 0 to import the
--   tools with DieRankId = NULL instead.
--   (DieRankCompatibility is empty in prod too, so Lots.Lot_Merge's cross-die
--   gate is inert there exactly as it is here.)
--
-- NOTE 2 -- Tools.Tool.ShotCount IS NOT IMPORTED. No stored procedure sets
--   it: it is live-incremented only by Workorder.DieCastShiftOutput_Record.
--   A proc-driven import necessarily lands 0. Source values at capture time
--   were 6MA-A = 1175, 6MA-B = 1352, 5G0-F-A = 500. If you want the real
--   lifetime counters in Dev, run the UPDATE at the bottom of this file.
--   ShotLimit IS carried (via Tool_Update) -- all three were NULL in prod.
--
-- NOTE 3 -- NO OUTER TRANSACTION, by design. Tool_Create and
--   ToolCavity_SaveAll are captured via INSERT ... EXEC and ROLLBACK inside
--   their own CATCH; a ROLLBACK inside a proc invoked via INSERT-EXEC while a
--   caller transaction is open raises Msg 3915. Each step is checked
--   individually and the script aborts on the first failure instead.
--
-- Re-runnable: a tool whose Code already exists is skipped (UQ_Tool_Code is
--   unfiltered, so a deprecated row with that code also blocks a re-create).
-- ============================================================================
SET NOCOUNT ON;
SET XACT_ABORT ON;

DECLARE @CarryDieRank BIT = 1;                 -- NOTE 1: 0 => DieRankId NULL
DECLARE @Initials     NVARCHAR(10) = N'JGP';   -- attribution for every audit row

-- ---------------------------------------------------------------------------
-- Resolve the installation-local FK targets BY NATURAL KEY (never by Id --
-- ToolAttributeDefinition is authored per-DB and Location.Id was re-keyed in
-- the July location reconcile).
-- ---------------------------------------------------------------------------
DECLARE @AppUserId  BIGINT = (SELECT Id FROM Location.AppUser
                              WHERE Initials = @Initials AND DeprecatedAt IS NULL);
DECLARE @DieTypeId  BIGINT = (SELECT Id FROM Tools.ToolType       WHERE Code = N'Die');
DECLARE @ActiveStat BIGINT = (SELECT Id FROM Tools.ToolStatusCode WHERE Code = N'Active');

IF @AppUserId IS NULL
BEGIN
    RAISERROR(N'Import aborted: no active Location.AppUser with Initials = %s.', 16, 1, @Initials);
    RETURN;
END
IF @DieTypeId IS NULL OR @ActiveStat IS NULL
BEGIN
    RAISERROR(N'Import aborted: Tools.ToolType(Die) or Tools.ToolStatusCode(Active) missing.', 16, 1);
    RETURN;
END

PRINT CONCAT(N'Target: ', DB_NAME(), N' on ', @@SERVERNAME,
             N'  |  attributing to AppUserId ', @AppUserId, N' (', @Initials, N')');

-- ---------------------------------------------------------------------------
-- Snapshot of MPP_MES_Prod.Tools, captured 2026-09-03. Every string ASCII.
-- ---------------------------------------------------------------------------
DECLARE @Src TABLE (
    RowNo        INT IDENTITY(1,1) PRIMARY KEY,
    Code         NVARCHAR(50)   NOT NULL,
    Name         NVARCHAR(100)  NOT NULL,
    Description  NVARCHAR(500)  NULL,
    DieRankCode  NVARCHAR(20)   NULL,
    DieRankName  NVARCHAR(100)  NULL,
    ShotLimit    INT            NULL,
    SrcShotCount INT            NOT NULL,
    CavitiesJson NVARCHAR(MAX)  NULL
);

INSERT INTO @Src (Code, Name, Description, DieRankCode, DieRankName, ShotLimit, SrcShotCount, CavitiesJson) VALUES
(N'6MA-A', N'6MA Family Die', N'Produces intake 2-4 and exhaust 2-4', NULL, NULL, NULL, 1175,
 N'[{"CavityNumber":1,"Description":"Intake 2-A","StatusCode":"Active"},{"CavityNumber":2,"Description":"Intake 2-B","StatusCode":"Active"},{"CavityNumber":3,"Description":"Intake 3-A","StatusCode":"Active"},{"CavityNumber":4,"Description":"Intake 3-B","StatusCode":"Active"},{"CavityNumber":5,"Description":"Intake 4-A","StatusCode":"Active"},{"CavityNumber":6,"Description":"Intake 4-B","StatusCode":"Active"},{"CavityNumber":7,"Description":"Exhaust 2-A","StatusCode":"Active"},{"CavityNumber":8,"Description":"Exhaust 2-B","StatusCode":"Active"},{"CavityNumber":9,"Description":"Exhaust 3-A","StatusCode":"Active"},{"CavityNumber":10,"Description":"Exhaust 3-B","StatusCode":"Active"},{"CavityNumber":11,"Description":"Exhaust 4-A","StatusCode":"Active"},{"CavityNumber":12,"Description":"Exhaust 4-B","StatusCode":"Active"}]'),
(N'6MA-B', N'6MA IN 1&5 EX 1&5', N'Intake 1&5, Exhaust 1&5', N'B', N'Good', NULL, 1352,
 N'[{"CavityNumber":1,"Description":"Intake 1 Aa","StatusCode":"Active"},{"CavityNumber":2,"Description":"Intake 1 Ab","StatusCode":"Active"},{"CavityNumber":3,"Description":"Intake 1 Ac","StatusCode":"Active"},{"CavityNumber":4,"Description":"Intake 5 Aa","StatusCode":"Active"},{"CavityNumber":5,"Description":"Intake 5 Ab","StatusCode":"Active"},{"CavityNumber":6,"Description":"Intake 5 Ac","StatusCode":"Active"},{"CavityNumber":7,"Description":"Exhaust 1 Aa","StatusCode":"Active"},{"CavityNumber":8,"Description":"Exhaust 1 Ab","StatusCode":"Active"},{"CavityNumber":9,"Description":"Exhaust 1 Ac","StatusCode":"Active"},{"CavityNumber":10,"Description":"Exhaust 5 Aa","StatusCode":"Active"},{"CavityNumber":11,"Description":"Exhaust 5 Ab","StatusCode":"Active"},{"CavityNumber":12,"Description":"Exhaust 5 Ac","StatusCode":"Active"}]'),
(N'5G0-F-A', N'Front 5G0', NULL, N'B', N'Good', NULL, 500,
 N'[{"CavityNumber":1,"Description":"5G0 Front Aa","StatusCode":"Active"},{"CavityNumber":2,"Description":"5G0 Front Ab","StatusCode":"Active"}]');

-- ---------------------------------------------------------------------------
-- NOTE 1: create any referenced DieRank that this database does not have.
-- ---------------------------------------------------------------------------
DECLARE @Res TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);

IF @CarryDieRank = 1
BEGIN
    DECLARE @rc NVARCHAR(20), @rn NVARCHAR(100);
    DECLARE @rankDesc NVARCHAR(500) = N'Imported from MPP_MES_Prod 2026-09-03.';
    DECLARE @rmsg NVARCHAR(500);

    DECLARE rank_cur CURSOR LOCAL FAST_FORWARD FOR
        SELECT DISTINCT s.DieRankCode, s.DieRankName
        FROM @Src s
        WHERE s.DieRankCode IS NOT NULL
          AND NOT EXISTS (SELECT 1 FROM Tools.DieRank d
                          WHERE d.Code = s.DieRankCode AND d.DeprecatedAt IS NULL);
    OPEN rank_cur;
    FETCH NEXT FROM rank_cur INTO @rc, @rn;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        DELETE FROM @Res;
        INSERT INTO @Res EXEC Tools.DieRank_Create
            @Code = @rc, @Name = @rn, @Description = @rankDesc, @AppUserId = @AppUserId;

        IF NOT EXISTS (SELECT 1 FROM @Res WHERE Status = 1)
        BEGIN
            SELECT TOP 1 @rmsg = Message FROM @Res;
            CLOSE rank_cur;
            DEALLOCATE rank_cur;
            RAISERROR(N'DieRank_Create failed for %s: %s', 16, 1, @rc, @rmsg);
            RETURN;
        END
        PRINT CONCAT(N'  + DieRank ', @rc, N' (', @rn, N') created.');
        FETCH NEXT FROM rank_cur INTO @rc, @rn;
    END
    CLOSE rank_cur;
    DEALLOCATE rank_cur;
END

-- ---------------------------------------------------------------------------
-- Tool + cavities, one tool at a time, aborting on the first failure.
-- ---------------------------------------------------------------------------
DECLARE @RowNo INT = 1, @MaxRow INT = (SELECT MAX(RowNo) FROM @Src);
DECLARE @Code NVARCHAR(50), @Name NVARCHAR(100), @Desc NVARCHAR(500),
        @RankCode NVARCHAR(20), @RankId BIGINT, @Limit INT,
        @Cav NVARCHAR(MAX), @ToolId BIGINT, @Msg NVARCHAR(500), @CavCount INT;

WHILE @RowNo <= @MaxRow
BEGIN
    SELECT @Code = Code, @Name = Name, @Desc = Description,
           @RankCode = DieRankCode, @Limit = ShotLimit, @Cav = CavitiesJson
    FROM @Src WHERE RowNo = @RowNo;

    -- Skip an existing Code (UQ_Tool_Code is unfiltered -- deprecated rows block too)
    IF EXISTS (SELECT 1 FROM Tools.Tool WHERE Code = @Code)
    BEGIN
        PRINT CONCAT(N'  = Tool ', @Code, N' already present -- skipped.');
        SET @RowNo += 1;
        CONTINUE;
    END

    SET @RankId = CASE WHEN @CarryDieRank = 1 AND @RankCode IS NOT NULL
                       THEN (SELECT Id FROM Tools.DieRank
                             WHERE Code = @RankCode AND DeprecatedAt IS NULL)
                  END;

    SET @ToolId = NULL;
    DELETE FROM @Res;
    INSERT INTO @Res EXEC Tools.Tool_Create
        @ToolTypeId   = @DieTypeId,
        @Code         = @Code,
        @Name         = @Name,
        @Description  = @Desc,
        @DieRankId    = @RankId,
        @StatusCodeId = @ActiveStat,
        @AppUserId    = @AppUserId;

    SELECT TOP 1 @ToolId = NewId, @Msg = Message FROM @Res;
    IF @ToolId IS NULL OR NOT EXISTS (SELECT 1 FROM @Res WHERE Status = 1)
    BEGIN
        RAISERROR(N'Tool_Create failed for %s: %s', 16, 1, @Code, @Msg);
        RETURN;
    END
    PRINT CONCAT(N'  + Tool ', @Code, N' created as Id ', @ToolId,
                 N' (DieRankId ', ISNULL(CONVERT(NVARCHAR(20), @RankId), N'NULL'), N').');

    -- Cavities, carried whole (number + description + status)
    IF @Cav IS NOT NULL
    BEGIN
        DELETE FROM @Res;
        INSERT INTO @Res EXEC Tools.ToolCavity_SaveAll
            @ToolId = @ToolId, @RowsJson = @Cav, @AppUserId = @AppUserId;

        SELECT TOP 1 @Msg = Message FROM @Res;
        IF NOT EXISTS (SELECT 1 FROM @Res WHERE Status = 1)
        BEGIN
            RAISERROR(N'ToolCavity_SaveAll failed for %s: %s', 16, 1, @Code, @Msg);
            RETURN;
        END
        SET @CavCount = (SELECT COUNT(*) FROM Tools.ToolCavity
                         WHERE ToolId = @ToolId AND DeprecatedAt IS NULL);
        PRINT CONCAT(N'      cavities: ', @CavCount, N'.');
    END

    -- ShotLimit is design life, so it IS configuration (NOTE 2). All three
    -- were NULL at capture; this runs only if a later snapshot sets one.
    IF @Limit IS NOT NULL
    BEGIN
        DELETE FROM @Res;
        INSERT INTO @Res EXEC Tools.Tool_Update
            @Id = @ToolId, @Name = @Name, @Description = @Desc,
            @DieRankId = @RankId, @ShotLimit = @Limit, @AppUserId = @AppUserId;

        SELECT TOP 1 @Msg = Message FROM @Res;
        IF NOT EXISTS (SELECT 1 FROM @Res WHERE Status = 1)
        BEGIN
            RAISERROR(N'Tool_Update (ShotLimit) failed for %s: %s', 16, 1, @Code, @Msg);
            RETURN;
        END
        PRINT CONCAT(N'      ShotLimit: ', @Limit, N'.');
    END

    SET @RowNo += 1;
END

-- ---------------------------------------------------------------------------
-- Verification
-- ---------------------------------------------------------------------------
PRINT N'--- imported ---';
SELECT t.Id, t.Code, t.Name, t.Description,
       ISNULL(dr.Code, N'<none>') AS DieRank,
       sc.Code                    AS Status,
       t.ShotCount, t.ShotLimit,
       (SELECT COUNT(*) FROM Tools.ToolCavity c
        WHERE c.ToolId = t.Id AND c.DeprecatedAt IS NULL) AS Cavities,
       (SELECT COUNT(*) FROM Tools.ToolAssignment a
        WHERE a.ToolId = t.Id AND a.ReleasedAt IS NULL)   AS ActiveMounts
FROM Tools.Tool t
JOIN Tools.ToolStatusCode sc ON sc.Id = t.StatusCodeId
LEFT JOIN Tools.DieRank   dr ON dr.Id = t.DieRankId
WHERE t.Code IN (N'6MA-A', N'6MA-B', N'5G0-F-A')
ORDER BY t.Code;

-- ---------------------------------------------------------------------------
-- OPTIONAL (NOTE 2) -- carry the real lifetime shot counters. No proc sets
-- ShotCount, so this is a direct write and is NOT audited. Uncomment only if
-- Dev needs the prod counters (e.g. to exercise ufn_ShotStatus thresholds).
-- ---------------------------------------------------------------------------
-- UPDATE t SET t.ShotCount = v.ShotCount
-- FROM Tools.Tool t
-- JOIN (VALUES (N'6MA-A', 1175), (N'6MA-B', 1352), (N'5G0-F-A', 500)) AS v(Code, ShotCount)
--   ON v.Code = t.Code;
