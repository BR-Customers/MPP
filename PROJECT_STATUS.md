# MPP MES — Project Status

**Last updated:** 2026-05-13

This file holds the **volatile** state of the project — current doc versions, active blockers, recent change narrative, and the next-session briefing. Durable identity, document map, architecture, and conventions live in `CLAUDE.md`.

---

## Current Document Versions

| Doc | Version | Rev Date | Status / Notes |
|---|---|---|---|
| Data Model | **v1.9m** | 2026-04-29 | Current. `Parts.OperationTemplate.RequiresSubLotSplit` added (FDS-05-009). |
| FDS | **v1.0** | 2026-05-04 | **First customer-review release.** Feedback-Welcomed callout added near front matter. In-document Revision History reset to start at v1.0; pre-release granular history (v0.1 through v0.11p) archived in `MPP_MES_FDS_CHANGELOG.docx`. From v1.0 forward, revisions are tracked in the FDS body itself. |
| Open Issues Register | **v2.17** | 2026-05-01 | Current. **9 items closed** from Jacques's 2026-05-01 markup: OI-07, -24, -25, -27, -28, -29, -30, -31, UJ-03 → all ✅ Resolved. 6 items remain Open. |
| Outstanding Items extract | **v2.0** | 2026-05-01 | Current. Reduced to 6 Open items per OIR v2.17. |
| User Journeys | **v0.9** | 2026-04-29 | Current. FDS v0.11m reconciliation pass. |
| Phased Plan — Plant Floor (Arc 2) | **v1.0** | 2026-04-29 | Current. Full rebuild from v0.3. |
| Phased Plan — Config Tool (Arc 1) | v1.7 | earlier | All 8 phases built and tested. |
| Seeding Registry | v1.0 | earlier | Current. |
| ERD | (current through v1.9i) | — | **Pending refresh** — see ERD Refresh Queue below. |

---

## 🚨 Active Blockers

### OI-35 — Architecture Decision Gate (HIGH)

**Long-horizon scaling, retention, archiving strategy must resolve before Arc 2 Phase 1 SQL build (`0014_arc2_phase1_shop_floor_foundation.sql`) commences.** Last-responsible-moment posture confirmed by Jacques 2026-04-29.

Eight architectural decisions:

1. Per-table retention class (push back on 20-yr for `Audit.OperationLog` / `InterfaceLog` / `FailureLog`).
2. Monthly partitioning + sliding-window automation across ~14 high-volume event tables. **Must be in CREATE migration.**
3. Columnstore on aged partitions (>90 days).
4. Materialized closure table for `Lots.LotGenealogy` — Honda audit O(1) vs recursive CTE at year 15. **Must be in CREATE migration.**
5. Materialize `TotalInProcess` / `InventoryAvailable` columns onto `Lots.Lot` (supersedes OI-23 view choice at scale). **Must be in CREATE migration.**
6. `Lots.IdentifierSequence_Next` locking model — row-locked vs SQL Server `SEQUENCE`.
7. Split `Audit.OperationLog` into 7-yr general + 20-yr `Lots.LotEventLog`. **Must be in CREATE migration.**
8. Filtered indexes on hot subsets.

Items 2/4/5/7 must be in the CREATE migration — retrofitting partition schemes, closure tables, or materialization columns to populated 100M+ row tables is operationally expensive.

**Resolution path:** internal Blue Ridge architecture review + MPP IT retention-policy negotiation (single meeting). Output: data model § "Scaling Decisions" + FDS-11 retention paragraph + Phase 1 migration content.

**Background:** `Meeting_Notes/2026-04-28_DataModel_Indexing_Scaling_Review.md`.

### Phase 0 Customer Validation Workshop with MPP — Track A (8 items)

Track A is the customer-validation gate. Track B is the architecture workshop above (OI-35). OI-31 closed 2026-05-01 (cutover seed at +10K above Flexware counter — captured in FDS-16-003) — only the rollout-shape sub-question remains as a Ben item, no longer Phase-0-gating.

1. **FDS-06-030** — WorkOrder BIT-flag enumeration.
2. **Historical data migration** — entity list + pre-flight validation + discrepancy review.
3. **ShotCount semantics** — cumulative counter (current default) vs derived from aggregated LOT quantity.
4. **Workstation `DefaultScreen` + `ConfirmationMethod` seeding** — per-Cell Perspective-view list + per-Cell `ConfirmationMethod` value (Vision / Barcode / Both).
5. **Honda AIM Hold/Update contract detail** — `PlaceOnHold` / `ReleaseFromHold` / `UpdateAim` signatures + error recovery (UJ-04 GetNextNumber pool flow already locked).
6. **Label template scope** — Flexware has 3 templates (CONTAINER / LOT / CONTAINER_HOLD); confirm matches + any new (Sort Cage / Hold / Void). Couples to S-09 in Seeding Registry.
7. **OI-32 Material Allocation operator screen** — premise challenged 2026-04-24; revised "close as not-reproduced" framing awaits Ben's explicit confirmation.
8. **OI-33 AIM pool empty-pool hard-fail customer validation** — confirm hard-fail is the desired posture (production stops on affected lines until pool refills; no soft-fallback).

---

## Outstanding for Next Session

### Open Part B UJs

- **UJ-05** Sort Cage serial migration — default direction committed (update-in-place + `Lots.ContainerSerialHistory`); awaits MPP Quality + Honda compliance affirmation.
- **UJ-19** Productivity DB replacement — Ben + MPP Production Control name the four PD reports; **MVP scope confirmed** per OI-30 closure (the four reports are deliverables; reports beyond the four = post-deployment change order).

