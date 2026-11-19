"""Harness for BlueRidge.Workorder.ScaleDigiWatcher -- the Digi One SP scale
feed -- under plain CPython, with the Ignition modules it imports (java.lang,
system.*) and the BlueRidge entities it calls stubbed.

    python tools/test_scale_digi_watcher.py

Spec: docs/superpowers/specs/2026-11-19-digi-scale-feed-design.md

The record, one per GOOD press, as the TCP driver (Character Based, delimiter
CR) delivers it -- the previous record's two LFs at the front:

    \\n\\n(NET)15.5<UOM>LB<TWM>1<Part>TEST3\\r

What is proved here is the Python half: the parse, the order of the per-press
checks, what reaches SQL, and what lands in the InterfaceLog payload. The rules
(one held press per terminal, eligibility, no box mixing) are SQL's and are
tested in sql/tests/0134_ScaleDigi and sql/tests/0113_ScaleStation.
"""

import json
import os
import sys
import types
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SCRIPTS = os.path.join(ROOT, "ignition", "projects", "Core", "ignition",
                       "script-python", "BlueRidge")
CODE = os.path.join(SCRIPTS, "Workorder", "ScaleDigiWatcher", "code.py")


def _stubModules():
    java = types.ModuleType("java")
    java.lang = types.ModuleType("java.lang")
    java.lang.Exception = Exception
    system = types.ModuleType("system")
    for name in ("date", "opc", "tag", "util", "perspective"):
        mod = types.ModuleType("system." + name)
        setattr(system, name, mod)
        sys.modules["system." + name] = mod
    system.util.jsonEncode = lambda obj: json.dumps(obj, sort_keys=True)
    sys.modules.update({"java": java, "java.lang": java.lang, "system": system})


def _loadFile(path, name):
    _stubModules()
    mod = types.ModuleType(name)
    with open(path, encoding="utf-8") as f:
        source = f.read()
    exec(compile(source, path, "exec"), mod.__dict__)
    return mod


def _load():
    return _loadFile(CODE, "ScaleDigiWatcher")


W = _load()

BENCH = "(NET)15.5<UOM>LB<TWM>1<Part>TEST3"


class ParseTests(unittest.TestCase):

    def test_bench_record(self):
        p = W.parse(BENCH)
        self.assertTrue(p["ok"])
        self.assertEqual(p["net"], 15.5)
        self.assertEqual(p["netText"], "15.5")
        self.assertEqual(p["uom"], "LB")
        self.assertEqual(p["twm"], 1)
        self.assertEqual(p["part"], "TEST3")

    def test_leading_lf_from_previous_record(self):
        p = W.parse("\n\n" + BENCH + "\r")
        self.assertTrue(p["ok"])
        self.assertEqual((p["net"], p["part"]), (15.5, "TEST3"))

    def test_fragments_reassembled(self):
        frags = ["(N", "ET)1", "5.5<U", "OM>LB<", "TWM>1<Pa", "rt>TEST3", "\r"]
        p = W.parse("".join(frags))
        self.assertTrue(p["ok"])
        self.assertEqual((p["net"], p["uom"], p["twm"], p["part"]), (15.5, "LB", 1, "TEST3"))

    def test_part_with_spaces_and_dashes(self):
        p = W.parse("(NET)18.2<UOM>LB<TWM>1<Part>12270-6NA -A000")
        self.assertEqual(p["part"], "12270-6NA -A000")

    def test_two_records_refused(self):
        p = W.parse(BENCH + "\r\n\n" + BENCH)
        self.assertFalse(p["ok"])
        self.assertIn("2", p["reason"])

    def test_no_record_refused(self):
        p = W.parse("\n\nhello\r")
        self.assertFalse(p["ok"])
        self.assertIn("no weighment", p["reason"])

    def test_none_refused(self):
        self.assertFalse(W.parse(None)["ok"])

    def test_malformed_record_refused(self):
        p = W.parse("(NET)abc<UOM>LB<TWM>1<Part>TEST3")
        self.assertFalse(p["ok"])

    def test_twm_zero_parsed(self):
        p = W.parse("(NET)15.5<UOM>LB<TWM>0<Part>TEST3")
        self.assertTrue(p["ok"])
        self.assertEqual(p["twm"], 0)

    def test_empty_part(self):
        p = W.parse("(NET)15.5<UOM>LB<TWM>1<Part>\r")
        self.assertTrue(p["ok"])
        self.assertEqual(p["part"], "")

    def test_negative_net(self):
        p = W.parse("(NET)-0.4<UOM>LB<TWM>1<Part>TEST3")
        self.assertTrue(p["ok"])
        self.assertEqual(p["net"], -0.4)

    def test_decode_signed_bytes(self):
        self.assertEqual(W.decodeBytes([40, 78, 69, 84, 41, -1]), "(NET)\xff")

    def test_decode_bench_bytes(self):
        raw = [10, 10] + [ord(c) for c in BENCH] + [13]
        self.assertEqual(W.parse(W.decodeBytes(raw))["part"], "TEST3")

    def test_decode_none(self):
        self.assertIsNone(W.decodeBytes(None))

    def test_digi_record_roundtrip(self):
        rec = W.digiRecord(15.5, "TEST3")
        self.assertTrue(rec.startswith("\n\n(NET)15.5<UOM>LB<TWM>1<Part>TEST3"))
        p = W.parse(rec)
        self.assertEqual((p["net"], p["twm"], p["part"]), (15.5, 1, "TEST3"))


