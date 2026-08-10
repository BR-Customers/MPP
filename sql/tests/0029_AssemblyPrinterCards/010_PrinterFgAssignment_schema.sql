SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0029_AssemblyPrinterCards/010_PrinterFgAssignment_schema.sql';
GO
DECLARE @tbl NVARCHAR(1) = CASE WHEN OBJECT_ID(N'Location.PrinterFgAssignment') IS NOT NULL THEN N'1' ELSE N'0' END;
EXEC test.Assert_IsEqual @TestName = N'[Schema] PrinterFgAssignment table exists', @Expected = N'1', @Actual = @tbl;
DECLARE @ux NVARCHAR(1) = CASE WHEN EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'UX_PrinterFgAssignment_Printer' AND is_unique = 1) THEN N'1' ELSE N'0' END;
EXEC test.Assert_IsEqual @TestName = N'[Schema] UNIQUE(PrinterLocationId) exists', @Expected = N'1', @Actual = @ux;
DECLARE @et NVARCHAR(1) = CASE WHEN EXISTS (SELECT 1 FROM Audit.LogEntityType WHERE Code = N'PrinterFgAssignment') THEN N'1' ELSE N'0' END;
EXEC test.Assert_IsEqual @TestName = N'[Schema] audit entity type seeded', @Expected = N'1', @Actual = @et;
GO
EXEC test.EndTestFile;
GO
