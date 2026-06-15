-- =============================================
-- File:         0020_PlantFloor_Foundation/020_AppUser_GetByInitials.sql
-- Author:       Blue Ridge Automation
-- Created:      2026-06-09
-- Description:  Phase-1 presence-contract check against the EXISTING
--               Location.AppUser_GetByInitials proc (Arc-1 v1.0). Asserts the
--               fields the Home Router / Initials Entry flow needs:
--                 - known initials -> one row carrying Id, Initials,
--                   DisplayName, IgnitionRole
--                 - unknown initials -> empty result set
--               Deprecated-returns-row is covered by Arc-1
--               03_appuser/040_AppUser_GetByInitials.sql Test 3 and is NOT
--               re-asserted here (the proc deliberately returns deprecated
--               rows for historical attribution; this test does not contradict
--               that contract).
-- =============================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0020_PlantFloor_Foundation/020_AppUser_GetByInitials.sql';
GO

-- ---- fixture: one active interactive user (AdAccount + IgnitionRole) ----
DELETE FROM Location.AppUser WHERE Initials = N'P1IN';
GO
DECLARE @C TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO @C
EXEC Location.AppUser_Create
    @Initials     = N'P1IN',
    @DisplayName  = N'Phase1 Initials User',
    @AdAccount    = N'p1.initials',
    @IgnitionRole = N'Supervisor',
    @AppUserId    = 1;
GO

-- =============================================
-- Test 1: known initials -> one row with presence fields populated.
-- =============================================
CREATE TABLE #GbI1 (
    Id           BIGINT,
    Initials     NVARCHAR(10),
    DisplayName  NVARCHAR(200),
    AdAccount    NVARCHAR(100),
    IgnitionRole NVARCHAR(100),
    CreatedAt    DATETIME2(3),
    DeprecatedAt DATETIME2(3)
);
INSERT INTO #GbI1 EXEC Location.AppUser_GetByInitials @Initials = N'P1IN';

DECLARE @Rc1 INT = (SELECT COUNT(*) FROM #GbI1);
EXEC test.Assert_RowCount
    @TestName      = N'[P1GbInit] Known initials: 1 row',
    @ExpectedCount = 1,
    @ActualCount   = @Rc1;

DECLARE @IdStr   NVARCHAR(20)  = CAST((SELECT TOP 1 Id FROM #GbI1) AS NVARCHAR(20));
DECLARE @Inits   NVARCHAR(10)  = (SELECT TOP 1 Initials FROM #GbI1);
DECLARE @Disp    NVARCHAR(200) = (SELECT TOP 1 DisplayName FROM #GbI1);
DECLARE @Role    NVARCHAR(100) = (SELECT TOP 1 IgnitionRole FROM #GbI1);
DROP TABLE #GbI1;

EXEC test.Assert_IsNotNull
    @TestName = N'[P1GbInit] Known initials: Id present',
    @Value    = @IdStr;
EXEC test.Assert_IsEqual
    @TestName = N'[P1GbInit] Known initials: Initials echoed',
    @Expected = N'P1IN',
    @Actual   = @Inits;
EXEC test.Assert_IsEqual
    @TestName = N'[P1GbInit] Known initials: DisplayName present',
    @Expected = N'Phase1 Initials User',
    @Actual   = @Disp;
EXEC test.Assert_IsEqual
    @TestName = N'[P1GbInit] Known initials: IgnitionRole present',
    @Expected = N'Supervisor',
    @Actual   = @Role;
GO

-- =============================================
-- Test 2: unknown initials -> empty result set.
-- =============================================
CREATE TABLE #GbI2 (
    Id           BIGINT,
    Initials     NVARCHAR(10),
    DisplayName  NVARCHAR(200),
    AdAccount    NVARCHAR(100),
    IgnitionRole NVARCHAR(100),
    CreatedAt    DATETIME2(3),
    DeprecatedAt DATETIME2(3)
);
INSERT INTO #GbI2 EXEC Location.AppUser_GetByInitials @Initials = N'ZZQ9';
DECLARE @Rc2 INT = (SELECT COUNT(*) FROM #GbI2);
DROP TABLE #GbI2;
EXEC test.Assert_RowCount
    @TestName      = N'[P1GbInit] Unknown initials: 0 rows',
    @ExpectedCount = 0,
    @ActualCount   = @Rc2;
GO

-- ---- cleanup ----
DELETE FROM Location.AppUser WHERE Initials = N'P1IN';
GO

EXEC test.EndTestFile;
GO
