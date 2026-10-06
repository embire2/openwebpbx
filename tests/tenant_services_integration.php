<?php
/** Run: php tests/tenant_services_integration.php. Uses a temporary PostgreSQL schema; no customer records are changed. */
if (PHP_SAPI !== 'cli') { http_response_code(404); exit; }
require dirname(__DIR__).'/resources/require.php';
require_once dirname(__DIR__).'/resources/classes/pbx_tenants.php';
$pdo=$database->db;$pdo->setAttribute(PDO::ATTR_ERRMODE,PDO::ERRMODE_EXCEPTION);
$schema='openweb_test_'.bin2hex(random_bytes(6));
$assert=function(bool $ok,string $message){if(!$ok)throw new RuntimeException($message);};
$throws=function(callable $fn,string $message)use($assert){try{$fn();}catch(Throwable $e){return;}$assert(false,$message);};
$query=function(string $sql,array $p=[])use($pdo){$s=$pdo->prepare($sql);$s->execute($p);return $s;};
class tested_pbx_tenants extends pbx_tenants {
    public bool $is_platform=true;
    protected function allowed(string $name): bool { return in_array($name,['pbx_service_create','pbx_template_manage'],true) || ($this->is_platform && in_array($name,['pbx_tenant_manage','domain_all'],true)); }
}
try {
    $pdo->exec('create schema '.$schema);$pdo->exec('set search_path to '.$schema.',public');
    $tables=['v_domains','v_users','v_user_groups','v_groups','v_group_permissions','v_permissions','v_menus','v_menu_items','v_menu_languages','v_menu_item_groups','v_dialplans','v_dialplan_details','v_domain_settings','v_extensions','v_voicemails','v_gateways','v_default_settings'];
    foreach($tables as $table)$pdo->exec('create table '.$table.' (like public.'.$table.' including all)');
    foreach(['v_groups','v_group_permissions','v_permissions','v_menus','v_menu_items','v_menu_languages','v_menu_item_groups','v_default_settings'] as $table)$pdo->exec('insert into '.$table.' select * from public.'.$table);
    $pdo->exec("insert into v_domains select * from public.v_domains where domain_name='call.openweb.co.za'");
    $pdo->exec('insert into v_dialplans select * from public.v_dialplans where domain_uuid in (select domain_uuid from v_domains) and app_uuid is not null');
    $pdo->exec('insert into v_dialplan_details select * from public.v_dialplan_details where dialplan_uuid in (select dialplan_uuid from v_dialplans)');
    $pdo->exec(file_get_contents(dirname(__DIR__).'/app/tenant_services/resources/install.sql'));
    $platformDomain=$pdo->query('select domain_uuid from v_domains')->fetchColumn();$platformUser=uuid();
    $query("insert into v_users(user_uuid,domain_uuid,username,user_email,user_enabled) values(:id,:domain,'test-platform@test.invalid','test-platform@test.invalid',true)",['id'=>$platformUser,'domain'=>$platformDomain]);
    $_SESSION=['user_uuid'=>$platformUser,'domain_uuid'=>$platformDomain,'user'=>['domain_uuid'=>$platformDomain]];
    $app=new tested_pbx_tenants($pdo);
    $config=['timezone'=>'Africa/Johannesburg','extension_start'=>100,'extension_count'=>2,'extension_limit'=>5,'trunks'=>[['name'=>'Fixture trunk','proxy'=>'sip.example.invalid','username'=>'fixture','password'=>'fixture-only-secret','transport'=>'udp','register'=>true,'enabled'=>false]],'rules'=>[['name'=>'Local calls','pattern'=>'^(0[0-9]{9})$','trunk'=>0,'prefix'=>'']],'settings'=>[['category'=>'voicemail','subcategory'=>'file','type'=>'text','value'=>'attach']]];
    $template=$app->saveTemplate(['template_name'=>'Test template','published'=>true,'config'=>$config]);
    $cipher=$query('select payload_ciphertext from v_pbx_templates where template_uuid=:id',['id'=>$template])->fetchColumn();$assert(!str_contains($cipher,'fixture-only-secret'),'Template credentials were not encrypted');
    $bad=$config;$bad['settings']=[['category'=>'security','subcategory'=>'command','type'=>'text','value'=>'bad']];$throws(fn()=>$app->saveTemplate(['template_name'=>'Unsafe','config'=>$bad]),'Unsafe domain setting accepted');
    $bad=$config;$bad['rules'][0]['pattern']='[';$throws(fn()=>$app->saveTemplate(['template_name'=>'Bad regex','config'=>$bad]),'Invalid call rule accepted');
    $urls=[];$tenants=[];
    $old=$app->invite(['tenant_name'=>'Pending','slug'=>'pending','email'=>'pending@test.invalid']);parse_str(parse_url($old,PHP_URL_QUERY),$oldArgs);
    $pending=$query("select tenant_uuid from v_pbx_tenants where slug='pending'")->fetchColumn();$renewed=$app->renewInvitation($pending);parse_str(parse_url($renewed,PHP_URL_QUERY),$newArgs);
    $assert(!$app->invitation($oldArgs['invite']) && (bool)$app->invitation($newArgs['invite']),'Renewed invitation did not invalidate the old link');
    foreach(['alpha','beta'] as $slug){$urls[$slug]=$app->invite(['tenant_name'=>ucfirst($slug),'slug'=>$slug,'email'=>$slug.'@test.invalid','service_limit'=>1]);parse_str(parse_url($urls[$slug],PHP_URL_QUERY),$args);$app->accept($args['invite'],'Fixture-password-123');$assert(!$app->invitation($args['invite']),'Invitation could be replayed');$tenants[$slug]=$query('select * from v_pbx_tenants where slug=:slug',['slug'=>$slug])->fetch(PDO::FETCH_ASSOC);}
    $app->is_platform=false;$a=$tenants['alpha'];$_SESSION=['user_uuid'=>$a['owner_user_uuid'],'domain_uuid'=>$a['home_domain_uuid'],'user'=>['domain_uuid'=>$a['home_domain_uuid']]];
    $request=uuid();$service=$app->provision(['tenant_uuid'=>$a['tenant_uuid'],'template_uuid'=>$template,'service_name'=>'Office','slug'=>'office','request_uuid'=>$request]);
    $same=$app->provision(['tenant_uuid'=>$a['tenant_uuid'],'template_uuid'=>$template,'service_name'=>'Office','slug'=>'office','request_uuid'=>$request]);$assert($same===$service,'Repeated submission created another service');
    $domain=$query('select domain_uuid from v_pbx_services where service_uuid=:id',['id'=>$service])->fetchColumn();
    $assert((int)$query('select count(*) from v_extensions where domain_uuid=:id',['id'=>$domain])->fetchColumn()===2,'Extension defaults were not provisioned');
    $assert((int)$query('select count(distinct password) from v_extensions where domain_uuid=:id',['id'=>$domain])->fetchColumn()===2,'SIP passwords were reused');
    $assert((int)$query('select count(*) from v_voicemails where domain_uuid=:id',['id'=>$domain])->fetchColumn()===2,'Voicemail defaults were not provisioned');
    $assert($app->canDomain($domain),'Owner cannot open their PBX');$assert(!$app->canDomain($tenants['beta']['home_domain_uuid']),'Cross-tenant domain access allowed');
    $throws(fn()=>$app->provision(['tenant_uuid'=>$tenants['beta']['tenant_uuid'],'template_uuid'=>$template,'service_name'=>'Other','slug'=>'other','request_uuid'=>uuid()]),'Cross-tenant service creation allowed');
    $throws(fn()=>$app->provision(['tenant_uuid'=>$a['tenant_uuid'],'template_uuid'=>$template,'service_name'=>'Second','slug'=>'second','request_uuid'=>uuid()]),'Tenant service limit was bypassed');
    $private=$app->saveTemplate(['template_name'=>'Alpha private','published'=>true,'config'=>$config]);
    $b=$tenants['beta'];$_SESSION=['user_uuid'=>$b['owner_user_uuid'],'domain_uuid'=>$b['home_domain_uuid'],'user'=>['domain_uuid'=>$b['home_domain_uuid']]];
    $throws(fn()=>$app->template($private),'Private template visible to another tenant');$throws(fn()=>$app->saveTemplate(['template_uuid'=>$template,'template_name'=>'Hijack','config'=>$config]),'Tenant could edit shared template');
    $serviceB=$app->provision(['tenant_uuid'=>$b['tenant_uuid'],'template_uuid'=>$template,'service_name'=>'Office','slug'=>'office','request_uuid'=>uuid()]);
    $domainB=$query('select domain_uuid from v_pbx_services where service_uuid=:id',['id'=>$serviceB])->fetchColumn();$assert($domainB!==$domain,'PBX domains were shared');
    $gatewayA=$query('select gateway_uuid from v_gateways where domain_uuid=:id',['id'=>$domain])->fetchColumn();$assert(!(bool)$query('select 1 from v_dialplan_details where domain_uuid=:id and dialplan_detail_data like :gateway',['id'=>$domainB,'gateway'=>'%'.$gatewayA.'%'])->fetchColumn(),'Call rules reference another tenant trunk');
    $query("update v_pbx_templates set published=false where template_uuid=:id",['id'=>$template]);$assert((int)$query('select count(*) from v_extensions where domain_uuid=:id',['id'=>$domain])->fetchColumn()===2,'Unpublishing changed an existing PBX');
    $query('update v_pbx_tenants set enabled=false where tenant_uuid=:id',['id'=>$b['tenant_uuid']]);$assert(!$app->canDomain($domainB),'Suspension did not revoke access');
    echo "PASS: invitation replay, credential encryption, validation, isolated domains/trunks/rules, service limits, idempotency, private templates, shared template ownership, suspension, and preserved services\n";
} finally {
    if($pdo->inTransaction())$pdo->rollBack();$pdo->exec('set search_path to public');$pdo->exec('drop schema if exists '.$schema.' cascade');
}
