-- ============================================================
-- Seed:        seed_macola_and_fg_boms.sql   (GENERATED -- edit
--              reference/scripts/build_macola_and_fg_bom_seed.py, never this file)
-- Author:      Blue Ridge Automation
-- Date:        2026-08-18
-- Description: Macola part numbers + finished-good BOM lines, transformed from
--              the customer workbook reference/MPP_Macola_Numbers_2026-06-15.xlsx
--              ("MACOLA NUMBERS FOR INVENTORYupdate 6-15-26.xlsx", MPP 6/15/26).
--
--              Lives in sql/scratch/ (NOT sql/seeds/) for the same reason
--              seed_mpp_parts.sql does: it is a first load that still carries
--              open customer data questions (see the RECONCILIATION appendix at
--              the bottom of this file and the report that generated it), and
--              dropping it into every Reset-DevDatabase / test-DB build before
--              MPP answers them would destabilise the suite. Promote to
--              sql/seeds/ once the data is settled.
--
--              THE GOVERNING RULE. A Macola number comes ONLY from a column
--              literally headed "MACOLA #". Exactly two sheets have one:
--              ALUMINUM (C1) and SUPPLY PARTS (C1). The per-family sheets'
--              RAW / TUMBLED BLASTED / MACHINED / FINISHED GOODS columns
--              (187-090, 187-091, 187-092, 187-MET, 186-AEP ...) are MPP
--              per-stage inventory codes, NOT Macola numbers, and nothing in
--              this file writes one to Parts.Item.MacolaPartNumber.
--
--              SCOPE. Nothing here CREATES a Parts.Item row. The workbook is an
--              inventory list, not a part master, and minting rows from it would
--              produce near-duplicate part numbers (92900-06012-1B alongside the
--              catalog's 92900-06012-0B). The four ALUMINUM alloys are the one
--              case where a Macola number has no item to attach to; their SQL is
--              emitted COMMENTED OUT because Raw Material Tracking is FUTURE
--              (MPP_Scope_Matrix.xlsx row 21 / FRS 3.9.1). The SERVICE /
--              PASS THRU / NEW MODEL sheets carry no MACOLA # column and are read
--              only as a PART NAME -> CUSTOMER PART # lookup table.
--
--              Fully idempotent -- re-running inserts and updates nothing twice.
--              An Item that ALREADY carries a non-blank MacolaPartNumber is
--              LEFT ALONE, never overwritten. ASCII-only.
--
--              Dependencies: 0005 (Parts.Item.MacolaPartNumber + its filtered
--              index), 0007 (Parts.Bom / Parts.BomLine), 004 (ItemType/Uom),
--              and a loaded part catalog (sql/scratch/seed_mpp_parts.sql and/or
--              sql/seeds/020_seed_items.sql). Rows whose PartNumber is absent
--              simply update/insert nothing -- the seed does not create them.
-- ============================================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

-- ============================================================
-- ALUMINUM sheet -- the 4 alloys and their Macola numbers (300 / 301 / 303 /
-- 304). NOT LOADED. The SQL below is deliberately COMMENTED OUT.
--
-- WHY. The ALUMINUM sheet's "Honda Part#" column holds alloy codes -- ADC12,
-- HD2BS, HD2G, NH41 -- not Honda part numbers, and nothing in the catalog
-- corresponds to them. Their Macola numbers have nowhere to land unless the
-- alloys exist as Parts.Item rows of ItemType 'RawMaterial'. But
-- reference/MPP_Scope_Matrix.xlsx row 21 -- Traceability / Raw Material
-- Tracking -- is "Not Included", Future (MPP_MES_SUMMARY.md line 307: FUTURE,
-- excluded per FRS 3.9.1), and the FUTURE rule is "schema supports it, but do
-- NOT implement, POPULATE, or test". Parts.ItemType 'RawMaterial' (Id 1,
-- migration 0004) therefore stays empty.
--
-- To enable, once raw-material tracking is in scope: un-comment the block
-- below and confirm the UoM (LB assumed -- MPP charges melt by weight).
-- ============================================================
-- DECLARE @Dev BIGINT = (SELECT TOP 1 Id FROM Location.AppUser WHERE Initials = N'DEV' ORDER BY Id);
-- DECLARE @A TABLE (Pn NVARCHAR(50), Descr NVARCHAR(500), Macola NVARCHAR(50));
-- INSERT INTO @A (Pn, Descr, Macola) VALUES
--  (N'ADC12', N'ADC12 ALUMINUM', N'300'),
--  (N'HD2BS', N'HD2BS ALUMINUM', N'301'),
--  (N'HD2G', N'HD2G ALUMINUM', N'303'),
--  (N'NH41', N'NH41 ALUMINUM', N'304');
--
-- INSERT INTO Parts.Item (ItemTypeId, PartNumber, Description, MacolaPartNumber,
--                         UomId, CreatedAt, CreatedByUserId)
-- SELECT t.Id, a.Pn, a.Descr, a.Macola, u.Id, SYSUTCDATETIME(), @Dev
-- FROM @A a
-- JOIN Parts.ItemType t ON t.Code = N'RawMaterial'
-- JOIN Parts.Uom      u ON u.Code = N'LB'
-- WHERE NOT EXISTS (SELECT 1 FROM Parts.Item x WHERE x.PartNumber = a.Pn);
-- PRINT 'seed_macola: RawMaterial alloys -> ' + CAST(@@ROWCOUNT AS VARCHAR(10)) + ' inserted.';
-- GO

