# MPP MES — Shop Floor Guide

A customer-facing, screen-by-screen guide to operating the MES from the plant floor via the
**MPP** Ignition Perspective application. Prepared by Blue Ridge Automation for Madison
Precision Products.

## Files

| File | What it is |
|---|---|
| `MPP_MES_ShopFloor_Guide.html` | **The deliverable.** A single self-contained HTML file (screenshots inlined as data URIs, stylesheet inlined) — hand this to the customer. Opens offline in any browser; no external assets. |
| `shopfloor-guide.src.html` | **Edit this.** The source template. References screenshots by relative path (`shots/NN_*.png`) and links `styles.css`, so it renders while editing. |
| `styles.css` | The page stylesheet. Inlined into the deliverable by `build.ps1`. |
| `shots/` | Screenshots, one per shop-floor screen/state, captured from the live app. |
| `build.ps1` | Inlines the stylesheet and screenshots from `shopfloor-guide.src.html` into the deliverable HTML. |

## Regenerating the deliverable

After editing `shopfloor-guide.src.html`, `styles.css`, or the screenshots in `shots/`:

```powershell
cd docs/shop-floor-guide
powershell -ExecutionPolicy Bypass -File .\build.ps1
```

This rewrites `MPP_MES_ShopFloor_Guide.html`.

## Editing conventions

- **Text/structure:** edit `shopfloor-guide.src.html` directly. Each screen is a `<section>`
  with an `h2`, a `p.lead` summary, framed screenshots (`figure.shot`), and — where there is a
  procedure — an `ol.steps` step list. Add the section's id to the sidebar `<nav class="toc">`
  so it appears in the contents.
- **Screenshots:** name them `NN_screen_state.png` and reference them as
  `src="shots/NN_screen_state.png"`. Wide app screenshots scale to the content width
  automatically.
- **Non-ASCII:** the source uses real em-dashes (—). If you script edits, read/write with
  UTF-8 (`[IO.File]::ReadAllText`/`WriteAllText`) — Windows PowerShell 5.1 `Get-Content`
  defaults to ANSI and will corrupt them. Never write the file with `Set-Content` without
  `-Encoding utf8NoBOM`; a BOM breaks the build.
- **Themes:** the page is light/dark aware via CSS custom properties in `styles.css`; style
  through the tokens, not inside the media query, so both themes stay in sync.
- **Accuracy:** button and field names in `<code>` and `<b>` spans are quoted verbatim from
  the Perspective views. When a screen changes, re-check them against
  `ignition/projects/MPP/com.inductiveautomation.perspective/views/BlueRidge/Views/ShopFloor/`
  rather than paraphrasing from memory.

## Still to flesh out

- **Assembly OUT** has no dedicated screenshot of the non-serialized line; only the serialized
  line is shown.
- **Shipping Dock's Active Manifest** is documented with a warning callout because the manifest
  has no data model behind it yet. Remove the callout once that lands.
- **Supervisor Dashboard's Print Failures tile** is still a placeholder in the app; the section
  says so. Update it when the tile is wired.
- **Screenshot headers must match the guide's framing.** The guide now tells operators the terminal
  is already set for their station and to raise it with a supervisor if the header says otherwise, so
  a screenshot whose header contradicts that undercuts the message. Two sets need re-capturing before
  customer release:
  - `17_initial_entry.png` is captured from the **Fallback Terminal / Madison Facility** — the exact
    unconfigured state the guide tells operators to report.
  - Shots `23`-`34` come from a session bound to the **Receiving** terminal, because the gateway
    host's loopback address maps there, so terminal-scoped screens name the wrong station.
- Before final customer release, review the dev-environment / sample-data caveat in the footer
  and the `Draft v0.3` tag in the masthead.

## Re-capturing screenshots

Screenshots were captured from the running app at
`http://localhost:8088/data/perspective/client/MPP`. Replace any `shots/NN_*.png` with an
updated capture (same filename) and re-run `build.ps1`.
