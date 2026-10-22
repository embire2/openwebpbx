"""Closed, read-only facts about the two owned fictional Windows providers."""
import re

ATTEMPT_CAUSES = ('none', 'other', 'PROVIDER_UNAVAILABLE', 'SUCCESS', 'NORMAL_CLEARING',
    'NORMAL_TEMPORARY_FAILURE', 'INCOMPATIBLE_DESTINATION', 'SERVICE_UNAVAILABLE',
    'DESTINATION_OUT_OF_ORDER', 'INVALID_GATEWAY', 'GATEWAY_DOWN', 'CHAN_NOT_IMPLEMENTED',
    'MANDATORY_IE_MISSING', 'INVALID_IE_CONTENTS', 'NO_ROUTE_DESTINATION', 'CALL_REJECTED',
    'ORIGINATOR_CANCEL', 'NO_USER_RESPONSE', 'NO_ANSWER', 'NORMAL_CIRCUIT_CONGESTION',
    'USER_BUSY', 'LOSE_RACE', 'ALLOTTED_TIMEOUT', 'RECOVERY_ON_TIMER_EXPIRE',
    'WRONG_CALL_STATE', 'UNALLOCATED_NUMBER', 'NETWORK_OUT_OF_ORDER', 'SWITCH_CONGESTION',
    'RESOURCE_UNAVAILABLE', 'CRASH', 'UNKNOWN')


def closed_observations(value, phase):
    assert phase in ('before', 'after')
    safe = {}
    if not isinstance(value, dict) or type(value.get('schema')) is not int or value['schema'] != 1:
        return safe
    rows = value.get('attempts')
    if isinstance(rows, list) and len(rows) == 2:
        for peer, row in zip(('primary', 'backup'), rows):
            if not isinstance(row, dict):
                continue
            prefix = 'provider_' + phase + '_' + peer + '_attempt_'
            for key in ('observed', 'counts_capped', 'will_retry'):
                if type(row.get(key)) is bool:
                    safe[prefix + key] = row[key]
            count = row.get('count')
            if type(count) is int and 0 <= count <= 16:
                safe[prefix + 'count'] = count
            code = row.get('sip_status')
            if type(code) is int and (code == 0 or 100 <= code <= 699):
                safe[prefix + 'sip_status'] = code
            for key, choices in (('state', ('absent', 'calling', 'skipped', 'answered', 'failed', 'cancelled', 'unknown')),
                                 ('cause', ATTEMPT_CAUSES)):
                if isinstance(row.get(key), str) and row[key] in choices:
                    safe[prefix + key] = row[key]
    plan = value.get('plan')
    if isinstance(plan, dict):
        prefix = 'provider_' + phase + '_plan_'
        for key in ('observed', 'registered', 'rule_matches', 'primary_available', 'backup_available'):
            if type(plan.get(key)) is bool:
                safe[prefix + key] = plan[key]
        for key, low, high in (('routes_count', 0, 16), ('selected_index', -1, 1)):
            if type(plan.get(key)) is int and low <= plan[key] <= high:
                safe[prefix + key] = plan[key]
        if plan.get('error') in ('none', 'other', 'no_rule', 'providers_unavailable', 'phone_unavailable'):
            safe[prefix + 'error'] = plan['error']
    runtime = value.get('runtime')
    if isinstance(runtime, list) and len(runtime) == 2:
        for peer, row in zip(('primary', 'backup'), runtime):
            if not isinstance(row, dict):
                continue
            prefix = 'provider_' + phase + '_' + peer + '_policy_'
            for key in ('available', 'rewrite_valid', 'leg_valid', 'options_present',
                        'options_schema_one', 'policy_source_forwardslash', 'options_module_readable'):
                if type(row.get(key)) is bool:
                    safe[prefix + key] = row[key]
            for key in ('enabled_kind', 'register_kind', 'options_kind'):
                if row.get(key) in ('nil', 'boolean', 'string', 'number', 'table', 'function', 'userdata', 'thread'):
                    safe[prefix + key] = row[key]
            for key in ('enabled_value', 'register_value'):
                if row.get(key) in ('true', 'false', 't', 'f', '1', '0', 'other'):
                    safe[prefix + key] = row[key]
    return safe


