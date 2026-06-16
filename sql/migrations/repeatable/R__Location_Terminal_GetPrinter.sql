-- ============================================================
-- Repeatable:  R__Location_Terminal_GetPrinter.sql
-- Author:      Blue Ridge Automation
-- Modified:    2026-06-16
-- Version:     1.0
-- Description: Arc 2 Phase 4 (Spec 2 sec 5). Resolves the child Printer Location
--              of a Terminal + its Endpoint / Model LocationAttribute values, for
--              the onStartup printer-into-session resolution and the LTT dispatch
--              path. The Printer is a LocationTypeDefinition (Name 'Printer',
--              DefId 16) child of the Terminal. Read proc: one row (TOP 1) or empty
--              when the terminal has no Printer child (the no-printer / FALLBACK
--              terminal case -> session.custom.printer stays empty -> fail-fast on
--              dispatch). Endpoint/Model are LEFT-joined so a row returns even when
--              an attribute value is unset.
-- ============================================================
CREATE OR ALTER PROCEDURE Location.Terminal_GetPrinter
    @TerminalLocationId BIGINT
AS
BEGIN
    SET NOCOUNT ON;

    SELECT TOP 1
        p.Id              AS LocationId,
        p.Code            AS Code,
        p.Name            AS Name,
        epv.AttributeValue AS Endpoint,
        mdv.AttributeValue AS Model
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
    WHERE p.ParentLocationId = @TerminalLocationId
      AND def.Name = N'Printer'
      AND p.DeprecatedAt IS NULL
    ORDER BY p.SortOrder, p.Id;
END;
GO
