# Die Cast Counter Anchor — Design Spec

**Date:** 2026-09-10
**Status:** Implemented (migration `0074`)
**Author:** Blue Ridge (with Claude)
**Arc / Phase:** Arc 2 (Plant Floor) — Die Cast. Closes edge cases **E3** and **E4** of the shot-reading chain.
**Origin:** Day-two deployment feedback, 2026-09-10 (Die Cast). An operator hit the backwards-reading wall on the Release dialog and had no way past it.
**Builds on:** `docs/superpowers/specs/2026-09-09-diecast-shot-reading-chain-design.md`, migration `0073`, commits `b48d6bff` / `b3b93d60` / `82feaaa7`.

> ⚠️ **Prod is live.** This changes nothing about how an existing number is computed — with no anchor recorded, every value is byte-for-byte what it was. It only adds a way to record a new kind of fact.

---

## 1. Motivation

### 1.1 What the operator saw

The Release dialog, mid-shift, on basket `10627564`:

> **That reading is behind the last reading recorded for this die, 2,124 for this shift. Check the number you wrote down.**

`Release basket` was disabled. Cancel was the only way out.

### 1.2 Two defects, one screen

**The rolling total was invisible until it blocked you.** `Workorder.DieCast_GetReleasePreview` has returned `DieCreditedThrough` since it was written, but the only component that read it was the red `Advisory` label, whose `position.display` binding is `readingState != "Ok" || belowStandardAfter`. So the number that governs every reading on the die was shown *only* in the sentence rejecting one. An operator could not check their reading against it beforehand, because nothing told them what it was.

**There was no way past the wall.** Three places refuse a reading below the die watermark — `Lots.DieCastLot_Release:151`, `Workorder.DieCastShiftOutput_Record`, and the Release button's `enabled` binding. All three are right for a typo. None of them has an exit for the two cases the floor actually hits:

| Case | What happens today |
|---|---|
| The press counter was reset mid-shift (power loss, maintenance, controller swap). It genuinely reads a smaller number now. | Every honest reading for the rest of the shift is refused. |
| A wrong number was entered earlier — someone typed a basket total where a counter reading belongs — and it has poisoned the watermark. | Same, and the poison stays until the shift rolls. |

The 2026-09-09 spec named both (E3, E4) and deferred them: *"a supervisor-elevated override is possible but should be deferred until MPP shows it is needed."* MPP has now shown it.

### 1.3 Why appending could not fix it

Both watermarks were `MAX(ShotCounterReading)` over the shift. **A MAX cannot be lowered by appending a row.** Every mechanism the system already had — record another contribution, release another basket — could only push the number *up*. Correcting downward meant editing an append-only ledger, which is why it had no implementation rather than a bad one.

---

## 2. Decisions locked

1. **Re-anchor, not bypass.** The operator declares the true reading and the correction holds for every subsequent read this shift. A per-release bypass would defer the same wall by exactly one basket.
2. **Any signed-in operator, with a mandatory reason.** No AD elevation. The operator is the only person who can see the press counter, and gating on a supervisor strands a night shift. The reason code and the audit row are the control.
3. **Forward-only.** An anchor sets where crediting *resumes*. Pieces already credited to baskets stay; `Tools.Tool.ShotCount` keeps what it has. See §7.
4. **A floor, not an override.** A contribution recorded after an anchor supersedes it normally. The chain resumes; the anchor is not sticky.
5. **Both die-cast entry points.** Release dialog and Record Shift Output. They share one popup and one proc.
6. **Its own table.** Not a `DieCastContribution` row — see §3.2.

---

## 3. The model

### 3.1 The floor

```
watermark = MAX( anchor.DeclaredReading,
                 MAX(reading) over contributions recorded AFTER the anchor,
                 0 )
```

Only the **latest** anchor for `(ToolId, ShiftId, CellLocationId)` participates. With no anchor the expression collapses to the pre-change `MAX(...)`, which is why §1's promise holds literally.

