-- ============================================================
-- Repeatable:  R__Quality_ControlledRun_Get.sql
-- Author:      Blue Ridge Automation
-- Modified:    2026-10-12
-- Version:     1.1
-- Change Log:  2026-10-13 - 1.1 - Totals count members that left by signed RELEASE,
--                                 and a released member is cleared for good.
-- Description: READ. One super-lot header with resolved names, totals and the
--              selection criteria as a sentence (CriteriaText -- built here so
--              no view or script assembles prose).
--
--              Totals count the members that are in the run now, or that left
--              it BECAUSE IT CLOSED or by a SIGNED RELEASE (so a super-lot still
--              reports what it held). Members removed by hand, or ended by a cancel, are not
--              counted. ClearedCount = members no longer CRT-tagged
--              (Quality.ufn_ControlledRunMemberState).
--
--              All timestamps are returned Eastern. No status row, no OUTPUT
--              params (FDS-11-011). Empty set = not found.
-- ============================================================
CREATE OR ALTER PROCEDURE Quality.ControlledRun_Get
    @Id BIGINT
AS
BEGIN
    SET NOCOUNT ON;

    SELECT
        r.Id,
        r.RunNumber,
        sc.Code AS StatusCode,
        r.Reason,
        r.AnchorLotId,
        al.LotName AS AnchorLotName,
        r.SelectionItemId,
        i.PartNumber,
        r.SelectionLocationId,
        lo.Name AS LocationName,
        CAST(r.SelectionFromAt AT TIME ZONE 'UTC' AT TIME ZONE 'Eastern Standard Time' AS DATETIME2(3)) AS SelectionFromAt,
        CAST(r.SelectionToAt   AT TIME ZONE 'UTC' AT TIME ZONE 'Eastern Standard Time' AS DATETIME2(3)) AS SelectionToAt,
        r.IncludeDescendants,
        r.AutoJoinEnabled,
        CAST(r.AutoJoinEndedAt AT TIME ZONE 'UTC' AT TIME ZONE 'Eastern Standard Time' AS DATETIME2(3)) AS AutoJoinEndedAt,
        ou.Initials AS OpenedByInitials,
        CAST(r.OpenedAt AT TIME ZONE 'UTC' AT TIME ZONE 'Eastern Standard Time' AS DATETIME2(3)) AS OpenedAt,
        cu.Initials AS ClosedByInitials,
        CAST(r.ClosedAt AT TIME ZONE 'UTC' AT TIME ZONE 'Eastern Standard Time' AS DATETIME2(3)) AS ClosedAt,
        r.CloseRemarks,
        ISNULL(tot.MemberCount, 0)  AS MemberCount,
        ISNULL(tot.ClearedCount, 0) AS ClearedCount,
        ISNULL(tot.PieceCount, 0)   AS PieceCount,
        CAST(LTRIM(
            ISNULL(i.PartNumber, N'')
          + CASE WHEN lo.Name IS NOT NULL THEN N' made on ' + lo.Name ELSE N'' END
          + CASE WHEN r.SelectionFromAt IS NOT NULL
                 THEN N' since ' + FORMAT(CAST(r.SelectionFromAt AT TIME ZONE 'UTC' AT TIME ZONE 'Eastern Standard Time' AS DATETIME2(0)), 'ddd MM/dd HH:mm')
                 ELSE N'' END
          + CASE WHEN r.IncludeDescendants = 1 AND al.LotName IS NOT NULL
                 THEN CASE WHEN i.PartNumber IS NOT NULL THEN N', plus' ELSE N'' END + N' everything made from ' + al.LotName
                 ELSE N'' END
          + CASE WHEN i.PartNumber IS NULL AND NOT (r.IncludeDescendants = 1 AND al.LotName IS NOT NULL)
                 THEN N'Hand-picked' ELSE N'' END
        ) AS NVARCHAR(400)) AS CriteriaText
    FROM Quality.ControlledRun r
    INNER JOIN Quality.ControlledRunStatusCode sc ON sc.Id = r.ControlledRunStatusId
    LEFT JOIN Lots.Lot al          ON al.Id = r.AnchorLotId
    LEFT JOIN Parts.Item i         ON i.Id  = r.SelectionItemId
    LEFT JOIN Location.Location lo ON lo.Id = r.SelectionLocationId
    LEFT JOIN Location.AppUser ou  ON ou.Id = r.OpenedByUserId
    LEFT JOIN Location.AppUser cu  ON cu.Id = r.ClosedByUserId
    OUTER APPLY (
        SELECT COUNT(*) AS MemberCount,
               -- A RELEASED member counts as cleared for good: if the unit is tagged
               -- again later for another reason, this super-lot's count must not drop.
               SUM(CASE WHEN ms.CrtActive = 0 OR ms.ControlledRunMemberEndReasonId IN (4 /* Released */, 5 /* ContainerVoided */)
                        THEN 1 ELSE 0 END) AS ClearedCount,
               SUM(ms.PieceCount) AS PieceCount
        FROM Quality.ufn_ControlledRunMemberState(r.Id) ms
        WHERE ms.EndedAt IS NULL OR ms.ControlledRunMemberEndReasonId IN (2 /* RunClosed */, 4 /* Released */, 5 /* ContainerVoided */)
    ) tot
    WHERE r.Id = @Id;
END;
GO
