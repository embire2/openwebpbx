<?php
/** Disposable nspawn-only full restore fixture. Never run against the live PBX. */
if (PHP_SAPI !== 'cli' || getenv('OPENWEB_RESTORE_QUALIFICATION') !== '1') { exit(2); }
if (gethostname() !== 'owpbx-desk-restore112' || trim((string)@file_get_contents('/run/systemd/container')) !== 'systemd-nspawn') {
    throw new RuntimeException('The exclusive disposable restore machine is required.');
}
umask(0077);
require '/var/www/fusionpbx/resources/require.php';
$db=$database->db; $db->setAttribute(PDO::ATTR_ERRMODE,PDO::ERRMODE_EXCEPTION);
$root='/var/lib/openwebpbx/restore-phone112';
if (!is_dir($root) || is_link($root)) throw new RuntimeException('Private fixture directory unavailable.');
$stateFile=$root.'/state.json'; $archive=$root.'/source.zip';
final class restore_qualification_scope extends pbx_tenants {
    // CLI deliberately grants every permission; isolate the tenant ownership policy.
    protected function allowed(string $name): bool { return $name==='pbx_service_create'; }
}
$q=static function(string $sql,array $args=[])use($db):PDOStatement { $s=$db->prepare($sql);$s->execute($args);return $s; };
$save=static function(array $state)use($stateFile):void {
    if(file_put_contents($stateFile,json_encode($state,JSON_PRETTY_PRINT|JSON_THROW_ON_ERROR),LOCK_EX)===false)throw new RuntimeException('Private fixture state could not be saved.');
    chmod($stateFile,0600);
};
$session=static function(array $state,string $domain,string $realm):void {
    global $domain_uuid,$user_uuid;
    $domain_uuid=$domain; $user_uuid=$state['owner'];
    $_SESSION=['authorized'=>true,'user_uuid'=>$user_uuid,'domain_uuid'=>$domain_uuid,'domain_name'=>$realm,'user'=>['domain_uuid'=>$domain_uuid]];
};
$seal=static function(array $data)use($root):string {
    $keyFile=$root.'/fixture-credential.key';
    if(!is_file($keyFile)){file_put_contents($keyFile,random_bytes(SODIUM_CRYPTO_SECRETBOX_KEYBYTES));chmod($keyFile,0600);}
    $key=file_get_contents($keyFile);$nonce=random_bytes(SODIUM_CRYPTO_SECRETBOX_NONCEBYTES);
    return base64_encode($nonce.sodium_crypto_secretbox(json_encode($data,JSON_THROW_ON_ERROR),$nonce,$key));
};
$unseal=static function(string $cipher)use($root):array {
    $raw=base64_decode($cipher,true);if(!is_string($raw)||strlen($raw)<=SODIUM_CRYPTO_SECRETBOX_NONCEBYTES+SODIUM_CRYPTO_SECRETBOX_MACBYTES)throw new RuntimeException('Encrypted owned fixture payload is unavailable.');
    $plain=sodium_crypto_secretbox_open(substr($raw,SODIUM_CRYPTO_SECRETBOX_NONCEBYTES),substr($raw,0,SODIUM_CRYPTO_SECRETBOX_NONCEBYTES),file_get_contents($root.'/fixture-credential.key'));
    if($plain===false)throw new RuntimeException('Encrypted owned fixture payload cannot be opened.');return json_decode($plain,true,512,JSON_THROW_ON_ERROR);
};
$mode=$argv[1]??'verify';
if(!in_array($mode,['prepare','verify','final-boundary','source-outbound','refresh-harness','provider-prepare','provider-check','provider-cleanup','native-cleanup','auth-profile','routing-open','routing-restore','https-prepare','https-check','https-cleanup'],true))throw new RuntimeException('Choose an explicitly scoped fixture action.');
if($mode==='prepare') {
    if(is_file($stateFile))throw new RuntimeException('A fixture already exists; reuse its private state.');
    if(!is_file($archive)||is_link($archive))throw new RuntimeException('Private supplied archive unavailable.');
    $suffix=bin2hex(random_bytes(6));$home=uuid();$owner=uuid();$tenant=uuid();
    $homeRealm='restore112-home-'.$suffix.'.invalid';$email='restore112-'.$suffix.'@example.invalid';$ownerPassword=bin2hex(random_bytes(24));
    $candidate=getenv('OPENWEB_RESTORE_CANDIDATE')==='1';
    $state=['scope'=>'supplied-v20-private-restore','machine'=>gethostname(),'created_epoch'=>time(),'suffix'=>$suffix,'home'=>$home,'home_realm'=>$homeRealm,'owner'=>$owner,'tenant'=>$tenant,'candidate_phone_preservation'=>$candidate,'selected_timezone'=>$candidate?'UTC':'Africa/Johannesburg'];$save($state);
    $db->beginTransaction();
    try {
        $q('insert into v_domains(domain_uuid,domain_name,domain_enabled,domain_description) values(?,?,true,?)',[$home,$homeRealm,'Disposable supplied-backup restore qualification']);
        $q("insert into v_users(user_uuid,domain_uuid,username,user_email,password,user_enabled,user_type) values(?,?,?,?,?,true,'default')",[$owner,$home,$email,$email,password_hash($ownerPassword,PASSWORD_DEFAULT)]);
        $group=$q("select group_uuid from v_groups where group_name='tenant_admin' and domain_uuid is null limit 1")->fetchColumn();
        if(!$group)throw new RuntimeException('Tenant administrator group unavailable.');
        $q("insert into v_user_groups(user_group_uuid,domain_uuid,user_uuid,group_uuid,group_name) values(?,?,?,?,'tenant_admin')",[uuid(),$home,$owner,$group]);
        $q('insert into v_pbx_tenants(tenant_uuid,tenant_name,slug,home_domain_uuid,owner_user_uuid,invite_email,enabled) values(?,?,?,?,?,?,true)',[$tenant,'Restore qualification','restore112-'.$suffix,$home,$owner,$email]);
        $db->commit();
    }catch(Throwable $e){if($db->inTransaction())$db->rollBack();throw $e;}
    $session($state,$home,$homeRealm);
    $setup=new pbx_setup($db);$metadata=['company_name'=>'Restore qualification','service_name'=>'Private supplied archive','tenant_uuid'=>$tenant,'timezone'=>$state['selected_timezone']];
    if($candidate)$metadata['sip_domain']='restore112-'.$suffix.'.invalid';
    $draft=$setup->analyzeStored($archive,$metadata);$state['draft']=$draft['draft_id'];$save($state);
    $cipher=$q('select payload_ciphertext from v_pbx_setup_drafts where draft_uuid=?',[$state['draft']])->fetchColumn();
    if(!$cipher)throw new RuntimeException('Restoration draft was not encrypted.');
    $domain=$setup->createImport($state['draft'],$metadata+['acknowledge_limitations'=>true]);
    $state['domain']=$domain;$state['realm']=$q('select domain_name from v_domains where domain_uuid=?',[$domain])->fetchColumn();
    $state['service']=$q('select service_uuid from v_pbx_services where domain_uuid=? and tenant_uuid=?',[$domain,$tenant])->fetchColumn();
    if(!$state['service'] || ($candidate?$state['realm']!==$metadata['sip_domain']:!str_contains($state['realm'],'.restore112-'.$suffix.'.')))throw new RuntimeException('Restored service ownership mismatch.');
    if($setup->createImport($state['draft'],$metadata+['acknowledge_limitations'=>true])!==$domain)throw new RuntimeException('Repeated confirmation duplicated the service.');
    $plan=threecx_backup::analyze($archive);$users=[];
    foreach($plan['users'] as $u)$users[]=['number'=>$u['number'],'auth'=>$u['auth_id'],'password'=>$u['password'],'source_status'=>$plan['v20']['users'][$u['number']]['profile'],'source_auto_status'=>$plan['v20']['users'][$u['number']]['auto_status'],'source_queue_status'=>$plan['v20']['users'][$u['number']]['queue_status'],'source_not_registered_voicemail'=>($plan['v20']['users'][$u['number']]['profiles']['Available']['available']['NotRegistered']['all']['type']??null)==='VoiceMail'];
    $phones=[];
    if($candidate)foreach($plan['v20']['phones'] as $phone){
        $u=current(array_filter($plan['users'],static fn($u)=>$u['number']===$phone['number']));
        $mapped=pbx_phone_restore::plan($phone,$plan['v20']['users'][$phone['number']]+$u,$state['realm']);
        $phones[]=['number'=>$phone['number'],'sip_user'=>$mapped['line']['user_id'],'auth'=>$mapped['line']['auth_id'],'password'=>$mapped['line']['password'],'source_status'=>$plan['v20']['users'][$phone['number']]['profile']];
    }
    $objects=[];foreach(['ring_groups','queues','receptionists'] as $kind)$objects[$kind]=array_map(static fn($row)=>array_intersect_key($row,array_flip(['number','members','options','timeout','ring_timeout','timeout_destination'])),$plan['v20'][$kind]);
    $state['credentials_ciphertext']=$seal(['scope'=>$state['scope'],'domain'=>$domain,'realm'=>$state['realm'],'owner'=>['email'=>$email,'password'=>$ownerPassword],'users'=>$users,'phones'=>$phones,'calling_objects'=>$objects]);
    $state['source_version']=$plan['source_version'];$state['imported_provider_activation_forbidden']=true;$save($state);
}
$state=json_decode((string)file_get_contents($stateFile),true,512,JSON_THROW_ON_ERROR);
if(($state['scope']??'')!=='supplied-v20-private-restore'||($state['machine']??'')!==gethostname()||!is_uuid($state['domain']??''))throw new RuntimeException('Owned restore state unavailable.');
if($q('select domain_name from v_domains where domain_uuid=?',[$state['domain']])->fetchColumn()!==$state['realm'])throw new RuntimeException('Native fixture realm mismatch.');
$plan=threecx_backup::analyze($archive);$policy=json_decode($q('select config from v_pbx_restore where domain_uuid=?',[$state['domain']])->fetchColumn(),true,512,JSON_THROW_ON_ERROR);
if($mode==='final-boundary'){
    $counts=['native_extensions'=>(int)$q('select count(*) from v_extensions where domain_uuid=?',[$state['domain']])->fetchColumn(),
        'native_gateways'=>(int)$q('select count(*) from v_gateways where domain_uuid=?',[$state['domain']])->fetchColumn(),
        'native_incoming_numbers'=>(int)$q('select count(*) from v_destinations where domain_uuid=?',[$state['domain']])->fetchColumn(),
        'remaining_owned_or_foreign_alias_fixtures'=>(int)$q('select count(*) from v_pbx_sip_domains where domain_uuid in (?,?)',[$state['domain'],$state['home']])->fetchColumn()];
    $checks=['native_users_exactly_original'=>$counts['native_extensions']===count($plan['users']),
        'native_providers_exactly_original'=>$counts['native_gateways']===count($plan['trunks']),
        'native_incoming_numbers_exactly_original'=>$counts['native_incoming_numbers']===count($plan['v20']['inbound_rules']),
        'no_invented_aliases_remain'=>$counts['remaining_owned_or_foreign_alias_fixtures']===0,
        'all_temporary_config_recovery_completed'=>!isset($state['provider_fixture'])&&!isset($state['https_fixture'])&&!isset($state['routing_restore_ciphertext'])];
    $report=['fixture_only'=>true,'counts'=>$counts,'checks'=>$checks,'all_passed'=>!in_array(false,$checks,true)];
    file_put_contents($root.'/final-boundary-evidence.json',json_encode($report,JSON_PRETTY_PRINT|JSON_THROW_ON_ERROR));chmod($root.'/final-boundary-evidence.json',0600);
    echo json_encode($report,JSON_PRETTY_PRINT|JSON_THROW_ON_ERROR)."\n";if(!$report['all_passed'])exit(1);exit;
}
if($mode==='source-outbound'){
    $checks=[];$providerIds=[];foreach($plan['trunks'] as $provider)$providerIds[$provider['name']]=$provider['source_id'];
    foreach($plan['v20']['outbound_rules'] as $index=>$source){
        $native=$policy['outbound_rules'][$index]??[];$same=true;
        foreach(['name','prefix','lengths','ranges','departments'] as $field)$same=$same&&($native[$field]??null)==($source[$field]??null);
        $routes=[];foreach($source['routes'] as $route){$route['trunk_id']=$providerIds[$route['provider']];unset($route['provider']);$routes[]=$route;}
        $same=$same&&($native['routes']??null)==$routes;
        $checks['source_rule_'.($index+1).'_order_prefix_lengths_permissions_and_rewrite']=$same;
    }
    $checks['one_enabled_owned_outbound_dispatcher']=(int)$q("select count(*) from v_dialplans where domain_uuid=? and dialplan_context=? and dialplan_enabled=true and position('app.lua pbx_setup outbound all' in dialplan_xml)>0",[$state['domain'],$state['realm']])->fetchColumn()===1;
    $report=['fixture_only'=>true,'read_only_source_comparison'=>true,'original_outgoing_rule_count'=>count($plan['v20']['outbound_rules']),'original_providers_not_activated'=>true,'checks'=>$checks,'all_passed'=>!in_array(false,$checks,true)];
    file_put_contents($root.'/source-outbound-preservation.json',json_encode($report,JSON_PRETTY_PRINT|JSON_THROW_ON_ERROR));chmod($root.'/source-outbound-preservation.json',0600);
    echo json_encode($report,JSON_PRETTY_PRINT|JSON_THROW_ON_ERROR)."\n";if(!$report['all_passed'])exit(1);exit;
}
if($mode==='routing-open'){
    if(isset($state['routing_restore_ciphertext']))throw new RuntimeException('An owned routing override is already active.');
    $state['routing_restore_ciphertext']=$seal(['domain'=>$state['domain'],'config'=>$policy]);$save($state);
    foreach($policy['departments'] as &$department)$department['office_override']=['state'=>'open','expires'=>time()+900];unset($department);
    $q('update v_pbx_restore set config=cast(? as jsonb) where domain_uuid=?',[json_encode($policy,JSON_THROW_ON_ERROR),$state['domain']]);
    (new cache)->delete('dialplan:'.$state['realm']);
    echo "Temporary OPEN office override applied only to the owned disposable restore. Source statuses and credentials are unchanged.\n";exit;
}
if($mode==='routing-restore'){
    $original=$unseal($state['routing_restore_ciphertext']??'');if($original['domain']!==$state['domain'])throw new RuntimeException('Routing recovery scope mismatch.');
    $q('update v_pbx_restore set config=cast(? as jsonb) where domain_uuid=?',[json_encode($original['config'],JSON_THROW_ON_ERROR),$state['domain']]);
    unset($state['routing_restore_ciphertext']);$save($state);$policy=$original['config'];
    (new cache)->delete('dialplan:'.$state['realm']);
}
if($mode==='https-prepare'){
    if(isset($state['https_fixture']))throw new RuntimeException('An owned HTTPS fixture is already active.');
    if($q('select count(*) from v_pbx_sip_domains where domain_uuid in (?,?)',[$state['domain'],$state['home']])->fetchColumn()!=0)throw new RuntimeException('Only initially alias-free owned fixtures are supported.');
    $state['https_fixture']=['alias'=>'phone-qa-'.$state['suffix'].'.example.invalid','foreign_alias'=>'foreign-phone-qa-'.$state['suffix'].'.example.invalid'];
    $extensions=$q('select * from v_extensions where domain_uuid=? order by extension_uuid',[$state['domain']])->fetchAll(PDO::FETCH_ASSOC);
    $state['https_restore_ciphertext']=$seal(['domain'=>$state['domain'],'config'=>$policy,'extensions'=>$extensions]);$save($state);
    $q('insert into v_pbx_sip_domains(sip_domain,domain_uuid,enabled,created_by) values(?,?,true,?)',[$state['https_fixture']['foreign_alias'],$state['home'],$state['owner']]);
    echo "Owned HTTPS phone-domain fixtures prepared privately.\n";exit;
}
if($mode==='https-check'){
    $original=$unseal($state['https_restore_ciphertext']??'');if($original['domain']!==$state['domain'])throw new RuntimeException('HTTPS recovery scope mismatch.');
    $expected=$argv[2]??'';if(!in_array($expected,['absent','enabled','disabled'],true))throw new RuntimeException('Choose the expected owned alias state.');
    $alias=$q('select enabled from v_pbx_sip_domains where domain_uuid=? and sip_domain=?',[$state['domain'],$state['https_fixture']['alias']])->fetch(PDO::FETCH_ASSOC);
    $aliasMatches=$expected==='absent'?$alias===false:(is_array($alias)&&filter_var($alias['enabled'],FILTER_VALIDATE_BOOLEAN)===($expected==='enabled'));
    $compare=$policy;unset($compare['sip_domains'],$compare['phone_domain']);$before=$original['config'];unset($before['sip_domains'],$before['phone_domain']);
    $extensions=$q('select * from v_extensions where domain_uuid=? order by extension_uuid',[$state['domain']])->fetchAll(PDO::FETCH_ASSOC);
    $primary=$policy['phone_domain']??$policy['realm'];
    $checks=['expected_owned_alias_state'=>$aliasMatches,'canonical_realm_retained'=>$policy['realm']===$state['realm']&&$q('select domain_name from v_domains where domain_uuid=?',[$state['domain']])->fetchColumn()===$state['realm'],
        'native_extensions_and_credentials_unchanged'=>$extensions===$original['extensions'],'all_original_routing_and_users_unchanged'=>$compare==$before,
        'primary_phone_domain_correct'=>$primary===($expected==='enabled'?$state['https_fixture']['alias']:$state['realm']),
        'foreign_alias_ownership_unchanged'=>$q('select domain_uuid from v_pbx_sip_domains where sip_domain=?',[$state['https_fixture']['foreign_alias']])->fetchColumn()===$state['home'],
        'original_providers_off'=>(int)$q("select count(*) from v_gateways where domain_uuid=? and enabled='true'",[$state['domain']])->fetchColumn()===0];
    $evidence=json_encode(['checks'=>$checks,'all_passed'=>!in_array(false,$checks,true)],JSON_THROW_ON_ERROR);
    file_put_contents($root.'/https-last-check-evidence.json',$evidence);chmod($root.'/https-last-check-evidence.json',0600);
    echo $evidence."\n";if(in_array(false,$checks,true))exit(1);exit;
}
if($mode==='https-cleanup'){
    $original=$unseal($state['https_restore_ciphertext']??'');if($original['domain']!==$state['domain'])throw new RuntimeException('HTTPS recovery scope mismatch.');
    foreach([[$state['domain'],$state['https_fixture']['alias']],[$state['home'],$state['https_fixture']['foreign_alias']]] as [$domain,$alias])$q('delete from v_pbx_sip_domains where domain_uuid=? and sip_domain=?',[$domain,$alias]);
    $q('update v_pbx_restore set config=cast(? as jsonb) where domain_uuid=?',[json_encode($original['config'],JSON_THROW_ON_ERROR),$state['domain']]);
    unset($state['https_fixture'],$state['https_restore_ciphertext']);$save($state);$policy=$original['config'];
    settings::clear_cache();
}
if($mode==='auth-profile'){
    $profile=$q("select sip_profile_uuid from v_sip_profiles where sip_profile_name='internal' and sip_profile_enabled=true")->fetchAll(PDO::FETCH_COLUMN);
    if(count($profile)!==1)throw new RuntimeException('One owned internal profile is required.');
    $db->beginTransaction();
    try{
        foreach(['inbound-reg-force-matching-username'=>['false',true],'challenge-realm'=>['auto_to',true],
                 'force-register-domain'=>['',false],'force-register-db-domain'=>['',false],
                 'reg-deny-binding-fetch-and-no-lookup'=>['false',false]] as $name=>[$value,$enabled]){
            $stmt=$q('update v_sip_profile_settings set sip_profile_setting_value=?,sip_profile_setting_enabled=? where sip_profile_uuid=? and sip_profile_setting_name=?',[$value,$enabled?'true':'false',$profile[0],$name]);
            if(!$stmt->rowCount())$q('insert into v_sip_profile_settings(sip_profile_setting_uuid,sip_profile_uuid,sip_profile_setting_name,sip_profile_setting_value,sip_profile_setting_enabled) values(?,?,?,?,?)',[uuid(),$profile[0],$name,$value,$enabled?'true':'false']);
        }
        $db->commit();
    }catch(Throwable $e){if($db->inTransaction())$db->rollBack();throw $e;}
    (new cache)->delete(gethostname().':configuration:sofia.conf');
    echo "Strict qualified profile settings applied only to the disposable clone.\n";exit;
}
if($mode==='native-cleanup'){
    $ledger=json_decode((string)file_get_contents($root.'/registration-ledger.json'),true,512,JSON_THROW_ON_ERROR);
    if(($ledger['domain']??null)!==$state['domain']||($ledger['realm']??null)!==$state['realm'])throw new RuntimeException('Exact owned registration ledger required.');
    $ids=$ledger['registration_call_ids']??[];if(!is_array($ids)||count($ids)>1000)throw new RuntimeException('Bounded owned registration ledger required.');
    foreach($ids as $id){if(!is_string($id)||!preg_match('/^[a-f0-9]{24}@localfixture$/D',$id))throw new RuntimeException('Owned registration identifier unavailable.');event_socket::api('sofia profile internal flush_inbound_reg '.$id);}
    $channels=static function()use($state):int{
        $rows=json_decode((string)event_socket::api('show channels as json'),true,512,JSON_THROW_ON_ERROR);$n=0;
        foreach($rows['rows']??[] as $row){$id=$row['uuid']??'';if(!is_uuid($id))throw new RuntimeException('Native channel identifier unavailable.');if(trim((string)event_socket::api('uuid_getvar '.$id.' domain_uuid'))===$state['domain'])$n++;}return $n;
    };
    event_socket::api('hupall NORMAL_CLEARING domain_uuid '.$state['domain']);$deadline=microtime(true)+5;
    while($channels()>0){if(microtime(true)>$deadline)throw new RuntimeException('Owned calls remain after bounded cleanup.');usleep(50000);}
    $raw=event_socket::api('sofia status profile internal reg');
    if(!is_string($raw)||strlen($raw)>8388608||str_starts_with(trim($raw),'-ERR'))throw new RuntimeException('Native scoped registration state is unavailable.');
    $remaining=0;
    foreach($ids as $id)$remaining+=preg_match('/(?:^|\r?\n)Call-ID:\s*'.preg_quote($id,'/').'(?:\r?\n|$)/',$raw)===1;
    // The native listing includes other scoped contacts; never print it.
    $originalGateways=[];foreach($plan['trunks'] as $trunk)$originalGateways[]=$policy['trunks'][$trunk['source_id']]['gateway_uuid'];
    $enabled=(int)$q("select count(*) from v_gateways where domain_uuid=? and enabled='true' and gateway_uuid in (".implode(',',array_fill(0,count($originalGateways),'?')).')',array_merge([$state['domain']],$originalGateways))->fetchColumn();
    $report=['fixture_only'=>true,'exact_owned_register_ids_checked'=>count($ids),'remaining_owned_register_ids'=>$remaining,'remaining_owned_calls'=>$channels(),'all_original_providers_off'=>$enabled===0,'all_passed'=>$remaining===0&&$enabled===0];
    file_put_contents($root.'/native-cleanup-evidence.json',json_encode($report,JSON_PRETTY_PRINT|JSON_THROW_ON_ERROR));chmod($root.'/native-cleanup-evidence.json',0600);
    echo json_encode($report,JSON_PRETTY_PRINT|JSON_THROW_ON_ERROR)."\n";if(!$report['all_passed'])exit(1);exit;
}
if($mode==='refresh-harness'){
    $credentials=$unseal($state['credentials_ciphertext']);
    if($credentials['domain']!==$state['domain']||$credentials['realm']!==$state['realm']||$credentials['scope']!==$state['scope'])throw new RuntimeException('Harness payload scope mismatch.');
    foreach($credentials['users'] as &$user){$user['source_queue_status']=$plan['v20']['users'][$user['number']]['queue_status'];$user['source_auto_status']=$plan['v20']['users'][$user['number']]['auto_status'];$user['source_not_registered_voicemail']=($plan['v20']['users'][$user['number']]['profiles']['Available']['available']['NotRegistered']['all']['type']??null)==='VoiceMail';}unset($user);
    foreach(['ring_groups','queues','receptionists'] as $kind)$credentials['calling_objects'][$kind]=array_map(static fn($row)=>array_intersect_key($row,array_flip(['number','members','options','timeout','ring_timeout','timeout_destination'])),$plan['v20'][$kind]);
    foreach($credentials['calling_objects']['receptionists'] as &$ivr){
        foreach($policy['receptionists'] as $native)if($native['number']===$ivr['number'])$ivr['private_prompt_file']=$native['prompt'];
    }unset($ivr);
    $state['credentials_ciphertext']=$seal($credentials);$save($state);
}
if($mode==='provider-prepare'){
    if(!empty($state['provider_fixture']))throw new RuntimeException('An owned local provider fixture already exists.');
    $ports=array_map('intval',array_slice($argv,2));if(count($ports)!==2||count(array_unique($ports))!==2||min($ports)<1024||max($ports)>65535)throw new RuntimeException('Choose two independent loopback provider ports.');
    if((int)$q("select count(*) from v_gateways where domain_uuid=? and enabled='true'",[$state['domain']])->fetchColumn()!==0)throw new RuntimeException('All source providers must remain off.');
    $state['provider_restore_ciphertext']=$seal(['domain'=>$state['domain'],'config'=>$policy]);$state['provider_fixture']=[];$save($state);
    $session($state,$state['domain'],$state['realm']);$admin=new pbx_admin($db);$auth=['username'=>'local-fixture-auth','password'=>bin2hex(random_bytes(24))];
    $keys=[];$ids=[];$incoming=[];
    foreach($ports as $index=>$port){
        $ip='127.0.0.'.($index+2);
        $input=['name'=>'Only local restore fixture '.($index+1),'host'=>$ip,'port'=>(string)$port,'transport'=>'udp','authentication'=>'ip','register'=>'0','allowed_ips'=>$ip,'main_number'=>'99000000'.($index+1),'codecs'=>'PCMU,PCMA','enabled'=>''];
        if($index===0)$input+=['username'=>'local-fixture-account','auth_username'=>$auth['username'],'password'=>$auth['password']];
        if($index===0)$input['authentication']='password';
        $key=$admin->save('trunk','new',$input);$keys[]=$key;$ids[]=$admin->config()['trunks'][$key]['gateway_uuid'];
        $target=current(array_filter($plan['users'],static fn($u)=>$plan['v20']['users'][$u['number']]['profile']==='Available'&&$plan['v20']['users'][$u['number']]['auto_status']==='0'));
        $incoming[]=$admin->save('incoming','new',['trunk_id'=>$key,'number'=>$input['main_number'],'office'=>'Extension:'.$target['number'],'enabled'=>'']);
        $state['provider_fixture']=['keys'=>$keys,'ids'=>$ids,'incoming'=>$incoming];$save($state);
    }
    $rule=$admin->save('outbound','new',['name'=>'Only isolated loopback qualification','prefix'=>'99','lengths'=>'5','routes'=>array_map(static fn($key)=>['trunk_id'=>$key,'strip'=>'2','prepend'=>'55','caller_id'=>''],$keys)]);
    $c=$admin->config();$local=array_values(array_filter($c['outbound_rules'],static fn($row)=>$row['rule_id']===$rule));
    $c['outbound_rules']=array_merge($local,array_values(array_filter($c['outbound_rules'],static fn($row)=>$row['rule_id']!==$rule)));
    $q('update v_pbx_restore set config=cast(? as jsonb) where domain_uuid=?',[json_encode($c,JSON_THROW_ON_ERROR),$state['domain']]);
    $credentials=$unseal($state['credentials_ciphertext']);$credentials['local_provider_auth']=$auth;$state['credentials_ciphertext']=$seal($credentials);$save($state);
    (new cache)->delete('dialplan:'.$state['realm']);event_socket::api('reloadxml');
    echo "Two invented-credential loopback providers and incoming numbers saved OFF; normal HTTPS handover is required.\n";exit;
}
if($mode==='provider-check'){
    $index=(int)($argv[2]??-1);$expected=$argv[3]??'';
    if(!in_array($index,[0,1],true)||!in_array($expected,['off','on'],true)||empty($state['provider_fixture']['keys'][$index]))throw new RuntimeException('Choose an owned loopback provider and expected state.');
    $original=$unseal($state['provider_restore_ciphertext']);if($original['domain']!==$state['domain'])throw new RuntimeException('Provider check scope mismatch.');
    $key=$state['provider_fixture']['keys'][$index];$id=$state['provider_fixture']['ids'][$index];$incoming=$state['provider_fixture']['incoming'][$index];$on=$expected==='on';
    $native=$q('select enabled,register,proxy from v_gateways where domain_uuid=? and gateway_uuid=?',[$state['domain'],$id])->fetch(PDO::FETCH_ASSOC);
    $rule=current(array_filter($policy['inbound_rules'],static fn($r)=>$r['rule_id']===$incoming));$trunk=$policy['trunks'][$key];
    $providers=0;foreach($original['config']['trunks'] as $source){$providers+=filter_var($q('select enabled from v_gateways where domain_uuid=? and gateway_uuid=?',[$state['domain'],$source['gateway_uuid']])->fetchColumn(),FILTER_VALIDATE_BOOLEAN);}
    $checks=['only_invented_loopback_provider'=>is_array($native)&&preg_match('/^127\.0\.0\.[23]:[0-9]{4,5}$/D',$native['proxy'])===1&&!filter_var($native['register'],FILTER_VALIDATE_BOOLEAN),
        'gateway_and_policy_expected_state'=>filter_var($native['enabled'],FILTER_VALIDATE_BOOLEAN)===$on&&$trunk['enabled']===$on,
        'incoming_route_and_native_destination_expected_state'=>is_array($rule)&&$rule['enabled']===$on&&filter_var($q('select destination_enabled from v_destinations where domain_uuid=? and destination_uuid=?',[$state['domain'],$incoming])->fetchColumn(),FILTER_VALIDATE_BOOLEAN)===$on,
        'all_original_providers_off'=>$providers===0,'original_users_preserved'=>$policy['users']==$original['config']['users'],
        'original_routing_retained'=>array_slice($policy['inbound_rules'],0,count($original['config']['inbound_rules']))==$original['config']['inbound_rules']];
    echo json_encode(['checks'=>$checks,'all_passed'=>!in_array(false,$checks,true)],JSON_THROW_ON_ERROR)."\n";if(in_array(false,$checks,true))exit(1);exit;
}
if($mode==='provider-cleanup'){
    $fixture=$state['provider_fixture']??null;if(!is_array($fixture)||empty($fixture['ids'])||empty($state['provider_restore_ciphertext']))throw new RuntimeException('The owned provider recovery state is unavailable.');
    $original=$unseal($state['provider_restore_ciphertext']);if($original['domain']!==$state['domain'])throw new RuntimeException('Provider recovery scope mismatch.');
    foreach($fixture['ids'] as $id){
        if(!is_uuid($id))throw new RuntimeException('An owned provider identifier is invalid.');
        $row=$q('select proxy,register from v_gateways where domain_uuid=? and gateway_uuid=?',[$state['domain'],$id])->fetch(PDO::FETCH_ASSOC);
        if(!$row||!preg_match('/^127\.0\.0\.[123]:[0-9]{4,5}$/D',$row['proxy'])||filter_var($row['register'],FILTER_VALIDATE_BOOLEAN))throw new RuntimeException('Only an invented loopback provider may be removed.');
        $q('update v_gateways set enabled=false where domain_uuid=? and gateway_uuid=?',[$state['domain'],$id]);event_socket::api('sofia profile external killgw '.$id);
        $q('delete from v_gateways where domain_uuid=? and gateway_uuid=?',[$state['domain'],$id]);
    }
    foreach($fixture['incoming']??[] as $incoming){
        $dp=$q('select dialplan_uuid from v_destinations where domain_uuid=? and destination_uuid=?',[$state['domain'],$incoming])->fetchColumn();
        if(!is_uuid($dp))throw new RuntimeException('Owned incoming recovery identifier unavailable.');
        $q('delete from v_dialplan_details where domain_uuid=? and dialplan_uuid=?',[$state['domain'],$dp]);
        $q('delete from v_dialplans where domain_uuid=? and dialplan_uuid=?',[$state['domain'],$dp]);
        $q('delete from v_destinations where domain_uuid=? and destination_uuid=?',[$state['domain'],$incoming]);
    }
    $q('update v_pbx_restore set config=cast(? as jsonb) where domain_uuid=?',[json_encode($original['config'],JSON_THROW_ON_ERROR),$state['domain']]);
    unset($state['provider_fixture'],$state['provider_restore_ciphertext']);$save($state);
    foreach(['dialplan:'.$state['realm'],gethostname().':configuration:sofia.conf'] as $name)(new cache)->delete($name);
    event_socket::api('reloadxml');
    $policy=$original['config'];
}
$checks=[];$check=static function(string $name,bool $value)use(&$checks):void{$checks[$name]=$value;};
$check('exact_supported_source_version',$plan['source_version']==='20.0.9.995');
$check('one_owned_service',(int)$q('select count(*) from v_pbx_services where tenant_uuid=?',[$state['tenant']])->fetchColumn()===1);
$check('all_original_trunks_off',(int)$q("select count(*) from v_gateways where domain_uuid=? and enabled='true'",[$state['domain']])->fetchColumn()===0);
$check('all_imported_incoming_routes_off',(int)$q("select count(*) from v_destinations where domain_uuid=? and destination_enabled='true'",[$state['domain']])->fetchColumn()===0);
$passwords=0;$pins=0;$identities=0;$profiles=0;
foreach($plan['users'] as $u){
    $row=$q('select extension,number_alias,password,effective_caller_id_number from v_extensions where domain_uuid=? and extension=?',[$state['domain'],$u['auth_id']])->fetch(PDO::FETCH_ASSOC);
    $passwords+=(bool)$row&&hash_equals($u['password'],$row['password']);
    $identities+=(bool)$row&&$row['extension']===$u['auth_id']&&$row['effective_caller_id_number']===$u['number']&&($policy['users'][$u['number']]['auth_id']??null)===$u['auth_id'];
    $pin=$q('select voicemail_password from v_voicemails where domain_uuid=? and voicemail_id=?',[$state['domain'],$u['number']])->fetchColumn();$pins+=is_string($pin)&&hash_equals($u['voicemail_pin'],$pin);
    // JSONB normalizes object-key ordering; compare profile values independently.
    $profiles+=($policy['users'][$u['number']]['profile']??null)===$plan['v20']['users'][$u['number']]['profile']&&($policy['users'][$u['number']]['profiles']??null)==$plan['v20']['users'][$u['number']]['profiles'];
}
$check('all_source_phone_passwords_preserved',$passwords===count($plan['users']));$check('all_source_voicemail_pins_preserved',$pins===count($plan['users']));$check('authentication_ids_and_extension_numbers_preserved',$identities===count($plan['users']));$check('all_statuses_and_forwarding_profiles_preserved',$profiles===count($plan['users']));
if(!empty($state['candidate_phone_preservation'])){
    // Independently read original XML bytes rather than comparing two normalized copies.
    $zip=new ZipArchive();if($zip->open($archive,ZipArchive::RDONLY)!==true)throw new RuntimeException('Private source archive unavailable.');
    try{
        $xmls=[];for($i=0;$i<$zip->numFiles;$i++){
            $entry=$zip->statIndex($i);$name=$entry['name'];
            if(strpos($name,'/')===false&&(preg_match('/^[0-9]+Db\.xml$/iD',$name)||strtolower($name)==='backupdb.xml')){
                if($entry['size']>threecx_backup::MAX_XML_BYTES)throw new RuntimeException('Source XML exceeds the bounded reader.');
                $xmls[]=$zip->getFromIndex($i);
            }
        }
    }finally{$zip->close();}
    if(count($xmls)!==1||!is_string($xmls[0])||preg_match('/<!\s*(?:DOCTYPE|ENTITY)/i',$xmls[0]))throw new RuntimeException('An unambiguous private source XML is required.');
    $doc=new DOMDocument();if(!$doc->loadXML($xmls[0],LIBXML_NONET))throw new RuntimeException('Original private source XML is invalid.');
    $xpath=new DOMXPath($doc);$rawPasswords=0;$rawPins=0;$rawPhones=[];
    foreach($xpath->query('/PhoneSystem/Tenants/Tenant/DN/Extension') as $node){
        $raw=static function(string $field)use($xpath,$node):string{return $xpath->evaluate('string(./'.$field.')',$node);};
        $number=trim($raw('Number'));$row=$q('select password from v_extensions where domain_uuid=? and effective_caller_id_number=?',[$state['domain'],$number])->fetchColumn();
        $rawPasswords+=is_string($row)&&hash_equals($raw('AuthPassword'),$row);
        $pin=$q('select voicemail_password from v_voicemails where domain_uuid=? and voicemail_id=?',[$state['domain'],$number])->fetchColumn();
        $rawPins+=is_string($pin)&&hash_equals(trim($raw('VMPIN')),$pin);
        foreach($xpath->query('./PhoneDevices/PhoneDevice',$node) as $phone){
            $rawPhones[]=['number'=>$number,'settings'=>$xpath->evaluate('string(./Settings)',$phone),'interface'=>trim($xpath->evaluate('string(./Interface)',$phone)),'provisioning_filename'=>trim($xpath->evaluate('string(./ProvisioningFilename)',$phone)),'provisioning_filename2'=>trim($xpath->evaluate('string(./ProvisioningFilename2)',$phone))];
        }
    }
    $check('raw_xml_password_bytes_match_all_native_users',$rawPasswords===count($plan['users']));
    $check('raw_xml_mailbox_pins_match_all_native_users',$rawPins===count($plan['users']));
    $key=file_get_contents(pbx_paths::key());$sealed=0;$settings=0;$lines=0;$templates=0;
    foreach($plan['v20']['phones'] as $index=>$phone){
        $stored=$policy['phones'][$index]??[];$cipher=$stored['source_ciphertext']??'';$decoded=base64_decode($cipher,true);
        if(!is_string($decoded)||strlen($decoded)<=SODIUM_CRYPTO_SECRETBOX_NONCEBYTES+SODIUM_CRYPTO_SECRETBOX_MACBYTES)continue;
        $plain=sodium_crypto_secretbox_open(substr($decoded,SODIUM_CRYPTO_SECRETBOX_NONCEBYTES),substr($decoded,0,SODIUM_CRYPTO_SECRETBOX_NONCEBYTES),$key);
        if($plain===false)continue;$payload=json_decode($plain,true,512,JSON_THROW_ON_ERROR);
        $preservedPhone=$payload['phone']??[];$nativePhoneId=$preservedPhone['uuid']??null;unset($preservedPhone['uuid']);
        $sealed+=($payload['domain_uuid']??null)===$state['domain']&&($payload['realm']??null)===$state['realm']&&$nativePhoneId===($stored['uuid']??null)&&$preservedPhone==$phone;
        $original=$rawPhones[$index]??[];
        $settings+=($payload['settings_xml']??null)===($original['settings']??null)&&($payload['phone']['interface']??null)===($original['interface']??null)&&($payload['phone']['provisioning_filename']??null)===($original['provisioning_filename']??null)&&($payload['phone']['provisioning_filename2']??null)===($original['provisioning_filename2']??null);
        $line=$q('select user_id,auth_id,password,server_address,server_address_primary from v_device_lines where domain_uuid=? and device_uuid=?',[$state['domain'],$stored['uuid']])->fetch(PDO::FETCH_ASSOC);
        $lines+=(bool)$line&&$line['user_id']===($payload['sip_user']??null)&&$line['auth_id']===($payload['auth_id']??null)&&hash_equals($payload['password'],$line['password'])&&$line['server_address']===$state['realm']&&$line['server_address_primary']===$state['realm'];
        $device=$q('select device_template,device_enabled from v_devices where domain_uuid=? and device_uuid=?',[$state['domain'],$stored['uuid']])->fetch(PDO::FETCH_ASSOC);
        $templates+=(bool)$device&&$device['device_template']===null&&in_array($device['device_enabled'],[false,'false','0',0],true);
    }
    $check('all_phone_settings_encrypted_and_bound_to_owned_realm',$sealed===count($plan['v20']['phones']));
    $check('all_original_phone_xml_and_provisioning_filenames_preserved',$settings===count($rawPhones));
    $check('all_device_lines_keep_original_sip_user_auth_id_password',$lines===count($plan['v20']['phones']));
    $check('no_guessed_model_template_or_automatic_reprovisioning',$templates===count($plan['v20']['phones']));
    $check('explicit_selected_tenant_sip_domain_applied',$state['realm']==='restore112-'.$state['suffix'].'.invalid');
    $selectedTimezone=$state['selected_timezone'];
    $check('selected_timezone_applied_to_policy_and_departments',($policy['timezone']??null)===$selectedTimezone&&!array_filter($policy['departments'],static fn($d)=>($d['timezone']??null)!==$selectedTimezone));
    $departmentRoutes=0;
    foreach($plan['v20']['departments'] as $index=>$department)$departmentRoutes+=is_array($department['source_routes']??null)&&($policy['departments'][$index]['source_routes']??null)==$department['source_routes'];
    $check('all_original_department_source_routes_retained_as_metadata',$departmentRoutes===count($plan['v20']['departments']));
    $groupOrder=0;$queueOrder=0;$hours=0;$sipFlags=0;
    foreach(['ring_groups','queues','receptionists'] as $kind)foreach($plan['v20'][$kind] as $index=>$row){
        $actual=$policy[$kind][$index]??[];$hours+=($actual['hours']??null)==$row['hours'];
        if($kind==='ring_groups')$groupOrder+=array_column($actual['members']??[],'number')===array_column($row['members'],'number')&&($actual['strategy']??null)===$row['strategy'];
        if($kind==='queues')$queueOrder+=array_column($actual['members']??[],'number')===array_column($row['members'],'number')&&($actual['strategy']??null)===$row['strategy'];
    }
    foreach($plan['v20']['users'] as $number=>$user){
        $actual=$policy['users'][$number]??[];$same=true;
        foreach(['deliver_audio','support_reinvite','support_replaces','srtp_mode'] as $field)$same=$same&&($actual[$field]??null)===$user[$field];
        // JSONB preserves setting values while sorting object keys.
        $same=$same&&($actual['phone_properties']??null)==$user['phone_properties'];
        $sipFlags+=$same;
    }
    $check('original_ring_group_strategies_and_member_order_preserved',$groupOrder===count($plan['v20']['ring_groups']));
    $check('original_queue_strategies_and_member_order_preserved',$queueOrder===count($plan['v20']['queues']));
    $check('all_call_object_hours_and_route_choices_preserved',$hours===count($plan['v20']['ring_groups'])+count($plan['v20']['queues'])+count($plan['v20']['receptionists']));
    $check('all_original_user_sip_flags_retained_in_policy',$sipFlags===count($plan['users']));
}
$draft=$q('select payload_ciphertext,completed_domain_uuid from v_pbx_setup_drafts where draft_uuid=?',[$state['draft']])->fetch(PDO::FETCH_ASSOC);$check('completed_draft_discards_secret_payload',$draft['payload_ciphertext']===null&&$draft['completed_domain_uuid']===$state['domain']);
$foreign=uuid();$session($state,$state['home'],$state['home_realm']);$scope=new restore_qualification_scope($db);$check('owner_scope_without_cli_permission_shortcut',$scope->canDomain($state['domain'])&&!$scope->canDomain($foreign));
$importReport=json_decode($q('select report from v_pbx_restore where domain_uuid=?',[$state['domain']])->fetchColumn(),true,512,JSON_THROW_ON_ERROR);
$mediaCounts=array_intersect_key($importReport,array_flip(['recordings','voicemail_files','voicemail_messages','voicemail_greetings','prompts','call_history','contacts']));
$report=['source_version'=>$plan['source_version'],'fixture_only'=>true,'test_state_credentials_encrypted'=>true,'archive_outside_web_root'=>true,'checks'=>$checks,'source_counts'=>threecx_v20::counts($plan),'restored_media_counts'=>$mediaCounts,'source_phone_passwords_verified'=>$passwords,'source_voicemail_pins_verified'=>$pins,'source_status_profiles_verified'=>$profiles,'actual_dual_identity_sip_registration_separate_required_gate'=>true,'all_passed'=>!in_array(false,$checks,true)];
file_put_contents($root.'/restore-evidence.json',json_encode($report,JSON_PRETTY_PRINT|JSON_THROW_ON_ERROR));chmod($root.'/restore-evidence.json',0600);
echo json_encode($report,JSON_PRETTY_PRINT|JSON_THROW_ON_ERROR)."\n";
if(!$report['all_passed'])exit(1);
