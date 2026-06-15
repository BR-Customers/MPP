# Terminal Mode — View-Policy Model (retires derived TerminalMode)

**Date:** 2026-06-10
**Status:** Approved (Jacques, in-session)
**Supersedes:** FDS-02-010 "Terminal Mode Determined by Location Assignment" (parent-tier derivation) and the `TerminalMode` column emitted by `Location.Terminal_GetByIpAddress` / `Location.Terminal_List`.

## 1. Trigger

Found during the Arc 2 Phase 1 Designer smoke (2026-06-10). The FDS-02-010 rule — terminal parented at a Cell → Dedicated, else Shared — misclassifies most of the plant as seeded:

- Machining/assembly lines (`MA1-*`, `MA2-*`, 18 lines) carry 3+ fixed-function terminals (Machining In Side A, Assembly Out 2, ...) parented **directly at the line** with **no equipment cells beneath**. Rule says Shared; reality is fixed-station.
- Trim shops (`TRIM1`/`TRIM2`) are area-level processing with one terminal each and **no press cells**. Rule says Shared.
- For both, FDS-02-009's Shared cell picker ("descendant Cells of the parent") resolves to an **empty list** — there is nothing to attribute production to. The flattened hierarchy breaks event attribution on those terminals regardless of mode label.
- Compounding: `Terminal` (DefId 7) and `Printer` (DefId 16) are themselves Cell-tier kinds, and **every terminal must carry ≥1 child Printer** (many supported) — so any "descendant Cells" logic needs an equipment-kind exclusion to even count correctly. The tree cannot carry the mode signal.

MPP traceability requirement (Jacques, 2026-06-10): those lines are tracked at **line level** — parts check in at Machining IN, check out (consuming) at Machining OUT, get consumed at Assembly IN, containerized at Assembly OUT, **all under the context of the line** (e.g., RPY Line). Stations are operation points, not locations. Modeling stations as Cells was considered and rejected.

## 2. Decision

**There is no TerminalMode — not derived from the tree, not stored as an attribute.** The behavior previously bundled under "mode" is a property of **the operator view a terminal is assigned** via its existing `DefaultScreen` EAV attribute. One knob per terminal; the configuration *is* the behavior, so nothing can drift.

Views are authored in one of two flavors:

| | **Shared-flavor view** | **Dedicated-flavor view** |
|---|---|---|
| Opening step | Select-location menu (or persistent location dropdown in an agnostic view) | None |
| Location context (`session.custom.cell`) | Operator-selected, from the terminal-parent's **descendant equipment cells** | Bound automatically to the **terminal's parent Location** (press cell, line, or trim shop — any tier) |
| Context change | Re-select via the same selector (FDS-02-011 mechanics) | Not changeable in the UI |
| Presence policy (`session.custom.presence.policy`) | `strict` — idle ⇒ initials **re-entry**; context change ⇒ re-prompt | `confirm` — idle ⇒ "Operate as [XY]? [Yes]" continue; initials persist through the shift |

Every event still carries the two FDS-02-009 references: `TerminalLocationId` (where the operator stands) + `LocationId` (the production context — now a Cell **or a line/area** for dedicated-at-line/area terminals).

### 2.1 Presence / idle re-confirmation (FDS-04-006 — UNCHANGED)

Per Jacques's explicit call: **both flavors keep the 30-minute idle re-confirmation overlay** exactly as FDS-04-006 specifies. The flavor only changes what the overlay does (Yes-continue vs re-entry), which FDS-04-003 already describes. Implementation: ONE `PresenceIdleWatcher` embed (the Phase-1 `now(30000)` component), always present on work views, branching on `session.custom.presence.policy` — views set the flag on load; no per-view timers. Performance: one timestamp-compare binding per session every 30 s — negligible at plant scale (~60 terminals).

### 2.2 Equipment-cell definition (picker filter only)

"Descendant equipment cells" = Cell-tier locations **excluding** kinds `Terminal` and `Printer` (by `LocationTypeDefinition.Code`, not hardcoded ids). This exclusion now exists ONLY in the picker proc, where it is self-evidently correct — it no longer influences any mode decision. FUTURE: an `IsInfrastructure` bit on `LocationTypeDefinition` if non-equipment Cell kinds multiply.

