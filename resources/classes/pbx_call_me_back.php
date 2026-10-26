<?php
/** Owner-managed, tenant-scoped Call Me Back accounts. Callers also enforce CSRF. */
class pbx_call_me_back {
    private PDO $db;
    private string $domain;
    private string $actor;
    private string $subject='';

    public function __construct(?PDO $db=null) {
        $this->db=$db??database::new()->db;
        $this->domain=(string)($_SESSION['domain_uuid']??'');
        $this->actor=(string)($_SESSION['user_uuid']??'');
        $this->requireOwner();
    }

    private function requireOwner(): void {
        if(!is_uuid($this->domain)||!is_uuid($this->actor)||$this->domain!==($_SESSION['domain_uuid']??null)||$this->actor!==($_SESSION['user_uuid']??null)||!(new pbx_staff_access($this->db))->owner())throw new RuntimeException('PBX owner access is required for Call Me Back.');
    }

    private function q(string $sql,array $args=[]): PDOStatement {
        $s=$this->db->prepare($sql);
        foreach($args as$k=>$v)$s->bindValue(':'.$k,$v,$v===null?PDO::PARAM_NULL:(is_bool($v)?PDO::PARAM_BOOL:(is_int($v)?PDO::PARAM_INT:PDO::PARAM_STR)));
        $s->execute();return $s;
    }

    private function text(array $in,string $key,int $max=120): string {
        $v=$in[$key]??'';
        if(!is_string($v)||mb_strlen($v)>$max||preg_match('/[\x00-\x1f\x7f]/',$v))throw new InvalidArgumentException('Enter a valid '.str_replace('_',' ',$key).'.');
        return trim($v);
    }

    private function id(array $in,string $key,bool $new=false): string {
        $id=$this->text($in,$key,36);
        if($new&&($id===''||$id==='new'))return '';
        if(!is_uuid($id))throw new InvalidArgumentException('Choose an item from this PBX.');
        return $id;
    }

    private function checked(array $in,string $key): bool {
        if(!isset($in[$key]))return false;
        if(!in_array($in[$key],['1',1,true],true))throw new InvalidArgumentException('Choose a valid '.str_replace('_',' ',$key).'.');
        return true;
    }

    protected function key(): string {
        $key=@file_get_contents(pbx_paths::key());
        if(!is_string($key)||strlen($key)!==32)throw new RuntimeException('Private account authentication is unavailable. Ask your instance administrator to check its key.');
        return $key;
    }

    /** Validate syntax/date/checksum without retaining the original identity number. */
    public static function validSouthAfricanId(string $id): bool {
        if(!preg_match('/^[0-9]{13}$/D',$id)||!in_array($id[10],['0','1'],true)||!in_array($id[11],['8','9'],true))return false;
        $year=2000+(int)substr($id,0,2);$month=(int)substr($id,2,2);$day=(int)substr($id,4,2);
        if(sprintf('%04d-%02d-%02d',$year,$month,$day)>gmdate('Y-m-d'))$year-=100;
        if(!checkdate($month,$day,$year))return false;
        $sum=0;
        for($i=0;$i<13;$i++){$digit=(int)$id[$i];if($i%2===1){$digit*=2;if($digit>9)$digit-=9;}$sum+=$digit;}
        return $sum%10===0;
    }

    public static function identityHash(string $domain,string $id,string $key): string {
        if(!is_uuid($domain)||strlen($key)!==32||!self::validSouthAfricanId($id))throw new InvalidArgumentException('Enter a valid South African ID number.');
        $tenantKey=hash_hmac('sha256',"openweb-call-me-back-id/v1\0".$domain,$key,true);
        return hash_hmac('sha256',$id,$tenantKey);
    }

