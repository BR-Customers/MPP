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

## Where we stand (git)
- `jacques/working` is **3 commits ahead of `origin/jacques/working`** (the spec+plan docs) and **0 behind / 3 ahead of `origin/main`** — no divergence from main.
- Pre-existing uncommitted working-tree changes (session-props, `global-props/data.bin`, NavigationTree/LotSearch resource.json) are **ambient** (gateway/Designer/other session), NOT part of this work — left untouched.
