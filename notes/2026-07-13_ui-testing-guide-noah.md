# MPP MES — UI Testing Guide

**Audience:** Noah (and anyone smoke-testing the Perspective UI)
**Updated:** 2026-07-13
**Scope:** How to navigate every screen in the two Perspective apps, what each screen does, and what to verify. Ends with two full end-to-end "golden thread" walkthroughs.

---

## 0. The two apps

The MES is split across **two Perspective projects**. They share the `BlueRidge` script library and the same SQL database, but they're different UIs for different people.

| Project | Who uses it | Look & feel | How you open it |
|---|---|---|---|
| **MPP_Config** ("Config Tool") | Engineering / setup | Desktop, sidebar + header, 1920×1080 | Config Tool session URL, lands on `/` (Home) |
| **MPP** ("Shop Floor") | Operators at terminals | Touch, big buttons (`pf-*` design system), 44px targets | Shop-floor session URL, lands on `/` (HomeRouter) |

**Rule of thumb:** you *configure* parts, routes, BOMs, tools, locations, and users in the **Config Tool**. You *run production* (die cast → trim → machine → assemble → ship) on the **Shop Floor**. Configure first, then run.

---

## 1. Before you start (prerequisites)

- **SQL Server 2022** (or SQL Server Express) running locally, in **Mixed Mode authentication** (SQL + Windows). If it's Windows-only, switch it in SSMS → right-click the server → *Properties* → *Security* → *SQL Server and Windows Authentication mode*, then restart the SQL service.
- **`sqlcmd.exe`** on your PATH (ships with SSMS or the SQL Server client tools).
- The **repo** cloned locally (you'll run scripts from the `sql/` folder).
- **Ignition Gateway** running with both projects (`MPP`, `MPP_Config`) deployed/synced from the repo.

---

## 1b. Seeding your database (step by step)

One script drops, rebuilds, migrates, and seeds everything. You do **not** run migrations or seeds by hand.

**1. Open PowerShell and go to the repo's `sql` folder:**
```powershell
cd <your-repo>\MPP\sql
```

**2. Run the reset — WITH demo data (recommended for UI testing):**
```powershell
.\scripts\Reset-DevDatabase.ps1 -DatabaseName MPP_MES_Dev
```
- If your SQL instance is **not** `localhost` (e.g. a named Express instance), add `-ServerInstance ".\SQLEXPRESS"` (use your instance name).
- This uses your **Windows login** to connect. It will, in order: drop & recreate `MPP_MES_Dev`; create a SQL login **`ignition`** (password `ignition`, db_owner) for the gateway to use; run all **37 migrations**; deploy the stored procedures; load the config seeds (plant, the 3 part families, routes/BOMs/eligibility, code tables); and finally stage the **demo threads** (`seed_demo.sql`).

**3. Confirm it worked.** At the end you'll see `MPP_MES_Dev rebuild complete.` and a **"WHAT TO SMOKE"** checklist naming the exact demo LOTs and containers (a shipped 6NA container, WIP at every 6NA terminal, a serialized 5G0 container + a quality hold, an open pause/downtime, a received part). That checklist is your starting point for §6.

**Alternative — config only (clean slate, no LOTs):**
```powershell
.\scripts\Reset-DevDatabase.ps1 -DatabaseName MPP_MES_Dev -SkipDemoSeed
```
Loads all config but **no LOTs** — you create everything yourself by walking the flow (also tests every create path).

**Re-stage the demo data WITHOUT a full reset** (keeps your config, just refreshes the demo LOTs — it's idempotent: it wipes transactional data and rebuilds):
```powershell
sqlcmd -S localhost -d MPP_MES_Dev -E -b -I -C -i .\scratch\seed_demo.sql
```
(The `-I` flag matters — the Lot tables use filtered indexes and error without it.)

**4. Point Ignition at the database.** In the Gateway, the `MPP_MES` datasource should be:
- **Server:** your SQL instance (e.g. `localhost` / `.\SQLEXPRESS`)
- **Database:** `MPP_MES_Dev`
- **Login / password:** `ignition` / `ignition` (created by the reset script; **dev only**)

**5. Restart the Gateway after every reset.** A drop/recreate leaves the gateway holding a faulted DB connection — the UI loads but **all data comes back empty**. If a screen is blank where you expect data, restart the gateway before assuming it's a bug.

**Verify from the DB (optional):**
```powershell
sqlcmd -S localhost -d MPP_MES_Dev -E -C -Q "SELECT COUNT(*) AS Lots FROM Lots.Lot; SELECT COUNT(*) AS Items FROM Parts.Item;"
```
After a demo-data reset you should see ~20 LOTs and 14 items.

> ⚠️ `Reset-DevDatabase.ps1` **destroys and rebuilds** the target database. Only ever run it against your local dev DB — never staging/production.

---

## 2. Getting around

### Config Tool
- **Left sidebar** lists every config screen. **Top header** shows the current screen + user. Just click sidebar entries.

### Shop Floor
Shop-floor screens are normally reached by **scanning into a terminal**, but for testing you have two shortcuts:

- **Dev Launcher** — the **left dock** (pull it out from the left edge). It lists every shop-floor screen; click one to open it.
- **Type the route** in the browser address bar (see the full list in §5). E.g. `…/shop-floor/die-cast`.
- **Terminal Selector** (`/shop-floor/terminal-selector`) — the real entry point. Scan or pick a terminal; the session then "zones" to that terminal's cell/line.

### Dedicated vs. shared terminals (important)
Some screens come in two flavors — this is intentional, so test both if you can:
- **Dedicated** (e.g. `/shop-floor/die-cast/dedicated`, `/trim/dedicated`) — the cell/line comes from the terminal's zone. **No cell picker** is shown.
- **Shared** (e.g. `/shop-floor/die-cast`, `/trim`) — the operator **picks or scans** the cell. A cell picker sits inside the Active Cell card.

---

## 3. The demo parts (what you're building)

Three finished-good families are configured. Knowing these tells you what to expect in dropdowns and where each part is eligible.

**A. 5G0 Front Cover — SERIALIZED**
`5G0-c` (casting) → machined into `5G0-SA` → assembled with `21001 pin` into `5G0-FG` (finished good, serialized).
- Die cast at **DC1**; trim at **TRIM1**; machining + serialized assembly on line **MA1-5GOF**.
- Container: 4 trays × 12, serialized, closes **by count**.

**B. 59B Cam-Rocker Holder Set — NON-SERIALIZED (3 castings)**
`12231-59B-0000` + `12232-59B-0000` + `12241-59B-0000` (three castings) + `90701-5R0-3000` dowel → assembled into `1223A-59B -A0002`.
- Die cast at **DC2**; trim at **TRIM1**; assembly on line **MA2-59B**.
- Container: 4 trays × 15, closes **by weight** (75 lb target).

**C. 6NA Fuel Pump — NON-SERIALIZED (simplest end-to-end)**
`12270-6NA` (casting) → machined into `12270-6NA-M` → assembled with `92900-06014-1B` stud + `94301-08100` dowel into `12270-6NA -0001` (finished good).
- Die cast at **DC3**; trim at **TRIM1**; machining + assembly on line **MA1-FP6NA**.
- Container: 4 trays × 6, closes **by vision**.

> **"Parts per basket"** (Config Tool Item field) drives the die-cast piece-count prefill: 5G0-c = 24, the 59B castings = 30, 12270-6NA = 12.

---

## 4. Config Tool — screen-by-screen

For each screen: how to reach it, what it does, and what to verify.

### `/` — Home / Landing
Landing page with links into the config areas. **Verify:** links route correctly; header/sidebar render.

### `/plant` — Plant Hierarchy
The ISA-95 location tree (Enterprise → Site → Area → WorkCenter → Cell). **Verify:** tree expands/collapses; you can add/rename/reorder a location (up/down arrows — **no drag-and-drop anywhere**); deprecating a location soft-deletes it; edits prompt the unsaved-changes popup on close if dirty.

### `/items` — Item Master
The big one. Multi-section editor (Identity, Container, Routes, BOMs) with **per-section Save/Discard**. **Verify per section:**
- **Identity:** part number, description, type (Component/SubAssembly/FinishedGood), UOM, **Parts Per Basket**, sub-lot qty. Save, reopen, values persist.
- **Container Config:** trays/container, parts/tray, serialized flag, closure method (ByCount/ByWeight/ByVision), target weight.
- **Routes (versioned):** add a Draft version, add steps (each step = an **Operation Type**, e.g. DieCast/TrimIn/TrimOut/MachiningIn/MachiningOut/AssemblyOut), publish it. Only **one Published** route per item at a time. Switching item rows or tabs while a section is dirty should prompt the unsaved popup.
- **BOMs (versioned):** add child lines with qty-per; publish.
- **Eligibility:** which **Areas / Production Lines** the item is allowed at (eligibility is set at Area/Line tier, not individual cells/terminals — the cascade resolves cell scans up to those tiers).

### `/parts/operation-templates` — Operation Templates
Reusable operation definitions grouped by **Operation Category** and **Operation Type/role**, with data-collection fields. **Verify:** create/edit a template; the "Data Collection" column populates; templates are pickable when building a route.

### `/parts/tools` — Tools
Dies/tools, their **cavities**, and **assignments** to die-cast cells. **You need this for the die-cast walkthrough** (a die-cast cell needs a mounted tool + at least one Active cavity before you can shoot). **Verify:** create a tool, add cavities, assign it to a cell; the Cell Mount badge shows; you can release an assignment.

### `/quality-specs` — Quality Specs
Spec-driven inspection definitions (versioned). **Verify:** create/publish a spec with attributes + UOM.

### `/defect-codes` — Defect Codes
Reject/defect code table. **Verify:** create/edit/deprecate a code; the editor pre-populates cleanly (no `"null"` text / red borders).

### `/downtime-codes` — Downtime Codes
Downtime reason code table (bidirectional editor). **Verify:** create/edit/deprecate; inputs write back on save.

### `/users` — Users
AppUser table (AD account + initials). **Verify:** list, create, edit, deprecate.

### `/audit-log` — Audit Log
Read-only config-change history. **Verify:** every config change you made above appears here, with resolved names in Old/New values and readable `Subject · Category · Action` descriptions; timestamps are **Eastern**.

### `/failure-log` — Failure Log
Read-only stored-proc failure log (top procs / reasons). **Verify:** renders; empty is fine on a clean DB.

---

## 5. Shop Floor — screen-by-screen

Full route list with what each screen is for.

| Route | Screen | What it does / what to verify |
|---|---|---|
| `/shop-floor/terminal-selector` | **Select Terminal** | Scan/pick a terminal; session zones to its cell/line. **Verify:** the scan field + search bar are centered; typing in search filters the table **without error** (this one previously threw `Error_ExpressionEval` — re-confirm it's clean). |
| `/shop-floor/die-cast` (shared) `/die-cast/dedicated` | **Die Cast Entry** | Shoot castings on a die-cast cell. Item dropdown lists only items with a **DieCast route** that are **eligible at the cell**. Piece count prefills from **Parts Per Basket**. Record shots + scrap; reject entry is **cavity-scoped**. **Verify:** Active Cell card + cell picker (shared only); no stray scrollbars on Active Cell / Shots / shift-counts cards; cavity dropdown opens without resizing the bar; a part with no operation template is gated (can't run). |
| `/shop-floor/trim` (shared) `/trim/dedicated` | **Trim Station** | IN tab = LOTs currently in trim (card list); OUT tab = pick a LOT, enter shot+scrap, choose a **destination production line** (dropdown filtered to lines the item is eligible at), Trim OUT. **Verify:** shot+scrap **combined** can't exceed the LOT's current pieces; scrap **decrements** the LOT; after Trim OUT the LOT lands on the **line** and appears in that line's Machining IN queue; submitting does **not** bounce you to the LOT summary. |
| `/shop-floor/machining-in` | **Machining IN** | FIFO queue of unworked LOTs that arrived at the line; pick one to record the machining-in checkpoint. **Verify:** a LOT trimmed-out to this line shows here; picking it drops it off the unworked queue. |
| `/shop-floor/machining-out` | **Machining OUT (Split)** | Consume-mint: turn a casting into its machined sub-assembly LOT (mints the machined part, decrements the casting). **Verify:** partial mint keeps the casting open; full consumption closes it; the minted LOT is line-resident. |
| `/shop-floor/assembly-in` | **Assembly IN** | Stage components into an assembly line. **Verify:** the line's queue shows eligible incoming LOTs. |
| `/shop-floor/assembly-nonserialized` | **Assembly (Non-Serialized)** | Complete trays into a container; the FG dropdown lists eligible finished goods; parts-per-tray prefills. **Verify:** the FG/parts fields **keep prefilling after the container opens** (this regressed once); **tray position is auto-assigned** (no manual input); container auto-completes when full and mints a Shipping Label. |
| `/shop-floor/assembly-serialized` | **Assembly (Serialized)** | Same as above but each part gets a serial; used by the 5G0 family. **Verify:** serials mint + attach to the container; container fills by count. |
| `/shop-floor/receiving` | **Receiving** | Inbound receipt = create a `Received`-origin LOT with vendor LOT # + serial range, no tool/cavity. **Verify:** vendor LOT and serial range are captured; origin = Received. |
| `/shop-floor/shipping` | **Shipping Dock** | Ship a COMPLETE container (claims/shows its AIM Shipper ID). **Verify:** a completed container appears; Ship marks it shipped; AIM id is present. |
| `/shop-floor/sort-cage` | **Sort Cage** | Sort/rework workflow (update-in-place container serials). **Verify:** renders; serial history updates. |
| `/shop-floor/inspection` | **Inspection** | Record a quality sample against a spec. **Verify:** the spec's attributes render; a sample records. |
| `/shop-floor/hold-management` | **Hold Management** | Place/release quality holds on a LOT. **Verify:** placing a hold blocks production on that LOT; releasing clears it and restores prior status. |
| `/shop-floor/downtime` | **Downtime Entry** | Start/stop a downtime event at a line. **Verify:** start opens an event; it shows on the Supervisor screen; ending closes it. |
| `/shop-floor/end-of-shift` | **End of Shift** | Shift close-out entry. **Verify:** renders; submits. |
| `/shop-floor/shift-summary` | **Shift-End Summary** | Read: open downtime + in-process LOTs at the location, times in **Eastern**. **Verify:** counts match what you staged. |
| `/shop-floor/supervisor` | **Supervisor Dashboard** | Line overview + open downtime; end downtime from here. **Verify:** renders; matches staged state. |
| `/shop-floor/lot-search` | **LOT Search** | Search LOTs by name / vendor LOT / etc. **Verify:** vendor-LOT fragment matches; origin filter works; row → LOT Detail. |
| `/shop-floor/lot-detail/:lotId` | **LOT Detail** | Full LOT history: movements, scrap-per-movement, total scrap, status. **Verify:** history timestamps are **rounded** (MM/dd HH:mm), not over-precise; scrap totals add up. |
| `/shop-floor/genealogy` | **Genealogy Viewer** | Parent/child LOT tree (split/merge/consume edges). **Verify:** the tree matches what you split/merged. |
| `/shop-floor/trace` | **Track & Trace** | Global trace across the plant. **Verify:** renders; resolves a LOT. |
| `/shop-floor/aim-pool-config` | **AIM Pool Config** | The FIFO AIM Shipper ID pool. **Verify:** ids list; empty pool blocks container completion (by design — hard-fail). |

---

## 6. Golden-thread walkthroughs (end-to-end)

Do these to prove a part flows through the whole plant. If you used the **demo-data** reset (§1), the die-cast tools are already mounted and there's WIP at every terminal — you can jump straight to any screen and act on the staged LOTs. The steps below assume a **config-only** reset and build a fresh LOT from scratch (which also exercises every create path).

### Walkthrough A — 6NA Fuel Pump (non-serialized, simplest)

**One-time setup (Config Tool):**
1. `/parts/tools` → create a die (e.g. "6NA Base Die"), add **2 Active cavities**, and **assign it to a DC3 machine cell** (e.g. `DC3-M01`). *(Die cast needs a mounted tool + active cavity.)*
2. Confirm in `/items` that **`12270-6NA`** has a published DieCast→…→MachiningIn→MachiningOut route (it does, from the seed) and is eligible at **DC3**.

**Run it (Shop Floor):**
1. **Die Cast** (`/shop-floor/die-cast`, pick the DC3 cell) → select item `12270-6NA` → piece count prefills to **12** → record shots → a casting LOT is created at DC3.
2. **Trim** (`/shop-floor/trim`) → IN tab shows the casting → OUT tab: pick it, enter shot/scrap, destination line **MA1-FP6NA** → Trim OUT.
3. **Machining IN** (`/shop-floor/machining-in`, MA1-FP6NA) → the LOT is in the unworked queue → pick it (records the checkpoint).
4. **Machining OUT** (`/shop-floor/machining-out`) → consume-mint the casting into **`12270-6NA-M`** (machined). Casting decrements/closes; machined LOT is line-resident.
5. **Assembly (Non-Serialized)** (`/shop-floor/assembly-nonserialized`, MA1-FP6NA) → FG = **`12270-6NA -0001`**, parts/tray prefills to **6** → complete trays; consumes the machined part + fasteners → container fills (4 trays) → auto-completes → Shipping Label minted.
6. **Shipping** (`/shop-floor/shipping`) → the completed container appears with an AIM id → **Ship** it.
7. **Trace it:** `/shop-floor/lot-search` → find the FG → **LOT Detail** / **Genealogy** → confirm the chain casting → machined → FG → shipped container.

### Walkthrough B — 5G0 Front Cover (serialized)

Same shape as A but on the **DC1 / TRIM1 / MA1-5GOF** path, and assembly is **serialized**:
1. Config: mount a die on a **DC1** cell.
2. Die Cast `5G0-c` (prefill **24**) → Trim → destination **MA1-5GOF** → Machining IN → Machining OUT mints **`5G0-SA`**.
3. **Assembly (Serialized)** (`/shop-floor/assembly-serialized`, MA1-5GOF) → FG **`5G0-FG`** consumes `5G0-SA` + `21001 pin`; each part gets a **serial**; container fills **by count** (4×12) → completes.
4. Ship + trace as above.

### Side flows to exercise anytime
- **Receiving** (`/shop-floor/receiving`): receive `21001 pin` or a dowel with a vendor LOT # — proves inbound receipts.
- **Hold**: put a hold on an in-process LOT, try to advance it (should block), release the hold.
- **Downtime**: start a downtime at a line, end it from Supervisor.
- **Split/Merge**: split a LOT into sublots and merge two same-item LOTs; check Genealogy.

---

## 7. Known open items to re-verify

These were fixed file-side but flagged as **needing a smoke re-confirmation** (from `notes/2026-07-07_smoke_findings.md`). Please give them extra attention:

- **Die Cast — cavity dropdown resize:** opening the CAVITY dropdown used to visibly jump/resize the bar. Static width/overflow fix applied — confirm it no longer jumps.
- **Die Cast — cavity-scoped reject:** rejects charge the newest open LOT on the **selected cavity**. Open LOTs on cavities 1 & 2, select cavity 2, reject, confirm the cavity-2 LOT decrements (not cavity 1). *(Open question for Jacques: whether a reject should be allowed with NO open LOT at all — that's a schema change, not a UI bug.)*
- Anything on **LOT Detail Paused tab** timestamps (the History tab rounding was fixed; Paused tab may need the same treatment).

---

## 8. How to report what you find

For each issue, capture:
- **Screen + route** (e.g. "Die Cast, `/shop-floor/die-cast`").
- **Steps to reproduce** (part, cell, what you clicked).
- **Expected vs. actual.**
- **Any error text** — especially the Perspective error overlay (Subcode / Property / Description), and a screenshot.
- Whether it's a **UI/layout** issue or a **data/behavior** issue.

Drop them in the same format as `notes/2026-07-07_smoke_findings.md` so they're easy to triage and fix.