def gateway_state(text):
    """Never return hostnames, UUIDs, credentials, raw responses or SIP headers."""
    if not isinstance(text, str) or len(text) > 65536:
        return {'observed': False, 'status': 'unknown', 'state': 'unknown'}
    status = re.findall(r'^Status\s+(UP|DOWN)\s*$', text, re.M)
    state = re.findall(r'^State\s+(NOREG|REGED|UNREGED|TRYING|REGISTER|UNREGISTER|FAIL_WAIT|FAILED|EXPIRED)\s*$', text, re.M)
    return {'observed': len(status) == len(state) == 1,
            'status': status[0] if len(status) == 1 else 'unknown',
            'state': state[0] if len(state) == 1 else 'unknown'}


def snapshot(f, providers, offsets, phase):
    assert phase in ('before', 'after') and len(providers) == len(offsets) == 2
    facts = {}
    number = re.fullmatch(r'native_provider_(10[0-3])', getattr(f, 'active_case', ''))
    if number:
        try:
            facts.update(closed_observations(f.cli('provider-observations', '99' + number[1]), phase))
        except Exception:
            facts['provider_' + phase + '_plan_observed'] = False
    for index, (peer, offset) in enumerate(zip(providers, offsets)):
        prefix = 'provider_' + phase + '_' + ('primary' if index == 0 else 'backup') + '_'
        facts[prefix + 'gateway_observed'] = False
        facts[prefix + 'gateway_status'] = facts[prefix + 'gateway_state'] = 'unknown'
        try:
            gateway = f.s['providers'][index]['gateway']
            assert isinstance(gateway, str) and re.fullmatch(r'[a-f0-9]{8}(?:-[a-f0-9]{4}){3}-[a-f0-9]{12}', gateway)
            state = gateway_state(f.cli('api', 'sofia status gateway ' + gateway, json_result=False))
            facts.update({prefix + 'gateway_' + name: value for name, value in state.items()})
        except (Exception, AssertionError):
            pass  # The original call failure remains primary; absence is explicit.
        rows = list(peer.invites[offset:])
        facts[prefix + 'counts_capped'] = len(rows) > 64
        facts[prefix + 'invites'] = min(len(rows), 64)
        facts[prefix + 'distinct_calls'] = min(len({row.get('callid') for row in rows[:64]}), 64)
        valid, pcmu, pcma = bool(rows), False, False
        for row in rows[:64]:
            text = row.get('sdp')
            offers = re.findall(r'^m=audio [0-9]{1,5} RTP/(?:AVP|SAVP) ([0-9 ]+)\r?$', text, re.M) if isinstance(text, str) and len(text) <= 65536 else []
            payloads = offers[0].split() if len(offers) == 1 else []
            good = bool(payloads) and len(payloads) <= 128 and all(len(value) <= 3 and 0 <= int(value) <= 127 for value in payloads)
            valid = valid and good
            pcmu = pcmu or good and '0' in payloads
            pcma = pcma or good and '8' in payloads
        facts[prefix + 'offer_parsed'] = valid and not facts[prefix + 'counts_capped']
        facts[prefix + 'offer_pcmu'] = bool(pcmu)
        facts[prefix + 'offer_pcma'] = bool(pcma)
        facts[prefix + 'receiver_failed'] = peer.receiver_failure is not None
        facts[prefix + 'receiver_alive'] = peer.thread.is_alive()
        calls = {row.get('callid') for row in rows[:64]}
        responses = [code for callid, code in peer.sent_codes if callid in calls and type(code) is int and 100 <= code <= 699]
        facts[prefix + 'last_response_code'] = responses[-1] if responses else 0
    return facts


def attach(error, facts, call):
    closed = dict(facts)
    code = call.get('code') if isinstance(call, dict) else None
    if type(code) is int and 100 <= code <= 699:
        closed['provider_caller_response_code'] = code
    error.provider_failure = closed
