-- ============================================================
-- Repeatable:  R__Quality_QualityResult_ListBySample.sql
-- Author:      Blue Ridge Automation
-- Modified:    2026-07-10
-- Version:     1.0
-- Description: Arc 2 Phase 9. Per-attribute results for one inspection sample,
--              joined to the spec attribute definition (name, data type, UOM,
--              target + limits, required flag) so the view can render the
--              expandable result rows without a second lookup. Ordered by the
--              attribute SortOrder.
--
--              READ proc: no status row, no OUTPUT params (FDS-11-011).
--              Empty result set = sample not found / no results.
-- ============================================================

CREATE OR ALTER PROCEDURE Quality.QualityResult_ListBySample
    @QualitySampleId BIGINT
AS
BEGIN
    SET NOCOUNT ON;

    SELECT
        qr.Id,
        qr.QualitySampleId,
        qr.QualitySpecAttributeId,
        a.AttributeName,
        a.DataType,
        a.Uom,
        a.TargetValue,
        a.LowerLimit,
        a.UpperLimit,
        a.IsRequired,
        a.SortOrder,
        qr.MeasuredValue,
        qr.NumericValue,
        qr.IsPass
    FROM Quality.QualityResult qr
    INNER JOIN Quality.QualitySpecAttribute a ON a.Id = qr.QualitySpecAttributeId
    WHERE qr.QualitySampleId = @QualitySampleId
    ORDER BY a.SortOrder, a.Id;
END;
GO
