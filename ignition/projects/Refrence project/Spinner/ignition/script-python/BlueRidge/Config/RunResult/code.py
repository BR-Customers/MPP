import inspect

def log(msg):
	"""
	Author: Ronald Pulliam
	Date: 07/03/2025
	Helper function for consistent project logging with function tracing.

	Args:
		msg (str): Message to log

	Returns:
		None
	"""
	BlueRidge.HMI.CNCLoader.Util.logging(__name__, inspect.currentframe().f_back.f_code.co_name, msg)

def getRunResults():
	"""
	Author: Ronald Pulliam
	Date: 07/03/2025
	Runs process/getRunResults named query and returns a list of engines.
	
	Returns:
		list[dict]
	"""
	namedQuery = "process/getRunResults"
	results = system.db.execQuery(namedQuery)
	headers = list(results.getColumnNames())
	resp = [dict(zip(headers, row)) for row in results]
	return resp

def getAll(data):
	"""
	Author: Ronald Pulliam
	Date: 07/03/2025
	Returns all runResults matching a UUID without formatting.
	
	Returns:
		list[dict]
	"""
	log('data=%s' % (data))
	results = getRunResults()
	resp = []
	for result in results:
		if result.get('reasonUUID') == data:
			resp.append(result)
	log('resp=%s' % (resp))
	return resp


def getOne(data):
	"""
	Author: Ronald Pulliam
	Date: 07/03/2025
	Placeholder for retrieving a single run result. Currently returns an empty string.

	Args:
		data (any): Input data (currently unused)

	Returns:
		str
	"""
	log('data=%s' % (data))
	resp = ''
	log('resp=%s' % (resp))
	return resp


def add(data):
	"""
	Author: Ronald Pulliam
	Date: 07/03/2025
	Adds a new run result using a named query.

	Args:
		data (dict|str): JSON string or dictionary containing run result data

	Returns:
		any - result of named query
	"""
	log('data=%s' % (data))
	if isinstance(data, str):
		data = system.util.jsonDecode(data)
	
	params = {
		'runResultUUID': None,
		'reasonUUID': data.get('reasonUUID'),
		'status': data.get('status', ''),
		'lastEdited': system.date.now(),
		'lastEditedBy': data.get('user', '')
	}
	
	resp = system.db.execQuery("process/addRunResult", params)
	log('resp=%s' % (resp))
	return resp


def update(data):
	"""
	Author: Ronald Pulliam
	Date: 07/03/2025
	Updates an existing run result using the named query process/addRunResult.

	Args:
		data (dict|str): JSON string or dictionary containing run result data

	Returns:
		any - result of named query
	"""
	log('data=%s' % (data))
	if isinstance(data, str):
		data = system.util.jsonDecode(data)
	
	params = {
		'runResultUUID': data.get('runResultUUID'),
		'reasonUUID': data.get('reasonUUID'),
		'status': data.get('status'),
		'lastEdited': system.date.now(),
		'lastEditedBy': data.get('lastEditedBy')
	}
	
	resp = system.db.execQuery("process/addRunResult", params)
	log('resp=%s' % (resp))
	return resp


def archive(data):
	"""
	Author: Ronald Pulliam
	Date: 07/03/2025
	Placeholder for archiving a run result. Currently returns an empty string.

	Args:
		data (any): Input data (currently unused)

	Returns:
		str
	"""
	log('data=%s' % (data))
	resp = ''
	log('resp=%s' % (resp))
	return resp