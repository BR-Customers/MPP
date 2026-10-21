-- ============================================================
-- Repeatable:  R__Quality_ControlledRun_List.sql
-- Author:      Blue Ridge Automation
-- Modified:    2026-10-12
-- Version:     1.2
-- Change Log:  2026-10-19 - 1.2 - Open runs: Id ASC tie-breaker (two runs opened in the same millisecond listed newest first).
--              2026-10-13 - 1.1 - Totals follow ControlledRun_Get v1.1 (released members).
-- Description: READ. Super-lots for the Quality view's left-hand list.
--
--              @StatusCode 'Open' (default) | 'Closed' | 'Cancelled'; NULL or
--              'All' = every status. @Text matches the run number, the reason
--              or the part number.
--
--              Order: open super-lots OLDEST first (the one that has waited
--              longest is at the top), then everything else newest first.
--              MemberCount / ClearedCount follow the same rule as
--              Quality.ControlledRun_Get. WindowOpen = open AND still adding
--              new production. Timestamps Eastern. Capped at 500 rows.
--
--              No status row, no OUTPUT params (FDS-11-011).
-- ============================================================
CREATE OR ALTER PROCEDURE Quality.ControlledRun_List
    @StatusCode NVARCHAR(20)  = N'Open',
    @Text       NVARCHAR(100) = NULL
AS
BEGIN
    SET NOCOUNT ON;

    SET @Text = NULLIF(LTRIM(RTRIM(@Text)), N'');
    IF @StatusCode = N'All' SET @StatusCode = NULL;

    SELECT TOP 500
        r.Id,
        r.RunNumber,
        sc.Code AS StatusCode,
        r.Reason,
        i.PartNumber,
        lo.Name AS LocationName,
        CAST(r.OpenedAt AT TIME ZONE 'UTC' AT TIME ZONE 'Eastern Standard Time' AS DATETIME2(3)) AS OpenedAt,
        CAST(r.ClosedAt AT TIME ZONE 'UTC' AT TIME ZONE 'Eastern Standard Time' AS DATETIME2(3)) AS ClosedAt,
        ISNULL(tot.MemberCount, 0)  AS MemberCount,
        ISNULL(tot.ClearedCount, 0) AS ClearedCount,
        CONVERT(BIT, CASE WHEN r.ControlledRunStatusId = 1 AND r.AutoJoinEnabled = 1 THEN 1 ELSE 0 END) AS WindowOpen
    FROM Quality.ControlledRun r
    INNER JOIN Quality.ControlledRunStatusCode sc ON sc.Id = r.ControlledRunStatusId
    LEFT JOIN Parts.Item i         ON i.Id  = r.SelectionItemId
    LEFT JOIN Location.Location lo ON lo.Id = r.SelectionLocationId
    OUTER APPLY (
        SELECT COUNT(*) AS MemberCount,
               -- A RELEASED member counts as cleared for good: if the unit is tagged
               -- again later for another reason, this super-lot's count must not drop.
               SUM(CASE WHEN ms.CrtActive = 0 OR ms.ControlledRunMemberEndReasonId IN (4 /* Released */, 5 /* ContainerVoided */)
                        THEN 1 ELSE 0 END) AS ClearedCount
        FROM Quality.ufn_ControlledRunMemberState(r.Id) ms
        WHERE ms.EndedAt IS NULL OR ms.ControlledRunMemberEndReasonId IN (2 /* RunClosed */, 4 /* Released */, 5 /* ContainerVoided */)
    ) tot
    WHERE (@StatusCode IS NULL OR sc.Code = @StatusCode)
      AND (@Text IS NULL
           OR r.RunNumber LIKE N'%' + @Text + N'%'
           OR r.Reason    LIKE N'%' + @Text + N'%'
           OR i.PartNumber LIKE N'%' + @Text + N'%')
    ORDER BY CASE WHEN r.ControlledRunStatusId = 1 THEN 0 ELSE 1 END,
             CASE WHEN r.ControlledRunStatusId = 1 THEN r.OpenedAt END ASC,
             CASE WHEN r.ControlledRunStatusId = 1 THEN r.Id END ASC,
             r.OpenedAt DESC,
             r.Id DESC;
END;
GO
