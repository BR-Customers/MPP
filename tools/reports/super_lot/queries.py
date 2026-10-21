"""Data sources and parameters for the Super-lot report (super-lot piece 6, mock 7).

Every source EXECs the same read proc the super-lot page uses, so the paper and
the screen cannot disagree. The only SQL written here is the Section filter on
ControlledRun_ReportOutcomes: that proc returns its two sections ('Outcome' and
'Defect') in ONE result set (FDS-11-011: one result set per proc), and the report
draws them as two tables. The filter is a WHERE on a column the proc already
returns -- no join, no rule.

Each DATA_SOURCES entry: {"key", "sql", "tokens", "children"}.
`tokens` bind positionally to the SQL's `?` placeholders; {ControlledRunId} is the
report parameter.

Data keys and how the layout reads them:
  Header      1 row   -> @Header.<col>@ anywhere on a page
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

# SET NOCOUNT ON first: without it the INSERT's row count is the batch's first
# result and the Reporting module reads that instead of the SELECT.
_OUTCOMES_SECTION_SQL = """SET NOCOUNT ON;
DECLARE @r TABLE (Section NVARCHAR(20), Label NVARCHAR(200), Pieces INT);
INSERT INTO @r (Section, Label, Pieces)
    EXEC Quality.ControlledRun_ReportOutcomes @Id = ?;
SELECT Label, Pieces FROM @r WHERE Section = N'%s';"""

DATA_SOURCES = [
    {"key": "Header", "sql": "EXEC Quality.ControlledRun_Get @Id = ?",
     "tokens": ["{ControlledRunId}"], "children": []},
    {"key": "Outcomes", "sql": _OUTCOMES_SECTION_SQL % "Outcome",
     "tokens": ["{ControlledRunId}"], "children": []},
    {"key": "Defects", "sql": _OUTCOMES_SECTION_SQL % "Defect",
     "tokens": ["{ControlledRunId}"], "children": []},
    {"key": "Members", "sql": "EXEC Quality.ControlledRun_ReportMembers @Id = ?",
     "tokens": ["{ControlledRunId}"], "children": []},
    {"key": "Deviations", "sql": "EXEC Quality.ControlledRunDeviation_ListByRun @Id = ?",
     "tokens": ["{ControlledRunId}"], "children": []},
    {"key": "Signatures", "sql": "EXEC Quality.ControlledRun_ListSignatures @Id = ?",
     "tokens": ["{ControlledRunId}"], "children": []},
]
