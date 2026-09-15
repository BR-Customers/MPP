-- No read proc exists for Workorder.DieCastVarianceReason -- it is a fixed,
-- MERGE-seeded code table (5 rows, seeded by migration 0084) with no CRUD
-- surface, so this NQ selects it directly. Deliberate exception to the
-- thin-EXEC-wrapper rule, not a default -- see task-7-report.md.
SELECT Id, Code, Name, RequiresNote, SortOrder
FROM Workorder.DieCastVarianceReason
ORDER BY SortOrder
