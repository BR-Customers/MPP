-- =============================================
-- File:         0130_LotToolCavity/010_cavity_open_basket_reads.sql
-- Author:       Blue Ridge Automation
-- Created:      2026-11-16
-- Description:  Migration 0130 (IX_Lot_ToolCavity_Status). Pins the index
--               definition and the per-cavity "Open basket" behaviour of the
--               procs it serves. No proc changed, so the behaviour assertions
--               pass with and without the index (same rows):
--                 * Workorder.DieCastScrap_Write die-wide writes one row per
--                   active cavity, carrying the cavity's Open LOT, else NULL --
--                   never a Good / Closed basket, never another die's;
--                 * Lots.Lot_GetLatestForToolCavity returns the newest not-Closed
--                   LOT on (tool, cavity);
--                 * Tools.ToolCavity_Deprecate refuses a cavity with an Open
--                   basket and deprecates one whose baskets are all Good / Closed.
--               Fixture: die A (cavities a, b, c), die B (cavity a), hand-built LOTs.
-- =============================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0130_LotToolCavity/010_cavity_open_basket_reads.sql';
GO

-- ---- cleanup (idempotent, FK-safe) ----
DELETE re FROM Workorder.RejectEvent re INNER JOIN Tools.Tool t ON t.Id = re.ToolId WHERE t.Code IN (N'TEST-0130-A', N'TEST-0130-B');
DELETE FROM Lots.Lot WHERE LotName LIKE N'T0130-%';
DELETE tc FROM Tools.ToolCavity tc INNER JOIN Tools.Tool t ON t.Id = tc.ToolId WHERE t.Code IN (N'TEST-0130-A', N'TEST-0130-B');
DELETE FROM Tools.Tool WHERE Code IN (N'TEST-0130-A', N'TEST-0130-B');
DELETE FROM Oee.Shift WHERE Remarks = N'TEST-0130';
GO

-- ---- the index ----
DECLARE @f NVARCHAR(200) = (SELECT filter_definition FROM sys.indexes
    WHERE object_id = OBJECT_ID(N'Lots.Lot') AND name = N'IX_Lot_ToolCavity_Status');
EXEC test.Assert_IsEqual N'[0130] IX_Lot_ToolCavity_Status filters die-cast LOTs', N'([ToolCavityId] IS NOT NULL)', @f;
DECLARE @keys NVARCHAR(200) = (
    SELECT STRING_AGG(c.name, N',') WITHIN GROUP (ORDER BY ic.key_ordinal)
    FROM sys.indexes i
    INNER JOIN sys.index_columns ic ON ic.object_id = i.object_id AND ic.index_id = i.index_id AND ic.is_included_column = 0
    INNER JOIN sys.columns c ON c.object_id = ic.object_id AND c.column_id = ic.column_id
    WHERE i.object_id = OBJECT_ID(N'Lots.Lot') AND i.name = N'IX_Lot_ToolCavity_Status');
EXEC test.Assert_IsEqual N'[0130] keyed (ToolCavityId, LotStatusId)', N'ToolCavityId,LotStatusId', @keys;
DECLARE @inc NVARCHAR(200) = (
    SELECT STRING_AGG(c.name, N',') WITHIN GROUP (ORDER BY c.name)
    FROM sys.indexes i
    INNER JOIN sys.index_columns ic ON ic.object_id = i.object_id AND ic.index_id = i.index_id AND ic.is_included_column = 1
    INNER JOIN sys.columns c ON c.object_id = ic.object_id AND c.column_id = ic.column_id
    WHERE i.object_id = OBJECT_ID(N'Lots.Lot') AND i.name = N'IX_Lot_ToolCavity_Status');
EXEC test.Assert_IsEqual N'[0130] INCLUDE (Id, ToolId) -- never PieceCount', N'Id,ToolId', @inc;
DECLARE @sv INT = (SELECT COUNT(*) FROM dbo.SchemaVersion WHERE MigrationId = N'0130_lot_tool_cavity_index');
EXEC test.Assert_IsEqual N'[0130] recorded in dbo.SchemaVersion', N'1', @sv;
GO

