# Super-lot piece 5 — Rework at trim and Return to vendor

> **Status: DESIGN 2026-10-19, awaiting Jacques's approval. NOT BUILT.**
> Fifth of six pieces. Branch `jacques/controlled-run-super-lot`. Nothing deploys until
> all six pieces are in.

**Read first:** `notes/2026-10-12_crt-super-lot-and-nonconformance-overview.md`,
`notes/2026-10-13_super-lot-piece-5-handoff.md`, the piece 3 spec
(`2026-10-12-controlled-run-results-and-signoff-design.md`) and the piece 4 spec
(`2026-10-12-controlled-run-container-repack-design.md`), `CLAUDE.md`.

---

## 1. Why

Change order B lists the standard dispositions: Pending, Use-As-Is, Rework, Scrap, Return
to Vendor. After pieces 3 and 4, Scrap moves material, Use-As-Is is a signed deviation and
a finished-good container can be repacked. **Rework and Return to vendor are still only
numbers on a results row.** The pieces they describe are still counted in their LOT as
good stock. This piece gives both outcomes a real effect on inventory, and keeps that
effect as close as possible to what the plant already does.

## 2. What MPP do (Jacques, 2026-10-19)

| Area | "Rework" means | What MES needs |
|---|---|---|
| Die cast | Sorting out bad parts | Scrap results only. Nothing new. |
| Trim | Check the LOT back in, run it through the machine again (likely with a part adjustment), check it out | **Built here** (section 4) |
| Machining, assembly | Manual rework | Nothing, unless it consumes extra BOM components. That is **BOM-component partial fill**, which stays a **separate follow-on** (piece 4 spec, section 9). Not built here. |
| Finished-good container | Open, scrap / top up, re-complete | Already built: piece 4 container repack. Nothing new. |

Further answers:

- A LOT stays together as a unit; reworked parts go back into the same basket / container.
  **Rework is always whole-LOT.**
- There is no rework area and no return-staging area. Material sits wherever there is room
  (at the line, in a warehouse). **No new location definitions.**
- Return to vendor applies to anything **purchased or pass-through**: not cast at MPP, not
  a finished good or sub-assembly MPP made.
- **MPP do not handle shipping.** A return is *marked* in MES; a supervisor later
  *confirms* the parts physically went back, from a tile on the Supervisor Dashboard.

## 3. Goals, non-goals, anti-goals

**Goals**
- Every supervisor-approved move back into trim is recorded as a rework, and the LOT
  shows up on the Trim screen again so it can be run and checked out.
- A super-lot cannot be released while one of its LOTs is out at trim rework.
- Material marked for return to vendor stops being available stock the moment it is
  marked, and the open returns are visible to supervisors until confirmed.

**Non-goals**
- BOM-component partial fill (separate follow-on).
- A route-based rework operation, rework location definitions, rework routes.
- A vendor table, RMA numbers, return paperwork, an outbound shipment, or charging the
  vendor through the charge-to-party machinery (migration `0067`).
- Rework of a part of a LOT (a split). Rework is whole-LOT.

**Anti-goals** (would be a failure even if it technically worked)
- An operator or supervisor needing a new step, button or screen to do a trim rework. The
  existing Trim IN override **is** the rework; nothing is added to that interaction.
- A return to vendor appearing in scrap / reject reports as MPP scrap.
- `PieceCount` and `InventoryAvailable` drifting apart (there is no audited repair path).

## 4. Rework at trim

### 4.1 What already happens (verified by reading, 2026-10-19)

At Trim IN the Movement Scan calls `Lots.Lot_MoveToValidated(@OperationTypeCode='TrimIn')`.
For a LOT whose route is already past trim, rule 4b refuses ("Backward move blocked"); the
view opens `Popups/MoveOverride` (supervisor AD account + password via
`BlueRidge.Location.AppUser.elevate`), then retries with `@OverrideAppUserId`. The only
trace today is the audit text "(backward-move supervisor override)".

Two gaps, both found by reading and **not yet reproduced on a database** (the build's
first test must reproduce them before changing anything):

1. **The LOT does not appear on the Trim screen after it is moved back.** The Trim
   screen's lists come from `Lots.Lot_GetWipQueueByLocation`, which is route-driven
   through `Lots.ufn_NextPendingRouteStep`. An `Advance` step is pending only while the
   LOT has **no** `ProductionEvent` for it, ever. A re-entered LOT already has TrimIn and
   TrimOut checkpoints, so its next pending step stays MachiningIn.
2. **A CRT LOT cannot be moved into trim at all.** Rule 6 of `Lot_MoveToValidated`
   (`Lots.ufn_CrtBlocksMoveTo`) refuses a production destination for a CRT LOT and runs
   even when a supervisor override is supplied.

