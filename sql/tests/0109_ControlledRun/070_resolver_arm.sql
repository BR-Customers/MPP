-- =============================================
-- File:        0109_ControlledRun/070_resolver_arm.sql
-- Author:      Blue Ridge Automation
-- Description: Lots.ufn_CrtForMint arm 4 -- an open super-lot window tags new production of its part (and line).
-- =============================================
EXEC test.BeginTestFile @FileName = N'0109_ControlledRun/070_resolver_arm.sql';
GO

-- ---- teardown (FK-safe): everything this suite creates (LOT names start TEST-CR-) ----
DECLARE @TdCon TABLE (Id BIGINT);
INSERT INTO @TdCon (Id)
SELECT DISTINCT ContainerId FROM Lots.ContainerTray
WHERE FinishedGoodLotId IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'TEST-CR-%');
DELETE FROM Quality.ControlledRunLabel;
DELETE FROM Quality.ControlledRunMember;
DELETE FROM Quality.ControlledRun;
DELETE FROM Lots.ContainerTray WHERE ContainerId IN (SELECT Id FROM @TdCon);
DELETE FROM Lots.Container WHERE Id IN (SELECT Id FROM @TdCon);
DELETE FROM Lots.LotGenealogyClosure
WHERE AncestorLotId   IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'TEST-CR-%')
   OR DescendantLotId IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'TEST-CR-%');
DELETE FROM Lots.LotEventLog WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'TEST-CR-%');
DELETE FROM Lots.Lot WHERE LotName LIKE N'TEST-CR-%';
UPDATE Lots.IdentifierSequence SET LastValue = 0 WHERE Code = N'ControlledRun';
GO

DECLARE @App  BIGINT = (SELECT TOP 1 Id FROM Location.AppUser WHERE Initials = N'SYS');
DECLARE @Item BIGINT = (SELECT TOP 1 Id FROM Parts.Item WHERE DeprecatedAt IS NULL ORDER BY Id);
DECLARE @Item2 BIGINT = (SELECT TOP 1 Id FROM Parts.Item WHERE DeprecatedAt IS NULL AND Id <> @Item ORDER BY Id);
DECLARE @Term BIGINT = (SELECT TOP 1 l.Id FROM Location.Location l
    JOIN Location.LocationTypeDefinition d ON d.Id = l.LocationTypeDefinitionId
    WHERE d.Code = N'Terminal' AND l.DeprecatedAt IS NULL AND l.ParentLocationId IS NOT NULL ORDER BY l.Id);
DECLARE @Line BIGINT = (SELECT ParentLocationId FROM Location.Location WHERE Id = @Term);
DECLARE @TermOther BIGINT = (SELECT TOP 1 l.Id FROM Location.Location l
    JOIN Location.LocationTypeDefinition d ON d.Id = l.LocationTypeDefinitionId
    WHERE d.Code = N'Terminal' AND l.DeprecatedAt IS NULL AND l.ParentLocationId <> @Line ORDER BY l.Id);
DECLARE @Cfg BIGINT = ISNULL((SELECT TOP 1 Id FROM Parts.ContainerConfig WHERE ItemId = @Item), (SELECT TOP 1 Id FROM Parts.ContainerConfig));
DECLARE @n NVARCHAR(500);

-- neutralise the other three arms for the fixture parts and terminals
DECLARE @OldCrt1 BIT = (SELECT CrtEnabled FROM Parts.Item WHERE Id = @Item);
DECLARE @OldCrt2 BIT = (SELECT CrtEnabled FROM Parts.Item WHERE Id = @Item2);
UPDATE Parts.Item SET CrtEnabled = 0 WHERE Id IN (@Item, @Item2);
DECLARE @AdCrt BIGINT = (SELECT TOP 1 Id FROM Location.LocationAttributeDefinition WHERE AttributeName = N'CrtEnabled' AND DeprecatedAt IS NULL);
DELETE FROM Location.LocationAttribute WHERE LocationId IN (@Term, @TermOther) AND LocationAttributeDefinitionId = @AdCrt;

DECLARE @b BIT;
SELECT @b = CrtActive FROM Lots.ufn_CrtForMint(@Item, @Term, NULL);
SET @n = CAST(@b AS NVARCHAR(1));
EXEC test.Assert_IsEqual @TestName = N'[Arm4] no super-lot window -> 0 (unchanged behaviour)', @Expected = N'0', @Actual = @n;

INSERT INTO Quality.ControlledRun (RunNumber, ControlledRunStatusId, Reason, OpenedByUserId, SelectionItemId, SelectionLocationId, AutoJoinEnabled)
VALUES (N'CR000701', 1, N'arm test', @App, @Item, @Line, 1);
DECLARE @Run BIGINT = SCOPE_IDENTITY();

