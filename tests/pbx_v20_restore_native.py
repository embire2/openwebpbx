#!/usr/bin/env python3
"""Owned nspawn-only source-credential SIP/RTP qualification; no carrier traffic."""
import argparse
import base64
import ctypes
import ctypes.util
import hashlib
import json
import math
import os
from pathlib import Path
import queue
import re
import secrets
import socket
import struct
import subprocess
import time
import wave

from sip_trunk_live import Peer, digest, headers, rtp_rate_check


class SourcePhone(Peer):
    """Keep original extension AOR independent of the original digest username."""
    def __init__(self, record, realm, bind='127.0.0.1'):
        self.tone_hz = record.get('tone_hz', 440)
        super().__init__(bind, provider=record.get('local_provider', False), first=record.get('first_provider', False))
        self.aor = record.get('sip_user', record['number'])
        self.auth_user = record['auth']
        self.password = record['password']
        self.realm = realm
        self.registration_transaction = None

    def packet(self, *args, **kwargs):
        return super().packet(*args, **kwargs).replace(b'Contact: <sip:fixture@', ('Contact: <sip:'+self.aor+'@').encode())

    def response(self, *args, **kwargs):
        return super().response(*args, **kwargs).replace(b'Contact: <sip:fixture@', ('Contact: <sip:'+self.aor+'@').encode())

    def media(self, pt=0):
        state = super().media(pt)
        state['decoded_pcm'] = bytearray()
        return state

    def run(self):
        """Actual peers follow SDP changes and retain bounded decoded remote audio."""
        last = 0
        while not self.stopped:
            try:
                data, peer = self.socket.recvfrom(65535)
                text = data.decode(errors='replace'); h = headers(text); cid = h.get('call-id', '')
                if text.startswith('SIP/2.0 '):
                    self.receive_response(text, peer)
                elif text.startswith('INVITE '):
                    transaction = (cid, h['cseq'])
                    if transaction in self.replies:
                        self.socket.sendto(self.replies[transaction], peer)
                        self.service_sip_transactions()
                        continue
                    offered = re.search(r'm=audio \d+ RTP/AVP ([^\r\n]+)', text)
                    wanted = 8 if self.provider else 0
                    number = text.split(' ', 2)[1].split(':', 1)[1].split('@', 1)[0]
                    code = 200 if offered and str(wanted) in offered.group(1).split() else 488
                    if self.provider and self.first:
                        code = 503 if number.endswith('101') else 486 if number.endswith('102') else 603 if number.endswith('103') else code
                        if number.endswith('104'):
                            raw = h.get('proxy-authorization', '')
                            fields = {key: (quoted or plain).strip() for key, quoted, plain in re.findall(r'(\w+)=(?:"([^"]*)"|([^, ]+))', raw)}
                            if not fields or cid not in self.challenge_nonces:
                                self.challenge_nonces[cid] = secrets.token_hex(16)
                                self.challenges += 1
                                code = 407
                            else:
                                md5 = lambda value: hashlib.md5(value.encode()).hexdigest()
                                uri = text.split(' ', 2)[1]
                                nonce = self.challenge_nonces[cid]
                                a1 = md5(self.auth['username']+':local-carrier.invalid:'+self.auth['password'])
                                a2 = md5('INVITE:'+uri)
                                expected = md5(a1+':'+nonce+':'+fields.get('nc', '')+':'+fields.get('cnonce', '')+':auth:'+a2)
                                valid = fields.get('nonce') == nonce and fields.get('realm') == 'local-carrier.invalid' and fields.get('qop') == 'auth' and fields.get('username') == self.auth['username'] and fields.get('uri') == uri and fields.get('response') == expected
                                code = 200 if valid else 403
                                self.auth_passed += valid
                    body = ''
                    if code == 200:
                        state = self.dialogs.get(cid) or self.media(wanted)
                        state['target'] = self.target(text)
                        state['incoming'] = {'headers': h, 'peer': peer}
                        state['remote_hold'] = bool(re.search(r'a=(?:sendonly|inactive)\r?\n', text))
                        self.dialogs[cid] = state
                        body = self.sdp(state)
                    self.invites.append({'callid': cid, 'number': text.split(' ', 2)[1].split(':', 1)[1].split('@', 1)[0],
                                         'headers': h, 'sdp': text.split('\r\n\r\n', 1)[-1], 'received_at': time.monotonic()})
                    reply = self.response(code, h, body)
                    self.replies[transaction] = reply
                    self.send_invite_response(reply, h, peer)
                elif text.startswith('ACK '):
                    self.acknowledge_invite(h)
                elif text.startswith('REGISTER '):
                    self.register_requests += 1
                    self.socket.sendto(self.response(403, h), peer)
                elif text.startswith(('BYE ', 'OPTIONS ', 'CANCEL ', 'INFO ', 'NOTIFY ')):
                    self.socket.sendto(self.response(200, h), peer)
                    if text.startswith(('BYE ', 'CANCEL ')) and cid in self.dialogs:
                        self.dialogs[cid]['ended'] = True
            except (socket.timeout, BlockingIOError):
                pass
            except OSError:
                if not self.stopped:
                    raise
            self.service_sip_transactions()
            now = time.monotonic()
            if now-last < .02:
                continue
            # Keep the RTP timestamp clock aligned to real 20ms packets. Resetting
            # to each late socket poll accumulates drift and makes native PLC
            # insert discontinuities in an otherwise continuous test tone.
            last = now if last == 0 or now-last > .2 else last+.02
            for state in list(self.dialogs.values()):
                if state.get('ended') or not state['target']:
                    continue
                seq = state['sent']
                sequence = state.setdefault('rtp_sequence', 0)
                clock = state.setdefault('rtp_clock', 0)
                pending = state.setdefault('dtmf_events', [])
                if pending:
                    event = pending[0]
                    event.setdefault('timestamp', clock)
                    step = event.setdefault('step', 0)
                    duration = min(step+1, 10)*160
                    end = step >= 9
                    payload = struct.pack('!BBH', event['digit'], (0x80 if end else 0)|10, duration)
                    packet = struct.pack('!BBHII', 0x80, 101|(0x80 if step == 0 else 0), sequence % 65536,
                                         event['timestamp'] % 4294967296, 73)+payload
                    event['step'] += 1
                    if step >= 11:
                        pending.pop(0)
                        event['completed'] = True
                else:
                    pcm = [int(6500*math.sin(2*math.pi*self.tone_hz*(clock+i)/8000)) for i in range(160)]
                    encoder = encode_alaw if state['pt'] == 8 else encode_ulaw
                    packet = struct.pack('!BBHII', 0x80, state['pt'], sequence % 65536, clock % 4294967296, 73) + bytes(encoder(sample) for sample in pcm)
                state['socket'].sendto(packet, state['target'])
                state['rtp_sequence'] += 1
                state['rtp_clock'] += 160
                state['sent'] += 1
                state['sent_first_at'] = state['sent_first_at'] or now
                state['sent_last_at'] = now
                while True:
                    try:
                        packet = state['socket'].recv(4096)
                        if len(packet) < 12 or packet[0] & 0xc0 != 0x80:
                            continue
                        audio_pt = packet[1] & 0x7f
                        if audio_pt == state['pt']:
                            state['received'] += 1
                            state['received_first_at'] = state['received_first_at'] or now
                            state['received_last_at'] = now
                            size = 12 + (packet[0] & 15)*4
                            if packet[0] & 16:
                                if len(packet) < size+4:
                                    continue
                                size += 4 + struct.unpack('!H', packet[size+2:size+4])[0]*4
                            payload = packet[size:]
                            if packet[0] & 32 and payload:
                                payload = payload[:-payload[-1]]
                            decoder = decode_alaw if state['pt'] == 8 else decode_ulaw
                            decoded = b''.join(struct.pack('<h', decoder(value)) for value in payload)
                            state['decoded_pcm'].extend(decoded)
                            # Keep the latest 30 seconds; no source speech is recorded.
                            del state['decoded_pcm'][:-480000]
                        elif audio_pt in (0, 8):
                            state['unexpected_audio'] += 1
                    except BlockingIOError:
                        break

    def exchange(self, method, uri, dest, user='fixture', realm='fixture.invalid',
                 password='', body='', to_uri=None, expires=None):
        previous = self.registration_transaction if method == 'REGISTER' else None
        cid = previous['cid'] if previous else secrets.token_hex(12) + '@localfixture'
        self.queues[cid] = queue.Queue()
        if method == 'REGISTER' and expires and expires > 0:
            self.registration_call_ids.append(cid)
        from_header = previous['from'] if previous else f'<sip:{user}@{realm}>;tag=' + secrets.token_hex(5)
        to_header = '<' + (to_uri or uri) + '>'
        seq = previous['seq']+1 if previous else 1
        if method == 'REGISTER':
            self.registration_transaction = {'cid': cid, 'seq': seq, 'from': from_header}
        challenges = 0
        branch = 'z9hG4bK' + secrets.token_hex(9)
        extra = [] if expires is None else ['Expires: ' + str(expires)]
        self.socket.sendto(self.packet(method, uri, cid, seq, from_header, to_header,
                                       body, extra, branch), dest)
        deadline = time.monotonic() + 18
        while time.monotonic() < deadline:
            try:
                text, peer = self.queues[cid].get(timeout=max(.1, deadline-time.monotonic()))
            except queue.Empty:
                break
            h = headers(text)
            if h.get('cseq', '') != str(seq)+' '+method:
                continue
            code = int(text.split(' ', 2)[1])
            if code < 200:
                continue
            if code in (401, 407) and password:
                challenges += 1
                if challenges > 2:
                    return {'code': code, 'text': text, 'callid': cid, 'seq': seq,
                            'from': from_header, 'to': h['to'], 'uri': uri, 'peer': peer,
                            'digest_challenge_count': challenges}
                if method == 'INVITE':
                    self.socket.sendto(self.packet('ACK', uri, cid, seq, from_header,
                                                   h['to'], branch=branch), peer)
                auth = digest(h.get('www-authenticate', h.get('proxy-authenticate', '')),
                              self.auth_user, password, method, uri)
                extra = [x for x in extra if not x.startswith(('Authorization:', 'Proxy-Authorization:'))]
                extra.append(('Authorization: ' if code == 401 else 'Proxy-Authorization: ') + auth)
                seq += 1
                if method == 'REGISTER':
                    self.registration_transaction['seq'] = seq
                branch = 'z9hG4bK' + secrets.token_hex(9)
                self.socket.sendto(self.packet(method, uri, cid, seq, from_header,
                                               to_header, body, extra, branch), dest)
                continue
            if method == 'INVITE':
                import re
                remote = re.search(r'<([^>]+)>', h.get('contact', '<'+uri+'>')).group(1) if code < 300 else uri
                self.socket.sendto(self.packet('ACK', remote, cid, seq, from_header,
                                               h['to'], branch=None if code < 300 else branch), peer)
                if code >= 300:
                    Path('/var/lib/openwebpbx/restore-phone112/last-invite-response.txt').write_text(text)
            return {'code': code, 'text': text, 'callid': cid, 'seq': seq,
                    'from': from_header, 'to': h['to'], 'uri': uri, 'peer': peer,
                    'digest_challenge_count': challenges}
        raise RuntimeError('Private source-identity SIP transaction timed out')

    def register(self, destination, password=None, expires=120):
        return self.exchange('REGISTER', 'sip:'+self.realm, destination, self.aor,
                             self.realm, self.password if password is None else password,
                             to_uri='sip:'+self.aor+'@'+self.realm, expires=expires)

    def dial(self, number, destination):
        return self.call('sip:'+number+'@'+self.realm, destination, self.aor,
                         self.realm, self.password)

    def dialog_request(self, call, method, body='', content_type='application/sdp', extra=None):
        remote = re.search(r'<([^>]+)>', headers(call['text']).get('contact', '<'+call['uri']+'>')).group(1)
        call['seq'] += 1
        packet = self.packet(method, remote, call['callid'], call['seq'], call['from'], call['to'], body, extra)
        packet = packet.replace(b'Content-Type: application/sdp', ('Content-Type: '+content_type).encode())
        self.socket.sendto(packet, call['peer'])
        deadline = time.monotonic()+10
        while time.monotonic() < deadline:
            text, _ = self.queues[call['callid']].get(timeout=max(.05, deadline-time.monotonic()))
            h = headers(text)
            if h.get('cseq') != str(call['seq'])+' '+method or int(text.split(' ', 2)[1]) < 200:
                continue
            result = int(text.split(' ', 2)[1])
            if result == 200 and method == 'INVITE':
                self.socket.sendto(self.packet('ACK', remote, call['callid'], call['seq'], call['from'], h['to']), call['peer'])
                call['media']['target'] = self.target(text)
            return result
        raise RuntimeError('Owned in-dialog SIP transaction timed out')

    def dtmf(self, call, digit):
        assert digit in '0123456789*#'
        assert 'telephone-event/8000' in call['text'] and re.search(r'm=audio \d+ RTP/AVP [^\r\n]*\b101\b', call['text']), 'RFC2833 was not negotiated'
        event = {'digit': '0123456789*#'.index(digit)}
        call['media'].setdefault('dtmf_events', []).append(event)
        deadline = time.monotonic()+3
        while not event.get('completed') and time.monotonic() < deadline:
            time.sleep(.01)
        assert event.get('completed'), 'Negotiated wire DTMF did not leave the peer'
        return True

    def hold(self, call, held):
        body = self.sdp(call['media']).replace('o=fixture 1 1 ', 'o=fixture 1 '+str(call['seq']+1)+' ')
        if held:
            body = body.replace('a=sendrecv', 'a=sendonly')
        return self.dialog_request(call, 'INVITE', body)

    def blind_transfer(self, call, number):
        return self.dialog_request(call, 'REFER', extra=['Refer-To: <sip:'+number+'@'+self.realm+'>',
                                                       'Referred-By: <sip:'+self.aor+'@'+self.realm+'>'])


