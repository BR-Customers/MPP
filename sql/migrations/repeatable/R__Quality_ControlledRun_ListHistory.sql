-- ============================================================
-- Repeatable:  R__Quality_ControlledRun_ListHistory.sql
-- Author:      Blue Ridge Automation
-- Modified:    2026-10-21
-- Version:     1.0
-- Description: READ. Super-lot piece 6 (spec 3.6) -- the super-lot page's History
--              tab: the run's audit trail merged with its signatures, NEWEST FIRST.
--
--              1. Audit.OperationLog rows with entity 'ControlledRun' and EntityId =
--                 @Id. Kind comes from the event code (here, never in a view):
--                   ControlledRunOpened                         -> Opened
--                   ControlledRunMemberAdded / MemberRemoved    -> Member
--                   ControlledRunWindowChanged                  -> Window
--                   ControlledRunLabelPrinted                   -> Label
--                   ControlledRunResultRecorded / ResultVoided  -> Result
--                   ControlledRunDeviationRaised                -> Deviation
--                   ControlledRunReleased                       -> Released
--                   ControlledRunClosed                         -> Closed
--                   ControlledRunCancelled                      -> Cancelled
--                   anything added later                        -> Event
--                 Detail is the row's Description without its leading
--                 '<RunNumber> . ' subject (the page already names the run).
--              2. Quality.Signature rows behind this run's releases
--                 (ControlledRunRelease.SignatureId) and deviations
--                 (ControlledRunDeviation.SignatureId), Kind 'Signature', Detail
--                 '<SignatureMeaning.Name> . "<Statement>"'.
--              Refused attempts are in Audit.FailureLog, not here.
--
--              Result: EventAt (Eastern), Kind, Detail, ByInitials.
--              No status row, no OUTPUT params (FDS-11-011). Empty set = no history
--              (or unknown run).
-- ============================================================
CREATE OR ALTER PROCEDURE Quality.ControlledRun_ListHistory
    @Id BIGINT
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @RunNumber NVARCHAR(15) = (SELECT RunNumber FROM Quality.ControlledRun WHERE Id = @Id);
    DECLARE @Prefix NVARCHAR(30) = @RunNumber + N' ' + Audit.ufn_MidDot() + N' ';
    DECLARE @EntityTypeId BIGINT = (SELECT Id FROM Audit.LogEntityType WHERE Code = N'ControlledRun');

    SELECT h.EventAt, h.Kind, h.Detail, h.ByInitials
    FROM (
        SELECT
            CAST(ol.LoggedAt AT TIME ZONE 'UTC' AT TIME ZONE 'Eastern Standard Time' AS DATETIME2(3)) AS EventAt,
            CAST(CASE ev.Code
                WHEN N'ControlledRunOpened'          THEN N'Opened'
                WHEN N'ControlledRunMemberAdded'     THEN N'Member'
                WHEN N'ControlledRunMemberRemoved'   THEN N'Member'
                WHEN N'ControlledRunWindowChanged'   THEN N'Window'
                WHEN N'ControlledRunLabelPrinted'    THEN N'Label'
                WHEN N'ControlledRunResultRecorded'  THEN N'Result'
                WHEN N'ControlledRunResultVoided'    THEN N'Result'
                WHEN N'ControlledRunDeviationRaised' THEN N'Deviation'
                WHEN N'ControlledRunReleased'        THEN N'Released'
                WHEN N'ControlledRunClosed'          THEN N'Closed'
                WHEN N'ControlledRunCancelled'       THEN N'Cancelled'
                ELSE N'Event'
            END AS NVARCHAR(20)) AS Kind,
            CAST(CASE WHEN LEFT(ol.Description, LEN(@Prefix + N'x') - 1) = @Prefix
                      THEN SUBSTRING(ol.Description, LEN(@Prefix + N'x'), 1000)
                      ELSE ol.Description END AS NVARCHAR(1000)) AS Detail,
            u.Initials AS ByInitials,
            ol.LoggedAt AS SortAt,
            0 AS SortGroup,
            ol.Id AS SortId
        FROM Audit.OperationLog ol
        INNER JOIN Audit.LogEventType ev ON ev.Id = ol.LogEventTypeId
        LEFT JOIN Location.AppUser u     ON u.Id  = ol.UserId
        WHERE ol.LogEntityTypeId = @EntityTypeId AND ol.EntityId = @Id

        UNION ALL

        SELECT
            CAST(sg.SignedAt AT TIME ZONE 'UTC' AT TIME ZONE 'Eastern Standard Time' AS DATETIME2(3)),
            CAST(N'Signature' AS NVARCHAR(20)),
            CAST(sm.Name + N' ' + Audit.ufn_MidDot() + N' "' + sg.Statement + N'"' AS NVARCHAR(1000)),
            u.Initials,
            sg.SignedAt,
            1,
            sg.Id
        FROM (
            SELECT rl.SignatureId FROM Quality.ControlledRunRelease rl WHERE rl.ControlledRunId = @Id
            UNION
            SELECT d.SignatureId FROM Quality.ControlledRunDeviation d WHERE d.ControlledRunId = @Id
        ) s
        INNER JOIN Quality.Signature sg         ON sg.Id = s.SignatureId
        INNER JOIN Quality.SignatureMeaning sm  ON sm.Id = sg.SignatureMeaningId
        LEFT JOIN Location.AppUser u            ON u.Id  = sg.AppUserId
    ) h
    ORDER BY h.SortAt DESC, h.SortGroup ASC, h.SortId DESC;
END;
GO
