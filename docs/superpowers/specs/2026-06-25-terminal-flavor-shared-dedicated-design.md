# Terminal Flavor — Shared vs Dedicated Operator Views (Design)

**Date:** 2026-06-25
**Status:** Approved (Hunter, 2026-06-25). **Die Cast + Trim built** (Body + Shared + Dedicated each). **Machining + Assembly normalized** (2026-06-26): the 5 line screens (MachiningIn, MachiningOutSplit, AssemblyIn, AssemblyNonSerialized, AssemblySerialized) are dedicated-flavor — onStartup binds session.custom.cell to the terminal's parent ProductionLine + presence=confirm; no shared variant (no picker). Smoke seed refactored to resolve locations BY CODE and stage WIP at the lines (fixes the trim-press id-shift regression permanently). Demo DefaultScreen seeded for the MA terminals. Suite green 1848/1848.
**Implements:** FDS-02-010 (view-policy model, approved by Jacques 2026-06-10) + `docs/superpowers/specs/2026-06-10-terminal-mode-view-policy-design.md`
**Decisions locked (Hunter, 2026-06-25):** (1) FDS-strict — separate view flavors selected via the Terminal's `DefaultScreen` attribute; (2) Trim is per-terminal (some trim terminals shared, some dedicated).

## 1. Goal

A terminal's location-context behavior is chosen **per terminal** via its `DefaultScreen` attribute:

- **Shared flavor** → the screen shows a **cell picker** (dropdown + scan, scoped to the terminal's eligible equipment cells). `presence.policy = strict`.
- **Dedicated flavor** → the screen is **bound to a single fixed cell** (the terminal's parent Location), **no picker**. `presence.policy = confirm`.

Both flavors must work for Die Cast and Trim, individually selectable per terminal (e.g., DC1-T1 shared, DC1-T2 dedicated to a specific machine).

## 2. Why separate views (not one adaptive view)

Per FDS-02-010 the behavior is a property of the **assigned view**, with the assignment living in `DefaultScreen`. Two genuinely separate flavor views (selected by route) keep the determination external to the view and drift-free, exactly as the FDS intends. To avoid duplicating the (large) data-entry form between flavors, the **form body is extracted once into a shared embedded view**; each flavor wrapper differs only in how it acquires the cell context and which presence policy it sets.

## 3. Structure (per process — Die Cast shown; Trim mirrors)

```
DieCastBody  (NEW embed)  ── the entire data-entry form; reads session.custom.cell; owns the
                              lot-create / shift-tally / right-rail logic. No context acquisition.
DieCastShared (route /shop-floor/die-cast)            ── header + CellContextSelector(kind) + embed(DieCastBody); presence=strict
DieCastDedicated (route /shop-floor/die-cast/dedicated) ── header + startup-bind-parent + embed(DieCastBody); presence=confirm
```

- **DieCastBody**: extracted from today's DieCastEntry — the `Body` subtree (NewLotForm + RightRail) plus the custom methods its buttons call (`startup` minus cell-pick, lot create, shift tally). It reads the active cell from `session.custom.cell` (already the case downstream). Header (`OperatorLabel`, paused indicator, close) stays in the wrappers since it is shared chrome.
- **DieCastShared**: keeps the current cell dropdown via the existing `CellContextSelector` (or the inline `CellDropdown` already on DieCastEntry), now passing a `kindFilter` (`"Die Cast Machine"`). Sets `session.custom.presence.policy = "strict"` on load. This is essentially today's DieCastEntry, minus the body (now embedded).
- **DieCastDedicated**: on startup resolves the terminal's **parent Location** (`session.custom.terminal.zoneLocationId` / a new `Terminal_GetParentContext` read) and writes it to `session.custom.cell` (`{locationId, code, name}`); shows the cell as a read-only label (no picker). Sets `presence.policy = "confirm"`.

Trim: `TrimBody` + `TrimShared` (route `/shop-floor/trim`, press dropdown via `kindFilter="Trim Press"`) + `TrimDedicated` (route `/shop-floor/trim/dedicated`, fixed to the trim shop).

## 4. Routing + per-terminal assignment

- Page-config adds the `*/dedicated` routes mapping to the new dedicated wrapper views.
- A terminal's `DefaultScreen` attribute holds the route it should open (e.g. `/shop-floor/die-cast` vs `/shop-floor/die-cast/dedicated`). HomeRouter already navigates to `t.defaultScreen` — no router change needed.
- **Seed**: set `DefaultScreen` on the demo terminals so both flavors are demonstrable — e.g. DC1-T1 → `/shop-floor/die-cast` (shared); add/point a dedicated DC terminal parented at a specific machine (e.g. a `DC1-M01` terminal) → `/shop-floor/die-cast/dedicated`. One trim terminal shared, one dedicated.

## 5. Dedicated context = terminal's parent (modeling note)

A dedicated terminal's fixed cell is its **parent Location** (FDS-02-009). For a dedicated Die Cast terminal to bind to a *machine*, that terminal must be parented at the machine (e.g., a terminal under `DC1-M01`). Today all DC terminals are parented at the area. The seed will add at least one machine-parented terminal to demonstrate the dedicated flavor; real parenting comes from MPP's per-workstation list (Phase 0 Track A item #4).

## 6. CellContextSelector + dropdown kind filter

`getContextCellsForDropdown` already gained an optional `kindFilter` (Trim/Die Cast fixes, committed). `CellContextSelector` will pass a `kindCode` param through to it so shared views show only their process's cell kind on any terminal (including the broad fallback terminal). Default `None` keeps current callers unchanged.

## 7. Scope / sequencing

1. Die Cast first (reference): extract `DieCastBody`, build `DieCastShared` + `DieCastDedicated`, routes, seed one shared + one dedicated DC terminal. Verify both.
2. Trim second: same split (`TrimBody` / `TrimShared` / `TrimDedicated`).
3. Machining/Assembly screens are already effectively dedicated (no picker); optionally normalize them to the dedicated wrapper later — **out of scope** for this pass unless requested.

## 8. Risks

- **Designer clobber**: these are edits to existing views (DieCastEntry/TrimStation) plus new views. Existing-view edits must be reloaded from disk in Designer (the recurring file-vs-Designer hazard already bit `42cfdba`). New views are safe.
- **Body extraction regression**: DieCastEntry is a working, complex screen. Extraction must preserve every custom method, custom prop, and `rootContainer.X` call. Mitigation: move the `Body` subtree + its methods/props verbatim into the embed; keep the wrappers thin; test lot-create end-to-end after.
- **No SQL test impact** expected (views + one optional `Terminal_GetParentContext` read proc + seed `DefaultScreen` rows); full suite re-run regardless.

## 9. Out of scope

- Per-workstation `DefaultScreen` values for the real plant (MPP-owed seed).
- Normalizing the machining/assembly screens into the wrapper pattern.
- Any terminal-registry admin UI.
