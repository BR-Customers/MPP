-- ============================================================
-- Scratch:     defectcode_renumber_risk.sql
-- Author:      Blue Ridge Automation
-- Created:     2026-09-15
-- Purpose:     READ-ONLY risk assessment ahead of renumbering
--              Quality.DefectCode to the shop-floor sheet numbering
--              (DCFM-0485 die cast / TSFM-0085 trim shop), zero-padded
--              to 3 digits.
--
--              Run against PROD. Writes nothing. No transaction needed.
--
-- Sections:
--   1. Blast radius        - reject volume per code
--   2. Declared vs actual  - WHERE each code was really recorded  <-- the decisive one
--   3. Free codes          - zero events, safe to change outright
--   4. Collision pre-check - does the proposed new Code already exist
--   5. Format audit        - anything not [0-9][0-9][0-9]
--   6. FK surface          - what else points at DefectCode (verified on the live DB)
--
-- Timestamps displayed Eastern per project convention.
-- ============================================================
SET NOCOUNT ON;

-- ============================================================
-- 1. BLAST RADIUS -- how much history hangs off each code.
--    Codes with Rejects = 0 are free. Codes with history are the
--    ones where a renumber rewrites the meaning of past data.
-- ============================================================
PRINT '=== 1. BLAST RADIUS PER DEFECT CODE ===';

SELECT
    dc.Id,
    dc.Code,
    dc.Description,
    oc.Name                                   AS DeclaredCategory,
    cp.Name                                   AS ChargeToParty,
    dc.IsExcused,
    dc.IsNonRejectScrap,
    CASE WHEN dc.DeprecatedAt IS NULL THEN 'Active' ELSE 'Deprecated' END AS State,
    COUNT(re.Id)                              AS Rejects,
    ISNULL(SUM(re.Quantity), 0)               AS TotalQty,
    COUNT(DISTINCT re.LotId)                  AS DistinctLots,
    COUNT(DISTINCT re.ItemId)                 AS DistinctParts,
    CAST(MIN(re.RecordedAt) AT TIME ZONE 'UTC'
         AT TIME ZONE 'Eastern Standard Time' AS DATETIME2(3)) AS FirstUsedEt,
    CAST(MAX(re.RecordedAt) AT TIME ZONE 'UTC'
         AT TIME ZONE 'Eastern Standard Time' AS DATETIME2(3)) AS LastUsedEt
FROM Quality.DefectCode dc
LEFT JOIN Parts.OperationCategory oc ON oc.Id = dc.OperationCategoryId
LEFT JOIN Quality.ChargeToParty   cp ON cp.Id = dc.ChargeToPartyId
LEFT JOIN Workorder.RejectEvent   re ON re.DefectCodeId = dc.Id
GROUP BY dc.Id, dc.Code, dc.Description, oc.Name, cp.Name,
         dc.IsExcused, dc.IsNonRejectScrap, dc.DeprecatedAt
ORDER BY COUNT(re.Id) DESC, dc.Code;


-- ============================================================
-- 2. DECLARED CATEGORY vs WHERE IT WAS ACTUALLY RECORDED
--
--    This is the decisive one. Each reject event is resolved up the
--    location tree to its Area (Die Cast / Trim Shop / Machine Shop)
--    via CellLocationId, falling back to TerminalLocationId.
--
--    A row where ActualArea disagrees with DeclaredCategory means the
--    code is filed under the wrong department -- and because the two
--    sheets give the SAME defect different numbers per department,
--    those events must be RE-POINTED to the right row, not renumbered
--    along with it.
-- ============================================================
PRINT '=== 2. DECLARED CATEGORY vs ACTUAL RECORDING AREA ===';

