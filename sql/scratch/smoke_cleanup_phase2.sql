-- ============================================================
-- smoke_cleanup_phase2.sql  (DEV SMOKE AID)
-- Removes ALL Lots.* rows (FK-safe). The dev DB normally holds zero persistent
-- LOTs; run this to clear the Phase 2 smoke seed after testing.
--   sqlcmd -S localhost -d MPP_MES_Dev -i sql/scratch/smoke_cleanup_phase2.sql -b -I -C
-- ============================================================
SET NOCOUNT ON;
SET XACT_ABORT ON;

DELETE FROM Audit.OperationLog
    WHERE LogEntityTypeId IN (SELECT Id FROM Audit.LogEntityType WHERE Code IN (N'PauseEvent', N'LotLabel'));
DELETE FROM Lots.PauseEvent;
DELETE FROM Lots.LotGenealogyClosure;
DELETE FROM Lots.LotGenealogy;
DELETE FROM Lots.LotAttributeChange;
IF OBJECT_ID(N'Lots.LotLabel') IS NOT NULL DELETE FROM Lots.LotLabel;
DELETE FROM Lots.LotEventLog;
DELETE FROM Lots.LotMovement;
DELETE FROM Lots.LotStatusHistory;
DELETE FROM Lots.Lot;

PRINT 'Phase 2 smoke data cleared.';
GO
