def handleTimerEvent():
	# Thin dispatcher - slides the monthly partition window once a day.
	# system.date.now() is "approximately now"; the proc treats it as UTC and
	# only needs the current month to compute the sliding window.
	BlueRidge.Audit.Partition.maintain(system.date.now())
