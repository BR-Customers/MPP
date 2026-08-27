-- =============================================
-- File:         0008_Parts_Item/028_ContainerConfig_tolerance.sql
-- Author:       Blue Ridge Automation
-- Created:      2026-08-27
-- Description:
--   Tests Parts.ContainerConfig.ToleranceWeight (migration 0068).
--   Covers: Create round-trips the value, both read procs project it,
--   Update mutates it, and NULL is allowed (tolerance optional).
--
--   Pre-conditions:
--     - Migration 0068 applied (Parts.ContainerConfig.ToleranceWeight)
--     - Parts.ContainerConfig_* procs deployed with @ToleranceWeight
--   Spec: docs/superpowers/specs/2026-08-27-ind570-scale-udt-modbus-tcp-design.md Sec 7.1
-- =============================================

EXEC test.BeginTestFile @FileName = N'0008_Parts_Item/028_ContainerConfig_tolerance.sql';
GO

-- =============================================
-- Setup: fresh host item (idempotent -- clear any leftovers first).
-- =============================================
DELETE cc FROM Parts.ContainerConfig cc
INNER JOIN Parts.Item i ON i.Id = cc.ItemId
WHERE i.PartNumber = N'TEST-CC-TOL';
DELETE FROM Parts.Item WHERE PartNumber = N'TEST-CC-TOL';
GO

DECLARE @RItem TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO @RItem EXEC Parts.Item_Create
    @ItemTypeId  = 4,                    -- FinishedGood
    @PartNumber  = N'TEST-CC-TOL',
    @Description = N'Tolerance test host item',
    @UomId       = 1,
    @AppUserId   = 1;
GO

-- =============================================
-- Test 1: Create with a tolerance round-trips it.
-- =============================================
DECLARE @ItemId BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'TEST-CC-TOL');

CREATE TABLE #Rt1 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #Rt1 EXEC Parts.ContainerConfig_Create
    @ItemId            = @ItemId,
    @TraysPerContainer = 4,
    @PartsPerTray      = 60,
    @IsSerialized      = 0,
    @ClosureMethod     = N'ByWeight',
    @TargetWeight      = 4.2000,
    @ToleranceWeight   = 0.0500,
    @AppUserId         = 1;

DECLARE @S1 NVARCHAR(1) = (SELECT CAST(Status AS NVARCHAR(1)) FROM #Rt1);
DECLARE @NewId1 NVARCHAR(20) = (SELECT CAST(NewId AS NVARCHAR(20)) FROM #Rt1);
DROP TABLE #Rt1;

EXEC test.Assert_IsEqual
    @TestName = N'[CreateTol] ContainerConfig_Create with ToleranceWeight Status 1',
    @Expected = N'1',
    @Actual   = @S1;

EXEC test.Assert_IsNotNull
    @TestName = N'[CreateTol] NewId is not NULL',
    @Value    = @NewId1;

DECLARE @Stored NVARCHAR(20) =
    (SELECT CAST(ToleranceWeight AS NVARCHAR(20))
     FROM Parts.ContainerConfig WHERE Id = CAST(@NewId1 AS BIGINT));
EXEC test.Assert_IsEqual
    @TestName = N'[CreateTol] ToleranceWeight persisted as 0.0500',
    @Expected = N'0.0500',
    @Actual   = @Stored;
GO

-- =============================================
-- Test 2: both read procs project ToleranceWeight.
--   Column order matters -- the temp tables mirror the SELECT lists.
-- =============================================
DECLARE @ItemId BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'TEST-CC-TOL');

CREATE TABLE #CcM (
    Id                 BIGINT,
    ItemId             BIGINT,
    TraysPerContainer  INT,
    PartsPerTray       INT,
    IsSerialized       BIT,
    DunnageCode        NVARCHAR(50),
    CustomerCode       NVARCHAR(50),
    ClosureMethod      NVARCHAR(20),
    TargetWeight       DECIMAL(10,4),
    ToleranceWeight    DECIMAL(10,4),
    CreatedAt          DATETIME2(3),
    UpdatedAt          DATETIME2(3),
    DeprecatedAt       DATETIME2(3)
);
INSERT INTO #CcM EXEC Parts.ContainerConfig_GetByItemAndMethod
    @ItemId = @ItemId, @ClosureMethod = N'ByWeight';

DECLARE @TolM NVARCHAR(20) = (SELECT CAST(ToleranceWeight AS NVARCHAR(20)) FROM #CcM);
EXEC test.Assert_IsEqual
    @TestName = N'[ReadTol] GetByItemAndMethod projects ToleranceWeight',
    @Expected = N'0.0500',
    @Actual   = @TolM;
DROP TABLE #CcM;

CREATE TABLE #CcI (
    Id                 BIGINT,
    ItemId             BIGINT,
    TraysPerContainer  INT,
    PartsPerTray       INT,
    IsSerialized       BIT,
    DunnageCode        NVARCHAR(50),
    CustomerCode       NVARCHAR(50),
    ClosureMethod      NVARCHAR(20),
    TargetWeight       DECIMAL(10,4),
    ToleranceWeight    DECIMAL(10,4),
    CreatedAt          DATETIME2(3),
    UpdatedAt          DATETIME2(3),
    DeprecatedAt       DATETIME2(3)
);
INSERT INTO #CcI EXEC Parts.ContainerConfig_GetByItem @ItemId = @ItemId;

