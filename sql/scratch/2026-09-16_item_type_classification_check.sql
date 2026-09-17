/* =============================================================================
   Item-type classification check  --  READ-ONLY (SELECTs only)
   Target: MPP_MES_Prod                                          2026-09-16

   Question: can every part now typed 'Component' be split cleanly into
     - Component    = the die-cast part (FDS-03-002: "manufactured intermediate")
     - PassThrough  = vendor-supplied part (FDS-03-002: "not manufactured by MPP")
   using data we already hold?

   Evidence per item, each from a separate part of the model:
     Route     - does any route version (Draft/Published/Deprecated) carry a DieCast step?
     Tooling   - is the part on an active die cavity (Tools.ToolCavity.ItemId)?
     LOT birth - how its LOTs were born: Manufactured vs Received / ReceivedOffsite
     BOM       - is it a child on a published BOM (consumed) / a parent (produced)?
     Stocking  - consumption points at M&A (Parts.ItemLocation.IsConsumptionPoint)

   Result sets:
     #1  Current type distribution (active / deprecated)
     #2  Per-item evidence + proposed type + Verdict, disagreements first
     #3  Current type x proposed type x Verdict rollup
============================================================================= */
SET NOCOUNT ON;
SET ANSI_WARNINGS OFF;   -- silences 'Null value is eliminated by an aggregate' (STRING_AGG over non-first steps)
SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;   -- live plant: don't take shared locks

-- #1 -------------------------------------------------------------------------
SELECT  it.Code AS ItemType,
        COUNT(CASE WHEN i.Id IS NOT NULL AND i.DeprecatedAt IS NULL THEN 1 END) AS Active,
        COUNT(CASE WHEN i.DeprecatedAt IS NOT NULL THEN 1 END)                AS Deprecated
FROM    Parts.ItemType it
LEFT JOIN Parts.Item i ON i.ItemTypeId = it.Id
GROUP BY it.Id, it.Code
ORDER BY it.Id;

-- #2 -------------------------------------------------------------------------
IF OBJECT_ID('tempdb..#Ev') IS NOT NULL DROP TABLE #Ev;

SELECT  i.Id,
        i.PartNumber,
        i.Description,
        it.Code                                                  AS CurrentType,
        CASE WHEN i.DeprecatedAt IS NULL THEN 0 ELSE 1 END        AS IsDeprecated,
        r.RouteVersions,
        r.DieCastRoute,
        r.FirstStepOps,
        cav.ActiveCavities,
        lot.LotsManufactured,
        lot.LotsReceived,
        lot.OpenLots,
        bom.ChildOfPublishedBoms,
        bom.ParentOfPublishedBoms,
        cp.ConsumptionPoints,
        cc.HasContainerConfig
INTO    #Ev
FROM    Parts.Item i
JOIN    Parts.ItemType it ON it.Id = i.ItemTypeId
OUTER APPLY (
    SELECT  COUNT(DISTINCT rt.Id) AS RouteVersions,
            MAX(CASE WHEN oty.Code = N'DieCast' THEN 1 ELSE 0 END) AS DieCastRoute,
            STRING_AGG(CASE WHEN rs.SequenceNumber = f.MinSeq THEN oty.Code END, N',') AS FirstStepOps
    FROM    Parts.RouteTemplate rt
    JOIN    Parts.RouteStep rs          ON rs.RouteTemplateId = rt.Id
    JOIN    Parts.OperationTemplate ot  ON ot.Id = rs.OperationTemplateId
    JOIN    Parts.OperationType oty     ON oty.Id = ot.OperationTypeId
    CROSS APPLY (SELECT MIN(SequenceNumber) AS MinSeq
                 FROM Parts.RouteStep WHERE RouteTemplateId = rt.Id) f
    WHERE   rt.ItemId = i.Id
) r
OUTER APPLY (
    SELECT COUNT(*) AS ActiveCavities
    FROM   Tools.ToolCavity tc
    WHERE  tc.ItemId = i.Id AND tc.DeprecatedAt IS NULL
) cav
OUTER APPLY (
    SELECT  COUNT(CASE WHEN lo.Code = N'Manufactured' THEN 1 END)                    AS LotsManufactured,
            COUNT(CASE WHEN lo.Code IN (N'Received', N'ReceivedOffsite') THEN 1 END) AS LotsReceived,
            COUNT(CASE WHEN ls.Code NOT IN (N'Closed', N'Scrap') THEN 1 END)         AS OpenLots
    FROM    Lots.Lot l
    JOIN    Lots.LotOriginType lo ON lo.Id = l.LotOriginTypeId
    JOIN    Lots.LotStatusCode ls ON ls.Id = l.LotStatusId
    WHERE   l.ItemId = i.Id
) lot
OUTER APPLY (
    SELECT  (SELECT COUNT(DISTINCT b.Id) FROM Parts.Bom b JOIN Parts.BomLine bl ON bl.BomId = b.Id
             WHERE bl.ChildItemId = i.Id AND b.PublishedAt IS NOT NULL AND b.DeprecatedAt IS NULL) AS ChildOfPublishedBoms,
            (SELECT COUNT(*) FROM Parts.Bom b
             WHERE b.ParentItemId = i.Id AND b.PublishedAt IS NOT NULL AND b.DeprecatedAt IS NULL)  AS ParentOfPublishedBoms
) bom
OUTER APPLY (
    SELECT COUNT(*) AS ConsumptionPoints
    FROM   Parts.ItemLocation il
    WHERE  il.ItemId = i.Id AND il.DeprecatedAt IS NULL AND il.IsConsumptionPoint = 1
) cp
OUTER APPLY (
    SELECT CASE WHEN EXISTS (SELECT 1 FROM Parts.ContainerConfig c
                             WHERE c.ItemId = i.Id AND c.DeprecatedAt IS NULL) THEN 1 ELSE 0 END AS HasContainerConfig
) cc;

