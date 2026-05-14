-- =============================================
-- Procedure:   Location.LocationAttribute_GetByLocation
-- Author:      Blue Ridge Automation
-- Created:     2026-04-13
-- Version:     3.0
--
-- Description:
--   Returns the attribute schema for a Location -- one row per active
--   LocationAttributeDefinition (for that Location's LocationTypeDefinition),
--   LEFT JOINed to any persisted LocationAttribute value. Definitions that
--   have no saved value still appear in the result; their AttributeValue,
--   Id, CreatedAt, UpdatedAt, UpdatedByUserId columns are NULL so the form
--   can distinguish "never entered" from "entered as empty string" and can
--   surface lad.DefaultValue as a placeholder.
--
--   Ordered by LocationAttributeDefinition.SortOrder ASC.
--   Read-only proc -- empty result means Location not found OR its
--   LocationTypeDefinition has no active attribute definitions.
--
-- Parameters:
--   @LocationId BIGINT - FK to Location. Required.
--
-- Result set (one row per active LocationAttributeDefinition):
--   Id                              -- LocationAttribute.Id, NULL when no value persisted
--   LocationId                      -- @LocationId (literal, always set)
--   LocationAttributeDefinitionId   -- LocationAttributeDefinition.Id (always set)
--   AttributeValue                  -- LocationAttribute.AttributeValue, NULL when no value persisted
--   CreatedAt, UpdatedAt, UpdatedByUserId  -- NULL when no value persisted
--   AttributeName, DataType, IsRequired, DefaultValue, Uom, SortOrder, Description
--                                   -- always set, from the definition
--
-- Dependencies:
--   Tables: Location.Location, Location.LocationAttribute, Location.LocationAttributeDefinition
--
-- Change Log:
--   2026-04-13 - 1.0 - Initial version (OUTPUT params)
--   2026-04-14 - 2.0 - Removed OUTPUT params for Named Query compatibility
--   2026-05-12 - 3.0 - Drive off LocationAttributeDefinition (LEFT JOIN values)
--                      so all defined attributes return even when no value
--                      has been saved yet -- form can then prompt for input.
-- =============================================
CREATE OR ALTER PROCEDURE Location.LocationAttribute_GetByLocation
    @LocationId BIGINT
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @LocationTypeDefinitionId BIGINT;

    SELECT @LocationTypeDefinitionId = l.LocationTypeDefinitionId
    FROM Location.Location l
    WHERE l.Id = @LocationId;

    IF @LocationTypeDefinitionId IS NULL
        RETURN;

    SELECT
        la.Id,
        @LocationId                     AS LocationId,
        lad.Id                          AS LocationAttributeDefinitionId,
        la.AttributeValue,
        la.CreatedAt,
        la.UpdatedAt,
        la.UpdatedByUserId,
        lad.AttributeName,
        lad.DataType,
        lad.IsRequired,
        lad.DefaultValue,
        lad.Uom,
        lad.SortOrder,
        lad.Description
    FROM Location.LocationAttributeDefinition lad
    LEFT JOIN Location.LocationAttribute la
        ON  la.LocationAttributeDefinitionId = lad.Id
        AND la.LocationId = @LocationId
    WHERE lad.LocationTypeDefinitionId = @LocationTypeDefinitionId
      AND lad.DeprecatedAt IS NULL
    ORDER BY lad.SortOrder ASC;
END;
GO
