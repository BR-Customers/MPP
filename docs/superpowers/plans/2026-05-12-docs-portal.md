# Internal Docs Portal Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a self-contained static HTML portal at `docs_portal/` that consolidates FDS + Data Model + OIR + ERD into one browsable, searchable internal reference for the Blue Ridge team. Generated from canonical markdown sources via a Node script — no server, opens from `file://`.

**Architecture:** Pure-Node generator (`tools/build_docs_portal.js`) parses three markdown docs with `markdown-it` + six custom plugins, emits one HTML file per doc plus an iframe wrapper for the ERD, and writes a section-level MiniSearch index. All pages share one CSS shell with the ERD palette. Generation is idempotent — re-running rebuilds `docs_portal/` from scratch.

**Tech Stack:** Node.js (built-in `node:fs/promises`, `node:test`), `markdown-it` + `markdown-it-attrs`, `minisearch` (bundled into client assets), vanilla CSS + vanilla JS.

**Spec:** `docs/superpowers/specs/2026-05-12-docs-portal-design.md` (approved 2026-05-12).

---

## File Structure

**New files:**

```
tools/
├── build_docs_portal.js            # Orchestrator: parse → render → emit
├── build_docs_portal.test.js       # node:test verification suite
├── lib/
│   ├── parse_oir_map.js            # Pre-parse OIR → {FDS-XX-NNN: [open OI IDs]}
│   ├── parse_dm_tables.js          # Pre-parse Data Model → Set of "Schema.Table"
│   ├── render_shell.js             # Page shell HTML (header + sidebar + footer)
│   ├── build_toc.js                # Extract h2/h3 from rendered HTML → sidebar TOC
│   ├── build_search_index.js       # Walk rendered HTMLs → MiniSearch corpus
│   └── slugify.js                  # FDS-05-009 → fds-05-009; "5.9 Section" → 5-9-section
├── markdown_plugins/
│   ├── anchor_fds_req.js           # **FDS-XX-NNN** → bold + section anchor
│   ├── scope_pill.js               # `MVP` / `CONDITIONAL` / etc. → colored pills
│   ├── cross_doc_link.js           # FDS-XX-NNN / OI-XX / UJ-XX / Schema.Table → links
│   ├── oi_badge.js                 # FDS-XX-NNN with open OIs → inline 🔓 badge
│   ├── schema_table_anchor.js      # DM only: anchor each Schema.TableName + column row
│   └── heading_permalinks.js       # h2/h3 hover # chip + copy-to-clipboard
└── assets/
    ├── portal.css                  # Shared shell styling (ERD palette)
    ├── portal.js                   # TOC active-section, search modal, permalink copy
    └── minisearch.min.js           # Copied from node_modules at build time

docs_portal/                         # Generated, committed alongside .docx
├── index.html                       # Meta-refresh → fds.html
├── fds.html
├── data-model.html
├── oir.html
├── erd.html                         # iframes ../MPP_MES_ERD.html
├── search-index.json
└── assets/                          # Copy of tools/assets/ + minisearch.min.js
```

**Modified files:**

- `package.json` — add `markdown-it`, `markdown-it-attrs`, `minisearch` to `devDependencies`.

**Naming:** plugin filenames use snake_case (`anchor_fds_req.js`) for consistency with `style_docx_tables.js` already at root. The spec section §11 shows kebab-case (`anchor-fds-req.js`); the engineer follows the locked snake_case in this plan — both work mechanically.

---

## Phase 1 — Scaffold

### Task 1: package.json devDeps + tools/ dir

**Files:**
- Modify: `package.json`
- Create: `tools/.gitkeep`

- [ ] **Step 1: Read existing package.json**

```bash
cat package.json
```

Expected current content:

```json
{
  "dependencies": {
    "docx": "^9.6.1",
    "xlsx": "^0.18.5"
  }
}
```

- [ ] **Step 2: Add devDependencies block**

Rewrite `package.json` to:

```json
{
  "dependencies": {
    "docx": "^9.6.1",
    "xlsx": "^0.18.5"
  },
  "devDependencies": {
    "markdown-it": "^14.1.0",
    "markdown-it-attrs": "^4.3.1",
    "minisearch": "^7.1.0"
  },
  "scripts": {
    "build:portal": "node tools/build_docs_portal.js",
    "test:portal": "node --test tools/build_docs_portal.test.js"
  }
}
```

- [ ] **Step 3: Install deps**

```bash
npm install
```

Expected: exits 0; `node_modules/markdown-it`, `node_modules/markdown-it-attrs`, `node_modules/minisearch` directories appear.

- [ ] **Step 4: Create the tools dir structure**

```bash
mkdir -p tools/lib tools/markdown_plugins tools/assets
```

- [ ] **Step 5: Commit**

```bash
git add package.json package-lock.json
git commit -m "chore(portal): add markdown-it + minisearch devDeps for docs portal generator"
```

---

## Phase 2 — Minimal pipeline (read FDS, emit fds.html)

### Task 2: render_shell.js — page shell with no content

**Files:**
- Create: `tools/lib/render_shell.js`
- Create: `tools/build_docs_portal.test.js`

- [ ] **Step 1: Write the failing test**

Append to `tools/build_docs_portal.test.js`:

```javascript
const test = require('node:test');
const assert = require('node:assert');
const { renderShell } = require('./lib/render_shell');

test('renderShell wraps content in nav header + main', () => {
  const html = renderShell({
    activeDoc: 'fds',
    title: 'FDS',
    contentHtml: '<h2>Hello</h2>',
    tocHtml: '<ul><li>Hello</li></ul>',
    sourcePath: 'MPP_MES_FDS.md',
    generatedAt: '2026-05-12T12:00:00Z',
  });
  assert.match(html, /<header/);
  assert.match(html, /href="fds\.html"[^>]*class="[^"]*active/);
  assert.match(html, /<aside[^>]*>[\s\S]*Hello[\s\S]*<\/aside>/);
  assert.match(html, /<main[^>]*>[\s\S]*<h2>Hello<\/h2>[\s\S]*<\/main>/);
  assert.match(html, /MPP_MES_FDS\.md/);
});
```

- [ ] **Step 2: Run test to verify it fails**

```bash
node --test tools/build_docs_portal.test.js
```

Expected: FAIL — `Cannot find module './lib/render_shell'`.

- [ ] **Step 3: Implement render_shell.js**

Create `tools/lib/render_shell.js`:

```javascript
const DOCS = [
  { key: 'fds', label: 'FDS', href: 'fds.html' },
  { key: 'data-model', label: 'Data Model', href: 'data-model.html' },
  { key: 'oir', label: 'OIR', href: 'oir.html' },
  { key: 'erd', label: 'ERD', href: 'erd.html' },
];

function escape(s) {
  return String(s).replace(/[&<>"]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]));
}

function renderShell({ activeDoc, title, contentHtml, tocHtml, sourcePath, generatedAt }) {
  const navLinks = DOCS.map((d) => {
    const cls = d.key === activeDoc ? 'nav-link active' : 'nav-link';
    return `<a href="${d.href}" class="${cls}">${d.label}</a>`;
  }).join('');

  return `<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>${escape(title)} — MPP MES Docs</title>
<link rel="stylesheet" href="assets/portal.css">
</head>
<body data-active-doc="${activeDoc}">
<header class="portal-header">
  <div class="brand">MPP MES Docs</div>
  <nav class="doc-nav">${navLinks}</nav>
  <button id="search-trigger" class="search-trigger" aria-label="Search">🔍</button>
</header>
<div class="portal-body">
  <aside class="portal-toc" aria-label="Section navigation">${tocHtml}</aside>
  <main class="portal-main">${contentHtml}</main>
</div>
<footer class="portal-footer">
  <span>Source: <code>${escape(sourcePath)}</code></span>
  <span>Generated: <time datetime="${escape(generatedAt)}">${escape(generatedAt)}</time></span>
</footer>
<div id="search-modal" class="search-modal" hidden></div>
<script src="assets/minisearch.min.js"></script>
<script src="assets/portal.js"></script>
</body>
</html>`;
}

module.exports = { renderShell, DOCS };
```

- [ ] **Step 4: Run test to verify it passes**

```bash
node --test tools/build_docs_portal.test.js
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add tools/lib/render_shell.js tools/build_docs_portal.test.js
git commit -m "feat(portal): page shell renderer with nav + sidebar + footer"
```

### Task 3: build_docs_portal.js — minimal end-to-end FDS pipeline

**Files:**
- Create: `tools/build_docs_portal.js`

- [ ] **Step 1: Add the failing test**

Append to `tools/build_docs_portal.test.js`:

```javascript
const fs = require('node:fs');
const path = require('node:path');
const { execSync } = require('node:child_process');

const REPO_ROOT = path.resolve(__dirname, '..');
const PORTAL_DIR = path.join(REPO_ROOT, 'docs_portal');

test('build script emits fds.html with shell + parsed markdown', () => {
  execSync('node tools/build_docs_portal.js', { cwd: REPO_ROOT, stdio: 'pipe' });
  const fdsPath = path.join(PORTAL_DIR, 'fds.html');
  assert.ok(fs.existsSync(fdsPath), 'fds.html should exist');
  const html = fs.readFileSync(fdsPath, 'utf8');
  assert.match(html, /<header class="portal-header"/);
  assert.match(html, /<main[^>]*>[\s\S]*<h1[\s\S]*MPP MES[\s\S]*<\/h1>/i);
});
```

- [ ] **Step 2: Run test, expect failure**

```bash
node --test tools/build_docs_portal.test.js
```

Expected: FAIL — `Cannot find module './build_docs_portal'` or `ENOENT: tools/build_docs_portal.js`.

- [ ] **Step 3: Implement build_docs_portal.js (minimal)**

Create `tools/build_docs_portal.js`:

