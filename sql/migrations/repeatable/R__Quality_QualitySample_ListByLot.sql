-- ============================================================
-- Repeatable:  R__Quality_QualitySample_ListByLot.sql
-- Author:      Blue Ridge Automation
-- Modified:    2026-07-10
-- Version:     1.0
-- Description: Arc 2 Phase 9. Inspection history for a LOT, newest first.
--              One row per Quality.QualitySample with the overall result code,
--              spec name + version, inspector display name, trigger, and the
--              per-attribute result counts (TotalResults / PassedResults).
--              SampledAt is ET-converted at the read boundary (UTC storage,
--              Eastern display).
--
--              READ proc: no status row, no OUTPUT params (FDS-11-011).
--              Empty result set = no samples for the LOT.
-- ============================================================

CREATE OR ALTER PROCEDURE Quality.QualitySample_ListByLot
    @LotId BIGINT
AS
BEGIN
    SET NOCOUNT ON;

    SELECT
        qs.Id,
        qs.LotId,
        qs.QualitySpecVersionId,
        s.Name                      AS SpecName,
        v.VersionNumber,
        qs.InspectionResultCodeId,
        ir.Code                     AS InspectionResultCode,
        ir.Name                     AS InspectionResultName,
        qs.SampleTriggerCodeId,
        st.Code                     AS SampleTriggerCode,
        qs.LocationId,
        loc.Name                    AS LocationName,
        qs.SampledByUserId,
        au.DisplayName              AS InspectorName,
        CAST(qs.SampledAt AT TIME ZONE 'UTC' AT TIME ZONE 'Eastern Standard Time' AS DATETIME2(3)) AS SampledAt,
        rc.TotalResults,
        rc.PassedResults
    FROM Quality.QualitySample qs
    INNER JOIN Quality.QualitySpecVersion   v   ON v.Id   = qs.QualitySpecVersionId
    INNER JOIN Quality.QualitySpec          s   ON s.Id   = v.QualitySpecId
    INNER JOIN Quality.InspectionResultCode ir  ON ir.Id  = qs.InspectionResultCodeId
    INNER JOIN Location.AppUser             au  ON au.Id  = qs.SampledByUserId
    LEFT  JOIN Quality.SampleTriggerCode    st  ON st.Id  = qs.SampleTriggerCodeId
    LEFT  JOIN Location.Location            loc ON loc.Id = qs.LocationId
    OUTER APPLY (
        SELECT COUNT(*)                                        AS TotalResults,
               SUM(CASE WHEN qr.IsPass = 1 THEN 1 ELSE 0 END)  AS PassedResults
        FROM Quality.QualityResult qr
        WHERE qr.QualitySampleId = qs.Id
    ) rc
    WHERE qs.LotId = @LotId
    ORDER BY qs.SampledAt DESC, qs.Id DESC;
END;
GO
