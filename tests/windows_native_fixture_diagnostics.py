#!/usr/bin/env python3
"""Exercise bounded fixture diagnostics without installing or contacting a PBX."""
import importlib.util
import html
import json
import subprocess
import tempfile
from pathlib import Path
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('native', ROOT / 'tests/windows-native-acceptance.py')
native = importlib.util.module_from_spec(spec)
spec.loader.exec_module(native)
checks = 0


def check(value):
    global checks
    assert value
    checks += 1


with tempfile.TemporaryDirectory() as folder:
    base = Path(folder)
    data = base / 'ProgramData'
    scope = data / 'OpenWebPBX/native-qualification' / ('a' * 24)
    scope.mkdir(parents=True)
    input_path = scope / 'input.json'
    input_path.write_text('{}')
    source = (ROOT / 'tests/windows-native-fixture.php').read_text()
    function = source[source.index('function windows_native_fixture_failure_record('):source.index("$fixtureStage='initialization';")]
    probe = base / 'diagnostics.php'
    probe.write_text('<?php\n' + function + r'''
$input=$argv[1];$data=$argv[2];$secret='NEVER_PUBLISH_PRIVATE_FIXTURE_MESSAGE';
$error=new RuntimeException($secret);$results=[];
$results[]=windows_native_fixture_failure_record($error,$input,'discover','config_read',$data);
$path=$input.'.discover.failure.json';$first=file_get_contents($path);
$results[]=!windows_native_fixture_failure_record(new LogicException($secret),$input,'discover','policy_save',$data)&&file_get_contents($path)===$first;
$row=json_decode($first,true,32,JSON_THROW_ON_ERROR);
$results[]=array_keys($row)===['schema','error_type','source_basename','source_line','action','stage'];
$results[]=$row['schema']===1&&$row['error_type']==='RuntimeException'&&$row['source_basename']==='external_component'&&$row['stage']==='config_read';
$results[]=!str_contains($first,$secret)&&!str_contains($first,$data)&&strlen($first)<=2048;
$results[]=!windows_native_fixture_failure_record($error,$input,'unknown','config_read',$data);
$results[]=windows_native_fixture_failure_record($error,$input,'cleanup','UNBOUNDED_PRIVATE_STAGE',$data)&&json_decode(file_get_contents($input.'.cleanup.failure.json'),true)['stage']==='initialization';
$outside=dirname($data).'/input.json';file_put_contents($outside,'{}');
$results[]=!windows_native_fixture_failure_record($error,$outside,'discover','config_read',$data)&&!file_exists($outside.'.discover.failure.json');
$results[]=!windows_native_fixture_failure_record($error,$input.'.absent','discover','config_read',$data);
if(DIRECTORY_SEPARATOR==='/'){symlink($input,dirname($input).'/linked.json');$results[]=!windows_native_fixture_failure_record($error,dirname($input).'/linked.json','discover','config_read',$data);}
echo json_encode($results,JSON_THROW_ON_ERROR);
''')
    result = subprocess.run(['php', str(probe), str(input_path), str(data)], capture_output=True, text=True, check=True)
    for outcome in json.loads(result.stdout):
        check(outcome)
    record = json.loads(Path(str(input_path) + '.discover.failure.json').read_text())
    safe = native.fixture_failure(record, 'discover')
    check(safe['active_case'] == 'fixture_php_discover_config_read')
    check(set(safe) == {'error_type', 'source_basename', 'source_line', 'active_case'})
    for mutate in [dict(record, action='cleanup'), dict(record, source_basename='private.php'),
                   dict(record, source_line=True), dict(record, source_line=100001),
                   dict(record, stage='private message'), dict(record, error_type='secret!')]:
        check(native.fixture_failure(mutate, 'discover') is None)
    fixture = native.Fixture.__new__(native.Fixture)
    fixture.php = Path('fictional-php')
    fixture.script = Path('fictional-fixture.php')
    fixture.path = input_path
    fixture.evidence = scope
    failed = subprocess.CompletedProcess([], 1, 'PRIVATE_STDOUT', 'PRIVATE_STDERR')
    with patch.object(native.subprocess, 'run', return_value=failed):
        try:
            fixture.cli('discover')
        except RuntimeError as error:
            check(error.fixture_failure == safe)
            check('PRIVATE_STDOUT' not in str(error) and 'PRIVATE_STDERR' not in str(error))
            check((scope / 'fixture-discover.private.out').read_text() == 'PRIVATE_STDOUT')
            check((scope / 'fixture-discover.private.err').read_text() == 'PRIVATE_STDERR')
        else:
            raise AssertionError('Failed PHP subprocess was accepted')
    Path(str(input_path) + '.discover.failure.json').write_text('x' * 2049)
    with patch.object(native.subprocess, 'run', return_value=failed):
        try:
            fixture.cli('discover')
        except RuntimeError as error:
            check(not hasattr(error, 'fixture_failure'))
        else:
            raise AssertionError('Failed PHP subprocess was accepted')

    check(native.g729_negotiation_failure({'code':200,'media':{'pt':18}}) is None)
    failure=native.g729_negotiation_failure({'code':488,'text':'PRIVATE_SIP_RESPONSE','digest_challenge_count':1})
    check(failure.active_case=='independent_g729_offer_refused' and failure.sip_failure=={'sip_response_code':488,'digest_challenge_count':1})
    check('PRIVATE_SIP_RESPONSE' not in str(failure))
    failure=native.g729_negotiation_failure({'code':200,'media':{'pt':0},'digest_challenge_count':1})
    check(failure.active_case=='independent_g729_answer_payload_mismatch' and failure.sip_failure['negotiated_payload_type']==0)
    for values in [{'code':True,'media':{'pt':False},'digest_challenge_count':False},
                   {'code':'PRIVATE_CODE','media':{'pt':'PRIVATE_PT'},'digest_challenge_count':'PRIVATE_COUNT'},
                   {'code':199,'media':{'pt':-1},'digest_challenge_count':-1},
                   {'code':700,'media':{'pt':128},'digest_challenge_count':4}]:
        check(native.g729_negotiation_failure(values).sip_failure=={})

    user={'extension_uuid':'11111111-1111-4111-8111-111111111111','domain_uuid':'22222222-2222-4222-8222-222222222222','auth':'fixture-8100','password':'PRIVATE_PASSWORD&<"'}
    fields={'extension_uuid':user['extension_uuid'],'domain_uuid':user['domain_uuid'],'extension':user['auth'],'password':user['password'],'absolute_codec_string':'PCMU','csrf-fictional':'PRIVATE_CSRF','max_registrations':'1','description':'Preserve fictional description'}
    def form(values):return '<form method="post">'+''.join('<input name="'+html.escape(key,quote=True)+'" value="'+html.escape(value,quote=True)+'">' for key,value in values.items())+'</form>'
    requests=[];web=native.Web.__new__(native.Web)
    def request(path,payload=None):
        requests.append((path,payload))
        if payload is None:return 200,path,form(fields)
        check(payload['csrf-fictional']==fields['csrf-fictional'] and payload['password']==user['password'] and payload['domain_uuid']==user['domain_uuid'])
        check(payload['max_registrations']=='1' and payload['description']==fields['description'] and payload['range']=='1')
        return 200,path,form(payload)
    web.request=request;web.extension_codecs(user,'PCMU,G729')
    check(len(requests)==2 and requests[1][1]['absolute_codec_string']=='PCMU,G729')
    wrong=fields|{'domain_uuid':'33333333-3333-4333-8333-333333333333'};requests=[]
    web.request=lambda path,payload=None:(requests.append((path,payload)) or (200,path,form(wrong)))
    try:web.extension_codecs(user,'PCMU')
    except AssertionError as error:
        check(len(requests)==1)
        check(error.audio_failure=={'owned_domain_matches':False,'authentication_id_matches':True,'sip_password_matches':True})
    else:raise AssertionError('Foreign-domain audio form was submitted')
    check(native.audio_identity_failure(fields,user) is None)
    for field,value in [('extension','other-fictional-user'),('password','PRIVATE_WRONG_SECRET')]:
        failure=native.audio_identity_failure(fields|{field:value},user)
        check(len(failure.audio_failure)==3 and all(type(value) is bool for value in failure.audio_failure.values()))
        check('PRIVATE_' not in str(failure))

print(f'PASS {checks} bounded PHP/Python fixture diagnostic checks; no PBX contacted')
