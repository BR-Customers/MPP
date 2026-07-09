# Auto-Open Next Container (#8) — Design Notes & Deferral

**Date:** 2026-07-01
**Author:** Jacques Potgieter (working session)
**Status:** ⏸️ **DEFERRED pending #7** (Trim OUT → line-deposit + terminal self-filtering; owned by Hunter).

---

## Why this is deferred

Auto-open's item resolution depends on knowing *which FinishedGood LOT is ready to be
packed at a line's Assembly-Out terminal*. That "is this LOT eligible at this terminal"
rule is the **core primitive of #7** (terminals self-filter their FIFO queue by sort
order). #8 needs it only for the Assembly-Out terminal; #7 needs it for every terminal.
They are therefore **not cleanly separable** — #8 must be specced against #7's decided
line/terminal model. Hunter is building #7, so #8 waits on that decision.

---

## Scope (confirmed this session)

- Applies to **all machining-&-assembly lines**, **mandatory** (not opt-in per line).
- Container auto-open logic **concerns ONLY those lines** — **NOT trim, NOT die cast.**
  Enforced by a LocationTypeDefinition scope guard, not hard-coded ids.
- Container opens at each line's **Assembly Out** terminal (confirmed: the "Assembly Out"
  LocationTypeDefinition is the packing station, vs "Assembly Finished" / "Assembly
  (Serialized)").
- Trigger model: **timer + event follow-on** (decided) — a Gateway timer backstop PLUS an
  immediate open right after a successful `Container_Complete`.

---

## Domain-model corrections captured this session

These supersede the original 2026-06-30 note's "lots at the terminal's parent location":

- **LOTs are checked into machining-&-assembly LINES** (WorkCenter / HL3), *not* terminal
  cells. The FIFO queue lives at the **line**.
- A line has N sequential terminals; each records a completion event as a LOT advances.
  The **Assembly-Out (last) terminal should only "see" LOTs that have completed all prior
  stations** — i.e. N−1 stations' worth of history.
- **Complication:** 2 lines have more than one terminal with combined **in/out
  functionality**, so a single line can have **up to 8–10 terminals** (multiple chained
  machining + assembly stations), not just the canonical 4 (machining-in, machining-out,
  assembly-in, assembly-out).

---

## Recommended terminal-eligibility rule (belongs to #7; #8 consumes it)

**Count distinct *terminals reached*, ordered by `SortOrder` — never raw events, never a
hardcoded number.**