### Open Part A items (4)

- **OI-32** Material Allocation operator screen — Ben's confirmation of "close as not-reproduced" framing.
- **OI-33** AIM pool empty-pool hard-fail — MPP Operations / IT customer validation.
- **OI-34** Production schedule leverage — MPP Production Control discovery walk-through.
- **OI-35** Long-horizon scaling, retention, archiving — Blue Ridge architecture review + MPP IT retention negotiation. **HARD GATE** before Arc 2 Phase 1 SQL build.

### SQL queue — Blue Ridge owns (gated on Phase 0)

1. ✅ **OI-07 + OI-12 correction migrations** — landed 2026-04-28 as `0013_oi07_oi12_corrections.sql`. 858/858 tests passing.
2. ✅ **LocationTypeDefinition CRUD support** — landed 2026-05-13 as `0014_locationattributedefinition_unique_active_name.sql` (filtered UNIQUE index) plus `R__Location_LocationTypeDefinition_SaveAll.sql` (bundled meta + child reconciliation in one transaction) and `R__Location_LocationTypeDefinition_Deprecate.sql` (cascade + FK guard against active Locations). 907/907 tests passing.
3. **Arc 2 Phase 1 SQL implementation** — needs renumber to **`0015_arc2_phase1_shop_floor_foundation.sql`** (0014 was taken by item 2). **GATED on Phase 0 — both tracks (Customer Validation + Architecture Decision)** before commencement. Phase 1 plan body bakes OI-35 architectural decisions into the migration on day one (partition functions, closure table if elected, materialization columns if elected, OperationLog split if elected, filtered indexes per B8). Includes the Phase 4 Data Model column add `Parts.OperationTemplate.RequiresSubLotSplit` if not landed earlier as its own migration.
4. **Phases 2–8 SQL** — sequential per the rebuilt plan (migrations `0016`–`0022`, shifted by one from the original reservation). Phase 4 migration `0018` includes the `RequiresSubLotSplit` ALTER if not already shipped.

### ERD refresh queue

ERD pending refresh for v1.9j–m additions:

- `ContainerConfig.ClosureMethod` values (`ByCount` / `ByWeight` / `ByVision`)
- `Lots.ShippingLabel.BannerAcknowledgedAt`
- `CoupledDownstreamCellLocationId` LocationAttribute under `CNCMachine`
- `Parts.OperationTemplate.RequiresSubLotSplit`

Per-schema tabs are the source of truth and remain canonical until next regen.

### Internal Docs Portal — ✅ landed 2026-05-12

Initial v1 build at `docs_portal/`. See "Recent Change Narrative" entry below for details.

### LocationTypeEditor modal — 🟡 IN-PROGRESS (2026-05-13)

Full vertical stack scaffolded (SQL + NQs + entity scripts + views + cog-button wiring), tests green, gateway scanned, but end-of-day smoke-test in Designer still has unresolved issues. **What's known to work:** SQL build (907/907 tests). What's pending verification next session: Designer-side modal rendering, tier dropdown → definitions repeater flow, save round-trip, deprecate FK guard surfacing in UI. See "Recent Change Narrative" entry below for the full surface and the failure modes hit + fixed during the day.

### Non-blocking polish

- Memory file revision-history-format trim: applied to FDS only; not yet to Data Model + OIR.
- FDS-06-028 wording sharpen — WO Auto-Finish (§6.10) prose still mentions "camera-count mode" pre-tray-reframe. Low priority.
- **Latent NQ v1 schema bug:** at least `location/Get/resource.json` is `version: 1`; Designer 8.3.5 NPEs when opening v1 NQ resources. Other v1 NQs in the project may exist. Worth a cleanup-pass bump-to-v2 when convenient. See `feedback_ignition_nq_resource_schema.md` memory.

---

## OIR Status (v2.17, 2026-05-01)

54 items total: **47 resolved, 0 in review, 6 open, 1 superseded.**

- **Open Part A:** OI-32 (Material Allocation framing — Ben), OI-33 (AIM pool hard-fail — MPP Ops / IT), OI-34 (production schedule leverage — Production Control), OI-35 (scaling / retention — Blue Ridge architecture + MPP IT) **HARD GATE**
- **Open Part B:** UJ-05 (Sort Cage serial migration — MPP Quality + Honda), UJ-19 (PD replacement — Ben + Production Control name the four reports)

---

## Decision Owners

Items genuinely gating downstream work, by owner:

1. **OI-35 Architecture Decision Workshop** — Blue Ridge architecture lead + MPP IT (retention-policy negotiation). Gates Arc 2 Phase 1 SQL build.
2. **Phase 0 Customer Validation Workshop with MPP** — 9 gating items above. Gates Arc 2 Phase 1 SQL build.
3. **Ben** — OI-32 close-as-not-reproduced confirmation; OI-31 rollout-shape decision is no longer gating (OI-31 closed 2026-05-01 with the +10K seed-offset rule; rollout shape is operationally informational only). Memo at `Meeting_Notes/2026-04-24_OI-31_Single-Line_Deployment_Impact.md`.
4. **Tom (security SME)** — final elevated-action list validation (FDS-04-007).

---

## Build Status

