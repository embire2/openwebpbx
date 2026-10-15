#!/usr/bin/env python3
"""Actual loopback RTP/telephone-event checks; no PBX or customer is contacted."""
import importlib.util
from pathlib import Path
import socket
import struct
import time

def module(name,path):
    spec=importlib.util.spec_from_file_location(name,path)
    value=importlib.util.module_from_spec(spec);spec.loader.exec_module(value);return value

root=Path(__file__).parent
native=module('ivr_native_support',root/'windows-native-acceptance.py')
source=module('ivr_source_phone',root/'pbx_v20_restore_native.py')
checks=0
def check(value):
    global checks
    assert value;checks+=1

def wait(predicate,seconds):
    end=time.monotonic()+seconds
    while time.monotonic()<end:
        value=predicate()
        if value:return value
        time.sleep(.005)
    raise AssertionError('Bounded actual peer observation expired')

record={'number':'9001','auth':'fictional-ivr-wire','password':'fictional-local-only'}
answer='SIP/2.0 200 OK\r\n\r\nm=audio 1 RTP/AVP 0 101\r\na=rtpmap:101 telephone-event/8000\r\n'

def wire_case(corrected,digit='2'):
    receiver=socket.socket(socket.AF_INET,socket.SOCK_DGRAM);receiver.bind(('127.0.0.1',0));receiver.settimeout(2)
    phone=source.SourcePhone(record,'ivr-wire-check.invalid','127.0.0.1')
    media=phone.media();media['dtmf_events']=[]
    # Queue the old first event BEFORE exposing its target to the actual sender.
    # This deterministically reproduces the immediate-key scheduling order.
    if not corrected:media['dtmf_events'].append({'digit':int(digit)})
    media['target']=receiver.getsockname();phone.dialogs['owned-wire-case']=media
    packets=[]
    try:
        if corrected:
            native.send_ivr_digit(phone,{'text':answer,'media':media},digit,wait)
        until=time.monotonic()+2
        while time.monotonic()<until:
            packet,_=receiver.recvfrom(4096)
            if len(packet)<12:continue
            _,payload_type,sequence,timestamp,ssrc=struct.unpack('!BBHII',packet[:12])
            packets.append((payload_type&127,sequence,timestamp,packet[12:]))
            if sum(p[0]==101 for p in packets)>=12 and any(p[0]==0 for p in packets):break
        events=[p for p in packets if p[0]==101]
        check(len(events)==12)
        check(all(len(p[3])==4 and p[3][0]==int(digit) for p in events))
        check(len({p[2] for p in events})==1)
        check(sum(bool(p[3][1]&128) for p in events)==3)
        check(all(struct.unpack('!H',p[3][2:])[0]<=1600 for p in events))
        check(all((b[1]-a[1])%65536==1 for a,b in zip(packets,packets[1:])))
        first=next(i for i,p in enumerate(packets) if p[0]==101)
        if corrected:
            check(first>0 and any(p[0]==0 for p in packets[:first]))
            check(events[0][2]>0)
        else:
            check(first==0)
            check(events[0][2]==0)
        return events[0][2]
    finally:
        media['ended']=True;phone.close();receiver.close()

for digit in ('2','1'):
    old=wire_case(False,digit);new=wire_case(True,digit)
    check(old==0 and new>0)
sent=[]
class StoppedPhone:
    def dtmf(self,*args):sent.append(True);return True
def expired(predicate,seconds):
    check(seconds==3 and not predicate())
    raise TimeoutError('No actual initial RTP')
try:native.send_ivr_digit(StoppedPhone(),{'media':{'sent':0,'rtp_clock':0}},'2',expired)
except TimeoutError:check(sent==[])
else:raise AssertionError('A key was fabricated without actual media')
print(f'PASS {checks} actual loopback RTP/DTMF and missing-media controls; no PBX contacted')
