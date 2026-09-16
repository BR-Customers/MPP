-- ============================================================
-- Migration:   0087_defectcode_area_scoped_codes.sql
-- Author:      Blue Ridge Automation
-- Created:     2026-09-15
-- Description: Makes Quality.DefectCode hold every reject code printed on the
--              three shop-floor sheets, each under the area whose sheet prints
--              it, with the code exactly as printed.
--
--                DCFM-0485 v18  Die Cast              36 codes
--                TSFM-0085 v7   Trim Shop             36 codes
--                line sheet     Machining & Assembly  33 codes
--                                                    ----
--                                                     105 rows
--
--              NO CODE IS RENUMBERED. The numbers live in systems outside the
--              MES and are honoured exactly as printed.
--
--              The grouping is the FK that already exists:
--              OperationCategoryId. The only thing blocking this was
--              UQ_DefectCode_Code being GLOBAL -- those 105 rows carry just 86
--              distinct numbers, because 17 codes are printed on more than one
--              sheet, and 133 / 134 appear twice on the M&A sheet alone (once
--              charged to Die Cast, once to the Machine Shop). So the key
--              becomes (OperationCategoryId, ChargeToPartyId, Code), which is
--              unique across all 105.
--
--              Also strips the 'DC - ' description prefix from migration 0086.
--              That hit all 59 die-cast-CHARGED codes when the M&A sheet lists
--              17; attribution belongs in ChargeToPartyId, which this migration
--              sets per row, not in the label.
--
--              Set-based and id-free, so it behaves the same on Dev, ProdSim
--              and Prod. Nothing is deleted -- codes the database holds that no
--              sheet claims are left exactly as they are. Re-running is a
--              no-op.
--
-- Change Log:
--   2026-09-15 - 1.0 - Initial version
-- ============================================================

SET XACT_ABORT ON;

-- ---- 1. Undo 0086's blanket description prefix ----
UPDATE Quality.DefectCode
   SET Description = SUBSTRING(Description, 6, LEN(Description) - 5)
 WHERE Description LIKE N'DC - %';
GO

-- ---- 2. Re-key: a code is unique per (area, charge-to), not plant-wide ----
IF EXISTS (SELECT 1 FROM sys.key_constraints WHERE name = N'UQ_DefectCode_Code')
    ALTER TABLE Quality.DefectCode DROP CONSTRAINT UQ_DefectCode_Code;
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'UQ_DefectCode_Area_Charge_Code')
    CREATE UNIQUE INDEX UQ_DefectCode_Area_Charge_Code
        ON Quality.DefectCode (OperationCategoryId, ChargeToPartyId, Code);
GO

-- ---- 3. The three sheets, one row per printed line ----
DECLARE @Sheet TABLE (Area NVARCHAR(30), ChargeTo NVARCHAR(30),
                      Code NVARCHAR(20), Descr NVARCHAR(500));

