# Hold Management Redesign Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Wire a working place/release-hold experience onto LOT Detail and replace the single-scroll Hold Management view with a tabbed master-detail layout, both driven by one reusable `HoldPanel` component.

**Architecture:** Build one embeddable Perspective component (`Quality/HoldPanel`) that resolves a LOT-or-container target, shows a place form when un-held and a release form when held, and calls the existing tested `BlueRidge.Quality.Hold` wrappers. Both hosts drive the panel via a page-scoped `holdPanelLoad` message and react to the panel's `holdChanged` message. No SQL schema or proc-behavior changes — only a display-only column added to two read procs plus one thin Python wrapper.

**Tech Stack:** Ignition 8.3 Perspective (file-based views), Jython gateway/entity scripts, SQL Server 2022 stored procedures, `scan.ps1` gateway sync.

## Global Constraints

- Branch: **`jacques/working`**. Commit there, never `main`. Confirm branch before first commit.
- Git staging: **explicit paths only** — never `git add -A`/`-u`. Omit `Co-Authored-By: Claude` trailer.
- After every new/changed Ignition resource: run `.\scan.ps1` (local sync only; never `pull.ps1` / `C:\MPP`).
- **No business logic in Python/bindings** — the component only orchestrates UI; every DB touch routes through `BlueRidge.Quality.Hold.*` / `BlueRidge.Lots.Lot.*` wrappers.
- **No `OUTPUT` params** in procs; read procs return a result set, empty = not found (FDS-11-011).
- Displayed timestamps are **ET** — read procs already `CAST(... AT TIME ZONE 'UTC' AT TIME ZONE 'Eastern Standard Time' ...)`.
- Seed/string values **ASCII-only** (byte-scan before applying).
- **Embed params are input-only** — parent→child propagates, child→parent does NOT; cross the boundary with page-scoped messages.
- **Every bound `view.custom.*` prop needs a fully-shaped default**; binding sources must return the shaped-empty object on the not-found path (never `None`/`{}`).
- `onStartup` lives in `events.system`, not `events.component` (never fires there).
- Event-script bodies start with a leading `\t` (Designer wraps them in `def runAction(self, event):`).
- Prefer `position.display` binding over `meta.visible` to show/hide flex children (except tabular rows).
- New views need BOTH `view.json` and `resource.json` (scope `"G"`, `files:["view.json"]`).
- View `customMethods` live on `root.scripts.customMethods`; a sibling method is called `self.<name>()` from within another root method / root event / root message-handler.
- All NQs live in the **Core** project; the `quality/Hold_*` NQs already exist.
- Verify actual submits via SQL/proc inspection — the in-app browser cannot commit Perspective input bindings.

---

## File Structure

**New:**
- `ignition/projects/MPP/com.inductiveautomation.perspective/views/BlueRidge/Components/PlantFloor/Quality/HoldPanel/view.json` (+ `resource.json`) — the reusable place/release sub-view.
- `ignition/projects/MPP/com.inductiveautomation.perspective/views/BlueRidge/Components/PlantFloor/Quality/HoldListRow/view.json` (+ `resource.json`) — a selectable open-holds list row for the master pane.

**Modified:**
- `sql/migrations/repeatable/R__Quality_Hold_GetOpenByLot.sql` — add `PlacedByInitials` display column.
- `sql/migrations/repeatable/R__Quality_Hold_GetOpenByContainer.sql` — add `PlacedByInitials` display column.
- `sql/tests/0029_PlantFloor_Hold_Sort_Shipping_Aim/` — new test asserting the new column shape.
- `ignition/projects/Core/ignition/script-python/BlueRidge/Quality/Hold/code.py` — add `getOpenByContainerOne`; add `PlacedByInitials` key to both shaped-empty dicts.
- `ignition/projects/MPP/com.inductiveautomation.perspective/views/BlueRidge/Views/ShopFloor/HoldManagement/view.json` — rebuild as 2-tab master-detail.
- `ignition/projects/MPP/com.inductiveautomation.perspective/views/BlueRidge/Views/ShopFloor/LotDetail/view.json` — add Hold tab, remove dead `BtnPlaceHold`/`BtnScrap` and header `BtnReleaseHold`, add `holdChanged` handler.

**Orphaned (leave in place, no longer referenced):**
- `.../Components/PlantFloor/Quality/HoldRow/view.json` — superseded by `HoldListRow`.

---

## Task 1: Read-proc column parity — `PlacedByInitials`

**Files:**
- Modify: `sql/migrations/repeatable/R__Quality_Hold_GetOpenByLot.sql`
- Modify: `sql/migrations/repeatable/R__Quality_Hold_GetOpenByContainer.sql`
- Test: `sql/tests/0029_PlantFloor_Hold_Sort_Shipping_Aim/016_Hold_GetOpen_initials.sql`

**Interfaces:**
- Produces: both `Quality.Hold_GetOpenByLot` and `Quality.Hold_GetOpenByContainer` now return an additional `PlacedByInitials NVARCHAR` column (joined from `Location.AppUser.Initials`, LEFT JOIN so a null placer yields NULL). Column order: append after `PlacedByUserId`, before `PlacedAt`.

