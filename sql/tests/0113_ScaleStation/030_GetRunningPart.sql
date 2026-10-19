-- =============================================
-- File:         0113_ScaleStation/030_GetRunningPart.sql
-- Author:       Blue Ridge Automation
-- Created:      2026-10-19
-- Description:
--   Workorder.ScaleStation_GetRunningPart: the one rule that decides which
--   part a By Weight scale closes, shared by the scale close and the screen
--   (spec §5): the station's open box, else an eligible override, else the
--   eligible part closest to ready, else None. Always exactly one row.
--   Reuses the TST-SS-* fixture built by 020_EligibleParts.sql.
-- =============================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0113_ScaleStation/030_GetRunningPart.sql';
GO

CREATE TABLE #R (ItemId BIGINT, PartNumber NVARCHAR(50), Description NVARCHAR(500), Source NVARCHAR(20),
                 PartsPerTray INT, TraysPerContainer INT, TargetWeight DECIMAL(10,4), ToleranceWeight DECIMAL(10,4),
                 LowLimit DECIMAL(10,4), HighLimit DECIMAL(10,4), EligibleCount INT, Message NVARCHAR(500),
                 OverrideItemId BIGINT, OverrideSetBy NVARCHAR(50), OverrideSetAtEt DATETIME2(3),
                 OpenContainerId BIGINT, OpenTraysClosed INT, OpenPartsClosed INT);
GO

-- Stock: FG-A eligible (4/7) and FG-B eligible (2/2, ranks first).
DECLARE @Line BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'TST-SS-LINE');
DECLARE @Good BIGINT = (SELECT Id FROM Lots.LotStatusCode WHERE Code = N'Good');
DECLARE @Rcv BIGINT = (SELECT Id FROM Lots.LotOriginType WHERE Code = N'Received');
DELETE FROM Lots.Lot WHERE CurrentLocationId = @Line;
INSERT INTO Lots.Lot (LotName, ItemId, LotOriginTypeId, LotStatusId, PieceCount, InventoryAvailable, CurrentLocationId, CreatedByUserId)
SELECT N'TST-SS-' + i.PartNumber + N'-' + CAST(NEWID() AS NVARCHAR(36)), i.Id, @Rcv, @Good, 10, 10, @Line, 1
FROM Parts.Item i WHERE i.PartNumber IN (N'TST-SS-C1', N'TST-SS-C2', N'TST-SS-P1', N'TST-SS-P2', N'TST-SS-P3');
GO

