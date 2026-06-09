-- =============================================
-- Procedure:   Location.Terminal_GetByIpAddress
-- Author:      Blue Ridge Automation
-- Created:     2026-06-09
-- Version:     1.0
--
-- Description:
--   Resolves the shop-floor Terminal Location for a connecting IP address
--   (Arc 2 Phase 1 session establishment). Reads the EAV IpAddress attribute
--   on the Terminal LocationTypeDefinition (DefId 7): the value lives on
--   Location.LocationAttribute.AttributeValue, the name 'IpAddress' lives on its
--   LocationAttributeDefinition. Returns, for the matched (active) Terminal:
--   its Id/Code/Name, its parent ("Zone") Id/Code/Name, the DefaultScreen
--   attribute value (NULL when unset), and a DERIVED TerminalMode:
--       'Dedicated'  when the parent Location is a Cell-tier Location,
--       'Shared'     when the parent is a WorkCenter- or Area-tier Location
--                    (and for any other / NULL parent tier).
--
--   This proc ALWAYS returns exactly one row and NEVER raises: when no active
--   Terminal matches @IpAddress (unknown IP, or the matched Terminal is
--   deprecated), it returns the global FALLBACK Terminal (Code
--   'FALLBACK-TERMINAL', seeded in migration 0020). A Terminal whose
--   DeprecatedAt is set is treated as no-match (-> fallback).
--
--   No OUTPUT params (Ignition JDBC). One result set.
--
-- Parameters:
--   @IpAddress NVARCHAR(50)  - connecting client IP. NULL / unknown -> fallback.
--
-- Result set (always one row):
--   TerminalId, TerminalCode, TerminalName,
--   ZoneId, ZoneCode, ZoneName,
--   DefaultScreen, TerminalMode, IsFallback
--
-- Dependencies:
--   Tables: Location.Location, Location.LocationAttribute,
--           Location.LocationAttributeDefinition, Location.LocationTypeDefinition,
--           Location.LocationType
--
-- Change Log:
--   2026-06-09 - 1.0 - Initial version (Phase 1 Task C).
-- =============================================
CREATE OR ALTER PROCEDURE Location.Terminal_GetByIpAddress
    @IpAddress NVARCHAR(50)
AS
BEGIN
    SET NOCOUNT ON;

    -- 1. Resolve the matched Terminal Location.Id by IpAddress attribute.
    --    Active Terminal only (DeprecatedAt IS NULL); attribute def is the
    --    Terminal-type (DefId 7) 'IpAddress' definition (active).
    DECLARE @TerminalId BIGINT = (
        SELECT TOP 1 la.LocationId
        FROM Location.LocationAttribute la
        INNER JOIN Location.LocationAttributeDefinition lad
            ON lad.Id = la.LocationAttributeDefinitionId
           AND lad.LocationTypeDefinitionId = 7
           AND lad.AttributeName = N'IpAddress'
           AND lad.DeprecatedAt IS NULL
        INNER JOIN Location.Location l
            ON l.Id = la.LocationId
           AND l.LocationTypeDefinitionId = 7
           AND l.DeprecatedAt IS NULL
        WHERE @IpAddress IS NOT NULL
          AND la.AttributeValue = @IpAddress
        ORDER BY la.LocationId
    );

    -- 2. No active match -> fall back to the global FALLBACK Terminal.
    DECLARE @IsFallback BIT = 0;
    IF @TerminalId IS NULL
    BEGIN
        SET @IsFallback = 1;
        SET @TerminalId = (SELECT Id FROM Location.Location WHERE Code = N'FALLBACK-TERMINAL');
    END

    -- 3. Project the Terminal + parent ("Zone") + DefaultScreen + derived mode.
    SELECT
        t.Id                                                AS TerminalId,
        t.Code                                              AS TerminalCode,
        t.Name                                              AS TerminalName,
        p.Id                                                AS ZoneId,
        p.Code                                              AS ZoneCode,
        p.Name                                              AS ZoneName,
        ds.AttributeValue                                   AS DefaultScreen,
        CAST(CASE WHEN plt.Code = N'Cell' THEN N'Dedicated'
                  ELSE N'Shared' END AS NVARCHAR(20))       AS TerminalMode,
        @IsFallback                                         AS IsFallback
    FROM Location.Location t
    LEFT JOIN Location.Location p
        ON p.Id = t.ParentLocationId
    LEFT JOIN Location.LocationTypeDefinition pltd
        ON pltd.Id = p.LocationTypeDefinitionId
    LEFT JOIN Location.LocationType plt
        ON plt.Id = pltd.LocationTypeId
    -- DefaultScreen attribute value for this Terminal (NULL when unset).
    LEFT JOIN (
        SELECT dsla.LocationId, dsla.AttributeValue
        FROM Location.LocationAttribute dsla
        INNER JOIN Location.LocationAttributeDefinition dslad
            ON dslad.Id = dsla.LocationAttributeDefinitionId
           AND dslad.LocationTypeDefinitionId = 7
           AND dslad.AttributeName = N'DefaultScreen'
           AND dslad.DeprecatedAt IS NULL
    ) ds ON ds.LocationId = t.Id
    WHERE t.Id = @TerminalId;
END;
GO
