// Dev-only helpers for the training captures, keyed by cavity CODE + description
// (DMO125 repeats letters a/b once per part, so a letter alone is ambiguous).
// Every write goes through the same procs the screens call.
import { execFileSync } from 'node:child_process';

export const DIE = 'DMO125', MACHINE = 'DC1-M11', PIN = '24680';

export function sql(q) {
  return execFileSync('sqlcmd', ['-S', 'localhost', '-d', 'MPP_MES_Dev', '-E', '-C', '-W', '-I', '-b',
    '-s', '|', '-h', '-1', '-Q', 'SET NOCOUNT ON;\n' + q], { encoding: 'utf8' }).trim();
}

const cav = (desc) => `(SELECT c.Id FROM Tools.ToolCavity c JOIN Tools.Tool t ON t.Id=c.ToolId
  WHERE t.Code=N'${DIE}' AND c.Description=N'${desc}' AND c.DeprecatedAt IS NULL)`;
const user = `(SELECT Id FROM Location.AppUser WHERE Pin=N'${PIN}')`;

export function openBasket({ desc, ltt }) {
  return sql(`DECLARE @C BIGINT=${cav(desc)};
DECLARE @T BIGINT=(SELECT ToolId FROM Tools.ToolCavity WHERE Id=@C), @I BIGINT=(SELECT ItemId FROM Tools.ToolCavity WHERE Id=@C);
DECLARE @M BIGINT=(SELECT Id FROM Location.Location WHERE Code=N'${MACHINE}'), @U BIGINT=${user};
DECLARE @Term BIGINT=(SELECT Id FROM Location.Location WHERE Code=N'DC1-T1');
DECLARE @R TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO @R EXEC Lots.DieCastLot_Open @ItemId=@I,@CurrentLocationId=@M,@ToolId=@T,@ToolCavityId=@C,
  @LotName=N'${ltt}',@AppUserId=@U,@TerminalLocationId=@Term;
SELECT Status, Message FROM @R;`);
}

export function releaseBasket({ desc, reading }) {
  return sql(`DECLARE @C BIGINT=${cav(desc)}, @U BIGINT=${user};
DECLARE @M BIGINT=(SELECT Id FROM Location.Location WHERE Code=N'${MACHINE}');
DECLARE @Term BIGINT=(SELECT Id FROM Location.Location WHERE Code=N'DC1-T1');
DECLARE @S BIGINT=(SELECT TOP 1 Id FROM Oee.Shift WHERE ActualEnd IS NULL ORDER BY Id DESC);
DECLARE @L BIGINT=(SELECT l.Id FROM Lots.Lot l JOIN Lots.LotStatusCode s ON s.Id=l.LotStatusId
  WHERE s.Code=N'Open' AND l.ToolCavityId=@C);
DECLARE @R TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO @R EXEC Lots.DieCastLot_Release @LotId=@L,@StorageLocationId=NULL,@FinalPieceDelta=NULL,
  @CounterReading=${reading},@ShiftId=@S,@AppUserId=@U,@TerminalLocationId=@Term,@CellLocationId=@M;
SELECT Status, Message FROM @R;`);
}

export function openLots() {
  const out = sql(`SELECT c.Description, c.CavityCode, l.LotName, l.PieceCount
FROM Lots.Lot l JOIN Lots.LotStatusCode s ON s.Id=l.LotStatusId AND s.Code=N'Open'
JOIN Tools.ToolCavity c ON c.Id=l.ToolCavityId JOIN Tools.Tool t ON t.Id=c.ToolId AND t.Code=N'${DIE}'
ORDER BY c.Id;`);
  return out ? out.split('\n').map((l) => { const [desc, code, ltt, pieces] = l.split('|');
    return { desc, code, ltt, pieces: Number(pieces) }; }) : [];
}

/** Dev playground reset for DMO125: remove every LOT, contribution, reject and
 *  counter anchor this die has, so each capture run starts from an empty die.
 *  Dev only -- Import-ConfigSnapshot left Dev with no production history. */
export function clearDie() {
  return sql(`DECLARE @T BIGINT=(SELECT Id FROM Tools.Tool WHERE Code=N'${DIE}');
IF DB_NAME() <> N'MPP_MES_Dev' THROW 50000, 'clearDie is Dev only', 1;
DECLARE @L TABLE (Id BIGINT PRIMARY KEY); INSERT INTO @L SELECT Id FROM Lots.Lot WHERE ToolId=@T;
DELETE FROM Workorder.DieCastCounterAnchor WHERE ToolId=@T;
DELETE FROM Workorder.DieCastContribution WHERE LotId IN (SELECT Id FROM @L) OR ToolCavityId IN (SELECT Id FROM Tools.ToolCavity WHERE ToolId=@T);
DELETE FROM Workorder.RejectEvent WHERE LotId IN (SELECT Id FROM @L) OR ToolId=@T;
DELETE FROM Workorder.ProductionEvent WHERE LotId IN (SELECT Id FROM @L);
DELETE FROM Lots.LotGenealogyClosure WHERE AncestorLotId IN (SELECT Id FROM @L) OR DescendantLotId IN (SELECT Id FROM @L);
DELETE FROM Lots.LotGenealogy WHERE ParentLotId IN (SELECT Id FROM @L) OR ChildLotId IN (SELECT Id FROM @L);
DELETE FROM Lots.LotAttributeChange WHERE LotId IN (SELECT Id FROM @L);
DELETE FROM Lots.LotEventLog WHERE LotId IN (SELECT Id FROM @L);
DELETE FROM Lots.LotLabel WHERE LotId IN (SELECT Id FROM @L) OR ParentLotId IN (SELECT Id FROM @L);
DELETE FROM Lots.LotMovement WHERE LotId IN (SELECT Id FROM @L);
DELETE FROM Lots.LotStatusHistory WHERE LotId IN (SELECT Id FROM @L);
DELETE FROM Lots.PauseEvent WHERE LotId IN (SELECT Id FROM @L);
DELETE FROM Lots.Lot WHERE Id IN (SELECT Id FROM @L);
SELECT 'cleared', COUNT(*) FROM @L;`);
}
