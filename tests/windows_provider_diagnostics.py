"""Closed, read-only facts about the two owned fictional Windows providers."""
import re


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
