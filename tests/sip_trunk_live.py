"""Opt-in actual-engine carrier checks. All provider endpoints and phones are loopback fixtures.

OPENWEB_LIVE_TRUNK_TEST=1 OPENWEB_SIP_TEST_BIND=<local SIP profile IP> python3 tests/sip_trunk_live.py
Requires the reviewed PHP/Lua source deployed to the running local FreeSWITCH instance.
Creates and removes one independent temporary domain; never enables existing trunks.
"""
import hashlib
import json
import os
from pathlib import Path
import queue
import re
import secrets
import shutil
import socket
import struct
import subprocess
import tempfile
import threading
import time


def headers(text):
    result = {}
    for line in text.split('\r\n')[1:]:
        if ': ' in line:
            key, value = line.split(': ', 1)
            result[key.lower()] = value
    return result


def digest(challenge, user, password, method, uri):
    fields = dict(re.findall(r'(\w+)="([^"]*)"', challenge))
    md5 = lambda value: hashlib.md5(value.encode()).hexdigest()
    a1 = md5(user + ':' + fields['realm'] + ':' + password)
    a2 = md5(method + ':' + uri)
    nonce = fields['nonce']
    extra = ''
    if 'auth' in fields.get('qop', ''):
        cnonce = secrets.token_hex(12)
        response = md5(a1 + ':' + nonce + ':00000001:' + cnonce + ':auth:' + a2)
        extra = ', qop=auth, nc=00000001, cnonce="' + cnonce + '"'
    else:
        response = md5(a1 + ':' + nonce + ':' + a2)
    return ('Digest username="' + user + '", realm="' + fields['realm'] + '", nonce="' + nonce
            + '", uri="' + uri + '", response="' + response + '", algorithm=MD5' + extra)


