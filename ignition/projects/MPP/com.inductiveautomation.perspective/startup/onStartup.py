def onStartup(session):
	session.custom.Locations = Location.buildTree(1, expandDepth=2, defaultIcon="material/place")