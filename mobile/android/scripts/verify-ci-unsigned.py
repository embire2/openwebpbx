#!/usr/bin/env python3
"""Read-only APK/AAB, native-library, permission and resolved-runtime gates."""
import argparse,hashlib,json,re,struct,subprocess,zipfile
from pathlib import Path,PurePosixPath
import xml.etree.ElementTree as ET

ANDROID='{http://schemas.android.com/apk/res/android}'
SIGNATURE=re.compile(r'META-INF/[^/]+\.(?:SF|RSA|DSA|EC)',re.I)
def sha(path):
    with path.open('rb') as stream:return hashlib.file_digest(stream,'sha256').hexdigest()
def run(command):return subprocess.check_output([str(x) for x in command],stderr=subprocess.PIPE,timeout=90)
def elf_load_alignments(raw):
    assert raw[:4]==b'\x7fELF' and raw[5]==1,'Invalid ELF header'
    if raw[4]==2:offset=struct.unpack_from('<Q',raw,32)[0];size,count=struct.unpack_from('<HH',raw,54);field,fmt=48,'<Q'
    else:
        assert raw[4]==1
        offset=struct.unpack_from('<I',raw,28)[0];size,count=struct.unpack_from('<HH',raw,42);field,fmt=28,'<I'
    assert 0<count<1024 and size>=field+struct.calcsize(fmt) and offset+size*count<=len(raw)
    result=[struct.unpack_from(fmt,raw,offset+i*size+field)[0]for i in range(count)if struct.unpack_from('<I',raw,offset+i*size)[0]==1]
    assert result
    return result
def archive(path,prefix,expected):
    members={};libraries={}
    with zipfile.ZipFile(path) as source:
        assert len(source.namelist())==len(set(source.namelist())),'Duplicate ZIP member'
        assert source.testzip() is None,'ZIP CRC failure'
        for entry in source.infolist():
            name=entry.filename;parts=PurePosixPath(name).parts
            assert name and not name.startswith('/') and '..' not in parts and '\\' not in name and not any(ord(c)<32 for c in name),'Unsafe ZIP path'
            assert not SIGNATURE.fullmatch(name),'Unsigned candidate contains JAR signature'
            if entry.is_dir():continue
            raw=source.read(entry);members[name]={'bytes':len(raw),'sha256':hashlib.sha256(raw).hexdigest()}
            if name.startswith(prefix+'lib/') and name.endswith('.so'):
                relative=name[len(prefix):];assert relative in expected and members[name]['sha256']==expected[relative],name
                alignments=elf_load_alignments(raw)
                if parts[-2] in ['arm64-v8a','x86_64']:assert min(alignments)>=16384,(name,alignments)
                libraries[relative]={'sha256':members[name]['sha256'],'LOAD_alignments':alignments}
    assert set(libraries)==set(expected),'Native library/ABI inventory changed'
    assert len(libraries)==39
    return {'members':members,'native_libraries':libraries}
def apk_gate(apk,tools,baseline,code,version):
    badging=run([tools/'aapt2','dump','badging',apk]).decode()
    first=badging.splitlines()[0]
    for value in ["name='com.openweb.pbx'",f"versionCode='{code}'",f"versionName='{version}'"]:assert value in first,value
    assert "targetSdkVersion:'36'" in badging and "minSdkVersion:'28'" in badging
    assert 'application-debuggable' not in badging
    permissions=run([tools/'aapt2','dump','permissions',apk]).decode()
    assert sorted(x for x in permissions.splitlines()if 'uses-permission:' in x or 'permission:' in x)==baseline['direct_permissions_lines'],'Direct permission drift'
    signed=subprocess.run([str(tools/'apksigner'),'verify','--verbose','--print-certs',str(apk)],capture_output=True,timeout=45)
    assert signed.returncode!=0 and b'DOES NOT VERIFY' in signed.stderr and b'Missing META-INF/MANIFEST.MF' in signed.stderr,'APK is signed or did not fail specifically as unsigned'
    run([tools/'zipalign','-c','-P','16','4',apk])
    return archive(apk,'',baseline['native_libraries'])
