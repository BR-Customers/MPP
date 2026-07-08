/* ============================================================================
   emmd_extract_master_data.sql  --  Phase 2: legacy master/reference extract
   ----------------------------------------------------------------------------
   TARGET   Legacy "MES" database (SparkMES lineage) on EXCSRV05, SQL 2016.
   SCOPE    Master / reference data only -- the small, stable tables that define
            the plant, the parts catalog, and product structure.  Transactional
            + genealogy tables (Lot*, SerializedItem*, *Transaction, *_Historical,
            VisionSystemEventLog, SystemLog) are intentionally EXCLUDED here;
            they are a separate traceability-validation pass.

   HOW TO RUN
     1. Open in SSMS, connect to EXCSRV05, confirm USE points at the legacy DB.
     2. Execute.  Emits ~10 labeled result grids (first column "#X ...").
     3. Copy each grid back.  They're small -- you can paste them in chunks
        (A-C first, then D-F) if that's easier.

   NOTES
     * FK ids are resolved to names so the grids are self-describing.
     * Legacy ids are kept alongside names so relationships stay unambiguous.
     * 100% read-only; READ UNCOMMITTED so it never blocks the live DB.
   ============================================================================ */

USE MES;   -- <-- confirm this is the legacy database name
GO

SET NOCOUNT ON;
SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;

/* ============================================================================
   #A  CODE / ENUM TABLES  (collapsed into one grid: Domain, Id, Name, ...)
   ----------------------------------------------------------------------------
   All the small state/type/disposition lookups in a single paste.  "Extra"
   carries the one notable flag/attribute per domain (e.g. IsFinishedGood).
   ============================================================================ */
SELECT '#A CODE' AS Grid, 'MaterialClass' AS Domain, MaterialClassID AS Id, Name,
       CAST(NULL AS nvarchar(100)) AS DisplayName,
       'IsFinishedGood=' + CAST(IsFinishedGood AS varchar(1)) AS Extra
FROM dbo.MaterialClass
UNION ALL SELECT '#A CODE','UnitOfMeasure', UnitOfMeasureID, Name, PluralName, 'Abbrev=' + Abbreviation FROM dbo.UnitOfMeasure
UNION ALL SELECT '#A CODE','LotState', LotStateID, Name, DisplayName, NULL FROM dbo.LotState
UNION ALL SELECT '#A CODE','ContainerState', ContainerStateID, Name, DisplayName, NULL FROM dbo.ContainerState
UNION ALL SELECT '#A CODE','SerializedItemState', SerializedItemStateID, Name, DisplayName, NULL FROM dbo.SerializedItemState
UNION ALL SELECT '#A CODE','Disposition', DispositionID, Name, DisplayName, NULL FROM dbo.Disposition
UNION ALL SELECT '#A CODE','LotTransactionType', LotTransactionTypeID, Name, DisplayName, NULL FROM dbo.LotTransactionType
UNION ALL SELECT '#A CODE','SubLotTransactionType', SubLotTransactionTypeID, Name, DisplayName, NULL FROM dbo.SubLotTransactionType
UNION ALL SELECT '#A CODE','SerializedItemTransactionType', SerializedItemTransactionTypeID, Name, DisplayName, NULL FROM dbo.SerializedItemTransactionType
UNION ALL SELECT '#A CODE','ProductionOrderState', ProductionOrderStateID, Name, DisplayName, NULL FROM dbo.ProductionOrderState
UNION ALL SELECT '#A CODE','WorkOrderState', WorkOrderStateID, Name, DisplayName, NULL FROM dbo.WorkOrderState
UNION ALL SELECT '#A CODE','VisionSystemEventType', VisionSystemEventTypeID, Name, DisplayName, NULL FROM dbo.VisionSystemEventType
UNION ALL SELECT '#A CODE','LotAttribute', LotAttributeID, Name, DisplayName, NULL FROM dbo.LotAttribute
UNION ALL SELECT '#A CODE','Role', RoleID, Name, NULL, NULL FROM dbo.Role
UNION ALL SELECT '#A CODE','Privilege', PrivilegeID, Name, DisplayName, NULL FROM dbo.Privilege
ORDER BY Domain, Id;

/* ============================================================================
   #B  LOCATION HIERARCHY  (ISA-95 tree, all 5 tiers in one grid)
   ----------------------------------------------------------------------------
   Tier / Id / Name / Parent tier+name so the whole plant tree reads top-down.
   "Extra" carries per-tier attributes (e.g. WorkCell.TrackingMode).
   ============================================================================ */
