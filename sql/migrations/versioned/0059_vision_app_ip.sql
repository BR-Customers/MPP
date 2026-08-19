-- =============================================
-- Migration:   0059_vision_app_ip.sql
-- Author:      Blue Ridge Automation
-- Date:        2026-08-18
-- Description: FAT Day 1 punch list item 8 -- "by vision screens the UI requires the
--              IP address, need to be able to configure that on the location".
--
--              The Terminal (LocationTypeDefinition 7) attribute that feeds the
--              ByVision assembly embed was 'VisionAppUrl', a free-text NVARCHAR(400)
--              holding a whole URL. MPP supplies plain IP addresses, so the attribute
--              is renamed to 'VisionAppIp' and the URL is COMPOSED at read time by
--              Location.ufn_VisionAppUrl (http://<ip>/, with an optional :port and/or
--              /path carried through, and a full URL passed through untouched).
--
--              The attribute is renamed rather than replaced so any existing value is
--              preserved -- and because ufn_VisionAppUrl passes a value containing
--              '://' through unchanged, a terminal already configured with a full URL
--              keeps working with no data edit.
--
--              The result COLUMN of Location.Terminal_GetClosureContext stays named
--              'VisionAppUrl' (it IS a URL after composition), so
--              BlueRidge.Location.Terminal.applyToSession, session.custom.terminal.
--              visionAppUrl and the two assembly views that bind it are UNCHANGED.
--
--              No editor work is required: the Plant Hierarchy attribute panel renders
--              generically from Location.LocationAttributeDefinition (see
--              BlueRidge.Location.Location.buildAttributesForType), so the renamed
--              attribute and its new Description appear automatically.
--
--              Idempotent. Guarded per statement -- a top-of-file RETURN would only
--              exit its own batch.
-- =============================================

IF EXISTS (SELECT 1 FROM dbo.SchemaVersion WHERE MigrationId = N'0059_vision_app_ip')
    PRINT 'Migration 0059 already applied -- statements below are individually guarded.';
GO

-- ---- 1. Rename the attribute definition + retarget its description ----
-- Guarded on "the old name is still there AND the new name is not", so a re-run,
-- or a database where an admin already renamed it by hand, is a no-op.
IF EXISTS (SELECT 1 FROM Location.LocationAttributeDefinition
           WHERE LocationTypeDefinitionId = 7 AND AttributeName = N'VisionAppUrl' AND DeprecatedAt IS NULL)
   AND NOT EXISTS (SELECT 1 FROM Location.LocationAttributeDefinition
                   WHERE LocationTypeDefinitionId = 7 AND AttributeName = N'VisionAppIp' AND DeprecatedAt IS NULL)
BEGIN
    UPDATE Location.LocationAttributeDefinition
    SET    AttributeName = N'VisionAppIp',
           Description   = N'Vision station IP address for the ByVision assembly embed. Enter the bare IP (e.g. 172.17.20.37); a :port and/or /path may be appended when the station needs one. The URL is composed as http://<value>/ at read time.'
    WHERE  LocationTypeDefinitionId = 7
      AND  AttributeName = N'VisionAppUrl'
      AND  DeprecatedAt IS NULL;
END
GO

INSERT INTO dbo.SchemaVersion (MigrationId, Description)
SELECT N'0059_vision_app_ip',
       N'Terminal LTD-7 attribute VisionAppUrl renamed to VisionAppIp (bare IP + optional :port//path); URL composed at read time by Location.ufn_VisionAppUrl. Terminal_GetClosureContext result column stays VisionAppUrl, so Perspective is unchanged.'
WHERE NOT EXISTS (SELECT 1 FROM dbo.SchemaVersion WHERE MigrationId = N'0059_vision_app_ip');
GO

PRINT 'Migration 0059 (vision app IP) applied.';
GO
