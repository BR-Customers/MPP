-- ============================================================
-- Seed:        002_demo_people_shifts_codes.sql   (MPP_MES_Demo ONLY)
-- Description: Sample operators (the demo's PINs, leading zeros kept), two supervisors,
--              three shift schedules covering the day with the current shift opened by
--              Oee.Shift_Reconcile, and small demo defect and downtime code sets.
--              Everything goes through the application's procs. ASCII-only.
-- ============================================================
SET NOCOUNT ON;
SET XACT_ABORT ON;

DECLARE @Sys BIGINT = 1;   -- bootstrap SYS user (migration 0001)
DECLARE @r TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
DECLARE @msg NVARCHAR(500);

-- ---- people --------------------------------------------------------------------------------
DECLARE @People TABLE (Seq INT IDENTITY, Initials NVARCHAR(10), Name NVARCHAR(200), Pin NVARCHAR(5), Ad NVARCHAR(100) NULL, Role NVARCHAR(100) NULL);
INSERT INTO @People (Initials, Name, Pin, Ad, Role) VALUES
    (N'JK', N'J. Kowalski', N'04218', NULL, NULL),
    (N'AM', N'A. Mendez',   N'40218', NULL, NULL),
    (N'TN', N'T. Nguyen',   N'31570', NULL, NULL),
    (N'LB', N'L. Brooks',   N'02693', NULL, NULL),
    (N'DP', N'D. Patel',    N'58104', NULL, NULL),
    (N'SO', N'S. Okafor',   N'77342', NULL, NULL),
    (N'RS', N'R. Santos',   N'61010', N'rsantos', N'Supervisor'),
    (N'CW', N'C. Weber',    N'61020', N'cweber',  N'Supervisor');

DECLARE @i INT = 1, @ini NVARCHAR(10), @nm NVARCHAR(200), @pin NVARCHAR(5), @ad NVARCHAR(100), @role NVARCHAR(100);
WHILE @i <= (SELECT COUNT(*) FROM @People)
BEGIN
    SELECT @ini = Initials, @nm = Name, @pin = Pin, @ad = Ad, @role = Role FROM @People WHERE Seq = @i;
    IF NOT EXISTS (SELECT 1 FROM Location.AppUser WHERE Pin = @pin)
    BEGIN
        DELETE @r;
        INSERT INTO @r EXEC Location.AppUser_Create @Initials = @ini, @DisplayName = @nm, @Pin = @pin,
            @AdAccount = @ad, @IgnitionRole = @role, @AppUserId = @Sys;
        IF NOT EXISTS (SELECT 1 FROM @r WHERE Status = 1)
        BEGIN SELECT @msg = Message FROM @r; RAISERROR('AppUser_Create %s: %s', 16, 1, @ini, @msg); END
    END
    SET @i += 1;
END

-- ---- shifts ----------------------------------------------------------------------------------
DECLARE @Shifts TABLE (Seq INT IDENTITY, Name NVARCHAR(100), StartT TIME(0), EndT TIME(0));
INSERT INTO @Shifts (Name, StartT, EndT) VALUES
    (N'First Shift',  '06:00', '14:00'),
    (N'Second Shift', '14:00', '22:00'),
    (N'Third Shift',  '22:00', '06:00');
DECLARE @sn NVARCHAR(100), @st TIME(0), @et TIME(0);
SET @i = 1;
WHILE @i <= 3
BEGIN
    SELECT @sn = Name, @st = StartT, @et = EndT FROM @Shifts WHERE Seq = @i;
    IF NOT EXISTS (SELECT 1 FROM Oee.ShiftSchedule WHERE Name = @sn AND DeprecatedAt IS NULL)
    BEGIN
        DELETE @r;
        INSERT INTO @r EXEC Oee.ShiftSchedule_Create @Name = @sn, @StartTime = @st, @EndTime = @et,
            @DaysOfWeekBitmask = 127, @EffectiveFrom = '2026-01-01', @AppUserId = @Sys;
        IF NOT EXISTS (SELECT 1 FROM @r WHERE Status = 1)
        BEGIN SELECT @msg = Message FROM @r; RAISERROR('ShiftSchedule_Create %s: %s', 16, 1, @sn, @msg); END
    END
    SET @i += 1;
END

-- Open the current shift the way scratch/seed_shifts.sql does: an anchor two days back, then
-- Oee.Shift_Reconcile backfills to now and opens the shift in progress.
IF NOT EXISTS (SELECT 1 FROM Oee.Shift)
BEGIN
    DECLARE @First BIGINT = (SELECT Id FROM Oee.ShiftSchedule WHERE Name = N'First Shift' AND DeprecatedAt IS NULL);
    DECLARE @AnchorEnd DATETIME2(3) = DATEADD(HOUR, 14, CAST(DATEADD(DAY, -2, CAST(SYSDATETIME() AS DATE)) AS DATETIME2(3)));
    INSERT INTO Oee.Shift (ShiftScheduleId, ActualStart, ActualEnd, Remarks)
    VALUES (@First, DATEADD(HOUR, -8, @AnchorEnd), @AnchorEnd, N'demo anchor');
    DECLARE @rs TABLE (Status BIT, Message NVARCHAR(500), ShiftsClosed INT, ShiftsBackfilled INT, ShiftOpened BIGINT);
    INSERT INTO @rs EXEC Oee.Shift_Reconcile @NowLocal = NULL, @MaxBackfillDays = 7, @AppUserId = @Sys;
    IF NOT EXISTS (SELECT 1 FROM @rs WHERE Status = 1)
    BEGIN SELECT @msg = Message FROM @rs; RAISERROR('Shift_Reconcile: %s', 16, 1, @msg); END
END

-- ---- defect codes ------------------------------------------------------------------------------
DECLARE @DieCast BIGINT = (SELECT Id FROM Parts.OperationCategory WHERE Code = N'DieCast');
DECLARE @Trim    BIGINT = (SELECT Id FROM Parts.OperationCategory WHERE Code = N'Trim');
DECLARE @MachAsm BIGINT = (SELECT Id FROM Parts.OperationCategory WHERE Code = N'MachiningAssembly');
DECLARE @Defects TABLE (Seq INT IDENTITY, Code NVARCHAR(20), Description NVARCHAR(500), Cat BIGINT);
INSERT INTO @Defects (Code, Description, Cat) VALUES
    (N'DC-POR', N'Porosity',            @DieCast),
    (N'DC-SHS', N'Short shot',          @DieCast),
    (N'DC-CLD', N'Cold flow',           @DieCast),
    (N'DC-FLS', N'Flash',               @DieCast),
    (N'TR-DMG', N'Damaged in handling', @Trim),
    (N'TR-BRR', N'Burr remaining',      @Trim),
    (N'MA-DIM', N'Dimension out',       @MachAsm),
    (N'MA-THR', N'Thread damage',       @MachAsm),
    (N'MA-ASM', N'Assembly error',      @MachAsm);
DECLARE @dc NVARCHAR(20), @dd NVARCHAR(500), @cat BIGINT;
SET @i = 1;
WHILE @i <= (SELECT COUNT(*) FROM @Defects)
BEGIN
    SELECT @dc = Code, @dd = Description, @cat = Cat FROM @Defects WHERE Seq = @i;
    IF NOT EXISTS (SELECT 1 FROM Quality.DefectCode WHERE Code = @dc)
    BEGIN
        DELETE @r;
        INSERT INTO @r EXEC Quality.DefectCode_Create @Code = @dc, @Description = @dd, @OperationCategoryId = @cat, @AppUserId = @Sys;
        IF NOT EXISTS (SELECT 1 FROM @r WHERE Status = 1)
        BEGIN SELECT @msg = Message FROM @r; RAISERROR('DefectCode_Create %s: %s', 16, 1, @dc, @msg); END
    END
    SET @i += 1;
END

-- ---- downtime codes ----------------------------------------------------------------------------
DECLARE @Down TABLE (Seq INT IDENTITY, Code NVARCHAR(20), Description NVARCHAR(500), Cat BIGINT, TypeId BIGINT);
INSERT INTO @Down (Code, Description, Cat, TypeId) VALUES
    (N'DC-DIE',  N'Die change',          @DieCast, 5),
    (N'DC-HYD',  N'Hydraulic fault',     @DieCast, 1),
    (N'DC-MOLD', N'Die maintenance',     @DieCast, 3),
    (N'TR-JAM',  N'Trim press jam',      @Trim,    1),
    (N'MA-TOOL', N'Tool change',         @MachAsm, 5),
    (N'MA-PART', N'Waiting for parts',   @MachAsm, 6),
    (N'MA-QC',   N'Quality check',       @MachAsm, 4);
DECLARE @tid BIGINT;
SET @i = 1;
WHILE @i <= (SELECT COUNT(*) FROM @Down)
BEGIN
    SELECT @dc = Code, @dd = Description, @cat = Cat, @tid = TypeId FROM @Down WHERE Seq = @i;
    IF NOT EXISTS (SELECT 1 FROM Oee.DowntimeReasonCode WHERE Code = @dc)
    BEGIN
        DELETE @r;
        INSERT INTO @r EXEC Oee.DowntimeReasonCode_Create @Code = @dc, @Description = @dd, @OperationCategoryId = @cat,
            @DowntimeReasonTypeId = @tid, @AppUserId = @Sys;
        IF NOT EXISTS (SELECT 1 FROM @r WHERE Status = 1)
        BEGIN SELECT @msg = Message FROM @r; RAISERROR('DowntimeReasonCode_Create %s: %s', 16, 1, @dc, @msg); END
    END
    SET @i += 1;
END