SELECT '#B LOCATION' AS Grid, 1 AS Tier, 'Site' AS TierName, s.SiteID AS Id, s.Name,
       CAST(NULL AS varchar(30)) AS ParentTier, CAST(NULL AS int) AS ParentId, CAST(NULL AS nvarchar(100)) AS ParentName,
       CAST(NULL AS varchar(60)) AS Extra
FROM dbo.Site s
UNION ALL
SELECT '#B LOCATION',2,'Area', a.AreaID, a.Name, 'Site', a.SiteID, s.Name, NULL
FROM dbo.Area a LEFT JOIN dbo.Site s ON s.SiteID = a.SiteID
UNION ALL
SELECT '#B LOCATION',3,'ProductionLine', pl.ProductionLineID, pl.Name, 'Area', pl.AreaID, a.Name, NULL
FROM dbo.ProductionLine pl LEFT JOIN dbo.Area a ON a.AreaID = pl.AreaID
UNION ALL
SELECT '#B LOCATION',4,'WorkCell', wc.WorkCellID, wc.Name, 'ProductionLine', wc.ProductionLineID, pl.Name,
       'TrackingMode=' + CAST(wc.TrackingMode AS varchar(3))
FROM dbo.WorkCell wc LEFT JOIN dbo.ProductionLine pl ON pl.ProductionLineID = wc.ProductionLineID
UNION ALL
SELECT '#B LOCATION',5,'Workstation', ws.WorkstationID, ws.Name, 'WorkCell', ws.WorkCellID, wc.Name,
       'Machine=' + ws.MachineName
FROM dbo.Workstation ws LEFT JOIN dbo.WorkCell wc ON wc.WorkCellID = ws.WorkCellID
ORDER BY Tier, ParentId, Id;

/* ============================================================================
   #B2  NAVIGATION LEVEL  (parallel navigation tree, separate from ISA-95)
   ============================================================================ */
SELECT '#B2 NAV' AS Grid, nl.NavigationLevelID AS Id, nl.Name, nl.[Level],
       nl.ParentNavigationLevelID AS ParentId, p.Name AS ParentName, nl.DisplayOrder
FROM dbo.NavigationLevel nl
LEFT JOIN dbo.NavigationLevel p ON p.NavigationLevelID = nl.ParentNavigationLevelID
ORDER BY nl.[Level], nl.DisplayOrder, nl.NavigationLevelID;

/* ============================================================================
   #C  MATERIAL (parts catalog)  -- full, class + UOM resolved
   ============================================================================ */
SELECT '#C MATERIAL' AS Grid, m.MaterialID AS Id, m.Name, m.Description,
       mc.Name AS MaterialClass, mc.IsFinishedGood,
       m.IsSupplyPart, m.Weight, uom.Name AS Uom,
       m.SortRecipeNumber, m.CountryOfOrigin
FROM dbo.Material m
LEFT JOIN dbo.MaterialClass mc ON mc.MaterialClassID = m.MaterialClassID
LEFT JOIN dbo.UnitOfMeasure  uom ON uom.UnitOfMeasureID = m.UnitOfMeasureID
ORDER BY mc.IsFinishedGood DESC, mc.Name, m.Name;

/* ============================================================================
   #D  BOM headers  -- one per material + version
   ============================================================================ */
SELECT '#D BOM' AS Grid, b.BomID AS Id, b.Version, b.MaterialID, m.Name AS Material,
       mc.Name AS MaterialClass, mc.IsFinishedGood
FROM dbo.Bom b
LEFT JOIN dbo.Material m       ON m.MaterialID = b.MaterialID
LEFT JOIN dbo.MaterialClass mc ON mc.MaterialClassID = m.MaterialClassID
ORDER BY mc.IsFinishedGood DESC, m.Name, b.Version;

/* ============================================================================
   #D2  BOM COMPONENTS  -- multi-level structure (ParentBomComponentID),
        with the parent material of the BOM + the component material resolved.
   ============================================================================ */
SELECT '#D2 BOMCOMP' AS Grid, bc.BomComponentID AS Id, bc.BomID,
       bm.Name AS BomForMaterial,
       bc.ParentBomComponentID AS ParentCompId,
       bc.MaterialID AS ComponentMaterialId, cm.Name AS ComponentMaterial,
       cmc.Name AS ComponentClass, bc.Quantity, bc.UnitOfMeasure
FROM dbo.BomComponent bc
LEFT JOIN dbo.Bom b            ON b.BomID = bc.BomID
LEFT JOIN dbo.Material bm      ON bm.MaterialID = b.MaterialID
LEFT JOIN dbo.Material cm      ON cm.MaterialID = bc.MaterialID
LEFT JOIN dbo.MaterialClass cmc ON cmc.MaterialClassID = cm.MaterialClassID
ORDER BY bc.BomID, bc.ParentBomComponentID, bc.BomComponentID;

