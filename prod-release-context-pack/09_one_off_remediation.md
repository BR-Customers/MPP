# One-off remediation against live data

Sometimes prod holds a row that is wrong and no screen can reach — a basket stranded Open at a press whose die came off, a quantity that drifted. Fixing it is not a release, but it follows the same shape at smaller scale.

> **A remediation is not a way to skip the release process.** If the fix is a code change, it is a release. This file is for repairing *data* that existing, already-deployed procs can repair. If you find yourself writing DDL, or changing what a proc does, stop — you are writing a release and it belongs in `sql/migrations/`.

---

## The three rules

**1. `@Commit = 0` runs the statements inside a transaction and rolls back. It never skips them.**

A preview that skips the writes proves nothing, and will surface a guard only on the commit run — which is the one moment you did not want a surprise. The dry run must exercise every validation the real run will.

```sql
DECLARE @Commit BIT = 0;
...
BEGIN TRANSACTION;
BEGIN TRY
    -- the real statements, always
    ...
    IF @Commit = 1 COMMIT TRANSACTION; ELSE ROLLBACK TRANSACTION;
END TRY
BEGIN CATCH
    IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
    ...
END CATCH
```

**2. Go through the procs. Never a raw `UPDATE`.**

The proc carries the validation and writes the audit rows. A hand-written `UPDATE` produces a change with no `LotEventLog` entry, no `ConfigLog` entry, and no explanation — and Honda traceability is the product. Capture the proc's status row and check it:

```sql
DECLARE @R TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO @R EXEC Lots.Lot_Release @LotId = @LotId, @AppUserId = @AppUserId, ...;
SELECT @St = Status, @Msg = Message FROM @R;
IF @St <> 1 BEGIN RAISERROR(N'Refused: %s', 16, 1, @Msg); ROLLBACK TRANSACTION; RETURN; END
```

**3. Arm the script in the working tree only. Never commit one armed.**

`@Commit = 1` lives for the minutes it takes to run. Set it back to `0` before committing. A committed armed script is a loaded gun in the repo for whoever runs it next.

---

## The shape of the script

File it as `sql/scratch/<date>_<slug>.sql`. `2026-09-14_close_stranded_basket.sql` is the reference implementation; read it before writing your own. Its structure:

**A header that states ONE JOB**, in a sentence, then *why the row is wrong*, then *what the fix does and why that is the right fix*:

> `ONE JOB: close basket 10627569, keeping its piece count as it stands.`
>
> It was left Open at DC1-M11 when DMO124 came off, so it appears on no screen and cannot be reached. Releasing it makes it Good at storage, where it rejoins its route and shows up in the Trim IN queue like any other basket.
>
> `@FinalPieceDelta = 0` and NO counter reading: the basket is settled where it stands, not credited. A reading would credit (reading − cavity watermark), and that watermark is press-scoped, so on a die that has moved presses it invents castings.

**Session settings.** `SET NOCOUNT ON; SET XACT_ABORT ON; SET QUOTED_IDENTIFIER ON;` — the last is not optional: `Lots.Lot` carries a filtered index and DML against it needs it.

**Parameters as `DECLARE`s at the top**, including `@Commit`. Names and initials, not ids — a script keyed on `@LotName = N'10627569'` is reviewable; one keyed on `@LotId = 88213` is not.

**Resolve and guard before the transaction.** Look up ids, then `RAISERROR ... RETURN` on every precondition: row not found, user not found, wrong status, nothing to do. Print the state you found before acting.

**An explicit out-of-scope paragraph.** The reference script carries one, and it is the most valuable thing in it:

> **NOT IN SCOPE, deliberately.** This LOT's `PieceCount` (2501) and `InventoryAvailable` (2991) disagree by 490 — drift from a manual Good→Open reopen that set one column without the other and left no `LotAttributeChange` row. **No existing proc can repair it:** `Lot_RectifyPieceCount` and `Lot_Update` both refuse a no-op count change, and both also refuse an Open LOT. Closing the basket does not require touching it. Tracked separately.

Saying what you are *not* fixing, and why, is what stops the next person assuming it was handled.

---

## Read the proc's guards before you chain it

Guards are not in the proc headers. Both `Lot_RectifyPieceCount` and `Lot_Update` reject a LOT whose status is `Open`, `Closed` or `BlocksProduction`, **and** both no-op-reject when the supplied `@PieceCount` equals the current value. So neither can realign `Lot.InventoryAvailable` when `PieceCount` is already correct — a divergence between the two materialized quantities has **no audited repair path today**.

Discovering that mid-run is how a remediation turns into an improvisation. Open the proc, read the validations, and confirm your path through them before you write the script.

---

## Running it

1. Run with `@Commit = 0`. Read the `PRINT` output and every status message. The guards must all pass and the statements must all succeed.
2. Have someone read the script — it is a write against a live plant with no fingerprint and no backup gate.
3. Take a backup if the change is not trivially reversible through the same procs.
4. Set `@Commit = 1`, run, confirm.
5. Set it back to `0`. Commit the script with the outcome in the header or in `notes/`.
6. Verify through the UI or a read proc, not by selecting the row you just wrote.

---

## When it is not a remediation

| Situation | Where it belongs |
|---|---|
| The proc needs to allow something it currently refuses | A release — repeatable proc change |
| A column is wrong for every row, not one | A release — versioned migration with a backfill |
| The same repair has now been needed twice | A release — fix the cause, or add the missing proc |
| You cannot do it through any existing proc | Stop. Either the proc is missing (a release) or the change should not happen. |
