-- ============================================================
-- Migration:   0100_session_policy_elevation_max.sql
-- Author:      Blue Ridge Automation
-- Created:     2026-09-29
-- Description: Location.SessionPolicy gains ElevationMaxSeconds -- the ABSOLUTE
--              ceiling on an elevation window.
--
--              Why: today's elevation window is a hard cap stamped once at
--              grant (Common.Session.beginElevatedWindow) and never pushed
--              forward. The app header's idle poll measures a DIFFERENT clock
--              (session.props.lastActivity, which Perspective resets on real
--              interaction), so a supervisor working CONTINUOUSLY for longer
--              than ElevationTimeoutSeconds is never idle -- no reset fires,
--              the screen looks fine -- yet isElevated() has already gone
--              false and protected actions start refusing. That is the normal
--              shape of reconciling a die cast shift off a paper press sheet.
--
--              The fix is to let activity push the window forward
--              (Common.Session.touchElevation, which exists and is called from
--              nowhere). Unbounded, that would be worse than the bug:
--              beginElevatedWindow REPLACES session.custom.user with the
--              supervisor, so a supervisor who elevates and walks away while
--              an operator keeps using the terminal would have everything
--              attributed to them for as long as the terminal stays busy.
--              This column is what bounds that -- activity extends the window
--              only up to the ceiling, then it ends regardless.
--
--              DEFAULT 1800 (30 min). Setting it EQUAL to
--              ElevationTimeoutSeconds reproduces today's behaviour exactly
--              (one window, no extension), which is the rollback lever.
--
--              Range 30..28800 -- deliberately wider at the top than the
--              rolling timeout's 3600, because a legitimate reconciliation can
--              outlast an hour, but capped at one 8-hour shift so it cannot
--              become "forever" by configuration.
--
--              One row; ADD ... NOT NULL ... DEFAULT here is trivial (contrast
--              0099 on DieCastContribution, which rewrites a large table).
-- ============================================================

IF COL_LENGTH(N'Location.SessionPolicy', N'ElevationMaxSeconds') IS NULL
    ALTER TABLE Location.SessionPolicy
        ADD ElevationMaxSeconds INT NOT NULL CONSTRAINT DF_SessionPolicy_ElevationMaxSeconds DEFAULT 1800;
GO

-- Defence in depth behind Location.SessionPolicy_Update's own validation. The
-- ordering term is the load-bearing one: a ceiling BELOW the rolling timeout
-- would expire the window before a single idle period had elapsed.
IF NOT EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = N'CK_SessionPolicy_ElevationMax')
    ALTER TABLE Location.SessionPolicy WITH CHECK
        ADD CONSTRAINT CK_SessionPolicy_ElevationMax
            CHECK (ElevationMaxSeconds BETWEEN 30 AND 28800
                   AND ElevationMaxSeconds >= ElevationTimeoutSeconds);
GO

IF NOT EXISTS (SELECT 1 FROM dbo.SchemaVersion WHERE MigrationId = N'0100_session_policy_elevation_max')
    INSERT INTO dbo.SchemaVersion (MigrationId, Description)
    VALUES (N'0100_session_policy_elevation_max',
            N'Location.SessionPolicy.ElevationMaxSeconds (INT NOT NULL DEFAULT 1800, 30..28800, >= ElevationTimeoutSeconds): the absolute ceiling an activity-extended elevation window can never pass. Enables Common.Session.touchElevation without making an elevated window unbounded.');
GO
PRINT 'Migration 0100 (session_policy_elevation_max) applied.';
GO
