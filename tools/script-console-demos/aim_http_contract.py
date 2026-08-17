# Paste into the Gateway Script Console. Proves the AimHttp contract end to end.
# SAFE: nextserial consumes ONE serial from the configured company's sequence.
# Company 01 is test. NEVER run this against company 99 (production).

print "=== 1. config ==="
base, company, token = BlueRidge.Lots.AimHttp._config()
print "   base=%s company=%s token=%s" % (base, company, token)
assert company != "99", "REFUSING to run against production company 99"

print "=== 2. query encoding (no live call) ==="
q = BlueRidge.Lots.AimHttp._buildPostQuery("000000024", "112006FB A000", 15, "LOTX")
print "   %s" % q
expected = "%5Cr%5Cn000000024%5Ct112006FB%20A000%5Ct15%5CtLOTX%5Cr%5Cn"
assert q == expected, "ENCODING WRONG\n  got: %s\n  exp: %s" % (q, expected)
print "   OK - backslashes are %5C, space is %20, no double-encoding"

print "=== 3. live nextSerial (consumes one serial) ==="
r = BlueRidge.Lots.AimHttp.nextSerial()
print "   %s" % r
assert r["ok"], "nextSerial failed: %s" % r["error"]
serial = r["serial"]

print "=== 4. live postSerial with a REAL customer part ==="
# Replace with a customer part that has an active blanket in the test company.
# Orders -> Order Entry -> Order Edit Lists -> Blanket Detail Summary by Customer Part
part = "112006FB A000"
r2 = BlueRidge.Lots.AimHttp.postSerial(serial, part, 15, serial)
print "   %s" % r2
if r2["ok"]:
    print "   PASS - AIM built the label. Verify on Unshipped Labels report."
else:
    print "   FAIL - %s" % r2["error"]
    print "   If the error starts 'AIM rejected: POST ' the query was not routed"
    print "   (double-encoding). If it says 'Blanket not found' the part has no"
    print "   active blanket - that is DATA, not transport."
