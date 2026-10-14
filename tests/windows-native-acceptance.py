#!/usr/bin/env python3
"""SPDX-License-Identifier: AGPL-3.0-or-later.
Actual disposable Windows SIP/audio/HTTPS qualification. All identities are fictional.
No carrier endpoints, customer archives, TLS bypass or physical-device claims.
"""
import argparse, base64, ctypes, hashlib, http.cookiejar, http.server, importlib.util, json, math
import os, queue, re, secrets, socket, socketserver, ssl, struct, subprocess, sys
import threading, time, urllib.error, urllib.parse, urllib.request, uuid, wave
from datetime import datetime, timedelta, timezone
from email.parser import BytesParser
from email.policy import default
from html.parser import HTMLParser
from pathlib import Path

WINPS=str(Path(os.environ.get('SystemRoot','C:/Windows'))/'System32/WindowsPowerShell/v1.0/powershell.exe')


def guard():
    if os.name != 'nt' or os.environ.get('OPENWEB_WINDOWS_NATIVE_TEST') != '1' or os.environ.get('GITHUB_ACTIONS') != 'true' or os.environ.get('RUNNER_ENVIRONMENT') != 'github-hosted' or os.environ.get('GITHUB_REPOSITORY') != 'embire2/openwebpbx':
        raise RuntimeError('Explicit disposable Windows hosted runner required')


def load_module(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec); sys.modules[name] = module
    spec.loader.exec_module(module); return module


class Forms(HTMLParser):
    def __init__(self, text):
        super().__init__(); self.forms=[]; self.form=None; self.select=None
        self.feed(text)
    def handle_starttag(self, tag, attributes):
        a=dict(attributes)
        if tag=='form': self.form={'action':a.get('action',''),'fields':{}}; self.forms.append(self.form)
        if self.form is None: return
        if tag=='input' and a.get('name') and 'disabled' not in a:
            if a.get('type') not in ('checkbox','radio') or 'checked' in a:
                self.form['fields'][a['name']]=a.get('value','')
        if tag=='select': self.select=a.get('name')
        if tag=='option' and self.select:
            if self.select not in self.form['fields'] or 'selected' in a:
                self.form['fields'][self.select]=a.get('value','')
    def handle_endtag(self, tag):
        if tag=='form': self.form=None
        if tag=='select': self.select=None


class Web:
    def __init__(self, address, root_ca):
        self.base=address.rstrip('/')
        context=ssl.create_default_context(cafile=str(root_ca))
        self.open=urllib.request.build_opener(urllib.request.HTTPCookieProcessor(http.cookiejar.CookieJar()), urllib.request.HTTPSHandler(context=context))
    def request(self, path, fields=None):
        url=urllib.parse.urljoin(self.base+'/',path)
        if urllib.parse.urlsplit(url).netloc != urllib.parse.urlsplit(self.base).netloc:
            raise RuntimeError('Fixture HTTPS origin changed')
        data=None if fields is None else urllib.parse.urlencode(fields,doseq=True).encode()
        try:
            with self.open.open(urllib.request.Request(url,data=data),timeout=25) as r:
                return r.status,r.geturl(),r.read().decode()
        except urllib.error.HTTPError as e:
            return e.code,e.geturl(),e.read().decode()
    def submit(self,path,action,fields,expected=200):
        status,url,text=self.request(path); assert status==200,'Fixture form is unavailable'
        candidates=[f for f in Forms(text).forms if f['fields'].get('action')==action and (action is not None or 'provider' in f['fields'])]
        assert candidates,'Expected normal authenticated form is unavailable'
        form=candidates[0]; payload=dict(form['fields']); payload.update(fields)
        result=self.request(form['action'] or path,payload)
        assert result[0]==expected,'Normal form submission failed'
        if expected==200: assert 'setup-message error' not in result[2] and 'role="alert"' not in result[2], 'Normal form rejected the fixture'
        return result
    def agent(self,number,state):
        status,_,text=self.request('/app/pbx_setup/live.php');assert status==200
        token=json.loads(text)['token'];fields={token['name']:token['hash'],'operation':'agent','queue':'8190','number':number,'agent_state':state}
        status,_,text=self.request('/app/pbx_setup/live.php',fields);assert status==200 and 'error' not in json.loads(text),'Normal supervisor action failed'



