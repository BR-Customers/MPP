-- ============================================================
-- Seed:        030_seed_defect_codes.sql
-- Author:      Blue Ridge Automation
-- Date:        2026-06-29
-- Description: FDS-08-016 -- load the 153 FRS Appendix E defect codes into
--              Quality.DefectCode (these were never seeded -> the reject-code
--              dropdown was empty). Source: reference/seed_data/defect_codes.csv.
--              Codes are scoped by Parts.OperationCategory (not physical Area):
--                Die Cast      -> DieCast            Machine Shop -> MachiningAssembly
--                Trim Shop     -> Trim               HSP / Prod. Control / Quality Control / logistics -> NULL (plant-wide)
--              A NULL OperationCategoryId means the code applies plant-wide
--              (shows on every reject screen). MPP can reclassify the plant-wide
--              bucket later (FDS-08-017 stays the refinement vehicle).
--              Plus MPP-added codes numbered from 260 (see the inline note at
--              the end of the table -- 2026-09-10, migration 0075).
--              OperationCategoryId resolved by Code at apply time. Idempotent on
--              UQ_DefectCode_Code (insert-where-not-exists). ASCII-only.
-- ============================================================

SET NOCOUNT ON;

DECLARE @DieCast BIGINT = (SELECT Id FROM Parts.OperationCategory WHERE Code = N'DieCast');
DECLARE @Trim    BIGINT = (SELECT Id FROM Parts.OperationCategory WHERE Code = N'Trim');
DECLARE @MachAsm BIGINT = (SELECT Id FROM Parts.OperationCategory WHERE Code = N'MachiningAssembly');
-- Plant-wide codes (shipping / labels / ISO / inventory) use NULL.

DECLARE @Defects TABLE (Code NVARCHAR(20), Description NVARCHAR(500), OperationCategoryId BIGINT, IsExcused BIT);

