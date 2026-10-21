#!/usr/bin/env python3
"""SPDX-License-Identifier: AGPL-3.0-or-later.
Actual disposable Windows SIP/audio/HTTPS qualification. All identities are fictional.
No carrier endpoints, customer archives, TLS bypass or physical-device claims.
"""
import argparse, base64, ctypes, hashlib, http.cookiejar, http.server, importlib.util, json, math
import os, queue, re, secrets, socket, socketserver, ssl, stat, struct, subprocess, sys
import threading, time, urllib.error, urllib.parse, urllib.request, uuid, wave
from datetime import datetime, timedelta, timezone
from email.parser import BytesParser
from email.policy import default
from html.parser import HTMLParser
from pathlib import Path

WINPS=str(Path(os.environ.get('SystemRoot','C:/Windows'))/'System32/WindowsPowerShell/v1.0/powershell.exe')
FIXTURE_PHP_SOURCES={'windows-native-fixture.php','permissions.php','database.php','pbx_admin.php','pbx_setup.php','pbx_setup_provisioner.php','pbx_tenants.php','pbx_paths.php','pbx_mapper.php','pbx_schedule.php','pbx_operations.php','pbx_native.php','pbx_phone_auth.php','pbx_sip_domain.php','config.php','event_socket.php','cache.php','external_component'}
FIXTURE_ACTIONS={'baseline','discover','cleanup','status','queue-state','job','due','voicemail-login','api','mail-seed','meeting-path-state'}
FIXTURE_STAGES={'initialization','owned_service_lookup','realm_validation','admin_permissions','config_read','users_discovery','extension_update','policy_save','cache_refresh'}
NATIVE_SUBSTAGES={'native_case','g729_regular_unregister','g729_alternate_register','g729_invite','g729_answer_validation',
    'g729_remote_answer','g729_media','g729_peer_receiver','g729_hangup','g729_alternate_unregister',
    'g729_peer_close','g729_codec_close','g729_regular_reregister','native_peer_unregister','native_peer_close','native_ledger_write',
    'callback_request_created','callback_agent_answer','callback_target_answer','callback_job_completed','hotel_phone_answer','hotel_wire_confirmation','hotel_job_completed',
    'voicemail_message_created','voicemail_recording_finalized','voicemail_mail_queued',
    'mailbox_register','mailbox_invite','mailbox_login_prompt','mailbox_main_menu_prompt','mailbox_tutorial_complete','mailbox_recording_playback',
    'mailbox_forward_extension_prompt','mailbox_forward_intro_prompt','mailbox_forwarded_prompt',
    'mailbox_forwarded_message_created','mailbox_forwarded_binary_copy','mailbox_observer_close'}
MAILBOX_STAGES={stage for stage in NATIVE_SUBSTAGES if stage.startswith('mailbox_')}
MAILBOX_PROMPTS={'password':'vm-enter_pass.wav','tutorial':'vm-tutorial_yes_no.wav','main_menu':'vm-listen_new.wav',
    'forward_extension':'vm-forward_enter_ext.wav','forward_intro':'vm-forward_add_intro.wav',
    'forwarded':'vm-message_forwarded.wav','auth_failed':'vm-fail_auth.wav','mailbox_id':'vm-enter_id.wav','goodbye':'vm-goodbye.wav'}


class WindowsRtpSocket:
    """Keep a late UDP port-unreachable report from stopping SIP reception.

    Windows reports a previous UDP send's ICMP error at recv. It does not
    terminate the datagram socket. Only that exact Windows RTP condition is
    treated as an empty poll; actual packets, pacing and audio are still required.
    """
    def __init__(self,sock):self.socket=sock
    def __getattr__(self,name):return getattr(self.socket,name)
    def recv(self,*args,**kwargs):
        try:return self.socket.recv(*args,**kwargs)
        except ConnectionResetError as error:
            if os.name!='nt' or getattr(error,'winerror',None)!=10054:raise
            raise BlockingIOError('Previous UDP send reported a port unreachable') from error


def native_exception_fields(error,stage,prefix='primary'):
    import traceback
    frames=traceback.extract_tb(error.__traceback__)
    if not frames or stage not in NATIVE_SUBSTAGES:return {}
    allowed={'windows-native-acceptance.py','pbx_v20_restore_native.py','sip_trunk_live.py'}
    location=frames[-1]
    caller=next((frame for frame in reversed(frames) if Path(frame.filename).name=='windows-native-acceptance.py'),None)
    fields={prefix+'_error_type':type(error).__name__,prefix+'_substage':stage,
        prefix+'_source_basename':Path(location.filename).name if Path(location.filename).name in allowed else 'external_component',
        prefix+'_source_line':location.lineno}
    if caller:fields.update({prefix+'_caller_basename':'windows-native-acceptance.py',prefix+'_caller_line':caller.lineno})
    return fields


def native_cleanup(primary,stage,steps):
    """Run every owned cleanup without replacing the original native failure."""
    failures=[]
    for substage,operation in steps:
        try:operation()
        except BaseException as error:failures.append((substage,error))
    if primary is not None:
        facts=getattr(primary,'native_failure',None) or native_exception_fields(primary,stage)
        if failures:
            if 'cleanup_error_type' not in facts:facts.update(native_exception_fields(failures[0][1],failures[0][0],'cleanup'))
            facts['cleanup_failure_count']=facts.get('cleanup_failure_count',0)+len(failures)
        primary.native_failure=facts
    elif failures:
        failed_stage,error=failures[0]
        error.native_failure=native_exception_fields(error,failed_stage)
        error.native_failure['cleanup_failure_count']=len(failures)
        raise error


def fixture_failure(record,action):
    if not isinstance(record,dict) or record.get('schema')!=1 or record.get('action')!=action or action not in FIXTURE_ACTIONS or record.get('stage') not in FIXTURE_STAGES:
        return None
    if record.get('source_basename') not in FIXTURE_PHP_SOURCES or type(record.get('source_line')) is not int or not 0<record['source_line']<=100000 or not isinstance(record.get('error_type'),str) or not re.fullmatch(r'[A-Za-z0-9_]{1,80}',record['error_type']):
        return None
    return {'source_basename':record['source_basename'],'source_line':record['source_line'],'error_type':record['error_type'],
            'active_case':'fixture_php_'+action.replace('-','_')+'_'+record['stage']}


def g729_negotiation_failure(call):
    code=call.get('code');payload=call.get('media',{}).get('pt')
    if type(code) is int and code==200 and type(payload) is int and payload==18:return None
    failure=AssertionError('Forced G729 offer was not negotiated')
    failure.active_case='independent_g729_offer_refused' if code!=200 else 'independent_g729_answer_payload_mismatch'
    failure.sip_failure={}
    if type(code) is int and 200<=code<=699:failure.sip_failure['sip_response_code']=code
    challenges=call.get('digest_challenge_count')
    if type(challenges) is int and 0<=challenges<=3:failure.sip_failure['digest_challenge_count']=challenges
    if type(payload) is int and 0<=payload<=127:failure.sip_failure['negotiated_payload_type']=payload
    return failure


def audio_identity_failure(fields,user):
    matches={'owned_domain_matches':fields.get('domain_uuid')==user['domain_uuid'],
             'authentication_id_matches':fields.get('extension')==user['auth'],
             'sip_password_matches':fields.get('password')==user['password']}
    if all(matches.values()):return None
    failure=AssertionError('The audio form does not retain the fictional phone identity')
    failure.audio_failure=matches
    return failure


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
    def extension_codecs(self,user,codecs):
        assert codecs in ('PCMU','PCMU,G729') and re.fullmatch(r'[a-f0-9-]{36}',user['extension_uuid'])
        path='/app/extensions/extension_edit.php?id='+user['extension_uuid']
        status,_,text=self.request(path);assert status==200,'Normal extension audio form unavailable'
        forms=[form for form in Forms(text).forms if form['fields'].get('extension_uuid')==user['extension_uuid'] and 'absolute_codec_string' in form['fields']]
        assert len(forms)==1,'Normal administrator audio choice unavailable'
        fields=dict(forms[0]['fields'])
        failure=audio_identity_failure(fields,user)
        if failure:raise failure
        fields['absolute_codec_string']=codecs;fields['range']='1'
        status,_,text=self.request(forms[0]['action'] or path,fields);assert status==200,'Normal administrator audio save failed'
        forms=[form for form in Forms(text).forms if form['fields'].get('extension_uuid')==user['extension_uuid']]
        assert len(forms)==1 and forms[0]['fields'].get('absolute_codec_string')==codecs,'Normal administrator audio choice did not reload'
        failure=audio_identity_failure(forms[0]['fields'],user)
        if failure:raise failure


