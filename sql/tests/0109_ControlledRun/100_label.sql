-- =============================================
-- File:        0109_ControlledRun/100_label.sql
-- Author:      Blue Ridge Automation
-- Description: Quality.ControlledRunLabel_Print -- four copies, ZPL-safe free text.
-- =============================================
EXEC test.BeginTestFile @FileName = N'0109_ControlledRun/100_label.sql';
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

INSERT INTO Lots.Lot (LotName, ItemId, LotOriginTypeId, LotStatusId, PieceCount, CurrentLocationId, CreatedByUserId, CreatedAtTerminalId)
VALUES (N'TEST-CR-A', @Item, 1, 1, 10, @Line, @App, @Term), (N'TEST-CR-B', @Item, 1, 1, 10, @Line, @App, @Term), (N'TEST-CR-C', @Item, 1, 1, 10, @Line, @App, @Term);
DECLARE @LotA BIGINT = (SELECT Id FROM Lots.Lot WHERE LotName = N'TEST-CR-A');
DECLARE @LotB BIGINT = (SELECT Id FROM Lots.Lot WHERE LotName = N'TEST-CR-B');
DECLARE @LotC BIGINT = (SELECT Id FROM Lots.Lot WHERE LotName = N'TEST-CR-C');
DECLARE @PartNo NVARCHAR(100) = (SELECT PartNumber FROM Parts.Item WHERE Id = @Item);

DECLARE @o TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
DECLARE @L TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT, ZplContent NVARCHAR(MAX));
DECLARE @j NVARCHAR(MAX) = (SELECT @LotA AS lotId FOR JSON PATH);
INSERT INTO @o EXEC Quality.ControlledRun_Open @Reason = N'porosity at bore', @SelectionItemId = @Item, @MembersJson = @j, @AppUserId = @App;
DECLARE @Run BIGINT = (SELECT NewId FROM @o);

-- ===== the normal label =====
INSERT INTO @L EXEC Quality.ControlledRunLabel_Print @Id = @Run, @AppUserId = @App, @TerminalLocationId = @Term, @PrinterName = N'QA-ZEBRA';
DECLARE @Zpl NVARCHAR(MAX) = (SELECT ZplContent FROM @L);
SET @n = (SELECT CAST(Status AS NVARCHAR(1)) + N'|' + Message + N'|' + CASE WHEN NewId IS NOT NULL THEN N'id' ELSE N'noid' END FROM @L);
EXEC test.Assert_IsEqual @TestName = N'[Label] Status 1 with the log id', @Expected = N'1|4 super-lot labels sent.|id', @Actual = @n;
SET @n = (SELECT CAST(COUNT(*) AS NVARCHAR(5)) + N'|' + CAST(MAX(Copies) AS NVARCHAR(5)) + N'|' + MAX(PrinterName) FROM Quality.ControlledRunLabel WHERE ControlledRunId = @Run);
EXEC test.Assert_IsEqual @TestName = N'[Label] one log row per request, Copies = 4, printer recorded', @Expected = N'1|4|QA-ZEBRA', @Actual = @n;
SET @n = CASE WHEN @Zpl LIKE N'^XA%^PQ4^XZ' THEN N'ok' ELSE RIGHT(@Zpl, 30) END;
EXEC test.Assert_IsEqual @TestName = N'[Label] one ZPL document ending ^PQ4^XZ (four copies)', @Expected = N'ok', @Actual = @n;
SET @n = CAST((LEN(@Zpl) - LEN(REPLACE(@Zpl, N'CR000001', N''))) / 8 AS NVARCHAR(5));
EXEC test.Assert_IsEqual @TestName = N'[Label] run number appears twice: large text and barcode', @Expected = N'2', @Actual = @n;
SET @n = CASE WHEN @Zpl LIKE N'%^BCN%^FDCR000001^FS%' THEN N'ok' ELSE N'no barcode of the run number' END;
EXEC test.Assert_IsEqual @TestName = N'[Label] the barcode encodes the run number and nothing else', @Expected = N'ok', @Actual = @n;
SET @n = CASE WHEN CHARINDEX(N'^FD' + @PartNo + N'^FS', @Zpl) > 0 AND @Zpl LIKE N'%^FDporosity at bore^FS%' AND @Zpl LIKE N'%^FDOpened 20__-__-__ __:__ by SYS^FS%' THEN N'ok' ELSE @Zpl END;
EXEC test.Assert_IsEqual @TestName = N'[Label] part, reason and the opened line (Eastern, initials)', @Expected = N'ok', @Actual = @n;
SET @n = CASE WHEN @Zpl LIKE N'%{%' OR @Zpl LIKE N'%}%' THEN N'token left behind' ELSE N'clean' END;
EXEC test.Assert_IsEqual @TestName = N'[Label] no unsubstituted token', @Expected = N'clean', @Actual = @n;
SET @n = (SELECT TOP 1 CASE WHEN ol.Description LIKE N'CR000001 % Label % Printed (4)' THEN N'ok' ELSE ol.Description END
          FROM Audit.OperationLog ol JOIN Audit.LogEventType t ON t.Id = ol.LogEventTypeId
          WHERE t.Code = N'ControlledRunLabelPrinted' AND ol.EntityId = @Run);
