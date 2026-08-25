# FAT Day 1 — Punch List, Findings & Open Questions

**Date:** 2026-08-18
**Branch:** `jacques/working`
**Source:** Jacques's punch list from the MPP FAT Day 1 session.

This document records, for each punch-list item: what the code/data actually does today
(with file references), what has already been decided, and the specific answers still
needed before build. Items are **not** implementation plans — each one that survives
triage gets its own spec.

---

## Answers still needed

| # | Item | Needed from | Question |
|---|---|---|---|
| 1 | BOM version on FG label | — | **DEFERRED** — further conversation required |
| 2 | Die list load | MPP / Jacques | Die→cavity roll-up rule; which statuses to load; Total vs Good shots for `ShotCount` |
| 2b | Die rank removal | Jacques | Cross-die merge gate: keep, drop, or replace? |
| 3 | IP auto-navigation | — | **DONE — root-caused + fixed.** Open: none |
| 4 | Production/inventory report | **DECIDED — building = Area; daily = shift-anchored (3rd → 1st → 2nd).** Open: none |
| 5 | Weekend shifts | **CLOSED — Jacques is creating the schedule in the existing editor. No build.** |
| 6 | User timeout | **DECIDED — 30 min operator, minute-based UI + UOM.** Open: none |
| 7 | Serialized-line validation number | Tom / MPP | **DETAILED** — see `2026-08-18_serialized-line-validation-number-brief.md` |
| 8 | Vision screen IP on location | **SHIPPED.** Open: confirm the derived station→terminal mapping |

---

## 1. BOM version number on the finished-good label — **DEFERRED**

**Status:** Deferred by Jacques pending a further conversation. Recorded here so the
findings are not lost.

**Format requested:** `00`, `01`, `02` — zero-padded two-digit, **not** `v1` / `v2` / `v3`.

### What exists today

Two label families:

| `Lots.LabelTypeCode` | Purpose | ZPL source |
|---|---|---|
| `Primary` (Id 1) | LOT Tracking Ticket (LTT), per-LOT | generic body seeded in `0021_arc2_phase2_lot_lifecycle.sql` |
| `Container` (Id 2) | **Honda container shipping label** | ported Honda body seeded in `0054_shipping_label_zpl_and_template.sql` |

The Honda label is rendered by
[`Lots.ufn_ShippingLabelZpl`](../sql/migrations/repeatable/R__Lots_ufn_ShippingLabelZpl.sql).
Its token set:

`{PartNumber}` `{Description}` `{MfgLotNumber}` `{MfgDate}` `{DcPartLevel}` `{Quantity}`
`{Serial}` `{Coo}` — plus `{PartNumberExt}`, `{DataMatrix}`, `{Auditor}` which are
**blank by design** (captions retained, no MES source).

**Neither label carries a BOM version today.** The `v1` / `v2` form Jacques saw is our
*display* convention — it appears in the LOT Detail header and in every audit
`Description` (`<PN> · BOM v2 · Published`), not on any label.

### The data is already captured

Migration `0047_lot_bom_asbuilt.sql` stamps `Lots.Lot.BomId` on the finished-good LOT at
mint time (`Assembly_CompleteTray`, `MachiningOut_Mint`), with a temporal backfill for
pre-existing LOTs. `Lots.Lot_Get` already surfaces `BomVersionNumber`. So this is a
**render change, not a data-model change**.

### The coupling that makes this urgent (see item 2)

The Honda label's **`D/C PART LEVEL (2P)`** field is currently fed by
`Tools.ufn_ContainerOriginDieRankCode` — a genealogy trace to the origin die's **die
rank**. Item 2 establishes that **die ranks do not exist at MPP**, so `Tools.DieRank`
stays empty and that function returns `''` — i.e. **2P will render blank on every
label**.

`00` / `01` / `02` is precisely Honda's native format for the D/C (design change) part
level. The strong hypothesis for the deferred conversation is therefore: **BOM version
replaces die rank in the 2P field.** That resolves both a blank field and the item-1
request in one change. To be confirmed.

### Open sub-questions for the deferred conversation

- Which label — Honda container label, LTT, or both?
- Which field — 2P, or a new field?
- Does the `00` format apply to the UI (LOT Detail header, audit descriptions) too, or
  labels only?

---

## 2. Die list — **we have the source; partial load is clean, cavity grouping is not**

**Source:** `reference/Die Shots Report.pdf` — 8 pages, "as of 8/6/2026", exported from
`backupsrv.mppnet.com/mpp/DieCast/DieShotsReport.aspx`.

Extract with `pdftotext -table` (the `-layout` mode interleaves columns and is unusable).

### Decisions taken (Jacques, 2026-08-18)

1. **The `Die` column is our `Tools.Tool.Code`.** It is MPP's naming convention for the
   different dies that produce the same part.
2. **Die rank is garbage and does not exist.** `Tools.DieRank` and
   `Tools.DieRankCompatibility` are to be left **empty**. `Tools.Tool.DieRankId` stays
   `NULL`.
3. The `Part` column is `<6-digit code>. <model identifier> <description>` — the 6-digit
   code's meaning is unknown, but the **model identifier** immediately after it (`5GO`,
   `RPY`, `59B`, `6MAA`, …) is the family name we should recognise.
4. Multiple rows can belong to the same physical die, representing different **cavities**
   (different parts produced by one die).

### What the report contains

| Column | Example |
|---|---|
| Status | `B` / `C` / `W` (legend: Waiting for Approval, Approved, Current, Backup, OutSourced) |
| Part | `152-090. 59B Base Comp Fuel Pump` |
| Die | `N`, `Q`, `G`, `II/JJ`, `7`, `1`, `A & B` |
| Total Shots / Good Shots | `25493` / `24553` |
| Shot Life Planned | `200000` |

