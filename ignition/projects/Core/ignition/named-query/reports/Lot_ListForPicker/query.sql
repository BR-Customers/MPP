-- Recent LOTs for the Reports landing-page LOT picker (Lot Detail report).
-- Returns human label ("000000001 - 12231-59B-0000") + the internal LotId value.
--
-- TOP 100 is deliberate and is NOT the only way to reach a LOT: this is a
-- convenience list of what is currently in flight. Any LOT of any age is
-- reachable by scanning or typing its LTT name into the same field
-- (allowCustomOptions), which BlueRidge.Reports._resolveLotId resolves by name.
-- Widening this list would only move the wall further out, not remove it.
SELECT TOP 100
    l.Id AS value,
    l.LotName + ' - ' + i.PartNumber AS label
FROM Lots.Lot l
JOIN Parts.Item i ON i.Id = l.ItemId
ORDER BY l.CreatedAt DESC;
