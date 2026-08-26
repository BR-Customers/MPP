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

## Nested tables and column-keyed grouping DO NOT RENDER (cost hours, 2026-08-26)

Two ReportMill hierarchy mechanisms look available in the layout XML and are silently
inert on our gateway. Both were established by **render**, not by reasoning:

| What you write | What actually happens |
|---|---|
| A `<table>` nested inside another `<table>` | Renders **nothing**. No exception, no log line, no partial output. The parent's rows render fine, the child is simply absent. |
| A **column-keyed** `<grouping>` (e.g. `<grouping key="PartNumber" header="true"/>`) meant to emit a band per distinct value | Emits **one** band carrying the **first row's** value. Looks like a "frozen" band. |

**Do not adopt a report as a known-good reference without rendering it.** The nested-table
failure reproduces on the pre-existing `Rejects Part Matrix` report, whose `ByParty` /
`Defects` nests have never rendered — it was adopted as the reference precisely *because*
it was the only nested layout in the repo, and it was broken too. Rendering it is what
turned a confusing bisect into a five-minute answer.

Corroborating survey: **every `<grouping>` in all 11 MPP reports is dataset-level**
(`key` == the data-source key, one per table). There is no working example of either
mechanism anywhere in the codebase — that absence is itself the signal.

**The rule: flatten hierarchies in SQL, draw them with a flat table.** Write a read proc
that returns the joined/denormalised shape (one row per parent-child pair, parent identity
repeated on every row) and give it a single dataset-level grouping. Reference impl:
`Lots.Lot_GetAncestorSteps` + the "Ancestor Process History" page of the Lot Detail report.
Copy the parent walk **verbatim** from the proc that feeds the parent table so the two can
never disagree, and `LEFT JOIN` the children so a parent with none still appears.

Corollary: the shared skill's `add_nested_query` / `_subquery` support builds a data
structure that is real (the child query does execute, bound to a parent row column) but
that **no layout can currently draw**. Nesting is a data-layer capability with no
presentation-layer counterpart here.

## An overflowing table repeats the WHOLE page

When a table runs past the bottom of its page, ReportMill continues it by repeating the
**entire page design** — every static element on that page, not just the table. A section
sharing a page with a summary block will reprint that summary block on the continuation
page. Give any table that can grow unboundedly its own page.

## Report PNGs are RGBA with a TRANSPARENT background

`executeReport(..., "png")` returns an image whose page background is transparent, not
white. Compositing it onto black (which is what a naive `.convert("RGB")` does) makes the
page look inky and the dark-on-light text nearly unreadable — easy to misread as a broken
render. Composite onto white before judging a layout:

```python
bg = Image.new("RGBA", page.size, (255, 255, 255, 255))
Image.alpha_composite(bg, page).convert("RGB").save(out)
```