### 4.2 The rule

**A supervisor-approved backward move whose operation is `TrimIn` is a rework.** Every
one, super-lot or not (Jacques). Other backward overrides (any other operation) are
unchanged and are not reworks.

### 4.3 Data — `Lots.LotRework` (new)

One row per trim rework. Append-only apart from the completion stamp.

| Column | Type | Notes |
|---|---|---|
| Id | BIGINT IDENTITY PK | |
| LotId | BIGINT FK → Lots.Lot NOT NULL | |
| ReEntrySequenceNumber | INT NOT NULL | The route `SequenceNumber` of the step moved back to (the LOT's TrimIn step). Steps at or after it become pending again. |
| LotMovementId | BIGINT NOT NULL | The `Lots.LotMovement` row the override move wrote. Pointer, no FK (high-volume table; same precedent as `ControlledRunResult.RejectEventId`). |
| StartedAt | DATETIME2(3) NOT NULL | UTC, = the movement time |
| MovedByUserId | BIGINT FK → AppUser NOT NULL | The `@AppUserId` of the move (the operator) |
| ApprovedByUserId | BIGINT FK → AppUser NOT NULL | The `@OverrideAppUserId` (the supervisor) |
| TerminalLocationId | BIGINT FK → Location NULL | |
| CompletedAt | DATETIME2(3) NULL | Set by the Trim OUT that closes it |
| CompletedProductionEventId | BIGINT NULL | That Trim OUT's checkpoint. Pointer, no FK. |

Filtered unique index: at most one open rework per LOT (`WHERE CompletedAt IS NULL`).

### 4.4 Behaviour

- **`Lots.Lot_MoveToValidated` v1.2.** When `@OverrideAppUserId` is supplied and
  `@OperationTypeCode = 'TrimIn'` and the move *is* backward (attempted sequence below the
  next pending sequence — the same test rule 4b uses), the move also inserts the
  `LotRework` row inside its existing transaction, and the audit Description reads as a
  rework (e.g. `<LOT> · Movement · <from>→<to> (trim rework, approved by <initials>)`).
  A LOT with an open rework that is moved back into trim again does **not** get a second
  row (the filtered unique index would refuse it); the move just happens.
  - **CRT exception:** rule 6 does not refuse this move. A rework move into trim is
    allowed for a CRT LOT. Hold, Scrap and Closed still refuse (rules before 4b are
    untouched). The CRT tag stays on the LOT; after Trim OUT the LOT is still refused a
    production destination until Quality releases it, as today.
  - No change to the view or the `MoveOverride` popup. No reason field is added (my call:
    Jacques asked to use the interaction as it is).
- **`Lots.ufn_NextPendingRouteStep` v1.2** (the one shared definition — Trim queue, Trim
  OUT pick list, Machining queues, `Lot_MoveToValidated` and `MachiningOut_Mint` all read
  it). For a LOT with a `LotRework` row, an `Advance` step whose `SequenceNumber` is
  `>= ReEntrySequenceNumber` of the **latest** rework counts as done only if it has a
  `ProductionEvent` recorded **after that rework's `StartedAt`**. Steps below the re-entry
  point keep today's rule. LOTs with no rework rows are unchanged. Must stay an inline TVF.
- **`Workorder.TrimOut_Record` v-next.** On success, if the LOT has an open `LotRework`,
  stamp `CompletedAt` + `CompletedProductionEventId` with the checkpoint it just wrote, in
  the same transaction, and write a `LotReworkCompleted` audit row.
  - Its guard 5 ("already in Trim Storage, must be checked in again") is unaffected: the
    rework move takes the LOT out of Trim Storage into the trim area.
- **Trim IN checkpoint.** Whatever records the TrimIn checkpoint today
  (`ProductionEvent.recordTrimInCheckpoint`) is unchanged; with the new pending rule the
  re-entered LOT is pending at TrimIn and then at TrimOut exactly like a first pass.
- Scrap at the re-run Trim OUT is ordinary subtractive trim scrap.

### 4.5 Super-lot effect

- **`Quality.ufn_ControlledRunMemberResults` v1.2:** `ReleaseBlockReason` gains
  **"At trim rework"** for a LOT member with an open `LotRework`. Placed after
  "No longer in the super-lot" and alongside piece 4's "Being reworked" (containers). The
  Sign-off tab and `ControlledRun_Release` pick it up for free.
- **Rework as a result entry (my call — please check).** Jacques agreed rework is two
  steps, sent and back. With rework now always whole-LOT at trim, the two steps are the
  **move into trim** (sent) and the **Trim OUT** (back); after it, Quality records
  Accepted / Scrap for the LOT's pieces as for any member. So the manual **Rework tile is
  removed** from results entry and `Quality.ControlledRunResult_Record` refuses the
  `Rework` disposition. Otherwise a LOT counted "Rework 100" and then "Accepted 95 /
  Scrap 5" would count its pieces twice and show a negative left-over. Pieces 3 to 5
  have never deployed, so no live rows are affected. The `Rework` code row stays (piece 3
  test pins it). `ReworkQty` stays in the function's result shape (to avoid breaking
  capture tables) and simply reads 0.