    /** Validate the fixed callback audio against the installed, versioned pack marker. */
    public static function promptPackReady(string $root): bool {
        $base=rtrim(str_replace('\\','/',$root),'/').'/openwebpbx';$marker=$base.'/voice-pack.json';
        if(is_link($marker)||!is_file($marker)||filesize($marker)>4194304)return false;
        try{$pack=json_decode((string)file_get_contents($marker),true,512,JSON_THROW_ON_ERROR);}catch(Throwable){return false;}
        if(($pack['version']??'')!=='1.0.2'||($pack['voice_id']??'')!=='i8SlcaZfyeP1st7wHsjM')return false;
        foreach(['incoming-new','incoming-known','authenticated','enter-number','invalid-id','unavailable','invalid-number','quota-exhausted']as$name){
            $relative='openwebpbx/voices/1.0.2/call-me-back/'.$name.'.wav';$file=rtrim($root,'/\\').'/'.$relative;
            $hash=$pack['files'][$relative]['sha256']??'';
            if(!is_string($hash)||!preg_match('/^[a-f0-9]{64}$/D',$hash)||is_link($file)||!is_file($file)||!hash_equals($hash,hash_file('sha256',$file)))return false;
        }
        return true;
    }
    protected function voicePackReady(): bool {return self::promptPackReady((string)config::load()->get('switch.sounds.dir'));}

    public function installed(): bool {
        $this->requireOwner();
        return (bool)$this->q("select to_regclass('v_pbx_cmb_services') is not null and to_regclass('v_pbx_cmb_accounts') is not null and to_regclass('v_pbx_cmb_bindings') is not null and to_regclass('v_pbx_cmb_requests') is not null and to_regclass('v_pbx_cmb_audit') is not null")->fetchColumn();
    }

    public function dashboard(): array {
        $this->requireOwner();
        if(!$this->installed())return ['installed'=>false,'services'=>[],'accounts'=>[],'bindings'=>[],'recent_attempts'=>[]];
        return [
            'installed'=>true,'voice_pack_ready'=>$this->voicePackReady(),
            'services'=>$this->q('select service_uuid,name,incoming_rule_uuid,route_owner,enabled,prompt_version,prompt_state,prompt_refresh_state,prompt_refresh_message,prompt_refresh_attempts,max_requests_hour,retention_days,array_to_json(destination_prefixes)::text destination_prefixes from v_pbx_cmb_services where domain_uuid=:d order by name,service_uuid',['d'=>$this->domain])->fetchAll(PDO::FETCH_ASSOC),
            'accounts'=>$this->q('select a.account_uuid,a.service_uuid,a.name,a.id_last4,a.total_seconds,a.used_seconds,a.reserved_seconds,a.enabled,s.name service_name from v_pbx_cmb_accounts a join v_pbx_cmb_services s on s.service_uuid=a.service_uuid and s.domain_uuid=a.domain_uuid where a.domain_uuid=:d order by a.name,a.account_uuid',['d'=>$this->domain])->fetchAll(PDO::FETCH_ASSOC),
            'bindings'=>$this->q('select b.binding_uuid,b.account_uuid,b.phone_number,b.authenticated_at,b.revoked_at from v_pbx_cmb_bindings b join v_pbx_cmb_accounts a on a.account_uuid=b.account_uuid and a.domain_uuid=b.domain_uuid where b.domain_uuid=:d and b.revoked_at is null order by b.authenticated_at desc limit 300',['d'=>$this->domain])->fetchAll(PDO::FETCH_ASSOC),
            'recent_attempts'=>$this->q('select r.request_uuid,r.service_uuid,r.account_uuid,r.caller_number,r.state,r.used_seconds,r.reserved_seconds,r.created_at,r.last_result,a.name account_name,s.name service_name from v_pbx_cmb_requests r join v_pbx_cmb_services s on s.service_uuid=r.service_uuid and s.domain_uuid=r.domain_uuid left join v_pbx_cmb_accounts a on a.account_uuid=r.account_uuid and a.domain_uuid=r.domain_uuid where r.domain_uuid=:d order by r.created_at desc,r.request_uuid desc limit 100',['d'=>$this->domain])->fetchAll(PDO::FETCH_ASSOC),
        ];
    }

