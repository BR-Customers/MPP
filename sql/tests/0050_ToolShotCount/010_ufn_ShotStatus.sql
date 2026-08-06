SET NOCOUNT ON; SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0050_ToolShotCount/010_ufn_ShotStatus.sql';
GO
-- No fixture: the TVF is a pure function of its two arguments.

-- No limit -> all derived values NULL / 0.
DECLARE @r1 NVARCHAR(20) = (SELECT ISNULL(CAST(ShotsRemaining AS NVARCHAR(20)), N'NULL') FROM Tools.ufn_ShotStatus(500, NULL));
EXEC test.Assert_IsEqual @TestName=N'[TVF] no limit -> ShotsRemaining NULL', @Expected=N'NULL', @Actual=@r1;
DECLARE @p1 NVARCHAR(20) = (SELECT ISNULL(CAST(PercentOfLimit AS NVARCHAR(20)), N'NULL') FROM Tools.ufn_ShotStatus(500, NULL));
EXEC test.Assert_IsEqual @TestName=N'[TVF] no limit -> PercentOfLimit NULL', @Expected=N'NULL', @Actual=@p1;
DECLARE @n1 NVARCHAR(5) = (SELECT CAST(IsNearLimit AS NVARCHAR(5)) FROM Tools.ufn_ShotStatus(500, NULL));
EXEC test.Assert_IsEqual @TestName=N'[TVF] no limit -> IsNearLimit 0', @Expected=N'0', @Actual=@n1;
DECLARE @o1 NVARCHAR(5) = (SELECT CAST(IsOverLimit AS NVARCHAR(5)) FROM Tools.ufn_ShotStatus(500, NULL));
EXEC test.Assert_IsEqual @TestName=N'[TVF] no limit -> IsOverLimit 0', @Expected=N'0', @Actual=@o1;

-- Below near (80%).
DECLARE @r2 NVARCHAR(20) = (SELECT CAST(ShotsRemaining AS NVARCHAR(20)) FROM Tools.ufn_ShotStatus(800, 1000));
EXEC test.Assert_IsEqual @TestName=N'[TVF] 800/1000 -> remaining 200', @Expected=N'200', @Actual=@r2;
DECLARE @p2 NVARCHAR(20) = (SELECT CAST(PercentOfLimit AS NVARCHAR(20)) FROM Tools.ufn_ShotStatus(800, 1000));
EXEC test.Assert_IsEqual @TestName=N'[TVF] 800/1000 -> percent 80.00', @Expected=N'80.00', @Actual=@p2;
DECLARE @n2 NVARCHAR(5) = (SELECT CAST(IsNearLimit AS NVARCHAR(5)) FROM Tools.ufn_ShotStatus(800, 1000));
EXEC test.Assert_IsEqual @TestName=N'[TVF] 800/1000 -> IsNearLimit 0', @Expected=N'0', @Actual=@n2;

-- At the near boundary (exactly 90%).
DECLARE @n3 NVARCHAR(5) = (SELECT CAST(IsNearLimit AS NVARCHAR(5)) FROM Tools.ufn_ShotStatus(900, 1000));
EXEC test.Assert_IsEqual @TestName=N'[TVF] 900/1000 -> IsNearLimit 1 (>=90%)', @Expected=N'1', @Actual=@n3;
DECLARE @o3 NVARCHAR(5) = (SELECT CAST(IsOverLimit AS NVARCHAR(5)) FROM Tools.ufn_ShotStatus(900, 1000));
EXEC test.Assert_IsEqual @TestName=N'[TVF] 900/1000 -> IsOverLimit 0', @Expected=N'0', @Actual=@o3;

-- Near but not over (95%).
DECLARE @n4 NVARCHAR(5) = (SELECT CAST(IsNearLimit AS NVARCHAR(5)) FROM Tools.ufn_ShotStatus(950, 1000));
EXEC test.Assert_IsEqual @TestName=N'[TVF] 950/1000 -> IsNearLimit 1', @Expected=N'1', @Actual=@n4;

-- Exactly at limit -> over, not near.
DECLARE @n5 NVARCHAR(5) = (SELECT CAST(IsNearLimit AS NVARCHAR(5)) FROM Tools.ufn_ShotStatus(1000, 1000));
EXEC test.Assert_IsEqual @TestName=N'[TVF] 1000/1000 -> IsNearLimit 0', @Expected=N'0', @Actual=@n5;
DECLARE @o5 NVARCHAR(5) = (SELECT CAST(IsOverLimit AS NVARCHAR(5)) FROM Tools.ufn_ShotStatus(1000, 1000));
EXEC test.Assert_IsEqual @TestName=N'[TVF] 1000/1000 -> IsOverLimit 1', @Expected=N'1', @Actual=@o5;

-- Over the limit -> remaining negative, over set.
DECLARE @r6 NVARCHAR(20) = (SELECT CAST(ShotsRemaining AS NVARCHAR(20)) FROM Tools.ufn_ShotStatus(1200, 1000));
EXEC test.Assert_IsEqual @TestName=N'[TVF] 1200/1000 -> remaining -200', @Expected=N'-200', @Actual=@r6;
DECLARE @o6 NVARCHAR(5) = (SELECT CAST(IsOverLimit AS NVARCHAR(5)) FROM Tools.ufn_ShotStatus(1200, 1000));
EXEC test.Assert_IsEqual @TestName=N'[TVF] 1200/1000 -> IsOverLimit 1', @Expected=N'1', @Actual=@o6;

-- Zero limit -> percent NULL (guard against divide-by-zero).
DECLARE @p7 NVARCHAR(20) = (SELECT ISNULL(CAST(PercentOfLimit AS NVARCHAR(20)), N'NULL') FROM Tools.ufn_ShotStatus(0, 0));
EXEC test.Assert_IsEqual @TestName=N'[TVF] 0/0 -> PercentOfLimit NULL (no divide-by-zero)', @Expected=N'NULL', @Actual=@p7;
GO
EXEC test.EndTestFile;
GO
