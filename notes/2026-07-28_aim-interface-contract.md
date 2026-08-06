# AIM Interface Contract — discovered, reconciled, and a server-side test plan

**Date:** 2026-07-28
**Source of truth:** `AIM_docs/customer_AIM_http` (MPP ↔ AIM Computer Solutions scope agreement)
**Supporting:** `AIM_docs/customer_docs/` (AIM Vision help system, ©2023, ~1,700 topics)
**Supersedes:** the "⛔ BLOCKED pending customer input" framing in the PROJECT_STATUS 2026-07-16 AIM section — 3 of its 5 blockers are answered below.

---

## 1. The contract

AIM modifies the **AIM Mobility Web service (`MobileMain`)** to accept HTTP POSTs that create
shipping labels. The service listens on **port 8080**. Two endpoints, both under one URL shape:

```
http://{servername}:8080/mes/floor/{CompanyCode}/636652666553236784/{request}
```

| Token | Meaning |
|---|---|
| `{servername}` | AIM server name or IP |
| `{CompanyCode}` | AIM company code. Doc says `99` is "usually used for test"; **MPP's test company is `01`** |
| `636652666553236784` | Fixed path token, appears to be a shared secret. Doc gives no rotation/derivation rule |
| `{request}` | `nextserial.csv` or `postserial.csv` |

### 1.1 `nextserial.csv` — get a serial