def aab_gate(aab,bundletool,baseline,code,version):
    assert sha(bundletool)==baseline['bundletool_sha256'],'Bundletool changed'
    java=['java','-Xmx512m','-jar',bundletool]
    run([*java,'validate','--bundle='+str(aab)])
    root=ET.fromstring(run([*java,'dump','manifest','--bundle='+str(aab),'--module=base']))
    assert root.get('package')=='com.openweb.pbx' and root.get(ANDROID+'versionCode')==str(code) and root.get(ANDROID+'versionName')==version
    sdk=root.find('uses-sdk');assert sdk is not None and sdk.get(ANDROID+'targetSdkVersion')=='36' and sdk.get(ANDROID+'minSdkVersion')=='28'
    app=root.find('application');assert app is not None and app.get(ANDROID+'debuggable','false')=='false' and app.get(ANDROID+'usesCleartextTraffic')=='false' and app.get(ANDROID+'allowBackup')=='false'
    permissions=sorted([dict(x.attrib)for x in root if x.tag in ['uses-permission','uses-permission-sdk-23']],key=lambda x:json.dumps(x,sort_keys=True))
    assert permissions==baseline['play_permissions'],'Play permission drift'
    assert not any(x.get(ANDROID+'name') in ['android.permission.REQUEST_INSTALL_PACKAGES','android.permission.UPDATE_PACKAGES_WITHOUT_USER_ACTION'] for x in root)
    assert not any(any(t in x.get(ANDROID+'name','')for t in ['.UpdateJob','.UpdateStatusReceiver','.UpdateReplacedReceiver']) for x in app),'Direct installer entered Play bundle'
    return archive(aab,'base/',baseline['native_libraries'])
def runtime_gate(inventory,artifacts,baseline):
    assert sha(inventory)==baseline['runtime_inventory_sha256'],'Runtime coordinate drift'
    result=json.loads(artifacts.read_text());assert set(result)=={'directReleaseRuntimeClasspath','playReleaseRuntimeClasspath'}
    union=set()
    for config,items in result.items():
        assert items and len({(x['coordinate'],x['filename'])for x in items})==len(items)
        for item in items:
            coordinate=item['coordinate'];union.add(coordinate)
            expected=baseline['runtime_components'][coordinate]
            assert {k:item[k]for k in ['filename','bytes','sha256']} in expected,(config,coordinate)
    assert union==set(baseline['runtime_components']) and len(union)==43,'Incomplete runtime selection'
    return result
def main():
    p=argparse.ArgumentParser();p.add_argument('--apk',type=Path,required=True);p.add_argument('--aab',type=Path,required=True);p.add_argument('--tools',type=Path,required=True);p.add_argument('--bundletool',type=Path,required=True);p.add_argument('--inventory',type=Path,required=True);p.add_argument('--runtime-artifacts',type=Path,required=True);p.add_argument('--output',type=Path,required=True);a=p.parse_args()
    assert not a.output.exists(),'Evidence output must be new'
    baseline=json.loads(Path(__file__).with_name('android120-ci-baseline.json').read_text())
    result={'schema':1,'android_version':'1.0.20','version_code':120,'APK_sha256':sha(a.apk),'AAB_sha256':sha(a.aab)}
    result['apk']=apk_gate(a.apk,a.tools,baseline,120,'1.0.20');result['aab']=aab_gate(a.aab,a.bundletool,baseline,120,'1.0.20');result['runtime_artifacts']=runtime_gate(a.inventory,a.runtime_artifacts,baseline)
    a.output.write_text(json.dumps(result,indent=2,sort_keys=True)+'\n')
    print(json.dumps({'APK_sha256':result['APK_sha256'],'AAB_sha256':result['AAB_sha256'],'native_libraries_each':39,'runtime_components':43,'permission_baseline':'accepted119','native_calling_or_Play_approval':False}))
if __name__=='__main__':main()
