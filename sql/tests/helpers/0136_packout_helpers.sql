-- =============================================
-- Helper: test.ContainerConfigInsert (view + INSTEAD OF INSERT trigger)
-- Created: 2026-11-20 (migration 0136, named pack-outs)
--
-- Test fixtures used to INSERT straight into Parts.ContainerConfig. Since 0136
-- every config row is a VERSION of a Parts.PackOut header (PackOutId +
-- VersionNumber NOT NULL). Fixtures insert into this view instead, with the
-- column list they always used; the trigger finds or creates the part's active
-- header for the method (named after the method, default when it is the first
-- active one) and inserts the next version. TEST SCHEMA ONLY -- production
-- writes go through Parts.PackOut_Save.
--
-- SCOPE_IDENTITY() is NULL after an INSTEAD OF insert: read the new config by
-- (ItemId, ClosureMethod, DeprecatedAt IS NULL).
-- =============================================
CREATE OR ALTER VIEW test.ContainerConfigInsert
AS
SELECT Id, ItemId, TraysPerContainer, PartsPerTray, IsSerialized, DunnageCode, CustomerCode,
       ClosureMethod, TargetWeight, ToleranceWeight, CreatedAt, DeprecatedAt
FROM Parts.ContainerConfig;
GO

CREATE OR ALTER TRIGGER test.trg_ContainerConfigInsert ON test.ContainerConfigInsert
INSTEAD OF INSERT
AS
BEGIN
    SET NOCOUNT ON;

    -- Headers for (item, method) pairs with no active header yet.
    INSERT INTO Parts.PackOut (ItemId, ClosureMethod, Name, IsDefault, CreatedByUserId)
    SELECT d.ItemId, d.ClosureMethod, m.Name,
           CASE WHEN EXISTS (SELECT 1 FROM Parts.PackOut x WHERE x.ItemId = d.ItemId AND x.ClosureMethod = d.ClosureMethod
                             AND x.IsDefault = 1 AND x.DeprecatedAt IS NULL) THEN 0 ELSE 1 END,
           1
    FROM (SELECT DISTINCT ItemId, ISNULL(ClosureMethod, N'ByCount') AS ClosureMethod FROM inserted) d
    JOIN Parts.ClosureMethodCode m ON m.Code = d.ClosureMethod
    WHERE NOT EXISTS (SELECT 1 FROM Parts.PackOut p WHERE p.ItemId = d.ItemId AND p.ClosureMethod = d.ClosureMethod
                      AND p.Name = m.Name AND p.DeprecatedAt IS NULL);

    INSERT INTO Parts.ContainerConfig (ItemId, ClosureMethod, PackOutId, VersionNumber, TraysPerContainer, PartsPerTray,
                                       IsSerialized, DunnageCode, CustomerCode, TargetWeight, ToleranceWeight,
                                       CreatedAt, DeprecatedAt, CreatedByUserId)
    SELECT i.ItemId, ISNULL(i.ClosureMethod, N'ByCount'), p.Id,
           ISNULL((SELECT MAX(v.VersionNumber) FROM Parts.ContainerConfig v WHERE v.PackOutId = p.Id), 0)
             + ROW_NUMBER() OVER (PARTITION BY p.Id ORDER BY (SELECT NULL)),
           i.TraysPerContainer, i.PartsPerTray, ISNULL(i.IsSerialized, 0), i.DunnageCode, i.CustomerCode,
           i.TargetWeight, i.ToleranceWeight, ISNULL(i.CreatedAt, SYSUTCDATETIME()), i.DeprecatedAt, 1
    FROM inserted i
    JOIN Parts.ClosureMethodCode m ON m.Code = ISNULL(i.ClosureMethod, N'ByCount')
    JOIN Parts.PackOut p ON p.ItemId = i.ItemId AND p.ClosureMethod = m.Code AND p.Name = m.Name AND p.DeprecatedAt IS NULL;
END;
GO