Grouped by customer: Aisin, American Honda, Astemo, Elesys, EMP, FPI, Honda,
Honda Alabama, Honda Anna Eng Plnt.

Footer: *Total Dies in Mass Production: 103; Total Dies over Planned Life: 227*.

### Parse results

- **343 data rows, all 343 parse cleanly** once the `Die` token is allowed to contain
  spaces — one row carries a two-token die identifier:
  `C  644-090. 6FB Holder Comp, No 1 Cam R   A & B   278147  266640  100000`.
  A structured extract is committed at **`reference/seed_data/die_shots_report.csv`**
  (343 rows) with columns `Customer, StatusCode, Status, PartCode6, ModelIdentifier,
  PartDescription, Die, TotalShots, GoodShots, ShotLifePlanned`.
- **104** distinct 6-digit codes
- **31** distinct die tokens
- **41** distinct model identifiers — of which ~9 are not real model codes but the first
  word of a non-Honda part name (`CASE`, `Cover`, `Inner`, `HEAT`, `CIVIC`, `B`, `C`, …),
  from the Astemo / Elesys / EMP / Aisin rows. The "model identifier" rule holds for
  Honda-family parts only.
- **`(6-digit code, Die)` is unique across all 343 rows** — this is a reliable natural key.

### Cavity grouping — tested, and it does **not** resolve cleanly

Two hypotheses were tested against the data:

**Hypothesis A — a die is `(model identifier, Die letter)`.** Produces 140 groups; 38 have
more than one part. **Rejected**, on two counts:

- Shot counts *differ* between parts inside 36 of the 38 multi-part groups. A single
  physical die would share one shot count across its cavities (unless MPP genuinely
  counts per-cavity — see the open question).
- It over-groups. `59B / die N` collects `152-090 59B Base Comp Fuel Pump`
  (life 200000) together with `187–196 59B In Cam No 1–5 / Ex 1–5` (life 0). Those are
  plainly different physical dies that happen to share the letter `N` within the 59B
  family.

**Hypothesis B — a die family is the set of part-codes sharing an identical set of die
letters.** Produces 41 families covering all 104 codes; 18 multi-part, 23 single-part;
**124 implied physical dies** (vs. the footer's 103 *in mass production*, which is
plausible since the footer excludes non-mass-production statuses). This one is much more
convincing on the strong cases:

```
dies H,J,K,L,M,N   -> 10 cavities: 187..196   (59B In Cam No 1-5 / Ex 1-5)
dies A,B,C,D,F     -> 10 cavities: 652..661   (6MAA HOLDCOMP NO1 INTAKE ...)
dies D,F,G,H       ->  8 cavities: 125..128, 131..134  (RPY Holder Comp Ex Cam)
dies G,H,I,J,K     ->  5 cavities: 135..138, 624       (RPY Holder Comp Rkr Shaft)
```

**But it also fails**, on two counts:

- **Singleton sets collapse unrelated parts.** `dies A -> 8 cavities: 559, 645, 679, 680,
  681, 682, 683, 686` sweeps `RXO oil pan` in with the Astemo `Cover Inverter` /
  `Inner Housing` parts purely because each happens to have only one die, lettered `A`.
- **13 `(model, die-letter)` collisions across families** — e.g. `RPY / die G` appears in
  four different families (`D,E,F,G`, `G,H,I,J,K`, `D,F,G,H`, `D,F,G`). So
  `<model>-<die>` is not a unique code either.

**Conclusion: the report alone cannot cleanly determine the die→cavity structure.**
The only thing it supports reliably is one row = one `(part, die)` pair.

### Recommended path

Load at the level the data actually supports, and ask MPP for the rest:

- One `Tools.Tool` per `(6-digit code, Die)` row — 343 rows (342 if the `A & B` row turns
  out to be two dies rather than one).
- `Code` = `<6-digit>-<Die>` (e.g. `152-N`); `Name` = `<desc> (Die <letter>)`.
- `ShotCount` and `ShotLifeLimit` from the report; `DieRankId` = `NULL`.
- **Defer cavity roll-up** until MPP supplies the die master, or confirms a rule.

This gets the die identifiers into the system (which is what the Die Cast screens and the
Die Cast Shot Count report need) without inventing a grouping we cannot defend.

### Open questions

- **Cavity roll-up.** Can MPP export the die master with an explicit die key, so cavities
  roll up correctly? Failing that: is per-cavity shot counting real at MPP (which would
  make hypothesis B correct and the differing counts *expected*)?
- **Mapping to our parts.** The `Part` column is an MPP die descriptor
  (`152-090. 59B Base Comp Fuel Pump`), **not** `Parts.Item.PartNumber`. A mapping rule is
  needed before dies can be linked to items. Does the 6-digit code exist anywhere in MPP's
  part master?
- **Which statuses to load** — all 343, or only Current / Backup / Approved (skip `W`
  Waiting-for-Approval and OutSourced)?
- **`Tool.ShotCount` source** — `Total Shots` or `Good Shots`? The Die Cast Shot Count
  report reads the materialized `Tools.Tool.ShotCount`.
- **The `A & B` row** — is that one die spanning two identifiers, or a data-entry artefact?

---

## 2b. Consequences of dropping die rank

Confirming "die rank is garbage" has three downstream effects worth deciding on:

**(a) The only true seeding blocker dissolves.**
`MPP_MES_SEEDING_REGISTRY.md` lists **S-08 (Die Rank Compatibility Matrix)** as the single
**true blocker** in the whole registry. If ranks do not exist, S-08 and S-07 (Die Ranks)
are both **cancelled**, and the registry drops to zero blocking items. The registry should
be updated to say so.

