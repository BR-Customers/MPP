# Ignition Reporting Module — MPP overlay

Read when building a **Reporting Module report** (PDF/print: rejects, die-shot, downtime,
production, Honda genealogy/shipping-history exports) — NOT Perspective dashboards. The
generic how-to lives in the globally-installed **`ignition-reporting` skill** (the reverse-
engineered `data.bin` codec, `ReportBuilder`, ReportMill layout helpers, author→deploy→verify
workflow). This file is only the **MPP-specific** deltas; the skill is the source of truth for
mechanics. If the skill isn't loaded (older session), its tools are at
`~/.claude/skills/ignition-reporting/tools/`.

## Validated donor (use this to clone every report envelope)

- **Donor:** `ignition/projects/MPP/com.inductiveautomation.reporting/reports/sample for claude/data.bin`
- **Codec status:** round-trips this donor **byte-for-byte** (inner stream + element tree),
  verified 2026-08-07 against **`framework.version 8.3.5.2026040611-rc1`** (our gateway). The
  version-correct class/method strings in this envelope are what you clone — never fabricate
  the binary from zero. `ReportBuilder("…/sample for claude/data.bin")` is the starting point.
- If the codec ever fails to round-trip after a gateway upgrade, re-validate (and fix the codec
  against the skill's `references/binary-format.md`) BEFORE generating anything.
- **Donor completeness gotcha:** `ReportBuilder` clones each setter *signature* from the donor, so
  the donor must actually contain: ≥1 **parameter** (any type — the Designer has no "Integer"; use
  **Long** for BIGINT ids) AND ≥1 **query data source whose SQL references a parameter** (e.g.
  `SELECT 1 WHERE 1 = {ShiftID}`) — a param-less query never emits `setExpressions`. If a needed
  setter is missing, the signatures are **arg-type-only** (every `List` setter shares one sig, every
  `String` setter another — verified), so you may borrow it: `rb._sigs["setExpressions"] =
  rb._sigs["setParameters"]`. Report params bind positionally to SQL `?` via the token list.

## Gotchas that cost hours (learned 2026-08-10, building the Reports suite)

- **A report resolves by its internal `setTitle`, NOT its folder name.** The Report Viewer
  `source` (and `executeReport(path,...)`) match the report's title. If you rename the folder,
  you MUST rebuild with `set_title` = the new folder name, or the viewer shows *"Enter a valid
  report in the source property"*. Keep **folder name == set_title == the view's `source`**.
- **Escape `&` / `<` / `>` in every layout literal** — wrap literals in `L.esc(...)`; pass only
  `@tokens@` raw. A raw `&` yields `RMException: The entity name must immediately follow the '&'`
  at *render* time (not load), surfaced as a generic "invalid report". **Validate the layout XML
  parses before deploy:** `xml.dom.minidom.parseString(layout_xml.encode('utf-8'))`.
- **Never hand the Report Viewer an empty `params` dict `{}`** — it rejects the source. The
  landing page's `composeParams` always returns a non-empty dict (a param-less report gets a
  harmless defaulted param, e.g. `{"MinPieces": 0}`, and the report declares that parameter).
- **`scan.ps1` DOES reload changed report `data.bin`** (no gateway restart needed) — a bad
  earlier diagnosis; the symptom was the title mismatch above, not a reload failure.
- Guard the Perspective glue: `BlueRidge.Reports` functions catch `(Exception,
  java.lang.Throwable)` and return safe fallbacks (`[]`, non-empty params dict); the view's
  `printPdf`/`selectReport` wrap in try/except + toast, so a data/gateway hiccup degrades cleanly.

## Deploy — scan-sync, NOT docker

The skill's deploy section assumes a Docker gateway (`docker cp` + `docker compose restart`).
**MPP does not.** Our gateway is the symlinked file-based project synced with `.\scan.ps1`
(see `09_repo_gateway_sync.md`; memory: local sync = `scan.ps1` only, never `pull.ps1` /
`C:\MPP`). So the deploy step is:

