import inspect
from com.inductiveautomation.ignition.common import TypeUtilities
from com.inductiveautomation.ignition.common.model.values import QualifiedValue

def logging(script, function, message):
	"""
	Author: Ronald Pulliam
	Date: 07/07/2025
	Logging utility to standardize log messages.

	Args:
		script (str): Name of the script module
		function (str): Name of the function
		message (str): Message to log

	Returns:
		str - Success confirmation
	"""
	logger = system.util.getLogger(script)
	logger.info("%s() %s" % (function, message))
	return 'success'

def getFileFormats():
	"""
	Author: Ronald Pulliam
	Date: 07/07/2025
	Provides available number formats for display.

	Returns:
		list[dict] - List of format options
	"""
	formats = [
		{"value": 0, "label": "None"},
		{"value": 1, "label": "##.****"},
		{"value": 2, "label": "###.****"},
		{"value": 3, "label": "####.****"}
	]
	return formats

def getBlockConfigs():
	"""
	Author: Ronald Pulliam
	Date: 07/07/2025
	Fetches block configuration options for use in dropdowns.

	Returns:
		list[dict] - Block configuration options
	"""
	logging(__name__, inspect.currentframe().f_code.co_name, 'running')
	data = BlueRidge.HMI.CNCLoader.BlockConfig.getAll()
	return [{'value': d.get('key'), 'label': d.get('text')} for d in data]

def getOperationTypes():
	"""
	Author: Ronald Pulliam
	Date: 07/07/2025
	Fetches available operation types for use in dropdowns.

	Returns:
		list[dict] - Operation types
	"""
	logging(__name__, inspect.currentframe().f_code.co_name, 'running')
	data = BlueRidge.HMI.CNCLoader.OperationType.getAll()
	resp = [{'value': d.get('text'), 'label': d.get('text')} for d in data]
	resp.append({'value': '', 'label': 'None'})
	return resp

def getOperationEngines():
	"""
	Author: Ronald Pulliam
	Date: 07/07/2025
	Fetches engine options for operations for dropdowns.

	Returns:
		list[dict] - Engine options
	"""
	logging(__name__, inspect.currentframe().f_code.co_name, 'running')
	data = BlueRidge.HMI.CNCLoader.Engine.getAll()
	return [{'value': d.get('text'), 'label': d.get('text')} for d in data]

def getFailureReasons(data):
	"""
	Author: Ronald Pulliam
	Date: 07/07/2025
	Fetches failure reasons linked to an engine.

	Args:
		data (str): Engine UUID

	Returns:
		list[dict] - List of failure reason items for UI
	"""
	reasonDataset = BlueRidge.HMI.CNCLoader.FailureReason.getAll(data)
	reasons = system.dataset.toPyDataSet(reasonDataset)
	return [{'text': r['name'], 'view': i + 1, 'value': ''} for i, r in enumerate(reasons)]

def getSelectionScreens():
	"""
	Author: Ronald Pulliam
	Date: 07/07/2025
	Provides available HMI selection screens for dropdowns.

	Returns:
		list[dict] - Selection screen options
	"""
	logging(__name__, inspect.currentframe().f_code.co_name, 'running')
	return [
		{"value": 0, "label": "None"},
		{"value": 1, "label": "1st"},
		{"value": 2, "label": "2nd"},
		{"value": 3, "label": "3rd"}
	]

def extractQualifiedValues(data):
	"""
	Author: Ben Furlani
	Date: 05/13/2025
	Recursively extracts `.value` from QualifiedValues in various data structures.

	Args:
		data (any): Input potentially containing QualifiedValues

	Returns:
		(any) - The input with all QualifiedValues converted to their .value
	"""
	if isinstance(data, QualifiedValue):
		return data.getValue()
	elif isinstance(data, list):
		return [extractQualifiedValues(i) for i in data]
	elif isinstance(data, tuple):
		return tuple(extractQualifiedValues(i) for i in data)
	elif isinstance(data, dict):
		return {k: extractQualifiedValues(v) for k, v in data.items()}
	else:
		return data

def convertWrapperObjectToJson(object):
	"""
	Author: Ben Furlani
	Date: 05/13/2025
	Converts a Java object to a JSON-compatible format using Ignition's utilities.

	Args:
		object (java.lang.Object): Java object to convert

	Returns:
		(com.inductiveautomation.ignition.common.gson.JsonElement): JSON representation
	"""
	return TypeUtilities.pyToGson(object)