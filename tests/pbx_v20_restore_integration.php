<?php
/** Optional full backup check. Customer data is never a repository fixture or printed. */
if(PHP_SAPI!=='cli'){http_response_code(404);exit;}
require dirname(__DIR__).'/resources/require.php';
$source=getenv('OPENWEB_PRIVATE_BACKUP');if(!$source){echo "Set OPENWEB_PRIVATE_BACKUP to a private V20 backup.\n";exit(2);}
$db=$database->db;$db->setAttribute(PDO::ATTR_ERRMODE,PDO::ERRMODE_EXCEPTION);$schema='openweb_v20_check_'.bin2hex(random_bytes(6));$restore=null;
$assert=function($ok,$why){if(!$ok)throw new RuntimeException($why);};
try{
    $db->exec('create schema '.$schema);$db->exec('set search_path to '.$schema.',public');
    foreach(['v_menu_items','v_menu_languages','v_domains','v_extensions','v_voicemails','v_gateways','v_ring_groups','v_ring_group_destinations','v_destinations','v_dialplans','v_dialplan_details','v_call_center_agents','v_call_center_queues','v_call_center_tiers','v_ivr_menus','v_ivr_menu_options','v_devices','v_device_lines','v_device_keys','v_contacts','v_contact_phones','v_recordings','v_voicemail_messages','v_voicemail_greetings'] as $table)$db->exec('create table '.$table.'(like public.'.$table.' including all)');
    $db->exec(file_get_contents(dirname(__DIR__).'/app/pbx_setup/resources/restore.sql'));
    $plan=threecx_backup::analyze($source);pbx_v20_restore::validate($plan);$safe=threecx_backup::preview($plan);
    foreach($plan['users'] as $u){$assert(!str_contains(json_encode($safe),$u['password']),'A user password appeared in preview');$assert(!str_contains(json_encode($safe),$u['voicemail_pin']),'A voicemail PIN appeared in preview');}
    foreach($plan['v20']['scripts'] as $s)foreach($s['pin_map'] as $pin=>$n)$assert(!str_contains(json_encode($safe),(string)$pin),'A call-menu PIN appeared in preview');
    $domain=uuid();$realm='verify-'.bin2hex(random_bytes(6)).'.example.invalid';$db->beginTransaction();
    $stmt=$db->prepare('insert into v_domains(domain_uuid,domain_name,domain_enabled) values(?,?,true)');$stmt->execute([$domain,$realm]);
    (new pbx_setup_provisioner($db))->apply($domain,$realm,$plan);$restore=new pbx_v20_restore($db);$report=$restore->apply($domain,$realm,$plan,$source);
    foreach(['users'=>'v_extensions','trunks'=>'v_gateways','queues'=>'v_call_center_queues','receptionists'=>'v_ivr_menus','ring_groups'=>'v_ring_groups','inbound_rules'=>'v_destinations','phones'=>'v_devices'] as $k=>$t)$assert((int)$db->query('select count(*) from '.$t)->fetchColumn()===$report[$k],'Restored count differs: '.$k);
    $assert((int)$db->query("select count(*) from v_gateways where enabled='true'")->fetchColumn()===0,'An unchecked provider was enabled');
    $assert((int)$db->query("select count(*) from v_destinations where destination_enabled='true'")->fetchColumn()===0,'An unchecked number was enabled');
    $assert((int)$db->query('select count(*) from v_pbx_call_history')->fetchColumn()===$report['call_history'],'Call history differs');
    $config=json_decode($db->query('select config from v_pbx_restore')->fetchColumn(),true);
    foreach($plan['users'] as $u){$stored=$db->prepare('select password from v_extensions where extension=?');$stored->execute([$u['auth_id']]);$assert(hash_equals($u['password'],$stored->fetchColumn()),'A phone password changed');}
    $assert((int)$db->query('select count(*) from v_voicemail_greetings')->fetchColumn()===$report['voicemail_greetings'],'Voicemail greetings differ');
    $assert(count($config['departments'])===count($plan['v20']['departments']),'A department was lost');
    $assert(count($config['outbound_rules'])===count($plan['v20']['outbound_rules']),'An outbound rule was lost');
    foreach($db->query('select file_path from v_pbx_media') as $row)$assert(is_file($row['file_path']),'A restored recording is missing');
    $db->commit();
    $_SESSION=['user_uuid'=>uuid(),'domain_uuid'=>$domain,'domain_name'=>$realm,'user'=>['domain_uuid'=>$domain]];
    $admin=new pbx_admin($db);$first=(string)array_key_first($config['users']);$u=$config['users'][$first];
    $admin->save('user',$first,['name'=>'Private restore check','email'=>'check@example.invalid','profile'=>$u['profile'],'timeout'=>'25','enabled'=>'1','voicemail_enabled'=>'1','department'=>'']);
    $assert($admin->config()['users'][$first]['name']==='Private restore check','Simple user save failed');
    // Changing status must not copy the former status's forwarding fields into it.
    $beforeProfile=$admin->config()['users'][$first]['profiles']['Away'];
    $admin->save('user',$first,['name'=>'Private restore check','profile'=>'Away','editing_profile'=>$u['profile'],'timeout'=>'25','enabled'=>'1']);
    $assert($admin->config()['users'][$first]['profiles']['Away']===$beforeProfile,'Changing status overwrote its forwarding rules');
    foreach($config['users'] as $number=>$person)if(!empty($person['greetings'])){
        $greeting=$person['greetings'][0]['id'];
        $admin->save('user',(string)$number,['name'=>'Greeting check','profile'=>$person['profile'],'timeout'=>'20','greeting_id'=>$greeting]);
        $s=$db->prepare('select greeting_id from v_voicemails where domain_uuid=? and voicemail_id=?');$s->execute([$domain,(string)$number]);
        $assert((string)$s->fetchColumn()===$greeting,'Selecting a voicemail greeting failed');break;
    }
    $added=$admin->save('user','new',['number'=>'99998','name'=>'Fixture User','profile'=>'Available','timeout'=>'20','enabled'=>'1','voicemail_enabled'=>'1']);
    $assert($added==='99998'&&strlen($admin->credentials($added)['password'])>20,'User creation or private phone details failed');
    foreach(['ring_group'=>'99990','queue'=>'99991','receptionist'=>'99992'] as $type=>$number){$input=['number'=>$number,'name'=>'Fixture '.$type,'timeout'=>'60','ring_timeout'=>'10','wrap_up'=>'2','members'=>[$first],'destination'=>'Extension:'.$first,'options'=>['1'=>['destination'=>'Extension:'.$first]]];$assert($admin->save($type,'new',$input)===$number,'Simple call handling creation failed');}
    $department=$admin->save('department','new',['name'=>'Fixture department','members'=>[$added]]);
    $admin->save('hours',$department,['timezone'=>'Africa/Johannesburg','days'=>['1'=>['open'=>'1','start'=>'08:00','end'=>'17:00']]]);
    $trunk=(string)array_key_first($config['trunks']);
    $admin->save('outbound','new',['name'=>'Fixture outgoing','prefix'=>'9','lengths'=>'10','routes'=>[['trunk_id'=>$trunk,'strip'=>'1','prepend'=>'+27','caller_id'=>'']]]);
    $newTrunk=$admin->save('trunk','new',['name'=>'Fixture IP Trunk','host'=>'127.0.0.1','port'=>'5099','authentication'=>'ip','main_number'=>'+27112345678','caller_id'=>'+27112345678']);
    $number=$admin->save('incoming','new',['number'=>'+27112345678','trunk_id'=>$newTrunk,'office'=>'Extension:'.$added,'outside'=>'VoiceMail:'.$added]);
    $assert(!$admin->config()['trunks'][$newTrunk]['enabled'],'A new trunk was enabled before checking');
    $admin->save('trunk',$newTrunk,['name'=>'Fixture IP Trunk','host'=>'127.0.0.1','authentication'=>'ip','allowed_ips'=>'127.0.0.1','enabled'=>'1']);
    $admin->save('incoming',$number,['enabled'=>'1','office'=>'Extension:'.$added]);
    // A second tenant must not take the same incoming number from the same provider.
    $foreignDomain=uuid();$s=$db->prepare('insert into v_domains(domain_uuid,domain_name,domain_enabled) values(?,?,true)');$s->execute([$foreignDomain,'binding-check.example.invalid']);
    $foreign=$admin->config();$foreign['inbound_rules']=array_values(array_filter($foreign['inbound_rules'],fn($r)=>$r['rule_id']===$number));$foreign['inbound_rules'][0]['rule_id']=uuid();
    $s=$db->prepare('insert into v_pbx_restore(domain_uuid,source_version,config) values(?,?,cast(? as jsonb))');$s->execute([$foreignDomain,'20.0.9.995',json_encode($foreign)]);
    try{$admin->save('incoming',$number,['enabled'=>'1']);throw new RuntimeException('A competing tenant number was accepted');}catch(InvalidArgumentException){}
    $s=$db->prepare('delete from v_pbx_restore where domain_uuid=?');$s->execute([$foreignDomain]);
    $admin->save('trunk',$newTrunk,['name'=>'Fixture IP Trunk','host'=>'127.0.0.1','authentication'=>'ip','allowed_ips'=>'127.0.0.2','enabled'=>'1']);
    $s=$db->prepare('select dialplan_xml from v_dialplans where dialplan_uuid=?');$s->execute([$admin->config()['inbound_rules'][count($admin->config()['inbound_rules'])-1]['dialplan_uuid']]);
    $assert(str_contains($s->fetchColumn(),'127\.0\.0\.2'),'Changing the provider address left stale incoming checks');

    $admin->delete('queue','99991');$admin->delete('ring_group','99990');$admin->delete('receptionist','99992');
    try{$admin->delete('user',$added);throw new RuntimeException('A referenced user was deleted');}catch(InvalidArgumentException){}
    // Remove the fixture number's reference, then delete the fixture user.
    $admin->save('incoming',$number,['office'=>'None:','outside'=>'None:']);$admin->delete('user',$added);
    $assert(!isset($admin->config()['users'][$added]),'User deletion failed');
    $before=json_encode($admin->config());try{$admin->save('user','outside-pbx',['name'=>'Foreign']);throw new RuntimeException('A foreign user was accepted');}catch(InvalidArgumentException){}
    $assert(json_encode($admin->config())===$before,'Rejected edit changed the PBX');
    $restore->rollbackFiles();$restore=null;
    echo json_encode(['result'=>'passed','counts'=>$report],JSON_PRETTY_PRINT)."\n";
}finally{
    if($db->inTransaction())$db->rollBack();if($restore)$restore->rollbackFiles();$db->exec('set search_path to public');$db->exec('drop schema if exists '.$schema.' cascade');
}
