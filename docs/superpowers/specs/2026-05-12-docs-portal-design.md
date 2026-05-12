# MPP MES Internal Docs Portal — Design Spec

**Status:** Design approved 2026-05-12. Ready for plan + implementation.
**Owner:** Jacques Potgieter
**Spec date:** 2026-05-12

---

## 1. Purpose

A self-contained static HTML portal that consolidates the MPP MES documentation
set into a single browsable, searchable surface for the Blue Ridge team. The
portal is **internal-only** — it does NOT replace the `.docx` deliverables sent
to MPP for customer review. The `.docx` chain (markdown → pandoc →
`style_docx_tables.js`) stays intact; the portal is generated alongside it.

The integration value is cross-doc: today, answering "where does
`Parts.OperationTemplate` show up across the FDS, Data Model, and Open Items
Register?" requires four separate file searches. The portal answers it in one
search box.

## 2. v1 scope

Four docs in v1:

| Doc | Source | How it lands |
|---|---|---|
| FDS | `MPP_MES_FDS.md` | parsed → `fds.html` |
| Data Model | `MPP_MES_DATA_MODEL.md` | parsed → `data-model.html` |
| Open Issues Register | `MPP_MES_Open_Issues_Register.md` | parsed → `oir.html` |
| ERD | `MPP_MES_ERD.html` | iframed at `erd.html` (no rewrite) |

Out of scope for v1 (deferred to v2+, the generator template scales):
- User Journeys, Phased Plans (Config Tool + Plant Floor), Seeding Registry,
  Configuration UI Spec, SQL Best Practices, SQL Version Control, Meeting Notes
