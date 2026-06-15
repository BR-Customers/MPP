def handleTimerEvent():
	# Thin dispatcher - singleton shift boundary logic lives in Core.
	# system.date.now() is "approximately now"; the Shift procs only need the
	# current instant to resolve the active schedule.
	BlueRidge.Oee.Shift.tickShiftBoundary(system.date.now())
