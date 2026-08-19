-- ============================================================
-- Repeatable:  R__Location_ufn_VisionAppUrl.sql
-- Author:      Blue Ridge Automation
-- Created:     2026-08-18
-- Version:     1.0
-- Description: Composes the ByVision embed URL from the Terminal's 'VisionAppIp'
--              LocationAttribute (FAT day-1 item 8).
--
--              MPP configures vision stations by IP, not by URL -- the operator-facing
--              value is e.g. '172.17.20.37'. This function turns whatever is stored
--              into something an inline-frame can load:
--
--                '172.17.20.37'            -> 'http://172.17.20.37/'
--                '172.17.20.37:8080'       -> 'http://172.17.20.37:8080/'
--                '172.17.20.37/app'        -> 'http://172.17.20.37/app'
--                '172.17.20.37:8080/app'   -> 'http://172.17.20.37:8080/app'
--                'https://vision/x'        -> 'https://vision/x'      (passed through)
--                NULL / '' / whitespace    -> NULL
--
--              Rules, in order:
--                1. Trim. Blank -> NULL, so the embed binds nothing rather than an
--                   'http:///' that would render a browser error page.
--                2. A value already carrying a scheme ('://') is returned UNCHANGED.
--                   This is what makes the 0059 rename non-breaking: a terminal that
--                   was configured under the old free-text 'VisionAppUrl' attribute
--                   keeps working with no data edit.
--                3. Otherwise prefix 'http://'. Append a trailing '/' only when the
--                   value carries no path of its own (no '/'), so an explicit path is
--                   never corrupted.
--
--              Pure/deterministic, no side effects, so Terminal_GetClosureContext can
--              call it inline. String composition only -- it does NOT validate that
--              the value is a well-formed address; a nonsense value yields a URL that
--              simply fails to load, which is the same visible outcome as before.
-- ============================================================
CREATE OR ALTER FUNCTION Location.ufn_VisionAppUrl (@Address NVARCHAR(400))
RETURNS NVARCHAR(400)
WITH SCHEMABINDING
AS
BEGIN
    IF @Address IS NULL
        RETURN NULL;

    DECLARE @v NVARCHAR(400) = LTRIM(RTRIM(@Address));
    IF @v = N''
        RETURN NULL;

    -- Already a full URL (any scheme) -- hand it back untouched.
    IF CHARINDEX(N'://', @v) > 0
        RETURN @v;

    RETURN N'http://' + @v
         + CASE WHEN CHARINDEX(N'/', @v) > 0 THEN N'' ELSE N'/' END;
END;
GO
