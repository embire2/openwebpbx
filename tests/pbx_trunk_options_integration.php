<?php
/** Actual PostgreSQL isolation; no customer, phone, provider or engine write. */
if(PHP_SAPI!=='cli')exit(2);
function permission_exists($name): bool {return !empty($_SESSION['permissions'][$name]);}
require dirname(__DIR__).'/resources/require.php';
class fixture_trunk_options extends pbx_trunk_options {
    public array $commands=[];public bool $module=true;public int $calls=0;public bool $failRefresh=false;public int $clears=0;
    protected function clearGatewayCache(): void {$this->clears++;}
    protected function engine(string $command): string {$this->commands[]=$command;if($command==='module_exists mod_hash')return $this->module?'true':'false';if($command==='show channels as json')return json_encode(['row_count'=>$this->calls]);return $this->failRefresh?'-ERR fixture refusal':'+OK fixture refresh';}
}
$db=database::new()->db;$db->setAttribute(PDO::ATTR_ERRMODE,PDO::ERRMODE_EXCEPTION);$schema='trunk_options_'.bin2hex(random_bytes(6));$prior=$_SESSION??[];$checks=0;
$q=static function(string $sql,array $p=[])use($db){$s=$db->prepare($sql);$s->execute($p);return $s;};
$ok=static function(bool $v,string $m)use(&$checks){if(!$v)throw new RuntimeException($m);$checks++;};
$reject=static function(callable $f,string $m)use($ok){try{$f();}catch(InvalidArgumentException|RuntimeException){$ok(true,$m);return;}$ok(false,$m);};
try {
 $db->exec('create schema '.$schema);$db->exec('set search_path to '.$schema.',public');
 foreach(['v_domains','v_users','v_pbx_tenants','v_pbx_services','v_pbx_restore','v_extensions','v_gateways','v_pbx_staff_audit']as$t)$db->exec('create table '.$t.'(like public.'.$t.' including all)');
 $domain=uuid();$foreign=uuid();$owner=uuid();$other=uuid();$gateway=uuid();$foreignGateway=uuid();
 foreach([$domain,$foreign]as$d)$q('insert into v_domains(domain_uuid,domain_name,domain_enabled)values(?,?,true)',[$d,$d.'.invalid']);
 foreach([[$owner,$domain,'owner'],[$other,$foreign,'foreign']]as$r)$q('insert into v_users(user_uuid,domain_uuid,username,user_enabled)values(?,?,?,true)',$r);
 foreach([[$domain,$owner,'owned'],[$foreign,$other,'foreign']]as[$d,$u,$name])$q('insert into v_pbx_tenants(tenant_uuid,tenant_name,owner_user_uuid,home_domain_uuid,enabled,slug,invite_email)values(?,?,?,?,true,?,?)',[uuid(),$name,$u,$d,$name,$name.'@example.invalid']);
 foreach([[$gateway,$domain],[$foreignGateway,$foreign]]as[$g,$d])$q("insert into v_gateways(gateway_uuid,domain_uuid,gateway,enabled,password,username,profile,channels,register_transport,expire_seconds,outbound_proxy)values(?,?,?,true,'fixture-secret','fixture-auth','external','10','udp','180','')",[$g,$d,'Fixture']);
 $q("insert into v_extensions(extension_uuid,domain_uuid,extension,enabled,password)values(?,?,'1000',true,'fixture-phone-secret')",[uuid(),$domain]);
 $c=['realm'=>$domain.'.invalid','timezone'=>'UTC','users'=>['1000'=>['name'=>'Fixture','enabled'=>true]],'trunks'=>['fixture'=>['name'=>'Fixture','gateway_uuid'=>$gateway,'enabled'=>true,'transport'=>'udp','expires'=>180,'outbound_proxy'=>'','limit'=>10]],'departments'=>[['number'=>'d','name'=>'Department','members'=>[['number'=>'1000']]]],'inbound_rules'=>[['rule_id'=>uuid(),'trunk_id'=>'fixture','enabled'=>true,'office'=>['type'=>'Extension','number'=>'1000']]],'outbound_rules'=>[]];
 $q("insert into v_pbx_restore(domain_uuid,source_version,config)values(?,'Fixture',?::jsonb),(?,'Fixture','{}')",[$domain,json_encode($c),$foreign]);
 $_SESSION=['authorized'=>true,'domain_uuid'=>$domain,'user_uuid'=>$owner,'permissions'=>['pbx_service_create'=>true],'user'=>['domain_uuid'=>$domain]];
 $service=new fixture_trunk_options($db);
 $input=static function(array $changes=[])use($service){$s=$service->snapshot('fixture');return array_replace(['options_revision'=>$s['revision'],'scope_department'=>$s['options']['scope_department'],'allow_incoming'=>'1','allow_outgoing'=>'1','support_reinvite'=>'1','srtp_mode'=>$s['options']['srtp_mode'],'limit'=>(string)$s['trunk']['limit'],'transport'=>$s['native']['register_transport'],'expires'=>$s['native']['expire_seconds'],'outbound_proxy'=>$s['native']['outbound_proxy']??''],$changes);};
 $read=static fn()=>json_decode($q('select config from v_pbx_restore where domain_uuid=?',[$domain])->fetchColumn(),true);
 $native=static fn()=>$q('select * from v_gateways order by gateway_uuid')->fetchAll(PDO::FETCH_ASSOC);
 $phones=$q('select * from v_extensions')->fetchAll(PDO::FETCH_ASSOC);$initialNative=$native();
 $s=$service->snapshot('fixture');$ok($s['options']['support_reinvite']&&$s['options']['srtp_mode']==='inherit'&&$s['options']['allow_incoming']&&$s['options']['allow_outgoing'],'Legacy effective defaults changed');
 $ok(!array_key_exists('password',$s['native'])&&!array_key_exists('username',$s['native']),'Secret native values exposed');
 $before=$read();$service->save('fixture',$input());$after=$read();$expected=$before;$expected['trunks']['fixture']['options']=pbx_trunk_options::defaults($before['trunks']['fixture'],$s['native']);$ok($after==$expected,'Initial save altered other routing');$ok($native()===$initialNative,'Unchanged connection or credentials rewritten');$ok($service->commands===['module_exists mod_hash']&&$service->clears===0,'Policy save restarted provider');
 $old=$input();$service->save('fixture',$input(['scope_department'=>'d','srtp_mode'=>'required','limit'=>'3']));$r=$read();$ok($r['trunks']['fixture']['options']['scope_department']==='d'&&$r['trunks']['fixture']['options']['srtp_mode']==='required'&&$r['trunks']['fixture']['limit']===3,'Policy choices lost');
 $changed=$native();foreach($changed as &$row)if($row['gateway_uuid']===$gateway)$row['channels']='10';unset($row);$ok($changed===$initialNative,'Policy save altered native fields beyond capacity projection');$reject(fn()=>$service->save('fixture',$old),'Stale revision accepted');
 foreach([['scope_department'=>'foreign'],['limit'=>'0'],['limit'=>'1.2'],['limit'=>'10001'],['transport'=>'any'],['expires'=>'0'],['outbound_proxy'=>'sip:bad'],['outbound_proxy'=>'bad@example.invalid'],['outbound_proxy'=>'host:65536'],['outbound_proxy'=>'${bad}'],['srtp_mode'=>'bad'],['support_reinvite'=>'false'],['allow_incoming'=>['1']],['options_revision'=>str_repeat('0',64)]]as$bad){$before=$read();$beforeNative=$native();$reject(fn()=>$service->save('fixture',$input($bad)),'Malformed option accepted');$ok($before===$read()&&$beforeNative===$native(),'Rejected save changed data');}
 $before=$read();$service->module=false;$reject(fn()=>$service->save('fixture',$input()),'Missing native limit backend accepted');$ok($before===$read(),'Readiness refusal wrote config');$service->module=true;
 $reject(fn()=>$service->save('fixture',$input(['transport'=>'tcp'])),'Connection changed without explicit confirmation');
 $service->calls=1;$reject(fn()=>$service->save('fixture',$input(['transport'=>'tcp','confirm_connection'=>'1'])),'Busy connection refreshed');$service->calls=0;
 $commands=count($service->commands);$notice=$service->save('fixture',$input(['transport'=>'tcp','expires'=>'300','outbound_proxy'=>'proxy.example.invalid:5070','confirm_connection'=>'1']));$ok(str_contains($notice,'connection refreshed'),'Successful refresh not reported');
 $ok(array_slice($service->commands,$commands)===['show channels as json','module_exists mod_hash','show channels as json','sofia profile external killgw '.$gateway,'sofia profile external rescan'],'Refresh affected another gateway or global engine');
 $r=$read();$ok($r['trunks']['fixture']['transport']==='tcp'&&$r['trunks']['fixture']['expires']===300&&$r['trunks']['fixture']['outbound_proxy']==='proxy.example.invalid:5070'&&!$r['trunks']['fixture']['options']['connection_pending'],'Connection projection/pending state differs');
 $service->failRefresh=true;$notice=$service->save('fixture',$input(['expires'=>'301','confirm_connection'=>'1']));$ok(str_contains($notice,'still needs a refresh')&&$read()['trunks']['fixture']['options']['connection_pending'],'Refresh failure falsely reported ready');$service->failRefresh=false;
 $notice=$service->save('fixture',$input(['confirm_connection'=>'1']));$ok(str_contains($notice,'connection refreshed')&&!$read()['trunks']['fixture']['options']['connection_pending'],'Pending refresh cannot recover');
 $q('update v_gateways set enabled=false where gateway_uuid=?',[$gateway]);$count=count($service->commands);$service->save('fixture',$input(['transport'=>'tls','outbound_proxy'=>'[2001:db8::1]:5061']));$ok(array_slice($service->commands,$count)===['module_exists mod_hash'],'Disabled gateway was started');
 $ok(!filter_var($q('select enabled from v_gateways where gateway_uuid=?',[$gateway])->fetchColumn(),FILTER_VALIDATE_BOOLEAN),'Disabled provider enabled');
 $before=$read();$in=$input();unset($in['allow_incoming'],$in['allow_outgoing'],$in['support_reinvite']);$service->save('fixture',$in);$r=$read();$ok(!$r['trunks']['fixture']['options']['allow_incoming']&&!$r['trunks']['fixture']['options']['allow_outgoing']&&!$r['trunks']['fixture']['options']['support_reinvite'],'Unchecked controls not saved');$ok($r['inbound_rules']===$before['inbound_rules'],'Directions rewrote incoming rules');
 $ok($q('select * from v_extensions')->fetchAll(PDO::FETCH_ASSOC)===$phones,'Phone identities or passwords changed');
 $n=$native();foreach($n as &$row)if($row['gateway_uuid']===$gateway){foreach(['channels','register_transport','expire_seconds','outbound_proxy','enabled']as$field)foreach($initialNative as$original)if($original['gateway_uuid']===$gateway)$row[$field]=$original[$field];}unset($row);$ok($n===$initialNative,'Unselected native provider fields changed');
 $ok($q('select config::text from v_pbx_restore where domain_uuid=?',[$foreign])->fetchColumn()==='{}','Foreign tenant changed');
 $reject(fn()=>$service->snapshot('foreign'),'Foreign trunk visible');$_SESSION['user_uuid']=$other;$reject(fn()=>$service->snapshot('fixture'),'Changed actor retained access');$_SESSION['user_uuid']=$owner;
 $q('update v_gateways set outbound_proxy=? where gateway_uuid=?',['sip:legacy.example.invalid;transport=udp',$gateway]);$legacyNative=$native();$service->save('fixture',$input());$ok($native()===$legacyNative,'Unchanged legacy proxy was rewritten');
 $q('update v_users set user_enabled=false where user_uuid=?',[$owner]);$reject(fn()=>$service->save('fixture',$input()),'Disabled owner retained access');
 $ok((int)$q('select count(*) from v_pbx_staff_audit')->fetchColumn()===8,'Successful save audit missing or rejected change audited');
 echo json_encode(['checks'=>$checks,'actual_isolated_postgresql'=>true,'native_fields_preserved'=>true,'phone_credentials_preserved'=>true,'real_provider_or_engine_writes'=>false],JSON_PRETTY_PRINT).PHP_EOL;
} finally {if($db->inTransaction())$db->rollBack();$db->exec('set search_path to public');$db->exec('drop schema if exists '.$schema.' cascade');$_SESSION=$prior;}
