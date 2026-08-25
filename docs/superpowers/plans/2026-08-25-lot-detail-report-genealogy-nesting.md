# LOT Detail Report — Nested Ancestor History + Reachable LOT Picker

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give the LOT Detail report a nested process history under every ancestor LOT, banded by part number, and make any LOT reachable from the report picker.

**Architecture:** The report today is an opaque committed `data.bin` with no generator in version control. Task 1 fixes that first by extracting its layout XML and SQL into checked-in source files plus a build script that regenerates the current report faithfully — every later task is then an ordinary edit to reviewable text. The nested history is a `SubQuery.setChildren` child query running `Lots.Lot_GetLifecycle` once per ancestor row, bound to the parent row's `RelatedLotId`, rendered as a `<table-group>` with a nested child `<table>`.

**Tech Stack:** Python 3 (build scripts, outside the gateway), Ignition Reporting Module `data.bin` binary format, ReportMill layout XML, SQL Server 2022 (read procs only — no schema change), Ignition Perspective (the picker).

**Spec:** `docs/superpowers/specs/2026-08-25-lot-detail-report-genealogy-nesting-design.md`

## Global Constraints

- **No schema change, no new stored procedure, no migration.** Reuses `Lots.Lot_GetLifecycle`, `Lots.Lot_GetGenealogyEdgeTree`, `Lots.Lot_GetShippedContainers` unchanged. The automated SQL suite must not need re-running.
- **Do not modify the global skill at `C:\Users\JacquesPotgieter\.claude\skills\ignition-reporting\`.** It is outside this repo and shared with other projects. Nesting support is added as a **subclass in this repo**.
- **Do not edit `sql/tests/0055_LotGenealogyReport/`** — those procs' contracts are unchanged.
- **A report resolves by its internal `setTitle`, not its folder name.** Folder name, `setTitle`, and `BlueRidge.Reports` registry `reportPath` must all stay exactly `Lot Detail`.
- **Escape `&`, `<`, `>` in every layout literal** and validate the layout XML parses (`xml.dom.minidom.parseString`) before writing `data.bin`. A raw `&` throws `RMException` at *render* time, surfaced only as a generic "invalid report".
- **`resource.json` for the report stays exactly** `{"scope":"A","version":1,"restricted":false,"overridable":true,"files":["data.bin"],"attributes":{}}` — a *partial* `lastModification` can fault the whole gateway on startup.
- **Deploy is `.\scan.ps1`** from the repo root. Never `pull.ps1`, never `C:\MPP`, no gateway restart (`scan.ps1` does reload a changed report `data.bin`).
- **`executeReport` arg order is `(reportPath, projectName, paramsDict, fileType)`.**
- **Render-and-look is mandatory.** Bad ReportMill layout and unresolved `@tokens@` render blank and log nothing. A clean load is not evidence.
- **Assume group bands and column headers do NOT repeat after a page break** (Jacques, 2026-08-25). Each ancestor row restates its own LOT name and part number so a continuation page is never orphaned timestamps.
- Commit to `jacques/working`. Stage explicit paths only — never `git add -u` / `-A`. Omit the `Co-Authored-By: Claude` trailer.
- Seed/report string values are ASCII-only where they reach SQL; the middle dot `·` already used in this report's layout is fine (it is XML, not a `sqlcmd`-read `.sql` file).

## Test LOTs (already characterised against `MPP_MES_Dev`)

| LOT | Id | Ancestors / Descendants / Containers / Events | Exercises |
|---|---|---|---|
| `000000001` (`12231-59B-0000`) | 254 | 0 / 5 / 5 / 3 | "Ancestors: 0" subtitle; populated descendants + containers |
| `MESL3000146` | 10270 | **4** / 0 / 1 / 0 | **the primary nested-block test** — four ancestors, each with its own step table, and the best chance of a page break |
| `000000024-04` (`5G0-SA`) | 10274 | 1 / 0 / 0 / 0 | single nested block; three zero subtitles |

Counts verified against `MPP_MES_Dev` on 2026-08-25 via `Lots.LotGenealogyClosure`.
Render **10270 and 254** at minimum; 10274 is a useful single-ancestor sanity check.

## File Structure

| Path | Responsibility |
|---|---|
| `tools/reports/lot_detail/layout.xml` | **Create.** The ReportMill layout, extracted from the current `data.bin`. Human-editable, diffable. The one file Tasks 4–5 edit. |
| `tools/reports/lot_detail/queries.py` | **Create.** The six SQL strings + data keys + expression tokens, as data. |
| `tools/reports/nesting_builder.py` | **Create.** `NestingReportBuilder(ReportBuilder)` — adds `add_nested_query`. Repo-local so the global skill stays untouched. |
| `tools/reports/build_lot_detail_report.py` | **Create.** Assembles donor + queries + layout → `data.bin`. The generator. |
| `tools/reports/verify_lot_detail_report.py` | **Create.** Parses a `data.bin` and asserts its structure (title, params, data keys, tokens, SQL, layout). Used as the test in several tasks. |
| `tools/reports/README.md` | **Create.** How to regenerate a report and why the binary is not the source of truth. |
| `ignition/projects/MPP/com.inductiveautomation.reporting/reports/Lot Detail/data.bin` | **Modify** (regenerated, never hand-edited). |
| `ignition/projects/MPP/ignition/timer/DevRenderReport/` | **Create then delete.** One-shot gateway render harness (Task 3, removed in Task 8). |
| `ignition/projects/Core/ignition/script-python/BlueRidge/Reports/code.py` | **Modify.** `composeParams` resolves a typed/scanned LOT name. |
| `ignition/projects/MPP/com.inductiveautomation.perspective/views/BlueRidge/Views/Reports/view.json` | **Modify.** `LotDropdown` gains `allowCustomOptions` + `search`. |

---

### Task 1: Extract the report into version-controlled source

Today `data.bin` is the only artifact — there is no generator, so no one can change this report without reverse-engineering it. This task produces source files plus a build script that regenerates today's report with **no behaviour change**, proven by structural equality.

**Files:**
- Create: `tools/reports/lot_detail/layout.xml`
- Create: `tools/reports/lot_detail/queries.py`
- Create: `tools/reports/build_lot_detail_report.py`
- Create: `tools/reports/verify_lot_detail_report.py`
- Create: `tools/reports/README.md`

**Interfaces:**
- Consumes: the skill's `ignition_report_codec.parse`, `ignition_tree_codec`, `report_builder.ReportBuilder` (read-only, imported by path).
- Produces: `queries.py` exposing `PARAMETERS: list[tuple[str,str,str]]` and `DATA_SOURCES: list[dict]` where each dict is `{"key": str, "sql": str, "tokens": list[str], "children": list[dict]}`; `verify_lot_detail_report.py` exposing `describe(path) -> dict` and `main(path) -> int`.

- [ ] **Step 1: Write the extraction+verify tool**

Create `tools/reports/verify_lot_detail_report.py`:

```python
"""Parse an Ignition report data.bin and describe its structure.

The report binary is generated, never hand-edited (see README.md). This module is
both the extractor that bootstrapped the source files and the structural test used
after every regeneration.
"""
import base64, os, re, struct, sys

