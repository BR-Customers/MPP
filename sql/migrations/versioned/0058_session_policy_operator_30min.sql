-- =============================================
-- Migration:   0058_session_policy_operator_30min.sql
-- Author:      Blue Ridge Automation
-- Date:        2026-08-18
-- Description: FAT Day 1 punch list item 6 -- the operator-presence idle timeout is
--              raised from 3 minutes to 30 minutes, and the shipped default is raised
--              to match so a fresh deployment starts at the value MPP asked for.
--
--              Columns stay in SECONDS. Seconds is the unit the session math uses
--              (BlueRidge.Common.Session multiplies by 1000 for the epoch-ms deadline)
--              and the unit both CHECK constraints are written against, so converting
--              the storage would ripple through the proc, the named query, the session
--              module and every test for a purely cosmetic gain. The MINUTES change
--              requested at FAT is a PRESENTATION change and is made in the Config-Tool
--              editor (MPP_Config .. Views/Audit/Users), which now shows and accepts
--              whole minutes and converts at the boundary.
--
--              Effect of the minutes-based editor on the existing bounds: CK_SessionPolicy_*
--              permit 30..3600 seconds. Whole-minute entry narrows the practical range to
--              1..60 minutes (60..3600 s) -- every minute value in that range is legal
--              under the unchanged CHECKs, so the constraints are deliberately left as
--              they are. The only value that becomes unreachable from the UI is a
--              sub-minute (30..59 s) timeout, which is not a setting MPP wants.
--
--              Elevation timeout is NOT changed (stays 300 s / 5 minutes).
--
--              Idempotent: guarded on dbo.SchemaVersion, and the DEFAULT swap is
--              guarded on the constraint's current definition.
-- =============================================

-- NOTE ON THE GUARD: RETURN exits only its OWN batch, so a top-of-file
-- "IF EXISTS ... RETURN / GO" does NOT stop the batches after it. Every
-- statement below is therefore guarded on its own, including the
-- dbo.SchemaVersion insert -- otherwise a re-run raises Msg 2627 on
-- UQ_SchemaVersion_MigrationId.
IF EXISTS (SELECT 1 FROM dbo.SchemaVersion
           WHERE MigrationId = N'0058_session_policy_operator_30min')
    PRINT 'Migration 0058 already applied -- statements below are individually guarded.';
GO

-- ---- 1. Raise the shipped DEFAULT 180 s -> 1800 s (30 min) ----
-- The default only applies to a fresh INSERT that omits the column (i.e. a brand-new
-- deployment's seed in 0049). Dropping/re-adding is the only way to change a DEFAULT.
IF EXISTS (SELECT 1 FROM sys.default_constraints
           WHERE name = N'DF_SessionPolicy_OpTimeout'
             AND parent_object_id = OBJECT_ID(N'Location.SessionPolicy'))
BEGIN
    ALTER TABLE Location.SessionPolicy DROP CONSTRAINT DF_SessionPolicy_OpTimeout;
    ALTER TABLE Location.SessionPolicy ADD CONSTRAINT DF_SessionPolicy_OpTimeout
        DEFAULT 1800 FOR OperatorPresenceTimeoutSeconds;
END
GO

-- ---- 2. Set the live single row to 30 minutes ----
-- Unconditional (not "only if still 180"): MPP's instruction at FAT was that the
-- operator-presence timeout IS 30 minutes, so any environment carrying an older value
-- is brought to it. UpdatedByUserId is NOT NULL -> attribute to the bootstrap system
-- user (AppUser 1), the same attribution 0049's seed used.
UPDATE Location.SessionPolicy
SET    OperatorPresenceTimeoutSeconds = 1800,
       UpdatedAt                      = SYSUTCDATETIME(),
       UpdatedByUserId                = 1
WHERE  OperatorPresenceTimeoutSeconds <> 1800;
GO

IF NOT EXISTS (SELECT 1 FROM dbo.SchemaVersion
               WHERE MigrationId = N'0058_session_policy_operator_30min')
    INSERT INTO dbo.SchemaVersion (MigrationId, Description)
    VALUES (N'0058_session_policy_operator_30min',
            N'Operator-presence idle timeout 180 s -> 1800 s (30 min) on the live row and on the shipped DEFAULT. Elevation unchanged (300 s). Storage stays in seconds; the Config-Tool editor presents minutes.');
GO

PRINT 'Migration 0058 (session policy operator 30 min) applied.';
GO
