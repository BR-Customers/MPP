"""Guard for the Config Tool's Test printer action.

The point of this action is that it makes 54 printers commissionable without
manufacturing 54 containers -- so what it SAYS matters as much as whether it
works. Each of the four outcomes sends a person to a different machine:

    unreachable  -> the bridge service, or the firewall on the terminal PC
    not a bridge -> something else owns 9100 there
    refused      -> right machine, wrong queue name
    not ready    -> right queue, printer offline or paused

These tests pin those four apart. Flattening them into one "printer offline"
is the failure mode the 2026-09-29 bring-up actually hit.

Printer/code.py imports java.net at module level, so it cannot be imported under
CPython. These tests ast-extract the self-contained helpers and exec those --
the same approach as test_label_transport_ack.py.

Run: python -m pytest ignition/tests/test_printer_probe.py
"""

import ast
import io
import os

import pytest

MODULE = os.path.join(
    os.path.dirname(__file__), os.pardir,
    "projects", "Core", "ignition", "script-python",
    "BlueRidge", "Location", "Printer", "code.py",
)

WANTED = ("_parseHostPort", "_kindOrDefault", "_draftPrinterFields",
          "_describeBridgeResult", "_withSource")


def load_helpers(path=MODULE):
    src = io.open(path, encoding="utf-8").read()
    tree = ast.parse(src)
    keep = [n for n in tree.body
            if isinstance(n, ast.FunctionDef) and n.name in WANTED]
    ns = {"_DEFAULT_ZEBRA_PORT": 9100}
    exec(compile(ast.Module(body=keep, type_ignores=[]), path, "exec"), ns)
    return ns


@pytest.fixture(scope="module")
def helpers():
    ns = load_helpers()
    missing = [n for n in WANTED if n not in ns]
    if missing:
        pytest.fail("helper(s) missing from the module: %s" % ", ".join(missing))
    return ns


def _probe(**kw):
    base = {"reached": True, "isBridge": True, "bridge": "1.0.0",
            "queue": "Zebra GX420d (RAW)", "ready": True, "jobs": 0, "error": None}
    base.update(kw)
    return base


def test_an_absent_kind_reads_as_networked(helpers):
    """The same default Location.ufn_PrinterEndpoint and Location_SaveAll apply,
       because it is the attribute's DefaultValue."""
    for v in (None, "", "   "):
        assert helpers["_kindOrDefault"](v) == "Networked"
    assert helpers["_kindOrDefault"](" UsbBridge ") == "UsbBridge"


def test_a_ready_bridge_names_the_queue_it_is_bound_to(helpers):
    got = helpers["_describeBridgeResult"]("172.17.20.5", 9100, _probe())
    assert got["status"] is True
    assert got["level"] == "success"
    assert "Zebra GX420d (RAW)" in got["message"]
    assert "172.17.20.5:9100" in got["message"]


def test_nothing_listening_points_at_the_service_and_the_firewall(helpers):
    got = helpers["_describeBridgeResult"](
        "172.17.20.5", 9100,
        _probe(reached=False, isBridge=False, bridge=None, queue=None,
               ready=None, error="Connection refused: getsockopt"))
    assert got["status"] is False
    assert got["level"] == "error"
    assert "Connection refused" in got["message"]
    assert "MesZebraBridge" in got["message"]


def test_a_silent_far_end_is_not_reported_as_a_working_printer(helpers):
    """Something accepted the connection but did not answer ?STATUS. For a
       UsbBridge printer that is a real fault -- the old bare-connect test passed
       in exactly this state and a label still never printed."""
    got = helpers["_describeBridgeResult"](
        "172.17.20.5", 9100,
        _probe(isBridge=False, bridge=None, queue=None, ready=None))
    assert got["status"] is False
    assert "did not answer" in got["message"]


def test_a_wrong_queue_name_is_a_different_diagnosis(helpers):
    """The bridge ANSWERED, so the network is fine and the queue is wrong. This
       is the ZDesigner-vs-Zebra trap, and it must not read as connectivity."""
    got = helpers["_describeBridgeResult"](
        "172.17.20.5", 9100,
        _probe(ready=False, queue=None,
               error="queue not found: 'ZDesigner GX420d'"))
    assert got["status"] is False
    assert "ZDesigner GX420d" in got["message"]


def test_a_bound_but_not_ready_queue_says_which_queue(helpers):
    got = helpers["_describeBridgeResult"](
        "172.17.20.5", 9100, _probe(ready=False, jobs=3))
    assert got["status"] is False
    assert "Zebra GX420d (RAW)" in got["message"]
    assert "3" in got["message"]