- [ ] **Step 1: Write the failing test**

Create `sql/tests/0029_PlantFloor_Hold_Sort_Shipping_Aim/016_Hold_GetOpen_initials.sql` following the INSERT-EXEC-into-temp-table pattern used by `015_Hold_ListOpen.sql`:

```sql
-- Assert Hold_GetOpenByLot / Hold_GetOpenByContainer expose PlacedByInitials.
SET NOCOUNT ON;
DECLARE @lotId BIGINT = (SELECT TOP 1 Id FROM Lots.Lot ORDER BY Id);
DECLARE @userId BIGINT = (SELECT TOP 1 Id FROM Location.AppUser ORDER BY Id);
DECLARE @htc BIGINT = (SELECT TOP 1 Id FROM Quality.HoldTypeCode ORDER BY Id);

-- place a hold so there is an open row to read
DECLARE @place TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO @place EXEC Quality.Hold_Place @LotId=@lotId, @HoldTypeCodeId=@htc, @Reason=N'test', @AppUserId=@userId;

DECLARE @read TABLE (Id BIGINT, LotId BIGINT, ContainerId BIGINT, HoldTypeCodeId BIGINT,
    HoldTypeCode NVARCHAR(50), Reason NVARCHAR(500), PlacedByUserId BIGINT,
    PlacedByInitials NVARCHAR(10), PlacedAt DATETIME2(3));
INSERT INTO @read EXEC Quality.Hold_GetOpenByLot @LotId=@lotId;

IF NOT EXISTS (SELECT 1 FROM @read WHERE LotId=@lotId)
    THROW 51000, 'Expected an open hold row from Hold_GetOpenByLot', 1;

-- cleanup: release the hold placed above
DECLARE @he BIGINT = (SELECT TOP 1 Id FROM @read);
DECLARE @rel TABLE (Status BIT, Message NVARCHAR(500));
INSERT INTO @rel EXEC Quality.Hold_Release @HoldEventId=@he, @AppUserId=@userId;
PRINT 'PASS 016_Hold_GetOpen_initials';
```

- [ ] **Step 2: Run the test to verify it fails**

Run the project's SQL test runner against a throwaway `MPP_MES_Test` DB (mirror how `0029` tests are executed — the `INSERT ... EXEC @read` will fail with a column-count/name mismatch because `PlacedByInitials` does not yet exist in the proc output).
Expected: FAIL — "Column name or number of supplied values does not match table definition" (temp-table shape has 9 columns, proc returns 8).

- [ ] **Step 3: Add the column to both procs**

In `R__Quality_Hold_GetOpenByLot.sql`, change the SELECT list to add the join + column:

```sql
    SELECT
        he.Id,
        he.LotId,
        he.ContainerId,
        he.HoldTypeCodeId,
        htc.Code AS HoldTypeCode,
        he.Reason,
        he.PlacedByUserId,
        u.Initials AS PlacedByInitials,
        CAST(he.PlacedAt AT TIME ZONE 'UTC' AT TIME ZONE 'Eastern Standard Time' AS DATETIME2(3)) AS PlacedAt
    FROM Quality.HoldEvent he
    INNER JOIN Quality.HoldTypeCode htc ON htc.Id = he.HoldTypeCodeId
    LEFT  JOIN Location.AppUser u       ON u.Id  = he.PlacedByUserId
    WHERE he.LotId = @LotId AND he.ReleasedAt IS NULL;
```

Apply the identical change (join `Location.AppUser u ON u.Id = he.PlacedByUserId`, add `u.Initials AS PlacedByInitials`) to `R__Quality_Hold_GetOpenByContainer.sql`, keeping its `WHERE he.ContainerId = @ContainerId AND he.ReleasedAt IS NULL`.

- [ ] **Step 4: Apply the migrations and re-run the test**

Apply the two repeatable migrations to the test DB (they are `CREATE OR ALTER`), then re-run `016_Hold_GetOpen_initials.sql`.
Expected: PASS — "PASS 016_Hold_GetOpen_initials".

- [ ] **Step 5: Commit**

```bash
git add sql/migrations/repeatable/R__Quality_Hold_GetOpenByLot.sql sql/migrations/repeatable/R__Quality_Hold_GetOpenByContainer.sql sql/tests/0029_PlantFloor_Hold_Sort_Shipping_Aim/016_Hold_GetOpen_initials.sql
git commit -m "feat(sql): add PlacedByInitials to Hold single-read procs"
```

---

## Task 2: Python wrapper — `getOpenByContainerOne` + shaped-empty parity

**Files:**
- Modify: `ignition/projects/Core/ignition/script-python/BlueRidge/Quality/Hold/code.py`

