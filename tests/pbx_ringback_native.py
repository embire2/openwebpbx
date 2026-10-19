#!/usr/bin/env python3
"""Opt-in owned two-phone fixture: decoded pre-answer ringback and answered audio.

The state must describe a separately created disposable PBX, never real users.
No provider, outside call, existing phone or global engine setting is changed.
"""
import argparse
import json
import math
import os
from pathlib import Path
import re
import struct
import subprocess
import time

from pbx_v20_restore_native import SourcePhone, decoded_tone_check, encode_ulaw
from sip_trunk_live import headers


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--state', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--server', required=True)
    parser.add_argument('--bind', default='127.0.0.2')
    args = parser.parse_args()
    if os.environ.get('OPENWEB_RINGBACK_NATIVE_TEST') != '1':
        raise RuntimeError('Explicit owned-fixture test opt-in is required.')
    os.umask(0o077)
    state = json.loads(args.state.read_text())
    assert re.fullmatch(r'recording-check-[a-f0-9]{12}\.invalid', state['realm'])
    assert [u['number'] for u in state['users']] == ['8100', '8101']
    assert not args.output.exists()
    destination = (args.server, 5060)

    class EarlyPhone(SourcePhone):
        def __init__(self, *a):
            self.pending = None; self.responses = []; self.early = {}; self.early_snapshot = {}
            super().__init__(*a)

        def receive_response(self, text, peer):
            h = headers(text)
            if text.startswith('SIP/2.0 ') and h.get('cseq', '').endswith(' INVITE'):
                code = int(text.split()[1]); cid = h.get('call-id')
                self.responses.append((cid, code))
                if code == 183 and '\r\nm=audio ' in text and self.pending is not None:
                    self.pending['target'] = self.target(text)
                    self.pending['pt'] = int(re.search(r'm=audio \d+ RTP/AVP (\d+)', text).group(1))
                    self.dialogs[cid] = self.pending
                    self.early[cid] = self.pending
                if code >= 200 and code not in (401, 407) and cid in self.early:
                    self.early_snapshot[cid] = bytes(self.early[cid]['decoded_pcm'])
            return super().receive_response(text, peer)

        def call(self, uri, dest, user='fixture', realm='fixture.invalid', password='', to_uri=None):
            media = self.media(); self.pending = media
            result = self.exchange('INVITE', uri, dest, user, realm, password, self.sdp(media, True), to_uri)
            self.pending = None
            if result['code'] == 200:
                media['target'] = self.target(result['text'])
                media['pt'] = int(re.search(r'm=audio \d+ RTP/AVP (\d+)', result['text']).group(1))
                self.dialogs[result['callid']] = media; result['media'] = media; self.outgoing.append(result)
            else:
                media['ended'] = True
                # The background receiver can still be finishing an RTP poll.
                # Peer.close owns the eventual socket close for early dialogs.
                if result['callid'] not in self.dialogs: media['socket'].close()
            return result

    class DelayedPhone(SourcePhone):
        mode = 'busy'
        def response(self, code, h, body=''):
            if code == 200 and h.get('cseq', '').endswith(' INVITE'):
                self.socket.sendto(super().response(183 if self.mode == 'early_media' else 180, h,
                                                   body if self.mode == 'early_media' else ''), destination)
                if self.mode == 'early_media':
                    # Act like a carrier playing a real progress announcement.
                    # The receiver loop is inside this response, so transmit a
                    # bounded tone here before handing media back to its loop.
                    media = self.dialogs[h['call-id']]
                    for sequence in range(160):
                        clock = sequence * 160
                        pcm = [int(6500*math.sin(2*math.pi*660*(clock+i)/8000)) for i in range(160)]
                        packet = struct.pack('!BBHII', 0x80, 0, sequence, clock, 73) + bytes(encode_ulaw(x) for x in pcm)
                        media['socket'].sendto(packet, media['target']); time.sleep(.02)
                    media['rtp_sequence'] = 160; media['rtp_clock'] = 25600
                else:
                    time.sleep(3.2)
                if self.mode == 'busy': return super().response(486, h)
            return super().response(code, h, body)

    caller = EarlyPhone(state['users'][0], state['realm'], args.bind)
    callee = DelayedPhone(state['users'][1], state['realm'], args.bind)
    calls = []; facts = {'owned_fixture_only': True, 'carrier_or_customer_phone_called': False}
    initial_media = json.loads(subprocess.check_output(['php', str(args.state.parent/'recording-native-fixture.php'), 'media']))
    try:
        for phone in (caller, callee): assert phone.register(destination)['code'] == 200
        for mode in ('busy', 'answer', 'early_media'):
            callee.mode = mode
            call = caller.dial('8101', destination); calls.append(call)
            codes = [code for cid, code in caller.responses if cid == call['callid']]
            raw = caller.early_snapshot[call['callid']]
            pcm = struct.unpack('<' + 'h' * (len(raw) // 2), raw)
            assert 183 in codes and len(pcm) > 12000, 'No decoded pre-answer ringback'
            # A dual 400/450 Hz tone is the server's ringback, not the remote
            # phone's 660 Hz test audio. Silence intervals must also be present.
            blocks = []; projected = total = 0
            for i in range(0, len(pcm)-800, 800):
                block = pcm[i:i+800]; energy = sum(x*x for x in block)
                total += energy; blocks.append(energy/800)
                for frequency in ((660,) if mode == 'early_media' else (400, 450)):
                    real = sum(x*math.cos(2*math.pi*frequency*k/8000) for k,x in enumerate(block))
                    imag = sum(x*math.sin(2*math.pi*frequency*k/8000) for k,x in enumerate(block))
                    projected += 2*(real*real+imag*imag)/800
            fraction = projected/total
            assert fraction > .85
            if mode != 'early_media': assert min(blocks) < max(blocks) * .01
            case = {'sip_responses': codes, 'preanswer_decoded_seconds': len(pcm)/8000,
                    'provider_660_energy' if mode == 'early_media' else 'ringback_400_450_energy': fraction,
                    'provider_early_media_preserved': mode == 'early_media'}
            if mode == 'busy':
                assert call['code'] >= 300
                rows = json.loads(subprocess.check_output(['php', str(args.state.parent/'recording-native-fixture.php'), 'media']))
                assert rows == initial_media, 'Unanswered ringing created or changed a recording'
                case['no_unanswered_recording'] = True
            else:
                assert call['code'] == 200
                # Remove early PCM before measuring the actual answered call.
                call['media']['decoded_pcm'].clear(); time.sleep(2.5)
                incoming = next(v for v in callee.dialogs.values() if not v.get('ended') and v.get('acked'))
                ratios = [decoded_tone_check(call['media'], 660), decoded_tone_check(incoming, 440)]
                assert min(ratios) > .9
                caller.hangup(call)
                case['answered_two_way_tone_ratios'] = ratios
            facts[mode] = case
    finally:
        # SourcePhone's own register implementation tracks its current digest
        # transaction here, not in the base Peer registration_call_ids array.
        state['registration_call_ids'] = [p.registration_transaction['cid'] for p in (caller, callee) if p.registration_transaction]
        state['call_ids'] = [c['callid'] for c in calls]
        args.state.write_text(json.dumps(state))
        caller.close(); callee.close()
        for cid in state['registration_call_ids']:
            subprocess.run(['fs_cli', '-x', 'sofia profile internal flush_inbound_reg ' + cid], check=True, stdout=subprocess.DEVNULL)
    facts['passed'] = True
    args.output.write_text(json.dumps(facts, indent=2))
    print(json.dumps(facts))


if __name__ == '__main__':
    main()
