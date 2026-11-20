-- =============================================
-- File: 0136_PackOut/040_terminal_select.sql
-- Desc: Location.Terminal_SetPackOut -- the station's pick; refused while the
--       box the next tray would go into is open (D2); upserts one row per
--       (terminal, part, method); audited.
--       Uses the TST-PO-* fixture from 020_resolve.sql.
-- =============================================
SET NOCOUNT ON;
EXEC test.BeginTestFile @FileName = N'0136_PackOut/040_terminal_select.sql';
GO
CREATE TABLE #S (Status BIT, Message NVARCHAR(500));
GO

DECLARE @Item BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'TST-PO-FG');
DECLARE @T1 BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'TST-PO-T1');
DECLARE @Line BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'TST-PO-LINE');
DECLARE @Card BIGINT = (SELECT Id FROM Parts.PackOut WHERE ItemId = @Item AND Name = N'Cardboard' AND DeprecatedAt IS NULL);
DECLARE @Tote BIGINT = (SELECT Id FROM Parts.PackOut WHERE ItemId = @Item AND Name = N'Tote' AND DeprecatedAt IS NULL);
DECLARE @S NVARCHAR(500);
DELETE FROM Location.TerminalPackOutSelection WHERE TerminalLocationId = @T1;
DELETE FROM Lots.Container WHERE ItemId = @Item;

