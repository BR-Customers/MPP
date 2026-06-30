# Unknown-Initials Self-Registration — Design

**Date:** 2026-06-11
**Status:** Approved by Jacques (2026-06-11)
**Scope:** InitialsEntry not-found flow → two-popup self-registration of an Operator-class AppUser

## Problem

When an operator types unrecognised initials at `InitialsEntry`, the flow dead-ends at an error label. There is no path to add the operator without leaving the terminal for the Configuration Tool.

## Decisions (with Jacques, 2026-06-11)

- **Self-service** — anyone at the terminal can create an Operator-class user. Audit attribution = bootstrap/system user (AppUser Id=1), since nobody is authenticated at this screen.
- **Operator-only fields** — Initials + Display Name. No AD account, no Ignition role (that's the Operator class; AD users stay a Config-Tool task).
- **Auto-proceed** — on successful create, log the new operator in and navigate to the terminal's `defaultScreen`, same path `submitInitials` takes on success.

## What already exists (do NOT rebuild)

- SQL procs `Location.AppUser_Create` / `_Update` / `_Get` / `_List` / `_Deprecate` / `_GetByInitials` / `_GetByAdAccount`, with tests under `sql/tests/03_appuser/`. `AppUser_Create(@Initials, @DisplayName, @AdAccount=NULL, @IgnitionRole=NULL, @AppUserId)` → `{Status, Message, NewId}`; enforces unique Initials + the IgnitionRole-requires-AdAccount rule.
- The reusable `BlueRidge/Components/PlantFloor/Keyboard` component (messageName param).

## What's missing (build this)

### 1. Named query `location/AppUser_Create` (Core)

Thin `EXEC` wrapper, `type: "Query"` (status-row mutation procs need Query, not UpdateQuery). Params copied from the `DefectCode_Create` shape: `initials`(7), `displayName`(7), `adAccount`(7), `ignitionRole`(7), `appUserId`(3). `database: "MPP"`.

### 2. Entity script — `BlueRidge.Location.AppUser.create(data)` (Core code.py)

```python
def create(data):
    """Create a new AppUser. Returns {Status, Message, NewId}.
       appUserId defaults to 1 (bootstrap/system user) for unauthenticated
       shop-floor self-registration."""
    params = {
        "initials":     (data.get("initials") or "").strip().upper(),
        "displayName":  data.get("displayName"),
        "adAccount":    data.get("adAccount"),
        "ignitionRole": data.get("ignitionRole"),
        "appUserId":    data.get("appUserId") or 1,
    }
    return BlueRidge.Common.Db.execMutation("location/AppUser_Create", params)
```

### 3. Popup A — `BlueRidge/Components/Popups/UnknownInitials` (new, MPP)

`modal` style class shape (per ElevationModal). Params: `initials`, `replyMessage` (default `unknownInitialsResult`), `popupId` (default `mpp-unknown-initials`). Body: "Initials '<X>' not recognised." Footer: **Dismiss** (`pf-btn pf-btn-secondary`) → `{action:"dismiss"}`; **Register New User** (`pf-btn pf-btn-primary`) → `{action:"register"}`. Both send page-scoped reply + `closePopup(popupId)`.

### 4. Popup B — `BlueRidge/Components/Popups/RegisterOperator` (new, MPP)

`modal` shape, ~560×620. Params: `initials` (prefill), `replyMessage` (default `registerOperatorResult`), `popupId` (default `mpp-register-operator`).

Custom state: `editInitials`, `editDisplayName` (seeded from param), `focusedField` (default `"displayName"`), `error`.

Body:
- Initials field (`pf-field`) — text-field bidi to `view.custom.editInitials`, `textTransform: uppercase`. `dom.onFocus` sets `focusedField="initials"`. Highlight border when focused (expr on `props.style.border`).
- Display Name field — text-field bidi to `view.custom.editDisplayName`. `onFocus` sets `focusedField="displayName"`. Highlight when focused.
- Embedded `Keyboard` (`ia.display.view`, ~520×210) with `params.messageName: "registerKeyPressed"`.
- Error label (shows `view.custom.error`, `position.display` gated).

Message handler `registerKeyPressed` (pageScope) routes keypad to the focused field via customMethods on root:
- `key` → append `payload.key` to `editInitials` or `editDisplayName` per `focusedField`
- `clear` → clear the focused field
- `enter` → `saveOperator()`

`saveOperator()` customMethod:
```
res = BlueRidge.Location.AppUser.create({"initials": editInitials, "displayName": editDisplayName})
if res.Status: sendMessage(replyMessage, {"action":"registered", "initials":..., "appUserId":res.NewId, "displayName":...}, page); closePopup
else: self.view.custom.error = res.Message
```
Footer: **Cancel** → `{action:"cancel"}` + close; **Save** → `saveOperator()`.

### 5. InitialsEntry wiring (existing view, Designer-edit per boundary — see note)

- `submitInitials` not-found branch: instead of only setting `error`, open Popup A with `params.initials` = the typed initials. (`openPopup` scope `G`.)
- New root message handlers (all `pageScope: true`):
  - `unknownInitialsResult`: `action=="register"` → open Popup B (prefill initials); `action=="dismiss"` → `clearKeys()`.
  - `registerOperatorResult`: `action=="registered"` → set `session.custom.user` + `session.custom.appUserId` from payload, `navigate(terminal.defaultScreen or "/")`. (Factor the login-and-navigate into a `loginAs(appUserId, initials, displayName)` customMethod reused by `submitInitials`.)

## Conventions / gotchas honored

- New views (both popups) file-authored + `scan.ps1`. InitialsEntry is existing — its handler/script additions are small; **edit in Designer** per the view-edit boundary, OR full-file Write while the view is closed in Designer. Given Designer just rewrote it (unicode escapes present), do the InitialsEntry changes in Designer to avoid the reconciliation race; the two NEW popups are file-authored.
- `openPopup` / any `system.perspective.*` from a dom/component event → `scope: "G"`.
- Event/handler/customMethod script bodies start with `\t`.
- No toast host on shop-floor pages → registration success/failure surfaces **inline** in Popup B, not via toast.
- `messageName` per embedded Keyboard is unique (`registerKeyPressed`) so it can't collide with InitialsEntry's `initialsKeyPressed`.
- NQ lives in Core; gateway **restart** may be needed for the inherited NQ registry to pick up a brand-new NQ (scan alone can be insufficient for inherited-NQ visibility — per project memory).

## Error handling

- Duplicate initials / proc validation failure → `Status=0`, `Message` shown inline in Popup B; popup stays open.
- Blank fields → Save disabled (expr on `props.enabled`) until both Initials and Display Name are non-empty; proc remains authoritative.

## Testing

Manual: scan (restart gateway for the new NQ) → terminal → type unknown initials → Enter → Popup A → Register → Popup B (initials prefilled) → type a name on the on-screen keyboard → Save → confirm auto-login + navigate. Re-test duplicate initials (inline error), Dismiss path, Cancel path.