    public function action(array $in): string {
        $this->requireOwner();
        if(!$this->installed())throw new RuntimeException('Install the Call Me Back database update before saving settings.');
        if($this->db->inTransaction())throw new LogicException('Call Me Back needs its own transaction.');
        $action=$this->text($in,'cmb_action',30);
        $this->db->beginTransaction();
        try {
            $this->subject='';
            // Serialize owner edits and refresh the currently-owned routing configuration.
            $c=(new pbx_admin($this->db))->config(true);
            $message=match($action){
                'save_service'=>$this->saveService($in,$c),
                'retry_voice'=>$this->retryVoice($in),
                'save_account'=>$this->saveAccount($in),
                'revoke_binding'=>$this->revokeBinding($in),
                'disable_account'=>$this->disableAccount($in),
                'delete_account'=>$this->deleteAccount($in),
                'cancel_request'=>$this->cancelRequest($in),
                default=>throw new InvalidArgumentException('Choose a Call Me Back action.'),
            };
            if(!is_uuid($this->subject))throw new LogicException('The account change could not be recorded.');
            $this->q('insert into v_pbx_cmb_audit(domain_uuid,actor_uuid,action,subject_uuid) values(:d,:actor,:action,:subject)',['d'=>$this->domain,'actor'=>$this->actor,'action'=>$action,'subject'=>$this->subject]);
            $this->db->commit();return $message;
        }catch(Throwable $e){if($this->db->inTransaction())$this->db->rollBack();throw $e;}
    }

    /** Used by the trunk editor inside its already-locked routing transaction. */
    public function routeIncoming(array $c,string $rule,?string $selected,bool $confirmed): void {
        $this->requireOwner();
        if(!$this->db->inTransaction())throw new LogicException('Lock incoming routing before changing Call Me Back.');
        $saved=$this->q('select *,array_to_json(destination_prefixes)::text prefixes from v_pbx_cmb_services where domain_uuid=:d and incoming_rule_uuid=:rule for update',['d'=>$this->domain,'rule'=>$rule])->fetch(PDO::FETCH_ASSOC);
        if($selected!==null&&(!$saved||$selected!==$saved['service_uuid']))throw new InvalidArgumentException('Set up Call Me Back for this incoming number first.');
        if(!$saved||($selected===null&&!$saved['enabled']))return;
        $enabling=$selected!==null;
        if($enabling===(bool)$saved['enabled'])return;
        if(!$confirmed)throw new InvalidArgumentException('Confirm the change to Call Me Back for this number.');
        $input=['service_uuid'=>$saved['service_uuid'],'service_name'=>$saved['name'],'incoming_rule_uuid'=>$rule,'route_owner'=>$saved['route_owner'],'max_requests_hour'=>$saved['max_requests_hour'],'retention_days'=>$saved['retention_days'],'destination_prefixes'=>implode(',',json_decode($saved['prefixes'],true,512,JSON_THROW_ON_ERROR)),'confirm_handover'=>'1'];
        if($enabling){$input['enabled']='1';$this->saveService($input,$c);}
        else $this->q('update v_pbx_cmb_services set enabled=false,updated_at=now() where domain_uuid=:d and service_uuid=:id',['d'=>$this->domain,'id'=>$saved['service_uuid']]);
        $this->q('insert into v_pbx_cmb_audit(domain_uuid,actor_uuid,action,subject_uuid) values(:d,:actor,:action,:id)',['d'=>$this->domain,'actor'=>$this->actor,'action'=>$enabling?'trunk_route_enable':'trunk_route_disable','id'=>$saved['service_uuid']]);
    }

