#!/usr/bin/env python3
"""Actual loopback UDP loss controls for the exact SIP peers; no PBX required."""
import argparse
import importlib.util
import json
from pathlib import Path
import secrets
import socket
import sys
import threading
import time


def load(name,path):
    spec=importlib.util.spec_from_file_location(name,path)
    module=importlib.util.module_from_spec(spec);sys.modules[name]=module
    spec.loader.exec_module(module);return module


def udp():
    sock=socket.socket(socket.AF_INET,socket.SOCK_DGRAM)
    sock.bind(('127.0.0.1',0));sock.settimeout(.02);return sock


def wait(predicate,seconds=2):
    end=time.monotonic()+seconds
    while time.monotonic()<end:
        value=predicate()
        if value:return value
        time.sleep(.005)
    raise AssertionError('Bounded loopback SIP observation expired')


def sdp(port):
    return f'v=0\r\no=fixture 1 1 IN IP4 127.0.0.1\r\ns=transaction loss\r\nc=IN IP4 127.0.0.1\r\nt=0 0\r\nm=audio {port} RTP/AVP 0\r\na=rtpmap:0 PCMU/8000\r\na=sendrecv\r\n'


def request(method,local,cid,seq,fh,th,body=''):
    lines=[method+' sip:8101@lifecycle.invalid SIP/2.0',
        f'Via: SIP/2.0/UDP 127.0.0.1:{local[1]};branch=z9hG4bK'+secrets.token_hex(8),
        'Max-Forwards: 20','From: '+fh,'To: '+th,'Call-ID: '+cid,
        f'CSeq: {seq} {method}',f'Contact: <sip:fixture@127.0.0.1:{local[1]}>']
    if body:lines.append('Content-Type: application/sdp')
    return ('\r\n'.join(lines+[f'Content-Length: {len(body.encode())}','',''])+body).encode()


def response(sip,data,local,body=''):
    h=sip.headers(data.decode());lines=['SIP/2.0 200 OK']
    for name in ('Via','From','To','Call-ID','CSeq'):
        value=h[name.lower()]
        if name=='To' and ';tag=' not in value:value+=';tag=loss-control'
        lines.append(name+': '+value)
    lines.append(f'Contact: <sip:fixture@127.0.0.1:{local[1]}>')
    if body:lines.append('Content-Type: application/sdp')
    return ('\r\n'.join(lines+[f'Content-Length: {len(body.encode())}','',''])+body).encode()


def receive(sock,predicate,seconds=2):
    end=time.monotonic()+seconds
    while time.monotonic()<end:
        try:data,address=sock.recvfrom(65535)
        except socket.timeout:continue
        assert address[0]=='127.0.0.1'
        if predicate(data):return data
    raise AssertionError('Expected actual UDP SIP packet did not arrive')


def lost_ack(factory,sip):
    peer=factory();raw=udp();media=udp();target=('127.0.0.1',peer.port)
    cid=secrets.token_hex(12)+'@loss-control';fh='<sip:fixture@lifecycle.invalid>;tag=caller';th='<sip:8101@lifecycle.invalid>'
    try:
        invite=request('INVITE',raw.getsockname(),cid,1,fh,th,sdp(media.getsockname()[1]));raw.sendto(invite,target)
        first=receive(raw,lambda p:p.startswith(b'SIP/2.0 200 '))
        state=wait(lambda:peer.dialogs.get(cid));media_socket=state['socket'];sent=state['sent'];h=sip.headers(first.decode())
        # First ACK is intentionally lost. Wrong tags/CSeq must not quench 2xx.
        raw.sendto(request('ACK',raw.getsockname(),cid,1,fh,h['to'].replace('tag=','tag=wrong-')),target)
        second=receive(raw,lambda p:p.startswith(b'SIP/2.0 200 '))
        assert second==first and not state.get('acked')
        raw.sendto(request('ACK',raw.getsockname(),cid,2,fh,h['to']),target)
        third=receive(raw,lambda p:p.startswith(b'SIP/2.0 200 '))
        assert third==first and not state.get('acked')
        assert len(peer.dialogs)==1 and peer.dialogs[cid] is state and state['socket'] is media_socket and state['sent']>sent
        raw.sendto(request('ACK',raw.getsockname(),cid,1,fh,h['to']),target)
        wait(lambda:state.get('acked'));assert state.get('acked_cseq')==1
        end=time.monotonic()+2.1
        while time.monotonic()<end:
            try:packet,_=raw.recvfrom(65535)
            except socket.timeout:continue
            assert not packet.startswith(b'SIP/2.0 200 '),'INVITE replay continued after matching ACK'
        # Cached duplicate INVITE reuses the same dialog/media and response.
        raw.sendto(invite,target);assert receive(raw,lambda p:p.startswith(b'SIP/2.0 200 '))==first
        assert len(peer.dialogs)==1 and peer.dialogs[cid] is state and state['socket'] is media_socket
        raw.sendto(request('BYE',raw.getsockname(),cid,2,fh,h['to']),target)
        receive(raw,lambda p:p.startswith(b'SIP/2.0 200 ') and b'CSeq: 2 BYE' in p)
        wait(lambda:state.get('ended'));assert not peer._invite_2xx
        return {'case':'lost-ACK','matching_ACK_only':True,'identical_200_replays':2,'single_dialog_media':True,'stopped_after_ACK':True,'exact_cleanup':True}
    finally:
        peer.close();raw.close();media.close();assert not peer.thread.is_alive()


