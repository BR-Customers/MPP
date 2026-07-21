# Downtime Increment 3 — Downtime Manager Popup — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A terminal-scoped, fully-audited Downtime Manager popup (opened from the App Header) that lists downtime events for the operator's scope + shift and supports full CRUD: start/stop live, edit reason+remarks, edit start/end times, add a fully-past event, void.

**Architecture:** A popup `Components/Popups/DowntimeManager` + a repeater row `Components/PlantFloor/DowntimeManager/EventRow` + an editor sub-popup `Components/Popups/DowntimeEditor`. All read/write via the Inc-1 `BlueRidge.Oee.Downtime` module. Scope resolves from `session.custom.cell.locationId`. No SQL (Inc 1 owns it).

**Tech Stack:** Ignition 8.3 Perspective, Jython, `scan.ps1`.

## Global Constraints & hard-won lessons (apply throughout)
- New views → author as files + `.\scan.ps1`.
- **NEVER pass a list into a `runScript` expression arg** — it arrives as a Java `QualifiedValue[]` that `_u` doesn't unwrap. Pass scalars; iterate lists only in Python/transforms (`feedback_ignition_runscript_list_arg_qv_array`).
- **`ia.input.date-time-input` `props.value` is a `java.util.Date`, not millis.** Bind bidi to a Date; on save `system.date.format(dateVal, "yyyy-MM-dd HH:mm:ss")` to an **ET wall-clock string** and pass as a STRING param (the proc converts ET→UTC). This sidesteps the TZ trap (mirrors the Shift-editor date fix).
- Selected/active fill must use a **defined** accent (`--mpp-accent-50` etc.); bare `--mpp-accent` is undefined → transparent (`project_mpp_core_stylesheet_canonical`).
- Cross embed/popup boundaries with **page-scoped** messages (`feedback_ignition_message_scope`); `system.perspective.*` from events uses `scope:"G"`; event bodies start with a tab.
- Editor `editDraft` custom prop: pre-seed the **full shape** (every bound key); reseed in **one** atomic property write (`feedback_ignition_bidi_nested_path_init`, Item-Master atomic-state rule).
- Toasts via `BlueRidge.Common.Ui.notifyResult` / `Common.Notify.toast`. Commit to `jacques/working`, explicit paths.

## Inc-1 contract this plan consumes (confirm these when Inc 1 is built)
`BlueRidge.Oee.Downtime`: `resolveScope(cellId)→scopeId`; `getByScope(scopeId, includeDescendants, shiftId)→list[dict]` with keys `DowntimeEventId, LocationCode, ReasonCode, ReasonDescription, DowntimeReasonCodeId, SourceCode, StartedAtEt, EndedAtEt, DurationMinutes, Remarks, OperatorInitials, IsOpen, IsVoided, VoidReason`; `updateReason(id, reasonId)`; `updateTimes(id, startedAtEtStr, endedAtEtStr, remarks)`; `recordHistorical(scopeId, startedAtEtStr, endedAtEtStr, reasonId, remarks)`; `void(id, reason)`. Plus existing `BlueRidge.Oee.DowntimeEvent.start(scopeId, downtimeReasonCodeId=)` / `.end(id)`.
> **Two Inc-1 refinements required for this UI** (fold into Inc-1 before/at build): (a) `UpdateTimes`/`RecordHistorical` ET datetime NQ params are **strings** (`sqlType 7`, `'yyyy-MM-dd HH:mm:ss'`), not sqlType 8; (b) `UpdateTimes` also accepts an optional `@Remarks` so "edit times + remarks" is one call.

## Reference (read first)
- `Views/ShopFloor/DowntimeEntry/view.json` + `Components/PlantFloor/DowntimeEntry/EventRow/view.json` (current start/end/assign UI, page-scoped row messages)
- `Components/Popups/ShiftScheduleEditor/view.json` (editor chrome, editDraft/selected, date-time-input, notifyResult/refresh pattern, the accent + date lessons already applied)
- `oee/DowntimeReasonCode.search` (reason dropdown source)

---

## Task 1: `DowntimeManager/EventRow` component

**Files:** Create `ignition/projects/MPP/.../views/BlueRidge/Components/PlantFloor/DowntimeManager/EventRow/{view.json,resource.json}`

**Interfaces — Consumes:** scalar input params (one event, shaped by the list transform). **Produces:** page-scoped messages `dtEndRequested` / `dtEditRequested` / `dtVoidRequested` with `{downtimeEventId}`.

