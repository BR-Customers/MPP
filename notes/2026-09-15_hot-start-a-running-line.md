# Hot start — adopting a line that is already running

**Date:** 2026-09-15
**Status:** Requirement captured. Not designed, not scoped, not built.
**Raised by:** Jacques, off the back of the 6MA "11 trays ahead" gap —
*"we need to be able to hot start a line in our system. A way for me to say: yep, we
can start now, we have an open container."*

## The problem

Today the MES can only begin counting a line from **zero**: `Lots.Container_Open`
takes `(@ItemId, @ContainerConfigId, @CellLocationId, @AppUserId, @TerminalLocationId)`
and opens an **empty** container at tray 0. There is no way to tell it "this line is
already running, there is a part-full box on the floor with N parts and K trays in it,
begin from there."

Every real start is a hot start. A line does not pause and empty itself so the MES can
be switched on — at cutover, after a gateway restart, after a terminal is repointed,
after a shift where the system was down, the line is mid-container. Without a hot
start the MES begins at 0 while the floor is at K, and stays exactly K trays behind
forever. That is the shape of the 6MA discrepancy, whether or not the interface log
explains it (see
[2026-09-15_6ma-assembly-terminal-observations.md](2026-09-15_6ma-assembly-terminal-observations.md) §3).

Worse, the error is *silent and permanent*: nothing reconciles it, and the box that
eventually completes gets an AIM serial and a label describing a quantity that does
not match what is in it.

## What it has to do

The operator/supervisor gesture is small: **"we have an open container — start here."**
Underneath it needs to establish, at minimum:

- which finished good the line is running,
- which container config / closure method,
- **how far into the container it already is** — trays completed and/or pieces in
  the box,
- and that the parts already in the box are *not* to be minted as newly-built
  genealogy.

That last point is the whole design question.

## The genealogy question — the real decision

Parts already in the box were built before the MES was watching. They have no
component LOTs consumed, no BOM trace, no operator. Honda requires full genealogy for
every part. So a hot start either:

**(a) Mints nothing for the pre-existing parts.** The container carries a declared
starting count with no LOT behind it. Honest and simple, but the container's piece
count then exceeds the sum of its traced LOTs — every downstream read that derives
quantity from genealogy has to tolerate the shortfall, and the shipped box has a
partially untraceable population.

**(b) Mints a cutover/adoption LOT for the pre-existing parts.** One LOT, declared
quantity, explicitly flagged as adopted rather than manufactured, consuming nothing.
Keeps the "every part has a LOT" invariant, and makes the untraced population
*visible and queryable* instead of implicit. Costs a new origin type.

(b) looks right, and the schema is close to ready for it: `Lots.LotOriginType`
currently holds only `Manufactured` / `Received` / `ReceivedOffsite`. A `Cutover` (or
`Adopted`) origin is the natural fourth, and it would also give the existing
`/shop-floor/cutover-scan` flow a proper origin to stamp instead of borrowing
`Received`.

**Decide this before anything else is built.** Everything downstream — the proc
signature, what the label prints, what genealogy shows, what Quality sees on a hold —
follows from it.

## Other things it has to get right

1. **Who is allowed.** Declaring "there are 47 parts in this box" creates inventory
   and shipped quantity out of a sentence. This is an AD-elevated action
   (FDS-04-007), not a PIN-presence action.

2. **It must be auditable as a declaration, not a measurement.** `Audit.ConfigLog`
   row in the house convention, `NewValue` carrying the declared trays/pieces and the
   resolved FG — so that when a box is questioned later, the hot start is visible as
   the reason its numbers start where they do.

3. **Idempotence / double-adoption.** Two supervisors hot-starting the same line ten
   seconds apart must not produce two open containers or double the declared count.
   The existing "one open box per station" rule (migration 0078,
   `Container.listOpenForStation`) is the place to enforce it.

4. **It is not only Assembly.** The same gap exists anywhere the MES tracks a
   position the floor already holds — a die cast shot watermark mid-shift, a machining
   cell part-way through a basket. Assembly OUT is where it hurts first because the
   container has a *target* and a *label*. Worth designing the Assembly case concretely
   and asking whether the shape generalises, rather than building one generic
   mechanism up front.

5. **Reverse gear.** A hot start entered wrong needs a correction path. Note that
   `Lot_RectifyPieceCount` and `Lot_Update` **both refuse a no-op** and both reject
   `Open` / `Closed` / `BlocksProduction` LOTs — so an adoption LOT may have no
   audited repair path unless one is built alongside. Do not discover this after the
   fact.

## Next step

This is a design conversation, not a ticket. Worth a proper brainstorm →
spec → plan under `docs/superpowers/`, starting from the genealogy decision above.
