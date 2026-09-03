-- =============================================
-- Repeatable:  R__Quality_Hold_ListOpenForReport.sql
-- Author:      Blue Ridge Automation
-- Modified:    2026-08-25
-- Version:     1.0
-- Description: FDS-12-010 Hold Status -- every LOT and container currently on
--              hold, with hold type, reason, placed-by and DURATION ON HOLD.
--
--              SIBLING to Quality.Hold_ListOpen, which is FROZEN: that proc
--              backs the Hold Management screen and does not carry the duration
--              this requirement names. Widening it would repeat the Lot_Search
--              mistake (three consumers, one of them calling positionally), so
--              the report gets its own read instead.
--
--              Quality.HoldEvent carries CK_HoldEvent_LotXorContainer -- a row
--              is Lot-scoped OR Container-scoped, never both -- so the two
--              LEFT JOINs are mutually exclusive by construction and the
--              Subject columns collapse cleanly.
--
--              One result set (FDS-11-011); ordered oldest-first so the
--              longest-held item leads the page.
-- =============================================
CREATE OR ALTER PROCEDURE Quality.Hold_ListOpenForReport
    @HoldTypeCodeId BIGINT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    SELECT
        he.Id                     AS HoldEventId,
        CASE WHEN he.LotId IS NOT NULL THEN N'LOT' ELSE N'Container' END AS SubjectKind,
        CASE WHEN he.LotId IS NOT NULL THEN l.LotName
             ELSE CAST(he.ContainerId AS NVARCHAR(20)) END               AS SubjectName,
        COALESCE(li.PartNumber, ci.PartNumber)                           AS ItemPartNumber,
        l.PieceCount              AS LotPieceCount,
        loc.Name                  AS CurrentLocationName,
        htc.Code                  AS HoldTypeCode,
        htc.Name                  AS HoldTypeName,
        he.Reason,
        u.DisplayName             AS PlacedByName,
        CAST(he.PlacedAt AT TIME ZONE 'UTC' AT TIME ZONE 'Eastern Standard Time' AS DATETIME2(3)) AS PlacedAt,
        -- Duration is computed against UTC on BOTH sides -- converting either
        -- operand to Eastern first would skew the span across a DST boundary.
        DATEDIFF(HOUR, he.PlacedAt, SYSUTCDATETIME())                    AS HoursOnHold
    FROM Quality.HoldEvent he
    INNER JOIN Quality.HoldTypeCode htc ON htc.Id = he.HoldTypeCodeId
    LEFT  JOIN Lots.Lot        l   ON l.Id   = he.LotId
    LEFT  JOIN Parts.Item      li  ON li.Id  = l.ItemId
    LEFT  JOIN Lots.Container  c   ON c.Id   = he.ContainerId
    LEFT  JOIN Parts.Item      ci  ON ci.Id  = c.ItemId
    LEFT  JOIN Location.Location loc ON loc.Id = COALESCE(l.CurrentLocationId, c.CurrentLocationId)
    LEFT  JOIN Location.AppUser u  ON u.Id   = he.PlacedByUserId
    WHERE he.ReleasedAt IS NULL
      AND (@HoldTypeCodeId IS NULL OR he.HoldTypeCodeId = @HoldTypeCodeId)
    ORDER BY he.PlacedAt ASC, he.Id ASC;
END
GO
