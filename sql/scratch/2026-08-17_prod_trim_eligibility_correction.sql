-- =============================================
-- 2026-08-17_prod_trim_eligibility_correction.sql
--
-- Purpose:
--   Re-point Trim Shop 1 / Trim Shop 2 part eligibility in MPP_MES_Prod to the
--   plant manager's changeover notes (4-20-26_DC_Changeover.xlsx thread).
--
--   TRIM 1 : 59B cam holders (whole family, In #1-#5 + Ex #1-#5)
--            RPY cam holders (In #1-#5, Ex #1-#6, Lower #1-#4)
--            RPY rocker shafts #1-#4
--            5G0 rocker shaft holders #1, #2, #3
--            6MA cam holders from the 2-4 die (Intake/Exhaust #2, #3, #4)
--   TRIM 2 : everything else that is trimmed
--   NO TRIM: 6MD manifold plate + every oil pan part except 6MA Oil Pan
--
-- Rules honoured:
--   * A part already eligible at BOTH shops is left untouched (the two shops
--     perform different functions; dual eligibility is legitimate).
--   * Idempotent - re-running only acts on rows not already in the target state.
--   * No outer transaction: Parts.ItemLocation_Add / _Remove each own their own
--     transaction + audit write, so every single change is atomic on its own and
--     a partial run is safe to resume.
--
-- Usage:
--   DryRun=1 (default) prints the plan and changes nothing. DryRun=0 executes.
--
--   sqlcmd -S <host> -U Ignition -d MPP_MES_Prod -I -C -b
--          -v DryRun=1 -i 2026-08-17_prod_trim_eligibility_correction.sql
-- =============================================
SET NOCOUNT ON;
SET XACT_ABORT ON;

DECLARE @DryRun    BIT    = TRY_CONVERT(BIT, N'$(DryRun)');
DECLARE @AppUserId BIGINT;

IF @DryRun IS NULL SET @DryRun = 1;

-- Attribute the change to the operator running it.
SELECT @AppUserId = Id FROM Location.AppUser WHERE AdAccount = N'admin1' AND DeprecatedAt IS NULL;
IF @AppUserId IS NULL
BEGIN
    RAISERROR(N'ABORT: could not resolve AppUser admin1.', 16, 1);
    RETURN;
END

DECLARE @Trim1Id BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'TRIM1' AND DeprecatedAt IS NULL);
DECLARE @Trim2Id BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'TRIM2' AND DeprecatedAt IS NULL);
IF @Trim1Id IS NULL OR @Trim2Id IS NULL
BEGIN
    RAISERROR(N'ABORT: TRIM1 / TRIM2 location not found.', 16, 1);
    RETURN;
END

-- ---------------------------------------------------------------
-- Target state: one row per part, naming the shop it belongs to.
-- ---------------------------------------------------------------
DECLARE @Target TABLE (PartNumber NVARCHAR(100) PRIMARY KEY, TargetCode NVARCHAR(10));

INSERT INTO @Target (PartNumber, TargetCode) VALUES
  -- TRIM 1 -- 59B cam holders, whole family
   (N'12231-59B-0000', N'TRIM1'), (N'12232-59B-0000', N'TRIM1'), (N'12233-59B-0000', N'TRIM1')
  ,(N'12234-59B-0000', N'TRIM1'), (N'12235-59B-0000', N'TRIM1'), (N'12241-59B-0000', N'TRIM1')
  ,(N'12242-59B-0000', N'TRIM1'), (N'12243-59B-0000', N'TRIM1'), (N'12244-59B-0000', N'TRIM1')
  ,(N'12245-59B-0000', N'TRIM1')
  -- TRIM 1 -- RPY cam holders: In #1-#5, Ex #1-#6, Lower #1-#4
  ,(N'12231-RPY -G000', N'TRIM1'), (N'12232-RPY -G000', N'TRIM1'), (N'12233-RPY -G000', N'TRIM1')
  ,(N'12234-RPY -G000', N'TRIM1'), (N'12235-RPY -G000', N'TRIM1')
  ,(N'12241-RPY -G000', N'TRIM1'), (N'12242-RPY -G000', N'TRIM1'), (N'12243-RPY -G000', N'TRIM1')
  ,(N'12244-RPY -G000', N'TRIM1'), (N'12245-RPY -G000', N'TRIM1'), (N'12246-RPY -G000', N'TRIM1')
  ,(N'12271-RPY -G000', N'TRIM1'), (N'12272-RPY -G000', N'TRIM1'), (N'12273-RPY -G000', N'TRIM1')
  ,(N'12274-RPY -G000', N'TRIM1')
  -- TRIM 1 -- RPY rocker shafts #1-#4 only
  ,(N'12261-RPY -G000', N'TRIM1'), (N'12262-RPY -G000', N'TRIM1'), (N'12263-RPY -G000', N'TRIM1')
  ,(N'12264-RPY -G000', N'TRIM1')
  -- TRIM 1 -- 5G0 rocker shaft holders #1, #2, #3
  ,(N'12231-5GO', N'TRIM1'), (N'12232-5GO', N'TRIM1'), (N'12233-5GO', N'TRIM1')
  -- TRIM 1 -- 6MA cam holders, 2-4 die only
  ,(N'12232-6MA -0000', N'TRIM1'), (N'12233-6MA -0000', N'TRIM1'), (N'12234-6MA -0000', N'TRIM1')
  ,(N'12242-6MA -0000', N'TRIM1'), (N'12243-6MA -0000', N'TRIM1'), (N'12244-6MA -0000', N'TRIM1')

  -- TRIM 2 -- 6MA cam holders, 1&5 die
  ,(N'12231-6MA -0000', N'TRIM2'), (N'12235-6MA -0000', N'TRIM2')
  ,(N'12241-6MA -0000', N'TRIM2'), (N'12245-6MA -0000', N'TRIM2')
  -- TRIM 2 -- RPY rocker shaft #5
  ,(N'12265-RPY -G000', N'TRIM2')
  -- TRIM 2 -- the one trimmed oil pan, plus other castings
  ,(N'11200-6MAA-J010', N'TRIM2'), (N'5G0-c', N'TRIM2')
  ,(N'12265-5BA -G000', N'TRIM2'), (N'12265-6B2 -A000', N'TRIM2')
  ,(N'12431-6FBA-A000', N'TRIM2'), (N'12235-6FBA-A000', N'TRIM2')
  ,(N'19311-6MAA-J011', N'TRIM2'), (N'19320-6MAA-J020', N'TRIM2')
  -- TRIM 2 -- fuel pumps
  ,(N'12270-5PAA', N'TRIM2'), (N'12270-66VA', N'TRIM2'), (N'12270-6B2A', N'TRIM2')
  ,(N'12270-6NA',  N'TRIM2'), (N'12270-6NAA', N'TRIM2'), (N'12270-6VJA', N'TRIM2')
  ,(N'12270-RPYA', N'TRIM2')
  -- TRIM 2 -- 5G0 shafts (assembly components; "everything else" per the notes)
  ,(N'146315GO A000', N'TRIM2'), (N'146325GO A000', N'TRIM2')
  ,(N'146335GO A000', N'TRIM2'), (N'146345GO A000', N'TRIM2')

  -- NO TRIM -- manifold plate + every oil pan part except 6MA Oil Pan
  ,(N'17145-6MDA',     N'NONE'), (N'11200-5J6-A000', N'NONE'), (N'1120A-64AA', N'NONE')
  ,(N'11200-6FB-A000', N'NONE'), (N'11221-64AA-A010', N'NONE'), (N'11222-64A-A001', N'NONE');

-- ---------------------------------------------------------------
-- Guard: every targeted part number must resolve to exactly one live Item.
-- ---------------------------------------------------------------
IF EXISTS (
    SELECT 1 FROM @Target t
    WHERE (SELECT COUNT(*) FROM Parts.Item i
           WHERE i.PartNumber = t.PartNumber AND i.DeprecatedAt IS NULL) <> 1)
BEGIN
    SELECT t.PartNumber,
           (SELECT COUNT(*) FROM Parts.Item i
            WHERE i.PartNumber = t.PartNumber AND i.DeprecatedAt IS NULL) AS LiveItemCount
    FROM @Target t
    WHERE (SELECT COUNT(*) FROM Parts.Item i
           WHERE i.PartNumber = t.PartNumber AND i.DeprecatedAt IS NULL) <> 1;
    RAISERROR(N'ABORT: one or more target part numbers did not resolve to exactly one live Item.', 16, 1);
    RETURN;
END

-- ---------------------------------------------------------------
-- Build the work list.
-- ---------------------------------------------------------------
DECLARE @Work TABLE (
    Seq          INT IDENTITY(1,1) PRIMARY KEY,
    ItemId       BIGINT,
    PartNumber   NVARCHAR(100),
    Descr        NVARCHAR(200),
    Action       NVARCHAR(10),   -- ADD | REMOVE
    LocationId   BIGINT,
    LocationCode NVARCHAR(10)
);

;WITH item AS (
    SELECT i.Id AS ItemId, i.PartNumber, ISNULL(i.Description, N'') AS Descr, t.TargetCode
    FROM @Target t
    JOIN Parts.Item i ON i.PartNumber = t.PartNumber AND i.DeprecatedAt IS NULL
),
liveTrim AS (
    SELECT il.ItemId, il.LocationId, l.Code
    FROM Parts.ItemLocation il
    JOIN Location.Location l ON l.Id = il.LocationId
    WHERE il.DeprecatedAt IS NULL AND l.Code IN (N'TRIM1', N'TRIM2')
),
-- A part live at BOTH shops is intentional; exclude it from all work.
dual AS (
    SELECT ItemId FROM liveTrim GROUP BY ItemId HAVING COUNT(*) > 1
)
INSERT INTO @Work (ItemId, PartNumber, Descr, Action, LocationId, LocationCode)
-- (a) grant eligibility at the target shop where it is missing
SELECT it.ItemId, it.PartNumber, it.Descr, N'ADD',
       CASE it.TargetCode WHEN N'TRIM1' THEN @Trim1Id ELSE @Trim2Id END, it.TargetCode
FROM item it
WHERE it.TargetCode <> N'NONE'
  AND it.ItemId NOT IN (SELECT ItemId FROM dual)
  AND NOT EXISTS (SELECT 1 FROM liveTrim lt WHERE lt.ItemId = it.ItemId AND lt.Code = it.TargetCode)
UNION ALL
-- (b) revoke eligibility anywhere it does not belong
SELECT it.ItemId, it.PartNumber, it.Descr, N'REMOVE', lt.LocationId, lt.Code
FROM item it
JOIN liveTrim lt ON lt.ItemId = it.ItemId
WHERE it.ItemId NOT IN (SELECT ItemId FROM dual)
  AND lt.Code <> it.TargetCode;

-- ---------------------------------------------------------------
-- Plan
-- ---------------------------------------------------------------
PRINT N'--------------------------------------------------------';
PRINT N'  TRIM ELIGIBILITY CORRECTION   DryRun=' + CONVERT(NVARCHAR(1), @DryRun);
DECLARE @PlanCount INT = (SELECT COUNT(*) FROM @Work);
PRINT N'  Planned changes: ' + CONVERT(NVARCHAR(10), @PlanCount);
PRINT N'--------------------------------------------------------';

SELECT Seq, Action, LocationCode, PartNumber, Descr
FROM @Work ORDER BY Action DESC, LocationCode, Descr;

SELECT i.PartNumber, ISNULL(i.Description, N'') AS Descr, N'left at both shops' AS Note
FROM Parts.Item i
WHERE i.Id IN (
    SELECT il.ItemId FROM Parts.ItemLocation il
    JOIN Location.Location l ON l.Id = il.LocationId
    WHERE il.DeprecatedAt IS NULL AND l.Code IN (N'TRIM1', N'TRIM2')
    GROUP BY il.ItemId HAVING COUNT(*) > 1);

IF @DryRun = 1
BEGIN
    PRINT N'DRY RUN - nothing was changed. Re-run with -v DryRun=0 to apply.';
    RETURN;
END

-- ---------------------------------------------------------------
-- Apply. ADDs run before REMOVEs so no part is momentarily untrimmed.
-- ---------------------------------------------------------------
DECLARE @Seq INT, @ItemId BIGINT, @LocId BIGINT, @Action NVARCHAR(10),
        @Pn NVARCHAR(100), @LocCode NVARCHAR(10);
DECLARE @Applied INT = 0, @Failed INT = 0;
DECLARE @FailMsg NVARCHAR(500);
DECLARE @Ok      BIT;

-- Capture shapes must match each proc's result set EXACTLY. A column-count
-- mismatch throws inside the proc's own transaction, whose CATCH then issues a
-- ROLLBACK that is illegal under INSERT-EXEC (Msg 3915) -- so _Add (which also
-- returns NewId) gets its own three-column table.
DECLARE @ResultAdd TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
DECLARE @ResultRem TABLE (Status BIT, Message NVARCHAR(500));

DECLARE c CURSOR LOCAL FAST_FORWARD FOR
    SELECT Seq, ItemId, LocationId, Action, PartNumber, LocationCode
    FROM @Work ORDER BY CASE Action WHEN N'ADD' THEN 0 ELSE 1 END, Seq;

OPEN c;
FETCH NEXT FROM c INTO @Seq, @ItemId, @LocId, @Action, @Pn, @LocCode;
WHILE @@FETCH_STATUS = 0
BEGIN
    DELETE FROM @ResultAdd;
    DELETE FROM @ResultRem;
    SET @FailMsg = NULL;
    SET @Ok = 0;

    IF @Action = N'ADD'
    BEGIN
        INSERT INTO @ResultAdd (Status, Message, NewId)
        EXEC Parts.ItemLocation_Add
             @ItemId = @ItemId, @LocationId = @LocId,
             @MinQuantity = NULL, @MaxQuantity = NULL, @DefaultQuantity = NULL,
             @IsConsumptionPoint = 0, @AppUserId = @AppUserId;

        SELECT TOP 1 @Ok = Status, @FailMsg = Message FROM @ResultAdd;
    END
    ELSE
    BEGIN
        INSERT INTO @ResultRem (Status, Message)
        EXEC Parts.ItemLocation_Remove
             @ItemId = @ItemId, @LocationId = @LocId, @AppUserId = @AppUserId;

        SELECT TOP 1 @Ok = Status, @FailMsg = Message FROM @ResultRem;
    END

    IF @Ok = 1
        SET @Applied += 1;
    ELSE
    BEGIN
        SET @Failed += 1;
        PRINT N'  FAILED  ' + @Action + N' ' + @LocCode + N' ' + @Pn + N'  ->  '
              + ISNULL(@FailMsg, N'(no result row)');
    END

    FETCH NEXT FROM c INTO @Seq, @ItemId, @LocId, @Action, @Pn, @LocCode;
END
CLOSE c;
DEALLOCATE c;

PRINT N'--------------------------------------------------------';
PRINT N'  Applied: ' + CONVERT(NVARCHAR(10), @Applied) + N'   Failed: ' + CONVERT(NVARCHAR(10), @Failed);
PRINT N'--------------------------------------------------------';

-- ---------------------------------------------------------------
-- Verification: resulting counts, then any part still off-target.
-- ---------------------------------------------------------------
SELECT l.Code AS Shop, COUNT(*) AS Parts
FROM Parts.ItemLocation il
JOIN Location.Location l ON l.Id = il.LocationId
WHERE il.DeprecatedAt IS NULL AND l.Code IN (N'TRIM1', N'TRIM2')
GROUP BY l.Code ORDER BY l.Code;

;WITH actual AS (
    SELECT t.PartNumber, t.TargetCode,
           ISNULL(STUFF((SELECT N',' + l2.Code
                         FROM Parts.ItemLocation il2
                         JOIN Location.Location l2 ON l2.Id = il2.LocationId
                         JOIN Parts.Item i2 ON i2.Id = il2.ItemId
                         WHERE i2.PartNumber = t.PartNumber AND il2.DeprecatedAt IS NULL
                           AND l2.Code IN (N'TRIM1', N'TRIM2')
                         ORDER BY l2.Code FOR XML PATH(N'')), 1, 1, N''), N'NONE') AS ActualCode
    FROM @Target t
)
SELECT PartNumber, TargetCode AS Expected, ActualCode AS Actual
FROM actual WHERE ActualCode <> TargetCode ORDER BY PartNumber;
