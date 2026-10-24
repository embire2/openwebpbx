"""Actual owned recovery files and exact core producer pins; no native pass."""
import ast
import copy
import hashlib
import importlib.util
import json
from pathlib import Path
import tempfile
import types
import unittest
from unittest.mock import patch

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location('restored_inventory_candidate', HERE / 'windows_restored_meeting.py')
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
CORE = HERE.parent / 'packaging/windows/backups.py'
CORE_SHA = 'a1b032a6ead38af079acb945869845a8f56015823e891dedc2bb22e33e23545e'
ORIGINAL_BODY = """def stable_files(q):
    root = ordinary(q.backups.RESTORE, True)
    entries = list(root.rglob('*')); require(len(entries) <= 64)
    result = {str(p.relative_to(root)): digest(p) for p in entries if not p.is_dir()}
    for p in entries: ordinary(p, p.is_dir())
    require('hold-calls' not in result and all('hold-' + name in result for name in ('jobs', 'updates', 'backups')))
    for name, path in {'original_input': q.path, 'original_ca': q.s['web_ca'], 'runtime': q.backups.STATE / 'runtime.json',
                       'meet_ca': q.backups.STATE / 'meet-ca.pem', 'phone_tls': q.backups.STATE / 'phone-tls.json',
                       'installed_configuration': q.backups.CONFIG}.items(): result['file:' + name] = digest(path)
    return result"""
namespace = dict(m.__dict__); exec(compile(ORIGINAL_BODY, 'exact-original-inventory', 'exec'), namespace)
original = namespace['stable_files']


class Fixture:
    def __init__(self, root, count=0, journal=True, copy_data=b'private recovery bytes', dump_data=b'private factory dump'):
        self.root = root; self.state = root / 'state'; self.state.mkdir()
        self.restore = self.state / 'backup-restore'; self.restore.mkdir()
        self.input = root / 'input.json'; self.input.write_text('{}')
        self.ca = root / 'ca.pem'; self.ca.write_text('controlled CA bytes')
        self.config = root / 'config.conf'; self.config.write_text('private configuration')
        self.targets = root / 'private-factory-target'; self.targets.mkdir()
        for name in ('runtime.json', 'meet-ca.pem', 'phone-tls.json'): (self.state / name).write_text('private ' + name)
        for name in ('jobs', 'updates', 'backups'): (self.restore / ('hold-' + name)).write_text('{}')
        self.q = types.SimpleNamespace(path=self.input, s={'web_ca': str(self.ca)}, backups=types.SimpleNamespace(
            RESTORE=self.restore, STATE=self.state, CONFIG=self.config, MAX_FILES=500000, MAX_ARCHIVE=50 * 1000**3,
            ROOTS={'private-target': self.targets}, MEDIA={}, reparse=lambda path: path.is_symlink()))
        self.journal = None
        if journal:
            self.copies = self.restore / 'factory-files'; self.copies.mkdir()
            files = {}
            for i in range(count):
                path = self.copies / str(i); path.write_bytes(copy_data)
                files[str(self.targets / str(i))] = dict(exists=True, copy=str(i), mode=0o600, sddl='D:PAI(A;;FA;;;SY)', size=len(copy_data), sha256=hashlib.sha256(copy_data).hexdigest())
            (self.restore / 'factory.dump').write_bytes(dump_data)
            self.journal = dict(schema=1, factory_security_version=1, files=files, factory_dump_sha256=hashlib.sha256(dump_data).hexdigest())
            self.save()
    def save(self): (self.restore / 'journal.json').write_text(json.dumps(self.journal))


