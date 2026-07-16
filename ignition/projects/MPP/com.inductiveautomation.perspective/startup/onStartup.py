def onStartup(session):
	# Resolve the terminal this Perspective session is connecting from by its
	# client IP, and stash terminal/zone/default-screen context for the Home
	# Router + per-screen context. Read-only; never errors (the proc returns a
	# fallback Terminal row for unregistered IPs). No DB mutation, no audit.
	ip = session.props.address       # Perspective client IP
	term = BlueRidge.Location.Terminal.getByIpAddress(ip)
	if term is None:
		# Defensive: proc is designed to always return a fallback row, but guard.
		session.custom.terminal = {
			"terminalLocationId": None,
			"terminalCode":       "",
			"terminalName":       "",
			"zoneLocationId":     None,
			"zoneName":           "",
			"defaultScreen":      "",
			"isFallback":         True,
		}
		session.custom.printer = {"locationId": None, "code": "", "endpoint": "", "model": ""}
		session.custom.plcDevices = []
		return
	session.custom.terminal = {
		"terminalLocationId": term.get("TerminalLocationId"),
		"terminalCode":       term.get("TerminalCode"),
		"terminalName":       term.get("TerminalName"),
		"zoneLocationId":     term.get("ZoneLocationId"),
		"zoneName":           term.get("ZoneName"),
		"defaultScreen":      term.get("DefaultScreen"),
		"isFallback":         bool(term.get("IsFallback")),
	}
	# Arc 2 Phase 4: resolve the terminal's child Printer into session.custom.printer
	# (one DB round-trip per session; the LTT dispatch path reads it). Empty dict
	# when the terminal has no Printer child (HasPrinter false / FALLBACK terminal).
	prn = BlueRidge.Location.Terminal.getPrinter(term.get("TerminalLocationId")) or {}
	session.custom.printer = {
		"locationId": prn.get("locationId"),
		"code":       prn.get("code") or "",
		"endpoint":   prn.get("endpoint") or "",
		"model":      prn.get("model") or "",
	}
	# Plan 3: resolve this terminal's PLC UDT-instance mappings for the gateway
	# watchers + PLC screens (empty list when the terminal drives no devices).
	session.custom.plcDevices = BlueRidge.Location.TerminalPlcDevice.getByTerminal(term.get("TerminalLocationId")) or []