SKILL_TOOLS = os.path.join(os.path.expanduser("~"), ".claude", "skills",
                           "ignition-reporting", "tools")
sys.path.insert(0, SKILL_TOOLS)

from ignition_report_codec import parse          # noqa: E402
import ignition_tree_codec as tc                 # noqa: E402

REPORT_BIN = os.path.join("ignition", "projects", "MPP",
                          "com.inductiveautomation.reporting", "reports",
                          "Lot Detail", "data.bin")


def _sid(st, i):
    v = st.get(i)
    return v if v is not None else "<%s>" % i


def _mname(st, e):
    for (nid, ct, raw) in e.attrs:
        if _sid(st, nid) == "m" and ct == tc.CODEC_STR and len(raw) == 4:
            return _sid(st, struct.unpack(">i", raw)[0])
    return None


def _body(st, e):
    if e.body is not None and len(e.body) == 4:
        return _sid(st, struct.unpack(">i", e.body)[0])
    return None


def _calls(st, e):
    out = {}
    for c in e.children:
        n = _mname(st, c)
        if n:
            out.setdefault(n, c)
    return out


def _subquery(st, e):
    """Describe a SubQuery element: key, tokens, sql, children."""
    k = _calls(st, e)
    key = None
    for c in k.get("setDataKey", e).children:
        key = _body(st, c) or key
    tokens, sql = [], None
    qc = k.get("setQueryConfig")
    if qc is not None:
        for cfg in qc.children:
            for s in cfg.children:
                sn = _mname(st, s)
                if sn == "setExpressions":
                    for lst in s.children:
                        for t in lst.children:
                            tokens.append(_body(st, t))
                elif sn == "setQuery":
                    for t in s.children:
                        sql = _body(st, t)
    children = []
    ch = k.get("setChildren")
    if ch is not None:
        for lst in ch.children:
            for sub in lst.children:
                if _calls(st, sub).get("setDataKey") is not None:
                    children.append(_subquery(st, sub))
    return {"key": key, "tokens": tokens, "sql": sql, "children": children}


def describe(path):
    """-> {title, parameters, sources, layout_xml}. sources are nested dicts."""
    d = parse(open(path, "rb").read())
    st = d["strings"]
    root = tc.parse_tree(d["element_tree_bytes"])

    sources, params, title, layout = [], [], None, None

    def walk(e):
        k = _calls(st, e)
        if "setRootQuery" in k:
            for sub in k["setRootQuery"].children:
                sources.append(_subquery(st, sub))
        for c in e.children:
            walk(c)

    walk(root)

    for i, s in sorted(st.items()):
        if not isinstance(s, str):
            continue
        t = s.strip()
        if len(t) > 400 and re.match(r"^[A-Za-z0-9+/=\s]+$", t):
            layout = base64.b64decode(t).decode("utf-8")

    # title + parameters read straight off the tree
    def walk2(e):
        k = _calls(st, e)
        if "setTitle" in k:
            for c in k["setTitle"].children:
                v = _body(st, c)
                if v:
                    walk2.title = v
        if "setName" in k and "setType" in k:
            nm = dv = None
            for c in k["setName"].children:
                nm = _body(st, c) or nm
            for c in k.get("setDefaultValue", k["setName"]).children:
                dv = _body(st, c) or dv
            if nm:
                params.append((nm, dv))
        for c in e.children:
            walk2(c)

    walk2.title = None
    walk2(root)
    title = walk2.title

    return {"title": title, "parameters": params, "sources": sources,
            "layout_xml": layout}


def _flatten(sources, depth=0, out=None):
    out = [] if out is None else out
    for s in sources:
        out.append((depth, s["key"], tuple(s["tokens"])))
        _flatten(s["children"], depth + 1, out)
    return out


def main(path=REPORT_BIN):
    info = describe(path)
    print("title      :", info["title"])
    print("parameters :", info["parameters"])
    print("layout     : %d chars" % len(info["layout_xml"] or ""))
    print("data sources:")
    for depth, key, toks in _flatten(info["sources"]):
        print("   %s%-22s tokens=%s" % ("    " * depth, key, list(toks)))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1] if len(sys.argv) > 1 else REPORT_BIN))
```

- [ ] **Step 2: Run it against the committed report to capture the baseline**

Run from the repo root:

```bash
python tools/reports/verify_lot_detail_report.py
```

Expected output (this is the baseline every later task must not regress):

```
title      : Lot Detail
parameters : [('LotId', '0')]
layout     : 20641 chars
data sources:
   Summary                tokens=['{LotId}']
   GenealogyAncestors     tokens=['{LotId}']
   GenealogyDescendants   tokens=['{LotId}']
   ShippedContainers      tokens=['{LotId}']
   Lifecycle              tokens=['{LotId}']
   Events                 tokens=['{LotId}']
```

There is also a seventh source keyed `Genealogy` in some parses — it is the dead
source D5 removes. Record whatever this command actually prints; the exact layout
char count and source order are the baseline, not the numbers above.

- [ ] **Step 3: Extract layout + SQL to source files**

Run this one-off (do not commit it — it only bootstraps the source files):

```bash
python -c "
import sys, io, os, json
sys.path.insert(0, 'tools/reports')
from verify_lot_detail_report import describe, REPORT_BIN
info = describe(REPORT_BIN)
os.makedirs('tools/reports/lot_detail', exist_ok=True)
io.open('tools/reports/lot_detail/layout.xml','w',encoding='utf-8',newline='\n').write(info['layout_xml'])
print('layout.xml written:', len(info['layout_xml']), 'chars')
for s in info['sources']:
    print(repr(s['key']), repr(s['tokens']), repr((s['sql'] or '')[:60]))
