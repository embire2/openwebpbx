"""Exercise actual closed browser/Python media diagnostic producers."""
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
spec = importlib.util.spec_from_file_location('windows_meeting_media', ROOT/'tests/windows-meet-browser.py')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
PRIVATE = 'PRIVATE_SDP_candidate_password'


def peer():
    return dict(observed=True, connected=True, connection_state='connected', ice_state='completed',
                visibility='visible', audio_context='running', decoded_frames=11, encoded_frames=12,
                inbound_audio_packets=13, outbound_audio_packets=14, inbound_video_packets=15,
                outbound_video_packets=16, video_colors=30, tone_ratio=.9, power=.02,
                remote_audio_live=True, remote_video_live=True, local_audio_live=True,
                local_video_live=True, vp8_decoding=True, probe_error=False, ui_state='connected')


class MediaDiagnosticsControls(unittest.TestCase):
    def test_python_exact_peer_shape_types_bounds_and_privacy(self):
        row = {'host': peer(), 'guest': peer() | {'decoded_frames': 20}}
        self.assertEqual(module.media_fields(row), {'meeting_media': row})
        self.assertEqual(len(peer()), 22)
        for side in ('host', 'guest'):
            for name, value in row[side].items():
                missing = copy.deepcopy(row); del missing[side][name]
                self.assertEqual(module.media_fields(missing), {})
                if type(value) is bool:
                    bad = [None, 1, 'true', PRIVATE]
                elif type(value) is int:
                    bad = [-1, 14401 if name == 'video_colors' else 2147483648, True, 1.5, '1']
                elif type(value) is float:
                    bad = [-.01, 1.01, float('nan'), float('inf'), -float('inf'), True, PRIVATE, 10**1000]
                else:
                    bad = [PRIVATE, value.upper(), None, [], {}]
                for invalid in bad:
                    changed = copy.deepcopy(row); changed[side][name] = invalid
                    self.assertEqual(module.media_fields(changed), {}, (side, name, type(invalid).__name__))
            extra = copy.deepcopy(row); extra[side]['sdp'] = PRIVATE
            self.assertEqual(module.media_fields(extra), {})
        for bad in [None, {}, [], row | {'private': PRIVATE}, {'host': peer(), 'guest': None}]:
            self.assertEqual(module.media_fields(bad), {})
        self.assertNotIn(PRIVATE, json.dumps(module.media_fields(row)))

    @unittest.skipUnless(shutil.which('node'), 'Node required for actual browser producers')
    def test_actual_stats_probe_preserves_metrics_without_private_data(self):
        source = (ROOT/'tests/windows-meet-browser.cjs').read_text()
        closed = source.split('const mediaBooleans=', 1)[1].split('function requireFact(', 1)[0]
        diagnostic = source.split('  qa.diagnostic = async () => {', 1)[1].split('\n  };\n}', 1)[0]
        code = 'const mediaBooleans='+closed+'''
const live={readyState:'live',enabled:true,muted:false};
const remote={srcObject:{getAudioTracks:()=>[live],getVideoTracks:()=>[live]}};
const status={textContent:'Connected. Your microphone and camera are controlled by the buttons below.'};
const document={visibilityState:'visible',getElementById:id=>id==='status'?status:remote};
const stats=new Map([
 ['v',{type:'inbound-rtp',kind:'video',framesDecoded:11,packetsReceived:15,codecId:'vp8',private:'PRIVATE_SDP_candidate_password'}],
 ['vo',{type:'outbound-rtp',kind:'video',framesEncoded:12,packetsSent:16}],
 ['a',{type:'inbound-rtp',kind:'audio',packetsReceived:13}],
 ['ao',{type:'outbound-rtp',kind:'audio',packetsSent:14}],
 ['vp8',{mimeType:'video/VP8'}]
]);
const pc={connectionState:'connected',iceConnectionState:'completed',getStats:async()=>stats,getSenders:()=>[{track:{...live,kind:'audio'}},{track:{...live,kind:'video'}}]};
const qa={pcs:[pc],audio:{state:'running'},proof:async()=>({connected:true,video_colors:30,tone_ratio:.9,power:.02})};
qa.diagnostic=async()=>{'''+diagnostic+'''
};
(async()=>{
 const rows=[];
 rows.push(closedMediaFields(await qa.diagnostic()));
 qa.proof=async()=>{throw Error('PRIVATE_SDP_candidate_password')};
 rows.push(closedMediaFields(await qa.diagnostic()));
 pc.connectionState='failed';pc.iceConnectionState='failed';document.visibilityState='hidden';qa.audio.state='suspended';
 rows.push(closedMediaFields(await qa.diagnostic()));
 qa.pcs=[];qa.audio=null;qa.proof=async()=>({connected:false});status.textContent='Could not join the meeting. Ask the host to check that it is open.';
 rows.push(closedMediaFields(await qa.diagnostic()));
 rows.push(await mediaFields({evaluate:async()=>{throw Error('PRIVATE_SDP_candidate_password')}}));
 const started=Date.now();rows.push(await mediaFields({evaluate:()=>new Promise(()=>{})}));
 if(Date.now()-started<2800||Date.now()-started>6000)throw Error('diagnostic deadline');
 for(const row of rows){if(!row||Object.keys(row).length!==22)throw Error('closed shape');}
 const unsafe={...rows[0],sdp:'PRIVATE_SDP_candidate_password'};
 if(closedMediaFields(unsafe)!==null)throw Error('private input accepted');
 for(const value of [NaN,Infinity,-Infinity,-1,1.1,true,'PRIVATE_SDP_candidate_password']){if(closedMediaFields({...rows[0],power:value})!==null)throw Error('invalid power');}
 console.log(JSON.stringify(rows));
})().catch(()=>process.exit(1));
'''
        result = subprocess.run([shutil.which('node'), '-e', code], capture_output=True, text=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn(PRIVATE, result.stdout)
        rows = json.loads(result.stdout)
        self.assertEqual(rows[0], peer())
        self.assertTrue(rows[1]['probe_error'])
        self.assertEqual(rows[1]['inbound_video_packets'], 15)
        self.assertEqual(rows[2]['connection_state'], 'failed')
        self.assertEqual(rows[2]['visibility'], 'hidden')
        self.assertEqual(rows[2]['audio_context'], 'suspended')
        self.assertTrue(rows[3]['observed'])
        self.assertFalse(rows[3]['connected'])
        self.assertEqual(rows[3]['connection_state'], 'unavailable')
        self.assertEqual(rows[3]['ui_state'], 'rejected')
        self.assertFalse(rows[4]['observed'])
        self.assertEqual(rows[4]['connection_state'], 'unavailable')
        self.assertFalse(rows[5]['observed'])
        for row in rows:
            self.assertEqual(module.media_fields({'host': row, 'guest': row}), {'meeting_media': {'host': row, 'guest': row}})
        self.assertIn('p.decoded_frames>=10&&p.video_colors>8&&p.tone_ratio>.65&&p.power>0.00001', source)


if __name__ == '__main__':
    unittest.main()
