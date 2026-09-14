# Prod release runbook — cutover machine + die name

**Release commit:** `e0cc9577` on `jacques/working`.
**Previous release:** `515db6c6` (2026-09-13, inventory cutover scan).
**Rehearsed against:** `MPP_MES_ProdSim`, a database built at `515db6c6` — prod's exact
migration state (81 migrations, highest `0081`, `Lots.Lot.ProducedAtLocationId` absent).

**Nothing may be committed between the preview you read and the Execute.** The plan
fingerprint covers HEAD; Execute refuses if anything moved.

Before starting, confirm the tree is where this runbook says:

```bash
git log --oneline -1
```

Expect `e0cc9577 docs(cutover): verification record for the machine eligibility dropdown`.

---

## 1. What this ships

Two features that share files, so they ship together.

**Cutover machine (the main change).** The inventory cutover scan's **Machine #** was a
free-text field that was never persisted — the operator typed `M10` / `10` / `Machine 10`
and it went nowhere. It is now a dropdown of die cast machines driven by part
eligibility, and the pick is stored on the LOT.

- `Lots.Lot.ProducedAtLocationId` (migration `0082`) — nullable FK to `Location.Location`.
- `Location.Location_ListDieCastMachinesForItem` — exact-match eligibility at the machine
  tier via `Parts.ItemLocation`, falling back to every active die cast machine when a part
  has no machine-tier row.
- `Lots.Lot_Create` takes `@ProducedAtLocationId`, validates it as an active die cast
  machine **before** the transaction, writes the column, and adds a resolved-name
  `ProducedAt` object to the `LotCreated` event JSON.
- `Lots.Lot_SearchAdvanced` now finds and displays cutover LOTs by machine. Without this
  they would be invisible on that screen: it resolves the machine through
  `Workorder.DieCastContribution`, and a cutover LOT has no contribution rows.

**Die name (`b8b55230`).** The DIE dropdown showed `Tools.Tool.Code` — the asset tag
(`DMO126`). It now shows `Tools.Tool.Name` (`6MA Family Die`), with `Code` as the fallback.
No SQL change: `Tools.Tool_ListForItem` already returned both.

**Header wrap fix (`f1cdaba4`).** Those two changes added ~30 characters to the latched
header row, which clipped at 1366px. `LatchedKvRow` carried `style.flexWrap: wrap`, which is
**inert** — `ia.container.flex` writes its own inline `flex-wrap` from `props.wrap`. Setting
the real prop makes it wrap instead of clip, at any width. Desktop and Tablet only; Phone
stacks vertically and cannot clip.

---

## 2. What the database change is

| | |
|---|---|
| Migrations | **1** — `0082_lot_produced_at_location` |
| Repeatables | **3** — 1 new, 2 changed |
| Post-commit | `R__Descriptions_ExtendedProperties.sql` (documentation only) |
| Rehearsal lock window | **0.2s** |

```
NEW      R__Location_Location_ListDieCastMachinesForItem.sql
CHANGED  R__Lots_Lot_Create.sql
CHANGED  R__Lots_Lot_SearchAdvanced.sql
```

`0082` adds a **nullable** column to `Lots.Lot`, which is the unpartitioned header table —
a metadata-only operation, no table rebuild. No index, no backfill. Existing LOTs keep
`NULL`, which is correct: their machine was never captured.

> **Read this before the preview surprises you.**
> `R__Descriptions_ExtendedProperties.sql` carries a **+309 / −54** documentation
> catch-up, far more than this release's one column. Those are descriptions written into
> `MPP_MES_DATA_MODEL.md` in *earlier* commits that were never regenerated into the
> repeatable. They are `MS_Description` extended properties only — no schema, no data, no
> behaviour. It runs **after** the commit, outside the transaction, so it never holds locks.

---

## 3. Deploy

Connection details are carried over from the 2026-09-13 runbook. **If the prod address or
login has changed, substitute yours** — nothing else in this runbook depends on them.

### Step 1 — Preview (read-only)

```bash
.\sql\scripts\Deploy-ProdRelease.ps1 -ServerInstance 172.17.10.148 -Username Ignition -DatabaseName MPP_MES_Prod
```

