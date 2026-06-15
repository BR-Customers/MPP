# MPP MES — Configuration Tool UI Testing Walk-through & Checklist

A guided, screen-by-screen pass over the Configuration Tool. It does two jobs at once:

1. **Walks you through the whole app** — each screen tells you how to reach it, what it's
   for, and what "looks right" before you start poking.
2. **Verifies every CRUD operation, every fallback (empty / null / not-found / invalid
   input), and every safety mechanism** (unsaved-changes gating, destructive confirms,
   validation guards, lifecycle rules, audit trail).

Work top to bottom — the order is a sensible tour of the app. Every screen has the **same
shape**: an orientation header, a **Standard checks** block (the always-true expectations,
spelled out so you don't have to remember them), then **CRUD**, **Fallbacks**, and **Safety**.

---

## How to use this checklist

**Set up a clean environment first.** You want known data and the freedom to create/deprecate
without fear:

1. `.\sql\scripts\Reset-DevDatabase.ps1` — rebuild `MPP_MES_Dev` from scratch.
2. Confirm the Gateway database connection to `MPP_MES_Dev` is *Valid*.
3. Open the **`MPP_Config`** project in a Perspective **session** (a browser tab at the
   project URL), **not** just the Designer — you're testing runtime behaviour.
4. Keep the Gateway **Logs** page open in another tab (Status → Diagnostics → Logs) so you
   can see a stack trace the moment something silently fails.

**Record a result for every `□` item:**

- ✅ **Pass** — behaves as described.
- ❌ **Fail** — log a bug (template below).
- ⏳ **Blocked** — can't test (missing seed data, needs PLC/AD, etc.) — say why.
- ➖ **N/A** — not present on this build.

**Bug report template** (one per ❌):

```
[BUG] <screen> — <short title>
Route:        /<route>
Steps:        1. … 2. … 3. …
Expected:     <what should happen>
Actual:       <what happened>
Severity:     Blocker / Major / Minor / Cosmetic
Evidence:     screenshot + (if relevant) Gateway log lines / Audit row
```

**Three reflexes when something looks off:**

- A button does nothing → check the Gateway **Logs** for a stack trace. A red component or "Component Error" banner = a binding failed.
- A save "succeeds" but nothing changes on screen → suspect a Named Query / proc issue; note it and move on, don't get stuck.

- Any create/update/deprecate → cross-check it landed an **Audit Log** row ([§11](#11-audit-log----audit-log-read-only)).

### The Standard checks — what the SC ids mean

Each screen below lists the ones that apply, as real checkboxes. This table is just the
definition so the per-screen lines can stay short.

| ID | Expectation |
|---|---|
| **SC-1** | **Loads clean** — no red "Component Error" banners, no Quality-Bad outlines, no literal `"null"` / `"None"` text anywhere. |
| **SC-2** | **Empty state** — with no matching data, lists show a sensible empty state, not a crash or endless spinner. |
| **SC-3** | **Refreshes** — after a create/edit/deprecate, the list/detail updates without a manual page reload. |
| **SC-4** | **Success toast** — every successful mutation raises a success toast (top-right, auto-dismiss ~8s). |
| **SC-5** | **Failure toast** — a rejected mutation raises an **error** toast carrying the proc's friendly message; error toasts persist until dismissed. |
| **SC-6** | **Audited** — every create/update/deprecate writes an `Audit.ConfigLog` row: readable `SUBJECT · CATEGORY · ACTION` + resolved-name Old/New values (`Location: {Id, Code, Name}`, not bare ids). |
| **SC-7** | **No log spam** — no unhandled exceptions in the Gateway log during normal use. |
| **SC-8** | **Navigable** — sidebar/header reaches the screen and back, active item highlights, the route deep-links directly. |

---

## 1. Home / Landing — `/`

> **Get here:** the project root URL. **What it is:** the entry hub — nav into every other
> screen. **Looks right:** tiles/links for each area, any counts reflect real dev data.

**Standard checks**

- □ Loads clean — no errors, no literal `null` (SC-1).
- □ Sidebar/nav reaches every screen and highlights the active one (SC-8).
- □ No exceptions in the Gateway log while navigating (SC-7).

**Behaviour**

- □ Every tile/link routes to the correct screen — no dead links.
- □ Any summary counts/cards reflect actual dev-DB data, not hardcoded numbers.

---

## 2. Plant Hierarchy — `/plant`

> **Get here:** sidebar → Plant (or `/plant`). **What it is:** the ISA-95 plant tree —
> create/edit/deprecate `Location` nodes and their attributes; manage location *kinds* via
> the Location Type Editor popup. **Looks right:** a tree you can expand, every node showing
> an icon, a detail/attributes panel on the right when a node is selected.

**Standard checks**

- □ Tree + detail load clean; node icons all resolve (no ⚠ broken-icon nodes) (SC-1).
- □ Selecting a node with no attributes shows an empty panel, not an error (SC-2).
- □ After create/edit/deprecate the tree refreshes (SC-3); success toast (SC-4); rejected action shows an error toast with the message (SC-5); each lands an Audit row (SC-6).
- □ No log spam; reachable + deep-links (SC-7, SC-8).

**CRUD**

- □ **Read** — tree loads the full hierarchy; expand/collapse works; selecting a node shows its detail + attributes.
- □ **Create** — `+ Add` injects a draft child under the selected parent; cascading **Type → Definition** dropdowns populate; Save creates it and it appears in the tree.
- □ **Update** — edit a node's name/code; Save persists; tree label updates.
- □ **Set attributes** — set/clear a `LocationAttribute` value; persists and re-reads.
- □ **Deprecate** — deprecate a node; it leaves the active tree; selection re-anchors to the parent (no stale-selection ⚠).

**Fallbacks**

- □ A node with a **null** optional field renders blank, not `"null"`.
- □ Cancelling `+ Add` without saving removes the draft node cleanly.

**Safety**

- □ **Unsaved gating** — with a dirty edit, switching nodes / closing raises **ConfirmUnsaved** (Save & Close / Discard & Close / Cancel); each button does what it says.
- □ **Destructive confirm** — Deprecate routes through a confirm dialog; Cancel aborts.
- □ **Duplicate code** — a node with an existing code is rejected (SC-5).
- □ **Parent rules** — the Definition dropdown only offers kinds valid under the chosen parent tier.
- □ **LocationType is read-only** — no UI to create/edit/delete the 5 ISA-95 tiers.

**Location Type Editor (popup from this screen)**

- □ **Create / Update / Deprecate** a `LocationTypeDefinition`; add/remove/edit its **attribute definition** rows.
- □ **SaveAll** persists the definition + all attribute-row changes atomically (one Save).
- □ Deprecating a definition **in use** by live locations is blocked or cascades per design — confirm it's not silent data loss.
- □ Unsaved gating on the popup's Close / X.

---

## 3. Item Master — `/items`

> **Get here:** sidebar → Items (or `/items`). **What it is:** the big compound editor — an
> item plus **6 sections**: Identity, Container Config, Routes (versioned), BOMs (versioned),
> Quality Specs (link), Eligibility. Each section saves independently. **Looks right:** an
> item list on the left; selecting one fills the section tabs. **Use demo item `5G0`**
> (fully configured) plus a fresh item you create.

**Standard checks**

- □ Selecting an item loads all six sections with no error banners / `null` text (SC-1).
- □ A **fresh** item with empty sections renders each tab cleanly (SC-2) — *watch for red borders / literal `null` on first paint; that's a real trap here.*
- □ Each section's Save refreshes its data (SC-3), toasts success (SC-4), surfaces proc errors as a toast (SC-5), and lands an Audit row (SC-6).
- □ No log spam; nav + deep-link (SC-7, SC-8).

**CRUD — Identity**

- □ **Create** a new item (AddItem popup): Part Number, Description, Item Type, UoM → appears in the list.
- □ **Read** — selecting loads all sections. **Update** identity fields; Save; re-read shows the change. **Deprecate** the item; it leaves the active list.

**CRUD — Container Config**

- □ Create / Update / Deprecate a container config for an item; persists.

**CRUD — Routes (versioned)**

- □ **Create** a route (Draft); add/edit/**reorder steps** with up/down arrows (no drag-drop); each step references an Operation Template.
- □ **SaveAll** (draft) persists steps atomically.
- □ **Publish** the draft → Published; **New Version** clones the selected version into a new Draft.
- □ **Deprecate** a version; **Discard Draft** removes an unsaved draft.

**CRUD — BOMs (versioned)**

- □ Create BOM (Draft); add/edit BOM **lines** (child item + qty + UoM); SaveDraft.
- □ Publish / New Version / Deprecate / Discard Draft all work.

**CRUD — Quality Specs (link)**

- □ "Go to spec →" cross-navigates to `/quality-specs` for the correct spec.

**CRUD — Eligibility**

- □ Add/remove location eligibility rows; **SaveAll** persists; set consumption metadata where applicable.

**Fallbacks**

- □ An item with **no published route/BOM** shows an appropriate empty / Draft-only state.
- □ Switching to an item with no Quality Spec shows an empty state, not an error.

**Safety**

- □ **Per-section dirty gating** — editing a field flips a `●` marker and reveals that section's Save/Discard.
- □ **Tab switch while dirty** raises ConfirmUnsaved (Save saves that section; Discard reverts; Cancel stays).
- □ **Item switch while dirty** raises ConfirmUnsaved.
- □ **No spurious dirty** — clicking between items/tabs *without* editing must **never** raise ConfirmUnsaved (deliberately click around fast to test this).
- □ **Lifecycle ≠ dirty** — Publish/Deprecate of a Route/BOM does not by itself flip the section-dirty flag; only unsaved Draft-line edits do.
- □ **Published is immutable** — you cannot edit a Published route/BOM version's lines in place.
- □ Required identity fields enforced; duplicate Part Number rejected (SC-5).

---

## 4. Operation Templates — `/parts/operation-templates`

> **Get here:** sidebar → Parts → Operation Templates. **What it is:** versioned operation
> templates plus a **Fields** editor (the data-collection fields an operation captures).
> **Looks right:** a template list, a version selector, a Fields panel.

**Standard checks**

- □ Loads clean (SC-1); template with no fields shows an empty Fields panel (SC-2); Save refreshes (SC-3) + toasts (SC-4/SC-5) + audits (SC-6); no log spam / navigable (SC-7/SC-8).

**CRUD**

- □ **Create** a template (NewOperationTemplate popup); **Update** header; **Deprecate**.
- □ **New Version** clones into a Draft; lifecycle (Publish where applicable) works.
- □ **Fields** — add a field (Data Collection Field dropdown), toggle **Required**, remove one; **SaveAll** persists; reactivating a previously-removed field works (no unique-constraint error).

**Fallbacks**

- □ Field dropdown with no available definitions shows an empty/disabled state, not a crash.

**Safety**

- □ Switching template / version while **Fields** is dirty raises ConfirmUnsaved.
- □ Required-toggle and remove only affect the draft until SaveAll; Discard reverts.
- □ Duplicate field assignment is prevented.

---

## 5. Tools — `/parts/tools`

> **Get here:** sidebar → Parts → Tools. **What it is:** the tool (die) master with 3 tabs —
> **Attributes**, **Cavities**, **Assignments** — plus the **Die Ranks** matrix.
> **Looks right:** a tool list, a header with status chip, the three tabs.

**Standard checks**

- □ Loads clean — no `"null"` rank pills, no `"null"` description (SC-1); empty assignment history on a never-mounted tool is fine (SC-2); mutations refresh (SC-3) + toast (SC-4/SC-5) + audit (SC-6); no log spam / navigable (SC-7/SC-8).

**CRUD — Tool**

- □ **Create** a tool (AddDie / add popup): code, name, type, optional description/rank.
- □ **Update** tool fields; Save persists.
- □ **Retire** (deprecate) — confirm it sets **status = Retired AND DeprecatedAt together** (chip must read *Retired*, not stay *Active*); tool leaves the active list.
- □ **Change status** via its control; persists + audits old→new status.

**CRUD — Attributes tab**

- □ Add an attribute (`+ Add` picks a Definition); the **value input matches the DataType** — String=text, Integer/Decimal=numeric, Boolean=checkbox, Date=date picker.
- □ Edit a value → `●` dirty + Save/Discard; **Save** persists + clears dirty; **Discard** reverts.
- □ `×` removes a row; on **Save** an absent row is **hard-deleted** (no soft-delete for attributes).
- □ `+ New definition` opens AddAttributeDefinition (creates a `ToolAttributeDefinition`).

**CRUD — Cavities tab**

- □ Add a cavity (defaults Active); set status via the inline dropdown; **Save**.
- □ **Empty save does NOT delete cavities** (insert+update only).
- □ **CavityNumber is read-only** on existing rows.
- □ A saved **Scrapped** cavity is locked/dimmed and cannot transition back out of Scrapped.

**CRUD — Assignments tab**

- □ **Mount** — inline cell dropdown lists **only compatible cells** (a Die tool → DieCastMachine cells only, not all ~146 cells/printers/terminals); Mount mounts immediately, toasts, banner + history update.
- □ **Release** an active assignment; banner clears.

**CRUD — Die Ranks (matrix popup)**

- □ Open the matrix; **Create / Edit / Deprecate** a rank (EditRank / DieRanks); cells reflect compatibility.

**Fallbacks**

- □ A tool with **no DieRank** hides the rank pill (no literal `"null"`).
- □ Saving a blank description stores NULL, and displays blank (not the string `"null"`).
- □ Each attribute value type renders correctly when null/empty.

**Safety**

- □ **Parent dirty-gating** — switching tools or tabs while Attributes/Cavities is dirty raises ConfirmUnsaved.
- □ **Assignments has NO dirty-gating** — mount/release are immediate/audited; switching away does **not** prompt ConfirmUnsaved.
- □ **DataType validation** — a non-numeric value in an Integer/Decimal attribute (or out-of-range) is rejected with a friendly message (SC-5); a Boolean left null must not crash.
- □ Retire confirm is a destructive-confirm dialog.

---

## 6. Quality Specs — `/quality-specs`

> **Get here:** sidebar → Quality → Quality Specs (or via Item Master "Go to spec →").
> **What it is:** a standalone versioned spec editor. **Lifecycle is date-resolved** —
> publishing does *not* auto-deprecate the prior version; effective-dating decides
> Active/Scheduled/Superseded. **Looks right:** a spec library on the left, a version
> dropdown + Version History, an attribute grid.

**Standard checks**

- □ Loads clean (SC-1); a spec with no published version shows a Draft-only/empty state (SC-2); save/publish refreshes the left list (SC-3) + toasts (SC-4/SC-5) + audits (SC-6); no log spam / navigable (SC-7/SC-8).

**CRUD**

- □ **Create** a spec (NewSpecModal): linked Item / Operation Template.
- □ **Add/edit attribute rows** — for **Numeric** attributes set UOM + Target/Lower/Upper; **SaveDraft**.
- □ **Publish** a draft (with an Effective From date); **New Version** clones the **selected** version into a new Draft.
- □ **Deprecate** a version; **Discard Draft** removes an unsaved draft.

**Fallbacks**

- □ **Non-Numeric** attributes hide the UOM / Target / Lower / Upper inputs (not empty numeric boxes).
- □ The spec library + Version History render legibly (no column squish, no em-dash mojibake, CreatedBy populated).

**Safety**

- □ **Range validation** — saving with `Lower ≤ Target ≤ Upper` violated is **rejected by the proc** with a clear message (SC-5).
- □ **Version state badges** — with two published versions (one effective now, one future-dated), the dropdown + Version History show **Active / Scheduled / Superseded** with the right colours.
- □ Published version is immutable (edits require New Version).
- □ Unsaved-draft gating on navigation away.

---

## 7. Downtime Codes — `/downtime-codes`

> **Get here:** sidebar → OEE → Downtime Codes. **What it is:** CRUD over
> `Oee.DowntimeReasonCode` (code + description + category/area + type). **Looks right:** a
> list/grid of codes, an add button, an editor popup.

**Standard checks**

- □ Loads clean (SC-1); empty/filtered-to-nothing shows empty state (SC-2); create/edit refreshes (SC-3) + toasts (SC-4/SC-5) + audits (SC-6); no log spam / navigable (SC-7/SC-8).

**CRUD**

- □ **Create** (DowntimeCodeEditor popup) / **Update** / **Deprecate** a downtime reason code.

**Fallbacks**

- □ Empty/long description renders cleanly; Type/Category dropdowns with an unassigned value don't show a confusing `"null"` label.

**Safety**

- □ Duplicate code rejected (SC-5); required fields enforced; deprecate destructive-confirm; unsaved gating on the popup.

---

## 8. Defect Codes — `/defect-codes`

> **Get here:** sidebar → Quality → Defect Codes. **What it is:** CRUD over
> `Quality.DefectCode`. **Looks right:** a list of defect codes + an editor popup.

**Standard checks**

- □ Loads clean (SC-1); empty state (SC-2); create/edit refreshes (SC-3) + toasts (SC-4/SC-5) + audits (SC-6); no log spam / navigable (SC-7/SC-8).

**CRUD**

- □ **Create** (DefectCodeEditor popup) / **Update** / **Deprecate** a defect code.

**Fallbacks**

- □ **First render of the editor** — text fields don't show red validation borders or literal `"null"` before you type.

**Safety**

- □ Duplicate code rejected; required fields enforced (Save disabled/rejected when incomplete); deprecate destructive-confirm; unsaved gating on the popup.

---

## 9. Audit Log — `/audit-log` (read-only)

> **Get here:** sidebar → Audit → Audit Log. **What it is:** the read-only browser over
> `Audit.ConfigLog` — your verification tool for SC-6 everywhere else. **Looks right:** a
> filterable table of recent config changes, clickable rows.

**Standard checks (read-only — no mutation checks apply)**

- □ Loads clean (SC-1); a filter matching nothing shows an empty state, not an error (SC-2); no log spam / navigable (SC-7/SC-8).

**Read / Behaviour**

- □ Loads recent rows with a **TOP 1000 cap** + a total-count indicator.
- □ **Filters** (Apply / Reset) work: entity type, date range, user, text search.
- □ **Row click** opens **ConfigChangeDetail** showing a readable diff (green add / red remove / yellow change) + full Old/New JSON below.
- □ **Timestamps display in Eastern time** (UTC→ET) and read correctly.
- □ Tile-stat rows are clickable and apply a filter.
- □ **Read-only** — no create/edit/delete affordances anywhere.

---

## 10. Failure Log — `/failure-log` (read-only)

> **Get here:** sidebar → Audit → Failure Log. **What it is:** the read-only browser over
> `Audit.FailureLog` — where rejected operations land. **Looks right:** a filterable table
> of failures, clickable rows.

**Standard checks (read-only)**

- □ Loads clean (SC-1); empty filter result is clean (SC-2); no log spam / navigable (SC-7/SC-8).

**Read / Behaviour**

- □ Loads rows (TOP cap + total count); filters (Apply / Reset) work.
- □ **Row click** opens **FailureDetail** with the full error context / stack.
- □ Timestamps in ET; **read-only**.
- □ **Cross-check:** trigger a deliberate failure elsewhere (submit a duplicate code) and confirm a matching `FailureLog` row shows up here.

---

## 11. Reference-data / sub-entity editors

These back the dropdowns on the screens above. Test wherever each is surfaced (popup or
inline). For each, run the full set: **Create / Update / Deprecate + duplicate-code rejection
+ unsaved gating + Audit row (SC-6)**:

- □ **Unit of Measure** (`Parts.Uom`)
- □ **Item Type** (`Parts.ItemType`)
- □ **Data Collection Field** (`Parts.DataCollectionField`) — feeds Operation Template fields.
- □ **Tool Attribute Definition** (`Tools.ToolAttributeDefinition`) — via AddAttributeDefinition.
- □ **Location Attribute Definition** (`Location.LocationAttributeDefinition`) — via the Location Type Editor.
- □ **Die Rank** (`Tools.DieRank`) — via the Die Ranks matrix.
- □ **Shift Schedule** (`Oee.ShiftSchedule`) — *if surfaced in the UI; if no screen exists, mark ➖ and note it.*

> **Cross-entity safety:** after deprecating a reference value that's **in use** (e.g. a UoM
> on live items), confirm the app blocks it with a clear message or handles it gracefully —
> never a silent failure or an orphaned reference rendering as `"null"`.

---

## 12. Cross-cutting safety regression sweep

Targeted re-tests of the traps this project has actually hit. Run these last, fast:

- □ **No spurious ConfirmUnsaved** — rapidly click between items/tabs on Item Master and Tools *without editing*; the popup must never appear.
- □ **Dirty flag clears after Save** — save a section, navigate away; no ConfirmUnsaved.
- □ **Discard fully reverts** — edit several fields, Discard, confirm every field returns to its saved value.
- □ **Cancel keeps your edits** — Cancel on ConfirmUnsaved loses nothing and saves nothing.
- □ **Toast queue** — fire several toasts fast; max ~5 stack, FIFO, errors persist.
- □ **Empty-result everywhere** — every list/detail handles "no data" without a red banner.
- □ **Null everywhere** — no screen renders the literal text `null` / `None` in any field, chip, pill, or label.
- □ **Every mutation is audited** — spot-check that each Create/Update/Deprecate you ran produced a matching Audit Log row with resolved names.

---

## 13. (Environment-dependent) Plant-floor — project `MPP`

The Arc 2 plant-floor views are **built but not yet smoke-tested**, and several depend on
infrastructure the dev laptop won't have (terminal-IP resolution, the AD Identity Provider,
PLC handshakes). Switch to the **`MPP`** project session. Test what's reachable; mark the
rest ⏳ with the dependency.

- □ **Terminal Selector** (`/shop-floor/terminal-selector`) — table loads terminals; row select works; selection persists.
- □ **Initials Entry** (`/shop-floor/initials`) — A–Z keypad enters initials; validation on empty/invalid.
- □ **Home Router** (`/`) — gates terminal → presence → default screen in the right order.
- □ **Elevation Modal** — renders (incl. `password-field`); ⏳ **AD validation is default-deny until the IdP is wired** — expect denial, not success; confirm the denial is graceful.
- □ **Idle re-confirm** — the 30-min presence re-confirm modal fires (timing — may be ⏳).

---

## Sign-off summary

| Screen | CRUD | Fallbacks | Safety | Notes / bug count |
|---|---|---|---|---|
| 1. Home / Landing | | | | |
| 2. Plant Hierarchy | | | | |
| 3. Item Master | | | | |
| 4. Operation Templates | | | | |
| 5. Tools | | | | |
| 6. Quality Specs | | | | |
| 7. Downtime Codes | | | | |
| 8. Defect Codes | | | | |
| 9. Audit Log | | | | |
| 10. Failure Log | | | | |
| 11. Reference data | | | | |
| 12. Regression sweep | | | | |
| 13. Plant-floor (env-dep.) | | | | |

**Tester:** ________________  **Build / commit:** ________________  **Date:** ____________

Mark each cell ✅ / ❌(n) / ⏳ / ➖. Attach the bug list. Anything ❌ Blocker or Major
should be raised before merge to `main`.
