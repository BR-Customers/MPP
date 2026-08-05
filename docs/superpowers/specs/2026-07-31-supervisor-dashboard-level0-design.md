# Supervisor Dashboard — Level 0 Design

**Date:** 2026-07-31
**Status:** Design (approved in ideation; mockup built, implementation not yet planned)
**Mockup:** `docs/mockups/supervisor-dashboard-level0.html` (published Artifact)
**Related:** `docs/proposals/SOW_Level2_Production_Plan_Integration.md` (the Level 2 follow-on)

## Purpose

Replace the current stubbed Supervisor Dashboard (`BlueRidge/Views/ShopFloor/SupervisorDashboard`, route `/shop-floor/supervisor`) — a flat downtime-centric tile row, mostly placeholders — with a plant-wide, desktop production-totals board for a shift supervisor / plant manager. The job: glance the whole floor, see shift totals roll up, and spot stalls and holds.

## Framing decisions (locked)

- **Audience / context:** one plant-wide view, office/desktop. Not per-area, not an andon TV.
- **Time scope:** selectable window — **This Shift** (default) · Today · This Week. Every number re-scopes to the window.
- **Event-derived only.** No PLC run-state signal exists. All counts and "activity" are aggregations of MES events (LOT movement, die-cast contributions, holds). Liveness is inferred from **event recency**, not a machine tag — an honest substitute for a RUNNING light.
- **No targets at Level 0.** Raw actuals + recency only. Plan-vs-actual is Level 2 (separate engagement).

## Content model

Four panels. Three production panels share one anatomy; the fourth (Holds) is an exception surface.

| Panel | Headline metric | Source events |
|---|---|---|
| **Die Cast** | Shots (good/scrap available) | `Workorder.DieCastContribution` per machine/tool |
| **Trim** | LOTs moved through (Trim OUT count) | LOT movement / Trim OUT events per press |
| **Production Lines** (Machining + Assembly grouped) | Containers produced (completed trays) | Assembly completion events per line |
| **Inspection & Holds** | # LOTs on hold (expandable list) | `Quality.Hold` active holds |

### Production panel anatomy

- **Panel header:** area identity chip + name, roll-up total + unit, and **exception badges** (⚠ N stale · N idle) bubbled up from the rows.
- **Sub-area groups** (DC1–4; TRIM1/2; MA1/MA2): collapsible. **Default collapsed, manual expand.** Group header shows sub-roll-up + its own exception badges, so problems are visible without expanding.
- **Resource rows** (per machine / press / line): `code · description`, the count, and a **state**:
  - **● live** — last event within the area's staleness threshold ("last 4m").
  - **⚠ stale** — an event exists but is older than the threshold ("last 22m · stale"). Possible stall.
  - **idle** (greyed) — zero count / no events in the window.
- Staleness thresholds are per-area and configurable. Mockup defaults: Die Cast 15 min, Trim 30 min, Lines 20 min.
- **Recency is a This-Shift concept.** In Today / Week windows the recency column is suppressed (a total, not a pulse).

### Holds panel

- Headline hold count (amber, distinct treatment) + caption (N new this shift, oldest age).
- Held-LOT list: LTT, part, location, hold reason (Quality / Engineering / Logistics), age. These are pulled from production until released — the "what needs attention" corner.

## Interactions (Level 0)

- Window tabs re-scope all numbers.
- Collapse / expand sub-area groups.
- Holds list always visible (expandable if it grows).
- Row click → *stub only* (future deep-link to LOT detail).
- Light / dark theme (the real view inherits the app theme; mockup includes a toggle).

## Data layer (what the build needs)

**~4 new aggregate read procs**, one per panel, all reading existing event tables — **no schema changes**:

1. Shots by machine (+ good/scrap) for a window — from `DieCastContribution`.
2. LOTs moved through Trim by press for a window — from LOT movement / Trim OUT events.
3. Containers (completed trays) by production line for a window — from assembly completion events.
4. Active holds list + count — from `Quality.Hold`.

Each returns per-resource rows with the count and the last-event timestamp (for recency). Follow the Ignition JDBC no-OUTPUT-param / one-result-set conventions; timestamps converted to ET at the read boundary.

## Forward path (designed-in, not built)

- **Level 1 (pace vs. engineered rate):** add a standard-rate field per die/part; the row anatomy already reserves the gutter for a pace bar. Row degrades gracefully when no rate exists.
- **Level 2 (plan-vs-actual):** the full plan-ingestion + attainment engagement scoped in the SOW. The same aggregate reads feed it; the dashboard overlay is additive.

## Open questions for the real build

- Exact source events/procs for "LOTs moved through Trim" and "containers produced" — confirm against current lot-event procs before writing the aggregate reads.
- Whether the roll-up for Production Lines should also expose the Machining vs. Assembly split (the plan tracks them separately; Level 0 shows one container number).
- Refresh cadence (polling interval) for a desktop board.
- Whether "Today" / "This Week" windows are needed at launch or This-Shift-only is enough for v1.

## Revision History

| Date | Change |
|---|---|
| 2026-07-31 | Initial Level 0 design captured from ideation session; interactive mockup built. |
