#!/usr/bin/env python3
"""Fresh Debian configuration. Never prints credentials or overwrites another PBX."""
import argparse,getpass,importlib.util,json,os,pathlib,re,secrets,shutil,subprocess,time
P=pathlib.Path
parser=argparse.ArgumentParser()
parser.add_argument('--domain',required=True)
parser.add_argument('--address',default='')
parser.add_argument('--email',required=True)
parser.add_argument('--certificate');parser.add_argument('--certificate-key')
parser.add_argument('--local-certificate',action='store_true')
parser.add_argument('--secrets-file',help='Private JSON containing AdminPassword; otherwise prompt securely')
a=parser.parse_args()
if not re.fullmatch(r'[a-zA-Z0-9.-]+',a.domain) or not re.fullmatch(r'[^@\s]+@[^@\s]+\.[^@\s]+',a.email):parser.error('Enter a valid server name and email.')
if not a.local_certificate and not(a.certificate and a.certificate_key):parser.error('Supply a certificate and key, or choose --local-certificate for testing.')
if P('/etc/fusionpbx/config.conf').exists():parser.error('An existing PBX configuration is present.')
password=json.loads(P(a.secrets_file).read_text())['AdminPassword'] if a.secrets_file else getpass.getpass('Administrator password: ')
if len(password)<8:parser.error('Use a password with at least eight characters.')
root=P('/var/www/fusionpbx');private=P('/var/lib/openwebpbx');cfg=P('/etc/fusionpbx')
def run(args,**kw):subprocess.run(args,check=True,**kw)
def write(path,text,mode=0o640,owner=0,group=33):
 p=P(path);p.parent.mkdir(parents=True,exist_ok=True);p.write_text(text);p.chmod(mode);os.chown(p,owner,group)
# Confirm the local database before copying application files or saving secrets.
clusters=subprocess.check_output(['pg_lsclusters','--no-header'],text=True).splitlines()
if not clusters:raise RuntimeError('The built-in PostgreSQL database is unavailable. Setup has not changed the PBX.')
version,cluster,dbport,*_=clusters[0].split()
run(['systemctl','start',f'postgresql@{version}-{cluster}'])
for attempt in range(30):
 if subprocess.run(['pg_isready','-h','127.0.0.1','-p',dbport,'-t','2'],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL).returncode==0:break
 time.sleep(2)
else:raise RuntimeError('The built-in database did not become ready. Setup has not changed the PBX.')
admin_sql=['runuser','-u','postgres','--','psql','-h','/var/run/postgresql','-p',dbport,'-U','postgres','-d','postgres','-X','-w','-v','ON_ERROR_STOP=1']
existing=subprocess.check_output(admin_sql+['-Atc',"select exists(select 1 from pg_roles where rolname='fusionpbx') or exists(select 1 from pg_database where datname='fusionpbx')"],text=True).strip()
if existing!='f':raise RuntimeError('An existing PBX database or account is present. This fresh installer will not overwrite it.')
for d in [private,cfg,P('/etc/openwebpbx')]:d.mkdir(parents=True,exist_ok=True);d.chmod(0o750);os.chown(d,0,33)
write(private/'setup-secrets.json',json.dumps({'AdminEmail':a.email,'AdminPassword':password}),0o600,0,0);del password
run(['tar','-xzf','engine.tar.gz','-C','/']);run(['ldconfig'])
shutil.copytree('web',root,dirs_exist_ok=True)
shutil.copytree('server','/opt/openwebpbx/service',dirs_exist_ok=True)
for path in [*root.rglob('*'),*P('/opt/openwebpbx/service').rglob('*')]:
 if path.is_dir():path.chmod(0o755)
 else:path.chmod(0o644)
