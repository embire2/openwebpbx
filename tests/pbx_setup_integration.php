<?php
/** CLI-only setup workflow checks against an isolated PostgreSQL schema. */
if (PHP_SAPI !== 'cli') { http_response_code(404); exit; }
require dirname(__DIR__).'/resources/require.php';
class setup_test_tenants extends pbx_tenants {
    public static bool $platform = true;
    protected function allowed(string $name): bool { return in_array($name,['pbx_service_create','pbx_template_manage'],true) || (self::$platform && in_array($name,['pbx_tenant_manage','domain_all'],true)); }
}
class tested_pbx_setup extends pbx_setup {
    private PDO $testDb;
    public function __construct(PDO $db) { parent::__construct($db); $this->testDb=$db; }
    protected function allowed(string $permission): bool { return $permission==='pbx_service_create'; }
    protected function tenantManager(): pbx_tenants { return new setup_test_tenants($this->testDb); }
}
$db=$database->db; $db->setAttribute(PDO::ATTR_ERRMODE,PDO::ERRMODE_EXCEPTION);
$schema='openweb_guided_test_'.bin2hex(random_bytes(6));
$query=function(string $sql,array $params=[])use($db){$s=$db->prepare($sql);$s->execute($params);return $s;};
$assert=function(bool $condition,string $message){if(!$condition)throw new RuntimeException($message);};
$reject=function(callable $fn,string $message)use($assert){try{$fn();}catch(Throwable $e){return;}$assert(false,$message);};
try {
    $db->exec('create schema '.$schema); $db->exec('set search_path to '.$schema.',public');
    $tables=['v_domains','v_users','v_user_groups','v_groups','v_group_permissions','v_permissions','v_menus','v_menu_items','v_menu_languages','v_menu_item_groups','v_dialplans','v_dialplan_details','v_domain_settings','v_extensions','v_voicemails','v_gateways','v_ring_groups','v_ring_group_destinations','v_destinations','v_default_settings'];
    foreach($tables as $table)$db->exec('create table '.$table.' (like public.'.$table.' including all)');
    foreach(['v_groups','v_group_permissions','v_permissions','v_menus','v_menu_items','v_menu_languages','v_menu_item_groups','v_default_settings'] as $table)$db->exec('insert into '.$table.' select * from public.'.$table);
    $db->exec("insert into v_domains select * from public.v_domains where domain_name='call.openweb.co.za'");
    $db->exec('insert into v_dialplans select * from public.v_dialplans where domain_uuid in(select domain_uuid from v_domains) and app_uuid is not null');
    $db->exec('insert into v_dialplan_details select * from public.v_dialplan_details where dialplan_uuid in(select dialplan_uuid from v_dialplans)');
    $db->exec(file_get_contents(dirname(__DIR__).'/app/tenant_services/resources/install.sql'));
    $db->exec(file_get_contents(dirname(__DIR__).'/app/pbx_setup/resources/install.sql'));
    $home=$db->query('select domain_uuid from v_domains')->fetchColumn(); $owner=uuid(); $foreign=uuid();
    $query("insert into v_dialplans(dialplan_uuid,domain_uuid,app_uuid,dialplan_name,dialplan_context,dialplan_enabled,dialplan_xml) values(:id,:domain,'8c914ec3-9fc0-8ab5-4cda-6c9288bdc9a3','Fixture platform outbound','call.openweb.co.za','true','<extension name=\"Foreign carrier\"/>')",['id'=>uuid(),'domain'=>$home]);
    foreach([$owner,$foreign] as $user)$query('insert into v_users(user_uuid,domain_uuid,username,user_email,user_enabled) values(:id,:domain,:email,:email,true)',['id'=>$user,'domain'=>$home,'email'=>$user.'@example.invalid']);
    $_SESSION=['user_uuid'=>$owner,'domain_uuid'=>$home,'domain_name'=>'call.openweb.co.za','user'=>['domain_uuid'=>$home]];
    $setup=new tested_pbx_setup($db);
    $input=['company_name'=>'Fixture company','service_name'=>'Main office','tenant_uuid'=>'','timezone'=>'Africa/Johannesburg','users'=>[['number'=>'100','name'=>'Alice Fixture','email'=>'alice@example.invalid'],['number'=>'101','name'=>'Bob Fixture','email'=>''],['number'=>'','name'=>'','email'=>'']],
        'trunk'=>['name'=>'Fixture trunk','host'=>'sip.example.invalid','port'=>'5060','transport'=>'udp','authentication'=>'password','username'=>'fixture-user','password'=>'Private-fixture-trunk-secret'],
        'inbound_number'=>'+27112345678','inbound_destination'=>'100','outbound'=>['prefix'=>'0','strip'=>'1','prepend'=>'+27']];
    $draft=$setup->reviewSetup($input); $id=$draft['draft_id'];
    $assert($draft['summary']['user_count']===2 && $draft['counts']['numbers']===1,'Review counts differ');
    $assert(!str_contains(json_encode($draft),'Private-fixture-trunk-secret') && !str_contains(json_encode($draft),'fixture-user'),'Review exposed credentials');
    $cipher=$query('select payload_ciphertext from v_pbx_setup_drafts where draft_uuid=:id',['id'=>$id])->fetchColumn();
    $assert(!str_contains($cipher,'Private-fixture-trunk-secret'),'Draft secrets not encrypted');
    $_SESSION['user_uuid']=$foreign; $reject(fn()=>$setup->draft($id),'Foreign administrator read draft'); $reject(fn()=>$setup->createSetup($id),'Foreign administrator consumed draft'); $_SESSION['user_uuid']=$owner;
    $bad=$input;$bad['users'][1]['number']='100';$reject(fn()=>$setup->reviewSetup($bad),'Duplicate user accepted');
    $bad=$input;$bad['inbound_destination']='999';$reject(fn()=>$setup->reviewSetup($bad),'Foreign DID destination accepted');
    $bad=$input;$bad['outbound']['prefix']='.*';$reject(fn()=>$setup->reviewSetup($bad),'Injected rule accepted');
    $bad=$input;$bad['trunk']['host']=['sip.example.invalid'];$reject(fn()=>$setup->reviewSetup($bad),'Nested SIP server accepted');
    $bad=$input;$bad['company_name']=['Fixture company'];$reject(fn()=>$setup->reviewSetup($bad),'Nested company name accepted');
    $domain=$setup->createSetup($id); $assert($setup->createSetup($id)===$domain,'Repeat submission created another PBX');
    $assert((int)$db->query('select count(*) from v_pbx_services')->fetchColumn()===1,'Service not created exactly once');
    $assert((int)$query('select count(*) from v_extensions where domain_uuid=:domain',['domain'=>$domain])->fetchColumn()===2,'Users missing');
    $assert((int)$query("select count(*) from v_dialplans where domain_uuid=:domain and dialplan_name='Fixture platform outbound'",['domain'=>$domain])->fetchColumn()===0,'Platform business route copied into tenant');
    $assert($query('select context from v_gateways where domain_uuid=:domain',['domain'=>$domain])->fetchColumn()!== 'public','Gateway escaped private context');
    $assert(!filter_var($query('select enabled from v_gateways where domain_uuid=:domain',['domain'=>$domain])->fetchColumn(),FILTER_VALIDATE_BOOLEAN),'Unverified trunk enabled');
    $assert($query('select payload_ciphertext from v_pbx_setup_drafts where draft_uuid=:id',['id'=>$id])->fetchColumn()===null,'Consumed draft retained secrets');
    $assert((int)$db->query('select count(*) from v_pbx_templates')->fetchColumn()===0,'Temporary template remained');
    $manager=new setup_test_tenants($db);$tenant=$manager->tenant();$assert($tenant['owner_user_uuid']===$owner,'Company bootstrap owner differs');
    setup_test_tenants::$platform=false;
    $assert($setup->canManage(),'Tenant owner cannot run guided setup');
    $input['tenant_uuid']=$tenant['tenant_uuid'];$input['service_name']='Rollback fixture';
    $rollback=$setup->reviewSetup($input);$query('update v_pbx_tenants set service_limit=1 where tenant_uuid=:id',['id'=>$tenant['tenant_uuid']]);
    $reject(fn()=>$setup->createSetup($rollback['draft_id']),'Service limit bypassed');
    $assert((int)$db->query('select count(*) from v_pbx_services')->fetchColumn()===1 && (int)$db->query('select count(*) from v_pbx_templates')->fetchColumn()===0,'Failed creation left partial configuration');
    $query('update v_pbx_tenants set service_limit=3 where tenant_uuid=:id',['id'=>$tenant['tenant_uuid']]);
    $db->exec("alter table v_voicemails add constraint fixture_failure check(voicemail_mail_to is distinct from 'alice@example.invalid') not valid");
    $reject(fn()=>$setup->createSetup($rollback['draft_id']),'Injected native persistence failure was ignored');
    $assert((int)$db->query('select count(*) from v_pbx_services')->fetchColumn()===1 && (int)$db->query('select count(*) from v_domains')->fetchColumn()===3 && (int)$db->query('select count(*) from v_extensions')->fetchColumn()===2 && (int)$db->query('select count(*) from v_pbx_templates')->fetchColumn()===0,'Native persistence failure left a partial domain or users');
    $db->exec('alter table v_voicemails drop constraint fixture_failure');
    $query('update v_pbx_setup_drafts set expires_at=now()-interval \'1 second\' where draft_uuid=:id',['id'=>$rollback['draft_id']]);$reject(fn()=>$setup->draft($rollback['draft_id']),'Expired draft visible');
    $_SESSION['user_uuid']=$foreign;$assert(!$setup->canManage(),'Unrelated user gained setup permissions');$_SESSION['user_uuid']=$owner;
    $query('update v_pbx_tenants set enabled=false where tenant_uuid=:id',['id'=>$tenant['tenant_uuid']]);$assert(!$setup->canManage(),'Suspended tenant can manage setup');
    echo "PASS: guided review, validation, encrypted credentials, private drafts, company bootstrap, native records, disabled provider ingress, idempotency, atomic rollback, expiry and tenant access\n";
} finally {
    if($db->inTransaction())$db->rollBack();$db->exec('set search_path to public');$db->exec('drop schema if exists '.$schema.' cascade');
}