Expect, section by section:

```
[3] Versioned migrations
  Database: 81 applied, highest 0081.
  Pending (1):
    + 0082_lot_produced_at_location.sql

[4] Repeatables -- target definitions vs this checkout
  459 identical, 2 changed, 1 new on the target.
    NEW      R__Location_Location_ListDieCastMachinesForItem.sql
    CHANGED  R__Lots_Lot_Create.sql
    CHANGED  R__Lots_Lot_SearchAdvanced.sql

[5] Pre-flight gates
  No gates fired.

[8] Plan
  1 migration(s), 3 repeatable(s) in one transaction; then
  R__Descriptions_ExtendedProperties.sql after commit.

Verdict
  Clear to deploy. 0 warning(s) to read above.
```

**Take the plan fingerprint from YOUR preview.** ProdSim printed `f7c13c4bc58f`; prod's
will differ, because the fingerprint covers the target's own state as well as HEAD.

**If it differs from the above:**

- *Pending shows more than `0082`* — prod is behind where this runbook assumes. Stop and
  reconcile; do not proceed.
- *More than 3 changed repeatables* — prod has drifted from git, or a commit landed since
  `515db6c6` that was never deployed. The per-object diffs are written to the report's
  `diffs` folder; read them. A larger CHANGED list is information, not automatically an
  error, but it means this runbook no longer describes what you are about to do.
- *Any gate fires* — stop. Gates read live plant data; a BLOCK means the release is unsafe
  right now, usually because the plant is mid-operation.

### Step 2 — Rehearsal

```bash
.\sql\scripts\Deploy-ProdRelease.ps1 -ServerInstance 172.17.10.148 -Username Ignition -DatabaseName MPP_MES_Prod -Mode Rehearse -ExpectedPlan <fingerprint from step 1>
```

This runs the real deploy script against real prod rows inside a transaction, verifies it,
then rolls back. It takes the same locks as Execute for the same fraction of a second.

Expect:

```
    == transaction open
    == [1] migration 0082_lot_produced_at_location
    Migration 0082 (lot_produced_at_location) applied.
    == [2] R__Location_Location_ListDieCastMachinesForItem.sql
    == [3] R__Lots_Lot_Create.sql
    == [4] R__Lots_Lot_SearchAdvanced.sql
    == verifying inside the transaction
    == checks passed
    == ROLLED BACK (rehearsal / preview script) -- nothing was kept

  REHEARSAL PASSED and was rolled back. Lock window: 0.2s.
```

If the rehearsal fails, **stop**. It failed against prod's actual data, which is the one
thing local testing cannot simulate.

### Step 3 — Execute

```bash
.\sql\scripts\Deploy-ProdRelease.ps1 -ServerInstance 172.17.10.148 -Username Ignition -DatabaseName MPP_MES_Prod -Mode Execute -ExpectedPlan <same fingerprint>
```

COPY_ONLY backup (with VERIFYONLY) → deploy script → verify → COMMIT. Any error anywhere
rolls the entire release back; there is no partial state.

### Step 4 — Ignition imports, **Core first**

SQL must already be deployed: these views and named queries call procs and read a column
that must exist.

| Archive | Contents |
|---|---|
| `Core_cutover-machine_2026-09-14_1119.zip` | 5 resources, 11 entries |
| `MPP_cutover-machine_2026-09-14_1119.zip` | 4 resources, 9 entries |

**Core (import first):**

```
NEW  ignition/named-query/location/DieCastMachine_ListForItem
MOD  ignition/named-query/lots/Lot_Create
MOD  ignition/script-python/BlueRidge/Cutover/Scan
MOD  ignition/script-python/BlueRidge/Location/Location
MOD  ignition/script-python/BlueRidge/Lots/Lot
```

**MPP (second):**

```
MOD  com.inductiveautomation.perspective/session-props
MOD  .../views/BlueRidge/Views/ShopFloor/_CutoverScan/Desktop
MOD  .../views/BlueRidge/Views/ShopFloor/_CutoverScan/Phone
MOD  .../views/BlueRidge/Views/ShopFloor/_CutoverScan/Tablet
```

