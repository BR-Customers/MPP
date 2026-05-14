import inspect
from com.inductiveautomation.ignition.common import TypeUtilities
from com.inductiveautomation.ignition.common.model.values import QualifiedValue

def logging(script, function, message):
	"""
	Author: Ronald Pulliam  
	Date: 07/03/2025  
	Generic logging function for consistent log statements.
	
	Args:
		script (str): the script path (usually __name__)  
		function (str): the function name (use inspect)  
		message (str): message to log
	
	Returns:
		str: "success"
	"""
	logger = system.util.getLogger(script)
	logger.info("%s() %s" % (function, message))
	return 'success'


def getFileFormats():
	"""
	Author: Ronald Pulliam  
	Date: 07/03/2025  
	Provides a list of file formats for dropdown selection.
	
	Returns:
		list[dict]: list of format options
	"""
	logging(__name__, inspect.currentframe().f_code.co_name, 'running')
	formats = [
		{"value": 0, "label": "None"},
		{"value": 1, "label": "##.****"},
		{"value": 2, "label": "###.****"},
		{"value": 3, "label": "####.****"},
	]
	logging(__name__, inspect.currentframe().f_code.co_name, 'resp=%s' % (formats))
	return formats


def getBlockConfigs():
	"""
	Author: Ronald Pulliam  
	Date: 07/03/2025  
	Retrieves block configurations for dropdown components.
	
	Returns:
		list[dict]: block configurations
	"""
	logging(__name__, inspect.currentframe().f_code.co_name, 'running')
	data = BlueRidge.Config.BlockConfig.getAll()
	resp = [{'value': d.get('key'), 'label': d.get('text')} for d in data]
	logging(__name__, inspect.currentframe().f_code.co_name, 'resp=%s' % (resp))
	return resp


def getOperationTypes():
	"""
	Author: Ronald Pulliam  
	Date: 07/03/2025  
	Retrieves active operation types for dropdown components.
	
	Returns:
		list[dict]: operation types
	"""
	logging(__name__, inspect.currentframe().f_code.co_name, 'running')
	data = BlueRidge.Config.OperationType.getAll()
	data = [d for d in data if d.get('available')]
	resp = [{'value': d.get('key'), 'label': d.get('text')} for d in data]
	logging(__name__, inspect.currentframe().f_code.co_name, 'resp=%s' % (resp))
	return resp


def getOperationEngines():
	"""
	Author: Ronald Pulliam  
	Date: 07/03/2025  
	Retrieves available engines for an operation.
	
	Returns:
		list[dict]: list of engines
	"""
	logging(__name__, inspect.currentframe().f_code.co_name, 'running')
	data = BlueRidge.Config.Engine.getAll()
	resp = [{'value': d.get('key'), 'label': d.get('text')} for d in data]
	logging(__name__, inspect.currentframe().f_code.co_name, 'resp=%s' % (resp))
	return resp


def getSelectionScreens():
	"""
	Author: Ronald Pulliam  
	Date: 07/03/2025  
	Returns available selection screens.
	
	Returns:
		list[dict]: selection screen options
	"""
	logging(__name__, inspect.currentframe().f_code.co_name, 'running')
	resp = [
		{"value": 0, "label": "None"},
		{"value": 1, "label": "1st"},
		{"value": 2, "label": "2nd"},
		{"value": 3, "label": "3rd"},
	]
	logging(__name__, inspect.currentframe().f_code.co_name, 'resp=%s' % (resp))
	return resp


def getAvailableEngines(data):
	"""
	Author: Ronald Pulliam  
	Date: 07/03/2025  
	Returns a filtered list of engines not yet associated with an operation.
	
	Args:
		data (str): UUID of the operation
	
	Returns:
		list[dict]: available engines
	"""
	logging(__name__, inspect.currentframe().f_code.co_name, 'data=%s' % (data))
	operationUUID = data
	operationEngines = BlueRidge.Recipe.OperationEngine.getOperationEngines()
	usedOperationEngines = [oe for oe in operationEngines if oe.get('operationUUID') == operationUUID]
	usedKeys = [oe.get('engineUUID') for oe in usedOperationEngines]
	
	allEngines = BlueRidge.Recipe.Engine.getAll()
	availableEngines = [e for e in allEngines if e.get('key') not in usedKeys]
	availableEngines = [a for a in availableEngines if a.get('available')]
	logging(__name__, inspect.currentframe().f_code.co_name, 'resp=%s' % (availableEngines))
	return availableEngines


def extractQualifiedValues(data):
	"""
	Author: Ben Furlani  
	Date: 05/13/2025  
	Recursively extracts the `.value` portion of a QualifiedValue, handling lists, dicts, or nested structures.
	
	Args:
		data (any): input data to parse
	
	Returns:
		(any): data with QualifiedValues replaced by raw values
	"""
	if isinstance(data, QualifiedValue):
		return data.getValue()
	elif isinstance(data, list):
		return [extractQualifiedValues(item) for item in data]
	elif isinstance(data, tuple):
		return tuple(extractQualifiedValues(item) for item in data)
	elif isinstance(data, dict):
		return {key: extractQualifiedValues(value) for key, value in data.items()}
	else:
		return data


def convertWrapperObjectToJson(object):
	"""
	Author: Ben Furlani  
	Date: 05/13/2025 
	Converts a Jython wrapper object to a JSON-compatible object.
	
	Args:
		object (any): the object to convert
	
	Returns:
		any: JSON-compatible object
	"""
	logging(__name__, inspect.currentframe().f_code.co_name, 'running')
	jsonObject = TypeUtilities.pyToGson(object)
	logging(__name__, inspect.currentframe().f_code.co_name, 'resp=%s' % (jsonObject))
	return jsonObject