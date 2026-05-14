import inspect

def getParameterLists():
	"""
	Author: Ronald Pulliam
	Date: 07/07/2025
	Retrieves all parameter list entries from the database.

	Returns:
		(list[dict]) - List of parameter list records
	"""
	namedQuery = "recipe/getParameterLists"
	results = system.db.execQuery(namedQuery)
	headers = list(results.getColumnNames())
	resp = [dict(zip(headers, row)) for row in results]
	return resp

def getAll(data):
	"""
	Author: Ronald Pulliam
	Date: 07/07/2025
	Filters parameter lists by engineOperationUUID and returns formatted records.

	Args:
		data (str): engineOperationUUID

	Returns:
		(list[dict]) - Filtered parameter lists
	"""
	BlueRidge.HMI.CNCLoader.Util.logging(__name__, inspect.currentframe().f_code.co_name, 'data=%s' % (data))
	parameterLists = getParameterLists()
	resp = []
	for parameterList in parameterLists:
		if parameterList.get('engineOperationUUID') == data:
			resp.append({
				"name": parameterList.get('name'),
				"extensionTypeUUID": parameterList.get('extensionTypeUUID'),
				"verified": parameterList.get('validated'),
				"key": parameterList.get('parameterListUUID'),
				"available": parameterList.get('active'),
				"engineOperationUUID": parameterList.get('engineOperationUUID'),
			})
	BlueRidge.HMI.CNCLoader.Util.logging(__name__, inspect.currentframe().f_code.co_name, 'resp=%s' % (resp))
	return resp

def getOne(data):
	"""
	Author: Ronald Pulliam
	Date: 07/07/2025
	Gets a single parameter list record by its UUID.

	Args:
		data (str): parameterListUUID

	Returns:
		(dict) - Parameter list record
	"""
	BlueRidge.HMI.CNCLoader.Util.logging(__name__, inspect.currentframe().f_code.co_name, 'data=%s' % (data))
	parameterLists = getParameterLists()
	resp = {}
	for parameterList in parameterLists:
		if parameterList.get('parameterListUUID') == data:
			resp = parameterList
	BlueRidge.HMI.CNCLoader.Util.logging(__name__, inspect.currentframe().f_code.co_name, 'resp=%s' % (resp))
	return resp

def add(data):
	"""
	Author: Ronald Pulliam
	Date: 07/07/2025
	Adds a new parameter list to the database.

	Args:
		data (dict | str): Dictionary with typeKey, opKey, and user

	Returns:
		(dataset) - Result of the named query execution
	"""
	BlueRidge.HMI.CNCLoader.Util.logging(__name__, inspect.currentframe().f_code.co_name, 'data=%s' % (data))
	namedQuery = 'recipe/addParameterList'
	if isinstance(data, str):
		data = system.util.jsonDecode(data)

	params = {
		'parameterListUUID': None,
		'name': 'New Routine',
		'extensionTypeUUID': BlueRidge.Recipe.Util.extractQualifiedValues(data.get('typeKey')),
		'engineOperationUUID': BlueRidge.Recipe.Util.extractQualifiedValues(data.get('opKey')),
		'validated': False,
		'active': False,
		'lastEdited': system.date.now(),
		'lastEditedBy': data.get('user')
	}
	resp = system.db.execQuery(namedQuery, params)
	BlueRidge.HMI.CNCLoader.Util.logging(__name__, inspect.currentframe().f_code.co_name, 'resp=%s' % (resp))
	return resp

def update(data):
	"""
	Author: Ronald Pulliam
	Date: 07/07/2025
	Updates an existing parameter list in the database.

	Args:
		data (dict | str): Dictionary with parameter list details

	Returns:
		(dataset) - Result of the named query execution
	"""
	BlueRidge.HMI.CNCLoader.Util.logging(__name__, inspect.currentframe().f_code.co_name, 'data=%s' % (data))
	namedQuery = "recipe/addParameterList"
	if isinstance(data, str):
		data = system.util.jsonDecode(data)

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
	resp = system.db.execQuery(namedQuery, params)
	BlueRidge.HMI.CNCLoader.Util.logging(__name__, inspect.currentframe().f_code.co_name, 'resp=%s' % (resp))
	return resp

def archive(data):
	"""
	Author: Ronald Pulliam
	Date: 07/07/2025
	Archives (deletes) a parameter list by UUID.

	Args:
		data (dict | str): Dictionary or string UUID

	Returns:
		(dataset) - Result of the named query execution
	"""
	BlueRidge.HMI.CNCLoader.Util.logging(__name__, inspect.currentframe().f_code.co_name, 'data=%s' % (data))
	namedQuery = "recipe/deleteParameterList"
	if isinstance(data, str):
		data = system.util.jsonDecode(data)
	UUID = data if not isinstance(data, dict) else data.get('key')
	params = {'UUID': UUID}
	resp = system.db.execQuery(namedQuery, params)
	BlueRidge.HMI.CNCLoader.Util.logging(__name__, inspect.currentframe().f_code.co_name, 'resp=%s' % (resp))
	return resp