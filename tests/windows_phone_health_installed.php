<?php
/** Installed fresh-factory native observer proof; never use on an occupied PBX. */
if(PHP_SAPI!=='cli'||PHP_OS_FAMILY!=='Windows')exit(2);
require 'C:/OpenWebPBX/web/resources/require.php';
$db=database::new()->db;
if(($argv[1]??'')==='preservation'){
 if((int)$db->query('select count(*) from v_pbx_restore')->fetchColumn()!==0)throw new RuntimeException('An empty disposable factory is required.');
 // A timed whole-public-schema baseline, with the observer stopped and shared
 // maintenance lock held by the parent. No heartbeat/log rows are excluded.
 $hash=hash_init('sha256');$total=0;$tables=0;
 $feed=static function(string $value)use($hash,&$total):void{$total+=strlen($value);if($total>268435456)throw new RuntimeException('Bounded disposable factory inventory required.');hash_update($hash,pack('N',strlen($value)).$value);};
 foreach($db->query("select nspname,nspowner,nspacl from pg_namespace order by nspname")->fetchAll(PDO::FETCH_ASSOC)as$row)$feed(json_encode($row,JSON_THROW_ON_ERROR));
 $objects=$db->query("select c.oid,c.relname,c.relkind,c.relowner,c.relacl,c.relnatts from pg_class c join pg_namespace n on n.oid=c.relnamespace where n.nspname='public' and c.relkind in ('r','p','S','v','m','f') order by c.relname")->fetchAll(PDO::FETCH_ASSOC);
 foreach($objects as$object){
  $feed(json_encode($object,JSON_THROW_ON_ERROR));$oid=(int)$object['oid'];
  $columns=$db->query("select a.attnum,a.attname,format_type(a.atttypid,a.atttypmod) type,a.attnotnull,a.attidentity,a.attgenerated,a.attisdropped,pg_get_expr(d.adbin,d.adrelid) default_value from pg_attribute a left join pg_attrdef d on d.adrelid=a.attrelid and d.adnum=a.attnum where a.attrelid=$oid and a.attnum>0 order by a.attnum")->fetchAll(PDO::FETCH_ASSOC);$feed(json_encode($columns,JSON_THROW_ON_ERROR));
  $constraints=$db->query("select conname,pg_get_constraintdef(oid) definition from pg_constraint where conrelid=$oid order by conname")->fetchAll(PDO::FETCH_ASSOC);$feed(json_encode($constraints,JSON_THROW_ON_ERROR));
  $indexes=$db->query("select pg_get_indexdef(indexrelid) definition from pg_index where indrelid=$oid order by indexrelid")->fetchAll(PDO::FETCH_ASSOC);$feed(json_encode($indexes,JSON_THROW_ON_ERROR));
  $name='public."'.str_replace('"','""',$object['relname']).'"';
  if($object['relkind']==='f')throw new RuntimeException('A disposable factory may not use foreign tables.');
  if(in_array($object['relkind'],['r','p','m'],true)){
   $tables++;$rows=$db->query('select to_jsonb(t)::text row_value from '.$name.' t order by to_jsonb(t)::text');$count=0;
   while(($row=$rows->fetch(PDO::FETCH_ASSOC))!==false){if(++$count>100000||strlen($row['row_value'])>16777216)throw new RuntimeException('Bounded disposable factory rows required.');$feed($row['row_value']);}
   $feed('rows:'.$count);
  }elseif($object['relkind']==='S'){$feed(json_encode($db->query('select last_value,is_called from '.$name)->fetch(PDO::FETCH_ASSOC),JSON_THROW_ON_ERROR));}
  elseif($object['relkind']==='v'){$feed((string)$db->query("select pg_get_viewdef($oid,true)")->fetchColumn());}
 }
 echo json_encode(['state'=>'observed','public_preservation_sha256'=>hash_final($hash),'tables'=>$tables,'complete_public_rows'=>true,'complete_namespace_inventory'=>true],JSON_THROW_ON_ERROR),PHP_EOL;exit;
}
if(($argv[1]??'')==='heartbeat'){
 $q=$db->query("select pid,extract(epoch from state_change)::double precision changed,client_port from pg_stat_activity where datname=current_database() and usename=current_user and state='idle' and query like 'select recovery_uuid,block_uuid from v_pbx_phone_health_recoveries %'");
 $rows=$q->fetchAll(PDO::FETCH_ASSOC);echo json_encode(['state'=>'observed','workers'=>$rows],JSON_THROW_ON_ERROR),PHP_EOL;exit;
}
if((int)$db->query('select count(*) from v_pbx_restore')->fetchColumn()!==0||(int)$db->query('select count(*) from v_pbx_phone_health_contacts')->fetchColumn()!==0)throw new RuntimeException('An empty disposable factory is required.');
if(!pbx_phone_health::installed($db)||!preg_match('/^[a-f0-9]{64}$/D',pbx_phone_health::instanceId()??''))throw new RuntimeException('The native health installation is unavailable.');
$raw=pbx_windows_health_stream::api('show registrations as json');$rows=pbx_phone_health::registrations($raw);
if($rows!==[])throw new RuntimeException('The disposable factory already has phone contacts.');
$collected=pbx_phone_health::collect($db,$raw);
if($collected['observed_contacts']!==0||$collected['checked_domains']!==0)throw new RuntimeException('The empty native collector changed customer scope.');
$ports=event_guard_windows::ports(pbx_windows_health_stream::api('sofia xmlstatus'));
if(!$ports['tcp']||!$ports['udp'])throw new RuntimeException('The native phone listener scope is unavailable.');
echo json_encode(['state'=>'passed','actual_installed_collector'=>true,'native_registration_count'=>0,'credentials_or_routes_changed'=>false,'checks'=>4],JSON_THROW_ON_ERROR),PHP_EOL;
