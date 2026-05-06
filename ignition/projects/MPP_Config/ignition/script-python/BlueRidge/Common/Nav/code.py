def toggleCategory(session, category, firstScreenPath, landingPath='/'):
	"""
	Author: Hunter Kraft
	Date: 2026-05-06
	Toggle a rail-category open/closed and navigate accordingly.

	If the same category is already active, collapses the nav-panel
	dock and navigates to the landing page. Otherwise sets the
	category as active, opens the nav-panel dock, and navigates to
	that category's first screen.

	Args:
		session: self.session from a Perspective component event handler.
		category (str): Category id ('plant', 'parts', 'quality', 'operations', 'system').
		firstScreenPath (str): Path to navigate to when opening this category.
		landingPath (str): Path when collapsing. Defaults to '/'.

	Returns:
		None
	"""
	logger = system.util.getLogger('BlueRidge.Common.Nav')
	currentCategory = session.custom.activeCategory or ''
	logger.info("toggleCategory called: clicked=%s, current=%s" % (category, currentCategory))

	# Resolve session + page ids explicitly so dock and navigate calls don't
	# silently lose context when invoked from a project-script frame.
	sessionId = None
	pageId = None
	try:
		info = system.perspective.getSessionInfo()
		if info:
			sessionId = info[0].get('session')
			pageId = info[0].get('pageId') or info[0].get('page')
	except:
		logger.exception("getSessionInfo failed; falling back to implicit context")

	try:
		if currentCategory == category:
			# Same category clicked twice — close the panel and go home.
			system.perspective.setSessionProps({'custom.activeCategory': ''}, sessionId=sessionId)
			system.perspective.closeDock('navPanel', sessionId=sessionId, pageId=pageId)
			system.perspective.navigate(landingPath, sessionId=sessionId, pageId=pageId)
			logger.info("closed navPanel; navigated to %s" % landingPath)
		else:
			# Different (or no) category active — open panel for this one and navigate.
			system.perspective.setSessionProps({'custom.activeCategory': category}, sessionId=sessionId)
			system.perspective.openDock('navPanel', sessionId=sessionId, pageId=pageId)
			system.perspective.navigate(firstScreenPath, sessionId=sessionId, pageId=pageId)
			logger.info("opened navPanel for %s; navigated to %s" % (category, firstScreenPath))
	except:
		logger.exception("toggleCategory action failed")
		raise
