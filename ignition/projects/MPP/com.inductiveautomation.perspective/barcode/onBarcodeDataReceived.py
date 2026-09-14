def onBarcodeDataReceived(session, data, context):
	"""Project-wide camera-scan event. EVERY native/barcode action in the app
	lands here -- Perspective does not return a scan to the component that
	asked for it -- so this is a dispatch surface only. The routing lives in
	BlueRidge.Common.Barcode, keyed on the action's context
	{"screen": ..., "field": ...}. Keep this a one-liner.

	data = {"barcodeType": "qrcode", "text": "<payload>", "timestamp": <ms>}"""
	BlueRidge.Common.Barcode.onScan(session, data, context)
