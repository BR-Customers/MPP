# Super-lot piece 3 — inspection results, signed release, deviation record

> **Status: BUILT 2026-10-13. SQL tested; views walked up to the sign-in prompt. See section 12 for what differs from this spec and what is still unverified.** Third of six
> pieces. Every decision in the first draft's section 9 is answered (section 2). Sections
> marked *verified* were checked against the code on 2026-10-12/13.
>
> **Built together with piece 2** as ONE plan, ONE migration and ONE build
> (`2026-10-12-controlled-run-completed-containers-design.md`). Nothing in this feature
> deploys until all six pieces are in.

**Read first:** `notes/2026-10-12_crt-super-lot-and-nonconformance-overview.md`; the piece 1
spec (built) and piece 2 spec; `CLAUDE.md`.
**Mockup:** `mockup/controlled_run_results_signoff_mock.html` (scene 1 Results, 2 Sign-off,
3 signed release, 4 deviation). Scenes 2-4 approved by Jacques 2026-10-13; scene 1 is the
accordion layout he asked for.
**Branch:** `jacques/controlled-run-super-lot`.

---

## 1. Problem

A super-lot can be opened, filled, labelled and closed, but closing it says nothing about
what happened in between. Members are released one at a time by clearing a tag; the only
record is a `CrtCleared` audit row per LOT. There is no record that the 200% inspection
was done, of what it found, of who accepted the result, or of a deviation that was judged
acceptable.

MPP asked for three things that are this one step: releasing many CRT LOTs at once
(change order A), a deviation and approval workflow with dispositions (B), and an elevated
electronic signature for quality approvals (B).

Confirmed with Jacques, 2026-10-12:

- The system **does not force** the 200% inspection. On release, Quality **confirms** it
  was done.
- Outcomes are counted per member: good, scrap, rework, return to vendor. The
  **nonconformance** is the Use-As-Is outcome with a signed deviation.
- "Pending" is simply a super-lot that is still open.

## 2. Decisions (all answered by Jacques, 2026-10-12 and 2026-10-13)

| # | Decision |
|---|---|
| D1 | **Signing gate is a seam only.** One SQL function answers "may this user sign this meaning?". Today it passes any active AD-mapped user. The Sign-off tab and the status entry say so plainly. No role table is invented. |
| D2 | **The deviation is a child of the super-lot** (`Quality.ControlledRunDeviation`), not the standalone `Quality.NonConformance` the data model describes. **The FDS is NOT edited** - "the FDS is a record of what was planned, not what is." `MPP_MES_DATA_MODEL.md` is updated, because it documents the schema as built. |
| D3 | **Results need not add up.** A released member needs at least one live result entry; quantities need not equal its piece count. The screen shows the difference ("left over"). |
| D4 | **Corrections: void and re-enter.** An entry is voided with a reason, never edited or deleted. A scrap entry that has already taken pieces off a LOT cannot be voided here. |
| D5 | **Per-unit clears stay allowed** for super-lot members (LOT Detail, the Assembly OUT CRT popup). The member then reads as untagged; it still leaves the super-lot only by signed release, removal, or the close. |
| D6 | **Add an `Accepted` disposition code.** Existing codes and names are left alone (`ReturnToSupplier` keeps its name; the screen label says "Return to vendor"). |
| D7 | **Deviation number is ours:** `DV` + 6 digits from `Lots.IdentifierSequence`, plus an optional free-text MPP reference. Signature wording is ours and is stored verbatim. |
| D8 | **A trigger refuses UPDATE and DELETE on `Quality.Signature`.** First trigger in the schema; deliberate. |
| D9 | **Results are entered inside a Quality sign-in window**, not a password per entry: one network sign-in, then work. **Quality screens get a 30-minute idle window** (section 6). The signed release and the deviation ask for the password again at the moment of signing, always. |
| D10 | **Results tab is an accordion** (`ia.display.accordion`): header = a summary-row view, body = an entry-form view built like Record Scrap at Trim and Assembly. **The component's built-in expand flag is used**; a reload preserves each item's `expanded` rather than replacing the toggle with our own. |
| D11 | **The existing super-lot page is changed by a scripted file edit** (Jacques: "you can make the changes"). New tabs are new views. |

Decided by me while completing the spec; small, and each is reversible. Say so if any is
wrong:

- **Cancel is refused once a release has been signed** on the super-lot. Cancel means "this
  grouping was a mistake"; after a signed release that is no longer true. Close it instead.
