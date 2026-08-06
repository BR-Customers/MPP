-- =============================================
-- Migration:   0054_drop_item_aim_customer_part.sql
-- Author:      Blue Ridge Automation
-- Date:        2026-08-04
-- Description: Removes Parts.Item.AimCustomerPartNumber and its two accessor
--              procs. Live testing against MPP's AIM server this week proved the
--              AIM Customer Part is DERIVABLE from Parts.Item.PartNumber -- it is
--              not an independent fact that must be sourced from AIM and
--              maintained by a human, as migration 0052 assumed:
--
--                Value sent to AIM         Result
--                11200-6FB-A00              Blanket not found
--                112006FBA00                 Blanket not found
--                112006FB A000               posted, label created  <-
--
--              The legacy MES material name for that part is '11200-6FB -A000'.
--              Strip the dashes and the result is '112006FB A000' exactly -- the
--              value that worked, and precisely what the legacy Base2 code did
--              (partName.Replace("-", "")) before writing its CSV row. See
--              notes/2026-07-28_aim-interface-contract.md and
--              Parts.ufn_AimCustomerPartNumber (new in this same commit) for the
--              full evidence and the one known irregular part the rule can't cover.
--
--              A stored per-item column that must be filled in by a human is now
--              strictly worse than a derived value: it can drift from PartNumber,
--              it can be left blank, and the whole "config-gap" self-heal
--              machinery in AimShipperIdPool_GetForPost / _ListUnposted existed
--              only to work around it being sometimes unset.
--
--              COORDINATED WITH (same commit):
--                - R__Parts_ufn_AimCustomerPartNumber.sql          -- NEW, the derivation
--                - R__Parts_Item_GetAimCustomerPartNumber.sql      -- DELETED
--                - R__Parts_Item_SetAimCustomerPartNumber.sql      -- DELETED
--                - R__Lots_Container_Complete.sql                  -- @PostPart now calls the ufn
--                - R__Lots_AimShipperIdPool_GetForPost.sql         -- COALESCE source is the ufn
--                - R__Lots_AimShipperIdPool_ListUnposted.sql       -- COALESCE source is the ufn
--                - ignition Item Master Identity view              -- AIM Customer Part field removed
--                - ignition BlueRidge.Parts.Item                   -- get/setAimCustomerPartNumber removed
--                - ignition BlueRidge.Lots.AimPost                 -- no_customer_part outcome removed
--                  (PartNumber is NOT NULL, so the derived value can never be
--                  missing for a configured item)
--
--              Idempotent-guarded; no explicit transaction (repo convention, see
--              0036_drop_coupled_downstream_cell.sql).
-- =============================================

IF OBJECT_ID(N'Parts.Item_GetAimCustomerPartNumber') IS NOT NULL
    DROP PROCEDURE Parts.Item_GetAimCustomerPartNumber;
GO

IF OBJECT_ID(N'Parts.Item_SetAimCustomerPartNumber') IS NOT NULL
    DROP PROCEDURE Parts.Item_SetAimCustomerPartNumber;
GO

-- Drop any default constraint on the column before dropping the column itself
-- (migration 0052 added it with no DEFAULT, so this is normally a no-op, but a
-- column cannot be dropped while a default constraint still references it).
DECLARE @df SYSNAME = (
    SELECT dc.name FROM sys.default_constraints dc
    INNER JOIN sys.columns c ON c.object_id = dc.parent_object_id AND c.column_id = dc.parent_column_id
    WHERE dc.parent_object_id = OBJECT_ID(N'Parts.Item') AND c.name = N'AimCustomerPartNumber');
IF @df IS NOT NULL EXEC(N'ALTER TABLE Parts.Item DROP CONSTRAINT ' + @df);
GO

IF COL_LENGTH(N'Parts.Item', N'AimCustomerPartNumber') IS NOT NULL
    ALTER TABLE Parts.Item DROP COLUMN AimCustomerPartNumber;
GO

IF NOT EXISTS (SELECT 1 FROM dbo.SchemaVersion WHERE MigrationId = N'0054_drop_item_aim_customer_part')
    INSERT INTO dbo.SchemaVersion (MigrationId, Description)
    VALUES (N'0054_drop_item_aim_customer_part',
        N'Drop Parts.Item.AimCustomerPartNumber + its Get/Set accessor procs -- the AIM customer part is now derived from Item.PartNumber via Parts.ufn_AimCustomerPartNumber (dash-strip), proven against live AIM testing 2026-08-04.');
GO

PRINT 'Migration 0054 (drop_item_aim_customer_part) applied.';
GO
