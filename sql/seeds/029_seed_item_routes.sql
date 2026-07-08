-- ============================================================
-- Seed:        029_seed_item_routes.sql
-- Author:      Blue Ridge Automation
-- Date:        2026-07-07 (terminal-mint re-author)
-- Description: Continuous Demo Seed Dataset (Task 1). Published RouteTemplate
--              + RouteStep rows for the processed items, authored to the
--              TERMINAL-MINT model (spec 2026-07-07, Model Y + decision C):
--
--                * A CASTING's route carries the full chain THROUGH its
--                  consume-mint. The casting is consumed at Machining OUT
--                  (mints the machined SubAssembly), so MachiningIn + MachiningOut
--                  live on the CASTING's route -- not the machined part's.
--                    6MA-C: DieCast -> TrimIn -> TrimOut -> MachiningIn -> MachiningOut
--                    5G0-C: DieCast -> MachiningIn -> MachiningOut   (5G0 skips trim)
--                * A SubAssembly picks up its route AFTER birth (it is born at the
--                  casting's Machining OUT); it is consumed at Assembly OUT (mints
--                  the finished good).
--                    6MA-M: AssemblyIn -> AssemblyOut
--                    5G0-M: AssemblyOut                (serialized line, no Assembly-In terminal)
--                * A FINISHED GOOD is the OUTPUT of Assembly OUT -- it has NO route
--                  of its own (born there, then packaged/shipped). 6MA / 5G0 get none.
--
--              Route legality (spec §4.2) holds: each non-FG route ends at a single
--              ConsumeMint step (Machining/Assembly OUT), an OriginMint (DieCast) is
--              first. Direct-INSERT (published), idempotent (IF NOT EXISTS guards,
--              natural-key by PartNumber / Code / Initials). ASCII-only.
--
--              Dependencies: 020_seed_items.sql (Items), 022/024/026/027
--              (OperationTemplate Codes: DieCastShot, TrimIn/Out, MachiningIn/Out,
--              AssemblyIn/Out).
-- ============================================================

-- ---- 6MA-C (casting): DieCast -> TrimIn -> TrimOut -> MachiningIn -> MachiningOut ----
DECLARE @RtId BIGINT;
IF NOT EXISTS (SELECT 1 FROM Parts.RouteTemplate rt INNER JOIN Parts.Item i ON i.Id = rt.ItemId WHERE i.PartNumber = N'6MA-C' AND rt.VersionNumber = 1)
    INSERT INTO Parts.RouteTemplate (ItemId, VersionNumber, Name, EffectiveFrom, PublishedAt, DeprecatedAt, CreatedByUserId, CreatedAt)
    SELECT i.Id, 1, N'6MA-C Cast->Trim->Machine Route v1', '2026-01-15', '2026-01-14', NULL, u.Id, SYSUTCDATETIME()
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
IF NOT EXISTS (SELECT 1 FROM Parts.RouteStep WHERE RouteTemplateId = @RtId AND SequenceNumber = 4)
    INSERT INTO Parts.RouteStep (RouteTemplateId, OperationTemplateId, SequenceNumber, IsRequired, Description)
    SELECT @RtId, ot.Id, 4, 1, N'Machining in' FROM Parts.OperationTemplate ot WHERE ot.Code = N'MachiningIn';
IF NOT EXISTS (SELECT 1 FROM Parts.RouteStep WHERE RouteTemplateId = @RtId AND SequenceNumber = 5)
    INSERT INTO Parts.RouteStep (RouteTemplateId, OperationTemplateId, SequenceNumber, IsRequired, Description)
    SELECT @RtId, ot.Id, 5, 1, N'Machining out (mints 6MA-M)' FROM Parts.OperationTemplate ot WHERE ot.Code = N'MachiningOut';
GO

-- ---- 6MA-M (sub-assembly): AssemblyIn -> AssemblyOut ----
DECLARE @RtId BIGINT;
IF NOT EXISTS (SELECT 1 FROM Parts.RouteTemplate rt INNER JOIN Parts.Item i ON i.Id = rt.ItemId WHERE i.PartNumber = N'6MA-M' AND rt.VersionNumber = 1)
    INSERT INTO Parts.RouteTemplate (ItemId, VersionNumber, Name, EffectiveFrom, PublishedAt, DeprecatedAt, CreatedByUserId, CreatedAt)
    SELECT i.Id, 1, N'6MA-M Assembly Route v1', '2026-01-15', '2026-01-14', NULL, u.Id, SYSUTCDATETIME()
    FROM Parts.Item i, Location.AppUser u WHERE i.PartNumber = N'6MA-M' AND u.Initials = N'DEV';
SET @RtId = (SELECT rt.Id FROM Parts.RouteTemplate rt INNER JOIN Parts.Item i ON i.Id = rt.ItemId WHERE i.PartNumber = N'6MA-M' AND rt.VersionNumber = 1);
IF NOT EXISTS (SELECT 1 FROM Parts.RouteStep WHERE RouteTemplateId = @RtId AND SequenceNumber = 1)
    INSERT INTO Parts.RouteStep (RouteTemplateId, OperationTemplateId, SequenceNumber, IsRequired, Description)
    SELECT @RtId, ot.Id, 1, 1, N'Assembly in' FROM Parts.OperationTemplate ot WHERE ot.Code = N'AssemblyIn';
