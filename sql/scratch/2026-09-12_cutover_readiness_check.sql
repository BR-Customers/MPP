-- =============================================
-- File:        sql/scratch/2026-09-12_cutover_readiness_check.sql
-- Purpose:     READ-ONLY pre-cutover checks for ONE M&A line. Run against the
--              target database before that line's inventory is scanned in.
--
--              Sections 1, 2, 5 and 6 should come back EMPTY. A row is something
--              to fix before anyone walks the rack with a scanner. Section 3 is
--              advisory (see its note) and section 4 is informational -- it
--              should return exactly one row.
--
-- Usage:       Set @LineCode and @EntryRole below, then run. No writes, no
--              transaction, safe against production.
--
-- Companion to: docs/superpowers/specs/2026-09-12-inventory-cutover-scan-design.md
-- =============================================
SET NOCOUNT ON;

DECLARE @LineCode  NVARCHAR(50) = N'MA1-5GOF';      -- <<< set per line
DECLARE @EntryRole NVARCHAR(30) = N'MachiningIn';   -- MachiningIn | AssemblyIn

DECLARE @Line BIGINT = (SELECT Id FROM Location.Location
                        WHERE Code = @LineCode AND DeprecatedAt IS NULL);
IF @Line IS NULL
BEGIN
    PRINT 'UNKNOWN LINE CODE -- check @LineCode against Location.Location. Stopping.';
    RETURN;
END

PRINT '';
PRINT '=== 1. BLOCKER: CASTINGS eligible here with NO entry step for the role ===';
PRINT '    Scoped to castings deliberately. EntryRouteSequence is a castings-only';
PRINT '    mechanism (design spec 3.4): a SubAssembly route is a single ConsumeMint';
PRINT '    step with nothing earlier to skip, and a purchased component has no route';
PRINT '    at all. Both surface correctly through Lot_GetComponentsAtCell without an';
PRINT '    entry point, so listing them here would be 13 rows of noise per line.';
PRINT '';
PRINT '    A CASTING with no step for the entry role, though, has no valid';
PRINT '    EntryRouteSequence and Lot_Create will refuse every basket of it.';
SELECT DISTINCT i.Id, i.PartNumber, i.Description
FROM Parts.v_EffectiveItemLocation e
INNER JOIN Parts.Item i      ON i.Id  = e.ItemId
WHERE e.LocationId IN (SELECT LocationId FROM Location.ufn_AncestorLocationIds(@Line))
      AND EXISTS (   -- "casting" = its route is minted at Die Cast. There is NO
                     -- 'Casting' ItemType in this model (the seeded codes are
                     -- RawMaterial / Component / SubAssembly / FinishedGood /
                     -- PassThrough -- a casting is a Component), so filtering by
                     -- item type silently matches nothing. Role is the authority,
                     -- consistent with the terminal-mint model.
              SELECT 1
              FROM Parts.RouteTemplate rt2
              INNER JOIN Parts.RouteStep rs2         ON rs2.RouteTemplateId = rt2.Id
              INNER JOIN Parts.OperationTemplate ot2 ON ot2.Id  = rs2.OperationTemplateId
              INNER JOIN Parts.OperationType oty2    ON oty2.Id = ot2.OperationTypeId
              INNER JOIN Parts.OperationRoleKind rk2 ON rk2.Id  = oty2.OperationRoleKindId
              WHERE rt2.ItemId = i.Id
                AND rt2.PublishedAt IS NOT NULL AND rt2.DeprecatedAt IS NULL
                AND rk2.Code = N'OriginMint')
  AND NOT EXISTS (
      SELECT 1
      FROM Parts.RouteTemplate rt
      INNER JOIN Parts.RouteStep rs         ON rs.RouteTemplateId = rt.Id
      INNER JOIN Parts.OperationTemplate ot ON ot.Id  = rs.OperationTemplateId
      INNER JOIN Parts.OperationType oty    ON oty.Id = ot.OperationTypeId
      WHERE rt.ItemId = i.Id
        AND rt.PublishedAt IS NOT NULL AND rt.DeprecatedAt IS NULL
        AND oty.Code = @EntryRole)
ORDER BY i.PartNumber;

