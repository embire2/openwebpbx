<?php
/** Optional Android wake-up. Signing and relay secrets stay in private instance storage. */
class pbx_mobile_push {
    private PDO $db;
    public function __construct(?PDO $db=null){$this->db=$db??database::new()->db;}
    private function q(string $sql,array $args=[]): PDOStatement {$s=$this->db->prepare($sql);$s->execute($args);return $s;}
    protected function settingsPath(): string {return self::path();}
    protected function authorized(): bool {return (new pbx_updates)->instanceAdmin()&&permission_exists('pbx_update_instance');}
    protected function engine(string $command): string {return (string)event_socket::api($command);}
    public static function path(): string {return pbx_paths::state().(PHP_OS_FAMILY==='Windows'?'/mobile-push.json':'/mobile-notifications/config.json');}
    private function stored(): array {
        $path=$this->settingsPath();if(is_link($path))throw new RuntimeException('Wake-up settings unavailable.');
        if(!is_file($path))return [];
        if(filesize($path)>65536||(PHP_OS_FAMILY!=='Windows'&&(fileperms($path)&0077)!==0))throw new RuntimeException('Wake-up settings unavailable.');
        $settings=json_decode((string)file_get_contents($path),true,32,JSON_THROW_ON_ERROR);
        if(!is_array($settings))throw new RuntimeException('Wake-up settings unavailable.');return $settings;
    }
    /** Safe form state; neither a Google private key nor a relay key can be returned. */
    public function view(): array {
        $s=$this->stored();return ['enabled'=>!empty($s['enabled']),'provider'=>$s['provider']??(!empty($s['service_account'])?'fcm':'webpush'),'project_id'=>$s['project_id']??'','delivery'=>($s['delivery']??'direct')==='cloudflare'?'cloudflare':'direct','relay_url'=>$s['relay_url']??'','has_client'=>!empty($s['client_config']),'has_service_key'=>!empty($s['service_account']),'has_relay_key'=>!empty($s['relay_token'])];
    }
    private function configuredClient(): array {
        $row=$this->q('select enabled,project_id,client_config from v_pbx_mobile_push_config where singleton')->fetch(PDO::FETCH_ASSOC);
        if(!$row||!filter_var($row['enabled'],FILTER_VALIDATE_BOOLEAN))return ['enabled'=>false,'message'=>'Incoming wake-up is not configured. Keep your phone connection running.'];
        $c=json_decode($row['client_config'],true,16,JSON_THROW_ON_ERROR);
        if(($c['provider']??'')==='webpush')return ['enabled'=>true,'provider'=>'webpush','vapid_public_key'=>(string)($c['vapid_public_key']??'')];
        return ['enabled'=>true,'provider'=>'fcm','project_id'=>$row['project_id'],'app_id'=>(string)($c['app_id']??''),'sender_id'=>(string)($c['sender_id']??''),'api_key'=>(string)($c['api_key']??'')];
    }
    /** The current native app supports UnifiedPush, not a Firebase client SDK. */
    public function client(): array {
        $c=$this->configuredClient();
        if(!empty($c['enabled'])&&($c['provider']??'')==='fcm')return ['enabled'=>false,'provider'=>'fcm','message'=>'The saved legacy Firebase adapter cannot wake the current Android app. Enable automatic setup in Incoming Call Wake-up.'];
        return $c;
    }
    public function register(array $account,array $input): array {
        // Retain the legacy API for clients explicitly using that adapter. It is
        // never advertised as usable to the current UnifiedPush native app.
        $c=$this->configuredClient();$token=$input['token']??null;$project=$input['project_id']??null;
        if(($c['provider']??'')==='webpush'){
            $endpoint=$input['endpoint']??null;$public=$input['p256dh']??null;$auth=$input['auth']??null;
            if(empty($c['enabled'])||($input['vapid_public_key']??'')!==$c['vapid_public_key']||!is_string($endpoint)||strlen($endpoint)>4096||!preg_match('~^https://fcm\.googleapis\.com/fcm/send/[A-Za-z0-9_:\-.]{20,4000}$~D',$endpoint))throw new InvalidArgumentException('Wake-up delivery is unavailable.');
            $p=self::decode($public,65);self::decode($auth,16);
            if($p[0]!=="\x04"||!openssl_pkey_get_public("-----BEGIN PUBLIC KEY-----\n".chunk_split(base64_encode(hex2bin('3059301306072a8648ce3d020106082a8648ce3d030107034200').$p),64,"\n")."-----END PUBLIC KEY-----\n"))throw new InvalidArgumentException('Check your phone wake-up keys.');
            $token=json_encode(['endpoint'=>$endpoint,'p256dh'=>$public,'auth'=>$auth,'vapid_public_key'=>$c['vapid_public_key']],JSON_THROW_ON_ERROR);$project='webpush';
        }elseif(empty($c['enabled'])||$project!==($c['project_id']??'')||!is_string($token)||strlen($token)<20||strlen($token)>4096||!preg_match('/^[a-zA-Z0-9_:\-.]+$/D',$token))throw new InvalidArgumentException('Wake-up delivery is unavailable.');
        if(!is_uuid($account['device_uuid']??'')||!is_uuid($account['domain_uuid']??'')||!is_uuid($account['extension_uuid']??''))throw new OutOfBoundsException('Phone unavailable.');
        $s=$this->q("update v_pbx_mobile_devices m set push_token=?,push_project=? where m.device_uuid=? and m.domain_uuid=? and m.extension_uuid=? and m.revoked_at is null and m.expires_at>now() and exists(select 1 from v_domains d join v_extensions e using(domain_uuid) where d.domain_uuid=m.domain_uuid and e.extension_uuid=m.extension_uuid and d.domain_enabled='true' and e.enabled='true') and not exists(select 1 from v_pbx_services s join v_pbx_tenants t using(tenant_uuid) where s.domain_uuid=m.domain_uuid and not t.enabled)",[$token,$project,$account['device_uuid'],$account['domain_uuid'],$account['extension_uuid']]);
        if($s->rowCount()!==1)throw new OutOfBoundsException('Phone unavailable.');return ['ok'=>true];
    }
    private function request(array $account,string $id): array {
        if(!is_uuid($id))throw new InvalidArgumentException('Call unavailable.');
        $row=$this->q('select request_uuid,call_uuid,state,expires_at from v_pbx_mobile_push_calls where request_uuid=? and device_uuid=? and domain_uuid=? and extension_uuid=?',[$id,$account['device_uuid'],$account['domain_uuid'],$account['extension_uuid']])->fetch(PDO::FETCH_ASSOC);
        if(!$row)throw new OutOfBoundsException('Call unavailable.');return $row;
    }
    public function call(array $account,string $id): array {
        $r=$this->request($account,$id);$ringing=!empty($this->configuredClient()['enabled'])&&in_array($r['state'],['pending','sent'],true)&&strtotime($r['expires_at'])>time()&&trim($this->engine('uuid_exists '.$r['call_uuid']))==='true';
        if($ringing){
            $domain=trim($this->engine('uuid_getvar '.$r['call_uuid'].' domain_uuid'));$targets=trim($this->engine('uuid_getvar '.$r['call_uuid'].' openweb_mobile_wake_targets'));
            $ringing=$domain===$account['domain_uuid']&&strlen($targets)<=40000&&in_array($account['extension_uuid'],explode(',',$targets),true);
        }
        if($ringing){$peer=trim($this->engine('uuid_getvar '.$r['call_uuid'].' bridge_uuid'));if(is_uuid($peer)&&((int)trim($this->engine('uuid_getvar '.$peer.' answer_epoch')))>0)$ringing=false;}
        return ['ringing'=>$ringing,'call_id'=>$r['call_uuid'],'expires_at'=>$r['expires_at']];
    }
    public function dismiss(array $account,string $id): array {
        $this->request($account,$id);
        // Preserve an in-flight lease. Its late response can record possible delivery
        // but cannot reopen this call, and the worker will send an ended notification.
        $this->q("update v_pbx_mobile_push_calls set state='dismissed',attempts=0,next_attempt_at=now() where request_uuid=? and device_uuid=? and domain_uuid=? and state in ('pending','sent')",[$id,$account['device_uuid'],$account['domain_uuid']]);return ['ok'=>true];
    }
    private function text(array $input,string $name,int $limit): string {
        $v=$input[$name]??'';if(!is_string($v)||strlen($v)>$limit)throw new InvalidArgumentException('Check your wake-up configuration files.');return trim($v);
    }
    private static function decode(mixed $value,int $length): string {
        if(!is_string($value)||strlen($value)>128||!preg_match('/^[A-Za-z0-9_-]+={0,2}$/D',$value))throw new InvalidArgumentException('Check your phone wake-up keys.');
        $bytes=base64_decode(strtr($value,'-_','+/'),true);if($bytes===false||strlen($bytes)!==$length)throw new InvalidArgumentException('Check your phone wake-up keys.');return $bytes;
    }
    private function vapid(array &$settings): void {
        if(empty($settings['vapid_private_key'])){
            $key=openssl_pkey_new(['private_key_type'=>OPENSSL_KEYTYPE_EC,'curve_name'=>'prime256v1']);$pem='';
            if(!$key||!openssl_pkey_export($key,$pem))throw new RuntimeException('Could not prepare wake-up keys.');$settings['vapid_private_key']=$pem;
        }
        $key=openssl_pkey_get_private($settings['vapid_private_key']);$details=$key?openssl_pkey_get_details($key):false;
        if(!$details||$details['type']!==OPENSSL_KEYTYPE_EC||($details['ec']['curve_name']??'')!=='prime256v1')throw new RuntimeException('Check the saved wake-up key.');
        $settings['vapid_public_key']=rtrim(strtr(base64_encode("\x04".str_pad($details['ec']['x'],32,"\0",STR_PAD_LEFT).str_pad($details['ec']['y'],32,"\0",STR_PAD_LEFT)),'+/','-_'),'=');
        $settings['vapid_subject']=$settings['vapid_subject']??'mailto:hello@openwebpbx.com';
    }
    private function service(array $key,string $project): void {
        $private=$key['private_key']??'';$rsa=is_string($private)?openssl_pkey_get_private($private):false;$details=$rsa?openssl_pkey_get_details($rsa):false;
        if(($key['type']??'')!=='service_account'||($key['project_id']??'')!==$project||!is_string($key['client_email']??null)||!preg_match('/^[a-zA-Z0-9_.-]+@[a-zA-Z0-9_.-]+\.iam\.gserviceaccount\.com$/D',$key['client_email'])||!$details||$details['type']!==OPENSSL_KEYTYPE_RSA||$details['bits']<2048)throw new InvalidArgumentException('Use a valid service account for the same project.');
    }
    private function settings(array $input,array $previous): array {
        if(empty($input['enabled'])){$previous['enabled']=false;return $previous;}
        $provider=$this->text($input,'provider',20);if($provider==='')$provider=$previous['provider']??(!empty($previous['service_account'])?'fcm':'webpush');
        if($provider==='webpush'){
            $settings=$previous;$this->vapid($settings);$settings['enabled']=true;$settings['provider']='webpush';$settings['project_id']='webpush';$settings['client_config']=['provider'=>'webpush','vapid_public_key'=>$settings['vapid_public_key']];
            $mode=$this->text($input,'delivery',20);if($mode==='')$mode=$previous['delivery']??'direct';
            if($mode==='cloudflare'){
                $url=$this->text($input,'relay_url',512);if($url==='')$url=$previous['relay_url']??'';$url=rtrim($url,'/');$token=$this->text($input,'relay_token',256);
                if($token===''){if($url!==rtrim($previous['relay_url']??'','/'))throw new InvalidArgumentException('Enter the relay key when changing the Worker address.');$token=$previous['relay_token']??'';}
                if(!preg_match('~^https://[a-z0-9-]+\.[a-z0-9-]+\.workers\.dev$~D',$url)||!preg_match('/^[A-Za-z0-9_-]{32,256}$/D',$token))throw new InvalidArgumentException('Use your Cloudflare Worker HTTPS address and relay key.');$settings['relay_url']=$url;$settings['relay_token']=$token;
            }elseif($mode!=='direct')throw new InvalidArgumentException('Choose a delivery method.');
            $settings['delivery']=$mode;return $settings;
        }
        if($provider!=='fcm')throw new InvalidArgumentException('Choose a wake-up method.');
        $raw=$this->text($input,'client_json',65536);$settings=$previous;
        if($raw!==''){
            $client=json_decode($raw,true,32,JSON_THROW_ON_ERROR);$project=$client['project_info']['project_id']??'';$sender=(string)($client['project_info']['project_number']??'');$app=null;
            foreach($client['client']??[] as $candidate)if(($candidate['client_info']['android_client_info']['package_name']??'')==='com.openweb.pbx'){$app=$candidate;break;}
            if(!$app||!is_string($project)||!preg_match('/^[a-z][a-z0-9-]{4,62}$/D',$project)||!preg_match('/^[0-9]{4,32}$/D',$sender))throw new InvalidArgumentException('Use the Android configuration for com.openweb.pbx.');
            $public=['app_id'=>$app['client_info']['mobilesdk_app_id']??'','sender_id'=>$sender,'api_key'=>$app['api_key'][0]['current_key']??''];$parts=[];
            if(!is_string($public['app_id'])||!preg_match('/^1:([0-9]+):android:[a-f0-9]+$/D',$public['app_id'],$parts)||$parts[1]!==$sender||!is_string($public['api_key'])||!preg_match('/^[A-Za-z0-9_-]{20,128}$/D',$public['api_key']))throw new InvalidArgumentException('Check the Android project configuration.');
            $settings['project_id']=$project;$settings['client_config']=$public;
        }
        if(empty($settings['project_id'])||empty($settings['client_config']))throw new InvalidArgumentException('Add your Android project configuration first.');
        $project=$settings['project_id'];$mode=$this->text($input,'delivery',20);if($mode==='')$mode=$previous['delivery']??'direct';
        $keyText=$this->text($input,'service_json',32768);$key=$keyText!==''?json_decode($keyText,true,16,JSON_THROW_ON_ERROR):($previous['service_account']??null);
        if($keyText!==''||$mode==='direct'){
            if(!is_array($key))throw new InvalidArgumentException('Add your service account for direct delivery.');$this->service($key,$project);$settings['service_account']=$key;
        }elseif(($key['project_id']??'')!==$project)unset($settings['service_account']);
        if($mode==='cloudflare'){
            $url=$this->text($input,'relay_url',512);if($url==='')$url=$previous['relay_url']??'';$url=rtrim($url,'/');$token=$this->text($input,'relay_token',256);
            if($token===''){
                if($url!==rtrim($previous['relay_url']??'','/'))throw new InvalidArgumentException('Enter the relay key when changing the Worker address.');$token=$previous['relay_token']??'';
            }
            if(!preg_match('~^https://[a-z0-9-]+\.[a-z0-9-]+\.workers\.dev$~D',$url)||!preg_match('/^[A-Za-z0-9_-]{32,256}$/D',$token))throw new InvalidArgumentException('Use your Cloudflare Worker HTTPS address and relay key.');
            $settings['relay_url']=$url;$settings['relay_token']=$token;
        }elseif($mode!=='direct')throw new InvalidArgumentException('Choose a delivery method.');
        $settings['enabled']=true;$settings['provider']='fcm';$settings['delivery']=$mode;return $settings;
    }
    private function atomic(string $path,string $bytes): void {
        if(strlen($bytes)>65536)throw new InvalidArgumentException('Wake-up configuration is too large.');$tmp=$path.'.'.bin2hex(random_bytes(8));$file=null;
        try{
            $file=fopen($tmp,'x');if(!$file||!chmod($tmp,0600))throw new RuntimeException('Settings unavailable.');
            if(fwrite($file,$bytes)!==strlen($bytes)||!fflush($file)||(function_exists('fsync')&&!fsync($file)))throw new RuntimeException('Settings unavailable.');
            fclose($file);$file=null;if(!rename($tmp,$path))throw new RuntimeException('Settings unavailable.');
        }finally{if(is_resource($file))fclose($file);if(is_file($tmp))unlink($tmp);}
    }
    public function save(array $input): void {
        if(!$this->authorized())throw new RuntimeException('Instance administrator access required.');
        $path=$this->settingsPath();$lockPath=$path.'.lock';if(is_link($lockPath)||is_link($path)||!is_dir(dirname($path)))throw new RuntimeException('Settings unavailable.');
        $lock=fopen($lockPath,'c');if(!$lock||!chmod($lockPath,0600))throw new RuntimeException('Settings unavailable.');
        $written=false;$old=null;
        try{
            if(!flock($lock,LOCK_EX))throw new RuntimeException('Settings unavailable.');
            $previous=$this->stored();$old=is_file($path)?file_get_contents($path):null;$settings=$this->settings($input,$previous);$bytes=json_encode($settings,JSON_THROW_ON_ERROR);
            $this->db->beginTransaction();
            $this->q('insert into v_pbx_mobile_push_config(singleton,enabled,project_id,client_config) values(true,?,?,?::jsonb) on conflict(singleton) do update set enabled=excluded.enabled,project_id=excluded.project_id,client_config=excluded.client_config',[$settings['enabled']?'true':'false',$settings['project_id']??'',json_encode($settings['client_config']??[],JSON_THROW_ON_ERROR)]);
            $this->atomic($path,$bytes);$written=true;$this->db->commit();
        }catch(Throwable $e){
            if($this->db->inTransaction())$this->db->rollBack();
            if($written){if($old!==null)$this->atomic($path,$old);elseif(is_file($path))unlink($path);}throw $e;
        }finally{flock($lock,LOCK_UN);fclose($lock);}
    }
}
