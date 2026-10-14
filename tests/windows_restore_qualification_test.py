#!/usr/bin/env python3
"""Offline evidence/refusal controls, not a claim of Windows qualification."""
import copy
import importlib.util
import json
from pathlib import Path
import shutil
import math
import struct
import subprocess
import tempfile
import unittest
from unittest import mock
import wave
from types import SimpleNamespace

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location('windows_restore_qualification', HERE / 'windows-restore-qualification.py')
q = importlib.util.module_from_spec(spec); spec.loader.exec_module(q)


class Controls(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(); self.root = Path(self.temporary.name)
        self.secret = 'Fictional-only-A9!' + 'a' * 40; self.key = q.derive(self.secret, 'capsule')
        self.archive = self.root / 'fixture.owpbx'; self.archive.write_bytes(b'OWPBXB01' + bytes(range(128)))
        self.binding = {'run_id': '123', 'source_commit': 'a' * 40, 'candidate_sha256': 'b' * 64,
                        'scope': 'c' * 24, 'service_name': 'Fictional cccccccccccccccccccccccc', 'base_suite_run_id': '122'}
        self.payload = {'schema': 1, **self.binding, 'cipher_bytes': self.archive.stat().st_size,
                        'cipher_sha256': q.digest(self.archive)}

    def tearDown(self): self.temporary.cleanup()
    def envelope(self, payload=None): return q.seal_capsule(payload or self.payload, self.key)
    def open(self, envelope=None, binding=None):
        return q.open_capsule(envelope or self.envelope(), self.key, binding or self.binding, self.archive)

    def test_authenticated_exact_ciphertext(self): self.assertEqual(self.open(), self.payload)
    def test_canonical_object_order(self):
        self.assertEqual(q.canonical({'b': 2, 'a': [1, True]}), q.canonical({'a': [1, True], 'b': 2}))
    def test_shared_key_labels_independent(self):
        self.assertNotEqual(q.derive(self.secret, 'audit'), self.key)
        self.assertNotEqual(q.derive(self.secret, 'administrator/source/x'), q.derive(self.secret, 'administrator/target/x'))
    def test_short_passphrase_refused(self):
        with self.assertRaises(ValueError): q.derive('short', 'capsule')
    def test_capsule_hmac_corruption_refused(self):
        envelope = self.envelope(); envelope['mac'] = '0' * 64
        with self.assertRaises(ValueError): self.open(envelope)
    def test_authenticated_other_run_refused(self):
        envelope = self.envelope(self.payload | {'run_id': '124'})
        with self.assertRaises(ValueError): self.open(envelope)
    def test_authenticated_other_package_refused(self):
        envelope = self.envelope(self.payload | {'candidate_sha256': 'd' * 64})
        with self.assertRaises(ValueError): self.open(envelope)
    def test_other_source_binding_refused(self):
        with self.assertRaises(ValueError): self.open(binding=self.binding | {'source_commit': 'd' * 40})
    def test_unexpected_envelope_field_refused(self):
        with self.assertRaises(ValueError): self.open(self.envelope() | {'logs': []})
    def test_nested_plaintext_secret_field_refused(self):
        for secret in ('password', 'passphrase', 'private_key', 'event_socket', 'users', 'admin_password', 'logs'):
            with self.subTest(secret=secret), self.assertRaises(ValueError):
                self.open(self.envelope(self.payload | {'nested': [{'nested': {secret: 'private'}}]}))
    def test_complete_cipher_corruption_refused(self):
        envelope = self.envelope(); self.archive.write_bytes(self.archive.read_bytes()[:-1] + b'x')
        with self.assertRaises(ValueError): self.open(envelope)
    def test_plaintext_archive_refused_even_authenticated(self):
        self.archive.write_bytes(b'NOTCRYPT' + b'x' * 128)
        payload = self.payload | {'cipher_sha256': q.digest(self.archive)}
        with self.assertRaises(ValueError): self.open(self.envelope(payload))
    def test_duplicate_evidence_keys_refused(self):
        path = self.root / 'data.json'; path.write_text('{"schema":1,"schema":2}')
        with self.assertRaises(ValueError): q.read_json(path)
    def test_bounded_evidence_and_nan_refused(self):
        path = self.root / 'data.json'; path.write_text('{"x":NaN}')
        with self.assertRaises(ValueError): q.read_json(path)
        path.write_text(' ' * 40)
        with self.assertRaises(ValueError): q.read_json(path, 16)
    def test_linked_cipher_refused(self):
        original = self.archive.with_suffix('.original'); self.archive.rename(original)
        try: self.archive.symlink_to(original)
        except OSError: self.skipTest('Symlink creation unavailable.')
        with self.assertRaises(ValueError): self.open()

    def identities(self):
        source = {'target_owned': {'cluster': 'a', 'database_credentials': 'b'}, 'machine_sid_hmac': 'c',
                  'certificate_sha256': 'd', 'template_key_sha256': 'e','hardware_uuid_hmac':'source-hardware',
                  'hostname_hmac':'source-host','runner_name_hmac':'source-runner','hosted_job_id':'12345'}
        target = {'target_owned': {'cluster': 'f', 'database_credentials': 'g'}, 'machine_sid_hmac': 'h',
                  'certificate_sha256': 'i', 'template_key_sha256': 'j','hardware_uuid_hmac':'target-hardware',
                  'hostname_hmac':'target-host','runner_name_hmac':'target-runner','hosted_job_id':'12346'}
        return source, target
    def test_different_machine_and_cluster_accepted(self): q.distinct_installations(*self.identities())
    def test_same_db_or_credentials_refused(self):
        for key in ('cluster', 'database_credentials'):
            source, target = self.identities(); target['target_owned'][key] = source['target_owned'][key]
            with self.subTest(key=key), self.assertRaises(ValueError): q.distinct_installations(source, target)
    def test_same_machine_or_private_material_refused(self):
        for key in ('hardware_uuid_hmac','hostname_hmac','certificate_sha256', 'template_key_sha256'):
            source, target = self.identities(); target[key] = source[key]
            with self.subTest(key=key), self.assertRaises(ValueError): q.distinct_installations(source, target)

    def test_same_image_sid_with_distinct_actual_vm_and_jobs_accepted(self):
        source,target=self.identities();target['machine_sid_hmac']=source['machine_sid_hmac']
        q.distinct_installations(source,target)
    def test_same_hardware_or_reforged_hosted_job_refused(self):
        for key in ('hardware_uuid_hmac','hosted_job_id'):
            source,target=self.identities();target[key]=source[key]
            with self.subTest(key=key),self.assertRaises(ValueError):q.distinct_installations(source,target)
        payload=self.payload|{'hosted_job_id':'12346'}
        with self.assertRaises(ValueError):self.open(self.envelope(payload),self.binding|{'hosted_job_id':'12345'})
    def test_actual_target_sid_and_machine_evidence_preserved(self):
        _,target=self.identities();q.preserve_machine_identity(target,copy.deepcopy(target))
        for key in ('machine_sid_hmac','hardware_uuid_hmac','hostname_hmac','runner_name_hmac','hosted_job_id'):
            altered=copy.deepcopy(target);altered[key]='changed'
            with self.subTest(key=key),self.assertRaises(ValueError):q.preserve_machine_identity(altered,target)

    def snapshot(self):
        tables = {'v_extensions': {'rows': 2, 'hmac': 'exact-credentials'}, 'v_pbx_jobs': {'rows': 1, 'hmac': 'future'},
                  'v_pbx_backup_status': {'rows': 1, 'hmac': 'heartbeat'}}
        return {'target_owned': {'cluster': 'exact'}, 'schema_metadata': {'columns': 'exact-defaults'},
                'all_table_values': tables, 'scoped_values': copy.deepcopy(tables),
                'restore_projections': {table:{'rows':0,'hmac':'exact'} for table in q.RESTORE_TRANSFORMED_TABLES},
                'source_phone_tuples': 'actual-native-tuples'}
    def test_exact_factory_and_restored_snapshots(self):
        before = self.snapshot(); q.compare_snapshots(before, copy.deepcopy(before), 'factory-recovery')
        after = copy.deepcopy(before); after['target_owned']['cluster'] = 'different-target'
        q.compare_snapshots(before, after, 'source-restored')
    def test_operational_heartbeat_only_allowed(self):
        before = self.snapshot(); after = copy.deepcopy(before)
        after['all_table_values']['v_pbx_backup_status']['hmac'] = 'new-heartbeat'
        q.compare_snapshots(before, after, 'factory-recovery')
    def test_credential_job_or_schema_changes_refused(self):
        for key in ('v_extensions', 'v_pbx_jobs'):
            before = self.snapshot(); after = copy.deepcopy(before)
            after['all_table_values'][key]['hmac'] = 'changed'
            with self.subTest(key=key), self.assertRaises(ValueError): q.compare_snapshots(before, after, 'source-restored')
        before = self.snapshot(); after = copy.deepcopy(before); after['schema_metadata']['columns'] = 'changed'
        with self.assertRaises(ValueError): q.compare_snapshots(before, after, 'factory-recovery')
    def test_factory_identity_and_actual_phone_changes_refused(self):
        before = self.snapshot(); after = copy.deepcopy(before); after['target_owned']['cluster'] = 'changed'
        with self.assertRaises(ValueError): q.compare_snapshots(before, after, 'factory-recovery')
        after = copy.deepcopy(before); after['source_phone_tuples'] = 'changed'
        with self.assertRaises(ValueError): q.compare_snapshots(before, after, 'source-restored')

    def test_unscoped_smtp_profiles_defaults_admin_memberships_refused(self):
        for table in ('v_smtp_settings','v_default_settings','v_sip_profile_settings','v_user_groups'):
            before=self.snapshot();before['all_table_values'][table]={'rows':1,'hmac':'original-global'}
            after=copy.deepcopy(before);after['all_table_values'][table]['hmac']='changed-global'
            with self.subTest(table=table),self.assertRaises(ValueError):q.compare_snapshots(before,after,'source-restored')

    def test_factory_backup_settings_secret_changes_refused(self):
        before=self.snapshot();before['all_table_values']['v_pbx_backup_settings']={'rows':1,'hmac':'original-secret-settings'}
        after=copy.deepcopy(before);after['all_table_values']['v_pbx_backup_settings']['hmac']='changed-password'
        with self.assertRaises(ValueError):q.compare_snapshots(before,after,'factory-recovery')

    def test_restore_only_explicit_lifecycle_fields_may_change(self):
        before=self.snapshot();before['all_table_values']['v_pbx_backup_settings']={'rows':1,'hmac':'enabled-source'}
        after=copy.deepcopy(before);after['all_table_values']['v_pbx_backup_settings']['hmac']='disabled-target'
        q.compare_snapshots(before,after,'source-restored')
        for table in q.RESTORE_TRANSFORMED_TABLES:
            changed=copy.deepcopy(after);changed['restore_projections'][table]['hmac']='changed-secret-or-identity'
            with self.subTest(table=table),self.assertRaises(ValueError):q.compare_snapshots(before,changed,'source-restored')

    def test_real_cli_adapter_keeps_password_out_of_arguments_and_restores_prompt(self):
        fixture=q.Qualification.__new__(q.Qualification);fixture.work=self.root;fixture.facts={}
        old_prompt=lambda _: 'untouched';prompt=SimpleNamespace(getpass=old_prompt);observed={}
        def main():
            observed['args']=q.sys.argv[:];observed['passphrase']=prompt.getpass('Original backup password: ')
        fixture.backups=SimpleNamespace(getpass=prompt,main=main)
        before=q.sys.argv
        fixture.cli(['restore','fixture.owpbx','--confirm-database','fusionpbx'],password=self.secret)
        self.assertNotIn(self.secret,observed['args']);self.assertEqual(observed['passphrase'],self.secret)
        self.assertIs(q.sys.argv,before);self.assertIs(prompt.getpass,old_prompt)
        self.assertEqual(fixture.facts['actual_console_keyboard_input'],'unqualified')

    def test_late_fault_actual_three_copies_then_recovery_continues(self):
        targets = {'key': self.root / 'openweb-template.key', 'notification': self.root / 'notification.json',
                   'media': self.root / 'media/source.wav'}; targets['media'].parent.mkdir()
        sources = {}
        for key in targets:
            source = self.root / (key + '.source'); source.write_bytes(('real ' + key).encode()); sources[key] = source
        witness = {}; copy_file = q.late_copy_fault(shutil.copyfile, targets['key'], targets['notification'],
                                                   [targets['media'].parent], witness)
        copy_file(sources['key'], targets['key']); self.assertFalse(witness['injected'])
        copy_file(sources['notification'], targets['notification']); self.assertFalse(witness['injected'])
        with self.assertRaises(RuntimeError): copy_file(sources['media'], targets['media'])
        self.assertTrue(witness['injected']); self.assertEqual(witness['categories'], ['key', 'media', 'notification'])
        self.assertEqual(targets['media'].read_bytes(), sources['media'].read_bytes())
        recovered = self.root / 'recovered.source'; recovered.write_bytes(b'original factory')
        copy_file(recovered, targets['key']); self.assertEqual(targets['key'].read_bytes(), b'original factory')
    def test_first_or_incomplete_categories_never_qualify_late(self):
        key = self.root / 'key'; notification = self.root / 'noti'; media = self.root / 'media'; media.mkdir()
        source = self.root / 'source'; source.write_bytes(b'real')
        witness = {}; copy_file = q.late_copy_fault(shutil.copyfile, key, notification, [media], witness)
        for target in (key, key, self.root / 'unrelated', notification): copy_file(source, target)
        self.assertFalse(witness['injected']); self.assertNotIn('media', witness['categories'])
    def test_copy_failure_is_not_false_success(self):
        witness = {}
        def broken(source, target): raise OSError('actual copy failed')
        copy_file = q.late_copy_fault(broken, self.root/'key', self.root/'noti', [self.root/'media'], witness)
        with self.assertRaises(OSError): copy_file(self.root/'missing', self.root/'key')
        self.assertEqual(witness['copied'], []); self.assertFalse(witness['injected'])

    def test_late_exact_native_media_neighbours_do_not_satisfy_witness(self):
        key, noti = self.root/'key', self.root/'noti'; media = self.root/'media'; media.mkdir()
        selected, neighbour = media/'answered.wav', media/'deposit.wav'
        source = self.root/'source'; source.write_bytes(b'complete actual native fixture')
        witness = {}; copy_file = q.late_copy_fault(shutil.copyfile, key, noti, [media], witness, media_paths=[selected])
        for target in (key, noti, neighbour): copy_file(source, target)
        self.assertFalse(witness['injected']); self.assertEqual(witness['categories'], ['key', 'notification'])
        with self.assertRaises(RuntimeError): copy_file(source, selected)
        self.assertTrue(witness['injected']); self.assertEqual(selected.read_bytes(), source.read_bytes())

    def test_media_selects_captured_answered_uuid_not_deposit_uuid_order(self):
        storage = self.root/'storage'; storage.mkdir()
        def wav_file(name, frequencies):
            path = storage/name; raw = bytearray()
            for i in range(8000*5):
                for frequency in frequencies: raw.extend(struct.pack('<h', int(12000*math.sin(2*math.pi*frequency*i/8000))))
            with wave.open(str(path), 'wb') as stream:
                stream.setparams((len(frequencies), 2, 8000, 0, 'NONE', 'not compressed')); stream.writeframes(raw)
            return {'exists': True, 'path': str(path), 'size': path.stat().st_size, 'sha256': q.digest(path)}
        vm = wav_file('message.wav', [440]); answered = wav_file('answered.wav', [440, 550]); deposit = wav_file('deposit.wav', [440, 220])
        fixture = q.Qualification.__new__(q.Qualification); fixture.s = {'answered_recording_uuid': 'ffff'}; fixture.work = self.root
        fixture.php = lambda action: {'voicemail': [{'voicemail_id': '8101', 'media': vm}],
            'recordings': [{'media_uuid': 'aaaa', 'media': deposit}, {'media_uuid': 'ffff', 'media': answered}]}
        fixture.record = lambda _: None
        actual_path = Path
        with mock.patch.object(q, 'Path', side_effect=lambda value: storage if str(value) == 'C:/ProgramData/OpenWebPBX/storage' else actual_path(value)):
            result = fixture.media()
        self.assertEqual(result['recording']['relative'], 'answered.wav')
        self.assertGreater(min(result['recording']['decoded_ratios']), .99)

    def test_workflow_distinct_jobs_cipher_only_and_no_reboot(self):
        workflow = (HERE.parent / '.github/workflows/windows-restore-qualification.yml').read_text()
        self.assertEqual(workflow.count('runs-on: windows-2025'), 2)
        self.assertIn('needs: source', workflow); self.assertIn('/fixture.owpbx', workflow); self.assertIn('/capsule.json', workflow)
        self.assertNotIn('windows113/', workflow); self.assertNotIn('SIGNING', workflow)
        self.assertNotIn('Restart-Computer', (HERE/'windows-restore-qualification.ps1').read_text())


if __name__ == '__main__': unittest.main()
