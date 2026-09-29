"""
usb_tcp_bridge.py  --  local loopback TCP:9100 -> USB Zebra bridge (no dependencies)

Lets the MES's ZPL dispatcher (BlueRidge.Lots.LabelTransport, a raw-TCP write to
host:9100) print to a USB-connected Zebra by exposing it on the LAN. Listens on
ALL interfaces (0.0.0.0) and forwards received bytes to a Windows print queue via
the spooler RAW datatype, calling winspool.drv directly through ctypes -- PURE
STANDARD LIBRARY, no pywin32 needed.

TEST/PROTOTYPE MODE: binding 0.0.0.0 means ANY machine that can reach this host on
port 9100 can print to it, unauthenticated. Fine for a one-off reachability test on
a coworker's laptop; NOT what should ship to a terminal PC long-term without also
firewalling the port to just the Gateway's IP (open item, design doc S10.3) and
running this as a proper Windows service instead of a console session.

Run:
    python zebraPrinter/usb_tcp_bridge.py                        # -> "Zebra GX420d (RAW)"
    python zebraPrinter/usb_tcp_bridge.py "Some Printer Name"    # override the queue

Then, from another machine on the LAN, point the printer endpoint at
<this-host's-IP>:9100  (find the IP with `ipconfig`), or test from the Designer
Script Console:
     print BlueRidge.Lots.LabelTransport.send("<ip>:9100", "^XA^CFA,30^FO50,50^FDMES TEST^FS^XZ")
Windows Firewall will likely prompt to allow python.exe on first run -- allow it,
or add an inbound rule for TCP 9100, or nothing outside this machine can connect.
Ctrl-C to stop.
"""
import ctypes
from ctypes import wintypes
import socket
import sys

HOST = "0.0.0.0"            # ALL interfaces -- reachable from the LAN, test/prototype only
PORT = 9100
DEFAULT_PRINTER = "Zebra GX420d (RAW)"

BRIDGE_VERSION = "1.0.0"
MAX_REQUEST_BYTES = 1048576   # 1 MiB -- see PROTOCOL.md "Framing"
READ_TIMEOUT = 2.0

winspool = ctypes.WinDLL("winspool.drv", use_last_error=True)


class DOCINFO(ctypes.Structure):
    _fields_ = [("pDocName", wintypes.LPWSTR),
                ("pOutputFile", wintypes.LPWSTR),
                ("pDatatype", wintypes.LPWSTR)]


class PRINTER_INFO_2(ctypes.Structure):
    _fields_ = [("pServerName", wintypes.LPWSTR), ("pPrinterName", wintypes.LPWSTR),
                ("pShareName", wintypes.LPWSTR), ("pPortName", wintypes.LPWSTR),
                ("pDriverName", wintypes.LPWSTR), ("pComment", wintypes.LPWSTR),
                ("pLocation", wintypes.LPWSTR), ("pDevMode", wintypes.LPVOID),
                ("pSepFile", wintypes.LPWSTR), ("pPrintProcessor", wintypes.LPWSTR),
                ("pDatatype", wintypes.LPWSTR), ("pParameters", wintypes.LPWSTR),
                ("pSecurityDescriptor", wintypes.LPVOID),
                ("Attributes", wintypes.DWORD), ("Priority", wintypes.DWORD),
                ("DefaultPriority", wintypes.DWORD), ("StartTime", wintypes.DWORD),
                ("UntilTime", wintypes.DWORD), ("Status", wintypes.DWORD),
                ("cJobs", wintypes.DWORD), ("AveragePPM", wintypes.DWORD)]


winspool.GetPrinterW.argtypes = [wintypes.HANDLE, wintypes.DWORD, wintypes.LPBYTE,
                                 wintypes.DWORD, ctypes.POINTER(wintypes.DWORD)]
winspool.GetPrinterW.restype = wintypes.BOOL
winspool.OpenPrinterW.argtypes = [wintypes.LPWSTR, ctypes.POINTER(wintypes.HANDLE), wintypes.LPVOID]
winspool.OpenPrinterW.restype = wintypes.BOOL
winspool.StartDocPrinterW.argtypes = [wintypes.HANDLE, wintypes.DWORD, ctypes.POINTER(DOCINFO)]
winspool.StartDocPrinterW.restype = wintypes.DWORD
winspool.StartPagePrinter.argtypes = [wintypes.HANDLE]
winspool.StartPagePrinter.restype = wintypes.BOOL
winspool.WritePrinter.argtypes = [wintypes.HANDLE, ctypes.c_char_p, wintypes.DWORD, ctypes.POINTER(wintypes.DWORD)]
winspool.WritePrinter.restype = wintypes.BOOL
winspool.EndPagePrinter.argtypes = [wintypes.HANDLE]
winspool.EndPagePrinter.restype = wintypes.BOOL
winspool.EndDocPrinter.argtypes = [wintypes.HANDLE]
winspool.EndDocPrinter.restype = wintypes.BOOL
winspool.ClosePrinter.argtypes = [wintypes.HANDLE]
winspool.ClosePrinter.restype = wintypes.BOOL


