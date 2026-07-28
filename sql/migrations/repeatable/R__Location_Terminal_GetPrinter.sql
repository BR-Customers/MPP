-- ============================================================
-- Repeatable:  R__Location_Terminal_GetPrinter.sql
-- Author:      Blue Ridge Automation
-- Modified:    2026-07-28
-- Version:     2.0
-- Description: Resolves a Terminal's child Printer Location + its Endpoint / Model /
--              LabelTypes attribute values, for the onStartup session resolution and
--              the label dispatch path.
--
--              v2.0 (design 2026-07-28 sec 3.4): optional @LabelTypeCode routes to the
--              printer whose LabelTypes CSV contains that code. No match -- or a blank
--              LabelTypes, or @LabelTypeCode NULL -- FALLS BACK to the terminal's first
--              printer by SortOrder, which is v1 behaviour exactly. That fallback is
--              what makes every existing caller and every seeded printer unaffected.
--
--              Read proc: one row or empty when the terminal has no Printer child (the
--              no-printer / FALLBACK terminal case -> fail-fast on dispatch). All three
--              attributes LEFT-joined so a row returns even when a value is unset.
-- ============================================================
CREATE OR ALTER PROCEDURE Location.Terminal_GetPrinter
    @TerminalLocationId BIGINT,
    @LabelTypeCode      NVARCHAR(50) = NULL
AS
BEGIN
    SET NOCOUNT ON;

    ;WITH Candidates AS (
        SELECT
            p.Id               AS LocationId,
            p.Code             AS Code,
            p.Name             AS Name,
            epv.AttributeValue AS Endpoint,
            mdv.AttributeValue AS Model,
            ltv.AttributeValue AS LabelTypes,
            p.SortOrder        AS SortOrder,
            -- 0 sorts ahead of 1: an explicit label-type match wins, everything
            -- else falls through to the SortOrder ordering below.
            CASE WHEN @LabelTypeCode IS NOT NULL
                  AND ltv.AttributeValue IS NOT NULL
                  AND N',' + REPLACE(ltv.AttributeValue, N' ', N'') + N','
                      LIKE N'%,' + @LabelTypeCode + N',%'
                 THEN 0 ELSE 1 END AS MatchRank
        FROM Location.Location p
        INNER JOIN Location.LocationTypeDefinition def ON def.Id = p.LocationTypeDefinitionId
        LEFT JOIN Location.LocationAttributeDefinition epd
            ON epd.LocationTypeDefinitionId = def.Id AND epd.AttributeName = N'Endpoint' AND epd.DeprecatedAt IS NULL
        LEFT JOIN Location.LocationAttribute epv
            ON epv.LocationId = p.Id AND epv.LocationAttributeDefinitionId = epd.Id
        LEFT JOIN Location.LocationAttributeDefinition mdd
            ON mdd.LocationTypeDefinitionId = def.Id AND mdd.AttributeName = N'Model' AND mdd.DeprecatedAt IS NULL
        LEFT JOIN Location.LocationAttribute mdv
            ON mdv.LocationId = p.Id AND mdv.LocationAttributeDefinitionId = mdd.Id
        LEFT JOIN Location.LocationAttributeDefinition ltd
            ON ltd.LocationTypeDefinitionId = def.Id AND ltd.AttributeName = N'LabelTypes' AND ltd.DeprecatedAt IS NULL
        LEFT JOIN Location.LocationAttribute ltv
            ON ltv.LocationId = p.Id AND ltv.LocationAttributeDefinitionId = ltd.Id
        WHERE p.ParentLocationId = @TerminalLocationId
          AND def.Name = N'Printer'
          AND p.DeprecatedAt IS NULL
    )
    SELECT TOP 1
        LocationId, Code, Name, Endpoint, Model, LabelTypes
    FROM Candidates
    ORDER BY MatchRank, SortOrder, LocationId;
END;
GO
