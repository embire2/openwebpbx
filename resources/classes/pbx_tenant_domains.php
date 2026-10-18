<?php
/** Tenant HTTPS aliases. Never replace SIP realms, extension authentication or host trust. */
class pbx_tenant_domains {
    public const BROKER='https://domains.openwebpbx.com';
    public const SUFFIX='.openwebpbx.com';
    public static function installed(PDO $db): bool {return (bool)$db->query("select to_regclass('v_pbx_tenant_domains')")->fetchColumn();}
    public static function hostname(string $host): string {
        $host=strtolower($host);
        if(str_ends_with($host,':443'))$host=substr($host,0,-4);
        if(strlen($host)>253||!preg_match('/^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?(?:\.[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?)+$/D',$host))return '';
        return $host;
    }
    public static function instanceUrl(): string {
        $host=self::hostname(pbx_paths::host());
        if($host===''||$host!==pbx_paths::host())throw new RuntimeException('The installed public hostname needs review.');
        return 'https://'.$host;
    }
    private static function transportReady(string $host,string $keyHash,string $serverHost): bool {
        $path=pbx_paths::state().'/tenant-domains/ready.json';
        for($p=$path;;$p=dirname($p)){if(is_link($p))return false;if($p===dirname($p))break;}
        if(!is_file($path)||filesize($path)>16384)return false;
        if(PHP_OS_FAMILY!=='Windows'&&(fileowner($path)!==0||(fileperms($path)&0022)!==0))return false;
        try{$value=json_decode(file_get_contents($path),true,6,JSON_THROW_ON_ERROR);}catch(Throwable $e){return false;}
        return ($value['schema']??null)===1&&($value['server_host']??'')===$serverHost&&($value['key_hash']??'')===$keyHash&&is_string($value['aliases'][$host]??null)&&strtotime($value['aliases'][$host])>time();
    }
    public static function requestDomain(PDO $db,?array $server=null): string {
        $host=self::hostname((string)(($server??$_SERVER)['HTTP_HOST']??''));
        if($host===''||$host===self::hostname(pbx_paths::host())||!str_ends_with($host,self::SUFFIX)||!self::installed($db))return '';
        $q=$db->prepare("select a.domain_uuid,a.key_hash,a.server_host from v_pbx_tenant_domains a join v_domains d on d.domain_uuid=a.domain_uuid join v_pbx_services s on s.domain_uuid=a.domain_uuid and s.service_uuid=a.service_uuid and s.tenant_uuid=a.tenant_uuid join v_pbx_tenants t on t.tenant_uuid=a.tenant_uuid where a.hostname=? and a.state='ready' and a.desired_enabled and a.certificate_not_after>now() and d.domain_enabled='true' and t.enabled=true");
        $q->execute([$host]);$rows=$q->fetchAll(PDO::FETCH_ASSOC);return count($rows)===1&&$rows[0]['server_host']===self::hostname(pbx_paths::host())&&self::transportReady($host,$rows[0]['key_hash'],$rows[0]['server_host'])?$rows[0]['domain_uuid']:'';
    }
    public static function url(PDO $db,string $domainUuid): string {
        if(!preg_match('/^[0-9a-f-]{36}$/D',$domainUuid)||!self::installed($db))return self::instanceUrl();
        $q=$db->prepare("select hostname from v_pbx_tenant_domains where domain_uuid=? and state='ready' and desired_enabled and certificate_not_after>now()");$q->execute([$domainUuid]);$host=$q->fetchColumn();
        if(!is_string($host)||self::hostname($host)!==$host||!str_ends_with($host,self::SUFFIX)||self::requestDomain($db,['HTTP_HOST'=>$host])!==$domainUuid)return self::instanceUrl();
        return 'https://'.$host;
    }
    public static function status(PDO $db,string $domainUuid): array {
        $url=self::url($db,$domainUuid);$ready=$url!==self::instanceUrl();
        return ['ready'=>$ready,'url'=>$url,'message'=>$ready?'Tenant address ready':'Tenant address is being prepared. The installation address remains available; pending setup retries automatically.'];
    }
    /** After switchService's normal permission check; never transports a login. */
    public static function serviceDesktopUrl(PDO $db,string $domainUuid,?array $server=null): string {
        return self::requestDomain($db,$server)===''?'/core/desktop/':self::url($db,$domainUuid).'/core/desktop/';
    }
    /** Called before normal domain discovery/settings. Shared-host behavior stays unchanged. */
    public static function guardRequest(PDO $db,?array $server=null): void {
        $server??=$_SERVER;$raw=(string)($server['HTTP_HOST']??'');$host=self::hostname($raw);
        $claimed=rtrim(trim(strtolower(preg_replace('/:[^:]*$/','',$raw))),'.');
        if($host===''&&str_ends_with($claimed,self::SUFFIX))throw new RuntimeException('Use the tenant address over its standard HTTPS port.');
        if($host===self::hostname(pbx_paths::host())||!str_ends_with($host,self::SUFFIX))return;
        $domain=self::requestDomain($db,$server);if($domain==='')throw new RuntimeException('This tenant address is unavailable. Use the installation address while setup is pending.');
        if(($_GET['domain_change']??'')==='true'&&($_GET['domain_uuid']??'')!==$domain)throw new RuntimeException('This address belongs to a different PBX service.');
        if(!empty($_SESSION['authorized'])) {
            $q=$db->prepare("select u.user_uuid from v_users u join v_user_groups g on g.user_uuid=u.user_uuid and g.group_name='tenant_admin' join v_pbx_tenants t on t.tenant_uuid=(select tenant_uuid from v_pbx_tenant_domains where domain_uuid=?) where u.user_uuid=? and u.user_enabled='true' and t.enabled and (t.owner_user_uuid=u.user_uuid or u.domain_uuid=?) limit 1");$q->execute([$domain,$_SESSION['user_uuid']??'',$domain]);
            if(!$q->fetchColumn())throw new RuntimeException('Use the installation address for platform administration. Tenant administration requires the assigned tenant account.');
        }
        $q=$db->prepare('select domain_name from v_domains where domain_uuid=?');$q->execute([$domain]);$realm=$q->fetchColumn();
        $_SESSION['domain_uuid']=$domain;$_SESSION['domain_name']=$realm;$_SESSION['context']=$realm;
        // This context is not authentication and grants no permission or admin role.
        $_SESSION['openweb_tenant_domain']=$domain;
    }
    /** Worker discovery is local and transactional; no network/DNS call occurs in a form save. */
    public static function discover(PDO $db): array {
        if(!self::installed($db))return [];
        $rows=$db->query("select s.domain_uuid,s.tenant_uuid,s.service_uuid,t.slug,(t.enabled and d.domain_enabled='true') desired_enabled,row_number()over(partition by s.tenant_uuid order by s.created_at,s.service_uuid) ordinal from v_pbx_services s join v_pbx_tenants t using(tenant_uuid) join v_domains d using(domain_uuid)")->fetchAll(PDO::FETCH_ASSOC);
        foreach($rows as $r){$slug=strtolower($r['slug']);if(!preg_match('/^[a-z0-9][a-z0-9-]{1,46}[a-z0-9]$/D',$slug))$slug='tenant-'.substr(str_replace('-','',$r['tenant_uuid']),0,12);if((int)$r['ordinal']>1)$slug=substr($slug,0,36).'-'.substr(str_replace('-','',$r['service_uuid']),0,10);
            $q=$db->prepare("insert into v_pbx_tenant_domains(domain_uuid,tenant_uuid,service_uuid,requested_label,desired_enabled)values(?,?,?,?,?) on conflict(domain_uuid)do update set desired_enabled=excluded.desired_enabled where v_pbx_tenant_domains.tenant_uuid=excluded.tenant_uuid and v_pbx_tenant_domains.service_uuid=excluded.service_uuid");$q->bindValue(1,$r['domain_uuid']);$q->bindValue(2,$r['tenant_uuid']);$q->bindValue(3,$r['service_uuid']);$q->bindValue(4,$slug);$q->bindValue(5,in_array($r['desired_enabled'],[true,'t','1',1],true),PDO::PARAM_BOOL);$q->execute();}
        $db->exec('update v_pbx_tenant_domains a set desired_enabled=false where not exists(select 1 from v_pbx_services s where s.service_uuid=a.service_uuid and s.domain_uuid=a.domain_uuid and s.tenant_uuid=a.tenant_uuid)');
        return $db->query('select * from v_pbx_tenant_domains where next_attempt<=now() order by updated_at,domain_uuid limit 50')->fetchAll(PDO::FETCH_ASSOC);
    }
    public static function record(PDO $db,array $value): void {
        $keys=['domain_uuid','hostname','server_host','key_hash','revision','state','error_category','certificate_not_after','retry_seconds'];sort($keys);$actual=array_keys($value);sort($actual);if($actual!==$keys)throw new InvalidArgumentException('Invalid tenant address worker result.');
        if(!preg_match('/^[0-9a-f-]{36}$/D',$value['domain_uuid'])||!preg_match('/^[0-9a-f]{64}$/D',$value['key_hash'])||!is_int($value['revision'])||$value['revision']<0||!is_int($value['retry_seconds'])||$value['retry_seconds']<60||$value['retry_seconds']>604800||!in_array($value['state'],['pending_dns','pending_tls','ready','disabled','retry','conflict'],true)||!in_array($value['error_category'],['','network','broker_pending','revision_conflict','dns_conflict','certificate_pending','rate_limited','local_configuration'],true))throw new InvalidArgumentException('Invalid tenant address worker result.');
        if($value['server_host']!==self::hostname(pbx_paths::host())||($value['hostname']!==null&&(self::hostname($value['hostname'])!==$value['hostname']||!preg_match('/^[a-z0-9][a-z0-9-]{1,61}[a-z0-9]\.openwebpbx\.com$/D',$value['hostname']))))throw new InvalidArgumentException('Invalid tenant address hostname.');
        if($value['state']==='ready'&&($value['hostname']===null||!is_string($value['certificate_not_after'])||strtotime($value['certificate_not_after'])<=time()||strtotime($value['certificate_not_after'])>time()+400*86400))throw new InvalidArgumentException('A valid tenant certificate is required.');
        $q=$db->prepare("update v_pbx_tenant_domains set hostname=?,server_host=?,key_hash=?,revision=?,state=?,error_category=?,certificate_not_after=?,next_attempt=now()+(? * interval '1 second'),updated_at=now() where domain_uuid=? and (key_hash='' or key_hash=?) and revision<=?");
        $q->execute([$value['hostname'],$value['server_host'],$value['key_hash'],$value['revision'],$value['state'],$value['error_category'],$value['certificate_not_after'],$value['retry_seconds'],$value['domain_uuid'],$value['key_hash'],$value['revision']]);if($q->rowCount()!==1)throw new RuntimeException('Tenant address ownership or revision changed.');
    }
}