- **Configuration Tool (Arc 1):** Phases 1–8 + G.1–G.5 + 0013 corrections + 0014 LocationTypeDefinition CRUD support complete. **907/907 tests passing** across 22+ test suites.
- **SQL artifacts:** `/sql/` folder, **14 versioned migrations + 218 repeatable procs.** PowerShell reset script `Reset-DevDatabase.ps1` auto-discovers and runs all scripts via `sqlcmd.exe`. Tested on SQL Server 2025.
- **Plant Floor (Arc 2):** Mockup landed at `mockup/plantFloor.html` (12 terminal/lot routes + Home Page). SQL not yet started — gated on Phase 0.
- **Ignition project (live build, Arc 1):** Phase 1 Location pipeline, toast notifications, scan helper landed 2026-05-12. PlantHierarchy view: tree-selection re-anchor pattern + move arrows wired through `BlueRidge.Common.Action.runMutation`. **LocationTypeEditor modal IN-PROGRESS as of 2026-05-13** — SQL + NQs + entity scripts + views all scaffolded and gateway-deployed, but still has Designer-side issues at end of day (see "Outstanding for Next Session"). Cog button on PlantHierarchy wired to open the modal.
- **Seed data loading:** CSVs ready in `reference/seed_data/` (876 rows total). `machines.csv` not yet loaded; MPP parts list not yet provided; `defect_codes.csv` not yet loaded; `downtime_reason_codes.csv` has bulk-load proc but not yet invoked.

---

## Source-of-Truth Doc Locations

| Doc | Markdown source | Word output |
|---|---|---|
| Data Model | `MPP_MES_DATA_MODEL.md` | `MPP_MES_DATA_MODEL.docx` |
| FDS | `MPP_MES_FDS.md` | `MPP_MES_FDS.docx` |
| FDS Changelog | `MPP_MES_FDS_CHANGELOG.md` | `MPP_MES_FDS_CHANGELOG.docx` |
| OIR | `MPP_MES_Open_Issues_Register.md` | `MPP_MES_Open_Issues_Register.docx` |
| User Journeys | `MPP_MES_USER_JOURNEYS.md` | `MPP_MES_USER_JOURNEYS.docx` |
| Phased Plan Plant Floor | `MPP_MES_PHASED_PLAN_PLANT_FLOOR.md` | `MPP_MES_PHASED_PLAN_PLANT_FLOOR.docx` |
| Seeding Registry | `MPP_MES_SEEDING_REGISTRY.md` | `MPP_MES_SEEDING_REGISTRY.docx` |
| ERD | `MPP_MES_ERD.html` | — |

Arc 2 revisions spec: `docs/superpowers/specs/2026-04-23-arc2-model-revisions.md` (still untracked in working tree).

Indexing review (carries OI-35 Decision Gate callout): `Meeting_Notes/2026-04-28_DataModel_Indexing_Scaling_Review.md`.

Phase G capability snapshot: `Meeting_Notes/2026-04-22_Phase_G_Capabilities_Summary.md`.

---

## Recent Change Narrative

A timeline of session-by-session changes. Most recent first.

### 2026-05-13 — LocationTypeEditor modal: full vertical stack scaffolded (WIP)

Big day. Built the complete top-to-bottom stack for the Plant Hierarchy view's cog-button "Location Type Editor" modal: SQL migration + procs + tests, named queries, entity scripts, embedded views, popup view, and the cog-button onClick wiring. **907/907 SQL tests pass.** End-of-day smoke-test in Designer still surfaces issues; modal is NOT FULLY WORKING yet but the full surface area is in place to iterate from.

**SQL (all green, all tests passing):**

- **Migration 0014** — `0014_locationattributedefinition_unique_active_name.sql`. Filtered UNIQUE index on `Location.LocationAttributeDefinition(LocationTypeDefinitionId, AttributeName) WHERE DeprecatedAt IS NULL`. Defends the bundled save proc against active-name collisions; allows reuse of deprecated names. **Note:** this slot was originally reserved for Arc 2 Phase 1's `0014_arc2_phase1_shop_floor_foundation.sql`. That work shifts to `0015` when it lands (SQL queue updated accordingly).
- **`R__Location_LocationTypeDefinition_SaveAll.sql`** — bundled save proc. Meta as params (`@Id`, `@LocationTypeId`, `@Code`, `@Name`, `@Icon`, `@Description`, `@AppUserId`) + `@AttributesJson NVARCHAR(MAX)`. Server-side reconciliation: OPENJSON parse → validate within-batch uniqueness + immutable Code/LocationTypeId on update → DEPRECATE missing children → UPDATE Id-matched (SortOrder = array index) → INSERT NULL-Id rows → one Audit row with full pre/post snapshot → status-row SELECT. See `project_mpp_bundled_save_pattern.md` memory.
- **`R__Location_LocationTypeDefinition_Deprecate.sql`** — soft-delete with cascade to active children. FK guard rejects when active `Location.Location` rows reference. Idempotent re-deprecate returns `Status=1, Message='Already deprecated.'`.
- **Tests:** `030_LocationTypeDefinition_SaveAll.sql` (12 scenarios), `040_LocationTypeDefinition_Deprecate.sql` (6 scenarios). All assertions pass.

**Ignition (scaffolded, end-of-day modal still buggy in Designer):**

