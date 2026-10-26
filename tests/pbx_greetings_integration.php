<?php
/** Real PostgreSQL owner/tenant/media/assignment checks in an owned schema and media directory. */
if(PHP_SAPI!=='cli')exit(2);
$dsn=getenv('OPENWEB_GREETINGS_TEST_DSN');if(!$dsn){fwrite(STDERR,"An owned PostgreSQL fixture connection is required.\n");exit(2);}
function uuid(): string {$v=bin2hex(random_bytes(16));return substr($v,0,8).'-'.substr($v,8,4).'-4'.substr($v,13,3).'-a'.substr($v,17,3).'-'.substr($v,20);}
function is_uuid($v): bool{return is_string($v)&&(bool)preg_match('/^[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}$/Di',$v);}
function permission_exists($name): bool{return !empty($_SESSION['permissions'][$name]);}
class database {public static PDO $fixture;public static function new(): object{return (object)['db'=>self::$fixture];}}
class settings {public static function clear_cache(): void{}}
class cache {public function delete($key): void{}}
class event_socket {public static function api($command): string{return '+OK isolated cache adapter';}}
class pbx_paths {
 public static string $root;
 public static function media(): string{return self::$root.'/media';}
 public static function greetings(): string{return self::media();}
 public static function greetingContains(string $domain,string $file): bool{return self::contains(self::greetings().'/'.$domain.'/greetings',$file);}
 public static function voicemail(): string{return self::$root.'/voicemail';}
 public static function contains(string $root,string $path): bool{$r=realpath($root);$p=realpath($path);return $r!==false&&$p!==false&&str_starts_with($p,rtrim($r,'/').'/');}
}
foreach(['pbx_tenants','pbx_setup','pbx_staff_access','pbx_admin','pbx_greetings']as$class)require dirname(__DIR__).'/resources/classes/'.$class.'.php';
$db=new PDO($dsn,getenv('OPENWEB_GREETINGS_TEST_USER')?:'postgres',getenv('OPENWEB_GREETINGS_TEST_PASSWORD')?:null,[PDO::ATTR_ERRMODE=>PDO::ERRMODE_EXCEPTION]);database::$fixture=$db;
$schema='greetings_'.bin2hex(random_bytes(6));$work=sys_get_temp_dir().'/'.$schema;mkdir($work,0700);pbx_paths::$root=$work;
$checks=0;$prior=$_SESSION??[];
$q=static function(string $sql,array $args=[])use($db){$s=$db->prepare($sql);$s->execute($args);return $s;};
$ok=static function($valid,$message)use(&$checks){if(!$valid)throw new RuntimeException($message);$checks++;};
$deny=static function(callable $action,$message)use($ok){try{$action();}catch(DomainException|InvalidArgumentException|OverflowException){$ok(true,$message);return;}$ok(false,$message);};
try{
 $db->exec('create schema '.$schema.';set search_path to '.$schema);
 $db->exec('create table v_domains(domain_uuid uuid primary key,domain_name text,domain_enabled boolean);create table v_users(user_uuid uuid primary key,domain_uuid uuid,user_enabled boolean);create table v_pbx_tenants(tenant_uuid uuid primary key,owner_user_uuid uuid,home_domain_uuid uuid,tenant_name text,enabled boolean);create table v_pbx_services(tenant_uuid uuid,domain_uuid uuid,service_name text);create table v_pbx_restore(domain_uuid uuid primary key,config jsonb);create table v_pbx_media(media_uuid uuid primary key,domain_uuid uuid,category text,file_path text,title text,source_path text,owner_number text,created_at timestamptz);create table v_recordings(recording_uuid uuid primary key,domain_uuid uuid,recording_filename text,recording_name text);create table v_extensions(extension_uuid uuid primary key,domain_uuid uuid,hold_music text,enabled boolean);create table v_voicemails(voicemail_uuid uuid primary key,domain_uuid uuid,greeting_id integer);create table v_voicemail_greetings(voicemail_greeting_uuid uuid primary key,domain_uuid uuid,voicemail_id text,greeting_id integer,greeting_filename text,greeting_description text,greeting_name text);create table v_ivr_menus(ivr_menu_uuid uuid primary key,domain_uuid uuid,ivr_menu_greet_long text,ivr_menu_greet_short text);create table v_call_center_queues(call_center_queue_uuid uuid primary key,domain_uuid uuid,queue_greeting text,queue_moh_sound text)');
 $migration=file_get_contents(dirname(__DIR__).'/app/pbx_greetings/resources/install.sql');$db->exec($migration);$db->exec($migration);
 $a=uuid();$b=uuid();$owner=uuid();$foreign=uuid();$ta=uuid();$tb=uuid();$ext=uuid();$vm=uuid();$ivr=uuid();$queue=uuid();
 foreach([$a,$b] as $d)$q('insert into v_domains values(?,?,true)',[$d,$d.'.invalid']);
 $q('insert into v_users values(?,?,true),(?,?,true)',[$owner,$a,$foreign,$b]);
 $q('insert into v_pbx_tenants values(?,?,?,\'Fixture A\',true),(?,?,?,\'Fixture B\',true)',[$ta,$owner,$a,$tb,$foreign,$b]);
 $q('insert into v_pbx_services values(?,?,\'Fixture PBX\'),(?,?,\'Other PBX\')',[$ta,$a,$tb,$b]);
 $c=['realm'=>$a.'.invalid','users'=>['1000'=>['name'=>'Fixture owner','number'=>'1000','extension_uuid'=>$ext,'voicemail_uuid'=>$vm,'enabled'=>true,'greeting_id'=>'7','greetings'=>[['id'=>'7','title'=>'Original custom greeting']]]],'queues'=>[['number'=>'8000','uuid'=>$queue,'name'=>'Queue']],'receptionists'=>[['number'=>'9000','uuid'=>$ivr,'name'=>'Reception']],'trunks'=>[]];
 $q('insert into v_pbx_restore values(?,cast(? as jsonb)),(?,cast(? as jsonb))',[$a,json_encode($c),$b,json_encode(array_replace($c,['realm'=>$b.'.invalid']))]);
 $q('insert into v_extensions values(?,?,null,true)',[$ext,$a]);$q('insert into v_voicemails values(?,?,7)',[$vm,$a]);$q('insert into v_ivr_menus values(?,?,\'old.wav\',\'old.wav\')',[$ivr,$a]);$q('insert into v_call_center_queues values(?,?,\'old.wav\',\'old-music.wav\')',[$queue,$a]);
 $_SESSION=['authorized'=>true,'user_uuid'=>$owner,'domain_uuid'=>$a,'domain_name'=>$a.'.invalid','permissions'=>['pbx_service_create'=>true]];
 $admin=new pbx_greetings($db);$ok($admin->installed(),'Repeatable migration installed');
 $input=['category'=>'voicemail','source'=>'phone','company_name'=>'Fixture Company','target_number'=>'1000','caller_extension'=>'1000'];
 $deny(fn()=>$admin->create($input),'No worker refuses creation instead of silently queuing');
 $q('insert into v_pbx_greeting_status values(1,false,now())');$deny(fn()=>$admin->create($input),'No provider configuration refuses creation');
 $q('update v_pbx_greeting_status set provider_configured=true');$ok($admin->readiness()['ready'],'Configured recent worker is ready');
 $id=$admin->create($input);$id2=$admin->create($input);$all=$admin->all();$ok(count($all)===2&&$all[0]['name']!==$all[1]['name'],'Blank names produce unique suitable names');
 foreach([['category'=>'invalid'],['source'=>'unknown'],['target_number'=>'not-a-number'],['caller_extension'=>'9999'],['company_name'=>''],['source'=>'text','script'=>''],['source'=>'text','script'=>str_repeat('x',3001)],['name'=>['bad']]]as$bad)$deny(fn()=>$admin->create(array_replace($input,$bad)),'Invalid greeting request refused');
 $outside=$admin->create(array_replace($input,['target_number'=>'+27110000001']));$ok(is_uuid($outside),'Outside number is queued without dialling from HTTP');
 $script="Hello.\r\nWelcome to our company.\nPlease hold\twhile we connect you.";
 $multiline=$admin->create(array_replace($input,['source'=>'text','script'=>$script]));
 $ok($q('select script from v_pbx_greetings where greeting_uuid=?',[$multiline])->fetchColumn()===$script,'Multiline text greeting preserves CRLF, LF and ordinary tab characters');
 foreach(["\0","\x0b","\x0c","\x1b","\x7f"] as $control)$deny(fn()=>$admin->create(array_replace($input,['source'=>'text','script'=>'Hello'.$control.'caller.'])),'Forbidden controls remain rejected in multiline greeting text');
 foreach(['name'=>"Office\nGreeting",'company_name'=>"Company\rName",'target_number'=>"1000\n",'caller_extension'=>"1000\t"] as $field=>$value)$deny(fn()=>$admin->create(array_replace($input,[$field=>$value])),'Non-script greeting fields remain single-line');
 $dir=pbx_paths::media().'/'.$a.'/greetings/'.$id;mkdir($dir,0700,true);$path=$dir.'/audio.wav';file_put_contents($path,str_repeat('x',2000));
 $q('insert into v_pbx_media values(?,?,\'prompts\',?,\'Ready fixture\',?,null,now())',[$id,$a,$path,'greetings/'.$id]);
 $q('insert into v_recordings values(?,?,?,\'Ready fixture\')',[uuid(),$a,$path]);$q('update v_pbx_greetings set state=\'ready\',media_uuid=greeting_uuid where greeting_uuid=?',[$id]);
 $ok($admin->media($id)['file_path']===$path,'Ready audio stays inside owned media root');
 $vmDir=pbx_paths::voicemail().'/default/'.$c['realm'].'/1000';mkdir($vmDir,0700,true);file_put_contents($vmDir.'/greeting_7.wav','ORIGINAL CUSTOM AUDIO');
 $admin->assign($id,'voicemail',['1000']);$saved=(new pbx_admin($db))->config();
 $ok($saved['users']['1000']['greeting_id']==='1000'&&file_get_contents($vmDir.'/greeting_7.wav')==='ORIGINAL CUSTOM AUDIO','Shared voicemail assignment preserves old custom greeting');
 $ok(file_get_contents($vmDir.'/greeting_1000.wav')===file_get_contents($path),'Voicemail copy matches recorded bytes');
 $admin->assign($id,'voicemail',['1000']);$ok((int)$q('select count(*) from v_voicemail_greetings')->fetchColumn()===1,'Repeated assignment reuses its existing copy');
 $admin->rename($id,['name'=>'Renamed fixture']);$ok($admin->all()[2]['name']==='Renamed fixture'||(bool)$q('select 1 from v_pbx_greetings where greeting_uuid=? and name=?',[$id,'Renamed fixture'])->fetchColumn(),'Rename preserves greeting identity');
 $ok($q('select recording_name from v_recordings where recording_filename=?',[$path])->fetchColumn()==='Renamed fixture','Recording library name follows rename');
 $renamed=(new pbx_admin($db))->config();$ok($renamed['users']['1000']['greetings'][1]['title']==='Renamed fixture','Voicemail greeting choices follow rename without changing old custom choices');
 $deny(fn()=>$admin->assign($id,'voicemail',['9999']),'Foreign destination refused');$deny(fn()=>$admin->assign($id,'hold_music',['8000']),'Wrong category assignment refused');$deny(fn()=>$admin->action($id,'archive'),'Assigned audio cannot be archived');
 $q('update v_pbx_greetings set category=\'receptionist\' where greeting_uuid=?',[$id]);$admin->assign($id,'receptionist',['9000']);$ok($q('select ivr_menu_greet_long from v_ivr_menus')->fetchColumn()===$path,'Digital Receptionist assignment reaches native configuration');
 $q('update v_pbx_greetings set category=\'queue_wait\' where greeting_uuid=?',[$id]);$admin->assign($id,'queue_wait',['8000']);$ok((new pbx_admin($db))->config()['queues'][0]['announce_sound']===$path,'Queue waiting announcement is assigned');
 $q('update v_pbx_greetings set category=\'hold_music\' where greeting_uuid=?',[$id]);$admin->assign($id,'hold_music',['8000']);$admin->assign($id,'extension_hold',['1000']);$ok($q('select queue_moh_sound from v_call_center_queues')->fetchColumn()===$path&&$q('select hold_music from v_extensions')->fetchColumn()===$path,'Hold audio reaches queue and extension settings');
 $admin->unassign($id,'extension_hold','1000');$ok($q('select hold_music from v_extensions')->fetchColumn()===null,'Unassign restores extension default music');
 $changed=(new pbx_admin($db))->config();$changed['queues'][0]['moh']='different-custom.wav';$q('update v_pbx_restore set config=cast(? as jsonb) where domain_uuid=?',[json_encode($changed),$a]);$q('update v_call_center_queues set queue_moh_sound=\'different-custom.wav\'');
 $admin->unassign($id,'hold_music','8000');$ok($q('select queue_moh_sound from v_call_center_queues')->fetchColumn()==='different-custom.wav','Removing stale assignment preserves a newer custom choice');
 $admin->unassign($id,'voicemail','1000');$ok(file_get_contents($vmDir.'/greeting_7.wav')==='ORIGINAL CUSTOM AUDIO'&&is_file($vmDir.'/greeting_1000.wav'),'Unassign preserves original and generated mailbox files');
 $_SESSION['domain_uuid']=$b;$deny(fn()=>new pbx_greetings($db),'Owner cannot switch to another tenant');$_SESSION['user_uuid']=$foreign;$_SESSION['domain_name']=$b.'.invalid';$other=new pbx_greetings($db);$ok(!$other->all(),'Foreign tenant list is isolated');$deny(fn()=>$other->media($id),'Foreign tenant cannot read audio');$deny(fn()=>$other->rename($id,['name'=>'Cross tenant']),'Foreign tenant cannot rename');$deny(fn()=>$other->assign($id,'voicemail',['1000']),'Foreign tenant cannot assign');$deny(fn()=>$other->unassign($id,'receptionist','9000'),'Foreign tenant cannot remove assignments');
 $_SESSION['domain_uuid']=$a;$_SESSION['user_uuid']=$owner;$_SESSION['domain_name']=$a.'.invalid';$q('update v_users set user_enabled=false where user_uuid=?',[$owner]);$deny(fn()=>new pbx_greetings($db),'Disabled administrator denied');$q('update v_users set user_enabled=true where user_uuid=?',[$owner]);
 $_SESSION['authorized']=false;$deny(fn()=>new pbx_greetings($db),'Signed-out administrator denied');$_SESSION['authorized']=true;
 $q("update v_pbx_greeting_status set checked_at=now()-interval '3 minutes'");$deny(fn()=>$admin->create($input),'Stale worker refuses creation');
 echo "PASS: $checks Greetings SQL, owner/tenant, readiness, unique names, media, category, assignment and custom-preservation checks\n";
}finally{if($db->inTransaction())$db->rollBack();$db->exec('set search_path to public;drop schema if exists '.$schema.' cascade');$delete=function($path)use(&$delete){if(is_dir($path)&&!is_link($path)){foreach(scandir($path)as$name)if($name!=='.'&&$name!=='..')$delete($path.'/'.$name);rmdir($path);}elseif(file_exists($path)||is_link($path))unlink($path);};$delete($work);$_SESSION=$prior;}
