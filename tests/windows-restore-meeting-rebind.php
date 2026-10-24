<?php
/** Actual isolated PostgreSQL/rebind evidence; no installed configuration is loaded. */
if(PHP_SAPI!=='cli'||getenv('OPENWEB_MEETING_REBIND_TEST')!=='1')exit(2);
$input=json_decode(stream_get_contents(STDIN),true,16,JSON_THROW_ON_ERROR);
$temporary=$input['temporary']??'';
if(!is_string($temporary)||!preg_match('~^/tmp/openweb-meet-rebind-[a-z0-9_]+$~D',$temporary)
    ||!is_dir($temporary.'/socket')||!is_dir($temporary.'/data')||is_link($temporary))throw new RuntimeException('A new isolated fixture cluster is required.');
define('OPENWEB_RESTORE_FIXTURE_LIBRARY_ONLY',true);
require __DIR__.'/windows-restore-qualification.php';
require dirname(__DIR__).'/resources/classes/config.php';
require dirname(__DIR__).'/resources/classes/pbx_paths.php';
require dirname(__DIR__).'/resources/classes/pbx_meet_install.php';
$db=new PDO('pgsql:host='.$temporary.'/socket;port=55483;dbname=postgres','postgres',null,[PDO::ATTR_ERRMODE=>PDO::ERRMODE_EXCEPTION]);
if($db->query("select current_setting('data_directory')")->fetchColumn()!==$temporary.'/data'
    ||$db->query('select inet_server_addr() is null')->fetchColumn()!==true)
    throw new RuntimeException('Only this newly created socket-only cluster may be used.');
