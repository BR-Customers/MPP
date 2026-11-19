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
    with open(path) as f:
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


if __name__ == "__main__":
    unittest.main()
