-- DEV ONLY. Walkthrough fixture for the super-lot Results / Sign-off tabs: four LOTs and one completed container (WALK-CR-*),
-- one open super-lot, a few results. Remove with 2026-10-13_super_lot_walkthrough_cleanup.sql. Never run on prod.
SET NOCOUNT ON;
DECLARE @App  BIGINT = (SELECT TOP 1 Id FROM Location.AppUser WHERE Initials = N'SYS');
DECLARE @Item BIGINT = (SELECT TOP 1 Id FROM Parts.Item WHERE DeprecatedAt IS NULL ORDER BY Id);
DECLARE @Term BIGINT = (SELECT TOP 1 l.Id FROM Location.Location l
    JOIN Location.LocationTypeDefinition d ON d.Id = l.LocationTypeDefinitionId
    WHERE d.Code = N'Terminal' AND l.DeprecatedAt IS NULL AND l.ParentLocationId IS NOT NULL ORDER BY l.Id);
DECLARE @Line BIGINT = (SELECT ParentLocationId FROM Location.Location WHERE Id = @Term);
DECLARE @Cfg BIGINT = ISNULL((SELECT TOP 1 Id FROM Parts.ContainerConfig WHERE ItemId = @Item), (SELECT TOP 1 Id FROM Parts.ContainerConfig));
DECLARE @Def BIGINT = (SELECT TOP 1 Id FROM Quality.DefectCode WHERE DeprecatedAt IS NULL ORDER BY Id);
IF EXISTS (SELECT 1 FROM Lots.Lot WHERE LotName LIKE N'WALK-CR-%') BEGIN PRINT 'already seeded'; RETURN; END

DECLARE @Ids TABLE (Name NVARCHAR(50) PRIMARY KEY, Id BIGINT);
INSERT INTO Lots.Lot (LotName, ItemId, LotOriginTypeId, LotStatusId, PieceCount, InventoryAvailable, CurrentLocationId, CreatedByUserId, CreatedAtTerminalId, CrtActive)
OUTPUT inserted.LotName, inserted.Id INTO @Ids (Name, Id)
VALUES (N'WALK-CR-1', @Item, 1, 1, 120, 120, @Line, @App, @Term, 0),
       (N'WALK-CR-2', @Item, 1, 1, 96,  96,  @Line, @App, @Term, 0),
       (N'WALK-CR-3', @Item, 1, 1, 110, 110, @Line, @App, @Term, 0),
       (N'WALK-CR-4', @Item, 1, 1, 60,  60,  @Line, @App, @Term, 0),
       (N'WALK-CR-T', @Item, 1, 4, 144, 0,   @Line, @App, @Term, 0);
INSERT INTO Lots.Container (ItemId, ContainerConfigId, CurrentLocationId, ContainerStatusCodeId, CompletedAt, CreatedByUserId)
VALUES (@Item, @Cfg, @Line, 2, SYSUTCDATETIME(), @App);
DECLARE @Con BIGINT = SCOPE_IDENTITY();
INSERT INTO Lots.ContainerTray (ContainerId, TrayPosition, FinishedGoodLotId) SELECT @Con, 1, Id FROM @Ids WHERE Name = N'WALK-CR-T';

DECLARE @o TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
DECLARE @j NVARCHAR(MAX) = (SELECT * FROM (SELECT Id AS lotId, CAST(NULL AS BIGINT) AS containerId FROM @Ids WHERE Name <> N'WALK-CR-T'
                                           UNION ALL SELECT NULL, @Con) x FOR JSON PATH);
INSERT INTO @o EXEC Quality.ControlledRun_Open @Reason = N'WALKTHROUGH - porosity at bore (test data, safe to delete)',
    @SelectionLocationId = @Line, @MembersJson = @j, @AppUserId = @App, @TerminalLocationId = @Term;
DECLARE @Run BIGINT = (SELECT NewId FROM @o);
DECLARE @M1 BIGINT = (SELECT m.Id FROM Quality.ControlledRunMember m JOIN @Ids i ON i.Id = m.LotId WHERE i.Name = N'WALK-CR-1');
DECLARE @M2 BIGINT = (SELECT m.Id FROM Quality.ControlledRunMember m JOIN @Ids i ON i.Id = m.LotId WHERE i.Name = N'WALK-CR-2');
DELETE FROM @o;
SET @j = (SELECT * FROM (VALUES (@M1, N'Accepted', 117, CAST(NULL AS BIGINT)), (@M1, N'Scrap', 3, @Def),
                                (@M2, N'Accepted', 90, NULL), (@M2, N'UseAsIs', 6, NULL)) v(memberId, dispositionCode, quantity, defectCodeId) FOR JSON PATH);
INSERT INTO @o EXEC Quality.ControlledRunResult_Record @ControlledRunId = @Run, @ResultsJson = @j, @AppUserId = @App, @TerminalLocationId = @Term;
SELECT * FROM @o;
SELECT @Run AS RunId;