**Interfaces:**
- Consumes: existing `getOpenByContainer(containerId)` (list read), existing `getOpenByLot(lotId)`.
- Produces: `getOpenByContainerOne(containerId)` returning a shaped single-hold dict `{IsHeld, Id, LotId, ContainerId, HoldTypeCodeId, HoldTypeCode, Reason, PlacedByUserId, PlacedByInitials, PlacedAt}` (shaped-empty when none). Both `getOpenByLotOne` and `getOpenByContainerOne` shaped-empty dicts include the `PlacedByInitials` key so the panel's bound summary never null-traverses.

- [ ] **Step 1: Add `PlacedByInitials` to the existing `getOpenByLotOne` shaped-empty**

In `getOpenByLotOne`, change the empty return to include the new key:

```python
    return {"IsHeld": False, "Id": None, "HoldTypeCode": None, "Reason": None,
            "PlacedByInitials": None, "PlacedAt": None}
```

- [ ] **Step 2: Add the `getOpenByContainerOne` wrapper**

Immediately after `getOpenByContainer`, add:

```python
def getOpenByContainerOne(containerId):
    """HoldPanel bound-container state: the single open hold as a shaped dict
       (IsHeld flags presence) or a shaped-empty dict when the container has no
       open hold -- keeps the bound custom prop safe per the pre-declared-props rule."""
    rows = getOpenByContainer(containerId) or []
    if rows:
        h = dict(rows[0])
        h["IsHeld"] = True
        return h
    return {"IsHeld": False, "Id": None, "HoldTypeCode": None, "Reason": None,
            "PlacedByInitials": None, "PlacedAt": None}
```

- [ ] **Step 3: Sync to the gateway**

Run:
```bash
.\scan.ps1
```
Expected: scan completes; no "script module" errors in `wrapper.log`.

- [ ] **Step 4: Verify the wrapper resolves**

In the Ignition Designer Script Console (or a scratch gateway script), run:
```python
print BlueRidge.Quality.Hold.getOpenByContainerOne(1)
```
Expected: a dict printed with `IsHeld` present (either an open hold or the shaped-empty dict) — no `AttributeError`/import error.

- [ ] **Step 5: Commit**

```bash
git add ignition/projects/Core/ignition/script-python/BlueRidge/Quality/Hold/code.py
git commit -m "feat(hold): add getOpenByContainerOne wrapper + initials in shaped-empty"
```

---

## Task 3: Build the reusable `HoldPanel` component

**Files:**
- Create: `ignition/projects/MPP/com.inductiveautomation.perspective/views/BlueRidge/Components/PlantFloor/Quality/HoldPanel/view.json`
- Create: `ignition/projects/MPP/com.inductiveautomation.perspective/views/BlueRidge/Components/PlantFloor/Quality/HoldPanel/resource.json`

**Interfaces:**
- Consumes: `BlueRidge.Quality.Hold.{getOpenByLotOne, getOpenByContainerOne, place, release, listAssociatedContainers}`, `BlueRidge.Lots.Lot.{get, getByName}`, `BlueRidge.Common.Ui.notifyResult`, `BlueRidge.Common.Notify.toast`, `BlueRidge.Common.Util.toIntOrNone`, `session.custom.appUserId`, `session.custom.terminal.terminalLocationId`.
- Produces: an embeddable view with input params `lotId` (BIGINT), `containerId` (BIGINT), `allowLookup` (bool); listens for page-scoped `holdPanelLoad {lotId, containerId, allowLookup}`; emits page-scoped `holdChanged {lotId, containerId, action, holdEventId}` on success.

- [ ] **Step 1: Create `resource.json`**

```json
{
  "scope": "G",
  "version": 1,
  "restricted": false,
  "overridable": true,
  "files": ["view.json"],
  "attributes": {}
}
```

- [ ] **Step 2: Create `view.json` — params + fully-shaped custom defaults**

Author the view root as an `ia.container.flex` (`direction: column`, class `pf-panel`, padding 16px, gap 12px). Params and custom block:

```json
"params": { "lotId": 0, "containerId": 0, "allowLookup": false },
"propConfig": {
  "params.lotId": { "paramDirection": "input" },
  "params.containerId": { "paramDirection": "input" },
  "params.allowLookup": { "paramDirection": "input" }
},
"custom": {
  "target": { "kind": null, "id": 0, "label": "" },
  "allowLookup": false,
  "hold": { "IsHeld": false, "Id": null, "HoldTypeCode": null, "Reason": null, "PlacedByInitials": null, "PlacedAt": null },
  "placeDraft": { "holdTypeCodeId": null, "reason": "" },
  "releaseDraft": { "releaseRemarks": "" },
  "lookupDraft": { "lotName": "", "containerId": "" },
  "holdTypeOptions": [
    { "label": "Quality", "value": 1 },
    { "label": "Customer Complaint", "value": 2 },
    { "label": "Precautionary", "value": 3 }
  ]
}
```

- [ ] **Step 3: Add the root `customMethods` (`applyTarget`, `refresh`)**

Under `root.scripts.customMethods`:

