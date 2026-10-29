<?php
/** Central, email-verified installation grants; independent of release signing. */
class pbx_installation_authority {
    public const ISSUER='https://call.openweb.co.za/api/v1';
    public const AUDIENCE='openwebpbx-installation';
    public const KEY_ID='installation-2026-a';
    private const MAX_AUTHORIZATIONS=50;
    public function __construct(private PDO $db) {}
    private function q(string $sql,array $params=[]): PDOStatement {
        $q=$this->db->prepare($sql);$q->execute($params);return $q;
    }
    private function fail(int $status,string $code,string $message): never {throw new pbx_tenant_api_error($status,$code,$message);}
    private function fields(array $input,array $keys): void {
        $actual=array_keys($input);sort($actual);$expected=$keys;sort($expected);
        if($actual!==$expected)$this->fail(400,'invalid_request','Check the installation fields.');
    }
    private function id(mixed $value): string {
        if(!is_string($value)||!is_uuid($value)||$value!==strtolower($value)||$value==='00000000-0000-0000-0000-000000000000')$this->fail(400,'invalid_request','Use a valid lowercase installation identifier.');return $value;
    }
    public static function base64url(string $bytes): string {return rtrim(strtr(base64_encode($bytes),'+/','-_'),'=');}
    public static function serverHost(mixed $host): string {
        if(!is_string($host)||strlen($host)>253||$host!==strtolower($host)||filter_var($host,FILTER_VALIDATE_IP)
            ||!preg_match('/^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?(?:\.[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?)+$/D',$host)
            ||in_array($host,['openwebpbx.com','localhost'],true)||(str_ends_with($host,'.openwebpbx.com')&&!preg_match('/^node-[0-9a-f]{32}\.openwebpbx\.com$/D',$host))||str_ends_with($host,'.local')||str_ends_with($host,'.localhost')||str_ends_with($host,'.invalid'))throw new InvalidArgumentException('Use the installation public hostname, without a URL, port or path.');
        return $host;
    }
    public static function publicKey(mixed $encoded): array {
        if(!is_string($encoded)||strlen($encoded)<80||strlen($encoded)>200)throw new InvalidArgumentException('Use the installation P256 public key.');
        $der=base64_decode($encoded,true);
        if(!is_string($der)||base64_encode($der)!==$encoded)throw new InvalidArgumentException('Use the installation P256 public key.');
        $pem="-----BEGIN PUBLIC KEY-----\n".chunk_split($encoded,64,"\n")."-----END PUBLIC KEY-----\n";
        $key=@openssl_pkey_get_public($pem);$details=$key?openssl_pkey_get_details($key):false;
        if(!$details||$details['type']!==OPENSSL_KEYTYPE_EC||$details['bits']!==256||($details['ec']['curve_oid']??'')!=='1.2.840.10045.3.1.7')throw new InvalidArgumentException('Use the installation P256 public key.');
        $canonical=base64_decode(preg_replace('/-----[^-]+-----|\s+/','',$details['key']),true);
        if(!is_string($canonical)||!hash_equals($der,$canonical))throw new InvalidArgumentException('Use canonical P256 public key encoding.');
        return ['encoded'=>$encoded,'pem'=>$pem,'hash'=>hash('sha256',$der)];
    }
    private function account(array $account,bool $lock=false,bool $requireVerified=true): array {
        $tenant=$this->id($account['tenant_uuid']??'');$user=$this->id($account['user_uuid']??'');
        $verified=" and (exists(select 1 from v_pbx_api_registrations r where r.tenant_uuid=t.tenant_uuid and r.verified_at is not null
                and lower(r.email)=lower(u.user_email) and lower(t.invite_email)=lower(u.user_email))
            or exists(select 1 from v_pbx_installation_email_verifications v where v.account_tenant_uuid=t.tenant_uuid
                and v.account_user_uuid=u.user_uuid and v.email=lower(u.user_email) and v.verified_at is not null))";
        $r=$this->q("select t.tenant_uuid,t.owner_user_uuid,u.user_email,t.tenant_name from v_pbx_tenants t join v_users u on u.user_uuid=t.owner_user_uuid
            where t.tenant_uuid=? and u.user_uuid=? and t.enabled=true and u.user_enabled::text='true'
            and exists(select 1 from v_user_groups ug join v_groups g on g.group_uuid=ug.group_uuid where ug.user_uuid=u.user_uuid and ug.group_name='tenant_admin' and g.group_name='tenant_admin' and g.domain_uuid is null)"
            .($requireVerified?$verified:'')
            .($lock?' for share of t,u':''),[$tenant,$user])->fetch(PDO::FETCH_ASSOC);
        if(!$r)$this->fail(403,'verified_account_required','Register and verify your email with the OpenWeb PBX API before authorizing an installation.');
        return $r;
    }
    protected function queueOwnerEmail(array $owner,string $token): void {
        $platform=$this->q('select domain_uuid from v_domains where domain_name=?',[pbx_paths::host()])->fetchColumn();
        if(!is_string($platform))throw new RuntimeException('The installation mail domain is unavailable.');
        $h=static fn(string $text):string=>htmlspecialchars($text,ENT_QUOTES|ENT_SUBSTITUTE,'UTF-8');
        $body='<h1>Confirm your OpenWeb PBX administrator email</h1><p>You requested installation authorization for '.$h($owner['tenant_name']).'.</p>'
            .'<p>Your one-use email verification code is:</p><p><code>'.$token.'</code></p>'
            .'<p>Send it as <code>token</code>, with your current administrator <code>password</code>, to <code>POST '.self::ISSUER.'/onboarding/email/verify</code>. It expires in 30 minutes.</p>'
            .'<p>If you did not request this code, ignore this email. No new installation has been authorized.</p>';
        $this->q("insert into v_email_queue(email_queue_uuid,domain_uuid,hostname,email_date,email_from,email_to,email_subject,email_body,email_status) values(?,?,?,now(),'',?,'Confirm your OpenWeb PBX email',?,'waiting')",[uuid(),$platform,gethostname(),$owner['user_email'],$body]);
    }
    public function requestEmail(array $account,array $input): array {
        $this->fields($input,[]);$owner=$this->account($account,false,false);$email=strtolower($owner['user_email']);
        if(!filter_var($email,FILTER_VALIDATE_EMAIL)||strlen($email)>254||preg_match('/[\x00-\x1f\x7f]/',$email))$this->fail(400,'email_unavailable','Ask your administrator to set a valid current email address.');
        $token=bin2hex(random_bytes(32));$this->db->beginTransaction();try{
            $owner=$this->account($account,true,false);
            if(strtolower($owner['user_email'])!==$email)$this->fail(409,'email_changed','Your account email changed. Request a new code.');
            $this->q("insert into v_pbx_installation_email_verifications(verification_uuid,account_tenant_uuid,account_user_uuid,email,verification_hash,expires_at)
                values(?,?,?,?,?,now()+interval '30 minutes') on conflict(account_tenant_uuid,account_user_uuid,email)
                do update set verification_hash=excluded.verification_hash,expires_at=excluded.expires_at,updated_at=now()",[uuid(),$account['tenant_uuid'],$account['user_uuid'],$email,hash('sha256',$token)]);
            $owner['user_email']=$email;$this->queueOwnerEmail($owner,$token);$this->db->commit();
            return ['status'=>'verification_required','message'=>'A one-use verification code has been queued for your current administrator email.'];
        }catch(Throwable $e){if($this->db->inTransaction())$this->db->rollBack();throw $e;}
    }
    public function verifyEmail(array $account,array $input): array {
        $this->fields($input,['token','password']);$owner=$this->account($account,false,false);
        if(!is_string($input['token'])||!preg_match('/^[a-f0-9]{64}$/D',$input['token'])||!is_string($input['password'])||strlen($input['password'])<1||strlen($input['password'])>72||preg_match('/[\x00-\x1f\x7f]/',$input['password']))$this->fail(400,'email_verification_invalid','The email verification details are invalid or expired.');
        $this->db->beginTransaction();try{
            $owner=$this->account($account,true,false);$email=strtolower($owner['user_email']);
            $row=$this->q('select verification_uuid from v_pbx_installation_email_verifications where account_tenant_uuid=? and account_user_uuid=? and email=? and verification_hash=? and expires_at>now() for update',[$account['tenant_uuid'],$account['user_uuid'],$email,hash('sha256',$input['token'])])->fetch(PDO::FETCH_ASSOC);
            if(!$row)$this->fail(400,'email_verification_invalid','The email verification details are invalid or expired.');
            $password=$this->q('select password from v_users where user_uuid=?',[$account['user_uuid']])->fetchColumn();
            if(!is_string($password)||!password_verify($input['password'],$password))$this->fail(401,'current_password_invalid','The current administrator password is incorrect.');
            $this->q('update v_pbx_installation_email_verifications set verification_hash=null,verified_at=now(),updated_at=now() where verification_uuid=?',[$row['verification_uuid']]);
            $this->q('insert into v_pbx_api_audit(audit_uuid,tenant_uuid,user_uuid,action,target_uuid) values(?,?,?,?,?)',[uuid(),$account['tenant_uuid'],$account['user_uuid'],'installation_email_verified',$row['verification_uuid']]);
            $this->db->commit();return ['verified'=>true,'email'=>$email];
        }catch(Throwable $e){if($this->db->inTransaction())$this->db->rollBack();throw $e;}
    }
    protected function publicPem(): string {
        $path=dirname(__DIR__).'/keys/installation-authority.pem';
        if(is_link($path)||!is_file($path)||filesize($path)>8192)throw new RuntimeException('Installation authority public key is unavailable.');
        $pem=file_get_contents($path);$key=is_string($pem)?@openssl_pkey_get_public($pem):false;$details=$key?openssl_pkey_get_details($key):false;
        if(!$details||$details['type']!==OPENSSL_KEYTYPE_RSA||$details['bits']!==3072)throw new RuntimeException('Installation authority public key is invalid.');return $details['key'];
    }
    protected function signingKey(): OpenSSLAsymmetricKey {
        $path=(string)config::load()->get('openweb.onboarding_authority_key','/etc/openwebpbx/installation-authority.key');
        if($path===''||!str_starts_with($path,'/')||!is_file($path)||filesize($path)>16384)throw new RuntimeException('Installation authority signing key is unavailable.');
        for($node=$path;;$node=dirname($node)){if(is_link($node))throw new RuntimeException('Linked installation authority key refused.');if($node===dirname($node))break;}
        if(PHP_OS_FAMILY!=='Windows'&&(fileowner($path)!==0||!in_array(fileperms($path)&0777,[0600,0640],true)))throw new RuntimeException('Private installation authority key required.');
        $key=@openssl_pkey_get_private(file_get_contents($path));$details=$key?openssl_pkey_get_details($key):false;
        if(!$details||$details['type']!==OPENSSL_KEYTYPE_RSA||$details['bits']!==3072||!hash_equals($this->publicPem(),$details['key']))throw new RuntimeException('Installation signing identity differs from its pinned public key.');return $key;
    }
    public function authority(): array {return ['schema'=>1,'issuer'=>self::ISSUER,'key_id'=>self::KEY_ID,'algorithm'=>'RS256','public_key_pem'=>$this->publicPem()];}
    public static function message(array $r): string {
        return "openwebpbx-installation-v1\n".$r['nonce']."\n".$r['server_host']."\n".$r['key_hash']."\n".$r['account_tenant_uuid']."\n".$r['local_tenant_uuid']."\n".$r['domain_uuid']."\n".$r['label']."\n";
    }
    /** Existing central registry owns the qualified public-DNS/HTTPS/SSRF boundary. */
    protected function verifySiteProof(array $r): void {
        if(!function_exists('curl_init'))throw new RuntimeException('The local proof client is unavailable.');
        $body=json_encode(['serverHost'=>$r['server_host'],'nonce'=>$r['nonce'],'keyHash'=>$r['key_hash']],JSON_THROW_ON_ERROR);
        $curl=curl_init('http://127.0.0.1:5095/internal/v1/verify-instance-proof');$response='';
        if(!$curl)throw new RuntimeException('The local proof client is unavailable.');
        try {
            curl_setopt_array($curl,[CURLOPT_POST=>true,CURLOPT_POSTFIELDS=>$body,CURLOPT_HTTPHEADER=>['Content-Type: application/json','Accept: application/json'],
                CURLOPT_FOLLOWLOCATION=>false,CURLOPT_MAXREDIRS=>0,CURLOPT_PROXY=>'',CURLOPT_CONNECTTIMEOUT=>3,CURLOPT_TIMEOUT=>18,
                CURLOPT_PROTOCOLS=>CURLPROTO_HTTP,CURLOPT_REDIR_PROTOCOLS=>CURLPROTO_HTTP,
                CURLOPT_WRITEFUNCTION=>static function($handle,string $bytes)use(&$response):int{if(strlen($response)+strlen($bytes)>1024)return 0;$response.=$bytes;return strlen($bytes);}]);
            $ok=curl_exec($curl);$status=curl_getinfo($curl,CURLINFO_RESPONSE_CODE);
            if($ok===false||$status===429||$status>=500)throw new RuntimeException('Installation hostname verification is temporarily unavailable.');
            if($status!==200)$this->fail(403,'installation_proof_required','Publish the installation ownership proof at its trusted HTTPS hostname, then try again.');
            $value=json_decode($response,true,4,JSON_THROW_ON_ERROR);
            if($value!==['verified'=>true])throw new RuntimeException('The installation proof service returned an invalid result.');
        }finally{curl_close($curl);}
    }
    public function challenge(array $account,array $input): array {
        $this->fields($input,['server_host','public_key','local_tenant_uuid','domain_uuid','label']);$this->account($account);
        $host=self::serverHost($input['server_host']);$key=self::publicKey($input['public_key']);$local=$this->id($input['local_tenant_uuid']);$domain=$this->id($input['domain_uuid']);$label=pbx_tenant_api_domains::label($input['label']);
        $id=uuid();$nonce=bin2hex(random_bytes(32));
        $until=$this->q("insert into v_pbx_installation_challenges(challenge_uuid,account_tenant_uuid,account_user_uuid,nonce,public_key,key_hash,server_host,local_tenant_uuid,domain_uuid,label,expires_at)
            values(?,?,?,?,?,?,?,?,?,?,now()+interval '5 minutes') returning expires_at",[$id,$account['tenant_uuid'],$account['user_uuid'],$nonce,$key['encoded'],$key['hash'],$host,$local,$domain,$label])->fetchColumn();
        $this->q("delete from v_pbx_installation_challenges where expires_at<now()-interval '1 day'");
        return ['challenge_uuid'=>$id,'nonce'=>$nonce,'expires_at'=>(new DateTimeImmutable($until))->format(DATE_RFC3339),
            'proof_path'=>'/.well-known/openwebpbx-instance/'.$nonce,'proof_body'=>"openwebpbx-instance-v1\n".$nonce."\n".$key['hash']."\n".$host."\n",
            'key_hash'=>$key['hash'],'account_tenant_uuid'=>$account['tenant_uuid']];
    }
    private function installationView(array $r): array {
        $out=[];foreach(['installation_uuid','account_tenant_uuid','local_tenant_uuid','domain_uuid','key_hash','server_host','label','state']as$key)$out[$key]=$r[$key];
        $out['generation']=(int)$r['generation'];foreach(['issued_at','expires_at','created_at','updated_at']as$key)$out[$key]=(new DateTimeImmutable($r[$key]))->format(DATE_RFC3339);return $out;
    }
    public function authorize(array $account,array $input): array {
        $this->fields($input,['challenge_uuid','signature']);$id=$this->id($input['challenge_uuid']);$this->account($account);
        if(!is_string($input['signature'])||strlen($input['signature'])>200||!is_string($signature=base64_decode($input['signature'],true))||base64_encode($signature)!==$input['signature'])$this->fail(400,'invalid_signature','Use the installation signature.');
        $r=$this->q('select * from v_pbx_installation_challenges where challenge_uuid=? and account_tenant_uuid=? and account_user_uuid=? and consumed_at is null and expires_at>now()',[$id,$account['tenant_uuid'],$account['user_uuid']])->fetch(PDO::FETCH_ASSOC);
        if(!$r)$this->fail(403,'challenge_expired','Request a new installation challenge.');
        $key=self::publicKey($r['public_key']);
        if(!hash_equals($key['hash'],$r['key_hash'])||openssl_verify(self::message($r),$signature,$key['pem'],OPENSSL_ALGO_SHA256)!==1)$this->fail(403,'invalid_signature','The installation signature does not match this request.');
        // No transaction/tenant lock is held over an external HTTPS proof.
        $this->verifySiteProof($r);$signer=$this->signingKey();
        $this->db->beginTransaction();try {
            $this->account($account,true);
            $this->q("select pg_advisory_xact_lock(hashtextextended('openweb-installation-authority',0))");
            $consumed=$this->q('update v_pbx_installation_challenges set consumed_at=now() where challenge_uuid=? and account_tenant_uuid=? and account_user_uuid=? and consumed_at is null and expires_at>now() returning challenge_uuid',[$id,$account['tenant_uuid'],$account['user_uuid']])->fetchColumn();
            if(!$consumed)$this->fail(403,'challenge_expired','Request a new installation challenge.');
            $existing=$this->q('select * from v_pbx_installation_authorizations where key_hash=? and domain_uuid=? for update',[$r['key_hash'],$r['domain_uuid']])->fetch(PDO::FETCH_ASSOC);
            if($existing){
                foreach(['account_tenant_uuid','local_tenant_uuid','domain_uuid','key_hash','server_host','label']as$binding)if(!hash_equals($existing[$binding],$r[$binding]))$this->fail(409,'installation_binding_conflict','This installation binding is already registered. Contact the instance custodian before moving it.');
                if($existing['state']!=='authorized')$this->fail(403,'installation_revoked','This installation authorization was revoked. Contact the instance custodian.');
                $installation=$existing['installation_uuid'];$generation=(int)$existing['generation']+1;
            }else{
                if((int)$this->q('select count(*) from v_pbx_installation_authorizations where account_tenant_uuid=?',[$account['tenant_uuid']])->fetchColumn()>=self::MAX_AUTHORIZATIONS)$this->fail(409,'installation_limit','This account has reached its installation authorization limit.');
                $conflict=$this->q('select exists(select 1 from v_pbx_installation_authorizations where (server_host=? and key_hash<>?) or (key_hash=? and server_host<>?))',[$r['server_host'],$r['key_hash'],$r['key_hash'],$r['server_host']])->fetchColumn();
                if(in_array($conflict,[true,'t','1',1],true))$this->fail(409,'installation_binding_conflict','This installation hostname or identity is already registered.');
                $installation=uuid();$generation=1;
            }
            $now=new DateTimeImmutable('now',new DateTimeZone('UTC'));$until=$now->add(new DateInterval('P1Y'));
            $payload=['schema'=>1,'issuer'=>self::ISSUER,'audience'=>self::AUDIENCE,'installation_uuid'=>$installation,
                'account_tenant_uuid'=>$r['account_tenant_uuid'],'local_tenant_uuid'=>$r['local_tenant_uuid'],'domain_uuid'=>$r['domain_uuid'],
                'key_hash'=>$r['key_hash'],'server_host'=>$r['server_host'],'label'=>$r['label'],'issued_at'=>$now->format(DATE_RFC3339),'expires_at'=>$until->format(DATE_RFC3339),'generation'=>$generation];
            $bytes=json_encode($payload,JSON_UNESCAPED_SLASHES|JSON_THROW_ON_ERROR);
            if(!openssl_sign($bytes,$signed,$signer,OPENSSL_ALGO_SHA256))throw new RuntimeException('Installation authorization could not be signed.');
            $envelope=['key_id'=>self::KEY_ID,'algorithm'=>'RS256','payload'=>self::base64url($bytes),'signature'=>self::base64url($signed)];
            if($existing){$this->q('update v_pbx_installation_authorizations set generation=?,issued_at=?,expires_at=?,activation=cast(? as jsonb),updated_at=now() where installation_uuid=?',[$generation,$payload['issued_at'],$payload['expires_at'],json_encode($envelope,JSON_THROW_ON_ERROR),$installation]);}
            else{$this->q('insert into v_pbx_installation_authorizations(installation_uuid,account_tenant_uuid,local_tenant_uuid,domain_uuid,key_hash,public_key,server_host,label,generation,issued_at,expires_at,activation) values(?,?,?,?,?,?,?,?,?,?,?,cast(? as jsonb))',[$installation,$r['account_tenant_uuid'],$r['local_tenant_uuid'],$r['domain_uuid'],$r['key_hash'],$r['public_key'],$r['server_host'],$r['label'],$generation,$payload['issued_at'],$payload['expires_at'],json_encode($envelope,JSON_THROW_ON_ERROR)]);}
            $this->q('insert into v_pbx_api_audit(audit_uuid,tenant_uuid,user_uuid,action,target_uuid) values(?,?,?,?,?)',[uuid(),$account['tenant_uuid'],$account['user_uuid'],$existing?'installation_renewed':'installation_authorized',$installation]);
            $this->db->commit();return $this->get($account,$installation);
        }catch(Throwable $e){if($this->db->inTransaction())$this->db->rollBack();throw $e;}
    }
    public function list(array $account): array {
        $this->account($account);$rows=$this->q('select * from v_pbx_installation_authorizations where account_tenant_uuid=? order by created_at,installation_uuid limit 50',[$account['tenant_uuid']])->fetchAll(PDO::FETCH_ASSOC);
        return ['installations'=>array_map(fn($r)=>$this->installationView($r),$rows)];
    }
    public function get(array $account,string $installation): array {
        $this->account($account);$id=$this->id($installation);$r=$this->q('select * from v_pbx_installation_authorizations where installation_uuid=? and account_tenant_uuid=?',[$id,$account['tenant_uuid']])->fetch(PDO::FETCH_ASSOC);
        if(!$r)$this->fail(404,'not_found','This installation authorization is unavailable.');
        return ['installation'=>$this->installationView($r),'activation'=>$r['state']==='authorized'?json_decode($r['activation'],true,8,JSON_THROW_ON_ERROR):null];
    }
}
