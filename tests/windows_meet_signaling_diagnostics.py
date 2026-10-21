"""Actual QA observer tests: method/status/HTTP enums only, no SIP/SDP secrets."""
import copy
import importlib.util
import json
from pathlib import Path
import shutil
import subprocess
import sys
import unittest

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('windows_meet_signaling', ROOT/'tests/windows-meet-browser.py')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
PRIVATE = 'PRIVATE_cookie_SDP_password_URI'


def peer():
    return dict(observed=True, endpoint_match=True, counts_capped=False,
                local_description=True, remote_description=False, admit_ok=True,
                ws_observed=1, ws_closed=0, ws_errors=0, sent_register=0, sent_invite=2,
                admit_requests=1, admit_responses=1, status_requests=1, status_responses=1,
                http_failures=0, api_json_failures=0, admit_http_status=200, status_http_status=200,
                signaling_state='have-local-offer', ice_gathering_state='complete',
                member_state='admitted', register_codes=[], invite_codes=[401, 200])


class SignalingDiagnosticControls(unittest.TestCase):
    def test_python_closed_shape_types_codes_and_privacy(self):
        valid = {'host': peer(), 'guest': peer() | {'member_state': 'waiting'}}
        self.assertEqual(module.signaling_fields(valid), {'meeting_signaling': valid})
        self.assertEqual(len(peer()), 24)
        for side in ('host', 'guest'):
            for name, value in valid[side].items():
                missing = copy.deepcopy(valid); del missing[side][name]
                self.assertEqual(module.signaling_fields(missing), {})
                if type(value) is bool:
                    invalid = [None, 1, 'true', PRIVATE]
                elif type(value) is int:
                    invalid = [-1, 600 if name.endswith('_http_status') else 513, True, 1.5, '1', 10**1000]
                elif isinstance(value, list):
                    invalid = [None, 200, '200', {}, [True], [99], [700], [200.0], [PRIVATE], [200]*17]
                else:
                    invalid = [PRIVATE, value.upper(), [], {}, None]
                for bad in invalid:
                    changed = copy.deepcopy(valid); changed[side][name] = bad
                    self.assertEqual(module.signaling_fields(changed), {}, (side, name, type(bad).__name__))
            extra = copy.deepcopy(valid); extra[side]['sdp'] = PRIVATE
            self.assertEqual(module.signaling_fields(extra), {})
        for invalid in [None, [], {}, valid | {'private': PRIVATE}, {'host': peer(), 'guest': None}]:
            self.assertEqual(module.signaling_fields(invalid), {})
        self.assertNotIn(PRIVATE, json.dumps(module.signaling_fields(valid)))

    @unittest.skipUnless(shutil.which('node'), 'Node required for actual event observer')
    def test_actual_websocket_http_and_pc_observers_are_closed_and_bounded(self):
        script = r'''
const {EventEmitter}=require('node:events'),vm=require('node:vm');
const observer=require(process.argv[1]);
const PRIVATE='PRIVATE_cookie_SDP_password_URI';
const origin='https://windowsqa.example.invalid:8443';
const page=new EventEmitter();
const pc={connectionState:'new',signalingState:'have-local-offer',iceGatheringState:'complete',localDescription:{sdp:PRIVATE},remoteDescription:null};
page.evaluate=async fn=>vm.runInNewContext('('+fn.toString()+')()',{window:{conferenceQA:{pcs:[pc]}}});
const row=observer.watch(page,origin);
const socket=new EventEmitter();socket.url=()=>origin.replace('https:','wss:')+'/meet-sip/';page.emit('websocket',socket);
function invite(){socket.emit('framesent',{payload:'INVITE sip:'+PRIVATE+' SIP/2.0\r\nAuthorization: '+PRIVATE+'\r\nCSeq: 1 INVITE\r\n\r\n'+PRIVATE});}
invite();invite();
socket.emit('framereceived',{payload:Buffer.from('SIP/2.0 401 Unauthorized\r\nCSeq: 1 INVITE\r\nPrivate: '+PRIVATE+'\r\n\r\n'+PRIVATE)});
socket.emit('framereceived',{payload:'SIP/2.0 200 OK\r\nCSeq: 2 INVITE\r\n\r\n'+PRIVATE});
socket.emit('framereceived',{payload:'SIP/2.0 200 OK\r\nCSeq: 3 BYE\r\n\r\n'+PRIVATE});
function request(action,url=origin+'/app/pbx_meet/api.php'){return {url:()=>url,method:()=> 'POST',postDataJSON:()=>({action,token:PRIVATE,member:PRIVATE})};}
function response(req,status,data){return {request:()=>req,status:()=>status,json:async()=>data};}
(async()=>{
 const admit=request('admit');page.emit('request',admit);page.emit('response',response(admit,200,{ok:true,private:PRIVATE}));
 const status=request('status');page.emit('request',status);page.emit('response',response(status,200,{state:'admitted',private:PRIVATE}));
 await new Promise(resolve=>setImmediate(resolve));
 const good=await observer.collect(page,row);
 const capped=observer.defaults(true);
 for(let i=0;i<513;i++)observer.parseFrame(capped,'REGISTER sip:'+PRIVATE+' SIP/2.0\r\nCSeq: 1 REGISTER\r\n\r\n',true);
 for(let i=0;i<20;i++)observer.parseFrame(capped,'SIP/2.0 '+(180+i)+' Fine\r\ncseq: 2 register\r\n\r\n'+PRIVATE,false);
 if(capped.sent_register!==512||!capped.counts_capped||capped.register_codes.length!==16||capped.register_codes[15]!==199)throw Error('bounded counters');
 if(observer.validate({...good,uri:PRIVATE})!==null||observer.validate({...good,invite_codes:[PRIVATE]})!==null)throw Error('unsafe projection');
 const bad=request('status');page.emit('request',bad);page.emit('response',{request:()=>bad,status:()=>500,json:async()=>{throw Error(PRIVATE)}});page.emit('requestfailed',bad);
 page.emit('request',request('admit','https://'+PRIVATE+'.invalid/app/pbx_meet/api.php'));
 socket.emit('socketerror',PRIVATE);socket.emit('close');await new Promise(resolve=>setImmediate(resolve));
 const failed=await observer.collect(page,row);
 const started=Date.now();const stalled=await observer.collect({evaluate:()=>new Promise(()=>{})},row);
 if(Date.now()-started<2800||Date.now()-started>6000)throw Error('bounded PC observation');
 for(const item of [good,capped,failed,stalled]){if(!observer.validate(item)||Object.keys(item).length!==24)throw Error('closed shape');}
 console.log(JSON.stringify({good,capped,failed,stalled}));
})().catch(()=>process.exit(1));
'''
        child = subprocess.run([shutil.which('node'), '-e', script, str(ROOT/'tests/windows-meet-signaling.cjs')], capture_output=True, text=True, timeout=12)
        self.assertEqual(child.returncode, 0, child.stderr)
        self.assertNotIn(PRIVATE, child.stdout)
        data = json.loads(child.stdout)
        self.assertEqual(data['good'], peer())
        self.assertFalse(data['failed']['endpoint_match'])
        self.assertEqual(data['failed']['status_http_status'], 500)
        self.assertEqual(data['failed']['api_json_failures'], 1)
        self.assertEqual(data['failed']['http_failures'], 1)
        self.assertEqual(data['failed']['ws_errors'], 1)
        self.assertEqual(data['failed']['ws_closed'], 1)
        self.assertEqual(data['stalled']['signaling_state'], 'unavailable')
        self.assertEqual(data['stalled']['invite_codes'], [401, 200])
        self.assertEqual(data['capped']['register_codes'], list(range(184, 200)))
        for row in data.values():
            self.assertEqual(module.signaling_fields({'host': row, 'guest': row}), {'meeting_signaling': {'host': row, 'guest': row}})


if __name__ == '__main__':
    unittest.main()
