# Super-lot pieces 2 + 3 Implementation Plan

> **For agentic workers:** executed natively in one session (Jacques's standing preference
> for pattern SQL: in-session TDD, one review at the end). Steps use checkbox syntax.
> The procs follow existing committed shapes; where a task says "shape of X", open X and
> keep its structure (validation blocks, failure logging, CATCH) exactly.

**Goal:** A completed container's CRT tag becomes real when it joins a super-lot, and a
super-lot gains inspection results, a signed bulk release, a deviation record and a
30-minute Quality sign-in window.

**Architecture:** One migration (`0110`) adds five tables and a few columns. Rules live in
SQL: status-row procs with every rejection before `BEGIN TRANSACTION`, one inline function
(`ufn_ControlledRunMemberResults`) that both the screen and the release proc read. Python
stays thin. The Results tab is an accordion of two new views; the existing page is changed
by a JSON-level script.

**Tech stack:** SQL Server 2022, Ignition 8.3 Perspective (file-based), Jython 2.7.

**Specs:** `docs/superpowers/specs/2026-10-12-controlled-run-results-and-signoff-design.md`
(piece 3, authoritative for D1-D11) and
`docs/superpowers/specs/2026-10-12-controlled-run-completed-containers-design.md` section 10
(piece 2). Mockup: `mockup/controlled_run_results_signoff_mock.html`.

## Global Constraints

- No `OUTPUT` parameters; one result set per proc; mutation procs end every path with
  `SELECT @Status AS Status, @Message AS Message[, @NewId AS NewId]`.
- A status-row proc never `EXEC`s another status-row proc and never `ROLLBACK`s outside
  CATCH. Inline with a `MIRROR of <file>` comment.
- Every rejecting validation runs before `BEGIN TRANSACTION`.
- `EXEC` arguments are literals or `@variables` only.
- ASCII-only in every seed string and SQL literal (byte-scan the migration).
- Timestamps stored `SYSUTCDATETIME()`, returned Eastern via `AT TIME ZONE`.
- Audit descriptions: `<SUBJECT> <middot> <CATEGORY> <middot> <ACTION>` via
  `Audit.ufn_MidDot()` + `Audit.ufn_TruncateActivity`.
- Named queries live in Core only; a status-row proc's NQ is `type: Query`.
- Never `int()` first on a scan; never write a rule in Python or a view expression.
- Tests run on a private database: `MPP_MES_CRTest`. Never `MPP_MES_Dev` / `MPP_MES_Test`.
- The FDS is not edited. No `Co-Authored-By` trailer. Stage explicit paths only.
- New views: folder + `view.json` + `resource.json`; never nest a view folder in a view
  folder; event script bodies start with a tab; `scope: "G"` on every script event.

## Review Focus

1. **A member cleared per unit before release** (LOT Detail) - release must still end its
   membership and write no `CrtCleared` row for it. Test in Task 5.
2. **Scrap that drives a LOT member to zero** - the LOT closes, stays tagged, and must
   still be releasable. Test in Task 3 + Task 5.
3. **Two entries for the same LOT in one results call whose scrap together exceeds the
   LOT** - refused as a whole before anything is written. Test in Task 3.
4. **A member id from another super-lot, or one already released, in the ticked list** -
   whole release refused, nothing cleared. Test in Task 5.
5. **A released unit tagged again afterwards** - the closed super-lot's cleared count does
   not drop, and the sync does not re-add it. Test in Task 5.

## File Structure

