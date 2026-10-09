<?php
/** Native phones: per-device credentials, one-use setup and extension-scoped data. */
class pbx_mobile {
    private PDO $db;
    public function __construct(?PDO $db=null){$this->db=$db??database::new()->db;}
    private function q(string $sql,array $p=[]): PDOStatement {$s=$this->db->prepare($sql);foreach($p as $k=>$v)$s->bindValue(':'.$k,$v,$v===null?PDO::PARAM_NULL:(is_bool($v)?PDO::PARAM_BOOL:(is_int($v)?PDO::PARAM_INT:PDO::PARAM_STR)));$s->execute();return $s;}
    private function text(mixed $v,int $max): string {if(!is_string($v)||strlen($v)>$max||preg_match('/[\x00-\x1f\x7f]/',$v))throw new InvalidArgumentException('Check the supplied details.');return trim($v);}
    private function id(string $id): void {if(!is_uuid($id))throw new InvalidArgumentException('Item unavailable.');}
    public function rate(string $key,int $limit,int $seconds): void {
        $row=$this->q("insert into v_pbx_mobile_rate(bucket,window_start,attempts) values(:b,now(),1) on conflict(bucket) do update set attempts=case when v_pbx_mobile_rate.window_start < now()-make_interval(secs=>:s) then 1 else v_pbx_mobile_rate.attempts+1 end,window_start=case when v_pbx_mobile_rate.window_start < now()-make_interval(secs=>:s) then now() else v_pbx_mobile_rate.window_start end returning attempts",['b'=>hash('sha256',$key),'s'=>$seconds])->fetchColumn();
        if((int)$row>$limit)throw new OverflowException('Please wait a few minutes and try again.');
        if(random_int(1,100)===1){$this->q("delete from v_pbx_mobile_rate where window_start<now()-interval '1 day'");$this->q("delete from v_pbx_mobile_enrollments where expires_at<now()-interval '1 day'");}
    }
    private function extension(string $domain,string $id): array {
        $this->id($domain);$this->id($id);
        $r=$this->q("select e.extension_uuid,e.extension,e.number_alias,e.effective_caller_id_name,d.domain_uuid,d.domain_name,r.config from v_extensions e join v_domains d using(domain_uuid) join v_pbx_restore r using(domain_uuid) where e.extension_uuid=:id and e.domain_uuid=:d and e.enabled='true' and d.domain_enabled='true' and not exists(select 1 from v_pbx_services s join v_pbx_tenants t using(tenant_uuid) where s.domain_uuid=d.domain_uuid and not t.enabled)",['id'=>$id,'d'=>$domain])->fetch(PDO::FETCH_ASSOC);
        if(!$r)throw new RuntimeException('This user is unavailable.');
        $config=json_decode($r['config'],true,512,JSON_THROW_ON_ERROR);unset($r['config']);$u=null;
        foreach($config['users']??[] as $number=>$candidate)if(($candidate['extension_uuid']??'')===$id&&!empty($candidate['enabled'])){$u=$candidate;$r['number']=(string)$number;break;}
        if(!$u||($u['auth_id']??null)!==$r['extension']||($config['realm']??null)!==$r['domain_name'])throw new RuntimeException('This user is unavailable.');
        $r['user']=$u;$r['config']=$config;return $r;
    }
    public function adminExtension(string $number): array {
        $domain=$_SESSION['domain_uuid']??'';
        if(!permission_exists('extension_edit')||!(new pbx_setup($this->db))->canManage()||!(new pbx_tenants($this->db))->canDomain($domain))throw new RuntimeException('Administrator access required.');
        $c=(new pbx_admin($this->db))->config();$u=$c['users'][$number]??null;
        if(!$u)throw new InvalidArgumentException('Choose a user in your PBX.');return $this->extension($domain,$u['extension_uuid']);
    }
    protected function tlsReady(): bool {return filter_var(config::load()->get('openweb.mobile_tls_ready','false'),FILTER_VALIDATE_BOOLEAN);}
    private function requireTls(): void {if(!$this->tlsReady())throw new RuntimeException('Phone connections are not ready. Ask your instance administrator to finish secure phone setup.');}
    public function createCode(string $number): array {
        $e=$this->adminExtension($number);return $this->issueCode($e);
    }
    private function issueCode(array $e): array {
        $this->requireTls();$this->rate('create:'.($_SESSION['user_uuid']??''),20,600);
        $url=pbx_paths::url();if(!preg_match('~^https://[a-z0-9.-]+(?::[0-9]{1,5})?$~iD',$url))throw new RuntimeException('Ask your instance administrator to finish HTTPS setup.');
        $this->db->beginTransaction();try {
            $this->q('select extension_uuid from v_extensions where extension_uuid=:id for update',['id'=>$e['extension_uuid']]);
            if((int)$this->q('select count(*) from v_pbx_mobile_devices where extension_uuid=:id and revoked_at is null and expires_at>now()',['id'=>$e['extension_uuid']])->fetchColumn()>=10)throw new RuntimeException('Remove an unused phone before adding another.');
            $this->q('delete from v_pbx_mobile_enrollments where extension_uuid=:id and used_at is null',['id'=>$e['extension_uuid']]);
            $code=bin2hex(random_bytes(32));$expiry=$this->q("insert into v_pbx_mobile_enrollments(enrollment_uuid,domain_uuid,extension_uuid,code_hash,created_by,expires_at) values(:id,:d,:e,:h,:u,now()+interval '10 minutes') returning expires_at",['id'=>uuid(),'d'=>$e['domain_uuid'],'e'=>$e['extension_uuid'],'h'=>hash('sha256',$code),'u'=>$_SESSION['user_uuid']])->fetchColumn();
            $this->db->commit();return ['payload'=>json_encode(['type'=>'openwebpbx','version'=>1,'server'=>$url,'code'=>$code],JSON_UNESCAPED_SLASHES|JSON_THROW_ON_ERROR),'expires_at'=>$expiry];
        }catch(Throwable $ex){if($this->db->inTransaction())$this->db->rollBack();throw $ex;}
    }
    public function enroll(array $in,string $ip): array {
        $this->rate('enroll:'.$ip,15,600);$this->requireTls();$code=$this->text($in['code']??'',64);$name=$this->text($in['device_name']??'Android phone',80);
        if(!preg_match('/^[a-f0-9]{64}$/D',$code)||($in['platform']??'android')!=='android'||$name==='')throw new InvalidArgumentException('The setup code is invalid or has expired.');
        $this->db->beginTransaction();try{
            $r=$this->q('select * from v_pbx_mobile_enrollments where code_hash=:h and used_at is null and expires_at>now() for update',['h'=>hash('sha256',$code)])->fetch(PDO::FETCH_ASSOC);
            if(!$r)throw new InvalidArgumentException('The setup code is invalid or has expired.');
            $this->q('select extension_uuid from v_extensions where extension_uuid=:id for update',['id'=>$r['extension_uuid']]);$e=$this->extension($r['domain_uuid'],$r['extension_uuid']);
            if((int)$this->q('select count(*) from v_pbx_mobile_devices where extension_uuid=:id and revoked_at is null and expires_at>now()',['id'=>$e['extension_uuid']])->fetchColumn()>=10)throw new RuntimeException('Remove an unused phone before adding another.');
            $token=bin2hex(random_bytes(32));$password=bin2hex(random_bytes(32));$auth='owm-'.bin2hex(random_bytes(16));$id=uuid();
            $this->q("insert into v_pbx_mobile_devices(device_uuid,domain_uuid,extension_uuid,device_name,platform,token_hash,sip_username,sip_a1_hash,expires_at) values(:id,:d,:e,:name,'android',:token,:auth,:a1,now()+interval '180 days')",['id'=>$id,'d'=>$e['domain_uuid'],'e'=>$e['extension_uuid'],'name'=>$name,'token'=>hash('sha256',$token),'auth'=>$auth,'a1'=>md5($auth.':'.$e['domain_name'].':'.$password)]);
            $this->q('update v_pbx_mobile_enrollments set used_at=now() where enrollment_uuid=:id',['id'=>$r['enrollment_uuid']]);$this->db->commit();$this->clearDirectory($e);
            $result=$this->bootstrap($e+['sip_username'=>$auth,'device_uuid'=>$id]);$result['token']=$token;$result['sip']['password']=$password;return $result;
        }catch(Throwable $ex){if($this->db->inTransaction())$this->db->rollBack();throw $ex;}
    }
    public function authenticate(string $token): array {
        if(!preg_match('/^[a-f0-9]{64}$/D',$token))throw new UnexpectedValueException('Connect your phone again.');
        $r=$this->q('select device_uuid,domain_uuid,extension_uuid,sip_username from v_pbx_mobile_devices where token_hash=:h and revoked_at is null and expires_at>now()',['h'=>hash('sha256',$token)])->fetch(PDO::FETCH_ASSOC);
        if(!$r)throw new UnexpectedValueException('Connect your phone again.');
        try{$e=$this->extension($r['domain_uuid'],$r['extension_uuid']);}catch(RuntimeException){throw new UnexpectedValueException('This phone is no longer connected.');}
        $this->q("update v_pbx_mobile_devices set last_seen_at=now() where device_uuid=:id and (last_seen_at is null or last_seen_at<now()-interval '5 minutes')",['id'=>$r['device_uuid']]);return $e+$r;
    }
    public function bootstrap(array $e): array {return ['account'=>['extension'=>$e['number'],'display_name'=>$e['user']['name']??$e['number']],'sip'=>['server'=>pbx_paths::host(),'domain'=>$e['domain_name'],'username'=>$e['sip_username'],'auth_username'=>$e['sip_username'],'port'=>5061,'transport'=>'tls','media_encryption'=>'srtp'],'device_id'=>$e['device_uuid'],'features'=>['directory','calls','voicemail']];}
    public function devices(string $number): array {$e=$this->adminExtension($number);return $this->q('select device_uuid,device_name,created_at,last_seen_at,expires_at,revoked_at from v_pbx_mobile_devices where extension_uuid=:e order by created_at desc limit 30',['e'=>$e['extension_uuid']])->fetchAll(PDO::FETCH_ASSOC);}
    public function adminRevoke(string $number,string $id): void {$e=$this->adminExtension($number);$this->id($id);$d=$this->q('select device_uuid,sip_username,domain_uuid from v_pbx_mobile_devices where device_uuid=:id and extension_uuid=:e',['id'=>$id,'e'=>$e['extension_uuid']])->fetch(PDO::FETCH_ASSOC);if(!$d)throw new InvalidArgumentException('Phone unavailable.');$this->revoke($e+$d);}
    /** A review account can connect only its operator-assigned demo extension. */
    public function reviewExtension(): array {
        if(empty($_SESSION['authorized'])||!permission_exists('pbx_mobile_review'))throw new RuntimeException('Review access required.');
        $r=$this->q("select r.domain_uuid,r.extension_uuid,r.echo_number,r.voicemail_number from v_pbx_mobile_reviewers r join v_users u using(user_uuid) where r.user_uuid=:u and r.domain_uuid=:d and u.domain_uuid=r.domain_uuid and u.user_enabled='true' and r.enabled",['u'=>$_SESSION['user_uuid']??'00000000-0000-0000-0000-000000000000','d'=>$_SESSION['domain_uuid']??'00000000-0000-0000-0000-000000000000'])->fetch(PDO::FETCH_ASSOC);
        if(!$r)throw new RuntimeException('Review access required.');
        return $this->extension($r['domain_uuid'],$r['extension_uuid'])+$r;
    }
    protected function reviewEngine(string $command,bool $background=false): string {
        $reply=$background?event_socket::async($command):event_socket::api($command);
        // Background commands return event headers; API commands normally return a body.
        // Preserve the engine's acknowledgement instead of casting its header array to "Array".
        if(is_array($reply))$reply=$reply['Reply-Text']??'';
        return is_string($reply)?$reply:'';
    }
    public function reviewRing(): void {
        $e=$this->reviewExtension();$this->requireTls();
        if(!preg_match('/^[a-z0-9.-]+$/Di',$e['domain_name'])||!preg_match('/^[a-z0-9_.-]{1,64}$/Di',$e['extension']))throw new RuntimeException('Demo phone setup is unavailable.');
        if(!$this->reviewDevices())throw new RuntimeException('Connect your demo phone first, then try again.');
        $raw=$this->reviewEngine('show channels as json');if(strlen($raw)>8388608)throw new RuntimeException('Call status is unavailable.');
        $channels=json_decode($raw,true,64,JSON_THROW_ON_ERROR);if(!is_array($channels)||!isset($channels['row_count'])||!is_numeric($channels['row_count'])||!is_array($channels['rows']??[])||(int)$channels['row_count']!==count($channels['rows']??[]))throw new RuntimeException('Call status is unavailable.');
        foreach($channels['rows']??[] as $row){$id=$row['uuid']??'';$this->id($id);if(trim($this->reviewEngine('uuid_getvar '.$id.' domain_uuid'))===$e['domain_uuid'])throw new RuntimeException('Finish your demo call before ringing your phone again.');}
        // One queued request per full ring+call lifetime prevents concurrent/replayed originates.
        $this->rate('review-ring:'.$_SESSION['user_uuid'],1,150);
        $id=uuid();$command="originate {origination_uuid=".$id.",domain_uuid=".$e['domain_uuid'].",domain_name=".$e['domain_name'].",rtp_secure_media=optional:AES_CM_128_HMAC_SHA1_80,origination_caller_id_name=OpenWeb_Review,origination_caller_id_number=".$e['echo_number'].",originate_timeout=25,execute_on_answer='sched_hangup +120 NORMAL_CLEARING'}user/".$e['extension'].'@'.$e['domain_name'].' &echo()';
        if(!str_contains($this->reviewEngine($command,true),'+OK'))throw new RuntimeException('Your demo phone could not be called. Open the app and try again in a few minutes.');
    }
    public function reviewCode(): array {return $this->issueCode($this->reviewExtension());}
    public function reviewDevices(): array {$e=$this->reviewExtension();return $this->q('select device_uuid,device_name,created_at,last_seen_at,expires_at,revoked_at from v_pbx_mobile_devices where domain_uuid=:d and extension_uuid=:e and revoked_at is null and expires_at>now() order by created_at',['d'=>$e['domain_uuid'],'e'=>$e['extension_uuid']])->fetchAll(PDO::FETCH_ASSOC);}
    public function reviewRevoke(string $id): void {
        $e=$this->reviewExtension();$this->rate('review-remove:'.$_SESSION['user_uuid'],30,600);$this->id($id);
        $d=$this->q('select device_uuid,sip_username from v_pbx_mobile_devices where device_uuid=:id and domain_uuid=:d and extension_uuid=:e',['id'=>$id,'d'=>$e['domain_uuid'],'e'=>$e['extension_uuid']])->fetch(PDO::FETCH_ASSOC);
        if(!$d)throw new InvalidArgumentException('Phone unavailable.');$this->revoke($e+$d);
    }
    private function clearDirectory(array $e): void {try{$cache=new cache;foreach([$e['extension'],$e['number']] as $user)$cache->delete('directory:'.$user.'@'.$e['domain_name']);}catch(Throwable){}}
    public function revoke(array $e): void {
        $this->id($e['device_uuid']);
        $this->q('update v_pbx_mobile_devices set revoked_at=coalesce(revoked_at,now()) where device_uuid=:id and domain_uuid=:d',['id'=>$e['device_uuid'],'d'=>$e['domain_uuid']]);
        $this->clearDirectory($e);
        // Remove only this device's contacts. Other phones on this extension stay connected.
        $result=(string)event_socket::api('lua app/pbx_setup/mobile_revoke.lua '.$e['device_uuid']);
        if(!str_starts_with(trim($result),'+OK'))throw new RuntimeException('Phone access was removed, but its call connection could not be cleared. Try removing the phone again.');
        event_socket::api('hupall NORMAL_CLEARING sip_auth_username '.$e['sip_username']);
        event_socket::api('hupall NORMAL_CLEARING sip_to_user '.$e['sip_username']);
    }
    public function directory(array $e): array {
        $rows=[];foreach($e['config']['users'] as $n=>$u)if(!empty($u['enabled']))$rows[]=['id'=>'extension:'.$n,'name'=>$u['name'],'number'=>(string)$n];
        foreach($e['config']['contacts']??[] as $i=>$c){$owner=(string)($c['owner']??'');if($owner!==''&&$owner!==$e['number'])continue;$number=(string)($c['phone']??'');if(!preg_match('/^\+?[0-9*#]{1,32}$/D',$number))continue;$rows[]=['id'=>'contact:'.$i,'name'=>trim(($c['first_name']??'').' '.($c['last_name']??''))?:($c['company']??$number),'number'=>$number];}
        usort($rows,fn($a,$b)=>strcasecmp($a['name'],$b['name']));return ['contacts'=>array_slice($rows,0,2000)];
    }
    public function calls(array $e): array {
        $rows=$this->q("select call_uuid::text id,party_number number,direction,started_at,duration,answered from v_pbx_mobile_calls where extension_uuid=:e order by started_at desc limit 100",['e'=>$e['extension_uuid']])->fetchAll(PDO::FETCH_ASSOC);
        $names=[];foreach($this->directory($e)['contacts'] as $c)$names[$c['number']]=$c['name'];foreach($rows as &$r){$r['name']=$names[$r['number']]??($r['number']?:'Unknown caller');$r['duration']=(int)$r['duration'];$r['answered']=filter_var($r['answered'],FILTER_VALIDATE_BOOLEAN);}return ['calls'=>$rows];
    }
    public function callLog(array $e,array $in): array {
        $id=$this->text($in['id']??'',36);$this->id($id);$n=$this->text($in['number']??'',32);$direction=$in['direction']??'';$duration=$in['duration']??null;$date=$this->text($in['started_at']??'',40);$epoch=strtotime($date);
        if(($n!==''&&!preg_match('/^\+?[0-9*#]{1,32}$/D',$n))||!in_array($direction,['incoming','outgoing','missed'],true)||!is_int($duration)||$duration<0||$duration>86400||!is_bool($in['answered']??null)||!$epoch||$epoch>time()+300||$epoch<time()-86400*30)throw new InvalidArgumentException('Check the call details.');
        $this->q('insert into v_pbx_mobile_calls(device_uuid,call_uuid,domain_uuid,extension_uuid,party_number,direction,started_at,duration,answered) values(:device,:id,:d,:e,:n,:direction,:time,:duration,:answered) on conflict(device_uuid,call_uuid) do nothing',['device'=>$e['device_uuid'],'id'=>$id,'d'=>$e['domain_uuid'],'e'=>$e['extension_uuid'],'n'=>$n,'direction'=>$direction,'time'=>gmdate('c',$epoch),'duration'=>$duration,'answered'=>$in['answered']]);return ['ok'=>true];
    }
    private function mailbox(array $e): string {if(empty($e['user']['voicemail_enabled'])||!is_uuid($e['user']['voicemail_uuid']??''))throw new RuntimeException('Voicemail is unavailable for this user.');return $e['user']['voicemail_uuid'];}
    public function voicemail(array $e): array {
        $rows=$this->q("select voicemail_message_uuid id,coalesce(caller_id_name,'') caller_name,coalesce(caller_id_number,'') caller_number,to_timestamp(created_epoch) created_at,coalesce(message_length,0)::int duration,(coalesce(message_status,'')='saved' or read_epoch>0) as read from v_voicemail_messages where domain_uuid=:d and voicemail_uuid=:v order by created_epoch desc limit 100",['d'=>$e['domain_uuid'],'v'=>$this->mailbox($e)])->fetchAll(PDO::FETCH_ASSOC);
        foreach($rows as &$r)$r['read']=filter_var($r['read'],FILTER_VALIDATE_BOOLEAN);return ['messages'=>$rows];
    }
    private function message(array $e,string $id): array {$this->id($id);$r=$this->q('select * from v_voicemail_messages where domain_uuid=:d and voicemail_uuid=:v and voicemail_message_uuid=:id',['d'=>$e['domain_uuid'],'v'=>$this->mailbox($e),'id'=>$id])->fetch(PDO::FETCH_ASSOC);if(!$r)throw new OutOfBoundsException('Message unavailable.');return $r;}
    private function vmPath(array $e,string $id,string $suffix='wav',string $prefix='msg_'): string {if(!preg_match('/^[a-zA-Z0-9.-]+$/D',$e['domain_name'])||!preg_match('/^[0-9]{1,32}$/D',$e['number']))throw new RuntimeException('Message unavailable.');return pbx_paths::voicemail().'/default/'.$e['domain_name'].'/'.$e['number'].'/'.$prefix.$id.'.'.$suffix;}
    public function voicemailAudio(array $e,string $id): array {
        $m=$this->message($e,$id);foreach(['wav'=>'audio/wav','mp3'=>'audio/mpeg'] as $ext=>$type){$file=$this->vmPath($e,$id,$ext);if(pbx_paths::contains(pbx_paths::voicemail(),$file)&&is_file($file)&&is_readable($file))return ['file'=>$file,'type'=>$type];}
        $encoded=$m['message_base64']??'';if(strlen($encoded)>36000000)throw new RuntimeException('Message unavailable.');$data=base64_decode($encoded,true);if($data===false||$data==='')throw new OutOfBoundsException('Message unavailable.');$type=(new finfo(FILEINFO_MIME_TYPE))->buffer($data);if(!in_array($type,['audio/x-wav','audio/wav','audio/mpeg'],true))throw new OutOfBoundsException('Message unavailable.');return ['data'=>$data,'type'=>$type];
    }
    public function voicemailRead(array $e,string $id): array {$this->message($e,$id);$this->q("update v_voicemail_messages set message_status='saved',read_epoch=extract(epoch from now()) where domain_uuid=:d and voicemail_uuid=:v and voicemail_message_uuid=:id",['d'=>$e['domain_uuid'],'v'=>$this->mailbox($e),'id'=>$id]);$this->mwi($e);return ['ok'=>true];}
    public function voicemailDelete(array $e,string $id): array {
        $this->message($e,$id);$moved=[];$this->db->beginTransaction();try{
            foreach(['msg_','intro_','intro_msg_'] as $prefix)foreach(['wav','mp3'] as $ext){$path=$this->vmPath($e,$id,$ext,$prefix);if(is_file($path)){if(!pbx_paths::contains(pbx_paths::voicemail(),$path))throw new RuntimeException('Message unavailable.');$trash=$path.'.deleted-'.bin2hex(random_bytes(6));if(!rename($path,$trash))throw new RuntimeException('The message could not be removed.');$moved[$path]=$trash;}}
            $this->q('delete from v_voicemail_messages where domain_uuid=:d and voicemail_uuid=:v and voicemail_message_uuid=:id',['d'=>$e['domain_uuid'],'v'=>$this->mailbox($e),'id'=>$id]);$this->db->commit();foreach($moved as $trash)@unlink($trash);
        }catch(Throwable $ex){if($this->db->inTransaction())$this->db->rollBack();foreach($moved as $path=>$trash)@rename($trash,$path);throw $ex;}$this->mwi($e);return ['ok'=>true];
    }
    private function mwi(array $e): void {try{event_socket::api('luarun app.lua voicemail mwi '.$e['number'].'@'.$e['domain_name']);}catch(Throwable){}}
    public static function qr(string $payload): string {
        require_once PROJECT_ROOT.'/resources/qr_code/QRCode.php';$qr=new QRCode(0,0);$qr->addData($payload);$qr->make();$n=$qr->getModuleCount();$path='';for($y=0;$y<$n;$y++)for($x=0;$x<$n;$x++)if($qr->isDark($y,$x))$path.='M'.($x+4).' '.($y+4).'h1v1h-1z';$size=$n+8;return '<svg xmlns="http://www.w3.org/2000/svg" role="img" aria-label="Scan to connect this phone" viewBox="0 0 '.$size.' '.$size.'" width="325" height="325" style="max-width:100%;height:auto;shape-rendering:crispEdges"><rect width="100%" height="100%" fill="white"/><path fill="black" d="'.$path.'"/></svg>';
    }
}
