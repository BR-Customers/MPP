# FAT testing notes — 2026-08-04

Raw punch-list from today's FAT, grouped and triaged. Legend:
**BUG** = defect vs intended behavior · **FEAT** = new/changed behavior · **Q** = decision needed ·
**COVERED** = already addressed by an in-flight spec/plan · **DONE** = fixed + verified.

## Progress / decisions (2026-08-04)

- **#4 DONE** — Trim OUT attribution fixed (`submitTrimOut` now passes `session.custom.appUserId`).
  Root cause: `Common.Util._currentAppUserId()` reads `getSessionInfo()` as a dict but the API
  returns a LIST → falls back to Dev User (AppUser 2). Same broken pattern in
  `ShippingDispatcher._sessionPrinter` + `LotLabel._sessionPrinter` → spawned a separate task.
- **#22 DONE** — Trim OUT re-entry guard added (`@FromLocationId = @TrimStoreId`), TDD red→green
  (test `050_TrimOut_Record_validation.sql` Test 6, area-level source). Root cause: Trim Storage
  is a child of the trim area, so the source-ancestor guard didn't block a same-shop re-entry.
- **#1 defect-code scoping** — spec + plan written; a subagent executed SQL Tasks 1–7 on an
  isolated branch (33/33 tests). Needs convergence into `jacques/working` + `scan.ps1` + the
  Designer view edits (Task 8). Migration is `0047` (correct on `jacques/working`, which has `0046`).
- **#20 decided** — scrap recognized *during a Record Shift Output event* should store the
  `ProductionEventId` of that shift-output event on the RejectEvent; standalone rejects may stay
  NULL. Work item: thread `ProductionEventId` through the shift-output → reject path.
- **#26 direction** — materialized running total on the die (Tool), incremented in the same
  transaction that records shots (like the B5 Lot quantity pattern), NOT recomputed from all LOTs.
  Add `ShotLimit` (nullable) + warn near/over limit; optional nightly reconciliation job. Details below.

## Status at 2026-08-05 (end of implementation session) — 13 done / 14 remaining

**DONE + verified (committed on `jacques/working`):**
- **#1** defect codes scoped by OperationCategory (migration `0048`, procs/NQs/seed/entity script +
  editor/row/list/reject views). **#4** Trim OUT attribution. **#6** cell-change presence re-confirm.
- Session/elevation feature (spec `2026-08-04-plant-floor-session-elevation-design.md`, plan same
  date): **#8** global timeout panel (User Management), **#9/#12** Tool Config gated, **#10** nav
  menu gated + MoveOverride windowed, **#11** elevation core (Supervisor Access / Reset Terminal /
  rolling 5-min idle watcher / `elevationResult`), **#12** OperatorEditor AD Account + Ignition Role
  fields. Backend: `Location.SessionPolicy` (migration `0049`) + procs + `Common.Session` helpers.
- **#18** lot-detail consumed part, **#22** Trim OUT re-entry guard, **#25** bigger toasts,
  **#26** tool shot count (migration `0050`). **#5** now testable (panel or `SessionPolicy_Update`).
- Bug found+fixed mid-build: `SessionPolicy_Update` NULL Description on no-change (`STUFF`-on-empty).

**REMAINING (14):**
- **In progress this session:** #2 (Trim OUT multi-select scrap, Trim-scoped) + #3 (downtime codes
  by OperationCategory — mirror of #1).
- **Handoff-doc cluster:** #13 default-screen dropdown, #14 printer endpoint validation +
  networked/hardwired attr, #15 verify terminal-by-IP, #16 onStartup IP validation bug,
  #19 event-log die-cast machine LocationId, #23 shot-loss cavity UX + auto-decrement, #24 shift-
  output overflow Apply error.
- **Own brainstorm:** #17 Hold management UX, #21 finished-goods close/inventory lifecycle.
- **Decisions made, build pending:** #7 config-app AD gate (Jacques driving), #20 thread
  ProductionEventId into shift-output scrap, #27 optional nightly shot-count reconciliation.

