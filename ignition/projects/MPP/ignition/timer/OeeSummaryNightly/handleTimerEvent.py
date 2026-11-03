def handleTimerEvent():
	# Thin dispatcher - once a day, rebuild the last 7 days of stored OEE figures:
	# the safety net behind the 15-minute change detection (OEE dashboard spec
	# 6.8). Runs as the SYS user. Committed DISABLED: enabling it is a deployment step.
	BlueRidge.Oee.Summary.nightly(BlueRidge.Common.Util.systemAppUserId())
