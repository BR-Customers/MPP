# LOT Detail report — nested ancestor process history + reachable LOT picker

**Date:** 2026-08-25
**Status:** Partially implemented 2026-08-25 — data layer done and reviewed; the
ancestors **layout is committed in a broken state** (`80f87484`). Resume from
`notes/2026-08-25_lot-detail-report-handoff.md`.
**Scope:** Reporting Module report + one Core NQ + the Reports landing-page picker. No schema change, no new stored procedure, no test-suite impact.

---

## What prompted this

The LOT Detail report "seemed empty." It is not — investigation showed a working
five-page traceability document whose data sources all return correctly. Three separate
things produced that impression, and only one of them is a report defect.

### Verified 2026-08-25 against `MPP_MES_Dev`

The report has six data sources across five pages, all bound to a single `LotId`
parameter (type Long), with folder name = internal `setTitle` = registry `reportPath`
(the title-match rule that silently breaks a Report Viewer is satisfied):

| Page | Section | Source |
|---|---|---|
| 1 | Summary header + **Made From · Ancestors** | `Lot_GetGenealogyEdgeTree ?, 'Ancestors'` |
| 2 | **Used In · Descendants** | `Lot_GetGenealogyEdgeTree ?, 'Descendants'` |
| 3 | **Containers · Shipped Units** | `Lot_GetShippedContainers ?` |
| 4 | **Lifecycle** | `Lot_GetLifecycle ?` |
| 5 | **Production Events** | inline SQL on `Workorder.ProductionEvent` |

Both genealogy procs are fully recursive. `Lot_GetGenealogyEdgeTree` walks the
`Lots.LotGenealogy` edge table in both directions with a path-string cycle guard;
`Lot_GetShippedContainers` seeds on the subject and walks every consumption edge down, so
it reaches containers any number of levels below the subject.

**The downstream question already works.** For component LOT `000000001`
(`12231-59B-0000`, 1800 pieces) the report returns 5 descendant FG lots
(`MESL3000142`–`146`) **and** 5 containers with live AIM shipper IDs, quantities,
statuses, locations and completion timestamps. "What containers and lots consumed this
LOT" needed no work.

### Root causes of the empty appearance

1. **The picker is `SELECT TOP 100 … ORDER BY l.CreatedAt DESC`.** Dev's newest LOTs are
   the terminal SubAssemblies from the demo seed (`10271`–`10275`), which genuinely have
   zero descendants, zero containers and zero production events. Anything picked off the
   top of that list yields one ancestor row and four blank pages. **This is a production
   defect, not a Dev annoyance:** a traceability report exists to investigate something
   that shipped months ago, and this query makes a LOT progressively less reachable the
   older it gets. Past 100 newer LOTs it becomes unreportable entirely.
2. **Empty ReportMill tables render as a bare header over a 420–630pt void**, with no
   "no rows" message — a legitimately-empty section is indistinguishable from a broken one.
3. **Real gap:** the ancestor/descendant pages are lot-level only. They name *which* LOTs
   were involved but say nothing about *what happened to them*. Answering "this part
   failed, what did everything upstream go through" currently means re-running the report
   once per ancestor.

## Decisions

| # | Decision | Rationale |
|---|---|---|
| D1 | Nest **lifecycle events** under each ancestor LOT | `Lot_GetLifecycle` is audit-log backed, so it covers moves, holds, splits and releases — not just production. Many LOTs have a full lifecycle but zero `ProductionEvent` rows, which would have produced empty nested blocks. |
| D2 | **Descendants stay lot-level** | Bounds the report. A component LOT feeding 30 FG lots stays a 30-row table rather than 30 nested step blocks. The downstream question is already answered by pages 2–3. |
| D3 | **Part-number group band, tree order inside** | Genealogy is a DAG with real depth, and the proc emits one row per distinct path — a strict part-number sort scatters a merge-topology ancestor through the list with nothing to explain why. Part number as a group *header* keeps the by-part view without flattening depth. |
| D4 | **Section counts in page subtitles**, not empty-state text | ReportMill has no clean conditional-visibility construct. Counts ("Ancestors — 3 LOTs" / "— none") are always accurate, always visible, and distinguish "nothing upstream of a die-cast origin" from "something broke" — the exact confusion that started this. |
| D5 | Drop the dead `Genealogy` data source and orphaned donor strings | A legacy flat union query no page references, plus `StartDate`/`EndDate`/`ShiftID` strings left over from the donor clone. Harmless but misleading to the next reader. |
| D6 | **Fix the LOT picker** in the same change | It is the reason the report looked empty and it is a genuine production defect. Small next to the report work. |

