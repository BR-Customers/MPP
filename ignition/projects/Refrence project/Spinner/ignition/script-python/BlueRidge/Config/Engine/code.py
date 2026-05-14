import inspect

def log(msg):
	"""
	Author: Ronald Pulliam
	Date: 07/03/2025
	Helper function for consistent project logging with function tracing.
	
	Args:
		msg (str): message to log
		
	Returns:
		None
	"""
	BlueRidge.Config.Util.logging(__name__, inspect.currentframe().f_back.f_code.co_name, msg)


def getEngines():
	"""
	Author: Ronald Pulliam
	Date: 07/03/2025
	Runs config/getEngines named query and returns a list of engines.
	
	Returns:
		list[dict]
	"""
	namedQuery = "config/getEngines"
	results = system.db.execQuery(namedQuery)
	headers = list(results.getColumnNames())
	resp = [dict(zip(headers, row)) for row in results]
	return resp


def getAll():
	"""
	Author: Ronald Pulliam
	Date: 07/03/2025
	Returns all engines formatted for UI selectors.
	
	Returns:
		list[dict]
	"""
	log('running')
	engines = getEngines()
	resp = []
	for engine in engines:
		resp.append({
			"text": engine.get('name', ''),
			"view": engine.get('engineUUID', ''),
			"value": "",
			"key": engine.get('engineUUID', ''),
			"available": engine.get('active', False),
		})
	log('resp=%s' % (resp))
	return resp


def getOne(data):
	"""
	Author: Ronald Pulliam
	Date: 07/03/2025
	Looks up a single engine by UUID and returns details.
	
	Args:
		data (str): UUID
		
	Returns:
		dict
	"""
	log('data=%s' % (data))
	resp = {
		"name": '',
		"available": False,
		"key": '',
		"blockConfig": '',
	}
	
	if data:
		engines = getEngines()
		for engine in engines:
			if str(engine.get('engineUUID')) == str(data):
				resp = {
					"name": engine.get("name", ''),
					"available": engine.get("active", False),
					"key": engine.get("engineUUID", ''),
					"blockConfig": engine.get("blockConfig", ''),
				}
				break
	
	log('resp=%s' % (resp))
	return resp


def add(data):
	"""
	Author: Ronald Pulliam
	Date: 07/03/2025
	Adds a new engine with placeholder values.
	
	Args:
		data (dict|str): JSON string or dict containing user
		
	Returns:
		any - result of named query
	"""
	log('data=%s' % (data))
	if isinstance(data, str):
		data = system.util.jsonDecode(data)
		
	params = {
		'engineUUID': None,
		'plantUUID': None,
		'name': 'New Engine',
		'active': False,
		'lastEdited': system.date.now(),
		'lastEditedBy': data.get('user', ''),
		'blockConfig': None
	}
	resp = system.db.execQuery("config/addEngine", params)
	log('resp=%s' % (resp))
	return resp


def archive(data):
	"""
	Author: Ronald Pulliam
	Date: 07/03/2025
	Archives (soft deletes) an engine and its related failure reasons.
	
	Args:
		data (str|dict): JSON string, UUID, or dict
		
	Returns:
		any - result of named query
	"""
	log('data=%s' % (data))
	if isinstance(data, str):
		data = system.util.jsonDecode(data)
	UUID = data
	if isinstance(data, dict):
		UUID = data.get('key')
		
	# Archive related failure reasons
	failureReasons = BlueRidge.Config.FailureReason.getAll(UUID)
	if failureReasons:
		for reason in failureReasons:
			BlueRidge.Config.FailureReason.archive(reason.get('key'))
	
	params = {'UUID': UUID}
	resp = system.db.execQuery("config/deleteEngine", params)
	log('resp=%s' % (resp))
	return resp


def update(data):
	"""
	Author: Ronald Pulliam
	Date: 07/03/2025
	Updates an existing engine.
	
	Args:
		data (dict|str): JSON string or dict
		
	Returns:
		any - result of named query
	"""
	log('data=%s' % (data))
	if isinstance(data, str):
		data = system.util.jsonDecode(data)
		
	params = {
		'engineUUID': data.get('key', ''),
		'plantUUID': data.get('plantUUID'),
		'name': data.get('name', ''),
		'active': data.get('available', False),
		'lastEdited': system.date.now(),
		'lastEditedBy': data.get('user', ''),
		'blockConfig': data.get('blockConfig', '')
	}
	resp = system.db.execQuery("config/addEngine", params)
	log('resp=%s' % (resp))
	return resp