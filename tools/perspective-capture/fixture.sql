SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO
-- ============================================================
-- Review-book fixtures. Three dies on three IDLE die cast machines
-- (DC1-M04/05/06 carry no tool and no baskets), so nothing existing in
-- MPP_MES_Dev is touched. Everything here is prefixed RB- and is removed by
-- teardown.sql.
--
-- Baskets are opened through Lots.DieCastLot_Open -- the same proc the Open
-- Basket tab calls -- so the fixture is the real path, not hand-built rows.
-- Counter readings are then driven through the UI for the screenshots.
-- ============================================================
SET NOCOUNT ON;
SET XACT_ABORT ON;

DECLARE @User BIGINT = (SELECT Id FROM Location.AppUser WHERE Pin = N'00002');
-- DC1-T1 is the die cast terminal's code in prod (and in Dev after the prod
-- config import); DC1-T01 was the older Dev seed's code.
DECLARE @Term BIGINT = (SELECT TOP 1 Id FROM Location.Location WHERE Code IN (N'DC1-T1', N'DC1-T01') AND DeprecatedAt IS NULL ORDER BY Code);
IF @Term IS NULL SELECT TOP 1 @Term = Id FROM Location.Location WHERE Name LIKE N'%Terminal%' ORDER BY Id;

DECLARE @DieType   BIGINT = (SELECT Id FROM Tools.ToolType             WHERE Code = N'Die');
DECLARE @ToolAct   BIGINT = (SELECT Id FROM Tools.ToolStatusCode       WHERE Code = N'Active');
DECLARE @CavAct    BIGINT = (SELECT Id FROM Tools.ToolCavityStatusCode WHERE Code = N'Active');
DECLARE @Uom       BIGINT = (SELECT TOP 1 UomId FROM Parts.Item WHERE UomId IS NOT NULL ORDER BY Id);
-- A casting's type, looked up by code: Item Ids differ between databases.
DECLARE @ItemType  BIGINT = (SELECT Id FROM Parts.ItemType WHERE Code = N'Component');

DECLARE @MA BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'DC1-M04');
DECLARE @MB BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'DC1-M05');
DECLARE @MC BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'DC1-M06');

-- ---------- parts (one per scenario, so basket capacity tells the story) ----------
IF NOT EXISTS (SELECT 1 FROM Parts.Item WHERE PartNumber = N'RB-A-70')
    INSERT INTO Parts.Item (ItemTypeId, PartNumber, Description, UomId, MaxLotSize, CreatedByUserId)
    VALUES (@ItemType, N'RB-A-70', N'Review book A - single cavity, 70 per basket', @Uom, 70, @User);
IF NOT EXISTS (SELECT 1 FROM Parts.Item WHERE PartNumber = N'RB-B-2200')
    INSERT INTO Parts.Item (ItemTypeId, PartNumber, Description, UomId, MaxLotSize, CreatedByUserId)
    VALUES (@ItemType, N'RB-B-2200', N'Review book B - multi cavity, 2200 per basket', @Uom, 2200, @User);
IF NOT EXISTS (SELECT 1 FROM Parts.Item WHERE PartNumber = N'RB-C-2000')
    INSERT INTO Parts.Item (ItemTypeId, PartNumber, Description, UomId, MaxLotSize, CreatedByUserId)
    VALUES (@ItemType, N'RB-C-2000', N'Review book C - solid run, 2000 per basket', @Uom, 2000, @User);

DECLARE @IA BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'RB-A-70');
DECLARE @IB BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'RB-B-2200');
DECLARE @IC BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'RB-C-2000');

-- ---------- dies ----------
IF NOT EXISTS (SELECT 1 FROM Tools.Tool WHERE Code = N'RB-A')
    INSERT INTO Tools.Tool (ToolTypeId, Code, Name, StatusCodeId, ShotCount, CreatedByUserId)
    VALUES (@DieType, N'RB-A', N'Review A - single cavity die', @ToolAct, 0, @User);
IF NOT EXISTS (SELECT 1 FROM Tools.Tool WHERE Code = N'RB-B')
    INSERT INTO Tools.Tool (ToolTypeId, Code, Name, StatusCodeId, ShotCount, CreatedByUserId)
    VALUES (@DieType, N'RB-B', N'Review B - four cavity family die', @ToolAct, 0, @User);
IF NOT EXISTS (SELECT 1 FROM Tools.Tool WHERE Code = N'RB-C')
    INSERT INTO Tools.Tool (ToolTypeId, Code, Name, StatusCodeId, ShotCount, CreatedByUserId)
    VALUES (@DieType, N'RB-C', N'Review C - four cavity die, solid run', @ToolAct, 0, @User);

