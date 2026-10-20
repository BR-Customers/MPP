-- =============================================
-- File:         0113_ScaleStation/040_SetScaleRunningPart.sql
-- Author:       Blue Ridge Automation
-- Created:      2026-10-19
-- Description:
--   Location.Terminal_SetScaleRunningPart: the audited per-terminal
--   running-part override (spec section 6). PIN sign-in + audit row is the
--   control; refused when the part is not eligible, when another part's box
--   is open at the station, and on a no-op. Reuses 020's TST-SS-* fixture.
-- =============================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0113_ScaleStation/040_SetScaleRunningPart.sql';
GO

CREATE TABLE #S (Status BIT, Message NVARCHAR(500));
CREATE TABLE #R (ItemId BIGINT, PartNumber NVARCHAR(50), Description NVARCHAR(500), Source NVARCHAR(20),
                 PartsPerTray INT, TraysPerContainer INT, TargetWeight DECIMAL(10,4), ToleranceWeight DECIMAL(10,4),
                 LowLimit DECIMAL(10,4), HighLimit DECIMAL(10,4), EligibleCount INT, Message NVARCHAR(500),
                 OverrideItemId BIGINT, OverrideSetBy NVARCHAR(50), OverrideSetAtEt DATETIME2(3),
                 OpenContainerId BIGINT, OpenTraysClosed INT, OpenPartsClosed INT);
GO

-- Stock so FG-A and FG-B are both eligible; no override, no open box.
DECLARE @Line BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'TST-SS-LINE');
DECLARE @Term BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'TST-SS-AOUT');
DECLARE @Good BIGINT = (SELECT Id FROM Lots.LotStatusCode WHERE Code = N'Good');
DECLARE @Rcv BIGINT = (SELECT Id FROM Lots.LotOriginType WHERE Code = N'Received');
DELETE tr FROM Lots.ContainerTray tr JOIN Lots.Container c ON c.Id = tr.ContainerId WHERE c.CurrentLocationId = @Line;
DELETE FROM Lots.Container WHERE CurrentLocationId = @Line;
DELETE FROM Lots.Lot WHERE CurrentLocationId = @Line;
DELETE FROM Location.LocationAttribute WHERE LocationId = @Term;
INSERT INTO Lots.Lot (LotName, ItemId, LotOriginTypeId, LotStatusId, PieceCount, InventoryAvailable, CurrentLocationId, CreatedByUserId)
SELECT N'TSS-' + RIGHT(i.PartNumber, 2) + N'-' + LEFT(CAST(NEWID() AS NVARCHAR(36)), 8), i.Id, @Rcv, @Good, 10, 10, @Line, 1
FROM Parts.Item i WHERE i.PartNumber IN (N'TST-SS-C1', N'TST-SS-C2', N'TST-SS-P1', N'TST-SS-P2', N'TST-SS-P3');
GO

