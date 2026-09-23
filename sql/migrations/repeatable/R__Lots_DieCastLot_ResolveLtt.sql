-- ============================================================
-- Repeatable:  R__Lots_DieCastLot_ResolveLtt.sql
-- Author:      Blue Ridge Automation
-- Created:     2026-09-22
-- Version:     1.0
-- Description: What happens if this LTT is added to this die's reconciliation
--              (spec 2026-09-21 sec 6.3). Called as the team lead scans or
--              types each LTT off the physical LOT, so the answer arrives at
--              the field and never at the save:
--
--                New        -- not in the MES and a valid 8-9 digit LTT: a new
--                              LOT, created and released to Warehouse at save;
--                OnThisDie  -- already a LOT on this die: adds to that LOT;
--                Elsewhere  -- a LOT on another press or die, or not a die cast
--                              LOT at all: refused, naming where it belongs;
--                Invalid    -- not an LTT.
--
--              ONE result set with the same shape on every branch (the screen
--              binds one table). A die is named name-first, then Asset #.
-- ============================================================
CREATE OR ALTER PROCEDURE Lots.DieCastLot_ResolveLtt
    @Ltt    NVARCHAR(50),
    @ToolId BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    SET @Ltt = LTRIM(RTRIM(ISNULL(@Ltt, N'')));

    IF NOT EXISTS (SELECT 1 FROM Lots.Lot WHERE LotName = @Ltt)
    BEGIN
        DECLARE @Valid BIT = Lots.ufn_IsValidExternalLtt(@Ltt);
        SELECT @Ltt AS Ltt,
               CASE WHEN @Valid = 1 THEN N'New' ELSE N'Invalid' END AS Result,
               CAST(NULL AS BIGINT) AS LotId, CAST(NULL AS BIGINT) AS ToolCavityId,
               CAST(NULL AS NVARCHAR(10)) AS CavityCode, CAST(NULL AS BIGINT) AS ItemId,
               CAST(NULL AS NVARCHAR(50)) AS PartNumber, CAST(NULL AS INT) AS PieceCount,
               CASE WHEN @Valid = 1 THEN N'New LOT ' + @Ltt + N' -- created and released to Warehouse when you save.'
                    ELSE N'An LTT is 8 or 9 digits. Check the number on the ticket.' END AS Message;
        RETURN;
    END

    SELECT l.LotName AS Ltt,
           CASE WHEN l.ToolId = @ToolId THEN N'OnThisDie' ELSE N'Elsewhere' END AS Result,
           l.Id AS LotId, l.ToolCavityId, tc.CavityCode, l.ItemId, i.PartNumber, l.PieceCount,
           CASE
               WHEN l.ToolId = @ToolId
                   THEN l.LotName + N' is already on this die, cavity ' + ISNULL(tc.CavityCode, N'?')
                        + N' -- its actual adds to that LOT.'
               WHEN l.ToolId IS NULL
                   THEN l.LotName + N' is ' + ISNULL(i.PartNumber, N'another part') + N' at '
                        + ISNULL(cl.Name, N'an unknown location') + N', not a die cast LOT.'
               ELSE l.LotName + N' is ' + ISNULL(pl.Name, N'another press') + N' ' + Audit.ufn_MidDot() + N' '
                    + ot.Name + N' (Asset # ' + ot.Code + N')'
                    + ISNULL(N', cavity ' + tc.CavityCode, N'') + N'.'
           END AS Message
    FROM Lots.Lot l
    LEFT JOIN Parts.Item i ON i.Id = l.ItemId
    LEFT JOIN Tools.ToolCavity tc ON tc.Id = l.ToolCavityId
    LEFT JOIN Tools.Tool ot ON ot.Id = l.ToolId
    LEFT JOIN Location.Location cl ON cl.Id = l.CurrentLocationId
    OUTER APPLY (SELECT TOP 1 x.Name FROM (
                     SELECT loc.Name, 1 AS Pri FROM Location.Location loc WHERE loc.Id = l.ProducedAtLocationId
                     UNION ALL
                     SELECT loc.Name, 2 FROM Workorder.DieCastContribution c
                       INNER JOIN Location.Location loc ON loc.Id = c.CellLocationId WHERE c.LotId = l.Id
                     UNION ALL
                     SELECT loc.Name, 3 FROM Tools.ToolAssignment ta
                       INNER JOIN Location.Location loc ON loc.Id = ta.CellLocationId
                       WHERE ta.ToolId = l.ToolId AND ta.ReleasedAt IS NULL) x
                 ORDER BY x.Pri) pl
    WHERE l.LotName = @Ltt;
END;
GO
