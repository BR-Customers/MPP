# Prod release runbook -- AIM post-back sends the serial printed on the label (0 + last 8 digits)

**Release commit:** `6023e7f9` on `jacques/working` -- the commit the archives were built and verified from.
**Previous release:** prod's Ignition is at `0647dc97` (executed 2026-10-07 08:39 ET), plus the die cast
shift-end bundle `846f636d` if that has been run -- its runbook's Outcome is blank, so this runbook does not
assume either way. It does not matter here: `BlueRidge/Lots/AimHttp` is byte-identical at `0647dc97` and
`846f636d` (`git diff --stat 0647dc97..846f636d` on it prints nothing), and no other resource ships.
**Rehearsed against:** nothing. **There is no SQL in this release**, so there is no preview, no rehearsal,
no Execute, no fingerprint and no backup. It is one Core script import.
**SQL suite:** not run -- no SQL changed.

> **Do not run `Deploy-ProdRelease.ps1` for this release.** This checkout also contains the die cast
> shift-end SQL. If that release has not been executed yet, a preview from here will list its three procs as
> pending. That is the other runbook's work (`notes/2026-10-08_prod-release-runbook-diecast-shift-end.md`),
> not this one's.

> **The two releases are independent and can go in either order.** They share no resource. The die cast
> Core archive carries `Workorder/DieCast` and the stylesheet, not `AimHttp`, so importing it after this
> one does not undo this one.
>
> **One side effect on the die cast runbook.** Its archive check,
> `git diff --stat 846f636d..HEAD -- ignition/ sql/migrations/`, now prints one line:
> `.../BlueRidge/Lots/AimHttp/code.py`. That line is this release. The die cast archives are still correct
> as long as it is the only line. The commits made for this release also moved `HEAD`, so **any die cast
> preview read before 13:20 on 2026-10-08 has a dead fingerprint** -- re-preview before its Execute.

> **Read this before deciding to ship.** What has and has not been proven:
>
> 1. **The new code has never run on a Gateway.** The transform and the query builder were lifted out of the
>    committed file and run in ordinary Python against the serials in AIM's email (`113906404` ->
>    `013906404`, `113803604` -> `013803604`, `000000024` unchanged, a non-numeric value unchanged). Jython
>    on the Gateway has not executed it. Section 6.1 is the first time it does.
> 2. **Our client has never posted a 0-form serial to AIM.** The evidence that AIM accepts it and echoes it
>    back is AIM's own log of the legacy MES doing exactly that on 2026-06-30 (`nextserial` returned
>    `113803604`; legacy posted `013803604`; AIM replied `013803604`), and AIM's email of 2026-10-08 saying
>    that is the required form. Section 6.2 is the first real post.
> 3. **The archives have not been imported anywhere.** Their three entries were compared byte for byte with
>    git (`code.py` and `resource.json` identical to `6023e7f9`; the rollback pair identical to `846f636d`).
> 4. **The shipping scan has not been tried on a box posted this way.** That scan (section 6.3) is the
>    actual proof; everything before it only shows we sent what AIM asked for.

---

## 1. What this ships

Boxes labelled by the MES have been failing the AIM shipping scan with "Serial Number ... Not On File"
since 2026-10-06 (`notes/2026-10-06_aim-serial-leading-1-shipping-scan.md`).

- AIM issues the MES a 9-digit serial that starts with `1` (`113906404`).
- The shipping label has room for 8 of those digits, so it prints `13218001` + `13906404`.
- The shipping tablet pads those 8 back to 9 with a zero and looks up `013906404`.
- The MES was posting the box to AIM as `113906404`. AIM accepted it and filed it under a number no box
  carries.

AIM confirmed on 2026-10-08 that the legacy MES gets the same `1...` serials from `nextserial` and posts
them as `0` + the last 8 digits. This release makes the MES do the same.

After the import:

- **Every post to AIM carries `0` + the last 8 digits of the pooled serial.** A post counts as successful
  only when AIM echoes that same value back.
- **The label does not change.** It already prints those 8 digits.
- **The pool does not change.** It still stores the serial exactly as AIM issued it (`1...`), and
  `nextserial` calls are untouched.
- **Operators see nothing different.** The difference shows at the shipping dock: the box scans.

### SQL

None.

### Ignition -- 1 resource, no deletions

| Archive | Resources |
|---|---|
| `Core_aim-post-serial_2026-10-08_1321.zip` | MOD `ignition/script-python/BlueRidge/Lots/AimHttp` |

`MPP` and `MPP_Config` have no changed resources and are not part of this release.

### In the range but shipping nothing

