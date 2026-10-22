<?php
/** Explainable phone health. Reads never change calling configuration or credentials. */
class pbx_phone_health {
    public const HISTORY_DAYS=30;
    public const COOLDOWN_SECONDS=900;
    public const FRESH_SECONDS=120;
    private PDO $db;
    private string $domain;
    private string $actor;
    private bool $trusted=false;
    private bool $owner=false;
    private ?pbx_staff_access $scope=null;
    private ?array $cachedRows=null;

    public function __construct(?PDO $db=null) {
        $this->db=$db??database::new()->db;
        $this->domain=(string)($_SESSION['domain_uuid']??'');
        $this->actor=(string)($_SESSION['user_uuid']??'');
    }
    protected function engine(string $command): string {return (string)event_socket::api($command);}
    protected function dispatch(string $block,string $recovery): bool {
        $cmd="sendevent CUSTOM\nEvent-Name: CUSTOM\nEvent-Subclass: event_guard:phone_health_unblock\nOpenWeb-Phone-Health-Block: ".$block."\nOpenWeb-Phone-Health-Recovery: ".$recovery."\n";
        event_socket::create();$reply=event_socket::command($cmd);
        if(is_array($reply)){
            if(count($reply)>8||($reply['Content-Type']??null)!=='command/reply')return false;
            $reply=$reply['Reply-Text']??null;
        }
        return is_string($reply)&&strlen($reply)<=1024&&preg_match('/^\+OK(?:\s|$)/D',trim($reply))===1;
    }
    private function q(string $sql,array $args=[]): PDOStatement {$q=$this->db->prepare($sql);$q->execute($args);return $q;}
    private static function on(mixed $v): bool {return filter_var($v,FILTER_VALIDATE_BOOLEAN);}
    private static function realm(mixed $v): bool {return is_string($v)&&strlen($v)<=253&&preg_match('/^[a-z0-9](?:[a-z0-9.-]*[a-z0-9])?$/D',$v)===1&&!str_contains($v,'..');}
    private static function label(mixed $v,string $fallback): string {return is_string($v)&&mb_strlen($v)<=120&&!preg_match('/[\x00-\x1f\x7f]/',$v)?$v:$fallback;}
    public static function installed(PDO $db): bool {
        return (bool)$db->query("select to_regclass('v_pbx_phone_health_contacts') is not null and to_regclass('v_pbx_phone_health_recoveries') is not null and to_regclass('v_pbx_phone_health_issues') is not null and to_regclass('v_pbx_phone_health_settings') is not null and to_regclass('v_pbx_phone_health_state') is not null")->fetchColumn();
    }
    private function context(): array {
        if(!$this->trusted){
            if(empty($_SESSION['authorized'])||$this->domain!==($_SESSION['domain_uuid']??null)||$this->actor!==($_SESSION['user_uuid']??null)||!is_uuid($this->domain)||!is_uuid($this->actor)||!$this->q("select 1 from v_users where user_uuid=? and user_enabled='true'",[$this->actor])->fetchColumn())throw new RuntimeException('Sign in with an enabled PBX administrator account.');
            $this->scope=new pbx_staff_access($this->db,$this->domain);$this->owner=$this->scope->owner();
            if(!$this->owner&&!$this->scope->can('phones'))throw new RuntimeException('Your role does not allow phone health for this PBX.');
        }
        $raw=$this->q("select r.config from v_pbx_restore r join v_domains d using(domain_uuid) where r.domain_uuid=? and d.domain_enabled='true' and not exists(select 1 from v_pbx_services s join v_pbx_tenants t using(tenant_uuid) where s.domain_uuid=r.domain_uuid and not t.enabled)",[$this->domain])->fetchColumn();
        if(!is_string($raw))throw new RuntimeException('This PBX is unavailable.');
        $c=json_decode($raw,true,512,JSON_THROW_ON_ERROR);
        if(!is_array($c)||!is_array($c['users']??null))throw new RuntimeException('This PBX needs a configuration review.');
        return $c;
    }
    /** Strict native response parser. A malformed response never becomes an empty/offline list. */
    public static function registrations(string $raw): array {
        if(strlen($raw)>8388608)throw new RuntimeException('Phone status response is too large.');
        $data=json_decode($raw,true,32,JSON_THROW_ON_ERROR);
        if(!is_array($data)||!is_int($data['row_count']??null)||$data['row_count']<0||$data['row_count']>20000)throw new RuntimeException('Phone status is unavailable.');
        $rows=$data['rows']??[];
        if(!is_array($rows)||!array_is_list($rows)||count($rows)!==$data['row_count'])throw new RuntimeException('Phone status is incomplete.');
        foreach($rows as$r)if(!is_array($r)||!is_string($r['reg_user']??null)||strlen($r['reg_user'])>256||!self::realm($r['realm']??null)||!is_scalar($r['expires']??null)||!preg_match('/^[0-9]{1,12}$/D',(string)$r['expires'])||!is_string($r['url']??null)||strlen($r['url'])>8192)throw new RuntimeException('Phone status is invalid.');
        return $rows;
    }
    /** Unique enabled native identities and explicitly owned aliases across the instance. */
    private static function directory(PDO $db): array {
        $out=['domains'=>[],'identities'=>[],'extensions'=>[]];
        $configs=$db->query("select r.domain_uuid,r.config,d.domain_name from v_pbx_restore r join v_domains d using(domain_uuid) where d.domain_enabled='true' and not exists(select 1 from v_pbx_services s join v_pbx_tenants t using(tenant_uuid) where s.domain_uuid=r.domain_uuid and not t.enabled)")->fetchAll(PDO::FETCH_ASSOC);
        $native=[];$counts=[];
        foreach($db->query('select extension_uuid,domain_uuid,extension,enabled from v_extensions')->fetchAll(PDO::FETCH_ASSOC)as$e){$native[$e['extension_uuid']]=$e;if(self::on($e['enabled']))$counts[$e['domain_uuid']."\0".$e['extension']]=($counts[$e['domain_uuid']."\0".$e['extension']]??0)+1;}
        $aliases=[];
        if($db->query("select to_regclass('v_pbx_sip_domains')")->fetchColumn())foreach($db->query('select a.domain_uuid,a.sip_domain from v_pbx_sip_domains a where a.enabled and not exists(select 1 from v_domains d where d.domain_name=a.sip_domain and d.domain_uuid<>a.domain_uuid)')->fetchAll(PDO::FETCH_ASSOC)as$a)$aliases[$a['domain_uuid']][]=$a['sip_domain'];
        foreach($configs as$row){
            $c=json_decode($row['config'],true,512,JSON_THROW_ON_ERROR);$d=$row['domain_uuid'];
            if(!is_array($c)||!is_array($c['users']??null)||!self::realm($row['domain_name'])||($c['realm']??null)!==$row['domain_name'])continue;
            $realms=array_values(array_unique(array_filter(array_merge([$row['domain_name']],$aliases[$d]??[]),[self::class,'realm'])));
            // An alias claimed by another domain is unusable, including a canonical collision.
            foreach($realms as$i=>$realm){$q=$db->prepare('select count(distinct domain_uuid) from (select domain_uuid from v_domains where domain_name=? union all select domain_uuid from v_pbx_sip_domains where sip_domain=? and enabled) a');
                if($db->query("select to_regclass('v_pbx_sip_domains')")->fetchColumn()){$q->execute([$realm,$realm]);if((int)$q->fetchColumn()!==1)unset($realms[$i]);}}
            $out['domains'][$d]=['config'=>$c,'realms'=>array_values($realms)];$uuidCounts=[];
            foreach($c['users']as$u)if(is_array($u)&&is_uuid($u['extension_uuid']??''))$uuidCounts[$u['extension_uuid']]=($uuidCounts[$u['extension_uuid']]??0)+1;
            foreach($c['users']as$n=>$u){
                $n=(string)$n;$id=$u['extension_uuid']??'';$e=$native[$id]??null;
                if(!preg_match('/^[0-9]{2,10}$/D',$n)||!self::on($u['enabled']??false)||!$e||$e['domain_uuid']!==$d||!self::on($e['enabled'])||($uuidCounts[$id]??0)!==1||($counts[$d."\0".$e['extension']]??0)!==1||!is_string($u['auth_id']??null)||$u['auth_id']!==$e['extension'])continue;
                $v=['domain_uuid'=>$d,'extension_uuid'=>$id,'number'=>$n];$out['extensions'][$id]=$v;
                foreach($realms as$realm)$out['identities'][$realm."\0".$u['auth_id']][]=$v;
            }
        }
        // App registrations contribute Online status, but never establish a desk-phone office.
        if($db->query("select to_regclass('v_pbx_mobile_devices')")->fetchColumn()){
            $devices=$db->query('select domain_uuid,extension_uuid,sip_username from v_pbx_mobile_devices where revoked_at is null and expires_at>now()')->fetchAll(PDO::FETCH_ASSOC);$seen=[];
            foreach($devices as$v)$seen[$v['domain_uuid']."\0".$v['sip_username']]=($seen[$v['domain_uuid']."\0".$v['sip_username']]??0)+1;
            foreach($devices as$v){$e=$out['extensions'][$v['extension_uuid']]??null;$realm=$out['domains'][$v['domain_uuid']]['config']['realm']??null;
                if($e&&$e['domain_uuid']===$v['domain_uuid']&&self::realm($realm)&&preg_match('/^owm-[a-f0-9]{32}$/D',(string)$v['sip_username'])&&$seen[$v['domain_uuid']."\0".$v['sip_username']]===1)$out['identities'][$realm."\0".$v['sip_username']][]= $e+['mobile'=>true];
            }
        }
        return $out;
    }
    private static function active(array $r): bool {return (int)$r['expires']>time()&&preg_match('~^sofia/[^/\s]+/sips?:[^\s]+$~D',$r['url'])===1;}
    /** Trusted local observer only. Failed SIP attempts cannot add or refresh contact history. */
    public static function collect(PDO $db,string $registrationsJson): array {
        if(PHP_SAPI!=='cli')throw new RuntimeException('Phone observation is a local service operation.');
        if(!self::installed($db))throw new RuntimeException('Install Phone Health before starting its observer.');
        $rows=self::registrations($registrationsJson);$directory=self::directory($db);$n=0;
        $ownTransaction=!$db->inTransaction();if($ownTransaction)$db->beginTransaction();
        try {
        $db->exec("select pg_advisory_xact_lock(hashtext('openweb-phone-health-collect'))");
        $db->exec('update v_pbx_phone_health_contacts set missing_since=coalesce(missing_since,now())');
        $insert=$db->prepare('insert into v_pbx_phone_health_contacts(domain_uuid,extension_uuid,source_address,expires_at) values(?,?,?::inet,to_timestamp(?)) on conflict(domain_uuid,extension_uuid,source_address) do update set last_seen=now(),expires_at=excluded.expires_at,missing_since=null');
        foreach($rows as$r){$owners=$directory['identities'][$r['realm']."\0".$r['reg_user']]??[];$source=$r['network_ip']??null;
            if(!self::active($r)||count($owners)!==1||!empty($owners[0]['mobile'])||!is_string($source)||!filter_var($source,FILTER_VALIDATE_IP)||str_contains($source,'/'))continue;
            $e=$owners[0];$insert->execute([$e['domain_uuid'],$e['extension_uuid'],$source,(int)$r['expires']]);$n++;
        }
        if($ownTransaction)$db->commit();
        }catch(Throwable$e){if($ownTransaction&&$db->inTransaction())$db->rollBack();throw$e;}
        return ['observed_contacts'=>$n,'checked_domains'=>count($directory['domains']),'at'=>gmdate('c')];
    }
    private function recentContacts(): array {
        return $this->q("select c.domain_uuid,c.extension_uuid,host(c.source_address) source_address,c.last_seen from v_pbx_phone_health_contacts c join v_extensions e on e.extension_uuid=c.extension_uuid and e.domain_uuid=c.domain_uuid where c.last_seen>now()-interval '30 days' and e.enabled='true'")->fetchAll(PDO::FETCH_ASSOC);
    }
    private function blocks(array $c,array $directory): array {
        if(!$this->q("select to_regclass('v_event_guard_logs')")->fetchColumn())return [];
        $contacts=$this->recentContacts();$bySource=[];foreach($contacts as$v)$bySource[$v['source_address']][]=$v;
        $realms=$directory['domains'][$this->domain]['realms']??[];
        if($this->q("select to_regclass('v_pbx_tenant_domains')")->fetchColumn())foreach($this->q("select hostname from v_pbx_tenant_domains where domain_uuid=? and state='ready' and desired_enabled",[$this->domain])->fetchAll(PDO::FETCH_COLUMN)as$h)if(self::realm($h))$realms[]=$h;
        $claimed=[];foreach($c['users']as$n=>$u)if(isset($u['auth_id'])&&is_string($u['auth_id']))foreach($realms as$realm)$claimed[$u['auth_id'].'@'.$realm]=(string)$n;
        $rows=$this->q("select event_guard_log_uuid,hostname,log_date,filter,ip_address,extension,log_status from v_event_guard_logs where hostname=? and log_status in ('blocked','pending') order by log_date desc limit 2001",[gethostname()])->fetchAll(PDO::FETCH_ASSOC);
        $out=[];
        foreach($rows as$r){
            if($r['filter']!=='sip-auth-fail'||!filter_var($r['ip_address'],FILTER_VALIDATE_IP))continue;
            $source=inet_ntop(inet_pton($r['ip_address']));$history=$bySource[$source]??[];$affected=[];$foreign=false;
            foreach($history as$h){$e=$directory['extensions'][$h['extension_uuid']]??null;if(!$e)continue;if($e['domain_uuid']!==$this->domain){$foreign=true;continue;}$affected[$e['number']]=$e['extension_uuid'];}
            $claim=$claimed[$r['extension']]??null;
            if(!$affected&&$claim===null)continue;
            if($claim!==null)$affected[$claim]=$c['users'][$claim]['extension_uuid']??'';
            $visible=[];foreach($affected as$n=>$id)if($this->trusted||$this->owner||$this->scope?->permits('phones',(string)$n,$c))$visible[]=(string)$n;
            if(!$visible)continue;sort($visible,SORT_NATURAL);
            $verified=array_filter($history,fn($h)=>$h['domain_uuid']===$this->domain&&isset($directory['extensions'][$h['extension_uuid']]));
            $restriction='';
            if(!$this->owner&&!$this->trusted)$restriction='Only the PBX owner can request an office recovery.';
            elseif(!filter_var($source,FILTER_VALIDATE_IP,FILTER_FLAG_IPV4))$restriction='IPv6 office recovery needs an instance-administrator review. Automatic recovery currently supports the Debian IPv4 security filter.';
            elseif(!$verified)$restriction='No recent successful desk-phone connection proves that this office address belongs to your PBX. Ask the instance administrator to review it.';
            elseif($foreign)$restriction='This address is shared with another PBX. An instance administrator must review the affected offices.';
            elseif($r['log_status']!=='blocked'||$this->q("select 1 from v_pbx_phone_health_recoveries where block_uuid=? and status='pending'",[$r['event_guard_log_uuid']])->fetchColumn())$restriction='Recovery is waiting for the security service to confirm it.';
            elseif(count($rows)>2000)$restriction='The security history needs an instance-administrator review.';
            elseif($this->q("select 1 from v_event_guard_logs where hostname=? and ip_address=? and log_status in ('blocked','pending') and event_guard_log_uuid<>?",[gethostname(),$source,$r['event_guard_log_uuid']])->fetchColumn())$restriction='Another security block also affects this address. An instance administrator must review it.';
            elseif($this->q("select 1 from v_pbx_phone_health_recoveries where source_address=?::inet and created_at>now()-interval '15 minutes'",[$source])->fetchColumn())$restriction='A recovery was already requested recently. Wait 15 minutes before trying again.';
            $departments=[];foreach(array_keys($affected)as$n)foreach(pbx_departments::memberships($c,(string)$n)as$d)$departments[$d]=true;
            if($restriction===''&&count($departments)>1&&!$this->trusted&&!permission_exists('pbx_tenant_manage')&&!permission_exists('domain_all'))$restriction='This office address is shared across departments. Ask the instance administrator to review recovery.';
            ksort($affected);$revision=hash('sha256',json_encode([$r,$affected,$foreign],JSON_THROW_ON_ERROR));
            $out[]=['block_uuid'=>$r['event_guard_log_uuid'],'source_address'=>($this->owner||$this->trusted)?$source:null,'affected_numbers'=>$visible,'blocked_at'=>$r['log_date'],'reason'=>'Repeated sign-in failures caused the security service to block this office address.','can_recover'=>$restriction==='','revision'=>$revision,'restriction'=>$restriction,'status'=>$r['log_status']];
        }
        return $out;
    }
    private function build(array $c,?array $rows,array $directory): array {
        $online=[];
        foreach($rows??[]as$r)if(self::active($r)){$owners=$directory['identities'][$r['realm']."\0".$r['reg_user']]??[];if(count($owners)===1&&$owners[0]['domain_uuid']===$this->domain)$online[$owners[0]['extension_uuid']]=true;}
        $summary=['online'=>0,'offline'=>0,'disabled'=>0,'unavailable'=>0,'blocked_offices'=>0,'provider_failures'=>0,'issues'=>0];$phones=[];$candidates=[];$last=[];$missing=[];$unknown=[];
        foreach($this->q("select extension_uuid,max(last_seen) last_seen,max(missing_since) missing_since from v_pbx_phone_health_contacts where domain_uuid=? and last_seen>now()-interval '30 days' group by extension_uuid",[$this->domain])->fetchAll(PDO::FETCH_ASSOC)as$v){$last[$v['extension_uuid']]=$v['last_seen'];$missing[$v['extension_uuid']]=$v['missing_since'];}
        $native=[];foreach($this->q('select extension_uuid,enabled from v_extensions where domain_uuid=?',[$this->domain])->fetchAll(PDO::FETCH_ASSOC)as$v)$native[$v['extension_uuid']]=$v;
        $blocks=$this->blocks($c,$directory);$blocked=[];foreach($blocks as$b)foreach($b['affected_numbers']as$n)$blocked[$n]=true;
        foreach($c['users']as$n=>$u){
            $n=(string)$n;if(!preg_match('/^[0-9]{2,10}$/D',$n)||(!$this->trusted&&!$this->owner&&!$this->scope?->permits('phones',$n,$c)))continue;
            $id=$u['extension_uuid']??'';$enabled=self::on($u['enabled']??false)&&(!isset($native[$id])||self::on($native[$id]['enabled']));
            $state=!$enabled?'disabled':($rows===null||!isset($directory['extensions'][$id])?'unavailable':(isset($online[$id])?'online':'offline'));
            $reason=match($state){'disabled'=>'Calling is disabled for this user.','online'=>'A current authenticated phone or app connection is present.','offline'=>'No current phone or app connection is registered.','unavailable'=>'The running phone status or its saved identity could not be confirmed.'};
            $next=match($state){'disabled'=>'An administrator can enable this user when it is ready.','online'=>'Registration is healthy. A real call is still needed to confirm ringing and sound.','offline'=>'Check the phone has power and internet, then check its saved SIP host and password.','unavailable'=>'Refresh after the phone service is available. If it persists, ask the instance administrator to review the saved identity.'};
            if(isset($blocked[$n])){$reason='The security service reports a block affecting this phone’s office address.';$next='Review the office block below. Correct the phone’s saved address or password before requesting recovery.';}
            $summary[$state]++;$phone=['number'=>$n,'name'=>self::label($u['name']??null,'Extension '.$n),'state'=>$state,'label'=>match($state){'online'=>'Online','offline'=>'Offline','disabled'=>'Disabled',default=>'Status unavailable'},'reason'=>$reason,'next_step'=>$next,'call_status'=>pbx_mobile_state::profile($u,$c,$n),'last_seen'=>$last[$id]??null,'known_office'=>isset($last[$id])&&strtotime($last[$id])>time()-30*86400];$phones[]=$phone;
            if($state==='offline'&&isset($last[$id],$missing[$id])&&strtotime($missing[$id])<=time()-90)$candidates['phone:'.$n]=['kind'=>'phone_offline','severity'=>'warning','summary'=>'Extension '.$n.' is offline.','extra'=>['number'=>$n,'reason'=>isset($blocked[$n])?'office_blocked':'not_registered']];
            elseif($state==='unavailable')$candidates['identity:'.$n]=['kind'=>'phone_unavailable','severity'=>'warning','summary'=>'Extension '.$n.' needs a phone-status review.','extra'=>['number'=>$n]];
        }
        foreach($blocks as$b)$candidates['block:'.$b['block_uuid']]=['kind'=>'office_blocked','severity'=>'danger','summary'=>'A security block affects '.count($b['affected_numbers']).' phone account'.(count($b['affected_numbers'])===1?'':'s').'.','extra'=>['block_uuid'=>$b['block_uuid'],'numbers'=>$b['affected_numbers']]];
        $providers=[];$gateways=[];
        foreach($this->q("select gateway_uuid,enabled,register,coalesce(nullif(auth_username,''),username,'')<>'' has_username,coalesce(password,'')<>'' has_password from v_gateways where domain_uuid=?",[$this->domain])->fetchAll(PDO::FETCH_ASSOC)as$g)$gateways[$g['gateway_uuid']]=$g;
        $engineChecks=0;$engineDeadline=microtime(true)+3.0;
        foreach($c['trunks']??[]as$id=>$t){
            $id=(string)$id;if(!$this->trusted&&!$this->owner&&!$this->scope?->permits('providers',$id,$c))continue;
            $g=$gateways[$t['gateway_uuid']??'']??null;$runtime=['state'=>'unknown'];
            if($rows!==null&&$g&&self::on($g['enabled'])&&is_uuid($t['gateway_uuid']??'')&&$engineChecks<24&&microtime(true)<$engineDeadline)try{$engineChecks++;$reply=$this->engine('sofia xmlstatus gateway '.$t['gateway_uuid']);if(trim($reply)==='Invalid Gateway!')$reply=$this->engine('sofia xmlstatus gateway '.strtoupper($t['gateway_uuid']));$runtime=pbx_trunk_readiness::gatewayState($reply,$t['gateway_uuid']);}catch(Throwable){}
            $t['enabled']=$g&&self::on($g['enabled']);$description=pbx_trunk_readiness::describe($t,$g,$runtime);
            $state=match($description['status']){'Off'=>'off','Registered'=>'online','Configured'=>'configured','Connecting'=>'connecting','Connection failed','Not connected','Needs settings'=>'failed',default=>'unavailable'};
            $providers[]=['id'=>$id,'name'=>self::label($t['name']??null,'Voice provider'),'state'=>$state,'label'=>$description['status'],'reason'=>$description['issues'][0]??$description['next_step'],'next_step'=>$description['next_step']];
            if($state==='failed'){$summary['provider_failures']++;$candidates['provider:'.$id]=['kind'=>'provider_failed','severity'=>'danger','summary'=>'Voice provider '.self::label($t['name']??null,$id).' needs attention.','extra'=>['provider_id'=>$id,'status'=>$description['status']]];}
            elseif($state==='unavailable')$unknown[]='provider:'.$id;
        }
        $summary['blocked_offices']=count($blocks);$issues=[];$persisted=[];
        foreach($this->q('select issue_uuid,issue_key,kind,summary,extra,severity,first_seen,last_seen from v_pbx_phone_health_issues where domain_uuid=? and resolved_at is null',[$this->domain])->fetchAll(PDO::FETCH_ASSOC)as$v)$persisted[$v['issue_key']]=$v;
        foreach($candidates as$key=>$v){$p=$persisted[$key]??[];$issues[]=['issue_uuid'=>$p['issue_uuid']??null,'code'=>$key,'title'=>match($v['kind']){'office_blocked'=>'Office blocked','provider_failed'=>'Provider needs attention','phone_unavailable'=>'Phone status unavailable',default=>'Phone offline'},'message'=>$v['summary'],'tone'=>$v['severity'],'first_seen'=>$p['first_seen']??null,'last_seen'=>$p['last_seen']??null];}
        $visiblePhones=array_column($phones,null,'number');$visibleProviders=array_column($providers,null,'id');
        foreach($persisted as$key=>$p){
            if(isset($candidates[$key]))continue;
            $extra=json_decode($p['extra'],true,32,JSON_THROW_ON_ERROR);$keep=false;
            if($p['kind']==='provider_failed')$keep=isset($visibleProviders[$extra['provider_id']??''])&&($rows===null||in_array($key,$unknown,true));
            elseif(in_array($p['kind'],['phone_offline','phone_unavailable'],true))$keep=$rows===null&&isset($visiblePhones[$extra['number']??'']);
            if(!$keep)continue;
            if($p['kind']==='provider_failed')$summary['provider_failures']++;
            $issues[]=['issue_uuid'=>$p['issue_uuid'],'code'=>$key,'title'=>'Previously reported issue — status unavailable','message'=>$p['summary'].' Its recovery has not been confirmed.','tone'=>$p['severity'],'first_seen'=>$p['first_seen'],'last_seen'=>$p['last_seen']];
        }
        if($rows===null)$issues[]=['issue_uuid'=>$persisted['monitor:unavailable']['issue_uuid']??null,'code'=>'monitor:unavailable','title'=>'Live phone status unavailable','message'=>'Current registrations cannot be read. Previously reported incidents remain open.','tone'=>'danger','first_seen'=>$persisted['monitor:unavailable']['first_seen']??null,'last_seen'=>$persisted['monitor:unavailable']['last_seen']??null];
        $summary['issues']=count($issues);
        return ['checked_at'=>gmdate('c'),'available'=>$rows!==null&&$summary['unavailable']===0&&$unknown===[],'summary'=>$summary,'phones'=>$phones,'providers'=>$providers,'office_blocks'=>$blocks,'issues'=>$issues,'_candidates'=>$candidates,'_unknown_keys'=>$unknown];
    }
    public function snapshot(): array {
        $c=$this->context();if(!self::installed($this->db))throw new RuntimeException('Phone Health is not installed on this instance.');
        try{$rows=self::registrations($this->engine('show registrations as json'));}catch(Throwable){$rows=null;}
        $out=$this->build($c,$rows,self::directory($this->db));unset($out['_candidates'],$out['_unknown_keys']);
        $observer=$this->q('select checked_at,available from v_pbx_phone_health_state where domain_uuid=?',[$this->domain])->fetch(PDO::FETCH_ASSOC);
        $out['observer']=['checked_at'=>$observer['checked_at']??null,'fresh'=>$observer&&strtotime($observer['checked_at'])>=time()-self::FRESH_SECONDS,'available'=>$observer?self::on($observer['available']):false];
        $out['available']=$out['available']&&$out['observer']['fresh']&&$out['observer']['available'];
        $out['recoveries']=[];
        if($this->owner)foreach($this->q('select recovery_uuid,created_at requested_at,acknowledged_at,status,host(source_address) source_address from v_pbx_phone_health_recoveries where domain_uuid=? order by created_at desc,recovery_uuid limit 20',[$this->domain])->fetchAll(PDO::FETCH_ASSOC)as$r)$out['recoveries'][]=$r;
        return $out;
    }
    public function alertSettings(): array {
        $this->context();if(!$this->owner)throw new RuntimeException('PBX owner access is required.');
        return ['alerts_enabled'=>self::on($this->q('select alerts_enabled from v_pbx_phone_health_settings where domain_uuid=?',[$this->domain])->fetchColumn())];
    }
    public function saveAlertSettings(bool $enabled): void {
        $this->db->beginTransaction();try{$this->context();if(!$this->owner)throw new RuntimeException('PBX owner access is required.');
            $this->q('insert into v_pbx_phone_health_settings(domain_uuid,alerts_enabled,updated_by) values(?,?::boolean,?) on conflict(domain_uuid) do update set alerts_enabled=excluded.alerts_enabled,updated_by=excluded.updated_by,updated_at=now()',[$this->domain,$enabled?'true':'false',$this->actor]);
            $this->scope->audit('phone_health_alerts',$enabled?'enabled':'disabled');$this->db->commit();
        }catch(Throwable$e){if($this->db->inTransaction())$this->db->rollBack();throw$e;}
    }
    /** Explicit, one-office request. Completion is acknowledged by the separate security worker. */
    public function recover(string $blockUuid,string $revision,bool $confirmed=false): array {
        if(!$confirmed||!is_uuid($blockUuid)||!preg_match('/^[a-f0-9]{64}$/D',$revision))throw new InvalidArgumentException('Confirm the affected office and its corrected phone settings before requesting recovery.');
        $recovery=uuid();$this->db->beginTransaction();
        try{
            $this->db->exec("set local lock_timeout='3s';set local statement_timeout='8s'");
            $this->q("select pg_advisory_xact_lock(hashtext(?))",['openweb-phone-health:'.gethostname()]);
            $c=$this->context();if(!$this->owner)throw new RuntimeException('Only the PBX owner may request office recovery.');
            // Serialise against edited Event Guard rows and re-read all proof under the lock.
            $r=$this->q('select event_guard_log_uuid from v_event_guard_logs where event_guard_log_uuid=? for update',[$blockUuid])->fetchColumn();
            if(!$r)throw new RuntimeException('This security block is no longer available.');
            $chosen=null;foreach($this->blocks($c,self::directory($this->db))as$b)if($b['block_uuid']===$blockUuid)$chosen=$b;
            if(!$chosen||!hash_equals($chosen['revision'],$revision))throw new RuntimeException('This office block changed. Refresh before requesting recovery.');
            if(!$chosen['can_recover'])throw new RuntimeException($chosen['restriction']);
            $this->q("insert into v_pbx_phone_health_recoveries(recovery_uuid,domain_uuid,actor_uuid,block_uuid,source_address,status) values(?,?,?,?,?::inet,'pending')",[$recovery,$this->domain,$this->actor,$blockUuid,$chosen['source_address']]);
            // Keep the legacy ledger blocked. Legacy unblock events must never consume this request.
            $this->scope->audit('phone_health_recovery',$blockUuid,'pending');$this->db->commit();
        }catch(Throwable$e){if($this->db->inTransaction())$this->db->rollBack();throw$e;}
        try{$sent=$this->dispatch($blockUuid,$recovery);}catch(Throwable){$sent=false;}
        if(!$sent){
            // A lost reply may still have dispatched. Retain pending for idempotent retry.
            return ['status'=>'pending','message'=>'Recovery is saved, but the security service has not confirmed receipt. The health service will retry it.'];
        }
        return ['status'=>'pending','message'=>'Office recovery requested. Wait for the security service to confirm removal, then check that the phones reconnect.'];
    }
    /** Rechecked by the privileged worker, without borrowing a web session or trusting event data. */
    public static function recoveryRefusal(PDO $db,array $request,array $log): ?string {
        if(PHP_SAPI!=='cli')return 'local_service_required';
        $q=static function(string $sql,array $args=[])use($db):PDOStatement{$s=$db->prepare($sql);$s->execute($args);return$s;};
        if(!is_uuid($request['domain_uuid']??'')||!is_uuid($request['actor_uuid']??'')||!filter_var($log['ip_address']??null,FILTER_VALIDATE_IP))return 'invalid_request';
        if(!$q("select 1 from v_users where user_uuid=? and user_enabled='true'",[$request['actor_uuid']])->fetchColumn())return 'actor_unavailable';
        $owner=(bool)$q('select 1 from v_pbx_tenants t where t.enabled and t.owner_user_uuid=? and (t.home_domain_uuid=? or exists(select 1 from v_pbx_services s where s.tenant_uuid=t.tenant_uuid and s.domain_uuid=?))',[$request['actor_uuid'],$request['domain_uuid'],$request['domain_uuid']])->fetchColumn();
        $permissions=$q("select distinct gp.permission_name from v_user_groups ug join v_users u on u.user_uuid=ug.user_uuid join v_groups g on g.group_uuid=ug.group_uuid join v_group_permissions gp on gp.group_name=g.group_name where ug.user_uuid=? and (ug.domain_uuid=? or ug.domain_uuid=u.domain_uuid) and (gp.domain_uuid=ug.domain_uuid or gp.domain_uuid is null) and gp.permission_assigned='true'",[$request['actor_uuid'],$request['domain_uuid']])->fetchAll(PDO::FETCH_COLUMN);
        $manager=in_array('pbx_tenant_manage',$permissions,true);$platform=$manager||in_array('domain_all',$permissions,true);
        if(!in_array('pbx_service_create',$permissions,true)||(!$owner&&!$manager))return 'actor_no_longer_owner';
        $directory=self::directory($db);$c=$directory['domains'][$request['domain_uuid']]['config']??null;
        if(!$c)return 'pbx_unavailable';
        $history=$q("select domain_uuid,extension_uuid from v_pbx_phone_health_contacts where source_address=?::inet and last_seen>now()-interval '30 days'",[$log['ip_address']])->fetchAll(PDO::FETCH_ASSOC);$owned=[];
        foreach($history as$h){$e=$directory['extensions'][$h['extension_uuid']]??null;if(!$e)continue;if($e['domain_uuid']!==$request['domain_uuid'])return 'shared_with_another_pbx';$owned[]=$e;}
        if(!$owned)return 'no_verified_office';
        $departments=[];foreach($owned as$e)foreach(pbx_departments::memberships($c,$e['number'])as$d)$departments[$d]=true;
        if(count($departments)>1&&!$platform)return 'shared_departments';
        if($q("select 1 from v_event_guard_logs where hostname=? and ip_address=? and log_status in ('blocked','pending') and event_guard_log_uuid<>?",[$log['hostname'],$log['ip_address'],$log['event_guard_log_uuid']])->fetchColumn())return 'another_security_block';
        return null;
    }
    /** Local service scan. Unknown engine state never resolves existing phone incidents. */
    public static function monitor(PDO $db,?string $registrationsJson): array {
        if(PHP_SAPI!=='cli')throw new RuntimeException('Phone monitoring is a local service operation.');
        if(!self::installed($db))throw new RuntimeException('Phone Health is not installed.');
        $rows=null;$contacts=0;
        if($registrationsJson!==null)try{$rows=self::registrations($registrationsJson);$contacts=self::collect($db,$registrationsJson)['observed_contacts'];}catch(Throwable){$rows=null;}
        $directory=self::directory($db);$stats=['observed_contacts'=>$contacts,'checked_domains'=>0,'open'=>0,'new'=>0,'resolved'=>0,'queued'=>0,'available'=>$rows!==null];
        foreach($directory['domains']as$d=>$entry){
            $self=new self($db);$self->trusted=true;$self->owner=true;$self->domain=$d;$c=$entry['config'];
            $built=$self->build($c,$rows,$directory);$current=$built['_candidates'];$unknown=$built['_unknown_keys'];
            if($rows===null)$current['monitor:unavailable']=['kind'=>'status_unavailable','severity'=>'danger','summary'=>'Live phone status is unavailable. Existing incidents remain open.','extra'=>[]];
            $db->beginTransaction();try{
                $self->q('select pg_advisory_xact_lock(hashtext(?))',['openweb-phone-health-scan:'.$d]);
                $self->q('insert into v_pbx_phone_health_state(domain_uuid,checked_at,available,detail) values(?,now(),?::boolean,?) on conflict(domain_uuid) do update set checked_at=excluded.checked_at,available=excluded.available,detail=excluded.detail',[$d,$rows===null?'false':'true',$rows===null?'Phone status unavailable':'Checked']);
                $existing=[];foreach($self->q('select * from v_pbx_phone_health_issues where domain_uuid=? for update',[$d])->fetchAll(PDO::FETCH_ASSOC)as$issue)$existing[$issue['issue_key']]=$issue;
                foreach($current as$key=>$v){
                    // Malformed/unavailable engine status is not evidence that an enabled phone failed.
                    if($rows===null&&in_array($v['kind'],['phone_offline','phone_unavailable','provider_failed'],true))continue;
                    $prior=$existing[$key]??null;$opened=!$prior||$prior['resolved_at']!==null;$id=$prior['issue_uuid']??uuid();
                    $self->q("insert into v_pbx_phone_health_issues(issue_uuid,domain_uuid,issue_key,kind,severity,summary,extra) values(?,?,?,?,?,?,?::jsonb) on conflict(domain_uuid,issue_key) do update set kind=excluded.kind,severity=excluded.severity,summary=excluded.summary,extra=excluded.extra,last_seen=now(),first_seen=case when v_pbx_phone_health_issues.resolved_at is null then v_pbx_phone_health_issues.first_seen else now() end,resolved_at=null,acknowledged_at=case when v_pbx_phone_health_issues.resolved_at is null then v_pbx_phone_health_issues.acknowledged_at else null end,notified_at=case when v_pbx_phone_health_issues.resolved_at is null then v_pbx_phone_health_issues.notified_at else null end,resolved_notified_at=null",[$id,$d,$key,$v['kind'],$v['severity'],$v['summary'],json_encode($v['extra'],JSON_THROW_ON_ERROR)]);
                    if($opened)$stats['new']++;
                    if(class_exists('pbx_phone_health_mail')&&pbx_phone_health_mail::queue($db,['domain_uuid'=>$d,'issue_uuid'=>$id,'issue_key'=>$key,'kind'=>$v['kind'],'summary'=>$v['summary'],'state'=>'opened','first_seen'=>$prior['first_seen']??gmdate('c'),'last_seen'=>gmdate('c')]))$stats['queued']++;
                }
                if($rows!==null)foreach($existing as$key=>$prior)if($prior['resolved_at']===null&&!isset($current[$key])&&!in_array($key,$unknown,true)){
                    $self->q('update v_pbx_phone_health_issues set resolved_at=now(),last_seen=now() where domain_uuid=? and issue_key=?',[$d,$key]);$stats['resolved']++;
                    if(class_exists('pbx_phone_health_mail')&&pbx_phone_health_mail::queue($db,['domain_uuid'=>$d,'issue_uuid'=>$prior['issue_uuid'],'issue_key'=>$key,'kind'=>$prior['kind'],'summary'=>$prior['summary'],'state'=>'resolved','first_seen'=>$prior['first_seen'],'last_seen'=>gmdate('c')]))$stats['queued']++;
                }
                $stats['open']+=(int)$self->q('select count(*) from v_pbx_phone_health_issues where domain_uuid=? and resolved_at is null',[$d])->fetchColumn();$db->commit();$stats['checked_domains']++;
            }catch(Throwable$e){if($db->inTransaction())$db->rollBack();throw$e;}
        }
        // Idempotent, targeted retries only. A legacy worker must never consume these rows globally.
        $self=new self($db);
        $self->q("update v_pbx_phone_health_recoveries set status='refused' where status='pending' and created_at<=now()-interval '15 minutes'");
        foreach($self->q("select recovery_uuid,block_uuid from v_pbx_phone_health_recoveries where status='pending' and created_at>now()-interval '15 minutes' order by created_at limit 20")->fetchAll(PDO::FETCH_ASSOC)as$r)try{$self->dispatch($r['block_uuid'],$r['recovery_uuid']);}catch(Throwable){}
        return $stats;
    }
}
