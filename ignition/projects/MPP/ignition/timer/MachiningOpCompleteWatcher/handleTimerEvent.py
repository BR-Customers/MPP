def handleTimerEvent():
	# Thin dispatcher - per-cell PLC OperationComplete edge logic lives in Core.
	# No-op until BlueRidge.Workorder.MachiningPlc._WATCH is configured at commissioning.
	BlueRidge.Workorder.MachiningPlc.tickWatcher()