### 2.3 What we deliberately give up

No mode data ⇒ no pre-flight "Shared terminal with empty picker" warning. A wrongly-assigned screen surfaces at the terminal (empty select-location list), not in a registry view. Accepted: screens are assigned from MPP's curated per-workstation list (Phase 0 Track A item #4), and the failure is loud and local. The registry (`Terminal_List`) keeps the checks that still mean something:

- **DefaultScreen missing** — terminal lands on the existing "contact Engineering" HomeRouter card.
- **No active child Printer** — violates the ≥1-printer invariant (new validation flag).

## 3. Code deltas (Phase-1 surface)

1. **`Location.Terminal_GetByIpAddress` + `Location.Terminal_List`** — DROP the derived `TerminalMode` CASE (and column). Keep terminal + parent ("zone") + `IpAddress` + `DefaultScreen` + `IsFallback`. `Terminal_List` ADDS `HasPrinter BIT` (≥1 active child `Printer` location) for the registry surface.
2. **NEW `Location.Terminal_ListContextCells @TerminalId`** — descendant equipment cells (recursive under the terminal's parent, excluding `Terminal`/`Printer` kinds, `DeprecatedAt IS NULL`), ordered for the select-location step / dropdown. + NQ (Core, `location/Terminal_ListContextCells`, type Query).
3. **MPP `onStartup`** — drop `terminalMode` from `session.custom.terminal`; add the parent-location context fields needed by dedicated-flavor views (`zoneLocationId` already present). Declare `session.custom.presence.policy` (default `strict`) in session-props.
4. **HomeRouter `route()`** — simplify: fallback/unknown terminal → terminal selector; DefaultScreen set → navigate; else the existing card. The Dedicated-initials gate moves out of the router (the view flavor + presence policy own it).
5. **CellContextSelector component** — re-point to `Terminal_ListContextCells` (currently lists by tier "Cell", which would offer terminals and printers as production contexts — latent bug fixed by this change).
6. **Tests** — `0020_PlantFloor_Foundation/010_Terminal_GetByIpAddress.sql` mode assertions removed; new assertions for `HasPrinter` + `Terminal_ListContextCells` (DC1 → 11 presses, line terminal → empty, excludes terminals/printers).

No schema migration. No seed change (hierarchy stays flat; no mode attribute to seed).

## 4. FDS amendments (FDS → v1.4)

- **§2.5 narrative** — terminals are a mix of dedicated and shared **by assigned view**, not by parent tier.
- **FDS-02-008** — strike "Terminal mode ... derived from the parent tier per FDS-02-010"; terminal config = `IpAddress`, `DefaultScreen` (required), printer children (≥1 required), etc.
- **FDS-02-009** — context selection re-stated per §2 table above; "descendant Cells" → "descendant **equipment** Cells (excluding Terminal/Printer kinds)"; dedicated context = parent Location **of any tier** (Cell, WorkCenter/Line, or Area), per MPP's line-level traceability ruling.
- **FDS-02-010** — REWRITTEN: "Terminal Behavior Determined by Assigned View" — the view-policy model, the two flavors, the presence-policy flag. The "mode IS the assignment / attribute would invite drift" rationale is retired with an explanatory note (the plant's cell-less lines and infrastructure-under-terminals made the tree an unreliable signal; the view assignment is now the single source).
- **FDS-02-011** — context-change rules re-homed onto view flavors (same rules, new anchor).
- **FDS-04-003** — presence semantics keyed to view flavor / `presence.policy`, not parent tier.
- **FDS-04-006** — UNCHANGED (explicitly reaffirmed).
- Revision History row citing this spec.

## 5. Out of scope

- The actual shared-/dedicated-flavor work views (Arc 2 Phases 2+ author them against this convention).
- MPP's per-workstation DefaultScreen values (Phase 0 Track A item #4 — customer-owed seed).
- `IsInfrastructure` kind flag (FUTURE).
- Any terminal-registry admin screen (flags land in `Terminal_List` now; UI later).
