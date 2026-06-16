-- =============================================
-- Procedure:   Location.Terminal_List
-- Author:      Blue Ridge Automation
-- Created:     2026-06-09
-- Version:     1.1
--
-- Description:
--   Admin rowset of all active (non-deprecated) Terminal Locations
--   (LocationTypeDefinition DefId 7), each with its parent ("Zone") names, its
--   IpAddress + DefaultScreen attribute values (NULL when unset),
--   and a HasPrinter validation flag (1 when the Terminal has at least one
--   active child Printer Location - every Terminal must carry >= 1 printer).
--   TerminalMode was REMOVED in v1.1 (view-policy model; FDS-02-010 v1.4).
--   Backs the terminal-registry admin surface.
--
--   The global FALLBACK Terminal (Code 'FALLBACK-TERMINAL') is INCLUDED - it is
--   a real, active Location and admins manage it alongside the rest.
--
--   No OUTPUT params (Ignition JDBC). One result set. Empty set only if no
--   Terminal Locations exist at all.
--
-- Parameters: none.
--
-- Result set (zero or more rows, ordered by TerminalCode):
--   TerminalId, TerminalCode, TerminalName,
--   ZoneId, ZoneCode, ZoneName,
--   IpAddress, DefaultScreen, IsFallback, HasPrinter
--
-- Dependencies:
--   Tables: Location.Location, Location.LocationAttribute,
--           Location.LocationAttributeDefinition, Location.LocationTypeDefinition
--
-- Change Log:
--   2026-06-09 - 1.0 - Initial version (Phase 1 Task C).
--   2026-06-10 - 1.1 - Drop derived TerminalMode; add HasPrinter flag.
-- =============================================
CREATE OR ALTER PROCEDURE Location.Terminal_List
AS
BEGIN
    SET NOCOUNT ON;

    SELECT
        t.Id                                                AS TerminalId,
        t.Code                                              AS TerminalCode,
        t.Name                                              AS TerminalName,
        p.Id                                                AS ZoneId,
        p.Code                                              AS ZoneCode,
        p.Name                                              AS ZoneName,
        ip.AttributeValue                                   AS IpAddress,
        ds.AttributeValue                                   AS DefaultScreen,
        CAST(CASE WHEN t.Code = N'FALLBACK-TERMINAL' THEN 1
                  ELSE 0 END AS BIT)                        AS IsFallback,
        CAST(CASE WHEN EXISTS (
            SELECT 1
            FROM Location.Location pr
            INNER JOIN Location.LocationTypeDefinition prd
                ON prd.Id = pr.LocationTypeDefinitionId
               AND prd.Code = N'Printer'
            WHERE pr.ParentLocationId = t.Id
              AND pr.DeprecatedAt IS NULL
        ) THEN 1 ELSE 0 END AS BIT)                         AS HasPrinter
    FROM Location.Location t
    LEFT JOIN Location.Location p
        ON p.Id = t.ParentLocationId
    LEFT JOIN (
        SELECT ipla.LocationId, ipla.AttributeValue
        FROM Location.LocationAttribute ipla
        INNER JOIN Location.LocationAttributeDefinition iplad
            ON iplad.Id = ipla.LocationAttributeDefinitionId
           AND iplad.LocationTypeDefinitionId = 7
           AND iplad.AttributeName = N'IpAddress'
           AND iplad.DeprecatedAt IS NULL
    ) ip ON ip.LocationId = t.Id
    LEFT JOIN (
        SELECT dsla.LocationId, dsla.AttributeValue
        FROM Location.LocationAttribute dsla
        INNER JOIN Location.LocationAttributeDefinition dslad
            ON dslad.Id = dsla.LocationAttributeDefinitionId
           AND dslad.LocationTypeDefinitionId = 7
           AND dslad.AttributeName = N'DefaultScreen'
           AND dslad.DeprecatedAt IS NULL
    ) ds ON ds.LocationId = t.Id
    WHERE t.LocationTypeDefinitionId = 7
      AND t.DeprecatedAt IS NULL
    ORDER BY t.Code;
END;
GO
