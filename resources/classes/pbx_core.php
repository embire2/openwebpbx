<?php
/** Tenant-scoped call operations. Never accepts arbitrary engine commands. */
class pbx_core_access extends RuntimeException {}
class pbx_core {
    private PDO $db;
    private string $domain;
    private string $actor;
    public function __construct(?PDO $db=null){
        $this->db=$db??database::new()->db;$this->domain=(string)($_SESSION['domain_uuid']??'');$this->actor=(string)($_SESSION['user_uuid']??'');
        if(empty($_SESSION['authorized'])||!is_uuid($this->domain)||!is_uuid($this->actor)||!$this->allowed('pbx_core_view')||!$this->tenantAccess())throw new pbx_core_access('PBX access denied.');
        $this->config();
    }
    protected function allowed(string $name): bool {return permission_exists($name)||(new pbx_setup($this->db))->canManage();}
    protected function tenantAccess(): bool {return (new pbx_tenants($this->db))->canDomain($this->domain);}
    protected function engine(string $command): string {return (string)event_socket::api($command);}
    private function q(string $sql,array $args=[]): PDOStatement {$s=$this->db->prepare($sql);$s->execute($args);return $s;}
    private function config(bool $lock=false): array {
        $v=$this->q("select r.config from v_pbx_restore r join v_domains d using(domain_uuid) where r.domain_uuid=? and d.domain_enabled='true' and not exists(select 1 from v_pbx_services s join v_pbx_tenants t using(tenant_uuid) where s.domain_uuid=d.domain_uuid and not t.enabled)".($lock?' for update of r':''),[$this->domain])->fetchColumn();
        if(!$v)throw new RuntimeException('This PBX is unavailable.');$c=json_decode($v,true,512,JSON_THROW_ON_ERROR);if(!preg_match('/^[a-z0-9][a-z0-9.-]{0,252}$/D',$c['realm']??''))throw new RuntimeException('This PBX address needs review.');return $c;
    }
    private function text(array $in,string $name,int $limit=80): string {$v=$in[$name]??'';if(!is_string($v)||strlen($v)>$limit||preg_match('/[\x00-\x1f\x7f]/',$v))throw new InvalidArgumentException('Enter a valid '.str_replace('_',' ',$name).'.');return trim($v);}
    private function admin(): void {if(!(new pbx_setup($this->db))->canManage())throw new pbx_core_access('PBX administrator access required.');}
    public static function pipeRows(string $value): array {
        if(strlen($value)>262144||str_starts_with(trim($value),'-ERR'))return [];
        $lines=preg_split('/\r?\n/',trim($value));$keys=str_getcsv(array_shift($lines)??'','|','"','\\');$rows=[];
        if(!in_array('name',$keys,true)&&!in_array('uuid',$keys,true))return [];
        foreach(array_slice($lines,0,200) as $line){$v=str_getcsv($line,'|','"','\\');if(count($v)===count($keys))$rows[]=array_combine($keys,$v);}return $rows;
    }
    private function call(string $id): void {
        if(!is_uuid($id)||trim($this->engine('uuid_exists '.$id))!=='true'||trim($this->engine('uuid_getvar '.$id.' domain_uuid'))!==$this->domain)throw new OutOfBoundsException('This call has ended or is outside your PBX.');
    }
    public function live(): array {
        $c=$this->config();$raw=$this->engine('show channels as json');if(strlen($raw)>1048576)throw new RuntimeException('The live call list is too large. Try again shortly.');
        $data=json_decode($raw,true);if(is_array($data)&&!array_key_exists('rows',$data)&&in_array($data['row_count']??null,[0,'0'],true))$data['rows']=[];
        if(!is_array($data)||!is_array($data['rows']??null))throw new RuntimeException('The calling service is unavailable.');
        $calls=[];$busy=[];
        foreach(array_slice($data['rows'],0,256) as $r){$id=(string)($r['uuid']??'');if(!is_uuid($id)||trim($this->engine('uuid_getvar '.$id.' domain_uuid'))!==$this->domain)continue;
            $number='';foreach($c['users'] as $n=>$u)if(($r['presence_id']??'')===$u['auth_id'].'@'.$c['realm']||($r['presence_id']??'')===$n.'@'.$c['realm']){$number=(string)$n;$busy[$number]=true;break;}
            $calls[]=['id'=>$id,'from'=>(string)($r['cid_num']??''),'name'=>(string)($r['cid_name']??''),'to'=>(string)($r['dest']??''),'user'=>$number,'state'=>(string)($r['callstate']??$r['state']??''),'started'=>(int)($r['created_epoch']??0),'parked'=>str_starts_with((string)($r['application']??''),'valet_park')];
        }
        $people=[];foreach($c['users'] as $n=>$u){if(empty($u['enabled']))continue;$state=pbx_mobile_state::profile($u,$c,(string)$n);$people[]=['number'=>(string)$n,'name'=>$u['name'],'status'=>isset($busy[$n])?'On a call':$state];}
        $queues=[];foreach($c['queues'] as $q){$members=self::pipeRows($this->engine('callcenter_config queue list members '.$q['number'].'@'.$c['realm']));$waiting=0;$longest=0;foreach($members as $m)if(in_array($m['state']??'',['Waiting','Trying'],true)){$waiting++;$longest=max($longest,time()-(int)($m['system_epoch']??time()));}
            $agents=[];foreach($q['members'] as $m){if(!is_uuid($m['agent_uuid']??''))continue;$row=self::pipeRows($this->engine('callcenter_config agent list '.$m['agent_uuid']));$r=$row[0]??[];$agents[]=['number'=>(string)$m['number'],'name'=>$c['users'][$m['number']]['name']??$m['number'],'status'=>$r['status']??'Unavailable','state'=>$r['state']??'Unknown','joined'=>($m['status']??'LoggedOut')==='LoggedIn'];}
            $queues[]=['number'=>(string)$q['number'],'name'=>$q['name'],'waiting'=>$waiting,'longest_wait'=>$longest,'agents'=>$agents,'target_seconds'=>(int)($q['service_target']??60),'alert'=>$waiting>0&&$longest>(int)($q['service_target']??60)];
        }
        return ['server_time'=>gmdate('c'),'calls'=>$calls,'people'=>$people,'queues'=>$queues,'can_control'=>$this->allowed('pbx_core_control'),'can_supervise'=>$this->allowed('pbx_core_supervise'),'parking_enabled'=>!empty($c['parking_enabled'])];
    }
    public function control(array $in): string {
        if(!$this->allowed('pbx_core_control'))throw new pbx_core_access('Call-control permission required.');
        $c=$this->config();$id=$this->text($in,'call',36);$action=$this->text($in,'operation',24);$target=$this->text($in,'target',20);$this->call($id);
        if(!in_array($action,['hold','resume','transfer','pickup','park','end'],true))throw new InvalidArgumentException('Choose a call action.');
        if(in_array($action,['transfer','pickup'],true)){if(!isset($c['users'][$target])||empty($c['users'][$target]['enabled']))throw new InvalidArgumentException('Choose an enabled user in your PBX.');}
        if($action==='park'&&(!ctype_digit($target)||(int)$target<1||(int)$target>20))throw new InvalidArgumentException('Choose parking space 1 to 20.');
        $command='lua app/pbx_setup/core_control.lua '.$this->domain.' '.$id.' '.$action.' '.($target?:'-');
        $result=trim($this->engine($command));$ok=str_starts_with($result,'+OK');
        $this->q('insert into v_pbx_core_audit(audit_uuid,domain_uuid,actor_uuid,action,call_uuid,target,result) values(?,?,?,?,?,?,?)',[uuid(),$this->domain,$this->actor,$action,$id,$target,$ok?'accepted':'failed']);
        if(!$ok)throw new RuntimeException('The call changed before this action completed. Refresh and try again.');return 'Call updated.';
    }
    public function agent(array $in): string {
        if(!$this->allowed('pbx_core_supervise'))throw new pbx_core_access('Queue-supervisor permission required.');
        $queue=$this->text($in,'queue',10);$number=$this->text($in,'number',10);$state=$this->text($in,'agent_state',12);
        if(!in_array($state,['ready','break','logout'],true))throw new InvalidArgumentException('Choose Ready, Break or Sign Out.');
        $this->db->beginTransaction();try{$c=$this->config(true);$found=false;
            foreach($c['queues'] as $i=>$q)if((string)$q['number']===$queue)foreach($q['members'] as $j=>$m)if((string)$m['number']===$number&&isset($c['users'][$number])&&!empty($c['users'][$number]['enabled'])){
                $c['queues'][$i]['members'][$j]['supervisor_break']=$state==='break';$c['queues'][$i]['members'][$j]['status']=$state==='logout'?'LoggedOut':'LoggedIn';$found=true;
            }
            if(!$found)throw new OutOfBoundsException('Choose an assigned agent in this PBX.');
            $this->q('update v_pbx_restore set config=?::jsonb where domain_uuid=?',[json_encode($c,JSON_THROW_ON_ERROR),$this->domain]);$this->db->commit();
        }catch(Throwable $e){if($this->db->inTransaction())$this->db->rollBack();throw $e;}
        $result=trim($this->engine('lua app/pbx_setup/mobile_state.lua '.$this->domain.' '.$number));
        $this->q('insert into v_pbx_core_audit(audit_uuid,domain_uuid,actor_uuid,action,target,result) values(?,?,?,?,?,?)',[uuid(),$this->domain,$this->actor,'agent_'.$state,$queue.'/'.$number,str_starts_with($result,'+OK')?'accepted':'pending']);
        return str_starts_with($result,'+OK')?'Agent updated.':'Agent preference saved. The calling service will apply it when available.';
    }
    public function saveRules(array $in): void {
        $this->admin();$blocked=$this->text($in,'blocked_numbers',2000);$numbers=[];foreach(preg_split('/[ ,]+/',$blocked,-1,PREG_SPLIT_NO_EMPTY) as $n){if(!preg_match('/^\+?[0-9]{1,32}$/D',$n))throw new InvalidArgumentException('Enter blocked phone numbers separated by commas.');$numbers[]=$n;}
        $emergency=$this->text($in,'emergency_numbers',250);$emergencyNumbers=[];foreach(preg_split('/[ ,]+/',$emergency,-1,PREG_SPLIT_NO_EMPTY) as $n){if(!preg_match('/^[0-9]{2,10}$/D',$n))throw new InvalidArgumentException('Enter emergency numbers separated by commas.');$emergencyNumbers[]=$n;}
        $this->db->beginTransaction();try{$c=$this->config(true);foreach($emergencyNumbers as $n)if(isset($c['users'][$n]))throw new InvalidArgumentException('An emergency number cannot also be a user extension.');$routes=[];if(!is_array($in['emergency_routes']??[]))throw new InvalidArgumentException('Choose emergency providers.');foreach($in['emergency_routes']??[] as $r){if(!is_array($r)||empty($r['trunk_id']))continue;if(!isset($c['trunks'][$r['trunk_id']]))throw new InvalidArgumentException('Choose an emergency provider from this PBX.');$cid=$this->text($r,'caller_id',32);if($cid!==''&&!preg_match('/^\+?[0-9]{1,32}$/D',$cid))throw new InvalidArgumentException('Enter your provider-approved location phone number.');$routes[]=['trunk_id'=>$r['trunk_id'],'strip'=>0,'prepend'=>'','caller_id'=>$cid];}
            if($emergencyNumbers&&!$routes)throw new InvalidArgumentException('Choose a provider for emergency calls.');if(count($routes)>3)throw new InvalidArgumentException('Choose up to three emergency providers.');
            $c['calling_rules']=['blocked_numbers'=>array_values(array_unique($numbers)),'block_anonymous'=>!empty($in['block_anonymous']),'emergency_numbers'=>array_values(array_unique($emergencyNumbers)),'emergency_routes'=>$routes,'emergency_location'=>$this->text($in,'emergency_location',200)];
            $this->q('update v_pbx_restore set config=?::jsonb where domain_uuid=?',[json_encode($c,JSON_THROW_ON_ERROR),$this->domain]);$this->db->commit();
        }catch(Throwable $e){if($this->db->inTransaction())$this->db->rollBack();throw $e;}
    }
    public function firstCalls(string $trunk): array {
        $c=$this->config();if(!isset($c['trunks'][$trunk]))throw new OutOfBoundsException('Choose a provider in this PBX.');
        $checks=$this->q('select check_kind,result,note,created_at from v_pbx_core_checks where domain_uuid=? and trunk_id=? and config_hash=? order by created_at desc limit 30',[$this->domain,$trunk,$this->fingerprint($c,$trunk)])->fetchAll(PDO::FETCH_ASSOC);
        $calls=$this->q("select xml_cdr_uuid,direction,caller_id_number,destination_number,billsec,start_stamp,hangup_cause,read_codec,write_codec from v_xml_cdr where domain_uuid=? and start_stamp>now()-interval '24 hours' and (leg='a' or leg is null) order by start_stamp desc limit 30",[$this->domain])->fetchAll(PDO::FETCH_ASSOC);
        return ['checks'=>$checks,'calls'=>$calls];
    }
    public function callPlan(array $in): array {
        $this->admin();$c=$this->config();$trunk=$this->text($in,'trunk',40);$owner=$this->text($in,'test_phone',10);$number=$this->text($in,'test_number',32);
        if(!isset($c['trunks'][$trunk])||!isset($c['users'][$owner])||empty($c['users'][$owner]['enabled']))throw new InvalidArgumentException('Choose a provider and an enabled phone in this PBX.');
        if(!preg_match('/^\+?[0-9]{2,32}$/D',$number))throw new InvalidArgumentException('Enter a normal outside test number.');
        $raw=$this->engine('lua app/pbx_setup/core_call_plan.lua '.$this->domain.' '.$owner.' '.$number);
        $plan=strlen($raw)<=65536?json_decode($raw,true):null;
        if(!is_array($plan)||!is_array($plan['routes']??null))throw new RuntimeException('The calling service could not check this route.');
        if(!empty($plan['error']))throw new InvalidArgumentException((string)$plan['error']);
        if(empty($plan['registered']))throw new InvalidArgumentException('Connect the chosen phone before starting the test.');
        if(($plan['provider']??'')!==$trunk)throw new InvalidArgumentException('This number currently uses another provider. Review Outbound Rules or choose that provider before testing.');
        return ['trunk'=>$trunk,'phone'=>$owner,'number'=>$number,'rule'=>(string)($plan['rule']??''),'routes'=>$plan['routes']];
    }
    public function startCallTest(array $in): string {
        $plan=$this->callPlan($in);if(empty($in['confirm_test']))throw new InvalidArgumentException('Confirm that you want to call this outside test number.');
        $id=uuid();$this->db->beginTransaction();try{
            $this->q('select pg_advisory_xact_lock(hashtextextended(?,0))',['first-call/'.$this->domain]);
            if($this->q("select 1 from v_pbx_core_audit where domain_uuid=? and action='first_call_test' and created_at>now()-interval '4 minutes' limit 1",[$this->domain])->fetchColumn())throw new RuntimeException('A first-call test was recently started. Wait four minutes before starting another.');
            $this->q('insert into v_pbx_core_audit(audit_uuid,domain_uuid,actor_uuid,action,call_uuid,target,result) values(?,?,?,?,?,?,?)',[$id,$this->domain,$this->actor,'first_call_test',$id,$plan['phone'].'/'.$plan['number'],'starting']);$this->db->commit();
        }catch(Throwable $e){if($this->db->inTransaction())$this->db->rollBack();throw $e;}
        $result=trim($this->engine('luarun app/pbx_setup/core_call_test.lua '.$this->domain.' '.$plan['trunk'].' '.$plan['phone'].' '.$plan['number'].' '.$id));
        if(!str_starts_with($result,'+OK')){$this->q("update v_pbx_core_audit set result='failed' where audit_uuid=? and domain_uuid=?",[$id,$this->domain]);throw new RuntimeException('The calling service could not start the test.');}
        return 'Answer the chosen phone. Your ordinary outgoing rule will then call the test number; the call ends within three minutes. Record the result after checking both phones.';
    }
    private function fingerprint(array $c,string $trunk): string {
        $routes=array_values(array_filter($c['outbound_rules'],fn($r)=>count(array_filter($r['routes']??[],fn($r)=>$r['trunk_id']===$trunk))>0));$providers=[$trunk=>$c['trunks'][$trunk]];
        foreach($routes as $rule)foreach($rule['routes'] as $r)if(isset($c['trunks'][$r['trunk_id']]))$providers[$r['trunk_id']]=$c['trunks'][$r['trunk_id']];ksort($providers);$native=[];
        foreach($providers as $id=>$provider)$native[$id]=$this->q('select enabled,username,auth_username,password,realm,proxy,register_proxy,outbound_proxy,register,register_transport,expire_seconds,codec_prefs,from_user,from_domain,extension,extension_in_contact,caller_id_in_from,sip_cid_type from v_gateways where domain_uuid=? and gateway_uuid=?',[$this->domain,$provider['gateway_uuid']])->fetch(PDO::FETCH_ASSOC);
        $key=@file_get_contents(pbx_paths::key());if(!is_string($key)||strlen($key)<32)throw new RuntimeException('The instance encryption key is unavailable. Ask your administrator to repair it.');
        return hash_hmac('sha256',json_encode([gethostname(),pbx_paths::host(),pbx_paths::address(),$providers,$native,array_values(array_filter($c['inbound_rules'],fn($r)=>$r['trunk_id']===$trunk)),$routes],JSON_THROW_ON_ERROR),$key);
    }
    public function recordCheck(array $in): void {
        $this->admin();$c=$this->config();$trunk=$this->text($in,'trunk',40);$kind=$this->text($in,'check_kind',24);$id=$this->text($in,'call_uuid',36);
        if(!isset($c['trunks'][$trunk])||!in_array($kind,['internal','incoming','outgoing','digits','caller_id','failover','long_call'],true))throw new InvalidArgumentException('Choose the provider and test step.');
        if(!is_uuid($id))throw new InvalidArgumentException('Select the completed test call.');
        $call=$this->q('select direction,billsec,hangup_cause,provider_uuid,last_arg,call_center_queue_uuid from v_xml_cdr where domain_uuid=? and xml_cdr_uuid=? and start_stamp>now()-interval \'24 hours\'',[ $this->domain,$id])->fetch(PDO::FETCH_ASSOC);
        if(!$call||(int)$call['billsec']<=0)throw new InvalidArgumentException('Use an answered call from this PBX within the last 24 hours.');
        if(in_array($kind,['incoming','outgoing','failover'],true)&&$call['direction']!==($kind==='incoming'?'inbound':'outbound'))throw new InvalidArgumentException('Select a call in the required direction.');
        if($kind==='internal'&&$call['direction']!=='local')throw new InvalidArgumentException('Select an internal call for this step.');
        $providers=[$c['trunks'][$trunk]['gateway_uuid']];if($kind==='failover'){$providers=[];foreach($c['outbound_rules'] as $rule){$selected=false;foreach($rule['routes']??[] as $r){if($r['trunk_id']===$trunk){$selected=true;continue;}if($selected&&isset($c['trunks'][$r['trunk_id']]))$providers[]=$c['trunks'][$r['trunk_id']]['gateway_uuid'];}}}
        if($kind!=='internal'&&!array_filter($providers,fn($id)=>($call['provider_uuid']??'')===$id||str_contains((string)($call['last_arg']??''),$id)))throw new InvalidArgumentException($kind==='failover'?'Select an answered outside call identifying a configured backup after this provider.':'This call does not identify the selected provider. Keep this step unverified until the provider call is recorded.');
        if(empty($in['confirmed']))throw new InvalidArgumentException('Confirm the result on the actual phones.');
        if($kind==='long_call'&&(int)$call['billsec']<300)throw new InvalidArgumentException('Use a test call lasting at least five minutes.');
        $note=$this->text($in,'note',500);$this->q('insert into v_pbx_core_checks(check_uuid,domain_uuid,trunk_id,check_kind,call_uuid,result,note,checked_by,config_hash) values(?,?,?,?,?,?,?,?,?)',[uuid(),$this->domain,$trunk,$kind,$id,'confirmed',$note,$this->actor,$this->fingerprint($c,$trunk)]);
    }
    public function queueReport(int $days=1): array {
        $days=max(1,min(31,$days));$c=$this->config();$rows=[];
        foreach($c['queues'] as $queue){$q=(string)$queue['number'];$r=$this->q("select count(*) filter(where state in ('finished','abandoned')) total,count(*) filter(where state='finished') answered,count(*) filter(where state='abandoned') abandoned,coalesce(round(avg(wait_seconds) filter(where state='finished')),0) average_wait from v_pbx_queue_tickets where domain_uuid=? and queue_number=? and joined_at>now()-(? * interval '1 day')",[$this->domain,$q,$days])->fetch(PDO::FETCH_ASSOC);
            $jobs=$this->q("select count(*) filter(where state='completed') completed,count(*) filter(where state='failed') failed,count(*) filter(where state in ('waiting','starting','calling')) pending from v_pbx_jobs where domain_uuid=? and queue_number=? and kind='callback' and created_at>now()-(? * interval '1 day')",[$this->domain,$q,$days])->fetch(PDO::FETCH_ASSOC);
            $rows[]=['number'=>$q,'name'=>$queue['name'],'calls'=>$r,'callbacks'=>$jobs];
        }return ['days'=>$days,'timezone'=>$c['timezone']??'UTC','queues'=>$rows];
    }
    public function preview(array $in): array {
        $c=$this->config();$choice=$this->text($in,'object',80);$time=$this->text($in,'preview_time',16);$zone=new DateTimeZone($c['timezone']??'UTC');$clock=$time===''?(new DateTimeImmutable)->setTimezone($zone):DateTimeImmutable::createFromFormat('!Y-m-d\TH:i',$time,$zone);
        if(!$clock||($time!==''&&$clock->format('Y-m-d\TH:i')!==$time))throw new InvalidArgumentException('Choose a valid date and time.');
        [$kind,$number]=array_pad(explode(':',$choice,2),2,'');$destination=null;$label='';$dept=null;
        if($kind==='user'&&isset($c['users'][$number])){$u=$c['users'][$number];$status=pbx_mobile_state::profile($u,$c,$number,$clock->getTimestamp());$profile=$u['profiles'][$status];$dept=pbx_schedule::department($c,$number);$label=$u['name'].' · '.$number;$destination=!empty($profile['away'])?($profile['away']['External']['all']??['type'=>'EndCall']):['type'=>'Extension','number'=>$number];}
        elseif($kind==='incoming'){foreach($c['inbound_rules'] as $r)if($r['rule_id']===$number){$destination=$r['office'];$dept=pbx_schedule::department($c,(string)($r['office_department']??$destination['number']??''));$office=$dept?pbx_schedule::office($dept,$c['timezone'],$clock->getTimestamp()):['open'=>true,'break'=>false,'holiday'=>false];if(($r['hours']['type']??'OfficeHours')!=='OfficeHours')$office['open']=pbx_schedule::inside($r['hours'],(int)$clock->format('w'),$clock->format('H:i'));if($office['holiday']&&!empty($r['use_holiday']))$destination=$r['holiday'];elseif(!$office['open']&&!empty($r['use_outside']))$destination=$r['outside'];$label=$r['number']?:'Main number';break;}}
        else throw new InvalidArgumentException('Choose a user or incoming number in this PBX.');
        if($destination===null)throw new OutOfBoundsException('This item is not in your PBX.');
        $office=$dept?pbx_schedule::office($dept,$c['timezone'],$clock->getTimestamp()):['open'=>true,'break'=>false,'holiday'=>false];$type=$destination['type']??'None';$n=(string)($destination['number']??'');
        $name=match($type){'Extension'=>($c['users'][$n]['name']??$n).' · '.$n,'VoiceMail'=>'Voicemail for '.($c['users'][$n]['name']??$n),'External'=>'Outside number '.($destination['external']??''),'None','EndCall'=>'End call',default=>$type.' '.$n};
        return ['label'=>$label,'time'=>$clock->format('D j M Y H:i T'),'office'=>$office['open']?'Open':($office['holiday']?'Holiday':($office['break']?'Break':'Closed')),'destination'=>$name];
    }
    public function network(): array {
        $this->admin();$host=pbx_paths::host();$ip=pbx_paths::address();$addresses=[];foreach(@dns_get_record($host,DNS_A|DNS_AAAA)?:[] as $r)$addresses[]=$r['ip']??$r['ipv6']??'';
        $dns=['name'=>'Server address','ok'=>in_array($ip,$addresses,true),'details'=>in_array($ip,$addresses,true)?'Your hostname points to the configured public address.':'The hostname and public address differ. Check DNS and the instance public address.'];
        $ctx=stream_context_create(['ssl'=>['verify_peer'=>true,'verify_peer_name'=>true,'peer_name'=>$host,'SNI_enabled'=>true]]);$errno=0;$error='';$tls=@stream_socket_client('tls://'.$host.':5061',$errno,$error,2,STREAM_CLIENT_CONNECT,$ctx);$ok=is_resource($tls);if($ok)fclose($tls);
        return [$dns,['name'=>'Phone connection','ok'=>$ok,'details'=>$ok?'The encrypted phone listener and trusted certificate respond.':'The encrypted phone listener did not pass. Check the certificate and port 5061.'],['name'=>'Remote audio','ok'=>null,'details'=>'Use the incoming and outgoing phone tests below. A server connection check cannot prove that audio passes a remote firewall.']];
    }
}
