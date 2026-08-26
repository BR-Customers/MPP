# LOT Detail report — nested ancestor history: handoff

**Date:** 2026-08-25 · **Branch:** `jacques/working` · **HEAD at handoff:** `80f87484`

Start here. Then read, in order:

1. `docs/superpowers/specs/2026-08-25-lot-detail-report-genealogy-nesting-design.md` — the design and the six decisions, with rationale.
2. `docs/superpowers/plans/2026-08-25-lot-detail-report-genealogy-nesting.md` — the 8-task plan. **Task 4 carries a warning banner; read it before touching the layout.**
3. `.superpowers/sdd/progress.md` — the execution ledger, bottom section (`=== NEW FEATURE (2026-08-25) ===`). Per-task commits and findings. **Gitignored scratch — copy anything you need out of it before any `git clean -fdx`.**

---

## What actually prompted this

The report "seemed empty." **It was never broken.** Investigation found a working five-page traceability document whose data sources all return correctly — for component LOT `000000001` it returns 5 descendant FG lots *and* 5 containers with live AIM shipper IDs.

It looked empty because the picker is `SELECT TOP 100 … ORDER BY CreatedAt DESC`, and Dev's newest LOTs are the terminal SubAssemblies from the demo seed, which genuinely have zero descendants, zero containers and zero production events. **That picker is a real production defect** — a traceability report exists to investigate something that shipped months ago, and this makes a LOT progressively less reachable as it ages. It is Task 7 and is arguably the highest-value item left.

The genuine feature gap: ancestor rows name *which* LOTs were involved but not *what happened to them*.

---

## State

| Task | State |
|---|---|
| 1 — extract report to version-controlled source | ✅ complete, reviewed clean |
| 2 — nested-child-query builder | ✅ complete, reviewed clean |
| 3 — wire `AncestorSteps` data source | ✅ complete, reviewed clean |
| 4 — nested ancestors layout | ✅ **complete 2026-08-26** — built **as designed** (nested child query + nested table). Needs the `<table-group>` wrapper; see below. |
| 5 — section counts in subtitles | ✅ **complete 2026-08-26** (`ce89ce56`) |
| 6 — drop dead data source | ✅ **verified NO-OP 2026-08-26** — no bare `Genealogy` source, no layout reference. Nothing to commit. |
| 7 — reachable LOT picker | ✅ **complete 2026-08-26** (`214d1674`), verified on the gateway |
| 8 — remove harness, close out | ✅ **complete 2026-08-26** — both dev timers deleted, spec + PROJECT_STATUS updated |

**Biggest win so far:** the report had **no generator anywhere in version control** — six `data.bin` files were built ad-hoc in a scratchpad and only the binaries committed. It now has `tools/reports/` with the layout as editable XML, the SQL as Python, a generator, and a test proving byte-level reproduction of the original.

---

## ⚠️ Task 4 is committed broken — decide this first

Commit `80f87484` renders LOT 10270 as **19 of 23 pages** (a page break before every single step row) with a part-number band frozen on ancestor 1's value. The nesting itself works — data, indentation, and per-row restatement are all correct — but the pagination makes it unusable.

**Two options:**
- **Revert `80f87484`** to put the report back in its previous good state, and redo the layout interactively later. Safest if you are not finishing it tonight.
- **Finish it interactively** (see below).

**There is an uncommitted candidate fix in the working tree** — `tools/reports/lot_detail/layout.xml`, with `startrowbreak="true"` removed from both tables and grouping switched `PartNumber` → `RelatedLotName` (band text `@RelatedLotName@ · @PartNumber@`). **It has never been rendered or verified.** `data.bin` was rebuilt from it, so **what is deployed is not what is committed**. Treat it as a starting point, not a solution.

Ruled out already: input ordering is *not* the cause of the frozen band — rows arrive sorted by `PartNumber` with four distinct ascending values for LOT 10270. This is genuine undocumented ReportMill grouping behaviour.

---

## Do NOT resume Task 4 as a delegated transcription task

