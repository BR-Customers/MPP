# MES catch-up and recording pause — design spec

**Date:** 2026-09-15
**Status:** Draft — awaiting Jacques review. **Spec only; nothing is built.**
**Line:** `MA2-6MACH` (6MA Cam Holder Line 1), during the parallel run
**Evidence:** `notes/2026-09-15_line-run-audit-MA2-6MACH_2043.txt`
**Related:** `docs/superpowers/specs/2026-09-15-line-run-audit-design.md`,
`docs/superpowers/specs/2026-09-12-inventory-cutover-scan-design.md`,
`MPP_MES_CUTOVER_PLAN.md`

---

## 1. What happened, and what it taught us

Over 25 hours on `MA2-6MACH`, **1,157 tray bookings were refused** for insufficient
component stock. Twenty of those twenty-five hours recorded **zero** trays. MES booked 113
trays / 276 parts against a line that physically ran the whole time.

Three facts from the audit shape everything below.

**The refusals were not operator-facing.** Every one is attributed to `SYS` / System
Bootstrap at `MA2-6MACH-AOUT3`, firing every 8–60 seconds — the ByVision
`TrayInspectionWatcher` booking one tray per PLC pass pulse. There was no screen for
anyone to ignore and no operator in the loop. Training would have prevented none of it.

**The trigger was a duplicate part.** `90701-5RO-3000` (letter O) and `90701-5R0-3000`
(digit zero) are the same physical 9x10 dowel pin, entered twice. Receipts landed on one
item, demand sat on the other. The 1223A BOM was repointed to the digit-zero item at
16:38; it is still short.

**Legacy remains the system of record for this window**, so no production data was lost to
the business — only to MES.

## 2. The hard constraint

**Production cannot stop, and MES is load-bearing for the PLC handshake.**

`TrayInspectionWatcher` writes `OkToContinue` (N7:1) to the PLC. The camera does not fire
until MES sets it. So disabling the watcher, the timer, or the terminal does not merely
stop recording — **it stops the line.**

Any pause must therefore be *surgical*: keep the handshake, skip only the booking. In
`TrayInspectionWatcher/code.py` that split is already clean — the `OkToContinue` writes
live at lines 286 / 319, the booking is the single call to
`BlueRidge.Workorder.Assembly.plcCompleteTray(...)` at line 200.

## 3. Scope

Four pieces, in the order they will be used:

1. **Recording pause** — stop MES attempting to book, without touching the PLC.
2. **Inventory pass-in** — get real component stock into MES at the line.
3. **Catch-up consumption** — flagged, FIFO, traceable-but-not-for-traceability.
4. **Summary adjustment per part** — reconcile the lost window.

Out of scope, deliberately: see § 9.

---

## 4. Piece 1 — Recording pause

### Approaches considered

| | Approach | Verdict |
|---|---|---|
| A | Line-scoped `LocationAttribute` gate, read by the watcher | **Recommended**, with D |
| B | Disable the gateway timer / tag-change script | Rejected — stops `OkToContinue`, stops the line |
| C | Deprecate or unregister the terminal | Rejected — breaks session context, "View Not Found", wide side effects |
| D | Guard inside `Assembly_CompleteTray` itself | **Recommended**, with A |

A and D together, because they answer different questions. A is the **UX pre-flight** — the
watcher skips the round trip and the screen can show why. D is the **authoritative guard**
— it covers every caller, including the operator ByCount button and anything added later.
This mirrors the house pattern of a SQL-side authority with a read-side pre-flight.

### Design

A new `LocationAttributeDefinition` on the **ProductionLine** type definition (not Terminal
— the whole audit established that stock and this problem are line-scoped):

- `MesRecordingPaused` — `1` / `0`
- `MesRecordingPausedUntilUtc` — ISO timestamp, **required** when pausing

`TrayInspectionWatcher` resolves the line from its terminal via
`Location.ufn_AncestorLocationIds`, checks the flag, and when paused **returns before the
`plcCompleteTray` call and after the handshake writes**. `Assembly_CompleteTray` gains the
same check as its first validation, returning a **distinct status** so a caller can tell
*paused* from *failed* — a proc that silently succeeds while doing nothing is a footgun.

### A pause must be loud

The failure we are fixing is a silent one. A pause that is itself silent is the same bug
with better manners. Therefore:

- **It expires.** `MesRecordingPausedUntilUtc` is mandatory; past it, the guard treats the
  line as live. A pause cannot be left on by being forgotten.
- **It is audited.** Setting and clearing both write `Audit.ConfigLog` through the normal
  attribute-save path.
- **It is visible on the floor.** A banner on the line's assembly screens.
- **It is visible to us.** The line run audit gains a section reporting paused lines and
  the window they were paused for, so a later audit of this window explains its own gap.
- **It does not write `FailureLog` rows.** A pause is expected, not a failure. This is what
  stops the 1,157-row noise.

---

## 5. Piece 2 — Inventory pass-in

Reuse the existing cutover scan (`docs/superpowers/specs/2026-09-12-inventory-cutover-scan-design.md`)
rather than building anything new. Two gaps to close first:

- Its **`addBox` (purchased) path is still unexercised** — that is precisely the path a
  box of dowel pins needs.
- The **duplicate item must be resolved before counting**, or stock lands on the wrong item
  again: deprecate `90701-5RO-3000` and repoint the METTS sub-assembly BOMs
  (`12231`–`12245 -J000`) to `90701-5R0-3000`.

No new tooling is specified here. If `addBox` proves unusable tonight, a one-off receipt
through `Lots.Lot_Create` under the § 8 preview/commit discipline is the fallback.

