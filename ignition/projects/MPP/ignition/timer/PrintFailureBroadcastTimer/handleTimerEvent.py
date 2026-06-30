def handleTimerEvent():
	# Every ~5s: broadcast 'print-failure-alert' to sessions for unacknowledged failed
	# prints. SIM skeleton in dev (read deferred). Logic lives in Core.
	BlueRidge.Lots.PrintFailureGateway.broadcastTick()
