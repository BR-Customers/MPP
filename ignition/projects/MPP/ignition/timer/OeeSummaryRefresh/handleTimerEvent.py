def handleTimerEvent():
	# Thin dispatcher - every 15 minutes, recompute the stored OEE figures of any
	# closed shift whose inputs changed (OEE dashboard spec 6.8). All rules are in
	# Oee.ShiftSummary_RefreshChanged. Gateway scope has no session, so it runs
	# as the SYS user. Committed DISABLED: enabling it is a deployment step.
	BlueRidge.Oee.Summary.refreshChanged(BlueRidge.Common.Util.systemAppUserId())
