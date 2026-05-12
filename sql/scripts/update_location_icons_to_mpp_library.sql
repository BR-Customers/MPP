-- ============================================================
-- Script:      update_location_icons_to_mpp_library.sql
-- Author:      Blue Ridge Automation
-- Date:        2026-05-11
-- Purpose:     Re-point Location.LocationTypeDefinition.Icon
--              values from the built-in Perspective `material/`
--              library to the custom `mpp/` library shipped in
--              `ignition/icons/mpp/mpp.svg`.
--
--              Migration 0003 seeded these with `material/<name>`
--              paths. 8 of those 15 names do NOT exist in the
--              locked mpp sprite set (see `mockup/icons.csv` and
--              `ignition/icons/mpp/mpp.svg`); this script swaps
--              every row to an icon that IS in the library.
--
-- Rerun safe: every row is unconditionally rewritten — running
--             twice has the same effect as running once.
--
-- Verification: a SELECT at the bottom shows Code + Icon for all
--               rows and flags any Icon that doesn't resolve to a
--               sprite id present in mpp.svg.
-- ============================================================

SET NOCOUNT ON;
SET XACT_ABORT ON;

BEGIN TRANSACTION;

-- Match quality legend (in comments below):
--   exact   = the upstream material/<name> exists verbatim in mpp.svg
--   close   = different name, same concept (e.g. qr_code_2 -> qr_code_scanner)
--   approx  = no semantic match in current library; best-available stand-in
--             (consider adding a dedicated sprite to mpp.svg later)

UPDATE Location.LocationTypeDefinition SET Icon = N'mpp/account_balance'        WHERE Code = N'Organization';            -- close  (material/domain  -> account_balance, ISA-95 enterprise tier)
UPDATE Location.LocationTypeDefinition SET Icon = N'mpp/factory'                WHERE Code = N'Facility';                -- exact
UPDATE Location.LocationTypeDefinition SET Icon = N'mpp/workspaces'             WHERE Code = N'ProductionArea';          -- exact
UPDATE Location.LocationTypeDefinition SET Icon = N'mpp/engineering'            WHERE Code = N'SupportArea';             -- exact
UPDATE Location.LocationTypeDefinition SET Icon = N'mpp/arrow_right_alt'        WHERE Code = N'ProductionLine';          -- approx (material/conveyor_belt; flow arrow stand-in)
UPDATE Location.LocationTypeDefinition SET Icon = N'mpp/fact_check'             WHERE Code = N'InspectionLine';          -- exact
UPDATE Location.LocationTypeDefinition SET Icon = N'mpp/tune'                   WHERE Code = N'Terminal';                -- approx (material/desktop_windows; no monitor sprite)
UPDATE Location.LocationTypeDefinition SET Icon = N'mpp/local_fire_department'  WHERE Code = N'DieCastMachine';          -- exact
UPDATE Location.LocationTypeDefinition SET Icon = N'mpp/handyman'               WHERE Code = N'CNCMachine';              -- approx (material/precision_manufacturing; tools stand-in)
UPDATE Location.LocationTypeDefinition SET Icon = N'mpp/content_cut'            WHERE Code = N'TrimPress';               -- exact
UPDATE Location.LocationTypeDefinition SET Icon = N'mpp/handyman'               WHERE Code = N'AssemblyStation';         -- exact
UPDATE Location.LocationTypeDefinition SET Icon = N'mpp/qr_code_scanner'        WHERE Code = N'SerializedAssemblyLine';  -- close  (material/qr_code_2 -> qr_code_scanner)
UPDATE Location.LocationTypeDefinition SET Icon = N'mpp/videocam'               WHERE Code = N'InspectionStation';       -- approx (material/visibility; vision/camera)
UPDATE Location.LocationTypeDefinition SET Icon = N'mpp/inventory_2'            WHERE Code = N'InventoryLocation';       -- exact
UPDATE Location.LocationTypeDefinition SET Icon = N'mpp/package_2'              WHERE Code = N'Scale';                   -- approx (material/scale; no scale sprite — container stand-in. Set NULL if preferred.)

-- == VERIFICATION ==============================================
-- Echo the post-update state. The IconExistsInLibrary column
-- checks every Icon against the locked sprite-id list extracted
-- from `ignition/icons/mpp/mpp.svg` so any future drift surfaces
-- here.

DECLARE @Sprites TABLE (SpriteId NVARCHAR(60) PRIMARY KEY);
INSERT INTO @Sprites (SpriteId) VALUES
    (N'home'), (N'play_arrow'), (N'arrow_right_alt'), (N'expand_less'),
    (N'expand_more'), (N'check_circle'), (N'cancel'), (N'pause_circle'),
    (N'search'), (N'lock'), (N'add_circle'), (N'edit'), (N'refresh'),
    (N'factory'), (N'workspaces'), (N'account_balance'), (N'settings'),
    (N'tune'), (N'inventory_2'), (N'package_2'), (N'fact_check'),
    (N'analytics'), (N'manage_history'), (N'handyman'), (N'engineering'),
    (N'verified'), (N'local_shipping'), (N'videocam'), (N'report'),
    (N'calendar_month'), (N'pending_actions'), (N'group'), (N'content_cut'),
    (N'qr_code_scanner'), (N'warning'), (N'local_fire_department');

SELECT
    d.Code,
    d.Icon,
    CASE
        WHEN d.Icon IS NULL THEN N'(null)'
        WHEN d.Icon LIKE N'mpp/%' AND EXISTS (
            SELECT 1 FROM @Sprites s WHERE s.SpriteId = SUBSTRING(d.Icon, 5, 100)
        ) THEN N'OK'
        WHEN d.Icon LIKE N'material/%' THEN N'WARN: still material/* — not in mpp lib'
        ELSE N'MISSING: not in mpp.svg sprite list'
    END AS IconStatus
FROM Location.LocationTypeDefinition d
ORDER BY d.Id;

COMMIT;