```
applyTarget(lotId, containerId, allowLookup):
	lid = int(lotId) if lotId else 0
	cid = int(containerId) if containerId else 0
	if lid > 0:
		lot = BlueRidge.Lots.Lot.get(lid) or {}
		tgt = {"kind": "lot", "id": lid, "label": (lot.get("LotName") or ("LOT #" + str(lid)))}
	elif cid > 0:
		tgt = {"kind": "container", "id": cid, "label": "Container #" + str(cid)}
	else:
		tgt = {"kind": None, "id": 0, "label": ""}
	self.view.custom.target = tgt
	self.view.custom.allowLookup = bool(allowLookup)
	self.refresh()

refresh():
	t = self.view.custom.target or {}
	kind = t.get("kind"); tid = t.get("id") or 0
	if kind == "lot" and tid > 0:
		self.view.custom.hold = BlueRidge.Quality.Hold.getOpenByLotOne(tid)
	elif kind == "container" and tid > 0:
		self.view.custom.hold = BlueRidge.Quality.Hold.getOpenByContainerOne(tid)
	else:
		self.view.custom.hold = {"IsHeld": False, "Id": None, "HoldTypeCode": None, "Reason": None, "PlacedByInitials": None, "PlacedAt": None}
	self.view.custom.placeDraft = {"holdTypeCodeId": None, "reason": ""}
	self.view.custom.releaseDraft = {"releaseRemarks": ""}
```

(In `view.json`, `customMethods` is a list of `{"name","params":[...],"script":"\t..."}`; `params` are string names, e.g. `applyTarget` has `["lotId","containerId","allowLookup"]`, `refresh` has `[]`. Each script line is `\t`-indented and `\n`-joined.)

- [ ] **Step 4: Add `onStartup` (events.system) + `holdPanelLoad` handler**

`root.events.system.onStartup` (script, scope `G`):
```
	self.applyTarget(self.view.params.lotId, self.view.params.containerId, self.view.params.allowLookup)
```

`root.scripts.messageHandlers` — page-scoped `holdPanelLoad`:
```
	self.applyTarget(payload.get("lotId"), payload.get("containerId"), payload.get("allowLookup"))
```
(`pageScope: true`, `sessionScope: false`, `viewScope: false`.)

- [ ] **Step 5: Add the target header + lookup row (children)**

Add these flex children to the root, each shown/hidden via a `position.display` expr binding:

1. **TargetLabel** (`ia.display.label`, class `pf-queue-name`) — `props.text` expr `{view.custom.target.label}`; `position.display` expr `{view.custom.target.id} > 0`.
2. **LookupRow** (`ia.container.flex`, row) — visible when `{view.custom.allowLookup} = true`. Contains a LOT-name `ia.input.text-field` bidi-bound to `view.custom.lookupDraft.lotName` (placeholder "Scan or type LTT"), a Container-Id `ia.input.text-field` bidi-bound to `view.custom.lookupDraft.containerId` (placeholder "Container Id"), and a **Load** `ia.input.button` (class `pf-btn pf-btn-secondary`). Use the same `pf-field`/`pf-field-label`/`pf-field-input` markup as the existing HoldManagement fields. Load `onActionPerformed` (script, scope `G`):

```
	d = self.view.custom.lookupDraft
	lotName = (d.get("lotName") or "").strip()
	cid = BlueRidge.Common.Util.toIntOrNone(d.get("containerId"))
	if lotName and cid is not None:
		BlueRidge.Common.Ui.notifyResult({"Status": False, "Message": "Enter only one of LOT name or Container Id, not both."}, "Load target")
		return
	if not lotName and cid is None:
		BlueRidge.Common.Ui.notifyResult({"Status": False, "Message": "Enter a LOT name or a Container Id."}, "Load target")
		return
	if lotName:
		lot = BlueRidge.Lots.Lot.getByName(lotName)
		if not lot or lot.get("Id") is None:
			BlueRidge.Common.Ui.notifyResult({"Status": False, "Message": "No LOT found named '" + lotName + "'."}, "Load target")
			return
		self.applyTarget(lot.get("Id"), 0, True)
	else:
		self.applyTarget(0, cid, True)
```

- [ ] **Step 6: Add the Place sub-panel (children)**

A **PlaceGroup** flex column, `position.display` expr `{view.custom.target.id} > 0 && !coalesce({view.custom.hold.IsHeld}, false)`:
- Hold-type `ia.input.dropdown`: `props.options` ← `view.custom.holdTypeOptions`; `props.value` bidi ← `view.custom.placeDraft.holdTypeCodeId`; placeholder "Select hold type".
- Reason `ia.input.text-field`: bidi ← `view.custom.placeDraft.reason`; placeholder "Reason for hold".
- **Place hold** `ia.input.button` (class `pf-btn pf-btn-primary pf-btn-large`), `onActionPerformed` (script, scope `G`):

