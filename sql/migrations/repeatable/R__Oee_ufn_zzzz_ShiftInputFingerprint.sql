-- =============================================
-- Repeatable:  R__Oee_ufn_zzzz_ShiftInputFingerprint.sql
-- Object:      Oee.ufn_ShiftInputFingerprint
-- Author:      Blue Ridge Automation
-- Created:     2026-10-30
-- Version:     1.0
--
-- Description:
--   A cheap fingerprint of everything one shift's stored OEE figures are
--   computed from (OEE dashboard spec
--   docs/superpowers/specs/2026-10-27-oee-dashboard-design.md v0.3.1 sec 6.8,
--   D22). Oee.ShiftSummary_ComputeCore stores it with the rows; the refresher
--   recomputes a shift whose fingerprint no longer matches. That is how a late
--   edit through ANY writer -- including one written next year -- reaches the
--   summary without the writer knowing the summary exists.
--
--   SHA2-256 over, for the shift:
--     the Oee.Shift row (ActualStart, ActualEnd);
--     Oee.DowntimeEvent with ShiftId = the shift (every column the calculation
--       reads, VoidedAt included);
--     Workorder.RejectEvent with ShiftId = the shift, plus ShiftId NULL rows
--       recorded within -12 h / +36 h of the shift start (the window
--       Oee.ufn_ShiftScrap searches for its RecordedAt fallback);
--     Workorder.DieCastContribution with ShiftId = the shift;
--     trim checkpoints (TrimIn / TrimOut ProductionEvent) of every LOT with a
--       checkpoint in the shift -- a checkpoint's credit depends on the LOT's
--       previous one, which may sit in another shift;
--     Lots.Lot stamped with the shift (the mint stamp, D18 / D21);
--     Oee.ShiftOverride rows for the shift's schedule and business date;
--     Tools.ToolAssignment rows overlapping the shift.
--   Each part contributes COUNT, the quantity sums and CHECKSUM_AGG(CHECKSUM(..))
--   of its columns. Configuration (reason codes, defect codes, locations,
--   schedules) is NOT here: Oee.ufn_ShiftSummaryConfigFingerprint covers it.
--
--   Inline TVF: one row, (Fingerprint VARBINARY(32)). Unknown shift -> one row
--   with a NULL fingerprint.
--
--   FILE NAME IS ORDER-SENSITIVE only by convention ('zzzz_' groups it with
--   ufn_ShiftSummaryRows); it calls no other function.
--
-- Change Log:
--   2026-10-30 - 1.0 - Initial version.
-- =============================================
CREATE OR ALTER FUNCTION Oee.ufn_ShiftInputFingerprint (@ShiftId BIGINT)
RETURNS TABLE
AS
RETURN
(
    WITH Sh AS (
        SELECT s.Id, s.ShiftScheduleId, s.ActualStart, s.ActualEnd,
               CAST(s.ActualStart AS DATE) AS BusinessDate,
               CAST(s.ActualStart AT TIME ZONE 'Eastern Standard Time' AT TIME ZONE 'UTC' AS DATETIME2(3)) AS StartUtc
        FROM Oee.Shift s
        WHERE s.Id = @ShiftId
    ),
    Dt AS (
        SELECT COUNT(*) AS N,
               SUM(CAST(ISNULL(de.DurationMinutes, 0) AS BIGINT)) AS Q,
               CHECKSUM_AGG(CHECKSUM(de.Id, de.LocationId, de.DowntimeReasonCodeId, de.StartedAt, de.EndedAt,
                                     de.IsApproximate, de.DurationMinutes, de.VoidedAt)) AS C
        FROM Oee.DowntimeEvent de
        WHERE de.ShiftId = @ShiftId
    ),
    Rj AS (
        SELECT COUNT(*) AS N, SUM(CAST(re.Quantity AS BIGINT)) AS Q,
               CHECKSUM_AGG(CHECKSUM(re.Id, re.Quantity, re.DefectCodeId, re.CellLocationId, re.ShiftId,
                                     re.LotId, re.ItemId, re.RecordedAt)) AS C
        FROM Sh
        INNER JOIN Workorder.RejectEvent re
                ON re.ShiftId = @ShiftId
                OR (re.ShiftId IS NULL
                    AND re.RecordedAt >= DATEADD(HOUR, -12, Sh.StartUtc)
                    AND re.RecordedAt <  DATEADD(HOUR,  36, Sh.StartUtc))
    ),
    Dc AS (
        SELECT COUNT(*) AS N, SUM(CAST(dcc.PieceDelta AS BIGINT)) AS Q,
               CHECKSUM_AGG(CHECKSUM(dcc.Id, dcc.PieceDelta, dcc.CellLocationId, dcc.LotId, dcc.ToolCavityId, dcc.EventAt)) AS C
        FROM Workorder.DieCastContribution dcc
        WHERE dcc.ShiftId = @ShiftId
    ),
    Tr AS (
        SELECT COUNT(*) AS N, SUM(CAST(ISNULL(pe.ShotCount, 0) AS BIGINT)) AS Q,
               CHECKSUM_AGG(CHECKSUM(pe.Id, pe.LotId, pe.ShiftId, pe.ShotCount, pe.EventAt, pe.TerminalLocationId)) AS C
        FROM Workorder.ProductionEvent pe
        INNER JOIN Parts.OperationTemplate ot ON ot.Id  = pe.OperationTemplateId
        INNER JOIN Parts.OperationType     oty ON oty.Id = ot.OperationTypeId
        WHERE oty.Code IN (N'TrimIn', N'TrimOut')
          AND pe.LotId IN (SELECT p2.LotId FROM Workorder.ProductionEvent p2 WHERE p2.ShiftId = @ShiftId)
    ),
    Lt AS (
        SELECT COUNT(*) AS N, SUM(CAST(ISNULL(l.MintedPieceCount, 0) AS BIGINT)) AS Q,
               CHECKSUM_AGG(CHECKSUM(l.Id, l.MintedPieceCount, l.ItemId, l.CreatedAtTerminalId, l.LotOriginTypeId)) AS C
        FROM Lots.Lot l
        WHERE l.ShiftId = @ShiftId
    ),
    Ov AS (
        SELECT COUNT(*) AS N,
               CHECKSUM_AGG(CHECKSUM(o.Id, o.LocationId, o.StartTime, o.EndTime, o.DeprecatedAt)) AS C
        FROM Sh
        INNER JOIN Oee.ShiftOverride o ON o.ShiftScheduleId = Sh.ShiftScheduleId AND o.BusinessDate = Sh.BusinessDate
    ),
    Ta AS (
        SELECT COUNT(*) AS N,
               CHECKSUM_AGG(CHECKSUM(a.Id, a.ToolId, a.CellLocationId, a.AssignedAt, a.ReleasedAt)) AS C
        FROM Sh
        INNER JOIN Tools.ToolAssignment a
                ON a.AssignedAt < DATEADD(HOUR, 36, Sh.StartUtc)
               AND (a.ReleasedAt IS NULL OR a.ReleasedAt > DATEADD(HOUR, -12, Sh.StartUtc))
    )
    SELECT HASHBYTES('SHA2_256', CONCAT(
               N'S', CONVERT(NVARCHAR(30), sh.ActualStart, 126), N'|', ISNULL(CONVERT(NVARCHAR(30), sh.ActualEnd, 126), N'-'),
               N'|D', dt.N, N':', ISNULL(dt.Q, 0), N':', ISNULL(dt.C, 0),
               N'|R', rj.N, N':', ISNULL(rj.Q, 0), N':', ISNULL(rj.C, 0),
               N'|C', dc.N, N':', ISNULL(dc.Q, 0), N':', ISNULL(dc.C, 0),
               N'|T', tr.N, N':', ISNULL(tr.Q, 0), N':', ISNULL(tr.C, 0),
               N'|L', lt.N, N':', ISNULL(lt.Q, 0), N':', ISNULL(lt.C, 0),
               N'|O', ov.N, N':', ISNULL(ov.C, 0),
               N'|A', ta.N, N':', ISNULL(ta.C, 0))) AS Fingerprint
    FROM (SELECT 1 AS One) one
    LEFT JOIN Sh sh ON 1 = 1
    CROSS JOIN Dt dt CROSS JOIN Rj rj CROSS JOIN Dc dc CROSS JOIN Tr tr
    CROSS JOIN Lt lt CROSS JOIN Ov ov CROSS JOIN Ta ta
    WHERE sh.Id IS NOT NULL
    UNION ALL
    SELECT CAST(NULL AS VARBINARY(32))
    WHERE NOT EXISTS (SELECT 1 FROM Sh)
);
GO
