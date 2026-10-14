<?php
/** Source file/transaction checks with SQLite and real EC keys; no installed configuration. */
if(PHP_SAPI!=='cli')exit(2);
class pbx_paths {public static function host(): string{return 'fixture.example.invalid';}}
require dirname(__DIR__).'/resources/classes/pbx_mobile_push.php';
class store_check_database extends PDO {
    public function __construct(){parent::__construct('sqlite::memory:');$this->setAttribute(PDO::ATTR_ERRMODE,PDO::ERRMODE_EXCEPTION);$this->exec('create table v_pbx_mobile_push_config(singleton boolean primary key,enabled boolean,project_id text,client_config text)');}
    public function prepare(string $query,array $options=[]): PDOStatement|false{return parent::prepare(str_replace('?::jsonb','?',$query),$options);}
}
class store_check_push extends pbx_mobile_push {
    public function __construct(PDO $db,private string $path){parent::__construct($db);}
    protected function settingsPath(): string{return $this->path;}
    protected function authorized(): bool{return true;}
}
$dir=sys_get_temp_dir().'/openweb-push-store-'.bin2hex(random_bytes(6));mkdir($dir,0700);$path=$dir.'/config.json';$db=new store_check_database;$push=new store_check_push($db,$path);$checks=0;
$check=function(bool $ok,string $name)use(&$checks){if(!$ok)throw new RuntimeException($name);$checks++;};
$reject=function(callable $f,string $name)use($check){try{$f();}catch(Throwable){$check(true,$name);return;}$check(false,$name);};
try{
    $push->save(['enabled'=>true,'provider'=>'webpush','delivery'=>'direct']);$original=file_get_contents($path);$identity=json_decode($original,true,32,JSON_THROW_ON_ERROR);
    $check($push->client()['enabled']&&!empty($identity['vapid_private_key']),'Actual authorized save generates real VAPID identity');
    file_put_contents($path,"\xef\xbb\xbf".$original);chmod($path,0600);
    $check($push->view()['enabled']&&$push->view()['provider']==='webpush','Byte-preserved UTF8 BOM legacy settings are readable by PHP');
    $check(file_get_contents($path)==="\xef\xbb\xbf".$original,'Reading migrated settings preserves original bytes');
    $push->save(['enabled'=>true,'provider'=>'webpush']);$saved=json_decode(file_get_contents($path),true,32,JSON_THROW_ON_ERROR);
    $check($saved['vapid_private_key']===$identity['vapid_private_key']&&$saved['vapid_public_key']===$identity['vapid_public_key'],'First normal save retains both existing signing keys');
    $check(!str_contains(json_encode($push->view()),'PRIVATE KEY')&&$push->client()['vapid_public_key']===$identity['vapid_public_key'],'Safe state exposes only the unchanged public identity');
    $dbBefore=$db->query('select * from v_pbx_mobile_push_config')->fetchAll(PDO::FETCH_ASSOC);
    file_put_contents($path,'invalid-json');$reject(fn()=>$push->save(['enabled'=>false]),'Malformed configuration is refused rather than silently replaced');
    $check(file_get_contents($path)==='invalid-json'&&$db->query('select * from v_pbx_mobile_push_config')->fetchAll(PDO::FETCH_ASSOC)===$dbBefore,'Failed settings read preserves private bytes and database state');
    echo 'PASS: '.$checks." notification file, real VAPID and BOM-preservation checks\n";
}finally{foreach(glob($dir.'/*') as $file)unlink($file);rmdir($dir);}