```javascript
#!/usr/bin/env node
const fs = require('node:fs');
const path = require('node:path');
const MarkdownIt = require('markdown-it');
const { renderShell } = require('./lib/render_shell');

const REPO_ROOT = path.resolve(__dirname, '..');
const PORTAL_DIR = path.join(REPO_ROOT, 'docs_portal');
const ASSETS_SRC = path.join(__dirname, 'assets');
const ASSETS_DEST = path.join(PORTAL_DIR, 'assets');

const DOCS = [
  { key: 'fds', source: 'MPP_MES_FDS.md', out: 'fds.html', title: 'FDS' },
];

function rmrf(dir) {
  if (fs.existsSync(dir)) fs.rmSync(dir, { recursive: true, force: true });
}

function copyDir(src, dest) {
  fs.mkdirSync(dest, { recursive: true });
  if (!fs.existsSync(src)) return;
  for (const entry of fs.readdirSync(src, { withFileTypes: true })) {
    const s = path.join(src, entry.name);
    const d = path.join(dest, entry.name);
    if (entry.isDirectory()) copyDir(s, d);
    else fs.copyFileSync(s, d);
  }
}

function buildMd() {
  return new MarkdownIt({ html: true, linkify: false, typographer: false });
}

function build() {
  rmrf(PORTAL_DIR);
  fs.mkdirSync(PORTAL_DIR, { recursive: true });

  const md = buildMd();
  const generatedAt = new Date().toISOString();

  for (const doc of DOCS) {
    const src = path.join(REPO_ROOT, doc.source);
    const raw = fs.readFileSync(src, 'utf8');
    const contentHtml = md.render(raw);
    const html = renderShell({
      activeDoc: doc.key,
      title: doc.title,
      contentHtml,
      tocHtml: '',
      sourcePath: doc.source,
      generatedAt,
    });
    fs.writeFileSync(path.join(PORTAL_DIR, doc.out), html, 'utf8');
  }

  // Asset copy (empty in this task; populated in Phase 3+)
  copyDir(ASSETS_SRC, ASSETS_DEST);

  console.log(`Built ${DOCS.length} doc(s) → ${PORTAL_DIR}`);
}

if (require.main === module) build();

module.exports = { build };
```

- [ ] **Step 4: Run test to verify pass**

```bash
node --test tools/build_docs_portal.test.js
```

Expected: PASS for the shell test AND the build test.

- [ ] **Step 5: Sanity-check the output**

```bash
node tools/build_docs_portal.js
```

Expected stdout: `Built 1 doc(s) → .../docs_portal`. `docs_portal/fds.html` exists, ~big file.

- [ ] **Step 6: Commit**

```bash
git add tools/build_docs_portal.js tools/build_docs_portal.test.js
git commit -m "feat(portal): minimal FDS → fds.html pipeline (no plugins, no TOC, no shell CSS yet)"
```

---

## Phase 3 — Shell CSS + sticky TOC + active-section highlighting

### Task 4: portal.css — ERD-palette shell

**Files:**
- Create: `tools/assets/portal.css`

- [ ] **Step 1: Write portal.css**

```css
:root {
  --bg: #0f1117;
  --surface: #1a1d27;
  --surface-raised: #222633;
  --border: #2e3345;
  --text: #e1e4ed;
  --text-muted: #8b90a0;
  --accent: #6c8aff;
  --tab-hover: #2e3345;
  --tag-bg: #2a2f3f;
  --pill-mvp: #2d6a4f;
  --pill-mvp-expanded: #1d6a8f;
  --pill-conditional: #8a6d2a;
  --pill-future: #4a4f5e;
  --header-height: 56px;
  --footer-height: 32px;
  --toc-width: 260px;
}
* { margin: 0; padding: 0; box-sizing: border-box; }
html, body { background: var(--bg); color: var(--text); }
body {
  font-family: 'Segoe UI', -apple-system, BlinkMacSystemFont, sans-serif;
  line-height: 1.6;
  font-size: 14px;
}
code, pre { font-family: 'Cascadia Code', 'Fira Code', 'Consolas', monospace; }

/* Header */
.portal-header {
  position: sticky; top: 0; z-index: 50;
  height: var(--header-height);
  background: var(--surface);
  border-bottom: 1px solid var(--border);
  display: flex; align-items: center;
  padding: 0 1.5rem; gap: 1.5rem;
}
.brand { font-weight: 600; color: var(--text); font-size: 0.95rem; }
.doc-nav { display: flex; gap: 0.25rem; flex: 1; }
.nav-link {
  color: var(--text-muted);
  padding: 0.5rem 0.9rem;
  text-decoration: none;
  border-radius: 4px;
  font-size: 0.85rem;
  transition: color 0.15s, background 0.15s;
}
.nav-link:hover { color: var(--text); background: var(--tab-hover); }
.nav-link.active { color: var(--accent); background: var(--surface-raised); }
.search-trigger {
  background: var(--surface-raised); border: 1px solid var(--border);
  color: var(--text); padding: 0.4rem 0.7rem; border-radius: 4px;
  cursor: pointer; font-size: 0.9rem;
}
.search-trigger:hover { background: var(--tab-hover); }

/* Body layout */
.portal-body {
  display: grid;
  grid-template-columns: var(--toc-width) 1fr;
  min-height: calc(100vh - var(--header-height) - var(--footer-height));
}
.portal-toc {
  position: sticky; top: var(--header-height);
  align-self: start;
  height: calc(100vh - var(--header-height) - var(--footer-height));
  overflow-y: auto;
  padding: 1.5rem 1rem;
  background: var(--surface);
  border-right: 1px solid var(--border);
  font-size: 0.83rem;
}
.portal-toc ul { list-style: none; padding-left: 0; }
.portal-toc ul ul { padding-left: 0.9rem; margin-top: 0.2rem; }
.portal-toc li { margin: 0.1rem 0; }
.portal-toc a {
  display: block;
  color: var(--text-muted);
  text-decoration: none;
  padding: 0.15rem 0.5rem;
  border-left: 2px solid transparent;
  border-radius: 0 3px 3px 0;
}
.portal-toc a:hover { color: var(--text); background: var(--tab-hover); }
.portal-toc a.active { color: var(--accent); border-left-color: var(--accent); background: var(--surface-raised); }

/* Main content */
.portal-main {
  padding: 2rem 3rem 4rem;
  max-width: 90ch;
  overflow-x: auto;
}
.portal-main h1 { font-size: 1.8rem; margin: 0 0 0.75rem; }
.portal-main h2 {
  font-size: 1.35rem;
  margin: 2.5rem 0 0.75rem;
  padding-bottom: 0.4rem;
  border-bottom: 1px solid var(--border);
}
.portal-main h3 { font-size: 1.1rem; margin: 1.75rem 0 0.5rem; }
.portal-main h4 { font-size: 0.95rem; margin: 1.25rem 0 0.4rem; color: var(--text-muted); }
.portal-main p { margin: 0.6rem 0; }
.portal-main ul, .portal-main ol { margin: 0.5rem 0 0.5rem 1.5rem; }
.portal-main li { margin: 0.2rem 0; }
.portal-main a { color: var(--accent); text-decoration: none; }
.portal-main a:hover { text-decoration: underline; }
.portal-main code {
  background: var(--surface-raised);
  padding: 0.1rem 0.3rem; border-radius: 3px;
  font-size: 0.88em;
}
.portal-main pre {
  background: var(--surface);
  border: 1px solid var(--border);
  border-radius: 6px;
  padding: 1rem;
  overflow-x: auto;
  margin: 0.8rem 0;
}
.portal-main pre code { background: none; padding: 0; }
.portal-main blockquote {
  border-left: 3px solid var(--accent);
  padding: 0.5rem 1rem;
  margin: 0.8rem 0;
  background: var(--surface);
  color: var(--text-muted);
}
.portal-main table {
  border-collapse: collapse;
  margin: 0.8rem 0;
  font-size: 0.88rem;
  width: 100%;
}
.portal-main th, .portal-main td {
  border: 1px solid var(--border);
  padding: 0.4rem 0.7rem;
  text-align: left;
  vertical-align: top;
}
.portal-main th { background: var(--surface-raised); font-weight: 600; }
.portal-main tr:nth-child(even) td { background: var(--surface); }
.portal-main hr { border: none; border-top: 1px solid var(--border); margin: 2rem 0; }

/* Heading permalinks (Plugin 6.6) */
.heading-permalink {
  opacity: 0; margin-left: 0.4rem;
  color: var(--text-muted); font-weight: 400; text-decoration: none;
  font-size: 0.85em;
  transition: opacity 0.15s;
}
.portal-main h2:hover .heading-permalink,
.portal-main h3:hover .heading-permalink { opacity: 1; }
.heading-permalink:hover { color: var(--accent); }

/* Scope pills (Plugin 6.2) */
.scope-pill {
  display: inline-block;
  padding: 0.08rem 0.5rem;
  border-radius: 10px;
  font-size: 0.72rem;
  font-weight: 600;
  letter-spacing: 0.02em;
  font-family: inherit;
}
.scope-pill.scope-mvp { background: var(--pill-mvp); color: #d8f3dc; }
.scope-pill.scope-mvp-expanded { background: var(--pill-mvp-expanded); color: #cde8f5; }
.scope-pill.scope-conditional { background: var(--pill-conditional); color: #fff3d6; }
.scope-pill.scope-future { background: var(--pill-future); color: var(--text); }

/* OI badge (Plugin 6.4) */
.oi-badge {
  display: inline-block;
  margin-left: 0.4rem;
  padding: 0.08rem 0.45rem;
  background: var(--pill-conditional);
  color: #fff3d6;
  border-radius: 10px;
  font-size: 0.7rem;
  font-weight: 600;
  text-decoration: none;
}
.oi-badge:hover { filter: brightness(1.15); }

/* FRS reference (Plugin 6.3, styled but not linked) */
.frs-ref {
  background: var(--tag-bg);
  color: var(--text-muted);
  padding: 0.05rem 0.4rem;
  border-radius: 3px;
  font-family: 'Cascadia Code', 'Fira Code', monospace;
  font-size: 0.82em;
}

/* Footer */
.portal-footer {
  height: var(--footer-height);
  background: var(--surface);
  border-top: 1px solid var(--border);
  color: var(--text-muted);
  font-size: 0.8rem;
  padding: 0 1.5rem;
  display: flex; align-items: center; justify-content: space-between;
}

/* Search modal */
.search-modal {
  position: fixed; inset: 10vh 0 auto; z-index: 100;
  margin: 0 auto; width: min(680px, 90vw);
  background: var(--surface-raised);
  border: 1px solid var(--border);
  border-radius: 8px;
  box-shadow: 0 8px 40px rgba(0, 0, 0, 0.6);
  display: flex; flex-direction: column;
  max-height: 70vh;
}
.search-modal[hidden] { display: none; }
.search-modal input {
  background: transparent;
  border: none; border-bottom: 1px solid var(--border);
  color: var(--text);
  padding: 1rem 1.25rem;
  font-size: 1rem;
  font-family: inherit;
  outline: none;
}
.search-modal .results { overflow-y: auto; padding: 0.5rem 0; }
.search-result {
  display: block;
  padding: 0.6rem 1.25rem;
  text-decoration: none;
  color: var(--text);
  border-bottom: 1px solid var(--border);
}
.search-result:last-child { border-bottom: none; }
.search-result:hover, .search-result.focused { background: var(--tab-hover); }
.search-result .doc-badge {
  display: inline-block;
  padding: 0.05rem 0.4rem;
  background: var(--surface);
  border-radius: 3px;
  font-size: 0.7rem;
  color: var(--text-muted);
  margin-right: 0.5rem;
  text-transform: uppercase;
}
.search-result .snippet { color: var(--text-muted); font-size: 0.82rem; margin-top: 0.2rem; }
.search-result mark { background: rgba(108, 138, 255, 0.3); color: var(--text); padding: 0 2px; border-radius: 2px; }

/* ERD page tweak */
.erd-frame { width: 100%; height: calc(100vh - var(--header-height) - var(--footer-height)); border: 0; display: block; }
.erd-fullscreen-link {
  display: inline-block;
  margin: 1rem 0;
  color: var(--accent);
  text-decoration: none;
}
.erd-fullscreen-link:hover { text-decoration: underline; }
```

