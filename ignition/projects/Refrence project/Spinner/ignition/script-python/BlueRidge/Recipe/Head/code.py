import inspect

def log(msg):
	"""
	Author: Ronald Pulliam  
	Date: 07/03/2025  
	Local project logger that routes to the BlueRidge logger.
	
	Args:
		msg (str): Message to log
		
	Returns:
		None
	"""
	BlueRidge.Config.Util.logging(__name__, inspect.currentframe().f_back.f_code.co_name, msg)


def getHeads():
	"""
	Author: Jennifer Lewis 
	Date: 02/05/2026
	Runs the named query to get all heads.
	
	Returns:
		list[dict]
	"""
	log('running')
	namedQuery = "config/getAllHeadConfigs"
	results = system.db.execQuery(namedQuery)
	headers = list(results.getColumnNames())
	resp = [dict(zip(headers, row)) for row in results]
	log('resp=%s' % (resp))
	return resp


def getAll():
	"""
	Author: Jennifer Lewis 
	Date: 02/05/2026
	Returns a list of heads formatted for dropdown or list components.
	
	Returns:
		list[dict]
	"""
	log('running')
	heads = getHeads()
	resp = []
	for head in heads:
		resp.append({
			"text": head.get('name'),
			"view": head.get('headConfigUUID'),
			"value": "",
			"key": head.get('headConfigUUID'),
			"available": head.get('active'),
		})
	log('resp=%s' % (resp))
	return resp


def getOne(data):
	"""
	Author: Jennifer Lewis 
	Date: 02/05/2026
	Returns a single head record by head UUID.
	
	Args:
		data (str): head UUID
		
	Returns:
		dict
	"""
	log('data=%s' % (data))
	resp = {
		"name": None,
		"available": False,
		"key": None,
		"headGroup": None
	}
	if data or data != 0:
		heads = getHeads()
		for head in heads:
			if head.get('headConfigUUID') == data:
				resp = {
					"name": head.get("name"),
					"available": head.get("active"),
					"key": head.get("headConfigUUID"),
					"headGroup": head.get("headUUID"),
					"type": "Head"
				}
				break
	log('resp=%s' % (resp))
	return resp

#
#def add(data):
#	"""
#	Author: Ronald Pulliam  
#	Date: 07/03/2025  
#	Adds a new engine with default placeholder values.
#	
#	Args:
#		data (dict or str): payload
#		
#	Returns:
#		any
#	"""
#	log('data=%s' % (data))
#	if type(data) == str:
#		data = system.util.jsonDecode(data)
#		
#	namedQuery = "config/addEngine"
#	params = {
#		'engineUUID': None,
#		'plantUUID': None,
#		'name': 'New Engine',
#		'active': False,
#		'lastEdited': system.date.now(),
#		'lastEditedBy': data.get('user')
#	}
#	resp = system.db.execQuery(namedQuery, params)
#	log('resp=%s' % (resp))
#	return resp
#
#
#def archive(data):
#	"""
#	Author: Ronald Pulliam  
#	Date: 07/03/2025  
#	Archives (soft deletes) an engine by UUID.
#	
#	Args:
#		data (dict or str): engine UUID or JSON with key
#		
#	Returns:
#		any
#	"""
#	log('data=%s' % (data))
#	namedQuery = "config/deleteEngine"
#	if type(data) == str:
#		data = system.util.jsonDecode(data)
#		
#	UUID = data
#	if isinstance(data, dict):
#		UUID = data.get('key')
#		
#	params = {'UUID': UUID}
#	resp = system.db.execQuery(namedQuery, params)
#	log('resp=%s' % (resp))
#	return resp
#
#
#def update(data):
#	"""
#	Author: Ronald Pulliam  
#	Date: 07/03/2025  
#	Updates an existing engine.
#	
#	Args:
#		data (dict or str): engine data
#		
#	Returns:
#		any
#	"""
#	log('data=%s' % (data))
#	if type(data) == str:
#		data = system.util.jsonDecode(data)
#		
#	namedQuery = "config/addEngine"
#	params = {
#		'engineUUID': data.get('key'),
#		'plantUUID': data.get('plantUUID'),
#		'name': data.get('name'),
#		'active': data.get('available'),
#		'lastEdited': system.date.now(),
#		'lastEditedBy': data.get('user')
#	}
#	resp = system.db.execQuery(namedQuery, params)
#	log('resp=%s' % (resp))
#	return resp