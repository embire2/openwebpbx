#!/usr/bin/env python3
"""Actual-source queue diagnostic contracts; no PBX/runtime acceptance inferred."""
import ast
import importlib.util
import json
import subprocess
import tempfile
from pathlib import Path
from types import SimpleNamespace

ROOT = Path(__file__).resolve().parents[1]
source = (ROOT / 'tests/windows-native-acceptance.py').read_text()
spec = importlib.util.spec_from_file_location('queue_native', ROOT / 'tests/windows-native-acceptance.py')
native = importlib.util.module_from_spec(spec)
spec.loader.exec_module(native)
checks = 0


def check(value):
    global checks
    assert value
    checks += 1


fixture = (ROOT / 'tests/windows-native-fixture.php').read_text()
helpers = fixture[fixture.index('function windows_native_queue_table('):fixture.index("$fixtureStage='initialization';")]
functions = (ROOT / 'resources/functions.php').read_text()
uuid = functions[functions.index('\tfunction is_uuid('):functions.index("\nif (!function_exists('is_xml'))")]
uuid = uuid[:uuid.rfind('\n}')]
with tempfile.TemporaryDirectory() as directory:
    script = Path(directory) / 'queue.php'
    script.write_text('<?php\n' + uuid + '\n' + helpers + r'''
$checks=[];$check=static function(bool $ok)use(&$checks):void{$checks[]=$ok;};
$realm='pbx-aaaaaaaaaaaa.fictional.invalid';$id1='11111111-1111-4111-8111-111111111111';$id2='22222222-2222-4222-8222-222222222222';$caller='33333333-3333-4333-8333-333333333333';$foreign='44444444-4444-4444-8444-444444444444';$call=str_repeat('a',24).'@localfixture';
$users=[['number'=>'8100','auth'=>'caller-private'],['number'=>'8101','auth'=>'8102'],['number'=>'8102','auth'=>'other-private'],['number'=>'8103','auth'=>'mail-private']];
$c=['realm'=>$realm,'users'=>[],'queues'=>[['number'=>'8190','members'=>[['number'=>'8101','agent_uuid'=>$id1,'status'=>'LoggedIn'],['number'=>'8102','agent_uuid'=>$id2,'status'=>'LoggedIn']],'native_strategy'=>'top-down','polling_mode'=>'native','timeout'=>8,'ring_timeout'=>3,'wrap_up'=>2,'callback_mode'=>'request','destination'=>['number'=>'8102']]]];
foreach($users as $u)$c['users'][$u['number']]=['auth_id'=>$u['auth'],'enabled'=>true,'profile'=>'Available','profiles'=>['Available'=>['queue_status'=>'-1']],'queue_status'=>'LoggedIn'];
$owned=static fn(string $id):bool=>in_array($id,[$id1,$id2],true);
$table=static function(array $rows):string{if(!$rows)return '';return implode('|',array_keys($rows[0]))."\n".implode("\n",array_map(static fn($r)=>implode('|',$r),$rows))."\n+OK\n";};
$agents=[];foreach([$id1,$id2] as $i=>$id)$agents[$id]=['name'=>$id,'contact'=>'[leg_timeout=3]user/'.$users[$i+1]['auth'].'@'.$realm,'status'=>'Available','state'=>'Waiting','ready_time'=>'0','last_bridge_end'=>'0','wrap_up_time'=>'2'];
$tiers=[['queue'=>'8190@'.$realm,'agent'=>$id1,'state'=>'Ready','position'=>'1'],['queue'=>'8190@'.$realm,'agent'=>$id2,'state'=>'Ready','position'=>'2']];
$channels=[['uuid'=>$caller,'context'=>$realm,'presence_id'=>'8102@'.$realm],['uuid'=>$foreign,'context'=>'foreign.invalid','presence_id'=>'8102@foreign.invalid']];
$members=[['state'=>'Waiting'],['state'=>'Trying'],['state'=>'Answered']];$registered=true;$vars=['sip_call_id'=>$call,'cc_agent_bridged'=>'false','openweb_queue_waiting'=>'true','cc_cancel_reason'=>'TIMEOUT','originate_disposition'=>'USER_BUSY'];$commands=[];
$api=static function(string $command)use(&$commands,&$agents,&$tiers,&$members,&$channels,&$registered,&$vars,$table,$realm,$caller):string{
 $commands[]=$command;
 if($command==='show channels as json')return json_encode(['rows'=>$channels],JSON_THROW_ON_ERROR);
 if($command==='callcenter_config queue list tiers 8190@'.$realm)return $table($tiers);
 if($command==='callcenter_config queue list members 8190@'.$realm)return $table($members);
 if(str_starts_with($command,'callcenter_config agent list ')){$id=substr($command,strlen('callcenter_config agent list '));return isset($agents[$id])?$table([$agents[$id]]):'-ERR';}
 if(str_starts_with($command,'sofia_contact '))return $registered?'sofia/internal/PRIVATE_CONTACT':'error/user_not_registered';
 if(str_starts_with($command,'uuid_getvar ')){$parts=explode(' ',$command);return $parts[1]===$caller?($vars[$parts[2]]??'_undef_'):'PRIVATE_FOREIGN_VALUE';}
 throw new RuntimeException('Unexpected diagnostic command.');
};
$state=windows_native_queue_snapshot($c,$users,$owned,$api,$call);
$check($state['config_matches']&&$state['expected_registered']&&$state['other_contact_matches']&&$state['expected_policy_ready']);
$check($state['waiting_members']===1&&$state['trying_members']===1&&$state['answered_members']===1);
$check($state['expected_status']==='Available'&&$state['expected_state']==='Waiting'&&$state['expected_tier_state']==='Ready'&&$state['expected_tier_position']===1);
$check($state['expected_ready_due']&&$state['expected_wrap_due']&&$state['expected_busy_channels']===1&&$state['other_busy_channels']===0);
$check($state['caller_found']&&!$state['agent_bridged']&&$state['queue_waiting']&&$state['cancel_reason']==='TIMEOUT'&&$state['originate_cause']==='USER_BUSY');
$bytes=json_encode($state,JSON_THROW_ON_ERROR);$check(!str_contains($bytes,$realm)&&!str_contains($bytes,$id1)&&!str_contains($bytes,'PRIVATE_')&&!str_contains($bytes,'other-private'));
$check(!array_filter($commands,static fn($x)=>str_contains($x,$foreign)));
$check(!array_filter($commands,static fn($x)=>!preg_match('/^(show channels as json|callcenter_config (queue list (tiers|members)|agent list)|sofia_contact |uuid_getvar )/D',$x)));
$registered=false;$agents[$id1]['contact']='user/stale-private@'.$realm;$agents[$id1]['ready_time']=(string)(time()+60);$agents[$id1]['last_bridge_end']=(string)time();$agents[$id1]['state']='Receiving';$agents[$id1]['status']='On Break';$tiers[0]['state']='Offering';
$state=windows_native_queue_snapshot($c,$users,$owned,$api);
$check(!$state['expected_registered']&&!$state['expected_contact_matches']&&!$state['expected_ready_due']&&!$state['expected_wrap_due']);
$check($state['expected_state']==='Receiving'&&$state['expected_status']==='On Break'&&$state['expected_tier_state']==='Offering');
$check(!$state['caller_found']&&$state['cancel_reason']==='UNKNOWN');
$agents[$id1]['status']='PRIVATE_STATUS';$agents[$id1]['state']='PRIVATE_STATE';$tiers[0]['state']='PRIVATE_TIER';$vars['originate_disposition']='PRIVATE_CAUSE';$vars['cc_cancel_reason']='PRIVATE_CANCEL';
$state=windows_native_queue_snapshot($c,$users,$owned,$api,$call);
$check($state['expected_status']==='Unknown'&&$state['expected_state']==='Unknown'&&$state['expected_tier_state']==='Unknown'&&$state['originate_cause']==='UNKNOWN'&&$state['cancel_reason']==='UNKNOWN');
$c['queues'][0]['members'][0]['supervisor_break']=true;$check(!windows_native_queue_snapshot($c,$users,$owned,$api)['expected_policy_ready']);unset($c['queues'][0]['members'][0]['supervisor_break']);
$c['users']['8101']['queue_status']='LoggedOut';$check(!windows_native_queue_snapshot($c,$users,$owned,$api)['expected_policy_ready']);$c['users']['8101']['queue_status']='LoggedIn';
$c['queues'][0]['members']=array_reverse($c['queues'][0]['members']);$check(!windows_native_queue_snapshot($c,$users,$owned,$api)['config_matches']);
foreach(['owner','auth','call','members'] as $case){
 $copy=$c;$u=$users;$own=$owned;$cid='';
 if($case==='owner')$own=static fn(string $id):bool=>false;
 if($case==='auth')$u[1]['auth']='foreign-private';
 if($case==='call')$cid='PRIVATE_FOREIGN_CALL';
 if($case==='members')$copy['queues'][0]['members'][]=$copy['queues'][0]['members'][0];
 try{windows_native_queue_snapshot($copy,$u,$own,$api,$cid);$check(false);}catch(RuntimeException $e){$check(true);}
}
$check(windows_native_queue_table(str_repeat('x',65537))===[]);
$check(windows_native_queue_table("PRIVATE HEADER\nPRIVATE_VALUE")===[]);
echo json_encode($checks,JSON_THROW_ON_ERROR);
''')
    result = subprocess.run(['php', str(script)], capture_output=True, text=True, check=True)
    for outcome in json.loads(result.stdout):
        check(outcome)