```
	d = self.view.custom.placeDraft
	t = self.view.custom.target or {}
	htc = d.get("holdTypeCodeId")
	reason = (d.get("reason") or "").strip() or None
	kind = t.get("kind"); tid = t.get("id") or 0
	if htc is None:
		BlueRidge.Common.Ui.notifyResult({"Status": False, "Message": "Select a hold type."}, "Place Hold")
		return
	if not tid:
		BlueRidge.Common.Ui.notifyResult({"Status": False, "Message": "No target selected."}, "Place Hold")
		return
	term = self.session.custom.terminal
	termId = term.terminalLocationId if term else None
	res = BlueRidge.Quality.Hold.place(htc, lotId=(tid if kind == "lot" else None), containerId=(tid if kind == "container" else None), reason=reason, appUserId=self.session.custom.appUserId, terminalLocationId=termId)
	BlueRidge.Common.Ui.notifyResult(res, "Hold placed")
	if res and res.get("Status"):
		if kind == "lot":
			cons = BlueRidge.Quality.Hold.listAssociatedContainers(tid) or []
			if len(cons) > 0:
				BlueRidge.Common.Notify.toast("Container advisory", str(len(cons)) + " associated container(s) - review whether they need holding too.", "warning", 0)
		self.refresh()
		system.perspective.sendMessage("holdChanged", payload={"lotId": (tid if kind == "lot" else 0), "containerId": (tid if kind == "container" else 0), "action": "placed", "holdEventId": res.get("NewId")}, scope="page")
```

- [ ] **Step 7: Add the Release sub-panel (children)**

A **ReleaseGroup** flex column, `position.display` expr `{view.custom.target.id} > 0 && coalesce({view.custom.hold.IsHeld}, false)`:
- Summary `ia.display.label` (class `pf-queue-detail`), `props.text` expr:
```
"Hold #" + toStr({view.custom.hold.Id}) + "  ·  " + coalesce({view.custom.hold.HoldTypeCode}, "") + if(isNull({view.custom.hold.PlacedByInitials}), "", "  ·  " + {view.custom.hold.PlacedByInitials}) + if(isNull({view.custom.hold.Reason}) || {view.custom.hold.Reason} = "", "", "  ·  " + {view.custom.hold.Reason})
```
(The `·` must be a literal middle-dot character in the expression string — no `\u` escapes in expr literals.)
- Release-remarks `ia.input.text-field`: bidi ← `view.custom.releaseDraft.releaseRemarks`; placeholder "Reason for release".
- **Release hold** `ia.input.button` (class `pf-btn pf-btn-secondary pf-btn-large`), `onActionPerformed` (script, scope `G`):

```
	h = self.view.custom.hold or {}
	heId = h.get("Id")
	t = self.view.custom.target or {}
	if not heId:
		BlueRidge.Common.Ui.notifyResult({"Status": False, "Message": "No open hold to release."}, "Release Hold")
		return
	remarks = (self.view.custom.releaseDraft.get("releaseRemarks") or "").strip() or None
	term = self.session.custom.terminal
	termId = term.terminalLocationId if term else None
	res = BlueRidge.Quality.Hold.release(heId, releaseRemarks=remarks, appUserId=self.session.custom.appUserId, terminalLocationId=termId)
	BlueRidge.Common.Ui.notifyResult(res, "Hold released")
	if res and res.get("Status"):
		kind = t.get("kind"); tid = t.get("id") or 0
		self.refresh()
		system.perspective.sendMessage("holdChanged", payload={"lotId": (tid if kind == "lot" else 0), "containerId": (tid if kind == "container" else 0), "action": "released", "holdEventId": heId}, scope="page")
```

- [ ] **Step 8: Sync + verify the view deserializes**

Run:
```bash
.\scan.ps1
```
Expected: scan completes with no `getObjectForSave` / GSON deserialize errors for `HoldPanel`. Open the view in Designer — it renders (empty target → lookup row only when `allowLookup`, otherwise blank). No red Component Error badges.

- [ ] **Step 9: Commit**

```bash
git add ignition/projects/MPP/com.inductiveautomation.perspective/views/BlueRidge/Components/PlantFloor/Quality/HoldPanel/view.json ignition/projects/MPP/com.inductiveautomation.perspective/views/BlueRidge/Components/PlantFloor/Quality/HoldPanel/resource.json
git commit -m "feat(hold): reusable HoldPanel place/release component"
```

---

## Task 4: Build the selectable `HoldListRow` component

**Files:**
- Create: `.../Components/PlantFloor/Quality/HoldListRow/view.json`
- Create: `.../Components/PlantFloor/Quality/HoldListRow/resource.json`

**Interfaces:**
- Produces: a repeater-instance view with input params `holdEventId`, `lotId`, `containerId`, `label`, `holdTypeCode`, `reason`, `placedByInitials`, `placedAt`, `selectedHoldEventId`. Whole-row click sends page-scoped `holdRowSelected {holdEventId, lotId, containerId}`.

- [ ] **Step 1: Create `resource.json`** (identical shape to Task 3 Step 1).

- [ ] **Step 2: Create `view.json`**

Root `ia.container.flex` (`direction: row`, `alignItems: center`, class `pf-queue-row`, gap 16px, padding "12px 16px"). Params:

```json
"params": {
  "holdEventId": 0, "lotId": 0, "containerId": 0, "label": "",
  "holdTypeCode": "", "reason": "", "placedByInitials": "", "placedAt": "",
  "selectedHoldEventId": 0
}
```

