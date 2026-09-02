-- ============================================================
-- Migration:   0069_appuser_pin.sql
-- Author:      Blue Ridge Automation
-- Date:        2026-09-02
-- Description: Adds Location.AppUser.Pin -- the 5-digit numeric
--              identifier users enter at a shop-floor terminal to
--              sign in, replacing initials as the login key.
--
--              The PIN is an IDENTIFIER, not a credential: stored
--              plaintext, admin-visible, echoed on screen during
--              entry. It is a second natural key alongside Initials,
--              not a password. (Contrast migration 0011, which
--              dropped a hashed PinHash column belonging to the
--              retired clock-number auth model -- that was a
--              credential; this is not.)
--
--              Shape delta on Location.AppUser:
--                + Pin NVARCHAR(5) NOT NULL
--                + UQ_AppUser_Pin (UNIQUE)
--                + CK_AppUser_Pin_Format (5 numeric digits)
--
--              EVERY row carries a PIN -- operators and AD users
--              alike. An AD user must exist in this table for
--              elevation to resolve their account, and may also sign
--              in at a terminal. Universal NOT NULL removes the whole
--              operator-vs-interactive branch from the procs. This
--              mirrors Initials, which has been NOT NULL UNIQUE since
--              migration 0012.
--
--              UNIQUE is deliberately NOT filtered on DeprecatedAt: a
--              retired person's PIN is never reissued, so historical
--              attribution can never be re-pointed at someone else.
--
--              LEADING ZEROS ARE SIGNIFICANT. Full-time employees'
--              codes begin with 0 (04218); temps' do not (40218).
--              NVARCHAR, never a numeric type -- an integer column or
--              parameter silently eats the zero and locks out every
--              full-time employee.
--
--              Backfill: existing rows get a synthetic zero-padded
--              PIN derived from Id so NOT NULL can be enforced without
--              data loss. There is no seed roster -- real people
--              self-register at a terminal on first PIN entry -- so
--              these placeholders only ever matter in dev.
--
--              Implementation note: statements referencing the newly
--              added Pin column run inside EXEC() so each gets its own
--              batch -- the outer parser does not see Pin until commit
--              and a direct reference fails with Msg 207.
-- ============================================================

BEGIN TRANSACTION;

IF EXISTS (SELECT 1 FROM dbo.SchemaVersion WHERE MigrationId = '0069_appuser_pin')
BEGIN
    PRINT 'Migration 0069 already applied - skipping.';
    COMMIT;
    RETURN;
END


-- ============================================================
-- == Step 1 - Add Pin as nullable ============================
-- ============================================================

IF COL_LENGTH('Location.AppUser', 'Pin') IS NULL
    EXEC('ALTER TABLE Location.AppUser ADD Pin NVARCHAR(5) NULL');


-- ============================================================
-- == Step 2 - Backfill EVERY existing row =====================
-- ============================================================
-- Zero-padded Id is guaranteed unique (Id is the PK) and guaranteed
-- 5 numeric digits for any Id below 100000. Placeholders only --
-- real people self-register at a terminal.

EXEC('UPDATE Location.AppUser
         SET Pin = RIGHT(N''00000'' + CAST(Id AS NVARCHAR(10)), 5)
       WHERE Pin IS NULL');


-- ============================================================
-- == Step 3 - Enforce NOT NULL + UNIQUE =======================
-- ============================================================

EXEC('ALTER TABLE Location.AppUser ALTER COLUMN Pin NVARCHAR(5) NOT NULL');

IF NOT EXISTS (SELECT 1 FROM sys.key_constraints WHERE name = 'UQ_AppUser_Pin')
    EXEC('ALTER TABLE Location.AppUser ADD CONSTRAINT UQ_AppUser_Pin UNIQUE (Pin)');


-- ============================================================
-- == Step 4 - CHECK: exactly 5 numeric digits ================
-- ============================================================
-- Leading zeros are legal and significant: 04218 is a full-time
-- employee's code, 40218 a temp's. Both are exactly 5 characters.

IF NOT EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = 'CK_AppUser_Pin_Format')
    EXEC('ALTER TABLE Location.AppUser
              ADD CONSTRAINT CK_AppUser_Pin_Format
                  CHECK (LEN(Pin) = 5 AND Pin NOT LIKE ''%[^0-9]%'')');


-- ============================================================
-- == Record migration ========================================
-- ============================================================
INSERT INTO dbo.SchemaVersion (MigrationId, Description)
VALUES (
    '0069_appuser_pin',
    'Location.AppUser gains Pin NVARCHAR(5) NOT NULL UNIQUE with a 5-digit numeric format CHECK. Sign-in moves from initials to PIN; every row carries one. Existing rows backfilled with zero-padded Id placeholders.'
);

COMMIT TRANSACTION;
PRINT 'Migration 0069 completed: Location.AppUser.Pin added (NOT NULL, UNIQUE, 5-digit numeric CHECK).';
