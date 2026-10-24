"""Actual PHP/socket-only PostgreSQL observations; no PBX or external mail."""
import ast
import copy
import importlib.util
import json
import os
from pathlib import Path
import pwd
import shutil
import subprocess
import tempfile
import types
import unittest
from unittest.mock import patch

HERE = Path(__file__).resolve().parent
SPEC = importlib.util.spec_from_file_location('welcome_observed', HERE / 'windows_welcome_native.py')
w = importlib.util.module_from_spec(SPEC); SPEC.loader.exec_module(w)
PG = Path('/usr/lib/postgresql/18/bin')
SECRET = 'PRIVATE_ROW_password_CREDENTIAL'


def record():
    return dict(schema=1, public_equal=False, config_equal=True, config_check='after_refusal',
                baseline_state='matched', sample_state='matched', before_tables=2, after_tables=2,
                changed_tables=1, added_tables=0, removed_tables=0, unlisted_tables=0,
                tables=[dict(name='v_users', before=1, after=1, kind='changed')])


PHP_DRIVER = r'''<?php
$i=json_decode(stream_get_contents(STDIN),true,32,JSON_THROW_ON_ERROR);
$root=$i['cluster'];
if(!preg_match('~^/tmp/openweb-welcome-observer-[a-z0-9_]+$~D',$root)||is_link($root))throw new RuntimeException('Owned cluster required.');
$db=new PDO('pgsql:host='.$root.'/socket;port=55484;dbname=postgres','postgres',null,[PDO::ATTR_ERRMODE=>PDO::ERRMODE_EXCEPTION]);
if($db->query("show data_directory")->fetchColumn()!==$root.'/data'||$db->query('select inet_server_addr() is null')->fetchColumn()!==true)throw new RuntimeException('Exact socket cluster required.');
require $i['helper'];
$source=file_get_contents($i['source']);$start=strpos($source,'function welcome_public_fingerprint(PDO $db):string{');$end=strpos($source,"\nif(\$action==='prepare'){",$start);
if($start===false||$end===false)throw new RuntimeException('Actual fingerprint required.');eval(substr($source,$start,$end-$start));
$db->exec('drop schema public cascade;create schema public;create table public.v_users(id integer,value text);create table public.v_user_logs(id integer,value text)');
$db->exec("insert into public.v_users values(1,'PRIVATE_ROW_password_CREDENTIAL')");
$configFile=$root.'/config.conf';file_put_contents($configFile,'original-private-config');
$state=['public_before'=>welcome_public_fingerprint($db),'original_config_sha256'=>hash_file('sha256',$configFile),'schema_created'=>true,'queues'=>[]];
$schema='owned_welcome_observer';$db->exec('drop schema if exists '.$schema.' cascade;create schema '.$schema);
$mode=$i['mode'];
if($mode==='baseline_unstable')$db->exec("insert into public.v_user_logs values(1,'PRIVATE_ROW_password_CREDENTIAL')");
$state['public_observation_before']=welcome_inventory_baseline($db,$state['public_before']);
$timeoutBefore=$db->query('show statement_timeout')->fetchColumn();$lockBefore=$db->query('show lock_timeout')->fetchColumn();
if(in_array($mode,['row','failure_unstable','baseline_unstable','sample_unavailable','original_primary'],true))$db->exec("update public.v_users set value='changed-private-value'");
if($mode==='catalog')$db->exec('drop table public.v_users;create table public.private_unknown_secret_table(id integer)');
if($mode==='config')file_put_contents($configFile,'changed-private-config');
if($mode==='oversized')$db->exec("update public.v_users set value=repeat('S',1048577)");
if($mode==='outer_transaction'){
 $db->beginTransaction();$db->exec("insert into public.v_users values(2,'owned-uncommitted')");$sample=welcome_inventory_sample($db);
 $out=['sample_unavailable'=>$sample===null,'outer_transaction_preserved'=>$db->inTransaction(),'uncommitted_row_preserved'=>(int)$db->query('select count(*) from public.v_users')->fetchColumn()===2];$db->rollBack();
 echo json_encode($out,JSON_THROW_ON_ERROR);exit;
}
if($mode==='lock_timeout'){
 $other=new PDO('pgsql:host='.$root.'/socket;port=55484;dbname=postgres','postgres',null,[PDO::ATTR_ERRMODE=>PDO::ERRMODE_EXCEPTION]);$other->beginTransaction();$other->exec('lock table public.v_users in access exclusive mode');
 $start=microtime(true);$sample=welcome_inventory_sample($db);$elapsed=microtime(true)-$start;$other->rollBack();
 echo json_encode(['sample_unavailable'=>$sample===null,'bounded'=>$elapsed<3.5,'own_transaction_closed'=>!$db->inTransaction(),'timeouts_restored'=>$timeoutBefore===$db->query('show statement_timeout')->fetchColumn()&&$lockBefore===$db->query('show lock_timeout')->fetchColumn()],JSON_THROW_ON_ERROR);exit;
}
$publicAfter=welcome_public_fingerprint($db);$configAfter=$publicAfter===$state['public_before']?hash_file('sha256',$configFile):null;
if($mode==='failure_unstable')$db->exec("insert into public.v_user_logs values(9,'changed after original check')");
if($mode==='sample_unavailable')$db->beginTransaction();
$observed=welcome_inventory_failure($db,$state,$configFile,$publicAfter,$configAfter);
if($mode==='sample_unavailable')$db->rollBack();
$out=['observation'=>$observed,'baseline_state'=>$state['public_observation_before']['state'],'own_transaction_closed'=>!$db->inTransaction(),'timeouts_restored'=>$timeoutBefore===$db->query('show statement_timeout')->fetchColumn()&&$lockBefore===$db->query('show lock_timeout')->fetchColumn()];
if(in_array($mode,['row','config','original_primary','success'],true)){
 $begin=strpos($source,"if(\$action==='cleanup'){");$end=strpos($source,"\n// This narrow test double",$begin);if($begin===false||$end===false)throw new RuntimeException('Actual cleanup required.');$action='cleanup';$welcomeInventory=null;
 try{eval(substr($source,$begin,$end-$begin));throw new RuntimeException('Expected original refusal.');}
 catch(Throwable $e){$out['original_error_exact']=get_class($e)==='RuntimeException'&&$e->getMessage()==='The original instance inventory changed.';$out['owned_schema_removed']=$db->query("select to_regnamespace('owned_welcome_observer') is null")->fetchColumn()===true;$out['observation']=$welcomeInventory??null;}
}
echo json_encode($out,JSON_THROW_ON_ERROR);
'''


