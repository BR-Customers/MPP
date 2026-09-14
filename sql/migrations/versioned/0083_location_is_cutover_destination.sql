-- ============================================================
-- Migration:   0083_location_is_cutover_destination.sql
-- Author:      Blue Ridge Automation
-- Date:        2026-09-14
-- Description: Location.Location.IsCutoverDestination -- "may the inventory
--              cutover scan count stock IN here?"
--
--              WHY A NEW FLAG. 0081 added IsStockLocation ("can physical stock
--              rest here?") and that is a DIFFERENT question. Seven locations
--              answer yes to it, including Shipping IN, Shipping OUT and two
--              inspection points. The cutover screen offers three: the
--              warehouse and the two trim stores.
--
--              WHY ON Location, NOT LocationTypeDefinition. 0081's flag is
--              per-TYPE, and that cannot work here: WHSE and SHIPIN are both
--              SupportArea, so the type does not discriminate. The answer is a
--              property of the individual location. Do not "tidy" this onto the
--              definition table -- it would re-admit shipping.
--
--              The line the operator selected is ALWAYS offered and is the
--              default; it is not flagged here, it is unioned in by
--              Location_ListCutoverDestinationsForLine.
-- ============================================================

-- ---- 1. The column ----
IF COL_LENGTH('Location.Location', 'IsCutoverDestination') IS NULL
    ALTER TABLE Location.Location
        ADD IsCutoverDestination BIT NOT NULL
            CONSTRAINT DF_Location_IsCutoverDestination DEFAULT 0;
GO

-- ---- 2. Which locations they are. Idempotent: re-running re-asserts the set. ----
UPDATE Location.Location
   SET IsCutoverDestination = 1
 WHERE Code IN (N'WHSE', N'TRIM1-STORE', N'TRIM2-STORE')
   AND IsCutoverDestination <> 1;

UPDATE Location.Location
   SET IsCutoverDestination = 0
 WHERE Code NOT IN (N'WHSE', N'TRIM1-STORE', N'TRIM2-STORE')
   AND IsCutoverDestination <> 0;
GO

-- ---- 3. Report, so a bad seed is visible at deploy ----
DECLARE @Dests NVARCHAR(500) = (
    SELECT STUFF((SELECT N', ' + Code FROM Location.Location
                  WHERE IsCutoverDestination = 1 AND DeprecatedAt IS NULL
                  ORDER BY Code FOR XML PATH(''), TYPE).value('.', 'NVARCHAR(MAX)'), 1, 2, N''));
PRINT 'Cutover destinations: ' + ISNULL(@Dests, N'(none)');
GO

-- ---- 4. Record migration ----
IF NOT EXISTS (SELECT 1 FROM dbo.SchemaVersion WHERE MigrationId = N'0083_location_is_cutover_destination')
    INSERT INTO dbo.SchemaVersion (MigrationId, Description)
    VALUES (N'0083_location_is_cutover_destination',
            N'Location.Location.IsCutoverDestination (BIT, default 0), set for WHSE / TRIM1-STORE / TRIM2-STORE. Per-ROW, not per-type: WHSE and SHIPIN are both SupportArea. Drives the cutover scan destination picker; the selected line is always offered as the default and is not flagged.');
GO
PRINT 'Migration 0083 (location_is_cutover_destination) applied.';
GO
