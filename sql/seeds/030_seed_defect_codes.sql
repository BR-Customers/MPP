-- ============================================================
-- Seed:        030_seed_defect_codes.sql
-- Author:      Blue Ridge Automation
-- Date:        2026-06-29
-- Description: FDS-08-016 -- load the 153 FRS Appendix E defect codes into
--              Quality.DefectCode (these were never seeded -> the reject-code
--              dropdown was empty). Source: reference/seed_data/defect_codes.csv.
--              Department -> Area mapping is REPRESENTATIVE (Hunter, 2026-06-29;
--              refine with MPP per FDS-08-017 -- die-cast codes attach to DC1
--              only, so DC2-4 will not see them once area-filtering is wired):
--                Die Cast      -> DC1      Machine Shop -> MA1
--                Trim Shop     -> TRIM1    HSP / Prod. Control / Quality Control -> MPP-MAD
--              AreaLocationId resolved by Code at apply time. Idempotent on
--              UQ_DefectCode_Code (insert-where-not-exists). ASCII-only.
-- ============================================================

SET NOCOUNT ON;

DECLARE @DC1 BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'DC1'     AND DeprecatedAt IS NULL);
DECLARE @MA1 BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MA1'     AND DeprecatedAt IS NULL);
DECLARE @TRM BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'TRIM1'   AND DeprecatedAt IS NULL);
DECLARE @SIT BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MPP-MAD' AND DeprecatedAt IS NULL);

DECLARE @Defects TABLE (Code NVARCHAR(20), Description NVARCHAR(500), AreaLocationId BIGINT, IsExcused BIT);

