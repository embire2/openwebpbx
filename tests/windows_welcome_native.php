<?php
/** SPDX-License-Identifier: AGPL-3.0-or-later.
 * Actual installed welcome/outbox dispatcher in an owned PostgreSQL schema.
 * Alias custody/readiness are explicitly modelled; no external mail is sent.
 */
if(PHP_SAPI!=='cli')exit(2);
$phase='input';
set_exception_handler(static function(Throwable $error)use(&$phase):void{
 $file=basename(str_replace('\\','/',$error->getFile()));
 if(!in_array($file,['windows_welcome_native.php','pbx_mobile.php','pbx_mobile_welcome.php','email.php','outgoing_mail.php','email_send.php','database.php','config.php','settings.php'],true))$file='external_component';
 echo json_encode(['state'=>'failed','phase'=>$phase,'error_type'=>get_class($error),'source_basename'=>$file,'source_line'=>$error->getLine(),'sqlstate'=>$error instanceof PDOException&&(bool)preg_match('/^[A-Z0-9]{5}$/D',(string)$error->getCode())?(string)$error->getCode():'none'],JSON_THROW_ON_ERROR),PHP_EOL;exit(1);
});
$action=$argv[1]??'';$input=$argv[2]??'';$work=$argv[3]??'';$portable=in_array('--portable-socket-factory',$argv,true);
if(!in_array($action,['prepare','dispatch','inspect','suppress','cleanup'],true)||!is_file($input)||is_link($input)||!is_dir($work)||is_link($work))throw new RuntimeException('An owned mail fixture is required.');
$s=json_decode(file_get_contents($input),true,64,JSON_THROW_ON_ERROR);
if(($s['schema']??0)!==1||($s['restore_server']??false)!==true||!preg_match('/^[a-f0-9]{24}$/D',$s['scope']??''))throw new RuntimeException('An explicit disposable factory is required.');
$work=str_replace('\\','/',realpath($work));$input=str_replace('\\','/',realpath($input));$source=$portable?($s['source_root']??''):'C:/OpenWebPBX/web';
if($portable){
 if(PHP_OS_FAMILY==='Windows'||!str_starts_with($work,'/var/lib/openwebpbx/windows-client-provisioning-20261022/'))throw new RuntimeException('The private socket factory is required.');
 $configFile=$s['portable_config']??'';
}else{
 if(PHP_OS_FAMILY!=='Windows'||getenv('OPENWEB_WINDOWS_NATIVE_TEST')!=='1'||getenv('GITHUB_ACTIONS')!=='true'||getenv('RUNNER_ENVIRONMENT')!=='github-hosted'||getenv('GITHUB_REPOSITORY')!=='embire2/openwebpbx')throw new RuntimeException('The explicit Windows factory is required.');
 $expected=str_replace('\\','/',getenv('ProgramData')?:'C:/ProgramData').'/OpenWebPBX/native-qualification/'.$s['scope'];
 require_once __DIR__.'/windows_welcome_paths.php';
 if(!windows_welcome_owned_paths($input,$work,$expected))throw new RuntimeException('The owned Windows mail directory is required.');
 $configFile=str_replace('\\','/',getenv('ProgramData')?:'C:/ProgramData').'/fusionpbx/config.conf';
}
if(!is_file($configFile)||is_link($configFile)||!is_file($source.'/resources/require.php'))throw new RuntimeException('The exact application/configuration is required.');
$originalConfigHash=hash_file('sha256',$configFile);$stateFile=$work.'/state.private.json';$privateConfig=$work.'/config.conf';
if($action==='prepare'){
 if(is_file($stateFile)||is_file($privateConfig))throw new RuntimeException('The fixture directory is already occupied.');
 $port=(int)($argv[4]??0);if($port<1024||$port>65535)throw new RuntimeException('A loopback SMTP port is required.');
 $values=parse_ini_file($configFile);if(!is_array($values))throw new RuntimeException('The installed configuration is unavailable.');$originalValues=$values;
 if($portable&&(($values['database.0.name']??'')!=='welcome_native'||!str_starts_with($values['database.0.host']??'','/var/tmp/openweb-welcome-pg-')))throw new RuntimeException('Only the isolated socket database may be used.');
 if(!$portable&&(!in_array($values['database.0.host']??'',['127.0.0.1','localhost'],true)||($values['database.0.name']??'')!=='fusionpbx'))throw new RuntimeException('The local Windows database is required.');
 $values['document.root']=$source;$values['cache.method']='file';$values['cache.location']=$work.'/cache';$values['openweb.mobile_tls_ready']='true';$values['error.reporting']='user';
 if(!mkdir($work.'/cache',0700))throw new RuntimeException('The private cache is unavailable.');
 $lines=[];foreach($values as$key=>$value){if(!preg_match('/^[a-zA-Z0-9_.-]+$/D',(string)$key)||!is_scalar($value)||preg_match('/[\r\n\x00]/',(string)$value))throw new RuntimeException('The configuration cannot be privately copied.');$lines[]=$key.' = "'.addcslashes((string)$value,'\\"').'"';}
 file_put_contents($privateConfig,implode("\n",$lines)."\n");
 $copiedValues=parse_ini_file($privateConfig);foreach($originalValues as$key=>$value){if(in_array($key,['document.root','cache.method','cache.location','openweb.mobile_tls_ready','error.reporting'],true))continue;if(($copiedValues[$key]??null)!==$value)throw new RuntimeException('The private configuration copy changed a runtime value.');}
 if($portable&&($s['fault_after_config_copy']??false)===true)throw new RuntimeException('Deliberate private configuration-copy interruption.');
 $state=['schema'=>'welcome_native_'.bin2hex(random_bytes(6)),'scope'=>$s['scope'],'smtp_port'=>$port,'domain'=>null,'owner'=>null,'extension'=>null,'queues'=>[],'original_config_sha256'=>$originalConfigHash];
}else{
 if(!is_file($stateFile)||is_link($stateFile)||!is_file($privateConfig)||is_link($privateConfig))throw new RuntimeException('The private fixture state is unavailable.');
 $state=json_decode(file_get_contents($stateFile),true,64,JSON_THROW_ON_ERROR);
 if(($state['scope']??'')!==$s['scope']||!preg_match('/^welcome_native_[a-f0-9]{12}$/D',$state['schema']??'')||($state['original_config_sha256']??'')!==$originalConfigHash)throw new RuntimeException('The fixture/configuration identity changed.');
}
$schema=$state['schema'];$phase='database';
require_once $source.'/resources/classes/config.php';config::load($privateConfig);
require_once $source.'/resources/classes/auto_loader.php';$autoload=new auto_loader();
$database=database::new(['config'=>config::load()]);$db=$database->db;$db->setAttribute(PDO::ATTR_ERRMODE,PDO::ERRMODE_EXCEPTION);
$backend=(int)$db->query('select pg_backend_pid()')->fetchColumn();
$q=static function(string $sql,array $args=[])use($db):PDOStatement{$r=$db->prepare($sql);$r->execute($args);return$r;};
function welcome_public_fingerprint(PDO $db):string{
 $hash=hash_init('sha256');$tables=$db->query("select tablename from pg_tables where schemaname='public' order by tablename")->fetchAll(PDO::FETCH_COLUMN);$bytes=0;
 foreach($tables as$table){if(!preg_match('/^[a-z_][a-z0-9_]*$/D',$table))throw new RuntimeException('The public inventory needs review.');hash_update($hash,$table."\0");
  $rows=$db->query('select row_to_json(t)::text from public."'.$table.'" t order by row_to_json(t)::text collate "C"');
  while(($row=$rows->fetchColumn())!==false){$bytes+=strlen($row);if($bytes>268435456)throw new RuntimeException('The disposable public inventory is too large.');hash_update($hash,strlen($row).':'.$row."\n");}}
 return hash_final($hash);
}
if($action==='prepare'){
 if(!$portable){
  $owned=$s['owned']??[];$service=$q('select d.domain_name from public.v_pbx_services s join public.v_domains d using(domain_uuid) join public.v_pbx_tenants t using(tenant_uuid) where s.domain_uuid=? and s.service_name=? and t.owner_user_uuid=?',[$owned['domain_uuid']??'', $s['service_name']??'', $s['factory_admin']['user_uuid']??''])->fetchColumn();
  if(!is_string($service)||!preg_match('/^pbx-[a-f0-9]{12}\./D',$service)||$service!==($owned['domain_name']??''))throw new RuntimeException('The normal native fixture tenant is unavailable.');
 }else{if((int)$db->query('select count(*) from public.v_users')->fetchColumn()!==0)throw new RuntimeException('The socket database is not empty.');}
 $state['public_before']=welcome_public_fingerprint($db);$state['schema_created']=false;file_put_contents($stateFile,json_encode($state,JSON_THROW_ON_ERROR));
 if($q('select to_regnamespace(?)',[$schema])->fetchColumn())throw new RuntimeException('The fixture schema name is already occupied.');
 $db->exec('create schema '.$schema);$state['schema_created']=true;file_put_contents($stateFile,json_encode($state,JSON_THROW_ON_ERROR));$db->exec('set search_path to '.$schema);
 foreach(['v_default_settings','v_domain_settings','v_user_settings','v_domains','v_users','v_extensions','v_voicemails','v_voicemail_messages','v_pbx_restore','v_pbx_services','v_pbx_tenants','v_email_queue','v_email_queue_attachments']as$table)$db->exec('create table '.$table.'(like public.'.$table.' including all)');
 $defaults=$q("select pg_get_expr(d.adbin,d.adrelid) from pg_attrdef d join pg_class c on c.oid=d.adrelid join pg_namespace n on n.oid=c.relnamespace where n.nspname=?",[$schema])->fetchAll(PDO::FETCH_COLUMN);
 foreach($defaults as$default)if(str_contains($default,'nextval(')||str_contains($default,'public.'))throw new RuntimeException('A copied default references shared state.');
 $db->exec(file_get_contents($source.'/app/pbx_mobile/resources/install.sql'));
 require_once $source.'/resources/functions.php';$state['domain']=uuid();$state['owner']=uuid();$state['extension']=uuid();$state['alias']='https://qa-welcome-'.substr($s['scope'],0,16).'.openwebpbx.com';
 $q("insert into v_domains(domain_uuid,domain_name,domain_enabled)values(?,'welcome.example.invalid',true)",[$state['domain']]);
 $q("insert into v_users(user_uuid,domain_uuid,username,user_enabled)values(?,?,'welcome-native-owner',true)",[$state['owner'],$state['domain']]);
 $q("insert into v_extensions(extension_uuid,domain_uuid,extension,number_alias,enabled,password)values(?,?,'native-welcome-auth','8100',true,'unchanged-fixture-sip')",[$state['extension'],$state['domain']]);
 $configuration=['realm'=>'welcome.example.invalid','users'=>['8100'=>['number'=>'8100','name'=>'Fictional Windows User','auth_id'=>'native-welcome-auth','extension_uuid'=>$state['extension'],'enabled'=>true,'email'=>'welcome@example.invalid']]];
 $q("insert into v_pbx_restore(domain_uuid,source_version,config)values(?,'native-welcome-fixture',?::jsonb)",[$state['domain'],json_encode($configuration,JSON_THROW_ON_ERROR)]);
}elseif($action!=='cleanup'){$db->exec('set search_path to '.$schema);}
if($action==='cleanup'){
 $phase='cleanup';if($db->inTransaction())$db->rollBack();$db->exec('set search_path to public');
 if(($state['schema_created']??false)===true)$db->exec('drop schema '.$schema.' cascade');
 $exact=welcome_public_fingerprint($db)===$state['public_before']&&hash_file('sha256',$configFile)===$state['original_config_sha256'];
 if(!$exact)throw new RuntimeException('The original instance inventory changed.');
 if(PHP_OS_FAMILY==='Windows')foreach($state['queues']as$id){if(!preg_match('/^[a-f0-9-]{36}$/D',$id))throw new RuntimeException('An owned queue identity changed.');$lock=str_replace('\\','/',getenv('ProgramData')?:'C:/ProgramData').'/OpenWebPBX/mail/dispatch.'.$id.'.lock';if(is_link($lock))throw new RuntimeException('An owned mail lock changed.');if(is_file($lock)&&!unlink($lock))throw new RuntimeException('An owned mail lock could not be removed.');}
 echo json_encode(['state'=>'cleaned','public_exact'=>true,'config_exact'=>true,'owned_schema_removed'=>true,'only_owned_locks_removed'=>true],JSON_THROW_ON_ERROR),PHP_EOL;exit;
}
// This narrow test double models only the custody/HTTPS precondition. Alias
// worker/IIS and external Android acceptance remain independently required.
final class pbx_tenant_domains {
 public static function url(PDO$db,string$domain):string{global$state;if($db->query('select current_schema()')->fetchColumn()!==$state['schema']||$domain!==$state['domain'])throw new RuntimeException('The modelled alias escaped its fixture.');return$state['alias'];}
 public static function requestDomain(PDO$db,array$server):string{global$state;return($server['HTTP_HOST']??'')===parse_url(self::url($db,$state['domain']),PHP_URL_HOST)?$state['domain']:'';}
}
$domain_uuid=$state['domain'];$user_uuid=$state['owner'];$_SESSION=['authorized'=>true,'domain_uuid'=>$domain_uuid,'domain_name'=>'welcome.example.invalid','user_uuid'=>$user_uuid];
$phase='bootstrap';require_once $source.'/resources/require.php';
if(database::new()->db!==$db||(int)$db->query('select pg_backend_pid()')->fetchColumn()!==$backend||$db->query('show search_path')->fetchColumn()!==$schema)throw new RuntimeException('The real framework opened a different connection or schema.');
if($action==='prepare'){
 $phase='queue';(new outgoing_mail($db))->save(['smtp_host'=>'127.0.0.1','smtp_port'=>(string)$state['smtp_port'],'smtp_secure'=>'none','smtp_ip_whitelisted'=>'1','smtp_from'=>'welcome@example.invalid','smtp_from_name'=>'Native Welcome Fixture','smtp_reply_to'=>'reply@example.invalid']);
 $q("insert into v_default_settings(default_setting_uuid,default_setting_category,default_setting_subcategory,default_setting_name,default_setting_value,default_setting_enabled)values(?,'email_queue','save_response','boolean','true',true)",[uuid()]);
 $sent=(new pbx_mobile_welcome($db))->queue('8100');$state['queues'][]=$sent['queue_uuid'];
 $parts=$q('select email_attachment_type,email_attachment_base64 from v_email_queue_attachments where email_queue_uuid=?',[$sent['queue_uuid']])->fetchAll(PDO::FETCH_ASSOC);$expected=[];foreach($parts as$part)$expected[$part['email_attachment_type']]=base64_decode($part['email_attachment_base64'],true);
 if(!is_string($expected['png']??null)||!is_string($expected['openwebpbx']??null))throw new RuntimeException('The actual welcome attachments are unavailable.');
 file_put_contents($work.'/expected.private.json',json_encode(['payload'=>json_decode($expected['openwebpbx'],true,32,JSON_THROW_ON_ERROR),'png_sha256'=>hash('sha256',$expected['png'])],JSON_THROW_ON_ERROR));
 file_put_contents($work.'/state.private.json',json_encode($state,JSON_THROW_ON_ERROR));
 echo json_encode(['state'=>'prepared','queue_uuid'=>$sent['queue_uuid'],'schema_isolated'=>true,'same_framework_backend'=>true,'alias_custody_modelled'=>true,'tls_readiness_modelled'=>true,'actual_windows_native'=>PHP_OS_FAMILY==='Windows'],JSON_THROW_ON_ERROR),PHP_EOL;
}elseif($action==='dispatch'){
 $phase='dispatch';$id=$argv[4]??'';if(!in_array($id,$state['queues'],true))throw new RuntimeException('Only an owned welcome queue is allowed.');
 $transport=(new outgoing_mail($db))->transport();if($transport['host']!=='127.0.0.1'||(int)$transport['port']!==$state['smtp_port']||$transport['auth']!==false||$transport['secure']!=='none'||$transport['from']!=='welcome@example.invalid')throw new RuntimeException('The dispatcher refused a nonfixture SMTP destination.');
 $job=$source.'/app/email_queue/resources/jobs/email_send.php';$argv=[$job,'email_queue_uuid='.$id.'&hostname='.rawurlencode(gethostname()).'&sleep=1'];chdir($source);include$job;
 if(database::new()->db!==$db||(int)$db->query('select pg_backend_pid()')->fetchColumn()!==$backend||$db->query('show search_path')->fetchColumn()!==$schema)throw new RuntimeException('The dispatcher escaped its real singleton connection.');
}elseif($action==='inspect'){
 $phase='inspect';$view=(new pbx_mobile_welcome($db))->latest('8100');
 echo json_encode(['state'=>'observed','delivery_state'=>$view['state'],'inbox_claim_refused'=>str_contains($view['message'],'Inbox delivery is not confirmed'),'queue_states'=>$q('select email_status from v_email_queue order by email_date,email_queue_uuid')->fetchAll(PDO::FETCH_COLUMN),'public_exact'=>welcome_public_fingerprint($db)===$state['public_before'],'config_exact'=>hash_file('sha256',$configFile)===$state['original_config_sha256'],'same_framework_backend'=>true],JSON_THROW_ON_ERROR),PHP_EOL;
}elseif($action==='suppress'){
 $phase='suppress';$sent=(new pbx_mobile_welcome($db))->queue('8100');$state['queues'][]=$sent['queue_uuid'];
 $q('update v_pbx_mobile_enrollments set used_at=now() where enrollment_uuid=(select enrollment_uuid from v_pbx_mobile_welcome where email_queue_uuid=?)',[$sent['queue_uuid']]);
 file_put_contents($stateFile,json_encode($state,JSON_THROW_ON_ERROR));echo json_encode(['state'=>'prepared','queue_uuid'=>$sent['queue_uuid']],JSON_THROW_ON_ERROR),PHP_EOL;
}
