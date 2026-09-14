# Cutover Machine — Eligibility Dropdown & `ProducedAtLocationId` — Design Spec

**Date:** 2026-09-14
**Status:** Draft — awaiting Jacques review
**Author:** Blue Ridge (with Claude)
**Arc / Phase:** Arc 2 (Plant Floor) — cutover tooling. Follow-on to the inventory cutover scan screen.
**Related:** `docs/superpowers/specs/2026-09-12-inventory-cutover-scan-design.md` (the screen this changes), `docs/superpowers/specs/2026-09-10-cavity-alpha-code-design.md` (`CavityCode`), `notes/2026-09-13_prod-release-runbook-inventory-cutover-scan.md` (the release this follows).

---

## 1. Motivation

The inventory cutover scan screen captures, per basket, what the paper LTT says: LOT name, cavity, cast date, piece count. The session header carries the part, the die, and a **Machine #**.

Machine # is the odd one out. It is an `ia.input.text-field` bound to `view.custom.setupDraft.machineNumber`, passed into `BlueRidge.Cutover.Scan.loadSession`, echoed in the header — **and then discarded.** `addBasket`'s `Lot.create` payload carries `itemId / lotOriginTypeId / currentLocationId / pieceCount / toolId / toolCavityId / entryRouteSequence / castDate`. No machine. Nothing downstream of the screen has ever seen it.

So the field has two independent problems:

1. **It is free text** where the plant has a governed list. Die cast machines are `Location` rows (`LocationTypeDefinition.Code = 'DieCastMachine'`, 22 active in Dev) and `Parts.ItemLocation` already records which parts run on which of them. An operator typing `M10`, `10`, `DC1-M10` or `Machine 10` produces four values for one machine.
2. **It is not persisted.** The die cast machine is the one piece of casting provenance on the tag that the new system cannot reconstruct, and the cutover window is the only chance to capture it.

### 1.1 Why the machine cannot be reconstructed

In normal production the machine is implied by the terminal: a die cast terminal's **parent is the machine** (`DC1-M01-T1` → `DC1-M01`), so `Lot.CreatedAtTerminalId` answers "which machine cast this" without a dedicated column. That is why no such column exists.

Cutover breaks the implication. The basket was cast weeks ago; the scan happens at a **machining** terminal, and `CreatedAtTerminalId` records the machining terminal. The link from LOT to casting machine exists only on the paper tag in the operator's hand.

### 1.2 What is already persisted (and is not at issue)

Raised during brainstorming and worth stating, because it narrows the change:

| Fact | Where it lives today | Written by |
|---|---|---|
| **Die** | `Lots.Lot.ToolId` → `Tools.Tool` | `addBasket` → `Lot_Create @ToolId` |
| **Cavity** | `Lots.Lot.ToolCavityId` → `Tools.ToolCavity` | `addBasket` → `Lot_Create @ToolCavityId` |
| **Location** | `Lots.Lot.CurrentLocationId`, plus a `Lots.LotMovement` first-placement row (`FromLocationId = NULL`) | `Lot_Create` |
| **Die cast machine** | — | — |

All three are additionally captured in the `LotCreated` event `NewValue` JSON, which already emits resolved-name objects for Item / Location / Status and a Description reading `<lot> · Lot · Created at <loc> (<part>, <n> pcs); Tool <code>, Cavity <code>`. `Lots.LotEventLog` is the Honda-class **20-year** retention table (migration 0020 § F), so that JSON is durable, not transient.

The machine is the only gap.

### 1.3 Why not `Lots.Lot.DieNumber`

`DieNumber NVARCHAR(50)` is unwritten and looks available. It is not: it is the **legacy die** column, declared in 0020 alongside `CavityNumber` as the pre-FK text pair, and documented in `R__Descriptions_ExtendedProperties.sql` as

> "Legacy as of v1.9 - superseded by ToolId FK above. Retained this release to support any cutover script needing the NVARCHAR form; scheduled for removal in a follow-up migration once all writers move to the Tool FK."

Putting a machine in a column documented as the die, and scheduled for deletion, trades a small migration today for an untangling migration later.

---

## 2. Decisions locked (from brainstorming)

