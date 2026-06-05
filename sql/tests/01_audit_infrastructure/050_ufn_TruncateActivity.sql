-- =============================================
-- File:         01_audit_infrastructure/050_ufn_TruncateActivity.sql
-- Author:       Blue Ridge Automation
-- Created:      2026-05-28
-- Description:  Tests for Audit.ufn_TruncateActivity.
--               Covers: NULL passthrough, short verbatim, boundary
--               (exactly 500), 1-over (501), far over (5000).
--
--               Pre-conditions:
--                 - Migration 0001 applied
--                 - Audit.ufn_TruncateActivity deployed
-- =============================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'01_audit_infrastructure/050_ufn_TruncateActivity.sql';
GO

-- =============================================
-- Test 1: NULL input -> NULL
-- =============================================
DECLARE @Actual NVARCHAR(500) = Audit.ufn_TruncateActivity(NULL);
DECLARE @ActualStr NVARCHAR(10) = CASE WHEN @Actual IS NULL THEN N'1' ELSE N'0' END;
EXEC test.Assert_IsEqual
    @TestName = N'[TruncNull] NULL passes through as NULL',
    @Expected = N'1',
    @Actual   = @ActualStr;
GO

-- =============================================
-- Test 2: Short input passes through verbatim
-- =============================================
DECLARE @Input NVARCHAR(MAX) = N'5G0 ' + NCHAR(183) + N' Eligibility ' + NCHAR(183) + N' +DIECAST';
DECLARE @Actual NVARCHAR(500) = Audit.ufn_TruncateActivity(@Input);
EXEC test.Assert_IsEqual
    @TestName = N'[TruncShort] Short input passes verbatim',
    @Expected = @Input,
    @Actual   = @Actual;
GO

-- =============================================
-- Test 3: Exactly-500 input passes through verbatim with length 500
-- =============================================
DECLARE @Input NVARCHAR(MAX) = REPLICATE(N'a', 500);
DECLARE @Actual NVARCHAR(500) = Audit.ufn_TruncateActivity(@Input);
DECLARE @LenStr NVARCHAR(10) = CAST(LEN(@Actual) AS NVARCHAR(10));
EXEC test.Assert_IsEqual
    @TestName = N'[TruncBoundary] 500-char input verbatim, length stays 500',
    @Expected = N'500',
    @Actual   = @LenStr;
GO

-- =============================================
-- Test 4: 501-char input gets truncated to 500 chars; suffix is the ellipsis
-- =============================================
DECLARE @Input NVARCHAR(MAX) = REPLICATE(N'a', 501);
DECLARE @Actual NVARCHAR(500) = Audit.ufn_TruncateActivity(@Input);
DECLARE @LenStr NVARCHAR(10) = CAST(LEN(@Actual) AS NVARCHAR(10));
EXEC test.Assert_IsEqual
    @TestName = N'[TruncOverflow] 501-char input truncated to 500 chars',
    @Expected = N'500',
    @Actual   = @LenStr;

DECLARE @LastChar NVARCHAR(1) = RIGHT(@Actual, 1);
DECLARE @IsEllipsis NVARCHAR(1) = CASE WHEN @LastChar = NCHAR(8230) THEN N'1' ELSE N'0' END;
EXEC test.Assert_IsEqual
    @TestName = N'[TruncOverflow] Last char is the NCHAR(8230) ellipsis',
    @Expected = N'1',
    @Actual   = @IsEllipsis;
GO

-- =============================================
-- Test 5: Far-overflow input (5000 chars) — still capped at exactly 500
-- =============================================
DECLARE @Input NVARCHAR(MAX) = REPLICATE(N'b', 5000);
DECLARE @Actual NVARCHAR(500) = Audit.ufn_TruncateActivity(@Input);
DECLARE @LenStr NVARCHAR(10) = CAST(LEN(@Actual) AS NVARCHAR(10));
EXEC test.Assert_IsEqual
    @TestName = N'[TruncFar] 5000-char input capped at 500',
    @Expected = N'500',
    @Actual   = @LenStr;
GO

EXEC test.EndTestFile;
GO
