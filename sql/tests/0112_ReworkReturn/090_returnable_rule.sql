-- =============================================
-- File:        0112_ReworkReturn/090_returnable_rule.sql
-- Author:      Blue Ridge Automation
-- Description: Super-lot piece 5, final review -- the ONE definition of "can this LOT
--              be returned to a vendor": Lots.ufn_LotReturnableToVendor, read by
--              Lots.VendorReturn_GetEligibility (the LOT Detail tab, which no longer
--              decides it in a binding) and by Lots.VendorReturn_Mark (whose refusal
--              is the same Reason, word for word):
--                * Received Good / Hold, ReceivedOffsite: returnable, Reason NULL;
--                * Manufactured: not returnable, the "made at MPP" text;
--                * Received but Closed / Scrap: not returnable, the status text;
--                * origin is reported before status;
--                * GetEligibility of an unknown LOT: no row.
--              LOTs named TEST-RET-%.
-- =============================================
EXEC test.BeginTestFile @FileName = N'0112_ReworkReturn/090_returnable_rule.sql';
GO
-- ---- teardown (FK-safe) ----
DECLARE @TdLot TABLE (Id BIGINT PRIMARY KEY);
INSERT INTO @TdLot (Id) SELECT Id FROM Lots.Lot WHERE LotName LIKE N'TEST-RET-%';
DELETE FROM Lots.VendorReturn WHERE LotId IN (SELECT Id FROM @TdLot);
DELETE FROM Lots.LotMovement WHERE LotId IN (SELECT Id FROM @TdLot);
DELETE FROM Lots.LotStatusHistory WHERE LotId IN (SELECT Id FROM @TdLot);
DELETE FROM Lots.LotEventLog WHERE LotId IN (SELECT Id FROM @TdLot);
DELETE FROM Lots.LotGenealogyClosure WHERE AncestorLotId IN (SELECT Id FROM @TdLot) OR DescendantLotId IN (SELECT Id FROM @TdLot);
DELETE FROM Lots.Lot WHERE Id IN (SELECT Id FROM @TdLot);
GO

DECLARE @App       BIGINT = (SELECT Id FROM Location.AppUser WHERE Initials = N'SYS');
DECLARE @OriginRcv BIGINT = (SELECT Id FROM Lots.LotOriginType WHERE Code = N'Received');
DECLARE @OriginOff BIGINT = (SELECT Id FROM Lots.LotOriginType WHERE Code = N'ReceivedOffsite');
DECLARE @OriginMfg BIGINT = (SELECT Id FROM Lots.LotOriginType WHERE Code = N'Manufactured');
DECLARE @StHold    BIGINT = (SELECT Id FROM Lots.LotStatusCode WHERE Code = N'Hold');
DECLARE @StClosed  BIGINT = (SELECT Id FROM Lots.LotStatusCode WHERE Code = N'Closed');
DECLARE @StScrap   BIGINT = (SELECT Id FROM Lots.LotStatusCode WHERE Code = N'Scrap');
DECLARE @ItemId BIGINT, @Cell BIGINT;
SELECT TOP 1 @ItemId = eil.ItemId, @Cell = eil.LocationId
FROM Parts.v_EffectiveItemLocation eil
WHERE eil.ItemId IN (SELECT Id FROM Parts.Item WHERE MaxLotSize IS NULL)
ORDER BY eil.LocationId;
DECLARE @n NVARCHAR(600);
DECLARE @e NVARCHAR(600);
DECLARE @L BIGINT;
DECLARE @Lc TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT, MintedLotName NVARCHAR(50));
DECLARE @Vr TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
DECLARE @El TABLE (LotId BIGINT, CanReturnToVendor BIT, Reason NVARCHAR(500));

