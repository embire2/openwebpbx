<?php
/** Execute native handler SQL in a disposable schema, then exercise its Lua renderer. */
if(PHP_SAPI!=='cli'){http_response_code(404);exit;}
require dirname(__DIR__).'/resources/require.php';
$db=$database->db;$db->setAttribute(PDO::ATTR_ERRMODE,PDO::ERRMODE_EXCEPTION);
$schema='openweb_xml_test_'.bin2hex(random_bytes(6));$checks=0;$jsonFile=null;
$check=static function(bool $ok,string $message)use(&$checks){if(!$ok)throw new RuntimeException($message);$checks++;};
$query=static function(string $sql,array $params=[])use($db){$s=$db->prepare($sql);$s->execute($params);return $s;};
$root=dirname(__DIR__);
$dialplan=file_get_contents($root.'/app/switch/resources/scripts/app/xml_handler/resources/scripts/dialplan/dialplan.lua');
$acl=file_get_contents($root.'/app/switch/resources/scripts/app/xml_handler/resources/scripts/configuration/acl.conf.lua');
if(!preg_match('/incoming_db:query\(\[\[(.*?)\]\],\s*\{hostname=hostname\}/s',$dialplan,$match))throw new RuntimeException('Native incoming query was not found.');
$incomingSql=$match[1];
if(!preg_match('/local approved_sql\s*=\s*\[\[(.*?)\]\]/s',$acl,$match))throw new RuntimeException('Native approved-provider query was not found.');
$providerSql=$match[1];
try{
    $db->exec('create schema '.$schema);$db->exec('set search_path to '.$schema);
    foreach([
        'v_domains(domain_uuid uuid primary key,domain_name text,domain_enabled boolean)',
        'v_pbx_restore(domain_uuid uuid primary key,config jsonb)',
        'v_gateways(gateway_uuid uuid primary key,domain_uuid uuid,enabled boolean)',
        'v_dialplans(dialplan_uuid uuid primary key,domain_uuid uuid,dialplan_xml text,dialplan_context text,dialplan_enabled boolean,hostname text,dialplan_order integer)',
        'v_destinations(destination_uuid uuid primary key,domain_uuid uuid,dialplan_uuid uuid,destination_enabled boolean)',
        'v_pbx_tenants(tenant_uuid uuid primary key,enabled boolean)',
        'v_pbx_services(tenant_uuid uuid,domain_uuid uuid)',
    ] as $table)$db->exec('create table '.$table);
    $cases=['active-later','active-first','off-native-gateway','foreign-gateway','off-domain','suspended-tenant','off-incoming','off-trunk','off-dialplan','off-destination','foreign-destination','wrong-host','wrong-context','wrong-incoming-map','malformed-incoming','malformed-trunks','without-restore'];
    $expected=[];$addresses=[];
    foreach($cases as $index=>$case){
        $domain=uuid();$gateway=uuid();$plan=uuid();$rule=uuid();$realm='fixture-'.$case.'.example.invalid';$foreign=uuid();$ip='192.0.2.'.(30+$index);$addresses[$case]=$ip;
        $active=str_starts_with($case,'active-');
        $xml='<extension name="'.$case.'"><condition field="${sip_gateway}" expression="^(?:'.$gateway.')?$"/><condition field="${sip_network_ip}" expression="^192[.]0[.]2[.]10$"/><condition field="${sip_to_user}" expression="^12025550100$"><action application="lua" data="app.lua pbx_setup incoming '.$rule.'"/></condition></extension>';
        $query('insert into v_domains values(:d,:realm,:on)',['d'=>$domain,'realm'=>$realm,'on'=>$case==='off-domain'?'false':'true']);
        $query('insert into v_gateways values(:g,:d,:on)',['g'=>$gateway,'d'=>$case==='foreign-gateway'?$foreign:$domain,'on'=>$case==='off-native-gateway'?'false':'true']);
        $query('insert into v_dialplans values(:id,:d,:xml,:context,:on,:host,:position)',['id'=>$plan,'d'=>$domain,'xml'=>$xml,'context'=>$case==='wrong-context'?'public':'ingress@'.$realm,'on'=>$case==='off-dialplan'?'false':'true','host'=>$case==='wrong-host'?'other-host':null,'position'=>$case==='active-first'?10:20+$index]);
        $query('insert into v_destinations values(:id,:d,:plan,:on)',['id'=>uuid(),'d'=>$case==='foreign-destination'?$foreign:$domain,'plan'=>$plan,'on'=>$case==='off-destination'?'false':'true']);
        $trunk=['gateway_uuid'=>$gateway,'enabled'=>$case!=='off-trunk','allowed_ips'=>[$ip]];
        if($active)$trunk['allowed_ips']=['192.0.2.10','2001:db8::10','::ffff:192.0.2.10','300.1.2.3','192.0.2.10/0','0.0.0.0/0','192.0.2.10"/><node type="allow" cidr="0.0.0.0/0','::::','abcd:','1::2::3','1:2:3:4:5:6:7','1:2:3:4:5:6:7:8:9','12345::1','1:2:3:4:5:6:7:8::','::ffff:999.0.0.1','::ffff:192.0.2.01','192.000.2.10'];
        $config=['trunks'=>['fixture'=>$trunk],'inbound_rules'=>[['trunk_id'=>'fixture','dialplan_uuid'=>$case==='wrong-incoming-map'?uuid():$plan,'enabled'=>$case!=='off-incoming']]];
        if($case==='malformed-incoming')$config['inbound_rules']=['bad'=>'shape'];
        if($case==='malformed-trunks')$config['trunks']=[['bad'=>'shape']];
        if($case!=='without-restore')$query('insert into v_pbx_restore values(:d,cast(:c as jsonb))',['d'=>$domain,'c'=>json_encode($config,JSON_THROW_ON_ERROR)]);
        if($case==='suspended-tenant'){$tenant=uuid();$query('insert into v_pbx_tenants values(:id,false)',['id'=>$tenant]);$query('insert into v_pbx_services values(:t,:d)',['t'=>$tenant,'d'=>$domain]);}
        if($active)$expected[$case]=$xml;
    }
    $rows=$query($incomingSql,['hostname'=>'fixture-host'])->fetchAll(PDO::FETCH_ASSOC);
    $check(count($rows)===2,'Disabled, foreign or malformed provider/tenant routes leaked into public fragments.');
    $check($rows[0]['dialplan_xml']===$expected['active-first']&&$rows[1]['dialplan_xml']===$expected['active-later'],'Incoming fragment order was not preserved.');
    foreach(array_slice($cases,2) as $case)$check(!str_contains(implode('',array_column($rows,'dialplan_xml')),'name="'.$case.'"'),'Inactive source included: '.$case);
    $providers=$query($providerSql)->fetchAll(PDO::FETCH_ASSOC);$ips=array_column($providers,'provider_ip');
    $check(in_array('192.0.2.10',$ips,true)&&in_array('2001:db8::10',$ips,true),'Active provider literals were not selected.');
    $check(count(array_filter($ips,static fn($ip)=>$ip==='192.0.2.10'))===1,'Provider addresses were not deduplicated.');
    foreach(['off-native-gateway','foreign-gateway','off-domain','suspended-tenant','off-trunk','malformed-trunks','without-restore'] as $case)$check(!in_array($addresses[$case],$ips,true),'Inactive provider was admitted by ACL query: '.$case);
    $check(in_array($addresses['off-incoming'],$ips,true),'Provider handshake authorization incorrectly depends on an incoming-number enable switch.');
    $jsonFile=tempnam(sys_get_temp_dir(),'openweb-xml-check-');if(!$jsonFile)throw new RuntimeException('Private fixture file unavailable.');chmod($jsonFile,0600);
    file_put_contents($jsonFile,json_encode(['incoming_rows'=>$rows,'provider_rows'=>$providers],JSON_THROW_ON_ERROR));
    $pipes=[];$process=proc_open(['lua',$root.'/tests/pbx_xml_routing.lua',$jsonFile],[0=>['pipe','r'],1=>['pipe','w'],2=>['pipe','w']],$pipes,$root);
    if(!is_resource($process))throw new RuntimeException('Lua renderer could not be started.');fclose($pipes[0]);$output=stream_get_contents($pipes[1]);$error=stream_get_contents($pipes[2]);fclose($pipes[1]);fclose($pipes[2]);$status=proc_close($process);
    $check($status===0,'Native Lua renderer failed: '.trim($error));echo trim($output)."\n";
    echo 'PASS: '.$checks." isolated PostgreSQL native ingress/provider selection checks\n";
}finally{
    if($jsonFile!==null)@unlink($jsonFile);$db->exec('set search_path to public');$db->exec('drop schema if exists '.$schema.' cascade');
}