class NativePlayback:
    """Observe real native prompt events; send digits only on the SIP/RTP peer."""
    def __init__(self,settings,realm):
        assert settings['host'] in ('127.0.0.1','localhost') and 1<=int(settings['port'])<=65535
        password=settings['password'];assert password and '\n' not in password and '\r' not in password
        self.realm=realm;self.socket=socket.create_connection((settings['host'],int(settings['port'])),timeout=5)
        self.socket.settimeout(.5);self.buffer=b'';self.events=[];self.observed=[];self.lock=threading.Lock();self.stopped=False;self.error=None
        assert self.frame(5)[0].get('Content-Type')=='auth/request','Native event authentication challenge missing'
        self.socket.sendall(('auth '+password+'\n\n').encode())
        assert self.frame(5)[0].get('Reply-Text','').startswith('+OK'),'Native event authentication failed'
        self.socket.sendall(b'event plain PLAYBACK_START\n\n')
        assert self.frame(5)[0].get('Reply-Text','').startswith('+OK'),'Native playback event subscription failed'
        self.thread=threading.Thread(target=self.run,daemon=True);self.thread.start()
    def frame(self,seconds):
        end=time.monotonic()+seconds
        while not self.stopped and time.monotonic()<end:
            split=self.buffer.find(b'\n\n')
            if split>=0:
                headers=dict(line.split(': ',1) for line in self.buffer[:split].decode().splitlines() if ': ' in line)
                size=int(headers.get('Content-Length','0'));assert 0<=size<=1048576,'Native event exceeded its bound'
                if len(self.buffer)>=split+2+size:
                    body=self.buffer[split+2:split+2+size];self.buffer=self.buffer[split+2+size:]
                    return headers,body
            try:
                part=self.socket.recv(65536)
                if not part:raise RuntimeError('Native event connection closed')
                self.buffer+=part
            except socket.timeout:continue
        raise TimeoutError('Native event frame deadline expired')
    def run(self):
        try:
            while not self.stopped:
                try:headers,body=self.frame(1)
                except TimeoutError:continue
                if headers.get('Content-Type')!='text/event-plain':continue
                event={k:urllib.parse.unquote(v) for k,v in (line.split(': ',1) for line in body.decode().splitlines() if ': ' in line)}
                with self.lock:
                    assert len(self.observed)<1000,'Native event observations exceeded their bound'
                    self.observed.append({'callid':event.get('variable_sip_call_id'),
                        'domain_header_present':'variable_domain_name' in event,'domain_matches':event.get('variable_domain_name')==self.realm,
                        'event_name_matches':event.get('Event-Name')=='PLAYBACK_START','path_header_present':'Playback-File-Path' in event})
                    if event.get('Event-Name')!='PLAYBACK_START' or event.get('variable_domain_name')!=self.realm:continue
                    self.events.append(event)
                    assert len(self.events)<=1000,'Owned native prompt events exceeded their bound'
        except BaseException as error:
            if not self.stopped:self.error=error
    def prompt(self,callid,suffixes,after=-1,seconds=30):
        end=time.monotonic()+seconds
        while time.monotonic()<end:
            if self.error:raise self.error
            with self.lock:
                for index,event in enumerate(self.events):
                    if index<=after or event.get('variable_sip_call_id')!=callid:continue
                    path=event.get('Playback-File-Path','').replace('\\','/')
                    if any(path.endswith(suffix) for suffix in suffixes):return index,path
            time.sleep(.02)
        raise AssertionError('The actual owned native mailbox prompt was not observed')
    def snapshot(self,callid,recording_name):
        assert re.fullmatch(r'[a-f0-9]{24}@localfixture',callid)
        with self.lock:
            owned=[event for event in self.observed if event['callid']==callid]
            realm=[event for event in self.observed if event['domain_matches']]
            matched=[event for event in self.events if event.get('variable_sip_call_id')==callid]
            facts={'mailbox_observer_failed':self.error is not None,'mailbox_observed_event_count':len(self.observed),
                'mailbox_owned_event_count':len(owned),'mailbox_matched_event_count':len(matched),'mailbox_owned_call_seen':bool(owned),
                'mailbox_realm_event_count':len(realm),'mailbox_realm_call_id_header_present':any(event['callid'] is not None for event in realm)}
            for field in ('domain_header_present','domain_matches','event_name_matches','path_header_present'):
                facts['mailbox_owned_'+field]=any(event[field] for event in owned)
            seen=set()
            for event in matched:
                path=event.get('Playback-File-Path','').replace('\\','/')
                names={name for name,suffix in MAILBOX_PROMPTS.items() if path.endswith(suffix)}
                if path==recording_name or path.endswith('/'+recording_name):names.add('recording')
                seen.update(names or {'other'})
            for name in (*MAILBOX_PROMPTS,'recording','other'):facts['mailbox_prompt_'+name+'_seen']=name in seen
            return facts
    def close(self):
        self.stopped=True;self.socket.close();self.thread.join(2)


def mailbox_step(f,stage,operation):
    assert stage in MAILBOX_STAGES
    f.native_substage=stage
    try:return operation()
    except BaseException as error:
        if not getattr(error,'native_failure',None):error.native_failure=native_exception_fields(error,stage)
        raise


def mailbox_prompt(f,playback,call,stage,suffixes,after=-1,seconds=30):
    return mailbox_step(f,stage,lambda:playback.prompt(call['callid'],suffixes,after=after,seconds=seconds))


def mailbox_signalling(f,method,operation,flags):
    assert method in ('REGISTER','INVITE')
    name='register' if method=='REGISTER' else 'invite'
    flags['mailbox_sip_method']=method
    flags['mailbox_'+name+'_started']=True
    result=mailbox_step(f,'mailbox_'+name,operation)
    flags['mailbox_'+name+'_completed']=True
    code=result.get('code');challenges=result.get('digest_challenge_count')
    if type(code) is int and 200<=code<=699:flags['mailbox_'+name+'_response_code']=code
    if type(challenges) is int and 0<=challenges<=3:flags['mailbox_'+name+'_challenge_count']=challenges
    return result


def mailbox_peer_snapshot(phone):
    facts={}
    try:
        error=phone.receiver_failure
        facts['mailbox_receiver_failed']=error is not None
        if error is not None:
            kind=type(error).__name__
            allowed={'OSError','SSLError','SSLEOFError','SSLZeroReturnError','SSLWantReadError','SSLWantWriteError',
                     'ConnectionResetError','ConnectionAbortedError','BrokenPipeError','TimeoutError','RuntimeError',
                     'AssertionError','ValueError','KeyError'}
            facts['mailbox_receiver_error_type']=kind if kind in allowed else 'external_error'
        facts['mailbox_receiver_thread_alive']=bool(phone.thread.is_alive())
    except BaseException:pass
    try:
        if phone.transport in ('udp','tcp','tls'):facts['mailbox_transport']=phone.transport
        # A descriptor can stay open after remote EOF. Report these separately;
        # neither observation proves a usable TLS/account connection.
        facts['mailbox_transport_socket_open']=phone.socket.sock.fileno()>=0
        facts['mailbox_transport_eof_seen']=phone.socket.peer_closed
    except BaseException:pass
    return facts


def mailbox_menu(f,playback,phone,call,flags):
    # SIP authentication selects the caller's own mailbox through 121. A PIN
    # prompt is a regression, never an invitation to supply a stored credential.
    # Keep one 30s menu budget while skipping an optional first-login tutorial.
    deadline=time.monotonic()+30
    index,prompt=mailbox_prompt(f,playback,call,'mailbox_login_prompt',
        ['vm-enter_pass.wav','vm-fail_auth.wav','vm-tutorial_yes_no.wav','vm-listen_new.wav'])
    def require_menu_prompt():
        assert prompt.endswith(('vm-tutorial_yes_no.wav','vm-listen_new.wav')),'Authenticated own mailbox requested a retired PIN or rejected the phone identity'
    mailbox_step(f,'mailbox_login_prompt',require_menu_prompt)
    if prompt.endswith('vm-tutorial_yes_no.wav'):
        phone.dtmf(call,'2');flags['mailbox_tutorial_skip_sent']=True
        index,prompt=mailbox_prompt(f,playback,call,'mailbox_tutorial_complete',
            ['vm-enter_pass.wav','vm-fail_auth.wav','vm-listen_new.wav'],after=index,seconds=max(0,deadline-time.monotonic()))
        def require_main_menu():
            assert prompt.endswith('vm-listen_new.wav'),'Mailbox tutorial requested a retired PIN or rejected the phone identity'
        mailbox_step(f,'mailbox_tutorial_complete',require_main_menu)
    flags['mailbox_pin_free']=True
    return index