**(b) `Lots.Lot_Merge`'s cross-die gate becomes inert — safely, but silently.**
[`R__Lots_Lot_Merge.sql`](../sql/migrations/repeatable/R__Lots_Lot_Merge.sql) §8 only runs
the compatibility check when the source LOTs carry **2+ distinct non-NULL `DieRankId`s**.
With every `DieRankId` NULL the rank set is empty, the check is skipped, and
**all cross-die merges are permitted without supervisor override**. No error, no
regression — but also no gate.

> **Decision needed:** is an unrestricted cross-die merge acceptable? If MPP wants *any*
> cross-die control, the gate has to key off something that does exist — most naturally
> the `ToolId` itself (merge only within one die, supervisor override otherwise). If not,
> the rank-check block should be removed rather than left as dead code.

**(c) The Honda label's `D/C PART LEVEL (2P)` field goes blank.** See item 1 — this is the
coupling that makes the deferred BOM-version conversation worth having soon.

---

## 3. IP-based auto-navigation to terminals — **validate end to end**

**Scope agreed:** validate the whole path end to end. On the production test **even
localhost would not resolve**. Failure mode is simple.

### The path, as built

```
onStartup(session)                              MPP/…/startup/onStartup.py
  -> Terminal.getByIpAddress(session.props.address)
  -> Location.Terminal_GetByIpAddress            R__Location_Terminal_GetByIpAddress.sql (v1.2)
       -> Location.ufn_NormalizeIpAddress        both sides normalised
       -> match on Terminal (LTD 7) attr 'IpAddress', else FALLBACK-TERMINAL row
  -> Terminal.applyToSession(session, term)      Core/…/BlueRidge/Location/Terminal/code.py
       sets session.custom.terminal / printer / plcDevices / closureMethod
            / closureCapabilities / policy; clears cell
  -> page "/" = HomeRouter -> root onStartup -> self.route()
```

`HomeRouter.route()` is correct as written:

```python
t = self.session.custom.terminal
if (not t.terminalLocationId) or t.isFallback:
    system.perspective.navigate("/shop-floor/terminal-selector")
    return
if t.defaultScreen:
    system.perspective.navigate(t.defaultScreen)
    return
```

The same `applyToSession` resolver also backs the NavigationTree launch and the Terminal
Selector, so the three entry points cannot drift.

### What is already known

- **Only 8 distinct IPs are seeded, across 16 attribute rows, for 67 terminals.**
  [`011_seed_locations_mpp_plant.sql:1856+`](../sql/seeds/011_seed_locations_mpp_plant.sql)
  carries the `MPP_Terminal_Printer_Inventory.xlsx` overlay: `172.17.14.117`,
  `172.17.14.169`, `172.17.14.211`, `172.17.14.232`, `172.17.20.55`, `172.17.20.57`,
  `172.17.20.115`, `172.17.20.162`. Every other terminal falls to `FALLBACK-TERMINAL`.
- **Localhost failing to resolve on the prod test is expected behaviour, not a defect** —
  unless a terminal was actually configured with `127.0.0.1`. `ufn_NormalizeIpAddress`
  collapses `::1`, `0:0:0:0:0:0:0:1`, `[…]`-bracketed and IPv4-mapped forms to
  `127.0.0.1`, but there still has to be a Terminal row *holding* `127.0.0.1` for a match.
  Worth confirming which DB the prod test ran against, and whether that row existed.
- A **fallback** terminal has `zoneLocationId` = the whole Madison Facility, which
  produces plant-wide queue reads and false "not eligible at destination" errors. The tell
  is the station subtitle reading "Madison Facility".

### Validation to run end to end

1. Confirm `session.props.address` as observed — grep the gateway `wrapper.log` for
   `ipAddress=` (the `getByIpAddress` wrapper logs it on every session start).
2. `Location.ufn_NormalizeIpAddress` — unit-check each form: dotted quad, `::1`,
   `[0:0:0:0:0:0:0:1]`, `::ffff:a.b.c.d`, zone-suffixed.
3. `Location.Terminal_GetByIpAddress` — registered IP resolves to its terminal;
   unregistered IP returns the fallback row with `IsFallback=1`.
4. `applyToSession` — terminal, printer, PLC devices, closure method/capabilities, policy
   all populated; `cell` cleared.
5. `HomeRouter.route()` — registered terminal lands on its `DefaultScreen`; fallback lands
   on the terminal selector.
6. A **loopback terminal** configured with `127.0.0.1` resolves from the gateway host
   itself (this is the case that failed on the prod test).

### ROOT CAUSE (validated 2026-08-18) — nothing was broken

The SQL layer is **provably correct**. `Run-Tests -Filter 0020_PlantFloor_Foundation` →
**142 passed / 0 failed**, including 26 assertions specifically covering this path:

- `[TermCell]` / `[TermArea]` — a known IP resolves its terminal, zone and DefaultScreen,
  `IsFallback = 0`
- `[TermUnknown]` — an unknown IP returns exactly one row, the FALLBACK terminal,
  `IsFallback = 1`
- `[TermDepr]` — a deprecated terminal's IP is not matched
- `[IpNorm]` ×9 — bracketed IPv6 loopback, compact `::1`, expanded
  `0:0:0:0:0:0:0:1`, IPv4-mapped and bracketed IPv4-mapped all resolve correctly, with
  no over-matching
- `[IpNorm][ufn]` ×6 — the normalizer itself, including NULL-in/NULL-out

`MPP_MES_Dev` confirms `Location.Terminal_GetByIpAddress` is at **v1.2** with
`Location.ufn_NormalizeIpAddress` present.

**So why did localhost fail at the prod test?** Because **no terminal is configured with
`127.0.0.1`.** Every configured IP in the plant model is a real plant address:

