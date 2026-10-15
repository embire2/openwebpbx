#!/usr/bin/env python3
"""Actual loopback TLS/RTP framing and receiver death proof; not a G729 codec/PBX qualification.

The deterministic codec stand-in checks exact 20-byte framing. Complete actual
Windows transcoding still requires the real independently loaded libbcg729 DLL.
"""
import importlib.util, json, math, re, socket, ssl, struct, tempfile, textwrap, threading, time
from pathlib import Path
from types import SimpleNamespace

ROOT=Path(__file__).resolve().parents[1]
spec=importlib.util.spec_from_file_location('native',ROOT/'tests/windows-native-acceptance.py')
native=importlib.util.module_from_spec(spec);spec.loader.exec_module(native)
sip=native.load_module('sip_trunk_live',ROOT/'tests/sip_trunk_live.py')
original=native.load_module('native_source_phone',ROOT/'tests/pbx_v20_restore_native.py')
source=(ROOT/'tests/windows-native-acceptance.py').read_text()
classes=textwrap.dedent(source[source.index('    class Phone(original.SourcePhone):'):source.index('    peers=[Phone(users[0]')])
checks=0
def check(value):
    global checks
    assert value;checks+=1
def wait(predicate):
    end=time.monotonic()+5
    while time.monotonic()<end:
        result=predicate()
        if result:return result
        time.sleep(.01)
    raise AssertionError('Bounded actual peer protocol test timed out')

class FrameCodec:
    def contexts(self):return object(),object()
    def encode(self,ctx,samples):assert len(samples)==160;return b'\x01'*20
    def decode(self,ctx,payload):
        assert len(payload)==20,'Forced G729 packet did not contain two 10ms frames'
        return struct.pack('<160h',*(int(6500*math.sin(2*math.pi*550*i/8000)) for i in range(160)))
    def close(self,contexts):pass

with tempfile.TemporaryDirectory() as folder:
    base=Path(folder);native.prepare_pki(SimpleNamespace(evidence=base,s={'scope':'a'*24}))
    context=ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER);context.load_cert_chain(base/'fixture-leaf.pem',base/'fixture-key.pem')
    server=socket.socket();server.bind(('127.0.0.1',0));server.listen();server.settimeout(5)
    media=socket.socket(socket.AF_INET,socket.SOCK_DGRAM);media.bind(('127.0.0.1',0));media.settimeout(2)
    messages=[];errors=[];ended=threading.Event();target=[]
    def serve():
        connection=None
        try:
            raw,_=server.accept();connection=context.wrap_socket(raw,server_side=True);connection.settimeout(.1);buffer=b''
            while not ended.is_set():
                try:
                    while b'\r\n\r\n' not in buffer:
                        piece=connection.recv(65535)
                        if not piece:return
                        buffer+=piece
                    header=buffer.split(b'\r\n\r\n',1)[0]
                    size=len(header)+4+int(re.search(br'(?im)^Content-Length:\s*(\d+)',header).group(1))
                    while len(buffer)<size:buffer+=connection.recv(65535)
                    message=buffer[:size].decode();buffer=buffer[size:];messages.append(message);h=sip.headers(message)
                    method=message.split(' ',1)[0]
                    if method=='ACK':continue
                    if method=='INVITE':
                        target[:]=[('127.0.0.1',int(re.search(r'm=audio (\d+)',message).group(1)))]
                        body=f'v=0\r\no=fixture 1 1 IN IP4 127.0.0.1\r\ns=framing\r\nc=IN IP4 127.0.0.1\r\nt=0 0\r\nm=audio {media.getsockname()[1]} RTP/AVP 18 101\r\na=rtpmap:18 G729/8000\r\na=ptime:20\r\na=sendrecv\r\n'
                    else:body=''
                    challenge=method in ('REGISTER','INVITE') and 'authorization' not in h
                    code=401 if challenge else 200
                    lines=[f'SIP/2.0 {code} Response']+[name+': '+h[name.lower()] for name in ['Via','From','To','Call-ID','CSeq']]
                    if challenge:lines+=['WWW-Authenticate: Digest realm="fictional.invalid", nonce="fixture-nonce", algorithm=MD5, qop="auth"'];body=''
                    else:lines+=['Contact: <sip:8101@127.0.0.1>']
                    connection.sendall(('\r\n'.join(lines+[f'Content-Length: {len(body)}','',''])+body).encode())
                except socket.timeout:continue
        except BaseException as error:
            if not ended.is_set():errors.append(error)
        finally:
            if connection:connection.close()
    worker=threading.Thread(target=serve);worker.start()
    def fixture_stream(bind,destination,ca,name):return native.SIPStream(bind,server.getsockname(),ca,name)
    scope={'original':original,'sip':sip,'bind':'127.0.0.1','realm':'fictional.invalid','ca':base/'fixture-root.pem',
           'SIPStream':fixture_stream,'threading':threading,'time':time,'struct':struct,'math':math,'socket':socket,
           'os':native.os,'WindowsRtpSocket':native.WindowsRtpSocket,
           'f':SimpleNamespace(evidence=base)}
    exec(classes,scope);peer=scope['G729Phone']({'number':'8100','auth':'auth-8100','password':'fictional-only'},FrameCodec())
    try:
        check(peer.register(('127.0.0.1',5061))['code']==200)
        call=peer.dial('8101',('127.0.0.1',5061));check(call['code']==200 and call['media']['pt']==18)
        offer=next(text for text in messages if text.startswith('INVITE '));check('a=ptime:20\r\n' in offer and 'a=maxptime:20\r\n' in offer)
        outbound,_=media.recvfrom(4096);check(len(outbound)==32 and outbound[1]&127==18)
        media.sendto(struct.pack('!BBHII',128,18,1,160,100)+bytes(20),target[0])
        wait(lambda:call['media']['received']==1);check(len(call['media']['decoded_pcm'])==320)
        check(peer.receiver_failure is None and peer.thread.is_alive())
        media.sendto(struct.pack('!BBHII',128,18,2,320,100)+bytes(10),target[0])
        wait(lambda:peer.receiver_failure is not None)
        check(isinstance(peer.receiver_failure,AssertionError));check(not peer.thread.is_alive())
        check((base/'g729-last-rtp.private.bin').read_bytes()[12:]==bytes(10))
        try:peer.register(('127.0.0.1',5061),expires=0)
        except AssertionError as error:check(error is peer.receiver_failure)
        else:raise AssertionError('Receiver failure was hidden behind a cleanup transaction')
        check((base/'g729-sip-responses.private.bin').stat().st_size>0)
    finally:ended.set();peer.close();worker.join(6);server.close();media.close()
    check(not errors and not worker.is_alive())
print(f'PASS {checks} actual TLS/20ms RTP framing, explicit ptime and retained receiver-failure checks; no PBX contacted')
