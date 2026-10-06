# Prod release runbook -- Container label barcodes: Code 128 with data identifiers

**Release commit:** `44ea9f82` on `jacques/working`.
**Previous release:** `20334b41` (2026-10-06, Pack-Out editing) is the last one CONFIRMED on prod: SQL `0105`,
104 migrations. The pass-through repack release (`f840f4b5`) was packaged the same day and its Outcome is
not filled in -- **this runbook covers both cases** (State A / State B below).
**Rehearsed against:** `MPP_MES_ProdSimEP2` (prod's confirmed state, repack procs absent) -- Preview +
Rehearse clean, rolled back. A full **Execute** was run against `MPP_MES_ProdSimEP` (same state plus the
repack procs) to cover the backup and post-commit steps.
**SQL suite:** 4292 assertions / 4292 passed / 0 failed on `MPP_MES_Test` (previous 4285 plus 7 new).

> **SQL only. No Ignition archives, nothing to import.**

> **Read this before deciding to ship.** This label has **never been printed on a real Zebra.** Dev has no
> printer. The ZPL is proven as text (the render tests assert the four fields), not as ink. The Code 128
> symbology was inferred from tape-measure lengths of the AIM label, not reported by a scanner. Section 6.1
> -- print one label and scan all four barcodes -- is the first real proof. Do it before a second container
> is completed.

> **Nothing may be committed between the preview you read and the Execute.** Any commit changes the
> fingerprint and Execute refuses. Re-preview and use the new fingerprint.
> ```bash
> git diff --stat 44ea9f82..HEAD -- sql/
> ```
> Expect **no output**.

---

## 1. What this ships

The four linear barcodes on the MPP container shipping label change so that they scan the same as the label
Honda's AIM batch-print tool produces. Compared onsite 2026-10-06 on part `1223A-6MA -J000`:

| Barcode | AIM batch label | Ours before | Ours after |
|---|---|---|---|
| PART NO. (P) | `P1223A6MA J000` | `1223A-6MA -J000` | `P1223A6MA J000` |
| D/C PART LEVEL (2P) | `2P00` | `00` | `2P00` |
| QUANTITY (Q) | `Q96` | `Q96` | `Q96` |
| SERIAL (1S) | `1S` + 16 digits | 16 digits | `1S` + 16 digits |

All four move from Code 39 to Code 128 and print about two-thirds of their current length. The
human-readable text, the 2D symbol, positions and heights are unchanged.

**Length is close to AIM's, not identical.** AIM's bars measure about 13 mil; a 203 dpi head can print
15 mil or 10 mil. This uses 15, so ours print roughly 11% longer than AIM's.

### SQL

| File | | Effect |
|---|---|---|
| `0106_container_label_code128_and_data_identifiers.sql` | migration | Rewrites four lines of the active Container `Lots.LabelTemplate` row. Guarded: throws if any line is not found verbatim. |
| `R__Lots_ufn_ShippingLabelZpl.sql` | CHANGED (v1.5) | Supplies `{PartNumberBarcode}` (part number without dashes). |

**State A only -- riding along if the repack release has not gone out:** `R__Workorder_Assembly_CompleteTray.sql`
(v1.5) and `R__Parts_Item_ListEligibleFinishedGoodsRanked.sql` (v1.1). The deploy script applies every
repeatable whose text differs on prod, so they cannot be left behind. Their runbook is
`notes/2026-10-06_prod-release-runbook-passthrough-repack.md`; **its sections 3 and 6 apply in full** if
they ship here.

### In the range but shipping nothing

`sql/tests/0025_PlantFloor_Label_Dispatch/030_ShippingLabel_Render.sql`, `docs/`, `notes/`.

---

## 2. What the database change is

| | State A (repack not yet on prod) | State B (repack already on prod) |
|---|---|---|
| Migrations | 1 -- `0106` | 1 -- `0106` |
| Repeatables | 3 changed | 1 changed |
| Rehearsal lock window (local) | 0.3 s | 0.2 s (Execute) |

One `UPDATE` of one `Lots.LabelTemplate` row and one `CREATE OR ALTER FUNCTION`. No table, column or index
changes.

---

## 3. Risk

**3.1 Does anything now refuse what it used to allow?** No.

**3.2 Is any of it shared code? YES.** `Lots.ufn_ShippingLabelZpl` renders **every** container shipping
label on every line, at container completion and on reprint. There is no per-line switch.

**3.3 What Honda's scanners read changes.** Three of four payloads gain a prefix and the part number loses
its dashes. That is the point of the release, and it matches the AIM label -- but if anything downstream
was reading OUR old payloads, it will now read something different.

**3.4 The dash rule rests on one part.** "Remove every dash, keep the space" reproduces AIM's
`P1223A6MA J000` exactly. No other part number has been compared.

**3.5 Mixed labels.** Labels already printed keep the old barcodes. A **reprint** after this release
renders the new form.

**3.6 Old Ignition against new SQL:** nothing in Ignition changes.

---

## 4. Deploy

Run from the repo root.

```powershell
$env:SQLCMDPASSWORD = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR((Read-Host 'Ignition SQL password' -AsSecureString)))
```

### Step 0 -- Is prod's template what 0106 expects? (read-only)

Run against `MPP_MES_Prod`:

```sql
DECLARE @Body NVARCHAR(MAX) = (SELECT TOP 1 t.ZplBody FROM Lots.LabelTemplate t
    JOIN Lots.LabelTypeCode c ON c.Id = t.LabelTypeCodeId
    WHERE c.Code = N'Container' AND t.DeprecatedAt IS NULL ORDER BY t.Id);
SELECT v.Field, CASE WHEN CHARINDEX(v.Line, @Body) > 0 THEN 'FOUND' ELSE '*** NOT FOUND ***' END AS Result
FROM (VALUES
 (N'1 part number',  N'^A0R^FO600,70^BY3^B3,,100,N,^FD{PartNumber}^FS'),
 (N'2 dc level',     N'^A0R^FO230,70^BY3^B3,,75,N,^FD{DcPartLevel}^FS'),
 (N'3 quantity',     N'^A0R^FO320,720^BY3^B3,,75,N,^FDQ{Quantity}^FS'),
 (N'4 serial',       N'^A0R^FO50,60^BY3^B3,,95,N,^FD{SerialBarcode}^FS')) v(Field, Line);
```

Expect four rows, all `FOUND`. Any `NOT FOUND` means prod's template has diverged; the migration would
throw and roll the release back. Stop and send me the `ZplBody`.

### Step 1 -- Preview (read-only)

```powershell
.\sql\scripts\Deploy-ProdRelease.ps1 -ServerInstance 172.17.10.148 -Username Ignition -DatabaseName MPP_MES_Prod
```

Expect (`[2]`, `[6]`, `[7]` show prod's own values):

```
[3] Versioned migrations
  Database: 104 applied, highest 0105.
  Pending (1):
    + 0106_container_label_code128_and_data_identifiers.sql

[4] Repeatables -- target definitions vs this checkout
  STATE A:  498 identical, 3 changed, 0 new on the target.
              CHANGED  R__Lots_ufn_ShippingLabelZpl.sql
              CHANGED  R__Parts_Item_ListEligibleFinishedGoodsRanked.sql
              CHANGED  R__Workorder_Assembly_CompleteTray.sql
  STATE B:  500 identical, 1 changed, 0 new on the target.
              CHANGED  R__Lots_ufn_ShippingLabelZpl.sql

[5] Pre-flight gates
  No gates fired.

[8] Plan
  1 migration(s), 3 repeatable(s)   (State A)   /   1 migration(s), 1 repeatable(s)   (State B)
  Plan fingerprint: <copy this>

Verdict
  Clear to deploy. 0 warning(s) to read above.
```

**Read `[2]` every time** -- it is the only line that names the database.

**If it differs:**

- *State A and you did not mean to ship the repack today* -- stop. There is no way to deploy the label
  change without it from this checkout. Decide, then continue or come back.
- *Any other CHANGED or NEW repeatable, or a second pending migration* -- prod is not where this runbook
  assumes. Stop; read the report's `diffs` folder.
- *A WARN in `[6]`* -- a long transaction is open. Wait for it.

Copy the fingerprint; do not retype it. The local sims printed `9cdec66593ca` (State A) and `0420d1aa7bcc`
(State B) at `44ea9f82`; yours will differ because the commit of this note moved `HEAD`.

### Step 2 -- Rehearse

```powershell
.\sql\scripts\Deploy-ProdRelease.ps1 -ServerInstance 172.17.10.148 -Username Ignition -DatabaseName MPP_MES_Prod -Mode Rehearse -ExpectedPlan <fingerprint>
```

Type `REHEARSE`. Expect (State A shown; State B has only steps `[1]` and `[2]`):

```
[10] Running the release transaction
    == transaction open
    == [1] migration 0106_container_label_code128_and_data_identifiers
    Migration 0106: Container label patched -- four barcodes now Code 128 with P / 2P / Q / 1S data identifiers.
    == [2] R__Lots_ufn_ShippingLabelZpl.sql
    == [3] R__Parts_Item_ListEligibleFinishedGoodsRanked.sql
    == [4] R__Workorder_Assembly_CompleteTray.sql
    == verifying inside the transaction
    == checks passed
    == ROLLED BACK (rehearsal / preview script) -- nothing was kept

  REHEARSAL PASSED and was rolled back. Lock window: 0.3s.
```

**If the rehearsal fails, stop.** Nothing was written. A `Migration 0106: ... not found verbatim` message
means Step 0 was skipped or prod's template changed since.

### Step 3 -- Execute

```powershell
.\sql\scripts\Deploy-ProdRelease.ps1 -ServerInstance 172.17.10.148 -Username Ignition -DatabaseName MPP_MES_Prod -Mode Execute -ExpectedPlan <fingerprint>
```

Type `MPP_MES_Prod`. Expect:

```
[9] Backup
  BACKUP DATABASE -> ...\MPP_MES_Prod_pre-release_0105_<stamp>.bak (COPY_ONLY, CHECKSUM)
  Backup written and verified.

[10] Running the release transaction
    == transaction open
    == [1] migration 0106_container_label_code128_and_data_identifiers
    == [2] R__Lots_ufn_ShippingLabelZpl.sql
    (State A: [3] and [4] as in the rehearsal)
    == verifying inside the transaction
    == checks passed
    == COMMITTED

[11] After commit
  R__Descriptions_ExtendedProperties.sql applied.
  Every repo migration is recorded.
  All 1 applied repeatable(s) now match the repo byte-for-byte.     (State A: All 3)

DONE
```

Ignore the closing "Import the Ignition exports NOW" line; there are none.

- *`ABORT: plan is <a> but -ExpectedPlan is <b>`* -- something moved since the preview. Re-preview.
- *`FAILED -- the transaction was rolled back`* -- prod is unchanged. Read `deploy.log`.

---

## 5. Ignition imports

None.

---

## 6. Verification

### 6.1 First -- the thing never seen: a printed label

Complete (or reprint) one container. On the printed label:

1. All four barcodes are present, unbroken, and shorter than before. Nothing overlaps the text.
2. Scan each one. Expect exactly, for `1223A-6MA -J000` at quantity 96 and level 00:
   `P1223A6MA J000` / `2P00` / `Q96` / `1S13218001` + the last 8 digits of the AIM serial.
3. Lay it beside an AIM batch label: the four barcodes should look alike, ours slightly longer.

**What each wrong result means:**

- *A barcode is missing or prints as a block / garbage* -- the printer rejected the Code 128 command. Go to
  section 7.
- *A barcode scans with the old payload* -- the label was rendered before the release (a re-send of stored
  ZPL). Complete a new container or use Reprint.
- *The part barcode has the wrong spacing for some other part* -- that is 3.4. Report the part number and
  what AIM's label scans as.
- *A barcode scans as `>...` or with odd characters* -- report the exact string.

### 6.2 SQL proof

```sql
SELECT CASE WHEN t.ZplBody LIKE N'%^B3%' THEN 1 ELSE 0 END AS HasCode39,
       (LEN(t.ZplBody) - LEN(REPLACE(t.ZplBody, N'^BCR', N''))) / 4 AS Code128Fields
FROM Lots.LabelTemplate t JOIN Lots.LabelTypeCode c ON c.Id = t.LabelTypeCodeId
WHERE c.Code = N'Container' AND t.DeprecatedAt IS NULL;
```

Expect `HasCode39 = 0`, `Code128Fields = 4`.

### 6.3 State A only

Run sections 6.1 to 6.3 of the pass-through repack runbook.

---

## 7. Rollback

**Before COMMIT:** automatic.

**After COMMIT:** there is no switch; the template row has to be put back by a forward migration that swaps
the four lines back to their `^B3` form (the function needs no change -- v1.5 renders the old template
correctly). That migration is **not written yet**. If 6.1 fails, stop completing containers on MPP labels,
tell me, and it ships through the same three steps. Labels already printed in the new form stay as printed.

A database restore is not the answer here: it would discard everything booked since the backup to undo one
row.

---

## 8. Outcome -- filled in after the release

Taken from the Execute report on this machine and from Jacques's scans of the first label printed.

| | |
|---|---|
| Executed at | 2026-10-06 16:17 ET, from `jacques/working @ d3735225` |
| Prod before | SQL `0105`, 104 migrations (`MESDBSRV`, 172.17.10.148) |
| State A or B | **B** -- the repack procs were already on prod |
| Step 0 result | not recorded |
| Plan fingerprint | `a1bd711591ee` |
| Backup path | `C:\Program Files\Microsoft SQL Server\MSSQL16.MSSQLSERVER\MSSQL\Backup\MPP_MES_Prod_pre-release_0105_20261006_161720.bak` |
| Preview `[4]` | 500 identical, 1 changed (`R__Lots_ufn_ShippingLabelZpl.sql`), 0 new; 0 warnings |
| Live activity `[6]` | 36 open baskets, 1 running shift |
| Prod rehearsal lock window | 0.4 s (Execute transaction: 0.3 s) |
| Report folder | `dist\deploy-reports\MPP_MES_Prod_Execute_20261006_161720` (preview `..._161630`, rehearse `..._161701`) |
| 6.1 four scans (exact strings) | `P1223A6MA J000`, `2P00`, `Q96`, `1S1321800113906405` -- all four scanned from a reprint made after the release (AIM serial `113906405`). |
| 6.1 side-by-side with AIM label | not recorded. All four barcodes printed whole, shorter than before, clear of the text. |

**What went differently from the plan:**

- Prod turned out to be in State B, which means the pass-through repack release had already been executed.
  Its own runbook's Outcome section is still blank.