1. Write `data.bin` + `resource.json` to
   `ignition/projects/MPP/com.inductiveautomation.reporting/reports/<Name>/` (reports live in
   the **MPP** runtime project — the donor does).
2. Run `.\scan.ps1` to push the resource to the gateway. No container copy, no gateway restart.
3. `resource.json`: keep the skill's shape. A **complete** `lastModification` (actor+timestamp)
   is fine — the donor has one; the skill's warning is specifically about a *partial*
   `lastModification`, which can NPE the whole gateway on startup.

## Data sources — call our read procs, don't re-embed logic

Report data sources are flat PrepStmt SQL with `?` bound positionally to the expression-token
list. Per our standing rule (**business logic in SQL, read via procs; no domain logic in the
presentation layer**), a report query SHOULD `EXEC` an existing read proc or select from a
view rather than re-implementing joins/filters inline — the same discipline as a Named Query.
(Reports do **not** use Named Queries — the "all NQs in Core" topology rule does not apply to
report data sources; the SQL is embedded in the report resource itself.)

- Timestamps: our procs already convert UTC→Eastern at the read boundary
  (`AT TIME ZONE`). Prefer proc output so report cells show ET; if you must format a raw UTC
  column in the layout, convert in the query, not the ReportMill `<format>`.
- Parameters bind by JDBC type — type numeric filters `Integer`, date windows `Date`
  (skill's object-graph ref). Default values are Ignition **expressions**
  (`now()`, `dateArithmetic(now(),-7,"day")`).

## Verify-by-render on the MPP gateway

`system.report.executeReport(path, project, paramsDict, "png")` runs in **gateway scope** only
— you can't call it from an external script. Trigger it from a one-shot gateway script (a
disabled timer you enable once, or a dev tag-change) and pull the PNG back out, then **look at
it** — bad layout / unresolved `@tokens@` render blank silently, never logging. Arg order is
`(reportPath, projectName, params, fileType)`.

## HTML-mock-first workflow (MPP house style)

For MPP reports — especially customer-facing ones (Honda trace/shipping exports) — mock the
report as **HTML first** (frontend-design / artifact skills) for fast layout + field sign-off,
*then* re-author the approved design into ReportMill XML via the skill's `reportmill_layout.py`.
The HTML is a design/approval artifact, not a 1:1 transpile source — ReportMill is a constrained
vocabulary (points, 612×792 letter, fixed tag set, no rounded corners). Once built,
`executeReport(..., "html")` renders the *real* report to HTML as a verification diff against
the mock.

## Locked template (report family look)

`mockup/reports/downtime_report_mock.html` is the **approved, locked template** for the report
family (Downtime / Rejects / Die-Shot / Production). Match its look when building any of the four:
blue-black header band on the app canvas (`--mpp-neutral-10`) + cyan accent rule
(`--mpp-accent-50`); Inter; a params band that is **shift-centric by default** (lead cell tinted);
a 5-KPI summary row; a **single-scale Pareto** (bars = minutes, cumulative line on the *same* axis
relabeled 0–100%, dashed line at the 80% vital-few — never a true dual y-axis); a breakdown split;
and a **machine-grouped nested detail** (per-machine summary band — total min, event count, top
reason + its minutes, unexcused % — above its child event rows, machines ranked by downtime).
Every field traces to a real column (validated against `Oee.DowntimeEvent` / `DowntimeReasonType`
/ `DowntimeReasonCode` / `DowntimeSourceCode` / `Shift`). Light document surface = the print steps
of the same hues. HTML mock is the design artifact → re-author into ReportMill XML (not a 1:1
transpile).

## Scope pointers