WITH Anc AS (
    -- every location, then walk up to its ancestors
    SELECT l.Id AS LeafId, l.Id AS NodeId, l.ParentLocationId,
           l.LocationTypeDefinitionId, 0 AS Lvl
    FROM Location.Location l
    UNION ALL
    SELECT a.LeafId, p.Id, p.ParentLocationId, p.LocationTypeDefinitionId, a.Lvl + 1
    FROM Location.Location p
    INNER JOIN Anc a ON p.Id = a.ParentLocationId
),
AreaOf AS (
    SELECT a.LeafId,
           MIN(a.NodeId) AS AreaLocationId          -- one Area ancestor per leaf
    FROM Anc a
    INNER JOIN Location.LocationTypeDefinition ltd ON ltd.Id = a.LocationTypeDefinitionId
    INNER JOIN Location.LocationType           lt  ON lt.Id  = ltd.LocationTypeId
    WHERE lt.Code = N'Area'
    GROUP BY a.LeafId
)
SELECT
    dc.Code,
    dc.Description,
    oc.Name                         AS DeclaredCategory,
    ISNULL(al.Name, '(unresolved)') AS ActualArea,
    COUNT(*)                        AS Rejects,
    SUM(re.Quantity)                AS TotalQty,
    CASE WHEN al.Name IS NULL THEN 'NO LOCATION ON EVENT'
         WHEN oc.Name IS NULL  THEN 'PLANT-WIDE (no category)'
         WHEN al.Name LIKE '%' + LEFT(oc.Name, 4) + '%' THEN 'ok'
         ELSE '*** MISMATCH ***'
    END                             AS Verdict,
    CAST(MIN(re.RecordedAt) AT TIME ZONE 'UTC'
         AT TIME ZONE 'Eastern Standard Time' AS DATETIME2(3)) AS FirstEt,
    CAST(MAX(re.RecordedAt) AT TIME ZONE 'UTC'
         AT TIME ZONE 'Eastern Standard Time' AS DATETIME2(3)) AS LastEt
FROM Workorder.RejectEvent re
INNER JOIN Quality.DefectCode      dc ON dc.Id = re.DefectCodeId
LEFT  JOIN Parts.OperationCategory oc ON oc.Id = dc.OperationCategoryId
LEFT  JOIN AreaOf                  ao ON ao.LeafId = COALESCE(re.CellLocationId, re.TerminalLocationId)
LEFT  JOIN Location.Location       al ON al.Id = ao.AreaLocationId
GROUP BY dc.Code, dc.Description, oc.Name, al.Name
ORDER BY CASE WHEN al.Name IS NOT NULL AND oc.Name IS NOT NULL
                   AND al.Name NOT LIKE '%' + LEFT(oc.Name, 4) + '%'
              THEN 0 ELSE 1 END,          -- mismatches first
         COUNT(*) DESC, dc.Code
OPTION (MAXRECURSION 100);


-- ============================================================
-- 3. FREE CODES -- no reject history. Renumber, recategorise,
--    split or deprecate these with zero historical consequence.
-- ============================================================
PRINT '=== 3. CODES WITH NO REJECT HISTORY (safe to change) ===';

SELECT dc.Code, dc.Description, oc.Name AS DeclaredCategory,
       CASE WHEN dc.DeprecatedAt IS NULL THEN 'Active' ELSE 'Deprecated' END AS State
FROM Quality.DefectCode dc
LEFT JOIN Parts.OperationCategory oc ON oc.Id = dc.OperationCategoryId
WHERE NOT EXISTS (SELECT 1 FROM Workorder.RejectEvent re WHERE re.DefectCodeId = dc.Id)
ORDER BY oc.Name, dc.Code;


-- ============================================================
-- 4. COLLISION PRE-CHECK against UQ_DefectCode_Code
--
--    EDIT @Map below with the intended old -> new pairs. Seeded with
--    the die cast sheet (DCFM-0485 v18) crosswalk. Any row flagged
--    BLOCKED needs a two-phase rename (park on a temp code first)
--    because the target Code is already taken.
-- ============================================================
PRINT '=== 4. COLLISION PRE-CHECK ===';

DECLARE @Map TABLE (OldCode NVARCHAR(20), NewCode NVARCHAR(20), Note NVARCHAR(200));
INSERT INTO @Map (OldCode, NewCode, Note) VALUES
    (N'117', N'024', N'Raised/Recessed Ejector Pins'),
    (N'118', N'025', N'No Good Date Pin (prod name says Broken Date Pin)'),
    (N'119', N'026', N'Egg-shaped Hole'),
    (N'120', N'027', N'Porosity in Gate Area'),
    (N'121', N'029', N'Cracks'),
    (N'122', N'030', N'Dimensional'),
    (N'123', N'032', N'Galling/Drags'),
    (N'126', N'040', N'Grease/Oil Contamination'),
    (N'127', N'041', N'Holes Not Punched -- sheet MERGES 127+131 into 041'),
    (N'128', N'042', N'Flaking'),
    (N'129', N'044', N'Chipped Bolt Pad'),
    (N'130', N'045', N'Over File'),
    (N'132', N'051', N'Robot Dropping Parts'),
    (N'133', N'052', N'Hit Damage/Dents'),
    (N'221', N'053', N'Computer reject/Low Speed'),
    (N'214', N'054', N'Computer reject/High Speed'),
    (N'215', N'055', N'Computer reject/Cycle time'),
    (N'216', N'056', N'Computer reject/Cast Pressure'),
    (N'217', N'057', N'Computer reject/Biscuit Size'),
    (N'218', N'058', N'Computer reject/Rise up time'),
    (N'219', N'059', N'Computer reject/High Speed Length'),
    (N'220', N'060', N'Computer reject/Press up time'),
    (N'256', N'062', N'Inventory Balance'),
    (N'DC-999', N'999', N'Warmup -- Blue Ridge addition, agreed');

