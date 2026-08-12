# Track & Trace Showcase Deck — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans (inline, human-in-the-loop capture) to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Produce a branded Blue Ridge PowerPoint that showcases the MES's track-and-trace, genealogy, movement, reporting, and data-integrity capabilities using real screenshots of the running system populated with purpose-built demo data.

**Architecture:** Stand up an isolated `MPP_MES_Showcase` database (never touches `MPP_MES_Dev`), populate it by reusing the proven `seed_demo.sql` golden thread + a new **showcase overlay** that scrubs customer/OEM identifiers and back-dates history so the reports render rich. Jacques repoints the shared gateway datasource at the showcase DB for one bounded capture window; Claude captures every screen + renders every PDF report; Jacques swaps back. The deck is built from Blue Ridge's official kickoff template so branding is inherited, ending on a carefully-framed data-integrity/compliance capstone for the medical-device audience.

**Tech Stack:** SQL Server 2022 (`sqlcmd`), PowerShell (`Reset-DevDatabase.ps1`, gateway `scan.ps1`), Ignition 8.3.5 Perspective + Reporting Module, in-app browser for capture, PowerPoint COM (rendering on this Windows host — LibreOffice unavailable), `python-pptx` + the `pptx` skill scripts for deck build/QA.

## Global Constraints

- **No writes to `MPP_MES_Dev`** or the committed Ignition project. Showcase DB is separate; capture assets live under `docs/showcase/`. The gateway datasource change is transient and reverted by Jacques.
- **Identity scrub = customer/OEM only.** Aluminum die casting for automotive may be shown plainly. No literal `Honda`, `Madison`, `MPP`, or `AIM` in any seeded string or captured screen. `automotive` / `die cast` / `aluminum` are fine.
- **Capture is read-only rendering.** The in-app browser renders/reads Perspective views + reports but cannot commit inputs — irrelevant here (all captures are pre-populated read views). Do NOT rely on typing/clicking to populate data.
- **Compliance framing:** "architected to support" / "provides the record foundation for" — NEVER "compliant / certified / validated". Every compliance-slide row must be verified against the current schema before it ships.
- **Branding:** navy `#1E2761`, cyan `#29ABE2`, gold `#F7A823`, white bg; reuse the template master/layouts — do not hand-draw brand elements.
- **SQL conventions:** ASCII-only seed strings; run `sqlcmd` with `-I` (Lots.* filtered indexes need `QUOTED_IDENTIFIER ON`); resolve locations/parts/users by Code/natural key, never hardcoded Id.
- **Git:** commit to `jacques/working`; stage explicit paths (never `git add -A/-u`); omit the Claude co-author trailer.
- Spec: `docs/superpowers/specs/2026-08-12-track-trace-showcase-deck-design.md`.

---

## File Structure

- **Create** `sql/scratch/seed_showcase_overlay.sql` — the overlay run AFTER a standard reset (which already runs `seed_demo.sql`): name scrub + back-dated downtime/shot-count/weekly history + extra inspections + verification block. Idempotent.
- **Create** `docs/showcase/screenshots/*.png` — captured Perspective screens (C1–C13).
- **Create** `docs/showcase/reports/*.pdf` + `*.png` — rendered PDF reports + rasters.
- **Create** `docs/showcase/build_deck.py` — deck assembly driver (or a documented manual `pptx`-skill sequence), producing the deck from the template.
- **Create** `docs/showcase/Track-and-Trace-Showcase.pptx` — final deliverable.
- **Reference (read-only):** `sql/scratch/seed_demo.sql` (golden-thread mechanics), each report's read NQ/proc under `ignition/projects/Core/.../named-queries/reports/` + the report SQL, `MPP_MES_DATA_MODEL.md` (compliance verification).

`MPP_MES_Showcase` is a transient local DB (reproducible from reset + overlay) — not a repo artifact.

---

## Task 1: Stand up the `MPP_MES_Showcase` database

**Files:** none created; runs existing `sql/scripts/Reset-DevDatabase.ps1`.

**Interfaces:**
- Produces: a fully-built `MPP_MES_Showcase` DB with schema + procs + repeatables + standard seeds (real plant locations, items 020, routes 029) + `seed_demo.sql` golden thread (shipped FG with genealogy, WIP at every terminal, a hold, one open downtime).

