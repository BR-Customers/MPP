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
(N'100', N'Soldering', @DieCast, 0),
(N'101', N'Broken/Bent Pin', @DieCast, 0),
(N'102', N'Bent Pin', @DieCast, 1),
(N'103', N'Trim Damage', @DieCast, 0),
(N'104', N'Flatness/Bent Parts', @DieCast, 0),
(N'105', N'Breakout (Broken Die)', @DieCast, 0),
(N'106', N'Broken Gate', @DieCast, 0),
(N'107', N'Test Part', @DieCast, 0),
(N'108', N'Blisters', @DieCast, 0),
(N'109', N'Stuck Part/Stuck Piece', @DieCast, 0),
(N'110', N'Flow Lines', @DieCast, 0),
(N'111', N'Flash', @DieCast, 0),
(N'112', N'Short Shot', @DieCast, 0),
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
(N'145', N'Drill Damage', @Trim, 0)
;

INSERT INTO Quality.DefectCode (Code, Description, OperationCategoryId, IsExcused)
SELECT d.Code, d.Description, d.OperationCategoryId, d.IsExcused
FROM @Defects d
WHERE NOT EXISTS (SELECT 1 FROM Quality.DefectCode dc WHERE dc.Code = d.Code);

PRINT 'Seed 030 (FRS defect codes) applied: ' + CAST(@@ROWCOUNT AS NVARCHAR(10)) + ' new rows.';
GO
