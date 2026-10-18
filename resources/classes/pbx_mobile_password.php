<?php
/** Extension app passwords. Never read, replace or derive the original SIP password. */
final class pbx_mobile_password {
    private const OPTIONS=['memory_cost'=>65536,'time_cost'=>2,'threads'=>1];
    private const DUMMY='$argon2id$v=19$m=65536,t=2,p=1$WDFZZ1MwUTlsSzNNVGF4aQ$B25SIpDuXKXb3HsarRUAekn1S5lhx+ETpvNrmTn5bwE';
    public function __construct(private PDO $db) {}
    private function q(string $sql,array $args=[]): PDOStatement {$s=$this->db->prepare($sql);$s->execute($args);return $s;}
    private static function valid(mixed $password): bool {return is_string($password)&&strlen($password)<=512&&mb_check_encoding($password,'UTF-8')&&mb_strlen($password,'UTF-8')>=12&&mb_strlen($password,'UTF-8')<=128&&!preg_match('/[\x00-\x1f\x7f]/',$password);}
    public static function validate(mixed $password): string {
        if(!self::valid($password))throw new InvalidArgumentException('Use an app password with 12 to 128 characters, without line breaks.');
        return $password;
    }
    /** One expensive verification also runs for unknown, disabled and wrong-tenant accounts. */
    public function verify(string $domain,string $number,mixed $password): array {
        $valid=self::valid($password);
        $rows=[];
        if(is_uuid($domain)&&preg_match('/^[0-9]{2,10}$/D',$number))$rows=$this->q("select a.extension_uuid,a.domain_uuid,a.password_hash,a.generation from v_pbx_mobile_accounts a join v_extensions e on e.extension_uuid=a.extension_uuid and e.domain_uuid=a.domain_uuid join v_domains d on d.domain_uuid=a.domain_uuid join v_pbx_restore r on r.domain_uuid=a.domain_uuid cross join lateral jsonb_each(r.config->'users') u where a.domain_uuid=? and u.key=? and u.value->>'extension_uuid'=a.extension_uuid::text and e.enabled='true' and d.domain_enabled='true' and u.value->>'enabled'='true' and u.value->>'auth_id'=e.extension and r.config->>'realm'=d.domain_name and not exists(select 1 from v_pbx_services s join v_pbx_tenants t using(tenant_uuid) where s.domain_uuid=d.domain_uuid and not t.enabled)",[$domain,$number])->fetchAll(PDO::FETCH_ASSOC);
        $row=count($rows)===1?$rows[0]:null;
        $match=password_verify($valid?$password:'invalid-input-work-factor',$row['password_hash']??self::DUMMY);
        if(!$valid||!$row||!$match)throw new UnexpectedValueException('The extension or app password is incorrect.');
        unset($row['password_hash']);return $row;
    }
    public function present(string $domain,string $extension): bool {return (bool)$this->q('select 1 from v_pbx_mobile_accounts where domain_uuid=? and extension_uuid=?',[$domain,$extension])->fetchColumn();}
    /** Called under the administrator's existing scoped user-save transaction. */
    public function set(string $domain,string $extension,mixed $password,?string $actor=null,?string $keepDevice=null): array {
        if(!$this->db->inTransaction())throw new LogicException('Save app passwords inside the scoped user transaction.');
        $password=self::validate($password);
        if(!is_uuid($domain)||!is_uuid($extension)||!$this->q('select 1 from v_extensions where domain_uuid=? and extension_uuid=? for update',[$domain,$extension])->fetchColumn())throw new InvalidArgumentException('Choose a user in this PBX.');
        if($keepDevice!==null&&(!is_uuid($keepDevice)||!$this->q('select 1 from v_pbx_mobile_devices where device_uuid=? and domain_uuid=? and extension_uuid=? and revoked_at is null and expires_at>now() for update',[$keepDevice,$domain,$extension])->fetchColumn()))throw new UnexpectedValueException('Connect your phone again.');
        $hash=password_hash($password,PASSWORD_ARGON2ID,self::OPTIONS);
        $saved=$this->q('insert into v_pbx_mobile_accounts(extension_uuid,domain_uuid,password_hash,updated_by) values(?,?,?,?) on conflict(extension_uuid)do update set password_hash=excluded.password_hash,generation=v_pbx_mobile_accounts.generation+1,updated_at=now(),updated_by=excluded.updated_by where v_pbx_mobile_accounts.domain_uuid=excluded.domain_uuid',[$extension,$domain,$hash,is_uuid($actor??'')?$actor:null]);
        if($saved->rowCount()!==1)throw new RuntimeException('App-password ownership needs review.');
        $this->q("update v_email_queue q set email_status='cancelled',update_date=now() from v_pbx_mobile_welcome w where w.email_queue_uuid=q.email_queue_uuid and w.domain_uuid=? and w.extension_uuid=? and q.email_status in('waiting','trying')",[$domain,$extension]);
        $this->q('delete from v_pbx_mobile_enrollments where domain_uuid=? and extension_uuid=? and used_at is null',[$domain,$extension]);
        $devices=$this->q('update v_pbx_mobile_devices set revoked_at=now() where domain_uuid=? and extension_uuid=? and revoked_at is null'.($keepDevice!==null?' and device_uuid<>?':'').' returning device_uuid,sip_username,domain_uuid,extension_uuid',$keepDevice!==null?[$domain,$extension,$keepDevice]:[$domain,$extension])->fetchAll(PDO::FETCH_ASSOC);
        return $devices;
    }
    public function generation(string $domain,string $extension): ?int {$r=$this->q('select generation from v_pbx_mobile_accounts where domain_uuid=? and extension_uuid=?',[$domain,$extension])->fetchColumn();return $r===false?null:(int)$r;}
}