- [ ] **Step 1: Author the row** — mirror `DowntimeEntry/EventRow`. Input params (all `paramDirection:"input"`): `downtimeEventId, startedAt, endedAt, durationMinutes, reasonLabel, sourceCode, remarks, initials, isOpen(bool), isVoided(bool)`. Layout (flex row): time range (`startedAt` → `endedAt` or "— open —"), duration, reason, source, initials, a **status chip** (Open = accent-50 fill / Closed = neutral / Voided = struck + dim via `opacity` binding on `isVoided`), then action buttons:
  - **End** (`meta.visible` = `{...isOpen} && !{...isVoided}`) → `sendMessage("dtEndRequested", {"downtimeEventId": self.view.params.downtimeEventId}, scope="page")`
  - **Edit** (`meta.visible` = `!{...isVoided}`) → `sendMessage("dtEditRequested", {...})`
  - **Void** (`meta.visible` = `!{...isVoided}`) → `sendMessage("dtVoidRequested", {...})`
  Each event-body tab-prefixed, `scope:"G"`.

- [ ] **Step 2:** resource.json (scope G, `files:["view.json"]`), validate JSON + AST scripts, `.\scan.ps1`.
- [ ] **Step 3: Commit** `git add .../DowntimeManager/EventRow && git commit -m "feat(plantfloor): DowntimeManager EventRow"`

---

## Task 2: `DowntimeManager` popup

**Files:** Create `ignition/projects/MPP/.../views/BlueRidge/Components/Popups/DowntimeManager/{view.json,resource.json}`

**Interfaces — Consumes:** `Downtime.resolveScope/getByScope`, `Shift.getOpen/list`; EventRow messages. **Produces:** opens `DowntimeEditor`; page-scoped `downtimeManagerRefresh`.

- [ ] **Step 1: custom state + bindings**
  - `custom.scopeLocationId` ← expr `runScript("BlueRidge.Oee.Downtime.resolveScope", 0, {session.custom.cell.locationId})` (scalar).
  - `custom.shiftId` (default null = current), `custom.shiftOptions` ← `runScript("BlueRidge.Oee.Shift.list", 0)` transform → `[{value:Id,label:ScheduleName+" "+ActualStart}]` (+ a "Current shift" option value null).
  - `custom.rows` ← expr `runScript("BlueRidge.Oee.Downtime.getByScope", 0, {view.custom.scopeLocationId}, true, {view.custom.shiftId})`.
  All shaped-default per pre-declare rule.

- [ ] **Step 2: layout** — modal (mirror ShiftScheduleEditor chrome): header (title "Downtime — <scope label>" + shift dropdown + close), body = table header + flex-repeater over `custom.rows` → `EventRow` (transform maps getByScope keys → row params incl. `reasonLabel = ReasonCode + " - " + ReasonDescription` or "(unassigned)", `startedAt=StartedAtEt` string, etc.), footer = **Start Downtime** + **Add Past Event** buttons.
  - Start Downtime (tab, G): `\tsid=self.view.custom.scopeLocationId\n\tif sid is None: return\n\tr=BlueRidge.Oee.DowntimeEvent.start(sid)\n\tBlueRidge.Common.Ui.notifyResult(r,"Downtime started")\n\tself.view.custom.shiftId=self.view.custom.shiftId` (poke refresh) — actually refresh via re-reading: set `self.refreshBinding("view.custom.rows")` won't work in handler; instead direct re-read: `self.view.custom.rows = BlueRidge.Oee.Downtime.getByScope(sid, True, self.view.custom.shiftId)` (`feedback_ignition_refresh_binding_noop`).
  - Add Past Event (tab, G): `\tsystem.perspective.openPopup(id="mpp-downtime-editor", view="BlueRidge/Components/Popups/DowntimeEditor", modal=True, showCloseIcon=False, params={"mode":"create","editId":None,"scopeLocationId":self.view.custom.scopeLocationId})`

- [ ] **Step 3: messageHandlers** (root, pageScope true) — direct re-read after each (per refreshBinding-noop):
  - `dtEndRequested`: `\tBlueRidge.Oee.DowntimeEvent.end(payload["downtimeEventId"])\n\tself.refreshRows()`
  - `dtVoidRequested`: open a confirm (reuse `ConfirmUnsaved`? no — a small reason prompt) OR directly `\tBlueRidge.Oee.Downtime.void(payload["downtimeEventId"])\n\tself.refreshRows()` (v1: void with no reason; a reason prompt can be a follow-up).
  - `dtEditRequested`: `\tsystem.perspective.openPopup(id="mpp-downtime-editor", view="BlueRidge/Components/Popups/DowntimeEditor", modal=True, showCloseIcon=False, params={"mode":"update","editId":payload["downtimeEventId"],"scopeLocationId":self.view.custom.scopeLocationId})`
  - `downtimeManagerRefresh`: `\tself.refreshRows()`
  - customMethod `refreshRows()`: `\tself.view.custom.rows = BlueRidge.Oee.Downtime.getByScope(self.view.custom.scopeLocationId, True, self.view.custom.shiftId)`
  - shift dropdown `onActionPerformed`: set `self.view.custom.shiftId = self.props.value` then `self.view.rootContainer.refreshRows()`.

- [ ] **Step 4:** resource.json, validate JSON + AST, `.\scan.ps1`, commit.
```bash
git add ignition/projects/MPP/com.inductiveautomation.perspective/views/BlueRidge/Components/Popups/DowntimeManager
git commit -m "feat(plantfloor): DowntimeManager popup (scope+shift list, start/void/end, row actions)"
```

