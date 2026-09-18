def handleTimerEvent():
	# Thin dispatcher - slides the monthly partition window once a day.
	# system.date.now() is "approximately now"; the proc treats it as UTC and
	# only needs the current month to compute the sliding window. Gateway scope has
	# no session, so the change is attributed to the SYS user.
	BlueRidge.Audit.Partition.maintain(system.date.now(), appUserId=BlueRidge.Common.Util.systemAppUserId())