Children:
1. **Info** flex column (`grow:1, basis:0`): a `pf-queue-name` label bound `{view.params.label}`; a `pf-queue-detail` label bound expr `{view.params.holdTypeCode} + if(isNull({view.params.reason}) || {view.params.reason} = "", "", "  ·  " + {view.params.reason}) + if(isNull({view.params.placedByInitials}) || {view.params.placedByInitials} = "", "", "  ·  " + {view.params.placedByInitials})` (literal middle-dot).
2. **HoldPill** `ia.display.label` (`shrink:0`), `props.text` expr `"#" + toStr({view.params.holdEventId})`, class `pf-pill pf-pill-hold`.

Selected-row highlight: bind root `props.style.classes` expr:
```
if({view.params.holdEventId} = {view.params.selectedHoldEventId} && {view.params.selectedHoldEventId} > 0, "pf-queue-row pf-queue-row-selected", "pf-queue-row")
```

Whole-row select — root `events.component.onClick` (script, scope `G`):
```
	system.perspective.sendMessage("holdRowSelected", payload={"holdEventId": self.view.params.holdEventId, "lotId": self.view.params.lotId or 0, "containerId": self.view.params.containerId or 0}, scope="page")
```

- [ ] **Step 3: Add the `pf-queue-row-selected` style rule (Core stylesheet)**

The plant-floor `psc-pf-*`/`pf-*` CSS is canonical in the **Core** stylesheet (`ignition/projects/Core/com.inductiveautomation.perspective/stylesheet/stylesheet.css`). Append:

```css
.pf-queue-row-selected { border: 1px solid var(--pf-accent, #185FA5); background: var(--pf-accent-bg, #E6F1FB); }
```
(Match the existing variable names actually used in that file — grep `pf-pill-hold` there first and reuse its color tokens rather than inventing new vars.)

- [ ] **Step 4: Sync + verify**

Run `.\scan.ps1`; open `HoldListRow` in Designer — renders a row without Component Errors.

- [ ] **Step 5: Commit**

```bash
git add ignition/projects/MPP/com.inductiveautomation.perspective/views/BlueRidge/Components/PlantFloor/Quality/HoldListRow/view.json ignition/projects/MPP/com.inductiveautomation.perspective/views/BlueRidge/Components/PlantFloor/Quality/HoldListRow/resource.json ignition/projects/Core/com.inductiveautomation.perspective/stylesheet/stylesheet.css
git commit -m "feat(hold): selectable HoldListRow + selected-row style"
```

---

## Task 5: Rebuild Hold Management as 2-tab master-detail

**Files:**
- Modify (full rewrite): `.../Views/ShopFloor/HoldManagement/view.json`

**Interfaces:**
- Consumes: `HoldPanel` (Task 3), `HoldListRow` (Task 4), NQ `quality/Hold_ListOpen`, `BlueRidge.Lots.Lot.search`, `BlueRidge.Quality.Hold.placeBulk`, `BlueRidge.Workorder.RejectEvent.record`, `BlueRidge.Quality.DefectCode.getForDropdown`.
- Produces: `/shop-floor/hold-management` with tabs "Open Holds" (master-detail) and "Bulk & Scrap".

- [ ] **Step 1: Keep the header, replace the body with a tab container**

Preserve the existing Header block (Title/Subtitle/Refresh/Close). Replace the `Body` column's children with a single `ia.container.tab` (`grow:1`), styled like LOT Detail's (`menuType: "modern"`, `menuStyle.classes: "tab-strip"`, `contentStyle.classes: "tab-content-fill"`, `tabStyle` active/inactive `tab-item`/`tab-item-active`). Two tabs: `"Open Holds"`, `"Bulk & Scrap"`, both `runWhileHidden: true`. Map panes by `position.tabIndex` (0 and 1) — **not array order** (per the tab-pane-tabindex rule).

Carry over these custom props (defaults preserved): `filterText:""`, `filterTypeId:null`, `holdTypeOptions` (3 types), `refreshToken:0`, `bulkHoldTypeId:null`, `bulkQuery:""`, `bulkReason:""`, `bulkResults:[]`, `bulkSelectedLotIds:[]`, `scrapDraft:{lotName:"",defectCodeId:null,quantity:"",remarks:""}`, `defectOptions:[]`. Add `selectedHoldEventId:0`. Keep the `custom.openHolds` binding (over `Hold_ListOpen`, refresh-token gated) and `custom.defectOptions` binding exactly as they are today.

- [ ] **Step 2: Tab 0 "Open Holds" — master pane (left)**

