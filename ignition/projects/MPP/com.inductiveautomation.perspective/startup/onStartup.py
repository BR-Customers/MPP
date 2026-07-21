def onStartup(session):
	# Resolve the terminal this Perspective session connects from by its client
	# IP, then bind the FULL terminal context (terminal / printer / plcDevices /
	# closure / vision, and clear any stale cell) via the shared
	# BlueRidge.Location.Terminal.applyToSession resolver -- the SAME one the
	# NavigationTree launch and the Terminal Selector use, so all three paths set
	# identical context and can never drift. Read-only; never errors (the proc
	# returns a fallback Terminal row for unregistered IPs).
	ip = session.props.address       # Perspective client IP
	term = BlueRidge.Location.Terminal.getByIpAddress(ip)
	if term is None:
		# Defensive: the proc is designed to always return a fallback row.
		BlueRidge.Location.Terminal.applyToSession(session, {"terminalLocationId": None})
		return
	BlueRidge.Location.Terminal.applyToSession(session, {
		"terminalLocationId": term.get("TerminalLocationId"),
		"terminalCode":       term.get("TerminalCode"),
		"terminalName":       term.get("TerminalName"),
		"zoneLocationId":     term.get("ZoneLocationId"),
		"zoneName":           term.get("ZoneName"),
		"defaultScreen":      term.get("DefaultScreen"),
		"isFallback":         bool(term.get("IsFallback")),
	})
