-- ============================================================
-- Seed:        050_demo_scenario.sql   (MPP_MES_Demo ONLY)
-- Description: One shift of production history for the sales-kit captures, created only
--              through the application's procs (the same ones the screens call):
--                Press 1 (D-210, HSG-410 a/b, 48/basket): three rounds of baskets released,
--                  a fourth filling. Round 1-2 trimmed to the housing line; a1, b1, a2 picked
--                  at Machining IN and minted into 16-piece machined housings (a2 part-way:
--                  32 of 48 left); b2 waits at Machining IN; round 3 waits at trim.
--                Press 3 (D-240, HSG-440): cavity a released once and refilling, cavity b
--                  never gets a basket (pending shots); a1 waits at Machining IN.
--                Press 2 (D-220 family die): one round released, trimmed to the cover line,
--                  picked; a second round filling, recorded at shift end with one scrap
--                  line and one piece not accounted for (a visible variance).
--                Housing line: two seal-kit boxes checked in; nine FG-4100 trays -> two full
--                  containers completed and one tray in the open box; 12 seal kits left
--                  (one tray from the low-inventory lock).
--                Cover line: two FG-2200 trays in an open box.
--              Every call checks its status row and stops the script on failure. ASCII-only.
-- ============================================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
SET QUOTED_IDENTIFIER ON;

DECLARE @JK BIGINT = (SELECT Id FROM Location.AppUser WHERE Pin = N'04218');
DECLARE @AM BIGINT = (SELECT Id FROM Location.AppUser WHERE Pin = N'40218');
DECLARE @TN BIGINT = (SELECT Id FROM Location.AppUser WHERE Pin = N'31570');
DECLARE @LB BIGINT = (SELECT Id FROM Location.AppUser WHERE Pin = N'02693');
DECLARE @Shift BIGINT = (SELECT TOP 1 Id FROM Oee.Shift WHERE ActualEnd IS NULL ORDER BY Id DESC);
DECLARE @L BIGINT;
DECLARE @DC BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'DC');
DECLARE @DCT BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'DC-T1');
DECLARE @TRIM BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'TRIM');
DECLARE @TRIMT BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'TRIM-T1');
DECLARE @L1 BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'L-1');
DECLARE @L2 BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'L-2');
DECLARE @L1MIN BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'L1-MIN');
DECLARE @L1MOUT BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'L1-MOUT');
DECLARE @L1AOUT BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'L1-AOUT');
DECLARE @L2MIN BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'L2-MIN');
DECLARE @L2AOUT BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'L2-AOUT');
DECLARE @OtTrimIn BIGINT = (SELECT Id FROM Parts.OperationTemplate WHERE Code = N'TrimIn');
DECLARE @OtTrimOut BIGINT = (SELECT Id FROM Parts.OperationTemplate WHERE Code = N'TrimOut');
DECLARE @OtMachOut BIGINT = (SELECT Id FROM Parts.OperationTemplate WHERE Code = N'MachiningOut');
DECLARE @Received BIGINT = (SELECT Id FROM Lots.LotOriginType WHERE Code = N'Received');
DECLARE @Porosity BIGINT = (SELECT Id FROM Quality.DefectCode WHERE Code = N'DC-POR');
IF @Shift IS NULL RAISERROR('050_demo_scenario: no open shift', 16, 1);

DECLARE @r2 TABLE (Status BIT, Message NVARCHAR(500));
DECLARE @r3 TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
DECLARE @rMint TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT, Available INT);
DECLARE @rLot TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT, MintedLotName NVARCHAR(50));
DECLARE @rTray TABLE (Status BIT, Message NVARCHAR(500), FinishedGoodLotId BIGINT, ContainerId BIGINT, ContainerTrayId BIGINT, ContainerFull BIT, TraysPerContainer INT);
DECLARE @rDone TABLE (Status BIT, Message NVARCHAR(500), ShippingLabelId BIGINT, AimShipperId NVARCHAR(50));
DECLARE @msg NVARCHAR(600), @lot BIGINT, @i INT, @n INT, @json NVARCHAR(MAX);