Contributions at *exactly* the anchor's `EventAt` are excluded (strict `>`). An anchor recorded in the same millisecond as a contribution is correcting it, so the anchor must win.

### 3.2 Why the floor reaches every cavity — and why that needs a table

The anchor is recorded against the **die**, and `ufn_CavityShotWatermark` floors **every cavity on that die** at it.

That is the whole reason it cannot be a contribution row. `Workorder.DieCastContribution.LotId` is `NOT NULL` (migration `0045`), so a contribution can only ever speak for a cavity that has an open basket. The correction must reach cavities that are Closed, Scrapped, or simply empty — because the next basket opened on any of them inherits that cavity's watermark, and an un-floored cavity would then be credited from a number the die no longer stands at.

The floor works in **both directions**, which is not an accident:

| Situation | Cavity watermark before | Anchor | After | Why it is right |
|---|---|---|---|---|
| Poisoned by a wrong entry | 2124 | 10 | **10** | Floored *down* — crediting resumes from the true reading. |
| Never produced this shift | 0 | 10 | **10** | Floored *up* — otherwise the next basket invents 10 shots of production. |
| Counter reset | 2124 | 0 | **0** | The start-of-shift state, with no special case. |
| Die changed over onto a running press | 0 | 1500 | **1500** | The incoming die does not inherit the outgoing die's shots. |

A counter reset is simply `DeclaredReading = 0`. E4 needs no code of its own.

### 3.3 No monotonic guard on the declaration

`@DeclaredReading` is bounded only by `>= 0`. Declaring a *lower* number is the entire point of the feature; guarding it would reintroduce the wall inside the tool built to get past it. The reason code, the note, and the audit row are the control.

---

## 4. Data model (migration `0074`)

```sql
Workorder.DieCastCounterAnchorReason      -- code table, 4 seeded rows
    Id, Code, Name, Description, SortOrder

Workorder.DieCastCounterAnchor            -- the declaration
    Id, ToolId, ShiftId, CellLocationId, DeclaredReading,
    ReasonId, Note, AppUserId, TerminalLocationId, EventAt
    CK_DieCastCounterAnchor_ReadingNonNeg  CHECK (DeclaredReading >= 0)
    IX_DieCastCounterAnchor_Scope (ToolId, ShiftId, CellLocationId,
                                   EventAt DESC, Id DESC) INCLUDE (DeclaredReading)
```

**Scoped by press**, the same three-part key the watermarks use, and load-bearing for the same reason: a die moved to another press is a different counter space; a changeover to another die on the same press has different `ToolCavity` rows.

**Append-only.** Superseding an anchor means recording a later one. No `UPDATE` path, no `DeprecatedAt` — the chain of declarations *is* the history.

Reasons: `CounterReset`, `WrongReadingEntered`, `DieChangeover`, `Other` (note required). Audit event type `DieCastCounterAnchored`, entity type the existing `Tool` (31) — an anchor is a statement about a die on a press, not about any one LOT.

---

## 5. Procedures

| Object | Version | Change |
|---|---|---|
| `Workorder.ufn_DieShotWatermark` | 2.0 | Anchor floor. |
| `Workorder.ufn_CavityShotWatermark` | 2.0 | Anchor floor; resolves the cavity's own tool so a caller cannot pass a mismatched one. |
| `Workorder.DieCastCounterAnchor_Record` | 1.0 (new) | The write. All validation pre-transaction, status row, `Warning` severity audit carrying old → new watermark. |
| `Workorder.DieCast_GetCounterContext` | 1.0 (new) | The rolling total plus its provenance. **Always exactly one row** — an unknown tool or shift returns a zero with `SourceKind 'None'`, never an empty set, because both screens bind nested paths into it. Timestamps converted to Eastern at the boundary. |
| `Workorder.DieCastCounterAnchorReason_List` | 1.0 (new) | Dropdown source. `RequiresNote` derived from `Code`. |
| `Workorder.DieCast_GetReleasePreview` | 1.1 | Appends `ToolId`, so the dialog can anchor without a second lookup. |

