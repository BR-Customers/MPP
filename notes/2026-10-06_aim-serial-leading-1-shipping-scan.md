# AIM serials issued to the MES start with `1`; the shipping tablet looks them up with `0` -- "Not On File"

**Date:** 2026-10-06 (found onsite by Jacques, about 16:42 ET, at the shipping dock)
**Status:** ANSWERED by AIM 2026-10-08; fix committed (`6023e7f9`), packaged for prod, not yet deployed --
see section 8. Original status: OPEN, cause located, fix not decided, question sent to MPP IT (section 6).
**Not caused by** the same-day Code 128 label release (`0106`): the 16 digits in the serial are composed
exactly as before, and the tablet stripped the new `1S` prefix and read them correctly.

---

## 1. What happened

A container labelled by the MES (part `1223A6MA J000`, qty 96) was scanned on the AIM Mobility shipping
tablet (`AIM Mobility (0.216) - TABLET - 99 - Shipping`, shipper `00084669`, OSCC1-01 AEP CONSOLIDATION
CENTER).

| | |
|---|---|
| Scanned barcode | `1S1321800113906404` |
| Tablet "Serial No" field | `1321800113906404` |
| Tablet alert | `Scanned Item Alert -- Serial Number: S013906404 Not On File` |

## 2. What we sent AIM for that box

`Audit.InterfaceLog` Id 27785, 2026-10-06 19:30:46 UTC, `AIM postserial`, response `OK`:

```
http://172.17.10.86:8080/mes/floor/99/<token>/postserial.csv?\r\n113906404\t1223A6MA J000\t96\tMESL3002604\r\n
```

So AIM accepted serial **`113906404`**; the tablet looked up **`013906404`**.

## 3. Why they differ

- The label serial is `13218001` (supplier code) + the **last 8** digits of the AIM serial
  (`Lots.ufn_ShippingLabelZpl`). A 9-digit serial does not fit; its first digit is dropped.
- The tablet takes the 8 digits after the supplier code, pads to 9 with a zero, and prefixes `S`.
- That round-trips only when the AIM serial's first digit is `0`. Ours is `1`.

## 4. Where the `1` comes from -- AIM, not us

Checked on prod 2026-10-06:

- `Lots.AimPoolConfig`: base URL `http://172.17.10.86:8080`, company `99`, posting enabled, target 50 /
  threshold 30, last updated 2026-09-16 14:49.
- The 20 newest pool rows (`113934769`-`113934788`, Ids 552-571, fetched 07:50:26-28 UTC) each sit 2-4 ms
  after a successful `AIM nextserial` row in `Audit.InterfaceLog` (Ids 26936-26955). Twenty for twenty.
- Grouping every 9-digit pool row by first digit returns one group: **`1`**. AIM has never issued the MES a
  serial starting with anything else.
- Code path (`AimPoolGateway.topupTick` -> `AimHttp.nextSerial` -> `Lots.AimShipperIdPool_Topup`): the
  reply is accepted only if it is exactly 9 digits after trimming and is stored unmodified. Nothing adds a
  digit.