DECLARE @TA BIGINT = (SELECT Id FROM Tools.Tool WHERE Code = N'RB-A');
DECLARE @TB BIGINT = (SELECT Id FROM Tools.Tool WHERE Code = N'RB-B');
DECLARE @TC BIGINT = (SELECT Id FROM Tools.Tool WHERE Code = N'RB-C');

-- ---------- cavities ----------
-- Cavity codes are letters (migration 0076), unique per (Tool, Item, CavityCode).
IF NOT EXISTS (SELECT 1 FROM Tools.ToolCavity WHERE ToolId = @TA)
    INSERT INTO Tools.ToolCavity (ToolId, CavityCode, StatusCodeId, Description, ItemId, CreatedByUserId)
    VALUES (@TA, N'a', @CavAct, N'Single Aa', @IA, @User);

IF NOT EXISTS (SELECT 1 FROM Tools.ToolCavity WHERE ToolId = @TB)
    INSERT INTO Tools.ToolCavity (ToolId, CavityCode, StatusCodeId, Description, ItemId, CreatedByUserId)
    VALUES (@TB, N'a', @CavAct, N'Intake 1 Aa',  @IB, @User),
           (@TB, N'b', @CavAct, N'Intake 2 Ab',  @IB, @User),
           (@TB, N'c', @CavAct, N'Exhaust 1 Ba', @IB, @User),
           (@TB, N'd', @CavAct, N'Exhaust 2 Bb', @IB, @User);

IF NOT EXISTS (SELECT 1 FROM Tools.ToolCavity WHERE ToolId = @TC)
    INSERT INTO Tools.ToolCavity (ToolId, CavityCode, StatusCodeId, Description, ItemId, CreatedByUserId)
    VALUES (@TC, N'a', @CavAct, N'Intake 1 Aa',  @IC, @User),
           (@TC, N'b', @CavAct, N'Intake 2 Ab',  @IC, @User),
           (@TC, N'c', @CavAct, N'Exhaust 1 Ba', @IC, @User),
           (@TC, N'd', @CavAct, N'Exhaust 2 Bb', @IC, @User);

-- ---------- mount each die on its idle machine ----------
IF NOT EXISTS (SELECT 1 FROM Tools.ToolAssignment WHERE ToolId = @TA AND ReleasedAt IS NULL)
    INSERT INTO Tools.ToolAssignment (ToolId, CellLocationId, AssignedAt, AssignedByUserId)
    VALUES (@TA, @MA, SYSUTCDATETIME(), @User);
IF NOT EXISTS (SELECT 1 FROM Tools.ToolAssignment WHERE ToolId = @TB AND ReleasedAt IS NULL)
    INSERT INTO Tools.ToolAssignment (ToolId, CellLocationId, AssignedAt, AssignedByUserId)
    VALUES (@TB, @MB, SYSUTCDATETIME(), @User);
IF NOT EXISTS (SELECT 1 FROM Tools.ToolAssignment WHERE ToolId = @TC AND ReleasedAt IS NULL)
    INSERT INTO Tools.ToolAssignment (ToolId, CellLocationId, AssignedAt, AssignedByUserId)
    VALUES (@TC, @MC, SYSUTCDATETIME(), @User);

-- ---------- eligibility so the parts show on the die cast dropdowns ----------
INSERT INTO Parts.ItemLocation (ItemId, LocationId)
SELECT v.i, v.l FROM (VALUES (@IA,@MA),(@IB,@MB),(@IC,@MC)) v(i,l)
WHERE NOT EXISTS (SELECT 1 FROM Parts.ItemLocation il WHERE il.ItemId = v.i AND il.LocationId = v.l);

-- ---------- published route per review part ----------
-- Mirrors sql/seeds/029_seed_item_routes.sql: insert the template already
-- published and resolve each step's OperationTemplate by ROLE. Casting chain
-- is the same shape as 12231-59B-0000 so these parts behave like real ones.
INSERT INTO Parts.RouteTemplate (ItemId, VersionNumber, Name, EffectiveFrom, PublishedAt, CreatedByUserId, CreatedAt)
SELECT v.i, 1, N'Review book route', '2026-01-15', '2026-01-14', @User, SYSUTCDATETIME()
FROM (VALUES (@IA),(@IB),(@IC)) v(i)
WHERE NOT EXISTS (SELECT 1 FROM Parts.RouteTemplate rt WHERE rt.ItemId = v.i AND rt.VersionNumber = 1);

