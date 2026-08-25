def handleTimerEvent():
	# DEV ONLY - one-shot report render harness. Deleted in Task 8.
	# Enable via resource.json, run scan.ps1, wait one tick, then disable again.
	import os
	out = "C:\\Temp\\report_render"
	if not os.path.isdir(out):
		os.makedirs(out)
	for lotId in (254, 10270, 10274):
		try:
			png = system.report.executeReport("Lot Detail", "MPP", {"LotId": lotId}, "png")
			f = open(os.path.join(out, "lot_detail_%d.png" % lotId), "wb")
			f.write(png)
			f.close()
			system.util.getLogger("DevRenderReport").info("rendered LotId=%d" % lotId)
		except Exception, e:
			system.util.getLogger("DevRenderReport").error(
				"render failed LotId=%d: %s" % (lotId, str(e)))
