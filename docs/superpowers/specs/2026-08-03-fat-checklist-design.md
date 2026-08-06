# FAT Checklist — Design Spec

**Date:** 2026-08-03
**Author:** Claude (Opus 4.8) with Jacques Potgieter
**Status:** Draft for review
**Deliverable:** A Factory Acceptance Test (FAT) checklist for the MPP MES — a **contractual, MPP-witnessed sign-off artifact** covering the full MVP scope (Config Tool / Arc 1 **and** Plant Floor / Arc 2).

---

## 1. Purpose & role

This is the **formal acceptance document** MPP (and, where relevant, Honda-facing traceability) witnesses before cutover. It is the contractual "the system does what was specified" record. Every test row must be witnessable: a clear procedure, an expected result, and columns to record pass/fail plus witness initials and date.

It is **not** an internal QA shakedown list and not a bug tracker. (Blue Ridge may run it internally first as a dry run, but the artifact's identity is the witnessed sign-off.)

## 2. Scope

- **Full MVP / MVP-EXPANDED**, both arcs.
- Config Tool (Arc 1): plant hierarchy, item master, routes, BOMs, quality specs, operation templates, container configs, code tables, PLC device mapping, users/attribution, shift schedules.
- Plant Floor (Arc 2): terminal/login, die cast, trim, machining, assembly, third-party inspection, quality capture & holds, movements, LOT traceability & genealogy, shift/downtime, labels & printing, audit browser.
- **Out of MVP** (FDS `FUTURE` requirements — Work Order demand/maintenance flows, OEE §9.5, NCM §8.6, Macola/Intelex/SCADA interfaces §13.2–13.4) is represented in the FDS index as **`Out-of-scope`** and `CONDITIONAL` items (Data Migration §14, Sampling §8.4, Work Orders MVP-LITE) as **`Conditional`** — never silently dropped, so the coverage sheet distinguishes "not tested because out of scope" from "not tested (gap)."

## 3. Format decision

**CSV-per-area (canonical, hand-edited) → Node builder → single `.xlsx` workbook.**

This mirrors the repo's established `reference/seed_data/` pattern (per-CSV canonical source + `build_seed_workbook.js` using SheetJS `xlsx`, CSVs are truth, workbook is a regenerated derivative). The Excel workbook is the working/witnessing form: filterable, sortable, one row per witnessable test step, printable per-tab for a station lead.

*(Alternatives rejected: a single master CSV split by `Area` at build time — breaks the per-file convention and noisier per-area diffs; Word `.docx` — the earlier decision preferred a filterable tracker over a signed prose document.)*

## 4. FDS traceability model — requirements are the **section spine**, not a per-row column

The FAT measures the built system against the **FDS** — Blue Ridge's own authored design spec (`MPP_MES_FDS.md`), which is current, MVP-scope-tagged per requirement, and already carries the client FRS crosswalk. Each FDS requirement carries its **FRS clause as a secondary reference**, so the acceptance is against the FDS but every requirement still traces back to the client's FRS.

The decisive design choice: FDS requirements organize the checklist as **sections**, not as a tag repeated on every row. A witness walks **requirement by requirement**; the test steps under each requirement are how it is proven. This keeps rows clean and makes the acceptance question legible: *was `FDS-05-034` witnessed — yes/no.*

- Each area sheet is divided into **FDS-requirement sections**. A section is a banner row: **`FDS-05-034 — Die-Cast-Origin Tool + Cavity Required (FRS 3.9.6)`** followed by that requirement's test steps.
- Test steps with **no FDS origin** (Config Tool setup surfaces, infra, Blue Ridge-added affordances) collect under an explicit **`Blue Ridge / Non-FDS`** section per sheet. A deliberate bucket, never a blank that reads as an oversight.
- A rare cross-cutting step may note a *secondary* requirement in its `Notes`, but its home is one section.

### 4.1 FDS index — the one place the requirement structure is asserted

`docs/fat/fds_index.csv` is the master list of FDS requirements, **extracted** from `MPP_MES_FDS.md` by `extract_fds_index.js` (parses each `#### FDS-XX-NNN — Title — \`SCOPE\`` header, its section, and the first `(FRS x.y.z)` in the body):

| Column | Meaning |
|---|---|
| `FDS` | Requirement id, e.g. `FDS-05-034` |
| `Title` | Section-banner title (from the FDS header) |
| `Section` | FDS subsection, e.g. `5.1 LOT Identity` |
| `Area` | Which area sheet the requirement's section lives on |
| `Scope` | Raw FDS tag: `MVP` / `MVP-EXPANDED` / `MVP-LITE` / `CONDITIONAL` / `FUTURE` |
| `InScope` | Derived: `Y` / `Conditional` / `Out-of-scope` |
| `FRS` | FRS crosswalk clause(s) from the FDS body (secondary reference) |
| `Verify` | `VERIFY` until Jacques signs off the mapping (see §6) |

242 requirements extracted across 15 sections. **Area placement** is best-effort: the FDS organizes by lifecycle concern (`§5 LOT Lifecycle`), the FAT by station (Die Cast / Trim / Machining), so the extractor uses a section→area map with subsection and per-id overrides; cross-station requirements (e.g. the die-cast basket lifecycle `FDS-05-039..042`) are re-filed to the station sheet. Jacques verifies placement.

## 5. Workbook structure

### 5.1 Sheets

1. **Cover / Summary** — project + parties, scope statement, the environment/build under test (gateway version, DB, git commit/tag), the witness & sign-off block, and an auto-rolled-up count table (per area: total / pass / fail / open / N-A).
2. **Coverage (FDS → tests)** — *generated*, not hand-authored. Left-joins `fds_index` to every test row: each in-scope requirement → the covering `TestID`(s) (with Section, Area, Scope, FRS crosswalk); any in-scope requirement with no covering test flagged **`⚠ NO TEST`**; out-of-scope requirements listed as `Out-of-scope`. This is the both-directions completeness proof and it can never drift from the forward rows because it is derived from them.
3. **One sheet per area**, in delivery order — Config Tool areas first, then Plant Floor areas — each internally sectioned by FDS requirement (§4).

### 5.2 Area sheets (initial set)

**Config Tool:** Plant Hierarchy · Item Master · Routes & BOMs · Quality Specs & Op Templates · Container Configs · Code Tables (defect/downtime) · Shift Schedules · PLC Device Mapping · Users & Attribution.

**Plant Floor:** Terminal & Login · Die Cast · Trim · Machining · Assembly · Third-Party Inspection · Quality Capture & Holds · Movements & Inventory · LOT Traceability & Genealogy · Shift & Downtime · Labels & Printing · Audit Browser.

(Areas are a starting partition; the builder derives tabs from the CSV files actually present in `docs/fat/`, so adding/splitting an area is just adding/renaming a CSV.)

### 5.3 Test row schema (per-area CSV columns)

| Column | Purpose |
|---|---|
| `TestID` | Area-prefixed, incrementing by 10 — `FAT-DC-010`, `FAT-TRC-020`. Stable handle for defects/re-tests. |
| `FDS` | The requirement this row is filed under (the grouping key; must be indexed to this area), or `NONE` for the Blue Ridge / Non-FDS section. |
| `Workflow` | The scenario the step belongs to (e.g. "Open cavity basket → accumulate → release"). Visual grouping within a section. |
| `Precondition` | State/setup required before the step (terminal, seeded data, prior step). |
| `Step` | The action the witness performs. |
| `Expected Result` | What must be observed to pass. |
| `Result` | Pass / Fail / N/A — filled by the witness. |
| `Witness` | Initials. |
| `Date` | Date witnessed. |
| `Notes` | Free text; defect reference on a fail; optional secondary requirement/FRS. |

The requirement **title** and **FRS crosswalk** live only in `fds_index`, never repeated on rows.

### 5.4 Builder — `docs/fat/build_fat_workbook.js`

Node + SheetJS `xlsx` (same dependency as `build_seed_workbook.js`). Responsibilities:

1. Read `fds_index.csv` and every `areas/<slug>.csv`.
2. For each area sheet: order rows by their `FDS` requirement (index order), emit a **section banner row** per requirement (`FDS-xx-nnn — Title (FRS x.y.z)`), place `NONE` rows under a trailing **Blue Ridge / Non-FDS** banner, and flag any row whose `FDS` isn't indexed to this area under an `⚠ Unfiled` banner. In-scope requirements with no authored steps get a `⚠ no test steps authored yet` placeholder.
3. Generate the **Coverage** sheet by left-joining `fds_index` to the union of all test rows on `FDS`.
4. Generate the **Cover / Summary** roll-up (per-area `COUNTIF` formulas over each sheet's Result column).
5. Column widths + `══` text-glyph banners (see §7 styling). Output `docs/fat/MPP_MES_FAT.xlsx`.

Regeneration workflow (documented in `docs/fat/README.md`): edit CSVs → `node docs/fat/build_fat_workbook.js` → commit both CSVs and the regenerated `.xlsx`.

## 6. FDS pre-population & verification

Jacques verifies; Claude pre-populates. Specifically:

- `extract_fds_index.js` parses `MPP_MES_FDS.md` into `fds_index.csv` (242 requirements: id → title → section → area → scope → FRS crosswalk), every row marked `VERIFY`. Area placement uses a section→area map with subsection + per-id overrides and is best-effort — the FDS organizes by lifecycle, the FAT by station.
- Claude drafts the test rows per area from the **actual current build** — commit history and live code — **not** the stale `ARC2_FDS_CONFORMANCE.md` / `ARC2_REVIEW_FINDINGS.md` (dated 2026-06-26; much has shipped since — downtime mgmt, shift schedules, per-cavity die cast, third-party inspection, PLC tray-close, multi-source FIFO machining). Those two docs are consulted as *reference only, low weight.*
- Jacques reviews and clears the `VERIFY` flags (and corrects area placement / scope calls). The `Verify` column makes the un-reviewed rows obvious at a glance and greppable.

## 7. Non-goals / styling / deferred

- **FRS as secondary reference only** — the spine is the FDS; each requirement's FRS crosswalk rides along in the index and Coverage sheet, not as a row tag.
- **Styling:** the community `xlsx` build sets widths but not fills/bold; section banners use `══` text glyphs. Swap to `exceljs` if MPP wants full visual styling — the CSV contract is unchanged.
- **No automated execution** — human-witnessed checklist; the SQL test suite (2225 tests) is separate internal evidence, not re-expressed here (the Cover sheet may cite it as supporting evidence).
- **No Word/PDF rendering in v1.** If MPP later wants a signed PDF, the `.xlsx` prints per-tab; a `.docx` render can be added without changing the CSV source of truth.

## 8. Deliverables

```
docs/fat/
  README.md                 # regeneration workflow + column legend
  extract_fds_index.js      # one-shot: MPP_MES_FDS.md -> fds_index.csv
  fds_index.csv             # FDS requirement spine (VERIFY-flagged), 242 reqs
  areas/<slug>.csv          # per-area test rows, pre-populated from current build
  build_fat_workbook.js     # SheetJS builder → grouped sheets + Coverage + Cover
  MPP_MES_FAT.xlsx          # generated derivative (committed)
```

## 9. Build sequence

1. ✅ `extract_fds_index.js` + `fds_index.csv` — full requirement spine from the FDS, scope flags, area placement (all `VERIFY`).
2. ✅ `build_fat_workbook.js` — grouping + Coverage + Cover, proven with 3 sample area CSVs (die-cast, traceability, item-master).
3. ✅ Author remaining `areas/<slug>.csv` files from the current build — all 22 areas authored (367 test steps), fanned out across 8 grounded subagents + gap-fill pass. Full in-scope coverage: **226/226** requirements witnessed, 0 orphan/unfiled, 0 malformed rows.
4. ✅ `README.md` + `MPP_MES_FAT.xlsx` regenerated (24 sheets: Cover, Coverage, 22 area tabs).
5. Hand to Jacques to clear `VERIFY` flags on `fds_index.csv` and witness-test.
5. Hand to Jacques to clear `VERIFY` flags and witness-test.