- **5 named queries:** `location/LocationType_List`, `LocationTypeDefinition_List`, `LocationAttributeDefinition_ListByDefinition`, `LocationTypeDefinition_SaveAll`, `LocationTypeDefinition_Deprecate`. Resource.json forced to v2 schema after Designer 8.3.5 NPE'd on v1 inheritance from the `Get` NQ template.
- **3 entity script modules:** `BlueRidge.Location.LocationType` (`listAll`, `nameForTier`), `BlueRidge.Location.LocationTypeDefinition` (`listByType`, `handleSaveAll`, `handleDeprecate`, `emptyMeta`, `emptyAttributeRow`, `metaFromDefinition`), `BlueRidge.Location.LocationAttributeDefinition` (`listByDefinition`). All read functions wrap their `system.db.execQuery` calls in try/except with error-toast on failure.
- **`Common.Action.runMutation` upgraded** — now returns the status-row dict (or None) instead of bool. Backwards-compatible (truthy/falsy preserved); `handleSaveAll` reads `result["NewId"]` from the return.
- **3 new views:** `BlueRidge/Components/AttributeDefinitionRow` (editable row sibling of read-only AttributeRow), `BlueRidge/Components/DefinitionItem` (chip/button for tier-scoped definition selection, root = flex with label inside), `BlueRidge/Components/Popups/LocationTypeEditor` (the modal — tier dropdown + definitions repeater + Definition Details panel + Attribute Definitions table + footer Close).
- **PlantHierarchy/view.json** cog icon (`LocationTypeEditorButton`) wired to `dom.onClick` opening the modal via `system.perspective.openPopup(id='mpp-loc-type-editor', view='BlueRidge/Components/Popups/LocationTypeEditor', modal=True, ...)`.

**Bugs hit + fixed during the day** (each = a memory entry now):

1. **Toast popup auto-dismiss never fired** — `view.custom.dismissAt` had no binding, so the polled `now(500) > dismissAt` expression stayed false forever. Fix: add an expression binding on `dismissAt` that computes `dateArithmetic(now(0), {view.params.ttl}, 'second')`. Updated `project_mpp_toast_system.md`.
2. **Tree-selection re-anchor pattern** — when items change programmatically the selection path goes stale. Fixed by having `handleMoveUp`/`handleMoveDown` return `{tree, selectedPath, selected}` so the view writes all three atomically. Same pattern can be reused for any future tree-mutating action.
3. **NQ resource.json schema v1 vs v2** — Designer 8.3.5 NPEs on v1 shape. Bumped all 5 new NQs to v2 with the Designer-saved field order. Pre-existing `location/Get` is still v1 — flagged for cleanup. New memory: `feedback_ignition_nq_resource_schema.md`.
4. **`def list()` shadowed Python builtin** in `BlueRidge.Location.LocationType` — broke `_rowsToDicts`'s `list(...)` call. Renamed to `listAll()`. Genuine junior miss; flagged it as such in the conversation. Update Plant Hierarchy view + binding to call `listAll`.
5. **Message scope: view vs page** — `scope='view'` doesn't propagate from an embedded view to its parent. Chip click from inside `DefinitionItem` with `scope='view'` never reached the popup's `definitionClick` handler. Fix: change to `scope='page'` and flip handler config to `pageScope: true`. Same fix applied to `attrDraftUpdate`/`attrDraftRemove`/`attrDraftMove` from `AttributeDefinitionRow`. New memory: `feedback_ignition_message_scope.md`.
6. **`lookup()` expression function** requires a Dataset, doesn't work against `list[dict]` from `runScript`. TypeBadge expression failed because tiers is a list[dict]. Fix: added `nameForTier(tiers, tierId)` helper in `LocationType` module, called via `runScript`. New memory: `feedback_ignition_lookup_dataset_only.md`.
7. **`DefinitionChip` view was rooted at `ia.input.button`** — non-idiomatic, didn't render text. Rebuilt as `ia.container.flex` root with `ia.display.label` child. Folder renamed `DefinitionChip` → `DefinitionItem`; "chip" terminology replaced with "definition" everywhere (function `chipsFromDefinitions` → `definitionItemsFor`, prop `view.custom.chips` → projection removed entirely, meta names `Chips*` → `Definitions*`, message `defChipClick` → `definitionClick`).
8. **Read-side silent failures upgraded to toasts** — all three list functions (`listAll`, `listByType`, `listByDefinition`) now catch exceptions and fire an error toast before returning `[]`. The `definitionClick` message handler also fires warning toasts on null payload + stale-id-not-in-list paths.

**Memory entries added/updated:**

- NEW: `feedback_ignition_nq_resource_schema.md` — v2 schema required, clone shape from Designer-saved file
- NEW: `feedback_ignition_message_scope.md` — view vs page, use page for embedded→parent
- NEW: `feedback_ignition_lookup_dataset_only.md` — Dataset-aware expr fns don't work on list[dict]
- NEW: `project_mpp_bundled_save_pattern.md` — the SaveAll-with-JSON-deltas pattern as project standard
- UPDATED: `project_mpp_toast_system.md` — dismissAt wiring formula
- UPDATED: `feedback_readonly_type_tables.md` — LocationTypeDefinition now CRUDable (LocationType stays read-only)

**Next session pickup:**

1. Open Designer fresh, pull project, double-click each new NQ to confirm none Designer-NPE
2. Open LocationTypeEditor modal via the cog button on Plant Hierarchy
3. Verify tier dropdown populates, definitions repeater renders DefinitionItems, click flow propagates selection to Definition Details + Attribute Definitions panels, Save round-trips through the bundled proc, Deprecate FK-guards on tiers with active Locations
4. Whatever isn't working at that point — fix and iterate

### 2026-05-12 — Internal Docs Portal landed

Built and shipped the v1 internal docs portal — a self-contained static HTML site at `docs_portal/` that consolidates **FDS + Data Model + OIR + ERD** into one browsable, searchable surface for the Blue Ridge team. Internal-only; does NOT replace the `.docx` deliverables to MPP.