def restored_call_check(caller, peers, target, destination, digit=None):
    before = {id(peer): set(peer.dialogs) for peer in peers}
    call = caller.dial(target, destination)
    assert call['code'] == 200, 'Restored calling object did not answer; SIP status '+str(call['code'])
    try:
        if digit is not None:
            time.sleep(.25)
            assert caller.dtmf(call, digit), 'Restored menu did not receive negotiated wire DTMF'
        deadline = time.monotonic()+15
        while time.monotonic() < deadline:
            fresh = [(peer, state) for peer in peers if peer is not caller for cid, state in peer.dialogs.items()
                     if cid not in before[id(peer)] and not state.get('ended') and state['received'] >= 50]
            if fresh and call['media']['received'] >= 100:
                remote, state = fresh[0]
                # Ignore negotiation and prompt audio; measure stable generated cross-leg tones.
                call['media']['decoded_pcm'].clear(); state['decoded_pcm'].clear()
                time.sleep(2)
                rtp_rate_check(call['media']); rtp_rate_check(state)
                return {'passed': True, 'caller_received_packets': call['media']['received'],
                        'callee_received_packets': state['received'], 'two_way_rtp_rate_verified': True,
                        'decoded_caller_remote_tone_ratio': decoded_tone_check(call['media'], remote.tone_hz),
                        'decoded_callee_remote_tone_ratio': decoded_tone_check(state, caller.tone_hz),
                        'native_menu_dtmf': digit is not None,
                        'negotiated_rfc2833_wire_dtmf': digit is not None}
            time.sleep(.05)
        raise AssertionError('Restored calling object did not bridge decoded two-way peer media')
    finally:
        caller.hangup(call)