-- ======================================================================================
-- Die cast: open baskets, release at counter readings, record shift-end output.
-- ======================================================================================
-- Baskets in the order they are opened: (press, die, part, cavity, ticket, release reading or NULL)
DECLARE @Bk TABLE (Seq INT IDENTITY, Press NVARCHAR(10), Die NVARCHAR(10), Pn NVARCHAR(20), Cav NVARCHAR(4), Ltt NVARCHAR(9), ReleaseAt INT NULL);
INSERT INTO @Bk (Press, Die, Pn, Cav, Ltt, ReleaseAt) VALUES
    (N'P-01', N'D-210', N'HSG-410', N'a', N'520100001', 48),  (N'P-01', N'D-210', N'HSG-410', N'b', N'520100002', 48),
    (N'P-01', N'D-210', N'HSG-410', N'a', N'520100003', 96),  (N'P-01', N'D-210', N'HSG-410', N'b', N'520100004', 96),
    (N'P-01', N'D-210', N'HSG-410', N'a', N'520100005', 144), (N'P-01', N'D-210', N'HSG-410', N'b', N'520100006', 144),
    (N'P-01', N'D-210', N'HSG-410', N'a', N'520100007', NULL),(N'P-01', N'D-210', N'HSG-410', N'b', N'520100008', NULL),
    (N'P-02', N'D-220', N'CVR-220', N'a', N'520200001', 60),  (N'P-02', N'D-220', N'CVR-220', N'b', N'520200002', 60),
    (N'P-02', N'D-220', N'BRK-230', N'a', N'520200003', 60),  (N'P-02', N'D-220', N'BRK-230', N'b', N'520200004', 60),
    (N'P-02', N'D-220', N'CVR-220', N'a', N'520200005', NULL),(N'P-02', N'D-220', N'CVR-220', N'b', N'520200006', NULL),
    (N'P-02', N'D-220', N'BRK-230', N'a', N'520200007', NULL),(N'P-02', N'D-220', N'BRK-230', N'b', N'520200008', NULL),
    (N'P-03', N'D-240', N'HSG-440', N'a', N'520300001', 40),  (N'P-03', N'D-240', N'HSG-440', N'a', N'520300002', NULL);

DECLARE @press NVARCHAR(10), @die NVARCHAR(10), @pn NVARCHAR(20), @cav NVARCHAR(4), @ltt NVARCHAR(9), @relAt INT;
DECLARE @pressId BIGINT, @toolId BIGINT, @cavId BIGINT, @itemId BIGINT;
SET @i = 1; SET @n = (SELECT COUNT(*) FROM @Bk);
WHILE @i <= @n
BEGIN
    SELECT @press = Press, @die = Die, @pn = Pn, @cav = Cav, @ltt = Ltt, @relAt = ReleaseAt FROM @Bk WHERE Seq = @i;
    SET @pressId = (SELECT Id FROM Location.Location WHERE Code = @press);
    SET @toolId = (SELECT Id FROM Tools.Tool WHERE Code = @die);
    SET @itemId = (SELECT Id FROM Parts.Item WHERE PartNumber = @pn);
    SET @cavId = (SELECT Id FROM Tools.ToolCavity WHERE ToolId = @toolId AND ItemId = @itemId AND CavityCode = @cav);
    DELETE @r3;
    INSERT INTO @r3 EXEC Lots.DieCastLot_Open @ItemId = @itemId, @CurrentLocationId = @pressId, @ToolId = @toolId,
        @ToolCavityId = @cavId, @LotName = @ltt, @AppUserId = @JK, @TerminalLocationId = @DCT;
    IF NOT EXISTS (SELECT 1 FROM @r3 WHERE Status = 1) BEGIN SELECT @msg = N'open ' + @ltt + N': ' + Message FROM @r3; THROW 51000, @msg, 1; END
    IF @relAt IS NOT NULL
    BEGIN
        SET @lot = (SELECT NewId FROM @r3);
        DELETE @r3;
        INSERT INTO @r3 EXEC Lots.DieCastLot_Release @LotId = @lot, @CounterReading = @relAt, @ShiftId = @Shift,
            @AppUserId = @JK, @TerminalLocationId = @DCT, @CellLocationId = @pressId;
        IF NOT EXISTS (SELECT 1 FROM @r3 WHERE Status = 1) BEGIN SELECT @msg = N'release ' + @ltt + N': ' + Message FROM @r3; THROW 51000, @msg, 1; END
    END
    SET @i += 1;