Request body per the doc's sample is `{cr}{lf}{cr}{lf}` with `Content-Type:
application/x-www-form-urlencoded` and `Content-Length: 4` (4 bytes = the two CRLFs — consistent,
so the empty-ish body appears deliberate rather than a typo).

Reply is `text/csv`, `Server: acsMobile-HTTPAPI/2.0`, body = the serial + CRLF:

```
000002234
```

**Nine digits, unique per company code.** ✅ **VERIFIED against MPP's AIM server 2026-07-28** — see
§5.6. The serial is **zero-padded left to 9 characters** and the reply carries **no leading
whitespace** (the indentation in the agreement's sample is document formatting only); `Content-Length`
is 11 = 9 digits + CRLF.

### 1.2 `postserial.csv` — bind content to the serial

Body is tab-delimited, one line:

```
{serial}<TAB>{CustomerPartNumber}<TAB>{Quantity}<TAB>{LotNumber}
```

Reply echoes the serial. AIM uses this to locate an active blanket in the AIM Vision Orders system
and build the label content.

**The doc's byte framing is ambiguous here.** Its sample shows a CRLF before *and* after the payload
line while still claiming `Content-Length: 4` (copy-paste error from the previous sample). Resolve
empirically — see §5.

### 1.3 Stated responsibilities and exclusions

- **"The label will not be printed from AIM but instead printed by the MPP MES system as it does
  today."** Our ZPL render + dispatch path is correct by design.
- Failures write `AIMVision\Lineside\Exceptions\<labelnumber>.txt` and a message to the
  **`acsMobileLog` Event Log**. Nothing in the MES reads either today.
- Out of scope: lot control; labels needing extra input (RAN / Kanban / Manifest numbers); label
  types not flagged **"Quick Label Allowed"** on the Bar Code Format Type record.
- **Label content must be identical for a given customer part number.** AIM resolves label format
  from **Blanket Release Order Detail by Item Number + Destination** (see
  `AIM_docs/customer_docs/quick_label_create_and_print.htm`). A part shipping to multiple Honda
  destinations with destination-specific content is explicitly excluded.
  → **Open question for MPP:** does any MPP part ship to more than one Honda destination?

---

## 2. Reconciliation with FRS Appendix L

| Appendix L method | HTTP equivalent | Status |
|---|---|---|
| `GetNextNumber(context)` | `nextserial.csv` | ✅ mapped |
| `UpdateAim(context, partName, quantity, lotName, serial, previousSerial=null)` | `postserial.csv` | ⚠️ mapped **except `previousSerial`** — no HTTP equivalent exists |
| `PlaceOnHold(context, serial)` | — | ❌ not in the agreement |
| `ReleaseFromHold(context, serial)` | — | ❌ not in the agreement |

### Legacy lineage (Appendix J, Base2)

The legacy MES **self-assigned** serials — `GetNextNumber` incremented a local `numberstorage`
counter (`WHERE snumberkey = 'LastSerial'`) and formatted 8 digits — then appended a flat CSV row:

```
1S13218001{serial}, {partName with dashes stripped}, {quantity}, {lotName}
```

Those are the **same four fields** as `postserial.csv`. The new contract is that flat-file drop
modernized to HTTP, with numbering authority moved from MPP-local to AIM and widened 8 → 9 digits.

Two formatting details carried by the legacy code but **unstated in the new agreement**:
1. **Dash-stripping** on the part number (`partName.Replace("-", "")`).
2. The `1S` + supplier code `13218001` prefix on the serial.

Whether `postserial.csv` expects raw or legacy-formatted values is a §5 test item.

### ⚠️ The payload field is the CUSTOMER part number, not AIM's item number

`postserial.csv` field 2 is `{Customer Part Number}` — the number **Honda** assigns. AIM stores that
separately from its internal Item Number and bridges them via the **Customer Part / Item Number
Cross-Reference Table** (`AIM_docs/customer_docs/customer_part_o_item_number_cross_reference_table.htm`).
Legacy Base2 also normalized it (`partName.Replace("-", "")`) before writing its CSV row.

**Open question for our schema:** is `Parts.Item.PartNumber` the Honda customer part number or MPP's
internal number? If internal, the MES cannot post back without the customer-part value or a mapping
column. Verify against a real part on AIM's Item Master + cross-reference screens.

#### ✅ RESOLVED 2026-07-31 — the AIM part-number format rule

A Quick Label screen in company 01 showed a real AIM item number: **`11300R70 A000`**
(desc "R70 CASE OIL SEAL ASSY", Destination `GNSE 25` / Honda, Standard Pack 15).

**Format: 5 chars + 4-char space-padded middle + 4-char suffix = 13 characters. No dashes.**

| Form | Value |
|---|---|
| Legacy MES material name | `11200-6FB -A000` |
| Dashes stripped, space preserved | `112006FB A000` |
| AIM convention (observed) | `11300R70 A000` — identical shape |

Legacy Base2's `partName.Replace("-", "")` was performing exactly this conversion. **The residual
space is part of the key, not a data-quality defect** — which also explains the legacy export's
`HasTrailingSpace` column and its 140 space-bearing part numbers (the middle segment padded to 4:
`6FB `, `R70 `, `5J6 `, `59B `).

**Both earlier POST attempts were malformed keys:** `11200-6FB-A00` (dashes + 3-char suffix) and
`112006FBA00` (space dropped + 3-char suffix). Correct would be `112006FB A000`. That, not blanket
config, is the probable cause of every "Blanket not found for customer part" so far.

**MES implication:** `Parts.Item.PartNumber` → AIM needs a deterministic transform (strip dashes,
preserve internal spacing, 4-char suffix). Confirm whether our stored value is the legacy dashed
form or the AIM form before implementing — and note the legacy export is itself inconsistent
(`11200-P8A-A00` carries no padding), so a blind rule will not cover every part.

#### ✅ IMPLEMENTED 2026-08-04 — dash-stripping supersedes "not derivable, must be stored" for OUR part numbers

The design that followed this note (`docs/superpowers/specs/2026-07-31-aim-integration-ignition-design.md`
§4.1, migration `0052`) concluded the AIM customer part **"is not derivable from `Item.PartNumber`"**
and stored it in a new `Parts.Item.AimCustomerPartNumber` column that a human had to fill in per
item. **That conclusion is now superseded for MPP's own part numbers.** This week's live testing
against MPP's AIM server (table below, first captured at the top of migration `0054`'s header)
confirmed the transform is exactly "strip dashes, preserve embedded spaces" applied to
`Parts.Item.PartNumber`:

| Value sent to AIM | Result |
|---|---|
| `11200-6FB-A00` | Blanket not found |
| `112006FBA00` | Blanket not found |
| `112006FB A000` | posted, label created |

The legacy MES material name for that part is `11200-6FB -A000`. Strip the dashes — and *only* the
dashes, do not trim or collapse whitespace — and the result is `112006FB A000` exactly: the value
that worked. This is precisely the legacy Base2 `partName.Replace("-", "")` step from §2's "Legacy
lineage" discussion above, applied at the correct point (the customer part, not the item number).

**Consequence:** `Parts.Item.AimCustomerPartNumber` and its two accessor procs are removed
(migration `0054_drop_item_aim_customer_part.sql`); `Parts.ufn_AimCustomerPartNumber(@PartNumber)`
derives the value on every read instead. There is no longer a per-item value for MPP to maintain,
no config-gap state, and nothing for the Item Master AIM field to edit — that field is deleted.

**Caveat — this does not resolve every part.** The AIM Customer Part / Item Number Cross-Reference
this note captured above shows one row dash-stripping cannot produce: `11300R70 A000` →
`11300R7- A000` — a **dash appears** in the AIM-side value exactly where the item number has a `0`.
No transform of `PartNumber` alone reproduces that. An irregular part shaped like that one may still
post the wrong customer part and need a manual look; this is a narrower, lower-probability version
of the original "not derivable" problem, not a fully closed question. If a part is ever observed
failing `postserial.csv` despite a clean dash-strip, check it against this pattern first.

#### 🔴 Part numbers do NOT match across systems (found 2026-07-30, superseded by the above)

Same physical part, two systems, two different strings:

| System | Value |
|---|---|
| AIM Item Master | `11200-6FB-A00` |
| Legacy MES material name (`sql/Legacy content/Legacy Part Export.xlsx`) | `11200-6FB -A000` |

Differences: an **embedded space** after the middle segment, and a **4-character suffix vs 3**.

This is systemic, not a one-off. The legacy export carries a dedicated **`HasTrailingSpace`** column,
and **140** of its part numbers contain embedded spaces (`12231-59B -0001`, `12270-6NA -0001`,
`11200-5J6 -A110`, …). The middle segment appears space-padded to 4 characters — but
*inconsistently*: `11200-P8A-A00` in the same export has no padding.

Consequences:

1. **Legacy → MES data migration** cannot assume part-number identity. Normalization rules must be
   agreed with MPP (is the space padding significant, or a fixed-width artifact?).
2. **MES → AIM** must send the value **exactly as AIM stores it**, which may be neither the legacy
   string nor our `Parts.Item.PartNumber`.
3. Combined with legacy Base2's `partName.Replace("-", "")`, there are at least three candidate
   on-the-wire forms for one part: `11200-6FB-A00`, `11200-6FB -A000`, `112006FBA00`.

Raise with MPP independently of the AIM interface work — it affects any legacy data migration
(a CONDITIONAL scope item), not just shipping labels.

### AIM-side prerequisites for a part to be postable

Per `orders_overview.htm`, shipping/bar-code defaults (standard pack, container ID, **bar code
format**, destination) live at the **order entry** level, not on the item. A part is only usable by
`postserial.csv` once all of these exist:

1. **Item Master** record (Inventory)
2. **Customer Part / Item Number cross-reference**
3. **Control Source** + **Destination** codes in their master tables
4. **Blanket order** with release detail (standard pack, bar code format, destination)
5. **Bar Code Format Type** flagged **Quick Labels Allowed**

This spans Inventory, Orders, and Bar Code. It is an ask for MPP's AIM administrator / AIM support,
not something to improvise — a missing Control Source three tables away surfaces as an opaque
`postserial.csv` failure.

### Navigating AIM Vision (Rev 11C)

Log in with User Name, Password, and **Company** (`01` for test) — company is chosen at the login
screen. The **hamburger icon** opens the application menus: **Inventory** → Item Master;
**Orders** → blanket / release / cross-reference; **Shipping** → Ship Order, Shipping and Bar Code
Labeling (Quick Label Create and Print lives here).

**Check for existing data before creating any:** the serial counter at `000000001` proves only that
no serials have been issued — company `01` may still carry master data. Run **Orders → Blanket Edit
List** or **Blanket Detail Summary by Customer Part Report** first.

---

## 3. Findings that change the build

### 3.1 The pool cannot be per-part — `AimShipperIdPool.PartNumber` is wrong

`nextserial.csv` **takes no part parameter**. Serials are unique *per company code*; part number
only enters at `postserial.csv`, when the serial is bound to content.

But as built (`sql/migrations/versioned/0028_arc2_phase6_assembly.sql:147`):

- `Lots.AimShipperIdPool.PartNumber NVARCHAR(50) NOT NULL`
- `AimShipperIdPool_Claim @PartNumber` filters by part and hard-fails per part
- filtered index `IX_AimShipperIdPool_AvailableByPart (PartNumber, FetchedAt)`
- FDS-07-010's topup loop is specced as "per part below `TopupThreshold`"

**The specced topup is not implementable against this contract** — there is no way to fetch a
part-specific ID. The pool must collapse to a **single generic pool per company code**.

Already verified (PROJECT_STATUS 2026-07-16) that nothing downstream depends on the per-part
binding: the container's part comes from `Container.ItemId`, `ShippingLabel` stores no part, and
the label / trace / post-back payloads all re-derive it. Generic also gives strictly better outage
tolerance. This moves from "clean change if MPP decides" to **a correction the contract requires**.

Blast radius: `0028` DDL (or a new migration), `_Claim` / `_Topup` / `_GetDepth`, the inlined claim
in `Container_Complete`, `AimPoolGateway.alarmTick` (currently loops per part), `AimPoolTile`,
seed `028`, tests `0028/035` + `0029/040`.

### 3.2 `UpdateAim` is not Sort-Cage-only — every container must post back

FDS-07-012 frames `UpdateAim` as a re-sort concern. Per the agreement, `postserial.csv` is **the**
mechanism that creates the shipping label in AIM. As built, the MES claims a pool ID at
`Container_Complete` and never posts back — **AIM would never learn what any container contains.**

`Lots.Container_GetLabelData` (currently uncommitted) already returns `PartNumber`, `Quantity`,
`MfgLotNumber`, `Serial` — the `postserial.csv` payload field-for-field. That proc is the natural
data source for the AIM call, not just for the ZPL render.

### 3.3 Holds have no transport

The agreement covers label creation only. Yet:

- **FDS-07-011** requires `PlaceOnHold` / `ReleaseFromHold` calls.
- **FRS §2.1.10** describes MES identifying a bad lot to AIM, *AIM returning a HOLD number*, and
  MES printing it as a Hold Ticket — which invalidates the original container label in AIM.
- **Appendix L's own aside:** *"QA Staff uses a tablet to go to the hold screen to put on and take
  off hold - a big deal."*

That aside reads like holds are performed **by humans in AIM's UI**, not via an MES API call. If so,
FDS-07-011 is specced against an interface that was never scoped, and the Sort Cage flow (FRS
§2.1.10 / §2.2.7, UJ-05) needs rework. **This is now the largest open AIM question.**

### 3.4 Exception surface is unmonitored

`AIMVision\Lineside\Exceptions\*.txt` + the `acsMobileLog` Event Log are where AIM reports failures.
A `postserial.csv` that returns 200 but fails downstream would be invisible to the MES today.
Decide: poll the Exceptions folder, or treat the echoed-serial reply as sufficient acknowledgement.

---

## 4. Still genuinely open

1. **Hold transport** (§3.3) — API or manual? Blocks FDS-07-011 + Sort Cage.
2. **`previousSerial`** — no HTTP equivalent; blocks FDS-07-012 re-pack traceability.
3. **OI-33 empty-pool policy** — hard-fail vs soft-fallback. Unchanged business decision.
4. **Honda label blank fields** — Part No. Ext (C), D/C Part Level (2P), Auditor, 2D DataMatrix.
   Confirmed **not** AIM-sourced; needs part-master data + the Honda container-label content spec.
5. **Multi-destination parts** — see §1.3.
6. **Part-number and serial formatting** — dash-stripping, `1S`/supplier prefix (§2).
7. **Path token `636652666553236784`** — fixed forever, or rotated per environment?

### Hypothesis worth one question, not an assumption

`Lots.ufn_IsValidExternalLtt` gates die-cast LTTs at **exactly 9 numeric digits**, "bulk pre-printed
by an external scheduler," with an **unconfirmed checksum** (2026-07-20 spec open item). AIM serials
are also 9 digits. If that external scheduler is AIM, the open LTT checksum question may be
answerable by the same vendor. Worth asking MPP — not worth assuming.

---

## 5. Server-side test plan

**Run from an RDP session on the AIM server itself** (the service binds port 8080 there; the MES dev
box has no route). PowerShell 5.1 assumed.

> ### ⚠️ These calls mutate AIM state
> `nextserial.csv` **consumes a serial** from the company's sequence — every call burns one, and
> there is no documented way to return it. `postserial.csv` **creates a shipping label record**.
> Use **company `01`** (test) for everything below. Do not point these at the live company code
> without MPP IT sign-off.

### Step 0 — confirm the service is up

```powershell
Get-Service | Where-Object { $_.Name -match 'acs|aim|mobile' } | Format-Table Name,Status,DisplayName
Test-NetConnection -ComputerName localhost -Port 8080
netstat -ano | Select-String ':8080'
```

`aim_services.htm` lists a **`MOBILE1`** ProControl service — that is the `MobileMain` process the
agreement modifies. If 8080 is closed, the change may not be deployed on this box yet.

### Step 1 — parameters

```powershell
$server  = 'localhost'          # or the AIM server name/IP if not running locally
$company = '01'                 # MPP test company
$token   = '636652666553236784'
$base    = "http://${server}:8080/mes/floor/$company/$token"
$log     = "$env:USERPROFILE\Desktop\aim_test_$(Get-Date -Format yyyyMMdd_HHmmss).txt"
```

### Step 2 — `nextserial.csv`

Body is the doc's 4-byte `CRLF CRLF`.

```powershell
$body = [Text.Encoding]::ASCII.GetBytes("`r`n`r`n")
$r = Invoke-WebRequest -Uri "$base/nextserial.csv" -Method POST `
        -ContentType 'application/x-www-form-urlencoded' -Body $body -UseBasicParsing
"STATUS : $($r.StatusCode)"                    | Tee-Object -FilePath $log -Append
"HEADERS: $($r.Headers | Out-String)"          | Tee-Object -FilePath $log -Append
"RAW    : [$($r.Content)]"                     | Tee-Object -FilePath $log -Append
$serial = $r.Content.Trim()
"SERIAL : [$serial] len=$($serial.Length)"     | Tee-Object -FilePath $log -Append
```