1. **The machine is the die cast machine that cast the parts** — casting provenance off the tag, beside die and cast date. Not a machine on the machining line being scanned into.
2. **It persists as a typed FK on the LOT** — `Lots.Lot.ProducedAtLocationId` — **and** as a resolved-name object in the `LotCreated` event JSON. Queryable on the row, durable in the 20-year log.
3. **Eligibility is exact-match at the machine tier**, not the ancestor cascade (§ 4).
4. **A part with no machine-tier eligibility row falls back to every active die cast machine.** The operator can always record what the tag says; eligibility is a shortlist, never a gate on the scan.
5. **Machine stays session-scoped**, set in the setup form beside Line and Part and changed the same way — through the **Change** button. It does not move into the per-basket entry panel.
6. **Purchased parts get no machine.** `addBox` does not pass one; a received component was never cast here.

---

## 3. The eligibility predicate

### 3.1 Exact match at the machine tier

A die cast machine is eligible for an item when an undeprecated `Parts.ItemLocation` row names **that machine** as the location:

```sql
EXISTS (SELECT 1 FROM Parts.ItemLocation il
        WHERE il.ItemId = @ItemId
          AND il.LocationId = m.Id
          AND il.DeprecatedAt IS NULL)
```

In Dev this yields a real shortlist: the six 6MA parts map to `DC1-M10` and nothing else; `RB-A-70` / `RB-B-2200` / `RB-C-2000` map to `DC1-M04` / `M05` / `M06`.

### 3.2 Why not the ancestor cascade

`Location.Location_ListMachiningDestinations` filters with `Parts.v_EffectiveItemLocation` + `Location.ufn_AncestorLocationIds` — the FDS-03-014 cascade, where eligibility at an ancestor tier flows down. Reusing it here is the obvious move and it is wrong.

Measured against Dev 2026-09-14, the cascade returns **11 machines for every part in the plant**. Eligibility is recorded predominantly at the Area (135 rows) and Line (272 rows) tiers, and every die cast machine beneath an eligible area inherits it. A filter that returns the same 11 rows regardless of input is not a filter.

The machine-tier rows (9 in Dev) are the deliberate signal — somebody mapped those parts to those machines on purpose. Exact match is what surfaces that intent.

This is the same shape as the move-eligibility rule, which checks the terminal's **immediate parent**, exact match, rather than walking ancestors.

### 3.3 Fallback

Four of the thirteen parts with tooling in Dev carry no machine-tier row. For those the proc returns **every active die cast machine**, with `IsEligible = 0` on each row so the caller can tell a fallback list from a shortlist. The distinction is informational today; it exists so a later screen can badge it without a proc change.

---

## 4. `Location.Location_ListDieCastMachinesForItem` (new read proc)

Modelled on `Location.Location_ListMachiningDestinations`. Read proc: no `@Status` / `@Message`, no OUTPUT params, one result set; an empty rowset means no die cast machines are configured at all (FDS-11-011).

```sql
CREATE OR ALTER PROCEDURE Location.Location_ListDieCastMachinesForItem
    @ItemId BIGINT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    -- Two-pass so the fallback is decided once, not per row: when the item has
    -- ANY machine-tier eligibility row the result is exactly those machines;
    -- when it has none the result is every active die cast machine.
    DECLARE @EligibleCount INT = (
        SELECT COUNT(*)
        FROM Location.Location m
        INNER JOIN Location.LocationTypeDefinition ltd ON ltd.Id = m.LocationTypeDefinitionId
        WHERE ltd.Code = N'DieCastMachine'
          AND m.DeprecatedAt IS NULL
          AND @ItemId IS NOT NULL
          AND EXISTS (SELECT 1 FROM Parts.ItemLocation il
                      WHERE il.ItemId = @ItemId AND il.LocationId = m.Id
                        AND il.DeprecatedAt IS NULL));

    SELECT
        m.Id,
        m.Code,
        m.Name,
        area.Code AS AreaCode,
        area.Name AS AreaName,
        CAST(CASE WHEN @EligibleCount = 0 THEN 0 ELSE 1 END AS BIT) AS IsEligible
    FROM Location.Location m
    INNER JOIN Location.LocationTypeDefinition ltd ON ltd.Id = m.LocationTypeDefinitionId
    LEFT JOIN Location.Location area ON area.Id = m.ParentLocationId
    WHERE ltd.Code = N'DieCastMachine'
      AND m.DeprecatedAt IS NULL
      AND (@EligibleCount = 0
           OR EXISTS (SELECT 1 FROM Parts.ItemLocation il
                      WHERE il.ItemId = @ItemId AND il.LocationId = m.Id
                        AND il.DeprecatedAt IS NULL))
    ORDER BY area.Code, m.Code;
END;
```

