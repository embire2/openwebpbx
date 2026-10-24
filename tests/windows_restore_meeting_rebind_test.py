#!/usr/bin/env python3
"""Actual socket-only PostgreSQL/PHP rebind; no production config or Windows claims."""
import ast
import copy
import importlib.util
import json
import os
from pathlib import Path, PureWindowsPath, WindowsPath
import pwd
import shutil
import subprocess
import tempfile
import unittest
from types import SimpleNamespace

HERE=Path(__file__).resolve().parent
SPEC=importlib.util.spec_from_file_location('meeting_restore_compare',HERE/'windows-restore-qualification.py')
q=importlib.util.module_from_spec(SPEC);SPEC.loader.exec_module(q)
PG=Path(os.environ.get('OPENWEB_TEST_POSTGRES_BIN','/usr/lib/postgresql/18/bin'))


def actual_windows_restore_arguments():
    # Execute only the unchanged product function with query/file/run adapters.
    # WindowsPath and PureWindowsPath share the real Windows string formatter.
    if WindowsPath.__str__ is not PureWindowsPath.__str__:
        raise AssertionError('The exact Windows formatter implementation changed.')
    tree=ast.parse((HERE.parent/'packaging/windows/backups.py').read_text())
    nodes=[n for n in tree.body if isinstance(n,ast.FunctionDef) and n.name=='restore_meeting']
    if len(nodes)!=1:raise AssertionError('One actual product restore_meeting function is required.')
    commands=[];paths=[];queries=[]
    def query(settings,sql):
        queries.append(sql);return 't' if "to_regclass" in sql else '1'
    def ordinary(path):paths.append(path);return path
    def run(command,**kwargs):commands.append((command,kwargs))
    roots={'freeswitch-config':PureWindowsPath('C:/TargetPBX/conf'),
        'runtime-config':PureWindowsPath('C:/ProgramData/OpenWebPBX'),
        'fusionpbx-config':PureWindowsPath('C:/ProgramData/fusionpbx')}
    namespace=dict(query=query,ordinary=ordinary,run=run,ROOTS=roots,
        APP=PureWindowsPath('C:/OpenWebPBX'),WEB_VERSION=PureWindowsPath('C:/OpenWebPBX/web/VERSION'),os=SimpleNamespace(name='nt'))
    exec(compile(ast.Module(body=nodes,type_ignores=[]),'actual-backups-restore-meeting','exec'),namespace)
    if namespace['restore_meeting']({}) is not True or len(commands)!=1 or len(paths)!=2 or len(queries)!=2:
        raise AssertionError('The exact once-only product argument flow changed.')
    command,kwargs=commands[0]
    if kwargs!={'timeout':120} or len(command)!=7 or command[:2]!=[r'C:\OpenWebPBX\php\php.exe','-r']:
        raise AssertionError('The original executable/argument/deadline contract changed.')
    if command[5]!=str(roots['freeswitch-config']):raise AssertionError('The raw Windows conf argument changed.')
    code=command[2]
    guard=next(line for line in code.splitlines() if line.startswith("if(str_replace('"))
    if "pbx_meet_install::rebind($db,null,$argv[3]);" not in code:
        raise AssertionError('The actual product must pass raw argv3 to rebind.')
    return {'windows_conf':command[5],'product_path_guard':guard}


