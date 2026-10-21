def handleTimerEvent():
	# Every 60s: record super-lot membership for new production the mint resolver
	# already tagged (Lots.ufn_CrtForMint arm 4). SHIPS DISABLED - enable per gateway.
	# The CRT block never depends on this timer; only how soon a new LOT appears in
	# the super-lot's member list. Logic lives in Core; this is dispatch only.
	BlueRidge.Quality.ControlledRun.syncTick()