class Peer:
    def __init__(self, ip='127.0.0.1', provider=False, first=False):
        self.ip, self.provider, self.first = ip, provider, first
        self.socket = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.socket.bind((ip, 0))
        # Keep signalling polling below the 20ms RTP packet interval. A 100ms
        # wait starves media whenever no SIP packet arrives on the same socket.
        self.socket.settimeout(.005)
        self.port = self.socket.getsockname()[1]
        self.queues, self.dialogs, self.invites, self.replies = {}, {}, [], {}
        self.auth = None; self.auth_passed = 0; self.register_requests = 0; self.outgoing = []
        self.challenge_nonces = {}; self.challenges = 0
        self.registration_call_ids = []
        self.stopped = False
        self.thread = threading.Thread(target=self.run, daemon=True)
        self.thread.start()

    def packet(self, method, uri, callid, seq, from_header, to_header, body='', extra=None, branch=None):
        lines = [method + ' ' + uri + ' SIP/2.0',
                 f'Via: SIP/2.0/UDP {self.ip}:{self.port};branch={branch or "z9hG4bK" + secrets.token_hex(9)};rport',
                 'Max-Forwards: 20', 'From: ' + from_header, 'To: ' + to_header,
                 'Call-ID: ' + callid, f'CSeq: {seq} {method}',
                 f'Contact: <sip:fixture@{self.ip}:{self.port}>', 'User-Agent: OpenWebPBX-Local-Carrier-Check']
        lines.extend(extra or [])
        if body: lines.append('Content-Type: application/sdp')
        return ('\r\n'.join(lines + [f'Content-Length: {len(body.encode())}', '', body])).encode()

    def response(self, code, h, body=''):
        names = {200:'OK', 403:'Forbidden', 486:'Busy Here', 503:'Service Unavailable', 603:'Decline'}
        lines = [f'SIP/2.0 {code} {names.get(code,"Response")}']
        for name in ['Via', 'From', 'To', 'Call-ID', 'CSeq']:
            value = h[name.lower()]
            if name == 'To' and ';tag=' not in value: value += ';tag=localfixture'
            lines.append(name + ': ' + value)
        if code == 200:
            lines.append(f'Contact: <sip:fixture@{self.ip}:{self.port}>')
        if code == 407:
            lines.append('Proxy-Authenticate: Digest realm="local-carrier.invalid", nonce="'+self.challenge_nonces[h['call-id']]+'", algorithm=MD5, qop="auth"')
        if body: lines.append('Content-Type: application/sdp')
        return ('\r\n'.join(lines + [f'Content-Length: {len(body.encode())}', '', body])).encode()

    def media(self, pt=0):
        sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        sock.bind((self.ip, 0)); sock.setblocking(False)
        state = {'socket':sock, 'pt':pt, 'received':0, 'unexpected_audio':0, 'sent':0, 'target':None,
                 'sent_first_at':None,'sent_last_at':None,'received_first_at':None,'received_last_at':None}
        return state

    def sdp(self, state, offer=False):
        codecs = '0 8 101' if offer else f'{state["pt"]} 101'
        return (f'v=0\r\no=fixture 1 1 IN IP4 {self.ip}\r\ns=Local carrier check\r\nc=IN IP4 {self.ip}\r\nt=0 0\r\n'
                f'm=audio {state["socket"].getsockname()[1]} RTP/AVP {codecs}\r\n'
                'a=rtpmap:0 PCMU/8000\r\na=rtpmap:8 PCMA/8000\r\na=rtpmap:101 telephone-event/8000\r\na=sendrecv\r\n')

    def target(self, text):
        return (re.search(r'c=IN IP4 ([^\r\n ]+)', text).group(1), int(re.search(r'm=audio (\d+)', text).group(1)))

    def run(self):
        last = 0
        while not self.stopped:
            try:
                data, peer = self.socket.recvfrom(65535)
                text = data.decode(errors='replace'); h = headers(text); cid = h.get('call-id','')
                if text.startswith('SIP/2.0 '):
                    if cid in self.queues: self.queues[cid].put((text, peer))
                elif text.startswith('INVITE '):
                    transaction = (cid, h['cseq'])
                    if transaction in self.replies:
                        self.socket.sendto(self.replies[transaction], peer); continue
                    number = text.split(' ', 2)[1].split(':',1)[1].split('@',1)[0]
                    self.invites.append({'callid':cid,'number':number,'headers':h,'sdp':text.split('\r\n\r\n',1)[-1],'received_at':time.monotonic()})
                    code = 503 if self.first and number.endswith('101') else 486 if self.first and number.endswith('102') else 603 if self.first and number.endswith('103') else 200
                    if self.first and number.endswith('104'):
                        raw=h.get('proxy-authorization','')
                        fields={key:(quoted or plain).strip() for key,quoted,plain in re.findall(r'(\w+)=(?:"([^"]*)"|([^, ]+))',raw)}
                        if not fields or cid not in self.challenge_nonces:
                            self.challenge_nonces[cid]=secrets.token_hex(16);self.challenges+=1;code=407
                        else:
                            md5=lambda value:hashlib.md5(value.encode()).hexdigest()
                            uri=text.split(' ',2)[1];a1=md5(self.auth['username']+':local-carrier.invalid:'+self.auth['password']);a2=md5('INVITE:'+uri)
                            nonce=self.challenge_nonces.get(cid,'')
                            expected=md5(a1+':'+nonce+':'+fields.get('nc','')+':'+fields.get('cnonce','')+':auth:'+a2)
                            valid=bool(nonce) and fields.get('nonce')==nonce and fields.get('realm')=='local-carrier.invalid' and fields.get('qop')=='auth' and fields.get('username')==self.auth['username'] and fields.get('uri')==uri and fields.get('response')==expected
                            code=200 if valid else 403
                            if valid:self.auth_passed+=1
                    body = ''
                    offered=re.search(r'm=audio \d+ RTP/AVP ([^\r\n]+)',text)
                    if code==200 and self.provider and (not offered or '8' not in offered.group(1).split()):code=488
                    if code == 200:
                        state = self.media(8 if self.provider else 0);state['target'] = self.target(text)
                        state['incoming'] = {'headers': h, 'peer': peer}
                        self.dialogs[cid] = state;body = self.sdp(state)
                    reply = self.response(code,h,body);self.replies[transaction] = reply;self.socket.sendto(reply,peer)
                elif text.startswith('ACK '):
                    if cid in self.dialogs:self.dialogs[cid]['acked']=True
                elif text.startswith('REGISTER '):
                    self.register_requests+=1;self.socket.sendto(self.response(403,h),peer)
                elif text.startswith(('BYE ','OPTIONS ','CANCEL ')):
                    self.socket.sendto(self.response(200,h),peer)
                    if text.startswith(('BYE ','CANCEL ')) and cid in self.dialogs:
                        self.dialogs[cid]['ended'] = True
            except (socket.timeout, BlockingIOError): pass
            except OSError:
                if not self.stopped: raise
            if time.monotonic()-last < .02: continue
            last = time.monotonic()
            for state in list(self.dialogs.values()):
                if state.get('ended') or not state['target']: continue
                seq=state['sent'];pt=state['pt']
                packet=struct.pack('!BBHII',0x80,pt,seq%65536,(seq*160)%4294967296,73)+bytes([0xD5 if pt==8 else 0xA0])*160
                state['socket'].sendto(packet,state['target']);state['sent']+=1
                state['sent_first_at']=state['sent_first_at'] or last;state['sent_last_at']=last
                while True:
                    try:
                        data=state['socket'].recv(4096)
                        if len(data)>=172 and data[0]&0xc0==0x80:
                            audio_pt=data[1]&0x7f
                            if audio_pt==state['pt']:
                                received_at=time.monotonic();state['received']+=1
                                state['received_first_at']=state['received_first_at'] or received_at;state['received_last_at']=received_at
                            elif audio_pt in (0,8):state['unexpected_audio']+=1
                    except BlockingIOError: break

    def exchange(self, method, uri, dest, user='fixture', realm='fixture.invalid', password='', body='', to_uri=None, expires=None):
        cid=secrets.token_hex(12)+'@localfixture'; self.queues[cid]=queue.Queue()
        if method=='REGISTER' and expires and expires>0:self.registration_call_ids.append(cid)
        from_header=f'<sip:{user}@{realm}>;tag='+secrets.token_hex(5)
        to_header='<'+(to_uri or uri)+'>';seq=1;branch='z9hG4bK'+secrets.token_hex(9)
        extra=[] if expires is None else ['Expires: '+str(expires)]
        self.socket.sendto(self.packet(method,uri,cid,seq,from_header,to_header,body,extra,branch),dest)
        deadline=time.monotonic()+18
        while time.monotonic()<deadline:
            try:text,peer=self.queues[cid].get(timeout=max(.1,deadline-time.monotonic()))
            except queue.Empty:break
            h=headers(text)
            if not h.get('cseq','').endswith(method):continue
            code=int(text.split(' ',2)[1])
            if code<200:continue
            if code in (401,407) and password:
                if method=='INVITE':self.socket.sendto(self.packet('ACK',uri,cid,seq,from_header,h['to'],branch=branch),peer)
                auth=digest(h.get('www-authenticate',h.get('proxy-authenticate','')),user,password,method,uri)
                extra=[x for x in extra if not x.startswith(('Authorization:','Proxy-Authorization:'))]
                extra.append(('Authorization: ' if code==401 else 'Proxy-Authorization: ')+auth)
                seq+=1;branch='z9hG4bK'+secrets.token_hex(9)
                self.socket.sendto(self.packet(method,uri,cid,seq,from_header,to_header,body,extra,branch),dest);continue
            if method=='INVITE':
                remote_uri=re.search(r'<([^>]+)>',h.get('contact','<'+uri+'>')).group(1) if code<300 else uri
                self.socket.sendto(self.packet('ACK',remote_uri,cid,seq,from_header,h['to'],branch=None if code<300 else branch),peer)
            return {'code':code,'text':text,'callid':cid,'seq':seq,'from':from_header,'to':h['to'],'uri':uri,'peer':peer}
        raise RuntimeError('Local SIP transaction timed out')

    def call(self, uri, dest, user='fixture', realm='fixture.invalid', password='', to_uri=None):
        media=self.media()
        result=self.exchange('INVITE',uri,dest,user,realm,password,self.sdp(media,True),to_uri)
        if result['code']==200:
            media['target']=self.target(result['text']);media['pt']=int(re.search(r'm=audio \d+ RTP/AVP (\d+)',result['text']).group(1))
            self.dialogs[result['callid']]=media;result['media']=media;self.outgoing.append(result)
        else:media['socket'].close()
        return result

    def hangup(self, call):
        remote=re.search(r'<([^>]+)>',headers(call['text']).get('contact','<'+call['uri']+'>')).group(1)
        self.socket.sendto(self.packet('BYE',remote,call['callid'],call['seq']+1,call['from'],call['to']),call['peer'])
        self.dialogs[call['callid']]['ended']=True

    def hangup_incoming(self, cid):
        """End an answered callback provider leg as the remote callee."""
        state=self.dialogs[cid];incoming=state['incoming'];h=incoming['headers']
        deadline=time.monotonic()+3
        while time.monotonic()<deadline and not state.get('acked'):time.sleep(.02)
        assert state.get('acked'),'Answered callback provider INVITE received no ACK'
        remote=re.search(r'<([^>]+)>',h['contact']).group(1)
        local=h['to'] if ';tag=' in h['to'] else h['to']+';tag=localfixture'
        seq=int(h['cseq'].split(' ',1)[0])+1
        self.queues[cid]=queue.Queue()
        self.socket.sendto(self.packet('BYE',remote,cid,seq,local,h['from']),incoming['peer'])
        deadline=time.monotonic()+3
        while time.monotonic()<deadline:
            try:reply,_=self.queues[cid].get(timeout=max(.02,deadline-time.monotonic()))
            except queue.Empty:break
            reply_headers=headers(reply)
            if reply_headers.get('cseq')==f'{seq} BYE':
                assert reply.startswith('SIP/2.0 200 '),'Callback provider BYE was not accepted'
                state['ended']=True;return
        raise AssertionError('Callback provider BYE received no 200 response')

    def close(self):
        for call in self.outgoing:
            if not call['media'].get('ended'):self.hangup(call)
        self.stopped=True;self.thread.join(2)
        self.socket.close()
        for state in self.dialogs.values():state['socket'].close()