-- ============================================================
-- Parts.Item.MacolaPartNumber -- from the SUPPLY PARTS "MACOLA #" column only.
--
-- Written ONLY where the column is currently NULL or blank. A part that already
-- carries a value is skipped, per the catalog seed's "already present is left
-- alone" convention. (Note: 5 catalog rows already carry a value that came from
-- the per-family sheets' FINISHED GOODS column -- 186-AEP, 142-AEP, 141-HCM,
-- 630-AEP, 662-AEP -- which under the governing rule are NOT Macola numbers.
-- They are deliberately NOT touched here; correcting them is Hunter's call.)
--
-- PartNumber is the emitted natural key: the generator has already reconciled
-- the workbook's Honda Part# against the catalog's fixed-width rendering
-- (e.g. sheet '14631-5G0-A000' -> catalog '146315GO A000'), so the SQL needs no
-- fuzzy matching of its own. A PartNumber absent from Parts.Item updates
-- nothing -- by design.
-- ============================================================
DECLARE @M TABLE (Pn NVARCHAR(50), Macola NVARCHAR(50));
INSERT INTO @M (Pn, Macola) VALUES
 (N'11221-64AA-A010', N'911'),
 (N'146315GO A000', N'619'),
 (N'146325GO A000', N'620'),
 (N'146335GO A000', N'621'),
 (N'146345GO A000', N'622'),
 (N'15123-PCX-0030-H1', N'434'),
 (N'19305-5K0-A000', N'916'),
 (N'19517-PD6-3000', N'356'),
 (N'90004PE2 0050', N'390'),
 (N'90009-R70-A000', N'433'),
 (N'90015-PH1-0130', N'363'),
 (N'90701-5GO -A000', N'610'),
 (N'91302-RZP-0000', N'922'),
 (N'92900-06014-1B', N'355'),
 (N'92900-06050-0B', N'900'),
 (N'94109-14000', N'327'),
 (N'94301-08100', N'366'),
 (N'94301-08140', N'308'),
 (N'94301-10120', N'388'),
 (N'94301-12160', N'310'),
 (N'95701-06020-08', N'914'),
 (N'96211-09000', N'439');

DECLARE @DevU BIGINT = (SELECT TOP 1 Id FROM Location.AppUser WHERE Initials = N'DEV' ORDER BY Id);
UPDATE i
   SET i.MacolaPartNumber = m.Macola,
       i.UpdatedAt        = SYSUTCDATETIME(),
       i.UpdatedByUserId  = @DevU
