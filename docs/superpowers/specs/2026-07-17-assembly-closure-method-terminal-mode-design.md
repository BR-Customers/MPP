# Assembly-Out Closure Method — Terminal Mode + Per-Method Container Config

**Date:** 2026-07-17
**Status:** Draft (design approved in brainstorming; blast radius complete; PLC tag wiring resolved from built UDTs)
**Author:** Blue Ridge Automation
**Related:** `MPP_MES_DATA_MODEL.md` (Parts.ContainerConfig, Lots.Container), FDS-02-010 (terminal view-policy), the 2026-06-10 terminal-mode-view-policy spec, Arc 2 Phase 6 assembly (`0028_arc2_phase6_assembly.sql`), Arc 2 Phase 7 hold (`Quality.Hold_Place`/`Hold_Release`).

---

## 1. Problem

The Assembly-Out non-serialized view ([AssemblyNonSerialized/view.json](../../../ignition/projects/MPP/com.inductiveautomation.perspective/views/BlueRidge/Views/ShopFloor/AssemblyNonSerialized/view.json)) renders a **hardcoded ByVision** camera-acceptance UI — a static green "PASS" pane, a "Per-Tray Close - ByVision" header, a `ByVision` chip — even when the container's actual closure method (from config) is **By Count**. Nothing on that pane is bound to a live camera/OPC tag or to the real closure method; it is decorative chrome carried over from a vision-mode mockup. On the floor this is misleading: an operator reads the green PASS as "the Cognex validated this tray" when in fact only the typed count was recorded.

Underlying this cosmetic bug is a modelling gap: **the same part, on the same line, is closed by different methods depending on the pack-out.** Concrete example — one finished good ships to Honda as a **ByVision** container (12 trays × 8 parts, camera-validated per tray) and to another customer as a **ByCount** container (1 technical tray × 48 parts in a cardboard box). Today `Parts.ContainerConfig` enforces **one active config per part** (`UQ_ContainerConfig_ActiveItemId`), so it cannot even express this, and the view has no mechanism to present the right one of three closure UIs.

### Constraints (from brainstorming)

- **No customer master.** Closure method must not be derived from a customer entity — none exists and none is wanted now.
- **No per-container operator decision.** The operator must never be prompted to pick a closure method when opening a container. That is a non-starter.
- **Deciding only on change.** A human decision is acceptable *only at a changeover*, and it must persist indefinitely until the next changeover.
- **Same line runs multiple methods** over time (via changeover), exactly as legacy did with its per-station `IsVisionModeEnabled` / `IsScaleModeEnabled` dashboard flags — but legacy lost the record of which mode ran; we must not.

---

## 2. Model

Closure method is resolved by a **persisted terminal mode** that *selects among* a part's **per-method container configs**. Two independent pieces that snap together:

### 2.1 `ContainerConfig` becomes 1-many per part, keyed by method

- Re-key the active-config unique index from `(ItemId)` → **`(ItemId, ClosureMethod)`** (filtered `WHERE DeprecatedAt IS NULL`). A part may have up to one active config per method.
- Each config is a **complete pack-out**: its own `PartsPerTray`, `TraysPerContainer`, `DunnageCode`, `TargetWeight`, and `ClosureMethod`.
- `ClosureMethod` becomes **NOT NULL** and **code-table-backed** via a new `Parts.ClosureMethodCode` (`ByCount` / `ByWeight` / `ByVision`) with an FK — per the no-magic-strings convention. It is promoted from its OI-02 "nullable maybe" status to the required discriminator.
- **One active config per (part, method)** — a part cannot have two different `ByCount` pack-outs. Two count box sizes for one part would need a further discriminator (the customer/pack-out axis), which is explicitly out of scope.

### 2.2 Terminal carries the mode; capability is derived from bound PLC devices

