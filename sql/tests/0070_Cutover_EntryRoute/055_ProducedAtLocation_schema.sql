-- =============================================
-- File:         0070_Cutover_EntryRoute/055_ProducedAtLocation_schema.sql
-- Description:  Lots.Lot.ProducedAtLocationId (migration 0082) -- the die cast
--               machine that produced a LOT.
--
--               Cutover is the only writer: a LOT born at a die cast terminal
--               gets its machine from CreatedAtTerminalId's parent, but a
--               cutover LOT is created at a MACHINING terminal weeks after the
--               casting, so the machine exists only on the paper tag.
--
--               NULLable by design -- every non-cutover LOT leaves it NULL.
-- =============================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0070_Cutover_EntryRoute/055_ProducedAtLocation_schema.sql';
GO

-- (1) The column exists.
DECLARE @a1 NVARCHAR(10) = CASE WHEN COL_LENGTH(N'Lots.Lot', N'ProducedAtLocationId') IS NOT NULL
                                THEN N'1' ELSE N'0' END;
EXEC test.Assert_IsEqual @TestName = N'[ProducedAt] column exists on Lots.Lot',
    @Expected = N'1', @Actual = @a1;

-- (2) It is BIGINT and NULLable. NOT NULL would break every existing caller.
DECLARE @a2 NVARCHAR(50) = (
    SELECT ty.name + N'/' + CAST(c.is_nullable AS NVARCHAR(1))
    FROM sys.columns c
    INNER JOIN sys.types ty ON ty.user_type_id = c.user_type_id
    WHERE c.object_id = OBJECT_ID(N'Lots.Lot') AND c.name = N'ProducedAtLocationId');
EXEC test.Assert_IsEqual @TestName = N'[ProducedAt] column is BIGINT NULL',
    @Expected = N'bigint/1', @Actual = @a2;

-- (3) It is a real FK to Location.Location, not a loose id.
DECLARE @a3 NVARCHAR(10) = (
    SELECT CAST(COUNT(*) AS NVARCHAR(10))
    FROM sys.foreign_keys fk
    INNER JOIN sys.foreign_key_columns fkc ON fkc.constraint_object_id = fk.object_id
    INNER JOIN sys.columns c ON c.object_id = fkc.parent_object_id
                            AND c.column_id = fkc.parent_column_id
    WHERE fk.parent_object_id = OBJECT_ID(N'Lots.Lot')
      AND fk.referenced_object_id = OBJECT_ID(N'Location.Location')
      AND c.name = N'ProducedAtLocationId');
EXEC test.Assert_IsEqual @TestName = N'[ProducedAt] column is an FK to Location.Location',
    @Expected = N'1', @Actual = @a3;

-- (4) The migration is recorded.
DECLARE @a4 NVARCHAR(10) = (
    SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM dbo.SchemaVersion
    WHERE MigrationId = N'0082_lot_produced_at_location');
EXEC test.Assert_IsEqual @TestName = N'[ProducedAt] migration 0082 recorded in SchemaVersion',
    @Expected = N'1', @Actual = @a4;

-- (5) The column carries an MS_Description (generated from the data model).
DECLARE @a5 NVARCHAR(10) = (
    SELECT CAST(COUNT(*) AS NVARCHAR(10))
    FROM sys.extended_properties ep
    WHERE ep.major_id = OBJECT_ID(N'Lots.Lot')
      AND ep.minor_id = COLUMNPROPERTY(OBJECT_ID(N'Lots.Lot'), N'ProducedAtLocationId', 'ColumnId')
      AND ep.name = N'MS_Description');
EXEC test.Assert_IsEqual @TestName = N'[ProducedAt] column is documented',
    @Expected = N'1', @Actual = @a5;
GO

EXEC test.EndTestFile;
GO
