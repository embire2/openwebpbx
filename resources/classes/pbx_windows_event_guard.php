<?php
/** Native Windows security policy; called only by the protected local task. */
class pbx_windows_event_guard {
    private PDO $db;
    private event_guard_interface $firewall;
    public function __construct(PDO $db,event_guard_interface $firewall){$this->db=$db;$this->firewall=$firewall;}
    private function q(string $sql,array $args=[]): PDOStatement {$q=$this->db->prepare($sql);$q->execute($args);return $q;}
    protected function registrations(): string {return pbx_windows_health_stream::api('show registrations as json');}
    protected function instanceId(): string {return pbx_phone_health::instanceId()??throw new RuntimeException('A Windows instance identity is required.');}
    private function allowed(string $source): bool {
        // Registered addresses and explicitly allowed administrator networks
        // retain the existing Event Guard exemptions. Unknown native state is
        // never evidence that a shared office is safe to block.
        $rows=pbx_phone_health::registrations($this->registrations());
        foreach($rows as$r)if((int)$r['expires']>time()&&filter_var($r['network_ip']??null,FILTER_VALIDATE_IP)&&inet_pton($r['network_ip'])===inet_pton($source))return true;
        foreach($this->db->query("select node_cidr from v_access_control_nodes where node_type='allow' and length(node_cidr)>0")->fetchAll(PDO::FETCH_COLUMN)as$cidr)if(check_cidr($cidr,$source))return true;
        return (bool)$this->q("select 1 from v_user_logs where remote_address=? and result='success' and timestamp>now()-interval '8 days' limit 1",[$source])->fetchColumn();
    }
    /** Fixed safe result only: no credentials, event bodies or source addresses. */
    public function consume(array $event): array {
        $kind=$event['Event-Subclass']??null;
        if($kind==='event_guard:phone_health_unblock'){
            $block=$event['OpenWeb-Phone-Health-Block']??null;$recovery=$event['OpenWeb-Phone-Health-Recovery']??null;
            if(!is_uuid($block)||!is_uuid($recovery))return ['status'=>'ignored'];
            $row=$this->q("select r.instance_id,l.ip_address from v_pbx_phone_health_recoveries r join v_event_guard_logs l on l.event_guard_log_uuid=r.block_uuid where r.recovery_uuid=? and r.block_uuid=? and r.status='pending' and l.hostname=? and l.filter='sip-auth-fail' and l.log_status='blocked'",[$recovery,$block,gethostname()])->fetch(PDO::FETCH_ASSOC);
            if(!$row||!is_string($row['instance_id'])||!hash_equals($this->instanceId(),$row['instance_id']))return ['status'=>'refused','reason'=>'different_installation'];
            if(!method_exists($this->firewall,'block_state_exact')||$this->firewall->block_state_exact($row['ip_address'],'sip-auth-fail')!=='present')return ['status'=>'pending','reason'=>'native_block_not_confirmed'];
            return pbx_phone_health_recovery::handle($this->db,$this->firewall,gethostname(),$block,$recovery);
        }
        if(!in_array($kind,['sofia::register_failure','sofia::pre_register'],true))return ['status'=>'ignored'];
        $source=$event['network-ip']??null;$host=$event['to-host']??null;$user=$event['to-user']??null;
        if(!is_string($source)||!filter_var($source,FILTER_VALIDATE_IP,FILTER_FLAG_IPV4)||!is_string($host)||strlen($host)>253||!is_string($user)||strlen($user)>256||preg_match('/[\x00-\x20\x7f]/',$host.$user))return ['status'=>'ignored'];
        if($kind==='sofia::pre_register'&&!filter_var($host,FILTER_VALIDATE_IP))return ['status'=>'ignored'];
        $source=inet_ntop(inet_pton($source));$filter=$kind==='sofia::register_failure'?'sip-auth-fail':'sip-auth-ip';
        // Protect local engine, loopback and administration. These sources
        // cannot establish customer office proof or create a remote block.
        if($source==='0.0.0.0'||str_starts_with($source,'127.')||$source==='255.255.255.255')return ['status'=>'ignored'];
        $this->db->beginTransaction();try{
            $this->db->exec("set local lock_timeout='3s';set local statement_timeout='12s'");
            $this->q('select pg_advisory_xact_lock(hashtext(?))',['openweb-phone-health:'.gethostname()]);
            if($this->allowed($source)){$this->db->rollBack();return ['status'=>'allowed'];}
            $existing=$this->q("select event_guard_log_uuid from v_event_guard_logs where hostname=? and ip_address=? and filter=? and log_status='blocked' order by log_date desc limit 1 for update",[gethostname(),$source,$filter])->fetchColumn();
            // Idempotently recreate a missing owned rule after a host restart;
            // an unrelated or changed rule refuses without changing the ledger.
            if(!$this->firewall->block_add($source,$filter)){$this->db->rollBack();return ['status'=>'unavailable'];}
            if(!$existing){
                $agent=$event['user-agent']??'';if(!is_string($agent)||strlen($agent)>512||preg_match('/[\x00-\x1f\x7f]/',$agent))$agent='';
                $this->q("insert into v_event_guard_logs(event_guard_log_uuid,hostname,log_date,filter,ip_address,extension,user_agent,log_status) values(?,?,now(),?,?,?,?, 'blocked')",[uuid(),gethostname(),$filter,$source,$user.'@'.$host,$agent]);
            }
            $this->db->commit();return ['status'=>'blocked'];
        }catch(Throwable$e){if($this->db->inTransaction())$this->db->rollBack();throw$e;}
    }
}