DECLARE @TolI NVARCHAR(20) =
    (SELECT CAST(ToleranceWeight AS NVARCHAR(20)) FROM #CcI WHERE ClosureMethod = N'ByWeight');
EXEC test.Assert_IsEqual
    @TestName = N'[ReadTol] GetByItem projects ToleranceWeight',
    @Expected = N'0.0500',
    @Actual   = @TolI;
DROP TABLE #CcI;
GO

-- =============================================
-- Test 3: Update mutates ToleranceWeight (and the audit diff shows it).
-- =============================================
DECLARE @ItemId BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'TEST-CC-TOL');
DECLARE @CcId BIGINT = (SELECT Id FROM Parts.ContainerConfig
                        WHERE ItemId = @ItemId AND DeprecatedAt IS NULL);

CREATE TABLE #Rt3 (Status BIT, Message NVARCHAR(500));
INSERT INTO #Rt3 EXEC Parts.ContainerConfig_Update
    @Id                = @CcId,
    @TraysPerContainer = 4,
    @PartsPerTray      = 60,
    @IsSerialized      = 0,
    @ClosureMethod     = N'ByWeight',
    @TargetWeight      = 4.2000,
    @ToleranceWeight   = 0.0750,
    @AppUserId         = 1;
DECLARE @S3 NVARCHAR(1) = (SELECT CAST(Status AS NVARCHAR(1)) FROM #Rt3);
DROP TABLE #Rt3;

EXEC test.Assert_IsEqual
    @TestName = N'[UpdateTol] ContainerConfig_Update with ToleranceWeight Status 1',
    @Expected = N'1',
    @Actual   = @S3;

DECLARE @Stored3 NVARCHAR(20) =
    (SELECT CAST(ToleranceWeight AS NVARCHAR(20))
     FROM Parts.ContainerConfig WHERE Id = @CcId);
EXEC test.Assert_IsEqual
    @TestName = N'[UpdateTol] ToleranceWeight persisted as 0.0750',
    @Expected = N'0.0750',
    @Actual   = @Stored3;

-- Audit diff carries the changed tolerance (Slice 5 field-diff convention).
DECLARE @UpdDesc NVARCHAR(500);
SELECT TOP 1 @UpdDesc = cl.Description
FROM Audit.ConfigLog cl
INNER JOIN Audit.LogEntityType let ON let.Id = cl.LogEntityTypeId
WHERE let.Code = N'ContainerConfig' AND cl.EntityId = @CcId
  AND cl.Description LIKE N'%Updated%'
ORDER BY cl.Id DESC;

DECLARE @UpdMatch NVARCHAR(1) =
    CASE WHEN @UpdDesc LIKE N'%ToleranceWeight%0.0500%0.0750%' THEN N'1' ELSE N'0' END;
EXEC test.Assert_IsEqual
    @TestName = N'[UpdateTol] Audit Description shows ToleranceWeight old->new',
    @Expected = N'1',
    @Actual   = @UpdMatch;
GO

-- =============================================
-- Test 4: ToleranceWeight is optional -- omitting it still succeeds
--   (FDS-06-014 calls the tolerance optional; the column is NULLable).
-- =============================================
DECLARE @ItemId BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'TEST-CC-TOL');
DECLARE @CcId BIGINT = (SELECT Id FROM Parts.ContainerConfig
                        WHERE ItemId = @ItemId AND DeprecatedAt IS NULL);

CREATE TABLE #Rt4d (Status BIT, Message NVARCHAR(500));
INSERT INTO #Rt4d EXEC Parts.ContainerConfig_Deprecate @Id = @CcId, @AppUserId = 1;
DROP TABLE #Rt4d;

CREATE TABLE #Rt4 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #Rt4 EXEC Parts.ContainerConfig_Create
    @ItemId            = @ItemId,
    @TraysPerContainer = 4,
    @PartsPerTray      = 60,
    @IsSerialized      = 0,
    @ClosureMethod     = N'ByWeight',
    @TargetWeight      = 4.2000,
    @AppUserId         = 1;
DECLARE @S4 NVARCHAR(1) = (SELECT CAST(Status AS NVARCHAR(1)) FROM #Rt4);
DECLARE @NewId4 BIGINT = (SELECT NewId FROM #Rt4);
DROP TABLE #Rt4;

EXEC test.Assert_IsEqual
    @TestName = N'[NullTol] Create omitting ToleranceWeight Status 1',
    @Expected = N'1',
    @Actual   = @S4;

DECLARE @IsNullTol NVARCHAR(1) =
    (SELECT CASE WHEN ToleranceWeight IS NULL THEN N'1' ELSE N'0' END
     FROM Parts.ContainerConfig WHERE Id = @NewId4);
EXEC test.Assert_IsEqual
    @TestName = N'[NullTol] ToleranceWeight stored as NULL',
    @Expected = N'1',
    @Actual   = @IsNullTol;
GO

-- =============================================
-- Cleanup
-- =============================================
DELETE cc FROM Parts.ContainerConfig cc
INNER JOIN Parts.Item i ON i.Id = cc.ItemId
WHERE i.PartNumber = N'TEST-CC-TOL';
DELETE FROM Parts.Item WHERE PartNumber = N'TEST-CC-TOL';
GO

EXEC test.EndTestFile;
GO