SELECT @b = CrtActive FROM Lots.ufn_CrtForMint(@Item, @Term, NULL);
SET @n = CAST(@b AS NVARCHAR(1));
EXEC test.Assert_IsEqual @TestName = N'[Arm4] open window: the part minted at a terminal under the line -> 1', @Expected = N'1', @Actual = @n;
SELECT @b = CrtActive FROM Lots.ufn_CrtForMint(@Item, @TermOther, NULL);
SET @n = CAST(@b AS NVARCHAR(1));
EXEC test.Assert_IsEqual @TestName = N'[Arm4] same part at another line -> 0', @Expected = N'0', @Actual = @n;
SELECT @b = CrtActive FROM Lots.ufn_CrtForMint(@Item2, @Term, NULL);
SET @n = CAST(@b AS NVARCHAR(1));
EXEC test.Assert_IsEqual @TestName = N'[Arm4] another part at the line -> 0', @Expected = N'0', @Actual = @n;
SELECT @b = CrtActive FROM Lots.ufn_CrtForMint(@Item, NULL, NULL);
SET @n = CAST(@b AS NVARCHAR(1));
EXEC test.Assert_IsEqual @TestName = N'[Arm4] a window that names a line needs a terminal to match -> 0', @Expected = N'0', @Actual = @n;

UPDATE Quality.ControlledRun SET SelectionLocationId = NULL WHERE Id = @Run;
SELECT @b = CrtActive FROM Lots.ufn_CrtForMint(@Item, @TermOther, NULL);
SET @n = CAST(@b AS NVARCHAR(1));
EXEC test.Assert_IsEqual @TestName = N'[Arm4] a window with no line covers the part anywhere -> 1', @Expected = N'1', @Actual = @n;
SELECT @b = CrtActive FROM Lots.ufn_CrtForMint(@Item, NULL, NULL);
SET @n = CAST(@b AS NVARCHAR(1));
EXEC test.Assert_IsEqual @TestName = N'[Arm4] ... including a mint with no terminal -> 1', @Expected = N'1', @Actual = @n;

UPDATE Quality.ControlledRun SET AutoJoinEnabled = 0 WHERE Id = @Run;
SELECT @b = CrtActive FROM Lots.ufn_CrtForMint(@Item, @Term, NULL);
SET @n = CAST(@b AS NVARCHAR(1));
EXEC test.Assert_IsEqual @TestName = N'[Arm4] window ended -> 0', @Expected = N'0', @Actual = @n;

UPDATE Quality.ControlledRun SET AutoJoinEnabled = 1, ControlledRunStatusId = 2, ClosedByUserId = @App, ClosedAt = SYSUTCDATETIME() WHERE Id = @Run;
SELECT @b = CrtActive FROM Lots.ufn_CrtForMint(@Item, @Term, NULL);
SET @n = CAST(@b AS NVARCHAR(1));
EXEC test.Assert_IsEqual @TestName = N'[Arm4] a closed super-lot never tags, whatever its flag says -> 0', @Expected = N'0', @Actual = @n;

SET @n = (SELECT CAST(COUNT(*) AS NVARCHAR(5)) FROM Lots.ufn_CrtForMint(999999999, 999999999, NULL));
EXEC test.Assert_IsEqual @TestName = N'[Arm4] still exactly one row for a nonexistent part and terminal', @Expected = N'1', @Actual = @n;

UPDATE Parts.Item SET CrtEnabled = @OldCrt1 WHERE Id = @Item;
UPDATE Parts.Item SET CrtEnabled = @OldCrt2 WHERE Id = @Item2;
GO

-- ---- teardown (FK-safe): everything this suite creates (LOT names start TEST-CR-) ----
DECLARE @TdCon TABLE (Id BIGINT);
INSERT INTO @TdCon (Id)
SELECT DISTINCT ContainerId FROM Lots.ContainerTray
WHERE FinishedGoodLotId IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'TEST-CR-%');
DELETE FROM Quality.ControlledRunLabel;
DELETE FROM Quality.ControlledRunMember;
DELETE FROM Quality.ControlledRun;
DELETE FROM Lots.ContainerTray WHERE ContainerId IN (SELECT Id FROM @TdCon);
DELETE FROM Lots.Container WHERE Id IN (SELECT Id FROM @TdCon);
DELETE FROM Lots.LotGenealogyClosure
WHERE AncestorLotId   IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'TEST-CR-%')
   OR DescendantLotId IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'TEST-CR-%');
DELETE FROM Lots.LotEventLog WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'TEST-CR-%');
DELETE FROM Lots.Lot WHERE LotName LIKE N'TEST-CR-%';
UPDATE Lots.IdentifierSequence SET LastValue = 0 WHERE Code = N'ControlledRun';
GO

EXEC test.EndTestFile;
GO
