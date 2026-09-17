# Prod release runbook — purchased parts become Pass-Through (0089)

**Release commit:** `192c77c1` on `jacques/working` — the commit that carries migration `0089`.
**Previous release:** `aec53015` (executed 2026-09-16 04:46 ET, migrations `0085`–`0088`).
**Published guide:** https://claude.ai/artifact/PiwAfdG7aQ3KGDtHTnwsgK
**Rehearsed against:** `MPP_MES_Dev` — **not** a ProdSim, deliberately. See § 3.4.

> **Nothing may be committed between the preview you read and the Execute.** The plan
> fingerprint covers HEAD; Execute refuses if anything moved.
>
> HEAD will be this runbook, or a later docs-only commit — that is fine and expected. What
> matters is that **no deployable moved after `192c77c1`**:
> ```bash
> git diff --stat 192c77c1..HEAD -- ignition/ sql/
> ```
> Expect **no output**. If anything is listed, re-preview.

---

## 1. What this ships

**Castings and bought parts stop sharing a type.** The part-list load typed every part that
is neither a Finished Good nor a Sub-Assembly as `Component` — the 6MA intake casting and the
9x14 dowel pin alike. FDS-03-002 already reserves `Component` for the manufactured
intermediate (the casting) and `Pass-Through` for vendor-supplied parts, and no item used
`Pass-Through`. M&A inventory needs the distinction because the two enter inventory in
completely different ways: a casting arrives as a manufactured LOT off its own route, and a
bought part is received.

After this release, the Config Tool's Item Master filter **Pass-Through** lists the bought
parts with a `PT` badge, and **Component** lists only castings (plus one known exception, § 6).

| Migration | What it does |
|---|---|
| `0089_item_type_cutover_reclassify` | 33 purchased parts `Component` → `PassThrough`; `1223A-6B2 -A000` 6B2 Cam Rocker Set `Component` → `FinishedGood`. One `Audit.ConfigLog` row per item, attributed to System Bootstrap. |

**No repeatables. No Ignition resources.** The Item Master filter and badge map already
know `Pass-Through`; the AddItem dropdown reads the type table.

**Why a migration and not a proc.** `Parts.Item_Update` deliberately refuses to change
`ItemTypeId`, and this is a cutover correction, not a capability. The migration writes its own
audit rows inside the release transaction, so every retype is explained, and no permanent
retype path exists afterwards.

**Evidence** (`sql/scratch/2026-09-16_item_type_classification_check.sql`, run against prod
2026-09-16): of 104 `Component` items, 68 carry a DieCast route step and 36 carry no route.
The LOT record agrees independently — the 68 hold 168 LOTs, all `Manufactured`; the 36 hold
5, all `Received` — and no part without a cast route sits on a die cavity.

**In the range, shipping nothing:**
- `sql/scripts/Deploy-ProdRelease.ps1` — the new `0089` pre-flight gate (runs from your checkout, not deployed).
- `sql/seeds/020_seed_items.sql` — types its four purchased parts `PassThrough`. The deploy runs no seeds.
- `sql/scratch/2026-09-16_item_type_classification_check.sql` — the evidence query; also the post-deploy check.
- `git diff aec53015..HEAD -- ignition/` also lists PLC tag/script changes (`PlcDevices.json`,
  `TrayInspectionStation.json`, `TrayInspectionWatcher`) merged from `hunter/explore`. **They
  are not part of this release** and there is no Ignition import in this window.

---

## 2. Risk

| Test | Answer |
|---|---|
| Does anything now refuse what it used to allow? | **No.** No proc changes. No SQL anywhere branches on `Component`; the only type checks in the codebase test `FinishedGood`. |
| Shared code? | **None.** |
| Metadata-only? | **No — a data change, and a small one.** 34 `UPDATE`s on `Parts.Item` (unpartitioned, ~175 rows) and 34 `Audit.ConfigLog` inserts. No DDL, no index. |
| Does the old Ignition keep working? | **Yes.** Nothing in Ignition changes. |

