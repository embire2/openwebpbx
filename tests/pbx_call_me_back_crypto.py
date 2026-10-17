#!/usr/bin/env python3
"""Cross-runtime verifier checks against Python's standard cryptographic primitives."""
import hashlib,hmac,json,secrets,subprocess,uuid
from pathlib import Path
root=Path(__file__).resolve().parents[1]
cases=[('',hashlib.sha256(b'').hexdigest()),('abc',hashlib.sha256(b'abc').hexdigest()),('a'*1000,hashlib.sha256(b'a'*1000).hexdigest())]
requests=[]
for _ in range(64):
 key=secrets.token_bytes(32);domain=str(uuid.uuid4());identity='8001015009087'
 expected=hmac.new(hmac.new(key,b'openweb-call-me-back-id/v1\0'+domain.encode(),hashlib.sha256).digest(),identity.encode(),hashlib.sha256).hexdigest()
 requests.append({'key':list(key),'domain':domain,'identity':identity,'expected':expected})
script="local C=dofile('app/pbx_setup/resources/switch/scripts/app/pbx_setup/cmb_crypto.lua');local J=dofile('app/switch/resources/scripts/resources/functions/lunajson.lua');local v=J.decode(io.read('*a'));for _,r in ipairs(v) do local key='';for _,n in ipairs(r.key)do key=key..string.char(n)end;assert(C.verifier(key,r.domain,r.identity)==r.expected,'Cross-runtime HMAC mismatch')end;assert(C.verifier('bad',v[1].domain,v[1].identity)==nil);assert(C.hmac(string.rep(string.char(11),20),'Hi There')=='b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7');print('PASS: 66 callback HMAC standard, cross-runtime and missing-key controls')"
# lunajson has require dependencies; supply the repository module search path.
subprocess.run(['lua','-e',"package.path='app/switch/resources/scripts/?.lua;'..package.path;"+script],input=json.dumps(requests),text=True,cwd=root,check=True)