---

## A. Defect / scrap reason scoping  → same theme as today's OperationCategory plan

1. **[COVERED]** Die-cast defect reason selection is not filtered by area.
   → Fixed by `docs/superpowers/plans/2026-08-04-defect-code-operation-category-scoping.md`
   (RejectPanel resolves `getForDropdown("DieCast")`; codes scoped by OperationCategory).
2. **[FEAT]** Trim OUT needs a **multi-select scrap reason** setup (currently only a scrap *count*
   entry). Reasons filtered by Trim-shop codes.
   → Builds directly on the category plan: add a reject/scrap surface to Trim OUT that calls
   `getForDropdown("TrimOut")` (resolves to the `Trim` category + plant-wide). Multi-select is the
   new part — needs a reason×qty capture, not one code. Design: one RejectEvent per reason, or a
   parent scrap with N reason lines?
3. **[FEAT]** Downtime codes are also organized by **area** today; they need the same
   OperationCategory treatment (DieCast / Trim / MachiningAssembly) so any area in that category
   finds them. → Sibling refactor of `Oee.DowntimeReasonCode` mirroring the defect-code plan
   (`DowntimeReasonCode_List`/editor/`DowntimeEntry`). Do this as a second, near-identical spec.

## B. Auth / session / login / elevation  (largest cluster — own workstream)

4. **[BUG]** Trim OUT completion signed in as **BOB** shows in lot detail as "Dev User".
   → Operator attribution not captured on the Trim OUT completion path; it's falling back to the
   dev/system AppUser. Trace which AppUserId the Trim OUT mint proc receives vs the session's
   `appUserId`. Likely the completion action isn't passing `session.custom.appUserId`, or the
   initials/AD resolution returned the fallback. Genealogy-critical (Honda) — high priority.
5. **[TEST]** Test operator re-sign-in by setting timeout to 1 minute.
6. **[FEAT]** Reprompt operator sign-in on die-cast **cell context change**.
7. **[FEAT]** Add login requirement to the **config app** (AD user).
8. **[Q/FEAT]** Make operator login timeout duration changeable via UI. (Where — terminal config?
   session-props? global setting? Decide scope.)
