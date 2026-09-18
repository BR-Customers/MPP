-- ============================================================
-- Migration:   0093_printreasoncode_ascii_name.sql
-- Author:      Blue Ridge Automation
-- Created:     2026-09-17
-- Description: Replaces the em-dash in Lots.PrintReasonCode 'ReprintDamaged'.
--
--              0004 seeded the Name as 'Reprint <em-dash> Damaged'. sqlcmd
--              reads .sql files in the Windows codepage, so the em-dash was
--              stored as mojibake -- confirmed on MPP_MES_Dev 2026-09-17,
--              where the Name reads 'Reprint a-euro-quote Damaged' (bytes
--              E2 00 AC 20 1D 20 in place of the dash). That garbage is what
--              Ignition would display. This is the ASCII-only seed rule in
--              CLAUDE.md, applied after the fact.
--
--              Keyed on Code, never on the current Name, so it corrects the
--              row whichever form it holds (mojibake, a real em-dash, or
--              anything else). This file is ASCII-only on purpose: it names
--              the dash in prose rather than containing it.
--
--              PURE RENAME of a display name. Lots.LotLabel.PrintReasonCodeId
--              is an FK on Id, which does not move. Nothing in the repo
--              matches on this Name. 0004 is left as-is -- applied
--              migrations are the historical record (same as 0085 / 0084).
--
--              Idempotent: no-ops once the Name is already correct.
--
-- Change Log:
--   2026-09-17 - 1.0 - Initial version
-- ============================================================

-- ---- 1. ASCII name for ReprintDamaged ----
IF EXISTS (SELECT 1 FROM Lots.PrintReasonCode
           WHERE Code = N'ReprintDamaged'
             AND Name <> N'Reprint - Damaged' COLLATE Latin1_General_BIN2)
BEGIN
    UPDATE Lots.PrintReasonCode
       SET Name = N'Reprint - Damaged'
     WHERE Code = N'ReprintDamaged';

    PRINT '0093: ReprintDamaged Name set to ASCII.';
END
ELSE
    PRINT '0093: ReprintDamaged Name already ASCII (or row absent) -- nothing to do.';
GO

-- ---- 2. Record migration ----
IF NOT EXISTS (SELECT 1 FROM dbo.SchemaVersion WHERE MigrationId = N'0093_printreasoncode_ascii_name')
    INSERT INTO dbo.SchemaVersion (MigrationId, Description)
    VALUES (N'0093_printreasoncode_ascii_name',
            N'Lots.PrintReasonCode ''ReprintDamaged'' Name: em-dash (stored as mojibake by sqlcmd) replaced with ASCII ''Reprint - Damaged''. Keyed on Code; Id unchanged.');
GO
PRINT 'Migration 0093 (printreasoncode_ascii_name) applied.';
