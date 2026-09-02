# Operator PIN Login Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Swap shop-floor operator sign-in from initials to a 5-digit numeric PIN, keeping Initials and DisplayName as attribution fields.

**Architecture:** The PIN is an **identifier, not a secret** — stored plaintext in a new `Location.AppUser.Pin NVARCHAR(5) NOT NULL UNIQUE` column, becoming the table's second universal natural key alongside `Initials`. Every user carries one, AD-backed or not.  Leading zeros are significant (full-time `04218`, temp `40218`), so it is a string end to end. Sign-in resolves PIN → `AppUser.Id` through a new `Location.AppUser_GetActiveByPin` proc (a mirror of the existing `_GetActiveByInitials` presence gate), and everything downstream of `loginAs` — `session.custom.user`, `session.custom.appUserId`, `Audit.OperatorChange_Log`, every mutation's `@AppUserId` — is unchanged. The three login popups keep their existing view paths and popup ids so none of the ~16 call sites that open them need to change.

**Tech Stack:** SQL Server 2022 (versioned + repeatable migrations, `test.*` assertion harness), Ignition 8.3 file-based Perspective (Core project script-python + named queries; MPP and MPP_Config view resources).

## Global Constraints

- **Branch:** `jacques/working`. Never commit to `main`.
- **Git staging:** stage explicit paths only. Never `git add -u` / `git add -A` — a concurrent user git sweep will pull stray files into the commit.
- **PIN is an identifier, not a credential.** Plaintext storage, admin-visible, digits echoed on screen during entry. No hashing, no masking, no "reset" semantics.
- **Elevation is NOT in scope and MUST NOT be touched.** `Common.Session.beginElevatedWindow` deliberately replaces `session.custom.user` / `appUserId` with the supervisor, so every action after an elevation is attributed to them. That is the intended behaviour — confirmed 2026-09-02 — not a defect to fix. A supervisor covering a break instead does a plain PIN sign-in through the operator bar, which grants no privilege because nothing reads `session.custom.user.ignitionRole` as an authorization gate. Do not add code for that path; it already exists. Verify it, don't build it.
- **There is no seed roster.** Operators onboard themselves: first PIN entry that does not resolve offers registration. Nothing in this plan waits on data from MPP.
- **PIN format:** exactly 5 numeric digits, `NVARCHAR(5)`, `NOT NULL`, `UNIQUE`. **Everyone** has one — operators and AD users alike, because an AD user must exist in `Location.AppUser` for elevation to resolve at all.
- **⚠️ The PIN is a STRING, never a number.** Full-time employees' codes carry a **leading zero** (`04218`); temps' do not (`40218`). Coercing a PIN to an integer anywhere — a Python `int()`, an NQ `sqlType: 3`, a numeric input component — silently strips that zero and every full-time employee fails to sign in. Column is `NVARCHAR(5)`, NQ parameter is `sqlType: 7` (String), the entry field accumulates characters. There is no zero-padding logic: the operator types all five digits.
- **View paths and popup ids do NOT change.** `BlueRidge/Components/Popups/InitialsEntry` (popup id `mpp-initials`), `.../UnknownInitials` (`mpp-unknown-initials`), `.../RegisterOperator` (`mpp-register-operator`) keep their folder names even though their content becomes PIN-based. Renaming them would force edits to the ~16 shop-floor views that open them, for zero functional gain.
- **SQL conventions** (`sql_best_practices_mes.md`): `UpperCamelCase`, `NVARCHAR` never `VARCHAR`, `DATETIME2(3)`, `BIGINT` FKs, `SYSUTCDATETIME()` for stored times.
- **No OUTPUT parameters** (FDS-11-011). Mutation procs end every exit path with `SELECT @Status AS Status, @Message AS Message[, @NewId AS NewId];`. Read procs emit their rowset only; empty = not found.
- **`RAISERROR` not `THROW`** in CATCH blocks. Schema-qualify every DB reference.
- **Audit Description shape:** `<SUBJECT> · <CATEGORY?> · <ACTION>` via `Audit.ufn_MidDot()`; `OldValue`/`NewValue` JSON.
- **Test harness surface is fixed** (`sql/tests/helpers/0001_test_framework.sql`): the only assertions that exist are `test.Assert_IsEqual` (`@TestName`, `@Expected NVARCHAR(MAX)`, `@Actual NVARCHAR(MAX)` — **cast every BIT/INT actual to `NVARCHAR` first**), `test.Assert_RowCount`, `test.Assert_Contains`, `test.Assert_IsNull`, `test.Assert_IsNotNull`, `test.Assert_IsTrue`. Files open with `EXEC test.BeginTestFile @FileName = N'<dir>/<file>.sql';` and close with `EXEC test.PrintSummary;`. Do not invent helper names.
- **Tests run against the throwaway DB only:** `pwsh -File sql/tests/Run-Tests.ps1 -DatabaseName "MPP_MES_Test" -Filter "<filter>"`. **NEVER** run the suite against `MPP_MES_Dev` — Jacques's Dev DB holds hand-built parts and LOTs.
- **Ignition JSON:** when writing `view.json` content, escape `=` as `=`, `'` as `'`, `<` as `<`, `>` as `>`, `&` as `&` to match Designer's GSON writer. Event/customMethod script bodies MUST start with a tab (`\t`) — Designer wraps them in `def runAction(self, event):`.
- **Expression language is C-style**, not Python: `=`, `!=`, `!`, `&&`, `||`, `if(cond, a, b)`. Transform `script` bodies are Jython.
- **After any Ignition file write, run `.\scan.ps1`** from the repo root to register resources with the gateway.
- **Designer must stay closed on the six edited views** for the duration (user confirmed). Named queries, script-python, and new views are safe regardless.
- Seed/label string values are **ASCII-only** — `sqlcmd` reads `.sql` in the Windows codepage and turns em-dashes into mojibake.

---

## File Structure

| File | Responsibility |
|---|---|
| `sql/migrations/versioned/0069_appuser_pin.sql` | Adds `Pin NOT NULL UNIQUE` with a 5-digit format CHECK; backfills every existing row. |
| `sql/migrations/repeatable/R__Location_AppUser_GetByPin.sql` | History lookup by PIN (returns deprecated rows). |
| `sql/migrations/repeatable/R__Location_AppUser_GetActiveByPin.sql` | Presence gate — active rows only. |
| `sql/migrations/repeatable/R__Location_AppUser_{Create,Update,Get,List,GetByInitials,GetActiveByInitials,GetByAdAccount,Deprecate}.sql` | Gain `Pin` in params / SELECT / audit JSON. |
| `sql/tests/03_appuser/046_AppUser_Pin_lookups.sql` | New — covers both PIN read procs. |
| `sql/tests/03_appuser/{020,030,040,045,050,060,080}*.sql`, `sql/tests/0020_PlantFloor_Foundation/020_AppUser_GetByInitials.sql` | Temp-table shapes gain `Pin`; Create/Update calls gain `@Pin`. |
| `ignition/projects/Core/ignition/named-query/location/AppUser_{GetByPin,GetActiveByPin}/` | New NQ resources. |
| `ignition/projects/Core/ignition/named-query/location/AppUser_{Create,Update}/` | Gain the `pin` parameter. |
| `ignition/projects/Core/ignition/script-python/BlueRidge/Location/AppUser/code.py` | Gains `getByPin` / `getActiveByPin`; `create`/`createOperator`/`updateOperator`/`emptyMeta` carry `pin`. |
| `.../MPP/.../views/BlueRidge/Components/PlantFloor/Numpad/` | New — 5-key-wide numeric keypad reusing the existing `_Keyboard/Key` sub-view. |
| `.../MPP/.../views/BlueRidge/Components/PlantFloor/Keyboard/view.json` | Gains a digit row so RegisterOperator can type a PIN. |
| `.../MPP/.../views/BlueRidge/Components/Popups/InitialsEntry/view.json` | The login surface — PIN entry, auto-submit at 5 digits. |
| `.../MPP/.../views/BlueRidge/Components/Popups/{UnknownInitials,RegisterOperator}/view.json` | Unknown-PIN copy; registration captures a PIN. |
| `.../MPP_Config/.../views/BlueRidge/Components/Popups/OperatorEditor/view.json` | Admin PIN assignment. |
| `.../MPP_Config/.../views/BlueRidge/{Views/Audit/Users,Components/UserRow}/view.json` | PIN column in the Users list. |
| `MPP_MES_FDS.md`, `MPP_MES_DATA_MODEL.md`, `PROJECT_STATUS.md`, `CLAUDE.md` | §4 security model reversal, schema delta, self-provisioning lifecycle, status narrative. |

---

### Task 1: Migration 0069 — `Location.AppUser.Pin`

**Files:**
- Create: `sql/migrations/versioned/0069_appuser_pin.sql`

**Interfaces:**
- Consumes: nothing.
- Produces: `Location.AppUser.Pin NVARCHAR(5) NOT NULL`; constraints `UQ_AppUser_Pin` (plain UNIQUE) and `CK_AppUser_Pin_Format`. Every later task depends on this column existing.

**Why `NOT NULL` for every row, not just operators:** an AD user must exist in `Location.AppUser` for elevation to resolve their account at all, and they may also step onto the floor and sign in at a terminal. Making the PIN universal removes the whole operator-vs-interactive branch — no filtered index, no conditional CHECK, no "does this row need one?" question in the procs. `Initials` is already modelled exactly this way (`NOT NULL UNIQUE` since migration 0012), so `Pin` simply becomes the table's second universal natural key.

**Why UNIQUE across deprecated rows too:** a plain `UNIQUE` (not filtered on `DeprecatedAt`) means a retired operator's PIN is never reissued. Historical attribution can therefore never be re-pointed at a different person — which is the whole reason the initials constraint was written the same way.

**Why `EXEC()` wrappers:** the outer batch parser does not see `Pin` until the `ALTER TABLE` commits, so a direct reference in the same batch fails with Msg 207. Migration `0012_appuser_initials_and_nullable_ad.sql` established this pattern for exactly this reason.

- [ ] **Step 1: Write the migration**

Create `sql/migrations/versioned/0069_appuser_pin.sql`:

```sql
-- ============================================================
-- Migration:   0069_appuser_pin.sql
-- Author:      Blue Ridge Automation
-- Date:        2026-09-02
-- Description: Adds Location.AppUser.Pin -- the 5-digit numeric
--              identifier operators use to sign in at a shop-floor
--              terminal, replacing initials as the login key.
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
```

- [ ] **Step 2: Apply it to the throwaway test DB and verify the shape**

Run:

```bash
pwsh -File sql/tests/Run-Tests.ps1 -DatabaseName "MPP_MES_Test" -Filter "03_appuser"
```

Expected: the runner applies migrations then runs the existing 03_appuser suite. Existing tests still pass (nothing SELECTs `Pin` yet). If the runner does not apply migrations itself, apply directly:

```bash
sqlcmd -S localhost -d MPP_MES_Test -i sql/migrations/versioned/0069_appuser_pin.sql
```

- [ ] **Step 3: Verify the constraints bite, and that a leading zero survives**

Run:

```bash
sqlcmd -S localhost -d MPP_MES_Test -Q "BEGIN TRY UPDATE Location.AppUser SET Pin = N'12A45' WHERE Id = 1; PRINT 'FAIL - format CHECK did not fire'; END TRY BEGIN CATCH PRINT 'PASS - format CHECK rejected non-numeric'; END CATCH; BEGIN TRY UPDATE Location.AppUser SET Pin = N'1234' WHERE Id = 1; PRINT 'FAIL - short PIN accepted'; END TRY BEGIN CATCH PRINT 'PASS - format CHECK rejected 4 digits'; END CATCH; UPDATE Location.AppUser SET Pin = N'04218' WHERE Id = 1; SELECT Pin AS LeadingZeroRoundTrip, LEN(Pin) AS Chars FROM Location.AppUser WHERE Id = 1;"
```