-- ---- fixture + assertions (one batch so the locals stay in scope) ----
DECLARE @Item BIGINT = (SELECT TOP 1 Id FROM Parts.Item WHERE DeprecatedAt IS NULL ORDER BY Id);
DECLARE @Cell BIGINT = (
    SELECT TOP 1 c.Id FROM Location.Location c
    INNER JOIN Location.LocationTypeDefinition d ON d.Id = c.LocationTypeDefinitionId
    WHERE d.Code = N'DieCastMachine' AND c.DeprecatedAt IS NULL ORDER BY c.Id);
DECLARE @Defect BIGINT = (SELECT TOP 1 Id FROM Quality.DefectCode ORDER BY Id);
IF @Item IS NULL OR @Cell IS NULL OR @Defect IS NULL
    RAISERROR(N'0130/010 fixture: no item, die-cast cell or defect code -- BLOCKED.', 16, 1);

DECLARE @Die BIGINT = (SELECT Id FROM Tools.ToolType WHERE Code = N'Die');
DECLARE @ToolActive BIGINT = (SELECT Id FROM Tools.ToolStatusCode WHERE Code = N'Active');
DECLARE @CavActive BIGINT = (SELECT Id FROM Tools.ToolCavityStatusCode WHERE Code = N'Active');
INSERT INTO Tools.Tool (ToolTypeId, Code, Name, StatusCodeId, CreatedAt, CreatedByUserId)
VALUES (@Die, N'TEST-0130-A', N'0130 die A', @ToolActive, SYSUTCDATETIME(), 1);
DECLARE @ToolA BIGINT = SCOPE_IDENTITY();
INSERT INTO Tools.Tool (ToolTypeId, Code, Name, StatusCodeId, CreatedAt, CreatedByUserId)
VALUES (@Die, N'TEST-0130-B', N'0130 die B', @ToolActive, SYSUTCDATETIME(), 1);
DECLARE @ToolB BIGINT = SCOPE_IDENTITY();
INSERT INTO Tools.ToolCavity (ToolId, CavityCode, StatusCodeId, ItemId, CreatedAt, CreatedByUserId)
VALUES (@ToolA, N'a', @CavActive, @Item, SYSUTCDATETIME(), 1);
DECLARE @CavA BIGINT = SCOPE_IDENTITY();
INSERT INTO Tools.ToolCavity (ToolId, CavityCode, StatusCodeId, ItemId, CreatedAt, CreatedByUserId)
VALUES (@ToolA, N'b', @CavActive, @Item, SYSUTCDATETIME(), 1);
DECLARE @CavB BIGINT = SCOPE_IDENTITY();
INSERT INTO Tools.ToolCavity (ToolId, CavityCode, StatusCodeId, ItemId, CreatedAt, CreatedByUserId)
VALUES (@ToolA, N'c', @CavActive, @Item, SYSUTCDATETIME(), 1);
INSERT INTO Tools.ToolCavity (ToolId, CavityCode, StatusCodeId, ItemId, CreatedAt, CreatedByUserId)
VALUES (@ToolB, N'a', @CavActive, @Item, SYSUTCDATETIME(), 1);
DECLARE @CavBa BIGINT = SCOPE_IDENTITY();

DECLARE @ScheduleId BIGINT = (SELECT TOP 1 Id FROM Oee.ShiftSchedule ORDER BY Id);
IF @ScheduleId IS NULL
BEGIN
    INSERT INTO Oee.ShiftSchedule (Name, StartTime, EndTime, DaysOfWeekBitmask, EffectiveFrom, CreatedByUserId)
    VALUES (N'0130/010 Test Schedule', '06:00', '14:00', 31, '2026-01-01', 1);
    SET @ScheduleId = SCOPE_IDENTITY();