EXEC test.Assert_IsEqual @TestName = N'[Label] audit line', @Expected = N'ok', @Actual = @n;

-- ===== a super-lot with no part =====
DELETE FROM @o; DELETE FROM @L;
SET @j = (SELECT @LotB AS lotId FOR JSON PATH);
INSERT INTO @o EXEC Quality.ControlledRun_Open @Reason = N'hand picked', @MembersJson = @j, @AppUserId = @App;
DECLARE @Run2 BIGINT = (SELECT NewId FROM @o);
INSERT INTO @L EXEC Quality.ControlledRunLabel_Print @Id = @Run2, @AppUserId = @App;
SET @Zpl = (SELECT ZplContent FROM @L);
SET @n = CASE WHEN @Zpl LIKE N'%^FO40,406^A0N,36,36^FD^FS%' AND @Zpl NOT LIKE N'%{%' THEN N'blank' ELSE @Zpl END;
EXEC test.Assert_IsEqual @TestName = N'[Label] no part -> a blank part field, not a leftover token', @Expected = N'blank', @Actual = @n;

-- ===== hostile / awkward reason text =====
DELETE FROM @o; DELETE FROM @L;
SET @j = (SELECT @LotC AS lotId FOR JSON PATH);
DECLARE @Nasty NVARCHAR(500) = N'bore ^XZ~JA crack ' + NCHAR(8212) + N' {Copies} line 2 ' + REPLICATE(N'x', 300);
INSERT INTO @o EXEC Quality.ControlledRun_Open @Reason = @Nasty, @MembersJson = @j, @AppUserId = @App;
DECLARE @Run3 BIGINT = (SELECT NewId FROM @o);
INSERT INTO @L EXEC Quality.ControlledRunLabel_Print @Id = @Run3, @AppUserId = @App;
SET @Zpl = (SELECT ZplContent FROM @L);
SET @n = CAST((LEN(@Zpl) - LEN(REPLACE(@Zpl, N'^XZ', N''))) / 3 AS NVARCHAR(5)) + N'|' + CASE WHEN @Zpl LIKE N'%^PQ4^XZ' THEN N'at the end' ELSE N'elsewhere' END;
EXEC test.Assert_IsEqual @TestName = N'[Label] a ^XZ typed into the reason cannot end the label early', @Expected = N'1|at the end', @Actual = @n;
SET @n = CASE WHEN CHARINDEX(N'~', @Zpl) > 0 THEN N'tilde survived' ELSE N'none' END;
EXEC test.Assert_IsEqual @TestName = N'[Label] no ~ (printer command prefix) survives', @Expected = N'none', @Actual = @n;
SET @n = CAST(PATINDEX(N'%[^ -~]%' COLLATE Latin1_General_BIN2, @Zpl) AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[Label] nothing outside printable ASCII (the em-dash became ?)', @Expected = N'0', @Actual = @n;
SET @n = CASE WHEN @Zpl LIKE N'%crack ? (Copies) line 2%' THEN N'ok' ELSE @Zpl END;
EXEC test.Assert_IsEqual @TestName = N'[Label] a token typed into the reason is not substituted', @Expected = N'ok', @Actual = @n;
DECLARE @a INT = CHARINDEX(N'^FDbore', @Zpl);
DECLARE @z INT = CHARINDEX(N'^FS', @Zpl, @a);
SET @n = CAST(@z - @a - 3 AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[Label] a long reason is cut to 110 characters', @Expected = N'110', @Actual = @n;

-- ===== rejections =====
DELETE FROM @L;
INSERT INTO @L EXEC Quality.ControlledRunLabel_Print @Id = 999999999, @AppUserId = @App;
SET @n = (SELECT CAST(Status AS NVARCHAR(1)) + N'|' + Message + N'|' + ISNULL(ZplContent, N'(null)') FROM @L);
EXEC test.Assert_IsEqual @TestName = N'[Label] unknown super-lot', @Expected = N'0|Super-lot not found.|(null)', @Actual = @n;

DECLARE @Tpl BIGINT = (SELECT t.Id FROM Lots.LabelTemplate t JOIN Lots.LabelTypeCode c ON c.Id = t.LabelTypeCodeId WHERE c.Code = N'ControlledRun' AND t.DeprecatedAt IS NULL);
UPDATE Lots.LabelTemplate SET DeprecatedAt = SYSUTCDATETIME() WHERE Id = @Tpl;
DELETE FROM @L;
INSERT INTO @L EXEC Quality.ControlledRunLabel_Print @Id = @Run, @AppUserId = @App;
UPDATE Lots.LabelTemplate SET DeprecatedAt = NULL WHERE Id = @Tpl;
SET @n = (SELECT CAST(Status AS NVARCHAR(1)) + N'|' + Message FROM @L);
EXEC test.Assert_IsEqual @TestName = N'[Label] no active template', @Expected = N'0|No active super-lot label template.', @Actual = @n;
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
