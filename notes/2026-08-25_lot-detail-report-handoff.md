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
| 4 — nested ancestors layout | ↩️ **REVERTED 2026-08-26** (`9c64ff9e`). Report is back to its good five-page state. Candidate fix preserved as `notes/2026-08-26_task4-candidate-layout.patch`. Still to be redone **interactively**. |
| 5 — section counts in subtitles | not started |
| 6 — drop dead data source | **confirmed NO-OP** — verify and record, don't dispatch |
| 7 — reachable LOT picker | ✅ **complete 2026-08-26** (`214d1674`), verified on the gateway |
| 8 — remove harness, close out | not started — `DevRenderReport` timer still present, disabled |

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