`ltd.Code = N'DieCastMachine'` rather than the literal id 8 — no magic integers.

**Ordering is `(AreaCode, Code)`, not `Name`.** Machine `Name`s collide across areas: `DC1-M01` and `DC2-M01` are both named `Machine 01`, `DC1-M02` and `DC2-M02` both `Machine 02`, and so on for all four die cast areas. Ordering or labelling by `Name` alone produces an ambiguous list.

---

## 5. Migration 0082 — `Lots.Lot.ProducedAtLocationId`

```sql
ALTER TABLE Lots.Lot
    ADD ProducedAtLocationId BIGINT NULL
        CONSTRAINT FK_Lot_ProducedAtLocation REFERENCES Location.Location(Id);
```

`Lots.Lot` is the unpartitioned header table (0020 § "Lots.Lot (header; NOT partitioned)"), so adding a nullable column is a metadata-only operation — no rebuild, no partition-alignment concern.

Extended-property description, set in the same migration and mirrored into `R__Descriptions_ExtendedProperties.sql`:

> "The die cast machine that produced this LOT. Populated by the inventory cutover scan, where the creating terminal is a machining terminal and therefore cannot imply the casting machine the way a die cast terminal's parent does. NULL for every LOT born at a die cast terminal (derive the machine from CreatedAtTerminalId's parent) and for received purchased components."

**No index.** Nothing queries by machine yet. Add one when a report needs it.

**No backfill.** LOTs created by the cutover releases already shipped keep `NULL`; their machine was never captured and cannot be recovered.

---

## 6. `Lots.Lot_Create` — new parameter

Gains `@ProducedAtLocationId BIGINT = NULL`, appended after `@CastDate`. The default keeps every existing caller — die cast mint, machining/assembly mints, tests — working unchanged, and the Ignition named query passes parameters by name.

### 6.1 Validation

Placed with the other rejecting validations, **before `BEGIN TRANSACTION`**. A `ROLLBACK` inside a proc invoked via `INSERT-EXEC` throws Msg 3915, so every rejection path must select its status row and `RETURN` with no open transaction.

```sql
IF @ProducedAtLocationId IS NOT NULL
   AND NOT EXISTS (SELECT 1
                   FROM Location.Location l
                   INNER JOIN Location.LocationTypeDefinition ltd
                           ON ltd.Id = l.LocationTypeDefinitionId
                   WHERE l.Id = @ProducedAtLocationId
                     AND l.DeprecatedAt IS NULL
                     AND ltd.Code = N'DieCastMachine')
BEGIN
    SET @Message = N'Producing machine must be an active die cast machine.';
    -- Audit.Audit_LogFailure + SELECT @Status, @Message, @NewId + RETURN,
    -- matching the sibling validations above it.
END
```

The check is deliberately narrow — active, and a die cast machine. It does **not** re-check eligibility: § 2 decision 4 makes eligibility a shortlist, and the fallback list is by definition ineligible.

### 6.2 Write and audit

The column is written on the `INSERT INTO Lots.Lot`. The `LotCreated` audit gains a resolved-name object in `@NewValue`, beside the existing `Item` / `Location` / `Status`:

```sql
JSON_QUERY((SELECT loc.Id, loc.Code, loc.Name
            FROM Location.Location loc WHERE loc.Id = l.ProducedAtLocationId
            FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)) AS ProducedAt
```

`FOR JSON` omits the key when the subquery yields NULL, so a LOT with no machine produces the JSON it produces today — no empty `ProducedAt: null` noise on the 99% of LOTs that will never have one.

The Description prose gains a machine clause beside the existing tool clause, built the same way. `@MachineName` / `@MachineArea` are resolved by scalar subquery alongside the existing `@ToolCode` / `@CavityNum` declarations:

```sql
DECLARE @MachineSuffix NVARCHAR(200) =
    CASE WHEN @ProducedAtLocationId IS NOT NULL
         THEN N'; Machine ' + ISNULL(@MachineArea, N'?') + N' ' + ISNULL(@MachineName, N'?')
         ELSE N'' END;
```

appended before `Audit.ufn_TruncateActivity` enforces the 500-character cap.

---

## 7. Ignition layer

### 7.1 Named query + wrapper

