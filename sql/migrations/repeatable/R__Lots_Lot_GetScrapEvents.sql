-- ============================================================
-- Repeatable:  R__Lots_Lot_GetScrapEvents.sql
-- Author:      Blue Ridge Automation
-- Modified:    2026-08-19
-- Version:     1.0
-- Description: Backlog 5.2. Per-event scrap list for the LOT Detail "Scrap" tab --
--              the detail behind Lots.Lot_GetScrapSummary's RejectedTotal.
--
--              One row per Workorder.RejectEvent against @LotId, newest first,
--              with the defect code resolved, the area the scrap was charged to
--              (RejectEvent.ChargeToArea -- the LOT's location at the time the
--              scrap was recorded), the free-text remark and the acting user.
--
--              RecordedAt is converted UTC -> Eastern at the boundary and CAST
--              back to DATETIME2(3). The CAST is mandatory: a raw datetimeoffset
--              breaks the Ignition JDBC result read mid-materialize, so the bound
--              property silently comes back empty.
--
--              READ proc: single result set, no status row, no OUTPUT params
--              (FDS-11-011). Empty set = no scrap recorded (no invented 404).
-- ============================================================
CREATE OR ALTER PROCEDURE Lots.Lot_GetScrapEvents
    @LotId    BIGINT,
    @TopN     INT = 100
AS
BEGIN
    SET NOCOUNT ON;

    IF @TopN IS NULL OR @TopN <= 0 SET @TopN = 100;

    SELECT TOP (@TopN)
        re.Id                                     AS RejectEventId,
        CAST(re.RecordedAt AT TIME ZONE 'UTC'
                           AT TIME ZONE 'Eastern Standard Time' AS DATETIME2(3))
                                                  AS RecordedAt,
        re.Quantity                               AS Quantity,
        dc.Id                                     AS DefectCodeId,
        dc.Code                                   AS DefectCode,
        ISNULL(dc.Description, N'')               AS DefectDescription,
        ISNULL(oc.Name, N'Plant-wide')            AS DefectCategoryName,
        ISNULL(re.ChargeToArea, N'')              AS ChargeToArea,
        ISNULL(re.Remarks, N'')                   AS Remarks,
        re.AppUserId                              AS ByUserId,
        au.DisplayName                            AS ByUserName
    FROM Workorder.RejectEvent re
    INNER JOIN Quality.DefectCode dc      ON dc.Id = re.DefectCodeId
    LEFT  JOIN Parts.OperationCategory oc ON oc.Id = dc.OperationCategoryId
    INNER JOIN Location.AppUser au        ON au.Id = re.AppUserId
    WHERE re.LotId = @LotId
    ORDER BY re.RecordedAt DESC, re.Id DESC;
END;
GO
