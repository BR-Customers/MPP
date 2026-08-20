-- =============================================
-- Seed:        032_seed_label_templates_mpp.sql
-- Author:      Blue Ridge Automation
-- Date:        2026-08-20
-- Description: MPP's PRODUCTION Primary LOT-ticket ZPL, captured from MPP_MES_Dev.
--
--              SCOPE: the PRIMARY label type ONLY. A byte-exact comparison of
--              the four active Lots.LabelTemplate bodies in Dev against the
--              migrations established that Primary is the only body no
--              migration reproduces:
--                * Primary   - MPP's real plant layout, loaded into Dev
--                              out-of-band. Reproduced by nothing. Seeded here.
--                * Master and Void - migration 0021's PLACEHOLDER plus
--                              migration 0065's {CrtMark} patch; the two
--                              bodies are byte-identical to each other. Owned
--                              by those migrations; MPP has not supplied real
--                              layouts. NOT touched here.
--                * Container - a verbatim copy of migration 0054's ported Honda
--                              ZPL, already reproduced by 0054. NOT touched here.
--
--              Seeding the other three would put this file's copy AHEAD of the
--              migrations that own them: because the UPDATE is unconditional on
--              the active row, a later migration revising Container/Master/Void
--              ZPL -- or a real layout hand-loaded into production -- would be
--              silently reverted on the next Deploy-Prod.ps1. Tracked as
--              seeding item S-13.
--
--              Seeds are applied AFTER versioned migrations, so this runs after
--              0021 (which creates the placeholder rows) and after 0065 (which
--              inserts the {CrtMark} token into the ones whose layout it
--              recognised). It therefore overwrites both for Primary -- which is
--              why the Primary body below must carry {CrtMark} itself. 0065
--              could not add it: the real Primary layout does not match 0021's
--              anchor, which is exactly what 0065's WARNING reports.
--
--              BARCODE SAFETY: the Primary body carries TWO {LotName} tokens.
--              {CrtMark} appears ONLY in the human-readable Lot line
--              (^A0,64,48^FO100,100^FD{LotName} {CrtMark}^FS) and NEVER inside
--              the ^B3 Code 39 field's ^FD payload -- injecting it there would
--              corrupt the scanned LOT number on a physical ticket.
--
--              Idempotent: the UPDATE is a no-op when the body already matches.
--              Targets only the ACTIVE (DeprecatedAt IS NULL) template for the
--              type, so template history is left intact.
--
--              ASCII-only, verified by byte scan -- sqlcmd reads .sql files in
--              the Windows codepage, and a non-ASCII byte here would print as
--              mojibake on a physical label.
-- =============================================

SET NOCOUNT ON;
GO

-- ---- Primary LTT ----
-- Label type resolved by Code, not by a hardcoded Id (repo convention, mirrors
-- migration 0054). The body is held in @Zpl so the UPDATE and its idempotence
-- guard cannot silently diverge from one another.
DECLARE @PrimaryTypeId BIGINT =
    (SELECT Id FROM Lots.LabelTypeCode WHERE Code = N'Primary');

DECLARE @Zpl NVARCHAR(MAX) = N'^XA^LH50,50^A0,34,27^FO0,0^FDArea:^FS^A0,64,48^FO100,0^FD{LocationName}^FS^A0,34,27^FO0,100^FDLot:^FS^A0,64,48^FO100,100^FD{LotName} {CrtMark}^FS^A0,34,27^FO0,200^FDMaterial:^FS^A0,64,48^FO100,200^FD{ItemCode}^FS^A0,45,37^FO100,275^FD{ItemDescription}^FS^A0,34,27^FO0,350^FDQuantity:^FS^A0,64,48^FO100,350^FD{PieceCount}^FS^A0^FO0,420^BY3^B3,,50,N,^FD{LotName}^FS^A0,34,27^FO0,500^FDDate/Time: {PrintedAt}^FS^XZ';

UPDATE Lots.LabelTemplate
   SET ZplBody = @Zpl
 WHERE LabelTypeCodeId = @PrimaryTypeId
   AND DeprecatedAt IS NULL
   AND ZplBody <> @Zpl;
GO

-- ---- Verify the three LTT templates are PRESENT and carry the CRT mark ----
-- Asserts a POSITIVE expected count: counting rows that LACK the token would
-- report success for a type whose active template is missing entirely.
-- Primary comes from this seed; Master and Void from 0021 + 0065's patch.
DECLARE @Expected INT = 3;
DECLARE @WithMark INT = (
    SELECT COUNT(*)
      FROM Lots.LabelTemplate t
      JOIN Lots.LabelTypeCode c ON c.Id = t.LabelTypeCodeId
     WHERE c.Code IN (N'Primary', N'Master', N'Void')
       AND t.DeprecatedAt IS NULL
       AND t.ZplBody LIKE N'%{CrtMark}%');
IF @WithMark <> @Expected
    PRINT 'WARNING: expected ' + CAST(@Expected AS NVARCHAR(10)) + ' active LTT label'
        + ' template(s) (Primary/Master/Void) carrying {CrtMark}, found '
        + CAST(@WithMark AS NVARCHAR(10)) + ' -- a CRT LOT will print with NO mark on'
        + ' the missing one(s).';
ELSE
    PRINT 'Primary label template seeded; all 3 active LTT templates carry {CrtMark}.';
GO
