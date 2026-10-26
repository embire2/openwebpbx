"""Run the compiled opt-in workflow only on a root-prepared disposable Android.
Requires fresh owned tenant QR PNGs and the unchanged platform TLS/custodian path.
No signing, fixture account creation, network policy or production credential access.
"""
from pathlib import Path
import argparse,json,re,subprocess,hashlib
parser=argparse.ArgumentParser();parser.add_argument('--adb',type=Path,required=True);parser.add_argument('--serial',required=True);parser.add_argument('--fixture-directory',type=Path,required=True);parser.add_argument('--output',type=Path,required=True);parser.add_argument('--unsigned-apk',type=Path,required=True);parser.add_argument('--qualified-apk',type=Path,required=True);parser.add_argument('--payload-verifier',type=Path,required=True);parser.add_argument('--apksigner',type=Path,required=True);args=parser.parse_args()
args.output.mkdir(mode=0o700,parents=True,exist_ok=False);fixture=json.loads((args.fixture_directory/'qr120-fixture.private.json').read_bytes());nonce=fixture['owner_nonce'];assert re.fullmatch('[a-f0-9]{12}',nonce)and fixture['scope']=='new-owned-qr120-tenants-only'
for name in ['a','b']:assert fixture[name]['server']==f'https://qa-qr120-{nonce}-{name}.openwebpbx.com'and re.fullmatch('[a-f0-9]{12}',fixture[name]['sip_nonce'])and fixture[name]['sip_domain']=='mobile-check-'+fixture[name]['sip_nonce']+'.invalid'
assert fixture['a']['sip_nonce']!=fixture['b']['sip_nonce']
adb=[str(args.adb),'-s',args.serial];remote='/sdcard/Android/data/com.openweb.pbx/files'
def run(command,**kwargs):return subprocess.run([*adb,*command],check=True,timeout=45,**kwargs)
# Public QA signature verification and exact release payload/installed-byte binding.
verified=subprocess.run(['python3',str(args.payload_verifier),str(args.unsigned_apk),str(args.qualified_apk)],check=True,stdout=subprocess.PIPE,stderr=subprocess.PIPE,timeout=45)
(args.output/'release-payload-equality.safe.json').write_bytes(verified.stdout)
signed=subprocess.run([str(args.apksigner),'verify','--verbose','--print-certs',str(args.qualified_apk)],check=True,stdout=subprocess.PIPE,stderr=subprocess.PIPE,timeout=45)
(args.output/'qualification-certificate.original.txt').write_bytes(signed.stdout)
paths=subprocess.check_output([*adb,'shell','pm','path','com.openweb.pbx'],timeout=15,text=True).splitlines();assert len(paths)==1 and paths[0].startswith('package:')
installed=args.output/'installed-base.apk';run(['pull',paths[0][8:],str(installed)],stdout=subprocess.DEVNULL)
assert hashlib.sha256(installed.read_bytes()).digest()==hashlib.sha256(args.qualified_apk.read_bytes()).digest(), 'Installed app differs from root-qualified release payload'
names=['qr120-fixture.private.json','qr120-a.png','qr120-b.png','qr120-a-reconnect.png']
for name in [*names,'qr120-native-workflow.safe.json']:
 run(['shell','test','!','-e',remote+'/'+name],stdout=subprocess.DEVNULL)
owned=[]
try:
 run(['shell','mkdir','-p',remote])
 for name in names:
  file=args.fixture_directory/name;assert file.is_file();run(['push',str(file),remote+'/'+name],stdout=subprocess.DEVNULL);owned.append(name)
 for permission in ['RECORD_AUDIO','CAMERA','POST_NOTIFICATIONS','BLUETOOTH_CONNECT']:
  run(['shell','pm','grant','com.openweb.pbx','android.permission.'+permission],stdout=subprocess.DEVNULL)
 with(args.output/'instrumentation.original.log').open('wb')as out:
  result=subprocess.run([*adb,'shell','am','instrument','-w','-r','-e','class','com.openweb.pbx.QrProvisioningWorkflowTest','-e','qrEnrollmentFixture','true','com.openweb.pbx.test/androidx.test.runner.AndroidJUnitRunner'],stdout=out,stderr=subprocess.STDOUT,timeout=360)
 text=(args.output/'instrumentation.original.log').read_text();assert result.returncode==0 and'OK (1 test)'in text and not any(x in text for x in ['FAILURES','INSTRUMENTATION_FAILED','Process crashed','AssumptionViolated'])
 run(['pull',remote+'/qr120-native-workflow.safe.json',str(args.output/'workflow.safe.json')],stdout=subprocess.DEVNULL)
 report=json.loads((args.output/'workflow.safe.json').read_text());assert report['owner_nonce']==nonce and report['actual_custodian_HTTPS_and_enrollment']and report['other_tenant_SDK_pointer_unchanged'];print('PASS actual QR/custodian/enrollment/two-tenant registration/reconnect; no calling/camera approval')
finally:
 # Delete only this driver's fixed new fixture names; backend owner removes its own UUIDs.
 for name in owned:
  run(['shell','rm','-f',remote+'/'+name],stdout=subprocess.DEVNULL)