The layout needs interactive render → look → adjust cycles against an undocumented engine. The plan's Task 4 XML was **authored from about ten minutes of reading two sample reports and written into the plan as verbatim code** — both defects above came from that guesswork, and the implementer transcribed it faithfully.

The previous feature's ledger already recorded this lesson: *"Report Tasks 4-5 = interactive, NOT in this SDD flow."* It was read at session start and not followed.

**Render loop:**
1. Edit `tools/reports/lot_detail/layout.xml`, run `python tools/reports/build_lot_detail_report.py` (XML-validates before writing).
2. Set `ignition/projects/MPP/ignition/timer/DevRenderReport/resource.json` → `"enabled": true`, run `./scan.ps1`, wait ~25s.
3. **Read the PNGs** at `C:\Temp\report_render\lot_detail_*.png` and *look at them*. A clean render with no exception proves nothing — bad layout renders blank and logs nothing.
4. Set `"enabled": false`, `./scan.ps1`. **Never leave it enabled** — it re-renders every 20s forever (it was found enabled at handoff).

**Test LOTs:** `10270` is primary (4 ancestors — the render that proves the feature). `10274` has 1 ancestor. `254` has 0 ancestors, so an empty Ancestors page is *correct*.

**Regression guard:** `python tools/reports/test_report_reproduction.py` must stay green. It asserts the nested `AncestorSteps` source is intact with tokens `['{RelatedLotId}']` — it was hardened specifically to catch the child being rebound to `{LotId}`, which would silently show every ancestor the *subject's* history.

---

## Before Task 7 — re-verify targets

Commit `090e9301` (another session, mid-flight) rewrote **both** files Task 7 edits: `BlueRidge/Reports/code.py` (+43) and `Views/Reports/view.json` (+410). The `LotDropdown` JSON captured in the plan is likely stale. Re-read both against HEAD before editing.

## Coordination issue for Jacques

Another session is building **parallel report tooling**:
- `tools/build_aggregate_reports.py` (from `090e9301`) alongside our `tools/reports/`.
- It added its own `_subquery` + `add_nested_query` to the **shared global skill** at `~/.claude/skills/ignition-reporting/tools/report_builder.py` (timestamped 2026-08-25 14:10, mid-task).

Our `NestingReportBuilder` now shadows those with an incompatible interface. Verified difference: the base's `_subquery` wraps `setChildren` in `if children:`, so it **omits `setChildren` on leaf nodes**, whereas the Designer-authored donor and both 8.1 customer reports **do** emit an empty `setChildren` on leaves. Ours matches Designer; the base does not. **Consolidation is Jacques's call.**

---

## Durable facts worth keeping

- **Gateway timer scripts need `def handleTimerEvent():` on line 1.** Leading `#` comments raise a Jython `PySyntaxError` in `wrapper.log` and the timer silently never runs. Comments go inside the body.
- **`<tablerow title>` must read exactly `"<groupingKey> Header|Details|Summary"`** — that string *is* the band binding. Wrong title renders nothing and logs nothing.
- **The first `<grouping key>` names the dataset; subsequent ones key on a column.**
- **A table nested inside its parent uses the bare child key; a standalone table elsewhere uses a dotted path** (`sites.siteTotals`).
- **`Lots.LotGenealogyClosure`** (`AncestorLotId`, `DescendantLotId`, `Depth`, with a `Depth=0` self-row) makes ancestor/descendant counts cheap index lookups.
- **Never SUM `PieceCount`** across genealogy rows — the proc emits one row per distinct *path*, so a LOT reachable by two paths appears twice.
- The Reporting module is in **TRIAL** on this gateway: watermark is normal; a *licensing* failure with no image means a lapsed trial needing a gateway restart, not a layout bug.

---

## 2026-08-26 session — revert + Task 7

**Task 4 reverted (`9c64ff9e`).** The deployed report is good again: five pages,
populated, verified by render (see below). The revert backs out ONLY the layout
page — the nested `AncestorSteps` data source from `e89af0b9` is untouched and
`test_report_reproduction.py` stays green, so Task 4 can be redone without
repeating Tasks 1–3. `80f87484` touched exactly the two files that were dirty in
the working tree, so the never-rendered candidate had to be salvaged before the
revert could run; it is `notes/2026-08-26_task4-candidate-layout.patch`, with a
header explaining what it is and how to reapply. **Still never rendered — still
not a solution.**