/* ============================================================================
   #E  WORKCELL MATERIAL  -- the implicit "routing": which materials are
        consumed/produced at which work cell.  This is how we'll derive routes.
   ============================================================================ */
SELECT '#E WCMATERIAL' AS Grid, wcm.WorkCellMaterialID AS Id,
       wc.Name AS WorkCell, pl.Name AS ProductionLine, a.Name AS Area,
       m.Name AS Material, mc.Name AS MaterialClass, mc.IsFinishedGood,
       wcm.IsConsumptionPoint, wcm.MinQuantity, wcm.MaxQuantity, wcm.DefaultQuantity,
       wcm.IsDeleted
FROM dbo.WorkCellMaterial wcm
LEFT JOIN dbo.WorkCell wc      ON wc.WorkCellID = wcm.WorkCellID
LEFT JOIN dbo.ProductionLine pl ON pl.ProductionLineID = wc.ProductionLineID
LEFT JOIN dbo.Area a           ON a.AreaID = pl.AreaID
LEFT JOIN dbo.Material m       ON m.MaterialID = wcm.MaterialID
LEFT JOIN dbo.MaterialClass mc ON mc.MaterialClassID = m.MaterialClassID
WHERE wcm.IsDeleted = 0
ORDER BY a.Name, pl.Name, wc.Name, wcm.IsConsumptionPoint DESC, m.Name;

/* ============================================================================
   #F  PRODUCTION ORDERS  -- what gets run on a line, tied to a BOM
   ============================================================================ */
SELECT '#F PRODORDER' AS Grid, po.ProductionOrderID AS Id, po.Name,
       pl.Name AS ProductionLine, po.BomID, m.Name AS BomMaterial,
       pos.Name AS State, po.Sequence, po.RequiredQuantity, po.CompletedQuantity,
       po.RemainingQuantity
FROM dbo.ProductionOrder po
LEFT JOIN dbo.ProductionLine pl  ON pl.ProductionLineID = po.ProductionLineID
LEFT JOIN dbo.Bom b              ON b.BomID = po.BomID
LEFT JOIN dbo.Material m         ON m.MaterialID = b.MaterialID
LEFT JOIN dbo.ProductionOrderState pos ON pos.ProductionOrderStateID = po.ProductionOrderStateID
ORDER BY po.Sequence, po.ProductionOrderID;

/* ============================================================================
   #F2  WORK ORDERS  -- the join hub: produced part resolved via BomComponent,
        plus the Honda-relevant attributes (customer, dunnage, tray, recipe).
   ============================================================================ */
SELECT '#F2 WORKORDER' AS Grid, wo.WorkOrderID AS Id,
       po.Name AS ProductionOrder, wc.Name AS WorkCell,
       wo.BomComponentID, pm.Name AS ProducedPart, pmc.Name AS ProducedClass,
       wos.Name AS State, wo.IsActive, wo.RequiredQuantity, wo.CompletedQuantity,
       wo.Customer, wo.ReturnableDunnageCode, wo.TrayQuantity,
       wo.IsCameraProcessingEnabled, wo.IsScaleProcessingEnabled, wo.RecipeNumber
FROM dbo.WorkOrder wo
LEFT JOIN dbo.ProductionOrder po ON po.ProductionOrderID = wo.ProductionOrderID
LEFT JOIN dbo.WorkCell wc        ON wc.WorkCellID = wo.WorkCellID
LEFT JOIN dbo.BomComponent bc    ON bc.BomComponentID = wo.BomComponentID
LEFT JOIN dbo.Material pm        ON pm.MaterialID = bc.MaterialID
LEFT JOIN dbo.MaterialClass pmc  ON pmc.MaterialClassID = pm.MaterialClassID
LEFT JOIN dbo.WorkOrderState wos ON wos.WorkOrderStateID = wo.WorkOrderStateID
ORDER BY wo.WorkOrderID;

/* ============================================================================
   #G  CUSTOMERS + LABELING / IDENTIFIER CONFIG  (small reference sets)
   ============================================================================ */
SELECT '#G CUSTOMER' AS Grid, CustomerID AS Id, Name, DisplayName FROM offsite.Customer
ORDER BY Name;

SELECT '#G2 IDENTFMT' AS Grid, IdentifierFormatID AS Id, Name, Format,
       StartingCounterValue, EndingCounterValue, ResetIntervalInMinutes
FROM dbo.IdentifierFormat
ORDER BY Name;

SELECT '#G3 LABELTMPL' AS Grid, LabelTemplateID AS Id, Name, DisplayName, TemplatePath
FROM dbo.LabelTemplate
ORDER BY Name;
GO
