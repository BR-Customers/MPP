-- ============================================================
-- Migration: 0055_printer_fg_assignment.sql
-- Author:    Blue Ridge Automation
-- Date:      2026-08-06 (renumbered 0052 -> 0055 on 2026-08-12)
-- Description: FG<->printer binding for multi-printer assembly-out stations
--   (printer-cards feature). One row per child Printer that has an assigned
--   finished good; UNIQUE(PrinterLocationId) = one FG per printer. Adds the
--   'PrinterFgAssignment' audit entity type. Idempotent-guarded.
--
--   RENUMBERED 0052 -> 0055. This shipped on main as 0052 while the AIM branch
--   independently used 0052/0053/0054, so merging produced two 0052_* files --
--   different filenames, so git never flagged it, but the migration order was
--   ambiguous. Both the filename AND the MigrationId string moved to 0055 so the
--   two stay in step. A database that already recorded '0052_printer_fg_assignment'
--   (i.e. built from main before the merge) will re-enter this file, find every
--   object already present via the guards below, change nothing, and record
--   '0055_printer_fg_assignment' -- one redundant SchemaVersion row, no drift.
--   Verified re-runnable 2026-08-12 against MPP_MES_Dev and MPP_MES_Test.
-- ============================================================
IF EXISTS (SELECT 1 FROM dbo.SchemaVersion WHERE MigrationId = N'0055_printer_fg_assignment')
BEGIN PRINT 'Migration 0055 already applied -- skipping.'; RETURN; END
GO

IF OBJECT_ID(N'Location.PrinterFgAssignment') IS NULL
BEGIN
    CREATE TABLE Location.PrinterFgAssignment (
        Id                     BIGINT IDENTITY(1,1) NOT NULL
            CONSTRAINT PK_PrinterFgAssignment PRIMARY KEY,
        PrinterLocationId      BIGINT NOT NULL
            CONSTRAINT FK_PrinterFgAssignment_Printer REFERENCES Location.Location(Id),
        ItemId                 BIGINT NOT NULL
            CONSTRAINT FK_PrinterFgAssignment_Item REFERENCES Parts.Item(Id),
        SortOrder              INT NOT NULL
            CONSTRAINT DF_PrinterFgAssignment_SortOrder DEFAULT (1),
        CreatedAt              DATETIME2(3) NOT NULL
            CONSTRAINT DF_PrinterFgAssignment_CreatedAt DEFAULT (SYSUTCDATETIME()),
        CreatedByAppUserId     BIGINT NULL
            CONSTRAINT FK_PrinterFgAssignment_CreatedBy REFERENCES Location.AppUser(Id),
        LastEditedAt           DATETIME2(3) NULL,
        LastEditedByAppUserId  BIGINT NULL
            CONSTRAINT FK_PrinterFgAssignment_EditedBy REFERENCES Location.AppUser(Id),
        CONSTRAINT UX_PrinterFgAssignment_Printer UNIQUE (PrinterLocationId)
    );
END
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_PrinterFgAssignment_Item')
    CREATE INDEX IX_PrinterFgAssignment_Item ON Location.PrinterFgAssignment (ItemId);
GO

-- Audit entity type (dynamic next Id -- no magic number / collision).
IF NOT EXISTS (SELECT 1 FROM Audit.LogEntityType WHERE Code = N'PrinterFgAssignment')
    INSERT INTO Audit.LogEntityType (Id, Code, Name, Description)
    SELECT ISNULL(MAX(Id),0)+1, N'PrinterFgAssignment', N'Printer FG Assignment',
           N'FG-to-printer binding at a multi-printer assembly-out station'
    FROM Audit.LogEntityType;
GO

-- Guarded like 0053/0054: the top-of-file RETURN only exits its OWN batch, so after the
-- next GO the remaining batches run regardless. Every other step here is self-guarded;
-- without this guard the re-run died on UQ_SchemaVersion_MigrationId.
IF NOT EXISTS (SELECT 1 FROM dbo.SchemaVersion WHERE MigrationId = N'0055_printer_fg_assignment')
    INSERT INTO dbo.SchemaVersion (MigrationId, Description)
    VALUES (N'0055_printer_fg_assignment', N'Location.PrinterFgAssignment (FG<->printer binding, UNIQUE per printer) + audit entity type.');
GO
-- "complete" not "applied": the batches below the top-of-file RETURN always run, so this
-- line is reached on a skipped re-run too.
PRINT 'Migration 0055 (printer_fg_assignment) complete.';
GO
