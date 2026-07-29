-- =============================================
-- File:         0023_PlantFloor_DieCast_Deltas/031_ufn_IsValidExternalLtt.sql
-- Description:  Lots.ufn_IsValidExternalLtt - external Die Cast LTT format rule
--               (exactly 9 numeric digits; checksum stubbed as valid for now).
-- =============================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0023_PlantFloor_DieCast_Deltas/031_ufn_IsValidExternalLtt.sql';
GO

DECLARE @v9   NVARCHAR(10) = CAST(Lots.ufn_IsValidExternalLtt(N'123456789') AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[LTT] 9 digits valid', @Expected = N'1', @Actual = @v9;

DECLARE @v8   NVARCHAR(10) = CAST(Lots.ufn_IsValidExternalLtt(N'12345678') AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[LTT] 8 digits invalid', @Expected = N'0', @Actual = @v8;

DECLARE @v10  NVARCHAR(10) = CAST(Lots.ufn_IsValidExternalLtt(N'1234567890') AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[LTT] 10 digits invalid', @Expected = N'0', @Actual = @v10;

DECLARE @valp NVARCHAR(10) = CAST(Lots.ufn_IsValidExternalLtt(N'12345678A') AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[LTT] non-digit invalid', @Expected = N'0', @Actual = @valp;

DECLARE @vnl  NVARCHAR(10) = CAST(Lots.ufn_IsValidExternalLtt(NULL) AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[LTT] NULL invalid', @Expected = N'0', @Actual = @vnl;
GO
EXEC test.EndTestFile;
GO
