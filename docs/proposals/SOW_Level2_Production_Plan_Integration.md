# Scope of Work — Production Plan Integration (Level 2)

**Prepared for:** Blue Ridge Automation — Business Development
**Client:** Madison Precision Products, Inc. (Madison, IN)
**Subject:** Bringing the weekly production plan into the MES so the plant runs against plan in real time
**Status:** Draft for BD review — scoping / opportunity framing, not a fixed-price quote
**Date:** 2026-07-31

---

## 1. The opportunity in one paragraph

The MES we are delivering now captures **what actually happened** on the floor — every shot, every trimmed LOT, every container, every hold — as it happens. The new Supervisor Dashboard surfaces those actuals live (this is "Level 0"). What the MES does **not** yet know is **what was supposed to happen**: MPP still plans and projects production in standalone Excel workbooks (`DC_Changeover.xlsx`, `MS_Changeover.xlsx`) that live entirely outside the system. Because the plan and the actuals live in two different worlds, no screen can answer the question a supervisor actually asks every hour — *"Are we going to make the number?"* Closing that gap — putting the plan **inside** the MES and scoring live actuals against it — is a discrete, high-value follow-on engagement. This document scopes it.

## 2. Current state (what MPP does today)

MPP's planning team maintains two weekly workbooks that we have reviewed:

- **`DC_Changeover.xlsx` (Die Cast).** A weekly grid: every die cast machine × the parts/dies it will run × 12 days × 3 shifts, with a **planned piece count** in each cell. A second tab (`DC master`) is an engineering rate book per die — cavity count, cycle time, OEE, availability, reject rate — that computes an **expected good-pieces-per-shift** figure. This is where the plan numbers come from.
- **`MS_Changeover.xlsx` (Machining & Assembly).** The same weekly grid organized Block → Line → Part → Process, with **separate Machining and Assembly targets** per shift, plus manual annotations for shift length, line status, and ownership.

These workbooks are authoritative for scheduling, labor projection, and daily target-setting — and they are maintained and read entirely by hand, disconnected from the shop floor. Attainment against them is reconciled after the fact, if at all.

## 3. Proposed future state (Level 2)

Bring the plan into the MES as first-class data and score live actuals against it:

- The weekly plan (per machine / line, per shift, per part) becomes **structured MES data**, not a spreadsheet — either imported from the existing workbooks or entered/adjusted in a purpose-built planning screen.
- The engineering rate book (`DC master`) becomes **standard-rate configuration** attached to each die/part — cycle time, cavities, OEE, reject rate — so the system can compute expected output independently of a hand-keyed cell.
- Every production panel on the Supervisor Dashboard gains a **plan-vs-actual overlay**: attainment % ("3,100 / 4,128 · 75%"), on-pace / behind-pace status derived from elapsed shift time, and a **projected end-of-shift** figure with shortfall flagged early enough to act.
- **Alerting** when a machine or line falls below a configurable attainment/pace threshold, so problems escalate without a supervisor watching the board.

The Level 0 dashboard is **deliberately built to receive this** — each resource row already reserves the gutter where the pace bar drops in, and the underlying reads are the same event aggregations. Level 2 is an additive layer, not a rebuild.

## 4. Scope of work

### 4.1 In scope

| # | Workstream | Description |
|---|---|---|
| 1 | **Plan data model** | Schema to hold the weekly plan at (resource × shift × part) granularity, versioned by plan week, with Machining/Assembly split for M&A lines. |
| 2 | **Standard-rate configuration** | Per-die / per-part rate attributes (cycle time, cavities, OEE, availability, reject rate) → computed expected-per-shift. Config screen + audit. |
| 3 | **Plan ingestion** | Either (a) a structured importer for the existing `DC`/`MS` workbooks, or (b) an in-MES plan entry/edit screen, or both. Choice is a design decision (see §6). |
| 4 | **Unit reconciliation** | Bridge plan units (pieces) to floor metrics (shots × cavities, pieces → containers via container config, LOTs). Required for any apples-to-apples comparison. |
| 5 | **Attainment & pace engine** | Server-side calc of actual-vs-plan, elapsed-pace expected, attainment %, and projected end-of-shift, per resource and rolled up per area. |
| 6 | **Dashboard overlay** | Extend the Supervisor Dashboard rows/panels with the pace bar, attainment %, and behind/ahead state. |
| 7 | **Threshold alerting** | Configurable per-area attainment/pace thresholds → floor + supervisor notification. |
| 8 | **Plan attainment reporting** | Shift / day / week attainment history and export for planning review. |