END
INSERT INTO Oee.Shift (ShiftScheduleId, ActualStart, ActualEnd, Remarks)
VALUES (@ScheduleId, DATEADD(DAY, -30, SYSUTCDATETIME()), DATEADD(HOUR, 8, DATEADD(DAY, -30, SYSUTCDATETIME())), N'TEST-0130');
DECLARE @Shift BIGINT = SCOPE_IDENTITY();

DECLARE @Open BIGINT = (SELECT Id FROM Lots.LotStatusCode WHERE Code = N'Open');
DECLARE @Good BIGINT = (SELECT Id FROM Lots.LotStatusCode WHERE Code = N'Good');
DECLARE @Clsd BIGINT = (SELECT Id FROM Lots.LotStatusCode WHERE Code = N'Closed');
DECLARE @Mfg  BIGINT = (SELECT Id FROM Lots.LotOriginType WHERE Code = N'Manufactured');
DECLARE @T DATETIME2(3) = SYSUTCDATETIME();
INSERT INTO Lots.Lot (LotName, ItemId, LotOriginTypeId, LotStatusId, PieceCount, MaxPieceCount, CurrentLocationId,
                      ToolId, ToolCavityId, CreatedAtTerminalId, CreatedByUserId, CreatedAt)
VALUES (N'T0130-1', @Item, @Mfg, @Clsd, 90, 100, @Cell, @ToolA, @CavA,  @Cell, 1, DATEADD(MINUTE, -30, @T)), -- A/a Closed
       (N'T0130-2', @Item, @Mfg, @Good, 95, 100, @Cell, @ToolA, @CavA,  @Cell, 1, DATEADD(MINUTE, -20, @T)), -- A/a Good (released)
       (N'T0130-3', @Item, @Mfg, @Open, 10, 100, @Cell, @ToolA, @CavA,  @Cell, 1, DATEADD(MINUTE, -10, @T)), -- A/a Open
       (N'T0130-4', @Item, @Mfg, @Good, 95, 100, @Cell, @ToolA, @CavB,  @Cell, 1, DATEADD(MINUTE, -20, @T)), -- A/b Good
       (N'T0130-5', @Item, @Mfg, @Clsd, 90, 100, @Cell, @ToolA, @CavB,  @Cell, 1, DATEADD(MINUTE, -10, @T)), -- A/b Closed (newest)
       (N'T0130-6', @Item, @Mfg, @Open, 20, 100, @Cell, @ToolB, @CavBa, @Cell, 1, DATEADD(MINUTE, -10, @T));  -- B/a Open
DECLARE @L3 BIGINT = (SELECT Id FROM Lots.Lot WHERE LotName = N'T0130-3');

-- ---- DieCastScrap_Write, die-wide ----
DECLARE @J NVARCHAR(MAX) = N'[{"defectCodeId":' + CAST(@Defect AS NVARCHAR(20)) + N',"quantity":3}]';
EXEC Workorder.DieCastScrap_Write @ToolId = @ToolA, @ShiftId = @Shift, @CellLocationId = @Cell,
     @DieWideJson = @J, @AppUserId = 1;
DECLARE @s NVARCHAR(MAX) = (
    SELECT STRING_AGG(tc.CavityCode + N':' + ISNULL(l.LotName, N'-') + N':' + CAST(re.Quantity AS NVARCHAR(10)), N',')
           WITHIN GROUP (ORDER BY tc.CavityCode)
    FROM Workorder.RejectEvent re
    INNER JOIN Tools.ToolCavity tc ON tc.Id = re.ToolCavityId
    LEFT JOIN Lots.Lot l ON l.Id = re.LotId
    WHERE re.ToolId = @ToolA);
EXEC test.Assert_IsEqual N'[ScrapWrite] die-wide: one row per active cavity, the Open LOT or none (Good / Closed / other die never)',
    N'a:T0130-3:3,b:-:3,c:-:3', @s;