Expected: both `PASS` lines, then `LeadingZeroRoundTrip = 04218` and `Chars = 5`. If the PIN comes back as `4218`, something has coerced it to a number — stop and fix that before going further, because it locks out every full-time employee.

- [ ] **Step 4: Commit**

```bash
git add sql/migrations/versioned/0069_appuser_pin.sql
git commit -m "feat(auth): add Location.AppUser.Pin for terminal sign-in

5-digit numeric identifier (not a credential), stored plaintext as
NVARCHAR NOT NULL UNIQUE with a format CHECK. Every row carries one --
an AD user must exist here for elevation to resolve, and may also sign in
at a terminal, so the universal column removes the operator-vs-interactive
branch entirely. UNIQUE is unfiltered so a retired person's PIN is never
reissued and historical attribution cannot be re-pointed.

Leading zeros are significant (full-time codes start with 0), hence
NVARCHAR rather than any numeric type.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 2: PIN lookup procs + tests

**Files:**
- Create: `sql/migrations/repeatable/R__Location_AppUser_GetActiveByPin.sql`
- Create: `sql/migrations/repeatable/R__Location_AppUser_GetByPin.sql`
- Test: `sql/tests/03_appuser/046_AppUser_Pin_lookups.sql`

**Interfaces:**
- Consumes: `Location.AppUser.Pin` (Task 1).
- Produces: `Location.AppUser_GetActiveByPin @Pin NVARCHAR(5)` and `Location.AppUser_GetByPin @Pin NVARCHAR(5)`. Both return zero or one row with columns, in order: `Id, Initials, DisplayName, Pin, AdAccount, IgnitionRole, CreatedAt, DeprecatedAt`. Task 4's named queries and Task 6's login view depend on this exact column list and order.

**Why two procs:** identical to the initials pair. `_GetActiveByPin` is the presence gate (`DeprecatedAt IS NULL`) — a retired operator must never sign in. `_GetByPin` returns deprecated rows so the login screen can tell "your account was deactivated, see a supervisor" apart from "that PIN doesn't exist, want to register?". Without the second proc both cases collapse into "unknown" and a deactivated operator would be offered self-registration, which then fails on the unique constraint with a confusing error.

- [ ] **Step 1: Write the failing test**

Create `sql/tests/03_appuser/046_AppUser_Pin_lookups.sql`:

```sql
-- =============================================
-- File:         03_appuser/046_AppUser_Pin_lookups.sql
-- Author:       Blue Ridge Automation
-- Created:      2026-09-02
-- Description:
--   Tests for the PIN sign-in resolvers Location.AppUser_GetActiveByPin
--   (presence gate, active rows only) and Location.AppUser_GetByPin
--   (history lookup, includes deprecated rows).
--
--   The pair mirrors AppUser_GetActiveByInitials / AppUser_GetByInitials:
--   an operator whose row is deprecated must FAIL the presence gate but
--   still RESOLVE through the history lookup, so the login screen can say
--   "deactivated" instead of offering self-registration.
--
--   Pre-conditions:
--     - Migration 0069 applied (Location.AppUser.Pin exists)
--     - Location.AppUser_Create deployed (v4.0 with @Pin)
--     - Location.AppUser_Deprecate deployed
-- =============================================

EXEC test.BeginTestFile @FileName = N'03_appuser/046_AppUser_Pin_lookups.sql';
GO

-- =============================================
-- Arrange: create an active operator with a known PIN.
-- =============================================
CREATE TABLE #MkActive (Status BIT, Message NVARCHAR(500), NewId BIGINT);

INSERT INTO #MkActive
EXEC Location.AppUser_Create
    @Initials    = N'PT1',
    @DisplayName = N'Pin Test Active',
    @Pin         = N'90001',
    @AppUserId   = 1;

DROP TABLE #MkActive;
GO

-- =============================================
-- Test 1: GetActiveByPin resolves an active operator.
-- =============================================
CREATE TABLE #Act1 (
    Id BIGINT, Initials NVARCHAR(10), DisplayName NVARCHAR(200),
    Pin NVARCHAR(5), AdAccount NVARCHAR(100), IgnitionRole NVARCHAR(100),
    CreatedAt DATETIME2(3), DeprecatedAt DATETIME2(3)
);

INSERT INTO #Act1
EXEC Location.AppUser_GetActiveByPin @Pin = N'90001';

