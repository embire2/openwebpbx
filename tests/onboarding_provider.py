"""Actual protected marker selection; never touches the installed instance."""
from pathlib import Path
import importlib.util
import os
import tempfile
from unittest.mock import patch

root=Path(__file__).resolve().parents[1]
spec=importlib.util.spec_from_file_location('onboarding_provider',root/'packaging/debian/onboarding.py');m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)
checks=0
def check(value,message):
 global checks
 assert value,message;checks+=1
def refused(path,message):
 try:m.image_provider(path)
 except ValueError:check(True,message)
 else:raise AssertionError(message)

with tempfile.TemporaryDirectory(prefix='openweb-provider-marker-')as temporary:
 p=Path(temporary)/'image-onboarding-enabled'
 check(m.image_provider(p)=='debian','Ordinary installations preserve provider choice')
 p.touch(mode=0o600);check(m.image_provider(p)=='webhotel','Existing protected opt-in marker supported')
 p.write_bytes(b'webhotel-image-onboarding-v1\n');check(m.image_provider(p)=='webhotel','Explicit hosted-image marker supported')
 for raw in [b'other',b'webhotel-image-onboarding-v1\nextra',b'x'*65]:
  p.write_bytes(raw);refused(p,'Unknown or oversized provider marker refused')
 p.write_bytes(b'');p.chmod(0o644);refused(p,'Public-readable marker refused');p.chmod(0o600)
 os.chown(p,33,33);refused(p,'Web user cannot select hosting provider');os.chown(p,0,0)
 link=Path(temporary)/'other';os.link(p,link);refused(p,'Hard-linked provider marker refused');link.unlink()
 p.unlink();p.symlink_to(Path(temporary)/'absent');refused(p,'Dangling linked provider marker refused');p.unlink()
 p.mkdir();refused(p,'Directory cannot act as provider marker');p.rmdir()
 with patch.object(m,'IS_WINDOWS',True):check(m.image_provider(p)=='debian','Windows self-install does not read Debian hosting marker')
print('PASS',checks,'actual image-provider selection controls')
