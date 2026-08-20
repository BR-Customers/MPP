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
--                * Master and Void - migration 0021's PLACEHOLDER; the two
--                              bodies are byte-identical to each other. Owned
--                              by that migration; MPP has not supplied real
--                              layouts. NOT touched here.
--                * Container - a verbatim copy of migration 0054's ported Honda
--                              ZPL, already reproduced by 0054. NOT touched here.
--                * CrtBanner - migration 0065's CRT banner. Owned by that
--                              migration. NOT touched here.
--
--              Seeding the other types would put this file's copy AHEAD of the
--              migrations that own them: because the UPDATE is unconditional on
--              the active row, a later migration revising their ZPL -- or a real
--              layout hand-loaded into production -- would be silently reverted
--              on the next Deploy-Prod.ps1. Tracked as seeding item S-13.
--
--              CRT (design D8, revised 2026-08-20): the body below is MPP's
--              layout UNMODIFIED. A CRT LOT is marked by a SEPARATE banner label
--              printed after the normal ticket (migration 0065), not by anything
--              spliced into this template -- so nothing here has to change when
--              MPP supplies a revised layout, and the barcode hazard noted below
--              never arises for CRT. The earlier design appended a {CrtMark}
--              token to the Lot line; migration 0065 removes it, and this seed
--              carries the restored original line
--              (^A0,64,48^FO100,100^FD{LotName}^FS). Seeds run AFTER migrations,
--              so leaving the token here would put it straight back.
--
--              BARCODE HAZARD (still true, just no longer a CRT concern): this
--              body carries TWO {LotName} tokens and the second sits inside the
--              ^B3 Code 39 field's ^FD payload. Anyone editing this template --
--              for any reason -- must anchor on the specific human-readable
--              field, never on the bare {LotName} token, or the edit lands in
--              the barcode and corrupts the scanned LOT number.
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

DECLARE @Zpl NVARCHAR(MAX) = N'^XA^LH50,50^A0,34,27^FO0,0^FDArea:^FS^A0,64,48^FO100,0^FD{LocationName}^FS^A0,34,27^FO0,100^FDLot:^FS^A0,64,48^FO100,100^FD{LotName}^FS^A0,34,27^FO0,200^FDMaterial:^FS^A0,64,48^FO100,200^FD{ItemCode}^FS^A0,45,37^FO100,275^FD{ItemDescription}^FS^A0,34,27^FO0,350^FDQuantity:^FS^A0,64,48^FO100,350^FD{PieceCount}^FS^A0^FO0,420^BY3^B3,,50,N,^FD{LotName}^FS^A0,34,27^FO0,500^FDDate/Time: {PrintedAt}^FS^XZ';

UPDATE Lots.LabelTemplate
   SET ZplBody = @Zpl
 WHERE LabelTypeCodeId = @PrimaryTypeId
   AND DeprecatedAt IS NULL
   AND ZplBody <> @Zpl;
GO

-- ---- Verify the LTT templates are PRESENT and free of the retired token ----
-- Asserts a POSITIVE expected count: counting rows that LACK something would
-- report success for a type whose active template is missing entirely.
-- Primary comes from this seed; Master and Void from migration 0021.
-- {CrtMark} is no longer substituted by anything (migration 0065 replaced it
-- with the CrtBanner label), so a surviving token would print LITERALLY.
DECLARE @Expected INT = 3;
DECLARE @Active INT = (
    SELECT COUNT(*)
      FROM Lots.LabelTemplate t
      JOIN Lots.LabelTypeCode c ON c.Id = t.LabelTypeCodeId
     WHERE c.Code IN (N'Primary', N'Master', N'Void')
       AND t.DeprecatedAt IS NULL);
DECLARE @Stale INT = (
    SELECT COUNT(*)
      FROM Lots.LabelTemplate t
     WHERE t.DeprecatedAt IS NULL
       AND t.ZplBody LIKE N'%{CrtMark}%');

IF @Active <> @Expected
    PRINT 'WARNING: expected ' + CAST(@Expected AS NVARCHAR(10)) + ' active LTT label'
        + ' template(s) (Primary/Master/Void), found ' + CAST(@Active AS NVARCHAR(10)) + '.';
ELSE IF @Stale > 0
    PRINT 'WARNING: ' + CAST(@Stale AS NVARCHAR(10)) + ' active label template(s) still carry'
        + ' the retired {CrtMark} token; nothing substitutes it, so it will print literally.';
ELSE
    PRINT 'Primary label template seeded; 3 active LTT templates, none carrying {CrtMark}.';
GO