```
sql/migrations/versioned/0110_controlled_run_results_signoff.sql        (create)
sql/migrations/repeatable/
  R__Quality_ControlledRun_ApplyMembersInternal.sql                      (modify v1.1)
  R__Quality_ControlledRun_RemoveMember.sql                              (modify: message)
  R__Quality_ufn_zz_ControlledRunMemberResults.sql                       (create)
  R__Quality_ufn_zz_SignatureAllowed.sql                                 (create)
  R__Quality_ControlledRunResult_Record.sql                              (create)
  R__Quality_ControlledRunResult_Void.sql                                (create)
  R__Quality_ControlledRunResult_ListByRun.sql                           (create)
  R__Quality_ControlledRunDeviation_Raise.sql                            (create)
  R__Quality_ControlledRunDeviation_ListByRun.sql                        (create)
  R__Quality_ControlledRun_Release.sql                                   (create)
  R__Quality_ControlledRun_ListSignatures.sql                            (create)
  R__Quality_SignatureMeaning_Get.sql                                    (create)
  R__Quality_ControlledRun_ListMembers.sql / _Get.sql / _List.sql        (modify)
  R__Quality_ControlledRun_Cancel.sql / _SyncInternal.sql                (modify)
  R__Location_SessionPolicy_Get.sql / _Update.sql                        (modify)
sql/tests/0109_ControlledRun/
  040_open.sql, 050_reads.sql                                            (modify on purpose)
  120_completed_containers.sql, 130_results.sql, 140_deviation_signature.sql,
  150_release.sql                                                        (create)
ignition/projects/Core/ignition/named-query/quality/<8 new>/             (create)
ignition/projects/Core/ignition/script-python/BlueRidge/Quality/ControlledRun/code.py   (modify)
ignition/projects/Core/ignition/script-python/BlueRidge/Common/Session/code.py          (modify)
ignition/projects/Core/ignition/script-python/BlueRidge/Location/SessionPolicy/code.py  (modify)
ignition/projects/MPP/.../session-props/props.json                       (modify: elevationProfile)
ignition/projects/MPP/.../views/BlueRidge/Components/PlantFloor/
  ControlledRunResults/  ControlledRunResultHeader/  ControlledRunResultEntry/
  ControlledRunResultLogRow/  ControlledRunSignOff/  ControlledRunReleaseRow/
  ControlledRunSignatureRow/                                             (create)
ignition/projects/MPP/.../views/BlueRidge/Components/Popups/
  ControlledRunRelease/  ControlledRunDeviation/                         (create)
  ControlledRunConfirm/view.json                                         (scripted edit)
ignition/projects/MPP/.../views/BlueRidge/Views/ShopFloor/ControlledRuns/view.json (scripted edit)
tools/scratch is NOT used: generator scripts live in the session scratchpad.
MPP_MES_DATA_MODEL.md, PROJECT_STATUS.md, notes/2026-10-12_crt-super-lot-...md  (modify)
```

Test command for every task (PowerShell, from `sql/tests`):

```
.\Run-Tests.ps1 -DatabaseName MPP_MES_CRTest -Filter "ControlledRun"
```

Baseline before Task 1: 171 assertions, 0 failures. After each task the count must be
baseline + that task's new assertions; exit 1 with 0 failures means a file threw and
later batches never ran.

---

### Task 1: Migration 0110

**Files:** create `sql/migrations/versioned/0110_controlled_run_results_signoff.sql`;
test `sql/tests/0109_ControlledRun/010_schema.sql` (append).

**Produces:** tables `Quality.SignatureMeaning`, `Quality.Signature` (+ trigger
`Quality.TR_Signature_Immutable`), `Quality.ControlledRunRelease`,
`Quality.ControlledRunResult`, `Quality.ControlledRunDeviation`; columns
`ControlledRunMember.WasCompleteAtJoin`, `.ControlledRunReleaseId`,
`SessionPolicy.QualityElevationTimeoutSeconds` (1800), `.QualityElevationMaxSeconds`
(14400); code rows `DispositionCode.Accepted`, `ControlledRunMemberEndReason.Released`
(Id 4), sequence `ControlledRunDeviation` (`DV{0:D6}`), four audit event codes.

- [ ] Append assertions to `010_schema.sql`: each table exists; `Released` = Id 4;
      `Accepted` exists; the sequence row; `UPDATE Quality.Signature` and `DELETE` both
      raise (TRY/CATCH, assert the message contains `append-only`).
