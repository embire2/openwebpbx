"""Portable QA-only adapter for the existing decoded 1026 native-clock proof.

The caller owns fixture creation, registration, unregistering, and peer closure.
This adapter calls only 1026 on that already registered fictional peer. It never
imports Linux fixture setup, executes SQL, or changes PBX configuration.
"""
import array
import ast
import hashlib
import ipaddress
import json
import math
import os
from pathlib import Path
import re
import socket
import struct
import sys
import threading
import time
import types
import urllib.parse
import uuid
import wave

PORTABLE_FUNCTIONS = frozenset(('check', 'sha', 'save', 'samples', 'timeline',
    'audio_frames', 'beep_groups', 'reference_match', 'reference_path',
    'sentence_paths', 'analyze', 'dependencies'))
PORTABLE_CLASSES = frozenset(('Capture', 'RecordingSocket', 'ClockEvents'))
CLOCK_PHASES = frozenset(('preflight', 'bindings', 'observer', 'invite', 'signals', 'analyze', 'cleanup'))


def load_clock(source_root, event_socket):
    """Load only reviewed portable definitions, with explicit private ESL input."""
    source_root = Path(source_root)
    path = source_root / 'tests/pbx_talking_clock_native.py'
    tree = ast.parse(path.read_text(encoding='utf-8'), filename=str(path))
    nodes = [node for node in tree.body if
             isinstance(node, ast.FunctionDef) and node.name in PORTABLE_FUNCTIONS or
             isinstance(node, ast.ClassDef) and node.name in PORTABLE_CLASSES]
    names = [node.name for node in nodes]
    if len(names) != len(set(names)) or set(names) != PORTABLE_FUNCTIONS | PORTABLE_CLASSES:
        raise AssertionError('The portable native clock definition inventory differs.')
    values = {}
    for node in tree.body:
        if isinstance(node, ast.Assign) and len(node.targets) == 1 and isinstance(node.targets[0], ast.Name):
            if node.targets[0].id in ('RATE', 'VERSION'):
                values[node.targets[0].id] = ast.literal_eval(node.value)
    if values != {'RATE': 8000, 'VERSION': '1.0.2'}:
        raise AssertionError('The reviewed native clock constants differ.')
    host, port, password = event_socket['host'], event_socket['port'], event_socket['password']
    if host not in ('127.0.0.1', '::1', 'localhost') or type(port) is not int or not 1 <= port <= 65535:
        raise AssertionError('Only an explicit local event socket is allowed.')
    if type(password) is not str or not password or any(c in password for c in '\r\n'):
        raise AssertionError('The explicit local event socket credentials are invalid.')
    namespace = {name: globals()[name] for name in ('array', 'hashlib', 'json', 'math', 'os',
                 'Path', 're', 'socket', 'struct', 'sys', 'threading', 'time', 'urllib', 'wave')}
    namespace.update(REPO=source_root, RATE=8000, VERSION='1.0.2',
                     UUID=re.compile(r'^[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}$'),
                     event_settings=lambda: (host, port, password))
    exec(compile(ast.Module(body=nodes, type_ignores=[]), str(path), 'exec'), namespace)
    return types.SimpleNamespace(**namespace)


def windows_recording_socket(recording_socket):
    class WindowsClockRecordingSocket(recording_socket):
        def recv(self, *args, **kwargs):
            try:
                return super().recv(*args, **kwargs)
            except ConnectionResetError as error:
                # RecordingSocket receives through recvfrom, so the existing
                # WindowsRtpSocket.recv-only guard cannot intercept this case.
                if os.name != 'nt' or getattr(error, 'winerror', None) != 10054:
                    raise
                raise BlockingIOError('Previous owned RTP send reported a port unreachable') from error
    return WindowsClockRecordingSocket