- Light theme / theme toggle (dark only)
- ERD content in search index
- Cross-doc backlinks ("OI-35 is referenced from…")
- PDF export of the portal
- Faceted/filtered search (scope filter, doc filter beyond MiniSearch's defaults)

## 3. Decisions matrix (from brainstorming session)

| # | Decision | Choice |
|---|---|---|
| Q1 | Purpose | **B** — Internal browse + search reference (supplements .docx) |
| Q2 | v1 doc scope | FDS + Data Model + OIR + ERD |
| Q3 | Source-of-truth + generator | **A** — Markdown stays authoritative; Node script regenerates HTML on demand |
| Q4 | Portal structure | **A + ii** — Multi-page site (real `.html` per doc, shared shell); ERD iframed |
| Q5 | Search | **C** — Cross-doc full-text via MiniSearch index baked into JSON |
| Q6 | Generator stack | **1** — Pure Node + markdown-it + custom plugins (no static site generator framework) |

## 4. Architecture

```
node tools/build_docs_portal.js
  ↓ reads
  MPP_MES_FDS.md
  MPP_MES_DATA_MODEL.md
  MPP_MES_Open_Issues_Register.md
  MPP_MES_ERD.html (referenced only, not parsed)
  ↓ emits
  docs_portal/
    ├── index.html         ← meta-refresh to fds.html
    ├── fds.html
    ├── data-model.html
    ├── oir.html
    ├── erd.html           ← iframes ../MPP_MES_ERD.html
    ├── search-index.json
    └── assets/
        ├── portal.css
        ├── portal.js
        └── minisearch.min.js
```

No server. Open `docs_portal/index.html` from the filesystem (`file://`). All
JavaScript is local (MiniSearch is bundled, not CDN-loaded).

## 5. Shared shell layout

Every page wears the same chrome:

```
┌─ Header ────────────────────────────────────────────────┐
│  MPP MES Docs  │ FDS │ Data Model │ OIR │ ERD │ [🔍]  │
├─ Sidebar ──────────┬─ Content ──────────────────────────┤
│ Sticky TOC (h2/h3) │  Rendered markdown                 │
│ — active section   │                                    │
│   highlighted on   │                                    │
│   scroll           │                                    │
└────────────────────┴────────────────────────────────────┘
Footer: source path + generator timestamp
```

**Theme:** inherits the ERD palette verbatim:

```css
--bg: #0f1117
--surface: #1a1d27
--surface-raised: #222633
--border: #2e3345
--text: #e1e4ed
--text-muted: #8b90a0
--accent: #6c8aff
--tab-hover: #2e3345
--tag-bg: #2a2f3f
```

Font: `'Segoe UI', -apple-system, BlinkMacSystemFont, sans-serif`. One CSS file
shared across pages.

**Sticky TOC:** left sidebar, two-level (h2 + h3). Active section highlighted
via `IntersectionObserver` as the user scrolls. Sections below the current
viewport collapse.

## 6. Custom markdown transforms — the actual value

Six markdown-it plugins, each in its own file under `tools/markdown_plugins/`:

### 6.1 `anchor-fds-req.js`
Every `**FDS-XX-NNN**` becomes a section-level anchor (`#fds-05-009`).
Requirement number stays bold; hover reveals a clickable `#` permalink chip.

### 6.2 `scope-pill.js`
Backtick-wrapped scope tags render as colored pills:

| Tag | Pill color |
|---|---|
| `` `MVP` `` | green |
| `` `MVP-EXPANDED` `` | cyan |
| `` `CONDITIONAL` `` | amber |
| `` `FUTURE` `` | gray |

### 6.3 `cross-doc-link.js`
Bare text patterns auto-link:

| Pattern | Target |
|---|---|
| `FDS-XX-NNN` | `fds.html#fds-XX-NNN` (within-doc anchor when already on FDS) |
| `OI-XX` | `oir.html#oi-XX` |
| `UJ-XX` | `oir.html#uj-XX` |
| `Schema.TableName` where Schema ∈ {Location, Parts, Lots, Workorder, Quality, Oee, Tools, Audit} | `data-model.html#schema-tablename` |
| `(FRS X.Y.Z)` | styled tag, no link (FRS PDF is outside the portal) |

### 6.4 `oi-badge.js`
At generation time the OIR is parsed FIRST to build a map of
`FDS-XX-NNN → [open OI IDs]`. Each requirement that has open items gets an
inline badge: `🔓 OI-35`. Closed items don't badge.

### 6.5 `schema-table-anchor.js` (Data Model only)
Every column-spec table for a `Schema.TableName` heading gets
`#schema-tablename` and `#schema-tablename-columnname` anchors so search
results can deep-link to specific columns.

### 6.6 `heading-permalinks.js`
h2/h3 get hover-revealed `#` chip with copy-to-clipboard JS for shareable
anchor links.

## 7. Search

**Engine:** MiniSearch (small, dependency-free, ~10 KB minified).
**Index format:** `search-index.json` written alongside the HTMLs.
**Granularity:** section-level — every h2 and h3 becomes an indexed document.

**Indexed fields:**

```js
{
  id: 'fds.html#fds-05-009',
  doc: 'fds',                              // for the doc badge in results
  title: '5.9 ...',                        // section title
  requirementId: 'FDS-05-009',             // when applicable
  scope: 'MVP',                            // when tagged
  body: '...full section text...'
}
```

**Boosts:** title 5×, requirementId 8×, body 1×.

**UI:** click 🔍 in header → modal with input + result list. Each result shows:
doc badge (color-coded), scope pill (if applicable), section title, snippet
with matched terms highlighted. Enter or click jumps to `<doc>.html#anchor`.

**Size budget:** target < 250 KB uncompressed for the four-doc corpus.
MiniSearch's default tokenizer + stemmer is fine; no custom Lunr-style
configuration needed.

## 8. ERD integration

`erd.html` is a ~30-line portal-shell wrapper around an iframe:

```html
<iframe src="../MPP_MES_ERD.html"
        style="width:100%; height: calc(100vh - 4rem); border: 0;">
</iframe>
```

A small "Open ERD full screen ↗" link sits in the page header for pan-zoom-heavy
work — clicking it opens the standalone `MPP_MES_ERD.html` in a new tab so the
user has the entire viewport.

ERD content is NOT in the search index for v1. Optional v2: index the table
descriptions baked into the ERD JS as a separate corpus.

## 9. Generator script

`tools/build_docs_portal.js` pipeline:

```
1. Parse OIR first       → build map of FDS-XX-NNN → [open OI IDs]
                           (required by oi-badge.js plugin)
2. Parse FDS, DM         → render with plugins; emit <doc>.html
3. Parse OIR             → render with plugins; emit oir.html
4. Emit erd.html shell   → iframe wrapper
5. Walk all rendered     → build MiniSearch corpus → write
   section tokens         search-index.json
6. Copy assets/          → portal.css, portal.js, minisearch.min.js
7. Write index.html      → meta-refresh to fds.html
```

**Idempotent.** Re-running blows away `docs_portal/` content and rebuilds.
**Generation time target:** < 5 seconds for the full doc set.

## 10. Testing / verification

`tools/build_docs_portal.test.js`:

- Run generator, assert each expected file exists in `docs_portal/`.
- `search-index.json` parses as valid JSON and contains ≥ 500 entries.
- Key anchors resolve: `fds.html#fds-05-009`, `oir.html#oi-35`,
  `data-model.html#parts-operationtemplate`.
- OI badge map built from OIR is non-empty for at least one known requirement.

**Visual spot-check** after first generation (no automation): open
`index.html`, click through doc switcher, run a sample search ("QualitySpec"),
verify cross-doc links work, verify scope pills + OI badges render.

No CI gate in v1 — manual rebuild after doc edits, matching the .docx flow.

## 11. Repo layout

```
tools/
├── build_docs_portal.js
├── build_docs_portal.test.js
├── markdown_plugins/
│   ├── anchor-fds-req.js
│   ├── scope-pill.js
│   ├── cross-doc-link.js
│   ├── oi-badge.js
│   ├── schema-table-anchor.js
│   └── heading-permalinks.js
└── assets/                       ← copied into docs_portal/assets/
    ├── portal.css
    ├── portal.js
    └── minisearch.min.js

docs_portal/                       ← generated output, committed
├── (see Architecture section)
```

## 12. Git hygiene

- **Committed:** `tools/build_docs_portal.js`, `tools/markdown_plugins/`,
  `tools/assets/`, the generated `docs_portal/` tree.
- Committing the generated output matches the precedent of committing
  `MPP_MES_*.docx` — lets teammates browse without rebuild.
- **gitignored:** `node_modules/` (already), any future watch-mode lock files.

## 13. Dependencies

| Package | Purpose | Approx size |
|---|---|---|
| `markdown-it` | Markdown → AST → HTML | ~100 KB |
| `markdown-it-attrs` | Inline `{#id .class}` attributes if needed | ~10 KB |
| `minisearch` | Client-side full-text search | ~10 KB |

All run-time deps (just MiniSearch bundled into `assets/minisearch.min.js`)
are local — no CDN calls from the generated HTML.

`package.json` lives at repo root if not already present; deps go in
`devDependencies` since they're only needed for generation.

## 14. Risks + mitigations

| Risk | Mitigation |
|---|---|
| Cross-doc auto-linker false positives (e.g. `Lots.Lot` matching when "lot" is just plain English) | Plugin restricts pattern to exact `Schema.TableName` with capitalized schema names from the known 8-schema set. Validates against known-table list before linking. |
| FDS-XX-NNN anchor collisions with prior docs | Anchors are per-page; collisions only matter within a doc, and FDS-XX-NNN is by construction unique. |
| MiniSearch index grows over time as more docs are added in v2+ | Acceptable up to ~1 MB. If exceeded, switch to lazy-loaded shards in v3. Not v1's problem. |
| iframe seam on ERD page (duplicated header chrome) | Acceptable v1 trade-off; absorb is a clean v2 if it bugs anyone. |
| OIR parse order matters (needed for oi-badge map) | Generator pipeline (Section 9) puts OIR parse first; documented. |

## 15. Resumption checklist for next session

When picking this up from a fresh session:

1. Read this spec.
2. Confirm with user that the design is still right (it was approved
   2026-05-12 but assumptions may have shifted).
3. Invoke `superpowers:writing-plans` skill to convert this spec into a
   step-by-step implementation plan.
4. Plan should break work into ~5–8 phases:
   - Phase 1: scaffold `tools/` + `package.json` + asset stubs
   - Phase 2: minimal markdown-it pipeline (read FDS, emit `fds.html` with
     no plugins, shared shell)
   - Phase 3: shell CSS + sticky TOC + active-section highlighting
   - Phase 4: markdown plugins one at a time (anchor-fds-req → scope-pill →
     cross-doc-link → oi-badge → schema-table-anchor → heading-permalinks)
   - Phase 5: data-model.html + oir.html + erd.html
   - Phase 6: MiniSearch index + search UI
   - Phase 7: smoke tests
   - Phase 8: regenerate, visual spot-check, commit `docs_portal/`
5. Then invoke `superpowers:executing-plans` or build straight through if
   the plan is small enough.
