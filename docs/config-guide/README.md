# MPP MES — Configuration Tool Guide

A customer-facing, screen-by-screen guide to configuring the MES via the **MPP_Config**
Ignition Perspective application. Prepared by Blue Ridge Automation for Madison Precision
Products.

## Files

| File | What it is |
|---|---|
| `MPP_MES_Configuration_Guide.html` | **The deliverable.** A single self-contained HTML file (screenshots inlined as data URIs) — hand this to the customer. Opens offline in any browser; no external assets. |
| `config-guide.src.html` | **Edit this.** The source template. References screenshots by relative path (`shots/NN_*.png`) so it renders while editing. |
| `shots/` | Screenshots, one per configuration screen/state, captured from the live app. |
| `build.ps1` | Inlines the screenshots from `config-guide.src.html` into the deliverable HTML. |

## Regenerating the deliverable

After editing `config-guide.src.html` or adding screenshots to `shots/`:

```powershell
cd docs/config-guide
powershell -ExecutionPolicy Bypass -File .\build.ps1
```

This rewrites `MPP_MES_Configuration_Guide.html`.

## Editing conventions

- **Text/structure:** edit `config-guide.src.html` directly. Each screen is a
  `<section>` with an eyebrow (category), an `h2`, a What/When/Why summary (`.www`),
  framed screenshots (`figure.shot`), and a "How to configure" step list (`ol.steps`).
  Add the section's id to the sidebar `<nav class="toc">` so it appears in the contents.
- **Screenshots:** name them `NN_screen_state.png` and reference as
  `src="shots/NN_screen_state.png"`. Wide app screenshots (~1936&nbsp;px) scale to the
  content width automatically.
- **Non-ASCII:** the source uses real em-dashes (—). If you script edits, read/write with
  UTF-8 (`[IO.File]::ReadAllText`/`WriteAllText`) — Windows PowerShell 5.1 `Get-Content`
  defaults to ANSI and will corrupt them.
- **Themes:** the page is light/dark aware via CSS custom properties; style through the
  tokens, not inside the media query, so both themes stay in sync.

## Still to flesh out

- **PLC Devices** — the fields and flow are documented, but the screen has no screenshot yet.
  Capture it once its UI styling is finalized.
- Before final customer release, review the dev-environment / sample-data caveat in the
  footer and the `Draft v0.3` tag in the masthead.

## Re-capturing screenshots

Screenshots were captured from the running app at `http://localhost:8088/data/perspective/client/MPP_Config`.
Replace any `shots/NN_*.png` with an updated capture (same filename) and re-run `build.ps1`.