SYS = 1
TERM = 106
PATH = "[MPP]PlcDevices/digiTest"


def _running(itemId=110, source="Default", openContainerId=None):
    return {"ItemId": itemId, "PartNumber": "FG-%s" % itemId, "Source": source,
            "OpenContainerId": openContainerId}


class Recorder(object):
    """Stands in for every BlueRidge entity the watcher calls, recording each
       call so a case can assert on it."""

    def __init__(self, items=None, running=None, pending=None, judge=None,
                 setResult=None, holdResult=None, closeResult=None):
        self.items = items or {}
        self.running = running or _running()
        self.pending = pending
        self.judgeRow = judge or {"Verdict": "Ok", "LowLimit": 14, "HighLimit": 17}
        self.setResult = setResult or {"Status": 1, "Message": "Running part set."}
        self.holdResult = holdResult or {"Status": 1, "Message": "Tray held.", "NewId": 9}
        self.closeResult = closeResult or {"Status": 1, "ContainerId": 77, "FinishedGoodLotId": 501}
        self.logs, self.alarms, self.closes, self.broadcasts = [], [], [], []
        self.sets, self.holds, self.judgeCalls, self.claims = [], [], [], []
        self.pendingCalls = []

    def install(self, module):
        rec = self
        BR = types.SimpleNamespace()
        BR.Workorder = types.SimpleNamespace(
            PlcWatcher=types.SimpleNamespace(
                logInterface=lambda device, description, **kw:
                    rec.logs.append(dict(kw, device=device, description=description)),
                notifyAlarm=lambda terminal, title, message, level="error":
                    rec.alarms.append({"title": title, "message": message, "level": level}),
                broadcastPageMessage=lambda messageType, payload:
                    rec.broadcasts.append((messageType, payload))),
            ScaleEPrintWatcher=types.SimpleNamespace(
                _claim=lambda path, stamp, initial: rec.claims.append(stamp) or not initial),
            Assembly=types.SimpleNamespace(
                plcCompleteTray=lambda terminal, method:
                    rec.closes.append(method) or rec.closeResult),
            ScaleStation=types.SimpleNamespace(
                getRunningPartOrEmpty=lambda terminal: dict(rec.running),
                getPendingPressOrEmpty=lambda terminal: dict(rec.pending or {"Id": None}),
                setRunningPart=lambda terminal, itemId, appUserId=None:
                    rec.sets.append((terminal, itemId, appUserId)) or rec._setOutcome(itemId),
                holdPress=lambda terminal, net, uom, code, appUserId=None:
                    rec.holds.append((terminal, net, uom, code, appUserId)) or rec.holdResult))
        BR.Parts = types.SimpleNamespace(
            ContainerConfig=types.SimpleNamespace(judgeWeight=rec._judge),
            Item=types.SimpleNamespace(getByPartNumber=lambda pn: rec.items.get(pn)))
        BR.Common = types.SimpleNamespace(
            Util=types.SimpleNamespace(log=lambda *a, **k: None, systemAppUserId=lambda: SYS))
        module.BlueRidge = BR

    def _setOutcome(self, itemId):
        if self.setResult.get("Status"):
            self.running = _running(itemId, "Override")
        return self.setResult

    def _judge(self, itemId, method, weight, scaleFlags=None):
        self.judgeCalls.append({"itemId": itemId, "method": method, "weight": weight})
        return dict(self.judgeRow)

    def payload(self, description="ByWeight tray close"):
        rows = [l for l in self.logs if l["description"] == description]
        return json.loads(rows[-1]["requestPayload"]) if rows else None

    def conditions(self):
        return [l.get("errorCondition") for l in self.logs if l.get("errorCondition")]


