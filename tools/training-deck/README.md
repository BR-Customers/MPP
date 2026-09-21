# Die cast training deck

Output: `docs/training/diecast/MPP_DieCast_Training.pptx` (29 slides, operators + team leads).
Spec: `docs/superpowers/specs/2026-09-18-diecast-operator-training-deck-design.md`.

| File | What it does |
|---|---|
| `diecast_content.js` | Every word on the slides. Edit wording here. |
| `build_diecast_deck.js` | Builds the .pptx. Refuses to write if a check fails. |
| `capture_diecast.mjs` | Drives the Dev die cast screen and saves screenshots + measured button positions to `docs/training/diecast/shots/`. |
| `lib/` | Reading-level score, marker placement, cropping, capture helpers. |
| `render_slides.ps1` | Exports every slide to PNG through PowerPoint, for a visual check. |

## Change wording, rebuild

```
npm run test:training
npm run build:training
```

Slide text must score grade 8 or below; the build tells you which slide failed.

## Re-capture screenshots (Dev only)

Needs the Dev gateway running with a live Perspective trial, and the capture Chrome
on port 9333 (never 9222, which Ignition Designer uses):

```
Start-Process "C:\Program Files\Google\Chrome\Application\chrome.exe" -ArgumentList "--remote-debugging-port=9333","--user-data-dir=$env:TEMP\training-capture-profile","--headless=new","--window-size=1600,1000","--disable-background-timer-throttling","--disable-backgrounding-occluded-windows","--disable-renderer-backgrounding","about:blank"
node tools/training-deck/capture_diecast.mjs --only operator     # or: reconcile
python tools/training-deck/check_overlays.py                     # draw targets to check them
```

The training operator is Sam Taylor, PIN 24680 (`setup_training_operator.sql`).
Two targets were placed by hand after the last capture (`void_dialog.voidBtn`,
`pin_pad.display`); the capture specs are corrected, so a re-capture measures them.

## Still to do: team lead screens

Slides 25-28 are placeholders. Capturing them needs a supervisor AD sign-in typed
by a person (the script never types credentials): a visible Chrome on port 9334,
the script pauses at Supervisor Access, you sign in, it carries on.