PRINT '';
PRINT '=== 2. BLOCKER: castings eligible here with NO configured cavities ===';
PRINT '    The scan screen requires a cavity for a cast part. No ToolCavity rows';
PRINT '    means no buttons to tap and no die genealogy for Honda.';
SELECT DISTINCT i.Id, i.PartNumber
FROM Parts.v_EffectiveItemLocation e
INNER JOIN Parts.Item i      ON i.Id  = e.ItemId
WHERE e.LocationId IN (SELECT LocationId FROM Location.ufn_AncestorLocationIds(@Line))
      AND EXISTS (   -- "casting" = its route is minted at Die Cast. There is NO
                     -- 'Casting' ItemType in this model (the seeded codes are
                     -- RawMaterial / Component / SubAssembly / FinishedGood /
                     -- PassThrough -- a casting is a Component), so filtering by
                     -- item type silently matches nothing. Role is the authority,
                     -- consistent with the terminal-mint model.
              SELECT 1
              FROM Parts.RouteTemplate rt2
              INNER JOIN Parts.RouteStep rs2         ON rs2.RouteTemplateId = rt2.Id
              INNER JOIN Parts.OperationTemplate ot2 ON ot2.Id  = rs2.OperationTemplateId
              INNER JOIN Parts.OperationType oty2    ON oty2.Id = ot2.OperationTypeId
              INNER JOIN Parts.OperationRoleKind rk2 ON rk2.Id  = oty2.OperationRoleKindId
              WHERE rt2.ItemId = i.Id
                AND rt2.PublishedAt IS NOT NULL AND rt2.DeprecatedAt IS NULL
                AND rk2.Code = N'OriginMint')
  AND NOT EXISTS (SELECT 1 FROM Tools.ToolCavity tc
                  WHERE tc.ItemId = i.Id AND tc.DeprecatedAt IS NULL)
ORDER BY i.PartNumber;

PRINT '';
PRINT '=== 3. ADVISORY: parts whose MaxLotSize is below a real basket ===';
PRINT '    NOT a blocker as of 2026-09-12 -- Item.MaxLotSize is informational and';
PRINT '    an over-size basket creates successfully with a note in the message.';
PRINT '    Listed so you can raise the caps and stop every scan carrying a toast.';
SELECT DISTINCT i.Id, i.PartNumber, i.MaxLotSize
FROM Parts.v_EffectiveItemLocation e
INNER JOIN Parts.Item i ON i.Id = e.ItemId
WHERE e.LocationId IN (SELECT LocationId FROM Location.ufn_AncestorLocationIds(@Line))
  AND i.MaxLotSize IS NOT NULL
  AND i.MaxLotSize < 4000
ORDER BY i.MaxLotSize, i.PartNumber;

PRINT '';
PRINT '=== 4. INFO: where scanned stock will land (expect exactly ONE row) ===';
PRINT '    NULL DefaultStockLocationId resolves to the line itself, which is how';
PRINT '    M&A inventory works today. A different Code here means stock is being';
PRINT '    deposited somewhere else -- confirm that is intended.';
EXEC Location.Location_GetStockDestination @LineLocationId = @Line;

PRINT '';
PRINT '=== 5. INFO: parts with MORE THAN ONE die (operator must pick) ===';
PRINT '    Every other part resolves its die automatically -- measured on Dev';
PRINT '    2026-09-12, ALL 13 mapped parts resolve to exactly one die, so this';
PRINT '    comes back empty there. The scan screen only shows a die picker for';
PRINT '    rows listed here. Note the join to Parts.Item is load-bearing: cavities';
PRINT '    with a NULL ItemId would otherwise group together and look like one';
PRINT '    part running six dies.';
SELECT i.PartNumber, COUNT(DISTINCT tc.ToolId) AS DieCount
FROM Tools.ToolCavity tc
INNER JOIN Parts.Item i ON i.Id = tc.ItemId
WHERE tc.DeprecatedAt IS NULL
GROUP BY i.PartNumber
HAVING COUNT(DISTINCT tc.ToolId) > 1
ORDER BY COUNT(DISTINCT tc.ToolId) DESC, i.PartNumber;

PRINT '';
PRINT '=== 6. BLOCKER: SubAssembly LOTs where a Machining OUT terminal sees them ===';
PRINT '    A SubAssembly route is a single ConsumeMint step, which is pending for';
PRINT '    the life of the LOT -- so one sitting at a machining location appears in';
PRINT '    the mint SOURCE pick-list beside the raw castings, and an operator can';
PRINT '    select an already-machined LOT as input. Scan SubAssembly stock to an';
PRINT '    assembly-side location. See the design spec, section 11.';
SELECT l.Id, l.LotName, i.PartNumber, loc.Code AS AtLocation, l.PieceCount
FROM Lots.Lot l
INNER JOIN Parts.Item i          ON i.Id  = l.ItemId
INNER JOIN Parts.ItemType it     ON it.Id = i.ItemTypeId
INNER JOIN Location.Location loc ON loc.Id = l.CurrentLocationId
INNER JOIN Lots.LotStatusCode sc ON sc.Id = l.LotStatusId AND sc.Code <> N'Closed'
WHERE it.Code = N'SubAssembly'   -- a real seeded ItemType code, unlike 'Casting'
  AND EXISTS (SELECT 1 FROM Lots.ufn_NextPendingRouteStep(l.Id) ns
              WHERE ns.OperationTypeCode = N'MachiningOut')
ORDER BY loc.Code, l.LotName;

PRINT '';
PRINT '=== readiness check complete ===';
