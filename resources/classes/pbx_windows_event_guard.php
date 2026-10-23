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
    /** Test seam for failure after a native mutation, before its SQL acknowledgement. */
    protected function afterNativeAdd(): void {}
    private function locked(): void {
        $this->db->beginTransaction();try{
            $this->db->exec("set local lock_timeout='3s';set local statement_timeout='12s'");
            $this->q('select pg_advisory_xact_lock(hashtext(?))',['openweb-phone-health:'.gethostname()]);
        }catch(Throwable$e){if($this->db->inTransaction())$this->db->rollBack();throw$e;}
    }
    /** Reconcile committed intents by observing exact native state only. A restored
     * or interrupted intent never creates a rule without a fresh failure event.
     * At most two bounded native reads run per scan; unknown/remaining work keeps
     * the security observer visibly unavailable rather than claiming a result. */
    public function reconcile(): bool {
        $rows=$this->q("select event_guard_log_uuid from v_event_guard_logs where hostname=? and log_status='windows_intent' order by log_date limit 2",[gethostname()])->fetchAll(PDO::FETCH_COLUMN);
        foreach($rows as$id){
            $this->locked();try{
                $row=$this->q("select ip_address,filter from v_event_guard_logs where event_guard_log_uuid=? and hostname=? and log_status='windows_intent' for update",[$id,gethostname()])->fetch(PDO::FETCH_ASSOC);
                if($row&&in_array($row['filter'],['sip-auth-fail','sip-auth-ip'],true)&&filter_var($row['ip_address'],FILTER_VALIDATE_IP,FILTER_FLAG_IPV4)){
                    $state=method_exists($this->firewall,'block_state_exact')?$this->firewall->block_state_exact($row['ip_address'],$row['filter']):'unknown';
                    if(in_array($state,['present','absent'],true))$this->q("update v_event_guard_logs set log_status=? where event_guard_log_uuid=?",[$state==='present'?'blocked':'windows_incomplete',$id]);
                }
                $this->db->commit();
            }catch(Throwable$e){if($this->db->inTransaction())$this->db->rollBack();throw$e;}
        }
        return !$this->q("select 1 from v_event_guard_logs where hostname=? and log_status='windows_intent' limit 1",[gethostname()])->fetchColumn();
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
        // pre_register is a challenge shared by REGISTER and INVITE. Its
        // to-host is the caller-controlled From host, not proof of a direct-IP
        // registration or failed digest. Private/public numeric phone headers
        // must never create an office-wide block. Keep genuine failures below.
        if($kind!=='sofia::register_failure')return ['status'=>'ignored'];
        $source=$event['network-ip']??null;$host=$event['to-host']??null;$user=$event['to-user']??null;
        if(!is_string($source)||!filter_var($source,FILTER_VALIDATE_IP,FILTER_FLAG_IPV4)||!is_string($host)||strlen($host)>253||!is_string($user)||strlen($user)>256||preg_match('/[\x00-\x20\x7f]/',$host.$user))return ['status'=>'ignored'];
        $source=inet_ntop(inet_pton($source));$filter='sip-auth-fail';
        // Protect local engine, loopback and administration. These sources
        // cannot establish customer office proof or create a remote block.
        if($source==='0.0.0.0'||str_starts_with($source,'127.')||$source==='255.255.255.255')return ['status'=>'ignored'];
        // Commit the intent before touching Defender. A timeout, process exit or
        // SQL acknowledgement failure must leave a durable, attributable record.
        $this->locked();try{
            if($this->allowed($source)){$this->db->rollBack();return ['status'=>'allowed'];}
            $id=$this->q("select event_guard_log_uuid from v_event_guard_logs where hostname=? and ip_address=? and filter=? and log_status in ('blocked','windows_intent') order by log_date desc limit 1 for update",[gethostname(),$source,$filter])->fetchColumn();
            if(!$id){
                $id=uuid();$agent=$event['user-agent']??'';if(!is_string($agent)||strlen($agent)>512||preg_match('/[\x00-\x1f\x7f]/',$agent))$agent='';
                $this->q("insert into v_event_guard_logs(event_guard_log_uuid,hostname,log_date,filter,ip_address,extension,user_agent,log_status) values(?,?,now(),?,?,?,?, 'windows_intent')",[$id,gethostname(),$filter,$source,$user.'@'.$host,$agent]);
            }else $this->q("update v_event_guard_logs set log_status='windows_intent' where event_guard_log_uuid=?",[$id]);
            $this->db->commit();
        }catch(Throwable$e){if($this->db->inTransaction())$this->db->rollBack();throw$e;}
        $this->firewall->block_add($source,$filter);$this->afterNativeAdd();
        // Never trust Add's reply as a durable ledger acknowledgement. Read the
        // exact owned state, then serialize the result with recovery requests.
        $this->locked();try{
            $row=$this->q("select log_status from v_event_guard_logs where event_guard_log_uuid=? and hostname=? and ip_address=? and filter=? for update",[$id,gethostname(),$source,$filter])->fetchColumn();
            if($row!=='windows_intent'){$this->db->rollBack();return ['status'=>'unavailable'];}
            $state=method_exists($this->firewall,'block_state_exact')?$this->firewall->block_state_exact($source,$filter):'unknown';
            if(in_array($state,['present','absent'],true))$this->q("update v_event_guard_logs set log_status=? where event_guard_log_uuid=?",[$state==='present'?'blocked':'windows_incomplete',$id]);
            $this->db->commit();return ['status'=>$state==='present'?'blocked':'unavailable'];
        }catch(Throwable$e){if($this->db->inTransaction())$this->db->rollBack();throw$e;}
    }
}