"
```

Expected: `layout.xml written: <N> chars`, then one line per data source with its SQL prefix.

The layout is extracted because it is 20KB of XML; the SQL is short enough to be
written out in full in the next step. **Cross-check the printed SQL prefixes
against the next step's `SUMMARY_SQL` / `EVENTS_SQL`** — if they differ, the
committed report has drifted from what this plan was written against, and the
printed version wins.

- [ ] **Step 4: Write `tools/reports/lot_detail/queries.py`**

`Summary` and `Events` are inline SQL; the other four are thin `EXEC` wrappers per
the project's "reports call read procs" rule. **Do not include the dead
`Genealogy` source** — D5 drops it, and Task 1's verify step accounts for that.

```python
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
```

- [ ] **Step 5: Write the generator `tools/reports/build_lot_detail_report.py`**

```python
"""Regenerate the Lot Detail report's data.bin from checked-in source.

The binary is an OUTPUT, never edited by hand. Run from the repo root:

    python tools/reports/build_lot_detail_report.py
    .\\scan.ps1

Clones the validated donor envelope (version-correct class/method signatures for
this gateway) and swaps in our title, parameters, data sources and layout.
"""
import io, os, sys, xml.dom.minidom

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(os.path.expanduser("~"), ".claude", "skills",
                                "ignition-reporting", "tools"))

from report_builder import ReportBuilder, RESOURCE_JSON   # noqa: E402
from lot_detail import queries                            # noqa: E402

REPO = os.path.abspath(os.path.join(HERE, "..", ".."))
REPORTS = os.path.join(REPO, "ignition", "projects", "MPP",
                       "com.inductiveautomation.reporting", "reports")
DONOR = os.path.join(REPORTS, "sample for claude", "data.bin")
OUT_DIR = os.path.join(REPORTS, "Lot Detail")
LAYOUT = os.path.join(HERE, "lot_detail", "layout.xml")
TITLE = "Lot Detail"          # MUST equal the folder name and the registry reportPath


def build():
    layout_xml = io.open(LAYOUT, encoding="utf-8").read()
    # A raw & / < / > in a literal throws RMException at RENDER time, which the
    # gateway surfaces only as a generic "invalid report". Fail here instead.
    xml.dom.minidom.parseString(layout_xml.encode("utf-8"))

    rb = ReportBuilder(DONOR)
    rb.set_title(TITLE)
    rb.set_parameters(queries.PARAMETERS)
    for src in queries.DATA_SOURCES:
        rb.add_query(src["key"], src["sql"], src["tokens"])
    rb.set_layout(layout_xml)
    rb.clear_snapshot()
    return rb.build()