INSERT INTO @Defects (Code, Description, OperationCategoryId, IsExcused) VALUES
-- Codes 001-015: the die cast sheet (DCFM-0485) numbering, which is what
-- MPP_MES_Prod carries. These were seeded 100-112 until 2026-09-15 -- the
-- TRIM sheet's numbers for the same defects -- which meant a Dev reset could
-- not reproduce prod. Note 015 (not 013): MPP retires numbers permanently,
-- so the gaps are real and must not be closed up.
(N'001', N'Soldering', @DieCast, 0),
(N'002', N'Broken/Bent Pin', @DieCast, 0),
(N'003', N'Bent Pin', @DieCast, 1),
(N'004', N'Trim Damage', @DieCast, 0),
(N'005', N'Bent Part (Air Gap)', @Trim, 0),
(N'006', N'Breakout (Broken Die)', @DieCast, 0),
(N'007', N'Broken Gate', @DieCast, 0),
(N'008', N'Test Part', @DieCast, 0),
(N'009', N'Blisters', @DieCast, 0),
(N'010', N'Stuck Part/Stuck Piece', @DieCast, 0),
(N'011', N'Flow Lines', @DieCast, 0),
(N'012', N'Flash', @DieCast, 0),
(N'015', N'Short Shot', @DieCast, 0),
(N'113', N'Broken Post', @DieCast, 0),
(N'114', N'Pin Size', @DieCast, 0),
(N'115', N'Computer Reject', @DieCast, 1),
(N'116', N'Double Shot', @DieCast, 1),
(N'117', N'Raised/Recessed Ejector Pins', @DieCast, 0),
(N'118', N'Broken Date Pin', @DieCast, 0),
(N'119', N'Egg-shaped Hole', @DieCast, 0),
(N'120', N'Porosity in Gate Area', @DieCast, 0),
(N'121', N'Cracks', @DieCast, 0),
(N'122', N'Dimensional (All dimensional except pin size and or depth/height)', @DieCast, 0),
(N'123', N'Galling/Drags', @DieCast, 0),
(N'124', N'Bad Repair', @DieCast, 1),
(N'125', N'Drags', @DieCast, 1),
(N'126', N'Contamination (Grease/Oil)', @DieCast, 0),
(N'127', N'Holes Not Punched', @DieCast, 0),
(N'128', N'Flaking', @DieCast, 0),
(N'129', N'Chipped Bolt Pad', @DieCast, 0),
(N'130', N'Over File', @DieCast, 0),
(N'131', N'Flash In Bolt Hole', @DieCast, 0),
(N'132', N'Robot Dropping Parts', @DieCast, 0),
(N'133', N'Hit Damage/Dent/Scratch/Nick', @DieCast, 0),
(N'134', N'Discoloration', @DieCast, 0),
(N'135', N'Porosity', @DieCast, 0),
(N'136', N'Hard Spot', @DieCast, 0),
(N'137', N'Failed Leak Test', @DieCast, 0),
(N'138', N'NCU - Non Clean Up', @DieCast, 0),
(N'139', N'Surface Void (not including caused by broken gate)', @DieCast, 0),
(N'191', N'Snout Damage', @DieCast, 0),
(N'197', N'Lamination', @DieCast, 0),
(N'206', N'Mixed Parts', @DieCast, 0),
(N'210', N'NG Condition (DC)', @DieCast, 0),
(N'214', N'Computer reject/High Speed', @DieCast, 0),
(N'215', N'Computer reject/Cycle time', @DieCast, 0),
(N'216', N'Computer reject/Cast Pressure', @DieCast, 0),
(N'217', N'Computer reject/Biscuit Size', @DieCast, 0),
(N'218', N'Computer reject/Rise up time', @DieCast, 0),
(N'219', N'Computer reject/High Speed Length', @DieCast, 0),
(N'220', N'Computer reject/Press up time', @DieCast, 0),
(N'221', N'Computer reject/Low Speed', @DieCast, 0),
(N'222', N'Telesis', @DieCast, 0),
(N'226', N'Gate breakout', @DieCast, 0),
(N'229', N'Trial Part', @DieCast, 0),
(N'230', N'Assembled on to NG part DC', @DieCast, 0),
(N'231', N'Tow motor dropped', @DieCast, 0),
(N'255', N'Incorrect Quantity', @DieCast, 0),
(N'256', N'InventoryBalance', @DieCast, 0),
(N'247', N'Missing Supply Part', NULL, 0),
(N'248', N'Damaged Supply Part', NULL, 0),
(N'249', N'Dowel Pin High', NULL, 0),
(N'250', N'Dowel Pin Low', NULL, 0),
(N'252', N'Baffle Plate NG', NULL, 0),
(N'253', N'NG Bolt Assembly', NULL, 0),
(N'146', N'Chatter', @MachAsm, 0),
(N'147', N'Cycle Stop', @MachAsm, 0),
(N'148', N'Dropped', @MachAsm, 0),
(N'149', N'Flatness', @MachAsm, 1),
(N'150', N'Holesize', @MachAsm, 0),
(N'151', N'Thickness', @MachAsm, 0),
(N'152', N'Thread Damage', @MachAsm, 0),
(N'153', N'Tool Break', @MachAsm, 0),
(N'154', N'Tool Mark', @MachAsm, 0),
(N'156', N'Hole Off Center', @MachAsm, 0),
(N'157', N'Pin Damage', @MachAsm, 0),
(N'158', N'Pin Height', @MachAsm, 0),
(N'159', N'Pin Missing', @MachAsm, 0),
(N'160', N'Low Pin Pressure', @MachAsm, 0),
(N'161', N'Torque No Good', @MachAsm, 0),
(N'162', N'Misset', @MachAsm, 0),
(N'163', N'Chamfer No Good', @MachAsm, 0),
(N'164', N'Incomplete Machining', @MachAsm, 0),
(N'165', N'Contamination', @MachAsm, 0),
(N'166', N'High Pin Pressure', @MachAsm, 0),
(N'167', N'Clamp Marks', @MachAsm, 0),
(N'168', N'Seal Damage', @MachAsm, 0),
(N'169', N'Skipped Proccess', @MachAsm, 0),
(N'170', N'Machine Trial', @MachAsm, 0),
(N'171', N'Double Cycle', @MachAsm, 0),
(N'172', N'Step Height', @MachAsm, 0),
(N'173', N'Stamp No Good', @MachAsm, 0),
(N'174', N'Over Machining', @MachAsm, 0),
(N'175', N'Diameter', @MachAsm, 0),
(N'176', N'Unidentified Part', @MachAsm, 0),
(N'177', N'Roundness', @MachAsm, 0),
(N'178', N'NG Face Height', @MachAsm, 0),
(N'179', N'Hole Depth', @MachAsm, 0),
(N'180', N'Part/Tower Height', @MachAsm, 0),
(N'181', N'Doesn''t Fit on Jig', @MachAsm, 0),
(N'182', N'Stuck in Washer Conveyor', @MachAsm, 0),
(N'183', N'Ledge', @MachAsm, 0),
(N'184', N'No Cup', @MachAsm, 1),
(N'185', N'No Clip Ring', @MachAsm, 1),
(N'186', N'Studbolt Backward', @MachAsm, 0),
(N'187', N'Concentricity', @MachAsm, 0),
(N'188', N'Cylindricity', @MachAsm, 0),
(N'189', N'Parallellism', @MachAsm, 0),
(N'190', N'Supply Part Defect', @MachAsm, 0),
(N'192', N'Tube Press Damage', @MachAsm, 0),
(N'194', N'Missing Material', @MachAsm, 0),
(N'195', N'Fail QA Machine', @MachAsm, 0),
(N'198', N'Tide Journals', @MachAsm, 0),
(N'199', N'Assembled on to NG part MS', @MachAsm, 0),
(N'200', N'Fail Leak Test (Equipment Failure)', @MachAsm, 0),
(N'207', N'Stripped Studbolts', @MachAsm, 0),
(N'208', N'Cross Threads', @MachAsm, 0),
(N'209', N'Low Studbolt', @MachAsm, 0),
(N'211', N'NG Condition (MS)', @MachAsm, 0),
(N'213', N'Thread Depth', @MachAsm, 0),
(N'223', N'Double Cup', @MachAsm, 0),
(N'224', N'Out of Sequence', @MachAsm, 0),
(N'227', N'Failed Leak Test- Seal', @MachAsm, 0),
(N'228', N'Failed Leak Test- Bolt', @MachAsm, 0),
(N'232', N'Abnormal clamp', @MachAsm, 0),
(N'233', N'Missing O-Ring', @MachAsm, 0),
(N'234', N'Missing Bolt', @MachAsm, 0),
(N'235', N'Unapproved Die', @MachAsm, 0),
(N'236', N'Oil Hole No Good', @MachAsm, 0),
(N'237', N'High Studbolt', @MachAsm, 0),
(N'238', N'Bolt Hole No Good', @MachAsm, 0),
(N'239', N'Steel Ball No Good', @MachAsm, 0),
(N'240', N'Over Grind', @MachAsm, 0),
(N'241', N'Clinch No Good', @MachAsm, 0),
(N'242', N'Joint Tube Height/Dimension', @MachAsm, 0),
(N'243', N'Angle Exceeded', @MachAsm, 0),
(N'244', N'Dents', @MachAsm, 0),
(N'245', N'No Oil Hole', @MachAsm, 0),
(N'246', N'No Stud Bolt', @MachAsm, 0),
(N'254', N'True Position', @MachAsm, 0),
(N'225', N'Labels ( incorrect or missing )', NULL, 0),
(N'201', N'Returned in empty dunnage', NULL, 0),
(N'202', N'Damaged in Transit', NULL, 0),
(N'203', N'Dropped Parts', NULL, 0),
(N'204', N'Incorrect Scan/labels', NULL, 0),
(N'205', N'Missed Shipment', NULL, 0),
(N'212', N'ISO Audit', NULL, 0),
(N'140', N'Stuck Media', @Trim, 0),
(N'141', N'Sanding Damage', @Trim, 0),
(N'142', N'N/G Blast N/G Tumble', @Trim, 0),
(N'143', N'Surface Roughness', @Trim, 0),
(N'144', N'White-Rust', @Trim, 0),
(N'145', N'Drill Damage', @Trim, 0),
-- MPP additions, numbered from 260 -- above the FRS Appendix E maximum of 256.
-- The free gaps INSIDE the FRS range (155, 193, 196, 251) sit mid-band where
-- Flexware could still fill them, so ours start a band of their own.
(N'260', N'Scale Adjustment', @Trim, 0),
(N'999', N'Warmup', @DieCast, 0)
;

