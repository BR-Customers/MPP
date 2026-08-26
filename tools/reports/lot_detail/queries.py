"""Data sources and parameters for the Lot Detail report.

SQL lives here rather than inside data.bin so it is greppable, diffable and
reviewable. Per the project rule, report queries EXEC an existing read proc
rather than re-implementing joins; Summary and Events predate that rule and stay
inline because they are simple projections with no domain logic.

Each DATA_SOURCES entry: {"key", "sql", "tokens", "children"}.
`tokens` bind positionally to the SQL's `?` placeholders. A token of the form
{Name} resolves to a report PARAMETER at the top level, or to a PARENT ROW COLUMN
inside a nested child.
"""

PARAMETERS = [
    ("LotId", "Long", "0"),
]

SUMMARY_SQL = """SELECT
  l.LotName AS lot_name, i.PartNumber AS part_number, i.Description AS item_desc,
  l.PieceCount AS pieces, s.Code AS status, ot.Name AS origin, loc.Name AS location,
  CAST(l.CreatedAt AT TIME ZONE 'UTC' AT TIME ZONE 'Eastern Standard Time' AS DATETIME2(0)) AS created_et,
  COALESCE(tool.Name, '-') AS tool
FROM Lots.Lot l
JOIN Parts.Item i ON i.Id = l.ItemId
LEFT JOIN Lots.LotStatusCode s ON s.Id = l.LotStatusId
LEFT JOIN Lots.LotOriginType ot ON ot.Id = l.LotOriginTypeId
LEFT JOIN Location.Location loc ON loc.Id = l.CurrentLocationId
LEFT JOIN Tools.Tool tool ON tool.Id = l.ToolId
WHERE l.Id = ?"""

EVENTS_SQL = """SELECT
  CAST(pe.EventAt AT TIME ZONE 'UTC' AT TIME ZONE 'Eastern Standard Time' AS DATETIME2(3)) AS event_at,
  COALESCE(ot.Name, '-') AS operation, pe.ShotCount AS shots, pe.ScrapCount AS scrap,
  COALESCE(u.Initials, '-') AS operator, COALESCE(loc.Name, '-') AS terminal
FROM Workorder.ProductionEvent pe
LEFT JOIN Parts.OperationTemplate ot ON ot.Id = pe.OperationTemplateId
LEFT JOIN Location.AppUser u ON u.Id = pe.AppUserId
LEFT JOIN Location.Location loc ON loc.Id = pe.TerminalLocationId
WHERE pe.LotId = ?
ORDER BY pe.EventAt"""

DATA_SOURCES = [
    {"key": "Summary", "sql": SUMMARY_SQL, "tokens": ["{LotId}"], "children": []},
    {"key": "GenealogyAncestors",
     "sql": "EXEC Lots.Lot_GetGenealogyEdgeTree ?, N'Ancestors'",
     "tokens": ["{LotId}"],
     "children": []},
    # Per-ancestor process history, FLAT: one row per (ancestor, lifecycle step),
    # ancestor identity repeated on every row. This was originally a NESTED child
    # of GenealogyAncestors bound to {RelatedLotId}; the data worked but no layout
    # could draw it -- a <table> inside a <table> renders nothing on this gateway,
    # and a column-keyed <grouping> emits one band with the first row's value.
    # Both verified by render 2026-08-26. The hierarchy is flattened in SQL instead
    # (Lots.Lot_GetAncestorSteps mirrors the edge-tree walk verbatim so the two
    # can never disagree), and drawn with the one table shape that renders.
    {"key": "AncestorSteps", "sql": "EXEC Lots.Lot_GetAncestorSteps ?",
     "tokens": ["{LotId}"], "children": []},
    {"key": "GenealogyDescendants",
     "sql": "EXEC Lots.Lot_GetGenealogyEdgeTree ?, N'Descendants'",
     "tokens": ["{LotId}"], "children": []},
    {"key": "ShippedContainers", "sql": "EXEC Lots.Lot_GetShippedContainers ?",
     "tokens": ["{LotId}"], "children": []},
    {"key": "Lifecycle", "sql": "EXEC Lots.Lot_GetLifecycle ?",
     "tokens": ["{LotId}"], "children": []},
    {"key": "Events", "sql": EVENTS_SQL, "tokens": ["{LotId}"], "children": []},
]
