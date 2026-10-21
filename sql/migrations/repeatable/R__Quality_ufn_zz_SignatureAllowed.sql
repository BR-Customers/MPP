-- ============================================================
-- Repeatable:  R__Quality_ufn_zz_SignatureAllowed.sql
-- Object:      Quality.ufn_SignatureAllowed
-- Author:      Blue Ridge Automation
-- Modified:    2026-10-13
-- Version:     1.0
-- Description: THE SEAM. The single place that answers "may this user sign
--              this meaning?" (spec D1 / 5.5). Every proc that writes a
--              Quality.Signature row asks here first.
--
--              TODAY it can only check that the user is active and has an AD
--              account, because there are no plant AD roles to gate on and the
--              project does not keep its own role tables. So ANY active
--              AD-mapped user may sign ANY meaning. That is a known, stated
--              limitation -- the Sign-off tab says so on screen.
--
--              When AD roles exist, THIS function is the only thing that
--              changes: branch on @MeaningCode and the user's role here.
--              @MeaningCode is unused until then, on purpose -- it is in the
--              signature now so no caller has to change later.
--
--              Scalar, deterministic for a given row state. 'zz_' is the
--              deploy-order marker used by every function file here.
-- ============================================================
CREATE OR ALTER FUNCTION Quality.ufn_SignatureAllowed (@AppUserId BIGINT, @MeaningCode NVARCHAR(30))
RETURNS BIT
AS
BEGIN
    RETURN CONVERT(BIT, CASE WHEN EXISTS (
        SELECT 1
        FROM Location.AppUser u
        WHERE u.Id = @AppUserId
          AND u.DeprecatedAt IS NULL
          AND NULLIF(LTRIM(RTRIM(u.AdAccount)), N'') IS NOT NULL
          AND EXISTS (SELECT 1 FROM Quality.SignatureMeaning sm WHERE sm.Code = @MeaningCode)
    ) THEN 1 ELSE 0 END);
END;
GO