- The Results / Members tabs show a member's open trim rework as a status ("At trim
  rework since <ET time>"), read from `LotRework`. Through a **new** read proc or a new
  column on `Quality.ControlledRun_ListMemberResults`; see handoff "tests that capture
  result sets by column list" — the builder chooses and updates every capture table if
  a column is added.

## 5. Return to vendor

### 5.1 Who can be returned

Only a LOT whose `LotOriginTypeId` is `Received` or `ReceivedOffsite`. Refused in SQL for
`Manufactured`. Following the LOT's origin, not the part type, is what makes pass-through
work: a pass-through part is a finished good by part number, but the LOT received at the
dock is `Received` (returnable), while the tray LOT MPP repack it into is `Manufactured`
(not returnable). A container member of a super-lot is never returnable (its tray LOTs are
`Manufactured`).

LOT status: `Good` or `Hold` may be marked (a held received LOT is exactly the one likely
to go back). `Closed`, `Scrap`, `Open` are refused. A CRT LOT may be marked.

### 5.2 Data — `Lots.VendorReturn` (new)

| Column | Type | Notes |
|---|---|---|
| Id | BIGINT IDENTITY PK | |
| LotId | BIGINT FK → Lots.Lot NOT NULL | |
| Quantity | INT NOT NULL, CHECK > 0 | |
| Remarks | NVARCHAR(500) NULL | Free text; no RMA / vendor fields (Jacques: "just mark it") |
| ControlledRunResultId | BIGINT FK → Quality.ControlledRunResult NULL | Set when the mark applies a super-lot Return result |
| MarkedByUserId | BIGINT FK → AppUser NOT NULL | |
| MarkedAt | DATETIME2(3) NOT NULL | UTC |
| TerminalLocationId | BIGINT FK → Location NULL | |
| ConfirmedAt / ConfirmedByUserId | NULL | Parts physically went back |
| CancelledAt / CancelledByUserId / CancelRemarks | NULL | Marked by mistake |

CHECK: not both confirmed and cancelled. Filtered index on open rows
(`ConfirmedAt IS NULL AND CancelledAt IS NULL`) for the dashboard tile.

### 5.3 Behaviour

