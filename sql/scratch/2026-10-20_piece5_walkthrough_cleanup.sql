-- ============================================================
-- Removes the piece 5 walkthrough rows (WALK-P5-RW, WALK-P5-R1) from MPP_MES_Dev.
-- Test data only. Order is FK-safe: results / returns / reworks / events before LOTs.
-- Their CR000001 memberships are deleted; the super-lot itself is left for
-- 2026-10-13_super_lot_walkthrough_cleanup.sql.
-- ============================================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
DECLARE @L TABLE (Id BIGINT PRIMARY KEY);
INSERT INTO @L SELECT Id FROM Lots.Lot WHERE LotName IN (N'WALK-P5-RW', N'WALK-P5-R1');

BEGIN TRANSACTION;
DELETE FROM Lots.VendorReturn WHERE LotId IN (SELECT Id FROM @L);
DELETE rr FROM Quality.ControlledRunResult rr JOIN Quality.ControlledRunMember m ON m.Id = rr.ControlledRunMemberId WHERE m.LotId IN (SELECT Id FROM @L);
DELETE FROM Quality.ControlledRunMember WHERE LotId IN (SELECT Id FROM @L);
DELETE FROM Lots.LotRework WHERE LotId IN (SELECT Id FROM @L);
DELETE FROM Workorder.RejectEvent WHERE LotId IN (SELECT Id FROM @L);
DELETE FROM Workorder.ProductionEvent WHERE LotId IN (SELECT Id FROM @L);
DELETE FROM Lots.LotGenealogyClosure WHERE AncestorLotId IN (SELECT Id FROM @L) OR DescendantLotId IN (SELECT Id FROM @L);
DELETE FROM Lots.LotMovement WHERE LotId IN (SELECT Id FROM @L);
DELETE FROM Lots.LotStatusHistory WHERE LotId IN (SELECT Id FROM @L);
DELETE FROM Lots.LotEventLog WHERE LotId IN (SELECT Id FROM @L);
DELETE FROM Lots.Lot WHERE Id IN (SELECT Id FROM @L);
COMMIT TRANSACTION;
SELECT COUNT(*) AS RemainingWalkP5Lots FROM Lots.Lot WHERE LotName LIKE N'WALK-P5-%';
