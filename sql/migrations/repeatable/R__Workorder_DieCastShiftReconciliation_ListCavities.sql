-- ============================================================
-- Repeatable:  R__Workorder_DieCastShiftReconciliation_ListCavities.sql
-- Author:      Blue Ridge Automation
-- Created:     2026-09-28
-- Version:     1.0
-- Description: The cavities that were on this die DURING the shift, one row
--              each, with the part each was making. Two controls on the
--              reconciliation screen have nothing else to read from:
--
--                * the LTT entry bar's Cavity picker -- a team lead typing in a
--                  basket the shift made has to name the cavity that cast it;
--                * the reject block's Part dropdown -- "All", or one part.
--
--              Neither can come from Workorder.DieCastShiftReconciliation_
--              ListLots, which lists LOTs and is EMPTY in precisely the case the
--              entry bar exists for: a shift where nothing was recorded. And
--              neither can come from _GetHeader, which returns the cavity COUNT,
--              not the set.
--
--              THE WINDOW IS THE SAVE'S WINDOW, CHARACTER FOR CHARACTER:
--                  cs.Code = N'Active'
--                  AND (tc.DeprecatedAt IS NULL OR tc.DeprecatedAt > @StartUtc)
--              the predicate Workorder.DieCastShiftReconciliation_Save 1.8 sec 8
--              builds @ActiveCav from, and Workorder.DieCastShiftReconciliation_
--              GetHeader 1.2 counts. THERE IS NO CreatedAt LOWER BOUND and its
--              absence is deliberate (spec A16): 88 of prod's 149 cavities
--              across 17 dies were configured the day AFTER the shift they ran
--              in, so a CreatedAt bound refused those dies outright.
--              A third source resolved differently would offer a cavity the save
--              then refuses ("Choose a cavity that was on this die during ...")
--              or hide one it would have accepted -- the exact disagreement 1.8
--              and 1.2 settled. Three resolvers share one predicate. If it
--              moves, all three move in the same commit.
--
--              NOT A CAVITY FILTER FOR ANYTHING ELSE. _ListLots, _ListRejects,
--              _ListEntries, _ListMoveTargets and _ListShifts deliberately carry
--              NO cavity predicate and must keep none (see _ListLots 1.2): a
--              basket cast on a since-deprecated cavity is still a basket and
--              still belongs on the list the team lead reconciles from. This proc
--              answers "what may be CHOSEN"; those answer "what is SHOWN".
--
--              ORDER: part, then cavity letter. A cavity letter is unique per
--              (Tool, Item, CavityCode), not per tool -- a family die repeats its
--              letters once per part -- so the letter alone is ambiguous and the
--              part has to lead.
--
--              TWO PARAMETERS, NOT THREE. The press is deliberately not one: the
--              cavity set depends on the die and the shift window and on nothing
--              else, exactly as @ActiveCav does. A parameter the query ignores
--              would tell the next reader it matters.
--
--              THERE IS NO @EndUtc HERE, for the same reason
--              Workorder.DieCastShiftReconciliation_GetHeader 1.2 dropped its
--              own: the only thing that ever needed the end of the shift was the
--              `tc.CreatedAt < @EndUtc` bound, and that bound is gone. An OPEN
--              shift therefore needs no "now" substitution either -- nothing
--              here reads the end of the window at all. Do not reintroduce
--              either one.
--
--              ONE result set, no OUTPUT params (FDS-11-011). EMPTY means this die
--              had no active cavities in the window -- the same condition the save
--              refuses with "This die had no active cavities during <shift>", so
--              the screen shows that sentence rather than an empty picker with no
--              explanation. An UNKNOWN shift is empty too, and that is what the
--              `@StartUtc IS NOT NULL` term in the WHERE clause is for: with no
--              shift there is no window, and `tc.DeprecatedAt > NULL` is UNKNOWN
--              rather than false, so without the term every never-deprecated
--              cavity on the die would come back as though it had been resolved.
--              A missing shift is not-found, not "all of them".
--
--              KNOWN LIMITATION, INHERITED ON PURPOSE. Documented at length in
--              R__Workorder_DieCastShiftReconciliation_Save.sql and not solved
--              here: cs.Code = 'Active' is evaluated as of NOW, because
--              Tools.ToolCavityStatusCode has no history -- nothing records when
--              a cavity became Closed or Scrapped. Do not fix it here alone. The
--              value of this read is that it agrees with the save; a unilateral
--              fix would end that.
--
-- Parameters (input):
--   @ShiftId BIGINT - the shift whose cavity set is wanted.
--   @ToolId  BIGINT - the die.
--
-- Result set (one row per cavity, ordered part then letter):
--   ToolCavityId, CavityCode, ItemId, PartNumber, PartDescription,
--   CanMintLot BIT, DeprecatedAtEt, IsOffDieNow BIT
--
-- Change Log:
--   2026-09-28 - 1.0 - Initial version. The cavity picker's and the Part
--                      dropdown's backing read (Plan 2 scope sec 9 question 1).
-- ============================================================
CREATE OR ALTER PROCEDURE Workorder.DieCastShiftReconciliation_ListCavities
    @ShiftId BIGINT,
    @ToolId  BIGINT
AS
BEGIN
    SET NOCOUNT ON;

    -- Oee.Shift is Eastern wall clock (OI-38); Tools.ToolCavity's stamps are UTC.
    DECLARE @StartEt DATETIME2(3);
    SELECT @StartEt = s.ActualStart FROM Oee.Shift s WHERE s.Id = @ShiftId;
    DECLARE @StartUtc DATETIME2(3) = CAST(@StartEt AT TIME ZONE 'Eastern Standard Time' AT TIME ZONE 'UTC' AS DATETIME2(3));

    SELECT
        tc.Id                                                            AS ToolCavityId,
        tc.CavityCode,
        tc.ItemId,
        i.PartNumber,
        i.Description                                                    AS PartDescription,
        -- Workorder.DieCastShiftReconciliation_Save refuses a NEW LOT on a cavity
        -- with no part configured ("That cavity has no part configured..."), so the
        -- picker can grey it rather than let the team lead find out at save.
        CAST(CASE WHEN tc.ItemId IS NULL THEN 0 ELSE 1 END AS BIT)       AS CanMintLot,
        CAST(tc.DeprecatedAt AT TIME ZONE 'UTC' AT TIME ZONE 'Eastern Standard Time' AS DATETIME2(3)) AS DeprecatedAtEt,
        CAST(CASE WHEN tc.DeprecatedAt IS NULL THEN 0 ELSE 1 END AS BIT) AS IsOffDieNow
    FROM Tools.ToolCavity tc
    INNER JOIN Tools.ToolCavityStatusCode cs ON cs.Id = tc.StatusCodeId
    LEFT JOIN Parts.Item i ON i.Id = tc.ItemId
    WHERE @StartUtc IS NOT NULL
      AND tc.ToolId = @ToolId
      AND cs.Code = N'Active'
      AND (tc.DeprecatedAt IS NULL OR tc.DeprecatedAt > @StartUtc)
    ORDER BY i.PartNumber, tc.CavityCode;
END;
GO
