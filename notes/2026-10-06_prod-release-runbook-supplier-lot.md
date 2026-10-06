# Prod release runbook -- supplier lot required on purchased-part check-in

**Release commit:** `2e8b6847` on `jacques/working` -- the commit the archives were built and verified from.
**Previous release:** `882d0736` (2026-10-05, D/C part level; prod's 13:21 Execute reported "already matches
this checkout"). Prod is at SQL **`0104`**, 103 migrations applied.
**Rehearsed against:** `MPP_MES_ProdSimVL`, built at `882d0736` -- prod's migration state (103 applied,
highest `0104`, `Lots.Lot_Create` without `@RequireVendorLot`). Preview + Rehearse clean, rollback verified.
A full **Execute** was then run against a second sim, `MPP_MES_ProdSimVL2`, to cover the backup, the
post-commit step and the section 6.4 proofs. `MPP_MES_ProdSimVL` is still at prod's state.
**SQL suite:** 4238 assertions / 4238 passed / 0 failed (run at `d88350b4`; `sql/` has not moved since).

> **Assumption to confirm in the preview.** This runbook assumes yesterday's Ignition imports
> (`dcpartlevel_2026-10-05_1308`) were completed on the prod Gateway. The SQL side is on record; the
> imports are not, because the 2026-10-01 runbook's Outcome section was never filled in.

> **Nothing may be committed between the preview you read and the Execute.** The plan fingerprint's first
> hashed line is the raw `HEAD` sha, so any commit changes it -- a docs-only commit included -- and Execute
> refuses. Re-preview and use the new fingerprint.
>
> **Two separate tests.** A docs-only commit invalidates the fingerprint but leaves the archives valid:
> ```bash
> git diff --stat 2e8b6847..HEAD -- ignition/ sql/
> ```
> Expect **no output**. Anything listed means the archives are stale: rebuild them, then re-preview.

---

## 1. What this ships

An operator adding a box of purchased parts must now give the supplier's lot number, by scan or on-screen
keyboard, or press **No lot on box**.

- **Line Inventory panel** (assembly and machining terminals): every add opens a new popup that asks for the
  supplier lot and the quantity. This includes the one-tap `+<box qty>` buttons, which now open the popup
  with the quantity already filled in instead of adding immediately.
- **Cutover Scan**, purchased-box form: the supplier lot is required, and there is a **No lot on box**
  button beside it. The field label changes from "Vendor lot -- optional" to "Supplier lot -- required".
- **No lot on box** stores the marker `NONE` in `Lots.Lot.VendorLotNumber`.
- **Unchanged on purpose:** Inventory Manager's receive form and Receiving Dock still treat the supplier lot
  as optional.

### SQL -- no migrations, 1 repeatable

| File | | Effect |
|---|---|---|
| `R__Lots_Lot_Create.sql` | CHANGED | v1.8. Two new optional parameters, `@RequireVendorLot` and `@VendorLotAbsent`, both default 0. Supplier lot trimmed on every call. |

### Ignition -- 9 resources, no deletions

| Project | | Resource |
|---|---|---|
| Core | MOD | `named-query/lots/Lot_Create` |
| Core | MOD | `script-python/BlueRidge/Lots/Lot` |
| Core | MOD | `script-python/BlueRidge/Cutover/Scan` |
| MPP | MOD | `session-props` |
| MPP | NEW | `views/BlueRidge/Components/PlantFloor/AddLotBox` |
| MPP | MOD | `views/BlueRidge/Components/PlantFloor/LineInventoryRow` |
| MPP | MOD | `views/BlueRidge/Views/ShopFloor/_CutoverScan/Desktop` |
| MPP | MOD | `views/BlueRidge/Views/ShopFloor/_CutoverScan/Phone` |
| MPP | MOD | `views/BlueRidge/Views/ShopFloor/_CutoverScan/Tablet` |

`MPP_Config` has no changed resources and is not part of this release.

### In the range but shipping nothing

`docs/superpowers/` (spec and plan), `notes/`, `PROJECT_STATUS.md`, and the new test file
`sql/tests/0020_PlantFloor_Foundation/043_Lot_Create_require_vendor_lot.sql`.

`Components/PlantFloor/AddLotQty` (the old numpad popup) is left in place. Nothing opens it after this
release. It is not deleted here.

---

## 2. What the database change is

| | |
|---|---|
| Migrations | 0 |
| Repeatables | 1 changed -- `R__Lots_Lot_Create.sql` |
| Post-commit | `R__Descriptions_ExtendedProperties.sql` (documentation only) |
| Rehearsal lock window | 0.1 s (local sim) |

