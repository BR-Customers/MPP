# FAT remaining-work handoffs — 2026-08-05

Paste-ready agent briefs for the FAT items not yet built. Source triage:
`notes/2026-08-04_fat-testing-notes.md`. Status at time of writing: 13 done, 14 remaining;
#2 and #3 have approved specs (plans/implementation pending — see end).

## Shared-environment rules (apply to EVERY handoff below)

There is **one** working tree and **one** Ignition gateway (symlinked to it) and **one** dev DB.
Multiple agents can work here safely IF they follow these — the rules exist because a prior round
lost work:

- **Stay on `jacques/working`. Do NOT run `git checkout <branch>`** — a checkout rewrites every file
  in the shared tree and reverts other agents' in-flight work. Commit directly to `jacques/working`.
- **Stage explicit paths only** (`git add <path>`), never `git add -A`/`-u` — the tree holds other
  agents' uncommitted files; inspect `git status` before committing and don't sweep up files you
  didn't create. No `Co-Authored-By` trailer.
- **Edit disjoint files.** Two agents editing the *same* view/proc collide. Each brief below lists its
  files; if two briefs overlap, run them sequentially, not in parallel.
- **Gateway/view work is single-lane.** Only one agent should be editing `view.json` + running
  `scan.ps1` at a time. Existing `view.json` edits are safe as file edits ONLY while Designer is
  closed (else its cache races the disk); new SQL/NQ/Python are always safe. Run `.\scan.ps1` after
  any Ignition resource change.