`ignition/projects/Core/ignition/named-query/location/DieCastMachine_ListForItem/` — `EXEC Location.Location_ListDieCastMachinesForItem @ItemId = :itemId`, `type: Query`, one parameter `itemId` `sqlType: 3`, matching its sibling `Location_ListMachiningDestinationsForItem`. All named queries live in Core.

`BlueRidge.Location.Location` gains:

```python
def getDieCastMachineDropdown(itemId, _refreshToken=None):
    """Die cast machines for an item, shaped for ia.input.dropdown:
       [{label: 'Die Cast 1 - Machine 10', value: <LocationId>}].
       Always a list, never None."""
```

The label is `"<AreaName> - <MachineName>"`. **ASCII only** — no middot — consistent with the seed-data rule and safe regardless of how the file is read. The area prefix is not decoration: without it `Machine 01` appears four times in a plant-wide list.

Mirrors `BlueRidge.Parts.Item.getEligibleForLocationDropdown`, including the ignored `_refreshToken` (runScript caches on args) and the `except (Exception, java.lang.Exception)` never-throw guard.

### 7.2 Session and setup state

| Before | After |
|---|---|
| `setupDraft.machineNumber: ""` | `setupDraft.machineLocationId: null` |
| `session.custom.cutover.session.machineNumber: ""` | `session.custom.cutover.session.machineLocationId: null` + `machineName: ""` |

`machineLocationId` is what persists; `machineName` is the resolved label the header displays. Both are declared in `session-props/props.json` and in `_EMPTY` in `BlueRidge.Cutover.Scan`, fully shaped — every bound custom property needs a shaped default.

### 7.3 `loadSession`

Signature becomes `loadSession(lineLocationId, itemId, entryRoleCode, machineLocationId, session)` — the positional slot the machine already occupies, now carrying an id.

It resolves the display name by calling `BlueRidge.Location.Location.getDieCastMachineDropdown(itemId)` and finding the option whose `value` matches `machineLocationId`. Using the same list the operator picked from means the label can never drift from the dropdown, and it **re-validates the pick for free**: if the part changed and the previously chosen machine is no longer offered, the match fails, `machineLocationId` resets to `None` and `machineName` to `""`, and the operator picks again rather than silently keeping a stale machine.

The resolved list is not stored in session state — unlike `toolOptions`, the machine dropdown reads its own options through a `runScript` binding on `setupDraft.itemId`, and the setup form is the only place it appears.

### 7.4 `addBasket`

Adds one key to the `Lot.create` payload:

```python
"producedAtLocationId": s.get("machineLocationId"),
```

`addBox` is untouched (§ 2 decision 6).

### 7.5 The three size views

`Desktop`, `Tablet`, `Phone` each change in five places:

1. `view.custom.setupDraft` default — `"machineNumber": ""` → `"machineLocationId": null`.
2. `MachineNumberInput` (`ia.input.text-field`) → `MachineDropdown` (`ia.input.dropdown`), placeholder `Pick the machine`, `props.options` bound to `runScript("BlueRidge.Location.Location.getDieCastMachineDropdown", 0, {view.custom.setupDraft.itemId})`, `props.value` bidirectional to `view.custom.setupDraft.machineLocationId`. The label above it stays **Machine #**.
3. The header's `MachineValue` label — `session.custom.cutover.session.machineNumber` → `...machineName`.
4. The **Change** button's reseed script — `"machineNumber": s.get("machineNumber")` → `"machineLocationId": s.get("machineLocationId")`.

5. The Start/Apply script that calls `loadSession` — `d.get("machineNumber")` → `d.get("machineLocationId")`.

`MachineValue` keeps its `pf-kpi-value-mono` class and has no width cap today; its KV cell carries `position.shrink: 0` like every sibling. `Die Cast 1 - Machine 10` is materially longer than `1`, so the header row is checked at all three breakpoints and adjusted only if it actually crowds — no speculative width change.

These are **existing** views, so the edits go through Designer rather than the filesystem, per the project's Ignition file-edit boundary — or, if file-edited, only with Designer closed and a `scan.ps1` afterwards.

---

## 8. Testing

### 8.1 New SQL coverage — `sql/tests/0070_Cutover_EntryRoute/060_DieCastMachine_ListForItem.sql`

