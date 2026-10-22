<?php
/** QA-only complete public/namespace digest. No framework or connection side effects. */
function windows_health_preservation(PDO $db): array {
 $hash=hash_init('sha256');$total=0;$tables=0;$objectsOut=[];
 $feed=static function(string $value)use($hash,&$total):void{$total+=strlen($value);if($total>268435456)throw new RuntimeException('Bounded disposable factory inventory required.');hash_update($hash,pack('N',strlen($value)).$value);};
 $feedPart=static function(HashContext $part,string $value)use($feed):void{$feed($value);hash_update($part,pack('N',strlen($value)).$value);};
 foreach($db->query("select nspname,nspowner,nspacl from pg_namespace order by nspname")->fetchAll(PDO::FETCH_ASSOC)as$row)$feed(json_encode($row,JSON_THROW_ON_ERROR));
 $namespaceHash=hash_final(hash_copy($hash));
 $objects=$db->query("select c.oid,c.relname,c.relkind,c.relowner,c.relacl,c.relnatts from pg_class c join pg_namespace n on n.oid=c.relnamespace where n.nspname='public' and c.relkind in ('r','p','S','v','m','f') order by c.relname")->fetchAll(PDO::FETCH_ASSOC);
 foreach($objects as$object){
  $shape=hash_init('sha256');$data=hash_init('sha256');$count=0;
  $feedPart($shape,json_encode($object,JSON_THROW_ON_ERROR));$oid=(int)$object['oid'];
  $columns=$db->query("select a.attnum,a.attname,format_type(a.atttypid,a.atttypmod) type,a.attnotnull,a.attidentity,a.attgenerated,a.attisdropped,pg_get_expr(d.adbin,d.adrelid) default_value from pg_attribute a left join pg_attrdef d on d.adrelid=a.attrelid and d.adnum=a.attnum where a.attrelid=$oid and a.attnum>0 order by a.attnum")->fetchAll(PDO::FETCH_ASSOC);$feedPart($shape,json_encode($columns,JSON_THROW_ON_ERROR));
  $constraints=$db->query("select conname,pg_get_constraintdef(oid) definition from pg_constraint where conrelid=$oid order by conname")->fetchAll(PDO::FETCH_ASSOC);$feedPart($shape,json_encode($constraints,JSON_THROW_ON_ERROR));
  $indexes=$db->query("select pg_get_indexdef(indexrelid) definition from pg_index where indrelid=$oid order by indexrelid")->fetchAll(PDO::FETCH_ASSOC);$feedPart($shape,json_encode($indexes,JSON_THROW_ON_ERROR));
  $name='public."'.str_replace('"','""',$object['relname']).'"';
  if($object['relkind']==='f')throw new RuntimeException('A disposable factory may not use foreign tables.');
  if(in_array($object['relkind'],['r','p','m'],true)){
   $tables++;$rows=$db->query('select to_jsonb(t)::text row_value from '.$name.' t order by to_jsonb(t)::text');
   while(($row=$rows->fetch(PDO::FETCH_ASSOC))!==false){if(++$count>100000||strlen($row['row_value'])>16777216)throw new RuntimeException('Bounded disposable factory rows required.');$feedPart($data,$row['row_value']);}
   $feedPart($data,'rows:'.$count);
  }elseif($object['relkind']==='S'){$feedPart($data,json_encode($db->query('select last_value,is_called from '.$name)->fetch(PDO::FETCH_ASSOC),JSON_THROW_ON_ERROR));}
  elseif($object['relkind']==='v'){$feedPart($shape,(string)$db->query("select pg_get_viewdef($oid,true)")->fetchColumn());}
  $objectsOut[$object['relname']]=['kind'=>$object['relkind'],'shape_sha256'=>hash_final($shape),'data_sha256'=>hash_final($data),'rows'=>$count];
 }
 return ['state'=>'observed','public_preservation_sha256'=>hash_final($hash),'tables'=>$tables,'complete_public_rows'=>true,'complete_namespace_inventory'=>true,'namespace_sha256'=>$namespaceHash,'objects'=>$objectsOut];
}
