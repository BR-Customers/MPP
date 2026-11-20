# Named pack-outs, selectable per terminal -- design

**Status:** DRAFT for Jacques's review (2026-11-20). Nothing built.
**Origin:** first real Digi press on prod terminal 215 (`66V-insp`, 19321-66V-A100), 2026-11-20. Jacques asked for pack-out configs to be savable and selectable with a button, because running a different container for the same part currently means overwriting the part's one config.

## 1. Intent

A finished good can go out in more than one container: Tom Davis's example is **cardboard vs tote**, which differ in parts per tray, trays per container and gross weight. Today `Parts.ContainerConfig` holds exactly one active pack-out per (part, closure method), so switching container means someone opens the Pack-Out popup and overwrites it, and switching back means overwriting it again.

On the floor a new run starts when the operator or a supervisor brings over skids of a different container. The person who knows the container changed is standing at the station. So:

- a part keeps **several named pack-outs** per closure method;
- the **station's existing Pack-Out popup** shows **one button per saved pack-out** for the part; tapping one makes it the pack-out this terminal runs; the build area stays so a new one can be created;
- the Config Tool Item Master shows and edits the same named pack-outs.

## 2. Decisions (Jacques, 2026-11-20)

| # | Decision |
|---|---|
| D1 | The selection belongs to the **terminal**. |
| D2 | Switching pack-out is **refused while the station has an open box** (of that part and closure method). Finish or close the box first -- the running-part rule operators already know. |
| D3 | A pack-out is identified by a **required free-text name** ("Tote", "Cardboard"). Dunnage Code stays an optional field. |
| D4 | One pack-out per (part, closure method) is flagged **default**; a terminal with no pick runs the default. |
| D5 | **Editing a pack-out's values retires the old version and saves a new version under the same name.** Every box keeps the exact numbers it was packed to; a terminal's pick follows the pack-out to its new version. |
| D6 | All three closure methods (By Count / By Weight / By Vision) get named pack-outs, one model. |
| D7 | The Config Tool Item Master Container Config tab becomes a full editor for named pack-outs (list, add, edit, set default, remove) -- same abilities as the station popup. |
| D8 | Approach 2 (below): a pack-out header with versions under it. |
| D9 | The stored procedures in the blast radius must stay performant -- measured, not assumed (section 9). |
| -- | A scale code maps to a **part**, never to a pack-out (Tom via Jacques, 2026-11-20). The Digi scale-code mapping work is independent of this. |

## 3. Goals, non-goals, anti-goals

**Goals**
- Several named pack-outs per part and closure method; one is the default.
- One tap at the station switches the terminal's pack-out; the next box opens on it.
- Every box records the exact pack-out version it was packed to, forever.
- Every place that today asks "what is this part's pack-out?" asks "what is this part's pack-out **at this terminal**?" and gets one answer from one SQL rule.
- No change in behaviour on release day: every existing config becomes its part's default pack-out, so every terminal runs what it runs today.

**Non-goals**
- Scale code -> pack-out mapping (decided against).
- Changing labels or AIM: nothing in the label or AIM path reads `DunnageCode` / `CustomerCode` or the pack-out values beyond the box's own trays (verified by grep 2026-11-20).
- A per-line or plant-wide selection.
- Re-targeting an open box.

**Anti-goals (a failure even if it works)**
- A box judged against a different container's target weight than the one it was opened on.
- A finished box whose record shows numbers it was not packed to.
- Two screens (popup vs Item Master, or screen vs scale close) disagreeing about which pack-out is running.
- Any hot path (scale press, tray close, the 5-second station reads) getting measurably slower, gaining Lots.Lot reads, or going parallel (the 2026-11-10 incident).

## 4. How it works today (blast radius, read 2026-11-20)

`Lots.Container.ContainerConfigId` (NOT NULL FK) is stamped when a box opens. Everything that reads **a box** goes through it and needs no change:
`Lots.ContainerTray_Close`, `Lots.Container_Complete`, `Lots.Container_GetOpenByCell`, `Lots.ContainerRework_*` (Get / ListAtLocation / ListTargets / MovePieces / Resume / Scrap), `Workorder.ScaleStation_GetPressLog`. None of them filter on `DeprecatedAt`, so a box on a retired version still reads correctly (the builder confirms this per proc).

Everything that reads **"the part's config for a method"** looks it up by `(ItemId, ClosureMethod, DeprecatedAt IS NULL)` and must change:

