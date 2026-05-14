import inspect
from com.inductiveautomation.ignition.common import TypeUtilities
from com.inductiveautomation.ignition.common.model.values import QualifiedValue

def logging(script, function, message):
	"""
	Author: Ronald Pulliam  
	Date: 07/03/2025  
	Global project logger callable from other modules.
	
	Args:
		script (str): script name
		function (str): function name
		message (str): message to log
		
	Returns:
		str - 'success'
	"""
	logger = system.util.getLogger(script)
	logger.info("%s() %s" % (function, message))
	return 'success'


def log(msg):
	"""
	Author: Ronald Pulliam  
	Date: 07/03/2025  
	Local helper for consistent project logging with automatic function tracing.
	
	Args:
		msg (str): message to log
		
	Returns:
		None
	"""
	logging(__name__, inspect.currentframe().f_back.f_code.co_name, msg)


def getFileFormats():
	"""
	Author: Ronald Pulliam  
	Date: 07/03/2025  
	Returns a static list of file formats for dropdowns.
	
	Returns:
		list[dict] - List of value/label pairs.
	"""
	log('running')
	resp = [
		{"value": "None", "label": "None"},
		{"value": "##.****", "label": "##.****"},
		{"value": "###.****", "label": "###.****"},
		{"value": "####.****", "label": "####.****"},
	]
	log('resp=%s' % (resp))
	return resp


def getBlockConfigs():
	"""
	Author: Ronald Pulliam  
	Date: 07/03/2025  
	Fetches available block configurations for dropdown components.
	
	Returns:
		list[dict] - List of value/label pairs.
	"""
	log('running')
	data = BlueRidge.Config.BlockConfig.getAll()
	data = [d for d in data if d.get('available')]
	resp = [{'value': d.get('key'), 'label': d.get('text')} for d in data]
	log('resp=%s' % (resp))
	return resp


def getOperationTypes():
	"""
	Author: Ronald Pulliam  
	Date: 07/03/2025  
	Fetches available operation types for tab components.
	
	Returns:
		list[dict] - List of key/text pairs.
	"""
	log('running')
	data = BlueRidge.Config.OperationType.getAll()
	data = [d for d in data if d.get('available')]
	resp = [{'key': d.get('key'), 'text': d.get('text')} for d in data]
	log('resp=%s' % (resp))
	return resp


def getExtensionTypes():
	"""
	Author: Ronald Pulliam  
	Date: 07/03/2025  
	Fetches available extension types for dropdown components.
	
	Returns:
		list[dict] - List of value/label pairs.
	"""
	log('running')
	data = BlueRidge.Config.ExtensionType.getAll()
	data = [d for d in data if d.get('available')]
	resp = [{'value': d.get('key'), 'label': d.get('text')} for d in data]
	log('resp=%s' % (resp))
	return resp


def getHMIs():
	"""
	Author: Ronald Pulliam  
	Date: 07/03/2025  
	Fetches available HMIs for dropdown components.
	
	Returns:
		list[dict] - List of value/label pairs.
	"""
	log('running')
	data = BlueRidge.Config.Plant.getHMI()
	resp = [{'value': d.get('key'), 'label': d.get('text')} for d in data]
	log('resp=%s' % (resp))
	return resp


def getSelectionScreens():
	"""
	Author: Ronald Pulliam  
	Date: 07/03/2025  
	Returns static selection screens for dropdown components.
	
	Returns:
		list[dict] - List of selection screen options.
	"""
	log('running')
	resp = [
		{"value": 0, "label": "None"},
		{"value": 1, "label": "1st"},
		{"value": 2, "label": "2nd"},
		{"value": 3, "label": "3rd"},
	]
	log('resp=%s' % (resp))
	return resp


def getAvailableEngines(equipmentUUID):
	"""
	Author: Ronald Pulliam  
	Date: 07/03/2025  
	Fetches available engines for a given equipment UUID, removing already assigned engines.
	
	Args:
		equipmentUUID (str): Equipment UUID.
		
	Returns:
		list[dict] - Available engines.
	"""
	log('data=%s' % (equipmentUUID))
	equipmentEngines = BlueRidge.Config.EquipmentEngine.getAll(equipmentUUID)
	usedKeys = [ee.get('engineUUID') for ee in equipmentEngines]
	allEngines = BlueRidge.Config.Engine.getAll()
	availableEngines = [e for e in allEngines if e.get('key') not in usedKeys and e.get('available')]
	log('resp=%s' % (availableEngines))
	return availableEngines


def extractQualifiedValues(data):
	"""
	Author: Ben Furlani  
	Date: 05/13/2025  
	Recursively extracts the `.value` portion of a QualifiedValue, converting nested QualifiedValues to raw values.
	
	Args:
		data (any): Value, list, tuple, or dict possibly containing QualifiedValues.
		
	Returns:
		(any) - Cleaned data with QualifiedValues converted to their .value attribute.
	"""
	log('data=%s' % (data))
	if isinstance(data, QualifiedValue):
		result = data.getValue()
	elif isinstance(data, list):
		result = [extractQualifiedValues(item) for item in data]
	elif isinstance(data, tuple):
		result = tuple(extractQualifiedValues(item) for item in data)
	elif isinstance(data, dict):
		result = {key: extractQualifiedValues(value) for key, value in data.items()}
	else:
		result = data
	log('resp=%s' % (result))
	return result


def convertWrapperObjectToJson(data):
	"""
	Author: Ben Furlani  
	Date: 05/13/2025   
	Converts a Python Ignition wrapper object to JSON (gson).
	
	Args:
		object (any): Ignition wrapper object.
		
	Returns:
		JsonElement - Gson-compatible JSON object.
	"""
	log('data=%s' % (data))
	jsonObject = TypeUtilities.pyToGson(data)
	log('resp=%s' % (jsonObject))
	return jsonObject
	
	
def bitsToBytes(bits):
	value = 0
	for i,bit in enumerate(bits):
		value |= (bit & 1) << (7-i)
	return value