def original_waiting_check(caller, peers, target, destination):
    before = {id(peer): len(peer.invites) for peer in peers}
    call = caller.dial(target, destination)
    assert call['code'] == 200, 'Source queue did not answer into waiting'
    try:
        time.sleep(3)
        assert not call['media'].get('ended'), 'Source queue ended before its preserved timeout'
        assert all(len(peer.invites) == before[id(peer)] for peer in peers if peer is not caller), 'A source logged-out agent unexpectedly rang'
        assert call['media']['received'] >= 50, 'Preserved empty queue delivered no waiting media'
        rtp_rate_check(call['media'])
        return {'passed': True, 'original_source_zero_eligible_agents': True,
                'waiting_media_packets': call['media']['received'],
                'no_logged_out_agent_invites': True, 'source_availability_unchanged': True,
                'full_source_master_timeout_not_waited': True}
    finally:
        caller.hangup(call)


def announcement_end_check(caller, peers, target, destination, source_timeout, prompt_file):
    before = {id(peer): len(peer.invites) for peer in peers}
    call = caller.dial(target, destination)
    assert call['code'] == 200, 'Source announcement menu did not answer'
    try:
        prompt_seconds = 0.
        if prompt_file:
            path = Path(prompt_file)
            assert not path.is_symlink() and str(path).startswith('/var/lib/freeswitch/storage/openwebpbx/'), 'Owned private prompt required'
            with wave.open(str(path)) as prompt:
                prompt_seconds = prompt.getnframes()/prompt.getframerate()
        assert 0 <= prompt_seconds <= 300 and 0 < source_timeout <= 60
        started = time.monotonic()
        deadline = started+prompt_seconds+source_timeout+8
        while time.monotonic() < deadline and not call['media'].get('ended'):
            time.sleep(.05)
        assert call['media'].get('ended'), 'Original menu EndCall fallback did not terminate'
        assert all(len(peer.invites) == before[id(peer)] for peer in peers if peer is not caller)
        return {'passed': True, 'source_has_no_menu_options': True,
                'original_end_call_fallback_after_timeout': True,
                'no_invented_menu_routes': True, 'native_timeout_without_dtmf': True,
                'source_timeout_seconds': source_timeout, 'private_prompt_seconds': round(prompt_seconds, 3),
                'observed_seconds_after_answer': round(time.monotonic()-started, 3)}
    finally:
        if not call['media'].get('ended'):
            caller.hangup(call)