**What's in v1:**

- Four pages: `fds.html`, `data-model.html`, `oir.html`, `erd.html` (the ERD is iframed — no rewrite), plus an `index.html` meta-refresh to FDS.
- Shared shell: sticky header nav, sticky TOC sidebar with `IntersectionObserver`-driven active-section highlight, dark theme matching the ERD palette (`#0f1117` bg / `#6c8aff` accent).
- Cross-doc full-text search via **MiniSearch** — section-level granularity (every h2 + h3), ~277 entries, ~470 KB serialized index, lazy-loaded into a modal triggered by `🔍` button or `/` key.
- Six custom markdown-it plugins:
  1. `heading_permalinks` — adds clickable `#` chips on h2/h3/h4, canonicalizes FDS-XX-NNN and OI-XX/UJ-XX heading ids
  2. `anchor_fds_req` — wraps bold-inline `**FDS-XX-NNN**` references in section anchors
  3. `scope_pill` — backticked scope tags (`MVP`, `CONDITIONAL`, etc.) render as colored badges
  4. `cross_doc_link` — bare `FDS-XX-NNN`, `OI-XX`, `UJ-XX`, `Schema.Table`, `(FRS X.Y.Z)` refs in body text auto-link across docs (only for known schema tables, validated against a pre-parsed allowlist)
  5. `oi_badge` — inline 🔓 OI-XX chip on FDS h4 requirements that an open OI references (8 live badges from the 6 open OIs)
  6. `schema_table_anchor` — Data Model only, gives table h3s schema-prefixed slugs (`parts-operationtemplate`) so cross_doc_link's expected anchors actually resolve

**How to rebuild:** `npm run build:portal` (alias for `node tools/build_docs_portal.js`). Idempotent — wipes and rebuilds `docs_portal/`. Test suite: `npm run test:portal` (38 tests across the generator + plugins + smoke tests).

**Spec + plan:** `docs/superpowers/specs/2026-05-12-docs-portal-design.md` (approved 2026-05-12) and `docs/superpowers/plans/2026-05-12-docs-portal.md` (17 tasks, executed via subagent-driven development).

**Three plan deviations corrected during build:**

1. `buildToc` regex strip left scope-pill text in TOC labels — added a span-strip pre-pass. Same issue with permalink `#` chips — added an anchor-strip pre-pass.
2. The FDS source uses `#### FDS-XX-NNN — Title` h4 headings, not `**FDS-XX-NNN**` bold inline (plan got this inverted). Both `heading_permalinks` and `oi_badge` were extended to recognize the h4 form. 8 live OI badges now appear on FDS.
3. The OIR's `### OI-XX — long description` headings were producing slugified ids that didn't match the bare `oir.html#oi-35` hrefs the cross-doc plugins generate. Added OIR-pattern canonicalization to `heading_permalinks` (mirrors the FDS pattern handling).

Each plan correction landed as a small `fix(portal):` commit so the chain is auditable.

### 2026-05-07 — MPP custom Perspective icon library landed

Built and deployed the `mpp` custom Perspective icon library against the lock spec in `mockup/icons.csv`. 34 unique icon sprites (35 logical icons; `cancel` covers both `close` and `reject` from `icons.csv`) at the locked Material Symbols Outlined / wght 300 / grade -25 / fill 0 / opsz 48 axes. Sprite at `ignition/icons/mpp/mpp.svg` (30 KB), companion `config.json` + `resource.json`, and a README at `ignition/icons/README.md` capturing the deploy + recolor recipe.

Three discoveries forced strategy changes from the original design spec, all captured in the README:

- **Ignition 8.3 moved custom icon libraries** from `data/modules/com.inductiveautomation.perspective/icons/<lib>.svg` (8.1) to `data/config/resources/core/com.inductiveautomation.perspective/icons/<lib>/` (8.3), with mandatory `config.json` + `resource.json` siblings. Folder name must equal library name. Gateway service restart needed — Scan File System is unreliable for modified-sprite reloads.
- **Material Symbols' native viewBox `0 -960 960 960` does not render** in 8.3 Perspective. Path data is remapped to viewBox `0 0 24 24` via `transform="translate(0 24) scale(0.025)"` on each path.
- **`fill="currentColor"` on the path doesn't propagate Perspective's color hook.** Perspective wraps each rendered icon in an outer SVG with `style="fill: currentcolor"`; SVG attribute fill on a child path overrides that cascade. Removing the fill attribute entirely lets the Icon component's top-level `color` prop or a Style Class `Text → Color` drive recolor.

Source for the SVGs: `github.com/google/material-design-icons` (the GitHub repo is the only place Google publishes Material Symbols at every variable-font axis combination including `gradN25`; `fonts.gstatic.com` exposes only `wght` and `fill`).

Spec + plan: `docs/superpowers/specs/2026-05-05-ignition-icon-library-design.md` and `docs/superpowers/plans/2026-05-05-ignition-icon-library.md`. Final-state commit: `8303f72`. Durable mechanics also captured in `CLAUDE.md` § Ignition custom Perspective icon library.

### 2026-05-04 — FDS v1.0 customer-review release

Cut FDS v0.11p → **v1.0**, the first customer-review release. Pre-release working-session history (v0.1 through v0.11p) archived in `MPP_MES_FDS_CHANGELOG.docx`; future revisions tracked in the FDS body itself.