| Terminal | IP |
|---|---|
| `MA2-59B-MIN` | `172.17.14.117` |
| `MA2-64AOP-AOUT` | `172.17.14.232` |
| `MA2-6FBCHOP-MIN` | `172.17.14.169` |
| `MA2-6MACH-AOUT1` | `172.17.20.55` |
| `MA2-6MACH-AOUT2` | `172.17.20.57` |
| `MA2-6MACH-MIN` | `172.17.14.211` |
| `MA2-6MAOP-AOUT` | `172.17.20.115` |
| `MA2-RPYCAM2-AOUT1` | `172.17.20.162` |
| `TT-00` (hand-added in Dev) | `11.11.1.11` |

A session on the gateway host normalizes to `127.0.0.1`, matches nothing, and correctly
returns the fallback. **The system did exactly what it was built to do — there was simply
nothing to match.** The defect was that it did so *silently*, so the demo looked broken.

### Fixes shipped

**1. The selector now diagnoses itself.** `BlueRidge/Views/ShopFloor/TerminalSelector`
gains an `UnregisteredBanner` (`psc-pf-banner` family, `mpp/warning` icon), `meta.visible`
bound to `{session.custom.terminal.isFallback}`, whose detail line reads:

> The gateway sees this device as **`{session.props.address}`** and no terminal carries
> that address. Pick your terminal below, or ask Engineering to register this IP.

That turns the exact FAT failure into a screen that explains itself and hands the
engineer the value they need to fix it.

**2. `sql/scratch/register_loopback_terminal.sql`** — points one chosen terminal's
`IpAddress` at `127.0.0.1` so a session opened **on the gateway host** resolves to a real
terminal. Scratch, deliberately **not** a seed: shipping `127.0.0.1` to a plant terminal
would make every gateway-host session claim to be that terminal. Includes a guard that
refuses to create a *second* loopback terminal (`Terminal_GetByIpAddress` tie-breaks
duplicates by lowest `LocationId`, so a stray second one would silently win) and an UNDO
block.

**Verified end to end against `MPP_MES_Dev`:**

```
EXEC Location.Terminal_GetByIpAddress @IpAddress = N'[0:0:0:0:0:0:0:1]'
-> 15 | DC1-T1 | Terminal | 3 | DC1 | Die Cast 1 | /shop-floor/die-cast | IsFallback=0
```

So `HomeRouter.route()` will now navigate a gateway-host session straight to
`/shop-floor/die-cast`. The duplicate guard was also exercised (a second terminal set to
`::1` was correctly refused, proving normalization applies inside the guard too).

### Still owed / not verified

- **The live browser leg (steps 1, 4, 5) is not verified** — the local gateway's
  Perspective client trial has expired. `session.props.address` observed form,
  `applyToSession` population and the `HomeRouter` navigate need one human pass once the
  trial is reset.
- **Owed from MPP:** an updated terminal↔IP inventory for the remaining ~59 terminals.
  Until then most terminals resolve to fallback — which now at least *says so*.

---

## 4. Report — production totals by building + daily + current inventory

**Decision taken (Jacques, 2026-08-18): building = Area.** Die Cast has 4 areas
(`DC1`–`DC4`). No new location tier is needed — the earlier concern about the model
lacking a "building" concept is resolved.

This is a large simplification. The plant hierarchy is Enterprise → Site → **Area** →
WorkCenter → Cell, and every area already hangs directly off `MPP-MAD` (Madison Facility):

| Area code | Name | Kind |
|---|---|---|
| `DC1` – `DC4` | Die Cast 1–4 | ProductionArea |
| `TRIM1`, `TRIM2` | Trim Shop 1–2 | ProductionArea |
| `MA1`, `MA2` | Machining & Assembly 1–2 | ProductionArea |
| `WHSE` | Warehouse | SupportArea |
| `SHIPIN`, `SHIPOUT` | Shipping IN / OUT | SupportArea |

Offsite lines are `OS-*`.

### What already exists

The Reporting Module suite (built 2026-08-10) already ships:

- **Current Inventory** — plantwide WIP snapshot by item and location (`reportPath` `Inventory`)
- **Production Line Performance** — weekly output, scrap and downtime by process line

So this item is closer to "extend and add an area roll-up" than "build from scratch".
Registry: `BlueRidge.Reports.registry()` in
[`Core/…/BlueRidge/Reports/code.py`](../ignition/projects/Core/ignition/script-python/BlueRidge/Reports/code.py).

### DECISION (Jacques, 2026-08-18) — **shift-anchored production day**

A production day runs **3rd → 1st → 2nd**. So the day begins with 3rd shift (which starts
the previous calendar evening and crosses midnight) and the totals for a given day are the
sum of those three shift instances — *not* a `CAST(... AS DATE)` cut, which would split 3rd
shift across two rows.

Implication for the report: group on the **shift instance** (`Oee.Shift`), and derive the
production date from the day the 3rd-shift instance's *scheduled* day belongs to, rather
than from any event timestamp. `Oee.Shift_Reconcile` already materializes one `Oee.Shift`
row per scheduled instance, so the grouping key exists.

**Spec written:** `docs/superpowers/specs/2026-08-18-production-and-inventory-by-area-design.md`. Two decisions flagged for confirmation there — whether a production day is labelled by the shift it *ends* in, and whether "production" means throughput per area (double-counts a piece across the areas it passes through) or pieces minted (sums to plant output, but reports Trim as zero).

---

## 5. Downtime calculations vs. weekend shifts that rarely run — **a real gap**

### The mechanism

1. `Oee.ShiftSchedule.DaysOfWeekBitmask` — Mon=1, Tue=2, Wed=4, Thu=8, Fri=16, Sat=32,
   Sun=64. If Sat/Sun are not in any schedule's bitmask,
   [`Oee.Shift_GetActive`](../sql/migrations/repeatable/R__Oee_Shift_GetActive.sql)
   returns **no row** for that moment.
2. [`Oee.Shift_Reconcile`](../sql/migrations/repeatable/R__Oee_Shift_Reconcile.sql)
   (gateway-timer driven) branch **(D)**: *"open the active instance; NULL active = gap =
   no open"*. On a weekend with no scheduled shift, **no `Oee.Shift` runtime instance is
   open**.
