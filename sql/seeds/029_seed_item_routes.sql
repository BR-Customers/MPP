-- ============================================================
-- Seed:        029_seed_item_routes.sql
-- Author:      Blue Ridge Automation
-- Date:        2026-07-06
-- Description: Continuous Demo Seed Dataset (Task 1). Published RouteTemplate
--              + RouteStep rows for the 6 processed items in the 020 parts
--              matrix (RD-BRKT is pass-through: no route). Split out of 020
--              into its own later-numbered file because RouteStep wiring
--              resolves Parts.OperationTemplate by Code, and those codes are
--              seeded by 022 (DieCastShot), 024 (TrimIn/TrimOut), 026
--              (MachiningIn/MachiningOut) and 027 (AssemblyIn/AssemblyOut) --
--              all of which sort AFTER 020 alphabetically. Seed scripts run
--              in filename order within a single Reset, so this file must be
--              numbered after all of 020/022/024/026/027 to see every
--              OperationTemplate row it needs. Idempotent (IF NOT EXISTS
--              guards, natural-key resolution: PartNumber / Code / Initials,
--              never a hardcoded Id). ASCII-only.
--
--              Dependencies: 020_seed_items.sql (Parts.Item: 6MA-C, 6MA-M,
--              6MA, 5G0-C, 5G0-M, 5G0), 022/024/026/027 (OperationTemplate
--              Code: DieCastShot, TrimIn, TrimOut, MachiningIn, MachiningOut,
--              AssemblyIn, AssemblyOut).
-- ============================================================

-- ============================================================
-- Parts.RouteTemplate + Parts.RouteStep (published), per processed item.
-- ============================================================

-- ---- 6MA-C: DieCastShot -> TrimIn -> TrimOut ----
DECLARE @RtId BIGINT;

IF NOT EXISTS (SELECT 1 FROM Parts.RouteTemplate rt INNER JOIN Parts.Item i ON i.Id = rt.ItemId WHERE i.PartNumber = N'6MA-C' AND rt.VersionNumber = 1)
    INSERT INTO Parts.RouteTemplate (ItemId, VersionNumber, Name, EffectiveFrom, PublishedAt, DeprecatedAt, CreatedByUserId, CreatedAt)
    SELECT i.Id, 1, N'6MA-C Die Cast + Trim Route v1', '2026-01-15', '2026-01-14', NULL, u.Id, SYSUTCDATETIME()
    FROM Parts.Item i, Location.AppUser u WHERE i.PartNumber = N'6MA-C' AND u.Initials = N'DEV';

SET @RtId = (SELECT rt.Id FROM Parts.RouteTemplate rt INNER JOIN Parts.Item i ON i.Id = rt.ItemId WHERE i.PartNumber = N'6MA-C' AND rt.VersionNumber = 1);

IF NOT EXISTS (SELECT 1 FROM Parts.RouteStep WHERE RouteTemplateId = @RtId AND SequenceNumber = 1)
    INSERT INTO Parts.RouteStep (RouteTemplateId, OperationTemplateId, SequenceNumber, IsRequired, Description)
    SELECT @RtId, ot.Id, 1, 1, N'Die cast shot' FROM Parts.OperationTemplate ot WHERE ot.Code = N'DieCastShot';

IF NOT EXISTS (SELECT 1 FROM Parts.RouteStep WHERE RouteTemplateId = @RtId AND SequenceNumber = 2)
    INSERT INTO Parts.RouteStep (RouteTemplateId, OperationTemplateId, SequenceNumber, IsRequired, Description)
    SELECT @RtId, ot.Id, 2, 1, N'Trim in' FROM Parts.OperationTemplate ot WHERE ot.Code = N'TrimIn';

IF NOT EXISTS (SELECT 1 FROM Parts.RouteStep WHERE RouteTemplateId = @RtId AND SequenceNumber = 3)
    INSERT INTO Parts.RouteStep (RouteTemplateId, OperationTemplateId, SequenceNumber, IsRequired, Description)
    SELECT @RtId, ot.Id, 3, 1, N'Trim out' FROM Parts.OperationTemplate ot WHERE ot.Code = N'TrimOut';
GO

-- ---- 6MA-M: MachiningIn -> MachiningOut ----
DECLARE @RtId BIGINT;

IF NOT EXISTS (SELECT 1 FROM Parts.RouteTemplate rt INNER JOIN Parts.Item i ON i.Id = rt.ItemId WHERE i.PartNumber = N'6MA-M' AND rt.VersionNumber = 1)
    INSERT INTO Parts.RouteTemplate (ItemId, VersionNumber, Name, EffectiveFrom, PublishedAt, DeprecatedAt, CreatedByUserId, CreatedAt)
    SELECT i.Id, 1, N'6MA-M Machining Route v1', '2026-01-15', '2026-01-14', NULL, u.Id, SYSUTCDATETIME()
    FROM Parts.Item i, Location.AppUser u WHERE i.PartNumber = N'6MA-M' AND u.Initials = N'DEV';