    /** One explicit DID per callback service; always scoped to this PBX. */
    public static function incomingChoices(array $c,array $services,string $editing=''): array {
        $used=[];foreach($services as $service)if(($service['service_uuid']??'')!==$editing)$used[(string)$service['incoming_rule_uuid']]=true;
        $out=[];foreach($c['inbound_rules']??[] as $rule)if(($rule['condition']??'')==='BasedOnDID'&&!isset($used[$rule['rule_id']])&&isset($c['trunks'][$rule['trunk_id']])&&preg_match('/^\+?[0-9]{3,20}$/D',(string)($rule['number']??'')))$out[$rule['rule_id']]=$rule['number'].' · '.($c['trunks'][$rule['trunk_id']]['name']??'Provider');
        return $out;
    }
    private function saveService(array $in,array $c): string {
        $id=$this->id($in,'service_uuid',true);$name=$this->text($in,'service_name',100);
        if($name==='')throw new InvalidArgumentException('Enter the company name callers should hear.');
        $rule=$this->id($in,'incoming_rule_uuid');$owner=$this->text($in,'route_owner',10);$enabled=$this->checked($in,'enabled');
        $incoming=null;foreach($c['inbound_rules']??[]as$r)if(($r['rule_id']??'')===$rule){$incoming=$r;break;}
        if(!isset(self::incomingChoices($c,[])[$rule]))throw new InvalidArgumentException('Choose an individual incoming number from this PBX.');
        if($this->q('select 1 from v_pbx_cmb_services where domain_uuid=:d and incoming_rule_uuid=:rule and service_uuid<>cast(:id as uuid)',['d'=>$this->domain,'rule'=>$rule,'id'=>$id!==''?$id:'00000000-0000-0000-0000-000000000000'])->fetchColumn())throw new InvalidArgumentException('This incoming number already has a Call Me Back service. Open that service to manage it.');
        if(!isset($c['users'][$owner])||empty($c['users'][$owner]['enabled']))throw new InvalidArgumentException('Choose an enabled user whose calling permissions will apply.');
        $native=$this->q("select 1 from v_extensions where domain_uuid=:d and extension_uuid=:e and enabled='true'",['d'=>$this->domain,'e'=>$c['users'][$owner]['extension_uuid']])->fetchColumn();
        if(!$native)throw new InvalidArgumentException('The selected calling user is disabled or unavailable.');
        $limit=$in['max_requests_hour']??30;
        if(is_bool($limit)||is_array($limit)||filter_var($limit,FILTER_VALIDATE_INT,['options'=>['min_range'=>1,'max_range'=>300]])===false)throw new InvalidArgumentException('Choose between 1 and 300 callback requests per hour.');
        $retention=$in['retention_days']??90;
        if(is_bool($retention)||is_array($retention)||filter_var($retention,FILTER_VALIDATE_INT,['options'=>['min_range'=>7,'max_range'=>3650]])===false)throw new InvalidArgumentException('Keep callback history for between 7 and 3,650 days.');
        $prefixes=[];foreach(explode(',',$this->text($in,'destination_prefixes',250))as$p){$p=trim($p);if(!preg_match('/^\+?[0-9]{1,12}$/D',$p))throw new InvalidArgumentException('Enter allowed number prefixes separated by commas, for example 0, +27.');$prefixes[$p]=$p;}
        if(count($prefixes)>20)throw new InvalidArgumentException('Use up to 20 allowed number prefixes.');
        $old=$id!==''?$this->q('select name,prompt_state,prompt_version,prompt_sha256 from v_pbx_cmb_services where domain_uuid=:d and service_uuid=:id for update',['d'=>$this->domain,'id'=>$id])->fetch(PDO::FETCH_ASSOC):null;
        if($id!==''&&!$old)throw new InvalidArgumentException('Choose a Call Me Back service from this PBX.');
        $changed=!$old||$old['name']!==$name;
        $ready=$old&&!$changed&&$old['prompt_state']==='ready'&&in_array($old['prompt_version'],['1.0.1','1.0.2'],true)&&preg_match('/^[a-f0-9]{64}$/D',(string)$old['prompt_sha256']);
        if($enabled){
            if(!$this->checked($in,'confirm_handover'))throw new InvalidArgumentException('Confirm that this incoming number should answer with Call Me Back.');
            if(!$ready||!$this->voicePackReady())throw new InvalidArgumentException('Save this service switched off first. Enable it when its Keoma voice prompts are ready.');
            if(empty($incoming['enabled'])||empty($c['trunks'][$incoming['trunk_id']]['enabled']))throw new InvalidArgumentException('Connect the provider and enable this incoming number before turning on Call Me Back.');
        }
        $args=['d'=>$this->domain,'id'=>$id?:uuid(),'name'=>$name,'rule'=>$rule,'owner'=>$owner,'enabled'=>$enabled,'limit'=>(int)$limit,'retention'=>(int)$retention,'prefixes'=>json_encode(array_values($prefixes),JSON_THROW_ON_ERROR)];
        if($id==='')$this->q("insert into v_pbx_cmb_services(service_uuid,domain_uuid,name,incoming_rule_uuid,route_owner,enabled,max_requests_hour,retention_days,destination_prefixes) values(:id,:d,:name,:rule,:owner,:enabled,:limit,:retention,array(select jsonb_array_elements_text(cast(:prefixes as jsonb))))",$args);
        else {$args['pending']=$changed||$old['prompt_state']==='failed';$this->q("update v_pbx_cmb_services set prompt_version=case when :pending then '1.0.2' else prompt_version end,name=:name,incoming_rule_uuid=:rule,route_owner=:owner,enabled=:enabled,max_requests_hour=:limit,retention_days=:retention,destination_prefixes=array(select jsonb_array_elements_text(cast(:prefixes as jsonb))),prompt_state=case when :pending then 'pending' else prompt_state end,prompt_sha256=case when :pending then null else prompt_sha256 end,prompt_audio_file=case when :pending then 'greeting.wav' else prompt_audio_file end,prompt_refresh_state=case when :pending then 'pending' else prompt_refresh_state end,prompt_refresh_attempts=case when :pending then 0 else prompt_refresh_attempts end,prompt_refresh_token=case when :pending then null else prompt_refresh_token end,prompt_refresh_until=case when :pending then null else prompt_refresh_until end,prompt_refresh_after=case when :pending then null else prompt_refresh_after end,prompt_refresh_message=case when :pending then '' else prompt_refresh_message end,updated_at=now() where domain_uuid=:d and service_uuid=:id",$args);}
        $this->subject=$args['id'];
        return $enabled?'Call Me Back is enabled for the selected incoming number.':($changed?'Saved switched off. The named Keoma greeting is waiting to be generated.':'Call Me Back settings saved switched off.');
    }

