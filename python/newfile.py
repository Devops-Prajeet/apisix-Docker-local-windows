import requests
import json

url = "https://sandbox-api.trusthub.in/bank-validateacct"


payload = json.dumps({
  "entityId": "2c59c369-67b2-42a7-afa5-4491a58a8e7c", #static
  "programId": "286", #static
  "requestId": "3g54et6et5tgr", #Random generate request id for each request hit
  "custIfsc": "SBIN0009995",
  "custAcctNo": "42992444999",
  "trackingRefNo": "qf4fq3fadfx", # trackingRefNo can be static not need to dynamic change
  "txnType": "IMPS" #static
})
headers = {
  'x-api-key': 'IsFNdstPNa6AxOhmNrW7X1cJhBsBpsqEqtd5LSF4',
  'Content-Type': 'application/json'
}

response = requests.request("POST", url, headers=headers, data=payload)

print(response.text)