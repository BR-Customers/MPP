-- ============================================================
-- Repeatable:  R__Parts_Item_GetAimCustomerPartNumber.sql
-- Author:      Blue Ridge Automation
-- Version:     1.0
-- Description: Reads Parts.Item.AimCustomerPartNumber - the Customer Part that
--              AIM's postserial.csv matches on. NOT derivable from Item.PartNumber
--              (AIM X-Ref: 11300R70 A000 -> 11300R7- A000), so it is stored per
--              item and sourced from AIM. Separate accessor rather than extending
--              Item_Get, mirroring Item_GetPlcId - keeps Item_Get's result shape
--              stable so no fixed-shape INSERT-EXEC capture breaks.
--
--              Read proc: empty rowset = item not found or deprecated (mirrors
--              Item_GetPlcId's DeprecatedAt IS NULL gate). Unlike GetPlcId this
--              does NOT also filter on AimCustomerPartNumber IS NOT NULL - a NULL
--              value is a legitimate "doesn't ship to Honda" state that the
--              caller (the Item Master field) must be able to distinguish from
--              "item not found". GetPlcId's value-IS-NOT-NULL gate is specific to
--              its own runtime-consumer semantics (an unconfigured PlcId is as
--              useless to the watcher as a missing one), not a general read-proc
--              convention - compare Location.Terminal_GetPrinter, which LEFT
--              JOINs and returns a row even when its attribute values are unset.
-- ============================================================
CREATE OR ALTER PROCEDURE Parts.Item_GetAimCustomerPartNumber
    @ItemId BIGINT
AS
BEGIN
    SET NOCOUNT ON;

    SELECT
        i.Id                    AS ItemId,
        i.AimCustomerPartNumber AS AimCustomerPartNumber
    FROM Parts.Item i
    WHERE i.Id = @ItemId
      AND i.DeprecatedAt IS NULL;
END;
GO
