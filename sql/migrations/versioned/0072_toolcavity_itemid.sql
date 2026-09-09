-- ============================================================
-- Migration:   0072_toolcavity_itemid.sql
-- Author:      Blue Ridge Automation
-- Date:        2026-09-09
-- Description: Die-cast day-one feedback. Adds Tools.ToolCavity.ItemId --
--              the configured cavity-to-part map for family dies.
--
--              REVERSES the 2026-06-15 decision recorded in the header of
--              R__Tools_ToolCavity_ListActiveByTool.sql, which held that the
--              produced Item is "derived from the run configuration
--              (Lots.Lot.ItemId)" and is therefore not modeled per cavity.
--              That holds only while every cavity has a LOT open on it. MPP
--              runs FAMILY DIES -- one 12-cavity die casting four different
--              part numbers, three cavities each (6MA IN 1 / IN 5 / EX 1 /
--              EX 5, per production sheet DCFM-2077) -- and a cavity can be
--              Closed or Scrapped while the die keeps running (observed on
--              the floor: 6MA EX 1 cavity 'a' is out of service). A cavity
--              with no LOT then has no knowable part at all, so the shift-
--              output screen cannot name it, cannot collect its scrap, and
--              cannot roll production up per part the way the paper sheet
--              does.
--
--              Which cavity cuts which part is a fixed physical property of
--              the die -- it changes only when the die is re-cut -- so it is
--              CONFIGURATION (Tool Cavities editor), not per-shift operator
--              entry. NULLable: a non-family die whose cavities all cut the
--              same part may leave it unset and keep deriving from the LOT.
--
--              Additive. Idempotent-guarded; no explicit transaction (repo
--              convention -- see 0067).
-- ============================================================

IF EXISTS (SELECT 1 FROM dbo.SchemaVersion WHERE MigrationId = N'0072_toolcavity_itemid')
BEGIN
    PRINT 'Migration 0072 already applied -- skipping.';
    RETURN;
END
GO

-- ============================================================
-- 1. Tools.ToolCavity.ItemId (nullable FK -> Parts.Item)
-- ============================================================
IF COL_LENGTH('Tools.ToolCavity', 'ItemId') IS NULL
    ALTER TABLE Tools.ToolCavity ADD ItemId BIGINT NULL;
GO

IF NOT EXISTS (SELECT 1 FROM sys.foreign_keys WHERE name = N'FK_ToolCavity_Item')
    ALTER TABLE Tools.ToolCavity
        ADD CONSTRAINT FK_ToolCavity_Item FOREIGN KEY (ItemId) REFERENCES Parts.Item(Id);
GO

-- Filtered: the vast majority of cavities on non-family dies stay NULL.
IF NOT EXISTS (SELECT 1 FROM sys.indexes
               WHERE name = N'IX_ToolCavity_ItemId'
                 AND object_id = OBJECT_ID(N'Tools.ToolCavity'))
    CREATE NONCLUSTERED INDEX IX_ToolCavity_ItemId
        ON Tools.ToolCavity (ItemId) WHERE ItemId IS NOT NULL;
GO

-- ============================================================
-- == Record migration ========================================
-- ============================================================
IF NOT EXISTS (SELECT 1 FROM dbo.SchemaVersion WHERE MigrationId = N'0072_toolcavity_itemid')
    INSERT INTO dbo.SchemaVersion (MigrationId, Description)
    VALUES (
        N'0072_toolcavity_itemid',
        N'Family dies: Tools.ToolCavity.ItemId BIGINT NULL FK Parts.Item + filtered index -- configured cavity-to-part map so a cavity with no open LOT still knows what it cuts. Reverses the 2026-06-15 no-per-cavity-Item decision.'
    );
GO

PRINT 'Migration 0072 completed: Tools.ToolCavity.ItemId.';
GO
