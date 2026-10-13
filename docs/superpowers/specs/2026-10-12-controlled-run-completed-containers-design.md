# Super-lot piece 2 — Controlled Run Tag on completed containers

> **Status: COMPLETE 2026-10-13, awaiting Jacques's read. NOT BUILT.** Second of six
> pieces. **Section 10 is the final design** - what is built, in one place. Sections 4,
> 5 and 8 are kept as the record of what was proposed and asked.
>
> **Decisions were answered on 2026-10-12 — read section 8a first; it overrides the
> proposals in sections 4 and 5.** In short: AIM is told nothing when a container is
> tagged; there is no interim Validate button; a tagged container can move anywhere; and
> **this piece is built together with piece 3**, because without piece 3's bulk release a
> tagged warehouse container has no way out. No decisions remain open.

**Read first, in this order:**

1. `notes/2026-10-12_crt-super-lot-and-nonconformance-overview.md` — what the feature is,
   the vocabulary, the six pieces.
2. `docs/superpowers/specs/2026-10-12-controlled-run-super-lot-design.md` — piece 1, built.
3. `PROJECT_STATUS.md`, the 2026-10-12 super-lot entry — what exists and what was not
   verified.
4. `CLAUDE.md` — project rules. The proc rules (FDS-11-011) and "Working Style" bind you.

**Branch:** `jacques/controlled-run-super-lot` (piece 1 is on it; build on top). Nothing
in this feature deploys to production until all six pieces are in.

---

## 1. Problem

Piece 1 lets Quality put a completed container on a super-lot, but it cannot make that
mean anything. A container has no tag of its own: it is "CRT" while any of its tray
LOTs has `Lots.Lot.CrtActive = 1`, and a tray LOT is **Closed** the moment its container
completes. Piece 1's `Quality.ControlledRun_ApplyMembersInternal` deliberately skips
Closed LOTs (it mirrors `Lots.Lot_SetCrt`, which refuses them). So today a completed
container joins a super-lot with `CrtSetByRun = 0`, shows as **Cleared**, and **can still
be loaded at the shipping dock.** Piece 1's own status text says so.

MPP's real case is exactly this one: a customer reports a problem, and everything made
from the suspect LOT up to now goes on CRT — including finished containers already
sitting in the warehouse. Those get pulled and every part is inspected.

This piece makes a completed container's tag real, deals with what Honda's AIM system
already believes about it, and gives Quality a way to release one that is not standing
at an assembly line.

## 2. What already works once the bit is set (verified 2026-10-12)

Every container-level guard already reads the tray LOTs' `CrtActive` and does **not**
care that they are Closed. Nothing here needs rewriting:

| Existing | Behaviour once a completed container's tray LOTs are tagged |
|---|---|
| `Lots.Container_Ship` | Refuses: "Container is pending Controlled Run Tag validation (cannot ship)." |
| `Lots.AimShipperIdPool_ListUnposted` | Excludes the container's serial from the post sweep, the owed backlog screen and the backlog alarm |
| `Lots.Container_ValidateCrt` | Clears every tagged tray LOT of the container, one `CrtCleared` audit row per LOT |
| `Lots.Lot_ClearCrt` | Already allows a Closed LOT |
| `Quality.Crt_GetRequiredInspections` | Excludes Closed LOTs, so no 200%-inspection prompt appears for them (intended — see `2026-08-14-crt-container-validation-design.md`) |
| `Quality.ufn_ControlledRunMemberState` | A container reads as tagged while any tray LOT is; the super-lot's "cleared" count and the close guard become honest with no change |
| `Quality.ufn_ControlledRunResolveMembers` | Already treats a completed, unshipped container as eligible |

So the core of this piece is small: **allow the tag to be set on the Closed tray LOTs of
an unshipped container.** The hard part is everything that follows from having done it.

## 3. Scope

**In:**

- Tagging the Closed tray LOTs of a completed, unshipped container when it joins a
  super-lot.
- The AIM consequence for a container whose shipper serial has **already been posted**.
- Releasing a tagged container from the super-lot view, wherever the container is.
- Making the same thing true for a container that joins by sync (a descendant of a
  member) or by scan.

**Out:**

| Not here | Piece |
|---|---|
| Bulk signed release, the "200% inspection completed" confirmation, per-member results, the deviation record, a Quality-only gate | 3 |
| Scrap out of a Closed tray LOT; opening a container, topping it up, voiding its serial, issuing and posting a new one | 3 / 4 |
| Shipped containers. They stay ineligible. A shipped container is a customer hold (`Quality.Hold_Place` + AIM `PlaceOnHold`), not a super-lot member | — |

## 4. Proposed design

Everything marked **(proposed)** is a recommendation for Jacques, not a decision.

### 4.1 Setting the tag

