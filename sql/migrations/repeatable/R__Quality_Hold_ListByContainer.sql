-- =============================================
-- Repeatable:  R__Quality_Hold_ListByContainer.sql
-- Author:      Blue Ridge Automation
-- Modified:    2026-08-25
-- Version:     1.0
-- Description: FDS-12-003 hold HISTORY for a container -- open AND released,
--              newest first. One result set (FDS-11-011).
--
--              DISTINCT from Quality.Hold_GetOpenByContainer, which filters
--              ReleasedAt IS NULL and therefore cannot show history. FDS-12-003
--              asks for "hold history"; the open-only read cannot serve it, so
--              this proc exists rather than the panel reusing that one.
--
--              Quality.HoldEvent carries CK_HoldEvent_LotXorContainer -- a row
--              is Lot-scoped OR Container-scoped, never both -- so filtering on
--              ContainerId is sufficient with no Lot-side exclusion.
-- =============================================
CREATE OR ALTER PROCEDURE Quality.Hold_ListByContainer
    @ContainerId BIGINT
AS
BEGIN
    SET NOCOUNT ON;

    SELECT
        he.Id AS HoldEventId,
        htc.Code AS HoldTypeCode,
        htc.Name AS HoldTypeName,
        he.Reason,
        placed.DisplayName AS PlacedByName,
        CAST(he.PlacedAt AT TIME ZONE 'UTC' AT TIME ZONE 'Eastern Standard Time' AS DATETIME2(3)) AS PlacedAt,
        rel.DisplayName AS ReleasedByName,
        CAST(he.ReleasedAt AT TIME ZONE 'UTC' AT TIME ZONE 'Eastern Standard Time' AS DATETIME2(3)) AS ReleasedAt,
        he.ReleaseRemarks,
        CASE WHEN he.ReleasedAt IS NULL THEN 1 ELSE 0 END AS IsOpen
    FROM Quality.HoldEvent he
    INNER JOIN Quality.HoldTypeCode htc    ON htc.Id    = he.HoldTypeCodeId
    INNER JOIN Location.AppUser     placed ON placed.Id = he.PlacedByUserId
    LEFT  JOIN Location.AppUser     rel    ON rel.Id    = he.ReleasedByUserId
    WHERE he.ContainerId = @ContainerId
    ORDER BY he.PlacedAt DESC, he.Id DESC;
END
GO
