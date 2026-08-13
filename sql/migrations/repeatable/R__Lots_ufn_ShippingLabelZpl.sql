-- ============================================================
-- Repeatable: R__Lots_ufn_ShippingLabelZpl.sql
-- Author:     Blue Ridge Automation
-- Version:    1.0
-- Description: Brief D (FAT-LBL-050) -- render the container shipping-label ZPL.
--   Resolves the ACTIVE Container Lots.LabelTemplate.ZplBody and substitutes the
--   {Placeholder} tokens from the container + its Item + genealogy die rank + the
--   composed serial. Pure/deterministic (no side effects) so both Container_Complete
--   and ShippingLabel_Reprint call it inside their own transactions.
--
--   Token map:
--     {PartNumber}    <- Parts.Item.PartNumber (container's Item)
--     {Description}   <- Parts.Item.Description
--     {MfgLotNumber}  <- @AimShipperId (AIM minted serial)
--     {MfgDate}       <- Container.CompletedAt, UTC->Eastern, M/dd/yy
--     {DcPartLevel}   <- Tools.ufn_ContainerOriginDieRankCode (genealogy die-rank trace)
--     {Quantity}      <- SUM(closed tray PartsClosedCount)
--     {Serial}        <- '13218001' (fixed MPP->Honda supplier code) + last 8 of the AIM serial
--     {Coo}           <- 'USA'
--     {PartNumberExt} / {DataMatrix} / {Auditor} <- blank by design (empty on every
--                        real MPP container label; layout + captions retained)
--
--   Unresolved-source tokens render as '' (label still prints). ASCII-only body.
-- ============================================================
CREATE OR ALTER FUNCTION Lots.ufn_ShippingLabelZpl (@ContainerId BIGINT, @AimShipperId NVARCHAR(50))
RETURNS NVARCHAR(MAX)
AS
BEGIN
    DECLARE @ContainerTypeId BIGINT = (SELECT Id FROM Lots.LabelTypeCode WHERE Code = N'Container');
    DECLARE @Zpl NVARCHAR(MAX) =
        (SELECT TOP 1 ZplBody FROM Lots.LabelTemplate
         WHERE LabelTypeCodeId = @ContainerTypeId AND DeprecatedAt IS NULL);
    IF @Zpl IS NULL
        RETURN N'';

    DECLARE @ItemId BIGINT, @CompletedAt DATETIME2(3);
    SELECT @ItemId = ItemId, @CompletedAt = CompletedAt FROM Lots.Container WHERE Id = @ContainerId;

    DECLARE @PartNumber  NVARCHAR(50)  = ISNULL((SELECT PartNumber  FROM Parts.Item WHERE Id = @ItemId), N'');
    DECLARE @Description  NVARCHAR(500) = ISNULL((SELECT Description FROM Parts.Item WHERE Id = @ItemId), N'');
    DECLARE @Qty         INT           = ISNULL((SELECT SUM(PartsClosedCount) FROM Lots.ContainerTray
                                                 WHERE ContainerId = @ContainerId AND ClosedAt IS NOT NULL), 0);
    DECLARE @DcPartLevel NVARCHAR(20)  = Tools.ufn_ContainerOriginDieRankCode(@ContainerId);
    DECLARE @Aim         NVARCHAR(50)  = ISNULL(@AimShipperId, N'');
    DECLARE @Serial      NVARCHAR(16)  = N'13218001' + RIGHT(@Aim, 8);
    DECLARE @MfgDate     NVARCHAR(20)  =
        CASE WHEN @CompletedAt IS NULL THEN N''
             ELSE FORMAT(CAST(@CompletedAt AT TIME ZONE 'UTC' AT TIME ZONE 'Eastern Standard Time' AS DATETIME2(3)), N'M/dd/yy') END;

    SET @Zpl = REPLACE(@Zpl, N'{PartNumber}',    @PartNumber);
    SET @Zpl = REPLACE(@Zpl, N'{Description}',   @Description);
    SET @Zpl = REPLACE(@Zpl, N'{MfgLotNumber}',  @Aim);
    SET @Zpl = REPLACE(@Zpl, N'{MfgDate}',       @MfgDate);
    SET @Zpl = REPLACE(@Zpl, N'{DcPartLevel}',   @DcPartLevel);
    SET @Zpl = REPLACE(@Zpl, N'{Quantity}',      CAST(@Qty AS NVARCHAR(20)));
    SET @Zpl = REPLACE(@Zpl, N'{Serial}',        @Serial);
    SET @Zpl = REPLACE(@Zpl, N'{Coo}',           N'USA');
    -- blank-by-design fields (layout + captions retained)
    SET @Zpl = REPLACE(@Zpl, N'{PartNumberExt}', N'');
    SET @Zpl = REPLACE(@Zpl, N'{DataMatrix}',    N'');
    SET @Zpl = REPLACE(@Zpl, N'{Auditor}',       N'');

    RETURN @Zpl;
END;
GO