`Quality.ControlledRun_ApplyMembersInternal` gains one more class of LOT it will tag:
a Closed LOT that is a tray (`Lots.ContainerTray.FinishedGoodLotId`) of a container whose
status is not `Shipped` and not `Void`. A Closed LOT that is not such a tray is still
never tagged.

- Keep the rule in **one** place. The helper is the only writer; `Lots.Lot_SetCrt` keeps
  refusing Closed LOTs, because on LOT Detail "tag a closed LOT" still has no meaning.
- Write the same per-LOT `CrtActivated` audit row the helper already writes.
- `CrtSetByRun` becomes 1 for these members.
- Consider recording, on the member row, that the container was already complete when it
  joined (**(proposed)** a `WasCompleteAtJoin BIT` column, set by the helper). Piece 4's
  repack and any report on "what did we pull back from the warehouse" will want it, and
  it cannot be derived later once the container has been reopened.

### 4.2 AIM — the part that needs a decision

A completed container has claimed a shipper serial, and unless it completed under the
old terminal-switch CRT, that serial **has already been posted to AIM**. Honda's system
believes the container is good. Tagging it afterwards does not un-post anything.

Three states to handle when a container joins a super-lot:

| Serial state | What the existing code does | Gap |
|---|---|---|
| Claimed, not yet posted (post failed or still queued) | `ListUnposted` now excludes it, so the retry sweep stops trying | None — this is the existing terminal-switch behaviour |
| Claimed and posted | Nothing | **AIM still says good.** Decision 8.1 |
| No serial (open container, not complete) | n/a | None |