- [ ] **Step 1: Build the DB (standard reset, WITH demo threads).**

`MPP_MES_Showcase` is not a `*_Dev` name, so the drop-guard does not require `-Force`.

```bash
cd "C:/Users/JacquesPotgieter/Documents/Dev/MPP/sql/scripts"
powershell -NoProfile -File ./Reset-DevDatabase.ps1 -ServerInstance localhost -DatabaseName MPP_MES_Showcase
```

Expected tail: "MPP_MES_Showcase rebuild complete.", migrations listed, "Stored procedures deployed: <n>", "demo threads seeded."

- [ ] **Step 2: Verify the golden thread landed.**

```bash
sqlcmd -S localhost -d MPP_MES_Showcase -E -I -C -W -Q "SELECT (SELECT COUNT(*) FROM Lots.Lot) AS Lots, (SELECT COUNT(*) FROM Lots.Container WHERE StatusCode='Shipped' OR Id IN (SELECT ContainerId FROM Lots.ContainerTray)) AS Containers, (SELECT COUNT(*) FROM Lots.LotGenealogy) AS GenealogyEdges, (SELECT COUNT(*) FROM Oee.DowntimeEvent) AS Downtime;"
```

Expected: Lots > 20, GenealogyEdges > 0, Downtime ≥ 1. If Lots = 0, the demo seed failed — re-run Step 1 and read the sqlcmd error.

- [ ] **Step 3: Identify the shipped-FG lot id for later capture.**

```bash
sqlcmd -S localhost -d MPP_MES_Showcase -E -I -C -W -Q "SELECT TOP 5 l.Id, l.LotNumber, i.PartNumber, i.Name, sc.Code AS Status FROM Lots.Lot l JOIN Parts.Item i ON i.Id=l.ItemId JOIN Lots.LotStatusCode sc ON sc.Id=l.LotStatusCodeId ORDER BY l.Id DESC;"
```

Record the finished-good lot id(s) with the deepest genealogy (the `*-M` machined / FG threads) — needed for capture C1/C2 and the Lot Detail report. No commit (DB is transient).

---

## Task 2: Author the showcase overlay — name scrub + report history

**Files:**
- Create: `sql/scratch/seed_showcase_overlay.sql`

**Interfaces:**
- Consumes: a freshly-reset `MPP_MES_Showcase` (Task 1).
- Produces: scrubbed display names; back-dated downtime spanning ≥ 2 weeks across multiple machines/reasons; believable `Tool.ShotCount`s; weekly production history sufficient for the Production Line Performance report; ≥1 pass + ≥1 fail inspection; a verification block that hard-fails on any gap or forbidden string.

- [ ] **Step 1: Read what the reports actually query.** Before writing history, read each report's read proc/NQ so the back-dated rows match the exact tables/date columns the report reads:

```bash
cd "C:/Users/JacquesPotgieter/Documents/Dev/MPP"
ls ignition/projects/Core/*/named-queries/reports/ 2>/dev/null; grep -rl "Downtime\|ShotCount\|LinePerformance\|Inventory" ignition/projects/Core --include=*.sql -i | grep -i report | head
```

Read: Downtime-by-Date-Range, Production-Line-Performance, Die-Cast-Shot-Count, Current-Inventory report SQL. Note the driving tables + the date column each filters on (this determines exactly what the overlay must INSERT/UPDATE).

- [ ] **Step 2: Write the overlay script.** `sql/scratch/seed_showcase_overlay.sql`, ASCII-only, no hardcoded `USE`, resolve everything by natural key. Structure:

