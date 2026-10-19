<?php
/** Actual bridge process + isolated PostgreSQL: no DNS, ACME, mail or application writes. */
if(PHP_SAPI!=='cli'||(function_exists('posix_geteuid')&&posix_geteuid()!==0))exit(2);
$dsn=$argv[1]??'';$bridge=$argv[2]??dirname(__DIR__).'/packaging/debian/tenant-domains.php';
$db=new PDO($dsn,'postgres',null,[PDO::ATTR_ERRMODE=>PDO::ERRMODE_EXCEPTION]);
$schema='tenant_contact_'.bin2hex(random_bytes(6));$root=sys_get_temp_dir().'/openweb-tenant-contact-'.bin2hex(random_bytes(6));mkdir($root,0700);mkdir($root.'/resources',0700);$checks=0;
$check=static function(bool $ok,string $label)use(&$checks): void {if(!$ok)throw new RuntimeException($label);$checks++;};
try{
 $db->exec('create schema '.$schema.';set search_path to '.$schema);
 $db->exec('create table v_users(user_uuid uuid primary key,user_email text,user_enabled text);create table v_user_groups(user_uuid uuid,group_name text)');
 // Only the installed-web bootstrap and unrelated domain discovery are local
 // adapters. Selection and JSON transport execute the real CLI bridge file.
 $bootstrap='<?php $db=new PDO('.var_export($dsn,true).',"postgres",null,[PDO::ATTR_ERRMODE=>PDO::ERRMODE_EXCEPTION]);$db->exec('.var_export('set search_path to '.$schema,true).');$database=(object)["db"=>$db];class pbx_paths{public static function host():string{return "instance.example.test";}}class pbx_tenant_domains{public static function discover(PDO $db):array{return [];}public static function installed(PDO $db):bool{return false;}}';
 file_put_contents($root.'/resources/require.php',$bootstrap);chmod($root.'/resources/require.php',0600);
 $snapshot=static fn():array=>[$db->query('select *from v_users order by user_uuid')->fetchAll(PDO::FETCH_ASSOC),$db->query('select *from v_user_groups order by user_uuid,group_name')->fetchAll(PDO::FETCH_ASSOC)];
 $call=static function(string $expected,string $label)use($bridge,$root,$snapshot,$check):void{
  $before=$snapshot();$process=proc_open([PHP_BINARY,$bridge,$root,'discover'],[0=>['file','/dev/null','r'],1=>['pipe','w'],2=>['pipe','w']],$pipes);if(!is_resource($process))throw new RuntimeException('Bridge process unavailable.');$output=stream_get_contents($pipes[1]);$error=stream_get_contents($pipes[2]);fclose($pipes[1]);fclose($pipes[2]);$exit=proc_close($process);
  $check($exit===0&&$error==='',$label.': actual bridge exits without warnings');$value=json_decode($output,true,8,JSON_THROW_ON_ERROR);
  $check($value===['server_host'=>'instance.example.test','contact_email'=>$expected,'aliases'=>[],'inventory'=>[]],$label.': exact chosen administrator and existing response contract');
  $check($before===$snapshot(),$label.': all administrator and membership rows unchanged');
 };
 $id=static fn(int $i):string=>'00000000-0000-4000-a000-'.str_pad((string)$i,12,'0',STR_PAD_LEFT);
 $add=static function(int $i,?string $email,string $enabled,string $group)use($db,$id):void{$db->prepare('insert into v_users values(?,?,?)')->execute([$id($i),$email,$enabled]);$db->prepare('insert into v_user_groups values(?,?)')->execute([$id($i),$group]);};
 $call('','No administrator');
 $add(1,null,'true','superadmin');$add(2,'   ','true','superadmin');$add(3,'not-an-email','true','superadmin');$add(4,"header@example.test\r\nBcc: foreign@example.test",'true','superadmin');$add(5,'disabled@example.test','false','superadmin');$add(6,'staff@example.test','true','tenant_admin');
 $call('','Blank, invalid, disabled and non-instance administrators are ignored');
 $add(7,'  owner@example.test  ','true','superadmin');$call('owner@example.test','Later valid enabled instance administrator selected');
 $add(8,'second@example.test','true','superadmin');$call('owner@example.test','First valid administrator order is deterministic');
 $db->prepare('insert into v_user_groups values(?,?)')->execute([$id(7),'superadmin']);$call('owner@example.test','Duplicate memberships do not change contact');
 $db->prepare("update v_users set user_enabled='false'where user_uuid=?")->execute([$id(7)]);$call('second@example.test','Disabled earlier valid administrator skipped');
 $db->prepare("update v_users set user_enabled='true'where user_uuid=?")->execute([$id(7)]);$db->prepare("update v_user_groups set group_name='tenant_admin'where user_uuid=?")->execute([$id(7)]);$call('second@example.test','Valid ordinary tenant administrator is not an instance contact');
 $db->prepare("update v_users set user_email='invalid@'where user_uuid=?")->execute([$id(8)]);$call('','No valid instance contact returns empty without inventing a sender fallback');
 echo 'PASS '.$checks." actual PostgreSQL/CLI contact selection, contract and no-mutation controls; no network or message APIs called\n";
}finally{
 $db->exec('set search_path to public;drop schema if exists '.$schema.' cascade');
 foreach([$root.'/resources/require.php']as$p)if(is_file($p))unlink($p);rmdir($root.'/resources');rmdir($root);
}
