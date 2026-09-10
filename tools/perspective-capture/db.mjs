import { execFileSync } from 'node:child_process';

export function sql(q, { db = 'MPP_MES_Dev' } = {}) {
  const out = execFileSync('sqlcmd',
    ['-S', 'localhost', '-d', db, '-C', '-W', '-I', '-b', '-Q', 'SET NOCOUNT ON;\n' + q],
    { encoding: 'utf8', maxBuffer: 8 * 1024 * 1024 });
  return out.trim();
}

/** One value back. */
export function scalar(q, opts) {
  const lines = sql(q, opts).split('\n').map((l) => l.trim()).filter(Boolean);
  return lines[lines.length - 1];
}

/** Open a basket on a cavity, then release it at `reading` -- the same two
 *  procs the Open Basket tab and the Release dialog call. Used to fast-forward
 *  the repetitive middle of a scenario; every step we actually SHOW is driven
 *  through the UI instead. */
export function openBasket({ die, cavity, ltt, item, machine }) {
  return sql(`
DECLARE @U BIGINT=(SELECT Id FROM Location.AppUser WHERE Pin=N'00002');
DECLARE @T BIGINT=(SELECT Id FROM Tools.Tool WHERE Code=N'${die}');
DECLARE @C BIGINT=(SELECT Id FROM Tools.ToolCavity WHERE ToolId=@T AND CavityNumber=${cavity});
DECLARE @I BIGINT=(SELECT Id FROM Parts.Item WHERE PartNumber=N'${item}');
DECLARE @M BIGINT=(SELECT Id FROM Location.Location WHERE Code=N'${machine}');
DECLARE @R TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO @R EXEC Lots.DieCastLot_Open @ItemId=@I,@CurrentLocationId=@M,@ToolId=@T,
  @ToolCavityId=@C,@LotName=N'${ltt}',@AppUserId=@U,@TerminalLocationId=NULL;
SELECT Message FROM @R;`);
}

export function releaseBasket({ die, cavity, reading, machine }) {
  return sql(`
DECLARE @U BIGINT=(SELECT Id FROM Location.AppUser WHERE Pin=N'00002');
DECLARE @T BIGINT=(SELECT Id FROM Tools.Tool WHERE Code=N'${die}');
DECLARE @C BIGINT=(SELECT Id FROM Tools.ToolCavity WHERE ToolId=@T AND CavityNumber=${cavity});
DECLARE @M BIGINT=(SELECT Id FROM Location.Location WHERE Code=N'${machine}');
DECLARE @S BIGINT=(SELECT TOP 1 Id FROM Oee.Shift WHERE ActualEnd IS NULL ORDER BY Id DESC);
DECLARE @L BIGINT=(SELECT l.Id FROM Lots.Lot l JOIN Lots.LotStatusCode s ON s.Id=l.LotStatusId
                   WHERE s.Code=N'Open' AND l.ToolCavityId=@C);
DECLARE @R TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO @R EXEC Lots.DieCastLot_Release @LotId=@L,@StorageLocationId=NULL,@FinalPieceDelta=NULL,
  @CounterReading=${reading},@ShiftId=@S,@AppUserId=@U,@TerminalLocationId=NULL,@CellLocationId=@M;
SELECT Message FROM @R;`);
}

/** Per-cavity state of a die, for the review book's data tables. */
export function dieState(die) {
  return sql(`
DECLARE @T BIGINT=(SELECT Id FROM Tools.Tool WHERE Code=N'${die}');
DECLARE @S BIGINT=(SELECT TOP 1 Id FROM Oee.Shift WHERE ActualEnd IS NULL ORDER BY Id DESC);
DECLARE @M BIGINT=(SELECT TOP 1 CellLocationId FROM Tools.ToolAssignment WHERE ToolId=@T AND ReleasedAt IS NULL);
SELECT tc.CavityNumber AS Cav, tc.Description AS Name,
       ISNULL(l.LotName,'-') AS Basket, ISNULL(l.PieceCount,0) AS Pc,
       ISNULL(sc.Code,'-') AS Status,
       Workorder.ufn_CavityShotWatermark(tc.Id,@S,@M) AS CreditedThru
FROM Tools.ToolCavity tc
LEFT JOIN Lots.Lot l ON l.ToolCavityId=tc.Id
LEFT JOIN Lots.LotStatusCode sc ON sc.Id=l.LotStatusId AND sc.Code=N'Open'
WHERE tc.ToolId=@T AND (l.Id IS NULL OR sc.Code=N'Open')
ORDER BY tc.CavityNumber;
SELECT 'DIE watermark'=Workorder.ufn_DieShotWatermark(@T,@S,@M),
       'ShotCount'=(SELECT ShotCount FROM Tools.Tool WHERE Id=@T);`);
}

/** Wipe a review die's LOTs/ledger/anchors back to nothing. Fixtures only --
 *  every row it touches was created by this review book (RB- dies). */
export function resetDie(die) {
  return sql(`
DECLARE @T BIGINT=(SELECT Id FROM Tools.Tool WHERE Code=N'${die}');
DECLARE @L TABLE (Id BIGINT PRIMARY KEY);
INSERT INTO @L SELECT Id FROM Lots.Lot WHERE ToolId=@T;
DELETE FROM Workorder.DieCastCounterAnchor WHERE ToolId=@T;
DELETE FROM Workorder.DieCastContribution WHERE LotId IN (SELECT Id FROM @L);
DELETE FROM Workorder.RejectEvent     WHERE LotId IN (SELECT Id FROM @L);
DELETE FROM Workorder.ProductionEvent WHERE LotId IN (SELECT Id FROM @L);
DELETE FROM Lots.LotGenealogyClosure WHERE AncestorLotId IN (SELECT Id FROM @L) OR DescendantLotId IN (SELECT Id FROM @L);
DELETE FROM Lots.LotGenealogy WHERE ParentLotId IN (SELECT Id FROM @L) OR ChildLotId IN (SELECT Id FROM @L);
DELETE FROM Lots.LotAttributeChange WHERE LotId IN (SELECT Id FROM @L);
DELETE FROM Lots.LotEventLog        WHERE LotId IN (SELECT Id FROM @L);
DELETE FROM Lots.LotLabel           WHERE LotId IN (SELECT Id FROM @L) OR ParentLotId IN (SELECT Id FROM @L);
DELETE FROM Lots.LotMovement        WHERE LotId IN (SELECT Id FROM @L);
DELETE FROM Lots.LotStatusHistory   WHERE LotId IN (SELECT Id FROM @L);
DELETE FROM Lots.PauseEvent         WHERE LotId IN (SELECT Id FROM @L);
DELETE FROM Lots.Lot WHERE Id IN (SELECT Id FROM @L);
UPDATE Tools.Tool SET ShotCount=0 WHERE Id=@T;
SELECT 'reset'=N'${die}';`);
}
