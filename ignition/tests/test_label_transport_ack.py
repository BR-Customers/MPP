"""Guard for LabelTransport's read of the bridge ACK.

zebraPrinter/PROTOCOL.md is frozen and three workstreams build against it.
_parseAck is the Gateway's half of that contract, so these tests pin the exact
line formats rather than the behaviour they happen to produce.

LabelTransport is Jython and imports java.net, so it cannot be imported under
CPython. These tests ast-extract the self-contained helpers and exec those --
the same approach as test_location_sort_order.py.

Run: python -m pytest ignition/tests/test_label_transport_ack.py
"""

import ast
import io
import os

import pytest

MODULE = os.path.join(
    os.path.dirname(__file__), os.pardir,
    "projects", "Core", "ignition", "script-python",
    "BlueRidge", "Lots", "LabelTransport", "code.py",
)

WANTED = ("_parseAck", "_unquote", "_dispatchLogParams")


def load_helpers(path=MODULE):
    """Exec only the self-contained helpers, so the test needs no Ignition."""
    src = io.open(path, encoding="utf-8").read()
    tree = ast.parse(src)
    keep = [n for n in tree.body
            if isinstance(n, ast.FunctionDef) and n.name in WANTED]
    # _SYSTEM_NAME is a module-level constant, not a function, so the extractor
    # does not pick it up. Seed it -- its value is asserted nowhere here; the
    # column it lands in is verified against the live DB in the plan's Task 5.
    ns = {"_SYSTEM_NAME": "Zebra"}
    exec(compile(ast.Module(body=keep, type_ignores=[]), path, "exec"), ns)
    return ns


@pytest.fixture(scope="module")
def helpers():
    ns = load_helpers()
    missing = [n for n in WANTED if n not in ns]
    if missing:
        pytest.fail("helper(s) missing from the module: %s" % ", ".join(missing))
    return ns


def test_a_successful_print_ack_is_parsed(helpers):
    got = helpers["_parseAck"]("OK queue='Zebra GX420d (RAW)' job=41 bytes=1264")
    assert got["acked"] is True
    assert got["ok"] is True
    assert got["queue"] == "Zebra GX420d (RAW)"
    assert got["job"] == 41
    assert got["bytes"] == 1264
    assert got["error"] is None


def test_an_err_ack_carries_the_reason(helpers):
    got = helpers["_parseAck"]("ERR queue not found: 'ZDesigner GX420d'")
    assert got["acked"] is True
    assert got["ok"] is False
    assert "queue not found" in got["error"]


def test_no_ack_is_not_a_failure(helpers):
    """A networked Zebra never replies. That is the expected result for
       ConnectionKind = Networked, not an error."""
    for line in (None, "", "   "):
        got = helpers["_parseAck"](line)
        assert got["acked"] is False
        assert got["ok"] is False
        assert got["error"] is None


def test_a_doubled_quote_in_a_queue_name_is_unescaped(helpers):
    got = helpers["_parseAck"]("OK queue='Bob''s Zebra' job=1 bytes=2")
    assert got["queue"] == "Bob's Zebra"


def test_an_unparseable_line_is_reported_not_swallowed(helpers):
    got = helpers["_parseAck"]("banana")
    assert got["acked"] is True
    assert got["ok"] is False
    assert "banana" in got["error"]


def _params(helpers, outcome, endpoint="10.20.11.157:9100"):
    return helpers["_dispatchLogParams"](endpoint, "^XA^XZ", outcome, "Shipping label")


def test_a_spooled_print_records_the_queue_and_job(helpers):
    ack = {"acked": True, "ok": True, "queue": "Zebra GX420d (RAW)",
           "job": 41, "bytes": 1264, "error": None}
    p = _params(helpers, {"ok": True, "error": None, "transport": "tcp", "ack": ack})
    assert p["errorCondition"] is None
    assert "Spooled" in p["responsePayload"]
    assert "job=41" in p["responsePayload"]
    assert "Zebra GX420d (RAW)" in p["responsePayload"]


def test_a_networked_printer_with_no_ack_is_recorded_as_sent_not_failed(helpers):
    ack = {"acked": False, "ok": False, "queue": None,
           "job": None, "bytes": None, "error": None}
    p = _params(helpers, {"ok": True, "error": None, "transport": "tcp", "ack": ack})
    assert p["errorCondition"] is None
    assert "no ack" in p["responsePayload"]


def test_a_transport_failure_names_the_stage(helpers):
    p = _params(helpers, {"ok": False, "error": "Connect timed out",
                          "transport": "tcp", "ack": {"acked": False, "ok": False,
                                                      "queue": None, "job": None,
                                                      "bytes": None, "error": None}})
    assert p["errorCondition"] == "DispatchFailed"
    assert p["errorDescription"] == "Connect timed out"


def test_a_bridge_refusal_is_distinguished_from_a_network_failure(helpers):
    """The bridge answered -- so the network is fine and the queue is wrong.
       That must not read as a connectivity problem."""
    ack = {"acked": True, "ok": False, "queue": None, "job": None,
           "bytes": None, "error": "queue not found: 'ZDesigner GX420d'"}
    p = _params(helpers, {"ok": False, "error": ack["error"],
                          "transport": "tcp", "ack": ack})
    assert p["errorCondition"] == "QueueRejected"
    assert "ZDesigner GX420d" in p["errorDescription"]
