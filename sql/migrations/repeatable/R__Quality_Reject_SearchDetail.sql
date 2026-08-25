-- =============================================
-- Repeatable:  R__Quality_Reject_SearchDetail.sql
-- Author:      Blue Ridge Automation
-- Modified:    2026-08-25
-- Version:     1.0
-- Description: FDS-12-006 Rejects -- Transaction Detail. Reproduces the legacy
--              PD "Search Reject" screen: one row per RejectEvent with the
--              defect, the responsible party and the quantity.
--
--              Charge-to comes from Quality.DefectCode.ChargeToPartyId, NOT
--              from Workorder.RejectEvent.ChargeToArea: in every row of the
--              legacy export the charge-to equals the defect code's home
--              department, and ChargeToArea is unconstrained free text that no
--              proc populates. The legacy column is left alone, unread.
--
--              Dates are Eastern calendar days, inclusive both ends, converted
--              to a half-open UTC range here so the filter agrees with the
--              Eastern-converted RecordedAt in the SELECT.
--
--              One result set (FDS-11-011).
-- =============================================
CREATE OR ALTER PROCEDURE Quality.Reject_SearchDetail
    @FromEt           DATE          = NULL,
    @ToEt             DATE          = NULL,
    @PartNumberLike   NVARCHAR(100) = NULL,
    @DefectCodeId     BIGINT        = NULL,
    @ChargeToPartyId  BIGINT        = NULL,
    @LimitRows        INT           = 1000
AS
BEGIN
    SET NOCOUNT ON;

    IF @LimitRows IS NULL OR @LimitRows < 1 SET @LimitRows = 1000;

    DECLARE @P NVARCHAR(120) = CASE
        WHEN @PartNumberLike IS NULL OR LTRIM(RTRIM(@PartNumberLike)) = N'' THEN NULL
        ELSE N'%' + LTRIM(RTRIM(@PartNumberLike)) + N'%' END;

    DECLARE @FromUtc DATETIME2(3) = NULL, @ToUtc DATETIME2(3) = NULL;
    IF @FromEt IS NOT NULL
        SET @FromUtc = CAST(CAST(@FromEt AS DATETIME2(3))
            AT TIME ZONE 'Eastern Standard Time' AT TIME ZONE 'UTC' AS DATETIME2(3));
    IF @ToEt IS NOT NULL
        SET @ToUtc = CAST(CAST(DATEADD(DAY, 1, @ToEt) AS DATETIME2(3))
            AT TIME ZONE 'Eastern Standard Time' AT TIME ZONE 'UTC' AS DATETIME2(3));

    SELECT TOP (@LimitRows)
        re.Id                AS RejectEventId,
        re.LotId,
        l.LotName,
        i.PartNumber         AS ItemPartNumber,
        CAST(re.RecordedAt AT TIME ZONE 'UTC' AT TIME ZONE 'Eastern Standard Time' AS DATETIME2(3)) AS RecordedAt,
        u.DisplayName        AS OperatorName,
        sh.ScheduleName      AS ShiftName,
        dc.Code              AS DefectCode,
        dc.Description       AS DefectDescription,
        cp.Name              AS ChargeToPartyName,
        re.Quantity,
        dc.IsNonRejectScrap,
        loc.Name             AS RecordedAtLocationName,
        COUNT(*) OVER()      AS TotalCount
    FROM Workorder.RejectEvent re
    INNER JOIN Lots.Lot          l  ON l.Id  = re.LotId
    INNER JOIN Parts.Item        i  ON i.Id  = l.ItemId
    INNER JOIN Quality.DefectCode dc ON dc.Id = re.DefectCodeId
    LEFT  JOIN Quality.ChargeToParty cp ON cp.Id = dc.ChargeToPartyId
    LEFT  JOIN Location.AppUser  u  ON u.Id  = re.AppUserId
    LEFT  JOIN Location.Location loc ON loc.Id = re.TerminalLocationId
    OUTER APPLY (
        -- Shift context is die-cast only: DieCastContribution is the sole
        -- table tying a LOT to an Oee.Shift instance. Trim / machining
        -- rejects report a NULL shift rather than a guessed one.
        SELECT TOP (1) ss.Name AS ScheduleName
        FROM Workorder.DieCastContribution dcc
        INNER JOIN Oee.Shift         sh2 ON sh2.Id = dcc.ShiftId
        INNER JOIN Oee.ShiftSchedule ss  ON ss.Id  = sh2.ShiftScheduleId
        WHERE dcc.LotId = re.LotId
        ORDER BY dcc.EventAt DESC, dcc.Id DESC
    ) sh
    WHERE (@FromUtc        IS NULL OR re.RecordedAt >= @FromUtc)
      AND (@ToUtc          IS NULL OR re.RecordedAt <  @ToUtc)
      AND (@P              IS NULL OR i.PartNumber LIKE @P)
      AND (@DefectCodeId   IS NULL OR re.DefectCodeId = @DefectCodeId)
      AND (@ChargeToPartyId IS NULL OR dc.ChargeToPartyId = @ChargeToPartyId)
    ORDER BY re.RecordedAt DESC, re.Id DESC;
END
GO
