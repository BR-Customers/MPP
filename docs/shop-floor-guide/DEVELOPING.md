# Developing the MES Configuration Guide — Handoff

A short guide to extending the customer-facing **MES Configuration Tool Guide**
(`MPP_MES_Configuration_Guide.html`). No special tooling required — a text editor, a
browser, PowerShell, and git.

---

## 1. How it fits together

You edit **one source file** and run **one build script**. The build inlines the
screenshots so the final deliverable is a single portable `.html` with no external files.

```
docs/config-guide/
├─ config-guide.src.html   ← EDIT THIS (text + structure; references shots/ by path)
├─ shots/                  ← screenshots, one per screen/state  (NN_name.png)
├─ build.ps1              ← inlines shots/ into the deliverable
├─ MPP_MES_Configuration_Guide.html  ← GENERATED deliverable (hand this to the customer)
└─ README.md              ← file map + conventions
```

- **Never hand-edit** `MPP_MES_Configuration_Guide.html` — it's generated and gets overwritten.
- Everything lives in one HTML file (`config-guide.src.html`): the `<style>` block at the top,
  the content, and a small `<script>` at the bottom for the sidebar scroll-spy. There's no
  framework, no build toolchain beyond the one PowerShell script.

---

## 2. The edit → preview → build loop

1. **Edit** `config-guide.src.html` in any text editor (VS Code recommended).
2. **Preview** by opening `config-guide.src.html` directly in a browser (double-click it).
   Screenshots load from `shots/`, so what you see is accurate.
3. **Build** the deliverable when you're happy:
   ```powershell
   cd docs/config-guide
   powershell -ExecutionPolicy Bypass -File .\build.ps1
   ```
   This regenerates `MPP_MES_Configuration_Guide.html`. Open it to sanity-check that the
   screenshots inlined (the script prints `Un-inlined shots/ refs remaining: 0`).

> **UTF-8 warning.** The source contains real em-dashes (`—`) and a couple of HTML entities.
> Keep your editor saving as **UTF-8** (VS Code default). If you ever script bulk edits in
> PowerShell, use `[IO.File]::ReadAllText/WriteAllText` — **not** `Get-Content`/`Set-Content`,
> which default to ANSI on Windows PowerShell 5.1 and will corrupt the dashes.

---

## 3. Adding a new screen (copy-paste skeleton)

Each screen is one `<section>`. Paste this where it belongs (screens are grouped by app
category: Plant, Parts, Quality, Operations, System), fill it in, and add a matching link to
the sidebar (step 4 below).

```html
<hr class="div">

<!-- ============ YOUR SCREEN ============ -->
<section id="your-screen-id">
  <span class="eyebrow">Category</span>          <!-- Plant / Parts / Quality / Operations / System -->
  <h2>Screen Name</h2>
  <p class="lead">One or two sentences: what this screen is and why it exists.</p>

  <!-- What / When / Why summary -->
  <div class="www">
    <div><h4>What</h4><p>What it configures.</p></div>
    <div><h4>When</h4><p>When you'd touch it.</p></div>
    <div><h4>Why</h4><p>Why it matters downstream.</p></div>
  </div>

  <!-- A screenshot, framed like an app window -->
  <figure class="shot">
    <div class="frame">
      <div class="frame-bar"><span class="dots"><i></i><i></i><i></i></span>
        <span class="path">Category <b>&rsaquo;</b> Screen Name</span></div>
      <img src="shots/23_your_screen.png" alt="Describe what the screenshot shows, for accessibility.">
    </div>
    <figcaption>Caption pointing out the important controls.</figcaption>
  </figure>

  <!-- Numbered how-to -->
  <h3>How to configure</h3>
  <ol class="steps">
    <li>First step. Use <code>Button Label</code> for UI buttons and <code>FieldName</code> for fields.</li>
    <li>Second step.</li>
  </ol>
</section>
```

### Reusable pieces (already styled — just use the class)

