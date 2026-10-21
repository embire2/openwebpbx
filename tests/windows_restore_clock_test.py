"""Actual restored-clock evidence/action boundaries; no PBX or network used."""
import copy
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from types import SimpleNamespace
from unittest import mock

spec=importlib.util.spec_from_file_location('restored_clock_action',Path(__file__).with_name('windows-restore-qualification.py'))
q=importlib.util.module_from_spec(spec);spec.loader.exec_module(q)


def proof():
    return dict(sourcebindings_verified=True,frozen_Nathaniel_assets=34,complete_announcements=3,
        GMT_plus_2_full_time_verified=True,minimum_component_correlation=.9,
        maximum_native_signal_lateness_ms=15,maximum_decoded_beep_target_error_ms=25.5,
        original_phone_media_restored=True,owned_clock_call_ended=True,scoped_observer_stopped=True,
        software_phone_only=True,no_carrier_calls_or_database_configuration_writes=True)


class ClockEvidence(unittest.TestCase):
    def test_complete_source_bound_audio_summary(self):
        value=proof();self.assertEqual(q.restored_clock_summary(value),value)

    def test_incomplete_private_and_nonfinite_fields_refuse(self):
        for field,original in proof().items():
            for bad in (None,'PRIVATE_NEVER_PUBLISH'):
                value=proof();value[field]=bad
                with self.assertRaises(ValueError):q.restored_clock_summary(value)
            if type(original) is bool:
                value=proof();value[field]=False
                with self.assertRaises(ValueError):q.restored_clock_summary(value)
        for field,values in {
            'frozen_Nathaniel_assets':(True,33,35),'complete_announcements':(True,2,4),
            'minimum_component_correlation':(True,.619,1.001,float('nan'),float('inf')),
            'maximum_native_signal_lateness_ms':(True,-1,250,float('nan')),
            'maximum_decoded_beep_target_error_ms':(True,-1,350,float('inf'))}.items():
            for bad in values:
                value=proof();value[field]=bad
                with self.assertRaises(ValueError):q.restored_clock_summary(value)
        value=proof();value['raw_events']='PRIVATE_NEVER_PUBLISH'
        with self.assertRaises(ValueError):q.restored_clock_summary(value)


class ClockAction(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory();self.addCleanup(self.temp.cleanup)
        self.fixture=q.Qualification.__new__(q.Qualification);f=self.fixture
        f.source=Path(self.temp.name);f.work=f.source;f.facts_path=f.work/'facts.json'
        f.s=dict(role='target',realm='owned.example.invalid',domain='00000000-0000-4000-8000-000000000001',event_socket={})
        f.facts={'checks':['restored_original_native_voicemail_121_pin_free_retrieval'],
                 'gates':{'restored_original_native_voicemail_121_pin_free_retrieval':'passed'}}
        self.original=object();self.peers=[mock.Mock(registration_call_ids=['a'*24+'@localfixture']),mock.Mock(registration_call_ids=['b'*24+'@localfixture'])]
        for peer in self.peers:peer.register.return_value={'code':200}
        f.peers=mock.Mock(return_value=(None,self.original,self.peers,('127.0.0.1',5060)))
        f.clean_peers=mock.Mock();self.adapter=mock.Mock();self.adapter.qualify_clock.return_value=proof()
        self.loader=mock.patch.object(q,'load_module',return_value=self.adapter);self.loader.start();self.addCleanup(self.loader.stop)

    def test_original_accounts_scoped_adapter_and_cleanup(self):
        old=copy.deepcopy(self.fixture.s);self.fixture.clock_target()
        self.assertEqual(self.fixture.s,old);self.fixture.clean_peers.assert_called_once_with(self.peers,('127.0.0.1',5060))
        args=self.adapter.qualify_clock.call_args.args
        self.assertIs(args[0],self.peers[0]);self.assertIs(args[1],self.original)
        self.assertEqual(args[2]['sip_destination'],('127.0.0.1',5060))
        self.assertEqual(args[-1],self.fixture.work/'clock-target-native')
        self.assertEqual(self.fixture.facts['clock_native'],proof())
        self.assertEqual(self.fixture.facts['gates']['restored_original_native_clock_1026_Nathaniel_GMT2_audio'],'passed')
        ledger=json.loads((self.fixture.work/'clock-registration-cleanup-private.json').read_text())
        self.assertEqual(ledger['ids'],['a'*24+'@localfixture','b'*24+'@localfixture'])

    def test_source_unproved_and_duplicate_target_refuse_before_sockets(self):
        for edit in ('source','unproved','duplicate'):
            f=self.fixture
            f.s['role']='source' if edit=='source' else 'target'
            f.facts['gates']['restored_original_native_voicemail_121_pin_free_retrieval']='unqualified' if edit=='unproved' else 'passed'
            f.facts['checks']=['restored_original_native_clock_1026_Nathaniel_GMT2_audio'] if edit=='duplicate' else []
            with self.assertRaises(RuntimeError):f.clock_target()
            f.peers.assert_not_called()

    def test_analysis_failure_preserves_original_and_still_cleans(self):
        primary=AssertionError('PRIVATE_NEVER_PUBLISH');primary.clock_phase='analyze'
        self.adapter.qualify_clock.side_effect=primary
        cleanup=RuntimeError('PRIVATE_NEVER_PUBLISH');cleanup.peer_cleanup_failure=[]
        self.fixture.clean_peers.side_effect=cleanup
        with self.assertRaises(AssertionError) as caught:self.fixture.clock_target()
        self.assertIs(caught.exception,primary);self.fixture.clean_peers.assert_called_once()
        self.assertNotIn('clock_native',self.fixture.facts)

    def test_bad_summary_never_becomes_a_gate(self):
        value=proof();value['minimum_component_correlation']=.1;self.adapter.qualify_clock.return_value=value
        with self.assertRaises(ValueError):self.fixture.clock_target()
        self.fixture.clean_peers.assert_called_once()
        self.assertNotIn('restored_original_native_clock_1026_Nathaniel_GMT2_audio',self.fixture.facts['gates'])


if __name__=='__main__':unittest.main()
