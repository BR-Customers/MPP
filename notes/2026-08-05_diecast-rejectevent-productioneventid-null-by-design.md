# Die-cast RejectEvent.ProductionEventId is NULL-by-design — FAT #20 (+ #27 deferred)

**Date:** 2026-08-05
**Decision owner:** Jacques
**FAT items:** #20 (scrap → ProductionEvent link), #27 (nightly shot-count reconciliation)
**Handoff:** C (`docs/handoffs/2026-08-05-fat-remaining-handoffs.md`)

## #20 — decision: NULL-by-design (no proc change)

FAT #20 asked: *"`Workorder.RejectEvent.ProductionEventId` is all NULL — should it be?"* The
handoff brief pre-framed this as *"thread the shift-output event's `ProductionEventId` onto the
`RejectEvent` rows."*

**That premise no longer holds.** Migration `0045` (per-cavity lifecycle, 2026-07-29) removed
die-cast's use of `Workorder.ProductionEvent` **entirely**. A die-cast **"Record Shift Output"**
event does not create a `ProductionEvent` — it writes:

- one `Workorder.DieCastContribution` ledger row per line (net good pieces per cavity-lot), and
- additive `Workorder.RejectEvent` rows (per-cavity `scrapLines[]` + a shot-loss fan-out across
  every open lot on the tool).

Verified three ways:
1. `0045_diecast_per_cavity_lifecycle.sql` contains **zero** `ProductionEvent` references.
2. The only procs that `INSERT INTO Workorder.ProductionEvent` are Machining/Trim
   (`MachiningOut_Mint`, `MachiningIn_RecordPick`, `TrimOut_Record`, `ProductionEvent_Record`) —
   **none die-cast, none shift-level.**
3. In `R__Workorder_DieCastShiftOutput_Record.sql` both additive-scrap inserts hardcode
   `ProductionEventId = NULL` (the per-cavity `scrapLines[]` insert and the `@ShotLossJson`
   fan-out insert).

So there is **no shift-output `ProductionEventId`** to thread. `RejectEvent.ProductionEventId` is
meaningful only for the **subtractive downstream** reject path (`Workorder.RejectEvent_Record`
called with a real `@ProductionEventId`). For die-cast additive scrap it is **NULL by design.**

**Why not link to something else instead**
- *Link to `DieCastContribution`* — would be a schema change (new nullable FK on `RejectEvent`)
  and the shot-loss fan-out has no single contribution to point at (it spans every open lot). If
  real shift-output → scrap traceability is ever wanted, that is its own spec, not #20.
- *Mint a shift-level `ProductionEvent`* — reverses part of the `0045` redesign and overloads a
  LOT-scoped checkpoint table with a die-scoped concept. The tool-shot-count spec
  (`2026-08-04-tool-shot-count-design.md` §2) explicitly rejected this direction.

**Outcome:** no change to `R__Workorder_DieCastShiftOutput_Record.sql`. The behavior is pinned by a
regression guard: `sql/tests/0045_DieCast_Lifecycle/070_ShiftOutput_RejectEvent_NullProductionEventId.sql`
asserts both the per-cavity additive scrap row and the shot-loss row carry `ProductionEventId = NULL`
(and that no die-cast RejectEvent carries a non-NULL one). If a future change starts stamping a
ProductionEventId onto die-cast additive scrap, that test fails loudly — a deliberate tripwire.

> The proc header would be the natural home for a one-line "ProductionEventId NULL-by-design"
> comment, but `R__Workorder_DieCastShiftOutput_Record.sql` is in Handoff B's blast radius (#19
> threads the machine LocationId into the same proc's audit op + bumps the header changelog), so
> that edit was intentionally NOT made here to avoid a same-file race. If desired, add the header
> comment when Handoff B lands.

## #27 — decision: deferred (obsoleted by the live increment)

FAT #27 proposed a **nightly gateway timer** to recompute each die's `Tools.Tool.ShotCount` from
submitted shot data.

**Deferred.** Migration `0050` (tool shot count, already shipped) increments `ShotCount`
**live, in the same transaction** as the shift-output Submit (see the `@GrossShots > 0` block in
`R__Workorder_DieCastShiftOutput_Record.sql`). The counter is always current. The tool-shot-count
spec (`2026-08-04-tool-shot-count-design.md` §8) already lists #27's daily trigger as *"obsoleted
by the live increment."*

There is also **no independent source to reconcile against**: shots ≠ pieces (one shot on an
N-cavity die makes N castings, and gross also counts scrap/shot-loss cycles), so a reconciliation
job could only recompute the counter **from itself**. A meaningful reconcile would require a
`Tools.ToolShotEvent` ledger, which does not exist and is itself deferred (spec §8). If that ledger
ever lands, revisit #27 then — until then it adds a gateway timer with no drift-correction value.

**Outcome:** nothing built for #27.
