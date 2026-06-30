def handleTimerEvent():
	# Thin dispatcher - per-line MIP/OPC edge logic lives in Core.
	# No-op until BlueRidge.Workorder.AssemblyPlc._WATCH is configured at commissioning.
	BlueRidge.Workorder.AssemblyPlc.tickWatcher()