SET @n = CASE WHEN @App IS NOT NULL AND @OriginRcv IS NOT NULL AND @OriginOff IS NOT NULL AND @OriginMfg IS NOT NULL
               AND @StHold IS NOT NULL AND @StClosed IS NOT NULL AND @StScrap IS NOT NULL
               AND @ItemId IS NOT NULL AND @Cell IS NOT NULL THEN N'ok' ELSE N'missing' END;
EXEC test.Assert_IsEqual @TestName = N'[RetRule] fixture: user, origins, statuses, item, location', @Expected = N'ok', @Actual = @n;

-- ---- LOTs ----
INSERT INTO @Lc EXEC Lots.Lot_Create @ItemId = @ItemId, @LotOriginTypeId = @OriginRcv, @CurrentLocationId = @Cell, @PieceCount = 10, @AppUserId = @App, @LotName = N'TEST-RET-GOOD';
SELECT @L = NewId FROM @Lc; DELETE FROM @Lc;
DECLARE @LGood BIGINT = @L;
INSERT INTO @Lc EXEC Lots.Lot_Create @ItemId = @ItemId, @LotOriginTypeId = @OriginRcv, @CurrentLocationId = @Cell, @PieceCount = 10, @AppUserId = @App, @LotName = N'TEST-RET-HOLD';
SELECT @L = NewId FROM @Lc; DELETE FROM @Lc;
DECLARE @LHold BIGINT = @L;
UPDATE Lots.Lot SET LotStatusId = @StHold WHERE Id = @LHold;
INSERT INTO @Lc EXEC Lots.Lot_Create @ItemId = @ItemId, @LotOriginTypeId = @OriginRcv, @CurrentLocationId = @Cell, @PieceCount = 10, @AppUserId = @App, @LotName = N'TEST-RET-OFF';
SELECT @L = NewId FROM @Lc; DELETE FROM @Lc;
DECLARE @LOff BIGINT = @L;
UPDATE Lots.Lot SET LotOriginTypeId = @OriginOff WHERE Id = @LOff;
INSERT INTO @Lc EXEC Lots.Lot_Create @ItemId = @ItemId, @LotOriginTypeId = @OriginRcv, @CurrentLocationId = @Cell, @PieceCount = 10, @AppUserId = @App, @LotName = N'TEST-RET-MFG';
SELECT @L = NewId FROM @Lc; DELETE FROM @Lc;
DECLARE @LMfg BIGINT = @L;
UPDATE Lots.Lot SET LotOriginTypeId = @OriginMfg WHERE Id = @LMfg;
INSERT INTO @Lc EXEC Lots.Lot_Create @ItemId = @ItemId, @LotOriginTypeId = @OriginRcv, @CurrentLocationId = @Cell, @PieceCount = 10, @AppUserId = @App, @LotName = N'TEST-RET-CLOSED';
SELECT @L = NewId FROM @Lc; DELETE FROM @Lc;
DECLARE @LClosed BIGINT = @L;
UPDATE Lots.Lot SET LotStatusId = @StClosed WHERE Id = @LClosed;
INSERT INTO @Lc EXEC Lots.Lot_Create @ItemId = @ItemId, @LotOriginTypeId = @OriginRcv, @CurrentLocationId = @Cell, @PieceCount = 10, @AppUserId = @App, @LotName = N'TEST-RET-SCRAP';
SELECT @L = NewId FROM @Lc; DELETE FROM @Lc;
DECLARE @LScrap BIGINT = @L;
UPDATE Lots.Lot SET LotStatusId = @StScrap WHERE Id = @LScrap;
-- both rules fail: origin is reported first
INSERT INTO @Lc EXEC Lots.Lot_Create @ItemId = @ItemId, @LotOriginTypeId = @OriginRcv, @CurrentLocationId = @Cell, @PieceCount = 10, @AppUserId = @App, @LotName = N'TEST-RET-MFGCL';
SELECT @L = NewId FROM @Lc; DELETE FROM @Lc;
DECLARE @LMfgCl BIGINT = @L;
UPDATE Lots.Lot SET LotOriginTypeId = @OriginMfg, LotStatusId = @StClosed WHERE Id = @LMfgCl;