SET @RtId = (SELECT rt.Id FROM Parts.RouteTemplate rt INNER JOIN Parts.Item i ON i.Id = rt.ItemId WHERE i.PartNumber = N'6MA-M' AND rt.VersionNumber = 1);

IF NOT EXISTS (SELECT 1 FROM Parts.RouteStep WHERE RouteTemplateId = @RtId AND SequenceNumber = 1)
    INSERT INTO Parts.RouteStep (RouteTemplateId, OperationTemplateId, SequenceNumber, IsRequired, Description)
    SELECT @RtId, ot.Id, 1, 1, N'Machining in' FROM Parts.OperationTemplate ot WHERE ot.Code = N'MachiningIn';

IF NOT EXISTS (SELECT 1 FROM Parts.RouteStep WHERE RouteTemplateId = @RtId AND SequenceNumber = 2)
    INSERT INTO Parts.RouteStep (RouteTemplateId, OperationTemplateId, SequenceNumber, IsRequired, Description)
    SELECT @RtId, ot.Id, 2, 1, N'Machining out' FROM Parts.OperationTemplate ot WHERE ot.Code = N'MachiningOut';
GO

-- ---- 6MA: AssemblyIn -> AssemblyOut ----
DECLARE @RtId BIGINT;

IF NOT EXISTS (SELECT 1 FROM Parts.RouteTemplate rt INNER JOIN Parts.Item i ON i.Id = rt.ItemId WHERE i.PartNumber = N'6MA' AND rt.VersionNumber = 1)
    INSERT INTO Parts.RouteTemplate (ItemId, VersionNumber, Name, EffectiveFrom, PublishedAt, DeprecatedAt, CreatedByUserId, CreatedAt)
    SELECT i.Id, 1, N'6MA Assembly Route v1', '2026-01-15', '2026-01-14', NULL, u.Id, SYSUTCDATETIME()
    FROM Parts.Item i, Location.AppUser u WHERE i.PartNumber = N'6MA' AND u.Initials = N'DEV';

SET @RtId = (SELECT rt.Id FROM Parts.RouteTemplate rt INNER JOIN Parts.Item i ON i.Id = rt.ItemId WHERE i.PartNumber = N'6MA' AND rt.VersionNumber = 1);

IF NOT EXISTS (SELECT 1 FROM Parts.RouteStep WHERE RouteTemplateId = @RtId AND SequenceNumber = 1)
    INSERT INTO Parts.RouteStep (RouteTemplateId, OperationTemplateId, SequenceNumber, IsRequired, Description)
    SELECT @RtId, ot.Id, 1, 1, N'Assembly in' FROM Parts.OperationTemplate ot WHERE ot.Code = N'AssemblyIn';

IF NOT EXISTS (SELECT 1 FROM Parts.RouteStep WHERE RouteTemplateId = @RtId AND SequenceNumber = 2)
    INSERT INTO Parts.RouteStep (RouteTemplateId, OperationTemplateId, SequenceNumber, IsRequired, Description)
    SELECT @RtId, ot.Id, 2, 1, N'Assembly out' FROM Parts.OperationTemplate ot WHERE ot.Code = N'AssemblyOut';
GO

-- ---- 5G0-C: DieCastShot only ----
DECLARE @RtId BIGINT;

IF NOT EXISTS (SELECT 1 FROM Parts.RouteTemplate rt INNER JOIN Parts.Item i ON i.Id = rt.ItemId WHERE i.PartNumber = N'5G0-C' AND rt.VersionNumber = 1)
    INSERT INTO Parts.RouteTemplate (ItemId, VersionNumber, Name, EffectiveFrom, PublishedAt, DeprecatedAt, CreatedByUserId, CreatedAt)
    SELECT i.Id, 1, N'5G0-C Die Cast Route v1', '2026-01-15', '2026-01-14', NULL, u.Id, SYSUTCDATETIME()
    FROM Parts.Item i, Location.AppUser u WHERE i.PartNumber = N'5G0-C' AND u.Initials = N'DEV';

SET @RtId = (SELECT rt.Id FROM Parts.RouteTemplate rt INNER JOIN Parts.Item i ON i.Id = rt.ItemId WHERE i.PartNumber = N'5G0-C' AND rt.VersionNumber = 1);