3. [`Oee.DowntimeEvent_Start`](../sql/migrations/repeatable/R__Oee_DowntimeEvent_Start.sql)
   line 96: `SELECT TOP 1 @ShiftId = Id FROM Oee.Shift WHERE ActualEnd IS NULL` →
   **`ShiftId` lands `NULL`**. The column is nullable; no error is raised.
4. `Oee.DowntimeEvent_GetByScope` filters `de.ShiftId = @Shift` → the weekend downtime
   **silently disappears** from the Downtime-by-Shift report and from any shift-based OEE
   availability rollup. It survives only in Downtime by Date Range.

### Blast radius beyond downtime

The same shift anchoring applies to production capture:

- `Lots.Lot_GetShiftCavityTally`
- `Workorder.DieCastShiftOutput_Record`
- `Workorder.DieCast_GetShiftOutputBreakdown`
- `Oee.EndOfShiftEntry_Submit`, `Oee.ShiftHandover_Acknowledge`
- `Oee.DowntimeEvent_RecordApproximate` — builds a **shift-anchored nominal window**;
  with no open shift this path needs its own check.

So a weekend run today produces downtime and production that are invisible to every
shift-scoped read.

### Options

| | Approach | Cost | Trade-off |
|---|---|---|---|
| **A** | Add Sat/Sun to the existing schedules' bitmasks | Config only, zero code | A shift instance opens every weekend whether or not anyone runs → availability denominators polluted with 100 %-downtime shifts |
| **B** | Add an explicit "Weekend" `ShiftSchedule`, enabled when a weekend run is planned | Config only | Honest and clean, but depends on someone remembering to enable it |
| **C** | On-demand shift creation — if downtime/production is recorded with no open shift, open one against the best-matching or a synthetic "Unscheduled" schedule | Code change | Self-healing, but adds a write path to read-shaped procs |

### DECISION (Jacques, 2026-08-18) — **Plan B**

> Create a weekend shift schedule, and if an event gets logged against that time, include it.

So: an explicit weekend `Oee.ShiftSchedule` exists permanently (`DaysOfWeekBitmask` covering
Sat and/or Sun). `Shift_Reconcile` then opens a runtime `Oee.Shift` instance for it like any
other shift, `DowntimeEvent_Start` attaches to it normally, and everything shift-scoped —
downtime reports, cavity tallies, die-cast shift output, end-of-shift entry — works with no
code change. Weekend activity is captured because the shift exists; weekends with no activity
simply produce an instance with nothing in it.

**Scope of work:**

1. Author the weekend `ShiftSchedule` row(s) — via the existing MPP_Config
   **Shift Schedules** editor (`MPP_Config .. Views/Oee/ShiftSchedules`) or a seed.
2. Add the **guard**: surface, rather than swallow, an event that lands with
   `ShiftId IS NULL`. Today `DowntimeEvent_Start` silently writes NULL and the event
   vanishes from every shift-scoped read. Even with a weekend schedule in place, a
   schedule gap at any other time reproduces the bug — so this stays worth doing.

### CLOSED (Jacques, 2026-08-18) — no build required

> "We can create the shift schedule, you don't need to build that. We actually built it in
> already."

The weekend schedule is authored through the existing MPP_Config **Shift Schedules**
editor. Nothing to implement.

**Note kept for the record:** `INSERT INTO Oee.ShiftSchedule` appears in this repo **only
in test fixtures** — there is no production seed, by design; schedules are configuration,
entered through the editor.

**The one code-side item that survives** (small, optional): `DowntimeEvent_Start` writes
`ShiftId = NULL` silently when no shift instance is open, and `DowntimeEvent_GetByScope`
then filters that event out of every shift-scoped read. With a weekend schedule in place
the common case is covered, but *any* future schedule gap reproduces the disappearance.
Surfacing it rather than swallowing it remains worth doing.

---

## 6. User timeout configuration

### What exists

`Location.SessionPolicy` (migration `0049_session_policy.sql`) — a **single global row**:

| Column | Default | Bounds (CHECK) |
|---|---|---|
| `OperatorPresenceTimeoutSeconds` | 180 (3 min) | 30–3600 |
| `ElevationTimeoutSeconds` | 300 (5 min) | 30–3600 |

Plus `UpdatedAt` / `UpdatedByUserId`, and an `Audit.LogEntityType` row `SessionPolicy`.

Read/update procs exist: `R__Location_SessionPolicy_Get.sql`,
`R__Location_SessionPolicy_Update.sql`. Test coverage:
`sql/tests/0020_PlantFloor_Foundation/030_SessionPolicy_crud.sql`.

Loaded into `session.custom.policy` by `BlueRidge.Common.Session.loadPolicyIntoSession`,
called from `Terminal.applyToSession` on **both** the fallback and registered-terminal
paths — so every session gets it.

Elevation uses a **rolling** window: `touchElevation()` pushes the deadline forward on
activity; expiry calls `resetTerminal()`, which drops elevation *and* the operator,
returns to the default screen and prompts for initials.

### Three candidate problems

1. **There appears to be no UI to edit it.** The table, procs, audit entity and session
   loader all exist, but no Config-Tool editor screen was found. If that is right,
   "configuring" the timeout today means a direct SQL update.
2. **It is global, not per-terminal.** A Die Cast entry terminal and a supervisor's
   configuration workstation share one 3-minute presence timeout. Is that acceptable, or
   does this need to be per-terminal / per-area?
3. **Perspective's own session idle timeout is separate.** The gateway's project session
   timeout can log the whole session out from underneath our presence timer. Worth
   confirming the two are not fighting.