**What does change for a person:**
- *Config Tool, Item Master:* the 33 bought parts move from the Component filter to Pass-Through.
- *The Cam Rocker Set becomes a Finished Good.* It will appear in reads that filter on
  Finished Good (the three procs that test `FinishedGood`: printer FG assignment, the Assembly OUT
  ranked list, and the plant scrap summary). It will **not** appear on an Assembly OUT pick-list
  until it has an eligible location, and it cannot be minted or shipped until it has a route and
  a container config. Configuration work, not a regression.

**The migration refuses — and the whole release rolls back — if:**
- a listed part is no longer `Component` (retyped since the evidence was read);
- a part headed for `PassThrough` has a DieCast route step, a `Manufactured` LOT, or an active die cavity;
- the Cam Rocker Set has any LOTs.

The preview's `0089` gate checks the same three things against live data first, so a
refusal shows up as a BLOCK in the preview rather than mid-transaction.

---

## 3. Deploy

Password: never on the command line. Let the script prompt (masked) when `-Username` is given.

### 3.1 Preview — read-only

```powershell
.\sql\scripts\Deploy-ProdRelease.ps1 -ServerInstance 172.17.10.148 -Username Ignition -DatabaseName MPP_MES_Prod
```

Expect in `[3]`:

```
  Database: 88 applied, highest 0088.
  Pending (1):
    + 0089_item_type_cutover_reclassify.sql
```

**If `[3]` does not say 88 applied / highest 0088, stop.** Something was deployed outside this process.

Expect in `[4]`: `0 changed, 0 new on the target.` Nothing under `sql/migrations/repeatable`
moved since `aec53015`, and that release reported every repeatable matching byte-for-byte.
A `CHANGED` row means prod was hand-patched since — read its diff before continuing.

Expect in `[5]`, exactly:

```
  [INFO] 0089: retypes 34 of 34 listed item(s): 33 -> PassThrough, 1 -> FinishedGood; one Audit.ConfigLog row each
```

The full plan is saved as `item_type_reclassify_plan.csv` in the report folder.

**If it differs:**
- *`[WARN] 0089: part '…' is not on the target`* — prod no longer has a part the evidence showed. Stop and re-run the classification check.
- *any `[BLOCK] 0089`* — the evidence no longer holds for that part. Stop. Take it out of the migration's list (a new commit, then re-preview) or fix the data.
- *`retypes N of 34` with N < 34 and no WARN* — some parts are already at their target type. Someone retyped by hand; find out who before continuing.

Expect in `[8]`: `1 migration(s), 0 repeatable(s) in one transaction`. Copy the fingerprint.

### 3.2 Rehearse — applies to live data, then rolls back

```powershell
.\sql\scripts\Deploy-ProdRelease.ps1 -ServerInstance 172.17.10.148 -Username Ignition -DatabaseName MPP_MES_Prod -Mode Rehearse -ExpectedPlan <fingerprint-from-YOUR-preview>
```

Type `REHEARSE` at the prompt. Expect:

```
    == transaction open
    == [1] migration 0089_item_type_cutover_reclassify
    0089: retyped 34 item(s); 0 already at target type; 0 listed part(s) not present on this database.
    Migration 0089 (item_type_cutover_reclassify) applied.
    == verifying inside the transaction
    == checks passed
    == ROLLED BACK (rehearsal / preview script) -- nothing was kept

  REHEARSAL PASSED and was rolled back. Lock window: 1s.
```

If the rehearsal fails, stop — it failed against prod's actual rows.

### 3.3 Execute

```powershell
.\sql\scripts\Deploy-ProdRelease.ps1 -ServerInstance 172.17.10.148 -Username Ignition -DatabaseName MPP_MES_Prod -Mode Execute -ExpectedPlan <same-fingerprint>
```

Type `MPP_MES_Prod` at the prompt. It takes a verified `COPY_ONLY` backup first — **note the path**. Expect `== COMMITTED`, then `Every repo migration is recorded.` and `DONE`.
It will end with `Import the Ignition exports NOW -- Core first.` — **there are none for this release.**

### 3.4 What the rehearsal was run against, and why

The local rehearsal ran against **`MPP_MES_Dev`**, not a ProdSim. A ProdSim is built from seeds
and holds 4 of the 34 listed parts, so it would print `retyped 4 … 30 not present` and prove
nothing about this migration. `MPP_MES_Dev` holds all 34 part numbers (hand-loaded from the
MPP part list).