---

## Task 3: `DowntimeEditor` sub-popup (edit + add-past)

**Files:** Create `ignition/projects/MPP/.../views/BlueRidge/Components/Popups/DowntimeEditor/{view.json,resource.json}`

**Interfaces — Consumes:** `Downtime.getByScope`(one)/`updateReason`/`updateTimes`/`recordHistorical`; `DowntimeReasonCode.search`. Params `{mode:"create"|"update", editId, scopeLocationId}`. **Produces:** page-scoped `downtimeManagerRefresh`.

- [ ] **Step 1: editDraft shape (full, pre-seeded)** — `{id, reasonCodeId, startVal(Date|None), endVal(Date|None), remarks}`. `selected` mirror for dirty. On `params.editId.onChange` (update mode): load the event (a small `Downtime.getOneById` helper OR filter `getByScope`), map `StartedAtEt/EndedAtEt` strings → Dates via `system.date.parse(s,"yyyy-MM-dd HH:mm:ss")`, atomic single write.

- [ ] **Step 2: fields** — Reason dropdown (`DowntimeReasonCode.search` options, bidi `editDraft.reasonCodeId`), **Start** `ia.input.date-time-input` (`pickerType:"datetime"`, `format:"YYYY-MM-DD HH:mm"`, bidi `editDraft.startVal`), **End** same (`editDraft.endVal`; optional in update mode if event still open), **Remarks** text-field.

- [ ] **Step 3: Save (customMethod `doSave`, tab-bodied)** — read editDraft via `extractQualifiedValues(self.view.custom.editDraft)`; validate: start present; if end present `end>start`; format Dates → ET strings `system.date.format(v,"yyyy-MM-dd HH:mm:ss")`.
  - `mode=="create"` → `BlueRidge.Oee.Downtime.recordHistorical(scopeLocationId, startStr, endStr, reasonCodeId, remarks)`; require end.
  - `mode=="update"` → `BlueRidge.Oee.Downtime.updateReason(editId, reasonCodeId)` then `BlueRidge.Oee.Downtime.updateTimes(editId, startStr, endStr, remarks)`.
  - `notifyResult`; on success `sendMessage("downtimeManagerRefresh", scope="page")` + `closePopup("mpp-downtime-editor")`.
  Save button → `self.view.rootContainer.doSave()`; Cancel → dirty-check `handleClose` (ConfirmUnsaved pattern, id `mpp-downtime-editor`).

- [ ] **Step 4:** resource.json, validate JSON + all embedded scripts (AST), `.\scan.ps1`, commit.
```bash
git add ignition/projects/MPP/com.inductiveautomation.perspective/views/BlueRidge/Components/Popups/DowntimeEditor
git commit -m "feat(plantfloor): DowntimeEditor popup (edit reason/times/remarks, add-past)"
```

---

## Task 4: End-to-end verification

- [ ] **Step 1: In the plant-floor app** (`/shop-floor/...`, a screen with a cell set — e.g. Mach IN sets cell 76): click the header **Downtime** button. Verify:
  - List shows the scope's events for the current shift; scope label reflects the **line** (M&A) — confirm it's the line, not the raw cell.
  - **Start Downtime** → open event appears + header "LINE DOWN" pill lights.
  - **Edit** an event → change reason + shift start time back 15 min → saves; list reflects new duration.
  - **Add Past Event** (yesterday 09:00–09:20) → appears (switch shift selector to that shift if needed).
  - **End** an open event; **Void** an event → shows struck/dim, `IsVoided`.
- [ ] **Step 2: Audit check** — `SELECT TOP 12 el.*, let.Code FROM Audit.OperationLog el JOIN Audit.LogEventType let ON let.Id=el.LogEventTypeId WHERE let.Code LIKE 'Downtime%' ORDER BY el.Id DESC;` → a row per action (Started/Ended/ReasonChanged/TimesEdited/RecordedHistorical/Voided) with resolved Old/New.
- [ ] **Step 3: Die-cast scope check** — on a die-cast screen with a selected press, open the popup; confirm scope = the **press** (not a line), events list/CRUD against the press.
- [ ] **Step 4: Commit** any fixes found; final `git commit` if needed.

---

## Self-Review
- EventRow (Task 1), Manager list+shift+start/end/void (Task 2), Editor edit/add-past (Task 3), E2E incl. scope + audit + die-cast (Task 4) — spec §4 covered. ✅
- All mutations audited (Inc 1), initials-attributed, no elevation gate. ✅
- Lessons pre-applied: no list-in-runScript, date-time-input Date→ET-string, defined accent, page-scoped messages, atomic editDraft, refreshBinding-noop direct re-read. ✅
- Inc-1 refinements (string datetime params, `@Remarks` on UpdateTimes, a `getOneById` or reuse) flagged as dependencies to reconcile when Inc 1 is built.
