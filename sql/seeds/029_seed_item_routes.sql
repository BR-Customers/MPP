-- ============================================================
-- Seed:        029_seed_item_routes.sql
-- Author:      Blue Ridge Automation
-- Date:        2026-07-13 (rewritten from the correct DB configuration)
-- Description: Published RouteTemplate + RouteStep rows for the 13-part Honda
--              matrix (020_seed_items.sql), matching the Config-Tool setup in
--              MPP_MES_Dev. Terminal-mint model: a casting's route carries the
--              chain THROUGH its consume-mint step; a machined SubAssembly/FG
--              picks up its route after birth.
--                * 5G0-c   : DieCast -> TrimIn -> TrimOut -> MachiningIn -> MachiningOut
--                * 5G0-SA  : MachiningOut
--                * 5G0-FG  : AssemblyOut
--                * 12231/12232/12241-59B-0000 : DieCast -> TrimIn -> TrimOut -> MachiningIn -> AssemblyOut
--                * 1223A-59B -A0002 : AssemblyOut
--                * 12270-6NA   : DieCast -> TrimIn -> TrimOut -> MachiningIn -> MachiningOut
--                * 12270-6NA-M : MachiningOut
--                * 12270-6NA -0001 : AssemblyOut
--
--              Steps resolve the OperationTemplate BY OperationType ROLE (via
--              Parts.OperationType.Code) -- robust to the specific template Code
--              (DieCastShot vs DC-A etc.); it binds to whichever active template
--              carries that role. Direct-INSERT (published v1), idempotent
--              (natural-key by PartNumber + VersionNumber / SequenceNumber).
--              ASCII-only.
--
--              Dependencies: 020_seed_items.sql (Items); 022/024/026/027
--              (one active OperationTemplate per role: DieCast, TrimIn, TrimOut,
--              MachiningIn, MachiningOut, AssemblyIn, AssemblyOut).
-- ============================================================
SET NOCOUNT ON;

DECLARE @Dev BIGINT = (SELECT Id FROM Location.AppUser WHERE Initials = N'DEV');

-- one published v1 RouteTemplate per processed item
DECLARE @R TABLE (Pn NVARCHAR(60), Name NVARCHAR(120));
INSERT INTO @R (Pn, Name) VALUES
 (N'5G0-c',            N'5G0-c Cast->Trim->Machine Route v1'),
 (N'5G0-SA',           N'5G0-SA Machining-Out Route v1'),
 (N'5G0-FG',           N'5G0-FG Assembly-Out Route v1'),
 (N'12231-59B-0000',   N'12231 Cast->Machine->Assembly Route v1'),
 (N'12232-59B-0000',   N'12232 Cast->Machine->Assembly Route v1'),
 (N'12241-59B-0000',   N'12241 Cast->Machine->Assembly Route v1'),
 (N'1223A-59B -A0002', N'1223A Assembly-Out Route v1'),
 (N'12270-6NA',        N'12270-6NA Cast->Trim->Machine Route v1'),
 (N'12270-6NA-M',      N'12270-6NA-M Machining-Out Route v1'),
 (N'12270-6NA -0001',  N'12270-6NA-0001 Assembly-Out Route v1');

-- ordered route steps, keyed by OperationType role
DECLARE @S TABLE (Pn NVARCHAR(60), Seq INT, Role NVARCHAR(30), Descr NVARCHAR(120));
INSERT INTO @S (Pn, Seq, Role, Descr) VALUES
 (N'5G0-c',1,N'DieCast',N'Die cast'),(N'5G0-c',2,N'TrimIn',N'Trim in'),(N'5G0-c',3,N'TrimOut',N'Trim out'),(N'5G0-c',4,N'MachiningIn',N'Machining in'),(N'5G0-c',5,N'MachiningOut',N'Machining out (mints 5G0-SA)'),
 (N'5G0-SA',1,N'MachiningOut',N'Machining out'),
 (N'5G0-FG',1,N'AssemblyOut',N'Assembly out'),
 (N'12231-59B-0000',1,N'DieCast',N'Die cast'),(N'12231-59B-0000',2,N'TrimIn',N'Trim in'),(N'12231-59B-0000',3,N'TrimOut',N'Trim out'),(N'12231-59B-0000',4,N'MachiningIn',N'Machining in'),(N'12231-59B-0000',5,N'AssemblyOut',N'Assembly out'),
 (N'12232-59B-0000',1,N'DieCast',N'Die cast'),(N'12232-59B-0000',2,N'TrimIn',N'Trim in'),(N'12232-59B-0000',3,N'TrimOut',N'Trim out'),(N'12232-59B-0000',4,N'MachiningIn',N'Machining in'),(N'12232-59B-0000',5,N'AssemblyOut',N'Assembly out'),
 (N'12241-59B-0000',1,N'DieCast',N'Die cast'),(N'12241-59B-0000',2,N'TrimIn',N'Trim in'),(N'12241-59B-0000',3,N'TrimOut',N'Trim out'),(N'12241-59B-0000',4,N'MachiningIn',N'Machining in'),(N'12241-59B-0000',5,N'AssemblyOut',N'Assembly out'),
 (N'1223A-59B -A0002',1,N'AssemblyOut',N'Assembly out'),
 (N'12270-6NA',1,N'DieCast',N'Die cast'),(N'12270-6NA',2,N'TrimIn',N'Trim in'),(N'12270-6NA',3,N'TrimOut',N'Trim out'),(N'12270-6NA',4,N'MachiningIn',N'Machining in'),(N'12270-6NA',5,N'MachiningOut',N'Machining out (mints 12270-6NA-M)'),
 (N'12270-6NA-M',1,N'MachiningOut',N'Machining out'),
 (N'12270-6NA -0001',1,N'AssemblyOut',N'Assembly out');

-- 1) RouteTemplate (published v1) per item
INSERT INTO Parts.RouteTemplate (ItemId, VersionNumber, Name, EffectiveFrom, PublishedAt, DeprecatedAt, CreatedByUserId, CreatedAt)
SELECT i.Id, 1, r.Name, '2026-01-15', '2026-01-14', NULL, @Dev, SYSUTCDATETIME()
FROM @R r JOIN Parts.Item i ON i.PartNumber = r.Pn
WHERE NOT EXISTS (SELECT 1 FROM Parts.RouteTemplate rt WHERE rt.ItemId = i.Id AND rt.VersionNumber = 1);

-- 2) RouteStep, resolving OperationTemplate by role (skips a role with no template)
INSERT INTO Parts.RouteStep (RouteTemplateId, OperationTemplateId, SequenceNumber, IsRequired, Description)
SELECT rt.Id, op.Id, s.Seq, 1, s.Descr
FROM @S s
JOIN Parts.Item i ON i.PartNumber = s.Pn
JOIN Parts.RouteTemplate rt ON rt.ItemId = i.Id AND rt.VersionNumber = 1
CROSS APPLY (
    SELECT TOP 1 o.Id
    FROM Parts.OperationTemplate o
    JOIN Parts.OperationType oty ON oty.Id = o.OperationTypeId
    WHERE oty.Code = s.Role AND o.DeprecatedAt IS NULL
    ORDER BY o.Id
) op
WHERE NOT EXISTS (SELECT 1 FROM Parts.RouteStep x WHERE x.RouteTemplateId = rt.Id AND x.SequenceNumber = s.Seq);
GO

PRINT 'seed_item_routes: 10 published routes (5G0/59B/6NA chains) with role-resolved steps loaded.';
GO
