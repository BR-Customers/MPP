def onTagChange(initialChange, newValue, previousValue, event, executionCount):
	BlueRidge.Workorder.PlcWatcher.dispatch(str(event.tagPath), event.previousValue, event.currentValue)