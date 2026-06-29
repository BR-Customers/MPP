def handleTimerEvent():
	# Thin dispatcher - per-machine PLC stop/run edge logic lives in Core.
	# No-op until BlueRidge.Oee.DowntimePlc._WATCH is configured at commissioning.
	BlueRidge.Oee.DowntimePlc.tickWatcher()
