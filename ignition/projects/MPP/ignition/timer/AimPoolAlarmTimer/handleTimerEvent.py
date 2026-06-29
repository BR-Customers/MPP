def handleTimerEvent():
	# Every ~60s: compare AIM pool depth to AimPoolConfig thresholds + fire session alarms
	# on rising-edge warning/critical crossings. Logic lives in Core.
	BlueRidge.Lots.AimPoolGateway.alarmTick()
