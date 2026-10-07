<?php
/** CLI-only, idempotent first installation. Secrets are read from a private file. */
if(PHP_SAPI!=='cli'){http_response_code(404);exit;}
$web=$argv[1]??'';$stage=$argv[2]??'';
require $web.'/resources/require.php';
$db=$database->db;$db->setAttribute(PDO::ATTR_ERRMODE,PDO::ERRMODE_EXCEPTION);
function sql(string $q,array $p=[]): PDOStatement {global $db;$s=$db->prepare($q);$s->execute($p);return $s;}
if($stage==='domain'){
 if(!sql('select domain_uuid from v_domains where domain_name=?',[pbx_paths::host()])->fetchColumn())sql('insert into v_domains(domain_uuid,domain_name,domain_description,domain_enabled) values(?,?,?,true)',[uuid(),pbx_paths::host(),'OpenWeb PBX platform']);
 echo "Platform domain initialized.\n";exit;
}
if($stage==='migrate'){
 foreach(['tenant_services/resources/install.sql','smtp_settings/resources/install.sql','pbx_setup/resources/install.sql','pbx_setup/resources/restore.sql','pbx_setup/resources/jobs.sql'] as $file)$db->exec(file_get_contents($web.'/app/'.$file));
 foreach(['cache.location'=>['cache','location','text'],'cache.method'=>['cache','method','text'],'switch.voicemail.dir'=>['switch','voicemail','dir'],'switch.recordings.dir'=>['switch','recordings','dir'],'switch.storage.dir'=>['switch','storage','dir'],'switch.sounds.dir'=>['switch','sounds','dir'],'switch.scripts.dir'=>['switch','scripts','dir']] as $key=>$parts){
  $value=config::load()->get($key);if($value==='')continue;
  $s=sql('update v_default_settings set default_setting_value=?,default_setting_enabled=true where default_setting_category=? and default_setting_subcategory=? and default_setting_name=?',[$value,...$parts]);
  if(!$s->rowCount())sql('insert into v_default_settings(default_setting_uuid,default_setting_category,default_setting_subcategory,default_setting_name,default_setting_value,default_setting_enabled) values(?,?,?,?,?,true)',[uuid(),...$parts,$value]);
 }
 settings::clear_cache();
 echo "PBX schema is ready.\n";exit;
}
if($stage!=='admin')throw new RuntimeException('Choose the installation stage.');
$private=getenv('OPENWEB_SETUP_SECRETS');if(!$private||!is_file($private))throw new RuntimeException('Private setup settings are missing.');
$input=json_decode(file_get_contents($private),true,512,JSON_THROW_ON_ERROR);
$email=$input['AdminEmail'];$password=$input['AdminPassword'];
if(!filter_var($email,FILTER_VALIDATE_EMAIL)||strlen($password)<8)throw new InvalidArgumentException('Use a valid administrator email and a password of at least eight characters.');
$domain=sql('select domain_uuid from v_domains where domain_name=?',[pbx_paths::host()])->fetchColumn();
$user=sql('select user_uuid from v_users where lower(username)=lower(?)',[$email])->fetchColumn();
if(!$user){
 $db->beginTransaction();try{
  $group=sql("select group_uuid from v_groups where group_name='superadmin' and domain_uuid is null")->fetchColumn();if(!$group)throw new RuntimeException('Default administrator permissions are unavailable.');
  $user=uuid();sql('insert into v_users(user_uuid,domain_uuid,username,user_email,password,user_enabled) values(?,?,?,?,?,true)',[$user,$domain,$email,$email,password_hash($password,PASSWORD_DEFAULT)]);
  sql("insert into v_user_groups(user_group_uuid,domain_uuid,user_uuid,group_uuid,group_name) values(?,?,?,?,'superadmin')",[uuid(),$domain,$user,$group]);$db->commit();
 }catch(Throwable $e){if($db->inTransaction())$db->rollBack();throw $e;}
}
unset($input,$password);
foreach(['tenant_services/resources/install.sql','smtp_settings/resources/install.sql','pbx_setup/resources/install.sql','pbx_setup/resources/restore.sql','pbx_setup/resources/jobs.sql'] as $file)$db->exec(file_get_contents($web.'/app/'.$file));
$_SESSION=['user_uuid'=>$user,'domain_uuid'=>$domain,'domain_name'=>pbx_paths::host(),'user'=>['domain_uuid'=>$domain]];
$tenant=sql('select tenant_uuid from v_pbx_tenants where owner_user_uuid=?',[$user])->fetchColumn();
if(!$tenant){$tenant=uuid();$home=uuid();$slug='company-'.substr(str_replace('-','',$tenant),0,12);sql('insert into v_domains(domain_uuid,domain_name,domain_description,domain_enabled) values(?,?,?,true)',[$home,$slug.'.'.pbx_paths::host(),'My company']);sql('insert into v_pbx_tenants(tenant_uuid,tenant_name,slug,home_domain_uuid,owner_user_uuid,invite_email) values(?,?,?,?,?,?)',[$tenant,'My company',$slug,$home,$user,$email]);}
$service=sql('select domain_uuid from v_pbx_services where tenant_uuid=? limit 1',[$tenant])->fetchColumn();
if(!$service){
 $manager=new pbx_tenants($db);$template=$manager->saveTemplate(['template_name'=>'Business PBX','published'=>'1','description'=>'An empty PBX, ready for users and a provider.','config'=>['timezone'=>'UTC','extension_start'=>100,'extension_count'=>0,'extension_limit'=>100,'trunks'=>[],'rules'=>[],'settings'=>[]]]);
 $id=$manager->provision(['tenant_uuid'=>$tenant,'template_uuid'=>$template,'service_name'=>'Main PBX','slug'=>'main','request_uuid'=>uuid()]);$service=sql('select domain_uuid from v_pbx_services where service_uuid=?',[$id])->fetchColumn();
}
$realm=sql('select domain_name from v_domains where domain_uuid=?',[$service])->fetchColumn();
$_SESSION['domain_uuid']=$service;$_SESSION['domain_name']=$realm;$admin=new pbx_admin($db);
if(!$admin->restored()){$db->beginTransaction();try{$admin->initialize($realm,'UTC');$db->commit();}catch(Throwable $e){$db->rollBack();throw $e;}}
if(!$admin->config()['users'])foreach(['100'=>'Reception','101'=>'Office'] as $number=>$name)$admin->save('user','new',['number'=>(string)$number,'name'=>$name,'profile'=>'Available','timeout'=>'20','enabled'=>'1','voicemail_enabled'=>'1','voicemail_email'=>'None']);
settings::clear_cache();
echo "Administrator and Main PBX are ready.\n";