- **DB validation:** use a uniquely-named throwaway DB (e.g. `MPP_MES_<Feature>`) via the reset flow
  (`sql_version_control_guide.md`); NEVER reset `MPP_MES_Dev`; don't use `MPP_MES_Test` if another
  agent might be. Next free versioned migration number: check the highest committed (currently `0050`,
  plus specs reserve `0051` for #3) — take the next free one and confirm no collision.
- Follow `CLAUDE.md`: FDS-11-011 (no OUTPUT params; status-row procs), audit Description convention,
  no business logic in Python, ASCII-only seeds, Ignition file-edit boundary.

---

## Handoff A — Terminal / Printer / IP cluster (#13, #14, #15, #16) — ✅ DONE (2026-08-05)

**Outcome (commits `aac8137c` #16/#15, `7d225ac1` #13/#14):**
- **#16 (bug):** root cause = `Terminal_GetByIpAddress` did a raw exact-string compare of the
  admin-typed `IpAddress` vs `session.props.address`, but the gateway observes loopback as the
  bracketed IPv6 form `[0:0:0:0:0:0:0:1]` (proven via a live onStartup diagnostic) — so a correct
  config silently fell to the Facility fallback. Fix: new `Location.ufn_NormalizeIpAddress` (strip
  brackets/zone-index, collapse loopback synonyms → `127.0.0.1`, strip IPv4-mapped `::ffff:` prefix);
  proc normalizes both sides. TDD `011_Terminal_GetByIpAddress_normalization.sql` (15 asserts), sibling
  010 green (26/26). Deployed to live `MPP_MES_Dev`.
- **#15 (verify):** confirmed end-to-end — with the fix live, the exact gateway-observed string
  `[0:0:0:0:0:0:0:1]` resolves to the test terminal (IsFallback=0). (Live browser-session render could
  not be exercised: the in-app browser pane is non-compositing here.)
- **#13 (feat):** enumerated-attribute dropdown in `LocationAttributeValueRow`; `DefaultScreen` offers
  the 12 curated operator-station routes (`BlueRidge.Location.AttributeOptions.forAttr`),
  `allowCustomOptions=true` so existing/dedicated values persist.
- **#14 (feat):** `ConnectionKind` (Networked/Hardwired) attr added to Printer DefId 16 (gen script +
  seed 011 + live Dev); "Validate endpoint" button in Plant Hierarchy (Printers only) →
  `BlueRidge.Location.Printer.validateEndpoint` (Networked TCP-probes IP:port default 9100/2s;
  Hardwired = "cannot validate here", never failed). Gateway-verified (options 12/2/0; hw=info,
  open=success, closed=error).
- **Recommended follow-up:** 30-sec visual smoke of the config app (select a Terminal → DefaultScreen
  dropdown; select a Printer → ConnectionKind dropdown + Validate button) — wiring is script- and
  JSON-verified but not visually rendered in this environment.

Cohesive: terminal-config UX + IP resolution. Contains one bug (#16), verification (#15), and two
features (#13, #14). Do as one agent, sequentially within the brief.

Cohesive: terminal-config UX + IP resolution. Contains one bug (#16), verification (#15), and two
features (#13, #14). Do as one agent, sequentially within the brief.

```
Work on the MPP MES "terminal / printer / IP" FAT cluster (items #13, #14, #15, #16). Read
CLAUDE.md, notes/2026-08-04_fat-testing-notes.md (items #13-16), the memory
project_mpp_terminal_session_context, and ignition-context-pack/*. Key code:
BlueRidge.Location.Terminal.applyToSession + getByIpAddress (Core script), the Terminal config
editor view (grep the MPP_Config views for the terminal/printer editor), the Printer
LocationTypeDefinition (Id 16, attrs Endpoint + Model; seeded in sql/seeds/011_seed_locations_mpp_plant.sql),
and the session onStartup that resolves the terminal by IP (grep 'getByIpAddress' + onStartup).

- #16 (BUG, do FIRST): on session startup the IP-address terminal resolution "did not fire
  correctly." Reproduce and root-cause with the systematic-debugging skill BEFORE any fix. Likely
  suspects: the onStartup event channel (events.system vs events.component — a file-authored
  events.component.onStartup is silently dead), the IP source (session.props.address vs a header),
  or getByIpAddress matching. Add a failing/diagnostic check, fix root cause, verify a real terminal
  IP resolves to its terminal + zone + defaultScreen (not the Facility-wide fallback).
- #15 (VERIFY): confirm a terminal resolves by IP end-to-end (the fallback terminal has
  zoneLocationId = whole Facility — the tell-tale "Madison Facility" subtitle). Document the check.
- #13 (FEAT): make the terminal config's "default screen" selection a DROPDOWN (currently free
  entry). Enumerate the known page routes from the MPP page-config
  (com.inductiveautomation.perspective/page-config/config.json) as the option list.
- #14 (FEAT): printer endpoint "valid endpoint" validation. Add a 'Networked' vs 'Hardwired'
  attribute to the Printer LocationTypeDefinition (16). For Networked, add a gateway-side reachability
  check of the Endpoint (IP:port) surfaced as a "valid endpoint" notification in the config app; for
  Hardwired, label it "cannot validate here" (a queue-name printer isn't reachable from the config
  app). A hardwired printer must never be failed as invalid.

Apply the shared-environment rules from docs/handoffs/2026-08-05-fat-remaining-handoffs.md. Report:
root cause of #16, the IP-resolution verification result, and the files touched.
```

---

## Handoff B — Die-cast entry fixes + shot-loss UX (#19, #24, #23) — ✅ CODE DONE, awaiting live smoke (2026-08-05)

> **Done (uncommitted on `jacques/working`):**
> - **#24** — root cause: the DieCastOverflow Apply `props.enabled` binding passed the `overflow`
>   *list* through a `runScript()` expr arg → arrives as `QualifiedValue[]` (which `extractQualifiedValues`
>   does NOT unwrap) → `.get()` on a QV → the thrown error; button fail-open-enabled hid it (the gate
>   never gated). Fixed: compute `view.custom.applyEnabled` in the popup's `overflowDecisionChanged`
>   handler (proper scope) and bind `props.enabled` to that scalar. View-only.
> - **#19** — `DieCastShiftOutput_Record` logged `DieCastPieceContributed` with `@LocationId=NULL`.
>   Added `@CellLocationId` (proc v1.3) → audit `@LocationId`; threaded view→entity→NQ→proc (submit +
>   all 3 overflow-resolve record calls). Test `0045/030` +1 assert; **69/69** on a throwaway DB;
>   proc applied to `MPP_MES_Dev`. **C-collision (proc shared with #20): resolved by editing line 129
>   only (audit call); #20's RejectEvent-insert lines untouched — rebase-safe.**
> - **#23** — `CavityLotRow` Good now auto-decrements on scrap entry (editable, incremental delta from
>   current Good, hand-adjustable) via new `applyScrap` method; "Register shot loss" row moved to the
>   TOP of the Record Shift Output tab (divider flipped top→bottom). Views-only.
> - **Drive-by fix:** `0045/030` referenced the dropped `Quality.DefectCode.AreaLocationId` (removed by
>   migration `0048`, FAT #1) → whole batch failed to COMPILE → 030 had been fully dead since 0048.
>   Switched to `OperationCategoryId` (NULL = plant-wide). **The FAT #1 work missed this test.**
> - **Owed:** Jacques live smoke of the 3 view changes (no automated UI test); commit.

The die-cast shift-output/entry surface. #19 + #24 are bugs; #23 is a UX rework. All touch
`Views/ShopFloor/DieCastBody` and the shift-output path, so keep them in ONE agent (serial) to avoid
same-file collisions.

```
Work on the MPP MES die-cast entry FAT items #19, #24, #23. Read CLAUDE.md,
notes/2026-08-04_fat-testing-notes.md (#19/#23/#24), migration
sql/migrations/versioned/0045_diecast_per_cavity_lifecycle.sql, R__Workorder_DieCastShiftOutput_Record.sql,
and Views/ShopFloor/DieCastBody/view.json (large). Use systematic-debugging for the two bugs.

- #24 (BUG): the "submit shift output" overflow-warning "Apply" button throws an error but is
  functional (works despite the error). Root-cause the thrown error in the DieCastOverflow popup /
  its Apply handler (grep 'dieCastOverflowResult' + 'DieCastOverflow') and fix so it no longer throws.
- #19 (BUG): the event-log LocationId does not capture the die-cast MACHINE selected when parts are
  added. The shift-output / parts-added audit op passes NULL or the terminal instead of the selected
  machine location. Thread the selected die-cast machine (cell) LocationId into the audit
  (Audit_LogOperation @LocationId) for the parts-added / DieCastPieceContributed op.
- #23 (FEAT/UX): "register shot loss" — move all cavity entry to the TOP of the screen, and make each
  cavity's Good-parts value AUTO-DECREASE as scrap quantity is entered for that cavity (live client-
  side recompute: good = proposed - Σscrap for the cavity). Layout + reactive binding work in
  DieCastBody; no schema change expected.

Apply the shared-environment rules from docs/handoffs/2026-08-05-fat-remaining-handoffs.md. Because
Designer must be CLOSED for file-based view edits, coordinate with the human before editing DieCastBody.
Report root causes for #19/#24 and the #23 UX change.
```

---

## Handoff C — Scrap ProductionEvent link + shot-count reconciliation (#20, #27)

> **Status: DONE** (2026-08-05). Investigation confirmed die-cast shift output creates **no
> `ProductionEvent`** (migration 0045 removed it), so #20's "thread the shift-output
> ProductionEventId" premise no longer holds. **Decision (Jacques): #20 = NULL-by-design**
> (no proc change; die-cast additive scrap has no event to tie to — the column is meaningful only
> for the subtractive downstream reject path). Pinned by regression guard
> `sql/tests/0045_DieCast_Lifecycle/070_ShiftOutput_RejectEvent_NullProductionEventId.sql`
> (6/6 pass). **#27 = deferred** (obsoleted by 0050's live in-txn `ShotCount` increment; no
> independent source to reconcile against). Rationale:
> `notes/2026-08-05_diecast-rejectevent-productioneventid-null-by-design.md`. No edit to
> `R__Workorder_DieCastShiftOutput_Record.sql` (left to Handoff B to avoid a same-file race).

Small backend items, disjoint from the view work above. One agent.

```
Work on MPP MES backend items #20 and #27. Read CLAUDE.md, notes/2026-08-04_fat-testing-notes.md
(#20 decided; #26/#27 direction), R__Workorder_DieCastShiftOutput_Record.sql,
R__Workorder_RejectEvent_Record.sql, and the tool-shot spec
docs/superpowers/specs/2026-08-04-tool-shot-count-design.md.

- #20 (decided): scrap recognized DURING a "Record Shift Output" event should store that shift-output
  event's ProductionEventId on the Workorder.RejectEvent rows (standalone die-cast cavity rejects may
  stay NULL). Thread the shift-output ProductionEventId into the additive RejectEvent inserts in
  DieCastShiftOutput_Record. Add a test asserting the RejectEvent rows carry the ProductionEventId.
- #27 (optional backstop): the die shot counter (Tools.Tool.ShotCount) is already incremented at
  shift-output time (the primary path). Add a NIGHTLY reconciliation gateway timer that recomputes
  each tool's ShotCount from the source ProductionEvent/DieCastContribution shot data and corrects
  drift — a backstop, not the primary path. Follow the Project-Tag/timer conventions in
  ignition-context-pack/05_lifecycle_and_timers.md; use systemAppUserId() for attribution. Confirm
  with the human whether #27 is wanted now or deferred before building it.

Apply the shared-environment rules from docs/handoffs/2026-08-05-fat-remaining-handoffs.md. Report the
#20 change + test, and whether #27 was built or deferred.
```

---

## Handoff D & E — Brainstorm-first (NOT solo-implementable): #17, #21 — 🟡 IN PROGRESS (started 2026-08-05)

> **#21 (E) — DONE 2026-08-05** (spec → plan → implemented → reviewed → tested; not yet pushed).
> Spec `docs/superpowers/specs/2026-08-05-finished-goods-close-inventory-lifecycle-design.md`,
> plan `docs/superpowers/plans/2026-08-05-finished-goods-close-inventory-lifecycle.md`.
> Decisions: close FG LOT Good→Closed **inline in `Lots.Container_Complete`** (via new silent helper
> `Lots.Lot_CloseInline`), close-the-loop in `Quality.Hold_Release` for held trays; status-only
> inventory exclusion; no reversal path; no timer. Commits b046baa8, a50b473d, 3b2c0c2c, abf6a34d.
> Tests: `sql/tests/0029_.../085,090,100` — full 0029 suite 59/59. Final review (opus): ready to merge.
> **#17 (D) — still pending brainstorm** (not started).

These are UX/architecture designs, not mechanical builds — they need a brainstorm with Jacques before
any implementation (per the brainstorming skill). Do NOT hand these to a solo implementation agent.
Scope briefs for the brainstorm sessions:

- **#17 Hold management UX.** Current `Views/ShopFloor/HoldManagement` + `Quality.HoldEvent`
  (one-open-per-lot/container, migrations 0029-0031). Goal: a total UX review so holds are actionable
  from **Lot Search** and the **inspection area**, not only the Hold Management screen. Brainstorm:
  where hold/release actions surface, the hold lifecycle states, and the Honda hold/AIM notification
  tie-in. Output: a spec, then plan.
- **#21 Finished-goods close / inventory lifecycle.** When a LOT is fully consumed by containers it
  should CLOSE — decide the trigger (immediate on final consumption / delayed / shipping-triggered),
  the final operator action, and how to filter finished goods out of a line's inventory WITHOUT
  ghosting them (must stay genealogy-queryable). Ties into the container/tray FG model (migration
  0034) and shipping. Brainstorm → spec → plan.

## Notes on the rest

- **#7 config-app standing AD-login gate** — Jacques is driving this (a project/view permission on
  `MPP_Config` requiring an authenticated AD user at all times). Not in a handoff.
- **#2 (Trim OUT multi-reason scrap)** and **#3 (downtime codes by OperationCategory)** — specs written
  and committed (`docs/superpowers/specs/2026-08-05-trim-out-multi-reason-scrap-design.md`,
  `2026-08-05-downtime-code-operation-category-scoping-design.md`). Next step is writing-plans then
  implementation; #3 is a mechanical mirror of the shipped #1 defect-code work, #2 depends on #1.
- **getSessionInfo() landmine** — separate spawned task (fixes `_currentAppUserId` +
  `ShippingDispatcher/LotLabel._sessionPrinter`, all of which read the list-returning API as a dict).
```