class Fixture:
    def __init__(self,input_path):
        self.path=Path(input_path); self.s=json.loads(self.path.read_text())
        self.evidence=Path(self.s['evidence_directory']); self.evidence.mkdir(exist_ok=True)
        self.source=Path(self.s['source_root']); self.php=Path('C:/OpenWebPBX/php/php.exe')
        self.script=self.source/'tests/windows-native-fixture.php'; self.checks=[]; self.active_case='fixture_initialization'
    def cli(self,action,*args,json_result=True):
        r=subprocess.run([str(self.php),str(self.script),action,str(self.path),*args],capture_output=True,text=True,timeout=35)
        if r.returncode:
            error=RuntimeError('Private fixture operation failed: '+action)
            if action in FIXTURE_ACTIONS:
                (self.evidence/('fixture-'+action+'.private.out')).write_text(r.stdout)
                (self.evidence/('fixture-'+action+'.private.err')).write_text(r.stderr)
                failure=Path(str(self.path)+'.'+action+'.failure.json')
                if failure.is_file() and not failure.is_symlink() and failure.stat().st_size<=2048:
                    try:error.fixture_failure=fixture_failure(json.loads(failure.read_text()),action)
                    except (ValueError,OSError):pass
            raise error
        return json.loads(r.stdout) if json_result else r.stdout.strip()
    def refresh(self): self.s=json.loads(self.path.read_text())
    def record(self,name,**facts):
        self.checks.append({'case':name,'passed':True,**facts})
        (self.evidence/'native-progress.json').write_text(json.dumps({'schema':1,'producer':'windows-native-acceptance.py','state':'running','checks':self.checks},indent=2))
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
        self.sock.settimeout(.005);self.buffer=b'';self.server=server;self.lock=threading.Lock();self.peer_closed=False
    def recvfrom(self,size):
        while True:
            if b'\r\n\r\n' in self.buffer:
                head=self.buffer.split(b'\r\n\r\n',1)[0];m=re.search(br'(?im)^Content-Length:\s*(\d+)',head);n=int(m.group(1)) if m else 0;end=len(head)+4+n
                if len(self.buffer)>=end:packet=self.buffer[:end];self.buffer=self.buffer[end:];return packet,self.server
            packet=self.sock.recv(size)
            if not packet:self.peer_closed=True;raise OSError('Native SIP stream ended')
            self.buffer+=packet
    def sendto(self,data,peer):
        with self.lock:self.sock.sendall(data)
    def close(self):self.sock.close()


def send_ivr_digit(phone,call,digit,wait):
    # This peer starts its RTP clock at zero. Emit actual audio before the
    # telephone event so an immediate key cannot use that inactive sentinel.
    wait(lambda:call['media']['sent']>0 and call['media'].get('rtp_clock',0)>0,seconds=3)
    assert phone.dtmf(call,digit),'Negotiated IVR key did not leave the peer'


def media_failure(error,peer,direction,seconds,view):
    first=view.get(direction+'_first_at');last=view.get(direction+'_last_at')
    span=last-first if first is not None and last is not None else 0
    packets=view[direction];rate=(packets-1)/span if packets>1 and span>0 else 0
    error.media_failure={'media_peer':peer,'media_direction':direction,'media_window_seconds':round(seconds,3),
        'media_span_seconds':round(span,6),'media_packets':packets,'media_rate_pps':round(rate,3)}
    return error


def bridged_media_window(states,seconds,rate_check):
    """Measure fresh bridged RTP, keeping prompt/wait history out of its rate."""
    assert .5<=seconds<=10 and math.isfinite(seconds),'Invalid bridged media observation interval'
    assert tuple(states)==('caller','destination'),'Exact owned media peers required'
    starts={peer:{direction:state[direction] for direction in ('sent','received')} for peer,state in states.items()}
    views={peer:{'sent':0,'received':0,'sent_first_at':None,'sent_last_at':None,
        'received_first_at':None,'received_last_at':None} for peer in states}
    # These are owned per-dialog buffers. Counters/clocks stay untouched so
    # their complete history remains available in the private failure report.
    for state in states.values():state['decoded_pcm'].clear()
    started=time.monotonic();deadline=started+seconds
    while True:
        for peer,state in states.items():
            for direction in ('sent','received'):
                count=state[direction]-starts[peer][direction]
                if count>views[peer][direction]:
                    stamp=state[direction+'_last_at']
                    if stamp is None or stamp<started:continue
                    if views[peer][direction+'_first_at'] is None:views[peer][direction+'_first_at']=stamp
                    views[peer][direction+'_last_at']=stamp;views[peer][direction]=count
        remaining=deadline-time.monotonic()
        if remaining<=0:break
        time.sleep(min(.005,remaining))
    finished=time.monotonic()
    for peer,state in states.items():
        view=views[peer];view['decoded_pcm']=bytes(state['decoded_pcm'])
        checking_rate=False
        try:
            for direction in ('sent','received'):
                assert view[direction+'_first_at'] is not None,'No new bridged RTP was observed'
                assert view[direction+'_first_at']<=started+.25,'Bridged RTP did not begin when the observation started'
                assert view[direction+'_last_at']>=finished-.25,'Bridged RTP stopped before the observation ended'
            checking_rate=True
            rate_check(view)  # Preserve the existing >=.3s and 30..70 packets/s limits.
        except AssertionError as error:
            if checking_rate:
                direction=next(d for d in ('sent','received') if view[d+'_last_at']-view[d+'_first_at']<.3 or
                    not 30<=(view[d]-1)/max(view[d+'_last_at']-view[d+'_first_at'],.000001)<=70)
            error=media_failure(error,peer,direction,seconds,view)
            error.media_window_private={'window':error.media_failure,'start_counts':starts[peer],
                'observation_started':started,'observation_finished':finished,
                'end_counts':{d:state[d] for d in ('sent','received')},
                'cumulative_first':{d:state[d+'_first_at'] for d in ('sent','received')},
                'cumulative_last':{d:state[d+'_last_at'] for d in ('sent','received')}}
            raise error
    return views


def queue_case_snapshot(f,peers,baseline,phase,call=None):
    """Only observe owned state; diagnostic failures cannot replace the call failure."""
    facts={};complete=True
    try:
        state=f.cli('queue-state',call['callid'] if call else '')
        assert isinstance(state,dict)
        facts.update({'queue_'+phase+'_'+key:value for key,value in state.items()})
    except BaseException:complete=False
    for label,peer in peers.items():
        try:
            previous=baseline[label];dialogs=list(peer.dialogs.items())
            fresh=[value for key,value in dialogs if key not in previous['dialogs']]
            prefix='queue_'+phase+'_'+label+'_'
            facts.update({prefix+'invites':len(peer.invites)-previous['invites'],
                prefix+'acks':sum(bool(value.get('acked')) for value in fresh),
                prefix+'ended':sum(bool(value.get('ended')) for value in fresh),
                prefix+'open_dialogs':sum(not value.get('ended',False) for key,value in dialogs),
                prefix+'receiver_failed':getattr(peer,'receiver_failure',None) is not None})
        except BaseException:complete=False
    return facts,complete


def declared_queue_tiers(f,call):
    # Check actual native rows after the declared first agent answers. A tied
    # accidental first answer must not qualify the configured priority order.
    state=f.cli('queue-state',call['callid'])
    assert state['config_matches'] and state['agent_bridged'],'The declared native queue was not bridged'
    assert (state['expected_tier_level'],state['expected_tier_position'],
            state['other_tier_level'],state['other_tier_position'])==(1,1,1,2),'The declared native queue tier order was lost'


def callback_wait(f,stage,predicate,seconds):
    assert stage in {'callback_request_created','callback_agent_answer','callback_target_answer','callback_job_completed'}
    try:return f.wait(predicate,seconds)
    except BaseException as error:
        error.native_failure=native_exception_fields(error,stage)
        raise


def voicemail_wait(f,stage,predicate,seconds):
    assert stage in {'voicemail_message_created','voicemail_recording_finalized','voicemail_mail_queued'}
    f.native_substage=stage
    try:return f.wait(predicate,seconds)
    except BaseException as error:
        if not getattr(error,'native_failure',None):error.native_failure=native_exception_fields(error,stage)
        raise


def voicemail_file_state(file):
    info=file.lstat()
    assert stat.S_ISREG(info.st_mode) and info.st_nlink==1 and not (getattr(info,'st_file_attributes',0)&0x400)
    finalized=False
    try:
        with file.open('rb') as stream:header=stream.read(12)
        if len(header)==12 and header[:4]==b'RIFF' and header[8:]==b'WAVE' and int.from_bytes(header[4:8],'little')+8==info.st_size:
            with wave.open(str(file)) as wav:
                finalized=0<wav.getnframes()*wav.getnchannels()*wav.getsampwidth()<=info.st_size-12
    except (EOFError,wave.Error):pass
    return info.st_size>4096,finalized