### 4.2 Out of scope (unless separately contracted)

- **Generating** the production schedule (line balancing, sequencing, capacity optimization) — Level 2 consumes the plan MPP produces; it does not create it.
- Labor scheduling / headcount planning (the workbooks carry this; the MES would not).
- Changes to Honda AIM/EDI demand intake.
- Automated PLC run-state sensing (a separate opportunity — see §7).

## 5. Deliverables

- Data model migrations + stored-procedure layer for plan, rates, attainment.
- Plan ingestion mechanism (importer and/or entry screen) per §6 decision.
- Standard-rate configuration screen.
- Supervisor Dashboard plan-vs-actual overlay.
- Threshold alerting configuration + delivery.
- Attainment reporting + export.
- Test coverage consistent with existing MES delivery standards; deployment to Dev → cutover.

## 6. Key decisions to resolve at kickoff

1. **Import vs. enter.** Do we ingest the existing Excel workbooks (fast, but couples us to their sheet layout and its `#VALUE!` fragility), build native plan entry in the MES (cleaner, retires the spreadsheets), or import-then-maintain-in-MES? This is the single biggest scope driver.
2. **Plan authority & change control.** Who owns the plan of record once it is in the MES, and how are mid-week changes handled (a common reality on the floor)?
3. **Rate source of truth.** Do the `DC master` engineering figures become MES config that MPP maintains, and how often do they change?
4. **Attainment granularity.** Score at machine/line level only, or also per-part within a resource (the plan is per-part; the floor rolls up)?

## 7. Adjacent opportunities (BD may bundle or stage)

- **PLC run-state sensing.** Level 0/2 infer "stalled" from event recency because there is no live machine signal. Instrumenting run/idle/fault from the PLCs would turn inference into fact and is a natural companion sale.
- **Downtime-to-attainment linkage.** Tie the existing downtime capture to attainment shortfalls ("behind because DC2 was down 40 min") — a strong analytics story once the plan is in.
- **OEE dashboarding.** The `DC master` already frames availability × performance × quality; with plan + actuals in one place, true live OEE is within reach.

## 8. Effort & phasing (relative sizing — BD to price)

Level 2 is **substantially larger than Level 0** because it introduces a new data domain (the plan) rather than reading existing events. Indicative phasing, smallest-valuable-slice first:

| Phase | Contents | Relative size |
|---|---|---|
| **2a** | Standard-rate config + pace-only overlay (expected-from-rate, no imported plan). Delivers "behind pace" with the least new data. | Small–Medium |
| **2b** | Plan data model + ingestion + unit reconciliation + attainment-vs-plan overlay. The core of the engagement. | Large |
| **2c** | Threshold alerting + attainment reporting/export. | Medium |

Phase 2a is a credible, quick win that proves value before committing to the full plan-ingestion build in 2b.

## 9. Dependencies & assumptions

- MPP provides current, representative copies of the planning workbooks and confirms which fields are authoritative.
- MPP identifies the plan owner and the change-control process (§6).
- Standard-rate figures are maintained by MPP as configuration.
- Level 0 Supervisor Dashboard is delivered and in use (it is the surface Level 2 extends).
- Existing MES architecture, environments, and delivery standards carry forward unchanged.

---

*This SOW is a scoping and opportunity-framing document for internal BD use. Effort bands are relative, not quotations; final pricing and timeline follow the kickoff decisions in §6.*