class InventoryPostgres(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.root=Path(tempfile.mkdtemp(prefix='openweb-welcome-observer-')); cls.started=False
        owner=pwd.getpwnam('postgres');os.chown(cls.root,owner.pw_uid,owner.pw_gid)
        cls.addClassCleanup(cls.cleanup)
        cls.pg('initdb','-D',str(cls.root/'data'),'--auth-local=trust','--auth-host=reject','--no-locale','-E','UTF8')
        socket=cls.root/'socket';socket.mkdir(mode=0o700);os.chown(socket,owner.pw_uid,owner.pw_gid)
        cls.pg('pg_ctl','-D',str(cls.root/'data'),'-l',str(cls.root/'postgres.log'),'-o',f"-k {socket} -p 55484 -c listen_addresses='' -c unix_socket_permissions=0700 -c max_connections=8 -c shared_buffers=16MB",'-w','start');cls.started=True
        cls.driver=cls.root/'driver.php';cls.driver.write_text(PHP_DRIVER)

    @classmethod
    def pg(cls,name,*args):
        p=subprocess.run(['runuser','-u','postgres','--',str(PG/name),*args],capture_output=True,timeout=30)
        if p.returncode:raise AssertionError('Owned fixture PostgreSQL refused.')

    @classmethod
    def cleanup(cls):
        if cls.started:cls.pg('pg_ctl','-D',str(cls.root/'data'),'-m','fast','-w','stop');cls.started=False
        shutil.rmtree(cls.root)

    def run_case(self,mode,source=None):
        payload={'cluster':str(self.root),'source':str(source or HERE/'windows_welcome_native.php'),'helper':str(HERE/'windows_welcome_inventory.php'),'mode':mode}
        p=subprocess.run(['php',str(self.driver)],input=json.dumps(payload),text=True,capture_output=True,timeout=10)
        self.assertEqual(0,p.returncode,p.stderr);self.assertNotIn(SECRET,p.stdout)
        result=json.loads(p.stdout)
        if 'observation'in result and result['observation'] is not None:self.assertEqual(result['observation'],w.welcome_inventory_fields(result['observation']))
        return result

    def test_actual_same_count_row_and_config_refusals_keep_original_cleanup(self):
        row=self.run_case('row');self.assertTrue(row['original_error_exact']);self.assertTrue(row['owned_schema_removed'])
        self.assertEqual(record(),row['observation'])
        config=self.run_case('config');self.assertTrue(config['original_error_exact']);self.assertTrue(config['owned_schema_removed'])
        self.assertTrue(config['observation']['public_equal']);self.assertFalse(config['observation']['config_equal']);self.assertEqual('original',config['observation']['config_check']);self.assertEqual(0,config['observation']['changed_tables'])
        self.assertTrue(row['timeouts_restored'] and config['timeouts_restored'])

    def test_catalog_unknown_names_counts_only_and_no_digests(self):
        r=self.run_case('catalog')['observation'];self.assertEqual((2,1,1,1),(r['changed_tables'],r['added_tables'],r['removed_tables'],r['unlisted_tables']))
        self.assertEqual([dict(name='v_users',before=1,after=0,kind='removed')],r['tables'])
        self.assertNotIn('private_unknown',json.dumps(r));self.assertNotIn('sha256',json.dumps(r))

    def test_real_baseline_and_later_instability_do_not_infer_tables(self):
        for mode,key in [('baseline_unstable','baseline_state'),('failure_unstable','sample_state')]:
            with self.subTest(mode=mode):
                r=self.run_case(mode)['observation'];self.assertEqual('unstable',r[key]);self.assertFalse(r['public_equal']);self.assertEqual([],r['tables']);self.assertEqual(0,r['changed_tables'])

    def test_sampler_unavailable_and_real_statement_lock_deadline_restore_session(self):
        for mode in ('sample_unavailable','oversized'):
            with self.subTest(mode=mode):
                r=self.run_case(mode);self.assertEqual('unavailable',r['observation']['sample_state']);self.assertTrue(r['own_transaction_closed'] and r['timeouts_restored'])
        self.assertTrue(all(self.run_case('lock_timeout').values()))
        self.assertTrue(all(self.run_case('outer_transaction').values()))

    def test_success_outputs_only_original_strict_cleanup_receipt(self):
        self.assertEqual(dict(state='cleaned',public_exact=True,config_exact=True,owned_schema_removed=True,only_owned_locks_removed=True),self.run_case('success'))

    def test_actual_terminal_handler_and_python_child_preserve_failure_only_fields(self):
        source=(HERE/'windows_welcome_native.php').read_text()
        handler=source[source.index("$phase='input';"):source.index("$action=$argv")]
        cleanup=source[source.index("if($action==='cleanup'){"):source.index('\n// This narrow test double')]
        prelude=PHP_DRIVER[:PHP_DRIVER.index("$out=['observation'")]
        child=self.root/'windows_welcome_native.php'
        child.write_text('<?php\n'+handler+prelude.removeprefix('<?php\n')+"\n$action='cleanup';\n"+cleanup)
        payload=dict(cluster=str(self.root),helper=str(HERE/'windows_welcome_inventory.php'),source=str(HERE/'windows_welcome_native.php'),mode='row')
        p=subprocess.run(['php',str(child)],input=json.dumps(payload),text=True,capture_output=True,timeout=10)
        self.assertEqual(1,p.returncode);self.assertEqual('',p.stderr);self.assertNotIn(SECRET,p.stdout)
        failure=json.loads(p.stdout);self.assertEqual('cleanup',failure['phase']);self.assertEqual('RuntimeException',failure['error_type']);self.assertEqual('windows_welcome_native.php',failure['source_basename']);self.assertEqual(record(),failure['welcome_cleanup_inventory']);self.assertLess(len(p.stdout),2048)
        fn=next(n for n in ast.parse((HERE/'windows_welcome_native.py').read_text()).body if isinstance(n,ast.FunctionDef)and n.name=='run_fixture')
        operation=copy.deepcopy(next(n for n in fn.body if isinstance(n,ast.FunctionDef)and n.name=='operation'))
        wrapper=ast.parse('def wrapper():\n serial=0\n pass\n return operation\n').body[0];wrapper.body[1]=operation
        ns=dict(vars(w),base=['explicit-php','explicit-helper'],input_path=Path('explicit-input'),work=self.root,tail=['--portable-socket-factory'],source=HERE)
        exec(compile(ast.fix_missing_locations(ast.Module(body=[wrapper],type_ignores=[])),str(HERE/'windows_welcome_native.py'),'exec'),ns)
        for mode in ('failure','success','wrong_phase','wrong_action','zero_return_stderr','malformed','oversized','observer_throws'):
            data=copy.deepcopy(failure)
            if mode=='wrong_phase':data['phase']='inspect'
            if mode=='malformed':data['welcome_cleanup_inventory']['message']=SECRET
            output=(json.dumps(data)+'\n').encode()
            if mode=='oversized':output=b' '*2049+output
            if mode=='success':output=b'{"state":"cleaned"}'
            action='inspect'if mode=='wrong_action'else'cleanup'
            result=subprocess.CompletedProcess([],0 if mode in ('success','zero_return_stderr')else 1,output,b'private child stderr'if mode=='zero_return_stderr'else b'')
            observer=ns['welcome_inventory_fields'];calls=[]
            def child_adapter(*args,**kw):calls.append((args,kw));return result
            def refuse(_):raise OSError(SECRET)
            if mode=='observer_throws':ns['welcome_inventory_fields']=refuse
            with self.subTest(mode=mode),patch.object(w.subprocess,'run',child_adapter):
                if mode=='success':self.assertEqual({'state':'cleaned'},ns['wrapper']()(action,'argument'))
                else:
                    with self.assertRaises(RuntimeError)as caught:ns['wrapper']()(action,'argument')
                    self.assertEqual('The private PHP welcome operation failed: '+action,str(caught.exception))
                    fields=getattr(caught.exception,'welcome_failure',{})
                    self.assertEqual(mode=='failure','welcome_cleanup_inventory'in fields);self.assertNotIn(SECRET,json.dumps(fields))
            ns['welcome_inventory_fields']=observer
            self.assertEqual([((['explicit-php','explicit-helper',action,'explicit-input',str(self.root),'argument','--portable-socket-factory'],),dict(cwd=HERE,capture_output=True,timeout=45))],calls)

    def test_missing_or_failed_baseline_observation_never_replaces_original_check(self):
        source=(HERE/'windows_welcome_native.php').read_text()
        begin=source.index(" try{if(function_exists('welcome_inventory_baseline'))")
        baseline=source[begin:source.index('\n',begin)]
        for mode,definition in [('missing',''),('throws',"function welcome_inventory_baseline($db,$hash){throw new RuntimeException('private observer');}"),('unavailable',"function welcome_inventory_baseline($db,$hash){return ['state'=>'unavailable'];}")]:
            body='<?php '+definition+";$state=['public_before'=>'original'];$db=null;"+baseline+";echo json_encode(['original_retained'=>$state['public_before']==='original','continued'=>true]);"
            p=subprocess.run(['php'],input=body,text=True,capture_output=True,timeout=5)
            with self.subTest(mode=mode):self.assertEqual(0,p.returncode);self.assertEqual(dict(original_retained=True,continued=True),json.loads(p.stdout))


class ProjectionAndPrimary(unittest.TestCase):
    def test_actual_original_python_check_location_and_primary_only_identity(self):
        source=(HERE/'windows_welcome_native.py').read_text();tree=ast.parse(source)
        fn=next(n for n in tree.body if isinstance(n,ast.FunctionDef)and n.name=='run_fixture')
        check=copy.deepcopy(next(n for n in fn.body if isinstance(n,ast.FunctionDef)and n.name=='check'))
        call=copy.deepcopy(next(n for n in ast.walk(fn)if isinstance(n,ast.Expr)and isinstance(n.value,ast.Call)and isinstance(n.value.func,ast.Name)and n.value.func.id=='check'and len(n.value.args)>1 and isinstance(n.value.args[1],ast.Constant)and n.value.args[1].value=='The concurrent welcome dispatch was not singular.'))
        wrapper=ast.parse('def run_fixture():\n checks=0\n pass\n pass\n').body[0];wrapper.body[1:]=[check,call]
        ns={'sink':types.SimpleNamespace(deliveries=[])}
        exec(compile(ast.fix_missing_locations(ast.Module(body=[wrapper],type_ignores=[])),str(HERE/'windows_welcome_native.py'),'exec'),ns)
        try:ns['run_fixture']()
        except RuntimeError as caught:primary=caught
        self.assertEqual(dict(schema=1,error_type='RuntimeError',source_basename='windows_welcome_native.py',source_line=call.lineno),w.welcome_primary_fields(primary))
        block=next(n for n in fn.body if isinstance(n,ast.If)and isinstance(n.test,ast.Name)and n.test.id=='primary')
        with self.assertRaises(RuntimeError)as caught:exec(compile(ast.Module(body=[block],type_ignores=[]),'<actual-original-primary>','exec'),{'primary':primary})
        self.assertIs(primary,caught.exception);self.assertFalse(hasattr(primary,'welcome_failure'))

    def test_closed_record_types_names_bounds_and_secrets(self):
        good=record();self.assertEqual(good,w.welcome_inventory_fields(good))
        for key in good:
            for bad in (None,SECRET,{},True,1.5):
                if type(good[key])is bool and bad is True:continue
                with self.subTest(key=key,bad=bad):self.assertEqual({},w.welcome_inventory_fields(good|{key:bad}))
            self.assertEqual({},w.welcome_inventory_fields({k:v for k,v in good.items() if k!=key}))
        self.assertEqual({},w.welcome_inventory_fields(good|{'message':SECRET}))
        for change in ({'name':SECRET},{'before':True},{'after':1000001},{'kind':SECRET},{'message':SECRET}):
            self.assertEqual({},w.welcome_inventory_fields(good|{'tables':[good['tables'][0]|change]}))
        self.assertEqual({},w.welcome_inventory_fields(good|{'tables':good['tables']*2,'changed_tables':2}))
        self.assertEqual({},w.welcome_inventory_fields(good|{'sample_state':'unavailable'}))

    def test_actual_final_cleanup_wrap_preserves_primary_and_cause(self):
        tree=ast.parse((HERE/'windows_welcome_native.py').read_text());fn=next(n for n in tree.body if isinstance(n,ast.FunctionDef) and n.name=='run_fixture')
        block=next(n for n in fn.body if isinstance(n,ast.If) and isinstance(n.test,ast.Name) and n.test.id=='cleanup_error')
        for mode in ('normal','php_primary','primary_observer_throws','inventory_observer_throws','no_primary'):
            try:exec(compile("raise RuntimeError('"+SECRET+"')",str(HERE/'windows_welcome_native.py'),'exec'))
            except RuntimeError as error:primary=error
            cleanup=RuntimeError('cleanup original');cleanup.welcome_failure={'welcome_phase':'cleanup','welcome_cleanup_inventory':record()}
            if mode=='php_primary':primary.welcome_failure={'welcome_phase':'inspect'}
            ns=dict(vars(w),primary=None if mode=='no_primary' else primary,cleanup_error=cleanup)
            def refuse(*args):raise OSError(SECRET)
            if mode=='primary_observer_throws':ns['welcome_primary_fields']=refuse
            if mode=='inventory_observer_throws':ns['welcome_inventory_fields']=refuse
            with self.subTest(mode=mode),self.assertRaises(RuntimeError)as caught:exec(compile(ast.Module(body=[block],type_ignores=[]),str(HERE/'windows_welcome_native.py'),'exec'),ns)
            self.assertEqual('The welcome fixture cleanup requires review.',str(caught.exception));self.assertIs(cleanup,caught.exception.__cause__)
            fields=caught.exception.welcome_failure;self.assertTrue(fields['welcome_cleanup_failed']);self.assertNotIn(SECRET,json.dumps(fields))
            self.assertEqual(mode not in ('primary_observer_throws','no_primary'),'welcome_primary'in fields)
            if mode=='php_primary':self.assertEqual('inspect',fields['welcome_phase']);self.assertEqual(record(),fields['welcome_cleanup_inventory'])


if __name__=='__main__':unittest.main()