def rtp_rate_check(state):
    """Require sustained 20ms media, rather than a few isolated RTP packets."""
    for direction in ['sent','received']:
        elapsed=state[direction+'_last_at']-state[direction+'_first_at']
        assert elapsed>=.3,'Local RTP rate observation was too short'
        rate=(state[direction]-1)/elapsed
        assert 30<=rate<=70,f'Local {direction} RTP pacing was {rate:.1f} packets/s; expected approximately 50'


def audio_check(call, other, previous):
    assert call['code']==200, f'Expected answered local call, received SIP {call["code"]}'
    deadline=time.monotonic()+5
    while time.monotonic()<deadline:
        fresh=[s for k,s in other.dialogs.items() if k not in previous]
        if fresh and fresh[-1]['received']>20 and call['media']['received']>20:
            assert fresh[-1]['unexpected_audio']==call['media']['unexpected_audio']==0,'RTP payload did not match the negotiated codec'
            rtp_rate_check(fresh[-1]);rtp_rate_check(call['media'])
            return
        time.sleep(.05)
    raise AssertionError('Two-way RTP did not reach both local endpoints')


def codec_check(invite):
    offered=re.search(r'm=audio \d+ RTP/AVP ([^\r\n]+)',invite['sdp'])
    assert offered and {'0','8'}.issubset(set(offered.group(1).split())),'Configured PCMU/PCMA list was not offered intact'