**Task 7 complete (`214d1674`).** The dropdown takes `allowCustomOptions` +
`search`; `BlueRidge.Reports._resolveLotId` resolves a scanned/typed LOT name
server-side.

> **The plan's Task 7 code was wrong, in the same way Task 4 was wrong.** It
> tried `int(lotId)` FIRST and only fell back to a name lookup. LOT names are
> zero-padded numerics, so `int('000000001')` succeeds and returns **1** — and
> LOT `000000001` is actually Id **254**. On a Honda traceability document that
> is the worst available failure: a fully populated report for the wrong LOT,
> with nothing on the page to signal it. Dev hides it (no LOT with Id 1);
> production would not. The plan's own Step 3 asserted `{'LotId': 254}` for that
> input, which its code could not produce — the contradiction survived because
> nobody ran it. Resolution now branches on TYPE (string ⇒ name-first), not on
> parseability.

**Verified, not assumed:** a temporary gateway timer exercised `composeParams`
against all six input shapes — option value `254`, scanned `'000000001'`, typed
`'254'`, unknown `'NOPE-999'`, blank, `None` — all six PASS. Then rendered Lot
Detail for the resolved LOT and *looked at the PNG*: 5 descendants, 5 containers
with live AIM shipper IDs, 6 lifecycle events, 3 production events, correctly
empty Ancestors page. The temp timer was deleted; `DevRenderReport` is back to
`enabled: false` (confirmed on disk after the final scan).

**Caveat on scope of proof:** Dev holds only **33 LOTs**, so the `TOP 100`
truncation cannot be reproduced here — every LOT currently fits the list. What
is proven is that resolution never consults the picker list at all, so list size
is irrelevant to the by-name path. The `TOP 100` query is left in place
deliberately (comment added saying why): it is now a convenience list of what is
in flight, not the only way in.

### Two pre-existing defects found while verifying — NOT fixed, NOT mine

1. **Page footer renders literal `@Page@` / `@PageMax@`.** Visible on every page
   of the known-good report, so it predates both Task 4 and Task 7. Cosmetic but
   customer-facing on a Honda-bound document. Needs the interactive render loop,
   so it belongs with Task 4.
2. **`InventoryManager.receiveLoose` has the same int-first bug** the Task 7 plan
   had: `int(partValue)` before `getByPartNumber`. Safe today only because MPP
   part numbers contain letters/dashes. A purely numeric part number would
   silently receive stock against the wrong item.

---

## 2026-08-26 (session 2) — Tasks 4, 5, 6, 8 complete

All 8 plan tasks are now done. The report renders 6 pages.

### The headline finding: nested tables work — but a malformed nest renders NOTHING, silently

**Corrected 2026-08-26 after Jacques pointed at the Boar's Head reports.** My first conclusion here
was that the engine did not support nesting at all. That was wrong, and the way it was wrong is the
useful part.

