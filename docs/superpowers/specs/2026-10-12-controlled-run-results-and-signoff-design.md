# Super-lot piece 3 — inspection results, signed release, deviation record

> **Status: DRAFT 2026-10-12. NOT APPROVED. NOT BUILT.** Handoff for another agent.
> Third of six pieces. Section 9 lists what is still Jacques's to decide; **do not build
> past an open decision.** This draft is lighter on code-level grounding than pieces 1
> and 2: where it says "verify", it has not been checked.

> **Built together with piece 2 (decided 2026-10-12).** Piece 2 is now small: let the
> member helper tag the Closed tray LOTs of an unshipped container, plus its tests. It
> has no release path of its own, so it and this piece are ONE plan and ONE build. Read
> section 8a of `2026-10-12-controlled-run-completed-containers-design.md` for the
> answers that apply here: AIM is told nothing when a container is tagged; a tagged
> container may move anywhere; a container may be on a hold and a super-lot at once.
> This piece's bulk release must therefore cover completed containers wherever they are,
> and must never post an already-posted AIM serial a second time.

**Read first:** `notes/2026-10-12_crt-super-lot-and-nonconformance-overview.md`; the piece 1
spec (`2026-10-12-controlled-run-super-lot-design.md`, built) and piece 2 spec
(`2026-10-12-controlled-run-completed-containers-design.md`); `CLAUDE.md`.
**Branch:** `jacques/controlled-run-super-lot`. Nothing deploys until all six pieces are in.

---

## 1. Problem

A super-lot can be opened, filled, labelled and closed, but closing it says nothing about
what happened in between. Members are released one LOT or one container at a time by
clearing a tag; the only record is a `CrtCleared` audit row per LOT. There is no record
that the 200% inspection was done, of what it found, of who accepted the result, or of a
deviation that was judged acceptable.

MPP asked for three things that are really this one step: releasing many CRT LOTs at
once (change order A), a quality deviation and approval workflow with dispositions
(change order B), and an elevated electronic signature for quality approvals (B).

Confirmed with Jacques, 2026-10-12:

- The system **does not force** the 200% inspection. On release, Quality **confirms** the
  CRT was acted on and the inspection was completed.
- The outcomes of the inspection are counted per member: good, scrap, rework, return to
  vendor. The **nonconformance**, as MPP use the word, is the case where a deviation is
  found and judged not to affect part performance — Use-As-Is, signed.
- "Pending" is simply a super-lot that is still open.
- Scrap is entered **per member** (the inspector knows which container the bad part came
  from), on one screen, one submit — not as a group total spread across LOTs.

## 2. Scope

**In:**

- A **results** record per member: how many pieces were inspected and what became of them.
- **Scrap** from a super-lot member, including a member that is on a real hold.
- A **signed release** of some or all members in one action, carrying the confirmation
  that the inspection was done.
- A **deviation (nonconformance) record** attached to the super-lot for the Use-As-Is
  outcome.
- A **signature record**: who approved what, with what meaning, when.
- A **Quality-only gate** on the approval, if roles exist by then (9.1).
- The **Results** and **Sign-off** tabs on the super-lot view (placeholders exist).

**Out:**

| Not here | Piece |
|---|---|
| Scrap out of a **Closed** tray LOT, reopening a container, top-up, re-serial, relabel | 4 |
| Rework and Return to Vendor as outcomes with real material effects. This piece **records the counts**; what physically happens to those pieces is piece 5 | 5 |
| Showing any of this on LOT Detail, genealogy, reports, dashboards | 6 |
| Intelex. Out of scope for the whole feature | — |

## 3. What exists that this builds on

| Existing | Use |
|---|---|
| `Quality.ControlledRun` / `ControlledRunMember` / `ufn_ControlledRunMemberState` | The case and its members. `ControlledRunMemberEndReason` was created expecting this piece to add outcome codes |
| `Workorder.RejectEvent_Record` | The one scrap mechanism: one LOT, one defect code + quantity, decrements the LOT. Refuses `Scrap` / `Closed` / `Open` status, and `Hold` unless `@AllowHeldLot = 1`. **Has no CRT guard**, so a tagged WIP LOT can be scrapped today |
| `Workorder.RejectEvent_RecordByPartFifo` | Precedent for many reject rows in one transaction from a JSON list. It does **not** look at `CrtActive` — see 6.3 |
| `Quality.DispositionCode` | Exists with four rows: `UseAsIs`, `Rework`, `Scrap`, `ReturnToSupplier`. No `Pending`. Change order B says "Return to Vendor" |
| `Quality.DefectCode` (+ `Quality.DefectCode_ListRankedForLocation`) | Scrap reasons |
| `Lots.Lot_ClearCrt`, `Lots.Container_ValidateCrt` | The per-unit clears a bulk release must mirror (one `CrtCleared` audit row per LOT is a traceability requirement, not a nicety) |
| `BlueRidge.Location.AppUser.elevate(...)` | Credential check + `ElevationGranted` audit row. **No role gate**: any active AD-mapped user passes |
| `Quality.NonConformance` | **Does not exist in the database.** Documented in `MPP_MES_DATA_MODEL.md` and FDS 8.6 only. `HoldEvent.NonConformanceId` and `QualityAttachment.NonConformanceId` were never built either |
| `Quality.QualityAttachment` | File metadata; only links to a `QualitySample` today |