## Architecture

### Data side — nested `SubQuery`

A child SubQuery is attached to the `GenealogyAncestors` root query via `setChildren`. It
runs once per ancestor row, with its `?` bound to the **parent row's** `RelatedLotId`
rather than to a report parameter:

```
GenealogyAncestors   EXEC Lots.Lot_GetGenealogyEdgeTree ?, N'Ancestors'   tokens ['{LotId}']
  └─ AncestorSteps   EXEC Lots.Lot_GetLifecycle ?                          tokens ['{RelatedLotId}']
```

No new SQL. `Lot_GetLifecycle` is the proc page 4 already calls, reused unchanged.

### Layout side — `<table-group>` with a nested child table, plus a second grouping

The ancestors table gains a part-number band and an inner table:

```
12231-59B-0000 · 59B Cam Holder IN #1 Casting          ← <grouping key="PartNumber" header>
   000000001   depth 1   Consumption   60 EA           ← ancestor detail row
      Jul 30 14:46  Die Cast LOT Opened     Machine 01   JACQUES     ← nested AncestorSteps
      Jul 31 13:28  Die Cast LOT Released   Warehouse    JACQUES
      Aug 03 13:20  Machining IN Picked     59b Cam…     JACQUES
```

### Reference mechanics (verified against two working customer reports)

Neither construct is documented in the `ignition-reporting` skill or the MPP context pack,
which cover only flat single-grouping tables. Both were reverse-engineered on 2026-08-25
from two 8.1 customer reports, which the skill's existing codec parsed unmodified
(`version=2` envelope, identical class names to 8.3.5 — the codec is version-portable).
A context-pack write-up is tracked as a separate task.

**Nested table** — the child `<table>` sits *inside* the parent `<table>`, as a sibling of
the parent's `<tablerow>` elements, the whole thing wrapped in `<table-group>`:

```xml
<table-group x="36" y="157.719" width="540" height="598.281" useStroke="false">
  <table width="540" height="598.281" list-key="sites" startrowbreak="true">
    <grouping key="sites" details="true" />
    <tablerow width="540" height="12.382" title="sites Details"> …cells… </tablerow>
    <table width="540" height="598.281" list-key="machines" startrowbreak="true">
      <grouping key="machines" … />
```

**Multi-level grouping** — several `<grouping>` elements on one table build nested bands:

```xml
<table list-key="step">
  <grouping key="step"      details="true" />
  <grouping key="stepIndex" header="true" details="true" />
  <tablerow title="step Details">        …
  <tablerow title="stepIndex Header">    …
  <tablerow title="stepIndex Details">   …
```

Three rules that are easy to get wrong and fail silently:

- `<tablerow title>` must read exactly `"<groupingKey> Header"` / `" Details"` / `" Summary"`.
  That string *is* the band binding; a wrong title renders nothing and logs nothing.
- The **first** `<grouping key>` names the dataset; **subsequent** ones key on a *column*
  to create sub-bands. This is what makes D3 free — no wrapper proc, no proc change, no
  touching `sql/tests/0055_LotGenealogyReport/`.
- A table nested inside its parent uses the **bare** child key (`list-key="machines"`); a
  standalone table elsewhere on the page addresses a child dataset by **dotted path**
  (`list-key="sites.siteTotals"`). Both forms appear in the same report.

### Donor

`reports/sample for claude/data.bin` was extended by Jacques on 2026-08-25 to carry a
nested query plus a parameter-referencing query, so the donor now natively contains every
signature this work needs on our own gateway version (`8.3.5.2026040611-rc1`):
`setChildren`, `SubQuery`, `setExpressions`, `setParameters`, `ReportParameter`. No
borrowed setter signature is required.

