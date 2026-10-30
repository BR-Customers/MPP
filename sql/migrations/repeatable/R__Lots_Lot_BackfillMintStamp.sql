-- =============================================
-- Procedure:   Lots.Lot_BackfillMintStamp
-- Author:      Blue Ridge Automation
-- Created:     2026-10-30
-- Version:     1.0
--
-- Description:
--   ONE-TIME backfill for migration 0117 (OEE dashboard spec
--   docs/superpowers/specs/2026-10-27-oee-dashboard-design.md v0.3.1 sec 7.5).
--   From 0117 on, the mint procs (Workorder.Assembly_CompleteTray v1.6,
--   Workorder.MachiningOut_Mint v2.9) stamp Lots.Lot.ShiftId + MintedPieceCount.
--   This stamps the LOTs minted BEFORE that, so the dashboard's good count has
--   history. Run once by the release runbook: @Commit = 0 first, read the report,
--   then @Commit = 1. A repeatable proc rather than migration SQL because
--   versioned migrations run before the functions it needs.
--
--   Candidates -- LOTs a MINT produced, not yet stamped:
--     FinishedGood or SubAssembly, Manufactured origin, ShiftId NULL, and the
--     child of a Consumption edge (RelationshipTypeId 3) whose source is a
--     DIFFERENT part (BOM / Machining OUT mint) or a Received / ReceivedOffsite
--     LOT of the same part (pass-through repack).
--   Never candidates: split children (Split edge, 1), merge outputs (Merge edge,
--     2), rework children (Lots.ContainerRework_MovePieces writes a Consumption
--     edge from a same-part MANUFACTURED LOT -- excluded by the source rule).
--
--   ShiftId          = Oee.ufn_ShiftIdForInstant(<birth placement>, CreatedAt),
--                      birth placement = the LOT's first LotMovement destination
--                      (the mint's @CellLocationId / line), else CurrentLocationId.
--   MintedPieceCount = the PieceCount in the LOT's LotCreated birth audit
--                      (exact; Assembly_CompleteTray writes it), else rebuilt as
--                      current PieceCount + its scrap (RejectEvent) + pieces split
--                      out (Split edges) + pieces moved out by rework (same-part
--                      Consumption edges). A LOT merged away (it is the parent of
--                      a Merge edge) has no birth audit to trust and cannot be
--                      rebuilt: NotReconstructable.
--
--   Outcome per candidate: Stamped | NoShift (no shift covers its birth) |
--   NotReconstructable. Only Stamped rows are written; the others are reported
--   and left NULL (they stay out of good -- the dashboard never guesses).
--
-- Parameters:
--   @Commit    BIT    - 0 (default) = rehearse; 1 = write.
--   @AppUserId BIGINT - required (audit attribution).
--
-- Result set: one row per candidate --
--   LotId, LotName, ShiftId NULL, MintedPieceCount NULL, Outcome.
--
-- @Commit = 0: run standalone (the runbook), it performs the UPDATE inside a
--   transaction and ROLLS BACK, so the rehearsal exercises the write (CLAUDE.md
--   one-off remediation rule). Captured by INSERT-EXEC (@@TRANCOUNT > 0 on entry)
--   a ROLLBACK is illegal (Msg 3915), so it reports without writing.
--
-- Change Log:
--   2026-10-30 - 1.0 - Initial version.
-- =============================================
CREATE OR ALTER PROCEDURE Lots.Lot_BackfillMintStamp
    @Commit    BIT    = 0,
    @AppUserId BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @ProcName NVARCHAR(200) = N'Lots.Lot_BackfillMintStamp';
    DECLARE @OuterTran INT = @@TRANCOUNT;

    IF @AppUserId IS NULL
    BEGIN
        RAISERROR(N'Lots.Lot_BackfillMintStamp: @AppUserId is required.', 16, 1);
        RETURN;
    END

    DECLARE @Mfg BIGINT = (SELECT Id FROM Lots.LotOriginType WHERE Code = N'Manufactured');

    DECLARE @Cand TABLE (
        LotId            BIGINT       NOT NULL PRIMARY KEY,
        LotName          NVARCHAR(50) NOT NULL,
        ShiftId          BIGINT       NULL,
        MintedPieceCount INT          NULL,
        Outcome          NVARCHAR(30) NOT NULL
    );

    INSERT INTO @Cand (LotId, LotName, ShiftId, MintedPieceCount, Outcome)
    SELECT l.Id, l.LotName, sh.ShiftId, q.Minted,
           CASE WHEN q.Minted IS NULL  THEN N'NotReconstructable'
                WHEN sh.ShiftId IS NULL THEN N'NoShift'
                ELSE N'Stamped' END
    FROM Lots.Lot l
    INNER JOIN Parts.Item it     ON it.Id = l.ItemId
    INNER JOIN Parts.ItemType ty ON ty.Id = it.ItemTypeId
    OUTER APPLY (
        SELECT TOP 1 m.ToLocationId
        FROM Lots.LotMovement m
        WHERE m.LotId = l.Id
        ORDER BY m.MovedAt, m.Id
    ) bm
    OUTER APPLY (
        SELECT TOP 1 f.ShiftId
        FROM Oee.ufn_ShiftIdForInstant(COALESCE(bm.ToLocationId, l.CurrentLocationId), l.CreatedAt) f
    ) sh
    OUTER APPLY (
        SELECT TOP 1 TRY_CAST(JSON_VALUE(e.NewValue, N'$.PieceCount') AS INT) AS BirthCount
        FROM Lots.LotEventLog e
        INNER JOIN Audit.LogEventType t ON t.Id = e.LogEventTypeId
        WHERE e.LotId = l.Id AND t.Code = N'LotCreated'
        ORDER BY e.LoggedAt, e.Id
    ) ba
    OUTER APPLY (
        SELECT CASE
            WHEN ba.BirthCount IS NOT NULL THEN ba.BirthCount
            WHEN EXISTS (SELECT 1 FROM Lots.LotGenealogy g WHERE g.ParentLotId = l.Id AND g.RelationshipTypeId = 2) THEN NULL
            ELSE l.PieceCount
               + ISNULL((SELECT SUM(re.Quantity) FROM Workorder.RejectEvent re WHERE re.LotId = l.Id), 0)
               + ISNULL((SELECT SUM(g.PieceCount) FROM Lots.LotGenealogy g
                         WHERE g.ParentLotId = l.Id AND g.RelationshipTypeId = 1), 0)
               + ISNULL((SELECT SUM(g.PieceCount) FROM Lots.LotGenealogy g
                         INNER JOIN Lots.Lot c ON c.Id = g.ChildLotId
                         WHERE g.ParentLotId = l.Id AND g.RelationshipTypeId = 3 AND c.ItemId = l.ItemId), 0)
        END AS Minted
    ) q
    WHERE l.ShiftId IS NULL
      AND l.LotOriginTypeId = @Mfg
      AND ty.Code IN (N'FinishedGood', N'SubAssembly')
      AND EXISTS (
          SELECT 1
          FROM Lots.LotGenealogy g
          INNER JOIN Lots.Lot p           ON p.Id = g.ParentLotId
          INNER JOIN Lots.LotOriginType po ON po.Id = p.LotOriginTypeId
          WHERE g.ChildLotId = l.Id
            AND g.RelationshipTypeId = 3
            AND (p.ItemId <> l.ItemId OR po.Code IN (N'Received', N'ReceivedOffsite')))
      AND NOT EXISTS (
          SELECT 1 FROM Lots.LotGenealogy g
          WHERE g.ChildLotId = l.Id AND g.RelationshipTypeId IN (1, 2));

    DECLARE @Stamped INT = (SELECT COUNT(*) FROM @Cand WHERE Outcome = N'Stamped');
    DECLARE @NoShift INT = (SELECT COUNT(*) FROM @Cand WHERE Outcome = N'NoShift');
    DECLARE @NotRec  INT = (SELECT COUNT(*) FROM @Cand WHERE Outcome = N'NotReconstructable');
    DECLARE @Desc NVARCHAR(1000) = Audit.ufn_TruncateActivity(
        N'Lot ' + Audit.ufn_MidDot() + N' Mint stamp backfill ' + Audit.ufn_MidDot()
        + N' Stamped ' + CAST(@Stamped AS NVARCHAR(20))
        + N', no shift ' + CAST(@NoShift AS NVARCHAR(20))
        + N', not reconstructable ' + CAST(@NotRec AS NVARCHAR(20)));
    DECLARE @NewValue NVARCHAR(MAX) =
        (SELECT @Stamped AS Stamped, @NoShift AS NoShift, @NotRec AS NotReconstructable FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

    IF @Commit = 1 OR @OuterTran = 0
    BEGIN
        BEGIN TRY
            BEGIN TRANSACTION;

            UPDATE l
               SET l.ShiftId          = c.ShiftId,
                   l.MintedPieceCount = c.MintedPieceCount
            FROM Lots.Lot l
            INNER JOIN @Cand c ON c.LotId = l.Id
            WHERE c.Outcome = N'Stamped'
              AND l.ShiftId IS NULL;

            EXEC Audit.Audit_LogOperation @AppUserId = @AppUserId, @LogEntityTypeCode = N'Lot', @EntityId = NULL,
                @LogEventTypeCode = N'Updated', @LogSeverityCode = N'Info', @Description = @Desc,
                @OldValue = NULL, @NewValue = @NewValue;

            IF @Commit = 1 COMMIT TRANSACTION;
            ELSE ROLLBACK TRANSACTION;   -- rehearsal: the write ran, nothing kept
        END TRY
        BEGIN CATCH
            IF @@TRANCOUNT > @OuterTran ROLLBACK TRANSACTION;
            DECLARE @ErrMsg NVARCHAR(4000) = @ProcName + N': ' + ERROR_MESSAGE();
            DECLARE @ErrSev INT = ERROR_SEVERITY(), @ErrState INT = ERROR_STATE();
            RAISERROR(@ErrMsg, @ErrSev, @ErrState);
            RETURN;
        END CATCH
    END

    SELECT LotId, LotName, ShiftId, MintedPieceCount, Outcome
    FROM @Cand
    ORDER BY LotId;
END;
GO