def send_raw(printer_name, data):
    """Send raw bytes to a Windows print queue. Returns (job_id, bytes_written)."""
    h = wintypes.HANDLE()
    if not winspool.OpenPrinterW(printer_name, ctypes.byref(h), None):
        raise ctypes.WinError(ctypes.get_last_error())
    try:
        di = DOCINFO("MES ZPL", None, "RAW")
        job = winspool.StartDocPrinterW(h, 1, ctypes.byref(di))
        if not job:
            raise ctypes.WinError(ctypes.get_last_error())
        try:
            if not winspool.StartPagePrinter(h):
                raise ctypes.WinError(ctypes.get_last_error())
            written = wintypes.DWORD(0)
            if not winspool.WritePrinter(h, data, len(data), ctypes.byref(written)):
                raise ctypes.WinError(ctypes.get_last_error())
            return (int(job), int(written.value))
        finally:
            winspool.EndPagePrinter(h)
            winspool.EndDocPrinter(h)
    finally:
        winspool.ClosePrinter(h)


def _oneline(text):
    """Collapse whitespace so an error can never break the one-line framing."""
    return " ".join(("%s" % text).split())


def _quote(value):
    """Single-quote a wire value, doubling any embedded quote (PROTOCOL.md)."""
    return "'" + ("%s" % value).replace("'", "''") + "'"


def queue_status(printer_name):
    """Read the queue's real state. ready = the queue opens and reports no
       error/offline/paused bit; jobs = its current job count. Never raises --
       an unopenable queue is a not-ready answer, which is the honest one."""
    h = wintypes.HANDLE()
    if not winspool.OpenPrinterW(printer_name, ctypes.byref(h), None):
        return {"queue": printer_name, "ready": False, "jobs": 0}
    try:
        needed = wintypes.DWORD(0)
        winspool.GetPrinterW(h, 2, None, 0, ctypes.byref(needed))
        if not needed.value:
            return {"queue": printer_name, "ready": False, "jobs": 0}
        buf = ctypes.create_string_buffer(needed.value)
        if not winspool.GetPrinterW(h, 2, ctypes.cast(buf, wintypes.LPBYTE),
                                    needed.value, ctypes.byref(needed)):
            return {"queue": printer_name, "ready": False, "jobs": 0}
        info = ctypes.cast(buf, ctypes.POINTER(PRINTER_INFO_2)).contents
        # PRINTER_STATUS_ERROR | _OFFLINE | _PAUSED | _NOT_AVAILABLE | _NO_TONER
        bad = 0x00000002 | 0x00000080 | 0x00000001 | 0x00001000 | 0x00040000
        return {"queue": printer_name,
                "ready": (info.Status & bad) == 0,
                "jobs": int(info.cJobs)}
    finally:
        winspool.ClosePrinter(h)


def handle_request(data, printer_name, spool, status):
    """Map one request's bytes to one response line WITHOUT its trailing
       newline, or None when the protocol says stay silent.

       spool(data)  -> (job_id, bytes_written), raises on failure
       status()     -> {"queue": str, "ready": bool, "jobs": int}

       Pure apart from the two injected callables, so the whole protocol is
       testable with no printer attached."""
    if not data:
        return None
    if data[:1] == b"?":
        cmd = data.decode("ascii", "replace").strip().upper()
        if cmd == "?STATUS":
            s = status()
            return "OK bridge=%s queue=%s ready=%s jobs=%d" % (
                BRIDGE_VERSION, _quote(s["queue"]),
                "true" if s["ready"] else "false", int(s["jobs"]))
        return "ERR unknown command %s" % _quote(cmd)
    try:
        job, written = spool(data)
    except Exception as e:
        return "ERR %s" % _oneline(e)
    return "OK queue=%s job=%d bytes=%d" % (_quote(printer_name), int(job), int(written))


def _read_request(conn):
    """Read until the peer half-closes, or the idle timeout, or the size cap."""
    chunks, total = [], 0
    try:
        while True:
            b = conn.recv(4096)
            if not b:
                break
            chunks.append(b)
            total += len(b)
            if total >= MAX_REQUEST_BYTES:
                break
    except socket.timeout:
        pass
    return b"".join(chunks)


def serve_connection(conn, printer_name, spool, status):
    """Read one request, write one response line, close. Never raises."""
    try:
        conn.settimeout(READ_TIMEOUT)
        reply = handle_request(_read_request(conn), printer_name, spool, status)
        if reply is not None:
            conn.sendall((reply + "\n").encode("ascii", "replace"))
            print("  %s" % reply)
            sys.stdout.flush()
    except Exception as e:
        print("  HANDLER ERROR: %s" % _oneline(e))
        sys.stdout.flush()
    finally:
        try:
            conn.close()
        except Exception:
            pass


def main():
    printer_name = sys.argv[1] if len(sys.argv) > 1 else DEFAULT_PRINTER
    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind((HOST, PORT))
    srv.listen(5)
    # A blocking accept() never returns to the interpreter loop, and on Windows CPython
    # only delivers KeyboardInterrupt to the main thread BETWEEN bytecode instructions --
    # so a Ctrl-C sits queued until the next connection arrives and appears to do nothing.
    # A 1s timeout hands control back every second so the interrupt lands promptly.
    srv.settimeout(1.0)
    print("Bridging  %s:%d  ->  printer '%s'   (Ctrl-C to stop)" % (HOST, PORT, printer_name))
    sys.stdout.flush()
    while True:
        try:
            conn, addr = srv.accept()
        except socket.timeout:
            continue
        # Log the source so a dispatch self-documents its origin: a Gateway-scope print
        # shows the Gateway's IP, a Designer Script Console test shows the local machine.
        print("  connection from %s" % (addr[0],))
        sys.stdout.flush()
        serve_connection(conn, printer_name,
                         lambda d: send_raw(printer_name, d),
                         lambda: queue_status(printer_name))


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        print("\nstopped.")