- [ ] **Step 2: Commit**

```bash
git add tools/assets/portal.css
git commit -m "feat(portal): shared shell CSS with ERD palette + scope pills + search modal styles"
```

### Task 5: build_toc.js — extract h2/h3 → nested list

**Files:**
- Create: `tools/lib/build_toc.js`

- [ ] **Step 1: Add the failing test**

Append to `tools/build_docs_portal.test.js`:

```javascript
const { buildToc } = require('./lib/build_toc');

test('buildToc nests h3 under h2', () => {
  const html = '<h2 id="a">A</h2><p/><h3 id="a1">A.1</h3><h3 id="a2">A.2</h3><h2 id="b">B</h2>';
  const toc = buildToc(html);
  assert.match(toc, /<a[^>]*href="#a"[^>]*>A<\/a>/);
  assert.match(toc, /<a[^>]*href="#a1"[^>]*>A\.1<\/a>/);
  assert.match(toc, /<a[^>]*href="#b"[^>]*>B<\/a>/);
  // h3s nested under their h2
  const aIdx = toc.indexOf('href="#a"');
  const a1Idx = toc.indexOf('href="#a1"');
  const bIdx = toc.indexOf('href="#b"');
  assert.ok(aIdx < a1Idx && a1Idx < bIdx, 'A.1 should appear between A and B');
});

test('buildToc strips trailing pills/badges from heading text', () => {
  const html = '<h2 id="x">Section <span class="scope-pill scope-mvp">MVP</span></h2>';
  const toc = buildToc(html);
  // pill text excluded from TOC label
  assert.match(toc, /<a[^>]*href="#x"[^>]*>Section\s*<\/a>/);
});
```

- [ ] **Step 2: Run test, expect failure**

```bash
node --test tools/build_docs_portal.test.js
```

Expected: FAIL on `buildToc` missing.

- [ ] **Step 3: Implement build_toc.js**

```javascript
function buildToc(renderedHtml) {
  const headingRe = /<h([23])\s+id="([^"]+)"[^>]*>([\s\S]*?)<\/h\1>/g;
  const items = [];
  let m;
  while ((m = headingRe.exec(renderedHtml)) !== null) {
    const level = Number(m[1]);
    const id = m[2];
    let text = m[3]
      .replace(/<[^>]+>/g, '')         // strip inline HTML (pills, badges, code, anchors)
      .replace(/\s+/g, ' ')
      .trim();
    items.push({ level, id, text });
  }
  if (items.length === 0) return '<ul></ul>';

  // Nest: h3s go under the most recent h2.
  let html = '<ul>';
  let openSub = false;
  for (let i = 0; i < items.length; i++) {
    const it = items[i];
    if (it.level === 2) {
      if (openSub) { html += '</ul></li>'; openSub = false; }
      else if (i > 0) html += '</li>';
      html += `<li><a href="#${it.id}">${it.text}</a>`;
      // Peek ahead — if next is h3, open sublist
      if (items[i + 1] && items[i + 1].level === 3) { html += '<ul>'; openSub = true; }
    } else if (it.level === 3) {
      html += `<li><a href="#${it.id}">${it.text}</a></li>`;
    }
  }
  if (openSub) html += '</ul></li>';
  else html += '</li>';
  html += '</ul>';
  return html;
}

module.exports = { buildToc };
```

- [ ] **Step 4: Run test to verify pass**

```bash
node --test tools/build_docs_portal.test.js
```

Expected: PASS.

- [ ] **Step 5: Wire buildToc into build_docs_portal.js**

In `tools/build_docs_portal.js`, replace the doc loop body so it calls `buildToc`. Edit the file:

```javascript
const { buildToc } = require('./lib/build_toc');
// ... inside build()'s for loop:
    const contentHtml = md.render(raw);
    const tocHtml = buildToc(contentHtml);
    const html = renderShell({
      activeDoc: doc.key,
      title: doc.title,
      contentHtml,
      tocHtml,
      sourcePath: doc.source,
      generatedAt,
    });
```

Note: this works once markdown-it emits id attributes on headings — done in Task 7 (heading_permalinks plugin). Until then, the TOC will be empty; that's OK for now.

- [ ] **Step 6: Commit**

```bash
git add tools/lib/build_toc.js tools/build_docs_portal.js tools/build_docs_portal.test.js
git commit -m "feat(portal): TOC builder (nested h2 + h3) with pill/badge stripping"
```

### Task 6: portal.js — active-section + permalink copy + search modal stub

**Files:**
- Create: `tools/assets/portal.js`

- [ ] **Step 1: Write portal.js**

```javascript
// MPP MES Docs Portal — client-side behavior
(function () {
  'use strict';

  // 1. Active-section highlight in TOC via IntersectionObserver
  function setupTocActiveHighlight() {
    const toc = document.querySelector('.portal-toc');
    const main = document.querySelector('.portal-main');
    if (!toc || !main) return;

    const headings = main.querySelectorAll('h2[id], h3[id]');
    const tocLinks = new Map();
    toc.querySelectorAll('a[href^="#"]').forEach((a) => {
      tocLinks.set(a.getAttribute('href').slice(1), a);
    });

    const visible = new Set();
    function updateActive() {
      tocLinks.forEach((a) => a.classList.remove('active'));
      // Pick the topmost visible heading
      let topId = null;
      let topOffset = Infinity;
      visible.forEach((id) => {
        const el = document.getElementById(id);
        if (!el) return;
        const top = el.getBoundingClientRect().top;
        if (top < topOffset) { topOffset = top; topId = id; }
      });
      if (topId && tocLinks.has(topId)) tocLinks.get(topId).classList.add('active');
    }

    const obs = new IntersectionObserver((entries) => {
      entries.forEach((e) => {
        if (e.isIntersecting) visible.add(e.target.id);
        else visible.delete(e.target.id);
      });
      updateActive();
    }, { rootMargin: '-72px 0px -50% 0px', threshold: 0 });

    headings.forEach((h) => obs.observe(h));
  }

  // 2. Permalink-chip click → copy to clipboard
  function setupPermalinkCopy() {
    document.addEventListener('click', (e) => {
      const a = e.target.closest('a.heading-permalink');
      if (!a) return;
      const url = new URL(a.getAttribute('href'), window.location.href).href;
      if (navigator.clipboard && navigator.clipboard.writeText) {
        e.preventDefault();
        navigator.clipboard.writeText(url).then(() => {
          a.dataset.copied = '1';
          setTimeout(() => delete a.dataset.copied, 1200);
        });
      }
    });
  }

  // 3. Search modal — wired in Phase 6 (Task 14). Trigger toggles visibility.
  function setupSearchModal() {
    const trigger = document.getElementById('search-trigger');
    const modal = document.getElementById('search-modal');
    if (!trigger || !modal) return;
    trigger.addEventListener('click', () => openSearch());
    document.addEventListener('keydown', (e) => {
      if (e.key === '/' && !['INPUT', 'TEXTAREA'].includes(document.activeElement.tagName)) {
        e.preventDefault();
        openSearch();
      } else if (e.key === 'Escape' && !modal.hidden) {
        modal.hidden = true;
      }
    });
    function openSearch() {
      if (!modal.dataset.initialized) initSearch(modal);
      modal.hidden = false;
      const input = modal.querySelector('input');
      if (input) { input.value = ''; input.focus(); modal.querySelector('.results').innerHTML = ''; }
    }
  }

  function initSearch(modal) {
    modal.dataset.initialized = '1';
    modal.innerHTML = '<input type="search" placeholder="Search docs… (Esc to close)" autocomplete="off"><div class="results"></div>';
    const input = modal.querySelector('input');
    const results = modal.querySelector('.results');

    // Lazy-load the index
    let indexPromise = null;
    function getIndex() {
      if (!indexPromise) {
        indexPromise = fetch('search-index.json')
          .then((r) => r.json())
          .then((raw) => {
            // eslint-disable-next-line no-undef
            const idx = MiniSearch.loadJSON(JSON.stringify(raw.index), raw.options);
            return { idx, byId: new Map(raw.docs.map((d) => [d.id, d])) };
          });
      }
      return indexPromise;
    }

    let debounce;
    input.addEventListener('input', () => {
      clearTimeout(debounce);
      debounce = setTimeout(() => runSearch(input.value), 80);
    });
    function runSearch(q) {
      results.innerHTML = '';
      if (!q || q.trim().length < 2) return;
      getIndex().then(({ idx, byId }) => {
        const hits = idx.search(q, { prefix: true, fuzzy: 0.15, combineWith: 'AND' }).slice(0, 30);
        results.innerHTML = hits.map((h) => renderResult(byId.get(h.id), q)).join('');
      });
    }
    function renderResult(doc, q) {
      if (!doc) return '';
      const snippet = makeSnippet(doc.body || '', q);
      const scopeHtml = doc.scope ? `<span class="scope-pill scope-${doc.scope.toLowerCase()}">${doc.scope}</span> ` : '';
      return `<a class="search-result" href="${doc.id}">
        <div><span class="doc-badge">${doc.doc}</span>${scopeHtml}${escapeHtml(doc.title || '')}</div>
        <div class="snippet">${snippet}</div>
      </a>`;
    }
    function makeSnippet(body, q) {
      const lc = body.toLowerCase();
      const term = q.toLowerCase().split(/\s+/).filter(Boolean)[0] || '';
      const idx = term ? lc.indexOf(term) : -1;
      const start = idx >= 0 ? Math.max(0, idx - 60) : 0;
      const slice = body.slice(start, start + 220);
      return escapeHtml(slice).replace(new RegExp(escapeRe(term), 'gi'), (m) => `<mark>${m}</mark>`);
    }
    function escapeRe(s) { return s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&'); }
    function escapeHtml(s) { return String(s).replace(/[&<>"]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c])); }
  }

  document.addEventListener('DOMContentLoaded', () => {
    setupTocActiveHighlight();
    setupPermalinkCopy();
    setupSearchModal();
  });
})();
```

