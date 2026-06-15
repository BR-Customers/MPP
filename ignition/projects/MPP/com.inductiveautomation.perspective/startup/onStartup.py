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
			"terminalMode":       "",
			"isFallback":         True,
		}
		return
	session.custom.terminal = {
		"terminalLocationId": term.get("TerminalLocationId"),
		"terminalCode":       term.get("TerminalCode"),
		"terminalName":       term.get("TerminalName"),
		"zoneLocationId":     term.get("ZoneLocationId"),
		"zoneName":           term.get("ZoneName"),
		"defaultScreen":      term.get("DefaultScreen"),
		"terminalMode":       term.get("TerminalMode"),
		"isFallback":         bool(term.get("IsFallback")),
	}