- **`Lots.VendorReturn_Mark(@LotId, @Quantity, @Remarks, @ControlledRunResultId, @AppUserId, @TerminalLocationId)`**
  - Quantity must not exceed `PieceCount`. Decrements `PieceCount` and
    `InventoryAvailable` together (floored at zero, mirroring
    `Workorder.RejectEvent_Record`'s subtractive path) and, at zero, closes the LOT with a
    `LotStatusHistory` row the same way that proc does (inline mirror; cite it).
  - **Not a `RejectEvent`.** Nothing in reject / scrap reporting sees it.
  - With `@ControlledRunResultId`: that result must be a live, unapplied `ReturnToSupplier`
    entry for a member whose LOT is `@LotId`, and `@Quantity` must equal its quantity
    (same rule `ContainerRework_Scrap` uses for an applied scrap).
  - Audit `VendorReturnMarked` (Lot entity → `LotEventLog`).
- **`Lots.VendorReturn_Confirm(@VendorReturnId, @AppUserId)`** — stamps the confirmation.
  No quantity change. Refused if already confirmed or cancelled. Audit
  `VendorReturnConfirmed`.
- **`Lots.VendorReturn_Cancel(@VendorReturnId, @CancelRemarks, @AppUserId)`** — before
  confirmation only. Restores `PieceCount` and `InventoryAvailable`. **Refused if the
  mark closed the LOT** (re-opening a closed LOT has no proc and is not built here; the
  limitation is stated in section 8). Audit `VendorReturnCancelled`.
- **Reads:** `Lots.VendorReturn_ListOpen` (dashboard tile + popup: LOT, part, vendor lot
  number, quantity, marked by / at in ET, location), `Lots.VendorReturn_ListByLot`
  (LOT Detail history).

### 5.4 Super-lot effect

- A live `ReturnToSupplier` result is *recorded* (count) as today; it is *applied* when a
  `VendorReturn` row points at it — the same recorded/applied idea as scrap.
  `IsApplied` / `CanVoid` in `Quality.ControlledRunResult_ListByRun` learn it; an applied
  return result cannot be voided (cancel the return instead, which un-applies it).
- **Left-over math:** `Quality.ufn_ControlledRunMemberResults` adds `AppliedReturnQty`
  back exactly as it adds `AppliedScrapQty`, because an applied return has already come
  off `PieceCount`:
  `LeftOver = PieceCount + AppliedScrapQty + AppliedReturnQty - ResultQty`.
  `AppliedReturnQty` is a new column at the END of the function's result shape; check
  every proc / test that reads the function by column list.
- `ControlledRunResult_Record` refuses a `ReturnToSupplier` entry for a member whose LOT
  is not `Received` / `ReceivedOffsite`, and for a container member.
- Release does **not** wait for the return to be confirmed: the pieces are off the LOT
  once marked, which is all the release needs (my call).

### 5.5 Screens (Jacques wants a mock before any screen is built)

- **Super-lot Results tab:** the existing Return tile records the count as today. A
  recorded return gets an **Apply** action, the same way a recorded scrap is applied, inside
  the Quality sign-in window. Hidden for non-received members.
- **LOT Detail:** a **Return to vendor** action for a received LOT (quantity + remarks),
  behind per-action AD elevation like other protected LOT actions (my call). Lists the
  LOT's returns with Cancel on an open one.
- **Supervisor Dashboard:** a **"Parts to return"** tile showing the count of open returns;
  it opens a popup listing them with **Confirm returned** per row. The signed-in user is
  the confirmer; no elevation (my call — confirming is a record of a physical event, not a
  protected action).
- Mocks for these three come first; the build plan has a mock step before any view work.

## 6. Code-table and audit rows

New `Audit.LogEventType` rows: `LotReworkStarted`, `LotReworkCompleted`,
`VendorReturnMarked`, `VendorReturnConfirmed`, `VendorReturnCancelled`. New
`Audit.LogEntityType` rows only if the existing `Lot` entity does not fit (it should).
Expect count-pin tests to break (handoff: `0004_Lots_codes`, `0005_Quality_codes`, and the
audit code pins); update them.

## 7. Constraints

- FDS-11-011: no OUTPUT params, one result set, all rejections before
  `BEGIN TRANSACTION`, no status-row proc calls another (inline mirrors, commented).
  `Lot_MoveToValidated` and `TrimOut_Record` are captured via INSERT-EXEC by tests.
- Timestamps stored UTC, displayed ET.
- Seed / string literals ASCII-only (the `→` in the existing movement description is
  built with `NCHAR(8594)`; keep doing that).
- New migration `0112_...`; new procs as repeatables. Test teardown order per the handoff
  (new tables hang off `Lots.Lot` and `Quality.ControlledRunResult`; delete them first).
- The FDS is not edited. Update `MPP_MES_DATA_MODEL.md` and `PROJECT_STATUS.md`.
- `ufn_NextPendingRouteStep` is on every terminal refresh: keep it an inline TVF, and
  check the plan of `Lot_GetWipQueueByLocation` does not regress for LOTs without
  reworks.

## 8. Known limitations

- A return that emptied (closed) its LOT cannot be cancelled.
- A rework records who approved and who moved, not what was adjusted (no reason field).
- Rework outside trim has no MES record unless it is scrap or a container repack.
- The vendor is not named on a return beyond the LOT's free-text `VendorLotNumber` and
  the return's remarks.

## 9. Tests the build must add

- Reproduce both gaps in 4.1 first (re-entered LOT absent from the Trim queue; CRT LOT
  refused at Trim IN with override), then make them pass.
- Rework: override move into trim writes one `LotRework`; a non-override or non-TrimIn
  move writes none; a forward TrimIn move with an override supplied writes none; the LOT is
  pending at TrimIn then TrimOut; Trim OUT completes the rework; downstream steps
  (MachiningIn) pending again when the rework came from past them; a LOT without reworks
  is unaffected; CRT LOT allowed into trim by rework but still refused production after;
  super-lot release blocked "At trim rework" until Trim OUT; Rework result entry refused.
- Return: mark on Received / ReceivedOffsite; refused on Manufactured, Closed, Scrap,
  Open, over-quantity; both quantities decrement; close at zero; no `RejectEvent`;
  applying a super-lot result (mismatch refusals); left-over math; confirm; cancel restores
  and un-applies; cancel refused after close and after confirm.

## Revision History

| Date | Change |
|---|---|
| 2026-10-12 | Initial draft: options and questions, written as a handoff. Not approved. |
| 2026-10-19 | Rewritten as a design from Jacques's answers: rework = the supervisor-approved move back into trim (whole LOT, `Lots.LotRework`, route pending rule re-armed after re-entry); Return to vendor = mark (stock off immediately, received-origin LOTs only, `Lots.VendorReturn`) + confirm on the Supervisor Dashboard. Partial fill stays a separate follow-on. |
