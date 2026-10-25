<?php
/** Shared extension status. Bearer identity always supplies the domain and user. */
class pbx_mobile_state {
    private PDO $db;
    public function __construct(?PDO $db=null){$this->db=$db??database::new()->db;}
    private function q(string $sql,array $args=[]): PDOStatement {$s=$this->db->prepare($sql);$s->execute($args);return $s;}

    /** Match the native profile policy, including temporary overrides and office hours. */
    public static function profile(array $user,array $config=[],?string $number=null,?int $now=null): string {
        $now??=time();$status=(string)($user['profile']??'Available');$temporary=$user['mobile_temporary']??[];
        $matching=isset($temporary['expires'],$temporary['target'],$temporary['previous'])&&$status===$temporary['target'];
        if($matching&&(int)$temporary['expires']<=$now)$status=(string)$temporary['previous'];
        $override=$matching&&(int)$temporary['expires']>$now;
        if(!$override&&$status!=='Do Not Disturb'&&(int)($user['auto_status']??0)%2===1&&$config!==[]){
            $number??=(string)($user['number']??'');$department=pbx_schedule::department($config,$number);
            if($department!==null){
                $office=pbx_schedule::office($department,$config['timezone']??'Africa/Johannesburg',$now);
                if(!$office['open'])$status=$office['break']?'Away':'Out of office';
                elseif($status==='Out of office'&&is_array($user['profiles']['Available']??null))$status='Available';
            }
        }
        return isset($user['profiles'][$status])?$status:(string)($user['profile']??'Available');
    }
    private function config(array $account,bool $lock=false): array {
        if(!is_uuid($account['domain_uuid']??'')||!is_uuid($account['extension_uuid']??'')||!preg_match('/^[0-9]{2,10}$/D',(string)($account['number']??'')))throw new InvalidArgumentException('User unavailable.');
        $raw=$this->q("select r.config from v_pbx_restore r join v_domains d using(domain_uuid) join v_extensions e on e.domain_uuid=d.domain_uuid and e.extension_uuid=? and e.enabled='true' where r.domain_uuid=? and d.domain_enabled='true' and not exists(select 1 from v_pbx_services s join v_pbx_tenants t using(tenant_uuid) where s.domain_uuid=d.domain_uuid and not t.enabled)".($lock?' for update of r':''),[$account['extension_uuid'],$account['domain_uuid']])->fetchColumn();
        $c=$raw?json_decode($raw,true,512,JSON_THROW_ON_ERROR):[];$user=$c['users'][$account['number']]??[];
        if(empty($user['enabled'])||($user['extension_uuid']??'')!==$account['extension_uuid'])throw new OutOfBoundsException('User unavailable.');
        return $c;
    }
    public function read(array $account): array {
        $c=$this->config($account);$u=$c['users'][$account['number']];$status=self::profile($u,$c,(string)$account['number']);$queues=[];
        $reserved=(bool)$this->q("select 1 from v_pbx_jobs where domain_uuid=? and agent_number=? and state in ('starting','calling')",[$account['domain_uuid'],$account['number']])->fetchColumn();
        foreach($c['queues']??[] as $queue)foreach($queue['members']??[] as $m)if((string)$m['number']===(string)$account['number']){
            $selected=($m['status']??'LoggedOut')==='LoggedIn';$global=($u['queue_status']??'')==='LoggedIn';$joined=$selected&&$global;
            $reason=!$selected?'You left this queue':(!$global?'Signed out of queues':(($u['profiles'][$status]['queue_status']??'1')==='0'?'Paused by your status':($reserved?'A callback is using your phone':(!empty($m['supervisor_break'])?'Paused by supervisor':''))));
            $queues[]=['number'=>(string)$queue['number'],'name'=>$queue['name'],'joined'=>$joined,'receiving'=>$reason==='','receiving_reason'=>$reason];
        }
        $profiles=array_keys($u['profiles']??[]);if(!in_array('Do Not Disturb',$profiles,true))$profiles[]='Do Not Disturb';
        $temp=$u['mobile_temporary']??[];$active=($temp['target']??null)===($u['profile']??'')&&(int)($temp['expires']??0)>time();
        return ['status'=>$status,'statuses'=>$profiles,'temporary_until'=>$active?gmdate('c',(int)$temp['expires']):null,'queues'=>$queues];
    }
    public function status(array $account,array $input): array {
        $status=$input['status']??null;$minutes=$input['minutes']??0;
        if(!is_string($status)||!is_int($minutes)||!in_array($minutes,[0,15,30,60,120,240,480],true))throw new InvalidArgumentException('Choose a status and duration.');
        $this->db->beginTransaction();try{
            $c=$this->config($account,true);$u=&$c['users'][$account['number']];
            if($status==='Do Not Disturb'&&!isset($u['profiles'][$status])){
                $u['profiles'][$status]=$u['profiles']['Away']??['available'=>[],'away'=>[],'timeout'=>'20'];
                $u['profiles'][$status]['name']=$status;
                $dest=!empty($u['voicemail_enabled'])&&is_uuid($u['voicemail_uuid']??'')?['type'=>'VoiceMail','number'=>$account['number'],'external'=>'']:['type'=>'EndCall','number'=>'','external'=>''];
                $u['profiles'][$status]['away']=['Internal'=>['all'=>$dest,'outside'=>$dest,'outside_inactive'=>true],'External'=>['all'=>$dest,'outside'=>$dest,'outside_inactive'=>true]];
                $u['profiles'][$status]['queue_status']='0';$u['profiles'][$status]['disable_ring_groups']=true;$u['profiles'][$status]['ring_mobile']=false;
            }
            if(!isset($u['profiles'][$status]))throw new InvalidArgumentException('Choose a status offered by your PBX.');
            // Return to the underlying selection; office hours are reapplied at expiry.
            $previous=(string)($u['profile']??'Available');$existing=$u['mobile_temporary']??[];
            if(($existing['target']??'')===$previous&&isset($existing['previous']))$previous=(string)$existing['previous'];
            unset($u['mobile_temporary']);$u['profile']=$status;
            $this->q('delete from v_pbx_mobile_presence where domain_uuid=? and extension_uuid=?',[$account['domain_uuid'],$account['extension_uuid']]);
            if($minutes>0){
                $expiry=time()+$minutes*60;$u['mobile_temporary']=['previous'=>$previous,'target'=>$status,'expires'=>$expiry];
                $this->q('insert into v_pbx_mobile_presence(domain_uuid,extension_uuid,number,previous_profile,target_profile,expires_at) values(?,?,?,?,?,to_timestamp(?))',[$account['domain_uuid'],$account['extension_uuid'],$account['number'],$previous,$status,$expiry]);
            }
            $this->save($account,$c);$this->db->commit();
        }catch(Throwable $e){if($this->db->inTransaction())$this->db->rollBack();throw $e;}
        $this->sync($account);return $this->read($account);
    }
    public function queue(array $account,array $input): array {
        $number=$input['number']??null;$joined=$input['joined']??null;
        if(!is_string($number)||!preg_match('/^[0-9]{2,10}$/D',$number)||!is_bool($joined))throw new InvalidArgumentException('Choose your queue.');
        $this->db->beginTransaction();try{
            $c=$this->config($account,true);$found=false;
            if($joined&&($c['users'][$account['number']]['queue_status']??'')!=='LoggedIn'){
                // Signing back in must enable only the selected queue, rather than
                // unexpectedly reactivate every inherited membership at once.
                $c['users'][$account['number']]['queue_status']='LoggedIn';
                foreach($c['queues']??[] as $i=>$queue)foreach($queue['members']??[] as $j=>$m)if((string)$m['number']===(string)$account['number'])$c['queues'][$i]['members'][$j]['status']='LoggedOut';
            }
            foreach($c['queues']??[] as $i=>$queue)if((string)$queue['number']===$number)foreach($queue['members']??[] as $j=>$m)if((string)$m['number']===(string)$account['number']){$c['queues'][$i]['members'][$j]['status']=$joined?'LoggedIn':'LoggedOut';$found=true;}
            if(!$found)throw new OutOfBoundsException('This queue is not assigned to you.');
            $this->save($account,$c);$this->db->commit();
        }catch(Throwable $e){if($this->db->inTransaction())$this->db->rollBack();throw $e;}
        $this->sync($account);return $this->read($account);
    }
    private function save(array $account,array $c): void {$this->q('update v_pbx_restore set config=?::jsonb where domain_uuid=?',[json_encode($c,JSON_THROW_ON_ERROR),$account['domain_uuid']]);}
    protected function engine(string $command): string {return (string)event_socket::api($command);}
    private function sync(array $account): void {
        // Read the latest committed configuration in the engine. Concurrent app/Admin
        // changes cannot be undone by an earlier request's copied profile or agent list.
        try{$this->engine('lua app/pbx_setup/mobile_state.lua '.$account['domain_uuid'].' '.$account['number']);}
        catch(Throwable){/* Saved settings remain authoritative on the next queue call. */}
    }
}