class Fixture:
    def __init__(self,input_path):
        self.path=Path(input_path); self.s=json.loads(self.path.read_text())
        self.evidence=Path(self.s['evidence_directory']); self.evidence.mkdir(exist_ok=True)
        self.source=Path(self.s['source_root']); self.php=Path('C:/OpenWebPBX/php/php.exe')
        self.script=self.source/'tests/windows-native-fixture.php'; self.checks=[]; self.active_case='fixture_initialization'
    def cli(self,action,*args,json_result=True):
        r=subprocess.run([str(self.php),str(self.script),action,str(self.path),*args],capture_output=True,text=True,timeout=35)
        if r.returncode: raise RuntimeError('Private fixture operation failed: '+action)
        return json.loads(r.stdout) if json_result else r.stdout.strip()
    def refresh(self): self.s=json.loads(self.path.read_text())
    def record(self,name,**facts):
        self.checks.append({'case':name,'passed':True,**facts})
        (self.evidence/'native-progress.json').write_text(json.dumps({'checks':self.checks},indent=2))
    def wait(self,predicate,seconds=12):
        end=time.monotonic()+seconds
        while time.monotonic()<end:
            result=predicate()
            if result: return result
            time.sleep(.05)
        raise AssertionError('Bounded native fixture observation expired')
    def music(self,pcm):
        with wave.open(self.s['music']) as f:
            assert f.getframerate()==8000 and f.getnchannels()==1 and f.getsampwidth()==2
            raw=f.readframes(f.getnframes())
        def envelope(samples):
            return [math.sqrt(sum(v*v for v in samples[i:i+160])/160) for i in range(0,len(samples)-159,160)]
        actual=struct.unpack('<'+'h'*(len(pcm)//2),pcm)[-64000:]
        assert len(actual)>=56000,'Stable held capture too short'
        reference=struct.unpack('<'+'h'*(len(raw)//2),raw)
        a,b=envelope(actual),envelope(reference); average=sum(a)/len(a)
        centered=[x-average for x in a]; energy=sum(x*x for x in centered); assert energy>0
        b+=b[:len(a)]; best=-1.; offset=0
        for start in range(len(b)-len(a)):
            part=b[start:start+len(a)]; mean=sum(part)/len(part)
            variance=sum(x*x for x in part)-len(part)*mean*mean
            if variance<=0:continue
            score=sum(x*y for x,y in zip(centered,part))/math.sqrt(energy*variance)
            if score>best:best=score;offset=start/50
        assert best>=.75,'Selected hold music identity failed'
        capture=hashlib.sha256(pcm).hexdigest()
        (self.evidence/'held-private.pcm').write_bytes(pcm)
        return {'held_seconds':len(actual)/8000,'correlation':round(best,4),'threshold':.75,'track_offset':offset,'capture_sha256':capture}


def prepare_pki(f):
    from cryptography import x509
    from cryptography.hazmat.primitives import hashes,serialization
    from cryptography.hazmat.primitives.asymmetric import rsa
    from cryptography.hazmat.primitives.serialization import pkcs12
    from cryptography.x509.oid import NameOID,ExtendedKeyUsageOID
    now=datetime.now(timezone.utc); key=rsa.generate_private_key(65537,2048); leafkey=rsa.generate_private_key(65537,2048)
    name=x509.Name([x509.NameAttribute(NameOID.COMMON_NAME,'OpenWeb PBX fictional hosted-runner '+f.s['scope'])])
    root=(x509.CertificateBuilder().subject_name(name).issuer_name(name).public_key(key.public_key()).serial_number(x509.random_serial_number()).not_valid_before(now-timedelta(minutes=5)).not_valid_after(now+timedelta(days=2)).add_extension(x509.BasicConstraints(ca=True,path_length=0),True).add_extension(x509.KeyUsage(False,False,False,False,False,True,True,False,False),True).add_extension(x509.SubjectKeyIdentifier.from_public_key(key.public_key()),False).sign(key,hashes.SHA256()))
    point=x509.DistributionPoint(full_name=[x509.UniformResourceIdentifier('http://127.0.0.1:18985/fixture.crl')],relative_name=None,reasons=None,crl_issuer=None)
    leaf=(x509.CertificateBuilder().subject_name(x509.Name([x509.NameAttribute(NameOID.COMMON_NAME,'windowsqa.example.invalid')])).issuer_name(name).public_key(leafkey.public_key()).serial_number(x509.random_serial_number()).not_valid_before(now-timedelta(minutes=5)).not_valid_after(now+timedelta(days=1)).add_extension(x509.BasicConstraints(ca=False,path_length=None),True).add_extension(x509.SubjectAlternativeName([x509.DNSName('windowsqa.example.invalid')]),False).add_extension(x509.ExtendedKeyUsage([ExtendedKeyUsageOID.SERVER_AUTH]),False).add_extension(x509.KeyUsage(True,False,True,False,False,False,False,False,False),True).add_extension(x509.AuthorityKeyIdentifier.from_issuer_public_key(key.public_key()),False).add_extension(x509.CRLDistributionPoints([point]),False).sign(key,hashes.SHA256()))
    crl=x509.CertificateRevocationListBuilder().issuer_name(name).last_update(now-timedelta(minutes=5)).next_update(now+timedelta(days=1)).sign(key,hashes.SHA256())
    secret=secrets.token_urlsafe(36)
    (f.evidence/'fixture-root.cer').write_bytes(root.public_bytes(serialization.Encoding.DER))
    (f.evidence/'fixture-root.pem').write_bytes(root.public_bytes(serialization.Encoding.PEM))
    (f.evidence/'fixture-chain.pem').write_bytes(leaf.public_bytes(serialization.Encoding.PEM)+root.public_bytes(serialization.Encoding.PEM))
    (f.evidence/'fixture.crl').write_bytes(crl.public_bytes(serialization.Encoding.DER))
    (f.evidence/'fixture-leaf.pem').write_bytes(leaf.public_bytes(serialization.Encoding.PEM))
    (f.evidence/'fixture-key.pem').write_bytes(leafkey.private_bytes(serialization.Encoding.PEM,serialization.PrivateFormat.PKCS8,serialization.NoEncryption()))
    (f.evidence/'fixture.pfx').write_bytes(pkcs12.serialize_key_and_certificates(b'fictional-windows-native',leafkey,leaf,[root],serialization.BestAvailableEncryption(secret.encode())))
    (f.evidence/'pki-private.json').write_text(json.dumps({'password':secret,'root_thumbprint':root.fingerprint(hashes.SHA1()).hex(),'leaf_thumbprint':leaf.fingerprint(hashes.SHA1()).hex()}))


def serve_pki(f):
    class Handler(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            if self.path!='/fixture.crl':self.send_error(404);return
            data=(f.evidence/'fixture.crl').read_bytes();self.send_response(200);self.send_header('Content-Length',str(len(data)));self.end_headers();self.wfile.write(data)
        def log_message(self,*args):pass
    with http.server.HTTPServer(('127.0.0.1',18985),Handler) as server:
        (f.evidence/'pki-ready.json').write_text('{"ready":true}')
        server.serve_forever()


class SIPClient:
    def __init__(self,transport,bind,server,realm,ca,tls_name):
        self.transport=transport;self.bind=bind;self.server=server;self.realm=realm
        self.buffer=b'';self.registrations={};self.nonces={};self.ledger=[]
        self.sock=socket.socket(socket.AF_INET,socket.SOCK_DGRAM if transport=='udp' else socket.SOCK_STREAM)
        self.sock.settimeout(5);self.sock.bind((bind,0));self.port=self.sock.getsockname()[1]
        if transport!='udp':
            self.sock.connect(server)
            if transport=='tls':self.sock=ssl.create_default_context(cafile=str(ca)).wrap_socket(self.sock,server_hostname=tls_name)
    def send(self,data):
        if self.transport=='udp':self.sock.sendto(data,self.server)
        else:self.sock.sendall(data)
    def receive(self):
        if self.transport=='udp':return self.sock.recvfrom(65535)[0].decode()
        while True:
            if b'\r\n\r\n' in self.buffer:
                head=self.buffer.split(b'\r\n\r\n',1)[0];n=int(re.search(br'(?im)^Content-Length:\s*(\d+)',head).group(1));end=len(head)+4+n
                if len(self.buffer)>=end:msg=self.buffer[:end];self.buffer=self.buffer[end:];return msg.decode()
            data=self.sock.recv(65535)
            if not data:raise RuntimeError('Native SIP stream closed')
            self.buffer+=data
    def register(self,u,**changes):
        realm=changes.get('realm',self.realm);aor=changes.get('aor',u['number']);auth=changes.get('auth',u['auth']);to=changes.get('to',aor)
        password=changes.get('password',u['password']);query=changes.get('query',False);expires=changes.get('expires',120)
        key=(aor,realm,to);r=self.registrations.setdefault(key,{'cid':uuid.uuid4().hex+'@fictional','tag':secrets.token_hex(6),'seq':0});r['seq']+=1
        self.ledger.append(r['cid']);uri='sip:'+realm;authorization=None;context=(auth,realm)
        if changes.get('reuse'):
            cached=self.nonces[context];cached['nc']+=1;authorization=self.digest(cached['challenge'],auth,password,uri,cached['nc'])
        for _ in range(4):
            fh=f'<sip:{aor}@{changes.get("from_realm",realm)}>;tag={r["tag"]}';th=f'<sip:{to}@{changes.get("to_realm",realm)}>'
            contact=f'sip:{aor}@{self.bind}:{self.port};transport={self.transport}'
            lines=[f'REGISTER {uri} SIP/2.0',f'Via: SIP/2.0/{self.transport.upper()} {self.bind}:{self.port};branch=z9hG4bK{secrets.token_hex(10)};rport','Max-Forwards: 20','From: '+fh,'To: '+th,'Call-ID: '+r['cid'],f'CSeq: {r["seq"]} REGISTER','User-Agent: OpenWebPBX-Fictional-Windows-Acceptance']
            if not query:lines+=['Contact: <'+contact+'>','Expires: '+str(expires)]
            if authorization:lines+=['Authorization: '+authorization]
            self.send(('\r\n'.join(lines+['Content-Length: 0','',''])).encode())
            while True:
                text=self.receive();h=self.headers(text)
                if h.get('call-id')==r['cid'] and h.get('cseq')==f'{r["seq"]} REGISTER' and text.startswith('SIP/2.0 ') and int(text.split()[1])>=200:break
            code=int(text.split()[1])
            if code==401 and authorization is None:
                ch=h['www-authenticate'];self.nonces[context]={'challenge':ch,'nc':1};authorization=self.digest(ch,auth,password,uri,1);r['seq']+=1;continue
            contacts=re.findall(r'(?im)^Contact:\s*([^\r\n]+)',text)
            contacts=[x for line in contacts for x in re.findall(r'<?(sips?:[^\s,>]+)',line)]
            return {'code':code,'contacts':contacts,'requested':contact,'response_identity':h.get('from')==fh and re.search(r'<([^>]+)>',h.get('to','<missing>')).group(1)==th[1:-1]}
        raise AssertionError('Repeated SIP challenge')
    @staticmethod
    def headers(text):
        return {k.lower():v.strip() for k,v in (line.split(':',1) for line in text.split('\r\n')[1:] if ':' in line)}
    @staticmethod
    def digest(ch,user,password,uri,nc):
        fields=dict(re.findall(r'(\w+)="([^"]*)"',ch));md5=lambda x:hashlib.md5(x.encode()).hexdigest();cnonce=secrets.token_hex(12);n=f'{nc:08x}'
        response=md5(md5(user+':'+fields['realm']+':'+password)+':'+fields['nonce']+':'+n+':'+cnonce+':auth:'+md5('REGISTER:'+uri))
        return f'Digest username="{user}", realm="{fields["realm"]}", nonce="{fields["nonce"]}", uri="{uri}", response="{response}", algorithm=MD5, qop=auth, nc={n}, cnonce="{cnonce}"'
    def close(self):self.sock.close()


class SIPStream:
    """Present a framed TCP/TLS SIP connection to the independent RTP peer."""
    def __init__(self,bind,server,ca=None,name=None):
        raw=socket.socket();raw.bind((bind,0));raw.settimeout(5);raw.connect(server)
        self.sock=ssl.create_default_context(cafile=str(ca)).wrap_socket(raw,server_hostname=name) if ca else raw
        self.sock.settimeout(.005);self.buffer=b'';self.server=server;self.lock=threading.Lock()
    def recvfrom(self,size):
        while True:
            if b'\r\n\r\n' in self.buffer:
                head=self.buffer.split(b'\r\n\r\n',1)[0];m=re.search(br'(?im)^Content-Length:\s*(\d+)',head);n=int(m.group(1)) if m else 0;end=len(head)+4+n
                if len(self.buffer)>=end:packet=self.buffer[:end];self.buffer=self.buffer[end:];return packet,self.server
            packet=self.sock.recv(size)
            if not packet:raise OSError('Native SIP stream ended')
            self.buffer+=packet
    def sendto(self,data,peer):
        with self.lock:self.sock.sendall(data)
    def close(self):self.sock.close()


class BCG729:
    """Independent peer codec; never invoke the native PBX codec callbacks."""
    def __init__(self,state_root):
        root=Path('C:/Program Files/FreeSWITCH');path=root/'libbcg729.dll'
        proof=json.loads(Path(state_root,'local-codec.json').read_text(encoding='utf-8-sig'))
        assert proof['schema']==1 and proof['callbacks']=='passed' and proof['data_imports_and_heap_ownership']=='passed'
        assert hashlib.sha256(path.read_bytes()).hexdigest()==proof['files']['libbcg729.dll'],'Independent codec DLL hash changed'
        self.search=os.add_dll_directory(str(root));self.dll=ctypes.CDLL(str(path))
        self.dll.initBcg729EncoderChannel.argtypes=[ctypes.c_uint8];self.dll.initBcg729EncoderChannel.restype=ctypes.c_void_p
        self.dll.initBcg729DecoderChannel.argtypes=[];self.dll.initBcg729DecoderChannel.restype=ctypes.c_void_p
        self.dll.closeBcg729EncoderChannel.argtypes=[ctypes.c_void_p];self.dll.closeBcg729DecoderChannel.argtypes=[ctypes.c_void_p]
        self.dll.bcg729Encoder.argtypes=[ctypes.c_void_p,ctypes.POINTER(ctypes.c_int16),ctypes.POINTER(ctypes.c_uint8),ctypes.POINTER(ctypes.c_uint8)]
        self.dll.bcg729Decoder.argtypes=[ctypes.c_void_p,ctypes.POINTER(ctypes.c_uint8),ctypes.c_uint8,ctypes.c_uint8,ctypes.c_uint8,ctypes.c_uint8,ctypes.POINTER(ctypes.c_int16)]
    def contexts(self):
        encoder=self.dll.initBcg729EncoderChannel(0);decoder=self.dll.initBcg729DecoderChannel()
        assert encoder and decoder,'Independent G729 context allocation failed';return encoder,decoder
    def encode(self,ctx,samples):
        result=bytearray()
        for start in [0,80]:
            pcm=(ctypes.c_int16*80)(*samples[start:start+80]);out=(ctypes.c_uint8*10)();length=ctypes.c_uint8()
            self.dll.bcg729Encoder(ctx,pcm,out,ctypes.byref(length));assert length.value==10,'G729 VAD changed fixture packet size';result.extend(out)
        return bytes(result)
    def decode(self,ctx,payload):
        assert len(payload)==20,'Forced G729 packet did not contain two 10ms frames';result=bytearray()
        for start in [0,10]:
            data=(ctypes.c_uint8*10).from_buffer_copy(payload[start:start+10]);pcm=(ctypes.c_int16*80)()
            self.dll.bcg729Decoder(ctx,data,10,0,0,0,pcm);result.extend(struct.pack('<80h',*pcm))
        return result
    def close(self,contexts):
        self.dll.closeBcg729EncoderChannel(contexts[0]);self.dll.closeBcg729DecoderChannel(contexts[1])


def normal_setup(f,web):
    f.active_case='normal_admin_https_csrf_setup'
    status,_,text=web.request('/login.php');assert status==200
    forms=Forms(text).forms;assert forms,'Normal sign-in form missing'
    fields=dict(forms[0]['fields']);fields.update(username=f.s['admin_email'],password=f.s['admin_password'])
    status,_,text=web.request(forms[0]['action'] or '/login.php',fields)
    assert status==200 and 'name="password"' not in text,'Normal administrator login failed'
    values={'company_name':f.s['company_name'],'service_name':f.s['service_name'],'timezone':'UTC','tenant_uuid':'','trunk[host]':'','trunk[name]':'No provider','trunk[authentication]':'ip','outbound[prefix]':'','outbound[strip]':'0','outbound[prepend]':'','inbound_number':'','inbound_destination':''}
    for i,n in enumerate(['8100','8101','8102','8103']):values.update({f'users[{i}][number]':n,f'users[{i}][name]':'Fictional Peer '+n,f'users[{i}][email]':'sink@example.invalid'})
    _,url,text=web.submit('/app/pbx_setup/?view=wizard','review_setup',values)
    assert 'view=review' in url,'Normal setup review missing'
    web.submit(url,'create_setup',{'acknowledged':'1'})
    f.cli('discover');f.refresh();f.record('normal_admin_https_csrf_company_pbx_users')
    # Actual authenticated UI edits create every call object used below.
    def save(view,number,fields):
        web.submit('/app/pbx_setup/?view='+view+'&edit='+number,'save',fields)
    for n in ['8100','8101','8102','8103']:
        save('users',n,{'name':'Fictional Peer '+n,'email':'sink@example.invalid','enabled':'1','voicemail_enabled':'1','voicemail_email':'Attachment' if n=='8103' else 'None','profile':'Available','timeout':'3','auto_status':'','hold_music':'openweb-music','no_answer':'VoiceMail:'+n,'busy':'VoiceMail:'+n,'not_registered':'VoiceMail:'+n})
    save('ring_groups','new',{'name':'Fictional simultaneous group','number':'8180','members[]':['8101','8102'],'ring_order':'8101,8102','strategy':'RingAll','timeout':'4','destination':'Extension:8102'})
    save('ring_groups','new',{'name':'Fictional hunting group','number':'8181','members[]':['8101','8102'],'ring_order':'8101,8102','strategy':'Hunt','timeout':'4','destination':'Extension:8102'})
    save('queues','new',{'name':'Fictional queue','number':'8190','members[]':['8101','8102'],'ring_order':'8101,8102','strategy':'PrioritizedHunt','timeout':'8','ring_timeout':'3','wrap_up':'2','queue_options_present':'1','capacity':'0','service_target':'15','tier_wait':'2','callback_mode':'request','callback_after':'2','callback_attempts':'1','callback_prefix':'','destination':'Extension:8102','moh':'openweb-music'})
    save('receptionists','new',{'name':'Fictional wire DTMF menu','number':'8170','timeout':'4','destination':'Extension:8102','options[2][destination]':'Extension:8101'})
    web.submit('/app/pbx_setup/?view=hotel','hotel_action',{'hotel_action':'add_room','number':'8102','room_name':'Fictional 2025'})
    web.submit('/app/pbx_setup/?view=hotel','hotel_action',{'hotel_action':'check_in','number':'8102','guest_name':'Fictional Guest'})
    f.record('normal_https_groups_queue_ivr_hotel_and_selected_music')
    status,_,_=web.request('/app/pbx_mobile/push.php',{'enabled':'1','provider':'webpush','delivery':'direct'})
    assert status==403,'Missing notification CSRF accepted'
    web.submit('/app/pbx_mobile/push.php',None,{'enabled':'1','provider':'webpush','delivery':'direct','relay_url':'','relay_token':''})
    first=json.loads(Path(f.s['private_state_root'],'mobile-notifications/config.json').read_text(encoding='utf-8-sig'))
    web.submit('/app/pbx_mobile/push.php',None,{'enabled':'1','provider':'webpush','delivery':'direct','relay_url':'','relay_token':''})
    second=json.loads(Path(f.s['private_state_root'],'mobile-notifications/config.json').read_text(encoding='utf-8-sig'))
    assert first==second,'Normal repeated save regenerated VAPID identity'
    assert first.get('enabled') and first.get('vapid_private_key'),'Automatic native notification keys missing'
    f.record('normal_iis_notification_two_saves_stable_vapid_csrf_no_push_delivery')


def native_calls(f):
    f.active_case='native_profile_and_fixture_dependencies'
    status=f.cli('status');bind=status['bind'];assert bind in socket.gethostbyname_ex(socket.gethostname())[2] or bind=='127.0.0.1','Native profile uses a nonlocal endpoint'
    ca=f.evidence/'fixture-root.pem';realm=f.s['realm'];users=f.s['users'];ledger=[]
    for transport in ['udp','tcp','tls']:
        f.active_case='native_'+transport+'_registration_matrix'
        client=SIPClient(transport,bind,(bind,5061 if transport=='tls' else 5060),realm,ca,'windowsqa.example.invalid')
        try:
            # The stock MSI directory must not authenticate its demonstration
            # account through XML, Lua, cache or a default/IP realm fallback.
            demo={'number':'1000','auth':'1000','password':'1234'}
            demo_realms=sorted(set(['default','127.0.0.1',bind,'windowsqa.example.invalid',realm]))
            for demo_realm in demo_realms:
                result=client.register(demo,realm=demo_realm)
                assert result['code'] in (401,403,404),'Stock demonstration credentials authenticated through a realm fallback'
            f.record('native_'+transport+'_msi_demo_password_all_realm_fallbacks_rejected',realms_tested=len(demo_realms),accepted_demo_registrations=0)
            for u in users:
                r=client.register(u);assert r['code']==200 and r['response_identity'] and r['requested'] in r['contacts'],'Exact fictional tuple/response failed'
                assert client.register(u,reuse=True)['code']==200,'Authenticated refresh failed'
                assert r['requested'] in client.register(u,query=True)['contacts'],'Binding query lost original AOR'
                removed=client.register(u,expires=0);assert removed['code']==200 and r['requested'] not in removed['contacts'],'Exact unregister failed'
            collision=users[1]
            for values in [{'password':'wrong-fictional-secret'},{'aor':collision['auth']},{'from_realm':'unowned.invalid'},{'to':users[2]['number']},{'to_realm':'unowned.invalid'},{'realm':'unowned.invalid'},{'auth':users[0]['auth']}]:
                assert client.register(collision,**values)['code'] in (401,403,404),'Cross-user/realm identity accepted'
            f.record('native_'+transport+'_number_auth_collision_refresh_query_unregister_isolation',tuples=4,negative_cases=7,strict_tls=transport=='tls')
        finally:
            ledger+=client.ledger;client.close()
    sip=load_module('sip_trunk_live',f.source/'tests/sip_trunk_live.py')
    original=load_module('portable_source_phone',f.source/'tests/pbx_v20_restore_native.py')
    # Keep the imported peer's diagnostic destination private and portable.
    original.Path=lambda value: f.evidence/'last-invite-response.txt' if str(value)=='/var/lib/openwebpbx/restore-phone112/last-invite-response.txt' else Path(value)
    class Phone(original.SourcePhone):
        def __init__(self,u,transport='udp'):
            self.transport=transport;super().__init__(u,realm,bind)
            if transport!='udp':
                self.stopped=True;self.thread.join(2);self.socket.close()
                self.socket=SIPStream(bind,(bind,5061 if transport=='tls' else 5060),ca if transport=='tls' else None,'windowsqa.example.invalid')
                self.port=self.socket.sock.getsockname()[1];self.stopped=False;self.thread=threading.Thread(target=self.run,daemon=True);self.thread.start()
        def packet(self,*a,**kw):
            result=super().packet(*a,**kw)
            return result.replace(b'SIP/2.0/UDP',('SIP/2.0/'+self.transport.upper()).encode()).replace(f'@{self.ip}:{self.port}>'.encode(),f'@{self.ip}:{self.port};transport={self.transport}>'.encode())
        def response(self,*a,**kw):
            return super().response(*a,**kw).replace(f'@{self.ip}:{self.port}>'.encode(),f'@{self.ip}:{self.port};transport={self.transport}>'.encode())
    class G729Phone(Phone):
        def __init__(self,u,codec):self.codec=codec;super().__init__(u,'tls')
        def media(self,pt=18):
            state=super().media(18);state['codec_contexts']=self.codec.contexts();return state
        def sdp(self,state,offer=False):
            return (f'v=0\r\no=fixture 1 1 IN IP4 {self.ip}\r\ns=Independent G729 peer\r\nc=IN IP4 {self.ip}\r\nt=0 0\r\n'
                    f'm=audio {state["socket"].getsockname()[1]} RTP/AVP 18 101\r\na=rtpmap:18 G729/8000\r\na=fmtp:18 annexb=no\r\na=rtpmap:101 telephone-event/8000\r\na=sendrecv\r\n')
        def run(self):
            last=0
            while not self.stopped:
                try:
                    data,peer=self.socket.recvfrom(65535);text=data.decode(errors='replace');h=sip.headers(text);cid=h.get('call-id','')
                    if text.startswith('SIP/2.0 '):
                        if cid in self.queues:self.queues[cid].put((text,peer))
                    elif text.startswith('INVITE '):
                        state=self.dialogs.get(cid) or self.media();state['target']=self.target(text);state['incoming']={'headers':h,'peer':peer};self.dialogs[cid]=state
                        self.socket.sendto(self.response(200,h,self.sdp(state)),peer)
                    elif text.startswith('ACK '):
                        if cid in self.dialogs:self.dialogs[cid]['acked']=True
                    elif text.startswith(('BYE ','OPTIONS ','CANCEL ','INFO ','NOTIFY ')):
                        self.socket.sendto(self.response(200,h),peer)
                        if text.startswith(('BYE ','CANCEL ')) and cid in self.dialogs:self.dialogs[cid]['ended']=True
                except (socket.timeout,BlockingIOError):pass
                except OSError:
                    if not self.stopped:raise
                now=time.monotonic()
                if now-last<.02:continue
                last=now if last==0 or now-last>.2 else last+.02
                for state in list(self.dialogs.values()):
                    if state.get('ended') or not state['target']:continue
                    clock=state.setdefault('rtp_clock',0);sequence=state.setdefault('rtp_sequence',0)
                    samples=[int(6500*math.sin(2*math.pi*self.tone_hz*(clock+i)/8000)) for i in range(160)]
                    payload=self.codec.encode(state['codec_contexts'][0],samples)
                    state['socket'].sendto(struct.pack('!BBHII',0x80,18,sequence%65536,clock%4294967296,93)+payload,state['target'])
                    state['rtp_sequence']+=1;state['rtp_clock']+=160;state['sent']+=1;state['sent_first_at']=state['sent_first_at'] or now;state['sent_last_at']=now
                    while True:
                        try:
                            packet=state['socket'].recv(4096)
                            if len(packet)<12 or packet[0]&0xc0!=0x80:continue
                            if packet[1]&0x7f!=18:state['unexpected_audio']+=1;continue
                            size=12+(packet[0]&15)*4
                            if packet[0]&16:size+=4+struct.unpack('!H',packet[size+2:size+4])[0]*4
                            payload=packet[size:]
                            if packet[0]&32:payload=payload[:-payload[-1]]
                            state['decoded_pcm'].extend(self.codec.decode(state['codec_contexts'][1],payload));del state['decoded_pcm'][:-480000]
                            state['received']+=1;state['received_first_at']=state['received_first_at'] or now;state['received_last_at']=now
                        except BlockingIOError:break
        def close(self):
            super().close()
            for state in self.dialogs.values():self.codec.close(state['codec_contexts'])
    peers=[Phone(users[0],'tls'),Phone(users[1]),Phone(users[2])]
    caller,a,b=peers;destination=(bind,5061)
    def media(call,remote,seconds=5):
        time.sleep(seconds);sip.rtp_rate_check(call['media']);sip.rtp_rate_check(remote)
        return {'caller_decoded_ratio':original.decoded_tone_check(call['media'],a.tone_hz if remote in a.dialogs.values() else b.tone_hz),'peer_decoded_ratio':original.decoded_tone_check(remote,caller.tone_hz),'duration_seconds':seconds,'caller_packets':call['media']['received'],'peer_packets':remote['received']}
    def call_check(target,expected=a,digit=None):
        f.active_case={'8101':'basic_decoded_audio','8180':'simultaneous_ring_group','8181':'hunting_ring_group','8190':'queue_agent_delivery','8170':'ivr_wire_digit_or_timeout'}[target]
        old=set(expected.dialogs);call=caller.dial(target,destination);assert call['code']==200,'Native call was not answered'
        if digit is not None:caller.dtmf(call,digit)
        remote=f.wait(lambda:next((v for k,v in expected.dialogs.items() if k not in old and v.get('acked')),None))
        result=media(call,remote);caller.hangup(call);time.sleep(.3);return result
    try:
        for p in peers:assert p.register((bind,5061 if p.transport=='tls' else 5060))['code']==200
        f.record('native_tls_signalling_two_way_decoded_rtp',**call_check('8101'))
        f.active_case='independent_g729_pcmu_transcoding'
        codec=BCG729(f.s['private_state_root']);g729=G729Phone(users[0],codec)
        try:
            assert g729.register((bind,5061))['code']==200
            old=set(a.dialogs);call=g729.dial('8101',(bind,5061));assert call['code']==200 and call['media']['pt']==18,'Forced G729 offer was not negotiated'
            remote=f.wait(lambda:next((v for k,v in a.dialogs.items() if k not in old and v.get('acked')),None));assert remote['pt']==0,'Opposite leg did not stay PCMU'
            time.sleep(7);sip.rtp_rate_check(call['media']);sip.rtp_rate_check(remote)
            up=original.decoded_tone_check(remote,g729.tone_hz);down=original.decoded_tone_check(call['media'],a.tone_hz)
            g729.hangup(call);f.record('native_g729_pcmu_independent_codec_two_way_transcoding',g729_payload_type=18,opposite_payload_type=0,g729_decoded_ratio=down,pcmu_decoded_ratio=up,seconds=7)
        finally:
            ledger+=g729.registration_call_ids
            try:g729.register((bind,5061),expires=0)
            finally:g729.close();codec.search.close()
        f.record('native_simultaneous_ring_group',**call_check('8180'))
        f.record('native_hunting_ring_group',**call_check('8181'))
        f.record('native_queue_agent_first',**call_check('8190'))
        f.record('native_ivr_negotiated_wire_rfc2833',**call_check('8170',digit='2'))
        f.active_case='hold_selected_music_resume_transfer'
        old=set(a.dialogs);call=caller.dial('8101',destination);assert call['code']==200
        remote=f.wait(lambda:next((v for k,v in a.dialogs.items() if k not in old),None));media(call,remote)
        assert caller.hold(call,True)==200;time.sleep(10);music=f.music(bytes(remote['decoded_pcm']))
        assert caller.hold(call,False)==200;time.sleep(4);original.decoded_tone_check(remote,caller.tone_hz)
        before=set(b.dialogs);assert caller.blind_transfer(call,'8102') in (200,202)
        transferred=f.wait(lambda:next((v for k,v in b.dialogs.items() if k not in before and v.get('acked')),None));time.sleep(5)
        original.decoded_tone_check(transferred,a.tone_hz);a.hangup_incoming(next(k for k,v in a.dialogs.items() if v is remote))
        f.record('native_visible_sip_hold_selected_music_resume_transfer',**music)
        # Timer expires through the configured receptionist destination; no fake DTMF.
        started=time.monotonic();result=call_check('8170',expected=b);elapsed=time.monotonic()-started
        assert elapsed>=3.5 and elapsed<16,'Configured IVR timeout was not observed';f.record('native_configured_ivr_timeout',elapsed_seconds=round(elapsed,3),**result)
        # Queue-only pause/logout takes precedence, and the actual caller's
        # negotiated wire digit requests the durable callback.
        f.active_case='queue_pause_logout_wire_callback'
        f.web.agent('8101','break');f.web.agent('8102','logout')
        before_invites=(len(a.invites),len(b.invites));before_a=set(a.dialogs);before_c=set(caller.dialogs)
        waiting=caller.dial('8190',destination);assert waiting['code']==200;time.sleep(2)
        assert (len(a.invites),len(b.invites))==before_invites,'Paused/signed-out queue member was rung'
        caller.dtmf(waiting,'2')
        requested=f.wait(lambda:next((j for j in f.cli('status')['jobs'] if j['kind']=='callback'),None),12);job=requested['job_uuid']
        f.web.agent('8101','ready');f.web.agent('8102','ready')
        ar=f.wait(lambda:next((v for k,v in a.dialogs.items() if k not in before_a and v.get('acked')),None),90)
        cr=f.wait(lambda:next((v for k,v in caller.dialogs.items() if k not in before_c and k!=waiting['callid'] and v.get('acked')),None),25)
        time.sleep(5);original.decoded_tone_check(ar,caller.tone_hz);original.decoded_tone_check(cr,a.tone_hz)
        caller.hangup_incoming(next(k for k,v in caller.dialogs.items() if v is cr))
        f.wait(lambda:next((j for j in f.cli('status')['jobs'] if j['job_uuid']==job and j['state']=='completed'),None),15)
        f.record('native_queue_pause_logout_wire_callback_localservice_agent_first_decoded_rtp')
        f.active_case='hotel_wakeup_worker_wire_confirmation'
        wake=(datetime.now(timezone.utc)+timedelta(minutes=2)).strftime('%Y-%m-%dT%H:%M')
        f.web.submit('/app/pbx_setup/?view=hotel','hotel_action',{'hotel_action':'wakeup','number':'8102','timezone':'UTC','wake_at':wake})
        before=set(b.dialogs);f.cli('due')
        wr=f.wait(lambda:next((v for k,v in b.dialogs.items() if k not in before and v.get('acked')),None),25)
        incoming=wr['incoming'];h=incoming['headers'];wcall={'callid':h['call-id'],'seq':int(h['cseq'].split()[0]),'from':h['to']+';tag=localfixture','to':h['from'],'text':'SIP/2.0 200 OK\r\nContact: '+h['contact']+'\r\n\r\n'+b.sdp(wr),'peer':incoming['peer'],'uri':h['contact'].strip('<>'),'media':wr}
        # RFC2833 events are sent on the actual answered wake-up leg.
        wr.setdefault('dtmf_events',[]).append({'digit':1});time.sleep(3)
        f.wait(lambda:any(j['kind']=='wakeup' and j['state']=='completed' for j in f.cli('status')['jobs']),20)
        f.record('native_hotel_wakeup_localservice_claim_wire_confirmation')
        # Unregistered destination invokes the normal native voicemail recorder.
        f.active_case='native_voicemail_recording_and_email_queue'
        call=caller.dial('8103',destination);assert call['code']==200
        time.sleep(32);caller.hangup(call)
        voicemail=f.wait(lambda:f.cli('status')['voicemail'],20)
        file=Path(voicemail[-1]['message_path']);f.wait(lambda:file.exists() and file.stat().st_size>4096,15)
        with wave.open(str(file)) as wav:
            assert wav.getsampwidth()==2 and wav.getnchannels()==1
            raw=wav.readframes(wav.getnframes());rate=wav.getframerate()
        sample={'decoded_pcm':bytearray(raw)}
        if rate==8000:ratio=original.decoded_tone_check(sample,caller.tone_hz)
        else:raise AssertionError('Voicemail fixture unexpectedly changed negotiated rate')
        f.record('native_voicemail_recording_private_owned_wav',decoded_ratio=ratio,recording_sha256=hashlib.sha256(raw).hexdigest())
        f.wait(lambda:f.cli('status')['mail'],15)
    finally:
        for p in peers:
            ledger+=p.registration_call_ids
            try:p.register((bind,5061 if p.transport=='tls' else 5060),expires=0)
            finally:p.close()
        (f.evidence/'registration-ledger.json').write_text(json.dumps({'registration_ids':sorted(set(ledger))},indent=2))


def smtp_and_queued_voicemail(f):
    f.active_case='global_smtp_unconfigured_queue_preservation'
    module=load_module('smtp_fixture',f.source/'tests/smtp_transport_integration.py')
    with socketserver.ThreadingTCPServer(('127.0.0.1',0),module.SMTPFixture) as sink:
        sink.deliveries=[];sink.connections=[];sink.envelopes=[];sink.record_lock=threading.Lock();sink.daemon_threads=True
        worker=threading.Thread(target=sink.serve_forever,daemon=True);worker.start()
        try:
            f.cli('mail-seed');before=f.cli('status')['mail']
            subprocess.run([WINPS,'-NoProfile','-NonInteractive','-File','C:/OpenWebPBX/tools/Install-MailQueue.ps1','-Tick'],capture_output=True,check=True,timeout=110)
            assert f.cli('status')['mail']==before,'Unconfigured queue consumed retry/status'
            f.record('native_global_smtp_unconfigured_queue_preserves_attempts')
            f.active_case='native_voicemail_global_smtp_ip_attachment'
            values={'smtp_host':'127.0.0.1','smtp_port':str(sink.server_address[1]),'smtp_secure':'none','smtp_from':'pbx@example.invalid','smtp_from_name':'Fictional Windows PBX','smtp_reply_to':'reply@example.invalid','smtp_ip_whitelisted':'1','smtp_username':'','smtp_password':''}
            f.web.submit('/app/smtp_settings/','save',values)
            subprocess.run([WINPS,'-NoProfile','-NonInteractive','-File','C:/OpenWebPBX/tools/Install-MailQueue.ps1','-Tick'],capture_output=True,check=True,timeout=110)
            f.wait(lambda:len(sink.deliveries)>=2,15)
            messages=[BytesParser(policy=default).parsebytes(data) for _,data in sink.deliveries]
            assert all(str(m['From'])=='Fictional Windows PBX <pbx@example.invalid>' and str(m['Reply-To'])=='Fictional Windows PBX <reply@example.invalid>' for m in messages),'Global SMTP sender/reply identity not enforced'
            attachments=[part.get_payload(decode=True) for message in messages for part in message.walk() if part.get_content_disposition()=='attachment']
            assert any(x[:4]==b'RIFF' and x[8:12]==b'WAVE' and len(x)>4096 for x in attachments),'Actual native voicemail attachment missing'
            assert all(not auth and count==0 for auth,count in sink.connections),'IP SMTP performed AUTH'
            f.record('native_queued_voicemail_global_smtp_ip_auth_actual_loopback_attachment',messages=len(messages),attachment_sha256=hashlib.sha256(attachments[0]).hexdigest(),no_external_mail=True)
            f.active_case='global_smtp_password_auth'
            f.cli('mail-seed');values.update(smtp_ip_whitelisted='0',smtp_username='fixture-user',smtp_password='fixture-password')
            f.web.submit('/app/smtp_settings/','save',values)
            old=len(sink.deliveries);subprocess.run([WINPS,'-NoProfile','-NonInteractive','-File','C:/OpenWebPBX/tools/Install-MailQueue.ps1','-Tick'],capture_output=True,check=True,timeout=110)
            f.wait(lambda:len(sink.deliveries)>old,15);assert sink.deliveries[-1][0],'Global SMTP password AUTH failed'
            f.record('native_global_smtp_password_auth_actual_loopback')
        finally:sink.shutdown();worker.join(3)
    context=ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER);context.load_cert_chain(f.evidence/'fixture-leaf.pem',f.evidence/'fixture-key.pem')
    class TLSSink(socketserver.ThreadingTCPServer):
        def get_request(self):
            raw,address=super().get_request();return context.wrap_socket(raw,server_side=True),address
    with TLSSink(('127.0.0.1',0),module.SMTPFixture) as sink:
        sink.deliveries=[];sink.connections=[];sink.envelopes=[];sink.record_lock=threading.Lock();sink.daemon_threads=True
        worker=threading.Thread(target=sink.serve_forever,daemon=True);worker.start()
        try:
            f.active_case='global_smtp_trusted_tls_hostname_auth'
            values.update(smtp_host='windowsqa.example.invalid',smtp_port=str(sink.server_address[1]),smtp_secure='ssl')
            f.web.submit('/app/smtp_settings/','save',values)
            f.web.submit('/app/smtp_settings/','check',{})
            assert not sink.deliveries,'Saved connection check unexpectedly delivered mail'
            f.cli('mail-seed')
            subprocess.run([WINPS,'-NoProfile','-NonInteractive','-File','C:/OpenWebPBX/tools/Install-MailQueue.ps1','-Tick'],capture_output=True,check=True,timeout=110)
            f.wait(lambda:bool(sink.deliveries),15);assert sink.deliveries[-1][0],'Trusted SMTP TLS/AUTH failed'
            f.record('native_global_smtp_trusted_tls_hostname_auth_actual_loopback',no_external_mail=True)
        finally:sink.shutdown();worker.join(3)


def main():
    p=argparse.ArgumentParser();p.add_argument('--input',required=True);p.add_argument('--phase',choices=['prepare-pki','pki-server','acceptance'],required=True);a=p.parse_args();guard();f=Fixture(a.input)
    if a.phase=='prepare-pki':prepare_pki(f);return
    if a.phase=='pki-server':serve_pki(f);return
    try:
        f.web=Web(f.s['public_url'],f.evidence/'fixture-root.pem');normal_setup(f,f.web);native_calls(f);smtp_and_queued_voicemail(f);f.web.request('/logout.php')
        (f.evidence/'software-native-report.json').write_text(json.dumps({'state':'passed','checks':f.checks,'carrier':'unqualified','physical_devices':'unqualified','android_hardware':'unqualified','public_acme':'unqualified','scope':'fictional-hosted-runner'},indent=2))
    except BaseException as e:
        import traceback
        location=traceback.extract_tb(e.__traceback__)[-1]
        basename=Path(location.filename).name
        if basename not in ('windows-native-acceptance.py','pbx_v20_restore_native.py','sip_trunk_live.py'):
            basename='external_component'
        (f.evidence/'software-native-report.json').write_text(json.dumps({'state':'failed','checks':f.checks,'error_type':type(e).__name__,'error':str(e),'source_basename':basename,'source_line':location.lineno,'active_case':f.active_case},indent=2))
        raise

if __name__=='__main__':main()
