<?php
/** Portable actual PHP/file controls; PDO rows and pbx_paths are explicit adapters. */
require_once __DIR__.'/windows_threecx_https_fixture.php';
require_once __DIR__.'/windows_threecx_fixture.php';
class pbx_paths {
    public static string $root;
    public static function uploads():string{return self::$root.'/uploads';}
    public static function media():string{return self::$root.'/media';}
    public static function voicemail():string{return self::$root.'/voicemail';}
    public static function contains(string $root,string $path):bool{return str_starts_with($path,rtrim($root,'/').'/');}
}
final class SyntheticRows {
    public function __construct(private mixed $value){}
    public function fetch(int $mode):mixed{return $this->value;}
    public function fetchAll(int $mode):array{return $this->value;}
    public function fetchColumn():mixed{return $this->value;}
}
class event_socket {
    public static array $rows=[];
    public static string $reply='error/user_not_registered';
    public static bool $throws=false;
    public static function api(string $command):string {
        if(self::$throws)throw new RuntimeException('Explicit engine API adapter failure.');
        if($command==='show registrations as json')return json_encode(['row_count'=>count(self::$rows),'rows'=>self::$rows],JSON_THROW_ON_ERROR);
        if(str_starts_with($command,'sofia_contact '))return self::$reply;
        if($command==='sofia status profile internal')return "SIP-IP 127.0.0.1\n";
        throw new RuntimeException('Foreign adapter command refused.');
    }
}
$checks=0;
function check(bool $value):void{global $checks;if(!$value)throw new RuntimeException('Portable synthetic control failed.');$checks++;}
function refuses(callable $operation):void{try{$operation();}catch(RuntimeException){check(true);return;}throw new RuntimeException('Expected synthetic refusal missing.');}
$root=sys_get_temp_dir().'/openweb-threecx-https-'.bin2hex(random_bytes(16));mkdir($root,0700);pbx_paths::$root=$root;
$remove=function(string $path)use(&$remove):void{if(is_link($path)||is_file($path)){unlink($path);return;}foreach(new DirectoryIterator($path) as $entry){if(!$entry->isDot())$remove($entry->getPathname());}rmdir($path);};
try{
    $fixture=windows_threecx_fixture($root);$domain='12345678-1234-1234-1234-123456789abc';$realm='pbx-aaaaaaaaaaaa.example.invalid';
    $s=['factory_admin'=>['user_uuid'=>'fake-owner'],'import_fixture'=>['draft_uuid'=>'fake-draft','users'=>$fixture['users'],'media'=>array_map(static fn($bytes)=>hash('sha256',$bytes),$fixture['media'])]];
    $c=['users'=>['9100'=>['auth_id'=>$fixture['users'][0]['auth'],'greetings'=>[['id'=>'100']]],'9101'=>['auth_id'=>$fixture['users'][1]['auth']]],'ring_groups'=>[['number'=>'9180','members'=>[['number'=>'9101'],['number'=>'9100']]]]];
    $rows=['draft'=>['user_uuid'=>'fake-owner','kind'=>'import','completed_domain_uuid'=>$domain,'payload_ciphertext'=>null],
        'extensions'=>[],'tuples'=>[],'extension_count'=>2,'gateway_count'=>1,'gateway_enabled'=>0,'destination_enabled'=>0,'lines'=>[], 'media'=>[]];
    foreach($fixture['users'] as $index=>$user){$rows['extensions'][$user['auth']]=['extension_uuid'=>'fictional-'.$index,'extension'=>$user['auth'],'password'=>$user['password'],'accountcode'=>$realm,'user_context'=>$realm,'effective_caller_id_number'=>$user['number']];$rows['tuples'][]=array_intersect_key($rows['extensions'][$user['auth']],array_flip(['extension_uuid','extension','password']));}
    $rows['lines'][]=['user_id'=>'9100','auth_id'=>$fixture['users'][0]['auth'],'password'=>$fixture['users'][0]['password'],'server_address'=>$realm];
    mkdir(pbx_paths::media().'/'.$domain,0700,true);mkdir(pbx_paths::voicemail().'/default/'.$realm.'/9100',0700,true);
    foreach($fixture['media'] as $source=>$bytes){$path=pbx_paths::media().'/'.$domain.'/'.count($rows['media']).'.wav';file_put_contents($path,$bytes);$rows['media'][]=['source_path'=>$source,'file_path'=>$path];}
    $greeting=pbx_paths::voicemail().'/default/'.$realm.'/9100/greeting_100.wav';file_put_contents($greeting,$fixture['media']['vmailprompts/9100/custom greeting.wav']);
    $queries=[];$q=static function(string $sql,array $args)use(&$rows,&$queries,$domain):SyntheticRows {
        $queries[]=$sql;check(str_starts_with($sql,'select '));
        if(str_contains($sql,'from v_pbx_setup_drafts'))return new SyntheticRows($rows['draft']);
        check($args[0]===$domain);
        return new SyntheticRows(match(true){
            str_contains($sql,'effective_caller_id_number')=>$rows['extensions'][$args[1]],
            str_contains($sql,'extension_uuid,extension,password from')=>$rows['tuples'],
            str_contains($sql,'count(*) from v_extensions')=>$rows['extension_count'],
            str_contains($sql,"from v_gateways where domain_uuid=? and enabled='true'")=>$rows['gateway_enabled'],
            str_contains($sql,'count(*) from v_gateways')=>$rows['gateway_count'],
            str_contains($sql,'count(*) from v_destinations')=>$rows['destination_enabled'],
            str_contains($sql,'from v_device_lines')=>$rows['lines'],
            str_contains($sql,'from v_pbx_media')=>$rows['media'],
            default=>throw new RuntimeException('Unknown synthetic query adapter.')});
    };
    $saved=0;$save=static function()use(&$saved):void{$saved++;};
    $run=static function()use(&$s,&$c,$domain,$realm,$q,$save):void{ob_start();try{windows_threecx_https_discover($s,$c,$domain,$realm,$q,$save);$report=json_decode(ob_get_contents(),true,32,JSON_THROW_ON_ERROR);check($report===['original_credentials_exact'=>true,'phone_line_exact'=>true,'restored_media_exact'=>true,'provider_disabled'=>true,'owned_draft_completed'=>true]);}finally{ob_end_clean();}};
    $run();check($s['users'][0]['password']===$fixture['users'][0]['password']&&$s['users'][1]['password']===$fixture['users'][1]['password']);
    $s0=$s;$r0=$rows;$c0=$c;
    foreach(['password','extension','effective_caller_id_number','accountcode','user_context'] as $field){$rows=$r0;$s=$s0;$rows['extensions'][$fixture['users'][0]['auth']][$field]='changed';refuses($run);}
    foreach(['user_uuid','kind','completed_domain_uuid','payload_ciphertext'] as $field){$rows=$r0;$s=$s0;$rows['draft'][$field]='changed';refuses($run);}
    foreach(['user_id','auth_id','password','server_address'] as $field){$rows=$r0;$s=$s0;$rows['lines'][0][$field]='changed';refuses($run);}
    foreach(['extension_count'=>3,'gateway_count'=>0,'gateway_enabled'=>1,'destination_enabled'=>1] as $field=>$value){$rows=$r0;$s=$s0;$rows[$field]=$value;refuses($run);}
    $rows=$r0;$s=$s0;$c=$c0;$c['users']['9100']['auth_id']='wrong';refuses($run);
    $c=$c0;$c['ring_groups'][0]['members']=array_reverse($c['ring_groups'][0]['members']);refuses($run);
    $c=$c0;$c['ring_groups'][0]['number']='wrong';refuses($run);
    $c=$c0;$s['original_phone_tuples'][0]['password']='wrong';refuses($run);
    $s=$s0;file_put_contents($greeting,'changed');refuses($run);file_put_contents($greeting,$fixture['media']['vmailprompts/9100/custom greeting.wav']);
    $rows=$r0;file_put_contents($rows['media'][0]['file_path'],'changed');refuses($run);file_put_contents($rows['media'][0]['file_path'],array_values($fixture['media'])[0]);
    $rows=$r0;$rows['media'][0]['file_path']=$root.'/synthetic V20.zip';refuses($run);$rows=$r0;$run();
    // The original review negative: replace one required source with a duplicate.
    $rows=$r0;$rows['media'][1]=$rows['media'][0];refuses($run);
    $rows=$r0;$rows['media'][1]['source_path']='unknown.wav';refuses($run);
    $rows=$r0;array_pop($rows['media']);refuses($run);
    $rows=$r0;$rows['media'][1]['file_path']=$rows['media'][0]['file_path'];refuses($run);
    $rows=$r0;$outside=$root.'/outside.wav';copy($rows['media'][0]['file_path'],$outside);
    $link=pbx_paths::media().'/'.$domain.'/linked';symlink($root,$link);
    $rows['media'][0]['file_path']=$link.'/outside.wav';refuses($run);unlink($link);unlink($outside);$rows=$r0;$run();
    // Real filesystem ownership/retention, with no database or service adapter.
    $s=['import_fixture'=>['archive_sha256'=>hash_file('sha256',$fixture['archive']),'uploads_before'=>[],'uploads_existed'=>false]];
    check(windows_threecx_https_inventory(pbx_paths::uploads())===[]);mkdir(pbx_paths::uploads(),0700);
    $name='12345678-1234-1234-1234-123456789abc.zip';$upload=pbx_paths::uploads().'/'.$name;copy($fixture['archive'],$upload);
    windows_threecx_https_uploads($s,$save);check($s['import_fixture']['uploaded_name']===$name&&file_exists($upload));
    file_put_contents($upload,'changed');refuses(static function()use(&$s,$save):void{windows_threecx_https_uploads($s,$save,true);});check(file_exists($upload));copy($fixture['archive'],$upload);
    $foreign=pbx_paths::uploads().'/foreign.zip';copy($fixture['archive'],$foreign);refuses(static function()use(&$s,$save):void{windows_threecx_https_uploads($s,$save,true);});check(file_exists($upload)&&file_exists($foreign));unlink($foreign);
    windows_threecx_https_uploads($s,$save,true);check($s['import_upload_cleanup']===true&&!file_exists(pbx_paths::uploads()));
    mkdir(pbx_paths::uploads());symlink($fixture['archive'],$upload);$s['import_fixture']['uploads_existed']=true;
    refuses(static function()use(&$s,$save):void{windows_threecx_https_uploads($s,$save,true);});check(is_link($upload)&&is_file($fixture['archive']));unlink($upload);rmdir(pbx_paths::uploads());
    // Real durable intent and canonical cleanup hook; engine responses are adapters.
    $scope=str_repeat('a',24);$evidence=$root.'/'.$scope.'/evidence';mkdir($evidence,0700,true);
    $s=['scope'=>$scope,'evidence_directory'=>$evidence,'threecx_import_only'=>true,'native_diagnostics_only'=>true,
        'import_fixture'=>['archive_sha256'=>hash_file('sha256',$fixture['archive']),'uploads_before'=>[],'uploads_existed'=>false]];
    $intent=['schema'=>1,'realm'=>'foreign-'.$scope.'.example.invalid','aor'=>'9100','auth'=>'source-login-9100','address'=>'127.0.0.1','port'=>43210,'contact'=>'sip:9100@127.0.0.1:43210;transport=udp','call_id'=>str_repeat('c',32).'@fictional','tag'=>str_repeat('d',24)];
    $api=static fn(string $command):string=>event_socket::api($command);
    windows_threecx_https_foreign_prepare($s,$intent,$api);$intentFile=windows_threecx_https_foreign_file($s);
    check(json_decode(file_get_contents($intentFile),true,16,JSON_THROW_ON_ERROR)===$intent);
    $s['foreign_registration_intent']=$intent;$intentHash=hash_file('sha256',$intentFile);
    refuses(static function()use($s,$intent,$api):void{windows_threecx_https_foreign_prepare($s,$intent,$api);});check(hash_file('sha256',$intentFile)===$intentHash);
    $never=static function():void{throw new RuntimeException('Unexpected database or factory adapter invocation.');};
    $clean=static function()use(&$s,$never,$save):void{windows_threecx_https_before('cleanup',$s,$never,$save,$never);};
    foreach(['unregister_refused','unregister_exception','query_survivor','registration_timeout'] as $failedAttempt){
        unset($s['import_upload_cleanup']);event_socket::$rows=[['reg_user'=>'9100','realm'=>$intent['realm'],'url'=>$intent['contact']]];
        refuses($clean);check(!isset($s['import_upload_cleanup'])&&hash_file('sha256',$intentFile)===$intentHash);
    }
    event_socket::$rows=[['reg_user'=>'source-login-9100','realm'=>$realm,'url'=>'sofia/internal/'.$intent['contact']]];refuses($clean);check(!isset($s['import_upload_cleanup']));
    event_socket::$rows=[];event_socket::$reply='sofia/internal/'.$intent['contact'];refuses($clean);check(!isset($s['import_upload_cleanup']));
    event_socket::$reply='error/user_not_registered';event_socket::$throws=true;refuses($clean);check(!isset($s['import_upload_cleanup']));event_socket::$throws=false;
    // A neighbouring port is foreign state: read it, never mutate it or claim it.
    event_socket::$rows=[['reg_user'=>'9100','realm'=>'unrelated.example.invalid','url'=>'sip:9100@127.0.0.1:432101;transport=udp']];
    $clean();check($s['import_upload_cleanup']===true&&count(event_socket::$rows)===1);unset($s['import_upload_cleanup']);
    $bytes=file_get_contents($intentFile);unlink($intentFile);refuses($clean);check(!isset($s['import_upload_cleanup']));file_put_contents($intentFile,$bytes);
    $s['foreign_registration_intent']['port']=43211;refuses($clean);check(!isset($s['import_upload_cleanup']));$s['foreign_registration_intent']=$intent;
    event_socket::$rows=[];$clean();check($s['import_upload_cleanup']===true&&hash_file('sha256',$intentFile)===$intentHash);
    echo json_encode(['state'=>'passed','checks'=>$checks,'actual_php_and_files'=>true,'database_adapter'=>true,'native_windows'=>false],JSON_THROW_ON_ERROR),PHP_EOL;
}finally{$remove($root);}
