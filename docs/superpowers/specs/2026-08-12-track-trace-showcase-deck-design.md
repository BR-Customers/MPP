# Track & Trace + Genealogy — Capability Showcase Deck (Design Spec)

**Date:** 2026-08-12
**Author:** Jacques Potgieter (w/ Claude)
**Status:** Approved design — ready for implementation plan
**Deliverable:** A branded PowerPoint deck showcasing the MES's track-and-trace, genealogy, movement, reporting, and data-integrity capabilities, built from real screenshots of the running system populated with purpose-built demo data.

---

## 1. Purpose & Audience

Build a **feature/function showcase** deck (not a sales pitch — no problem/solution framing, no selling language) that demonstrates the working MES to a **division of Baxter** (medical-device manufacturer). Each slide presents a capability with a real screenshot (or rendered PDF report) and a short descriptive caption of what it does.

The deck is presented by Blue Ridge's team to a prospect. It must look like a polished, real, working system — visual fidelity is the priority.

### Positioning constraints (hard requirements)

- **"Track & Trace + Genealogy" capability positioning.** The capability is the subject, not any one client's project. It is fine to present the demo as an **aluminum die casting facility supporting automotive** — that is real and credible. What we do NOT do: name the specific end customer (no MPP / Madison Precision) or the OEM (no Honda), and we do not frame around any one customer's mandates.
- **The live process on screen is aluminum die casting** (Die Cast → Trim → Machining → Assembly → Ship) — shown plainly, not hidden. The compliance slide adds the bridge that the **genealogy / audit / versioning / movement model is process-agnostic** and applies to any regulated discrete manufacturing, including medical-device Device History Record needs.
- **Seed data avoids customer/OEM identifiers only.** The facility name is a plausible die-cast company name that is NOT the real customer ("Madison"). Part names/numbers can be realistic automotive aluminum castings (brackets, housings, cases, covers) — they just must not name or imply a specific OEM.
- **No Honda/AIM-labeled screens or fields are captured.** The AIM (Honda EDI) shipping-label / shipper-ID surfaces are excluded from the capture list. If any captured screen incidentally shows AIM/Honda-specific terminology, it is re-shot or excluded.

---

## 2. Brand System (inherited from the Blue Ridge template)

