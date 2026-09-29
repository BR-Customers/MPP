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
<- ERR queue not found: 'ZDesigner GX420d'; visible: Zebra GX420d (RAW)
```

`job` is the Windows spooler job id. `bytes` is the byte count handed to the
spooler.

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

Commands are case-insensitive. An unrecognised command is an `ERR`, never
silence.

## Non-bridge printers

A real networked Zebra on raw 9100 never replies. A client that reads nothing
before its timeout records `sent, no ack (raw 9100)`. That is **not** an
error -- it is the expected result for a `ConnectionKind = Networked` printer
and must be recorded as distinct from a failure.
