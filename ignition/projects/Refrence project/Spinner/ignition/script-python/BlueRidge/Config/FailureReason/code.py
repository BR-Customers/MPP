import inspect

def log(msg):
	"""
	Author: Ronald Pulliam
	Date: 07/03/2025
	Helper function for consistent project logging with caller name.
	
	Args:
		msg (str): log message
		
	Returns:
		None
	"""
	BlueRidge.Config.Util.logging(__name__, inspect.currentframe().f_back.f_code.co_name, msg)


def getFailureReason():
	"""
	Author: Ronald Pulliam
	Date: 07/03/2025
	Fetches failure reasons from the process/getReasons named query.
	
	Returns:
		list[dict]
	"""
	namedQuery = "process/getReasons"
	results = system.db.execQuery(namedQuery)
	headers = list(results.getColumnNames())
	resp = [dict(zip(headers, row)) for row in results]
	return resp


def getAll(engineUUID):
	"""
	Author: Ronald Pulliam
	Date: 07/03/2025
	Returns all failure reasons for a given engine, formatted for table display.
	
	Args:
		engineUUID (str): UUID of the engine
		
	Returns:
		list[dict]
	"""
	log('data=%s' % (engineUUID))
	reasons = getFailureReason()
	resp = []
	for reason in reasons:
		if reason.get('engineUUID') == engineUUID:
			resp.append({
				"Name": reason.get('name', ''),
				"Last Edited By": reason.get('lastEditedBy', ''),
				"Last Edited": reason.get('lastEdited', ''),
				"key": reason.get('reasonUUID', '')
			})
	log('resp=%s' % (resp))
	return resp


def getOne(data):
	"""
	Author: Ronald Pulliam
	Date: 07/03/2025
	Returns details of a single failure reason by UUID.
	
	Args:
		data (str): reason UUID
		
	Returns:
		dict
	"""
	log('data=%s' % (data))
	resp = {}
	reasons = getFailureReason()
	for reason in reasons:
		if str(reason.get('reasonUUID')) == str(data):
			resp = reason
			break
	log('resp=%s' % (resp))
	return resp


def add(data):
	"""
	Author: Ronald Pulliam
	Date: 07/03/2025
	Adds a new failure reason for a given engine.
	
	Args:
		data (dict|str): JSON string or dict with user and engineUUID
		
	Returns:
		any - result of named query
	"""
	log('data=%s' % (data))
	if isinstance(data, str):
		data = system.util.jsonDecode(data)
		
	engineUUID = data.get('engineUUID')
	if not engineUUID:
		engineUUID = getOne(data.get('key')).get('engineUUID')
		
	params = {
		'engineUUID': engineUUID,
		'reasonUUID': None,
		'name': 'New Reason',
		'lastEdited': system.date.now(),
		'lastEditedBy': data.get('user', '')
	}
	resp = system.db.execUpdate("process/addReason", params)
	log('resp=%s' % (resp))
	return resp


def update(data):
	"""
	Author: Ronald Pulliam
	Date: 07/03/2025
	Updates an existing failure reason.
	
	Args:
		data (dict|str): JSON string or dict
		
	Returns:
		any - result of named query
	"""
	log('data=%s' % (data))
	if isinstance(data, str):
		data = system.util.jsonDecode(data)
		
	existing = getOne(data.get('key'))
	engineUUID = existing.get('engineUUID', '')
	
	params = {
		'engineUUID': engineUUID,
		'reasonUUID': data.get('key', ''),
		'name': data.get('Name', ''),
		'lastEdited': system.date.now(),
		'lastEditedBy': data.get('user', '')
	}
	resp = system.db.execUpdate("process/addReason", params)
	log('resp=%s' % (resp))
	return resp


def archive(data):
	"""
	Author: Ronald Pulliam
	Date: 07/03/2025
	Archives (deletes) a failure reason by UUID and unlinks all associated RunResults.
	
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
	
	# Find and unlink any RunResults using this reason
	runResults = BlueRidge.Config.RunResult.getAll(UUID)
	for result in runResults:
		data = {
			'runResultUUID': result.get('runResultUUID'),
			'reasonUUID': None,
			'status': result.get('status'),
			'lastEdited': system.date.now(),
			'lastEditedBy': result.get('lastEditedBy')
		}
		log("Unlinking RunResult %s" % data['runResultUUID'])
		BlueRidge.Config.RunResult.update(data)
	
	params = {'UUID': UUID}
	resp = system.db.execQuery("process/deleteReason", params)
	log('resp=%s' % (resp))
	return resp