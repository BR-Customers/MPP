-- Removes ONLY the walkthrough fixture (LOT names WALK-CR-*) and the super-lots that hold nothing else.
SET NOCOUNT ON;
DECLARE @Lot TABLE (Id BIGINT);
INSERT INTO @Lot SELECT Id FROM Lots.Lot WHERE LotName LIKE N'WALK-CR-%';
DECLARE @Con TABLE (Id BIGINT);
INSERT INTO @Con SELECT DISTINCT ContainerId FROM Lots.ContainerTray WHERE FinishedGoodLotId IN (SELECT Id FROM @Lot);
DECLARE @Run TABLE (Id BIGINT);
INSERT INTO @Run SELECT DISTINCT m.ControlledRunId FROM Quality.ControlledRunMember m
    WHERE m.LotId IN (SELECT Id FROM @Lot) OR m.ContainerId IN (SELECT Id FROM @Con);
DELETE FROM @Run WHERE Id IN (SELECT m.ControlledRunId FROM Quality.ControlledRunMember m
    WHERE (m.LotId IS NOT NULL AND m.LotId NOT IN (SELECT Id FROM @Lot)) OR (m.ContainerId IS NOT NULL AND m.ContainerId NOT IN (SELECT Id FROM @Con)));
DECLARE @Sig TABLE (Id BIGINT);
INSERT INTO @Sig SELECT SignatureId FROM Quality.ControlledRunRelease WHERE ControlledRunId IN (SELECT Id FROM @Run)
           UNION SELECT SignatureId FROM Quality.ControlledRunDeviation WHERE ControlledRunId IN (SELECT Id FROM @Run);
DELETE FROM Quality.ControlledRunResult WHERE ControlledRunMemberId IN (SELECT Id FROM Quality.ControlledRunMember WHERE ControlledRunId IN (SELECT Id FROM @Run));
DELETE FROM Quality.ControlledRunLabel WHERE ControlledRunId IN (SELECT Id FROM @Run);
DELETE FROM Quality.ControlledRunMember WHERE ControlledRunId IN (SELECT Id FROM @Run);
DELETE FROM Quality.ControlledRunRelease WHERE ControlledRunId IN (SELECT Id FROM @Run);
DELETE FROM Quality.ControlledRunDeviation WHERE ControlledRunId IN (SELECT Id FROM @Run);
ALTER TABLE Quality.Signature DISABLE TRIGGER TR_Signature_Immutable;
DELETE FROM Quality.Signature WHERE Id IN (SELECT Id FROM @Sig);
ALTER TABLE Quality.Signature ENABLE TRIGGER TR_Signature_Immutable;
DELETE FROM Quality.ControlledRun WHERE Id IN (SELECT Id FROM @Run);
DELETE FROM Workorder.RejectEvent WHERE LotId IN (SELECT Id FROM @Lot);
DELETE FROM Lots.LotStatusHistory WHERE LotId IN (SELECT Id FROM @Lot);
DELETE FROM Lots.ContainerTray WHERE ContainerId IN (SELECT Id FROM @Con);
DELETE FROM Lots.Container WHERE Id IN (SELECT Id FROM @Con);
DELETE FROM Lots.LotEventLog WHERE LotId IN (SELECT Id FROM @Lot);
DELETE FROM Lots.Lot WHERE Id IN (SELECT Id FROM @Lot);
SELECT (SELECT COUNT(*) FROM Lots.Lot WHERE LotName LIKE N'WALK-CR-%') AS LotsLeft, (SELECT COUNT(*) FROM @Run) AS RunsRemoved;
-- Hand the numbers back only when nothing real is left to collide with.
IF NOT EXISTS (SELECT 1 FROM Quality.ControlledRun)
    UPDATE Lots.IdentifierSequence SET LastValue = 0 WHERE Code = N'ControlledRun';
IF NOT EXISTS (SELECT 1 FROM Quality.ControlledRunDeviation)
    UPDATE Lots.IdentifierSequence SET LastValue = 0 WHERE Code = N'ControlledRunDeviation';
