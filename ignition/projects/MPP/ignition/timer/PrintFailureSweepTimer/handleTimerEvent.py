def handleTimerEvent():
	# Every ~5 min: re-dispatch stranded shipping labels + mark/alarm. SIM skeleton in dev
	# (read + mark procs deferred). Logic lives in Core.
	BlueRidge.Lots.PrintFailureGateway.sweepTick()