> **Correction to the first pass of this document:** an editor **does** exist. It is the
> `SessionPolicyPanel` on the Config-Tool **Users** page
> (`MPP_Config .. Views/Audit/Users`) — an eyebrow reading *"Session timeouts (global,
> seconds)"*, two `ia.input.text-field`s bound bidirectionally to
> `view.custom.policy.operatorPresenceTimeoutSeconds` / `.elevationTimeoutSeconds`, and a
> "Save timeouts" button calling `handleSavePolicy`. The view's `onStartup` loads the row
> via `SessionPolicy.getPolicy()`. Point 1 above ("no UI") was wrong.

### DECISION (Jacques, 2026-08-18)

1. **Operator-presence timeout = 30 minutes** (was 3).
2. **Both fields become minute-based in the UI**, with the unit of measure shown.

**Storage stays in seconds.** Seconds is the unit `BlueRidge.Common.Session` computes with
(`* 1000` for the epoch-ms deadline) and the unit both `CK_SessionPolicy_*` constraints are
written against; converting the columns would ripple through the proc, the named query, the
session module and the tests for a purely cosmetic gain. The minutes change is a
**presentation** change made at the editor boundary.

Effect on bounds: the CHECKs permit 30–3600 s. Whole-minute entry narrows the practical
range to **1–60 minutes**, every value of which is legal under the unchanged constraints.
The only thing that becomes unreachable from the UI is a sub-minute timeout, which is not a
setting MPP wants. Constraints deliberately left alone.

### Work done — SHIPPED

- **`sql/migrations/versioned/0062_session_policy_operator_30min.sql`** — sets the live row's
  `OperatorPresenceTimeoutSeconds` to 1800 and raises the shipped
  `DF_SessionPolicy_OpTimeout` default 180 → 1800 so a fresh deployment starts correct.
  Elevation unchanged at 300 s. Idempotent, guarded on `dbo.SchemaVersion`.
- **`BlueRidge.Common.Session`** — the two operator-presence fallbacks (`or 180`) raised to
  `or 1800`, so a missing policy row degrades to 30 min rather than 3.
- **`BlueRidge.Location.SessionPolicy.getPolicy`** — shaped fallback raised to
  `{OperatorPresenceTimeoutSeconds: 1800, ElevationTimeoutSeconds: 300}`.

- **`MPP_Config .. Views/Audit/Users`** (file-authored, Designer closed, then `scan.ps1`):
  - `onStartup` divides the loaded seconds by 60 into `operatorPresenceTimeoutMinutes` /
    `elevationTimeoutMinutes`.
  - `OpInput` / `ElevInput` bidirectional bindings repointed to the minute keys.
  - `view.custom.policy` default reshaped to minutes (`30` / `5`).
  - Labels carry the UOM: eyebrow "Session timeouts (global)", fields
    **"Operator presence (min)"** and **"Elevation (min)"**.
  - `handleSavePolicy` converts minutes → seconds via `Common.Util.toIntOrNone`, and
    refuses to save with an error toast if either field is blank or non-numeric rather
    than writing a silent fallback.

### Verification

- Migration applied to `MPP_MES_Dev`; row reads `OperatorPresenceTimeoutSeconds = 1800`,
  `ElevationTimeoutSeconds = 300`; `DF_SessionPolicy_OpTimeout` now `((1800))`.
- Re-run is clean (exit 0). The first cut of the migration was **not** idempotent — a
  top-of-file `IF EXISTS ... RETURN` guard only exits its own batch, so the
  `dbo.SchemaVersion` insert still ran and raised Msg 2627. Fixed by guarding that insert
  with `IF NOT EXISTS`. **The same latent flaw exists in `0049_session_policy.sql`** (and
  possibly other migrations using that guard shape) — harmless while migrations only ever
  run against a freshly dropped database, but worth a sweep.
- `view.json` re-parses as valid JSON; diff is 18 lines, no pickled runtime data.
- **Not render-verified** — the Perspective client trial on the local gateway has expired
  ("Your Perspective client trial period has expired"). Needs a gateway admin to start a
  new 2-hour trial before the panel can be eyeballed. Note that the in-app browser cannot
  commit input bindings anyway, so the Save round-trip needs a human.

### Still worth deciding separately

- **The policy is global, not per-terminal.** A Die Cast entry terminal and a supervisor's
  configuration workstation share one timeout. Acceptable, or per-terminal / per-area?
- **Perspective's own session idle timeout is separate.** The gateway's project session
  timeout can log a session out from underneath our presence timer — worth confirming the
  two do not fight, now that ours is 30 minutes.

---

## 7. What number validates serialized lines — question for Tom

**Owner:** Jacques to send Tom; answer owed by MPP.

### What we know from the touchpoint agreement

From `reference/5GO_AP4_Automation_Touchpoint_Agreement.md`:

- The tag is **`PartSN`** (Read, String): *"Serial Number is set in automation and is to be
  collected by MES upon DataRdy."*
- It is read **from the Laser Marker over serial comms**. On a failed read the automation
  sets `PartSN` to the literal string `"NoRead"`.
- MES then validates **format validity** and **uniqueness (duplicate check)**, and writes
  `PartValid` back to the PLC.
- `MESInterlockEnable` (Read/Write) toggles whether MES enforces its checks at all.
  `HardwareInterlockEnable` (Read) toggles the automation-side checks.
- Station designations: **5GO** = serialized (uses laser marker); **PNA** = lot-tracked,
  no serial number.

### Our side

[`BlueRidge.Workorder.AssemblyPlc`](../ignition/projects/Core/ignition/script-python/BlueRidge/Workorder/AssemblyPlc/code.py)
holds the orchestration skeleton with `_WATCH = []` — a deliberate no-op until
commissioning supplies the per-line tag map. The documented per-piece flow is: read/mint
`PartSN` → validate uniqueness → write `PartValid` → `ContainerSerial.serialAdd` →
`ConsumptionEvent.recordWithBomCheck` → tray/container close.

