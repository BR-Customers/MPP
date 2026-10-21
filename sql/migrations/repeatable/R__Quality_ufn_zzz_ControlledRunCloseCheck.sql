-- ============================================================
-- Repeatable:  R__Quality_ufn_zzz_ControlledRunCloseCheck.sql
-- Object:      Quality.ufn_ControlledRunCloseCheck
-- Author:      Blue Ridge Automation
-- Modified:    2026-10-21
-- Version:     1.0
-- Description: Super-lot piece 6 (spec 3.7). May this super-lot be closed now,
--              and if not, why. ONE row (CanClose BIT, Reason NVARCHAR(200)) for a
--              run that exists, none for an unknown id. Reason is NULL exactly when
--              CanClose = 1.
--
--              The ONE definition of Close's rules 3-5, read by
--              Quality.ControlledRun_Close (which refuses with Reason, byte for byte)
--              and by Quality.ControlledRun_Get (CanClose / CloseBlockedReason for the
--              page's Close button). Checked in Close's order:
--                3. not open        -> 'Super-lot <RN> is not open.'
--                4. window open     -> 'End the window before closing.'
--                5. tagged members  -> '<n> of <m> members are still CRT-tagged.'
--                                      (current members; Quality.ufn_ControlledRunMemberState)
--
--              Close runs ControlledRun_SyncInternal before it reads this (a read
--              cannot), so a Get taken while new matching material is waiting to be
--              listed can say CanClose = 1 and the Close still refuse rule 5. With the
--              window ended and nothing pending the two always agree.
--
--              FILE NAME IS ORDER-SENSITIVE: 'zzz_' sorts after
--              R__Quality_ufn_zz_ControlledRunMemberState.sql, which it reads (a
--              function gets no deferred name resolution). Do not "tidy" it.
-- ============================================================
CREATE OR ALTER FUNCTION Quality.ufn_ControlledRunCloseCheck (@Id BIGINT)
RETURNS TABLE
AS
RETURN
(
    SELECT CONVERT(BIT, CASE WHEN x.Reason IS NULL THEN 1 ELSE 0 END) AS CanClose,
           x.Reason
    FROM Quality.ControlledRun r
    OUTER APPLY (
        SELECT COUNT(*) AS Total,
               ISNULL(SUM(CASE WHEN ms.CrtActive = 1 THEN 1 ELSE 0 END), 0) AS Outstanding
        FROM Quality.ufn_ControlledRunMemberState(r.Id) ms
        WHERE ms.EndedAt IS NULL
    ) t
    CROSS APPLY (
        SELECT CAST(CASE
            WHEN r.ControlledRunStatusId <> 1 THEN N'Super-lot ' + r.RunNumber + N' is not open.'
            WHEN r.AutoJoinEnabled = 1        THEN N'End the window before closing.'
            WHEN t.Outstanding > 0            THEN CAST(t.Outstanding AS NVARCHAR(10)) + N' of '
                                                 + CAST(t.Total AS NVARCHAR(10)) + N' members are still CRT-tagged.'
        END AS NVARCHAR(200)) AS Reason
    ) x
    WHERE r.Id = @Id
);
GO