| You want… | Markup |
|---|---|
| Field reference table | `<div class="tbl-scroll"><table class="fields"><thead><tr><th>Field</th><th>What it does</th></tr></thead><tbody><tr><td>Name</td><td>…</td></tr></tbody></table></div>` |
| Info callout | `<div class="note"><span class="ic">i</span><div>…</div></div>` |
| Warning callout | `<div class="note warn"><span class="ic">!</span><div>…</div></div>` |
| Lifecycle chips | `<span class="chip chip-draft">Draft</span>` · `chip-pub` (Published) · `chip-dep` (Deprecated) |
| Inline code / path | `<code>Save</code>` (buttons/fields) or `<span class="mono">/some/path</span>` (paths, IDs) |
| Section divider | `<hr class="div">` between sections |

### 4. Add it to the sidebar

Find the `<nav class="toc">` near the top and add a link under the right category group:

```html
<div class="toc-grp">Category</div>
<a href="#your-screen-id">Screen Name</a>
```

The `href` must match the section's `id`. The active-link highlight is automatic.

---

## 4. Screenshots

- **Capture:** open the app (`http://localhost:8088/data/perspective/client/MPP_Config`),
  maximize the browser, navigate to the screen/state you want. Use the Windows Snipping Tool
  (`Win`+`Shift`+`S`), rectangular region. **Start just below the browser toolbar** (at the
  app's own top bar, the cyan **MPP** logo) and grab the **full app width** down to the bottom
  of the content. Don't include browser tabs, the address bar, or bookmarks.
- **Save** as PNG into `shots/` with the next number and a descriptive name:
  `shots/23_your_screen.png`. (The numbers are just for ordering/readability.)
- **Sizing doesn't need to be exact** — the guide scales every image to the content width. The
  existing shots are ~1900 px wide, full app content, no browser chrome; match that framing so
  the guide stays visually consistent.
- Reference it with `<img src="shots/23_your_screen.png" alt="…">` and always write a real
  `alt` + `<figcaption>`.

---

## 5. Styling / theming (don't fight it)

- Colors come from **CSS custom properties** defined at the top of the file (`--accent`,
  `--ink`, `--surface`, etc.). Use the existing classes; **don't hardcode hex colors** in new
  markup, or light/dark theme will break.
- The page supports **light and dark**. If you add new CSS, define the color as a token and set
  it in all three places (`@media (prefers-color-scheme: dark)`, `:root[data-theme="light"]`,
  `:root[data-theme="dark"]`) — copy how an existing token is done.
- Keep the browser-tab title (`<title>`) and don't rename the deliverable file — downstream
  links point at `MPP_MES_Configuration_Guide.html`.

---

## 6. Git

1. Branch off `main` (or use `jacques/working`):
   ```powershell
   git checkout -b docs/config-guide-<what> main
   ```
2. Make your edits, add screenshots, then **run `build.ps1`** so the deliverable is current.
3. Commit the source, the new screenshots, **and** the rebuilt deliverable together, staging
   explicit paths:
   ```powershell
   git add docs/config-guide/config-guide.src.html docs/config-guide/shots docs/config-guide/MPP_MES_Configuration_Guide.html
   git commit -m "docs(config-guide): <what you added>"
   ```
   > Stage explicit paths (not `git add -A`) — this repo often has unrelated in-progress work in
   > the tree.
4. Push and open a PR / merge as usual.

---

## 7. What's left to do (roadmap)

- **PLC Devices** — currently a placeholder note in the *System* section (its UI styling was
  still in progress). Capture it and write the section once the screen is finalized.
- **Item Master** — updates are coming from Jacques; fold them into that section.
- **Before customer release:** remove the `Draft v0.1` tag in the masthead meta and the
  dev-environment / sample-data caveat in the footer, and re-check the
  “**N** configuration screens” count in the masthead.

---

*Questions on how a particular pattern was built? Every existing section is a working example —
copy the closest one and adapt.*
