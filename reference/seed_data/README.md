# MPP MES — Seed Data

CSV files extracted from `reference/MPP_FRS_Draft.pdf` (Flexware FRS v1.0, 3/15/2024). These are the row-level master data tables that will be loaded into the MES at deployment.

**Source:** Appendices B, C, D, E of the FRS PDF, extracted via `pdftotext -table` and parsed by Node.js scripts. The original markdown extracts in `mpp_frs_md/` are also derived from the same PDF but with poorer column fidelity — these CSVs are the canonical form.

**Status:** Authoritative for seed data loading. Update only when MPP provides revised lists or when discrepancies are found against the source PDF.

**Last extracted:** 2026-04-10 from `MPP_FRS_Draft.pdf`

---

## Files

| File | Source | Rows | Target table | Purpose |
|---|---|---|---|---|
| `machines.csv` | Appendix B (pp 81–86) | ~228 | `Location` (Cell tier, machine kinds) | Plant equipment master — tonnage, cycle times, departments |
| `opc_tags.csv` | Appendix C (pp 87–91) | ~150 | (Ignition OPC config — not a SQL table) | OPC tag catalog for OmniServer and TOPServer |
| `downtime_reason_codes.csv` | Appendix D (pp 92–105) | ~660 | `DowntimeReasonCode` | Operator-selectable downtime reasons by area and type |
| `defect_codes.csv` | Appendix E (pp 106–110) | ~145 | `DefectCode` | Reject/scrap defect codes by area |
| `die_shots_report.csv` | `Aug 17_ 2026 Die Shots Report.html` | 343 | — (source extract) | Flat part × die extract of the legacy MES die-shots page, as published |
| `die_roster.csv` | the above + `Copy of Asset #'s for Dies.xlsx` | 253 | `Tools.Tool` | **One row per physical die** — asset tag, status, generation letter, cavity count, shot counts, vendor |
| `die_cavities.csv` | same | 371 | `Tools.ToolCavity` | One row per (die, cavity) with the Macola part number |

---

## Column Definitions

### `machines.csv`

Maps to seed data for `Location` records of definition `DieCastMachine`, `CNCMachine`, `TrimPress`, `AssemblyStation`, etc. The legacy MES used a flat machine list; in the new model these become Cell-tier `Location` instances with appropriate `LocationTypeDefinition` references.

| Column | Type | Description |
|---|---|---|
| `MachId` | INT | Sequential machine identifier from legacy MES |
| `MachNo` | VARCHAR | MPP-assigned machine number (often matches MachId; sometimes differs) |
| `MachDesc` | VARCHAR | Machine name/description (e.g., "DieCast#7", "Side Case OP30-2") |
| `Tonnage` | DECIMAL | Press tonnage where applicable; 0 or empty for non-press equipment |
| `DeptDesc` | VARCHAR | Department/area name (Die Cast, Trim Shop, Machine Shop, Assembly, etc.) |
| `MinPerShift` | INT | Available production minutes per shift |
| `RefCycleTime` | INT | Reference cycle time in seconds for OEE performance calculation |
| `ProdPerShift` | INT | Target production count per shift (often 0/empty in legacy data) |
| `CycleTime` | DECIMAL | Actual cycle time |
| `OeeTarget` | DECIMAL | Target OEE percentage (often empty in legacy data) |
| `PlannedQty100p` | INT | Planned quantity at 100% performance (often empty) |
| `DeptCode` | VARCHAR | Short department code (DC, TR, MS, AS) |
| `DeptCode2Desc` | VARCHAR | Department description (denormalized from DeptDesc) |
| `ProcId` | INT | Process identifier |
| `ProcDesc` | VARCHAR | Process description (Diecast, Trim, Machine, Assembly) |
| `OrigProc` | INT | Original process flag |

### `opc_tags.csv`

OPC tag catalog from Appendix C. These define which scales (OmniServer) and PLCs (TOPServer / SWToolbox) the MES communicates with. Not a SQL table — this drives Ignition OPC connection configuration.

| Column | Type | Description |
|---|---|---|
| `ServerName` | VARCHAR | OPC server short name (Omni or Top) |
| `ServerPid` | VARCHAR | Full OPC server identifier (OmniServer, SWToolbox.S7-1200, etc.) |
| `Direction` | VARCHAR | Read or Write |
| `AccessPath` | VARCHAR | OPC access path (often empty) |
| `OpcItemId` | VARCHAR | Full OPC item ID (e.g., `59B_1_FP_1.NET_DataReady`) |

### `downtime_reason_codes.csv`

