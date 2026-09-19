# Die Cast Operator + Team Lead Training Deck — Design

**Date:** 2026-09-18
**Status:** Approved in conversation with Jacques (outline, packaging, annotation style); spec for review.

## 1. Purpose

A PowerPoint that teaches die cast operators and team leads to run the MES die cast
terminal: sign in, open and release baskets, reconcile the shift, and the few team lead
actions. It replaces "someone shows you once at the press" with a repeatable session and a
printed handout.

## 2. Audience and voice

- **Who:** die cast operators and team leads at MPP. Not engineers, not IT.
- **Reading level:** grade 7–8. Short sentences, common words, one idea per sentence. Name a
  screen control exactly as it is printed on the screen (`Scan LTT`, `Compute`,
  `Submit shift entry`) and explain any plant word the first time it appears.
- **Tone:** plain and direct, second person ("Tap **Release**."). No system internals — no
  "watermark", "contribution", "LOT genealogy", "proc".
- **Checked, not assumed:** every slide's on-screen text and every speaker note is scored with a
  Flesch–Kincaid grade formula in the build. On-screen text must score ≤ 8.0; notes ≤ 9.0 (notes
  are read by the trainer, not the operator). Screen labels and part numbers are excluded from
  the score — they are not prose.

## 3. Packaging and use

- **One deck, two parts:** Part 1 Operators, Part 2 Team Leads (a divider slide between).
- **Trainer-led + handout:** slides carry the steps; speaker notes carry the explanation the
  trainer says out loud, the "why", and the "what if it goes wrong". Every slide prints legibly
  in black-and-white handout mode (markers carry a number, not just a colour).
- **16:9**, white slides, dark title/closing slides. Calibri throughout (ships with Office,
  renders true-to-width in QA).

## 4. Visual language

### 4.1 Step slides — "style A, thin lines"

Screenshot on the left (~64% of the width); a numbered step list on the right.

- Each action on the screenshot gets a **thin amber outline** (`FFB400`, 1.5 pt, thin dark
  halo so it reads on the dark screen) and a **small numbered disc** (amber, black numeral).
- The numbers on the screenshot match the numbered steps in the list, 1-to-1.
- One short task per slide, 2–4 steps. A task that needs more gets a second slide
  ("… continued"), never a smaller font.
- An optional grey tip box under the steps for the one "if this happens, do that".
- **Numbers mean "press / do this".** Nothing else on a step slide is numbered.

### 4.2 Overview slides — one per screen, with a legend

Screenshot with **lettered, coloured zones** (A, B, C …; thin 1.5 pt outlines, each zone its own
colour) and a legend on the right naming each zone in a few plain words.
**Letters mean "this is an area"** — never used for actions, so the two never get confused.

### 4.3 Annotations are PowerPoint shapes, not baked into the images

Screenshots go in clean. Outlines, discs and zone tags are native PowerPoint shapes placed on
top, so a trainer can nudge or delete one without re-capturing. Their positions come from the
real on-screen element rectangles measured during capture (§6.3), not guessed pixels.

## 5. Outline

**Part 1 — Operators**

| # | Slide | Type |
|---|---|---|
| 1 | Title | title |
| 2 | Why we record baskets — the ticket follows the parts all the way to Honda | concept (one picture, three lines) |
| 3 | Words you will see — die, cavity, basket, LTT ticket, press counter, shift, scrap | glossary |
| 4 | **The Lot Management screen** | overview + legend |
| 5 | Sign in with your PIN — and what to do if it says "PIN Not Recognized" | steps |
| 6 | Pick your machine and check the die | steps |
| 7 | Open a basket (scan the LTT) | steps |
| 8 | Changeover: open all empty cavities at once | steps |
| 9 | Release a full basket — read the press counter, check the three boxes | steps (may be 2) |
| 10 | Void an empty basket | steps |
| 11 | **The Reconcile Shift screen** | overview + legend |
| 12 | End of shift: pick the shift, type the counter, press **Compute** | steps |
| 13 | Warm-up shots and quality test shots | steps |
| 14 | Check Good, add cavity scrap | steps |
| 15 | Amber number? Pick a reason ("Unknown" is OK), then **Submit** | steps |
| 16 | The counter was reset — **Fix counter** | steps |
| 17 | The **Downtime** button | steps |
| 18 | Handing over to the next operator | steps |
| 19 | Quick reference — one page, made to print | summary |

**Part 2 — Team Leads**

