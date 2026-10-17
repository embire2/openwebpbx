#!/usr/bin/env python3
"""Actual duplicate internal delivery must not remove a running call's native caps."""
import json,os,subprocess
from pathlib import Path
# Reuse the frozen SIP/RTP fixture definitions, without executing its main cases.
path=Path(__file__).with_name('pbx_call_me_back_native.py');text=path.read_text();marker="\ntry:\n    php('create'"
assert text.count(marker)==1
namespace={'__name__':'cmb_native_support'};exec(compile(text.split(marker)[0],str(path),'exec'),namespace)
provider=namespace['provider'];php=namespace['php'];reports=[];proof=None
original_php=php

def watched(action,*args,**kwargs):
    global proof
    result=original_php(action,*args,**kwargs)
    if action=='status' and proof is None:
        current=json.loads(result)
        if current['request'] and current['request']['state']=='connected':
            process=subprocess.run(['php',str(path.with_name('pbx_call_me_back_duplicate_fixture.php')),namespace['state_path']],capture_output=True,text=True)
            if process.returncode:raise AssertionError('Actual duplicate invocation did not preserve native caps: '+process.stderr[-500:])
            proof=json.loads(process.stdout)
    return result
namespace['php']=watched
try:
    php('create',*(p.port for p in provider),base=True);php('setup')
    namespace['f']=json.loads(Path(namespace['state_path']).read_text())
    namespace['run'](True,quota=3,cap=True)
    assert proof and proof['timers_before']==proof['timers_after']==2
    result={'duplicate_active_request_keeps_both_native_timers':True,'three_second_native_cutoff_after_duplicate':True,'decoded_two_way_media':True,'facts':proof,'normal_case':namespace['reports'][0]}
    Path('/root/cmb-work/native-duplicate-results.safe.json').write_text(json.dumps(result,indent=2));print('PASS native duplicate delivery preserves both timers and the actual three-second two-way call cutoff',flush=True)
finally:
    for p in provider:
        for cid,state in list(p.dialogs.items()):
            if state.get('incoming') and not state.get('ended'):
                try:p.hangup_incoming(cid)
                except Exception:pass
        p.close()
