"""Actual diagnostic/parser code controls; no PBX or native media is claimed."""
import importlib.util
import ast
import copy
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

    def refresh_fixture(self):
        peers = [Peer(name) for name in ('8100', '8101', '8102')]
        users = [dict(number=peer.aor, auth=peer.auth_user, password=peer.password,
                      extension_uuid='owned-' + str(index)) for index, peer in enumerate(peers)]
        rows = {peer.auth_user: dict(extension_uuid=user['extension_uuid'], password_sha256=hashlib.sha256(peer.password.encode()).hexdigest(), absolute_codec_string='PCMU') for peer, user in zip(peers, users)}
        class RefreshFixture:
            def __init__(self):
                self.s = dict(users=users, realm=peers[0].realm)
                self.calls, self.checks, self.status_reads = [], [], 0
                self.status = dict(bind='127.0.0.1', extension_codec_preferences=rows, registration_limits=['1'] * 4)
            def cli(self, action, command=None, **options):
                if action == 'status':
                    self.status_reads += 1
                    return copy.deepcopy(self.status)
                return 'sofia/owned-contact'
            def record(self, case, **facts):
                self.checks.append(dict(case=case, **facts))
        fixture = RefreshFixture()
        for index, peer in enumerate(peers):
            peer.transport = 'tls' if index == 0 else 'udp'
            peer.hold_registration_destination = ('127.0.0.1', 5061 if index == 0 else 5060)
            peer.check_receiver = lambda: None
            def register(endpoint, item=peer):
                fixture.calls.append((item.aor, endpoint))
                hold.registration_result(item, dict(code=200, text='SIP/2.0 200 OK\r\nExpires: 120\r\n\r\n'), 120, hold.time.monotonic())
                return dict(code=200)
            peer.register = register
        return fixture, peers

    def test_synchronous_refresh_preserves_identity_endpoints_and_policy(self):
        for phase in hold.REFRESH_BOUNDARIES:
            fixture, peers = self.refresh_fixture()
            before = copy.deepcopy(fixture.status)
            hold.refresh_owned_peers(fixture, peers, phase)
            self.assertEqual(fixture.calls, [('8100', ('127.0.0.1', 5061)), ('8101', ('127.0.0.1', 5060)), ('8102', ('127.0.0.1', 5060))])
            self.assertEqual(fixture.status, before)
            self.assertEqual(fixture.checks[0]['peer_count'], 3)
            self.assertTrue(fixture.checks[0]['no_product_registration_change'])
            self.assertNotIn('private', json.dumps(fixture.checks))

    def test_refresh_excludes_g729_interleave_and_offline_voicemail(self):
        for phase in ('during_g729', 'before_voicemail', '', None):
            fixture, peers = self.refresh_fixture()
            with self.assertRaises(AssertionError):
                hold.refresh_owned_peers(fixture, peers, phase)
            self.assertFalse(fixture.calls)
            self.assertEqual(fixture.status_reads, 0)
        fixture, peers = self.refresh_fixture();peers[2].aor = '8103'
        with self.assertRaises(AssertionError):hold.refresh_owned_peers(fixture, peers, 'before_hold')
        self.assertFalse(fixture.calls)

    def test_refresh_refuses_changed_endpoint_or_identity_before_register(self):
        for field, value in [('endpoint', ('127.0.0.1', 5060)), ('password', 'changed-owned-password'), ('transport', 'unknown')]:
            fixture, peers = self.refresh_fixture()
            if field == 'endpoint':peers[0].hold_registration_destination = value
            elif field == 'transport':peers[0].transport = value
            else:peers[0].password = value
            with self.assertRaises(AssertionError):hold.refresh_owned_peers(fixture, peers, 'before_hold')
            self.assertFalse(fixture.calls)

    def test_failed_refresh_or_changed_lease_cannot_complete(self):
        for code, lease in [(403, 120), (200, 180)]:
            fixture, peers = self.refresh_fixture()
            def changed(endpoint):
                fixture.calls.append(('8100', endpoint))
                hold.registration_result(peers[0], dict(code=code, text=f'SIP/2.0 {code} Result\r\nExpires: {lease}\r\n\r\n'), 120, hold.time.monotonic())
                return dict(code=code)
            peers[0].register = changed
            with self.assertRaises(AssertionError):hold.refresh_owned_peers(fixture, peers, 'before_hold')
            self.assertEqual(len(fixture.calls), 1)
            self.assertFalse(fixture.checks)

    def test_refresh_requires_unchanged_actual_sql_identity(self):
        for kind in ('password', 'limit'):
            fixture, peers = self.refresh_fixture();original = peers[2].register
            def changed(endpoint):
                result = original(endpoint)
                if kind == 'password':fixture.status['extension_codec_preferences'][peers[0].auth_user]['password_sha256'] = 'changed'
                else:fixture.status['registration_limits'][0] = '2'
                return result
            peers[2].register = changed
            with self.assertRaises(AssertionError):hold.refresh_owned_peers(fixture, peers, 'before_hold')
            self.assertFalse(fixture.checks)

    def test_200_without_actual_current_contact_is_refused(self):
        fixture, peers = self.refresh_fixture();original = fixture.cli
        fixture.cli = lambda action, *args, **kw: original(action, *args, **kw) if action == 'status' else 'error/user_not_registered'
        with self.assertRaises(AssertionError):hold.refresh_owned_peers(fixture, peers, 'before_hold')
        self.assertEqual(len(fixture.calls), 1)
        self.assertFalse(fixture.checks)

    def test_fixed_boundaries_follow_g729_and_never_refresh_the_offline_peer(self):
        tree = ast.parse(Path(__file__).with_name('windows-native-acceptance.py').read_text())
        calls = [node for node in ast.walk(tree) if isinstance(node, ast.Call) and isinstance(node.func, ast.Attribute) and node.func.attr == 'refresh_owned_peers']
        phases = [node.args[2].value for node in sorted(calls, key=lambda node: node.lineno)]
        self.assertEqual(phases, ['after_clock', 'before_provider_services', 'before_groups', 'before_hold', 'before_callbacks', 'before_hotel', 'before_voicemail_deposit', 'before_mailbox_retrieval'])
        for node in calls:
            self.assertEqual([item.id for item in node.args[1].elts], ['caller', 'a', 'b'])
        native = next(node for node in ast.walk(tree) if isinstance(node, ast.FunctionDef) and node.name == 'native_calls')
        g729 = next(node for node in ast.walk(native) if isinstance(node, ast.Try) and any(isinstance(item, ast.Assign) and any(isinstance(target, ast.Attribute) and target.attr == 'native_substage' for target in item.targets) and isinstance(item.value, ast.Constant) and item.value.value == 'g729_regular_unregister' for item in node.body))
        self.assertLess(g729.end_lineno, next(node.lineno for node in calls if node.args[2].value == 'before_provider_services'))
        hold_branch = next(node for node in ast.walk(native) if isinstance(node, ast.If) and isinstance(node.test, ast.Name) and node.test.id == 'hold_only')
        self.assertTrue(any(isinstance(node, ast.Return) for node in ast.walk(hold_branch)))
        self.assertLess(hold_branch.end_lineno, min(node.lineno for node in calls))
        text = Path(__file__).with_name('windows-native-acceptance.py').read_text()
        self.assertIn("len(self.registration_packets)<=40", text)
        self.assertLessEqual((1 + 2 + len(hold.REFRESH_BOUNDARIES) + 1) * 3, 40)

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
