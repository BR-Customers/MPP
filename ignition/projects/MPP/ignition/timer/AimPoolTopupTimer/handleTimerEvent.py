def handleTimerEvent():
	# Every ~30s: refill the AIM pool per part from AIM GetNextNumber (commissioning).
	# SHIPS DISABLED - enable only after the Script Console gates in AimPostTimer's
	# Tasks 1 and 3 pass on the target Gateway, same reasoning as AimPostTimer:
	# topupTick() calls AimHttp.nextSerial() up to 25 times per tick, and every fetched
	# serial CONSUMES it from AIM's counter whether or not this MES ever pools it - a
	# serial that is fetched but not pooled is lost forever, it cannot be handed back.
	# This timer's "enabled": false is a second, redundant safety net on top of the real
	# gate: AimHttp.nextSerial()/postSerial() also refuse to make any network call while
	# Lots.AimPoolConfig.AimPostingEnabled is 0 (the shipped default). Both the timer AND
	# AimPostingEnabled must be turned on deliberately before this loop can reach AIM.
	# Logic lives in Core.
	BlueRidge.Lots.AimPoolGateway.topupTick()