One `CREATE OR ALTER PROCEDURE`. No table, column, index or data is touched. The two new parameters default
to 0, so every existing caller behaves as before until the Ignition import turns the requirement on.

---

## 3. Risk

### 3.1 Does anything now refuse what it used to allow? -- YES, and that is the point

After the imports, two screens refuse a purchased box with no supplier lot and no **No lot on box** answer:

- **Line Inventory.** The popup's Add button stays disabled until one of the two is given. Nobody is blocked:
  **No lot on box** is one tap.
- **Cutover Scan.** Add box is refused with "Supplier lot number is required." The way out is the same
  button.

**If cutover scanning is still in progress on site, this lands in the middle of it.** Tell whoever is
scanning purchased boxes before the import, not after.

There is no backlog of rows in a newly refused state; the rule applies only to boxes added from now on.
For context on how much of a habit change this is, run this read-only query before the window:

```sql
SELECT COUNT(*) AS ReceivedLots30d,
       SUM(CASE WHEN l.VendorLotNumber IS NULL THEN 1 ELSE 0 END) AS WithoutSupplierLot
FROM Lots.Lot l
JOIN Lots.LotOriginType o ON o.Id = l.LotOriginTypeId
WHERE o.Code = N'Received' AND l.CreatedAt >= DATEADD(DAY, -30, SYSUTCDATETIME());
```

### 3.2 Is any of it shared code? -- YES

`BlueRidge.Lots.Lot` and the `lots/Lot_Create` named query are how **every** LOT is created, die cast
baskets included. The change to `create()` is two extra parameters sent as 0, but it is on the path every
press uses. Section 6.2 proves a surface that is not this feature.

`session-props` is shared by every MPP session. The change is one added key
(`cutover.purchased.vendorLotAbsent: false`). The committed file was checked for baked-in live data: the
cutover block is empty defaults.

### 3.3 Is the schema change metadata-only? -- there is no schema change

### 3.4 Does the old Ignition keep working against the new SQL? -- yes; the reverse does NOT

- **New SQL, old Ignition:** fine. The new parameters default to 0. There is no rush between the SQL step
  and the imports.
- **New Core, old SQL:** broken. The named query passes `@RequireVendorLot`, which the old proc does not
  have, so **every LOT creation in the plant fails**. SQL first is not a formality for this release.
- **New Core, old MPP:** the Line Inventory buttons still use the old path, which sends no supplier lot and
  is now refused. Import the MPP archive straight after Core; do not stop between them.

### 3.5 What operators will notice on day one

- `+ LOT` and one-tap buttons on Line Inventory open a larger popup with a keyboard. One-tap is now
  scan-then-tap.
- Cutover Scan's purchased form has a new button and refuses a blank supplier lot.
- Sessions left open across the import must be reloaded (F5).

How many parts are one-tap on prod (Dev has none, so that path was not seen on screen):

```sql
SELECT COUNT(*) AS OneTapParts
FROM Parts.Item i JOIN Parts.ItemType t ON t.Id = i.ItemTypeId
WHERE t.Code = N'PassThrough' AND i.BoxQuantity IS NOT NULL AND i.DeprecatedAt IS NULL;
```

---

## 4. Deploy

Run everything from the repo root of the release checkout. Have the Designer open on the prod Gateway with
both zips to hand before Step 1.

Password into a masked variable first (it never goes on a command line):

```powershell
$env:SQLCMDPASSWORD = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR((Read-Host 'Ignition SQL password' -AsSecureString)))
```

### Step 1 -- Preview (read-only, writes nothing)

```powershell
.\sql\scripts\Deploy-ProdRelease.ps1 -ServerInstance 172.17.10.148 -Username Ignition -DatabaseName MPP_MES_Prod
```

