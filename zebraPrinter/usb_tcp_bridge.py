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

winspool = ctypes.WinDLL("winspool.drv", use_last_error=True)


class DOCINFO(ctypes.Structure):
    _fields_ = [("pDocName", wintypes.LPWSTR),
                ("pOutputFile", wintypes.LPWSTR),
                ("pDatatype", wintypes.LPWSTR)]


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
    """Send raw bytes to a Windows print queue via the spooler RAW datatype."""
    h = wintypes.HANDLE()
    if not winspool.OpenPrinterW(printer_name, ctypes.byref(h), None):
        raise ctypes.WinError(ctypes.get_last_error())
    try:
        di = DOCINFO("MES ZPL", None, "RAW")
        if not winspool.StartDocPrinterW(h, 1, ctypes.byref(di)):
            raise ctypes.WinError(ctypes.get_last_error())
        try:
            if not winspool.StartPagePrinter(h):
                raise ctypes.WinError(ctypes.get_last_error())
            written = wintypes.DWORD(0)
            if not winspool.WritePrinter(h, data, len(data), ctypes.byref(written)):
                raise ctypes.WinError(ctypes.get_last_error())
            return written.value
        finally:
            winspool.EndPagePrinter(h)
            winspool.EndDocPrinter(h)
    finally:
        winspool.ClosePrinter(h)


def main():
    printer_name = sys.argv[1] if len(sys.argv) > 1 else DEFAULT_PRINTER
    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind((HOST, PORT))
    srv.listen(5)
    print("Bridging  %s:%d  ->  printer '%s'   (Ctrl-C to stop)" % (HOST, PORT, printer_name))
    sys.stdout.flush()
    while True:
        conn, addr = srv.accept()
        conn.settimeout(2.0)
        chunks = []
        try:
            while True:
                b = conn.recv(4096)
                if not b:
                    break
                chunks.append(b)
        except socket.timeout:
            pass
        finally:
            conn.close()
        data = b"".join(chunks)
        if data:
            try:
                n = send_raw(printer_name, data)
                print("  received %d bytes -> spooled %d to '%s'" % (len(data), n, printer_name))
            except Exception as e:
                print("  PRINT ERROR: %s" % e)
            sys.stdout.flush()


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        print("\nstopped.")