In-scope reports per `reference/MPP_Scope_Matrix.xlsx` (Production Data Acquisition, "Included
and Expanded"): **Rejects Report, Die Shot Report, Downtime Report, Production Report**.
Traceability/Honda **genealogy + shipping-history exports** (FAT-TRC-100/280/310) are the
Spec H cluster this skill unblocks — TRC-310's Honda format is pending an example from MPP
(`notes/2026-08-07_mpp-email-honda-trace-export.md`).

## The format element uses `pattern=`, not `format=` (cost hours, 2026-08-25)

Building the five aggregate reports, all five failed to render with the generic
*"Enter a valid report in the source property"* — the same symptom as a title
mismatch, but the titles were correct.

**Cause:** the ReportMill `<format>` element's attribute is **`pattern`**, not
`format`. An unrecognised attribute invalidates the element and takes the whole
report down. Nothing in the gateway log points at it: the only reporting entries
were `Error executing query parameter expression "{StartDate}"`, which is
**benign noise the working reports emit too** — chasing it is a dead end.

```xml
<!-- WRONG: renders nothing, no useful log line -->
<format type="date"   format="MM/dd/yy HH:mm" />
<format type="number" format="#,##0" />

<!-- RIGHT: copied from the working Downtime by Date Range report -->
<format type="date"   pattern="MMM d, yyyy" null-string="&lt;N/A&gt;" />
<format type="date"   pattern="MMM d  HH:mm" null-string="&lt;N/A&gt;" />
<format type="number" pattern="#,##0"        null-string="&lt;N/A&gt;" />
```

**The technique that found it** — bisect from a KNOWN-GOOD report, not from the
broken one. Build your report with the working report's layout XML verbatim: if
it renders, the fault is entirely in your layout, and you can halve it from
there (title block only, then table). Guessing at title/snapshot/param-type/SQL
form burned far longer and eliminated nothing.

**Two red herrings encountered on the way, both disproved by checking a WORKING
report rather than assuming:**

- *Row cells wider than the table.* Real in one of ours (588pt of cells in a
  540pt table) — but `Downtime by Date Range` overflows too (550 in 540) and
  renders fine. Not fatal.
- *`logical_name="Times New Roman"`* (the layout helper's default) vs the
  `Helvetica` every MPP report uses. Cosmetic; not the cause.

Also worth knowing: a blank date picker does NOT render an unfiltered report —
the module fails the parameter expression and the viewer shows nothing with no
explanation. `BlueRidge.Reports.composeParams` now defaults a 14-day window.

## Nested tables and column-keyed grouping DO work — but ONLY inside a `<table-group>` (2026-08-26)

Both mechanisms are real and render correctly. Getting them wrong fails **silently** —
no exception, no log line, no partial output — so a malformed nest looks exactly like an
unsupported feature. Two independent attempts in this repo got it wrong the same way.

### The shape that works

Copied from the production **`CryovacEnterpriseWeeklyReport`** (Boar's Head), which nests
five tables successfully:

```xml
<table-group x="36" y="100" width="540" height="632" useStroke="false">
  <table width="540" height="632" list-key="Parent" startrowbreak="false">
    <grouping key="Parent" details="true" />
    <tablerow width="540" height="22" title="Parent Details"> … </tablerow>
    <table width="540" height="632" list-key="Child">
      <grouping key="Child" header="true" details="true" />
      <tablerow width="540" height="15" title="Child Header">  … </tablerow>
      <tablerow y="15" width="540" height="14" title="Child Details"> … </tablerow>
    </table>
  </table>
</table-group>
```

Three rules, each of which silently renders nothing if broken:

1. **The whole nest MUST be wrapped in `<table-group>`.** A `<table>` nested directly
   inside another `<table>` with no wrapper renders nothing.
2. **The child table carries the SAME `width` AND `height` as its parent, and NO `x`/`y`
   of its own.** The `<table-group>` positions the stack. Giving the child its own
   smaller box and offsets renders nothing.
3. **`<tablerow title>` must read exactly `"<groupingKey> Header|Details|Summary"`** —
   that string *is* the band binding. A nested table uses the **bare** child key
   (`list-key="Child"`); a standalone table elsewhere in the document may use a dotted
   path (`sites.siteTotals`).

### Column-keyed grouping (a band per distinct value)

Also real. From the production `CIPReport_OLD`, where `step` is the dataset and
`stepIndex` is a **column** of it:

```xml
<grouping key="step" details="true" />
<grouping key="stepIndex" header="true" details="true" />
<tablerow width="540" height="1" title="step Details"> … 1px spacer … </tablerow>
<tablerow y="51" width="540" height="596" version-key="phaseName"
          title="stepIndex Details" structured="false" stay-with="0"> … </tablerow>
```

Note the dataset-level row is a **1px spacer** and the column-keyed row carries
`structured="false"` (free-form band: children positioned absolutely inside it rather
than as a row of cells), plus `version-key` and `stay-with`. Omitting those and writing
it as an ordinary structured row produces **one** band carrying the **first row's**
value — the "frozen band" symptom.

### The trap that produced two broken nests here

**`Rejects Part Matrix`** shipped with its `ByParty` / `Defects` tables rendering nothing:
it omitted the `<table-group>` and gave each child its own `y` offset and a narrower box.
The generator behind it (`nested_table()` in `tools/build_aggregate_reports.py`) had a
docstring claiming the Cryovac shape while emitting exactly that malformation. Both were
fixed 2026-08-26 (`11d6f268`) and the report now renders both sections — it is safe to
read as a reference again, but read the **generator**, which carries the rules inline.

The failure is completely silent, so a nest can pass review and a render check while
producing nothing. **Render any report before adopting it as a reference, and check that
every section actually has content** — not just that a page appeared. That single check is
what separated "the feature is unsupported" from "our markup is malformed", after several
hours spent on the former conclusion.

Working references live outside this repo: `CryovacWeeklyEnterpriseReport.zip` and
`ContainerFareCIPReport.zip` (Boar's Head, 8.1). They are also the provenance for the
nested-**query** binary shape in `tools/reports/nesting_builder.py`.

## An overflowing table repeats the WHOLE page

When a table runs past the bottom of its page, ReportMill continues it by repeating the
**entire page design** — every static element on that page, not just the table. A section
sharing a page with a summary block will reprint that summary block on the continuation
page. Give any table that can grow unboundedly its own page.

## `@Page@` / `@PageMax@` resolve only in PAGINATED output — verify them in PDF, not PNG

A footer element like:

```xml
<text x="36" y="762" width="260" height="16"><string>Page  @Page@  of  @PageMax@</string></text>
```

is correct and works. But `executeReport(..., "png")` renders the **literal text**
`Page @Page@ of @PageMax@`, because PNG is not a paginated format and the page-number
keys have nothing to resolve against. The same report rendered with
`executeReport(..., "pdf")` shows `Page 1 of 6`, `Page 2 of 6`, and so on.

This is a trap for the whole render-verify workflow, which is PNG-based: an unresolved
`@token@` in a PNG normally *does* mean a broken binding, so the footer looks like a bug
on every report in the project. It is not. **Confirm page-number tokens against a PDF
render before "fixing" anything.** Checking the drawn text is enough:

```python
import pypdf, re
r = pypdf.PdfReader("report.pdf")
shown = re.compile(r'\(([^)]*)\)\s*Tj').findall(
    r.pages[0].get_contents().get_data().decode('latin-1', 'replace'))
print([x for x in shown if 'Page' in x])      # -> ['Page  1  of  6']
```

(`pypdf`'s `extract_text()` missed this string entirely — scan the content-stream
text-showing operators instead.)

Corroboration: the production Boar's Head reports use byte-identical footer markup.
Markup that matches a known-good production report and still "fails" is a signal to
question the verification method, not the markup.

## Report PNGs are RGBA with a TRANSPARENT background

`executeReport(..., "png")` returns an image whose page background is transparent, not
white. Compositing it onto black (which is what a naive `.convert("RGB")` does) makes the
page look inky and the dark-on-light text nearly unreadable — easy to misread as a broken
render. Composite onto white before judging a layout:

```python
bg = Image.new("RGBA", page.size, (255, 255, 255, 255))
Image.alpha_composite(bg, page).convert("RGB").save(out)
```
