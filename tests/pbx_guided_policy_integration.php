<?php
/** CLI-only real PostgreSQL checks; every record is in a disposable schema. */
if (PHP_SAPI !== 'cli') { http_response_code(404); exit; }
require dirname(__DIR__).'/resources/require.php';
class guided_policy_admin extends pbx_admin {
    protected function changed(?string $trunk=null, ?string $queue=null): void {}
    protected function engine(string $command): string { return ''; }
}
$db=$database->db; $db->setAttribute(PDO::ATTR_ERRMODE,PDO::ERRMODE_EXCEPTION);
$schema='openweb_guided_policy_'.bin2hex(random_bytes(6)); $checks=0;
$q=static function(string $sql,array $values=[])use($db):PDOStatement {
    $statement=$db->prepare($sql);
    foreach($values as $name=>$value)$statement->bindValue(':'.$name,$value,$value===null?PDO::PARAM_NULL:(is_bool($value)?PDO::PARAM_BOOL:(is_int($value)?PDO::PARAM_INT:PDO::PARAM_STR)));
    $statement->execute();return $statement;
};
$assert=static function(bool $value,string $label)use(&$checks):void {if(!$value)throw new RuntimeException($label);$checks++;};
$reject=static function(callable $work,string $label)use($assert):void {try{$work();}catch(Throwable $error){$assert(true,$label);return;}throw new RuntimeException($label);};
try {
    $db->exec('create schema '.$schema);$db->exec('set search_path to '.$schema.',public');
    $tables=['v_domains','v_users','v_user_groups','v_groups','v_group_permissions','v_permissions','v_menus','v_menu_items','v_menu_languages','v_menu_item_groups','v_dialplans','v_dialplan_details','v_domain_settings','v_extensions','v_voicemails','v_gateways','v_ring_groups','v_ring_group_destinations','v_destinations','v_default_settings','v_call_center_queues','v_call_center_agents','v_call_center_tiers','v_ivr_menus','v_ivr_menu_options'];
    foreach($tables as $table)$db->exec('create table '.$table.' (like public.'.$table.' including all)');
    foreach(['v_groups','v_group_permissions','v_permissions','v_default_settings'] as $table)$db->exec('insert into '.$table.' select * from public.'.$table);
    $db->exec(file_get_contents(dirname(__DIR__).'/app/tenant_services/resources/install.sql'));
    $db->exec(file_get_contents(dirname(__DIR__).'/app/pbx_setup/resources/install.sql'));
    $db->exec(file_get_contents(dirname(__DIR__).'/app/pbx_setup/resources/restore.sql'));
    $home=uuid();$owner=uuid();
    $host=pbx_paths::host();
    $q('insert into v_domains(domain_uuid,domain_name,domain_enabled) values(:id,:name,true)',['id'=>$home,'name'=>$host]);
    foreach(glob(PROJECT_ROOT.'/app/dialplans/resources/switch/conf/dialplan/*.xml') as $file){
        $document=new DOMDocument();$document->load($file,LIBXML_NONET);$extension=$document->documentElement;
        if($extension->tagName!=='extension'||!str_contains($extension->getAttribute('context'),'${domain_name}'))continue;
        $q('insert into v_dialplans(dialplan_uuid,domain_uuid,app_uuid,dialplan_name,dialplan_context,dialplan_xml,dialplan_enabled) values(:id,:domain,:app,:name,:context,:xml,true)',
            ['id'=>uuid(),'domain'=>$home,'app'=>$extension->getAttribute('app_uuid'),'name'=>$extension->getAttribute('name'),
            'context'=>str_replace('${domain_name}',$host,$extension->getAttribute('context')),'xml'=>$document->saveXML($extension)]);
        break;
    }
    $q('insert into v_users(user_uuid,domain_uuid,username,user_email,user_enabled) values(:id,:domain,:email,:email,true)',['id'=>$owner,'domain'=>$home,'email'=>'guided-owner@example.invalid']);
    $_SESSION=['authorized'=>true,'user_uuid'=>$owner,'domain_uuid'=>$home,'domain_name'=>$host,'user'=>['domain_uuid'=>$home],
        'permissions'=>array_fill_keys(['pbx_service_create','pbx_tenant_manage','domain_all','gateway_edit'],1)];
    $setup=new pbx_setup($db);
    $input=['company_name'=>'Fictional guided company','service_name'=>'Fictional first calls','timezone'=>'UTC','tenant_uuid'=>'',
        'users'=>[['number'=>'8100','name'=>'Fictional first','email'=>'first@example.invalid'],['number'=>'8101','name'=>'Fictional second','email'=>'']],
        'trunk'=>['host'=>'sip.example.invalid','name'=>'Fictional disabled provider','authentication'=>'password','username'=>'fixture-provider','password'=>'generated-provider-test-only'],
        'outbound'=>['prefix'=>'0','strip'=>'1','prepend'=>'+27'],'inbound_number'=>'+27110000000','inbound_destination'=>'8100'];
    $draft=$setup->reviewSetup($input);
    $sealed=base64_decode($q('select payload_ciphertext from v_pbx_setup_drafts where draft_uuid=:id',['id'=>$draft['draft_id']])->fetchColumn(),true);
    $reviewed=json_decode(sodium_crypto_secretbox_open(substr($sealed,24),substr($sealed,0,24),file_get_contents(pbx_paths::key())),true,512,JSON_THROW_ON_ERROR)['plan'];
    $domain=$setup->createSetup($draft['draft_id']);
    $realm=$q('select domain_name from v_domains where domain_uuid=:d',['d'=>$domain])->fetchColumn();
    $_SESSION['domain_uuid']=$domain;$_SESSION['domain_name']=$realm;
    $admin=new guided_policy_admin($db);$c=$admin->config();
    $assert($c['realm']===$realm&&$c['timezone']==='UTC'&&$c['origin']==='OpenWeb PBX','New setup has no native/admin calling policy');
    $assert(array_keys($c['users'])===[8100,8101]&&count($c['trunks'])===1,'Reviewed users/providers were not mapped');
    $assert(count($c['queues'])===0&&count($c['receptionists'])===0&&count($c['departments'])===0,'Unrequested call objects were fabricated');
    $accounts=$q('select * from v_extensions where domain_uuid=:d order by extension',['d'=>$domain])->fetchAll(PDO::FETCH_ASSOC);
    $mailboxes=$q('select * from v_voicemails where domain_uuid=:d order by voicemail_id',['d'=>$domain])->fetchAll(PDO::FETCH_ASSOC);
    foreach($accounts as $i=>$account){$number=$account['effective_caller_id_number'];$u=$c['users'][$number];
        $assert($u['extension_uuid']===$account['extension_uuid']&&$u['auth_id']===$account['extension']&&$u['contact_user']===$number,'Policy changed native phone identity');
        $assert(hash_equals($reviewed['users'][$i]['password'],$account['password'])&&$mailboxes[$i]['voicemail_uuid']===$u['voicemail_uuid']&&$mailboxes[$i]['voicemail_password']===$reviewed['users'][$i]['voicemail_pin'],'Reviewed generated credentials/mailbox identity were lost');
        $xml=$q('select dialplan_xml from v_dialplans where domain_uuid=:d and dialplan_uuid=:id',['d'=>$domain,'id'=>$u['dialplan_uuid']])->fetchColumn();
        $assert(str_contains($xml,'app.lua pbx_setup user '.$number),'New user is not dispatched through the current native core');
        $assert($u['profiles']['Available']['available']['NoAnswer']['all']['number']===$number&&$u['profiles']['Away']['away']['Internal']['all']['type']==='VoiceMail','Default no-answer/away policy was lost');
        $assert(!str_contains(json_encode($c,JSON_THROW_ON_ERROR),$account['password'])&&!str_contains(json_encode($c,JSON_THROW_ON_ERROR),$mailboxes[$i]['voicemail_password']),'Policy duplicated private credentials');
    }
    $trunk=$c['trunks']['wizard-trunk'];$gateway=$q('select * from v_gateways where domain_uuid=:d',['d'=>$domain])->fetch(PDO::FETCH_ASSOC);
    $assert($trunk['gateway_uuid']===$gateway['gateway_uuid']&&!$trunk['enabled']&&!$gateway['enabled']&&$trunk['allowed_ips']===[],'Setup enabled an unverified provider');
    $assert($gateway['password']==='generated-provider-test-only'&&!str_contains(json_encode($c,JSON_THROW_ON_ERROR),$gateway['password']),'Original provider credential changed or leaked to policy');
    $incoming=$c['inbound_rules'][0];$destination=$q('select * from v_destinations where domain_uuid=:d',['d'=>$domain])->fetch(PDO::FETCH_ASSOC);
    $assert($incoming['rule_id']===$destination['destination_uuid']&&$incoming['dialplan_uuid']===$destination['dialplan_uuid']&&!$incoming['enabled']&&!$destination['destination_enabled'],'Incoming native IDs/disabled state changed');
    $assert($destination['destination_app']==='lua'&&$destination['destination_data']==='app.lua pbx_setup incoming '.$incoming['rule_id']&&$incoming['office']['number']==='8100','Incoming dispatch/target missing');
    $route=$c['outbound_rules'][0];
    $assert($route['prefix']==='0'&&$route['routes'][0]['strip']===1&&$route['routes'][0]['prepend']==='+27','Reviewed outgoing rule changed');
    $assert((int)$q("select count(*) from v_dialplan_details where domain_uuid=:d and dialplan_detail_type='lua' and dialplan_detail_data='app.lua pbx_setup outbound all'",['d'=>$domain])->fetchColumn()===1,'Missing or duplicate dynamic outgoing dispatcher');
    $assert((int)$q("select count(*) from v_dialplan_details where domain_uuid=:d and dialplan_detail_data='app.lua pbx_setup voicemail_login *97'",['d'=>$domain])->fetchColumn()===1,'Native mailbox login dispatcher missing');
    $before=$q('select * from v_pbx_restore where domain_uuid=:d',['d'=>$domain])->fetch(PDO::FETCH_ASSOC);
    $assert($setup->createSetup($draft['draft_id'])===$domain&&$q('select * from v_pbx_restore where domain_uuid=:d',['d'=>$domain])->fetch(PDO::FETCH_ASSOC)===$before,'Retry regenerated policy/identities');
    $admin->save('user','8100',['name'=>'Fictional renamed','email'=>'first@example.invalid','enabled'=>'1','voicemail_enabled'=>'1','profile'=>'Available','timeout'=>'7','no_answer'=>'VoiceMail:8101','busy'=>'VoiceMail:8100','not_registered'=>'VoiceMail:8100']);
    $saved=$admin->config();
    $assert($saved['users'][8100]['name']==='Fictional renamed'&&$saved['users'][8100]['profiles']['Available']['available']['NoAnswer']['all']['number']==='8101','Normal Admin user save did not synchronize policy');
    $now=$q('select * from v_extensions where domain_uuid=:d order by extension',['d'=>$domain])->fetchAll(PDO::FETCH_ASSOC);
    $assert(array_column($now,'password')===array_column($accounts,'password')&&array_column($now,'extension_uuid')===array_column($accounts,'extension_uuid')&&array_column($now,'extension')===array_column($accounts,'extension'),'Normal edit changed generated SIP credentials/UUIDs');
    $admin->save('outbound',$route['rule_id'],['name'=>'Edited outgoing','prefix'=>'9','lengths'=>'10','routes'=>[['trunk_id'=>'wizard-trunk','strip'=>'1','prepend'=>'+44','caller_id'=>'']]]);
    $assert($admin->config()['outbound_rules'][0]['prefix']==='9'&&(int)$q("select count(*) from v_dialplan_details where domain_uuid=:d and dialplan_detail_data='app.lua pbx_setup outbound all'",['d'=>$domain])->fetchColumn()===1,'Outgoing edit left a stale direct-bridge dialplan');
    $assert(!$q('select enabled from v_gateways where domain_uuid=:d',['d'=>$domain])->fetchColumn(),'Normal edits connected the disabled provider');
    $admin->save('ring_group','new',['number'=>'8180','name'=>'Fictional guided hunt','members'=>['8100','8101'],'ring_order'=>'8101,8100','strategy'=>'Hunt','timeout'=>'5','destination'=>'VoiceMail:8100']);
    $group=$admin->config()['ring_groups'][0];
    $assert(array_column($group['members'],'number')===['8101','8100']&&$group['native_strategy']==='sequence'&&$group['destination']['type']==='VoiceMail','New guided PBX cannot create an ordered core ring group');
    $assert($q('select dialplan_uuid from v_ring_groups where domain_uuid=:d and ring_group_uuid=:id',['d'=>$domain,'id'=>$group['uuid']])->fetchColumn()===$group['dialplan_uuid'],'Normal ring group native IDs diverged from policy');
    $admin->save('queue','new',['number'=>'8190','name'=>'Fictional guided queue','members'=>['8100','8101'],'ring_order'=>'8101,8100','strategy'=>'PrioritizedHunt','timeout'=>'8','ring_timeout'=>'3','wrap_up'=>'2','destination'=>'VoiceMail:8100']);
    $queue=$admin->config()['queues'][0];
    $assert($queue['native_strategy']==='top-down'&&count($queue['members'])===2&&$queue['ring_timeout']===3&&$queue['wrap_up']===2,'New guided PBX cannot create a core queue');
    $assert((int)$q('select count(*) from v_call_center_tiers where domain_uuid=:d and call_center_queue_uuid=:id',['d'=>$domain,'id'=>$queue['uuid']])->fetchColumn()===2,'Normal queue native tiers were not created');
    $admin->save('receptionist','new',['number'=>'8170','name'=>'Fictional guided menu','timeout'=>'4','destination'=>'VoiceMail:8100','options'=>['2'=>['destination'=>'Extension:8101']]]);
    $ivr=$admin->config()['receptionists'][0];
    $assert($ivr['options'][0]['digit']==='2'&&$ivr['options'][0]['destination']['number']==='8101','New guided PBX cannot create a core receptionist');
    $assert($q('select dialplan_uuid from v_ivr_menus where domain_uuid=:d and ivr_menu_uuid=:id',['d'=>$domain,'id'=>$ivr['uuid']])->fetchColumn()===$ivr['dialplan_uuid'],'Normal IVR native IDs diverged from policy');
    // A no-provider wizard must also support future Admin additions and calling.
    $_SESSION['domain_uuid']=$home;$_SESSION['domain_name']=$host;
    $minimal=$input;$minimal['service_name']='Fictional no provider';$minimal['trunk']['host']='';$minimal['inbound_number']='';
    $minimalDraft=$setup->reviewSetup($minimal);$minimalDomain=$setup->createSetup($minimalDraft['draft_id']);
    $minimalPolicy=json_decode($q('select config from v_pbx_restore where domain_uuid=:d',['d'=>$minimalDomain])->fetchColumn(),true,512,JSON_THROW_ON_ERROR);
    $assert($minimalPolicy['trunks']===[]&&$minimalPolicy['outbound_rules']===[]&&count($minimalPolicy['users'])===2,'No-provider wizard failed policy initialization');
    $assert((int)$q("select count(*) from v_dialplan_details where domain_uuid=:d and dialplan_detail_data='app.lua pbx_setup outbound all'",['d'=>$minimalDomain])->fetchColumn()===1,'Future outgoing rules have no native dispatcher');
    $tenant=$q('select tenant_uuid from v_pbx_services where domain_uuid=:d',['d'=>$domain])->fetchColumn();$q('update v_pbx_tenants set service_limit=10 where tenant_uuid=:id',['id'=>$tenant]);
    // The policy insert is inside the existing complete setup transaction.
    $failed=$input;$failed['service_name']='Fictional policy rollback';$failed['tenant_uuid']=$tenant;
    $failedDraft=$setup->reviewSetup($failed);$counts=[];foreach(['v_domains','v_pbx_services','v_extensions','v_voicemails','v_gateways','v_destinations','v_dialplans','v_dialplan_details','v_pbx_restore'] as $table)$counts[$table]=(int)$q('select count(*) from '.$table)->fetchColumn();
    $db->exec("alter table v_pbx_restore add constraint guided_policy_failure check(config->>'origin' is distinct from 'OpenWeb PBX') not valid");
    $reject(fn()=>$setup->createSetup($failedDraft['draft_id']),'Failed policy insert was ignored');
    foreach($counts as $table=>$count)$assert((int)$q('select count(*) from '.$table)->fetchColumn()===$count,'Failed policy insert left native objects');
    $assert($q('select completed_domain_uuid from v_pbx_setup_drafts where draft_uuid=:id',['id'=>$failedDraft['draft_id']])->fetchColumn()===null,'Failed policy insert consumed the reviewed draft');
    $db->exec('alter table v_pbx_restore drop constraint guided_policy_failure');
    $foreign=uuid();$q('insert into v_domains(domain_uuid,domain_name,domain_enabled) values(:d,:name,true)',['d'=>$foreign,'name'=>'foreign-empty.example.invalid']);
    $provisioner=new pbx_setup_provisioner($db);$plan=['source_format'=>'guided_setup','users'=>[['number'=>'9100','name'=>'Fictional guard','email'=>'','auth_id'=>'9100','password'=>'fictional-preserved-secret','voicemail_pin'=>'001234','enabled'=>true]],'trunks'=>[],'ring_groups'=>[],'inbound_rules'=>[],'outbound_rules'=>[]];
    $db->beginTransaction();$reject(fn()=>$provisioner->apply($foreign,'foreign-empty.example.invalid',$plan,'UTC'),'Foreign empty domain accepted as owned guided setup');$db->rollBack();
    $db->beginTransaction();$reject(fn()=>$provisioner->apply($foreign,'foreign-empty.example.invalid',$plan),'Unreviewed guided timezone accepted');$db->rollBack();
    $plan['v20']=[];$db->beginTransaction();$reject(fn()=>$provisioner->apply($foreign,'foreign-empty.example.invalid',$plan,'UTC'),'Source restore silently treated as guided setup');$db->rollBack();unset($plan['v20']);
    $plan['source_format']='configuration';$db->beginTransaction();$provisioner->apply($foreign,'foreign-empty.example.invalid',$plan);
    $assert(!(bool)$q('select 1 from v_pbx_restore where domain_uuid=:d',['d'=>$foreign])->fetchColumn(),'Non-guided import behavior changed');$db->rollBack();
    echo 'PASS '.$checks." real PostgreSQL normal guided policy/identity/edit/rollback/scope checks\n";
} finally {
    if($db->inTransaction())$db->rollBack();$db->exec('set search_path to public');$db->exec('drop schema if exists '.$schema.' cascade');
}