- [ ] Run: fails (objects missing).
- [ ] Write the migration in the shape of `0109_controlled_run.sql` (guard, per-statement
      idempotence, extended properties, SchemaVersion row). Trigger body:
      `THROW 51010, 'Quality.Signature is append-only.', 1;` (AFTER UPDATE, DELETE).
- [ ] Byte-scan the file for non-ASCII; run tests; commit
      `feat(quality): migration 0110 -- results, release, deviation, signature`.

### Task 2: Piece 2 -- tag the Closed trays of a joining container

**Files:** modify `R__Quality_ControlledRun_ApplyMembersInternal.sql`,
`R__Quality_ControlledRun_RemoveMember.sql`; modify `040_open.sql`, `050_reads.sql`;
create `120_completed_containers.sql`.

- [ ] Change the two pinned assertions: `040` expects `1|1` for the completed container
      ("its Closed tray IS tagged, CrtSetByRun = 1"); `050` cleared count drops by one.
- [ ] Write `120_completed_containers.sql`: completed container joins (tray tagged, one
      `CrtActivated`, `WasCompleteAtJoin = 1`; an open container gets 0); a Closed LOT
      that is not a tray is still ineligible; `Lots.Container_Ship` refuses the tagged
      container; its unposted pool serial is absent from `AimShipperIdPool_ListUnposted`
      and returns after `Container_ValidateCrt`; join by `ControlledRun_AddMembers`
      behaves the same; `ControlledRun_Close` refuses while it is tagged; a container on
      a `Quality.Hold_Place` hold can still join and both blocks stand;
      `RemoveMember` on a tagged container says "Sign-off".
- [ ] Run: the new and changed assertions fail.
- [ ] Helper v1.1: the UPDATE's status test becomes
      `(sc.Code <> N'Closed' AND l.Id IN (member LOTs)) OR l.Id IN (trays of member containers)`;
      INSERT adds `WasCompleteAtJoin = CASE WHEN container status = 'Complete' THEN 1 ELSE 0 END`.
      `RemoveMember`: `@Tail` branches on `@ContainerId IS NOT NULL`.
- [ ] Run; commit `feat(quality): super-lot piece 2 -- a completed container's tag is real`.

### Task 3: Results

**Files:** create `R__Quality_ufn_zz_ControlledRunMemberResults.sql`,
`R__Quality_ControlledRunResult_Record.sql`, `_Void.sql`, `_ListByRun.sql`; modify
`R__Quality_ControlledRun_ListMembers.sql`; create `130_results.sql`.

**Produces:**
- `Quality.ufn_ControlledRunMemberResults(@ControlledRunId)` -> `MemberId, AcceptedQty,
  ScrapQty, ReworkQty, ReturnQty, UseAsIsQty, AppliedScrapQty, ResultQty, LeftOver,
  HasResult BIT, ReleaseBlockReason NVARCHAR(100) NULL`.
- `Quality.ControlledRunResult_Record @ControlledRunId, @ResultsJson, @AppUserId,
  @TerminalLocationId` -> `Status, Message, NewId`. JSON items
  `{memberId, dispositionCode, quantity, defectCodeId, remarks}`.
- `Quality.ControlledRunResult_Void @ResultId, @Remarks, @AppUserId, @TerminalLocationId`
  -> `Status, Message`.
- `Quality.ControlledRunResult_ListByRun @Id, @IncludeVoided BIT = 0` -> `ResultId,
  MemberId, DisplayName, DispositionCode, DispositionName, Quantity, DefectCode,
  DefectDescription, Remarks, RecordedByInitials, RecordedAt (ET), IsApplied, IsVoided,
  CanVoid`.

- [ ] Write `130_results.sql` covering spec 9 "Results" and "Void" plus Review Focus 2
      and 3.
- [ ] Run: fails.
- [ ] Write the function, then `_Record` (scrap block = inlined mirror of
      `R__Workorder_RejectEvent_Record.sql` subtractive path, cursor over scrap entries
      on LOT members; held LOT allowed, `Closed`/`Scrap`/`Open` refused; per-LOT scrap
      total checked against `PieceCount` before the transaction and re-checked under
      `UPDLOCK`), `_Void`, `_ListByRun`; extend `_ListMembers`.