SELECT  e.*, p.ProposedType, v.Verdict
FROM    #Ev e
CROSS APPLY (SELECT CASE WHEN e.CurrentType NOT IN (N'Component', N'PassThrough') THEN NULL
                          WHEN e.DieCastRoute = 1 THEN N'Component' ELSE N'PassThrough' END AS ProposedType) p
CROSS APPLY (SELECT CASE
            WHEN p.ProposedType IS NULL                                    THEN N'n/a (not in scope)'
            -- the independent signals must agree before we trust the route
            WHEN e.DieCastRoute = 1 AND e.LotsReceived > 0                 THEN N'CONFLICT: cast route but received LOTs'
            WHEN ISNULL(e.DieCastRoute, 0) = 0 AND e.LotsManufactured > 0  THEN N'CONFLICT: no cast route but manufactured LOTs'
            WHEN ISNULL(e.DieCastRoute, 0) = 0 AND e.ActiveCavities > 0    THEN N'CONFLICT: on a die but no cast route'
            WHEN ISNULL(e.DieCastRoute, 0) = 0 AND e.RouteVersions > 0     THEN N'REVIEW: has a non-cast route'
            WHEN ISNULL(e.DieCastRoute, 0) = 0 AND e.ChildOfPublishedBoms = 0
                                                                           THEN N'REVIEW: no route, not consumed by any BOM'
            WHEN e.ParentOfPublishedBoms > 0                               THEN N'REVIEW: has its own BOM (assembly?)'
            WHEN e.CurrentType = p.ProposedType                            THEN N'OK (no change)'
            ELSE N'OK (reclassify)'
        END AS Verdict) v
ORDER BY
        CASE LEFT(v.Verdict, 2) WHEN N'CO' THEN 0 WHEN N'RE' THEN 1 WHEN N'OK' THEN 2 ELSE 3 END,
        e.IsDeprecated,
        p.ProposedType,
        e.PartNumber;

-- #3 -------------------------------------------------------------------------
SELECT  CurrentType, ProposedType,
        LEFT(Verdict, CHARINDEX(N':', Verdict + N':') - 1) AS VerdictClass,
        COUNT(*) AS Items,
        SUM(IsDeprecated) AS OfWhichDeprecated
FROM (
    SELECT  e.CurrentType, e.IsDeprecated,
            CASE WHEN e.CurrentType NOT IN (N'Component', N'PassThrough') THEN NULL
                 WHEN e.DieCastRoute = 1 THEN N'Component' ELSE N'PassThrough' END AS ProposedType,
            CASE
                WHEN e.CurrentType NOT IN (N'Component', N'PassThrough') THEN N'n/a'
                WHEN e.DieCastRoute = 1 AND e.LotsReceived > 0 THEN N'CONFLICT'
                WHEN ISNULL(e.DieCastRoute, 0) = 0 AND (e.LotsManufactured > 0 OR e.ActiveCavities > 0) THEN N'CONFLICT'
                WHEN ISNULL(e.DieCastRoute, 0) = 0 AND (e.RouteVersions > 0 OR e.ChildOfPublishedBoms = 0) THEN N'REVIEW'
                WHEN e.ParentOfPublishedBoms > 0 THEN N'REVIEW'
                ELSE N'OK'
            END AS Verdict
    FROM #Ev e
) x
GROUP BY CurrentType, ProposedType, LEFT(Verdict, CHARINDEX(N':', Verdict + N':') - 1)
ORDER BY CurrentType, ProposedType, VerdictClass;

DROP TABLE #Ev;