- **Feedback-Welcomed callout** added prominently near the front matter, framing v1.0 as the critical-feedback window. Specific areas highlighted: plant-floor workflows (§5–§9), event-data capture, Honda traceability, integration touch points, scope boundary, the 6 remaining open items.
- **In-document Revision History** reset to start at v1.0 with one consolidated entry summarising the 16 sections covered + the 6 remaining open items. Pointer block to the standalone changelog removed.
- **`MPP_MES_FDS_CHANGELOG.md/.docx`** marked archival as of v1.0; standalone artifact retained as the historical record of design evolution but no longer appended to.

### 2026-05-01 — Outstanding Items extract + 9-item closure pass + companion FDS amendments

Built a focused 15-item working extract of the OIR (`MPP_MES_Outstanding_Items.md` / `.docx`) for customer review. Jacques marked it up by adding "Final decision" annotations to 9 items; clarified two follow-ups (per-Operation split flag confirmed as the implemented mechanism; UJ-19 four PD reports remain MVP scope while reports beyond the four = post-deployment change order); approved a four-doc landing pass.

- **OIR v2.17** (companion to this session) — closed OI-07, -24, -25, -27, -28, -29, -30, -31, UJ-03 → all ✅ Resolved with explicit Decision (2026-05-01) blocks. Counts shift: Part A Resolved 22 → 30, In Review 1 → 0, Open 11 → 4 (only OI-32, -33, -34, -35 remain). Part B Resolved 16 → 17, In Review 1 → 0, Open 2 → 2 (UJ-05, UJ-19). Grand total: 54 items, 47 resolved, 0 in review, 6 open, 1 superseded.
- **FDS v0.11p** — **FDS-16-003** amended: cutover-day seeding rule changed from "at or above the Flexware value" to a concrete `<Flexware-current> + 10,000` offset (or MPP-agreed delta). Sample post-offset cutover seeds: `Lot=1,720,932`, `SerializedItem=12,492`. The "Open items (OI-31)" paragraph absorbed into design fact (format carry-forward, no reset policy, ~30+ year rollover horizon). **FDS-12-015 NEW** — `§12.6 Notifications Posture — MVP` establishes banners-only via terminal-context broadcast (FDS-07-006a/b, elevation banners, hold tiles, AIM-pool alarm tiles); text and email notifications are out-of-MVP, future change order. **Embedded Open Items Register reduced** from 14 unresolved items to 6 (OI-33, OI-35, UJ-19 HIGH; OI-34, OI-32, UJ-05 MEDIUM); previously-omitted OI-35 row added.
- **`MPP_MES_Outstanding_Items.md/.docx` v2.0** — refreshed to the 6 remaining Open items only (OI-32, OI-33, OI-34, OI-35, UJ-05, UJ-19). Customer-facing working draft for Phase 0 / architecture-review walk-throughs.
- **No data model / SQL / UJ doc changes this session** — register entries + FDS prose only.
- **Phase 0 Track A items reduced** from 9 to 8 (OI-31 closed; sub-question Ben rollout-shape no longer Phase-0-gating). Active blockers stay: OI-35 architecture gate (HARD) + Phase 0 Customer Validation Workshop.

### 2026-04-30 — Arc 2 Plant Floor mockup + FDS amendments

Substantial day building the operator-facing UI mockup and correcting two FDS sections.

- **`mockup/plantFloor.html` + `mockup/plantFloor.css` + extracted `mockup/styles.css`** — 12 terminal/lot routes covering every operator surface in the Phased Plan v1.0: `home`, `terminal/initials`, `terminal/cell-context`, `terminal/diecast`, `terminal/trim-in`, `terminal/trim-out`, `terminal/machining-in`, `terminal/assembly`, `terminal/assembly-ns`, `terminal/sort-cage` (Serialized + Non-Serialized variants), `terminal/receiving`, `terminal/shipping`, `terminal/end-of-shift`, `lot/detail`. Home Page has plant-hierarchy tree dock + tabbed details panel (Location Details + LOT Search + Genealogy Lookup + Hold Management + Supervisor Dashboard with AIM Pool Wallboard tile). Cross-cutting modals: Elevation, BOM Rename, Idle Re-Confirm, Material Substitute Override, Change Cell Context. Print Failure Banner. Header has elevation toggle (mockup demo affordance), app-title-as-home-link, breadcrumb (terminal routes only), Config Tool nav-out (elevated only). Polymorphism via Flex Repeater + Embedded View. Per-action AD elevation pattern with secondary-color treatment for elevated buttons. 1080p scroll-free with inner-repeater scroll modifiers for high-N entity lists. Touch-friendly (44 px minimum touch targets, 56 px header).
- **FDS v0.11m → v0.11n** (commit `361f6a4`): **FDS-09-013** End-of-Shift Time Entry — selection mechanism corrected to button-toggle on both terminal modes. 3 toggleable buttons (Lunch · 30 min, Break 1 · 15 min, Break 2 · 15 min) tap-to-select / tap-to-deselect. No numeric duration entry. Differences between Dedicated and Shared scoped to identity capture only (Shared adds inline initials field + 3-button single-select Time Category — Regular / Overtime / Double-Time). Zero-button submission valid (operator skipped breaks → no DowntimeEvent rows).
- **FDS v0.11n → v0.11o** (commit `d7f889f`): **FDS-06-014** ByVision row corrected — camera scans the FULL TRAY as a single image, ONE validation event per tray (not per piece). Four-tray container = four passing tray-scan events. Per-tray `ConsumptionEvent` semantics clarified. New OPC tag names: `TrayPresent`, `TrayValidationResult`, `TrayFullFlag`. Same mechanic applies in Sort Cage non-serialized re-pack (uses the same camera).
- **Phased Plan v1.0 implication flagged** — Phase 1's "Terminal Selector" placeholder is structurally a Home Page (plant browser) for elevated desktop users, not a generic Terminal Selector. Mockup proves the model; Phased Plan + FDS will be updated at next pass to match. Companion FDS-02 paragraph also pending.

