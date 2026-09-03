-- =============================================
-- File:         09_metadata/090_ExtendedProperties.sql
-- Author:       Blue Ridge Automation
-- Created:      2026-09-03
-- Description:
--   Tests for the MS_Description extended properties generated from
--   MPP_MES_DATA_MODEL.md by sql/scripts/gen_extended_properties.js and
--   applied by R__Descriptions_ExtendedProperties.sql.
--
--   These properties are what makes the database self-documenting: SSMS,
--   Ignition, and any schema tool pointed at MPP_MES_Dev read them. Before
--   this work the database carried ZERO of them, so every generated data
--   model came out with an empty documentation section.
--
--   Test 3 is the one that matters most in practice. sqlcmd reads .sql files
--   in the Windows codepage, so an em-dash or arrow in a description lands as
--   mojibake ("a<eur>") in the database and then in Ignition. The generator
--   transliterates to ASCII and refuses to write a file containing a byte
--   above 0x7F; this asserts the guarantee held all the way through.
--
--   Test 4 is a canary on the highest-value single description in the model:
--   the leading-zero rule on Location.AppUser.Pin, whose loss would lock out
--   every full-time employee.
--
--   Pre-conditions:
--     - R__Descriptions_ExtendedProperties.sql applied
-- =============================================

EXEC test.BeginTestFile @FileName = N'09_metadata/090_ExtendedProperties.sql';
GO

-- =============================================
-- Test 1: table-level descriptions exist in quantity.
-- The document describes 90 tables; 66 of them carry a prose paragraph.
-- A floor of 60 catches "the repeatable never ran" without being brittle
-- about individual tables gaining or losing a description.
-- =============================================
DECLARE @TableDescriptions INT = (
    SELECT COUNT(*)
    FROM sys.extended_properties
    WHERE name = N'MS_Description' AND minor_id = 0
);

DECLARE @TableOk BIT = CASE WHEN @TableDescriptions >= 60 THEN 1 ELSE 0 END;
DECLARE @TableDetail NVARCHAR(1000) = N'Found ' + CAST(@TableDescriptions AS NVARCHAR(20)) + N', expected at least 60';

EXEC test.Assert_IsTrue
    @TestName  = N'ExtendedProperties: at least 60 table descriptions present',
    @Condition = @TableOk,
    @Detail    = @TableDetail;
GO

-- =============================================
-- Test 2: column-level descriptions exist in quantity.
-- =============================================
DECLARE @ColumnDescriptions INT = (
    SELECT COUNT(*)
    FROM sys.extended_properties
    WHERE name = N'MS_Description' AND minor_id > 0
);

DECLARE @ColumnOk BIT = CASE WHEN @ColumnDescriptions >= 200 THEN 1 ELSE 0 END;
DECLARE @ColumnDetail NVARCHAR(1000) = N'Found ' + CAST(@ColumnDescriptions AS NVARCHAR(20)) + N', expected at least 200';

EXEC test.Assert_IsTrue
    @TestName  = N'ExtendedProperties: at least 200 column descriptions present',
    @Condition = @ColumnOk,
    @Detail    = @ColumnDetail;
GO

-- =============================================
-- Test 3: every description is pure ASCII.
-- A binary collation makes the range test byte-exact; under the database's
-- default case-insensitive collation, [^ -~] would not reliably match.
-- =============================================
DECLARE @NonAscii INT = (
    SELECT COUNT(*)
    FROM sys.extended_properties
    WHERE name = N'MS_Description'
      AND CAST(value AS NVARCHAR(MAX)) COLLATE Latin1_General_BIN2 LIKE N'%[^ -~]%'
);

EXEC test.Assert_RowCount
    @TestName      = N'ExtendedProperties: no description contains a non-ASCII character',
    @ExpectedCount = 0,
    @ActualCount   = @NonAscii;
GO

-- =============================================
-- Test 4: canary -- the leading-zero PIN rule made the trip intact.
-- =============================================
DECLARE @PinDescription NVARCHAR(MAX) = (
    SELECT CAST(ep.value AS NVARCHAR(MAX))
    FROM sys.extended_properties ep
    JOIN sys.columns c ON c.object_id = ep.major_id AND c.column_id = ep.minor_id
    JOIN sys.tables  t ON t.object_id = c.object_id
    JOIN sys.schemas s ON s.schema_id = t.schema_id
    WHERE s.name = N'Location'
      AND t.name = N'AppUser'
      AND c.name = N'Pin'
      AND ep.name = N'MS_Description'
);

EXEC test.Assert_IsNotNull
    @TestName = N'ExtendedProperties: Location.AppUser.Pin carries a description',
    @Value    = @PinDescription;

EXEC test.Assert_Contains
    @TestName    = N'ExtendedProperties: the Pin description keeps the leading-zero rule',
    @HaystackStr = @PinDescription,
    @NeedleStr   = N'Leading zeros are significant';
GO

-- =============================================
-- Test 5: a description is attached to a real column, not a stale ordinal.
-- sp_addextendedproperty stores minor_id as a column ordinal. If a column is
-- dropped and another added, an orphaned property would silently re-attach to
-- whatever now holds that ordinal. Every column-level property must join to a
-- live column.
-- =============================================
DECLARE @Orphaned INT = (
    SELECT COUNT(*)
    FROM sys.extended_properties ep
    WHERE ep.name = N'MS_Description'
      AND ep.minor_id > 0
      AND ep.class = 1
      AND NOT EXISTS (
          SELECT 1 FROM sys.columns c
          WHERE c.object_id = ep.major_id AND c.column_id = ep.minor_id
      )
);

EXEC test.Assert_RowCount
    @TestName      = N'ExtendedProperties: no column description orphaned from its column',
    @ExpectedCount = 0,
    @ActualCount   = @Orphaned;
GO

EXEC test.EndTestFile;
GO