def _run(rec, message=BENCH):
    rec.install(W)
    return W.handleMessage(PATH, TERM, message)


class HandleMessageTests(unittest.TestCase):

    def test_match_same_part_closes(self):
        rec = Recorder(items={"TEST3": {"Id": 110}})
        r = _run(rec)
        self.assertEqual(r["Status"], 1)
        self.assertEqual(rec.sets, [])
        self.assertEqual(rec.closes, ["ByWeight"])
        p = rec.payload()
        self.assertEqual((p["v"], p["partSource"], p["scalePart"], p["twm"]), (2, "Scale", "TEST3", 1))
        self.assertEqual((p["verdict"], p["scaleVerdict"], p["mesVerdict"], p["agree"]), ("Ok", "Ok", "Ok", True))
        close = [l for l in rec.logs if l["description"] == "ByWeight tray close"][0]
        self.assertEqual((close["locationId"], close["itemId"], close["lotId"], close["ok"]), (TERM, 110, 501, True))

    def test_match_other_part_switches_then_closes(self):
        rec = Recorder(items={"TEST3": {"Id": 222}})
        r = _run(rec)
        self.assertEqual(rec.sets, [(TERM, 222, SYS)])
        self.assertEqual(r["Status"], 1)
        self.assertEqual(rec.judgeCalls[0]["itemId"], 222)

    def test_switch_refused_closes_nothing(self):
        rec = Recorder(items={"TEST3": {"Id": 222}},
                       setResult={"Status": 0, "Message": "Finish open box #5 first."})
        r = _run(rec)
        self.assertEqual(r["Status"], 0)
        self.assertEqual(rec.closes, [])
        self.assertEqual(rec.alarms[-1]["message"], "Finish open box #5 first.")
        self.assertEqual(rec.payload("Tray not closed")["scalePart"], "TEST3")

    def test_unknown_code_with_open_box_closes_with_warning(self):
        rec = Recorder(running=_running(110, "Default", openContainerId=5))
        r = _run(rec)
        self.assertEqual(r["Status"], 1)
        self.assertIn("ScaleFlagsPartUnknown", rec.conditions())
        self.assertEqual(rec.payload()["partSource"], "Running")
        self.assertEqual(rec.holds, [])

    def test_unknown_code_with_override_closes_with_warning(self):
        rec = Recorder(running=_running(110, "Override"))
        r = _run(rec)
        self.assertEqual(r["Status"], 1)
        self.assertIn("ScaleFlagsPartUnknown", rec.conditions())

    def test_unknown_code_default_holds(self):
        rec = Recorder(running=_running(110, "Default"))
        r = _run(rec)
        self.assertTrue(r.get("Held"))
        self.assertEqual(r["Status"], 0)
        self.assertEqual(rec.holds, [(TERM, 15.5, "LB", "TEST3", SYS)])
        self.assertEqual(rec.closes, [])
        self.assertIn("ScaleFlagsHeld", rec.conditions())
        self.assertEqual(rec.alarms[-1]["level"], "warning")

    def test_unknown_code_nothing_runs_holds(self):
        rec = Recorder(running=_running(None, "None"))
        r = _run(rec)
        self.assertTrue(r.get("Held"))

    def test_hold_refused_is_a_refusal(self):
        rec = Recorder(running=_running(110, "Default"),
                       holdResult={"Status": 0, "Message": "A tray is already waiting", "NewId": None})
        r = _run(rec)
        self.assertEqual(r["Status"], 0)
        self.assertFalse(r.get("Held"))
        self.assertEqual(rec.closes, [])

    def test_deprecated_item_is_no_match(self):
        # Parts.Item.getByPartNumber returns None for a deprecated part, so the code
        # is treated as unknown: held when the running part is only a default.
        rec = Recorder(items={}, running=_running(110, "Default"))
        r = _run(rec)
        self.assertTrue(r.get("Held"))

    def test_empty_part_is_no_match(self):
        rec = Recorder(items={"": {"Id": 1}}, running=_running(110, "Override"))
        _run(rec, "(NET)15.5<UOM>LB<TWM>1<Part>\r")
        self.assertIn("ScaleFlagsPartUnknown", rec.conditions())

    def test_pending_blocks_press(self):
        rec = Recorder(items={"TEST3": {"Id": 110}}, pending={"Id": 9, "NetWeight": 15.5})
        r = _run(rec)
        self.assertEqual(r["Status"], 0)
        self.assertEqual(rec.alarms[-1]["title"], "Tray waiting for its part")
        self.assertEqual((rec.holds, rec.closes, rec.sets), ([], [], []))

    def test_twm_zero_refused(self):
        rec = Recorder(items={"TEST3": {"Id": 110}})
        r = _run(rec, "(NET)15.5<UOM>LB<TWM>0<Part>TEST3")
        self.assertEqual(r["Status"], 0)
        self.assertEqual(rec.alarms[-1]["title"], "Scale did not pass this tray")
        self.assertEqual(rec.closes, [])

    def test_wrong_units_refused(self):
        rec = Recorder(items={"TEST3": {"Id": 110}})
        r = _run(rec, "(NET)7.0<UOM>KG<TWM>1<Part>TEST3")
        self.assertEqual(rec.alarms[-1]["title"], "Scale is in the wrong units")
        self.assertEqual(rec.closes, [])

    def test_lowercase_lb_accepted(self):
        rec = Recorder(items={"TEST3": {"Id": 110}})
        r = _run(rec, "(NET)15.5<UOM>lb<TWM>1<Part>TEST3")
        self.assertEqual(r["Status"], 1)

    def test_mes_mismatch_logs_warning_and_closes(self):
        rec = Recorder(items={"TEST3": {"Id": 110}},
                       judge={"Verdict": "Under", "LowLimit": 16, "HighLimit": 18, "Message": "1.0 lb under"})
        r = _run(rec)
        self.assertEqual(r["Status"], 1)
        self.assertIn("ScaleFlagsMesMismatch", rec.conditions())
        p = rec.payload()
        self.assertEqual((p["mesVerdict"], p["agree"], p["verdict"]), ("Under", False, "Ok"))

    def test_mes_noconfig_agree_none(self):
        rec = Recorder(items={"TEST3": {"Id": 110}}, judge={"Verdict": "NoConfig", "Message": "no target"})
        _run(rec)
        self.assertIsNone(rec.payload()["agree"])
        self.assertIn("ScaleFlagsMesMismatch", rec.conditions())

    def test_close_failure_alarms(self):
        rec = Recorder(items={"TEST3": {"Id": 110}}, closeResult={"Status": 0, "Message": "No stock"})
        r = _run(rec)
        self.assertEqual(r["Status"], 0)
        self.assertEqual(rec.alarms[-1]["message"], "No stock")

    def test_unreadable_message_refused(self):
        rec = Recorder()
        r = _run(rec, None)
        self.assertEqual(r["Status"], 0)
        self.assertEqual(rec.alarms[-1]["title"], "Scale weighment not read")

    def test_unparseable_message_refused(self):
        rec = Recorder()
        _run(rec, "\n\ngarbage\r")
        self.assertEqual(rec.alarms[-1]["title"], "Scale weighment not understood")

    def test_broadcast_on_every_outcome(self):
        for msg in (BENCH, None, "(NET)15.5<UOM>LB<TWM>0<Part>TEST3"):
            rec = Recorder(items={"TEST3": {"Id": 110}})
            _run(rec, msg)
            self.assertEqual(rec.broadcasts, [("scalePressRecorded", {"terminalLocationId": TERM})])

    def test_on_receive_skips_initial_change(self):
        rec = Recorder()
        rec.install(W)
        self.assertIsNone(W.onReceive(PATH, TERM, object(), initialChange=True))
        self.assertEqual(rec.closes, [])


if __name__ == "__main__":
    unittest.main()
