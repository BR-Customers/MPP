# perspective-capture

Drives a real Perspective session in headless Chrome over the DevTools
Protocol, and writes screenshots to **files** — so a walkthrough can be
scripted, re-run, and pasted into a document.

Built for the press-counter review book (`docs/superpowers/specs/2026-09-10-diecast-counter-anchor-design.md`,
`notes/2026-09-10_review-book-teardown.sql`). Reusable for FAT evidence, demo
captures, or any "show me this screen in this state" job.

**Zero dependencies.** Node 22+ has a global `WebSocket`, which is all CDP
needs.

## Why not the in-app browser pane

It renders and clicks fine, but it **cannot commit a Perspective input
binding** — `form_input`, native events and synthetic keystrokes all leave
`view.custom.*` untouched — and it hands screenshots back inline rather than as
files. Both are fatal for a screenshot document. Real Chrome has neither
problem.

## Running

```bash
"/c/Program Files/Google/Chrome/Application/chrome.exe" \
  --remote-debugging-port=9222 --user-data-dir=/tmp/cap-profile \
  --headless=new --window-size=1600,1000 \
  --disable-background-timer-throttling \
  --disable-backgrounding-occluded-windows \
  --disable-renderer-backgrounding &

SHOTDIR=/tmp/shots node scenA.mjs
```

## Four things that cost hours, so they are load-bearing

1. **The throttling flags are not optional.** Headless Chrome backgrounds its
   renderer, which kills Perspective's websocket. The symptom is not an error:
   the session shows *"No Connection to Gateway"*, clicks land on nothing, and
   every selector still resolves because the DOM is intact. Without those three
   flags nothing works and nothing says why.

2. **Click the element, not the coordinates.** `el.click()` raises a real
   bubbling event React acts on. A coordinate `Input.dispatchMouseEvent` gets
   swallowed by the transparent modal layer Perspective stacks over popups —
   silently, with the button still painting its hover state. (If you do use
   coordinates, `buttons: 1` on `mousePressed` is mandatory or React ignores
   the event.)

3. **Several identical views are mounted at once.** The login popup, the
   register popup and the numpad all exist in the DOM simultaneously; all but
   the visible one measure `0×0`. A non-zero `getBoundingClientRect()` is what
   disambiguates them — not text, not DOM depth.

4. **A `scan.ps1` mid-run detaches every embedded view.** The gateway logs
   *"View restarted but missing from session"* and from then on every click on
   a repeater row is a dead event. Reload the page after any scan.

Two more, smaller: dialog headings often repeat their confirm button's label
(`Release basket`), so match on `<button>` for actions; and when walking up
from a button to find its row, stop at ~220 characters of text or you reach the
container holding every row and always match the first one.

## Layout

| File | |
|---|---|
| `cdp.mjs` | CDP transport, screenshots, viewport, low-level input |
| `lib.mjs` | Die cast terminal steps — sign-in, cell picker, tabs, typed fields |
| `db.mjs` | `sqlcmd` helpers; opens/releases baskets through the real procs |
| `fixture.sql` | Three review dies on idle machines DC1-M04/05/06 |
| `scenA/B/BC.mjs` | The three walked-through shifts |
| `standalone.mjs` | Wraps a published artifact body into an emailable `.html` |

Fixtures are removed by `notes/2026-09-10_review-book-teardown.sql`.