def main():
    data = build()
    if not os.path.isdir(OUT_DIR):
        os.makedirs(OUT_DIR)
    open(os.path.join(OUT_DIR, "data.bin"), "wb").write(data)
    io.open(os.path.join(OUT_DIR, "resource.json"), "w",
            encoding="utf-8", newline="\n").write(RESOURCE_JSON)
    print("wrote %s (%d bytes)" % (os.path.join(OUT_DIR, "data.bin"), len(data)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
```

Add `tools/reports/lot_detail/__init__.py` (empty file) so `from lot_detail import queries` resolves.

- [ ] **Step 6: Regenerate and verify structure is unchanged**

```bash
python tools/reports/build_lot_detail_report.py && python tools/reports/verify_lot_detail_report.py
```

Expected: the same `title`, `parameters`, layout char count, and the same six data
keys with the same tokens as the Step 2 baseline — minus the dead `Genealogy`
source if Step 2 showed one. If any other line differs, the generator is not
faithful; fix it before continuing. **Do not proceed with a generator that does not
reproduce the report.**

- [ ] **Step 7: Write `tools/reports/README.md`**

```markdown
# Report build tooling

Ignition Reporting Module reports are committed as `data.bin` — a gzipped binary
object graph. **The binary is an output. Do not hand-edit it.**

Source of truth for the Lot Detail report:

| File | What |
|---|---|
| `lot_detail/layout.xml` | ReportMill page layout (points, 612x792 letter) |
| `lot_detail/queries.py` | Parameters + data sources (SQL, tokens, nesting) |
| `build_lot_detail_report.py` | Assembles them onto the donor envelope |
| `verify_lot_detail_report.py` | Parses a built `data.bin` and prints its structure |
| `nesting_builder.py` | Adds nested-child-query support to the skill's builder |

Regenerate and deploy:

```
python tools/reports/build_lot_detail_report.py
.\scan.ps1
```

`scan.ps1` DOES reload a changed report `data.bin` — no gateway restart.

Three things that fail silently and cost hours:

- A report resolves by its internal `setTitle`, NOT its folder name. Folder name,
  `setTitle`, and the `BlueRidge.Reports` registry `reportPath` must all match.
- A raw `&` / `<` / `>` in a layout literal throws `RMException` at render time,
  shown as a generic "invalid report". The generator XML-parses the layout first.
- Unresolved `@tokens@` and bad layout render BLANK and log nothing. Always render
  and look at the output; a clean load proves nothing.

The generic mechanics (binary format, codec, ReportMill vocabulary) live in the
global `ignition-reporting` skill; MPP-specific notes are in
`ignition-context-pack/10_reporting_module.md`.
```

- [ ] **Step 8: Commit**

```bash
git add tools/reports/README.md tools/reports/build_lot_detail_report.py tools/reports/verify_lot_detail_report.py tools/reports/lot_detail/__init__.py tools/reports/lot_detail/layout.xml tools/reports/lot_detail/queries.py "ignition/projects/MPP/com.inductiveautomation.reporting/reports/Lot Detail/data.bin"
git commit -m "refactor(reports): extract Lot Detail report into version-controlled source

The report existed only as a committed data.bin with no generator anywhere in the
repo, so changing it meant reverse-engineering the binary first. Layout XML and
SQL are now checked-in source files, with a build script that reproduces the
report and a verify script that asserts its structure. No behaviour change."
```

---

### Task 2: Nested-query support in a repo-local builder subclass

**Files:**
- Create: `tools/reports/nesting_builder.py`
- Create: `tools/reports/test_nesting_builder.py`

**Interfaces:**
- Consumes: `report_builder.ReportBuilder` (global skill, unmodified), its `_obj`, `_call`, `_str`, `_arraylist`, `C_SUBQ`, `C_PREP`, `C_QRDO`, `C_DSCFG`, `QUERY_TYPE_ID`.
- Produces: `NestingReportBuilder(ReportBuilder)` with `add_nested_query(data_key, sql, expr_tokens, children)` where `children` is `list[{"key","sql","tokens","children"}]`, recursive. Task 3 calls it.

- [ ] **Step 1: Write the failing test**

Create `tools/reports/test_nesting_builder.py`:

```python
"""Assert NestingReportBuilder emits a real setChildren SubQuery.

Run: python tools/reports/test_nesting_builder.py
"""
import os, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

from nesting_builder import NestingReportBuilder          # noqa: E402
from verify_lot_detail_report import describe             # noqa: E402

REPO = os.path.abspath(os.path.join(HERE, "..", ".."))
DONOR = os.path.join(REPO, "ignition", "projects", "MPP",
                     "com.inductiveautomation.reporting", "reports",
                     "sample for claude", "data.bin")


def test_nested_child_is_emitted():
    rb = NestingReportBuilder(DONOR)
    rb.set_title("NestTest")
    rb.set_parameters([("LotId", "Long", "0")])
    rb.add_nested_query(
        "Parent", "EXEC Lots.Lot_GetGenealogyEdgeTree ?, N'Ancestors'", ["{LotId}"],
        children=[{"key": "Child", "sql": "EXEC Lots.Lot_GetLifecycle ?",
                   "tokens": ["{RelatedLotId}"], "children": []}])
    rb.set_layout("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<document version=\"14\"/>")
    rb.clear_snapshot()
    path = os.path.join(tempfile.mkdtemp(), "data.bin")
    open(path, "wb").write(rb.build())

    info = describe(path)
    parents = [s for s in info["sources"] if s["key"] == "Parent"]
    assert len(parents) == 1, "expected one Parent source, got %r" % (info["sources"],)
    parent = parents[0]
    assert parent["tokens"] == ["{LotId}"], parent["tokens"]
    assert len(parent["children"]) == 1, "no nested child emitted: %r" % (parent,)
    child = parent["children"][0]
    assert child["key"] == "Child", child["key"]
    assert child["tokens"] == ["{RelatedLotId}"], child["tokens"]
    assert "Lot_GetLifecycle" in child["sql"], child["sql"]
    print("PASS test_nested_child_is_emitted")


if __name__ == "__main__":
    test_nested_child_is_emitted()
```

- [ ] **Step 2: Run it to verify it fails**

```bash
python tools/reports/test_nesting_builder.py
```

Expected: `ModuleNotFoundError: No module named 'nesting_builder'`

- [ ] **Step 3: Write the implementation**

Create `tools/reports/nesting_builder.py`:

```python
"""Nested-child-query support for Ignition report data sources.

The global ignition-reporting skill's ReportBuilder.add_query emits FLAT root
queries only. A nested child runs once per PARENT ROW, with its `?` bound to a
parent row COLUMN rather than to a report parameter -- which is what lets the Lot
Detail report show each ancestor LOT's own process history.

Subclassed here rather than patched into the skill: the skill lives outside this
repo and is shared with other projects. If this proves out, upstream it.

Emitted shape (verified against a Designer-authored donor on 8.3.5 and against two
production 8.1 customer reports):

    QueryReportDataObject
      setRootQuery -> SubQuery
                        setChildren    arraylist[ SubQuery, ... ]   <- may be empty
                        setDataKey     str
                        setQueryConfig PrepStmtQueryConfig

Setter order matters for byte-similarity with Designer output: setChildren,
setDataKey, setQueryConfig.
"""
import os, sys

sys.path.insert(0, os.path.join(os.path.expanduser("~"), ".claude", "skills",
                                "ignition-reporting", "tools"))

from report_builder import (ReportBuilder, C_SUBQ, C_PREP, C_QRDO, C_DSCFG,   # noqa: E402
                            QUERY_TYPE_ID)


class NestingReportBuilder(ReportBuilder):

    def _prep(self, sql, expr_tokens):
        return self._obj(C_PREP, [
            self._call("setExpressions",
                       self._arraylist([self._str(t) for t in expr_tokens])),
            self._call("setQuery", self._str(sql)),
            self._call("setSyntaxClassname", self._str(self._syntax)),
        ])

    def _subquery(self, data_key, sql, expr_tokens, children):
        """Build one SubQuery, recursing into children. An empty children list is
           emitted rather than omitted -- that is what Designer writes."""
        kids = [self._subquery(c["key"], c["sql"], c["tokens"], c.get("children") or [])
                for c in (children or [])]
        return self._obj(C_SUBQ, [
            self._call("setChildren", self._arraylist(kids)),
            self._call("setDataKey", self._str(data_key)),
            self._call("setQueryConfig", self._prep(sql, expr_tokens)),
        ])

    def add_nested_query(self, data_key, sql, expr_tokens, children=None):
        """Top-level SQL data source that may carry per-parent-row child queries.

        children: list of {"key", "sql", "tokens", "children"} dicts, recursive.
        A child's tokens name PARENT ROW COLUMNS, e.g. {RelatedLotId}."""
        if not hasattr(self, "_ds_items"):
            self._ds_items = []
        qrdo = self._obj(C_QRDO, [
            self._call("setRootQuery",
                       self._subquery(data_key, sql, expr_tokens, children)),
        ])
        self._ds_items.append(self._obj(C_DSCFG, [
            self._call("setConfigObject", qrdo),
            self._call("setDataSourceId", self._str(QUERY_TYPE_ID)),
        ]))
```

- [ ] **Step 4: Run the test to verify it passes**

```bash
python tools/reports/test_nesting_builder.py
```

Expected: `PASS test_nested_child_is_emitted`

If it fails with a `KeyError: 'setChildren'` or `'setExpressions'` from `_call`,
the donor is missing that setter signature — re-check that
`reports/sample for claude/data.bin` still contains both a nested query and a
query whose SQL references a `{parameter}`.

- [ ] **Step 5: Commit**

```bash
git add tools/reports/nesting_builder.py tools/reports/test_nesting_builder.py
git commit -m "feat(reports): nested child-query support for report data sources

The skill's ReportBuilder emits flat root queries only. A nested child runs once
per parent row with its ? bound to a parent row column, which is what lets a
report show per-ancestor detail. Subclassed in-repo so the shared global skill
stays untouched."
```

---

### Task 3: Wire the `AncestorSteps` nested data source (data only)

Data side first, layout untouched — so a failure here is unambiguously a data
problem, not a layout one. The report renders exactly as before; the nested
dataset simply exists.

**Files:**
- Modify: `tools/reports/lot_detail/queries.py`
- Modify: `tools/reports/build_lot_detail_report.py`
- Create: `ignition/projects/MPP/ignition/timer/DevRenderReport/handleTimerEvent.py`
- Create: `ignition/projects/MPP/ignition/timer/DevRenderReport/resource.json`

**Interfaces:**
- Consumes: `NestingReportBuilder.add_nested_query` (Task 2).
- Produces: a `GenealogyAncestors` source carrying one child keyed `AncestorSteps`. Task 4's layout binds `list-key="AncestorSteps"`.

- [ ] **Step 1: Add the child to `queries.py`**

Replace the `GenealogyAncestors` entry in `DATA_SOURCES` with:

```python
    {"key": "GenealogyAncestors",
     "sql": "EXEC Lots.Lot_GetGenealogyEdgeTree ?, N'Ancestors'",
     "tokens": ["{LotId}"],
     # Runs once per ancestor row. {RelatedLotId} is a COLUMN of the parent row,
     # not a report parameter -- this is what gives each ancestor its own history.
     "children": [
         {"key": "AncestorSteps",
          "sql": "EXEC Lots.Lot_GetLifecycle ?",
          "tokens": ["{RelatedLotId}"],
          "children": []},
     ]},
```

- [ ] **Step 2: Switch the generator to the nesting builder**

In `tools/reports/build_lot_detail_report.py` replace the import and the build loop:

```python
from nesting_builder import NestingReportBuilder          # noqa: E402
from report_builder import RESOURCE_JSON                  # noqa: E402
```

```python
    rb = NestingReportBuilder(DONOR)
    rb.set_title(TITLE)
    rb.set_parameters(queries.PARAMETERS)
    for src in queries.DATA_SOURCES:
        rb.add_nested_query(src["key"], src["sql"], src["tokens"],
                            src.get("children") or [])
```

- [ ] **Step 3: Regenerate and verify the nesting appears**

```bash
python tools/reports/build_lot_detail_report.py && python tools/reports/verify_lot_detail_report.py
```

Expected — note the indented child:

```
data sources:
   Summary                tokens=['{LotId}']
   GenealogyAncestors     tokens=['{LotId}']
       AncestorSteps          tokens=['{RelatedLotId}']
   GenealogyDescendants   tokens=['{LotId}']
   ShippedContainers      tokens=['{LotId}']
   Lifecycle              tokens=['{LotId}']
   Events                 tokens=['{LotId}']
```

- [ ] **Step 4: Create the one-shot render harness**

`system.report.executeReport` is gateway-scope only. Create
`ignition/projects/MPP/ignition/timer/DevRenderReport/handleTimerEvent.py`:

```python
# DEV ONLY - one-shot report render harness. Deleted in Task 8.
# Enable via resource.json, run scan.ps1, wait one tick, then disable again.
def handleTimerEvent():
	import os
	out = "C:\\Temp\\report_render"
	if not os.path.isdir(out):
		os.makedirs(out)
	for lotId in (254, 10270, 10274):
		try:
			png = system.report.executeReport("Lot Detail", "MPP", {"LotId": lotId}, "png")
			f = open(os.path.join(out, "lot_detail_%d.png" % lotId), "wb")
			f.write(png)
			f.close()
			system.util.getLogger("DevRenderReport").info("rendered LotId=%d" % lotId)
		except Exception, e:
			system.util.getLogger("DevRenderReport").error(
				"render failed LotId=%d: %s" % (lotId, str(e)))
```

`resource.json` (`enabled: false` — flip to `true` only when rendering):

```json
{
  "scope": "G",
  "version": 1,
  "restricted": false,
  "overridable": true,
  "files": ["handleTimerEvent.py"],
  "attributes": {
    "delay": 20000,
    "fixedDelay": true,
    "sharedThread": true,
    "enabled": false
  }
}
```

- [ ] **Step 5: Render the baseline and look at it**

Set `"enabled": true`, then:

```bash
./scan.ps1
```

Wait ~25s, then read all three PNGs to confirm the report still renders as it
did before (5 pages, ancestors table lot-level, no visual change yet):

```bash
ls -la /c/Temp/report_render/
```

Open each `C:\Temp\report_render\lot_detail_*.png` with the Read tool and
**look at them**. Expected: unchanged from today's report. If a page
is blank that was not blank before, the nested data source broke rendering — stop
and fix before Task 4.

Set `"enabled": false` and `./scan.ps1` again.

- [ ] **Step 6: Commit**

```bash
git add tools/reports/lot_detail/queries.py tools/reports/build_lot_detail_report.py ignition/projects/MPP/ignition/timer/DevRenderReport "ignition/projects/MPP/com.inductiveautomation.reporting/reports/Lot Detail/data.bin"
git commit -m "feat(reports): nested AncestorSteps data source on Lot Detail

Runs Lot_GetLifecycle once per ancestor row, bound to the parent row's
RelatedLotId. Data side only - layout unchanged, so this is verifiably a no-op
visually. Adds a disabled one-shot render harness (removed once verified)."
```

---

### Task 4: Ancestors page — part-number band + nested step table

> ## ⚠️ STOP — DO NOT EXECUTE THIS TASK AS WRITTEN (2026-08-25)
>
> The XML below was authored from ~10 minutes of reading two sample reports and
> written here as verbatim code to transcribe. **It was never rendered before being
> put in this plan, and it does not work.** Executing it produced commit `80f87484`,
> which renders LOT 10270 as **19 of 23 pages** (a page break before every step row,
> from `startrowbreak="true"` on the nested table) with the part-number band frozen
> on ancestor 1's value.
>
> Report layout against ReportMill is **not a delegable transcription task** — it
> needs interactive render → look → adjust cycles. Treat the XML below as a rough
> starting point only.
>
> Read `notes/2026-08-25_lot-detail-report-handoff.md` before touching this.
> Ruled out already: the frozen band is **not** an input-ordering problem.

**Files:**
- Modify: `tools/reports/lot_detail/layout.xml`

**Interfaces:**
- Consumes: data keys `GenealogyAncestors` (columns `RelatedLotId`, `RelatedLotName`, `ItemId`, `PartNumber`, `RelationshipName`, `PieceCount`, `UomCode`, `Depth`, `Direction`) and its child `AncestorSteps` (columns `EventAtEt`, `EventTypeName`, `LocationName`, `OperatorName`, `Description`).
- Produces: no interface for later tasks.

- [ ] **Step 1: Replace the ancestors `<table>` with a `<table-group>`**

In `layout.xml`, find the element beginning
`<table x="36" y="312" width="540" height="420" list-key="GenealogyAncestors">`
and replace that whole element (through its closing `</table>`) with the block
below.

Three rules this markup depends on, each of which fails **silently** if broken:
`<tablerow title>` must read exactly `"<groupingKey> Header|Details"`; the first
`<grouping key>` names the dataset and later ones key on a *column*; a table
nested inside its parent uses the **bare** child key.

Per the page-break constraint, the ancestor detail row restates LOT name and part
number so a continuation page is never orphaned timestamps.

```xml
<table-group x="36" y="312" width="540" height="420" useStroke="false">
<table width="540" height="420" list-key="GenealogyAncestors" startrowbreak="true">
<grouping key="GenealogyAncestors" details="true" />
<grouping key="PartNumber" header="true" details="true" />
<tablerow width="540" height="1" title="GenealogyAncestors Details"><row-cell-text width="540" height="1" /></tablerow>
<tablerow y="8" width="540" height="20" title="PartNumber Header"><row-cell-text width="540" height="20"><font logical_name="Helvetica" style="1" size="11" /><color value="#126680" /><pgraph align="left" /><string>@PartNumber@</string></row-cell-text></tablerow>
<tablerow y="30" width="540" height="17" title="PartNumber Details"><row-cell-text x="0" width="44" height="17"><font logical_name="Helvetica" style="0" size="9.5" /><color value="#1b2430" /><pgraph align="right" /><string>@Depth@</string></row-cell-text><row-cell-text x="44" width="140" height="17"><font logical_name="Helvetica" style="1" size="9.5" /><color value="#1b2430" /><pgraph align="left" /><string>@RelatedLotName@</string></row-cell-text><row-cell-text x="184" width="130" height="17"><font logical_name="Helvetica" style="0" size="9.5" /><color value="#1b2430" /><pgraph align="left" /><string>@PartNumber@</string></row-cell-text><row-cell-text x="314" width="104" height="17"><font logical_name="Helvetica" style="0" size="9.5" /><color value="#1b2430" /><pgraph align="left" /><string>@RelationshipName@</string></row-cell-text><row-cell-text x="418" width="60" height="17"><font logical_name="Helvetica" style="0" size="9.5" /><color value="#1b2430" /><pgraph align="right" /><string>@PieceCount@</string><format type="number" pattern="#,##0" null-string="&lt;N/A&gt;" /></row-cell-text><row-cell-text x="478" width="62" height="17"><font logical_name="Helvetica" style="0" size="9.5" /><color value="#1b2430" /><pgraph align="left" /><string>@UomCode@</string></row-cell-text></tablerow>
<table x="24" width="516" height="380" list-key="AncestorSteps" startrowbreak="true">
<grouping key="AncestorSteps" header="true" details="true" />
<tablerow width="516" height="16" title="AncestorSteps Header"><row-cell-text x="0" width="110" height="16"><font logical_name="Helvetica" style="1" size="8.5" /><color value="#6b788f" /><pgraph align="left" /><string>Step time (ET)</string></row-cell-text><row-cell-text x="110" width="170" height="16"><font logical_name="Helvetica" style="1" size="8.5" /><color value="#6b788f" /><pgraph align="left" /><string>Event</string></row-cell-text><row-cell-text x="280" width="146" height="16"><font logical_name="Helvetica" style="1" size="8.5" /><color value="#6b788f" /><pgraph align="left" /><string>Location</string></row-cell-text><row-cell-text x="426" width="90" height="16"><font logical_name="Helvetica" style="1" size="8.5" /><color value="#6b788f" /><pgraph align="left" /><string>Operator</string></row-cell-text></tablerow>
<tablerow y="16" width="516" height="15" title="AncestorSteps Details"><row-cell-text x="0" width="110" height="15"><font logical_name="Helvetica" style="0" size="8.5" /><color value="#1b2430" /><pgraph align="left" /><string>@EventAtEt@</string><format type="date" pattern="MMM d  HH:mm:ss" null-string="&lt;N/A&gt;" /></row-cell-text><row-cell-text x="110" width="170" height="15"><font logical_name="Helvetica" style="0" size="8.5" /><color value="#1b2430" /><pgraph align="left" /><string>@EventTypeName@</string></row-cell-text><row-cell-text x="280" width="146" height="15"><font logical_name="Helvetica" style="0" size="8.5" /><color value="#1b2430" /><pgraph align="left" /><string>@LocationName@</string></row-cell-text><row-cell-text x="426" width="90" height="15"><font logical_name="Helvetica" style="0" size="8.5" /><color value="#1b2430" /><pgraph align="left" /><string>@OperatorName@</string></row-cell-text></tablerow>
</table>
</table>
</table-group>
```

- [ ] **Step 2: Update the section heading above the table**

The existing heading reads `Made From  &#183;  Ancestors`. Leave the heading text
alone — Task 5 appends the count to the subtitle, not here.

- [ ] **Step 3: Regenerate (the generator XML-validates the layout)**

```bash
python tools/reports/build_lot_detail_report.py
```

Expected: `wrote …\Lot Detail\data.bin (<N> bytes)`. An
`xml.parsers.expat.ExpatError` here means a malformed tag or an unescaped `&` —
fix the XML; this check exists precisely so it does not become a silent render
failure.

- [ ] **Step 4: Render and LOOK**

Set `DevRenderReport` `"enabled": true`, `./scan.ps1`, wait ~25s, then Read the
PNGs.

Expected for `lot_detail_10270.png` (the primary test — four ancestors): four
part-number bands, each with its ancestor LOT row and an indented step table of
that LOT's own lifecycle rows beneath it. This is the render that proves the
feature works.

Expected for `lot_detail_10274.png`: page 1 shows one part-number band `5G0-c`,
one ancestor row `000000024`, and beneath it an indented step table with that
casting's six lifecycle rows (Die Cast LOT Opened → Machining IN Picked).

Expected for `lot_detail_254.png`: page 1's ancestors area is empty (LOT 254 is a
die-cast origin), and pages 2–3 are unchanged.

If the step table is missing, the most likely cause in order: (a) a `<tablerow
title>` that does not exactly match `"<groupingKey> Header"` / `" Details"`,
(b) the nested table using a dotted key instead of the bare `AncestorSteps`,
(c) the child data source not present — re-run `verify_lot_detail_report.py`.

Set `"enabled": false`, `./scan.ps1`.

- [ ] **Step 5: Commit**

```bash
git add tools/reports/lot_detail/layout.xml "ignition/projects/MPP/com.inductiveautomation.reporting/reports/Lot Detail/data.bin"
git commit -m "feat(reports): per-ancestor process history on the Lot Detail report

Ancestors page becomes a part-number band over tree-ordered LOT rows, each with
its own lifecycle steps nested beneath. Ancestor rows restate LOT name and part
number so a block that splits across a page break is still readable."
```

---

### Task 5: Section counts in page subtitles

**Files:**
- Modify: `tools/reports/lot_detail/queries.py`
- Modify: `tools/reports/lot_detail/layout.xml`

**Interfaces:**
- Consumes: nothing from earlier tasks beyond the `Summary` data key.
- Produces: `Summary` columns `ancestor_count`, `descendant_count`, `container_count`, `event_count`.

- [ ] **Step 1: Add counts to `SUMMARY_SQL` in `queries.py`**

Insert these four scalar sub-selects into the existing `SELECT` list, immediately
before `FROM Lots.Lot l`, keeping the trailing comma on the preceding column. The
recursive CTEs mirror the section procs' own walks (`Lots.LotGenealogy` edges,
path-string cycle guard) so a count can never disagree with its table.

