#!/usr/bin/env python3
"""Opt-in 1026 qualification with one owned tenant and a registered software phone.

Execution requires OPENWEB_CLOCK_NATIVE_TEST=1 and --execute-owned-native-test.
No provider, existing route, global configuration or old evidence is changed.
Preflight uses private shadow scripts/sounds; installed uses the global 1026 route.
Audio and credentials stay in a new root-only evidence directory. Native calls
must be coordinated separately; --self-test runs no PBX/database/network code.
"""
import argparse
import array
import fcntl
import hashlib
import json
import math
import os
from pathlib import Path
import pwd
import random
import re
import secrets
import shutil
import socket
import stat
import struct
import subprocess
import sys
import tempfile
import threading
import time
import urllib.parse
import uuid
import wave
import xml.etree.ElementTree as ET

REPO = Path(__file__).resolve().parents[1]
RATE = 8000
VERSION = '1.0.2'
UUID = re.compile(r'^[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}$')
PRIVATE_ROOT = Path('/var/lib/openwebpbx/clock1026-repair-20261017')
ENGINE_SCRIPTS = Path('/usr/share/freeswitch/scripts')
ENGINE_SOUNDS = Path('/usr/share/freeswitch/sounds')


def check(value, message):
    if not value:
        raise AssertionError(message)


