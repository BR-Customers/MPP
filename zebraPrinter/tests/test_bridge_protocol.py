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


def test_status_reports_version_queue_and_readiness():
    reply = bridge.handle_request(b"?STATUS", "Zebra GX420d (RAW)",
                                  _spool_ok, _status_ok)
    assert reply == ("OK bridge=%s queue='Zebra GX420d (RAW)' ready=true jobs=0"
                     % bridge.BRIDGE_VERSION)


def test_status_is_case_insensitive():
    lower = bridge.handle_request(b"?status", "Q", _spool_ok, _status_ok)
    upper = bridge.handle_request(b"?STATUS", "Q", _spool_ok, _status_ok)
    # Assert the CONTENT too, not just that the two agree -- comparing them
    # alone passes against any stub that returns one constant for both.
    assert lower == upper
    assert lower.startswith("OK bridge=")


def test_status_reports_a_not_ready_queue():
    def busy():
        return {"queue": "Q", "ready": False, "jobs": 3}
    reply = bridge.handle_request(b"?STATUS", "Q", _spool_ok, busy)
    assert "ready=false" in reply
    assert "jobs=3" in reply


def test_a_quote_in_a_queue_name_is_doubled():
    def odd():
        return {"queue": "Bob's Zebra", "ready": True, "jobs": 0}
    reply = bridge.handle_request(b"?STATUS", "Q", _spool_ok, odd)
    assert "queue='Bob''s Zebra'" in reply


def test_unknown_command_is_refused_not_ignored():
    reply = bridge.handle_request(b"?WAT", "Q", _spool_ok, _status_ok)
    assert reply.startswith("ERR unknown command")
    assert "?WAT" in reply