IF NOT EXISTS (SELECT 1 FROM Parts.RouteStep WHERE RouteTemplateId = @RtId AND SequenceNumber = 2)
    INSERT INTO Parts.RouteStep (RouteTemplateId, OperationTemplateId, SequenceNumber, IsRequired, Description)
    SELECT @RtId, ot.Id, 2, 1, N'Assembly out (mints 6MA)' FROM Parts.OperationTemplate ot WHERE ot.Code = N'AssemblyOut';
GO

-- ---- 6MA (finished good): NO route (born at 6MA-M's Assembly OUT; packaged/shipped) ----

-- ---- 5G0-C (casting): DieCast -> MachiningIn -> MachiningOut ----
DECLARE @RtId BIGINT;
IF NOT EXISTS (SELECT 1 FROM Parts.RouteTemplate rt INNER JOIN Parts.Item i ON i.Id = rt.ItemId WHERE i.PartNumber = N'5G0-C' AND rt.VersionNumber = 1)
    INSERT INTO Parts.RouteTemplate (ItemId, VersionNumber, Name, EffectiveFrom, PublishedAt, DeprecatedAt, CreatedByUserId, CreatedAt)
    SELECT i.Id, 1, N'5G0-C Cast->Machine Route v1', '2026-01-15', '2026-01-14', NULL, u.Id, SYSUTCDATETIME()
    FROM Parts.Item i, Location.AppUser u WHERE i.PartNumber = N'5G0-C' AND u.Initials = N'DEV';
SET @RtId = (SELECT rt.Id FROM Parts.RouteTemplate rt INNER JOIN Parts.Item i ON i.Id = rt.ItemId WHERE i.PartNumber = N'5G0-C' AND rt.VersionNumber = 1);
IF NOT EXISTS (SELECT 1 FROM Parts.RouteStep WHERE RouteTemplateId = @RtId AND SequenceNumber = 1)
    INSERT INTO Parts.RouteStep (RouteTemplateId, OperationTemplateId, SequenceNumber, IsRequired, Description)
    SELECT @RtId, ot.Id, 1, 1, N'Die cast shot' FROM Parts.OperationTemplate ot WHERE ot.Code = N'DieCastShot';
IF NOT EXISTS (SELECT 1 FROM Parts.RouteStep WHERE RouteTemplateId = @RtId AND SequenceNumber = 2)
    INSERT INTO Parts.RouteStep (RouteTemplateId, OperationTemplateId, SequenceNumber, IsRequired, Description)
    SELECT @RtId, ot.Id, 2, 1, N'Machining in' FROM Parts.OperationTemplate ot WHERE ot.Code = N'MachiningIn';
IF NOT EXISTS (SELECT 1 FROM Parts.RouteStep WHERE RouteTemplateId = @RtId AND SequenceNumber = 3)
    INSERT INTO Parts.RouteStep (RouteTemplateId, OperationTemplateId, SequenceNumber, IsRequired, Description)
    SELECT @RtId, ot.Id, 3, 1, N'Machining out (mints 5G0-M)' FROM Parts.OperationTemplate ot WHERE ot.Code = N'MachiningOut';
GO

-- ---- 5G0-M (sub-assembly): AssemblyOut (serialized line, no Assembly-In terminal) ----
DECLARE @RtId BIGINT;
IF NOT EXISTS (SELECT 1 FROM Parts.RouteTemplate rt INNER JOIN Parts.Item i ON i.Id = rt.ItemId WHERE i.PartNumber = N'5G0-M' AND rt.VersionNumber = 1)
    INSERT INTO Parts.RouteTemplate (ItemId, VersionNumber, Name, EffectiveFrom, PublishedAt, DeprecatedAt, CreatedByUserId, CreatedAt)
    SELECT i.Id, 1, N'5G0-M Serialized Assembly Route v1', '2026-01-15', '2026-01-14', NULL, u.Id, SYSUTCDATETIME()
    FROM Parts.Item i, Location.AppUser u WHERE i.PartNumber = N'5G0-M' AND u.Initials = N'DEV';
SET @RtId = (SELECT rt.Id FROM Parts.RouteTemplate rt INNER JOIN Parts.Item i ON i.Id = rt.ItemId WHERE i.PartNumber = N'5G0-M' AND rt.VersionNumber = 1);
IF NOT EXISTS (SELECT 1 FROM Parts.RouteStep WHERE RouteTemplateId = @RtId AND SequenceNumber = 1)
    INSERT INTO Parts.RouteStep (RouteTemplateId, OperationTemplateId, SequenceNumber, IsRequired, Description)
    SELECT @RtId, ot.Id, 1, 1, N'Assembly out (serialized; mints 5G0)' FROM Parts.OperationTemplate ot WHERE ot.Code = N'AssemblyOut';
GO

-- ---- 5G0 (finished good): NO route (born at 5G0-M's Assembly OUT; packaged/shipped) ----

PRINT 'seed_item_routes: terminal-mint routes loaded (6MA-C x5, 6MA-M x2, 5G0-C x3, 5G0-M x1 steps; FGs 6MA/5G0 unrouted).';
GO
