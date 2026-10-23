"""Bounded diagnostics for the owned native hold/transfer case; no product edits."""
import hashlib
import re
import time

STAGES = {'before', 'initial_invite', 'initial_destination', 'initial_media', 'hold_request',
          'hold_music', 'resume_request', 'resumed_audio', 'transfer_request',
          'transfer_destination', 'transferred_audio', 'end_transferred_call', 'complete'}


def registration_result(peer, result, requested, started):
    """Retain only negotiated lease metadata, never authentication headers."""
    lifetime = -1
    text = result.get('text', '')
    if isinstance(text, str) and len(text) <= 1048576:
        headers = text.split('\r\n\r\n', 1)[0]
        lines = headers.splitlines()
        values = [match.group(1) for line in lines if (match := re.fullmatch(r'Expires:\s*([0-9]{1,5})\s*', line, re.I))]
        contacts = [match.group(1) for line in lines if (match := re.fullmatch(r'Contact:\s*(.+)', line, re.I))]
        contact_values = re.findall(r';\s*expires=([0-9]{1,5})(?=\s|;|$)', contacts[0], re.I) if len(contacts) == 1 and ',' not in contacts[0] else []
        selected = contact_values if len(contact_values) == 1 else values if len(values) == 1 and len(contacts) <= 1 else []
        if len(contacts) > 1 or (contacts and ',' in contacts[0]) or len(contact_values) > 1:
            selected = []
        if len(selected) == 1 and 0 <= int(selected[0]) <= 86400:
            lifetime = int(selected[0])
    peer.hold_registration = {'observed': result.get('code') == 200,
                              'code': result.get('code', 0), 'requested': requested,
                              'accepted': lifetime, 'started': started}


def contact_state(fixture, peer):
    value = fixture.cli('api', 'sofia_contact ' + peer.auth_user + '@' + peer.realm, json_result=False)
    if not isinstance(value, str) or len(value) > 65536:
        raise AssertionError('The owned contact query is unavailable')
    value = value.strip()
    if value.startswith('sofia/'):
        return 'registered'
    if value == 'error/user_not_registered':
        return 'unregistered'
    return 'unknown'


class Observer:
    def __init__(self, fixture, peers):
        assert set(peers) == {'caller', 'first', 'second'}
        self.fixture, self.peers, self.started = fixture, peers, time.monotonic()
        self.stage = 'before'
        self.codes = dict(invite=0, hold=0, resume=0, transfer=0)
        self.baseline = {name: (set(peer.dialogs), len(peer.invites)) for name, peer in peers.items()}
        self.before = self.snapshot()

    def snapshot(self):
        peers = {}
        for name, peer in self.peers.items():
            before, invites = self.baseline[name]
            rows = [value for key, value in list(peer.dialogs.items()) if key not in before]
            error = getattr(peer, 'receiver_failure', None)
            kind = 'none' if error is None else next((name for cls, name in
                   ((ConnectionResetError, 'ConnectionResetError'), (OSError, 'OSError'),
                    (AssertionError, 'AssertionError')) if isinstance(error, cls)), 'other')
            reg = getattr(peer, 'hold_registration', {})
            age = int((time.monotonic() - reg['started']) * 1000) if reg.get('observed') is True else -1
            row = {'contact': 'unknown', 'contact_query_failed': False,
                   'receiver_running': bool(peer.thread.is_alive()), 'receiver_failure': kind,
                   'registration_observed': reg.get('observed') is True,
                   'registration_code': int(reg.get('code', 0)),
                   'requested_expires': int(reg.get('requested', -1)),
                   'accepted_expires': int(reg.get('accepted', -1)),
                   'registration_age_ms': age, 'new_invites': max(0, len(peer.invites) - invites),
                   'new_dialogs': len(rows), 'acked_dialogs': sum(bool(v.get('acked')) for v in rows),
                   'ended_dialogs': sum(bool(v.get('ended')) for v in rows)}
            try:
                row['contact'] = contact_state(self.fixture, peer)
            except BaseException:
                row['contact_query_failed'] = True
            peers[name] = row
        return peers

    def record(self):
        return {'schema': 1, 'stage': self.stage, 'elapsed_ms': int((time.monotonic() - self.started) * 1000),
                'codes': dict(self.codes), 'before': self.before, 'after': self.snapshot()}


