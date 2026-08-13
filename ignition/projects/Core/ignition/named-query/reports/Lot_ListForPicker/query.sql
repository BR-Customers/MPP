-- Recent LOTs for the Reports landing-page LOT picker (Lot Detail report).
-- Returns human label ("000000001 - 12231-59B-0000") + the internal LotId value.
SELECT TOP 100
    l.Id AS value,
    l.LotName + ' - ' + i.PartNumber AS label
FROM Lots.Lot l
JOIN Parts.Item i ON i.Id = l.ItemId
ORDER BY l.CreatedAt DESC;