Maps directly to `DowntimeReasonCode` table. ~660 rows organized by area and type. The "excused" flag drives whether downtime counts against OEE availability.

| Column | Type | Maps To | Description |
|---|---|---|---|
| `ReasonId` | INT | (legacy) | Sequential reason identifier from legacy MES |
| `ReasonDesc` | VARCHAR | `DowntimeReasonCode.Description` | Operator-facing reason text |
| `DeptId` | INT | (legacy) | Numeric department identifier from legacy |
| `DeptDesc` | VARCHAR | (resolves to `Location.Name` for Area) | Area name (Die Cast, Trim Shop, etc.) |
| `DeptCode` | VARCHAR | `DowntimeReasonCode.Code` short code | Short department code (DC, TR, MS, AS) |
| `TypeId` | INT | (legacy) | Numeric type identifier |
| `TypeDesc` | VARCHAR | `DowntimeReasonType.Name` | Type category (Equipment, Mold, Quality, Setup, Miscellaneous, Unscheduled) |
| `Excused` | BIT | `DowntimeReasonCode.IsExcused` | 0 = counts against availability, 1 = excused |

### `defect_codes.csv`

Maps directly to `DefectCode` table. ~145 rows organized by area.

| Column | Type | Maps To | Description |
|---|---|---|---|
| `DefectCode` | INT | `DefectCode.Code` | Numeric defect code from legacy MES |
| `DefectDescription` | VARCHAR | `DefectCode.Description` | Operator-facing defect text |
| `DeptId` | INT | (legacy) | Numeric department identifier |
| `DeptDesc` | VARCHAR | (resolves to `Location.Name` for Area) | Area name |
| `Excused` | BIT | `DefectCode.IsExcused` | 0 = counts against quality rate, 1 = excused |

---

## Parsing Notes

The PDF uses fixed-position table layouts that wrap long descriptions across multiple lines. The parsers handle this by:

1. Reading line-by-line through `pdftotext -table` output
2. Detecting "data rows" by leading whitespace + numeric ID pattern
3. Buffering "fragment lines" (no ID) as description prefixes for the next data row
4. Joining accumulated prefixes to the data row's parsed description

**Known good wrapped rows:**
- Appendix E row 122: "Dimensional (All dimensional except pin size and or depth/height)" — 3 source lines stitched into one cell
- Appendix B row 188: "Side Case OP30-2" — prefix "Side Case OP30-" + suffix "2"
- Appendix B rows 183, 184, 185, 186, 191, 196, etc.: similar prefix-stitch handling

If parsing produces row counts that differ significantly from expected, see `parse_warnings.md` (generated only if warnings exist).

## Regenerating

```bash
# Extract from PDF
pdftotext -table -f 81 -l 86 reference/MPP_FRS_Draft.pdf reference/seed_data/_appendix_b_raw.txt
pdftotext -table -f 87 -l 91 reference/MPP_FRS_Draft.pdf reference/seed_data/_appendix_c_raw.txt
pdftotext -table -f 92 -l 105 reference/MPP_FRS_Draft.pdf reference/seed_data/_appendix_d_raw.txt
pdftotext -table -f 106 -l 110 reference/MPP_FRS_Draft.pdf reference/seed_data/_appendix_e_raw.txt

# Run parsers (in build/ or scripts/ folder, TBD)
node parse_appendix_b.js
node parse_appendix_c.js
node parse_appendix_d.js
node parse_appendix_e.js

# Regenerate Excel workbook
node build_seed_workbook.js
```

---

## Die roster (`die_roster.csv` / `die_cavities.csv`)

These two are **not** FRS extracts — they are built from the two tooling artefacts MPP
delivered on 2026-09-12, and they are derived, not raw. Regenerate with:

```bash
python reference/seed_data/parsers/build_die_roster.py
```

The Die Shots Report lists a die **once per part number it casts**, so its 343 rows are not
343 dies. The parser collapses them into physical dies by clustering near-identical shot
counts within a (family, component, generation-letter) bucket, then joins the asset register
on the same key plus journal position / cam bank. The part numbers in each cluster are that
die's cavities.

Seeding-registry item: **S-14**. Full analysis, including the two things the legacy data does
not map cleanly and the four open questions for MPP:
`notes/2026-09-12_die-asset-register-and-shot-report.md`.

> **`CavityCount` is a lower bound.** It counts *distinct part numbers cast per shot*. A die
> with four identical cavities making one part number reads as 1 — the report cannot see it.
> MPP has to supply the true count for single-part dies.
