-- =============================================
-- File: 0008_Parts_Item/025_ClosureMethodCode.sql
-- Desc: Parts.ClosureMethodCode exists and is seeded ByCount/ByWeight/ByVision.
-- =============================================
EXEC test.BeginTestFile @FileName = N'0008_Parts_Item/025_ClosureMethodCode.sql';
GO

DECLARE @Cnt NVARCHAR(10) =
    (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM Parts.ClosureMethodCode
     WHERE Code IN (N'ByCount', N'ByWeight', N'ByVision') AND DeprecatedAt IS NULL);
EXEC test.Assert_IsEqual
    @TestName = N'[ClosureMethodCode] three active codes seeded',
    @Expected = N'3', @Actual = @Cnt;

DECLARE @Uq NVARCHAR(10) =
    (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM sys.indexes
     WHERE name = N'UQ_ClosureMethodCode_Code');
EXEC test.Assert_IsEqual
    @TestName = N'[ClosureMethodCode] unique index on Code present',
    @Expected = N'1', @Actual = @Uq;
GO

EXEC test.EndTestFile;
GO