- [ ] **Step 2: Commit**

```bash
git add tools/assets/portal.js
git commit -m "feat(portal): client JS — TOC active highlight + permalink copy + search modal scaffolding"
```

---

## Phase 4 — Markdown plugins

### Task 7: heading_permalinks plugin (added first because TOC depends on heading ids)

**Files:**
- Create: `tools/lib/slugify.js`
- Create: `tools/markdown_plugins/heading_permalinks.js`

- [ ] **Step 1: Add slugify test + impl**

Append to `tools/build_docs_portal.test.js`:

```javascript
const { slugify } = require('./lib/slugify');

test('slugify lowercases, hyphenates, strips punctuation', () => {
  assert.strictEqual(slugify('5.9 Sub-LOT Split'), '5-9-sub-lot-split');
  assert.strictEqual(slugify('FDS-05-009 SHALL …'), 'fds-05-009-shall');
  assert.strictEqual(slugify('Parts.OperationTemplate'), 'parts-operationtemplate');
});

test('slugify de-dupes within a document', () => {
  const seen = new Map();
  assert.strictEqual(slugify('X', seen), 'x');
  assert.strictEqual(slugify('X', seen), 'x-2');
  assert.strictEqual(slugify('X', seen), 'x-3');
});
```

Create `tools/lib/slugify.js`:

```javascript
function slugify(text, seen) {
  let slug = String(text)
    .toLowerCase()
    .replace(/<[^>]+>/g, '')                // strip HTML
    .replace(/[^\w\s.-]/g, '')              // drop punctuation except dot/dash/space
    .replace(/\./g, '-')                    // dots to dashes
    .replace(/\s+/g, '-')                   // whitespace to dashes
    .replace(/-+/g, '-')                    // collapse runs
    .replace(/^-|-$/g, '');                 // trim leading/trailing
  if (!slug) slug = 'section';
  if (!seen) return slug;
  if (!seen.has(slug)) { seen.set(slug, 1); return slug; }
  const n = seen.get(slug) + 1;
  seen.set(slug, n);
  return `${slug}-${n}`;
}

module.exports = { slugify };
```

- [ ] **Step 2: Run tests, expect PASS**

```bash
node --test tools/build_docs_portal.test.js
```

- [ ] **Step 3: Add plugin test**

Append to `tools/build_docs_portal.test.js`:

```javascript
const MdLib = require('markdown-it');
const headingPermalinks = require('./markdown_plugins/heading_permalinks');

test('heading_permalinks adds id + permalink anchor to h2/h3', () => {
  const md = new MdLib();
  md.use(headingPermalinks);
  const html = md.render('## My Section\n\n### Sub one\n');
  assert.match(html, /<h2[^>]*id="my-section"/);
  assert.match(html, /<a[^>]*class="heading-permalink"[^>]*href="#my-section"/);
  assert.match(html, /<h3[^>]*id="sub-one"/);
});

test('heading_permalinks de-dupes within a render pass', () => {
  const md = new MdLib();
  md.use(headingPermalinks);
  const html = md.render('## Same\n\n## Same\n');
  assert.match(html, /id="same"/);
  assert.match(html, /id="same-2"/);
});
```

- [ ] **Step 4: Run test, expect FAIL**

```bash
node --test tools/build_docs_portal.test.js
```

- [ ] **Step 5: Implement heading_permalinks.js**

Create `tools/markdown_plugins/heading_permalinks.js`:

```javascript
const { slugify } = require('../lib/slugify');

module.exports = function headingPermalinks(md) {
  md.core.ruler.push('heading_permalinks', (state) => {
    const seen = new Map();
    for (let i = 0; i < state.tokens.length; i++) {
      const tok = state.tokens[i];
      if (tok.type !== 'heading_open') continue;
      if (tok.tag !== 'h2' && tok.tag !== 'h3') continue;
      const inline = state.tokens[i + 1];
      if (!inline || inline.type !== 'inline') continue;
      const text = inline.content;
      const id = slugify(text, seen);
      tok.attrSet('id', id);
      // Append a permalink anchor as the last inline child.
      const linkOpen = new state.Token('html_inline', '', 0);
      linkOpen.content = ` <a class="heading-permalink" href="#${id}" aria-label="Permalink">#</a>`;
      inline.children = inline.children || [];
      inline.children.push(linkOpen);
    }
  });
};
```

- [ ] **Step 6: Wire into builder**

Edit `tools/build_docs_portal.js`. Change `buildMd()` to:

```javascript
const headingPermalinks = require('./markdown_plugins/heading_permalinks');
const markdownItAttrs = require('markdown-it-attrs');

function buildMd(opts = {}) {
  const md = new MarkdownIt({ html: true, linkify: false, typographer: false });
  md.use(markdownItAttrs);
  md.use(headingPermalinks);
  return md;
}
```

- [ ] **Step 7: Run tests + manual rebuild check**

```bash
node --test tools/build_docs_portal.test.js
node tools/build_docs_portal.js
```

Inspect `docs_portal/fds.html`: heading ids should appear, TOC should now populate.

- [ ] **Step 8: Commit**

```bash
git add tools/lib/slugify.js tools/markdown_plugins/heading_permalinks.js tools/build_docs_portal.js tools/build_docs_portal.test.js
git commit -m "feat(portal): heading_permalinks plugin — adds ids + clickable # chips to h2/h3"
```

### Task 8: anchor_fds_req plugin

**Files:**
- Create: `tools/markdown_plugins/anchor_fds_req.js`

- [ ] **Step 1: Add test**

Append to `tools/build_docs_portal.test.js`:

```javascript
const anchorFdsReq = require('./markdown_plugins/anchor_fds_req');

test('anchor_fds_req wraps **FDS-XX-NNN** in an anchor', () => {
  const md = new MdLib();
  md.use(anchorFdsReq);
  const html = md.render('Some text **FDS-05-009** more text.');
  assert.match(html, /<a[^>]*id="fds-05-009"[^>]*>[\s\S]*FDS-05-009[\s\S]*<\/a>/);
  assert.match(html, /<strong>FDS-05-009<\/strong>/);
});

test('anchor_fds_req leaves plain text matches alone', () => {
  const md = new MdLib();
  md.use(anchorFdsReq);
  const html = md.render('See FDS-05-009 for details.');
  assert.doesNotMatch(html, /id="fds-05-009"/);
});
```

- [ ] **Step 2: Run, expect FAIL**

```bash
node --test tools/build_docs_portal.test.js
```

- [ ] **Step 3: Implement**

```javascript
// Only matches the pattern **FDS-XX-NNN** (bold marker). Plain-text FDS-XX-NNN
// is handled by cross_doc_link (linking, not anchoring).
const RE = /^FDS-(\d{2})-(\d{3})$/;

module.exports = function anchorFdsReq(md) {
  md.core.ruler.after('inline', 'anchor_fds_req', (state) => {
    for (const blockTok of state.tokens) {
      if (blockTok.type !== 'inline' || !blockTok.children) continue;
      const kids = blockTok.children;
      for (let i = 0; i < kids.length; i++) {
        const t = kids[i];
        if (t.type !== 'strong_open') continue;
        // Look for: strong_open, text(FDS-XX-NNN), strong_close
        const textTok = kids[i + 1];
        const closeTok = kids[i + 2];
        if (!textTok || textTok.type !== 'text' || !closeTok || closeTok.type !== 'strong_close') continue;
        const m = RE.exec(textTok.content.trim());
        if (!m) continue;
        const id = `fds-${m[1]}-${m[2]}`;
        const linkOpen = new state.Token('html_inline', '', 0);
        linkOpen.content = `<a id="${id}" class="fds-req-anchor" href="#${id}">`;
        const linkClose = new state.Token('html_inline', '', 0);
        linkClose.content = '</a>';
        kids.splice(i, 0, linkOpen);
        kids.splice(i + 4, 0, linkClose);
        i += 4;
      }
    }
  });
};
```

- [ ] **Step 4: Wire + run**

In `tools/build_docs_portal.js`:

```javascript
md.use(require('./markdown_plugins/anchor_fds_req'));
```

(Add after `headingPermalinks`.)

```bash
node --test tools/build_docs_portal.test.js
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add tools/markdown_plugins/anchor_fds_req.js tools/build_docs_portal.js tools/build_docs_portal.test.js
git commit -m "feat(portal): anchor_fds_req plugin — bold FDS-XX-NNN gets a section anchor"
```

### Task 9: scope_pill plugin

**Files:**
- Create: `tools/markdown_plugins/scope_pill.js`

- [ ] **Step 1: Add test**

```javascript
const scopePill = require('./markdown_plugins/scope_pill');

test('scope_pill renders backticked MVP/CONDITIONAL/etc. as colored spans', () => {
  const md = new MdLib();
  md.use(scopePill);
  for (const tag of ['MVP', 'MVP-EXPANDED', 'CONDITIONAL', 'FUTURE']) {
    const html = md.render(`Scope: \`${tag}\` here`);
    const cls = `scope-${tag.toLowerCase()}`;
    assert.match(html, new RegExp(`<span class="scope-pill ${cls}">${tag}</span>`));
  }
});

test('scope_pill leaves unrelated inline code alone', () => {
  const md = new MdLib();
  md.use(scopePill);
  const html = md.render('Path: `Parts.Item`');
  assert.match(html, /<code>Parts\.Item<\/code>/);
  assert.doesNotMatch(html, /scope-pill/);
});
```

- [ ] **Step 2: Expect FAIL**

```bash
node --test tools/build_docs_portal.test.js
```

- [ ] **Step 3: Implement**

```javascript
const TAGS = new Set(['MVP', 'MVP-EXPANDED', 'CONDITIONAL', 'FUTURE']);

