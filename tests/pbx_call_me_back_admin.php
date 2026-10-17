<?php
/** Actual Call Me Back owner/account SQL against an explicitly supplied disposable database. */
if(PHP_SAPI!=='cli')exit(2);
$dsn=getenv('OPENWEB_CMB_TEST_DSN');
if(!$dsn){fwrite(STDERR,"Set OPENWEB_CMB_TEST_DSN to an owned disposable PostgreSQL database.\n");exit(2);}
function uuid(): string {$h=bin2hex(random_bytes(16));return substr($h,0,8).'-'.substr($h,8,4).'-4'.substr($h,13,3).'-a'.substr($h,17,3).'-'.substr($h,20);}
function is_uuid($v): bool {return is_string($v)&&(bool)preg_match('/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/Di',$v);}
function permission_exists(string $permission): bool {return !empty($_SESSION['permissions'][$permission]);}
class config {public static function load(): self{return new self;}public function get(string $name): string{return '/nonexistent-cmb-test-sounds';}}
class database {public static PDO $fixture;public static function new(): object{return(object)['db'=>self::$fixture];}}
foreach(['pbx_tenants','pbx_setup','pbx_admin','pbx_staff_access','pbx_call_me_back']as$class)require dirname(__DIR__).'/resources/classes/'.$class.'.php';
class cmb_test_admin extends pbx_call_me_back {protected function voicePackReady(): bool{return true;}protected function key(): string{return str_repeat('F',32);}}
$db=new PDO($dsn,getenv('OPENWEB_CMB_TEST_USER')?:'postgres',getenv('OPENWEB_CMB_TEST_PASSWORD')?:null,[PDO::ATTR_ERRMODE=>PDO::ERRMODE_EXCEPTION]);database::$fixture=$db;
$schema='cmb_admin_'.bin2hex(random_bytes(6));$prior=$_SESSION??[];$checks=0;
$q=static function(string $sql,array $args=[])use($db){$s=$db->prepare($sql);$s->execute($args);return$s;};
$ok=static function($v,string $message)use(&$checks){if(!$v)throw new RuntimeException($message);$checks++;};
$reject=static function(callable $f,string $message)use($ok){try{$f();}catch(InvalidArgumentException|RuntimeException){$ok(true,$message);return;}$ok(false,$message);};
$makeId=static function(string $prefix): string{for($i=0;$i<10;$i++){if(pbx_call_me_back::validSouthAfricanId($prefix.$i))return$prefix.$i;}throw new RuntimeException('Fictional ID fixture generation failed.');};
try {
 $db->exec('create schema '.$schema);$db->exec('set search_path to '.$schema);
 $db->exec('create table v_domains(domain_uuid uuid primary key,domain_name text,domain_enabled boolean);create table v_users(user_uuid uuid primary key,domain_uuid uuid);create table v_pbx_tenants(tenant_uuid uuid primary key,owner_user_uuid uuid,home_domain_uuid uuid,enabled boolean);create table v_pbx_services(tenant_uuid uuid,domain_uuid uuid);create table v_pbx_restore(domain_uuid uuid primary key,config jsonb);create table v_extensions(extension_uuid uuid primary key,domain_uuid uuid,enabled boolean)');
 $db->exec(file_get_contents(dirname(__DIR__).'/app/pbx_setup/resources/call_me_back.sql'));
 $a=uuid();$b=uuid();$owner=uuid();$foreign=uuid();$staff=uuid();$extension=uuid();$rule=uuid();$otherRule=uuid();$tenantA=uuid();$tenantB=uuid();
 foreach([$a,$b]as$d)$q('insert into v_domains values(?,?,true)',[$d,$d.'.invalid']);
 foreach([[$owner,$a],[$foreign,$b],[$staff,$a]]as$u)$q('insert into v_users values(?,?)',$u);
 $q('insert into v_pbx_tenants values(?,?,?,true),(?,?,?,true)',[$tenantA,$owner,$a,$tenantB,$foreign,$b]);
 $q('insert into v_extensions values(?,?,true)',[$extension,$a]);
 $c=['realm'=>$a.'.invalid','users'=>['1000'=>['name'=>'Fictional route owner','extension_uuid'=>$extension,'enabled'=>true]],'trunks'=>['provider'=>['name'=>'Fictional provider','enabled'=>true]],'inbound_rules'=>[['rule_id'=>$rule,'number'=>'+27110000001','trunk_id'=>'provider','condition'=>'BasedOnDID','enabled'=>true],['rule_id'=>$otherRule,'number'=>'+27110000002','trunk_id'=>'provider','condition'=>'BasedOnDID','enabled'=>true]]];
 $q('insert into v_pbx_restore values(?,?::jsonb),(?,?::jsonb)',[$a,json_encode($c),$b,json_encode(['realm'=>$b.'.invalid','users'=>[],'trunks'=>[],'inbound_rules'=>[]])]);
 $_SESSION=['authorized'=>true,'domain_uuid'=>$a,'user_uuid'=>$owner,'permissions'=>['pbx_service_create'=>true]];$admin=new cmb_test_admin($db);
 $ok($admin->installed()&&$admin->dashboard()['services']===[],'Fresh callback schema unavailable');
 $serviceInput=['cmb_action'=>'save_service','service_uuid'=>'','service_name'=>'Fictional Company','incoming_rule_uuid'=>$rule,'route_owner'=>'1000','max_requests_hour'=>30,'destination_prefixes'=>'0, +27','retention_days'=>90];
 $before=$q('select config::text from v_pbx_restore where domain_uuid=?',[$a])->fetchColumn();
 $reject(fn()=>$admin->action($serviceInput+['enabled'=>'1','confirm_handover'=>'1']),'New service enabled before prompts existed');
 $admin->action($serviceInput);$service=$q('select service_uuid from v_pbx_cmb_services where domain_uuid=?',[$a])->fetchColumn();$saved=$admin->dashboard()['services'][0];
 $ok(!$saved['enabled']&&$saved['prompt_state']==='pending'&&$saved['retention_days']===90,'New service was not saved safely switched off');
 $ok($q('select config::text from v_pbx_restore where domain_uuid=?',[$a])->fetchColumn()===$before,'Callback setup changed existing incoming routes');
 $reject(fn()=>$admin->action(array_replace($serviceInput,['incoming_rule_uuid'=>uuid()])),'Foreign incoming route accepted');
 $reject(fn()=>$admin->action(array_replace($serviceInput,['route_owner'=>'9999'])),'Foreign calling user accepted');
 $reject(fn()=>$admin->action(array_replace($serviceInput,['destination_prefixes'=>'0, .*!'])),'Dial string injected through prefixes');
 $reject(fn()=>$admin->action(array_replace($serviceInput,['retention_days'=>6])),'Invalid short retention accepted');
 $reject(fn()=>$admin->action(array_replace($serviceInput,['retention_days'=>3651])),'Invalid long retention accepted');
 $reject(fn()=>$admin->action(array_replace($serviceInput,['enabled'=>['1']])),'Nested enable value accepted');
 $q("update v_pbx_cmb_services set prompt_state='ready',prompt_sha256=repeat('a',64) where service_uuid=?",[$service]);
 $edit=array_replace($serviceInput,['service_uuid'=>$service]);
 $reject(fn()=>$admin->action($edit+['enabled'=>'1']),'Activation omitted handover acknowledgement');
 $admin->action($edit+['enabled'=>'1','confirm_handover'=>'1']);$ok($admin->dashboard()['services'][0]['enabled'],'Ready service did not enable');
 $q('update v_extensions set enabled=false where extension_uuid=?',[$extension]);$reject(fn()=>$admin->action($edit+['enabled'=>'1','confirm_handover'=>'1']),'Native-disabled calling user accepted');$q('update v_extensions set enabled=true where extension_uuid=?',[$extension]);
 $q("update v_pbx_cmb_services set enabled=false,prompt_sha256=null where service_uuid=?",[$service]);$reject(fn()=>$admin->action($edit+['enabled'=>'1','confirm_handover'=>'1']),'Unsealed prompts accepted');$q("update v_pbx_cmb_services set prompt_sha256=repeat('a',64) where service_uuid=?",[$service]);
 $admin->action(array_replace($edit,['service_name'=>'Changed Fictional Company']));$saved=$admin->dashboard()['services'][0];$ok(!$saved['enabled']&&$saved['prompt_state']==='pending','Changed company name retained old enabled greeting');
 $edit['service_name']='Changed Fictional Company';
 $identity=$makeId('800101500908');$alternate=$makeId('810102500908');
 $ok(pbx_call_me_back::validSouthAfricanId($identity),'Valid fictional ID refused');
 foreach(['','123','8001325009087','8001015009287',substr($identity,0,12).(((int)$identity[12]+1)%10)]as$bad)$ok(!pbx_call_me_back::validSouthAfricanId($bad),'Invalid identity accepted');
 $proof=pbx_call_me_back::identityHash($a,$identity,str_repeat('F',32));
 $ok(strlen($proof)===64&&$proof!==pbx_call_me_back::identityHash($b,$identity,str_repeat('F',32)),'Identity hash was not tenant-separated');
 $accountInput=['cmb_action'=>'save_account','account_uuid'=>'','service_uuid'=>$service,'account_name'=>'Fictional Account','south_african_id'=>$identity,'total_minutes'=>'60','enabled'=>'1'];
 $admin->action($accountInput);$account=$q('select account_uuid from v_pbx_cmb_accounts where domain_uuid=?',[$a])->fetchColumn();$row=$q('select * from v_pbx_cmb_accounts where account_uuid=?',[$account])->fetch(PDO::FETCH_ASSOC);
 $ok($row['id_hmac']===$proof&&$row['id_last4']===substr($identity,-4)&&$row['total_seconds']===3600,'Identity/quota not persisted correctly');
 $json=json_encode($admin->dashboard(),JSON_THROW_ON_ERROR);$ok(!str_contains($json,$identity)&&!str_contains($json,$proof),'Dashboard exposed full identity or reusable proof');
 $reject(fn()=>$admin->action($accountInput),'Duplicate identity account accepted');
 $reject(fn()=>$admin->action(array_replace($accountInput,['service_uuid'=>uuid(),'south_african_id'=>$alternate])),'Foreign service account accepted');
 $reject(fn()=>$admin->action(array_replace($accountInput,['south_african_id'=>['nested']])),'Nested identity accepted');
 $reject(fn()=>$admin->action(array_replace($accountInput,['south_african_id'=>$alternate,'total_minutes'=>525601])),'Over-limit account allowance accepted');
 $accountEdit=array_replace($accountInput,['account_uuid'=>$account,'south_african_id'=>'']);
 $q('update v_pbx_cmb_accounts set used_seconds=120,reserved_seconds=600 where account_uuid=?',[$account]);
 $reject(fn()=>$admin->action(array_replace($accountEdit,['total_minutes'=>11])),'Allowance was reduced below reserved plus used time');
 $admin->action(array_replace($accountEdit,['total_minutes'=>12]));$ok((int)$q('select total_seconds from v_pbx_cmb_accounts where account_uuid=?',[$account])->fetchColumn()===720,'Exact usage/reservation allowance refused');
 $reject(fn()=>$admin->action(array_replace($accountEdit,['south_african_id'=>$alternate])),'Existing identity was replaced silently');
 $binding=uuid();$q('insert into v_pbx_cmb_bindings(binding_uuid,domain_uuid,service_uuid,account_uuid,phone_number) values(?,?,?,?,?)',[$binding,$a,$service,$account,'+27820000001']);
 $admin->action(['cmb_action'=>'revoke_binding','binding_uuid'=>$binding]);$ok($q('select revoked_at is not null from v_pbx_cmb_bindings where binding_uuid=?',[$binding])->fetchColumn(),'Saved caller not revoked');
 $binding2=uuid();$q('insert into v_pbx_cmb_bindings(binding_uuid,domain_uuid,service_uuid,account_uuid,phone_number) values(?,?,?,?,?)',[$binding2,$a,$service,$account,'+27820000002']);
 $admin->action(['cmb_action'=>'disable_account','account_uuid'=>$account]);$ok(!$q('select enabled from v_pbx_cmb_accounts where account_uuid=?',[$account])->fetchColumn()&&$q('select revoked_at is not null from v_pbx_cmb_bindings where binding_uuid=?',[$binding2])->fetchColumn(),'Disabled account retained saved authentication');
 $request=uuid();$q("insert into v_pbx_cmb_requests(request_uuid,domain_uuid,service_uuid,inbound_uuid,caller_number,state) values(?,?,?,?,?,'queued')",[$request,$a,$service,uuid(),'+27820000003']);
 $admin->action(['cmb_action'=>'cancel_request','request_uuid'=>$request]);$ok($q('select state from v_pbx_cmb_requests where request_uuid=?',[$request])->fetchColumn()==='cancelled','Waiting request did not cancel');
 $reject(fn()=>$admin->action(['cmb_action'=>'cancel_request','request_uuid'=>$request]),'Completed cancellation was repeated');
 $active=uuid();$q("insert into v_pbx_cmb_requests(request_uuid,domain_uuid,service_uuid,account_uuid,inbound_uuid,caller_number,state,reserved_seconds) values(?,?,?,?,?,?,'connected',600)",[$active,$a,$service,$account,uuid(),'+27820000004']);
 $reject(fn()=>$admin->action(['cmb_action'=>'cancel_request','request_uuid'=>$active]),'Connected call cancelled through waiting-request action');
 $reject(fn()=>$admin->action(['cmb_action'=>'delete_account','account_uuid'=>$account,'confirm_delete'=>'1']),'Account deleted during active call/reservation');
 $q("update v_pbx_cmb_requests set state='completed',used_seconds=120,reserved_seconds=0,completed_at=now() where request_uuid=?",[$active]);$q('update v_pbx_cmb_accounts set reserved_seconds=0 where account_uuid=?',[$account]);
 $reject(fn()=>$admin->action(['cmb_action'=>'delete_account','account_uuid'=>$account]),'Account identity deleted without confirmation');
 $_SESSION['user_uuid']=$staff;$reject(fn()=>new cmb_test_admin($db),'Department staff could open owner account management');$reject(fn()=>$admin->dashboard(),'Existing object survived changed actor');$_SESSION['user_uuid']=$owner;
 $_SESSION['domain_uuid']=$b;$reject(fn()=>$admin->action($accountEdit),'An existing object changed tenants');$_SESSION['domain_uuid']=$a;
 $_SESSION['authorized']=false;$reject(fn()=>$admin->dashboard(),'Logged-out owner retained access');$_SESSION['authorized']=true;
 $_SESSION['user_uuid']=$foreign;$_SESSION['domain_uuid']=$b;$other=new cmb_test_admin($db);$ok($other->dashboard()['services']===[]&&$other->dashboard()['accounts']===[],'Foreign owner read another tenant');$reject(fn()=>$other->action($accountEdit),'Foreign owner modified another tenant account');$reject(fn()=>$other->action(['cmb_action'=>'revoke_binding','binding_uuid'=>$binding]),'Foreign owner revoked caller');$_SESSION['user_uuid']=$owner;$_SESSION['domain_uuid']=$a;
 $audit=$q('select action,actor_uuid,subject_uuid from v_pbx_cmb_audit where domain_uuid=?',[$a])->fetchAll(PDO::FETCH_ASSOC);$counts=array_count_values(array_column($audit,'action'));ksort($counts);$ok($counts===['cancel_request'=>1,'disable_account'=>1,'revoke_binding'=>1,'save_account'=>2,'save_service'=>3],'Accepted/rejected mutation audit totals differ');$ok(!str_contains(json_encode($audit),$identity)&&!str_contains(json_encode($audit),'+2782'),'Audit contained caller identity');
 // Exercise the actual rendered partial with the normal form helpers; no identity/proof can leak.
 $render=static function(array $get)use($db,$c):string{$_GET=$get;$admin=new pbx_admin($db);$e=static fn($v)=>htmlspecialchars(is_scalar($v)?(string)$v:'',ENT_QUOTES,'UTF-8');$csrf=static function(){echo '<input type="hidden" name="fixture_csrf" value="fictional">';};$input=static function($name,$label,$value='',$type='text',$extra='')use($e){echo '<label>'.$e($label).'<input name="'.$e($name).'" type="'.$e($type).'" value="'.$e($value).'" '.$extra.'></label>';};$select=static function($name,$label,$choices,$value='',$extra='')use($e){echo '<label>'.$e($label).'<select name="'.$e($name).'" '.$extra.'>';foreach($choices as$k=>$v)echo '<option value="'.$e($k).'" '.((string)$k===(string)$value?'selected':'').'>'.$e($v).'</option>';echo '</select></label>';};$check=static function($name,$label,$checked=false)use($e){echo '<label class="setup-check-label"><input type="checkbox" name="'.$e($name).'" value="1" '.($checked?'checked':'').'><span>'.$e($label).'</span></label>';};$table=static function($heads,$rows)use($e){echo '<div class="setup-table-wrap"><table class="setup-table"><thead><tr>';foreach($heads as$h)echo '<th>'.$e($h).'</th>';echo '</tr></thead><tbody>';foreach($rows as$r){echo '<tr>';foreach($r as$cell)echo '<td>'.$cell.'</td>';echo '</tr>';}echo '</tbody></table></div>';};ob_start();require dirname(__DIR__).'/app/pbx_setup/call_me_back.php';return ob_get_clean();};
 $html=$render(['account'=>'new']);$ok(str_contains($html,'name="south_african_id" type="password" value=""')&&str_contains($html,'pattern="[0-9]{13}"'),'New account did not protect identity input');
 $html=$render(['account'=>$account]);$ok(!str_contains($html,$identity)&&!str_contains($html,$proof)&&str_contains($html,'*********'.substr($identity,-4)),'Rendered account exposed full identity/proof');$ok(str_contains($html,'Delete account identity')&&str_contains($html,'confirm_delete'),'Deletion is missing its confirmation');
 $html=$render(['service'=>$service]);$ok(str_contains($html,'Save switched off')&&!str_contains($html,'name="enabled"'),'Pending greeting can be enabled in the form');
 if($dir=getenv('OPENWEB_CMB_TEST_HTML_DIR')){
  if(!is_dir($dir)||!is_writable($dir))throw new RuntimeException('Create the private browser fixture directory first.');
  $style=file_get_contents(dirname(__DIR__).'/app/pbx_setup/setup.css').file_get_contents(dirname(__DIR__).'/app/pbx_setup/core.css');
  foreach(['dashboard'=>[],'service-new'=>['service'=>'new'],'service-pending'=>['service'=>$service],'account-new'=>['account'=>'new'],'account-edit'=>['account'=>$account]]as$file=>$get){$body=$render($get);file_put_contents($dir.'/'.$file.'.html','<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><title>Fictional callback UI fixture</title><style>body{margin:0;font-family:Arial,sans-serif;background:#eef3fa}html[data-theme="dark"]{--openweb-text:#edf4ff;--openweb-surface:#152239;--openweb-line:#35445d;--openweb-bg:#0d192b;--openweb-accent:#6ebcff}html[data-theme="dark"] body{background:#0d192b}'.$style.'</style></head><body><main class="pbx-setup"><header class="setup-heading"><h1>Admin</h1></header><div class="setup-shell"><nav class="setup-nav"><a href="#">Call Handling</a><a class="selected" href="#">Call Me Back</a></nav><div class="setup-content"><section class="setup-card"><h2>Call Me Back</h2>'.$body.'</section></div></div></main></body></html>');chmod($dir.'/'.$file.'.html',0600);}
 }
 $admin->action(['cmb_action'=>'delete_account','account_uuid'=>$account,'confirm_delete'=>'1']);$deleted=$q('select name,id_hmac,id_last4,enabled,used_seconds,total_seconds from v_pbx_cmb_accounts where account_uuid=?',[$account])->fetch(PDO::FETCH_ASSOC);
 $ok($deleted['name']==='Deleted account'&&$deleted['id_hmac']===null&&$deleted['id_last4']===null&&!$deleted['enabled']&&$deleted['used_seconds']===120&&$deleted['total_seconds']===720,'Deletion lost ledger or retained identity');
 $ok((int)$q('select count(*) from v_pbx_cmb_bindings where account_uuid=?',[$account])->fetchColumn()===0&&$q('select caller_number from v_pbx_cmb_requests where request_uuid=?',[$active])->fetchColumn()===null,'Deletion retained callback identity');
 $ok((int)$q("select count(*) from v_pbx_cmb_audit where domain_uuid=? and action='delete_account' and subject_uuid=?",[$a,$account])->fetchColumn()===1,'Identity deletion was not audited exactly once');
 $reject(fn()=>$admin->action($accountEdit),'Deleted identity account was resurrected');
 $html=$render(['account'=>$account]);$ok(!str_contains($html,'name="account_name"')&&!str_contains($html,'*********'.substr($identity,-4)),'Deleted account remained editable or identifiable');
 $q('update v_pbx_tenants set enabled=false where tenant_uuid=?',[$tenantA]);$reject(fn()=>$admin->dashboard(),'Suspended tenant retained callback administration');
 echo "PASS: $checks actual PostgreSQL callback-owner, prompt activation, identity privacy, quota, audit, deletion, rendering and tenant boundaries\n";
}finally{if($db->inTransaction())$db->rollBack();$db->exec('set search_path to public');$db->exec('drop schema if exists '.$schema.' cascade');$_SESSION=$prior;}