def sha(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def save(path, value):
    temporary = path.with_name(path.name + '.new')
    temporary.write_text(json.dumps(value, indent=2) + '\n')
    temporary.chmod(0o600)
    os.replace(temporary, path)


def quote(value):
    return "'" + str(value).replace("'", "''") + "'"


def sql(statement):
    result = subprocess.run(['runuser', '-u', 'postgres', '--', 'psql', '-XAt',
                             '-v', 'ON_ERROR_STOP=1', '-d', 'fusionpbx'],
                            input=statement, text=True, capture_output=True, timeout=30)
    check(result.returncode == 0, 'Owned clock fixture database operation failed')
    return result.stdout.strip()


def engine(command):
    result = subprocess.run(['fs_cli', '-x', command], text=True,
                            capture_output=True, timeout=15)
    check(result.returncode == 0, 'Owned clock fixture engine operation failed')
    return result.stdout.strip()


def load_phone(work):
    # The existing peer preserves distinct SIP user/auth identities and actual
    # digest/ACK/BYE/RTP behavior. Redirect its private failure capture locally.
    sys.path.insert(0, str(REPO / 'tests'))
    import pbx_v20_restore_native as source
    original_path = source.Path
    source.Path = lambda value: work / 'sip-response.private.txt' if str(value).endswith('last-invite-response.txt') else original_path(value)

    class Phone(source.SourcePhone):
        def media(self, pt=0):
            state = super().media(pt)
            state['clock_capture'] = Capture()
            state['socket'] = RecordingSocket(state['socket'], state, source)
            return state

    return Phone


class Capture:
    def __init__(self):
        self.packets = []
        self.lock = threading.Lock()
        self.foreign_packets = 0

    def append(self, sequence, timestamp, epoch_ms, pcm):
        with self.lock:
            check(len(self.packets) < 10000, 'Clock RTP capture exceeded its fixed bound')
            self.packets.append((sequence, timestamp, epoch_ms, pcm))

    def snapshot(self):
        with self.lock:
            return list(self.packets)


class RecordingSocket:
    def __init__(self, sock, state, source):
        self.socket, self.state, self.source = sock, state, source

    def __getattr__(self, name):
        return getattr(self.socket, name)

    def recv(self, size):
        packet, peer = self.socket.recvfrom(size)
        captured = time.time_ns() / 1000000
        capture = self.state['clock_capture']
        if peer != self.state.get('target'):
            capture.foreign_packets += 1
            return packet
        if len(packet) >= 12 and packet[0] & 0xc0 == 0x80 and packet[1] & 0x7f == self.state['pt']:
            offset = 12 + 4 * (packet[0] & 15)
            if packet[0] & 16:
                check(len(packet) >= offset + 4, 'Clock RTP extension is truncated')
                offset += 4 + struct.unpack('!H', packet[offset + 2:offset + 4])[0] * 4
            check(offset <= len(packet), 'Clock RTP payload is truncated')
            payload = packet[offset:]
            if packet[0] & 32 and payload:
                check(0 < payload[-1] <= len(payload), 'Clock RTP padding is invalid')
                payload = payload[:-payload[-1]]
            decoder = self.source.decode_alaw if self.state['pt'] == 8 else self.source.decode_ulaw
            pcm = b''.join(struct.pack('<h', decoder(value)) for value in payload)
            sequence, timestamp = struct.unpack('!HI', packet[2:8])
            capture.append(sequence, timestamp, captured, pcm)
        return packet


def event_settings():
    values = {}
    for name in ('/etc/fusionpbx/config.conf', '/usr/local/etc/fusionpbx/config.conf'):
        path = Path(name)
        if path.is_file():
            for line in path.read_text().splitlines():
                if '=' in line:
                    key, value = line.split('=', 1)
                    values[key.strip()] = value.strip()
            break
    password = values.get('switch.event_socket.password') or values.get('event_socket.password')
    port = values.get('switch.event_socket.port') or values.get('event_socket.port') or '8021'
    if not password:
        path = Path('/etc/freeswitch/autoload_configs/event_socket.conf.xml')
        params = {item.get('name'): item.get('value') for item in ET.parse(path).findall('.//param')}
        password, port = params.get('password'), params.get('listen-port', port)
    check(password and '\n' not in password and '\r' not in password, 'Local event credentials unavailable')
    return '127.0.0.1', int(port), password


class ClockEvents:
    def __init__(self, state):
        host, port, password = event_settings()
        self.realm, self.domain = state['realm'], state['domain']
        self.socket = socket.create_connection((host, port), timeout=5)
        self.socket.settimeout(.25)
        self.buffer, self.events = b'', []
        self.lock = threading.Lock()
        self.stopped, self.error = False, None
        check(self.frame(5)[0].get('Content-Type') == 'auth/request', 'Clock event challenge absent')
        for command in ('auth ' + password, 'filter variable_domain_name ' + self.realm,
                        'event plain PLAYBACK_START PLAYBACK_STOP CHANNEL_ANSWER CHANNEL_HANGUP_COMPLETE'):
            self.socket.sendall((command + '\n\n').encode())
            check(self.frame(5)[0].get('Reply-Text', '').startswith('+OK'), 'Clock event subscription refused')
        self.thread = threading.Thread(target=self.run, daemon=True)
        self.thread.start()

    def frame(self, seconds):
        deadline = time.monotonic() + seconds
        while not self.stopped and time.monotonic() < deadline:
            offset = self.buffer.find(b'\n\n')
            if offset >= 0:
                headers = dict(row.split(': ', 1) for row in self.buffer[:offset].decode().splitlines() if ': ' in row)
                size = int(headers.get('Content-Length', '0'))
                check(0 <= size <= 1048576, 'Clock event frame exceeded its bound')
                if len(self.buffer) >= offset + 2 + size:
                    body, self.buffer = self.buffer[offset + 2:offset + 2 + size], self.buffer[offset + 2 + size:]
                    return headers, body
            try:
                part = self.socket.recv(65536)
                check(part, 'Clock event connection closed')
                self.buffer += part
            except socket.timeout:
                pass
        raise TimeoutError('Clock event deadline expired')

    def run(self):
        try:
            while not self.stopped:
                try:
                    headers, body = self.frame(1)
                except TimeoutError:
                    continue
                if headers.get('Content-Type') != 'text/event-plain':
                    continue
                fields = {key: urllib.parse.unquote(value) for key, value in
                          (row.split(': ', 1) for row in body.decode().splitlines() if ': ' in row)}
                if fields.get('variable_domain_name') != self.realm or fields.get('variable_domain_uuid') != self.domain:
                    continue
                event = {'name': fields.get('Event-Name'), 'callid': fields.get('variable_sip_call_id'),
                         'uuid': fields.get('Unique-ID'), 'epoch_ms': int(fields['Event-Date-Timestamp']) / 1000,
                         'path': fields.get('Playback-File-Path', ''),
                         'authorized': fields.get('variable_sip_authorized') == 'true'}
                for key in ('version', 'announcement_target_ms', 'announcement_ms', 'hour', 'minute', 'second',
                            'welcome_completed_ms', 'target_ms', 'signal_ms'):
                    value = fields.get('variable_openweb_clock_' + key)
                    if value is not None:
                        event[key] = value if key == 'version' else int(value)
                with self.lock:
                    check(len(self.events) < 1000, 'Clock event inventory exceeded its bound')
                    self.events.append(event)
        except BaseException as error:
            if not self.stopped:
                self.error = error

    def snapshot(self, callid):
        if self.error:
            raise self.error
        with self.lock:
            return [dict(row) for row in self.events if row['callid'] == callid]

    def close(self):
        self.stopped = True
        self.thread.join(2)
        self.socket.close()
        check(not self.thread.is_alive(), 'Clock event observer did not stop')


def samples(pcm):
    result = array.array('h', pcm)
    if sys.byteorder != 'little':
        result.byteswap()
    return result


def timeline(packets):
    check(len(packets) >= 100, 'Clock produced insufficient RTP')
    first = packets[0][1]
    ordered, seen = [], set()
    for sequence, stamp, epoch, pcm in packets:
        offset = ((stamp - first + 0x80000000) & 0xffffffff) - 0x80000000
        check(abs(offset) < RATE * 180, 'Clock RTP clock exceeded its bounded timeline')
        if (sequence, stamp) not in seen:
            seen.add((sequence, stamp))
            ordered.append((offset, epoch, pcm))
    ordered.sort()
    earliest = ordered[0][0]
    ordered = [(offset - earliest,epoch,pcm) for offset,epoch,pcm in ordered]
    length = max(offset + len(pcm) // 2 for offset, _, pcm in ordered)
    output = bytearray(length * 2)
    gap = 0
    end = 0
    for offset, _, pcm in ordered:
        gap = max(gap, offset - end)
        output[offset * 2:offset * 2 + len(pcm)] = pcm
        end = max(end, offset + len(pcm) // 2)
    # Each received packet estimates the absolute RTP origin. The earliest
    # estimate excludes queueing delay; keep receiver delay in the evidence.
    origins = [epoch - offset * 1000 / RATE for offset, epoch, _ in ordered]
    origin = min(origins)
    return output, origin, gap * 1000 / RATE, max(origins) - min(origins)


def audio_frames(pcm):
    data = samples(pcm)
    result = []
    cosine = [math.cos(2 * math.pi * index / 8) for index in range(8)]
    sine = [math.sin(2 * math.pi * index / 8) for index in range(8)]
    for offset in range(0, len(data) - 159, 160):
        frame = data[offset:offset + 160]
        energy = sum(value * value for value in frame)
        real = sum(value * cosine[index % 8] for index, value in enumerate(frame))
        imaginary = sum(value * sine[index % 8] for index, value in enumerate(frame))
        result.append({'offset_ms': offset / 8, 'rms': math.sqrt(energy / 160),
                       'tone_ratio': 2 * (real * real + imaginary * imaginary) / (160 * energy) if energy else 0})
    return result


def beep_groups(frames):
    groups, current = [], []
    for row in frames:
        if row['rms'] >= 400 and row['tone_ratio'] >= .75:
            current.append(row)
        else:
            if len(current) >= 6:
                groups.append({'offset_ms': current[0]['offset_ms'], 'duration_ms': len(current) * 20})
            current = []
    if len(current) >= 6:
        groups.append({'offset_ms': current[0]['offset_ms'], 'duration_ms': len(current) * 20})
    return groups


def reference_match(pcm, reference, expected_ms, window_ms=450):
    actual = samples(pcm)
    with wave.open(str(reference)) as audio:
        check(audio.getnchannels() == 1 and audio.getsampwidth() == 2 and audio.getframerate() == RATE,
              'Clock reference is not mono PCM16 at 8000 Hz')
        wanted = samples(audio.readframes(audio.getnframes()))
    count = min(1600, len(wanted))
    check(count >= 160, 'Clock speech reference is too short')
    # Match a loud 200ms region; silence and file duration alone cannot pass.
    start = max(range(0, max(1, len(wanted) - count + 1), 160),
                key=lambda offset: sum(value * value for value in wanted[offset:offset + count]))
    word = wanted[start:start + count:4]
    energy = sum(value * value for value in word)
    check(energy > 0, 'Clock reference contains no speech')
    center = int(expected_ms * 8) + start
    low = max(0, center - window_ms * 8)
    high = min(len(actual) - count, center + window_ms * 8)
    best, at = -1.0, None
    # Cover every absolute sample phase. Searching only low + n*8 can miss
    # the waveform when an event timestamp has a different sample residue.
    # Frame-aligned native playback usually matches phase0 immediately; stop
    # early only on strong waveform identity, never on the acceptance floor.
    for phase in range(8):
        first = low + (phase - low) % 8
        for offset in range(first, high + 1, 8):
            part = actual[offset:offset + count:4]
            power = sum(value * value for value in part)
            if power:
                score = sum(a * b for a, b in zip(word, part)) / math.sqrt(energy * power)
                if score > best:
                    best, at = score, offset / 8 - start / 8
                if best >= .98:
                    return {'correlation': round(best, 5), 'offset_ms': at}
    return {'correlation': round(best, 5), 'offset_ms': at}


def reference_path(event, sound_root):
    path = Path(event['path'])
    if not path.is_absolute():
        path = sound_root / path
    check(path.is_file() and not path.is_symlink(), 'Clock reference file unavailable')
    check(path.resolve().is_relative_to(sound_root.resolve()), 'Clock reference escaped its owned sound root')
    return path


def sentence_paths(target):
    expected = time.gmtime(target / 1000 + 7200)
    def number(value):
        values = [value] if value <= 20 or value % 10 == 0 else [value // 10 * 10, value % 10]
        return ['en/us/callie/digits/8000/' + str(item) + '.wav' for item in values]
    base = 'openwebpbx/talking-clock-1.0.2-'
    return (['openwebpbx/talking-clock-1.0.1-signal.wav'] + number(expected.tm_hour) + [base + ('hour.wav' if expected.tm_hour == 1 else 'hours.wav')] +
            number(expected.tm_min) + [base + ('minute.wav' if expected.tm_min == 1 else 'minutes.wav'), base + 'and.wav'] + number(expected.tm_sec) +
            [base + 'seconds.wav', 'openwebpbx/talking-clock-1.0.1-exactly.wav'])


def analyze(work, events, packets, sound_root, phase):
    pcm, origin, rtp_gap, receiver_jitter = timeline(packets)
    with wave.open(str(work / 'clock-decoded.private.wav'), 'wb') as audio:
        audio.setnchannels(1);audio.setsampwidth(2);audio.setframerate(RATE);audio.writeframes(pcm)
    save(work / 'events.private.json', events)
    frames = audio_frames(pcm)
    beeps = beep_groups(frames)
    save(work / 'capture-metrics.safe.json',{'origin_epoch_ms':origin,'maximum_rtp_timestamp_gap_ms':rtp_gap,
         'receiver_queue_jitter_ms':receiver_jitter,'captured_rtp_packets':len(packets),'beeps':beeps})
    save(work / 'rtp-headers.private.json',[{'sequence':row[0],'timestamp':row[1],'received_epoch_ms':row[2],'pcm_bytes':len(row[3])} for row in packets])
    gates = []
    def require(value,message):
        gates.append({'passed':bool(value),'condition':message})
    starts = [event for event in events if event['name'] == 'PLAYBACK_START']
    spoken = [event for event in starts if event['path'].endswith('.wav') and not event['path'].endswith('-tick.wav')]
    welcome = [event for event in spoken if event['path'].endswith('talking-clock-1.0.2-welcome.wav')]
    check(len(welcome) == 1, 'Short clock welcome was not played exactly once')
    welcome_stop = next(event for event in events if event['name'] == 'PLAYBACK_STOP' and event['path'] == welcome[0]['path'])
    announcements = {}
    for event in spoken:
        target = event.get('announcement_target_ms')
        if target is not None and event not in welcome:
            announcements.setdefault(target, []).append(event)
    signals = [event for event in starts if 'tone_stream://' in event['path'] and '1000' in event['path']]
    complete = sorted(target for target in announcements if any(event.get('target_ms') == target for event in signals))
    check(len(complete) >= 3, 'Fewer than three complete clock announcements and native signals')
    complete = complete[:3]
    require(all(b - a == 15000 for a, b in zip(complete, complete[1:])), 'Clock announcements skipped a 15-second interval')
    proof = []
    first = announcements[complete[0]][0]
    first_gap = first['epoch_ms'] - welcome_stop['epoch_ms']
    require(0 <= first_gap < 1500, 'Clock waited after its welcome instead of speaking promptly')
    for target in complete:
        group = announcements[target]
        expected = time.gmtime(target / 1000 + 7200)
        require(all(event.get('version') == VERSION and event.get('hour') == expected.tm_hour
                  and event.get('minute') == expected.tm_min and event.get('second') == expected.tm_sec for event in group),
              'Clock native announcement fields do not match the GMT+2 target')
        actual_paths = [reference_path(event,sound_root).relative_to(sound_root).as_posix() for event in group]
        require(actual_paths == sentence_paths(target), 'Clock actual spoken number sequence differs from the GMT+2 target')
        for suffix in ('-hour.wav' if expected.tm_hour == 1 else '-hours.wav',
                       '-minute.wav' if expected.tm_min == 1 else '-minutes.wav', '-and.wav', '-seconds.wav'):
            require(any(event['path'].endswith(suffix) for event in group), 'Clock full-time speech omitted a required unit')
        matches = []
        for event in group:
            path = reference_path(event, sound_root)
            match = reference_match(pcm, path, event['epoch_ms'] - origin)
            require(match['correlation'] >= .62, 'A clock speech component was not verified in decoded RTP')
            matches.append({'file': path.name, 'sha256': sha(path), **match})
        signal = next(event for event in signals if event.get('target_ms') == target)
        require(0 <= signal['signal_ms'] - target < 250, 'Native clock signal missed its epoch target')
        near = [beep for beep in beeps if abs(origin + beep['offset_ms'] - target) < 350]
        require(len(near) == 1, 'Decoded 1000Hz beep did not uniquely align with native target')
        signal_offset = target - origin
        start_offset = max(0, group[0]['epoch_ms'] - origin - 300)
        end_offset = min(len(pcm) / 16, signal_offset + 400)
        clip = work / ('announcement-' + str(len(proof) + 1) + '.private.wav')
        with wave.open(str(clip), 'wb') as audio:
            audio.setnchannels(1);audio.setsampwidth(2);audio.setframerate(RATE)
            audio.writeframes(pcm[int(start_offset * 8) * 2:int(end_offset * 8) * 2])
        proof.append({'target_ms': target, 'gmt2': time.strftime('%H:%M:%S', expected),
                      'native_signal_lateness_ms': signal['signal_ms'] - target,
                      'decoded_beep_target_error_ms': round(origin + near[0]['offset_ms'] - target, 3) if len(near)==1 else None,
                      'decoded_beep_duration_ms': near[0]['duration_ms'] if len(near)==1 else None,
                      'minimum_component_correlation':min(match['correlation'] for match in matches),
                      'speech_components': matches,
                      'clip_sha256': sha(clip)})
    lower, upper = welcome_stop['epoch_ms'] - origin, complete[-1] - origin + 200
    silence, maximum = 0, 0
    for frame in frames:
        if lower <= frame['offset_ms'] <= upper:
            silence = silence + 20 if frame['rms'] < 100 else 0
            maximum = max(maximum, silence)
    require(maximum <= 1300, 'Clock produced an extended silent audio gap')
    require(rtp_gap <= 250, 'Clock stopped sending continuous RTP during its wait')
    result = {'all_passed': all(gate['passed'] for gate in gates), 'conditions':gates,'phase': phase, 'version': VERSION,
              'software_phone_only': True, 'no_carrier_calls': True,
              'complete_announcements': proof, 'post_welcome_first_speech_gap_ms': round(first_gap, 3),
              'maximum_decoded_silence_ms': maximum, 'maximum_rtp_timestamp_gap_ms': rtp_gap,
              'receiver_queue_jitter_ms': round(receiver_jitter, 3), 'captured_rtp_packets': len(packets),
              'decoded_audio_sha256': sha(work / 'clock-decoded.private.wav'),
              'speech_proof': 'Actual decoded RTP matched each native speech asset; clips retained for independent transcription/listening.'}
    save(work / 'result.safe.json', result)
    check(result['all_passed'], '; '.join(gate['condition'] for gate in gates if not gate['passed']))
    return result


def dependencies():
    manifest = json.loads((REPO / 'app/pbx_setup/resources/talking-clock/1.0.2/audio-manifest.json').read_text())
    hashes = dict(manifest['frozen_dependencies_sha256'])
    hashes.update({name:item['sha256'] for name,item in manifest['files'].items()})
    paths = re.findall(r"\['([^']+)'\]",(REPO / 'app/switch/resources/scripts/app/pbx_services/clock_prompts.lua').read_text())
    check(len(paths) == 34 and set(paths) == set(hashes), 'Clock dependency inventory is not the exact34 approved assets')
    return hashes, manifest['files']


def prepare_shadow(state):
    stage = Path(state['stage']);shadow = stage / 'scripts';sounds = stage / 'sounds'
    stage.mkdir(mode=0o750)
    save(stage / 'owner.json',{'domain':state['domain'],'realm':state['realm']})
    shutil.copytree(ENGINE_SCRIPTS, shadow)
    for name in ('clock.lua','clock_prompts.lua'):
        shutil.copyfile(REPO / 'app/switch/resources/scripts/app/pbx_services' / name,shadow / 'app/pbx_services' / name)
    hashes, additions = dependencies()
    for name, expected in hashes.items():
        relative = Path(name)
        check(not relative.is_absolute() and '..' not in relative.parts, 'Invalid clock sound path')
        source = REPO / 'app/pbx_setup/resources/prompts' / relative.name if name in additions else ENGINE_SOUNDS / relative
        check(sha(source) == expected, 'Clock audio dependency differs from its sealed manifest')
        target = sounds / relative;target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(source, target)
    wrapper = stage / 'clock.lua'
    wrapper.write_text("require 'resources.functions.config'\npackage.path=" + json.dumps(str(shadow) + '/?.lua;') + "..package.path\nscripts_dir=" + json.dumps(str(shadow)) + "\nsession:setVariable('sounds_dir'," + json.dumps(str(sounds)) + ")\nargv={[0]='app.lua',[1]='pbx_services',[2]='clock'}\nloadfile(scripts_dir..'/app.lua')()\n")
    owner = pwd.getpwnam('www-data')
    for path in [stage, *stage.rglob('*')]:
        check(not path.is_symlink(), 'Clock shadow contains a symbolic link')
        os.chown(path, owner.pw_uid, owner.pw_gid)
        path.chmod(0o750 if path.is_dir() else 0o640)
    return sounds, wrapper


def create_fixture(state, wrapper):
    check(sql('select count(*) from v_domains where domain_uuid=' + quote(state['domain']) + ' or domain_name=' + quote(state['realm'])) == '0',
          'Clock fixture identity already exists')
    statements = ['begin', 'insert into v_domains(domain_uuid,domain_name,domain_enabled,domain_description)values(' +
                  quote(state['domain']) + ',' + quote(state['realm']) + ",true,'Owned clock1026 native qualification')",
                  'insert into v_extensions(extension_uuid,domain_uuid,extension,number_alias,password,effective_caller_id_number,user_context,accountcode,dial_domain,enabled,call_timeout,max_registrations)values(' +
                  ','.join(quote(value) for value in [state['extension'],state['domain'],state['auth'],'991001',state['password'],'991001',state['realm'],state['realm'],state['realm']]) + ",'true',20,1)"]
    if wrapper:
        extension = ET.Element('extension', {'name':'Owned clock1026', 'continue':'false'})
        condition = ET.SubElement(extension, 'condition', {'field':'destination_number','expression':'^1026$'})
        for app, data in [('set','domain_uuid=' + state['domain']),('set','domain_name=' + state['realm']),('lua',str(wrapper))]:
            ET.SubElement(condition, 'action', {'application':app,'data':data})
        statements.append('insert into v_dialplans(dialplan_uuid,domain_uuid,dialplan_name,dialplan_number,dialplan_context,dialplan_order,dialplan_enabled,dialplan_xml,dialplan_continue)values(' +
                          ','.join(quote(value) for value in [state['dialplan'],state['domain'],'Owned clock1026','1026',state['realm']]) +
                          ',10,true,' + quote(ET.tostring(extension,encoding='unicode')) + ',false)')
    sql(';\n'.join(statements + ['commit']) + ';')


def cdr_directory():
    native_log = engine('global_getvar log_dir')
    check(native_log.startswith('/') and '\n' not in native_log, 'Native CDR log directory unavailable')
    setting = sql("select default_setting_value from v_default_settings where default_setting_category='switch' and default_setting_subcategory='log' and default_setting_enabled='true' order by default_setting_uuid limit 1")
    worker = Path(setting or '/var/log/freeswitch') / 'xml_cdr'
    params = {item.get('name'):item.get('value') for item in ET.parse('/etc/freeswitch/autoload_configs/xml_cdr.conf.xml').findall('.//param')}
    configured = params.get('log-dir') or str(Path(native_log) / 'xml_cdr')
    check(configured.startswith('/') and '$' not in configured, 'Native CDR directory needs explicit fixture review')
    check(Path(configured).resolve() == worker.resolve(), 'Native writer and durable importer use different CDR directories')
    check(worker.is_dir() and not worker.is_symlink(), 'Owned CDR cleanup directory unavailable')
    return worker


def retain_owned_spool(state, directory, work):
    retained = []
    for ident in state.get('owned_call_uuids', []):
        check(UUID.fullmatch(ident), 'Clock CDR ledger UUID invalid')
        for parent in (directory,directory/'failed/openweb',directory/'failed/xml',directory/'failed/sql',directory/'failed/size'):
            for name in (ident+'.cdr.xml','a_'+ident+'.cdr.xml'):
                path = parent / name
                if not path.exists():
                    continue
                check(not path.is_symlink() and path.is_file() and 0 < path.stat().st_size <= 3000000,
                      'Owned CDR cleanup refused an unsafe file')
                body = path.read_bytes()
                check(not re.search(br'<!\s*(?:DOCTYPE|ENTITY)',body,re.I), 'Owned CDR cleanup refused unsafe XML')
                document = ET.fromstring(body)
                check(document.tag == 'cdr', 'Owned CDR cleanup root invalid')
                variables = {}
                for item in document.findall('./variables/*'):
                    value = urllib.parse.unquote_plus(item.text or '')
                    if item.tag in variables:
                        check(variables[item.tag] == value, 'Owned CDR identity is ambiguous')
                    variables[item.tag] = value
                check((variables.get('uuid') or variables.get('call_uuid')) == ident and
                      variables.get('domain_uuid') == state['domain'] and variables.get('domain_name') == state['realm'] and
                      variables.get('sip_call_id') in state.get('sip_call_ids', []),
                      'Owned CDR cleanup refused mismatching UUID/domain/SIP identity')
                target = work / 'owned-cdr-retained'
                target.mkdir(mode=0o700,exist_ok=True)
                destination = target / (name + '.' + secrets.token_hex(4) + '.private.xml')
                digest = hashlib.sha256(body).hexdigest()
                check(sha(path) == digest, 'Owned CDR changed during cleanup')
                os.replace(path,destination)
                check(sha(destination) == digest, 'Owned CDR retention changed its original bytes')
                retained.append({'uuid':ident,'sha256':digest,'bytes':len(body)})
    return retained


def importer_guard(directory):
    path = directory / '.openweb-import.lock'
    descriptor = os.open(path,os.O_RDWR | os.O_NOFOLLOW)
    check(stat.S_ISREG(os.fstat(descriptor).st_mode),'Durable importer lock is not a regular file')
    deadline = time.monotonic() + 10
    try:
        while True:
            try:
                fcntl.flock(descriptor,fcntl.LOCK_EX | fcntl.LOCK_NB)
                return descriptor
            except BlockingIOError:
                check(time.monotonic() < deadline,'Durable importer did not release its existing lock')
                time.sleep(.05)
    except BaseException:
        os.close(descriptor)
        raise


def cleanup(state, work):
    check(UUID.fullmatch(state['domain']) and state['realm'].startswith('clock-check-') and state['realm'].endswith('.invalid'), 'Clock cleanup identity invalid')
    owned = sql('select json_build_object(\'realm\',domain_name,\'description\',domain_description) from v_domains where domain_uuid=' + quote(state['domain']))
    if owned:
        row = json.loads(owned)
        check(row == {'realm':state['realm'],'description':'Owned clock1026 native qualification'}, 'Clock cleanup refused a different domain owner')
    engine('hupall NORMAL_CLEARING domain_uuid ' + state['domain'])
    deadline = time.monotonic() + 10
    while any(engine('uuid_exists ' + ident) == 'true' for ident in state.get('owned_call_uuids', [])):
        check(time.monotonic() < deadline,'Owned clock channel survived hangup')
        time.sleep(.05)
    for callid in state.get('registration_call_ids', []):
        check(re.fullmatch('[a-f0-9]{24}@localfixture',callid), 'Clock registration ledger invalid')
        engine('sofia profile internal flush_inbound_reg ' + callid)
    # A failed REGISTER can have committed before its response was received.
    engine('sofia profile internal flush_inbound_reg ' + state['auth'] + '@' + state['realm'])
    time.sleep(2)  # Allow the native final CDR writer to finish the owned leg.
    tables = sql("select c.table_name from information_schema.columns c join information_schema.tables t using(table_schema,table_name) where c.table_schema='public' and c.column_name='domain_uuid' and c.table_name like 'v\\_%' escape '\\' and t.table_type='BASE TABLE' order by c.table_name").splitlines()
    directory = cdr_directory()
    retained = []
    # The existing importer uses this same flock. Hold it only while relocating
    # exact owned XML and deleting that domain's rows, so no read-before-delete
    # import can later recreate history. Customer spool files remain untouched.
    for _ in range(3):
        descriptor = importer_guard(directory)
        try:
            retained += retain_owned_spool(state,directory,work)
            statements = ['begin']
            for table in tables:
                check(re.fullmatch(r'v_[a-z0-9_]+',table), 'Unexpected clock cleanup table identifier')
                if table != 'v_domains':
                    statements.append('delete from ' + table + ' where domain_uuid=' + quote(state['domain']))
            statements += ['delete from v_domains where domain_uuid=' + quote(state['domain']), 'commit']
            sql(';\n'.join(statements) + ';')
        finally:
            fcntl.flock(descriptor,fcntl.LOCK_UN);os.close(descriptor)
        time.sleep(3)
    save(work/'owned-cdr-cleanup.safe.json',{'retained_owned_records':retained,'existing_importer_lock_used':True,
         'foreign_spool_files_read_or_modified':0,'owned_uuid_count':len(state.get('owned_call_uuids',[]))})
    stage = Path(state['stage'])
    suffix = state['realm'].removeprefix('clock-check-').removesuffix('.invalid')
    check(stage == Path('/var/lib/freeswitch/storage') / ('clock-native-' + suffix) and not stage.is_symlink(), 'Clock cleanup path invalid')
    if stage.exists():
        check(json.loads((stage / 'owner.json').read_text()) == {'domain':state['domain'],'realm':state['realm']}, 'Clock cleanup refused a different shadow owner')
        shutil.rmtree(stage)
    check(sql('select count(*) from v_domains where domain_uuid=' + quote(state['domain'])) == '0', 'Owned clock domain remains')
    tasks = json.loads(engine('show tasks as json'))
    check(isinstance(tasks,dict) and isinstance(tasks.get('rows'),list), 'Native task cleanup inventory unavailable')
    owned_tasks = [row for row in tasks['rows'] if any(ident in json.dumps(row) for ident in state.get('owned_call_uuids',[]))]
    channel_exists = {ident:engine('uuid_exists ' + ident) for ident in state.get('owned_call_uuids',[])}
    registrations = engine('sofia status profile internal reg')
    matches = [line for line in registrations.splitlines() if state['realm'] in line or state['auth'] in line or
               any(ident in line for ident in state.get('registration_call_ids',[]))]
    contact_absent = engine('sofia_contact ' + state['auth'] + '@' + state['realm']).startswith('error/')
    evidence = {'all_passed':not owned_tasks and all(value == 'false' for value in channel_exists.values()) and
                not matches and contact_absent,'captured_at_ms':time.time_ns() // 1000000,
                'native_tasks_json_supported':True,'owned_task_rows':owned_tasks,'owned_channel_exists':channel_exists,
                'owned_registration_matching_lines':len(matches),'owned_registration_contact_absent':contact_absent,
                'owned_domain_rows':0,'shadow_removed':not stage.exists()}
    save(work/'final-native-cleanup.safe.json',evidence)
    check(evidence['all_passed'], 'Owned clock channel, contact or native timer remains after cleanup')


def execute(args):
    check(os.geteuid() == 0 and os.environ.get('OPENWEB_CLOCK_NATIVE_TEST') == '1' and args.execute_owned_native_test,
          'Clock native test requires explicit coordinated execution')
    work = args.work.resolve()
    check(work.parent == PRIVATE_ROOT and not work.exists(), 'Use a fresh child of the private clock repair directory')
    PRIVATE_ROOT.mkdir(mode=0o700, exist_ok=True);work.mkdir(mode=0o700)
    executed_source = work / 'harness-executed.private.py'
    shutil.copyfile(Path(__file__),executed_source);executed_source.chmod(0o600)
    save(work/'harness-source.safe.json',{'sha256':sha(executed_source),'retained_before_fixture_creation':True})
    suffix = secrets.token_hex(6)
    state = {'phase':args.phase,'domain':str(uuid.uuid4()),'realm':'clock-check-' + suffix + '.invalid',
             'extension':str(uuid.uuid4()),'dialplan':str(uuid.uuid4()),'auth':'clock-' + suffix,
             'password':secrets.token_hex(24),'stage':'/var/lib/freeswitch/storage/clock-native-' + suffix,
             'registration_call_ids':[],'owned_call_uuids':[],'sip_call_ids':[]}
    save(work / 'state.private.json',state)
    phone = observer = call = None
    primary = None
    try:
        sounds, wrapper = prepare_shadow(state) if args.phase == 'preflight' else (ENGINE_SOUNDS,None)
        hashes, _ = dependencies()
        bindings = {name:sha(sounds / name) for name in hashes}
        check(bindings == hashes, 'Native clock sound root does not match the complete sealed dependency set')
        script_root = Path(state['stage']) / 'scripts' if wrapper else ENGINE_SCRIPTS
        for name in ('clock.lua','clock_prompts.lua'):
            check(sha(script_root / 'app/pbx_services' / name) == sha(REPO / 'app/switch/resources/scripts/app/pbx_services' / name), 'Native clock script differs from its reviewed source')
        save(work / 'bindings.safe.json',{'audio':bindings,'scripts':{name:sha(script_root / 'app/pbx_services' / name) for name in ('index.lua','clock.lua','clock_prompts.lua')},'identity_sha256':sha(script_root / 'resources/functions/mailbox_identity.lua')})
        create_fixture(state,wrapper)
        profile = engine('sofia status profile internal')
        bind = re.search(r'^\s*SIP-IP\s+(\S+)',profile,re.M).group(1)
        check(bind in socket.gethostbyname_ex(socket.gethostname())[2] or bind == '127.0.0.1' or
              subprocess.run(['ip','address','show','to',bind],capture_output=True).stdout,
              'Clock SIP target must be an interface on this host')
        Phone = load_phone(work)
        phone = Phone({'number':state['auth'],'auth':state['auth'],'password':state['password']},state['realm'])
        observer = ClockEvents(state)
        registered = phone.register((bind,5060))
        state['registration_call_ids'] = phone.registration_call_ids
        save(work / 'state.private.json',state)
        check(registered['code'] == 200, 'Clock software phone did not register')
        call = phone.dial('1026',(bind,5060))
        state['sip_call_ids'].append(call['callid'])
        save(work/'state.private.json',state)
        check(call['code'] == 200, 'Clock1026 was not answered')
        deadline = time.monotonic() + 75
        while time.monotonic() < deadline:
            check(phone.thread.is_alive() and not call['media'].get('ended'), 'Clock ended or software phone failed early')
            events = observer.snapshot(call['callid'])
            observed = sorted({event['uuid'] for event in events if event.get('uuid') and UUID.fullmatch(event['uuid'])})
            if observed != state['owned_call_uuids']:
                state['owned_call_uuids'] = observed;save(work/'state.private.json',state)
            signals = [event for event in events if event['name']=='PLAYBACK_STOP' and 'tone_stream://' in event['path'] and '1000' in event['path']]
            if len(signals) >= 3:
                time.sleep(.4)
                break
            time.sleep(.05)
        events = observer.snapshot(call['callid'])
        check(any(event['authorized'] for event in events), 'Clock call did not use an authenticated SIP identity')
        result = analyze(work,events,call['media']['clock_capture'].snapshot(),sounds,args.phase)
        print('PASS owned ' + args.phase + ' clock1026: ' + str(len(result['complete_announcements'])) + ' decoded full-time announcements',flush=True)
    except BaseException as error:
        primary = error
        save(work / 'failure.safe.json',{'all_passed':False,'phase':args.phase,'error_type':type(error).__name__})
        raise
    finally:
        failures = []
        if observer and call:
            try:
                state['owned_call_uuids'] = sorted(set(state['owned_call_uuids']) | {event['uuid'] for event in observer.snapshot(call['callid']) if event.get('uuid') and UUID.fullmatch(event['uuid'])})
                save(work/'state.private.json',state)
            except BaseException as error:failures.append(type(error).__name__)
        for operation in [lambda:phone.hangup(call) if phone and call and call['code']==200 and not call['media'].get('ended') else None,
                          lambda:phone.register((bind,5060),expires=0) if phone else None,
                          lambda:phone.close() if phone else None,
                          lambda:observer.close() if observer else None,
                          lambda:cleanup(state,work)]:
            try:operation()
            except BaseException as error:failures.append(type(error).__name__)
        save(work / 'cleanup.safe.json',{'all_passed':not failures,'cleanup_error_types':failures,'owned_domain_removed':not failures})
        if failures and primary is None:
            raise RuntimeError('Clock owned-fixture cleanup failed')


def self_test():
    # Actual signal detector/reassembly/reference matcher, without any network.
    pcm = b''.join(struct.pack('<h',int(5000*math.sin(2*math.pi*1000*index/RATE))) for index in range(1600))
    output, origin, gap, jitter = timeline([(index,(index*160)&0xffffffff,1000000+index*20,pcm[:320]) for index in range(100)])
    check(len(output)==32000 and origin==1000000 and gap==0 and jitter==0,'Synthetic RTP timeline failed')
    beeps = beep_groups(audio_frames(pcm))
    check(len(beeps)==1 and beeps[0]['duration_ms']==200,'Actual1000Hz detector failed')
    quiet = b'\0'*16000
    check(not beep_groups(audio_frames(quiet)),'Silence passed the beep detector')
    tick = b''.join(struct.pack('<h',int(500*math.sin(2*math.pi*440*index/RATE))) for index in range(480)) + quiet[:15040]
    check(not beep_groups(audio_frames(tick)),'Quiet440Hz wait tick passed the1000Hz detector')
    records = [(index,index*160,1000000+index*20,pcm[:320]) for index in range(101)]
    dropped = timeline([record for record in records if record[0] != 4])
    check(dropped[2] == 20 and len(dropped[0]) == 32320,'Lost RTP packet was hidden by PCM concatenation')
    reordered = timeline([records[1],records[0],*records[2:]])
    check(reordered == timeline(records),'Early reordered RTP changed the native audio clock')
    with tempfile.TemporaryDirectory(prefix='clock-audio-math-') as folder:
        path = Path(folder) / 'reference.wav'
        speech = b''.join(struct.pack('<h',int(4000*math.sin(2*math.pi*677*index/RATE) + 1000*math.sin(2*math.pi*133*index/RATE))) for index in range(1600))
        with wave.open(str(path),'wb') as audio:
            audio.setnchannels(1);audio.setsampwidth(2);audio.setframerate(RATE);audio.writeframes(speech)
        match = reference_match(quiet[:1600] + speech + quiet,path,100,30)
        check(match['correlation'] > .99 and abs(match['offset_ms'] - 100) < 2,'Actual decoded-reference matcher lost the known signal')
        check(reference_match(quiet,path,100,30)['correlation'] < .62,'Silence passed actual decoded-reference matching')
        # A nonperiodic waveform makes an incorrect sample residue fail rather
        # than obtaining a misleading match one period away. The event's
        # expected residue is deliberately fixed while all8 actual phases vary.
        generator = random.Random(1026)
        speech = b''.join(struct.pack('<h',generator.randrange(-6000,6001)) for _ in range(1600))
        with wave.open(str(path),'wb') as audio:
            audio.setnchannels(1);audio.setsampwidth(2);audio.setframerate(RATE);audio.writeframes(speech)
        for phase in range(8):
            prefix = b'\0' * (2 * (800 + phase))
            match = reference_match(prefix + speech + quiet,path,100.625,30)
            check(match['correlation'] > .999 and match['offset_ms'] == (800 + phase) / 8,
                  'Reference matcher missed a nonperiodic waveform sample phase')
    singular = sentence_paths((23 * 60 + 1) * 60000)
    plural = sentence_paths(0)
    check('openwebpbx/talking-clock-1.0.2-hour.wav' in singular and
          'openwebpbx/talking-clock-1.0.2-minute.wav' in singular and
          'openwebpbx/talking-clock-1.0.2-hours.wav' not in singular and
          'openwebpbx/talking-clock-1.0.2-minutes.wav' not in singular,
          'Independent GMT+2 clock expectation lost singular hour/minute')
    check('openwebpbx/talking-clock-1.0.2-hours.wav' in plural and
          'openwebpbx/talking-clock-1.0.2-minutes.wav' in plural,
          'Independent GMT+2 clock expectation lost plural hours/minutes')
    print('PASS clock native harness RTP/reordering/gap/beep/reference controls; no PBX or database contacted')


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--self-test',action='store_true')
    parser.add_argument('--phase',choices=['preflight','installed'])
    parser.add_argument('--work',type=Path)
    parser.add_argument('--execute-owned-native-test',action='store_true')
    args=parser.parse_args()
    if args.self_test:self_test();return
    check(args.phase and args.work,'Choose an explicit phase and fresh private evidence directory')
    execute(args)


if __name__ == '__main__':
    main()