-- ---- the function ----
SET @n = (SELECT CONCAT(CAST(CanReturnToVendor AS NVARCHAR(1)), N'|', ISNULL(Reason, N'<NULL>')) FROM Lots.ufn_LotReturnableToVendor(@LGood));
EXEC test.Assert_IsEqual @TestName = N'[RetRule] Received Good: returnable, no reason', @Expected = N'1|<NULL>', @Actual = @n;
SET @n = (SELECT CONCAT(CAST(CanReturnToVendor AS NVARCHAR(1)), N'|', ISNULL(Reason, N'<NULL>')) FROM Lots.ufn_LotReturnableToVendor(@LHold));
EXEC test.Assert_IsEqual @TestName = N'[RetRule] Received Hold: returnable (a held box is a prime candidate)', @Expected = N'1|<NULL>', @Actual = @n;
SET @n = (SELECT CONCAT(CAST(CanReturnToVendor AS NVARCHAR(1)), N'|', ISNULL(Reason, N'<NULL>')) FROM Lots.ufn_LotReturnableToVendor(@LOff));
EXEC test.Assert_IsEqual @TestName = N'[RetRule] ReceivedOffsite Good: returnable', @Expected = N'1|<NULL>', @Actual = @n;
SET @n = (SELECT CONCAT(CAST(CanReturnToVendor AS NVARCHAR(1)), N'|', ISNULL(Reason, N'<NULL>')) FROM Lots.ufn_LotReturnableToVendor(@LMfg));
EXEC test.Assert_IsEqual @TestName = N'[RetRule] Manufactured: not returnable, made-at-MPP reason',
    @Expected = N'0|LOT TEST-RET-MFG was made at MPP; only purchased or received material can be returned to a vendor.', @Actual = @n;
SET @n = (SELECT CONCAT(CAST(CanReturnToVendor AS NVARCHAR(1)), N'|', ISNULL(Reason, N'<NULL>')) FROM Lots.ufn_LotReturnableToVendor(@LMfgCl));
EXEC test.Assert_IsEqual @TestName = N'[RetRule] Manufactured AND Closed: origin reason first',
    @Expected = N'0|LOT TEST-RET-MFGCL was made at MPP; only purchased or received material can be returned to a vendor.', @Actual = @n;
SET @e = (SELECT N'0|LOT TEST-RET-CLOSED is ' + Name + N' (status Closed) and cannot be returned to a vendor.' FROM Lots.LotStatusCode WHERE Id = @StClosed);
SET @n = (SELECT CONCAT(CAST(CanReturnToVendor AS NVARCHAR(1)), N'|', ISNULL(Reason, N'<NULL>')) FROM Lots.ufn_LotReturnableToVendor(@LClosed));
EXEC test.Assert_IsEqual @TestName = N'[RetRule] Received Closed: not returnable, status reason', @Expected = @e, @Actual = @n;
SET @n = (SELECT CAST(CanReturnToVendor AS NVARCHAR(1)) FROM Lots.ufn_LotReturnableToVendor(@LScrap));
EXEC test.Assert_IsEqual @TestName = N'[RetRule] Received Scrap: not returnable', @Expected = N'0', @Actual = @n;

-- ---- the read the LOT Detail tab binds to ----
INSERT INTO @El EXEC Lots.VendorReturn_GetEligibility @LotId = @LGood;
SET @n = (SELECT CONCAT(LotId, N'|', CAST(CanReturnToVendor AS NVARCHAR(1)), N'|', ISNULL(Reason, N'<NULL>')) FROM @El); DELETE FROM @El;
SET @e = CONCAT(@LGood, N'|1|<NULL>');
EXEC test.Assert_IsEqual @TestName = N'[RetRule] GetEligibility, returnable LOT: one row, CanReturnToVendor 1', @Expected = @e, @Actual = @n;
DECLARE @Missing BIGINT = -1;
INSERT INTO @El EXEC Lots.VendorReturn_GetEligibility @LotId = @Missing;
SET @n = CAST((SELECT COUNT(*) FROM @El) AS NVARCHAR(5)); DELETE FROM @El;
EXEC test.Assert_IsEqual @TestName = N'[RetRule] GetEligibility, unknown LOT: no row', @Expected = N'0', @Actual = @n;

