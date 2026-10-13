# Super-lot piece 5 handoff (rework / return to vendor)

**Date:** 2026-10-13
**From:** the session that built pieces 2, 3 and 4
**Branch:** `jacques/controlled-run-super-lot` (latest `135da447`). Nothing deploys until all six pieces are in.
**Read first:** `PROJECT_STATUS.md` (the three 2026-10-13 super-lot entries), then the piece 5 draft
`docs/superpowers/specs/2026-10-12-controlled-run-rework-and-return-design.md`. Each built spec ends
with a "Build notes" section that says where the build differs from the spec.

## What piece 5 inherits

- **Rework and Return are counts today, nothing more.** `Quality.ControlledRunResult` rows with
  disposition `Rework` or `ReturnToSupplier` have no material effect (piece 3). Piece 5 gives them one.
  Display label is "Return to vendor"; the code stays `ReturnToSupplier` (Jacques, 2026-10-12).
- **The pattern for "a recorded result becomes real"** already exists for scrap:
  `ControlledRunResult.RejectEventId` is NULL while a scrap is only recorded and set when it is applied
  (`Lots.ContainerRework_Scrap @ControlledRunResultId`). `IsApplied` / `CanVoid` in
  `Quality.ControlledRunResult_ListByRun` key off it. Rework / Return will want the same idea; decide
  whether to add a pointer column per outcome or one generic "applied" marker.
- **"Left over" math** lives in ONE place, `Quality.ufn_ControlledRunMemberResults`
  (`PieceCount + AppliedScrapQty - ResultQty`). If rework or return takes pieces OFF a LOT, that
  function must learn about it or the Results tab will show a wrong left-over.
- **Release readiness** is the same function's `ReleaseBlockReason`. A new block (e.g. "rework not
  finished") goes there, and the Sign-off tab and `Quality.ControlledRun_Release` pick it up for free.

## Decisions Jacques has already made that bind piece 5

- The FDS is NOT edited to match the build ("a record of what was planned"). Update
  `MPP_MES_DATA_MODEL.md` and `PROJECT_STATUS.md` instead.
- Everything on the super-lot page runs inside one **Quality sign-in window** (30 min idle, 4 h
  ceiling, ends on leaving the page): `Common.Session.requireElevation(session, "ControlledRun",
  "Quality sign-in", {...})` replays as page message `controlledRunAction`. **Signatures are outside
  the window**: they take account + password at the moment of signing and pass the signer id straight
  to the proc. `Quality.ufn_SignatureAllowed` is the only place that decides who may sign.
- Results entry is an **accordion using the component's built-in expand flag**; `reload()` rewrites
  `props.items` and carries each item's `expanded` over. Do not bind `props.items`.
- Per-unit clears on LOT Detail stay allowed for super-lot members.
- Open questions in the piece 5 draft (does a reworked part stay in its LOT? is Return for received
  material only? what paperwork?) are for Jacques. He answers fast when asked in plain language with
  a recommendation; he pushed back when I replaced something built-in with my own code without a
  reason, and he wants a mock before a screen is built.

## Things that will bite

- **Generated procs.** The piece 4 mutation procs (`R__Lots_ContainerRework_SetStage / Resume / Void /
  Scrap / MovePieces`) came from a scratch generator that is NOT in the repo. The committed `.sql` is
  the source of truth; edit it directly and keep the shape. Every rule in the reject block is
  parenthesised on purpose (an `OR` inside a rule once escaped the "first failing rule" test).
- **Function file order.** `R__Quality_ufn_zzz_ControlledRunMemberResults.sql` has THREE z's because
  it reads `ufn_zz_ControlledRunMemberState`; with two it would deploy first and a fresh DB would fail.
- **Tests that capture result sets by column list.** Adding a column to `ControlledRun_ListMembers`,
  `_Get`, `_List`, `ControlledRunResult_ListByRun` or `SessionPolicy_Get` breaks existing `INSERT ... EXEC`
  temp tables in `sql/tests/0109_ControlledRun/` and others. Prefer a new read proc, or update every
  capture table.
- **Test teardown order.** New tables hang off `Quality.ControlledRunMember` / `ControlledRun`. The older
  test files' teardowns do not know about them, so a test file that throws midway poisons re-runs on the
  same database. Copy the teardown block from `120_completed_containers.sql`; `Quality.Signature` needs
  its trigger disabled to delete.
- **Count pins.** Adding a code-table row broke `0005_Quality_codes` (dispositions) and `0004_Lots_codes`
  (container statuses). Expect the same for any new code row.
- **`EXEC` arguments must be literals or variables**, in tests too: compute an expected string into a
  variable first.
- **The Bash tool mangles heredocs** that contain apostrophes or `\\n`. Write scripts with the Write
  tool and run the file.
- **Views:** new views as new folders are safe. `LineInventory/view.json` was last saved by Designer
  (unicode-escaped operators); it was edited by inserting ONE text line, not by re-serialising. The
  super-lot page and `ControlledRunConfirm` / `ControlledRunMemberRow` were generated and are safe to
  edit as parsed JSON.
- **Run-Tests.ps1 drops its database.** Private name only (`MPP_MES_CRTest` was used). A full clean run
  takes several minutes; baseline is 4,795 assertions with the two count pins since updated.

## Not verified by anyone yet (do not assume it works)

- Nothing past a typed password has been driven from the UI: Save results, Void, Mark the rest, Sign
  and release, Sign deviation, and the 30-minute window itself.
- Piece 4's Repack popup, the line inventory button and the pick popup have never been rendered.
- No real re-completion with label print and AIM post.
- Layout was only seen at a small emulated size.

## State left behind

- `MPP_MES_Dev` has migrations `0110` and `0111` and all procs applied, plus a labelled walkthrough
  fixture: super-lot `CR000001`, LOTs `WALK-CR-*`, container 20031. Remove with
  `sql/scratch/2026-10-13_super_lot_walkthrough_cleanup.sql`.
- Jacques has his own uncommitted changes in the working tree (page-config, a runbook note, the sample
  accordion view, `reference/um.csv`). Stage explicit paths only.

## Follow-ons named but not built

- BOM-component partial fill at the line (piece 4 spec, section 9).
- AIM cancellation post for a voided, already-posted serial (`Lots.AimShipperIdPool_ListVoided @OnlyPosted = 1`).
- The New super-lot wizard still asks for a password on its last step.
- Line scrap by part (`RejectEvent_RecordByPartFifo`) still spreads across CRT-tagged and clean LOTs.
- Trace screens do not mark a scrapped serial (piece 6).