---

## 6. Piece 3 — Catch-up consumption

### The central decision: what we refuse to fabricate

Catch-up records **consumption**, so component stock becomes correct. It does **not** mint
finished-good LOTs and does **not** write genealogy edges.

This is the point of the design, not a limitation of it. "Not for traceability" should mean
*we did not write fiction into the Honda trace* — not *we wrote fiction and labelled it*. A
fabricated FG LOT with fabricated parentage is exactly the thing a 20-year traceability
retention class exists to prevent. The finished-good record for this window lives in legacy,
and § 7 documents that.

`Workorder.ConsumptionEvent` already supports this shape: `ProducedLotId` is nullable
(today's "container only" case), while `ProducedItemId` stays populated so the rows still
say what they were consumed *for*.

### Schema

```
Workorder.ProductionCatchUp
    Id               BIGINT IDENTITY PK
    LineLocationId   BIGINT   NOT NULL FK Location.Location
    WindowStartUtc   DATETIME2(3) NOT NULL
    WindowEndUtc     DATETIME2(3) NOT NULL
    ReasonText       NVARCHAR(500) NOT NULL
    SourceSystem     NVARCHAR(100) NULL      -- e.g. 'Legacy MES (EXCSRV05)'
    AppUserId        BIGINT   NOT NULL FK Location.AppUser
    CreatedAt        DATETIME2(3) NOT NULL
    CONSTRAINT UQ_ProductionCatchUp_LineWindow
        UNIQUE (LineLocationId, WindowStartUtc, WindowEndUtc)
```

Plus `Workorder.ConsumptionEvent.ProductionCatchUpId BIGINT NULL` with a filtered index, so
every catch-up row is identifiable and reversible as a set.

Default `ReasonText` (**ASCII only** — the house rule; `sqlcmd` turns an em-dash into
mojibake):

```
Starting up MES - data not for traceability, catching up to production
```

The unique constraint on `(line, window)` is what stops a double-apply.

### Proc

```
Workorder.ProductionCatchUp_Apply
    @LineLocationId      BIGINT,
    @FinishedGoodItemId  BIGINT,
    @PartsProduced       INT,          -- from legacy
    @WindowStartUtc      DATETIME2(3),
    @WindowEndUtc        DATETIME2(3),
    @ReasonText          NVARCHAR(500) = NULL,
    @AppUserId           BIGINT,
    @Commit              BIT = 0
```

For each line of the FG's published BOM it computes `QtyPer × @PartsProduced` and
FIFO-consumes from line stock, using **the same availability guard as
`Assembly_CompleteTray`** — exclude `Closed`/`Open`, exclude `BlocksProduction = 1`. The two
must agree or catch-up will disagree with live production.

### Short stock is reported, not refused

Stock will very likely be insufficient — that is the condition we are recovering from. So
catch-up **consumes what is there and reports the remainder as an explicit deficit** rather
than refusing the whole adjustment.

The deficit is a first-class output, never a silent truncation: per component, *required /
consumed / deficit*. That figure is the answer to "identify my inventory status" — it is
exactly how much stock MES never knew about.

### Preview / commit

`@Commit = 0` **runs the statements inside a transaction and rolls back** — per the house
one-off-remediation rule, a preview that skips the writes proves nothing and surfaces a
guard only on the commit run. It returns the full per-component table either way.

---

## 7. Piece 4 — Summary adjustment per part

The output of § 6 *is* the summary adjustment: one `ProductionCatchUp` header per
(line, window), and one consumption roll-up per component beneath it. No per-tray
reconstruction.

Alongside it, a dated note in `notes/` recording: the window, the legacy production figure
used and where it came from, the per-component required/consumed/deficit table, and a plain
statement that **finished-good production for this window is recorded in legacy, not MES**.
That note is the artifact anyone reading this window later needs.

---

## 8. Guard rails

- Every change goes **through procs**, never a raw `UPDATE`, so validation and audit rows
  come with it.
- `@Commit = 0` first, always; the armed script exists in the working tree only and is
  never committed armed.
- The catch-up is **reversible as a set** via `ProductionCatchUpId`.
- Re-run `sql/scratch/2026-09-15_line_run_audit.sql` before and after; the before/after
  pair is the evidence the adjustment did what it claimed.

---

## 9. Out of scope (and why it still matters)

**Nothing escalates a repeated failure to a human.** That is the actual root cause of "25
hours and nobody knew", and none of the four pieces above fixes it. A blocking modal is not
the answer either — the failing path has no operator attached.

What fits is a **gateway-level alarm on repeated `Audit.FailureLog` writes per location**:
N failures in M minutes at one location raises an alarm and notifies. It is a separate,
small piece of work and it should not be smuggled into this spec, but it is the one change
that would have turned this incident into a 20-minute phone call.

**Also out of scope:** the `-0000` / `-J000` pack-out split found in §5.1 of the audit
(Jacques is correcting it manually), and the die-cast side of the value stream.

---

## 10. Open decision

**Where the pause flag is authored.** The Config Tool's Plant Hierarchy screen already
edits `LocationAttribute` values, so the flag is settable there with no new UI. But pausing
is a shop-floor act under time pressure, and sending someone into the Config Tool mid-shift
is friction that may push people toward blunter instruments.

Options: (a) Config Tool only — zero new UI; (b) add a supervisor-elevated
Pause/Resume control on the line's assembly screen; (c) both.

Recommendation is **(a) for now, (c) eventually** — get the mechanism right before
spending UI on it, since tonight it will be set once by Jacques rather than routinely by
supervisors.
