# 2026-07-17 — Assembly-Out Closure Method (design + plan)

## What this session produced

Designed and planned the assembly-out **closure-method** feature (Count / Weight / Vision). Two docs committed to `jacques/working` (3 commits, not yet pushed):

- **Spec:** `docs/superpowers/specs/2026-07-17-assembly-closure-method-terminal-mode-design.md` (`103303b6`, refined in `7fd162fd`)
- **Plan:** `docs/superpowers/plans/2026-07-17-assembly-closure-method-terminal-mode.md` (`8dc3dd9a`) — 16 tasks, 6 phases.

## The model we landed on (after several iterations)

Trigger: the AssemblyNonSerialized view shows hardcoded ByVision camera chrome even when the container's real closure method is By Count — decorative, unbound to any tag/config.

Final design:
- **`ContainerConfig` goes 1-many per part, keyed by `(ItemId, ClosureMethod)`.** Each config is a full pack-out (its own PartsPerTray/TraysPerContainer/Dunnage/TargetWeight). Example: same FG → Honda `ByVision` 12×8, other customer `ByCount` 1×48. **No customer model** — the configs aren't keyed by customer.
- **Terminal carries a persisted `CurrentClosureMethod` mode** (EAV attr, like DefaultScreen) that **selects among** the part's configs. Zero per-container operator choice.
- **Capability is derived, not stored** — from `TerminalPlcDevice → PlcDeviceType.ClosureMethodCode` (ScaleStation→ByWeight, TrayInspectionStation→ByVision, MIP types NULL, ByCount always). `ClosureCapabilities` attribute was dropped.
- **Changeover = elevated shop-floor action** (supervisor AD elevation, audited, persists). Swapping with an open container **freezes it** via the existing `Quality.Hold_Place` path (Open→Hold→Open native round-trip).
- **Close triggers read off the UDTs we built:** `ScaleStation.NET_TargetWeightMetFlag` (+ `TargetWeight`→`TRG_TargetWeightValue`); `TrayInspectionStation.OkToContinue` (+ `Item.PlcId`→`PartNumber` recipe, `VisionPartNumber` read-back). These belong to the **PLC auto-close tail (Phase 7 — separate follow-on plan)**.

## Rejected turns (don't relitigate)
- Customer/pack-out as the discriminator → **rejected** ("I do not want to manage customers").
- Operator picks method per container → **rejected** (non-starter).
- `ClosureCapabilities` as a hand-authored attribute → **rejected** (derive from PLC device type).

## Blast radius (four parallel Explore passes, folded into spec §5)
- One hard SQL break: `Assembly_CompleteTray:125-130` TOP-1-by-ItemId → resolve by (ItemId, method).
- `ContainerConfig_Create` drop one-per-item rule + method required; `_Update` method immutable; `_GetByItem` now 0-N rows.
- Container-consuming procs (`Container_Open/_Complete/_GetOpenByCell/ContainerTray_Close`) are SAFE (pin `ContainerConfigId`).
- Test fixtures already supply ClosureMethod (no hard test breaks); soft: `0008/020` Test 5 invert, `0005/010` HoldTypeCode count 3→4.
- Views: both AssemblyNonSerialized + AssemblySerialized carry the hardcoded-vision chrome; Item Master ContainerConfig editor → per-method list.

## Plan execution shape
- Phases 1-4 (schema, terminal/capability, proc resolution, changeover) = red/green TDD against `Run-Tests.ps1`, agent-executable.
- Phases 5-6 (Item Master editor, assembly views, chip) = **Designer-driven** per the view-edit boundary — build-specs + scan/verify, need a Designer session.
- Phase 7 (PLC auto-close watchers) = follow-on plan, hardware/elevation-seam dependent.
- Verify-before-apply: exact `LocationAttributeDefinition` column set vs `0002`/`0020`; `HoldTypeCode`/`LogEventType` seed ids.

## Housekeeping
- The background Explore agent "Map legacy OPC tags to closure triggers" **failed** (process exited mid-run). No loss — superseded by reading the UDT JSON directly (`ignition/tags/udt/*.json`).
- Next free versioned migration ids: `0039`, `0040`.

## IMPLEMENTATION STATUS (updated end of session)