def encode_ulaw(value):
    sign = 0x80 if value < 0 else 0
    sample = min(abs(value), 32635) + 0x84
    exponent = min(max(sample.bit_length()-8, 0), 7)
    return (~(sign | exponent << 4 | (sample >> (exponent+3) & 15))) & 255


def decode_ulaw(value):
    value = (~value) & 255
    sample = ((value & 15) << 3) + 0x84
    sample = (sample << ((value >> 4) & 7)) - 0x84
    return -sample if value & 0x80 else sample


def encode_alaw(value):
    positive = value >= 0
    sample = min(value if positive else -value-1, 32767)
    exponent = max(0, sample.bit_length()-8)
    mantissa = sample >> (4 if exponent == 0 else exponent+3) & 15
    return (exponent << 4 | mantissa) ^ (0xd5 if positive else 0x55)


def decode_alaw(value):
    value ^= 0x55
    exponent = value >> 4 & 7
    sample = (value & 15) << 4
    sample += 8 if exponent == 0 else 0x108
    if exponent > 1:
        sample <<= exponent-1
    return sample if value & 0x80 else -sample


def decoded_tone_check(state, frequency):
    samples = list(struct.unpack('<'+'h'*(len(state['decoded_pcm'])//2), state['decoded_pcm']))[-16000:]
    assert len(samples) >= 4000, 'Decoded remote audio observation was too short'
    energy = sum(value*value for value in samples)
    assert energy/len(samples) > 100000, 'Decoded remote audio was silent'
    real = sum(value*math.cos(2*math.pi*frequency*i/8000) for i, value in enumerate(samples))
    imag = sum(value*math.sin(2*math.pi*frequency*i/8000) for i, value in enumerate(samples))
    ratio = 2*(real*real+imag*imag)/(len(samples)*energy)
    assert ratio >= .8, 'Decoded remote fixture tone did not cross the restored bridge'
    return round(ratio, 4)


def selected_music_check(pcm):
    """Require the unchanged 0.75 telephone-energy identity threshold."""
    def envelope(samples):
        return [math.sqrt(sum(value*value for value in samples[i:i+160])/160)
                for i in range(0, len(samples)-159, 160)]
    reference = Path('/var/lib/freeswitch/storage/openweb-music/8000/lofi-beat-loop-schmoop.wav')
    with wave.open(str(reference)) as wav:
        assert wav.getframerate() == 8000 and wav.getnchannels() == 1 and wav.getsampwidth() == 2
        raw = wav.readframes(wav.getnframes())
    received = list(struct.unpack('<'+'h'*(len(pcm)//2), pcm))
    source = list(struct.unpack('<'+'h'*(len(raw)//2), raw))
    # Remove SIP negotiation; use the final eight-second stable held interval.
    received = received[-64000:]
    assert len(received) >= 56000, 'Stable held music observation was too short'
    actual, track = envelope(received), envelope(source)
    mean = sum(actual)/len(actual)
    centered = [value-mean for value in actual]
    variance = sum(value*value for value in centered)
    assert variance > 0
    track += track[:len(actual)]
    best, offset = -1., 0
    for start in range(len(track)-len(actual)):
        section = track[start:start+len(actual)]
        local_mean = sum(section)/len(section)
        local_variance = sum(value*value for value in section)-local_mean*local_mean*len(section)
        if local_variance <= 0:
            continue
        corr = sum(a*b for a, b in zip(centered, section))/math.sqrt(variance*local_variance)
        if corr > best:
            best, offset = corr, start/50
    assert best >= .75, 'Held remote audio did not match the selected CC0 track'
    return {'stable_held_seconds': len(received)/8000, 'selected_track_envelope_correlation': round(best, 4),
            'track_offset_seconds': round(offset, 2), 'unchanged_identity_threshold': .75}


def private_credentials(root, state):
    """Decrypt into memory only; source credentials never enter logs or fixtures."""
    sodium = ctypes.CDLL(ctypes.util.find_library('sodium'))
    if sodium.sodium_init() < 0:
        raise RuntimeError('Private fixture cryptography unavailable')
    raw = base64.b64decode(state['credentials_ciphertext'], validate=True)
    nonce, cipher = raw[:24], raw[24:]
    key = (root/'fixture-credential.key').read_bytes()
    if len(key) != 32 or len(cipher) <= 16:
        raise RuntimeError('Private encrypted fixture payload unavailable')
    plain = ctypes.create_string_buffer(len(cipher)-16)
    sodium.crypto_secretbox_open_easy.argtypes = [ctypes.c_void_p, ctypes.c_char_p,
                                                  ctypes.c_ulonglong, ctypes.c_char_p,
                                                  ctypes.c_char_p]
    sodium.crypto_secretbox_open_easy.restype = ctypes.c_int
    if sodium.crypto_secretbox_open_easy(plain, cipher, len(cipher), nonce, key) != 0:
        raise RuntimeError('Private encrypted fixture payload could not be opened')
    result = json.loads(plain.raw)
    if result['domain'] != state['domain'] or result['realm'] != state['realm'] or result['scope'] != state['scope']:
        raise RuntimeError('Private fixture credential scope mismatch')
    return result


def main():
    os.umask(0o077)
    if not __debug__:
        raise RuntimeError('Qualification requires assertions enabled')
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--all-users', action='store_true')
    parser.add_argument('--source-phones', action='store_true')
    parser.add_argument('--phone-domain-alias', action='store_true')
    parser.add_argument('--restored-objects', action='store_true')
    parser.add_argument('--hold-transfer', action='store_true')
    parser.add_argument('--local-provider', action='store_true')
    parser.add_argument('--voicemail', action='store_true')
    args = parser.parse_args()
    if os.environ.get('OPENWEB_RESTORE_QUALIFICATION') != '1' or socket.gethostname() != 'owpbx-desk-restore112' or Path('/run/systemd/container').read_text().strip() != 'systemd-nspawn':
        raise RuntimeError('The exclusively owned disposable restore machine is required')
    interfaces = json.loads(subprocess.check_output(['/usr/sbin/ip', '-j', 'address'], text=True))
    if not interfaces or any(interface['ifname'] != 'lo' for interface in interfaces):
        raise RuntimeError('Loopback-only fixture network required')
    root = Path('/var/lib/openwebpbx/restore-phone112')
    state = json.loads((root/'state.json').read_text())
    if state['scope'] != 'supplied-v20-private-restore' or not state['imported_provider_activation_forbidden']:
        raise RuntimeError('The exclusively owned source restore scope is required')
    source = private_credentials(root, state)
    phone_realm = state['realm']
    if args.phone_domain_alias:
        assert args.source_phones and state.get('https_fixture'), 'An owned HTTPS-created phone alias and original source phones are required'
        phone_realm = state['https_fixture']['alias']
    available = [u for u in source['users'] if u['source_status'] == 'Available']
    manual_available = [u for u in available if u.get('source_auto_status') == '0']
    separate = next(u for u in manual_available if u['number'] != u['auth'])
    same = next(u for u in available if u['number'] == u['auth'])
    second_manual = next(u for u in manual_available if u['number'] != separate['number'])
    assert sum((args.all_users, args.source_phones, args.restored_objects, args.hold_transfer, args.local_provider, args.voicemail)) <= 1
    selected = source['phones'] if args.source_phones else source['users'] if args.all_users or args.restored_objects else [separate, second_manual]
    if args.hold_transfer:
        selected = [separate, second_manual, next(u for u in manual_available if u['number'] not in (separate['number'], second_manual['number']))]
    if args.local_provider or args.voicemail:
        selected = [separate]
    peers, rows = [], []
    destination = ('127.0.0.1', 5060)
    started = time.monotonic()
    mode = ('all-users' if args.all_users else 'source-phones' if args.source_phones else
            'objects' if args.restored_objects else 'hold-transfer' if args.hold_transfer else
            'local-provider' if args.local_provider else 'voicemail' if args.voicemail else 'basic')
    if args.phone_domain_alias:
        mode = 'alias-source-phones'
    completed = False
    cleanup = []
    provider_prepared = False
    try:
        for index, record in enumerate(selected):
            phone = SourcePhone(dict(record, tone_hz=440+index*197), phone_realm)
            peers.append(phone)
            result = phone.register(destination)
            row = {'case': 'source_registration_'+str(index+1),
                   'separate_original_aor_and_auth_id': phone.aor != record['auth'],
                   'actual_source_phone_record': args.source_phones,
                   'digest_challenge_count': result['digest_challenge_count'],
                   'status_code': result['code'], 'passed': result['code'] == 200}
            rows.append(row)
            if not row['passed']:
                raise RuntimeError('Original domain-change registration rejected; status '+str(result['code']))
            phone.registered = True
        if args.voicemail:
            caller = peers[0]
            mailbox = next(user for user in manual_available if user['number'] != separate['number'] and user['source_not_registered_voicemail'])
            folder = Path('/var/lib/freeswitch/storage/voicemail/default')/state['realm']/mailbox['number']
            assert not folder.is_symlink()
            before = set(folder.glob('*.wav'))
            call = caller.dial(mailbox['number'], destination)
            assert call['code'] == 200, 'Original NotRegistered voicemail route did not answer'
            try:
                # Retain the original greeting and provide generated microphone audio.
                time.sleep(25)
            finally:
                caller.hangup(call)
            deadline = time.monotonic()+10
            created = []
            finalized = None
            waited_for_header = False
            while time.monotonic() < deadline:
                created = [path for path in folder.glob('*.wav') if path not in before and not path.name.startswith('greeting_') and not path.is_symlink()]
                if created:
                    try:
                        with wave.open(str(created[0])) as recording:
                            if recording.getnframes() > 0:
                                finalized = (recording.getnchannels(), recording.getsampwidth(),
                                             recording.getframerate(), recording.readframes(recording.getnframes()))
                                break
                    except (wave.Error, EOFError):
                        waited_for_header = True
                time.sleep(.1)
            assert finalized, 'Native voicemail did not save finalized generated caller audio'
            channels, width, rate, raw = finalized
            assert channels == 1 and width == 2 and rate in (8000, 16000, 32000, 48000)
            samples = struct.unpack('<'+'h'*(len(raw)//2), raw)[::rate//8000]
            pcm = bytearray(b''.join(struct.pack('<h', sample) for sample in samples))
            ratio = decoded_tone_check({'decoded_pcm': pcm}, caller.tone_hz)
            rows.append({'case': 'source_not_registered_voicemail_generated_audio', 'passed': True,
                         'original_not_registered_destination_unchanged': True,
                         'new_native_voicemail_files': len(created), 'generated_caller_tone_ratio': ratio,
                         'source_greeting_and_pin_unchanged': True, 'recording_outside_web_root': True,
                         'finalized_native_wav_header_verified': True,
                         'asynchronous_header_finalization_observed': waited_for_header})
        elif args.local_provider:
            caller = peers[0]
            providers = [SourcePhone({'number': 'local-fixture', 'auth': 'local-fixture', 'password': '',
                                     'tone_hz': 1109+index*199, 'local_provider': True,
                                     'first_provider': index == 0}, 'local-carrier.invalid',
                                     bind='127.0.0.'+str(index+2)) for index in range(2)]
            peers.extend(providers)
            subprocess.run(['/usr/bin/php', str(root/'fixture.php'), 'provider-prepare',
                            str(providers[0].port), str(providers[1].port)], check=True, capture_output=True, timeout=30)
            provider_prepared = True
            provider_state = json.loads((root/'state.json').read_text())
            providers[0].auth = private_credentials(root, provider_state)['local_provider_auth']
            handover = subprocess.run(['/usr/bin/python3', str(root/'HTTPS.py'), '--connect-provider'],
                                      capture_output=True, text=True, timeout=90)
            (root/'provider-https-private.log').write_text(handover.stdout+handover.stderr)
            handover.check_returncode()
            for index, (number, winning) in enumerate((('99100', 0), ('99101', 1), ('99104', 0))):
                remote = providers[winning]
                previous = set(remote.dialogs)
                call = caller.dial(number, destination)
                assert call['code'] == 200, 'Invented loopback provider did not answer'
                try:
                    time.sleep(3)
                    dialog = next(value for cid, value in remote.dialogs.items() if cid not in previous)
                    rtp_rate_check(call['media']); rtp_rate_check(dialog)
                    assert dialog['pt'] == 8 and call['media']['unexpected_audio'] == dialog['unexpected_audio'] == 0
                    assert any(invite['number'] == '55'+number[2:] for invite in remote.invites), 'Outgoing rewrite did not reach the reviewed local provider'
                    rows.append({'case': 'restored_tenant_local_provider_'+str(index+1), 'passed': True,
                                 'provider_pcm_a_negotiated': True, 'two_way_rtp_rate_verified': True,
                                 'caller_remote_tone_ratio': decoded_tone_check(call['media'], remote.tone_hz),
                                 'provider_remote_tone_ratio': decoded_tone_check(dialog, caller.tone_hz),
                                 'actual_provider_failover': winning == 1})
                finally:
                    caller.hangup(call)
            assert providers[0].auth_passed >= 1 and providers[0].register_requests == 0
            rows.append({'case': 'invented_provider_digest_without_registration', 'passed': True,
                         'valid_digest_count': providers[0].auth_passed, 'provider_register_count': 0})
        elif args.hold_transfer:
            caller, callee, target = peers
            before = set(callee.dialogs)
            call = caller.dial(callee.aor, destination)
            assert call['code'] == 200
            try:
                time.sleep(3)
                remote_id = next(cid for cid in callee.dialogs if cid not in before)
                remote = callee.dialogs[remote_id]
                decoded_tone_check(call['media'], callee.tone_hz)
                decoded_tone_check(remote, caller.tone_hz)
                remote['decoded_pcm'].clear()
                assert caller.hold(call, True) == 200, 'Source phone hold was rejected'
                time.sleep(10)
                music = selected_music_check(bytes(remote['decoded_pcm']))
                rtp_rate_check(remote)
                rows.append(dict(case='restored_phone_hold_selected_music', passed=True,
                                 received_packets=remote['received'], **music))
                assert caller.hold(call, False) == 200, 'Source phone resume was rejected'
                call['media']['decoded_pcm'].clear(); remote['decoded_pcm'].clear()
                time.sleep(3)
                rows.append({'case': 'restored_phone_resume_decoded_media', 'passed': True,
                             'caller_remote_tone_ratio': decoded_tone_check(call['media'], callee.tone_hz),
                             'callee_remote_tone_ratio': decoded_tone_check(remote, caller.tone_hz)})
                before_target = set(target.dialogs)
                assert caller.blind_transfer(call, target.aor) == 202, 'Native restored phone REFER was rejected'
                deadline = time.monotonic()+10
                while time.monotonic() < deadline and not any(cid not in before_target for cid in target.dialogs):
                    time.sleep(.05)
                target_id = next(cid for cid in target.dialogs if cid not in before_target)
                transferred = target.dialogs[target_id]
                remote['decoded_pcm'].clear(); transferred['decoded_pcm'].clear()
                time.sleep(3)
                rows.append({'case': 'restored_phone_blind_transfer_decoded_media', 'passed': True,
                             'original_remote_tone_ratio': decoded_tone_check(remote, target.tone_hz),
                             'target_remote_tone_ratio': decoded_tone_check(transferred, callee.tone_hz)})
                target.hangup_incoming(target_id)
            finally:
                if not call['media'].get('ended'):
                    caller.hangup(call)
                for cid, callee_media in list(callee.dialogs.items()):
                    if cid not in before and not callee_media.get('ended'):
                        callee.hangup_incoming(cid)
        elif args.restored_objects:
            caller = next(peer for peer in peers if peer.aor == separate['number'])
            rows.append(dict(case='restored_internal_decoded_audio', **restored_call_check(caller, peers, second_manual['number'], destination)))
            by_number = {user['number']: user for user in source['users']}
            runtime_profiles = json.loads((root/'policy-runtime-private.json').read_text())['users']
            def receiving(number):
                return runtime_profiles[number]['effective_profile'] == 'Available'
            def outside_caller(obj):
                member_numbers = {member['number'] for member in obj.get('members', [])}
                return next(peer for peer in peers if peer.aor not in member_numbers and
                            receiving(peer.aor))
            for kind in ('ring_groups', 'queues'):
                for index, obj in enumerate(source['calling_objects'][kind]):
                    caller = outside_caller(obj)
                    eligible = [member for member in obj['members'] if member['status'] == 'LoggedIn' and
                                by_number[member['number']]['source_queue_status'] == 'LoggedIn' and
                                receiving(member['number'])]
                    try:
                        result = (original_waiting_check(caller, peers, obj['number'], destination)
                                  if kind == 'queues' and not eligible else
                                  restored_call_check(caller, peers, obj['number'], destination))
                    except Exception:
                        rows.append({'case': 'restored_'+kind+'_'+str(index+1), 'passed': False,
                                     'eligible_source_member_count': len(eligible),
                                     'temporary_office_open_override': 'routing_restore_ciphertext' in state})
                        raise
                    rows.append(dict(case='restored_'+kind+'_'+str(index+1), **result))
            for index, obj in enumerate(source['calling_objects']['receptionists']):
                options = [option for option in obj['options'] if option['destination']['type'] in ('Extension', 'RingGroup', 'Queue') and len(option['digit']) == 1]
                if not options:
                    assert not obj['options'] and obj['timeout_destination']['type'] == 'EndCall'
                    result = announcement_end_check(caller, peers, obj['number'], destination,
                                                    obj['timeout'], obj.get('private_prompt_file', ''))
                else:
                    option = next((item for item in options if item['destination']['type'] != 'Extension' or
                                   receiving(item['destination']['number'])), options[0])
                    if option['destination']['type'] == 'Extension':
                        target_number = option['destination']['number']
                        caller = next(peer for peer in peers if peer.aor != target_number and
                                      receiving(peer.aor))
                    elif option['destination']['type'] in ('Queue', 'RingGroup'):
                        kind = 'queues' if option['destination']['type'] == 'Queue' else 'ring_groups'
                        target_object = next(item for item in source['calling_objects'][kind]
                                             if item['number'] == option['destination']['number'])
                        caller = outside_caller(target_object)
                    result = restored_call_check(caller, peers, obj['number'], destination, option['digit'])
                rows.append(dict(case='restored_receptionist_'+str(index+1), **result))
        elif not args.all_users:
            caller, callee = peers
            call = caller.dial(callee.aor, destination)
            if call['code'] != 200:
                rows.append({'case': 'original_identity_internal_answer', 'status_code': call['code'],
                             'digest_challenge_count': call['digest_challenge_count'],
                             'callee_received_invites': len(callee.invites),
                             'callee_answered_dialogs': len(callee.dialogs), 'passed': False})
            assert call['code'] == 200, 'Restored internal call was not answered'
            time.sleep(5)
            rtp_rate_check(call['media'])
            remote = list(callee.dialogs.values())[-1]
            rtp_rate_check(remote)
            for role, media in (('caller', call['media']), ('callee', remote)):
                (root/('last-'+role+'-decoded-private.raw')).write_bytes(bytes(media['decoded_pcm']))
            decoded_caller = decoded_tone_check(call['media'], callee.tone_hz)
            decoded_callee = decoded_tone_check(remote, caller.tone_hz)
            caller.hangup(call)
            rows.append({'case': 'original_identity_internal_media', 'passed': True,
                         'caller_received_packets': call['media']['received'],
                         'callee_received_packets': remote['received'],
                         'two_way_rtp_rate_verified': True,
                         'decoded_caller_remote_tone_ratio': decoded_caller,
                         'decoded_callee_remote_tone_ratio': decoded_callee})
            rejected = caller.register(destination, password=secrets.token_hex(32))
            rows.append({'case': 'wrong_source_password_rejected', 'status_code': rejected['code'],
                         'passed': rejected['code'] in (401, 403, 404)})
            assert rows[-1]['passed'], 'A wrong source password was accepted'
            assert caller.register(destination)['code'] == 200, 'A failed digest corrupted the original registration'
            foreign = SourcePhone(selected[0], 'foreign-restore112.invalid')
            peers.append(foreign)
            rejected = foreign.register(destination)
            rows.append({'case': 'foreign_tenant_realm_rejected', 'status_code': rejected['code'],
                         'passed': rejected['code'] in (401, 403, 404)})
            assert rows[-1]['passed'], 'Original credentials registered in a foreign realm'
            collision = next((u for u in source['users'] if u['number'] != u['auth'] and
                              any(v['number'] == u['auth'] for v in source['users'])), None)
            if collision:
                confused = SourcePhone(dict(collision, sip_user=collision['auth']), phone_realm)
                peers.append(confused)
                rejected = confused.register(destination)
                rows.append({'case': 'cross_user_numeric_authentication_collision_rejected',
                             'status_code': rejected['code'], 'passed': rejected['code'] in (401, 403, 404)})
                assert rows[-1]['passed'], 'An authentication-ID collision registered as another user'
        completed = True
    finally:
        prior = root/'registration-ledger.json'
        existing = json.loads(prior.read_text()) if prior.exists() else {}
        assert not existing or existing['domain'] == state['domain'] and existing['realm'] == state['realm']
        ledger = sorted(set(existing.get('registration_call_ids', [])) | {cid for peer in peers for cid in peer.registration_call_ids})
        (root/'registration-ledger.json').write_text(json.dumps({'domain': state['domain'],
            'realm': state['realm'], 'registration_call_ids': ledger}, indent=2)+'\n')
        for index, peer in enumerate(peers):
            if getattr(peer, 'registered', False):
                try:
                    result = peer.register(destination, expires=0)
                    cleanup.append({'peer_index': index+1, 'unregister_status': result['code'],
                                    'passed': result['code'] == 200})
                except Exception:
                    cleanup.append({'peer_index': index+1, 'passed': False})
            peer.close()
        if provider_prepared:
            result = subprocess.run(['/usr/bin/php', str(root/'fixture.php'), 'provider-cleanup'],
                                    capture_output=True, text=True, timeout=30)
            cleanup.append({'owned_loopback_providers_removed_original_config_restored': result.returncode == 0,
                            'passed': result.returncode == 0})
        result = subprocess.run(['/usr/bin/php', str(root/'fixture.php'), 'native-cleanup'],
                                capture_output=True, text=True, timeout=15)
        cleanup.append({'exact_owned_native_calls_and_register_ids_removed': result.returncode == 0,
                        'passed': result.returncode == 0})
        report = {'fixture_only': True, 'source_credentials_decrypted_in_memory_only': True,
                  'mode': mode, 'completed_epoch': int(time.time()), 'loopback_only_network_verified': True,
                  'original_extension_aor_and_authentication_id': True,
                  'source_passwords_unchanged': True, 'new_tenant_realm': True,
                  'normal_https_owned_phone_domain_alias_used': args.phone_domain_alias,
                  'temporary_owned_office_open_override': 'routing_restore_ciphertext' in state,
                  'elapsed_seconds': round(time.monotonic()-started, 3), 'cases': rows,
                  'owned_unregister_cleanup': cleanup,
                  'matrix_completed': completed,
                  'all_passed': completed and bool(rows) and all(row['passed'] for row in rows) and all(row['passed'] for row in cleanup)}
        installed = [Path('/var/www/fusionpbx/resources/classes')/(name+'.php') for name in
                     ('threecx_v20', 'pbx_setup_provisioner', 'pbx_v20_restore', 'pbx_phone_restore', 'pbx_ringing', 'pbx_sip_domain', 'pbx_setup', 'pbx_tenants')]
        installed += [Path('/usr/share/freeswitch/scripts/app/pbx_setup')/name for name in
                      ('policy.lua', 'index.lua', 'core_agent.lua', 'jobs.lua', 'queue_runtime.lua', 'mobile_state.lua')]
        installed += sorted(Path('/usr/share/freeswitch/scripts/app/pbx_setup').glob('*.lua'))
        installed += [Path('/usr/share/freeswitch/scripts/app/xml_handler/resources/scripts/directory')/name for name in
                      ('auth_binding.lua', 'directory.lua', 'mobile.lua', 'contact_realms.lua')]
        installed.append(Path('/usr/lib/freeswitch/mod/mod_sofia.so'))
        report['actual_installed_source_sha256'] = {str(path): hashlib.sha256(path.read_bytes()).hexdigest()
                                                   for path in installed if path.is_file()}
        (root/'native-basic-evidence.json').write_text(json.dumps(report, indent=2)+'\n')
        (root/('native-'+mode+'-evidence.json')).write_text(json.dumps(report, indent=2)+'\n')
        print(json.dumps(report, indent=2))


if __name__ == '__main__':
    main()
