#!/usr/bin/env python3
"""Synthetic canary provenance/package guards; no Windows execution or signing.

Tiny fictional native files and mocked read-only git blobs exercise refusal and
diff boundaries. They do not qualify a DLL version, install, worker or rollback.
"""
import copy
import hashlib
import importlib.util
import json
from pathlib import Path
import stat
import tempfile
import unittest
from unittest import mock
import zipfile

spec = importlib.util.spec_from_file_location('canary', Path(__file__).with_name('windows-canary-preparation.py'))
p = importlib.util.module_from_spec(spec)
spec.loader.exec_module(p)


class CanaryPreparation(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.base = self.root / 'base.zip'
        self.facts_path = self.root / 'facts.json'
        self.native = self.root / 'native'
        self.native.mkdir()
        self.output = self.root / 'output'
        self.commit = '1' * 40
        self.sources = {
            'VERSION': b'1.0.13\n',
            'platform/Directory.Build.props': b'<Project><PropertyGroup><Version>1.0.13</Version></PropertyGroup></Project>\n',
            'packaging/updates/release-public.pem': b'-----BEGIN PUBLIC KEY-----\npublic synthetic fixture\n',
            **{f'platform/Synthetic{i}.cs': f'// synthetic source {i}\n'.encode() for i in range(40)},
        }
        self.files = {
            'VERSION': b'1.0.13\n', 'web/VERSION': b'1.0.13\n',
            'README.txt': b'OpenWeb PBX 1.0.13\n\nStart with docs/installing-1.0.13.md.\n',
            'web/index.php': b'unchanged synthetic public app',
            'web/flags/Cocos (Keeling) Islands.png': b'public synthetic flag',
            'codec-source/tests/public-example.key': b'public upstream synthetic example',
            'engine/mod/mod_sofia.dll': b'unchanged public synthetic registrar',
            'Install-MailQueue.ps1': b'# synthetic ordinary mail installation\n',
        }
        for part in p.NATIVE_TREES:
            label = {'server': 'Server', 'desktop': 'Desktop', 'updater': 'Updater'}[part]
            self.files[f'{part}/OpenWebPbx.{label}.dll'] = b'fictional original native file13'
            self.files[f'{part}/OpenWebPbx.{label}.exe'] = b'fictional original apphost13'
            self.files[f'{part}/original-only.txt'] = b'old source-specific output'
        self.archive()
        self.facts = {
            'schema': 1, 'state': 'partial', 'source_commit': self.commit,
            'gates': {gate: 'passed' for gate in p.ESSENTIAL_GATES} | {'outside_acme': 'unqualified'},
            'artifacts': {'candidate_sha256': p.digest(self.base)},
        }
        self.inputs = {
            'version': '1.0.14', 'source_commit': self.commit,
            'source_inputs': [{'path': name, 'sha256': hashlib.sha256(data).hexdigest()}
                              for name, data in sorted(self.sources.items())],
            'overlays': [],
        }
        for name in sorted(p.OVERLAYS):
            data = self.sources[name].replace(b'1.0.13', b'1.0.14')
            self.native_file('overlays/' + name, data)
            self.inputs['overlays'].append({'path': name, 'original_sha256': hashlib.sha256(self.sources[name]).hexdigest(),
                                            'sha256': hashlib.sha256(data).hexdigest()})
        assemblies = []
        for part in sorted(p.NATIVE_TREES):
            label = {'server': 'Server', 'desktop': 'Desktop', 'updater': 'Updater'}[part]
            dll = f'{part}/OpenWebPbx.{label}.dll'
            self.native_file(dll, b'fictional target native file14; not an actual DLL')
            self.native_file(f'{part}/OpenWebPbx.{label}.exe', b'fictional target apphost14')
            self.native_file(f'{part}/new-only.txt', b'new fictional source-specific output')
            assemblies.append({'path': dll, 'assembly_version': '1.0.14.0', 'sha256': p.digest(self.native / dll)})
        self.verification = {'version': '1.0.14', 'assemblies': assemblies,
                             'manager_startup': {'window_verified': False, 'limitation': 'Synthetic test; never executed Windows.'}}
        self.refresh()
        self.git = mock.patch.object(p, 'git_run', side_effect=self.git_read)
        self.git.start()
        self.addCleanup(self.git.stop)

    def git_read(self, _repository, *args):
        if args == ('rev-parse', '--verify', self.commit + '^{commit}'):
            return (self.commit + '\n').encode()
        if args == ('ls-tree', '-r', '--name-only', self.commit, '--', 'platform', 'packaging/updates/release-public.pem', 'VERSION'):
            return ('\n'.join(sorted(self.sources)) + '\n').encode()
        if len(args) == 2 and args[0] == 'show' and args[1].startswith(self.commit + ':'):
            return self.sources[args[1][len(self.commit) + 1:]]
        raise AssertionError('An unexpected or mutable git source was requested.')

    def native_file(self, name, data):
        path = self.native / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)

    def archive(self, extra=None):
        files = self.files | (extra or {})
        with zipfile.ZipFile(self.base, 'w') as archive:
            prefix = 'openwebpbx-1.0.13-windows-x64/'
            archive.writestr(prefix + 'release-manifest.json', json.dumps({'version': '1.0.13', 'files': {
                name: hashlib.sha256(data).hexdigest() for name, data in files.items()}}))
            for name, data in files.items():
                archive.writestr(prefix + name, data)

    def refresh(self):
        self.facts_path.write_text(json.dumps(self.facts))
        (self.native / 'source-inputs.json').write_text(json.dumps(self.inputs))
        (self.native / 'verification.json').write_text(json.dumps(self.verification))
        self.checksums()

    def checksums(self):
        lines = [p.digest(path) + '  ' + path.relative_to(self.native).as_posix()
                 for path in sorted(self.native.rglob('*')) if path.is_file() and path.name != 'SHA256SUMS']
        (self.native / 'SHA256SUMS').write_text('\n'.join(lines) + '\n')

    def run_prepare(self):
        return p.prepare(self.base, self.facts_path, self.native, self.output, repository=self.root,
                         preparation_source_commit='2' * 40, preparation_run_id='12345')

    def reject(self):
        with self.assertRaises(ValueError):
            self.run_prepare()

    def test_exact_provenance_allowed_diffs_and_unsigned_packages(self):
        result = self.run_prepare()
        self.assertEqual(result['state'], 'prepared_unsigned')
        self.assertTrue(result['private_laboratory_only'])
        self.assertEqual(result['source_commit'], self.commit)
        self.assertEqual(result['base_archive_sha256'], p.digest(self.base))
        self.assertEqual(result['preparation_source_commit'], '2' * 40)
        self.assertEqual(result['preparation_run_id'], '12345')
        for flavor in ('normal', 'fault'):
            directory = self.output / flavor / p.NAME
            archive = self.output / flavor / (p.NAME + '.zip')
            self.assertEqual(p.candidate.verify(archive, p.TARGET)['sha256'], result[flavor]['sha256'])
            self.assertEqual((directory / 'VERSION').read_bytes(), b'1.0.14\n')
            self.assertEqual((directory / 'web/VERSION').read_bytes(), b'1.0.14\n')
            self.assertEqual((directory / 'web/index.php').read_bytes(), self.files['web/index.php'])
            self.assertEqual((directory / 'engine/mod/mod_sofia.dll').read_bytes(), self.files['engine/mod/mod_sofia.dll'])
            self.assertFalse((directory / 'server/original-only.txt').exists())
            self.assertEqual((directory / 'server/new-only.txt').read_bytes(), b'new fictional source-specific output')
        self.assertEqual({entry['path'] for entry in result['fault_diff']}, p.FAULT_FILES | {'release-manifest.json'})
        normal = self.output / 'normal' / p.NAME
        fault = self.output / 'fault' / p.NAME
        self.assertEqual((fault / 'Install-MailQueue.ps1').read_bytes(), (normal / 'Install-MailQueue.ps1').read_bytes() + p.FAULT_HOOK.encode())
        self.assertTrue((normal / 'README.txt').read_bytes().startswith(b'OpenWeb PBX 1.0.14\n'))
        self.assertIn(b'installing-1.0.13.md', (normal / 'README.txt').read_bytes())
        self.assertEqual(stat.S_IMODE(self.output.stat().st_mode), 0o700)
        self.assertEqual(stat.S_IMODE((self.output / 'provenance.json').stat().st_mode), 0o600)
        self.assertFalse((normal / 'provenance.json').exists())
        self.assertEqual(p.digest(self.output / 'evidence/source-inputs.json'), result['native_provenance']['source_inputs_sha256'])
        self.assertIn('canary-fault-witness-<nonce>.json', result['fault_contract']['witness'])
        self.assertIn('baseline_version', result['fault_contract']['required_fields'])

    def test_empty_or_missing_essential_gates_are_never_qualification(self):
        for gate in p.ESSENTIAL_GATES:
            for value in ('pending', 'unqualified', False, None):
                with self.subTest(gate=gate, value=value):
                    self.facts['gates'][gate] = value
                    self.refresh()
                    self.reject()
            self.facts['gates'][gate] = 'passed'
        self.facts['gates'] = {}
        self.refresh()
        self.reject()

    def test_failed_base_and_missing_archive_identity(self):
        self.facts['state'] = 'failed'
        self.refresh()
        self.reject()
        self.facts['state'] = 'partial'
        self.facts['artifacts'] = None
        self.refresh()
        self.reject()

    def test_base_archive_must_match_exact_qualified_bytes(self):
        self.archive({'web/new.txt': b'changed since qualification'})
        self.reject()

    def test_source_commit_must_be_same_immutable_base(self):
        self.inputs['source_commit'] = '2' * 40
        self.refresh()
        self.reject()

    def test_full_original_source_hashes_cannot_be_omitted_or_rewritten(self):
        original = copy.deepcopy(self.inputs['source_inputs'])
        self.inputs['source_inputs'].pop()
        self.refresh()
        self.reject()
        self.inputs['source_inputs'] = original
        self.inputs['source_inputs'][0]['sha256'] = '0' * 64
        self.refresh()
        self.reject()

    def test_original_source_path_traversal(self):
        self.inputs['source_inputs'][0]['path'] = '../outside'
        self.refresh()
        self.reject()

    def test_exact_two_overlays_only(self):
        self.inputs['overlays'].pop()
        self.refresh()
        self.reject()

    def test_other_overlay_source_changes_are_rejected_even_when_rehashed(self):
        name = 'platform/Directory.Build.props'
        self.native_file('overlays/' + name, self.sources[name].replace(b'1.0.13', b'1.0.14') + b'<!-- unrelated code change -->')
        for entry in self.inputs['overlays']:
            if entry['path'] == name:
                entry['sha256'] = p.digest(self.native / ('overlays/' + name))
        self.refresh()
        self.reject()

    def test_overlay_original_hash_must_be_independent_immutable_hash(self):
        self.inputs['overlays'][0]['original_sha256'] = '0' * 64
        self.refresh()
        self.reject()

    def test_no_assembly_version_claim_without_windows_verification(self):
        (self.native / 'verification.json').unlink()
        self.checksums()
        with self.assertRaises(FileNotFoundError):
            self.run_prepare()

    def test_actual_version_and_hash_records_for_all_three_assemblies(self):
        self.verification['assemblies'][0]['assembly_version'] = '1.0.13.0'
        self.refresh()
        self.reject()
        self.verification['assemblies'][0]['assembly_version'] = '1.0.14.0'
        self.verification['assemblies'][0]['sha256'] = '0' * 64
        self.refresh()
        self.reject()

    def test_complete_native_trees_are_required(self):
        (self.native / 'server/OpenWebPbx.Server.exe').unlink()
        self.checksums()
        self.reject()

    def test_exact_native_checksums_refuse_unlisted_or_changed_files(self):
        self.native_file('server/unlisted.txt', b'unlisted native output')
        self.reject()

    def test_native_case_collisions_symlinks_and_hardlinks(self):
        self.native_file('server/OPENWEBPBX.Server.dll', b'collision')
        self.reject()
        (self.native / 'server/OPENWEBPBX.Server.dll').unlink()
        link = self.native / 'server/link.txt'
        link.symlink_to(self.native / 'server/OpenWebPbx.Server.dll')
        self.reject()
        link.unlink()
        import os
        os.link(self.native / 'server/OpenWebPbx.Server.dll', link)
        self.reject()

    def test_native_signing_secret_is_never_prepared(self):
        self.native_file('signing.key', b'fictional private signing secret')
        self.checksums()
        self.reject()

    def test_private_pem_under_an_unusual_name_is_rejected(self):
        self.native_file('unusual.pem', b'-----BEGIN PRIVATE KEY-----\nsynthetic forbidden fixture\n')
        self.checksums()
        self.reject()

    def test_checksum_inventory_cannot_traverse(self):
        with (self.native / 'SHA256SUMS').open('a') as stream:
            stream.write('0' * 64 + '  ../outside\n')
        self.reject()

    def test_bounded_native_member_and_inventory_counts(self):
        with (self.native / 'oversized.bin').open('wb') as stream:
            stream.seek(p.MAX_FILE)
            stream.write(b'x')
        self.reject()
        (self.native / 'oversized.bin').unlink()
        with mock.patch.object(p, 'MAX_ENTRIES', 3):
            self.reject()

    def test_existing_outputs_are_not_overwritten(self):
        self.output.mkdir()
        sentinel = self.output / 'unrelated.txt'
        sentinel.write_text('preserve unrelated work')
        self.reject()
        self.assertEqual(sentinel.read_text(), 'preserve unrelated work')

    def test_preparation_workflow_identity_is_required(self):
        with self.assertRaises(ValueError):
            p.prepare(self.base, self.facts_path, self.native, self.output, repository=self.root,
                      preparation_source_commit='main', preparation_run_id='12345')
        with self.assertRaises(ValueError):
            p.prepare(self.base, self.facts_path, self.native, self.output, repository=self.root,
                      preparation_source_commit='2' * 40, preparation_run_id='not-a-run')

    def test_unknown_metadata_cannot_export_private_inputs(self):
        self.inputs['private_input'] = 'forbidden synthetic private runtime value'
        self.refresh()
        self.reject()

    def test_duplicate_provenance_keys_are_rejected(self):
        self.facts_path.write_text('{"schema":1,"schema":1}')
        self.reject()

if __name__ == '__main__':
    unittest.main()