```sql
  ,(SELECT COUNT(*) FROM Lots.LotGenealogyClosure c
      WHERE c.DescendantLotId = l.Id AND c.Depth > 0) AS ancestor_count
  ,(SELECT COUNT(*) FROM Lots.LotGenealogyClosure c
      WHERE c.AncestorLotId = l.Id AND c.Depth > 0) AS descendant_count
  ,(SELECT COUNT(*) FROM Lots.ContainerTray ct
      WHERE ct.FinishedGoodLotId = l.Id
         OR ct.FinishedGoodLotId IN (
              SELECT c.DescendantLotId FROM Lots.LotGenealogyClosure c
              WHERE c.AncestorLotId = l.Id AND c.Depth > 0)) AS container_count
  ,(SELECT COUNT(*) FROM Workorder.ProductionEvent pe WHERE pe.LotId = l.Id) AS event_count
```

`Lots.LotGenealogyClosure` (`AncestorLotId`, `DescendantLotId`, `Depth`) is the
maintained transitive closure, with a `Depth = 0` self-row per LOT — hence the
`Depth > 0` filter on every count. Using it keeps these as cheap index lookups
instead of four recursive walks, and gives the exact full-depth answer.

**These counts are DISTINCT LOTS; the ancestors/descendants tables list PATHS.**
`Lot_GetGenealogyEdgeTree` emits one row per distinct path from the subject, so on
a diamond/merge topology a LOT reachable by two paths appears twice in the table
while the closure counts it once. That is deliberate — "Ancestors: 3 LOTs" is the
more meaningful headline — and it is why the subtitles below say "LOTs" explicitly.
Never SUM the consumed/contributed column to derive a total; per-path rows
double-count shared upstream edges.