INSERT INTO @Sheet (Area, ChargeTo, Code, Descr) VALUES
(N'DieCast', N'DieCast', N'001', N'Soldering'),
(N'DieCast', N'DieCast', N'002', N'Broken/Bent Pin'),
(N'DieCast', N'DieCast', N'004', N'Trim Damage'),
(N'DieCast', N'DieCast', N'005', N'Flatness/Bent Parts'),
(N'DieCast', N'DieCast', N'006', N'Breakout (Broken Die)'),
(N'DieCast', N'DieCast', N'007', N'Broken Gate'),
(N'DieCast', N'DieCast', N'008', N'Test Part'),
(N'DieCast', N'DieCast', N'009', N'Blisters'),
(N'DieCast', N'DieCast', N'010', N'Stuck Part / Stuck Piece'),
(N'DieCast', N'DieCast', N'011', N'Flow Lines'),
(N'DieCast', N'DieCast', N'012', N'Flash'),
(N'DieCast', N'DieCast', N'015', N'Short Shot'),
(N'DieCast', N'DieCast', N'024', N'Raised/Recessed Ejector Pins'),
(N'DieCast', N'DieCast', N'025', N'No Good Date Pin'),
(N'DieCast', N'DieCast', N'026', N'Egg-shaped Hole'),
(N'DieCast', N'DieCast', N'027', N'Porosity in Gate Area'),
(N'DieCast', N'DieCast', N'029', N'Cracks'),
(N'DieCast', N'DieCast', N'030', N'Dimensional'),
(N'DieCast', N'DieCast', N'032', N'Galling/Drags'),
(N'DieCast', N'DieCast', N'040', N'Grease/Oil Contamination'),
(N'DieCast', N'DieCast', N'041', N'Holes Not Punched/Flash in Bolt Holes'),
(N'DieCast', N'DieCast', N'042', N'Flaking'),
(N'DieCast', N'DieCast', N'044', N'Chipped Bolt Pad'),
(N'DieCast', N'DieCast', N'045', N'Over File'),
(N'DieCast', N'DieCast', N'051', N'Robot Dropping Parts'),
(N'DieCast', N'DieCast', N'052', N'Hit Damage/Dents'),
(N'DieCast', N'DieCast', N'053', N'Computer reject/Low Speed'),
(N'DieCast', N'DieCast', N'054', N'Computer reject/High Speed'),
(N'DieCast', N'DieCast', N'055', N'Computer reject/Cycle time'),
(N'DieCast', N'DieCast', N'056', N'Computer reject/Cast Pressure'),
(N'DieCast', N'DieCast', N'057', N'Computer reject/Biscuit Size'),
(N'DieCast', N'DieCast', N'058', N'Computer reject/Rise up time'),
(N'DieCast', N'DieCast', N'059', N'Computer reject/High Speed Length'),
(N'DieCast', N'DieCast', N'060', N'Computer reject/Press up time'),
(N'DieCast', N'DieCast', N'062', N'Inventory Balance'),
(N'DieCast', N'DieCast', N'257', N'QR Code Reject'),
(N'Trim', N'TrimShop', N'100', N'Soldering'),
(N'Trim', N'TrimShop', N'103', N'Trim Damage'),
(N'Trim', N'TrimShop', N'104', N'Bent Part (Air Gap)'),
(N'Trim', N'TrimShop', N'105', N'Broken Die (Breakout)'),
(N'Trim', N'TrimShop', N'106', N'Broken Gate'),
(N'Trim', N'TrimShop', N'107', N'Test Part'),
(N'Trim', N'TrimShop', N'108', N'Blisters'),
(N'Trim', N'TrimShop', N'109', N'Stuck Part/ Stuck Piece'),
(N'Trim', N'TrimShop', N'110', N'Flow Lines'),
(N'Trim', N'TrimShop', N'111', N'Flash'),
(N'Trim', N'TrimShop', N'112', N'Short Shot'),
(N'Trim', N'TrimShop', N'113', N'Broken Post'),
(N'Trim', N'TrimShop', N'117', N'Raised/ Recessed Ejector Pins'),
(N'Trim', N'TrimShop', N'118', N'No Good Date Pin'),
(N'Trim', N'TrimShop', N'119', N'Egg-shaped Hole'),
(N'Trim', N'TrimShop', N'120', N'Porosity in Gate'),
(N'Trim', N'TrimShop', N'121', N'Crack'),
(N'Trim', N'TrimShop', N'125', N'Drags'),
(N'Trim', N'TrimShop', N'126', N'Contamination (Grease/Oil)'),
(N'Trim', N'TrimShop', N'127', N'Holes Not Punched'),
(N'Trim', N'TrimShop', N'128', N'Flaking'),
(N'Trim', N'TrimShop', N'129', N'Chipped Bolt Pad'),
(N'Trim', N'TrimShop', N'130', N'Over File'),
(N'Trim', N'TrimShop', N'131', N'Flash in Bolt Hole'),
(N'Trim', N'TrimShop', N'133', N'Hit Damage'),
(N'Trim', N'TrimShop', N'134', N'Discoloration'),
(N'Trim', N'TrimShop', N'140', N'Stuck Media'),
(N'Trim', N'TrimShop', N'142', N'NG Blast/ NG Tumble'),
(N'Trim', N'TrimShop', N'143', N'Surface Roughness'),
(N'Trim', N'TrimShop', N'144', N'White Rust'),
(N'Trim', N'TrimShop', N'145', N'Drill damage (Broken Drill Bit)'),
(N'Trim', N'TrimShop', N'147', N'Cycle Stop'),
(N'Trim', N'TrimShop', N'162', N'Misset'),
(N'Trim', N'TrimShop', N'163', N'Chamfer No Good'),
(N'Trim', N'TrimShop', N'197', N'Lamination'),
(N'Trim', N'TrimShop', N'244', N'Dents'),
(N'MachiningAssembly', N'DieCast', N'108', N'Blister'),
(N'MachiningAssembly', N'DieCast', N'105', N'Break Out'),
(N'MachiningAssembly', N'DieCast', N'121', N'Cracks'),
(N'MachiningAssembly', N'DieCast', N'104', N'Bent Part'),
(N'MachiningAssembly', N'DieCast', N'134', N'Discolor'),
(N'MachiningAssembly', N'DieCast', N'128', N'Flaking'),
(N'MachiningAssembly', N'DieCast', N'110', N'Flowlines'),
(N'MachiningAssembly', N'DieCast', N'106', N'Broken Gate'),
(N'MachiningAssembly', N'DieCast', N'136', N'Hard spot'),
(N'MachiningAssembly', N'DieCast', N'107', N'D/C Test Parts'),
(N'MachiningAssembly', N'DieCast', N'133', N'Nicks/Dents (Body Damage)'),
(N'MachiningAssembly', N'DieCast', N'197', N'Lamination'),
(N'MachiningAssembly', N'DieCast', N'135', N'Porosity'),
(N'MachiningAssembly', N'DieCast', N'100', N'Solder'),
(N'MachiningAssembly', N'DieCast', N'142', N'N/G Shotblast'),
(N'MachiningAssembly', N'DieCast', N'103', N'Trim Press Damage'),
(N'MachiningAssembly', N'DieCast', N'144', N'White Rust'),
(N'MachiningAssembly', N'MachineShop', N'146', N'Chatter'),
(N'MachiningAssembly', N'MachineShop', N'147', N'Cycle Stop'),
(N'MachiningAssembly', N'MachineShop', N'122', N'Dimension'),
(N'MachiningAssembly', N'MachineShop', N'134', N'Discolor'),
(N'MachiningAssembly', N'MachineShop', N'148', N'Dropped'),
(N'MachiningAssembly', N'MachineShop', N'149', N'Flatness No Good'),
(N'MachiningAssembly', N'MachineShop', N'150', N'Hole Size No Good'),
(N'MachiningAssembly', N'MachineShop', N'143', N'Surface Roughness'),
(N'MachiningAssembly', N'MachineShop', N'170', N'Machine Trial'),
(N'MachiningAssembly', N'MachineShop', N'133', N'Scratches/Nicks/Dents'),
(N'MachiningAssembly', N'MachineShop', N'138', N'Non Clean Up'),
(N'MachiningAssembly', N'MachineShop', N'151', N'Thickness No good'),
(N'MachiningAssembly', N'MachineShop', N'152', N'Threads No Good'),
(N'MachiningAssembly', N'MachineShop', N'153', N'Tool Break'),
(N'MachiningAssembly', N'MachineShop', N'154', N'Tool Mark'),
(N'MachiningAssembly', N'MachineShop', N'224', N'Out of Sequence');