END

-- Shift-end entries on the baskets still filling. Press 2 carries one scrap line and is
-- typed one piece short on BRK-230 b: net shots 45 = good 44 + scrap 0 + 1 unaccounted.
DECLARE @Out TABLE (Seq INT IDENTITY, Press NVARCHAR(10), Die NVARCHAR(10), Reading INT);
INSERT INTO @Out (Press, Die, Reading) VALUES (N'P-01', N'D-210', 170), (N'P-02', N'D-220', 105), (N'P-03', N'D-240', 55);
DECLARE @reading INT;
SET @i = 1;
WHILE @i <= 3
BEGIN
    SELECT @press = Press, @die = Die, @reading = Reading FROM @Out WHERE Seq = @i;
    SET @pressId = (SELECT Id FROM Location.Location WHERE Code = @press);
    SET @toolId = (SELECT Id FROM Tools.Tool WHERE Code = @die);
    SET @json = (
        SELECT l.Id AS lotId,
               CASE WHEN l.LotName = N'520200007' THEN 44 WHEN l.LotName = N'520200008' THEN 44
                    WHEN @press = N'P-01' THEN 26 WHEN @press = N'P-02' THEN 45 ELSE 15 END AS pieceDelta,
               JSON_QUERY(CASE WHEN l.LotName = N'520200007'
                    THEN N'[{"defectCodeId":' + CAST(@Porosity AS NVARCHAR(20)) + N',"quantity":1}]' ELSE N'[]' END) AS scrapLines
        FROM Lots.Lot l JOIN Lots.LotStatusCode s ON s.Id = l.LotStatusId
        WHERE l.ToolId = @toolId AND s.Code = N'Open'
        ORDER BY l.Id FOR JSON PATH);
    DELETE @r3;
    INSERT INTO @r3 EXEC Workorder.DieCastShiftOutput_Record @ShiftId = @Shift, @ToolId = @toolId, @LinesJson = @json,
        @AppUserId = @JK, @TerminalLocationId = @DCT, @CounterReading = @reading, @CellLocationId = @pressId;
    IF NOT EXISTS (SELECT 1 FROM @r3 WHERE Status = 1) BEGIN SELECT @msg = N'shift output ' + @press + N': ' + Message FROM @r3; THROW 51000, @msg, 1; END
    SET @i += 1;
END

-- ======================================================================================
-- Trim: check baskets in (TrimIn) and out to their line (TrimOut deposits into the line's
-- FIFO queue). Round 3 of press 1 stays waiting at trim.
-- ======================================================================================
DECLARE @Tr TABLE (Seq INT IDENTITY, Ltt NVARCHAR(9), Line NVARCHAR(10), CheckOut BIT);
INSERT INTO @Tr (Ltt, Line, CheckOut) VALUES
    (N'520100001', N'L-1', 1), (N'520100002', N'L-1', 1), (N'520100003', N'L-1', 1), (N'520100004', N'L-1', 1),
    (N'520200001', N'L-2', 1), (N'520200002', N'L-2', 1), (N'520200003', N'L-2', 1), (N'520200004', N'L-2', 1),
    (N'520300001', N'L-1', 1),
    (N'520100005', NULL, 0), (N'520100006', NULL, 0);