def voicemail_scan(f):
    # This is the fresh installer's exact storage/voicemail root. Never infer a
    # directory from an absent SQL row or follow a linked parent/file.
    realm=f.s['realm'];assert re.fullmatch(r'pbx-[a-f0-9]{12}\.[a-z0-9][a-z0-9.-]{0,240}',realm)
    directory=Path(f.s['private_state_root'])/'storage/voicemail/default'/realm/'8103'
    assert directory.is_absolute()
    empty={'wav_count':0,'wav_any_size_gt4096':False,'wav_any_header_finalized':False}
    for parent in [*reversed(directory.parents),directory]:
        if not parent.exists() and not parent.is_symlink():return directory,empty
        info=parent.lstat()
        assert stat.S_ISDIR(info.st_mode) and not (getattr(info,'st_file_attributes',0)&0x400)
    files=[]
    for index,file in enumerate(directory.iterdir()):
        assert index<64,'Owned mailbox scan exceeded its entry bound'
        info=file.lstat();assert not stat.S_ISLNK(info.st_mode) and not (getattr(info,'st_file_attributes',0)&0x400)
        if not re.fullmatch(r'msg_[a-fA-F0-9]{8}(?:-[a-fA-F0-9]{4}){3}-[a-fA-F0-9]{12}\.wav',file.name):continue
        files.append(voicemail_file_state(file))
    return directory,{'wav_count':len(files),'wav_any_size_gt4096':any(row[0] for row in files),'wav_any_header_finalized':any(row[1] for row in files)}


def voicemail_snapshot(f,phase,file=None):
    """Read only owned SQL counts and bounded recording-state booleans."""
    assert phase in {'before','after'}
    prefix='voicemail_'+phase+'_';facts={};complete=True
    try:
        status=f.cli('status');messages=status['voicemail'];mail=status['mail']
        assert isinstance(messages,list) and len(messages)<=64 and isinstance(mail,list) and len(mail)<=64
        owned=[row for row in messages if row.get('voicemail_id')=='8103']
        facts.update({prefix+'message_count':len(owned),prefix+'mail_count':len(mail)})
        directory,scan=voicemail_scan(f);facts.update({prefix+name:value for name,value in scan.items()})
        if file is None and owned:file=Path(owned[0]['message_path'])
        if file is None:return facts,complete  # No SQL row means no known exact file.
        assert file.parent==directory and re.fullmatch(r'msg_[a-fA-F0-9]{8}(?:-[a-fA-F0-9]{4}){3}-[a-fA-F0-9]{12}\.wav',file.name)
        try:file.lstat();exists=True
        except FileNotFoundError:exists=False
        facts.update({prefix+'recording_exists':exists,prefix+'recording_size_gt4096':False,prefix+'recording_header_finalized':False})
        if exists:
            large,finalized=voicemail_file_state(file)
            facts.update({prefix+'recording_size_gt4096':large,prefix+'recording_header_finalized':finalized})
    except BaseException:complete=False
    return facts,complete


def callback_job_facts(rows,job=None):
    """Classify owned SQL rows without publishing identities or raw results."""
    assert isinstance(rows,list) and len(rows)<=64
    rows=[row for row in rows if row.get('kind')=='callback' and row.get('queue_number')=='8190' and (job is None or row.get('job_uuid')==job)]
    facts={'job_count':len(rows),'job_state':'absent' if not rows else 'unknown'}
    if len(rows)!=1:return facts
    row=rows[0];state=row.get('state')
    if state in {'waiting','starting','calling','completed','failed','cancelled'}:facts['job_state']=state
    for field in ('attempts','max_attempts'):
        value=row.get(field)
        if type(value) is int and 0<=value<=1000:facts[field]=value
    for field in ('due','expired','lease_expired','has_lease'):
        value=row.get(field)
        if type(value) is bool:facts[field]=value
    facts['target_matches']=row.get('target_number')=='8100' and row.get('internal_target') is True
    facts['request_is_call']=isinstance(row.get('request_key'),str) and re.fullmatch(r'call/[a-f0-9-]{36}',row['request_key']) is not None
    facts['has_call_uuid']=isinstance(row.get('call_uuid'),str) and re.fullmatch(r'[a-f0-9-]{36}',row['call_uuid']) is not None
    classes={'':'unset','Waiting for office hours':'hours','Waiting for the queue':'queue','Waiting for an earlier caller':'earlier_caller',
        'Waiting for an agent':'agent','Waiting for an available agent and call route':'agent_or_route','Agent did not answer':'agent_no_answer',
        'Phone reconnected; retrying':'reconnected','Caller did not answer or no provider route was available':'caller_or_route',
        'Interrupted; rescheduled':'interrupted','Request expired':'expired','Queue callbacks are off':'disabled',
        'PBX phone domain is unavailable':'domain','Call could not be completed':'native_error','Connected':'connected'}
    facts['result_class']=classes.get(row.get('last_result') or '','unknown')
    return facts


def hotel_job_facts(rows):
    """Only fixed facts from this fixture's wake-up rows; no identifiers/results."""
    assert isinstance(rows,list) and len(rows)<=64
    rows=[row for row in rows if row.get('kind')=='wakeup']
    facts={'job_count':len(rows),'job_state':'absent' if not rows else 'unknown'}
    if len(rows)!=1:return facts
    row=rows[0]
    if row.get('state') in {'waiting','starting','calling','completed','failed','cancelled'}:facts['job_state']=row['state']
    facts['target_matches']=row.get('target_number')=='8102'
    for name in ('attempts','max_attempts'):
        if type(row.get(name)) is int and 0<=row[name]<=1000:facts[name]=row[name]
    for name in ('due','expired','lease_expired','has_lease'):
        if type(row.get(name)) is bool:facts[name]=row[name]
    facts['has_call_uuid']=isinstance(row.get('call_uuid'),str) and re.fullmatch(r'[a-f0-9-]{36}',row['call_uuid']) is not None
    results={'':'unset','Room is checked out':'room_checked_out','Room phone unavailable':'room_unavailable',
             'Waiting for an agent':'agent','Room did not answer':'room_no_answer','Phone reconnected; retrying':'reconnected',
             'Wake-up was not confirmed':'unconfirmed','Wake-up confirmed':'confirmed','Interrupted; rescheduled':'interrupted',
             'Request expired':'expired','PBX phone domain is unavailable':'domain','Call could not be completed':'native_error'}
    facts['result_class']=results.get(row.get('last_result') or '','unknown')
    return facts


def hotel_snapshot(f,peer,baseline,phase,event=None):
    facts={};complete=True;prefix='hotel_'+phase+'_';clock_started=None
    try:facts.update({prefix+key:value for key,value in hotel_job_facts(f.cli('status')['jobs']).items()})
    except BaseException:complete=False
    try:
        dialogs=[state for key,state in list(peer.dialogs.items()) if key not in baseline['dialogs']]
        assert len(dialogs)<=64
        invites=len(peer.invites)-baseline['invites'];assert 0<=invites<=64
        clock_started=any(type(state.get('rtp_clock')) is int and state['rtp_clock']>0 for state in dialogs)
        facts.update({prefix+'peer_invites':invites,prefix+'peer_acks':sum(bool(state.get('acked')) for state in dialogs),
                      prefix+'peer_ended':sum(bool(state.get('ended')) for state in dialogs),
                      prefix+'peer_open_dialogs':sum(not state.get('ended',False) for state in dialogs),
                      prefix+'peer_received_rtp':any(state.get('received',0)>0 for state in dialogs),
                      prefix+'peer_sent_rtp':any(state.get('sent',0)>0 for state in dialogs),
                      prefix+'peer_receiver_failed':getattr(peer,'receiver_failure',None) is not None})
    except BaseException:complete=False
    facts[prefix+'dtmf_attempted']=event is not None
    if event is not None:
        facts[prefix+'dtmf_completed']=event.get('completed') is True
        if type(clock_started) is bool:facts[prefix+'dtmf_clock_started']=clock_started
    return facts,complete


def hotel_wait(f,stage,predicate,seconds):
    assert stage in {'hotel_phone_answer','hotel_job_completed'}
    f.native_substage=stage
    try:return f.wait(predicate,seconds)
    except BaseException as error:
        if not getattr(error,'native_failure',None):error.native_failure=native_exception_fields(error,stage)
        raise