class Fixture:
    def __init__(self, fail=False):
        self.calls = []
        self.fail = fail

    def cli(self, *args):
        self.calls.append(args)
        if self.fail:
            raise RuntimeError('PRIVATE_DIAGNOSTIC_FAILURE')
        return {'expected_registered': True, 'caller_found': len(args[1]) > 0}


a = SimpleNamespace(dialogs={'old': {'acked': True}}, invites=['old'], receiver_failure=None)
b = SimpleNamespace(dialogs={}, invites=[], receiver_failure=None)
peers = {'expected': a, 'other': b}
baseline = {key: {'dialogs': set(peer.dialogs), 'invites': len(peer.invites)} for key, peer in peers.items()}
fixture = Fixture()
before, complete = native.queue_case_snapshot(fixture, peers, baseline, 'before')
check(complete and before['queue_before_expected_open_dialogs'] == 1)
check(before['queue_before_expected_invites'] == 0 and before['queue_before_expected_acks'] == 0)
check(fixture.calls == [('queue-state', '')])
a.dialogs['new'] = {'acked': False, 'ended': False}
a.invites.append('new')
b.dialogs['other'] = {'acked': True, 'ended': True}
b.invites.append('other')
b.receiver_failure = RuntimeError('PRIVATE_RECEIVER_FAILURE')
after, complete = native.queue_case_snapshot(fixture, peers, baseline, 'after', {'callid': 'a' * 24 + '@localfixture'})
check(complete and after['queue_after_expected_invites'] == 1 and after['queue_after_expected_acks'] == 0)
check(after['queue_after_other_invites'] == 1 and after['queue_after_other_acks'] == 1 and after['queue_after_other_ended'] == 1)
check(after['queue_after_expected_open_dialogs'] == 2 and after['queue_after_other_open_dialogs'] == 0)
check(after['queue_after_other_receiver_failed'] and 'PRIVATE_' not in json.dumps(after))
partial, complete = native.queue_case_snapshot(Fixture(True), peers, baseline, 'after')
check(not complete and partial['queue_after_expected_invites'] == 1)
# Exercise the actual nested call_check with failing diagnostics and preserve the
# exact primary exception, expected first peer and twelve-second default wait.
tree = ast.parse(source)
outer = next(node for node in tree.body if isinstance(node, ast.FunctionDef) and node.name == 'native_calls')
call_check = next(node for node in ast.walk(outer) if isinstance(node, ast.FunctionDef) and node.name == 'call_check')
primary = AssertionError('PRIVATE_PRIMARY_CALL_FAILURE')


def wait(predicate):
    raise primary


fake = Fixture(True)
fake.wait = wait
namespace = {'f': fake, 'a': a, 'b': b, 'queue_case_snapshot': native.queue_case_snapshot,
             'caller': SimpleNamespace(dial=lambda *args: {'code': 200, 'callid': 'a' * 24 + '@localfixture'}),
             'destination': ('127.0.0.1', 5061)}
exec(compile(ast.Module(body=[call_check], type_ignores=[]), '<actual-call-check>', 'exec'), namespace)
try:
    namespace['call_check']('8190')
except AssertionError as error:
    check(error is primary and error.queue_failure['queue_diagnostics_complete'] is False)
    check(fake.active_case == 'queue_agent_delivery' and len(fake.calls) == 2)
    check('PRIVATE_' not in json.dumps(error.queue_failure))
else:
    raise AssertionError('Queue call failure was hidden')
check(native.Fixture.wait.__defaults__ == (12,))
check(call_check.args.defaults[0].id == 'a')
print(f'PASS {checks} actual-source queue scope/state/peer/privacy/primary-failure controls; no PBX contacted')
