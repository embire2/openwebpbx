<?php
/** Reusable tenant-owned greetings. HTTP callers must validate their form token. */
class pbx_greetings {
    private PDO $db;
    private string $domain;
    private string $actor;
    public const VOICE = 'i8SlcaZfyeP1st7wHsjM';
    public const CATEGORIES = ['voicemail'=>'Voicemail greeting','receptionist'=>'Digital Receptionist greeting','queue_intro'=>'Queue welcome greeting','queue_wait'=>'Queue waiting announcement','hold_music'=>'Music on hold','announcement'=>'General announcement'];
    public function __construct(?PDO $db=null) {
        $this->db=$db??database::new()->db;$this->domain=(string)($_SESSION['domain_uuid']??'');$this->actor=(string)($_SESSION['user_uuid']??'');$this->access();
    }
    protected function access(): void {
        if(!is_uuid($this->domain)||!is_uuid($this->actor)||$this->domain!==($_SESSION['domain_uuid']??'')||$this->actor!==($_SESSION['user_uuid']??'')||
            !$this->q("select 1 from v_users u join v_domains d on d.domain_uuid=? where u.user_uuid=? and u.user_enabled='true' and d.domain_enabled='true'",[$this->domain,$this->actor])->fetchColumn()||
            !(new pbx_staff_access($this->db))->owner())throw new DomainException('PBX administrator access is required for Greetings.');
    }
    private function q(string $sql,array $args=[]): PDOStatement {$s=$this->db->prepare($sql);$s->execute($args);return $s;}
    private function text(array $in,string $name,int $max=120,bool $multiline=false): string {
        $controls=$multiline?'/[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]/u':'/[\x00-\x1f\x7f]/u';
        $s=$in[$name]??'';if(!is_string($s)||mb_strlen($s)>$max||preg_match($controls,$s))throw new InvalidArgumentException('Enter a valid '.str_replace('_',' ',$name).'.');return trim($s);
    }
    public function installed(): bool {$this->access();return (bool)$this->q("select to_regclass('v_pbx_greetings') is not null and to_regclass('v_pbx_greeting_uses') is not null and to_regclass('v_pbx_greeting_status') is not null")->fetchColumn();}
    public function readiness(): array {
        $this->access();$r=$this->q('select provider_configured,checked_at>now()-interval \'2 minutes\' online from v_pbx_greeting_status where singleton=1')->fetch(PDO::FETCH_ASSOC);
        $online=$r&&filter_var($r['online'],FILTER_VALIDATE_BOOLEAN);$configured=$r&&filter_var($r['provider_configured'],FILTER_VALIDATE_BOOLEAN);
        return ['ready'=>(bool)($online&&$configured),'online'=>(bool)$online,'narrator'=>'Keoma','message'=>!$online?'The Greetings service is not running yet. Ask your instance administrator to activate the updated OpenWebPBX service.':(!$configured?'Keoma is not configured yet. Your instance administrator must configure its ElevenLabs account before greetings can be created.':'Keoma is ready. Phone recording and text greetings are available.')];
    }
    public function config(): array {$this->access();return (new pbx_admin($this->db))->config();}
    public function companyName(): string {
        $this->access();return (string)($this->q('select coalesce(t.tenant_name,s.service_name) from v_pbx_services s join v_pbx_tenants t using(tenant_uuid) where s.domain_uuid=?',[$this->domain])->fetchColumn()?:($_SESSION['domain_name']??'Your company'));
    }
    public function all(): array {
        $this->access();return $this->q('select g.greeting_uuid,g.name,g.category,g.source,g.company_name,g.target_number,g.caller_extension,g.state,g.last_result,g.created_at,g.media_uuid,(select count(*) from v_pbx_greeting_uses u where u.domain_uuid=g.domain_uuid and u.greeting_uuid=g.greeting_uuid) uses from v_pbx_greetings g where g.domain_uuid=? order by g.created_at desc limit 500',[$this->domain])->fetchAll(PDO::FETCH_ASSOC);
    }
    public function create(array $in): string {
        $this->access();$name=$this->text($in,'name');$category=$this->text($in,'category',30);$source=$this->text($in,'source',10);$company=$this->text($in,'company_name');
        if($company==='')throw new InvalidArgumentException('Enter a company name.');
        if(!isset(self::CATEGORIES[$category])||!in_array($source,['phone','text'],true))throw new InvalidArgumentException('Choose a greeting category and recording method.');
        $target='';$caller='';$script='';$config=$this->config();
        if($source==='phone') {
            $target=$this->text($in,'target_number',20);$caller=$this->text($in,'caller_extension',10);
            if(!isset($config['users'][$caller])||empty($config['users'][$caller]['enabled']))throw new InvalidArgumentException('Choose the calling extension whose outside-call rules should be used.');
            if(isset($config['users'][$target])) {if(empty($config['users'][$target]['enabled']))throw new InvalidArgumentException('Choose an enabled phone.');}
            elseif(!preg_match('/^\+?[0-9]{7,18}$/D',$target))throw new InvalidArgumentException('Enter an extension from this PBX or an outside telephone number.');
        } else {
            $script=$this->text($in,'script',3000,true);if($script==='')throw new InvalidArgumentException('Type the greeting Keoma should record.');
        }
        if(!$this->readiness()['ready'])throw new InvalidArgumentException($this->readiness()['message']);
        $id=uuid();if($name==='')$name=self::CATEGORIES[$category].' '.gmdate('Y-m-d H:i').' '.substr($id,0,8);$this->db->beginTransaction();
        try {
            $this->q('select pg_advisory_xact_lock(hashtextextended(?,741103501))',[$this->domain]);
            if((int)$this->q("select count(*) from v_pbx_greetings where domain_uuid=? and created_at>now()-interval '1 day'",[$this->domain])->fetchColumn()>=40)throw new OverflowException('This PBX has reached its daily greeting allowance. Try again tomorrow.');
            if((int)$this->q("select count(*) from v_pbx_greetings where domain_uuid=? and state in ('pending','preparing','ready_to_call','calling')",[$this->domain])->fetchColumn()>=5)throw new OverflowException('Wait for an existing greeting to finish before creating another.');
            $this->q('insert into v_pbx_greetings(greeting_uuid,domain_uuid,created_by,name,category,source,company_name,script,target_number,caller_extension) values(?,?,?,?,?,?,?,?,?,?)',[$id,$this->domain,$this->actor,$name,$category,$source,$company,$script,$target,$caller]);
            $this->db->commit();return $id;
        }catch(Throwable $e){if($this->db->inTransaction())$this->db->rollBack();throw $e;}
    }
    private function row(string $id,bool $lock=false): array {
        if(!is_uuid($id))throw new InvalidArgumentException('Choose a greeting.');
        $r=$this->q('select * from v_pbx_greetings where domain_uuid=? and greeting_uuid=?'.($lock?' for update':''),[$this->domain,$id])->fetch(PDO::FETCH_ASSOC);
        if(!$r)throw new InvalidArgumentException('This greeting is not in your PBX.');return $r;
    }
    public function rename(string $id,array $in): void {
        $this->access();$name=$this->text($in,'name');if($name==='')throw new InvalidArgumentException('Enter a greeting name.');
        $this->db->beginTransaction();try{
            $r=$this->row($id,true);$this->q('update v_pbx_greetings set name=?,updated_at=now() where domain_uuid=? and greeting_uuid=?',[$name,$this->domain,$id]);
            if($r['media_uuid'])$this->q('update v_pbx_media set title=? where domain_uuid=? and media_uuid=?',[$name,$this->domain,$r['media_uuid']]);
            if($r['media_uuid'])$this->q('update v_recordings set recording_name=? where domain_uuid=? and recording_filename=(select file_path from v_pbx_media where domain_uuid=? and media_uuid=?)',[$name,$this->domain,$this->domain,$r['media_uuid']]);
            $this->q('update v_voicemail_greetings set greeting_name=? where domain_uuid=? and greeting_description=?',[$name,$this->domain,'OpenWeb greeting '.$id]);
            if($r['media_uuid']){
                $config=(new pbx_admin($this->db))->config(true);
                foreach($config['users'] as &$user)if(isset($user['greetings']))foreach($user['greetings'] as &$greeting)if(($greeting['media_uuid']??'')===$r['media_uuid'])$greeting['title']=$name;
                unset($user,$greeting);
                $this->q('update v_pbx_restore set config=cast(? as jsonb) where domain_uuid=?',[json_encode($config,JSON_THROW_ON_ERROR),$this->domain]);
            }
            $this->db->commit();
        }catch(Throwable $e){if($this->db->inTransaction())$this->db->rollBack();throw $e;}
    }
    public function action(string $id,string $action): void {
        $this->access();$this->db->beginTransaction();try{
            $r=$this->row($id,true);
            if($action==='cancel'&&in_array($r['state'],['pending','preparing','ready_to_call'],true))$this->q("update v_pbx_greetings set state='cancelled',lease_until=null,last_result='Cancelled by administrator',updated_at=now() where domain_uuid=? and greeting_uuid=?",[$this->domain,$id]);
            elseif($action==='retry'&&$r['state']==='failed'){
                if((int)$r['attempts']>=3)throw new InvalidArgumentException('This greeting has reached its retry limit. Create a new greeting after checking the voice service or recording phone.');
                $this->q("update v_pbx_greetings set state='pending',lease_until=null,last_result='',updated_at=now() where domain_uuid=? and greeting_uuid=?",[$this->domain,$id]);
            }
            elseif($action==='archive'&&in_array($r['state'],['ready','failed','cancelled'],true)){
                if($this->q('select 1 from v_pbx_greeting_uses where domain_uuid=? and greeting_uuid=? limit 1',[$this->domain,$id])->fetchColumn())throw new InvalidArgumentException('This greeting is assigned. Replace its assignments before archiving it.');
                $this->q("update v_pbx_greetings set state='archived',updated_at=now() where domain_uuid=? and greeting_uuid=?",[$this->domain,$id]);
            }else throw new InvalidArgumentException('This greeting has changed. Refresh the page. Calls already in progress cannot be cancelled here.');
            $this->db->commit();
        }catch(Throwable $e){if($this->db->inTransaction())$this->db->rollBack();throw $e;}
    }
    public function media(string $id): array {
        $this->access();$r=$this->row($id);if($r['state']!=='ready')throw new InvalidArgumentException('This greeting is not ready.');
        $m=$this->q("select file_path,title from v_pbx_media where domain_uuid=? and media_uuid=? and category='prompts'",[$this->domain,$r['media_uuid']])->fetch(PDO::FETCH_ASSOC);
        if(!$m||!pbx_paths::contains(pbx_paths::media().'/'.$this->domain.'/greetings',$m['file_path'])||is_link($m['file_path'])||!is_file($m['file_path'])||filesize($m['file_path'])>32000000)throw new RuntimeException('This greeting audio is unavailable.');return $m;
    }
    public function uses(string $id): array {$this->access();$this->row($id);return $this->q('select kind,target_number from v_pbx_greeting_uses where domain_uuid=? and greeting_uuid=? order by kind,target_number',[$this->domain,$id])->fetchAll(PDO::FETCH_ASSOC);}
    public function unassign(string $id,string $kind,string $target): void {
        $this->access();if(!in_array($kind,['voicemail','receptionist','queue_intro','queue_wait','hold_music','extension_hold'],true)||!preg_match('/^[0-9]{2,10}$/D',$target))throw new InvalidArgumentException('Choose an assigned destination.');
        $this->db->beginTransaction();try{
            $r=$this->row($id,true);$media=$this->media($id);$config=(new pbx_admin($this->db))->config(true);$realm=$config['realm'];
            if(!$this->q('select 1 from v_pbx_greeting_uses where domain_uuid=? and greeting_uuid=? and kind=? and target_number=? for update',[$this->domain,$id,$kind,$target])->fetchColumn())throw new InvalidArgumentException('This assignment has changed. Refresh the page.');
            if($kind==='voicemail'&&isset($config['users'][$target])){
                $greeting=$this->q('select greeting_id from v_voicemail_greetings where domain_uuid=? and voicemail_id=? and greeting_description=?',[$this->domain,$target,'OpenWeb greeting '.$id])->fetchColumn();
                if($greeting!==false&&(string)($config['users'][$target]['greeting_id']??'')===(string)$greeting){
                    $config['users'][$target]['greeting_id']='';$this->q('update v_voicemails set greeting_id=null where domain_uuid=? and voicemail_uuid=? and greeting_id=?',[$this->domain,$config['users'][$target]['voicemail_uuid'],$greeting]);
                }
            }elseif($kind==='extension_hold'&&isset($config['users'][$target])&&($config['users'][$target]['hold_music']??'')===$media['file_path']){
                $config['users'][$target]['hold_music']='';$this->q('update v_extensions set hold_music=null where domain_uuid=? and extension_uuid=? and hold_music=?',[$this->domain,$config['users'][$target]['extension_uuid'],$media['file_path']]);
            }elseif(!in_array($kind,['voicemail','extension_hold'],true)){
                $collection=$kind==='receptionist'?'receptionists':'queues';$field=match($kind){'receptionist'=>'prompt','queue_intro'=>'intro','queue_wait'=>'announce_sound','hold_music'=>'moh'};
                foreach($config[$collection] as &$item)if((string)$item['number']===$target&&($item[$field]??'')===$media['file_path']){
                    $item[$field]='';
                    if($kind==='receptionist')$this->q("update v_ivr_menus set ivr_menu_greet_long='',ivr_menu_greet_short='' where domain_uuid=? and ivr_menu_uuid=?",[$this->domain,$item['uuid']]);
                    elseif($kind==='queue_intro')$this->q("update v_call_center_queues set queue_greeting='' where domain_uuid=? and call_center_queue_uuid=?",[$this->domain,$item['uuid']]);
                    elseif($kind==='hold_music')$this->q("update v_call_center_queues set queue_moh_sound='local_stream://openweb' where domain_uuid=? and call_center_queue_uuid=?",[$this->domain,$item['uuid']]);
                }unset($item);
            }
            $this->q('delete from v_pbx_greeting_uses where domain_uuid=? and greeting_uuid=? and kind=? and target_number=?',[$this->domain,$id,$kind,$target]);
            $this->q('update v_pbx_restore set config=cast(? as jsonb) where domain_uuid=?',[json_encode($config,JSON_THROW_ON_ERROR),$this->domain]);$this->db->commit();
        }catch(Throwable $e){if($this->db->inTransaction())$this->db->rollBack();throw $e;}
        settings::clear_cache();$cache=new cache;$cache->delete('dialplan:'.$realm);$cache->delete('voicemail:'.$realm.':'.$target);$cache->delete(gethostname().':configuration:callcenter.conf');$cache->delete('configuration:callcenter.conf');
        if($kind==='extension_hold'&&isset($config['users'][$target])){if(isset($config['users'][$target]['auth_id']))$cache->delete('directory:'.$config['users'][$target]['auth_id'].'@'.$realm);$cache->delete('directory:'.$target.'@'.$realm);}
        if(in_array($kind,['queue_intro','queue_wait','hold_music'],true))try{event_socket::api('callcenter_config queue unload '.$target.'@'.$realm);}catch(Throwable){}
        try{event_socket::api('reloadxml');}catch(Throwable){}
    }
    public function assign(string $id,string $kind,array $targets): void {
        $this->access();$r=$this->row($id);$media=$this->media($id);
        $compatible=['voicemail'=>['voicemail'],'receptionist'=>['receptionist'],'queue_intro'=>['queue_intro','announcement'],'queue_wait'=>['queue_wait','announcement'],'hold_music'=>['hold_music'],'extension_hold'=>['hold_music']];
        if(!isset($compatible[$kind])||!in_array($r['category'],$compatible[$kind],true)||!$targets||count($targets)>200)throw new InvalidArgumentException('Choose matching destinations for this greeting category.');
        foreach($targets as $target)if(!is_string($target)||!preg_match('/^[0-9]{2,10}$/D',$target))throw new InvalidArgumentException('Choose destinations from this PBX.');
        $created=[];$this->db->beginTransaction();
        try {
            $this->row($id,true);$admin=new pbx_admin($this->db);$config=$admin->config(true);$realm=$config['realm']??'';
            if(!is_string($realm)||!preg_match('/^[a-z0-9.-]+$/D',$realm))throw new RuntimeException('The PBX address needs review.');
            foreach(array_unique($targets) as $target) {
                if(in_array($kind,['voicemail','extension_hold'],true)) {
                    $user=$config['users'][$target]??null;if(!$user||empty($user['enabled']))throw new InvalidArgumentException('Choose enabled users from this PBX.');
                    if($kind==='voicemail') {
                        if(empty($user['voicemail_uuid'])||!is_uuid($user['voicemail_uuid']))throw new InvalidArgumentException('Enable voicemail for this user first.');
                        $description='OpenWeb greeting '.$id;
                        $existing=$this->q('select greeting_id from v_voicemail_greetings where domain_uuid=? and voicemail_id=? and greeting_description=?',[$this->domain,$target,$description])->fetchColumn();
                        $greeting=$existing===false?max(1000,(int)$this->q('select coalesce(max(greeting_id),0)+1 from v_voicemail_greetings where domain_uuid=? and voicemail_id=?',[$this->domain,$target])->fetchColumn()):(int)$existing;
                        if($existing===false) {
                            $directory=pbx_paths::voicemail().'/default/'.$realm.'/'.$target;
                            if(!is_dir($directory)&&!mkdir($directory,0700,true))throw new RuntimeException('Voicemail storage is unavailable.');
                            if(is_link($directory)||!pbx_paths::contains(pbx_paths::voicemail(),$directory))throw new RuntimeException('Voicemail storage needs administrator review.');
                            $path=$directory.'/greeting_'.$greeting.'.wav';
                            $out=@fopen($path,'xb');if(!$out)throw new RuntimeException('The greeting filename is already in use. Existing audio was preserved.');
                            $created[]=$path;try{$in=fopen($media['file_path'],'rb');if(!$in)throw new RuntimeException('Greeting audio is unavailable.');try{if(stream_copy_to_stream($in,$out)===false)throw new RuntimeException('The greeting could not be copied.');}finally{fclose($in);}}finally{fclose($out);}chmod($path,0600);
                            $this->q('insert into v_voicemail_greetings(voicemail_greeting_uuid,domain_uuid,voicemail_id,greeting_id,greeting_filename,greeting_description,greeting_name) values(?,?,?,?,?,?,?)',[uuid(),$this->domain,$target,$greeting,'greeting_'.$greeting.'.wav',$description,$r['name']]);
                            $config['users'][$target]['greetings'][]=['id'=>(string)$greeting,'title'=>$r['name'],'media_uuid'=>$r['media_uuid']];
                        }
                        $config['users'][$target]['greeting_id']=(string)$greeting;
                        $this->q('update v_voicemails set greeting_id=? where domain_uuid=? and voicemail_uuid=?',[$greeting,$this->domain,$user['voicemail_uuid']]);
                    } else {
                        $config['users'][$target]['hold_music']=$media['file_path'];
                        $this->q('update v_extensions set hold_music=? where domain_uuid=? and extension_uuid=?',[$media['file_path'],$this->domain,$user['extension_uuid']]);
                    }
                } else {
                    $collection=$kind==='receptionist'?'receptionists':'queues';$index=null;
                    foreach($config[$collection]??[] as $i=>$item)if((string)$item['number']===$target){$index=$i;break;}
                    if($index===null)throw new InvalidArgumentException('Choose a destination from this PBX.');
                    $field=match($kind){'receptionist'=>'prompt','queue_intro'=>'intro','queue_wait'=>'announce_sound','hold_music'=>'moh'};
                    $config[$collection][$index][$field]=$media['file_path'];$item=$config[$collection][$index];
                    if($kind==='receptionist')$this->q('update v_ivr_menus set ivr_menu_greet_long=?,ivr_menu_greet_short=? where domain_uuid=? and ivr_menu_uuid=?',[$media['file_path'],$media['file_path'],$this->domain,$item['uuid']]);
                    elseif($kind==='queue_intro')$this->q('update v_call_center_queues set queue_greeting=? where domain_uuid=? and call_center_queue_uuid=?',[$media['file_path'],$this->domain,$item['uuid']]);
                    elseif($kind==='hold_music')$this->q('update v_call_center_queues set queue_moh_sound=? where domain_uuid=? and call_center_queue_uuid=?',[$media['file_path'],$this->domain,$item['uuid']]);
                }
                $this->q('insert into v_pbx_greeting_uses(domain_uuid,greeting_uuid,kind,target_number) values(?,?,?,?) on conflict(domain_uuid,kind,target_number) do update set greeting_uuid=excluded.greeting_uuid,created_at=now()',[$this->domain,$id,$kind,$target]);
            }
            $this->q('update v_pbx_restore set config=cast(? as jsonb) where domain_uuid=?',[json_encode($config,JSON_THROW_ON_ERROR),$this->domain]);$this->db->commit();
        }catch(Throwable $e){if($this->db->inTransaction())$this->db->rollBack();foreach($created as $file)@unlink($file);throw $e;}
        settings::clear_cache();$cache=new cache;$cache->delete('dialplan:'.$realm);$cache->delete(gethostname().':configuration:callcenter.conf');$cache->delete('configuration:callcenter.conf');
        foreach($targets as $target){$cache->delete('voicemail:'.$realm.':'.$target);if($kind==='extension_hold'&&isset($config['users'][$target])){if(isset($config['users'][$target]['auth_id']))$cache->delete('directory:'.$config['users'][$target]['auth_id'].'@'.$realm);$cache->delete('directory:'.$target.'@'.$realm);}if(in_array($kind,['queue_intro','queue_wait','hold_music'],true))try{event_socket::api('callcenter_config queue unload '.$target.'@'.$realm);}catch(Throwable){}}
        try{event_socket::api('reloadxml');}catch(Throwable){}
    }
}