DECLARE @Count1 INT = (SELECT COUNT(*) FROM #Act1);

EXEC test.Assert_RowCount
    @TestName      = N'GetActiveByPin active: 1 row returned',
    @ExpectedCount = 1,
    @ActualCount   = @Count1;

DECLARE @Initials1 NVARCHAR(10) = (SELECT TOP 1 Initials FROM #Act1);
DROP TABLE #Act1;

EXEC test.Assert_IsEqual
    @TestName = N'GetActiveByPin active: Initials come back with the row',
    @Expected = N'PT1',
    @Actual   = @Initials1;
GO

-- =============================================
-- Test 2: GetActiveByPin returns nothing for an unknown PIN.
-- =============================================
CREATE TABLE #Act2 (
    Id BIGINT, Initials NVARCHAR(10), DisplayName NVARCHAR(200),
    Pin NVARCHAR(5), AdAccount NVARCHAR(100), IgnitionRole NVARCHAR(100),
    CreatedAt DATETIME2(3), DeprecatedAt DATETIME2(3)
);

INSERT INTO #Act2
EXEC Location.AppUser_GetActiveByPin @Pin = N'99999';

DECLARE @Count2 INT = (SELECT COUNT(*) FROM #Act2);
DROP TABLE #Act2;

EXEC test.Assert_RowCount
    @TestName      = N'GetActiveByPin unknown: 0 rows returned',
    @ExpectedCount = 0,
    @ActualCount   = @Count2;
GO

-- =============================================
-- Test 3: a deprecated operator FAILS the presence gate ...
-- =============================================
CREATE TABLE #MkDep (Status BIT, Message NVARCHAR(500), NewId BIGINT);

INSERT INTO #MkDep
EXEC Location.AppUser_Create
    @Initials    = N'PT2',
    @DisplayName = N'Pin Test Deprecated',
    @Pin         = N'90002',
    @AppUserId   = 1;

DECLARE @DepId BIGINT = (SELECT NewId FROM #MkDep);
DROP TABLE #MkDep;

CREATE TABLE #DepRes (Status BIT, Message NVARCHAR(500));
INSERT INTO #DepRes
EXEC Location.AppUser_Deprecate @Id = @DepId, @AppUserId = 1;
DROP TABLE #DepRes;

CREATE TABLE #Act3 (
    Id BIGINT, Initials NVARCHAR(10), DisplayName NVARCHAR(200),
    Pin NVARCHAR(5), AdAccount NVARCHAR(100), IgnitionRole NVARCHAR(100),
    CreatedAt DATETIME2(3), DeprecatedAt DATETIME2(3)
);

INSERT INTO #Act3
EXEC Location.AppUser_GetActiveByPin @Pin = N'90002';

DECLARE @Count3 INT = (SELECT COUNT(*) FROM #Act3);
DROP TABLE #Act3;

EXEC test.Assert_RowCount
    @TestName      = N'GetActiveByPin deprecated: 0 rows (presence gate blocks)',
    @ExpectedCount = 0,
    @ActualCount   = @Count3;
GO

-- =============================================
-- Test 4: ... but STILL resolves through the history lookup.
--   This is what lets the login screen say "deactivated" rather than
--   offering self-registration on a PIN that is already taken.
-- =============================================
CREATE TABLE #Act4 (
    Id BIGINT, Initials NVARCHAR(10), DisplayName NVARCHAR(200),
    Pin NVARCHAR(5), AdAccount NVARCHAR(100), IgnitionRole NVARCHAR(100),
    CreatedAt DATETIME2(3), DeprecatedAt DATETIME2(3)
);

INSERT INTO #Act4
EXEC Location.AppUser_GetByPin @Pin = N'90002';

DECLARE @Count4 INT = (SELECT COUNT(*) FROM #Act4);
DROP TABLE #Act4;

EXEC test.Assert_RowCount
    @TestName      = N'GetByPin deprecated: 1 row (history lookup allows)',
    @ExpectedCount = 1,
    @ActualCount   = @Count4;
GO

-- =============================================
-- Test 5: a LEADING-ZERO PIN round-trips intact.
--   Full-time employees' codes start with 0; temps' do not. If anything
--   in the chain coerces the PIN to a number the zero is eaten and every
--   full-time employee is locked out. This asserts the SQL layer is clean;
--   the NQ layer is guarded by sqlType 7 (Task 4).
-- =============================================
CREATE TABLE #MkZero (Status BIT, Message NVARCHAR(500), NewId BIGINT);

INSERT INTO #MkZero
EXEC Location.AppUser_Create
    @Initials    = N'PT3',
    @DisplayName = N'Pin Test Leading Zero',
    @Pin         = N'09003',
    @AppUserId   = 1;

DROP TABLE #MkZero;

CREATE TABLE #Act5 (
    Id BIGINT, Initials NVARCHAR(10), DisplayName NVARCHAR(200),
    Pin NVARCHAR(5), AdAccount NVARCHAR(100), IgnitionRole NVARCHAR(100),
    CreatedAt DATETIME2(3), DeprecatedAt DATETIME2(3)
);

INSERT INTO #Act5
EXEC Location.AppUser_GetActiveByPin @Pin = N'09003';

DECLARE @Pin5 NVARCHAR(5) = (SELECT TOP 1 Pin FROM #Act5);
DROP TABLE #Act5;

EXEC test.Assert_IsEqual
    @TestName = N'GetActiveByPin: leading zero survives the round trip',
    @Expected = N'09003',
    @Actual   = @Pin5;
GO

-- =============================================
-- Final summary
-- =============================================
EXEC test.PrintSummary;
GO
```

- [ ] **Step 2: Run the test to verify it fails**

Run:

```bash
pwsh -File sql/tests/Run-Tests.ps1 -DatabaseName "MPP_MES_Test" -Filter "046_AppUser_Pin_lookups"
```

Expected: FAIL — `Could not find stored procedure 'Location.AppUser_GetActiveByPin'`.

(`Run-Tests.ps1` exits 1 when a test's `sqlcmd` errors even with 0 assertion failures — that is the expected signature here.)

- [ ] **Step 3: Write `Location.AppUser_GetActiveByPin`**

Create `sql/migrations/repeatable/R__Location_AppUser_GetActiveByPin.sql`:

```sql
-- =============================================
-- Procedure:   Location.AppUser_GetActiveByPin
-- Author:      Blue Ridge Automation
-- Created:     2026-09-02
-- Version:     1.0
--
-- Description:
--   Resolves an AppUser by Pin for terminal sign-in -- ACTIVE users only
--   (DeprecatedAt IS NULL). This is the presence-eligibility gate for PIN
--   login: an unknown PIN and a deprecated operator's PIN must both fail
--   to resolve, so a retired operator can never establish presence or
--   stamp new production.
--
--   Contrast with the sibling Location.AppUser_GetByPin, which
--   INTENTIONALLY returns deprecated rows so the login screen can
--   distinguish "deactivated -- see a supervisor" from "unknown PIN --
--   register?". Read-only proc -- empty result means the PIN is not
--   eligible for sign-in.
--
--   Direct analogue of Location.AppUser_GetActiveByInitials, which
--   remains in place for attribution lookups by initials.
--
-- Parameters:
--   @Pin NVARCHAR(5) - PIN to look up. Required.
--
-- Result set:
--   Zero or one row from Location.AppUser matching the Pin with
--   DeprecatedAt IS NULL.
--
-- Dependencies:
--   Tables: Location.AppUser
--
-- Change Log:
--   2026-09-02 - 1.0 - Initial version (operator PIN sign-in)
-- =============================================
CREATE OR ALTER PROCEDURE Location.AppUser_GetActiveByPin
    @Pin NVARCHAR(5)
AS
BEGIN
    SET NOCOUNT ON;

    SELECT
        Id,
        Initials,
        DisplayName,
        Pin,
        AdAccount,
        IgnitionRole,
        CreatedAt,
        DeprecatedAt
    FROM Location.AppUser
    WHERE Pin = @Pin
      AND DeprecatedAt IS NULL;
END;
GO
```

- [ ] **Step 4: Write `Location.AppUser_GetByPin`**

Create `sql/migrations/repeatable/R__Location_AppUser_GetByPin.sql`:

```sql
-- =============================================
-- Procedure:   Location.AppUser_GetByPin
-- Author:      Blue Ridge Automation
-- Created:     2026-09-02
-- Version:     1.0
--
-- Description:
--   Looks up an AppUser by Pin INCLUDING deprecated rows. PINs are unique
--   across the full lifecycle, so a retired operator's PIN still resolves
--   here. The login screen uses this ONLY to tell a deactivated operator
--   apart from an unknown PIN after the presence gate
--   (Location.AppUser_GetActiveByPin) has already refused; it must never
--   be used to establish presence.
--
--   Direct analogue of Location.AppUser_GetByInitials. Read-only proc --
--   empty result means not found.
--
-- Parameters:
--   @Pin NVARCHAR(5) - PIN to look up. Required.
--
-- Result set:
--   Zero or one row from Location.AppUser matching the Pin.
--
-- Dependencies:
--   Tables: Location.AppUser
--
-- Change Log:
--   2026-09-02 - 1.0 - Initial version (operator PIN sign-in)
-- =============================================
CREATE OR ALTER PROCEDURE Location.AppUser_GetByPin
    @Pin NVARCHAR(5)
AS
BEGIN
    SET NOCOUNT ON;

    SELECT
        Id,
        Initials,
        DisplayName,
        Pin,
        AdAccount,
        IgnitionRole,
        CreatedAt,
        DeprecatedAt
    FROM Location.AppUser
    WHERE Pin = @Pin;
END;
GO
```

- [ ] **Step 5: Run the test to verify it passes**

Run:

```bash
pwsh -File sql/tests/Run-Tests.ps1 -DatabaseName "MPP_MES_Test" -Filter "046_AppUser_Pin_lookups"
```

Expected: 5 assertions PASS, 0 failures.

**Note:** Tests 1 and 3 call `Location.AppUser_Create` with `@Pin`, which Task 3 adds. If Task 3 has not landed yet, Step 5 fails with `Procedure or function Location.AppUser_Create has too many arguments specified` — that is expected; re-run Step 5 after Task 3 and confirm green before committing this task. If executing tasks strictly in order, do Task 3 first and return here.

- [ ] **Step 6: Commit**

```bash
git add sql/migrations/repeatable/R__Location_AppUser_GetActiveByPin.sql sql/migrations/repeatable/R__Location_AppUser_GetByPin.sql sql/tests/03_appuser/046_AppUser_Pin_lookups.sql
git commit -m "feat(auth): AppUser_GetActiveByPin + AppUser_GetByPin sign-in resolvers

Mirrors the initials pair: the active-only proc is the presence gate,
the history proc lets the login screen tell a deactivated operator apart
from an unknown PIN instead of offering self-registration on a PIN that
is already taken.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 3: Carry `Pin` through the existing AppUser procs

**Files:**
- Modify: `sql/migrations/repeatable/R__Location_AppUser_Create.sql`
- Modify: `sql/migrations/repeatable/R__Location_AppUser_Update.sql`
- Modify: `sql/migrations/repeatable/R__Location_AppUser_Get.sql`
- Modify: `sql/migrations/repeatable/R__Location_AppUser_List.sql`
- Modify: `sql/migrations/repeatable/R__Location_AppUser_GetByInitials.sql`
- Modify: `sql/migrations/repeatable/R__Location_AppUser_GetActiveByInitials.sql`
- Modify: `sql/migrations/repeatable/R__Location_AppUser_GetByAdAccount.sql`
- Modify: `sql/migrations/repeatable/R__Location_AppUser_Deprecate.sql`
- Test: `sql/tests/03_appuser/{020_AppUser_Get,030_AppUser_GetByAdAccount,040_AppUser_GetByInitials,045_AppUser_GetActiveByInitials,050_AppUser_List,060_AppUser_Update,080_AppUser_Deprecate}.sql`, `sql/tests/0020_PlantFloor_Foundation/020_AppUser_GetByInitials.sql`, `sql/tests/03_appuser/010_AppUser_Create.sql`

**Interfaces:**
- Consumes: `Location.AppUser.Pin` (Task 1).
- Produces: `Location.AppUser_Create @Initials, @DisplayName, @Pin, @AdAccount, @IgnitionRole, @AppUserId` and `Location.AppUser_Update @Id, @Initials, @DisplayName, @Pin, @AdAccount, @IgnitionRole, @AppUserId`. Every read proc's SELECT gains `Pin` as the **4th column**, immediately after `DisplayName` — matching the order established in Task 2. Task 4's named queries pass `@Pin` as a string (`sqlType: 7`).

**⚠️ Breaking-change warning:** six existing test files `INSERT ... EXEC` these read procs into temp tables whose column list must match the SELECT exactly. Adding `Pin` to a read proc breaks every one of them with `Column name or number of supplied values does not match table definition`. They are listed above and MUST be updated in the same task, or the suite goes red for reasons unrelated to the feature.

- [ ] **Step 1: Add `Pin` to every read proc's SELECT**

In each of `R__Location_AppUser_Get.sql`, `R__Location_AppUser_List.sql`, `R__Location_AppUser_GetByInitials.sql`, `R__Location_AppUser_GetActiveByInitials.sql`, `R__Location_AppUser_GetByAdAccount.sql`, insert `Pin,` on its own line immediately after the `DisplayName,` line inside the `SELECT`:

```sql
    SELECT
        Id,
        Initials,
        DisplayName,
        Pin,
        AdAccount,
        IgnitionRole,
        CreatedAt,
        DeprecatedAt
    FROM Location.AppUser
```

In `R__Location_AppUser_List.sql` also extend the text filter so an admin can search by PIN, and bump the header Change Log:

```sql
    WHERE (@IncludeDeprecated = 1 OR DeprecatedAt IS NULL)
      AND (@Filter IS NULL OR @Filter = ''
           OR Initials    LIKE '%' + @Filter + '%'
           OR DisplayName LIKE '%' + @Filter + '%'
           OR AdAccount   LIKE '%' + @Filter + '%'
           OR Pin         LIKE '%' + @Filter + '%')
    ORDER BY DisplayName;
```

Add to each modified proc's Change Log block:

```sql
--   2026-09-02 - <next> - Pin exposed in SELECT (operator PIN sign-in)
```

- [ ] **Step 2: Add `@Pin` to `Location.AppUser_Create`**

In `R__Location_AppUser_Create.sql`:

Bump the header to `Version: 4.0`, add to Parameters:

```sql
--   @Pin NVARCHAR(5)                  - 5-digit sign-in PIN. Required for EVERY user.
--                                       Unique across all rows including deprecated.
--                                       Leading zeros significant -- string, not a number.
```

and to the Change Log:

```sql
--   2026-09-02 - 4.0 - @Pin added (required): users sign in by PIN. Uniqueness
--                      and 5-digit format validated here ahead of the DB
--                      constraints so the UI gets a readable message.
```

Signature — `@Pin` goes after `@DisplayName` to match the read-proc column order:

```sql
CREATE OR ALTER PROCEDURE Location.AppUser_Create
    @Initials     NVARCHAR(10),
    @DisplayName  NVARCHAR(200),
    @Pin          NVARCHAR(5),
    @AdAccount    NVARCHAR(100)  = NULL,
    @IgnitionRole NVARCHAR(100)  = NULL,
    @AppUserId    BIGINT
AS
```

Include `Pin` in the audit params JSON:

```sql
    DECLARE @Params   NVARCHAR(MAX) =
        (SELECT @Initials     AS Initials,
                @DisplayName  AS DisplayName,
                @Pin          AS Pin,
                @AdAccount    AS AdAccount,
                @IgnitionRole AS IgnitionRole
         FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);
```

Add three business-rule checks. Place them immediately after the existing "IgnitionRole requires AdAccount" block, before `BEGIN TRANSACTION`. Each follows the file's established shape (set message, `Audit_LogFailure`, status SELECT, `RETURN`):

```sql
        -- PIN format: exactly 5 numeric digits (mirrors CK_AppUser_Pin_Format).
        -- A leading zero is legal and significant -- 04218 is a full-time
        -- employee's code -- so this must never be a numeric comparison.
        IF @Pin IS NULL OR LEN(@Pin) <> 5 OR @Pin LIKE '%[^0-9]%'
        BEGIN
            SET @Message = N'PIN must be exactly 5 digits.';
            EXEC Audit.Audit_LogFailure
                @AppUserId           = @AppUserId,
                @LogEntityTypeCode   = N'AppUser',
                @EntityId            = NULL,
                @LogEventTypeCode    = N'Created',
                @FailureReason       = @Message,
                @ProcedureName       = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
            RETURN;
        END

        -- PIN uniqueness across ALL rows (active + deprecated): a retired
        -- operator's PIN stays reserved so historical attribution never
        -- collides with a newly issued one.
        IF EXISTS (SELECT 1 FROM Location.AppUser WHERE Pin = @Pin)
        BEGIN
            SET @Message = N'An AppUser with this PIN already exists.';
            EXEC Audit.Audit_LogFailure
                @AppUserId           = @AppUserId,
                @LogEntityTypeCode   = N'AppUser',
                @EntityId            = NULL,
                @LogEventTypeCode    = N'Created',
                @FailureReason       = @Message,
                @ProcedureName       = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
            RETURN;
        END

Extend the INSERT:

```sql
        INSERT INTO Location.AppUser
            (Initials, DisplayName, Pin, AdAccount, IgnitionRole, CreatedAt)
        VALUES
            (@Initials, @DisplayName, @Pin, @AdAccount, @IgnitionRole, SYSUTCDATETIME());
```

- [ ] **Step 3: Add `@Pin` to `Location.AppUser_Update`**

In `R__Location_AppUser_Update.sql`, bump to `Version: 4.0`, add a required `@Pin NVARCHAR(5)` parameter after `@DisplayName`, add `Pin` to both the old-value and new-value audit JSON snapshots, and add the same two checks (format, then uniqueness) — with uniqueness excluding the row being updated:

```sql
        IF EXISTS (SELECT 1 FROM Location.AppUser WHERE Pin = @Pin AND Id <> @Id)
```

Extend the `UPDATE ... SET` list with `Pin = @Pin,`.

Add to the Description block, so the intent is not lost:

```sql
--   Pin is mutable so an admin can re-issue a number when MPP recycles or
--   corrects one. Uniqueness is re-validated on every update, excluding the
--   row being updated -- the same treatment Initials and AdAccount get.
```

- [ ] **Step 4: Add `Pin` to the `AppUser_Deprecate` audit snapshot**

In `R__Location_AppUser_Deprecate.sql`, add `Pin` to the `FOR JSON PATH` old-value snapshot alongside `Initials` / `DisplayName` / `AdAccount` so the audit trail records which PIN was retired.

- [ ] **Step 5: Repair the six test files broken by the widened SELECTs**

In each of `sql/tests/03_appuser/020_AppUser_Get.sql`, `030_AppUser_GetByAdAccount.sql`, `040_AppUser_GetByInitials.sql`, `045_AppUser_GetActiveByInitials.sql`, `050_AppUser_List.sql`, and `sql/tests/0020_PlantFloor_Foundation/020_AppUser_GetByInitials.sql`, add `Pin NVARCHAR(5),` after the `DisplayName NVARCHAR(200),` line of **every** temp-table declaration:

```sql
CREATE TABLE #Act1 (
    Id           BIGINT,
    Initials     NVARCHAR(10),
    DisplayName  NVARCHAR(200),
    Pin          NVARCHAR(5),
    AdAccount    NVARCHAR(100),
    IgnitionRole NVARCHAR(100),
    CreatedAt    DATETIME2(3),
    DeprecatedAt DATETIME2(3)
);
```

Then in `sql/tests/03_appuser/010_AppUser_Create.sql`, `060_AppUser_Update.sql`, and `080_AppUser_Deprecate.sql`, **every** `EXEC Location.AppUser_Create` / `_Update` must now pass a unique `@Pin` — the parameter is required for all users, AD-backed or not. Use the `91xxx` band so PINs never collide with the migration's zero-padded backfill or with `046`'s `90001` / `90002` / `09003`:

```sql
EXEC Location.AppUser_Create
    @Initials    = N'TST',
    @DisplayName = N'Test Operator',
    @Pin         = N'91001',
    @AppUserId   = 1;
```

Add one new assertion to `010_AppUser_Create.sql` covering the new rejection — an operator with no AD account and no PIN:

```sql
-- =============================================
-- Test: a row with no PIN is rejected (the parameter is required).
-- =============================================
CREATE TABLE #NoPin (Status BIT, Message NVARCHAR(500), NewId BIGINT);

INSERT INTO #NoPin
EXEC Location.AppUser_Create
    @Initials    = N'NPN',
    @DisplayName = N'No Pin Operator',
    @AppUserId   = 1;

DECLARE @NoPinStatusStr NVARCHAR(1) = CAST((SELECT Status FROM #NoPin) AS NVARCHAR(1));
DROP TABLE #NoPin;

EXEC test.Assert_IsEqual
    @TestName = N'Create without PIN: rejected',
    @Expected = N'0',
    @Actual   = @NoPinStatusStr;
GO

-- =============================================
-- Test: a 4-digit PIN is rejected -- full-time codes are 5 characters
--   with a LEADING ZERO (04218), never 4 digits. If this ever passes,
--   somebody has coerced the PIN to a number somewhere.
-- =============================================
CREATE TABLE #ShortPin (Status BIT, Message NVARCHAR(500), NewId BIGINT);

INSERT INTO #ShortPin
EXEC Location.AppUser_Create
    @Initials    = N'SPN',
    @DisplayName = N'Short Pin',
    @Pin         = N'4218',
    @AppUserId   = 1;

DECLARE @ShortPinStatusStr NVARCHAR(1) = CAST((SELECT Status FROM #ShortPin) AS NVARCHAR(1));
DROP TABLE #ShortPin;

EXEC test.Assert_IsEqual
    @TestName = N'Create with a 4-digit PIN: rejected',
    @Expected = N'0',
    @Actual   = @ShortPinStatusStr;
GO
```

- [ ] **Step 6: Run the full AppUser suite**

Run:

```bash
pwsh -File sql/tests/Run-Tests.ps1 -DatabaseName "MPP_MES_Test" -Filter "03_appuser"
```

Expected: all assertions PASS, 0 failures — including `046_AppUser_Pin_lookups` from Task 2.

Then the plant-floor foundation suite, which carries the other affected file:

```bash
pwsh -File sql/tests/Run-Tests.ps1 -DatabaseName "MPP_MES_Test" -Filter "0020_PlantFloor_Foundation"
```

Expected: all PASS.

- [ ] **Step 7: Run the whole suite to catch anything else that INSERT-EXECs an AppUser read**

Run:

```bash
pwsh -File sql/tests/Run-Tests.ps1 -DatabaseName "MPP_MES_Test"
```

Expected: 0 failures. If a file fails with `Column name or number of supplied values does not match table definition`, it is another temp table needing the `Pin` column — fix it the same way and re-run.

- [ ] **Step 8: Commit**

```bash
git add sql/migrations/repeatable/R__Location_AppUser_Create.sql sql/migrations/repeatable/R__Location_AppUser_Update.sql sql/migrations/repeatable/R__Location_AppUser_Get.sql sql/migrations/repeatable/R__Location_AppUser_List.sql sql/migrations/repeatable/R__Location_AppUser_GetByInitials.sql sql/migrations/repeatable/R__Location_AppUser_GetActiveByInitials.sql sql/migrations/repeatable/R__Location_AppUser_GetByAdAccount.sql sql/migrations/repeatable/R__Location_AppUser_Deprecate.sql sql/tests/03_appuser sql/tests/0020_PlantFloor_Foundation/020_AppUser_GetByInitials.sql
git commit -m "feat(auth): carry Pin through the AppUser CRUD + read procs

Create/Update take a required @Pin with format and uniqueness validation
ahead of the DB constraints so the UI gets a readable message.
Every read proc exposes Pin as the 4th column; List searches it. Test temp
tables widened to match, and every Create/Update fixture given a PIN.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 4: Named queries + Core Python surface

**Files:**
- Create: `ignition/projects/Core/ignition/named-query/location/AppUser_GetActiveByPin/{query.sql,resource.json}`
- Create: `ignition/projects/Core/ignition/named-query/location/AppUser_GetByPin/{query.sql,resource.json}`
- Modify: `ignition/projects/Core/ignition/named-query/location/AppUser_Create/{query.sql,resource.json}`
- Modify: `ignition/projects/Core/ignition/named-query/location/AppUser_Update/{query.sql,resource.json}`
- Modify: `ignition/projects/Core/ignition/script-python/BlueRidge/Location/AppUser/code.py`

**Interfaces:**
- Consumes: the procs from Tasks 2 and 3.
- Produces: `BlueRidge.Location.AppUser.getActiveByPin(pin)` and `.getByPin(pin)` — each returns a dict with keys `Id, Initials, DisplayName, Pin, AdAccount, IgnitionRole, CreatedAt, DeprecatedAt`, or `None`. `createOperator(meta, appUserId)` / `updateOperator(chosenId, meta, appUserId)` read `meta["pin"]`; `create(data)` reads `data["pin"]`; `emptyMeta()` includes `"pin": ""`. Tasks 6, 7 and 8 call these.

**Why `sqlType: 7`:** Designer's NQ enum, not `java.sql.Types` — `7` is String/`NVARCHAR`, `3` is Int8/`BIGINT`. The PIN is `NVARCHAR(5)` and must travel as a string; passing it as an integer would strip a leading zero and silently fail to resolve `01234`.

- [ ] **Step 1: Create the `AppUser_GetActiveByPin` named query**

`ignition/projects/Core/ignition/named-query/location/AppUser_GetActiveByPin/query.sql`:

```sql
EXEC Location.AppUser_GetActiveByPin
    @Pin = :pin
```

`.../AppUser_GetActiveByPin/resource.json`:

```json
{
  "scope": "DG",
  "version": 2,
  "restricted": false,
  "overridable": true,
  "files": [
    "query.sql"
  ],
  "attributes": {
    "useMaxReturnSize": false,
    "autoBatchEnabled": false,
    "fallbackValue": "",
    "maxReturnSize": 100,
    "cacheUnit": "SEC",
    "type": "Query",
    "enabled": true,
    "cacheAmount": 1,
    "cacheEnabled": false,
    "database": "MPP",
    "fallbackEnabled": false,
    "lastModificationSignature": "",
    "permissions": [
      {
        "zone": "",
        "role": ""
      }
    ],
    "lastModification": {
      "actor": "claude",
      "timestamp": "2026-09-02T12:00:00Z"
    },
    "parameters": [
      {
        "type": "Parameter",
        "identifier": "pin",
        "sqlType": 7
      }
    ]
  }
}
```

- [ ] **Step 2: Create the `AppUser_GetByPin` named query**

`.../AppUser_GetByPin/query.sql`:

```sql
EXEC Location.AppUser_GetByPin
    @Pin = :pin
```

`.../AppUser_GetByPin/resource.json`: identical to Step 1's, byte-for-byte.

- [ ] **Step 3: Add the `pin` parameter to the Create and Update named queries**

`.../AppUser_Create/query.sql`:

```sql
EXEC Location.AppUser_Create
    @Initials     = :initials,
    @DisplayName  = :displayName,
    @Pin          = :pin,
    @AdAccount    = :adAccount,
    @IgnitionRole = :ignitionRole,
    @AppUserId    = :appUserId
```

`.../AppUser_Update/query.sql`:

```sql
EXEC Location.AppUser_Update
	@Id = :id,
	@Initials = :initials,
	@DisplayName = :displayName,
	@Pin = :pin,
	@AdAccount = :adAccount,
	@IgnitionRole = :ignitionRole,
	@AppUserId = :appUserId
```

In BOTH `resource.json` files, insert this object into `attributes.parameters` immediately after the `displayName` entry:

```json
      {
        "type": "Parameter",
        "identifier": "pin",
        "sqlType": 7
      },
```

Also blank each file's `"lastModificationSignature"` to `""` — the stored hash no longer matches the content and the gateway recomputes it on next save.

- [ ] **Step 4: Add the PIN accessors to the Core AppUser module**

In `ignition/projects/Core/ignition/script-python/BlueRidge/Location/AppUser/code.py`, insert these two functions immediately after `getActiveByInitials`:

```python
def getByPin(pin):
    """Resolve an AppUser by sign-in PIN, INCLUDING deprecated rows.

       PINs are unique across the full lifecycle, so a retired operator's PIN
       still resolves here. Use this ONLY to tell a deactivated operator apart
       from an unknown PIN after getActiveByPin has already refused -- never to
       establish presence. Returns a dict or None."""
    BlueRidge.Common.Util.log("pin=%s" % pin)
    return BlueRidge.Common.Db.execOne(
        "location/AppUser_GetByPin",
        {"pin": pin},
    )


def getActiveByPin(pin):
    """Resolve an ACTIVE (non-deprecated) AppUser by sign-in PIN.

       The presence-eligibility gate for PIN login: unknown AND deprecated
       PINs both return None, so neither can sign in nor stamp a mutation.
       The DeprecatedAt filter is enforced in SQL (Location.
       AppUser_GetActiveByPin), not here. Returns a dict or None."""
    BlueRidge.Common.Util.log("pin=%s" % pin)
    return BlueRidge.Common.Db.execOne(
        "location/AppUser_GetActiveByPin",
        {"pin": pin},
    )
```

- [ ] **Step 5: Carry `pin` through the mutation wrappers**

In the same file, replace `createOperator`, `updateOperator`, `create`, and `emptyMeta` with these versions (only the `pin` line and the docstring change in each):

```python
def createOperator(meta, appUserId):
    """Create a user from the operator editor. Initials + DisplayName + Pin
       always; an optional AdAccount + IgnitionRole link the row to an AD
       supervisor (empty -> NULL = operator-only). Returns
       {Status, Message, NewId}."""
    m = BlueRidge.Common.Util.extractQualifiedValues(meta) or {}
    attributes = {
        "initials":     m.get("initials"),
        "displayName":  m.get("displayName"),
        "pin":          (m.get("pin") or None),
        "adAccount":    (m.get("adAccount") or None),
        "ignitionRole": (m.get("ignitionRole") or None),
        "appUserId":    appUserId,
    }
    return createUser(attributes)
```

```python
def updateOperator(chosenId, meta, appUserId):
    """Update a user from the operator editor (Initials + DisplayName + Pin +
       optional AdAccount/IgnitionRole AD link; empty -> NULL).
       Returns {Status, Message}."""
    m = BlueRidge.Common.Util.extractQualifiedValues(meta) or {}
    attributes = {
        "id":           chosenId,
        "initials":     m.get("initials"),
        "displayName":  m.get("displayName"),
        "pin":          (m.get("pin") or None),
        "adAccount":    (m.get("adAccount") or None),
        "ignitionRole": (m.get("ignitionRole") or None),
        "appUserId":    appUserId,
    }
    return updateUser(attributes)
```

```python
def emptyMeta():
    """Blank meta dict for the editor's create-mode initialization."""
    return {
        "id":          None,
        "initials":    "",
        "displayName": "",
        "pin":         "",
        "adAccount":   "",
        "ignitionRole": "",
    }
```

```python
def create(data):
    """Create a new AppUser. Returns {Status, Message, NewId}.

       Shop-floor self-registration (UnknownInitials -> RegisterOperator) creates
       Operator rows: Initials + DisplayName + Pin only, AdAccount/
       IgnitionRole NULL. appUserId defaults to 1 (the bootstrap/system user)
       because nobody is authenticated at the PIN screen -- attribution policy,
       not a rule."""
    BlueRidge.Common.Util.log("data=%s" % data)
    params = {
        "initials":     (data.get("initials") or "").strip().upper(),
        "displayName":  data.get("displayName"),
        "pin":          (data.get("pin") or None),
        "adAccount":    data.get("adAccount"),
        "ignitionRole": data.get("ignitionRole"),
        "appUserId":    data.get("appUserId") or 1,
    }
    return BlueRidge.Common.Db.execMutation("location/AppUser_Create", params)
```

Note `createUser` and `updateUser` pass their `attributes` dict straight through to the NQ, so they need no change.

- [ ] **Step 6: Scan and verify the resolver works end to end**

Run:

```bash
pwsh -File scan.ps1
```

Expected: HTTP 200 from the project-scan endpoint.

Then verify against the Dev DB from the Designer Script Console (or any gateway-scope script):

```python
print BlueRidge.Location.AppUser.getActiveByPin("00003")
```

Expected: a dict for whichever operator row migration 0069 backfilled, or `None` if `MPP_MES_Dev` carries no AD-less rows. Either is a pass — what must NOT appear in `wrapper.log` is `Named query not found` or `Error executing system.db.runNamedQuery`.

- [ ] **Step 7: Commit**

```bash
git add ignition/projects/Core/ignition/named-query/location ignition/projects/Core/ignition/script-python/BlueRidge/Location/AppUser/code.py
git commit -m "feat(auth): PIN named queries + Core AppUser accessors

getActiveByPin/getByPin mirror the initials pair; createOperator,
updateOperator, create and emptyMeta carry pin. PIN travels as sqlType 7
(String) so a leading zero survives the round trip.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 5: Numeric keypad views

**Files:**
- Create: `ignition/projects/MPP/com.inductiveautomation.perspective/views/BlueRidge/Components/PlantFloor/Numpad/{view.json,resource.json}`
- Modify: `ignition/projects/MPP/com.inductiveautomation.perspective/views/BlueRidge/Components/PlantFloor/Keyboard/view.json`

**Interfaces:**
- Consumes: the existing `BlueRidge/Components/PlantFloor/_Keyboard/Key` sub-view, unchanged. Each repeater instance is `{"label", "key", "action", "variant", "messageName"}` plus an optional `"instancePosition"`; `Key` sends a page-scoped message named by `messageName` with payload `{"action", "key"}`.
- Produces: `BlueRidge/Components/PlantFloor/Numpad` with one param, `messageName` (string, default `"numpadKeyPressed"`). It emits the same `{"action": "key"|"backspace"|"clear"|"enter", "key": <digit>}` payloads the existing Keyboard does, so a host view's handler is interchangeable between the two. Task 6 embeds it.

**Why a new view rather than a `layout` param on Keyboard:** `Numpad` is a new resource, so it is safe to file-author outright (no Designer cache exists for it), and the login screen wants a genuinely different geometry — three big columns of digits, not a 10-across QWERTY strip. The existing Keyboard is left structurally alone apart from one additive digit row that RegisterOperator needs.

**Why Keyboard still gains digits:** RegisterOperator types Initials, Display Name and now a PIN against a single embedded keyboard. Without a digit row the operator cannot enter their PIN there at all.

- [ ] **Step 1: Create the Numpad resource descriptor**

`.../PlantFloor/Numpad/resource.json`:

```json
{
  "scope": "G",
  "version": 1,
  "restricted": false,
  "overridable": true,
  "files": [
    "view.json"
  ],
  "attributes": {
    "lastModification": {
      "actor": "claude",
      "timestamp": "2026-09-02T12:00:00Z"
    }
  }
}
```

A view folder needs BOTH `view.json` and `resource.json` — `scan.ps1` does not synthesize the latter, and a missing one presents as "View Not Found".

- [ ] **Step 2: Create the Numpad view**

`.../PlantFloor/Numpad/view.json`. Four rows: `1 2 3` / `4 5 6` / `7 8 9` / `Clear 0 Backspace`. There is deliberately **no Enter key** — Task 6 auto-submits on the 5th digit, and an Enter the operator never needs is a target for mis-taps.

```json
{
  "custom": {},
  "params": {
    "messageName": "numpadKeyPressed"
  },
  "propConfig": {
    "params.messageName": {
      "paramDirection": "input",
      "persistent": true
    }
  },
  "props": {
    "defaultSize": {
      "height": 420,
      "width": 420
    }
  },
  "root": {
    "type": "ia.container.flex",
    "meta": {
      "name": "root"
    },
    "props": {
      "direction": "column",
      "justify": "center",
      "alignItems": "center",
      "style": {
        "classes": "pf-numpad"
      }
    },
    "children": [
      {
        "type": "ia.display.flex-repeater",
        "meta": {
          "name": "Row1"
        },
        "position": {
          "basis": "96px",
          "shrink": 0
        },
        "props": {
          "direction": "row",
          "path": "BlueRidge/Components/PlantFloor/_Keyboard/Key",
          "useDefaultViewHeight": false,
          "useDefaultViewWidth": false,
          "elementPosition": {
            "basis": "120px",
            "grow": 0,
            "shrink": 0
          }
        },
        "propConfig": {
          "props.instances": {
            "binding": {
              "type": "property",
              "config": {
                "path": "view.params.messageName"
              },
              "transforms": [
                {
                  "type": "script",
                  "code": "\tmn = value or \"numpadKeyPressed\"\n\treturn [{\"label\": c, \"key\": c, \"action\": \"key\", \"variant\": \"default\", \"messageName\": mn} for c in \"123\"]"
                }
              ]
            }
          }
        }
      },
      {
        "type": "ia.display.flex-repeater",
        "meta": {
          "name": "Row2"
        },
        "position": {
          "basis": "96px",
          "shrink": 0
        },
        "props": {
          "direction": "row",
          "path": "BlueRidge/Components/PlantFloor/_Keyboard/Key",
          "useDefaultViewHeight": false,
          "useDefaultViewWidth": false,
          "elementPosition": {
            "basis": "120px",
            "grow": 0,
            "shrink": 0
          }
        },
        "propConfig": {
          "props.instances": {
            "binding": {
              "type": "property",
              "config": {
                "path": "view.params.messageName"
              },
              "transforms": [
                {
                  "type": "script",
                  "code": "\tmn = value or \"numpadKeyPressed\"\n\treturn [{\"label\": c, \"key\": c, \"action\": \"key\", \"variant\": \"default\", \"messageName\": mn} for c in \"456\"]"
                }
              ]
            }
          }
        }
      },
      {
        "type": "ia.display.flex-repeater",
        "meta": {
          "name": "Row3"
        },
        "position": {
          "basis": "96px",
          "shrink": 0
        },
        "props": {
          "direction": "row",
          "path": "BlueRidge/Components/PlantFloor/_Keyboard/Key",
          "useDefaultViewHeight": false,
          "useDefaultViewWidth": false,
          "elementPosition": {
            "basis": "120px",
            "grow": 0,
            "shrink": 0
          }
        },
        "propConfig": {
          "props.instances": {
            "binding": {
              "type": "property",
              "config": {
                "path": "view.params.messageName"
              },
              "transforms": [
                {
                  "type": "script",
                  "code": "\tmn = value or \"numpadKeyPressed\"\n\treturn [{\"label\": c, \"key\": c, \"action\": \"key\", \"variant\": \"default\", \"messageName\": mn} for c in \"789\"]"
                }
              ]
            }
          }
        }
      },
      {
        "type": "ia.display.flex-repeater",
        "meta": {
          "name": "Row4"
        },
        "position": {
          "basis": "96px",
          "shrink": 0
        },
        "props": {
          "direction": "row",
          "path": "BlueRidge/Components/PlantFloor/_Keyboard/Key",
          "useDefaultViewHeight": false,
          "useDefaultViewWidth": false,
          "elementPosition": {
            "basis": "120px",
            "grow": 0,
            "shrink": 0
          }
        },
        "propConfig": {
          "props.instances": {
            "binding": {
              "type": "property",
              "config": {
                "path": "view.params.messageName"
              },
              "transforms": [
                {
                  "type": "script",
                  "code": "\tmn = value or \"numpadKeyPressed\"\n\treturn [\n\t\t{\"label\": \"Clear\", \"key\": \"\", \"action\": \"clear\", \"variant\": \"secondary\", \"messageName\": mn},\n\t\t{\"label\": \"0\", \"key\": \"0\", \"action\": \"key\", \"variant\": \"default\", \"messageName\": mn},\n\t\t{\"label\": \"Back\", \"key\": \"\", \"action\": \"backspace\", \"variant\": \"secondary\", \"messageName\": mn}\n\t]"
                }
              ]
            }
          }
        }
      }
    ]
  }
}
```

- [ ] **Step 3: Add a digit row to the existing Keyboard**

In `.../PlantFloor/Keyboard/view.json`, insert a new child as the **first** element of `root.children`, before `Row1`. Copy `Row1`'s `position` and `props` objects verbatim from that file so the new row matches the existing key sizing exactly, and give it this binding:

```json
{
  "type": "ia.display.flex-repeater",
  "meta": {
    "name": "Row0"
  },
  "position": {
    "basis": "62px",
    "shrink": 0
  },
  "props": {
    "direction": "row",
    "elementPosition": {
      "basis": "62px",
      "grow": 0,
      "shrink": 0
    },
    "path": "BlueRidge/Components/PlantFloor/_Keyboard/Key",
    "style": {
      "gap": "8px"
    },
    "useDefaultViewHeight": false,
    "useDefaultViewWidth": false
  },
  "propConfig": {
    "props.instances": {
      "binding": {
        "type": "property",
        "config": {
          "path": "view.params.messageName"
        },
        "transforms": [
          {
            "type": "script",
            "code": "\tmn = value or \"keyboardKeyPressed\"\n\treturn [{\"label\": c, \"key\": c, \"action\": \"key\", \"variant\": \"default\", \"messageName\": mn} for c in \"1234567890\"]"
          }
        ]
      }
    }
  }
}
```

These `position` / `props` values are copied from the existing `Row1` in that file, so the new digit row keys are sized and gapped identically. Also raise the view's `props.defaultSize.height` from `280` to `350` (one 62px row plus the 8px gap, rounded up) so the keyboard is not clipped in its hosts.

- [ ] **Step 4: Scan and verify both keypads render**

Run:

```bash
pwsh -File scan.ps1
```

Expected: HTTP 200.

Then open a shop-floor page in a browser and confirm: the existing operator popup's keyboard now shows a digit row above QWERTY, and no component renders as a red Component Error. A ⚠ triangle on a key means the `_Keyboard/Key` path is wrong; a blank view means malformed JSON (trailing comma or BOM) — fix the file, re-scan, reload.

- [ ] **Step 5: Commit**

```bash
git add "ignition/projects/MPP/com.inductiveautomation.perspective/views/BlueRidge/Components/PlantFloor/Numpad" "ignition/projects/MPP/com.inductiveautomation.perspective/views/BlueRidge/Components/PlantFloor/Keyboard/view.json"
git commit -m "feat(shop-floor): numeric keypad for PIN entry

New Numpad view (3-wide digits, Clear/0/Back, no Enter -- the PIN screen
auto-submits) reusing the existing _Keyboard/Key sub-view unchanged. The
QWERTY Keyboard gains a digit row so operator self-registration can capture
a PIN on the same keyboard as initials and name.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 6: Convert the login popup to PIN

**Files:**
- Modify: `ignition/projects/MPP/com.inductiveautomation.perspective/views/BlueRidge/Components/Popups/InitialsEntry/view.json`

**Interfaces:**
- Consumes: `BlueRidge.Location.AppUser.getActiveByPin` / `.getByPin` (Task 4); `BlueRidge/Components/PlantFloor/Numpad` (Task 5).
- Produces: unchanged externals — the view still lives at `BlueRidge/Components/Popups/InitialsEntry`, still opens under popup id `mpp-initials`, still takes only `params.popupId`, and still ends by calling `loginAs(appUserId, initials, displayName, ignitionRole)` which writes `session.custom.user` + `session.custom.appUserId` and fires `Audit.OperatorChange_Log`. **No call site changes.** It consumes `{"action": "register"}` / `{"action": "retype"}` on `unknownInitialsResult` and consumes `registerOperatorResult` with `{action, appUserId, initials, displayName}`.

**Design notes:**
- `view.custom.initials` is **renamed to `view.custom.pin`**. Every reference is inside this one file, so the rename is self-contained.
- The keypad message name changes from `initialsKeyPressed` to `pinKeyPressed`; the handler is in this same file and the Numpad receives the name as a param, so nothing external is affected.
- `appendKey` **auto-submits at 5 digits** and refuses a 6th, so the operator taps five keys and is in. It also ignores non-digits defensively.
- The PIN echoes as digits, spaced — the operator can see a fat-finger before the 5th key commits.
- `loginAs` is left **byte-identical**. It is the audited seam; touching it would put the operator-handoff audit at risk for no benefit.

- [ ] **Step 1: Replace the `custom` block**

```json
  "custom": {
    "dialogOpen": false,
    "error": "",
    "pin": ""
  },
```

- [ ] **Step 2: Replace `root.scripts.customMethods`**

Keep `loginAs` exactly as it is in the current file — copy it across verbatim, do not retype it. Replace the other four methods with:

```json
      {
        "name": "appendKey",
        "params": [
          "ch"
        ],
        "script": "\t# Digits only, capped at 5. The 5th digit submits immediately -- the\n\t# operator taps five keys and is signed in, no Enter to hunt for.\n\tself.view.custom.error = \"\"\n\tif ch is None or not str(ch).isdigit():\n\t\treturn\n\tcurrent = self.view.custom.pin or \"\"\n\tif len(current) >= 5:\n\t\treturn\n\tcurrent = current + str(ch)\n\tself.view.custom.pin = current\n\tif len(current) == 5:\n\t\tself.submitPin()"
      },
      {
        "name": "clearKeys",
        "params": [],
        "script": "\tself.view.custom.error = \"\"\n\tself.view.custom.pin = \"\""
      },
      {
        "name": "backspaceKey",
        "params": [],
        "script": "\tself.view.custom.error = \"\"\n\tself.view.custom.pin = (self.view.custom.pin or \"\")[:-1]"
      },
      {
        "name": "submitPin",
        "params": [],
        "script": "\tif self.view.custom.dialogOpen:\n\t\treturn\n\ttext = (self.view.custom.pin or \"\").strip()\n\tif len(text) != 5:\n\t\tself.view.custom.error = \"\"\n\t\treturn\n\tu = BlueRidge.Location.AppUser.getActiveByPin(text)\n\tif u is not None:\n\t\tself.view.custom.error = \"\"\n\t\tself.loginAs(u[\"Id\"], u[\"Initials\"], u[\"DisplayName\"], u.get(\"IgnitionRole\"))\n\t\treturn\n\t# Not an active operator. A deprecated (deactivated) operator is blocked with a\n\t# clear message -- they cannot self-register, the PIN is already taken -- while a\n\t# genuinely unknown PIN is offered self-registration.\n\tdep = BlueRidge.Location.AppUser.getByPin(text)\n\tif dep is not None:\n\t\tself.view.custom.error = \"That operator is deactivated. See a supervisor.\"\n\t\tself.view.custom.pin = \"\"\n\t\treturn\n\tself.view.custom.dialogOpen = True\n\tsystem.perspective.openPopup(id=\"mpp-unknown-initials\", view=\"BlueRidge/Components/Popups/UnknownInitials\", params={\"pin\": text, \"replyMessage\": \"unknownInitialsResult\", \"popupId\": \"mpp-unknown-initials\"}, modal=True, showCloseIcon=False)"
      }
```

Note the deactivated branch clears the PIN — the previous operator's number must not sit on screen for the next person to re-submit.

- [ ] **Step 3: Replace `root.scripts.messageHandlers`**

```json
    "messageHandlers": [
      {
        "messageType": "pinKeyPressed",
        "pageScope": true,
        "script": "\ta = payload.get(\"action\") if payload else None\n\tif a == \"key\":\n\t\tself.appendKey(payload.get(\"key\"))\n\telif a == \"backspace\":\n\t\tself.backspaceKey()\n\telif a == \"clear\":\n\t\tself.clearKeys()\n\telif a == \"enter\":\n\t\tself.submitPin()",
        "sessionScope": false,
        "viewScope": false
      },
      {
        "messageType": "unknownInitialsResult",
        "pageScope": true,
        "script": "\taction = payload.get(\"action\") if payload else None\n\tif action == \"register\":\n\t\tsystem.perspective.openPopup(id=\"mpp-register-operator\", view=\"BlueRidge/Components/Popups/RegisterOperator\", params={\"pin\": (self.view.custom.pin or \"\").strip(), \"replyMessage\": \"registerOperatorResult\", \"popupId\": \"mpp-register-operator\"}, modal=True, showCloseIcon=False)\n\telse:\n\t\t# \"retype\" -- and any unexpected reply -- returns to a blank pad rather than\n\t\t# leaving a half-entered PIN on screen for the next person.\n\t\tself.view.custom.dialogOpen = False\n\t\tself.clearKeys()",
        "sessionScope": false,
        "viewScope": false
      },
      {
        "messageType": "registerOperatorResult",
        "pageScope": true,
        "script": "\taction = payload.get(\"action\") if payload else None\n\tself.view.custom.dialogOpen = False\n\tif action == \"registered\":\n\t\tself.loginAs(payload.get(\"appUserId\"), payload.get(\"initials\"), payload.get(\"displayName\"), None)\n\telse:\n\t\tself.clearKeys()",
        "sessionScope": false,
        "viewScope": false
      }
    ]
```

The `enter` branch is retained because the Keyboard component still emits it if this view is ever hosted with the alpha keyboard; the Numpad simply never sends it.

- [ ] **Step 4: Retarget the on-screen components**

In the same file:

`Heading` — set `props.text` to `"Enter your PIN"`.

`InitialsEcho` — keep the component name (renaming it would churn the diff for no gain) and replace its `props.text` binding with a spaced digit echo:

```json
        "propConfig": {
          "props.text": {
            "binding": {
              "type": "expr",
              "config": {
                "expression": "if({view.custom.pin} = \"\", \"- - - - -\", {view.custom.pin})"
              }
            }
          }
        }
```

`ScannerInput` — repoint the bidirectional binding at the new property and keep the blur-submit:

```json
        "propConfig": {
          "props.text": {
            "binding": {
              "type": "property",
              "config": {
                "bidirectional": true,
                "path": "view.custom.pin"
              }
            }
          }
        }
```

and change its `events.dom.onBlur` script body to `\tself.view.rootContainer.submitPin()`.

Set `props.deferUpdates: false` on `ScannerInput`. A badge scanner writes the whole PIN and immediately blurs; with `deferUpdates` at its default the gateway-scope blur handler can read an empty value and silently no-op.

`Keyboard` (the `ia.display.view` child) — repoint at the Numpad and rename the message:

```json
        "props": {
          "path": "BlueRidge/Components/PlantFloor/Numpad",
          "params": {
            "messageName": "pinKeyPressed"
          },
          "useDefaultViewHeight": false,
          "useDefaultViewWidth": false
        }
```

Preserve whatever `position` object the component already has.

- [ ] **Step 5: Scan and verify**

Run:

```bash
pwsh -File scan.ps1
```

Expected: HTTP 200.

Then, in a browser at a shop-floor page, confirm: the popup reads "Enter your PIN", shows `- - - - -`, the numeric keypad renders, tapping 5 digits signs in, and the header operator label updates to the resolved name without a page reload.

**Do not attempt to verify the submit through the in-app browser tool** — it renders and clicks fine but cannot commit Perspective input bindings. Verify the sign-in landed by checking the audit row instead:

```bash
sqlcmd -S localhost -d MPP_MES_Dev -Q "SELECT TOP 5 LoggedAt, Description FROM Audit.OperationLog ORDER BY Id DESC"
```

Expected: a recent operator-change row naming the operator who signed in.

- [ ] **Step 6: Commit**

```bash
git add "ignition/projects/MPP/com.inductiveautomation.perspective/views/BlueRidge/Components/Popups/InitialsEntry/view.json"
git commit -m "feat(shop-floor): operator signs in by 5-digit PIN

Resolves through AppUser_GetActiveByPin and auto-submits on the 5th digit.
Deactivated operators get a clear message instead of being offered
self-registration on a PIN that is already taken. View path, popup id and
the loginAs seam (session identity + operator-change audit) are unchanged,
so none of the ~16 call sites that open this popup need touching.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 7: Unknown-PIN and self-registration popups

**Files:**
- Modify: `ignition/projects/MPP/com.inductiveautomation.perspective/views/BlueRidge/Components/Popups/UnknownInitials/view.json`
- Modify: `ignition/projects/MPP/com.inductiveautomation.perspective/views/BlueRidge/Components/Popups/RegisterOperator/view.json`

**Interfaces:**
- Consumes: `params.pin` (sent by Task 6); `BlueRidge.Location.AppUser.create` with a `pin` key (Task 4).
- Produces: `UnknownInitials` replies `{"action": "register"|"retype"}` on `params.replyMessage` (`"retype"` replaces the old `"dismiss"`). `RegisterOperator` replies `{"action": "registered", "initials", "appUserId", "displayName"}` — unchanged, so Task 6's `registerOperatorResult` handler needs no rework.

**Why the PIN field is read-only in RegisterOperator:** the operator already typed the PIN on the login screen; it arrives as `params.pin`. Re-typing it invites a mismatch between the PIN they signed in with and the PIN stored. It is displayed so they can confirm it, not edited.

- [ ] **Step 1: Retitle `UnknownInitials`**

Change `params` to:

```json
  "params": {
    "pin": "",
    "popupId": "mpp-unknown-initials",
    "replyMessage": "unknownInitialsResult"
  },
```

Set `HeaderTitle.props.text` to `"PIN Not Recognized"`.

Bind `Message.props.text` to name the PIN:

```json
        "propConfig": {
          "props.text": {
            "binding": {
              "type": "expr",
              "config": {
                "expression": "\"PIN \" + {view.params.pin} + \" is not registered at this plant.\""
              }
            }
          }
        }
```

Set `Prompt.props.text` to `"Check the number and try again, or register as a new operator."`

**Then swap the footer's emphasis — this is the point of the step, not cosmetics.** Today `RegisterButton` carries `pf-btn-primary` and sits rightmost, so the emphasized, easiest-to-tap action *creates a person*. Under PIN sign-in a single mistyped digit lands here, and self-registration is now the only onboarding path, so the default action must be "try again", not "create a duplicate operator".

Rename `DismissButton` to `RetypeButton` and reorder `Footer.children` so it reads **`RegisterButton` first, `RetypeButton` second** (the footer is `justify: "flex-end"`, so the last child sits rightmost where the primary action belongs):

```json
{
  "type": "ia.input.button",
  "meta": {
    "name": "RegisterButton"
  },
  "position": {
    "shrink": 0
  },
  "props": {
    "text": "Register New User",
    "style": {
      "classes": "pf-btn pf-btn-secondary"
    }
  },
  "events": {
    "component": {
      "onActionPerformed": {
        "type": "script",
        "scope": "G",
        "config": {
          "script": "	system.perspective.sendMessage(self.view.params.replyMessage, payload={\"action\": \"register\"}, scope=\"page\")
	system.perspective.closePopup(id=self.view.params.popupId)"
        }
      }
    }
  }
},
{
  "type": "ia.input.button",
  "meta": {
    "name": "RetypeButton"
  },
  "position": {
    "shrink": 0
  },
  "props": {
    "text": "Re-type PIN",
    "style": {
      "classes": "pf-btn pf-btn-primary"
    }
  },
  "events": {
    "component": {
      "onActionPerformed": {
        "type": "script",
        "scope": "G",
        "config": {
          "script": "	system.perspective.sendMessage(self.view.params.replyMessage, payload={\"action\": \"retype\"}, scope=\"page\")
	system.perspective.closePopup(id=self.view.params.popupId)"
        }
      }
    }
  }
}
```

The reply action changes from `"dismiss"` to `"retype"`. That rename is safe: `InitialsEntry` is the only view that opens this popup (verified 2026-09-02 — nothing else references `mpp-unknown-initials`), and Task 6 Step 3 already routes the new name.

- [ ] **Step 2: Add the PIN to `RegisterOperator`'s state**

Replace the `custom` and `params` blocks:

```json
  "custom": {
    "editDisplayName": "",
    "editInitials": "",
    "editPin": "",
    "error": "",
    "focusedField": "displayName"
  },
  "params": {
    "pin": "",
    "popupId": "mpp-register-operator",
    "replyMessage": "registerOperatorResult"
  },
```

- [ ] **Step 3: Update the startup script**

`root.events.system.onStartup.config.script`:

```
\tself.view.custom.editPin = self.view.params.pin or \"\"\n\tself.view.custom.editInitials = \"\"\n\tself.view.custom.editDisplayName = \"\"\n\tself.view.custom.focusedField = \"displayName\"\n\tself.view.custom.error = \"\"
```

The operator now types their initials here rather than having them prefilled — the PIN is what they arrived with.

- [ ] **Step 4: Update `saveOperator` to send the PIN**

Replace that customMethod's script with:

```
\tinitials = (self.view.custom.editInitials or \"\").strip()\n\tname = (self.view.custom.editDisplayName or \"\").strip()\n\tpin = (self.view.custom.editPin or \"\").strip()\n\tif not initials or not name:\n\t\tself.view.custom.error = \"Initials and display name are both required.\"\n\t\treturn\n\tif len(pin) != 5 or not pin.isdigit():\n\t\tself.view.custom.error = \"PIN must be exactly 5 digits.\"\n\t\treturn\n\tres = BlueRidge.Location.AppUser.create({\"initials\": initials, \"displayName\": name, \"pin\": pin})\n\tif res and res.get(\"Status\"):\n\t\tsystem.perspective.sendMessage(self.view.params.replyMessage, payload={\"action\": \"registered\", \"initials\": initials.upper(), \"appUserId\": res.get(\"NewId\"), \"displayName\": name}, scope=\"page\")\n\t\tsystem.perspective.closePopup(id=self.view.params.popupId)\n\telse:\n\t\tself.view.custom.error = (res.get(\"Message\") if res else None) or \"Could not create operator\"
```

- [ ] **Step 5: Add the read-only PIN display**

Insert a new child as the **first** element of `FieldsRow.children`, before the existing `InitialsField` container. Copy the `position` and container `props` objects verbatim from the sibling `InitialsField` container so the three fields lay out consistently:

```json
{
  "type": "ia.container.flex",
  "meta": {
    "name": "PinField"
  },
  "position": {
    "basis": "200px",
    "shrink": 0
  },
  "props": {
    "direction": "column",
    "style": {
      "classes": "pf-field"
    }
  },
  "children": [
    {
      "type": "ia.display.label",
      "meta": {
        "name": "PinLabel"
      },
      "position": {
        "basis": "auto",
        "shrink": 0
      },
      "props": {
        "text": "PIN",
        "style": {
          "classes": "pf-field-label"
        }
      }
    },
    {
      "type": "ia.display.label",
      "meta": {
        "name": "PinValue"
      },
      "propConfig": {
        "props.text": {
          "binding": {
            "type": "property",
            "config": {
              "path": "view.custom.editPin"
            }
          }
        }
      }
    }
  ]
}
```

These values mirror the sibling `InitialsField` container and `InitialsLabel` exactly (`pf-field` / `pf-field-label`), so the three fields lay out and read identically. `FieldsRow` is a `direction: "row"` flex with a 16px gap, so a third 200px-basis child fits its 880px default width.

- [ ] **Step 6: Scan and verify the round trip**

Run:

```bash
pwsh -File scan.ps1
```

Expected: HTTP 200.

At a terminal, type an unregistered 5-digit PIN. Expected: "PIN NNNNN is not registered at this plant." → Register → the form shows that PIN read-only, you type initials + name → Save signs you straight in.

Confirm the row landed with its PIN:

```bash
sqlcmd -S localhost -d MPP_MES_Dev -Q "SELECT TOP 5 Id, Initials, DisplayName, Pin FROM Location.AppUser ORDER BY Id DESC"
```

Expected: the new operator with the PIN you typed.

- [ ] **Step 7: Commit**

```bash
git add "ignition/projects/MPP/com.inductiveautomation.perspective/views/BlueRidge/Components/Popups/UnknownInitials/view.json" "ignition/projects/MPP/com.inductiveautomation.perspective/views/BlueRidge/Components/Popups/RegisterOperator/view.json"
git commit -m "feat(shop-floor): unknown-PIN prompt + PIN-carrying self-registration

The PIN the operator typed at the login screen flows through to the
registration form read-only, so what they signed in with is what gets
stored. Folder names are deliberately unchanged -- renaming them would
force edits to every view that opens these popups.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 8: Config Tool — assign and see PINs

**Files:**
- Modify: `ignition/projects/MPP_Config/com.inductiveautomation.perspective/views/BlueRidge/Components/Popups/OperatorEditor/view.json`
- Modify: `ignition/projects/MPP_Config/com.inductiveautomation.perspective/views/BlueRidge/Components/UserRow/view.json`
- Modify: `ignition/projects/MPP_Config/com.inductiveautomation.perspective/views/BlueRidge/Views/Audit/Users/view.json`

**Interfaces:**
- Consumes: `BlueRidge.Location.AppUser.createOperator` / `.updateOperator` reading `meta["pin"]` (Task 4); `Location.AppUser_List` exposing `Pin` (Task 3).
- Produces: nothing downstream.

**Why the Users list needs no binding change:** its `Rows` flex-repeater binds `props.instances` straight to `view.custom.rows`, which is the `AppUser_List` result. Once the proc SELECTs `Pin`, every instance dict already carries it — `UserRow` just has to declare the param and render it.

**Note on file encoding:** `OperatorEditor/view.json` contains non-ASCII bytes (a `·` in the dirty indicator). Read and write it as UTF-8 explicitly; the default Windows codepage will throw `UnicodeDecodeError`.

- [ ] **Step 1: Add `pin` to the editor's draft shape**

In `OperatorEditor/view.json`, both `custom.editDraft.meta` and `custom.selected.meta` gain `"pin": ""`. A bidirectionally-bound nested field needs its key present in the default shape, or the first render shows a validation border and the literal text `null`:

```json
  "custom": {
    "editDraft": {
      "meta": {
        "adAccount": "",
        "displayName": "",
        "id": null,
        "ignitionRole": "",
        "initials": "",
        "pin": ""
      }
    },
    "selected": {
      "meta": {
        "adAccount": "",
        "displayName": "",
        "id": null,
        "ignitionRole": "",
        "initials": "",
        "pin": ""
      }
    }
  },
```

- [ ] **Step 2: Add the PIN input**

Insert a new child into `FormBody.children`, immediately after the existing `CodeField` (the Initials field). The container `props`, the label's `field-label` class, and the input's `search-input` styling below are copied from `CodeField` so the form stays visually uniform. `FormBody` is a column flex and its field rows carry no `position` object — do not invent one:

```json
{
  "type": "ia.container.flex",
  "meta": {
    "name": "PinFieldRow"
  },
  "props": {
    "direction": "column",
    "style": {
      "gap": "4px",
      "overflow": "visible"
    }
  },
  "children": [
    {
      "type": "ia.display.label",
      "meta": {
        "name": "Label"
      },
      "props": {
        "text": "PIN (5 digits)",
        "style": {
          "classes": "field-label"
        }
      }
    },
    {
      "type": "ia.input.text-field",
      "meta": {
        "name": "Input"
      },
      "props": {
        "deferUpdates": false,
        "placeholder": "e.g. 40218",
        "style": {
          "boxSizing": "border-box",
          "classes": "search-input",
          "width": "100%"
        }
      },
      "propConfig": {
        "props.text": {
          "binding": {
            "type": "property",
            "config": {
              "bidirectional": true,
              "path": "view.custom.editDraft.meta.pin"
            }
          }
        }
      }
    }
  ]
}
```

`"bidirectional": true` must sit **inside** the binding's `config` object — placed as a sibling of `config` it is silently ignored and the field becomes one-way, so edits never reach the draft.

No client-side format validation is added here on purpose: `AppUser_Create` / `AppUser_Update` already reject a malformed or duplicate PIN with a specific message, and `notifyResult` surfaces it. Duplicating the rule in Python would be a second source of truth.

- [ ] **Step 3: Show the PIN in the Users list**

In `UserRow/view.json`, add `"Pin": ""` to the `params` block, and insert a new label as the **second** child of `root` (between `Initials` and `DisplayName`). The `position` matches the sibling `Initials` label exactly. Like that sibling, it carries no `props` object — the text arrives entirely through the binding:

```json
{
  "type": "ia.display.label",
  "meta": {
    "name": "Pin"
  },
  "position": {
    "basis": "100px",
    "shrink": 0
  },
  "propConfig": {
    "props.text": {
      "binding": {
        "type": "property",
        "config": {
          "path": "view.params.Pin"
        }
      }
    }
  }
}
```

In `Views/Audit/Users/view.json`, insert a matching header label as the second child of `TableHeader`, so the column headings stay aligned with the row:

```json
{
  "type": "ia.display.label",
  "meta": {
    "name": "ColPin"
  },
  "position": {
    "basis": "100px",
    "shrink": 0
  },
  "props": {
    "text": "PIN"
  }
}
```

`ColInitials` already uses `{"basis": "100px", "shrink": 0}`; matching it keeps header and row in step.

- [ ] **Step 4: Scan and verify**

Run:

```bash
pwsh -File scan.ps1
```

Expected: HTTP 200.

Open the Config Tool Users page. Expected: a PIN column populated for operator rows and blank for the AD users (`SYS`, `DEV`); editing an operator shows their PIN, and saving a changed PIN succeeds. Save a **duplicate** PIN and confirm an error toast reading "An AppUser with this PIN already exists." — that proves the proc-level guard is reaching the UI.

- [ ] **Step 5: Commit**

```bash
git add "ignition/projects/MPP_Config/com.inductiveautomation.perspective/views/BlueRidge/Components/Popups/OperatorEditor/view.json" "ignition/projects/MPP_Config/com.inductiveautomation.perspective/views/BlueRidge/Components/UserRow/view.json" "ignition/projects/MPP_Config/com.inductiveautomation.perspective/views/BlueRidge/Views/Audit/Users/view.json"
git commit -m "feat(config): PIN column and PIN field on the Users screen

Admins can see and re-issue operator PINs. Format and uniqueness stay in
the procs -- the editor surfaces their messages rather than duplicating
the rules in Python.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 9: Documentation

**Files:**
- Modify: `MPP_MES_FDS.md` (§4 requirements + Revision History)
- Modify: `MPP_MES_DATA_MODEL.md` (`Location.AppUser` table spec + Revision History)
- Modify: `PROJECT_STATUS.md`
- Modify: `CLAUDE.md`

**Interfaces:**
- Consumes: everything above.
- Produces: nothing downstream.

**Why this task is not optional:** FDS §4 currently states the *opposite* of what the code now does — FDS-04-002 says "No password is verified" and FDS-04-004 says "no clock-number/PIN convenience login." Shipping the feature while the signed design document forbids it is exactly the kind of drift the FRS crosswalk exists to prevent, and MPP reads these documents.

- [ ] **Step 1: Rewrite the affected FDS §4 requirements**

| Requirement | Change |
|---|---|
| FDS-04-001 (Two Identity Classes) | Add a `Pin` column, `NOT NULL` for **both** classes. Operator row: `AdAccount` NULL, `Initials` NOT NULL, `Pin` NOT NULL, `IgnitionRole` NULL. Interactive row: all four populated — an AD user must exist in `Location.AppUser` for elevation to resolve their account, and may also sign in at a terminal. |
| FDS-04-002 (Operator Initials Capture) | Retitle to **Operator PIN Capture**. The terminal prompts for a 5-digit PIN; the MES resolves it via `Location.AppUser_GetActiveByPin` and establishes presence. State explicitly that the PIN is an **identifier, not a credential** — it is not hashed and verifies no secret; it replaces initials as the sign-in key purely because MPP already issues PINs internally and operators know them. Initials remain the human-readable attribution label shown on screen and in reports. |
| FDS-04-004 (Interactive User Authentication) | Strike "no clock-number/PIN convenience login." Replace with: operator PIN sign-in establishes *presence only* and grants no privilege; every elevated action still requires a per-action AD credential under FDS-04-007. |
| FDS-04-005 (Pre-Populated Initials Field) | Resolution proc reference changes from `Location.AppUser_GetByInitials` to `Location.AppUser_GetActiveByPin` for presence; the displayed field stays initials. |
| FDS-04-010 (Operator AppUser Lifecycle) | Rewrite the provisioning path: operator rows are **self-created at the terminal** on first PIN entry (PIN + initials + display name), not pre-loaded by an Admin. The Configuration Tool remains the place to correct, re-issue a PIN, or deprecate. Add: PINs are unique across the full row set including deprecated rows, so a retired person's PIN is never reissued and historical attribution can never be re-pointed. |
| FDS-04-006 (30-Minute Presence Re-Confirmation) | "change" reopens the PIN screen rather than the initials screen. Note that a supervisor covering a break signs in by PIN like anyone else — a plain presence swap that confers no privilege. |

Add a Revision History row:

```markdown
| 1.x | 2026-09-02 | Blue Ridge Automation | **Operator sign-in moves from initials to a 5-digit PIN.** FDS-04-002 retitled to Operator PIN Capture; FDS-04-004's "no clock-number/PIN convenience login" prohibition struck (it barred a *credential* login — the PIN is an identifier that establishes presence only and grants no privilege, and every elevated action still takes a per-action AD credential under FDS-04-007, unchanged). FDS-04-001 identity table gains `Pin`, `NOT NULL` for both identity classes. FDS-04-005 presence resolution repointed at `Location.AppUser_GetActiveByPin`. FDS-04-010 rewritten: operators self-provision at the terminal on first PIN entry — there is no pre-loaded roster. Initials and DisplayName retained unchanged as attribution fields. Migration `0069_appuser_pin.sql`. |
```

- [ ] **Step 2: Update the Data Model**

In `MPP_MES_DATA_MODEL.md`, add to the `Location.AppUser` column table:

```markdown
| `Pin` | `NVARCHAR(5)` | NOT NULL | 5-digit terminal sign-in identifier, unique across all rows including deprecated (`UQ_AppUser_Pin`). Plaintext by design — an identifier, not a credential. `CK_AppUser_Pin_Format` enforces exactly 5 numeric digits. **Leading zeros are significant** (full-time `04218` vs temp `40218`) — string type is mandatory, never numeric. |
```

Add `UQ_AppUser_Pin` and `CK_AppUser_Pin_Format` to that table's constraint list, and add a Revision History row naming migration `0069`.

- [ ] **Step 3: Update `PROJECT_STATUS.md` and `CLAUDE.md`**

Append a `PROJECT_STATUS.md` entry describing the change, naming migration `0069`, the two new procs, and the `Numpad` view. State explicitly that there is **no seed dependency** — operators self-register on first PIN entry — and that **elevation is untouched**.

Add a short subsection to `CLAUDE.md` under Conventions:

```markdown
### Operator sign-in is by PIN (2026-09-02)

Shop-floor operators sign in with a **5-digit numeric PIN**, not initials.
The PIN is an **identifier, not a credential** — `Location.AppUser.Pin
NVARCHAR(5)`, plaintext, filtered-UNIQUE, admin-visible, echoed on screen
during entry. Presence resolves through `Location.AppUser_GetActiveByPin`
(active-only gate); `Location.AppUser_GetByPin` is the history lookup that
lets the login screen say "deactivated" instead of offering self-registration
on a PIN that is already taken — the same active/history split the initials
procs use.

`Initials` and `DisplayName` are retained unchanged as attribution fields:
initials are what appear on screen and in reports, the PIN is only how the
operator is recognized at the terminal. Nothing downstream of
`InitialsEntry.loginAs` changed — `session.custom.appUserId`, every
mutation's `@AppUserId`, and the operator-change audit are identical.

The login popups keep their historic folder names (`Popups/InitialsEntry`,
`UnknownInitials`, `RegisterOperator`) deliberately — renaming them would
force edits to the ~16 shop-floor views that open them.

PINs are 5 characters and **leading zeros are significant** — a full-time
employee's code is `04218`, a temp's is `40218`. The column is `NVARCHAR(5)`
and the named-query parameter is `sqlType: 7` (String). Never coerce a PIN
to an integer: it eats the zero and locks out every full-time employee.

There is **no seed roster**. A PIN that does not resolve offers registration,
and the operator creates their own row (PIN + initials + name) at the
terminal. The Config Tool Users screen is for correcting and deprecating,
not for onboarding.

**Elevation is a separate axis and was deliberately not touched.** A PIN
grants presence only; every protected action still takes a per-action AD
credential (FDS-04-007). `Common.Session.beginElevatedWindow` intentionally
replaces `session.custom.user` with the supervisor so that everything after
an elevation is attributed to them — that is by design, not a defect. A
supervisor covering a break instead does a plain PIN sign-in from the
operator bar, which confers no privilege because nothing reads
`session.custom.user.ignitionRole` as an authorization gate.
```

- [ ] **Step 4: Regenerate the Word versions of the changed docs**

Run:

```bash
pandoc MPP_MES_FDS.md -o MPP_MES_FDS.docx --reference-doc=reference.docx && node style_docx_tables.js MPP_MES_FDS.docx
```

Expected: no errors; the `.docx` mtime updates.

- [ ] **Step 5: Commit**

```bash
git add MPP_MES_FDS.md MPP_MES_FDS.docx MPP_MES_DATA_MODEL.md PROJECT_STATUS.md CLAUDE.md
git commit -m "docs: operator PIN sign-in replaces initials in FDS section 4

FDS-04-002 retitled to Operator PIN Capture and FDS-04-004's PIN
prohibition struck -- that clause barred a credential login; the PIN is an
identifier granting presence only, with per-action AD elevation unchanged.
Data model gains the Pin column spec. No seed roster: operators onboard
themselves on first PIN entry.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

## Post-Implementation Verification

Run before declaring done:

- [ ] Full SQL suite green: `pwsh -File sql/tests/Run-Tests.ps1 -DatabaseName "MPP_MES_Test"` — 0 failures.
- [ ] `pwsh -File scan.ps1` returns HTTP 200 with no errors in `wrapper.log`.
- [ ] Sign in at a terminal with a valid 5-digit PIN; the header operator label shows the right name and an operator-change row appears in `Audit.OperationLog`.
- [ ] An unknown PIN offers **Re-type PIN** as the emphasized, rightmost button, with Register New User secondary beside it. Re-type returns to a blank keypad. Registering instead signs the new operator straight in. A deactivated operator's PIN is refused with "See a supervisor" and does NOT offer registration.
- [ ] **A leading-zero PIN signs in.** Set one operator's PIN to `0` + four digits and sign in with it. This is the single most likely way this feature breaks in production.
- [ ] **Supervisor break-cover swap:** with an operator signed in, tap the operator bar's change button, enter a supervisor's PIN, and confirm they become the terminal operator with NO elevation prompt and NO elevated privileges (`session.custom.elevatedUntil` stays null).
- [ ] **Elevation still behaves as before:** trigger a protected action, authenticate with AD, and confirm the supervisor becomes the session user for the elevation window — unchanged behaviour, deliberately not modified by this work.
- [ ] Perform one ordinary mutation (e.g. a movement scan) and confirm the resulting row's `AppUserId` matches the signed-in operator.
- [ ] Confirm a PIN never satisfies an elevation prompt — the AD credential dialog must still appear for every protected action.
- [ ] `git status` shows no unintended files staged, and no `thumbnail.png` / `data.bin` was committed.

## Known Follow-Ups (not in this plan)

- `Components/PlantFloor/InitialsField` (the FDS-04-005 per-mutation field) exists as a view but is embedded nowhere. It still resolves by initials via `resolveForPresence`. If it is ever wired in, decide then whether the override field takes initials or a PIN — out of scope here because nothing renders it.
