"""Actual diagnostic/parser code controls; no PBX or native media is claimed."""
import importlib.util
import hashlib
import json
from pathlib import Path
from types import SimpleNamespace
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('owned_hold_diagnostic', Path(__file__).with_name('windows_hold_native.py'))
hold = importlib.util.module_from_spec(spec)
spec.loader.exec_module(hold)


class Peer:
    def __init__(self, name):
        self.aor = self.auth_user = name
        self.password, self.realm = 'private-password-never-export', 'private-realm.invalid'
        self.tone_hz = 440
        self.dialogs, self.invites = {}, []
        self.thread = SimpleNamespace(is_alive=lambda: True)
        self.receiver_failure = None
        self.hold_registration = dict(observed=True, code=200, requested=120, accepted=120, started=hold.time.monotonic())


class Fixture:
    def __init__(self, peers):
        self.peers = peers
        self.failed_queries = False
        self.offline = set()

    def cli(self, action, command, **options):
        if self.failed_queries:
            raise RuntimeError('private-message-never-export')
        peer = next(peer for peer in self.peers if command == 'sofia_contact ' + peer.auth_user + '@' + peer.realm)
        return 'error/user_not_registered' if peer.auth_user in self.offline else 'sofia/private-contact-never-export'

    def wait(self, predicate):
        value = predicate()
        if value is None:
            raise AssertionError('Bounded fixture observation expired')
        return value

    def music(self, pcm):
        return dict(correlation=.9, held_seconds=8)