- [ ] Run; commit `feat(quality): super-lot inspection results and void`.

### Task 4: Signature seam and deviation

**Files:** create `R__Quality_ufn_zz_SignatureAllowed.sql`,
`R__Quality_SignatureMeaning_Get.sql`, `R__Quality_ControlledRunDeviation_Raise.sql`,
`_ListByRun.sql`; create `140_deviation_signature.sql`.

**Produces:** `Quality.ufn_SignatureAllowed(@AppUserId BIGINT, @MeaningCode NVARCHAR(30))
RETURNS BIT`; `Quality.SignatureMeaning_Get @Code` -> `Code, Name, Statement`;
`Quality.ControlledRunDeviation_Raise @ControlledRunId, @Description, @Justification,
@DefectCodeId, @AffectedQuantity, @ExternalReference, @AppUserId, @TerminalLocationId`
-> `Status, Message, NewId`; `_ListByRun @Id` -> `Id, DeviationNumber, ExternalReference,
Description, Justification, DefectCode, AffectedQuantity, SignedByInitials, RaisedAt (ET)`.

- [ ] Tests: `DV000001` then `DV000002`; signature row carries the meaning's statement
      and entity `ControlledRun`; blank description / justification refused; a user with
      no AD account refused by the seam; closed super-lot refused; a refused raise burns
      no number.
- [ ] Implement (sequence mint = inlined mirror, as in `ControlledRun_Open`); run; commit
      `feat(quality): signature record, signing seam, super-lot deviation`.

### Task 5: Signed release and piece 1 follow-ons

**Files:** create `R__Quality_ControlledRun_Release.sql`,
`R__Quality_ControlledRun_ListSignatures.sql`; modify `_Get`, `_List`, `_Cancel`,
`_SyncInternal`; create `150_release.sql`.

**Produces:** `Quality.ControlledRun_Release @Id, @MemberIdsJson, @InspectionConfirmed,
@Remarks, @AppUserId, @TerminalLocationId` -> `Status, Message, NewId`;
`Quality.ControlledRun_ListSignatures @Id` -> `SignedAt (ET), SignedByInitials,
MeaningCode, MeaningName, Statement, Summary`.

- [ ] Tests: spec 9 "Release" and "Piece 1 reads", Review Focus 1, 2, 4, 5.
- [ ] Implement. Clear = inlined mirror of `R__Lots_Lot_ClearCrt.sql` with `OUTPUT` into a
      table and one audit row per LOT; `SUPERLOT_RACE` on a row-count mismatch, mapped in
      CATCH as `ControlledRun_Open` does. `_Get`/`_List`: member filter
      `EndedAt IS NULL OR reason IN (RunClosed, Released)`, cleared =
      `CrtActive = 0 OR reason = Released`. `_Cancel`: refuse when a
      `ControlledRunRelease` row exists. `_SyncInternal`: `@Removed` also takes reason 4.
- [ ] Run the suite, then `-Filter "Crt"` (178 baseline); commit
      `feat(quality): super-lot signed bulk release`.

### Task 6: Session policy -- Quality window values

**Files:** modify `R__Location_SessionPolicy_Get.sql`, `_Update.sql`,
`BlueRidge/Location/SessionPolicy/code.py`; the existing session-policy test file.

- [ ] Test: Get returns both values (1800 / 14400); Update with them omitted leaves them;
      Update with them set stores them; max below timeout refused.
- [ ] Implement (`@QualityElevationTimeoutSeconds INT = NULL`, `@QualityElevationMaxSeconds
      INT = NULL`, NULL = keep); NQ params added with `sqlType 4`; Python fallback dict
      gains the two keys. Run `-Filter "SessionPolicy"`; commit.

### Task 7: Named queries and script module

