<?php
/** Exact, owned phone addresses. Existing routing/media/app realm never changes. */
class pbx_sip_domains {
    protected PDO $db;
    private string $domain;
    protected function tenantManager(): pbx_tenants {return new pbx_tenants($this->db);}
    protected function setupManager(): pbx_setup {return new pbx_setup($this->db);}
    public function __construct(?PDO $db=null){
        $this->db=$db??database::new()->db;$this->domain=$_SESSION['domain_uuid']??'';
        if(!is_uuid($this->domain)||!$this->setupManager()->canManage()||!$this->tenantManager()->canDomain($this->domain))throw new RuntimeException('PBX administrator access required.');
    }
    private function query(string $sql,array $parameters=[]): PDOStatement {$s=$this->db->prepare($sql);$s->execute($parameters);return $s;}
    public function addresses(): array {return $this->query('select sip_domain,enabled from v_pbx_sip_domains where domain_uuid=:d order by created_at,sip_domain',['d'=>$this->domain])->fetchAll(PDO::FETCH_ASSOC);}
    public function primary(): string {
        $raw=$this->query('select config from v_pbx_restore where domain_uuid=:d',['d'=>$this->domain])->fetchColumn();
        if(!$raw)throw new RuntimeException('Choose a configured PBX first.');
        $config=json_decode($raw,true,512,JSON_THROW_ON_ERROR);$canonical=$config['realm'];$selected=$config['phone_domain']??$canonical;
        if($selected===$canonical)return $canonical;
        return $this->query('select 1 from v_pbx_sip_domains where sip_domain=:name and domain_uuid=:d and enabled=true',['name'=>$selected,'d'=>$this->domain])->fetchColumn()?$selected:$canonical;
    }
    public function readiness(): array {
        $name=$this->primary();$addresses=gethostbynamel($name)?:[];
        $expected=pbx_paths::address();$expected=filter_var($expected,FILTER_VALIDATE_IP,FILTER_FLAG_IPV4)?[$expected]:(gethostbynamel($expected)?:[]);
        $names=array_filter(explode(',',(string)config::load()->get('openweb.sip_tls_names','')));
        return ['name'=>$name,'dns'=>count(array_intersect($addresses,$expected))>0,'tls'=>filter_var(config::load()->get('openweb.mobile_tls_ready','false'),FILTER_VALIDATE_BOOLEAN)&&pbx_sip_domain::certificateCovers($name,$names)];
    }
    public function save(array $input): string {
        $name=pbx_sip_domain::validate($input['sip_domain']??'');if($name==='')throw new InvalidArgumentException('Enter the new phone domain.');
        if($this->db->inTransaction())throw new LogicException('Phone-domain changes require their own transaction.');
        $this->db->beginTransaction();
        try {
            $raw=$this->query('select r.config from v_pbx_restore r join v_domains d using(domain_uuid) where r.domain_uuid=:d and d.domain_enabled=true for update of r',['d'=>$this->domain])->fetchColumn();if(!$raw)throw new RuntimeException('Choose a configured PBX first.');$config=json_decode($raw,true,512,JSON_THROW_ON_ERROR);
            $this->query('select pg_advisory_xact_lock(hashtextextended(:realm,0))',['realm'=>$name]);
            if($this->query('select 1 from v_domains where lower(domain_name)=:name and domain_uuid<>:d',['name'=>$name,'d'=>$this->domain])->fetchColumn()||$this->query('select 1 from v_pbx_sip_domains where sip_domain=:name and domain_uuid<>:d',['name'=>$name,'d'=>$this->domain])->fetchColumn())throw new InvalidArgumentException('This phone domain belongs to another PBX.');
            if($name!==$config['realm']){
                $exists=$this->query('select 1 from v_pbx_sip_domains where sip_domain=:name and domain_uuid=:d',['name'=>$name,'d'=>$this->domain])->fetchColumn();
                if(!$exists&&count($this->addresses())>=3)throw new InvalidArgumentException('Use up to three public phone domains per PBX.');
                $this->query('insert into v_pbx_sip_domains(sip_domain,domain_uuid,enabled,created_by) values(:name,:d,true,:u) on conflict(sip_domain) do update set enabled=true where v_pbx_sip_domains.domain_uuid=excluded.domain_uuid',['name'=>$name,'d'=>$this->domain,'u'=>$_SESSION['user_uuid']]);
            }
            $config['sip_domains']=array_column(array_filter($this->addresses(),static fn($r)=>filter_var($r['enabled'],FILTER_VALIDATE_BOOLEAN)),'sip_domain');$config['phone_domain']=$name;
            $this->query('update v_pbx_restore set config=cast(:c as jsonb) where domain_uuid=:d',['c'=>json_encode($config,JSON_THROW_ON_ERROR),'d'=>$this->domain]);$this->db->commit();
        }catch(Throwable $e){if($this->db->inTransaction())$this->db->rollBack();throw $e;}
        $cache=new cache;foreach(array_unique(array_merge([$config['realm']],$config['sip_domains'])) as $realm)foreach($config['users'] as $number=>$user){$cache->delete('directory:'.$user['auth_id'].'@'.$realm);$cache->delete('directory:'.$number.'@'.$realm);}settings::clear_cache();
        return $name;
    }
    public function disable(array $input): void {
        $name=pbx_sip_domain::validate($input['sip_domain']??'');if($name==='')throw new InvalidArgumentException('Choose a phone domain.');
        if($this->db->inTransaction())throw new LogicException('Phone-domain changes require their own transaction.');
        $this->db->beginTransaction();
        try{
            $raw=$this->query('select config from v_pbx_restore where domain_uuid=:d for update',['d'=>$this->domain])->fetchColumn();if(!$raw)throw new RuntimeException('Choose a configured PBX first.');$config=json_decode($raw,true,512,JSON_THROW_ON_ERROR);
            $updated=$this->query('update v_pbx_sip_domains set enabled=false where sip_domain=:name and domain_uuid=:d returning sip_domain',['name'=>$name,'d'=>$this->domain])->fetchColumn();if(!$updated)throw new InvalidArgumentException('This phone domain is not in your PBX.');
            $config['sip_domains']=array_column(array_filter($this->addresses(),static fn($r)=>filter_var($r['enabled'],FILTER_VALIDATE_BOOLEAN)),'sip_domain');
            if(($config['phone_domain']??'')===$name)$config['phone_domain']=$config['realm'];
            $this->query('update v_pbx_restore set config=cast(:c as jsonb) where domain_uuid=:d',['c'=>json_encode($config,JSON_THROW_ON_ERROR),'d'=>$this->domain]);$this->db->commit();
        }catch(Throwable $e){if($this->db->inTransaction())$this->db->rollBack();throw $e;}
        $cache=new cache;foreach($config['users'] as $number=>$user){$cache->delete('directory:'.$user['auth_id'].'@'.$name);$cache->delete('directory:'.$number.'@'.$name);}settings::clear_cache();
    }
}
