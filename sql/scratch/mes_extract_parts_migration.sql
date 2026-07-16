/* ============================================================================
   mes_extract_parts_migration.sql  --  FULL part catalog extract for migration
   ----------------------------------------------------------------------------
   TARGET   Legacy "MES" database (SparkMES lineage) on EXCSRV05, SQL 2016.
   PURPOSE  Pull EVERYTHING about parts so we can migrate the catalog into our
            Parts schema, and so we have the raw material to reconstruct ROUTING
            + ELIGIBILITY (which the legacy system only expressed implicitly via
            WorkCellMaterial -- there are no route/operation tables).

   OUTPUT   Labeled grids #P1..#P10 (first column "#Px ..."). All small enough
            to Save Results As... CSV into reference/legacy_mes_extract/parts/.

   MAPPING NOTES (legacy -> our model)
     * ItemType is DERIVED, not stored. Real signals: MaterialClass.IsFinishedGood
       + Material.IsSupplyPart + BOM presence + produced/consumed pattern +
       part-number suffix. #P1 emits a SuggestedItemType but leave final
       classification to migration logic (SubAssembly vs Component vs Casting
       needs the routing pass).
     * Program (5A2 / RPY / 59B / ...) is a SEPARATE attribute, not the type.
       Derived two ways here (from MaterialClass name and from the part number)
       so they can be cross-checked.
     * BOMs are physically FLAT: BomComponent.ParentBomComponentID is NULL
       everywhere, and every BOM lists its OWN output as a self-component. #P3
       flags the self row (IsSelfRow=1) -- DROP it on import.
     * Data landmines: trailing spaces in Name (#P1 HasTrailingSpace), free-text
       messy Bom.Version, 'DO NOT USE'/'DNU'/'TEMP' names, mojibake dunnage.
     * WorkCellMaterial is the ELIGIBILITY set (part <-> cell, many-to-many).
       #P4 keeps IsDeleted rows too (flagged) so we see full + historical
       eligibility -- the feed for the routing-reconstruction phase.

   100% read-only; READ UNCOMMITTED so it never blocks the live DB.
   ============================================================================ */

USE MES;   -- confirm legacy DB name
GO

SET NOCOUNT ON;
SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;

/* ============================================================================
   #P1  MATERIAL  -- the migration master row per part, with derived signals
   ============================================================================ */
SELECT '#P1 MATERIAL' AS Grid,
       m.MaterialID,
       m.Name,
       CASE WHEN m.Name <> RTRIM(m.Name) THEN 1 ELSE 0 END        AS HasTrailingSpace,
       m.Description,
       mc.Name                                                    AS MaterialClass,
       LEFT(mc.Name + ' ', CHARINDEX(' ', mc.Name + ' ') - 1)     AS ProgramFromClass,
       RTRIM(p.prog)                                              AS ProgramFromPartNo,
       mc.IsFinishedGood,
       m.IsSupplyPart,
       /* best-guess type; refine in migration with the routing pass */
       CASE WHEN m.IsSupplyPart = 1        THEN 'SupplyPart'
            WHEN mc.IsFinishedGood = 1     THEN 'FinishedGood'
            WHEN m.Name LIKE '%-0000'      THEN 'Casting'          -- raw-cast heuristic
            ELSE 'Component'                                        -- machined/subassembly -> review
       END                                                        AS SuggestedItemType,
       m.Weight,
       uom.Name                                                   AS Uom,
       m.SortRecipeNumber,
       m.CountryOfOrigin,
       /* structural signals for classification + routing */
       CASE WHEN EXISTS (SELECT 1 FROM dbo.Bom b WHERE b.MaterialID = m.MaterialID)
            THEN 1 ELSE 0 END                                     AS HasBom,
       CASE WHEN EXISTS (SELECT 1 FROM dbo.BomComponent bc JOIN dbo.Bom b ON b.BomID = bc.BomID
                         WHERE bc.MaterialID = m.MaterialID AND b.MaterialID <> m.MaterialID)
            THEN 1 ELSE 0 END                                     AS UsedAsComponent,
       (SELECT COUNT(*) FROM dbo.WorkCellMaterial w
          WHERE w.MaterialID = m.MaterialID AND w.IsConsumptionPoint = 0 AND w.IsDeleted = 0) AS ProducedAtCells,
       (SELECT COUNT(*) FROM dbo.WorkCellMaterial w
          WHERE w.MaterialID = m.MaterialID AND w.IsConsumptionPoint = 1 AND w.IsDeleted = 0) AS ConsumedAtCells,
       m.CreatedTimestamp, m.ModifiedTimestamp
