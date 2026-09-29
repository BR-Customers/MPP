"""Wire-protocol guard for the MES Zebra bridge.

zebraPrinter/PROTOCOL.md is the contract three separate workstreams build
against -- the C# MesZebraBridge service, LabelTransport's ACK read, and the
Config Tool's test button. These tests pin the exact bytes on the wire so a
well-meaning edit to the bridge cannot silently move the contract.

The spooler and the queue-status reader are injected, so nothing here needs a
printer, a driver, or Windows print services.

Run: python -m pytest zebraPrinter/tests/test_bridge_protocol.py
"""

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

import usb_tcp_bridge as bridge


def _spool_ok(data):
    return (41, len(data))


def _status_ok():
    return {"queue": "Zebra GX420d (RAW)", "ready": True, "jobs": 0}


def test_empty_request_gets_no_reply():
    """validateEndpoint connects and closes without sending. Replying to that
       would be a protocol change; staying silent is the contract."""
    assert bridge.handle_request(b"", "Q", _spool_ok, _status_ok) is None