A flex row (`grow:1`, gap 16px). Left column (`basis:0, grow:1`, class `pf-panel`):
- The existing **FilterRow** (filter text-field bidi `view.custom.filterText`; hold-type dropdown bidi `view.custom.filterTypeId`) — reuse verbatim.
- A **"New hold"** `ia.input.button` (class `pf-btn pf-btn-secondary`), `onActionPerformed` (script, scope `G`):
```
	self.view.custom.selectedHoldEventId = 0
	system.perspective.sendMessage("holdPanelLoad", payload={"lotId": 0, "containerId": 0, "allowLookup": True}, scope="page")
```
- An `ia.display.flex-repeater` (`path: BlueRidge/Components/PlantFloor/Quality/HoldListRow`, `direction: column`, `elementPosition.basis: "76px"`), `props.instances` bound to `view.custom.openHolds` with transform:
```
	sel = int(self.view.custom.selectedHoldEventId or 0)
	rows = []
	for r in (value or []):
		if r.get("LotId") is not None:
			label = r.get("LotName") or ("LOT #" + str(r.get("LotId")))
		else:
			label = "Container #" + str(r.get("ContainerId")) + (("  ·  " + r.get("ContainerItemPartNumber")) if r.get("ContainerItemPartNumber") else "")
		rows.append({"holdEventId": r.get("HoldEventId"), "lotId": r.get("LotId") or 0, "containerId": r.get("ContainerId") or 0, "label": label, "holdTypeCode": r.get("HoldTypeCode") or "", "reason": r.get("Reason") or "", "placedByInitials": r.get("PlacedByInitials") or "", "placedAt": (str(r.get("PlacedAt")) if r.get("PlacedAt") else ""), "selectedHoldEventId": sel})
	return rows
```
(The transform reads `self.view.custom.selectedHoldEventId`, so the binding must also list it as a dependency — bind `props.instances` via an `expr` that references both `{view.custom.openHolds}` and `{view.custom.selectedHoldEventId}`, mirroring the existing bulk-results pattern, then the script transform builds the rows.)

- [ ] **Step 3: Tab 0 "Open Holds" — detail pane (right)**

Right column (`basis:0, grow:1`): an embedded-view component (`ia.display.view`) with `props.path: "BlueRidge/Components/PlantFloor/Quality/HoldPanel"` and static param defaults `{"lotId":0,"containerId":0,"allowLookup":true}` (the panel is driven by messages, so static params are only the initial state).

- [ ] **Step 4: Tab 0 message handlers (view root)**

Add to `root.scripts.messageHandlers` (all `pageScope: true`):

`holdRowSelected`:
```
	he = payload.get("holdEventId")
	self.view.custom.selectedHoldEventId = int(he) if he else 0
	system.perspective.sendMessage("holdPanelLoad", payload={"lotId": payload.get("lotId") or 0, "containerId": payload.get("containerId") or 0, "allowLookup": False}, scope="page")
```

`holdChanged` (panel → list refresh; a released hold leaves the list):
```
	self.view.custom.selectedHoldEventId = 0
	self.view.custom.refreshToken = (self.view.custom.refreshToken or 0) + 1
	system.perspective.sendMessage("holdPanelLoad", payload={"lotId": 0, "containerId": 0, "allowLookup": True}, scope="page")
```

- [ ] **Step 5: Tab 1 "Bulk & Scrap"**

Move the existing **BulkHoldPanel** (search field + `BulkSearchButton` → `Lot.search`; `BulkResultsRepeater` over `BulkResultRow`; `BulkActionRow` hold-type + reason + `placeBulk`) and **ScrapPanel** (LOT name / reject qty / defect / remarks → `RejectEvent.record(allowHeldLot=True)`) into tab pane `tabIndex:1`, **unchanged** in behavior. Keep the `bulkToggle` message handler (page-scoped) exactly as today.

- [ ] **Step 6: Sync + verify deserialization and flows**

Run `.\scan.ps1`. Open `/shop-floor/hold-management`:
- No Component Errors; the tab strip shows two tabs.
- "Open Holds": the list renders open holds; clicking a row highlights it and the right panel shows the Release form; "New hold" shows the lookup + Place form.
- "Bulk & Scrap": bulk search + scrap forms present.

Because the in-app browser cannot commit input bindings, **verify an actual place** by SQL: after driving a place through the panel in the real Designer/session, confirm `SELECT TOP 5 * FROM Quality.HoldEvent ORDER BY Id DESC` shows the new open row, and a release nulls `ReleasedAt`.

- [ ] **Step 7: Commit**

```bash
git add ignition/projects/MPP/com.inductiveautomation.perspective/views/BlueRidge/Views/ShopFloor/HoldManagement/view.json
git commit -m "feat(hold): Hold Management 2-tab master-detail with shared HoldPanel"
```

---

## Task 6: LOT Detail — add Hold tab, remove dead buttons

**Files:**
- Modify: `.../Views/ShopFloor/LotDetail/view.json`

**Interfaces:**
- Consumes: `HoldPanel` (Task 3). Existing `load()` customMethod, `view.params.lotId`, `view.custom.hold`, header hold pill.
- Produces: a "Hold" tab (`tabIndex:5`) hosting `HoldPanel(lotId=params.lotId, containerId=0, allowLookup=false)`; header pill stays live via a `holdChanged`→`load()` handler.

- [ ] **Step 1: Add the Hold tab to `TabContainer`**