class RecoveryInventory(unittest.TestCase):
    def test_actual_after_parse_journal_replacement_old_admits_corrected_order_refuses(self):
        current = (HERE / 'windows_restored_meeting.py').read_text()
        fixed = '    original_journal = digest(journal); value = read_json(journal, 8 * 1024**2)'
        rejected = '    value = read_json(journal, 8 * 1024**2); original_journal = digest(journal)'
        self.assertEqual(current.count(fixed), 1)
        inventory_source = current
        helper = next(n for n in ast.parse(current).body if isinstance(n, ast.FunctionDef) and n.name == 'restored_path_fields')
        inventory_source = inventory_source.replace(ast.get_source_segment(current, helper) + '\n\n\n', '', 1)
        start = inventory_source.index("    if record['active_case'] == 'native_windows_meeting_browser_start':")
        end = inventory_source.index('    return record\n', start) + len('    return record\n')
        inventory_source = inventory_source[:start] + inventory_source[end:]
        inventory_source = inventory_source.replace("    record = {'schema': 1, 'state': 'failed', 'producer': 'windows_restored_meeting.py',", "    return {'schema': 1, 'state': 'failed', 'producer': 'windows_restored_meeting.py',", 1)
        self.assertEqual(hashlib.sha256(inventory_source.encode()).hexdigest(), 'e84f1a60b98fc905f58d49a4f2da1d5a06f529b452bdded0c3555150c05218fc')
        old_source = inventory_source.replace(fixed, rejected, 1)
        self.assertEqual(hashlib.sha256(old_source.encode()).hexdigest(), '9a87dde5bdbf8061b9901dd609f52185cc48f3a1e5159003fc80a14387fffee9')
        old = types.ModuleType('rejected_648a_journal_order'); old.__file__ = str(HERE / 'windows_restored_meeting.py')
        exec(compile(old_source, old.__file__, 'exec'), old.__dict__)
        for module, refuses in ((old, False), (m, True)):
            with self.subTest(refuses=refuses), tempfile.TemporaryDirectory(prefix='restored-inventory-order-race-') as td:
                f = Fixture(Path(td), count=2); path = f.restore / 'journal.json'
                before = path.read_bytes(); saved_read = module.read_json; observed = []
                invalid = copy.deepcopy(f.journal)
                invalid['files'] = {'/outside/core/allowed/roots': next(iter(invalid['files'].values()))}
                replacement = json.dumps(invalid).encode()
                def replace_after_parse(candidate, *args, **kwargs):
                    value = saved_read(candidate, *args, **kwargs)
                    if candidate == path:
                        observed.append('valid_original_parsed')
                        self.assertEqual(value, f.journal)
                        path.write_bytes(replacement)
                    return value
                with patch.object(module, 'read_json', side_effect=replace_after_parse):
                    if refuses:
                        # The final existing journal equality detects the race;
                        # no earlier copy/path policy was weakened or bypassed.
                        node = next(n for n in ast.walk(ast.parse(current)) if isinstance(n, ast.Call)
                                    and isinstance(n.func, ast.Name) and n.func.id == 'require'
                                    and ast.get_source_segment(current, n) == 'require(digest(journal) == original_journal)')
                        frames = []
                        try: module.stable_files(f.q)
                        except RuntimeError as error:
                            trace = error.__traceback__
                            while trace:
                                if trace.tb_frame.f_code.co_name == 'recovery_inventory': frames.append(trace.tb_lineno)
                                trace = trace.tb_next
                        else: self.fail('The corrected journal order admitted the real replacement.')
                        self.assertEqual(frames, [node.lineno])
                    else:
                        snapshot = module.stable_files(f.q)
                        self.assertEqual(snapshot['journal.json'], hashlib.sha256(replacement).hexdigest())
                self.assertEqual(observed, ['valid_original_parsed'])
                self.assertNotEqual(before, path.read_bytes()); self.assertEqual(path.read_bytes(), replacement)
                path.write_bytes(before)
                self.assertEqual(old.stable_files(f.q), m.stable_files(f.q))

    def test_exact_core_producer_policy_and_durable_copy_source_pins(self):
        raw = CORE.read_bytes(); self.assertEqual(hashlib.sha256(raw).hexdigest(), CORE_SHA)
        tree = ast.parse(raw); constants = {}
        for node in tree.body:
            if isinstance(node, ast.Assign) and any(isinstance(t, ast.Name) and t.id in ('MAX_FILES', 'MAX_ARCHIVE') for t in node.targets):
                constants[node.targets[0].id] = eval(compile(ast.Expression(node.value), '<public-policy>', 'eval'), {'__builtins__': {}})
        self.assertEqual(constants, {'MAX_FILES': 500000, 'MAX_ARCHIVE': 50 * 1000**3})
        source = raw.decode(); restore = next(n for n in tree.body if isinstance(n, ast.FunctionDef) and n.name == '_restore')
        text = ast.get_source_segment(source, restore)
        for fragment in ("recovery_files = RESTORE / 'factory-files'", 'for index, target in enumerate(recovery_targets):',
                         'copy = recovery_files / str(index)', 'shutil.copyfile(target, copy)', "'size': st.st_size, 'sha256': checksum(copy)",
                         "'factory_dump_sha256': checksum(RESTORE / 'factory.dump')", "atomic_json(RESTORE / 'journal.json', journal)"):
            self.assertIn(fragment, text)
        self.assertNotIn('8 * 1024**2', text)

    def test_actual_65_file_original_refusal_and_full_journal_bound_positive(self):
        with tempfile.TemporaryDirectory(prefix='restored-inventory-65-') as td:
            f = Fixture(Path(td), count=65)
            with self.assertRaises(RuntimeError): original(f.q)
            snapshot = m.stable_files(f.q)
            for i in range(65): self.assertEqual(snapshot['factory-files/' + str(i)], hashlib.sha256(b'private recovery bytes').hexdigest())
            self.assertEqual(snapshot['factory.dump'], f.journal['factory_dump_sha256'])
            self.assertEqual(snapshot, m.stable_files(f.q))
            self.assertEqual(len(snapshot), 65 + 11)
            # No recovery copy, journal, dump, hold or fixed input was omitted.
            self.assertTrue({'journal.json', 'factory.dump', 'hold-jobs', 'hold-updates', 'hold-backups'} <= set(snapshot))

    def test_original_64_entry_branch_and_all_fixed_file_bytes_unchanged_without_copies(self):
        with tempfile.TemporaryDirectory(prefix='restored-inventory-no-copies-') as td:
            f = Fixture(Path(td), journal=False)
            for i in range(61): (f.restore / ('extra-' + str(i))).write_bytes(b'controlled metadata')
            self.assertEqual(len(list(f.restore.rglob('*'))), 64)
            self.assertEqual(original(f.q), m.stable_files(f.q))
            (f.restore / 'extra-over-bound').write_bytes(b'controlled metadata')
            for method in (original, m.stable_files):
                with self.assertRaises(RuntimeError): method(f.q)
        with tempfile.TemporaryDirectory(prefix='restored-inventory-zero-journal-') as td:
            f = Fixture(Path(td), count=0)
            self.assertEqual(original(f.q), m.stable_files(f.q))

    def test_every_copy_dump_and_metadata_change_is_retained_or_refused(self):
        with tempfile.TemporaryDirectory(prefix='restored-inventory-preserve-') as td:
            f = Fixture(Path(td), count=65); baseline = m.stable_files(f.q)
            for i in range(65):
                path = f.copies / str(i); before = path.read_bytes(); path.write_bytes(b'X' + before[1:])
                with self.subTest(copy=i), self.assertRaises(RuntimeError): m.stable_files(f.q)
                path.write_bytes(before)
            dump = f.restore / 'factory.dump'; before = dump.read_bytes(); dump.write_bytes(b'X' + before[1:])
            with self.assertRaises(RuntimeError): m.stable_files(f.q)
            dump.write_bytes(before)
            for path in (f.input, f.ca, f.config, f.state / 'runtime.json', f.state / 'meet-ca.pem', f.state / 'phone-tls.json', f.restore / 'hold-jobs'):
                before = path.read_bytes(); path.write_bytes(before + b' changed')
                self.assertNotEqual(m.stable_files(f.q), baseline); path.write_bytes(before)
            added = f.restore / 'unexpected-metadata'; added.write_bytes(b'new exact path')
            self.assertNotEqual(m.stable_files(f.q), baseline); added.unlink()
            self.assertEqual(m.stable_files(f.q), baseline)
            (f.restore / 'hold-calls').write_text('{}')
            with self.assertRaises(RuntimeError): m.stable_files(f.q)

    def test_journal_copy_names_counts_and_fields_have_no_escape_or_unbound_allowance(self):
        changes = [lambda j: j.update(schema=True), lambda j: j.update(factory_security_version=2),
                   lambda j: j.update(files=[]), lambda j: j.update(factory_dump_sha256='private'),
                   lambda j: j.update(files={'/outside/allowed/roots': next(iter(j['files'].values()))}),
                   lambda j: next(iter(j['files'].values())).update(mode=True),
                   lambda j: next(iter(j['files'].values())).update(sddl=''),
                   lambda j: next(iter(j['files'].values())).update(copy='../0'),
                   lambda j: next(iter(j['files'].values())).update(copy='/absolute'),
                   lambda j: next(iter(j['files'].values())).update(copy='00'),
                   lambda j: next(iter(j['files'].values())).update(copy='500000'),
                   lambda j: next(iter(j['files'].values())).update(copy=0),
                   lambda j: next(iter(j['files'].values())).update(exists=1),
                   lambda j: next(iter(j['files'].values())).update(exists=False),
                   lambda j: next(iter(j['files'].values())).update(size=True),
                   lambda j: next(iter(j['files'].values())).update(size=-1),
                   lambda j: next(iter(j['files'].values())).update(size=1),
                   lambda j: next(iter(j['files'].values())).update(sha256='0'*64),
                   lambda j: j['files'].update(duplicate=copy.deepcopy(next(iter(j['files'].values()))))]
        for index, change in enumerate(changes):
            with self.subTest(index=index), tempfile.TemporaryDirectory(prefix='restored-inventory-journal-') as td:
                f = Fixture(Path(td), count=2); change(f.journal); f.save()
                with self.assertRaises(RuntimeError): m.stable_files(f.q)
        for case in ('missing-journal', 'duplicate-json', 'missing-copy', 'extra-copy', 'copy-directory', 'copy-link', 'copies-root-link', 'target-parent-link', 'target-parent-escape', 'dump-link'):
            with self.subTest(case=case), tempfile.TemporaryDirectory(prefix='restored-inventory-path-') as td:
                f = Fixture(Path(td), count=2); external = Path(td) / 'external'; external.write_bytes(b'private recovery bytes')
                if case == 'missing-journal': (f.restore / 'journal.json').unlink()
                elif case == 'duplicate-json':
                    path = f.restore / 'journal.json'; path.write_text(path.read_text().replace('"schema": 1', '"schema": 1, "schema": 1'))
                elif case == 'missing-copy': (f.copies / '0').unlink()
                elif case == 'extra-copy': (f.copies / '99').write_bytes(b'not journal bound')
                elif case == 'copy-directory': (f.copies / '0').unlink(); (f.copies / '0').mkdir()
                elif case == 'copy-link': (f.copies / '0').unlink(); (f.copies / '0').symlink_to(external)
                elif case == 'copies-root-link':
                    moved = Path(td) / 'moved-copies'; f.copies.rename(moved); f.copies.symlink_to(moved, target_is_directory=True)
                elif case == 'target-parent-link':
                    moved = Path(td) / 'moved-targets'; f.targets.rename(moved); f.targets.symlink_to(moved, target_is_directory=True)
                elif case == 'target-parent-escape':
                    entry = f.journal['files'].pop(next(iter(f.journal['files'])))
                    f.journal['files'][str(f.targets / 'nested/../outside')] = entry; f.save()
                elif case == 'dump-link': (f.restore / 'factory.dump').unlink(); (f.restore / 'factory.dump').symlink_to(external)
                with self.assertRaises(RuntimeError): m.stable_files(f.q)

    def test_recovery_data_above_old_8mib_limit_uses_bounded_streaming_and_core_aggregate(self):
        with tempfile.TemporaryDirectory(prefix='restored-inventory-large-data-') as td:
            data = b'Z' * (9 * 1024**2); f = Fixture(Path(td), count=1, copy_data=data, dump_data=data)
            with self.assertRaises(RuntimeError): original(f.q)
            snapshot = m.stable_files(f.q); digest = hashlib.sha256(data).hexdigest()
            self.assertEqual(snapshot['factory-files/0'], digest); self.assertEqual(snapshot['factory.dump'], digest)
            # A small explicit policy adapter proves aggregate refusal without
            # allocating or reading the actual50GB native policy boundary.
            f.q.backups.MAX_ARCHIVE = len(data)
            with self.assertRaises(RuntimeError): m.stable_files(f.q)
        with tempfile.TemporaryDirectory(prefix='restored-inventory-policy-') as td:
            f = Fixture(Path(td), count=2)
            for name, value in [('MAX_FILES', True), ('MAX_FILES', 1), ('MAX_FILES', 500001), ('MAX_ARCHIVE', True), ('MAX_ARCHIVE', 50 * 1000**3 + 1)]:
                before = getattr(f.q.backups, name); setattr(f.q.backups, name, value)
                with self.subTest(policy=name, value=value), self.assertRaises(RuntimeError): m.stable_files(f.q)
                setattr(f.q.backups, name, before)
            huge = f.copies / '0'
            with huge.open('wb') as stream: stream.truncate(50 * 1000**3 + 1)
            entry = next(iter(f.journal['files'].values())); entry['size'] = huge.stat().st_size; f.save()
            with self.assertRaises(RuntimeError): m.stable_files(f.q)

    def test_stream_refuses_growth_truncation_links_and_retains_fixed_metadata_bound(self):
        with tempfile.TemporaryDirectory(prefix='restored-inventory-stream-') as td:
            path = Path(td) / 'file'; path.write_bytes(b'four'); real_open = Path.open; requests = []
            class Growing:
                def __enter__(self): self.stream = real_open(path, 'rb'); return self
                def __exit__(self, *args): self.stream.close()
                def fileno(self): return self.stream.fileno()
                def read(self, size):
                    requests.append(size)
                    if len(requests) == 1:
                        with real_open(path, 'ab') as target: target.write(b'X')
                    return self.stream.read(size)
            with patch.object(Path, 'open', lambda current, *args, **kwargs: Growing() if current == path else real_open(current, *args, **kwargs)):
                with self.assertRaises(RuntimeError): m.recovery_file_digest(path, 4, 100)
            self.assertEqual(requests, [5])
            with self.assertRaises(RuntimeError): m.recovery_file_digest(path, 4, 100)
            alias = Path(td) / 'alias'; alias.symlink_to(path)
            with patch.object(Path, 'open', side_effect=AssertionError('Linked data must not open')):
                with self.assertRaises(RuntimeError): m.recovery_file_digest(alias, 5, 100)
        with tempfile.TemporaryDirectory(prefix='restored-inventory-metadata-cap-') as td:
            f = Fixture(Path(td), journal=False); extra = f.restore / 'metadata'
            with extra.open('wb') as stream: stream.truncate(8 * 1024**2 + 1)
            for method in (original, m.stable_files):
                with self.assertRaises(RuntimeError): method(f.q)


if __name__ == '__main__': unittest.main()
