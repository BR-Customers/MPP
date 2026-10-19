"""Harness for BlueRidge.Workorder.ScaleEPrintWatcher -- runs the watcher's
parse() and handleMessage() under plain CPython, with the Ignition modules it
imports (java.lang, system.*) and the BlueRidge entities it calls stubbed.

    python tools/test_scale_eprint_watcher.py

What it proves is the transport half only: what the parser pulls out of a
printed record, what reaches judgeWeight, what lands in the InterfaceLog
payload, and that the scale's flags never change whether a tray closes. The
verdict and the flag comparison are SQL's and are tested in
sql/tests/0008_Parts_Item/029_ContainerConfig_JudgeWeight.sql; here the judge
is a stub that returns whatever row a case gives it.
"""

import os
import sys
import types
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CODE = os.path.join(ROOT, "ignition", "projects", "Core", "ignition",
                    "script-python", "BlueRidge", "Workorder",
                    "ScaleEPrintWatcher", "code.py")


def _stubModules():
    java = types.ModuleType("java")
    java.lang = types.ModuleType("java.lang")
    java.lang.Exception = Exception
    system = types.ModuleType("system")
    for name in ("date", "opc", "tag"):
        mod = types.ModuleType("system." + name)
        setattr(system, name, mod)
        sys.modules["system." + name] = mod
    sys.modules.update({"java": java, "java.lang": java.lang, "system": system})


class Recorder(object):
    """Stands in for every BlueRidge entity the watcher calls, recording each
       call so a case can assert on it."""

    def __init__(self, judgeRow=None, closeResult=None, ctx=None):
        self.logs = []
        self.alarms = []
        self.judgeCalls = []
        self.closes = []
        self.judgeRow = judgeRow
        self.closeResult = closeResult or {"Status": 1, "ContainerId": 77}
        self.ctx = ctx or {"finishedGoodItemId": 110}

    def install(self, module):
        rec = self
        BR = types.SimpleNamespace()
        BR.Workorder = types.SimpleNamespace(
            PlcWatcher=types.SimpleNamespace(
                logInterface=lambda device, description, **kw:
                    rec.logs.append(dict(kw, device=device, description=description)),
                notifyAlarm=lambda terminal, title, message, level="error":
                    rec.alarms.append({"title": title, "message": message, "level": level})),
            Assembly=types.SimpleNamespace(
                resolvePlcCloseContext=lambda terminal, method: rec.ctx,
                plcCompleteTray=lambda terminal, method:
                    rec.closes.append(method) or rec.closeResult))
        BR.Parts = types.SimpleNamespace(
            ContainerConfig=types.SimpleNamespace(judgeWeight=rec._judge))
        BR.Common = types.SimpleNamespace(
            Util=types.SimpleNamespace(log=lambda *a, **k: None))
        module.BlueRidge = BR

    def _judge(self, itemId, method, weight, scaleFlags=None):
        self.judgeCalls.append({"itemId": itemId, "method": method,
                                "weight": weight, "scaleFlags": scaleFlags})
        return dict(self.judgeRow)


def _load():
    _stubModules()
    mod = types.ModuleType("ScaleEPrintWatcher")
    with open(CODE) as f:
        source = f.read()
    exec(compile(source, CODE, "exec"), mod.__dict__)
    return mod


W = _load()

# The Template 1 head (no flags) and the Template 3 head (flags, no trailing
# line break), in the layout the terminal prints them. See the note on
# FIXTURES_VERIFIED below.
T1 = "      35.13 lb \r\n      16.93 lb T \r\n      18.20 lb N \r\n"
T1_CAM = "      35.13 lb \r\n      16.93 lb T \r\n      18.20 lb N \r\nCAM=1"
T3_OK = "      66.0 lb \r\n      16.0 lb T \r\n      50.0 lb N \r\nUNDER: 0 OVER: 0 OK: 1"
T3_UNDER = "      56.0 lb \r\n      49.8 lb T \r\n       6.2 lb N \r\nUNDER: 1 OVER: 0 OK: 0"
T3_ZERO = "      66.0 lb \r\n      16.0 lb T \r\n      50.0 lb N \r\nUNDER: 0 OVER: 0 OK: 0"

