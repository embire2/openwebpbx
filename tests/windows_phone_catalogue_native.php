<?php
/** Disposable GHA-only shim. Real production methods; fixture path/fetch/clock adapters only. */
if(PHP_SAPI!=='cli'||PHP_OS_FAMILY!=='Windows')exit(2);
function catalogue_fixture_failure(Throwable $error):array{
    $source=basename($error->getFile());
    if(!in_array($source,['windows-phone-catalogue.php','windows_phone_catalogue_native.php','refresh.fixture.php','pbx_windows_phone_catalogue.php'],true))$source='external_component';
    $type=get_class($error);if(!in_array($type,['RuntimeException','InvalidArgumentException','UnexpectedValueException','JsonException','TypeError','ValueError','Error','ErrorException','windows_phone_catalogue_failure'],true))$type='external_error';
    $line=$error->getLine();if($line<0||$line>100000)$line=0;
    return ['schema'=>1,'producer'=>'windows_phone_catalogue_native.php','state'=>'failed','source_basename'=>$source,'source_line'=>$line,'error_type'=>$type];
}
try{

$configPath=__DIR__.'/fixture.json';
$config=json_decode(file_get_contents($configPath),true,16,JSON_THROW_ON_ERROR);
$root=str_replace('\\','/',$config['root']??'');$runner=rtrim(str_replace('\\','/',$config['runner_temp']??''),'/').'/';
// Scheduler SYSTEM children do not inherit the runner user's environment. The
// GHA-only driver creates this protected marker; the path/name adapters remain explicit.
if(($config['scope']??null)!=='disposable_github_actions_fixture'||$runner==='/'||!str_starts_with(strtolower($root),strtolower($runner))||!preg_match('~/OpenWebPBX-Catalogue-QA-[a-f0-9]{32}/case$~D',$root))throw new RuntimeException('Only the new disposable fixture is allowed.');
define('PROJECT_ROOT',$root.'/web');
require $config['catalogue_class'];
require $config['refresh_library'];
function fixture_write(string $path,string $bytes):void{if(file_exists($path)||is_link($path))throw new RuntimeException('Never replace fixture seed material.');$s=fopen($path,'xb');try{if(fwrite($s,$bytes)!==strlen($bytes)||!fflush($s)||!fsync($s))throw new RuntimeException('Fixture flush failed.');}finally{fclose($s);}if(!chmod($path,0640))throw new RuntimeException('Fixture chmod failed.');}
function fixture_ready(string $phase):void{echo json_encode(['schema'=>1,'state'=>'ready','phase'=>$phase,'pid'=>getmypid()],JSON_THROW_ON_ERROR)."\n";flush();$line=fgets(STDIN);if($line!==false&&trim($line)!=='release')throw new RuntimeException('The owned controller command differs.');}
final class catalogue_native_fixture extends windows_phone_catalogue_refresh {
    public function __construct(private array $fixture,private string $action){parent::__construct($fixture['root'].'/web',$fixture['root'].'/state',$fixture['root'].'/state/upgrade.lock','Windows');}
    protected function now():DateTimeImmutable{return new DateTimeImmutable($this->fixture['clock'],new DateTimeZone('UTC'));}
    protected function fetch():string{
        file_put_contents($this->fixture['root'].'/fetches.private.jsonl',json_encode(['action'=>$this->action,'pid'=>getmypid()])."\n",FILE_APPEND|LOCK_EX);
        if($this->action==='--hold')fixture_ready('both_leases');
        if(($this->fixture['scheduled_hold']??false)===true){
            fixture_write($this->fixture['root'].'/scheduled-ready.private.json',json_encode(['schema'=>1,'pid'=>getmypid()],JSON_THROW_ON_ERROR));$deadline=microtime(true)+20;
            while(!is_file($this->fixture['root'].'/scheduled-release')&&microtime(true)<$deadline){clearstatcache();usleep(100000);}
            if(!is_file($this->fixture['root'].'/scheduled-release'))throw new RuntimeException('Owned scheduled fixture release timed out.');
        }
        return pbx_windows_phone_catalogue::read($this->fixture['envelope'],pbx_windows_phone_catalogue::MAX_ENVELOPE);
    }
    protected function commit(string $stage,string $destination):void{
        if(basename($destination)==='accepted.json'&&$this->action==='--before-rename')fixture_ready('prepared_complete_stage');
        parent::commit($stage,$destination);
        if(basename($destination)==='accepted.json'&&$this->action==='--after-rename')fixture_ready('accepted_before_committed_journal');
    }
}
$action=$argv[1]??'--refresh';
try{
    $directory=$root.'/state/windows-phone-catalogue';
    if($action==='--seed'){
        // The ephemeral private key exists only in this process; no private key is written or exported.
        $key=openssl_pkey_new(['config'=>$config['openssl_config'],'private_key_type'=>OPENSSL_KEYTYPE_RSA,'private_key_bits'=>3072]);if(!$key)throw new RuntimeException('Fixture RSA generation failed.');
        $public=openssl_pkey_get_details($key)['key'];fixture_write($root.'/web/resources/windows-phone/release-public.pem',$public);
        for($sequence=1;$sequence<=5;$sequence++){
            $version='1.0.'.($sequence-1);$later=$sequence===5;
            $payload=['schema'=>1,'purpose'=>'windows-phone-release','component'=>'windows-free-phone','platform'=>'windows-x64','channel'=>'stable','version'=>$version,'sequence'=>$sequence,'published_at'=>$later?'2028-01-01T00:00:00Z':'2026-10-23T11:59:00Z','expires_at'=>$later?'2028-06-29T00:00:00Z':'2027-04-21T12:00:00Z','package'=>['url'=>'https://github.com/embire2/openwebpbx/releases/download/windows-phone-v'.$version.'/OpenWebPBX-Free-Phone-'.$version.'-win-x64.msixbundle','bytes'=>1000,'sha256'=>str_repeat('a',64),'identity'=>'Fictional.OpenWeb.CatalogueFixture','publisher'=>'CN=Fictional Catalogue Fixture']];
            $bytes=json_encode($payload,JSON_THROW_ON_ERROR|JSON_UNESCAPED_SLASHES);if(!openssl_sign($bytes,$signature,$key,OPENSSL_ALGO_SHA256))throw new RuntimeException('Fixture signing failed.');
            fixture_write($root.'/envelope-'.$sequence.'.json',json_encode(['algorithm'=>'rsa-sha256','key_id'=>'windows-phone-release-1','payload'=>base64_encode($bytes),'signature'=>base64_encode($signature)],JSON_THROW_ON_ERROR));
        }
        echo json_encode(['schema'=>1,'state'=>'seeded','ephemeral_rsa_bits'=>3072,'public_sha256'=>hash('sha256',$public),'private_key_persisted'=>false,'production_release_published'=>false])."\n";exit(0);
    }
    if($action==='--assert-exclusive'){windows_phone_catalogue_refresh::assertExclusive($root.'/state/upgrade.lock');echo '{"schema":1,"state":"exclusive_parent_held"}'."\n";exit(0);}
    if($action==='--prepared-stage-check'){$key=pbx_windows_phone_catalogue::read($root.'/web/resources/windows-phone/release-public.pem',16384);$stage=pbx_windows_phone_catalogue::preparedStage($directory,$key);echo json_encode(['schema'=>1,'state'=>$stage===null?'ready':'prepared_stage','stage'=>$stage],JSON_THROW_ON_ERROR)."\n";exit(0);}
    if($action==='--read'){
        $reader=new class($root,new DateTimeImmutable($config['clock'])) extends pbx_windows_phone_catalogue {
            public function __construct(private string $root,private DateTimeImmutable $clock){}
            protected function keyPath():string{return$this->root.'/web/resources/windows-phone/release-public.pem';}
            protected function cachePath():string{return$this->root.'/state/windows-phone-catalogue/accepted.json';}
            protected function now():DateTimeImmutable{return$this->clock;}
        };
        echo json_encode(['schema'=>1,'state'=>'observed','version'=>$reader->publishedVersion()])."\n";exit(0);
    }
    if(!in_array($action,['--refresh','--hold','--before-rename','--after-rename'],true))throw new RuntimeException('Unknown fixture action.');
    echo json_encode((new catalogue_native_fixture($config,$action))->run(),JSON_THROW_ON_ERROR)."\n";
}catch(windows_phone_catalogue_busy){echo '{"schema":1,"state":"deferred"}'."\n";exit(0);}catch(windows_phone_catalogue_failure $failure){echo json_encode(['schema'=>1,'state'=>'failed','publication_state'=>$failure->publicationState,'observation_failed'=>$failure->observationFailed])."\n";fwrite(STDERR,json_encode(catalogue_fixture_failure($failure->getPrevious()??$failure),JSON_THROW_ON_ERROR)."\n");exit(3);}
}catch(Throwable $failure){fwrite(STDERR,json_encode(catalogue_fixture_failure($failure),JSON_THROW_ON_ERROR)."\n");exit(4);}
