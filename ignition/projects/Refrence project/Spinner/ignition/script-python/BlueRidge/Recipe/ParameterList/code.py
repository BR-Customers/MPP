import inspect

def log(msg):
	"""
	Author: Ronald Pulliam  
	Date: 07/03/2025  
	Local logging wrapper for Recipe.ParameterList.
	
	Args:
		msg (str): Log message
		
	Returns:
		None
	"""
	BlueRidge.Config.Util.logging(__name__, inspect.currentframe().f_back.f_code.co_name, msg)


def getParameterLists():
	"""
	Author: Ronald Pulliam  
	Date: 07/03/2025  
	Runs named query to get all parameter lists.
	
	Returns:
		list[dict]
	"""
	log('running')
	namedQuery = "recipe/getParameterLists"
	results = system.db.execQuery(namedQuery)
	headers = list(results.getColumnNames())
	resp = [dict(zip(headers, row)) for row in results]
	log('resp=%s' % (resp))
	return resp


def getAll(data):
	"""
	Author: Ronald Pulliam  
	Date: 07/03/2025  
	Gets all parameter lists attached to a given engine operation.
	
	Args:
		data (str): engineOperationUUID
		
	Returns:
		list[dict]
	"""
	log('data=%s' % (data))
	parameterLists = getParameterLists()
	resp = []
	for pl in parameterLists:
		if pl.get('engineOperationUUID') == data:
			resp.append({
				"name": pl.get('name'),
				"extensionTypeUUID": pl.get('extensionTypeUUID'),
				"verified": pl.get('validated'),
				"key": pl.get('parameterListUUID'),
				"available": pl.get('active'),
				"engineOperationUUID": pl.get('engineOperationUUID'),
			})
	log('resp=%s' % (resp))
	return resp


def getOne(data):
	"""
	Author: Ronald Pulliam  
	Date: 07/03/2025  
	Returns a single parameter list.
	
	Args:
		data (str): parameterListUUID
		
	Returns:
		dict
	"""
	log('data=%s' % (data))
	parameterLists = getParameterLists()
	resp = {"name": None, "validated": False}
	for pl in parameterLists:
		if pl.get('parameterListUUID') == data:
			resp = pl
			break
	log('resp=%s' % (resp))
	return resp


def add(data):
	"""
	Author: Ronald Pulliam  
	Date: 07/03/2025  
	Adds a new parameter list.
	
	Args:
		data (dict or str)
		
	Returns:
		any
	"""
	log('data=%s' % (data))
	if isinstance(data, str):
		data = system.util.jsonDecode(data)
		
	namedQuery = 'recipe/addParameterList'
	
	params = {
		'parameterListUUID': None,
		'name': 'New Routine',
		'extensionTypeUUID': data.get('typeKey'), #BlueRidge.Recipe.Util.extractQualifiedValues(data.get('typeKey')),
		'engineOperationUUID': data.get('opKey'), #BlueRidge.Recipe.Util.extractQualifiedValues(data.get('opKey')),
		'validated': False,
		'active': False,
		'lastEdited': system.date.now(),
		'lastEditedBy': data.get('user')
	}
	
	resp = system.db.execUpdate(namedQuery, params)
	log('resp=%s' % (resp))
	return resp


def update(data):
	"""
	Author: Ronald Pulliam  
	Date: 07/03/2025  
	Updates a parameter list.
	
	Args:
		data (dict or str)
		
	Returns:
		any
	"""
	log('data=%s' % (data))
	if isinstance(data, str):
		data = system.util.jsonDecode(data)
		
	namedQuery = "recipe/addParameterList"
	
	params = {
		'parameterListUUID': data.get('key'),
		'name': data.get('name'),
		'extensionTypeUUID': data.get('extensionTypeUUID'),
		'engineOperationUUID': data.get('engineOperationUUID'),
		'validated': data.get('verified'),
		'active': data.get('available'),
		'lastEdited': system.date.now(),
		'lastEditedBy': data.get('user')
	}
	
	resp = system.db.execUpdate(namedQuery, params)
	log('resp=%s' % (resp))
	return resp


def archive(data):
	"""
	Author: Ronald Pulliam  
	Date: 07/03/2025  
	Archives (deletes) a parameter list by UUID.
	
	Args:
		data (str or dict)
		
	Returns:
		any
	"""
	log('data=%s' % (data))
	if isinstance(data, str):
		data = system.util.jsonDecode(data)
	UUID = data
	if isinstance(data, dict):
		UUID = data.get('key')
		
	namedQuery = "recipe/deleteParameterList"
	params = {"UUID": UUID}
	resp = system.db.execUpdate(namedQuery, params)
	
#	parametersToDelete = BlueRidge.Recipe.HeadParameter.getAll(UUID)
#	for param in parametersToDelete:
#		BlueRidge.Recipe.HeadParameter.archive(param['key'])
	
	log('resp=%s' % (resp))
	return resp