def verify_bindings(clock, source_root, sound_root, script_root, work):
    source_root, sound_root, script_root = map(Path, (source_root, sound_root, script_root))
    hashes, _ = clock.dependencies()
    clock.check(len(hashes) == 34, 'The clock does not have exactly34 approved sound dependencies')
    actual = {}
    for name, wanted in hashes.items():
        relative = Path(name)
        clock.check(not relative.is_absolute() and '..' not in relative.parts, 'The clock dependency path is unsafe')
        path = sound_root / relative
        clock.check(path.is_file() and not path.is_symlink() and
                    path.resolve().is_relative_to(sound_root.resolve()), 'The installed clock sound is unavailable or unsafe')
        actual[name] = clock.sha(path)
        clock.check(actual[name] == wanted, 'An installed clock sound differs from the frozen Nathaniel asset')
    scripts = {}
    for name in ('clock.lua', 'clock_prompts.lua'):
        installed = script_root / 'app/pbx_services' / name
        source = source_root / 'app/switch/resources/scripts/app/pbx_services' / name
        clock.check(installed.is_file() and not installed.is_symlink() and
                    installed.resolve().is_relative_to(script_root.resolve()), 'The installed clock script is unavailable or unsafe')
        scripts[name] = clock.sha(installed)
        clock.check(scripts[name] == clock.sha(source), 'An installed clock script differs from reviewed source')
    proof = {'sourcebindings_verified': True, 'frozen_Nathaniel_assets': len(actual), 'audio': actual,
             'scripts': scripts, 'native_analyzer_source_sha256': clock.sha(source_root / 'tests/pbx_talking_clock_native.py')}
    clock.save(work / 'bindings.safe.json', proof)
    return proof


def close_observer(observer):
    """Also close a partially constructed observer after auth/subscription failure."""
    if observer is None:
        return
    if not hasattr(observer, 'thread') and hasattr(observer, 'socket'):
        observer.stopped = True
        observer.socket.close()
        return
    try:
        observer.close()
    finally:
        observer.stopped = True
        sock = getattr(observer, 'socket', None)
        if sock is not None:
            sock.close()
        thread = getattr(observer, 'thread', None)
        if thread is not None:
            thread.join(2)
            if thread.is_alive():
                raise AssertionError('The scoped clock event observer did not stop.')