**Files:** eight NQ folders under `Core/.../named-query/quality/` (`ControlledRunResult_Record`,
`_Void`, `_ListByRun`, `ControlledRunDeviation_Raise`, `_ListByRun`, `ControlledRun_Release`,
`ControlledRun_ListSignatures`, `SignatureMeaning_Get`), copied from
`ControlledRun_RemoveMember` / `_ListMembers`; modify `BlueRidge/Quality/ControlledRun/code.py`.

**Produces (Python):** `recordResults(runId, entries, appUserId, terminalLocationId)`,
`acceptRemaining(runId, appUserId, terminalLocationId)`, `voidResult(resultId, remarks,
appUserId, tid)`, `raiseDeviation(runId, data, appUserId, tid)`, `release(runId, memberIds,
confirmed, remarks, appUserId, tid)`, `signatureStatement(code)`, `resultItems(runId,
expandedIds, ...)` (accordion items), `resultLogInstances`, `releaseInstances(runId,
tickedJson)`, `tickToggle` / `tickAllReady` / `tickedIds`, `deviationInstances`,
`signatureInstances`, entry-draft helpers `draftAdd` / `draftSet` / `draftRemove` /
`draftAcceptRest` / `draftInstances` / `draftTotals` (a JSON string, as the wizard keeps
its preview).

- [ ] Write; compile-check `code.py` in memory (`compile(src, 'code.py', 'exec')` under
      Python 2 syntax rules - never `py_compile` in the tree); `.\scan.ps1`; call each
      read through the gateway once; commit.

### Task 8: Quality sign-in window

**Files:** modify `BlueRidge/Common/Session/code.py`, MPP `session-props/props.json`.

- [ ] `loadPolicyIntoSession` adds the two Quality values; `_elevationSeconds`,
      `_elevationMaxSeconds`, `activeTimeoutSeconds` branch on
      `session.custom.elevationProfile == "Quality"`; new `setElevationProfile(session,
      profile)` - entering stamps the profile and re-stamps both deadlines from now when
      a window is open; leaving clears it and clamps `elevatedUntil` to now + the
      standard timeout. Declare `elevationProfile: ""` in session props.
- [ ] Scan; commit.

### Task 9: Views

**Files:** the seven component views and two popups listed above (generated by a
scratchpad script into new folders), then scripted edits to `ControlledRuns/view.json`
(custom `activeTab`, `resultsToken`; tab click events and classes; display bindings on
`MemberHeader` / `MemberRepeater` / `DetailFoot`; two `ia.display.view` embeds; KPI label
"Released"; `events.system.onStartup` / `onShutdown` calling `setElevationProfile`;
mutating buttons routed through `requireElevation`) and `ControlledRunConfirm/view.json`
(credential fields hidden and skipped while elevated).

- [ ] Generate; validate every `view.json` parses and every event has `scope`; verify
      icon paths; `.\scan.ps1`; read `wrapper.log` for deserialize errors.
- [ ] Walk in the browser pane: page loads, tabs switch, accordion expands and survives a
      reload, tiles add lines, Sign-off lists members. Record what could not be walked.
- [ ] Commit `feat(quality): super-lot Results and Sign-off tabs`.

### Task 10: Docs and end review

- [ ] `MPP_MES_DATA_MODEL.md` (new tables, columns, `NonConformance` marked never built,
      revision row); `node sql/scripts/gen_extended_properties.js`; `PROJECT_STATUS.md`
      entry; overview note revision row; spec status lines -> BUILT.
- [ ] Apply `0110` + repeatables to `MPP_MES_Dev` (additive).
- [ ] One independent review of the branch diff; fix what it confirms; final test run;
      commit.

## Self-review

Spec coverage: piece 2 section 10 items 1-9 -> Task 2 (item 8, container moves, is a grep
in Task 2 recorded in the status entry); piece 3 section 5.1-5.6 -> Tasks 3-5; section 6 ->
Tasks 6 and 8; section 7 -> Tasks 7 and 9; section 4 -> Task 1. No AIM call is added
anywhere (decided). Names used in Tasks 7 and 9 match the result sets declared in 3-5.