## 4. Proposed design

Everything here is a recommendation until Jacques agrees it.

### 4.1 Results

A new append-only table, one row per **entry** against a member:

```
Quality.ControlledRunResult
  Id, ControlledRunMemberId (FK), DispositionCodeId (FK -> Quality.DispositionCode),
  Quantity INT (> 0), DefectCodeId (FK, NULL -- required for Scrap),
  RejectEventId (BIGINT NULL -- the scrap row this entry produced, if any),
  Remarks, AppUserId, TerminalLocationId, RecordedAt
```

- "Good" needs a code. **(proposed)** add `Accepted` to `Quality.DispositionCode`
  rather than overloading `UseAsIs`: "the part is fine" and "the part deviates and we
  accept it" are different statements, and only the second is a nonconformance.
- Corrections are a new row, never an edit. If a wrong entry must be undone, a reversing
  entry is the audited way — decide whether that is needed in v1 (9.4).
- The sum of a member's result quantities need not equal its piece count while the
  super-lot is open. Whether it must at release is decision 9.3.

### 4.2 Scrap

A Scrap result **calls the real scrap mechanism** so piece counts, the reject reports and
genealogy stay true: one `Workorder.RejectEvent` per (LOT, defect code), stamped as the
existing procs stamp it.

- The orchestrating proc is captured via `INSERT … EXEC`, so it cannot `EXEC`
  `RejectEvent_Record`. Either inline the reject block (as `RejectEvent_RecordByPartFifo`
  does, commented as a mirror) or — better — extract a **silent internal helper** the way
  piece 1 did for members, and have both callers use it. Read
  `R__Quality_ControlledRun_ApplyMembersInternal.sql` for the pattern.
- A container member's scrap lands on a specific tray LOT. Closed tray LOTs cannot be
  scrapped until piece 4; until then a Scrap result on a completed container is
  **recorded as intent only** (`RejectEventId` NULL) and piece 4 turns it into material
  movement. Say so on the screen.
- Scrap needs `ChargeToParty` / location stamping the same way the existing scrap paths
  do (migration `0067`). Verify what `RejectEvent_Record` requires today.

### 4.3 Signed release

One action releases the ticked members of a super-lot:

- Clears `CrtActive` on each LOT (and each tagged tray LOT of each container) with **one
  `CrtCleared` audit row per LOT**, exactly as the per-unit paths do.
- Ends those memberships with a new end reason (`Released`).
- Writes **one** signature row (4.5) covering the action, and links each released member
  to it.
- Carries a required confirmation: *"The Controlled Run Tag was acted on and the 200%
  inspection was completed for these members."* Stored as a fact on the signature row,
  not as free text.
- For containers, the AIM step that `BlueRidge.Lots.Container.validateCrt` performs
  after clearing must still happen (post the held serial). Piece 2 decides what AIM is
  told about an already-posted serial; follow it.