### 2026-04-29 — Multi-doc reconciliation + scaling-gate tracking + Phased Plan rebuild + DM column add

Five commits over the day landed substantial work.

- **OIR sync + DM column adds** (commit `c7ca780`) — DM v1.9j → v1.9k. `Lots.ShippingLabel.BannerAcknowledgedAt DATETIME2(3) NULL` added (FDS-07-006b broadcast-script Acknowledge action). `CoupledDownstreamCellLocationId` LocationAttributeDefinition seeded under `CNCMachine` (FDS-06-008 auto-move target). OIR v2.14 → v2.15 — OI-33 (AIM pool empty-pool hard-fail customer validation, HIGH) + OI-34 (production schedules leverage, MEDIUM) folded from embedded FDS register into canonical OIR. OIR v2.15 → v2.16 — **OI-35 NEW (HIGH) "MUST DECIDE BEFORE ARC 2 PHASE 1 SQL BUILD"** — long-horizon scaling, retention, archiving strategy.
- **DM v1.9l + UJ v0.9 reconciliation** (commit `3851802`) — comprehensive sweep aligning DM and UJ to FDS v0.11m. DM v1.9k → v1.9l: ContainerConfig `ByVision` reframed as tray-level trigger; "Casting → Trim" subsection retitled "Trim → Machining" with full BOM example rewrite (5G0-TRIM Component + 5G0-MACHINED Sub-Assembly); `Parts.v_EffectiveItemLocation` view documented (Direct ∪ BomDerived per FDS-02-012); deferred event tables (WorkOrderOperation, ConsumptionEvent, RejectEvent, DowntimeEvent) renamed `OperatorId` → `AppUserId`; UJ-14 + UJ-16 PENDING callouts converted to resolved-prose; 5 Arc 2 admonitions stripped; WorkOrderType SQL correction marked landed; Tools cross-references rewritten. UJ v0.8 → v0.9: 4 high-impact scene rewrites — Trim Shop ("Trim is yield loss, not a rename" + "Trim OUT split + route to Machining FIFO"); Machining scene (FIFO pick + BOM rename at IN, PLC-driven auto-move at OUT); 11:30am Assembly tray-level closure with three peer methods + configured-value references; End of Shift FDS-09-013 single-submission rewrite. Assumption status flips: UJ-12, UJ-14, UJ-16, UJ-18 → ✅ Resolved.
- **Phased Plan Plant Floor v0.3 → v1.0 full rebuild + DM v1.9m** (commit `cf11542`) — complete document rebuild. 1825 lines (down from v0.3's 2077). Phase shape preserved (9 phases, 0–8). Cross-Cutting Concerns B1–B17 lifted verbatim with B12 reframed for **Flex Repeater + Embedded View** as the polymorphic primitive. NEW Seeding Registry — Phase Coupling section maps S-01..S-11 to phases. Phase 0 expanded with parallel **Architecture Decision Workshop** track (OI-35). Phase 1 bakes OI-35 architectural decisions into the migration on day one. Phase 3 Die Cast walkthrough corrected for **Shared terminal model**. Phase 4 Trim OUT branches on `Parts.OperationTemplate.RequiresSubLotSplit`. Phase 5 Machining whole rewrite (FIFO pick + BOM rename at IN; PLC-driven auto-complete + auto-move via CoupledDownstreamCellLocationId at OUT; no operator OUT view). Phase 6 Assembly tray-level closure with three peer methods. Phase 7 AIM pool topup loop + tier alarms. Phase 8 FDS-09-013 end-of-shift entry. Migration numbering rebased — Phase 1 lands at `0014`. **DM v1.9l → v1.9m** companion: `Parts.OperationTemplate.RequiresSubLotSplit BIT NOT NULL DEFAULT 0` added.

### 2026-04-28 — FDS continuity + clarity pass + indexing review

FDS lifted from v0.11j → v0.11m across multiple amend-in-place sessions. Major edits:

- §1.4 layer diagram → table; §1.7 FDS-01-007 historian-DB-separation guidance added.
- §2.5 Cell Context Selection (scan **or** dropdown — was scan-only); FDS-02-010 mode-derivation table refreshed (Cell→Dedicated, WC→Shared, Area→Shared); FDS-02-012 expanded with BOM-derived eligibility.
- §3.6 + §6.6 closure granularity corrected to **tray-level** (FDS-03-017 / FDS-06-013 / FDS-06-014 rewritten — `ClosureMethod` extended with `ByVision`).
- §5.10 + FDS-05-033 part-identity rename moved one step downstream from Casting→Trim to **Trim→Machining**; §5.4/§6.3/§6.4 Trim→Machining workflow reframe (sub-LOT split at Trim OUT not Machining IN; Machining OUT auto-completes via PLC and auto-moves to coupled Assembly Cell via new `CoupledDownstreamCellLocationId` LocationAttribute).
- §9.4 end-of-shift time entry (lunch + breaks only, ~15-min header window).
- FDS-07-006b reframed from per-session bound-query to **Gateway-broadcast-with-session-filter** (one DB query per 5s regardless of terminal count).
- Document-wide strip of project-execution decoration (Arc 2 / Phase N / version trailers / "Implementation deferred" admonitions / requirement-deletion tombstones).

**Standalone FDS Change Log doc** — `MPP_MES_FDS_CHANGELOG.md` + `.docx` created. Pre-release pattern: change log lives in companion doc while FDS is in active development; reintegrates into FDS at customer-review release.

**Data model v1.9j** — `Parts.ContainerConfig.ClosureMethod` extended with `ByVision`; UpperCamelCase casing applied; OI-02 caveat retired.

**Indexing & query-perf review** — full report at `Meeting_Notes/2026-04-28_DataModel_Indexing_Scaling_Review.md`. Phase 1–8 already-built schemas have good index coverage; the gap is the **deferred Arc 2 tables** (Lots event tables, Workorder.ConsumptionEvent / RejectEvent, Oee.DowntimeEvent, Quality.HoldEvent) — 14 tables × multiple indexes each need to be pinned in the data model spec before Arc 2 Phase 1 CREATE migrations are written. Three architectural concerns also flagged: 20-year audit retention strategy, `v_LotDerivedQuantities` materialization criteria, recursive-CTE depth limit on `LotGenealogy`. All pre-Arc-2-Phase-1 decisions.

### 2026-04-27 — Integration queue + UJ enrichment + closure batch

- **Integration queue from OIR v2.10 — 7 of 8 landed:** (1) OI-12 MaxParts ✅ `47a4e25`, (2) OI-18 ItemLocation cascade ✅ `0f7f40f`, (3) OI-08 Terminal mode ✅ `7a9d87e`, (4) OI-23 Lot derivations view ✅ `e393b7d`, (5) OI-16 PLC confirm + RequiresCompletionConfirm ✅ `55427f5`, (6) OI-21 Pausable LOT — design locked + landed ✅ `15edd5e`, (7) UJ-04 AIM pool — design locked + landed ✅ `82df891`. (8) OI-13 BOM export moved to seeding registry as S-06.
- **UJ enrichment + closure batch** — 13 UJ entries enriched to OI-style depth in v2.13 (commit `483948e`); Jacques reviewed the docx and closed 10 in v2.14 (commit `a2b58f5`): UJ-07/-08/-11/-13/-14/-16 (Option A defaults), UJ-09 (Option C — strict + supervisor override), UJ-10 (Option D — shift-end summary), UJ-17 (Option A — ConfirmationMethod LocationAttribute), UJ-18 (Gateway-script-async architectural — FDS-01-014 + print-dispatch async pattern + ShippingLabel +5 print-state cols).

### 2026-04-23 / -24 — Arc 2 Model Revisions + corrections

- **Arc 2 Model Revisions (2026-04-23 session)** — 6 commits on 2026-04-23 lifted doc set to Data Model v1.9 / FDS v0.11 / UJ v0.8 / OIR v2.7 / Arc 2 Plan v0.2. Tool/Cavity promoted to `Lots.Lot`; ProductionEvent reshaped to checkpoint form; new `Lots.IdentifierSequence` table; `MaxLotSize` repurposed as `PartsPerBasket`; OI-09 closed (cavity-parallel LOTs as peers); OI-26 deleted; OI-31 opened.
- **2026-04-24 corrections + integrations:**
  - ERD full rebuild — every tab fully current to v1.9; Master tab rebuilt from v1.5 baseline; Audit `bigbigint` typos + OEE column mismatches fixed; Tools cross-schema FKs drawn (commits `2a91da0`, `70d0f37`).
  - Phase 0 + Phase 1 of Arc 2 Plan rewritten in-place (clock# + PIN removed from body, not just overlay) — commit `9121502`.
  - **OI-07 correction** — `WorkOrderType` corrected to single `Production` row; Demand + Maintenance moved to FUTURE hooks; Recipe deleted (commit `ce3e080`).
  - **Storyboards + IPAddresses review** (commit `7550bb8`) — 2012 Flexware docs reviewed against v1.9 design. 83% coverage. Report at `reference/NewInput/REVIEW_2026-04-24.md`. OI-32 Material Allocation + OI-32b Material Classes opened.
  - **OI-31 single-line deployment memo for Ben** — `Meeting_Notes/2026-04-24_OI-31_Single-Line_Deployment_Impact.md`.
  - **Jacques's OIR review batch applied** (commit `6865d8d`, OIR v2.10) — 17 Part A OIs moved Resolved + 2 UJ closures (UJ-02, UJ-04).

### Earlier landmarks

- **Phase G SQL** — All five sub-phases (G.1–G.5) landed by 2026-04-23 (terminal commit `534f55c`). 853/853 tests passing across 20+ test suites at that point.
- **2026-04-20 OI review refactor** — All phases (A/B/C/D/E/F/G) landed.
- **Phase B Tool Management design spec** — Approved 2026-04-21 (commit `47ce9c7`). Full schema spec at `docs/superpowers/specs/2026-04-21-tool-management-design.md` v0.2.
- **Legacy PDF references** — `reference/Manufacturing Director Technical Manual.pdf` (2009 Flexware doc) converted to searchable Markdown at `reference/Manufacturing_Director_Technical_Manual.md` on 2026-04-21. Converter `reference/scripts/convert_mdtm_to_md.js` reusable for future Flexware docs.
- **Seed data extraction** — 876 rows extracted from FRS Appendices B/C/D/E into CSVs in `reference/seed_data/`, plus auto-generated `reference/seed_data.xlsx`. Per-appendix Node.js parsers in `reference/seed_data/parsers/`. Source PDF: `reference/MPP_FRS_Draft.pdf`.