def callback_snapshot(f,peers,baseline,phase,call=None,job=None,previous_success=None):
    facts,complete=queue_case_snapshot(f,peers,baseline,phase,call);prefix='callback_'+phase+'_';success=None
    try:
        rows=f.cli('status')['jobs'];classified=callback_job_facts(rows,job)
        facts.update({prefix+key:value for key,value in classified.items()})
        if classified.get('has_call_uuid'):
            row=next(row for row in rows if row.get('kind')=='callback' and row.get('queue_number')=='8190' and (job is None or row.get('job_uuid')==job))
            facts[prefix+'call_uuid_alive']=f.cli('api','uuid_exists '+row['call_uuid'],json_result=False)=='true'
    except BaseException:complete=False
    try:
        with urllib.request.urlopen('http://127.0.0.1:8087/health',timeout=2) as response:
            raw=response.read(4097);assert len(raw)<=4096;health=json.loads(raw)
        state=health.get('state');assert state in {'Starting','Running','Connection unavailable','Setup required'}
        success=health.get('lastSuccess');assert success is None or isinstance(success,str) and len(success)<=64
        facts.update({prefix+'worker_state':state,prefix+'last_success_present':success is not None,
            prefix+'last_success_advanced':success is not None and previous_success is not None and success!=previous_success})
        facts[prefix+'jobs_held']=(Path(f.s['private_state_root'])/'backup-restore/hold-jobs').exists()
        pause=f.cli('api','fsctl pause_check',json_result=False)
        facts[prefix+'pause_state']={'true':'paused','false':'active'}.get(pause,'unknown')
    except BaseException:complete=False
    return facts,complete,success


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
    for index,codecs in [(0,'PCMU,G729'),(1,'PCMU')]:
        f.active_case='normal_admin_owned_extension_audio_preferences'
        user=f.s['users'][index];web.extension_codecs(user,codecs)
        actual=f.cli('status')['extension_codec_preferences'][user['auth']]
        assert actual['extension_uuid']==user['extension_uuid'] and actual['absolute_codec_string']==codecs and actual['password_sha256']==hashlib.sha256(user['password'].encode()).hexdigest(),'Normal audio save changed the owned tuple or preference'
    f.record('normal_admin_https_csrf_explicit_caller_pcmu_g729_and_peer_pcmu_identity_preserved')
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
    assert len(status['registration_limits'])==4 and all(int(value)==1 for value in status['registration_limits']),'The real guided registration limit must stay at one'
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
    # Keep both numerical-collision accounts active. A quota must count its
    # directory-owned authentication identity, preserving the configured one
    # contact limit and excluding only its own refresh Call-ID.
    for transport in ['udp','tcp','tls']:
        for order in [(1,2),(2,1)]:
            f.active_case='native_'+transport+'_canonical_registration_quota_'+str(order[0])+str(order[1])
            clients=[SIPClient(transport,bind,(bind,5061 if transport=='tls' else 5060),realm,ca,'windowsqa.example.invalid') for _ in range(3)]
            first,second,extra=clients;one,two=users[order[0]],users[order[1]]
            def present(user):return not f.cli('api','sofia_contact '+user['auth']+'@'+realm,json_result=False).startswith('error/')
            try:
                assert first.register(one)['code']==200 and second.register(two)['code']==200,'Canonical identity collision corrupted another account quota'
                assert first.register(one,reuse=True)['code']==200 and second.register(two,reuse=True)['code']==200,'Same-Call-ID refresh counted as another contact'
                assert present(one) and present(two),'Both canonical contacts were not stored independently'
                assert extra.register(one)['code']==403,'Same-account second contact bypassed the configured limit'
                assert extra.register(one,password='wrong-fictional-secret')['code'] in (401,403),'Wrong password bypassed authentication'
                assert extra.register(one,auth=two['auth'],password=two['password'])['code'] in (401,403,404),'Cross-pair credentials bypassed the directory guard'
                assert present(one) and present(two),'A refused registration removed an accepted contact'
                assert first.register(one,expires=0)['code']==200 and not present(one) and present(two),'Exact unregister removed the other canonical account'
                assert second.register(two,expires=0)['code']==200 and not present(two),'Exact unregister left its own canonical contact'
                f.record('native_'+transport+'_canonical_registration_quota_both_order_'+str(order[0])+str(order[1]),limit=1,distinct_accounts=2,extra_contact_refused=True,refresh_and_unregister=True,wrong_and_cross_auth_refused=True)
            finally:
                try:
                    first.register(one,expires=0);second.register(two,expires=0)
                finally:
                    for client in clients:ledger+=client.ledger;client.close()
    sip=load_module('sip_trunk_live',f.source/'tests/sip_trunk_live.py')
    original=load_module('portable_source_phone',f.source/'tests/pbx_v20_restore_native.py')
    # Keep the imported peer's diagnostic destination private and portable.
    original.Path=lambda value: f.evidence/'last-invite-response.txt' if str(value)=='/var/lib/openwebpbx/restore-phone112/last-invite-response.txt' else Path(value)
    class Phone(original.SourcePhone):
        def __init__(self,u,transport='udp'):
            self.transport=transport;self.registration_packets=[];self.receiver_failure=None;super().__init__(u,realm,bind)
            if transport!='udp':
                self.stopped=True;self.thread.join(2);self.socket.close()
                self.socket=SIPStream(bind,(bind,5061 if transport=='tls' else 5060),ca if transport=='tls' else None,'windowsqa.example.invalid')
                self.port=self.socket.sock.getsockname()[1];self.stopped=False;self.thread=threading.Thread(target=self.run,daemon=True);self.thread.start()
        def packet(self,*a,**kw):
            result=super().packet(*a,**kw)
            result=result.replace(b'SIP/2.0/UDP',('SIP/2.0/'+self.transport.upper()).encode()).replace(f'@{self.ip}:{self.port}>'.encode(),f'@{self.ip}:{self.port};transport={self.transport}>'.encode())
            if a and a[0]=='REGISTER':
                self.registration_packets.append(result)
                assert len(self.registration_packets)<=20,'Owned registration trace exceeded its bound'
            return result
        def response(self,*a,**kw):
            return super().response(*a,**kw).replace(f'@{self.ip}:{self.port}>'.encode(),f'@{self.ip}:{self.port};transport={self.transport}>'.encode())
        def media(self,pt=0):
            state=super().media(pt)
            if os.name=='nt':state['socket']=WindowsRtpSocket(state['socket'])
            return state
        def run(self):
            try:self.run_media()
            except BaseException as error:self.receiver_failure=error
        def run_media(self):super().run()
        def check_receiver(self):
            if self.receiver_failure is not None:raise self.receiver_failure
        def exchange(self,*args,**kwargs):
            self.check_receiver()
            try:return super().exchange(*args,**kwargs)
            except BaseException:
                self.check_receiver();raise
    class G729Phone(Phone):
        def __init__(self,u,codec):self.codec=codec;self.invite_packets=[];super().__init__(u,'tls')
        def packet(self,*args,**kwargs):
            result=super().packet(*args,**kwargs)
            if args and args[0]=='INVITE':
                self.invite_packets.append(result);assert len(self.invite_packets)<=4 and sum(map(len,self.invite_packets))<=262144,'Owned G729 INVITE trace exceeded its bound'
                (f.evidence/'g729-invite-requests.private.bin').write_bytes(b'\n\n'.join(self.invite_packets))
            return result
        def media(self,pt=18):
            state=super().media(18);state['codec_contexts']=self.codec.contexts();return state
        def sdp(self,state,offer=False):
            return (f'v=0\r\no=fixture 1 1 IN IP4 {self.ip}\r\ns=Independent G729 peer\r\nc=IN IP4 {self.ip}\r\nt=0 0\r\n'
                    f'm=audio {state["socket"].getsockname()[1]} RTP/AVP 18 101\r\na=rtpmap:18 G729/8000\r\na=fmtp:18 annexb=no\r\na=ptime:20\r\na=maxptime:20\r\na=rtpmap:101 telephone-event/8000\r\na=sendrecv\r\n')
        def run_media(self):
            last=0
            while not self.stopped:
                try:
                    data,peer=self.socket.recvfrom(65535);text=data.decode(errors='replace');h=sip.headers(text);cid=h.get('call-id','')
                    if text.startswith('SIP/2.0 '):
                        trace=f.evidence/'g729-sip-responses.private.bin'
                        if not trace.exists() or trace.stat().st_size+len(data)<=262144:
                            with trace.open('ab') as output:output.write(data+b'\n\n')
                        self.receive_response(text,peer)
                    elif text.startswith('INVITE '):
                        state=self.dialogs.get(cid) or self.media();state['target']=self.target(text);state['incoming']={'headers':h,'peer':peer};self.dialogs[cid]=state
                        self.send_invite_response(self.response(200,h,self.sdp(state)),h,peer)
                    elif text.startswith('ACK '):
                        self.acknowledge_invite(h)
                    elif text.startswith(('BYE ','OPTIONS ','CANCEL ','INFO ','NOTIFY ')):
                        self.socket.sendto(self.response(200,h),peer)
                        if text.startswith(('BYE ','CANCEL ')) and cid in self.dialogs:self.dialogs[cid]['ended']=True
                except (socket.timeout,BlockingIOError):pass
                except OSError:
                    if not self.stopped:raise
                self.service_sip_transactions()
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
                            try:decoded=self.codec.decode(state['codec_contexts'][1],payload)
                            except BaseException:
                                (f.evidence/'g729-last-rtp.private.bin').write_bytes(packet);raise
                            if state['received']==0:(f.evidence/'g729-first-rtp.private.bin').write_bytes(packet)
                            state['decoded_pcm'].extend(decoded);del state['decoded_pcm'][:-480000]
                            state['received']+=1;state['received_first_at']=state['received_first_at'] or now;state['received_last_at']=now
                        except BlockingIOError:break
        def close(self):
            super().close()
            for state in self.dialogs.values():self.codec.close(state['codec_contexts'])
    peers=[Phone(users[0],'tls'),Phone(users[1]),Phone(users[2])]
    caller,a,b=peers;destination=(bind,5061)
    def media(call,remote,seconds=5):
        views=bridged_media_window({'caller':call['media'],'destination':remote},seconds,sip.rtp_rate_check)
        ratios={}
        for peer,frequency in [('caller',a.tone_hz if remote in a.dialogs.values() else b.tone_hz),('destination',caller.tone_hz)]:
            try:ratios[peer]=original.decoded_tone_check(views[peer],frequency)
            except AssertionError as error:raise media_failure(error,peer,'received',seconds,views[peer])
        return {'caller_decoded_ratio':ratios['caller'],'peer_decoded_ratio':ratios['destination'],'duration_seconds':seconds,'caller_packets':views['caller']['received'],'peer_packets':views['destination']['received']}
    def call_check(target,expected=a,digit=None):
        f.active_case={'8101':'basic_decoded_audio','8180':'simultaneous_ring_group','8181':'hunting_ring_group','8190':'queue_agent_delivery','8170':'ivr_wire_digit_or_timeout'}[target]
        observed={'expected':a,'other':b};baseline={label:{'dialogs':set(peer.dialogs),'invites':len(peer.invites)} for label,peer in observed.items()}
        facts={};complete=True;call=None
        if target=='8190':facts,complete=queue_case_snapshot(f,observed,baseline,'before')
        try:
            old=set(expected.dialogs);call=caller.dial(target,destination);assert call['code']==200,'Native call was not answered'
            if digit is not None:send_ivr_digit(caller,call,digit,f.wait)
            remote=f.wait(lambda:next((v for k,v in expected.dialogs.items() if k not in old and v.get('acked')),None))
            if target=='8190':declared_queue_tiers(f,call)
            result=media(call,remote);caller.hangup(call);time.sleep(.3);return result
        except BaseException as error:
            if target=='8190':
                after,finished=queue_case_snapshot(f,observed,baseline,'after',call);facts.update(after)
                facts['queue_diagnostics_complete']=complete and finished;error.queue_failure=facts
            raise
    try:
        for index,p in enumerate(peers):
            f.active_case='native_media_peer_'+p.transport+'_registration_'+str(index)
            result=p.register((bind,5061 if p.transport=='tls' else 5060))
            if result['code']!=200:
                (f.evidence/('media-peer-'+str(index)+'-registration.private.txt')).write_text(result.get('text',''))
                (f.evidence/('media-peer-'+str(index)+'-requests.private.bin')).write_bytes(b'\n\n'.join(p.registration_packets))
                failure=RuntimeError('The independent media peer registration failed')
                failure.sip_failure={'sip_response_code':int(result['code']),'digest_challenge_count':int(result.get('digest_challenge_count',0))}
                raise failure
        f.record('native_tls_signalling_two_way_decoded_rtp',**call_check('8101'))
        f.active_case='independent_g729_pcmu_transcoding'
        (f.evidence/'g729-profile.private.txt').write_text(f.cli('api','sofia status profile internal',json_result=False))
        (f.evidence/'g729-implementations.private.json').write_text(f.cli('api','show codecs as json',json_result=False))
        codec=BCG729(f.s['private_state_root']);g729=G729Phone(users[0],codec)
        try:
            # The guided account permits one contact. Replace the regular
            # caller explicitly for this alternate-codec call, then restore it.
            f.native_substage='g729_regular_unregister';assert caller.register((bind,5061),expires=0)['code']==200
            f.native_substage='g729_alternate_register';assert g729.register((bind,5061))['code']==200
            f.native_substage='g729_invite';old=set(a.dialogs);call=g729.dial('8101',(bind,5061))
            f.native_substage='g729_answer_validation'
            assert len(call.get('text',''))<=1048576,'Owned G729 response exceeded its bound'
            (f.evidence/'g729-invite-response.private.txt').write_text(call.get('text',''))
            failure=g729_negotiation_failure(call)
            if failure:f.active_case=failure.active_case;raise failure
            f.native_substage='g729_remote_answer';remote=f.wait(lambda:next((v for k,v in a.dialogs.items() if k not in old and v.get('acked')),None));assert remote['pt']==0,'Opposite leg did not stay PCMU'
            f.native_substage='g729_media';time.sleep(7)
            if g729.receiver_failure is not None:f.native_substage='g729_peer_receiver';g729.check_receiver()
            sip.rtp_rate_check(call['media']);sip.rtp_rate_check(remote)
            up=original.decoded_tone_check(remote,g729.tone_hz);down=original.decoded_tone_check(call['media'],a.tone_hz)
            f.native_substage='g729_hangup';g729.hangup(call);f.record('native_g729_pcmu_independent_codec_two_way_transcoding',g729_payload_type=18,opposite_payload_type=0,g729_decoded_ratio=down,pcmu_decoded_ratio=up,seconds=7)
        finally:
            ledger+=g729.registration_call_ids
            def alternate_unregister():assert g729.register((bind,5061),expires=0)['code']==200
            def regular_reregister():assert caller.register((bind,5061))['code']==200
            native_cleanup(sys.exc_info()[1],getattr(f,'native_substage','g729_media'),[
                ('g729_alternate_unregister',alternate_unregister),('g729_peer_close',g729.close),
                ('g729_codec_close',codec.search.close),('g729_regular_reregister',regular_reregister)])
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
        observed={'expected':a,'other':b,'target':caller}
        baseline={label:{'dialogs':set(peer.dialogs),'invites':len(peer.invites)} for label,peer in observed.items()}
        facts,complete,health=callback_snapshot(f,observed,baseline,'before');waiting=None;job=None
        facts['callback_wire_digit_emitted']=False
        try:
            before_invites=(len(a.invites),len(b.invites));before_a=set(a.dialogs);before_c=set(caller.dialogs)
            waiting=caller.dial('8190',destination);assert waiting['code']==200;time.sleep(2)
            assert (len(a.invites),len(b.invites))==before_invites,'Paused/signed-out queue member was rung'
            caller.dtmf(waiting,'2');facts['callback_wire_digit_emitted']=True
            facts['callback_wire_sent_rtp']=waiting['media']['sent']>0;facts['callback_wire_received_rtp']=waiting['media']['received']>0
            requested=callback_wait(f,'callback_request_created',lambda:next((j for j in f.cli('status')['jobs'] if j['kind']=='callback'),None),12);job=requested['job_uuid']
            f.web.agent('8101','ready');f.web.agent('8102','ready')
            ar=callback_wait(f,'callback_agent_answer',lambda:next((v for k,v in a.dialogs.items() if k not in before_a and v.get('acked')),None),90)
            cr=callback_wait(f,'callback_target_answer',lambda:next((v for k,v in caller.dialogs.items() if k not in before_c and k!=waiting['callid'] and v.get('acked')),None),25)
            time.sleep(5);original.decoded_tone_check(ar,caller.tone_hz);original.decoded_tone_check(cr,a.tone_hz)
            caller.hangup_incoming(next(k for k,v in caller.dialogs.items() if v is cr))
            callback_wait(f,'callback_job_completed',lambda:next((j for j in f.cli('status')['jobs'] if j['job_uuid']==job and j['state']=='completed'),None),15)
            f.record('native_queue_pause_logout_wire_callback_localservice_agent_first_decoded_rtp')
        except BaseException as error:
            after,finished,_=callback_snapshot(f,observed,baseline,'after',waiting,job,health);facts.update(after)
            facts['queue_diagnostics_complete']=complete and finished;error.queue_failure=facts
            raise
        f.active_case='hotel_wakeup_worker_wire_confirmation'
        wake=(datetime.now(timezone.utc)+timedelta(minutes=2)).strftime('%Y-%m-%dT%H:%M')
        f.web.submit('/app/pbx_setup/?view=hotel','hotel_action',{'hotel_action':'wakeup','number':'8102','timezone':'UTC','wake_at':wake})
        before=set(b.dialogs);baseline={'dialogs':before,'invites':len(b.invites)};event=None
        facts,complete=hotel_snapshot(f,b,baseline,'before')
        try:
            due=f.cli('due')
            value=due.get('owned_wakeup_updated_count')
            if type(value) is int and 0<=value<=64:facts['hotel_due_update_count']=value
            wr=hotel_wait(f,'hotel_phone_answer',lambda:next((v for k,v in b.dialogs.items() if k not in before and v.get('acked')),None),25)
            # Reuse the actual wire helper: ACK alone does not establish this
            # peer's RTP clock, and timestamp zero is native's inactive sentinel.
            f.native_substage='hotel_wire_confirmation';event={'completed':False}
            offer=next((invite['sdp'] for invite in reversed(b.invites) if invite['callid']==wr['incoming']['headers']['call-id']),None)
            assert offer is not None,'The owned wake-up SDP offer is missing'
            send_ivr_digit(b,{'text':offer,'media':wr},'1',f.wait)
            event['completed']=True;time.sleep(3)
            hotel_wait(f,'hotel_job_completed',lambda:any(j['kind']=='wakeup' and j['state']=='completed' for j in f.cli('status')['jobs']),20)
            f.record('native_hotel_wakeup_localservice_claim_wire_confirmation')
        except BaseException as error:
            after,finished=hotel_snapshot(f,b,baseline,'after',event);facts.update(after)
            facts['hotel_diagnostics_complete']=complete and finished;error.hotel_failure=facts
            if not getattr(error,'native_failure',None):error.native_failure=native_exception_fields(error,getattr(f,'native_substage','native_case'))
            raise
        # Unregistered destination invokes the normal native voicemail recorder.
        f.active_case='native_voicemail_recording_and_email_queue'
        facts,complete=voicemail_snapshot(f,'before');file=None
        try:
            call=caller.dial('8103',destination);assert call['code']==200
            time.sleep(32);caller.hangup(call)
            voicemail=voicemail_wait(f,'voicemail_message_created',lambda:next((m for m in f.cli('status')['voicemail'] if m['voicemail_id']=='8103'),None),20)
            file=Path(voicemail['message_path']);voicemail_wait(f,'voicemail_recording_finalized',lambda:file.exists() and file.stat().st_size>4096,15)
            with wave.open(str(file)) as wav:
                assert wav.getsampwidth()==2 and wav.getnchannels()==1
                raw=wav.readframes(wav.getnframes());rate=wav.getframerate()
            sample={'decoded_pcm':bytearray(raw)}
            if rate==8000:ratio=original.decoded_tone_check(sample,caller.tone_hz)
            else:raise AssertionError('Voicemail fixture unexpectedly changed negotiated rate')
            f.record('native_voicemail_recording_private_owned_wav',decoded_ratio=ratio,recording_sha256=hashlib.sha256(raw).hexdigest())
            voicemail_wait(f,'voicemail_mail_queued',lambda:f.cli('status')['mail'],15)
        except BaseException as error:
            after,finished=voicemail_snapshot(f,'after',file);facts.update(after)
            facts['voicemail_diagnostics_complete']=complete and finished;error.voicemail_failure=facts
            stage=getattr(f,'native_substage',None)
            if stage in {'voicemail_message_created','voicemail_recording_finalized','voicemail_mail_queued'} and not getattr(error,'native_failure',None):error.native_failure=native_exception_fields(error,stage)
            raise
        # Retrieve that real recording through authenticated 121 and forward it with wire
        # RFC2833. Native playback events synchronize actual menu prompts;
        # they never inject digits or bypass the mailbox authentication.
        f.active_case='native_voicemail_wire_forwarding_binary_copy'
        f.native_substage='native_case'
        mailbox_info=f.cli('voicemail-login')
        assert mailbox_info['pin_free'] is True and mailbox_info['mailbox_number']=='8103' and mailbox_info['voicemail_dial']=='121'
        assert not any(key in mailbox_info for key in ('pin','voicemail_pin','voicemail_password'))
        playback=NativePlayback(mailbox_info['event_socket'],realm)
        mailbox=Phone(users[3],'tls');peers.append(mailbox)
        retrieve=None;flags={'mailbox_pin_free':False,'mailbox_tutorial_skip_sent':False,
            'mailbox_forward_destination_sent':False,'mailbox_forward_no_intro_sent':False,
            'mailbox_register_started':False,'mailbox_register_completed':False,
            'mailbox_invite_started':False,'mailbox_invite_completed':False}
        try:
            registered=mailbox_signalling(f,'REGISTER',lambda:mailbox.register((bind,5061)),flags)
            assert registered['code']==200
            retrieve=mailbox_signalling(f,'INVITE',lambda:mailbox.dial('121',(bind,5061)),flags)
            assert retrieve['code']==200
            index=mailbox_menu(f,playback,mailbox,retrieve,flags)
            mailbox.dtmf(retrieve,'1')
            index,_=mailbox_prompt(f,playback,retrieve,'mailbox_recording_playback',[file.name],after=index,seconds=45)
            time.sleep(3);original.decoded_tone_check(retrieve['media'],caller.tone_hz)
            mailbox.dtmf(retrieve,'8')
            index,_=mailbox_prompt(f,playback,retrieve,'mailbox_forward_extension_prompt',['vm-forward_enter_ext.wav'],after=index)
            for digit in '8102#':mailbox.dtmf(retrieve,digit)
            flags['mailbox_forward_destination_sent']=True
            index,_=mailbox_prompt(f,playback,retrieve,'mailbox_forward_intro_prompt',['vm-forward_add_intro.wav'],after=index)
            mailbox.dtmf(retrieve,'2');flags['mailbox_forward_no_intro_sent']=True
            index,_=mailbox_prompt(f,playback,retrieve,'mailbox_forwarded_prompt',['vm-message_forwarded.wav'],after=index)
            forwarded=mailbox_step(f,'mailbox_forwarded_message_created',lambda:f.wait(lambda:next((m for m in f.cli('status')['voicemail'] if m['voicemail_id']=='8102'),None),15))
            forwarded_file=Path(forwarded['message_path'])
            f.native_substage='mailbox_forwarded_binary_copy'
            assert forwarded_file.is_file() and forwarded_file.read_bytes()==file.read_bytes(),'Native forwarded WAV did not preserve exact source bytes'
            prompts=playback.snapshot(retrieve['callid'],file.name)
            assert not prompts['mailbox_prompt_password_seen'] and not prompts['mailbox_prompt_auth_failed_seen'],'Authenticated mailbox requested a PIN or rejected its owner'
            mailbox.hangup(retrieve)
            f.record('native_tls_mailbox_wire_forwarding_exact_binary_wav',wire_digits='RFC2833',source_and_forwarded_sha256=hashlib.sha256(file.read_bytes()).hexdigest(),drive_letter_path_verified=bool(re.match(r'^[A-Za-z]:[/\\]',str(file))),path_spaces_observed=' ' in str(file),bytes=forwarded_file.stat().st_size)
        except BaseException as error:
            facts={**flags,**mailbox_peer_snapshot(mailbox),'mailbox_diagnostics_complete':False}
            try:
                facts.update(playback.snapshot(retrieve['callid'],file.name))
                facts['mailbox_dialog_ended']=bool(retrieve['media'].get('ended'))
                facts['mailbox_received_rtp']=retrieve['media']['received']>0
                facts['mailbox_diagnostics_complete']=True
            except BaseException:pass
            error.mailbox_failure=facts
            stage=getattr(f,'native_substage','native_case')
            if stage in MAILBOX_STAGES and not getattr(error,'native_failure',None):error.native_failure=native_exception_fields(error,stage)
            raise
        finally:native_cleanup(sys.exc_info()[1],getattr(f,'native_substage','native_case'),[('mailbox_observer_close',playback.close)])
    finally:
        steps=[]
        for p in peers:
            ledger+=p.registration_call_ids
            steps.extend([('native_peer_unregister',lambda p=p:p.register((bind,5061 if p.transport=='tls' else 5060),expires=0)),('native_peer_close',p.close)])
        steps.append(('native_ledger_write',lambda:(f.evidence/'registration-ledger.json').write_text(json.dumps({'registration_ids':sorted(set(ledger))},indent=2))))
        stage=getattr(f,'native_substage','g729_media') if f.active_case.startswith('independent_g729_') else 'native_case'
        native_cleanup(sys.exc_info()[1],stage,steps)