def bye_loss(factory,sip,loss):
    peer=factory();remote=udp();media=udp();stop=threading.Event();released=threading.Event();first_processed=threading.Event()
    byes=[];acks=[];responses=[];errors=[]
    def serve():
        try:
            while not stop.is_set():
                try:data,address=remote.recvfrom(65535)
                except socket.timeout:continue
                assert address[0]=='127.0.0.1'
                if data.startswith(b'INVITE '):remote.sendto(response(sip,data,remote.getsockname(),sdp(media.getsockname()[1])),address)
                elif data.startswith(b'ACK '):acks.append(data)
                elif data.startswith(b'BYE '):
                    byes.append(data)
                    if len(byes)==1 and loss=='initial-BYE':first_processed.set();continue
                    released.set();answer=response(sip,data,remote.getsockname())
                    if len(byes)==1 and loss=='BYE-response':first_processed.set();continue
                    # A response with the wrong Via branch must not complete it.
                    wrong=answer.replace(b'branch=z9hG4bK',b'branch=z9hG4bKwrong')
                    remote.sendto(wrong,address);time.sleep(.04)
                    responses.append(answer);remote.sendto(answer,address)
        except BaseException as error:
            if not stop.is_set():errors.append(error)
    worker=threading.Thread(target=serve);worker.start()
    hanging=None
    try:
        call=peer.call('sip:fixture@lifecycle.invalid',remote.getsockname());assert call['code']==200;wait(lambda:acks)
        failures=[];completed=threading.Event();started=time.monotonic()
        def hangup():
            try:peer.hangup(call)
            except BaseException as error:failures.append(error)
            finally:completed.set()
        hanging=threading.Thread(target=hangup);hanging.start()
        wait(lambda:first_processed.is_set());assert call['media'].get('ended') and not completed.is_set()
        assert released.is_set()==(loss=='BYE-response')
        wait(lambda:completed.is_set());hanging.join(1)
        assert not errors and not failures and released.is_set() and len(byes)==2 and byes[0]==byes[1]
        transaction=call['media']['bye_transaction']
        assert transaction['done'].is_set() and transaction['error'] is None and transaction['response']==responses[0].decode()
        assert not peer._bye_transactions and .45<=time.monotonic()-started<2
        before=len(byes);peer.hangup(call);assert len(byes)==before,'Repeated cleanup started a second BYE transaction'
        return {'case':'lost-'+loss,'BYE_requests':2,'stable_branch_CSeq_bytes':True,'local_termination_immediate':True,'final_response_required':True,'remote_released':True,'exact_cleanup':True}
    finally:
        if hanging:hanging.join(3)
        peer.close();stop.set();worker.join(1);remote.close();media.close()
        if hanging:hanging.join(1)
        assert not peer.thread.is_alive() and not worker.is_alive() and (hanging is None or not hanging.is_alive())


def main():
    parser=argparse.ArgumentParser();parser.add_argument('--source-root',type=Path,default=Path(__file__).resolve().parents[1]);parser.add_argument('--report',type=Path)
    args=parser.parse_args();sip=load('sip_trunk_live',args.source_root/'tests/sip_trunk_live.py');original=load('transaction_source_phone',args.source_root/'tests/pbx_v20_restore_native.py')
    rows=[]
    for kind in ('Peer','SourcePhone'):
        def factory():
            return sip.Peer('127.0.0.1') if kind=='Peer' else original.SourcePhone({'number':'8101','auth':'fictional-auth','password':'fictional-only'},'lifecycle.invalid','127.0.0.1')
        for operation in (lambda:lost_ack(factory,sip),lambda:bye_loss(factory,sip,'initial-BYE'),lambda:bye_loss(factory,sip,'BYE-response')):
            rows.append({'peer':kind,**operation()})
    report={'schema':1,'loopback_only':True,'PBX_contacted':False,'intentional_loss':True,'actual_CI_failure_cause_established':False,'cases':rows,'passed':True}
    if args.report:
        args.report.write_text(json.dumps(report,indent=2)+'\n');args.report.chmod(0o600)
    print('PASS six actual Peer/SourcePhone UDP lost-ACK/lost-initial-BYE/lost-BYE-response controls; exact packets, matching transactions, immediate local termination, single dialog/media and cleanup; no PBX or CI-cause claim')


if __name__=='__main__':main()