| # | Slide | Type |
|---|---|---|
| 20 | Part 2 divider | divider |
| 21 | **Supervisor Access** — signing in with your own account for protected actions | steps |
| 22 | **Die Mount** — changing the die on a press | steps |
| 23 | **Reset Terminal** — when to use it, when not to | steps |
| 24 | **The Die Cast Production dashboard** (`/shop-floor/die-cast/supervisor`) | overview + legend |
| 25 | Team lead shift checklist | summary |

Content for each step slide is taken from the **live screen**, not from the in-app How To
guides (`tools/gen_howto_views.py`), which describe an approved design and lag the view in
places (e.g. the guide's "Open basket" button is a `Scan LTT` box on the live row).

## 6. How the screenshots are made

### 6.1 Environment

- **Dev** (`MPP_MES_Dev`), carrying prod's configuration since the 2026-09-18 import
  (`Import-ConfigSnapshot.ps1`). Jacques's local playground — writes are fine.
- **Machine 11** (`DC1-M11`), terminal `DC1-T1`, die **DMO125** (12 cavities, 6 parts × `a`/`b`)
  — a real die, so the screens look like the plant.
- **One training operator** added through `Location.AppUser_Create`, fictional name and initials
  (e.g. *Sam Taylor / ST*), so the screens do not say "Dev User".
- Browser at **1600 × 1000** — large enough to read on a projector once scaled to the slide.

### 6.2 Driving the screens

The capture harness (`tools/perspective-capture/`, headless Chrome over CDP on port 9333)
drives the real screens: PIN pad, Active Cell, `Scan LTT`, Release dialog, Reconcile Shift,
Fix counter. Where a step needs history the screen cannot show in one sitting (e.g. a basket
that has been running for hours), baskets are opened / released through the **same procs the
screen calls** (`tools/perspective-capture/db.mjs`), never raw `INSERT`s. A run is repeatable:
it starts by clearing its own baskets on DMO125.

### 6.3 Measuring what to point at

For every capture, the script records the bounding rectangle of each control a slide will
annotate (found by visible text or placeholder, filtered to non-zero size — harness rule 3), in
screenshot pixels, into a JSON file beside the PNG. The deck generator converts those to slide
inches. A control that cannot be found fails the capture loudly; nothing is placed by guesswork.

### 6.4 Things that may not be capturable on Dev

- **Supervisor Access / Die Mount need an AD sign-in.** Dev has a working dev account. The
  capture script never types credentials: for the team lead slides it runs Chrome as a
  **visible window**, drives to the Supervisor Access popup, captures it empty, then **pauses**
  and waits for Jacques to type the account and password himself. It resumes when the elevated
  state appears on screen. Credentials are never written into a script, file or note.
- **Downtime** depends on a PLC-driven event or the manual Downtime entry. Captured from the
  manual path; if the screen needs an open downtime event, one is created through its proc.

## 7. Build

- **Generator:** `tools/training-deck/build_diecast_deck.js` (pptxgenjs). Content — slide
  titles, steps, legend entries, notes — lives in a separate data file
  `tools/training-deck/diecast_content.js` so wording can be edited without touching layout.
- **Capture script:** `tools/training-deck/capture_diecast.mjs` (uses the harness library).
- **Output:** `docs/training/diecast/MPP_DieCast_Training.pptx`, screenshots + rect JSON in
  `docs/training/diecast/shots/`. Committed (the deck is a deliverable; screenshots are its
  source and show Dev data only).
- **Checks run by the build:** readability score per slide (§2), every step number has a
  matching marker and vice versa, every legend letter has a zone, every marker lands inside
  its screenshot.

## 8. QA

Render to images (`soffice` → PDF → JPEG) and inspect every slide for overflow, overlap,
markers off target, and low contrast. Validate with the pptx skill's `validate.py`. Then a
fresh-eyes read of the slide text alone, as an operator would read it.

## 9. Out of scope

- **A die cast shift repair view** (editing a submitted Reconcile Shift entry). It does not
  exist. The deck teaches what does: the Reporting Shift picker lists the last 3 shifts, and
  late scrap can be added to a basket released earlier in the same shift. A trainer note says a
  submitted entry cannot be changed from the terminal — call the team lead.
- **The general Supervisor Dashboard** (`/shop-floor/supervisor`) — four of six tiles are
  placeholders; not ready to teach.
- Trim, machining, assembly screens — later decks can reuse this generator.
