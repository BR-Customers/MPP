# Convention Rectification Review — 2026-05-14

**Context:** Hunter's branch (`hunter/explore`) merged to `main` 2026-05-14. The `ignition-context-pack/` now reflects `MPP_MES_CONFIG_TOOL_FRONTEND_CONVENTIONS.md` v1.2 + documents the SaveAll bundled pattern. Our 2026-05-12/13 Ignition work (commits `f9fc9fc` + `c2438be`) was built against the older pack and deviates in several places.

**This document:** Line-by-line response sheet for Jacques to mark up and return. Each item has a fixed ID, the observation/proposal, and a `Decision:` / `Notes:` block to annotate. Decision shorthand suggestions: **Accept** (do it), **Reject** (keep current), **Modify** (do it differently — explain in Notes), **Defer** (later, not now), **Discuss** (need a conversation).

---

## A — Architectural deviations

### A1. The Common.Db / Common.Ui / Common.Util layer doesn't exist

**Observation:** `BlueRidge/Common/Db`, `Common/Ui`, `Common/Util` are empty placeholder folders. Entity scripts skip the helper layer and call `system.db.execQuery` / `runNamedQuery` directly. 7 direct-call sites across 6 modules; 5 modules each have their own copy of `_rowsToDicts(ds)`.

**Proposal:** Implement the three Common modules per pack `03_script_python.md`. Centralize `_rowsToDicts` in `Common.Db.execList`.

**Decision:** we should leverage these folders for all procedures that are repeatable accross domains. lock that in.
**Notes:**


---

### A2. Common.Action.runMutation is our parallel-universe execMutation

**Observation:** We built `Common.Action.runMutation(nq, params, successTitle, successMsg, errorTitle)` which does DB call + toast firing + returns `None` on failure. The pack splits this into two orthogonal pieces: `Common.Db.execMutation` (returns the status dict on success AND failure) + `Common.Ui.notifyResult(result, successText)` (routes to UI). Also: pack uses `Status NVARCHAR("OK"/"ERROR")`; our procs use `Status BIT(1/0)`.

**Proposal:** Refit `Common.Action.runMutation` → rename to `Common.Db.execMutation`, drop the toast firing, return the dict on both paths. Add `Common.Ui.notifyResult` that wraps our existing toast. Keep `Status BIT` server-side; document the variant.

**Decision:** do a random pull of 10 SPs from the repo, We build them all to follow a standard convention, those SPs are the rule of LAW for returns wether thats a bit or nvarchar return. pack will need to reflect those SPs return format. verbatam
**Notes:**


---

### A3. No `editDraft` / `selected` split on the LocationTypeEditor

**Observation:** `view.custom` is `{ meta, attributesDraft, mode, selectedDefId, tierId }` — `meta` and `attributesDraft` are the in-flight edit objects with no baseline to compare against. Consequences: no dirty indicator, no Cancel-to-revert, no enforcement of the "discard on selection change" universal rule.

**Proposal:** Replace with `view.custom.selected = { meta, attributes }` (baseline) + `view.custom.editDraft = { meta, attributes }` (in-flight). Add dirty indicator, Cancel-to-revert, refit Save handler.

**Decision:** agree with standard. modify views according
**Notes:**


---

### A4. Entity script module surface diverges from pack

**Observation:** Pack standard: `getAll` / `getOne` / `add` / `update` / `deprecate`. Ours:

| Module | Our names | Pack equivalent |
|---|---|---|
| `Location.Location` | `get`, `getAttributesByLocation`, `handleMoveUp`, `handleMoveDown` | `getOne`, dedicated reorder handlers |
| `Location.LocationType` | `listAll`, `nameForTier` | `getAll` |
| `Location.LocationTypeDefinition` | `listByType`, `handleSaveAll`, `handleDeprecate`, `emptyMeta`, `emptyAttributeRow`, `metaFromDefinition` | `getAll(typeId)`, `saveAll`, `deprecate` + factories |
| `Location.LocationAttributeDefinition` | `listByDefinition` | `getAll(parentId)` |
| `Location.Tree` | `buildTree`, `findPathById`, `getNodeData`, `resolveSelectedId` | (specialized — no pack standard) |

**Proposal:** Standardize on pack naming. `listByType` → `getAll(typeId)`, `listByDefinition` → `getAll(parentId)`, `listAll` → `getAll`. Or write a one-paragraph project ADR justifying the `list*` naming.

**Decision:** that "standard" is the starting point. NOT the complete list. so the Move up, move down content is fine. 
**Notes:**


---

### A5. No `Common.Util.log` helper

**Observation:** Each module declares its own `logger = system.util.getLogger(...)` and calls `logger.debugf` / `logger.errorf` directly. Pack convention: shared `Common.Util.log(msg)` using `inspect.currentframe().f_back` to auto-fill calling module + function.

**Proposal:** Implement `Common.Util.log` per pack. Replace per-module logger declarations with direct calls to the shared function.