module.exports = function scopePill(md) {
  md.core.ruler.after('inline', 'scope_pill', (state) => {
    for (const blockTok of state.tokens) {
      if (blockTok.type !== 'inline' || !blockTok.children) continue;
      for (const t of blockTok.children) {
        if (t.type !== 'code_inline') continue;
        const content = t.content;
        if (!TAGS.has(content)) continue;
        t.type = 'html_inline';
        t.content = `<span class="scope-pill scope-${content.toLowerCase()}">${content}</span>`;
      }
    }
  });
};
```

- [ ] **Step 4: Wire + run tests**

In `tools/build_docs_portal.js`, after `anchor_fds_req`:

```javascript
md.use(require('./markdown_plugins/scope_pill'));
```

```bash
node --test tools/build_docs_portal.test.js
```

- [ ] **Step 5: Commit**

```bash
git add tools/markdown_plugins/scope_pill.js tools/build_docs_portal.js tools/build_docs_portal.test.js
git commit -m "feat(portal): scope_pill plugin — MVP/CONDITIONAL/etc. render as colored badges"
```

### Task 10: parse_dm_tables.js — pre-parse known Schema.TableName set

**Files:**
- Create: `tools/lib/parse_dm_tables.js`

- [ ] **Step 1: Add test**

```javascript
const { parseDmTables } = require('./lib/parse_dm_tables');

test('parseDmTables extracts Schema.TableName from Data Model headings', () => {
  const sample = `# Data Model
## 2. Location Schema
### Location
### LocationAttribute
## 3. Parts Schema
### OperationTemplate
### ContainerConfig
## 4. Lots Schema
### Lot
`;
  const map = parseDmTables(sample);
  assert.ok(map.has('Location.Location'));
  assert.ok(map.has('Parts.OperationTemplate'));
  assert.ok(map.has('Parts.ContainerConfig'));
  assert.ok(map.has('Lots.Lot'));
  assert.strictEqual(map.get('Parts.OperationTemplate'), 'parts-operationtemplate');
});
```

- [ ] **Step 2: Expect FAIL**

- [ ] **Step 3: Implement**

```javascript
const SCHEMAS = ['Location', 'Parts', 'Lots', 'Workorder', 'Quality', 'Oee', 'Tools', 'Audit'];

function parseDmTables(markdown) {
  const lines = markdown.split(/\r?\n/);
  const result = new Map();        // "Schema.Table" -> anchor slug
  let currentSchema = null;
  for (const line of lines) {
    const h2 = /^##\s+\d+\.\s+(\w+)\s+Schema/i.exec(line);
    if (h2) {
      const schema = SCHEMAS.find((s) => s.toLowerCase() === h2[1].toLowerCase());
      if (schema) currentSchema = schema;
      continue;
    }
    if (!currentSchema) continue;
    const h3 = /^###\s+([A-Za-z][A-Za-z0-9_]*)\s*$/.exec(line.replace(/<.+$/, '').trim());
    if (!h3) continue;
    const table = h3[1];
    const key = `${currentSchema}.${table}`;
    if (!result.has(key)) result.set(key, `${currentSchema.toLowerCase()}-${table.toLowerCase()}`);
  }
  return result;
}

module.exports = { parseDmTables, SCHEMAS };
```

- [ ] **Step 4: Run tests**

```bash
node --test tools/build_docs_portal.test.js
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add tools/lib/parse_dm_tables.js tools/build_docs_portal.test.js
git commit -m "feat(portal): parse_dm_tables — extracts Schema.TableName allowlist for cross-doc linking"
```

### Task 11: cross_doc_link plugin

**Files:**
- Create: `tools/markdown_plugins/cross_doc_link.js`

- [ ] **Step 1: Add test**

```javascript
const crossDocLink = require('./markdown_plugins/cross_doc_link');

test('cross_doc_link rewrites bare FDS-XX-NNN, OI-XX, UJ-XX, Schema.Table', () => {
  const md = new MdLib();
  md.use(crossDocLink, {
    currentDoc: 'fds',
    knownTables: new Map([['Parts.OperationTemplate', 'parts-operationtemplate']]),
  });
  let html = md.render('See FDS-05-009 and OI-35 and UJ-04.');
  assert.match(html, /<a[^>]*href="#fds-05-009"[^>]*>FDS-05-009<\/a>/);   // within-doc anchor on FDS
  assert.match(html, /<a[^>]*href="oir\.html#oi-35"[^>]*>OI-35<\/a>/);
  assert.match(html, /<a[^>]*href="oir\.html#uj-04"[^>]*>UJ-04<\/a>/);

  html = md.render('See Parts.OperationTemplate column.');
  assert.match(html, /<a[^>]*href="data-model\.html#parts-operationtemplate"[^>]*>Parts\.OperationTemplate<\/a>/);
});

test('cross_doc_link styles (FRS X.Y) as a tag, no link', () => {
  const md = new MdLib();
  md.use(crossDocLink, { currentDoc: 'fds', knownTables: new Map() });
  const html = md.render('(FRS 3.9.6)');
  assert.match(html, /<span class="frs-ref">\(FRS 3\.9\.6\)<\/span>/);
});

test('cross_doc_link skips text inside existing links and code', () => {
  const md = new MdLib();
  md.use(crossDocLink, { currentDoc: 'fds', knownTables: new Map() });
  const html = md.render('Code: `OI-35` and link: [OI-35](https://example.com)');
  // Inside code: untouched
  assert.match(html, /<code>OI-35<\/code>/);
  // Inside link: untouched
  assert.match(html, /<a href="https:\/\/example\.com">OI-35<\/a>/);
  // Should NOT have wrapped either with the cross-doc href
  assert.doesNotMatch(html, /<a[^>]*href="oir\.html#oi-35"[^>]*>OI-35<\/a><\/code>/);
});
```

- [ ] **Step 2: Expect FAIL**

- [ ] **Step 3: Implement**

```javascript
// Patterns are matched against text-token content only — never inside
// code_inline, links, raw HTML, or strong (so anchor_fds_req keeps priority).
const RE_FDS = /\bFDS-(\d{2})-(\d{3})\b/g;
const RE_OI = /\bOI-(\d{2})\b/g;
const RE_UJ = /\bUJ-(\d{2})\b/g;
const RE_FRS = /\(FRS [\d.]+\)/g;

function buildTableRe(knownTables) {
  if (!knownTables || knownTables.size === 0) return null;
  const keys = [...knownTables.keys()]
    .sort((a, b) => b.length - a.length)              // longest first
    .map((k) => k.replace(/\./g, '\\.'));
  return new RegExp(`\\b(${keys.join('|')})\\b`, 'g');
}

module.exports = function crossDocLink(md, opts = {}) {
  const currentDoc = opts.currentDoc || '';
  const knownTables = opts.knownTables || new Map();
  const tableRe = buildTableRe(knownTables);

  md.core.ruler.after('anchor_fds_req', 'cross_doc_link', (state) => {
    walkInline(state.tokens, (children) => {
      for (let i = 0; i < children.length; i++) {
        const tok = children[i];
        if (tok.type !== 'text') continue;
        const replaced = replaceText(tok.content, currentDoc, tableRe, knownTables);
        if (replaced === null) continue;
        const newToks = textToTokens(state, replaced);
        children.splice(i, 1, ...newToks);
        i += newToks.length - 1;
      }
    });
  });
};

function walkInline(tokens, visit) {
  for (const blockTok of tokens) {
    if (blockTok.type !== 'inline' || !blockTok.children) continue;
    visit(blockTok.children);
  }
}

function replaceText(text, currentDoc, tableRe, knownTables) {
  // If no pattern matches, signal no-op with null.
  if (!RE_FDS.test(text) && !RE_OI.test(text) && !RE_UJ.test(text) && !RE_FRS.test(text)
      && !(tableRe && tableRe.test(text))) {
    // reset lastIndex on the global regexes used in test()
    RE_FDS.lastIndex = RE_OI.lastIndex = RE_UJ.lastIndex = RE_FRS.lastIndex = 0;
    if (tableRe) tableRe.lastIndex = 0;
    return null;
  }
  RE_FDS.lastIndex = RE_OI.lastIndex = RE_UJ.lastIndex = RE_FRS.lastIndex = 0;
  if (tableRe) tableRe.lastIndex = 0;

  let out = escapeHtml(text);
  out = out.replace(RE_FDS, (m, a, b) => {
    const href = currentDoc === 'fds' ? `#fds-${a}-${b}` : `fds.html#fds-${a}-${b}`;
    return `<a class="xref" href="${href}">${m}</a>`;
  });
  out = out.replace(RE_OI, (m, n) => {
    const href = currentDoc === 'oir' ? `#oi-${n}` : `oir.html#oi-${n}`;
    return `<a class="xref" href="${href}">${m}</a>`;
  });
  out = out.replace(RE_UJ, (m, n) => {
    const href = currentDoc === 'oir' ? `#uj-${n}` : `oir.html#uj-${n}`;
    return `<a class="xref" href="${href}">${m}</a>`;
  });
  out = out.replace(RE_FRS, (m) => `<span class="frs-ref">${m}</span>`);
  if (tableRe) {
    out = out.replace(tableRe, (m) => {
      const anchor = knownTables.get(m);
      const href = currentDoc === 'data-model' ? `#${anchor}` : `data-model.html#${anchor}`;
      return `<a class="xref" href="${href}">${m}</a>`;
    });
  }
  return out;
}

function textToTokens(state, html) {
  const t = new state.Token('html_inline', '', 0);
  t.content = html;
  return [t];
}

