-- =============================================
-- File:         0067_Lot_SearchAdvanced/050_signature_parity.sql
-- Author:       Blue Ridge Automation
-- Description:  Lots.Lot_SearchAdvanced must expose EXACTLY the 12 canonical
--               filter parameters (design spec section 3.1). The named query's
--               parameters[] and BlueRidge.Lots.Lot._EMPTY_FILTERS carry the
--               same twelve names; this file pins the SQL end so drift is
--               caught here rather than as a filter that silently stops
--               filtering -- the failure mode that motivated explicit named
--               parameters over a JSON blob.
--
--               Also asserts Lots.Lot_Search is still FROZEN at its original
--               four parameters. It has three consumers (077_Lot_Search,
--               BlueRidge.Lots.Lot.search, and the HoldManagement bulk picker,
--               which calls the wrapper POSITIONALLY); widening it breaks all
--               three, so the freeze is enforced here rather than trusted.
-- =============================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0067_Lot_SearchAdvanced/050_signature_parity.sql';
GO

DECLARE @n INT;
DECLARE @Expected TABLE (Name SYSNAME PRIMARY KEY);
INSERT INTO @Expected (Name) VALUES
    (N'@Query'), (N'@ItemId'), (N'@CreatedFromEt'), (N'@CreatedToEt'),
    (N'@ToolId'), (N'@ToolCavityId'), (N'@LocationId'), (N'@MachineLocationId'),
    (N'@ShiftId'), (N'@LotStatusId'), (N'@LotOriginTypeId'), (N'@LimitRows');

SELECT @n = COUNT(*) FROM sys.parameters
WHERE object_id = OBJECT_ID(N'Lots.Lot_SearchAdvanced');
EXEC test.Assert_IsEqual @TestName = N'[SearchAdv] proc exposes exactly 12 parameters',
    @Expected = N'12', @Actual = @n;

SELECT @n = COUNT(*) FROM sys.parameters p
WHERE p.object_id = OBJECT_ID(N'Lots.Lot_SearchAdvanced')
  AND p.name NOT IN (SELECT Name FROM @Expected);
EXEC test.Assert_IsEqual @TestName = N'[SearchAdv] no unexpected parameter name',
    @Expected = N'0', @Actual = @n;

SELECT @n = COUNT(*) FROM @Expected e
WHERE e.Name NOT IN (SELECT p.name FROM sys.parameters p
                     WHERE p.object_id = OBJECT_ID(N'Lots.Lot_SearchAdvanced'));
EXEC test.Assert_IsEqual @TestName = N'[SearchAdv] no canonical parameter missing',
    @Expected = N'0', @Actual = @n;

-- Both date bounds must be DATE, not DATETIME2 -- the proc does the Eastern-day
-- to UTC-instant conversion internally and a DATETIME2 parameter would let a
-- caller smuggle a time component past it.
SELECT @n = COUNT(*) FROM sys.parameters p
INNER JOIN sys.types t ON t.user_type_id = p.user_type_id
WHERE p.object_id = OBJECT_ID(N'Lots.Lot_SearchAdvanced')
  AND p.name IN (N'@CreatedFromEt', N'@CreatedToEt')
  AND t.name = N'date';
EXEC test.Assert_IsEqual @TestName = N'[SearchAdv] both date bounds are DATE typed',
    @Expected = N'2', @Actual = @n;

-- Lot_Search stays frozen.
SELECT @n = COUNT(*) FROM sys.parameters WHERE object_id = OBJECT_ID(N'Lots.Lot_Search');
EXEC test.Assert_IsEqual @TestName = N'[SearchAdv] Lot_Search still has exactly 4 parameters (frozen)',
    @Expected = N'4', @Actual = @n;
GO