Source: `New Kickoff Meeting PowerPoint Template.pptx` (Blue Ridge Automation's official kickoff template, 16:9 / 13.33"×7.5").

**Palette**
- Navy (primary text, frame): `#1E2761`
- Cyan / sky blue (accent, logo mountain): `#29ABE2`
- Gold / orange (secondary accent, "sunrise" dots): `#F7A823`
- Background: white `#FFFFFF`, with the template's navy outer frame + thin cyan inner border
- This maps directly onto the app's own cyan-accent plant-floor aesthetic — screenshots and slides read as one system.

**Typography:** template's serif navy titles (centered), sans body. Keep the template's master fonts. For any newly-authored text, use safe-list fonts (Cambria for serif headers to match, Calibri/Arial for body) so overflow QA is trustworthy.

**Motif:** the template's mountain logo + corner sunrise-dot graphic. Reuse the branded master/layouts so this carries automatically — do not hand-draw brand elements.

**Layouts to reuse (from the template master):**
- `Double Logo` — title slide + closing slide
- `Section Header` — pillar dividers (Track & Trace / Live Movement / Reporting)
- `Picture with Caption` — single-screenshot feature slides
- `Two Content` / `Comparison` — 2-up screenshot slides (reports, config)
- `Title and Content` / `Title Only` / `Blank` — flexible composited slides

**Build method (see §6):** start from the template `.pptx`, do all structural work first (keep the branded title + closing Double Logo slides, delete the kickoff-specific slides 2–34, add new feature slides on the branded layouts), then fill content, then QA.

---

## 3. Data Pipeline

The gateway datasource is a shared singleton currently pointing at `MPP_MES_Dev` (Jacques's hand-built DB). The showcase must **not** touch `MPP_MES_Dev`.

**Steps:**

1. **Build `MPP_MES_Showcase`** via `sql/scripts/Reset-DevDatabase.ps1 -ServerInstance localhost -DatabaseName MPP_MES_Showcase -SkipDemoSeed` — full schema (versioned migrations) + repeatables + standard seeds (real plant-location model, code tables). `-SkipDemoSeed` so we control the transactional seed ourselves. (`MPP_MES_Showcase` is not a `*_Dev` name, so the drop guard does not require `-Force`; a fresh create is fine.)
2. **Genericize + seed** via a purpose-built script `sql/scratch/seed_showcase.sql` (see §4). Runs after the reset. Idempotent where practical.
3. **Verify** the seed produced screenshot-worthy data (row-count / spot-check queries — see §4.5) before involving the gateway.
4. **Gateway swap (Jacques-in-the-loop, single bounded window):** Jacques repoints the gateway datasource connection to `MPP_MES_Showcase`, runs `.\scan.ps1`. Claude captures every screen + renders every report in one batch. Jacques swaps the datasource back to `MPP_MES_Dev` + `.\scan.ps1`. The disruption window is short because all data is staged and the capture route list is pre-built.
5. **Capture** via the in-app browser (read-only rendering only — no input committing needed; that limitation does not apply to pre-populated read views).

**Why swap the existing gateway (not Docker):** the running 8.3.5 gateway already has the entire project deployed and render-verified — Perspective views, the `mpp` icon library, plant-floor stylesheets, all named queries, and the six PDF reports (which were painful to get rendering: report-resolves-by-title, icon paths, XML-escaping). A fresh Docker gateway risks visual drift that undermines a fidelity-critical sales deck. The swap reuses all of it.

---

## 4. Seed Data Requirements (`sql/scratch/seed_showcase.sql`)

Goal: produce **prospect-grade, report-worthy, genealogy-rich** transactional data on top of the standard config. Build on the proven patterns in `sql/scratch/seed_demo.sql` (idempotent wipe of its own transactional footprint in FK-safe order, then rebuild the golden thread via production procs). Extend/adjust for showcase quality.

### 4.1 Identity scrub (customer/OEM anonymity only)
Aluminum die casting for automotive may be shown plainly. Only customer/OEM identifiers are scrubbed.
- **Facility / site root name** → a plausible die-cast company name that is NOT the real customer (e.g. "Riverside Die Casting" or similar — no "Madison", no customer identifier). Applied via a targeted `UPDATE` of the root `Location.Name` (and any customer-identifying area names) after the location seed loads. Codes may stay; only display Names matter for screenshots.
- **Part names/numbers** → realistic automotive aluminum castings (e.g. "Housing, Oil Pump", "Bracket, Transmission Mount", "Cover, Valve", "Case, Gearbox") with neutral part numbers — just no named/implied OEM.
- Confirm no seeded string contains "Honda", "Madison", "MPP", or "AIM" (byte/text scan before capture). "Automotive" / "die cast" / "aluminum" are fine.

### 4.2 Track & Trace / genealogy content
- **At least one fully-shipped finished good** with a **complete end-to-end genealogy**: Die Cast origin → Trim → Machining (consume-mint SubAssembly) → Assembly (consume-mint FG) → Shipped. Multi-level parent/child lineage with per-edge consumed quantities so `LotDetail`, `GenealogyViewer`/`GlobalTrace`, and the Lot Detail PDF all render a rich tree.
- **2–3 additional in-flight lineages** at varying depth so genealogy/search screens show more than one thread.
- Production events + as-built BOM version stamped (the mint procs already do this) so the LotDetail tabs (genealogy, production events, as-built BOM, inspections) are all populated.

### 4.3 Movement / WIP content
- **WIP spread across terminals** — Open die-cast baskets, released lots in Trim storage, machined subassemblies staged, assembly in progress — so operator queues and the Current Inventory / Supervisor views look alive (believable counts, not one lonely row).

### 4.4 Reporting content (date-spread is essential)
Reports render empty without historical spread. Seed:
- **Downtime events across several shifts / a date range** (mix of reason codes, a few machines) → feeds Downtime by Shift, Downtime by Date Range, Production Line Performance.
- **Die-cast shot counts** on mounted dies (materialized `Tool.ShotCount`) → Die Cast Shot Count report.
- **Weekly output/scrap** spread → Production Line Performance report.
- Current Inventory is fed by the WIP spread (§4.3).

### 4.5 Quality / compliance-visible content
- **At least one open Hold** (so Hold Management + the LotDetail "ON HOLD" pill render) and one released hold (history).
- **A few quality inspections** (pass + fail) so the LotDetail Inspections tab and any quality read is populated.
- **Audit log** populates naturally from all the production procs (no separate step) — gives the Audit Browser real content and underwrites the compliance slide.

### 4.6 Verification queries (run before gateway swap)
A short verification block (SELECT counts) asserting: ≥1 shipped FG with genealogy depth ≥4; WIP present at ≥3 distinct locations; downtime events spanning ≥5 days; ≥1 open hold; ≥1 pass + ≥1 fail inspection; audit rows > 0; **zero** rows containing forbidden identity strings.

---

## 5. Screenshot Capture List

Captured via the in-app browser against the swapped gateway. Perspective session may land on the fallback terminal (plant-wide zone) — acceptable and often better for a showcase (plant-wide queues look fuller). Each item notes the route and what it must show. Reports are rendered via the Reports landing page (or by temporarily defaulting the view, per the reporting capture note) → PDF → image.

| Cap # | Screen | Route | Must show |
|---|---|---|---|
| C1 | LOT Detail | `/shop-floor/lot-detail/:lotId` (the shipped FG) | Header + genealogy tab + production events + as-built BOM; no AIM/Honda fields |
| C2 | Genealogy tree | `/shop-floor/genealogy` or `/shop-floor/trace` | Multi-level parent/child tree of the shipped FG |
| C3 | LOT search | `/shop-floor/lot-search` | Results list with several lots + status |
| C4 | Shop-floor movement | an operator terminal (`/shop-floor/machining` or `/shop-floor/assembly-nonserialized`) | WIP queue + move/validated-move affordance |
| C5 | Plant-wide WIP | `/shop-floor/supervisor` | Live inventory/WIP across the floor |
| C6 | Reporting hub | `/shop-floor/reports` | Tile rail of available reports |
| C7 | Lot Detail PDF | Reports → Lot Detail | 2-page traceability artifact (rendered PDF → image) |
| C8 | Current Inventory PDF | Reports → Current Inventory | Plantwide WIP report |
| C9 | Production Line Performance PDF | Reports → Production Line Performance | Weekly output/scrap/downtime |
| C10 | Plant Hierarchy (config) | `/plant` (MPP_Config) | ISA-95 location tree |
| C11 | Item Master (config) | `/items` (MPP_Config) | Part config (identity + routes/BOM tabs) |
| C12 | Quality Specs (config) | `/quality-specs` (MPP_Config) | Spec-driven quality config |
| C13 | Audit Browser (optional, compliance support) | `/audit-log` (MPP_Config) | Audit trail with attribution + old/new values |

Existing captured config screenshots in `docs/screenshots/` may be reused if they still match the current UI and carry no customer identifiers — but a fresh capture from the showcase DB is preferred for consistency.

Capture output stored under `docs/showcase/screenshots/` (new folder). Report PDFs and their rasterized images under `docs/showcase/reports/`.

---

## 6. Deck Specification (slide-by-slide)

~14 slides. Built from the template; branding inherited. Each content slide: branded layout + screenshot(s) + a short (1–2 line) descriptive caption + speaker notes (talk track for the presenter). No selling language.

| # | Slide | Layout | Content |
|---|---|---|---|
| 1 | **Title** | Double Logo | "Track & Trace + Genealogy" / "Manufacturing Execution — Capability Showcase". Blue Ridge logo (from template). Subtitle/date optional. |
| 2 | Section: **Track & Trace** | Section Header | Divider. One-line framing: complete part genealogy, birth to shipment. |
| 3 | **LOT traceability** | Picture w/ Caption | C1 (LOT Detail). Caption: every lot carries its full production history, as-built BOM, and quality record. |
| 4 | **Full genealogy tree** | Picture w/ Caption | C2. Caption: forward + backward lineage — trace any finished good to its source material and vice-versa. |
| 5 | **Find any part** | Picture w/ Caption | C3 (LOT search). Caption: locate any lot and its complete history in seconds. |
| 6 | Section: **Live Movement** | Section Header | Divider. Framing: real-time WIP and validated material movement. |
| 7 | **Shop-floor movement** | Picture w/ Caption | C4. Caption: operators move material with barcode-validated, eligibility-checked transactions. |
| 8 | **Plant-wide WIP** | Picture w/ Caption | C5 (Supervisor). Caption: live inventory across every operation, one view. |
| 9 | Section: **Reporting** | Section Header | Divider. Framing: instant operational + traceability reporting. |
| 10 | **Reporting hub** | Picture w/ Caption | C6. Caption: on-demand PDF reports from the floor. |
| 11 | **Reports** | Two Content / Comparison | C7 (Lot Detail PDF) + C9 (Production Line Performance) or C8. Caption per image. |
| 12 | **Configuration** | Comparison / Two Content (2–3 tiled images) | C10 + C11 + C12 composited. Caption: the whole system is operator-configurable — plant model, parts, routes, quality specs — no code. |
| 13 | **Data Integrity & Compliance Foundation** | Title and Content | Capstone. The standards-mapping table (§7), careful "architected to support" framing. Optional inset of C13 (Audit Browser). |
| 14 | **Close** | Double Logo | Branded closing. Contact / "Transforming Manufacturing Beyond Limits" tagline (from template). |

Section dividers (2/6/9) are lightweight and may be trimmed if the reviewer prefers a tighter deck; content slides are the core.

---

## 7. Compliance Slide Content (slide 13)

**Framing rule (non-negotiable):** the deck claims the architecture is **designed / architected to support** these standards and **provides the record-keeping foundation** for them. It never claims the software is "compliant", "certified", or "validated" — those are validated-system + procedural determinations the customer makes.

**Header:** "Built on a Data-Integrity Foundation"
**Sub:** "Architected to support the record-keeping and traceability requirements of regulated manufacturing."

**Mapping (each row = one architectural capability the system already has → the standard concept it supports):**

| Architecture (already built) | Supports |
|---|---|
| Append-only event tables; full audit log capturing who/what/when with resolved old→new values | 21 CFR Part 11 audit trail; ALCOA+ (Attributable, Contemporaneous, Enduring) |
| Active-Directory authentication + per-action AD elevation for protected actions | Part 11 authority checks / electronic-signature-style authorization |
| No hard deletes (soft-delete/deprecation); UTC-stamped, immutable records | Record protection & retention; ALCOA+ Original/Enduring/Available |
| Full lot genealogy (forward + backward) + production-event history + as-built BOM | Device History Record traceability (21 CFR 820 / QMSR / ISO 13485) |
| Spec-driven quality + hold / nonconformance control | Nonconformance handling (820.90 / ISO 13485 §8.3) |
| Draft → Published → Deprecated version control on BOMs, routes, operation templates, quality specs | Controlled document / specification revision control |

**Accuracy gate:** before finalizing, each claimed feature is verified to exist in the current schema (grep the data model / migrations). Any row that cannot be substantiated is cut. Better a shorter honest table than an overclaim a medical-device auditor-minded audience will catch.

---

## 8. Build & QA Process

Follows the `pptx` skill.

1. Copy the template to the working deck. Do all **structural** work first: keep slides 1 (title) and 35 (closing) Double Logo; delete kickoff slides 2–34 via `<p:sldIdLst>`; add new feature slides on the branded layouts using `add_slide.py`; then `clean.py`.
2. Fill content (titles, captions, images, speaker notes). Insert screenshots sized to read cleanly with ≥0.5" margins; composited config slide tiles 2–3 images with consistent gaps.
3. **Content QA:** `markitdown` the deck; grep for leftover placeholder text (`[Name]`, `[Title]`, `lorem`, `[insert`, template bracketed tokens) — none may remain. Confirm no forbidden identity strings ("Honda", "Madison", "MPP", "AIM", OEM names) anywhere.
4. **File QA:** `python scripts/office/validate.py deck.pptx --original template.pptx`.
5. **Visual QA:** render to images (via PowerPoint COM on this Windows host — LibreOffice `soffice` fails in this sandbox) and inspect every slide fresh for overflow, overlap, low contrast, misaligned tiles, uneven gaps, and that every screenshot is legible.
6. Deliver the `.pptx` (and note it inherits the template's editable branded master so Jacques can tweak).

**Tooling note (this host):** `defusedxml`, `lxml`, `Pillow`, `python-pptx` installed. `markitdown` may need install. LibreOffice/`pdftoppm` unavailable — use installed **PowerPoint COM** (PowerShell) for `.pptx`→PDF/PNG rendering.

---

## 9. Risks & Caveats

- **Die-cast process visible in screenshots.** Intentional and fine — shown plainly as automotive aluminum die casting. Only customer/OEM identifiers are scrubbed; the process-agnostic compliance framing bridges to the medical-device audience.
- **Gateway swap coordination.** Requires Jacques for the datasource repoint (both directions). Bounded window; all data staged first. Fallback terminal → plant-wide queues (acceptable/beneficial).
- **Report render fidelity.** Reports render-verified previously; re-verify each renders non-empty against the showcase data before capture (date-spread in the seed is the dependency).
- **In-app browser cannot commit inputs.** Irrelevant here — all captures are read-only renders of pre-populated views/reports.
- **Overclaiming compliance.** Controlled by the §7 framing rule + accuracy gate.
- **No changes to `MPP_MES_Dev` or the committed project.** The showcase DB is separate; the deck and any capture assets live under `docs/showcase/`. Gateway datasource change is transient and reverted.

---

## 10. Deliverables

- `sql/scratch/seed_showcase.sql` — showcase seed (idempotent), + genericization.
- `MPP_MES_Showcase` database (local, transient — reproducible from reset + seed).
- `docs/showcase/screenshots/*` + `docs/showcase/reports/*` — capture assets.
- `docs/showcase/Track-and-Trace-Showcase.pptx` — the final branded deck.
