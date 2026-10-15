#!/usr/bin/env python3
"""Exercise the exact PHP response expression without configuration/SQL/native calls."""
import json,re,subprocess
from pathlib import Path
root=Path(__file__).resolve().parents[1]
source=(root/'tests/windows-native-fixture.php').read_text()
match=re.search(r"'cleanup_reloadxml'=>([^\n]+?)\],JSON_THROW_ON_ERROR",source)
assert match
expression=match.group(1)
values=['','  ','+OK [Success]','+OK PRIVATE_SECRET','-ERR PRIVATE_SECRET','PRIVATE_SECRET','<PRIVATE_SECRET>']
expected=['empty','empty','success','success','error','other','other']
checks=0
def check(value):
    global checks
    assert value
    checks+=1
code='<?php $values=json_decode(stream_get_contents(STDIN),true);$out=[];foreach($values as $v){$cleanupReloadXml=trim($v);$out[]='+expression+';}echo json_encode($out,JSON_THROW_ON_ERROR);'
import tempfile
with tempfile.TemporaryDirectory(prefix='ow-restart-control-') as d:
 p=Path(d)/'control.php';p.write_text(code)
 child=subprocess.run(['php','-n',str(p)],input=json.dumps(values),capture_output=True,text=True,check=True)
 for actual,wanted in zip(json.loads(child.stdout),expected,strict=True):check(actual==wanted)
 check('PRIVATE' not in child.stdout);check(not child.stderr)
check(source.count("event_socket::api('reloadxml')")==2) # same native calls; only existing cleanup return observed
check('$cleanupReloadXml=trim((string)event_socket::api(\'reloadxml\'))' in source)
print(f'PASS {checks} actual PHP cleanup reload response/source controls; no configuration, database or native access')
