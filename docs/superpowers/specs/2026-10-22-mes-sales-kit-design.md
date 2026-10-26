# MES sales kit (menu-driven deck + interactive demo) -- design

**Date:** 2026-10-22
**Status:** Ready for Jacques's approval (open items settled 2026-10-26)
**Built with:** the `ignition-sales-kit` skill (Aaron's, from the RFID Track & Trace kit), unpacked
at `<scratchpad>/rfid_kit/RFID Track & Trace - Marketing Kit/skill/ignition-sales-kit/`.
Its `SKILL.md`, `references/deck-outline.md`, `references/demo-architecture.md` and
`references/anonymization.md` are normative except where this document says otherwise.

## 1. Intent

Blue Ridge has delivered a full MES on Ignition Perspective + SQL Server for a die-cast and
assembly plant (MPP). The capabilities it proves -- LOT traceability from raw material to the
shipped container, lot-based casting, line-flow machining and assembly, quality containment,
customer-compliant shipping -- are sellable to other plants. Sales needs a kit to sell them.

The MES has far more features than one pitch can carry, so the kit is **menu-driven**: a short
core every meeting gets, then a menu from which the salesperson opens the module that matches what
the prospect raised first. The interactive demo mirrors the same menu.

The selling line Jacques arrived at: **one system runs both modes of discrete manufacturing** --
lot-based (casting, trim: baskets filled and closed at a count) and line-flow (machining,
assembly: LOTs live at the line and are pulled FIFO) -- and keeps **one unbroken genealogy across
the handoff**, basket -> machined part -> finished good. Most plants run those two modes on two
systems, or on paper at the seam.

Language rule from that conversation: never say "continuous" -- to a process-industry buyer it
means chemicals / food / paper. Say **lot-based** and **line-flow**; both are discrete.

## 2. Goals, non-goals, anti-goals

**Goals**
- One presenter deck (`.pptx`) and one interactive demo (single `.html`) that share a module menu.
- A salesperson can open at any module and present it standalone, then return to the menu.
- A one-page "starting point picker" so sales knows which module to open from what the prospect
  says.
- Built so further modules can be added later without restructuring either deliverable.

**Non-goals (this pass)**
- Modules 4-7 (section 4) -- the structure reserves them; they are built in a later pass.
- An industry-specific re-skin. The sample plant is a casting + assembly components plant.
- Hosting the demo on the company website (the file must be hostable; publishing it is sales'
  call).

**Anti-goals -- a failure even if it technically works**
- Anything that lets a reader identify MPP, Honda or the Madison site (section 6).
- Claiming "proven in production" for a feature that is not in MPP's prod (section 5).
- Selling OEE as an existing product: no OEE dashboard exists; OEE is an add-on.
- A demo that is a mockup of screens without the real behaviour (the rules are what is sold).
- Timelines, dates, prices, PLC/controls brand names anywhere -- slides, notes, demo, README.

## 3. Deliverables

| File | What |
|---|---|
| `MES Track & Trace - Overview.pptx` | Menu-driven presenter deck (section 4.1) |
| `MES Track & Trace - Interactive Demo.html` | Single self-contained file, works from `file://`, a web server and an iframe (section 4.2) |
| `README.md` | What each file is, how to present, the starting point picker, the rules for sales |
| `deck-build/`, `demo-build/` | Generators and sources so the kit can be rebuilt and extended |

Shareable kit folder and naming: section 9.

## 4. Structure

### Modules

Named for what the prospect has, not MPP's screen names. **First pass builds the core + modules
1-3.** Modules 4-7 exist in the deck as menu tiles marked "available on request" (no hyperlink
target yet) and are not on the demo's welcome screen until built.

| # | Module | What it shows | MPP prod status |
|---|---|---|---|
| 1 | Traceability & genealogy | Trace a finished unit back to press, cavity and shift; forward to every container it went into; LOT detail; the trace PDF | Deployed |
| 2 | Casting & lot-based production | Per-cavity tracking, a basket as a LOT opened/released at a count, shift reconciliation against the press counter | Deployed |
| 3 | Line-flow machining & assembly | Line inventory, FIFO pull by scan, a machined part minted from its casting (parent reduced, child created), tray completion, the station that locks itself before it runs out of components | Deployed (scale station pending) |
| 4 | Quality & containment | Holds, scrap with reasons, inspection, sort cage; controlled runs with e-signed release | Holds etc. deployed; controlled runs pending |
| 5 | Shipping & customer compliance | Customer-format labels, container validation at the dock, live link to the customer's shipping system | Deployed |
| 6 | Downtime & shift performance | Downtime entry, supervisor dashboard, shift-end summary, PDF reports | Deployed (no OEE dashboard) |
| 7 | Engineering owns the rules | Plant model, routes, BOMs, part eligibility, plain-English audit trail | Deployed |

Operator PIN sign-in and supervisor approval for protected actions belong to the **core**: every
module depends on them.

### 4.1 Deck

Follows `deck-outline.md` (audience = the prospect; coaching only in speaker notes; plain language
on slides; every slide has a visual and a talk track; 13.33 x 7.5; pptxgenjs with masters and
sections; never hand-edit the pptx) with this arc instead of its single-capability outline:

**Core (every meeting)**
1. Title -- product name, one-line value prop, a drawn graphic of the flow (basket -> line ->
   finished good -> container), "Presented by Blue Ridge Automation". Notes: the do-not-say list.
2. Problem -- "The question every plant asks after a customer complaint": which units, from which
   cast, which shift, where are they now. Industry-neutral pain cards.
3. Where this fits -- plants with both lot-based and line-flow production; regulated or
   customer-audited traceability; legacy MES / paper travelers; multi-area flow.
4. What we deliver -- one system, both modes, one genealogy; on Ignition; operator terminals;
   integrations (scales, printers, vision, the customer's EDI) without naming brands.
5. The operator's day -- PIN sign-in at a terminal, protected actions ask a supervisor first.
6. **"Where do you want to start?"** -- the menu: 7 tiles. Tiles 1-3 hyperlink to their section;
   4-7 shown as "available on request".

**Modules 1-3** -- one PowerPoint section each, 3-5 slides: a module title slide, tour slides
(prospect-pointed title, caption, a capture of the demo, feature pill), and a last slide with a
"Back to the menu" link to slide 6. Each module stands alone if the presenter opens it first.

**Close (every meeting)**
- What changes on your floor (outcomes, qualitative).
- Is this a fit for your plant? (questions in second person; what each answer tells the presenter
  is in the notes; the notes also map answers to modules).
- How we work together (site walk, FDS, build and preview, commission, train) -- no durations.
- Add-ons (OEE, ERP hooks, ... -- quoted separately).
- Take the next steps (explore the demo; schedule a live demo with one of our engineers) -- always
  last.

Hyperlinks: tile -> section uses internal slide links; verify in rendered PowerPoint slide show.

### 4.2 Demo

Follows `demo-architecture.md` (vanilla JS, one file, CONFIG block at the top, seeded simulation,
render-per-view, throttled re-render, scene hooks `?scene=&nochrome=1`, SAMPLE PROJECT chip,
dark-only, no external requests, tablet-usable, small-screen note) with these differences:

- **Welcome screen = the module menu.** One sentence on what this is (a sample plant running the
  MES, simulated data), a tile per built module that starts that module's guided tour, "Explore on
  your own", and the "Schedule a live demo" call-to-action (also in the header).
- **Tours are per module** (5-8 steps each, each with a working "Show me"); the tour drawer shows
  which module you are in and offers "Back to the menu" at the end. The last step of every tour
  ends on the call-to-action.
- **Screens reproduced** (shop-floor app look: the MPP Core stylesheet tokens -- neutral stack
  `#0B1220`...`#F0F3F8`, accent `#126680`/`#1888A8`/`#22A8CC`/`#4BC2E0`, warn `#F4B343`, Noto Sans
  / Roboto Mono):
  - Core: terminal sign-in with the numeric PIN pad; a protected action asking for a supervisor.
  - M1: LOT search, LOT detail (history, genealogy tab), the genealogy tree walking from a tray
    back to the press and cavity, global trace forward to containers.
  - M2: die cast terminal (cavities, open basket, shot counts rising live, release at count),
    shift reconciliation sheet (net shots = good + scrap + unaccounted; non-zero variance takes a
    disposition, "Unknown" always available).
  - M3: line inventory, Machining IN scan-to-pull, Machining OUT FIFO queue -> pick casting ->
    machined LOT minted (parent reduced, child created), assembly tray completion, the
    low-inventory lock and checking a box in.
- **Simulation** advances the real rules: presses fire shots into open baskets per cavity, baskets
  release and join the trim/line queues, machining pulls oldest first, assembly consumes and
  closes trays, genealogy edges are recorded as they happen so a trace done mid-demo is real.
- Genealogy is the spine: any LOT anywhere opens the same LOT detail, so modules connect.

## 5. Maturity rule

The deck and demo may say the system is **proven in production at a manufacturer** -- never where.
*(Builder's call, from the review:)* that claim is made **once, about the system as a whole**, in
the core -- never per feature or per screen. Feature pills and tour steps describe what the screen
does, not whether it is live, so the kit does not depend on which Ignition import reached MPP's
prod when. Features known to be pending (the Assembly Out scale station, controlled runs /
super-lots) are not shown in modules 1-3 at all this pass. OEE is an add-on only.

**Reuse is cleared:** Blue Ridge's agreement with MPP allows the delivered features to be shown to
other prospects in anonymized form (Jacques, 2026-10-22). The demo keeps the shop-floor look
(Blue Ridge's own design system) and the behaviour; section 6 removes everything that names or
numbers MPP.

**Trim** *(builder's call)*: shown in module 2 as one tour step -- a basket checked into trim and
out again -- not a full screen set.

**Add-ons slide** *(builder's call, for Jacques to check)*: OEE & downtime analytics, ERP /
scheduling integration, controlled runs with e-signed release, scale / weigh stations. All
"quoted separately".

## 6. Keeping MPP out

`anonymization.md` applies in full. The sample plant is synthetic by construction. MPP-specific
terms that must not appear in any shareable file (deck XML, demo, README, build scripts):

- MPP, Madison Precision Products, Madison, Indiana; Honda; AIM (say "the customer's shipping
  system" / "customer EDI"); Flexware; Manufacturing Director; SparkMES; EXCSRV05.
- Real part numbers (`5G0`, `6MA`, `12270-6NA-M`, `5J6`, `5K8`, `64A`, `6C2`, ...), die codes
  (`DM0124`), MPP line / area / terminal names, MPP seed data, people, IPs, hostnames.
- The `LTT` name (say "LOT ticket"). Template codes (`T-Out-A`, `M-Out-A`).
- Any real screenshot, DOM capture or drawing. `notes/2026-10-22_mpp-mes-walkthrough.html` and
  `mockup/*.html` are **study material only** for behaviour, layout and wording.
- PLC / controls brands; scale / printer / vision vendor names (say "scales", "label printers",
  "vision").

Fictional sample plant (builder's call within these rules): a components plant with die-cast
presses, a trim area, two machining + assembly lines and a shipping dock; neutral product
families (housings, covers, brackets); invented part numbers and die codes in a different format
from MPP's; invented operator initials. All of it in the demo's CONFIG block.

The real -> fictional key, if any is written, stays internal (section 7).

## 7. Where things live

- **Shareable kit:** `C:\Users\JacquesPotgieter\Documents\Dev\Marketing\MES Track & Trace\` (section 9).
- **Internal:** `notes/2026-10-22_mes-sales-kit-SOURCE.md` in this repo -- which project it came
  from, the do-not-say term list used for the final grep, the maturity snapshot.
- **This design:** this file.

## 8. Verification

- Demo in the in-app browser (served over HTTP from a static server; the built-in browser cannot
  open `file://`): every view at 1600x900 and 1024x768, welcome menu, every tour step's "Show me"
  at 1x and 10x, success and failure paths of each operator flow, zero console errors.
- Deck: rendered via PowerPoint (`render_pptx.ps1`), contact sheets inspected, `validate.py`
  passes, menu hyperlinks work in slide show.
- Final grep of the shareable folder (unzipped deck XML included) for every term in section 6,
  every PLC brand, and dates.

## 9. Settled with Jacques (2026-10-26)

1. **Product name:** `MES Track & Trace` *(builder's call -- Jacques's own phrase for the
   capability; distinct from Aaron's `RFID Track & Trace`)*. Files:
   `MES Track & Trace - Overview.pptx`, `MES Track & Trace - Interactive Demo.html`.
2. **Shareable kit lives at** `C:\Users\JacquesPotgieter\Documents\Dev\Marketing\MES Track & Trace\`
   (outside this repo), laid out as SKILL.md phase 6 describes.
3. **"Schedule a live demo with one of our engineers" stays as worded.** The live demo is an
   engineer walking the prospect through a running Ignition Perspective demo application that
   models this track & trace functionality. The link/contact is a clearly marked placeholder in
   the demo CONFIG block and the deck generator until supplied.
4. **Logo:** the Blue Ridge logo PNG already inlined in the RFID Track & Trace demo (extracted;
   copied to `demo-build/assets/` and `deck-build/`).

## 10. Left to the builder

Fictional names and numbers; exact slide count per module (3-5); tour wording; simulation
rates; drawn layouts; which screens each tour step lands on; deck palette details within the
deck-outline look rules.
