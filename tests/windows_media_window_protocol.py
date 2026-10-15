#!/usr/bin/env python3
"""Real SourcePhone loopback RTP sampling; no PBX, codec DLL or customer access.

An owned UDP relay models the IVR's prompt/wait phase before a steady bridge.
It also introduces real silence, missing/stale media, and bad packet pacing.
"""
import importlib.util
from pathlib import Path
import socket
import threading
import time

ROOT=Path(__file__).parent
def module(name,path):
    spec=importlib.util.spec_from_file_location(name,path)
    result=importlib.util.module_from_spec(spec);spec.loader.exec_module(result);return result
native=module('window_native_support',ROOT/'windows-native-acceptance.py')
source=module('window_source_phone',ROOT/'pbx_v20_restore_native.py')
checks=0
def check(value):
    global checks
    assert value;checks+=1
def wait(predicate,seconds=3):
    deadline=time.monotonic()+seconds
    while time.monotonic()<deadline:
        if predicate():return
        time.sleep(.005)
    raise AssertionError('Owned RTP fixture did not become ready')

relay=socket.socket(socket.AF_INET,socket.SOCK_DGRAM)
relay.bind(('127.0.0.1',0));relay.settimeout(.02)
phones=[source.SourcePhone({'number':str(9001+i),'auth':'fictional-window-'+str(i),
    'password':'fictional-local-only','tone_hz':frequency},'media-window.invalid') for i,frequency in enumerate((440,550))]
states=[phone.media() for phone in phones]
mode={'kind':'initial','packets':0};stop=threading.Event();errors=[]
def forward():
    try:
        while not stop.is_set():
            try:packet,_=relay.recvfrom(4096)
            except socket.timeout:continue
            mode['packets']+=1;kind=mode['kind']
            if kind=='initial' and mode['packets']>4:continue
            if kind=='missing':continue
            if kind=='low' and mode['packets']%4:continue
            if kind=='stale' and time.monotonic()>mode['until']:continue
            if kind=='late' and time.monotonic()<mode['after']:continue
            if kind=='silence':packet=packet[:12]+bytes([255])*len(packet[12:])
            for unused in range(4 if kind=='high' else 1):relay.sendto(packet,states[0]['socket'].getsockname())
    except BaseException as error:
        if not stop.is_set():errors.append(error)
worker=threading.Thread(target=forward);worker.start()
states[0]['target']=states[1]['socket'].getsockname();states[1]['target']=relay.getsockname()
for phone,state in zip(phones,states):phone.dialogs['owned-media-window']=state
owned={'caller':states[0],'destination':states[1]}
try:
    wait(lambda:states[0]['received']>=4 and states[1]['received']>=4)
    # Genuine early prompt packets followed by a real receive gap. Keep every
    # lifetime counter/timestamp untouched so the old rate can be compared.
    time.sleep(4.2)
    check(states[0]['received']==4)
    mode['kind']='normal'
    views=native.bridged_media_window(owned,5,source.rtp_rate_check)
    for peer,frequency in [('caller',550),('destination',440)]:
        source.rtp_rate_check(views[peer]);check(True)
        check(source.decoded_tone_check(views[peer],frequency)>=.8)
        check(views[peer]['sent']>=150 and views[peer]['received']>=150)
    lifetime_rate=(states[0]['received']-1)/(states[0]['received_last_at']-states[0]['received_first_at'])
    fresh_rates={peer:round((view['received']-1)/(view['received_last_at']-view['received_first_at']),3) for peer,view in views.items()}
    check(lifetime_rate<30)
    try:source.rtp_rate_check(states[0])
    except AssertionError as error:check('RTP pacing' in str(error))
    else:raise AssertionError('The original cumulative IVR mismatch was not reproduced')
    check(all(phone.thread.is_alive() for phone in phones))
    # Every refusal uses actual datagrams observed by the unchanged SourcePhone.
    # A missing or prematurely stopped stream must not borrow earlier traffic.
    for kind in ('missing','low','high','stale','late'):
        mode['kind']=kind
        if kind=='stale':mode['until']=time.monotonic()+.4
        elif kind=='late':mode['after']=time.monotonic()+.4
        else:time.sleep(.08)
        try:native.bridged_media_window(owned,1,source.rtp_rate_check)
        except AssertionError as error:
            facts=error.media_failure
            check(facts['media_peer']=='caller' and facts['media_direction']=='received')
            check(facts['media_window_seconds']==1)
            if kind=='missing':check(facts['media_packets']==0)
            elif kind=='low':check(facts['media_rate_pps']<30)
            elif kind=='high':check(facts['media_rate_pps']>70)
            elif kind=='stale':check('stopped before' in str(error))
            else:check('did not begin' in str(error))
            check('start_counts' in error.media_window_private)
        else:raise AssertionError('Invalid fresh RTP was accepted: '+kind)
    mode['kind']='silence';time.sleep(.08)
    views=native.bridged_media_window(owned,1,source.rtp_rate_check)
    source.rtp_rate_check(views['caller']);check(True)
    try:source.decoded_tone_check(views['caller'],550)
    except AssertionError as error:check('silent' in str(error))
    else:raise AssertionError('Paced silence passed the unchanged decoded-audio assertion')
    mode['kind']='normal';time.sleep(.08)
    views=native.bridged_media_window(owned,1,source.rtp_rate_check)
    check(source.decoded_tone_check(views['caller'],550)>=.8)
    try:source.decoded_tone_check(views['caller'],440)
    except AssertionError as error:check('tone did not cross' in str(error))
    else:raise AssertionError('The wrong decoded tone was accepted')
finally:
    stop.set()
    for state in states:state['ended']=True
    for phone in phones:phone.close()
    worker.join(3);relay.close()
check(not errors and not worker.is_alive() and all(not phone.thread.is_alive() for phone in phones))
print(f'PASS {checks} actual SourcePhone RTP window/prompt-gap/pacing/freshness/decoded-tone controls; no PBX contacted')
print(f'Actual rates: old cumulative caller received={lifetime_rate:.3f}pps; fresh five-second caller={fresh_rates["caller"]:.3f}pps/destination={fresh_rates["destination"]:.3f}pps; unchanged30..70pps threshold')
