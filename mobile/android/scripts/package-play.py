#!/usr/bin/env python3
"""Package the reviewed Play bundle and public submission files only."""
import argparse
import hashlib
import json
from pathlib import Path
import struct
import zipfile

p=argparse.ArgumentParser(description=__doc__)
p.add_argument('--bundle',type=Path,required=True)
p.add_argument('--verification',type=Path,required=True)
p.add_argument('--video',type=Path,help='Reviewed public demonstration MP4 with fictional accounts only')
p.add_argument('--output',type=Path,required=True)
a=p.parse_args()
project=Path(__file__).resolve().parents[1]
repo=project.parents[1]
version=(repo/'VERSION').read_text().strip()
report=json.loads(a.verification.read_text())
sha=lambda data:hashlib.sha256(data).hexdigest()
assert report['sha256']==sha(a.bundle.read_bytes()) and report['version']==version
assert report['direct_installer_excluded'] and report['bundletool_validation']=='passed'
assert report['target_sdk']>=36
play=project/'play'
files={}
for relative in ['listing.json','declarations.md','closed-test-plan.md']:
    files['mobile/android/play/'+relative]=(play/relative).read_bytes()
for path in sorted((play/'metadata').rglob('*')):
    if path.is_file():
        assert path.suffix in ('.txt','.png'), 'Unexpected listing file'
        files['mobile/android/play/'+path.relative_to(play).as_posix()]=path.read_bytes()
screens=list((play/'metadata/en-US/images/phoneScreenshots').glob('*.png'))
assert len(screens)>=2,'At least two actual phone screenshots must be prepared'
for image in screens:
    data=image.read_bytes();assert data[:8]==b'\x89PNG\r\n\x1a\n'
    width,height=struct.unpack('>II',data[16:24]);assert min(width,height)>=320 and max(width,height)<=3840 and max(width,height)<=2*min(width,height)
for name,maximum in [('title',30),('short_description',80),('full_description',4000)]:
    assert 0<len((play/'metadata/en-US'/f'{name}.txt').read_text().strip())<=maximum
for relative in ['docs/google-play.md','docs/google-play-review.md']:
    files[relative]=(repo/relative).read_bytes()
files[a.bundle.name]=a.bundle.read_bytes()
files['VERIFICATION.json']=a.verification.read_bytes()
if a.video:
    assert a.video.suffix == '.mp4' and a.video.stat().st_size < 100*1024*1024
    files['review-demonstration.mp4']=a.video.read_bytes()
files['START-HERE.md']=f'''# OpenWeb PBX {version} — Google Play submission files\n\nThis packet is prepared for submission. Google has not approved or published the app.\n\n1. Create/verify the Google Play Console account that will own the app.\n2. Create the free app OpenWeb PBX, language English (United States), package com.openweb.pbx.\n3. Import the existing app-signing identity using Google’s encrypted PEPK process; see docs/google-play.md before accepting a newly generated signing key.\n4. Upload {a.bundle.name} to Internal testing.\n5. Copy listing text and images from mobile/android/play/metadata/en-US. Use the live privacy/support/data-removal URLs in listing.json.\n6. Complete the prepared declarations with the owner’s confirmed details. Put the separately supplied private reviewer login in App access; it is intentionally absent from this public packet.\n7. Test through Google Play, address its pre-launch report, complete any required closed test, then submit the reviewed production release.\n\nFull steps and links: docs/google-play.md. The app signing key, upload credentials, reviewer password and customer data are not included. This AAB is for Google Play; phone users install the APK release or the approved store app.\n\nSource and current release: https://github.com/embire2/openwebpbx/releases/tag/v{version}\n'''.encode()
# Only explicitly listed public inputs are read. No private environment or reviewer file.
files['SHA256SUMS']=''.join(sha(data)+'  '+name+'\n' for name,data in sorted(files.items())).encode()
a.output.parent.mkdir(parents=True,exist_ok=True)
with zipfile.ZipFile(a.output,'w',zipfile.ZIP_DEFLATED,compresslevel=6) as archive:
    for name,data in sorted(files.items()):
        archive.writestr(f'openwebpbx-google-play-{version}/'+name,data)
print(json.dumps({'archive':str(a.output),'files':len(files),'bytes':a.output.stat().st_size,'sha256':sha(a.output.read_bytes()),'phone_screenshots':len(screens),'store_status':'prepared_not_submitted'},indent=2))
