-- =============================================
-- File:         0024_PlantFloor_Movement_Trim/010_ItemLocation_CheckEligibility.sql
-- Author:       Blue Ridge Automation
-- Created:      2026-06-16
-- Description:  Tests for Parts.ItemLocation_CheckEligibility (Arc 2 Phase 4 sec 4.1).
--                 - Direct match -> IsEligible=1, Path='Direct'
--                 - ineligible (no path) -> IsEligible=0, Path NULL
--               Read-only proc; no fixture LOTs needed. EXEC params are pre-assigned
--               @variables per the SP-template convention.
-- =============================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0024_PlantFloor_Movement_Trim/010_ItemLocation_CheckEligibility.sql';
GO

-- =============================================
-- Test 1: Direct-eligible pair from the view
-- =============================================
DECLARE @ItemId BIGINT, @LocId BIGINT;
SELECT TOP 1 @ItemId = ItemId, @LocId = LocationId
FROM Parts.v_EffectiveItemLocation WHERE Source = N'Direct' ORDER BY LocationId;

CREATE TABLE #E (IsEligible BIT, Path NVARCHAR(20));
INSERT INTO #E EXEC Parts.ItemLocation_CheckEligibility @ItemId = @ItemId, @LocationId = @LocId;

DECLARE @Elig NVARCHAR(10) = (SELECT CAST(IsEligible AS NVARCHAR(10)) FROM #E);
DECLARE @Path NVARCHAR(20) = (SELECT Path FROM #E);
DROP TABLE #E;
EXEC test.Assert_IsEqual @TestName = N'[Elig] Direct IsEligible=1', @Expected = N'1', @Actual = @Elig;
EXEC test.Assert_IsEqual @TestName = N'[Elig] Direct Path=Direct', @Expected = N'Direct', @Actual = @Path;
GO

-- =============================================
-- Test 2: Ineligible (Item 1 at a location with no eligibility path)
-- =============================================
DECLARE @ItemId BIGINT = 1;
DECLARE @BadLoc BIGINT = (
    SELECT TOP 1 l.Id FROM Location.Location l
    WHERE l.DeprecatedAt IS NULL
      AND l.Id NOT IN (SELECT LocationId FROM Parts.v_EffectiveItemLocation WHERE ItemId = @ItemId)
    ORDER BY l.Id);

CREATE TABLE #N (IsEligible BIT, Path NVARCHAR(20));
INSERT INTO #N EXEC Parts.ItemLocation_CheckEligibility @ItemId = @ItemId, @LocationId = @BadLoc;

DECLARE @NElig NVARCHAR(10) = (SELECT CAST(IsEligible AS NVARCHAR(10)) FROM #N);
DECLARE @NPathNull NVARCHAR(10) = (SELECT CASE WHEN Path IS NULL THEN N'1' ELSE N'0' END FROM #N);
DROP TABLE #N;
EXEC test.Assert_IsEqual @TestName = N'[Elig] Ineligible IsEligible=0', @Expected = N'0', @Actual = @NElig;
EXEC test.Assert_IsEqual @TestName = N'[Elig] Ineligible Path is NULL', @Expected = N'1', @Actual = @NPathNull;
GO

EXEC test.EndTestFile;
GO
