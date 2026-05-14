import inspect

def log(msg):
    """
    Author: Ronald Pulliam
    Date: 07/07/2025
    Project logging helper for consistent tracing.
    
    Args:
        msg (str): message to log
        
    Returns:
        None
    """
    BlueRidge.HMI.CNCLoader.Util.logging(__name__, inspect.currentframe().f_back.f_code.co_name, msg)


def getBlockConfigs():
    """
    Author: Ronald Pulliam
    Date: 07/07/2025
    Fetches block configurations from the named query.
    
    Returns:
        list[dict]
    """
    namedQuery = "config/getBlockConfigs"
    results = system.db.execQuery(namedQuery)
    headers = list(results.getColumnNames())
    return [dict(zip(headers, row)) for row in results]


def getAll():
    """
    Author: Ronald Pulliam
    Date: 07/07/2025
    Returns all block configs formatted for UI selectors.
    
    Returns:
        list[dict]
    """
    log('running')
    blockConfigs = getBlockConfigs()
    resp = []
    for blockConfig in blockConfigs:
        resp.append({
            "text": blockConfig.get('name', ''),
            "view": blockConfig.get('blockConfigUUID'),
            "value": "",
            "key": blockConfig.get('blockConfigUUID')
        })
    log('resp=%s' % (resp))
    return resp


def getOne(data):
    """
    Author: Ronald Pulliam
    Date: 07/07/2025
    Returns details for a specific block configuration.
    
    Args:
        data (str): UUID of the blockConfig
        
    Returns:
        dict
    """
    log('data=%s' % (data))
    resp = {
        "name": '',
        "available": False,
        "cylinderCount": 0,
        "bankCount": 0,
        "key": None,
        "assignedNumbers": [],
        "type": "blockConfig"
    }
    
    if data:
        blockConfigs = getBlockConfigs()
        for blockConfig in blockConfigs:
            if str(blockConfig.get("blockConfigUUID")) == str(data):
                resp = {
                    "name": blockConfig.get("name", ''),
                    "available": blockConfig.get("active", False),
                    "cylinderCount": blockConfig.get("cylinderCount", 0),
                    "bankCount": blockConfig.get("bankCount", 0),
                    "key": blockConfig.get("blockConfigUUID"),
                    "assignedNumbers": system.util.jsonDecode(blockConfig.get("assignedNumbers", "[]")),
                    "type": "blockConfig"
                }
                break
                
    log('resp=%s' % (resp))
    return resp


def getBanks(data):
	"""
	Author: Ronald Pulliam
	Date: 07/07/2025
	Splits a block configuration into bank definitions for UI.
	
	Args:
	    data (dict): blockConfig dictionary
	    
	Returns:
	    list[dict]
	"""
	log('data=%s' % (data))
	
	blockConfig = data
	blockConfigKey = blockConfig.get("key")
	bankCount = blockConfig.get("bankCount")
	cylinderCount = blockConfig.get("cylinderCount")
	assignedNumbers = blockConfig.get("assignedNumbers")
	selections = blockConfig.get("selections",[False]*len(assignedNumbers))
	instances = []
	if bankCount:
		if bankCount != 0:
			cylinderCountPerBank = int(cylinderCount/bankCount)
		else:
			cylinderCountPerBank = cylinderCount
		for i in range(bankCount):
			bankAssignedNumbers = assignedNumbers[i*cylinderCountPerBank:i*cylinderCountPerBank+cylinderCountPerBank]
			bankSelections = selections[i*cylinderCountPerBank:i*cylinderCountPerBank+cylinderCountPerBank]
			instances.append({"key":blockConfigKey,"bankNumber":i+1,"bankCount":bankCount,"cylinderCount":cylinderCount, "bankAssignedNumbers": bankAssignedNumbers, "bankSelections": bankSelections})
	log('resp=%s' % (instances))
	return instances


def getCylinders(data):
	"""
	Author: Ronald Pulliam
	Date: 07/07/2025
	Splits a bank into individual cylinders for UI.
	
	Args:
	    data (dict): bank dictionary
	    
	Returns:
	    list[dict]
	"""
	log('data=%s' % (data))
	
	blockConfig = data#system.util.jsonDecode(data)
	blockConfigKey = blockConfig["key"]
	bankNumber = blockConfig["bankNumber"]
	bankCount = blockConfig["bankCount"]
	cylinderCount = blockConfig["cylinderCount"]
	bankAssignedNumbers = blockConfig["bankAssignedNumbers"]
	bankSelections = blockConfig['bankSelections']
	#	bankAdder = (bankNumber-1)*cylinderCount
	instances = []
	for i in range(cylinderCount/bankCount):
		if i < len(bankAssignedNumbers):
			instances.append({"assignedNumber": bankAssignedNumbers[i], "selected": bankSelections[i]})
		else:
			instances.append({"assignedNumber": 1, "selected": False})
	log('resp=%s' % (instances))
	return instances