def smtp_tick_fields(result):
    facts={'smtp_tick_outcome':'unrecognized'}
    if type(result.returncode) is int and -(2**31)<=result.returncode<2**31:facts['smtp_tick_exit']=result.returncode
    if result.returncode:
        facts['smtp_tick_outcome']='command_failed';return facts
    try:
        assert len(result.stdout)<=4096
        row=json.loads(result.stdout)
        assert type(row) is dict
        if set(row)=={'deferred','reason'} and row.get('deferred') is True and row.get('reason') in ('maintenance','restore'):
            facts['smtp_tick_outcome']='deferred_'+row['reason']
        elif set(row)=={'configured','selected','attempts_consumed'} and row.get('configured') is False and all(type(row.get(k)) is int and row[k]==0 for k in ('selected','attempts_consumed')):
            facts['smtp_tick_outcome']='unconfigured'
        elif set(row)=={'configured','selected','processed'} and row.get('configured') is True and all(type(row.get(k)) is int and 0<=row[k]<=10 for k in ('selected','processed')) and row['processed']<=row['selected']:
            facts.update(smtp_tick_outcome='processed',smtp_tick_selected=row['selected'],smtp_tick_processed=row['processed'])
    except (AssertionError,ValueError,TypeError):pass
    return facts


def smtp_tick(f,deadline=None):
    f.smtp_failure.update(smtp_tick_maintenance_deferrals=0,smtp_tick_retry_count=0)
    while True:
        remaining=110 if deadline is None else deadline-time.monotonic()
        assert remaining>0,'Mail dispatch exhausted its existing observation budget'
        try:result=subprocess.run([WINPS,'-NoProfile','-NonInteractive','-File','C:/OpenWebPBX/tools/Install-MailQueue.ps1','-Tick'],capture_output=True,timeout=min(110,remaining))
        except subprocess.TimeoutExpired:
            f.smtp_failure['smtp_tick_outcome']='command_timeout';raise
        # A task can exit zero after deliberately deferring maintenance. Preserve
        # its real result instead of presenting that as an attempted SMTP send.
        with (f.evidence/'smtp-tick.private.out').open('ab') as stream:stream.write(result.stdout)
        with (f.evidence/'smtp-tick.private.err').open('ab') as stream:stream.write(result.stderr)
        f.smtp_failure.update(smtp_tick_fields(result));result.check_returncode()
        outcome=f.smtp_failure['smtp_tick_outcome']
        if outcome!='deferred_maintenance' or deadline is None:
            assert outcome in ('processed','unconfigured'),'Mail dispatch did not attempt the configured queue'
            return result
        f.smtp_failure['smtp_tick_maintenance_deferrals']+=1
        remaining=deadline-time.monotonic()
        assert remaining>0 and f.smtp_failure['smtp_tick_maintenance_deferrals']<64,'Mail maintenance deferral exhausted its existing observation budget'
        time.sleep(min(.25,remaining))
        f.smtp_failure['smtp_tick_retry_count']+=1


