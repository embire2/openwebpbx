"""Exercise actual framing, private rotation and secret redaction, no PBX calls."""
import importlib.util
import json
import os
from pathlib import Path
import socket
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('diagnostics', Path(__file__).resolve().parents[1] / 'packaging/debian/call-diagnostics.py')
d = importlib.util.module_from_spec(spec)
spec.loader.exec_module(d)


class DiagnosticsTests(unittest.TestCase):
    def test_redaction_and_tenant_scope(self):
        uid = '00000000-0000-4000-a000-000000000001'
        event = {'Event-Name': 'CHANNEL_HANGUP_COMPLETE', 'Unique-ID': uid,
                 'variable_domain_uuid': uid, 'variable_sip_auth_password': 'SECRET',
                 'variable_sip_h_Authorization': 'SECRET', 'variable_switch_r_sdp': 'SECRET',
                 'DTMF-Digit': 'SECRET', 'Application-Data': 'SECRET',
                 'Caller-Caller-ID-Number': '+27871234567', 'Caller-Destination-Number': '1050',
                 'variable_remote_media_ip': '192.0.2.20', 'variable_rtp_audio_in_packet_count': '123',
                 'variable_rtp_audio_in_mos': '4.5', 'variable_sip_call_id': 'PRIVATE-CALL-ID'}
        result = d.project(event, [uid])
        self.assertNotIn('SECRET', json.dumps(result))
        self.assertNotIn('PRIVATE-CALL-ID', json.dumps(result))
        self.assertEqual(result['caller'], '***4567')
        self.assertEqual(result['destination'], '1050')
        self.assertEqual(result['remote_media_ip'], '192.0.2.20')
        self.assertEqual(result['rtp_audio_in_packet_count'], '123')
        self.assertIsNone(d.project(event, ['foreign']))

    def test_unknown_and_custom_events(self):
        self.assertIsNone(d.project({'Event-Name': 'DTMF'}))
        self.assertIsNone(d.project({'Event-Name': 'CUSTOM', 'Event-Subclass': 'other'}))
        result = d.project({'Event-Name': 'CUSTOM', 'Event-Subclass': 'openweb::call_trace',
                            'OpenWeb-Stage': 'provider_attempt', 'OpenWeb-Trunk': '10008',
                            'OpenWeb-Target': '0873508601', 'OpenWeb-Cause': 'bad\nvalue'})
        self.assertEqual(result['trunk'], '10008')
        self.assertEqual(result['target'], '***8601')
        self.assertNotIn('route_cause', result)

    def test_fragmented_frames_survive_timeout(self):
        left, right = socket.socketpair()
        try:
            left.settimeout(.02)
            frames = d.Frames(left)
            right.sendall(b'Content-Type: text/event-json\nContent-Length: 7\n\n{"a"')
            with self.assertRaises(socket.timeout):
                frames.receive()
            right.sendall(b':1}Content-Type: command/reply\nReply-Text: +OK\n\n')
            self.assertEqual(json.loads(frames.receive()[1]), {'a': 1})
            self.assertEqual(frames.receive()[0]['Reply-Text'], '+OK')
        finally:
            left.close(); right.close()

    def test_frame_limit(self):
        left, right = socket.socketpair()
        try:
            right.sendall(b'Content-Length: 3000000\n\n')
            with self.assertRaises(ValueError):
                d.Frames(left).receive()
        finally:
            left.close(); right.close()

    @unittest.skipUnless(os.geteuid() == 0, 'Actual private root journal permissions')
    def test_rotation_and_link_refusal(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'events.jsonl'
            journal = d.Journal(path, 100, 2)
            for i in range(20):
                journal.write({'event': 'test', 'index': i})
            files = list(Path(directory).iterdir())
            self.assertEqual(len(files), 3)
            self.assertTrue(all(p.stat().st_mode & 0o077 == 0 and p.stat().st_size <= 100 for p in files))
            path.unlink(); path.symlink_to('/etc/passwd')
            with self.assertRaises(ValueError):
                journal.write({'event': 'refused'})

    def test_no_connection_when_expired(self):
        # An expired configuration must not authenticate or subscribe at all.
        old = d.Journal
        records = []
        class MemoryJournal:
            def write(self, record): records.append(record)
        d.Journal = MemoryJournal
        try:
            d.collect({'expires_at': 1, 'host': '127.0.0.1', 'port': 1, 'password': 'fixture'})
        finally:
            d.Journal = old
        self.assertEqual([r['event'] for r in records], ['diagnostics_started', 'diagnostics_expired'])


if __name__ == '__main__':
    unittest.main()
