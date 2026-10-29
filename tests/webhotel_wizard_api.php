<?php
/** Real PostgreSQL/cryptography; an isolated schema and explicit proof/DNS hooks only. */
if(PHP_SAPI!=='cli')exit(2);
require dirname(__DIR__).'/resources/require.php';
$db=$database->db;$db->setAttribute(PDO::ATTR_ERRMODE,PDO::ERRMODE_EXCEPTION);
$schema='openweb_wizard_test_'.bin2hex(random_bytes(6));$count=0;
$check=function(bool$ok,string$message)use(&$count){if(!$ok)throw new RuntimeException($message);$count++;};
$denied=function(callable$fn,int$status,string$code='')use($check){try{$fn();}catch(pbx_tenant_api_error$e){$check($e->status===$status,'Unexpected setup refusal status');if($code!=='')$check($e->apiCode===$code,'Unexpected setup refusal code');return;}throw new RuntimeException('Expected setup refusal');};
$invalid=function(callable$fn)use($check){try{$fn();}catch(InvalidArgumentException){$check(true,'Invalid address refused');return;}throw new RuntimeException('Expected invalid address');};
$q=function(string$sql,array$params=[])use($db){$q=$db->prepare($sql);$q->execute($params);return$q;};
class fixture_wizard_authority extends pbx_installation_authority {
 public static OpenSSLAsymmetricKey $signer;
 protected function publicPem(): string{return openssl_pkey_get_details(self::$signer)['key'];}
 protected function signingKey(): OpenSSLAsymmetricKey{return self::$signer;}
 protected function verifySiteProof(array$r):void{}
}
class fixture_image_wizard extends pbx_wizard_api {
 public array $requests=[];public bool $ready=false;
 public function __construct(PDO$db,pbx_tenant_api$api,private fixture_wizard_authority$issuer){parent::__construct($db,$api);}
 protected function authority():pbx_installation_authority{return $this->issuer;}
 protected function rpc(string$operation,array$value):array{
  $this->requests[]=[$operation,$value];
  if($operation==='bootstrap-instance')return ['serverHost'=>'node-'.str_replace('-','',$value['installationUuid']).'.openwebpbx.com','address'=>$value['serverAddress'],'state'=>'dns_ready'];
  return ['verified'=>$this->ready];
 }
}
try{
 $db->exec('create schema '.$schema);$db->exec('set search_path to '.$schema.',public');
 foreach(['v_domains','v_users','v_user_groups','v_groups','v_group_permissions','v_permissions','v_menus','v_menu_items','v_menu_languages','v_menu_item_groups','v_default_settings','v_email_queue']as$table)$db->exec('create table '.$table.' (like public.'.$table.' including all)');
 foreach(['v_groups','v_group_permissions','v_permissions','v_menus','v_menu_items','v_menu_languages','v_menu_item_groups','v_default_settings']as$table)$db->exec('insert into '.$table.' select * from public.'.$table);
 foreach(['tenant_services/resources/install.sql','tenant_api/resources/install.sql','tenant_api/resources/onboarding.sql','tenant_api/resources/wizard.sql']as$file)$db->exec(file_get_contents(dirname(__DIR__).'/app/'.$file));
 $db->exec(file_get_contents(dirname(__DIR__).'/app/tenant_api/resources/wizard.sql'));
 $accounts=[];$tokens=[];$group=$q("select group_uuid from v_groups where group_name='tenant_admin' and domain_uuid is null limit 1")->fetchColumn();
 foreach(['alpha','bravo','unverified']as$name){
  $home=uuid();$user=uuid();$tenant=uuid();$email=$name.'@wizard.test.invalid';
  $q("insert into v_domains(domain_uuid,domain_name,domain_enabled) values(?,?,'true')",[$home,$name.'.wizard.test']);
  $q("insert into v_users(user_uuid,domain_uuid,username,user_email,password,user_enabled) values(?,?,?,?,?,'true')",[$user,$home,$email,$email,password_hash('Synthetic-only-password-2026!',PASSWORD_DEFAULT)]);
  $q("insert into v_user_groups(user_group_uuid,domain_uuid,user_uuid,group_uuid,group_name) values(?,?,?,?,'tenant_admin')",[uuid(),$home,$user,$group]);
  $q('insert into v_pbx_tenants(tenant_uuid,tenant_name,slug,home_domain_uuid,owner_user_uuid,invite_email) values(?,?,?,?,?,?)',[$tenant,$name,$name,$home,$user,$email]);
  if($name!=='unverified')$q("insert into v_pbx_api_registrations(registration_uuid,tenant_name,slug,email,password_hash,expires_at,verified_at,tenant_uuid) values(?,?,?,?,'',now(),now(),?)",[uuid(),$name,$name,$email,$tenant]);
  $token='owta_'.bin2hex(random_bytes(32));$q("insert into v_pbx_api_tokens(token_uuid,tenant_uuid,user_uuid,token_name,token_hash,expires_at) values(?,?,?,'Synthetic',?,now()+interval '1 day')",[uuid(),$tenant,$user,hash('sha256',$token)]);
  $accounts[$name]=['tenant_uuid'=>$tenant,'user_uuid'=>$user];$tokens[$name]=$token;
 }
 $api=new pbx_tenant_api($db,['enabled'=>true,'registration_enabled'=>true]);fixture_wizard_authority::$signer=openssl_pkey_new(['private_key_type'=>OPENSSL_KEYTYPE_RSA,'private_key_bits'=>3072]);
 $wizard=new fixture_image_wizard($db,$api,new fixture_wizard_authority($db));
 foreach(['127.0.0.1','10.0.0.1','169.254.169.254','192.0.2.1','198.51.100.1','203.0.113.1','100.64.0.1','172.31.0.1','192.168.1.1','::1','fe80::1','2001:db8::1','::ffff:8.8.8.8','2002:808:808::1']as$bad)$invalid(fn()=>pbx_wizard_api::address($bad));
 $check(pbx_wizard_api::address('8.8.8.8')==='8.8.8.8','Public IPv4 parser changed address');
 $check(pbx_wizard_api::address('2606:4700:4700::1111')==='2606:4700:4700::1111','Public IPv6 parser changed address');
 $key=openssl_pkey_new(['private_key_type'=>OPENSSL_KEYTYPE_EC,'curve_name'=>'prime256v1']);$pem=openssl_pkey_get_details($key)['key'];$public=preg_replace('/-----[^-]+-----|\s+/','',$pem);$hash=hash('sha256',base64_decode($public));
 $input=['provider'=>'webhotel','image_version'=>'1.0.21','public_key'=>$public,'local_tenant_uuid'=>uuid(),'domain_uuid'=>uuid(),'bootstrap_uuid'=>uuid()];
 $denied(fn()=>$wizard->start(array_replace($input,['bootstrap_uuid'=>'a1000000-0000-1000-8000-000000000001']),'1.0.0.1'),400,'invalid_request');
 $start=$wizard->start($input,'8.8.8.8');$check($start['verification_uri']==='https://openwebpbx.com/wizard','Wrong public setup URL');
 $check(preg_match('/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\+00:00$/D',$start['expires_at'])===1,'Setup expiry is not strict UTC RFC3339');
 $remaining=strtotime($start['expires_at'])-time();$check($remaining>1740&&$remaining<=1801,'Setup expiry is not within its real30-minute bound');
 $check(str_starts_with($start['verification_uri_complete'],'https://openwebpbx.com/wizard#code='),'Pairing secret belongs only in a URL fragment');
 $check(!str_contains($start['verification_uri_complete'],$start['device_code']),'Device credential leaked in browser link');
 $row=$q('select * from v_pbx_wizard_devices')->fetch(PDO::FETCH_ASSOC);
 $check($row['device_hash']===hash('sha256',$start['device_code'])&&!str_contains(json_encode($row),$start['device_code']),'Device credential stored in plaintext');
 $check($row['user_code_hash']===hash('sha256',str_replace('-','',$start['user_code'])),'Pairing code was not hashed');
 $check($row['key_hash']===$hash&&$row['server_address']==='8.8.8.8','Device identity or observed IP changed');
 $check($row['bootstrap_uuid']===$input['bootstrap_uuid'],'The installed canonical-node UUID was replaced');
 $denied(fn()=>$wizard->start($input,'8.8.8.8'),409,'setup_already_started');
 $lookup=$wizard->lookup(['user_code'=>strtolower($start['user_code'])],'1.1.1.1');
 $check($lookup['expires_at']===$start['expires_at'],'Browser status did not normalize the same database expiry to UTC');
 $check(!array_intersect(array_keys($lookup),['device_code','device_hash','public_key','account_user_uuid','account_tenant_uuid','activation']),'Public lookup exposed enrollment secrets');
 $poll=$wizard->poll(['device_code'=>$start['device_code']],'8.8.8.8');$check($poll['state']==='pending'&&!isset($poll['nonce']),'Unclaimed device received bootstrap authority');
 $claim=['user_code'=>$start['user_code'],'label'=>'wizard-tenant','confirm_server'=>true,'accept_terms'=>true];
 $denied(fn()=>$wizard->claim($accounts['unverified'],$claim),403,'verified_account_required');
 $denied(fn()=>$wizard->claim($accounts['alpha'],array_replace($claim,['confirm_server'=>false])),400,'confirmation_required');
 $claimed=$wizard->claim($accounts['alpha'],$claim);$check($claimed['state']==='claimed'&&!$claimed['ready']&&$claimed['tenant_url']===null,'Claim prematurely activated a server');
 $check($wizard->claim($accounts['alpha'],$claim)['pairing_uuid']===$claimed['pairing_uuid'],'Identical own claim was not idempotent');
 $denied(fn()=>$wizard->claim($accounts['bravo'],$claim),409,'server_already_claimed');
 $denied(fn()=>$wizard->claim($accounts['alpha'],array_replace($claim,['label'=>'different-tenant'])),409,'server_already_claimed');
 $denied(fn()=>$wizard->status($accounts['bravo'],$start['pairing_uuid']),404,'setup_unavailable');
 $stored=json_encode($q('select * from v_pbx_wizard_devices')->fetch(PDO::FETCH_ASSOC));
 $check(!str_contains($stored,$tokens['alpha'])&&!str_contains($stored,$tokens['bravo']),'Owner bearer credential was copied into pairing state');
 $poll=$wizard->poll(['device_code'=>$start['device_code']],'8.8.8.8');
 $check($poll['proof_body']==="openwebpbx-bootstrap-v1\n".$poll['nonce']."\n".$hash."\n8.8.8.8\n",'Bootstrap proof bytes differ from the registry contract');
 $message="openwebpbx-bootstrap-v1\n".$poll['nonce']."\n8.8.8.8\n".$hash."\n".$poll['bootstrap_uuid']."\n".$accounts['alpha']['tenant_uuid']."\n".$input['local_tenant_uuid']."\n".$input['domain_uuid']."\nwizard-tenant\n";
 openssl_sign($message,$signature,$key,OPENSSL_ALGO_SHA256);
 $denied(fn()=>$wizard->bootstrap(['device_code'=>$start['device_code'],'signature'=>base64_encode('wrong')]),403,'signature_invalid');
 $check(count($wizard->requests)===0,'Invalid signature reached DNS/proof transport');
 $node=$wizard->bootstrap(['device_code'=>$start['device_code'],'signature'=>base64_encode($signature)]);
 $check($node['state']==='dns_ready'&&$node['server_host']==='node-'.str_replace('-','',$poll['bootstrap_uuid']).'.openwebpbx.com','Bootstrap node binding incorrect');
 $rpc=$wizard->requests[0][1];$check($rpc['accountTenantUuid']===$accounts['alpha']['tenant_uuid']&&$rpc['publicKey']===$public,'Bootstrap RPC lost owner or key binding');
 // Root's actual managed-node predicate is exercised by the real authority here.
 $challenge=$wizard->challenge(['device_code'=>$start['device_code']]);
 $r=['nonce'=>$challenge['nonce'],'server_host'=>$node['server_host'],'key_hash'=>$hash,'account_tenant_uuid'=>$accounts['alpha']['tenant_uuid'],'local_tenant_uuid'=>$input['local_tenant_uuid'],'domain_uuid'=>$input['domain_uuid'],'label'=>'wizard-tenant'];
 openssl_sign(pbx_installation_authority::message($r),$signed,$key,OPENSSL_ALGO_SHA256);
 $denied(fn()=>$wizard->authorize(['device_code'=>$start['device_code'],'challenge_uuid'=>uuid(),'signature'=>base64_encode($signed)]),409,'challenge_changed');
 $authorized=$wizard->authorize(['device_code'=>$start['device_code'],'challenge_uuid'=>$challenge['challenge_uuid'],'signature'=>base64_encode($signed)]);
 $check($authorized['installation']['key_hash']===$hash,'Authorization lost the device key binding');
 $check($q('select state from v_pbx_wizard_devices')->fetchColumn()==='authorized','Authorization state not recorded');
 $check($wizard->status($accounts['alpha'],$start['pairing_uuid'])['tenant_url']===null,'Authorization alone advertised a ready HTTPS address');
 $poll=$wizard->poll(['device_code'=>$start['device_code']],'8.8.8.8');$hostname='wizard-tenant.openwebpbx.com';
 $complete="openwebpbx-complete-v1\n".$poll['complete_nonce']."\n".$hash."\n".$node['server_host']."\n".$hostname."\n".$input['domain_uuid']."\n";openssl_sign($complete,$signed,$key,OPENSSL_ALGO_SHA256);
 $body=['device_code'=>$start['device_code'],'hostname'=>$hostname,'signature'=>base64_encode($signed)];
 $denied(fn()=>$wizard->complete($body),503,'server_preparing');$check($wizard->status($accounts['alpha'],$start['pairing_uuid'])['ready']===false,'Failed TLS proof activated the server');
 $wizard->ready=true;$ready=$wizard->complete($body);$check($ready['ready']&&$ready['tenant_url']==='https://'.$hostname&&$ready['admin_url']==='https://'.$hostname.'/admin','Ready address not bound to proven tenant hostname');
 $q("update v_pbx_wizard_devices set expires_at=now()-interval '1 minute'");
 $check($wizard->poll(['device_code'=>$start['device_code']],'8.8.8.8')['state']==='complete','Completed server cannot use its own durable device renewal identity');
 $denied(fn()=>$wizard->lookup(['user_code'=>$start['user_code']],'1.1.1.1'),404,'pairing_unavailable');
 $q('update v_pbx_tenants set enabled=false where tenant_uuid=?',[$accounts['alpha']['tenant_uuid']]);
 $denied(fn()=>$wizard->poll(['device_code'=>$start['device_code']],'8.8.8.8'),403,'account_unavailable');
 $q('update v_pbx_tenants set enabled=true where tenant_uuid=?',[$accounts['alpha']['tenant_uuid']]);
 $q("update v_pbx_wizard_devices set expires_at=now()-interval '1 minute',activation_expires_at=now()-interval '1 minute'");
 $rotated=$wizard->start($input,'8.8.8.8');$check($rotated['pairing_uuid']!==$start['pairing_uuid']&&$rotated['device_code']!==$start['device_code'],'Expired setup did not rotate its credentials');
 $recovered=$wizard->poll(['device_code'=>$rotated['device_code']],'8.8.8.8');
 $check($recovered['bootstrap_uuid']===$input['bootstrap_uuid']&&$recovered['account_tenant_uuid']===$accounts['alpha']['tenant_uuid']&&$recovered['label']==='wizard-tenant','Expired setup lost its immutable node or claimed owner');
 $denied(fn()=>$wizard->claim($accounts['bravo'],array_replace($claim,['user_code'=>$rotated['user_code']])),409,'server_already_claimed');
 $denied(fn()=>$wizard->poll(['device_code'=>$start['device_code']],'8.8.8.8'),401,'device_expired');
 $other=openssl_pkey_new(['private_key_type'=>OPENSSL_KEYTYPE_EC,'curve_name'=>'prime256v1']);$otherPublic=preg_replace('/-----[^-]+-----|\s+/','',openssl_pkey_get_details($other)['key']);
 $denied(fn()=>$wizard->start(array_replace($input,['public_key'=>$otherPublic]),'8.8.8.8'),409,'server_identity_changed');
 $q("update v_pbx_wizard_devices set state='revoked'");$denied(fn()=>$wizard->poll(['device_code'=>$rotated['device_code']],'8.8.8.8'),401,'device_expired');
 $check((int)$q('select count(*) from v_pbx_services')->fetchColumn()===0,'Image enrollment created a second PBX on the main server');
 echo 'PASS: '.$count." real PostgreSQL/P256/RSA image-pairing controls; network proof and DNS hooks are isolated\n";
}finally{if($db->inTransaction())$db->rollBack();$db->exec('set search_path to public');$db->exec('drop schema if exists '.$schema.' cascade');}