**Expect:** `200`, `Content-Type: text/csv`, `Server: acsMobile-HTTPAPI/2.0`, 9 digits after trim.
Record whether leading whitespace is really present and whether digits are zero-padded.

### Step 3 — `postserial.csv`

Use a **real part number from test company 01** with an active blanket, or AIM cannot resolve a
label format. Start with the part exactly as AIM stores it (dashes intact).

```powershell
$part = 'REPLACE-WITH-REAL-PART'
$qty  = '50'
$lot  = 'TESTLOT001'
$payload = "$serial`t$part`t$qty`t$lot`r`n"
"SEND   : [$($payload -replace "`t",'<TAB>' -replace "`r`n",'<CRLF>')]" | Tee-Object -FilePath $log -Append
$body = [Text.Encoding]::ASCII.GetBytes($payload)
$r2 = Invoke-WebRequest -Uri "$base/postserial.csv" -Method POST `
        -ContentType 'application/x-www-form-urlencoded' -Body $body -UseBasicParsing
"STATUS : $($r2.StatusCode)"     | Tee-Object -FilePath $log -Append
"REPLY  : [$($r2.Content)]"      | Tee-Object -FilePath $log -Append
```

**Framing variants** if it rejects — try in order, one serial each, logging every attempt:

| # | Body |
|---|---|
| A | `payload + CRLF` (above) |
| B | `CRLF + payload + CRLF` (literal reading of the doc's sample) |
| C | `payload` with no trailing CRLF |
| D | A, but part number with dashes stripped (legacy Base2 behavior) |
| E | A, but serial prefixed `1S13218001` (legacy Base2 behavior) |

### Step 4 — verify AIM actually built the label

1. `dir "C:\AIMVision\Lineside\Exceptions\*.txt"` — sorted newest first. A file named for the
   serial means it failed; **read it, that is the real error message.**
2. Event Viewer → the `acsMobileLog` log.
3. In AIM Vision: look the serial up in the **Barcode Serial Label** table (Bar Code menu →
   Serial Label Entry) and confirm part / qty / lot / destination came through.

### Step 5 — precise-byte fallback

If `Invoke-WebRequest` fights you on `Content-Length` or chunking, drive the socket directly so the
bytes on the wire are exactly the doc's sample:

```powershell
function Send-AimRaw {
    param([string]$Server, [int]$Port = 8080, [string]$Path, [string]$Payload)
    $client = New-Object System.Net.Sockets.TcpClient($Server, $Port)
    $stream = $client.GetStream()
    $bodyBytes = [Text.Encoding]::ASCII.GetBytes($Payload)
    $req = "POST $Path HTTP/1.1`r`n" +
           "Host: ${Server}:$Port`r`n" +
           "User-Agent: MPP-MES-Test/1.0`r`n" +
           "Connection: close`r`n" +
           "Content-Type: application/x-www-form-urlencoded`r`n" +
           "Content-Length: $($bodyBytes.Length)`r`n`r`n"
    # Two writes -- do NOT concatenate the byte arrays with '+' (PowerShell would
    # produce an Object[], which NetworkStream.Write rejects).
    $headBytes = [Text.Encoding]::ASCII.GetBytes($req)
    $stream.Write($headBytes, 0, $headBytes.Length)
    if ($bodyBytes.Length -gt 0) { $stream.Write($bodyBytes, 0, $bodyBytes.Length) }
    $stream.Flush()
    $reader = New-Object System.IO.StreamReader($stream)
    $resp = $reader.ReadToEnd()
    $reader.Close(); $client.Close()
    return $resp
}

