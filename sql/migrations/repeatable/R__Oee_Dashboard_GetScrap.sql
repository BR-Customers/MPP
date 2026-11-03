-- =============================================
-- Procedure:   Oee.Dashboard_GetScrap
-- Author:      Blue Ridge Automation
-- Created:     2026-10-30
-- Version:     1.0
--
-- Description:
--   The scrap panels (OEE dashboard spec
--   docs/superpowers/specs/2026-10-27-oee-dashboard-design.md v0.3.2 sec
--   5.3, 5.4, 6.4), read from the source rejects (Oee.ufn_ShiftScrap per
--   shift -- charged by defect code) and the good counts (Oee.ufn_ShiftGood).
--   Scope:
--     @LocationId  scrap charged to the location (a trim press reads its SHOP,
--                  D5) PLUS scrap found there but charged elsewhere, flagged
--                  IsFoundDownstream = 1 so the page greys it and leaves it out
--                  of the unit's quality (5.4)
--     @AreaFamily  everything charged to the family, found-downstream included
--     neither      everything charged to an area (the plant)
--   @GroupBy:
--     Defect  one row per (defect, part): the drill-down panel
--     Part    one row per part, with that part's good and quality: the trim
--             shop "scrap by part" table (parts with good but no scrap
--             included)
--     Line    one row per M&A line the scrap landed on, with its top defect
--             and its good and quality: the M&A "scrap by line" panel
--   Non-reject scrap is returned flagged (IsNonReject = 1) and never counts in
--   Quality.
--
-- Result set: GroupKey, DefectCode, DefectDescription, ItemId, PartNumber,
--   LocationId, LocationName, Good, Quantity, IsNonReject, IsFoundDownstream,
--   ChargedToFamily, FoundAtLocationName, Quality. Largest quantity first.
--
-- Change Log:
--   2026-10-30 - 1.0 - Initial version.
-- =============================================
CREATE OR ALTER PROCEDURE Oee.Dashboard_GetScrap
    @Zoom          NVARCHAR(5),
    @AnchorShiftId BIGINT,
    @AreaFamily    NVARCHAR(10) = NULL,
    @LocationId    BIGINT       = NULL,
    @GroupBy       NVARCHAR(10) = N'Defect'