**Decision:** implement the Common.Util.Log pack, refactor scripting
**Notes:**


---

### A6. `_currentAppUserId` is in the wrong place

**Observation:** We have `Common.Session.getCurrentUserId()` returning a hardcoded `2` as a dev placeholder. Pack convention: `Common.Util._currentAppUserId()` reading from `system.perspective.getSessionInfo()["custom"]["appUserId"]`.

**Proposal:** Move the function to `Common.Util._currentAppUserId`. Keep the hardcoded dev value in the body until login wiring lands. Optionally have `Common.Session.getCurrentUserId` re-export Util's function for backwards compat.

**Decision:** agreed with proposal
**Notes:**


---

### A7. No RowVersion optimistic locking

**Observation:** `Location.LocationTypeDefinition` and `Location.LocationAttributeDefinition` don't have `RowVersion BIGINT` columns. The SaveAll proc doesn't accept `@RowVersion`. Pack mandates this for versioned entities; the conventions doc generalizes it. LocationTypeDefinition isn't versioned in the Draft/Published/Deprecated sense, but two engineers editing simultaneously would get last-write-wins.

**Proposal (deferrable):** ALTER both tables to add `RowVersion BIGINT NOT NULL DEFAULT 0`; refit SaveAll proc to accept `@RowVersion` and reject on mismatch; refit view to pass through untouched.

**Decision:** location type definition and locationAttributeDefinition are not versioned elements. so why? last write should win in this case.
**Notes:**


---

### A8. NQ resource.json schema inconsistency

**Observation:** `location/Get/resource.json` is `version: 1` (latent — Designer 8.3.5 NPEs on v1 NQ resources per `feedback_ignition_nq_resource_schema.md`). All five 2026-05-13 NQs are `version: 2` (correct).

**Proposal:** Bump `Get/resource.json` to v2, mirroring the field shape from one of the Designer-saved v2 files. Same cleanup-pass treatment for any other v1 NQs lurking.

**Decision:** update context pack to reflect V2 
**Notes:**


---

### A9. sqlType code disagreement

**Observation:** Our NQs disagree on the sqlType for BIGINT:
- `Get/resource.json` — sqlType `-5` (matches pack: -5 = BIGINT)
- `LocationTypeDefinition_SaveAll/resource.json` — sqlType `2` (which is NUMERIC per java.sql.Types)

Memory entry `feedback_ignition_nq_resource_schema.md` says `2` for BIGINT. Pack `04_named_queries.md` says `-5`. SQL Server may be loose; one is right, one is empirically convenient.

**Proposal:** Test empirically in Designer (try both on a BIGINT-param NQ, see which Designer writes / accepts). Pick one, standardize. Update the wrong memory entry.

**Decision:** _____________________________
**Notes:**


---

### A10. Parameter-identifier casing drift

**Observation:** Three casing styles in the same project:
- `Get/resource.json` — identifier `id` (lowercase)
- `LocationTypeDefinition_SaveAll/resource.json` — `Id`, `LocationTypeId`, `AppUserId` (PascalCase)
- `Location.py:123` calls `getLocationAttributes` with `{"LocationID": ...}` (ALL-CAPS trailing D)

Pack uses camelCase (`:itemId` / `@itemId`).

**Proposal:** Pick one casing convention for NQ parameter identifiers + proc `@param` names. Refit drifted NQs and call sites.

**Decision:** follow pack conventions.
**Notes:**


---

### A11. View `runScript` bindings with cache TTL of 0

**Observation:** `LocationTypeEditor/view.json` binds `view.custom.definitions` and `view.custom.tiers` to `runScript(..., 0, ...)`. TTL 0 = no cache. The 5 ISA-95 tiers never change; definitions per tier change rarely. This re-runs the entity-script call on every binding evaluation.

**Proposal:** Either bump TTL to a positive value (e.g., 60s for tiers, 5s for definitions) or load once on view open + manually invalidate after mutations.

**Decision:** I dont want hard coded drop downs, and I dont want consistant polling refresh. so can we load once on view open. and manually refresh if a relevant mutation occurs
**Notes:**


---

## B — Bugs / latent issues

### B1. `print ds` left in `Location.py:124`

**Observation:** Debug residue.

**Proposal:** Strip.

**Decision:** strip
**Notes:**


---

### B2. `Tree.code.py` header comment is malformed

**Observation:** Header mixes module identifier with a function signature; the default-icon string in the comment (`material/place`) disagrees with the actual default (`mpp/factory` at line 31).

**Proposal:** Rewrite header to the standard shape used by other modules.

**Decision:** rewrite header to the standard shape
**Notes:**


---

### B3. Toast view changed between commits — verify final state matches the working dismissAt fix

**Observation:** `Components/Popups/Toast/view.json` was created in `f9fc9fc` and modified in `c2438be`. Memory entry says the `dismissAt` binding fix landed 2026-05-13.