9. **[FEAT]** Tool config on die cast should require **elevated login** to launch the config app.
   (dup of #12.)
10. **[FEAT]** Shop-floor nav menu locked behind an elevated action.
11. **[FEAT]** Elevated user completes task → reset to default (NOT a sticky session): 5-minute
    timeout on elevated permissions **plus** a "Reset Terminal" button that logs out elevated
    permissions, returns to the default screen, and prompts operator initial-initials login.
12. **[FEAT]** (dup of #9) Tool config on die cast requires elevated login.

→ #6–#12 are one coherent **session/elevation model** — worth a dedicated brainstorm+spec before
touching code. Relates to `[[project_mpp_terminal_session_context]]`. #4 is a bug to fix now,
independent of the redesign.

## C. Terminal / printer / IP config

13. **[FEAT]** Terminal-config "default screen" selection → make it a **dropdown** (currently free
    entry?). Enumerate the known screen routes.
14. **[Q/FEAT]** Printer endpoint "valid endpoint" notification. Feasible **partially**: a networked
    printer endpoint (IP:port) can be reachability-tested from the gateway; a hardwired/queue-name
    printer cannot be validated from the config app. Proposal: add a `Networked` vs `Hardwired`
    attribute on the Printer location def; only attempt validation for Networked, and label
    Hardwired as "cannot validate here." (Printer def is LocationTypeDefinition 16, attrs Endpoint +
    Model — add the kind attribute.)
15. **[BUG?]** Validate that a terminal resolves **by IP**. → Confirm `Terminal.applyToSession` IP
    match; the fallback terminal (unregistered IP) yields a Facility-wide zone — see
    `[[project_mpp_terminal_session_context]]`.
16. **[BUG]** On startup, IP-address validation did **not fire correctly**. → Same subsystem as #15;
    onStartup event channel / timing. Check `events.system.onStartup` (not `events.component`).

## D. Hold management

17. **[FEAT]** Hold management needs a total UX/UI review — must be **actionable from Lot Search**
    and from the **inspection area**, not only its own screen. Own brainstorm.

## E. Lot detail / genealogy / event capture

18. **[FEAT]** On lot consumption in Lot Detail, also show the **part that was consumed** (not just
    the LOT). → Join the consumed LOT's Item into the genealogy/consumption read.
19. **[BUG]** Event-log `LocationId` does not capture the **die-cast machine** selected when parts
    are added. → The "parts added" (shift output / register) audit op is passing NULL/terminal
    instead of the selected machine location. Cross-ref #23 (machine selection lives in the die-cast
    entry header).
20. **[Q]** `Workorder.RejectEvent.ProductionEventId` is all NULL — should it be? → Today the
    die-cast RejectPanel doesn't pass one (proc accepts NULL). For additive die-cast scrap there may
    be no ProductionEvent to tie to. Decide: is the reject supposed to reference the shift/production
    event that produced the pieces? If yes, the die-cast entry must thread the current
    ProductionEventId into `submitReject`. Otherwise document NULL-by-design for additive scrap.

## F. Lot lifecycle / finished goods / FIFO guards

21. **[Q/FEAT]** A LOT fully consumed by containers should be **closed** — when? Options: (a)
    immediately on final consumption, (b) after a period, (c) on a shipping trigger. Need the final
    operator action, and to **filter finished goods out of the line's inventory** without *ghosting*
    them (they must remain queryable/genealogy-intact). → Design question; ties into container/tray
    FG model (migration 0034) and shipping.
22. **[BUG]** Trim OUT allowed **manually entering a LOT that had already been through Trim OUT**,
    without a re-check-in. → Route/FIFO guard missing on the Trim-OUT manual-entry path: it should
    reject a LOT whose Trim-OUT step already has a ProductionEvent (or isn't the lowest pending
    route step). Cross-ref the terminal-mint queue rule `[[project_mpp_terminal_mint_model]]`.
    Traceability defect — high priority.

## G. Die-cast entry UX

23. **[FEAT]** Die-cast "register shot loss": move all **cavity entry to the top**; per-cavity Good
    parts should **auto-decrease** with every scrap qty entered. (UX + live recompute; cross-ref #19
    machine capture and the per-cavity lifecycle migration 0045.)
24. **[BUG]** Submit shift output overflow-warning "Apply" button throws an error but is functional
    (works despite the error). → Swallow/fix the error on the overflow-resolution Apply path.
25. **[FEAT]** Make toast notifications a little bigger. → Quick CSS bump in the toast popup
    (`[[project_mpp_toast_system]]`).

## H. Tools / shot count

26. **[Q/FEAT]** Should tools have a **shot-limit** property? And how/where to display **total shots**
    a die has had? → New `Tools` attribute + a read that sums submitted shot counts per tool.
27. **[FEAT]** Daily trigger to update a tool's **shot count** from submitted shot counts by LOT.
    → Gateway timer/scheduled job aggregating shot counts into a materialized tool total (pairs with
    #26's display).

---

## Suggested sequencing (my read)

1. **Now / quick:** #4 (attribution bug — genealogy), #22 (Trim-OUT re-entry guard — genealogy),
   #24 (overflow Apply error), #25 (toast size). #4 and #22 are correctness defects on Honda
   traceability — highest priority.
2. **Extend today's plan:** #2 (Trim-OUT scrap multi-select) and #3 (downtime codes by
   OperationCategory) — same pattern, cheap on the back of the defect-code work.
3. **Dedicated specs (brainstorm first):** B-cluster session/elevation model (#6–#12), #17 Hold
   management UX, #21 FG close/inventory lifecycle.
4. **Terminal/printer:** #13–#16 as one pass (IP resolution + printer-kind validation + default-
   screen dropdown).
5. **Tools shot count:** #26–#27 together.
6. **Genealogy display polish:** #18, #19, #20 (answer the Q first).
