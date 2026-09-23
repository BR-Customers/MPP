-- =============================================
-- Fixture for sql/tests/0097_DieCast_Reconciliation/*.
-- Deployed by Run-Tests.ps1 step 2 (helpers). Self-contained: builds its own
-- die, cavities, mount and shifts in January 2020 so no other suite's shifts,
-- mounts or LOTs can interleave with it. The mount is CLOSED (ReleasedAt set)
-- because UQ_ToolAssignment_ActiveCell allows one live die per press.
-- =============================================
CREATE OR ALTER FUNCTION test.ufn_RC (@Key NVARCHAR(20))
RETURNS BIGINT
AS
BEGIN
    RETURN CASE @Key
        WHEN N'Tool'  THEN (SELECT Id FROM Tools.Tool WHERE Code = N'RC-DIE')
        WHEN N'CavA'  THEN (SELECT tc.Id FROM Tools.ToolCavity tc JOIN Tools.Tool t ON t.Id = tc.ToolId WHERE t.Code = N'RC-DIE' AND tc.CavityCode = N'a')
        WHEN N'CavB'  THEN (SELECT tc.Id FROM Tools.ToolCavity tc JOIN Tools.Tool t ON t.Id = tc.ToolId WHERE t.Code = N'RC-DIE' AND tc.CavityCode = N'b')
        WHEN N'ItemA' THEN (SELECT tc.ItemId FROM Tools.ToolCavity tc JOIN Tools.Tool t ON t.Id = tc.ToolId WHERE t.Code = N'RC-DIE' AND tc.CavityCode = N'a')
        WHEN N'ItemB' THEN (SELECT tc.ItemId FROM Tools.ToolCavity tc JOIN Tools.Tool t ON t.Id = tc.ToolId WHERE t.Code = N'RC-DIE' AND tc.CavityCode = N'b')
        WHEN N'Cell'  THEN (SELECT TOP 1 ta.CellLocationId FROM Tools.ToolAssignment ta JOIN Tools.Tool t ON t.Id = ta.ToolId WHERE t.Code = N'RC-DIE')
        WHEN N'Usr'   THEN (SELECT TOP 1 Id FROM Location.AppUser ORDER BY Id)
        WHEN N'Usr2'  THEN (SELECT TOP 1 Id FROM Location.AppUser WHERE Id > (SELECT MIN(Id) FROM Location.AppUser) ORDER BY Id)
        WHEN N'Whse'  THEN (SELECT TOP 1 Id FROM Location.Location WHERE Code = N'WHSE' AND DeprecatedAt IS NULL ORDER BY Id)
        WHEN N'S1'    THEN (SELECT Id FROM (SELECT Id, ROW_NUMBER() OVER (ORDER BY ActualStart) AS rn FROM Oee.Shift WHERE Remarks = N'RC-FIXTURE') x WHERE rn = 1)
        WHEN N'S2'    THEN (SELECT Id FROM (SELECT Id, ROW_NUMBER() OVER (ORDER BY ActualStart) AS rn FROM Oee.Shift WHERE Remarks = N'RC-FIXTURE') x WHERE rn = 2)
        WHEN N'S3'    THEN (SELECT Id FROM (SELECT Id, ROW_NUMBER() OVER (ORDER BY ActualStart) AS rn FROM Oee.Shift WHERE Remarks = N'RC-FIXTURE') x WHERE rn = 3)
        WHEN N'S4'    THEN (SELECT Id FROM (SELECT Id, ROW_NUMBER() OVER (ORDER BY ActualStart) AS rn FROM Oee.Shift WHERE Remarks = N'RC-FIXTURE') x WHERE rn = 4)
        WHEN N'S5'    THEN (SELECT Id FROM (SELECT Id, ROW_NUMBER() OVER (ORDER BY ActualStart) AS rn FROM Oee.Shift WHERE Remarks = N'RC-FIXTURE') x WHERE rn = 5)
    END;
END;
GO

-- NAMING CONVENTION, load-bearing: Cleanup only removes LOTs matching
--   ToolId = RC-DIE  OR  LotName LIKE N'99700%'
-- A LOT seeded by DieCastRecon_SeedLot always carries the tool, so it is covered.
-- A LOT a test creates ANY OTHER WAY -- in particular one minted through a live
-- procedure such as Lots.DieCastLot_Mint, which does not take RC-DIE -- is only
-- covered if it is NAMED with the 99700 prefix. Miss that and the row survives
-- teardown and pollutes every suite that runs after it.
CREATE OR ALTER PROCEDURE test.DieCastRecon_Cleanup
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @Tool BIGINT = (SELECT Id FROM Tools.Tool WHERE Code = N'RC-DIE');
    DECLARE @Lots TABLE (Id BIGINT PRIMARY KEY);
    INSERT INTO @Lots (Id) SELECT Id FROM Lots.Lot WHERE ToolId = @Tool OR LotName LIKE N'99700%';

    DELETE m FROM Workorder.DieCastReconciliationMove m
      JOIN Workorder.DieCastShiftReconciliation h ON h.Id = m.ReconciliationId WHERE h.ToolId = @Tool;
    DELETE FROM Workorder.DieCastCounterAnchor WHERE ToolId = @Tool;
    DELETE FROM Workorder.DieCastContribution  WHERE LotId IN (SELECT Id FROM @Lots);
    DELETE FROM Workorder.RejectEvent          WHERE ToolId = @Tool OR LotId IN (SELECT Id FROM @Lots);
    DELETE FROM Workorder.ProductionEvent      WHERE LotId IN (SELECT Id FROM @Lots);
    DELETE FROM Workorder.DieCastShiftReconciliation WHERE ToolId = @Tool;
    DELETE FROM Lots.LotGenealogyClosure WHERE AncestorLotId IN (SELECT Id FROM @Lots) OR DescendantLotId IN (SELECT Id FROM @Lots);
    DELETE FROM Lots.LotGenealogy        WHERE ParentLotId  IN (SELECT Id FROM @Lots) OR ChildLotId      IN (SELECT Id FROM @Lots);
    DELETE FROM Lots.LotAttributeChange  WHERE LotId IN (SELECT Id FROM @Lots);
    DELETE FROM Lots.LotEventLog         WHERE LotId IN (SELECT Id FROM @Lots);
    DELETE FROM Lots.LotLabel            WHERE LotId IN (SELECT Id FROM @Lots) OR ParentLotId IN (SELECT Id FROM @Lots);
    DELETE FROM Lots.LotMovement         WHERE LotId IN (SELECT Id FROM @Lots);
    DELETE FROM Lots.LotStatusHistory    WHERE LotId IN (SELECT Id FROM @Lots);
    DELETE FROM Lots.PauseEvent          WHERE LotId IN (SELECT Id FROM @Lots);
    DELETE FROM Lots.Lot                 WHERE Id IN (SELECT Id FROM @Lots);
    DELETE FROM Tools.ToolCavity     WHERE ToolId = @Tool;
    DELETE FROM Tools.ToolAssignment WHERE ToolId = @Tool;
    DELETE FROM Tools.Tool           WHERE Id = @Tool;
    DELETE FROM Oee.Shift         WHERE Remarks = N'RC-FIXTURE';
    DELETE FROM Oee.ShiftSchedule WHERE Name = N'RC-FIXTURE-SCHED';
END;
GO

CREATE OR ALTER PROCEDURE test.DieCastRecon_Setup
AS
BEGIN
    SET NOCOUNT ON;
    EXEC test.DieCastRecon_Cleanup;

    DECLARE @Usr   BIGINT = (SELECT TOP 1 Id FROM Location.AppUser ORDER BY Id);
    DECLARE @Cell  BIGINT = (SELECT TOP 1 l.Id FROM Location.Location l
                             JOIN Location.LocationTypeDefinition d ON d.Id = l.LocationTypeDefinitionId
                             WHERE d.Code = N'DieCastMachine' AND l.DeprecatedAt IS NULL ORDER BY l.Id);
    DECLARE @ItemA BIGINT = (SELECT TOP 1 Id FROM Parts.Item WHERE DeprecatedAt IS NULL ORDER BY Id);
    DECLARE @ItemB BIGINT = (SELECT TOP 1 Id FROM Parts.Item WHERE DeprecatedAt IS NULL AND Id > @ItemA ORDER BY Id);

    INSERT INTO Oee.ShiftSchedule (Name, StartTime, EndTime, DaysOfWeekBitmask, EffectiveFrom, CreatedByUserId, DeprecatedAt)
    VALUES (N'RC-FIXTURE-SCHED', '07:00:00', '15:00:00', 127, '2020-01-01', @Usr, '2020-01-01');
    DECLARE @Sched BIGINT = SCOPE_IDENTITY();

    -- Eastern wall clock (OI-38). Deprecated schedule: the shift RESOLVER
    -- (Oee.ufn_ShiftIdForInstant) must not start using it for other suites.
    INSERT INTO Oee.Shift (ShiftScheduleId, ActualStart, ActualEnd, Remarks) VALUES
        (@Sched, '2020-01-06T07:00:00', '2020-01-06T15:00:00', N'RC-FIXTURE'),
        (@Sched, '2020-01-06T15:00:00', '2020-01-06T23:00:00', N'RC-FIXTURE'),
        (@Sched, '2020-01-06T23:00:00', '2020-01-07T07:00:00', N'RC-FIXTURE'),
        (@Sched, '2020-01-07T07:00:00', '2020-01-07T15:00:00', N'RC-FIXTURE'),
        (@Sched, '2020-01-07T15:00:00', '2020-01-07T23:00:00', N'RC-FIXTURE');

    INSERT INTO Tools.Tool (Code, Name, ToolTypeId, StatusCodeId, CreatedByUserId, ShotCount)
    VALUES (N'RC-DIE', N'Reconciliation Test Die',
            (SELECT TOP 1 Id FROM Tools.ToolType ORDER BY Id),
            (SELECT Id FROM Tools.ToolStatusCode WHERE Code = N'Active'), @Usr, 10000);
    DECLARE @Tool BIGINT = SCOPE_IDENTITY();

    DECLARE @Active BIGINT = (SELECT Id FROM Tools.ToolCavityStatusCode WHERE Code = N'Active');
    INSERT INTO Tools.ToolCavity (ToolId, CavityCode, StatusCodeId, Description, ItemId, CreatedByUserId)
    VALUES (@Tool, N'a', @Active, N'RC cavity a', @ItemA, @Usr),
           (@Tool, N'b', @Active, N'RC cavity b', @ItemB, @Usr);

    INSERT INTO Tools.ToolAssignment (ToolId, CellLocationId, AssignedAt, ReleasedAt, AssignedByUserId, ReleasedByUserId)
    VALUES (@Tool, @Cell, '2020-01-01T00:00:00', '2020-02-01T00:00:00', @Usr, @Usr);
END;
GO

-- A die cast LOT on the fixture die, inserted directly (the live Open proc
-- requires the die to be mounted NOW). 'Good' also writes the Open->Good
-- history row that Lots.ufn_DieCastLotCountLock reads as "released".
CREATE OR ALTER PROCEDURE test.DieCastRecon_SeedLot
    @Ltt NVARCHAR(50), @CavKey NVARCHAR(10), @StatusCode NVARCHAR(20) = N'Open'
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @Cav BIGINT = test.ufn_RC(@CavKey);
    DECLARE @Usr BIGINT = test.ufn_RC(N'Usr');
    DECLARE @Loc BIGINT = CASE WHEN @StatusCode = N'Open' THEN test.ufn_RC(N'Cell') ELSE test.ufn_RC(N'Whse') END;
    INSERT INTO Lots.Lot (LotName, ItemId, LotOriginTypeId, LotStatusId, PieceCount, InventoryAvailable,
                          CurrentLocationId, ToolId, ToolCavityId, CreatedAt, CreatedByUserId)
    SELECT @Ltt, tc.ItemId, (SELECT Id FROM Lots.LotOriginType WHERE Code = N'Manufactured'),
           (SELECT Id FROM Lots.LotStatusCode WHERE Code = @StatusCode), 0, 0, @Loc, tc.ToolId, tc.Id,
           '2020-01-06T12:00:00', @Usr
    FROM Tools.ToolCavity tc WHERE tc.Id = @Cav;
    IF @StatusCode <> N'Open'
        INSERT INTO Lots.LotStatusHistory (LotId, OldStatusId, NewStatusId, Reason, ChangedByUserId, ChangedAt)
        SELECT l.Id, (SELECT Id FROM Lots.LotStatusCode WHERE Code = N'Open'), l.LotStatusId, N'fixture release', @Usr, '2020-01-06T13:00:00'
        FROM Lots.Lot l WHERE l.LotName = @Ltt;
END;
GO

-- A live-style credit: the contribution row plus the LOT count, as
-- DieCastShiftOutput_Record would have written it at @AtUtc.
CREATE OR ALTER PROCEDURE test.DieCastRecon_SeedCredit
    @Ltt NVARCHAR(50), @ShiftKey NVARCHAR(10), @Pieces INT, @Reading INT = NULL,
    @AtUtc DATETIME2(3), @UserId BIGINT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @Lot BIGINT = (SELECT Id FROM Lots.Lot WHERE LotName = @Ltt);
    INSERT INTO Workorder.DieCastContribution (LotId, ShiftId, PieceDelta, AppUserId, EventAt, CellLocationId, ShotCounterReading, ToolCavityId)
    SELECT @Lot, test.ufn_RC(@ShiftKey), @Pieces, ISNULL(@UserId, test.ufn_RC(N'Usr')), @AtUtc,
           test.ufn_RC(N'Cell'), @Reading, l.ToolCavityId
    FROM Lots.Lot l WHERE l.Id = @Lot;
    UPDATE Lots.Lot SET PieceCount = PieceCount + @Pieces, InventoryAvailable = InventoryAvailable + @Pieces WHERE Id = @Lot;
END;
GO

-- A live-style scrap row against a cavity (no LOT), as the die-wide fan-out writes it.
CREATE OR ALTER PROCEDURE test.DieCastRecon_SeedReject
    @ShiftKey NVARCHAR(10), @CavKey NVARCHAR(10), @DefectCode NVARCHAR(20), @Qty INT,
    @AtUtc DATETIME2(3), @UserId BIGINT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    INSERT INTO Workorder.RejectEvent (ProductionEventId, LotId, ItemId, ToolId, ToolCavityId, ShiftId, CellLocationId,
                                       DefectCodeId, Quantity, ChargeToArea, Remarks, AppUserId, TerminalLocationId, RecordedAt)
    SELECT NULL, NULL, tc.ItemId, tc.ToolId, tc.Id, test.ufn_RC(@ShiftKey), test.ufn_RC(N'Cell'),
           (SELECT Id FROM Quality.DefectCode WHERE Code = @DefectCode), @Qty, NULL, N'fixture',
           ISNULL(@UserId, test.ufn_RC(N'Usr')), NULL, @AtUtc
    FROM Tools.ToolCavity tc WHERE tc.Id = test.ufn_RC(@CavKey);
END;
GO
