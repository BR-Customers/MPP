-- =============================================
-- Repeatable:  R__Lots_Lot_SearchAdvanced.sql
-- Author:      Blue Ridge Automation
-- Modified:    2026-08-25
-- Version:     1.0
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
--              Origin machine is DieCastContribution.CellLocationId (the press,
--              stamped at write time by migration 0061). Deliberately NOT
--              derived from LotMovement: 0061 exists to stop live re-derivation
--              of the press, and a movement-based derivation reintroduces the
--              same drift.
--
--              Dates are Eastern calendar days, inclusive both ends, converted
--              to a half-open UTC range here so the filter agrees with the
--              Eastern-converted CreatedAt in the SELECT. (Audit.ConfigLog_List
--              does NOT do this -- it displays Eastern but filters raw UTC, so
--              near midnight its filter and column disagree. Do not copy it.)
--
--              The legacy Lot.DieNumber / Lot.CavityNumber columns are used
--              NOWHERE here -- superseded by ToolId / ToolCavityId.
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
    @LimitRows         INT           = 100
AS
BEGIN
    SET NOCOUNT ON;

    IF @LimitRows IS NULL OR @LimitRows < 1 SET @LimitRows = 100;

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

    ;WITH Descendants AS (
        SELECT Id FROM Location.Location WHERE Id = @LocationId
        UNION ALL
        SELECT c.Id FROM Location.Location c
        INNER JOIN Descendants d ON c.ParentLocationId = d.Id
    )
    SELECT TOP (@LimitRows)
        l.Id, l.LotName, l.ItemId, l.LotOriginTypeId, l.LotStatusId, l.PieceCount,
        l.VendorLotNumber, l.CurrentLocationId,
        CAST(l.CreatedAt AT TIME ZONE 'UTC' AT TIME ZONE 'Eastern Standard Time' AS DATETIME2(3)) AS CreatedAt,
        i.PartNumber         AS ItemPartNumber,
        sc.Code              AS LotStatusCode,
        ot.Code              AS LotOriginTypeCode,
        loc.Name             AS CurrentLocationName,
        lastop.OperationName AS LastOperationName,
        t.Code               AS ToolCode,
        tc.CavityNumber      AS CavityNumber,
        press.MachineName    AS OriginMachineName,
        COUNT(*) OVER()      AS TotalCount
    FROM Lots.Lot l
    INNER JOIN Parts.Item         i   ON i.Id   = l.ItemId
    INNER JOIN Lots.LotStatusCode sc  ON sc.Id  = l.LotStatusId
    INNER JOIN Lots.LotOriginType ot  ON ot.Id  = l.LotOriginTypeId
    INNER JOIN Location.Location  loc ON loc.Id = l.CurrentLocationId
    LEFT  JOIN Tools.Tool         t   ON t.Id   = l.ToolId
    LEFT  JOIN Tools.ToolCavity   tc  ON tc.Id  = l.ToolCavityId
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
    WHERE (@Q IS NULL OR l.LotName LIKE @Q OR l.VendorLotNumber LIKE @Q OR i.PartNumber LIKE @Q)
      AND (@ItemId          IS NULL OR l.ItemId          = @ItemId)
      AND (@FromUtc         IS NULL OR l.CreatedAt      >= @FromUtc)
      AND (@ToUtc           IS NULL OR l.CreatedAt       < @ToUtc)
      AND (@ToolId          IS NULL OR l.ToolId          = @ToolId)
      AND (@ToolCavityId    IS NULL OR l.ToolCavityId    = @ToolCavityId)
      AND (@LotStatusId     IS NULL OR l.LotStatusId     = @LotStatusId)
      AND (@LotOriginTypeId IS NULL OR l.LotOriginTypeId = @LotOriginTypeId)
      AND (@LocationId      IS NULL OR l.CurrentLocationId IN (SELECT Id FROM Descendants))
      AND (@MachineLocationId IS NULL OR EXISTS (
              SELECT 1 FROM Workorder.DieCastContribution dm
              WHERE dm.LotId = l.Id AND dm.CellLocationId = @MachineLocationId))
      AND (@ShiftId IS NULL OR EXISTS (
              SELECT 1 FROM Workorder.DieCastContribution ds
              WHERE ds.LotId = l.Id AND ds.ShiftId = @ShiftId))
    ORDER BY l.CreatedAt DESC, l.Id DESC
    OPTION (MAXRECURSION 100);
END
GO
