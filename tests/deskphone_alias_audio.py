#!/usr/bin/env python3
"""Opt-in isolated phone-domain fixture qualification; credentials remain private."""
import importlib.util,json,os,socket,time,math,struct,re,subprocess
from pathlib import Path
assert os.environ.get('OPENWEB_DESKPHONE_AUTH_TEST')=='1' and socket.gethostname()=='owpbx-desk-auth112'
os.umask(0o077);root=Path('/var/lib/openwebpbx/auth-phone112');state=json.loads((root/'state.json').read_text())
spec=importlib.util.spec_from_file_location('sourcephones','/root/pbx_v20_restore_native.py');source=importlib.util.module_from_spec(spec);spec.loader.exec_module(source)
from sip_trunk_live import audio_check,headers
available=[u for u in state['users'] if u['source_status']=='Available'];first=next(u for u in available if u['number']!=u['auth']);second=next(u for u in available if u['number']!=first['number'])
peers=[source.SourcePhone(first|{'tone_hz':440},state['alias']),source.SourcePhone(second|{'tone_hz':660},state['alias'])];call=None;checks={}
def check(k,v):checks[k]=bool(v);assert v,'Disposable alias audio check failed: '+k
def spectrum(pcm,expected):
 samples=struct.unpack('<'+'h'*(len(pcm)//2),bytes(pcm));samples=samples[-8000:]
 powers={freq:abs(sum(sample*complex(math.cos(2*math.pi*freq*i/8000),-math.sin(2*math.pi*freq*i/8000)) for i,sample in enumerate(samples))) for freq in [440,660]}
 return len(samples)>=4000 and max(powers,key=powers.get)==expected
try:
 for i,ph in enumerate(peers):
  r=ph.register(('127.0.0.1',5060));check('original_alias_registration_'+str(i+1),r['code']==200)
 previous=set(peers[1].dialogs);call=peers[0].dial(second['number'],('127.0.0.1',5060));check('answered_internal_alias_call',call['code']==200)
 audio_check(call,peers[1],previous);time.sleep(1)
 receiver=next(s for cid,s in peers[1].dialogs.items() if cid not in previous and not s.get('ended'))
 check('sustained_two_way_rtp',call['media']['received']>50 and receiver['received']>50)
 check('caller_decoded_remote_660hz',spectrum(call['media']['decoded_pcm'],660));check('callee_decoded_remote_440hz',spectrum(receiver['decoded_pcm'],440))
 invite=next(i for i in peers[1].invites if i['callid'] not in previous);uri=re.search(r'<([^>]+)>',invite['headers']['to']).group(1)
 check('incoming_to_original_number_at_new_alias',uri=='sip:'+second['number']+'@'+state['alias'])
 preserved=json.loads(subprocess.run(['php','/root/auth-fixture.php','verify'],capture_output=True,text=True,check=True).stdout);check('source_passwords_unchanged',preserved['source_credentials_unchanged']);check('canonical_policy_context_preserved',preserved['canonical_realm_unchanged'])
finally:
 if call and call['code']==200:peers[0].hangup(call);time.sleep(.3)
 for ph in peers:
  try:check('original_phone_'+str(peers.index(ph)+1)+'_unregistered',ph.register(('127.0.0.1',5060),expires=0)['code']==200)
  finally:ph.close()
report={'scope':'original-source-credentials-phone-domain-alias','checks':checks,'count':len(checks),'all_passed':all(checks.values()),'decoded_synthetic_audio_only':True,'canonical_realm_unchanged':True,'no_customer_or_carrier_calls':True,'physical_phone_firmware_port_test_pending':True}
(root/'alias-audio-evidence.json').write_text(json.dumps(report,indent=2));print(json.dumps(report))