In the `props.tabs` array append `{ "text": "Hold", "runWhileHidden": true, "disabled": false }` (becomes index 5). Add a matching pane child with `position.tabIndex: 5`, an `ia.display.view` `props.path: "BlueRidge/Components/PlantFloor/Quality/HoldPanel"` and `props.params`:
```json
{ "lotId": "{view.params.lotId}", "containerId": 0, "allowLookup": false }
```
Bind the `lotId` param to `view.params.lotId` (property binding), so the embed receives the current LOT.

- [ ] **Step 2: Drive the panel from `load()` (guarantees sync)**

Append to the end of the existing `load()` customMethod script:
```
	system.perspective.sendMessage("holdPanelLoad", payload={"lotId": (self.view.params.lotId or 0), "containerId": 0, "allowLookup": False}, scope="page")
```

- [ ] **Step 3: Refresh the header pill after a panel action**

`root.scripts.messageHandlers` is currently `null`. Set it to a list with one page-scoped handler `holdChanged`:
```
	self.load()
```
(The handler runs on the view root; `load` is a root customMethod, so `self.load()`.)

- [ ] **Step 4: Remove the dead header buttons**

Delete the `BtnPlaceHold` component (the `enabled:false` "Place Hold is a later phase action" button) and the `BtnScrap` component. Delete the header `BtnReleaseHold` component (release now lives in the Hold tab — single entry point per the spec default). Leave `BtnSetCrt`/`BtnClearCrt` and the header hold **pill** untouched.

- [ ] **Step 5: Sync + verify**

Run `.\scan.ps1`. Open `/shop-floor/lot-detail/<id>` for a known LOT:
- Tabs now end with "Hold"; the Hold tab shows Place (un-held LOT) or Release (held LOT).
- Placing a hold from the tab flips the header pill to "ON HOLD …" (via `holdChanged`→`load()`), and `Quality.HoldEvent` shows the new row (SQL check).
- Releasing from the tab clears the pill and nulls nothing is left open for that LOT.
- The old dead Place Hold / Scrap / header Release buttons are gone.

- [ ] **Step 6: Commit**

```bash
git add ignition/projects/MPP/com.inductiveautomation.perspective/views/BlueRidge/Views/ShopFloor/LotDetail/view.json
git commit -m "feat(hold): LOT Detail Hold tab, remove dead place/scrap/release header buttons"
```

---

## Task 7: End-to-end verification + cleanup

**Files:** none (verification only).

- [ ] **Step 1: Run the SQL test suite for Phase 7**

Execute the `0029_PlantFloor_Hold_Sort_Shipping_Aim` tests against `MPP_MES_Test`.
Expected: all pass, including new `016_Hold_GetOpen_initials`. (Run-Tests exit 1 with 0 failures usually means an FK cleanup-order issue, not a real failure — check the log.)

- [ ] **Step 2: Cross-host round-trip**

In a real session: place a hold on a LOT from **LOT Detail → Hold tab**; confirm it appears in **Hold Management → Open Holds** list. Select it there; release from the detail panel; confirm the LOT Detail header pill clears on reload and the row leaves the list.

- [ ] **Step 3: Container + bulk + scrap regression**

- Hold Management "New hold" → Container Id path places a container hold (SQL: `Quality.HoldEvent` row with `ContainerId` set).
- "Bulk & Scrap": bulk-place across 2+ searched LOTs; scrap a held LOT (SQL: `RejectEvent` recorded, LOT stays on hold).

- [ ] **Step 4: Confirm no orphan references**

Grep the MPP project for any remaining reference to the old `Quality/HoldRow` path; if the rebuilt Hold Management no longer references it, that's expected (component left orphaned intentionally). No view should reference a deleted button by name.

```bash
grep -rn "Quality/HoldRow" ignition/projects/MPP
```
Expected: no matches in `HoldManagement/view.json` (HoldListRow is used instead).

- [ ] **Step 5: Final scan + status**

Run `.\scan.ps1`; confirm clean. `git status` shows only intended files committed across Tasks 1–6.

---

## Self-Review Notes

- **Spec coverage:** HoldPanel LOT-or-container + lookup (Task 3) ✓; getOpenByContainerOne (Task 2) ✓; read-proc column parity / open-question 2 (Task 1) ✓; Hold Management 2-tab master-detail, unified list, container advisory as toast, bulk+scrap moved (Task 5) ✓; LOT Detail Hold tab + dead-button removal + header Release removed per open-question-1 default (Task 6) ✓; no SQL behavior change ✓; page-scoped messaging per embed-input-only rule ✓.
- **Deferred decision resolved:** spec open-question 1 (header Release button) → **removed** (Task 6 Step 4), single entry point via the Hold tab. Open-question 2 (container read-proc parity) → **add `PlacedByInitials`** (Task 1).
- **Type consistency:** `applyTarget(lotId, containerId, allowLookup)` and `refresh()` names, the `holdPanelLoad`/`holdRowSelected`/`holdChanged` message names, and the `{IsHeld, Id, HoldTypeCode, Reason, PlacedByInitials, PlacedAt}` hold shape are used identically across Tasks 2–6.
