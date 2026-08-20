-- =============================================
-- Seed:        032_seed_label_templates_mpp.sql
-- Author:      Blue Ridge Automation
-- Date:        2026-08-20
-- Description: MPP's PRODUCTION LOT-ticket ZPL, captured from MPP_MES_Dev.
--
--              Confirmed by Hunter 2026-08-20: the ZPL bodies in the database
--              are the ones going to production. They were loaded into Dev
--              out-of-band and, until this seed, were reproduced by NO
--              migration or seed -- so a fresh Deploy-Prod.ps1 shipped
--              migration 0021's PLACEHOLDER layout instead of the real labels.
--              Tracked as seeding item S-13.
--
--              Seeds are applied AFTER versioned migrations, so this runs after
--              0021 (which creates the placeholder rows) and after 0063 (which
--              inserts the {CrtMark} token into the ones whose layout it
--              recognised). It therefore overwrites both -- which is why the
--              Primary body below must carry {CrtMark} itself. 0063 could not
--              add it: the real Primary layout does not match 0021's anchor,
--              which is exactly what 0063's WARNING reports.
--
--              Idempotent: each UPDATE is a no-op when the body already matches.
--              Targets only the ACTIVE (DeprecatedAt IS NULL) template per type,
--              so template history is left intact.
--
--              ASCII-only, verified by byte scan -- sqlcmd reads .sql files in
--              the Windows codepage, and a non-ASCII byte here would print as
--              mojibake on a physical label.
-- =============================================

SET NOCOUNT ON;
GO

-- ---- Primary (LabelTypeCodeId 1) ----
UPDATE Lots.LabelTemplate
   SET ZplBody = N'^XA^LH50,50^A0,34,27^FO0,0^FDArea:^FS^A0,64,48^FO100,0^FD{LocationName}^FS^A0,34,27^FO0,100^FDLot:^FS^A0,64,48^FO100,100^FD{LotName} {CrtMark}^FS^A0,34,27^FO0,200^FDMaterial:^FS^A0,64,48^FO100,200^FD{ItemCode}^FS^A0,45,37^FO100,275^FD{ItemDescription}^FS^A0,34,27^FO0,350^FDQuantity:^FS^A0,64,48^FO100,350^FD{PieceCount}^FS^A0^FO0,420^BY3^B3,,50,N,^FD{LotName}^FS^A0,34,27^FO0,500^FDDate/Time: {PrintedAt}^FS^XZ'
 WHERE LabelTypeCodeId = 1
   AND DeprecatedAt IS NULL
   AND ZplBody <> N'^XA^LH50,50^A0,34,27^FO0,0^FDArea:^FS^A0,64,48^FO100,0^FD{LocationName}^FS^A0,34,27^FO0,100^FDLot:^FS^A0,64,48^FO100,100^FD{LotName} {CrtMark}^FS^A0,34,27^FO0,200^FDMaterial:^FS^A0,64,48^FO100,200^FD{ItemCode}^FS^A0,45,37^FO100,275^FD{ItemDescription}^FS^A0,34,27^FO0,350^FDQuantity:^FS^A0,64,48^FO100,350^FD{PieceCount}^FS^A0^FO0,420^BY3^B3,,50,N,^FD{LotName}^FS^A0,34,27^FO0,500^FDDate/Time: {PrintedAt}^FS^XZ';
GO

-- ---- Container (LabelTypeCodeId 2) ----
UPDATE Lots.LabelTemplate
   SET ZplBody = N'^XA
^A0R,24,26^FO740,20^FDPART NO. (P)^FS
^A0R,86,86^FO690,200^FD{PartNumber}^FS
^A0R^FO600,70^BY3^B3,,100,N,^FD{PartNumber}^FS
^FO660,1100^BXR,5,200,,,,^FD{DataMatrix}^FS
^A0R,24,24^FO550,20^FDPART NO. EXT (C)^FS
^A0R,72,72^FO480,70^FD{PartNumberExt}^FS
^A0R^FO410,70^BY3^B3,,80,N,^FD{PartNumberExt}^FS
^A0R,24,24^FO550,670^FDDESCRIPTION^FS
^A0R,45,36^FO500,670^FD{Description}^FS
^A0R,24,24^FO460,670^FDMFG LOT NUMBER^FS
^A0R,45,36^FO410,670^FD{MfgLotNumber}^FS
^A0R,24,24^FO460,1070^FDMFG DATE^FS
^A0R,45,36^FO410,1070^FD{MfgDate}^FS
^A0R,24,24^FO460,940^FDAUDIT^FS
^A0R,45,36^FO420,940^FD{Auditor}^FS
^A0R,24,24^FO370,20^FDD/C PART LEVEL (2P)^FS
^A0R,72,72^FO300,70^FD{DcPartLevel}^FS
^A0R^FO230,70^BY3^B3,,75,N,^FD{DcPartLevel}^FS
^A0R^FO320,720^BY3^B3,,75,N,^FDQ{Quantity}^FS
^A0R,72,72^FO240,720^FD{Quantity}^FS
^A0R,24,24^FO230,670^FDQUANTITY (Q)^FS
^A0R,24,24^FO190,20^FDSERIAL (1S)^FS
^A0R,72,72^FO140,200^FD{Serial}^FS
^A0R^FO50,60^BY3^B3,,95,N,^FD{Serial}^FS
^A0R,24,24^FO20,20^FDMade In / C.O.O.                                               Madison Precision Products Inc., 94 E 400 North, Madison, IN 47250^FS
^A0R,24,24^FO20,220^FD{Coo}^FS
^FO580,10^GB0,1300,3^FS
^FO490,650^GB0,905,3^FS
^FO400,10^GB0,1300,3^FS
^FO220,10^GB0,1300,3^FS
^FO220,650^GB360,0,3^FS
^PQ2
^XZ'
 WHERE LabelTypeCodeId = 2
   AND DeprecatedAt IS NULL
   AND ZplBody <> N'^XA
