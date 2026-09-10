-- ============================================================
-- Migration:   0076_toolcavity_alpha_code.sql
-- Author:      Blue Ridge Automation
-- Date:        2026-09-10
-- Description: Cavity identity moves from a die-wide INT ordinal to a
--              PER-PART lowercase alphabetic code.
--
--              MPP runs family dies -- one 12-cavity die casting four part
--              numbers, three cavities each -- and names a cavity by a
--              letter scoped to its part ("6MA EX 1 cavity 'a'", per 0072's
--              own header). The letter was already being hand-typed into
--              the free-text Description ('In 1 Da' / 'Db' / 'Dc' on prod)
--              because the schema had nowhere else to put it.
--
--              ONE migration, per the spec. An earlier attempt split this
--              into an additive half plus a later drop, to keep the test
--              suite green mid-rename; it does not work. The re-scoped
--              unique index treats two NULL codes on one (Tool, Item) as a
--              collision, so any proc creating a second cavity before the
--              write procs are migrated throws -- and a ROLLBACK inside an
--              INSERT-EXEC raises Msg 3915. Keeping a green window would
--              mean dual-writing a CavityNumber that is deleted four
--              commits later. The suite is red until the write and read
--              procs land; that is inherent to a rename.
--
--              Design: docs/superpowers/specs/2026-09-10-cavity-alpha-code-design.md
--              Plan:   docs/superpowers/plans/2026-09-10-cavity-alpha-code.md
--
--              Idempotent-guarded; no explicit transaction (repo convention,
--              see 0067).
-- ============================================================

IF EXISTS (SELECT 1 FROM dbo.SchemaVersion WHERE MigrationId = N'0076_toolcavity_alpha_code')
BEGIN
    PRINT 'Migration 0076 already applied -- skipping.';
    RETURN;
END
GO

-- ============================================================
-- 1. Add the column, nullable for the backfill
-- ============================================================
IF COL_LENGTH('Tools.ToolCavity', 'CavityCode') IS NULL
    ALTER TABLE Tools.ToolCavity ADD CavityCode NVARCHAR(4) NULL;
GO

-- ============================================================
-- 2. Guard: there is no 27th letter.
--    A group this large means the ItemId map is wrong, not the letters.
-- ============================================================
IF EXISTS (SELECT 1 FROM Tools.ToolCavity
           GROUP BY ToolId, ISNULL(ItemId, -1) HAVING COUNT(*) > 26)
BEGIN
    RAISERROR(N'Migration 0076 aborted: a (Tool, Item) group has more than 26 cavities. Configure Tools.ToolCavity.ItemId before migrating.', 16, 1);
    RETURN;
END
GO

-- ============================================================
-- 3. THE REAL GATE (deterministic, no heuristics).
--
--    The backfill partitions by (ToolId, ISNULL(ItemId,-1)). A FAMILY die
--    -- one carrying two or more distinct parts -- that ALSO has an
--    unmapped cavity is the failure case: the unmapped row drops into the
--    NULL group alone and silently shifts the letters of its peers.
--
--    Observed on prod 2026-09-10: DMO124 cavity 7 ('Exhaust 1 Aa') was
--    Scrapped before 0072 shipped and could not be mapped through the UI.
--    Left unmapped it derives 'a' in the NULL group, while cavities 8 and 9
--    of part 12241-6MA derive 'a','b' instead of the correct 'b','c'.
--
--    A single-part die with every ItemId NULL is NOT affected -- its
--    cavities form one group and letter correctly.
-- ============================================================
IF EXISTS (
    SELECT 1
    FROM Tools.ToolCavity tc
    WHERE tc.DeprecatedAt IS NULL
    GROUP BY tc.ToolId
    HAVING COUNT(DISTINCT tc.ItemId) >= 2
       AND SUM(CASE WHEN tc.ItemId IS NULL THEN 1 ELSE 0 END) > 0)
BEGIN
    DECLARE @Offenders NVARCHAR(MAX) = (
        SELECT STRING_AGG(CAST(x.Code AS NVARCHAR(MAX)), N', ')
        FROM (
            SELECT t.Code
            FROM Tools.ToolCavity tc
            INNER JOIN Tools.Tool t ON t.Id = tc.ToolId
            WHERE tc.DeprecatedAt IS NULL
            GROUP BY t.Code
            HAVING COUNT(DISTINCT tc.ItemId) >= 2
               AND SUM(CASE WHEN tc.ItemId IS NULL THEN 1 ELSE 0 END) > 0
        ) x);

    DECLARE @GateMsg NVARCHAR(2044) = LEFT(
        N'Migration 0076 aborted: family die(s) with an unmapped cavity -- '
        + ISNULL(@Offenders, N'?')
        + N'. An unmapped cavity falls into the NULL group alone and mis-letters its peers. Map every cavity to its part in the Tool Cavities editor, then re-run.', 2044);
    RAISERROR(@GateMsg, 16, 1);
    RETURN;
END
GO

-- ============================================================
-- 4. Backfill: letters per part group, in existing ordinal order.
--    Deprecated rows included -- the unique index is filtered, but the
--    column becomes NOT NULL in step 6.
-- ============================================================
UPDATE tc
SET CavityCode = CHAR(96 + x.rn)
FROM Tools.ToolCavity tc
INNER JOIN (
    SELECT Id,
           ROW_NUMBER() OVER (PARTITION BY ToolId, ISNULL(ItemId, -1)
                              ORDER BY CavityNumber, Id) AS rn
    FROM Tools.ToolCavity
) x ON x.Id = tc.Id
WHERE tc.CavityCode IS NULL;
GO