# nextserial, byte-exact
Send-AimRaw -Server 'localhost' -Path "/mes/floor/01/636652666553236784/nextserial.csv" -Payload "`r`n`r`n"
```

This returns the full raw response including status line and headers — the most useful thing to
paste back for diagnosis.

### 5.6 Results — 2026-07-28, MPP AIM server, company `01`

**`nextserial.csv` — ✅ PASS.** First live call against the real service.

```
STATUS : 200
HEADERS: Connection: close | Content-Length: 11 | Content-Type: text/csv
         Date: 7/28/2026 1:10:37 PM | Server: acsMobile-HTTPAPI/2.0
RAW    : [000000001\n]
SERIAL : [000000001] len=9
```

Confirmed:

| Fact | Consequence |
|---|---|
| Service live on 8080; path token + company `01` accepted | AIM has deployed the agreed modification; no further AIM-side work needed for serial issue |
| 9 digits, **zero-padded left** | `AimShipperIdPool.AimShipperId` **must stay `NVARCHAR`** — never an integer type, leading zeros are significant |
| **No** leading whitespace; `Content-Length` 11 = 9 + CRLF | A plain `.Trim()` (or strip trailing CRLF) is a sufficient parse |
| 4-byte `CRLF CRLF` request body accepted | The doc's odd `Content-Length: 4` is literal, not a typo |
| Serial returned is `000000001` | Company `01`'s counter is **at its start** — a fresh test company. Expect **no parts / blankets / Quick-Label-Allowed format types configured**, which `postserial.csv` requires |

**Cutover implication:** the *production* company code has its own independently-advanced counter.
Confirm the production company code and its current serial position with MPP/AIM before go-live —
and note the legacy MPP-local `numberstorage` counter (Appendix J, 8-digit) is a **separate**
sequence that does not migrate.

### 2026-07-31 — direct testing from the dev box; transport understood, label creation NOT yet confirmed

**Reachability:** the AIM server (`172.17.10.86:8080`) is routable from the dev box over VPN — no RDP
needed for the HTTP work. ICMP is filtered, so use `Test-NetConnection -Port 8080`, not ping.
No SMB (`C$`) or WinRM access, so the Exceptions folder can only be read on the server itself.

⚠️ **An earlier revision of this note claimed `postserial.csv` was working end-to-end. That was
recorded on a tentative report and is RETRACTED — label creation is still unconfirmed.** Serials
`000000016`–`000000021` were sent (see the correlation table below); the part-number conclusion drawn
from them does not hold.

**Unresolved:** which customer-part rendering (if any) AIM's blanket lookup accepts. The
`112006FB A000` form is derived from the legacy export and the X-Ref screen but is **not** verified.

| Representation | Value | Status |
|---|---|---|
| Legacy MES material name | `11200-6FB -A000` | — |
| AIM **Item Number** (X-Ref right column) | `112006FBAA000` | ✗ |
| AIM **Customer Part** (X-Ref left column) | `112006FB A000` | unverified |
| Earlier attempts | `11200-6FB-A00`, `112006FBA00` | ✗ |

### 🎯 2026-07-31 — THE ACTUAL `postserial.csv` FORMAT (from `acsMobileLog`)

**The written agreement is wrong about how the payload is transmitted.** The production client sends
the data in the **query string** with an **empty body**, and uses **literal backslash escape
sequences** — not control characters.

Captured from `acsMobileLog` (a production call, company 99):

```
POST /127.0.0.1/floor/99/636652666553236784/postserial.csv?%5Cr%5Cn013843444%5Ct12230P8A%20A000%5Ct30%5Ct013843444%5Cr%5Cn HTTP/1.1
Content-Type: application/x-www-form-urlencoded
Host: 172.17.10.86:8080
Content-Length: 0
```

Decoding: `%5C` is a **backslash**, so `%5Cr%5Cn` is the two-character text `\r\n` and `%5Ct` is the
text `\t`. The space in the part number is `%20`.

**Correct request shape:**

```
POST /mes/floor/{CompanyCode}/636652666553236784/postserial.csv?\r\n{serial}\t{part}\t{qty}\t{lot}\r\n
Content-Type: application/x-www-form-urlencoded
Content-Length: 0                      <- EMPTY BODY
```

…with the whole query URL-encoded (`\`→`%5C`, space→`%20`).

**Success signature:** the reply is the documented `{serialnumber}{cr}{lf}` — **11 bytes**. A
**91–93 byte echo of the request** is the listener's *unrecognized-request fallback* and means the
call was NOT routed.

#### Behavioural tests against company `01` (2026-07-31)

**Duplicate serial → REJECTED, no duplicate label.** Posted serial `000000025` twice, second time
with a different quantity (15 then 25):

| Attempt | Reply |
|---|---|
| #1 qty 15 | `000000025` — success |
| #2 qty 25 | `POST /mes/floor/01/…?\r\n000000025\t…` — echo = rejected |

First write wins; the second is refused and does **not** overwrite. **Retry is therefore safe** — a
re-post can never create a duplicate label.

⚠️ **A rejected duplicate writes NO exception file.** So the Exceptions folder is **not** a complete
failure oracle — absence of a file does not imply success, and only some failure classes
(blanket-not-found, etc.) produce one. Any future design that treats "no exception file" as
confirmation must first establish *which* failures are logged there.

> **Open item — needs MPP:** reading `…\Lineside\Exceptions\` remotely would give a second
> verification channel alongside the HTTP reply. `C$` and WinRM are both blocked from the dev box
> (tested 2026-07-31), so this needs MPP IT to grant a share or place an agent on the AIM box.
> **Raise with MPP before designing anything that depends on it.**

**Known gap this leaves:** if AIM accepts a post but the reply is lost (dropped connection, timeout
after processing, gateway restart mid-call), a retry gets the echo and reads as failure — forever.
Safe, but not self-healing. Mitigation is a human-confirmed `MarkPosted` action, since AIM exposes no
query endpoint.

**Out-of-order posting → FULLY SUPPORTED.** Pulled `000000026`/`027`/`028`, posted them in reverse
(`028` qty 5, `027` qty 10, `026` qty 20). All three succeeded. **Serials are independent — no
sequencing constraint**, so a retry queue may post in any order and a stuck row never head-of-line
blocks the rest.

**Quantity is unconstrained** — accepted 15 and 25 for a part whose standard pack is 15, matching
production traffic that ranges 5–96.

#### ✅ VERIFIED END-TO-END 2026-07-31 (positive confirmation, not absence-of-error)

`Shipping → Bar Code Reports → Unshipped Labels → Unshipped Labels by Destination / Customer Part`
(company 01, Print = All) returned the label AIM built from our API call:

```
Destination      Customer Part     Serial       Qty  Item Description  Lot Number   Date Entered
GNSE 25 - Honda  112006FB A000     S000000024   15   PAN ASSY,OIL      000000024    07/31/26
```

Every field as sent. **Negative control:** serials `000000016`–`000000023` (all body-format attempts)
are **absent from the report** — they created nothing. Serials 6–9 dated 07/30/26 are from earlier
manual Quick Label testing, unrelated.

The serial renders as `S000000024` in the report (label-type prefix); the stored serial is the bare
9 digits.

**Everything else we chased was a symptom of this one error:**

- Part-number renderings were never the issue — `112006FB A000` appears repeatedly in production
  traffic (`112006FB A000\t60\tMESL1715953`), confirming our derived format was right all along.
- The bare-filename exceptions (`.NNNNN` with no part) were AIM failing on a request with no payload
  anywhere it looks — of course serial and part were empty.
- Body framing, content types, `Expect: 100-continue`, chunking, `Keep-Alive` vs `close` — all
  irrelevant, because the body is never read.

**Other observations from production traffic:**

- The **lot field is usually the serial repeated** (`…\t30\t013843444`); occasionally a real lot
  (`MESL1715958`, `MESL1715953`).
- Real quantities vary widely (5, 6, 10, 15, 30, 48, 60, 96) — **quantity is not constrained to the
  standard pack**.
- Some parts carry a **trailing space** inside the part field (`1932A69F A000 `), consistent with the
  legacy export's `HasTrailingSpace` column.
- Production runs on **company `99`** from `172.17.10.8` (the legacy MES box); its serial counter is
  at ~13.84 million. **⚠️ Company `01` ONLY for MES testing — never send traffic to `99`.**

**Implementation note for `AimPoolGateway`:** build the URL, send an empty POST body, and treat
`len(response) == 11` / a 9-digit numeric reply as success; treat a reply containing `POST ` as a
routing failure (unrecognized request), which is a usable synchronous error signal — better than the
fire-and-forget assumption recorded earlier.

#### 🔴 SUPERSEDED — earlier conclusion that `postserial.csv` does not function

Exhaustively tested from the dev box. **No client-side variation reaches `MobileMain`:**

| Varied | Values tried |
|---|---|
| Transport | `Invoke-WebRequest`; raw TCP socket w/ explicit `Content-Length`; curl |
| Headers | `Connection: close` and `Keep-Alive`; AIM's own documented Dalvik UA + `Accept-Encoding: gzip` |
| Body framing | `payload+CRLF`; `CRLF+payload+CRLF`; no EOL; `payload+LF` |
| Content-Type | `application/x-www-form-urlencoded`; `text/plain`; urlencoded body; `data=` field |
| Part rendering | `11200-6FB-A00`, `112006FBA00`, `112006FB A000`, `11300R70 A000`, `11300R7- A000`, `11300R7-A000` |

**Every attempt: bare exception filename (no serial), message with no part number.**

Evidence it is server-side, not ours:

1. `nextserial.csv` works flawlessly — service live, path token + company `01` accepted, valid
   9-digit serials issued (counter reached `000000023` during testing).
2. The HTTP front-end **echoes our body back byte-exact** — verified with `cat -A`: real tab
   characters (`^I`), correct CRLF. The payload demonstrably arrives at `acsMobile-HTTPAPI`.
3. `postserial.csv` has **never** returned its documented reply (`{serialnumber}{cr}{lf}`). The echo
   is almost certainly the listener's *unrecognized-request* fallback, **not** an acknowledgement.
   (An earlier revision of this note read it as an ack — wrong.)
4. AIM's own historical exception `013504608.40802` **does** carry a 9-digit serial prefix, proving
   the parse path can populate it. Ours never does.

⇒ The POST-content half of AIM's modification is not working here. `GetNextNumber` is delivered;
`UpdateAim` is not.

**Server-side checks still owed** (none run yet): is the `MOBILE1` / acsMobile ProControl service
**running**? What is the **timestamp** on `013504608.40802` (did this ever work, and when did it
stop)? What does the **`acsMobileLog` Event Log** record for our requests? A stopped consuming
service would explain everything — the HTTP listener answering while nothing processes the request.

**Impact on the build:** `AimPoolGateway.topupTick()` can be implemented for real now (GetNextNumber
is proven). The container post-back (`UpdateAim`) **cannot be commissioned** until this is resolved.

#### What IS solidly established

1. **`Invoke-WebRequest` silently loses the body.** .NET adds `Expect: 100-continue` (and may chunk),
   which `acsMobile-HTTPAPI/2.0` does not handle — the request arrives with **empty fields**,
   producing an exception file named `.NNNNN` with **no serial prefix** and a message with **no part
   number** (`Blanket not found for Customer Part` with nothing after it). That signature means *the
   body never arrived*, NOT that the part is wrong — it sent us chasing part numbers for two days.
   **Use a raw socket with an explicit `Content-Length`** (or set
   `[System.Net.ServicePointManager]::Expect100Continue = $false`).

3. **The HTTP reply is an echo, not a result.** `postserial.csv` returns the request line plus the
   body it received:

   ```
   POST /mes/floor/01/636652666553236784/postserial.csv
   000000016	11300R7- A000	15	TESTLOT001
   ```

   Not the documented `{serialnumber}{cr}{lf}`. `acsMobile-HTTPAPI` only acknowledges receipt;
   **`MobileMain` creates the label asynchronously**. So a 200 proves nothing about the label.

#### 🔴 Architectural consequence — no success signal

**The only indication of failure is a file on AIM's server** (`…\Lineside\Exceptions\`), written
after the HTTP call has already returned 200. The MES cannot learn from the response whether a label
was built. Design implications for `AimPoolGateway`:

- **Use the echo as an integrity check.** Compare the echoed body to what we sent — a mismatch proves
  the body was mangled in transit (the exact `Invoke-WebRequest` failure above). This is a free,
  synchronous guard worth implementing.
- **Label-creation success is NOT observable synchronously.** Either poll/watch the Exceptions folder
  (needs a share or an agent on the AIM box) or accept fire-and-forget and reconcile later. Decide
  before wiring `Container_Complete` → post-back. Affects FDS-07-012.
- Exception filename convention: `<9-digit label number>.<n>` when the body parsed
  (`013504608.40802`), bare `.<n>` when it did not (`.36445`) — a usable diagnostic signature.

#### Diagnostic method (for the next person)

Send one request per candidate, **each with its own serial**, then attribute results by serial in the
Exceptions folder — the serial is the only correlation key, since the reply is only an echo. A serial
with **no** exception file is a success.

**Correlation table for the 2026-07-31 run (all raw-socket, all echoed back correctly):**

| Serial | Part sent | Qty | Lot | Form |
|---|---|---|---|---|
| `000000016` | `11300R7- A000` | 15 | TESTLOT001 | R70 customer part (X-Ref, with space) |
| `000000017` | `11300R70 A000` | 15 | TESTLOT001 | R70 item number |
| `000000018` | `11300R7-A000` | 15 | TESTLOT001 | R70 customer part, space removed |
| `000000019` | `112006FB A000` | 15 | TESTLOT001 | 6FB customer part |
| `000000020` | `112006FB A000` | 25 | TESTLOT002 | 6FB, non-standard-pack qty |
| `000000021` | `112006FB A000` | 15 | TESTLOT003 | 6FB, repeat |

⚠️ **Trap:** "no exception file" was read off a quick glance and proved wrong. Confirm success
**positively** — the label must appear under Shipping → Bar Code Entry → Serial. Absence of evidence
is not evidence here, particularly since exception writing is asynchronous and may lag the HTTP call.

---

**`postserial.csv` — ⚠️ TRANSPORT VALIDATED, lookup failed (2026-07-30) — superseded by the above.**

Sent `{serial}<TAB>11200-6FB-A00<TAB>50<TAB>TESTLOT001<CRLF>`. AIM returned:

```
Blanket not found for customer part
```

**This is a successful transport test.** AIM accepted the POST, parsed the tab-delimited body,
extracted field 2, and reached the blanket lookup. Confirmed by this result:

| Fact | Consequence |
|---|---|
| Body framing `payload + CRLF` accepted | Variant A is correct; variants B/C in §5.3 are unnecessary |
| Tab delimiter + 4-field order parsed | Payload contract as documented is right |
| Error names **"customer part"** | Field 2 is matched against the **Customer Part Number**, NOT the Item Master item number — confirms §2's warning empirically |

**Remaining unknown: the correct customer-part string.** `11200-6FB-A00` is the Item Master *item
number*. Leading hypothesis is that AIM indexes blankets by a **dashless** customer part
(`112006FBA00`) — which would finally explain legacy Base2's otherwise-arbitrary
`partName.Replace("-", "")`: it was converting item-number form into customer-part form for this
exact lookup. Honda EDI part numbers are commonly transmitted dashless.

Resolve definitively rather than by guessing — read the value out of AIM:

- **Orders → Customer Part / Item Number Cross-Reference**, look up `11200-6FB-A00`; the
  **Customer Part Number** field is what field 2 wants, verbatim.
- **Orders → Blanket Detail Summary by Customer Part Report** (company 01) — lists customer parts
  that *have* blankets. Any value there is guaranteed to satisfy the lookup. An **empty** report
  means company 01 has no order data and MPP/AIM must seed a blanket first.

Capture whether the customer part is dashless and whether it carries space padding — that is the
mapping rule `Parts.Item.PartNumber` → AIM will have to implement.

**Retry with the dashless form `112006FBA00` failed identically (2026-07-30).** So the cause is
probably NOT the part-number format.

**AIM documents this exact error, and both causes are blanket state/config — not the part number:**

> *"Blanket not found — This exception can be displayed for one of two reasons: 1) the **Active**
> field on the Blanket PO Entry - General screen is off or false, or 2) the **Control Source**
> identified in the **Destination** table is incorrect for the blanket on file."*
> — `AIM_docs/customer_docs/autocor_ship_order_entry_import.htm` (exception 7)

*Provenance caveat:* that table documents the **AutoCOR Ship Order Entry Import** path, not the
Mobility HTTP service. Identical wording, same ERP, same blanket lookup — strong candidates, not
certainties.

**Diagnostic order (no serials consumed until the last step):**

1. **Quick Label Create and Print** with the part — the manual equivalent of `postserial.csv`, same
   blanket resolution. Failing here too ⇒ conclusively AIM-side data/config; our request is fine.
   Succeeding here while the API fails ⇒ a real divergence to report to AIM.
2. **Blanket PO Entry / Inquiry** — does a blanket exist, and is **Active** checked? (cause 1)
3. **Destination table** — is the **Control Source** correct for that blanket? (cause 2)
4. **Blanket Detail Summary by Customer Part Report** — inventory of what exists, and it displays
   customer-part strings in AIM's own formatting (settles the dashes question as a side effect).

**Escalation wording if company `01` has no order data:** not *"what is the customer part number"*
but ***"we need one test part in company 01 with an active blanket and a correct control source on
its destination."***

⚠️ Flipping an inactive blanket's Active flag is a change to MPP's ERP data. Route through whoever
owns that system rather than toggling it silently, even in a test company.

**Exact AIM Vision menu paths** (from the help TOC, which mirrors the app menus; navigate via the
hamburger icon):

| Screen | Path |
|---|---|
| **Blanket Detail Summary by Customer Part Report** ← *start here* | Orders → Order Entry → Order Edit Lists |
| Blanket PO Entry / Inquiry (Active flag) | Orders → Order Entry |
| Destination (Control Source) | Orders → File Maintenance → Destination |
| Control Source master | Orders → File Maintenance |
| Customer Part / Item Number X-Ref | Orders → File Maintenance |
| PO Blanket Status Inquiry | Orders → Inquiries |
| **Quick Label Create and Print** (manual equivalent, no serial burned) | Shipping → **Processes** |
| Bar Code Format Type (Quick Labels Allowed) | Shipping → Bar Code File Maintenance |
| Serial Label Print / Entry (verify a posted serial) | Shipping → Bar Code Print / Bar Code Entry |

Two non-obvious placements: the blanket reports are under **Order Entry → Order Edit Lists**, not
under Orders → Reports; and Quick Label is under Shipping → **Processes**, not either Bar Code
submenu (the topic notes it is also reachable from the Bar Code menu, so installs may vary).

#### Verified 2026-07-31: blanket header, control source, and customer part are all CORRECT

Blanket exists; Control Source on the Destination matches; the customer-part value is confirmed.
**Both AutoCOR-documented causes are therefore ruled out**, and `postserial.csv` still fails.

**Leading hypothesis — the lookup is against Blanket Release Order DETAIL, not the header:**

> *"The Shipping Label or Serial Label Type Format to use is determined from the corresponding value
> in the **Blanket Release Order Detail** table based on the Item Number and Destination entered. If
> multiple destinations exist for the item number entered, then the user must select the destination
> from a filter browse."*
> *"the Blanket Release Order Detail table is checked to see if there is **only one active record**
> for that item."* — `quick_label_create_and_print.htm`

An active header with a good control source is **necessary but not sufficient**. Resolution needs
**exactly one active Blanket Release Order Detail record**.

🔴 **`postserial.csv` has no destination field** (serial / part / qty / lot only). With 2+ active
detail records the service cannot disambiguate — which is the agreement's own written exclusion:

> *"if the same customer part is sent to multiple destinations and the label requires destination
> specific content, adjustments will have to be made and are considered outside the scope."*

If confirmed, this is a **scope gap in the AIM agreement**, not a defect in our request, and it
escalates to MPP: *does this part ship to more than one Honda destination, and if so how is the
destination to be selected?* A destination field would have to be added to the interface.

**Diagnose without printing.** Quick Label resolves on tab-out of Item Number, before Print:

| Observed | Meaning |
|---|---|
| Destination auto-fills + Quantity per Container populates | exactly one active detail record — resolution OK |
| Forced to pick from a filter browse | **multiple** active destinations — the suspected cause |
| Neither populates | **no** active detail record |

Still to rule out: (a) was the blanket verified while logged into company **01**, the same company
the API posts to? (b) was the POST retried with the X-Ref string *verbatim*?

**Printing for a full manual test** needs the printer registered at Shipping → Bar Code File
Maintenance → **Device Control** (`device_control_file.htm`); "printer not in barcode device table"
is that record missing. Device ID must match the PC's printer name exactly (e.g.
`Microsoft Print to PDF`). Printer Type offers only Intermec / Intermec 34xx-44xx / Printronix-IGP /
Zebra — no generic type, so a PDF device would capture raw ZPL as text, not a rendered label.

### 5.7 Finding a valid part before testing `postserial.csv`

`postserial.csv` fails without an **active blanket** for the part (AIM resolves label format from
Blanket Release Order Detail by Item + Destination) and a bar-code format type flagged **"Quick
Labels Allowed"**. A fresh test company has neither.

**Quick Label Create and Print is the manual equivalent of `postserial.csv`** — same resolution path,
same constraints. Use it as the pre-check, because it cleanly separates *"my HTTP framing is wrong"*
from *"AIM's data isn't set up"*:

1. In AIM Vision, switch to company `01`. Bar Code menu (or Shipping menu) → **Quick Label Create
   and Print**.
2. Enter a part number. If it populates the description, resolves a Destination, and defaults
   Quantity per Container from Standard Pack, that part has a usable active blanket.
3. Bar Code → **Bar Code Format Type List** — confirm the format type for that part shows
   **Quick Labels Allowed** checked.
4. Use **that exact part number**, as AIM stores it, in the §5.3 payload.

If no part passes step 2, `postserial.csv` cannot succeed in company `01` regardless of framing, and
the next step is asking MPP/AIM to seed one test part with an active blanket — *not* debugging our
request.

Use a **fresh serial per framing attempt** (a serial already bound to a label may be rejected as a
duplicate on re-post). Company `01`'s counter is at 1, so serials are cheap here.

### What to bring back

The `$log` file, plus: exact status codes, whether the reply is zero-padded, which framing variant
worked, whether the part number needed dash-stripping, whether the serial needed the `1S` prefix,
and the contents of any Exceptions `.txt`. That set is enough to write the real
`AimPoolGateway.topupTick()` / post-back implementation with no guesswork.

---

## 6. Repo inventory (as of 2026-07-28)

**SQL** — `Lots.AimShipperIdPool` + `Lots.AimPoolConfig` (migration `0028`); repeatables
`R__Lots_AimShipperIdPool_Claim` / `_Topup` / `_GetDepth`, `R__Lots_AimPoolConfig_Get` / `_Update`;
claim inlined in `Container_Complete`; dev seed `sql/seeds/028_seed_aim_pool_dev.sql`; tests
`sql/tests/0028_PlantFloor_Assembly/035_AimPool_claim_topup.sql`,
`sql/tests/0029_PlantFloor_Hold_Sort_Shipping_Aim/040_AimPoolConfig.sql`.

**Ignition** — 5 named queries under `named-query/lots/Aim*`; Core scripts `BlueRidge.Lots.AimPool`,
`AimPoolConfig`, `AimPoolGateway`; MPP timers `AimPoolTopupTimer` (30s) + `AimPoolAlarmTimer` (60s),
both `enabled: true`; views `Components/PlantFloor/AimPoolTile`, `Views/ShopFloor/AimPoolConfig`.

**Stub status** — `AimPoolGateway.topupTick()` is a bare `return`; `placeOnHold` / `releaseFromHold`
/ `update` log an InterfaceLog attempt and return *"AIM endpoint not configured (dev)"*. Only
`alarmTick()` is functional. Both gateway timers are enabled and calling a no-op.

**Docs** — FDS-07-010 / 010a / 010b / 011 / 012 (§7.4); OI-33; FRS §2.1.10, §2.2.7, §2.3.1, §5.5.2,
Appendix J (legacy Base2), Appendix L (AIM interface); UJ-04 (pool design), UJ-05 (serial migration);
`notes/2026-07-14_zebra-label-template-datamodel-mapping.md`; `docs/ARC2_FDS_CONFORMANCE.md`.

**`AIM_docs/`** — untracked. `customer_AIM_http` is the contract and belongs in the repo. The
`customer_docs/` tree is 9,323 files of vendor HTML help (1,707 topics) — decide separately whether
to commit it, extract only the relevant topics, or gitignore it and keep it on a share.