    private function retryVoice(array $in): string {
        $id=$this->id($in,'service_uuid');
        if(!$this->q("update v_pbx_cmb_services set prompt_refresh_state='pending',prompt_refresh_attempts=0,prompt_refresh_after=null,prompt_refresh_token=null,prompt_refresh_until=null,prompt_refresh_message='Keoma preparation requested. Existing audio remains available.' where domain_uuid=:d and service_uuid=:id and prompt_version='1.0.1' and prompt_state='ready' and prompt_audio_file='greeting.wav' and (prompt_refresh_until is null or prompt_refresh_until<now())",['d'=>$this->domain,'id'=>$id])->rowCount())throw new InvalidArgumentException('This greeting changed or is already being prepared. Refresh the page.');
        $this->subject=$id;
        return 'Keoma preparation requested. Existing calls and greeting remain available.';
    }

    private function saveAccount(array $in): string {
        $id=$this->id($in,'account_uuid',true);$service=$this->id($in,'service_uuid');$name=$this->text($in,'account_name',100);$enabled=$this->checked($in,'enabled');
        if($name==='')throw new InvalidArgumentException('Enter the account holder’s name.');
        if(!$this->q('select 1 from v_pbx_cmb_services where domain_uuid=:d and service_uuid=:id',['d'=>$this->domain,'id'=>$service])->fetchColumn())throw new InvalidArgumentException('Choose a service from this PBX.');
        $minutes=$in['total_minutes']??null;
        if(is_bool($minutes)||is_array($minutes)||filter_var($minutes,FILTER_VALIDATE_INT,['options'=>['min_range'=>0,'max_range'=>525600]])===false)throw new InvalidArgumentException('Enter a total allowance between 0 and 525,600 minutes.');
        $total=(int)$minutes*60;
        if($id===''){
            $identity=$this->text($in,'south_african_id',13);
            $hash=self::identityHash($this->domain,$identity,$this->key());$last=substr($identity,-4);unset($identity);
            $id=uuid();$this->q('insert into v_pbx_cmb_accounts(account_uuid,domain_uuid,service_uuid,name,id_hmac,id_last4,total_seconds,enabled) values(:id,:d,:service,:name,:hash,:last,:total,:enabled)',['id'=>$id,'d'=>$this->domain,'service'=>$service,'name'=>$name,'hash'=>$hash,'last'=>$last,'total'=>$total,'enabled'=>$enabled]);
        }else{
            if($this->text($in,'south_african_id',13)!=='')throw new InvalidArgumentException('Identity numbers cannot be changed on an existing account. Disable it and create a new account if the identity was incorrect.');
            $old=$this->q('select service_uuid,used_seconds,reserved_seconds,id_last4 from v_pbx_cmb_accounts where domain_uuid=:d and account_uuid=:id for update',['d'=>$this->domain,'id'=>$id])->fetch(PDO::FETCH_ASSOC);
            if(!$old||$old['service_uuid']!==$service)throw new InvalidArgumentException('Choose this account’s existing service.');
            if($old['id_last4']===null)throw new InvalidArgumentException('This account was deleted. Create a new account with the account holder’s authority.');
            if($total<(int)$old['used_seconds']+(int)$old['reserved_seconds'])throw new InvalidArgumentException('The allowance must cover minutes already used and reserved by current calls.');
            $this->q('update v_pbx_cmb_accounts set name=:name,total_seconds=:total,enabled=:enabled,updated_at=now() where domain_uuid=:d and account_uuid=:id',['d'=>$this->domain,'id'=>$id,'name'=>$name,'total'=>$total,'enabled'=>$enabled]);
            if(!$enabled)$this->q('update v_pbx_cmb_bindings set revoked_at=now() where domain_uuid=:d and account_uuid=:id and revoked_at is null',['d'=>$this->domain,'id'=>$id]);
        }
        $this->subject=$id;
        return 'Call Me Back account and total minute allowance saved.';
    }

