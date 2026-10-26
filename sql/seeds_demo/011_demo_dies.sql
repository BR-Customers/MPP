-- ============================================================
-- Seed:        011_demo_dies.sql   (MPP_MES_Demo ONLY)
-- Description: Three dies with their cavities, each mounted on a press. D-220 is a family die:
--              a cavity letter only means something with its part (CVR-220 a/b, BRK-230 a/b).
--              Through Tools.Tool_Create / ToolCavity_Create / ToolAssignment_Assign. ASCII-only.
-- ============================================================
SET NOCOUNT ON;
SET XACT_ABORT ON;

DECLARE @Sys BIGINT = 1;
DECLARE @ttDie BIGINT = (SELECT Id FROM Tools.ToolType WHERE Code = N'Die');
DECLARE @scAct BIGINT = (SELECT Id FROM Tools.ToolStatusCode WHERE Code = N'Active');
DECLARE @r TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
DECLARE @msg NVARCHAR(500), @i INT, @code NVARCHAR(50), @name NVARCHAR(100), @tid BIGINT;

DECLARE @Tools TABLE (Seq INT IDENTITY, Code NVARCHAR(50), Name NVARCHAR(100));
INSERT INTO @Tools (Code, Name) VALUES (N'D-210', N'Housing die'), (N'D-220', N'Cover / bracket family die'), (N'D-240', N'Pump housing die');
SET @i = 1;
WHILE @i <= 3
BEGIN
    SELECT @code = Code, @name = Name FROM @Tools WHERE Seq = @i;
    IF NOT EXISTS (SELECT 1 FROM Tools.Tool WHERE Code = @code)
    BEGIN
        DELETE @r;
        INSERT INTO @r EXEC Tools.Tool_Create @ToolTypeId = @ttDie, @Code = @code, @Name = @name,
            @Description = NULL, @DieRankId = NULL, @StatusCodeId = @scAct, @AppUserId = @Sys;
        IF NOT EXISTS (SELECT 1 FROM @r WHERE Status = 1) BEGIN SELECT @msg = Message FROM @r; RAISERROR('Tool_Create %s: %s', 16, 1, @code, @msg); END
    END
    SET @i += 1;
END

DECLARE @Cav TABLE (Seq INT IDENTITY, ToolCode NVARCHAR(50), Pn NVARCHAR(50), CavCode NVARCHAR(4));
INSERT INTO @Cav (ToolCode, Pn, CavCode) VALUES
    (N'D-210', N'HSG-410', N'a'), (N'D-210', N'HSG-410', N'b'),
    (N'D-220', N'CVR-220', N'a'), (N'D-220', N'CVR-220', N'b'), (N'D-220', N'BRK-230', N'a'), (N'D-220', N'BRK-230', N'b'),
    (N'D-240', N'HSG-440', N'a'), (N'D-240', N'HSG-440', N'b');
DECLARE @pn NVARCHAR(50), @cc NVARCHAR(4), @iid BIGINT, @desc NVARCHAR(500);
SET @i = 1;
WHILE @i <= (SELECT COUNT(*) FROM @Cav)
BEGIN
    SELECT @code = ToolCode, @pn = Pn, @cc = CavCode FROM @Cav WHERE Seq = @i;
    SET @tid = (SELECT Id FROM Tools.Tool WHERE Code = @code);
    SET @iid = (SELECT Id FROM Parts.Item WHERE PartNumber = @pn);
    SET @desc = @pn + N' cavity ' + @cc;
    IF NOT EXISTS (SELECT 1 FROM Tools.ToolCavity WHERE ToolId = @tid AND ItemId = @iid AND CavityCode = @cc)
    BEGIN
        DELETE @r;
        INSERT INTO @r EXEC Tools.ToolCavity_Create @ToolId = @tid, @CavityCode = @cc, @Description = @desc, @ItemId = @iid, @AppUserId = @Sys;
        IF NOT EXISTS (SELECT 1 FROM @r WHERE Status = 1) BEGIN SELECT @msg = Message FROM @r; RAISERROR('ToolCavity_Create %s %s %s: %s', 16, 1, @code, @pn, @cc, @msg); END
    END
    SET @i += 1;
END

DECLARE @Mount TABLE (Seq INT IDENTITY, ToolCode NVARCHAR(50), Cell NVARCHAR(50));
INSERT INTO @Mount (ToolCode, Cell) VALUES (N'D-210', N'P-01'), (N'D-220', N'P-02'), (N'D-240', N'P-03');
DECLARE @cell NVARCHAR(50), @cid BIGINT;
SET @i = 1;
WHILE @i <= 3
BEGIN
    SELECT @code = ToolCode, @cell = Cell FROM @Mount WHERE Seq = @i;
    SET @tid = (SELECT Id FROM Tools.Tool WHERE Code = @code);
    SET @cid = (SELECT Id FROM Location.Location WHERE Code = @cell);
    IF NOT EXISTS (SELECT 1 FROM Tools.ToolAssignment WHERE (ToolId = @tid OR CellLocationId = @cid) AND ReleasedAt IS NULL)
    BEGIN
        DELETE @r;
        INSERT INTO @r EXEC Tools.ToolAssignment_Assign @ToolId = @tid, @CellLocationId = @cid, @Notes = NULL, @AppUserId = @Sys;
        IF NOT EXISTS (SELECT 1 FROM @r WHERE Status = 1) BEGIN SELECT @msg = Message FROM @r; RAISERROR('ToolAssignment_Assign %s -> %s: %s', 16, 1, @code, @cell, @msg); END
    END
    SET @i += 1;
END