function escapeHtml(s) {
  return String(s).replace(/[&<>"]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]));
}
```

- [ ] **Step 4: Wire into builder**

Edit `tools/build_docs_portal.js` so `buildMd` accepts options and uses them:

```javascript
const crossDocLink = require('./markdown_plugins/cross_doc_link');

function buildMd({ currentDoc, knownTables } = {}) {
  const md = new MarkdownIt({ html: true, linkify: false, typographer: false });
  md.use(markdownItAttrs);
  md.use(headingPermalinks);
  md.use(require('./markdown_plugins/anchor_fds_req'));
  md.use(require('./markdown_plugins/scope_pill'));
  md.use(crossDocLink, { currentDoc, knownTables: knownTables || new Map() });
  return md;
}
```

And in `build()`, before the doc loop, pre-parse the Data Model:

```javascript
const { parseDmTables } = require('./lib/parse_dm_tables');
// ... inside build():
const dmRaw = fs.readFileSync(path.join(REPO_ROOT, 'MPP_MES_DATA_MODEL.md'), 'utf8');
const knownTables = parseDmTables(dmRaw);
// ... per-doc:
const md = buildMd({ currentDoc: doc.key, knownTables });
```

- [ ] **Step 5: Run tests + regenerate**

```bash
node --test tools/build_docs_portal.test.js
node tools/build_docs_portal.js
```

Inspect `docs_portal/fds.html` — search for an `OI-` reference; it should be wrapped in an anchor pointing at `oir.html#oi-XX`.

- [ ] **Step 6: Commit**

```bash
git add tools/markdown_plugins/cross_doc_link.js tools/lib/parse_dm_tables.js tools/build_docs_portal.js tools/build_docs_portal.test.js
git commit -m "feat(portal): cross_doc_link plugin — auto-links FDS/OI/UJ/Schema.Table refs across docs"
```

### Task 12: parse_oir_map.js + oi_badge plugin

**Files:**
- Create: `tools/lib/parse_oir_map.js`
- Create: `tools/markdown_plugins/oi_badge.js`

- [ ] **Step 1: Add parse_oir_map test**

```javascript
const { parseOirMap } = require('./lib/parse_oir_map');

test('parseOirMap collects open OIs and maps requirements to them', () => {
  const sample = `# OIR
## OI-35 Architecture Decision Gate
**Status:** Open

Affects FDS-11-011 and FDS-05-009.

## OI-12 MaxParts relocation
**Status:** Resolved

Affects FDS-05-009.

## OI-32 Material allocation
**Status:** Open

Affects FDS-08-001.
`;
  const { openIds, reqToOpenOis } = parseOirMap(sample);
  assert.deepStrictEqual([...openIds].sort(), ['OI-32', 'OI-35']);
  assert.deepStrictEqual(reqToOpenOis.get('FDS-11-011').sort(), ['OI-35']);
  assert.deepStrictEqual(reqToOpenOis.get('FDS-05-009').sort(), ['OI-35']);  // OI-12 is Resolved, excluded
  assert.deepStrictEqual(reqToOpenOis.get('FDS-08-001').sort(), ['OI-32']);
});
```

- [ ] **Step 2: Expect FAIL**

- [ ] **Step 3: Implement parse_oir_map.js**

```javascript
const RE_HEADING = /^##\s+(OI-\d{2}|UJ-\d{2})\b/;
const RE_STATUS = /^\*\*Status:\*\*\s*(\w[\w-]*)/i;
const RE_FDS = /\bFDS-(\d{2})-(\d{3})\b/g;

function parseOirMap(markdown) {
  const lines = markdown.split(/\r?\n/);
  const items = [];                  // {id, status, body}
  let cur = null;
  for (const line of lines) {
    const h = RE_HEADING.exec(line);
    if (h) {
      if (cur) items.push(cur);
      cur = { id: h[1], status: '', body: '' };
      continue;
    }
    if (!cur) continue;
    if (!cur.status) {
      const s = RE_STATUS.exec(line);
      if (s) { cur.status = s[1]; continue; }
    }
    cur.body += line + '\n';
  }
  if (cur) items.push(cur);

  const openIds = new Set();
  const reqToOpenOis = new Map();
  for (const it of items) {
    if (!/^open$/i.test(it.status)) continue;
    openIds.add(it.id);
    let m;
    RE_FDS.lastIndex = 0;
    while ((m = RE_FDS.exec(it.body)) !== null) {
      const req = `FDS-${m[1]}-${m[2]}`;
      if (!reqToOpenOis.has(req)) reqToOpenOis.set(req, []);
      const arr = reqToOpenOis.get(req);
      if (!arr.includes(it.id)) arr.push(it.id);
    }
  }
  return { openIds, reqToOpenOis, items };
}

module.exports = { parseOirMap };
```

- [ ] **Step 4: Add oi_badge plugin test**

```javascript
const oiBadge = require('./markdown_plugins/oi_badge');

test('oi_badge appends 🔓 OI-XX after **FDS-XX-NNN** when in the open map', () => {
  const md = new MdLib();
  md.use(require('./markdown_plugins/anchor_fds_req'));
  md.use(oiBadge, { reqToOpenOis: new Map([['FDS-05-009', ['OI-35']]]) });
  const html = md.render('**FDS-05-009** SHALL …');
  assert.match(html, /<a[^>]*class="oi-badge"[^>]*href="oir\.html#oi-35"[^>]*>🔓 OI-35<\/a>/);
});

test('oi_badge does not badge requirements without open OIs', () => {
  const md = new MdLib();
  md.use(require('./markdown_plugins/anchor_fds_req'));
  md.use(oiBadge, { reqToOpenOis: new Map() });
  const html = md.render('**FDS-05-009** SHALL …');
  assert.doesNotMatch(html, /oi-badge/);
});
```

- [ ] **Step 5: Expect FAIL**

- [ ] **Step 6: Implement oi_badge.js**

```javascript
const RE_FDS = /^FDS-(\d{2})-(\d{3})$/;

module.exports = function oiBadge(md, opts = {}) {
  const map = opts.reqToOpenOis || new Map();
  md.core.ruler.after('anchor_fds_req', 'oi_badge', (state) => {
    for (const blockTok of state.tokens) {
      if (blockTok.type !== 'inline' || !blockTok.children) continue;
      const kids = blockTok.children;
      for (let i = 0; i < kids.length; i++) {
        const t = kids[i];
        if (t.type !== 'strong_open') continue;
        const text = kids[i + 1];
        const close = kids[i + 2];
        if (!text || text.type !== 'text' || !close || close.type !== 'strong_close') continue;
        const m = RE_FDS.exec(text.content.trim());
        if (!m) continue;
        const req = `FDS-${m[1]}-${m[2]}`;
        const ois = map.get(req);
        if (!ois || ois.length === 0) continue;
        // Insert badge token immediately AFTER the </strong> (and after any anchor close added by anchor_fds_req).
        const badgeHtml = ois.map((id) => {
          const n = id.replace(/^OI-/, '').toLowerCase();
          return `<a class="oi-badge" href="oir.html#oi-${n}">🔓 ${id}</a>`;
        }).join('');
        const badgeTok = new state.Token('html_inline', '', 0);
        badgeTok.content = badgeHtml;
        // Find insertion point: skip past strong_close + optional anchor close from anchor_fds_req
        let insertAt = i + 3;
        while (kids[insertAt] && kids[insertAt].type === 'html_inline' && /^<\/a>/.test(kids[insertAt].content)) {
          insertAt++;
        }
        kids.splice(insertAt, 0, badgeTok);
        i = insertAt;
      }
    }
  });
};
```

- [ ] **Step 7: Wire into builder**

Edit `tools/build_docs_portal.js`. Add OIR pre-parse + pass the map into `buildMd`:

```javascript
const { parseOirMap } = require('./lib/parse_oir_map');

// inside build(), BEFORE the doc loop:
const oirRaw = fs.readFileSync(path.join(REPO_ROOT, 'MPP_MES_Open_Issues_Register.md'), 'utf8');
const { reqToOpenOis } = parseOirMap(oirRaw);

// pass through:
const md = buildMd({ currentDoc: doc.key, knownTables, reqToOpenOis });
```

Update `buildMd`:

```javascript
function buildMd({ currentDoc, knownTables, reqToOpenOis } = {}) {
  const md = new MarkdownIt({ html: true, linkify: false, typographer: false });
  md.use(markdownItAttrs);
  md.use(headingPermalinks);
  md.use(require('./markdown_plugins/anchor_fds_req'));
  md.use(require('./markdown_plugins/scope_pill'));
  md.use(require('./markdown_plugins/oi_badge'), { reqToOpenOis: reqToOpenOis || new Map() });
  md.use(require('./markdown_plugins/cross_doc_link'), { currentDoc, knownTables: knownTables || new Map() });
  return md;
}
```

- [ ] **Step 8: Run tests + rebuild**

```bash
node --test tools/build_docs_portal.test.js
node tools/build_docs_portal.js
```

Open `docs_portal/fds.html`, find an FDS requirement that's named in an open OI (e.g., FDS-11-011 → OI-35). Confirm the inline badge appears.

- [ ] **Step 9: Commit**

```bash
git add tools/lib/parse_oir_map.js tools/markdown_plugins/oi_badge.js tools/build_docs_portal.js tools/build_docs_portal.test.js
git commit -m "feat(portal): oi_badge plugin + parse_oir_map — inline 🔓 badge on FDS reqs with open OIs"
```

### Task 13: schema_table_anchor plugin (Data Model only)

**Files:**
- Create: `tools/markdown_plugins/schema_table_anchor.js`

This plugin runs only on the Data Model render. It assigns the schema-prefixed slug (`parts-operationtemplate`) to the matching h3 (instead of the slugify default `operationtemplate`), so cross_doc_link's expected anchors resolve.

- [ ] **Step 1: Add test**

```javascript
const schemaTableAnchor = require('./markdown_plugins/schema_table_anchor');

test('schema_table_anchor rewrites h3 ids inside a Schema section', () => {
  const md = new MdLib();
  md.use(require('./markdown_plugins/heading_permalinks'));
  md.use(schemaTableAnchor, {
    knownTables: new Map([
      ['Parts.OperationTemplate', 'parts-operationtemplate'],
      ['Parts.ContainerConfig', 'parts-containerconfig'],
    ]),
  });
  const src = [
    '## 3. Parts Schema',
    '',
    '### OperationTemplate',
    '',
    'Some prose.',
    '',
    '### ContainerConfig',
    '',
    'More prose.',
  ].join('\n');
  const html = md.render(src);
  assert.match(html, /<h3[^>]*id="parts-operationtemplate"/);
  assert.match(html, /<h3[^>]*id="parts-containerconfig"/);
});
```

- [ ] **Step 2: Expect FAIL**

- [ ] **Step 3: Implement**

```javascript
const { SCHEMAS } = require('../lib/parse_dm_tables');

module.exports = function schemaTableAnchor(md, opts = {}) {
  const knownTables = opts.knownTables || new Map();

  md.core.ruler.after('heading_permalinks', 'schema_table_anchor', (state) => {
    let currentSchema = null;
    for (let i = 0; i < state.tokens.length; i++) {
      const tok = state.tokens[i];
      if (tok.type !== 'heading_open') continue;
      const inline = state.tokens[i + 1];
      if (!inline || inline.type !== 'inline') continue;
      const text = inline.content.replace(/<[^>]+>/g, '').trim();

      if (tok.tag === 'h2') {
        const m = /^\d+\.\s+(\w+)\s+Schema/i.exec(text);
        if (m) {
          const schema = SCHEMAS.find((s) => s.toLowerCase() === m[1].toLowerCase());
          currentSchema = schema || null;
        } else if (/^[\d.]+\s/.test(text)) {
          currentSchema = null;          // numbered non-schema section
        }
        continue;
      }
      if (tok.tag !== 'h3' || !currentSchema) continue;

      const tableName = (text.match(/^([A-Za-z][A-Za-z0-9_]*)/) || [])[1];
      if (!tableName) continue;
      const key = `${currentSchema}.${tableName}`;
      const slug = knownTables.get(key);
      if (!slug) continue;
      tok.attrSet('id', slug);

      // Also re-point the permalink anchor (added by heading_permalinks) to the new slug.
      if (inline.children) {
        const last = inline.children[inline.children.length - 1];
        if (last && last.type === 'html_inline' && /class="heading-permalink"/.test(last.content)) {
          last.content = last.content.replace(/href="#[^"]+"/, `href="#${slug}"`);
        }
      }
    }
  });
};
```

- [ ] **Step 4: Wire — only on Data Model**

Edit `tools/build_docs_portal.js`. Add a `plugins` opt to `buildMd`:

```javascript
function buildMd({ currentDoc, knownTables, reqToOpenOis } = {}) {
  const md = new MarkdownIt({ html: true, linkify: false, typographer: false });
  md.use(markdownItAttrs);
  md.use(headingPermalinks);
  if (currentDoc === 'data-model') {
    md.use(require('./markdown_plugins/schema_table_anchor'), { knownTables: knownTables || new Map() });
  }
  md.use(require('./markdown_plugins/anchor_fds_req'));
  md.use(require('./markdown_plugins/scope_pill'));
  md.use(require('./markdown_plugins/oi_badge'), { reqToOpenOis: reqToOpenOis || new Map() });
  md.use(require('./markdown_plugins/cross_doc_link'), { currentDoc, knownTables: knownTables || new Map() });
  return md;
}
```

- [ ] **Step 5: Run tests**

```bash
node --test tools/build_docs_portal.test.js
```

- [ ] **Step 6: Commit**

```bash
git add tools/markdown_plugins/schema_table_anchor.js tools/build_docs_portal.js tools/build_docs_portal.test.js
git commit -m "feat(portal): schema_table_anchor plugin — DM table h3s get Schema-prefixed slugs"
```

---

## Phase 5 — Emit remaining docs

### Task 14: Add data-model.html, oir.html, erd.html to DOCS list

**Files:**
- Modify: `tools/build_docs_portal.js`

- [ ] **Step 1: Add test**

```javascript
test('build emits all four target HTMLs', () => {
  execSync('node tools/build_docs_portal.js', { cwd: REPO_ROOT, stdio: 'pipe' });
  for (const name of ['fds.html', 'data-model.html', 'oir.html', 'erd.html', 'index.html']) {
    assert.ok(fs.existsSync(path.join(PORTAL_DIR, name)), `${name} should exist`);
  }
});

test('erd.html iframes the standalone ERD file', () => {
  const html = fs.readFileSync(path.join(PORTAL_DIR, 'erd.html'), 'utf8');
  assert.match(html, /<iframe[^>]+src="\.\.\/MPP_MES_ERD\.html"/);
  assert.match(html, /erd-fullscreen-link/);
});

test('index.html redirects to fds.html', () => {
  const html = fs.readFileSync(path.join(PORTAL_DIR, 'index.html'), 'utf8');
  assert.match(html, /<meta http-equiv="refresh" content="0;\s*url=fds\.html"/i);
});

test('data-model.html contains schema-prefixed anchors', () => {
  const html = fs.readFileSync(path.join(PORTAL_DIR, 'data-model.html'), 'utf8');
  assert.match(html, /id="parts-operationtemplate"/);
  assert.match(html, /id="lots-shippinglabel"/);
});
```

- [ ] **Step 2: Expect FAIL (only fds.html exists after Task 13)**

- [ ] **Step 3: Modify build_docs_portal.js**

Replace the `DOCS` const and `build()` body. Final state:

```javascript
const DOCS = [
  { key: 'fds', source: 'MPP_MES_FDS.md', out: 'fds.html', title: 'FDS' },
  { key: 'data-model', source: 'MPP_MES_DATA_MODEL.md', out: 'data-model.html', title: 'Data Model' },
  { key: 'oir', source: 'MPP_MES_Open_Issues_Register.md', out: 'oir.html', title: 'Open Issues Register' },
];

function build() {
  rmrf(PORTAL_DIR);
  fs.mkdirSync(PORTAL_DIR, { recursive: true });

  const generatedAt = new Date().toISOString();
  const dmRaw = fs.readFileSync(path.join(REPO_ROOT, 'MPP_MES_DATA_MODEL.md'), 'utf8');
  const knownTables = parseDmTables(dmRaw);
  const oirRaw = fs.readFileSync(path.join(REPO_ROOT, 'MPP_MES_Open_Issues_Register.md'), 'utf8');
  const { reqToOpenOis } = parseOirMap(oirRaw);

  for (const doc of DOCS) {
    const src = path.join(REPO_ROOT, doc.source);
    const raw = fs.readFileSync(src, 'utf8');
    const md = buildMd({ currentDoc: doc.key, knownTables, reqToOpenOis });
    const contentHtml = md.render(raw);
    const tocHtml = buildToc(contentHtml);
    const html = renderShell({
      activeDoc: doc.key,
      title: doc.title,
      contentHtml,
      tocHtml,
      sourcePath: doc.source,
      generatedAt,
    });
    fs.writeFileSync(path.join(PORTAL_DIR, doc.out), html, 'utf8');
  }

  // erd.html — iframe wrapper
  const erdHtml = renderShell({
    activeDoc: 'erd',
    title: 'ERD',
    contentHtml: `
      <a class="erd-fullscreen-link" href="../MPP_MES_ERD.html" target="_blank" rel="noopener">Open ERD full screen ↗</a>
      <iframe class="erd-frame" src="../MPP_MES_ERD.html" title="MPP MES ERD"></iframe>
    `,
    tocHtml: '<ul><li><em>Pan + zoom inside the ERD.</em></li></ul>',
    sourcePath: 'MPP_MES_ERD.html',
    generatedAt,
  });
  fs.writeFileSync(path.join(PORTAL_DIR, 'erd.html'), erdHtml, 'utf8');

  // index.html — meta-refresh to fds.html
  fs.writeFileSync(
    path.join(PORTAL_DIR, 'index.html'),
    `<!DOCTYPE html><html><head><meta charset="UTF-8"><meta http-equiv="refresh" content="0; url=fds.html"></head><body><a href="fds.html">Open FDS</a></body></html>`,
    'utf8'
  );

  copyDir(ASSETS_SRC, ASSETS_DEST);

  console.log(`Built ${DOCS.length + 1} pages → ${PORTAL_DIR}`);
}
```

- [ ] **Step 4: Run tests**

```bash
node --test tools/build_docs_portal.test.js
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add tools/build_docs_portal.js tools/build_docs_portal.test.js
git commit -m "feat(portal): emit data-model.html + oir.html + erd.html + index.html"
```

---

## Phase 6 — Search index + vendor minisearch

### Task 15: build_search_index.js + vendor minisearch.min.js

**Files:**
- Create: `tools/lib/build_search_index.js`
- Modify: `tools/build_docs_portal.js`

- [ ] **Step 1: Add tests**

```javascript
const { buildSearchIndex } = require('./lib/build_search_index');

test('buildSearchIndex extracts section-level entries with doc + scope + body', () => {
  const renderedDocs = [
    {
      key: 'fds',
      title: 'FDS',
      html: '<h2 id="s1">Section One <span class="scope-pill scope-mvp">MVP</span></h2><p>Body of section one mentioning <a id="fds-05-009">FDS-05-009</a>.</p><h2 id="s2">Section Two</h2><p>Stuff.</p>',
    },
  ];
  const { docs } = buildSearchIndex(renderedDocs);
  assert.strictEqual(docs.length, 2);
  const first = docs.find((d) => d.id === 'fds.html#s1');
  assert.strictEqual(first.doc, 'fds');
  assert.strictEqual(first.title, 'Section One');
  assert.strictEqual(first.scope, 'MVP');
  assert.match(first.body, /Body of section one/);
  assert.strictEqual(first.requirementId, 'FDS-05-009');
});

test('build_docs_portal emits search-index.json with >= 200 entries', () => {
  execSync('node tools/build_docs_portal.js', { cwd: REPO_ROOT, stdio: 'pipe' });
  const raw = JSON.parse(fs.readFileSync(path.join(PORTAL_DIR, 'search-index.json'), 'utf8'));
  assert.ok(raw.docs.length >= 200, `expected >=200 entries, got ${raw.docs.length}`);
  assert.ok(raw.index, 'serialized MiniSearch index present');
  assert.ok(raw.options, 'MiniSearch options present');
});

test('build_docs_portal copies minisearch.min.js into assets', () => {
  assert.ok(fs.existsSync(path.join(PORTAL_DIR, 'assets', 'minisearch.min.js')));
});
```

- [ ] **Step 2: Expect FAIL**

- [ ] **Step 3: Implement build_search_index.js**

```javascript
const MiniSearch = require('minisearch');

const HEADING_RE = /<h([23])\s+id="([^"]+)"[^>]*>([\s\S]*?)<\/h\1>/g;
const FDS_RE = /<a[^>]+id="(fds-\d{2}-\d{3})"/;
const SCOPE_RE = /<span class="scope-pill scope-([a-z-]+)"/;

function buildSearchIndex(renderedDocs) {
  const docs = [];
  for (const d of renderedDocs) {
    HEADING_RE.lastIndex = 0;
    const sections = [];
    let m;
    while ((m = HEADING_RE.exec(d.html)) !== null) {
      sections.push({ level: Number(m[1]), id: m[2], titleHtml: m[3], offset: m.index });
    }
    for (let i = 0; i < sections.length; i++) {
      const s = sections[i];
      const nextOffset = i + 1 < sections.length ? sections[i + 1].offset : d.html.length;
      const slice = d.html.slice(s.offset, nextOffset);
      const titleText = s.titleHtml.replace(/<[^>]+>/g, '').replace(/\s+/g, ' ').trim();
      const bodyText = slice.replace(/<[^>]+>/g, ' ').replace(/&nbsp;/g, ' ').replace(/\s+/g, ' ').trim();
      const scopeMatch = SCOPE_RE.exec(s.titleHtml);
      const fdsMatch = FDS_RE.exec(slice);
      docs.push({
        id: `${d.key}.html#${s.id}`,
        doc: d.key,
        title: titleText,
        requirementId: fdsMatch ? fdsMatch[1].toUpperCase() : '',
        scope: scopeMatch ? scopeMatch[1].toUpperCase().replace(/-/g, '-') : '',
        body: bodyText.slice(0, 2000),
      });
    }
  }

  const ms = new MiniSearch({
    fields: ['title', 'requirementId', 'body'],
    storeFields: ['id', 'doc', 'title', 'requirementId', 'scope'],
    searchOptions: {
      boost: { title: 5, requirementId: 8 },
      prefix: true,
      fuzzy: 0.15,
    },
  });
  ms.addAll(docs);

  return {
    docs,
    payload: {
      docs,
      index: JSON.parse(JSON.stringify(ms.toJSON())),
      options: {
        fields: ['title', 'requirementId', 'body'],
        storeFields: ['id', 'doc', 'title', 'requirementId', 'scope'],
      },
    },
  };
}

