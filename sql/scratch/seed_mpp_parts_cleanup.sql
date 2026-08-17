-- ============================================================
-- Script:      seed_mpp_parts_cleanup.sql
-- Author:      Blue Ridge Automation
-- Date:        2026-08-13
-- Description: Companion to seed_mpp_parts.sql. Leaves MPP_MES_Dev holding the
--              customer part list and nothing else.
--
--              (1) Overwrites the 5 part numbers shared with the 13-part demo
--                  matrix (020_seed_items.sql) to MPP's own wording. The seed is
--                  deliberately INSERT-only and skipped these, so they kept demo
--                  descriptions like "59B Cam Holder IN #1 Casting".
--
--              (2) DEPRECATES the 10 items that are NOT on the customer list,
--                  plus their eligibility / container config / routes, so they
--                  drop out of the Item Master (Parts.Item_List filters
--                  DeprecatedAt IS NULL unless @IncludeDeprecated = 1).
--
--              *** SOFT delete, deliberately -- NOT a DELETE. ***
--              6 of the 10 carry live LOTs (19 of Dev's 24), including the 2 on
--              11200-6FB -A000 that hold the PROVEN AIM post-back evidence
--              (serial 000000034 / 112006FB A000, 2026-08-05). A hard DELETE
--              would need those LOTs destroyed first, taking the AIM evidence
--              and the demo genealogy with them. Deprecating hides the parts
--              while preserving all of it, and is fully reversible -- see the
--              UNDO block at the bottom of this file.
--
--              Verified before writing: none of the 10 is a BOM child or parent
--              of any customer item, so nothing on MPP's list is affected.
--
--              Idempotent. ASCII-only.
-- ============================================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

-- ============================================================
-- (1) Customer wording for the 5 shared part numbers.
--     Description only. MaxLotSize / DefaultSubLotQty are intentionally left
--     alone: the demo carries real values (15/30) where MPP's workbook is blank,
--     so overwriting would replace configuration with NULL.
-- ============================================================
DECLARE @W TABLE (Pn NVARCHAR(50), Descr NVARCHAR(500));
INSERT INTO @W (Pn, Descr) VALUES
 (N'12231-59B-0000', N'59B Cam Holder In #1'),
 (N'12232-59B-0000', N'59B Cam Holder In #2'),
 (N'12241-59B-0000', N'59B Cam Holder Ex #1'),
 (N'92900-06014-1B', N'6x14 Stud Bolt'),
 (N'94301-08100',    N'8x10 Dowel Pin');

UPDATE i SET i.Description = w.Descr, i.UpdatedAt = SYSUTCDATETIME()
FROM Parts.Item i JOIN @W w ON w.Pn = i.PartNumber
WHERE i.Description <> w.Descr OR i.Description IS NULL;
PRINT 'cleanup: descriptions rewritten -> ' + CAST(@@ROWCOUNT AS VARCHAR(10));
GO

-- ============================================================
-- (2) Deprecate the 10 non-customer items and their config.
-- ============================================================
DECLARE @D TABLE (Pn NVARCHAR(50));
INSERT INTO @D (Pn) VALUES
 (N'11200-6FB -A000'),   -- AIM post-back test part (LOTs + AIM evidence preserved)
 (N'1223A-59B -A0002'),  -- demo 59B set; MPP's real number is 1223A-59B-A000
 (N'12270-6NA'),
 (N'12270-6NA -0001'),
 (N'12270-6NA-M'),
 (N'21001 pin'),
 (N'5G0-FG'),
 (N'5G0-SA'),
 (N'5G0-c'),
 (N'90701-5R0-3000');    -- demo dowel (digit zero); MPP's is 90701-5RO-3000 (letter O)

DECLARE @Now DATETIME2(3) = SYSUTCDATETIME();

UPDATE il SET il.DeprecatedAt = @Now
FROM Parts.ItemLocation il JOIN Parts.Item i ON i.Id = il.ItemId JOIN @D d ON d.Pn = i.PartNumber
WHERE il.DeprecatedAt IS NULL;
PRINT 'cleanup: ItemLocation deprecated   -> ' + CAST(@@ROWCOUNT AS VARCHAR(10));

UPDATE cc SET cc.DeprecatedAt = @Now
FROM Parts.ContainerConfig cc JOIN Parts.Item i ON i.Id = cc.ItemId JOIN @D d ON d.Pn = i.PartNumber
WHERE cc.DeprecatedAt IS NULL;
PRINT 'cleanup: ContainerConfig deprecated-> ' + CAST(@@ROWCOUNT AS VARCHAR(10));

-- Deprecating the route makes any open LOT on these parts inert: the WIP queue
-- joins rt.PublishedAt IS NOT NULL AND rt.DeprecatedAt IS NULL, so those LOTs
-- stop appearing in every shop-floor queue. Intended -- they are demo LOTs and
-- the parts are being retired -- but it IS a shop-floor behaviour change.
UPDATE rt SET rt.DeprecatedAt = @Now
FROM Parts.RouteTemplate rt JOIN Parts.Item i ON i.Id = rt.ItemId JOIN @D d ON d.Pn = i.PartNumber
WHERE rt.DeprecatedAt IS NULL;
PRINT 'cleanup: RouteTemplate deprecated  -> ' + CAST(@@ROWCOUNT AS VARCHAR(10));

UPDATE b SET b.DeprecatedAt = @Now
FROM Parts.Bom b JOIN Parts.Item i ON i.Id = b.ParentItemId JOIN @D d ON d.Pn = i.PartNumber
WHERE b.DeprecatedAt IS NULL;
PRINT 'cleanup: Bom deprecated            -> ' + CAST(@@ROWCOUNT AS VARCHAR(10));

UPDATE i SET i.DeprecatedAt = @Now, i.UpdatedAt = @Now
FROM Parts.Item i JOIN @D d ON d.Pn = i.PartNumber
WHERE i.DeprecatedAt IS NULL;
PRINT 'cleanup: Item deprecated           -> ' + CAST(@@ROWCOUNT AS VARCHAR(10));
GO

PRINT 'cleanup: done.';
GO

-- ============================================================
-- UNDO -- restores all 10 items and their config. Nothing was destroyed.
-- ============================================================
/*
DECLARE @D TABLE (Pn NVARCHAR(50));
INSERT INTO @D (Pn) VALUES (N'11200-6FB -A000'),(N'1223A-59B -A0002'),(N'12270-6NA'),
 (N'12270-6NA -0001'),(N'12270-6NA-M'),(N'21001 pin'),(N'5G0-FG'),(N'5G0-SA'),(N'5G0-c'),(N'90701-5R0-3000');
UPDATE i  SET i.DeprecatedAt  = NULL FROM Parts.Item i JOIN @D d ON d.Pn = i.PartNumber;
UPDATE il SET il.DeprecatedAt = NULL FROM Parts.ItemLocation il    JOIN Parts.Item i ON i.Id=il.ItemId       JOIN @D d ON d.Pn=i.PartNumber;
UPDATE cc SET cc.DeprecatedAt = NULL FROM Parts.ContainerConfig cc JOIN Parts.Item i ON i.Id=cc.ItemId       JOIN @D d ON d.Pn=i.PartNumber;
UPDATE rt SET rt.DeprecatedAt = NULL FROM Parts.RouteTemplate rt   JOIN Parts.Item i ON i.Id=rt.ItemId       JOIN @D d ON d.Pn=i.PartNumber;
UPDATE b  SET b.DeprecatedAt  = NULL FROM Parts.Bom b              JOIN Parts.Item i ON i.Id=b.ParentItemId  JOIN @D d ON d.Pn=i.PartNumber;
*/
