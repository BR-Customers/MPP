# Developing the MES Shop Floor Guide — Handoff

A short guide to extending the customer-facing **MES Shop Floor Guide**
(`MPP_MES_ShopFloor_Guide.html`). No special tooling required — a text editor, a browser,
PowerShell, and git.

---

## 1. How it fits together

You edit **one source file** (plus a stylesheet) and run **one build script**. The build
inlines the stylesheet and the screenshots so the final deliverable is a single portable
`.html` with no external files.

```
docs/shop-floor-guide/
├─ shopfloor-guide.src.html  ← EDIT THIS (text + structure; links styles.css, references shots/)
├─ styles.css                ← EDIT THIS for styling (inlined at build time)
├─ shots/                    ← screenshots, one per screen/state  (NN_name.png)
├─ build.ps1                 ← inlines styles.css + shots/ into the deliverable
├─ MPP_MES_ShopFloor_Guide.html  ← GENERATED deliverable (hand this to the customer)
└─ README.md                 ← file map + conventions
```

- **Never hand-edit** `MPP_MES_ShopFloor_Guide.html` — it's generated and gets overwritten.
- This differs from the sibling **config guide**, which keeps its CSS in a `<style>` block
  inside its source file. Here the CSS lives in `styles.css` and `build.ps1` folds it in.
- There's no framework and no build toolchain beyond the one PowerShell script. The only
  JavaScript is a small `<script>` at the bottom of the source that drives the sidebar
  scroll-spy.

---

## 2. The edit → preview → build loop

1. **Edit** `shopfloor-guide.src.html` (and `styles.css` if you need new styling).
2. **Preview** by opening `shopfloor-guide.src.html` directly in a browser (double-click it).
   The stylesheet and screenshots load from disk, so what you see is accurate.
3. **Build** the deliverable when you're happy:
   ```powershell
   cd docs/shop-floor-guide
   powershell -ExecutionPolicy Bypass -File .\build.ps1
   ```
   This regenerates `MPP_MES_ShopFloor_Guide.html`. The script prints
   `Un-inlined shots/ refs remaining: 0` and `External stylesheet refs remaining: 0` when the
   deliverable is genuinely self-contained — if either is non-zero, it warns.

> **UTF-8 warning.** The source contains real em-dashes (`—`), en-dashes, and middle dots.
> Keep your editor saving as **UTF-8 without a BOM** (VS Code default). If you script bulk
> edits in PowerShell, use `[IO.File]::ReadAllText/WriteAllText` — **not**
> `Get-Content`/`Set-Content`, which default to ANSI on Windows PowerShell 5.1 and will
> corrupt the dashes. A BOM at the top of the source also breaks the build.

---

## 3. Adding a new screen (copy-paste skeleton)

Each screen is one `<section>`. Paste it where it belongs, fill it in, and add a matching
link to the sidebar (step 4 below).