AS
BEGIN
    SET NOCOUNT ON;

    -- a trim press reads its shop (trim scrap is shop-level, D5)
    DECLARE @Loc BIGINT = @LocationId;
    IF @Loc IS NOT NULL
        SELECT @Loc = CASE WHEN u.AreaFamily = N'trim' AND u.IsStation = 0 THEN u.ProductionAreaId ELSE @Loc END
        FROM Oee.ufn_OeeUnits() u WHERE u.LocationId = @LocationId;

    DECLARE @S TABLE (ChargeFamily NVARCHAR(10), UnitLocationId BIGINT, FoundAtLocationId BIGINT, ItemId BIGINT,
                      DefectCodeId BIGINT, Quantity BIGINT, IsNonReject BIT, IsFoundDownstream BIT);
    INSERT INTO @S
    SELECT s.ChargeFamily, s.UnitLocationId, s.FoundAtLocationId, s.ItemId, s.DefectCodeId,
           s.Quantity, s.IsNonReject, s.IsFoundDownstream
    FROM Oee.ufn_ShiftsForPeriod(@Zoom, @AnchorShiftId) p
    CROSS APPLY Oee.ufn_ShiftScrap(p.ShiftId) s
    WHERE (@Loc IS NOT NULL AND (s.UnitLocationId = @Loc OR (s.FoundAtLocationId = @Loc AND s.IsFoundDownstream = 1)))
       OR (@Loc IS NULL AND @AreaFamily IS NOT NULL AND s.ChargeFamily = @AreaFamily)
       OR (@Loc IS NULL AND @AreaFamily IS NULL AND s.ChargeFamily IS NOT NULL);

    DECLARE @G TABLE (UnitLocationId BIGINT, AreaFamily NVARCHAR(10), ItemId BIGINT, Good BIGINT);
    INSERT INTO @G
    SELECT g.UnitLocationId, g.AreaFamily, g.ItemId, g.Good
    FROM Oee.ufn_ShiftsForPeriod(@Zoom, @AnchorShiftId) p
    CROSS APPLY Oee.ufn_ShiftGood(p.ShiftId) g
    WHERE (@Loc IS NOT NULL AND g.UnitLocationId = @Loc)
       OR (@Loc IS NULL AND @AreaFamily IS NOT NULL AND g.AreaFamily = @AreaFamily)
       OR (@Loc IS NULL AND @AreaFamily IS NULL AND g.AreaFamily IS NOT NULL);

    IF @GroupBy = N'Part'
    BEGIN
        ;WITH Parts AS (
            SELECT ItemId FROM @S WHERE IsNonReject = 0 AND IsFoundDownstream = 0 AND ItemId IS NOT NULL
            UNION SELECT ItemId FROM @G WHERE ItemId IS NOT NULL
        )
        SELECT CAST(N'P' + CAST(pt.ItemId AS NVARCHAR(20)) AS NVARCHAR(60)) AS GroupKey,
               td.Code AS DefectCode, td.Description AS DefectDescription,
               pt.ItemId, i.PartNumber,
               CAST(NULL AS BIGINT) AS LocationId, CAST(NULL AS NVARCHAR(200)) AS LocationName,
               ISNULL(gd.Good, 0) AS Good, ISNULL(sc.Qty, 0) AS Quantity,
               CAST(0 AS BIT) AS IsNonReject, CAST(0 AS BIT) AS IsFoundDownstream,
               CAST(NULL AS NVARCHAR(10)) AS ChargedToFamily, CAST(NULL AS NVARCHAR(200)) AS FoundAtLocationName,
               CASE WHEN ISNULL(gd.Good, 0) + ISNULL(sc.Qty, 0) > 0
                    THEN CAST(CAST(ISNULL(gd.Good, 0) AS DECIMAL(19,6)) / (ISNULL(gd.Good, 0) + ISNULL(sc.Qty, 0)) AS DECIMAL(5,4)) END AS Quality
        FROM Parts pt
        INNER JOIN Parts.Item i ON i.Id = pt.ItemId
        OUTER APPLY (SELECT SUM(g.Good) AS Good FROM @G g WHERE g.ItemId = pt.ItemId) gd
        OUTER APPLY (SELECT SUM(s.Quantity) AS Qty FROM @S s
                     WHERE s.ItemId = pt.ItemId AND s.IsNonReject = 0 AND s.IsFoundDownstream = 0) sc
        OUTER APPLY (SELECT TOP 1 dc.Code, dc.Description FROM @S s INNER JOIN Quality.DefectCode dc ON dc.Id = s.DefectCodeId
                     WHERE s.ItemId = pt.ItemId AND s.IsNonReject = 0 AND s.IsFoundDownstream = 0
                     GROUP BY dc.Code, dc.Description ORDER BY SUM(s.Quantity) DESC, dc.Code) td
        ORDER BY ISNULL(sc.Qty, 0) DESC, i.PartNumber;
        RETURN;
    END

    IF @GroupBy = N'Line'
    BEGIN
        ;WITH Lines AS (
            SELECT DISTINCT s.UnitLocationId FROM @S s
            WHERE s.UnitLocationId IS NOT NULL AND s.IsNonReject = 0 AND s.IsFoundDownstream = 0
        )
        SELECT CAST(N'L' + CAST(ln.UnitLocationId AS NVARCHAR(20)) AS NVARCHAR(60)) AS GroupKey,
               td.Code AS DefectCode, td.Description AS DefectDescription,
               CAST(NULL AS BIGINT) AS ItemId, CAST(NULL AS NVARCHAR(100)) AS PartNumber,
               ln.UnitLocationId AS LocationId, l.Name AS LocationName,
               ISNULL(gd.Good, 0) AS Good, ISNULL(sc.Qty, 0) AS Quantity,
               CAST(0 AS BIT) AS IsNonReject, CAST(0 AS BIT) AS IsFoundDownstream,
               CAST(NULL AS NVARCHAR(10)) AS ChargedToFamily, CAST(NULL AS NVARCHAR(200)) AS FoundAtLocationName,
               CASE WHEN ISNULL(gd.Good, 0) + ISNULL(sc.Qty, 0) > 0
                    THEN CAST(CAST(ISNULL(gd.Good, 0) AS DECIMAL(19,6)) / (ISNULL(gd.Good, 0) + ISNULL(sc.Qty, 0)) AS DECIMAL(5,4)) END AS Quality
        FROM Lines ln
        INNER JOIN Location.Location l ON l.Id = ln.UnitLocationId
        OUTER APPLY (SELECT SUM(g.Good) AS Good FROM @G g WHERE g.UnitLocationId = ln.UnitLocationId) gd
        OUTER APPLY (SELECT SUM(s.Quantity) AS Qty FROM @S s
                     WHERE s.UnitLocationId = ln.UnitLocationId AND s.IsNonReject = 0 AND s.IsFoundDownstream = 0) sc
        OUTER APPLY (SELECT TOP 1 dc.Code, dc.Description FROM @S s INNER JOIN Quality.DefectCode dc ON dc.Id = s.DefectCodeId
                     WHERE s.UnitLocationId = ln.UnitLocationId AND s.IsNonReject = 0 AND s.IsFoundDownstream = 0
                     GROUP BY dc.Code, dc.Description ORDER BY SUM(s.Quantity) DESC, dc.Code) td
        ORDER BY ISNULL(sc.Qty, 0) DESC, l.Name;
        RETURN;
    END

    -- Defect (default): one row per (defect, part, flags)
    SELECT CAST(N'D' + CAST(s.DefectCodeId AS NVARCHAR(20)) + N'-' + ISNULL(CAST(s.ItemId AS NVARCHAR(20)), N'0')
                + N'-' + CAST(s.IsNonReject AS NVARCHAR(1)) + CAST(s.IsFoundDownstream AS NVARCHAR(1)) AS NVARCHAR(60)) AS GroupKey,
           dc.Code AS DefectCode, dc.Description AS DefectDescription,
           s.ItemId, i.PartNumber,
           CAST(NULL AS BIGINT) AS LocationId, CAST(NULL AS NVARCHAR(200)) AS LocationName,
           CAST(NULL AS BIGINT) AS Good, SUM(s.Quantity) AS Quantity,
           s.IsNonReject, s.IsFoundDownstream,
           s.ChargeFamily AS ChargedToFamily,
           MAX(fl.Name) AS FoundAtLocationName,
           CAST(NULL AS DECIMAL(5,4)) AS Quality
    FROM @S s
    INNER JOIN Quality.DefectCode dc ON dc.Id = s.DefectCodeId
    LEFT JOIN Parts.Item i           ON i.Id = s.ItemId
    LEFT JOIN Location.Location fl   ON fl.Id = s.FoundAtLocationId
    GROUP BY s.DefectCodeId, dc.Code, dc.Description, s.ItemId, i.PartNumber, s.IsNonReject, s.IsFoundDownstream, s.ChargeFamily
    ORDER BY SUM(s.Quantity) DESC, dc.Code;
END
GO