# Verified 2026-10-19 on the office scale (B913444851) on Dev. Four real
# Template 3 prints were each 74 bytes (MessageBytes), the exact length of this
# fixed-width layout, and the live watcher parsed a real Message into
# flags=UNDER:0,OVER:0,OK:1 and closed the tray (Audit.InterfaceLog Id 38).
FIXTURES_VERIFIED = True


def _row(verdict="Ok", scale=None, agree=None, flagsMessage=None):
    return {"Verdict": verdict, "Message": "msg for %s" % verdict,
            "LowLimit": 48.0, "HighLimit": 52.0,
            "ScaleVerdict": scale, "FlagsAgree": agree, "FlagsMessage": flagsMessage}


class ParseTests(unittest.TestCase):

    def test_template1_has_no_flags(self):
        p = W.parse(T1)
        self.assertTrue(p["ok"])
        self.assertEqual(p["netText"], "18.20")
        self.assertIsNone(p["flags"])
        self.assertIsNone(p["cam"])

    def test_cam_variant_still_parses(self):
        p = W.parse(T1_CAM)
        self.assertTrue(p["ok"])
        self.assertEqual(p["cam"], 1)
        self.assertIsNone(p["flags"])

    def test_template3_flags_present(self):
        p = W.parse(T3_UNDER)
        self.assertTrue(p["ok"])
        self.assertEqual(p["net"], 6.2)
        self.assertEqual(p["flags"], {"under": 1, "over": 0, "ok": 0})

    def test_template3_all_zero_is_parsed_not_judged(self):
        p = W.parse(T3_ZERO)
        self.assertEqual(p["flags"], {"under": 0, "over": 0, "ok": 0})

    def test_flags_without_trailing_line_break(self):
        self.assertFalse(T3_OK.endswith("\n"))
        self.assertEqual(W.parse(T3_OK)["flags"], {"under": 0, "over": 0, "ok": 1})

    def test_flags_line_with_lf_only_and_extra_spaces(self):
        p = W.parse("50.0 lb N\nUNDER:  0   OVER: 1  OK:0")
        self.assertEqual(p["flags"], {"under": 0, "over": 1, "ok": 0})

    def test_flags_on_the_net_line(self):
        # Malaki's how-to doc showed them there; accepted anywhere.
        p = W.parse("      66.0 lb \r\n      16.0 lb T \r\n      50.0 lb N UNDER: 0 OVER: 0 OK: 1")
        self.assertTrue(p["ok"])
        self.assertEqual(p["netText"], "50.0")
        self.assertEqual(p["flags"], {"under": 0, "over": 0, "ok": 1})
        self.assertEqual(p["flagsState"], "read")

    def _assertUnreadable(self, message):
        p = W.parse(message)
        self.assertTrue(p["ok"], "a flags problem must never refuse the weighment")
        self.assertIsNone(p["flags"])
        self.assertEqual(p["flagsState"], "unreadable")

    def test_value_other_than_0_or_1_is_unreadable(self):
        self._assertUnreadable("50.0 lb N\r\nUNDER: 0 OVER: 0 OK: 2")
        self._assertUnreadable("50.0 lb N\r\nUNDER: 0 OVER: 0 OK: 01")

    def test_more_than_one_flag_set_is_unreadable(self):
        self._assertUnreadable("50.0 lb N\r\nUNDER: 1 OVER: 0 OK: 1")

    def test_partial_flags_line_is_unreadable(self):
        self._assertUnreadable("50.0 lb N\r\nUNDER: OVER: 0")
        self._assertUnreadable("50.0 lb N\r\nUNDER: 1")

    def test_absent_flags_state(self):
        self.assertEqual(W.parse(T1)["flagsState"], "absent")

    def test_still_exactly_one_net_line(self):
        self.assertFalse(W.parse(T3_OK + "\r\n" + T3_OK)["ok"])
        self.assertFalse(W.parse("UNDER: 0 OVER: 0 OK: 1")["ok"])

    def test_two_flags_lines_are_unreadable_not_refused(self):
        self._assertUnreadable("50.0 lb N\r\nUNDER: 0 OVER: 0 OK: 1\r\nUNDER: 1 OVER: 0 OK: 0")