- **A released or removed unit is never brought back by the sync.** `ControlledRun_SyncInternal`
  already skips units removed by hand; released units join that list.
- **Totals count a released member as cleared for good,** even if it is tagged again later
  for another reason. Otherwise a closed super-lot's "cleared" count would drop afterwards.
- **No inline AIM post on release.** Clearing the tags is what returns a held serial to
  `Lots.AimShipperIdPool_ListUnposted`; the existing 60-second sweep posts it. An
  already-posted serial is not in that list, and `AimPost.postOne` returns
  `already_posted` without calling AIM if anything ever does ask (*verified*). One
  definition of "owed", no second post.
- **Quality ceiling: 4 hours** (`QualityElevationMaxSeconds = 14400`), configurable. The
  existing ceiling is 30 minutes from sign-in, so a 30-minute idle window alone would
  still end at 30 minutes in total.
- **File attachments on a deviation are not in this piece.**

## 3. Scope

**In:** results per member; scrap from a LOT member (including one on a real hold); a
signed release of ticked members with the inspection confirmation; the deviation record;
the signature record and its seam; the Quality sign-in window; the Results and Sign-off
tabs.

**Out:**

| Not here | Piece |
|---|---|
| Scrap out of a container's tray LOT, reopening a container, top-up, re-serial, relabel | 4 |
| Rework and Return to Vendor as material movements. This piece **records the counts** only | 5 |
| Any of this on LOT Detail, genealogy, reports, dashboards; the History tab | 6 |
| Intelex | - |
| Whether line scrap (`RejectEvent_RecordByPartFifo`) should skip CRT-tagged LOTs. A behaviour change outside this view; left as it is and listed in section 11 | - |

## 4. Data model — migration `0110_controlled_run_results_signoff`

One migration for pieces 2 and 3 (check the directory and `main` for the next free number
at build time). Idempotent per statement, ASCII-only.

### 4.1 Changes to existing tables

```sql
ALTER TABLE Quality.ControlledRunMember ADD
    WasCompleteAtJoin      BIT    NOT NULL CONSTRAINT DF_ControlledRunMember_WasCompleteAtJoin DEFAULT (0),  -- piece 2
    ControlledRunReleaseId BIGINT NULL     CONSTRAINT FK_ControlledRunMember_Release REFERENCES Quality.ControlledRunRelease(Id);

ALTER TABLE Location.SessionPolicy ADD
    QualityElevationTimeoutSeconds INT NOT NULL DEFAULT 1800,    -- 30 min idle
    QualityElevationMaxSeconds     INT NOT NULL DEFAULT 14400;   -- 4 h ceiling
    -- CHECK: timeout BETWEEN 30 AND 3600; max BETWEEN timeout AND 28800 (same bounds as 0049 / 0100)
```

Code rows: `Quality.DispositionCode` + `Accepted`;
`Quality.ControlledRunMemberEndReason` + `Released`;
`Lots.IdentifierSequence` + `ControlledRunDeviation` (`DV{0:D6}`);
`Audit.LogEventType` + `ControlledRunResultRecorded`, `ControlledRunResultVoided`,
`ControlledRunReleased`, `ControlledRunDeviationRaised`.

### 4.2 New tables

```
Quality.SignatureMeaning            (read-only code table)
  Id, Code, Name, Statement NVARCHAR(500)
  rows: ControlledRunRelease - "I confirm the Controlled Run Tag was acted on and the 200%
                                inspection was completed for the members being released."
        DeviationApproval    - "I approve this deviation: the condition described does not
                                affect part performance and the affected material is
                                accepted for use as is."

Quality.Signature                   (append-only; trigger refuses UPDATE / DELETE)
  Id, SignatureMeaningId (FK), AppUserId (FK, the signer), SignedAt,
  Statement NVARCHAR(500)  -- copied from the meaning AT SIGNING, so later rewording
                           -- never changes what somebody signed
  LogEntityTypeId (FK Audit.LogEntityType), EntityId BIGINT  -- what was signed
  TerminalLocationId (FK, NULL)

Quality.ControlledRunRelease        (one row per signed release action)
  Id, ControlledRunId (FK), SignatureId (FK), InspectionConfirmed BIT NOT NULL
  CHECK (InspectionConfirmed = 1), MemberCount INT, Remarks NVARCHAR(500) NULL,
  ReleasedByUserId (FK), ReleasedAt, TerminalLocationId (FK, NULL)

Quality.ControlledRunResult         (one row per entry; never edited, may be voided once)
  Id, ControlledRunMemberId (FK), DispositionCodeId (FK), Quantity INT CHECK (> 0),
  DefectCodeId (FK, NULL - required for Scrap), RejectEventId BIGINT NULL
  (the Workorder.RejectEvent this entry produced; NULL = nothing was taken off a LOT),
  Remarks NVARCHAR(500) NULL, RecordedByUserId (FK), TerminalLocationId (FK, NULL),
  RecordedAt, VoidedAt NULL, VoidedByUserId (FK, NULL), VoidRemarks NVARCHAR(500) NULL
  CHECK void columns all-or-none; index (ControlledRunMemberId) INCLUDE (...)

Quality.ControlledRunDeviation
  Id, ControlledRunId (FK), DeviationNumber NVARCHAR(15) UNIQUE,
  ExternalReference NVARCHAR(50) NULL, Description NVARCHAR(1000) (what deviates),
  Justification NVARCHAR(1000) (why it does not affect part performance),
  DefectCodeId (FK, NULL), AffectedQuantity INT NULL CHECK (> 0),
  SignatureId (FK), RaisedByUserId (FK), RaisedAt, TerminalLocationId (FK, NULL)
```