def qualify(fixture, caller, first, second, destination, media, decoded):
    """Run the original native operations, retaining the precise failed stage."""
    observe = Observer(fixture, dict(caller=caller, first=first, second=second))
    try:
        observe.stage = 'initial_invite'
        old = set(first.dialogs)
        call = caller.dial('8101', destination)
        observe.codes['invite'] = call['code']
        assert call['code'] == 200
        observe.stage = 'initial_destination'
        remote = fixture.wait(lambda: next((v for k, v in first.dialogs.items() if k not in old), None))
        observe.stage = 'initial_media'
        media(call, remote)
        observe.stage = 'hold_request'
        observe.codes['hold'] = caller.hold(call, True)
        assert observe.codes['hold'] == 200
        observe.stage = 'hold_music'
        time.sleep(10)
        music = fixture.music(bytes(remote['decoded_pcm']))
        observe.stage = 'resume_request'
        observe.codes['resume'] = caller.hold(call, False)
        assert observe.codes['resume'] == 200
        observe.stage = 'resumed_audio'
        time.sleep(4)
        decoded(remote, caller.tone_hz)
        observe.stage = 'transfer_request'
        before = set(second.dialogs)
        observe.codes['transfer'] = caller.blind_transfer(call, '8102')
        assert observe.codes['transfer'] in (200, 202)
        observe.stage = 'transfer_destination'
        transferred = fixture.wait(lambda: next((v for k, v in second.dialogs.items()
                                                if k not in before and v.get('acked')), None))
        observe.stage = 'transferred_audio'
        time.sleep(5)
        decoded(transferred, first.tone_hz)
        observe.stage = 'end_transferred_call'
        first.hangup_incoming(next(k for k, v in first.dialogs.items() if v is remote))
        observe.stage = 'complete'
        return music
    except BaseException as error:
        try:
            error.hold_failure = {'hold_diagnostics': observe.record()}
        except BaseException:
            error.hold_failure = {'hold_diagnostics': {'schema': 1, 'stage': observe.stage,
                                                      'snapshot_unavailable': True}}
        raise


def expiry_diagnostic(fixture, peers, run_hold):
    """Observe genuine lease expiry and identical-tuple re-registration only."""
    assert len(peers) == 3
    identity = [(peer.aor, peer.auth_user, peer.password, peer.realm) for peer in peers]
    leases = [getattr(peer, 'hold_registration', {}) for peer in peers]
    def actual_tuples():
        rows = fixture.cli('status')['extension_codec_preferences']
        result = {}
        for peer in peers:
            row = rows[peer.auth_user]
            assert row['password_sha256'] == hashlib.sha256(peer.password.encode()).hexdigest()
            expected = next(user for user in fixture.s['users'] if user['auth'] == peer.auth_user)
            assert row['extension_uuid'] == expected['extension_uuid']
            result[peer.auth_user] = (row['extension_uuid'], row['password_sha256'])
        return result
    original_tuples = actual_tuples()
    destinations = [getattr(peer, 'hold_registration_destination', None) for peer in peers]
    assert all(type(value) is tuple and len(value) == 2 and isinstance(value[0], str) and
               type(value[1]) is int and 1 <= value[1] <= 65535 for value in destinations)
    run_hold('immediate')
    fixture.active_case = 'native_hold_diagnostic_lease_metadata'
    assert all(row.get('observed') is True and type(row.get('accepted')) is int and
               1 <= row['accepted'] <= 180 and type(row.get('requested')) is int and
               row['requested'] == 120 for row in leases), 'The actual short negotiated leases are required'
    fixture.active_case = 'native_hold_diagnostic_natural_expiry'
    expected_expiry = max(row['started'] + row['accepted'] for row in leases)
    limit = expected_expiry + 120
    assert limit - time.monotonic() <= 300, 'The natural expiry observation must remain bounded'
    while time.monotonic() < limit:
        for peer in peers:
            peer.check_receiver()
        if all(contact_state(fixture, peer) == 'unregistered' for peer in peers):
            assert time.monotonic() >= expected_expiry - 1, 'Contacts disappeared before their negotiated leases expired'
            break
        time.sleep(2)
    else:
        raise AssertionError('The unchanged native contacts did not naturally expire in the bounded window')
    fixture.record('native_hold_diagnostic_natural_expiry_observed', requested_expires=120,
                   negotiated_expires=[row['accepted'] for row in leases], no_product_registration_change=True)
    fixture.active_case = 'native_hold_diagnostic_registration_recovery'
    for peer, destination in zip(peers, destinations):
        assert peer.register(destination)['code'] == 200
    assert [(peer.aor, peer.auth_user, peer.password, peer.realm) for peer in peers] == identity
    assert actual_tuples() == original_tuples
    assert all(contact_state(fixture, peer) == 'registered' for peer in peers)
    run_hold('reregistered')
    fixture.record('native_hold_diagnostic_identical_tuple_reregistered', exact_tuples_preserved=True,
                   all_three_actual_contacts_returned=True, no_product_registration_change=True)


