-- =============================================
-- File:         0008_Parts_Item/020_ContainerConfig_crud.sql
-- Author:       Blue Ridge Automation
-- Created:      2026-04-13
-- Description:
--   Tests for Parts.ContainerConfig CRUD procs:
--     Parts.ContainerConfig_GetByItem
--     Parts.ContainerConfig_Create
--     Parts.ContainerConfig_Update
--     Parts.ContainerConfig_Deprecate
--
--   Covers: GetByItem empty + populated, Create happy + NULL required
--   + invalid ItemId + duplicate active config (filtered unique index
--   UQ_ContainerConfig_ActiveItemId), Update happy + missing Id,
--   Deprecate happy, Create-after-deprecate allowed, audit trail.
--
--   Pre-conditions:
--     - Migration 0001 applied (AppUser, Audit schema, bootstrap user Id=1)
--     - Parts schema migration applied (Parts.Item, Parts.ContainerConfig,
--       Parts.ItemType seeds 1-5, Parts.Uom seeds 1-6)
--     - Filtered unique index UQ_ContainerConfig_ActiveItemId present
--       (prevents >1 active ContainerConfig per ItemId)
--     - All Parts.ContainerConfig_* procs deployed
--     - Parts.Item_Create proc deployed (used for setup)
-- =============================================

EXEC test.BeginTestFile @FileName = N'0008_Parts_Item/020_ContainerConfig_crud.sql';
GO

-- =============================================
-- Setup: create a FinishedGood Item to attach container configs to.
-- =============================================
DECLARE @S    BIT,
        @M    NVARCHAR(500),
        @ItemId BIGINT;

CREATE TABLE #Rc19 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #Rc19
EXEC Parts.Item_Create
    @ItemTypeId  = 4,                     -- FinishedGood
    @PartNumber  = N'TEST-CC-001',
    @Description = N'Container Config Host Item',
    @UomId       = 1,
    @AppUserId   = 1;
SELECT @S = Status, @M = Message, @ItemId = NewId FROM #Rc19;
DROP TABLE #Rc19;
GO

-- =============================================
-- Test 1: ContainerConfig_GetByItem - no rows initially
-- =============================================
DECLARE @S    BIT,
        @M    NVARCHAR(500),
        @SStr NVARCHAR(1),
        @ItemId BIGINT;

SELECT @ItemId = Id FROM Parts.Item WHERE PartNumber = N'TEST-CC-001';

CREATE TABLE #Cc0 (
    Id                 BIGINT,
    ItemId             BIGINT,
    TraysPerContainer  INT,
    PartsPerTray       INT,
    IsSerialized       BIT,
    DunnageCode        NVARCHAR(50),
    CustomerCode       NVARCHAR(50),
    ClosureMethod      NVARCHAR(20),
    TargetWeight       DECIMAL(10,4),
    CreatedAt          DATETIME2(3),
    UpdatedAt          DATETIME2(3),
    DeprecatedAt       DATETIME2(3)
);

INSERT INTO #Cc0
EXEC Parts.ContainerConfig_GetByItem @ItemId = @ItemId;

