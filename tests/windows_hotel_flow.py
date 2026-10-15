#!/usr/bin/env python3
"""Actual owned-hotel classifier/wait controls; no PBX or external endpoint."""
import ast
import importlib.util
import json
from pathlib import Path
from types import SimpleNamespace

root=Path(__file__).parent
spec=importlib.util.spec_from_file_location('hotel_native',root/'windows-native-acceptance.py')
native=importlib.util.module_from_spec(spec);spec.loader.exec_module(native)
checks=0
def check(value):
    global checks
    assert value
    checks+=1

row={'kind':'wakeup','target_number':'8102','state':'calling','attempts':1,'max_attempts':3,
     'due':True,'expired':False,'lease_expired':False,'has_lease':True,
     'call_uuid':'11111111-1111-4111-8111-111111111111','last_result':'Wake-up was not confirmed',
     'password':'PRIVATE_DO_NOT_PUBLISH'}
facts=native.hotel_job_facts([row])
check(facts['job_count']==1 and facts['job_state']=='calling' and facts['result_class']=='unconfirmed')
check(facts['target_matches'] is True and facts['has_call_uuid'] is True)
check('PRIVATE_' not in json.dumps(facts) and '11111111-' not in json.dumps(facts) and 'last_result' not in facts)
check(native.hotel_job_facts([])=={'job_count':0,'job_state':'absent'})
check(native.hotel_job_facts([row|{'kind':'callback'}])=={'job_count':0,'job_state':'absent'})
check(native.hotel_job_facts([row,row])=={'job_count':2,'job_state':'unknown'})
for result,kind in [('Room is checked out','room_checked_out'),('Room phone unavailable','room_unavailable'),
                    ('Room did not answer','room_no_answer'),('Wake-up confirmed','confirmed'),
                    ('PRIVATE_DO_NOT_PUBLISH','unknown')]:
    check(native.hotel_job_facts([row|{'last_result':result}])['result_class']==kind)
for field in ('attempts','max_attempts'):
    for value in (True,'1',-1,1001,1.5):check(field not in native.hotel_job_facts([row|{field:value}]))
for field in ('due','expired','lease_expired','has_lease'):
    for value in (1,'true',None):check(field not in native.hotel_job_facts([row|{field:value}]))
check(native.hotel_job_facts([row|{'target_number':'9999'}])['target_matches'] is False)
check(native.hotel_job_facts([row|{'state':'PRIVATE_DO_NOT_PUBLISH'}])['job_state']=='unknown')
peer=SimpleNamespace(dialogs={'old':{'acked':True},'fresh':{'acked':True,'ended':False,'sent':12,'received':8,'rtp_clock':1920}},
                     invites=[{},{}],receiver_failure=None)
fixture=SimpleNamespace(cli=lambda action:{'jobs':[row]})
snapshot,complete=native.hotel_snapshot(fixture,peer,{'dialogs':{'old'},'invites':1},'after',{'completed':True,'clock_started':True})
check(complete and snapshot['hotel_after_peer_invites']==1 and snapshot['hotel_after_peer_acks']==1)
check(snapshot['hotel_after_peer_open_dialogs']==1 and snapshot['hotel_after_peer_ended']==0)
check(snapshot['hotel_after_dtmf_completed'] and snapshot['hotel_after_dtmf_clock_started'])
check('PRIVATE_' not in json.dumps(snapshot) and 'call_uuid' not in snapshot)
def fails(action):raise RuntimeError('PRIVATE_DO_NOT_PUBLISH')
snapshot,complete=native.hotel_snapshot(SimpleNamespace(cli=fails),peer,{'dialogs':set(peer.dialogs),'invites':2},'after')
check(not complete and snapshot['hotel_after_peer_invites']==0 and snapshot['hotel_after_dtmf_attempted'] is False)
snapshot,complete=native.hotel_snapshot(fixture,SimpleNamespace(),{'dialogs':set(),'invites':0},'after',{'completed':False})
check(not complete and snapshot['hotel_after_dtmf_completed'] is False)
check('hotel_after_dtmf_clock_started' not in snapshot)
for stage,seconds in [('hotel_phone_answer',25),('hotel_job_completed',20)]:
    observed=[]
    def wait(predicate,timeout):observed.append(timeout);raise AssertionError('owned controlled wait')
    f=SimpleNamespace(wait=wait)
    try:native.hotel_wait(f,stage,lambda:False,seconds)
    except AssertionError as error:
        check(observed==[seconds] and f.native_substage==stage)
        check(error.native_failure['primary_substage']==stage)
    else:raise AssertionError('The actual hotel wait did not preserve failure')
tree=ast.parse((root/'windows-native-acceptance.py').read_text())
body=next(node for node in tree.body if isinstance(node,ast.FunctionDef) and node.name=='native_calls')
digits=[node for node in ast.walk(body) if isinstance(node,ast.Call) and isinstance(node.func,ast.Name) and node.func.id=='send_ivr_digit' and len(node.args)>2 and isinstance(node.args[2],ast.Constant) and node.args[2].value=='1']
check(len(digits)==1)
print(f'PASS {checks} actual hotel job/snapshot/deadline/source-wiring controls; no PBX contacted')