-- ============================================================
-- 5. ADVISORY cross-check -- prints, never aborts.
--
--    Operators already type the letter as the last character of
--    Description ('In 1 Da', 'Ex 1 Db', 'Exhaust 1 Aa'). Where a
--    Description ends in <non-letter><uppercase><lowercase> the trailing
--    letter is almost certainly the cavity, so a disagreement is worth
--    a human's eye.
--
--    It PRINTS rather than aborting because the pattern is a heuristic
--    over free text and a legitimate naming scheme can disagree: the
--    RB-B / RB-C demo dies name cavities per DIE HALF ('Exhaust 1 Ba',
--    'Exhaust 2 Bb'), so their letters restart within one part. Aborting
--    a production migration on a naming convention would be wrong.
--
--    Description is compared to, never parsed into, the column (spec D4).
-- ============================================================
DECLARE @Advisory NVARCHAR(MAX) = (
    SELECT STRING_AGG(CAST(
               d.ToolCode + N' "' + d.Descr + N'" -> ' + d.Derived AS NVARCHAR(MAX)), N'; ')
    FROM (
        SELECT t.Code AS ToolCode, tc.Description AS Descr, tc.CavityCode AS Derived
        FROM Tools.ToolCavity tc
        INNER JOIN Tools.Tool t ON t.Id = tc.ToolId
        WHERE tc.DeprecatedAt IS NULL
          AND tc.Description IS NOT NULL
          AND LEN(tc.Description) >= 3
          AND RIGHT(tc.Description, 3) COLLATE Latin1_General_BIN2 LIKE N'[^a-zA-Z][A-Z][a-z]'
          AND RIGHT(tc.Description, 1) <> tc.CavityCode
    ) d);

IF @Advisory IS NOT NULL
BEGIN
    PRINT '0076 ADVISORY: derived cavity code differs from the letter in Description for:';
    PRINT LEFT(@Advisory, 4000);
    PRINT '0076 ADVISORY: review these; a per-die-half naming scheme is a legitimate cause.';
END
GO

-- ============================================================
-- 6. Lock it down
-- ============================================================
ALTER TABLE Tools.ToolCavity ALTER COLUMN CavityCode NVARCHAR(4) NOT NULL;
GO

-- ============================================================
-- 7. Re-scope uniqueness: per (Tool, Item), not per Tool.
--    ItemId stays NULLable -- SQL Server treats NULLs as equal for
--    uniqueness, so a non-family die's cavities form one group and still
--    get distinct letters. That is correct: a one-part die's cavities ARE
--    mutually exclusive.
-- ============================================================
IF EXISTS (SELECT 1 FROM sys.indexes
           WHERE name = N'UQ_ToolCavity_ActiveToolCavity'
             AND object_id = OBJECT_ID(N'Tools.ToolCavity'))
    DROP INDEX UQ_ToolCavity_ActiveToolCavity ON Tools.ToolCavity;
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes
               WHERE name = N'UQ_ToolCavity_ActiveToolItemCode'
                 AND object_id = OBJECT_ID(N'Tools.ToolCavity'))
    CREATE UNIQUE INDEX UQ_ToolCavity_ActiveToolItemCode
        ON Tools.ToolCavity (ToolId, ItemId, CavityCode)
        WHERE DeprecatedAt IS NULL;
GO

-- ============================================================
-- 8. Drop the superseded columns.
--
--    Tools.ToolCavity.CavityNumber -- the die-wide INT ordinal.
--
--    Lots.Lot.CavityNumber -- the D2 free-text manual-cavity note, retired
--    with the fallback itself: @ToolCavityId is now unconditionally
--    required for a die-cast-origin LOT. Guarded, because dropping a
--    populated column destroys data.
--
--    NOT REVERSIBLE. The ordinal cannot be recovered from the letter once
--    cavities are added or deprecated. Rollback is restore-from-backup.
-- ============================================================
IF EXISTS (SELECT 1 FROM Lots.Lot WHERE NULLIF(LTRIM(RTRIM(CavityNumber)), N'') IS NOT NULL)
BEGIN
    RAISERROR(N'Migration 0076 aborted: Lots.Lot.CavityNumber holds data. Rename it to CavityNote instead of dropping it, and keep the D2 fallback.', 16, 1);
    RETURN;
END
GO

IF COL_LENGTH('Tools.ToolCavity', 'CavityNumber') IS NOT NULL
    ALTER TABLE Tools.ToolCavity DROP COLUMN CavityNumber;
GO

IF COL_LENGTH('Lots.Lot', 'CavityNumber') IS NOT NULL
    ALTER TABLE Lots.Lot DROP COLUMN CavityNumber;
GO

-- ============================================================
-- == Record migration ========================================
-- ============================================================
IF NOT EXISTS (SELECT 1 FROM dbo.SchemaVersion WHERE MigrationId = N'0076_toolcavity_alpha_code')
    INSERT INTO dbo.SchemaVersion (MigrationId, Description)
    VALUES (
        N'0076_toolcavity_alpha_code',
        N'Cavity identity: per-part lowercase alphabetic Tools.ToolCavity.CavityCode NVARCHAR(4) NOT NULL, backfilled per (Tool, Item) group in ordinal order. Aborts if a family die still has an unmapped cavity (that row would mis-letter its peers). Unique index re-scoped to (ToolId, ItemId, CavityCode). Drops Tools.ToolCavity.CavityNumber and Lots.Lot.CavityNumber (D2 manual-cavity fallback retired).'
    );
GO

PRINT 'Migration 0076 completed: Tools.ToolCavity.CavityCode.';
GO