| Reader | Where | Today |
|---|---|---|
| `Workorder.Assembly_CompleteTray` | SQL write path | step 4b picks the config when it must open a box; the open box is then found by **Item**, and the resolved `PartsPerTray` / `TraysPerContainer` set the target -- even for a box opened on other values |
| `Parts.ContainerConfig_JudgeWeight` | SQL, per scale press | window from the part's config |
| `Workorder.Assembly_GetTraysRemaining` | SQL read | `PartsPerTray` from the part's config |
| `Workorder.ScaleStation_GetRunningPart` | SQL read, per press + screen | config columns from the part's config, not the open box's |
| `Workorder.ufn_ScaleStationEligibleParts` | SQL function | "has a By Weight pack-out with PartsPerTray > 0" + parts-for-a-tray ranking |
| `Location.Terminal_SetScaleRunningPart` | SQL | open-box check joins config for `ByWeight` (box-based, fine) |
| `Parts.ContainerConfig_GetByItemAndMethod` | SQL -> Python `getByItemAndMethod[OrEmpty]` | used by `Assembly.resolvePlcCloseContext` (pieceCount), `Assembly._recommendedWithPackout`, `ScaleWatcher` (IND570 setpoint push), `AssemblyNonSerialized` `fgConfig` (parts-per-tray prefill + Flow A setpoint push) |
| `Parts.ContainerConfig_JudgeWeight` -> Python `judgeWeight` | `ScaleEPrintWatcher`, `ScaleDigiWatcher` | by (item, "ByWeight") |
| `Parts.ContainerConfig_GetByItem` -> `getByItemAll` | Item Master tab | one row per method |
| `Parts.ContainerConfig_Create / _Update / _Deprecate` | Item Master tab, `saveDraft` (popup) | `_Update` overwrites in place (the source of D5's problem) |
| `Parts.ContainerConfig_ListHistory` -> `getHistoryForItem` | popup "Load a previous pack-out" | rebuilt from audit + deprecated rows |
| `Parts.Item_Deprecate` | SQL | cascades deprecation to the part's configs |

Ignition surfaces: `MPP/.../Popups/PackOutEdit` (opened by the Pack-Out button on `Views/ShopFloor/AssemblyNonSerialized`, shown where the host sets `allowPackOutEdit` -- today `ThirdPartyInspection`), `MPP_Config/.../ItemMaster/ContainerConfig` (+ its how-to popup), Core `BlueRidge.Parts.ContainerConfig`.

Other code that touches the table and must keep working: `sql/seeds/020_seed_items.sql`, `sql/seeds_demo/*`, `sql/scripts/Export-ProdConfig.ps1`, `sql/scripts/Deploy-Prod.ps1`, `R__Descriptions_ExtendedProperties.sql`, and **44 test files that INSERT into `Parts.ContainerConfig` directly** as fixtures.

## 5. Approaches considered

1. **Name + default + lineage key on `ContainerConfig` itself.** Fewest tables, but name and default are copied onto every version row; a rename or default change rewrites rows boxes point at or mints a fake version; keeping a terminal's pick across versions goes through the lineage key. Rejected.
2. **Pack-out header with versions under it (chosen).** `Parts.PackOut` holds identity (part, method, name, default); `Parts.ContainerConfig` rows become its versions. Boxes keep pointing at the exact version, so every box-reading proc is untouched; a terminal pick points at the header, so it survives edits and renames. Matches how BOMs / routes / quality specs carry versions under one identity.
3. **Terminal stores a config Id; an edit re-points terminals.** Fragile: every edit must find and rewrite every terminal pick. Dropped.

## 6. Data model (migration `0135_named_pack_outs`)

Prod is at `0134`; `0118`, `0120`-`0133` ship with the SP-review bundle under `-AllowOutOfOrder`; container-as-LOT (PR #16) holds `0119`. `0135` is free on every branch (checked 2026-11-20).

### 6.1 `Parts.PackOut` (new) -- the identity

| Column | Type | Notes |
|---|---|---|
| `Id` | BIGINT IDENTITY PK | |
| `ItemId` | BIGINT NOT NULL FK `Parts.Item` | |
| `ClosureMethod` | NVARCHAR(20) NOT NULL FK `Parts.ClosureMethodCode(Code)` | same string-code FK convention as `ContainerConfig.ClosureMethod` (0040) |
| `Name` | NVARCHAR(50) NOT NULL | free text, trimmed, non-empty; ASCII-only in seeds |
| `IsDefault` | BIT NOT NULL | |
| `CreatedAt` / `CreatedByUserId` | DATETIME2(3) / BIGINT FK AppUser | UTC |
| `UpdatedAt` / `UpdatedByUserId` | NULL | rename / default change |
| `DeprecatedAt` / `DeprecatedByUserId` | NULL | soft delete |

Indexes:
- `UQ_PackOut_ActiveName` UNIQUE `(ItemId, ClosureMethod, Name)` WHERE `DeprecatedAt IS NULL`
- `UQ_PackOut_ActiveDefault` UNIQUE `(ItemId, ClosureMethod)` WHERE `IsDefault = 1 AND DeprecatedAt IS NULL` -- at most one default
- "at least one default while any active pack-out exists" is enforced by the procs (section 7), not a constraint.

### 6.2 `Parts.ContainerConfig` (changed) -- the versions

- `+ PackOutId BIGINT NOT NULL FK Parts.PackOut` (added NULL, backfilled, then NOT NULL)
- `+ VersionNumber INT NOT NULL`
- `+ CreatedByUserId BIGINT NULL FK AppUser` (versions are now created by people; the original table never recorded who) -- builder's call whether to add `DeprecatedByUserId` too.
- `ItemId` and `ClosureMethod` **stay** (denormalised from the header, written by the procs, never changed). Every box-reading proc reads `cc.ClosureMethod` today; keeping it avoids touching ten procs. The procs guarantee they equal the header's.
- `UpdatedAt` stays but is no longer written (versions are immutable).
- Drop `UQ_ContainerConfig_ActiveItemMethod` (it is the one-per-method rule this feature removes).
- Add `UQ_ContainerConfig_ActivePackOut` UNIQUE `(PackOutId)` WHERE `DeprecatedAt IS NULL`, INCLUDE the pack values -- one active version per pack-out, and the resolver's covering seek.
- Add UNIQUE `(PackOutId, VersionNumber)`.

### 6.3 `Location.TerminalPackOutSelection` (new) -- the terminal's pick

| Column | Type |
|---|---|
| `Id` | BIGINT IDENTITY PK |
| `TerminalLocationId` | BIGINT NOT NULL FK `Location.Location` (LTD 7) |
| `ItemId` | BIGINT NOT NULL FK `Parts.Item` |
| `ClosureMethod` | NVARCHAR(20) NOT NULL FK `Parts.ClosureMethodCode(Code)` |
| `PackOutId` | BIGINT NOT NULL FK `Parts.PackOut` |
| `SetByUserId` / `SetAt` | BIGINT FK AppUser / DATETIME2(3) UTC |

`UQ_TerminalPackOutSelection` UNIQUE `(TerminalLocationId, ItemId, ClosureMethod)` INCLUDE `(PackOutId)`.

**One pick per terminal per part and method** (my call): a scale station changes running part on its own (`ScaleStation_GetRunningPart`), so returning to 66V should bring back "Tote" rather than the default. A table, not a terminal attribute, because the attribute model holds one value per terminal. The row is updated in place; the history is the audit row (`Audit.OperationLog`, event `PackOutSelected`), the same model as `Terminal_SetScaleRunningPart`.

A pick whose pack-out is later deprecated is ignored by the resolver (falls back to the default); `PackOut_Deprecate` also deletes picks pointing at it, in the same transaction.

### 6.4 Backfill (inside `0135`)

Per existing `(ItemId, ClosureMethod)` group in `ContainerConfig`:
- one `PackOut` header, `Name` = the method's display name ("By Count" / "By Weight" / "By Vision"), `IsDefault = 1`;
- every row in the group (active and deprecated) becomes a version of that header, `VersionNumber` by `CreatedAt, Id`;
- if the group has no active row, the header is deprecated (`DeprecatedAt` = the latest row's) and `IsDefault = 0`;
- `CreatedByUserId` on the backfilled headers = SYS (AppUser 1).

So every terminal resolves to exactly the row it uses today. A pre-flight gate (section 10) proves it on the target.

## 7. Procedures

All follow `_TEMPLATE_stored_procedure.sql`, FDS-11-011 (one result set, no OUTPUT, status-row mutations, rejections before `BEGIN TRANSACTION`), and the audit Description convention.

### 7.1 New

| Proc | What it does |
|---|---|
| `Parts.ufn_ResolvePackOut(@ItemId, @ClosureMethod, @TerminalLocationId)` | **Inline** table-valued function (never scalar, never multi-statement). Returns at most one row: `ContainerConfigId, PackOutId, PackOutName, VersionNumber, Source ('Selected' | 'Default'), PartsPerTray, TraysPerContainer, TargetWeight, ToleranceWeight, IsSerialized, DunnageCode, CustomerCode`. Rule: the terminal's active pick, else the active default; the pack-out's active version. `@TerminalLocationId` NULL = default only. **The one rule**; every reader in section 7.2 uses it. |
| `Parts.PackOut_ListByItem(@ItemId, @TerminalLocationId = NULL)` | Read for the buttons and the Item Master: active pack-outs with their active version's values, `IsDefault`, and (with a terminal) `IsSelected` (the terminal's explicit pick) and `IsRunning` (what the resolver returns). Ordered method, default first, then name. |
| `Parts.PackOut_Save` | Bundled save of one pack-out (the `LocationTypeDefinition_SaveAll` precedent). `@PackOutId` NULL = create header + version 1 (`IsDefault = 1` when it is the part's first active pack-out for that method). Otherwise: a name change updates the header; **any pack-value change deprecates the active version and inserts version N+1** (D5); no change = rejected as no-op. Validation moves here from Python `saveDraft` (positive trays / parts per tray; By Weight needs positive target and positive tolerance). Returns `NewId` = PackOutId. Audits to `Audit.ConfigLog`. |
| `Parts.PackOut_SetDefault(@PackOutId)` | Moves the default flag within (part, method), in one transaction. |
| `Parts.PackOut_Deprecate(@PackOutId)` | Deprecates header + active version, deletes terminal picks on it. **Refuses the default while other active pack-outs exist** (pick a new default first) -- my call, so "always a default" holds without a silent auto-promotion. Deprecating the only pack-out is allowed (the part then has none for that method, as clearing does today). |
| `Location.Terminal_SetPackOut(@TerminalLocationId, @PackOutId, @AppUserId)` | Sets the terminal's pick for that pack-out's (part, method). **D2:** refuses while there is an open box the next tray of that part would go into at this terminal (section 7.1a). Refuses a deprecated pack-out and a no-op. Any PIN-signed-in operator; the audit row is the control (same as the running-part override). `@PackOutId` NULL is not offered -- picking the default is just picking it. |

### 7.1a The open box wins, everywhere (builder check, my call)

"The pack-out in force" for a (terminal, part) is: **the open box `Assembly_CompleteTray` would put the next tray into, if there is one -> that box's own version; otherwise `ufn_ResolvePackOut`.** Every reader uses this one rule -- `CompleteTray`, `JudgeWeight`, `GetRunningPart`, `GetTraysRemaining`, `GetByItemAndMethod` (and so the PLC close's piece count, the `fgConfig` prefill and the Flow A setpoint push). Otherwise, after an edit mid-box, the PLC would send the new `PartsPerTray` and `CompleteTray` would refuse it against the box's old one, and the scale would be set up for weights the tray is not judged against.

"The box `CompleteTray` would use" means its existing lookup, unchanged: the station's own open box of that part; else an unowned open box of that part at the line; else (caller is not a terminal) the oldest open box of that part at the line. This lookup is factored into one inline function (e.g. `Lots.ufn_ContainerForNextTray`) that `CompleteTray` and the readers share, so they cannot drift. `CompleteTray`'s lookup is by part only, not closure method, as today.

**D2 uses the same box:** `Terminal_SetPackOut` refuses while that function returns a box for the pack-out's part at this terminal -- whatever that box's closure method. This is D2's intent ("finish or close the box first") applied to the exact box the next tray would go into.

Readers return which one they used: `+ PackOutSource` = `OpenBox | Selected | Default`.

### 7.2 Changed (each gets a version bump)

| Proc | Change |
|---|---|
| `Workorder.Assembly_CompleteTray` | 4b resolves through `ufn_ResolvePackOut(@FinishedGoodItemId, @ClosureMethod, @StationLocationId)`. **When an open box is found, its own `ContainerConfigId` governs `PartsPerTray` / `TraysPerContainer` / target for that box**, not the resolved values; a newly opened box is stamped with the resolved version. The piece-count validation that today runs against the resolved `PartsPerTray` before the box is found must use the box's value when a box exists (builder decides the restructure; the FIFO / locking logic of the proc is **not** touched -- it is a flagged write path in the SP review). No new locks: a pick changed between resolve and box-open just means the box opens on the previous pick, consistently. |
| `Parts.ContainerConfig_JudgeWeight` | `+ @TerminalLocationId BIGINT = NULL`. Window = the station's open box's version when one exists (same open-box rule as `GetRunningPart`), else `ufn_ResolvePackOut`. Result set unchanged except `+ PackOutName`. Called without a terminal it behaves as today (default pack-out). |
| `Workorder.Assembly_GetTraysRemaining` | `+ @TerminalLocationId = NULL`, `PartsPerTray` via the resolver. Result set unchanged. Must build on the `origin/main` v1.1 (PR #9, requires 0118). |
| `Workorder.ScaleStation_GetRunningPart` | config columns from the **open box's version** when a box is open, else the resolver for the running part at this terminal. `+ PackOutId, PackOutName, PackOutSource` columns (appended; callers read by name). |
| `Workorder.ufn_ScaleStationEligibleParts` | "has a By Weight pack-out" and the parts-for-a-tray ranking use the **resolved** pack-out at `@TerminalLocationId`. Must build on the `origin/main` v1.2 (PR #24, literal `LotStatusId <> 4`) and keep its measured shape. |
| `Parts.ContainerConfig_GetByItemAndMethod` | `+ @TerminalLocationId = NULL` -> resolver; `+ PackOutId, PackOutName, Source`. |
| `Parts.Item_Deprecate` | cascade also deprecates the part's `PackOut` headers and deletes their terminal picks. |
| `Parts.ContainerConfig_Create / _Update / _Deprecate` | **Dropped** (replaced by `PackOut_Save` / `_Deprecate`). `_Update` must not survive -- it is the in-place overwrite D5 removes. Named queries removed with them. |
| `Parts.ContainerConfig_GetByItem` | Replaced by `PackOut_ListByItem` for the Item Master; drop it if nothing else calls it (builder greps). |
| `Parts.ContainerConfig_ListHistory` | The popup stops using it (the buttons are the reusable history now). Builder's call: drop it with its NQ, or keep it unused for a later version-history view. |

## 8. Ignition

### 8.1 Station popup `MPP/.../Popups/PackOutEdit`

Per closure-method section (layout unchanged otherwise):

```
By Weight
[ * Cardboard          ] [  Tote               ] [ + New ]
[ 6/tray x 1  15.0 lb  ] [ 8/tray x 4  62.0 lb ]
  RUNNING                                         
Name [Cardboard     ]  Parts/tray [6]  Trays [1]  Target [15.0]  Tol [1.35]
Dunnage [      ]  Serialized [ ]                 [Make default] [Remove]
```

- One button per active pack-out: name, its numbers, a default marker, and the one running at this terminal highlighted (`PackOut_ListByItem` with the session terminal).
- **Tapping a button selects it for this terminal** (`Terminal_SetPackOut`) and loads it into the fields below. A refusal (open box, D2) shows the proc's message as a toast and loads nothing. *(My call: one tap does both, because "select an existing one" is the main job; editing is the less common one.)*
- `+ New` clears the fields for a new named pack-out. Save -> `PackOut_Save` (a new version when an existing one's values changed). A new pack-out is not auto-selected; the operator taps it (my call -- avoids a save quietly switching a running station; Jacques may prefer auto-select).
- `Make default`, `Remove` -> `PackOut_SetDefault` / `PackOut_Deprecate`.
- "Load a previous pack-out..." and the per-section Clear go away.
- At a non-terminal session (unregistered IP, facility fallback) the buttons show but selecting is disabled with a reason.
- Save / select / default / remove each send `packOutChanged` (existing message) so `AssemblyNonSerialized` re-reads `fgConfig` -- which keeps Flow A's setpoint push working on a switch.

### 8.2 Station screens

- `AssemblyNonSerialized` `fgConfig` and every Python `getByItemAndMethod` / `judgeWeight` caller pass the terminal (`session.custom.terminal.terminalLocationId` in views; the watcher's own terminal in gateway scope). `Assembly.resolvePlcCloseContext`, `_recommendedWithPackout`, `ScaleWatcher` setpoint push, `ScaleEPrintWatcher`, `ScaleDigiWatcher`.
- The station header shows the running pack-out's name next to the part (from `GetRunningPart` / `fgConfig`). *(My call; small.)*

### 8.3 Config Tool `MPP_Config/.../ItemMaster/ContainerConfig`

Rebuilt to the same model: per method, a list of the part's pack-outs (name, values, default marker, version number), add / edit / make default / remove, through the same procs. Keeps the per-section ownership pattern (own `state.selected` / `state.editDraft`, atomic state writes, `sectionDirtyChanged`, ConfirmUnsaved on navigation). No terminal context: it never selects. The how-to popup text is updated.

### 8.4 Core `BlueRidge.Parts.ContainerConfig`

`saveDraft` / `getDraftForItem` / `getHistoryForItem` / `add` / `update` / `deprecate` are replaced by thin wrappers over the new procs (`listForItem`, `save`, `setDefault`, `deprecate`, `select`). No business rules in Python: validation lives in `PackOut_Save`. Every mutation takes `appUserId` from its caller (CLAUDE.md attribution rule).

## 9. Performance (D9)

The config tables are tiny (Dev: 51 config rows; prod a few hundred), so the risk is not the new tables -- it is **changing the plan shape** of procs that also read `Lots.Lot` / `Lots.Container`, three of which were tuned in the SP review (PR #9, #24, 0118).

Rules:
- `ufn_ResolvePackOut` is an inline TVF and every lookup in it is an index seek on the indexes in section 6. No scalar UDFs anywhere in the path.
- Readers apply the resolver **once per call** (a variable or a single `CROSS APPLY` on the already-chosen item), never inside a per-LOT loop. `ufn_ScaleStationEligibleParts` resolves per finished good at the line (a handful), joined before its stock aggregate, keeping PR #24's literal `LotStatusId <> 4`.
- No new lock hints or transactions in `Assembly_CompleteTray`.

Measurement (the acceptance test, recorded in the PR):
- On `MPP_MES_Bench` (the 5.5M-LOT bench used by the SP review; harness pattern in `notes/sp-review-handoff/perf/`), capture `SET STATISTICS IO, TIME` and the actual plan **before** (base branch) and **after** for: `ScaleStation_GetRunningPart`, `ScaleStation_ListEligibleParts` (the function), `ContainerConfig_JudgeWeight`, `Assembly_GetTraysRemaining`, `ContainerConfig_GetByItemAndMethod`, and `Assembly_CompleteTray` (inside a rolled-back transaction).
- Pass = no increase in logical reads on `Lots.Lot`, `Lots.Container`, `Lots.ContainerTray`; the new tables add single-digit reads; no plan goes parallel that was serial; elapsed time within noise.
- Same result rows and columns as before for terminals with no pick (the release-day no-change promise), checked by a before/after comparison script like the 0118 one.

## 10. Release and branch

- **Branch:** one branch `sp/parts-PackOut`, one PR, using the CLAUDE.md SP-rule exception ("cannot land separately": one migration + the procs that read its columns). Never `main` / `jacques/working`; never prod. Jacques merges.
- **Base:** see open question Q1.
- **Pre-flight gate for the release** (written per `prod-release-context-pack/04_preflight_gates.md`): after `0135`, for every terminal and every finished good with an active config, `ufn_ResolvePackOut` returns the same `ContainerConfigId` the old `(ItemId, ClosureMethod, active)` lookup returned; zero differences, or BLOCK.
- **Tests:** new `sql/tests/0135_PackOut/` (resolver precedence; pick per part; deprecated pick falls back; save creates / versions / renames / no-op; default uniqueness and the refuse-deprecate-default rule; `Terminal_SetPackOut` refused with an open box; `CompleteTray` keeps an open box on its own version after an edit; `JudgeWeight` judges against the open box's version; backfill shape). The 44 fixture files that insert into `Parts.ContainerConfig` are updated mechanically to insert a `PackOut` header first. Python: the existing `tools/test_scale_*` style tests cover the watcher call changes. Suite assertion count before and after, per the SP rule.
- **Docs:** Data Model (new table, changed columns), `PROJECT_STATUS.md`. The FDS is not edited to match the build.
- Prod packaging per "Production deployments" only if Jacques asks.

## 11. Open questions

- **Q1. Base branch.** `origin/main` lacks the Digi feed (PR #36, deployed to prod from `release/2026-11-19-digi-scale-feed`, **not merged**), and `ScaleDigiWatcher` is one of the callers that must pass the terminal. Options: wait for #36 to merge and branch from `main`; or branch from `feature/digi-scale-feed` and retarget when #36 merges.
- **Q2. Container-as-LOT (PR #16, open)** rewrites `Assembly_CompleteTray`'s box handling. Whichever merges second rebases onto the other.

## 12. Left to the builder

Exact restructure of `Assembly_CompleteTray` step 4b / box lookup (within the constraint above); whether `ContainerConfig_ListHistory` is dropped; audit event codes and Description wording; popup layout details within the sketch; the perf harness script; the mechanical fixture rewrite approach.