The evidence I had: my nested layout rendered nothing, AND the pre-existing `Rejects Part Matrix`
nest rendered nothing, AND every `<grouping>` in all 11 MPP reports is dataset-level. Three
consistent signals — and the conclusion still did not follow, because **both failing examples were
malformed in the same way**, and "no working example in this repo" is not "unsupported". The
working references were sitting outside the repo the whole time
(`CryovacWeeklyEnterpriseReport.zip`, `ContainerFareCIPReport.zip` — Boar's Head, 8.1; also the
provenance for `nesting_builder.py`'s binary shape).

**The shape that actually works**, from `CryovacEnterpriseWeeklyReport`, which nests five tables:

```xml
<table-group x="36" y="100" width="540" height="632" useStroke="false">
  <table width="540" height="632" list-key="Parent" startrowbreak="false">
    <grouping key="Parent" details="true" />
    <tablerow width="540" height="22" title="Parent Details"> … </tablerow>
    <table width="540" height="632" list-key="Child">     <!-- SAME w/h, NO x/y -->
      <grouping key="Child" header="true" details="true" />
      <tablerow width="540" height="15" title="Child Header"> … </tablerow>
      <tablerow y="15" width="540" height="14" title="Child Details"> … </tablerow>
    </table>
  </table>
</table-group>
```

1. The nest MUST be wrapped in **`<table-group>`**. Bare `<table>`-in-`<table>` renders nothing.
2. The child carries the **parent's exact width AND height, with no `x`/`y`** — the table-group
   positions the stack. A child with its own smaller box and offsets renders nothing.
3. `<tablerow title>` must be exactly `"<groupingKey> Header|Details"`; nested tables use the
   **bare** child key.

`80f87484`, my first attempt, and `Rejects Part Matrix` all break rules 1 and 2.

**Column-keyed grouping also works** (`CIPReport_OLD`): the dataset row is a **1px spacer** and the
column-keyed row needs `structured="false"` plus `version-key` / `stay-with`. Written as an ordinary
structured row it yields ONE band with the FIRST row's value — the "frozen band" of `80f87484`.

**Do not adopt `Rejects Part Matrix` as a reference.** It is the repo's only nested layout, which is
exactly why it is tempting, and its nests have never rendered. Render a reference before trusting
it — that check is what eventually separated "unsupported feature" from "malformed markup", and it
should have been applied to the *search for a reference*, not just to the reference I happened to
find.

### What was built

- The Ancestor Process History page is built **as the design intended**: a `<table-group>` holding
  the `GenealogyAncestors` table, with each ancestor's own `AncestorSteps` history nested beneath
  its band. `AncestorSteps` is a true nested child query — `Lots.Lot_GetLifecycle` bound to the
  parent row's `{RelatedLotId}` column, so `nesting_builder.py` IS in use.
- It gets its **own page** (page 2); see the page-break note below.
- Section counts in every page subtitle, verified in SQL before the layout was touched.

A flat fallback was built first (a `Lots.Lot_GetAncestorSteps` proc returning one row per
(ancestor, step), drawn as a plain table) while nesting was believed impossible. Once the real
nesting shape was found, that proc was **dropped** — from the repo and from `MPP_MES_Dev` — and the
nested design shipped instead. It is in history at `a3343fd9` if the flat shape is ever wanted.

### Observed page-break behaviour (Task 8 Step 2 — replaces the design's assumption)

When a table overflows its page, ReportMill **repeats the entire page design**, not just the
continuing table. With the history on page 1, the summary block and the ancestors table
printed a second time. Moving it to its own page confines the repeat to the table that
actually continues. **With current Dev data no test LOT overflows a page**, so this is recorded
from the page-1 experiment, not from the shipped layout — stated explicitly rather than left
implied.

### Verification

Rendered and *looked at* on all three test LOTs: `10270` (4 ancestors, 19 step rows),
`10274` (1 ancestor, 5 steps), `254` (0 ancestors — correctly empty; it is a die-cast origin).
Subtitle counts match the SQL exactly on every line. The reproduction test was rewritten for
the flat shape and **mutation-tested twice**: rebinding the source to `Lot_GetLifecycle` (which
would show the SUBJECT's history under an ancestors heading) fails loudly, and renaming a count
alias fails loudly.

One process miss worth recording: the Task 5 commit went in with the reproduction test
FAILING. The test was run as `python ... | tail -1`, so the pipeline's exit status came from
`tail` and the `&&` guard never fired. Fixed in `e4929c00`. **Check the exit code, not the
last line of output** — that is the entire point of running a test.

### Still open

- **Footer renders literal `@Page@` / `@PageMax@`** on every page of **all 11 reports**.
  Pre-existing and global, not specific to this report. Chipped, not fixed — deliberately out
  of scope here.
- **`InventoryManager.receiveLoose`** has the same int-first resolution bug the LOT picker had.
  Safe today only because MPP part numbers contain letters. Chipped.
- **Tooling duplication** with the other session's `tools/build_aggregate_reports.py` and its
  `add_nested_query` in the shared global skill — still Jacques's call. Note that the shared
  skill's nested-query support builds a structure that, per the finding above, **no layout can
  currently draw.**
