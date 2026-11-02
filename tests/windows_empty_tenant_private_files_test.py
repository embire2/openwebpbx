"""Real-key/source-byte controls; no installed paths or database access."""
import hashlib
import importlib.util
import json
from pathlib import Path
import unittest
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import ec

SPEC=importlib.util.spec_from_file_location('empty_tenant',Path(__file__).with_name('windows_empty_tenant_private_files.py'))
M=importlib.util.module_from_spec(SPEC);SPEC.loader.exec_module(M)
ROOT=Path(__file__).resolve().parents[1]
PS=(ROOT/'packaging/windows/Tenant-Domains.ps1').read_text()
PROOF=PS.split(".GetBytes('",1)[1].split("')",1)[0].encode()

class Content(unittest.TestCase):
 def setUp(self):
  self.host='windowsqa.example.invalid'
  self.key=ec.generate_private_key(ec.SECP256R1())
  self.pem=self.key.private_bytes(serialization.Encoding.PEM,serialization.PrivateFormat.PKCS8,serialization.NoEncryption())
  public=self.key.public_key().public_bytes(serialization.Encoding.DER,serialization.PublicFormat.SubjectPublicKeyInfo)
  self.ready={'schema':1,'server_host':self.host,'key_hash':hashlib.sha256(public).hexdigest(),'aliases':{}}
  self.value={'key':self.pem,'ready':json.dumps(self.ready).encode(),'proof':PROOF}
 def test_real_source_p256_and_exact_empty_ready(self):self.assertTrue(M.validate_bytes(self.host,self.value))
 def deny_ready(self,change):
  change(self.ready);self.value['ready']=json.dumps(self.ready).encode()
  with self.assertRaises((RuntimeError,ValueError)):M.validate_bytes(self.host,self.value)
 def test_wrong_host(self):self.deny_ready(lambda r:r.update(server_host='foreign.example.invalid'))
 def test_wrong_key(self):self.deny_ready(lambda r:r.update(key_hash='0'*64))
 def test_nonempty_alias(self):self.deny_ready(lambda r:r['aliases'].update({'tenant.example.invalid':'future'}))
 def test_extra_authority_field(self):self.deny_ready(lambda r:r.update(authorizations={}))
 def test_boolean_schema(self):self.deny_ready(lambda r:r.update(schema=True))
 def test_wrong_curve(self):
  key=ec.generate_private_key(ec.SECP384R1());self.value['key']=key.private_bytes(serialization.Encoding.PEM,serialization.PrivateFormat.PKCS8,serialization.NoEncryption())
  with self.assertRaises(RuntimeError):M.validate_bytes(self.host,self.value)
 def test_wrong_private_key_serialization(self):
  self.value['key']=self.key.private_bytes(serialization.Encoding.PEM,serialization.PrivateFormat.TraditionalOpenSSL,serialization.NoEncryption())
  with self.assertRaises(RuntimeError):M.validate_bytes(self.host,self.value)
 def test_changed_proof(self):
  self.value['proof']+=b' '
  with self.assertRaises(RuntimeError):M.validate_bytes(self.host,self.value)
 def test_duplicate_ready_key(self):
  self.value['ready']=b'{"schema":1,'+self.value['ready'][1:]
  with self.assertRaises(RuntimeError):M.validate_bytes(self.host,self.value)
 def test_changed_source_serialization(self):
  self.value['ready']=json.dumps(self.ready,sort_keys=True).encode()
  with self.assertRaises(RuntimeError):M.validate_bytes(self.host,self.value)
 def test_source_proof_literal(self):self.assertEqual(hashlib.sha256(PROOF).hexdigest(),M.PROOF_SHA256)
 def test_source_directory_atomic_identity_recipes(self):
  import tempfile,shutil
  with tempfile.TemporaryDirectory()as d:
   target=Path(d);shutil.copyfile(ROOT/'packaging/debian/tenant-domains.py',target/'tenant-domains.py');M.source_recipes(target)
   p=target/'tenant-domains.py';p.write_text(p.read_text().replace('def directory(path, public=False):','def directory(path, public=False):\n    pass'))
   with self.assertRaises(RuntimeError):M.source_recipes(target)

if __name__=='__main__':unittest.main()