`notes/` (this runbook, the two AIM notes) and `PROJECT_STATUS.md`.

---

## 2. What the database change is

There is none. No migration, no repeatable, no data change.

---

## 3. Risk

### 3.1 Does anything now refuse what it used to allow? -- one thing, on the AIM side

The MES now treats a post as successful only if AIM replies with the **0-form** serial. If AIM were to
answer with anything else, the post is recorded as failed and retried every 60 seconds. Nothing on the
floor stops: the container still completes and the label still prints; the box shows on the **AIM Pool
Config** screen as owed, with AIM's reply as the error. AIM's June log shows it echoing the 0 form, so this
is not expected.

### 3.2 Is any of it shared code? -- yes, all AIM traffic

`BlueRidge.Lots.AimHttp` is the only module that calls AIM. Everything routes through it: the post when a
container completes, the post after a CRT validation, the 60-second retry sweep, and the pool top-up
(`nextserial`). Only `postSerial` changed, but the whole module is re-imported. Section 6.4 proves the pool
top-up, which was not changed, still works.

### 3.3 Is the schema change metadata-only? -- there is no schema change

### 3.4 Does the old Ignition keep working against the new SQL? -- not applicable, no SQL

### 3.5 Boxes that are owed to AIM at the moment of import

Any container whose post has not yet succeeded is retried by the sweep within a minute of the import, now
in the 0 form. That is the wanted outcome. Section 4 counts them first so the number is known.

### 3.6 What this release does not touch

- **Boxes already posted in the `1...` form.** The MES has them marked as posted and will not send them
  again. Their records in AIM stay as they are, matching no label. The boxes themselves were pulled and
  relabelled with AIM batch labels (Jacques, 2026-10-08). Whether AIM wants those records voided is a
  question for AIM; section 4 gives the count to send them.
- **Test company `01`.** Its serials already start with zeros, so the posted value is the same as before.

---

## 4. Before the import -- two read-only counts

SSMS, `172.17.10.148`, database `MPP_MES_Prod`. Neither query changes anything.

**4.1 How many boxes are owed to AIM right now** (these will be posted in the 0 form straight after the
import):

```sql
SELECT COUNT(*) AS OwedToAim,
       CAST(MIN(ConsumedAt) AT TIME ZONE 'UTC' AT TIME ZONE 'Eastern Standard Time' AS DATETIME2(0)) AS OldestET
FROM Lots.AimShipperIdPool
WHERE ConsumedAt IS NOT NULL AND PostedAt IS NULL;
```

Write the number in section 8. Zero is normal when AIM has been reachable. A large number means AIM has
been refusing or unreachable for a while -- read `LastPostError` on those rows before importing, because
the import will not fix a different fault.

**4.2 How many boxes were posted in the `1...` form** (for the record, and for AIM):

```sql
SELECT COUNT(*) AS PostedWithLeading1,
       MIN(AimShipperId) AS FirstSerial, MAX(AimShipperId) AS LastSerial
FROM Lots.AimShipperIdPool
WHERE PostedAt IS NOT NULL AND AimShipperId LIKE N'1%';
```

---

## 5. Ignition import

Designer -> File -> Import, accepting overwrite for the one listed resource. Do **not** use the Gateway web
page's project import.

1. **`Core_aim-post-serial_2026-10-08_1321.zip`** -- 1 resource, 3 entries, in `dist\ignition-exports\`:
   `MOD ignition/script-python/BlueRidge/Lots/AimHttp`
2. `MPP` -- nothing.
3. `MPP_Config` -- nothing.

The checklist is `aim-post-serial_2026-10-08_1321_CONTENTS.txt`. No deletions. No hand steps.

Sessions do not need reloading: no view, stylesheet or session property changed. The Gateway timers pick
the new script up when the project saves.

Note the time of the import; sections 6.2 and 6.4 look for rows newer than it.

---

## 6. Verification

### 6.1 First -- the import landed, and the code runs on the Gateway (sends nothing)

Designer Script Console:

```python
print BlueRidge.Lots.AimHttp._wireSerial("113906404")
print BlueRidge.Lots.AimHttp._buildPostQuery(BlueRidge.Lots.AimHttp._wireSerial("113906404"), "1223A6MA J000", 96, "MESL3002604")
```

Expect exactly:

```
013906404
%5Cr%5Cn013906404%5Ct1223A6MA%20J000%5Ct96%5CtMESL3002604%5Cr%5Cn
```

Neither line makes a network call.

- *`AttributeError: ... has no attribute '_wireSerial'`* -- the import did not land. Re-import the Core zip.
- *The first line prints `113906404`* -- the old module is still loaded. Save the project in the Designer
  and run it again.

**Do not call `postSerial` or `nextSerial` from the console on prod.** `nextSerial` burns a real serial and
`postSerial` creates a real label record.

### 6.2 The first real post

After the next container completes at any Assembly OUT (or straight away, if section 4.1 counted owed
boxes):

```sql
SELECT TOP 10
       CAST(LoggedAt AT TIME ZONE 'UTC' AT TIME ZONE 'Eastern Standard Time' AS DATETIME2(0)) AS LoggedET,
       Description, RequestPayload, ResponsePayload, ErrorDescription