SELECT
    m.OldCode,
    m.NewCode,
    m.Note,
    ISNULL(src.Description, '(old code not found)') AS CurrentDescription,
    ISNULL(reo.Rejects, 0)                          AS RejectsOnOldCode,
    CASE
        WHEN src.Id IS NULL             THEN 'no-op (old code absent)'
        WHEN tgt.Id IS NOT NULL         THEN '*** BLOCKED -- target exists: ' + tgt.Description + ' ***'
        WHEN ISNULL(reo.Rejects, 0) = 0 THEN 'safe (no history)'
        -- The FK is on Id, so no RejectEvent row moves. What changes is what
        -- those rows MEAN: history recorded under the old code now reports
        -- under the new one. Fine for a pure renumber; NOT fine if the row is
        -- also recategorised or split -- see section 2.
        ELSE CAST(reo.Rejects AS NVARCHAR(20)) + ' historical event(s) change code'
    END AS Verdict
FROM @Map m
LEFT JOIN Quality.DefectCode src ON src.Code = m.OldCode
LEFT JOIN Quality.DefectCode tgt ON tgt.Code = m.NewCode
OUTER APPLY (
    SELECT COUNT(*) AS Rejects
    FROM Workorder.RejectEvent re WHERE re.DefectCodeId = src.Id
) reo
ORDER BY CASE WHEN tgt.Id IS NOT NULL THEN 0 ELSE 1 END, m.NewCode;


-- ============================================================
-- 5. FORMAT AUDIT -- everything must be exactly 3 digits.
-- ============================================================
PRINT '=== 5. CODES THAT ARE NOT 3 DIGITS ===';

SELECT dc.Code, dc.Description, oc.Name AS DeclaredCategory,
       LEN(dc.Code) AS CodeLen,
       (SELECT COUNT(*) FROM Workorder.RejectEvent re WHERE re.DefectCodeId = dc.Id) AS Rejects
FROM Quality.DefectCode dc
LEFT JOIN Parts.OperationCategory oc ON oc.Id = dc.OperationCategoryId
WHERE dc.Code NOT LIKE '[0-9][0-9][0-9]' OR LEN(dc.Code) <> 3
ORDER BY dc.Code;


-- ============================================================
-- 6. FK SURFACE -- confirm on the LIVE database what actually
--    points at Quality.DefectCode. (Repo says only
--    Workorder.RejectEvent.DefectCodeId -- verify, do not trust.)
-- ============================================================
PRINT '=== 6. FOREIGN KEYS REFERENCING Quality.DefectCode ===';

SELECT
    OBJECT_SCHEMA_NAME(fk.parent_object_id) + '.' + OBJECT_NAME(fk.parent_object_id) AS ReferencingTable,
    COL_NAME(fkc.parent_object_id, fkc.parent_column_id)                            AS ReferencingColumn,
    fk.name                                                                         AS ForeignKey
FROM sys.foreign_keys fk
INNER JOIN sys.foreign_key_columns fkc ON fkc.constraint_object_id = fk.object_id
WHERE fk.referenced_object_id = OBJECT_ID(N'Quality.DefectCode')
ORDER BY ReferencingTable, ReferencingColumn;

-- Denormalised text that could carry a stale department string.
PRINT '=== 6b. RejectEvent.ChargeToArea distinct values ===';

SELECT re.ChargeToArea, COUNT(*) AS Rejects
FROM Workorder.RejectEvent re
GROUP BY re.ChargeToArea
ORDER BY COUNT(*) DESC;
