# Shift reconciliation backfill -- Trim shop follow-up (2026-09-17)

**Context.** Building 2 die cast operators could not enter LOTs on the night of
2026-09-16 (3rd shift). The paperwork (DCFM-0485-style press sheet: LTT, cavity,
basket qty, scrap by reason, warm-ups) is complete, but the MES had no path to
enter a past shift after the fact. Some baskets were keyed in through the
inventory cutover screen as a stopgap; that is not the right tool (no production
record, and cutover is a one-time migration screen, not an operational path).

**Decision (brainstorm, approach A).** Build a die cast **shift reconciliation**
surface: CRUD over one past `(Shift, Press, Die)` -- add baskets (LTT + cavity +
qty), submit scrap/warm-ups, enter the shift's shot total -- written against that
shift, supervisor-attributed, with a reason. Expected to be used regularly, not
as a one-off.

**Follow-up owed: Trim shop needs the same capability.** When Trim IN / Trim OUT
entries are missed, there is equally no way to record a past shift's trim work
from the trim shop sheet (TSFM-0085). Design the die cast version so the shape
(past-shift header, line entry, reason, late-entry audit marker) can be reused
for Trim rather than rebuilt.
