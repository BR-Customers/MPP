import inspect

def log(msg):
	"""
	Author: Ronald Pulliam  
	Date: 07/03/2025  
	Local logging helper for consistent project logging.
	
	Args:
		msg (str): Message to log
		
	Returns:
		None
	"""
	BlueRidge.Config.Util.logging(__name__, inspect.currentframe().f_back.f_code.co_name, msg)


def getExtensionTypes():
	"""
	Author: Ronald Pulliam  
	Date: 07/03/2025  
	Fetches all active extension types from the named query.
	
	Returns:
		list[dict]
	"""
	log('running')
	namedQuery = "recipe/getExtensionTypes"
	results = system.db.execQuery(namedQuery)
	headers = list(results.getColumnNames())
	resp = [dict(zip(headers, row)) for row in results if row[headers.index('active')]]
	log('resp=%s' % (resp))
	return resp


def getAll():
	"""
	Author: Ronald Pulliam  
	Date: 07/03/2025  
	Returns a list of extension types formatted for dropdown components.
	
	Returns:
		list[dict]
	"""
	log('running')
	extensions = getExtensionTypes()
	resp = []
	for ext in extensions:
		resp.append({
			"text": ext.get('name'),
			"view": ext.get('extensionTypeUUID'),
			"value": "",
			"key": ext.get('extensionTypeUUID'),
		})
	log('resp=%s' % (resp))
	return resp


def getOne(data):
	"""
	Author: Ronald Pulliam  
	Date: 07/03/2025  
	Returns a single extension type record by UUID.
	
	Args:
		data (str): extensionTypeUUID
		
	Returns:
		dict
	"""
	log('data=%s' % (data))
	resp = {
		"name": None,
		"format": None,
		"extension": None,
		"available": False,
		"key": None,
		"type": "extensionType"
	}
	if data:
		extensions = getExtensionTypes()
		for ext in extensions:
			if str(ext.get("extensionTypeUUID")) == str(data):
				resp = {
					"name": ext.get("name"),
					"format": ext.get("programNameFormat"),
					"extension": ext.get("extension"),
					"available": ext.get("active"),
					"key": ext.get("extensionTypeUUID"),
					"type": "extensionType"
				}
				break
	log('resp=%s' % (resp))
	return resp


def add(data):
	"""
	Author: Ronald Pulliam  
	Date: 07/03/2025  
	Adds or updates an extension type.
	
	Args:
		data (dict or str): payload
		
	Returns:
		any
	"""
	log('data=%s' % (data))
	if isinstance(data, str):
		data = system.util.jsonDecode(data)
		
	namedQuery = "recipe/addExtensionType"
	scripttype = data.get('scripttype')
	
	if scripttype == 'new':
		name = "New Extension"
		programNameFormat = None
		extension = None
		active = False
		extensionTypeUUID = None
	else:
		name = data.get('name')
		programNameFormat = data.get('format')
		extension = data.get('extension')
		active = data.get('available')
		extensionTypeUUID = data.get('key')
		
	params = {
		'name': name,
		'programNameFormat': programNameFormat,
		'extension': extension,
		'extensionTypeUUID': extensionTypeUUID,
		'active': active,
		'lastEdited': system.date.now(),
		'lastEditedBy': data.get('user')
	}
	
	resp = system.db.execQuery(namedQuery, params)
	log('resp=%s' % (resp))
	return resp


def archive(data):
	"""
	Author: Ronald Pulliam  
	Date: 07/03/2025  
	Archives (soft deletes) an extension type by UUID.
	
	Args:
		data (str or dict): extensionTypeUUID or dict with 'key'
		
	Returns:
		any
	"""
	log('data=%s' % (data))
	if isinstance(data, str):
		data = system.util.jsonDecode(data)
		
	UUID = data
	if isinstance(data, dict):
		UUID = data.get('key')
		
	namedQuery = "recipe/deleteExtensionType"
	params = {'UUID': UUID}
	resp = system.db.execQuery(namedQuery, params)
	log('resp=%s' % (resp))
	return resp


def update(data):
	"""
	Author: Ronald Pulliam  
	Date: 07/03/2025  
	Updates an extension type (routes to add).
	
	Args:
		data (dict or str): extension type data
		
	Returns:
		any
	"""
	log('data=%s' % (data))
	resp = add(data)
	log('resp=%s' % (resp))
	return resp