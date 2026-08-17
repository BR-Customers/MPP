# Paste into the Gateway Script Console. Exercises the real topupTick() against AIM.
# WARNING: this consumes real serials from the configured AIM company code (01 in dev).
# Every run moves AIM's counter forward - do not loop this.

cfg = BlueRidge.Lots.AimPoolConfig.get() or []
print "config: %s" % (cfg[0] if cfg else "UNCONFIGURED")

before = BlueRidge.Lots.AimPool.getDepth() or []
print "depth before: %s" % (before[0] if before else {"Depth": 0})

result = BlueRidge.Lots.AimPoolGateway.topupTick()
print "\ntopupTick() result: %s" % result

after = BlueRidge.Lots.AimPool.getDepth() or []
print "\ndepth after: %s" % (after[0] if after else {"Depth": 0})
