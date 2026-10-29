<?php
/** Local PBX registration. The web process never reads or signs with the instance private key. */
class pbx_onboarding_denied extends RuntimeException {}
class pbx_onboarding_pending extends RuntimeException {}

class pbx_onboarding {
    public const API='https://call.openweb.co.za/api/v1';
    public const KEY_ID='installation-2026-a';
    private PDO $db;
    private string $service;
    public function __construct(?PDO $db=null,?string $service=null) {
        $this->db=$db??database::new()->db;$this->db->setAttribute(PDO::ATTR_ERRMODE,PDO::ERRMODE_EXCEPTION);
        $this->service=$service??'';
    }
    private function q(string $sql,array $values=[]): PDOStatement {
        $s=$this->db->prepare($sql);foreach($values as $key=>$value)$s->bindValue(is_int($key)?$key+1:':'.$key,$value,$value===null?PDO::PARAM_NULL:(is_bool($value)?PDO::PARAM_BOOL:(is_int($value)?PDO::PARAM_INT:PDO::PARAM_STR)));$s->execute();return $s;
    }
    private static function uuid(mixed $value): string {
        if(!is_string($value)||!preg_match('/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/D',$value))throw new InvalidArgumentException('Choose a valid PBX.');return $value;
    }
    private static function yes(mixed $value): bool {return in_array($value,[true,'t','true',1,'1'],true);}
    private static function text(mixed $value,int $maximum=120): string {
        if(!is_string($value)||trim($value)===''||strlen($value)>$maximum||preg_match('/[\x00-\x1f\x7f]/',$value))throw new InvalidArgumentException('Check the supplied details.');return trim($value);
    }
    private static function email(mixed $value): string {$value=strtolower(self::text($value,254));if(!filter_var($value,FILTER_VALIDATE_EMAIL))throw new InvalidArgumentException('Enter a valid email address.');return $value;}
    private static function password(mixed $value,bool $new=false): string {
        if(!is_string($value)||strlen($value)>72||strlen($value)<($new?12:1)||preg_match('/[\x00-\x1f\x7f]/',$value)||($new&&(!preg_match('/[A-Za-z]/',$value)||!preg_match('/[0-9]/',$value))))throw new InvalidArgumentException($new?'Choose a password with 12 to 72 bytes, including a letter and a number.':'Enter your account password.');return $value;
    }
    private static function keys(array $value,array $allowed,array $required=[]): void {
        if(array_diff(array_keys($value),$allowed)||array_diff($required,array_keys($value)))throw new InvalidArgumentException('Check the supplied details.');
    }
    private function actor(): string {
        if(($_SESSION['authorized']??false)!==true)throw new pbx_onboarding_denied('Sign in as the PBX owner to continue.');return self::uuid($_SESSION['user_uuid']??'');
    }
    /** Re-read ownership and actual group membership; no CLI permission shortcut or cached grants. */
    private function visible(?string $service=null,?string $actor=null): array {
        $actor??=$this->actor();$actor=self::uuid($actor);$values=['actor'=>$actor];$filter='';
        if($service!==null){$filter=' and s.service_uuid=:service';$values['service']=self::uuid($service);}
        return $this->q("select s.service_uuid,s.domain_uuid,s.tenant_uuid,s.service_name,d.domain_name,t.tenant_name,t.owner_user_uuid,t.slug
            from v_pbx_services s join v_pbx_tenants t using(tenant_uuid)
            join v_domains d on d.domain_uuid=s.domain_uuid join v_users owner on owner.user_uuid=t.owner_user_uuid
            join v_users actor on actor.user_uuid=:actor and actor.user_enabled::text='true'
            where t.enabled=true and d.domain_enabled::text='true' and owner.user_enabled::text='true'
             and (exists(select 1 from v_user_groups ug join v_groups g on g.group_uuid=ug.group_uuid
                 where ug.user_uuid=actor.user_uuid and ug.group_name=g.group_name and g.group_name='superadmin' and g.domain_uuid is null)
               or (t.owner_user_uuid=actor.user_uuid and exists(select 1 from v_user_groups ug join v_groups g on g.group_uuid=ug.group_uuid
                 where ug.user_uuid=actor.user_uuid and ug.group_name=g.group_name and g.group_name='tenant_admin' and g.domain_uuid is null)))".$filter.' order by s.created_at,s.service_uuid',$values)->fetchAll(PDO::FETCH_ASSOC);
    }
    public function services(): array {return $this->visible();}
    private function local(bool $lock=false): array {
        $rows=$this->visible($this->service);if(count($rows)!==1)throw new pbx_onboarding_denied('Choose a PBX that you own.');$row=$rows[0];
        if($lock){$this->q('select service_uuid from v_pbx_services where service_uuid=? for update',[$row['service_uuid']]);$again=$this->visible($this->service);if(count($again)!==1||$again[0]['owner_user_uuid']!==$row['owner_user_uuid'])throw new pbx_onboarding_denied('This PBX is no longer available.');}
        return $row;
    }
    private function row(array $local,bool $create=false): ?array {
        if($create)$this->q('insert into v_pbx_onboarding(domain_uuid,tenant_uuid,service_uuid,owner_user_uuid) values(?,?,?,?) on conflict(domain_uuid) do nothing',[$local['domain_uuid'],$local['tenant_uuid'],$local['service_uuid'],$local['owner_user_uuid']]);
        $r=$this->q('select * from v_pbx_onboarding where domain_uuid=?',[$local['domain_uuid']])->fetch(PDO::FETCH_ASSOC);
        if(!$r)return null;if($r['tenant_uuid']!==$local['tenant_uuid']||$r['service_uuid']!==$local['service_uuid']||$r['owner_user_uuid']!==$local['owner_user_uuid'])throw new pbx_onboarding_denied('This registration needs an instance administrator to review its ownership.');return $r;
    }
    protected function encryptionKey(): string {
        $key=@file_get_contents(pbx_paths::key());if(!is_string($key)||strlen($key)!==SODIUM_CRYPTO_SECRETBOX_KEYBYTES)throw new RuntimeException('Account protection is not ready. Ask the instance administrator to check this server.');return $key;
    }
    private function seal(string $token): string {$nonce=random_bytes(SODIUM_CRYPTO_SECRETBOX_NONCEBYTES);return base64_encode($nonce.sodium_crypto_secretbox($token,$nonce,$this->encryptionKey()));}
    private function unseal(string $ciphertext): string {
        $raw=base64_decode($ciphertext,true);if(!is_string($raw)||strlen($raw)<40)throw new RuntimeException('Sign in to your OpenWeb account again.');
        $token=sodium_crypto_secretbox_open(substr($raw,24),substr($raw,0,24),$this->encryptionKey());if(!is_string($token)||!preg_match('/^owta_[a-f0-9]{64}$/D',$token))throw new RuntimeException('Sign in to your OpenWeb account again.');return $token;
    }
    /** Fixed HTTPS authority only; no user-controlled URL, redirect, proxy or TLS bypass. */
    protected function central(string $route,array $body,?string $bearer=null): array {
        if(!in_array($route,['/registrations','/registrations/verify','/auth/token','/onboarding/email/request','/onboarding/email/verify'],true))throw new LogicException('Unsupported account operation.');
        $headers=['Content-Type: application/json','Accept: application/json'];
        if($bearer!==null){if(!preg_match('/^owta_[a-f0-9]{64}$/D',$bearer))throw new RuntimeException('Sign in to your OpenWeb account again.');$headers[]='Authorization: Bearer '.$bearer;}
        $h=curl_init(self::API.$route);$reply='';
        curl_setopt_array($h,[CURLOPT_POST=>true,CURLOPT_HTTPHEADER=>$headers,CURLOPT_POSTFIELDS=>json_encode((object)$body,JSON_THROW_ON_ERROR),CURLOPT_RETURNTRANSFER=>false,
            CURLOPT_FOLLOWLOCATION=>false,CURLOPT_MAXREDIRS=>0,CURLOPT_PROTOCOLS=>CURLPROTO_HTTPS,CURLOPT_REDIR_PROTOCOLS=>CURLPROTO_HTTPS,CURLOPT_SSL_VERIFYPEER=>true,CURLOPT_SSL_VERIFYHOST=>2,CURLOPT_PROXY=>'',CURLOPT_CONNECTTIMEOUT=>10,CURLOPT_TIMEOUT=>30,
            CURLOPT_WRITEFUNCTION=>static function($h,string $chunk)use(&$reply): int {if(strlen($reply)+strlen($chunk)>32768)return 0;$reply.=$chunk;return strlen($chunk);}]);
        try{$ok=curl_exec($h);$status=(int)curl_getinfo($h,CURLINFO_RESPONSE_CODE);}finally{curl_close($h);}
        if($ok===false||!in_array($status,[200,201,202],true))throw new pbx_onboarding_pending(match($status){400=>'Check your account details and verification code.',401=>'The email or password was not accepted. Try again.',409=>'This account or company name needs review. Try signing in or contact OpenWeb.',429=>'Please wait a few minutes before trying again.',default=>'OpenWeb could not be reached. Your local PBX settings are unchanged; try again shortly.'});
        try{$out=json_decode($reply,true,12,JSON_THROW_ON_ERROR);}catch(Throwable){throw new pbx_onboarding_pending('OpenWeb returned an incomplete reply. Please try again.');}
        if(!is_array($out)||array_is_list($out))throw new pbx_onboarding_pending('OpenWeb returned an incomplete reply. Please try again.');return $out;
    }
    public function register(array $input): void {
        $local=$this->local();self::keys($input,['tenant_name','slug','email','password','accept_terms'],['tenant_name','slug','email','password','accept_terms']);
        $name=self::text($input['tenant_name']);$slug=pbx_tenant_api_domains::label(self::text($input['slug'],40));$email=self::email($input['email']);$password=self::password($input['password'],true);
        if($input['accept_terms']!==true)throw new InvalidArgumentException('Accept the terms and privacy policy to create your account.');
        $existing=$this->row($local);if($existing&&($existing['activation']!==null||$existing['account_tenant_uuid']!==null))throw new InvalidArgumentException('This PBX already has an OpenWeb account. Continue setup or sign in to that account again.');
        $reply=$this->central('/registrations',['tenant_name'=>$name,'slug'=>$slug,'email'=>$email,'password'=>$password,'accept_terms'=>true]);
        if(($reply['status']??null)!=='verification_required')throw new pbx_onboarding_pending('Your account request was not confirmed. Try again.');
        $this->db->beginTransaction();try{$local=$this->local(true);$this->row($local,true);$this->q("update v_pbx_onboarding set account_email=?,state='account_pending',last_error_category='',updated_at=now() where domain_uuid=? and activation is null",[$email,$local['domain_uuid']]);$this->db->commit();}catch(Throwable $e){if($this->db->inTransaction())$this->db->rollBack();throw $e;}
    }
    public function verify(array $input): void {
        $local=$this->local();self::keys($input,['token','password'],['token','password']);$token=$input['token'];if(!is_string($token)||!preg_match('/^[a-f0-9]{64}$/D',$token))throw new InvalidArgumentException('Paste the verification code from your email.');
        $password=self::password($input['password']);$reply=$this->central('/registrations/verify',['token'=>$token,'password'=>$password]);$this->saveAccount($reply,$local);
    }
    public function signIn(array $input): void {
        $local=$this->local();self::keys($input,['email','password'],['email','password']);$email=self::email($input['email']);$password=self::password($input['password']);
        $reply=$this->central('/auth/token',['email'=>$email,'password'=>$password]);$this->saveAccount($reply,$local);
    }
    private function accountBearer(array $local): string {
        $row=$this->row($local);if(!$row||$row['account_tenant_uuid']===null||strtotime((string)$row['token_expires_at'])<=time())throw new InvalidArgumentException('Sign in to your OpenWeb account again.');return $this->unseal($row['token_ciphertext']);
    }
    public function requestEmailCode(): void {
        $local=$this->local();$reply=$this->central('/onboarding/email/request',[],$this->accountBearer($local));
        if(($reply['status']??null)!=='verification_required')throw new pbx_onboarding_pending('Your email check was not confirmed. Try again.');
        $state=static::registered($this->db,$local['domain_uuid'])?'ready':'account_pending';$this->q("update v_pbx_onboarding set state=?,last_error_category='verified_account_required',updated_at=now() where domain_uuid=?",[$state,$local['domain_uuid']]);
    }
    public function verifyAccountEmail(array $input): void {
        $local=$this->local();self::keys($input,['token','password'],['token','password']);$token=$input['token'];if(!is_string($token)||!preg_match('/^[a-f0-9]{64}$/D',$token))throw new InvalidArgumentException('Paste the verification code from your email.');
        $reply=$this->central('/onboarding/email/verify',['token'=>$token,'password'=>self::password($input['password'])],$this->accountBearer($local));
        if(($reply['verified']??null)!==true)throw new pbx_onboarding_pending('Your email check was not confirmed. Try again.');
        $this->db->beginTransaction();try{$this->local(true);$state=static::registered($this->db,$local['domain_uuid'])?'ready':'account_ready';$this->q("update v_pbx_onboarding set state=?,last_error_category='',updated_at=now() where domain_uuid=?",[$state,$local['domain_uuid']]);$this->q("update v_pbx_onboarding_jobs set next_attempt=now(),updated_at=now() where domain_uuid=? and state='retry' and error_category in ('verified_account_required','email_verification_required')",[$local['domain_uuid']]);$this->db->commit();}catch(Throwable $e){if($this->db->inTransaction())$this->db->rollBack();throw $e;}
    }
    private function saveAccount(array $reply,array $local): void {
        $account=$reply['tenant']??null;$token=$reply['access_token']??null;$expiry=$reply['expires_at']??null;
        if(!is_array($account)||!is_string($token)||!preg_match('/^owta_[a-f0-9]{64}$/D',$token)||($reply['token_type']??'')!=='Bearer'||!is_string($expiry)||strtotime($expiry)<=time()||strtotime($expiry)>time()+91*86400)throw new pbx_onboarding_pending('OpenWeb did not confirm the account. Sign in again.');
        $accountId=self::uuid($account['tenant_uuid']??'');$email=self::email($account['email']??'');$label=pbx_tenant_api_domains::label(self::text($account['slug']??'',40));$sealed=$this->seal($token);
        $this->db->beginTransaction();try{
            $local=$this->local(true);$r=$this->row($local,true);
            if($r['account_tenant_uuid']!==null&&$r['account_tenant_uuid']!==$accountId&&($r['activation']!==null||in_array($r['state'],['queued','preparing','ready'],true)))throw new InvalidArgumentException('Use the OpenWeb account already connected to this PBX.');
            $alias=$this->q('select requested_label from v_pbx_tenant_domains where domain_uuid=?',[$local['domain_uuid']])->fetchColumn();$label=is_string($alias)?pbx_tenant_api_domains::label($alias):($r['requested_label']!==''?$r['requested_label']:$label);
            $this->q("update v_pbx_onboarding set account_tenant_uuid=?,account_email=?,requested_label=?,token_ciphertext=?,token_expires_at=?,state=case when activation is null then 'account_ready' else state end,last_error_category='',updated_at=now() where domain_uuid=?",[$accountId,$email,$label,$sealed,$expiry,$local['domain_uuid']]);$this->db->commit();
        }catch(Throwable $e){if($this->db->inTransaction())$this->db->rollBack();throw $e;}
    }
    protected function publicIdentity(): array {
        $path=pbx_paths::state().'/tenant-domains/instance-public.json';
        for($part=$path;;$part=dirname($part)){if(is_link($part)||(PHP_OS_FAMILY!=='Windows'&&file_exists($part)&&(fileowner($part)!==0||(fileperms($part)&0022)!==0)))throw new pbx_onboarding_pending('The secure server connection needs administrator attention.');if($part===dirname($part))break;}
        if(!is_file($path)||filesize($path)>8192)throw new pbx_onboarding_pending('This server is preparing its secure connection. Wait a moment and try again.');
        if(PHP_OS_FAMILY!=='Windows'&&(fileowner($path)!==0||(fileperms($path)&0022)!==0))throw new pbx_onboarding_pending('The secure server connection needs administrator attention.');
        try{$r=json_decode(file_get_contents($path),true,5,JSON_THROW_ON_ERROR);}catch(Throwable){throw new pbx_onboarding_pending('This server is preparing its secure connection. Wait a moment and try again.');}
        if(!is_array($r)||($r['schema']??null)!==1||($r['server_host']??'')!==pbx_paths::host()||!is_string($r['key_hash']??null)||!preg_match('/^[a-f0-9]{64}$/D',$r['key_hash'])||!is_string($r['public_key']??null))throw new pbx_onboarding_pending('The secure server connection needs administrator attention.');
        $raw=base64_decode($r['public_key'],true);if(!is_string($raw)||strlen($raw)<64||strlen($raw)>256||base64_encode($raw)!==$r['public_key']||!hash_equals($r['key_hash'],hash('sha256',$raw)))throw new pbx_onboarding_pending('The secure server connection needs administrator attention.');
        $public=openssl_pkey_get_public("-----BEGIN PUBLIC KEY-----\n".chunk_split(base64_encode($raw),64,"\n")."-----END PUBLIC KEY-----\n");$details=$public?openssl_pkey_get_details($public):false;
        if(!$details||$details['type']!==OPENSSL_KEYTYPE_EC||!in_array($details['ec']['curve_name']??'',['prime256v1','secp256r1'],true))throw new pbx_onboarding_pending('The secure server connection needs administrator attention.');
        $policy=self::policy($this->db);if($policy['canonical_host']!==$r['server_host']||$policy['instance_key_hash']!==$r['key_hash'])throw new pbx_onboarding_pending('This server is preparing its secure connection. Wait a moment and try again.');return $r;
    }
    public function queue(array $input): string {
        $this->local();self::keys($input,['label'],['label']);$label=pbx_tenant_api_domains::label(self::text($input['label'],40));$identity=$this->publicIdentity();
        $this->db->beginTransaction();try{
            $local=$this->local(true);$r=$this->row($local,true);if($r['account_tenant_uuid']===null||$r['token_ciphertext']===''||strtotime((string)$r['token_expires_at'])<=time())throw new InvalidArgumentException('Sign in to your OpenWeb account before choosing an address.');
            $alias=$this->q('select requested_label,tenant_uuid,service_uuid from v_pbx_tenant_domains where domain_uuid=?',[$local['domain_uuid']])->fetch(PDO::FETCH_ASSOC);
            if($alias&&($alias['requested_label']!==$label||$alias['tenant_uuid']!==$local['tenant_uuid']||$alias['service_uuid']!==$local['service_uuid']))throw new InvalidArgumentException('This PBX already has a reserved address. Keep its current short name.');
            if($r['activation']!==null&&($r['requested_label']!==$label||$r['server_host']!==$identity['server_host']||$r['key_hash']!==$identity['key_hash']))throw new InvalidArgumentException('This registration is already bound to this PBX. Ask the instance administrator about a controlled move.');
            $pending=$this->q("select job_uuid from v_pbx_onboarding_jobs where domain_uuid=? and revision=? and state in ('queued','preparing','retry')",[$local['domain_uuid'],$r['revision']])->fetchColumn();
            if($pending&&$r['requested_label']===$label&&$r['server_host']===$identity['server_host']&&$r['key_hash']===$identity['key_hash']){$this->q("update v_pbx_onboarding_jobs set state='queued',next_attempt=now(),updated_at=now() where job_uuid=? and state='retry'",[$pending]);$this->q("update v_pbx_onboarding set state='queued',last_error_category='',updated_at=now() where domain_uuid=? and state='retry'",[$local['domain_uuid']]);$this->db->commit();return $pending;}
            $revision=(int)$r['revision']+1;$job=uuid();$this->q("update v_pbx_onboarding_jobs set state='superseded',updated_at=now() where domain_uuid=? and state in ('queued','preparing','retry')",[$local['domain_uuid']]);
            $state=static::registered($this->db,$local['domain_uuid'])?'ready':'queued';$this->q("update v_pbx_onboarding set requested_label=?,server_host=?,key_hash=?,revision=?,state=?,last_error_category='',updated_at=now() where domain_uuid=?",[$label,$identity['server_host'],$identity['key_hash'],$revision,$state,$local['domain_uuid']]);
            $this->q('insert into v_pbx_onboarding_jobs(job_uuid,domain_uuid,revision) values(?,?,?)',[$job,$local['domain_uuid'],$revision]);$this->db->commit();return $job;
        }catch(Throwable $e){if($this->db->inTransaction())$this->db->rollBack();throw $e;}
    }
    private static function policy(PDO $db): array {
        $r=['required'=>false,'canonical_host'=>'','instance_key_hash'=>''];
        if($db->query("select to_regclass('v_pbx_onboarding_policy')")->fetchColumn())$r=$db->query('select required,canonical_host,instance_key_hash from v_pbx_onboarding_policy where singleton=true')->fetch(PDO::FETCH_ASSOC)?:$r;
        return $r;
    }
    public static function required(PDO $db): bool {
        $marker=static::requiredMarkerPath();$parent=dirname($marker);
        $marked=is_link($marker)||file_exists($marker)||is_link($parent)||(file_exists($parent)&&(!is_dir($parent)||!is_readable($parent)));
        return $marked||filter_var(config::load()->get('openweb.onboarding_required','false'),FILTER_VALIDATE_BOOLEAN)||self::yes(self::policy($db)['required']);
    }
    protected static function requiredMarkerPath(): string {return PHP_OS_FAMILY==='Windows'?rtrim(str_replace('\\','/',getenv('ProgramData')?:'C:/ProgramData'),'/').'/OpenWebPBX-Installation/onboarding-required':'/etc/openwebpbx-installation/onboarding-required';}
    protected static function authorityPem(): string {
        $path=PROJECT_ROOT.'/resources/keys/installation-authority.pem';if(!is_file($path)||is_link($path)||filesize($path)>16384)throw new RuntimeException('The OpenWeb registration authority is unavailable.');
        return file_get_contents($path);
    }
    private static function decode(string $value,int $maximum): string {
        if($value===''||strlen($value)>$maximum*2||!preg_match('/^[A-Za-z0-9_-]+$/D',$value))throw new RuntimeException('The registration reply could not be verified.');
        $raw=base64_decode(strtr($value,'-_','+/').str_repeat('=',(4-strlen($value)%4)%4),true);
        if(!is_string($raw)||strlen($raw)>$maximum||rtrim(strtr(base64_encode($raw),'+/','-_'),'=')!==$value)throw new RuntimeException('The registration reply could not be verified.');return $raw;
    }
    private static function timestamp(mixed $value): int {
        if(!is_string($value)||!preg_match('/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,6})?(?:Z|\+00:00)$/D',$value))throw new RuntimeException('The registration reply could not be verified.');
        try{$date=new DateTimeImmutable($value);$errors=DateTimeImmutable::getLastErrors();if(is_array($errors)&&($errors['warning_count']||$errors['error_count']))throw new RuntimeException();return $date->getTimestamp();}catch(Throwable){throw new RuntimeException('The registration reply could not be verified.');}
    }
    /** Raw-payload PKCS#1 SHA256 verification shared by UI and local runtime gates. */
    public static function verifyReceipt(array $envelope,array $bindings,string $pem,?int $now=null): array {
        $keys=array_keys($envelope);sort($keys);if($keys!==['algorithm','key_id','payload','signature']||$envelope['algorithm']!=='RS256'||$envelope['key_id']!==self::KEY_ID||!is_string($envelope['payload'])||!is_string($envelope['signature']))throw new RuntimeException('The registration reply could not be verified.');
        $raw=self::decode($envelope['payload'],8192);$signature=self::decode($envelope['signature'],1024);$public=openssl_pkey_get_public($pem);$details=$public?openssl_pkey_get_details($public):false;
        if(!$details||$details['type']!==OPENSSL_KEYTYPE_RSA||$details['bits']<3072||$details['bits']>8192||openssl_verify($raw,$signature,$public,OPENSSL_ALGO_SHA256)!==1)throw new RuntimeException('The registration reply could not be verified.');
        try{$p=json_decode($raw,true,6,JSON_THROW_ON_ERROR);}catch(Throwable){throw new RuntimeException('The registration reply could not be verified.');}
        $expected=['schema','issuer','audience','installation_uuid','account_tenant_uuid','local_tenant_uuid','domain_uuid','key_hash','server_host','label','issued_at','expires_at','generation'];$actual=is_array($p)?array_keys($p):[];sort($expected);sort($actual);
        if($actual!==$expected||$p['schema']!==1||$p['issuer']!==self::API||$p['audience']!=='openwebpbx-installation'||!is_int($p['generation'])||$p['generation']<1)throw new RuntimeException('The registration reply could not be verified.');
        foreach(['installation_uuid','account_tenant_uuid','local_tenant_uuid','domain_uuid']as$key)self::uuid($p[$key]);
        foreach(['account_tenant_uuid','local_tenant_uuid','domain_uuid','key_hash','server_host','label']as$key)if(!is_string($p[$key])||!isset($bindings[$key])||!is_string($bindings[$key])||!hash_equals($bindings[$key],$p[$key]))throw new RuntimeException('This registration belongs to a different PBX.');
        if(isset($bindings['installation_uuid'])&&$bindings['installation_uuid']!==$p['installation_uuid'])throw new RuntimeException('This registration belongs to a different PBX.');
        if(!preg_match('/^[a-f0-9]{64}$/D',$p['key_hash'])||pbx_tenant_domains::hostname($p['server_host'])!==$p['server_host'])throw new RuntimeException('The registration reply could not be verified.');pbx_tenant_api_domains::label($p['label']);
        $issued=self::timestamp($p['issued_at']);$expires=self::timestamp($p['expires_at']);$now??=time();if($issued>$now+300||$expires<=$now||$expires<=$issued||$expires-$issued>366*86400)throw new RuntimeException('The registration is expired or this server clock needs attention.');return $p;
    }
    private static function receipt(PDO $db,string $domain): ?array {
        try{
            $s=$db->prepare("select o.*,t.enabled tenant_enabled,d.domain_enabled from v_pbx_onboarding o
                join v_pbx_tenants t on t.tenant_uuid=o.tenant_uuid and t.owner_user_uuid=o.owner_user_uuid
                join v_pbx_services s on s.service_uuid=o.service_uuid and s.domain_uuid=o.domain_uuid and s.tenant_uuid=o.tenant_uuid
                join v_domains d on d.domain_uuid=o.domain_uuid join v_users u on u.user_uuid=o.owner_user_uuid and u.user_enabled::text='true'
                where o.domain_uuid=?");$s->execute([self::uuid($domain)]);$r=$s->fetch(PDO::FETCH_ASSOC);if(!$r||!self::yes($r['tenant_enabled'])||!self::yes($r['domain_enabled'])||$r['activation']===null)return null;
            $policy=self::policy($db);if($policy['canonical_host']!==pbx_paths::host()||$r['server_host']!==$policy['canonical_host']||$r['key_hash']!==$policy['instance_key_hash'])return null;
            $bindings=['account_tenant_uuid'=>$r['account_tenant_uuid'],'local_tenant_uuid'=>$r['tenant_uuid'],'domain_uuid'=>$r['domain_uuid'],'key_hash'=>$policy['instance_key_hash'],'server_host'=>$policy['canonical_host'],'label'=>$r['requested_label']];
            $p=self::verifyReceipt(json_decode($r['activation'],true,6,JSON_THROW_ON_ERROR),$bindings,static::authorityPem());return ['row'=>$r,'payload'=>$p];
        }catch(Throwable){return null;}
    }
    protected static function transport(PDO $db,string $domain,string $host): bool {return pbx_tenant_domains::requestDomain($db,['HTTP_HOST'=>$host])===$domain;}
    private static function registered(PDO $db,string $domain): bool {
        $receipt=static::receipt($db,$domain);if(!$receipt)return false;$r=$receipt['row'];
        $s=$db->prepare("select hostname from v_pbx_tenant_domains where domain_uuid=? and tenant_uuid=? and service_uuid=? and requested_label=? and key_hash=? and server_host=? and state='ready' and desired_enabled and certificate_not_after>now()");$s->execute([$domain,$r['tenant_uuid'],$r['service_uuid'],$r['requested_label'],$r['key_hash'],$r['server_host']]);$host=$s->fetchColumn();return is_string($host)&&static::transport($db,$domain,$host);
    }
    public static function allowsDomain(PDO $db,string $domain): bool {return !self::required($db)||static::registered($db,$domain);}
    /** DNS/TLS workers may prepare an authorized tenant before its transport is ready. */
    public static function authorizedDomain(PDO $db,string $domain): bool {return !self::required($db)||static::receipt($db,$domain)!==null;}
    public function status(): array {
        $local=$this->local();$r=$this->row($local);$ready=$r!==null&&static::registered($this->db,$local['domain_uuid']);$identityReady=false;try{$this->publicIdentity();$identityReady=true;}catch(Throwable){}
        $confirmed=$r!==null&&static::receipt($this->db,$local['domain_uuid'])!==null;$state=$ready?'ready':($r['state']??'pending');if(!$ready&&$state==='ready')$state=$confirmed?'preparing':'retry';$canRequest=$r&&$r['account_tenant_uuid']!==null&&$r['token_ciphertext']!==''&&strtotime((string)$r['token_expires_at'])>time();$needsLogin=$r&&$r['account_tenant_uuid']!==null&&!$confirmed&&!$canRequest;$needsEmail=$r&&$r['account_tenant_uuid']!==null&&(in_array($r['last_error_category'],['verified_account_required','email_verification_required'],true)||$r['state']==='account_pending');
        $message=$ready?'Your PBX is registered and its secure tenant address is ready.':match($state){'account_pending'=>'Check your email for your verification code.','account_ready'=>'Choose the tenant address you want to use.','queued','preparing'=>'We are confirming this server and preparing its tenant address.','retry'=>'Setup is waiting for another check. Your local settings are safe.',default=>'Create or sign in to your OpenWeb account to continue.'};
        if($needsLogin&&!$ready)$message='Sign in to your OpenWeb account again to continue setup.';
        if($confirmed&&!$ready)$message='Your registration is confirmed. We are waiting for the secure tenant address to be ready.';
        if($needsEmail&&!$ready)$message='Confirm your OpenWeb account email before completing this server setup.';
        $url=null;if($ready)$url=pbx_tenant_domains::url($this->db,$local['domain_uuid']);
        return ['service_uuid'=>$local['service_uuid'],'service_name'=>$local['service_name'],'tenant_name'=>$local['tenant_name'],'state'=>$state,'ready'=>$ready,'registration_confirmed'=>$confirmed,'can_request_registration'=>(bool)$canRequest,'identity_ready'=>$identityReady,'account_email'=>$r['account_email']??'','account_connected'=>$r!==null&&$r['account_tenant_uuid']!==null,'needs_sign_in'=>(bool)$needsLogin,'needs_email_verification'=>(bool)$needsEmail,'requested_label'=>$r['requested_label']??'','url'=>$url,'admin_url'=>$url?$url.'/admin':null,'message'=>$message];
    }
    protected function requireWorker(): void {
        if(PHP_SAPI!=='cli'||!defined('OPENWEB_ONBOARDING_WORKER')||OPENWEB_ONBOARDING_WORKER!==true||(function_exists('posix_geteuid')&&posix_geteuid()!==0))throw new pbx_onboarding_denied('The local setup worker is required.');
    }
    public function workerJobs(int $limit=10): array {
        $this->requireWorker();if($limit<1||$limit>10)throw new InvalidArgumentException('Invalid worker limit.');$identity=$this->publicIdentity();$out=[];
        $this->db->beginTransaction();try{
            $jobs=$this->q("select j.*,o.tenant_uuid,o.service_uuid,o.owner_user_uuid,o.account_tenant_uuid,o.requested_label,o.server_host,o.key_hash,o.token_ciphertext,o.token_expires_at
                from v_pbx_onboarding_jobs j join v_pbx_onboarding o on o.domain_uuid=j.domain_uuid and o.revision=j.revision
                where j.state in ('queued','preparing','retry') and j.next_attempt<=now() order by j.next_attempt,j.created_at limit ".$limit.' for update of j skip locked')->fetchAll(PDO::FETCH_ASSOC);
            foreach($jobs as$r){
                $local=$this->visible($r['service_uuid'],$r['owner_user_uuid']);
                if(count($local)!==1||$local[0]['owner_user_uuid']!==$r['owner_user_uuid']||$r['server_host']!==$identity['server_host']||$r['key_hash']!==$identity['key_hash']){$this->q("update v_pbx_onboarding_jobs set state='superseded',error_category='ownership_changed',updated_at=now() where job_uuid=?",[$r['job_uuid']]);continue;}
                if(strtotime((string)$r['token_expires_at'])<=time()){$this->q("update v_pbx_onboarding_jobs set state='retry',error_category='account_expired',next_attempt=now()+interval '1 day',updated_at=now() where job_uuid=?",[$r['job_uuid']]);$this->q("update v_pbx_onboarding set state=?,last_error_category='account_expired',updated_at=now() where domain_uuid=?",[static::registered($this->db,$r['domain_uuid'])?'ready':'retry',$r['domain_uuid']]);continue;}
                $token=$this->unseal($r['token_ciphertext']);$this->q("update v_pbx_onboarding_jobs set state='preparing',attempts=attempts+1,next_attempt=now()+interval '5 minutes',updated_at=now() where job_uuid=?",[$r['job_uuid']]);$this->q("update v_pbx_onboarding set state=?,updated_at=now() where domain_uuid=?",[static::registered($this->db,$r['domain_uuid'])?'ready':'preparing',$r['domain_uuid']]);
                $out[]=['job_uuid'=>$r['job_uuid'],'revision'=>(int)$r['revision'],'service_uuid'=>$r['service_uuid'],'domain_uuid'=>$r['domain_uuid'],'local_tenant_uuid'=>$r['tenant_uuid'],'account_tenant_uuid'=>$r['account_tenant_uuid'],'server_host'=>$r['server_host'],'key_hash'=>$r['key_hash'],'label'=>$r['requested_label'],'access_token'=>$token,'public_key'=>$identity['public_key']];
            }$this->db->commit();return $out;
        }catch(Throwable $e){if($this->db->inTransaction())$this->db->rollBack();throw $e;}
    }
    public function workerRecord(array $input,bool $deferCommit=false): void {
        $this->requireWorker();self::keys($input,['job_uuid','revision','activation','error_category','retry_seconds'],['job_uuid','revision']);$job=self::uuid($input['job_uuid']);if(!is_int($input['revision'])||$input['revision']<1)throw new InvalidArgumentException('Invalid worker revision.');
        if($deferCommit&&!$this->db->inTransaction())throw new LogicException('A worker import transaction is required.');
        $identity=$this->publicIdentity();if(!$deferCommit)$this->db->beginTransaction();try{
            $r=$this->q('select o.*,j.job_uuid,j.state job_state from v_pbx_onboarding o join v_pbx_onboarding_jobs j on j.domain_uuid=o.domain_uuid and j.revision=o.revision where j.job_uuid=? and j.revision=? for update of o,j',[$job,$input['revision']])->fetch(PDO::FETCH_ASSOC);
            if(!$r||$r['job_state']==='superseded')throw new RuntimeException('This setup request is no longer current.');$local=$this->visible($r['service_uuid'],$r['owner_user_uuid']);if(count($local)!==1||$local[0]['owner_user_uuid']!==$r['owner_user_uuid']||$r['server_host']!==$identity['server_host']||$r['key_hash']!==$identity['key_hash'])throw new RuntimeException('This setup request no longer belongs to this server.');
            if(isset($input['activation'])){
                if(isset($input['error_category'])||isset($input['retry_seconds'])||!is_array($input['activation']))throw new InvalidArgumentException('Invalid worker result.');
                $bindings=['account_tenant_uuid'=>$r['account_tenant_uuid'],'local_tenant_uuid'=>$r['tenant_uuid'],'domain_uuid'=>$r['domain_uuid'],'key_hash'=>$r['key_hash'],'server_host'=>$r['server_host'],'label'=>$r['requested_label']];$p=self::verifyReceipt($input['activation'],$bindings,static::authorityPem());
                if($r['activation']!==null){$oldEnvelope=json_decode($r['activation'],true,6,JSON_THROW_ON_ERROR);$oldUnsigned=json_decode(self::decode($oldEnvelope['payload'],8192),true,6,JSON_THROW_ON_ERROR);$old=self::verifyReceipt($oldEnvelope,$bindings,static::authorityPem(),self::timestamp($oldUnsigned['issued_at']));$same=hash_equals($oldEnvelope['payload'],$input['activation']['payload'])&&hash_equals($oldEnvelope['signature'],$input['activation']['signature']);if($old['installation_uuid']!==$p['installation_uuid']||$p['generation']<$old['generation']||($p['generation']===$old['generation']&&!$same))throw new RuntimeException('An older or different registration cannot replace this one.');}
                // Queue only this exact local service; the existing custodian
                // worker owns DNS, HTTPS and all private-key operations.
                $this->q("select pg_advisory_xact_lock(hashtextextended('openweb-api-tenant-aliases',0))");
                $alias=$this->q('select * from v_pbx_tenant_domains where domain_uuid=? for update',[$r['domain_uuid']])->fetch(PDO::FETCH_ASSOC);
                if($alias&&($alias['tenant_uuid']!==$r['tenant_uuid']||$alias['service_uuid']!==$r['service_uuid']||$alias['requested_label']!==$r['requested_label']))throw new RuntimeException('This PBX already has a different reserved address.');
                if(!$alias){if((int)$this->q('select count(*) from v_pbx_tenant_domains')->fetchColumn()>=50)throw new RuntimeException('This instance needs additional managed-address capacity.');$this->q('insert into v_pbx_tenant_domains(domain_uuid,tenant_uuid,service_uuid,requested_label,desired_enabled) values(?,?,?,?,true)',[$r['domain_uuid'],$r['tenant_uuid'],$r['service_uuid'],$r['requested_label']]);}
                $this->q("update v_pbx_onboarding set activation=cast(? as jsonb),grant_expires_at=?,state='preparing',last_error_category='',updated_at=now() where domain_uuid=?",[json_encode($input['activation'],JSON_THROW_ON_ERROR),$p['expires_at'],$r['domain_uuid']]);if(static::registered($this->db,$r['domain_uuid']))$this->q("update v_pbx_onboarding set state='ready' where domain_uuid=?",[$r['domain_uuid']]);$this->q("update v_pbx_onboarding_jobs set state='completed',error_category='',updated_at=now() where job_uuid=?",[$job]);
            }else{
                $category=$input['error_category']??'network';$retry=$input['retry_seconds']??300;if(!in_array($category,['network','account_expired','rate_limited','public_address_pending','ownership_conflict','authority_unavailable','certificate_pending','local_configuration','verified_account_required','email_verification_required'],true)||!is_int($retry)||$retry<60||$retry>86400)throw new InvalidArgumentException('Invalid worker result.');
                $this->q("update v_pbx_onboarding_jobs set state='retry',error_category=?,next_attempt=now()+make_interval(secs=>?),updated_at=now() where job_uuid=?",[$category,$retry,$job]);$this->q("update v_pbx_onboarding set state=?,last_error_category=?,updated_at=now() where domain_uuid=?",[static::registered($this->db,$r['domain_uuid'])?'ready':'retry',$category,$r['domain_uuid']]);
            }if(!$deferCommit)$this->db->commit();
        }catch(Throwable $e){if(!$deferCommit&&$this->db->inTransaction())$this->db->rollBack();throw $e;}
    }
    /** Root-only image pairing imports a signed grant; it never accepts caller identity claims. */
    public function workerImport(array $input): array {
        $this->requireWorker();self::keys($input,['service_uuid','activation'],['service_uuid','activation']);$service=self::uuid($input['service_uuid']);if(!is_array($input['activation']))throw new InvalidArgumentException('A signed registration is required.');
        $identity=$this->publicIdentity();$this->db->beginTransaction();try{
            $owner=$this->q('select t.owner_user_uuid from v_pbx_services s join v_pbx_tenants t using(tenant_uuid) where s.service_uuid=? for update of s',[$service])->fetchColumn();if(!is_string($owner))throw new RuntimeException('The local PBX is unavailable.');
            $rows=$this->visible($service,$owner);if(count($rows)!==1)throw new RuntimeException('The local PBX owner is unavailable.');$local=$rows[0];$r=$this->row($local);
            // These two values are used only as expected fields for the
            // cryptographic verifier. Nothing is persisted before verification.
            $unsigned=json_decode(self::decode((string)($input['activation']['payload']??''),8192),true,6,JSON_THROW_ON_ERROR);
            $bindings=['account_tenant_uuid'=>$r['account_tenant_uuid']??($unsigned['account_tenant_uuid']??''),'local_tenant_uuid'=>$local['tenant_uuid'],'domain_uuid'=>$local['domain_uuid'],'key_hash'=>$identity['key_hash'],'server_host'=>$identity['server_host'],'label'=>$r&&$r['activation']!==null?$r['requested_label']:($unsigned['label']??'')];
            $p=self::verifyReceipt($input['activation'],$bindings,static::authorityPem());
            if($r&&$r['activation']!==null){$old=json_decode($r['activation'],true,6,JSON_THROW_ON_ERROR);if(hash_equals($old['payload']??'',$input['activation']['payload'])&&hash_equals($old['signature']??'',$input['activation']['signature'])){$this->db->commit();$this->workerReconcile($local['domain_uuid']);$ready=static::registered($this->db,$local['domain_uuid']);return ['service_uuid'=>$service,'domain_uuid'=>$local['domain_uuid'],'registration_confirmed'=>true,'ready'=>$ready,'url'=>$ready?pbx_tenant_domains::url($this->db,$local['domain_uuid']):null];}}
            $r=$this->row($local,true);$revision=(int)$r['revision']+1;$job=uuid();
            $this->q("update v_pbx_onboarding_jobs set state='superseded',updated_at=now() where domain_uuid=? and state in ('queued','preparing','retry')",[$local['domain_uuid']]);
            $this->q("update v_pbx_onboarding set account_tenant_uuid=?,requested_label=?,server_host=?,key_hash=?,revision=?,state='preparing',last_error_category='',updated_at=now() where domain_uuid=?",[$p['account_tenant_uuid'],$p['label'],$identity['server_host'],$identity['key_hash'],$revision,$local['domain_uuid']]);
            $this->q("insert into v_pbx_onboarding_jobs(job_uuid,domain_uuid,revision,state) values(?,?,?,'preparing')",[$job,$local['domain_uuid'],$revision]);
            $this->workerRecord(['job_uuid'=>$job,'revision'=>$revision,'activation'=>$input['activation']],true);$this->db->commit();
            $this->workerReconcile($local['domain_uuid']);$ready=static::registered($this->db,$local['domain_uuid']);return ['service_uuid'=>$service,'domain_uuid'=>$local['domain_uuid'],'registration_confirmed'=>true,'ready'=>$ready,'url'=>$ready?pbx_tenant_domains::url($this->db,$local['domain_uuid']):null];
        }catch(Throwable $e){if($this->db->inTransaction())$this->db->rollBack();throw $e;}
    }
    /** Persist readiness for native consumers, after signature and transport checks. */
    public function workerReconcile(?string $domain=null): array {
        $this->requireWorker();$rows=$this->q('select domain_uuid,state,revision,activation from v_pbx_onboarding'.($domain!==null?' where domain_uuid=?':'').' order by domain_uuid',$domain!==null?[self::uuid($domain)]:[])->fetchAll(PDO::FETCH_ASSOC);$ready=0;
        foreach($rows as$r){$ok=static::registered($this->db,$r['domain_uuid']);$ready+=(int)$ok;$state=$ok?'ready':($r['state']==='ready'?(static::receipt($this->db,$r['domain_uuid'])!==null?'preparing':'retry'):$r['state']);
            if($state!==$r['state'])$this->q('update v_pbx_onboarding set state=?,updated_at=now() where domain_uuid=? and revision=? and activation is not distinct from cast(? as jsonb)',[$state,$r['domain_uuid'],$r['revision'],$r['activation']]);}
        return ['checked'=>count($rows),'ready'=>$ready,'pending'=>count($rows)-$ready];
    }
}