- **Persisted mode** — one new EAV attribute on the Terminal Location (`LocationTypeDefinition` 7), same mechanism as `IpAddress` / `DefaultScreen`: **`CurrentClosureMethod`** — the station's active mode; changed only at changeover. `onStartup` resolves it into **`session.custom.closureMethod`** alongside the existing `session.custom.terminal` / `.printer` / `.plcDevices`.
- **Capability is NOT stored** — it is derived from the PLC devices already bound to the terminal (`Location.TerminalPlcDevice → Location.PlcDeviceType`). The mapping lives in **data, not logic**: add a nullable **`PlcDeviceType.ClosureMethodCode`** FK →
  - `ScaleStation` → `ByWeight`
  - `TrayInspectionStation` → `ByVision`
  - `SerializedMipStation` / `NonSerializedMipStation` → `NULL` (MIP handshake is the part-validation axis, orthogonal to container closure)
  - A terminal's **capability set** = the distinct non-null `ClosureMethodCode` across its active devices, **plus `ByCount` always** (needs no device). The changeover picker offers exactly this set. `ClosureCapabilities` as a stored attribute is dropped.
- **Vision embed URL** — the external vision-app URL for the ByVision appearance stays a small terminal attribute (`VisionAppUrl`); it is a display concern, not a PLC tag.

### 2.3 Resolution — deterministic, zero per-container choice

At the assembly-out cell:

- **Open container at the cell?** → closure method = its pinned `ContainerConfig.ClosureMethod` (via `Lots.Container.ContainerConfigId`). No prompt.
- **No open container?** → the effective config = the running part's active `ContainerConfig WHERE ClosureMethod = session.custom.closureMethod`. That single config drives sizing, dunnage, the view appearance, and the close trigger.
- **No config for the mode** → hard block ("Part X has no *ByVision* pack-out configured"). A wrong-station / missing-config guard the operator does not resolve on the floor.

The operator never selects a method. The terminal's mode already answered "which pack-out."

---

## 3. Changeover — elevated shop-floor action

- The assembly-out header shows a **mode chip** (`Closure: Vision`) so current mode is always visible.
- Changing it requires **supervisor AD elevation** (operator initials are not sufficient), reusing the existing elevation mechanism. The picker offers only `ClosureCapabilities` modes.
- On confirm, a new mutation proc updates the terminal's `CurrentClosureMethod` attribute and **audits** it (who / when / old → new) — closing legacy's invisible-toggle gap.
- The new mode **persists indefinitely** until the next changeover — no expiry, no per-container reset.
- **Live-session refresh (required).** `session.custom.closureMethod` is resolved once at `onStartup`, so the durable-attribute write alone leaves the running session stale. The changeover handler, after the proc returns success, **directly assigns `session.custom.closureMethod` (and any dependent props) locally** in the same session so the view re-renders immediately without a re-login (`system.perspective.setSessionProps` does not exist — assign the prop directly). The elevation returns an `appUserId` statelessly and does **not** set `session.custom.appUserId`; the handler passes the returned id straight to the changeover proc.

### 3.1 Swap with an open container → freeze it

