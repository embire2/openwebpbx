<?php
/** Actual PostgreSQL tenant portfolio boundaries. No calls, mail or customer rows. */
if(PHP_SAPI!=='cli')exit(2);
$no_session=true;$_SESSION=[];require dirname(__DIR__).'/resources/require.php';
$db=$database->db;$schema='openweb_tenant_api_'.bin2hex(random_bytes(6));$checks=0;
$q=function(string $sql,array $in=[])use($db){$s=$db->prepare($sql);$s->execute($in);return $s;};
$ok=function(bool $pass,string $why)use(&$checks){$checks++;if(!$pass)throw new RuntimeException($why);};
$denied=function(callable $action,string $why)use($ok){try{$action();}catch(pbx_api_access_denied|OutOfBoundsException|InvalidArgumentException){$ok(true,$why);return;}$ok(false,$why);};
$as=function(string $user,string $domain){$_SESSION=['authorized'=>true,'user_uuid'=>$user,'domain_uuid'=>$domain,'user'=>['domain_uuid'=>$domain]];permissions::reset();};
try{
 $db->exec('create schema '.$schema);
 // Shadow every customer table so an unseeded fixture cannot read live rows.
 foreach($db->query("select tablename from pg_tables where schemaname='public' and tablename like 'v_%'")->fetchAll(PDO::FETCH_COLUMN) as $table){if(!preg_match('/^v_[a-z0-9_]+$/D',$table))throw new RuntimeException('Unexpected table');$db->exec('create table '.$schema.'.'.$table.' (like public.'.$table.' including all)');}
 $db->exec('set search_path to '.$schema.',public');
 $group=uuid();$q("insert into v_groups(group_uuid,group_name)values(?,'tenant_admin')",[$group]);
 foreach(['pbx_api_key_manage','pbx_service_view','pbx_service_create','pbx_template_manage','extension_view','extension_edit','gateway_view','gateway_edit','pbx_tenant_backup','pbx_update_manage'] as $permission)$q("insert into v_group_permissions(group_permission_uuid,group_uuid,group_name,permission_name,permission_assigned)values(?,?,'tenant_admin',?,'true')",[uuid(),$group,$permission]);
 $users=[];$homes=[];$tenants=[];
 foreach(['alpha','beta','pbx-admin'] as $name){$homes[$name]=uuid();$users[$name]=uuid();$q('insert into v_domains(domain_uuid,domain_name,domain_enabled)values(?,?,true)',[$homes[$name],$name.'.fixture.invalid']);$q("insert into v_users(user_uuid,domain_uuid,username,user_enabled)values(?,?,?,'true')",[$users[$name],$homes[$name],$name.'@fixture.invalid']);$q("insert into v_user_groups(user_group_uuid,user_uuid,domain_uuid,group_uuid,group_name)values(?,?,?,?,'tenant_admin')",[uuid(),$users[$name],$homes[$name],$group]);}
 foreach(['alpha','beta'] as $name){$tenants[$name]=uuid();$q('insert into v_pbx_tenants(tenant_uuid,tenant_name,slug,home_domain_uuid,owner_user_uuid,invite_email)values(?,?,?,?,?,?)',[$tenants[$name],ucfirst($name),$name,$homes[$name],$users[$name],$name.'@fixture.invalid']);}
 $add=function(string $name,string $tenant)use($q,$users){$domain=uuid();$q('insert into v_domains(domain_uuid,domain_name,domain_enabled)values(?,?,true)',[$domain,$name.'.fixture.invalid']);$q('insert into v_pbx_services(service_uuid,tenant_uuid,domain_uuid,service_name,template_name,template_version,request_uuid,created_by)values(?,?,?,?,?,?,?,?)',[uuid(),$tenant,$domain,$name,'Fixture',1,uuid(),$users['alpha']]);$q("insert into v_pbx_restore(domain_uuid,source_version,config,report)values(?,'fixture',?::jsonb,'{}')",[$domain,json_encode(['realm'=>$name.'.fixture.invalid','users'=>['1000'=>['number'=>'1000','name'=>$name,'password'=>'private-fixture-only','auth_id'=>'private-fixture-id']],'trunks'=>[],'departments'=>[],'queues'=>[],'ring_groups'=>[],'receptionists'=>[],'inbound_rules'=>[],'outbound_rules'=>[],'scripts'=>[]])]);return $domain;};
 $a=$add('alpha-a',$tenants['alpha']);$b=$add('alpha-b',$tenants['alpha']);$foreign=$add('beta-a',$tenants['beta']);
 $keys=new pbx_access_keys($db);$api=new pbx_reseller_api($db);$as($users['alpha'],$homes['alpha']);
 $choices=$keys->choices();$ok($choices['tenant_admin_tenants']===[$tenants['alpha']],'Full tenant preset offered a foreign tenant');
 $ok(count(pbx_access_keys::TENANT_ADMIN_SCOPES)===9&&!array_intersect(pbx_access_keys::TENANT_ADMIN_SCOPES,['system:manage','reseller:manage',...pbx_access_keys::ACCOUNT_SCOPES]),'Full tenant preset contains instance, reseller or account authority');
 $q('update v_users set domain_uuid=? where user_uuid=?',[$a,$users['pbx-admin']]);$q('update v_user_groups set domain_uuid=? where user_uuid=?',[$a,$users['pbx-admin']]);$as($users['pbx-admin'],$a);
 $ok($keys->choices()['tenant_admin_tenants']===[],'PBX-only administrator was offered full tenant authority');
 $denied(fn()=>$keys->create(['name'=>'PBX admin escalation','tenant_uuid'=>$tenants['alpha'],'scopes'=>pbx_access_keys::TENANT_ADMIN_SCOPES]),'PBX-only administrator created a tenant-wide key');
 $as($users['alpha'],$homes['alpha']);
 $full=$keys->create(['name'=>'Full tenant fixture','tenant_uuid'=>$tenants['alpha'],'scopes'=>pbx_access_keys::TENANT_ADMIN_SCOPES]);$auth='Bearer '.$full['token'];
 $identity=$keys->authenticate($auth,'192.0.2.40');$ok($identity['tenant_uuid']===$tenants['alpha']&&$identity['domain_uuid']===null&&!$identity['instance'],'Full key lost its tenant-only boundary');
 $services=$api->handle('GET','/services',[],$auth,'192.0.2.40');$ids=array_column($services,'domain_uuid');sort($ids);$expected=[$a,$b];sort($expected);$ok($ids===$expected,'Full key did not list exactly its current services');
 foreach([$a,$b] as $domain){$data=$api->handle('GET','/pbx/'.$domain.'/users',[],$auth,'192.0.2.40');$ok(isset($data['1000'])&&!str_contains(json_encode($data),'private-fixture'),'Full key could not read a permitted PBX or exposed credentials in public reads');}
 $new=$add('alpha-future',$tenants['alpha']);$ok(isset($api->handle('GET','/pbx/'.$new.'/users',[],$auth,'192.0.2.40')['1000']),'Existing tenant key could not reach a newly added service');
 $ok(count($api->handle('GET','/services',[],$auth,'192.0.2.40'))===3,'New service absent from tenant portfolio');
 foreach(['/pbx/'.$foreign.'/users','/instance/mail','/instance/backups','/instance/reseller-policy'] as $path)$denied(fn()=>$api->handle('GET',$path,[],$auth,'192.0.2.40'),'Full key escaped tenant boundary at '.$path);
 $denied(fn()=>$api->handle('POST','/tenants',['tenant_name'=>'Not permitted','slug'=>'not-permitted','email'=>'no@fixture.invalid'],$auth,'192.0.2.40'),'Full tenant key gained reseller invitation authority');
 $denied(fn()=>$keys->create(['name'=>'Wrong tenant','tenant_uuid'=>$tenants['beta'],'scopes'=>pbx_access_keys::TENANT_ADMIN_SCOPES]),'Owner created full access to another tenant');
 $as($users['alpha'],$homes['alpha']);$one=$keys->create(['name'=>'One service','tenant_uuid'=>$tenants['alpha'],'domain_uuid'=>$a,'scopes'=>pbx_access_keys::TENANT_ADMIN_SCOPES]);$oneAuth='Bearer '.$one['token'];
 $denied(fn()=>$api->handle('GET','/pbx/'.$b.'/users',[],$oneAuth,'192.0.2.40'),'PBX-specific full key reached another PBX');$denied(fn()=>$api->handle('GET','/services',[],$oneAuth,'192.0.2.40'),'PBX-specific key enumerated tenant services');
 $child=$api->handle('POST','/keys',['name'=>'Narrow child','scopes'=>['pbx:read'],'days'=>365],$auth,'192.0.2.40');$childIdentity=$keys->authenticate('Bearer '.$child['token'],'192.0.2.40');$ok($childIdentity['tenant_uuid']===$tenants['alpha']&&$childIdentity['domain_uuid']===null&&$childIdentity['parent_key_uuid']===$full['key_uuid'],'Delegation changed tenant boundary');
 $denied(fn()=>$api->handle('POST','/keys',['name'=>'Escalate','scopes'=>['system:manage']],$auth,'192.0.2.40'),'Tenant key delegated instance authority');
 $denied(fn()=>$api->handle('POST','/keys',['name'=>'Escalate reseller','scopes'=>['reseller:manage']],$auth,'192.0.2.40'),'Tenant key delegated reseller authority');
 $q('update v_domains set domain_enabled=false where domain_uuid=?',[$b]);$denied(fn()=>$api->handle('GET','/pbx/'.$b.'/users',[],$auth,'192.0.2.40'),'Tenant key ignored PBX suspension');$q('update v_domains set domain_enabled=true where domain_uuid=?',[$b]);
 $q('update v_pbx_services set tenant_uuid=? where domain_uuid=?',[$tenants['beta'],$new]);$denied(fn()=>$api->handle('GET','/pbx/'.$new.'/users',[],$auth,'192.0.2.40'),'Tenant key retained a service moved to another tenant');
 $q('update v_pbx_tenants set enabled=false where tenant_uuid=?',[$tenants['alpha']]);$denied(fn()=>$keys->authenticate($auth,'192.0.2.40'),'Full tenant key ignored tenant suspension');$q('update v_pbx_tenants set enabled=true where tenant_uuid=?',[$tenants['alpha']]);
 $as($users['alpha'],$homes['alpha']);$keys->revoke($full['key_uuid']);$denied(fn()=>$keys->authenticate('Bearer '.$child['token'],'192.0.2.40'),'Revoked full tenant key left delegated access active');
 $q("update v_group_permissions set permission_assigned='false' where group_uuid=? and permission_name='pbx_api_key_manage'",[$group]);$denied(fn()=>$keys->authenticate($oneAuth,'192.0.2.40'),'Key ignored administrator role withdrawal');
 echo 'PASS '.$checks." actual PostgreSQL full-tenant/multi-PBX API controls; no customer rows or calls changed.\n";
}finally{if($db->inTransaction())$db->rollBack();$db->exec('set search_path to public');$db->exec('drop schema if exists '.$schema.' cascade');}
