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
	if session.custom.activeCategory == category:
		session.custom.activeCategory = ''
		system.perspective.closeDock('navPanel')
		system.perspective.navigate(landingPath)
	else:
		session.custom.activeCategory = category
		system.perspective.openDock('navPanel')
		system.perspective.navigate(firstScreenPath)
