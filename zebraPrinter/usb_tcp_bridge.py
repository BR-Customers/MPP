"""
usb_tcp_bridge.py  --  local loopback TCP:9100 -> USB Zebra bridge (no dependencies)

Lets the MES's ZPL dispatcher (BlueRidge.Lots.LotLabel._dispatchZpl, a raw-TCP
write to host:9100) print to a USB-connected Zebra WITHOUT putting the printer on
the network. It listens ONLY on 127.0.0.1 (loopback -- nothing is exposed to the
LAN) and forwards received bytes to a Windows print queue via the spooler RAW
datatype, calling winspool.drv directly through ctypes -- PURE STANDARD LIBRARY,
no pywin32 needed.

Run:
    python zebraPrinter/usb_tcp_bridge.py                        # -> "Zebra GX420d (RAW)"
    python zebraPrinter/usb_tcp_bridge.py "Some Printer Name"    # override the queue

Then point the terminal's Printer endpoint at  127.0.0.1:9100  (or test from the
Designer Script Console:
     import BlueRidge.Lots.LotLabel as LL
     print LL._dispatchZpl("127.0.0.1:9100", "^XA^CFA,30^FO50,50^FDMES TEST^FS^XZ")
).  Ctrl-C to stop.
"""
import ctypes
from ctypes import wintypes
import socket
import sys

HOST = "127.0.0.1"          # loopback ONLY -- not reachable from the network
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