- When the last member is released the super-lot can close. **(proposed)** closing stays
  its own action (piece 1's `ControlledRun_Close`), so "everything is released" and "the
  case is finished" remain separate statements.

The per-unit clears on LOT Detail and in the `CrtValidation` popup keep working. Decide
whether a unit that is in a super-lot may still be cleared there, bypassing the signed
release (9.5).

### 4.4 Deviation (nonconformance) record

**(proposed)** Build the deviation as a child of the super-lot, not as the standalone
`Quality.NonConformance` table the data model describes:

```
Quality.ControlledRunDeviation
  Id, ControlledRunId (FK), DeviationNumber, Description (what deviates),
  Justification (why it does not affect part performance),
  DefectCodeId (NULL), AffectedQuantity (NULL), SignatureId (FK), RaisedAt
```

Why not the documented table: it is single-LOT (`LotId NOT NULL`, one defect code, one
quantity), and MPP's deviation covers a group and exists only as the outcome of a
super-lot. If MPP later want a nonconformance with no super-lot behind it, that is the
time to generalise. This is a real fork — decision 9.2 — and whichever way it goes,
`MPP_MES_DATA_MODEL.md` and FDS 8.6 must be brought into line, because today they
describe a table that was never built.

A Use-As-Is result requires a deviation record. `Quality.QualityAttachment` could carry
supporting files if it gains a nullable `ControlledRunDeviationId`.

### 4.5 Signature record

```
Quality.Signature
  Id, AppUserId (the approver), SignedAt, MeaningCode (FK -> a small code table:
  ControlledRunRelease, DeviationApproval, ...), EntityType / EntityId (what was signed),
  Statement NVARCHAR (the exact words shown at signing), TerminalLocationId
```

- The signature is created **only** after `elevate()` succeeds with the stateless,
  per-action form (the one the super-lot view already uses). The approver's `AppUserId`
  goes straight to the proc; it is never stored on the session.
- It is "distinct from standard operator sign-in" because a PIN sign-in is an identifier,
  not a credential, and a signature takes an AD password at the moment of signing.
- This table is deliberately generic: it is the "elevated electronic signature
  capability" of change order B, and other approvals can use it later.
- Store the statement text shown to the signer. A signature whose meaning has to be
  reconstructed from code is not much of a signature.

### 4.6 The view

On `/shop-floor/controlled-runs` the **Results** and **Sign-off** tabs are placeholders
drawn disabled. This piece makes them live:

- **Results:** the member list with entry per row — accepted, scrap (defect code +
  quantity, several reasons allowed), rework, return, use-as-is. Rows with nothing wrong
  default to "all accepted" in one action.
- **Sign-off:** what is ready to release, the confirmation, the deviation form when any
  Use-As-Is exists, the credential, and the history of signatures on this super-lot.

Mock it before building, as piece 1 did (`mockup/controlled_run_super_lot_mock.html`).
The existing view files are **generated JSON that is now committed**; edit them in
Designer per the project's view-edit boundary, or regenerate deliberately — do not
hand-edit large view JSON.

## 5. Quality-only gate

`elevate()` returns `ignitionRole`. There is no action-to-role map anywhere, and Jacques
has said AD roles are coming. This piece should **define the seam** — a single SQL place
that answers "may this user sign this meaning?" — and enforce it only if roles exist.
If they do not, say plainly on the sign-off screen and in the status entry that any
AD-mapped user can sign. Do not invent a role table to fill the gap (CLAUDE.md: no
custom RBAC tables).

## 6. Things to check, not assume

1. What `RejectEvent_Record` requires today (charge-to party, terminal, operation type)
   and whether a scrap from a quality inspection has a sensible `OperationTypeCode`.
2. Whether a member on a real hold should be scrapped with `@AllowHeldLot = 1`.
3. `RejectEvent_RecordByPartFifo` ignores `CrtActive`, so line scrap can land on a
   super-lot member or skip one. Decide with Jacques whether line scrap should skip
   tagged LOTs; it is a behaviour change outside this view.
4. Whether `AimPost.postOne` is safe to call for a serial that is already posted.
5. Piece 1's `Close` refuses while any member is tagged. With `Released` memberships
   ended, confirm the totals in `ControlledRun_Get` / `_List` still read sensibly (they
   count open members plus `RunClosed` ones today).

## 7. Constraints that will bite

Same as piece 2, section 6: status-row procs may not `EXEC` each other or `ROLLBACK`
inside `INSERT … EXEC` (use silent helpers); validations before `BEGIN TRANSACTION`;
piece 1's mutation procs were generated by a script that is not in the repo — edit the
committed `.sql`; no rule in Python or a view expression; tests in
`sql/tests/0109_ControlledRun/` (171 assertions at hand-off) on a **private** database.

## 8. Testing this piece must add

- Results: entries append; quantities validated; a Scrap entry on a WIP LOT writes a
  `RejectEvent` and decrements the LOT; a Scrap entry on a completed container records
  intent only.
- Release: every ticked member cleared with one `CrtCleared` row per LOT; one signature;
  unticked members untouched; all-or-nothing on any failure; a member taken or changed
  mid-flight gives a clean refusal (piece 1's `SUPERLOT_RACE` pattern).
- The confirmation is required; without it, nothing is released.
- Use-As-Is cannot be released without a deviation record and its signature.
- A released LOT can be consumed and moved again; a released container can ship.
- Signature rows are never updated or deleted.

## 9. Decisions for Jacques

1. **Quality-only signing.** Enforce now (needs AD roles), or ship the seam and state the
   limitation?
2. **The deviation record.** A child of the super-lot (recommended), or build the
   standalone `Quality.NonConformance` the data model describes and attach super-lots to
   it?
3. **Must results add up before release?** Recommended: no hard wall — require a result
   for every released member, but do not force quantities to equal the piece count; show
   the difference. A hard wall invites made-up numbers.
4. **Corrections.** Reversing entries in v1, or accept that a wrong entry is annotated
   and left?
5. **Per-unit clears for super-lot members.** Still allowed on LOT Detail (recommended
   no: once a unit is in a super-lot, it leaves through the signed release or by being
   removed with a reason)?
6. **An `Accepted` disposition code** for "good", and renaming `ReturnToSupplier` to
   match MPP's "Return to Vendor"?
7. **Does MPP need a deviation number in their own format**, or their own approval
   wording on the signature?

## Revision History

| Date | Change |
|---|---|
| 2026-10-12 | Initial draft, written as a handoff for another agent. Not approved. |