def test_a_queue_with_a_backlog_is_not_reported_as_simply_ready(helpers):
    """2026-09-30: two labels spooled cleanly, ShippingLabel.PrintedAt set,
       InterfaceLog clean -- and nothing printed, because the Zebra was
       unplugged. A Windows queue outlives its device: it keeps accepting jobs
       and sets no error, offline or paused bit, so ready stayed true while
       jobs climbed. ready is accurate about the status bits and useless for
       the question being asked, so jobs is read alongside it."""
    got = helpers["_describeBridgeResult"]("172.17.20.5", 9100, _probe(jobs=2))
    assert got["status"] is False
    assert got["level"] == "warning"
    assert "2 job" in got["message"]
    assert "unplugged" in got["message"] or "powered off" in got["message"]
    # Still names the binding -- the bridge and queue are fine, the device is not.
    assert "Zebra GX420d (RAW)" in got["message"]


def test_an_empty_queue_is_still_a_clean_pass(helpers):
    """A healthy queue drains in milliseconds -- verified 2026-09-30, job 30,
       jobs=0 before and after. So the backlog check must not fire on zero."""
    got = helpers["_describeBridgeResult"]("172.17.20.5", 9100, _probe(jobs=0))
    assert got["status"] is True
    assert got["level"] == "success"


def test_a_not_ready_queue_still_wins_over_the_backlog_warning(helpers):
    """An explicit NOT-ready queue is a harder fault than a backlog and must
       keep its own error rather than being softened to a warning."""
    got = helpers["_describeBridgeResult"]("172.17.20.5", 9100,
                                           _probe(ready=False, jobs=2))
    assert got["status"] is False
    assert got["level"] == "error"
    assert got["title"] == "Queue not ready"


def test_a_derived_endpoint_says_where_the_host_came_from(helpers):
    """Without this the message names an address that appears nowhere on the
       printer row, because a UsbBridge printer stores no endpoint at all."""
    msg = helpers["_withSource"]("Printer ready.", {
        "EndpointSource": "derived-terminal-ip",
        "TerminalIpAddress": "172.17.20.5",
        "ConnectionKind": "UsbBridge", "StoredEndpoint": None})
    assert "172.17.20.5" in msg
    assert "terminal" in msg.lower()


def test_an_unresolved_endpoint_dumps_the_three_facts_that_explain_it(helpers):
    msg = helpers["_withSource"]("No endpoint.", {
        "EndpointSource": "unresolved", "TerminalIpAddress": None,
        "ConnectionKind": "UsbBridge", "StoredEndpoint": None})
    assert "UsbBridge" in msg


def test_a_stored_endpoint_says_so(helpers):
    msg = helpers["_withSource"]("Reachable.", {
        "EndpointSource": "stored", "TerminalIpAddress": None,
        "ConnectionKind": "Networked", "StoredEndpoint": "172.17.20.228:9100"})
    assert "stored" in msg


def test_the_draft_reader_pulls_endpoint_and_kind(helpers):
    ep, kind = helpers["_draftPrinterFields"]([
        {"name": "Endpoint", "value": "", "defaultValue": None},
        {"name": "Model", "value": "GX420d", "defaultValue": None},
        {"name": "ConnectionKind", "value": "UsbBridge", "defaultValue": "Networked"},
    ])
    assert ep == ""
    assert kind == "UsbBridge"


def test_the_draft_reader_falls_back_to_the_default_value(helpers):
    ep, kind = helpers["_draftPrinterFields"]([
        {"name": "Endpoint", "value": None, "defaultValue": None},
        {"name": "ConnectionKind", "value": None, "defaultValue": "Networked"},
    ])
    assert ep == ""
    assert kind == "Networked"


def test_the_draft_reader_survives_junk_rows(helpers):
    ep, kind = helpers["_draftPrinterFields"]([None, {}, {"name": "Endpoint"}])
    assert ep == ""
    assert kind == ""


def test_a_port_less_endpoint_still_parses_to_the_zebra_default(helpers):
    """Unchanged behaviour, pinned because Task 4 now feeds this function a
       value SQL composed rather than one a human typed."""
    assert helpers["_parseHostPort"]("172.17.20.5") == ("172.17.20.5", 9100)
    assert helpers["_parseHostPort"]("172.17.20.5:9101") == ("172.17.20.5", 9101)