`ReportBuilder.add_query` emits flat root queries only, so it needs a nesting entry point
(e.g. `add_query(..., children=[…])` or `add_nested_query`). Signatures are cloned from the
donor by setter name and argument type, not by tree position — the donor's parameterised
query being a *sibling* of the nested pair rather than the nested child itself is fine.

### D4 — where the section counts come from

The `Summary` data source is inline SQL in the report (not a proc), returns exactly one
row, and every page already reads from it (`@Summary.lot_name@`, `@Summary.part_number@`).
It gains four scalar sub-selects — `ancestor_count`, `descendant_count`, `container_count`,
`event_count` — counted over the same edge/closure walks the section procs use.

Each page's existing subtitle line then carries its own count, e.g.
`@Summary.lot_name@ · @Summary.part_number@ · @Summary.descendant_count@ LOTs`. Rendering a
literal `0` is acceptable and still unambiguous; a `<format>` with a `null-string` covers
the NULL case. No extra round-trip — the Summary query already runs once per report.

### D6 — reachable LOT picker

`reports/Lot_ListForPicker` keeps returning the recent list for browsing, but the
`LotDropdown` on the Reports landing page gains `allowCustomOptions: true` + `search: true`
— the project's standing "scan or dropdown is ONE dropdown" convention. An operator can
then scan an LTT barcode or type a LOT name that is not in the loaded list.

A free-text entry arrives as a plain string rather than an option `value`, so
`BlueRidge.Reports.composeParams` must resolve it: when `lotId` is not an integer, look the
name up (`BlueRidge.Lots.Lot.getByName`, which already exists) and pass the resolved id.
An unresolvable name must surface a toast rather than silently rendering an empty report —
that failure mode is precisely what this whole change is fixing.

## Verification

No SQL changes, so the automated suite is unaffected. Verification is by render:

1. **Render and look.** Bad ReportMill layout and unresolved `@tokens@` fail silently in
   the render, never in the log — a clean load is not evidence. Render to PNG via
   `system.report.executeReport(path, project, params, "png")` from a one-shot gateway
   script and inspect the image.
2. Validate the layout XML parses (`xml.dom.minidom.parseString`) before deploy, and
   `L.esc(...)` every literal — a raw `&` throws `RMException` at render time, surfaced as
   a generic "invalid report".
3. Test LOTs, both already characterised:
   - `000000001` (id 254) — no ancestors, 5 descendants, 5 containers. Exercises D4's
     "Ancestors — none" subtitle and a populated descendants/containers pair.
   - A SubAssembly such as `000000024-04` (id 10274) — 1 ancestor with a real lifecycle,
     0 descendants. Exercises the nested step block and three "none" subtitles.
4. Confirm what a nested block does when it splits across a page break. Neither customer
   report demonstrated this, and Jacques's expectation (2026-08-25) is that the band and
   column headers do **not** repeat on the continuation page. **Design accordingly: assume
   they do not.** Each ancestor's step block therefore has to be readable without a
   repeated header — the ancestor's LOT name and part number are restated on its own row
   rather than living only in the group band above it, so a continuation page is never a
   column of orphaned timestamps with no idea which LOT they belong to. If the headers turn
   out to repeat, that restatement is mild redundancy rather than a rewrite.
5. Picker: scan/type a LOT name older than the newest 100 and confirm it resolves.

## Rejected alternatives

- **One flat pre-joined query with three grouping levels** (ancestors ⋈ lifecycle, banded
  by PartNumber → LOT → step). Avoids extending `ReportBuilder` entirely and was a genuine
  contender. Rejected because it pushes a report-specific join into SQL against the
  standing "reports call read procs, no domain logic in the presentation layer" rule, and
  gives less control over how a step block paginates. Worth revisiting if the builder
  extension proves harder than expected.
- **Nesting steps under descendants too** (D2). Symmetric and useful for a recall sweep,
  but this is where page count explodes on a high-fan-out component LOT.
- **Production events instead of lifecycle events** (D1). Tighter and more quantitative,
  but misses moves, holds and releases, and many LOTs have zero production events.
- **Conditional empty-state text** (D4). No clean ReportMill construct; faking one is more
  fragile than always-visible counts.
- **Raising the picker's `TOP 100`** (D6). Client-side search only filters already-loaded
  options, so this scales no better — the lookup has to be able to reach any LOT.
