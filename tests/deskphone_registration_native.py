#!/usr/bin/env python3
"""Opt-in isolated source-credential registration checks; private fixture preparation required."""
import argparse,hashlib,importlib.util,json,os,re,secrets,socket,ssl,subprocess,time,xml.etree.ElementTree as ET,uuid
from pathlib import Path
os.umask(0o077)
ROOT=Path('/var/lib/openwebpbx/auth-phone112')
assert os.environ.get('OPENWEB_DESKPHONE_AUTH_TEST') == '1'
assert socket.gethostname()=='owpbx-desk-auth112' and Path('/run/systemd/container').read_text().strip()=='systemd-nspawn'
state=json.loads((ROOT/'state.json').read_text());assert state['scope']=='auth-only-supplied-v20'
spec=importlib.util.spec_from_file_location('sip','/root/sip-peer.py');sip=importlib.util.module_from_spec(spec);spec.loader.exec_module(sip)
def esl(command):
 password=next(n.attrib['value'] for n in ET.parse('/etc/freeswitch/autoload_configs/event_socket.conf.xml').iter('param') if n.attrib['name']=='password')
 r=subprocess.run(['/usr/bin/fs_cli','-p',password,'-x',command],capture_output=True,text=True)
 if r.returncode:raise RuntimeError('Disposable engine API is unavailable.')
 return r.stdout.strip()
def mutate(kind,value):subprocess.run(['php','/root/auth-fixture.php','mutate',kind,value],stdout=subprocess.DEVNULL,check=True)
def contact_uris(text):
 return [uri for line in re.findall(r'(?im)^Contact:\s*([^\r\n]+)',text) for uri in re.findall(r'<?(sips?:[^\s,>]+)',line)]
def nonce_digest(challenge,user,password,method,uri,nc):
 fields=dict(re.findall(r'(\w+)="([^"]*)"',challenge));h=lambda v:hashlib.md5(v.encode()).hexdigest();cnonce=secrets.token_hex(12);number=f'{nc:08x}'
 response=h(h(user+':'+fields['realm']+':'+password)+':'+fields['nonce']+':'+number+':'+cnonce+':auth:'+h(method+':'+uri))
 return f'Digest username="{user}", realm="{fields["realm"]}", nonce="{fields["nonce"]}", uri="{uri}", response="{response}", algorithm=MD5, qop=auth, nc={number}, cnonce="{cnonce}"'
