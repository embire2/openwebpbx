<?php
/** Exact-row Event Guard consumer. Never handles legacy/global unblock requests. */
class pbx_phone_health_recovery {
    public static function handle(PDO $db,event_guard_interface $firewall,string $hostname,mixed $block,mixed $recovery): array {
        if(PHP_SAPI!=='cli'||!is_string($block)||!is_string($recovery)||!is_uuid($block)||!is_uuid($recovery)||!pbx_phone_health::installed($db))return ['status'=>'ignored'];
        $q=static function(string $sql,array $args=[])use($db):PDOStatement{$s=$db->prepare($sql);$s->execute($args);return$s;};
        $db->beginTransaction();try{
            $db->exec("set local lock_timeout='3s';set local statement_timeout='8s'");
            $q('select pg_advisory_xact_lock(hashtext(?))',['openweb-phone-health:'.$hostname]);
            $r=$q('select recovery_uuid,domain_uuid,actor_uuid,block_uuid,host(source_address) source_address,status,created_at from v_pbx_phone_health_recoveries where recovery_uuid=? and block_uuid=? for update',[$recovery,$block])->fetch(PDO::FETCH_ASSOC);
            if(!$r||$r['status']!=='pending'){$db->rollBack();return ['status'=>'ignored'];}
            // The existing service consumes events serially. Row locks protect against parallel
            // web edits and a second worker; only this exact, still-blocked log may be changed.
            $log=$q('select event_guard_log_uuid,hostname,filter,ip_address,log_status from v_event_guard_logs where event_guard_log_uuid=? for update',[$block])->fetch(PDO::FETCH_ASSOC);
            $refusal=null;
            if(!$log||$log['hostname']!==$hostname||$log['filter']!=='sip-auth-fail'||$log['log_status']!=='blocked'||!filter_var($log['ip_address'],FILTER_VALIDATE_IP)||inet_pton($log['ip_address'])!==inet_pton($r['source_address']))$refusal='block_changed';
            elseif(strtotime($r['created_at'])<=time()-pbx_phone_health::COOLDOWN_SECONDS)$refusal='request_expired';
            else $refusal=pbx_phone_health::recoveryRefusal($db,$r,$log);
            if($refusal!==null){
                $q("update v_pbx_phone_health_recoveries set status='refused' where recovery_uuid=? and status='pending'",[$recovery]);
                $q("insert into v_pbx_staff_audit(audit_uuid,domain_uuid,actor_uuid,action,target,result) values(?,?,?,'phone_health_recovery',?,?)",[uuid(),$r['domain_uuid'],$r['actor_uuid'],$block,$refusal]);
                $db->commit();return ['status'=>'refused','reason'=>$refusal];
            }
            if(!method_exists($firewall,'block_state_exact')||!method_exists($firewall,'block_delete_exact')){
                $db->rollBack();return ['status'=>'pending','reason'=>'exact_firewall_check_unavailable'];
            }
            $other=$firewall->block_state_exact($log['ip_address'],'sip-auth-ip');
            if($other==='unknown'){$db->rollBack();return ['status'=>'pending','reason'=>'exact_firewall_check_unavailable'];}
            if($other==='present'){
                $q("update v_pbx_phone_health_recoveries set status='refused' where recovery_uuid=? and status='pending'",[$recovery]);
                $q("insert into v_pbx_staff_audit(audit_uuid,domain_uuid,actor_uuid,action,target,result) values(?,?,?,'phone_health_recovery',?,'another_security_block')",[uuid(),$r['domain_uuid'],$r['actor_uuid'],$block]);
                $db->commit();return ['status'=>'refused','reason'=>'another_security_block'];
            }
            $state=$firewall->block_state_exact($log['ip_address'],'sip-auth-fail');
            if($state==='unknown'){$db->rollBack();return ['status'=>'pending','reason'=>'exact_firewall_check_unavailable'];}
            if($state==='absent'){
                // A stale database block is safe to reconcile only after the exact filter
                // reports absence. No other firewall filter or address is modified.
                $removed=true;
            }else $removed=$firewall->block_delete_exact($log['ip_address'],'sip-auth-fail');
            if(!$removed||$firewall->block_state_exact($log['ip_address'],'sip-auth-fail')!=='absent'){
                $db->rollBack();return ['status'=>'pending','reason'=>'security_service_not_confirmed'];
            }
            $q("update v_event_guard_logs set log_status='unblocked',log_date=now() where event_guard_log_uuid=? and hostname=? and filter='sip-auth-fail' and log_status='blocked'",[$block,$hostname]);
            $q("update v_pbx_phone_health_recoveries set status='acknowledged',acknowledged_at=now() where recovery_uuid=? and status='pending'",[$recovery]);
            $q("insert into v_pbx_staff_audit(audit_uuid,domain_uuid,actor_uuid,action,target,result) values(?,?,?,'phone_health_recovery',?,'acknowledged')",[uuid(),$r['domain_uuid'],$r['actor_uuid'],$block]);
            $db->commit();return ['status'=>'acknowledged'];
        }catch(Throwable$e){if($db->inTransaction())$db->rollBack();throw$e;}
    }
}