The cost: Dev is at **0087**, one behind prod, and 16 repeatables behind, so its preview
listed `0088` + `0089` and 16 `CHANGED`. **Prod should show only `0089` and 0 changed.** The
lines that are about this release matched what prod is expected to print exactly:

| | Dev (report stamps 2026-09-16 23:46-23:47) |
|---|---|
| Preview `[5]` | `[INFO] 0089: retypes 34 of 34 listed item(s): 33 -> PassThrough, 1 -> FinishedGood; one Audit.ConfigLog row each` |
| Rehearse step | `0089: retyped 34 item(s); 0 already at target type; 0 listed part(s) not present on this database.` |
| Verdict | `REHEARSAL PASSED and was rolled back. Lock window: 1s.` |
| After rollback | 87 migrations, highest 0087; 0 PassThrough items; 0 `migration 0089` audit rows |
| Report folders | `dist/deploy-reports/MPP_MES_Dev_Preview_20260916_234630`, `…_Rehearse_20260916_234712` |

Also proven before commit:
- Full SQL suite on a throwaway database: **3638 / 3638**, exit 0 (0089 runs as a no-op on a virgin DB).
- In a rolled-back transaction on Dev: a second run retypes 0 (idempotent); each of the three
  guards refuses when its condition is staged; stored characters are `·` (183) and `→` (8594).

---

## 4. Verification after Execute

```sql
-- 1. type counts                                       expect (active / deprecated)
--    Component 69 / 1    PassThrough 32 / 1    FinishedGood 48 / 0    SubAssembly 27 / 1
SELECT it.Code,
       COUNT(CASE WHEN i.DeprecatedAt IS NULL THEN 1 END)     AS Active,
       COUNT(CASE WHEN i.DeprecatedAt IS NOT NULL THEN 1 END) AS Deprecated
  FROM Parts.ItemType it LEFT JOIN Parts.Item i ON i.ItemTypeId = it.Id
 GROUP BY it.Id, it.Code ORDER BY it.Id;

-- 2. one audit row per retype                          expect 34
SELECT COUNT(*) FROM Audit.ConfigLog WHERE Description LIKE N'%migration 0089%';
```

Component stays at 69 active, not 68: the 68 castings plus `92900-0614-1B`, left alone (§ 6).

Then re-run the evidence query and read its last result set:

```powershell
sqlcmd -S 172.17.10.148 -U Ignition -d MPP_MES_Prod -C -W -s "|" -i sql\scratch\2026-09-16_item_type_classification_check.sql -o item_type_check_after.txt
```

Expect these rows (`CurrentType|ProposedType|VerdictClass|Items|OfWhichDeprecated`) and no `CONFLICT` row:

```
Component|Component|OK|68|0
Component|PassThrough|REVIEW|2|1
FinishedGood|NULL|n/a|48|0
PassThrough|PassThrough|OK|33|1
SubAssembly|NULL|n/a|28|1
```

The two REVIEW rows are the stud bolt and the deprecated `5RO` pin (section 6).

On a Config Tool session: **Item Master → filter Pass-Through** lists the bought parts with a
`PT` badge; open one and confirm the Identity panel reads *Pass-Through*.

---

## 5. Rollback

The `COPY_ONLY` backup is the rollback of last resort, but restoring it discards every plant
transaction since the window. For this change the practical rollback is **a forward migration**
with the same list and From/To swapped — the same shape, same guards, same audit. Nothing
downstream reads the type in a way that would leave residue.

---

## 6. Known open — not in this release

| Item | Note |
|---|---|
| `92900-0614-1B` 6x14 Stud Bolt | Looks like a duplicate of `92900-06014-1B`. Left as `Component` by decision, so it shows among the castings until resolved. |
| `90701-5RO-3000` (letter O) | Deprecated typo of `90701-5R0-3000`. Left as it is. |
| `90701-5GO -A000` 10x10 Dowel Pin | Deprecated, yet a child on 2 published BOMs. In Dev those are `14650-5GO -A000` and `14660-5GO -A000` v1 (QtyPer 7); confirm on prod. Retyped to Pass-Through here regardless. |
| Cam Rocker Set configuration | Now a Finished Good with no route, container config or eligible location — cannot be minted or shipped until configured. |
| `21001 pin` on prod | The Dev seed's test part exists on prod. Retyped with the rest; whether it belongs there is a separate question. |
| 42 castings with no die cavity | No cavity and no LOTs on prod — castings whose inventory has not been cut over (59B, RPY, fuel pumps, 5G0, 6FB families…). Not a defect in this release. |
| M&A inventory screens | The reason for this release; not built yet. |
| ItemType → Area/route constraint | Still unbuilt. Now that the type is trustworthy it becomes enforceable. |