Executed the plan against a throwaway `MPP_MES_Test` (never touched `MPP_MES_Dev`/the gateway). Full suite: **2110 passing / 8 failing — all 8 pre-existing** (0027 Machining + 077 Lot_Search, Jacques's in-flight `MachiningIn` route-aware + `Lot_Search` location commits; zero closure dependency; my work added only passing tests).

**DONE + committed + pushed** (`jacques/working`):
- Migrations **0040** (ClosureMethodCode + ContainerConfig re-key to `(ItemId, ClosureMethod)` NOT NULL + FK) and **0041** (PlcDeviceType.ClosureMethodCode map + terminal CurrentClosureMethod/VisionAppUrl attrs + Changeover HoldTypeCode + ClosureModeChanged LogEventType). *(0039 was already taken by plc_handshake_audit — bumped from the plan's 0039/0040.)*
- Procs: `ContainerConfig_Create` (method required, per-(item,method) unique), `_Update` (method immutable), `_GetByItem` (0-N rows), new `_GetByItemAndMethod`, `Assembly_CompleteTray` (resolve by (item,method) + no-pack-out block), new `Terminal_GetClosureContext` (derived capability), new `Terminal_SetClosureMethod` (elevated changeover, freezes open container via inlined Hold_Place mirror).
- Tests: new 025/026/027 (0008), 030/031/032 (0020), 093 (0028); fixed 020/020-cascade (0008), 010 quality-codes count 3→4, 092/077/095 CompleteTray callers, seed_demo.
- Ignition: onStartup stashes `session.custom.closureMethod`/`closureCapabilities`; `Terminal.getClosureContext` (defensive) + NQ; `Location.ClosureMode.changeover` + NQ; `ContainerConfig.getByItemAll`/`getByItemAndMethod` + NQ; `Assembly.handleTrayComplete` routes closureMethod; `Assembly_CompleteTray` NQ closureMethod sqlType 7→12.

**DONE 2026-07-20 (session 2): SQL deployed to Dev + Perspective UI built.**
- **SQL deployed to `MPP_MES_Dev` nondestructively** (no reset): migrations 0040/0041 applied idempotently (must use `sqlcmd -I` for QUOTED_IDENTIFIER on the filtered-index UPDATE) + 7 changed/new procs (CREATE OR ALTER). Verified: ClosureMethodCode seeded, new index + NOT NULL live, `Terminal_GetClosureContext` returns caps. Dev's 1 ContainerConfig row (ByCount) backfilled cleanly.
- **Perspective UI built (3 parallel subagents) + deployed via scan.ps1**, committed:
  - AssemblyNonSerialized + AssemblySerialized: three appearances (Count/Weight/Vision) gated on `session.custom.closureMethod`; method chip opens the ChangeoverElevation popup; ByVision embeds `session.custom.terminal.visionAppUrl` via `ia.display.inline-frame`; Complete Tray passes closureMethod. (Serialized has no count/close controls — MIP-driven — so its Count/Weight panels are status-only.)
  - New popup `BlueRidge/Components/Popups/ChangeoverElevation`: capability-limited method dropdown + AD account/password → `ClosureMode.changeover` → writes `session.custom.closureMethod`.
  - Item Master ContainerConfig editor: per-method (ByCount/ByWeight/ByVision) list, atomic state, Save loops add/update. **Regenerated whole file (sorted keys) — structural anchors verified but NEEDS Designer/runtime click-through.**

**Still open / decisions for Jacques:**
- **Runtime click-through** of all three screens + the changeover (needs a terminal with a mode set) — I couldn't drive a live Perspective session here.
- **`session-props/props.json`** still uncommitted (closure declarations + ambient pickled-terminal state DC1-T1/Indianapolis). scan deployed it (declarations needed at runtime); COMMIT the declarations + decide on the pickle.
- **Item Master editor dropped `IsSerialized` + `CustomerCode` inputs** (carried through, not editable). Decide if `IsSerialized` needs to stay editable per-method.
- **AD elevation `_validateAdCredentials` is a stub** (rejects all) → the changeover popup can't complete end-to-end until wired; test the proc directly meanwhile.

**Original remaining items (still valid):**
1. **`session-props/props.json`** — I added `closureMethod`/`closureCapabilities` declarations but LEFT THE FILE UNCOMMITTED because it carries ambient **pickled live-terminal state** (`DC1-T1`/id 15, timeZone → America/Indianapolis leaked into defaults). Review + commit the closure declarations; consider discarding the pickled defaults.
2. **Designer view tasks (plan Tasks 11, 13, 15, 16)** — three-appearance conditional on both AssemblyNonSerialized + AssemblySerialized (Count/Weight/Vision off `session.custom.closureMethod`), the header changeover mode-chip (elevation popup → `ClosureMode.changeover`, then assign `session.custom.closureMethod` locally), and the Item Master ContainerConfig editor going per-method-list (load via `getByItemAll`). File-edit boundary → do in Designer.
3. **Deploy sequence:** apply migrations 0040/0041 to `MPP_MES_Dev` → `.\scan.ps1` (deploys the NQs/scripts) → Designer view work → wire the Complete Tray button to pass `self.session.custom.closureMethod` into `handleTrayComplete`.
4. **Phase 7 (PLC auto-close)** — separate follow-on plan (Weight `NET_TargetWeightMetFlag` / Vision `OkToContinue` watchers). Not started.

## Where we stand (git)
- `jacques/working` is **3 commits ahead of `origin/jacques/working`** (the spec+plan docs) and **0 behind / 3 ahead of `origin/main`** — no divergence from main.
- Pre-existing uncommitted working-tree changes (session-props, `global-props/data.bin`, NavigationTree/LotSearch resource.json) are **ambient** (gateway/Designer/other session), NOT part of this work — left untouched.