FROM Parts.Item i
JOIN @M m ON m.Pn = i.PartNumber
WHERE NULLIF(LTRIM(RTRIM(i.MacolaPartNumber)), N'') IS NULL;
PRINT 'seed_macola: MacolaPartNumber   -> ' + CAST(@@ROWCOUNT AS VARCHAR(10)) + ' updated.';

DECLARE @Absent INT = (SELECT COUNT(*) FROM @M m
                       WHERE NOT EXISTS (SELECT 1 FROM Parts.Item i WHERE i.PartNumber = m.Pn));
IF @Absent > 0
    PRINT 'seed_macola: WARNING -- ' + CAST(@Absent AS VARCHAR(10)) +
          ' part number(s) in this seed are absent from Parts.Item (catalog not loaded?).';
GO

-- ============================================================
-- Parts.Bom + Parts.BomLine -- finished-good BOMs from SUPPLY PARTS.
--
-- Source shape: an anchor row carries Supply Part Description | Honda Part# |
-- MACOLA # | Corresponding FG Assembly(s) | Pcs per part. A component feeding
-- several finished goods gets CONTINUATION rows underneath with the first three
-- columns blank; those are forward-filled. "Pcs per part" is blank on most
-- continuations (qty forward-fills from the anchor) but carries a per-FG
-- override on 20 of them, which is honoured.
--
-- Emitted only where BOTH sides resolve to a catalog part number. The BOM is
-- Published v1, mirroring 020_seed_items.sql / seed_mpp_parts.sql. A parent
-- that already has a v1 BOM gets these lines ADDED to it; a line already
-- present (same parent + child) is skipped, so nothing is overwritten.
--
-- Lines where the workbook's qty DISAGREES with the qty already in the catalog
-- are deliberately NOT emitted -- they are listed in the RECONCILIATION
-- appendix at the bottom of this file for MPP to arbitrate.
-- ============================================================
DECLARE @Dev BIGINT = (SELECT TOP 1 Id FROM Location.AppUser WHERE Initials = N'DEV' ORDER BY Id);
DECLARE @B TABLE (Parent NVARCHAR(50), Child NVARCHAR(50), Qty DECIMAL(10,4), Sort INT);
INSERT INTO @B (Parent, Child, Qty, Sort) VALUES
 (N'11200-5J6 -A110', N'90009-R70-A000', 1, 1),  -- 5J6-1 OIL PAN <- DRAIN PLUG BOLT
 (N'11200-5J6 -A110', N'94109-14000', 1, 2),  -- 5J6-1 OIL PAN <- DRAIN PLUG WASHER
 (N'11200-5J6 -A110', N'94301-08140', 2, 3),  -- 5J6-1 OIL PAN <- 8 x14 DOWEL PIN
 (N'1120A-64A -A000', N'15123-PCX-0030-H1', 1, 1),  -- 64A OIL PAN <- 18 x 13 Dowel Pin
 (N'1120A-64A -A000', N'90009-R70-A000', 1, 2),  -- 64A OIL PAN <- DRAIN PLUG BOLT
 (N'1120A-69F -A000', N'90009-R70-A000', 1, 1),  -- 69F OIL PAN <- DRAIN PLUG BOLT
 (N'1223A-RPY -A000', N'96211-09000', 1, 1),  -- RPY CH/RS SET <- 9 STEEL BALL
 (N'12270-RPY -G001', N'94301-10120', 2, 1);  -- RPY Fuel Pump <- 10 X 12 DOWEL PIN

INSERT INTO Parts.Bom (ParentItemId, VersionNumber, EffectiveFrom, PublishedAt, CreatedByUserId, CreatedAt)
SELECT DISTINCT i.Id, 1, '2026-01-15', '2026-01-14', @Dev, SYSUTCDATETIME()
FROM @B b
JOIN Parts.Item i ON i.PartNumber = b.Parent
WHERE NOT EXISTS (SELECT 1 FROM Parts.Bom x WHERE x.ParentItemId = i.Id AND x.VersionNumber = 1);
PRINT 'seed_macola: Parts.Bom          -> ' + CAST(@@ROWCOUNT AS VARCHAR(10)) + ' inserted.';