```sql
-- seed_showcase_overlay.sql
-- Runs AFTER Reset-DevDatabase.ps1 (which runs seed_demo.sql) against MPP_MES_Showcase.
-- Idempotent overlay: (A) scrub customer/OEM display identifiers, (B) back-date
-- history so Downtime/Line-Performance/Shot-Count reports render rich, (C) add
-- inspections, (D) verify. ASCII-only. Run with -I.
SET NOCOUNT ON;

-- ============ (A) IDENTITY SCRUB (display Names only; codes/PartNumbers unchanged) ============
-- Facility root -> plausible non-customer die-cast name.
UPDATE Location.Location SET Name = N'Riverside Die Casting'
 WHERE Id = (SELECT Id FROM Location.Location WHERE ParentLocationId IS NULL);
-- Generic automotive-casting descriptive names, mapped by PartNumber natural key.
-- (Fill in the real PartNumbers from Task 1 Step 3; examples:)
UPDATE Parts.Item SET Name = N'Housing, Oil Pump'        WHERE PartNumber = N'<castingPN>';
UPDATE Parts.Item SET Name = N'Housing, Oil Pump (Machined)' WHERE PartNumber = N'<machinedPN>';
UPDATE Parts.Item SET Name = N'Bracket, Transmission Mount' WHERE PartNumber = N'<pn2>';
-- Scrub any area/cell Name that names the customer/OEM (spot-check output of the verify block).

-- ============ (B) BACK-DATED HISTORY ============
-- B1. Downtime across ~14 days, several machines + reason codes, CLOSED with durations.
--     Insert directly into Oee.DowntimeEvent (report reads history, not the live proc);
--     match the exact columns the report filters (StartedAt/EndedAt/DurationMinutes/
--     MachineLocationId/DowntimeReasonId) confirmed in Step 1. Use DATEADD from a fixed
--     anchor passed via :setvar or a declared @Anchor = CAST(SYSUTCDATETIME() AS DATE).
-- B2. Shot counts: set believable Tool.ShotCount on mounted dies.
UPDATE Tools.Tool SET ShotCount = 48250 WHERE Code = N'DEMO-DC-6NA';  -- confirm col/table in Step 1
-- B3. Weekly production spread for Line Performance: back-date a subset of ProductionEvent
--     rows (or insert summary rows) across 3-4 ISO weeks per the report's grouping column.

-- ============ (C) INSPECTIONS (pass + fail) ============
-- Ensure >=1 Pass and >=1 Fail Quality.QualitySample exist on captured lots
-- (seed_demo may already place a hold; add a passing + a failing sample if absent).

-- ============ (D) VERIFICATION (hard-fail on any gap or forbidden string) ============
DECLARE @bad INT = (
  SELECT COUNT(*) FROM (
    SELECT Name FROM Location.Location
    UNION ALL SELECT Name FROM Parts.Item
    UNION ALL SELECT PartNumber FROM Parts.Item
  ) x WHERE x.Name LIKE '%Honda%' OR x.Name LIKE '%Madison%'
     OR x.Name LIKE '%MPP%' OR x.Name LIKE '%AIM%');
IF @bad > 0 THROW 50001, 'Forbidden customer/OEM identifier present in display data.', 1;
-- Coverage asserts (THROW if unmet):
IF (SELECT COUNT(DISTINCT CAST(StartedAt AS DATE)) FROM Oee.DowntimeEvent) < 5
   THROW 50002, 'Downtime history spans < 5 distinct days.', 1;
IF NOT EXISTS (SELECT 1 FROM Quality.QualitySample) THROW 50003, 'No inspections seeded.', 1;
PRINT N'seed_showcase_overlay: verification passed.';
```

Replace every `<...>` placeholder and every guessed column/table name with the values confirmed in Step 1. The `UPDATE Tools.Tool`/`Oee.DowntimeEvent` column names above are provisional — confirm against the schema before running.

- [ ] **Step 3: Run the overlay.**

```bash
sqlcmd -S localhost -d MPP_MES_Showcase -E -b -I -C -i "C:/Users/JacquesPotgieter/Documents/Dev/MPP/sql/scratch/seed_showcase_overlay.sql"
```

Expected: "seed_showcase_overlay: verification passed." and exit 0. Any THROW = fix the gap and re-run (idempotent).

- [ ] **Step 4: Spot-check the report-critical spread.**

```bash
sqlcmd -S localhost -d MPP_MES_Showcase -E -I -C -W -Q "SELECT COUNT(*) AS DowntimeRows, MIN(StartedAt) AS FirstDT, MAX(StartedAt) AS LastDT FROM Oee.DowntimeEvent; SELECT Code, ShotCount FROM Tools.Tool WHERE ShotCount > 0;"
```

