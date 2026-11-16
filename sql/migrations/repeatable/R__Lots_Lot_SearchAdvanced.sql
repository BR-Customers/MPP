-- =============================================
-- Repeatable:  R__Lots_Lot_SearchAdvanced.sql
-- Author:      Blue Ridge Automation
-- Modified:    2026-10-06
-- Version:     2.0 (2026-11-04; landed alone 2026-11-16) - see the v2.0 note below
-- Version:     1.3
-- Description: FDS-12-004 LOT Search. Filtered browse: free text, item, Eastern
--              created-day range, die, cavity, location (always incl.
--              descendants), origin machine, shift, status, origin type.
--              One result set (FDS-11-011); recency-ordered; TOP (@LimitRows)
--              with COUNT(*) OVER() AS TotalCount for the pager.
--
--              SEPARATE from Lots.Lot_Search, which is FROZEN: it has three
--              consumers (test 077_Lot_Search, BlueRidge.Lots.Lot.search, and
--              the HoldManagement bulk picker, which calls search()
--              POSITIONALLY). Widening it would break all three. See design
--              spec section 2.3.
--
--              Die / Cavity / Machine / Shift are die-cast-origin dimensions.
--              Lot.ToolId / ToolCavityId are NULL on merged LOTs (OI-05) and on
--              non-cast origins, and machine resolves through
--              Workorder.DieCastContribution -- so any of those four narrows to
--              die-cast-origin LOTs. Intended; surfaced in the UI, not
--              compensated for here.
--
--              Origin machine has TWO recorded sources. Normally-produced LOTs:
--              DieCastContribution.CellLocationId (the press, stamped at write
--              time by migration 0061). Cutover LOTs: Lot.ProducedAtLocationId
--              (0082), read off the paper tag -- they have no contribution rows
--              at all, so without it the captured machine is unreachable here.
--              Contribution wins where a LOT has both. Still deliberately NOT
--              derived from LotMovement: 0061 exists to stop live re-derivation
--              of the press, and both sources above are RECORDED, not derived.
--
--              Dates are Eastern calendar days, inclusive both ends, converted
--              to a half-open UTC range here so the filter agrees with the
--              Eastern-converted CreatedAt in the SELECT. (Audit.ConfigLog_List
--              does NOT do this -- it displays Eastern but filters raw UTC, so
--              near midnight its filter and column disagree. Do not copy it.)
--
--              The legacy Lot.DieNumber column is used NOWHERE here --
--              superseded by ToolId / ToolCavityId. (Lot.CavityNumber, the D2
--              free-text manual-cavity note, was dropped outright by 0076.)
--
--              v1.2 (2026-09-21): + t.Name AS ToolName after ToolCode. The
--              LOT Search grid shows the die by NAME -- the code is known
--              only to the die manager and is on no shop-floor screen.
--
--              v1.3 (2026-10-06): + i.Description AS ItemDescription after
--              ItemPartNumber -- the grid shows the part by description, and
--              the free text matches it too, so what is on screen is
--              searchable. + @ExcludeFinishedGoods BIT = 0 (LAST param,
--              default keeps every existing caller's result). The LOT Search
--              screen passes 1 by default: finished-good tray LOTs outnumber
--              everything else and are rarely what is being looked for.
--              Same predicate as Lots.Lot_GetLineInventoryByPart.
--              Callers using a fixed-shape INSERT-EXEC capture must widen
--              to 20 columns.
-- =============================================
--              v2.0 (2026-11-04, container-as-LOT spec 8.2): year-scale volume.
--              An exact LOT name is found at any age; every other match (part
--              of a name, part number / description through Parts.Item, vendor
--              LOT) looks in the created-day range when one is given, else the
--              last 90 days unless + @IncludeOlder BIT = 0 (LAST param) is 1.
--              COUNT(*) OVER() is gone: TotalCount = rows returned, + HasMore
--              (LAST column). Fixed-shape INSERT-EXEC captures widen to 21.
-- =============================================
CREATE OR ALTER PROCEDURE Lots.Lot_SearchAdvanced
    @Query             NVARCHAR(100) = NULL,
    @ItemId            BIGINT        = NULL,
    @CreatedFromEt     DATE          = NULL,
    @CreatedToEt       DATE          = NULL,
    @ToolId            BIGINT        = NULL,
    @ToolCavityId      BIGINT        = NULL,
    @LocationId        BIGINT        = NULL,
    @MachineLocationId BIGINT        = NULL,
    @ShiftId           BIGINT        = NULL,
    @LotStatusId       BIGINT        = NULL,
    @LotOriginTypeId   BIGINT        = NULL,
    @LimitRows         INT           = 100,
    @ExcludeFinishedGoods BIT        = 0,
    @IncludeOlder      BIT           = 0
AS
BEGIN
    SET NOCOUNT ON;

    IF @LimitRows IS NULL OR @LimitRows < 1 SET @LimitRows = 100;
    IF @ExcludeFinishedGoods IS NULL SET @ExcludeFinishedGoods = 0;

    DECLARE @Q NVARCHAR(120) = CASE
        WHEN @Query IS NULL OR LTRIM(RTRIM(@Query)) = N'' THEN NULL
        ELSE N'%' + LTRIM(RTRIM(@Query)) + N'%' END;

    -- Eastern calendar days -> half-open UTC instant range.
    DECLARE @FromUtc DATETIME2(3) = NULL, @ToUtc DATETIME2(3) = NULL;
    IF @CreatedFromEt IS NOT NULL
        SET @FromUtc = CAST(CAST(@CreatedFromEt AS DATETIME2(3))
            AT TIME ZONE 'Eastern Standard Time' AT TIME ZONE 'UTC' AS DATETIME2(3));
    IF @CreatedToEt IS NOT NULL
        SET @ToUtc = CAST(CAST(DATEADD(DAY, 1, @CreatedToEt) AS DATETIME2(3))
            AT TIME ZONE 'Eastern Standard Time' AT TIME ZONE 'UTC' AS DATETIME2(3));

    -- v2.0 (container-as-LOT spec 8.2): an exact LOT name is found at any age; every
    -- other match looks inside the window -- the explicit created-day range when given,
    -- else the last 90 days unless @IncludeOlder = 1. Candidates first (newest, the limit
    -- + 1, so HasMore is known without counting every match), then the joins / applies
    -- for the returned rows only.
    DECLARE @Raw NVARCHAR(100) = NULLIF(LTRIM(RTRIM(@Query)), N'');
    -- A shift is an explicit time scope too: it replaces the window like a day range.
    DECLARE @WinFrom DATETIME2(3) = CASE WHEN ISNULL(@IncludeOlder, 0) = 1 OR @FromUtc IS NOT NULL OR @ToUtc IS NOT NULL
                                              OR @ShiftId IS NOT NULL
                                         THEN NULL ELSE DATEADD(DAY, -90, SYSUTCDATETIME()) END;
    DECLARE @Items TABLE (Id BIGINT NOT NULL PRIMARY KEY);
    IF @Q IS NOT NULL
        INSERT INTO @Items (Id) SELECT i.Id FROM Parts.Item i WHERE i.PartNumber LIKE @Q OR i.Description LIKE @Q;
    DECLARE @Cand TABLE (Id BIGINT NOT NULL PRIMARY KEY);

    -- 1. exact LOT name, any age (same filters)
    IF @Raw IS NOT NULL
    BEGIN
    ;WITH Descendants AS (
        SELECT Id FROM Location.Location WHERE Id = @LocationId
        UNION ALL
        SELECT c.Id FROM Location.Location c
        INNER JOIN Descendants d ON c.ParentLocationId = d.Id
    )
        INSERT INTO @Cand (Id)
        SELECT l.Id
        FROM Lots.Lot l
        INNER JOIN Parts.Item i ON i.Id = l.ItemId
        WHERE l.LotName = @Raw
      AND (@ItemId          IS NULL OR l.ItemId          = @ItemId)
      AND (@FromUtc         IS NULL OR l.CreatedAt      >= @FromUtc)
      AND (@ToUtc           IS NULL OR l.CreatedAt       < @ToUtc)
      AND (@ToolId          IS NULL OR l.ToolId          = @ToolId)
      AND (@ToolCavityId    IS NULL OR l.ToolCavityId    = @ToolCavityId)
      AND (@LotStatusId     IS NULL OR l.LotStatusId     = @LotStatusId)
      AND (@LotOriginTypeId IS NULL OR l.LotOriginTypeId = @LotOriginTypeId)
      AND (@ExcludeFinishedGoods = 0
           OR i.ItemTypeId <> (SELECT Id FROM Parts.ItemType WHERE Code = N'FinishedGood'))
      AND (@LocationId      IS NULL OR l.CurrentLocationId IN (SELECT Id FROM Descendants))
      -- Origin machine has TWO recorded sources, and a LOT has at most one of
      -- them. A normally-produced LOT accumulates DieCastContribution rows at
      -- the press. A CUTOVER LOT has none -- it is migrated stock whose machine
      -- was read off the paper tag into Lot.ProducedAtLocationId (0082).
      -- Both are RECORDED values; neither is the live LotMovement re-derivation
      -- this proc's header rejects.
      AND (@MachineLocationId IS NULL
           OR l.ProducedAtLocationId = @MachineLocationId
           OR EXISTS (
              SELECT 1 FROM Workorder.DieCastContribution dm
              WHERE dm.LotId = l.Id AND dm.CellLocationId = @MachineLocationId))
      AND (@ShiftId IS NULL OR l.Id IN (
              SELECT ds.LotId FROM Workorder.DieCastContribution ds
              WHERE ds.ShiftId = @ShiftId))
        OPTION (MAXRECURSION 100, RECOMPILE);
    END

    -- 2. every other match, newest first, inside the window. An exact LOT name answers
    --    alone: the operator scanned or typed a whole LOT number, so this scan is skipped.
    IF NOT EXISTS (SELECT 1 FROM @Cand)
    BEGIN
    ;WITH Descendants AS (
        SELECT Id FROM Location.Location WHERE Id = @LocationId
        UNION ALL
        SELECT c.Id FROM Location.Location c
        INNER JOIN Descendants d ON c.ParentLocationId = d.Id
    )
    INSERT INTO @Cand (Id)
    SELECT TOP (@LimitRows + 1) l.Id
    FROM Lots.Lot l
    INNER JOIN Parts.Item i ON i.Id = l.ItemId
    WHERE (@WinFrom IS NULL OR l.CreatedAt >= @WinFrom)
      AND (@Q IS NULL OR l.LotName LIKE @Q OR l.VendorLotNumber LIKE @Q OR l.ItemId IN (SELECT Id FROM @Items))
      AND NOT EXISTS (SELECT 1 FROM @Cand x WHERE x.Id = l.Id)
      AND (@ItemId          IS NULL OR l.ItemId          = @ItemId)
      AND (@FromUtc         IS NULL OR l.CreatedAt      >= @FromUtc)
      AND (@ToUtc           IS NULL OR l.CreatedAt       < @ToUtc)
      AND (@ToolId          IS NULL OR l.ToolId          = @ToolId)
      AND (@ToolCavityId    IS NULL OR l.ToolCavityId    = @ToolCavityId)
      AND (@LotStatusId     IS NULL OR l.LotStatusId     = @LotStatusId)
      AND (@LotOriginTypeId IS NULL OR l.LotOriginTypeId = @LotOriginTypeId)
      AND (@ExcludeFinishedGoods = 0
           OR i.ItemTypeId <> (SELECT Id FROM Parts.ItemType WHERE Code = N'FinishedGood'))
      AND (@LocationId      IS NULL OR l.CurrentLocationId IN (SELECT Id FROM Descendants))
      -- Origin machine has TWO recorded sources, and a LOT has at most one of
      -- them. A normally-produced LOT accumulates DieCastContribution rows at
      -- the press. A CUTOVER LOT has none -- it is migrated stock whose machine
      -- was read off the paper tag into Lot.ProducedAtLocationId (0082).
      -- Both are RECORDED values; neither is the live LotMovement re-derivation
      -- this proc's header rejects.
      AND (@MachineLocationId IS NULL
           OR l.ProducedAtLocationId = @MachineLocationId
           OR EXISTS (
              SELECT 1 FROM Workorder.DieCastContribution dm
              WHERE dm.LotId = l.Id AND dm.CellLocationId = @MachineLocationId))
      AND (@ShiftId IS NULL OR l.Id IN (
              SELECT ds.LotId FROM Workorder.DieCastContribution ds
              WHERE ds.ShiftId = @ShiftId))
    ORDER BY l.CreatedAt DESC, l.Id DESC
    OPTION (MAXRECURSION 100, RECOMPILE);
    END

    DECLARE @Found INT = (SELECT COUNT(*) FROM @Cand);
    DECLARE @HasMore BIT = CASE WHEN @Found > @LimitRows THEN 1 ELSE 0 END;
    DECLARE @Returned INT = CASE WHEN @Found > @LimitRows THEN @LimitRows ELSE @Found END;

    SELECT TOP (@LimitRows)
        l.Id, l.LotName, l.ItemId, l.LotOriginTypeId, l.LotStatusId, l.PieceCount,
        l.VendorLotNumber, l.CurrentLocationId,
        CAST(l.CreatedAt AT TIME ZONE 'UTC' AT TIME ZONE 'Eastern Standard Time' AS DATETIME2(3)) AS CreatedAt,
        i.PartNumber         AS ItemPartNumber,
        i.Description        AS ItemDescription,
        sc.Code              AS LotStatusCode,
        ot.Code              AS LotOriginTypeCode,
        loc.Name             AS CurrentLocationName,
        lastop.OperationName AS LastOperationName,
        t.Code               AS ToolCode,
        t.Name               AS ToolName,
        tc.CavityCode        AS CavityCode,
        COALESCE(press.MachineName, pal.Name) AS OriginMachineName,
        @Returned            AS TotalCount,
        @HasMore             AS HasMore
    FROM @Cand cd
    INNER JOIN Lots.Lot           l   ON l.Id   = cd.Id
    INNER JOIN Parts.Item         i   ON i.Id   = l.ItemId
    INNER JOIN Lots.LotStatusCode sc  ON sc.Id  = l.LotStatusId
    INNER JOIN Lots.LotOriginType ot  ON ot.Id  = l.LotOriginTypeId
    INNER JOIN Location.Location  loc ON loc.Id = l.CurrentLocationId
    LEFT  JOIN Tools.Tool         t   ON t.Id   = l.ToolId
    LEFT  JOIN Tools.ToolCavity   tc  ON tc.Id  = l.ToolCavityId
    LEFT  JOIN Location.Location  pal ON pal.Id = l.ProducedAtLocationId
    OUTER APPLY (
        SELECT TOP (1) oty.Name AS OperationName
        FROM Workorder.ProductionEvent pe
        INNER JOIN Parts.OperationTemplate ot2 ON ot2.Id = pe.OperationTemplateId
        INNER JOIN Parts.OperationType     oty ON oty.Id = ot2.OperationTypeId
        WHERE pe.LotId = l.Id
        ORDER BY pe.EventAt DESC, pe.Id DESC
    ) lastop
    OUTER APPLY (
        SELECT TOP (1) cell.Name AS MachineName
        FROM Workorder.DieCastContribution dcc
        INNER JOIN Location.Location cell ON cell.Id = dcc.CellLocationId
        WHERE dcc.LotId = l.Id AND dcc.CellLocationId IS NOT NULL
        ORDER BY dcc.EventAt ASC, dcc.Id ASC
    ) press
    ORDER BY l.CreatedAt DESC, l.Id DESC;
END
GO