class Client:
 def __init__(self,transport,tls_name=None):
  self.transport=transport;self.pending=b'';self.contexts={};self.registrations={};self.sock=socket.socket(socket.AF_INET,socket.SOCK_DGRAM if transport=='udp' else socket.SOCK_STREAM);self.sock.settimeout(4)
  self.sock.bind(('127.0.0.1',0));self.port=self.sock.getsockname()[1];self.dest=('127.0.0.1',5061 if transport=='tls' else 5060)
  if transport!='udp':
   self.sock.connect(self.dest)
   if transport=='tls':self.sock=ssl.create_default_context(cafile=str(ROOT/'tls.crt')).wrap_socket(self.sock,server_hostname=tls_name or state['realm'])
 def send(self,data):
  if self.transport=='udp':self.sock.sendto(data,self.dest)
  else:self.sock.sendall(data)
 def receive(self):
  if self.transport=='udp':return self.sock.recvfrom(65535)[0].decode()
  while True:
   if b'\r\n\r\n' in self.pending:
    head=self.pending.split(b'\r\n\r\n',1)[0];match=re.search(br'(?im)^Content-Length:\s*(\d+)',head);length=int(match.group(1)) if match else 0;end=len(head)+4+length
    if len(self.pending)>=end:message=self.pending[:end];self.pending=self.pending[end:];return message.decode()
   data=self.sock.recv(65535)
   if not data:raise RuntimeError('Private SIP stream closed.')
   self.pending+=data
 def register(self,u,**changes):
  realm=changes.get('realm',state['realm']);aor=changes.get('aor',u['number']);to=changes.get('to',aor);to_realm=changes.get('to_realm',realm);from_realm=changes.get('from_realm',realm);auth=changes.get('auth',u['auth']);password=changes.get('password',u['password']);expires=changes.get('expires',120)
  registration=self.registrations.setdefault((aor,realm,to,to_realm),{'cid':secrets.token_hex(14)+'@fixture','tag':secrets.token_hex(8),'seq':0});cid=registration['cid'];tag=registration['tag'];uri='sip:'+realm;contact=f'<sip:{aor}@127.0.0.1:{self.port};transport={self.transport}>';from_header=f'<sip:{aor}@{from_realm}>;tag={tag}';to_header=f'<sip:{to}@{to_realm}>';registration['seq']+=1;seq=registration['seq'];authorization=None;query=changes.get('bind_query',False);context_key=(auth,realm)
  if changes.get('reuse_nonce'):
   saved=self.contexts[context_key];saved['nc']+=1;authorization=nonce_digest(saved['challenge'],auth,password,'REGISTER',uri,saved['nc'])
  challenge_realm=bool(authorization)
  for _ in range(4):
   lines=[f'REGISTER {uri} SIP/2.0',f'Via: SIP/2.0/{self.transport.upper()} 127.0.0.1:{self.port};branch=z9hG4bK{secrets.token_hex(10)};rport','Max-Forwards: 20','From: '+from_header,'To: '+to_header,'Call-ID: '+cid,f'CSeq: {seq} REGISTER','User-Agent: OpenWebPBX-Isolated-Deskphone-Qualification']
   if not query:lines.extend(['Contact: '+contact,'Expires: '+str(expires)])
   if authorization:lines.append('Authorization: '+authorization)
   (ROOT/'last-request.txt').write_text('\r\n'.join(lines+['Content-Length: 0','','']));self.send(('\r\n'.join(lines+['Content-Length: 0','',''])).encode())
   while True:
    text=self.receive();headers=sip.headers(text);(ROOT/'last-received.txt').write_text(text)
    if headers.get('call-id')==cid and headers.get('cseq')==f'{seq} REGISTER' and text.startswith('SIP/2.0 ') and int(text.split()[1])>=200:break
   code=int(text.split()[1])
   if code==401 and authorization is None:
    challenge=headers['www-authenticate'];challenge_realm=('realm="'+to_realm+'"') in challenge
    self.contexts[context_key]={'challenge':challenge,'nc':1};authorization=nonce_digest(challenge,auth,password,'REGISTER',uri,1);seq+=1;registration['seq']=seq;continue
   response_uri=lambda value:re.search(r'<([^>]+)>',value).group(1)
   result={'code':code,'from_unchanged':headers.get('from')==from_header,'to_aor_unchanged':response_uri(headers.get('to','<missing>'))==response_uri(to_header),'contact_unchanged':query or response_uri(contact) in contact_uris(text),'call_id_unchanged':headers.get('call-id')==cid,'cseq_unchanged':headers.get('cseq')==f'{seq} REGISTER','challenge_realm_matched':challenge_realm}
   result['contacts']=contact_uris(text);result['requested_contact']=response_uri(contact)
   (ROOT/'last-response.txt').write_text(text)
   return result
  raise RuntimeError('Private authentication challenge repeated.')
 def incoming_uri_check(self,u,realm=None):
  r=self.register(u,realm=realm or state['realm']);channel_id=str(uuid.uuid4())
  canonical=u.get('canonical_auth',u['auth']);worker=subprocess.Popen(['python3','/root/auth-esl.py','originate {origination_uuid='+channel_id+',originate_timeout=3}user/'+canonical+'@'+state['realm']+' &park()'],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
  try:
   deadline=time.monotonic()+4
   while time.monotonic()<deadline:
    text=self.receive()
    if text.startswith('INVITE '):
     h=sip.headers(text);uri=text.split()[1];(ROOT/'incoming-invite.txt').write_text(text)
     to_uri=re.search(r'<([^>]+)>',h.get('to','<missing>')).group(1)
     expected='sip:'+u['number']+'@'+(realm or state['realm'])
     self.last_incoming_to_aor_matches=to_uri.split(';',1)[0]==expected
     (ROOT/'incoming-header-evidence.json').write_text(json.dumps({'request_uri_matches_original_contact':uri==r['requested_contact'],'to_aor_matches_registered_user_and_realm':self.last_incoming_to_aor_matches}))
     lines=['SIP/2.0 486 Busy Here']
     for name in ['Via','From','To','Call-ID','CSeq']:
      value=h[name.lower()]
      if name=='To' and ';tag=' not in value:value+=';tag=fixturebusy'
      lines.append(name+': '+value)
     self.send(('\r\n'.join(lines+['Content-Length: 0','',''])).encode());return uri==r['requested_contact']
   return False
  finally:
   esl('uuid_kill '+channel_id+' NORMAL_CLEARING');worker.wait(timeout=5)
 def close(self):self.sock.close()
checks={};failures=[]
def check(name,value):checks[name]=bool(value);failures.extend([] if value else [name])
parser=argparse.ArgumentParser();parser.add_argument('--transport',choices=['udp','tcp','tls','all'],default='all');args=parser.parse_args()
for attempt in range(50):
 try:
  if 'RUNNING' in esl('sofia status'):break
 except RuntimeError:pass
 time.sleep(.1)
else:raise RuntimeError('Disposable SIP profiles did not become ready.')
users=state['users'];numbers={u['number'] for u in users};separate=next(u for u in users if u['number']!=u['auth'] and u['auth'] not in numbers)
collision=next(u for u in users if u['number']!=u['auth'] and u['auth'] in numbers)
for transport in (['udp','tcp','tls'] if args.transport=='all' else [args.transport]):
 for account in users+[state['ordinary'],state['mobile'],state['foreign']]:esl('sofia profile internal flush_inbound_reg '+account.get('canonical_auth',account['auth'])+'@'+account.get('realm',state['realm']))
 c=Client(transport)
 try:
  for i,u in enumerate(users):
   (ROOT/'progress.json').write_text(json.dumps({'transport':transport,'source_index':i+1}));r=c.register(u);check(f'{transport}_original_source_{i+1}',r['code']==(200 if u['enabled'] else 403))
   if r['code']==200:
    for k,v in r.items():
     if k not in ['code','contacts','requested_contact']:check(f'{transport}_response_{i+1}_{k}',v)
    contact=esl('sofia_contact '+u['auth']+'@'+state['realm']);check(f'{transport}_canonical_contact_{i+1}',not contact.startswith('error/') and f'127.0.0.1:{c.port}' in contact)
    removed=c.register(u,expires=0);check(f'{transport}_source_unregister_{i+1}',removed['code']==200 and f':{c.port}' not in esl('sofia_contact '+u['auth']+'@'+state['realm']))
  r=c.register(separate,aor=separate['auth']);check(transport+'_legacy_noncolliding_auth_aor',r['code']==200)
  c.register(separate,aor=separate['auth'],expires=0)
  r=c.register(collision,aor=collision['auth']);check(transport+'_numeric_collision_cannot_claim_other_aor',r['code']==403)
  for name,kw in [('wrong_password',{'password':'unrelated-test-password'}),('foreign_from',{'aor':'999999'}),('foreign_from_realm',{'from_realm':'foreign112.invalid'}),('mixed_to',{'to':separate['auth']}),('wrong_realm',{'realm':'foreign112.invalid'}),('foreign_to_realm',{'to_realm':'foreign112.invalid'}),('foreign_auth',{'auth':'not-a-real-account'})]:
   r=c.register(separate,**kw);check(transport+'_'+name,r['code'] in [403,401])
  foreign=state['foreign'];r=c.register(foreign,realm=foreign['realm']);check(transport+'_separate_domain_valid_identity',r['code']==200)
  check(transport+'_separate_domain_rejects_source_password',c.register(users[0],realm=foreign['realm'],aor=foreign['number'])['code']==403)
  check(transport+'_separate_domain_cannot_claim_original_from_realm',c.register(foreign,realm=foreign['realm'],from_realm=state['realm'])['code']==403)
  c.register(foreign,realm=foreign['realm'],expires=0)
  # Prewarm the regular user_call cache, then change protected state without flushing any directory cache.
  first=users[0];cache=esl('user_data '+first['auth']+'@'+state['realm']+' param password');check(transport+'_prewarm_password_exact',hashlib.sha256(cache.encode()).digest()==hashlib.sha256(first['password'].encode()).digest())
  r=c.register(first);check(transport+'_warmed_auth_refresh',c.register(first,reuse_nonce=True)['code']==200)
  check(transport+'_warmed_auth_forged_pair',c.register(first,aor='999999',reuse_nonce=True)['code']==403)
  c.register(separate);check(transport+'_warmed_auth_mixed_to',c.register(separate,to=separate['auth'],reuse_nonce=True)['code']==403)
  for kind in ['extension','tenant','domain']:
   mutate(kind,'false')
   try:r=c.register(first,reuse_nonce=True);check(transport+'_prewarmed_'+kind+'_disabled',r['code']==403)
   finally:mutate(kind,'true')
   r=c.register(first);check(transport+'_'+kind+'_restored_registration',r['code']==200)
  for label,u in [('ordinary',state['ordinary']),('mobile',state['mobile'])]:
   r=c.register(u);check(transport+'_'+label+'_register',r['code']==200);check(transport+'_'+label+'_response_contact',r['contact_unchanged'])
   check(transport+'_'+label+'_warm_refresh',c.register(u,reuse_nonce=True)['code']==200)
   check(transport+'_'+label+'_forged_warm_from',c.register(u,aor='999999',reuse_nonce=True)['code']==403)
   r=c.register(u,bind_query=True);check(transport+'_'+label+'_binding_query',r['code']==200 and any(f':{c.port}' in x for x in r['contacts']))
   r=c.register(u,expires=0);check(transport+'_'+label+'_unregister_response',r['code']==200)
   canonical=u.get('canonical_auth',u['auth']);contact=esl('sofia_contact '+canonical+'@'+state['realm']);check(transport+'_'+label+'_unregister_removes_this_contact',r['requested_contact'] not in contact)
  mobile=state['mobile'];c.register(mobile);mutate('mobile','false')
  try:check(transport+'_revoked_mobile_warmed_auth',c.register(mobile,reuse_nonce=True)['code']==403)
  finally:mutate('mobile','true')
  check(transport+'_incoming_invite_keeps_original_contact_uri',c.incoming_uri_check(separate))
  # Two independent contacts retain original URI users and normal binding-list/query semantics.
  c.register(separate,expires=0);other=Client(transport)
  try:
   a=c.register(separate);b=other.register(separate)
   # Sofia queues insertion; require both bindings to be visible before testing a subsequent query.
   deadline=time.monotonic()+3
   while time.monotonic()<deadline:
    stored=esl('sofia_contact '+separate['auth']+'@'+state['realm'])
    if a['requested_contact'] in stored and b['requested_contact'] in stored:break
    time.sleep(.01)
   check(transport+'_two_contacts_listed',a['requested_contact'] in b['contacts'] and b['requested_contact'] in b['contacts'])
   q=c.register(separate,bind_query=True);check(transport+'_query_has_both_original_contacts',q['code']==200 and a['requested_contact'] in q['contacts'] and b['requested_contact'] in q['contacts'])
   r=other.register(separate,expires=0);check(transport+'_unregister_keeps_remaining_contact',r['code']==200 and a['requested_contact'] in r['contacts'] and b['requested_contact'] not in r['contacts'])
   r=c.register(separate,expires=0);check(transport+'_last_unregister_returns_no_contacts',r['code']==200 and not r['contacts'])
   check(transport+'_last_unregister_removes_canonical_binding',esl('sofia_contact '+separate['auth']+'@'+state['realm']).startswith('error/'))
  finally:other.close()
  # Call-ID is never an authority to modify another user's or realm's registration.
  for scope,victim,attacker,attacker_realm in [('user',users[0],users[1],state['realm']),('tenant',users[0],state['foreign'],state['foreign']['realm'])]:
   x,y=Client(transport),Client(transport)
   try:
    a=x.register(victim);b=y.register(attacker,realm=attacker_realm)
    victim_key=(victim['number'],state['realm'],victim['number'],state['realm']);attacker_key=(attacker['number'],attacker_realm,attacker['number'],attacker_realm)
    y.registrations[attacker_key]['cid']=x.registrations[victim_key]['cid'];r=y.register(attacker,realm=attacker_realm,expires=0)
    check(transport+'_copied_call_id_'+scope+'_cannot_unregister_victim',r['code']==200 and a['requested_contact'] in esl('sofia_contact '+victim['auth']+'@'+state['realm']))
   finally:
    for account,realm in [(victim,state['realm']),(attacker,attacker_realm)]:esl('sofia profile internal flush_inbound_reg '+account['auth']+'@'+realm)
    x.close();y.close()
 finally:c.close()
report={'scope':'auth-only-supplied-v20','transports':args.transport,'source_users':len(users),'original_passwords_used_without_changes':True,'checks':checks,'count':len(checks),'failed_cases':failures,'all_passed':not failures,'response_headers_kept_private':True,'loopback_only':True,'production_unchanged':True}
(ROOT/('native-'+args.transport+'-evidence.json')).write_text(json.dumps(report,indent=2));print(json.dumps({k:v for k,v in report.items() if k!='checks'}));raise SystemExit(0 if not failures else 1)
