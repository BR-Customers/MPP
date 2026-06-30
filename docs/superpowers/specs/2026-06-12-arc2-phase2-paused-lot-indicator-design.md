# Arc 2 Phase 2 — Paused-LOT Indicator (Ignition) — Design

**Date:** 2026-06-12
**Status:** Draft for review
**Scope:** The **Paused-LOT Indicator** — a reusable badge component (embedded in every Cell workstation header) plus its detail-list popup and resume action. Fourth of the four deferred Phase 2 views. The most fully Phase-2-backed of the four, and the only one with a **mutation** (resume).

## 1. Source of truth

- FDS-05-038 / OI-21 (FDS §5, "Operator UX — Paused-LOT indicator"): every workstation screen at a Cell surfaces an indicator showing the count of currently-open pauses at that Cell; tapping opens a list (`LotName`, Part, `PausedAt`, `PausedByUserId`); selecting + confirming invokes resume, transitioning the operator's active context to the resumed LOT. Resume may be by a different operator than the one who paused.
- Mockup: `span.pf-paused-indicator` (`⏸ Paused [count]`) present in every terminal header (`mockup/plantFloor.html`, e.g. Die Cast / Machining / Trim headers).

## 2. Reconciliation to Phase 2 SQL — fully backed

All three procs shipped in migration `0021`:
- `Lots.LotPause_GetCountsByLocation @LocationId` → `(LocationId, OpenPauseCount)` — the badge value.
- `Lots.LotPause_GetByLocation @LocationId` → `(PauseEventId, LotId, LotName, ItemId, ItemCode, PausedAt, PausedByUserId, PausedReason)` — the detail list.
- `Lots.LotPause_Resume @PauseEventId, @ResumedRemarks=NULL, @AppUserId` → status row `(Status, Message)` — the resume mutation.

They have **no Named Queries yet** — that is the bulk of this view's plumbing. No new SQL proc needed.

**One deferral:** FDS says resume "transitions the operator's active context to the resumed LOT." The operator **work screens don't exist yet** (Phase 3+). So this push: resume closes the pause, toasts, and refreshes the badge + list. The active-context handoff is a TODO the consuming work screen wires when it's built; the indicator emits a page-scoped `pausedLotResumed` message with the resumed `LotId` for that future consumer.

## 3. Components

This is a **component + popup**, not a page:

- **`BlueRidge/Components/PlantFloor/PausedLotIndicator`** — the embeddable badge. Param `locationId` (BIGINT, input). Binds its count to `LotPause.getCountByLocation(locationId)`; renders `⏸ Paused N`; hidden or dimmed when count is 0 (per FDS the indicator is always present — show "0"). `onClick` opens the detail popup (scope `"G"` per `feedback_ignition_popup_open_scope`), passing `locationId`.
- **`BlueRidge/Components/Popups/PausedLotList`** — the detail list popup. Param `locationId`. Loads `LotPause.getByLocation(locationId)` into a repeater; each row shows `LotName · ItemCode · PausedAt · PausedBy` with a **Resume** button. Resume → `LotPause.resume(pauseEventId)` → `notifyResult` toast → on success, refresh the list + emit page-scoped `pausedLotResumed {lotId}`; close popup when the list empties (or keep open for multi-resume — decide at build; default: keep open, refresh).
- **Consumption:** future Cell work screens embed `PausedLotIndicator` in their header with `locationId` = the terminal's context Cell (`session.custom.cell.*` from the Phase 1 terminal-context work). For this push, demo via a small scratch page (`/shop-floor/paused-demo`) that embeds the indicator with a picked Cell, so it's smoke-testable before any work screen exists.

## 4. Data contract

New `BlueRidge.Lots.LotPause` entity module (sibling of `Lots.Lot`):

| Element | Proc (shipped) | NQ (Core, new) | Entity method |
|---|---|---|---|
| Badge count | `LotPause_GetCountsByLocation` | `lots/LotPause_GetCountsByLocation` (param `locationId` s3) | `LotPause.getCountByLocation(locationId)` → dict |
| Detail list | `LotPause_GetByLocation` | `lots/LotPause_GetByLocation` (param `locationId` s3) | `LotPause.getByLocation(locationId)` → list[dict] |
| Resume | `LotPause_Resume` | `lots/LotPause_Resume` (params `pauseEventId` s3, `resumedRemarks` s7, `appUserId` s3) — **`type:"Query"`** (status-row mutation per `feedback_ignition_nq_type_for_status_row_procs`) | `LotPause.resume(pauseEventId, resumedRemarks=None, appUserId=None)` → `{Status, Message}` via `execMutation`; `appUserId` defaults to `Common.Util._currentAppUserId()` |

## 5. View/Component conventions

- Resume is the only mutation → routes through `Common.Ui.notifyResult`; no `editDraft` (no form). Reads are `execList`/`execOne`.
- Badge count binding: pre-declare the count custom prop with a shaped default (`{"OpenPauseCount": 0}`); the read returns the shaped dict even when 0.
- Popup open from a dom event uses `scope:"G"`; the resume reply / `pausedLotResumed` use page-scoped messages (`pageScope:true`).
- Indicator badge styling mirrors `.pf-paused-indicator` from the mockup (amber pill, count chip).

## 6. Done when

- `LotPause` entity module + three NQs (counts/list/resume) added and scanned.
- `PausedLotIndicator` + `PausedLotList` built; a scratch demo page embeds the indicator for a chosen Cell.
- Designer smoke: pause two LOTs at a Cell → badge shows 2; open popup → both listed oldest-first; Resume one → toast, list drops to 1, badge updates to 1; resuming as a different operator records the resumer.

## 7. Out of scope

The active-context handoff into a work screen (Phase 3+ — the indicator just emits `pausedLotResumed`). Placing pauses (already handled by `LotPause_Place` from the work screens, not this component). Other Phase 2 views — separate specs.