DELETE FROM #S; INSERT INTO #S EXEC Location.Terminal_SetPackOut @TerminalLocationId = @T1, @PackOutId = @Tote, @AppUserId = 1;
SET @S = (SELECT CONCAT((SELECT Status FROM #S), N'|',
          (SELECT COUNT(*) FROM Location.TerminalPackOutSelection WHERE TerminalLocationId = @T1 AND ItemId = @Item AND PackOutId = @Tote)));
EXEC test.Assert_IsEqual @TestName = N'[Select] pick set', @Expected = N'1|1', @Actual = @S;

DELETE FROM #S; INSERT INTO #S EXEC Location.Terminal_SetPackOut @TerminalLocationId = @T1, @PackOutId = @Tote, @AppUserId = 1;
SET @S = (SELECT CAST(Status AS NVARCHAR(1)) FROM #S);
EXEC test.Assert_IsEqual @TestName = N'[Select] same pick again refused (no-op)', @Expected = N'0', @Actual = @S;

-- A third pack-out: switching between non-defaults updates the one row.
INSERT INTO Parts.PackOut (ItemId, ClosureMethod, Name, IsDefault, CreatedByUserId) VALUES (@Item, N'ByWeight', N'Crate', 0, 1);
DECLARE @Crate BIGINT = SCOPE_IDENTITY();
INSERT INTO Parts.ContainerConfig (ItemId, ClosureMethod, PackOutId, VersionNumber, TraysPerContainer, PartsPerTray, IsSerialized, TargetWeight, ToleranceWeight)
VALUES (@Item, N'ByWeight', @Crate, 1, 2, 5, 0, 30.0, 1.0);
DELETE FROM #S; INSERT INTO #S EXEC Location.Terminal_SetPackOut @TerminalLocationId = @T1, @PackOutId = @Crate, @AppUserId = 1;
SET @S = (SELECT CONCAT((SELECT Status FROM #S), N'|',
          (SELECT COUNT(*) FROM Location.TerminalPackOutSelection WHERE TerminalLocationId = @T1 AND ItemId = @Item), N'|',
          (SELECT PackOutId - @Crate FROM Location.TerminalPackOutSelection WHERE TerminalLocationId = @T1 AND ItemId = @Item)));
EXEC test.Assert_IsEqual @TestName = N'[Select] switch updates the one row', @Expected = N'1|1|0', @Actual = @S;

-- Tapping the DEFAULT clears the pick: the terminal follows whatever the default is (Jacques, 2026-11-20).
DELETE FROM #S; INSERT INTO #S EXEC Location.Terminal_SetPackOut @TerminalLocationId = @T1, @PackOutId = @Card, @AppUserId = 1;
SET @S = (SELECT CONCAT((SELECT Status FROM #S), N'|',
          (SELECT COUNT(*) FROM Location.TerminalPackOutSelection WHERE TerminalLocationId = @T1 AND ItemId = @Item), N'|',
          (SELECT Source FROM Parts.ufn_ResolvePackOut(@Item, N'ByWeight', @T1))));
EXEC test.Assert_IsEqual @TestName = N'[Select] tapping the default clears the pick (follows the default)', @Expected = N'1|0|Default', @Actual = @S;

UPDATE Parts.PackOut SET IsDefault = 0 WHERE Id = @Card;
UPDATE Parts.PackOut SET IsDefault = 1 WHERE Id = @Crate;
SET @S = (SELECT PackOutName FROM Parts.ufn_ResolvePackOut(@Item, N'ByWeight', @T1));
EXEC test.Assert_IsEqual @TestName = N'[Select] a later default change is followed', @Expected = N'Crate', @Actual = @S;
UPDATE Parts.PackOut SET IsDefault = 0 WHERE Id = @Crate;
UPDATE Parts.PackOut SET IsDefault = 1 WHERE Id = @Card;

DELETE FROM #S; INSERT INTO #S EXEC Location.Terminal_SetPackOut @TerminalLocationId = @T1, @PackOutId = @Card, @AppUserId = 1;
SET @S = (SELECT CAST(Status AS NVARCHAR(1)) FROM #S);
EXEC test.Assert_IsEqual @TestName = N'[Select] tapping the default with no pick is a no-op (refused)', @Expected = N'0', @Actual = @S;

DECLARE @Aud NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM Audit.OperationLog ol
    JOIN Audit.LogEventType ev ON ev.Id = ol.LogEventTypeId AND ev.Code = N'PackOutSelected'
    WHERE ol.TerminalLocationId = @T1);
EXEC test.Assert_IsEqual @TestName = N'[Select] each switch audited', @Expected = N'3', @Actual = @Aud;
DELETE FROM Parts.ContainerConfig WHERE PackOutId = @Crate;
DELETE FROM Parts.PackOut WHERE Id = @Crate;

-- D2: an own open box blocks the switch.
DECLARE @CardCfg BIGINT = (SELECT Id FROM Parts.ContainerConfig WHERE PackOutId = @Card AND DeprecatedAt IS NULL);
INSERT INTO Lots.Container (ItemId, ContainerConfigId, CurrentLocationId, ContainerStatusCodeId, CreatedByUserId, StationLocationId)
VALUES (@Item, @CardCfg, @Line, 1, 1, @T1);
DECLARE @Box BIGINT = SCOPE_IDENTITY();
DELETE FROM #S; INSERT INTO #S EXEC Location.Terminal_SetPackOut @TerminalLocationId = @T1, @PackOutId = @Tote, @AppUserId = 1;
SET @S = (SELECT CONCAT(Status, N'|', CASE WHEN Message LIKE N'Box #' + CAST(@Box AS NVARCHAR(20)) + N' is open%' THEN N'box' ELSE Message END) FROM #S);
EXEC test.Assert_IsEqual @TestName = N'[Select] refused while own box is open', @Expected = N'0|box', @Actual = @S;

-- ...and so does an unowned open box at the line (the one the next tray would claim).
UPDATE Lots.Container SET StationLocationId = NULL WHERE Id = @Box;
DELETE FROM #S; INSERT INTO #S EXEC Location.Terminal_SetPackOut @TerminalLocationId = @T1, @PackOutId = @Tote, @AppUserId = 1;
SET @S = (SELECT CAST(Status AS NVARCHAR(1)) FROM #S);
EXEC test.Assert_IsEqual @TestName = N'[Select] refused while an unowned box at the line is open', @Expected = N'0', @Actual = @S;
DELETE FROM Lots.Container WHERE Id = @Box;

-- A removed pack-out cannot be picked; a non-terminal location cannot pick.
UPDATE Parts.PackOut SET DeprecatedAt = SYSUTCDATETIME() WHERE Id = @Tote;
DELETE FROM #S; INSERT INTO #S EXEC Location.Terminal_SetPackOut @TerminalLocationId = @T1, @PackOutId = @Tote, @AppUserId = 1;
SET @S = (SELECT CAST(Status AS NVARCHAR(1)) FROM #S);
EXEC test.Assert_IsEqual @TestName = N'[Select] removed pack-out refused', @Expected = N'0', @Actual = @S;
UPDATE Parts.PackOut SET DeprecatedAt = NULL WHERE Id = @Tote;

DELETE FROM #S; INSERT INTO #S EXEC Location.Terminal_SetPackOut @TerminalLocationId = @Line, @PackOutId = @Tote, @AppUserId = 1;
SET @S = (SELECT CAST(Status AS NVARCHAR(1)) FROM #S);
EXEC test.Assert_IsEqual @TestName = N'[Select] non-terminal location refused', @Expected = N'0', @Actual = @S;

DELETE FROM Location.TerminalPackOutSelection WHERE TerminalLocationId = @T1;
GO
DROP TABLE #S;
GO
EXEC test.EndTestFile;
GO
