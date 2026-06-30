-- ============================================================
-- Repeatable:  R__Parts_ItemLocation_CheckEligibility.sql
-- Author:      Blue Ridge Automation
-- Modified:    2026-06-16
-- Version:     1.0
-- Description: Arc 2 Phase 4 (spec sec 4.1). Advisory eligibility read over
--              Parts.v_EffectiveItemLocation (Direct U BomDerived, FDS-02-012).
--              Returns one row: IsEligible BIT, Path NVARCHAR(20)
--              ('Direct'/'BomDerived'/NULL). Direct preferred over BomDerived.
--              Read proc: no status row, no OUTPUT params. @LocationId is generic
--              (Cell OR Area resolution -- Trim IN resolves at the Trim Shop Area).
--              The authoritative gate is Lots.Lot_MoveToValidated; this only drives
--              UI pre-commit feedback. (v_EffectiveItemLocation exposes 'Source';
--              aliased here to 'Path' per the spec's contract.)
-- ============================================================
CREATE OR ALTER PROCEDURE Parts.ItemLocation_CheckEligibility
    @ItemId     BIGINT,
    @LocationId BIGINT
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Path NVARCHAR(20) = (
        SELECT TOP 1 v.Source
        FROM Parts.v_EffectiveItemLocation v
        WHERE v.ItemId = @ItemId AND v.LocationId = @LocationId
        ORDER BY CASE WHEN v.Source = N'Direct' THEN 0 ELSE 1 END);

    SELECT CASE WHEN @Path IS NULL THEN CAST(0 AS BIT) ELSE CAST(1 AS BIT) END AS IsEligible,
           @Path AS Path;
END;
GO
