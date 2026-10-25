<?php
/** Actual administrator saves and schedule previews in an owned PostgreSQL schema; no calls or mail. */
if(PHP_SAPI!=='cli')exit(2);
require dirname(__DIR__).'/resources/require.php';
class group_hours_admin extends pbx_admin {
    protected function changed(?string $trunk=null,?string $queue=null): void {}
    protected function engine(string $command): string {return '+OK';}
}
$db=$database->db;$schema='pbx_group_hours_'.bin2hex(random_bytes(6));$session=$_SESSION??[];$checks=0;
$q=static function($sql,$params=[])use($db){$s=$db->prepare($sql);$s->execute($params);return $s;};
$ok=static function(bool $condition,string $label)use(&$checks){if(!$condition)throw new RuntimeException($label);$checks++;};
$reject=static function(callable $call,string $label)use($ok){try{$call();}catch(InvalidArgumentException){$ok(true,$label);return;}$ok(false,$label);};
try {
    $db->exec('create schema '.$schema.';set search_path to '.$schema.',public');
    foreach(['v_domains','v_users','v_extensions','v_voicemails','v_voicemail_greetings','v_voicemail_messages','v_dialplans','v_dialplan_details','v_pbx_restore','v_pbx_media','v_pbx_staff_roles','v_pbx_staff_audit','v_pbx_sip_domains'] as $table)$db->exec('create table '.$table.'(like public.'.$table.' including all)');
    $domain=uuid();$foreign=uuid();$actor=uuid();
    foreach([$domain,$foreign] as $id)$q('insert into v_domains(domain_uuid,domain_name,domain_enabled) values(?,?,true)',[$id,$id.'.invalid']);
    $q('insert into v_users(user_uuid,domain_uuid,username,user_enabled) values(?,?,?,true)',[$actor,$domain,'group-hours-owner@example.invalid']);
    $c=['realm'=>$domain.'.invalid','timezone'=>'Africa/Johannesburg','users'=>[],'departments'=>[],'trunks'=>[],'queues'=>[],'ring_groups'=>[],'receptionists'=>[],'scripts'=>[],'specials'=>[],'phones'=>[],'contacts'=>[],'inbound_rules'=>[['rule_id'=>'preserved-incoming','office'=>['type'=>'Extension','number'=>'1000'],'outside'=>['type'=>'VoiceMail','number'=>'1000']]],'outbound_rules'=>[['name'=>'Preserved outbound','departments'=>['Global Lighting'],'ranges'=>[],'routes'=>[['trunk_id'=>'unchanged-provider']]]]];
    foreach([$domain,$foreign] as $id)$q("insert into v_pbx_restore(domain_uuid,source_version,config) values(?,'fictional-group-hours',?::jsonb)",[$id,json_encode($c)]);
    $_SESSION=['authorized'=>true,'user_uuid'=>$actor,'domain_uuid'=>$domain,'domain_name'=>$c['realm']];$admin=new group_hours_admin($db);
    $userInput=['name'=>'Fictional User','enabled'=>'1','voicemail_enabled'=>'1','profile'=>'Available','editing_profile'=>'Available','timeout'=>'20'];
    foreach(['1000','1001','1002','1003'] as $number)$admin->save('user','new',$userInput+['number'=>$number]);
    $company=$admin->save('department','new',['name'=>'Global Lighting','members'=>['1000','1001']]);
    $other=$admin->save('department','new',['name'=>'Other Company','members'=>['1002']]);
    $baseline=$admin->config();$foreignBefore=$q('select config from v_pbx_restore where domain_uuid=?',[$foreign])->fetchColumn();
    $nativeBefore=$q('select extension_uuid,extension,password from v_extensions order by extension_uuid')->fetchAll(PDO::FETCH_ASSOC);
    $groupInput=['name'=>'Global Lighting','members'=>['1000','1001']];
    $hours=['timezone'=>'Africa/Johannesburg','periods'=>[['enabled'=>'1','day'=>'1','start'=>'08:00','end'=>'17:00']],'break_periods'=>[['enabled'=>'1','day'=>'1','start'=>'12:00','end'=>'13:00']],'holidays'=>"2026-12-25 Christmas"];
    $admin->save('department',$company,$groupInput+$hours);
    $ok($admin->config()===$baseline,'Older group form does not change existing hours without an explicit action');
    $admin->save('department',$company,$groupInput+$hours+['group_hours_action'=>'save']);
    $saved=$admin->config();$department=pbx_departments::find($saved,$company);
    $when=static fn(string $local):int=>(new DateTimeImmutable($local,new DateTimeZone('Africa/Johannesburg')))->getTimestamp();
    $ok(pbx_schedule::office($department,'UTC',$when('2026-10-19 09:00'))['open'],'Group edit saves effective opening hours');
    $ok(!pbx_schedule::office($department,'UTC',$when('2026-10-19 19:00'))['open'],'Group edit applies closed hours');
    $ok(pbx_schedule::office($department,'UTC',$when('2026-10-19 12:30'))['break'],'Group edit retains breaks');
    $ok(pbx_schedule::office($department,'UTC',$when('2026-12-25 09:00'))['holiday'],'Group edit retains holidays');
    $ok(pbx_departments::find($saved,$other)===pbx_departments::find($baseline,$other),'Saving one group leaves another group exact');
    $ok($saved['inbound_rules']===$baseline['inbound_rules']&&$saved['outbound_rules']===$baseline['outbound_rules'],'Saving group hours preserves all imported routes');
    $userBefore=$saved['users'][1000];
    $admin->save('user','1000',$userInput+['office_routing_enabled'=>'1','office_open_route'=>'Extension:1001','office_closed_route'=>'VoiceMail:1000']);
    $ok($admin->config()['users'][1000]===$userBefore,'Marker-free legacy user forms cannot enable or replace office routing');
    $routing=['office_routing_present'=>'1','office_routing_enabled'=>'1','office_open_route'=>'Extension:1001','office_closed_route'=>'VoiceMail:1000'];
    $reject(fn()=>$admin->save('user','1003',$userInput+$routing),'Office-hour routes require an assigned company group');
    $admin->save('user','1000',$userInput+$routing);
    $config=$admin->config();$user=$config['users'][1000];
    $ok(pbx_schedule::userDestination($config,$user,$when('2026-10-19 09:00'))['number']==='1001','Open office uses the selected extension destination');
    $ok(pbx_schedule::userDestination($config,$user,$when('2026-10-19 19:00'))['type']==='VoiceMail','Closed office uses its separate voicemail destination');
    $ok(pbx_schedule::userDestination($config,$user,$when('2026-10-19 12:30'))['type']==='VoiceMail','Breaks use the out-of-office destination');
    $ok(pbx_schedule::userDestination($config,$user,$when('2026-12-25 09:00'))['type']==='VoiceMail','Holidays use the out-of-office destination');
    $core=new pbx_core($db);
    $preview=$core->preview(['object'=>'user:1000','preview_time'=>'2026-10-19T09:00']);
    $ok($preview['office']==='Open'&&str_ends_with($preview['destination'],'1001'),'Call Routing preview reflects the actual in-office user route');
    $preview=$core->preview(['object'=>'user:1000','preview_time'=>'2026-10-19T19:00']);
    $ok($preview['office']==='Closed'&&str_starts_with($preview['destination'],'Voicemail for '),'Call Routing preview reflects the separate out-of-office user route');
    foreach(['closed'=>'VoiceMail','open'=>'Extension'] as $override=>$targetType){
        $admin->save('hours',$company,$hours+['apply_override'=>'1','office_override'=>$override,'override_minutes'=>'5']);
        $overridden=$admin->config();
        $ok(pbx_schedule::userDestination($overridden,$overridden['users'][1000],time())['type']===$targetType,'Temporary company '.$override.' override controls user routing');
    }
    $admin->save('hours',$company,$hours+['apply_override'=>'1','office_override'=>'automatic']);
    $user['internal_after_hours']=true;
    $ok(pbx_schedule::userDestination($config,$user,$when('2026-10-19 19:00'),true)===null,'Authenticated direct internal exception retains ringing after hours');
    $ok(pbx_schedule::userDestination($config,$user,$when('2026-10-19 19:00'),false)['type']==='VoiceMail','Internal preference does not bypass outside-call routing');
    $admin->save('hours',$company,['timezone'=>'Africa/Johannesburg','periods'=>[['enabled'=>'1','day'=>'1','start'=>'22:00','end'=>'02:00']],'break_periods'=>[],'holidays'=>'']);
    $config=$admin->config();$user=$config['users'][1000];
    $ok(pbx_schedule::userDestination($config,$user,$when('2026-10-19 23:30'))['type']==='Extension','Overnight office starts on the selected day');
    $ok(pbx_schedule::userDestination($config,$user,$when('2026-10-20 01:30'))['type']==='Extension','Overnight office continues on the following day');
    $ok(pbx_schedule::userDestination($config,$user,$when('2026-10-20 02:00'))['type']==='VoiceMail','Overnight closing boundary is exclusive');
    foreach([['group_hours_action'=>'bad'],['group_hours_action'=>[]],['group_hours_action'=>'save','timezone'=>'Not/AZone']] as $bad){
        $before=$admin->config();$reject(fn()=>$admin->save('department',$company,array_replace($groupInput,$hours,$bad)),'Invalid company hours rejected');
        $ok($admin->config()===$before&&!$db->inTransaction(),'Rejected company edit rolls back every row');
    }
    foreach([['office_routing_present'=>[]],['office_routing_enabled'=>[]],['office_open_route'=>'Extension:9999'],['office_open_route'=>'Extension:1000'],['office_closed_route'=>'External:','office_closed_route_external'=>'sofia/foreign']] as $bad){
        $before=$admin->config();$reject(fn()=>$admin->save('user','1000',array_replace($userInput,$routing,$bad)),'Invalid, foreign or self-referencing user route rejected');
        $ok($admin->config()===$before&&!$db->inTransaction(),'Rejected user route preserves the transaction');
    }
    $reject(fn()=>$admin->save('user','1002',$userInput+['office_routing_present'=>'1','office_routing_enabled'=>'1','office_open_route'=>'Extension:9999','office_closed_route'=>'None:']),'Foreign destination cannot be selected for another company');
    $savedRouting=$admin->config()['users'][1000]['office_routing'];
    $admin->save('user','1000',$userInput+['office_routing_present'=>'1']);
    $disabled=$admin->config()['users'][1000];
    $ok($disabled['office_routing']['enabled']===false&&$disabled['office_routing']['outside']===$savedRouting['outside']&&$disabled['office_routing']['office']===$savedRouting['office'],'Disabled state is stored without silently changing saved routes');
    $ok(pbx_schedule::userDestination($admin->config(),$disabled,$when('2026-10-20 12:00'))===pbx_schedule::objectDestination($admin->config(),$disabled,$when('2026-10-20 12:00')),'Disabling explicit routes restores the original routing logic');
    $admin->save('department',$company,$groupInput+['group_hours_action'=>'delete']);
    $config=$admin->config();$deleted=pbx_departments::find($config,$company);
    $ok($deleted['hours']['type']==='AllHours'&&$deleted['breaks']['periods']===[]&&$deleted['holidays']===[]&&!isset($deleted['office_override']),'Deletion removes only this group schedule, breaks, holidays and override');
    $ok(pbx_schedule::office($deleted,'UTC',$when('2026-10-20 02:00'))['open'],'Deleted schedule leaves the group always open');
    $ok($config['inbound_rules']===$baseline['inbound_rules']&&$config['outbound_rules']===$baseline['outbound_rules'],'Deleting schedules preserves original call routes');
    $ok(pbx_departments::find($config,$other)===pbx_departments::find($baseline,$other),'Deleting one schedule preserves another company exact');
    $ok($q('select extension_uuid,extension,password from v_extensions order by extension_uuid')->fetchAll(PDO::FETCH_ASSOC)===$nativeBefore,'All original SIP usernames and passwords remain exact');
    $ok($q('select config from v_pbx_restore where domain_uuid=?',[$foreign])->fetchColumn()===$foreignBefore,'Other tenant configuration remains exact');
    $created=$admin->save('department','new',['name'=>'New Company','members'=>[],'group_hours_action'=>'save']+$hours);
    $ok(pbx_schedule::office(pbx_departments::find($admin->config(),$created),'UTC',$when('2026-10-19 09:00'))['open'],'Creating a company group can create its opening hours in the same transaction');
    // Render the actual shared schedule controls and actual user routing panel.
    $e=static fn($s)=>htmlspecialchars((string)$s,ENT_QUOTES,'UTF-8');
    $departmentName=static fn($s)=>$s;
    $input=static function($name,$label,$value='',$type='text',$extra='')use($e){echo '<label>'.$e($label).'<input name="'.$e($name).'" type="'.$e($type).'" value="'.$e($value).'" '.$extra.'></label>';};
    $select=static function($name,$label,$choices,$value='',$extra='')use($e){echo '<label>'.$e($label).'<select name="'.$e($name).'" '.$extra.'>';foreach($choices as $id=>$title)echo '<option value="'.$e($id).'"'.((string)$id===(string)$value?' selected':'').'>'.$e($title).'</option>';echo '</select></label>';};
    $check=static function($name,$label,$selected=false,$submitted='1')use($e){echo '<label><input type="checkbox" name="'.$e($name).'" value="'.$e($submitted).'"'.($selected?' checked':'').'>'.$e($label).'</label>';};
    $c=$admin->config();$row=pbx_departments::find($c,$company);
    ob_start();try{require dirname(__DIR__).'/app/pbx_setup/office-hours-fields.php';$html=ob_get_contents();}finally{ob_end_clean();}
    $ok(str_contains($html,'name="timezone"')&&str_contains($html,'name="periods[0][start]"')&&str_contains($html,'name="break_periods[0][start]"')&&str_contains($html,'name="holidays"'),'Shared company editor renders timezone, opening times, breaks and holiday controls');
    $source=file_get_contents(dirname(__DIR__).'/app/pbx_setup/edit.php');$start=strpos($source,'<div data-panel="office-routing">');$end=strpos($source,'<div data-panel="provisioning">',$start);$fragment=substr($source,$start,$end-$start);
    $key='1000';$row=$c['users'][1000];$department=static fn($n)=>pbx_schedule::department($c,$n)??['number'=>'','name'=>''];
    ob_start();try{eval('?>'.$fragment);$html=ob_get_contents();}finally{ob_end_clean();}
    $dom=new DOMDocument();$previous=libxml_use_internal_errors(true);try{$dom->loadHTML($html);}finally{libxml_clear_errors();libxml_use_internal_errors($previous);}$xpath=new DOMXPath($dom);
    $ok($xpath->query('//input[@name="office_routing_present" and @value="1"]')->length===1,'Actual extension panel posts an explicit opt-in marker');
    $ok($xpath->query('//select[@name="office_open_route"]')->length===1&&$xpath->query('//select[@name="office_closed_route"]')->length===1,'Actual extension panel has independent open and closed destinations');
    $ok($xpath->query('//option[@value="Extension:1000"]')->length===0,'Actual route choices avoid a self-transfer loop');
    $ok(str_contains($dom->textContent,'Global Lighting')&&str_contains($dom->textContent,'direct calls between extensions can still ring after hours'),'Actual panel identifies the company and preserves the internal-hours explanation');
    echo 'PASS: '.$checks." PostgreSQL group-hours, extension-routing, preservation and rejection checks\n";
} finally {
    if($db->inTransaction())$db->rollBack();$db->exec('set search_path to public;drop schema if exists '.$schema.' cascade');$_SESSION=$session;
}