class MeetingRebindControls(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        if os.name!='posix' or not (PG/'initdb').is_file() or not shutil.which('php'):
            raise unittest.SkipTest('Actual local PostgreSQL/PHP are required for these component tests.')
        cls.directory=Path(tempfile.mkdtemp(prefix='openweb-meet-rebind-'))
        cls.started=False
        cls.prefix=[]
        if os.geteuid()==0:
            account=pwd.getpwnam('postgres');os.chown(cls.directory,account.pw_uid,account.pw_gid)
            cls.prefix=['runuser','-u','postgres','--']
        cls.addClassCleanup(cls.cleanup_cluster)
        cls.run_pg('initdb','-D',str(cls.directory/'data'),'--no-locale','-E','UTF8','--auth-local=trust','--auth-host=reject')
        socket=cls.directory/'socket';socket.mkdir(mode=0o700)
        if cls.prefix:os.chown(socket,account.pw_uid,account.pw_gid)
        options=f"-k {socket} -p 55483 -c listen_addresses='' -c unix_socket_permissions=0700 -c shared_buffers=16MB -c max_connections=8 -c autovacuum=off"
        cls.started=True
        cls.run_pg('pg_ctl','-D',str(cls.directory/'data'),'-l',str(cls.directory/'postgres.log'),'-o',options,'-w','-t','20','start')
        child=subprocess.run(['php',str(HERE/'windows-restore-meeting-rebind.php')],
            input=json.dumps({'temporary':str(cls.directory)}|actual_windows_restore_arguments()),text=True,capture_output=True,
            env=os.environ|{'OPENWEB_MEETING_REBIND_TEST':'1'},timeout=30)
        if child.returncode:raise AssertionError('The isolated actual PHP fixture failed: '+child.stderr)
        cls.evidence=json.loads(child.stdout)
        destination=os.environ.get('OPENWEB_MEETING_REBIND_EVIDENCE')
        if destination:Path(destination).write_text(json.dumps(cls.evidence,indent=2)+'\n')

    @classmethod
    def run_pg(cls,name,*args):
        child=subprocess.run(cls.prefix+[str(PG/name),*args],text=True,capture_output=True,timeout=40)
        if child.returncode:raise AssertionError('The isolated cluster operation failed: '+child.stdout+child.stderr)

    @classmethod
    def cleanup_cluster(cls):
        if cls.started:
            cls.run_pg('pg_ctl','-D',str(cls.directory/'data'),'-m','fast','-w','-t','20','stop')
            cls.started=False
        shutil.rmtree(cls.directory)

    def compare(self,source=None,target=None,baseline=None):
        q.compare_snapshots(source or self.evidence['source'],target or self.evidence['target'],
            'source-restored',target_baseline=baseline or self.evidence['baseline'])

    def test_actual_rebind_exact_three_value_cells_and_idempotence(self):
        self.assertEqual(self.evidence['actual_rebound_rows'],3)
        self.assertIs(self.evidence['idempotent'],True)
        self.assertEqual(sorted(self.evidence['actual_delta_cells']),[
            ['cfb1c835-c30c-409b-bff7-a893a7e84df1',name,'sip_profile_setting_value']
            for name in ['ext-rtp-ip','rtp-ip','tls-cert-dir']])
        source,target=self.evidence['source'],self.evidence['target']
        self.assertNotEqual(source['all_table_values']['v_sip_profile_settings'],target['all_table_values']['v_sip_profile_settings'])
        self.assertEqual(source['meeting_rebind']['hmac'],target['meeting_rebind']['hmac'])
        self.assertNotEqual(source['meeting_rebind']['binding'],target['meeting_rebind']['binding'])
        self.compare()
        self.compare(source=target,target=target)

    def test_actual_windows_same_path_changes_only_two_addresses(self):
        case=self.evidence['same_path'];self.assertEqual(case['actual_rebound_rows'],2)
        self.compare(case['source'],case['target'],case['baseline'])

    def test_actual_windows_argument_and_exact_target_binding(self):
        proof=self.evidence['windows_argument']
        self.assertIs(proof['config_guard_passed'],True)
        self.assertIs(proof['exact_raw_windows_tls_value'],True)
        self.assertIs(proof['different_from_raw_config_tls'],True)
        self.assertEqual(proof['actual_rebound_rows'],3)
        self.assertEqual(proof['collector'],'passed')
        self.assertIs(proof['idempotent'],True)
        self.assertEqual(proof['snapshot']['meeting_rebind']['binding'],proof['baseline']['meeting_rebind']['binding'])
        self.compare(proof['source'],proof['snapshot'],proof['baseline'])

    def test_windows_representation_is_not_general_path_normalization(self):
        expected={'mixed_prefix','backslash_suffix','different_case','different_drive','neighbor_directory',
            'parent_component','dot_component','repeated_separator','repeated_suffix_separator',
            'encoded_component','neighbor_suffix','trailing_separator'}
        self.assertEqual(set(self.evidence['windows_path_refused']),expected)
        self.assertEqual(len(self.evidence['windows_path_refused']),len(expected))
        self.assertEqual(set(self.evidence['windows_guard_refused']),{'disabled_tls','duplicate_tls','invalid_uuid'})
        self.assertEqual(len(self.evidence['windows_guard_refused']),3)

    def test_windows_representation_preserves_other_rows_and_original_binding(self):
        self.assertEqual(set(self.evidence['windows_changed_snapshots']),
            {'foreign_tls','owned_uuid','owned_other_column','different_config','different_address'})
        for name,snapshot in self.evidence['windows_changed_snapshots'].items():
            with self.subTest(name=name),self.assertRaises(ValueError):self.compare(target=snapshot)

    def test_actual_invalid_owned_values_and_profile_identities_refuse_in_php(self):
        expected={f'{kind}_{name}' for name in ('rtp-ip','ext-rtp-ip','tls-cert-dir')
                  for kind in ('wrong_value','disabled','missing','renamed','duplicate')}
        expected|={'wrong_profile_uuid','profile_name','profile_uuid','profile_duplicate','conference_name','conference_duplicate','stale_source_binding'}
        self.assertEqual(set(self.evidence['refused']),expected)
        self.assertEqual(len(self.evidence['refused']),len(expected))

    def test_actual_other_cells_uuids_foreign_profiles_and_wrong_local_context_refuse(self):
        expected={f'{kind}_{name}' for name in ('rtp-ip','ext-rtp-ip','tls-cert-dir') for kind in ('uuid','other_column','foreign')}
        expected|={'owned_other_setting','new_foreign_row','delete_foreign_row','profile_disabled','profile_other_column','conference_other_column','wrong_address','wrong_conf'}
        self.assertEqual(set(self.evidence['mutated_snapshots']),expected)
        for name,snapshot in self.evidence['mutated_snapshots'].items():
            with self.subTest(name=name),self.assertRaises(ValueError):self.compare(target=snapshot)

    def test_complete_exact_proof_shape_and_original_target_binding_required(self):
        for which in ('source','target','baseline'):
            original=self.evidence[which];proof=original['meeting_rebind'];table=original['all_table_values']['v_sip_profile_settings']
            invalid=[None,{},proof|{'rows':True},proof|{'rows':-1},proof|{'rows':2},proof|{'rows':table['rows']+1},
                proof|{'hmac':None},proof|{'hmac':'PRIVATE'},proof|{'hmac':[]},proof|{'binding':False},
                proof|{'binding':'PRIVATE'},proof|{'binding':{}},proof|{'unexpected':'PRIVATE'},
                {k:v for k,v in proof.items() if k!='binding'}]
            for candidate in invalid:
                changed=copy.deepcopy(original);changed['meeting_rebind']=candidate
                with self.subTest(which=which,candidate=candidate),self.assertRaises(ValueError):self.compare(**{which:changed})
            for row in ({'rows':True,'hmac':'a'*64},{'rows':table['rows'],'hmac':'bad'},table|{'extra':0}):
                changed=copy.deepcopy(original);changed['all_table_values']['v_sip_profile_settings']=row
                with self.subTest(which=which,row=row),self.assertRaises(ValueError):self.compare(**{which:changed})
        with self.assertRaises(ValueError):q.compare_snapshots(self.evidence['source'],self.evidence['target'],'source-restored')
        for which in ('target','baseline'):
            changed=copy.deepcopy(self.evidence[which]);changed['meeting_rebind']['binding']='0'*64
            with self.subTest(which=which),self.assertRaises(ValueError):self.compare(**{which:changed})
        for which in ('source','target'):
            changed=copy.deepcopy(self.evidence[which]);changed['meeting_rebind']['hmac']='0'*64
            with self.subTest(which=which),self.assertRaises(ValueError):self.compare(**{which:changed})

    def test_factory_recovery_retains_every_original_value(self):
        original=self.evidence['source'];q.compare_snapshots(original,copy.deepcopy(original),'factory-recovery')
        with self.assertRaises(ValueError):q.compare_snapshots(original,self.evidence['target'],'factory-recovery')

    def test_actual_collector_and_restore_call_cannot_bypass_full_table_comparison(self):
        self.assertNotIn('v_sip_profile_settings',q.OPERATIONAL_TABLES|q.RESTORE_TRANSFORMED_TABLES)
        source=(HERE/'windows-restore-qualification.py').read_text();tree=ast.parse(source)
        restore=next(n for n in ast.walk(tree) if isinstance(n,ast.FunctionDef) and n.name=='restore')
        calls=[n for n in ast.walk(restore) if isinstance(n,ast.Call) and isinstance(n.func,ast.Name) and n.func.id=='compare_snapshots']
        self.assertEqual(len(calls),1);self.assertEqual([(k.arg,ast.unparse(k.value)) for k in calls[0].keywords],[('target_baseline','before')])
        php=(HERE/'windows-restore-qualification.php').read_text()
        self.assertIn("if($table==='v_sip_profile_settings')$out['meeting_rebind']=restore_fixture_meeting_rebind($db,$rows,$key);",php)


if __name__=='__main__':unittest.main()
