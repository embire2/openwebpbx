#!/usr/bin/env python3
"""Verify the built Play bundle, including permissions, signing and native alignment."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import struct
import subprocess
import xml.etree.ElementTree as ET
import zipfile

p = argparse.ArgumentParser(description=__doc__)
p.add_argument('bundle', type=Path)
p.add_argument('--bundletool', required=True, type=Path)
p.add_argument('--report', type=Path)
a = p.parse_args()
project = Path(__file__).resolve().parents[1]
version = (project.parents[1] / 'VERSION').read_text().strip()
expected_cert = '449740f6858cb092a0f67d9d79d2505a8d6e7e4d4c1a52a8eaed9b895e48e69d'

def command(*args):
    return subprocess.check_output(args, text=True, stderr=subprocess.STDOUT)

command('java', '-jar', str(a.bundletool), 'validate', '--bundle='+str(a.bundle))
manifest = command('java', '-jar', str(a.bundletool), 'dump', 'manifest', '--bundle='+str(a.bundle))
root = ET.fromstring(manifest)
ns = '{http://schemas.android.com/apk/res/android}'
assert root.get('package') == 'com.openweb.pbx', 'Unexpected package'
assert root.get(ns+'versionName') == version, 'Unexpected version'
assert int(root.get(ns+'versionCode')) == int(re.search(r'\?: (\d+)\s*\n', (project/'app/build.gradle.kts').read_text()).group(1))
sdk = root.find('uses-sdk')
assert int(sdk.get(ns+'targetSdkVersion')) >= 36
assert sdk.get(ns+'minSdkVersion') == '28'
application = root.find('application')
assert application.get(ns+'debuggable', 'false') == 'false'
assert application.get(ns+'allowBackup') == 'false'
assert application.get(ns+'usesCleartextTraffic') == 'false'
permissions = sorted(x.get(ns+'name') for x in root.findall('uses-permission'))
for forbidden in ['REQUEST_INSTALL_PACKAGES', 'UPDATE_PACKAGES_WITHOUT_USER_ACTION', 'MANAGE_EXTERNAL_STORAGE', 'READ_SMS', 'READ_CALL_LOG', 'USE_FULL_SCREEN_INTENT', 'FOREGROUND_SERVICE_CAMERA', 'FOREGROUND_SERVICE_PHONE_CALL', 'FOREGROUND_SERVICE_DATA_SYNC']:
    assert 'android.permission.'+forbidden not in permissions, 'Unexpected permission: '+forbidden
services = {x.get(ns+'name'): x for x in application.findall('service')}
phone = services['com.openweb.pbx.PhoneService']
assert phone.get(ns+'exported') == 'false'
# Bundletool emits compiled flag values, while source/XML tools may emit names.
types = phone.get(ns+'foregroundServiceType')
assert int(types,0) == 0x90 if types.startswith(('0x','0X')) or types.isdigit() else set(types.split('|')) == {'connectedDevice','microphone'}
receivers = {x.get(ns+'name') for x in application.findall('receiver')}
assert 'com.openweb.pbx.UpdateJob' not in services
assert not receivers & {'com.openweb.pbx.UpdateStatusReceiver','com.openweb.pbx.UpdateReplacedReceiver'}
assert services['com.openweb.pbx.PlayUpdateJob'].get(ns+'permission') == 'android.permission.BIND_JOB_SERVICE'
cert = command('keytool','-printcert','-jarfile',str(a.bundle))
match = re.search(r'SHA256:\s*([0-9A-Fa-f:]+)',cert)
assert match and match.group(1).replace(':','').lower() == expected_cert, 'Wrong app signing identity'
command('jarsigner','-verify',str(a.bundle))
native = []
with zipfile.ZipFile(a.bundle) as archive:
    assert archive.testzip() is None
    for name in archive.namelist():
        assert not name.startswith('/') and '..' not in Path(name).parts
        assert not any(part in ('.env','.git') for part in Path(name).parts)
        assert not name.endswith(('.jks','.keystore','.pfx','.key'))
        if name.endswith('.dex'):
            data=archive.read(name)
            for forbidden in [b'Landroid/content/pm/PackageInstaller;',b'Lcom/openweb/pbx/UpdateStatusReceiver;',b'Lcom/openweb/pbx/UpdateReplacedReceiver;']:
                assert forbidden not in data, 'Direct installer reference in Play DEX'
        if '/lib/' not in name or not name.endswith('.so'):
            continue
        data = archive.read(name)
        assert data[:4] == b'\x7fELF'
        if data[4] != 2:
            continue # 16KB page-size requirement is for 64-bit ABIs.
        assert data[5] == 1, 'Unexpected ELF endian'
        offset = struct.unpack_from('<Q',data,32)[0]
        entry_size, count = struct.unpack_from('<HH',data,54)
        loads=[]
        for i in range(count):
            entry=offset+i*entry_size
            kind,flags,file_offset,address,_,file_size,memory_size,alignment=struct.unpack_from('<IIQQQQQQ',data,entry)
            if kind == 1:
                assert alignment >= 16384 and (file_offset-address)%16384 == 0, '16KB ELF alignment: '+name
                loads.append(alignment)
        assert loads
        native.append({'name':name,'load_alignments':loads})
assert native, 'Missing calling engine'
report={'bundle':a.bundle.name,'bytes':a.bundle.stat().st_size,'sha256':hashlib.sha256(a.bundle.read_bytes()).hexdigest(),'version':version,'package':'com.openweb.pbx','target_sdk':int(sdk.get(ns+'targetSdkVersion')),'certificate_sha256':expected_cert,'permissions':permissions,'native_64bit_libraries':native,'bundletool_validation':'passed','direct_installer_excluded':True,'runtime_16kb_qualification':'separate_device_test_required'}
if a.report:
    a.report.parent.mkdir(parents=True,exist_ok=True)
    a.report.write_text(json.dumps(report,indent=2)+'\n')
print(json.dumps({k:v for k,v in report.items() if k not in ('permissions','native_64bit_libraries')},indent=2))
print('64-bit ELF libraries checked:',len(native))