module.exports = { buildSearchIndex };
```

- [ ] **Step 4: Wire into builder**

Edit `tools/build_docs_portal.js`. Track rendered HTMLs and emit the index:

```javascript
const { buildSearchIndex } = require('./lib/build_search_index');

// inside build(), accumulate rendered docs:
const renderedDocs = [];
for (const doc of DOCS) {
  // ... existing render ...
  renderedDocs.push({ key: doc.key, title: doc.title, html: contentHtml });
}

// After the loop, before copyDir:
const { payload } = buildSearchIndex(renderedDocs);
fs.writeFileSync(
  path.join(PORTAL_DIR, 'search-index.json'),
  JSON.stringify(payload),
  'utf8'
);

// Vendor minisearch into assets
const miniSearchSrc = path.join(REPO_ROOT, 'node_modules', 'minisearch', 'dist', 'umd', 'index.min.js');
fs.mkdirSync(ASSETS_DEST, { recursive: true });
fs.copyFileSync(miniSearchSrc, path.join(ASSETS_DEST, 'minisearch.min.js'));
```

Note on the MiniSearch UMD path: confirm with `ls node_modules/minisearch/dist/`. If the layout differs (newer versions ship `umd/index.js` only), point at the actual minified UMD file. Fall back: `node_modules/minisearch/dist/umd/index.js` is acceptable — rename on copy.

- [ ] **Step 5: Run tests + rebuild**

```bash
ls node_modules/minisearch/dist/
node tools/build_docs_portal.js
node --test tools/build_docs_portal.test.js
```

Expected: PASS. Open `docs_portal/fds.html`, hit 🔍, type "QualitySpec" — results should appear with doc badges and snippets.

- [ ] **Step 6: Commit**

```bash
git add tools/lib/build_search_index.js tools/build_docs_portal.js tools/build_docs_portal.test.js
git commit -m "feat(portal): MiniSearch cross-doc index + vendored client lib"
```

---

## Phase 7 — Smoke tests + anchor resolution

### Task 16: end-to-end anchor + OI-badge smoke tests

**Files:**
- Modify: `tools/build_docs_portal.test.js`

- [ ] **Step 1: Add smoke tests**

```javascript
test('end-to-end: key anchors resolve in generated HTML', () => {
  execSync('node tools/build_docs_portal.js', { cwd: REPO_ROOT, stdio: 'pipe' });
  const fds = fs.readFileSync(path.join(PORTAL_DIR, 'fds.html'), 'utf8');
  const dm = fs.readFileSync(path.join(PORTAL_DIR, 'data-model.html'), 'utf8');
  const oir = fs.readFileSync(path.join(PORTAL_DIR, 'oir.html'), 'utf8');

  // Known requirement that exists in v1.0 FDS
  assert.match(fds, /id="fds-05-009"/);
  // Schema-prefixed DM anchors
  assert.match(dm, /id="parts-operationtemplate"/);
  assert.match(dm, /id="lots-shippinglabel"/);
  // OI anchors
  assert.match(oir, /id="oi-35"/);
});