-- The guard is (Code, OperationCategoryId), NOT Code alone. Migration 0087
-- made a code unique per (area, charge-to) rather than plant-wide, and a reset
-- runs migrations BEFORE seeds -- so by the time this runs, 0087 has already
-- created 24 of these numbers under a DIFFERENT area (125 Drags under Trim,
-- say, where this seed files it under Die Cast). A Code-only guard sees the
-- number, skips the row, and the area this seed is responsible for never gets
-- it: the fresh-reset database ends at 209 codes where prod has 233, and
-- 125 loses IsExcused with it.
INSERT INTO Quality.DefectCode (Code, Description, OperationCategoryId, IsExcused)
SELECT d.Code, d.Description, d.OperationCategoryId, d.IsExcused
FROM @Defects d
WHERE NOT EXISTS (SELECT 1 FROM Quality.DefectCode dc
                  WHERE dc.Code = d.Code
                    AND dc.OperationCategoryId = d.OperationCategoryId);

PRINT 'Seed 030 (FRS defect codes) applied: ' + CAST(@@ROWCOUNT AS NVARCHAR(10)) + ' new rows.';

-- IsExcused belongs to the row wherever it came from. 0087 inserts every code
-- it adds with IsExcused = 0 (correctly -- it is filing sheet lines, not making
-- an OEE judgement), and for a code it filed in the SAME area this seed wants
-- -- 149 Flatness under Machining & Assembly -- the insert above rightly skips
-- it. Without this the flag is simply lost on a fresh reset, and IsExcused
-- feeds the OEE quality calculation, so the loss is silent and arithmetic.
-- Must stay in THIS batch: @Defects does not survive the GO below.
UPDATE dc SET IsExcused = 1
  FROM Quality.DefectCode dc
  JOIN @Defects d ON d.Code = dc.Code
                 AND d.OperationCategoryId = dc.OperationCategoryId
 WHERE d.IsExcused = 1 AND dc.IsExcused = 0;

