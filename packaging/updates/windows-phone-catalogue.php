<?php
/** Privileged, bounded metadata refresh. No DB/config credentials and no package installation. */
final class windows_phone_catalogue_busy extends RuntimeException {}
final class windows_phone_catalogue_failure extends RuntimeException {public function __construct(public readonly string $publicationState,Throwable $primary,public readonly bool $observationFailed=false){parent::__construct('Windows phone catalogue refresh did not complete.',0,$primary);}}
class windows_phone_catalogue_refresh {
    public function __construct(protected string $web,protected string $state,protected string $maintenance,protected string $platform=PHP_OS_FAMILY){}
    protected function now():DateTimeImmutable{return new DateTimeImmutable('now',new DateTimeZone('UTC'));}
    protected function path():string{return$this->state.'/windows-phone-catalogue';}
    protected function key():string{return$this->web.'/resources/windows-phone/release-public.pem';}
    private function read(string $path,int $max):string{return pbx_windows_phone_catalogue::read($path,$max);}
    public static function assertExclusive(string $path):void{
        pbx_windows_phone_catalogue::read($path,1048576);$handle=@fopen($path,'r+b');if(!$handle)throw new RuntimeException('The parent catalogue lease could not be observed.');
        try{$wouldBlock=0;if(flock($handle,LOCK_SH|LOCK_NB,$wouldBlock)){flock($handle,LOCK_UN);throw new RuntimeException('An exclusive parent catalogue lease is required.');}if($wouldBlock!==1)throw new RuntimeException('The parent catalogue lease was not verified.');}finally{fclose($handle);}
    }
    protected function held():bool{
        foreach([$this->state.'/updates/maintenance',$this->state.'/call-records.hold']as$path)if(file_exists($path)||is_link($path))return true;
        $restore=$this->state.'/backup-restore';if(is_dir($restore)){foreach(scandir($restore)?:[]as$name)if(str_starts_with($name,'hold-'))return true;}
        foreach([$this->state.'/updates/install-journal.json'=>['completed','rolled_back'],$restore.'/journal.json'=>['restored','recovered']]as$path=>$terminal){
            if(!file_exists($path)&&!is_link($path))continue;
            $record=pbx_windows_phone_catalogue::object($this->read($path,1048576),1048576);if(!isset($record->state)||!is_string($record->state)||!in_array($record->state,$terminal,true))return true;
            if($record->state==='completed'&&property_exists($record,'finalization')){
                // Debian's durable finalizer writes the exact string; Windows
                // retains its separately typed phase/failure record.
                if($this->platform==='Windows'){if(!$record->finalization instanceof stdClass||($record->finalization->phase??null)!=='complete'||($record->finalization->failed??null)!==false)return true;}
                elseif($record->finalization!=='completed')return true;
            }
        }
        return false;
    }
    private function lock(string $path){
        // Existing shared maintenance file only. Installation owns its creation/ACL.
        $this->read($path,1048576);$handle=@fopen($path,'r+b');if(!$handle)throw new RuntimeException('The catalogue maintenance lease is unavailable.');
        $wouldBlock=0;if(!flock($handle,LOCK_EX|LOCK_NB,$wouldBlock)){fclose($handle);if($wouldBlock===1)throw new windows_phone_catalogue_busy('The catalogue maintenance lease is busy.');throw new RuntimeException('The catalogue maintenance lease was refused.');}return$handle;
    }
    protected function fetch():string{
        if(!function_exists('curl_init'))throw new RuntimeException('The verified catalogue transport is unavailable.');
        $url=pbx_windows_phone_catalogue::FEED;$deadline=microtime(true)+45;
        for($redirect=0;$redirect<=5;$redirect++){
            $part=parse_url($url);$host=$part['host']??'';$path=$part['path']??'';
            if(($part['scheme']??'')!=='https'||($part['port']??443)!==443||isset($part['user'])||isset($part['pass'])||isset($part['fragment'])||strlen($url)>16384||!in_array($host,['github.com','release-assets.githubusercontent.com','objects.githubusercontent.com'],true)||($host==='github.com'&&$path!=='/embire2/openwebpbx/releases/download/windows-phone-stable/windows-phone-update-manifest.json'))throw new RuntimeException('The catalogue transport destination was refused.');
            $remaining=(int)ceil($deadline-microtime(true));if($remaining<=0)throw new RuntimeException('The catalogue transport deadline expired.');$body='';$location=null;$headers=0;$curl=curl_init($url);
            curl_setopt_array($curl,[CURLOPT_FOLLOWLOCATION=>false,CURLOPT_PROXY=>'',CURLOPT_CONNECTTIMEOUT=>min(15,$remaining),CURLOPT_TIMEOUT=>$remaining,CURLOPT_SSL_VERIFYPEER=>true,CURLOPT_SSL_VERIFYHOST=>2,CURLOPT_PROTOCOLS=>CURLPROTO_HTTPS,CURLOPT_USERAGENT=>'OpenWebPBX-WindowsPhoneCatalogue/1',CURLOPT_WRITEFUNCTION=>static function($curl,string $bytes)use(&$body):int{if(strlen($body)+strlen($bytes)>pbx_windows_phone_catalogue::MAX_ENVELOPE)return 0;$body.=$bytes;return strlen($bytes);},CURLOPT_HEADERFUNCTION=>static function($curl,string $header)use(&$location,&$headers):int{$headers+=strlen($header);if($headers>32768)return 0;if(strncasecmp($header,'Location:',9)===0)$location=trim(substr($header,9));return strlen($header);}]);
            try{$ok=curl_exec($curl);$status=curl_getinfo($curl,CURLINFO_RESPONSE_CODE);if($ok===false)throw new RuntimeException('The catalogue transport failed.');}finally{curl_close($curl);}
            if(in_array($status,[301,302,303,307,308],true)){if(!is_string($location)||!str_starts_with($location,'https://'))throw new RuntimeException('The catalogue redirect was refused.');$url=$location;continue;}
            if($status!==200)throw new RuntimeException('The catalogue is not published.');return$body;
        }
        throw new RuntimeException('The catalogue redirect limit was exceeded.');
    }
    protected function commit(string $temporary,string $destination):void{
        if(basename($destination)==='accepted.json'&&basename($temporary)!==pbx_windows_phone_catalogue::acceptedStage($this->read($temporary,pbx_windows_phone_catalogue::MAX_CACHE)))throw new RuntimeException('The accepted catalogue stage changed before publication.');
        if($this->platform==='Windows'){
            $powershell=(getenv('SystemRoot')?:'C:/Windows').'/System32/WindowsPowerShell/v1.0/powershell.exe';$helper='C:/OpenWebPBX/tools/WindowsPhoneCatalogue.ps1';
            $process=proc_open([$powershell,'-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',$helper,'-Action','Commit','-StagePath',$temporary,'-TargetName',basename($destination)],[0=>['pipe','r'],1=>['file','NUL','w'],2=>['file','NUL','w']],$pipes);if(!is_resource($process))throw new RuntimeException('The catalogue commit helper is unavailable.');fclose($pipes[0]);if(proc_close($process)!==0)throw new RuntimeException('The catalogue durable commit failed.');
        }else{
            if(!rename($temporary,$destination))throw new RuntimeException('The catalogue commit failed.');$this->flushDirectory(dirname($destination));
        }
    }
    protected function flushDirectory(string $path):void{$directory=fopen($path,'r');if(!$directory)throw new RuntimeException('The catalogue directory flush failed.');try{if(!fsync($directory))throw new RuntimeException('The catalogue directory flush failed.');}finally{fclose($directory);}}
    private function write(string $bytes,string $destination):void{
        $name=basename($destination)==='accepted.json'?pbx_windows_phone_catalogue::acceptedStage($bytes):'.publication-'.bin2hex(random_bytes(16)).'.new';$temporary=$this->path().'/'.$name;$file=fopen($temporary,'xb');if(!$file)throw new RuntimeException('The catalogue stage could not be created.');
        $primary=null;
        try{try{if(!chmod($temporary,0640)||fwrite($file,$bytes)!==strlen($bytes)||!fflush($file)||!fsync($file))throw new RuntimeException('The catalogue stage could not be flushed.');}finally{fclose($file);}$this->commit($temporary,$destination);}
        catch(Throwable $error){$primary=$error;throw$error;}
        finally{if(is_file($temporary)){try{if($this->read($temporary,pbx_windows_phone_catalogue::MAX_JOURNAL)!==$bytes)throw new RuntimeException('Changed catalogue stage was preserved.');if(!unlink($temporary))throw new RuntimeException('The owned catalogue stage could not be removed.');}catch(Throwable $cleanup){if($primary===null)throw$cleanup;}}}
    }
    private function present(string $name):bool{$names=@scandir($this->path());if($names===false)throw new RuntimeException('The catalogue directory could not be observed.');return in_array($name,$names,true);}
    private function journal(array $record):string{return json_encode($record,JSON_THROW_ON_ERROR|JSON_UNESCAPED_SLASHES)."\n";}
    protected function observe(string $key,?string $before,?string $candidate):string{
        if($this->present('publication.json')){$j=pbx_windows_phone_catalogue::publication($this->read($this->path().'/publication.json',pbx_windows_phone_catalogue::MAX_JOURNAL),$key,$this->now());$actual=$this->present('accepted.json')?hash('sha256',$this->read($this->path().'/accepted.json',pbx_windows_phone_catalogue::MAX_CACHE)):null;if($j['state']==='committed'&&hash('sha256',$j['candidate'])===$actual){if($candidate!==null&&$candidate===$actual)return'committed_valid';return$before===$actual?'not_committed':'committed_valid';}return'indeterminate';}
        if(!$this->present('accepted.json'))return$before===null?'not_committed':'indeterminate';return$before!==null&&hash_equals($before,hash('sha256',$this->read($this->path().'/accepted.json',pbx_windows_phone_catalogue::MAX_CACHE)))?'not_committed':'indeterminate';
    }
    /** Caller is root/SYSTEM; Windows helper owns protected directory provisioning. */
    public function run(?string $import=null):array{
        if($this->platform!=='Windows'&&(!function_exists('posix_geteuid')||posix_geteuid()!==0))throw new RuntimeException('Catalogue refresh requires the installation owner.');
        $maintenance=$this->lock($this->maintenance);$local=null;$key=null;$before=null;$candidate=null;
        try{
            if($this->held())throw new windows_phone_catalogue_busy('A restore or update holds catalogue refresh.');
            $directory=$this->path();$info=@lstat($directory);if(!$info||($info['mode']&0170000)!==0040000||is_link($directory))throw new RuntimeException('The protected catalogue directory is unavailable.');
            $key=$this->read($this->key(),16384);pbx_windows_phone_catalogue::directory($directory,$key);
            $local=$this->lock($directory.'/refresh.lock');pbx_windows_phone_catalogue::directory($directory,$key);$destination=$directory.'/accepted.json';$journalPath=$directory.'/publication.json';$previous=null;
            if($this->present('accepted.json'))$before=hash('sha256',$this->read($destination,pbx_windows_phone_catalogue::MAX_CACHE));
            if($this->present('publication.json')){
                $pending=pbx_windows_phone_catalogue::publication($this->read($journalPath,pbx_windows_phone_catalogue::MAX_JOURNAL),$key,$this->now());$candidateHash=hash('sha256',$pending['candidate']);
                if($pending['state']==='prepared'){
                    if($before!==$candidateHash&&$before!==$pending['previous_sha256'])throw new RuntimeException('The pending publication conflicts with retained catalogue state.');
                    $candidate=$candidateHash;
                    $stageName=pbx_windows_phone_catalogue::acceptedStage($pending['candidate']);
                    if($before===$candidateHash&&$this->present($stageName))throw new RuntimeException('A duplicate accepted catalogue stage was preserved for review.');
                    if($before!==$candidateHash){if($this->present($stageName))$this->commit($directory.'/'.$stageName,$destination);else$this->write($pending['candidate'],$destination);}
                    if(hash('sha256',$this->read($destination,pbx_windows_phone_catalogue::MAX_CACHE))!==$candidateHash)throw new RuntimeException('The recovered accepted catalogue differs from its pinned journal.');
                    $done=['schema'=>1,'component'=>pbx_windows_phone_catalogue::COMPONENT,'key_id'=>pbx_windows_phone_catalogue::KEY_ID,'state'=>'committed','previous_sha256'=>$pending['previous_sha256'],'candidate'=>$pending['candidate']];$this->write($this->journal($done),$journalPath);$before=$candidateHash;
                }elseif($before!==$candidateHash)throw new RuntimeException('The committed publication differs from retained catalogue state.');
            }elseif($before!==null)throw new RuntimeException('The catalogue is missing its durable publication record.');
            if($this->present('accepted.json')){$old=pbx_windows_phone_catalogue::accepted($this->read($destination,pbx_windows_phone_catalogue::MAX_CACHE),$key,$this->now(),false);$previous=['sequence'=>$old['sequence'],'payload_sha256'=>$old['payload_sha256'],'version'=>$old['version']];}
            $envelope=$import===null?$this->fetch():$this->read($import,pbx_windows_phone_catalogue::MAX_ENVELOPE);$release=pbx_windows_phone_catalogue::verify($envelope,$key,$previous,$this->now());
            $record=['schema'=>1,'component'=>pbx_windows_phone_catalogue::COMPONENT,'key_id'=>pbx_windows_phone_catalogue::KEY_ID,'envelope'=>$envelope,'sequence'=>$release['sequence'],'payload_sha256'=>$release['payload_sha256'],'version'=>$release['version'],'accepted_at'=>$this->now()->format('Y-m-d\TH:i:s\Z')];$bytes=json_encode($record,JSON_THROW_ON_ERROR|JSON_UNESCAPED_SLASHES)."\n";$candidate=hash('sha256',$bytes);
            $publication=['schema'=>1,'component'=>pbx_windows_phone_catalogue::COMPONENT,'key_id'=>pbx_windows_phone_catalogue::KEY_ID,'state'=>'prepared','previous_sha256'=>$before,'candidate'=>$bytes];$this->write($this->journal($publication),$journalPath);$this->write($bytes,$destination);$verified=pbx_windows_phone_catalogue::accepted($this->read($destination,pbx_windows_phone_catalogue::MAX_CACHE),$key,$this->now());if($verified['payload_sha256']!==$release['payload_sha256'])throw new RuntimeException('The committed catalogue differs.');$publication['state']='committed';$this->write($this->journal($publication),$journalPath);
            return['schema'=>1,'state'=>'accepted','component'=>pbx_windows_phone_catalogue::COMPONENT,'version'=>$release['version'],'sequence'=>$release['sequence']];
        }catch(windows_phone_catalogue_busy $busy){throw$busy;}catch(Throwable $primary){$state='indeterminate';$observationFailed=false;try{if($key!==null)$state=$this->observe($key,$before,$candidate);}catch(Throwable){$observationFailed=true;}throw new windows_phone_catalogue_failure($state,$primary,$observationFailed);}finally{if(is_resource($local)){flock($local,LOCK_UN);fclose($local);}flock($maintenance,LOCK_UN);fclose($maintenance);}
    }
}
if(PHP_SAPI==='cli'&&realpath($_SERVER['SCRIPT_FILENAME']??'')===__FILE__){
    try{
        $web=PHP_OS_FAMILY==='Windows'?'C:/OpenWebPBX/web':'/var/www/fusionpbx';define('PROJECT_ROOT',$web);require_once $web.'/resources/classes/pbx_paths.php';require_once $web.'/resources/classes/pbx_windows_phone_catalogue.php';
        if(count($argv)===2&&$argv[1]==='--assert-exclusive'){windows_phone_catalogue_refresh::assertExclusive(pbx_paths::state().'/upgrade.lock');echo '{"schema":1,"state":"exclusive_parent_held"}'."\n";exit(0);}
        if(count($argv)===2&&$argv[1]==='--prepared-stage-check'){$key=pbx_windows_phone_catalogue::read($web.'/resources/windows-phone/release-public.pem',16384);$stage=pbx_windows_phone_catalogue::preparedStage(pbx_paths::state().'/windows-phone-catalogue',$key);echo json_encode(['schema'=>1,'state'=>$stage===null?'ready':'prepared_stage','stage'=>$stage],JSON_THROW_ON_ERROR)."\n";exit(0);}
        if(count($argv)===3&&$argv[1]==='--rollback-check'){$key=pbx_windows_phone_catalogue::read($web.'/resources/windows-phone/release-public.pem',16384);pbx_windows_phone_catalogue::assertRollback(pbx_paths::state().'/windows-phone-catalogue',$argv[2],$key);echo '{"schema":1,"state":"rollback_allowed"}'."\n";exit(0);}
        $import=null;if(count($argv)!==1){if(count($argv)!==3||$argv[1]!=='--import')throw new InvalidArgumentException('Use the installed catalogue refresh command.');$import=$argv[2];}
        $worker=new windows_phone_catalogue_refresh($web,pbx_paths::state(),PHP_OS_FAMILY==='Windows'?pbx_paths::state().'/upgrade.lock':'/run/openwebpbx-upgrade.lock');echo json_encode($worker->run($import),JSON_THROW_ON_ERROR)."\n";
    }catch(windows_phone_catalogue_busy){echo '{"schema":1,"state":"deferred"}'."\n";exit(0);}catch(windows_phone_catalogue_failure $failure){echo json_encode(['schema'=>1,'state'=>'failed','publication_state'=>$failure->publicationState,'observation_failed'=>$failure->observationFailed])."\n";exit(1);}catch(Throwable){fwrite(STDERR,"Windows phone catalogue refresh was refused before its result could be verified.\n");exit(1);}
}