class HandleMessageTests(unittest.TestCase):

    def _run(self, message, row, **kw):
        rec = Recorder(judgeRow=row, **kw)
        rec.install(W)
        result = W.handleMessage("[MPP]PlcDevices/MPP_Scale", 106, message)
        return rec, result

    def test_flags_absent_closes_and_logs_none(self):
        rec, result = self._run(T1, _row("Ok"))
        self.assertEqual(result["Status"], 1)
        self.assertIsNone(rec.judgeCalls[0]["scaleFlags"])
        self.assertEqual(len(rec.logs), 1)
        self.assertIn("flags=None", rec.logs[0]["requestPayload"])
        self.assertIn("scale=None agree=None", rec.logs[0]["requestPayload"])

    def test_flags_present_and_agreeing(self):
        rec, result = self._run(T3_OK, _row("Ok", scale="Ok", agree=True))
        self.assertEqual(result["Status"], 1)
        self.assertEqual(rec.judgeCalls[0]["scaleFlags"], {"under": 0, "over": 0, "ok": 1})
        self.assertEqual([l["description"] for l in rec.logs], ["ByWeight tray close"])
        payload = rec.logs[0]["requestPayload"]
        self.assertIn("flags=UNDER:0,OVER:0,OK:1", payload)
        self.assertIn("scale=Ok agree=True", payload)
        self.assertEqual(rec.alarms, [])

    def test_mismatch_on_an_ok_tray_still_closes_and_warns(self):
        rec, result = self._run(T3_UNDER, _row("Ok", scale="Under", agree=False,
                                               flagsMessage="scale Under, MES Ok"))
        self.assertEqual(result["Status"], 1)
        self.assertEqual(rec.closes, ["ByWeight"])
        self.assertEqual([l["description"] for l in rec.logs],
                         ["Scale flags warning", "ByWeight tray close"])
        warn = rec.logs[0]
        self.assertEqual(warn["errorCondition"], "ScaleFlagsMismatch")
        self.assertEqual(warn["errorDescription"], "scale Under, MES Ok")
        self.assertTrue(warn["ok"])
        self.assertEqual(rec.alarms, [], "a flags mismatch raises no operator toast")

    def test_mismatch_on_a_refused_tray_still_refuses_and_warns(self):
        rec, result = self._run(T3_OK, _row("Over", scale="Ok", agree=False,
                                            flagsMessage="scale Ok, MES Over"))
        self.assertEqual(result["Status"], 0)
        self.assertEqual(rec.closes, [])
        self.assertEqual([l["description"] for l in rec.logs],
                         ["Scale flags warning", "Tray not closed"])
        self.assertIn("flags=UNDER:0,OVER:0,OK:1", rec.logs[1]["requestPayload"])
        self.assertIn("scale=Ok agree=False", rec.logs[1]["requestPayload"])
        # The only toast is the MES refusal itself.
        self.assertEqual(len(rec.alarms), 1)
        self.assertEqual(rec.alarms[0]["level"], "warning")

    def test_all_zero_is_no_target_not_a_mismatch(self):
        rec, result = self._run(T3_ZERO, _row("Ok", scale="NoTarget", agree=None,
                                              flagsMessage="no active target"))
        self.assertEqual(result["Status"], 1)
        self.assertEqual(rec.judgeCalls[0]["scaleFlags"], {"under": 0, "over": 0, "ok": 0})
        self.assertEqual(rec.logs[0]["errorCondition"], "ScaleFlagsNoTarget")
        self.assertEqual(rec.alarms, [])

    def test_unreadable_flags_still_close_and_say_so(self):
        rec, result = self._run(
            "      66.0 lb \r\n      16.0 lb T \r\n      50.0 lb N \r\nUNDER: 1 OVER: 1 OK: 0",
            _row("Ok"))
        self.assertEqual(result["Status"], 1)
        self.assertIsNone(rec.judgeCalls[0]["scaleFlags"])
        self.assertIn("flags=Unreadable", rec.logs[0]["requestPayload"])

    def test_flags_on_a_refusal_before_judging(self):
        rec, result = self._run(T3_OK.replace(" lb", " kg"), _row("Ok"))
        self.assertEqual(result["Status"], 0)
        self.assertEqual(rec.judgeCalls, [])
        self.assertIn("flags=UNDER:0,OVER:0,OK:1", rec.logs[0]["requestPayload"])


if __name__ == "__main__":
    if not FIXTURES_VERIFIED:
        sys.stderr.write("NOTE: Template 3 fixtures are a reconstruction, not "
                         "captured bytes (FIXTURES_VERIFIED = False).\n")
    unittest.main()
