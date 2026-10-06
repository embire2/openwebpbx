<?php
/** CLI-only bounded parser tests. All sample values are invented and never contact a PBX. */
if (PHP_SAPI !== 'cli') { http_response_code(404); exit; }
require dirname(__DIR__).'/resources/classes/threecx_backup.php';
if (!class_exists('ZipArchive')) throw new RuntimeException('Install the PHP zip extension before running these tests.');
$dir=sys_get_temp_dir().'/openweb-3cx-parser-'.bin2hex(random_bytes(8));mkdir($dir,0700);
$checks=0;
function check(bool $ok,string $description): void { global $checks;if(!$ok)throw new RuntimeException('FAIL: '.$description);$checks++; }
function xmlFile(string $xml): string { global $dir;$file=$dir.'/'.bin2hex(random_bytes(5)).'.xml';file_put_contents($file,$xml);chmod($file,0600);return $file; }
function zipFile(array $entries,?callable $change=null): string {
    global $dir;$file=$dir.'/'.bin2hex(random_bytes(5)).'.zip';$z=new ZipArchive();$z->open($file,ZipArchive::CREATE);
    foreach($entries as $name=>$value)$z->addFromString($name,$value);
    if($change)$change($z);$z->close();chmod($file,0600);return $file;
}
function rejected(string $path,string $message): void { try { threecx_backup::analyze($path); }catch(InvalidArgumentException $e){check(true,$message);return;}throw new RuntimeException('FAIL: '.$message); }
function unsupported(array $plan,string $kind): bool { return in_array($kind,array_column($plan['unsupported'],'category'),true); }
function nativeFixture(string $version='16.0.1.273',string $extra=''): string {
    return '<?xml version="1.0" encoding="UTF-8"?><PhoneSystem><header><version>'.$version.'</version></header>
        <Gateways><VoipProvider><Name>Example relay</Name><Host>sip.example.invalid</Host><Port>5060</Port><RequireRegistrationFor>InOutCalls</RequireRegistrationFor></VoipProvider></Gateways>
        <Tenants><Tenant><DN>
        <Extension><Number>100</Number><FirstName>Example</FirstName><LastName>User</LastName><EmailAddress>user@example.invalid</EmailAddress><AuthID>auth100</AuthID><AuthPassword>fixture-sip-secret</AuthPassword><VMPIN>7359</VMPIN><Enabled>True</Enabled></Extension>
        <Extension><Number>101</Number><FirstName>Second</FirstName><AuthID>101</AuthID><Enabled>False</Enabled></Extension>
        <ExternalLine><Number>10000</Number><Gateway>Example relay</Gateway><AuthID>fixture-trunk-user</AuthID><AuthPassword>fixture-trunk-secret</AuthPassword><DIDNumbers>+27115550001,+27115550002</DIDNumbers>
        <RoutingRules><ExternalLineRule><RuleConditionGroup><CallType Type="AllCalls"/><Condition Type="ForwardAll"/><Hours Type="OfficeHours"/></RuleConditionGroup><Destination><To>Extension</To><Internal DN="100"/></Destination></ExternalLineRule>
        <ExternalLineRule><RuleConditionGroup><CallType Type="AllCalls"/><Condition Type="ForwardAll"/><Hours Type="OutOfOfficeHours"/></RuleConditionGroup><Destination><To>Extension</To><Internal DN="100"/></Destination></ExternalLineRule></RoutingRules></ExternalLine>'.$extra.'</DN>
        <OutboundRules><OutboundRule><Name>Local calls</Name><Prefix>0</Prefix><NumberLengthRanges>10,11</NumberLengthRanges><OutboundRoutes><OutboundRoute><Gateway>Example relay</Gateway><StripDigits>1</StripDigits><Prepend>27</Prepend></OutboundRoute><OutboundRoute><Gateway/></OutboundRoute></OutboundRoutes></OutboundRule></OutboundRules>
        </Tenant></Tenants></PhoneSystem>';
}
try {
    $native=nativeFixture();$p=threecx_backup::analyze(xmlFile($native));
    check($p['supported'] && $p['source_version']==='16.0.1.273' && $p['source_format']==='3cx-native-xml','known native v16 envelope recognized');
    check(count($p['users'])===2 && $p['users'][0]['auth_id']==='auth100' && $p['users'][0]['password']==='fixture-sip-secret' && $p['users'][1]['enabled']===false,'native user identifiers, secrets and enabled state privately normalized');
    check($p['trunks'][0]['source_id']==='10000' && $p['trunks'][0]['register'] && !$p['trunks'][0]['enabled'],'trunk provider joins to source line and remains disabled');
    check(count($p['inbound_rules'])===2 && $p['inbound_rules'][0]['trunk_id']==='10000' && $p['inbound_rules'][0]['destination']==='100','identical office-hours pair safely maps exact DIDs');
    check($p['outbound_rules'][0]['lengths']===[10,11] && $p['outbound_rules'][0]['strip']===1 && $p['outbound_rules'][0]['trunk_id']==='10000','single outbound route normalized');
    check(count($p['warnings'])>=2,'missing endpoint credentials and changed PBX identity are reported');
    $json=json_encode(threecx_backup::preview($p));
    foreach(['fixture-sip-secret','fixture-trunk-secret','fixture-trunk-user','auth100','7359'] as $secret)check(!str_contains($json,$secret),'preview omits a credential value');
    check(threecx_backup::preview($p)['counts']['users']===2 && threecx_backup::preview($p)['users'][0]['has_password'],'preview exposes only secret presence');
    $p=threecx_backup::analyze(zipFile(['123456Db.xml'=>$native,'Recordings/example.wav'=>'invented local attachment']));
    check($p['source_format']==='3cx-native-zip' && unsupported($p,'recordings'),'native ZIP loaded in memory and audio attachment reported');
    check(threecx_backup::analyze(xmlFile(nativeFixture('14.0.0.0')))['supported'],'verified v14 core layout recognized');
    foreach(['18.0.9.35','20.0.0.1','17.1.0.0','99.0.0.0','16.unknown','14.x'] as $version){$p=threecx_backup::analyze(xmlFile(nativeFixture($version)));check(!$p['supported'] && unsupported($p,'source_version'),'unverified source version fails closed');}
    $p=threecx_backup::analyze(xmlFile('<PhoneSystem><header><version>16.0.1.273</version></header><Tenants><Tenant><Extensions/></Tenant></Tenants></PhoneSystem>'));
    check(!$p['supported'] && unsupported($p,'database_layout'),'unknown native layout does not claim success');
    $p=threecx_backup::analyze(xmlFile('<Anything><Number>100</Number></Anything>'));
    check(!$p['supported'],'arbitrary XML not treated as a backup');
    $p=threecx_backup::analyze(xmlFile(nativeFixture('16.0.1.273','<RingGroup><Number>800</Number></RingGroup><Queue><Number>801</Number></Queue>')));
    check(unsupported($p,'special_extensions') && !$p['ring_groups'],'unknown ring group and queue structures explicitly reported');
    $p=threecx_backup::analyze(xmlFile(str_replace('<FirstName>Example</FirstName>','<FirstName>Example</FirstName><ForwardingRules><Rule/></ForwardingRules>',$native)));
    check(unsupported($p,'extension_behavior'),'forwarding behavior not silently discarded');
    $p=threecx_backup::analyze(xmlFile(str_replace('<Hours Type="OutOfOfficeHours"/>','<Hours Type="Weekend"/>',$native)));
    check(!$p['inbound_rules'] && unsupported($p,'inbound_schedules'),'unknown schedule never becomes unrestricted inbound routing');
    $p=threecx_backup::analyze(xmlFile(str_replace('<Internal DN="100"/></Destination></ExternalLineRule></RoutingRules>','<Internal DN="101"/></Destination></ExternalLineRule></RoutingRules>',$native)));
    check(!$p['inbound_rules'] && unsupported($p,'inbound_schedules'),'different night destination never becomes all-hours routing');
    $p=threecx_backup::analyze(xmlFile(str_replace('<Gateway/></OutboundRoute>','<Gateway>Example relay</Gateway></OutboundRoute>',$native)));
    check(!$p['outbound_rules'] && unsupported($p,'outbound_restrictions'),'failover route does not become a single simplified rule');
    $p=threecx_backup::analyze(xmlFile(str_replace('<Prefix>0</Prefix>','<DNRanges><DNRange><From>100</From><To>100</To></DNRange></DNRanges><Prefix>0</Prefix>',$native)));
    check(!$p['outbound_rules'] && unsupported($p,'outbound_restrictions'),'extension-restricted outbound rule is never broadened');
    $p=threecx_backup::analyze(xmlFile(str_replace('<Prefix>0</Prefix><NumberLengthRanges>10,11</NumberLengthRanges>','<Prefix/><NumberLengthRanges/>',$native)));
    check(!$p['outbound_rules'] && unsupported($p,'unrestricted_outbound'),'unrestricted outbound rule requires explicit manual policy');
    $p=threecx_backup::analyze(xmlFile(str_replace('<NumberLengthRanges>10,11</NumberLengthRanges>','<NumberLengthRanges>8-12</NumberLengthRanges>',$native)));
    check(!$p['outbound_rules'] && unsupported($p,'outbound_lengths'),'range syntax not guessed');
    $p=threecx_backup::analyze(xmlFile(str_replace('fixture-sip-secret','$2y$10$notaportableSIPsecret',$native)));
    check($p['users'][0]['password']==='' && unsupported($p,'extension_credentials'),'password hashes never used as SIP passwords');
    $p=threecx_backup::analyze(xmlFile(str_replace('fixture-sip-secret','fixture&amp;unsafe-secret',$native)));
    check($p['users'][0]['password']==='' && unsupported($p,'extension_credentials'),'credentials unsafe in the native directory regenerate with warning');
    $p=threecx_backup::analyze(xmlFile(str_replace('<NumberLengthRanges>10,11</NumberLengthRanges>','<NumberLengthRanges>1</NumberLengthRanges>',$native)));
    check(!$p['outbound_rules'] && unsupported($p,'outbound_lengths'),'one-digit outbound lengths are not accepted');
    $setup='<SetupConfig><tcxinit><option><code>InstallationType</code><answer>new</answer></option></tcxinit><extensions><extension><Number>200</Number><FirstName>Sample</FirstName><AuthID>200</AuthID><AuthPassword>setup-fixture-secret</AuthPassword></extension></extensions></SetupConfig>';
    $p=threecx_backup::analyze(xmlFile($setup));check($p['supported'] && $p['source_format']==='3cx-setupconfig-xml' && count($p['users'])===1,'documented SetupConfig distinctly labeled as an export');
    $p=threecx_backup::analyze(xmlFile(str_replace('<answer>new</answer>','<answer>restore</answer>',$setup)));
    check(!$p['supported'] && unsupported($p,'backup_reference'),'setup restore reference does not fetch an external backup');
    rejected(xmlFile('<!DOCTYPE PhoneSystem [<!ENTITY x SYSTEM "file:///etc/passwd">]><PhoneSystem>&x;</PhoneSystem>'),'external entities rejected');
    rejected(xmlFile('<!DOCTYPE r [<!ENTITY a "boom"><!ENTITY b "&a;&a;">]><r>&b;</r>'),'entity expansion rejected');
    rejected(xmlFile('<PhoneSystem><broken></PhoneSystem>'),'malformed XML rejected');
    rejected(xmlFile(str_repeat('<a>',34).str_repeat('</a>',34)),'deep XML rejected');
    rejected(xmlFile('<PhoneSystem xmlns="urn:other"><header/></PhoneSystem>'),'unknown namespaced schema rejected');
    rejected(xmlFile(str_replace('<Number>100</Number>','<Number>100</Number><Number>100</Number>',$native)),'duplicate fields rejected');
    rejected(xmlFile(str_replace('<Number>101</Number>','<Number>100</Number>',$native)),'duplicate user numbers rejected');
    rejected(xmlFile(str_replace('<AuthPassword>fixture-sip-secret</AuthPassword>','<AuthPassword encoding="ciphertext">fixture-sip-secret</AuthPassword>',$native)),'unknown encrypted field format rejected');
    rejected(zipFile(['123Db.xml'=>$native,'../escaped.php'=>'fixture']),'traversal paths rejected');
    rejected(zipFile(['123Db.xml'=>$native,'/absolute/file'=>'fixture']),'absolute paths rejected');
    rejected(zipFile(['123Db.xml'=>$native,'folder\\file'=>'fixture']),'Windows path traversal rejected');
    rejected(zipFile(['123Db.xml'=>$native,'123db.XML'=>$native]),'case-insensitive duplicate candidate rejected');
    rejected(zipFile(['123Db.xml'=>$native,'456Db.xml'=>$native]),'ambiguous backup candidates rejected');
    rejected(zipFile(['unknown.xml'=>$native]),'unknown database archive naming rejected');
    rejected(zipFile(['123Db.xml'=>$native,'link'=>'target'],function($z){$z->setExternalAttributesName('link',ZipArchive::OPSYS_UNIX,0120777<<16);}), 'symlink entry rejected');
    rejected(zipFile(['123Db.xml'=>$native],function($z){$z->setEncryptionName('123Db.xml',ZipArchive::EM_AES_256,'fixture-password');}), 'encrypted ZIP rejected');
    rejected(zipFile(['123Db.xml'=>$native,'bomb.bin'=>str_repeat('0',2097152)]),'excessive compression ratio rejected');
    rejected(xmlFile(str_repeat(' ',threecx_backup::MAX_XML_BYTES+1)),'oversized XML rejected before parse');
    $p=threecx_backup::analyze(xmlFile('unknown encrypted binary fixture'));check(!$p['supported'] && unsupported($p,'archive_format'),'unknown binary envelope reported');
    check(count(glob($dir.'/*'))>0,'test fixtures exist only in private temporary directory');
    echo 'PASS: '.$checks." bounded 3CX parser checks; synthetic native v14/v16 fixtures only.\n";
} finally {
    foreach(glob($dir.'/*') as $file)unlink($file);rmdir($dir);
}
