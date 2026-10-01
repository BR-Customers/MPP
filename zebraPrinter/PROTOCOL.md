# MES Zebra Bridge -- Wire Protocol v1.0.0

Normative. The Gateway (`BlueRidge.Lots.LabelTransport`), the `MesZebraBridge`
Windows service, and `zebraPrinter/usb_tcp_bridge.py` all conform to this file.
Change it here first, with agreement, before changing any implementation.

Transport: TCP, default port 9100. One request per connection.

## Framing

The client writes its request, then **half-closes** its side of the socket
(`shutdown(SHUT_WR)`). The half-close is what ends the server's read
immediately; without it the server waits out a 2 second idle timeout and the
round trip becomes seconds instead of milliseconds.

The server then writes **one line**, terminated with a single `\n`, and closes.

All bytes in both directions are ASCII. A request larger than 1 MiB is
truncated at that limit.

## Requests

| First byte | Meaning |
|---|---|
| (no bytes at all) | Reachability probe. **The server replies nothing** and closes. |
| `?` | A command (see below). |
| anything else | ZPL to print. |

## Responses

A response is `OK` or `ERR`, a space, then `key=value` pairs separated by
single spaces. Values that may contain spaces are single-quoted; a `'` inside
a quoted value is doubled (`Bob's` becomes `'Bob''s'`).

### Print

```
-> ^XA...^XZ            then shutdown(SHUT_WR)
<- OK queue='Zebra GX420d (RAW)' job=41 bytes=1264
<- ERR [WinError 1801] The printer name is invalid.
```

`job` is the Windows spooler job id. `bytes` is the byte count handed to the
spooler.

Everything after `ERR ` is **free text**, collapsed to one line. The minimum is
the underlying error, exactly as the reference implementation emits it above --
that string was observed on 2026-09-30 and is what `Audit.InterfaceLog` records
as `QueueRejected`.

An implementation **SHOULD** do better for an unknown queue by naming what it
found, because the bare Win32 message says the name is wrong without saying what
would be right:

```
<- ERR queue not found: 'ZDesigner GX420d'; visible: Zebra GX420d (RAW), Microsoft Print to PDF
```

This is a SHOULD, not a MUST: the Python reference bridge takes its queue name
as an argument and does not enumerate, so it emits the minimum. `MesZebraBridge`
already enumerates local queues for auto-detection and is expected to emit the
richer form. Both are conformant -- a client parses `ERR ` plus free text and
must not depend on either wording.

*(An earlier revision of this file showed only the richer form as though it were
what the reference implementation produced. It was not, and no implementation
emitted it. Corrected 2026-09-30.)*

`OK` means the named Windows queue accepted these bytes as that job. It does
**not** mean a label physically printed -- that is not knowable from here and
is never claimed.

### `?STATUS`

```
-> ?STATUS              then shutdown(SHUT_WR)
<- OK bridge=1.0.0 queue='Zebra GX420d (RAW)' ready=true jobs=0
<- ERR unknown command '?WAT'
```

`ready` is `true` or `false`. `jobs` is the queue's current job count. No label
is consumed, so this is safe to call at any time and is the basis of the
Config Tool's "Test this printer" action.

**`ready` reports the printer's status bits and nothing more.** A Windows queue
whose device is unplugged or powered off keeps accepting jobs and stacking them,
and Windows sets no error, offline, paused or not-available bit while it does --
so such a queue answers `ready=true` with `jobs` climbing and never falling.
Observed 2026-09-30: two labels spooled cleanly, `jobs=2`, nothing printed, the
Zebra was unplugged.

**A client must read `ready` and `jobs` together.** A healthy queue drains in
milliseconds, so `jobs > 0` at probe time is itself a signal worth surfacing.
This is a reading rule, not a format change -- nothing in the grammar above
moves.

Commands are case-insensitive. An unrecognised command is an `ERR`, never
silence.

## Non-bridge printers

A real networked Zebra on raw 9100 never replies. A client that reads nothing
before its timeout records `sent, no ack (raw 9100)`. That is **not** an
error -- it is the expected result for a `ConnectionKind = Networked` printer
and must be recorded as distinct from a failure.

## Verified

Observed 2026-09-29 against the real Windows spooler and the real Zebra driver
(`ZDesigner GX420d` / USB002), bridge and client both on `127.0.0.1`:

    ?STATUS  -> OK bridge=1.0.0 queue='ZDesigner GX420d' ready=true jobs=0
    ^XA...   -> OK queue='ZDesigner GX420d' job=15 bytes=38
    (empty)  -> no reply

And with the bridge bound to a queue that does not exist on the host, which is
what reaches `Audit.InterfaceLog` as `QueueRejected` (rows 32-34, 2026-09-30):

    ^XA...   -> ERR [WinError 1801] The printer name is invalid.

The job id is real, not a placeholder: `Get-PrintJob` independently reported
`Id 15, MES ZPL, 38 bytes` for that exchange. `StartDocPrinterW`'s return
value **is** the spooler job id on this driver, and `bytes` matches the
spooler's own size. The job was purged afterwards.

Binding a queue name that does not exist on the host returns
`ready=false` while still naming what it tried -- which is how commissioning
catches the wrong-queue-name mistake before any label is wasted.

### Not yet verified

- **That a label physically emerges.** Requires the printer attached; the
  spooler accepts and numbers jobs regardless. See the note under Print: `OK`
  has never meant "printed".
- **The exchange over the network**, Gateway host to a remote bridge. Raw TCP
  reachability to `10.20.11.157:9100` was proven on 2026-09-29, but not
  carrying this protocol.

The C# `MesZebraBridge` service is correct when it reproduces the three
verified exchanges above byte for byte.
