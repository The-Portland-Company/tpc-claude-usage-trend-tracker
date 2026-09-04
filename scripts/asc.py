#!/usr/bin/env python3
"""Tiny App Store Connect API client (same key as Focus Dock's asc_submit.py)."""
import json, sys, time, urllib.request, urllib.error, jwt
KEY_ID="XG3FW9LT9Q"; ISSUER="178bab61-1c45-4f62-9525-55f8ed15a98d"
P8=f"/Users/spencerhill/.appstoreconnect/private_keys/AuthKey_{KEY_ID}.p8"
BASE="https://api.appstoreconnect.apple.com"
def token():
    now=int(time.time())
    return jwt.encode({"iss":ISSUER,"iat":now,"exp":now+1200,"aud":"appstoreconnect-v1"},open(P8).read(),algorithm="ES256",headers={"kid":KEY_ID,"typ":"JWT"})
def call(method,path,body=None):
    req=urllib.request.Request(BASE+path,method=method,data=json.dumps(body).encode() if body else None,
        headers={"Authorization":"Bearer "+token(),"Content-Type":"application/json"})
    try:
        with urllib.request.urlopen(req) as r: return r.status,(json.loads(r.read() or b"{}"))
    except urllib.error.HTTPError as e: return e.code,json.loads(e.read() or b"{}")
if __name__=="__main__":
    m,p=sys.argv[1],sys.argv[2]; b=json.loads(sys.argv[3]) if len(sys.argv)>3 else None
    s,d=call(m,p,b); print(s); print(json.dumps(d,indent=1)[:4000])