- [ ] **Step 2: Verify the SQL runs before building anything**

```bash
sqlcmd -S localhost -d MPP_MES_Dev -b -I -C -W -s "|" -Q "<paste the full new SUMMARY_SQL with ? replaced by 254>"
```

Expected: one row, with `ancestor_count=0`, `descendant_count=5`,
`container_count=5`, `event_count=3` for LOT 254, and `4 / 0 / 1 / 0` for LOT 10270. If those do not match the
test-LOT table above, stop — the counts disagree with the tables.

- [ ] **Step 3: Append counts to each page subtitle in `layout.xml`**

Page 1's `@Summary.lot_name@` header line and the four later pages' subtitle lines
(`@Summary.lot_name@  &#183;  @Summary.part_number@`) each gain their section's
count. Edit each subtitle `<string>` as follows:

| Page | New `<string>` content |
|---|---|
| 1 (ancestors) | `@Summary.lot_name@  &#183;  Ancestors: @Summary.ancestor_count@` |
| 2 (descendants) | `@Summary.lot_name@  &#183;  @Summary.part_number@  &#183;  Used in: @Summary.descendant_count@ LOTs` |
| 3 (containers) | `@Summary.lot_name@  &#183;  @Summary.part_number@  &#183;  Containers: @Summary.container_count@` |
| 5 (production events) | `@Summary.lot_name@  &#183;  @Summary.part_number@  &#183;  Events: @Summary.event_count@` |