^A0R,24,26^FO740,20^FDPART NO. (P)^FS
^A0R,86,86^FO690,200^FD{PartNumber}^FS
^A0R^FO600,70^BY3^B3,,100,N,^FD{PartNumber}^FS
^FO660,1100^BXR,5,200,,,,^FD{DataMatrix}^FS
^A0R,24,24^FO550,20^FDPART NO. EXT (C)^FS
^A0R,72,72^FO480,70^FD{PartNumberExt}^FS
^A0R^FO410,70^BY3^B3,,80,N,^FD{PartNumberExt}^FS
^A0R,24,24^FO550,670^FDDESCRIPTION^FS
^A0R,45,36^FO500,670^FD{Description}^FS
^A0R,24,24^FO460,670^FDMFG LOT NUMBER^FS
^A0R,45,36^FO410,670^FD{MfgLotNumber}^FS
^A0R,24,24^FO460,1070^FDMFG DATE^FS
^A0R,45,36^FO410,1070^FD{MfgDate}^FS
^A0R,24,24^FO460,940^FDAUDIT^FS
^A0R,45,36^FO420,940^FD{Auditor}^FS
^A0R,24,24^FO370,20^FDD/C PART LEVEL (2P)^FS
^A0R,72,72^FO300,70^FD{DcPartLevel}^FS
^A0R^FO230,70^BY3^B3,,75,N,^FD{DcPartLevel}^FS
^A0R^FO320,720^BY3^B3,,75,N,^FDQ{Quantity}^FS
^A0R,72,72^FO240,720^FD{Quantity}^FS
^A0R,24,24^FO230,670^FDQUANTITY (Q)^FS
^A0R,24,24^FO190,20^FDSERIAL (1S)^FS
^A0R,72,72^FO140,200^FD{Serial}^FS
^A0R^FO50,60^BY3^B3,,95,N,^FD{Serial}^FS
^A0R,24,24^FO20,20^FDMade In / C.O.O.                                               Madison Precision Products Inc., 94 E 400 North, Madison, IN 47250^FS
^A0R,24,24^FO20,220^FD{Coo}^FS
^FO580,10^GB0,1300,3^FS
^FO490,650^GB0,905,3^FS
^FO400,10^GB0,1300,3^FS
^FO220,10^GB0,1300,3^FS
^FO220,650^GB360,0,3^FS
^PQ2
^XZ';
GO

-- ---- Master (LabelTypeCodeId 3) ----
UPDATE Lots.LabelTemplate
   SET ZplBody = N'^XA^FO40,40^A0N,40,40^FDLOT {LotName}^FS^FO300,45^A0N,30,30^FD{CrtMark}^FS^FO40,90^A0N,30,30^FDItem {ItemCode}  Qty {PieceCount}^FS^FO40,130^A0N,30,30^FDParent {ParentLotNumber}^FS^FO40,170^A0N,24,24^FD{PrintedAt}^FS^FO40,210^BY2^BCN,80,Y,N,N^FD{LotName}^FS^XZ'
 WHERE LabelTypeCodeId = 3
   AND DeprecatedAt IS NULL
   AND ZplBody <> N'^XA^FO40,40^A0N,40,40^FDLOT {LotName}^FS^FO300,45^A0N,30,30^FD{CrtMark}^FS^FO40,90^A0N,30,30^FDItem {ItemCode}  Qty {PieceCount}^FS^FO40,130^A0N,30,30^FDParent {ParentLotNumber}^FS^FO40,170^A0N,24,24^FD{PrintedAt}^FS^FO40,210^BY2^BCN,80,Y,N,N^FD{LotName}^FS^XZ';
GO

-- ---- Void (LabelTypeCodeId 4) ----
UPDATE Lots.LabelTemplate
   SET ZplBody = N'^XA^FO40,40^A0N,40,40^FDLOT {LotName}^FS^FO300,45^A0N,30,30^FD{CrtMark}^FS^FO40,90^A0N,30,30^FDItem {ItemCode}  Qty {PieceCount}^FS^FO40,130^A0N,30,30^FDParent {ParentLotNumber}^FS^FO40,170^A0N,24,24^FD{PrintedAt}^FS^FO40,210^BY2^BCN,80,Y,N,N^FD{LotName}^FS^XZ'
 WHERE LabelTypeCodeId = 4
   AND DeprecatedAt IS NULL
   AND ZplBody <> N'^XA^FO40,40^A0N,40,40^FDLOT {LotName}^FS^FO300,45^A0N,30,30^FD{CrtMark}^FS^FO40,90^A0N,30,30^FDItem {ItemCode}  Qty {PieceCount}^FS^FO40,130^A0N,30,30^FDParent {ParentLotNumber}^FS^FO40,170^A0N,24,24^FD{PrintedAt}^FS^FO40,210^BY2^BCN,80,Y,N,N^FD{LotName}^FS^XZ';
GO

-- ---- Verify every active LTT template carries the CRT mark ----
DECLARE @NoMark INT = (
    SELECT COUNT(*) FROM Lots.LabelTemplate
     WHERE LabelTypeCodeId IN (1, 3, 4)
       AND DeprecatedAt IS NULL
       AND ZplBody NOT LIKE N'%{CrtMark}%');
IF @NoMark > 0
    PRINT 'WARNING: ' + CAST(@NoMark AS NVARCHAR(10)) + ' active LTT label template(s)'
        + ' carry no {CrtMark} -- a CRT LOT will print with NO mark on those tickets.';
ELSE
    PRINT 'Label templates seeded; all active LTT templates carry {CrtMark}.';
GO
