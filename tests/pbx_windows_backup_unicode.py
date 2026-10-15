"""UTF-8 backup SQL transport with real subprocesses and isolated PostgreSQL.

PortableTransport also runs under the installed Windows Python during native
backup qualification. Its child checks native argv and consumes actual stdin.
The CP1252 regression is explicitly modelled on Linux, not Windows evidence.
"""
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT=Path(__file__).resolve().parents[1]
spec=importlib.util.spec_from_file_location('unicode_backups',ROOT/'packaging/windows/backups.py')
b=importlib.util.module_from_spec(spec);spec.loader.exec_module(b)
PRIVATE='Fictional private SQL marker \u6f22\U0001f642'
MESSAGE='Local backup completed. The SFTP copy failed; see this backup\u2019s status.'
PREAMBLE='SET standard_conforming_strings=on;\n'
OLD_QUERY='''def old_query(settings, sql, *, json_result=False):
    result = run(database_command(settings) + ['-X', '-q', '-A', '-t', '-v', 'ON_ERROR_STOP=1', '-c', 'SET standard_conforming_strings=on;\\n'+sql],
                 env=database_environment(settings), timeout=60).decode().strip()
    return json.loads(result) if json_result else result
'''


class PortableTransport(unittest.TestCase):
    def test_query_native_argv_contains_no_sql_and_child_consumes_exact_utf8(self):
        sql='select '+b.literal(MESSAGE+' '+PRIVATE);expected=(PREAMBLE+sql).encode('utf-8');original=b.run;calls=[]
        settings={'database.0.username':'fictional','database.0.name':'fictional','database.0.password':PRIVATE}
        child='''import hashlib,json,sys
data=sys.stdin.buffer.read()
assert "-c" not in sys.argv[1:] and sys.argv[-2:]==["-f","-"]
assert "--single-transaction" in sys.argv[1:] and "ON_ERROR_STOP=1" in sys.argv[1:]
assert all(argument.isascii() for argument in sys.argv[1:])
assert not any("standard_conforming_strings" in argument or "SFTP copy" in argument for argument in sys.argv[1:])
data.decode("utf-8")
sys.stdout.write(json.dumps({"sha256":hashlib.sha256(data).hexdigest()}))
'''
        def boundary(command,*,env,timeout,input=None):
            self.assertEqual(input,expected);self.assertEqual(env['PGCLIENTENCODING'],'UTF8');self.assertEqual(timeout,60)
            self.assertNotIn(PRIVATE,command);calls.append(command)
            return original([sys.executable,'-I','-c',child,*command[1:]],env=env,timeout=timeout,input=input)
        import hashlib
        with patch.object(b,'run',side_effect=boundary):result=b.query(settings,sql,json_result=True)
        self.assertEqual(result,{'sha256':hashlib.sha256(expected).hexdigest()});self.assertEqual(len(calls),1)
    def test_other_run_calls_keep_exact_subprocess_keywords_and_result(self):
        environment={'private':'fixture'};result=subprocess.CompletedProcess(['fixture'],0,b'exact\0output',b'private')
        with patch.object(b.subprocess,'run',return_value=result) as delegate:
            self.assertIs(b.run(['fixture'],env=environment,timeout=27),result.stdout)
        delegate.assert_called_once_with(['fixture'],env=environment,stdout=subprocess.PIPE,stderr=subprocess.PIPE,timeout=27)
        with patch.object(b.subprocess,'run',return_value=result) as delegate:b.run(['fixture'],input=b'bounded bytes')
        self.assertEqual(delegate.call_args.kwargs['input'],b'bounded bytes')
    def test_actual_input_failure_timeout_and_unavailable_tool_messages_stay_private(self):
        payload=(PRIVATE+MESSAGE).encode('utf-8')
        actual=b.run([sys.executable,'-I','-c','import sys;sys.stdout.buffer.write(sys.stdin.buffer.read())'],input=payload,timeout=10)
        self.assertEqual(actual,payload)
        with tempfile.TemporaryDirectory(prefix='backup-missing-tool-') as temporary:
            for command,timeout in [([sys.executable,'-I','-c','import sys;sys.stderr.buffer.write(sys.stdin.buffer.read());sys.exit(7)'],10),
                ([sys.executable,'-I','-c','import time;time.sleep(5)'],.05),([str(Path(temporary)/'absent-tool')],10)]:
                with self.assertRaises(b.BackupError) as failure:b.run(command,input=payload,timeout=timeout)
                self.assertNotIn(PRIVATE,str(failure.exception));self.assertNotIn(MESSAGE,str(failure.exception))
    def test_child_environment_explicit_utf8_without_parent_change(self):
        with patch.dict(os.environ,{'PGCLIENTENCODING':'WIN1252','OPENWEB_UNICODE_TEST':'preserved'}):
            child=b.database_environment({'database.0.password':PRIVATE})
            self.assertEqual(child['PGCLIENTENCODING'],'UTF8');self.assertEqual(child['PGPASSWORD'],PRIVATE)
            self.assertEqual(child['OPENWEB_UNICODE_TEST'],'preserved');self.assertEqual(os.environ['PGCLIENTENCODING'],'WIN1252')