Page 4 (Lifecycle) is the subject LOT's own history and needs no count. Use
`&#183;` for the middle dot, never a raw `·`, and never a raw `&`.

- [ ] **Step 4: Regenerate, render, LOOK**

```bash
python tools/reports/build_lot_detail_report.py
```

Enable `DevRenderReport`, `./scan.ps1`, wait ~25s, Read the PNGs.

Expected `lot_detail_254.png`: page 1 subtitle `000000001 · Ancestors: 0`, page 2
`… Used in: 5 LOTs`, page 3 `… Containers: 5`.
Expected `lot_detail_10270.png`: page 1 `… Ancestors: 4`, page 2 `… Used in: 0
LOTs`, page 3 `… Containers: 1`.
Expected `lot_detail_10274.png`: page 1 `… Ancestors: 1`, page 2 `… Used in: 0
LOTs`, page 3 `… Containers: 0`.

A subtitle rendering `<N/A>` means the column name does not match the SQL alias.
Disable the timer, `./scan.ps1`.

- [ ] **Step 5: Commit**

```bash
git add tools/reports/lot_detail/queries.py tools/reports/lot_detail/layout.xml "ignition/projects/MPP/com.inductiveautomation.reporting/reports/Lot Detail/data.bin"
git commit -m "feat(reports): section counts in Lot Detail page subtitles

An empty ReportMill table renders as a bare header over a void with no 'no rows'
message, so a legitimately-empty section looked broken. Each page subtitle now
carries its own count, which is what started this investigation."
```

---

### Task 6: Drop the dead data source

**Files:**
- Modify: `tools/reports/lot_detail/queries.py` (only if Task 1 Step 2 showed a `Genealogy` source)

- [ ] **Step 1: Confirm nothing references it**

```bash
grep -c "Genealogy@\|list-key=\"Genealogy\"" tools/reports/lot_detail/layout.xml
```

Expected: `0`. (`GenealogyAncestors` / `GenealogyDescendants` are different keys
and DO appear — the grep pattern above is anchored so it does not match them.)

- [ ] **Step 2: Confirm `queries.py` has no `Genealogy` entry**

Task 1 Step 4 already excluded it. Verify:

```bash
python tools/reports/verify_lot_detail_report.py
```

Expected: no bare `Genealogy` line in the data-source list. If one appears, remove
that entry from `DATA_SOURCES`, regenerate, and re-run.

- [ ] **Step 3: Commit (skip if nothing changed)**

```bash
git add tools/reports/lot_detail/queries.py "ignition/projects/MPP/com.inductiveautomation.reporting/reports/Lot Detail/data.bin"
git commit -m "chore(reports): drop the unreferenced Genealogy data source

A legacy flat union query no page binds to. Orphaned donor parameter strings
(StartDate/EndDate/ShiftID) fall out of the rebuild automatically."
```

---

### Task 7: Make any LOT reachable from the picker

The picker is `SELECT TOP 100 … ORDER BY CreatedAt DESC`, so a LOT becomes
progressively less reachable as it ages — backwards for a report whose purpose is
investigating something that shipped months ago.