```html
<!-- ============ YOUR SCREEN ============ -->
<section id="your-screen-id">
  <h2>Screen Name</h2>
  <p class="lead">One or two sentences: what this screen is and when an operator uses it.</p>

  <!-- A screenshot, framed like an app window -->
  <figure class="shot">
    <div class="frame">
      <div class="frame-bar"><span class="dots"><i></i><i></i><i></i></span>
        <span class="path">Screen Name</span></div>
      <img src="shots/17_your_screen.png" alt="Describe what the screenshot shows, for accessibility.">
    </div>
    <figcaption>Caption pointing out the important controls.</figcaption>
  </figure>

  <!-- Numbered how-to -->
  <ol class="steps">
    <li>First step. Use <code>Button Label</code> for buttons and <b>Field Name</b> for fields.</li>
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
| Numbered concept cards | `<div class="cards"><div class="card"><h4><span class="k">1</span>Title</h4><p>…</p></div></div>` |
| Plain concept cards | same, with `<h4>Title</h4>` and no `<span class="k">` |
| Lifecycle chips | `<span class="chip chip-draft">Draft</span>` · `chip-pub` (Published) · `chip-dep` (Deprecated) |
| Inline code / path | `<code>Save</code>` (buttons) or `<span class="mono">/some/path</span>` (paths, IDs) |

### 4. Add it to the sidebar

Find the `<nav class="toc">` near the top and add a link under the right group
(*Start here* / *Screens* / *Elevated Access* / *Miscellaneous*):

```html
<div class="toc-grp">Screens</div>
<a href="#your-screen-id">Screen Name</a>
```

The `href` must match the section's `id`. The active-link highlight is automatic.

---

## 4. Screenshots

- **Capture:** open the app (`http://localhost:8088/data/perspective/client/MPP`), maximize the
  browser, and navigate to the screen/state you want. Use the Windows Snipping Tool
  (`Win`+`Shift`+`S`), rectangular region. **Start just below the browser toolbar** (at the
  app's own header band) and grab the **full app width** down to the bottom of the content.
  Don't include browser tabs, the address bar, or bookmarks.
- **Set the terminal first.** Most shop-floor screens only render meaningfully when the session
  is pointed at a terminal of the right kind. A terminal whose station subtitle reads
  *"Madison Facility"* is the unregistered-IP fallback and will show plant-wide queues — not
  what you want in a screenshot.
- **Save** as PNG into `shots/` with the next number and a descriptive name:
  `shots/17_your_screen.png`. (The numbers are just for ordering/readability.)
- **Sizing doesn't need to be exact** — the guide scales every image to the content width.
  Match the framing of the existing shots so the guide stays visually consistent.
- Reference it with `<img src="shots/17_your_screen.png" alt="…">` and always write a real
  `alt` and a `<figcaption>`.

---

## 5. Styling / theming (don't fight it)

- Colors come from **CSS custom properties** defined at the top of `styles.css` (`--accent`,
  `--ink`, `--surface`, etc.). Use the existing classes; **don't hardcode hex colors** in new
  markup, or light/dark theme will break.
- The page supports **light and dark**. If you add new CSS, define the color as a token and set
  it in every place the existing tokens are set — copy how an existing token is done.
- Keep the browser-tab title (`<title>`) and don't rename the deliverable file — downstream
  links point at `MPP_MES_ShopFloor_Guide.html`.

---

## 6. Keeping the guide honest

The shop floor changes faster than the guide does, and a wrong button name is worse than no
guide. When you touch a section:

- **Quote the UI verbatim.** Button and field names come from the Perspective views under
  `ignition/projects/MPP/com.inductiveautomation.perspective/views/BlueRidge/Views/ShopFloor/`.
  Grep the view's `"text"` props rather than paraphrasing from memory or from an old screenshot.
- **Re-check tab lists and counts.** Several sections state how many tabs a screen has. Those
  drift — LOT Detail has grown from five tabs to eight.
- **Watch for superseded workflows.** Die Cast moved from a one-basket-at-a-time form to a
  per-cavity grid, and Machining IN moved from a FIFO pick list to a scan. A section that still
  describes the old flow reads as plausible and is completely wrong.
- **LTT barcodes are 8 or 9 digits**, not 9. MPP's pre-printed stock is 8 digits; the rule
  lives in `Lots.ufn_IsValidExternalLtt`.

---

## 7. Git

1. Branch off `main` (or use `jacques/working`):
   ```powershell
   git checkout -b docs/shopfloor-guide-<what> main
   ```
2. Make your edits, add screenshots, then **run `build.ps1`** so the deliverable is current.
3. Commit the source, the stylesheet, the new screenshots, **and** the rebuilt deliverable
   together, staging explicit paths:
   ```powershell
   git add docs/shop-floor-guide/shopfloor-guide.src.html docs/shop-floor-guide/styles.css docs/shop-floor-guide/shots docs/shop-floor-guide/MPP_MES_ShopFloor_Guide.html
   git commit -m "docs(shopfloor-guide): <what you added>"
   ```
   > Stage explicit paths (not `git add -A`) — this repo often has unrelated in-progress work in
   > the tree.
4. Push and open a PR / merge as usual.

---

## 8. What's left to do (roadmap)

- **Every shop-floor route now has a section.** What is left is accuracy, not coverage.
- **Assembly OUT** has no screenshot of the non-serialized line — only the serialized one.
- **Two things the guide flags as unfinished in the app**, both with warning callouts to remove
  once they land: Shipping Dock's Active Manifest (no data model behind it) and the Supervisor
  Dashboard's Print Failures tile.
- **Screenshots are captured headlessly** — see `scripts/` note below. They all come from a
  session bound to the **Receiving** terminal, because the gateway host's loopback address maps
  there, so terminal-scoped screens show that station in the header. Re-capture from the correct
  terminal before customer release.
- **Before customer release:** remove the `Draft v0.3` tag in the masthead meta and the
  dev-environment / sample-data caveat in the footer.

## 9. Capturing screenshots headlessly

The screenshots in this guide were taken by driving headless Edge over the Chrome DevTools
Protocol rather than by hand. Two things make that non-obvious, and both will bite anyone who
retries it:

- **`msedge --headless --screenshot` hangs.** Perspective holds a websocket open, so
  `--virtual-time-budget` never drains. Drive CDP and call `Page.captureScreenshot` yourself once
  the page has painted.
- **Every shop-floor screen sits behind the "Enter your initials" keypad.** An unauthenticated
  headless session screenshots the keypad, not the screen. Sign an operator in first by clicking
  the on-screen keys, then `Enter`.

Capture at `deviceScaleFactor: 2` so the images stay sharp at the width the guide renders them.

---

*Questions on how a particular pattern was built? Every existing section is a working example —
copy the closest one and adapt.*
