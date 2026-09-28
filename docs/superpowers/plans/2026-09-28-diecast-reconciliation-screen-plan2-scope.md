# Die Cast Shift Reconciliation -- the Ignition screen (Plan 2) -- SCOPE DRAFT

> **Status: scope draft, not a task plan.** It says which screens exist, what each is for, what it
> reads and writes, and what still has to be decided. It deliberately names no column and no
> parameter list, because **the SQL read contracts were still moving while this was written**
> (2026-09-28: `..._ListRejects` changed grain, and `..._GetHeader`, `..._ListShifts` and
> `..._Save` were all mid-change). Whoever writes the task-by-task plan binds to the contracts as
> they stand *after* the freeze, not to anything quoted here.
>
> **The screen build is gated on Plan 1 Task 15 passing** -- the full SQL suite green, the procs
> applied to `MPP_MES_Dev`, and the 2026-09-17 Machine 11 press sheet replayed on ProdSim with the
> numbers matching the paper. Until that gate is green the screen would be built against arithmetic
> nobody has proven.

**Seed:** `docs/superpowers/plans/2026-09-22-diecast-shift-reconciliation-sql.md` § "What Plan 2
covers (not this plan)".
**Design:** `docs/superpowers/specs/2026-09-21-diecast-shift-reconciliation-design.md` -- **§14
amendments win** wherever they disagree with §1-13. A13/A14/A15 are recent and material.
**Mockup:** `mockup/diecast_shift_reconciliation_mock.html` -- the intent for the screen, built on
real production data, statically wired. Treat it as the specification of *behaviour and wording*,
never of data shape.

---

## 1. Purpose and boundary

**Delivers.** The Perspective surface a team lead uses to reconcile **one past shift x press x die**
against its press sheet: pick the shift, see everything on record beside what the sheet says, re-file
entries that went to the wrong shift, add production that was never entered (including LTTs that
exist only on paper), close numeric gaps in either direction, and save it as one audited
reconciliation. Plus the Core named queries and the entity-script glue that feed it, the AD sign-in
that opens it, and the supervisor dashboard tile that says a shift still needs it.

**Does not deliver.**

- Any SQL. Every proc, function and worker is Plan 1's. If Plan 2 finds it needs a read that does
  not exist, that is an **amendment to Plan 1**, raised and built there -- not a query written into
  a named query or a calculation written into Python.
- Trim's equivalent screen (spec §10).
- The supervisor dashboard's own redesign -- only the one tile is added (spec §6.4).
- AD **role** gating. Any active AD-mapped user may reconcile until AD roles land (D8).
- Reject reports adopting the new approver column (spec §10).
- Changes to the live die cast entry / release screens. They are untouched; Plan 1's worker
  extraction is what keeps them behaving identically, and its regression suite is the evidence.

---

## 2. Constraints the screen inherits -- do not re-derive these

Stated as constraints because they are already settled and each one shapes a view.

1. **The landing list is one row per shift x press x die.** A die that ran and recorded nothing
   still appears. The list is therefore longer than "shifts with a problem" and needs its own
   visual hierarchy.