def smtp_snapshot(f,sink,seed):
    facts=dict(f.smtp_failure)
    with sink.record_lock:
        facts.update(smtp_delivery_count=min(64,len(sink.deliveries)),smtp_envelope_count=min(64,len(sink.envelopes)),
            smtp_session_count=min(64,len(sink.connections)),smtp_authenticated_session_count=min(64,sum(auth for auth,_ in sink.connections)))
        for name in ('accepted','handshake_completed','handshake_failed'):
            if hasattr(sink,name):facts['smtp_tls_'+name+'_count']=min(64,getattr(sink,name))
        if getattr(sink,'handshake_error',None) in ('SSLError','TimeoutError','OSError','external_error'):facts['smtp_tls_error_type']=sink.handshake_error
    try:
        rows=f.cli('status')['mail'];assert type(rows) is list and len(rows)<=64
        owned=[row for row in rows if row.get('email_queue_uuid')==seed]
        facts['smtp_seed_row_count']=len(owned)
        if len(owned)==1:
            row=owned[0]
            if row.get('email_status') in ('waiting','trying','sent','failed'):facts['smtp_seed_status']=row['email_status']
            value=row.get('email_retry_count')
            if type(value) is int and 0<=value<=100:facts['smtp_seed_retry_count']=value
            if row.get('response_class') in ('none','configuration','certificate','authentication','connection','other'):facts['smtp_seed_response_class']=row['response_class']
        facts['smtp_queue_observed']=True
    except BaseException:facts['smtp_queue_observed']=False
    return facts


