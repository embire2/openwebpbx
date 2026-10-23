<?php
/** Actual candidate parser/provisioner/restore with real isolated PostgreSQL/media.
 * Configuration paths alone are explicit adapters; no UI, engine, customer ZIP or mail.
 */
if(PHP_SAPI!=='cli')exit(2);
$phase='input';$checks=0;$failure=null;$cleanupFailure=null;$db=null;$schema=null;$created=false;$restore=null;$before=null;$ownedWork=false;
$work=$argv[1]??'';$portable=($argv[2]??'')==='--portable-socket';$configInput=$portable?($argv[3]??''):rtrim(getenv('ProgramData')?:'C:/ProgramData','/\\').'/fusionpbx/config.conf';
$source=$portable?($argv[4]??''):'C:/OpenWebPBX/web';
function windows_threecx_check(bool $condition):void{global$checks;if(!$condition)throw new RuntimeException('The isolated synthetic import assertion refused.');$checks++;}
function windows_threecx_public(PDO $db,string $schema='public'):string{
    if($schema!=='public'&&!preg_match('/^threecx_native_[a-f0-9]{24}$/D',$schema))throw new RuntimeException('Only the exact isolated inventory is allowed.');
    $hash=hash_init('sha256');$total=0;$tables=$db->query("select tablename from pg_tables where schemaname='".$schema."' order by tablename")->fetchAll(PDO::FETCH_COLUMN);
    foreach($tables as$table){if(!preg_match('/^[a-z_][a-z0-9_]*$/D',$table))throw new RuntimeException('The public inventory requires review.');hash_update($hash,$table."\0");$q=$db->query('select row_to_json(t)::text from "'.$schema.'"."'.$table.'" t order by row_to_json(t)::text collate "C"');while(($row=$q->fetchColumn())!==false){$total+=strlen($row);if($total>268435456)throw new RuntimeException('The public inventory exceeds its fixture bound.');hash_update($hash,strlen($row).':'.$row."\n");}}
    return hash_final($hash);
}
function windows_threecx_remove(string $path):void{
    if(!file_exists($path)&&!is_link($path))return;if(is_link($path))throw new RuntimeException('A redirected fixture path cannot be cleaned.');
    if(is_dir($path)){foreach(new DirectoryIterator($path)as$f){if(!$f->isDot())windows_threecx_remove($f->getPathname());}if(!rmdir($path))throw new RuntimeException('Owned fixture directory cleanup refused.');}
    elseif(!is_file($path)||!unlink($path))throw new RuntimeException('Owned fixture cleanup refused.');
}
try{
    if(!is_dir($work)||is_link($work)||!is_file($configInput)||is_link($configInput)||!is_file($source.'/resources/classes/threecx_backup.php'))throw new RuntimeException('The exact owned import fixture is required.');
    $work=str_replace('\\','/',realpath($work));$source=str_replace('\\','/',realpath($source));
    if($portable){if(PHP_OS_FAMILY==='Windows'||!preg_match('~^/tmp/openweb-threecx-pg-[a-f0-9]{32}/work$~D',$work))throw new RuntimeException('Only the isolated socket factory may run portably.');}
    else{if(PHP_OS_FAMILY!=='Windows'||getenv('OPENWEB_WINDOWS_NATIVE_TEST')!=='1'||getenv('GITHUB_ACTIONS')!=='true'||getenv('RUNNER_ENVIRONMENT')!=='github-hosted'||getenv('GITHUB_REPOSITORY')!=='embire2/openwebpbx'||!preg_match('~^'.preg_quote(str_replace('\\','/',getenv('ProgramData')?:'C:/ProgramData').'/OpenWebPBX/native-threecx-import/','~').'[a-f0-9]{24}$~iD',$work))throw new RuntimeException('The disposable hosted Windows factory is required.');}
    foreach(new DirectoryIterator($work)as$entry)if(!$entry->isDot())throw new RuntimeException('The exact owned fixture directory must initially be empty.');
    $ownedWork=true;
    $values=parse_ini_file($configInput);if(!is_array($values))throw new RuntimeException('The factory database configuration is unavailable.');$configHash=hash_file('sha256',$configInput);
    $host=$values['database.0.host']??'';$port=$values['database.0.port']??'';$name=$values['database.0.name']??'';
    if(!ctype_digit((string)$port)||!preg_match('/^[a-zA-Z0-9_]+$/D',$name)||($portable?!preg_match('~^/tmp/openweb-threecx-pg-[a-f0-9]{32}$~D',$host):($host!=='127.0.0.1'||$name!=='fusionpbx')))throw new RuntimeException('Only the explicit local factory database is allowed.');
    // Keep all actual restored paths/key material below this protected fixture.
    // No application bootstrap/global singleton connection can fall back to public.
    final class windows_threecx_path_configuration {
        public static array $values=[];public static string $file;
        public static function load():self{return new self();}public static function find():string{return self::$file;}
        public function get(string $name,mixed $default=null):mixed{return self::$values[$name]??$default;}
    }
    class_alias(windows_threecx_path_configuration::class,'config');windows_threecx_path_configuration::$file=$work.'/fixture.conf';
    windows_threecx_path_configuration::$values=['switch.storage.dir'=>$work.'/private storage','switch.voicemail.dir'=>$work.'/private voicemail'];
    $key=fopen($work.'/openweb-template.key','xb');if(!$key)throw new RuntimeException('The private fixture key could not be exclusively created.');try{if(fwrite($key,random_bytes(32))!==32)throw new RuntimeException('The private fixture key could not be created.');}finally{fclose($key);}
    spl_autoload_register(static function(string $class)use($source):void{if(!preg_match('/^[a-zA-Z0-9_]+$/D',$class))throw new RuntimeException('An unexpected import dependency was requested.');$path=$source.'/resources/classes/'.$class.'.php';if(!is_file($path))throw new RuntimeException('An installed import dependency is unavailable.');require_once$path;});
    require_once $source.'/resources/functions.php';require_once __DIR__.'/windows_threecx_fixture.php';
    $phase='database';$db=new PDO('pgsql:host='.$host.';port='.$port.';dbname='.$name,$values['database.0.username']??'', $values['database.0.password']??null,[PDO::ATTR_ERRMODE=>PDO::ERRMODE_EXCEPTION]);
    if($portable)windows_threecx_check($db->query('show data_directory')->fetchColumn()===$host.'/data'&&$db->query('show listen_addresses')->fetchColumn()==='');
    $db->exec("set statement_timeout='10000ms';set lock_timeout='2000ms'");$before=windows_threecx_public($db);$schema='threecx_native_'.bin2hex(random_bytes(12));$db->exec('create schema '.$schema);$created=true;$db->exec('set search_path to '.$schema);
    $tables=['v_menu_items','v_menu_languages','v_domains','v_extensions','v_voicemails','v_gateways','v_ring_groups','v_ring_group_destinations','v_destinations','v_dialplans','v_dialplan_details','v_call_center_agents','v_call_center_queues','v_call_center_tiers','v_ivr_menus','v_ivr_menu_options','v_devices','v_device_lines','v_device_keys','v_contacts','v_contact_phones','v_recordings','v_voicemail_messages','v_voicemail_greetings','v_pbx_restore','v_pbx_media','v_pbx_call_history'];
    foreach($tables as$table)$db->exec('create table '.$table.'(like public.'.$table.' including all)');
    $defaults=$db->query("select pg_get_expr(d.adbin,d.adrelid) from pg_attrdef d join pg_class c on c.oid=d.adrelid join pg_namespace n on n.oid=c.relnamespace where n.nspname='".$schema."'")->fetchAll(PDO::FETCH_COLUMN);
    foreach($defaults as$default)if(str_contains($default,'nextval(')||str_contains($default,'public.'))throw new RuntimeException('A copied default references shared state.');
    $phase='synthetic_archive';$fixture=windows_threecx_fixture($work);$plan=threecx_backup::analyze($fixture['archive']);pbx_v20_restore::validate($plan);windows_threecx_check($plan['source_version']==='20.0.9.995'&&count($plan['users'])===2);
    $preview=json_encode(threecx_backup::preview($plan),JSON_THROW_ON_ERROR);foreach($fixture['users']as$u)windows_threecx_check(!str_contains($preview,$u['password']));
    $phase='apply';$domain=uuid();$realm='synthetic-'.bin2hex(random_bytes(6)).'.example.invalid';$db->beginTransaction();$q=$db->prepare('insert into v_domains(domain_uuid,domain_name,domain_enabled)values(?,?,true)');$q->execute([$domain,$realm]);
    (new pbx_setup_provisioner($db))->apply($domain,$realm,$plan);$restore=new pbx_v20_restore($db);$report=$restore->apply($domain,$realm,$plan,$fixture['archive']);$db->commit();
    $configuration=json_decode($db->query('select config from v_pbx_restore')->fetchColumn(),true,512,JSON_THROW_ON_ERROR);
    foreach($fixture['users']as$u){$q=$db->prepare('select extension,password,accountcode,user_context,effective_caller_id_number from v_extensions where domain_uuid=? and extension=?');$q->execute([$domain,$u['auth']]);$row=$q->fetch(PDO::FETCH_ASSOC);windows_threecx_check($row&&$row['extension']===$u['auth']&&hash_equals($u['password'],$row['password'])&&$row['effective_caller_id_number']===$u['number']&&$row['accountcode']===$realm&&$row['user_context']===$realm);windows_threecx_check($configuration['users'][$u['number']]['auth_id']===$u['auth']);}
    windows_threecx_check((int)$db->query('select count(*) from v_gateways')->fetchColumn()===1&&(int)$db->query("select count(*) from v_gateways where enabled='true'")->fetchColumn()===0);
    windows_threecx_check((int)$db->query("select count(*) from v_destinations where destination_enabled='true'")->fetchColumn()===0);
    windows_threecx_check(count($configuration['ring_groups'])===1&&array_column($configuration['ring_groups'][0]['members'],'number')===['9101','9100']);
    windows_threecx_check($configuration['inbound_rules'][0]['office']['type']==='RingGroup'&&$configuration['inbound_rules'][0]['office']['number']==='9180');
    windows_threecx_check((int)$db->query('select count(*) from v_ring_group_destinations')->fetchColumn()===2&&$report['phones']===1&&$report['voicemail_greetings']===1);
    $line=$db->query('select user_id,auth_id,password,server_address from v_device_lines')->fetch(PDO::FETCH_ASSOC);windows_threecx_check($line&&$line['user_id']==='9100'&&$line['auth_id']===$fixture['users'][0]['auth']&&$line['password']===$fixture['users'][0]['password']&&$line['server_address']===$realm);
    $sealed=base64_decode($configuration['phones'][0]['source_ciphertext'],true);$plain=sodium_crypto_secretbox_open(substr($sealed,SODIUM_CRYPTO_SECRETBOX_NONCEBYTES),substr($sealed,0,SODIUM_CRYPTO_SECRETBOX_NONCEBYTES),file_get_contents($work.'/openweb-template.key'));$phone=json_decode($plain,true,64,JSON_THROW_ON_ERROR);
    windows_threecx_check($phone['settings_xml']==='<PhoneDevice><BLFS><Key value="9101"/></BLFS></PhoneDevice>'&&$phone['domain_uuid']===$domain&&$phone['realm']===$realm);
    $media=$db->query('select source_path,file_path from v_pbx_media order by source_path')->fetchAll(PDO::FETCH_ASSOC);windows_threecx_check(count($media)===count($fixture['media']));
    foreach($media as$m)windows_threecx_check(isset($fixture['media'][$m['source_path']])&&pbx_paths::contains($work,$m['file_path'])&&hash_file('sha256',$m['file_path'])===hash('sha256',$fixture['media'][$m['source_path']]));
    $custom=$configuration['users']['9100']['greetings'][0]['id']??'';windows_threecx_check($custom!==''&&is_file(pbx_paths::voicemail().'/default/'.$realm.'/9100/greeting_'.$custom.'.wav'));
    windows_threecx_check(hash_file('sha256',pbx_paths::voicemail().'/default/'.$realm.'/9100/greeting_'.$custom.'.wav')===hash('sha256',$fixture['media']['vmailprompts/9100/custom greeting.wav']));
    windows_threecx_check(empty($configuration['users']['9101']['greetings'])&&!isset($configuration['users']['9101']['voicemail_pin'])&&(int)$db->query('select count(*) from v_voicemail_greetings')->fetchColumn()===1);
    windows_threecx_check((int)$db->query('select count(*) from v_voicemail_messages')->fetchColumn()===1&&is_file($configuration['receptionists'][0]['prompt']));
    // Actual imported greeting remains intact when default voicemail policy is applied.
    $customHash=hash_file('sha256',pbx_paths::voicemail().'/default/'.$realm.'/9100/greeting_'.$custom.'.wav');$noPins=pbx_voicemail_policy::withoutPins($configuration);pbx_voicemail_policy::apply($db);windows_threecx_check(!isset($noPins['users']['9100']['voicemail_pin'])&&hash_file('sha256',pbx_paths::voicemail().'/default/'.$realm.'/9100/greeting_'.$custom.'.wav')===$customHash);
    windows_threecx_check((int)$db->query('select count(*) from v_voicemails where voicemail_password is not null')->fetchColumn()===0);
    $phase='repeat_refusal';$beforeRows=$db->query('select count(*) from v_extensions')->fetchColumn();$db->beginTransaction();$refused=false;try{(new pbx_setup_provisioner($db))->apply($domain,$realm,$plan);}catch(RuntimeException){$refused=true;}finally{$db->rollBack();}windows_threecx_check($refused&&$db->query('select count(*) from v_extensions')->fetchColumn()===$beforeRows);
    $phase='unsafe_zip';$bad=$work.'/unsafe.zip';$z=new ZipArchive();$z->open($bad,ZipArchive::CREATE|ZipArchive::EXCL);$z->addFromString('123456Db.xml','<PhoneSystem/>');$z->addFromString('../outside.wav','invalid');$z->close();$refused=false;try{threecx_backup::analyze($bad);}catch(InvalidArgumentException){$refused=true;}windows_threecx_check($refused&&!file_exists(dirname($work).'/outside.wav'));
    // Exercise actual late extraction failure after a real earlier WAV write.
    $phase='bad_wav_rollback';$prior=windows_threecx_public($db,$schema);$z=new ZipArchive();$z->open($fixture['archive'],ZipArchive::RDONLY);$xml=$z->getFromName('123456Db.xml');$z->close();$bad=$work.'/bad audio.zip';$z=new ZipArchive();$z->open($bad,ZipArchive::CREATE|ZipArchive::EXCL);$z->addFromString('123456Db.xml',$xml);$z->addFromString('vmailprompts/9100/first.wav',$fixture['media']['vmailprompts/9100/custom greeting.wav']);$z->addFromString('httpprompts/bad.wav','This is not a valid WAV header');$z->close();
    $faultDomain=uuid();$faultRealm='fault-'.bin2hex(random_bytes(6)).'.example.invalid';$faultRestore=new pbx_v20_restore($db);$refused=false;$lateWitness=false;$db->beginTransaction();
    try{$q=$db->prepare('insert into v_domains(domain_uuid,domain_name,domain_enabled)values(?,?,true)');$q->execute([$faultDomain,$faultRealm]);(new pbx_setup_provisioner($db))->apply($faultDomain,$faultRealm,$plan);$faultRestore->apply($faultDomain,$faultRealm,$plan,$bad);}catch(InvalidArgumentException){$refused=true;$written=glob(pbx_paths::media().'/'.$faultDomain.'/*.wav')?:[];$hashes=array_map(static fn($path)=>hash_file('sha256',$path),$written);$lateWitness=count($written)===2&&in_array(hash('sha256',$fixture['media']['vmailprompts/9100/custom greeting.wav']),$hashes,true)&&in_array(hash('sha256','This is not a valid WAV header'),$hashes,true);}finally{if($db->inTransaction())$db->rollBack();$faultRestore->rollbackFiles();}
    windows_threecx_check($refused&&$lateWitness&&windows_threecx_public($db,$schema)===$prior&&!file_exists(pbx_paths::media().'/'.$faultDomain));
    windows_threecx_check($db->query('show search_path')->fetchColumn()===$schema);
}catch(Throwable$e){$failure=$e;}
finally{
    try{
        if($db&&$db->inTransaction())$db->rollBack();if($restore)$restore->rollbackFiles();
        if($db&&$created){$db->exec('set search_path to public');$db->exec('drop schema '.$schema.' cascade');windows_threecx_check($db->query("select to_regnamespace('".$schema."')")->fetchColumn()===null);}
        if($db&&$before!==null)windows_threecx_check(windows_threecx_public($db)===$before);
        if(isset($configHash))windows_threecx_check(hash_file('sha256',$configInput)===$configHash);
        if($ownedWork&&is_dir($work)){foreach(['private storage','private voicemail','openweb-template.key','synthetic V20.zip','unsafe.zip','bad audio.zip']as$entry)windows_threecx_remove($work.'/'.$entry);}
    }catch(Throwable$e){$cleanupFailure=$e;}
}
$out=['schema'=>1,'producer'=>'windows_threecx_import_native.php','state'=>$failure||$cleanupFailure?'failed':'passed','checks'=>$checks,'php_version'=>PHP_VERSION,'actual_windows_native'=>PHP_OS_FAMILY==='Windows','actual_php_pg_zip_restore'=>!$failure&&!$cleanupFailure,'configuration_path_adapter'=>true,'ui_upload_tested'=>false,'calling_tested'=>false,'installed_server_changed'=>false,'historical_failure_cause_proven'=>false];
if(!$failure&&!$cleanupFailure)$out+=['synthetic_archive_only'=>true,'original_credentials_preserved'=>true,'custom_greeting_media_exact'=>true,'default_greeting_unchanged'=>true,'groups_and_routes_restored'=>true,'providers_and_dids_disabled'=>true,'complete_public_rows_exact'=>true,'global_config_exact'=>true,'owned_schema_media_key_removed'=>true,'late_wav_failure_exact_rollback'=>true];
else{$e=$failure??$cleanupFailure;$out+=['phase'=>$phase,'error_type'=>get_class($e),'source_basename'=>in_array(basename($e->getFile()),['windows_threecx_import_native.php','windows_threecx_fixture.php','pbx_setup_provisioner.php','pbx_v20_restore.php','threecx_backup.php','threecx_v20.php','pbx_paths.php','pbx_phone_restore.php'],true)?basename($e->getFile()):'external_component','source_line'=>$e->getLine(),'cleanup_failed'=>$cleanupFailure!==null];}
echo json_encode($out,JSON_THROW_ON_ERROR),PHP_EOL;exit($failure||$cleanupFailure?1:0);