FROM dbo.Material m
LEFT JOIN dbo.MaterialClass  mc  ON mc.MaterialClassID  = m.MaterialClassID
LEFT JOIN dbo.UnitOfMeasure  uom ON uom.UnitOfMeasureID = m.UnitOfMeasureID
CROSS APPLY (SELECT afterDash = CASE WHEN CHARINDEX('-', m.Name) > 0
                                     THEN SUBSTRING(m.Name, CHARINDEX('-', m.Name) + 1, 200) ELSE '' END) a
CROSS APPLY (SELECT prog = CASE WHEN a.afterDash = '' THEN NULL
                                WHEN CHARINDEX('-', a.afterDash) > 0 THEN LEFT(a.afterDash, CHARINDEX('-', a.afterDash) - 1)
                                ELSE a.afterDash END) p
ORDER BY mc.IsFinishedGood DESC, mc.Name, m.Name;

/* ============================================================================
   #P2  BOM HEADERS  -- one per material + version (Version is free-text/messy)
   ============================================================================ */
SELECT '#P2 BOM' AS Grid,
       b.BomID, b.Version,
       b.MaterialID, m.Name AS Material, mc.Name AS MaterialClass, mc.IsFinishedGood,
       b.CreatedTimestamp, b.ModifiedTimestamp
FROM dbo.Bom b
LEFT JOIN dbo.Material m       ON m.MaterialID = b.MaterialID
LEFT JOIN dbo.MaterialClass mc ON mc.MaterialClassID = m.MaterialClassID
ORDER BY mc.IsFinishedGood DESC, m.Name, b.Version;

/* ============================================================================
   #P3  BOM COMPONENTS  -- the assembly structure (flat; self-row flagged)
        DROP rows where IsSelfRow=1 on import.  ParentBomComponentID is expected
        NULL throughout (kept so you can verify the flatness assumption).
   ============================================================================ */
SELECT '#P3 BOMCOMP' AS Grid,
       bc.BomComponentID, bc.BomID,
       b.MaterialID       AS BomMaterialID, bm.Name AS BomForMaterial,
       bc.ParentBomComponentID,
       bc.MaterialID      AS ComponentMaterialID, cm.Name AS ComponentMaterial,
       cmc.Name           AS ComponentClass,
       bc.Quantity, bc.UnitOfMeasure,
       CASE WHEN bc.MaterialID = b.MaterialID THEN 1 ELSE 0 END AS IsSelfRow
FROM dbo.BomComponent bc
LEFT JOIN dbo.Bom b            ON b.BomID = bc.BomID
LEFT JOIN dbo.Material bm      ON bm.MaterialID = b.MaterialID
LEFT JOIN dbo.Material cm      ON cm.MaterialID = bc.MaterialID
LEFT JOIN dbo.MaterialClass cmc ON cmc.MaterialClassID = cm.MaterialClassID
ORDER BY bc.BomID, IsSelfRow, cm.Name;

/* ============================================================================
   #P4  WORKCELL MATERIAL  == the implicit ROUTING / ELIGIBILITY set ==========
        Part <-> cell, many-to-many, with consume/produce + qty bounds + full
        location context. Keeps IsDeleted rows (flagged) for the historical
        eligibility picture. THIS is the primary feed for route reconstruction:
        per material, order the cells Casting -> Machining -> Assembly.
   ============================================================================ */
SELECT '#P4 WCMATERIAL' AS Grid,
       wcm.WorkCellMaterialID,
       wcm.MaterialID, m.Name AS Material, mc.Name AS MaterialClass, mc.IsFinishedGood,
       wcm.IsConsumptionPoint,       -- 1 = consumed here, 0 = produced here
       wcm.MinQuantity, wcm.MaxQuantity, wcm.DefaultQuantity,
       wcm.IsDeleted,
       wc.WorkCellID, wc.Name AS WorkCell,
       pl.Name AS ProductionLine, a.Name AS Area