Company 99 is production by our own records (`notes/2026-07-28_aim-interface-contract.md`: a captured
legacy production call to `/floor/99/`; MPP's test company is `01`). The vendor document's "99 is usually
used for test" does not apply at MPP.

### The last 8 digits are in the plant's real sequence

| When | Source | Serial | Last 8 |
|---|---|---|---|
| 2026-07 | legacy production call (captured) | `013843444` | `13843444` |
| 10/05 | legacy label | 8 digits on label | `13933626` |
| 10/06 07:50 UTC | `nextserial` reply to the MES | `113934769`-`788` | `13934769`-`788` |
| 10/06 | AIM batch label | 8 digits on label | `13936248` |

One shared counter, apparently, with a `1` in front of the values handed to our interface. On test company
`01` the same call returned plain zero-padded values (`000000024`), no `1`.

## 5. What AIM's own table shows (Jacques, 2026-10-06)

`acsAutosys.dbo.shipper_container`, `TOP 100 ... ORDER BY shipper_number DESC`, all company `99`:

- `serial_number` is 9 characters with a **leading zero** on every row returned (`012273012` ...
  `012288574`); `serial_prefix` is `S`. So the tablet's key `S013906404` is `serial_prefix + serial_number`,
  and legacy serials are filed with the leading `0`. This confirms what section 3 assumed.
- `supplier_lot_number` is either a legacy lot (`MESL1424814`) or the serial repeated, matching the
  postserial traffic already documented.

**What this does NOT show.** It is the table of containers already on a shipper. The rows returned are in
the 12.27-12.29 million range, well behind today's 13.93 million, so `ORDER BY shipper_number` did not
return the newest rows, and none of the MES-issued serials appear. Whether `113906404` is in this table at
all is not expected -- that box has not shipped. The record `postserial` created lives somewhere else
(AIM's "Unshipped Labels" report reads it); that table has not been found yet.

**Next look, read-only, on the AIM database:**

```sql
-- which tables carry a serial column
SELECT TABLE_NAME, COLUMN_NAME FROM acsAutosys.INFORMATION_SCHEMA.COLUMNS
WHERE COLUMN_NAME LIKE '%serial%' ORDER BY TABLE_NAME;

-- has anything with a leading 1 ever shipped, and where is the counter really
SELECT LEFT(serial_number, 1) AS FirstDigit, COUNT(*) AS Containers, MAX(serial_number) AS Highest
FROM acsAutosys.dbo.shipper_container WHERE company_code = '99'
GROUP BY LEFT(serial_number, 1);
```

Then search the label table the first query turns up for `113906404` and for `013906404`.

## 6. Message sent to MPP IT

Subject: *AIM serials issued to the new MES are not found at shipping scan*. Body: the flow in section 3
with the `113906404` example, and three questions:

1. Why does AIM give the MES interface serials starting with `1` when the legacy system's start with `0`?
   Is that a setting on company 99?
2. Can it be changed so the MES receives serials in the same `0...` range?
3. If the `1` is intentional, how should the label carry it so the tablet finds the record? Reprinting
   `113906404` from AIM would show what AIM expects.

## 7. Open, and what is at stake

- **Every MES-labelled container fails the shipping scan the same way.** Until this is resolved those boxes
  need an AIM-printed label to ship.
- **Possible wrong-record match.** Our printed serial is identical to what a genuine `013906404` would
  print. If that number was ever issued for real, scanning our label would find that record instead of
  failing. Not observed; the one scan so far returned Not On File.
- **Not known:** whether the `1` is deliberate; how AIM itself prints a label for a serial of 100,000,000
  or more; where the `postserial` record is stored.
- **Do not "fix" this by swapping the `1` for a `0` on our side** without the vendor's answer: it would
  post a serial AIM never issued to us, into a range the legacy system is still drawing from.
- **Standing gap, unchanged:** the `nextserial` success log does not record the serial returned and the
  pool row carries no `FetchedInterfaceLogId`, so provenance was proven here only by timestamp proximity.

## 8. Answered 2026-10-08 (AIM, by email)

AIM's reply: "you reserve a 113906404 using nextserial, but are supposed to print an 013906404 ... this is
not our design, just a requirement of the numbering scheme Flexware was using." Their log of the legacy MES
on 2026-06-30 shows `nextserial` returning `113803604` and the legacy client posting `013803604`, with AIM
replying `013803604`.

What that settles:

- **The `1` is not special to our interface.** Section 4's reading ("a `1` in front of the values handed to
  our interface") was wrong: the legacy MES receives the same `1...` serials and shortens them itself. There
  is one counter, at about 113.9 million.
- **The caution in section 7 is retired.** Posting `0` + the last 8 digits is not "a serial AIM never issued
  us"; it is the form AIM expects, and the last 8 digits come from the same counter legacy draws on, so
  there is no second range to collide with.
- **Fix:** `BlueRidge.Lots.AimHttp.postSerial` posts `0` + the last 8 digits and expects that echoed back
  (commit `6023e7f9`). The pool and the label are unchanged. Runbook:
  `notes/2026-10-08_prod-release-runbook-aim-post-serial.md`.
- **The boxes already posted in the `1...` form** were pulled and relabelled with AIM batch labels
  (Jacques, 2026-10-08). Their AIM records remain; whether to void them is AIM's call.
- AIM called this "the first problem", so more may follow in that thread.