The confirmation is a **fact on the release row** (`InspectionConfirmed`, constrained to 1),
not free text. `Quality.Signature` stays generic: it is the "elevated electronic signature"
of change order B and other approvals can use it later.

`MPP_MES_DATA_MODEL.md` gains these tables and loses the claim that
`Quality.NonConformance` exists; extended properties are regenerated with
`node sql/scripts/gen_extended_properties.js`.

## 5. Behaviour

### 5.1 Results — `Quality.ControlledRunResult_Record`

`@ControlledRunId, @ResultsJson, @AppUserId, @TerminalLocationId` with
`[{memberId, dispositionCode, quantity, defectCodeId?, remarks?}, ...]`. One call may
carry many members; the screen sends one member's entries, and "mark the rest as all
accepted" sends many.

Refused before the transaction (whole call, with the member named): super-lot not open;
a member that is not a current member of it; unknown disposition; quantity not above
zero; Scrap without an active defect code; Scrap on a LOT member whose status is `Closed`,
`Scrap` or `Open`; Scrap totalling more than the LOT has.

Inside one transaction:

- **Scrap on a LOT member is real.** One `Workorder.RejectEvent` per entry, the LOT
  decremented, closed at zero if it was `Good`, with the same audit rows as
  `Workorder.RejectEvent_Record`. The block is an **inlined, commented mirror** of that
  proc (the precedent is `RejectEvent_RecordByPartFifo`); the proc itself is not touched.
  No operation type is passed, so the scrap is subtractive (*verified*: additive applies
  only to die-cast). A LOT on a real hold is scrapped in place, as `@AllowHeldLot = 1`
  does. `ChargeToArea` is NULL.
- **Scrap on a container member is recorded only** (`RejectEventId` NULL). Which tray the
  part came out of, and taking it out, is piece 4. The screen says "not yet applied".
- Accepted, Rework, Return and Use-As-Is are counts only.
- One `ControlledRunResultRecorded` audit row for the call.

Returns `Status, Message, NewId` (NewId = the first result row).

**"Left over"** for a member is `PieceCount + AppliedScrap - SUM(live Quantity)`. Applied
scrap has already come out of `PieceCount`, so adding it back gives the pieces the member
started with; live quantities (applied scrap included) are what has been accounted for.
It is information, never a wall (D3).

### 5.2 Void — `Quality.ControlledRunResult_Void`