2. **The dashboard signal carries two distinct claims, and only one is a finding.** A real finding
   (production on record, no shift-end number ever entered) alerts; an **idle** shift (nothing
   recorded at all, and no shot total entered -- the owner's chosen discriminator, 2026-09-25) does
   not. The claim is on the row in the same vocabulary the landing list uses, so the screen can
   **group, count or suppress the two independently without a SQL change**. It must. Merging them
   into one number is explicitly forbidden.
3. **The move-target list can legitimately return fewer than four rows.** It is the closed shifts
   within two of this one; at the ends of history there are fewer. The popup must render whatever
   arrives -- never assume four, never pad, never pre-select.
4. **A shift label is a date fragment (mm-dd) plus the schedule's name.** It is not a time of day and
   must not be formatted, parsed or sorted as one. The shift's actual window is separate, and shift
   times are already Eastern (OI-38) while everything else converts at the read boundary. **Every
   timestamp on screen is Eastern.**
5. **Reject rows are grained by approver.** One defect code on one part approved by two people is
   two rows, each carrying only that person's quantity; an unapproved line is its own row. A
   per-defect total is **summed on the screen**, never read off one row. This grain changed on
   2026-09-25 precisely because the earlier one named the wrong person -- do not flatten it back.
6. **The typed column is Actual, never Sheet.** An **LTT** is the ticket number, a **LOT** is the
   record; "tag" and "basket" appear nowhere. A die is its **name first, then `Asset # <code>`**;
   the word "code" never reaches the operator.
7. **All named queries live in the Core project.** MPP has none of its own; MPP_Config carries one
   historical stray (`parts/OperationTemplate_List`) and that is not a precedent. Sibling projects
   cannot see each other's named queries.
8. **New views may be authored as files; existing views are edited in Designer.** This splits Plan 2
   in two and must be sequenced accordingly -- see §8.
9. **No business logic in Python.** Domain rules live in SQL. §9 carries the open question about
   where the screen's own arithmetic sits relative to that rule.
10. **The caller supplies `appUserId`.** No entity function resolves or defaults it; views pass
    `BlueRidge.Common.Session.currentAppUserId(self.session)`.

---

## 3. The views

Route `/shop-floor/die-cast/reconcile`, added to MPP's `page-config`. All new views live under the
**MPP** project (`BlueRidge/Views/ShopFloor/...`, `BlueRidge/Components/...`), all named queries and
scripts under **Core**.

### 3.1 `Views/ShopFloor/DieCastReconcile` -- the shell

**For:** owning the route, the AD gate, the app-header crumb, and which of the three phases is on
screen (landing / sheet / result). It holds the selected shift x press x die and nothing else.
**Opened by:** a team lead, from the supervisor dashboard tile or the die cast supervisor page.
**Reads:** nothing directly.
**Writes:** nothing.
**Pattern:** the existing shop-floor shell shape (`DieCastShared` -> `DieCastBody`). Elevation gate
at the door, the way `DieCastBody` gates the Die Mount popup.

### 3.2 `Components/PlantFloor/DieCastReconcileLanding` -- pick the shift

**For:** choosing a press, then a shift x die. **Nothing is pre-selected** -- the wrong-shift defect
this feature repairs came from a screen that preselected the current shift, and that is the single
most important behaviour on this view. An open shift is shown but not reconcilable.
**Opened by:** the shell, as the first phase; also the destination of the dashboard tile.
**Reads:** the landing list proc (per press) and the unreconciled/dashboard proc (plant-wide,
flagged-only mode -- see §6 and the open question in §9).
**Writes:** nothing.
**Pattern:** plain read-only list with a press selector; the `AuditBrowser` read-only-browser shape.

### 3.3 `Components/PlantFloor/DieCastReconcileSheet` -- the reconciliation

The screen. Layout A, sheet-shaped (D9): shift banner with die life before -> after, reason
(+ note when the reason demands one), **entries on record**, **shift totals** (Recorded | Actual |
Gap), **reject block**, **LOT list grouped by part** with the LTT entry bar, and a footer carrying
the blocking checks and Review & Save.

**For:** laying what is on record beside what the sheet says, field for field, and staging every
change until one Save.
**Opened by:** the shell, after a shift is chosen.
**Reads:** the header read (banner, recorded totals, die life, active-cavity count, the stale-guard
token), the entries read, the LOTs read, the rejects read, the reason code table, and the LTT
resolver -- called **as each LTT is typed or scanned**, never at save.
**Writes:** nothing until Save. Moves, added LTTs, typed Actuals and reject lines are all **staged
on screen** and undoable.
**Pattern:** the **per-section ownership** pattern (`project_mpp_item_master_pattern`) is the right
shape for a view this size -- each block (entries / totals / rejects / LOTs) an embedded view with
its own local state, reporting up by page-scoped message. But **the sections are not independent
here**: the totals block's arithmetic reads the reject block's sum and the LOT list's sum, so this
is per-section *ownership* with a single shared derived-state owner on the parent, not the
independent-save shape Item Master uses. There is one Save, not one per section. Whoever writes the
plan should decide the split explicitly rather than inherit it.

Non-negotiables this view will trip over, all already documented:

- Every `view.custom.*` a binding reads needs a **fully shaped default**, and the binding source
  must itself always return the full shape, including on the empty path.
- `load()` seeds `selected` and `editDraft` in **one property write**.
- Numeric inputs need `deferUpdates: false` -- the Save button reads what is typed, and an
  uncommitted field is an empty one.
- Table rows use `meta.visible` only where column alignment demands it; otherwise
  `position.display`.
- Every shop-floor screen in this project carries a **HowTo popup** and a header button that opens
  it; this one is not an exception.

### 3.4 `Components/Popups/DieCastReconcileMove` -- re-file an entry

**For:** moving one or more entries to the shift they belong to. Shows the entry's facts, **From**
and **To** as large shift names with each shift's good total, the explicit statement that shots,
pieces, LOTs and die life do not change, and the row count that moves. The confirm button names the
target shift.
**Opened by:** the sheet view.
**Reads:** the move-targets read.
**Writes:** nothing -- the choice is staged back to the sheet and written by the Save.

### 3.5 `Components/Popups/DieCastReconcileConfirm` -- what will change

**For:** the §7.5 confirmation. Full width, the shift in large type at the top, then **only the
groups that have content**, in plain sentences with numbers: entries moved, production added,
production reduced, new LOTs, LOT counts changed, counts left standing, die life. Anything that
**reduces** production, die life or a count is amber and needs its own tick box before the confirm
button enables; additions do not. The confirm button names the shift.
**Opened by:** the sheet view, once every blocking check passes.
**Reads:** see the open question in §9 -- today this content is arithmetic, and where it is computed
is undecided.
**Writes:** on confirm, the Save. This is the only write in Plan 2.

### 3.6 `Components/Popups/DieCastReconcileHowTo`

**For:** the project's standard how-to-read-this-screen popup. Reads and writes nothing.

### 3.7 `Views/ShopFloor/SupervisorDashboard` -- MODIFIED, Designer only

**For:** the "Shifts not reconciled" tile (§6). This is an **existing** view with existing tiles, so
it is a Designer edit, and that is what splits Plan 2's sequencing.

### 3.8 Reused, not rebuilt

`Common.Notify.toast` for every mutation result; `Popups/ConfirmUnsaved` for Discard with unsaved
work; `PlantFloor/ElevationModal` + `Common.Session.requireElevation` for the AD sign-in;
`PlantFloor/Numpad` and `PlantFloor/Keyboard` for touch entry (see the open question on which
terminal this runs on); `Common.Terminal` session context for the terminal the save is stamped with;
`Common.Session.currentAppUserId` for attribution.

---

## 4. Core named queries

One per read procedure the screen consumes, plus the Save. Named here by purpose; the plan binds
their parameters after the contract freeze. All under `ignition/projects/Core/ignition/named-query/`.

| Named query | Purpose |
|---|---|
| `workorder/DieCastShiftReconciliation_ListShifts` | the landing list for one press |
| `workorder/DieCastShift_ListUnreconciled` | the dashboard tile and its flagged drill-through, plant-wide, two claims |
| `workorder/DieCastShiftReconciliation_GetHeader` | the banner, the Recorded column, die life, the active-cavity count, the stale-guard token |
| `workorder/DieCastShiftReconciliation_ListEntries` | what is on record, grouped into entries, with the row ids a move acts on |
| `workorder/DieCastShiftReconciliation_ListLots` | the LOT list with each LOT's state and whether its count is locked |
| `workorder/DieCastShiftReconciliation_ListRejects` | the reject block's Recorded side (grained by approver -- sum on screen) |
| `workorder/DieCastShiftReconciliation_ListMoveTargets` | where an entry may move, with what each target already holds |
| `workorder/DieCastReconciliationReason_List` | the reason dropdown, carrying whether a note is required |
| `lots/DieCastLot_ResolveLtt` | what happens if this LTT is added -- called at the field, per LTT |
| `workorder/DieCastShiftReconciliation_Save` | the one write |

Reused where they fit rather than duplicated: `quality/DefectCode_List` for the reject reason
dropdown and `location/AppUser_List` for the approver picker -- **both need confirming** against
what the Save will accept (§9).

All of these, including the Save, are **status-row / result-set procs and take named-query
`type: Query`** -- `execNonQuery` / `UpdateQuery` is for silent procs and would swallow the Save's
status row.

---

## 5. Entity script / project library surface

One new module, in Core: `BlueRidge/Workorder/DieCastReconciliation`.

It is **thin glue and nothing else** -- one function per named query, each taking the ids the view
already holds and returning rows or the status dict. No domain decision, no threshold, no
transition, no defaulting of `appUserId`: the write function takes it from the caller and passes it
through `Common.Util.requireAppUserId`, which logs an ERROR naming the function when it is missing
so a missing user is a visible failure and never a change credited to someone else.

Two things that will want to live here and **should be argued before they do**: the blocking-check
arithmetic and the confirmation's change groups (§9). If either lands in Python it is domain logic
in Python, and the answer is a Plan 1 amendment, not a helper function.

One entry is added to `Common.Session`'s elevated-replay map (§6). That is a Core script edit on a
shared file -- small, but shared.

---

## 6. How the team lead gets in, and what it means for authorization

**A PIN is presence, never privilege.** Every shop-floor operator signs in with a PIN; a PIN grants
no authority at all, and nothing in this system reads a role off a PIN sign-in. This screen writes
production records, LOT counts and die life into Honda traceability for a shift that is already
closed. It is a protected action.

**So it takes an AD credential, per the existing per-action elevation path (D8).** The mechanism
already exists and is not being invented here:

- `Common.Session.requireElevation(session, code, label, params)` stashes the intent and opens
  `PlantFloor/ElevationModal`;
- on success the app header calls `beginElevatedWindow`, which **replaces the session user with the
  supervisor** and opens a rolling window;
- `dispatchElevatedAction` replays the stashed intent through an explicit code -> page-message map,
  so the requesting view's own handler re-runs with the window open.

Plan 2 adds **one gate at the door of the reconcile screen** and **one entry in that map**. Because
elevation replaces the session user, `currentAppUserId(session)` then returns the team lead, and
that is exactly the identity the Save is stamped with, the banner names, and the landing list shows
afterwards. No new auth surface, no new table, no role check -- **any active AD-mapped user**, which
is the shipping-label-reprint stance and stays that way until AD roles land.

Two consequences worth stating plainly:

- **The Save's approver field is a different axis from the sign-in.** The press sheet's QAS column
  names whoever approved the scrap, who is generally *not* the person reconciling, and the Save
  resolves it to an active application user. See §9.
- **The window is time-limited and the screen outlives it.** A reconciliation is a long, paper-in-
  hand task. §10 carries this as a risk.

---

## 7. The dashboard tile

One tile on the existing supervisor dashboard: **Shifts not reconciled** -- a count, amber when
non-zero, tapping through to the flagged list.

The count is the **alerting** claim only: production on record with no shift-end number ever
entered. The idle claim -- a die assigned across a whole closed shift with nothing recorded and no
shot total -- is reported by the same read but flagged not-alerting, because operators leave a die
assigned until the next is mounted, so it fires over every weekend and every prep window. **It must
never inflate the tile's number.**

The two stay distinguishable because the read puts the claim on each row in the same vocabulary the
landing list uses. The screen therefore filters, it does not re-derive: the tile counts rows of one
claim; the drill-through decides for itself whether to show the other, and if it does, it shows it
as its own separate, unhighlighted group with its own wording. Both come from the same single read,
so the tile's number and the list can never disagree.

---

## 8. Dependencies and sequencing

**Gates, in order. Nothing in Plan 2 starts before G1.**

- **G1 -- contract freeze.** Plan 1's reads and Save are committed and declared stable. As of writing
  they are not: the rejects read changed grain, and the header, landing and Save procs all changed
  on 2026-09-28. A named query built against a moving contract is silent rework.
- **G2 -- Task 15 passes.** Full suite green on a throwaway database with no new failures; the
  procs applied to `MPP_MES_Dev`; the 2026-09-17 Machine 11 press sheet replayed on a ProdSim copy
  of prod with the numbers matching the paper. **The screen build starts here.** The mockup is
  already proven against that sheet; the SQL has to be too before a screen is wrapped around it.
- **G3 -- procs live on `MPP_MES_Dev`.** Falls out of G2 step 2. Named queries cannot be smoke-
  tested against Dev until it is true.

**Then, inside Plan 2:**

1. **Named queries, serial, all in Core.** They share one folder tree and one gateway scan; parallel
   authoring of named queries and SQL has bitten this project before. One scan at the end, then
   verify each resolves -- a missing named-query file shows up as a screen that saves fine and
   never refreshes.
2. **Entity script**, once its named queries resolve.
3. **New views, file-authored**, then `scan.ps1`. These are new folders with no Designer cache, so
   they are safe to write as files -- and **only** because they are new. Disjoint new view folders
   may be authored in parallel; that is the one place parallelism is safe here.
4. **The route** in MPP's `page-config` -- a config file, not a view, so a file edit. It is shared
   with other sessions; stage it explicitly.
5. **The dashboard tile, in Designer.** `SupervisorDashboard` exists, so file-editing it risks the
   Designer-vs-disk reconciliation race. This is the last step and it is manual.
6. **Live smoke on the Dev gateway** with a real AD sign-in: every popup in §7 of the spec, a
   blocked save for each blocking check, and a reduction that needs its tick box.
7. **Release.** The full contract applies (`prod-release-context-pack/`): preview, rehearsal against
   live data, fingerprint-guarded execute, **scoped exports built from git and verified against
   HEAD** (Core first, then MPP), and a published runbook. Plan 1's SQL and Plan 2's resources ship
   in the same window -- the screen is useless without the procs and the procs are inert without the
   screen -- so the runbook covers both, and Plan 1's worker-extraction regression evidence rides
   with it.

**Working-tree discipline throughout:** the tree is shared with other sessions and carries hundreds
of unrelated modified files. Stage explicit paths; never `git add -u`, `-A` or `.`.

---

## 9. Open questions

These are raised, not answered. Each one changes what Plan 2 contains.

1. **Where does the die's cavity-and-part list come from?** The reject block needs a Part dropdown
   (All, or one part) and the LTT entry bar needs a Cavity picker on a multi-cavity die. The header
   read returns the active-cavity **count**, not the set; the LOT list only surfaces parts that
   already have LOTs -- which is **empty in exactly the case the entry bar exists for** (a shift
   with nothing recorded, the Machine 202 case). The Save resolves its cavity set *as of the shift*,
   and the header read was changed on 2026-09-28 to match it precisely so the two could not
   disagree. A third source resolved as-of-now would reintroduce that bug. **This looks like a
   missing read, and if it is, it belongs in Plan 1, not in a named query.**
2. **The QAS column.** The Save requires the approver to be an *active* application user. Do the
   quality inspectors who sign press sheets all have rows? What should the screen do with a sheet
   signed by someone who does not -- leave the line unapproved (the Save appears to allow it), or
   refuse? Picking by initials is what the spec says; the picker's source needs confirming.
3. **Where does the confirmation's arithmetic live?** The §7.5 groups -- which LOTs get corrected,
   which stand and why, die life before -> after, and which changes are reductions that trigger the
   tick box -- are the same computation the Save performs. Computing them on screen duplicates
   domain logic in Python, which the project forbids; computing them in SQL needs a preview read
   that Plan 1 did not build. A preview proc would also make the tick box a fact rather than a
   guess. **Which way?**
4. **Are the blocking checks the sanctioned exception?** The header read exposes the active-cavity
   count with the stated intent that *the screen* computes the total good it expects from it. That
   reads like a deliberate exception to "no business logic in Python" for the pre-save checks. Is
   it? If yes, say so once, in one place, so the next reader does not relitigate it. If no, it is
   the same answer as question 3.
5. **Which terminal does a team lead use?** The mockup assumes a keyboard and a wedge scanner, and
   the spec's LTT flow depends on the cursor staying in the field after each add. If this runs on a
   touch plant-floor terminal, every numeric field needs the `Numpad` and the LTT field needs the
   `Keyboard`, and that is a materially larger view.
6. **The tile's drill-through.** The dashboard read is plant-wide; the landing list is per press. So
   tapping the tile cannot simply "filter the landing list" -- either the landing grows a
   plant-wide flagged mode driven by the dashboard read, or the tile opens a separate list. Which?
   And does that list show the idle rows at all?
7. **What happens to a half-typed sheet?** Nothing persists a draft. An elevation expiry, a
   navigation, a reload, or a stale-guard refusal after somebody else writes to the same shift all
   discard a sheet that may represent twenty minutes of typing from paper. Is retyping acceptable,
   or does the screen need to preserve the typed Actuals across a reload?
8. **A die that changed mid-shift** is two landing rows and two reconciliations. Is doing them one
   after the other acceptable, or does the team lead expect one pass?

---

## 10. Risks specific to this screen

- **The elevation window can expire mid-sheet.** It is a rolling window; `Common.Session` has a
  `touchElevation` helper to push it forward, and **nothing in the project calls it today**.
  Perspective's own activity tracking does keep the window alive while the team lead is typing, but
  a team lead reading paper for five minutes without touching the screen is the normal shape of this
  task -- and the app header's idle poll resets the terminal when an *elevated* session goes idle,
  which navigates away. Combined with question 7, that is a plausible way to lose real work. Worth
  deciding before the view is built, not after a team lead reports it.
- **Arithmetic drift.** Whatever is not resolved by questions 3 and 4, the screen and the Save will
  both compute something. Any divergence shows up as a save that refuses a correctly entered press
  sheet, or a confirmation that promises something the Save does not do. The cavity-set change on
  2026-09-28 is exactly this failure caught once already.
- **The sheet view is large.** Many bound custom properties, nested paths, embedded sections and
  derived totals -- the shape that has produced most of this project's Perspective incidents. The
  pre-declare-every-bound-prop rule, the atomic-state-write rule and the input-commit rule all bite
  here, and none of them fails loudly.
- **Read contracts may still move.** They moved three times in the week before this was written, and
  the rejects grain change was a *result-set shape* change. A named query and a table binding both
  break silently on one. Hence G1.
- **Existing-view editing.** The dashboard tile is a Designer edit on a view other sessions may also
  be touching, in a shared working tree, at the end of a chain of file-authored work. It is the most
  likely place for a conflict, which is why it is last.
- **One release window, two halves.** The SQL half rewrites the live die cast write path. If the
  screen half slips, the SQL still has to ship or roll back as a unit, because a partly-deployed
  reconciliation is a screen that writes through procs that are not there.

---

## 11. Revision history

| Date | Change |
|---|---|
| 2026-09-28 | Initial scope draft, written while the Plan 1 read contracts were still changing. |
