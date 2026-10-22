"""Actual Windows-only fictional provider/Call Me Back SIP/RTP qualification.

Uses the existing owned disposable tenant and software peers. No real provider,
identity, external voice generation or physical-phone acceptance is claimed.
"""
import re
import time


def qualify(f, caller, extension, destination, Provider, original, sip, Playback, provider_diagnostics):
    providers = []
    playback = None
    primary = None
    cleanup_errors = []
    try:
        for index in range(2):
            providers.append(Provider(index))
        f.active_case = 'native_fictional_provider_setup'
        f.cli('providers-create', *(str(peer.port) for peer in providers))
        f.refresh()
        realm = f.s['realm']
        inbound_destination = tuple(f.cli('services-info')['external_sip'])

        def decoded(left, right, left_frequency, right_frequency, seconds=3):
            left['decoded_pcm'].clear(); right['decoded_pcm'].clear()
            time.sleep(seconds)
            for peer in (caller, extension, *providers):
                peer.check_receiver()
                assert peer.thread.is_alive(), 'An owned SIP/RTP receiver stopped during the native media window'
            sip.rtp_rate_check(left); sip.rtp_rate_check(right)
            return original.decoded_tone_check(left, left_frequency), original.decoded_tone_check(right, right_frequency)

        # 3CX retries both 503 and 603; busy486 stops. Each retry must create
        # exactly one backup dialog and independently decode both audio paths.
        for number, winner, refused in [('99100', 0, None), ('99101', 1, None),
                                        ('99102', None, 486), ('99103', 1, 603)]:
            f.active_case = 'native_provider_' + number[-3:]
            before = [len(peer.invites) for peer in providers]
            dialogs = [set(peer.dialogs) for peer in providers]
            facts = provider_diagnostics.snapshot(f, providers, before, 'before')
            call = None
            try:
                call = caller.dial(number, destination)
                wire = '55' + number[2:]
                if winner is not None:
                    assert call['code'] == 200, 'The fictional provider call did not answer'
                    try:
                        remote = f.wait(lambda: next((value for key, value in providers[winner].dialogs.items()
                            if key not in dialogs[winner] and value.get('acked')), None))
                        down, up = decoded(call['media'], remote, providers[winner].tone_hz, caller.tone_hz)
                        assert remote['pt'] == 8 and call['media']['pt'] == 0
                    finally:
                        if not call['media'].get('ended'):
                            caller.hangup(call)
                else:
                    assert call['code'] >= 300, 'The refused provider call unexpectedly answered'
                    down = up = None
                time.sleep(.3)
                seen = [[row for row in peer.invites[start:] if row['number'] == wire]
                        for peer, start in zip(providers, before)]
                assert len({row['callid'] for row in seen[0]}) == 1, 'Primary call was missing or duplicated'
                assert len({row['callid'] for row in seen[1]}) == (1 if winner == 1 else 0), 'Unexpected backup or duplicate call'
                if refused is not None:
                    assert any(code == refused for _, code in providers[0].sent_codes[-8:]), 'The controlled refusal was not sent'
                elif winner == 1:
                    assert any(code == 503 for _, code in providers[0].sent_codes[-8:]), 'The controlled 503 was not sent'
                f.record('native_provider_' + ('603_failover_once_decoded_rtp' if refused == 603 else
                         '503_failover_once_decoded_rtp' if winner == 1 else
                         'outbound_decoded_rtp' if winner == 0 else 'busy_no_failover'),
                         primary_distinct_calls=1, backup_distinct_calls=1 if winner == 1 else 0,
                         caller_decoded_ratio=down, provider_decoded_ratio=up, no_carrier_traffic=True)
            except BaseException as error:
                facts.update(provider_diagnostics.snapshot(f, providers, before, 'after'))
                provider_diagnostics.attach(error, facts, call)
                raise

        f.active_case = 'native_provider_incoming_decoded_rtp'
        before = set(extension.dialogs)
        incoming = providers[0].call('sip:999100001@' + realm, inbound_destination,
                                    user='+27820000009', realm=realm, to_uri='sip:999100001@' + realm)
        assert incoming['code'] == 200
        try:
            remote = f.wait(lambda: next((value for key, value in extension.dialogs.items()
                if key not in before and value.get('acked')), None))
            down, up = decoded(incoming['media'], remote, extension.tone_hz, providers[0].tone_hz)
        finally:
            if not incoming['media'].get('ended'):
                providers[0].hangup(incoming)
        f.record('native_provider_incoming_owned_did_decoded_rtp',caller_decoded_ratio=down,
                 extension_decoded_ratio=up,no_carrier_traffic=True)

        f.active_case = 'native_cmb_hmac_quota_setup'
        setup = f.cli('cmb-setup'); f.refresh()
        assert setup['identity_hmac_verified'] is True and setup['no_plaintext_identity_in_database'] is True
        assert setup['configured_total_seconds'] == 3600
        cmb = f.s['cmb']
        playback = Playback.__new__(Playback)
        playback.__init__(f.cli('services-info')['event_socket'], realm)

        def state():
            value = f.cli('cmb-status')
            assert value['identity_hmac_unchanged'] is True
            return value

        def find_dialog(number, before):
            for peer in providers:
                for callid, media in list(peer.dialogs.items()):
                    if callid not in before and media.get('incoming') and not media.get('ended'):
                        target = media['incoming']['headers'].get('to', '')
                        if re.search(r'sip:' + re.escape(number) + '@', target):
                            return peer, callid, media
            return None

        def run(new_identity, quota=None):
            f.active_case = 'native_cmb_' + ('new_identity' if new_identity else 'short_quota' if quota is not None else 'saved_caller')
            f.cli('cmb-reset')
            if quota is not None:
                f.cli('cmb-quota', str(quota))
            account_before = state()['account']
            before = {key for peer in providers for key in peer.dialogs}
            before_invites = [len(item.invites) for item in providers]
            call = providers[0].call('sip:999100001@' + realm, inbound_destination,
                user=cmb['caller'], realm=realm, to_uri='sip:999100001@' + realm)
            assert call['code'] == 200
            f.wait(lambda: call['media'].get('ended'), 30)
            assert call['media']['received'] > 20, 'The incoming Nathaniel announcement had no RTP'
            peer, callid, media = f.wait(lambda: find_dialog('0820000001', before), 20)
            assert call['media'].get('ended'), 'Callback began before the original call ended'
            f.wait(lambda: media.get('acked') and media['received'] > 40, 10)
            wrapper = {'media': media, 'text': peer.sdp(media), 'callid': callid}
            if new_identity:
                index, _ = playback.prompt(callid, ['greeting.wav'])
                for digit in cmb['identity'] + '#':
                    peer.dtmf(wrapper, digit)
                index, _ = playback.prompt(callid, ['authenticated.wav'], after=index)
                index, _ = playback.prompt(callid, ['enter-number.wav'], after=index)
            else:
                index, _ = playback.prompt(callid, ['enter-number.wav'])
                with playback.lock:
                    assert not any(event.get('variable_sip_call_id') == callid and
                        event.get('Playback-File-Path', '').replace('\\', '/').endswith('/greeting.wav')
                        for event in playback.events), 'Saved caller unexpectedly needed identity authentication'
            f.wait(lambda: state()['request']['state'] == 'dialling', 5)
            for digit in cmb['destination'] + '#':
                peer.dtmf(wrapper, digit)
            target, target_id, target_media = f.wait(lambda: find_dialog(cmb['destination'], before), 15)
            connected = f.wait(lambda: (lambda value: value if value['request']['state'] == 'connected' else None)(state()), 6)
            limit = int(connected['request']['reserved_seconds'])
            assert 0 < limit <= 600 and limit == min(600, int(account_before['total_seconds']) - int(account_before['used_seconds']))
            started = time.monotonic()
            down, up = decoded(media, target_media, target.tone_hz, peer.tone_hz, 1.5 if quota is not None else 3)
            if quota is not None:
                f.wait(lambda: media.get('ended') and target_media.get('ended'), limit + 8)
                elapsed = time.monotonic() - started
                assert max(0, limit - 2) <= elapsed <= limit + 4, 'The native short user allowance cutoff was not respected'
            else:
                target.hangup_incoming(target_id)
                f.wait(lambda: media.get('ended'), 6)
                elapsed = None
            final = f.wait(lambda: (lambda value: value if value['request']['state'] in ('completed', 'failed') else None)(state()), 10)
            charged = int(final['request']['used_seconds'])
            assert final['request']['state'] == 'completed' and 0 < charged <= limit
            assert int(final['account']['reserved_seconds']) == 0 and final['bindings'] == 1
            assert int(final['account']['used_seconds']) - int(account_before['used_seconds']) == charged
            assert int(final['account']['total_seconds']) == int(account_before['total_seconds'])
            for expected, item, offset in zip(('0820000001', cmb['destination']), providers, before_invites):
                assert len({row['callid'] for row in item.invites[offset:] if row['number'] == expected}) == 1, 'A callback or destination was duplicated'
            f.record('native_cmb_' + ('sa_id_first_auth_decoded_bridge' if new_identity else
                'saved_caller_decoded_bridge' if quota is None else 'short_quota_native_cutoff_exact_usage'),
                identity_hmac_unchanged=True, persistent_binding_verified=True, no_plaintext_identity_in_facts=True,
                caller_decoded_ratio=down, destination_decoded_ratio=up, charged_seconds=charged,
                native_reserved_limit_seconds=limit, observed_short_cutoff_seconds=elapsed,
                reservation_released=True, total_allowance_unchanged=True,
                ten_minute_policy_ceiling_verified=True, actual_600_second_call=False, no_carrier_traffic=True)

        run(True)
        run(False)
        run(False, 4)
        f.cli('cmb-reset'); f.cli('cmb-quota', '0')
        before = {key for peer in providers for key in peer.dialogs}
        before_invites = [len(item.invites) for item in providers]
        call = providers[0].call('sip:999100001@' + realm, inbound_destination,
            user=cmb['caller'], realm=realm, to_uri='sip:999100001@' + realm)
        assert call['code'] == 200
        f.wait(lambda: call['media'].get('ended'), 30)
        peer, callid, media = f.wait(lambda: find_dialog('0820000001', before), 20)
        f.wait(lambda: media.get('ended'), 20)
        final = state()
        assert final['request']['last_result'] == 'quota_exhausted'
        assert int(final['account']['reserved_seconds']) == 0 and find_dialog(cmb['destination'], before) is None
        assert not any(row['number'] == cmb['destination'] for item, offset in zip(providers, before_invites) for row in item.invites[offset:]), 'An exhausted allowance attempted a destination call'
        f.record('native_cmb_exhausted_quota_no_destination', identity_hmac_unchanged=True,
                 no_destination_bridge=True, reservation_released=True,no_carrier_traffic=True)
        assert all(peer.register_requests == 0 for peer in providers), 'A fictional IP provider attempted registration'
    except BaseException as error:
        primary = error
        raise
    finally:
        if playback is not None:
            try:
                if hasattr(playback, 'thread'):
                    playback.close()
                    assert not playback.thread.is_alive(), 'The owned callback playback observer did not stop'
                elif hasattr(playback, 'socket'):
                    playback.stopped = True
                    playback.socket.close()
            except BaseException as error: cleanup_errors.append(error)
        for peer in providers:
            for call in list(peer.outgoing):
                if call.get('media') and not call['media'].get('ended'):
                    try: peer.hangup(call)
                    except BaseException as error: cleanup_errors.append(error)
            for callid, media in list(peer.dialogs.items()):
                if media.get('incoming') and not media.get('ended'):
                    try: peer.hangup_incoming(callid)
                    except BaseException as error: cleanup_errors.append(error)
            try: peer.close()
            except BaseException as error: cleanup_errors.append(error)
        if cleanup_errors:
            if primary is not None: primary.provider_cleanup_failed = True
            else: raise cleanup_errors[0]