DECLARE @line NVARCHAR(10), @co BIT, @lineId BIGINT, @pcs INT;
SET @i = 1; SET @n = (SELECT COUNT(*) FROM @Tr);
WHILE @i <= @n
BEGIN
    SELECT @ltt = Ltt, @line = Line, @co = CheckOut FROM @Tr WHERE Seq = @i;
    SELECT @lot = Id, @pcs = PieceCount FROM Lots.Lot WHERE LotName = @ltt;
    DELETE @r2;
    INSERT INTO @r2 EXEC Lots.Lot_MoveToValidated @LotId = @lot, @ToLocationId = @TRIM, @AppUserId = @AM,
        @TerminalLocationId = @TRIMT, @OperationTypeCode = N'TrimIn';
    IF NOT EXISTS (SELECT 1 FROM @r2 WHERE Status = 1) BEGIN SELECT @msg = N'trim in ' + @ltt + N': ' + Message FROM @r2; THROW 51000, @msg, 1; END
    -- the Trim IN screen also records the TrimIn checkpoint that advances the route
    DELETE @r3;
    INSERT INTO @r3 EXEC Workorder.ProductionEvent_Record @LotId = @lot, @OperationTemplateId = @OtTrimIn, @ShotCount = @pcs,
        @AppUserId = @AM, @TerminalLocationId = @TRIMT;
    IF NOT EXISTS (SELECT 1 FROM @r3 WHERE Status = 1) BEGIN SELECT @msg = N'trim in event ' + @ltt + N': ' + Message FROM @r3; THROW 51000, @msg, 1; END
    IF @co = 1
    BEGIN
        SET @lineId = (SELECT Id FROM Location.Location WHERE Code = @line);
        DELETE @r3;
        INSERT INTO @r3 EXEC Workorder.TrimOut_Record @ParentLotId = @lot, @OperationTemplateId = @OtTrimOut, @ShotCount = @pcs,
            @DestinationCellLocationId = @lineId, @SourceLocationId = @TRIM, @AppUserId = @AM, @TerminalLocationId = @TRIMT;
        IF NOT EXISTS (SELECT 1 FROM @r3 WHERE Status = 1) BEGIN SELECT @msg = N'trim out ' + @ltt + N': ' + Message FROM @r3; THROW 51000, @msg, 1; END
    END
    SET @i += 1;
END

-- ======================================================================================
-- Machining IN picks, oldest first. Housing line: 520100001, 520100002, 520100003
-- (520100004 and 520300001 stay waiting). Cover line: all four castings.
-- ======================================================================================
DECLARE @Pk TABLE (Seq INT IDENTITY, Ltt NVARCHAR(9), Line NVARCHAR(10));
INSERT INTO @Pk (Ltt, Line) VALUES
    (N'520100001', N'L-1'), (N'520100002', N'L-1'), (N'520100003', N'L-1'),
    (N'520200001', N'L-2'), (N'520200002', N'L-2'), (N'520200003', N'L-2'), (N'520200004', N'L-2');
DECLARE @term BIGINT;
SET @i = 1; SET @n = (SELECT COUNT(*) FROM @Pk);
WHILE @i <= @n
BEGIN
    SELECT @ltt = Ltt, @line = Line FROM @Pk WHERE Seq = @i;
    SET @lot = (SELECT Id FROM Lots.Lot WHERE LotName = @ltt);
    SET @lineId = (SELECT Id FROM Location.Location WHERE Code = @line);
    SET @term = CASE @line WHEN N'L-1' THEN @L1MIN ELSE @L2MIN END;
    DELETE @r3;
    INSERT INTO @r3 EXEC Workorder.MachiningIn_RecordPick @LotId = @lot, @LineLocationId = @lineId, @AppUserId = @TN, @TerminalLocationId = @term;
    IF NOT EXISTS (SELECT 1 FROM @r3 WHERE Status = 1) BEGIN SELECT @msg = N'machining in ' + @ltt + N': ' + Message FROM @r3; THROW 51000, @msg, 1; END
    SET @i += 1;
END

-- ======================================================================================
-- Machining OUT: 16-piece machined housings minted from the castings (Consumption genealogy).
-- 520100001 x3, 520100002 x3, 520100003 x1 -> 520100003 is left at 32 of 48.
-- ======================================================================================
DECLARE @Mt TABLE (Seq INT IDENTITY, Ltt NVARCHAR(9));
INSERT INTO @Mt (Ltt) VALUES (N'520100001'), (N'520100001'), (N'520100001'), (N'520100002'), (N'520100002'), (N'520100002'), (N'520100003');
SET @i = 1; SET @n = (SELECT COUNT(*) FROM @Mt);
WHILE @i <= @n
BEGIN
    SELECT @ltt = Ltt FROM @Mt WHERE Seq = @i;
    SET @lot = (SELECT Id FROM Lots.Lot WHERE LotName = @ltt);
    DELETE @rMint;
    INSERT INTO @rMint EXEC Workorder.MachiningOut_Mint @SourceLotId = @lot, @OperationTemplateId = @OtMachOut, @PieceCount = 16,
        @AppUserId = @TN, @TerminalLocationId = @L1MOUT;
    IF NOT EXISTS (SELECT 1 FROM @rMint WHERE Status = 1) BEGIN SELECT @msg = N'mint from ' + @ltt + N': ' + Message FROM @rMint; THROW 51000, @msg, 1; END
    SET @i += 1;
