-- ============================================================
-- Repeatable:  R__Quality_ControlledRun_ReportOutcomes.sql
-- Author:      Blue Ridge Automation
-- Modified:    2026-10-21
-- Version:     1.1
-- Change Log:  2026-10-21 - 1.0 - Super-lot piece 6: the report's outcome and defect totals.
--              2026-10-21 - 1.1 - Optional @Section ('Outcome' | 'Defect'); NULL = both, as
--                                 before. Lets the report bind each table to a bare EXEC
--                                 that keeps this proc's ORDER BY.
-- Description: READ. The super-lot report's "results by outcome" and "scrap by defect
--              code" blocks, one result set.
--
--              Section 'Outcome': one row per disposition that has pieces, Label =
--              Quality.DispositionCode.Name, Pieces = the sum of the run's LIVE
--              (VoidedAt IS NULL) result entries, over every member -- current and
--              ended, the same population as ControlledRun_ReportMembers. Use As-Is
--              is its own outcome (6c); the report does not say which entry falls
--              under which deviation. Totals equal the sum of ResultQty from
--              Quality.ufn_ControlledRunMemberResults (same non-voided rows).
--              Order: Accepted, Scrap, Rework, Return to Supplier, Use As-Is.
--
--              Section 'Defect': Scrap entries only, grouped by defect code, Label =
--              '<Code> - <Description>' ('No defect recorded' when the entry carries
--              none), most pieces first.
--
--              @Section NULL (default) returns both sections; 'Outcome' or 'Defect'
--              returns only that section, same order.
--
--              No status row, no OUTPUT params (FDS-11-011). Empty set = unknown run
--              or no live results.
--
-- Result set:  Section, Label, Pieces
-- ============================================================
CREATE OR ALTER PROCEDURE Quality.ControlledRun_ReportOutcomes
    @Id      BIGINT,
    @Section NVARCHAR(20) = NULL
AS
BEGIN
    SET NOCOUNT ON;

    SELECT u.Section, u.Label, u.Pieces
    FROM (
        SELECT N'Outcome' AS Section, 1 AS SecOrd,
               CASE dc.Code WHEN N'Accepted' THEN 1 WHEN N'Scrap' THEN 2 WHEN N'Rework' THEN 3
                            WHEN N'ReturnToSupplier' THEN 4 WHEN N'UseAsIs' THEN 5 ELSE 9 END AS Ord,
               CAST(dc.Name AS NVARCHAR(200)) AS Label,
               CAST(SUM(rr.Quantity) AS INT) AS Pieces
        FROM Quality.ControlledRunMember m
        INNER JOIN Quality.ControlledRunResult rr ON rr.ControlledRunMemberId = m.Id AND rr.VoidedAt IS NULL
        INNER JOIN Quality.DispositionCode dc     ON dc.Id = rr.DispositionCodeId
        WHERE m.ControlledRunId = @Id
        GROUP BY dc.Code, dc.Name
        UNION ALL
        SELECT N'Defect', 2, 0,
               CAST(ISNULL(df.Code + N' - ' + df.Description, N'No defect recorded') AS NVARCHAR(200)),
               CAST(SUM(rr.Quantity) AS INT)
        FROM Quality.ControlledRunMember m
        INNER JOIN Quality.ControlledRunResult rr ON rr.ControlledRunMemberId = m.Id AND rr.VoidedAt IS NULL
        INNER JOIN Quality.DispositionCode dc     ON dc.Id = rr.DispositionCodeId AND dc.Code = N'Scrap'
        LEFT JOIN Quality.DefectCode df           ON df.Id = rr.DefectCodeId
        WHERE m.ControlledRunId = @Id
        GROUP BY df.Code, df.Description
    ) u
    WHERE @Section IS NULL OR u.Section = @Section
    ORDER BY u.SecOrd, u.Ord, u.Pieces DESC, u.Label;
END;
GO