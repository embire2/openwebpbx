<?php
/** Tenant-scoped live phone registration; independent from availability and calling credentials. */
class pbx_user_presence {
    private PDO $db;
    private string $domain;
    private ?pbx_staff_access $scope=null;
    public function __construct(?PDO $db=null) {
        $this->db=$db??database::new()->db;$this->domain=(string)($_SESSION['domain_uuid']??'');$actor=(string)($_SESSION['user_uuid']??'');
        if(empty($_SESSION['authorized'])||!is_uuid($this->domain)||!is_uuid($actor))throw new RuntimeException('Sign in to your PBX first.');
        $q=$this->db->prepare("select 1 from v_users where user_uuid=? and user_enabled='true'");$q->execute([$actor]);if(!$q->fetchColumn())throw new RuntimeException('Your account is unavailable.');
        if(!(new pbx_setup($this->db))->canManage()||!(new pbx_tenants($this->db))->canDomain($this->domain)){
            $scope=new pbx_staff_access($this->db,$this->domain);if(!$scope->active())throw new RuntimeException('Your staff access is unavailable.');$this->scope=$scope;
        }
    }
    protected function engine(): string {return (string)event_socket::api('show registrations as json');}
    private function query(string $sql,array $args=[]): PDOStatement {$q=$this->db->prepare($sql);$q->execute($args);return $q;}
    private static function realm(mixed $value): bool {return is_string($value)&&strlen($value)<=253&&preg_match('/^[a-z0-9](?:[a-z0-9.-]*[a-z0-9])?$/D',$value)===1&&!str_contains($value,'..');}
    private static function enabled(mixed $value): bool {return filter_var($value,FILTER_VALIDATE_BOOLEAN);}
    private static function state(string $state): array {return ['state'=>$state,'label'=>match($state){'online'=>'Online','offline'=>'Offline',default=>'Status unavailable'}];}
    /** No contact, authentication ID, address, device token or other tenant data leaves this class. */
    public function snapshot(): array {
        $row=$this->query('select r.config,d.domain_name,d.domain_enabled from v_pbx_restore r join v_domains d using(domain_uuid) where r.domain_uuid=?',[$this->domain])->fetch(PDO::FETCH_ASSOC);
        if(!$row)throw new RuntimeException('Choose a configured PBX first.');
        $config=json_decode($row['config'],true,512,JSON_THROW_ON_ERROR);$users=$config['users']??[];if(!is_array($users))throw new RuntimeException('This PBX needs review.');
        $visible=$this->scope?($this->scope->filtered($config)['users']??[]):$users;$states=[];$profiles=[];
        foreach($visible as$n=>$u)if(preg_match('/^[0-9]{2,10}$/D',(string)$n)){
            $profiles[(string)$n]=pbx_mobile_state::profile($u,$config,(string)$n);
            $states[(string)$n]=self::state('offline')+['call_status'=>$profiles[(string)$n]];
        }
        $result=['domain_uuid'=>$this->domain,'checked_at'=>gmdate('c'),'users'=>(object)$states];
        if(!$states)return $result;
        try {
            if(!self::enabled($row['domain_enabled'])||$this->query('select 1 from v_pbx_services s join v_pbx_tenants t using(tenant_uuid) where s.domain_uuid=? and not t.enabled',[$this->domain])->fetchColumn())return $result;
            $canonical=$row['domain_name'];if(!self::realm($canonical)||($config['realm']??null)!==$canonical)throw new RuntimeException('Phone domain needs review.');
            $aliases=(bool)$this->query("select to_regclass('v_pbx_sip_domains')")->fetchColumn();
            if($aliases&&$this->query('select 1 from v_pbx_sip_domains where sip_domain=? and domain_uuid<>? and enabled',[$canonical,$this->domain])->fetchColumn())throw new RuntimeException('Phone domain ownership needs review.');
            $realms=[$canonical];
            if($aliases)foreach($this->query('select a.sip_domain from v_pbx_sip_domains a where a.domain_uuid=? and a.enabled and not exists(select 1 from v_domains d where d.domain_name=a.sip_domain and d.domain_uuid<>a.domain_uuid) order by a.sip_domain',[$this->domain])->fetchAll(PDO::FETCH_COLUMN)as$alias)if(self::realm($alias))$realms[]=$alias;
            $extensions=[];$authCounts=[];foreach($this->query('select extension_uuid,extension,enabled from v_extensions where domain_uuid=?',[$this->domain])->fetchAll(PDO::FETCH_ASSOC)as$e){$extensions[$e['extension_uuid']]=$e;if(self::enabled($e['enabled']))$authCounts[$e['extension']]=($authCounts[$e['extension']]??0)+1;}
            $counts=[];foreach($users as$u)if(is_array($u)&&is_uuid($u['extension_uuid']??''))$counts[$u['extension_uuid']]=($counts[$u['extension_uuid']]??0)+1;
            $identities=[];$byExtension=[];
            foreach($visible as$n=>$u){
                $n=(string)$n;if(!isset($states[$n])||!is_array($u))continue;
                $id=$u['extension_uuid']??'';$native=$extensions[$id]??null;
                if(!self::enabled($u['enabled']??false)||($native&&!self::enabled($native['enabled'])))continue;
                if(!$native||($counts[$id]??0)!==1||($authCounts[$native['extension']]??0)!==1||!is_string($u['auth_id']??null)||$u['auth_id']!==$native['extension']){$states[$n]=self::state('unavailable');continue;}
                $byExtension[$id]=$n;foreach($realms as$realm)$identities[$realm."\0".$u['auth_id']][]=$n;
            }
            if($this->query("select to_regclass('v_pbx_mobile_devices')")->fetchColumn()){
                $devices=$this->query('select extension_uuid,sip_username from v_pbx_mobile_devices where domain_uuid=? and revoked_at is null and expires_at>now()',[$this->domain])->fetchAll(PDO::FETCH_ASSOC);$mobileCounts=[];
                foreach($devices as$device)if(is_string($device['sip_username']))$mobileCounts[$device['sip_username']]=($mobileCounts[$device['sip_username']]??0)+1;
                foreach($devices as$device){
                    $number=$byExtension[$device['extension_uuid']]??null;$username=$device['sip_username'];
                    if($number!==null&&is_string($username)&&preg_match('/^owm-[a-f0-9]{32}$/D',$username)){
                        if($mobileCounts[$username]!==1){$states[$number]=self::state('unavailable');continue;}
                        $identities[$canonical."\0".$username][]=$number;
                    }
                }
            }
            $raw=$this->engine();if(strlen($raw)>8388608)throw new RuntimeException('Phone status response is too large.');
            $live=json_decode($raw,true,32,JSON_THROW_ON_ERROR);if(!is_array($live)||!isset($live['row_count'])||!is_int($live['row_count'])||$live['row_count']<0||$live['row_count']>20000)throw new RuntimeException('Phone status is unavailable.');
            $rows=$live['rows']??[];if(!is_array($rows)||!array_is_list($rows)||count($rows)!==$live['row_count'])throw new RuntimeException('Phone status is incomplete.');
            $now=time();foreach($rows as$registration){
                if(!is_array($registration)||!is_string($registration['reg_user']??null)||!is_string($registration['realm']??null)||!is_scalar($registration['expires']??null)||!preg_match('/^[0-9]{1,12}$/D',(string)$registration['expires']))throw new RuntimeException('Phone status is invalid.');
                if(!is_string($registration['url']??null)||strlen($registration['url'])>8192)throw new RuntimeException('Phone contact is unavailable.');
                if((int)$registration['expires']<=$now||!preg_match('~^sofia/[^/\s]+/sips?:[^\s]+$~D',$registration['url']))continue;
                $owners=array_unique($identities[$registration['realm']."\0".$registration['reg_user']]??[]);
                if(count($owners)>1){foreach($owners as$n)$states[$n]=self::state('unavailable');continue;}
                if(count($owners)===1)$states[reset($owners)]=self::state('online');
            }
        }catch(Throwable){foreach($states as$n=>$s)$states[$n]=self::state('unavailable');}
        foreach($states as$n=>&$status)$status['call_status']=$profiles[$n];unset($status);
        $result['users']=(object)$states;return $result;
    }
    public static function callStatus(string $number,array $status): string {
        $label=is_string($status['call_status']??null)?$status['call_status']:'Status unavailable';
        return '<span data-call-status-number="'.htmlspecialchars($number,ENT_QUOTES,'UTF-8').'">'.htmlspecialchars($label,ENT_QUOTES,'UTF-8').'</span>';
    }
    public static function badge(string $number,array $status): string {
        $state=in_array($status['state']??null,['online','offline','unavailable'],true)?$status['state']:'unavailable';$label=self::state($state)['label'];
        return '<span class="pbx-phone-state '.$state.'" data-phone-number="'.htmlspecialchars($number,ENT_QUOTES,'UTF-8').'" role="status" aria-live="polite">'.htmlspecialchars($label,ENT_QUOTES,'UTF-8').'</span>';
    }
}
