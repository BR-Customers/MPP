# Prod release runbook -- pass-through repack (a finished good with no BOM packs from received stock)

**Release commit:** `f840f4b5` on `jacques/working`.
**Previous release:** `20334b41` (2026-10-06 13:23, Pack-Out editing). Prod is at SQL **`0105`**, 104 migrations.
**Rehearsed against:** `MPP_MES_ProdSimEP2`, at prod's state (104 applied, highest `0105`, both procs at
their previous versions). Preview + Rehearse clean, rollback verified; it is still at prod's state. A full
**Execute** was run against a second sim, `MPP_MES_ProdSimEP`, to cover the backup and post-commit steps.
**SQL suite:** 4285 assertions / 4285 passed / 0 failed (the previous release's 4263 plus 22 new), run on
`MPP_MES_Test_RP` with this release's SQL.

> **SQL only. There are no Ignition archives and nothing to import.** The screens already call these two
> procs; only what the procs answer changes.

> **Read this before deciding to ship.** A repack tray close has **never been done through the screen.**
> The proc is proven by 22 assertions (received stock consumed, FIFO, held stock skipped, the minted tray
> LOT never re-consumed), and on Dev the Assembly tab was seen selecting the 66V part on its own once the
> procs were in. But Dev's pass-through terminal is By Weight with no scale, so no tray was closed from it.
> Section 6.1 is that first close.

> **Nothing may be committed between the preview you read and the Execute.** The plan fingerprint's first
> hashed line is the raw `HEAD` sha, so any commit changes it -- a docs-only commit included -- and Execute
> refuses. Re-preview and use the new fingerprint.
> ```bash
> git diff --stat f840f4b5..HEAD -- sql/
> ```
> Expect **no output**. Anything listed means this runbook no longer describes what would deploy.

---

## 1. What this ships

The pass-through stations receive a part already finished, inspect it, and repackage it under the **same
part number**. The Assembly tab on that screen is the standard assembly-out screen, which builds a finished
good by consuming its BOM. These parts have no BOM, and a part cannot be on its own BOM, so the screen could
neither select the part ("No part in production") nor close a tray ("No active BOM").

After this release, **a finished good with no published BOM is treated as a repack part**:

- The Assembly tab lists it and selects it by default.
- Closing a tray mints the tray LOT exactly as assembly-out always has, and fills it from **received LOTs of
  that same part number at the line**, oldest first.
- The received LOT is drawn down; when it reaches zero it closes. Genealogy links it to the tray LOT, so the
  vendor lot is traceable from the shipped container.
- Containers, the full-box check, the AIM serial and the MPP shipping label are unchanged -- that part of
  the flow is not touched.

A finished good **with** a published BOM behaves exactly as before.

### SQL -- 2 changed repeatables, no migration

| File | | Effect |
|---|---|---|
| `R__Workorder_Assembly_CompleteTray.sql` | CHANGED (v1.5) | No published BOM is the repack case instead of a refusal. Consumes 1:1 from `Received` / `ReceivedOffsite` LOTs of the same Item at the line. |
| `R__Parts_Item_ListEligibleFinishedGoodsRanked.sql` | CHANGED (v1.1) | Lists no-BOM finished goods; "satisfied" when that received stock is at the line; ranked behind a BOM'd part at equal satisfaction. |

### In the range but shipping nothing

`sql/tests/0028_PlantFloor_Assembly/100_Assembly_CompleteTray_repack.sql`, `CLAUDE.md`, `PROJECT_STATUS.md`, `notes/`.

---

## 2. What the database change is

| | |
|---|---|
| Migrations | 0 |
| Repeatables | 2 changed |
| Post-commit | `R__Descriptions_ExtendedProperties.sql` (documentation only) |
| Rehearsal lock window | 0.3 s (local sim) |

Two `CREATE OR ALTER PROCEDURE`. No table, column, index or row changes.

---

## 3. Risk

### 3.1 Does anything now refuse what it used to allow? -- no, the reverse

One refusal is removed. A finished good with no BOM used to be refused with "No active BOM"; it is now
accepted **when received stock of that part is at the line**, and otherwise refused with a message that
says how many are needed and how many are there.

### 3.2 Is any of it shared code? -- YES, the most shared proc on the floor

`Workorder.Assembly_CompleteTray` is **every non-serialized tray close in the plant**: operator by-count,
the scales, the vision cells, the MIP stations. The change is confined to the branch a part reaches only
when it has no published BOM, but the whole proc is replaced. **Section 6.2 proves a normal line still
closes a tray.**

### 3.3 What changes on lines that are NOT pass-through

A finished good with no published BOM that is eligible at a normal assembly line will now **appear** in that
line's finished-good dropdown and printer cards. It was hidden before. Two things limit this:

- It ranks behind any part that has a BOM, so it does not become the default while a BOM'd part exists.
- A tray can only be closed for it if received-origin stock of that same part is at the line.

**Step 0 counts these parts on prod before you deploy.** On Dev there is one.

### 3.4 The rule is "no BOM", not a flag

There is no pass-through marker on the part. If a real assembled finished good is missing its BOM **and**
received-origin stock of it is sitting at its line, it would be packed without consuming components. That
needs both conditions at once; Step 0's second number tells you whether prod has any such case today.

### 3.5 Does the old Ignition keep working against the new SQL? -- yes, there is no new Ignition

### 3.6 What operators will notice on day one

At a pass-through station: the Assembly tab shows the part and its pack-out instead of "No part in
production", and a tray closes. Three things to tell them:

1. **Stock must be received at the line first** (Inventory tab). The tray is packed from it.
2. **No inspection result is required.** A received LOT can be packed without one. A LOT on **Hold** is
   skipped, so placing a hold is how a failed lot is kept out of a box.
3. **A By Weight terminal still needs a By Weight pack-out with a target and tolerance** (the Pack-Out
   button), or the scale close stays disabled.

---

## 4. Deploy

Run everything from the repo root of the release checkout.

```powershell
$env:SQLCMDPASSWORD = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR((Read-Host 'Ignition SQL password' -AsSecureString)))
```

### Step 0 -- Count the parts this affects (read-only)

Run against `MPP_MES_Prod`:

```sql
WITH PT AS (
    SELECT DISTINCT t.ParentLocationId AS LineId
    FROM Location.LocationAttribute la JOIN Location.Location t ON t.Id = la.LocationId
    WHERE la.AttributeValue LIKE N'%third-party%'
), NoBom AS (
    SELECT i.Id, i.PartNumber, il.LocationId, ln.Name AS Line,
           CASE WHEN pt.LineId IS NULL THEN N'other line' ELSE N'pass-through line' END AS Kind
    FROM Parts.Item i
    JOIN Parts.ItemType it ON it.Id = i.ItemTypeId AND it.Code = N'FinishedGood'
    JOIN Parts.ItemLocation il ON il.ItemId = i.Id AND il.DeprecatedAt IS NULL
    JOIN Location.Location ln ON ln.Id = il.LocationId
    LEFT JOIN PT pt ON pt.LineId = il.LocationId
    WHERE i.DeprecatedAt IS NULL
      AND NOT EXISTS (SELECT 1 FROM Parts.Bom b WHERE b.ParentItemId = i.Id
                      AND b.PublishedAt IS NOT NULL AND b.DeprecatedAt IS NULL)
)
SELECT n.Kind, n.Line, n.PartNumber,
       ISNULL((SELECT SUM(l.InventoryAvailable) FROM Lots.Lot l
               JOIN Lots.LotOriginType o ON o.Id = l.LotOriginTypeId
               JOIN Lots.LotStatusCode sc ON sc.Id = l.LotStatusId
               WHERE l.ItemId = n.Id AND l.CurrentLocationId = n.LocationId
                 AND o.Code IN (N'Received', N'ReceivedOffsite')
                 AND sc.Code NOT IN (N'Closed', N'Open') AND sc.BlocksProduction = 0), 0) AS ReceivedStockAtLine
FROM NoBom n
ORDER BY n.Kind, n.Line, n.PartNumber;
```

Read it like this:

- **`pass-through line` rows** are the parts this release is for. The 66V row should show the stock you
  received as `ReceivedStockAtLine`. If it shows 0, the stock is at a different location or was not created
  with a received origin, and the tray will not close -- stop and tell me what the row shows.
- **`other line` rows** are finished goods that will newly appear in a normal line's dropdown. Any of them
  with `ReceivedStockAtLine` above 0 could be packed without a BOM (3.4). Decide whether that is intended
  before going on; giving the part its BOM, or leaving it, are both fine answers.

### Step 1 -- Preview (read-only, writes nothing)

```powershell
.\sql\scripts\Deploy-ProdRelease.ps1 -ServerInstance 172.17.10.148 -Username Ignition -DatabaseName MPP_MES_Prod
```

Expect (`[2]`, `[6]` and `[7]` will show prod's own values):

```
[3] Versioned migrations
  Database: 104 applied, highest 0105. Most recent:
  No pending migrations.

[4] Repeatables -- target definitions vs this checkout
  499 identical, 2 changed, 0 new on the target.
    CHANGED  R__Parts_Item_ListEligibleFinishedGoodsRanked.sql
    CHANGED  R__Workorder_Assembly_CompleteTray.sql

[8] Plan
  0 migration(s), 2 repeatable(s) in one transaction; then R__Descriptions_ExtendedProperties.sql after commit.
  Plan fingerprint: <copy this>

Verdict
  Clear to deploy. 0 warning(s) to read above.
```

**Read `[2]` every time.** It is the only line that names the database you are pointed at.

**If it differs:**

- *Any pending migration, any NEW repeatable, or a third CHANGED one* -- prod is not where this runbook
  assumes. Stop; the per-object diffs are in the report's `diffs` folder.
- *The two CHANGED diffs* are worth a glance: each should show only added lines marked `v1.5` / `v1.1`
  plus, in the ranked proc, one removed `AND EXISTS (... Parts.Bom ...)` line.
- *A WARN in `[6]`* -- a long transaction is open and will block the deploy's locks. Wait for it.

Copy the fingerprint; do not retype it. The local sim printed `6b0e104a7df4` at `f840f4b5`; yours will
differ because later commits moved `HEAD`.

### Step 2 -- Rehearse (runs the real script on live data, then rolls back)

```powershell
.\sql\scripts\Deploy-ProdRelease.ps1 -ServerInstance 172.17.10.148 -Username Ignition -DatabaseName MPP_MES_Prod -Mode Rehearse -ExpectedPlan <fingerprint>
```

Type `REHEARSE` when asked. Expect:

```
[10] Running the release transaction
    == transaction open
    == [1] R__Parts_Item_ListEligibleFinishedGoodsRanked.sql
    == [2] R__Workorder_Assembly_CompleteTray.sql
    == verifying inside the transaction
    == checks passed
    == ROLLED BACK (rehearsal / preview script) -- nothing was kept

  REHEARSAL PASSED and was rolled back. Lock window: 0.3s.
```

Replacing `Assembly_CompleteTray` waits for any tray close that is mid-flight, so the window on prod may be
a little longer. **If the rehearsal fails, stop.** Nothing was written.

### Step 3 -- Execute

```powershell
.\sql\scripts\Deploy-ProdRelease.ps1 -ServerInstance 172.17.10.148 -Username Ignition -DatabaseName MPP_MES_Prod -Mode Execute -ExpectedPlan <fingerprint>
```

Type `MPP_MES_Prod` when asked. Expect:

```
[9] Backup
  BACKUP DATABASE -> ...\MPP_MES_Prod_pre-release_0105_<stamp>.bak (COPY_ONLY, CHECKSUM)
  Backup written and verified.

[10] Running the release transaction
    == transaction open
    == [1] R__Parts_Item_ListEligibleFinishedGoodsRanked.sql
    == [2] R__Workorder_Assembly_CompleteTray.sql
    == verifying inside the transaction
    == checks passed
    == COMMITTED

[11] After commit
  R__Descriptions_ExtendedProperties.sql applied.
  Every repo migration is recorded.
  All 2 applied repeatable(s) now match the repo byte-for-byte.

DONE
```

The script ends with "Import the Ignition exports NOW". **Ignore that line for this release; there are none.**

- *`ABORT: plan is <a> but -ExpectedPlan is <b>`* -- something moved since the preview. Re-preview.
- *`FAILED -- the transaction was rolled back`* -- prod is unchanged. Read `deploy.log`.

---

## 5. Ignition imports

None. Press **F5** on the pass-through stations so the Assembly tab re-runs its default part selection.

---

## 6. Verification

### 6.1 First -- the thing never seen working: a repack tray close

At the 66v Thermo Case pass-through station, with the stock you received still at the line:

1. Open the Assembly tab. Expect the tray header to show the part's pack-out (for example "16 trays x 6
   parts/tray") instead of "Configured PartsPerTray = 0". "Now producing" stays on "No part in production"
   until the first tray opens a container; that is how every assembly line reads before its first tray.
2. Close one tray. Expect the normal tray-closed result and an open container.
3. Confirm what was written:

```sql
SELECT TOP 5 c.LotName AS TrayLot, c.PieceCount AS TrayPcs, p.LotName AS ReceivedLot, p.VendorLotNumber,
       g.PieceCount AS Taken, p.PieceCount AS ReceivedLotPcsLeft
FROM Lots.LotGenealogy g
JOIN Lots.Lot c ON c.Id = g.ChildLotId
JOIN Lots.Lot p ON p.Id = g.ParentLotId
JOIN Parts.Item i ON i.Id = c.ItemId AND i.Id = p.ItemId
WHERE g.RelationshipTypeId = 3
ORDER BY g.Id DESC;
```

Expect a row for the tray just closed: the tray LOT, the received LOT it came from with its vendor lot,
`Taken` equal to the tray size, and the received LOT's count down by that amount.

4. Fill and complete the container. Expect the MPP shipping label and AIM serial exactly as on any other
   assembly-out box.

**What each wrong result means:**

- *Still "Configured PartsPerTray = 0"* -- the part has no pack-out for this terminal's closure method. Use
  Pack-Out to add one.
- *"Insufficient received stock of this part at the line to repackage (need N, have M)"* -- the proc is
  working and cannot see the stock. `M` is what it found. The stock is at another location, on Hold, or was
  not created as a received LOT. Step 0's query shows which.
- *"Insufficient component stock at the line -- short: ..."* -- the part **does** have a published BOM, so
  this is ordinary assembly-out and not a repack. Nothing in this release applies to it.
- *The tray closes but the query shows nothing* -- report it; that would mean a tray was minted without a
  source, which the proc is written never to do.

### 6.2 Shared code -- prove a surface that is NOT the feature

After the next tray on any normal assembly line (operator, scale or vision), confirm it booked and consumed
components as before:

```sql
SELECT TOP 5 CAST(ce.ConsumedAt AT TIME ZONE 'UTC' AT TIME ZONE 'Eastern Standard Time' AS DATETIME2(0)) AS ConsumedET,
       pi.PartNumber AS Produced, ci.PartNumber AS Consumed, ce.PieceCount
FROM Workorder.ConsumptionEvent ce
JOIN Parts.Item pi ON pi.Id = ce.ProducedItemId
JOIN Parts.Item ci ON ci.Id = ce.ConsumedItemId
ORDER BY ce.Id DESC;
```

Expect rows newer than the release time where `Produced` and `Consumed` are **different** part numbers.
**If normal lines are running and no such rows appear, or operators report trays failing, treat it as this
release** and go to section 7.

### 6.3 Quick SQL proof

```sql
SELECT OBJECT_NAME(object_id) AS Proc,
       CASE WHEN definition LIKE N'%@Repack%' OR definition LIKE N'%at equal satisfaction%' THEN 1 ELSE 0 END AS HasRepack
FROM sys.sql_modules
WHERE object_id IN (OBJECT_ID(N'Workorder.Assembly_CompleteTray'), OBJECT_ID(N'Parts.Item_ListEligibleFinishedGoodsRanked'));
```

Expect two rows, both `HasRepack = 1`.

---

## 7. Rollback

**Before COMMIT:** automatic.

**After COMMIT:** put the two procs back to their previous text. From the repo root:

```bash
git checkout 20334b41 -- sql/migrations/repeatable/R__Workorder_Assembly_CompleteTray.sql sql/migrations/repeatable/R__Parts_Item_ListEligibleFinishedGoodsRanked.sql
```

Commit that, then run Preview -> Rehearse -> Execute again; the preview should show the same two procs as
CHANGED. Pass-through parts go back to being unselectable. Trays already packed stay valid: they are
ordinary LOTs in ordinary containers and nothing about them depends on the new code.

There is no Ignition half.

---

## 8. Outcome -- filled in after the release

_(still to fill in)_

| | |
|---|---|
| Executed at | |
| Prod before | SQL `0105`, 104 migrations |
| Step 0: pass-through rows / other-line rows / any with stock | |
| Plan fingerprint | |
| Backup path | |
| Preview `[4]` | |
| Live activity `[6]` | |
| Prod rehearsal lock window | |
| Report folder | |
| 6.1 first repack tray (part, tray LOT, received LOT) | |
| 6.1 container completed, label + AIM | |
| 6.2 a normal line still consumes components | |

**What went differently from the plan:**

_(still to fill in)_
