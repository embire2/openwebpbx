<?php
/** Signed Windows Phone release metadata only; never installs or fetches from an API request. */
class pbx_windows_phone_catalogue {
    public const FEED='https://github.com/embire2/openwebpbx/releases/download/windows-phone-stable/windows-phone-update-manifest.json';
    public const KEY_ID='windows-phone-release-1';
    public const COMPONENT='windows-free-phone';
    public const MAX_LIFETIME=366*86400;
    public const MAX_ENVELOPE=262144;
    public const MAX_CACHE=524288;
    public const MAX_JOURNAL=1048576;
    protected function keyPath():string{return PROJECT_ROOT.'/resources/windows-phone/release-public.pem';}
    protected function cachePath():string{return pbx_paths::state().'/windows-phone-catalogue/accepted.json';}
    protected function now():DateTimeImmutable{return new DateTimeImmutable('now',new DateTimeZone('UTC'));}
    private static function invalid():never{throw new UnexpectedValueException('Windows phone release metadata could not be verified.');}
    private static function exact(mixed $value,array $fields):stdClass{
        if(!$value instanceof stdClass)self::invalid();$actual=array_keys(get_object_vars($value));sort($actual);sort($fields);if($actual!==$fields)self::invalid();return$value;
    }
    /** json_decode alone loses duplicate fields. Walk valid JSON before accepting either signed object. */
    private static function unique(string $text,int &$at,int $depth=0):void{
        if($depth>8)self::invalid();$length=strlen($text);$space=static function()use($text,&$at,$length){while($at<$length&&str_contains(" \t\r\n",$text[$at]))$at++;};
        $string=static function()use($text,&$at,$length):string{$start=$at++;while($at<$length){$c=$text[$at++];if($c==='\\'){$at++;continue;}if($c==='"')return json_decode(substr($text,$start,$at-$start),false,2,JSON_THROW_ON_ERROR);}self::invalid();};
        $space();$c=$text[$at]??'';
        if($c==='{'){$at++;$space();$keys=[];if(($text[$at]??'')==='}'){$at++;return;}while(true){$space();if(($text[$at]??'')!=='"')self::invalid();$key=$string();if(isset($keys[$key]))self::invalid();$keys[$key]=true;$space();if(($text[$at++]??'')!==':')self::invalid();self::unique($text,$at,$depth+1);$space();$next=$text[$at++]??'';if($next==='}')return;if($next!==',')self::invalid();}}
        elseif($c==='['){$at++;$space();if(($text[$at]??'')===']'){$at++;return;}while(true){self::unique($text,$at,$depth+1);$space();$next=$text[$at++]??'';if($next===']')return;if($next!==',')self::invalid();}}
        elseif($c==='"'){$string();return;}
        else{while($at<$length&&!str_contains(",]} \t\r\n",$text[$at]))$at++;}
    }
    public static function object(string $bytes,int $maximum):stdClass{
        if($bytes===''||strlen($bytes)>$maximum||str_starts_with($bytes,"\xEF\xBB\xBF"))self::invalid();
        try{$value=json_decode($bytes,false,10,JSON_THROW_ON_ERROR);$at=0;self::unique($bytes,$at);if(trim(substr($bytes,$at))!=='')self::invalid();}catch(JsonException){self::invalid();}
        if(!$value instanceof stdClass)self::invalid();return$value;
    }
    private static function base64(mixed $value):string{if(!is_string($value)||$value==='')self::invalid();$bytes=base64_decode($value,true);if($bytes===false||base64_encode($bytes)!==$value)self::invalid();return$bytes;}
    public static function version(mixed $value):string{
        if(!is_string($value)||!preg_match('/^(0|[1-9][0-9]{0,4})\.(0|[1-9][0-9]{0,4})\.(0|[1-9][0-9]{0,4})$/D',$value))self::invalid();foreach(explode('.',$value)as$n)if((int)$n>65535)self::invalid();return$value;
    }
    public static function instant(mixed $value):DateTimeImmutable{
        if(!is_string($value)||!preg_match('/^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$/D',$value))self::invalid();
        $date=DateTimeImmutable::createFromFormat('!Y-m-d\TH:i:s\Z',$value,new DateTimeZone('UTC'));$errors=DateTimeImmutable::getLastErrors();
        if(!$date||($errors!==false&&($errors['warning_count']||$errors['error_count']))||$date->format('Y-m-d\TH:i:s\Z')!==$value)self::invalid();return$date;
    }
    /** Signature covers original bytes. $current=false is only for validating an expired high-water record. */
    public static function verify(string $envelope,string $publicKey,?array $previous=null,?DateTimeImmutable $now=null,bool $current=true):array{
        if(PHP_INT_SIZE!==8||strlen($publicKey)>16384||!str_starts_with($publicKey,'-----BEGIN PUBLIC KEY-----'))self::invalid();
        $outer=self::exact(self::object($envelope,self::MAX_ENVELOPE),['algorithm','key_id','payload','signature']);
        if($outer->algorithm!=='rsa-sha256'||$outer->key_id!==self::KEY_ID)self::invalid();$bytes=self::base64($outer->payload);$signature=self::base64($outer->signature);if(strlen($bytes)>65536)self::invalid();
        $key=openssl_pkey_get_public($publicKey);if(!$key)self::invalid();$details=openssl_pkey_get_details($key);
        if(!$details||$details['type']!==OPENSSL_KEYTYPE_RSA||$details['bits']<3072||strlen($signature)!==intdiv($details['bits']+7,8)||openssl_verify($bytes,$signature,$key,OPENSSL_ALGO_SHA256)!==1)self::invalid();
        $item=self::exact(self::object($bytes,65536),['schema','purpose','component','platform','channel','version','sequence','published_at','expires_at','package']);
        if(!is_int($item->schema)||$item->schema!==1||$item->purpose!=='windows-phone-release'||$item->component!==self::COMPONENT||$item->platform!=='windows-x64'||$item->channel!=='stable'||!is_int($item->sequence)||$item->sequence<1)self::invalid();
        $version=self::version($item->version);$published=self::instant($item->published_at);$expires=self::instant($item->expires_at);$now??=new DateTimeImmutable('now',new DateTimeZone('UTC'));
        $lifetime=$expires->getTimestamp()-$published->getTimestamp();if($lifetime<=0||$lifetime>self::MAX_LIFETIME||($current&&($published->getTimestamp()>$now->getTimestamp()+300||$expires<=$now)))self::invalid();
        $package=self::exact($item->package,['url','bytes','sha256','identity','publisher']);
        if($package->url!=='https://github.com/embire2/openwebpbx/releases/download/windows-phone-v'.$version.'/OpenWebPBX-Free-Phone-'.$version.'-win-x64.msixbundle'||!is_int($package->bytes)||$package->bytes<1000||$package->bytes>1073741824||!is_string($package->sha256)||!preg_match('/^[a-f0-9]{64}$/D',$package->sha256)||!is_string($package->identity)||!preg_match('/^[A-Za-z0-9.-]{3,50}$/D',$package->identity)||!is_string($package->publisher)||mb_strlen($package->publisher)<4||mb_strlen($package->publisher)>500||!str_starts_with($package->publisher,'CN=')||preg_match('/\p{Cc}/u',$package->publisher))self::invalid();
        $digest=hash('sha256',$bytes);
        if($previous!==null){if(array_keys($previous)!==['sequence','payload_sha256','version']||!is_int($previous['sequence'])||$previous['sequence']<1||!is_string($previous['payload_sha256'])||!preg_match('/^[a-f0-9]{64}$/D',$previous['payload_sha256']))self::invalid();self::version($previous['version']);if($item->sequence<$previous['sequence']||($item->sequence===$previous['sequence']&&!hash_equals($previous['payload_sha256'],$digest))||version_compare($version,$previous['version'],'<'))self::invalid();}
        return['version'=>$version,'sequence'=>$item->sequence,'payload_sha256'=>$digest,'published_at'=>$item->published_at,'expires_at'=>$item->expires_at,'package'=>get_object_vars($package)];
    }
    /** Protected source/cache are public metadata. Never follow a file link or accept writable Unix inputs. */
    public static function read(string $path,int $maximum):string{
        for($parent=$path;;$parent=dirname($parent)){clearstatcache(true,$parent);if(is_link($parent))self::invalid();$stat=@lstat($parent);if($stat===false)self::invalid();if(PHP_OS_FAMILY!=='Windows'&&($stat['uid']!==0||($stat['mode']&0022)!==0))self::invalid();if(dirname($parent)===$parent)break;}
        $before=@lstat($path);if(!$before||($before['mode']&0170000)!==0100000||($before['nlink']??0)!==1||$before['size']>$maximum)self::invalid();$stream=@fopen($path,'rb');if(!$stream)self::invalid();
        try{$opened=fstat($stream);$data=stream_get_contents($stream,$maximum+1);$after=fstat($stream);if($data===false||strlen($data)>$maximum||!$opened||!$after||$opened['dev']!==$before['dev']||$opened['ino']!==$before['ino']||$opened['size']!==strlen($data))self::invalid();foreach(['dev','ino','mode','nlink','uid','gid','size','mtime','ctime']as$field)if($opened[$field]!==$after[$field])self::invalid();}finally{fclose($stream);}return$data;
    }
    public static function accepted(string $cache,string $publicKey,?DateTimeImmutable $now=null,bool $current=true):array{
        $record=self::exact(self::object($cache,self::MAX_CACHE),['schema','component','key_id','envelope','sequence','payload_sha256','version','accepted_at']);
        if(!is_int($record->schema)||$record->schema!==1||$record->component!==self::COMPONENT||$record->key_id!==self::KEY_ID||!is_string($record->envelope)||!is_int($record->sequence)||!is_string($record->payload_sha256)||!is_string($record->version))self::invalid();self::instant($record->accepted_at);
        $release=self::verify($record->envelope,$publicKey,null,$now,$current);if($record->sequence!==$release['sequence']||$record->payload_sha256!==$release['payload_sha256']||$record->version!==$release['version'])self::invalid();return$release;
    }
    public static function acceptedStage(string $candidate):string{return'.accepted-'.hash('sha256',$candidate).'.new';}
    public static function directory(string $path,?string $preparedKey=null):void{
        $stat=@lstat($path);if(!$stat||is_link($path)||($stat['mode']&0170000)!==0040000)self::invalid();$names=@scandir($path);if($names===false)self::invalid();
        foreach($names as$name){
            if($name==='.'||$name==='..')continue;
            if(!in_array($name,['owner.json','refresh.lock','accepted.json','publication.json','task.json','activation.json'],true)){
                // Only privileged refresh may recover this exact complete stage. API reads stay unavailable.
                if($preparedKey===null)self::invalid();$pending=self::publication(self::read($path.'/publication.json',self::MAX_JOURNAL),$preparedKey,null,false);
                if($pending['state']!=='prepared'||$name!==self::acceptedStage($pending['candidate'])||self::read($path.'/'.$name,self::MAX_CACHE)!==$pending['candidate'])self::invalid();
            }
            $s=@lstat($path.'/'.$name);if(!$s||is_link($path.'/'.$name)||($s['mode']&0170000)!==0100000||$s['nlink']!==1||(PHP_OS_FAMILY!=='Windows'&&($s['uid']!==0||($s['mode']&0022)!==0))||($name==='refresh.lock'&&$s['size']!==0))self::invalid();
        }
        $owner=self::exact(self::object(self::read($path.'/owner.json',4096),4096),['schema','component','key_id']);if(!is_int($owner->schema)||$owner->schema!==1||$owner->component!==self::COMPONENT||$owner->key_id!==self::KEY_ID)self::invalid();
        if(in_array('task.json',$names,true)){$r=self::exact(self::object(self::read($path.'/task.json',131072),131072),['schema','component','definition_sha256','security']);if(!is_int($r->schema)||$r->schema!==1||$r->component!==self::COMPONENT||!is_string($r->definition_sha256)||!preg_match('/^[a-f0-9]{64}$/D',$r->definition_sha256)||!is_string($r->security)||$r->security===''||strlen($r->security)>65536)self::invalid();}
        if(in_array('activation.json',$names,true)){$r=self::exact(self::object(self::read($path.'/activation.json',16384),16384),['schema','component','owner','version','task_before_exists','enable_on_commit','phase','task_definition_sha256']);if(!is_int($r->schema)||$r->schema!==1||$r->component!==self::COMPONENT||!in_array($r->owner,['install','upgrade'],true)||!is_bool($r->task_before_exists)||!is_bool($r->enable_on_commit)||(!$r->task_before_exists&&!$r->enable_on_commit)||!in_array($r->phase,['prepared','complete'],true)||!is_string($r->task_definition_sha256)||!preg_match('/^[a-f0-9]{64}$/D',$r->task_definition_sha256))self::invalid();self::version($r->version);}
    }
    /** Read-only wrapper preflight; refresh repeats signature and path checks under its lease. */
    public static function preparedStage(string $directory,string $publicKey):?string{
        self::directory($directory,$publicKey);$names=scandir($directory);
        if(!in_array('publication.json',$names,true))return null;
        $pending=self::publication(self::read($directory.'/publication.json',self::MAX_JOURNAL),$publicKey,null,false);
        $name=self::acceptedStage($pending['candidate']);return$pending['state']==='prepared'&&in_array($name,$names,true)?$name:null;
    }
    public static function publication(string $journal,string $publicKey,?DateTimeImmutable $now=null,bool $current=false):array{
        $r=self::exact(self::object($journal,self::MAX_JOURNAL),['schema','component','key_id','state','previous_sha256','candidate']);
        if(!is_int($r->schema)||$r->schema!==1||$r->component!==self::COMPONENT||$r->key_id!==self::KEY_ID||!in_array($r->state,['prepared','committed'],true)||($r->previous_sha256!==null&&(!is_string($r->previous_sha256)||!preg_match('/^[a-f0-9]{64}$/D',$r->previous_sha256)))||!is_string($r->candidate))self::invalid();
        return['state'=>$r->state,'previous_sha256'=>$r->previous_sha256,'candidate'=>$r->candidate,'release'=>self::accepted($r->candidate,$publicKey,$now,$current)];
    }
    /** Read-only operator preflight, before stopping tasks/services or touching PBX files. */
    public static function highWater(string $directory,string $publicKey):?array{
        if(!is_dir($directory)){if(is_link($directory)||file_exists($directory))self::invalid();$parent=@scandir(dirname($directory));if($parent===false||in_array(basename($directory),$parent,true))self::invalid();return null;}for($node=$directory;;$node=dirname($node)){$s=@lstat($node);if(!$s||is_link($node)||(PHP_OS_FAMILY!=='Windows'&&($s['uid']!==0||($s['mode']&0022)!==0)))self::invalid();if(dirname($node)===$node)break;}$names=@scandir($directory);if($names===false)self::invalid();$hasCache=in_array('accepted.json',$names,true);$hasJournal=in_array('publication.json',$names,true);if(!$hasCache&&!$hasJournal)return null;if(!$hasCache||!$hasJournal)self::invalid();
        $cache=self::read($directory.'/accepted.json',self::MAX_CACHE);$journal=self::publication(self::read($directory.'/publication.json',self::MAX_JOURNAL),$publicKey,null,false);if($journal['state']!=='committed'||!hash_equals(hash('sha256',$journal['candidate']),hash('sha256',$cache)))self::invalid();return['sequence'=>$journal['release']['sequence'],'payload_sha256'=>$journal['release']['payload_sha256'],'version'=>$journal['release']['version']];
    }
    public static function assertRollback(string $current,string $snapshot,string $publicKey):void{
        $present=self::highWater($current,$publicKey);$saved=self::highWater($snapshot,$publicKey);if($present!==null&&($saved===null||$present['sequence']>$saved['sequence']||($present['sequence']===$saved['sequence']&&$present['payload_sha256']!==$saved['payload_sha256'])||version_compare($present['version'],$saved['version'],'>')))throw new RuntimeException('Operator rollback would lower WindowsPhone release trust; retain the machine catalogue with a reviewed recovery plan.');
    }
    public function release():?array{try{self::directory(dirname($this->cachePath()));$key=self::read($this->keyPath(),16384);$cache=self::read($this->cachePath(),self::MAX_CACHE);$journal=self::publication(self::read(dirname($this->cachePath()).'/publication.json',self::MAX_JOURNAL),$key,$this->now(),true);if($journal['state']!=='committed'||!hash_equals(hash('sha256',$journal['candidate']),hash('sha256',$cache)))return null;return$journal['release'];}catch(Throwable){return null;}}
    public function publishedVersion():string{return$this->release()['version']??'';}
}
