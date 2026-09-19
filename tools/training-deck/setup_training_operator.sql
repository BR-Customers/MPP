-- Creates the fictional training operator whose name shows in the training
-- screenshots. Dev only. PIN 24680 (leading digit non-zero on purpose: it is a
-- made-up person, not a full-time employee code).
SET NOCOUNT ON;
IF NOT EXISTS (SELECT 1 FROM Location.AppUser WHERE Pin = N'24680')
BEGIN
    DECLARE @R TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
    INSERT INTO @R EXEC Location.AppUser_Create
        @Initials = N'ST', @DisplayName = N'Sam Taylor', @Pin = N'24680',
        @AdAccount = NULL, @IgnitionRole = NULL, @AppUserId = 1;
    SELECT Status, Message, NewId FROM @R;
END
ELSE SELECT 'exists' AS Status, Id FROM Location.AppUser WHERE Pin = N'24680';