INSERT INTO Parts.BomLine (BomId, ChildItemId, QtyPer, UomId, SortOrder)
SELECT bm.Id, c.Id, b.Qty, c.UomId,
       (SELECT ISNULL(MAX(x.SortOrder), 0) FROM Parts.BomLine x WHERE x.BomId = bm.Id) + b.Sort
FROM @B b
JOIN Parts.Item p  ON p.PartNumber   = b.Parent
JOIN Parts.Bom  bm ON bm.ParentItemId = p.Id AND bm.VersionNumber = 1
JOIN Parts.Item c  ON c.PartNumber   = b.Child
WHERE NOT EXISTS (SELECT 1 FROM Parts.BomLine x WHERE x.BomId = bm.Id AND x.ChildItemId = c.Id);
PRINT 'seed_macola: Parts.BomLine      -> ' + CAST(@@ROWCOUNT AS VARCHAR(10)) + ' inserted.';
GO

/* ============================================================
   RECONCILIATION APPENDIX -- generated with this file. Nothing below
   executes; it is the audit trail for what the workbook could NOT be
   turned into SQL, and why. Row-level detail: macola_bom_reconciliation.csv
   ============================================================
--
-- --------------------------------------------------------------------------
-- COUNTS
-- --------------------------------------------------------------------------
--   workbook MACOLA # values ............... 66 (ALUMINUM 4 + SUPPLY PARTS 62)
--   catalog items (match baseline) ......... 170
--   Macola numbers landed on an item ....... 22
--   Macola numbers held back (FUTURE scope)  4   (ALUMINUM -- raw material)
--   Macola numbers with no catalog item .... 40
--   catalog items left with no Macola ...... 143
--   finished goods in catalog .............. 38
--   finished goods GIVEN a Macola number ... 0   <-- see the note below
--   SUPPLY PARTS component->FG links ....... 149
--   BOM lines resolved end to end .......... 21
--     of which new (emitted) ............... 8
--     of which already in the catalog ...... 13
--   BOM lines with a QTY CONFLICT .......... 2
--   BOM links, FG parent unresolved ........ 59
--   BOM links, component child unresolved .. 7
--   BOM links, neither side resolved ....... 60
--
-- --------------------------------------------------------------------------
-- THE FINISHED-GOOD / MACOLA TENSION
-- --------------------------------------------------------------------------
--   The task was phrased "add the Macola numbers to finished goods", but the
--   only MACOLA # columns in this workbook are on ALUMINUM (raw material) and
--   SUPPLY PARTS (purchased components). Neither is a finished good. Under the
--   governing rule, finished goods therefore receive NO Macola number: 0 of
--   38 catalog finished goods got one from this workbook.
--   MPP/Hunter to confirm whether FG Macola numbers exist somewhere else.
--
-- --------------------------------------------------------------------------
-- MACOLA # ROWS WITH NO CATALOG PART (40) -- number is real, part is not in the MES catalog
-- --------------------------------------------------------------------------
--   r2     ENGINE COOLER                    15500-RPY-G010-M4    macola=444
--   r3     6 X 16 FLANGE BOLT               95701-06016-08       macola=443
--   r4     BAFFLE PLATE                     11221-59B-0000       macola=357
--   r6     BAFFLE PLATE                     11221-5R0-0000       macola=904
--   r7     PLATE DIFF LUBE                  22792-5MX-A000       macola=901
--   r10    8.8X1.9 ORING                    91308-PH9-0000       macola=902
--   r13    17.8 X 2.4 ORING                 11203-PWA-0031       macola=905
--   r18    THRUST WASHER                    14646-R70-A000       macola=389
--   r19    ROCKER ARM EX 14612              14612-5G0-A000       macola=612
--   r20    ROCKER ARM EX 14614              14614-5G0-A000       macola=613
--   r21    ROCKER ARM IN 14640              14640-5G0-A000       macola=614
--   r22    ROCKER ARM IN 14620              14620-5G0-A000       macola=615
--   r23    ROCKER ARM EX 14624              14624-5G0-A000       macola=616
--   r24    ROCKER ARM EX 14627              14627-5G0-A010       macola=617
--   r25    Rocker Arm Spring 14645          14645-5G0-A000       macola=618
--   r30    8 STEEL BALL                     96211-08000          macola=432
--   r32    6C1 OIL PAN                      11200-6C1-A000       macola=909
--   r33    5WJ OIL PAN                      11200-5WJ-A000       macola=910
--   r35    Baffle Plate B                   11222-64AA-A001      macola=912
--   r49    6x10 DOWEL PIN                   94301-06100          macola=312
--   r51    9 X 10 DOWEL PIN                 90701-5R0-3000       macola=313
--   r52    JOINT TUBE                       030ES-M4464-0000     macola=314
--   r53    M6x12 FLANGE BOLT                95701-06012-08       macola=323
--   r71    6X12 STUD BOLT                   92900-06012-1B       macola=332
--   r89    26.2X2.4 O-RING                  91307-P8A-A000       macola=329
--   r91    CASE OIL SEAL 80 X 98 X 10(CG)   (blank)              macola=330
--   r92    48.5X2.4 O-RING                  91301-P8A-A000       macola=331
--   r107   20X2.3 O-RING                    91301-RNA-A020-M2    macola=364
--   r113   18X22 DOWEL PIN                  90703-PEO-0000       macola=365
--   r121   Case Oil Seal (Seals)            91214-RKG-0030       macola=903
--   r128   13 x 20 Dowel pin                90715-PC6-000        macola=410
--   r129   SEALING BOLT 10MM                90030-RT4-0030       macola=414
--   r130   ORING 116.7X2.2                  91318-RT4-0030       macola=415
--   r131   CHOKE LUBE CHECK                 21259-RT4-3000       macola=418
--   r132   9 X 14 DOWEL PIN                 90701-5A2A-A000      macola=429
--   r137   9 X 17 DOWEL PIN                 90702-5A2A-A000      macola=431
--   r144   O-RING                           91303-5A2-A010-M1    macola=435
--   r147   FLANGE BOLT                      90002-5G0-A000       macola=611
--   r149   6S9 OIL SEAL                     91214-6S9-A010-M1    macola=913
--   r151   Thermostat                       19300-6C1-A010-M2    macola=915
--
-- --------------------------------------------------------------------------
-- BOM QTY CONFLICTS (2) -- workbook disagrees with the loaded catalog; NOT emitted
-- --------------------------------------------------------------------------
--   1223A-5BA -A000      <- 96211-09000          workbook=2 catalog=1   (5BA CH/RS SET / 9 STEEL BALL)
--   1223A-6B2 -A000      <- 96211-09000          workbook=2 catalog=1   (6B2 CH/RS SETS / 9 STEEL BALL)
--
-- --------------------------------------------------------------------------
-- BOM LINKS WHOSE FG NAME DID NOT RESOLVE (51 distinct names)
-- --------------------------------------------------------------------------
--   59B CH/RS SETS               no name match anywhere
--   59B FUEL PUMP                family-sheet PN not in catalog: 12270-59B-0000
--   59B SETS MPP CAST            no name match anywhere
--   5A2 CH/RS SETS               family-sheet PN not in catalog: 1226A-5A2-A000
--   5A2 FUEL PUMP                family-sheet PN not in catalog: 122705A2 A010
--   5A2 Fuel Pump                family-sheet PN not in catalog: 122705A2 A010
--   5AA / 5K8 OIL PAN            no name match anywhere
--   5AA 5K8 OIL PAN              no name match anywhere
--   5B0 CH/RS SETS               no name match anywhere
--   5BA SIDE COVER               family-sheet PN not in catalog: 12270-5BA-A000
--   5G0 FRONT                    family-sheet PN not in catalog: 14650-5G0A-A000
--   5G0 HOLDER ASSY FR           no name match anywhere
--   5G0 HOLDER ASSY RR           no name match anywhere
--   5G0 Holder Assy Front        no name match anywhere
--   5G0 Holder Assy Rear         no name match anywhere
--   5G0 REAR                     family-sheet PN not in catalog: 14660-5G0A-A000
--   5J6 OIL PAN                  family-sheet PN not in catalog: 1120R5J6A010
--   5LA Oil Pan                  family-sheet PN not in catalog: 1120A5LAA000
--   5MH OIL PAN                  family-sheet PN not in catalog: 112005MHA000
--   5MX 5YL PIPE B DIFF LUBE     no name match anywhere
--   5MX PIPE LUBE DIFF           no name match anywhere
--   5MX/5YL PIPE B DIFF LUBE     no name match anywhere
--   5PA FUEL PUMP METTS          no name match anywhere
--   5PA OIL PAN                  family-sheet PN not in catalog: 1120A-5PA-A000
--   5YK PIPE B DIFF LUBE         family-sheet PN not in catalog: 22790-5YK-0000
--   66VT FUEL PUMP               family-sheet PN not in catalog: 12270-6VVT-A000
--   69F TCASE                    no name match anywhere
--   69F THERMO CASE              no name match anywhere
--   6AT CAP AL SIDE              no name match anywhere
--   6C2 OIL PAN                  no name match anywhere
--   6L2 OIL PAN                  no name match anywhere
--   6MA/69F OP                   no name match anywhere
--   6S9 CASE OIL SEAL            family-sheet PN not in catalog: 11300-6S9A-A000
--   CAP COOLER RETURN            no name match anywhere
--   HITACHI SINGLE CASE          no name match anywhere
--   P8A CASE OIL SEAL            no name match anywhere
--   P8A OIL PAN                  family-sheet PN not in catalog: 11200-P8A-A00
--   P8A OILPAN                   family-sheet PN not in catalog: 11200-P8A-A00
--   PGE OIL PAN                  family-sheet PN not in catalog: 11200-PGE-A00
--   R1A LOST MOTION              family-sheet PN not in catalog: 12236-R1A-A000
--   R1B OIL PAN                  no name match anywhere
--   R1B Oil pan                  no name match anywhere
--   R70 CASE OIL SEAL            family-sheet PN not in catalog: 11300-R70-A000
--   RCA CAMTHRUST REAR           family-sheet PN not in catalog: 1224A-RCA-A000
--   RCA CASE OIL SEAL            family-sheet PN not in catalog: 11300-RCA-A000
--   RDJ OIL PAN                  family-sheet PN not in catalog: 11200-RDJ-A00
--   RNA OIL PAN                  family-sheet PN not in catalog: 11200-RNA-A02, 1120ARNA 0200
--   RNAOIL PAN                   family-sheet PN not in catalog: 11200-RNA-A02, 1120ARNA 0200
--   RNO OIL PAN                  no name match anywhere
--   RPY WATER PASSAGE            family-sheet PN not in catalog: 19410RPYG000
--   RXO Oil Pan                  family-sheet PN not in catalog: 11200RX0 A000
--
-- --------------------------------------------------------------------------
-- BOM LINKS WHOSE COMPONENT DID NOT RESOLVE (7)
-- --------------------------------------------------------------------------
--   64A OIL PAN                  child=11222-64AA-A001      Baffle Plate B
--   6B2 FUEL PUMP                child=92900-06012-1B       6X12 STUD BOLT
--   P8A CAMTHRUST FRONT          child=91301-P8A-A000       48.5X2.4 O-RING
--   64A OIL PAN                  child=91301-RNA-A020-M2    20X2.3 O-RING
--   6B2 CH/RS SETS               child=90701-5A2A-A000      9 X 14 DOWEL PIN
--   RPY CH/RS SETS               child=90701-5A2A-A000      9 X 14 DOWEL PIN
--   5BA CH/RS SETS               child=90701-5A2A-A000      9 X 14 DOWEL PIN
--
   ============================================================ */
