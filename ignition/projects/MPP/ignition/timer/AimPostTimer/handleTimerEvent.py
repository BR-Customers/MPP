def handleTimerEvent():
	# Every 60s: post any container completions still owed to AIM.
	# SHIPS DISABLED - enable only after the Script Console gates in Tasks 1 and 3 pass
	# on the target Gateway. Logic lives in Core; this is dispatch only.
	BlueRidge.Lots.AimPost.retryTick()
