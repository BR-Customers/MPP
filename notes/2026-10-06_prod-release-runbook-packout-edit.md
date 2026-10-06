# Prod release runbook -- Pack-Out editing on the Pass-Through Parts screen

**Release commit:** `20334b41` on `jacques/working` -- the commit the archives were built and verified from.
**Previous release:** `5c482c49` (2026-10-06, EPrint scale watcher). Jacques confirmed on 2026-10-06 that it
was executed: prod is at SQL **`0105`**, 104 migrations applied.
**Rehearsed against:** `MPP_MES_ProdSimEP2`, at prod's migration state (104 applied, highest `0105`, no
`Parts.ContainerConfig_ListHistory`). Preview, Rehearse and a full Execute all clean.
The SQL rehearsal ran at `2c40a81a`; `20334b41` changes two `view.json` files and no SQL
(`git diff --stat 2c40a81a..20334b41 -- sql/` prints nothing).
**SQL suite:** 4263 assertions / 4263 passed / 0 failed (the previous release's 4252 plus 11 new), run on
`MPP_MES_Test_PO` with this release's SQL.

> **Nothing may be committed between the preview you read and the Execute.** The plan fingerprint's first
> hashed line is the raw `HEAD` sha, so any commit changes it -- a docs-only commit included -- and Execute
> refuses. Re-preview and use the new fingerprint.
>
> **Two separate tests.** A docs-only commit invalidates the fingerprint but leaves the archives valid:
> ```bash
> git diff --stat 20334b41..HEAD -- ignition/ sql/
> ```
> Expect **no output**. Anything listed means the archives are stale: rebuild them, then re-preview.

---

## 1. What this ships

On the **Pass-Through Parts** screen, the Assembly tab gains a **Pack-Out** button. It opens a popup where
the operator sets a part's container configuration without going to the Config Tool:

- **Part** -- a dropdown of the parts eligible at this line. It is preselected when the screen already has
  a part (an open container, or the picked finished good), and when the line has only one eligible part.
- **By Count / By Weight / By Vision** -- the same pack-outs and the same fields as Item Master's Container
  Config tab, with Add and Clear per method.
- **Numpad** -- tap a number field (it is outlined) and the keypad types into it. A separate decimal-point
  key is enabled on the two weight fields. The keyboard works too.
- **Load a previous pack-out** -- per method, a dropdown of value sets this part used before. Picking one
  fills the fields; nothing changes until Save.

**Any signed-in operator can use it. There is no supervisor elevation.** That is a decision, not an
omission: parts run through the pass-through stations never run through die cast, and a pack-out change
mid-run is acceptable there. The change is written through the existing container-config procs, so it is
validated and audited to the signed-in person exactly as a Config Tool edit is.

After Save, the Assembly tab re-reads the pack-out immediately. If no part was selected because none had a
pack-out for the terminal's closure method, the screen re-runs its default part selection.

**The button appears only on the Pass-Through Parts screen.** Every other non-serialized assembly line uses
the same underlying view and does not get it.

### SQL

| File | | Effect |
|---|---|---|
| `R__Parts_ContainerConfig_ListHistory.sql` | NEW | Read proc. Past pack-out value sets for a part: the values each in-place update replaced (from `Audit.ConfigLog`) plus cleared pack-outs, de-duplicated, without the set that is currently live. Top 30. |

### Ignition -- 5 resources, no deletions

| Project | | Resource |
|---|---|---|
| Core | NEW | `named-query/parts/ContainerConfig_ListHistory` |
| Core | MOD | `script-python/BlueRidge/Parts/ContainerConfig` -- three added functions: `getDraftForItem`, `saveDraft`, `getHistoryForItem`. No existing function is edited. |
| MPP | NEW | `views/BlueRidge/Components/Popups/PackOutEdit` |
| MPP | MOD | `views/BlueRidge/Views/ShopFloor/AssemblyNonSerialized` |
| MPP | MOD | `views/BlueRidge/Views/ShopFloor/ThirdPartyInspection` -- passes one param |

`MPP_Config` has no changed resources and is not part of this release. The Item Master Container Config tab
is untouched.

### In the range but shipping nothing

`sql/tests/0008_Parts_Item/030_ContainerConfig_ListHistory.sql` and `notes/`.

---

## 2. What the database change is

| | |
|---|---|
| Migrations | 0 |
| Repeatables | 1 new -- `R__Parts_ContainerConfig_ListHistory.sql` |
| Post-commit | `R__Descriptions_ExtendedProperties.sql` (documentation only) |
| Rehearsal lock window | 0.2 s (local sim) |

One new read-only stored procedure. No table, column, index or row is created or changed. No
release-specific gate was written: a new read proc gives the same result whatever the plant is doing.

---

## 3. Risk

### 3.1 Does anything now refuse what it used to allow? -- no

No existing proc gains a validation. The popup's saves go through `ContainerConfig_Create` / `_Update` /
`_Deprecate` unchanged.

### 3.2 Is any of it shared code? -- YES, two pieces

- **`AssemblyNonSerialized` is the screen for every non-serialized assembly line**, not just the
  pass-through stations. What changes for the other lines: a hidden button (its `allowPackOutEdit` param
  defaults to false), one new custom property, one extra argument on the pack-out read that stays constant
  unless a Pack-Out save happens, and a message handler nothing else sends. None of that should be visible,
  but it is a re-import of a view those lines run on. **Section 6.2 proves one of them still closes a tray.**
- **`BlueRidge.Parts.ContainerConfig`** backs the Item Master Container Config tab, the assembly-out
  pack-out header, and the EPrint checkweigh verdict. Three functions added, none edited. Section 6.2
  covers the Item Master tab.

### 3.3 Is the schema change metadata-only? -- there is no schema change

### 3.4 Does the old Ignition keep working against the new SQL? -- yes, and the reverse

- **New SQL, old Ignition:** nothing calls the new proc.
- **New Ignition, old SQL:** the popup opens and saves; only the history dropdowns stay empty, because that
  read is guarded and returns nothing on failure. Do SQL first anyway.

The SQL step and the imports are independent. There is no rush between them.

### 3.5 What operators will notice on day one

A **Pack-Out** button on the Pass-Through Parts Assembly tab. Tell the pass-through operators three things:

1. A saved pack-out takes effect at once, for the trays closed after the save.
2. On a by-weight terminal with a scale, saving re-sends the target weight and tolerance to the scale.
3. Check the number shown in the field before pressing Save. Keys pressed faster than the screen can echo
   them can land out of order (the PIN pad behaves the same way).

The Part dropdown lists every part eligible at the line, not only finished goods.

---

## 4. Deploy

Run everything from the repo root of the release checkout.

Password into a masked variable first (it never goes on a command line):

```powershell
$env:SQLCMDPASSWORD = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR((Read-Host 'Ignition SQL password' -AsSecureString)))
```

### Step 1 -- Preview (read-only, writes nothing)

```powershell
.\sql\scripts\Deploy-ProdRelease.ps1 -ServerInstance 172.17.10.148 -Username Ignition -DatabaseName MPP_MES_Prod
```

Expect (`[2]`, `[6]` and `[7]` will show prod's own values):

```
[3] Versioned migrations
  Database: 104 applied, highest 0105. Most recent:
    0105_plcdevicetype_scalestation_eprint
    0104_item_dc_part_level
    ...
  No pending migrations.

[4] Repeatables -- target definitions vs this checkout
  500 identical, 0 changed, 1 new on the target.
    NEW      R__Parts_ContainerConfig_ListHistory.sql

[8] Plan
  0 migration(s), 1 repeatable(s) in one transaction; then R__Descriptions_ExtendedProperties.sql after commit.
  Plan fingerprint: <copy this>

Verdict
  Clear to deploy. 0 warning(s) to read above.
```

**Read `[2]` every time.** It is the only line that names the database you are pointed at.

**If it differs:**

- *Any pending migration, or any CHANGED repeatable* -- prod is not where this runbook assumes. Stop and
  reconcile; per-object diffs are in the report's `diffs` folder.
- *"already matches this checkout"* -- the SQL is already there. Skip to section 5.
- *A WARN in `[6]`* -- a long transaction is open and will block the deploy's locks. Wait for it.

**Take the fingerprint from this preview.** The local sim printed `ac0f42f9f7bd` at `2c40a81a`; yours will
differ because later commits moved `HEAD`. Copy it, do not retype it.

### Step 2 -- Rehearse (runs the real script on live data, then rolls back)

```powershell
.\sql\scripts\Deploy-ProdRelease.ps1 -ServerInstance 172.17.10.148 -Username Ignition -DatabaseName MPP_MES_Prod -Mode Rehearse -ExpectedPlan <fingerprint>
```

Type `REHEARSE` when asked. Expect:

```
[10] Running the release transaction
    == transaction open
    == [1] R__Parts_ContainerConfig_ListHistory.sql
    == verifying inside the transaction
    == checks passed
    == ROLLED BACK (rehearsal / preview script) -- nothing was kept

  REHEARSAL PASSED and was rolled back. Lock window: 0.2s.
```

**If the rehearsal fails, stop.** It failed against prod's real state and nothing was written.

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
    == [1] R__Parts_ContainerConfig_ListHistory.sql
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

Archives, in `dist\ignition-exports\`, built from git at `20334b41` and compared entry by entry with it.
Every entry is byte-identical to `HEAD` except `AssemblyNonSerialized/resource.json`, which the builder
rewrites on purpose to stop naming the excluded `thumbnail.png`.

1. **`Core_packout-edit_2026-10-06_1307.zip`** -- 2 resources, 5 entries
   - NEW `ignition/named-query/parts/ContainerConfig_ListHistory`
   - MOD `ignition/script-python/BlueRidge/Parts/ContainerConfig`
2. **`MPP_packout-edit_2026-10-06_1307.zip`** -- 3 resources, 7 entries
   - NEW `views/BlueRidge/Components/Popups/PackOutEdit`
   - MOD `views/BlueRidge/Views/ShopFloor/AssemblyNonSerialized`
   - MOD `views/BlueRidge/Views/ShopFloor/ThirdPartyInspection`
3. **`MPP_Config`** -- nothing to import.

No deletions. No tags, devices or Gateway settings.

This Core archive's `ContainerConfig` script is the EPrint release's version plus three functions, so it
imports cleanly over what that release put there.

**Then reload the open sessions.** F5 on each non-serialized assembly workstation and each pass-through
station. This release changes a view those sessions have open, and on the Dev Gateway a session left open
across the update stopped responding to its buttons until it was reloaded.

---

## 6. Verification

### 6.1 First -- what was never seen working

Everything in the popup was exercised on the Dev Gateway in a desktop browser: open, part list, load, numpad
typing, decimal key, Save, the audit row, the header updating, and loading and saving a previous pack-out.
Four things were **not** observed. Check them in this order at one pass-through station:

1. **On a real touch screen**, tap a number field and confirm it is outlined and the keypad types into it.
   Dev testing used a mouse. If tapping does not select the field, the keyboard still works; report it.
2. **On a by-weight terminal with a scale**, save a By Weight pack-out and confirm the scale takes the new
   target. Dev has no scale mapped, so the re-send was never seen. A red "Scale setpoint not sent" toast
   means the pack-out saved but the scale did not take it.
3. **With no part selected** ("No part in production"), add a pack-out for the terminal's closure method and
   save. Expect the screen to pick the part up. This path could not be reached on Dev. If it stays on "No
   part in production", press F5; if it is still empty, the part is being left out for another reason (the
   default selection only offers finished goods that have a published BOM).
4. **Type at a normal pace and read the field before Save.** See 3.5.

Then confirm the write and who it was credited to:

```sql
SELECT TOP 5 CAST(cl.LoggedAt AT TIME ZONE 'UTC' AT TIME ZONE 'Eastern Standard Time' AS DATETIME2(0)) AS LoggedET,
       u.Initials, cl.Description
FROM Audit.ConfigLog cl
JOIN Audit.LogEntityType et ON et.Id = cl.LogEntityTypeId AND et.Code = N'ContainerConfig'
LEFT JOIN Location.AppUser u ON u.Id = cl.UserId
ORDER BY cl.Id DESC;
```

Expect the newest row to be the edit just made, with the operator's initials. **A row credited to `DEV` or
`SYS` is wrong** -- report it.

### 6.2 Shared code -- prove surfaces that are NOT the feature

1. **A non-pass-through, non-serialized assembly line.** After F5, confirm there is **no** Pack-Out button,
   the header shows the part and its trays-by-parts as before, and the next tray closes normally.
2. **Item Master -> any finished good -> Container Config tab** loads and saves as before.

If either fails, treat it as this release and go to section 7.

A warning that predates this release may appear in the Gateway log when the assembly screen opens:
`Error running property change script on view.custom.closureMethodTracker ... no attribute 'container'`.
It was seen on Dev before and after this change and is not caused by it.

### 6.3 Quick SQL proofs (confirmed on `MPP_MES_ProdSimEP2` after a real Execute)

```sql
SELECT COUNT(*) AS Applied, MAX(MigrationId) AS Highest FROM dbo.SchemaVersion;
```

Expect `104`, `0105_plcdevicetype_scalestation_eprint` (unchanged: this release adds no migration).

```sql
EXEC Parts.ContainerConfig_ListHistory @ItemId = -1;
```

Expect the column headers and zero rows.

---

## 7. Rollback

**Before COMMIT:** automatic. Any error rolls the transaction back and prod is unchanged.

**After COMMIT, SQL:** leave it. One uncalled read proc. No restore is warranted.

**A wrong pack-out saved from the floor:** open Pack-Out, pick the earlier values from **Load a previous
pack-out**, Save. Or correct it in Item Master.

**The Ignition half:** only if section 6.2 fails. Build the previous definitions and import Core, then MPP:

```powershell
.\tools\Build-ChangeExport.ps1 -Since 20334b41 -Until 5c482c49 -Label packout-edit-rollback
```

Read its `CONTENTS.txt` before importing; a reversed build has not been used in a real rollback. It restores
the three modified resources. The two NEW ones (`PackOutEdit`, the named query) are not removed by it and
are inert once the button is gone; delete them in the Designer if you want them gone. Reload sessions after.

---

## 8. Outcome

Released 2026-10-06. Filled in from the deploy reports on the release machine and Jacques's confirmation.

| | |
|---|---|
| Executed at | 2026-10-06 13:23 (report stamp, release machine's clock) |
| Prod before | SQL `0105`, 104 migrations |
| HEAD at execute | `46464cb8` (docs-only after release commit `20334b41`) |
| Plan fingerprint | `bc14efbb42f0` |
| Backup path | `C:\Program Files\Microsoft SQL Server\MSSQL16.MSSQLSERVER\MSSQL\Backup\MPP_MES_Prod_pre-release_0105_20261006_132356.bak` |
| Preview `[4]` | 500 identical, 0 changed, 1 new -- as predicted |
| Live activity `[6]` | 36 open baskets, 1 running shift; 0 warnings |
| Prod rehearsal lock window | 0.4 s |
| Execute | `COMMITTED`, sqlcmd 0.3 s; post-commit proofs both green |
| Report folder | `dist\deploy-reports\MPP_MES_Prod_Execute_20261006_132356` |
| Ignition imports | Done (Jacques) |
| 6.1 touch / scale / no-part / audit row | Not recorded per check. Jacques: "looks good". |
| 6.2 other line still closes a tray; Item Master tab | Not recorded per check. |

**What went differently from the plan:**

Nothing reported. The section 6.1 items (touch-screen field selection, the scale setpoint re-send, the
no-part-selected path) were named as unverified before the release; no individual result for them was
written down, so treat them as unconfirmed until someone notes one.