### The question to send

> What is `PartSN` actually made of on the serialized lines?
>
> 1. **Format and length** — what is the mask? Is it Honda-assigned, MPP-assigned, or a
>    laser-marker sequence? An example of a real value would settle most of this.
> 2. **Uniqueness scope** — must it be unique **globally**, **per part number**, or
>    **per line per day**? This determines the index we build and what counts as a
>    duplicate.
> 3. **Is it the same number the Cognex vision reads** at the tray stations, or a
>    different identifier?
> 4. **Which lines are serialized** — 5GO only, or others?
> 5. What should MES do on a `"NoRead"` — reject the piece, accept it unserialized, or
>    hold it?

Can be drafted as a formal email like
[`notes/2026-08-07_mpp-email-honda-trace-export.md`](2026-08-07_mpp-email-honda-trace-export.md)
on request.

---

## 8. Vision screen IP configurable on the location — **mostly already built**

### What exists

`VisionAppUrl` is **already** a Terminal (LocationTypeDefinition 7) location attribute:

- Defined in migration `0041_closure_terminal_and_plc_capability.sql` alongside
  `CurrentClosureMethod`
- Read by
  [`Location.Terminal_GetClosureContext`](../sql/migrations/repeatable/R__Location_Terminal_GetClosureContext.sql),
  which returns `{CurrentClosureMethod, VisionAppUrl, ClosureCapabilities}`
- Stamped onto `session.custom.terminal.visionAppUrl` by `Terminal.applyToSession`
- Test coverage: `sql/tests/0020_PlantFloor_Foundation/030_closure_capability_seed.sql`
  and `031_Terminal_GetClosureContext.sql`

So the schema, the read proc and the session plumbing are all done.

### What is missing

**No editor field** for it in the Plant Hierarchy UI — the same gap as `SessionPolicy` in
item 6. Today it is configurable in the database, not in the application. That matches the
punch-list wording ("need to be able to configure that on the location").

### DECISION (Jacques, 2026-08-18) — **it is just the IP**

The location attribute captures an **IP address only**; the application composes the URL.

**Consumers to update.** `visionAppUrl` is read in exactly two places, both as a direct
expression binding on an inline-frame `props.url`:

- `BlueRidge/Views/ShopFloor/AssemblyNonSerialized` → `props.url` ← `{session.custom.terminal.visionAppUrl}`
- `BlueRidge/Views/ShopFloor/AssemblySerialized` → `props.url` ← `{session.custom.terminal.visionAppUrl}`

**Approach:** keep `session.custom.terminal.visionAppUrl` as the *composed* URL so neither
assembly view changes, and compose it from the stored IP in
`Location.Terminal_GetClosureContext` (SQL — consistent with "no business logic in Python").
The stored attribute becomes the IP; the session property stays the URL.

**URL shape (Jacques, 2026-08-18):** start with **`http://<IP>/`**, plus an **optional
port/path** so a station that needs one is not blocked.

### Vision station IPs supplied

| Station (as given) | IP |
|---|---|
| Sort Cage | `172.17.20.37` |
| RPY Line 1 | `172.17.20.4` |
| RPY Line 2 | `172.17.20.32` |
| 6NA, 6VJ Fuel Pump | `172.17.21.238` |
| RPY, 6B2, 66V Fuel Pump | `172.17.21.244` |
| 6MA CH | `172.17.21.237` |
| 59B CH | `172.17.21.241` |

**Open:** these are **line/station names, not terminal codes**. They need mapping onto the
`ByVision` terminals in the plant model before they can be loaded — e.g. "RPY Line 2"
plausibly maps to a terminal under `MA2-RPYCAM2` or `MA2-RPY6B2`, but that must be
confirmed rather than guessed.

> **Second correction to the first pass of this document:** there is **no missing editor
> field**. The Plant Hierarchy attribute panel is fully generic — its flex-repeater binds
> `view.custom.editDraft.attributes`, built by
> `BlueRidge.Location.Location.buildAttributesForType`, which emits one editor row per
> active `LocationAttributeDefinition` (name, value, dataType, uom, required, description).
> **Any attribute defined for LocationTypeDefinition 7 renders automatically.** So item 8
> is SQL-only, and the same correction applies as for item 6.

### Work done — SHIPPED