---

## 7. Outcome -- executed 2026-09-17 06:03 ET

**Clean. `== COMMITTED`, sqlcmd exit 0 after 1.4s, no BLOCK gate fired. 34 items retyped, as previewed.**

| | |
|---|---|
| Executed at | 2026-09-17 06:03 ET |
| Prod starting state | 88 applied, highest `0088`; 464 repeatables identical, 0 changed, 0 new |
| Prod HEAD | `92fd283d` (docs-only after the release commit `192c77c1`; `git diff --stat 192c77c1..HEAD -- ignition/ sql/` empty) |
| Plan fingerprint used | `4bc594c67226` (prod's own; Dev's was `b33ec19e394d`) |
| Preview `[5]` printed | `[INFO] 0089: retypes 34 of 34 listed item(s): 33 -> PassThrough, 1 -> FinishedGood; one Audit.ConfigLog row each` -- exactly as predicted |
| Rehearse printed | `REHEARSAL PASSED and was rolled back. Lock window: 1.9s.` |
| Execute printed | `0089: retyped 34 item(s); 0 already at target type; 0 listed part(s) not present on this database.` |
| Lock window | 1.4s (rehearsal 1.9s; Dev 1s) |
| After commit | `R__Descriptions_ExtendedProperties.sql applied.` / `Every repo migration is recorded.` / `All 0 applied repeatable(s) now match the repo byte-for-byte.` |
| Backup path | `C:\Program Files\Microsoft SQL Server\MSSQL16.MSSQLSERVER\MSSQL\Backup\MPP_MES_Prod_pre-release_0088_20260917_060339.bak` (COPY_ONLY, CHECKSUM, verified) |
| Report folders | `dist/deploy-reports/MPP_MES_Prod_Preview_20260917_054853`, `..._Rehearse_20260917_060236`, `..._Execute_20260917_060339` |
| Ignition imports | None, as planned. The script's closing `Import the Ignition exports NOW` line does not apply to this release. |
| Verification (section 4) | _still to run_ -- type counts, 34 audit rows, the evidence check, and the Item Master Pass-Through filter |

### What went sideways

Two false starts before the rehearsal, neither of which wrote anything:

- **05:50:34 -- `Login failed for user 'Ignition'`** at `[2]`. The run stopped at the connection; the next attempt connected, so most likely a mistyped password at the masked prompt.
- **05:50:48 -- fingerprint abort.** `-ExpectedPlan` was typed as `4bc59c67223` against the preview's `4bc594c67226` (one `4` dropped, last digit wrong). The guard aborted before any transaction.
  **The same class of slip as 2026-09-12. Paste the fingerprint; never retype it.**

The 06:02 rehearsal with the pasted fingerprint passed, and Execute followed at 06:03.

### Two prod-only procedures surfaced by the preview

`[4]` warned about two objects on prod with no file in any branch, any worktree, or `MPP_MES_Dev`:

| Object | Created (server time) | By |
|---|---|---|
| `Lots.ShippingLabel_GetLastForTerminal` | 2026-09-16 09:57:07 | login `Ignition`, host `IGNSRV`, JDBC |
| `Oee.DowntimeEvent_RequiresReasonGate` | 2026-09-16 15:04:45 | login `Ignition`, host `IGNSRV`, JDBC |

Source: the SQL default trace (`EventClass 46`, Object:Created). Created through the prod
Gateway's database connection -- the pattern of Designer's Database Query Browser or a
Script Console -- and never altered since. Neither has a header. Both are consistent with
the schema (`Oee.Shift` holds Eastern wall-clock times, so the gate's ET comparison is
right). They were left untouched by this release. **Open:** asked Hunter whether they are
his and whether prod-Gateway views or named queries changed with them; then bring both into
`sql/migrations/repeatable/` and diff the prod Gateway's resources against git.
