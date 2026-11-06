<?php
/** Revocable machine credentials, independent of phone passwords and QR setup. */
class pbx_api_access_denied extends DomainException {}
class pbx_api_rate_limited extends OverflowException {}
class pbx_access_keys {
    public const SCOPES=['pbx:read','pbx:write','calls:control','credentials:read','backups:read','backups:write','templates:read','templates:write','reseller:manage','keys:manage','system:manage'];
    private PDO $db;
    public function __construct(?PDO $db=null){$this->db=$db??database::new()->db;}
    private function q(string $sql,array $p=[]): PDOStatement {$s=$this->db->prepare($sql);$s->execute($p);return $s;}
    public function grant(string $user,string $permission): bool {
        return is_uuid($user)&&(bool)$this->q("select 1 from v_users u join v_user_groups ug on ug.user_uuid=u.user_uuid join v_group_permissions gp on gp.group_uuid=ug.group_uuid where u.user_uuid=? and u.user_enabled='true' and gp.permission_name=? and gp.permission_assigned='true' and (ug.domain_uuid is null or ug.domain_uuid=u.domain_uuid) and (gp.domain_uuid is null or gp.domain_uuid=u.domain_uuid) limit 1",[$user,$permission])->fetchColumn();
    }
    public function permissions(string $actor,string $domain): array {
        $p=$this->q("select distinct gp.permission_name from v_users u join v_user_groups ug on ug.user_uuid=u.user_uuid join v_group_permissions gp on gp.group_uuid=ug.group_uuid where u.user_uuid=? and u.user_enabled='true' and gp.permission_assigned='true' and (ug.domain_uuid is null or ug.domain_uuid=u.domain_uuid or ug.domain_uuid=?) and (gp.domain_uuid is null or gp.domain_uuid=?)",[$actor,$domain,$domain])->fetchAll(PDO::FETCH_COLUMN);
        return array_fill_keys($p,1);
    }
    private function actor(): string {$id=$_SESSION['user_uuid']??'';if(empty($_SESSION['authorized'])||!is_string($id)||!$this->grant($id,'pbx_api_key_manage'))throw new pbx_api_access_denied('API key administrator access is required.');return $id;}
    public function instance(string $actor): bool {return $this->grant($actor,'pbx_tenant_manage');}
    public function domainAdmin(string $actor,string $domain): bool {
        return is_uuid($domain)&&$this->grant($actor,'pbx_api_key_manage')&&$this->grant($actor,'extension_edit')&&$this->grant($actor,'gateway_edit')&&(bool)$this->q("select 1 from v_users u join v_domains d on d.domain_uuid=u.domain_uuid where u.user_uuid=? and u.domain_uuid=? and u.user_enabled='true' and d.domain_enabled and not exists(select 1 from v_pbx_services s join v_pbx_tenants t using(tenant_uuid) where s.domain_uuid=d.domain_uuid and not t.enabled)",[$actor,$domain])->fetchColumn();
    }
    private function resellerParent(string $actor): bool {
        return $this->grant($actor,'pbx_reseller_manage')&&(bool)$this->q('select 1 from v_pbx_tenants where owner_user_uuid=? and enabled limit 1',[$actor])->fetchColumn();
    }
    public function tenantOwned(string $actor,string $tenant): bool {
        $reseller=$this->resellerParent($actor);
        return is_uuid($tenant)&&(bool)$this->q('select 1 from v_pbx_tenants where tenant_uuid=? and enabled and (owner_user_uuid=?'.($reseller?' or reseller_user_uuid=?':'').')',$reseller?[$tenant,$actor,$actor]:[$tenant,$actor])->fetchColumn();
    }
    public function choices(): array {
        $actor=$this->actor();$instance=$this->instance($actor);$own=$this->q('select domain_uuid from v_users where user_uuid=?',[$actor])->fetchColumn();$admin=$this->domainAdmin($actor,(string)$own);$reseller=$this->resellerParent($actor);
        $tp=[];$tf='';$sp=[];$sf='';
        if(!$instance){$tf=' and (owner_user_uuid=?';$tp[]=$actor;$sf=' and (t.owner_user_uuid=?';$sp[]=$actor;if($reseller){$tf.=' or reseller_user_uuid=?';$tp[]=$actor;$sf.=' or t.reseller_user_uuid=?';$sp[]=$actor;}if($admin){$tf.=' or exists(select 1 from v_pbx_services s where s.tenant_uuid=v_pbx_tenants.tenant_uuid and s.domain_uuid=?)';$tp[]=$own;$sf.=' or d.domain_uuid=?';$sp[]=$own;}$tf.=')';$sf.=')';}
        $tenants=$this->q('select tenant_uuid,tenant_name from v_pbx_tenants where enabled'.$tf.' order by tenant_name',$tp)->fetchAll(PDO::FETCH_ASSOC);
        $services=$this->q('select d.domain_uuid,s.tenant_uuid,coalesce(s.service_name,d.domain_name) service_name,d.domain_name from v_domains d left join v_pbx_services s using(domain_uuid) left join v_pbx_tenants t using(tenant_uuid) where d.domain_enabled and (t.tenant_uuid is null or t.enabled)'.$sf.' order by service_name',$sp)->fetchAll(PDO::FETCH_ASSOC);
        return ['instance'=>$instance,'reseller'=>$instance?$this->grant($actor,'pbx_reseller_manage'):$reseller,'tenants'=>$tenants,'services'=>$services,'domain_admin'=>$admin,'default_domain'=>!$instance&&$admin&&!$this->q('select 1 from v_pbx_tenants where owner_user_uuid=? and enabled',[$actor])->fetchColumn()?$own:''];
    }
    public function listing(): array {
        $id=$this->actor();return $this->q("with recursive selected as (select * from v_pbx_access_keys where owner_user_uuid=? order by created_at desc limit 500), chain as (select key_uuid origin,key_uuid,parent_key_uuid,revoked_at is null and expires_at>now() active,1 depth from selected union all select c.origin,p.key_uuid,p.parent_key_uuid,p.revoked_at is null and p.expires_at>now(),c.depth+1 from v_pbx_access_keys p join chain c on p.key_uuid=c.parent_key_uuid where c.depth<33), state as (select origin,bool_and(active) and bool_or(parent_key_uuid is null) and max(depth)<=32 effective_active from chain group by origin) select k.key_uuid,k.key_name,k.prefix,k.tenant_uuid,k.domain_uuid,k.scopes,k.expires_at,k.revoked_at,k.last_used_at,k.last_used_ip,k.created_at,k.parent_key_uuid,s.effective_active from selected k join state s on s.origin=k.key_uuid order by k.created_at desc",[$id])->fetchAll(PDO::FETCH_ASSOC);
    }
    private function chainDepth(string $id): int {
        $r=$this->q("with recursive chain as (select key_uuid,parent_key_uuid,revoked_at is null and expires_at>now() active,1 depth from v_pbx_access_keys where key_uuid=? union all select p.key_uuid,p.parent_key_uuid,p.revoked_at is null and p.expires_at>now(),c.depth+1 from v_pbx_access_keys p join chain c on p.key_uuid=c.parent_key_uuid where c.depth<33) select bool_and(active) and bool_or(parent_key_uuid is null) and max(depth)<=32 valid,max(depth) depth from chain",[$id])->fetch(PDO::FETCH_ASSOC);return $r&&filter_var($r['valid'],FILTER_VALIDATE_BOOLEAN)?(int)$r['depth']:0;
    }
    public function delegate(array $in,string $parent): array {
        $actor=$this->actor();if(!is_uuid($parent))throw new pbx_api_access_denied('Parent key unavailable.');$this->db->beginTransaction();
        try {$p=$this->q('select * from v_pbx_access_keys where key_uuid=? and owner_user_uuid=? for update',[$parent,$actor])->fetch(PDO::FETCH_ASSOC);$depth=$p?$this->chainDepth($parent):0;if(!$depth||$depth>=32)throw new pbx_api_access_denied('Parent key unavailable or delegation depth reached.');$scopes=$in['scopes']??[];if(!is_array($scopes)||!array_is_list($scopes)||array_filter($scopes,static fn($s)=>!is_string($s))||array_diff($scopes,json_decode($p['scopes'],true,16,JSON_THROW_ON_ERROR)))throw new pbx_api_access_denied('A key cannot delegate greater permissions.');$in['tenant_uuid']=$p['tenant_uuid'];$in['domain_uuid']=$p['domain_uuid'];$out=$this->create($in);$this->q('update v_pbx_access_keys set expires_at=least(expires_at,?::timestamptz),parent_key_uuid=? where key_uuid=?',[$p['expires_at'],$parent,$out['key_uuid']]);$this->db->commit();return $out;}catch(Throwable $e){if($this->db->inTransaction())$this->db->rollBack();throw $e;}
    }
    public function create(array $in): array {
        $actor=$this->actor();$name=$in['name']??'';$scopes=$in['scopes']??[];
        if(!is_string($name)||trim($name)===''||mb_strlen($name)>100||preg_match('/[\x00-\x1f\x7f]/',$name)||!is_array($scopes)||!array_is_list($scopes)||!$scopes||count($scopes)>count(self::SCOPES))throw new InvalidArgumentException('Choose a name and API permissions.');
        foreach($scopes as $scope)if(!is_string($scope)||!in_array($scope,self::SCOPES,true))throw new InvalidArgumentException('Choose valid API permissions.');
        $days=filter_var($in['days']??90,FILTER_VALIDATE_INT,['options'=>['min_range'=>1,'max_range'=>365]]);if($days===false||is_bool($in['days']??null))throw new InvalidArgumentException('Choose an expiry of 1 to 365 days.');
        $tenant=$in['tenant_uuid']??null;$domain=$in['domain_uuid']??null;$platform=$this->instance($actor);
        foreach([$tenant,$domain] as $id)if($id!==null&&(!is_string($id)||($id!==''&&!is_uuid($id))))throw new InvalidArgumentException('Choose a tenant and PBX.');
        $domainAdmin=is_string($domain)&&$domain!==''&&$this->domainAdmin($actor,$domain);
        if($tenant!==null&&$tenant!==''&&!($this->tenantOwned($actor,$tenant)||$platform||$domainAdmin))throw new pbx_api_access_denied('Choose your own tenant.');
        if(!$tenant){$tenant=null;if(!$platform&&!$domainAdmin)throw new pbx_api_access_denied('Choose your tenant workspace or own PBX.');}
        elseif(!$this->q('select 1 from v_pbx_tenants where tenant_uuid=? and enabled',[$tenant])->fetchColumn())throw new pbx_api_access_denied('Tenant unavailable.');
        if(in_array('system:manage',$scopes,true)&&(!$platform||$tenant))throw new pbx_api_access_denied('System access requires an instance-wide administrator key.');
        if(in_array('reseller:manage',$scopes,true)&&!$this->grant($actor,'pbx_reseller_manage'))throw new pbx_api_access_denied('Reseller permission cannot be delegated by this account.');
        if($domain){if(!($domainAdmin&&!$tenant)&&(!$tenant||!$this->q('select 1 from v_pbx_services s join v_domains d using(domain_uuid) where s.tenant_uuid=? and s.domain_uuid=? and d.domain_enabled',[$tenant,$domain])->fetchColumn()))throw new pbx_api_access_denied('Choose a PBX belonging to this tenant.');}else $domain=null;
        $own=!$this->db->inTransaction();if($own)$this->db->beginTransaction();
        try {
            $this->q("select pg_advisory_xact_lock(hashtextextended('api-keys:'||?::text,0))",[$actor]);
            if((int)$this->q('select count(*) from v_pbx_access_keys where owner_user_uuid=? and revoked_at is null and expires_at>now()',[$actor])->fetchColumn()>=200)throw new OverflowException('Revoke an unused API key before creating another.');
            $id=uuid();$token='owpbx_'.str_replace('-','',$id).'_'.bin2hex(random_bytes(32));$prefix=substr($token,0,15);
            $this->q('insert into v_pbx_access_keys(key_uuid,owner_user_uuid,tenant_uuid,domain_uuid,key_name,token_hash,prefix,scopes,expires_at) values(?,?,?,?,?,?,?,?::jsonb,now()+make_interval(days=>?))',[$id,$actor,$tenant,$domain,trim($name),hash('sha256',$token),$prefix,json_encode(array_values(array_unique($scopes)),JSON_THROW_ON_ERROR),$days]);
            if($own)$this->db->commit();
            return ['key_uuid'=>$id,'token'=>$token,'name'=>trim($name),'prefix'=>$prefix,'message'=>'Save this key now. It will not be displayed again.'];
        }catch(Throwable $e){if($own&&$this->db->inTransaction())$this->db->rollBack();throw $e;}
    }
    public function revoke(string $id): void {$actor=$this->actor();if(!is_uuid($id)||!$this->q('update v_pbx_access_keys set revoked_at=coalesce(revoked_at,now()) where key_uuid=? and owner_user_uuid=? returning key_uuid',[$id,$actor])->fetchColumn())throw new OutOfBoundsException('API key unavailable.');}
    public function rotate(string $id): array {
        $actor=$this->actor();if(!is_uuid($id))throw new InvalidArgumentException('Choose an API key.');if(!$this->chainDepth($id))throw new OutOfBoundsException('API key unavailable.');$this->db->beginTransaction();
        try {$old=$this->q('select *,greatest(1,least(365,ceil(extract(epoch from (expires_at-now()))/86400))) days from v_pbx_access_keys where key_uuid=? and owner_user_uuid=? and revoked_at is null and expires_at>now() for update',[$id,$actor])->fetch(PDO::FETCH_ASSOC);if(!$old)throw new OutOfBoundsException('API key unavailable.');$this->revoke($id);$out=$this->create(['name'=>$old['key_name'],'scopes'=>json_decode($old['scopes'],true,16,JSON_THROW_ON_ERROR),'days'=>(int)$old['days'],'tenant_uuid'=>$old['tenant_uuid'],'domain_uuid'=>$old['domain_uuid']]);$this->q('update v_pbx_access_keys set expires_at=?,parent_key_uuid=? where key_uuid=?',[$old['expires_at'],$old['parent_key_uuid'],$out['key_uuid']]);$this->db->commit();return $out;}catch(Throwable $e){if($this->db->inTransaction())$this->db->rollBack();throw $e;}
    }
    public function authenticate(string $authorization,string $ip,bool $recordUsage=true): array {
        if(!preg_match('/^Bearer (owpbx_[a-f0-9]{32}_[a-f0-9]{64})$/D',$authorization,$m))throw new pbx_api_access_denied('A valid API key is required.');
        $row=$this->q("select k.*,u.domain_uuid owner_domain_uuid from v_pbx_access_keys k join v_users u on u.user_uuid=k.owner_user_uuid where token_hash=? and revoked_at is null and expires_at>now() and u.user_enabled='true'",[hash('sha256',$m[1])])->fetch(PDO::FETCH_ASSOC);
        if(!$row||!$this->chainDepth($row['key_uuid'])||!$this->grant($row['owner_user_uuid'],'pbx_api_key_manage'))throw new pbx_api_access_denied('This API key has expired or is no longer available.');
        $platform=$this->instance($row['owner_user_uuid']);
        if($row['tenant_uuid']) {
            if(!$this->q('select 1 from v_pbx_tenants where tenant_uuid=? and enabled',[$row['tenant_uuid']])->fetchColumn()||(!$platform&&!$this->tenantOwned($row['owner_user_uuid'],$row['tenant_uuid'])&&!($row['domain_uuid']&&$this->domainAdmin($row['owner_user_uuid'],$row['domain_uuid']))))throw new pbx_api_access_denied('Tenant access has been withdrawn.');
            if($row['domain_uuid']&&!$this->q('select 1 from v_pbx_services s join v_domains d using(domain_uuid) where s.tenant_uuid=? and s.domain_uuid=? and d.domain_enabled',[$row['tenant_uuid'],$row['domain_uuid']])->fetchColumn())throw new pbx_api_access_denied('PBX access has been withdrawn.');
        }elseif(!$platform&&!($row['domain_uuid']&&$this->domainAdmin($row['owner_user_uuid'],$row['domain_uuid'])))throw new pbx_api_access_denied('PBX access has been withdrawn.');
        if($recordUsage) {
            $count=$this->q("update v_pbx_access_keys set last_used_at=now(),last_used_ip=?::inet,request_count=case when request_window<date_trunc('minute',now()) then 1 else request_count+1 end,request_window=date_trunc('minute',now()) where key_uuid=? returning request_count",[filter_var($ip,FILTER_VALIDATE_IP)?$ip:null,$row['key_uuid']])->fetchColumn();
            if((int)$count>120)throw new pbx_api_rate_limited('This key has reached 120 requests per minute. Try again shortly.');
        }elseif($this->q("select 1 from v_pbx_access_keys where key_uuid=? and request_window>=date_trunc('minute',now()) and request_count>=120",[$row['key_uuid']])->fetchColumn())throw new pbx_api_rate_limited('This key has reached 120 requests per minute. Try again shortly.');
        $row['scopes']=json_decode($row['scopes'],true,16,JSON_THROW_ON_ERROR);$row['instance']=$platform&&!$row['tenant_uuid']&&!$row['domain_uuid'];unset($row['token_hash']);return $row;
    }
}