class Tests(unittest.TestCase):
    def expiry(self, early=False):
        clock = SimpleNamespace(now=1000.0)
        def sleep(seconds):
            clock.now += seconds
        with patch.object(hold.time, 'monotonic', side_effect=lambda: clock.now), patch.object(hold.time, 'sleep', side_effect=sleep):
            peers = [Peer(name) for name in ('caller', 'first', 'second')]
            endpoints = [('127.0.0.1', 5061), ('127.0.0.1', 5060), ('127.0.0.1', 5060)]
            calls, phases = [], []
            users = [dict(auth=peer.auth_user, extension_uuid='owned-' + str(index)) for index, peer in enumerate(peers)]
            rows = {peer.auth_user: dict(extension_uuid=user['extension_uuid'], password_sha256=hashlib.sha256(peer.password.encode()).hexdigest()) for peer, user in zip(peers, users)}
            def register(peer, destination):
                calls.append((peer.auth_user, destination))
                peer.hold_registration = dict(observed=True, code=200, requested=120, accepted=120, started=clock.now)
                return dict(code=200)
            for peer, endpoint in zip(peers, endpoints):
                peer.hold_registration_destination = endpoint
                peer.check_receiver = lambda: None
                peer.register = lambda destination, item=peer: register(item, destination)
            class ExpiryFixture:
                s = dict(users=users)
                checks = []
                def cli(self, action, command=None, **options):
                    if action == 'status':
                        return dict(extension_codec_preferences=rows)
                    peer = next(item for item in peers if command == 'sofia_contact ' + item.auth_user + '@' + item.realm)
                    return 'error/user_not_registered' if early or clock.now >= peer.hold_registration['started'] + 120 else 'sofia/owned'
                def record(self, case, **facts):
                    self.checks.append(dict(case=case, **facts))
            fixture = ExpiryFixture()
            def run_hold(phase):
                phases.append(phase)
                clock.now += 5
            if early:
                with self.assertRaisesRegex(AssertionError, 'before their negotiated'):
                    hold.expiry_diagnostic(fixture, peers, run_hold)
                self.assertFalse(calls)
            else:
                hold.expiry_diagnostic(fixture, peers, run_hold)
                self.assertEqual([destination for _, destination in calls], endpoints)
                self.assertEqual(phases, ['immediate', 'reregistered'])
                self.assertGreaterEqual(clock.now, 1120)
                self.assertEqual(len(fixture.checks), 2)
                self.assertNotIn('private', json.dumps(fixture.checks))

    def test_expiry_uses_original_tls_and_udp_endpoints(self):
        self.expiry()

    def test_early_disappearance_is_not_natural_expiry(self):
        self.expiry(early=True)

    def test_registration_headers_keep_only_lease_metadata(self):
        cases = [
            ('Contact: <sip:private@host>;expires=120\r\n', 120),
            ('cOnTaCt: <sip:private@host>;expires=30\r\n', 30),
            ('Expires: 120\r\n', 120),
            ('Contact: <sip:a@host>;expires=120\r\nContact: <sip:b@host>;expires=120\r\nExpires: 120\r\n', -1),
            ('Contact: <sip:a@host>;expires=120,<sip:b@host>;expires=120\r\n', -1),
            ('Contact: <sip:a@host>;expires=120;expires=130\r\n', -1),
            ('Contact: <sip:a@host>;expires=99999\r\n', -1),
            ('Expires: -1\r\n', -1), ('', -1)]
        for headers, expected in cases:
            with self.subTest(headers=headers):
                peer = Peer('owned')
                hold.registration_result(peer, dict(code=200, text='SIP/2.0 200 OK\r\n' + headers + 'Authorization: private-secret-never-export\r\n\r\n'), 120, 42.0)
                self.assertEqual(peer.hold_registration['accepted'], expected)
                self.assertEqual(set(peer.hold_registration), {'observed', 'code', 'requested', 'accepted', 'started'})
                self.assertNotIn('private', json.dumps(peer.hold_registration))

    def test_contact_errors_are_not_invented_expiry(self):
        peer = Peer('owned')
        for text, expected in [('sofia/owned', 'registered'), ('error/user_not_registered', 'unregistered'),
                               ('error/invalid_profile', 'unknown'), ('-ERR unavailable', 'unknown')]:
            fixture = SimpleNamespace(cli=lambda *args, value=text, **kw: value)
            self.assertEqual(hold.contact_state(fixture, peer), expected)

    def test_snapshot_has_no_identity_or_exception_message(self):
        peers = [Peer(name) for name in ('caller', 'first', 'second')]
        fixture = Fixture(peers)
        observer = hold.Observer(fixture, dict(zip(('caller', 'first', 'second'), peers)))
        fixture.failed_queries = True
        peers[1].receiver_failure = OSError('private-error-never-export')
        result = observer.record()
        self.assertTrue(all(row['contact_query_failed'] for row in result['after'].values()))
        self.assertEqual(result['after']['first']['receiver_failure'], 'OSError')
        self.assertNotIn('private', json.dumps(result))

    def case(self, missing):
        caller, first, second = [Peer(name) for name in ('caller', 'first', 'second')]
        fixture = Fixture([caller, first, second])
        events = []
        remote = dict(decoded_pcm=b'owned-audio', acked=True, ended=False)
        def dial(number, destination):
            events.append('dial')
            if missing != 'initial':
                first.dialogs['owned-first'] = remote
                first.invites.append({})
            return dict(code=200)
        caller.dial = dial
        caller.hold = lambda call, value: events.append('hold' if value else 'resume') or 200
        def transfer(call, target):
            events.append('transfer')
            if missing != 'transfer':
                second.dialogs['owned-second'] = dict(acked=True, ended=False)
                second.invites.append({})
            return 202
        caller.blind_transfer = transfer
        first.hangup_incoming = lambda callid: events.append('hangup')
        media = lambda *args: events.append('media')
        decoded = lambda *args: events.append('decoded')
        return fixture, caller, first, second, events, media, decoded

    def test_initial_wait_is_distinct_from_transfer_wait(self):
        for missing, stage in [('initial', 'initial_destination'), ('transfer', 'transfer_destination')]:
            fixture, caller, first, second, events, media, decoded = self.case(missing)
            with patch.object(hold.time, 'sleep'), self.assertRaises(AssertionError) as captured:
                hold.qualify(fixture, caller, first, second, ('127.0.0.1', 5060), media, decoded)
            result = captured.exception.hold_failure['hold_diagnostics']
            self.assertEqual(result['stage'], stage)
            self.assertEqual(result['codes']['invite'], 200)
            self.assertEqual(result['codes']['transfer'], 0 if missing == 'initial' else 202)
            self.assertNotIn('private', json.dumps(result))

    def test_original_hold_operations_and_waits_are_preserved(self):
        fixture, caller, first, second, events, media, decoded = self.case(None)
        with patch.object(hold.time, 'sleep') as sleeps:
            result = hold.qualify(fixture, caller, first, second, ('127.0.0.1', 5060), media, decoded)
        self.assertEqual(result, dict(correlation=.9, held_seconds=8))
        self.assertEqual(events, ['dial', 'media', 'hold', 'resume', 'decoded', 'transfer', 'decoded', 'hangup'])
        self.assertEqual([call.args[0] for call in sleeps.call_args_list], [10, 4, 5])


if __name__ == '__main__':
    unittest.main()
