-- ============================================================
-- Fix:         fix_subassembly_routes_to_assemblyout.sql
-- Author:      Blue Ridge Automation
-- Date:        2026-08-24
-- Description: Re-point every SubAssembly route step that resolves to the
--              MachiningOut ConsumeMint template at the AssemblyOut ConsumeMint
--              template instead.
--
--              WHY. Parts.OperationRoleKind 'ConsumeMint' marks the step at which a
--              part is CONSUMED, and Lots.Lot_GetWipQueueByLocation deliberately holds
--              a ConsumeMint step PENDING for as long as the LOT is open (that is what
--              keeps a decrementing casting in the Machining OUT queue across repeated
--              partial mints). A minted SubAssembly whose only route step was
--              MachiningOut therefore re-entered the very Machining OUT queue that had
--              just produced it -- and BlueRidge.Lots.Lot.mapMachiningOutQueue marks
--              every row selectable and default-selects the oldest, so an operator
--              could pick an already-machined LOT as a mint SOURCE.
--
--              A SubAssembly is consumed at ASSEMBLY OUT (Workorder.Assembly_CompleteTray
--              consumes SubAssembly + components into the FinishedGood), so AssemblyOut
--              is its correct terminal ConsumeMint. Route stays a single step: there is
--              no active AssemblyIn OperationTemplate, and AssemblyIn records no Advance
--              checkpoint, so an AssemblyIn step would strand the LOT permanently pending.
--
--              Shape matches the two SubAssemblies already corrected by hand in the
--              Config Tool (5G0-SA, 12270-6NA-M -> template A-Out-A).
--
--              Castings are NOT touched -- a casting's route legitimately ENDS at its
--              MachiningOut consume-mint. Scoped strictly to Parts.ItemType 'SubAssembly'.
--
--              Idempotent: re-running finds nothing to update. Read-only if the
--              database is already correct. ASCII-only.
--
--              Seed-side authority is fixed in the same change:
--                sql/scratch/seed_mpp_parts.sql   (26 catalog SubAssemblies)
--                sql/seeds/029_seed_item_routes.sql (5G0-SA, 12270-6NA-M)
--              Both seeds insert-if-not-exists, so they cannot repair an existing
--              database -- that is what this script is for.
-- ============================================================
SET NOCOUNT ON;
SET XACT_ABORT ON;

DECLARE @AssemblyOutTemplateId BIGINT = (
    SELECT TOP 1 ot.Id
    FROM Parts.OperationTemplate ot
    JOIN Parts.OperationType oty ON oty.Id = ot.OperationTypeId
    WHERE oty.Code = N'AssemblyOut' AND ot.DeprecatedAt IS NULL
    ORDER BY ot.Id);

IF @AssemblyOutTemplateId IS NULL
BEGIN
    RAISERROR(N'fix_subassembly_routes: no active AssemblyOut OperationTemplate; nothing done.', 16, 1);
    RETURN;
END

DECLARE @Targets TABLE (RouteStepId BIGINT PRIMARY KEY, PartNumber NVARCHAR(60), RouteTemplateId BIGINT);

INSERT INTO @Targets (RouteStepId, PartNumber, RouteTemplateId)
SELECT rs.Id, i.PartNumber, rt.Id
FROM Parts.RouteStep rs
JOIN Parts.RouteTemplate rt      ON rt.Id  = rs.RouteTemplateId
JOIN Parts.Item i                ON i.Id   = rt.ItemId
JOIN Parts.ItemType it           ON it.Id  = i.ItemTypeId
JOIN Parts.OperationTemplate ot  ON ot.Id  = rs.OperationTemplateId
JOIN Parts.OperationType oty     ON oty.Id = ot.OperationTypeId
WHERE it.Code  = N'SubAssembly'
  AND oty.Code = N'MachiningOut';

DECLARE @TargetCount INT = (SELECT COUNT(*) FROM @Targets);
PRINT 'fix_subassembly_routes: ' + CAST(@TargetCount AS VARCHAR(10)) + ' SubAssembly route step(s) to re-point.';

IF EXISTS (SELECT 1 FROM @Targets)
BEGIN
    BEGIN TRANSACTION;

    UPDATE rs
       SET rs.OperationTemplateId = @AssemblyOutTemplateId,
           rs.Description         = N'Assembly out'
    FROM Parts.RouteStep rs
    JOIN @Targets t ON t.RouteStepId = rs.Id;

    PRINT 'fix_subassembly_routes: ' + CAST(@@ROWCOUNT AS VARCHAR(10)) + ' route step(s) updated.';

    COMMIT TRANSACTION;
END
ELSE
    PRINT 'fix_subassembly_routes: nothing to do (already correct).';
GO

-- ---- verification: every SubAssembly route step, post-fix ----
SELECT i.PartNumber, rt.Id AS RouteId, rs.SequenceNumber AS Seq,
       oty.Code AS Role, rk.Code AS Kind, ot.Code AS TemplateCode
FROM Parts.Item i
JOIN Parts.ItemType it            ON it.Id  = i.ItemTypeId AND it.Code = N'SubAssembly'
JOIN Parts.RouteTemplate rt       ON rt.ItemId = i.Id AND rt.PublishedAt IS NOT NULL AND rt.DeprecatedAt IS NULL
JOIN Parts.RouteStep rs           ON rs.RouteTemplateId = rt.Id
JOIN Parts.OperationTemplate ot   ON ot.Id  = rs.OperationTemplateId
JOIN Parts.OperationType oty      ON oty.Id = ot.OperationTypeId
JOIN Parts.OperationRoleKind rk   ON rk.Id  = oty.OperationRoleKindId
WHERE i.DeprecatedAt IS NULL
ORDER BY i.PartNumber, rs.SequenceNumber;
GO
