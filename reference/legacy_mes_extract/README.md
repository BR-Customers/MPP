# Legacy MES / EMMD extract — CSV snapshot

Data pulled from the **legacy production databases on `EXCSRV05`** during the
2026-07-08 mapping session and cached here as CSVs so it can be reused (e.g. a
future full-catalog seed / analysis) without re-querying.

## Source

| DB | What it is | Extract script |
|----|------------|----------------|
| `MES` | Live SparkMES-lineage MES (parts, BOMs, routing, lots) | `sql/scratch/emmd_extract_master_data.sql` |
| `EMMD` | Flexware Execution-Management automation engine (OPC/handshake) | `sql/scratch/emmd_extract_automation_config.sql` |
| both | Schema discovery (tables / columns / FKs) | `sql/scratch/emmd_discovery.sql` |

## Provenance & fidelity

These CSVs were **transcribed from the SSMS result grids pasted into the
2026-07-08 chat** — the legacy DBs are not reachable from the build environment,
so the chat text was the source. Treat them as a working snapshot: good for
reference and planning, but **spot-check against a fresh extract before using as
authoritative seed input**.

**To regenerate authoritative CSVs** (when on a host that can reach `EXCSRV05`):
open the relevant extract script above in SSMS, run it, and for each result grid
use *right-click → Save Results As… → CSV*. That reads straight from the DB, so
it is byte-accurate (unlike the transcribed snapshot here).

## Files

### Schema (discovery)
- `mes_tables.csv` — `MES` table inventory (name, approx rows, column count)
- `mes_foreign_keys.csv` — `MES` FK relationships
- `mes_columns.csv` — `MES` column catalog. Core/structural tables (Bom, BomComponent, Material, Lot, WorkOrder, WorkCell, etc.) are complete; a few very-wide peripheral tables (`LblParts`'s 74 cols, some dashboard-config tables) are abbreviated to key columns — regenerate for the exhaustive list.
- `emmd_tables.csv` — `EMMD` table inventory
- `emmd_foreign_keys.csv` — `EMMD` FK relationships
- `emmd_columns.csv` — `EMMD` column catalog

### MES master / reference data
- `code_tables.csv` — state/type/disposition/UoM/class/role/privilege lookups (grid #A)
- `locations.csv` — ISA-95 plant tree Site→Area→Line→Cell→Workstation (grid #B)
- `navigation.csv` — parallel navigation tree (grid #B2)
- `materials.csv` — parts catalog, 340 rows (grid #C)
- `bom.csv` — BOM headers (grid #D)
- `bom_components.csv` — BOM component lines (grid #D2)
- `workcell_material.csv` — consumption/production points per cell = implicit routing (grid #E)
- `production_orders.csv` — production orders (grid #F)
- `work_orders.csv` — work orders with produced part resolved (grid #F2)
- `customers.csv` — customer codes (grid #G)
- `identifier_formats.csv` — LTT / serialized-item id formats (grid #G2)
- `label_templates.csv` — ZPL label templates (grid #G3)

All 18 files are populated from the chat snapshot. Row counts: materials 343,
bom 225, bom_components 557, workcell_material 548, code_tables 219,
production_orders 189, work_orders 190, locations 253, navigation 59,
customers 8, identifier_formats 2, label_templates 3; schema: mes_tables 102,
mes_foreign_keys 94, mes_columns 471, emmd_tables 25, emmd_foreign_keys 30,
emmd_columns 145.