`@ResultId, @Remarks (required), @AppUserId, @TerminalLocationId`. Refused when: already
voided; the super-lot is not open; the member has left the super-lot; **the entry
produced a `RejectEvent`** ("these pieces were already taken off the LOT; correct the LOT's
piece count instead"). Stamps the three void columns; one `ControlledRunResultVoided` audit
row.

### 5.3 Deviation — `Quality.ControlledRunDeviation_Raise`

`@ControlledRunId, @Description, @Justification, @DefectCodeId?, @AffectedQuantity?,
@ExternalReference?, @AppUserId (the signer), @TerminalLocationId`. Refused when the
super-lot is not open, either text is blank, or the seam (5.5) says the user may not sign.
Mints the `DV` number (inlined mirror of `Lots.IdentifierSequence_Next`, as
`ControlledRun_Open` does), writes the signature (meaning `DeviationApproval`) and the
deviation, one `ControlledRunDeviationRaised` audit row. Returns `Status, Message, NewId`.

A deviation belongs to the super-lot, not to a member. **A member with a live Use-As-Is
result cannot be released until the super-lot has at least one deviation.**

### 5.4 Signed release — `Quality.ControlledRun_Release`

`@Id, @MemberIdsJson ([n, ...]), @InspectionConfirmed, @Remarks?, @AppUserId (the signer),
@TerminalLocationId`.

Refused before the transaction: super-lot not open; the seam refuses the signer;
`@InspectionConfirmed` is not 1 ("Confirm the inspection was completed"); no members; a
member that is not a current member of this super-lot; a member with no live result; a
member with Use-As-Is and no deviation on the super-lot. Refusals name the member.

Inside one transaction, all or nothing:

1. Clear `CrtActive` on every tagged LOT of the ticked members (a container's tray LOTs
   included, Closed or not) with **one `CrtCleared` audit row per LOT**, in the shape
   `Lots.Lot_ClearCrt` writes, description suffixed `(super-lot CRnnnnnn release)`.
2. One `Quality.Signature` (meaning `ControlledRunRelease`), one
   `Quality.ControlledRunRelease`.
3. End the memberships: `EndedAt`, reason `Released`, `ControlledRunReleaseId`. If the
   number of rows ended differs from the number ticked, raise `SUPERLOT_RACE` and let
   the CATCH map it to "Something changed while you were releasing. Reload and try
   again." (piece 1's pattern).
4. One `ControlledRunReleased` audit row naming the members.

A member already untagged (cleared per unit, D5) is released the same way; it simply
produces no `CrtCleared` row. Returns `Status, Message, NewId` (the release).

Closing stays its own action (`ControlledRun_Close`): "everything is released" and "the
case is finished" remain separate statements. With every member released the close
guard sees nothing outstanding (*verified* against `ControlledRun_Close`).

### 5.5 The seam — `Quality.ufn_SignatureAllowed(@AppUserId, @MeaningCode)`

Returns 1 when the user is active and has an AD account. That is all it can check today.
When AD roles exist, this function is the only place that changes. The Sign-off tab
carries a standing notice: *"Any network account registered in the MES can sign today.
Signing will be limited to Quality once plant AD roles exist."*

### 5.6 Reads and changes to piece 1 objects

| Object | Change |
|---|---|
| `Quality.ufn_ControlledRunMemberResults(@ControlledRunId)` (new, inline) | Per member: quantity per disposition, applied scrap, total, left over, `HasResult`, `ReleaseBlockReason` (NULL = ready; otherwise "No results yet" / "Use as is needs a deviation"). One definition for the screen and for the release proc |
| `Quality.ControlledRun_ListMembers` | + the columns above, `WasCompleteAtJoin`, `ControlledRunReleaseId` |
| `Quality.ControlledRunResult_ListByRun(@Id, @IncludeVoided)` (new) | Entries newest first, Eastern, with `IsApplied` and `CanVoid` |
| `Quality.ControlledRun_ListSignatures(@Id)` (new) | Releases and deviations on this super-lot: when, who, meaning, statement, a one-line summary |
| `Quality.ControlledRunDeviation_ListByRun(@Id)` (new) | Deviations |
| `Quality.SignatureMeaning_Get(@Code)` (new) | The statement shown before signing - the same text the proc stores |
| `Quality.ControlledRun_Get` / `_List` | Totals also count members ended as `Released`; a released member counts as cleared |
| `Quality.ControlledRun_Cancel` | Refused once a release exists |
| `Quality.ControlledRun_SyncInternal` | Skips units that were released, as it skips removed ones |
| `Quality.ControlledRun_RemoveMember` | Message fix (piece 2) |
| `Location.SessionPolicy_Get` / `_Update` | Carry the two Quality values. `_Update` takes them as optional parameters that mean "leave as it is" when omitted, so the Configuration Tool's existing panel keeps saving |

No rule lives in Python or in a view expression: readiness, left over and what may be
voided are all columns SQL returns.

## 6. Quality sign-in window

*Verified:* the timeout is the single global row `Location.SessionPolicy`
(`ElevationTimeoutSeconds` 300, rolling on activity; `ElevationMaxSeconds` 1800, absolute).
`Common.Session.beginElevatedWindow` makes the signed-in person the session user;
`touchElevation` (app-header idle poll) extends the window on activity up to the ceiling.
The super-lot page uses none of that today: every action takes a network password.

Change:

- `session.custom.elevationProfile` (declared in session props, default `""`).
  `_elevationSeconds`, `_elevationMaxSeconds` and `activeTimeoutSeconds` read the Quality
  values when it is `"Quality"`.
- The super-lot page asks for a **Quality sign-in** (the existing elevation modal through
  `Common.Session.requireElevation`) before the first action that changes anything, and
  stamps the profile. Leaving the page clears the profile and pulls the rolling deadline
  back to the standard timeout, so the long window never follows the person to a line
  screen.
- Inside the window: add, remove, end/resume window, close, cancel, results and void use
  the session user and do not ask again. `ControlledRunConfirm` hides its account and
  password fields while a window is open.
- **Signing is outside the window.** Release and deviation always take account and
  password in their own popup, validated by `AppUser.elevate(...)` in its stateless form,
  and the signer's id goes straight to the proc.

Consequence to know: while the window is open, the signed-in person is the terminal's
user, so anything done on that terminal is credited to them. That is the existing
elevation behaviour, now lasting up to 30 idle minutes on this page.

## 7. The view

`/shop-floor/controlled-runs`. The left-hand list is unchanged apart from "released"
replacing "cleared" in the progress text.

- **Tabs become live.** `view.custom.activeTab` (`members` | `results` | `signoff`); History
  stays a placeholder. The member table shows on Members; two new embedded views show on
  the others. The middle KPI reads "Released".
- **Results** (`Components/PlantFloor/ControlledRunResults`): a fixed column header, then
  an `ia.display.accordion`, one item per current member.
  - Header view `ControlledRunResultHeader`: member, part, pieces, the five quantities,
    left over. Same row look as the Members tab.
  - Body view `ControlledRunResultEntry`: (1) outcome tiles - Accepted, Rework, Return to
    vendor, Use as is, and "Accept the rest"; (2) scrap reason tiles, tap to add 1, "More
    reasons" for the full list; (3) one Entered list holding outcomes and scrap reasons
    alike, with - / + and tap-the-quantity for the number pad; Remark; Save. It reuses
    `Scrap/ScrapCodeTile`, `Scrap/ScrapLineRow` and `PlantFloor/Numpad`.
  - Reason tiles are ranked with `Quality.DefectCode_ListRankedForLocation` for the
    super-lot's "made at" location (the member's current location when the super-lot has
    none), no operation filter. With no scrap history there the order falls back to the
    proc's tie-break, which is acceptable (*verified* in the proc header).
  - `props.items` is written by a `reload()` method, not bound: it reads each current
    item's `expanded`, rebuilds the list from SQL rows, and carries the flags over by
    member id (D10). To be checked on the gateway: whether collapsed bodies are built up
    front and what that costs on a long list.
  - Above the list: "Mark the rest as all accepted (n)". Below it: the entry log with
    Void where SQL says an entry can be voided.
