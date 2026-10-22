"""Exercise closed native-provider projections without PBX or carrier traffic."""
import importlib.util
import json
from pathlib import Path
from types import SimpleNamespace
import unittest
from copy import deepcopy

spec = importlib.util.spec_from_file_location('provider_projection', Path(__file__).with_name('windows_provider_diagnostics.py'))
projection = importlib.util.module_from_spec(spec)
spec.loader.exec_module(projection)


class Projections(unittest.TestCase):
    def observation(self):
        return {'schema':1,'attempts':[{'observed':True,'count':1,'counts_capped':False,
            'state':'failed','cause':'INCOMPATIBLE_DESTINATION','sip_status':488,'will_retry':True,
            'password':'PRIVATE'}]*2,'plan':{'observed':True,'registered':True,'rule_matches':True,
            'routes_count':2,'primary_available':False,'backup_available':False,'selected_index':-1,'error':'providers_unavailable'},
            'runtime':[{'enabled_kind':'string','enabled_value':'t','register_kind':'string','register_value':'f',
                'available':True,'rewrite_valid':True,'leg_valid':False,'options_present':True,'options_kind':'table',
                'options_schema_one':True,'policy_source_forwardslash':True,'options_module_readable':False}]*2}

    def test_closed_attempts_and_actual_runtime_plan(self):
        value=projection.closed_observations(self.observation(),'after')
        self.assertEqual(value['provider_after_primary_attempt_cause'],'INCOMPATIBLE_DESTINATION')
        self.assertEqual(value['provider_after_plan_error'],'providers_unavailable')
        self.assertTrue(value['provider_after_primary_policy_available'])
        self.assertFalse(value['provider_after_primary_policy_leg_valid'])
        self.assertNotIn('PRIVATE',json.dumps(value))

    def test_closed_observation_type_and_enum_refusals(self):
        for field,bad in [('cause','PRIVATE'),('state','PRIVATE'),('count','1'),('sip_status',True),('will_retry','true')]:
            row=deepcopy(self.observation());row['attempts'][0][field]=bad
            self.assertNotIn('provider_before_primary_attempt_'+field,projection.closed_observations(row,'before'))
        for field,bad in [('error','PRIVATE'),('selected_index',True),('routes_count','2'),('registered',1)]:
            row=deepcopy(self.observation());row['plan'][field]=bad
            self.assertNotIn('provider_before_plan_'+field,projection.closed_observations(row,'before'))
        for field,bad in [('enabled_kind','PRIVATE'),('enabled_value','PRIVATE'),('leg_valid','false')]:
            row=deepcopy(self.observation());row['runtime'][0][field]=bad
            self.assertNotIn('provider_before_primary_policy_'+field,projection.closed_observations(row,'before'))
    def peer(self, sdp='m=audio 20000 RTP/AVP 0 8 101\r\n', **extra):
        return SimpleNamespace(invites=[{'sdp': sdp, 'callid': 'PRIVATE_CALL_ID', 'headers': {'password': 'PRIVATE_PASSWORD'}}],
            sent_codes=[('PRIVATE_CALL_ID', 488)], receiver_failure=None,
            thread=SimpleNamespace(is_alive=lambda: True), **extra)

    def fixture(self):
        return SimpleNamespace(s={'providers': [{'gateway': '01234567-89ab-cdef-0123-456789abcdef'}] * 2},
            cli=lambda *a, **kw: 'Name PRIVATE_NAME\nState NOREG\nStatus UP\nPassword PRIVATE_PASSWORD\n')

    def test_exact_offer_and_gateway(self):
        result = projection.snapshot(self.fixture(), [self.peer(), self.peer('m=audio 20000 RTP/AVP 0\r\n')], [0, 0], 'after')
        self.assertTrue(result['provider_after_primary_gateway_observed'])
        self.assertEqual(result['provider_after_primary_gateway_status'], 'UP')
        self.assertTrue(result['provider_after_primary_offer_pcma'])
        self.assertFalse(result['provider_after_backup_offer_pcma'])
        self.assertEqual(result['provider_after_primary_last_response_code'], 488)
        self.assertNotIn('PRIVATE', json.dumps(result))

    def test_missing_and_malformed_offers(self):
        for sdp in ('', 'm=audio 1 RTP/AVP 128\r\n', 'm=audio 1 RTP/AVP 8 SECRET\r\n',
                    'm=audio 1 RTP/AVP 8\r\nm=audio 2 RTP/AVP 0\r\n', 'x' * 65537):
            result = projection.snapshot(self.fixture(), [self.peer(sdp)] * 2, [0, 0], 'after')
            self.assertFalse(result['provider_after_primary_offer_parsed'])
            self.assertFalse(result['provider_after_primary_offer_pcma'])

    def test_no_invite_is_not_missing_codec(self):
        result = projection.snapshot(self.fixture(), [self.peer()] * 2, [1, 1], 'after')
        self.assertEqual(result['provider_after_primary_invites'], 0)
        self.assertFalse(result['provider_after_primary_offer_parsed'])
        self.assertEqual(result['provider_after_primary_last_response_code'], 0)

    def test_query_failures_do_not_replace_call_failure(self):
        f = self.fixture()
        def fail(*a, **kw):
            raise RuntimeError('PRIVATE_ERROR')
        f.cli = fail
        result = projection.snapshot(f, [self.peer()] * 2, [0, 0], 'before')
        self.assertFalse(result['provider_before_primary_gateway_observed'])
        self.assertEqual(result['provider_before_primary_gateway_status'], 'unknown')
        self.assertNotIn('PRIVATE', json.dumps(result))

    def test_duplicate_or_oversized_gateway(self):
        for text in ('Status UP\nStatus DOWN\nState NOREG\n', 'x' * 65537, None, True):
            self.assertFalse(projection.gateway_state(text)['observed'])

    def test_capped_wire_ledger(self):
        peer = self.peer()
        peer.invites *= 65
        result = projection.snapshot(self.fixture(), [peer] * 2, [0, 0], 'after')
        self.assertTrue(result['provider_after_primary_counts_capped'])
        self.assertEqual(result['provider_after_primary_invites'], 64)
        self.assertFalse(result['provider_after_primary_offer_parsed'])

    def test_only_valid_response_code_is_attached(self):
        for code in ('488', True, 0, 700, None):
            e = AssertionError('PRIVATE_ERROR')
            projection.attach(e, {'provider_after_primary_invites': 0}, {'code': code, 'text': 'PRIVATE_SIP'})
            self.assertNotIn('provider_caller_response_code', e.provider_failure)
            self.assertNotIn('PRIVATE', json.dumps(e.provider_failure))
        e = AssertionError()
        projection.attach(e, {}, {'code': 488})
        self.assertEqual(e.provider_failure, {'provider_caller_response_code': 488})


if __name__ == '__main__':
    unittest.main()