Expect (from the local sim; `[2]`, `[6]` and `[7]` will show prod's own values):

```
[2] Connection
  ... MPP_MES_Prod: ONLINE ...

[3] Versioned migrations
  Database: 103 applied, highest 0104. Most recent:
    0104_item_dc_part_level
    0103_container_label_serial_text_and_partext_barcode
    ...
  No pending migrations.

[4] Repeatables -- target definitions vs this checkout
  498 identical, 1 changed, 0 new on the target.
    CHANGED  R__Lots_Lot_Create.sql

[5] Pre-flight gates (read-only, against live data)

[8] Plan
  0 migration(s), 1 repeatable(s) in one transaction; then R__Descriptions_ExtendedProperties.sql after commit.
  Plan fingerprint: <copy this>

Verdict
  Clear to deploy. 0 warning(s) to read above.
```

**Read `[2]` every time.** It is the only line that names the database you are pointed at.

**If it differs:**

- *Any pending migration* -- prod is behind where this runbook assumes. Stop and reconcile.
- *More than 1 changed repeatable* -- prod has drifted from git, or something was never deployed. Read the
  per-object diffs in the report's `diffs` folder before continuing.
- *0 changed, "already matches this checkout"* -- the proc is already there. Skip to section 5.
- *A WARN in `[6]`* -- a long transaction is open and will block the deploy's lock. Wait for it.

**Take the fingerprint from this preview.** The local sims printed `61330c48d648` at `2e8b6847`; yours will
differ because this runbook was committed afterwards. Copy it, do not retype it.

### Step 2 -- Rehearse (runs the real script on live data, then rolls back)

```powershell
.\sql\scripts\Deploy-ProdRelease.ps1 -ServerInstance 172.17.10.148 -Username Ignition -DatabaseName MPP_MES_Prod -Mode Rehearse -ExpectedPlan <fingerprint>
```

Type `REHEARSE` when asked. Expect:

```
[10] Running the release transaction
    == transaction open
    == [1] R__Lots_Lot_Create.sql
    == verifying inside the transaction
    == checks passed
    == ROLLED BACK (rehearsal / preview script) -- nothing was kept

  REHEARSAL PASSED and was rolled back. Lock window: 0.1s.
```

The lock window on prod will be longer than 0.1 s with the plant running; earlier releases measured 0.2 s
to 2.9 s. **If the rehearsal fails, stop.** It failed against prod's real state and nothing was written.

### Step 3 -- Execute

```powershell
.\sql\scripts\Deploy-ProdRelease.ps1 -ServerInstance 172.17.10.148 -Username Ignition -DatabaseName MPP_MES_Prod -Mode Execute -ExpectedPlan <fingerprint>
```

Type `MPP_MES_Prod` when asked. Expect:

```
[9] Backup
  BACKUP DATABASE -> ...\MPP_MES_Prod_pre-release_0104_<stamp>.bak (COPY_ONLY, CHECKSUM)
  Backup written and verified.

[10] Running the release transaction
    == transaction open
    == [1] R__Lots_Lot_Create.sql
    == verifying inside the transaction
    == checks passed
    == COMMITTED

[11] After commit
  R__Descriptions_ExtendedProperties.sql applied.
  Every repo migration is recorded.
  All 1 applied repeatable(s) now match the repo byte-for-byte.

DONE
```

Note the `.bak` path for section 8.

- *`ABORT: plan is <a> but -ExpectedPlan is <b>`* -- something moved since the preview. Re-preview, read the
  new plan, use the new fingerprint. Never `-Force` past it.
- *`FAILED -- the transaction was rolled back`* -- prod is unchanged. Read `deploy.log`. Do not import.

---

## 5. Ignition imports

**Only after Step 3 prints `COMMITTED`.** Designer -> File -> Import, one zip at a time, accepting overwrite
for the listed resources. Do not use the Gateway web page's project import.

Archives, in `dist\ignition-exports\`, built from git at `2e8b6847` and verified entry by entry against it
(17 of 18 resource files byte-identical; the one difference is the Phone view's manifest, rewritten by the
builder to drop `thumbnail.png`):

1. **`Core_supplier-lot_2026-10-06_0819.zip`** -- 3 resources, 7 entries
   - MOD `ignition/named-query/lots/Lot_Create`
   - MOD `ignition/script-python/BlueRidge/Cutover/Scan`
   - MOD `ignition/script-python/BlueRidge/Lots/Lot`
2. **`MPP_supplier-lot_2026-10-06_0819.zip`** -- 6 resources, 13 entries. **Import immediately after Core.**
   - MOD `com.inductiveautomation.perspective/session-props`
   - NEW `.../views/BlueRidge/Components/PlantFloor/AddLotBox`
   - MOD `.../views/BlueRidge/Components/PlantFloor/LineInventoryRow`
   - MOD `.../views/BlueRidge/Views/ShopFloor/_CutoverScan/Desktop`
   - MOD `.../views/BlueRidge/Views/ShopFloor/_CutoverScan/Phone`
   - MOD `.../views/BlueRidge/Views/ShopFloor/_CutoverScan/Tablet`
3. **`MPP_Config`** -- nothing to import.

No deletions and no hand steps.

Then **reload every open Perspective session** (F5 on each shop-floor screen).

---

## 6. Verification

### 6.1 First -- the two things never seen working

1. **A scanner read into the popup.** On a line terminal, tap `+ LOT`, and scan a supplier label with the
   handheld. The value should land in the Supplier lot field, and the scanner's Enter should switch the
   keypad to the numpad. Everything else about the popup was driven on Dev with the on-screen keys; a real
   wedge scan was not.
   *If the scan lands nowhere:* tap the Supplier lot field once and scan again. If that works, the popup's
   startup focus is not taking and operators need that extra tap until it is fixed.
2. **A one-tap part.** If the section 3.5 query returned any, tap one. The popup should open with the box
   quantity already in Quantity. Dev has no one-tap parts, so this was never seen.

### 6.2 Shared code -- prove a surface that is NOT the feature

After the imports, confirm the next die cast basket was created normally:

```sql
SELECT TOP 3 l.LotName, l.PieceCount, o.Code AS Origin,
       CAST(l.CreatedAt AT TIME ZONE 'UTC' AT TIME ZONE 'Eastern Standard Time' AS DATETIME2(0)) AS CreatedET
FROM Lots.Lot l JOIN Lots.LotOriginType o ON o.Id = l.LotOriginTypeId
WHERE o.Code = N'Manufactured'
ORDER BY l.Id DESC;
```

Expect a row newer than the import time once a press has booked a basket. **If presses are running and no
new row appears, or operators report a failed basket entry, treat it as this release** and go to section 7.

Also add one box through **Inventory Manager's receive form** with the supplier lot left blank. It should still succeed: that screen was left optional.

### 6.3 The feature

1. Line Inventory `+ LOT`: type a supplier lot, Enter, key a quantity, Add. Toast "Box checked in".
2. Same popup: **No lot on box**, key a quantity, Add.
3. Cutover Scan, purchased form, supplier lot blank: Add box is refused with "Supplier lot number is
   required."
4. Cutover Scan: **No lot on box**, then Add box succeeds.

```sql
SELECT TOP 4 l.LotName, l.PieceCount, l.VendorLotNumber, i.PartNumber
FROM Lots.Lot l JOIN Parts.Item i ON i.Id = l.ItemId
JOIN Lots.LotOriginType o ON o.Id = l.LotOriginTypeId
WHERE o.Code = N'Received' ORDER BY l.Id DESC;
```

Expect the typed supplier lot on the first check's row and `NONE` on the rows from checks 2 and 4.

### 6.4 Quick SQL proofs (confirmed on `MPP_MES_ProdSimVL2` after a real Execute)

```sql
SELECT name FROM sys.parameters
WHERE object_id = OBJECT_ID('Lots.Lot_Create') AND name IN ('@RequireVendorLot','@VendorLotAbsent')
ORDER BY parameter_id;
```

Expect 2 rows: `@RequireVendorLot`, `@VendorLotAbsent`.

```sql
SELECT COUNT(*) AS Applied, MAX(MigrationId) AS Highest FROM dbo.SchemaVersion;
```

Expect `103`, `0104_item_dc_part_level` (unchanged; this release has no migration).

---

## 7. Rollback

**Before COMMIT:** automatic. Any error rolls the transaction back and prod is unchanged.

**After COMMIT, SQL:** leave it. Proc v1.8 behaves exactly like v1.7 for any caller that does not set the
new parameters, so there is nothing to gain from reverting it and no restore is warranted.

**The Ignition half is the real rollback.** There is no switch that turns the requirement off. To return to
the previous behaviour, build the previous definitions and import them, Core first:

```powershell
.\tools\Build-ChangeExport.ps1 -Since 2e8b6847 -Until 882d0736 -Label supplier-lot-rollback
```

Read its `CONTENTS.txt` before importing; this reversed build has never been used in a real rollback.
`AddLotBox` was added by this release and is not removed by that import. It is harmless once
`LineInventoryRow` is back to the old version; delete it in the Designer if you want it gone.

**If LOT creation is failing plant-wide after the Core import** (section 6.2), the cause is almost certainly
Core imported against the old proc. Check section 6.4's first query: if it returns 0 rows, the SQL step did
not commit. Run Step 3; do not roll Ignition back.

---

## 8. Outcome -- filled in after the release

_(still to fill in)_

| | |
|---|---|
| Executed at (ET) | |
| Prod before | SQL `0104`, 103 migrations |
| Plan fingerprint | |
| Backup path | |
| Preview `[4]` | |
| Live activity `[6]` | |
| Prod rehearsal lock window | |
| Report folder | |
| Section 3.1 query (received / without supplier lot) | |
| Section 3.5 query (one-tap parts) | |
| 6.1 scanner read | |
| 6.1 one-tap part | |

**What went differently from the plan:**

_(still to fill in)_
