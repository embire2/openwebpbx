#!/usr/bin/env python3
"""Opt-in, private nspawn-only callback SIP/RTP qualification. No real providers."""
import json, os, secrets, socket, subprocess, sys, time, threading
from pathlib import Path
from pbx_v20_restore_native import SourcePhone, rtp_rate_check, decoded_tone_check

assert socket.gethostname()=='owpbx-native112-fresh' and Path('/run/systemd/container').read_text().strip()=='systemd-nspawn'
assert os.environ.get('OPENWEB_CMB_NATIVE_TEST')=='1'
source=Path('/root/cmb-source/tests'); state_path='/tmp/openweb-trunk-check-cmb-'+secrets.token_hex(6)+'.json'
provider=[SourcePhone({'number':'local','auth':'local','password':'fictional','local_provider':True,'tone_hz':600+i*150},'provider.invalid') for i in range(2)]
reports=[]
lock_next_answer=False
for item in provider:
    original=item.response
    def response(code,h,body='',_item=item,_original=original):
        global lock_next_answer
        if code==200 and h.get('cseq','').endswith('INVITE') and h.get('call-id') in _item.dialogs:
            state=_item.dialogs[h['call-id']]
            if lock_next_answer and '0820000002@' in h.get('to',''):
                lock_next_answer=False
                process=subprocess.Popen(['php',str(source/'pbx_call_me_back_native_fixture.php'),'lock_answer',state_path],stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
                assert process.stdout.readline().strip()=='LOCKED','Answer delay fixture failed to acquire its owned row'
                state['accounting_lock']=process
            state['answer_sent_at']=time.monotonic()
        return _original(code,h,body)
    item.response=response
def php(action,*args,base=False):
    file=source/('sip_trunk_live_fixture.php' if base else 'pbx_call_me_back_native_fixture.php')
    r=subprocess.run(['php',str(file),action,state_path,*map(str,args)],env=os.environ|{'OPENWEB_LIVE_TRUNK_TEST':'1'},capture_output=True,text=True)
    if r.returncode: raise RuntimeError('Owned PHP callback fixture failed: '+r.stderr[-1500:])
    return r.stdout.strip()
def status(): return json.loads(php('status'))
def wait(fn,seconds=20,label='condition'):
    end=time.monotonic()+seconds
    while time.monotonic()<end:
        value=fn()
        if value:return value
        time.sleep(.1)
    raise AssertionError('Timed out: '+label)
def callback_dialog(before):
    for p in provider:
        for cid,s in p.dialogs.items():
            if cid not in before and s.get('incoming') and '0820000001@' in s['incoming']['headers']['to']:
                return p,cid,s

def new_inbound(early=False):
    before={cid for p in provider for cid in p.dialogs}
    caller=provider[0]
    c=caller.call('sip:999100001@'+f['realm'],('127.0.0.1',5080),user=f['cmb_cli'],realm=f['realm'],to_uri='sip:999100001@'+f['realm'])
    assert c['code']==200,'Incoming callback DID did not answer'
    if early:
        wait(lambda:c['media']['received']>20,5,'early incoming announcement')
        caller.hangup(c)
    wait(lambda:c['media'].get('ended'),30,'incoming announcement hangup')
    p,cid,s=wait(lambda:callback_dialog(before),15,'immediate real callback')
    assert c['media']['received']>20,'Incoming Nathaniel announcement had no decoded RTP'
    wait(lambda:s.get('acked'),3,'callback SIP ACK')
    return p,cid,s

def digits(p,cid,s,text):
    call={'media':s,'text':p.sdp(s),'callid':cid}
    for digit in text:p.dtmf(call,digit)

def connected_target(exclude):
    for p in provider:
        for cid,s in p.dialogs.items():
            if cid not in exclude and s.get('incoming') and '0820000002@' in s['incoming']['headers']['to'] and not s.get('ended'):
                return p,cid,s

def run(auth,quota=None,cap=False,early=False,locked=False):
    global lock_next_answer
    php('reset')
    if quota is not None:php('quota',quota)
    before={cid for p in provider for cid in p.dialogs}
    p,cid,s=new_inbound(early);wait(lambda:s['received']>40,10,'callback greeting audio')
    if auth:
        digits(p,cid,s,f['cmb_identity']+'#')
        wait(lambda:status()['request']['state']=='dialling',15,'successful SA-ID authentication')
        time.sleep(6)
    else:
        wait(lambda:status()['request']['state']=='dialling',6,'saved caller authentication')
        time.sleep(1)
    lock_next_answer=locked
    digits(p,cid,s,f['cmb_destination']+'#')
    target,tcid,ts=wait(lambda:connected_target(before),15,'destination bridge')
    wait(lambda:status()['request']['state']=='connected',5,'durable destination answer')
    start=ts.get('answer_sent_at',time.monotonic()) if cap else time.monotonic();remaining=status()['request']['reserved_seconds'];s['decoded_pcm'].clear();ts['decoded_pcm'].clear()
    task=json.loads(php('engine','show tasks as json'))
    rows=task.get('rows',[])
    assert any(('openweb-cmb-active-'+status()['request']['request_uuid']) in json.dumps(row) for row in rows),'A-leg hard cutoff task missing'
    if cap:
        wait(lambda:s.get('ended') and ts.get('ended'),remaining+8,'native allowance cutoff on both legs')
        elapsed=time.monotonic()-start
        assert remaining-2<=elapsed<=remaining+4,'Native hard cutoff did not respect reserved talk seconds'
    else:
        time.sleep(2)
        target.hangup_incoming(tcid);wait(lambda:s.get('ended'),5,'bridge remote hangup')
        elapsed=time.monotonic()-start
    final=wait(lambda:(lambda x:x if x['request']['state'] in ('completed','failed') else None)(status()),8,'exact usage settlement')
    assert final['request']['state']=='completed' and final['request']['used_seconds']>0
    assert final['request']['used_seconds']<=remaining<=600
    assert final['account']['reserved_seconds']==0
    if ts.get('accounting_lock'):
        ts['accounting_lock'].communicate(timeout=2);assert ts['accounting_lock'].returncode==0
    # Actual decoded voice and negotiated media, rather than signalling-only success.
    assert len(s.get('decoded_pcm',b''))>1000 and len(ts.get('decoded_pcm',b''))>1000
    assert s['received']>20 and ts['received']>20
    caller_ratio=decoded_tone_check(s,target.tone_hz);destination_ratio=decoded_tone_check(ts,p.tone_hz)
    report={'new_identity':auth,'caller_ended_announcement':early,'accounting_delay_seconds':3 if locked else 0,'saved_authentication':not auth,'native_cap_seconds':remaining if cap else None,'observed_connected_seconds':round(elapsed,2),'charged_seconds':final['request']['used_seconds'],'reservation_released':True,'incoming_hangup_before_callback':True,'decoded_two_way_media':True,'caller_remote_tone_ratio':caller_ratio,'destination_remote_tone_ratio':destination_ratio,'no_carrier_traffic':True}
    reports.append(report);print('PASS native callback case '+json.dumps(report),flush=True)
try:
    php('create',*(p.port for p in provider),base=True)
    php('setup');f=json.loads(Path(state_path).read_text())
    if os.environ.get('OPENWEB_CMB_EDGES')=='1':
        for identity,expected in [(f['cmb_identity'],'quota_exhausted'),('8101025009083','authentication_failed')]:
            php('reset');php('quota',0 if expected=='quota_exhausted' else 3600)
            p,cid,s=new_inbound();wait(lambda:s['received']>40,10,'new caller authentication prompt');digits(p,cid,s,identity+'#');wait(lambda:s.get('ended'),15,'refused new caller')
            x=status();assert x['request']['last_result']==expected and x['account']['reserved_seconds']==0
            reports.append({'first_time_identity_outcome':expected,'no_destination_bridge':True});print('PASS native first-time identity outcome '+expected,flush=True)
        php('quota',3600)
    run(True)
    run(False)
    if os.environ.get('OPENWEB_CMB_EDGES')=='1':
        run(False,early=True)
        run(False,quota=5,cap=True,locked=True)
    run(False,quota=3,cap=True)
    php('reset');php('quota',0)
    before={cid for p in provider for cid in p.dialogs};p,cid,s=new_inbound();wait(lambda:s.get('ended'),15,'exhausted account announcement')
    x=status();assert x['request']['last_result']=='quota_exhausted' and x['account']['reserved_seconds']==0
    reports.append({'exhausted_account_no_reauthentication':True,'no_destination_bridge':not connected_target(before)})
    print('PASS native exhausted allowance announces quota without asking for identity',flush=True)
    if os.environ.get('OPENWEB_CMB_FULL_TIMEOUT')=='1':run(False,quota=600,cap=True)
finally:
    for p in provider:
        for cid,s in list(p.dialogs.items()):
            if s.get('incoming') and not s.get('ended'):
                try:p.hangup_incoming(cid)
                except Exception:pass
    # Whole new fixture DB will be removed only after source/config preservation checks.
    Path('/root/cmb-work/native-results.safe.json').write_text(json.dumps({'cases':reports,'all_expected_cases_passed':len(reports)==(4+(1 if os.environ.get('OPENWEB_CMB_FULL_TIMEOUT')=='1' else 0)+(4 if os.environ.get('OPENWEB_CMB_EDGES')=='1' else 0)),'local_software_peers_only':True},indent=2))
    for p in provider:p.close()