def callback_check(root, statefile, agent, first, second, target, provider):
    """Exercise the durable worker delivery path to a synthetic external number."""
    agent_before=set(agent.dialogs);provider_before=set(provider.dialogs)
    first_before=len(first.invites);second_before=len(second.invites)
    challenges_before=first.challenges
    operation=["php",str(root/'tests/sip_trunk_live_fixture.php')]
    subprocess.run(operation+['callback-start',str(statefile),target],check=True,cwd=root,timeout=30)
    deadline=time.monotonic()+20;agent_call=None;provider_call=None
    while time.monotonic()<deadline:
        agents=[(cid,s) for cid,s in agent.dialogs.items() if cid not in agent_before and not s.get('ended')]
        providers=[(cid,s) for cid,s in provider.dialogs.items() if cid not in provider_before and not s.get('ended')]
        if agents and providers:
            agent_call=agents[-1];provider_call=providers[-1]
            if agent_call[1]['received']>20 and provider_call[1]['received']>20:break
        time.sleep(.05)
    else:
        status=subprocess.run(operation+['callback-status',str(statefile),target],check=True,cwd=root,timeout=10,capture_output=True,text=True)
        raise AssertionError('Local external callback did not connect with two-way RTP; job '+status.stdout.strip())
    first_invites=first.invites[first_before:];second_invites=second.invites[second_before:]
    for invite in first_invites+second_invites:codec_check(invite)
    assert agent_call[1]['unexpected_audio']==provider_call[1]['unexpected_audio']==0,'Callback RTP payload did not match the negotiated codec'
    rtp_rate_check(agent_call[1]);rtp_rate_check(provider_call[1])
    assert provider_call[1]['pt']==8,'Callback provider did not select PCMA'
    agent_invite=next(i for i in agent.invites if i['callid']==agent_call[0])
    assert first_invites and agent_invite['received_at']<first_invites[0]['received_at'],'Callback provider was called before the available agent'
    expected='55'+target[2:]
    assert first_invites and all(i['number']==expected for i in first_invites),'Callback first provider rewrite failed'
    if target=='99101':
        assert len(first_invites)==len(second_invites)==1,'Callback provider fallback was missing or duplicated'
        assert second_invites[0]['number']==expected,'Callback backup provider rewrite failed'
        assert '+27100000002' in second_invites[0]['headers']['from'],'Callback backup From used the wrong caller ID'
        assert 'sip:+27100000002@' in second_invites[0]['headers']['contact'],'Callback backup Contact identity was lost'
        assert '+27100000002' in second_invites[0]['headers'].get('remote-party-id',''),'Callback backup RPID identity was lost'
    else:
        assert not second_invites,'Authenticated callback unexpectedly used a backup provider'
        assert first.challenges==challenges_before+1 and len(first_invites)==2,'Callback did not complete a fresh provider digest challenge'
        assert first_invites[1]['headers'].get('proxy-authorization'),'Callback provider digest challenge/retry sequence was missing'
    provider.hangup_incoming(provider_call[0])
    deadline=time.monotonic()+10
    while time.monotonic()<deadline:
        response=subprocess.run(operation+['callback-status',str(statefile),target],check=True,cwd=root,timeout=10,capture_output=True,text=True)
        job=json.loads(response.stdout)
        if job['state']=='completed':break
        if job['state'] in ('failed','cancelled','waiting'):raise AssertionError('Answered callback was not completed: '+response.stdout.strip())
        time.sleep(.1)
    else:raise AssertionError('Answered external callback job did not complete')
    assert job['attempts']==1 and job['last_result']=='Connected','Callback completion/attempt tracking was incorrect'
    assert job['internal_target'] is False and job['lease_until'] is None and job['agent_number'] is None,'Callback durable result retained a lease or internal target'
    deadline=time.monotonic()+5
    while time.monotonic()<deadline and not agent_call[1].get('ended'):time.sleep(.05)
    assert agent_call[1].get('ended'),'Completed callback left the local agent call running'
    deadline=time.monotonic()+5
    while time.monotonic()<deadline:
        response=subprocess.run(operation+['callback-agent-status',str(statefile)],check=True,cwd=root,timeout=10,capture_output=True,text=True)
        if json.loads(response.stdout)['ready']:break
        time.sleep(.1)
    else:raise AssertionError('Completed callback did not release its own native queue agent')