- **`sql/migrations/versioned/0063_vision_app_ip.sql`** — renames the LTD-7 attribute
  `VisionAppUrl` → **`VisionAppIp`** and rewrites its Description (which surfaces as the
  editor's help text). Renamed rather than replaced so any existing value survives.
- **`sql/migrations/repeatable/R__Location_ufn_VisionAppUrl.sql`** — new composer:

  | Stored | Composed |
  |---|---|
  | `172.17.20.37` | `http://172.17.20.37/` |
  | `172.17.20.37:8080` | `http://172.17.20.37:8080/` |
  | `172.17.20.37/app` | `http://172.17.20.37/app` |
  | `172.17.20.37:8080/app` | `http://172.17.20.37:8080/app` |
  | `https://vision/x` | `https://vision/x` (passed through) |
  | NULL / `''` / whitespace | NULL |

  The pass-through rule is what makes the rename **non-breaking**: a terminal already
  holding a full URL under the old attribute keeps working with no data edit. Blank → NULL
  matters too — otherwise the inline-frame would load `http:///` and render a browser
  error page.
- **`Location.Terminal_GetClosureContext` v1.1** — reads `VisionAppIp`, composes via the
  function. **The result column keeps the name `VisionAppUrl`** (it is a URL by the time it
  leaves the proc), so `applyToSession`, `session.custom.terminal.visionAppUrl` and both
  assembly views (`AssemblyNonSerialized`, `AssemblySerialized`) are **untouched**.
- **Tests** — new `sql/tests/0020_PlantFloor_Foundation/032_Terminal_VisionAppUrl.sql`
  (15 assertions: 10 on the composer, 3 end-to-end through the proc including the legacy
  full-URL regression, 2 on the rename itself). `030_closure_capability_seed.sql` updated
  for the new attribute name. **Suite: 157 passed / 0 failed** (was 142 — +15).

### Station → terminal mapping — DERIVED, NEEDS CONFIRMATION

MPP supplied line/station names, not terminal codes. On each candidate line exactly **one**
terminal is configured `CurrentClosureMethod = 'ByVision'` — by definition the station with
the camera — which disambiguates all six production lines. The Sort Cage matches by name.

| MPP station | IP | → Terminal | Basis |
|---|---|---|---|
| Sort Cage | `172.17.20.37` | `INSP-SORT-T1` | parent `INSP-SORT` = "Sort Cage Inspection" |
| RPY Line 1 | `172.17.20.4` | `MA2-RPYCAM1-AOUT1` | only ByVision on "RPY Line 1 Cam Holders" |
| RPY Line 2 | `172.17.20.32` | `MA2-RPYCAM2-AOUT1` | only ByVision on "RPY Line 2 Cam holders" |
| 6NA, 6VJ Fuel Pump | `172.17.21.238` | `MA1-FP6NA-AOUT` | line "Fuel Pump (6na 6vj)" |
| RPY, 6B2, 66V Fuel Pump | `172.17.21.244` | `MA1-FPRPY-AOUT` | line "Fuel Pump (RPY 66v)" — **see note** |
| 6MA CH | `172.17.21.237` | `MA2-6MACH-AOUT3` | only ByVision on "6MA Cam Holder Line 1" (AOUT1/2 are ByCount METTs) |
| 59B CH | `172.17.21.241` | `MA2-59B-AOUT2` | only ByVision on "59b Cam holder" (AOUT1 is ByCount METTs) |

**Note on "RPY, 6B2, 66V Fuel Pump":** the plant model names that line *"Fuel Pump (RPY
66v)"* — the **6B2** in MPP's label is unaccounted for. The only other 6B2 location,
`MA2-RPY6B2` ("RPY 6b2 line2"), is a **cam-holder** line with no ByVision terminal, so
`MA1-FPRPY-AOUT` is the only fuel-pump line matching RPY + 66V. Worth one confirmation.

**Five terminals are configured ByVision but were given no IP**, so their vision embed
stays blank: `MA2-5PA-AOUT`, `MA2-64AOP-AOUT`, `MA2-6FBCHOP-AOUT`, `MA2-6MAOP-AOUT`,
`MA2-V6OP-AOUT`. Either MPP owes those IPs, or those stations do not actually run ByVision.

**`sql/scratch/seed_vision_app_ip.sql`** loads the seven (idempotent upsert; refuses to
load *anything* if a mapped terminal code is missing, rather than silently loading six of
seven). Deliberately **scratch until the mapping is confirmed** — promote to `sql/seeds/`
on sign-off.

### Verified against `MPP_MES_Dev`

```
EXEC Location.Terminal_GetClosureContext @TerminalLocationId = <MA2-RPYCAM1-AOUT1>
-> ByVision | http://172.17.20.4/ | ByCount,ByVision
```

All seven load and compose correctly.

---

## Status

| # | Item | State |
|---|---|---|
| 1 | BOM version on FG label | Deferred |
| 2 | Die list load | Awaiting MPP: cavity roll-up, part mapping, status filter, shot-count source |
| 2b | Cross-die merge gate | Awaiting Jacques: keep / drop / re-key on `ToolId` |
| 3 | IP auto-navigation | **Shipped** — root-caused, banner + loopback script; live browser leg unverified (trial expired) |
| 4 | Production/inventory report | **Spec written** — `docs/superpowers/specs/2026-08-18-production-and-inventory-by-area-design.md`; 2 items to confirm |
| 5 | Weekend shifts | **Closed** — Jacques authoring the schedule; optional NULL-shift guard remains |
| 6 | User timeout | **Shipped** — migration `0062` + minute-based editor; not render-verified (trial expired) |
| 7 | Serialized-line validation number | Brief written, awaiting Tom / MPP |
| 8 | Vision screen IP | **Shipped** — migration `0063` + composer + 15 tests (157/0). Mapping derived, needs confirmation before promoting the seed |

---

## Revision History

| Date | Rev | Change |
|---|---|---|
| 2026-08-18 | 1.0 | Initial — FAT Day 1 punch list captured with per-item code findings, die-report structural analysis, and open questions. |
| 2026-08-18 | 1.3 | #8 shipped: migration `0063` renames the LTD-7 attribute to `VisionAppIp`, new `Location.ufn_VisionAppUrl` composes `http://<ip>/` (+ optional port/path, full URL passed through), `Terminal_GetClosureContext` v1.1, 15 new tests (suite 157/0). No view work — second correction: the Plant Hierarchy attribute panel renders generically from the definitions. Station→terminal mapping derived via the ByVision closure method and loaded to Dev, pending confirmation. |
| 2026-08-18 | 1.2 | #3 root-caused (no terminal carries 127.0.0.1 — the proc and normalizer are correct; 142/0 tests) and fixed with a self-diagnosing selector banner + a loopback registration script. #4 daily = shift-anchored (3rd→1st→2nd). #5 closed, no build. #8 URL shape + 7 station IPs recorded. Replaced the sequencing table with a status table. |
| 2026-08-18 | 1.1 | Decisions folded in: #1 deferred; #2 Die column = `Tool.Code`, die rank dropped (+ new §2b on the consequences); #4 building = Area; #5 Plan B (weekend schedule); #6 30 min operator + minute-based UI; #8 IP only. #6 SQL + Python shipped (migration `0062`). #7 detailed out to its own brief. Corrected §6 — a SessionPolicy editor does exist, on the Config-Tool Users page. |
