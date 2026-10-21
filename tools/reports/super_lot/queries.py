"""Data sources and parameters for the Super-lot report (super-lot piece 6, mock 7).

Every list source is a bare EXEC of the same read proc the super-lot page uses,
so the paper and the screen cannot disagree. ControlledRun_ReportOutcomes returns
its two sections ('Outcome' and 'Defect') in one result set; its optional
@Section (v1.1) lets each report table bind to one section while keeping the
proc's ORDER BY. The only inline SQL is `Printed`: the print time, converted to
Eastern in SQL so it agrees with the "All times Eastern" footer (ReportMill's
@Date@ would render gateway-JVM time).

Each DATA_SOURCES entry: {"key", "sql", "tokens", "children"}.
`tokens` bind positionally to the SQL's `?` placeholders; {ControlledRunId} is the
report parameter.

Data keys and how the layout reads them:
  Header      1 row   -> @Header.<col>@ anywhere on a page
  Printed     1 row   -> @Printed.PrintedAt@
  Outcomes    list    -> <table list-key="Outcomes">, bare @Label@ / @Pieces@
  Defects     list    -> <table list-key="Defects">,  bare @Label@ / @Pieces@
  Members     list    -> <table list-key="Members">
  Deviations  list    -> <table list-key="Deviations">
  Signatures  list    -> <table list-key="Signatures">
"""

PARAMETERS = [
    # BIGINT id: the Designer has no "Integer" for a BIGINT, Long is the match.
    ("ControlledRunId", "Long", "0"),
]

# Echoes the parameter so this source binds one expression like every other one
# (every proven data source in this repo carries at least one token).
PRINTED_SQL = ("SELECT CAST(SYSUTCDATETIME() AT TIME ZONE 'UTC' "
               "AT TIME ZONE 'Eastern Standard Time' AS DATETIME2(3)) AS PrintedAt, "
               "CAST(? AS BIGINT) AS ControlledRunId")

DATA_SOURCES = [
    {"key": "Header", "sql": "EXEC Quality.ControlledRun_Get @Id = ?",
     "tokens": ["{ControlledRunId}"], "children": []},
    {"key": "Printed", "sql": PRINTED_SQL,
     "tokens": ["{ControlledRunId}"], "children": []},
    {"key": "Outcomes",
     "sql": "EXEC Quality.ControlledRun_ReportOutcomes @Id = ?, @Section = N'Outcome'",
     "tokens": ["{ControlledRunId}"], "children": []},
    {"key": "Defects",
     "sql": "EXEC Quality.ControlledRun_ReportOutcomes @Id = ?, @Section = N'Defect'",
     "tokens": ["{ControlledRunId}"], "children": []},
    {"key": "Members", "sql": "EXEC Quality.ControlledRun_ReportMembers @Id = ?",
     "tokens": ["{ControlledRunId}"], "children": []},
    {"key": "Deviations", "sql": "EXEC Quality.ControlledRunDeviation_ListByRun @Id = ?",
     "tokens": ["{ControlledRunId}"], "children": []},
    {"key": "Signatures", "sql": "EXEC Quality.ControlledRun_ListSignatures @Id = ?",
     "tokens": ["{ControlledRunId}"], "children": []},
]
