<?php
/** Dedicated browser/image enrollment. Owner bearer secrets never reach an image. */
class pbx_wizard_api {
    public const ORIGIN='https://openwebpbx.com';
    public const URI=self::ORIGIN.'/wizard';
    public function __construct(private PDO $db,private ?pbx_tenant_api $api=null) { $this->api??=new pbx_tenant_api($db); }
    private function q(string $sql,array $params=[]): PDOStatement { $q=$this->db->prepare($sql);$q->execute($params);return $q; }
    private function fail(int $status,string $code,string $message): never { throw new pbx_tenant_api_error($status,$code,$message); }
    private function fields(array $input,array $required,array $optional=[]): void {
        if(array_diff($required,array_keys($input))||array_diff(array_keys($input),array_merge($required,$optional)))$this->fail(400,'invalid_request','Check the information supplied to the setup wizard.');
    }
    private function id(mixed $id): string {if(!is_string($id)||!is_uuid($id)||$id!==strtolower($id)||$id==='00000000-0000-0000-0000-000000000000')$this->fail(400,'invalid_request','Use the server identifier supplied by your installation.');return $id;}
    public static function address(string $value): string {
        $raw=@inet_pton($value);if($raw===false)throw new InvalidArgumentException('Use the public server address.');
        $value=inet_ntop($raw);
        if(strlen($raw)===4){$b=array_values(unpack('C*',$raw));
            if(in_array($b[0],[0,10,127],true)||$b[0]>=224||($b[0]===169&&$b[1]===254)||($b[0]===172&&$b[1]>=16&&$b[1]<=31)
                ||($b[0]===192&&($b[1]===168||($b[1]===0&&in_array($b[2],[0,2],true))||($b[1]===88&&$b[2]===99)))
                ||($b[0]===100&&$b[1]>=64&&$b[1]<=127)||($b[0]===198&&in_array($b[1],[18,19],true))
                ||($b[0]===198&&$b[1]===51&&$b[2]===100)||($b[0]===203&&$b[1]===0&&$b[2]===113))throw new InvalidArgumentException('The server needs a reachable public address.');
        }else{$b=array_values(unpack('C*',$raw));
            if($b[0]<0x20||$b[0]>0x3f||($b[0]===0x20&&$b[1]===0x01&&($b[2]<2||($b[2]===0x0d&&$b[3]===0xb8)))
                ||($b[0]===0x20&&$b[1]===0x02)||($b[0]===0x3f&&$b[1]===0xff&&($b[2]&0xf0)===0))throw new InvalidArgumentException('The server needs a reachable public address.');
        }
        return $value;
    }
    private function userCode(mixed $value): string {
        if(!is_string($value)||strlen($value)>24)$this->fail(400,'pairing_invalid','Enter the setup code shown by your server.');
        $value=strtoupper(str_replace(['-',' '],'',$value));if(!preg_match('/^[A-F0-9]{10}$/D',$value))$this->fail(400,'pairing_invalid','Enter the setup code shown by your server.');return $value;
    }
    private function account(array $row): array {
        if(!is_uuid($row['account_tenant_uuid']??'')||!is_uuid($row['account_user_uuid']??''))$this->fail(409,'claim_required','Connect this server to your account in the setup wizard.');
        $r=$this->q("select t.tenant_uuid,u.user_uuid from v_pbx_tenants t join v_users u on u.user_uuid=t.owner_user_uuid
            where t.tenant_uuid=? and u.user_uuid=? and t.enabled and u.user_enabled::text='true'
            and exists(select 1 from v_user_groups ug join v_groups g on g.group_uuid=ug.group_uuid
                where ug.user_uuid=u.user_uuid and ug.group_name='tenant_admin' and g.group_name='tenant_admin' and g.domain_uuid is null)",[$row['account_tenant_uuid'],$row['account_user_uuid']])->fetch(PDO::FETCH_ASSOC);
        if(!$r)$this->fail(403,'account_unavailable','This account cannot authorize the server. Contact the account administrator.');return $r;
    }
    private function verified(array $account): void {
        $ok=$this->q("select exists(select 1 from v_users u join v_pbx_tenants t on t.owner_user_uuid=u.user_uuid
            where t.tenant_uuid=? and u.user_uuid=? and (
                exists(select 1 from v_pbx_api_registrations r where r.tenant_uuid=t.tenant_uuid and r.verified_at is not null and lower(r.email)=lower(u.user_email) and lower(t.invite_email)=lower(u.user_email))
                or exists(select 1 from v_pbx_installation_email_verifications v where v.account_tenant_uuid=t.tenant_uuid and v.account_user_uuid=u.user_uuid and v.email=lower(u.user_email) and v.verified_at is not null)))",[$account['tenant_uuid'],$account['user_uuid']])->fetchColumn();
        if(!in_array($ok,[true,'t','1',1],true))$this->fail(403,'verified_account_required','Confirm your account email before connecting this server.');
    }
    protected function authority(): pbx_installation_authority {return new pbx_installation_authority($this->db);}
    protected function rpc(string $operation,array $value): array {
        if(!in_array($operation,['bootstrap-instance','verify-tenant-ready'],true))throw new LogicException('Unknown enrollment operation.');
        $c=curl_init('http://127.0.0.1:5095/internal/v1/'.$operation);$raw='';
        curl_setopt_array($c,[CURLOPT_POST=>true,CURLOPT_POSTFIELDS=>json_encode($value,JSON_THROW_ON_ERROR),CURLOPT_HTTPHEADER=>['Content-Type: application/json','Accept: application/json'],CURLOPT_FOLLOWLOCATION=>false,CURLOPT_PROXY=>'',CURLOPT_CONNECTTIMEOUT=>3,CURLOPT_TIMEOUT=>35,CURLOPT_PROTOCOLS=>CURLPROTO_HTTP,CURLOPT_WRITEFUNCTION=>static function($handle,string $chunk)use(&$raw):int{if(strlen($raw)+strlen($chunk)>8192)return 0;$raw.=$chunk;return strlen($chunk);}]);
        $ok=curl_exec($c);$status=curl_getinfo($c,CURLINFO_RESPONSE_CODE);curl_close($c);
        if($ok===false||$status!==200)$this->fail(503,'server_preparing','Your server is still being checked. Keep the server running and try again shortly.');
        $reply=json_decode($raw,true,12,JSON_THROW_ON_ERROR);if(!is_array($reply))throw new RuntimeException('Enrollment response unavailable.');return $reply;
    }
    private function device(mixed $code,bool $lock=false): array {
        if(!is_string($code)||!preg_match('/^owpd_[a-f0-9]{64}$/D',$code))$this->fail(401,'device_invalid','The server setup session is unavailable. Start setup again on the server.');
        $r=$this->q('select * from v_pbx_wizard_devices where device_hash=?'.($lock?' for update':''),[hash('sha256',$code)])->fetch(PDO::FETCH_ASSOC);
        if(!$r||$r['state']==='revoked'||(strtotime($r['expires_at'])<=time()&&(!in_array($r['state'],['authorized','complete'],true)||strtotime($r['activation_expires_at']??'')<=time())))$this->fail(401,'device_expired','The server setup session expired. Start setup again on the server.');return $r;
    }
    private function view(array $r): array {
        return ['pairing_uuid'=>$r['pairing_uuid'],'state'=>$r['state'],'provider'=>$r['provider'],'image_version'=>$r['image_version'],
            'server_address'=>$r['server_address'],'label'=>$r['label'],'server_host'=>$r['server_host'],
            'ready'=>$r['state']==='complete','tenant_url'=>$r['state']==='complete'?'https://'.$r['tenant_hostname']:null,
            'admin_url'=>$r['state']==='complete'?'https://'.$r['tenant_hostname'].'/admin':null,
            'expires_at'=>(new DateTimeImmutable($r['expires_at']))->setTimezone(new DateTimeZone('UTC'))->format(DATE_RFC3339)];
    }
    private function signature(array $r,mixed $signature,string $message): string {
        if(!is_string($signature)||strlen($signature)>200||!($decoded=base64_decode($signature,true)))$this->fail(400,'signature_invalid','The server identity could not be confirmed.');
        $key=pbx_installation_authority::publicKey($r['public_key']);if(openssl_verify($message,$decoded,$key['pem'],OPENSSL_ALGO_SHA256)!==1)$this->fail(403,'signature_invalid','The server identity could not be confirmed.');return $signature;
    }
    public function start(array $input,string $ip): array {
        $this->fields($input,['provider','image_version','public_key','local_tenant_uuid','domain_uuid'],['bootstrap_uuid']);$address=self::address($ip);
        if(!in_array($input['provider'],['webhotel','debian'],true)||!is_string($input['image_version'])||!preg_match('/^[A-Za-z0-9][A-Za-z0-9._+-]{0,63}$/D',$input['image_version']))$this->fail(400,'invalid_image','Use an up-to-date OpenWeb PBX image.');
        $key=pbx_installation_authority::publicKey($input['public_key']);$tenant=$this->id($input['local_tenant_uuid']);$domain=$this->id($input['domain_uuid']);
        $this->api->rate('wizard:start:'.$address,5,3600);$this->api->rate('wizard:start:global',100,86400);
        $bootstrap=isset($input['bootstrap_uuid'])?$this->id($input['bootstrap_uuid']):uuid();
        if(!preg_match('/^[a-f0-9]{8}-[a-f0-9]{4}-4[a-f0-9]{3}-[89ab][a-f0-9]{3}-[a-f0-9]{12}$/D',$bootstrap))$this->fail(400,'invalid_request','Use the server identifier supplied by your installation.');
        $private='owpd_'.bin2hex(random_bytes(32));$user=strtoupper(bin2hex(random_bytes(5)));$pairing=uuid();$nonce=bin2hex(random_bytes(32));
        $this->db->beginTransaction();try{
            $this->q('select pg_advisory_xact_lock(hashtextextended(?,0))',['wizard:'.$key['hash']]);
            $old=$this->q('select * from v_pbx_wizard_devices where bootstrap_uuid=? for update',[$bootstrap])->fetch(PDO::FETCH_ASSOC);
            if($old){
                foreach(['key_hash'=>$key['hash'],'local_tenant_uuid'=>$tenant,'domain_uuid'=>$domain,'server_address'=>$address]as$field=>$expected)if($old[$field]!==$expected)$this->fail(409,'server_identity_changed','Start setup using the original server identity.');
                if($old['state']==='revoked'||strtotime($old['expires_at'])>time()||strtotime($old['activation_expires_at']??'')>time())$this->fail(409,'setup_already_started','This server already has a setup session. Reopen its existing setup link.');
                // An expired code may be replaced by this same immutable image identity.
                // Retain its claimed owner/label and allocated canonical DNS binding.
                $expires=$this->q("update v_pbx_wizard_devices set pairing_uuid=?,device_hash=?,user_code_hash=?,expires_at=now()+interval '30 minutes',challenge_uuid=null,activation=null,activation_expires_at=null,complete_nonce=null,tenant_hostname=null,state=case when server_host is not null then 'dns_ready' when account_tenant_uuid is not null then 'claimed' else 'pending' end,updated_at=now() where bootstrap_uuid=? returning expires_at",[$pairing,hash('sha256',$private),hash('sha256',$user),$bootstrap])->fetchColumn();
            }else{
            if($this->q("select 1 from v_pbx_wizard_devices where key_hash=? and local_tenant_uuid=? and domain_uuid=? and state<>'revoked' and (expires_at>now() or activation_expires_at>now()) limit 1",[$key['hash'],$tenant,$domain])->fetchColumn())$this->fail(409,'setup_already_started','This server already has a setup session. Reopen its existing setup link.');
            $expires=$this->q("insert into v_pbx_wizard_devices(pairing_uuid,bootstrap_uuid,provider,image_version,server_address,local_tenant_uuid,domain_uuid,public_key,key_hash,device_hash,user_code_hash,bootstrap_nonce,expires_at)
                values(?,?,?,?,?,?,?,?,?,?,?,?,now()+interval '30 minutes') returning expires_at",[$pairing,$bootstrap,$input['provider'],$input['image_version'],$address,$tenant,$domain,$key['encoded'],$key['hash'],hash('sha256',$private),hash('sha256',$user),$nonce])->fetchColumn();
            }
            $this->db->commit();
        }catch(Throwable$e){if($this->db->inTransaction())$this->db->rollBack();throw$e;}
        $display=substr($user,0,5).'-'.substr($user,5);return ['pairing_uuid'=>$pairing,'device_code'=>$private,'user_code'=>$display,'verification_uri'=>self::URI,'verification_uri_complete'=>self::URI.'#code='.$display,
            'expires_at'=>(new DateTimeImmutable($expires))->setTimezone(new DateTimeZone('UTC'))->format(DATE_RFC3339),'poll_interval'=>5];
    }
    public function lookup(array $input,string $ip): array {
        $this->fields($input,['user_code']);$this->api->rate('wizard:lookup:'.$ip,30,600);$code=$this->userCode($input['user_code']);
        $r=$this->q("select * from v_pbx_wizard_devices where user_code_hash=? and expires_at>now() and state<>'revoked'",[hash('sha256',$code)])->fetch(PDO::FETCH_ASSOC);
        if(!$r)$this->fail(404,'pairing_unavailable','This setup code is unavailable or expired. Check the code shown on your server.');
        return array_intersect_key($this->view($r),array_flip(['pairing_uuid','state','provider','image_version','server_address','expires_at']));
    }
    public function claim(array $account,array $input): array {
        $this->fields($input,['user_code','label','confirm_server','accept_terms']);if($input['confirm_server']!==true||$input['accept_terms']!==true)$this->fail(400,'confirmation_required','Confirm the server and accept the terms before continuing.');
        $label=is_string($input['label'])?pbx_tenant_api_domains::label($input['label']):'';if($label==='')$this->fail(400,'invalid_subdomain','Choose your OpenWeb PBX address.');
        $this->verified($account);$code=$this->userCode($input['user_code']);$this->api->rate('wizard:claim:'.$account['tenant_uuid'],10,3600);
        $this->db->beginTransaction();try{
            $r=$this->q("select * from v_pbx_wizard_devices where user_code_hash=? and expires_at>now() and state<>'revoked' for update",[hash('sha256',$code)])->fetch(PDO::FETCH_ASSOC);
            if(!$r)$this->fail(404,'pairing_unavailable','This setup code is unavailable or expired. Check the code shown on your server.');
            if($r['account_tenant_uuid']!==null){if($r['account_tenant_uuid']!==$account['tenant_uuid']||$r['account_user_uuid']!==$account['user_uuid']||$r['label']!==$label)$this->fail(409,'server_already_claimed','This server has already been connected to another setup.');}
            else{
                $this->q('select pg_advisory_xact_lock(hashtextextended(?,0))',['wizard:owner:'.$account['tenant_uuid']]);
                if((int)$this->q("select count(*) from v_pbx_wizard_devices where account_tenant_uuid=? and state<>'revoked'",[$account['tenant_uuid']])->fetchColumn()>=50)$this->fail(409,'installation_limit','This account has reached its server setup limit.');
                $this->q("update v_pbx_wizard_devices set account_tenant_uuid=?,account_user_uuid=?,label=?,claimed_at=now(),terms_version='2026-10-29',state='claimed',updated_at=now() where pairing_uuid=?",[$account['tenant_uuid'],$account['user_uuid'],$label,$r['pairing_uuid']]);$r['account_tenant_uuid']=$account['tenant_uuid'];$r['account_user_uuid']=$account['user_uuid'];$r['label']=$label;$r['state']='claimed';
            }
            $this->account($r);$this->db->commit();return $this->view($r);
        }catch(Throwable$e){if($this->db->inTransaction())$this->db->rollBack();throw$e;}
    }
    public function poll(array $input,string $ip): array {
        $this->fields($input,['device_code']);$r=$this->device($input['device_code']);$this->api->rate('wizard:poll:'.$r['pairing_uuid'],120,60);
        $out=$this->view($r)+['bootstrap_uuid'=>$r['bootstrap_uuid'],'local_tenant_uuid'=>$r['local_tenant_uuid'],'domain_uuid'=>$r['domain_uuid'],'key_hash'=>$r['key_hash'],'account_tenant_uuid'=>$r['account_tenant_uuid']];
        if($r['account_tenant_uuid']){
            $this->account($r);$out['nonce']=$r['bootstrap_nonce'];$out['proof_path']='/.well-known/openwebpbx-instance/'.$r['bootstrap_nonce'];
            $out['proof_body']="openwebpbx-bootstrap-v1\n".$r['bootstrap_nonce']."\n".$r['key_hash']."\n".$r['server_address']."\n";
        }
        if($r['activation'])$out['activation']=json_decode($r['activation'],true,8,JSON_THROW_ON_ERROR);
        if($r['complete_nonce'])$out['complete_nonce']=$r['complete_nonce'];
        return $out;
    }
    public function bootstrap(array $input): array {
        $this->fields($input,['device_code','signature']);$r=$this->device($input['device_code']);$account=$this->account($r);$this->verified($account);
        $message="openwebpbx-bootstrap-v1\n".$r['bootstrap_nonce']."\n".$r['server_address']."\n".$r['key_hash']."\n".$r['bootstrap_uuid']."\n".$r['account_tenant_uuid']."\n".$r['local_tenant_uuid']."\n".$r['domain_uuid']."\n".$r['label']."\n";
        $signature=$this->signature($r,$input['signature'],$message);$this->api->rate('wizard:bootstrap:'.$r['pairing_uuid'],10,600);
        $reply=$this->rpc('bootstrap-instance',['installationUuid'=>$r['bootstrap_uuid'],'accountTenantUuid'=>$r['account_tenant_uuid'],'serverAddress'=>$r['server_address'],'nonce'=>$r['bootstrap_nonce'],'keyHash'=>$r['key_hash'],'localTenantUuid'=>$r['local_tenant_uuid'],'domainUuid'=>$r['domain_uuid'],'label'=>$r['label'],'signature'=>$signature,'publicKey'=>$r['public_key']]);
        $expected='node-'.str_replace('-','',$r['bootstrap_uuid']).'.openwebpbx.com';
        if(($reply['serverHost']??'')!==$expected||($reply['address']??'')!==$r['server_address']||!in_array($reply['state']??'',['dns_ready','pending_dns'],true))throw new RuntimeException('The registered server address differs from this installation.');
        $state=$reply['state']==='dns_ready'?'dns_ready':'bootstrap_pending';
        $this->q("update v_pbx_wizard_devices set server_host=?,state=?,updated_at=now() where pairing_uuid=? and account_tenant_uuid=? and state in ('claimed','bootstrap_pending','dns_ready')",[$expected,$state,$r['pairing_uuid'],$r['account_tenant_uuid']]);
        $r['server_host']=$expected;$r['state']=$state;return $this->view($r);
    }
    public function challenge(array $input): array {
        $this->fields($input,['device_code']);$r=$this->device($input['device_code']);$account=$this->account($r);
        if(!in_array($r['state'],['dns_ready','authorized','complete'],true)||!is_string($r['server_host']))$this->fail(409,'server_preparing','Your server address is still being prepared.');
        $this->api->rate('wizard:challenge:'.$r['pairing_uuid'],10,600);
        $reply=$this->authority()->challenge($account,['server_host'=>$r['server_host'],'public_key'=>$r['public_key'],'local_tenant_uuid'=>$r['local_tenant_uuid'],'domain_uuid'=>$r['domain_uuid'],'label'=>$r['label']]);
        $this->q('update v_pbx_wizard_devices set challenge_uuid=?,updated_at=now() where pairing_uuid=?',[$reply['challenge_uuid'],$r['pairing_uuid']]);return $reply;
    }
    public function authorize(array $input): array {
        $this->fields($input,['device_code','challenge_uuid','signature']);$r=$this->device($input['device_code']);$account=$this->account($r);
        if(($r['challenge_uuid']??'')!==$this->id($input['challenge_uuid']))$this->fail(409,'challenge_changed','Ask the server to request a new setup check.');
        $this->api->rate('wizard:authorize:'.$r['pairing_uuid'],10,600);
        $reply=$this->authority()->authorize($account,['challenge_uuid'=>$r['challenge_uuid'],'signature'=>$input['signature']]);
        $a=$reply['activation']??null;$raw=is_array($a)?base64_decode(strtr($a['payload']??'','-_','+/'),true):false;$payload=$raw?json_decode($raw,true,8,JSON_THROW_ON_ERROR):null;
        if(!is_array($payload))throw new RuntimeException('The installation authorization is unavailable.');
        foreach(['account_tenant_uuid','local_tenant_uuid','domain_uuid','key_hash','server_host','label']as$field)if(($payload[$field]??null)!==$r[$field])throw new RuntimeException('The installation authorization belongs to a different server.');
        $this->q("update v_pbx_wizard_devices set activation=cast(? as jsonb),activation_expires_at=?,installation_uuid=?,state='authorized',complete_nonce=?,updated_at=now() where pairing_uuid=?",[json_encode($a,JSON_THROW_ON_ERROR),$payload['expires_at'],$payload['installation_uuid'],bin2hex(random_bytes(32)),$r['pairing_uuid']]);return $reply;
    }
    public function complete(array $input): array {
        $this->fields($input,['device_code','hostname','signature']);$r=$this->device($input['device_code']);$account=$this->account($r);$this->verified($account);
        if(!in_array($r['state'],['authorized','complete'],true)||!is_string($r['complete_nonce']))$this->fail(409,'authorization_required','Your server authorization is still being prepared.');
        $host=$input['hostname'];if(!is_string($host)||!preg_match('/^[a-z0-9][a-z0-9-]{1,61}[a-z0-9]\.openwebpbx\.com$/D',$host))$this->fail(400,'invalid_subdomain','Use the tenant address assigned to this server.');
        $this->signature($r,$input['signature'],"openwebpbx-complete-v1\n".$r['complete_nonce']."\n".$r['key_hash']."\n".$r['server_host']."\n".$host."\n".$r['domain_uuid']."\n");
        $this->api->rate('wizard:complete:'.$r['pairing_uuid'],10,600);
        $reply=$this->rpc('verify-tenant-ready',['hostname'=>$host,'serverHost'=>$r['server_host'],'keyHash'=>$r['key_hash'],'domainUuid'=>$r['domain_uuid'],'nonce'=>$r['complete_nonce']]);
        if(($reply['verified']??false)!==true)$this->fail(503,'server_preparing','Your tenant address is still being checked.');
        $this->q("update v_pbx_wizard_devices set tenant_hostname=?,state='complete',updated_at=now() where pairing_uuid=?",[$host,$r['pairing_uuid']]);$r['tenant_hostname']=$host;$r['state']='complete';return $this->view($r);
    }
    public function status(array $account,string $id): array {
        $r=$this->q('select * from v_pbx_wizard_devices where pairing_uuid=? and account_tenant_uuid=? and account_user_uuid=?',[$this->id($id),$account['tenant_uuid'],$account['user_uuid']])->fetch(PDO::FETCH_ASSOC);
        if(!$r)$this->fail(404,'setup_unavailable','This server setup is unavailable.');$this->account($r);return $this->view($r);
    }
}