DECLARE @Steps TABLE (ItemId BIGINT, Seq INT, Role NVARCHAR(30), Descr NVARCHAR(100));
INSERT INTO @Steps (ItemId, Seq, Role, Descr)
SELECT v.i, s.Seq, s.Role, s.Descr
FROM (VALUES (@IA),(@IB),(@IC)) v(i)
CROSS JOIN (VALUES (1,N'DieCast',N'Die cast'),(2,N'TrimIn',N'Trim in'),(3,N'TrimOut',N'Trim out'),
                   (4,N'MachiningIn',N'Machining in'),(5,N'AssemblyOut',N'Assembly out')) s(Seq,Role,Descr);

INSERT INTO Parts.RouteStep (RouteTemplateId, OperationTemplateId, SequenceNumber, IsRequired, Description)
SELECT rt.Id, op.Id, st.Seq, 1, st.Descr
FROM @Steps st
JOIN Parts.RouteTemplate rt ON rt.ItemId = st.ItemId AND rt.VersionNumber = 1
CROSS APPLY (SELECT TOP 1 o.Id FROM Parts.OperationTemplate o
             JOIN Parts.OperationType oty ON oty.Id = o.OperationTypeId
             WHERE oty.Code = st.Role AND o.DeprecatedAt IS NULL ORDER BY o.Id) op
WHERE NOT EXISTS (SELECT 1 FROM Parts.RouteStep x WHERE x.RouteTemplateId = rt.Id AND x.SequenceNumber = st.Seq);

-- ---------- open the starting baskets, through the real proc ----------
DECLARE @R TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
DECLARE @Cav BIGINT, @n INT;

-- A: one basket on the single cavity
SELECT @Cav = Id FROM Tools.ToolCavity WHERE ToolId = @TA AND CavityCode = N'a';
IF NOT EXISTS (SELECT 1 FROM Lots.Lot l JOIN Lots.LotStatusCode s ON s.Id=l.LotStatusId AND s.Code='Open' WHERE l.ToolId=@TA)
    INSERT INTO @R EXEC Lots.DieCastLot_Open @ItemId=@IA, @CurrentLocationId=@MA, @ToolId=@TA,
        @ToolCavityId=@Cav, @LotName=N'91000001', @AppUserId=@User, @TerminalLocationId=@Term;

-- B: four baskets
SET @n = 1;
WHILE @n <= 4
BEGIN
    SELECT @Cav = Id FROM Tools.ToolCavity WHERE ToolId = @TB AND CavityCode = NCHAR(96 + @n);   -- 1..4 -> a..d
    IF NOT EXISTS (SELECT 1 FROM Lots.Lot l JOIN Lots.LotStatusCode s ON s.Id=l.LotStatusId AND s.Code='Open'
                   WHERE l.ToolCavityId=@Cav)
    BEGIN
        DECLARE @nb NVARCHAR(20) = CAST(91000100 + @n AS NVARCHAR(20));
        INSERT INTO @R EXEC Lots.DieCastLot_Open @ItemId=@IB, @CurrentLocationId=@MB, @ToolId=@TB,
            @ToolCavityId=@Cav, @LotName=@nb, @AppUserId=@User, @TerminalLocationId=@Term;
    END
    SET @n = @n + 1;
END

-- C: four baskets
SET @n = 1;
WHILE @n <= 4
BEGIN
    SELECT @Cav = Id FROM Tools.ToolCavity WHERE ToolId = @TC AND CavityCode = NCHAR(96 + @n);   -- 1..4 -> a..d
    IF NOT EXISTS (SELECT 1 FROM Lots.Lot l JOIN Lots.LotStatusCode s ON s.Id=l.LotStatusId AND s.Code='Open'
                   WHERE l.ToolCavityId=@Cav)
    BEGIN
        DECLARE @nc NVARCHAR(20) = CAST(91000200 + @n AS NVARCHAR(20));
        INSERT INTO @R EXEC Lots.DieCastLot_Open @ItemId=@IC, @CurrentLocationId=@MC, @ToolId=@TC,
            @ToolCavityId=@Cav, @LotName=@nc, @AppUserId=@User, @TerminalLocationId=@Term;
    END
    SET @n = @n + 1;
END

SELECT Status, Message FROM @R;
SELECT t.Code AS Die, loc.Name AS Machine, COUNT(l.Id) AS OpenBaskets
FROM Tools.Tool t
JOIN Tools.ToolAssignment a ON a.ToolId=t.Id AND a.ReleasedAt IS NULL
JOIN Location.Location loc ON loc.Id=a.CellLocationId
LEFT JOIN Lots.Lot l ON l.ToolId=t.Id
LEFT JOIN Lots.LotStatusCode s ON s.Id=l.LotStatusId AND s.Code='Open'
WHERE t.Code LIKE 'RB-%'
GROUP BY t.Code, loc.Name ORDER BY t.Code;
