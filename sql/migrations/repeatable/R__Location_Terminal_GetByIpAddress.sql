-- =============================================
-- Procedure:   Location.Terminal_GetByIpAddress
-- Author:      Blue Ridge Automation
-- Created:     2026-06-09
-- Version:     1.1
--
-- Description:
--   Resolves the shop-floor Terminal Location for a connecting IP address
--   (Arc 2 Phase 1 session establishment). Reads the EAV IpAddress attribute
--   on the Terminal LocationTypeDefinition (DefId 7): the value lives on
--   Location.LocationAttribute.AttributeValue, the name 'IpAddress' lives on its
--   LocationAttributeDefinition. Returns, for the matched (active) Terminal:
--   its Id/Code/Name, its parent ("Zone") Id/Code/Name, the DefaultScreen
--   attribute value (NULL when unset). TerminalMode was REMOVED in v1.1:
--   terminal behavior (dedicated vs shared) is a property of the assigned
--   view per FDS-02-010 (view-policy model) and the spec
--   docs/superpowers/specs/2026-06-10-terminal-mode-view-policy-design.md.
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
--   @IpAddress NVARCHAR(45)  - connecting client IP (max IPv6 canonical length).
--                              NULL / unknown -> fallback.
--
-- Result set (always one row, except the seed-missing degenerate case below):
--   TerminalLocationId, TerminalCode, TerminalName,
--   ZoneLocationId, ZoneCode, ZoneName,
--   DefaultScreen, IsFallback
--
-- Dependencies:
--   Tables: Location.Location, Location.LocationAttribute,
--           Location.LocationAttributeDefinition
--
-- Change Log:
--   2026-06-09 - 1.0 - Initial version (Phase 1 Task C).
--   2026-06-10 - 1.1 - Drop derived TerminalMode (view-policy model).
-- =============================================
CREATE OR ALTER PROCEDURE Location.Terminal_GetByIpAddress
    @IpAddress NVARCHAR(45)
AS
BEGIN
    SET NOCOUNT ON;

    -- 1. Resolve the matched Terminal Location.Id by IpAddress attribute.
    --    Active Terminal only (DeprecatedAt IS NULL); attribute def is the
    --    Terminal-type (DefId 7) 'IpAddress' definition (active).
    --    Tie-break: if two active Terminals are misconfigured with the SAME
    --    IpAddress (no DB constraint enforces uniqueness across Locations),
    --    the lowest LocationId wins DETERMINISTICALLY. Duplicate-IP detection
    --    belongs in admin-side validation, not here.
    DECLARE @TerminalLocationId BIGINT = (
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
    IF @TerminalLocationId IS NULL
    BEGIN
        SET @IsFallback = 1;
        SET @TerminalLocationId = (SELECT Id FROM Location.Location WHERE Code = N'FALLBACK-TERMINAL' AND DeprecatedAt IS NULL);
    END

    -- 2b. Seed-missing guard: the FALLBACK-TERMINAL seed (sql/seeds/011) has NOT
    --     been applied (seeds run AFTER migrations, so on a fresh migrate-only
    --     DB the fallback Location does not yet exist). Rather than let the final
    --     WHERE t.Id = @TerminalLocationId silently match zero rows on a NULL
    --     predicate, return an EXPLICIT empty result set with the SAME column
    --     shape and RETURN. The Gateway session-init MUST treat an empty set as
    --     "terminal registry not provisioned" and route to an error screen.
    IF @TerminalLocationId IS NULL
    BEGIN
        SELECT
            CAST(NULL AS BIGINT)        AS TerminalLocationId,
            CAST(NULL AS NVARCHAR(50))  AS TerminalCode,
            CAST(NULL AS NVARCHAR(200)) AS TerminalName,
            CAST(NULL AS BIGINT)        AS ZoneLocationId,
            CAST(NULL AS NVARCHAR(50))  AS ZoneCode,
            CAST(NULL AS NVARCHAR(200)) AS ZoneName,
            CAST(NULL AS NVARCHAR(255)) AS DefaultScreen,
            CAST(1 AS BIT)              AS IsFallback
        WHERE 1 = 0;
        RETURN;
    END

    -- 3. Project the Terminal + parent ("Zone") + DefaultScreen.
    SELECT
        t.Id                                                AS TerminalLocationId,
        t.Code                                              AS TerminalCode,
        t.Name                                              AS TerminalName,
        p.Id                                                AS ZoneLocationId,
        p.Code                                              AS ZoneCode,
        p.Name                                              AS ZoneName,
        ds.AttributeValue                                   AS DefaultScreen,
        @IsFallback                                         AS IsFallback
    FROM Location.Location t
    LEFT JOIN Location.Location p
        ON p.Id = t.ParentLocationId
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
    WHERE t.Id = @TerminalLocationId;
END;
GO
