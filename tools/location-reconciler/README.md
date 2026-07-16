# Location Reconciler

A self-contained browser tool for reconciling the **new Location seed** against the
**legacy MES plant tree**, side by side, with legacy device/OPC/host enrichment — so
you can decide how to collapse/expand the model and export the result as JSON.

## Use it

Just open **`location-reconciler.html`** in any browser (double-click / `file://` — no
server needed). Everything (both trees, the device catalog) is inlined.

Each tree header has a **Collapse all / Expand all** toggle and a search box.

- **Left — Legacy (MES), read-only:** full ISA-95 tree from `locations.csv`
  (Site → Area → Line → WorkCell → Workstation). `DO NOT USE`/`TEMP`/`TBD` nodes are
  struck through. Badges: `⌘ host` (Workstation `Machine=`), `N mat` (workcell
  materials = routing), `N dev` (heuristically-matched OPC devices).
- **Right — New seed (011), editable:** parsed from
  `sql/seeds/011_seed_locations_mpp_plant.sql`.
  - **+ Child / Delete / ↑ / ↓** — structural edits (re-parent via the **Parent**
    picker in the detail panel).
  - **← Pull from legacy** — select a legacy node (left) + a new parent (right), click
    to copy it in (carries its host as a `Host` attribute, its top device match, and a
    `legacySourceIds` back-reference).
- **Detail & enrichment (right pane):** click any node. Legacy nodes show host +
  materials + matched devices (with **Attach** buttons to wire a device onto the
  selected new node). New nodes get an inline editor (Name/Code/Kind/Parent/attrs);
  Printer nodes suggest `Endpoint`/`Model`, Terminals suggest `Role`/`Host`.
  Every node (legacy or new) has a **Notes** box at the bottom of its detail — jot
  reconciliation notes as you go; they auto-save and ride along in the export
  (new-node notes on the node, legacy notes under a top-level `legacyNotes` map). When
  both a legacy and a new node are selected you'll see two Notes boxes — the first under
  *Edit · new node*, the second under *Legacy · …*.
- **Device catalog** button — searchable list of all 22 EMMD devices (tags, migration
  strategy, notes) for manual matching.

Edits **auto-save to your browser** (localStorage). **Export JSON** copies/downloads the
whole new tree as a nested structure; **Import** replaces the working tree from pasted
JSON; **Reset to seed** discards edits.

When you're happy, hit **Export JSON** and hand the result back — it's shaped
(`code / name / kind / defId / parentCode via nesting / attributes / deviceRefs /
legacySourceIds`) to map straight onto a regenerated seed + migration.

## Regenerate

Rebuild the HTML after the seed or the legacy extracts change:

```
node tools/location-reconciler/build.js
```

Sources it reads (all already in the repo):
`reference/legacy_mes_extract/locations.csv`, `.../workcell_material.csv`,
`.../emmd_automation/device_rollup.tsv`, `.../emmd_automation/integration_manifest.csv`,
`.../emmd_automation/opc_servers.tsv`, and `sql/seeds/011_seed_locations_mpp_plant.sql`.

## Notes / caveats

- The legacy CSV/TSV extracts were **transcribed from SSMS grids** (see
  `reference/legacy_mes_extract/README.md`) — treat as a working snapshot; a
  byte-accurate re-pull is advisable before any export is treated as authoritative.
- Device matching is **heuristic** (shared program/keyword tokens). Top matches are
  usually right, but always sanity-check against the full catalog.
- Physical **printer endpoints/IPs** are not in any extract — those `Endpoint` values
  are filled by hand (floor-walk / MPP IT).