P('/opt/openwebpbx/service/OpenWebPbx.Server').chmod(0o755)
P('/run/php').mkdir(parents=True,exist_ok=True)
run(['systemctl','daemon-reload'])
dbpass=secrets.token_hex(32);switchpass=secrets.token_hex(32)
run(admin_sql+['-q'],input=f"CREATE ROLE fusionpbx LOGIN PASSWORD '{dbpass}';\nCREATE DATABASE fusionpbx OWNER fusionpbx;\n",text=True,stdout=subprocess.DEVNULL)
connected=subprocess.check_output(['psql','-h','127.0.0.1','-p',dbport,'-U','fusionpbx','-d','fusionpbx','-X','-w','-v','ON_ERROR_STOP=1','-Atc','select current_database()'],env=os.environ|{'PGPASSWORD':dbpass},text=True).strip()
if connected!='fusionpbx':raise RuntimeError('The application could not connect to its built-in database. Setup has not completed.')
settings={'database.0.type':'pgsql','database.0.host':'127.0.0.1','database.0.port':dbport,'database.0.name':'fusionpbx','database.0.username':'fusionpbx','database.0.password':dbpass,'database.1.type':'sqlite','database.1.name':'core.db','database.1.path':'/var/lib/freeswitch/db','document.root':str(root),'project.path':'','temp.dir':'/var/tmp','php.dir':'/usr/bin','php.bin':'php','cache.method':'file','cache.location':'/var/cache/fusionpbx','cache.settings':'true','session.cookie_secure':'true','session.cookie_httponly':'true','session.cookie_samesite':'Lax','switch.conf.dir':'/etc/freeswitch','switch.sounds.dir':'/usr/share/freeswitch/sounds','switch.database.dir':'/var/lib/freeswitch/db','switch.storage.dir':'/var/lib/freeswitch/storage','switch.voicemail.dir':'/var/lib/freeswitch/storage/voicemail','switch.recordings.dir':'/var/lib/freeswitch/recordings','switch.scripts.dir':'/usr/share/freeswitch/scripts','switch.event_socket.host':'127.0.0.1','switch.event_socket.port':'8021','switch.event_socket.password':switchpass,'xml_handler.fs_path':'false','xml_handler.reg_as_number_alias':'false','xml_handler.number_as_presence_id':'true','openweb.public_host':a.domain,'openweb.public_url':'https://'+a.domain,'openweb.public_ip':a.address}
write(cfg/'config.conf','\n'.join(f'{k} = {v}' for k,v in settings.items())+'\n')
key=cfg/'openweb-template.key';key.write_bytes(secrets.token_bytes(32));key.chmod(0o640);os.chown(key,0,33)
for path in ['/usr/share/freeswitch/scripts','/etc/freeswitch/languages','/var/cache/fusionpbx','/var/lib/freeswitch/db','/var/lib/freeswitch/storage/voicemail','/var/lib/freeswitch/recordings','/var/log/freeswitch','/var/run/freeswitch',str(private/'uploads')]:
 p=P(path);p.mkdir(parents=True,exist_ok=True);p.chmod(0o750);os.chown(p,33,33)
env=os.environ|{'OPENWEB_SETUP_SECRETS':str(private/'setup-secrets.json')}
bootstrap=str(P('bootstrap.php').resolve())
with open(private/'install.log','w') as log:
 os.chmod(log.name,0o600)
 def php(*args):run(['php',*args],cwd=root,env=env,stdout=log,stderr=subprocess.STDOUT)
 php('core/upgrade/upgrade_schema.php');php(bootstrap,str(root),'domain')
 for step in ['--defaults','--group','--menu']:php('core/upgrade/upgrade.php',step)
 php(bootstrap,str(root),'migrate');php(bootstrap,str(root),'admin')
