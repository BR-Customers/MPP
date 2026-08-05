# FAT Checklist — `docs/fat/`

Factory Acceptance Test for the MPP MES. A **contractual, MPP-witnessed sign-off** covering the full MVP (Config Tool / Arc 1 + Plant Floor / Arc 2). Design spec: [`docs/superpowers/specs/2026-08-03-fat-checklist-design.md`](../superpowers/specs/2026-08-03-fat-checklist-design.md).

The FAT measures the built system against the **FDS** (`MPP_MES_FDS.md`, Blue Ridge's authored design spec). Each FDS requirement carries its **FRS crosswalk** as a secondary reference, so every accepted requirement still traces back to the client's FRS clause.

## Canonical source vs. derivative

- **Canonical (hand-edit these):** `fds_index.csv` + `areas/<slug>.csv`.
- **Derivative (never hand-edit):** `MPP_MES_FAT.xlsx` — regenerated from the CSVs.

Regenerate after any CSV change:

```bash
node docs/fat/build_fat_workbook.js
```

Commit both the CSVs and the regenerated `.xlsx`.

## FDS requirements are the section spine

`fds_index.csv` is the master list of FDS requirements — the **section headers**, authored once. Requirement traceability lives here, not as a tag on every test row. It is pre-populated by an extractor:

```bash
node docs/fat/extract_fds_index.js   # re-parse MPP_MES_FDS.md -> fds_index.csv
```

| Column | Meaning |
|---|---|
| `FDS` | Requirement id (e.g. `FDS-05-034`) |
| `Title` | Section-banner title (from the FDS header) |
| `Section` | FDS subsection, e.g. `5.1 LOT Identity` |
| `Area` | Slug of the area sheet the requirement's section lives on (see `SHEETS` in the builder). Blank = requirement with no sheet home (e.g. §14 Data Migration). |
| `Scope` | Raw FDS tag: `MVP` / `MVP-EXPANDED` / `MVP-LITE` / `CONDITIONAL` / `FUTURE` |
| `InScope` | Derived: `Y` (MVP*) / `Conditional` / `Out-of-scope` (FUTURE) |
| `FRS` | FRS crosswalk clause(s) from the FDS body, secondary reference |
| `Verify` | `VERIFY` until the mapping has been checked and signed off |

> Every row currently carries `VERIFY`. The extractor's **area placement** and **scope** are a best-effort pre-population — the FDS organizes by lifecycle concern, the FAT by station, so some requirements need re-filing to the right area sheet (change the `Area` cell). Verify each and clear the flag (blank the cell). Re-running the extractor **overwrites** `fds_index.csv`, so make area/scope corrections either in the extractor's mapping tables (`ID_AREA` / `SUBSECTION_AREA`) or after the final extract.

## Test rows — `areas/<slug>.csv`

One witnessable step per row. Columns:

`TestID, FDS, Workflow, Precondition, Step, Expected Result, Result, Witness, Date, Notes`

- `TestID` — area-prefixed, increments of 10 (`FAT-DC-010`). Stable handle for defects/re-tests.
- `FDS` — the requirement this row is filed under (must exist in `fds_index.csv` **and** be indexed to this area), or `NONE` for Blue Ridge / Non-FDS steps (setup, infra, BRA-added affordances).
- `Result / Witness / Date` — left blank; filled during witnessing.

Rows are drafted from the **current build** (commit history + live code). The month-old `../ARC2_FDS_CONFORMANCE.md` / `../ARC2_REVIEW_FINDINGS.md` are low-weight reference only — a lot shipped after them (downtime mgmt, shift schedules, per-cavity die cast, third-party inspection, PLC tray-close, multi-source FIFO machining).

## Generated sheets

- **Cover** — parties, "measured against the FDS", scope, environment-under-test, sign-off block, and a live roll-up (per-area `COUNTIF` over each sheet's Result column).
- **Coverage** — every FDS requirement → covering `TestID`(s), with Section, Area, Scope, and FRS crosswalk. In-scope requirements with no test are flagged **`⚠ NO TEST`**; out-of-scope show `Out-of-scope`; test rows citing an unknown id surface as `⚠ UNKNOWN REQUIREMENT`. Derived, so it can't drift from the rows.
- **One sheet per area** — test rows grouped into `══ FDS-xx-nnn — Title (FRS x.y.z)` section banners, with a trailing `══ Blue Ridge / Non-FDS` section. In-scope requirements with no authored steps show a `⚠ no test steps authored yet` placeholder so gaps are visible where the witness works.

## Adding / re-filing

- **New area:** add `areas/<slug>.csv` + ensure `<slug>`/name is in the `SHEETS` array in `build_fat_workbook.js`.
- **Re-file a requirement** to a different area sheet: change its `Area` cell in `fds_index.csv` (or the extractor's mapping tables, then re-extract).
- Each test row's `FDS` must point at a requirement whose `Area` is that sheet's slug (or `NONE`) — otherwise the builder lists it under an `⚠ Unfiled` banner.

## Styling

The builder uses **ExcelJS** (`exceljs`, a saved dependency). The generated workbook has:

- Frozen bold header row on every sheet.
- Colored, merged **section banners** — blue for FDS requirements (with the FRS crosswalk + scope tag), green for Blue Ridge / Non-FDS, orange for any unfiled/warning block.
- Wrapped, top-aligned text with estimated row heights, thin cell borders, and zebra striping within each section.
- The **Result / Witness / Date** columns highlighted as fill-in cells; Result carries a `Pass / Fail / N/A` dropdown.
- **Coverage** sheet with color-coded flags (green Covered, red ⚠ NO TEST, amber Conditional, grey Out-of-scope).
- **Cover** sheet with a styled sign-off table and a live roll-up (`COUNTIF` over each area's Result column).

Row heights are pre-estimated so wrapped text shows without needing Excel's auto-fit. The CSV contract is unchanged — restyling never touches the source data.
