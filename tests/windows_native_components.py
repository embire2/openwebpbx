#!/usr/bin/env python3
"""Tests for the portable acceptance harness, not a Windows PBX qualification."""
import hashlib, importlib.util, json, secrets, socket, ssl, tempfile, threading
from pathlib import Path
from types import SimpleNamespace
from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.serialization import pkcs12

spec=importlib.util.spec_from_file_location('native',Path(__file__).with_name('windows-native-acceptance.py'))
n=importlib.util.module_from_spec(spec);spec.loader.exec_module(n)
checks=0
def check(value):
    global checks
    assert value;checks+=1

try:n.guard()
except RuntimeError:check(True)
else:raise AssertionError('Disposable platform guard was bypassed')
forms=n.Forms('<form><input name="csrf" value="safe"><input type="checkbox" name="not_checked"><input type="checkbox" name="checked" checked value="1"><select name="mode"><option value="a"><option value="b" selected></select><input name="disabled" disabled></form>').forms
check(forms[0]['fields']=={'csrf':'safe','checked':'1','mode':'b'})
with tempfile.TemporaryDirectory() as folder:
    root=Path(folder);f=SimpleNamespace(evidence=root,s={'scope':secrets.token_hex(12)})
    n.prepare_pki(f);state=json.loads((root/'pki-private.json').read_text())
    private,leaf,chain=pkcs12.load_key_and_certificates((root/'fixture.pfx').read_bytes(),state['password'].encode())
    check(private is not None and leaf is not None and len(chain)==1)
    check(leaf.subject!=leaf.issuer)
    check(leaf.extensions.get_extension_for_class(x509.SubjectAlternativeName).value.get_values_for_type(x509.DNSName)==['windowsqa.example.invalid'])
    check(leaf.fingerprint(hashes.SHA1()).hex()==state['leaf_thumbprint'])
    crl=x509.load_der_x509_crl((root/'fixture.crl').read_bytes());check(crl.issuer==chain[0].subject)
    (root/'leaf.pem').write_bytes(leaf.public_bytes(serialization.Encoding.PEM));(root/'key.pem').write_bytes(private.private_bytes(serialization.Encoding.PEM,serialization.PrivateFormat.PKCS8,serialization.NoEncryption()))
    context=ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER);context.load_cert_chain(root/'leaf.pem',root/'key.pem')
    # Exercise the exact UDP and framed TCP/TLS registrar fixture independently.
    for transport in ['udp','tcp','tls']:
        server=socket.socket(socket.AF_INET,socket.SOCK_DGRAM if transport=='udp' else socket.SOCK_STREAM)
        server.bind(('127.0.0.1',0));server.settimeout(8)
        if transport!='udp':server.listen()
        error=[];requests=[]
        def serve():
            client=None
            try:
                if transport!='udp':
                    client,_=server.accept()
                    if transport=='tls':client=context.wrap_socket(client,server_side=True)
                for response_index in range(2):
                    if transport=='udp':data,peer=server.recvfrom(65535)
                    else:
                        data=b''
                        while b'\r\n\r\n' not in data:data+=client.recv(65535)
                    text=data.decode();h=n.SIPClient.headers(text);requests.append(text)
                    code=401 if response_index==0 else 200
                    lines=[f'SIP/2.0 {code} Response']+[name+': '+h[name.lower()] for name in ['Via','From','To','Call-ID','CSeq']]
                    if code==401:lines+=['WWW-Authenticate: Digest realm="fixture.invalid", nonce="known-nonce", algorithm=MD5, qop="auth"']
                    else:lines+=['Contact: '+h['contact']]
                    wire=('\r\n'.join(lines+['Content-Length: 0','',''])).encode()
                    if transport=='udp':server.sendto(wire,peer)
                    else:
                        # Deliberate framing fragments exercise stream buffering.
                        client.sendall(wire[:25]);client.sendall(wire[25:])
            except BaseException as e:error.append(e)
            finally:
                if client:client.close()
        thread=threading.Thread(target=serve);thread.start()
        c=n.SIPClient(transport,'127.0.0.1',server.getsockname(),'fixture.invalid',root/'fixture-root.pem','windowsqa.example.invalid')
        try:
            result=c.register({'number':'8101','auth':'8102','password':'fictional-password'})
            check(result['code']==200 and result['response_identity'])
            check(result['requested'] in result['contacts'])
            check('username="8102"' in requests[1] and 'From: <sip:8101@fixture.invalid>' in requests[1])
        finally:c.close();thread.join(10);server.close()
        if error:raise error[0]
    # Independent tone encoder/decoder keeps meaningful decoded-media thresholds.
    sip=n.load_module('sip_trunk_live',Path(__file__).with_name('sip_trunk_live.py'))
    source=n.load_module('source_phone_fixture',Path(__file__).with_name('pbx_v20_restore_native.py'))
    import math,struct
    samples=[int(6500*math.sin(2*math.pi*550*i/8000)) for i in range(16000)]
    decoded=b''.join(struct.pack('<h',source.decode_ulaw(source.encode_ulaw(v))) for v in samples)
    check(source.decoded_tone_check({'decoded_pcm':bytearray(decoded)},550)>.99)
    try:source.decoded_tone_check({'decoded_pcm':bytearray(decoded)},440)
    except AssertionError:check(True)
    else:raise AssertionError('Wrong remote tone passed')
    # Native prompt observer uses framed, authenticated, loopback events and
    # filters the fictional realm plus the actual caller's SIP Call-ID.
    event_server=socket.socket();event_server.bind(('127.0.0.1',0));event_server.listen();event_server.settimeout(8)
    event_errors=[];commands=[]
    def event_fixture():
        client=None
        try:
            client,_=event_server.accept();client.settimeout(5)
            client.sendall(b'Content-Type: auth/request\n\n')
            for expected in [b'auth fixture-secret',b'event plain PLAYBACK_START']:
                request=b''
                while b'\n\n' not in request:request+=client.recv(4096)
                commands.append(request);assert request.strip()==expected
                client.sendall(b'Content-Type: command/reply\nReply-Text: +OK accepted\n\n')
            for realm,callid,path in [('foreign.invalid','owned-call','foreign.wav'),('fictional.invalid','other-call','wrong.wav'),('fictional.invalid','owned-call','C:/Program Files/FreeSWITCH/sounds/voicemail/vm-enter_pass.wav')]:
                body=('Event-Name: PLAYBACK_START\nvariable_domain_name: '+realm+'\nvariable_sip_call_id: '+callid+'\nPlayback-File-Path: '+path.replace(' ','%20')+'\n\n').encode()
                frame=('Content-Type: text/event-plain\nContent-Length: '+str(len(body))+'\n\n').encode()+body
                client.sendall(frame[:19]);client.sendall(frame[19:])
            # Keep the real observer alive until its owned client closes.
            client.recv(1)
        except BaseException as error:event_errors.append(error)
        finally:
            if client:client.close()
    event_thread=threading.Thread(target=event_fixture);event_thread.start()
    playback=n.NativePlayback({'host':'127.0.0.1','port':event_server.getsockname()[1],'password':'fixture-secret'},'fictional.invalid')
    try:
        index,path=playback.prompt('owned-call',['vm-enter_pass.wav'],seconds=5)
        check(path=='C:/Program Files/FreeSWITCH/sounds/voicemail/vm-enter_pass.wav')
        check(len(playback.events)==2 and index==1)
        check(commands[0].strip()==b'auth fixture-secret' and commands[1].strip()==b'event plain PLAYBACK_START')
        try:playback.prompt('owned-call',['wrong.wav'],seconds=.1)
        except AssertionError:check(True)
        else:raise AssertionError('Another call prompt matched owned call')
    finally:playback.close();event_thread.join(10);event_server.close()
    if event_errors:raise event_errors[0]
    try:n.NativePlayback({'host':'foreign.example.invalid','port':8021,'password':'fixture-secret'},'fictional.invalid')
    except AssertionError:check(True)
    else:raise AssertionError('Non-loopback native observer was accepted')
print(f'PASS {checks} portable native-harness protocol/PKI checks; no Windows product result implied')