**Files:**
- Modify: `ignition/projects/Core/ignition/script-python/BlueRidge/Reports/code.py`
- Modify: `ignition/projects/MPP/com.inductiveautomation.perspective/views/BlueRidge/Views/Reports/view.json`

**Interfaces:**
- Consumes: `BlueRidge.Lots.Lot.getByName(lotName)` (exists, `Lot/code.py:503`), returns a dict or `None`.
- Produces: `composeParams` accepting `lotId` as an int OR a LOT-name string.

- [ ] **Step 1: Make `composeParams` resolve a typed/scanned name**

In `BlueRidge/Reports/code.py`, replace the `lot_detail` branch of `composeParams`:

```python
        if selectedKey == "lot_detail":
            return {"LotId": _resolveLotId(lotId)}
```

and add above `composeParams`:

```python
def _resolveLotId(lotId):
    """The LOT dropdown allows custom options, so a scanned/typed LOT NAME arrives
    as a plain string instead of an option value. Resolve it to an id.

    Returns 0 for unresolvable input -- the report then renders its own empty
    state rather than the Report Viewer rejecting the params outright. The view's
    selectReport toasts on 0 so the operator is told, because silently rendering
    an empty report is the exact failure this change exists to remove."""
    if lotId is None or lotId == "":
        return 0
    try:
        return int(lotId)
    except (ValueError, TypeError):
        pass
    try:
        row = BlueRidge.Lots.Lot.getByName(str(lotId).strip())
        if row and row.get("Id"):
            return int(row.get("Id"))
    except (Exception, _JavaThrowable) as e:
        logger.warn("_resolveLotId failed for %r: %s" % (lotId, str(e)))
    return 0
```

- [ ] **Step 2: Let the dropdown accept a scanned or typed LOT**

In `Views/Reports/view.json`, the `LotDropdown` component's `props` block gains two
keys (the project's standing rule is that "scan or dropdown" is ONE dropdown with
custom options plus search, not a second scan field):

```json
    "props": {
      "allowCustomOptions": true,
      "search": true,
      "placeholder": "Scan or select LOT",
      "style": {
        "classes": "pf-field-select"
      }
    }
```

Leave `propConfig` untouched. `allowCustomOptions` is the verified key —
`allowCustomValues` is not a real prop and fails silently.

- [ ] **Step 3: Deploy and check the resolver directly**

```bash
./scan.ps1
```

Then confirm the resolver handles all three input shapes, via the gateway log or
Designer Script Console:

```python
print BlueRidge.Reports.composeParams("lot_detail", None, None, None, 254)
print BlueRidge.Reports.composeParams("lot_detail", None, None, None, "000000001")
print BlueRidge.Reports.composeParams("lot_detail", None, None, None, "NOPE-999")
```

Expected: `{'LotId': 254}`, `{'LotId': 254}`, `{'LotId': 0}`.

- [ ] **Step 4: Confirm end-to-end in the browser**

Open `http://localhost:8088/data/perspective/client/MPP/shop-floor/reports`, choose
the Lot Detail tile, type `000000001` into the LOT field, and confirm the viewer
renders the populated report — the same LOT that was previously unreachable
because it is not in the newest 100.

- [ ] **Step 5: Commit**

```bash
git add ignition/projects/Core/ignition/script-python/BlueRidge/Reports/code.py ignition/projects/MPP/com.inductiveautomation.perspective/views/BlueRidge/Views/Reports/view.json
git commit -m "fix(reports): make any LOT reachable from the Lot Detail picker

The picker was TOP 100 ORDER BY CreatedAt DESC, so a LOT got progressively less
reachable as it aged - backwards for a traceability report. The dropdown now
accepts a scanned or typed LOT name, resolved server-side, and reports an
unresolvable name instead of rendering an empty report."
```

---

### Task 8: Remove the harness and close out

**Files:**
- Delete: `ignition/projects/MPP/ignition/timer/DevRenderReport/`
- Modify: `docs/superpowers/specs/2026-08-25-lot-detail-report-genealogy-nesting-design.md`
- Modify: `PROJECT_STATUS.md`

- [ ] **Step 1: Final render of both test LOTs**

Enable `DevRenderReport`, `./scan.ps1`, wait ~25s, Read all three PNGs one last
time and
confirm against the spec's verification list: nested step block present and
readable, part-number band present, counts correct, pages 2–5 unchanged.

- [ ] **Step 2: Record what the page break actually did**

While looking at a report whose ancestor block spans a page break, note whether
the part-number band and step-table column headers repeated on the continuation
page. Add one line to the spec's verification section stating the observed
behaviour, replacing the assumption. If no test LOT produces a break, say that
explicitly rather than leaving it implied.

- [ ] **Step 3: Delete the harness**

```bash
git rm -r "ignition/projects/MPP/ignition/timer/DevRenderReport"
./scan.ps1
```

Confirm the gateway log shows no `DevRenderReport` errors after the scan.

- [ ] **Step 4: Update spec status and PROJECT_STATUS**

Set the spec's `**Status:**` line to
`Implemented and render-verified 2026-08-25`. Append a PROJECT_STATUS entry
covering: the report was never broken; the picker was the real defect; the report
now has a version-controlled generator; and nested report tables are now a known,
documented technique.

- [ ] **Step 5: Commit**

```bash
git add -- docs/superpowers/specs/2026-08-25-lot-detail-report-genealogy-nesting-design.md PROJECT_STATUS.md
git commit -m "docs(reports): close out Lot Detail genealogy nesting

Removes the dev render harness, records the observed page-break behaviour against
the assumption the design was built on, and notes that report edits now go through
a checked-in generator rather than hand-edited binaries."
```

---

## Notes for the implementer

- **The binary is an output.** After Task 1, never hand-edit `data.bin`. Change
  `queries.py` or `layout.xml` and re-run the generator.
- **`scan.ps1` reloads a changed report** — no gateway restart. If a change seems
  not to take, suspect the title-match rule before suspecting the reload.
- **When a section renders blank**, check in this order: (1) `<tablerow title>`
  exactly matches `"<groupingKey> Header|Details"`, (2) the data key spelling in
  `list-key`, (3) `verify_lot_detail_report.py` shows the source actually exists,
  (4) the underlying proc returns rows for that LOT in `MPP_MES_Dev`.
- **`Lot_GetGenealogyEdgeTree` emits one row per distinct PATH**, not per node. A
  node reachable by two paths appears twice. Never SUM `PieceCount` across rows.
- If the builder extension turns out to be a dead end, the spec records a
  fallback: one flat pre-joined query with three `<grouping>` levels, no builder
  change at all.