**Proposal:** Diff the current on-disk version against the fix described in `project_mpp_toast_system.md` memory and confirm.

**Decision:** agree with proposal
**Notes:**


---

## C — Things our work should contribute back to the pack

### C1. Toast system (major addition)

**Observation:** Our `Common.Notify.toast` + popup-per-toast Toast view is meaningfully richer than the pack's `NotificationBanner` single-mounted view:

| Feature | Pack | Ours |
|---|---|---|
| Surface | Single banner | Popup-per-toast |
| Stacking | Max 3 | Max 5 (FIFO eviction) |
| Persistence by type | Auto-dismiss by ttl | Errors persist; non-errors 8s |
| Slot management | Implicit | Explicit `STACK_TOP_STEP` |
| Stale cleanup | None | 2-min defensive sweep |
| Session storage | None | `session.custom.toastInstances` |
| Auto-dismiss mechanism | Internal | `now(500)` polling + `dismissAt` binding |

**Proposal:** Add a section to pack `03_script_python.md` documenting the popup-per-toast variant as an alternative to the single-banner. Add `dismissAt` binding mechanics to pack `02_perspective_views.md`. Public `notifyResult` surface unchanged — it routes into our richer Notify underneath.

**Decision:** standardize around the toast process. without a variant or an alternative to single banner. also update the persistance of non-errors to 5 seconds.
**Notes:**


---

### C2. Tree re-anchor pattern after mutation

**Observation:** `Location.Location._refreshAfterMutation(targetId, ...)` returns `{tree, selectedPath, selected}` for the view to apply atomically. Pattern: rebuild tree, find new path for entity id, look up entity's fresh data, return all three. View writes all three view.custom props from the dict. Works around the limitation that Tree.props.selection's bidirectional writeback doesn't fire on programmatic items replacement.

**Proposal:** Add a short section to pack `02_perspective_views.md` titled "Tree mutations: return `{items, selectedPath, selected}` so the view applies all three atomically."

**Decision:** agree with proposal
**Notes:**


---

### C3. Bundled SaveAll pattern — already landed

**Observation:** Hunter's `fc534bf` already added SaveAll documentation to pack `04_named_queries.md` referencing our `Location.LocationTypeDefinition_SaveAll` as first appearance.

**Proposal:** No action — already done. Noting for completeness.

**Decision:** 
**Notes:**


---

### C4. The `mode: 'create' | 'update'` discriminator on shared editor popups

**Observation:** LocationTypeEditor uses `view.custom.mode` to drive create vs update behavior. Pack uses implicit `editDraft.Id == null` discriminator. When the same popup serves both Add and Edit, an explicit `mode` reads more clearly than `null`-checks scattered through bindings.

**Proposal:** Minor pack addition in `07_conventions_and_antipatterns.md`: "Shared add/edit popups MAY use an explicit `view.custom.mode = 'create' | 'update'` prop alongside `editDraft.Id` for binding clarity."

**Decision:** agree with proposal
**Notes:**


---

## D — Proposed rectification waves (for sequencing)

### D1. Wave 1 — Build the missing foundation (no LocationTypeEditor changes)

Items: A1, A2, A5, A6, A9 (sqlType empirical test).

Output: working `Common.Db.execList` / `execOne` / `execMutation`; `Common.Ui.notifyResult` routing into our toast; `Common.Util.log` + `_currentAppUserId`. Entity scripts not yet migrated.

**Decision:** _____________________________
**Notes:**


---

### D2. Wave 2 — Retrofit entity scripts

Items: A1 (call-site migration), A4 (naming standardization), A5 (logger replacement), A10 (parameter casing fix), B1, B2.

Output: Location / Tree / LocationType / LocationTypeDefinition / LocationAttributeDefinition all go through Common helpers; 5 copies of `_rowsToDicts` deleted; module surfaces normalized.

**Decision:** _____________________________
**Notes:**


---

### D3. Wave 3 — Retrofit LocationTypeEditor view

Items: A3.

Output: editDraft/selected split, dirty indicator, Cancel-to-revert, Save handler routes through `notifyResult`.

**Decision:** _____________________________
**Notes:**


---

### D4. Wave 4 — Pack contributions

Items: C1, C2, C4, A8 (cleanup pass on Get NQ to v2).

Output: pack updated with toast variant, tree-mutation re-anchor pattern, mode discriminator note; latent v1 NQ resolved.

**Decision:** _____________________________
**Notes:**


---

### D5. Wave 5 — RowVersion (optional)

Items: A7.

Output: optimistic locking on LocationTypeDefinition / LocationAttributeDefinition.

**Decision:** _____________________________
**Notes:**


---

## Sign-off

**Overall posture (pick one):**

- [ ] Proceed waves 1→4 in order; defer wave 5
- [ ] Proceed waves 1→5 in order
- [ ] Proceed selectively — see per-item decisions above
- [ ] Re-discuss before any rectification work

**Other comments / corrections / things I got wrong:**