-- ==== set an eligible part ====
DECLARE @Term BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'TST-SS-AOUT');
DECLARE @A BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'TST-SS-FG-A');
DECLARE @Before BIGINT = ISNULL((SELECT MAX(Id) FROM Audit.OperationLog), 0);
DELETE FROM #S; INSERT INTO #S EXEC Location.Terminal_SetScaleRunningPart @TerminalLocationId = @Term, @ItemId = @A, @AppUserId = 1;
DECLARE @St NVARCHAR(5) = (SELECT CAST(Status AS NVARCHAR(5)) FROM #S);
EXEC test.Assert_IsEqual @TestName = N'[SetRun] set eligible part -> Status 1', @Expected = N'1', @Actual = @St;
DELETE FROM #R; INSERT INTO #R EXEC Workorder.ScaleStation_GetRunningPart @TerminalLocationId = @Term;
DECLARE @R NVARCHAR(100) = (SELECT CONCAT(PartNumber, N'|', Source) FROM #R);
EXEC test.Assert_IsEqual @TestName = N'[SetRun] the scale now runs the override', @Expected = N'TST-SS-FG-A|Override', @Actual = @R;
DECLARE @Aud NVARCHAR(500) = (SELECT TOP 1 ol.Description FROM Audit.OperationLog ol
                              JOIN Audit.LogEventType et ON et.Id = ol.LogEventTypeId
                              WHERE ol.Id > @Before AND et.Code = N'ScaleRunningPartChanged' ORDER BY ol.Id DESC);
EXEC test.Assert_Contains @TestName = N'[SetRun] audit row names old and new part', @HaystackStr = @Aud, @NeedleStr = N'Default -> TST-SS-FG-A';
GO

-- ==== no-op refused ====
DECLARE @Term BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'TST-SS-AOUT');
DECLARE @A BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'TST-SS-FG-A');
DELETE FROM #S; INSERT INTO #S EXEC Location.Terminal_SetScaleRunningPart @TerminalLocationId = @Term, @ItemId = @A, @AppUserId = 1;
DECLARE @St NVARCHAR(5) = (SELECT CAST(Status AS NVARCHAR(5)) FROM #S);
EXEC test.Assert_IsEqual @TestName = N'[SetRun] no-op (same part) refused', @Expected = N'0', @Actual = @St;
GO

-- ==== not eligible refused ====
DECLARE @Term BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'TST-SS-AOUT');
DECLARE @N BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'TST-SS-FG-N');
DELETE FROM #S; INSERT INTO #S EXEC Location.Terminal_SetScaleRunningPart @TerminalLocationId = @Term, @ItemId = @N, @AppUserId = 1;
DECLARE @St NVARCHAR(5) = (SELECT CAST(Status AS NVARCHAR(5)) FROM #S);
EXEC test.Assert_IsEqual @TestName = N'[SetRun] refused: not eligible', @Expected = N'0', @Actual = @St;
GO

-- ==== another part's box open refused ====
DECLARE @Term BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'TST-SS-AOUT');
DECLARE @Line BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'TST-SS-LINE');
DECLARE @A BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'TST-SS-FG-A');
DECLARE @B BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'TST-SS-FG-B');
DECLARE @CfgA BIGINT = (SELECT Id FROM Parts.ContainerConfig WHERE ItemId = @A AND ClosureMethod = N'ByWeight' AND DeprecatedAt IS NULL);
INSERT INTO Lots.Container (ItemId, ContainerConfigId, CurrentLocationId, ContainerStatusCodeId, CreatedByUserId, StationLocationId)
VALUES (@A, @CfgA, @Line, 1, 1, @Term);
DECLARE @C BIGINT = SCOPE_IDENTITY();
DELETE FROM #S; INSERT INTO #S EXEC Location.Terminal_SetScaleRunningPart @TerminalLocationId = @Term, @ItemId = @B, @AppUserId = 1;
DECLARE @S NVARCHAR(600) = (SELECT CONCAT(Status, N'|', Message) FROM #S);
EXEC test.Assert_Contains @TestName = N'[SetRun] refused with another part''s box open', @HaystackStr = @S, @NeedleStr = N'0|Box #';
DELETE FROM Lots.Container WHERE Id = @C;
GO

-- ==== clear ====
DECLARE @Term BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'TST-SS-AOUT');
DELETE FROM #S; INSERT INTO #S EXEC Location.Terminal_SetScaleRunningPart @TerminalLocationId = @Term, @ItemId = NULL, @AppUserId = 1;
DECLARE @St NVARCHAR(5) = (SELECT CAST(Status AS NVARCHAR(5)) FROM #S);
DELETE FROM #R; INSERT INTO #R EXEC Workorder.ScaleStation_GetRunningPart @TerminalLocationId = @Term;
DECLARE @R NVARCHAR(100) = (SELECT CONCAT(@St, N'|', PartNumber, N'|', Source, N'|', ISNULL(CAST(OverrideItemId AS NVARCHAR(20)), N'none')) FROM #R);
EXEC test.Assert_IsEqual @TestName = N'[SetRun] clear -> back to the default', @Expected = N'1|TST-SS-FG-B|Default|none', @Actual = @R;
GO

-- ==== bad inputs ====
DECLARE @Line BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'TST-SS-LINE');
DECLARE @Term BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'TST-SS-AOUT');
DECLARE @A BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'TST-SS-FG-A');
DELETE FROM #S; INSERT INTO #S EXEC Location.Terminal_SetScaleRunningPart @TerminalLocationId = @Line, @ItemId = @A, @AppUserId = 1;
DECLARE @St NVARCHAR(5) = (SELECT CAST(Status AS NVARCHAR(5)) FROM #S);
EXEC test.Assert_IsEqual @TestName = N'[SetRun] refused: not a terminal', @Expected = N'0', @Actual = @St;
DELETE FROM #S; INSERT INTO #S EXEC Location.Terminal_SetScaleRunningPart @TerminalLocationId = @Term, @ItemId = @A, @AppUserId = NULL;
SET @St = (SELECT CAST(Status AS NVARCHAR(5)) FROM #S);
EXEC test.Assert_IsEqual @TestName = N'[SetRun] refused: missing AppUserId', @Expected = N'0', @Actual = @St;
GO

DROP TABLE #S; DROP TABLE #R;
GO
EXEC test.EndTestFile;
GO