`BlueRidge.Lots.AimPoolGateway.placeOnHold(aimShipperId)` and `releaseFromHold` exist.
In dev they are simulated (they log to `Audit.InterfaceLog` and return "not
configured"). Their docstring says they are for a **shipped** container. Whether AIM
accepts `PlaceOnHold` for a posted-but-unshipped serial is **not known** — it is a
question for MPP / Honda, not something to infer from the code.

**(proposed)** Record on the member row what was true at join (`AimWasPostedAtJoin BIT`)
so nothing downstream has to guess, and let decision 8.1 choose the action.

**On release** of a container whose serial was posted before it was tagged: the existing
`BlueRidge.Lots.Container.validateCrt` clears the tag and then calls
`AimPost.postOne`. Find out what `postOne` does with a serial that is already posted
before relying on it — read `BlueRidge/Lots/AimPost/code.py` and the
`AimShipperIdPool_MarkPosted` / `_RecordPostResult` procs. It must be a no-op or a clean
"already posted", never a second post.

### 4.3 Releasing a container that is not at a line

Today the only release path for a container is the `CrtValidation` popup on an Assembly
OUT terminal. `Lots.Container_ListPendingValidation(@LocationId)` lists containers whose
**current location** is at or under that terminal's line. A container pulled from the
warehouse is not under any line, so it appears in nobody's list and cannot be released.

**(proposed)** Add a per-container **Validate** action to the member row in the
super-lot view (`Components/PlantFloor/ControlledRunMemberRow`, shown only for a
container member that is still tagged), going through the existing
`ControlledRunConfirm` popup and credential, and calling the existing
`BlueRidge.Lots.Container.validateCrt`. No new release proc. Piece 3 replaces this with
the signed bulk release; this is the minimum that makes piece 2 usable.

Also change the removal message in `Quality.ControlledRun_RemoveMember`: for a container
it currently says "clear it on LOT Detail", which is wrong.

### 4.4 Moving a tagged container

Piece 1's movement block (`Lots.ufn_CrtBlocksMoveTo`) is about LOTs. Check what moves a
**container** between locations (warehouse, shipping dock, sort cage, inspection) and
whether any of those paths should refuse a tagged container or must stay open so it can
be pulled to inspection. Do not assume; find the procs, then ask (8.3).

### 4.5 Consistency checks to make, not assume

- `Lots.Container_ListPendingValidation` — with completed containers now taggable from
  anywhere, does the Assembly OUT button's "pending count" start showing warehouse
  containers that the line cannot act on? Its header discusses status scoping; read it.
- `Quality.Hold_Place` on a container that is also on a super-lot, and the reverse. The
  two are independent today (a hold changes the container's status; CRT does not). Say
  what happens and whether it is acceptable.
- A container with some trays tagged and some not (an open container that joined before
  it completed, then completed). `Container_ValidateCrt` clears all tagged trays; confirm
  the member state reads correctly throughout.
- The piece 1 tests that pin "a completed container is a member but its Closed tray is
  NOT tagged" (`sql/tests/0109_ControlledRun/040_open.sql`, and the "2 cleared" count in
  `050_reads.sql`) will fail by design. Change them deliberately and say so.

## 5. Data model

**(proposed)** Two columns on `Quality.ControlledRunMember`, new versioned migration
(next free number at build time — `0110` as of 2026-10-12; check the directory and
`main`):

```sql
ALTER TABLE Quality.ControlledRunMember ADD
    WasCompleteAtJoin  BIT NOT NULL CONSTRAINT DF_ControlledRunMember_WasCompleteAtJoin  DEFAULT (0),
    AimWasPostedAtJoin BIT NOT NULL CONSTRAINT DF_ControlledRunMember_AimWasPostedAtJoin DEFAULT (0);
```

If decision 8.1 chooses an AIM action, its attempt and outcome are logged through the
existing `Audit.InterfaceLog` path like every other AIM call. No new table.

Update `MPP_MES_DATA_MODEL.md` (the piece 1 tables are in section 5, revision 3.3) and
regenerate extended properties with `node sql/scripts/gen_extended_properties.js`.

## 6. Constraints that will bite

- **A status-row proc may not `EXEC` another status-row proc, and may not `ROLLBACK`
  inside a caller's `INSERT … EXEC`.** Piece 1 solved this with *silent internal helpers*
  (`ControlledRun_ApplyMembersInternal`, `ControlledRun_SyncInternal`): no result set, no
  rollback, called inside the caller's transaction. Follow that pattern; read both files'
  headers before writing SQL.
- **All rejecting validations run before `BEGIN TRANSACTION`**, so there is a
  check-then-write window. Piece 1's `Open` / `AddMembers` close it with a count check
  that raises `SUPERLOT_RACE` and a CATCH that maps it to a plain message. Keep that
  working when you change the helper.
- **Generated procs.** Piece 1's mutation procs were generated from compact specs by a
  scratch script that is not in the repo. The committed `.sql` files are the source of
  truth — edit them directly and keep their shape.
- **No rule in Python or in a view expression.** Whether a container can be tagged or
  released is decided in SQL.
- **AIM calls are async and gateway-side** (FDS-01-014) and are never made inside a
  database transaction.
- **Tests:** `sql/tests/0109_ControlledRun/` (171 assertions). `Run-Tests.ps1` DROPS its
  target database: use a private name, never `MPP_MES_Dev` or `MPP_MES_Test`. Check the
  assertion count, not only failures. The existing CRT suites
  (`0056_CrtValidation`, `0064_Crt_PartScoped`) must still pass — 178 assertions under
  `-Filter "Crt"` as of 2026-10-12.

## 7. Testing this piece must add

- A completed, unshipped container joining a super-lot: every tray LOT tagged, one
  `CrtActivated` row each, `CrtSetByRun = 1`, the member reads as tagged.
- `Lots.Container_Ship` refuses that container, and ships it once validated.
- A Closed LOT that is **not** a tray is still not tagged. A **shipped** container is
  still ineligible.
- The serial of a tagged, not-yet-posted container leaves `ListUnposted` and returns
  when validated.
- The already-posted case, per decision 8.1 — including that release never posts twice.
- The same outcomes when the container joins by scan and by sync (as a descendant).
- The super-lot cannot close while a completed-container member is tagged, and can once
  it is validated.
- Gateway: validate a warehouse container from the super-lot view. The embedded test
  browser cannot type into Perspective inputs; anything needing typed text or a
  credential needs a person.

## 8a. Decisions answered by Jacques, 2026-10-12

These override the "(proposed)" text and the options in section 8 below.

1. **AIM when an already-posted container is tagged: nothing (option a).** The MES
   blocks shipping; AIM is not told. Jacques added: *no AIM action when a container
   joins a super-lot — only on a new finished container completion.* So AIM hears about
   a reworked container when it completes again with its new serial (piece 4), and not
   before. Section 4.2's `PlaceOnHold` / `ReleaseFromHold` idea is **dropped**.
2. **No interim Validate action. Wait for piece 3.** Section 4.3's per-container Validate
   button is **dropped**; a tagged warehouse container is released by piece 3's signed
   bulk release. Consequence: on its own this piece would leave such a container tagged
   with no way out, so **pieces 2 and 3 are built as one unit** (see the note at the top
   of the piece 3 spec). The wrong removal message in 4.3 still needs fixing.
3. **A tagged container may be moved anywhere.** Shipping is the only block. Section 4.4
   reduces to a check that no existing container-move path refuses a tagged container.
4. **`AimWasPostedAtJoin` is dropped** — with no AIM action at join there is nothing for
   it to drive. *(This is my reading of Jacques's answer, which restated the AIM rule
   rather than addressing the columns.)* **`WasCompleteAtJoin` is KEPT** (Jacques,
   2026-10-12): once piece 4 reopens a container nothing else records that it was pulled
   back from finished stock. So section 5's migration adds that ONE column, set by the
   member helper when the container's status is `Complete` at the moment it joins.
5. **A container may be on a real hold and on a super-lot at once.** Neither refuses the
   other. Test that both blocks apply and that releasing one does not release the other.

One thing these answers leave to verify: on release, the existing
`BlueRidge.Lots.Container.validateCrt` calls `AimPost.postOne`. For a container whose
serial was posted before it was tagged, that must be a no-op, never a second post. Piece
3's bulk release inherits this — check it there.

## 8. Decisions for Jacques (as originally asked — see 8a for the answers)

Ask these in plain language before planning. Each has a recommendation.

1. **A container whose serial is already posted to AIM goes on CRT. What should AIM be
   told?**
   - **(a)** Nothing. The MES blocks shipping; AIM is unaware until piece 4 voids the
     serial for a container that is actually reworked.
   - **(b)** Send `PlaceOnHold` when it is tagged and `ReleaseFromHold` when it is
     validated.
   - **(c)** Something else Honda requires.
   I recommend finding out from MPP whether AIM accepts a hold on an unshipped serial
   before choosing. If the answer is not available, (a) is the smallest safe step,
   because the dock block is what actually stops the container leaving.
2. **The Validate action on the member row (4.3)** as the interim release path, or wait
   for piece 3's bulk release and build pieces 2 and 3 together?
3. **Moving a tagged container (4.4).** Should a tagged container be free to move
   anywhere inside the plant (so it can be pulled to inspection), with shipping the only
   block? I believe yes.
4. **`WasCompleteAtJoin` / `AimWasPostedAtJoin` (section 5).** Worth two columns now, or
   leave it to be reconstructed from audit rows later?
5. **A container on a real hold and on a super-lot at once** — allowed, or should one
   refuse the other?

## 9. Known limitations to state, not hide

- Tagging a container says nothing to anyone holding its paper shipping label. The
  label on the container still looks shippable; the super-lot label (piece 1, four per
  print) is the visible flag.
- A container that ships between the preview and the open is caught by eligibility
  ("Already shipped") and refuses the whole open. That is piece 1 behaviour and stays.
- Until piece 4, a container that fails inspection has no path: its parts cannot be
  scrapped (Closed LOT) and it cannot be reopened. It stays tagged and blocked.

## 10. Final design (2026-10-13)

Built with piece 3 as one plan and one migration
(`0110_controlled_run_results_signoff`; see the piece 3 spec, section 4).

1. **`Quality.ControlledRun_ApplyMembersInternal` v1.1.** The tag is also set on a
   **Closed** LOT when it is a tray (`Lots.ContainerTray.FinishedGoodLotId`) of a
   container that is joining. Eligibility already keeps `Shipped` and `Void` containers
   out, so no second status test is needed. A Closed LOT that is not such a tray is still
   never tagged, and `Lots.Lot_SetCrt` keeps refusing Closed LOTs. Same `CrtActivated`
   audit row per LOT; `CrtSetByRun = 1`.
2. **`ControlledRunMember.WasCompleteAtJoin`**, set by the helper when the container's
   status is `Complete` at the moment it joins. `AimWasPostedAtJoin` is not built.
3. **Nothing is sent to AIM** when a container is tagged. *Verified:* a claimed,
   not-yet-posted serial drops out of `Lots.AimShipperIdPool_ListUnposted` while any tray
   is tagged and returns when the tags clear; a posted serial is untouched, and
   `AimPost.postOne` returns `already_posted` without calling AIM.
4. **No Validate button here.** A tagged container is released by piece 3's signed
   release, wherever it is. The existing Assembly OUT popup still lists and can validate
   a tagged container that is standing at that line (piece 3, D5).
5. **Join by scan and by sync** go through the same helper, so they behave the same.
   The sync's descendant arm only looks at CRT-active descendants; a Closed tray of a
   completed container is not CRT-active until it joins, so a completed container is
   reached by sync only when its tray was already tagged. Selecting by genealogy in the
   wizard is what finds warehouse containers - that is piece 1's preview, unchanged.
6. **`Quality.ControlledRun_RemoveMember`** message: for a container it now says the
   container is still tagged and is released from the Sign-off tab, not "on LOT Detail".
7. **Hold and super-lot together** are allowed; neither refuses the other. Tested: both
   blocks apply, and releasing one leaves the other.
8. **Moving a tagged container** is not blocked by anything; shipping is the only block.
   To confirm in the build: no container-move proc reads the tray LOTs' `CrtActive`.
9. **Tests changed on purpose:** `040_open.sql` ("a completed container ... its Closed
   tray is NOT tagged", now tagged with `CrtSetByRun = 1`) and `050_reads.sql` (the
   "2 cleared" count). New file for the cases in section 7.

## Revision History

| Date | Change |
|---|---|
| 2026-10-12 | Initial draft, written as a handoff for another agent. Not approved. |
| 2026-10-13 | Section 10 added: the final design after Jacques's answers and code verification; built with piece 3. |