class NativeSMTPTLSSink(socketserver.ThreadingTCPServer):
    def get_request(self):
        raw,address=super().get_request()
        with self.record_lock:self.accepted+=1
        try:connection=self.tls_context.wrap_socket(raw,server_side=True)
        except BaseException as error:
            raw.close()
            with self.record_lock:
                self.handshake_failed+=1
                self.handshake_error=next((name for cls,name in ((ssl.SSLError,'SSLError'),(TimeoutError,'TimeoutError'),(OSError,'OSError')) if isinstance(error,cls)),'external_error')
            raise
        with self.record_lock:self.handshake_completed+=1
        return connection,address


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
    with NativeSMTPTLSSink(('127.0.0.1',0),module.SMTPFixture) as sink:
        sink.deliveries=[];sink.connections=[];sink.envelopes=[];sink.record_lock=threading.Lock();sink.daemon_threads=True
        sink.tls_context=context;sink.accepted=0;sink.handshake_completed=0;sink.handshake_failed=0
        worker=threading.Thread(target=sink.serve_forever,daemon=True);worker.start()
        seed=None;f.smtp_failure={}
        try:
            f.active_case='global_smtp_trusted_tls_hostname_auth'
            f.smtp_failure['smtp_stage']='save'
            values.update(smtp_host='windowsqa.example.invalid',smtp_port=str(sink.server_address[1]),smtp_secure='ssl')
            f.web.submit('/app/smtp_settings/','save',values)
            f.smtp_failure['smtp_stage']='connection_check'
            result=f.web.submit('/app/smtp_settings/','check',{})
            f.smtp_failure['smtp_connection_check_passed']='SMTP connection succeeded. No email was sent.' in result[2]
            assert f.smtp_failure['smtp_connection_check_passed'],'Normal SMTP connection check did not confirm success'
            assert not sink.deliveries,'Saved connection check unexpectedly delivered mail'
            f.smtp_failure['smtp_stage']='seed';seed=f.cli('mail-seed')['id']
            f.smtp_failure['smtp_stage']='dispatch';deadline=time.monotonic()+15;smtp_tick(f,deadline)
            f.smtp_failure['smtp_stage']='delivery'
            if not sink.deliveries:f.wait(lambda:bool(sink.deliveries),max(0,deadline-time.monotonic()))
            assert sink.deliveries[-1][0],'Trusted SMTP TLS/AUTH failed'
            observed=smtp_snapshot(f,sink,seed)
            assert observed.get('smtp_seed_row_count')==1 and observed.get('smtp_seed_status')=='sent','Trusted SMTP queue did not finish its owned seeded message'
            f.record('native_global_smtp_trusted_tls_hostname_auth_actual_loopback',no_external_mail=True,maintenance_deferrals=f.smtp_failure['smtp_tick_maintenance_deferrals'],dispatch_retries=f.smtp_failure['smtp_tick_retry_count'])
        except BaseException as error:
            error.smtp_failure=smtp_snapshot(f,sink,seed);raise
        finally:sink.shutdown();worker.join(3)


def main():
    p=argparse.ArgumentParser();p.add_argument('--input',required=True);p.add_argument('--phase',choices=['prepare-pki','pki-server','acceptance'],required=True);a=p.parse_args();guard();f=Fixture(a.input)
    if a.phase=='prepare-pki':prepare_pki(f);return
    if a.phase=='pki-server':serve_pki(f);return
    try:
        f.web=Web(f.s['public_url'],f.evidence/'fixture-root.pem');normal_setup(f,f.web)
        load_module('windows_meeting_browser',f.source/'tests/windows-meet-browser.py').run(f)
        native_calls(f);smtp_and_queued_voicemail(f);f.web.request('/logout.php')
        (f.evidence/'software-native-report.json').write_text(json.dumps({'schema':1,'producer':'windows-native-acceptance.py','state':'passed','checks':f.checks,'carrier':'unqualified','physical_devices':'unqualified','android_hardware':'unqualified','public_acme':'unqualified','scope':'fictional-hosted-runner'},indent=2))
    except BaseException as e:
        import traceback
        location=traceback.extract_tb(e.__traceback__)[-1]
        basename=Path(location.filename).name
        if basename not in ('windows-native-acceptance.py','pbx_v20_restore_native.py','sip_trunk_live.py'):
            basename='external_component'
        failure={'schema':1,'producer':'windows-native-acceptance.py','state':'failed','checks':f.checks,'error_type':type(e).__name__,'error':str(e),'source_basename':basename,'source_line':location.lineno,'active_case':f.active_case}
        if getattr(e,'fixture_failure',None):failure.update(e.fixture_failure)
        if getattr(e,'sip_failure',None):failure.update(e.sip_failure)
        if getattr(e,'audio_failure',None):failure.update(e.audio_failure)
        if getattr(e,'native_failure',None):failure.update(e.native_failure)
        if getattr(e,'media_failure',None):failure.update(e.media_failure)
        if getattr(e,'media_window_private',None):failure['media_window_private']=e.media_window_private
        if getattr(e,'queue_failure',None):failure.update(e.queue_failure)
        if getattr(e,'voicemail_failure',None):failure.update(e.voicemail_failure)
        if getattr(e,'mailbox_failure',None):failure.update(e.mailbox_failure)
        if getattr(e,'hotel_failure',None):failure.update(e.hotel_failure)
        if getattr(e,'smtp_failure',None):failure.update(e.smtp_failure)
        if getattr(e,'meeting_owner_failure',None):failure.update(e.meeting_owner_failure)
        if getattr(e,'meeting_media_failure',None):failure.update(e.meeting_media_failure)
        if getattr(e,'meeting_signaling_failure',None):failure.update(e.meeting_signaling_failure)
        if getattr(e,'meeting_path_failure',None):failure.update(e.meeting_path_failure)
        (f.evidence/'software-native-report.json').write_text(json.dumps(failure,indent=2))
        raise

if __name__=='__main__':main()