DECLARE @Cnt INT = (SELECT COUNT(*) FROM #Cc0);
EXEC test.Assert_RowCount
    @TestName      = N'[GetByItemEmpty] Returns 0 rows',
    @ExpectedCount = 0,
    @ActualCount   = @Cnt;

DROP TABLE #Cc0;
GO

-- =============================================
-- Test 2: ContainerConfig_Create happy path
-- =============================================
DECLARE @S    BIT,
        @M    NVARCHAR(500),
        @SStr NVARCHAR(1),
        @ItemId BIGINT,
        @NewId BIGINT;

SELECT @ItemId = Id FROM Parts.Item WHERE PartNumber = N'TEST-CC-001';

CREATE TABLE #Rcc2 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #Rcc2 EXEC Parts.ContainerConfig_Create
    @ItemId            = @ItemId,
    @TraysPerContainer = 4,
    @PartsPerTray      = 25,
    @IsSerialized      = 0,
    @DunnageCode       = N'DUN-001',
    @CustomerCode      = N'CUST-HON',
    @ClosureMethod     = N'Strap',
    @TargetWeight      = 125.5000,
    @AppUserId         = 1;
SELECT @S = Status, @M = Message, @NewId = NewId FROM #Rcc2;
DROP TABLE #Rcc2;

SET @SStr = CAST(@S AS NVARCHAR(1));

EXEC test.Assert_IsEqual
    @TestName = N'[CreateHappy] Status is 1',
    @Expected = N'1',
    @Actual   = @SStr;

DECLARE @NewIdStr NVARCHAR(20) = CAST(@NewId AS NVARCHAR(20));
EXEC test.Assert_IsNotNull
    @TestName = N'[CreateHappy] NewId is not NULL',
    @Value    = @NewIdStr;

DECLARE @RowCount INT;
SELECT @RowCount = COUNT(*) FROM Parts.ContainerConfig WHERE Id = @NewId;
EXEC test.Assert_RowCount
    @TestName      = N'[CreateHappy] Row exists',
    @ExpectedCount = 1,
    @ActualCount   = @RowCount;
GO

-- =============================================
-- Test 3: ContainerConfig_Create - NULL required param (ItemId)
--   Status=0.
-- =============================================
DECLARE @S    BIT,
        @M    NVARCHAR(500),
        @SStr NVARCHAR(1),
        @NewId BIGINT;

CREATE TABLE #Rcc3 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #Rcc3 EXEC Parts.ContainerConfig_Create
    @ItemId            = NULL,
    @TraysPerContainer = 1,
    @PartsPerTray      = 1,
    @IsSerialized      = 0,
    @DunnageCode       = N'DUN-X',
    @CustomerCode      = N'CUST-X',
    @AppUserId         = 1;
SELECT @S = Status, @M = Message, @NewId = NewId FROM #Rcc3;
DROP TABLE #Rcc3;

SET @SStr = CAST(@S AS NVARCHAR(1));

EXEC test.Assert_IsEqual
    @TestName = N'[CreateNullItem] Status is 0',
    @Expected = N'0',
    @Actual   = @SStr;

DECLARE @NewIdStr NVARCHAR(20) = CAST(@NewId AS NVARCHAR(20));
EXEC test.Assert_IsNull
    @TestName = N'[CreateNullItem] NewId is NULL',
    @Value    = @NewIdStr;
GO

-- =============================================
-- Test 4: ContainerConfig_Create - invalid ItemId
--   Status=0.
-- =============================================
DECLARE @S    BIT,
        @M    NVARCHAR(500),
        @SStr NVARCHAR(1),
        @NewId BIGINT;

CREATE TABLE #Rcc4 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #Rcc4 EXEC Parts.ContainerConfig_Create
    @ItemId            = 999999,
    @TraysPerContainer = 1,
    @PartsPerTray      = 1,
    @IsSerialized      = 0,
    @DunnageCode       = N'DUN-X',
    @CustomerCode      = N'CUST-X',
    @AppUserId         = 1;
SELECT @S = Status, @M = Message, @NewId = NewId FROM #Rcc4;
DROP TABLE #Rcc4;

SET @SStr = CAST(@S AS NVARCHAR(1));

EXEC test.Assert_IsEqual
    @TestName = N'[CreateBadItem] Status is 0',
    @Expected = N'0',
    @Actual   = @SStr;
GO

-- =============================================
-- Test 5: ContainerConfig_Create duplicate active config for same Item
--   Second active create for same ItemId must fail (filtered unique index
--   UQ_ContainerConfig_ActiveItemId). Proc should return status=0 with
--   a friendly message, whether pre-checked or caught via CATCH.
-- =============================================
DECLARE @S    BIT,
        @M    NVARCHAR(500),
        @SStr NVARCHAR(1),
        @ItemId BIGINT,
        @NewId BIGINT;

SELECT @ItemId = Id FROM Parts.Item WHERE PartNumber = N'TEST-CC-001';

CREATE TABLE #Rcc5 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #Rcc5 EXEC Parts.ContainerConfig_Create
    @ItemId            = @ItemId,
    @TraysPerContainer = 2,
    @PartsPerTray      = 10,
    @IsSerialized      = 0,
    @DunnageCode       = N'DUN-DUP',
    @CustomerCode      = N'CUST-DUP',
    @AppUserId         = 1;
SELECT @S = Status, @M = Message, @NewId = NewId FROM #Rcc5;
DROP TABLE #Rcc5;

SET @SStr = CAST(@S AS NVARCHAR(1));

EXEC test.Assert_IsEqual
    @TestName = N'[CreateDupActive] Status is 0',
    @Expected = N'0',
    @Actual   = @SStr;

DECLARE @NewIdStr NVARCHAR(20) = CAST(@NewId AS NVARCHAR(20));
EXEC test.Assert_IsNull
    @TestName = N'[CreateDupActive] NewId is NULL',
    @Value    = @NewIdStr;
GO

-- =============================================
-- Test 6: ContainerConfig_GetByItem returns the created row
-- =============================================
DECLARE @S    BIT,
        @M    NVARCHAR(500),
        @SStr NVARCHAR(1),
        @ItemId BIGINT;

SELECT @ItemId = Id FROM Parts.Item WHERE PartNumber = N'TEST-CC-001';

CREATE TABLE #Cc1 (
    Id                 BIGINT,
    ItemId             BIGINT,
    TraysPerContainer  INT,
    PartsPerTray       INT,
    IsSerialized       BIT,
    DunnageCode        NVARCHAR(50),
    CustomerCode       NVARCHAR(50),
    ClosureMethod      NVARCHAR(20),
    TargetWeight       DECIMAL(10,4),
    CreatedAt          DATETIME2(3),
    UpdatedAt          DATETIME2(3),
    DeprecatedAt       DATETIME2(3)
);