    private function revokeBinding(array $in): string {
        $id=$this->id($in,'binding_uuid');
        if(!$this->q('update v_pbx_cmb_bindings set revoked_at=now() where domain_uuid=:d and binding_uuid=:id and revoked_at is null',['d'=>$this->domain,'id'=>$id])->rowCount())throw new InvalidArgumentException('This saved caller has changed. Refresh the page.');
        $this->subject=$id;
        return 'Saved caller authentication revoked. Their next callback will ask for the ID number again.';
    }

    private function disableAccount(array $in): string {
        $id=$this->id($in,'account_uuid');
        if(!$this->q('update v_pbx_cmb_accounts set enabled=false,updated_at=now() where domain_uuid=:d and account_uuid=:id and enabled',['d'=>$this->domain,'id'=>$id])->rowCount())throw new InvalidArgumentException('This account has changed. Refresh the page.');
        $this->q('update v_pbx_cmb_bindings set revoked_at=now() where domain_uuid=:d and account_uuid=:id and revoked_at is null',['d'=>$this->domain,'id'=>$id]);
        $this->subject=$id;
        return 'Account disabled. New authenticated calls will be refused; an already connected call can finish within its current limit.';
    }

    private function cancelRequest(array $in): string {
        $id=$this->id($in,'request_uuid');
        if(!$this->q("update v_pbx_cmb_requests set state='cancelled',updated_at=now(),completed_at=now(),last_result='admin_cancelled' where domain_uuid=:d and request_uuid=:id and state='queued' and reserved_seconds=0",['d'=>$this->domain,'id'=>$id])->rowCount())throw new InvalidArgumentException('This request has already started or changed. Refresh the page.');
        $this->subject=$id;
        return 'Waiting callback cancelled.';
    }

    private function deleteAccount(array $in): string {
        $id=$this->id($in,'account_uuid');
        if(!$this->checked($in,'confirm_delete'))throw new InvalidArgumentException('Confirm that this account’s identity and saved callers should be deleted.');
        $account=$this->q('select reserved_seconds,id_last4 from v_pbx_cmb_accounts where domain_uuid=:d and account_uuid=:id for update',['d'=>$this->domain,'id'=>$id])->fetch(PDO::FETCH_ASSOC);
        if(!$account||$account['id_last4']===null)throw new InvalidArgumentException('Choose an existing account from this PBX.');
        $active=$this->q("select 1 from v_pbx_cmb_requests where domain_uuid=:d and account_uuid=:id and state in ('announcing','queued','starting','authenticating','dialling','connected') limit 1",['d'=>$this->domain,'id'=>$id])->fetchColumn();
        if((int)$account['reserved_seconds']>0||$active)throw new InvalidArgumentException('Disable the account, then wait for its current callback to finish before deleting its identity.');
        $this->q('delete from v_pbx_cmb_bindings where domain_uuid=:d and account_uuid=:id',['d'=>$this->domain,'id'=>$id]);
        $this->q('update v_pbx_cmb_requests set caller_number=null,updated_at=now() where domain_uuid=:d and account_uuid=:id',['d'=>$this->domain,'id'=>$id]);
        $this->q("update v_pbx_cmb_accounts set name='Deleted account',id_hmac=null,id_last4=null,enabled=false,updated_at=now() where domain_uuid=:d and account_uuid=:id",['d'=>$this->domain,'id'=>$id]);
        $this->subject=$id;
        return 'Account identity and saved callers deleted. Cumulative minute totals and usage records are retained under the PBX retention policy.';
    }
}