- **Sign-off** (`Components/PlantFloor/ControlledRunSignOff`): left, the release list
  with a tick per ready member (`ReleaseBlockReason` shown otherwise), "Tick all ready",
  "Release ticked (n)"; right, deviations with "Raise deviation", the signature history,
  and the seam notice.
- **Popups:** `ControlledRunRelease` (statement, required confirmation checkbox,
  remarks, account, password) and `ControlledRunDeviation` (the two texts, defect,
  quantity, MPP reference, statement, account, password).

New views are written as files. The existing page and `ControlledRunConfirm` are changed
by a script that edits the parsed JSON (D11). Jacques must not have either open with
unsaved changes in Designer when it is scanned.

## 8. Constraints that will bite

- A status-row proc may not `EXEC` another status-row proc or `ROLLBACK` inside
  `INSERT ... EXEC`: inline with a mirror comment, or use a silent helper. Rejecting
  validations run before `BEGIN TRANSACTION`.
- Piece 1's mutation procs are the committed `.sql`; edit them and keep their shape.
- `Run-Tests.ps1` DROPS its target: use a private database name.
- The trigger on `Quality.Signature` must `THROW`, never `ROLLBACK`, because it can fire
  inside a caller's `INSERT ... EXEC`.
- ASCII-only seed text, including the two signature statements.

## 9. Tests (`sql/tests/0109_ControlledRun/`, 171 assertions at hand-off)

- **Results:** entries append; each refusal in 5.1; Scrap on a WIP LOT writes a
  `RejectEvent`, decrements the LOT and closes it at zero; Scrap on a held LOT works;
  Scrap on a container records intent only; left over is right before and after scrap.
- **Void:** stamps once; refuses a second void, an applied scrap, a member that has left.
- **Deviation:** number `DV000001`; signature row with the stored statement; blank texts
  refused.