def main():
    if os.environ.get('OPENWEB_LIVE_TRUNK_TEST')!='1':raise SystemExit('Explicit OPENWEB_LIVE_TRUNK_TEST=1 is required.')
    bind=os.environ.get('OPENWEB_SIP_TEST_BIND','')
    if not bind:raise SystemExit('Specify this machine\'s SIP profile IP in OPENWEB_SIP_TEST_BIND.')
    # A local bind verifies this is our own instance, not an arbitrary remote PBX.
    check=socket.socket(socket.AF_INET,socket.SOCK_DGRAM);check.bind((bind,0));check.close()
    root=Path(__file__).resolve().parents[1];private=Path(tempfile.mkdtemp(prefix='openweb-trunk-check-'));statefile=private/'state.json'
    # Keep handset addresses separate from the trusted carrier address, as on a
    # real deployment; a carrier-whitelisted source intentionally skips digest.
    peers=[Peer(provider=True,first=True),Peer(provider=True),Peer('127.0.0.3'),Peer('127.0.0.4'),Peer('127.0.0.2')]
    first,second,caller,phone,foreign=peers
    state=None;cleaned=False
    try:
        subprocess.run(['php',str(root/'tests/sip_trunk_live_fixture.php'),'create',str(statefile),str(first.port),str(second.port)],check=True,cwd=root,timeout=60)
        state=json.loads(statefile.read_text());realm=state['realm'];users=state['users'];first.auth=state['provider_auth'];time.sleep(1)
        for peer,user in zip([caller,phone],users):
            result=peer.exchange('REGISTER','sip:'+realm,(bind,5060),user['auth'],realm,user['password'],expires=90)
            assert result['code']==200,'Fixture phone did not register'
            saved=json.loads(statefile.read_text());saved.setdefault('registration_call_ids',[]).append(result['callid'])
            statefile.write_text(json.dumps(saved));statefile.chmod(0o600)
        before=set(second.dialogs)
        result=caller.call('sip:99101@'+realm,(bind,5060),users[0]['auth'],realm,users[0]['password'])
        audio_check(result,second,before);caller.hangup(result)
        assert first.invites[-1]['number']==second.invites[-1]['number']=='55101','Per-route number rewrite failed'
        assert '+27100000002' in second.invites[-1]['headers']['from'],'Failover retained the wrong caller ID'
        assert 'sip:+27100000002@' in second.invites[-1]['headers']['contact'],'Dynamic provider Contact identity was lost'
        assert '+27100000002' in second.invites[-1]['headers'].get('remote-party-id',''),'Provider caller ID header was lost'
        codec_check(second.invites[-1]);assert second.dialogs[second.invites[-1]['callid']]['pt']==8,'Provider did not select PCMA'
        before=len(second.invites)
        result=caller.call('sip:99102@'+realm,(bind,5060),users[0]['auth'],realm,users[0]['password'])
        assert result['code'] in (486,600),'Busy destination did not return busy'
        time.sleep(.2);assert len(second.invites)==before,'A busy call escaped to the second provider'
        before=set(first.dialogs)
        result=caller.call('sip:99104@'+realm,(bind,5060),users[0]['auth'],realm,users[0]['password'])
        audio_check(result,first,before);caller.hangup(result)
        assert first.auth_passed==1,'Provider digest authentication did not succeed'
        assert first.register_requests==second.register_requests==0,'A nonregistering provider received REGISTER'
        callback_check(root,statefile,phone,first,second,'99101',second)
        before=first.auth_passed
        callback_check(root,statefile,phone,first,second,'99104',first)
        assert first.auth_passed==before+1,'Callback worker provider digest authentication failed'
        assert first.register_requests==second.register_requests==0,'Callback worker sent REGISTER to a nonregistering provider'
        for invite in first.invites+second.invites:codec_check(invite)
        before=set(phone.dialogs)
        result=first.call('sip:contact-alias@'+bind,(bind,5080),to_uri='sip:999100001@'+bind)
        audio_check(result,phone,before);first.hangup(result)
        result=first.call('sip:contact-alias@'+bind,(bind,5080),to_uri='sip:999100002@'+bind)
        assert result['code']>=400,'An unconfigured incoming number was accepted'
        result=first.call('sip:contact-alias@'+bind+';gw='+state['gateway_ids'][1],(bind,5080),to_uri='sip:999100001@'+bind)
        assert result['code']>=400,'An incoming number accepted the wrong provider binding'
        result=foreign.call('sip:contact-alias@'+bind,(bind,5080),to_uri='sip:999100001@'+bind)
        assert result['code']>=400,'Unapproved incoming source was accepted'
        subprocess.run(['php',str(root/'tests/sip_trunk_live_fixture.php'),'disable',str(statefile)],check=True,cwd=root,timeout=60)
        result=first.call('sip:contact-alias@'+bind,(bind,5080),to_uri='sip:999100001@'+bind)
        assert result['code']>=400,'Disabled provider remained reachable through cached incoming rules'
        print('PASS: actual-engine outgoing and durable external callback provider failover, per-route rewrite/From/Contact/caller-ID headers, ordinary and callback provider digest without REGISTER, negotiated PCMA and paced two-way RTP; completed one-attempt callback jobs; busy stops; To-header incoming routing; unconfigured number, wrong gateway, unapproved source and disabled provider rejected.')
    finally:
        if state:
            for peer,user in zip([caller,phone],state['users']):
                try:peer.exchange('REGISTER','sip:'+state['realm'],(bind,5060),user['auth'],state['realm'],user['password'],expires=0)
                except Exception:pass
        for peer in peers:peer.close()
        if statefile.exists():
            saved=json.loads(statefile.read_text())
            saved['call_ids']=sorted({cid for peer in peers for cid in peer.queues}|{i['callid'] for peer in peers for i in peer.invites})
            saved['registration_call_ids']=sorted({cid for peer in peers for cid in peer.registration_call_ids})
            statefile.write_text(json.dumps(saved));statefile.chmod(0o600)
            subprocess.run(['php',str(root/'tests/sip_trunk_live_fixture.php'),'cleanup',str(statefile)],check=True,cwd=root,timeout=60)
            cleaned=True
        if cleaned or not statefile.exists():shutil.rmtree(private)


if __name__=='__main__':main()
