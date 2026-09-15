SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0022_PlantFloor_DieCast/110_CavityScrap.sql';
GO

-- =============================================
-- CAVITY-ATTRIBUTED DIE-CAST SCRAP (migration 0084).
--
-- Die-cast scrap is a fact about (Shift, Press, Tool, Cavity, Part); the LOT is
-- optional decoration. These assertions pin the SHAPE; behaviour tests follow
-- in later tasks of the same plan.
--
-- NOTE the asymmetry these tests encode, because it is the thing most likely to
-- be "tidied" later: RejectEvent.LotId becomes NULLABLE, while
-- DieCastContribution.LotId stays NOT NULL. See spec sec 3.6 -- a basketless
-- cavity must NOT advance its shot watermark, and that constraint is what
-- stops it.
-- =============================================

DECLARE @v NVARCHAR(20);

SET @v = CAST((SELECT is_nullable FROM sys.columns
               WHERE object_id = OBJECT_ID(N'Workorder.RejectEvent') AND name = N'LotId') AS NVARCHAR(20));
EXEC test.Assert_IsEqual @TestName = N'[0084] RejectEvent.LotId is nullable',
    @Expected = N'1', @Actual = @v;

SET @v = CAST((SELECT COUNT(*) FROM sys.columns
               WHERE object_id = OBJECT_ID(N'Workorder.RejectEvent')
                 AND name IN (N'ItemId', N'ToolId', N'ToolCavityId', N'ShiftId', N'CellLocationId')) AS NVARCHAR(20));
EXEC test.Assert_IsEqual @TestName = N'[0084] RejectEvent gained 5 attribution columns',
    @Expected = N'5', @Actual = @v;

SET @v = CAST((SELECT is_nullable FROM sys.columns
               WHERE object_id = OBJECT_ID(N'Workorder.DieCastContribution') AND name = N'LotId') AS NVARCHAR(20));
EXEC test.Assert_IsEqual @TestName = N'[0084] DieCastContribution.LotId stays NOT NULL (spec 3.6)',
    @Expected = N'0', @Actual = @v;

-- every index on RejectEvent must remain partition-aligned, or sliding-window
-- TRUNCATE retention (B2) breaks silently at the next maintenance run
SET @v = CAST((SELECT COUNT(*) FROM sys.indexes i
               JOIN sys.data_spaces ds ON ds.data_space_id = i.data_space_id
               WHERE i.object_id = OBJECT_ID(N'Workorder.RejectEvent')
                 AND i.index_id > 0 AND ds.name <> N'ps_MonthlyUtc') AS NVARCHAR(20));
EXEC test.Assert_IsEqual @TestName = N'[0084] every RejectEvent index still ON ps_MonthlyUtc',
    @Expected = N'0', @Actual = @v;

SET @v = CAST((SELECT COUNT(*) FROM Workorder.DieCastVarianceReason) AS NVARCHAR(20));
EXEC test.Assert_IsEqual @TestName = N'[0084] DieCastVarianceReason seeded with 5 reasons',
    @Expected = N'5', @Actual = @v;

SET @v = (SELECT CAST(RequiresNote AS NVARCHAR(20)) FROM Workorder.DieCastVarianceReason WHERE Code = N'Unknown');
EXEC test.Assert_IsEqual @TestName = N'[0084] Unknown requires a note',
    @Expected = N'1', @Actual = @v;

SET @v = (SELECT CAST(dc.IsNonRejectScrap AS NVARCHAR(20)) FROM Quality.DefectCode dc WHERE dc.Code = N'DC-999');
EXEC test.Assert_IsEqual @TestName = N'[0084] DC-999 Warmup is non-reject scrap',
    @Expected = N'1', @Actual = @v;

SET @v = (SELECT oc.Code FROM Quality.DefectCode dc
          JOIN Parts.OperationCategory oc ON oc.Id = dc.OperationCategoryId WHERE dc.Code = N'DC-999');
EXEC test.Assert_IsEqual @TestName = N'[0084] DC-999 is categorised DieCast',
    @Expected = N'DieCast', @Actual = @v;

SET @v = (SELECT cp.Code FROM Quality.DefectCode dc
          JOIN Quality.ChargeToParty cp ON cp.Id = dc.ChargeToPartyId WHERE dc.Code = N'DC-999');
EXEC test.Assert_IsEqual @TestName = N'[0084] DC-999 charges to DieCast',
    @Expected = N'DieCast', @Actual = @v;

-- backfill: every pre-existing reject must now carry its LOT's part
SET @v = CAST((SELECT COUNT(*) FROM Workorder.RejectEvent re
               JOIN Lots.Lot l ON l.Id = re.LotId
               WHERE re.ItemId IS NULL OR re.ItemId <> l.ItemId) AS NVARCHAR(20));
EXEC test.Assert_IsEqual @TestName = N'[0084] ItemId backfilled to match every existing LOT',
    @Expected = N'0', @Actual = @v;
GO