-- ==== default ====
DECLARE @Term BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'TST-SS-AOUT');
DELETE FROM #R; INSERT INTO #R EXEC Workorder.ScaleStation_GetRunningPart @TerminalLocationId = @Term;
DECLARE @S NVARCHAR(200) = (SELECT CONCAT(PartNumber, N'|', Source, N'|', EligibleCount, N'|', PartsPerTray, N'|', LowLimit, N'-', HighLimit) FROM #R);
EXEC test.Assert_IsEqual @TestName = N'[ScaleRun] default = ReadyRank 1, Source Default',
    @Expected = N'TST-SS-FG-B|Default|2|10|17.7500-18.7500', @Actual = @S;
GO

-- ==== override honoured ====
DECLARE @Term BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'TST-SS-AOUT');
DECLARE @Def BIGINT = (SELECT Id FROM Location.LocationAttributeDefinition WHERE LocationTypeDefinitionId = 7 AND AttributeName = N'ScaleRunningItemId' AND DeprecatedAt IS NULL);
DECLARE @A NVARCHAR(20) = (SELECT CAST(Id AS NVARCHAR(20)) FROM Parts.Item WHERE PartNumber = N'TST-SS-FG-A');
DELETE FROM Location.LocationAttribute WHERE LocationId = @Term AND LocationAttributeDefinitionId = @Def;
INSERT INTO Location.LocationAttribute (LocationId, LocationAttributeDefinitionId, AttributeValue, CreatedAt, UpdatedAt, UpdatedByUserId)
VALUES (@Term, @Def, @A, SYSUTCDATETIME(), SYSUTCDATETIME(), 1);
DELETE FROM #R; INSERT INTO #R EXEC Workorder.ScaleStation_GetRunningPart @TerminalLocationId = @Term;
DECLARE @S NVARCHAR(200) = (SELECT CONCAT(PartNumber, N'|', Source, N'|', CASE WHEN OverrideItemId = CAST(@A AS BIGINT) THEN N'ovr' ELSE N'?' END) FROM #R);
EXEC test.Assert_IsEqual @TestName = N'[ScaleRun] override honoured, Source Override', @Expected = N'TST-SS-FG-A|Override|ovr', @Actual = @S;
GO

-- ==== ineligible override falls back, and says so ====
DECLARE @Term BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'TST-SS-AOUT');
DECLARE @Def BIGINT = (SELECT Id FROM Location.LocationAttributeDefinition WHERE LocationTypeDefinitionId = 7 AND AttributeName = N'ScaleRunningItemId' AND DeprecatedAt IS NULL);
UPDATE Location.LocationAttribute SET AttributeValue = (SELECT CAST(Id AS NVARCHAR(20)) FROM Parts.Item WHERE PartNumber = N'TST-SS-FG-N')
WHERE LocationId = @Term AND LocationAttributeDefinitionId = @Def;
DELETE FROM #R; INSERT INTO #R EXEC Workorder.ScaleStation_GetRunningPart @TerminalLocationId = @Term;
DECLARE @S NVARCHAR(200) = (SELECT CONCAT(PartNumber, N'|', Source) FROM #R);
EXEC test.Assert_IsEqual @TestName = N'[ScaleRun] ineligible override falls back to the default', @Expected = N'TST-SS-FG-B|Default', @Actual = @S;
DECLARE @M NVARCHAR(500) = (SELECT Message FROM #R);
EXEC test.Assert_Contains @TestName = N'[ScaleRun] ineligible override falls back with message', @HaystackStr = @M, @NeedleStr = N'not eligible';
DELETE FROM Location.LocationAttribute WHERE LocationId = @Term AND LocationAttributeDefinitionId = @Def;
GO

-- ==== open box beats override; trays/parts closed from production records ====
DECLARE @Term BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'TST-SS-AOUT');
DECLARE @Line BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'TST-SS-LINE');
DECLARE @Def BIGINT = (SELECT Id FROM Location.LocationAttributeDefinition WHERE LocationTypeDefinitionId = 7 AND AttributeName = N'ScaleRunningItemId' AND DeprecatedAt IS NULL);
DECLARE @A BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'TST-SS-FG-A');
DECLARE @B BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'TST-SS-FG-B');
DECLARE @CfgA BIGINT = (SELECT Id FROM Parts.ContainerConfig WHERE ItemId = @A AND ClosureMethod = N'ByWeight' AND DeprecatedAt IS NULL);
INSERT INTO Location.LocationAttribute (LocationId, LocationAttributeDefinitionId, AttributeValue, CreatedAt)
VALUES (@Term, @Def, CAST(@B AS NVARCHAR(20)), SYSUTCDATETIME());
INSERT INTO Lots.Container (ItemId, ContainerConfigId, CurrentLocationId, ContainerStatusCodeId, CreatedByUserId, StationLocationId)
VALUES (@A, @CfgA, @Line, 1, 1, @Term);
DECLARE @C BIGINT = SCOPE_IDENTITY();
INSERT INTO Lots.ContainerTray (ContainerId, TrayPosition, PartsClosedCount, ClosedAt, ClosureMethod)
VALUES (@C, 1, 10, SYSUTCDATETIME(), N'ByWeight'), (@C, 2, 10, SYSUTCDATETIME(), N'ByWeight'), (@C, 3, 10, SYSUTCDATETIME(), N'ByWeight');
DELETE FROM #R; INSERT INTO #R EXEC Workorder.ScaleStation_GetRunningPart @TerminalLocationId = @Term;
DECLARE @S NVARCHAR(200) = (SELECT CONCAT(PartNumber, N'|', CASE WHEN OpenContainerId = @C THEN N'box' ELSE N'?' END, N'|', OpenTraysClosed, N'|', OpenPartsClosed) FROM #R);
EXEC test.Assert_IsEqual @TestName = N'[ScaleRun] open box beats override', @Expected = N'TST-SS-FG-A|box|3|30', @Actual = @S;
DELETE FROM Lots.ContainerTray WHERE ContainerId = @C;
DELETE FROM Lots.Container WHERE Id = @C;
DELETE FROM Location.LocationAttribute WHERE LocationId = @Term AND LocationAttributeDefinitionId = @Def;
GO

-- ==== nothing eligible ====
DECLARE @Term BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'TST-SS-AOUT');
DECLARE @Line BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'TST-SS-LINE');
DELETE FROM Lots.Lot WHERE CurrentLocationId = @Line;
DELETE FROM #R; INSERT INTO #R EXEC Workorder.ScaleStation_GetRunningPart @TerminalLocationId = @Term;
DECLARE @S NVARCHAR(200) = (SELECT CONCAT(COUNT(*), N'|', MAX(Source), N'|', MAX(EligibleCount), N'|', CASE WHEN MAX(Message) IS NULL THEN N'nomsg' ELSE N'msg' END) FROM #R);
EXEC test.Assert_IsEqual @TestName = N'[ScaleRun] nothing eligible -> Source None, one row, Message set', @Expected = N'1|None|0|msg', @Actual = @S;
GO

-- ==== not a terminal -> one row, None ====
DECLARE @Line BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'TST-SS-LINE');
DELETE FROM #R; INSERT INTO #R EXEC Workorder.ScaleStation_GetRunningPart @TerminalLocationId = @Line;
DECLARE @S NVARCHAR(200) = (SELECT CONCAT(COUNT(*), N'|', MAX(Source)) FROM #R);
EXEC test.Assert_IsEqual @TestName = N'[ScaleRun] not a terminal -> one row, Source None', @Expected = N'1|None', @Actual = @S;
GO

DROP TABLE #R;
GO
EXEC test.EndTestFile;
GO