`SourceKind` is `None` / `Entry` / `Anchor`. An entry recorded above an anchor names *itself* — it is what the number now is, and naming the superseded anchor would mislead.

---

## 6. UI

**Both screens gain the same two things**, above the field they explain:

> This die is at **2,124** for the shift (recorded 14:12 by JP).

and a `Counter reset / wrong total?` button. On the Release dialog that button is quiet (`pf-btn-secondary`) until `readingState = "Behind"`, at which point it turns primary — it is then the only enabled action on the row, and should look like it.

**The popup** (`Popups/DieCastCounterAnchor`) shows the recorded total and its provenance, takes the actual reading, a reason, and a note, and states the consequence in the operator's language:

> Crediting resumes from **12**. Pieces already on the baskets are **NOT** changed, and the die keeps the shot count it already has.

It **writes its own anchor** rather than handing numbers back — it already holds every one of them, and the caller only needs to know the watermark moved. It replies page-scoped `dieCastAnchorResult`; both callers bump a refresh token.

**The refresh token is load-bearing.** An anchor changes the watermark without changing any real input of the preview binding, so nothing would re-evaluate and the dialog would go on quoting the number that had just been superseded. `getReleasePreview` and `getCounterContext` therefore take an unused `_refreshToken` (the same device as `getBulkOpenRowInstances`' `_optionsToken`). On the shift-output screen the handler also **clears the computed breakdown**, whose per-cavity credits were derived from a floor that no longer applies.

---

## 7. What this deliberately does not fix

**Pieces already credited stay on their baskets.** A wrong reading that inflated a basket did so by writing a `DieCastContribution` row and incrementing `Lots.Lot.PieceCount`; those are recorded facts and the anchor does not rewrite recorded facts. The dialog says so in as many words, and `DieCastCounterAnchor_Record`'s success `Message` repeats it — if either ever stops saying it, operators will assume the baskets were fixed too. Correcting a wrong basket count is a separate action.

**`Tools.Tool.ShotCount` keeps the inflation, and this is worth watching.** The shipped `ufn_DieShotWatermark` header documents that release *also* advances `ShotCount` — reversing decision 7 of the 2026-09-09 spec, because a changeover closes the lots and the outgoing die may never see a shift-output entry. A consequence nobody chose: a typo'd `2124` added 2,124 of phantom die life against `ShotLimit`, and a forward-only anchor leaves it there. **Open item:** a die could run past its limit on shots it never fired. Not addressed here; raise it if the die-life numbers start to drift.

---

## 8. Testing

`sql/tests/0022_PlantFloor_DieCast/100_CounterAnchor.sql` — **40 assertions, all passing.**

The three that matter most:

1. **With no anchor, nothing changed** — the v2.0 functions return exactly what v1.0 returned, or every existing die-cast test is passing for a new reason.
2. **The floor reaches a cavity with no basket** — the property a contribution row could never have.
3. **Forward-only** — pieces and `ShotCount` are asserted unchanged across an anchor, and the reply is asserted to *say* they are unchanged.

Plus: the refused reading becoming usable, reset-to-0, both floor directions, an entry superseding an anchor, the context read's three `SourceKind` values and its always-one-row contract, and five rejections that write nothing.

Fixtures are self-contained, per the `Msg 515` seed-dependency failures that still affect four sibling suites in this folder (`task_a2b8d904`, pre-existing).

---

## 9. Deployment

Additive and idempotent-guarded. No backfill, no cutover window — with no anchor rows the behaviour is unchanged, so it can land mid-shift.

**Order:** migration `0074`, then the six repeatables, then the Ignition resources. The views call procs that must already exist.

---

## 10. Out of scope

- Reversing pieces credited by a superseded reading (§7).
- `ShotCount` correction (§7) — flagged as an open item.
- Time-ranged shot-loss attribution (E8, unchanged).
- Any terminal other than die cast.