@unittest.skipIf(os.name=='nt','The separate native SYSTEM backup task proves actual Windows PostgreSQL.')
class PostgreSQLTransport(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        import pwd
        cls.pg=Path('/usr/lib/postgresql/18/bin');cls.work=Path(tempfile.mkdtemp(prefix='openweb-backup-unicode-'))
        owner=pwd.getpwnam('postgres');os.chown(cls.work,owner.pw_uid,owner.pw_gid);cls.work.chmod(0o700)
        cls.data=cls.work/'data';cls.socket=cls.work/'socket';cls.socket.mkdir();os.chown(cls.socket,owner.pw_uid,owner.pw_gid)
        cls.started=False
        try:
            cls.admin('initdb','-D',str(cls.data),'-A','trust','-U','fixture','--no-locale','--encoding=UTF8')
            cls.admin('pg_ctl','-D',str(cls.data),'-l',str(cls.work/'server-private.log'),'-o',"-k "+str(cls.socket)+" -p 55439 -c listen_addresses=''",'-w','start');cls.started=True
            cls.settings={'database.0.type':'pgsql','database.0.host':str(cls.socket),'database.0.port':'55439','database.0.username':'fixture','database.0.name':'postgres'}
            cls.tools=patch.object(b,'tool',side_effect=lambda name:str(cls.pg/name));cls.tools.start()
            b.query(cls.settings,'create table fixture(id integer primary key,value text);create table protected(value text);insert into protected values(\'original\')')
        except BaseException:
            cls.tearDownClass();raise
    @classmethod
    def admin(cls,tool,*arguments):
        result=subprocess.run(['runuser','-u','postgres','--',str(cls.pg/tool),*arguments],capture_output=True,timeout=30)
        if result.returncode:raise RuntimeError('An isolated PostgreSQL Unicode control failed.')
        return result.stdout
    @classmethod
    def tearDownClass(cls):
        try:
            if hasattr(cls,'tools'):cls.tools.stop()
            if cls.started:cls.admin('pg_ctl','-D',str(cls.data),'-m','fast','-w','stop')
        finally:shutil.rmtree(cls.work)
    def test_actual_nonascii_message_and_multilingual_value_round_trip(self):
        value=MESSAGE+' '+PRIVATE+' \\ backslash and apostrophe\''
        b.query(self.settings,'insert into fixture values(1,'+b.literal(value)+')')
        self.assertEqual(b.query(self.settings,'select value from fixture where id=1'),value)
        self.assertEqual(b.query(self.settings,'select json_build_object(\'value\',value) from fixture where id=1',json_result=True),{'value':value})
        self.assertEqual(b.query(self.settings,'show standard_conforming_strings'),'on')
    def test_failed_second_statement_rolls_back_entire_batch_and_stops_before_third(self):
        with self.assertRaises(b.BackupError):b.query(self.settings,"insert into fixture values(2,'must rollback');select 1/0;delete from protected")
        self.assertEqual(b.query(self.settings,'select count(*) from fixture where id=2'),'0')
        self.assertEqual(b.query(self.settings,'select value from protected'),'original')
    def test_explicit_begin_commit_compatible_and_transaction_failure_recovers(self):
        b.query(self.settings,'BEGIN;insert into fixture values(3,'+b.literal(PRIVATE)+');COMMIT;')
        self.assertEqual(b.query(self.settings,'select value from fixture where id=3'),PRIVATE)
        with self.assertRaises(b.BackupError):b.query(self.settings,"BEGIN;update protected set value='must rollback';select 1/0;COMMIT;")
        self.assertEqual(b.query(self.settings,'select value from protected'),'original')
    def test_legacy_cp1252_argv_negative_and_utf8_stdin_positive_same_real_server(self):
        old={name:getattr(b,name) for name in ('run','database_command','database_environment')};old['json']=json
        exec(compile(OLD_QUERY,'legacy-backup-query.py','exec'),old)
        actual=subprocess.run;observed=[]
        def windows_argv_boundary(command,*arguments,**keywords):
            # Explicit POSIX modelling of a Windows narrow-argv conversion.
            transformed=[argument.encode('cp1252') if isinstance(argument,str) and not argument.isascii() else argument for argument in command]
            observed.append({'nonascii_argv':any(isinstance(argument,bytes) for argument in transformed),'stdin':isinstance(keywords.get('input'),bytes)})
            return actual(transformed,*arguments,**keywords)
        statement='select '+b.literal(MESSAGE)
        with patch.object(b.subprocess,'run',side_effect=windows_argv_boundary):
            with self.assertRaises(b.BackupError):old['old_query'](self.settings,statement)
            self.assertEqual(b.query(self.settings,statement),MESSAGE)
        self.assertEqual(observed,[{'nonascii_argv':True,'stdin':False},{'nonascii_argv':False,'stdin':True}])


if __name__=='__main__':unittest.main()
