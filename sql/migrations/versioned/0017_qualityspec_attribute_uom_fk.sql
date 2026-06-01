-- =============================================
-- Migration: 0017_qualityspec_attribute_uom_fk
-- Adds UomId FK to Quality.QualitySpecAttribute (replaces free-text Uom usage
-- by the Config Tool editor) and a soft-delete marker to Quality.QualitySpec
-- so specs can be deprecated at the header level.
--
-- Note: the user/attribution table in this project is Location.AppUser
-- (NOT Audit.AppUser) -- see migration 0001 + every *ByUserId FK convention.
-- =============================================

-- 1. QualitySpecAttribute.UomId -> Parts.Uom
IF NOT EXISTS (SELECT 1 FROM sys.columns
              WHERE object_id = OBJECT_ID(N'Quality.QualitySpecAttribute') AND name = N'UomId')
BEGIN
    ALTER TABLE Quality.QualitySpecAttribute ADD UomId BIGINT NULL;
END
GO

IF NOT EXISTS (SELECT 1 FROM sys.foreign_keys WHERE name = N'FK_QualitySpecAttribute_Uom')
BEGIN
    ALTER TABLE Quality.QualitySpecAttribute
        ADD CONSTRAINT FK_QualitySpecAttribute_Uom
        FOREIGN KEY (UomId) REFERENCES Parts.Uom(Id);
END
GO

-- 2. QualitySpec soft-delete columns
IF NOT EXISTS (SELECT 1 FROM sys.columns
              WHERE object_id = OBJECT_ID(N'Quality.QualitySpec') AND name = N'DeprecatedAt')
BEGIN
    ALTER TABLE Quality.QualitySpec ADD DeprecatedAt DATETIME2(3) NULL;
    ALTER TABLE Quality.QualitySpec ADD DeprecatedByUserId BIGINT NULL;
END
GO

IF NOT EXISTS (SELECT 1 FROM sys.foreign_keys WHERE name = N'FK_QualitySpec_DeprecatedByUser')
BEGIN
    ALTER TABLE Quality.QualitySpec
        ADD CONSTRAINT FK_QualitySpec_DeprecatedByUser
        FOREIGN KEY (DeprecatedByUserId) REFERENCES Location.AppUser(Id);
END
GO
