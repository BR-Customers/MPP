-- =============================================
-- File:         0028_PlantFloor_Assembly/035_AimPool_claim_topup.sql
-- Description:  Lots.AimShipperIdPool_Topup + _Claim (Arc 2 Phase 6 / UJ-04). FIFO
--               claim by part number; per-part isolation; OI-33 empty-pool hard-fail;
--               topup idempotent on AimShipperId. (@ContainerId NULL -> no container
--               fixture needed; ConsumedByContainerId is nullable.)
-- =============================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0028_PlantFloor_Assembly/035_AimPool_claim_topup.sql';
GO

DELETE FROM Lots.AimShipperIdPool WHERE PartNumber IN (N'P6-PARTA', N'P6-PARTB');
GO

-- topup 3 for PARTA, 1 for PARTB (distinct ids; FIFO = insertion order via Id tiebreak)
DECLARE @T TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO @T EXEC Lots.AimShipperIdPool_Topup @PartNumber = N'P6-PARTA', @AimShipperId = N'AIM-A1'; DELETE FROM @T;
INSERT INTO @T EXEC Lots.AimShipperIdPool_Topup @PartNumber = N'P6-PARTA', @AimShipperId = N'AIM-A2'; DELETE FROM @T;
INSERT INTO @T EXEC Lots.AimShipperIdPool_Topup @PartNumber = N'P6-PARTA', @AimShipperId = N'AIM-A3'; DELETE FROM @T;
INSERT INTO @T EXEC Lots.AimShipperIdPool_Topup @PartNumber = N'P6-PARTB', @AimShipperId = N'AIM-B1';

DECLARE @Depth NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM Lots.AimShipperIdPool WHERE PartNumber = N'P6-PARTA' AND ConsumedAt IS NULL);
EXEC test.Assert_IsEqual @TestName = N'[AimPool] PARTA depth 3 after topup', @Expected = N'3', @Actual = @Depth;

-- claim PARTA -> FIFO A1
DECLARE @C TABLE (Status BIT, Message NVARCHAR(500), AimShipperId NVARCHAR(50));
INSERT INTO @C EXEC Lots.AimShipperIdPool_Claim @PartNumber = N'P6-PARTA', @ContainerId = NULL, @AppUserId = 1;
DECLARE @S1 NVARCHAR(10) = (SELECT CAST(Status AS NVARCHAR(10)) FROM @C);
DECLARE @A1 NVARCHAR(50) = (SELECT AimShipperId FROM @C); DELETE FROM @C;
EXEC test.Assert_IsEqual @TestName = N'[AimPool] claim 1 Status 1', @Expected = N'1', @Actual = @S1;
EXEC test.Assert_IsEqual @TestName = N'[AimPool] claim 1 is FIFO (AIM-A1)', @Expected = N'AIM-A1', @Actual = @A1;

-- claim PARTA -> A2
INSERT INTO @C EXEC Lots.AimShipperIdPool_Claim @PartNumber = N'P6-PARTA', @ContainerId = NULL, @AppUserId = 1;
DECLARE @A2 NVARCHAR(50) = (SELECT AimShipperId FROM @C); DELETE FROM @C;
EXEC test.Assert_IsEqual @TestName = N'[AimPool] claim 2 is AIM-A2', @Expected = N'AIM-A2', @Actual = @A2;

-- claim PARTB -> B1 (isolation: PARTA claims did not draw PARTB)
INSERT INTO @C EXEC Lots.AimShipperIdPool_Claim @PartNumber = N'P6-PARTB', @ContainerId = NULL, @AppUserId = 1;
DECLARE @B1 NVARCHAR(50) = (SELECT AimShipperId FROM @C); DELETE FROM @C;
EXEC test.Assert_IsEqual @TestName = N'[AimPool] PARTB claim isolated (AIM-B1)', @Expected = N'AIM-B1', @Actual = @B1;

-- claim PARTA -> A3 (drains PARTA)
INSERT INTO @C EXEC Lots.AimShipperIdPool_Claim @PartNumber = N'P6-PARTA', @ContainerId = NULL, @AppUserId = 1;
DECLARE @A3 NVARCHAR(50) = (SELECT AimShipperId FROM @C); DELETE FROM @C;
EXEC test.Assert_IsEqual @TestName = N'[AimPool] claim 3 is AIM-A3', @Expected = N'AIM-A3', @Actual = @A3;

-- claim PARTA empty -> OI-33 hard-fail
INSERT INTO @C EXEC Lots.AimShipperIdPool_Claim @PartNumber = N'P6-PARTA', @ContainerId = NULL, @AppUserId = 1;
DECLARE @SE NVARCHAR(10) = (SELECT CAST(Status AS NVARCHAR(10)) FROM @C);
DECLARE @ME NVARCHAR(500) = (SELECT Message FROM @C); DELETE FROM @C;
EXEC test.Assert_IsEqual @TestName = N'[AimPool] empty pool hard-fail (Status 0)', @Expected = N'0', @Actual = @SE;
DECLARE @MEok NVARCHAR(10) = CASE WHEN @ME LIKE N'%empty%' THEN N'1' ELSE N'0' END;
EXEC test.Assert_IsEqual @TestName = N'[AimPool] empty message mentions empty', @Expected = N'1', @Actual = @MEok;

-- topup idempotent: re-topup an existing id does not double-insert
DECLARE @TI TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO @TI EXEC Lots.AimShipperIdPool_Topup @PartNumber = N'P6-PARTA', @AimShipperId = N'AIM-A1';
DECLARE @Dups NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM Lots.AimShipperIdPool WHERE AimShipperId = N'AIM-A1');
EXEC test.Assert_IsEqual @TestName = N'[AimPool] topup idempotent (no double-insert)', @Expected = N'1', @Actual = @Dups;
GO

DELETE FROM Lots.AimShipperIdPool WHERE PartNumber IN (N'P6-PARTA', N'P6-PARTB');
GO

EXEC test.EndTestFile;
GO
