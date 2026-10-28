<?php
/** Real PostgreSQL integration in an owned temporary schema; no public tenant/DNS/call is created. */
if(PHP_SAPI!=='cli')exit(2);
require dirname(__DIR__).'/resources/require.php';
require_once dirname(__DIR__).'/resources/classes/pbx_tenant_api.php';
$db=$database->db;$db->setAttribute(PDO::ATTR_ERRMODE,PDO::ERRMODE_EXCEPTION);
$schema='openweb_api_test_'.bin2hex(random_bytes(6));$checks=0;
$ok=function(bool $value,string $message)use(&$checks):void{if(!$value)throw new RuntimeException($message);$checks++;};
$error=function(callable $fn,int $status,string $code='')use($ok):void{
    try{$fn();}catch(pbx_tenant_api_error $ex){$ok($ex->status===$status,'Unexpected API error status '.$ex->status.' instead of '.$status);if($code!=='')$ok($ex->apiCode===$code,'Unexpected API error code');return;}
    throw new RuntimeException('Expected API refusal '.$status);
};
$q=function(string $sql,array $p=[])use($db):PDOStatement{$s=$db->prepare($sql);$s->execute($p);return $s;};
class tested_tenant_api extends pbx_tenant_api {
    public array $verification=[];
    protected function queueVerification(array $registration,string $token):void{$this->verification[$registration['email']]=$token;parent::queueVerification($registration,$token);}
    protected function afterProvision(array $account,string $service):void{}
}
class api_test_template_admin extends pbx_tenants {
    protected function allowed(string $name):bool{return in_array($name,['pbx_tenant_manage','pbx_template_manage','pbx_service_create'],true);}
}
try{
    $db->exec('create schema '.$schema);$db->exec('set search_path to '.$schema.',public');
    $tables=['v_domains','v_users','v_user_groups','v_groups','v_group_permissions','v_permissions','v_menus','v_menu_items','v_menu_languages','v_menu_item_groups','v_dialplans','v_dialplan_details','v_domain_settings','v_extensions','v_voicemails','v_gateways','v_default_settings','v_email_queue','v_pbx_restore'];
    foreach($tables as$table)$db->exec('create table '.$table.' (like public.'.$table.' including all)');
    foreach(['v_groups','v_group_permissions','v_permissions','v_menus','v_menu_items','v_menu_languages','v_menu_item_groups','v_default_settings']as$table)$db->exec('insert into '.$table.' select * from public.'.$table);
    $q('insert into v_domains select * from public.v_domains where domain_name=?',[pbx_paths::host()]);
    $db->exec('insert into v_dialplans select * from public.v_dialplans where domain_uuid in(select domain_uuid from v_domains) and app_uuid is not null');
    $db->exec('insert into v_dialplan_details select * from public.v_dialplan_details where dialplan_uuid in(select dialplan_uuid from v_dialplans)');
    foreach(['tenant_services','pbx_tenant_domains','tenant_api']as$app)$db->exec(file_get_contents(dirname(__DIR__).'/app/'.$app.'/resources/install.sql'));
    // Applying the additive schema twice must not erase tokens or customer rows.
    $db->exec(file_get_contents(dirname(__DIR__).'/app/tenant_api/resources/install.sql'));
    $baselineDomains=(int)$q('select count(*) from v_domains')->fetchColumn();
    $policy=['enabled'=>true,'registration_enabled'=>true,'service_limit'=>1,'max_public_tenants'=>25];$api=new tested_tenant_api($db,$policy);
    $signup=static fn(string $slug):array=>['tenant_name'=>ucfirst($slug).' Test','slug'=>$slug,'email'=>$slug.'@tenant-api.test.invalid','password'=>'Synthetic-API-password-2026!','accept_terms'=>true];
    $alpha=$signup('alpha');[$status,$body]=$api->handle('POST','/registrations',$alpha,[],'192.0.2.10');
    $ok($status===202&&$body['status']==='verification_required','Signup response incorrect');
    $ok(!isset($body['token'])&&!isset($body['access_token']),'Signup disclosed credentials');
    $ok((int)$q('select count(*) from v_pbx_tenants')->fetchColumn()===0,'Unverified tenant was created');
    $ok((int)$q('select count(*) from v_users')->fetchColumn()===0,'Unverified owner was created');
    $ok((int)$q('select count(*) from v_domains')->fetchColumn()===$baselineDomains,'Unverified workspace was created');
    $pending=$q('select * from v_pbx_api_registrations')->fetch(PDO::FETCH_ASSOC);$code=$api->verification[$alpha['email']];
    $ok(password_verify($alpha['password'],$pending['password_hash']),'Password was not hashed');
    $ok($pending['verification_hash']===hash('sha256',$code)&&!str_contains(json_encode($pending),$code),'Verification token was not hashed');
    $ok((int)$q("select count(*) from v_email_queue where email_status='waiting'")->fetchColumn()===1,'Verification was not queued through global mail');
    $error(fn()=>$api->handle('POST','/registrations',$alpha+['role'=>'superadmin'],[],'192.0.2.20'),400);
    $bad=$alpha;$bad['accept_terms']=false;$error(fn()=>$api->handle('POST','/registrations',$bad,[],'192.0.2.20'),400,'terms_required');
    $bad=$alpha;$bad['password']='short1';$error(fn()=>$api->handle('POST','/registrations',$bad,[],'192.0.2.20'),400);
    $bad=$alpha;$bad['slug']='www';try{$api->handle('POST','/registrations',$bad,[],'192.0.2.20');throw new RuntimeException('Reserved label accepted');}catch(InvalidArgumentException){$checks++;}
    $error(fn()=>$api->handle('POST','/registrations/verify',['token'=>$code,'password'=>'Incorrect-password-2026'],[],'192.0.2.10'),400,'verification_invalid');
    $ok((int)$q('select count(*) from v_users')->fetchColumn()===0,'Wrong registration password created an account');
    [$status,$auth]=$api->handle('POST','/registrations/verify',['token'=>$code,'password'=>$alpha['password']],[],'192.0.2.10');
    $ok($status===201&&preg_match('/^owta_[a-f0-9]{64}$/D',$auth['access_token'])===1,'Verified API key incorrect');
    $ok($auth['tenant']['service_limit']===1&&$auth['tenant']['service_count']===0,'Public tenant quota incorrect');
    $a=$api->authenticate('Bearer '.$auth['access_token']);$headers=['Authorization'=>'Bearer '.$auth['access_token']];
    $token=$q('select * from v_pbx_api_tokens where token_uuid=?',[$a['token_uuid']])->fetch(PDO::FETCH_ASSOC);
    $ok($token['token_hash']===hash('sha256',$auth['access_token'])&&!str_contains(json_encode($token),$auth['access_token']),'Bearer credential stored in plaintext');
    $pending=$q('select * from v_pbx_api_registrations')->fetch(PDO::FETCH_ASSOC);$ok($pending['verification_hash']===null&&$pending['password_hash']==='','Verified pending secrets retained');
    $error(fn()=>$api->handle('POST','/registrations/verify',['token'=>$code,'password'=>$alpha['password']],[],'192.0.2.10'),400,'verification_invalid');
    [$status,$duplicate]=$api->handle('POST','/registrations',$alpha,[],'192.0.2.11');$ok($status===202&&$duplicate===$body,'Duplicate registration enumerated identities');
    $error(fn()=>$api->handle('GET','/me',[],[],'192.0.2.10'),401,'invalid_token');
    $_SESSION=['authorized'=>true,'user_uuid'=>$a['user_uuid'],'permissions'=>['pbx_tenant_manage'=>true]];
    $error(fn()=>$api->handle('GET','/me',[],[],'192.0.2.10'),401,'invalid_token');
    [$status,$me]=$api->handle('GET','/me',[],$headers,'192.0.2.10');$ok($status===200&&$me['tenant']['tenant_uuid']===$a['tenant_uuid'],'Owner /me unavailable');
    $admin=new api_test_template_admin($db);$templateConfig=['timezone'=>'Africa/Johannesburg','extension_start'=>100,'extension_count'=>2,'extension_limit'=>20,'trunks'=>[],'rules'=>[],'settings'=>[]];
    $template=$admin->saveTemplate(['template_name'=>'Self-service starter','published'=>true,'config'=>$templateConfig]);
    $q('update v_pbx_templates set api_enabled=true where template_uuid=?',[$template]);
    $unsafe=$templateConfig;$unsafe['trunks']=[['name'=>'Provider','proxy'=>'sip.example.invalid','username'=>'provider-secret-user','password'=>'provider-secret-password','transport'=>'udp','register'=>true,'enabled'=>false]];
    $unsafeTemplate=$admin->saveTemplate(['template_name'=>'Private provider','published'=>true,'config'=>$unsafe]);
    $q('update v_pbx_templates set api_enabled=true where template_uuid=?',[$unsafeTemplate]);
    $unpublished=$admin->saveTemplate(['template_name'=>'Unpublished starter','published'=>false,'config'=>$templateConfig]);
    $notOptedIn=$admin->saveTemplate(['template_name'=>'Operator-only shared starter','published'=>true,'config'=>$templateConfig]);
    $gui=new pbx_tenant_api_provisioner($db,['pbx_service_view'=>true,'pbx_service_create'=>true]);
    $_SESSION=['authorized'=>true,'user_uuid'=>$a['user_uuid'],'domain_uuid'=>$a['home_domain_uuid'],'user'=>['domain_uuid'=>$a['home_domain_uuid']]];
    foreach([$notOptedIn,$unsafeTemplate]as$forbidden){
        try{$gui->template($forbidden);throw new LogicException('A public tenant bypassed the API template policy through the GUI model');}
        catch(RuntimeException $denied){$ok(in_array($denied->getMessage(),['Template access denied.','Choose a provider-free starter template.'],true),'Unexpected GUI template failure');}
    }
    [$status,$catalog]=$api->handle('GET','/templates',[],$headers,'192.0.2.10');$ok($status===200&&count($catalog['templates'])===1,'Unsafe or unpublished templates visible');
    $ok(!str_contains(json_encode($catalog),'provider-secret'),'Catalog leaked provider credentials');
    $create=['template_uuid'=>$template,'service_name'=>'Main Office','slug'=>'office','subdomain'=>'alpha-api-test'];$key=uuid();
    $error(fn()=>$api->handle('POST','/services',$create,$headers,'192.0.2.10'),400);
    $foreign=$create;$foreign['template_uuid']=uuid();$error(fn()=>$api->handle('POST','/services',$foreign,$headers+['Idempotency-Key'=>uuid()],'192.0.2.10'),404,'template_unavailable');
    $foreign=$create;$foreign['template_uuid']=$unpublished;$error(fn()=>$api->handle('POST','/services',$foreign,$headers+['Idempotency-Key'=>uuid()],'192.0.2.10'),404,'template_unavailable');
    $foreign=$create;$foreign['template_uuid']=$notOptedIn;$error(fn()=>$api->handle('POST','/services',$foreign,$headers+['Idempotency-Key'=>uuid()],'192.0.2.10'),404,'template_unavailable');
    $foreign=$create;$foreign['template_uuid']=$unsafeTemplate;$error(fn()=>$api->handle('POST','/services',$foreign,$headers+['Idempotency-Key'=>uuid()],'192.0.2.10'),403,'template_unavailable');
    [$status,$serviceBody]=$api->handle('POST','/services',$create,$headers+['Idempotency-Key'=>$key],'192.0.2.10');$service=$serviceBody['service'];
    $ok($status===201&&$service['tenant_uuid']===$a['tenant_uuid'],'Owned PBX was not created');
    $ok($service['template_version']===1&&$service['software_version']===pbx_updates::version(),'New service did not use current software/template');
    $ok($serviceBody['subdomain']['requested_label']==='alpha-api-test'&&!$serviceBody['subdomain']['ready'],'Alias request falsely ready or lost custom label');
    [$status,$repeated,$extra]=$api->handle('POST','/services',array_reverse($create,true),$headers+['Idempotency-Key'=>$key],'192.0.2.10');
    $ok($status===201&&$repeated==$serviceBody&&$extra['Idempotent-Replayed']==='true','Idempotency did not replay exact result');
    $bad=$create;$bad['service_name']='Changed';$error(fn()=>$api->handle('POST','/services',$bad,$headers+['Idempotency-Key'=>$key],'192.0.2.10'),409,'idempotency_conflict');
    $ok((int)$q('select count(*) from v_pbx_services')->fetchColumn()===1,'Duplicate request created a second PBX');
    $error(fn()=>$api->handle('POST','/services',$create,$headers+['Idempotency-Key'=>uuid()],'192.0.2.10'),409,'service_limit');
    $native=$q('select extension,password from v_extensions where domain_uuid=? order by extension',[$service['domain_uuid']])->fetchAll(PDO::FETCH_ASSOC);
    $ok(array_column($native,'extension')===['100','101']&&count(array_unique(array_column($native,'password')))===2,'Template extensions not created with unique credentials');
    $restored=json_decode($q('select config from v_pbx_restore where domain_uuid=?',[$service['domain_uuid']])->fetchColumn(),true,512,JSON_THROW_ON_ERROR);
    $ok(isset($restored['users']['100'],$restored['users']['101'])&&$restored['realm']===$service['sip_domain'],'New tenant Desktop lacks current calling model');
    $ok((int)$q('select count(*) from v_pbx_tenant_domains where domain_uuid=? and requested_label=?',[$service['domain_uuid'],'alpha-api-test'])->fetchColumn()===1,'Subdomain was not assigned atomically');
    $ok((int)$q('select count(*) from v_gateways where domain_uuid=?',[$service['domain_uuid']])->fetchColumn()===0,'Public provisioning created a provider connection');
    [$status,$list]=$api->handle('GET','/services',[],$headers,'192.0.2.10');$ok($status===200&&count($list['services'])===1,'Own PBX list incorrect');
    $beta=$signup('bravo');$api->handle('POST','/registrations',$beta,[],'192.0.2.21');[, $authB]=$api->handle('POST','/registrations/verify',['token'=>$api->verification[$beta['email']],'password'=>$beta['password']],[],'192.0.2.21');
    $headersB=['Authorization'=>'Bearer '.$authB['access_token']];
    $q("update v_group_permissions set permission_assigned='false' where group_name='tenant_admin' and permission_name='pbx_service_create'");
    $error(fn()=>$api->handle('POST','/services',$create,$headersB+['Idempotency-Key'=>uuid()],'192.0.2.21'),403,'permission_denied');
    $q("update v_group_permissions set permission_assigned='true' where group_name='tenant_admin' and permission_name='pbx_service_create'");
    $error(fn()=>$api->handle('GET','/services/'.$service['service_uuid'],[],$headersB,'192.0.2.21'),404,'not_found');
    $error(fn()=>$api->handle('GET','/services/'.$service['service_uuid'].'/subdomain',[],$headersB,'192.0.2.21'),404,'not_found');
    $error(fn()=>$api->handle('DELETE','/tokens/'.$a['token_uuid'],[],$headersB,'192.0.2.21'),404,'not_found');
    [, $keys]=$api->handle('POST','/tokens',['name'=>'Automation','expires_in_days'=>1],$headers,'192.0.2.10');
    $ok($api->authenticate('Bearer '.$keys['access_token'])['tenant_uuid']===$a['tenant_uuid'],'Additional owner key invalid');
    [, $rotated]=$api->handle('POST','/tokens/'.$keys['token']['token_uuid'].'/rotate',[],$headers,'192.0.2.10');
    $error(fn()=>$api->authenticate('Bearer '.$keys['access_token']),401,'invalid_token');
    $ok($api->authenticate('Bearer '.$rotated['access_token'])['tenant_uuid']===$a['tenant_uuid'],'Rotated key unavailable');
    [$status]=$api->handle('DELETE','/tokens/'.$rotated['token']['token_uuid'],[],$headers,'192.0.2.10');$ok($status===204,'Key revocation did not return204');
    $error(fn()=>$api->authenticate('Bearer '.$rotated['access_token']),401,'invalid_token');
    [$status,$login]=$api->handle('POST','/auth/token',['email'=>$alpha['email'],'password'=>$alpha['password']],[],'192.0.2.10');$ok($status===200&&isset($login['access_token']),'Verified owner login failed');
    $error(fn()=>$api->handle('POST','/auth/token',['email'=>$alpha['email'],'password'=>'Wrong-password-2026'],[],'192.0.2.10'),401,'invalid_credentials');
    $error(fn()=>$api->handle('POST','/auth/token',['email'=>'unknown@tenant-api.test.invalid','password'=>'Wrong-password-2026'],[],'192.0.2.10'),401,'invalid_credentials');
    $badPassword=['current_password'=>'Incorrect-current-2026','new_password'=>'Replacement-tenant-password-2026!'];
    $error(fn()=>$api->handle('POST','/me/password',$badPassword,$headers,'192.0.2.10'),401,'current_password_invalid');
    $newPassword=['current_password'=>$beta['password'],'new_password'=>'Replacement-tenant-password-2026!'];
    [$status,$changedPassword]=$api->handle('POST','/me/password',$newPassword,$headersB,'192.0.2.21');
    $ok($status===200&&$api->authenticate('Bearer '.$changedPassword['access_token'])['tenant_uuid']===$authB['tenant']['tenant_uuid'],'Password change replacement key unavailable');
    $error(fn()=>$api->authenticate('Bearer '.$authB['access_token']),401,'invalid_token');
    $error(fn()=>$api->handle('POST','/auth/token',['email'=>$beta['email'],'password'=>$beta['password']],[],'192.0.2.21'),401,'invalid_credentials');
    [$status]=$api->handle('POST','/auth/token',['email'=>$beta['email'],'password'=>$newPassword['new_password']],[],'192.0.2.21');$ok($status===200,'New account password cannot sign in');
    $ok($native===$q('select extension,password from v_extensions where domain_uuid=? order by extension',[$service['domain_uuid']])->fetchAll(PDO::FETCH_ASSOC),'Changing an administrator password changed SIP phone credentials');
    $charlie=$signup('charlie');$api->handle('POST','/registrations',$charlie,[],'192.0.2.31');
    $q("update v_pbx_api_registrations set expires_at=now()-interval '1 second' where email=?",[$charlie['email']]);
    $error(fn()=>$api->handle('POST','/registrations/verify',['token'=>$api->verification[$charlie['email']],'password'=>$charlie['password']],[],'192.0.2.31'),400,'verification_invalid');
    $ok((int)$q('select count(*) from v_pbx_tenants')->fetchColumn()===2,'Expired verification created an active tenant');
    $q('update v_pbx_tenants set enabled=false where tenant_uuid=?',[$a['tenant_uuid']]);$error(fn()=>$api->authenticate('Bearer '.$auth['access_token']),401,'invalid_token');$q('update v_pbx_tenants set enabled=true where tenant_uuid=?',[$a['tenant_uuid']]);
    $q("update v_users set user_enabled='false' where user_uuid=?",[$a['user_uuid']]);$error(fn()=>$api->authenticate('Bearer '.$auth['access_token']),401,'invalid_token');$q("update v_users set user_enabled='true' where user_uuid=?",[$a['user_uuid']]);
    $q("update v_pbx_api_tokens set expires_at=now()-interval '1 second' where token_uuid=?",[$a['token_uuid']]);$error(fn()=>$api->authenticate('Bearer '.$auth['access_token']),401,'invalid_token');
    for($i=0;$i<3;$i++)$api->rate('isolated-rate-case',3,60);$error(fn()=>$api->rate('isolated-rate-case',3,60),429,'rate_limited');
    $disabled=new tested_tenant_api($db,array_replace($policy,['enabled'=>false]));$error(fn()=>$disabled->handle('GET','/health',[],[],'192.0.2.99'),503,'api_disabled');
    $closed=new tested_tenant_api($db,array_replace($policy,['registration_enabled'=>false]));$error(fn()=>$closed->handle('POST','/registrations',$signup('charlie'),[],'192.0.2.99'),403,'registration_disabled');
    $closed=new tested_tenant_api($db,array_replace($policy,['max_public_tenants'=>2]));$error(fn()=>$closed->handle('POST','/registrations',$signup('charlie'),[],'192.0.2.99'),503,'registration_capacity');
    $audit=json_encode($q('select * from v_pbx_api_audit')->fetchAll(PDO::FETCH_ASSOC));$ok(!str_contains($audit,'@')&&!str_contains($audit,$alpha['password'])&&!str_contains($audit,$auth['access_token']),'Audit log leaked PII/secrets');
    $records=json_encode($q('select * from v_pbx_api_idempotency')->fetchAll(PDO::FETCH_ASSOC));$ok(!str_contains($records,'password')&&!str_contains($records,'owta_'),'Idempotency records leaked credentials');
    echo 'PASS: '.$checks." actual PostgreSQL tenant API controls; isolated schema only\n";
}finally{
    if($db->inTransaction())$db->rollBack();$db->exec('set search_path to public');$db->exec('drop schema if exists '.$schema.' cascade');
}
