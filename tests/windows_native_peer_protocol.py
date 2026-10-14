#!/usr/bin/env python3
"""Exercise the actual media peer's Number/AuthID packets on owned loopback ports."""
import hashlib
import importlib.util
import json
import re
import socket
import ssl
import tempfile
import textwrap
import threading
from pathlib import Path
from types import SimpleNamespace

ROOT=Path(__file__).resolve().parents[1]
spec=importlib.util.spec_from_file_location('native',ROOT/'tests/windows-native-acceptance.py')
native=importlib.util.module_from_spec(spec);spec.loader.exec_module(native)
sip=native.load_module('sip_trunk_live',ROOT/'tests/sip_trunk_live.py')
original=native.load_module('native_source_phone',ROOT/'tests/pbx_v20_restore_native.py')
text=(ROOT/'tests/windows-native-acceptance.py').read_text()
phone_source=textwrap.dedent(text[text.index('    class Phone(original.SourcePhone):'):text.index('    class G729Phone(Phone):')])
checks=0
def check(value):
    global checks
    assert value;checks+=1

with tempfile.TemporaryDirectory() as folder:
    base=Path(folder);native.prepare_pki(SimpleNamespace(evidence=base,s={'scope':'a'*24}))
    context=ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER);context.load_cert_chain(base/'fixture-leaf.pem',base/'fixture-key.pem')
    for transport in ['udp','tcp','tls']:
        server=socket.socket(socket.AF_INET,socket.SOCK_DGRAM if transport=='udp' else socket.SOCK_STREAM)
        server.bind(('127.0.0.1',0));server.settimeout(8)
        if transport!='udp':server.listen()
        endpoint=server.getsockname();errors=[];messages=[]
        record={'number':'8101','auth':'8102','password':'fictional-peer-password'}
        def serve():
            connection=None
            try:
                if transport!='udp':
                    connection,_=server.accept();connection.settimeout(5)
                    if transport=='tls':connection=context.wrap_socket(connection,server_side=True)
                buffer=b''
                for index in range(2):
                    if transport=='udp':data,address=server.recvfrom(65535)
                    else:
                        while b'\r\n\r\n' not in buffer:buffer+=connection.recv(65535)
                        head=buffer.split(b'\r\n\r\n',1)[0];end=len(head)+4+int(re.search(br'(?im)^Content-Length:\s*(\d+)',head).group(1))
                        while len(buffer)<end:buffer+=connection.recv(65535)
                        data=buffer[:end];buffer=buffer[end:]
                    message=data.decode();h=native.SIPClient.headers(message);messages.append(message)
                    code=401 if index==0 else 200
                    if index:
                        auth=dict(re.findall(r'(\w+)="([^"]*)"',h['authorization']))
                        nonce_count=re.search(r'\bnc=([0-9a-f]{8})',h['authorization']).group(1)
                        md5=lambda value:hashlib.md5(value.encode()).hexdigest()
                        expected=md5(md5(record['auth']+':fictional.invalid:'+record['password'])+':owned-nonce:'+nonce_count+':'+auth['cnonce']+':auth:'+md5('REGISTER:sip:fictional.invalid'))
                        assert auth['username']==record['auth'] and auth['realm']=='fictional.invalid' and auth['response']==expected
                    lines=[f'SIP/2.0 {code} Response']+[name+': '+h[name.lower()] for name in ['Via','From','To','Call-ID','CSeq']]
                    if index==0:lines+=['WWW-Authenticate: Digest realm="fictional.invalid", nonce="owned-nonce", algorithm=MD5, qop="auth"']
                    else:lines+=['Contact: '+h['contact']]
                    wire=('\r\n'.join(lines+['Content-Length: 0','',''])).encode()
                    if transport=='udp':server.sendto(wire,address)
                    else:connection.sendall(wire[:31]);connection.sendall(wire[31:])
                if connection:connection.recv(1)
            except BaseException as error:errors.append(error)
            finally:
                if connection:connection.close()
        worker=threading.Thread(target=serve);worker.start()
        def fixture_stream(bind,destination,ca,name):
            assert destination==('127.0.0.1',5061 if transport=='tls' else 5060)
            return native.SIPStream(bind,endpoint,ca,name)
        namespace={'original':original,'bind':'127.0.0.1','realm':'fictional.invalid','ca':base/'fixture-root.pem',
                   'SIPStream':fixture_stream,'threading':threading}
        exec(phone_source,namespace)
        peer=namespace['Phone'](record,transport)
        try:
            result=peer.register(endpoint)
            check(result['code']==200 and result['digest_challenge_count']==1)
            check('From: <sip:8101@fictional.invalid>' in messages[1] and 'To: <sip:8101@fictional.invalid>' in messages[1])
            check('Contact: <sip:8101@127.0.0.1:' in messages[1] and (';transport='+transport) in messages[1])
            check('SIP/2.0/'+transport.upper() in messages[1] and len(peer.registration_call_ids)==1)
            check(len(peer.registration_packets)==2 and peer.registration_packets[1].decode()==messages[1])
        finally:peer.close();worker.join(10);server.close()
        if errors:raise errors[0]
print(f'PASS {checks} actual media-peer UDP/TCP/TLS Number/AuthID/digest/framing checks; no PBX contacted')