- Order a line's terminals by **`Location.SortOrder`** — this column **already exists** on
  `Location.Location` (migration `0002`); no schema add needed (contra note #7's worry).
- A LOT's **progress on a line** = `COUNT(DISTINCT terminal)` where it has a completion
  event at a terminal on that line, sourced from `Workorder.ProductionEvent` (LotId,
  LocationId, EventAt) and/or `Audit.OperationLog` (EntityId = LotId, TerminalLocationId).
- A terminal at `SortOrder = s` admits a LOT iff the LOT has completion events at **all
  s−1 prior-positioned terminals** on the line. Assembly-Out (max SortOrder) admits LOTs
  that have completed every prior station.

**Why distinct-terminal count (not raw-event count):** a dual in/out terminal writes ≥2
event rows per LOT pass but is **one** distinct terminal, so it contributes exactly one to
progress. This dodges any need to classify events as "in" vs "out," and generalizes from 4
terminals to 10 with **no** hardcoded "needs 3 events."

**Assumption to confirm:** a line is a *linear pipeline* where every LOT passes every
station in SortOrder. If some parts legitimately **skip** stations, distinct-count ≠
position and we'd need a **route-driven "expected stations" set** instead of a plain count.

Suggested shared artifact (build in #7): a read such as
`Lots.Lot_ListEligibleAtTerminal(@TerminalLocationId)` or a `ufn_LotProgressOnLine`.

---

## Auto-open decision logic (once the primitive exists)

For each M&A line's **Assembly-Out** terminal, open a container when **all** of:

1. the terminal has **zero** open containers right now,
2. there is ≥1 **FinishedGood**-type LOT at the line that has **completed all prior
   stations** (progress = N−1), and
3. the **FIFO-oldest** such LOT's Item has an **active `ContainerConfig`**.

Take that oldest LOT's Item → its single active ContainerConfig → open. Empty queue / no
config = **clean no-op** (correct cold-start behavior: nothing to pack yet). MVP scope: one
open container per terminal; simultaneous multiple-open-for-different-items is **out**
(YAGNI).

---

## Grounded technical facts (verified this session)

- **ContainerConfig is deterministic given the Item** — at most one active config per Item
  (filtered unique index `UQ_ContainerConfig_ActiveItemId`). So "which config" is solved
  the instant we know "which item." `Parts.ContainerConfig_GetByItem` returns it.
- **`Lots.Container_Complete` is an INSERT-EXEC-captured orchestrating proc** → per the
  CLAUDE.md rule it **cannot `EXEC Container_Open`** (inner SELECT pollutes its single
  result set; nested INSERT-EXEC is illegal). Therefore the event-driven "open next on
  complete" **must** be an **Ignition-side follow-on call** after Complete returns
  `Status = 1` — never inside Complete's transaction.
- **No uniqueness constraint** enforces ≤1 open container per cell (`Container_GetOpenByCell`
  can return multiple). Auto-open **must guard concurrency** (existence check under
  `UPDLOCK, HOLDLOCK` inside the txn) so the timer and the event follow-on can't double-open.
- **`Location.SortOrder` already exists** (0002).
- **No system AppUser seeded yet.** Auto-opened containers must be attributed to a dedicated
  `system` AppUser (resolve internally in the proc; a seed is part of this work). Couples
  with the already-owed "seed a dedicated system AppUser before cutover" item.
- Existing building blocks: `Lots.Container_Open(@ItemId,@ContainerConfigId,@CellLocationId,
  @AppUserId,@TerminalLocationId)`, `Container_Complete`, `Container_GetOpenByCell`,
  `Lots.Lot_GetWipQueueByLocation` (FIFO by `MovedAt ASC`, optional descendant rollup),
  `Parts.ContainerConfig_GetByItem`. Entity script `BlueRidge.Lots.Container`
  (open / complete / getOpenByCell / trayClose / …).
- Timer pattern to copy: MPP project, `ignition/timer/<Name>/` scope `G`, `delay 60000`,
  `fixedDelay`, `sharedThread`; thin dispatch one-liner into a Core script (cf.
  `ShiftBoundaryTicker` → `BlueRidge.Oee.Shift.tickShiftBoundary`).

---

## Planned build shape (draft — revisit after #7 lands)

1. Seed a dedicated **`system` AppUser**.
2. Reuse #7's terminal-eligibility primitive to resolve the packable FinishedGood at each
   line's Assembly-Out terminal.
3. **`Lots.Container_EnsureOpenForCell(@AssemblyOutLocationId)`** — per-terminal mutation:
   concurrency + already-open guard, resolve oldest eligible FG LOT → item → active config,
   **inline** the open (mirror `Container_Open`), audit to the system user, single status
   row. No-op paths return `Status = 1`, `NewId = NULL`.
4. **`Lots.Container_EnsureOpenForActiveLines()`** — cursor over all M&A Assembly-Out
   terminals, `EXEC` the per-terminal proc each. Timer entry point.
5. Gateway timer **`AssemblyContainerAutoOpen`** (MPP, ~60s) → Core
   `BlueRidge.Lots.Container.ensureOpenForActiveLines()`.
6. **Event follow-on**: in the assembly view, after `Container.complete()` returns
   `Status = 1`, call `ensureOpenForCell(assemblyOutLocationId)` + refresh the open-container
   binding. (Edit to an existing view → do in Designer.)
7. **Tests**: per-terminal ensure (opens / skip-if-already-open / skip-if-none-waiting /
   picks FIFO-oldest / attribution = system user / no-active-config no-op); the sweep; and
   the timer↔event **double-open concurrency guard**.

---

## Open questions to resolve when resumed (post-#7)

1. **Final terminal-eligibility semantics come from #7** — distinct-terminal count vs
   route-driven "expected stations"; how a LOT advances station-to-station; whether a LOT's
   `CurrentLocationId` stays = the line the whole time (events carry the terminal).
2. Do any parts **skip stations**? (Breaks the linear-pipeline assumption behind
   distinct-terminal counting.)
3. **System AppUser** identity/resolution key — reserved Initials (`SYS`)? a dedicated flag
   column? — and the seed itself.
4. Is **>1 open container** per line/Assembly-Out terminal ever legal? (Decides the guard
   strength and whether to add a filtered unique index for one-open-per-terminal.)
5. **Container anchor** under the line model — should `Container.CurrentLocationId` be the
   Assembly-Out terminal location or the line? Confirm against #7's deposit model.

---

## Cross-references

- Original seed of this idea: `notes/2026-06-30_working-notes.md` § "Auto-open the next
  container at an assembly line" (Approach A: event-driven + Gateway-timer backstop +
  system AppUser).
- Blocking dependency: **#7** — `notes/2026-06-30_working-notes.md` § "Trim OUT should check
  LOTs into the LINE; terminals self-filter their FIFO queue by sort order" (Hunter).
- Subsumes the Machining-IN duplicate-LOT bug (folded into #7 per the 2026-06-30 decision).
