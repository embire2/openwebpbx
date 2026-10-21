<?php
/** Real PostgreSQL, isolated schema; never reloads providers or calls a customer. */
if(PHP_SAPI!=='cli')exit(2);
// Production deliberately grants CLI all permissions; use the real HTTP permission shape here.
function permission_exists($name): bool {return !empty($_SESSION['permissions'][$name]);}
require dirname(__DIR__).'/resources/require.php';
$db=database::new()->db;$db->setAttribute(PDO::ATTR_ERRMODE,PDO::ERRMODE_EXCEPTION);
$schema='trunk_routes_'.bin2hex(random_bytes(6));$checks=0;$prior=$_SESSION??[];
$q=static function(string $sql,array $p=[])use($db){$s=$db->prepare($sql);$s->execute($p);return $s;};
$ok=static function(bool $v,string $m)use(&$checks){if(!$v)throw new RuntimeException($m);$checks++;};
$reject=static function(callable $f,string $m)use($ok){try{$f();}catch(InvalidArgumentException|RuntimeException $e){$ok(true,$m);return;}$ok(false,$m);};
try{
    $db->exec('create schema '.$schema);$db->exec('set search_path to '.$schema.',public');
    foreach(['v_domains','v_users','v_pbx_tenants','v_pbx_services','v_pbx_restore','v_extensions','v_gateways','v_dialplans','v_destinations','v_pbx_staff_audit','v_pbx_cmb_services','v_pbx_cmb_audit'] as $t)$db->exec('create table '.$t.'(like public.'.$t.' including all)');
    $domain=uuid();$foreign=uuid();$owner=uuid();$actor=uuid();$tenant=uuid();$otherTenant=uuid();$rule=uuid();$rule2=uuid();$ext=uuid();$gateway=uuid();$service=uuid();$foreignService=uuid();
    foreach([$domain,$foreign] as $d)$q('insert into v_domains(domain_uuid,domain_name,domain_enabled) values(?,?,true)',[$d,$d.'.invalid']);
    $q('insert into v_users(user_uuid,domain_uuid,username,user_enabled) values(?,?,?,true),(?,?,?,true)',[$owner,$domain,'fixture-owner',$actor,$foreign,'foreign-owner']);
    $q("insert into v_pbx_tenants(tenant_uuid,tenant_name,owner_user_uuid,home_domain_uuid,enabled,slug,invite_email) values(?,?,?,?,true,'owned','owned@example.invalid'),(?,?,?,?,true,'foreign','foreign@example.invalid')",[$tenant,'Owned',$owner,$domain,$otherTenant,'Foreign',$actor,$foreign]);
    $q('insert into v_extensions(extension_uuid,domain_uuid,extension,enabled,password) values(?,?,?,true,?)',[$ext,$domain,'1000','fixture-secret']);
    $q('insert into v_gateways(gateway_uuid,domain_uuid,gateway,enabled,password) values(?,?,?,true,?)',[$gateway,$domain,'Fixture provider','fixture-provider-secret']);
    $end=['type'=>'None','number'=>'','external'=>''];$c=['realm'=>$domain.'.invalid','timezone'=>'Africa/Johannesburg','default_hours'=>['type'=>'AllHours'],'users'=>['1000'=>['name'=>'Fictional User','enabled'=>true,'extension_uuid'=>$ext,'voicemail_enabled'=>true],'1001'=>['name'=>'Disabled User','enabled'=>false,'voicemail_enabled'=>false]],'ring_groups'=>[['number'=>'8000','name'=>'Fictional Group']],'receptionists'=>[['number'=>'8001','name'=>'Fictional Receptionist']],'queues'=>[],'scripts'=>[],'departments'=>[['number'=>'dept','name'=>'Office','hours'=>['type'=>'SpecificHours','periods'=>[['day'=>3,'start'=>'08:00','end'=>'17:00']]],'members'=>[['number'=>'1000','primary'=>true]],'holidays'=>[['date'=>'2026-12-25']]]],'trunks'=>['provider'=>['enabled'=>true,'gateway_uuid'=>$gateway],'other'=>['enabled'=>false]],'inbound_rules'=>[['rule_id'=>$rule,'trunk_id'=>'provider','number'=>'+27110000001','condition'=>'BasedOnDID','hours'=>['type'=>'OfficeHours'],'office'=>['type'=>'Extension','number'=>'1000','external'=>''],'outside'=>$end,'holiday'=>$end,'use_outside'=>true,'use_holiday'=>true,'enabled'=>true],['rule_id'=>$rule2,'trunk_id'=>'other','number'=>'+27110000002','office'=>$end,'hours'=>['type'=>'AllHours'],'enabled'=>false]]];
    $q("insert into v_pbx_restore(domain_uuid,source_version,config) values(?,'Fixture',?::jsonb),(?,'Fixture','{}')",[$domain,json_encode($c),$foreign]);
    $q("insert into v_pbx_cmb_services(service_uuid,domain_uuid,name,incoming_rule_uuid,route_owner,prompt_state,prompt_sha256) values(?,?,?,?,?,'ready',?),(?,?,?,?,?,'ready',?)",[$service,$domain,'Fictional Company',$rule,'1000',str_repeat('a',64),$foreignService,$foreign,'Foreign',uuid(),'1000',str_repeat('a',64)]);
    $_SESSION=['authorized'=>true,'domain_uuid'=>$domain,'user_uuid'=>$owner,'permissions'=>['pbx_service_create'=>true],'user'=>['domain_uuid'=>$domain]];
    $routes=new pbx_trunk_routes($db);
    $input=static function(array $override=[])use($routes,$rule){$s=$routes->snapshot('provider')['rules'][0];return array_replace(['incoming_rule'=>$rule,'route_revision'=>$s['revision'],'office'=>'keep','outside'=>'keep','holiday'=>'keep','office_department'=>'','use_outside'=>'1','use_holiday'=>'1'],$override);};
    $read=static fn()=>json_decode($q('select config from v_pbx_restore where domain_uuid=?',[$domain])->fetchColumn(),true);
    $native=$q('select * from v_gateways')->fetchAll(PDO::FETCH_ASSOC);$phones=$q('select * from v_extensions')->fetchAll(PDO::FETCH_ASSOC);
    $snapshot=$routes->snapshot('provider');$ok(count($snapshot['rules'])===1&&$snapshot['rules'][0]['callback']['service_uuid']===$service,'Trunk or callback leaked across ownership');
    foreach(['Extension:1000'=>['Extension','1000'],'RingGroup:8000'=>['RingGroup','8000'],'IVR:8001'=>['IVR','8001']] as $value=>[$kind,$n]){$before=$read();$routes->save('provider',$input(['office'=>$value]));$after=$read();$expected=$before;$expected['inbound_rules'][0]['office']=['type'=>$kind,'number'=>$n,'external'=>''];$ok($after===$expected,'A destination save changed another field');}
    foreach(['RingGroup:foreign','IVR:foreign','Extension:9999','Extension:1001','CallMeBack:'.$foreignService,'CallMeBack:bad'] as $value){$before=$read();$reject(fn()=>$routes->save('provider',$input(['office'=>$value,'confirm_callback'=>'1'])),'Invalid or foreign destination accepted');$ok($read()===$before,'Rejected destination changed configuration');}
    $bad=$input(['incoming_rule'=>$rule2]);$reject(fn()=>$routes->save('provider',$bad),'Another trunk rule accepted');
    $reject(fn()=>$routes->snapshot('foreign'),'Unknown trunk accepted');
    $old=$input();$routes->save('provider',$input(['office'=>'Extension:1000']));$reject(fn()=>$routes->save('provider',$old),'Stale route overwrote newer selection');
    $routes->save('provider',$input(['office'=>'RingGroup:8000','outside'=>'IVR:8001','holiday'=>'Extension:1000','office_department'=>'dept']));$saved=$read()['inbound_rules'][0];
    $ok($saved['outside']['type']==='IVR'&&$saved['holiday']['type']==='Extension'&&$saved['office_department']==='dept','Closed or holiday destination lost');
    $reject(fn()=>$routes->save('provider',$input(['office_department'=>'foreign'])),'Foreign department accepted');
    $reject(fn()=>$routes->save('provider',$input(['office'=>['Extension:1000']])),'Array destination accepted');
    $reject(fn()=>$routes->save('provider',$input(['use_outside'=>'false'])),'Malformed flag accepted');
    $reject(fn()=>$routes->save('provider',$input(['office'=>'External:','office_external'=>'${bad}'])),'Unsafe outside number accepted');
    $before=$read();$reject(fn()=>$routes->save('provider',$input(['office'=>'CallMeBack:'.$service])),'Callback activated without handover confirmation');$ok($read()===$before,'Rejected callback changed normal destinations');
    $routes->save('provider',$input(['office'=>'CallMeBack:'.$service,'confirm_callback'=>'1']));$ok($read()===$before,'Callback activation rewrote fallback routes');
    $s=$routes->snapshot('provider')['rules'][0];$ok($s['current']['slot']==='callback'&&$s['callback']['enabled'],'Active callback not shown as current destination');
    $reject(fn()=>$routes->save('provider',$input(['office'=>'Extension:1000'])),'Callback disabled without confirmation');
    $q('update v_extensions set enabled=false where extension_uuid=?',[$ext]);
    $routes->save('provider',$input(['office'=>'Extension:1000','confirm_callback'=>'1']));$ok(!$routes->snapshot('provider')['rules'][0]['callback']['enabled'],'Callback could not be disabled after its calling user became unavailable');
    $q('update v_extensions set enabled=true where extension_uuid=?',[$ext]);
    $q("update v_pbx_cmb_services set prompt_state='pending' where service_uuid=?",[$service]);$reject(fn()=>$routes->save('provider',$input(['office'=>'CallMeBack:'.$service,'confirm_callback'=>'1'])),'Callback with unready prompt enabled');
    $q("update v_pbx_cmb_services set prompt_state='ready' where service_uuid=?",[$service]);
    $disabled=$read();$disabled['trunks']['provider']['enabled']=false;$q('update v_pbx_restore set config=?::jsonb where domain_uuid=?',[json_encode($disabled),$domain]);
    $reject(fn()=>$routes->save('provider',$input(['office'=>'CallMeBack:'.$service,'confirm_callback'=>'1'])),'Callback on disconnected provider enabled');
    $routes->save('provider',$input(['office'=>'IVR:8001']));$ok(!$read()['trunks']['provider']['enabled'],'Editing offline route enabled provider');
    $ok($q('select * from v_gateways')->fetchAll(PDO::FETCH_ASSOC)===$native&&$q('select * from v_extensions')->fetchAll(PDO::FETCH_ASSOC)===$phones,'Native provider or phone changed');
    $ok($q('select config::text from v_pbx_restore where domain_uuid=?',[$foreign])->fetchColumn()==='{}','Foreign configuration changed');
    $ok((int)$q("select count(*) from v_pbx_cmb_audit where action in ('trunk_route_enable','trunk_route_disable')")->fetchColumn()===2,'Callback handover audit missing');
    $ok((int)$q('select count(*) from v_pbx_staff_audit')->fetchColumn()===8,'Routing success audit missing or rejected save audited as accepted');
    $clock=static fn($time)=>(new DateTimeImmutable($time,new DateTimeZone('Africa/Johannesburg')))->getTimestamp();
    $r=$saved;$ok(pbx_trunk_routes::current($r,$c,$clock('2026-10-21 10:00'))['slot']==='office','Open-hour preview differs');
    $ok(pbx_trunk_routes::current($r,$c,$clock('2026-10-21 20:00'))['slot']==='outside','Closed-hour preview differs');
    $ok(pbx_trunk_routes::current($r,$c,$clock('2026-12-25 10:00'))['slot']==='holiday','Holiday precedence differs');
    $c['departments'][0]['office_override']=['state'=>'open','expires'=>$clock('2026-12-26 00:00')];$ok(pbx_trunk_routes::current($r,$c,$clock('2026-12-25 10:00'))['slot']==='office','Override preview differs');
    unset($r['office_department']);$r['office']=['type'=>'RingGroup','number'=>'8000'];$c['default_hours']=['type'=>'SpecificHours','periods'=>[]];$ok(pbx_trunk_routes::current($r,$c,$clock('2026-10-21 10:00'))['slot']==='outside','PBX default hours ignored without a department');
    $_SESSION['user_uuid']=$actor;$reject(fn()=>new pbx_trunk_routes($db),'Foreign tenant actor allowed');$_SESSION['user_uuid']=$owner;
    $q('update v_pbx_tenants set enabled=false where tenant_uuid=?',[$tenant]);$reject(fn()=>$routes->snapshot('provider'),'Suspended tenant allowed');
    echo json_encode(['checks'=>$checks,'isolated_postgresql'=>true,'no_engine_or_customer_calls'=>true,'gateway_and_phone_preservation'=>true],JSON_PRETTY_PRINT).PHP_EOL;
}finally{if($db->inTransaction())$db->rollBack();$db->exec('set search_path to public');$db->exec('drop schema if exists '.$schema.' cascade');$_SESSION=$prior;}
