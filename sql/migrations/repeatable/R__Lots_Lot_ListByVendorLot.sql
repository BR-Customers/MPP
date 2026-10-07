-- ============================================================
-- Repeatable:  R__Lots_Lot_ListByVendorLot.sql
-- Author:      Blue Ridge Automation
-- Created:     2026-10-07
-- Version:     1.0
-- Description: LOTs already carrying a supplier lot number -- the read behind
--              the "this supplier lot was already entered" warning on every
--              operator check-in (Line Inventory + LOT popup, the low-inventory
--              banner's form, the cutover purchased-box form).
--
--              WHY A WARNING AND NOT A REFUSAL (Jacques, 2026-10-07). Each box
--              of a purchased part carries its own supplier lot, so the same
--              number entered twice is almost always the same box entered
--              twice. But it is the operator's call: the screen warns, names
--              where and against which part the number was first entered, and
--              lets them continue. Lots.Lot_Create is therefore NOT changed and
--              does not refuse a repeat.
--
--              MATCH. Exact, after trimming, on Lots.Lot.VendorLotNumber --
--              ANY part, ANY status (a closed LOT still counts: the number was
--              entered). NULL, blank and the marker NONE (Lot_Create v1.8's
--              "no lot on box") never match anything.
--
--              EnteredLocationName is where the LOT was first put (its earliest
--              LotMovement), falling back to where it is now.
--
--              FDS-11-011: no OUTPUT params; single result set, always emitted;
--              empty set = not entered before. Newest first, TOP 5;
--              TotalMatches carries the full count.
--
-- Change Log:
--   2026-10-07 - 1.0 - Initial version.
-- ============================================================
CREATE OR ALTER PROCEDURE Lots.Lot_ListByVendorLot
    @VendorLotNumber NVARCHAR(100)
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @V NVARCHAR(100) = NULLIF(LTRIM(RTRIM(@VendorLotNumber)), N'');
    IF @V = N'NONE' SET @V = NULL;

    SELECT TOP 5
        l.Id                                    AS LotId,
        l.LotName                               AS LotName,
        l.VendorLotNumber                       AS VendorLotNumber,
        i.Id                                    AS ItemId,
        i.PartNumber                            AS PartNumber,
        ISNULL(i.Description, i.PartNumber)     AS ItemDescription,
        ISNULL(el.Name, cl.Name)                AS EnteredLocationName,
        cl.Name                                 AS CurrentLocationName,
        CAST(l.CreatedAt AT TIME ZONE 'UTC' AT TIME ZONE 'Eastern Standard Time' AS DATETIME2(3)) AS EnteredAt,
        l.PieceCount                            AS PieceCount,
        sc.Code                                 AS LotStatusCode,
        COUNT(*) OVER ()                        AS TotalMatches
    FROM Lots.Lot l
    INNER JOIN Parts.Item i          ON i.Id  = l.ItemId
    INNER JOIN Lots.LotStatusCode sc ON sc.Id = l.LotStatusId
    INNER JOIN Location.Location cl  ON cl.Id = l.CurrentLocationId
    OUTER APPLY (
        SELECT TOP 1 loc.Name
        FROM Lots.LotMovement m
        INNER JOIN Location.Location loc ON loc.Id = m.ToLocationId
        WHERE m.LotId = l.Id
        ORDER BY m.MovedAt ASC, m.Id ASC
    ) el
    WHERE @V IS NOT NULL
      AND l.VendorLotNumber = @V
    ORDER BY l.CreatedAt DESC, l.Id DESC;
END;
GO