-- ---- Lot_GetLatestForToolCavity ----
DECLARE @LT TABLE (Id BIGINT, LotName NVARCHAR(50), PieceCount INT, InventoryAvailable INT, CavityCode NVARCHAR(50));
INSERT INTO @LT EXEC Lots.Lot_GetLatestForToolCavity @ToolId = @ToolA, @ToolCavityId = @CavA;
SET @s = (SELECT LotName FROM @LT);
EXEC test.Assert_IsEqual N'[LatestForToolCavity] A/a: newest not-Closed is the Open basket', N'T0130-3', @s;
DELETE FROM @LT;
INSERT INTO @LT EXEC Lots.Lot_GetLatestForToolCavity @ToolId = @ToolA, @ToolCavityId = @CavB;
SET @s = (SELECT LotName FROM @LT);
EXEC test.Assert_IsEqual N'[LatestForToolCavity] A/b: skips the newer Closed basket', N'T0130-4', @s;
DELETE FROM @LT;
INSERT INTO @LT EXEC Lots.Lot_GetLatestForToolCavity @ToolId = @ToolA, @ToolCavityId = @CavBa;
SET @s = CAST((SELECT COUNT(*) FROM @LT) AS NVARCHAR(10));
EXEC test.Assert_IsEqual N'[LatestForToolCavity] cavity of another die: nothing', N'0', @s;

-- ---- ToolCavity_Deprecate open-basket guard ----
DECLARE @R TABLE (Status BIT, Message NVARCHAR(500));
INSERT INTO @R EXEC Tools.ToolCavity_Deprecate @Id = @CavA, @AppUserId = 1;
SET @s = (SELECT CAST(Status AS NVARCHAR(1)) + N':' + Message FROM @R);
EXEC test.Assert_IsEqual N'[CavityDeprecate] cavity with an Open basket is refused',
    N'0:This cavity still has an open basket. Release or void it before deprecating the cavity.', @s;
SET @s = (SELECT CASE WHEN DeprecatedAt IS NULL THEN N'live' ELSE N'deprecated' END FROM Tools.ToolCavity WHERE Id = @CavA);
EXEC test.Assert_IsEqual N'[CavityDeprecate] refused cavity stays live', N'live', @s;
DELETE FROM @R;
INSERT INTO @R EXEC Tools.ToolCavity_Deprecate @Id = @CavB, @AppUserId = 1;
SET @s = (SELECT CAST(Status AS NVARCHAR(1)) FROM @R);
EXEC test.Assert_IsEqual N'[CavityDeprecate] cavity with only Good / Closed baskets is deprecated', N'1', @s;
-- releasing the Open basket clears the guard
UPDATE Lots.Lot SET LotStatusId = @Good WHERE Id = @L3;
DELETE FROM @R;
INSERT INTO @R EXEC Tools.ToolCavity_Deprecate @Id = @CavA, @AppUserId = 1;
SET @s = (SELECT CAST(Status AS NVARCHAR(1)) FROM @R);
EXEC test.Assert_IsEqual N'[CavityDeprecate] after the basket is released the cavity deprecates', N'1', @s;
GO

-- ---- cleanup ----
DELETE re FROM Workorder.RejectEvent re INNER JOIN Tools.Tool t ON t.Id = re.ToolId WHERE t.Code IN (N'TEST-0130-A', N'TEST-0130-B');
DELETE FROM Lots.Lot WHERE LotName LIKE N'T0130-%';
DELETE tc FROM Tools.ToolCavity tc INNER JOIN Tools.Tool t ON t.Id = tc.ToolId WHERE t.Code IN (N'TEST-0130-A', N'TEST-0130-B');
DELETE FROM Tools.Tool WHERE Code IN (N'TEST-0130-A', N'TEST-0130-B');
DELETE FROM Oee.Shift WHERE Remarks = N'TEST-0130';
GO

EXEC test.EndTestFile;
GO
