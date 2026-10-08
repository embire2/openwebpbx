<?php
/** Isolated PostgreSQL editor checks; private save methods avoid live reloads and SIP traffic. */
if(PHP_SAPI!=='cli'){http_response_code(404);exit;}
require dirname(__DIR__).'/resources/require.php';
$db=$database->db;$db->setAttribute(PDO::ATTR_ERRMODE,PDO::ERRMODE_EXCEPTION);
$schema='openweb_trunk_admin_test_'.bin2hex(random_bytes(6));$checks=0;
$assert=static function(bool $ok,string $message)use(&$checks){if(!$ok)throw new RuntimeException($message);$checks++;};
$q=static function(string $sql,array $params=[])use($db){$stmt=$db->prepare($sql);$stmt->execute($params);return $stmt;};
try{
    $db->exec('create schema '.$schema);$db->exec('set search_path to '.$schema.',public');
    foreach(['v_domains','v_gateways','v_dialplans','v_dialplan_details','v_destinations','v_pbx_restore'] as $table)$db->exec('create table '.$table.'(like public.'.$table.' including all)');
    $domain=uuid();$foreignDomain=uuid();$gateway=uuid();$foreignGateway=uuid();$dialplan=uuid();$rule=uuid();
    foreach([$domain,$foreignDomain] as $id)$q('insert into v_domains(domain_uuid,domain_name,domain_enabled) values(:id,:name,true)',['id'=>$id,'name'=>$id.'.example.invalid']);
    $native=['gateway_uuid'=>$gateway,'domain_uuid'=>$domain,'gateway'=>'Fixture provider','proxy'=>'provider.example.invalid:5061','username'=>'fixture-account','password'=>'private-fixture-password','auth_username'=>'fixture-digest','realm'=>'Fixture Realm','from_user'=>'fixture-from','from_domain'=>'from.example.invalid','register_proxy'=>'registrar.example.invalid:5061','outbound_proxy'=>'outbound.example.invalid:5061','register'=>'true','register_transport'=>'tls','expire_seconds'=>900,'channels'=>23,'codec_prefs'=>'PCMA,PCMU','extension'=>'fixture-contact','extension_in_contact'=>'true','caller_id_in_from'=>'true','sip_cid_type'=>'pid','enabled'=>'true','profile'=>'external'];
    $columns=array_keys($native);$q('insert into v_gateways('.implode(',',$columns).') values('.implode(',',array_map(static fn($key)=>':'.$key,$columns)).')',$native);
    $q("insert into v_gateways(gateway_uuid,domain_uuid,gateway,enabled) values(:id,:domain,'Foreign fixture',false)",['id'=>$foreignGateway,'domain'=>$foreignDomain]);
    $config=['realm'=>$domain.'.example.invalid','users'=>[],'trunks'=>['fixture'=>['number'=>'fixture','gateway_uuid'=>$gateway,'name'=>'Fixture provider','host'=>'provider.example.invalid','port'=>5061,'transport'=>'tls','register'=>true,'enabled'=>true,'allowed_ips'=>['198.51.100.10'],'main_number'=>'+27110000001','caller_id'=>'+27110000001','limit'=>23,'expires'=>900,'type'=>'Provider','headers'=>[]]],'inbound_rules'=>[['rule_id'=>$rule,'dialplan_uuid'=>$dialplan,'trunk_id'=>'fixture','condition'=>'BasedOnDID','number'=>'+27110000001','enabled'=>false,'office'=>['type'=>'None','number'=>'','external'=>''],'outside'=>['type'=>'None','number'=>'','external'=>''],'use_outside'=>false]],'outbound_rules'=>[]];
    $q('insert into v_dialplans(dialplan_uuid,domain_uuid,dialplan_name,dialplan_xml,dialplan_enabled) values(:id,:d,:name,:xml,false)',['id'=>$dialplan,'d'=>$domain,'name'=>'Fixture incoming','xml'=>'<extension><condition field="destination_number" expression="^.+$"><action application="lua" data="fixture"/></condition></extension>']);
    $q("insert into v_dialplan_details(dialplan_detail_uuid,domain_uuid,dialplan_uuid,dialplan_detail_tag,dialplan_detail_type,dialplan_detail_data) values(:id,:d,:dp,'condition','destination_number','^.+$')",['id'=>uuid(),'d'=>$domain,'dp'=>$dialplan]);
    $q('insert into v_destinations(destination_uuid,domain_uuid,dialplan_uuid,destination_enabled) values(:id,:d,:dp,false)',['id'=>$rule,'d'=>$domain,'dp'=>$dialplan]);
    $q("insert into v_pbx_restore(domain_uuid,source_version,config) values(:d,'Fixture',cast(:config as jsonb))",['d'=>$domain,'config'=>json_encode($config)]);
    $_SESSION=['authorized'=>true,'user_uuid'=>uuid(),'domain_uuid'=>$domain,'domain_name'=>$config['realm'],'user'=>['domain_uuid'=>$domain]];
    $admin=new pbx_admin($db);$save=new ReflectionMethod(pbx_admin::class,'saveTrunk');
    $input=['name'=>'Edited provider','host'=>'provider.example.invalid','authentication'=>'password','username'=>'fixture-account','allowed_ips'=>'198.51.100.10','enabled'=>'1'];
    $db->beginTransaction();$save->invokeArgs($admin,['fixture',$input,&$config]);
    $stored=$q('select * from v_gateways where gateway_uuid=:id',['id'=>$gateway])->fetch(PDO::FETCH_ASSOC);
    foreach(['password','auth_username','realm','from_user','from_domain','register_proxy','outbound_proxy','register_transport','expire_seconds','channels','codec_prefs','extension','extension_in_contact','caller_id_in_from','sip_cid_type','register','enabled'] as $field)$assert(in_array($field,['register','enabled','caller_id_in_from'],true)?filter_var($stored[$field],FILTER_VALIDATE_BOOLEAN)===filter_var($native[$field],FILTER_VALIDATE_BOOLEAN):(string)$stored[$field]===(string)$native[$field],'Omitted native trunk field changed: '.$field);
    $assert(!array_key_exists('password',$config['trunks']['fixture'])&&!array_key_exists('username',$config['trunks']['fixture']),'Provider credentials copied into routing policy');
    $xml=$q('select dialplan_xml from v_dialplans where dialplan_uuid=:id',['id'=>$dialplan])->fetchColumn();
    $doc=new DOMDocument;$doc->loadXML($xml);$conditions=$doc->getElementsByTagName('condition');$expression=$conditions[0]->getAttribute('expression');
    $assert($conditions[0]->getAttribute('field')==='${sip_gateway}'&&$conditions[1]->getAttribute('field')==='${sip_network_ip}'&&$conditions[2]->getAttribute('field')==='${sip_to_user}'&&preg_match('~'.$expression.'~',$gateway)===1&&preg_match('~'.$expression.'~','')===1&&preg_match('~'.$expression.'~',$foreignGateway)===0,'Provider gateway ownership was not checked before IP and DID selection');
    $bindings=$q("select dialplan_detail_data,dialplan_detail_order from v_dialplan_details where dialplan_uuid=:id and dialplan_detail_type='\${sip_gateway}'",['id'=>$dialplan])->fetchAll(PDO::FETCH_ASSOC);
    $assert(count($bindings)===1&&$bindings[0]['dialplan_detail_data']===$expression&&(int)$bindings[0]['dialplan_detail_order']===0,'Stored incoming provider binding was not synchronized');
    $assert(str_contains($xml,'${sip_to_user}')&&str_contains($xml,'${sip_network_ip}')&&str_contains($xml,'198\.51\.100\.10'),'Saved incoming To selector or source-IP gate missing');
    $input['register']='0';$input['transport']='tcp';$input['port']='5070';$input['source_field']='RequestLineURIUser';$input['expires']='1800';$input['limit']='15';
    $save->invokeArgs($admin,['fixture',$input,&$config]);
    $stored=$q('select * from v_gateways where gateway_uuid=:id',['id'=>$gateway])->fetch(PDO::FETCH_ASSOC);
    $assert(!$stored['register']&&$stored['password']==='private-fixture-password'&&$stored['auth_username']==='fixture-digest','Disabling registration discarded digest authentication');
    $assert($stored['register_transport']==='tcp'&&$stored['proxy']==='provider.example.invalid:5070'&&(int)$stored['expire_seconds']===1800&&(int)$stored['channels']===15,'Provider transport/port/expiry/limit did not round-trip');
    $xml=$q('select dialplan_xml from v_dialplans where dialplan_uuid=:id',['id'=>$dialplan])->fetchColumn();
    $detail=$q('select dialplan_detail_type from v_dialplan_details where dialplan_uuid=:id',['id'=>$dialplan])->fetchColumn();
    $assert(str_contains($xml,'${sip_req_user}')&&!str_contains($xml,'${sip_to_user}')&&$detail==='${sip_req_user}','Request URI selector was not synchronized in native conditions');
    $input['authentication']='ip';$save->invokeArgs($admin,['fixture',$input,&$config]);
    $stored=$q('select * from v_gateways where gateway_uuid=:id',['id'=>$gateway])->fetch(PDO::FETCH_ASSOC);
    $assert($stored['username']===''&&$stored['auth_username']===''&&$stored['password']===''&&!$stored['register'],'Explicit IP authentication retained digest credentials');
    $q('update v_gateways set sip_cid_type=null where gateway_uuid=:id',['id'=>$gateway]);unset($config['trunks']['fixture']['sip_cid_type']);
    $config['trunks']['fixture']['headers']['RemotePartyIDCallingPartyUserPart']='$OutboundCallerId';
    $save->invokeArgs($admin,['fixture',$input,&$config]);
    $assert($q('select sip_cid_type from v_gateways where gateway_uuid=:id',['id'=>$gateway])->fetchColumn()==='rpid'&&$config['trunks']['fixture']['sip_cid_type']==='rpid','Blank legacy caller-ID type did not use restored headers');
    $q("update v_gateways set sip_cid_type='' where gateway_uuid=:id",['id'=>$gateway]);$config['trunks']['fixture']['sip_cid_type']='';$config['trunks']['fixture']['headers']=[];
    $save->invokeArgs($admin,['fixture',$input,&$config]);
    $assert($q('select sip_cid_type from v_gateways where gateway_uuid=:id',['id'=>$gateway])->fetchColumn()==='none'&&$config['trunks']['fixture']['sip_cid_type']==='none','Blank legacy caller-ID type without headers was not normalized');
    $new=$save->invokeArgs($admin,['new',['name'=>'New fixture','host'=>'provider.example.invalid','authentication'=>'ip'],&$config]);
    $assert($config['trunks'][$new]['sip_cid_type']==='none'&&!$config['trunks'][$new]['enabled'],'New trunk did not get a safe caller-ID default');
    $q('delete from v_gateways where gateway_uuid=:id',['id'=>$config['trunks'][$new]['gateway_uuid']]);unset($config['trunks'][$new]);
    $assert((int)$q('select dialplan_order from v_dialplans where dialplan_uuid=:id',['id'=>$dialplan])->fetchColumn()===100&&(int)$q('select destination_order from v_destinations where destination_uuid=:id',['id'=>$rule])->fetchColumn()===100,'Specific number order was not synchronized');
    $incoming=new ReflectionMethod(pbx_admin::class,'saveIncoming');$ordered=$config;$ordered['inbound_rules'][0]['condition']='ForwardAll';$ordered['inbound_rules'][0]['number']='';
    $incoming->invokeArgs($admin,[$rule,[],&$ordered]);$xml=$q('select dialplan_xml from v_dialplans where dialplan_uuid=:id',['id'=>$dialplan])->fetchColumn();
    $assert((int)$q('select dialplan_order from v_dialplans where dialplan_uuid=:id',['id'=>$dialplan])->fetchColumn()===1000&&(int)$q('select destination_order from v_destinations where destination_uuid=:id',['id'=>$rule])->fetchColumn()===1000&&str_contains($xml,'27110000001')&&!str_contains($xml,'expression="^.+$"'),'Fallback ordering or declared-number restriction was lost');
    $ordered['inbound_rules'][0]['condition']='BasedOnDID';$ordered['inbound_rules'][0]['number']='*001';$incoming->invokeArgs($admin,[$rule,[],&$ordered]);
    $assert((int)$q('select dialplan_order from v_dialplans where dialplan_uuid=:id',['id'=>$dialplan])->fetchColumn()===500&&(int)$q('select destination_order from v_destinations where destination_uuid=:id',['id'=>$rule])->fetchColumn()===500,'Suffix number order was not synchronized');
    $incoming->invokeArgs($admin,[$rule,[],&$config]);
    $binding=new ReflectionMethod(pbx_admin::class,'checkIncomingBinding');$own=$config;$own['inbound_rules'][0]['enabled']=true;
    $fallback=$own['inbound_rules'][0];$fallback['rule_id']=uuid();$fallback['condition']='ForwardAll';$fallback['number']='';
    $binding->invoke($admin,$fallback,$own['trunks']['fixture'],$own);$assert(true,'Same-trunk fallback should follow its specific number');
    $duplicate=$own['inbound_rules'][0];$duplicate['rule_id']=uuid();
    try{$binding->invoke($admin,$duplicate,$own['trunks']['fixture'],$own);throw new RuntimeException('Duplicate specific number was accepted');}catch(InvalidArgumentException){$assert(true,'Duplicate specific number denied');}
    $foreign=$own;$foreign['trunks']['fixture']['gateway_uuid']=$foreignGateway;$foreign['inbound_rules']=[$fallback];
    $q("insert into v_pbx_restore(domain_uuid,source_version,config) values(:d,'Fixture',cast(:config as jsonb))",['d'=>$foreignDomain,'config'=>json_encode($foreign)]);
    try{$binding->invoke($admin,$own['inbound_rules'][0],$own['trunks']['fixture'],$own);throw new RuntimeException('Foreign fallback stole a declared number');}catch(InvalidArgumentException){$assert(true,'Foreign fallback declared-number overlap denied');}
    $foreign['trunks']['fixture']['main_number']='+27199999999';$q('update v_pbx_restore set config=cast(:config as jsonb) where domain_uuid=:d',['d'=>$foreignDomain,'config'=>json_encode($foreign)]);
    $binding->invoke($admin,$own['inbound_rules'][0],$own['trunks']['fixture'],$own);$assert(true,'Unrelated foreign fallback number should not conflict');
    $foreign['trunks']['fixture']['dids']=['+27110000001'];$q('update v_pbx_restore set config=cast(:config as jsonb) where domain_uuid=:d',['d'=>$foreignDomain,'config'=>json_encode($foreign)]);
    $suffix=$own['inbound_rules'][0];$suffix['rule_id']=uuid();$suffix['number']='*001';
    try{$binding->invoke($admin,$suffix,$own['trunks']['fixture'],$config);throw new RuntimeException('Suffix number stole a later foreign declared DID');}catch(InvalidArgumentException){$assert(true,'Suffix overlap with a later foreign declared number denied');}
    $q('delete from v_pbx_restore where domain_uuid=:d',['d'=>$foreignDomain]);
    $assert($q('select gateway from v_gateways where gateway_uuid=:id',['id'=>$foreignGateway])->fetchColumn()==='Foreign fixture','Foreign gateway was changed');
    $db->commit();
    $q('update v_pbx_restore set config=cast(:config as jsonb) where domain_uuid=:d',['config'=>json_encode($config),'d'=>$domain]);
    $readiness=$admin->trunkReadiness(false);
    $assert(count($readiness['trunks'])===1&&$readiness['counts']['incoming_off']===1&&!$readiness['calls_verified'],'Readiness escaped the active PBX or claimed carrier verification');
    try{$admin->checkTrunkProvider('foreign-key');throw new RuntimeException('Foreign provider check was accepted');}catch(InvalidArgumentException){$assert(true,'Foreign provider check denied');}
    echo 'PASS: '.$checks." isolated trunk preservation, independent digest/registration, native options, incoming selectors/IP checks and scoped readiness checks; no live reload or SIP traffic\n";
}finally{
    if($db->inTransaction())$db->rollBack();$db->exec('set search_path to public');$db->exec('drop schema if exists '.$schema.' cascade');
}
