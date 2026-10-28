<?php
/** API ownership adapter for the existing signed, asynchronous domain worker. */
final class pbx_tenant_api_domains {
    private PDO $db;
    private const RESERVED = ['www','mail','smtp','imap','pop','ftp','cpcontacts','cpcalendars','webmail','cpanel','whm','autodiscover','autoconfig','domains','api','admin','portal','status','updates','releases','download','downloads','support','legal','privacy','terms','delete','ns','ns1','ns2','localhost','test','staging','dev','beta','call','pbx','acme'];

    public function __construct(PDO $db) { $this->db=$db; }

    public static function label(string $value): string {
        // Normalize neither URLs nor mixed-case aliases into a different name.
        if (!preg_match('/^[a-z0-9][a-z0-9-]{1,38}[a-z0-9]$/D',$value)
            || str_starts_with($value,'xn--') || in_array($value,self::RESERVED,true)) {
            throw new InvalidArgumentException('Choose an available subdomain of 3 to 40 lowercase letters, numbers and hyphens.');
        }
        return $value;
    }

    private function query(string $sql,array $values=[]): PDOStatement {
        $q=$this->db->prepare($sql);$q->execute($values);return $q;
    }

    private function owned(array $account,string $service,bool $lock=false): array {
        if (!is_uuid($service) || !is_uuid($account['tenant_uuid']??'') || !is_uuid($account['user_uuid']??'')) {
            throw new OutOfBoundsException('PBX service unavailable.');
        }
        $q=$this->query("select s.service_uuid,s.domain_uuid,s.tenant_uuid
            from v_pbx_services s join v_pbx_tenants t using(tenant_uuid)
            join v_domains d on d.domain_uuid=s.domain_uuid
            join v_users u on u.user_uuid=t.owner_user_uuid
            where s.service_uuid=? and s.tenant_uuid=? and u.user_uuid=?
              and t.enabled=true and u.user_enabled::text='true' and d.domain_enabled::text='true'
              and exists(select 1 from v_user_groups ug join v_groups g on g.group_uuid=ug.group_uuid
                where ug.user_uuid=u.user_uuid and g.group_name='tenant_admin' and g.domain_uuid is null)"
            .($lock?' for share of s,t,u,d':''),[$service,$account['tenant_uuid'],$account['user_uuid']]);
        $row=$q->fetch(PDO::FETCH_ASSOC);
        if (!$row) throw new OutOfBoundsException('PBX service unavailable.');
        return $row;
    }

    public function availability(string $label): array {
        $label=self::label($label);$host=$label.pbx_tenant_domains::SUFFIX;
        $used=$this->query('select exists(select 1 from v_pbx_tenant_domains where lower(requested_label)=? or lower(hostname)=?)
            or exists(select 1 from v_domains where lower(domain_name)=?)',[$label,$host,$host])->fetchColumn();
        return ['label'=>$label,'hostname'=>$host,'available'=>!in_array($used,[true,'t','1',1],true),
            'scope'=>'this_instance','reservation_confirmed'=>false];
    }

    /** Join service creation's transaction so workers never see an unassigned API service. */
    public function request(array $account,string $service,string $label): array {
        $label=self::label($label);$ownTransaction=!$this->db->inTransaction();
        if ($ownTransaction) $this->db->beginTransaction();
        try {
            // Serialize names and capacity without locking or altering existing leases.
            $this->query("select pg_advisory_xact_lock(hashtextextended('openweb-api-tenant-aliases',0))");
            $row=$this->owned($account,$service,true);
            $existing=$this->query('select requested_label,tenant_uuid,service_uuid from v_pbx_tenant_domains where domain_uuid=? for update',[$row['domain_uuid']])->fetch(PDO::FETCH_ASSOC);
            if ($existing) {
                if ($existing['tenant_uuid']!==$row['tenant_uuid'] || $existing['service_uuid']!==$service
                    || $existing['requested_label']!==$label) {
                    throw new DomainException('This PBX already has a reserved subdomain. Existing names cannot be renamed through the API.');
                }
            } else {
                if (!$this->availability($label)['available']) throw new DomainException('This subdomain is already reserved.');
                if ((int)$this->query('select count(*) from v_pbx_tenant_domains')->fetchColumn()>=50) {
                    throw new DomainException('This server has reached its managed-address limit. Contact the instance administrator.');
                }
                $this->query('insert into v_pbx_tenant_domains(domain_uuid,tenant_uuid,service_uuid,requested_label,desired_enabled)
                    values(?,?,?,?,true) on conflict(domain_uuid) do nothing',[$row['domain_uuid'],$row['tenant_uuid'],$service,$label]);
                // Discovery can race a legacy service. Refuse rather than replace its chosen name.
                $saved=$this->query('select requested_label,tenant_uuid,service_uuid from v_pbx_tenant_domains where domain_uuid=?',[$row['domain_uuid']])->fetch(PDO::FETCH_ASSOC);
                if (!$saved || $saved['requested_label']!==$label || $saved['tenant_uuid']!==$row['tenant_uuid'] || $saved['service_uuid']!==$service) {
                    throw new DomainException('This PBX already has a reserved subdomain. Existing names cannot be renamed through the API.');
                }
            }
            $result=$this->status($account,$service);
            if ($ownTransaction) $this->db->commit();
            return $result;
        } catch (Throwable $e) {
            if ($ownTransaction && $this->db->inTransaction()) $this->db->rollBack();
            throw $e;
        }
    }

    public function status(array $account,string $service): array {
        $row=$this->owned($account,$service);
        $alias=$this->query('select requested_label,hostname,state,next_attempt,error_category from v_pbx_tenant_domains
            where domain_uuid=? and tenant_uuid=? and service_uuid=?',[$row['domain_uuid'],$row['tenant_uuid'],$service])->fetch(PDO::FETCH_ASSOC);
        if (!$alias) return ['service_uuid'=>$service,'requested_label'=>null,'requested_hostname'=>null,'hostname'=>null,
            'url'=>null,'admin_url'=>null,'state'=>'not_requested','ready'=>false,'next_attempt'=>null,'error_category'=>''];
        $url=pbx_tenant_domains::url($this->db,$row['domain_uuid']);
        $ready=$alias['state']==='ready' && $url!==pbx_tenant_domains::instanceUrl();
        return ['service_uuid'=>$service,'requested_label'=>$alias['requested_label'],
            'requested_hostname'=>$alias['requested_label'].pbx_tenant_domains::SUFFIX,'hostname'=>$alias['hostname'],
            'url'=>$ready?$url:null,'admin_url'=>$ready?$url.'/admin':null,
            'state'=>$alias['state']==='ready'&&!$ready?'pending_tls':$alias['state'],'ready'=>$ready,
            'next_attempt'=>$alias['next_attempt'],'error_category'=>$alias['error_category']];
    }
}
