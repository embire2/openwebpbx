<?php
/** CLI-only real PostgreSQL checks, in an owned schema; no engine commands. */
if(PHP_SAPI!=='cli'){http_response_code(404);exit;}
require dirname(__DIR__).'/resources/require.php';
class users_groups_admin extends pbx_admin {
    protected function changed(?string $trunk=null,?string $queue=null): void {}
    protected function engine(string $command): string {return '+OK';}
}
$db=$database->db;$db->setAttribute(PDO::ATTR_ERRMODE,PDO::ERRMODE_EXCEPTION);
$input=['name'=>'Fictional User','enabled'=>'1','voicemail_enabled'=>'1'];
if(($argv[1]??'')==='--allocate'){
    if(!preg_match('/^pbx_users_groups_[a-f0-9]{12}$/D',$argv[2]??'')||!is_uuid($argv[3]??''))throw new RuntimeException('Invalid fixture scope.');
    $db->exec('set search_path to '.$argv[2].',public');
    $_SESSION=['authorized'=>true,'user_uuid'=>uuid(),'domain_uuid'=>$argv[3],'domain_name'=>'users-groups.invalid'];
    echo (new users_groups_admin($db))->save('user','new',$input+['number'=>$argv[4],'suggested_number'=>$argv[4],'auto_extension'=>'1']);exit;
}
$schema='pbx_users_groups_'.bin2hex(random_bytes(6));$checks=0;$children=[];$previous=$_SESSION??[];
$q=static function($sql,$params=[])use($db){$s=$db->prepare($sql);$s->execute($params);return $s;};
$check=static function($yes,$message)use(&$checks){if(!$yes)throw new RuntimeException($message);$checks++;};
$reject=static function($call,$message)use($check){try{$call();}catch(InvalidArgumentException){$check(true,$message);return;}$check(false,$message);};
try{
    $db->exec('create schema '.$schema);$db->exec('set search_path to '.$schema.',public');
    foreach(['v_domains','v_extensions','v_voicemails','v_voicemail_greetings','v_voicemail_messages','v_dialplans','v_dialplan_details','v_pbx_restore','v_ring_groups','v_ring_group_destinations','v_call_center_queues','v_call_center_agents','v_call_center_tiers','v_ivr_menus','v_ivr_menu_options','v_pbx_media'] as $table)$db->exec('create table '.$table.'(like public.'.$table.' including all)');
    $domain=uuid();$foreign=uuid();$actor=uuid();
    foreach([$domain,$foreign] as $id)$q('insert into v_domains(domain_uuid,domain_name,domain_enabled) values(?,?,true)',[$id,$id.'.invalid']);
    $_SESSION=['authorized'=>true,'user_uuid'=>$actor,'domain_uuid'=>$domain,'domain_name'=>'users-groups.invalid'];
    $c=['realm'=>'users-groups.invalid','timezone'=>'UTC','users'=>[],'trunks'=>['provider'=>['number'=>'provider','name'=>'Fictional Provider']],'departments'=>[],'queues'=>[],'ring_groups'=>[],'receptionists'=>[],'scripts'=>[],'specials'=>[],'phones'=>[],'contacts'=>[],'inbound_rules'=>[],'outbound_rules'=>[]];
    foreach([$domain,$foreign] as $id)$q("insert into v_pbx_restore(domain_uuid,source_version,config) values(?,'fictional',?::jsonb)",[$id,json_encode($c)]);
    $foreignBefore=$q('select config from v_pbx_restore where domain_uuid=?',[$foreign])->fetchColumn();
    $admin=new users_groups_admin($db);
    $check($admin->nextExtension()==='1000','Empty PBX did not suggest 1000');
    $q("insert into v_extensions(extension_uuid,domain_uuid,extension,effective_caller_id_number) values(?,?,'legacy-auth','1000')",[uuid(),$domain]);
    $q("insert into v_voicemails(voicemail_uuid,domain_uuid,voicemail_id) values(?,?,'1001')",[uuid(),$domain]);
    $q("insert into v_extensions(extension_uuid,domain_uuid,extension) values(?,?,'ow-1002')",[uuid(),$domain]);
    $q("insert into v_dialplans(dialplan_uuid,domain_uuid,dialplan_number) values(?,?,'1003')",[uuid(),$domain]);
    $check($admin->nextExtension()==='1004','Native-only users, auth IDs, mailboxes or dialplans collided');
    $one=$admin->save('user','new',$input);$check($one==='1004','Blank extension did not allocate a free number');
    $created=$admin->config()['users'][$one];$check($created['contact_user']===$one&&$q('select number_alias from v_extensions where extension_uuid=?',[$created['extension_uuid']])->fetchColumn()===$one,'New phone identity did not retain its dialled extension and separate authentication ID');
    $two=$admin->save('user','new',$input+['number'=>'1010']);$check($two==='1010','Administrator manual override was ignored');
    $before=$admin->config();$nativeBefore=$q('select password from v_extensions where extension_uuid=?',[$before['users'][$one]['extension_uuid']])->fetchColumn();
    $reject(fn()=>$admin->save('user','new',$input+['number'=>'1000']),'Occupied native number accepted');
    $reject(fn()=>$admin->save('user','new',$input+['number'=>'1010']),'Duplicate user extension accepted');
    $check($before===$admin->config(),'Rejected number changed the configuration');
    $stale=$admin->save('user','new',$input+['number'=>'1010','suggested_number'=>'1010','auto_extension'=>'1']);$check($stale==='1005','Stale automatic suggestion did not safely select a free number');
    $manual=$admin->save('user','new',$input+['number'=>'1020','suggested_number'=>'1005','auto_extension'=>'1']);$check($manual==='1020','Manual edit was treated as automatic without JavaScript');
    $a=$admin->save('department','new',['name'=>'Sales','members'=>[$one],'department_options_present'=>1]);
    $b=$admin->save('department','new',['name'=>'Support','members'=>[$one,$two]]);
    $c=$admin->config();$check(pbx_schedule::department($c,$one)['number']===$a,'Additional department stole primary membership');
    $check(count(pbx_departments::memberships($c,$one))===2,'Additional department membership was lost');
    $admin->save('user',$one,$input+['department'=>$b]);$c=$admin->config();
    $check(pbx_schedule::department($c,$one)['number']===$b&&count(pbx_departments::memberships($c,$one))===2,'Changing primary discarded secondary membership');
    $reject(fn()=>$admin->save('user',$one,$input+['department'=>'foreign']),'Foreign department accepted');
    $check($c===$admin->config(),'Invalid department changed user credentials or policy');
    $admin->save('department',$a,['name'=>'Sales','members'=>[$one,'provider']]);$c=$admin->config();
    $check(pbx_schedule::department($c,'provider')['number']===$a,'Provider could not join department');
    $check(pbx_schedule::department($c,$one)['number']===$b,'Department edit reset an existing primary');
    $group=$admin->save('ring_group','new',['number'=>'1100','name'=>'Fictional Sales Ring Group','timeout'=>'10','members'=>[$one,$two],'strategy'=>'Hunt','ring_order'=>$two.','.$one,'department'=>$a,'schedule_mode'=>'department','office_closed'=>'VoiceMail:'.$one,'office_break'=>'Extension:'.$two,'office_holiday'=>'None:']);
    $c=$admin->config();$g=$c['ring_groups'][0];$check($group==='1100'&&array_column($g['members'],'number')===[$two,$one],'Selected ring members or ordering did not persist');
    $check($q('select ring_group_strategy from v_ring_groups where ring_group_extension=?',[$group])->fetchColumn()==='sequence','Native ringing strategy not synchronized');
    $check(pbx_schedule::department($c,$group)['number']===$a&&$g['hours']['hours']['type']==='OfficeHours','Call handling did not inherit chosen department');
    $admin->save('hours',$a,['timezone'=>'UTC','periods'=>[['enabled'=>1,'day'=>1,'start'=>'08:00','end'=>'17:00']],'break_periods'=>[['enabled'=>1,'day'=>1,'start'=>'12:00','end'=>'13:00']],'holidays'=>'2026-12-25 Christmas']);$c=$admin->config();
    $check(pbx_schedule::objectDestination($c,$g,strtotime('2026-10-12 18:00 UTC'))['number']===$one,'Closed department did not route to selected voicemail');
    $check(pbx_schedule::objectDestination($c,$g,strtotime('2026-10-12 12:30 UTC'))['number']===$two,'Department break did not use selected destination');
    $check(pbx_schedule::objectDestination($c,$g,strtotime('2026-12-25 10:00 UTC'))['type']==='None','Department holiday destination did not apply');
    $check(pbx_schedule::objectDestination($c,$g,strtotime('2026-10-12 10:00 UTC'))===null,'Open department unexpectedly replaced normal ringing');
    $core=new pbx_core($db);$preview=$core->preview(['object'=>'ring_groups:'.$group,'preview_time'=>'2026-10-12T18:00']);
    $check($preview['office']==='Closed'&&str_starts_with($preview['destination'],'Voicemail for '),'Actual Admin preview disagrees with closed ring-group routing');
    $preview=$core->preview(['object'=>'ring_groups:'.$group,'preview_time'=>'2026-10-12T12:30']);$check(str_ends_with($preview['destination'],' · '.$two),'Actual Admin break preview disagrees with routing');
    foreach(['queue'=>'1200','receptionist'=>'1300'] as $kind=>$number){
        $admin->save($kind,'new',['number'=>$number,'name'=>'Fictional '.$kind,'timeout'=>'10','members'=>[$one],'strategy'=>'RingAll','department'=>$a,'schedule_mode'=>'department','office_closed'=>'VoiceMail:'.$one]);
        $preview=$core->preview(['object'=>($kind==='queue'?'queues':'receptionists').':'.$number,'preview_time'=>'2026-10-12T18:00']);$check(str_starts_with($preview['destination'],'Voicemail for '),'Selected department did not route '.$kind.' after hours');
    }
    $c=$admin->config();
    $before=$c;$reject(fn()=>$admin->save('ring_group',$group,['name'=>'Bad','members'=>[$one],'department'=>'foreign']),'Foreign handling department accepted');$check($before===$admin->config(),'Foreign handling save partially modified native policy');
    $out=$admin->save('outbound','new',['name'=>'Sales only','prefix'=>'0','lengths'=>'10','routes'=>[['trunk_id'=>'provider']],'caller_restrictions_present'=>1,'department_ids'=>[$a],'caller_ranges'=>'1020, 1030-1040']);
    $rule=$admin->config()['outbound_rules'][0];$check($rule['department_ids']===[$a]&&$rule['departments']===[]&&count($rule['ranges'])===2,'Outbound restrictions did not persist stable IDs and ranges');
    $legacy=$admin->config();$legacy['outbound_rules'][]=['rule_id'=>uuid(),'name'=>'Legacy','departments'=>['Sales'],'ranges'=>[],'routes'=>[]];$q('update v_pbx_restore set config=?::jsonb where domain_uuid=?',[json_encode($legacy),$domain]);
    $admin->save('department',$a,['name'=>'Sales Renamed','members'=>[$one,$group,'provider']]);$c=$admin->config();
    $check($c['outbound_rules'][0]['department_ids']===[$a]&&$c['outbound_rules'][1]['departments']===['Sales Renamed'],'Renaming broke stable or restored name restrictions');
    $check(pbx_schedule::department($c,$one)['number']===$b,'Renaming department changed primary membership');
    $reject(fn()=>$admin->save('department',$a,['name'=>'Support','members'=>[$one]]),'Ambiguous duplicate department name accepted');
    $before=$admin->config();$reject(fn()=>$admin->save('outbound',$out,['name'=>'No','routes'=>[['trunk_id'=>'provider']],'caller_restrictions_present'=>1,'department_ids'=>['foreign']]),'Foreign outbound department accepted');$check($before===$admin->config(),'Rejected outbound edit partially saved');
    $admin->save('user',$one,$input+['department'=>$a,'departments_present'=>1,'departments'=>[]]);$c=$admin->config();
    $admin->save('department',$a,['name'=>'Sales Renamed','members'=>[$one,$group,'provider'],'department_options_present'=>1]);$c=$admin->config();
    $check(!pbx_departments::visible($c,$two,$one),'Hidden department leaked into unrelated phone directory');
    $check(pbx_departments::visible($c,$one,$one),'User could not see own phone');
    $directory=(new pbx_mobile($db))->directory(['config'=>$c,'number'=>$two]);$check(!in_array($one,array_column($directory['contacts'],'number'),true),'Actual mobile directory ignored visibility');
    $admin->save('department',$a,['name'=>'Sales Renamed','members'=>[$one,$two,$group,'provider'],'department_options_present'=>1]);$c=$admin->config();
    $check(pbx_departments::visible($c,$two,$one),'Shared department directory member hidden');
    $check($nativeBefore===$q('select password from v_extensions where extension_uuid=?',[$c['users'][$one]['extension_uuid']])->fetchColumn(),'Department or normal user edits changed SIP password');
    // Two actual PHP processes submit the same displayed automatic suggestion.
    $suggested=$admin->nextExtension();
    for($i=0;$i<2;$i++){
        $pipes=[];$cmd=[PHP_BINARY];if(ini_get('auto_prepend_file'))$cmd=array_merge($cmd,['-d','auto_prepend_file='.ini_get('auto_prepend_file')]);$cmd=array_merge($cmd,[__FILE__,'--allocate',$schema,$domain,$suggested]);
        $process=proc_open($cmd,[0=>['pipe','r'],1=>['pipe','w'],2=>['pipe','w']],$pipes);if(!is_resource($process))throw new RuntimeException('Could not start owned concurrency worker.');fclose($pipes[0]);$children[]=[$process,$pipes];
    }
    $allocated=[];foreach($children as [$process,$pipes]){$allocated[]=trim(stream_get_contents($pipes[1]));$stderr=stream_get_contents($pipes[2]);fclose($pipes[1]);fclose($pipes[2]);$exit=proc_close($process);$check($exit===0&&$stderr==='','Automatic concurrent save failed');}$children=[];
    $check(count(array_unique($allocated))===2,'Concurrent users received duplicate extensions');
    foreach($allocated as $number)$check(isset($admin->config()['users'][$number]),'Concurrent allocated user missing from committed policy');
    $check($foreignBefore===$q('select config from v_pbx_restore where domain_uuid=?',[$foreign])->fetchColumn(),'Another PBX was changed');
    echo 'PASS: '.$checks." automatic extension, concurrent save, department membership, native ring group, schedules, restrictions and directory checks\n";
}finally{
    foreach($children as [$process,$pipes]){if(is_resource($process))proc_terminate($process);foreach($pipes as $pipe)if(is_resource($pipe))fclose($pipe);if(is_resource($process))proc_close($process);}
    if($db->inTransaction())$db->rollBack();$db->exec('set search_path to public');$db->exec('drop schema if exists '.$schema.' cascade');$_SESSION=$previous;
}