Expected: multiple downtime rows spanning ~2 weeks; non-zero shot counts.

- [ ] **Step 5: Commit the overlay script.**

```bash
git add sql/scratch/seed_showcase_overlay.sql
git commit -m "feat(seed): showcase overlay - identity scrub + back-dated report history"
```

---

## Task 3: Compliance accuracy gate (schema-verify the slide-13 table)

**Files:** none created (produces a short verified note appended to the plan-local scratch, and the final table content used in Task 6).

**Interfaces:**
- Produces: a confirmed subset of the six spec §7 rows, each substantiated by a concrete schema object. Unsupported rows are cut.

- [ ] **Step 1: Verify each claim against the live schema.** For each row, confirm the object exists:

```bash
cd "C:/Users/JacquesPotgieter/Documents/Dev/MPP"
grep -rniE "append-?only|LotEventLog|OperationLog|ProductionEvent" MPP_MES_DATA_MODEL.md | head
grep -rniE "ConfigLog|OldValue|NewValue|InterfaceLog" MPP_MES_DATA_MODEL.md | head
grep -rniE "DeprecatedAt|soft delete" MPP_MES_DATA_MODEL.md | head
grep -rniE "LotGenealogy|Closure|adjacency" MPP_MES_DATA_MODEL.md | head
grep -rniE "QualitySpec|Hold|nonconform" MPP_MES_DATA_MODEL.md | head
grep -rniE "VersionNumber|PublishedAt|Draft|Published|Deprecated" MPP_MES_DATA_MODEL.md | head
```

- [ ] **Step 2: Verify attribution + UTC-stamping conventions** (underpins ALCOA+ Attributable/Contemporaneous):

```bash
grep -rniE "AppUser|GETUTCDATETIME|GetUtcDateTime|AT TIME ZONE" MPP_MES_DATA_MODEL.md CLAUDE.md | head
```

- [ ] **Step 3: Finalize the table.** Keep only rows with a confirmed backing object. Record the final rows (feeds Task 6 slide 13). If a row cannot be substantiated, drop it — a shorter honest table beats an overclaim. No commit (no file yet).

---

## Task 4: Capture screenshots + render reports (gateway swap, human-in-the-loop)

**Files:**
- Create: `docs/showcase/screenshots/C01_lot_detail.png` … `C13_audit.png`
- Create: `docs/showcase/reports/*.pdf` + rasterized `*.png`

**Interfaces:**
- Consumes: populated `MPP_MES_Showcase`; the gateway pointed at it.
- Produces: all capture assets per spec §5 table (C1–C13), clean of forbidden identifiers.

- [ ] **Step 1: Stage the capture route list.** Write the ordered list of routes + the specific lot id (Task 1 Step 3) into the C1/C2 URLs. Create the output dir:

```bash
mkdir -p "C:/Users/JacquesPotgieter/Documents/Dev/MPP/docs/showcase/screenshots" "C:/Users/JacquesPotgieter/Documents/Dev/MPP/docs/showcase/reports"
```

- [ ] **Step 2: Ask Jacques to swap the gateway datasource to `MPP_MES_Showcase` and run `.\scan.ps1`.** Wait for confirmation. (This is the one blocking human step. Do not proceed until confirmed.)

- [ ] **Step 3: Sanity-check the gateway is serving showcase data.** In the in-app browser, load one populated route (e.g. `/shop-floor/lot-search`) and read the page — confirm it shows the scrubbed facility name and generic parts (no forbidden identifiers).

- [ ] **Step 4: Capture each Perspective screen (C1–C6, C10–C13).** For each route in spec §5: navigate, read_page to confirm the intended content is present + carries no forbidden string, then screenshot. Save to `docs/showcase/screenshots/CNN_<name>.png`. Prefer a desktop viewport (resize_window to 1280×800 or wider) for legibility.

