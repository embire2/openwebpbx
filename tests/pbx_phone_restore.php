<?php
require_once __DIR__.'/../resources/classes/pbx_phone_restore.php';
$checks=0;
function check(bool $value,string $message): void {global $checks;if(!$value)throw new RuntimeException($message);$checks++;}
function refuses(callable $run,string $message): void {try{$run();}catch(InvalidArgumentException){check(true,$message);return;}throw new RuntimeException($message);}
$user=['number'=>'100','auth_id'=>'device-100','password'=>" original & < > \" ' $ secret ", 'name'=>'A & B <Office>', 'enabled'=>true,'phone_properties'=>['MYPHONE_SIPTRANSPORT'=>'tls','MYPHONE_RTPMODE'=>'source-only']];
$raw='<PhoneDevice Secret="private-phone-secret" enabled="true"><DynamicOptions><option name="vlanwanid" value="41"/></DynamicOptions><CodecsPriority><Codec Priority="1" payload="PCMA"/></CodecsPriority><BLFS><BLF type="BLF" value="101"/></BLFS></PhoneDevice>';
$phone=['number'=>'100','mac'=>'001122334455','template'=>'fanvil.ph.xml','interface'=>'original-interface','settings'=>$raw,'provisioning_filename2'=>'original-private-path'];
$plan=pbx_phone_restore::plan($phone,$user,'tenant.example.test');
check($plan['line']['user_id']==='100'&&$plan['line']['auth_id']==='device-100','Separate source SIP/authentication identities survive.');
check($plan['line']['password']===$user['password'],'Password bytes, whitespace and XML-sensitive characters survive.');
check($plan['line']['server_address']==='tenant.example.test'&&$plan['line']['server_address_primary']==='tenant.example.test','Registrar uses the chosen tenant domain.');
check($plan['line']['outbound_proxy_primary']===null,'No outbound proxy is invented.');
check($plan['line']['sip_transport']===null&&$plan['line']['sip_port']===null&&$plan['line']['register_expires']===null,'Missing deskphone settings remain unknown; app preferences do not become handset settings.');
check($plan['device']['device_vendor']==='fanvil'&&$plan['device']['device_model']===null&&$plan['device']['device_template']===null,'Fanvil model is not guessed as X4.');
check($plan['device']['device_enabled']===false&&$plan['line']['enabled']===true,'Unreviewed provisioning is disabled without disabling SIP authentication.');
check($plan['source_payload']['settings_xml']===$raw&&$plan['source_payload']['phone']===$phone,'Exact source settings and provisioning metadata survive.');
check($plan['source_payload']['password']===$user['password']&&$plan['source_payload']['phone_properties']===$user['phone_properties'],'Private identity/app settings are retained for caller sealing.');
check(count($plan['source_payload']['blfs'])===1&&count($plan['source_payload']['codecs'])===1&&$plan['source_payload']['options']['vlanwanid']==='41','BLF, codec priority and VLAN details survive.');
check(!str_contains(json_encode([$plan['summary'],$plan['dependencies']]),'private-phone-secret')&&!str_contains(json_encode([$plan['summary'],$plan['dependencies']]),$user['password']),'Public summary excludes source passwords/secrets.');
$known=$phone+['transport'=>'tcp','sip_port'=>'5090','register_expires'=>'1200','outbound_proxy'=>'old-sbc.example.test','model'=>'X5U'];
$plan=pbx_phone_restore::plan($known,$user,'new.example.test');
check($plan['line']['sip_transport']==='tcp'&&$plan['line']['sip_port']==='5090'&&$plan['line']['register_expires']===1200,'Explicit source transport, port and interval survive.');
check($plan['line']['outbound_proxy_primary']==='old-sbc.example.test','Existing proxy stays unchanged and is flagged for reachability review.');
check($plan['device']['device_model']==='X5U'&&$plan['device']['device_template']===null,'Known model does not invent an unreviewed native provisioning template.');
refuses(fn()=>pbx_phone_restore::plan($phone,$user+[],'bad domain'),'Unsafe domain refused.');
refuses(fn()=>pbx_phone_restore::plan($phone,array_replace($user,['password'=>'']),'new.example.test'),'Missing password refused instead of randomized.');
refuses(fn()=>pbx_phone_restore::plan($phone,array_replace($user,['password'=>"line\nbreak"]),'new.example.test'),'Password line break refused.');
refuses(fn()=>pbx_phone_restore::plan($phone,array_replace($user,['password'=>'${secret}']),'new.example.test'),'Interpolation refused.');
refuses(fn()=>pbx_phone_restore::plan(array_replace($phone,['settings'=>'<!DOCTYPE x [<!ENTITY secret SYSTEM "file:///etc/passwd">]><PhoneDevice/>']),$user,'new.example.test'),'Unsafe XML refused without loading private files.');
refuses(fn()=>pbx_phone_restore::plan(array_replace($phone,['settings'=>'<PhoneDevice AuthID="other"/>']),$user,'new.example.test'),'Conflicting source authentication identity refused.');
refuses(fn()=>pbx_phone_restore::plan($phone+['transport'=>'unsupported'],$user,'new.example.test'),'Unsupported transport is not silently replaced.');
refuses(fn()=>pbx_phone_restore::plan($phone+['sip_port'=>'70000'],$user,'new.example.test'),'Invalid source port refused.');
refuses(fn()=>pbx_phone_restore::plan(array_replace($phone,['settings'=>'<PhoneDevice><option name="x" value="1"/><option name="x" value="2"/></PhoneDevice>']),$user,'new.example.test'),'Repeated settings refused.');
echo "PASS: $checks source phone preservation/validation checks.\n";