FROM dbo.WorkCellMaterial wcm
LEFT JOIN dbo.Material m        ON m.MaterialID = wcm.MaterialID
LEFT JOIN dbo.MaterialClass mc  ON mc.MaterialClassID = m.MaterialClassID
LEFT JOIN dbo.WorkCell wc       ON wc.WorkCellID = wcm.WorkCellID
LEFT JOIN dbo.ProductionLine pl ON pl.ProductionLineID = wc.ProductionLineID
LEFT JOIN dbo.Area a            ON a.AreaID = pl.AreaID
ORDER BY m.Name, wcm.IsConsumptionPoint, a.Name, pl.Name, wc.Name;

/* ============================================================================
   #P5  PER-PART PROCESSING / PACKAGING ATTRIBUTES  (distinct, from WorkOrder)
        The Honda-relevant per-part config: customer, dunnage, tray size, camera
        /scale flags, recipe, identifier format, target weight. Deduped to the
        distinct combos actually used per produced part (+ activity so you can
        tell current config from stale).
   ============================================================================ */
SELECT '#P5 PARTCONFIG' AS Grid,
       pm.Name              AS ProducedPart,
       pmc.Name             AS ProducedClass,
       wo.Customer,
       wo.ReturnableDunnageCode,
       wo.TrayQuantity,
       wo.GroupTargetQuantity,
       wo.IsCameraProcessingEnabled,
       wo.IsScaleProcessingEnabled,
       wo.RecipeNumber,
       idf.Name             AS IdentifierFormat,
       wo.GroupTargetWeight, wo.GroupTargetWeightTolerance, twuom.Name AS TargetWeightUom,
       COUNT(*)             AS WorkOrderRows,
       MAX(CASE WHEN wo.IsActive = 1 THEN 1 ELSE 0 END) AS HasActiveWO,
       SUM(wo.CompletedQuantity) AS TotalCompleted
FROM dbo.WorkOrder wo
LEFT JOIN dbo.BomComponent bc  ON bc.BomComponentID = wo.BomComponentID
LEFT JOIN dbo.Material pm       ON pm.MaterialID = bc.MaterialID
LEFT JOIN dbo.MaterialClass pmc ON pmc.MaterialClassID = pm.MaterialClassID
LEFT JOIN dbo.IdentifierFormat idf ON idf.IdentifierFormatID = wo.IdentifierFormatID
LEFT JOIN dbo.UnitOfMeasure twuom  ON twuom.UnitOfMeasureID = wo.TargetWeightUnitOfMeasureID
GROUP BY pm.Name, pmc.Name, wo.Customer, wo.ReturnableDunnageCode, wo.TrayQuantity,
         wo.GroupTargetQuantity, wo.IsCameraProcessingEnabled, wo.IsScaleProcessingEnabled,
         wo.RecipeNumber, idf.Name, wo.GroupTargetWeight, wo.GroupTargetWeightTolerance, twuom.Name
ORDER BY pm.Name, wo.Customer;

/* ============================================================================
   #P6..#P10  SUPPORTING CODE / REFERENCE SETS
   ============================================================================ */
SELECT '#P6 UOM' AS Grid, UnitOfMeasureID, Name, PluralName, Abbreviation, DisplayOrder
FROM dbo.UnitOfMeasure ORDER BY DisplayOrder, Name;

SELECT '#P7 MATERIALCLASS' AS Grid, MaterialClassID, Name, Description, IsFinishedGood,
       LEFT(Name + ' ', CHARINDEX(' ', Name + ' ') - 1) AS ProgramGuess
FROM dbo.MaterialClass ORDER BY IsFinishedGood DESC, Name;

SELECT '#P8 IDENTFORMAT' AS Grid, IdentifierFormatID, Name, Description, Format,
       StartingCounterValue, EndingCounterValue, LastCounterValue, ResetIntervalInMinutes
FROM dbo.IdentifierFormat ORDER BY Name;

SELECT '#P9 LABELTEMPLATE' AS Grid, LabelTemplateID, Name, DisplayName, TemplatePath,
       CreatedTimestamp, ModifiedTimestamp
FROM dbo.LabelTemplate ORDER BY Name;

SELECT '#P10 CUSTOMER' AS Grid, CustomerID, Name, DisplayName
FROM offsite.Customer ORDER BY Name;
GO
