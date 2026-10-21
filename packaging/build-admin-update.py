#!/usr/bin/env python3
"""Build the narrow admin update without packaging unqualified full-server changes."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import tarfile

root = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--output', type=Path, required=True)
parser.add_argument('--hosted-index', type=Path, required=True, help='Sealed pre-update hosted16 index.php.')
parser.add_argument('--signing-key', type=Path, required=True)
args = parser.parse_args()
if (root / 'ADMIN_VERSION').read_text().strip() != '1.0.19':
    parser.error('Reproduce admin1.0.19 from its immutable v1.0.19 source checkout.')
stage = args.output / 'openwebpbx-1.0.19-admin-update'
stage.mkdir(parents=True, exist_ok=False)
sha = lambda data: hashlib.sha256(data).hexdigest()
old = lambda path: subprocess.check_output(['git', 'show', '96ce9313802a99520dc46704e633fc80481a87b2:' + path], cwd=root)


def index_patch(data):
    text = data.decode()
    post = "        elseif(($_POST['action']??'')==='save_trunk_incoming'&&$view==='voice'){(new pbx_trunk_routes)->save($key,$_POST);$_SESSION['pbx_setup_notice']='Incoming route saved. New calls use the selected destination.';header('Location: /app/pbx_setup/?view=voice&edit='.rawurlencode($key).'#incoming-calls');exit;}\n"
    anchor = "        elseif(($_POST['action']??'')==='check_provider'&&$view==='voice')"
    form = '    <form method="post" class="setup-form admin-form-tabs">'
    include = "    <?php if($view==='voice'&&$key!=='new')require __DIR__.'/trunk-routes.php'; ?>\n"
    for marker in [anchor, form, '$e(pbx_updates::version())']:
        if text.count(marker) != 1:raise RuntimeError('Unexpected original admin entry.')
    text = text.replace(anchor, post + anchor).replace(form, include + form).replace('$e(pbx_updates::version())', "$e(pbx_updates::version().' · Admin '.pbx_trunk_routes::VERSION)")
    return text.encode()


rows = []
for target in ['resources/classes/pbx_call_me_back.php', 'resources/classes/pbx_trunk_routes.php', 'app/pbx_setup/trunk-routes.php', 'app/pbx_setup/trunk-routes.js', 'ADMIN_VERSION', 'app/pbx_setup/index.php']:
    variants = []
    if target == 'app/pbx_setup/index.php':
        inputs = [('stock16', old(target)), ('hosted16', args.hosted_index.read_bytes())]
        for label, data in inputs:
            baseline = stage / 'baselines' / label / 'index.php';baseline.parent.mkdir(parents=True, exist_ok=True);baseline.write_bytes(data)
            patched = index_patch(data);name = 'payload/' + label + '/index.php';p = stage / name;p.parent.mkdir(parents=True, exist_ok=True);p.write_bytes(patched)
            variants.append({'before_sha256': sha(data), 'sha256': sha(patched), 'source': name})
    else:
        data = (root / target).read_bytes();name = 'payload/' + target;p = stage / name;p.parent.mkdir(parents=True, exist_ok=True);p.write_bytes(data)
        variants.append({'before_sha256': sha(old(target)) if target == 'resources/classes/pbx_call_me_back.php' else None, 'sha256': sha(data), 'source': name})
        if target == 'resources/classes/pbx_call_me_back.php':
            baseline = stage / 'baselines/pbx_call_me_back.php';baseline.parent.mkdir(parents=True, exist_ok=True);baseline.write_bytes(old(target))
    rows.append({'target': target, 'variants': variants})
contract = {'schema': 1, 'version': '1.0.19', 'base_core': '1.0.16', 'files': rows}
manifest = stage / 'admin-update-manifest.json';manifest.write_text(json.dumps(contract, indent=2) + '\n')
subprocess.run(['openssl', 'dgst', '-sha256', '-sign', str(args.signing_key), '-out', str(stage / 'admin-update-manifest.sig'), str(manifest)], check=True)
shutil.copy2(root / 'packaging/updates/release-public.pem', stage)
shutil.copy2(root / 'packaging/debian/install-admin-update.py', stage)
shutil.copy2(root / 'docs/incoming-routing-1.0.19.md', stage / 'README.md')
shutil.copy2(root / 'LICENSE', stage)
archive = args.output / (stage.name + '.tar.gz')
with tarfile.open(archive, 'w:gz') as output:output.add(stage, arcname=stage.name)
print(archive.name, archive.stat().st_size, sha(archive.read_bytes()))
