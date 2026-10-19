-- =============================================
-- Procedure:   Parts.ContainerConfig_JudgeWeight
-- Author:      Blue Ridge Automation
-- Created:     2026-10-06
-- Version:     1.1
--
-- Description:
--   The checkweigh verdict for one tray: is @Weight inside the part's
--   TargetWeight +/- ToleranceWeight window?
--
--   This is the verdict the IND570 used to compute itself over the PLC
--   interface (Under / OK / Over status bits). The terminals have no PLC
--   option card, so the MES reads only the printed net weight and the
--   comparison lives here, beside the two numbers it compares.
--
--   Both limits are INCLUSIVE: a tray exactly on Target - Tolerance or
--   Target + Tolerance is Ok.
--
--   A missing config or a missing target/tolerance is its own verdict, never
--   a zero. A NULL tolerance read as 0 would make a zero-width window and
--   reject every tray; read as "no check" it would pass every tray. Neither
--   is a decision this proc may make for the plant, so it reports the gap
--   and the caller closes nothing.
--
--   THE SCALE'S OWN FLAGS (v1.1). A terminal programmed with a Target Table
--   record prints its own UNDER / OVER / OK flags (IND570 Template 3). They
--   are a SECOND OPINION, never the verdict: the window that decides is the
--   part's ContainerConfig, because it is per part and audited, and the
--   scale's record is whatever someone last loaded at the terminal. The
--   flags are classified and compared here so a disagreement -- most often a
--   Target Table record not switched at a part changeover -- can be logged
--   and looked into. Nothing about Verdict changes because of them.
--
--   Flags all 0 means the scale has no active target. That is its own state
--   (NoTarget), not a disagreement: there is nothing to compare.
--
-- Parameters:
--   @ItemId        BIGINT        - FK -> Parts.Item. Required.
--   @ClosureMethod NVARCHAR(20)  - FK -> Parts.ClosureMethodCode.Code. Required.
--   @Weight        DECIMAL(10,4) - Net weight read from the scale. Required.
--   @ScaleUnder    INT = NULL    - The scale's printed UNDER flag (0/1). Optional.
--   @ScaleOver     INT = NULL    - The scale's printed OVER flag (0/1). Optional.
--   @ScaleOk       INT = NULL    - The scale's printed OK flag (0/1). Optional.
--                                  All three NULL = the scale printed no flags
--                                  (a Template 1 head); the scale columns are NULL.
--
-- Result set:
--   EXACTLY ONE row, always (so a caller never has to tell "no row" from
--   "no verdict"):
--     Verdict         NVARCHAR(20)  - Ok | Under | Over | NoConfig | NoTolerance | NoWeight
--     Message         NVARCHAR(500) - operator-facing sentence for that verdict
--     Weight, TargetWeight, ToleranceWeight, LowLimit, HighLimit  DECIMAL(10,4) NULL
--     ScaleVerdict    NVARCHAR(20)  NULL - the scale's own call, read from its flags:
--                       Ok | Under | Over  exactly one flag set
--                       NoTarget          all three 0 -- no active Target Table record
--                       Invalid           anything else (two flags set, a value other
--                                         than 0/1, or only some of the three supplied)
--                       NULL              no flags supplied
--     FlagsAgree      BIT  NULL - 1 when ScaleVerdict = Verdict, 0 when they differ;
--                       NULL unless BOTH sides are one of Ok / Under / Over
--     FlagsMessage    NVARCHAR(500) NULL - a sentence for supervisors/engineers when
--                       FlagsAgree = 0 or ScaleVerdict is NoTarget / Invalid; else NULL
--
-- Dependencies:
--   Tables: Parts.ContainerConfig
--
-- Change Log:
--   2026-10-06 - 1.0 - Initial version (IND570 EPrint checkweigh).
--   2026-10-19 - 1.1 - Optional @ScaleUnder/@ScaleOver/@ScaleOk; ScaleVerdict,
--                      FlagsAgree, FlagsMessage columns (the scale's flags are
--                      compared and reported, never acted on).
-- =============================================
CREATE OR ALTER PROCEDURE Parts.ContainerConfig_JudgeWeight
    @ItemId        BIGINT,
    @ClosureMethod NVARCHAR(20),
    @Weight        DECIMAL(10,4),
    @ScaleUnder    INT = NULL,
    @ScaleOver     INT = NULL,
    @ScaleOk       INT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @ConfigId  BIGINT,
            @Target    DECIMAL(10,4),
            @Tolerance DECIMAL(10,4),
            @Low       DECIMAL(10,4),
            @High      DECIMAL(10,4),
            @Verdict   NVARCHAR(20),
            @Message   NVARCHAR(500),
            @ScaleVerdict NVARCHAR(20),
            @FlagsAgree   BIT,
            @FlagsMessage NVARCHAR(500);

    SELECT @ConfigId  = Id,
           @Target    = TargetWeight,
           @Tolerance = ToleranceWeight
    FROM Parts.ContainerConfig
    WHERE ItemId = @ItemId
      AND ClosureMethod = @ClosureMethod
      AND DeprecatedAt IS NULL;

    IF @Weight IS NULL
    BEGIN
        SET @Verdict = N'NoWeight';
        SET @Message = N'No weight was read from the scale.';
    END
    ELSE IF @ConfigId IS NULL
    BEGIN
        SET @Verdict = N'NoConfig';
        SET @Message = N'This part has no ' + ISNULL(@ClosureMethod, N'?')
                     + N' container config. Add one in Item Master before running it on a scale.';
    END
    ELSE IF @Target IS NULL OR @Tolerance IS NULL
    BEGIN
        SET @Verdict = N'NoTolerance';
        SET @Message = N'This part''s ' + @ClosureMethod
                     + N' container config is missing its target weight or tolerance. Set both in Item Master.';
    END
    ELSE
    BEGIN
        SET @Low  = @Target - @Tolerance;
        SET @High = @Target + @Tolerance;

        IF @Weight < @Low
        BEGIN
            SET @Verdict = N'Under';
            SET @Message = N'Tray is UNDER weight: ' + CAST(@Weight AS NVARCHAR(20))
                         + N' against ' + CAST(@Low AS NVARCHAR(20)) + N' to ' + CAST(@High AS NVARCHAR(20)) + N'.';
        END
        ELSE IF @Weight > @High
        BEGIN
            SET @Verdict = N'Over';
            SET @Message = N'Tray is OVER weight: ' + CAST(@Weight AS NVARCHAR(20))
                         + N' against ' + CAST(@Low AS NVARCHAR(20)) + N' to ' + CAST(@High AS NVARCHAR(20)) + N'.';
        END
        ELSE
        BEGIN
            SET @Verdict = N'Ok';
            SET @Message = N'Tray weight is within tolerance.';
        END
    END

    -- The scale's second opinion. Classified, compared, never acted on.
    IF @ScaleUnder IS NULL AND @ScaleOver IS NULL AND @ScaleOk IS NULL
        SET @ScaleVerdict = NULL;
    ELSE IF @ScaleUnder IS NULL OR @ScaleOver IS NULL OR @ScaleOk IS NULL
         OR @ScaleUnder NOT IN (0, 1) OR @ScaleOver NOT IN (0, 1) OR @ScaleOk NOT IN (0, 1)
         OR @ScaleUnder + @ScaleOver + @ScaleOk > 1
        SET @ScaleVerdict = N'Invalid';
    ELSE IF @ScaleUnder + @ScaleOver + @ScaleOk = 0
        SET @ScaleVerdict = N'NoTarget';
    ELSE IF @ScaleUnder = 1
        SET @ScaleVerdict = N'Under';
    ELSE IF @ScaleOver = 1
        SET @ScaleVerdict = N'Over';
    ELSE
        SET @ScaleVerdict = N'Ok';

    IF @ScaleVerdict IN (N'Ok', N'Under', N'Over') AND @Verdict IN (N'Ok', N'Under', N'Over')
    BEGIN
        SET @FlagsAgree = CASE WHEN @ScaleVerdict = @Verdict THEN 1 ELSE 0 END;
        IF @FlagsAgree = 0
            SET @FlagsMessage = N'The scale judged this tray ' + @ScaleVerdict
                              + N' but the MES judged it ' + @Verdict
                              + N' against ' + CAST(@Low AS NVARCHAR(20)) + N' to ' + CAST(@High AS NVARCHAR(20))
                              + N'. The MES verdict stands. Check that the scale''s Target Table record matches this part.';
    END
    ELSE IF @ScaleVerdict = N'NoTarget'
        SET @FlagsMessage = N'The scale has no active target (its UNDER, OVER and OK flags are all 0). The MES verdict stands. Load this part''s Target Table record at the scale.';
    ELSE IF @ScaleVerdict = N'Invalid'
        SET @FlagsMessage = N'The scale''s UNDER / OVER / OK flags do not read as one verdict ('
                          + ISNULL(CAST(@ScaleUnder AS NVARCHAR(10)), N'-') + N'/'
                          + ISNULL(CAST(@ScaleOver  AS NVARCHAR(10)), N'-') + N'/'
                          + ISNULL(CAST(@ScaleOk    AS NVARCHAR(10)), N'-')
                          + N'). The MES verdict stands.';

    SELECT @Verdict   AS Verdict,
           @Message   AS Message,
           @Weight    AS Weight,
           @Target    AS TargetWeight,
           @Tolerance AS ToleranceWeight,
           @Low       AS LowLimit,
           @High      AS HighLimit,
           @ScaleVerdict AS ScaleVerdict,
           @FlagsAgree   AS FlagsAgree,
           @FlagsMessage AS FlagsMessage;
END;
GO
