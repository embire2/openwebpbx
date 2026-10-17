<?php
/** Invented V20 source records exercise the complete reader -> phone/settings boundary. */
if(PHP_SAPI!=='cli'){http_response_code(404);exit;}
foreach(['threecx_v20','pbx_phone_restore','pbx_ringing'] as $class)require_once __DIR__.'/../resources/classes/'.$class.'.php';
$checks=0;$check=static function(bool $condition,string $message)use(&$checks){if(!$condition)throw new RuntimeException($message);$checks++;};
$escape=static fn(string $s)=>htmlspecialchars($s,ENT_XML1|ENT_QUOTES,'UTF-8');
$password="  Original & < > \" secret  ";$settings="\n<PhoneDevice><DynamicOptions><option name=\"vlanwanid\" value=\"22\"/></DynamicOptions></PhoneDevice>\n";
$xml='<PhoneSystem><header><version>20.0.9.995</version></header><Tenants><Tenant><DN>'.
    '<Extension><Number>100</Number><FirstName>First</FirstName><AuthID>101</AuthID><AuthPassword>'.$escape($password).'</AuthPassword><VMPIN>001234</VMPIN><FwdProfiles><FwdProfile><Name>Available</Name></FwdProfile></FwdProfiles><OfficeHoursRoute>RingGroup.800.</OfficeHoursRoute><DeliverAudio>True</DeliverAudio><SupportReinvite>False</SupportReinvite><SupportReplaces>True</SupportReplaces><SRTPMode>SRTPDisabled</SRTPMode><PhoneDevices><PhoneDevice><MAC>001122334455</MAC><TemplateFilename>fanvil.ph.xml</TemplateFilename><Settings>'.$escape($settings).'</Settings><ProvisioningFilename2>source-private-filename</ProvisioningFilename2></PhoneDevice></PhoneDevices></Extension>'.
    '<Extension><Number>101</Number><AuthID>login-101</AuthID><AuthPassword>Second-source-password</AuthPassword><FwdProfiles><FwdProfile><Name>Available</Name></FwdProfile></FwdProfiles></Extension>'.
    '<RingGroup><Number>800</Number><Name>Ordered group</Name><RingStrategy>RingStrategyHunt</RingStrategy><Members><Member DN="101"/><Member DN="100"/></Members></RingGroup>'.
    '<Queue><Number>801</Number><Name>Random start</Name><PollingStrategy>PollingStrategyHuntRandomStart</PollingStrategy><Members><Member DN="101"/><Member DN="100"/></Members></Queue>'.
    '</DN></Tenant></Tenants></PhoneSystem>';
$document=new DOMDocument();$check($document->loadXML($xml,LIBXML_NONET),'Invented source fixture did not load.');$plan=threecx_v20::read($document->documentElement);
$check($plan['users'][0]['password']===$password,'Source password bytes were changed.');
$check($plan['users'][0]['auth_id']==='101'&&$plan['users'][1]['number']==='101'&&$plan['users'][1]['auth_id']==='login-101','Cross-user numeric identity pair was collapsed.');
$check(!array_key_exists('voicemail_pin',$plan['users'][0]),'Retired mailbox PIN was extracted.');
$user=$plan['v20']['users'][100]+$plan['users'][0];$phone=pbx_phone_restore::plan($plan['v20']['phones'][0],$user,'new-tenant.example.test');
$check($phone['line']['user_id']==='100'&&$phone['line']['auth_id']==='101'&&$phone['line']['password']===$password,'Phone mapping changed source credentials.');
$check($phone['source_payload']['settings_xml']===$settings&&$phone['source_payload']['phone']['provisioning_filename2']==='source-private-filename','Original source XML/provisioning path was changed.');
$check($plan['v20']['users'][100]['hours']['office']==='RingGroup.800.','Office-hours destination was lost.');
$check($plan['v20']['users'][100]['deliver_audio']===true&&$plan['v20']['users'][100]['support_reinvite']===false&&$plan['v20']['users'][100]['support_replaces']===true&&$plan['v20']['users'][100]['srtp_mode']==='SRTPDisabled','Source SIP options were lost.');
$check(array_column($plan['v20']['ring_groups'][0]['members'],'number')===['101','100']&&pbx_ringing::group($plan['v20']['ring_groups'][0]['strategy'])==='sequence','Original hunt order was changed.');
$check(pbx_ringing::queue($plan['v20']['queues'][0]['strategy'])===['native_strategy'=>'top-down','polling_mode'=>'random_start'],'Random-start hunting was changed to random ringing.');
foreach(['HuntByThreesRandom','HuntByThreesPrioritized','SkillBasedRoutingRingAll','Invented'] as $strategy){try{pbx_ringing::queue($strategy);throw new RuntimeException('Unsupported ringing semantics were silently accepted.');}catch(InvalidArgumentException){$checks++;}}
echo "PASS: $checks V20 credential, source-phone and ringing boundary checks.\n";