DECLARE @Want TABLE (OperationCategoryId BIGINT, ChargeToPartyId BIGINT,
                     Code NVARCHAR(20), Descr NVARCHAR(500));

INSERT INTO @Want (OperationCategoryId, ChargeToPartyId, Code, Descr)
SELECT oc.Id, cp.Id, s.Code, s.Descr
  FROM @Sheet s
  JOIN Parts.OperationCategory oc ON oc.Code = s.Area
  JOIN Quality.ChargeToParty   cp ON cp.Code = s.ChargeTo;

IF (SELECT COUNT(*) FROM @Want) <> (SELECT COUNT(*) FROM @Sheet)
    RAISERROR(N'0087: an OperationCategory or ChargeToParty code did not resolve.', 16, 1);

-- 3a. Already filed correctly -- make the wording match the paper.
UPDATE dc SET Description = w.Descr
  FROM Quality.DefectCode dc
  JOIN @Want w ON w.OperationCategoryId = dc.OperationCategoryId
               AND w.ChargeToPartyId    = dc.ChargeToPartyId
               AND w.Code               = dc.Code
 WHERE dc.Description <> w.Descr;
PRINT '0087: ' + CAST(@@ROWCOUNT AS NVARCHAR(10)) + ' description(s) matched to the sheet.';

-- 3b. Everything the sheet prints that the table does not hold for that area.
INSERT INTO Quality.DefectCode (Code, Description, OperationCategoryId, ChargeToPartyId, IsExcused)
SELECT w.Code, w.Descr, w.OperationCategoryId, w.ChargeToPartyId, 0
  FROM @Want w
 WHERE NOT EXISTS (SELECT 1 FROM Quality.DefectCode dc
                    WHERE dc.OperationCategoryId = w.OperationCategoryId
                      AND dc.ChargeToPartyId     = w.ChargeToPartyId
                      AND dc.Code                = w.Code);
PRINT '0087: ' + CAST(@@ROWCOUNT AS NVARCHAR(10)) + ' code(s) added.';
GO

-- ---- 4. Record migration ----
IF NOT EXISTS (SELECT 1 FROM dbo.SchemaVersion WHERE MigrationId = N'0087_defectcode_area_scoped_codes')
    INSERT INTO dbo.SchemaVersion (MigrationId, Description)
    VALUES (N'0087_defectcode_area_scoped_codes',
            N'Quality.DefectCode carries all 105 codes printed on DCFM-0485 v18, TSFM-0085 v7 and the M&A line production sheet, one row per printed line, grouped by the existing OperationCategoryId FK. Global UQ_DefectCode_Code replaced by UQ_DefectCode_Area_Charge_Code on (OperationCategoryId, ChargeToPartyId, Code) -- 105 rows carry 86 distinct numbers. No code renumbered, nothing deleted. 0086 description prefix removed.');
GO
PRINT 'Migration 0087 (defectcode_area_scoped_codes) applied.';
