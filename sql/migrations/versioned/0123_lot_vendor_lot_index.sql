-- ============================================================
-- Migration:   0123_lot_vendor_lot_index.sql
-- Author:      Blue Ridge Automation
-- Created:     2026-11-16
-- Description: One narrow filtered index so the "supplier lot already entered" check
--              (Lots.Lot_ListByVendorLot) seeks on Lots.Lot.VendorLotNumber instead of
--              scanning the Lots.Lot heap.
--
--   WHY (stored-procedure review, 2026-11-16). Every operator check-in of a purchased box
--   (Line Inventory add form, the low-inventory banner's form, the cutover purchased-box
--   form) calls BlueRidge.Lots.Lot.findVendorLotUse before the LOT is created. The proc is
--       SELECT TOP 5 ..., COUNT(*) OVER () AS TotalMatches
--       FROM Lots.Lot l JOIN ... WHERE @V IS NOT NULL AND l.VendorLotNumber = @V
--       ORDER BY l.CreatedAt DESC, l.Id DESC;
--   Lots.Lot is a heap (its PK is NONCLUSTERED) and nothing indexes VendorLotNumber, so
--   every check-in scanned the whole table, which grows with every LOT ever made, usually
--   to find nothing (a new box's supplier lot has not been entered before).
--
--   KEY (VendorLotNumber) ONLY. The proc's only predicate is equality on VendorLotNumber.
--   It sorts by CreatedAt DESC, Id DESC, but COUNT(*) OVER () must read every match anyway,
--   so ordering the key by CreatedAt would save only a sort of a handful of rows.
--
--   FILTER VendorLotNumber IS NOT NULL. Manufactured LOTs carry no supplier lot, so most of
--   the table stays out of the index. The equality predicate implies NOT NULL, so the
--   optimiser can use the filtered index for the proc's local-variable parameter. The NONE
--   marker ("no lot on box", Lot_Create v1.8) is deliberately NOT filtered out: a filter of
--   VendorLotNumber <> N'NONE' could not be matched against "= @V" (the optimiser cannot
--   prove @V <> 'NONE' at compile time), so the index would go unused. NONE rows cost one
--   entry each and the proc never seeks for NONE (it short-circuits before reading).
--
--   DELIBERATELY NO INCLUDE COLUMNS. The proc also returns LotName, ItemId, LotStatusId,
--   CurrentLocationId, CreatedAt and PieceCount. PieceCount, LotStatusId and
--   CurrentLocationId are rewritten constantly (credits, consumption, moves, closes), so
--   including them would make those writes maintain this index too. A match set is a few
--   rows, so a row lookup per match costs far less than that write amplification.
--   VendorLotNumber is written only by Lot_Create (Lot_Split / Lot_Merge / the mint procs
--   insert NULL) and changed only by Lot_Update, so the index is maintained
--   on inserts of LOTs that carry a supplier lot and on the rare correction. No change to the
--   proc or to its result set. Offline build on Standard edition (writes to Lots.Lot wait
--   while it builds: seconds at ~80k rows). ASCII only.
--
--   NUMBERING. 0119 is claimed by the container-as-LOT branch and 0120 / 0121 / 0122 by the
--   other review index PRs, so this is 0123. It depends only on Lots.Lot (0020) and the
--   VendorLotNumber column, not on any of them; renumber if they land in another order.
-- ============================================================

IF NOT EXISTS (SELECT 1 FROM sys.indexes
               WHERE object_id = OBJECT_ID(N'Lots.Lot') AND name = N'IX_Lot_VendorLotNumber')
    CREATE NONCLUSTERED INDEX IX_Lot_VendorLotNumber
        ON Lots.Lot (VendorLotNumber)
        WHERE VendorLotNumber IS NOT NULL;
GO

IF NOT EXISTS (SELECT 1 FROM dbo.SchemaVersion WHERE MigrationId = N'0123_lot_vendor_lot_index')
    INSERT INTO dbo.SchemaVersion (MigrationId, Description)
    VALUES (N'0123_lot_vendor_lot_index',
            N'Lots.Lot += IX_Lot_VendorLotNumber (filtered VendorLotNumber NOT NULL, keyed VendorLotNumber; no INCLUDE) for the supplier-lot-already-entered check on every purchased-box check-in (stored-procedure review 2026-11-16). No proc change.');
GO
