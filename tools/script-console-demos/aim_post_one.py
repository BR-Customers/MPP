# Paste into the Gateway Script Console. Exercises postOne against real owed rows.
# Consumes nothing by itself - it only posts rows the MES already owes AIM.

owed = BlueRidge.Lots.AimPool.listUnposted(10) or []
print "owed rows: %d" % len(owed)
for r in owed:
    print "  %s  part=%r qty=%s lot=%s attempts=%s age=%smin err=%r" % (
        r.get("AimShipperId"), r.get("CustomerPartNumber"), r.get("Quantity"),
        r.get("LotNumber"), r.get("PostAttempts"), r.get("AgeMinutes"),
        r.get("LastPostError"))

if owed:
    s = owed[0].get("AimShipperId")
    print "\nposting %s ..." % s
    print "  %s" % BlueRidge.Lots.AimPost.postOne(s)
    print "\nre-posting the SAME serial (expect outcome=already_posted, no AIM call):"
    print "  %s" % BlueRidge.Lots.AimPost.postOne(s)
else:
    print "nothing owed - complete a container first, or seed a row."