IF NOT EXISTS (SELECT 1 FROM Parts.RouteStep WHERE RouteTemplateId = @RtId AND SequenceNumber = 1)
    INSERT INTO Parts.RouteStep (RouteTemplateId, OperationTemplateId, SequenceNumber, IsRequired, Description)
    SELECT @RtId, ot.Id, 1, 1, N'Die cast shot' FROM Parts.OperationTemplate ot WHERE ot.Code = N'DieCastShot';
GO

-- ---- 5G0-M: MachiningIn -> MachiningOut ----
DECLARE @RtId BIGINT;

IF NOT EXISTS (SELECT 1 FROM Parts.RouteTemplate rt INNER JOIN Parts.Item i ON i.Id = rt.ItemId WHERE i.PartNumber = N'5G0-M' AND rt.VersionNumber = 1)
    INSERT INTO Parts.RouteTemplate (ItemId, VersionNumber, Name, EffectiveFrom, PublishedAt, DeprecatedAt, CreatedByUserId, CreatedAt)
    SELECT i.Id, 1, N'5G0-M Machining Route v1', '2026-01-15', '2026-01-14', NULL, u.Id, SYSUTCDATETIME()
    FROM Parts.Item i, Location.AppUser u WHERE i.PartNumber = N'5G0-M' AND u.Initials = N'DEV';

SET @RtId = (SELECT rt.Id FROM Parts.RouteTemplate rt INNER JOIN Parts.Item i ON i.Id = rt.ItemId WHERE i.PartNumber = N'5G0-M' AND rt.VersionNumber = 1);

IF NOT EXISTS (SELECT 1 FROM Parts.RouteStep WHERE RouteTemplateId = @RtId AND SequenceNumber = 1)
    INSERT INTO Parts.RouteStep (RouteTemplateId, OperationTemplateId, SequenceNumber, IsRequired, Description)
    SELECT @RtId, ot.Id, 1, 1, N'Machining in' FROM Parts.OperationTemplate ot WHERE ot.Code = N'MachiningIn';

IF NOT EXISTS (SELECT 1 FROM Parts.RouteStep WHERE RouteTemplateId = @RtId AND SequenceNumber = 2)
    INSERT INTO Parts.RouteStep (RouteTemplateId, OperationTemplateId, SequenceNumber, IsRequired, Description)
    SELECT @RtId, ot.Id, 2, 1, N'Machining out' FROM Parts.OperationTemplate ot WHERE ot.Code = N'MachiningOut';
GO

-- ---- 5G0: AssemblyIn -> AssemblyOut ----
DECLARE @RtId BIGINT;

IF NOT EXISTS (SELECT 1 FROM Parts.RouteTemplate rt INNER JOIN Parts.Item i ON i.Id = rt.ItemId WHERE i.PartNumber = N'5G0' AND rt.VersionNumber = 1)
    INSERT INTO Parts.RouteTemplate (ItemId, VersionNumber, Name, EffectiveFrom, PublishedAt, DeprecatedAt, CreatedByUserId, CreatedAt)
    SELECT i.Id, 1, N'5G0 Assembly Route v1', '2026-01-15', '2026-01-14', NULL, u.Id, SYSUTCDATETIME()
    FROM Parts.Item i, Location.AppUser u WHERE i.PartNumber = N'5G0' AND u.Initials = N'DEV';

SET @RtId = (SELECT rt.Id FROM Parts.RouteTemplate rt INNER JOIN Parts.Item i ON i.Id = rt.ItemId WHERE i.PartNumber = N'5G0' AND rt.VersionNumber = 1);

IF NOT EXISTS (SELECT 1 FROM Parts.RouteStep WHERE RouteTemplateId = @RtId AND SequenceNumber = 1)
    INSERT INTO Parts.RouteStep (RouteTemplateId, OperationTemplateId, SequenceNumber, IsRequired, Description)
    SELECT @RtId, ot.Id, 1, 1, N'Assembly in' FROM Parts.OperationTemplate ot WHERE ot.Code = N'AssemblyIn';

IF NOT EXISTS (SELECT 1 FROM Parts.RouteStep WHERE RouteTemplateId = @RtId AND SequenceNumber = 2)
    INSERT INTO Parts.RouteStep (RouteTemplateId, OperationTemplateId, SequenceNumber, IsRequired, Description)
    SELECT @RtId, ot.Id, 2, 1, N'Assembly out' FROM Parts.OperationTemplate ot WHERE ot.Code = N'AssemblyOut';
GO

PRINT 'seed_item_routes: 6 published RouteTemplates (13 RouteSteps total) loaded for 6MA-C/6MA-M/6MA/5G0-C/5G0-M/5G0.';
GO