PRINT 'Seed 030 excused flags reconciled: ' + CAST(@@ROWCOUNT AS NVARCHAR(10)) + ' row(s).';
GO

-- ============================================================
-- Classification (migration 0067) -- charge-to party + non-reject scrap.
--
-- Applied HERE as well as in the migration because of ordering: a reset runs
-- migrations BEFORE seeds, so 0067's backfill sees an empty DefectCode and
-- no-ops. The migration's copy is what fixes an in-place upgrade (Dev/Prod,
-- where the codes already exist); this copy is what fixes a fresh reset.
-- Same split migration 0048 uses for OperationCategoryId -- keep the two in
-- step if the mapping ever changes.
--
-- Guarded on the columns existing so this seed still applies cleanly to a
-- database that predates 0067.
-- ============================================================
IF COL_LENGTH(N'Quality.DefectCode', N'ChargeToPartyId') IS NOT NULL
BEGIN
    DECLARE @cpDieCast     BIGINT = (SELECT Id FROM Quality.ChargeToParty WHERE Code = N'DieCast');
    DECLARE @cpTrimShop    BIGINT = (SELECT Id FROM Quality.ChargeToParty WHERE Code = N'TrimShop');
    DECLARE @cpMachineShop BIGINT = (SELECT Id FROM Quality.ChargeToParty WHERE Code = N'MachineShop');
    DECLARE @cpMppNS       BIGINT = (SELECT Id FROM Quality.ChargeToParty WHERE Code = N'MppNonSpecific');
    DECLARE @cpSupplierNS  BIGINT = (SELECT Id FROM Quality.ChargeToParty WHERE Code = N'SupplierNonSpecific');

    DECLARE @ocDieCast BIGINT = (SELECT Id FROM Parts.OperationCategory WHERE Code = N'DieCast');
    DECLARE @ocTrim    BIGINT = (SELECT Id FROM Parts.OperationCategory WHERE Code = N'Trim');
    DECLARE @ocMachAsm BIGINT = (SELECT Id FROM Parts.OperationCategory WHERE Code = N'MachiningAssembly');

    -- HSP -> Non-Specific Supplier (supplier-provided parts).
    UPDATE Quality.DefectCode SET ChargeToPartyId = @cpSupplierNS
    WHERE ChargeToPartyId IS NULL
      AND Code IN (N'247', N'248', N'249', N'250', N'252', N'253');

    -- Prod. Control + Quality Control -> Non-Specific MPP.
    UPDATE Quality.DefectCode SET ChargeToPartyId = @cpMppNS
    WHERE ChargeToPartyId IS NULL
      AND Code IN (N'225', N'201', N'202', N'203', N'204', N'205', N'212');

    -- The three process families, from OperationCategory.
    UPDATE Quality.DefectCode SET ChargeToPartyId = @cpDieCast
    WHERE ChargeToPartyId IS NULL AND OperationCategoryId = @ocDieCast;

    UPDATE Quality.DefectCode SET ChargeToPartyId = @cpTrimShop
    WHERE ChargeToPartyId IS NULL AND OperationCategoryId = @ocTrim;

    UPDATE Quality.DefectCode SET ChargeToPartyId = @cpMachineShop
    WHERE ChargeToPartyId IS NULL AND OperationCategoryId = @ocMachAsm;

    -- 999 Warmup: process necessity, not a defect. Counted for material and
    -- yield, excluded from the reject percentage, charged to Die Cast so it
    -- stays visible as a departmental cost rather than sitting in Unassigned.
    UPDATE Quality.DefectCode SET IsNonRejectScrap = 1
    WHERE Code = N'999' AND IsNonRejectScrap = 0;

    -- Counted, but excluded from every reject percentage.
    --   008 Test Part (DC)             170 Machine Trial (MS)
    --   229 Trial Part (DC)
    --   230 Assembled on to NG (DC)    199 Assembled on to NG (MS)
    UPDATE Quality.DefectCode SET IsNonRejectScrap = 1
    WHERE IsNonRejectScrap = 0 AND Code IN (N'008', N'170', N'229', N'230', N'199');

    -- NO 'DC - ' DESCRIPTION PREFIX HERE. This block used to mirror migration
    -- 0086, which prefixed every die-cast-CHARGED description. Migration 0087
    -- REVERSED that decision and strips the prefix back off: attribution is
    -- ChargeToPartyId, which 0087 sets per row, not something spelled into the
    -- label. The seed's copy outlived the decision it mirrored, and because a
    -- reset runs migrations BEFORE seeds it re-applied the prefix AFTER 0087
    -- had removed it -- so every fresh Dev/Test database disagreed with prod,
    -- which never re-runs seeds. Do not reinstate it without also reversing
    -- 0087.

    PRINT 'Seed 030 classification applied (charge-to party + non-reject scrap).';
END
GO