REFRESH_BOUNDARIES = {'after_clock', 'before_provider_services', 'before_groups',
                      'before_hold', 'before_callbacks', 'before_hotel',
                      'before_voicemail_deposit', 'before_mailbox_retrieval'}


def refresh_owned_peers(fixture, peers, boundary):
    """Keep the three ordinary software contacts current at fixed phase edges.

    This deliberately has no timer/thread. It cannot interleave the alternate
    G729 unregister test or register the intentionally offline voicemail phone.
    """
    assert boundary in REFRESH_BOUNDARIES
    assert len(peers) == 3 and [peer.aor for peer in peers] == ['8100', '8101', '8102']
    assert [peer.transport for peer in peers] == ['tls', 'udp', 'udp']
    fixture.active_case = 'native_owned_registration_refresh_' + boundary
    identity = [(p.aor, p.auth_user, p.password, p.realm, p.transport) for p in peers]
    destinations = [getattr(p, 'hold_registration_destination', None) for p in peers]
    before = fixture.cli('status')
    expected_rows = before['extension_codec_preferences']
    leases = []
    for peer, endpoint in zip(peers, destinations):
        peer.check_receiver()
        expected = next(u for u in fixture.s['users'] if u['number'] == peer.aor)
        assert (expected['auth'], expected['password'], fixture.s['realm']) == (peer.auth_user, peer.password, peer.realm)
        row = expected_rows[peer.auth_user]
        assert row['extension_uuid'] == expected['extension_uuid']
        assert row['password_sha256'] == hashlib.sha256(peer.password.encode()).hexdigest()
        assert endpoint == (before['bind'], 5061 if peer.transport == 'tls' else 5060)
        registration = getattr(peer, 'hold_registration', {})
        assert registration.get('observed') is True and registration.get('code') == 200
        assert type(registration.get('requested')) is int and registration['requested'] == 120
        assert type(registration.get('accepted')) is int and 1 <= registration['accepted'] <= 86400
        leases.append(registration['accepted'])
    for peer, endpoint, lease in zip(peers, destinations, leases):
        result = peer.register(endpoint)
        if result.get('code') != 200:
            raise AssertionError('The exact owned software-phone lease could not be refreshed')
        current = peer.hold_registration
        assert current.get('requested') == 120 and current.get('accepted') == lease
        peer.check_receiver()
        assert contact_state(fixture, peer) == 'registered'
    after = fixture.cli('status')
    assert [(p.aor, p.auth_user, p.password, p.realm, p.transport) for p in peers] == identity
    assert [p.hold_registration_destination for p in peers] == destinations
    assert after['extension_codec_preferences'] == expected_rows
    assert after['registration_limits'] == before['registration_limits']
    assert all(contact_state(fixture, peer) == 'registered' for peer in peers)
    fixture.record('native_owned_registration_refresh_' + boundary, peer_count=3,
                   unchanged_authentication_tuples=True, unchanged_registration_endpoints=True,
                   all_actual_contacts_current=True, negotiated_expiry_unchanged=True,
                   no_product_registration_change=True)
