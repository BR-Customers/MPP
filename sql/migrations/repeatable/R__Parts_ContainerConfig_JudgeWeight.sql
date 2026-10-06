-- =============================================
-- Procedure:   Parts.ContainerConfig_JudgeWeight
-- Author:      Blue Ridge Automation
-- Created:     2026-10-06
-- Version:     1.0
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
-- Parameters:
--   @ItemId        BIGINT        - FK -> Parts.Item. Required.
--   @ClosureMethod NVARCHAR(20)  - FK -> Parts.ClosureMethodCode.Code. Required.
--   @Weight        DECIMAL(10,4) - Net weight read from the scale. Required.
--
-- Result set:
--   EXACTLY ONE row, always (so a caller never has to tell "no row" from
--   "no verdict"):
--     Verdict         NVARCHAR(20)  - Ok | Under | Over | NoConfig | NoTolerance | NoWeight
--     Message         NVARCHAR(500) - operator-facing sentence for that verdict
--     Weight, TargetWeight, ToleranceWeight, LowLimit, HighLimit  DECIMAL(10,4) NULL
--
-- Dependencies:
--   Tables: Parts.ContainerConfig
--
-- Change Log:
--   2026-10-06 - 1.0 - Initial version (IND570 EPrint checkweigh).
-- =============================================
CREATE OR ALTER PROCEDURE Parts.ContainerConfig_JudgeWeight
    @ItemId        BIGINT,
    @ClosureMethod NVARCHAR(20),
    @Weight        DECIMAL(10,4)
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @ConfigId  BIGINT,
            @Target    DECIMAL(10,4),
            @Tolerance DECIMAL(10,4),
            @Low       DECIMAL(10,4),
            @High      DECIMAL(10,4),
            @Verdict   NVARCHAR(20),
            @Message   NVARCHAR(500);

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

    SELECT @Verdict   AS Verdict,
           @Message   AS Message,
           @Weight    AS Weight,
           @Target    AS TargetWeight,
           @Tolerance AS ToleranceWeight,
           @Low       AS LowLimit,
           @High      AS HighLimit;
END;
GO