- **Release:** every ticked member cleared with one `CrtCleared` per LOT; one signature,
  one release row; unticked members untouched; confirmation required; no-result and
  Use-As-Is-without-deviation refused; all-or-nothing; a released LOT can move again and
  a released container can ship; a member cleared per unit beforehand still releases.
- **Signature:** UPDATE and DELETE are refused by the trigger.
- **Piece 1 reads:** totals with released members; close after full release; cancel
  refused after a release; sync does not bring a released unit back.
- **Session policy:** the two Quality values round-trip; omitted on update = unchanged.
- The existing CRT suites still reproduce their 178-assertion baseline.

Gateway walkthrough: the embedded test browser cannot type into Perspective inputs, so
anything needing typed text or a credential (sign-in, release, deviation) needs a person.
Tile taps and the accordion can be walked.

## 10. Build order

1. Migration `0110`. 2. Piece 2's helper change and its tests. 3. Results, void and their
reads. 4. Deviation, signature, seam, trigger. 5. Release, and the piece 1 read/guard
changes. 6. Session policy values. 7. Named queries and `BlueRidge.Quality.ControlledRun`.
8. `Common.Session` profile. 9. New views and popups. 10. The scripted edit to the page.
11. Data model doc, extended properties, `PROJECT_STATUS.md`.

## 11. Known limitations to state, not hide

- Anyone with an AD-mapped account can sign until roles exist (D1).
- A container that fails inspection still has no path until piece 4: its scrap is a
  recorded intention and its parts stay counted.
- Rework and Return to Vendor are counts with no material effect until piece 5.
- Line scrap by part (`RejectEvent_RecordByPartFifo`) still spreads across CRT-tagged and
  clean LOTs alike. Whether it should skip tagged LOTs is a question for Jacques, outside
  this piece.
- A per-unit clear (D5) bypasses the signature for that unit. The super-lot shows it
  untagged; the only record of who cleared it is the LOT's own `CrtCleared` row.
- Does MPP need a deviation number in its own format? Built with ours plus a reference
  field; worth asking MPP.

## 12. Build notes (2026-10-13)

**Differs from the sections above:**

- **5.6:** `Quality.ControlledRun_ListMembers` was NOT extended. The result columns, `WasCompleteAtJoin` and the release-block reason come from a new proc, `Quality.ControlledRun_ListMemberResults`, because `_ListMembers` is captured by column list in several piece 1 tests and feeds only the Members tab. The Members tab therefore does not show "pulled back from finished stock" yet.
- **6:** the New super-lot wizard still asks for a network password on its last step; it was not moved inside the Quality sign-in window. A press of Save / Add / Remove with no window open asks for the sign-in and the person then repeats the press.
- **7:** the middle KPI still reads "Cleared" (it counts members that are released OR untagged, which is what the number is). The "Released" wording in the mockup was not applied.
- **7:** the Results tab scrolls as a whole; the accordion takes its natural height. The arrow is on the right.
- **Observed on the gateway:** the accordion builds every member's body view up front, collapsed ones included. Fine for tens of members; a list of hundreds would need bodies loaded only for open items, which means taking over the expand flag (the thing D10 chose not to do). Revisit only if it is slow in practice.

**Verified:** `sql/tests/0109_ControlledRun/` 304 assertions, 0 failed; full suite on a clean private database 4,730 assertions, 0 failed. Gateway walkthrough up to every point that needs a typed credential (see `PROJECT_STATUS.md`, 2026-10-13 entry).

**Not verified:** anything after a sign-in or a signature on the gateway; layout at 1920 x 1080; that the body views keep an unsaved draft when another member is saved (the item list is rewritten on every refresh).

**From the end review, left as they are:** the scrap status guard in `ControlledRunResult_Record` names the statuses (`Scrap`, `Closed`, `Open`) where `RejectEvent_Record` tests `BlocksProduction`; they agree today and a new blocking status would need adding here. A result voided in the instant between a release's check and its write is not re-checked inside the transaction.

## Revision History

| Date | Change |
|---|---|
| 2026-10-12 | Initial draft, written as a handoff for another agent. Not approved. |
| 2026-10-13 | Completed with Jacques: all seven open decisions answered, the "verify" items checked against code, results-entry layout settled as an accordion with the Record Scrap tile pattern, Quality 30-minute sign-in window added, data model and procs made concrete. |
| 2026-10-13 | Built. Section 12 added: differences from the spec, what was verified and what was not. |