def qualify_clock(phone, original_peer_module, state, source_root, sound_root, script_root, private_work):
    """Return a closed safe summary after genuine RTP analysis and owned cleanup."""
    phase, primary, observer, call, result = 'preflight', None, None, None, None
    clock = None
    work = Path(private_work)
    before_outgoing = {id(value) for value in phone.outgoing}
    had_media_override = 'media' in phone.__dict__
    original_override = phone.__dict__.get('media')
    original_media = phone.media
    changed_media = False
    captures = []
    cleanup = []
    try:
        if work.exists() or not work.is_absolute() or '..' in work.parts or work.resolve() != work:
            raise AssertionError('A new canonical private evidence directory is required.')
        if not re.fullmatch(r'[A-Za-z0-9.-]+', state['realm']) or str(uuid.UUID(state['domain'])) != state['domain']:
            raise AssertionError('The owned clock tenant identity is invalid.')
        if phone.realm != state['realm']:
            raise AssertionError('The registered peer belongs to a different clock tenant.')
        destination = state['sip_destination']
        if (type(destination) not in (tuple, list) or len(destination) != 2 or
                destination[0] != phone.ip or type(destination[1]) is not int or not 1 <= destination[1] <= 65535):
            raise AssertionError('Use the existing local peer SIP destination explicitly.')
        address = ipaddress.ip_address(destination[0])
        if address.is_unspecified or address.is_multicast:
            raise AssertionError('The owned clock SIP destination is invalid.')
        if any(not value.get('ended') for value in phone.dialogs.values()):
            raise AssertionError('The owned clock phone already has an active dialog.')
        work.mkdir(mode=0o700)
        clock = load_clock(source_root, state['event_socket'])
        phase = 'bindings'
        verify_bindings(clock, source_root, sound_root, script_root, work)
        Recorder = windows_recording_socket(clock.RecordingSocket)

        def media(pt=0):
            value = original_media(pt)
            value['clock_capture'] = clock.Capture()
            value['socket'] = Recorder(value['socket'], value, original_peer_module)
            captures.append(value)
            return value

        phone.media = media
        changed_media = True
        phase = 'observer'
        # Keep the partial object so failed ESL authentication cannot leak it.
        observer = clock.ClockEvents.__new__(clock.ClockEvents)
        observer.__init__(state)
        phase = 'invite'
        call = phone.dial('1026', tuple(destination))
        clock.check(call['code'] == 200, 'The owned native clock1026 call was not answered')
        clock.check(call['media'] in captures, 'The native clock call did not use its owned RTP capture')
        phase = 'signals'
        deadline = time.monotonic() + 75
        while time.monotonic() < deadline:
            if hasattr(phone, 'check_receiver'):
                phone.check_receiver()
            clock.check(phone.thread.is_alive() and not call['media'].get('ended'),
                        'The owned clock call or RTP receiver ended early')
            events = observer.snapshot(call['callid'])
            signals = [event for event in events if event['name'] == 'PLAYBACK_STOP' and
                       'tone_stream://' in event['path'] and '1000' in event['path']]
            if len(signals) >= 3:
                time.sleep(.4)
                break
            time.sleep(.05)
        events = observer.snapshot(call['callid'])
        clock.check(any(event['authorized'] for event in events), 'The clock did not use the registered authenticated SIP identity')
        phase = 'analyze'
        result = clock.analyze(work, events, call['media']['clock_capture'].snapshot(),
                               Path(sound_root), 'restored-Windows-target')
    except BaseException as error:
        primary = error
        primary.clock_phase = phase
        if work.is_dir() and clock is not None:
            try:
                clock.save(work / 'failure.safe.json', {'all_passed': False, 'clock_phase': phase,
                                                       'error_type': type(error).__name__})
            except BaseException as retained_error:
                cleanup.append(retained_error)
        raise
    finally:
        # Include a call returned into phone.outgoing just before a dial error.
        owned = [value for value in phone.outgoing if id(value) not in before_outgoing and
                 value.get('uri') == 'sip:1026@' + state['realm'] and
                 any(value.get('media') is media for media in captures)]
        if call is not None and call.get('code') == 200 and not any(value is call for value in owned):
            owned.append(call)
        for value in owned:
            try:
                if not value['media'].get('ended'):
                    phone.hangup(value)
                if not value['media'].get('ended'):
                    raise AssertionError('The owned clock dialog did not end.')
            except BaseException as error:
                cleanup.append(error)
        try:
            close_observer(observer)
        except BaseException as error:
            cleanup.append(error)
        if changed_media:
            if had_media_override:
                phone.media = original_override
            else:
                del phone.media
        for value in captures:
            # The peer still owns its socket until normal close, except media
            # never attached to a SIP dialog after a failed INVITE exchange.
            if not any(value is item for item in phone.dialogs.values()):
                try:
                    value['socket'].close()
                except BaseException as error:
                    cleanup.append(error)
        if clock is not None and work.is_dir():
            try:
                clock.save(work / 'cleanup.safe.json', {'all_passed': not cleanup,
                'owned_clock_calls': len(owned), 'owned_clock_calls_ended': all(v['media'].get('ended') for v in owned),
                'original_phone_media_restored': not changed_media or
                    (phone.__dict__.get('media') is original_override if had_media_override else 'media' not in phone.__dict__),
                'observer_stopped': observer is None or getattr(observer, 'stopped', False),
                'captured_rtp_packets': sum(len(value['clock_capture'].snapshot()) for value in captures),
                'foreign_rtp_packets_rejected': sum(value['clock_capture'].foreign_packets for value in captures),
                'cleanup_error_types': [type(error).__name__ for error in cleanup]})
            except BaseException as retained_error:
                cleanup.append(retained_error)
        if cleanup:
            if primary is not None:
                primary.clock_cleanup_error_types = tuple(type(error).__name__ for error in cleanup)
            else:
                cleanup[0].clock_phase = 'cleanup'
                raise cleanup[0]
    proof = {'sourcebindings_verified': True, 'frozen_Nathaniel_assets': 34,
             'complete_announcements': len(result['complete_announcements']), 'GMT_plus_2_full_time_verified': True,
             'minimum_component_correlation': min(item['minimum_component_correlation'] for item in result['complete_announcements']),
             'maximum_native_signal_lateness_ms': max(item['native_signal_lateness_ms'] for item in result['complete_announcements']),
             'maximum_decoded_beep_target_error_ms': max(abs(item['decoded_beep_target_error_ms']) for item in result['complete_announcements']),
             'original_phone_media_restored': True, 'owned_clock_call_ended': True, 'scoped_observer_stopped': True,
             'software_phone_only': True, 'no_carrier_calls_or_database_configuration_writes': True}
    clock.save(work / 'qualification.safe.json', proof)
    return proof