- [ ] **Step 5: Render the PDF reports (C7–C9).** On `/shop-floor/reports`, for Lot Detail, Current Inventory, and Production Line Performance: generate the PDF (or temporarily default the landing view to each report per the reporting-capture note if interactive generation isn't possible in-browser), download the PDF to `docs/showcase/reports/`, then rasterize to PNG via PowerPoint COM is N/A for PDFs — use whichever of `pdftoppm`/`convert` is available, else open the PDF and screenshot. Confirm each renders NON-EMPTY (page count > 0, data visible). If a report is empty, the seed spread (Task 2) is insufficient — fix the overlay, ask Jacques to re-scan, re-render.

- [ ] **Step 6: Ask Jacques to swap the datasource back to `MPP_MES_Dev` and `.\scan.ps1`.** Confirm done.

- [ ] **Step 7: Final identifier scrub on captured assets.** Visually inspect every PNG/PDF for any `Honda/Madison/MPP/AIM` text (e.g. in a corner subtitle or report footer). Re-shot or crop any that leak. Commit the assets:

```bash
git add docs/showcase/screenshots docs/showcase/reports
git commit -m "assets(showcase): captured screens + rendered reports from MPP_MES_Showcase"
```

---

## Task 5: Assemble the deck structure from the template

**Files:**
- Create: `docs/showcase/build_deck.py` (or documented manual sequence)
- Create: `docs/showcase/Track-and-Trace-Showcase.pptx` (structural skeleton this task)
- Work dir: unpack under scratchpad; template copy at `<scratchpad>/template.pptx`.

**Interfaces:**
- Consumes: the branded template (Double Logo title/close + Section Header / Picture-with-Caption / Two Content / Comparison / Title-and-Content layouts).
- Produces: a 14-slide skeleton with the correct branded layout per spec §6, kickoff-specific slides removed, ready for content.

- [ ] **Step 1: Copy the template into the deliverable path.**

```bash
cp "C:/Users/JacquesPotgieter/Downloads/New Kickoff Meeting PowerPoint Template.pptx" "C:/Users/JacquesPotgieter/Documents/Dev/MPP/docs/showcase/Track-and-Trace-Showcase.pptx"
```

- [ ] **Step 2: Do ALL structural work first (per pptx skill: add/delete/reorder before editing content).** Keep slide 1 (Double Logo title) and slide 35 (Double Logo close). Delete kickoff slides 2–34. Add the feature slides by duplicating the right layout-bearing source slide with `add_slide.py`, so each new slide inherits a branded layout:
  - Section Header ×3 (Track & Trace / Live Movement / Reporting)
  - Picture-with-Caption ×7 (C1–C6, C10 single; and the report hub)
  - Two Content / Comparison ×2 (reports 2-up; config 2–3-up)
  - Title-and-Content ×1 (compliance capstone)

Use `python <pptx-skill>/scripts/add_slide.py unpacked/ slideN.xml --after slideM.xml`. Finalize `<p:sldIdLst>` order to match spec §6, then run `clean.py`.

- [ ] **Step 3: Repackage + validate the skeleton.**

```bash
python "<pptx-skill>/scripts/office/validate.py" "docs/showcase/Track-and-Trace-Showcase.pptx" --original "<scratchpad>/template.pptx"
```

Expected: structural checks pass (schema errors inherited from template are baselined by `--original`).

- [ ] **Step 4: Commit the skeleton.**

```bash
git add docs/showcase/Track-and-Trace-Showcase.pptx docs/showcase/build_deck.py
git commit -m "feat(deck): branded 14-slide skeleton from Blue Ridge template"
```

---

## Task 6: Fill deck content (titles, captions, images, speaker notes, compliance table)

**Files:** Modify `docs/showcase/Track-and-Trace-Showcase.pptx` (via `build_deck.py` / XML edits).

**Interfaces:**
- Consumes: the skeleton (Task 5), capture assets (Task 4), verified compliance rows (Task 3).
- Produces: the complete deck — every slide filled per spec §6/§7, zero placeholder text, zero forbidden identifiers.

- [ ] **Step 1: Fill the title + close (Double Logo).** Title: "Track & Trace + Genealogy" / "Manufacturing Execution — Capability Showcase". Close: keep branded tagline. Remove the "Kickoff Meeting" text.

- [ ] **Step 2: Fill the three Section Header dividers** with the pillar names + one-line framing (spec §6).

- [ ] **Step 3: Place screenshots into the Picture/Two-Content/Comparison slides** (C1–C6, C10–C12 config 2–3-up, report 2-up C7+C9). Size each image to read cleanly with ≥0.5" margins; tile config images with consistent gaps. Add the per-slide descriptive caption (1–2 lines, feature-not-selling) from spec §6.

- [ ] **Step 4: Build the compliance capstone (slide 13)** from the Task 3 verified rows, header "Built on a Data-Integrity Foundation", sub "Architected to support the record-keeping and traceability requirements of regulated manufacturing." Optional Audit Browser inset (C13). Use the "architected to support" language verbatim — no "compliant/certified".

- [ ] **Step 5: Add speaker notes** (presenter talk track) to each content slide via `slide.addNotes`-equivalent XML (notes slide), plain descriptive text.

- [ ] **Step 6: Repackage.** Zip from inside the unpacked dir (rm the old pptx first).

- [ ] **Step 7: Commit.**

```bash
git add docs/showcase/Track-and-Trace-Showcase.pptx docs/showcase/build_deck.py
git commit -m "feat(deck): fill showcase content + compliance capstone"
```

---

## Task 7: QA + deliver

**Files:** Modify the deck as QA requires.

- [ ] **Step 1: Content QA.**

```bash
python -c "import subprocess" # ensure markitdown available; if not: pip install 'markitdown[pptx]'
markitdown "docs/showcase/Track-and-Trace-Showcase.pptx" | grep -iE "\bx{3,}\b|lorem|ipsum|\bTODO|\[insert|\[Name\]|\[Title\]|Kickoff|Honda|Madison|\bMPP\b|\bAIM\b" || echo "CLEAN"
```

Expected: `CLEAN`. Any hit = fix and repackage.

- [ ] **Step 2: File QA.**

```bash
python "<pptx-skill>/scripts/office/validate.py" "docs/showcase/Track-and-Trace-Showcase.pptx" --original "<scratchpad>/template.pptx"
```

Expected: structural checks pass.

- [ ] **Step 3: Visual QA (render every slide via PowerPoint COM, inspect fresh).**

```powershell
# PowerShell: export deck to per-slide PNGs
$d="C:\Users\JacquesPotgieter\Documents\Dev\MPP\docs\showcase\Track-and-Trace-Showcase.pptx"
$o="C:\Users\JACQUE~1\AppData\Local\Temp\claude\...\scratchpad\qa_png"; New-Item -ItemType Directory -Force $o|Out-Null
$p=New-Object -ComObject PowerPoint.Application
$pr=$p.Presentations.Open($d,$true,$false,$false)
1..$pr.Slides.Count|%{ $pr.Slides.Item($_).Export((Join-Path $o "slide$_.png"),"PNG",1600,900) }
$pr.Close(); $p.Quit()
```

Inspect every exported PNG for: text overflow/cutoff (check first), overlaps, low contrast, misaligned/uneven image tiles, <0.5" margins, legibility of every screenshot, leftover template decoration mispositioned after edits. Fix issues in the generator, repackage, re-render only changed slides.

- [ ] **Step 4: Deliver.** Send the final `.pptx` to Jacques (SendUserFile) with a one-line note that it inherits the editable branded master. Final commit if any QA fixes were made:

```bash
git add docs/showcase/Track-and-Trace-Showcase.pptx docs/showcase/build_deck.py
git commit -m "fix(deck): QA pass - overflow/alignment/contrast"
```

---

## Self-Review notes

- **Spec coverage:** §1 positioning → Tasks 2/4/6/7 scrub gates; §2 brand → Tasks 5/6; §3 pipeline → Tasks 1/4; §4 seed → Tasks 1/2; §5 capture → Task 4; §6 deck → Tasks 5/6; §7 compliance → Tasks 3/6; §8 QA → Task 7. All covered.
- **Human-in-the-loop:** Task 4 Steps 2 & 6 are the only blocking Jacques steps (datasource swap both ways) — bounded, all data staged first.
- **Provisional schema names** (`Oee.DowntimeEvent` columns, `Tools.Tool.ShotCount`, status-code joins) are explicitly flagged to confirm in Task 2 Step 1 against the live schema/report SQL before running — not assumed.
- **Report emptiness risk** handled by Task 4 Step 5's non-empty gate feeding back into the Task 2 overlay.