shutil.copytree(root/'app/switch/resources/conf','/etc/freeswitch',dirs_exist_ok=True)
shutil.copytree(root/'app/switch/resources/scripts','/usr/share/freeswitch/scripts',dirs_exist_ok=True)
shutil.copytree(root/'app/pbx_setup/resources/switch/scripts','/usr/share/freeswitch/scripts',dirs_exist_ok=True)
shutil.copytree(root/'app/pbx_setup/resources/prompts','/usr/share/freeswitch/sounds/openwebpbx',dirs_exist_ok=True)
shutil.copy(root/'app/pbx_setup/resources/prompts/openweb.xml','/etc/freeswitch/languages/en/ivr/openweb.xml')
import xml.etree.ElementTree as ET
modules=P('/etc/freeswitch/autoload_configs/modules.conf.xml');doc=ET.parse(modules)
if not any(n.get('module')=='mod_pgsql' for n in doc.findall('./modules/load')):doc.find('./modules').insert(0,ET.Element('load',{'module':'mod_pgsql'}))
doc.write(modules)
write('/etc/freeswitch/autoload_configs/event_socket.conf.xml',f'<configuration name="event_socket.conf"><settings><param name="listen-ip" value="127.0.0.1"/><param name="listen-port" value="8021"/><param name="password" value="{switchpass}"/></settings></configuration>')
write('/etc/openwebpbx/runtime.json',json.dumps({'ConnectionStrings':{'Pbx':f'Host=127.0.0.1;Port={dbport};Database=fusionpbx;Username=fusionpbx;Password={dbpass}'},'Switch':{'Host':'127.0.0.1','Port':8021,'Password':switchpass}}))
for d in ['/etc/freeswitch','/usr/share/freeswitch','/var/lib/freeswitch']:run(['chown','-R','www-data:www-data',d])
if a.local_certificate:
 a.certificate=str(cfg/'local-test.crt');a.certificate_key=str(cfg/'local-test.key')
 run(['openssl','req','-x509','-newkey','rsa:3072','-nodes','-keyout',a.certificate_key,'-out',a.certificate,'-days','365','-subj','/CN='+a.domain,'-addext','subjectAltName=DNS:'+a.domain],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
 os.chmod(a.certificate_key,0o600)
for path in [a.certificate,a.certificate_key]:
 if not P(path).is_file():raise RuntimeError('Certificate file is unavailable')
 if any(c in str(path) for c in ['\n','\r',';','"']):raise RuntimeError('Invalid certificate path')
nginx=P('nginx.conf').read_text().replace('@DOMAIN@',a.domain).replace('@CERT@',str(a.certificate)).replace('@KEY@',str(a.certificate_key))
write('/etc/nginx/sites-available/openwebpbx',nginx,0o644)
P('/etc/nginx/sites-enabled/default').unlink(missing_ok=True)
P('/etc/nginx/sites-enabled/openwebpbx').symlink_to('/etc/nginx/sites-available/openwebpbx')
write('/etc/php/8.4/fpm/conf.d/99-openwebpbx.ini','upload_max_filesize=2048M\npost_max_size=2060M\nmax_execution_time=600\nmax_input_time=600\nmemory_limit=512M\n',0o644)
for service in ['freeswitch','openwebpbx']:shutil.copy(service+'.service','/etc/systemd/system/'+service+'.service')
write('/etc/cron.d/openwebpbx','17 * * * * www-data /usr/bin/php /var/www/fusionpbx/app/pbx_setup/cleanup.php >/dev/null 2>&1\n',0o644)
run(['nginx','-t']);run(['systemctl','daemon-reload']);run(['systemctl','enable','--now','freeswitch','openwebpbx','nginx','php8.4-fpm']);run(['systemctl','restart','php8.4-fpm','nginx'])
(private/'setup-secrets.json').unlink()
import urllib.request
for attempt in range(30):
 try:
  with urllib.request.urlopen('http://127.0.0.1:8087/health',timeout=3) as response:
   if json.load(response).get('state')=='Running':break
 except (OSError,ValueError):pass
 time.sleep(2)
else:raise RuntimeError('The background call service is not ready. Check journalctl -u openwebpbx.')
if not a.local_certificate:
 run(['python3','configure-sip-tls.py','--domain',a.domain,'--fullchain',a.certificate,'--private-key',a.certificate_key])
# The independent updater runs outside the call-service process and retains the
# current trusted helper while a candidate is staged and verified.
release=P('VERSION').read_text().strip()
tools=P('/opt/openwebpbx/tools');tools.mkdir(parents=True,exist_ok=True,mode=0o755)
for name in ['upgrade.py','verify_feed.py','release-public.pem','configure-sip-tls.py','configure-sip-tls.php']:
 shutil.copy(name,tools/name);(tools/name).chmod(0o644)
slot=P('/opt/openwebpbx/updater/slots')/release
shutil.copytree('updater',slot)
for path in slot.rglob('*'):path.chmod(0o755 if path.is_dir() or path.name=='OpenWebPbx.Updater' else 0o644)
(slot.parent.parent/'current').symlink_to('slots/'+release)
updates=private/'updates';updates.mkdir(mode=0o700);updates.chmod(0o700);os.chown(updates,0,0)
for name in ['openwebpbx-updater.service','openwebpbx-update-recovery.service']:
 shutil.copy(name,P('/etc/systemd/system')/name)
spec=importlib.util.spec_from_file_location('installed_upgrade',tools/'upgrade.py')
upgrade=importlib.util.module_from_spec(spec);spec.loader.exec_module(upgrade)
upgrade.ensure_recovery_integration()
run(['systemctl','daemon-reload']);run(['systemctl','enable','--now','openwebpbx-updater'])
print('Admin is ready at https://'+a.domain)