$db->exec('create table v_sip_profiles(sip_profile_uuid uuid primary key,sip_profile_name text,sip_profile_enabled boolean,custom_note text);
    create table v_conference_profiles(conference_profile_uuid uuid primary key,profile_name text,custom_note text);
    create table v_sip_profile_settings(sip_profile_setting_uuid uuid primary key,sip_profile_uuid uuid,sip_profile_setting_name text,sip_profile_setting_value text,sip_profile_setting_enabled boolean,sip_profile_setting_order integer,custom_payload jsonb)');
$key=str_repeat('K',32);$profile='cfb1c835-c30c-409b-bff7-a893a7e84df1';$conference='b26410e0-b732-4c72-b9cf-cc045c395a57';$foreign='22222222-2222-4222-8222-222222222222';
$configuration=static function(string $address,string $conf)use($temporary):void {
    // Actual config parser and pbx_paths; these values are entirely fictional.
    $file=$temporary.'/fixture.conf';
    file_put_contents($file,'document.root = "'.$temporary.'"'.PHP_EOL.'openweb.public_ip = "'.$address.'"'.PHP_EOL.'openweb.public_host = "fixture.example.invalid"'.PHP_EOL.'switch.conf.dir = "'.str_replace('\\','\\\\',$conf).'"'.PHP_EOL);
    config::$config=null;config::load($file);
};
$seed=static function(string $address,string $conf,bool $factory=false)use($db,$profile,$conference,$foreign,$configuration):void {
    $configuration($address,$conf);
    $db->exec('truncate v_sip_profile_settings,v_sip_profiles,v_conference_profiles');
    $q=$db->prepare('insert into v_sip_profiles values(?,?,?,?)');$q->execute([$profile,'openweb-meet','true','private installer']);$q->execute([$foreign,'customer-provider','true','preserve foreign profile']);
    $db->prepare('insert into v_conference_profiles values(?,?,?)')->execute([$conference,'openweb-meet','preserve conference']);
    $q=$db->prepare('insert into v_sip_profile_settings values(?,?,?,?,?,?,?::jsonb)');$n=1;
    foreach([$profile,$foreign] as $owner)foreach(['rtp-ip'=>$address,'ext-rtp-ip'=>$address,'tls-cert-dir'=>rtrim($conf,'/\\').'/tls/openweb-meet','auth-calls'=>'true','inbound-codec-prefs'=>'PCMU,PCMA,VP8'] as $name=>$value){
        $id=sprintf('%08d-1111-4111-8111-%012d',$factory?2:1,$n);
        $q->execute([$id,$owner,$name,$owner===$profile?$value:'customer-'.$name,'true',$n,json_encode(['custom'=>'kept','ordinal'=>$n,'nested'=>['enabled'=>true]])]);$n++;
    }
};
$rows=static fn(string $table):array=>array_map(static fn(string $r):mixed=>json_decode($r,false,512,JSON_THROW_ON_ERROR),$db->query('select row_to_json(t) from '.$table.' t')->fetchAll(PDO::FETCH_COLUMN));
$snapshot=static function(string $label)use($db,$key,$rows):array {
    $out=['label'=>$label,'schema_metadata'=>['schema'=>'fixture','tables'=>'fixture','columns'=>'fixture'],'target_owned'=>['cluster'=>'same-isolated-cluster'],
        'all_table_values'=>[],'scoped_values'=>[],'restore_projections'=>[],'source_phone_tuples'=>'unchanged-fixture-tuples'];
    foreach(['v_sip_profiles','v_conference_profiles','v_sip_profile_settings'] as $table){$values=$rows($table);$out['all_table_values'][$table]=['rows'=>count($values),'hmac'=>restore_fixture_rows_digest($values,$key)];
        if($table==='v_sip_profile_settings')$out['meeting_rebind']=restore_fixture_meeting_rebind($db,$values,$key);}
    return $out;
};
$sourceAddress='192.0.2.10';$targetAddress='198.51.100.20';$sourceConf='C:/SourcePBX/conf';$targetConf='C:/TargetPBX/conf';
$seed($targetAddress,$targetConf,true);$baseline=$snapshot('target-before');
$seed($sourceAddress,$sourceConf);$source=$snapshot('source');$originalRows=$rows('v_sip_profile_settings');
$configuration($targetAddress,$targetConf);$changed=pbx_meet_install::rebind($db);$target=$snapshot('target-restored');$targetRows=$rows('v_sip_profile_settings');
$deltas=[];foreach($targetRows as $row)foreach($originalRows as $old)if($row->sip_profile_setting_uuid===$old->sip_profile_setting_uuid){foreach(get_object_vars($row)as$field=>$value)if($value!=$old->$field)$deltas[]=[$row->sip_profile_uuid,$row->sip_profile_setting_name,$field];}
if($changed!==3||count($deltas)!==3)throw new RuntimeException('The actual product did not rebind exactly three rows.');
foreach($deltas as[$owner,$name,$field])if($owner!==$profile||!in_array($name,['rtp-ip','ext-rtp-ip','tls-cert-dir'],true)||$field!=='sip_profile_setting_value')throw new RuntimeException('The actual product changed an unowned cell.');
if(pbx_meet_install::rebind($db)!==0)throw new RuntimeException('The actual product rebind is not idempotent.');
$out=['source'=>$source,'baseline'=>$baseline,'target'=>$target,'actual_rebound_rows'=>$changed,'actual_delta_cells'=>$deltas,'idempotent'=>true,'refused'=>[],'mutated_snapshots'=>[]];
$mutations=[];
foreach(['rtp-ip','ext-rtp-ip','tls-cert-dir'] as $name){
    $where="sip_profile_uuid='$profile' and sip_profile_setting_name='$name'";
    $mutations['wrong_value_'.$name]="update v_sip_profile_settings set sip_profile_setting_value='arbitrary-unapproved-value' where $where";
    $mutations['disabled_'.$name]="update v_sip_profile_settings set sip_profile_setting_enabled=false where $where";
    $mutations['missing_'.$name]="delete from v_sip_profile_settings where $where";
    $mutations['renamed_'.$name]="update v_sip_profile_settings set sip_profile_setting_name='changed-name' where $where";
    $mutations['uuid_'.$name]="update v_sip_profile_settings set sip_profile_setting_uuid='99999999-9999-4999-8999-999999999999' where $where";
    $mutations['other_column_'.$name]="update v_sip_profile_settings set custom_payload='{\"custom\":\"changed\"}'::jsonb where $where";
    $mutations['foreign_'.$name]="update v_sip_profile_settings set sip_profile_setting_value='foreign-changed' where sip_profile_uuid='$foreign' and sip_profile_setting_name='$name'";
    $mutations['duplicate_'.$name]="insert into v_sip_profile_settings select '99999999-9999-4999-8999-999999999999',sip_profile_uuid,sip_profile_setting_name,sip_profile_setting_value,sip_profile_setting_enabled,sip_profile_setting_order,custom_payload from v_sip_profile_settings where $where";
}
$mutations += [
    'wrong_profile_uuid'=>"update v_sip_profile_settings set sip_profile_uuid='$foreign' where sip_profile_uuid='$profile' and sip_profile_setting_name='rtp-ip'",
    'owned_other_setting'=>"update v_sip_profile_settings set sip_profile_setting_value='false' where sip_profile_uuid='$profile' and sip_profile_setting_name='auth-calls'",
    'new_foreign_row'=>"insert into v_sip_profile_settings values('99999999-9999-4999-8999-999999999999','$foreign','new-value','added',true,99,'{}')",
    'delete_foreign_row'=>"delete from v_sip_profile_settings where sip_profile_uuid='$foreign' and sip_profile_setting_name='auth-calls'",
    'profile_name'=>"update v_sip_profiles set sip_profile_name='customer-profile' where sip_profile_uuid='$profile'",
    'profile_uuid'=>"update v_sip_profiles set sip_profile_uuid='99999999-9999-4999-8999-999999999999' where sip_profile_uuid='$profile'",
    'profile_duplicate'=>"insert into v_sip_profiles values('99999999-9999-4999-8999-999999999999','openweb-meet',true,'collision')",
    'profile_disabled'=>"update v_sip_profiles set sip_profile_enabled=false where sip_profile_uuid='$profile'",
    'profile_other_column'=>"update v_sip_profiles set custom_note='changed' where sip_profile_uuid='$profile'",
    'conference_name'=>"update v_conference_profiles set profile_name='changed' where conference_profile_uuid='$conference'",
    'conference_duplicate'=>"insert into v_conference_profiles values('99999999-9999-4999-8999-999999999999','openweb-meet','collision')",
    'conference_other_column'=>"update v_conference_profiles set custom_note='changed' where conference_profile_uuid='$conference'",
];
foreach($mutations as $name=>$sql){$db->beginTransaction();try{$db->exec($sql);try{$out['mutated_snapshots'][$name]=$snapshot('target-restored');}catch(RuntimeException $e){$out['refused'][]=$name;}}finally{$db->rollBack();}}
// Even a self-consistent actual rebind to the wrong address/path must fail the
// Python target-baseline comparison; accepting the table alone is insufficient.
foreach(['wrong_address'=>['203.0.113.77',$targetConf],'wrong_conf'=>[$targetAddress,'C:/Unapproved/conf']] as $name=>[$address,$conf]){
    $db->beginTransaction();try{$configuration($address,$conf);pbx_meet_install::rebind($db);$out['mutated_snapshots'][$name]=$snapshot('target-restored');}finally{$db->rollBack();$configuration($targetAddress,$targetConf);}}
$configuration($sourceAddress,$sourceConf);
try{$snapshot('target-restored');throw new LogicException('Unrebound local values were accepted.');}catch(RuntimeException $e){$out['refused'][]='stale_source_binding';}
$seed($sourceAddress,$targetConf);$samePathSource=$snapshot('source');$configuration($targetAddress,$targetConf);$addressOnly=pbx_meet_install::rebind($db);
if($addressOnly!==2)throw new RuntimeException('Two actual address changes were required when the native configuration path remains the same.');
$out['same_path']=['source'=>$samePathSource,'baseline'=>$baseline,'target'=>$snapshot('target-restored'),'actual_rebound_rows'=>$addressOnly];
echo json_encode($out,JSON_THROW_ON_ERROR|JSON_UNESCAPED_SLASHES),PHP_EOL;
