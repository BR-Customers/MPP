def handleTimerEvent():
	# Every ~30s: refill the AIM pool per part from AIM GetNextNumber (commissioning).
	# SIM no-op in dev (the 028 seed pre-fills the pool). Logic lives in Core.
	BlueRidge.Lots.AimPoolGateway.topupTick()
