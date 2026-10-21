"""Portable adapter controls; never contact a PBX, database, or event socket."""
import importlib.util
import json
import math
from pathlib import Path
import socket
import struct
import tempfile
import types
import unittest
from unittest.mock import patch
import wave

SPEC = importlib.util.spec_from_file_location('windows_clock_native', Path(__file__).with_name('windows_clock_native.py'))
adapter = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(adapter)
REPO = Path(__file__).resolve().parents[1]
EVENT = {'host': '127.0.0.1', 'port': 8021, 'password': 'PRIVATE_QA_ESL_VALUE'}


class Sock:
    def __init__(self, error=None, packet=None):
        self.error, self.packet, self.closed = error, packet, False
    def recvfrom(self, size):
        if self.error is not None:
            raise self.error
        return self.packet, ('127.0.0.1', 9010)
    def close(self):
        self.closed = True


class Phone:
    def __init__(self):
        self.realm, self.ip = 'clock.windows.invalid', '127.0.0.1'
        self.dialogs, self.outgoing, self.hungup = {}, [], []
        self.thread = types.SimpleNamespace(is_alive=lambda: True)
        self.dial_error = self.hangup_error = None
    def media(self, pt=0):
        return {'pt': pt, 'socket': Sock(), 'target': None}
    def dial(self, number, destination):
        assert number == '1026' and destination == ('127.0.0.1', 5060)
        value = self.media()
        self.dialogs['owned-clock-call'] = value
        call = {'code': 200, 'media': value, 'callid': 'owned-clock-call', 'uri': 'sip:1026@' + self.realm}
        self.outgoing.append(call)
        if self.dial_error:
            raise self.dial_error
        return call
    def hangup(self, call):
        self.hungup.append(call)
        if self.hangup_error:
            raise self.hangup_error
        call['media']['ended'] = True


class Observer:
    instances = []
    def __init__(self, state):
        self.stopped = False
        self.__class__.instances.append(self)
    def snapshot(self, callid):
        assert callid == 'owned-clock-call'
        return [{'authorized': True, 'name': 'PLAYBACK_STOP', 'path': 'tone_stream://%(200,0,1000)'}] * 3
    def close(self):
        self.stopped = True


class ClockAdapterTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='windows-clock-portable-controls-')
        self.root = Path(self.temporary.name)
        self.clock = adapter.load_clock(REPO, EVENT)
        Observer.instances = []
        self.state = {'realm': 'clock.windows.invalid', 'domain': '11111111-2222-4333-8444-555555555555',
                      'sip_destination': ['127.0.0.1', 5060], 'event_socket': dict(EVENT)}
    def tearDown(self):
        self.temporary.cleanup()
    def run_qualifier(self, phone=None, analyze=None, observer=Observer):
        phone = phone or Phone()
        clock = types.SimpleNamespace(**vars(self.clock))
        clock.ClockEvents = observer
        clock.analyze = analyze or (lambda *args: {'complete_announcements': [
            {'minimum_component_correlation': .9998, 'native_signal_lateness_ms': 12,
             'decoded_beep_target_error_ms': -17.5}] * 3})
        with patch.object(adapter, 'load_clock', return_value=clock), \
             patch.object(adapter, 'verify_bindings', return_value={'sourcebindings_verified': True}), \
             patch.object(adapter.time, 'sleep', return_value=None):
            return adapter.qualify_clock(phone, types.SimpleNamespace(), self.state, REPO,
                                         self.root / 'sounds', self.root / 'scripts', self.root / 'work')
    def test_AST_only_portable_code_and_exact_manifest(self):
        self.assertEqual(len(self.clock.dependencies()[0]), 34)
        self.assertFalse(hasattr(self.clock, 'sql'))
        self.assertFalse(hasattr(self.clock, 'execute'))
        self.assertFalse(hasattr(self.clock, 'prepare_shadow'))
        self.assertFalse(hasattr(self.clock, 'fcntl'))
        self.assertFalse(hasattr(self.clock, 'pwd'))
        self.assertEqual(self.clock.event_settings(), ('127.0.0.1', 8021, EVENT['password']))
    def test_ESL_guards(self):
        for field, value in [('host', '203.0.113.8'), ('port', '8021'), ('port', 0),
                             ('password', ''), ('password', 'line\nbreak')]:
            with self.subTest(field=field, value=value), self.assertRaises(AssertionError):
                adapter.load_clock(REPO, dict(EVENT) | {field: value})
    def test_Windows_recvfrom_10054_only(self):
        wrapper = adapter.windows_recording_socket(self.clock.RecordingSocket)
        for system, code, expected in [('nt', 10054, BlockingIOError), ('nt', 10053, ConnectionResetError),
                                       ('posix', 10054, ConnectionResetError)]:
            error = ConnectionResetError('private fake reset');error.winerror = code
            state = {'pt': 0, 'target': ('127.0.0.1', 9010), 'clock_capture': self.clock.Capture()}
            receiver = wrapper(Sock(error=error), state, types.SimpleNamespace())
            with self.subTest(system=system, code=code), patch.object(adapter.os, 'name', system), self.assertRaises(expected):
                receiver.recv(4096)
            self.assertEqual(state['clock_capture'].snapshot(), [])
    def test_valid_RTP_decoded_and_unknown_peer_excluded(self):
        packet = struct.pack('!BBHII', 0x80, 0, 71, 1600, 73) + b'\xff' * 160
        capture = self.clock.Capture();state = {'pt': 0, 'target': ('127.0.0.1', 9010), 'clock_capture': capture}
        receiver = adapter.windows_recording_socket(self.clock.RecordingSocket)(Sock(packet=packet), state,
            types.SimpleNamespace(decode_ulaw=lambda value: 19))
        self.assertEqual(receiver.recv(4096), packet)
        sequence, timestamp, _, pcm = capture.snapshot()[0]
        self.assertEqual((sequence, timestamp, pcm), (71, 1600, struct.pack('<h', 19) * 160))
        state['target'] = ('127.0.0.1', 9011);receiver.recv(4096)
        self.assertEqual(len(capture.snapshot()), 1)
        self.assertEqual(capture.foreign_packets, 1)
    def test_existing_signal_and_gap_analyzers(self):
        pcm = b''.join(struct.pack('<h', int(5000 * math.sin(2 * math.pi * 1000 * i / 8000))) for i in range(1600))
        self.assertEqual(self.clock.beep_groups(self.clock.audio_frames(pcm)), [{'offset_ms': 0, 'duration_ms': 200}])
        self.assertEqual(self.clock.beep_groups(self.clock.audio_frames(b'\0' * 16000)), [])
        rows = [(i, i * 160, 1000000 + i * 20, pcm[:320]) for i in range(101)]
        self.assertEqual(self.clock.timeline([r for r in rows if r[0] != 4])[2], 20)
        self.assertEqual(self.clock.timeline([rows[1], rows[0], *rows[2:]]), self.clock.timeline(rows))
    def test_reference_matching_rejects_silence(self):
        reference = self.root / 'reference.wav'
        pcm = b''.join(struct.pack('<h', int(4000 * math.sin(2 * math.pi * 677 * i / 8000))) for i in range(1600))
        with wave.open(str(reference), 'wb') as audio:
            audio.setnchannels(1);audio.setsampwidth(2);audio.setframerate(8000);audio.writeframes(pcm)
        self.assertGreater(self.clock.reference_match(b'\0' * 1600 + pcm + b'\0' * 16000, reference, 100, 30)['correlation'], .99)
        self.assertLess(self.clock.reference_match(b'\0' * 16000, reference, 100, 30)['correlation'], .62)
    def test_binding_verifies_all_34_sounds_and_two_scripts(self):
        source = self.root / 'source';sounds = self.root / 'sounds';scripts = self.root / 'scripts'
        (source / 'tests').mkdir(parents=True);(source / 'tests/pbx_talking_clock_native.py').write_text('source identity')
        hashes = {}
        for i in range(34):
            name = 'openwebpbx/sound-' + str(i) + '.wav';path = sounds / name;path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(str(i).encode());hashes[name] = self.clock.sha(path)
        for name in ('clock.lua', 'clock_prompts.lua'):
            for path in (scripts / 'app/pbx_services' / name, source / 'app/switch/resources/scripts/app/pbx_services' / name):
                path.parent.mkdir(parents=True, exist_ok=True);path.write_bytes(name.encode())
        bound = types.SimpleNamespace(**vars(self.clock));bound.dependencies = lambda: (hashes, {})
        proof = adapter.verify_bindings(bound, source, sounds, scripts, self.root)
        self.assertEqual(proof['frozen_Nathaniel_assets'], 34)
        self.assertEqual(len(proof['scripts']), 2)
        (sounds / next(iter(hashes))).write_bytes(b'changed')
        with self.assertRaisesRegex(AssertionError, 'frozen Nathaniel'):
            adapter.verify_bindings(bound, source, sounds, scripts, self.root)
    def test_success_restores_media_hangs_up_only_own_call_and_closes_observer(self):
        phone = Phone();summary = self.run_qualifier(phone)
        self.assertEqual(len(phone.hungup), 1)
        self.assertEqual(summary['complete_announcements'], 3)
        self.assertEqual(summary['minimum_component_correlation'], .9998)
        self.assertEqual(summary['maximum_decoded_beep_target_error_ms'], 17.5)
        self.assertNotIn('media', phone.__dict__)
        self.assertTrue(Observer.instances[0].stopped)
        self.assertNotIn(EVENT['password'], json.dumps(summary))
    def test_existing_instance_media_override_restored_exactly(self):
        phone = Phone();original = phone.media;phone.media = original
        self.run_qualifier(phone)
        self.assertIs(phone.__dict__['media'], original)
    def test_primary_analysis_failure_survives_cleanup_failure(self):
        phone = Phone();phone.hangup_error = RuntimeError('private hangup failure')
        error = AssertionError('private analysis failure')
        def fail(*args):raise error
        with self.assertRaises(AssertionError) as caught:
            self.run_qualifier(phone, fail)
        self.assertIs(caught.exception, error)
        self.assertEqual(error.clock_phase, 'analyze')
        self.assertEqual(error.clock_cleanup_error_types, ('RuntimeError',))
        self.assertTrue(Observer.instances[0].stopped)
        self.assertNotIn('media', phone.__dict__)
        self.assertNotIn('private analysis failure', (self.root / 'work/failure.safe.json').read_text())
    def test_dial_exception_after_outgoing_identity_still_ends_own_call(self):
        phone = Phone();error = RuntimeError('private dial failure');phone.dial_error = error
        with self.assertRaises(RuntimeError) as caught:self.run_qualifier(phone)
        self.assertIs(caught.exception, error)
        self.assertEqual(error.clock_phase, 'invite')
        self.assertTrue(phone.hungup[0]['media']['ended'])
        self.assertTrue(Observer.instances[0].stopped)
        self.assertNotIn('media', phone.__dict__)
    def test_partial_observer_constructor_failure_closes_its_socket(self):
        sockets = []
        class BrokenObserver:
            def __init__(self, state):
                self.socket = Sock();sockets.append(self.socket)
                raise AssertionError('private auth failure')
        phone = Phone()
        with self.assertRaises(AssertionError) as caught:self.run_qualifier(phone, observer=BrokenObserver)
        self.assertEqual(caught.exception.clock_phase, 'observer')
        self.assertTrue(sockets[0].closed)
        self.assertEqual(phone.hungup, [])
        self.assertNotIn('media', phone.__dict__)
    def test_active_dialog_and_wrong_destination_refuse_before_calls(self):
        phone = Phone();phone.dialogs['foreign'] = {'ended': False}
        with self.assertRaisesRegex(AssertionError, 'active dialog'):self.run_qualifier(phone)
        self.assertEqual(phone.outgoing, [])
        phone.dialogs.clear();self.state['sip_destination'][0] = '192.0.2.7'
        with self.assertRaisesRegex(AssertionError, 'existing local peer'):self.run_qualifier(phone)
        self.assertEqual(phone.outgoing, [])


if __name__ == '__main__':
    unittest.main(verbosity=2)