INSERT INTO #Cc1
EXEC Parts.ContainerConfig_GetByItem @ItemId = @ItemId;

DECLARE @ActiveCount INT = (SELECT COUNT(*) FROM #Cc1 WHERE DeprecatedAt IS NULL);
EXEC test.Assert_RowCount
    @TestName      = N'[GetByItem] One active row returned',
    @ExpectedCount = 1,
    @ActualCount   = @ActiveCount;

DROP TABLE #Cc1;
GO

-- =============================================
-- Test 7: ContainerConfig_Update happy path
--   TraysPerContainer changes, UpdatedAt is not NULL.
-- =============================================
DECLARE @S    BIT,
        @M    NVARCHAR(500),
        @SStr NVARCHAR(1),
        @ItemId BIGINT,
        @CcId BIGINT;

SELECT @ItemId = Id FROM Parts.Item WHERE PartNumber = N'TEST-CC-001';
SELECT @CcId = Id FROM Parts.ContainerConfig
    WHERE ItemId = @ItemId AND DeprecatedAt IS NULL;

CREATE TABLE #Rcc7 (Status BIT, Message NVARCHAR(500));
INSERT INTO #Rcc7 EXEC Parts.ContainerConfig_Update
    @Id                = @CcId,
    @TraysPerContainer = 8,
    @PartsPerTray      = 25,
    @IsSerialized      = 0,
    @DunnageCode       = N'DUN-001',
    @CustomerCode      = N'CUST-HON',
    @ClosureMethod     = N'Strap',
    @TargetWeight      = 150.0000,
    @AppUserId         = 1;
SELECT @S = Status, @M = Message FROM #Rcc7;
DROP TABLE #Rcc7;

SET @SStr = CAST(@S AS NVARCHAR(1));

EXEC test.Assert_IsEqual
    @TestName = N'[UpdateHappy] Status is 1',
    @Expected = N'1',
    @Actual   = @SStr;

DECLARE @StoredTrays INT,
        @StoredUpdatedAt DATETIME2(3);

SELECT
    @StoredTrays     = TraysPerContainer,
    @StoredUpdatedAt = UpdatedAt
FROM Parts.ContainerConfig
WHERE Id = @CcId;

DECLARE @TraysStr NVARCHAR(20) = CAST(@StoredTrays AS NVARCHAR(20));
EXEC test.Assert_IsEqual
    @TestName = N'[UpdateHappy] TraysPerContainer = 8',
    @Expected = N'8',
    @Actual   = @TraysStr;

DECLARE @UpdatedAtNotNull NVARCHAR(1) = CASE WHEN @StoredUpdatedAt IS NOT NULL THEN N'1' ELSE N'0' END;
EXEC test.Assert_IsEqual
    @TestName = N'[UpdateHappy] UpdatedAt is not NULL',
    @Expected = N'1',
    @Actual   = @UpdatedAtNotNull;
GO

-- =============================================
-- Test 8: ContainerConfig_Update - missing Id
--   Status=0.
-- =============================================
DECLARE @S    BIT,
        @M    NVARCHAR(500),
        @SStr NVARCHAR(1);

CREATE TABLE #Rcc8 (Status BIT, Message NVARCHAR(500));
INSERT INTO #Rcc8 EXEC Parts.ContainerConfig_Update
    @Id                = NULL,
    @TraysPerContainer = 1,
    @PartsPerTray      = 1,
    @IsSerialized      = 0,
    @DunnageCode       = N'DUN',
    @CustomerCode      = N'CUST',
    @AppUserId         = 1;
SELECT @S = Status, @M = Message FROM #Rcc8;
DROP TABLE #Rcc8;

SET @SStr = CAST(@S AS NVARCHAR(1));

EXEC test.Assert_IsEqual
    @TestName = N'[UpdateNullId] Status is 0',
    @Expected = N'0',
    @Actual   = @SStr;
GO

-- =============================================
-- Test 9: ContainerConfig_Deprecate happy path
--   DeprecatedAt is set.
-- =============================================
DECLARE @S    BIT,
        @M    NVARCHAR(500),
        @SStr NVARCHAR(1),
        @ItemId BIGINT,
        @CcId BIGINT;

SELECT @ItemId = Id FROM Parts.Item WHERE PartNumber = N'TEST-CC-001';
SELECT @CcId = Id FROM Parts.ContainerConfig
    WHERE ItemId = @ItemId AND DeprecatedAt IS NULL;

CREATE TABLE #Rcc9 (Status BIT, Message NVARCHAR(500));
INSERT INTO #Rcc9 EXEC Parts.ContainerConfig_Deprecate
    @Id        = @CcId,
    @AppUserId = 1;
SELECT @S = Status, @M = Message FROM #Rcc9;
DROP TABLE #Rcc9;

SET @SStr = CAST(@S AS NVARCHAR(1));

EXEC test.Assert_IsEqual
    @TestName = N'[DeprecateHappy] Status is 1',
    @Expected = N'1',
    @Actual   = @SStr;

DECLARE @DepAt DATETIME2(3);
SELECT @DepAt = DeprecatedAt FROM Parts.ContainerConfig WHERE Id = @CcId;

DECLARE @DepAtNotNull NVARCHAR(1) = CASE WHEN @DepAt IS NOT NULL THEN N'1' ELSE N'0' END;
EXEC test.Assert_IsEqual
    @TestName = N'[DeprecateHappy] DeprecatedAt is not NULL',
    @Expected = N'1',
    @Actual   = @DepAtNotNull;
GO

-- =============================================
-- Test 10: After deprecate, Create succeeds for same Item
--   (filtered unique index only covers active rows).
-- =============================================
DECLARE @S    BIT,
        @M    NVARCHAR(500),
        @SStr NVARCHAR(1),
        @ItemId BIGINT,
        @NewId BIGINT;

SELECT @ItemId = Id FROM Parts.Item WHERE PartNumber = N'TEST-CC-001';

CREATE TABLE #Rcc10 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #Rcc10 EXEC Parts.ContainerConfig_Create
    @ItemId            = @ItemId,
    @TraysPerContainer = 6,
    @PartsPerTray      = 30,
    @IsSerialized      = 1,
    @DunnageCode       = N'DUN-002',
    @CustomerCode      = N'CUST-HON',
    @ClosureMethod     = N'Lid',
    @TargetWeight      = 200.0000,
    @AppUserId         = 1;
SELECT @S = Status, @M = Message, @NewId = NewId FROM #Rcc10;
DROP TABLE #Rcc10;

SET @SStr = CAST(@S AS NVARCHAR(1));

EXEC test.Assert_IsEqual
    @TestName = N'[CreateAfterDep] Status is 1',
    @Expected = N'1',
    @Actual   = @SStr;

DECLARE @NewIdStr NVARCHAR(20) = CAST(@NewId AS NVARCHAR(20));
EXEC test.Assert_IsNotNull
    @TestName = N'[CreateAfterDep] NewId is not NULL',
    @Value    = @NewIdStr;

-- There should now be exactly 1 active + 1 deprecated row for the item
DECLARE @ActiveCount INT;
SELECT @ActiveCount = COUNT(*) FROM Parts.ContainerConfig
    WHERE ItemId = @ItemId AND DeprecatedAt IS NULL;
EXEC test.Assert_RowCount
    @TestName      = N'[CreateAfterDep] Exactly 1 active row for Item',
    @ExpectedCount = 1,
    @ActualCount   = @ActiveCount;
GO

-- =============================================
-- Test 11: Audit trail - ConfigLog has entries for ContainerConfig
-- =============================================
DECLARE @AuditCount INT;
SELECT @AuditCount = COUNT(*)
FROM Audit.ConfigLog cl
INNER JOIN Audit.LogEntityType let ON let.Id = cl.LogEntityTypeId
WHERE let.Code = N'ContainerConfig';

DECLARE @AuditCond BIT = CASE WHEN @AuditCount >= 3 THEN 1 ELSE 0 END;
EXEC test.Assert_IsTrue
    @TestName  = N'[Audit] ConfigLog has >= 3 ContainerConfig entries',
    @Condition = @AuditCond;
GO

-- =============================================
-- Test 12: Audit-readability narrative — ContainerConfig_Create Description + FK
--   Slice 5 convention. Description shape:
--     <PartNumber> · Container Config · Created; <key params>
--   NewValue JSON carries a resolved "Item" sub-object (PartNumber).
-- =============================================
DECLARE @S    BIT,
        @M    NVARCHAR(500),
        @SStr NVARCHAR(1),
        @ItemId BIGINT,
        @NewId BIGINT;

-- Fresh host item (TEST-CC- prefix is covered by cleanup below)
CREATE TABLE #RcS5Item (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #RcS5Item
EXEC Parts.Item_Create
    @ItemTypeId  = 4,
    @PartNumber  = N'TEST-CC-S5-001',
    @Description = N'Container Audit Host',
    @UomId       = 1,
    @AppUserId   = 1;
SELECT @ItemId = NewId FROM #RcS5Item;
DROP TABLE #RcS5Item;

CREATE TABLE #RccAud1 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #RccAud1 EXEC Parts.ContainerConfig_Create
    @ItemId            = @ItemId,
    @TraysPerContainer = 4,
    @PartsPerTray      = 25,
    @IsSerialized      = 0,
    @ClosureMethod     = N'ByCount',
    @AppUserId         = 1;
SELECT @NewId = NewId FROM #RccAud1;
DROP TABLE #RccAud1;

DECLARE @CcCreateDesc NVARCHAR(500), @CcCreateNew NVARCHAR(MAX);
SELECT TOP 1 @CcCreateDesc = cl.Description, @CcCreateNew = cl.NewValue
FROM Audit.ConfigLog cl
INNER JOIN Audit.LogEntityType let ON let.Id = cl.LogEntityTypeId
WHERE let.Code = N'ContainerConfig' AND cl.EntityId = @NewId
ORDER BY cl.Id DESC;

DECLARE @CcCreateDescMatch NVARCHAR(1) =
    CASE WHEN @CcCreateDesc LIKE N'TEST-CC-S5-001%Container Config%Created%ClosureMethod ByCount%'
         THEN N'1' ELSE N'0' END;
EXEC test.Assert_IsEqual
    @TestName = N'[AuditCcCreate] Description matches "<Part> · Container Config · Created; ..."',
    @Expected = N'1',
    @Actual   = @CcCreateDescMatch;

DECLARE @CcCreateFkMatch NVARCHAR(1) =
    CASE WHEN JSON_VALUE(@CcCreateNew, '$.Item.PartNumber') IS NOT NULL THEN N'1' ELSE N'0' END;
EXEC test.Assert_IsEqual
    @TestName = N'[AuditCcCreate] NewValue has resolved Item.PartNumber',
    @Expected = N'1',
    @Actual   = @CcCreateFkMatch;
GO

-- =============================================
-- Test 13: Audit-readability narrative — ContainerConfig_Update Description (diff)
--   Description shape:
--     <PartNumber> · Container Config · Updated ClosureMethod ByCount → ByWeight; ...
--   OldValue JSON carries a resolved "Item" sub-object.
-- =============================================
DECLARE @S    BIT,
        @M    NVARCHAR(500),
        @ItemId BIGINT,
        @CcId BIGINT;

SELECT @ItemId = Id FROM Parts.Item WHERE PartNumber = N'TEST-CC-S5-001';
SELECT @CcId = Id FROM Parts.ContainerConfig
    WHERE ItemId = @ItemId AND DeprecatedAt IS NULL;

CREATE TABLE #RccAud2 (Status BIT, Message NVARCHAR(500));
INSERT INTO #RccAud2 EXEC Parts.ContainerConfig_Update
    @Id                = @CcId,
    @TraysPerContainer = 4,
    @PartsPerTray      = 25,
    @IsSerialized      = 0,
    @ClosureMethod     = N'ByWeight',
    @TargetWeight      = 1500.0000,
    @AppUserId         = 1;
SELECT @S = Status, @M = Message FROM #RccAud2;
DROP TABLE #RccAud2;

DECLARE @CcUpdDesc NVARCHAR(500), @CcUpdOld NVARCHAR(MAX);
SELECT TOP 1 @CcUpdDesc = cl.Description, @CcUpdOld = cl.OldValue
FROM Audit.ConfigLog cl
INNER JOIN Audit.LogEntityType let ON let.Id = cl.LogEntityTypeId
WHERE let.Code = N'ContainerConfig' AND cl.EntityId = @CcId AND cl.Description LIKE N'%Updated%'
ORDER BY cl.Id DESC;

DECLARE @CcUpdDescMatch NVARCHAR(1) =
    CASE WHEN @CcUpdDesc LIKE N'TEST-CC-S5-001%Container Config%Updated%ClosureMethod ByCount%ByWeight%'
         THEN N'1' ELSE N'0' END;
EXEC test.Assert_IsEqual
    @TestName = N'[AuditCcUpdate] Description shows changed field old→new',
    @Expected = N'1',
    @Actual   = @CcUpdDescMatch;

DECLARE @CcUpdFkMatch NVARCHAR(1) =
    CASE WHEN JSON_VALUE(@CcUpdOld, '$.Item.PartNumber') IS NOT NULL THEN N'1' ELSE N'0' END;
EXEC test.Assert_IsEqual
    @TestName = N'[AuditCcUpdate] OldValue has resolved Item.PartNumber',
    @Expected = N'1',
    @Actual   = @CcUpdFkMatch;
GO

-- =============================================
-- Cleanup: delete test ContainerConfig rows and the host Item
-- =============================================
DELETE cc
FROM Parts.ContainerConfig cc
INNER JOIN Parts.Item i ON i.Id = cc.ItemId
WHERE i.PartNumber LIKE N'TEST-CC-%';

DELETE FROM Parts.Item WHERE PartNumber LIKE N'TEST-CC-%';
GO

-- =============================================
-- Final summary
-- =============================================
EXEC test.PrintSummary;
GO