END

-- ======================================================================================
-- Purchased seal kits checked in at the housing line (two boxes, by supplier lot).
-- ======================================================================================
DECLARE @Seal BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'SEAL-01');
DELETE @rLot;
INSERT INTO @rLot EXEC Lots.Lot_Create @ItemId = @Seal, @LotOriginTypeId = @Received, @CurrentLocationId = @L1, @PieceCount = 100,
    @VendorLotNumber = N'SUP-1099', @AppUserId = @LB, @TerminalLocationId = @L1AOUT;
IF NOT EXISTS (SELECT 1 FROM @rLot WHERE Status = 1) BEGIN SELECT @msg = N'seal box 1: ' + Message FROM @rLot; THROW 51000, @msg, 1; END
DELETE @rLot;
INSERT INTO @rLot EXEC Lots.Lot_Create @ItemId = @Seal, @LotOriginTypeId = @Received, @CurrentLocationId = @L1, @PieceCount = 20,
    @VendorLotNumber = N'SUP-1102', @AppUserId = @LB, @TerminalLocationId = @L1AOUT;
IF NOT EXISTS (SELECT 1 FROM @rLot WHERE Status = 1) BEGIN SELECT @msg = N'seal box 2: ' + Message FROM @rLot; THROW 51000, @msg, 1; END

-- ======================================================================================
-- Assembly OUT: 9 housing trays (two full containers completed + one tray in the open box),
-- 2 cover trays in an open box.
-- ======================================================================================
DECLARE @Asm TABLE (Seq INT IDENTITY, Fg NVARCHAR(20), Line NVARCHAR(10), Pcs INT);
INSERT INTO @Asm (Fg, Line, Pcs) VALUES
    (N'FG-4100', N'L-1', 12), (N'FG-4100', N'L-1', 12), (N'FG-4100', N'L-1', 12), (N'FG-4100', N'L-1', 12),
    (N'FG-4100', N'L-1', 12), (N'FG-4100', N'L-1', 12), (N'FG-4100', N'L-1', 12), (N'FG-4100', N'L-1', 12),
    (N'FG-4100', N'L-1', 12),
    (N'FG-2200', N'L-2', 24), (N'FG-2200', N'L-2', 24);
DECLARE @fg NVARCHAR(20), @fgId BIGINT, @full BIT, @cont BIGINT;
SET @i = 1; SET @n = (SELECT COUNT(*) FROM @Asm);
WHILE @i <= @n
BEGIN
    SELECT @fg = Fg, @line = Line, @pcs = Pcs FROM @Asm WHERE Seq = @i;
    SET @fgId = (SELECT Id FROM Parts.Item WHERE PartNumber = @fg);
    SET @lineId = (SELECT Id FROM Location.Location WHERE Code = @line);
    SET @term = CASE @line WHEN N'L-1' THEN @L1AOUT ELSE @L2AOUT END;
    DELETE @rTray;
    INSERT INTO @rTray EXEC Workorder.Assembly_CompleteTray @FinishedGoodItemId = @fgId, @PieceCount = @pcs, @CellLocationId = @lineId,
        @ClosureMethod = N'ByCount', @AppUserId = @LB, @TerminalLocationId = @term;
    IF NOT EXISTS (SELECT 1 FROM @rTray WHERE Status = 1) BEGIN SELECT @msg = N'tray ' + CAST(@i AS NVARCHAR(5)) + N' ' + @fg + N': ' + Message FROM @rTray; THROW 51000, @msg, 1; END
    SELECT @full = ContainerFull, @cont = ContainerId FROM @rTray;
    IF @full = 1
    BEGIN
        DELETE @rDone;
        INSERT INTO @rDone EXEC Lots.Container_Complete @ContainerId = @cont, @OperatorConfirmed = 1, @AppUserId = @LB, @TerminalLocationId = @term;
        IF NOT EXISTS (SELECT 1 FROM @rDone WHERE Status = 1) BEGIN SELECT @msg = N'complete container: ' + Message FROM @rDone; THROW 51000, @msg, 1; END
    END
    SET @i += 1;
END
