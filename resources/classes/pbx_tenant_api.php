<?php
/** OpenWeb PBX tenant API v1. Bearer credentials never authorize another tenant. */
class pbx_tenant_api_error extends RuntimeException {
    public function __construct(public readonly int $status, public readonly string $apiCode, string $message,
                                public readonly array $headers = []) { parent::__construct($message); }
}

/** Avoid global permission caches and the legacy CLI permission bypass. */
final class pbx_tenant_api_provisioner extends pbx_tenants {
    public function __construct(PDO $db, private array $grants) { parent::__construct($db); }
    protected function allowed(string $name): bool {
        return in_array($name, ['pbx_service_view','pbx_service_create','pbx_template_manage'], true)
            && isset($this->grants[$name]);
    }
}

class pbx_tenant_api {
    private PDO $db;
    private array $policy;
    private const SIGNUP_RESPONSE = ['status'=>'verification_required','message'=>'If these details can be registered, a verification code will be emailed. Check your inbox and spam folder.'];
    public function __construct(?PDO $db = null, ?array $policy = null) {
        $this->db = $db ?? database::new()->db;
        $this->db->setAttribute(PDO::ATTR_ERRMODE, PDO::ERRMODE_EXCEPTION);
        $c = config::load();
        $this->policy = $policy ?? [
            'enabled'=>filter_var($c->get('openweb.tenant_api_enabled','false'),FILTER_VALIDATE_BOOLEAN),
            'registration_enabled'=>filter_var($c->get('openweb.tenant_api_registration_enabled','false'),FILTER_VALIDATE_BOOLEAN),
            'service_limit'=>(int)$c->get('openweb.tenant_api_service_limit','1'),
            'max_public_tenants'=>(int)$c->get('openweb.tenant_api_max_public_tenants','25'),
        ];
        $this->policy += ['enabled'=>false,'registration_enabled'=>false,'service_limit'=>1,'max_public_tenants'=>25];
        if (!is_bool($this->policy['enabled']) || !is_bool($this->policy['registration_enabled'])
            || !is_int($this->policy['service_limit']) || $this->policy['service_limit']<1 || $this->policy['service_limit']>10
            || !is_int($this->policy['max_public_tenants']) || $this->policy['max_public_tenants']<1 || $this->policy['max_public_tenants']>1000) {
            throw new RuntimeException('Tenant API policy is invalid.');
        }
    }
    protected function q(string $sql, array $params = []): PDOStatement {
        $s=$this->db->prepare($sql);
        foreach($params as $key=>$value) $s->bindValue(is_int($key)?$key+1:':'.$key,$value,$value===null?PDO::PARAM_NULL:(is_bool($value)?PDO::PARAM_BOOL:(is_int($value)?PDO::PARAM_INT:PDO::PARAM_STR)));
        $s->execute(); return $s;
    }
    private function fail(int $status,string $code,string $message,array $headers=[]): never { throw new pbx_tenant_api_error($status,$code,$message,$headers); }
    private function fields(array $input,array $allowed,array $required=[]): void {
        if (array_is_list($input) && $input!==[]) $this->fail(400,'invalid_request','Send a JSON object.');
        if (array_diff(array_keys($input),$allowed) || array_diff($required,array_keys($input))) $this->fail(400,'invalid_request','Check the required and supported fields.');
    }
    private function text(mixed $value,int $min,int $max,string $field): string {
        if (!is_string($value) || strlen($value)>$max || strlen(trim($value))<$min || preg_match('/[\x00-\x1f\x7f]/',$value)) $this->fail(400,'invalid_request','Check '.$field.'.');
        return trim($value);
    }
    private function slug(mixed $value): string {
        $value=strtolower($this->text($value,3,40,'the short name'));
        if (!preg_match('/^[a-z0-9](?:[a-z0-9-]{1,38}[a-z0-9])$/D',$value)) $this->fail(400,'invalid_request','Use 3 to 40 letters, numbers or hyphens, without an opening or closing hyphen.');
        return $value;
    }
    private function email(mixed $value): string {
        $value=strtolower($this->text($value,3,254,'the email address'));
        if (!filter_var($value,FILTER_VALIDATE_EMAIL)) $this->fail(400,'invalid_request','Enter a valid email address.');
        return $value;
    }
    private function password(mixed $value): string {
        if (!is_string($value) || strlen($value)<12 || strlen($value)>72 || preg_match('/[\x00-\x1f\x7f]/',$value)
            || !preg_match('/[A-Za-z]/',$value) || !preg_match('/[0-9]/',$value)) $this->fail(400,'invalid_request','Use a password with 12 to 72 bytes, including a letter and a number.');
        return $value;
    }
    private function identifier(mixed $value): string {
        if (!is_string($value) || !is_uuid($value)) $this->fail(400,'invalid_request','Use a valid UUID.');
        return strtolower($value);
    }
    private static function yes(mixed $value): bool { return in_array($value,[true,'t','true',1,'1'],true); }
    private function hash(string $value): string {
        $key=@file_get_contents(pbx_paths::key());
        if (!is_string($key) || strlen($key)!==32) throw new RuntimeException('The instance encryption key is unavailable.');
        return hash_hmac('sha256',$value,$key);
    }
    public function rate(string $key,int $limit,int $seconds): void {
        $count=$this->q("insert into v_pbx_api_rate(bucket,window_start,attempts) values(:bucket,now(),1) on conflict(bucket) do update set attempts=case when v_pbx_api_rate.window_start<now()-make_interval(secs=>:seconds) then 1 else v_pbx_api_rate.attempts+1 end,window_start=case when v_pbx_api_rate.window_start<now()-make_interval(secs=>:seconds) then now() else v_pbx_api_rate.window_start end returning attempts",['bucket'=>$this->hash($key),'seconds'=>$seconds])->fetchColumn();
        if ((int)$count>$limit) $this->fail(429,'rate_limited','Please wait before trying again.',['Retry-After'=>(string)$seconds]);
        if (random_int(1,100)===1) {
            $this->q("delete from v_pbx_api_rate where window_start<now()-interval '2 days'");
            $this->q("delete from v_pbx_api_registrations where verified_at is null and expires_at<now()-interval '2 days'");
        }
    }
    protected function domains(): pbx_tenant_api_domains { return new pbx_tenant_api_domains($this->db); }
    protected function installationAuthority(): pbx_installation_authority {return new pbx_installation_authority($this->db);}
    /** Existing mail queue dispatches through the instance-wide SMTP service. */
    protected function queueVerification(array $registration,string $token): void {
        $platform=$this->q('select domain_uuid from v_domains where domain_name=:host',['host'=>pbx_paths::host()])->fetchColumn();
        if (!is_string($platform)) throw new RuntimeException('The installation domain is unavailable.');
        $h=static fn(string $value): string=>htmlspecialchars($value,ENT_QUOTES|ENT_SUBSTITUTE,'UTF-8');
        $body='<h1>Verify your OpenWeb PBX account</h1><p>A registration was requested for '.$h($registration['tenant_name']).'.</p>'
            .'<p>Your one-use verification code is:</p><p><code>'.$token.'</code></p>'
            .'<p>Send this code as the <code>token</code> field, together with the password you chose when registering, to <code>POST '.$h(pbx_paths::url()).'/api/v1/registrations/verify</code>. It expires in 30 minutes.</p>'
            .'<p>API documentation: <a href="https://openwebpbx.com/api-docs">openwebpbx.com/api-docs</a>.</p>'
            .'<p>If you did not request this account, ignore this message. No PBX has been created.</p>';
        $this->q("insert into v_email_queue(email_queue_uuid,domain_uuid,hostname,email_date,email_from,email_to,email_subject,email_body,email_status) values(:id,:domain,:hostname,now(),'',:email,'Verify your OpenWeb PBX account',:body,'waiting')",
            ['id'=>uuid(),'domain'=>$platform,'hostname'=>gethostname(),'email'=>$registration['email'],'body'=>$body]);
    }
    private function audit(?array $account,string $action,?string $target=null): void {
        $this->q('insert into v_pbx_api_audit(audit_uuid,tenant_uuid,user_uuid,action,target_uuid) values(:id,:tenant,:user,:action,:target)',
            ['id'=>uuid(),'tenant'=>$account['tenant_uuid']??null,'user'=>$account['user_uuid']??null,'action'=>$action,'target'=>$target]);
    }
    public function register(array $input,string $ip): array {
        if (!$this->policy['registration_enabled']) $this->fail(403,'registration_disabled','Public registration is not enabled on this instance.');
        $this->fields($input,['tenant_name','slug','email','password','accept_terms'],['tenant_name','slug','email','password','accept_terms']);
        $name=$this->text($input['tenant_name'],1,120,'the company name'); $slug=$this->slug($input['slug']); $email=$this->email($input['email']); $password=$this->password($input['password']);
        if ($input['accept_terms']!==true) $this->fail(400,'terms_required','Accept the terms and privacy policy before registering.');
        $availability=$this->domains()->availability($slug);
        if (!empty($availability['reserved'])) $this->fail(400,'invalid_subdomain','Choose another short name.');
        $this->rate('signup:ip:'.$ip,5,3600); $this->rate('signup:email:'.$email,3,3600); $this->rate('signup:global',100,86400);
        // Hash for both existing and new identities, keeping the response generic.
        $passwordHash=password_hash($password,PASSWORD_DEFAULT); $token=bin2hex(random_bytes(32));
        $this->db->beginTransaction();
        try {
            $this->q("select pg_advisory_xact_lock(hashtextextended('openweb-api-signup',0))");
            if ((int)$this->q('select count(*) from v_pbx_api_registrations where verified_at is not null')->fetchColumn()>=$this->policy['max_public_tenants']) $this->fail(503,'registration_capacity','New tenant registration is temporarily at capacity.');
            $exists=$this->q('select 1 from v_users where lower(username)=:email or lower(user_email)=:email union all select 1 from v_pbx_tenants where lower(invite_email)=:email or slug=:slug limit 1',['email'=>$email,'slug'=>$slug])->fetchColumn();
            if (!$exists) {
                // Each retry invalidates older codes for this email; it never
                // changes a live identity or reserves a public DNS address.
                $this->q('delete from v_pbx_api_registrations where lower(email)=:email and verified_at is null',['email'=>$email]);
                $registration=['registration_uuid'=>uuid(),'tenant_name'=>$name,'slug'=>$slug,'email'=>$email];
                $this->q("insert into v_pbx_api_registrations(registration_uuid,tenant_name,slug,email,password_hash,verification_hash,expires_at) values(:id,:name,:slug,:email,:password,:token,now()+interval '30 minutes')",
                    ['id'=>$registration['registration_uuid'],'name'=>$name,'slug'=>$slug,'email'=>$email,'password'=>$passwordHash,'token'=>hash('sha256',$token)]);
                $this->queueVerification($registration,$token);
            }
            $this->db->commit(); return self::SIGNUP_RESPONSE;
        } catch(Throwable $ex) { if($this->db->inTransaction())$this->db->rollBack(); throw $ex; }
    }
    public function verify(array $input,string $ip): array {
        if (!$this->policy['registration_enabled']) $this->fail(403,'registration_disabled','Public registration is not enabled on this instance.');
        $this->fields($input,['token','password'],['token','password']); $this->rate('verify:ip:'.$ip,30,600);
        $token=$input['token']; if(!is_string($token)||!preg_match('/^[a-f0-9]{64}$/D',$token)) $this->fail(400,'verification_invalid','The verification code is invalid or expired.');
        $password=$this->password($input['password']);
        $this->db->beginTransaction();
        try {
            $this->q("select pg_advisory_xact_lock(hashtextextended('openweb-api-signup',0))");
            $r=$this->q('select * from v_pbx_api_registrations where verification_hash=:hash and verified_at is null and expires_at>now() for update',['hash'=>hash('sha256',$token)])->fetch(PDO::FETCH_ASSOC);
            if (!$r || !password_verify($password,$r['password_hash'])) $this->fail(400,'verification_invalid','The verification code or registration password is invalid or expired.');
            if ((int)$this->q('select count(*) from v_pbx_api_registrations where verified_at is not null')->fetchColumn()>=$this->policy['max_public_tenants']) $this->fail(503,'registration_capacity','New tenant registration is temporarily at capacity.');
            if ($this->q('select 1 from v_users where lower(username)=:email or lower(user_email)=:email union all select 1 from v_pbx_tenants where lower(invite_email)=:email or slug=:slug limit 1',['email'=>$r['email'],'slug'=>$r['slug']])->fetchColumn()) $this->fail(409,'registration_conflict','The requested company name or account is unavailable. Contact the instance administrator.');
            $group=$this->q("select group_uuid from v_groups where group_name='tenant_admin' and domain_uuid is null")->fetchColumn();
            if (!is_string($group)) throw new RuntimeException('The tenant role is unavailable.');
            $domain=uuid();$tenant=uuid();$user=uuid();$realm=$r['slug'].'.'.pbx_paths::host();
            if(strlen($realm)>253)throw new RuntimeException('The instance hostname is too long.');
            $this->q("insert into v_domains(domain_uuid,domain_name,domain_description,domain_enabled) values(:id,:name,:description,'true')",['id'=>$domain,'name'=>$realm,'description'=>$r['tenant_name'].' workspace']);
            $this->q("insert into v_users(user_uuid,domain_uuid,username,user_email,password,user_enabled,user_type) values(:id,:domain,:email,:email,:password,'true','default')",['id'=>$user,'domain'=>$domain,'email'=>$r['email'],'password'=>$r['password_hash']]);
            $this->q("insert into v_user_groups(user_group_uuid,domain_uuid,user_uuid,group_uuid,group_name) values(:id,:domain,:user,:group,'tenant_admin')",['id'=>uuid(),'domain'=>$domain,'user'=>$user,'group'=>$group]);
            $this->q('insert into v_pbx_tenants(tenant_uuid,tenant_name,slug,home_domain_uuid,owner_user_uuid,invite_email,service_limit) values(:id,:name,:slug,:domain,:user,:email,:limit)',
                ['id'=>$tenant,'name'=>$r['tenant_name'],'slug'=>$r['slug'],'domain'=>$domain,'user'=>$user,'email'=>$r['email'],'limit'=>$this->policy['service_limit']]);
            $this->q('update v_pbx_api_registrations set verified_at=now(),tenant_uuid=:tenant,verification_hash=null,password_hash=\'\' where registration_uuid=:id',['tenant'=>$tenant,'id'=>$r['registration_uuid']]);
            $account=$this->owner($tenant,$user);$issued=$this->issueToken($account,'Initial API key',90);$this->audit($account,'tenant_registered',$tenant);
            $this->db->commit();return ['tenant'=>$this->tenantView($account)]+$issued;
        }catch(Throwable $ex){if($this->db->inTransaction())$this->db->rollBack();throw $ex;}
    }
    private function owner(string $tenant,string $user): array {
        $r=$this->q("select t.tenant_uuid,t.tenant_name,t.slug,t.invite_email,t.home_domain_uuid,t.service_limit,t.owner_user_uuid user_uuid
            from v_pbx_tenants t join v_users u on u.user_uuid=t.owner_user_uuid and u.user_uuid=:user
            where t.tenant_uuid=:tenant and t.enabled=true and u.user_enabled='true'
            and exists(select 1 from v_user_groups ug join v_groups g on g.group_uuid=ug.group_uuid where ug.user_uuid=u.user_uuid and ug.group_name='tenant_admin' and g.group_name='tenant_admin' and g.domain_uuid is null)",['tenant'=>$tenant,'user'=>$user])->fetch(PDO::FETCH_ASSOC);
        if (!$r) $this->fail(401,'invalid_token','Sign in again or contact your tenant administrator.');
        return $r;
    }
    private function tenantView(array $a): array {
        return ['tenant_uuid'=>$a['tenant_uuid'],'tenant_name'=>$a['tenant_name'],'slug'=>$a['slug'],'email'=>$a['invite_email'],
            'service_limit'=>(int)$a['service_limit'],'service_count'=>(int)$this->q('select count(*) from v_pbx_services where tenant_uuid=:tenant',['tenant'=>$a['tenant_uuid']])->fetchColumn()];
    }
    private function tokenView(array $r): array {
        $out=['token_uuid'=>$r['token_uuid']]; foreach(['created_at','expires_at','revoked_at','last_used_at'] as $key)$out[$key]=isset($r[$key])?(new DateTimeImmutable($r[$key]))->format(DATE_RFC3339):null;
        $out['name']=$r['token_name'];return $out;
    }
    private function issueToken(array $account,string $name,int $days): array {
        if (!$this->db->inTransaction()) throw new LogicException('Token issuance requires a transaction.');
        $this->q('select tenant_uuid from v_pbx_tenants where tenant_uuid=:tenant for update',['tenant'=>$account['tenant_uuid']]);
        if ((int)$this->q('select count(*) from v_pbx_api_tokens where tenant_uuid=:tenant and user_uuid=:user and revoked_at is null and expires_at>now()',['tenant'=>$account['tenant_uuid'],'user'=>$account['user_uuid']])->fetchColumn()>=10) $this->fail(409,'token_limit','Revoke an unused API key before creating another.');
        $secret='owta_'.bin2hex(random_bytes(32));
        $row=$this->q('insert into v_pbx_api_tokens(token_uuid,tenant_uuid,user_uuid,token_name,token_hash,expires_at) values(:id,:tenant,:user,:name,:hash,now()+make_interval(days=>:days)) returning *',
            ['id'=>uuid(),'tenant'=>$account['tenant_uuid'],'user'=>$account['user_uuid'],'name'=>$name,'hash'=>hash('sha256',$secret),'days'=>$days])->fetch(PDO::FETCH_ASSOC);
        $this->audit($account,'token_created',$row['token_uuid']);
        return ['access_token'=>$secret,'token_type'=>'Bearer','expires_at'=>(new DateTimeImmutable($row['expires_at']))->format(DATE_RFC3339),'token'=>$this->tokenView($row)];
    }
    public function login(array $input,string $ip): array {
        $this->fields($input,['email','password'],['email','password']);$email=$this->email($input['email']);
        if(!is_string($input['password'])||strlen($input['password'])<1||strlen($input['password'])>72||preg_match('/[\x00-\x1f\x7f]/',$input['password']))$this->fail(401,'invalid_credentials','The email or password is incorrect.');
        $this->rate('login:ip:'.$ip,20,600);$this->rate('login:email:'.$email,8,600);
        $r=$this->q('select t.tenant_uuid,u.user_uuid,u.password from v_pbx_tenants t join v_users u on u.user_uuid=t.owner_user_uuid where lower(u.username)=:email or lower(u.user_email)=:email limit 1',['email'=>$email])->fetch(PDO::FETCH_ASSOC);
        // Fixed dummy hash retains a password verifier on unknown identities.
        $dummy='$2y$10$92IXUNpkjO0rOQ5byMi.Ye4oKoEa3Ro9llC/.og/at2uheWG/igi.';
        if(!password_verify($input['password'],$r['password']??$dummy)||!$r)$this->fail(401,'invalid_credentials','The email or password is incorrect.');
        $this->db->beginTransaction();try{
            $a=$this->owner($r['tenant_uuid'],$r['user_uuid']);$issued=$this->issueToken($a,'Login API key',90);$this->db->commit();return ['tenant'=>$this->tenantView($a)]+$issued;
        }catch(Throwable $ex){if($this->db->inTransaction())$this->db->rollBack();throw $ex;}
    }
    public function authenticate(string $authorization): array {
        if(!preg_match('/^Bearer (owta_[a-f0-9]{64})$/D',$authorization,$m))$this->fail(401,'invalid_token','Supply a valid Bearer API key.');
        $r=$this->q('select * from v_pbx_api_tokens where token_hash=:hash and revoked_at is null and expires_at>now()',['hash'=>hash('sha256',$m[1])])->fetch(PDO::FETCH_ASSOC);
        if(!$r)$this->fail(401,'invalid_token','This API key is invalid or expired.');
        $a=$this->owner($r['tenant_uuid'],$r['user_uuid']);$this->q("update v_pbx_api_tokens set last_used_at=now() where token_uuid=:id and (last_used_at is null or last_used_at<now()-interval '5 minutes')",['id'=>$r['token_uuid']]);
        $a['token_uuid']=$r['token_uuid'];$a['token_name']=$r['token_name'];$a['token']=$this->tokenView($r);return $a;
    }
    private function grants(array $a): array {
        $rows=$this->q("select distinct p.permission_name from v_user_groups ug join v_groups g on g.group_uuid=ug.group_uuid join v_group_permissions p on p.group_uuid=g.group_uuid and p.group_name=g.group_name
            where ug.user_uuid=:user and ug.group_name='tenant_admin' and g.group_name='tenant_admin' and g.domain_uuid is null and p.permission_assigned='true' and (p.domain_uuid is null or p.domain_uuid=:domain)",['user'=>$a['user_uuid'],'domain'=>$a['home_domain_uuid']])->fetchAll(PDO::FETCH_COLUMN);
        return array_fill_keys($rows,true);
    }
    private function withOwner(array $a,callable $fn): mixed {
        $saved=$_SESSION??[];
        $_SESSION=['authorized'=>true,'user_uuid'=>$a['user_uuid'],'domain_uuid'=>$a['home_domain_uuid'],'user'=>['domain_uuid'=>$a['home_domain_uuid']]];
        try { return $fn(new pbx_tenant_api_provisioner($this->db,$this->grants($a))); }
        finally { $_SESSION=$saved; }
    }
    private function eligible(array $row): bool {
        // Public self-service starts without carrier connections. An owner can
        // configure their own provider after opening the new PBX admin panel.
        return ($row['tenant_uuid']!==null || self::yes($row['api_enabled']??false))
            && empty($row['config']['trunks']) && empty($row['config']['rules']) && empty($row['config']['settings']);
    }
    public function templates(array $a): array {
        return $this->withOwner($a,function(pbx_tenants $app): array {
            $out=[];foreach($app->templates() as $entry){$r=$app->template($entry['template_uuid']);if(!$this->eligible($r))continue;
                $row=array_intersect_key($r,array_flip(['template_uuid','template_name','description','version']));$row['version']=(int)$row['version'];
                foreach(['timezone','extension_start','extension_count','extension_limit'] as $key)$row[$key]=$r['config'][$key];$out[]=$row;
            }return ['templates'=>$out];
        });
    }
    private function serviceView(array $r): array {
        $out=array_intersect_key($r,array_flip(['service_uuid','tenant_uuid','domain_uuid','service_name','template_uuid','template_name','created_at']));
        $out['created_at']=(new DateTimeImmutable($out['created_at']))->format(DATE_RFC3339);
        $out['template_version']=(int)$r['template_version'];$out['sip_domain']=$r['domain_name'];$out['software_version']=pbx_updates::version();return $out;
    }
    private function service(array $a,string $id): array {
        $r=$this->q('select s.*,d.domain_name from v_pbx_services s join v_domains d using(domain_uuid) where s.tenant_uuid=:tenant and s.service_uuid=:service',['tenant'=>$a['tenant_uuid'],'service'=>$this->identifier($id)])->fetch(PDO::FETCH_ASSOC);
        if(!$r)$this->fail(404,'not_found','This PBX service is unavailable.');return $this->serviceView($r);
    }
    private function canonical(mixed $value): mixed {
        if(!is_array($value))return $value;if(!array_is_list($value))ksort($value,SORT_STRING);foreach($value as &$item)$item=$this->canonical($item);return $value;
    }
    private function idempotent(array $a,string $key,string $operation,array $input,callable $fn): array {
        $key=$this->identifier($key);$hash=hash('sha256',json_encode($this->canonical($input),JSON_THROW_ON_ERROR));
        $this->db->beginTransaction();try{
            $this->q('select tenant_uuid from v_pbx_tenants where tenant_uuid=:tenant for update',['tenant'=>$a['tenant_uuid']]);
            $r=$this->q('select * from v_pbx_api_idempotency where tenant_uuid=:tenant and idempotency_key=:key for update',['tenant'=>$a['tenant_uuid'],'key'=>$key])->fetch(PDO::FETCH_ASSOC);
            if($r){if($r['operation']!==$operation||!hash_equals($r['request_hash'],$hash))$this->fail(409,'idempotency_conflict','This Idempotency-Key was used for a different request.');
                if($r['response_status']===null||$r['response_body']===null)throw new RuntimeException('An incomplete idempotent request needs review.');
                $this->db->commit();return [(int)$r['response_status'],json_decode($r['response_body'],true,16,JSON_THROW_ON_ERROR),['Idempotent-Replayed'=>'true']];}
            $this->q('insert into v_pbx_api_idempotency(tenant_uuid,idempotency_key,operation,request_hash) values(:tenant,:key,:operation,:hash)',['tenant'=>$a['tenant_uuid'],'key'=>$key,'operation'=>$operation,'hash'=>$hash]);
            [$status,$body]=$fn();$this->q('update v_pbx_api_idempotency set response_status=:status,response_body=cast(:body as jsonb) where tenant_uuid=:tenant and idempotency_key=:key',
                ['status'=>$status,'body'=>json_encode($body,JSON_THROW_ON_ERROR),'tenant'=>$a['tenant_uuid'],'key'=>$key]);
            $this->db->commit();return [$status,$body,[]];
        }catch(Throwable $ex){if($this->db->inTransaction())$this->db->rollBack();throw $ex;}
    }
    protected function afterProvision(array $account,string $service): void {
        settings::clear_cache();$cache=new cache;$cache->delete(gethostname().':configuration:sofia.conf');
        try { event_socket::api('reloadxml'); } catch(Throwable $ignored) { error_log('OpenWeb PBX tenant API: service created; XML refresh deferred.'); }
    }
    protected function initializeService(array $account,array $service,array $template): void {
        (new pbx_tenant_api_setup($this->db))->initialize($account,$service,$template);
    }
    private function createService(array $a,array $input,string $key): array {
        $this->fields($input,['template_uuid','service_name','slug','subdomain'],['template_uuid','service_name','slug']);
        $template=$this->identifier($input['template_uuid']);$name=$this->text($input['service_name'],1,120,'the service name');$slug=$this->slug($input['slug']);$label=$input['subdomain']??$a['slug'];
        if(!is_string($label))$this->fail(400,'invalid_subdomain','Choose a subdomain label.');
        $result=$this->idempotent($a,$key,'create_service',$input,function()use($a,$template,$name,$slug,$label): array {
            return $this->withOwner($a,function(pbx_tenants $app)use($a,$template,$name,$slug,$label): array {
                $current=$this->owner($a['tenant_uuid'],$a['user_uuid']);
                if(!isset($this->grants($current)['pbx_service_create']))$this->fail(403,'permission_denied','Your tenant role does not allow creating PBX services.');
                if((int)$this->q('select count(*) from v_pbx_services where tenant_uuid=:tenant',['tenant'=>$a['tenant_uuid']])->fetchColumn()>=(int)$current['service_limit'])$this->fail(409,'service_limit','This tenant has reached its PBX service limit.');
                if(!$this->q('select 1 from v_pbx_templates where template_uuid=:id and published=true and ((tenant_uuid is null and api_enabled=true) or tenant_uuid=:tenant)',['id'=>$template,'tenant'=>$a['tenant_uuid']])->fetchColumn())$this->fail(404,'template_unavailable','This PBX template is unavailable.');
                try {$fullTemplate=$app->template($template);}
                catch(RuntimeException $denied){
                    // These are the shared model's exact, intentional access
                    // refusals. Encryption/storage failures retain their 503.
                    if($denied->getMessage()==='Choose a provider-free starter template.')$this->fail(403,'template_unavailable','Choose a provider-free self-service template.');
                    if(in_array($denied->getMessage(),['Template access denied.','Choose a published template.'],true))$this->fail(404,'template_unavailable','This PBX template is unavailable.');
                    throw $denied;
                }
                if(!$this->eligible($fullTemplate))$this->fail(403,'template_unavailable','Choose a self-service template without provider connections or outgoing provider rules.');
                $service=$app->provision(['tenant_uuid'=>$a['tenant_uuid'],'template_uuid'=>$template,'service_name'=>$name,'slug'=>$slug,'request_uuid'=>uuid()],true);
                $this->initializeService($a,$this->service($a,$service),$fullTemplate);
                $subdomain=$this->domains()->request($a,$service,$label);$this->audit($a,'service_created',$service);
                return [201,['service'=>$this->service($a,$service),'subdomain'=>$subdomain]];
            });
        });
        if(empty($result[2]['Idempotent-Replayed']))$this->afterProvision($a,$result[1]['service']['service_uuid']);return $result;
    }
    private function days(array $input): int {
        $days=$input['expires_in_days']??90;if(!is_int($days)||$days<1||$days>90)$this->fail(400,'invalid_request','API keys may be valid for 1 to 90 days.');return $days;
    }
    private function tokenChange(array $a,string $action,?string $id,array $input): array {
        $allowed=$action==='create'?['name','expires_in_days']:($action==='rotate'?['expires_in_days']:[]);$this->fields($input,$allowed,$action==='create'?['name']:[]);
        $name=$action==='create'?$this->text($input['name'],1,80,'the API key name'):'';$days=$this->days($input);
        $this->db->beginTransaction();try{
            $this->q('select tenant_uuid from v_pbx_tenants where tenant_uuid=:tenant for update',['tenant'=>$a['tenant_uuid']]);
            if($action!=='create'){
                $r=$this->q('select * from v_pbx_api_tokens where token_uuid=:id and tenant_uuid=:tenant and user_uuid=:user for update',['id'=>$this->identifier($id),'tenant'=>$a['tenant_uuid'],'user'=>$a['user_uuid']])->fetch(PDO::FETCH_ASSOC);
                if(!$r)$this->fail(404,'not_found','This API key is unavailable.');
                if($action==='rotate'&&($r['revoked_at']!==null||strtotime($r['expires_at'])<=time()))$this->fail(409,'token_unavailable','Only an active API key can be rotated.');
                $this->q('update v_pbx_api_tokens set revoked_at=coalesce(revoked_at,now()) where token_uuid=:id',['id'=>$r['token_uuid']]);$this->audit($a,'token_revoked',$r['token_uuid']);$name=$r['token_name'];
            }
            $out=$action==='revoke'?[]:$this->issueToken($a,$name,$days);$this->db->commit();return [$action==='revoke'?204:201,$out,[]];
        }catch(Throwable $ex){if($this->db->inTransaction())$this->db->rollBack();throw $ex;}
    }
    private function changePassword(array $a,array $input): array {
        $this->fields($input,['current_password','new_password'],['current_password','new_password']);
        $current=$input['current_password'];
        if(!is_string($current)||strlen($current)<1||strlen($current)>72||preg_match('/[\x00-\x1f\x7f]/',$current))$this->fail(401,'current_password_invalid','The current administrator password is incorrect.');
        $replacement=$this->password($input['new_password']);$this->rate('password:'.$a['user_uuid'],5,600);
        $hash=password_hash($replacement,PASSWORD_DEFAULT);
        $this->db->beginTransaction();try{
            $this->q('select tenant_uuid from v_pbx_tenants where tenant_uuid=:tenant for update',['tenant'=>$a['tenant_uuid']]);
            $account=$this->owner($a['tenant_uuid'],$a['user_uuid']);
            $old=$this->q('select password from v_users where user_uuid=:user for update',['user'=>$a['user_uuid']])->fetchColumn();
            if(!is_string($old)||!password_verify($current,$old))$this->fail(401,'current_password_invalid','The current administrator password is incorrect.');
            $this->q('update v_users set password=:password where user_uuid=:user',['password'=>$hash,'user'=>$a['user_uuid']]);
            $this->q('update v_pbx_api_tokens set revoked_at=now() where tenant_uuid=:tenant and user_uuid=:user and revoked_at is null',['tenant'=>$a['tenant_uuid'],'user'=>$a['user_uuid']]);
            $this->audit($account,'password_changed',$a['user_uuid']);$issued=$this->issueToken($account,'Password change API key',90);
            $this->db->commit();return [200,$issued,[]];
        }catch(Throwable $ex){if($this->db->inTransaction())$this->db->rollBack();throw $ex;}
    }
    /** Return [HTTP status, JSON body, extra headers]; never trust browser sessions. */
    public function handle(string $method,string $route,array $input,array $headers,string $ip): array {
        if(!$this->policy['enabled'])$this->fail(503,'api_disabled','The tenant API is not enabled on this instance.');
        if(!$this->q("select to_regclass('v_pbx_api_tokens')")->fetchColumn())$this->fail(503,'api_unavailable','The tenant API needs installation.');
        $headers=array_change_key_case($headers,CASE_LOWER);$route=rtrim($route,'/')?:'/';
        if($method==='GET'&&$route==='/health')return [200,['api'=>'OpenWeb PBX Tenant API','version'=>'1','software_version'=>pbx_updates::version(),'registration_enabled'=>$this->policy['registration_enabled'],'documentation'=>'https://openwebpbx.com/api-docs'],[]];
        if($method==='GET'&&$route==='/onboarding/authority')return [200,$this->installationAuthority()->authority(),[]];
        if($method==='POST'&&$route==='/registrations')return [202,$this->register($input,$ip),[]];
        if($method==='POST'&&$route==='/registrations/verify')return [201,$this->verify($input,$ip),[]];
        if($method==='POST'&&$route==='/auth/token')return [200,$this->login($input,$ip),[]];
        $account=$this->authenticate($headers['authorization']??'');$this->rate('request:'.$account['tenant_uuid'],120,60);
        if($route==='/onboarding/email/request'&&$method==='POST'){
            $this->rate('installation-email-request:'.$account['tenant_uuid'],3,3600);return [202,$this->installationAuthority()->requestEmail($account,$input),[]];
        }
        if($route==='/onboarding/email/verify'&&$method==='POST'){
            $this->rate('installation-email-verify:'.$account['tenant_uuid'],10,600);return [200,$this->installationAuthority()->verifyEmail($account,$input),[]];
        }
        if($route==='/installations/challenge'&&$method==='POST'){
            $this->rate('installation-challenge:'.$account['tenant_uuid'],20,600);return [201,$this->installationAuthority()->challenge($account,$input),[]];
        }
        if($route==='/installations'){
            if($method==='GET')return [200,$this->installationAuthority()->list($account),[]];
            if($method==='POST'){$this->rate('installation-authorize:'.$account['tenant_uuid'],20,600);return [201,$this->installationAuthority()->authorize($account,$input),[]];}
        }
        if($method==='GET'&&preg_match('~^/installations/([0-9a-fA-F-]{36})$~D',$route,$installation))return [200,$this->installationAuthority()->get($account,$installation[1]),[]];
        if($method==='GET'&&$route==='/me')return [200,['tenant'=>$this->tenantView($account),'token'=>$account['token']],[]];
        if($method==='POST'&&$route==='/me/password')return $this->changePassword($account,$input);
        if($method==='GET'&&$route==='/templates')return [200,$this->templates($account),[]];
        if($route==='/services'){
            if($method==='GET'){
                $rows=$this->q('select s.*,d.domain_name from v_pbx_services s join v_domains d using(domain_uuid) where s.tenant_uuid=:tenant order by s.created_at,s.service_uuid limit 100',['tenant'=>$account['tenant_uuid']])->fetchAll(PDO::FETCH_ASSOC);
                return [200,['services'=>array_map(fn(array $r):array=>$this->serviceView($r),$rows)],[]];
            }
            if($method==='POST')return $this->createService($account,$input,$headers['idempotency-key']??'');
        }
        if($method==='GET'&&$route==='/subdomains/availability'){
            $this->fields($input,['label'],['label']);if(!is_string($input['label']))$this->fail(400,'invalid_subdomain','Choose a subdomain label.');return [200,$this->domains()->availability($input['label']),[]];
        }
        if(preg_match('~^/services/([0-9a-fA-F-]{36})(/subdomain)?$~D',$route,$m)){
            $service=$this->identifier($m[1]);$this->service($account,$service);
            if(empty($m[2])&&$method==='GET')return [200,['service'=>$this->service($account,$service)],[]];
            if(!empty($m[2])&&$method==='GET')return [200,['subdomain'=>$this->domains()->status($account,$service)],[]];
            if(!empty($m[2])&&$method==='POST'){
                $this->fields($input,['label'],['label']);if(!is_string($input['label']))$this->fail(400,'invalid_subdomain','Choose a subdomain label.');
                return $this->idempotent($account,$headers['idempotency-key']??'','subdomain:'.$service,$input,function()use($account,$service,$input):array {
                    $out=$this->domains()->request($account,$service,$input['label']);$this->audit($account,'subdomain_requested',$service);return [200,['subdomain'=>$out]];
                });
            }
        }
        if($route==='/tokens'){
            if($method==='GET')return [200,['tokens'=>array_map(fn(array $r):array=>$this->tokenView($r),$this->q('select * from v_pbx_api_tokens where tenant_uuid=:tenant and user_uuid=:user order by created_at desc limit 100',['tenant'=>$account['tenant_uuid'],'user'=>$account['user_uuid']])->fetchAll(PDO::FETCH_ASSOC))],[]];
            if($method==='POST')return $this->tokenChange($account,'create',null,$input);
        }
        if(preg_match('~^/tokens/([0-9a-fA-F-]{36})(/rotate)?$~D',$route,$m)){
            if(empty($m[2])&&$method==='DELETE')return $this->tokenChange($account,'revoke',$m[1],$input);
            if(!empty($m[2])&&$method==='POST')return $this->tokenChange($account,'rotate',$m[1],$input);
        }
        $known=['/health'=>['GET'],'/onboarding/authority'=>['GET'],'/onboarding/email/request'=>['POST'],'/onboarding/email/verify'=>['POST'],'/installations/challenge'=>['POST'],'/installations'=>['GET','POST'],'/registrations'=>['POST'],'/registrations/verify'=>['POST'],'/auth/token'=>['POST'],'/me'=>['GET'],'/me/password'=>['POST'],'/templates'=>['GET'],'/services'=>['GET','POST'],'/subdomains/availability'=>['GET'],'/tokens'=>['GET','POST']];
        if(preg_match('~^/installations/[0-9a-fA-F-]{36}$~D',$route))$this->fail(405,'method_not_allowed','This method is unavailable.',['Allow'=>'GET']);
        $allow=$known[$route]??(preg_match('~^/services/[0-9a-fA-F-]{36}/subdomain$~D',$route)?['GET','POST']:(preg_match('~^/services/[0-9a-fA-F-]{36}$~D',$route)?['GET']:(preg_match('~^/tokens/[0-9a-fA-F-]{36}/rotate$~D',$route)?['POST']:(preg_match('~^/tokens/[0-9a-fA-F-]{36}$~D',$route)?['DELETE']:null))));
        if($allow)$this->fail(405,'method_not_allowed','This method is unavailable.',['Allow'=>implode(', ',$allow)]);
        $this->fail(404,'not_found','This API endpoint is unavailable.');
    }
}
