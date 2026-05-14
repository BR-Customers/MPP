import inspect

def log(msg):
	"""
	Author: Ronald Pulliam
	Date: 07/03/2025
	Helper for consistent project logging with automatic
	caller function tracing.
	
	Args:
		msg (str): log message
		
	Returns:
		None
	"""
	BlueRidge.Config.Util.logging(__name__, inspect.currentframe().f_back.f_code.co_name, msg)


def getExtensionTypes():
	"""
	Author: Ronald Pulliam
	Date: 07/03/2025
	Runs recipe/getExtensionTypes named query and returns
	the extension types as a list of dictionaries.
	
	Returns:
		list[dict]
	"""
	namedQuery = "recipe/getExtensionTypes"
	results = system.db.execQuery(namedQuery)
	headers = list(results.getColumnNames())
	extensions = [dict(zip(headers, row)) for row in results]
	return extensions


def getAll():
	"""
	Author: Ronald Pulliam
	Date: 07/03/2025
	Returns all extension types formatted for UI selectors.
	
	Returns:
		list[dict]
	"""
	log('running')
	extensions = getExtensionTypes()
	resp = []
	for extension in extensions:
		resp.append({
			"text": extension.get('name', ''),
			"view": extension.get('extensionTypeUUID'),
			"value": "",
			"key": extension.get('extensionTypeUUID'),
			"available": extension.get("active", False),
		})
	log('resp=%s' % (resp))
	return resp


def getOne(data):
	"""
	Author: Ronald Pulliam
	Date: 07/03/2025
	Looks up a single extension type by UUID.
	
	Args:
		data (str): UUID
		
	Returns:
		dict
	"""
	log('data=%s' % (data))
	resp = {
		"name": '',
		"format": '',
		"extension": '',
		"available": False,
		"key": '',
		"type": "extensionType"
	}
	
	if data:
		extensionTypes = getExtensionTypes()
		for extensionType in extensionTypes:
			if str(extensionType.get("extensionTypeUUID")) == str(data):
				resp = {
					"name": extensionType.get("name", ''),
					"format": extensionType.get("programNameFormat"),
					"extension": extensionType.get('extension'),
					"available": extensionType.get("active", False),
					"key": extensionType.get("extensionTypeUUID"),
					"type": "extensionType",
				}
				break
	
	log('resp=%s' % (resp))
	return resp


def add(data):
	"""
	Author: Ronald Pulliam
	Date: 07/03/2025
	Adds or updates an extension type depending on scripttype field.
	
	Args:
		data (dict|str): JSON string or dict
		
	Returns:
		any - result of named query
	"""
	log('data=%s' % (data))
	if isinstance(data, str):
		data = system.util.jsonDecode(data)
	
	if data.get('scripttype') == 'new':
		name = 'New Extension'
		programNameFormat = None
		extension = None
		active = False
		extensionTypeUUID = None
	else:
		name = data.get('name', '')
		programNameFormat = data.get('format')
		extension = data.get('extension')
		active = data.get('available', False)
		extensionTypeUUID = data.get('key')
		
	lastEdited = system.date.now()
	lastEditedBy = data.get('user', '')
	
	params = {
		'name': name,
		'programNameFormat': programNameFormat,
		'extension': extension,
		'extensionTypeUUID': extensionTypeUUID,
		'active': active,
		'lastEdited': lastEdited,
		'lastEditedBy': lastEditedBy
	}
	resp = system.db.execUpdate("recipe/addExtensionType", params)
	log('resp=%s' % (resp))
	return resp


def archive(data):
	"""
	Author: Ronald Pulliam
	Date: 07/03/2025
	Archives (soft deletes) an extension type and cascades
	to delete related parameter defaults.
	
	Args:
		data (str|dict): JSON string, UUID, or dict
		
	Returns:
		any - result of named query
	"""
	log('data=%s' % (data))
#	try:
#		if isinstance(data, str):
#			if "{" in data:
#				data = system.util.jsonDecode(data)
#				UUID = data['key']
#	except:
	UUID = data
	if isinstance(data, dict):
		UUID = data.get('key')
	
	# Cascade delete parameter defaults
	paramDefaults = BlueRidge.Config.ParamDefault.getAll(UUID)
	if paramDefaults:
		for param in paramDefaults:
			BlueRidge.Config.ParamDefault.archive(param.get('key'))
	
	params = {'UUID': UUID}
	resp = system.db.execUpdate("recipe/deleteExtensionType", params)
	log('resp=%s' % (resp))
	return resp


def update(data):
	"""
	Author: Ronald Pulliam
	Date: 07/03/2025
	Updates an extension type by reusing the add() function.
	
	Args:
		data (dict|str): JSON string or dict
		
	Returns:
		any - result of named query
	"""
	log('data=%s' % (data))
	resp = add(data)
	log('resp=%s' % (resp))
	return resp