- No-open-container is **not** a precondition. If a changeover occurs while a container is open at the cell, the changeover proc **freezes** that container by calling `Quality.Hold_Place @ContainerId` with a new **`Changeover`** `HoldTypeCode` → container status Hold(4).
- The next run in the new mode opens a **fresh** container (resolution picks the new method's config).
- **Thaw/resume:** when the terminal is next flipped back to the held container's method, the container is releasable via `Quality.Hold_Release` (restores prior status Open) and resumes accepting trays. Releasing is **gated** on `session.custom.closureMethod == heldContainer.ContainerConfig.ClosureMethod`, so a Vision container never resumes under Count mode.

---

## 4. The view — three appearances off `session.custom.closureMethod`

A single conditional replaces the hardcoded ByVision chrome. `position.display` gates the middle panel on the resolved method; the shared chrome (KPIs, Container Completion Gate, header) stays common.

| Mode | Middle panel | Device UDT | Close trigger (MES watches) | MES writes down |
|---|---|---|---|---|
| **ByCount** | Today's build: operator-typed "Parts in tray" + **Complete Tray** button. | — | operator button (`Assembly.handleTrayComplete`) | — |
| **ByWeight** | Live weight vs target ("waiting for scale — 4.2 / 5.0 kg"); no camera, no count field. | `ScaleStation` | `NET_TargetWeightMetFlag` → true | `TRG_TargetWeightValue` ← `ContainerConfig.TargetWeight` (+ UOM/tolerance), pulse `TRG_SendMessage` |
| **ByVision** | External vision app embedded left (`VisionAppUrl`); per-slot dispositions + tray status right. | `TrayInspectionStation` | `OkToContinue` → true (with `InspectionComplete`, `PartDisposition01..18`) | `PartNumber` ← `Item.PlcId` (recipe); validate `VisionPartNumber` read-back |

Trigger-tag path = `TerminalPlcDevice.UdtInstancePath` + member. `Workorder.TrayInspectionWatcher` already subscribes to the TrayInspection members; a scale watcher covers `NET_TargetWeightMetFlag`. Weight/Vision auto-close is the PLC tail phase; the view swap + Count path ship first.

`Lots.ContainerTray.ClosureMethod` already persists per tray in the mint path, so each tray records the mode that produced it — full traceability regardless of appearance.

---

## 5. Impact / blast radius

> Populated from the four parallel blast-radius passes (SQL/procs, Ignition views/scripts, terminal/session/hold, tests/seeds). See subsections below.

Synthesized from four parallel read-only passes. Two agents disagreed on test-fixture NULL risk; the pass that actually opened the fixtures wins (they already supply `ClosureMethod`) — see §5.4.

### 5.1 SQL / procs

**MUST-CHANGE**

- **`R__Workorder_Assembly_CompleteTray.sql:125-130`** — the `SELECT TOP 1 … WHERE ItemId … ORDER BY Id DESC` config resolution goes nondeterministic once a part has >1 active config. Replace with a hard `(ItemId, <resolved ClosureMethod>)` lookup; no match → the block described in §2.3. The method is the terminal mode (arrives via `@ClosureMethod`, sourced from `session.custom.closureMethod`); the existing `COALESCE(cc.ClosureMethod, @ClosureMethod, 'ByCount')` fallback is removed.
- **`R__Parts_ContainerConfig_Create.sql` (~L103-114)** — carries an explicit *"one active config per Item"* business-rule check on top of the index. Both relax to `(ItemId, ClosureMethod)`. `@ClosureMethod` becomes **required** (drop the `= NULL` default).
- **`R__Parts_ContainerConfig_Update.sql`** — make `ClosureMethod` **immutable** (reject changing it; switching method = deprecate + create). Prevents an update from colliding a row into another method's slot.
- **`R__Parts_ContainerConfig_GetByItem.sql`** — flips from 0-or-1 to **0-or-N** rows. Update the header contract; every caller must iterate (chiefly the Item Master editor load). A sibling `GetByItemAndMethod` is the clean read for single-config resolution.
- **New:** `Parts.ClosureMethodCode` code table (ByCount/ByWeight/ByVision) + FK from `ContainerConfig.ClosureMethod`; column → `NOT NULL`.

**SAFE — container pins its config, no fan-out** (each JOINs `Lots.Container.ContainerConfigId`, set once at open): `R__Lots_Container_Open`, `R__Lots_Container_Complete`, `R__Lots_Container_GetOpenByCell`, `R__Lots_ContainerTray_Close`. Verify only that `Container_Open` is invoked with the `(ItemId, method)`-correct config id. `v_EffectiveItemLocation` never touches ContainerConfig. `Item_Deprecate` cascade-deprecates *all* of an item's configs — correct.

### 5.2 Ignition views / scripts / NQs

**MUST-CHANGE — views**

- **`AssemblyNonSerialized/view.json`** — hardcoded ByVision chrome: `ConfirmMethod` chip (~L152, static `"ByVision"`), the `"Per-Tray Close - ByVision"` header string (~L690), and the entire camera PASS pane (~L751-873). Replace with the three-appearance conditional on `session.custom.closureMethod`. The `closureRaw` binding already reads the real method from config — reuse it.
- **`AssemblySerialized/view.json`** — same hardcoded-Vision pattern (chip + subtitle + vision tray panel). **Resolves open question:** serialized shares the shape and needs the same three-appearance treatment.
- **`ItemMaster/ContainerConfig/view.json`** — single `selected`/`editDraft` → a **per-method list** (≤3). Load fans out via the multi-row `GetByItem`; Save loops per method; the per-section-ownership dirty pattern stays, and the parent Item Master treats the whole section as one dirty unit (no per-method dirty tracking).

**MUST-CHANGE — scripts**

- **`BlueRidge.Parts.ContainerConfig.code.py`** — `getByItem`/`getByItemOrEmpty` return a single row; add `getByItemAll(itemId)` (editor load) and `getByItemAndMethod(itemId, method)` (assembly resolution + prefill).
- **`BlueRidge.Workorder.Assembly.code.py`** — `completeTray`/`handleTrayComplete` **already accept a `closureMethod` param that is currently unused**; route `session.custom.closureMethod` through it to the proc.
- **`BlueRidge.Lots.Container.code.py`** — `open()` already takes `containerConfigId` (multi-config-ready). `getOpenByCell` single-open-container assumption holds because frozen containers drop to Hold(4) and leave the open set.

**SHOULD-REVIEW** — NQs `ContainerConfig_GetByItem` (multi-row shape), `Assembly_CompleteTray` / `ContainerTray_Close` / `ContainerConfig_Create`/`Update` (several already carry a `closureMethod` param). PLC watchers are commissioning stubs but assume vision: `TrayInspectionWatcher` (writes a vision recipe — must guard on method), `NonSerializedMipWatcher` (`_resolveLineConfig` stub must carry method), `AssemblyPlc` (skeleton). These matter only at the PLC tail phase.

### 5.3 Terminal / session / hold

- **Terminal EAV** — add two `LocationAttributeDefinition` rows for `LocationTypeDefinitionId = 7` (`CurrentClosureMethod`, `VisionAppUrl`), following the `0002`/`0020` seed pattern; respect the `(LocationTypeDefinitionId, AttributeName)` filtered-unique constraint (`0014`) and continue the existing `SortOrder`. (`ClosureCapabilities` is NOT stored — see below.)
- **`Location.PlcDeviceType.ClosureMethodCode`** — new nullable FK → `Parts.ClosureMethodCode`; seed `ScaleStation→ByWeight`, `TrayInspectionStation→ByVision`, MIP types `NULL`. Capability = distinct non-null values across the terminal's active `TerminalPlcDevice` rows + `ByCount`. A read proc (`Location.Terminal_GetClosureCapabilities` or a column on the terminal resolver) surfaces the set for the changeover picker.
- **`R__Location_Terminal_GetByIpAddress.sql`** — add `LEFT JOIN` + projection for `CurrentClosureMethod` (and `VisionAppUrl`) so the session resolver can read them.
- **UDT close-trigger members** already exist (we built them): `ScaleStation.NET_TargetWeightMetFlag` / `TRG_TargetWeightValue` / `TRG_SendMessage`; `TrayInspectionStation.OkToContinue` / `InspectionComplete` / `PartDisposition01..18` / `PartNumber` / `VisionPartNumber`. No UDT changes needed — the tail-phase watchers subscribe to them.
- **`onStartup.py`** — stash `session.custom.closureMethod` (+ vision URL) from the terminal row, fallback `""`. `session-props/props.json` needs no declaration (session custom is untyped) — but readers must tolerate empty/None.
- **Hold freeze/thaw is native** — `Hold_Place @ContainerId` on an **Open(1)** container captures `PriorContainerStatusCodeId = 1`; `Hold_Release` restores Open(1). While Hold(4) it leaves `Container_GetOpenByCell` (cell free for the new-mode container) and returns on thaw. Seed `Quality.HoldTypeCode` Id 4 `Changeover` (guarded insert). **Verify:** existing tests only held Complete/Shipped containers — confirm `Hold_Place` permits an Open one (no status guard beyond the double-hold B3 check is expected).
- **Elevation** — reuse `BlueRidge.Location.AppUser.elevate(ad, pw, 'Changeover', terminalId)` + `ElevationModal`; it's **stateless per action** (returns `appUserId`, does not set `session.custom.appUserId`), so pass the returned id straight to the changeover proc. Audit via existing `ElevationGranted`/`ElevationDenied` event types (27/28). **Deployment blocker:** `_validateAdCredentials` is a stub that rejects all until wired to the gateway IdP — the changeover can't be exercised end-to-end in dev until that lands (dev workaround: bypass seam or bootstrap user).

### 5.4 Tests / seeds

- **No hard fixture breaks.** Every `0028`/`0029` ContainerConfig insert and `sql/seeds/020_seed_items.sql` already supply an explicit `ClosureMethod` (ByCount/ByWeight/ByVision). The NOT-NULL migration's only data concern is **backfilling pre-existing rows** (default `ByCount`, see §7).
- **Soft breaks:** `sql/tests/0008_Parts_Item/020_ContainerConfig_crud.sql` **Test 5** asserts duplicate-per-item rejection — invert to "same-method duplicate rejects, different-method succeeds." `sql/tests/0005_Quality_codes/010_Quality_codes_read.sql` asserts `HoldTypeCode_List` = 3 rows — bump to 4 for `Changeover`.
- **New coverage:** `(ItemId, ClosureMethod)` uniqueness; `Assembly_CompleteTray` method resolution + no-match block; changeover freeze → new container → thaw round-trip.

---

## 6. Phasing

Multi-part build; the plan will sequence roughly:

1. **Schema foundation** — `Parts.ClosureMethodCode` code table; `ContainerConfig.ClosureMethod` NOT NULL + FK; re-key unique index `(ItemId, ClosureMethod)`; backfill existing configs.
2. **Terminal mode + derived capability** — `CurrentClosureMethod` + `VisionAppUrl` EAV attrs; `PlcDeviceType.ClosureMethodCode` column + seed; capability read from `TerminalPlcDevice`; `onStartup` → `session.custom.closureMethod`.
3. **Config-driven resolution in procs** — `Assembly_CompleteTray` (+ `Container_Open`) resolve config by `(ItemId, ClosureMethod)` instead of TOP-1-by-ItemId.
4. **Changeover action** — elevated mutation proc + `Changeover` HoldTypeCode + freeze/thaw; header mode chip.
5. **Item Master editor** — ContainerConfig section edits a per-method list.
6. **View three-appearance rework** — Count (reuse) / Weight / Vision conditional; strip hardcoded ByVision chrome.
7. **PLC-driven close (tail)** — Weight + Vision auto-close via the PLC-integration foundation.

Front phases (1–6) deliver the visible fix; phase 7 rides the PLC integration.

---

## 7. Open questions

- **Backfill default** for `ClosureMethod` on existing NULL configs before the NOT-NULL constraint — proposed `ByCount`. Confirm (dev seeds already set explicit methods, so this only affects any hand-created rows).
### Resolved during blast radius

- **Capability is derived, not authored** — from `TerminalPlcDevice → PlcDeviceType.ClosureMethodCode` (§2.2). No `ClosureCapabilities` attribute, no commissioning-editor question. `ByCount` is always in the set.
- **Close-trigger tags are known** — read off the UDTs we built (§4): `NET_TargetWeightMetFlag` (weight), `OkToContinue` (vision). `TargetWeight` on the config feeds `TRG_TargetWeightValue`; `Item.PlcId` feeds the vision `PartNumber` recipe.
- **Serialized assembly view is in scope** — it carries the identical hardcoded-Vision chrome and takes the same three-appearance treatment (not a separate path).
- **Changeover with an open container** freezes it via the existing Hold path (native Open→Hold→Open round-trip); no new container status needed.
- **Live-session staleness** is handled in the changeover handler by assigning `session.custom.closureMethod` directly after the proc (§3).

### Verify during implementation (not blockers)

- `Quality.Hold_Place` permits holding an **Open(1)** container (tests only exercised Complete/Shipped).
- AD elevation `_validateAdCredentials` seam is a stub — end-to-end changeover needs it wired (or a dev bypass) to test on real hardware.
- `Container_Open` is always called with the `(ItemId, method)`-correct `ContainerConfigId` (the safety of the downstream SAFE procs depends on it).