`MPP_Config` has no changed resources and is not part of this release.

Both archives were built **from git at `e0cc9577`**, not from the working tree. The builder
rewrote one manifest to drop a `thumbnail.png` entry — that is deliberate and important:
`thumbnail.png` is gitignored, and a manifest naming a file the archive does not contain is
what produces a Designer `NullPointerException` / "project is null".

---

## 4. Verification

### 4.1 The column and the audit JSON

Scan one basket at a cutover terminal with a machine selected, then:

```sql
SELECT TOP 3 l.Id, l.LotName, l.ProducedAtLocationId, loc.Code, loc.Name
FROM Lots.Lot l
LEFT JOIN Location.Location loc ON loc.Id = l.ProducedAtLocationId
ORDER BY l.Id DESC;
```

The newest LOT should carry the machine's id, code and name.

```sql
SELECT TOP 1 Description, NewValue FROM Lots.LotEventLog ORDER BY Id DESC;
```

`Description` should end `; Tool <code>, Cavity <code>; Machine <area> <name>`, and
`NewValue` should contain a `ProducedAt` object with `Id` / `Code` / `Name`.

> **This is the one hop that was never verified before shipping.** Everything up to
> `Lot_Create` is covered by the SQL suite (3523 assertions, 0 failures) and the UI was
> verified live, but the browser used for testing cannot commit the LTT and piece-count
> text fields, so the UI→database write is inferred rather than observed. **Do this check
> first.**

### 4.2 LOT Search

Filter LOT Search by the machine you just used. The cutover LOT should appear, and its
origin-machine column should name the machine.

### 4.3 The dropdown

- A part with a machine-tier eligibility row offers **only** its machines.
- A part without one offers **every** active die cast machine.
- Labels read `<Area> - <Machine>` (`Die Cast 1 - Machine 10`). The area prefix matters:
  machine names repeat across areas, and four bare "Machine 01"s are indistinguishable.
- Changing the part clears a now-ineligible machine.

### 4.4 The die name

The header DIE should show the die's **name**, not its asset tag.

---

## 5. Rollback

**Database:** restore the COPY_ONLY backup Execute took. `0082` adds a nullable column and
the three procs are `CREATE OR ALTER`, so nothing destructive happens — but restore is the
sanctioned path.

**Ignition:** re-import the previous release's archives,
`Core_cutover-scan_2026-09-13_2352.zip` and `MPP_cutover-scan_2026-09-13_2352.zip`.

Order reverses: **Ignition first, then SQL.** The old views do not reference the new column.

---

## 6. Known, not fixed

**A part with no die configuration is un-scannable, and fails unhelpfully.** A part with no
`Tools.ToolCavity` rows shows a green `AUTO` badge beside a blank die name and no cavity
tiles; `addBasket` requires a cavity, so the operator reaches a dead end at *Add basket*
with nothing explaining why. Observed on `11200-6MAA-J010` in Dev.

This is **pre-existing** — not introduced by this release — but it becomes live as the real
MPP part list is seeded, and cutover is exactly when someone will hit it. Worth its own
ticket.

**`style.flexWrap` is inert across the project.** The header clipping traced to a style
property that `ia.container.flex` silently overrides. There are **14** `style.flexWrap`
usages and **43** correct `props.wrap` ones in the project, so other views may carry the
same dead style, waiting for content to grow into it. A sweep, not a release item.

---

## 7. Provenance

| | |
|---|---|
| Release commit | `e0cc9577` |
| Commits since prod | 16 (`515db6c6..e0cc9577`) |
| SQL suite | 3523 passed, 0 failed, exit 0 — on final HEAD, from a database rebuilt from migrations |
| ProdSim preview | Clear to deploy, 0 warnings, fingerprint `f7c13c4bc58f` |
| ProdSim rehearsal | Passed, rolled back, 0.2s lock window |
| Live UI verification | `notes/2026-09-14_cutover-machine-verification.md` |
| Design spec | `docs/superpowers/specs/2026-09-14-cutover-machine-eligibility-design.md` |
| Implementation plan | `docs/superpowers/plans/2026-09-14-cutover-machine-eligibility.md` |
