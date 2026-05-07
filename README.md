# MPP MES Replacement Project

Blue Ridge Automation's MES replacement for **Madison Precision Products** (Honda Tier 2 die cast aluminum supplier, Madison IN). Replacing the legacy WPF/.NET "Manufacturing Director" MES with an **Ignition Perspective + SQL Server 2022** system.

**Client:** Madison Precision Products, Inc.
**Contractor:** Blue Ridge Automation
**Based On:** Flexware FRS v1.0, annotated by Blue Ridge
**Core mission:** Full LOT traceability from raw aluminum through shipping. Honda requires complete genealogy for every part.

---

## Start Here

Read in this order. Each document builds on the previous.

| # | Document | Purpose |
|---|---|---|
| 1 | [`CLAUDE.md`](./CLAUDE.md) | Project context and document map (start here for AI-agent collaboration) |
| 2 | [`MPP_MES_SUMMARY.md`](./MPP_MES_SUMMARY.md) | High-level summary: scope matrix, data model overview, design decisions, session notes |
| 3 | [`MPP_MES_USER_JOURNEYS.md`](./MPP_MES_USER_JOURNEYS.md) | Two narrative arcs — Configuration Tool + Plant Floor day-in-the-life — with 19 assumption decisions |
| 4 | [`MPP_MES_DATA_MODEL.md`](./MPP_MES_DATA_MODEL.md) | Column-level specification for all ~50 tables across 7 schemas |
| 5 | [`MPP_MES_FDS.md`](./MPP_MES_FDS.md) | Functional Design Specification — 15 sections, numbered requirements (FDS-XX-NNN), open items register |
| 6 | [`MPP_MES_ERD.html`](./MPP_MES_ERD.html) | Interactive ERD with per-schema tabs, open in a browser |
| 7 | [`MPP_MES_Open_Issues_Register.docx`](./MPP_MES_Open_Issues_Register.docx) | Consolidated open items with FRS/FDS references and status tags |

All `.md` files have matching `.docx` versions generated via pandoc — see [Regenerating Word Docs](#regenerating-word-docs) below.

---

## Folder Structure

```
mpp/
├── CLAUDE.md                           Project instructions for AI agents
├── README.md                           This file
│
├── MPP_MES_FDS.md / .docx              Functional Design Specification
├── MPP_MES_DATA_MODEL.md / .docx       Data model reference (schemas, tables, columns)
├── MPP_MES_SUMMARY.md / .docx          System summary and scope assessment
├── MPP_MES_USER_JOURNEYS.md / .docx    Narrative user journeys
├── MPP_MES_ERD.html                    Interactive ERD
├── MPP_MES_Open_Issues_Register.docx   Open items register (authored in Word directly)
├── sql_best_practices_mes.md           SQL conventions
│
├── ignition/                          Ignition gateway resources we ship
│   ├── projects/MPP_Config/              Perspective project export (views, stylesheet, page-config)
│   └── icons/mpp/                        Custom Perspective icon library (mpp.svg + config.json + resource.json)
│                                          Mirrors gateway path data/config/resources/core/com.inductiveautomation.perspective/icons/mpp/
│                                          See ignition/icons/README.md for deploy + recolor recipe.
│
├── reference/                          Source material — scope matrix, production sheets, PLC spec
│   ├── MPP_Scope_Matrix.xlsx              Scope authority (37 rows: MVP/CONDITIONAL/FUTURE)
│   ├── Excel Prod Sheets.xlsx             Paper production sheet templates
│   ├── MS1FM-*.xlsx                       11 line-specific production sheets
│   ├── 2011230 5GO_AP4 Automation Touchpoint Agreement.pdf
│   └── 5GO_AP4_Automation_Touchpoint_Agreement.md   Markdown conversion of the PLC spec
│
├── mpp_frs_md/                         Flexware FRS source (22 annotated markdown files)
│   ├── 00_glossary.md
│   ├── 01_introduction.md
│   ├── ... (sections 2-6 + 14 appendices)
│   └── SPARK_DEPENDENCY_REGISTER.md    Spark dependency analysis + Blue Ridge design decisions
│
├── templates/                          Blue Ridge Word templates and letterhead
│
├── reference.docx                      Pandoc reference doc for Word output styling
├── style_docx_tables.js                Post-processor that adds bordered + striped tables
│
└── package.json                        Node dependencies (jszip for docx post-processing)
```

---

## Key Facts

- **Architecture:** Ignition Gateway (Perspective UI, Tag Historian, Gateway Scripts) + SQL Server 2022 with 7 schemas.
- **Auth:** Active Directory + Ignition roles. Clock number + PIN for shop floor. No custom RBAC.
- **Scope:** 17 MVP items, 5 conditional, 15 future. The scope matrix at `reference/MPP_Scope_Matrix.xlsx` is the authority.
- **Location model:** ISA-95 5-tier hierarchy (Enterprise → Site → Area → Work Center → Cell) with polymorphic `LocationTypeDefinition` kinds (Terminal, DieCastMachine, CNCMachine, InventoryLocation, etc.) under the Cell tier.
- **External interfaces:** AIM (Honda EDI) and Zebra printers called directly, with all requests/responses logged to `InterfaceLog` (per OI-01 resolution — no event outbox).
- **Naming:** All DB identifiers use `UpperCamelCase`. See `sql_best_practices_mes.md`.

---

## Conventions

- **FDS requirements:** Numbered `FDS-XX-NNN` (section-sequence). RFC 2119 keywords (SHALL, SHALL NOT, SHOULD, MAY, FUTURE).
- **Scope tags:** Every section and table carries `MVP`, `MVP-EXPANDED`, `MVP-LITE`, `CONDITIONAL`, or `FUTURE`.
- **FRS crosswalk:** FDS requirements reference originating FRS sections in parentheses, e.g., `(FRS 3.9.6)`.
- **Open item status:** ✅ Resolved | 🔶 Pending Customer Validation / Pending Internal Review | ⬜ Open

Every project document (FDS, Data Model, Summary, User Journeys) carries a **Revision History** table near the top. Update it when you edit.

---

## Regenerating Word Docs

All four core markdown documents are converted to Word via pandoc with custom table styling:

```bash
# Single document
pandoc MPP_MES_FDS.md -o MPP_MES_FDS.docx \
    --from markdown --to docx \
    --toc --toc-depth=3 \
    --reference-doc=reference.docx \
    --metadata title="MPP MES — Functional Design Specification"
node style_docx_tables.js MPP_MES_FDS.docx
```

The `style_docx_tables.js` post-processor adds:
- Bordered tables (gray outer, lighter inner gridlines)
- Dark blue header row with white bold text
- Alternating row shading (light gray on even rows)

Repeat for `MPP_MES_DATA_MODEL.md`, `MPP_MES_SUMMARY.md`, and `MPP_MES_USER_JOURNEYS.md` (adjust the title metadata accordingly).

**Requirements:** `pandoc` (tested on 3.9.0.2) and `node` with `jszip` installed (`npm install`).

**Note on opening in Word:** Pandoc generates an empty TOC field — on first open in Word, right-click the TOC placeholder and select "Update Field" to populate it.

---

## Current Status (2026-04-10)

- Data model, FDS, Summary, and User Journeys are all at v0.4 (or higher)
- 3 of 10 original OI items resolved; 4 pending customer validation; 2 remain open
- Not yet started: Ignition project setup, Perspective screens, SQL DDL scripts, seed data, PLC integration, testing

See `MPP_MES_SUMMARY.md` "Remaining Tasks" for the full roadmap and `MPP_MES_Open_Issues_Register.docx` for open item detail.