FROM Audit.InterfaceLog
WHERE SystemName = N'AIM' AND Description = N'AIM postserial'
ORDER BY Id DESC;
```

Expect, on every row newer than the import: the serial straight after `postserial.csv?%5Cr%5Cn` **starts
with `0`**, `ResponsePayload` is `OK`, `ErrorDescription` is NULL.

- *The serial still starts with `1`* -- the old script is running. Go back to 6.1.
- *`ErrorDescription` reads `AIM rejected: POST /mes/floor/...`* -- AIM did not accept the post and echoed
  the request back. Copy the row and send it to AIM. The box stays owed and is retried; nothing is lost.
  If every post is rejected, roll back (section 7) -- the old form was at least being accepted.
- *`ErrorDescription` reads `AIM rejected: 1...`* -- AIM accepted the post but echoed a different serial
  than the one sent. Not expected. Send AIM the row; do not roll back on this alone.
- *`HTTP 403: Not logged in - AIM Mobility must be restarted.`* or a timeout -- AIM's service, not this
  release.

### 6.3 The proof -- scan the box

Take a box from 6.2 to the AIM shipping tablet and scan its label onto a shipper. Expect it to be found.
`Serial Number: S0... Not On File` means AIM does not have the record under the number the tablet reads;
send AIM the 6.2 row for that box.

A second look that needs no box: in AIM Vision, **Shipping -> Bar Code Reports -> Unshipped Labels ->
Unshipped Labels by Destination / Customer Part** should list the serial as `S0` + the 8 digits on the
label.

### 6.4 Shared code -- the pool still fills

The top-up only calls AIM when the pool drops below its threshold (30 on prod), so this may take a few
containers.

```sql
SELECT TOP 5
       CAST(LoggedAt AT TIME ZONE 'UTC' AT TIME ZONE 'Eastern Standard Time' AS DATETIME2(0)) AS LoggedET,
       Description, ResponsePayload, ErrorDescription
FROM Audit.InterfaceLog
WHERE SystemName = N'AIM' AND Description = N'AIM nextserial'
ORDER BY Id DESC;
```

Expect rows newer than the import with `ResponsePayload` = `OK`, once the pool has dipped. The **AIM Pool
Config** screen should show the depth holding between 30 and 50.

### 6.5 The pool is unchanged

```sql
SELECT TOP 5 AimShipperId, ConsumedByContainerId, PostAttempts, LastPostError,
       CAST(PostedAt AT TIME ZONE 'UTC' AT TIME ZONE 'Eastern Standard Time' AS DATETIME2(0)) AS PostedET
FROM Lots.AimShipperIdPool
WHERE PostedAt IS NOT NULL
ORDER BY PostedAt DESC;
```

Expect `AimShipperId` still starting with `1` (as AIM issued it), `PostedET` after the import,
`LastPostError` NULL.

---

## 7. Rollback

Import the previous version (built and verified against `846f636d`, never imported in anger):

1. `Core_aim-post-serial-ROLLBACK_2026-10-08_1321.zip` -- `MOD ignition/script-python/BlueRidge/Lots/AimHttp`
2. Confirm in the Script Console: `print hasattr(BlueRidge.Lots.AimHttp, "_wireSerial")` prints `False`.

After a rollback the MES posts the `1...` form again, which AIM accepts and the shipping tablet cannot
find. Boxes posted in the 0 form while the release was in stay posted and are not sent again.

There is no SQL to roll back.

---

## 8. Outcome

_(still to fill in)_

| | |
|---|---|
| Imported at (ET) | |
| Die cast shift-end release already in? | |
| 4.1 boxes owed to AIM before the import | |
| 4.2 boxes posted with a leading 1 (count, first, last) | |
| 6.1 console output as expected | |
| 6.2 first post (serial, reply) | |
| 6.3 box scanned at the tablet | |
| 6.4 nextserial still OK | |
| 6.5 pool row unchanged | |
| Anything that went sideways | |
