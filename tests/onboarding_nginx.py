"""Actual fresh configuration function and native Nginx syntax; no live writes."""
import ast
from pathlib import Path
import re
import subprocess
import tempfile

root=Path(__file__).resolve().parents[1]
module=ast.parse((root/'packaging/debian/configure.py').read_text())
function=next(n for n in module.body if isinstance(n,ast.FunctionDef)and n.name=='managed_nginx_configuration')
namespace={'re':re};exec(compile(ast.Module(body=[function],type_ignores=[]),str(root/'packaging/debian/configure.py'),'exec'),namespace)
configure=namespace[function.name];checks=0
def check(ok,message):
 global checks
 assert ok,message;checks+=1

base='http {\n # server_names_hash_bucket_size 64;\n}\n'
check('server_names_hash_bucket_size 128;'in configure(base),'Fresh default capacity increased')
for value in [128,256,512]:
 text='http {\n server_names_hash_bucket_size '+str(value)+';\n}\n';check(configure(text)==text,'Larger operator choice retained')
small='http {\n server_names_hash_bucket_size 32;\n}\n';check('server_names_hash_bucket_size 128;'in configure(small),'Small explicit capacity increased')
check(configure(configure(base))==configure(base),'Repeated configuration remains exact')
for text in ['events {}','http {\nserver_names_hash_bucket_size 64;\nserver_names_hash_bucket_size 128;\n}']:
 try:configure(text)
 except RuntimeError:check(True,'Ambiguous configuration refused')
 else:raise AssertionError('Ambiguous configuration accepted')
with tempfile.TemporaryDirectory(prefix='openweb-onboarding-nginx-')as temporary:
 p=Path(temporary);config=p/'nginx.conf';name='node-0123456789abcdef0123456789abcdef.openwebpbx.com'
 text='pid '+str(p/'nginx.pid')+';\nerror_log stderr;\nevents {}\nhttp {\nserver_names_hash_bucket_size 64;\naccess_log off;\nserver {listen 127.0.0.1:39871; server_name '+name+'; return 404;}\nserver {listen 127.0.0.1:39871; server_name second.example.test; return 404;}\n}\n'
 config.write_text(text)
 before=subprocess.run(['nginx','-t','-p',str(p),'-c',str(config)],capture_output=True)
 check(before.returncode!=0 and b'server_names_hash_bucket_size'in before.stderr,'Actual native default refuses full installation identity')
 config.write_text(configure(text));after=subprocess.run(['nginx','-t','-p',str(p),'-c',str(config)],capture_output=True)
 check(after.returncode==0,'Actual native Nginx accepts managed canonical host')
print('PASS',checks,'fresh configuration and native Nginx controls')
