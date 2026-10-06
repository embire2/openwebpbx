<?php
/** CLI-only PostgreSQL integration checks. An isolated schema contains every fixture. */
if (PHP_SAPI !== 'cli') { http_response_code(404); exit; }
require dirname(__DIR__).'/resources/require.php';
require_once dirname(__DIR__).'/resources/classes/pbx_setup_provisioner.php';
$db = $database->db;
$db->setAttribute(PDO::ATTR_ERRMODE, PDO::ERRMODE_EXCEPTION);
$schema = 'openweb_setup_test_'.bin2hex(random_bytes(6));
$query = function(string $sql, array $params = []) use ($db): PDOStatement {
    $statement = $db->prepare($sql); $statement->execute($params); return $statement;
};
$assert = function(bool $condition, string $message): void { if (!$condition) throw new RuntimeException($message); };
$reject = function(callable $callback, string $message) use ($assert): void {
    try { $callback(); } catch (InvalidArgumentException|RuntimeException|LogicException $error) { return; }
    $assert(false, $message);
};
$plan = [
    'users'=>[
        ['number'=>'100','name'=>'Alice Example','email'=>'alice@example.invalid','auth_id'=>'alice100','password'=>'Fixture-SIP-password-100','voicemail_pin'=>'001234','enabled'=>true],
        ['number'=>'101','name'=>'Bob Example','email'=>'','auth_id'=>'101','password'=>'','voicemail_pin'=>'','enabled'=>false]
    ],
    'trunks'=>[
        ['source_id'=>'provider1','name'=>'Example provider','host'=>'sip.example.invalid','port'=>5060,'transport'=>'udp','username'=>'fixtureuser','password'=>'Fixture-trunk-password','register'=>true,'enabled'=>true],
        ['source_id'=>'provider2','name'=>'Example IP provider','host'=>'2001:db8::1','port'=>5061,'transport'=>'tls','username'=>'','password'=>'','register'=>false,'enabled'=>true]
    ],
    'ring_groups'=>[['number'=>'800','name'=>'Sales','strategy'=>'sequence','members'=>['100','101'],'timeout'=>30]],
    'inbound_rules'=>[
        ['number'=>'+27112345678','name'=>'Main number','destination_type'=>'ring_group','destination'=>'800','trunk_id'=>'provider1'],
        ['number'=>'+27112345679','name'=>'Voicemail number','destination_type'=>'voicemail','destination'=>'100','trunk_id'=>'provider1']
    ],
    'outbound_rules'=>[['name'=>'National calls','prefix'=>'0','lengths'=>[10],'strip'=>1,'prepend'=>'+27','trunk_id'=>'provider1']]
];
try {
    $db->exec('create schema '.$schema); $db->exec('set search_path to '.$schema.',public');
    $tables = ['v_domains','v_extensions','v_voicemails','v_gateways','v_ring_groups','v_ring_group_destinations','v_destinations','v_dialplans','v_dialplan_details'];
    foreach ($tables as $table) $db->exec('create table '.$table.' (like public.'.$table.' including all)');
    $domains = [];
    foreach (['alpha','beta','rejected'] as $label) {
        $domains[$label] = uuid();
        $query('insert into v_domains(domain_uuid,domain_name,domain_enabled) values(:id,:name,true)', ['id'=>$domains[$label],'name'=>$label.'.example.invalid']);
    }
    $provisioner = new pbx_setup_provisioner($db);
    $normalized = $provisioner->validate($plan);
    $assert($normalized['trunks'][1]['host'] === '[2001:db8::1]', 'IPv6 gateway address was not normalized');
    $reject(fn()=>$provisioner->apply($domains['alpha'],'alpha.example.invalid',$plan), 'Provisioning ran outside a transaction');
    $cases = [
        'duplicate extension'=>function($p){$p['users'][1]['number']='100';return $p;},
        'duplicate authentication ID'=>function($p){$p['users'][1]['auth_id']='alice100';return $p;},
        'authentication alias collision'=>function($p){$p['users'][0]['auth_id']='101';return $p;},
        'foreign ring group member'=>function($p){$p['ring_groups'][0]['members']=['999'];return $p;},
        'unmapped strategy'=>function($p){$p['ring_groups'][0]['strategy']='hunt-random';return $p;},
        'foreign inbound destination'=>function($p){$p['inbound_rules'][0]['destination']='801';return $p;},
        'foreign inbound trunk'=>function($p){$p['inbound_rules'][0]['trunk_id']='foreign';return $p;},
        'unsupported schedule'=>function($p){$p['inbound_rules'][0]['office_hours']=['09:00-17:00'];return $p;},
        'unsupported configuration section'=>function($p){$p['queues']=[['number'=>'900']];return $p;},
        'unsupported outbound restriction'=>function($p){$p['outbound_rules'][0]['extensions']=['100'];return $p;},
        'foreign outbound trunk'=>function($p){$p['outbound_rules'][0]['trunk_id']='foreign';return $p;},
        'unrestricted outbound catchall'=>function($p){$p['outbound_rules'][0]['prefix']='';$p['outbound_rules'][0]['lengths']=[];return $p;},
        'oversized strip'=>function($p){$p['outbound_rules'][0]['strip']=10;return $p;},
        'regex injection'=>function($p){$p['outbound_rules'][0]['prefix']='0.*';return $p;},
        'context injection'=>function($p){$p['users'][0]['user_context']='foreign.example.invalid';return $p;},
        'invalid enable status'=>function($p){$p['users'][0]['enabled']='yes';return $p;},
        'unsafe SIP credential'=>function($p){$p['users'][0]['password']='unsafe"<xml>';return $p;},
        'invalid SIP host'=>function($p){$p['trunks'][0]['host']='sip.invalid/../../';return $p;}
    ];
    foreach ($cases as $name=>$mutate) $reject(fn()=>$provisioner->validate($mutate($plan)), 'Accepted '.$name);
    $db->beginTransaction();
    $invalid = $plan; $invalid['outbound_rules'][0]['trunk_id']='foreign';
    $reject(fn()=>$provisioner->apply($domains['rejected'],'rejected.example.invalid',$invalid), 'Invalid last record was accepted');
    $assert((int)$db->query('select count(*) from v_extensions')->fetchColumn() === 0, 'Validation inserted earlier records before rejecting a later record');
    $reject(fn()=>$provisioner->apply($domains['alpha'],'beta.example.invalid',$plan), 'Mismatched domain UUID/name was accepted');
    $result = $provisioner->apply($domains['alpha'],'alpha.example.invalid',$plan);
    $assert($db->inTransaction(), 'Mapper committed its caller transaction');
    $assert($result['counts'] === ['users'=>2,'voicemails'=>2,'trunks'=>2,'ring_groups'=>1,'inbound_rules'=>2,'outbound_rules'=>1], 'Provisioned record counts differ');
    $assert(count($result['warnings']) === 5, 'Generated credentials, alias reprovisioning or disabled carrier warnings are missing');
    $assert(!str_contains(json_encode($result), 'Fixture-'), 'Returned metadata disclosed credentials');
    $extension = $query("select * from v_extensions where domain_uuid=:domain and number_alias='100'", ['domain'=>$domains['alpha']])->fetch(PDO::FETCH_ASSOC);
    $assert($extension['extension']==='alice100' && $extension['password']==='Fixture-SIP-password-100', 'SIP ID and password were not preserved');
    $assert($extension['user_context']==='alpha.example.invalid' && $extension['dial_domain']==='alpha.example.invalid', 'Extension context escaped its PBX domain');
    $voicemail = $query("select * from v_voicemails where domain_uuid=:domain and voicemail_id='100'", ['domain'=>$domains['alpha']])->fetch(PDO::FETCH_ASSOC);
    $assert($voicemail['voicemail_password']==='001234' && $voicemail['voicemail_mail_to']==='alice@example.invalid', 'Voicemail PIN/email were not preserved');
    $generated = $query("select password from v_extensions where domain_uuid=:domain and extension='101'", ['domain'=>$domains['alpha']])->fetchColumn();
    $assert(strlen($generated) >= 32 && $generated!==$extension['password'], 'Missing SIP password was not replaced with a unique secret');
    $assert(!(bool)$query('select bool_or(enabled) from v_gateways where domain_uuid=:domain', ['domain'=>$domains['alpha']])->fetchColumn(), 'An imported gateway was enabled');
    $assert(!(bool)$query('select bool_or(destination_enabled) from v_destinations where domain_uuid=:domain', ['domain'=>$domains['alpha']])->fetchColumn(), 'An imported DID was enabled');
    $assert(!(bool)$query("select 1 from v_dialplans where dialplan_context='public' limit 1")->fetchColumn(), 'Import created a shared public-context dialplan');
    $assert((int)$query('select count(*) from v_gateways where domain_uuid=:domain and context=:context', ['domain'=>$domains['alpha'],'context'=>'ingress@alpha.example.invalid'])->fetchColumn()===2, 'Gateway ingress includes the internal PBX context');
    $assert((int)$query('select count(*) from v_destinations where domain_uuid=:domain and destination_context=:context', ['domain'=>$domains['alpha'],'context'=>'ingress@alpha.example.invalid'])->fetchColumn()===2, 'DID ingress includes the internal PBX context');
    $deny = $query("select dialplan_xml from v_dialplans where domain_uuid=:domain and dialplan_name='Reject unconfigured incoming calls' and dialplan_enabled=true", ['domain'=>$domains['alpha']])->fetchColumn();
    $assert(str_contains($deny,'UNALLOCATED_NUMBER') && !str_contains($deny,'transfer'), 'Unconfigured incoming calls do not have a deny fallback');
    $outbound = $query("select * from v_dialplans where domain_uuid=:domain and dialplan_name='National calls'", ['domain'=>$domains['alpha']])->fetch(PDO::FETCH_ASSOC);
    $assert($outbound['app_uuid']==='8c914ec3-9fc0-8ab5-4cda-6c9288bdc9a3', 'Outbound rule is hidden from the native Outbound Routes page');
    $assert((int)$query('select count(*) from v_dialplans where domain_uuid=:domain and app_uuid=:app', ['domain'=>$domains['alpha'],'app'=>'c03b422e-13a8-bd1b-e42b-b6b9b4d27ce4'])->fetchColumn()===2, 'Inbound rules are hidden from the native Inbound Routes page');
    $document = new DOMDocument(); $assert($document->loadXML($outbound['dialplan_xml']), 'Outbound XML is invalid');
    $xpath = new DOMXPath($document);
    $pattern = $xpath->evaluate('string(/extension/condition/@expression)');
    $assert(preg_match('~'.$pattern.'~','0112345678',$matched) === 1 && $matched[1]==='112345678', 'Outbound prefix/strip mapping changed the intended number');
    foreach (['1112345678','011234567','01123456789','0abc234567'] as $number) $assert(preg_match('~'.$pattern.'~',$number) === 0, 'Outbound expression matched an unintended number');
    $bridge = $xpath->evaluate('string(/extension/condition/action[@application="bridge"]/@data)');
    $assert(str_ends_with($bridge,'/+27$1'), 'Outbound prepend mapping was lost');
    $destinations = $query('select destination_number,destination_delay from v_ring_group_destinations where domain_uuid=:domain order by destination_delay', ['domain'=>$domains['alpha']])->fetchAll(PDO::FETCH_ASSOC);
    $assert(array_column($destinations,'destination_number') === ['100','101'], 'Ring group member ordering or aliases were changed');
    $reject(fn()=>$provisioner->apply($domains['alpha'],'alpha.example.invalid',$plan), 'Import modified a nonempty PBX');
    $second = $provisioner->apply($domains['beta'],'beta.example.invalid',$plan);
    $assert($second['counts']===$result['counts'], 'Identical numbers could not be provisioned in a second isolated domain');
    $gatewayA = $query('select gateway_uuid from v_gateways where domain_uuid=:domain and gateway=:name', ['domain'=>$domains['alpha'],'name'=>'Example provider'])->fetchColumn();
    $assert(!(bool)$query('select 1 from v_dialplan_details where domain_uuid=:domain and dialplan_detail_data like :gateway', ['domain'=>$domains['beta'],'gateway'=>'%'.$gatewayA.'%'])->fetchColumn(), 'Another PBX dialplan references a foreign gateway');
    $assert(!(bool)$query('select 1 from v_dialplan_details where domain_uuid=:domain and dialplan_detail_data like :foreign', ['domain'=>$domains['beta'],'foreign'=>'%alpha.example.invalid%'])->fetchColumn(), 'Another PBX dialplan references a foreign realm');
    $db->rollBack();
    foreach ($tables as $table) if ($table!=='v_domains') $assert((int)$db->query('select count(*) from '.$table)->fetchColumn()===0, 'Transaction rollback left '.$table.' records');
    echo "PASS: complete validation before writes; native SIP IDs/aliases/secrets and voicemail preservation; domain isolation; disabled gateways/private DID routes; outbound prefix/length/strip mapping; ring group membership; metadata redaction; nonempty-domain rejection; caller-owned atomic rollback.\n";
} finally {
    if ($db->inTransaction()) $db->rollBack();
    $db->exec('set search_path to public');
    $db->exec('drop schema if exists '.$schema.' cascade');
}