test('OI badge appears on at least one FDS requirement', () => {
  const fds = fs.readFileSync(path.join(PORTAL_DIR, 'fds.html'), 'utf8');
  assert.match(fds, /class="oi-badge"/, 'expected at least one inline OI badge on FDS page');
});

test('search-index.json size budget < 500 KB uncompressed', () => {
  const stat = fs.statSync(path.join(PORTAL_DIR, 'search-index.json'));
  assert.ok(stat.size < 500 * 1024, `search-index.json grew to ${stat.size} bytes`);
});
```

- [ ] **Step 2: Run tests**

```bash
node --test tools/build_docs_portal.test.js
```

Expected: PASS. If `class="oi-badge"` doesn't match, the OIR parse map didn't find any open OIs naming an FDS requirement — check OIR v2.17 still has at least one open item referencing an FDS-XX-NNN (OI-35 does, referencing FDS-11-011 / FDS-11 retention work).

If `id="lots-shippinglabel"` doesn't match: the slugify rule produces `lots-shippinglabel` (no separator between `Shipping` and `Label`); confirm `parseDmTables` keyed on `Lots.ShippingLabel` → `lots-shippinglabel`. Both sides agree because both call `lowercase + concat` on the part after the dot.

- [ ] **Step 3: Commit**

```bash
git add tools/build_docs_portal.test.js
git commit -m "test(portal): end-to-end anchor + OI-badge + search-index size smoke tests"
```

---

## Phase 8 — Final build + visual spot-check + commit output

### Task 17: Final regenerate + commit docs_portal/

**Files:**
- Generated: `docs_portal/**`

- [ ] **Step 1: Full regenerate**

```bash
node tools/build_docs_portal.js
```

Expected stdout: `Built 4 pages → .../docs_portal`.

- [ ] **Step 2: Run all tests one more time**

```bash
node --test tools/build_docs_portal.test.js
```

Expected: ALL PASS.

- [ ] **Step 3: Manual visual spot-check (open in browser)**

Open `docs_portal/index.html` from disk. Check, in order:

1. Lands on FDS page with shell chrome.
2. Sidebar TOC populated; clicking an item jumps to that section.
3. Scrolling highlights the active section in the TOC.
4. At least one h2/h3 shows the `#` permalink chip on hover; clicking copies to clipboard.
5. At least one `MVP` / `CONDITIONAL` / `FUTURE` scope pill is rendered as a colored badge (not as inline code).
6. At least one FDS-XX-NNN occurrence outside the requirement's defining line is a clickable cross-link to itself (or to `fds.html` when on another page).
7. At least one `OI-XX` reference becomes a link to `oir.html#oi-XX`. Navigate to a different doc, check the link goes to OIR.
8. At least one `Parts.Tablename` reference becomes a link into the Data Model page.
9. At least one FDS requirement shows the inline 🔓 OI-XX badge.
10. Click ERD tab → ERD renders in iframe. Click "Open ERD full screen" — standalone tab opens.
11. Click 🔍 in header → modal opens. Type "QualitySpec" → results appear with doc badges, scope pills, snippets with highlighted terms. Click a result → jumps to anchor.
12. Press `/` from any non-input element → search modal opens. Press Esc → closes.

If any of the above fail, fix and re-run `node tools/build_docs_portal.js` before committing.

- [ ] **Step 4: Verify gitignore doesn't accidentally exclude output**

```bash
git status docs_portal/
```

Expected: untracked files listed. Nothing under `docs_portal/` should be ignored.

- [ ] **Step 5: Commit the generator output**

```bash
git add docs_portal/
git commit -m "docs(portal): generate initial docs_portal/ build (FDS v1.0 + DM v1.9m + OIR v2.17)"
```

- [ ] **Step 6: Update PROJECT_STATUS.md "On deck" → "Landed"**

Edit `PROJECT_STATUS.md`:

- Remove the "Internal Docs Portal — design approved, awaiting plan + build" subsection from "Outstanding for Next Session".
- Add a new "2026-05-12 — Internal Docs Portal landed" entry at the top of "Recent Change Narrative" summarising: 4 docs (FDS + DM + OIR + ERD), MiniSearch cross-doc index, 6 markdown plugins, generator at `tools/build_docs_portal.js`, output at `docs_portal/`.

```bash
git add PROJECT_STATUS.md
git commit -m "docs(status): mark docs portal v1 landed"
```

---

## Self-Review

**Spec coverage:**

| Spec section | Covered by |
|---|---|
| §2 v1 scope: FDS + DM + OIR + ERD | Tasks 3, 14 |
| §4 architecture (file layout) | Task 14 |
| §5 shared shell (header + sidebar + theme) | Tasks 2, 4, 5 |
| §6.1 anchor-fds-req | Task 8 |
| §6.2 scope-pill | Task 9 |
| §6.3 cross-doc-link | Task 11 |
| §6.4 oi-badge | Task 12 |
| §6.5 schema-table-anchor | Task 13 |
| §6.6 heading-permalinks | Task 7 |
| §7 MiniSearch index + UI | Tasks 6, 15 |
| §8 ERD iframe | Task 14 |
| §9 generator pipeline (OIR-first parse) | Tasks 11, 12, 14 |
| §10 testing | Tasks 5–16 (TDD throughout) + Task 16 smoke tests |
| §11 repo layout | File Structure section |
| §12 git hygiene (commit docs_portal/) | Task 17 |
| §13 dependencies | Task 1 |
| §14 risks (cross-doc false positives) | Task 11 mitigated via `knownTables` allowlist |
| §15 resumption checklist | This plan IS the output of step 3 |

No gaps.

**Placeholder scan:** No "TBD", "implement later", or "add error handling" steps. Every code step shows the actual code.

**Type/name consistency:**
- `renderShell({ activeDoc, title, contentHtml, tocHtml, sourcePath, generatedAt })` — consistent in Tasks 2, 14.
- `buildMd({ currentDoc, knownTables, reqToOpenOis })` — consistent in Tasks 7, 11, 12, 13, 14.
- `buildSearchIndex(renderedDocs)` returns `{ docs, payload }` — consistent in Task 15.
- Plugin filenames use snake_case throughout (spec used kebab-case in §11; this plan locks snake_case in the File Structure section).
- `parseDmTables` returns `Map<string, string>` ("Schema.Table" → slug); `parseOirMap` returns `{ openIds, reqToOpenOis, items }` — both signatures used consistently.

---

**Plan complete and saved to `docs/superpowers/plans/2026-05-12-docs-portal.md`. Two execution options:**

**1. Subagent-Driven (recommended)** — fresh subagent per task, review between tasks, fast iteration.

**2. Inline Execution** — execute tasks in this session using executing-plans, batch execution with checkpoints.