INSERT INTO @Defects (Code, Description, AreaLocationId, IsExcused) VALUES
(N'100', N'Soldering', @DC1, 0),
(N'101', N'Broken/Bent Pin', @DC1, 0),
(N'102', N'Bent Pin', @DC1, 1),
(N'103', N'Trim Damage', @DC1, 0),
(N'104', N'Flatness/Bent Parts', @DC1, 0),
(N'105', N'Breakout (Broken Die)', @DC1, 0),
(N'106', N'Broken Gate', @DC1, 0),
(N'107', N'Test Part', @DC1, 0),
(N'108', N'Blisters', @DC1, 0),
(N'109', N'Stuck Part/Stuck Piece', @DC1, 0),
(N'110', N'Flow Lines', @DC1, 0),
(N'111', N'Flash', @DC1, 0),
(N'112', N'Short Shot', @DC1, 0),
(N'113', N'Broken Post', @DC1, 0),
(N'114', N'Pin Size', @DC1, 0),
(N'115', N'Computer Reject', @DC1, 1),
(N'116', N'Double Shot', @DC1, 1),
(N'117', N'Raised/Recessed Ejector Pins', @DC1, 0),
(N'118', N'Broken Date Pin', @DC1, 0),
(N'119', N'Egg-shaped Hole', @DC1, 0),
(N'120', N'Porosity in Gate Area', @DC1, 0),
(N'121', N'Cracks', @DC1, 0),
(N'122', N'Dimensional (All dimensional except pin size and or depth/height)', @DC1, 0),
(N'123', N'Galling/Drags', @DC1, 0),
(N'124', N'Bad Repair', @DC1, 1),
(N'125', N'Drags', @DC1, 1),
(N'126', N'Contamination (Grease/Oil)', @DC1, 0),
(N'127', N'Holes Not Punched', @DC1, 0),
(N'128', N'Flaking', @DC1, 0),
(N'129', N'Chipped Bolt Pad', @DC1, 0),
(N'130', N'Over File', @DC1, 0),
(N'131', N'Flash In Bolt Hole', @DC1, 0),
(N'132', N'Robot Dropping Parts', @DC1, 0),
(N'133', N'Hit Damage/Dent/Scratch/Nick', @DC1, 0),
(N'134', N'Discoloration', @DC1, 0),
(N'135', N'Porosity', @DC1, 0),
(N'136', N'Hard Spot', @DC1, 0),
(N'137', N'Failed Leak Test', @DC1, 0),
(N'138', N'NCU - Non Clean Up', @DC1, 0),
(N'139', N'Surface Void (not including caused by broken gate)', @DC1, 0),
(N'191', N'Snout Damage', @DC1, 0),
(N'197', N'Lamination', @DC1, 0),
(N'206', N'Mixed Parts', @DC1, 0),
(N'210', N'NG Condition (DC)', @DC1, 0),
(N'214', N'Computer reject/High Speed', @DC1, 0),
(N'215', N'Computer reject/Cycle time', @DC1, 0),
(N'216', N'Computer reject/Cast Pressure', @DC1, 0),
(N'217', N'Computer reject/Biscuit Size', @DC1, 0),
(N'218', N'Computer reject/Rise up time', @DC1, 0),
(N'219', N'Computer reject/High Speed Length', @DC1, 0),
(N'220', N'Computer reject/Press up time', @DC1, 0),
(N'221', N'Computer reject/Low Speed', @DC1, 0),
(N'222', N'Telesis', @DC1, 0),
(N'226', N'Gate breakout', @DC1, 0),
(N'229', N'Trial Part', @DC1, 0),
(N'230', N'Assembled on to NG part DC', @DC1, 0),
(N'231', N'Tow motor dropped', @DC1, 0),
(N'255', N'Incorrect Quantity', @DC1, 0),
(N'256', N'InventoryBalance', @DC1, 0),
(N'247', N'Missing Supply Part', @SIT, 0),
(N'248', N'Damaged Supply Part', @SIT, 0),
(N'249', N'Dowel Pin High', @SIT, 0),
(N'250', N'Dowel Pin Low', @SIT, 0),
(N'252', N'Baffle Plate NG', @SIT, 0),
(N'253', N'NG Bolt Assembly', @SIT, 0),
(N'146', N'Chatter', @MA1, 0),
(N'147', N'Cycle Stop', @MA1, 0),
(N'148', N'Dropped', @MA1, 0),
(N'149', N'Flatness', @MA1, 1),
(N'150', N'Holesize', @MA1, 0),
(N'151', N'Thickness', @MA1, 0),
(N'152', N'Thread Damage', @MA1, 0),
(N'153', N'Tool Break', @MA1, 0),
(N'154', N'Tool Mark', @MA1, 0),
(N'156', N'Hole Off Center', @MA1, 0),
(N'157', N'Pin Damage', @MA1, 0),
(N'158', N'Pin Height', @MA1, 0),
(N'159', N'Pin Missing', @MA1, 0),
(N'160', N'Low Pin Pressure', @MA1, 0),
(N'161', N'Torque No Good', @MA1, 0),
(N'162', N'Misset', @MA1, 0),
(N'163', N'Chamfer No Good', @MA1, 0),
(N'164', N'Incomplete Machining', @MA1, 0),
(N'165', N'Contamination', @MA1, 0),
(N'166', N'High Pin Pressure', @MA1, 0),
(N'167', N'Clamp Marks', @MA1, 0),
(N'168', N'Seal Damage', @MA1, 0),
(N'169', N'Skipped Proccess', @MA1, 0),
(N'170', N'Machine Trial', @MA1, 0),
(N'171', N'Double Cycle', @MA1, 0),
(N'172', N'Step Height', @MA1, 0),
(N'173', N'Stamp No Good', @MA1, 0),
(N'174', N'Over Machining', @MA1, 0),
(N'175', N'Diameter', @MA1, 0),
(N'176', N'Unidentified Part', @MA1, 0),
(N'177', N'Roundness', @MA1, 0),
(N'178', N'NG Face Height', @MA1, 0),
(N'179', N'Hole Depth', @MA1, 0),
(N'180', N'Part/Tower Height', @MA1, 0),
(N'181', N'Doesn''t Fit on Jig', @MA1, 0),
(N'182', N'Stuck in Washer Conveyor', @MA1, 0),
(N'183', N'Ledge', @MA1, 0),
(N'184', N'No Cup', @MA1, 1),
(N'185', N'No Clip Ring', @MA1, 1),
(N'186', N'Studbolt Backward', @MA1, 0),
(N'187', N'Concentricity', @MA1, 0),
(N'188', N'Cylindricity', @MA1, 0),
(N'189', N'Parallellism', @MA1, 0),
(N'190', N'Supply Part Defect', @MA1, 0),
(N'192', N'Tube Press Damage', @MA1, 0),
(N'194', N'Missing Material', @MA1, 0),
(N'195', N'Fail QA Machine', @MA1, 0),
(N'198', N'Tide Journals', @MA1, 0),
(N'199', N'Assembled on to NG part MS', @MA1, 0),
(N'200', N'Fail Leak Test (Equipment Failure)', @MA1, 0),
(N'207', N'Stripped Studbolts', @MA1, 0),
(N'208', N'Cross Threads', @MA1, 0),
(N'209', N'Low Studbolt', @MA1, 0),
(N'211', N'NG Condition (MS)', @MA1, 0),
(N'213', N'Thread Depth', @MA1, 0),
(N'223', N'Double Cup', @MA1, 0),
(N'224', N'Out of Sequence', @MA1, 0),
(N'227', N'Failed Leak Test- Seal', @MA1, 0),
(N'228', N'Failed Leak Test- Bolt', @MA1, 0),
(N'232', N'Abnormal clamp', @MA1, 0),
(N'233', N'Missing O-Ring', @MA1, 0),
(N'234', N'Missing Bolt', @MA1, 0),
(N'235', N'Unapproved Die', @MA1, 0),
(N'236', N'Oil Hole No Good', @MA1, 0),
(N'237', N'High Studbolt', @MA1, 0),
(N'238', N'Bolt Hole No Good', @MA1, 0),
(N'239', N'Steel Ball No Good', @MA1, 0),
(N'240', N'Over Grind', @MA1, 0),
(N'241', N'Clinch No Good', @MA1, 0),
(N'242', N'Joint Tube Height/Dimension', @MA1, 0),
(N'243', N'Angle Exceeded', @MA1, 0),
(N'244', N'Dents', @MA1, 0),
(N'245', N'No Oil Hole', @MA1, 0),
(N'246', N'No Stud Bolt', @MA1, 0),
(N'254', N'True Position', @MA1, 0),
(N'225', N'Labels ( incorrect or missing )', @SIT, 0),
(N'201', N'Returned in empty dunnage', @SIT, 0),
(N'202', N'Damaged in Transit', @SIT, 0),
(N'203', N'Dropped Parts', @SIT, 0),
(N'204', N'Incorrect Scan/labels', @SIT, 0),
(N'205', N'Missed Shipment', @SIT, 0),
(N'212', N'ISO Audit', @SIT, 0),
(N'140', N'Stuck Media', @TRM, 0),
(N'141', N'Sanding Damage', @TRM, 0),
(N'142', N'N/G Blast N/G Tumble', @TRM, 0),
(N'143', N'Surface Roughness', @TRM, 0),
(N'144', N'White-Rust', @TRM, 0),
(N'145', N'Drill Damage', @TRM, 0)
;

INSERT INTO Quality.DefectCode (Code, Description, AreaLocationId, IsExcused)
SELECT d.Code, d.Description, d.AreaLocationId, d.IsExcused
FROM @Defects d
WHERE d.AreaLocationId IS NOT NULL
  AND NOT EXISTS (SELECT 1 FROM Quality.DefectCode dc WHERE dc.Code = d.Code);

PRINT 'Seed 030 (FRS defect codes) applied: ' + CAST(@@ROWCOUNT AS NVARCHAR(10)) + ' new rows.';
GO