| Case | Assertion |
|---|---|
| Item with machine-tier rows | Returns exactly those machines, `IsEligible = 1` on every row |
| Item with no machine-tier rows | Returns every active die cast machine, `IsEligible = 0` on every row |
| `@ItemId = NULL` | Returns every active die cast machine (fallback branch) |
| Deprecated machine | Excluded from both the shortlist and the fallback |
| Deprecated `ItemLocation` row | Does not make its machine eligible; item falls back if it was the only row |
| Ordering | `(AreaCode, Code)` ascending |

Fixtures use dynamic lookups, not hardcoded ids, matching the rest of the suite.

### 8.2 New `Lot_Create` coverage — `sql/tests/0070_Cutover_EntryRoute/070_Lot_Create_ProducedAt.sql`

| Case | Assertion |
|---|---|
| Valid die cast machine | `Status = 1`; `Lot.ProducedAtLocationId` set; `LotEventLog.NewValue` contains a `ProducedAt` object with `Id`/`Code`/`Name`; Description carries the machine clause |
| Omitted (default NULL) | `Status = 1`; column NULL; `NewValue` has **no** `ProducedAt` key; Description unchanged from today |
| A non-machine location (a line, an area, a terminal) | `Status = 0`, message names the rule, no LOT row created |
| A deprecated die cast machine | `Status = 0` |
| Ineligible-but-valid machine | `Status = 1` — eligibility is a shortlist, not a gate (§ 6.1) |

Captured with `INSERT … EXEC` into a temp table matching the `Status / Message / NewId` shape.

### 8.3 Regression

The existing `0020_PlantFloor_Foundation/040_Lot_Create.sql` set and `0070_Cutover_EntryRoute/*` must pass **unmodified** — the new parameter is optional and every existing call omits it. Teardown deletes `LotGenealogyClosure` before LOTs.

### 8.4 Manual

On a Dev session at a machining line: pick a 6MA part and confirm the dropdown offers only `Die Cast 1 - Machine 10`; pick `12231-6MA -0000` (no machine-tier row) and confirm the full 22-machine fallback; change part after picking a machine and confirm the stale machine clears; scan a basket and confirm `Lots.Lot.ProducedAtLocationId` and the `LotCreated` JSON in SQL.

---

## 9. Rejected alternatives

**`Lots.Lot.DieNumber`.** Documented as the legacy die column and scheduled for removal (§ 1.3).

**A new `Lots.Lot.MachineNumber NVARCHAR`.** Free text where a governed `Location` list exists, against the standing "all enum/status columns code-table backed with FK — no magic integers, no free-text" rule.

**Audit JSON only, no column.** Durable (20-year table) but reaches "every cutover LOT from Machine 10" only through `JSON_VALUE` over a partitioned log. A nullable FK on an unpartitioned header table costs one metadata-only `ALTER`.

**The ancestor cascade as the eligibility filter.** Returns 11 machines for every part in Dev (§ 3.2).

**Per-basket machine.** Rejected in brainstorming: the machine belongs with Line and Part, changed through the same Change button, not latched per basket beside cavity and cast date.

**`allowCustomOptions: true` on the dropdown.** A typed value does not resolve to a `LocationId`, which is what the new FK stores. The fallback-to-all-machines list is the escape hatch instead.

---

## 10. Deployment

A schema change, so this ships as a full production release, not an Ignition-only scan:

1. **Preview** — `sql/scripts/Deploy-ProdRelease.ps1`, read-only, with the plan fingerprint.
2. **Rehearsal** — against live data in a transaction, verified, rolled back. Rehearse locally first against a DB built at the target's exact migration state.
3. **Execute** — COPY_ONLY backup, one transaction, `-ExpectedPlan` from the preview that was read. Nothing committed between preview and execute; the fingerprint includes HEAD.
4. **Scoped project exports** — built from git and verified against HEAD via `tools/Build-ChangeExport.ps1`: the new named query and `BlueRidge.Location.Location` (Core, imported first), then the three `_CutoverScan` views and `session-props` (MPP).
5. **Instruction guide** — published as an Artifact and mirrored to `notes/2026-09-14_prod-release-runbook-cutover-machine.md`.

**Order matters:** migration 0082 and the `Lot_Create` / `Location_ListDieCastMachinesForItem` procs land **before** the Ignition resources. A view calling a named query whose proc does not yet exist shows an empty dropdown; a proc with an unused parameter is inert.

---

## 11. Open items

None. Every decision in § 2 was resolved in brainstorming.