-- ---- the tab and the save say the same thing, word for word ----
INSERT INTO @El EXEC Lots.VendorReturn_GetEligibility @LotId = @LMfg;
SET @e = (SELECT Reason FROM @El); DELETE FROM @El;
INSERT INTO @Vr EXEC Lots.VendorReturn_Mark @LotId = @LMfg, @Quantity = 1, @AppUserId = @App;
SET @n = (SELECT CONCAT(CAST(Status AS NVARCHAR(1)), N'|', Message) FROM @Vr); DELETE FROM @Vr;
SET @e = N'0|' + @e;
EXEC test.Assert_IsEqual @TestName = N'[RetRule] Manufactured: Mark refuses with exactly the GetEligibility reason', @Expected = @e, @Actual = @n;

INSERT INTO @El EXEC Lots.VendorReturn_GetEligibility @LotId = @LClosed;
SET @e = (SELECT Reason FROM @El); DELETE FROM @El;
INSERT INTO @Vr EXEC Lots.VendorReturn_Mark @LotId = @LClosed, @Quantity = 1, @AppUserId = @App;
SET @n = (SELECT CONCAT(CAST(Status AS NVARCHAR(1)), N'|', Message) FROM @Vr); DELETE FROM @Vr;
SET @e = N'0|' + @e;
EXEC test.Assert_IsEqual @TestName = N'[RetRule] Closed: Mark refuses with exactly the GetEligibility reason', @Expected = @e, @Actual = @n;

-- a returnable Hold LOT is accepted by Mark (the status re-check under the lock passes)
INSERT INTO @Vr EXEC Lots.VendorReturn_Mark @LotId = @LHold, @Quantity = 10, @AppUserId = @App;
SET @n = (SELECT CONCAT(CAST(Status AS NVARCHAR(1)), N'|', Message) FROM @Vr); DELETE FROM @Vr;
EXEC test.Assert_IsEqual @TestName = N'[RetRule] Hold LOT: Mark accepted, stays on hold at zero', @Expected = N'1|Marked for return; 0 pieces remaining; LOT remains on hold.', @Actual = @n;
SET @n = (SELECT sc.Code FROM Lots.Lot l JOIN Lots.LotStatusCode sc ON sc.Id = l.LotStatusId WHERE l.Id = @LHold);
EXEC test.Assert_IsEqual @TestName = N'[RetRule] ...and the LOT is still Hold', @Expected = N'Hold', @Actual = @n;
GO

-- ---- teardown ----
DECLARE @TdLot TABLE (Id BIGINT PRIMARY KEY);
INSERT INTO @TdLot (Id) SELECT Id FROM Lots.Lot WHERE LotName LIKE N'TEST-RET-%';
DELETE FROM Lots.VendorReturn WHERE LotId IN (SELECT Id FROM @TdLot);
DELETE FROM Lots.LotMovement WHERE LotId IN (SELECT Id FROM @TdLot);
DELETE FROM Lots.LotStatusHistory WHERE LotId IN (SELECT Id FROM @TdLot);
DELETE FROM Lots.LotEventLog WHERE LotId IN (SELECT Id FROM @TdLot);
DELETE FROM Lots.LotGenealogyClosure WHERE AncestorLotId IN (SELECT Id FROM @TdLot) OR DescendantLotId IN (SELECT Id FROM @TdLot);
DELETE FROM Lots.Lot WHERE Id IN (SELECT Id FROM @TdLot);
GO

EXEC test.EndTestFile;
GO
