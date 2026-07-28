# =============================================================================
# Test: BlueRidge.Lots.LabelTransport endpoint grammar
#
# Run in the Designer Script Console (Tools -> Script Console). Paste, execute.
# Prints one line per case; a FAIL line means the grammar is wrong.
#
# Grammar under test (design 2026-07-28 sec 3.1), evaluated in order:
#   1. empty/whitespace          -> invalid
#   2. starts with \\            -> queue (UNC verbatim)
#   3. matches ^(.+):(\d+)$      -> tcp
#   4. anything else             -> queue (local queue name)
#
# The port is MANDATORY for tcp. That is the whole point: it makes a bare
# name unambiguously a queue, where the old code silently guessed hostname.
# =============================================================================
import BlueRidge.Lots.LabelTransport as LT

CASES = [
    # (endpoint,                      expected transport, expected target)
    ("10.20.30.40:9100",              "tcp",   "10.20.30.40:9100"),
    ("zebra-dc1.mpp.local:9100",      "tcp",   "zebra-dc1.mpp.local:9100"),
    ("10.20.30.40:6101",              "tcp",   "10.20.30.40:6101"),
    ("\\\\FLXWAPSRV1\\5A2 Machining", "queue", "\\\\FLXWAPSRV1\\5A2 Machining"),
    ("\\\\887intel\\RPY COMP",        "queue", "\\\\887intel\\RPY COMP"),
    ("Zebra GX420d (RAW)",            "queue", "Zebra GX420d (RAW)"),
    ("printer01",                     "queue", "printer01"),   # bare name = queue, NOT host:9100
    ("  10.20.30.40:9100  ",          "tcp",   "10.20.30.40:9100"),   # trimmed
]

INVALID = ["", "   ", None, ":9100", "10.20.30.40:0", "10.20.30.40:70000"]

failures = 0
for endpoint, wantTransport, wantTarget in CASES:
    d = LT.describeEndpoint(endpoint)
    ok = d["valid"] and d["transport"] == wantTransport and d["target"] == wantTarget
    if not ok:
        failures += 1
    print "%s  %-32r -> %s" % ("PASS" if ok else "FAIL", endpoint, d)

for endpoint in INVALID:
    d = LT.describeEndpoint(endpoint)
    ok = (not d["valid"]) and d["transport"] is None and d["reason"]
    if not ok:
        failures += 1
    print "%s  %-32r -> %s" % ("PASS" if ok else "FAIL", endpoint, d)

# send() on an invalid endpoint must return, never raise.
r = LT.send("", "^XA^XZ")
ok = (r["ok"] is False) and (r["transport"] is None) and r["error"]
if not ok:
    failures += 1
print "%s  send('') returns instead of raising -> %s" % ("PASS" if ok else "FAIL", r)

print "\n%d failure(s)" % failures
