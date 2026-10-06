<?php
/** Native objects and a domain-bound routing policy for the inspected V20 backup. */
final class pbx_v20_restore {
    public const MEDIA_ROOT='/var/lib/freeswitch/storage/openwebpbx';
    private PDO $db;
    private string $domain;
    private string $realm;
    private array $policy;
    private array $media=[];
    private array $mediaFiles=[];
    private array $missingPrompts=[];
    public function __construct(PDO $db){$this->db=$db;}
    private function query(string $sql,array $params=[]): PDOStatement {
        $s=$this->db->prepare($sql);
        foreach($params as $k=>$v)$s->bindValue(':'.$k,$v,$v===null?PDO::PARAM_NULL:(is_bool($v)?PDO::PARAM_BOOL:(is_int($v)?PDO::PARAM_INT:PDO::PARAM_STR)));
        $s->execute();return $s;
    }
    private function insert(string $table,array $row): void {
        $keys=array_keys($row);$this->query('insert into '.$table.'('.implode(',',$keys).') values('.implode(',',array_map(fn($k)=>':'.$k,$keys)).')',$row);
    }
    public static function validate(array $plan): void {
        $v=$plan['v20']??null;
        if(!is_array($v)||($plan['source_version']??'')!=='20.0.9.995')throw new InvalidArgumentException('This backup update has not been checked.');
        $known=[];
        foreach($plan['users'] as $u)$known[$u['number']]='Extension';
        foreach(['queues'=>'Queue','ring_groups'=>'RingGroup','receptionists'=>'IVR','scripts'=>'RoutePoint','specials'=>'Special'] as $key=>$kind){
            if(count($v[$key]??[])>500)throw new InvalidArgumentException('The backup has too many call handling entries.');
            foreach($v[$key] as $r){if(isset($known[$r['number']]))throw new InvalidArgumentException('Two call handling entries use the same extension.');$known[$r['number']]=$kind;}
        }
        $check=function(array $d)use($known){
            if(!in_array($d['type']??'', ['None','EndCall','External','Boomerang','Extension','VoiceMail','RingGroup','Queue','IVR','RoutePoint','Fax'],true))throw new InvalidArgumentException('A call destination needs a restore update.');
            if(in_array($d['type'],['None','EndCall'],true))return;
            if($d['type']==='External'){if(!preg_match('/^\+?[0-9*#]{1,32}$/D',$d['external']??''))throw new InvalidArgumentException('A forwarding number is missing.');return;}
            if(($d['number']??'')!==''&&!isset($known[$d['number']]))throw new InvalidArgumentException('A call destination is missing from the backup.');
        };
        foreach(['queues','ring_groups'] as $key)foreach($v[$key] as $r){foreach($r['members'] as $m)if(($known[$m['number']]??'')!=='Extension')throw new InvalidArgumentException('A call group contains a missing user.');$check($r['destination']);if(!in_array($r['strategy'],['PollingStrategyRingAll','RingAll','RingStrategyRingAll'],true))throw new InvalidArgumentException('This ringing order needs a restore update.');}
        foreach($v['receptionists'] as $r){$check($r['timeout_destination']);foreach($r['options'] as $o)$check($o['destination']);}
        foreach($v['users'] as $u){if(!isset($u['profiles'][$u['profile']]))throw new InvalidArgumentException('A user status is missing.');foreach($u['profiles'] as $p){foreach($p['available'] as $a){$check($a['all']);$check($a['internal']);}foreach($p['away'] as $a){$check($a['all']);$check($a['outside']);}}}
        $providers=[];foreach($plan['trunks'] as $t)$providers[$t['name']]=$t['source_id'];
        foreach($v['inbound_rules'] as $r){if(!isset($v['trunks'][$r['trunk_id']]))throw new InvalidArgumentException('An incoming rule has no trunk.');foreach(['office','outside','holiday'] as $k)$check($r[$k]);if($r['condition']==='BasedOnDID'&&!preg_match('/^\*?\+?[0-9]{1,32}$/D',$r['number']))throw new InvalidArgumentException('An incoming number needs a restore update.');}
        foreach($v['outbound_rules'] as $r){foreach(explode(',',$r['prefix']) as $prefix)if(!preg_match('/^\+?[0-9]{0,20}$/D',trim($prefix)))throw new InvalidArgumentException('An outbound prefix is invalid.');if(!preg_match('/^[0-9,\- ]{0,120}$/D',$r['lengths']))throw new InvalidArgumentException('An outbound length is invalid.');foreach($r['routes'] as $route){if(!isset($providers[$route['provider']]))throw new InvalidArgumentException('An outbound rule has no trunk.');if(!preg_match('/^\+?[0-9]{0,20}$/D',$route['prepend']))throw new InvalidArgumentException('An outbound prefix is invalid.');}}
        foreach($v['scripts'] as $s)foreach($s['pin_map'] as $target)if(!preg_match('/^[0-9]{2,10}$/D',(string)$target))throw new InvalidArgumentException('A call menu destination is invalid.');
    }
    private function dialplan(string $number,string $mode,string $key,int $order=80,string $context='',bool $enabled=true,string $app=''): string {
        $id=uuid();$d=new DOMDocument('1.0','UTF-8');$x=$d->appendChild($d->createElement('extension'));$x->setAttribute('name','OpenWeb '.$mode.' '.$number);$x->setAttribute('uuid',$id);$x->setAttribute('continue','false');
        $c=$x->appendChild($d->createElement('condition'));$c->setAttribute('field','destination_number');$c->setAttribute('expression',$number===''?'^.+$':'^'.preg_quote($number,'~').'$');
        $actions=[['set','domain_uuid='.$this->domain],['set','domain_name='.$this->realm],['lua','app.lua pbx_setup '.$mode.' '.$key]];
        foreach($actions as [$a,$v]){$n=$c->appendChild($d->createElement('action'));$n->setAttribute('application',$a);$n->setAttribute('data',$v);}
        $this->insert('v_dialplans',['dialplan_uuid'=>$id,'domain_uuid'=>$this->domain,'app_uuid'=>$app?:null,'dialplan_name'=>'OpenWeb '.$mode.' '.$number,'dialplan_number'=>$number,'dialplan_context'=>$context?:$this->realm,'dialplan_order'=>$order,'dialplan_continue'=>false,'dialplan_enabled'=>$enabled,'dialplan_xml'=>$d->saveXML($x),'dialplan_description'=>'Restored 3CX call handling. Edit in Admin.']);
        $rows=[['condition','destination_number',$c->getAttribute('expression')]];foreach($actions as [$a,$v])$rows[]=['action',$a,$v];
        foreach($rows as $i=>[$tag,$type,$data])$this->insert('v_dialplan_details',['dialplan_detail_uuid'=>uuid(),'domain_uuid'=>$this->domain,'dialplan_uuid'=>$id,'dialplan_detail_tag'=>$tag,'dialplan_detail_type'=>$type,'dialplan_detail_data'=>$data,'dialplan_detail_order'=>10+$i*10,'dialplan_detail_group'=>0,'dialplan_detail_enabled'=>true]);
        return $id;
    }
    /** All changes share the setup transaction. Extraction rolls back if any stage fails. */
    public function apply(string $domain,string $realm,array $plan,?string $archive=null): array {
        self::validate($plan);if(!$this->db->inTransaction())throw new LogicException('A restore requires a transaction.');
        if(!is_uuid($domain)||!preg_match('/^[a-z0-9.-]+$/D',$realm))throw new InvalidArgumentException('Invalid PBX.');
        $this->domain=$domain;$this->realm=$realm;$this->policy=$plan['v20'];$this->policy['realm']=$realm;
        if($archive)$this->extract($archive);
        foreach($plan['users'] as $u){$p=&$this->policy['users'][$u['number']];$native=$this->query('select extension_uuid from v_extensions where domain_uuid=:d and extension=:e',['d'=>$domain,'e'=>$u['auth_id']])->fetchColumn();
            $p['auth_id']=$u['auth_id'];$p['extension_uuid']=$native;$p['name']=$u['name'];$p['email']=$u['email'];$p['enabled']=$u['enabled'];
            $this->query('update v_extensions set call_timeout=:timeout,outbound_caller_id_number=:cid,description=:name,max_registrations=5 where extension_uuid=:id and domain_uuid=:d',['timeout'=>$p['profiles'][$p['profile']]['timeout'],'cid'=>$p['outbound_caller_id'],'name'=>$u['name'],'id'=>$native,'d'=>$domain]);
            $this->query('update v_voicemails set voicemail_enabled=:on,voicemail_tutorial=false,voicemail_mail_to=:email,voicemail_file=:file,voicemail_local_after_email=:keep where domain_uuid=:d and voicemail_id=:n',['on'=>$p['voicemail_enabled'],'email'=>$p['voicemail_email']==='None'?'':$u['email'],'file'=>in_array($p['voicemail_email'],['Attachment','AttachmentAndDelete'],true)?'attach':'link','keep'=>$p['voicemail_email']!=='AttachmentAndDelete','d'=>$domain,'n'=>$u['number']]);
            // Do not send imported mail or reuse the old hosted email relay.
            $p['voicemail_uuid']=$this->query('select voicemail_uuid from v_voicemails where domain_uuid=:d and voicemail_id=:n',['d'=>$domain,'n'=>$u['number']])->fetchColumn();
            $p['dialplan_uuid']=$this->dialplan($u['number'],'user',$u['number'],80);
            unset($p);
        }
        $providers=[];foreach($plan['trunks'] as $t){$id=$this->query('select gateway_uuid from v_gateways where domain_uuid=:d and gateway=:n',['d'=>$domain,'n'=>$t['name']])->fetchColumn();$p=&$this->policy['trunks'][$t['source_id']];$p['gateway_uuid']=$id;$p['name']=$t['name'];$p['host']=$t['host'];$p['port']=$t['port'];$p['transport']=$t['transport'];$p['register']=$t['register'];$p['enabled']=false;$p['allowed_ips']=[];$providers[$t['name']]=$t['source_id'];
            $from=$p['headers']['FromUserPart']??'';$this->query('update v_gateways set expire_seconds=:expires,channels=:channels,caller_id_in_from=:cid,from_user=:user,from_domain=:host where domain_uuid=:d and gateway_uuid=:id',['expires'=>$p['expires'],'channels'=>$p['limit'],'cid'=>$from==='$OutboundCallerId','user'=>$from==='$AuthID'?$t['username']:null,'host'=>$t['host'],'d'=>$domain,'id'=>$id]);unset($p);}
        foreach($this->policy['outbound_rules'] as $i=>&$r){$r['rule_id']=uuid();foreach($r['routes'] as &$route){$route['trunk_id']=$providers[$route['provider']];unset($route['provider']);}unset($route);}$this->dialplan('','outbound','all',900);unset($r);
        foreach($this->policy['ring_groups'] as &$r){$r['uuid']=uuid();$r['dialplan_uuid']=$this->dialplan($r['number'],'group',$r['number'],80,'',true,'1d61fb65-1eec-bc73-a6ee-a6203b4fe6f2');$this->insert('v_ring_groups',['ring_group_uuid'=>$r['uuid'],'domain_uuid'=>$domain,'dialplan_uuid'=>$r['dialplan_uuid'],'ring_group_name'=>$r['name'],'ring_group_extension'=>$r['number'],'ring_group_strategy'=>'simultaneous','ring_group_call_timeout'=>$r['timeout'],'ring_group_context'=>$realm,'ring_group_enabled'=>true,'ring_group_timeout_app'=>'lua','ring_group_timeout_data'=>'app.lua pbx_setup group_timeout '.$r['number'],'ring_group_description'=>'Restored from 3CX']);foreach($r['members'] as $m)$this->insert('v_ring_group_destinations',['ring_group_destination_uuid'=>uuid(),'domain_uuid'=>$domain,'ring_group_uuid'=>$r['uuid'],'destination_number'=>$m['number'],'destination_timeout'=>$r['timeout'],'destination_enabled'=>true]);}unset($r);
        $agents=[];foreach($this->policy['queues'] as &$r){$r['uuid']=uuid();$r['dialplan_uuid']=$this->dialplan($r['number'],'queue',$r['number'],80,'',true,'e95a2bd9-07fb-409b-84aa-1cbd0ea9a3cf');$r['intro']=$this->prompt($r['intro']);$r['moh']=$this->prompt($r['moh']);
            $this->insert('v_call_center_queues',['call_center_queue_uuid'=>$r['uuid'],'domain_uuid'=>$domain,'dialplan_uuid'=>$r['dialplan_uuid'],'queue_name'=>$r['name'],'queue_extension'=>$r['number'],'queue_strategy'=>'ring-all','queue_moh_sound'=>$r['moh']?:'local_stream://default','queue_greeting'=>$r['intro'],'queue_max_wait_time'=>$r['timeout'],'queue_max_wait_time_with_no_agent'=>$r['timeout'],'queue_time_base_score'=>'system','queue_tier_rules_apply'=>false,'queue_tier_rule_no_agent_no_wait'=>false,'queue_discard_abandoned_after'=>60,'queue_abandoned_resume_allowed'=>false,'queue_announce_position'=>$r['announce_position'],'queue_announce_frequency'=>$r['announce_interval'],'queue_context'=>$realm,'queue_timeout_action'=>'lua:app.lua pbx_setup queue_timeout '.$r['number'],'queue_description'=>'Restored from 3CX']);
            foreach($r['members'] as $i=>&$m){$aKey=$r['number'].'-'.$m['number'];if(!isset($agents[$aKey])){$a=uuid();$agents[$aKey]=$a;$u=$this->policy['users'][$m['number']];$contact='[leg_timeout='.$r['ring_timeout'].',domain_uuid='.$domain.',domain_name='.$realm.']user/'.$u['auth_id'].'@'.$realm;$this->insert('v_call_center_agents',['call_center_agent_uuid'=>$a,'domain_uuid'=>$domain,'agent_name'=>$u['name'].' '.$r['number'],'agent_type'=>'callback','agent_id'=>$m['number'],'agent_contact'=>$contact,'agent_status'=>$m['status']==='LoggedIn'&&$u['queue_status']==='LoggedIn'?'Available':'Logged Out','agent_max_no_answer'=>0,'agent_call_timeout'=>$r['ring_timeout'],'agent_wrap_up_time'=>$r['wrap_up'],'agent_reject_delay_time'=>2,'agent_busy_delay_time'=>2,'agent_no_answer_delay_time'=>2]);}$m['agent_uuid']=$agents[$aKey];$this->insert('v_call_center_tiers',['call_center_tier_uuid'=>uuid(),'domain_uuid'=>$domain,'call_center_queue_uuid'=>$r['uuid'],'call_center_agent_uuid'=>$m['agent_uuid'],'queue_name'=>$r['number'].'@'.$realm,'agent_name'=>$m['agent_uuid'],'tier_level'=>1,'tier_position'=>$i+1]);}unset($m);
        }unset($r);
        foreach($this->policy['receptionists'] as &$r){$r['uuid']=uuid();$r['dialplan_uuid']=$this->dialplan($r['number'],'ivr',$r['number']);$r['prompt']=$this->prompt($r['prompt']);$this->insert('v_ivr_menus',['ivr_menu_uuid'=>$r['uuid'],'domain_uuid'=>$domain,'dialplan_uuid'=>$r['dialplan_uuid'],'ivr_menu_name'=>$r['name'],'ivr_menu_extension'=>$r['number'],'ivr_menu_greet_long'=>$r['prompt'],'ivr_menu_greet_short'=>$r['prompt'],'ivr_menu_timeout'=>$r['timeout']*1000,'ivr_menu_inter_digit_timeout'=>2000,'ivr_menu_max_failures'=>3,'ivr_menu_max_timeouts'=>1,'ivr_menu_digit_len'=>1,'ivr_menu_context'=>$realm,'ivr_menu_enabled'=>true,'ivr_menu_description'=>'Restored from 3CX']);foreach($r['options'] as $i=>$o)$this->insert('v_ivr_menu_options',['ivr_menu_option_uuid'=>uuid(),'domain_uuid'=>$domain,'ivr_menu_uuid'=>$r['uuid'],'ivr_menu_option_digits'=>$o['digit'],'ivr_menu_option_action'=>'menu-exec-app','ivr_menu_option_param'=>'lua app.lua pbx_setup ivr_key '.$r['number'].':'.$o['digit'],'ivr_menu_option_order'=>$i+1,'ivr_menu_option_enabled'=>true]);}unset($r);
        foreach($this->policy['scripts'] as &$r){$r['dialplan_uuid']=$this->dialplan($r['number'],'script',$r['number']);}unset($r);
        foreach($this->policy['inbound_rules'] as $i=>&$r){$r['rule_id']=uuid();$r['enabled']=false;$r['dialplan_uuid']=$this->dialplan($r['condition']==='BasedOnDID'?ltrim($r['number'],'*'):$this->policy['trunks'][$r['trunk_id']]['main_number'],'incoming',$r['rule_id'],100+$i,'ingress@'.$realm,false,'c03b422e-13a8-bd1b-e42b-b6b9b4d27ce4');$this->insert('v_destinations',['destination_uuid'=>$r['rule_id'],'domain_uuid'=>$domain,'dialplan_uuid'=>$r['dialplan_uuid'],'destination_type'=>'inbound','destination_number'=>$r['number']?:$this->policy['trunks'][$r['trunk_id']]['main_number'],'destination_context'=>'ingress@'.$realm,'destination_app'=>'lua','destination_data'=>'app.lua pbx_setup incoming '.$r['rule_id'],'destination_enabled'=>false,'destination_type_voice'=>1,'destination_description'=>$r['name'],'destination_order'=>100+$i]);}unset($r);
        foreach($this->policy['phones'] as &$r){$r['uuid']=uuid();$u=$this->policy['users'][$r['number']];$vendor=str_contains($r['template'],'fanvil')?'fanvil':'generic';$this->insert('v_devices',['device_uuid'=>$r['uuid'],'domain_uuid'=>$domain,'device_address'=>$r['mac'],'device_label'=>$u['name'],'device_vendor'=>$vendor,'device_template'=>$vendor==='fanvil'?'fanvil/x4':'generic','device_enabled'=>true,'device_description'=>'Restored phone. Set the new server address.']);$password=$this->query('select password from v_extensions where domain_uuid=:d and extension_uuid=:id',['d'=>$domain,'id'=>$u['extension_uuid']])->fetchColumn();$this->insert('v_device_lines',['device_line_uuid'=>uuid(),'domain_uuid'=>$domain,'device_uuid'=>$r['uuid'],'line_number'=>1,'server_address'=>'call.openweb.co.za','server_address_primary'=>'call.openweb.co.za','outbound_proxy_primary'=>'call.openweb.co.za','label'=>$u['number'],'display_name'=>$u['name'],'user_id'=>$u['auth_id'],'auth_id'=>$u['auth_id'],'password'=>$password,'sip_port'=>'5060','sip_transport'=>'udp','register_expires'=>180,'enabled'=>true]);
            $this->phoneKeys($r);unset($r['settings']);}unset($r);
        foreach($this->policy['contacts'] as $r){$id=uuid();$this->insert('v_contacts',['contact_uuid'=>$id,'domain_uuid'=>$domain,'contact_type'=>'person','contact_name_given'=>$r['first_name'],'contact_name_family'=>$r['last_name'],'contact_organization'=>$r['company'],'contact_note'=>'Imported address book for '.$r['owner']]);if($r['phone']!=='')$this->insert('v_contact_phones',['contact_phone_uuid'=>uuid(),'domain_uuid'=>$domain,'contact_uuid'=>$id,'phone_number'=>$r['phone'],'phone_type_voice'=>1,'phone_primary'=>true]);}
        foreach($this->policy['specials'] as $r){if($r['kind']==='SpecialMenu')$this->dialplan($r['number'],'voicemail_login',$r['number']);elseif($r['kind']==='ParkExtension'&&str_starts_with($r['number'],'SP'))$this->dialplan($r['number'],'park',$r['number']);}
        $greetings=$this->importGreetings($domain,$realm,$this->policy['users']);
        $history=0;$vm=0;if($archive){$zip=new ZipArchive();if($zip->open($archive,ZipArchive::RDONLY)!==true)throw new RuntimeException('The backup is unavailable.');try{$history=$this->history($zip);$vm=$this->voicemail($zip);$this->recordings($zip);}finally{$zip->close();}}
        $notes=$plan['unsupported'];
        if($this->missingPrompts)$notes[]=['category'=>'Audio files','count'=>count($this->missingPrompts),'reason'=>'These call prompts are named in the settings but are missing from the original backup. Upload replacements in Call Handling.'];
        if($greetings['selection_required'])$notes[]=['category'=>'Voicemail greetings','count'=>$greetings['selection_required'],'reason'=>'Greeting files are restored. The backup does not identify the active greeting; choose it under Users → Voicemail.'];
        $report=threecx_v20::counts($plan)+['recordings'=>count(array_filter($this->media,fn($m)=>$m['category']==='recordings')),'voicemail_files'=>count(array_filter($this->media,fn($m)=>$m['category']==='voicemails')),'voicemail_messages'=>$vm,'voicemail_greetings'=>$greetings['files'],'prompts'=>count(array_filter($this->media,fn($m)=>$m['category']==='prompts')),'call_history'=>$history,'contacts'=>count($this->policy['contacts']),'notes'=>$notes];
        $this->insert('v_pbx_restore',['domain_uuid'=>$domain,'source_version'=>$plan['source_version'],'config'=>json_encode($this->policy,JSON_THROW_ON_ERROR),'report'=>json_encode($report,JSON_THROW_ON_ERROR)]);
        return $report;
    }
    /** Also supports an idempotent upgrade of an already restored, privately stored PBX. */
    public function importGreetings(string $domain,string $realm,array &$users): array {
        if(!$this->db->inTransaction()||!is_uuid($domain)||!preg_match('/^[a-z0-9.-]+$/D',$realm))throw new LogicException('Greeting restore requires a PBX transaction.');
        $files=0;$owners=[];
        $rows=$this->query("select media_uuid,owner_number,file_path,title from v_pbx_media where domain_uuid=:d and category='prompts' and source_path like 'vmailprompts/%' order by source_path",['d'=>$domain])->fetchAll(PDO::FETCH_ASSOC);
        foreach($rows as $m){$number=$m['owner_number'];if(!isset($users[$number]))continue;
            $source='Imported audio '.$m['media_uuid'];$id=$this->query('select greeting_id from v_voicemail_greetings where domain_uuid=:d and voicemail_id=:n and greeting_description=:f',['d'=>$domain,'n'=>$number,'f'=>$source])->fetchColumn();
            if($id===false){$id=max(100,(int)$this->query('select coalesce(max(greeting_id),0)+1 from v_voicemail_greetings where domain_uuid=:d and voicemail_id=:n',['d'=>$domain,'n'=>$number])->fetchColumn());
                $dir='/var/lib/freeswitch/storage/voicemail/default/'.$realm.'/'.$number;if(!is_dir($dir)&&!mkdir($dir,0700,true))throw new RuntimeException('Voicemail storage is unavailable.');$path=$dir.'/greeting_'.$id.'.wav';
                if(file_exists($path)||!copy($m['file_path'],$path))throw new RuntimeException('A voicemail greeting could not be restored.');chmod($path,0600);$this->mediaFiles[]=$path;
                $this->insert('v_voicemail_greetings',['voicemail_greeting_uuid'=>uuid(),'domain_uuid'=>$domain,'voicemail_id'=>$number,'greeting_id'=>$id,'greeting_filename'=>'greeting_'.$id.'.wav','greeting_description'=>$source,'greeting_name'=>$m['title']]);
            }
            if(!isset($owners[$number])){$users[$number]['greetings']=[];$owners[$number]=true;}
            $users[$number]['greetings'][]=['id'=>(string)$id,'title'=>$m['title'],'media_uuid'=>$m['media_uuid']];$files++;
        }
        $choices=0;foreach(array_keys($owners) as $number){$id=$this->query('select greeting_id from v_voicemails where domain_uuid=:d and voicemail_id=:n',['d'=>$domain,'n'=>$number])->fetchColumn();$users[$number]['greeting_id']=$id===null||$id===false?'':(string)$id;if($users[$number]['greeting_id']==='')$choices++;}
        return ['files'=>$files,'selection_required'=>$choices];
    }
    private function extract(string $archive): void {
        // Recheck the entire archive before writing. Never extractAll or trust filenames.
        threecx_backup::analyze($archive);$root=self::MEDIA_ROOT.'/'.$this->domain;
        if(file_exists($root))throw new RuntimeException('This PBX already has restored files.');
        if(!is_dir(self::MEDIA_ROOT)&&!mkdir(self::MEDIA_ROOT,0700,true))throw new RuntimeException('Backup storage is unavailable.');
        if(!mkdir($root,0700))throw new RuntimeException('Backup storage is unavailable.');$this->mediaFiles[]=$root;
        $zip=new ZipArchive();$zip->open($archive,ZipArchive::RDONLY);$total=0;
        try{for($i=0;$i<$zip->numFiles;$i++){$s=$zip->statIndex($i);$name=$s['name'];if(!preg_match('#^(recordings|voicemails|httpprompts|vmailprompts)/.+\.wav$#iD',$name,$m))continue;
            if($s['size']>268435456)throw new InvalidArgumentException('A recording is too large.');$id=uuid();$target=$root.'/'.$id.'.wav';$in=$zip->getStreamIndex($i);$out=fopen($target,'xb');if(!$in||!$out)throw new RuntimeException('A recording could not be restored.');$written=0;$header='';
            try{while(!feof($in)){$buf=fread($in,1048576);if($buf===false)throw new RuntimeException('A recording could not be read.');if($written===0)$header=substr($buf,0,12);$written+=strlen($buf);$total+=strlen($buf);if($written>$s['size']||$total>threecx_backup::MAX_ARCHIVE_BYTES)throw new InvalidArgumentException('The recordings exceed the backup limit.');if(fwrite($out,$buf)!==strlen($buf))throw new RuntimeException('Backup storage is full.');}}finally{fclose($in);fclose($out);}
            if($written!==$s['size']||substr($header,0,4)!=='RIFF'||substr($header,8,4)!=='WAVE')throw new InvalidArgumentException('The backup contains an invalid WAV recording.');chmod($target,0600);
            $category=in_array($m[1],['httpprompts','vmailprompts'],true)?'prompts':$m[1];$owner=explode('/',$name)[1]??'';$row=['media_uuid'=>$id,'domain_uuid'=>$this->domain,'category'=>$category,'source_path'=>$name,'file_path'=>$target,'title'=>basename($name),'owner_number'=>isset($this->policy['users'][$owner])?$owner:null];$this->insert('v_pbx_media',$row);$this->media[$name]=$row;
            if($category==='prompts')$this->insert('v_recordings',['recording_uuid'=>uuid(),'domain_uuid'=>$this->domain,'recording_filename'=>$target,'recording_name'=>basename($name),'recording_description'=>'Restored 3CX prompt']);
        }}finally{$zip->close();}
    }
    private function prompt(string $source): string {
        if($source==='')return '';$source=str_replace('\\','/',$source);$base=basename($source);$matches=[];
        foreach($this->media as $name=>$m)if($m['category']==='prompts'&&strcasecmp(basename($name),$base)===0)$matches[$m['file_path']]=true;
        if(isset($this->media[$source]))return $this->media[$source]['file_path'];
        if(count($matches)===1)return array_key_first($matches);
        // Some backups include identical global prompts under two user directories.
        if(count($matches)>1){$paths=array_keys($matches);$hash=hash_file('sha256',$paths[0]);if(count(array_filter($paths,fn($p)=>hash_file('sha256',$p)!==$hash))===0)return $paths[0];}
        if($matches)throw new InvalidArgumentException('A call prompt has conflicting copies.');
        $this->missingPrompts[$base]=true;return '';
    }
    private function phoneKeys(array $phone): void {
        if($phone['settings']==='')return;if(preg_match('/<!\s*(?:DOCTYPE|ENTITY)/i',$phone['settings']))throw new InvalidArgumentException('A phone configuration is invalid.');$d=new DOMDocument();if(!$d->loadXML($phone['settings'],LIBXML_NONET|LIBXML_NOBLANKS))throw new InvalidArgumentException('A phone configuration is invalid.');$xp=new DOMXPath($d);$i=0;
        foreach($xp->query('//BLFS/*') as $blf){$value=$blf->getAttribute('value')?:$blf->getAttribute('extension');if($value===''||!preg_match('/^[0-9*#SP]{1,15}$/D',$value))continue;$this->insert('v_device_keys',['device_key_uuid'=>uuid(),'domain_uuid'=>$this->domain,'device_uuid'=>$phone['uuid'],'device_key_id'=>++$i,'device_key_category'=>'line','device_key_vendor'=>str_contains($phone['template'],'fanvil')?'fanvil':'generic','device_key_type'=>'blf','device_key_value'=>$value,'device_key_extension'=>$phone['number'],'device_key_line'=>'1']);}
    }
    private function csv(ZipArchive $z,string $name): Generator {
        $i=$z->locateName($name);if($i===false)return;$s=$z->getStreamIndex($i);if(!$s)throw new RuntimeException('Call history is unreadable.');$bytes=0;$rows=0;
        try{$header=fgetcsv($s,1048576,',','"','');if(!$header)return;$header[0]=ltrim($header[0],"\xef\xbb\xbf");while(($row=fgetcsv($s,1048576,',','"',''))!==false){$bytes+=array_sum(array_map('strlen',$row));if(++$rows>200000||$bytes>268435456)throw new InvalidArgumentException('Call history exceeds the restore limit.');if(count($row)!==count($header))throw new InvalidArgumentException('Call history contains a damaged row.');yield array_combine($header,$row);}}finally{fclose($s);}
    }
    private function date(string $value): ?string {
        if($value===''||$value==='0')return null;if(preg_match('/^\d{14}\.\d+$/D',$value)){$d=DateTimeImmutable::createFromFormat('YmdHis',substr($value,0,14),new DateTimeZone('UTC'));return $d?$d->format('c'):null;}
        try{return (new DateTimeImmutable($value,new DateTimeZone('UTC')))->format('c');}catch(Throwable){return null;}
    }
    private function history(ZipArchive $z): int {
        $sql='insert into v_pbx_call_history(history_uuid,domain_uuid,owner_number,party_number,party_name,call_type,start_time,answer_time,end_time,end_status,source_id) values(:id,:d,:owner,:party,:name,:type,:start,:answer,:end,:status,:source)';$s=$this->db->prepare($sql);$count=0;
        foreach($this->csv($z,'DbTables/myphone_callhistory_v14.csv') as $r){$s->execute(['id'=>uuid(),'d'=>$this->domain,'owner'=>$r['dnowner'],'party'=>$r['party_dn']?:$r['party_callerid'],'name'=>$r['party_name'],'type'=>$r['calltype'],'start'=>$this->date($r['start_time']),'answer'=>$this->date($r['established_time']),'end'=>$this->date($r['end_time']),'status'=>$r['end_status'],'source'=>$r['idmpch14']]);$count++;}return $count;
    }
    private function voicemail(ZipArchive $z): int {
        $map=[];$raw=$z->getFromName('OtherSettings/MappingTable.xml');if($raw!==false){if(strlen($raw)>1048576||preg_match('/<!\s*(?:DOCTYPE|ENTITY)/i',$raw))throw new InvalidArgumentException('The voicemail index is invalid.');$d=new DOMDocument();$d->loadXML($raw,LIBXML_NONET);foreach($d->getElementsByTagName('DN') as $n)$map[$n->getAttribute('ID')]=$n->getAttribute('No');}
        $count=0;$restored=[];foreach($this->csv($z,'DbTables/s_voicemail.csv') as $r){$number=$map[$r['callee']]??$r['callee'];$u=$this->policy['users'][$number]??null;$source='voicemails/'.$number.'/'.basename(str_replace('\\','/',$r['wav_file'])).(str_ends_with(strtolower($r['wav_file']),'.wav')?'':'.wav');$media=$this->media[$source]??null;
            if(!$media){foreach($this->media as $m)if($m['category']==='voicemails'&&basename($m['source_path'])===basename($r['wav_file']).(str_ends_with(strtolower($r['wav_file']),'.wav')?'':'.wav')){$media=$m;break;}}
            if(!$u||!$media||in_array(strtolower($r['removed']),['true','t','1'],true))continue;
            $id=uuid();$epoch=strtotime($this->date($r['created_time'])??'now');$heard=in_array(strtolower($r['heard']),['true','t','1'],true);$this->insert('v_voicemail_messages',['voicemail_message_uuid'=>$id,'domain_uuid'=>$this->domain,'voicemail_uuid'=>$u['voicemail_uuid'],'created_epoch'=>$epoch,'read_epoch'=>$heard?strtotime($this->date($r['heard_time'])??'now'):null,'caller_id_name'=>$r['caller_name'],'caller_id_number'=>$r['caller'],'message_length'=>(int)$r['duration'],'message_status'=>$heard?'saved':'new','message_transcription'=>$r['transcription']]);
            $dir='/var/lib/freeswitch/storage/voicemail/default/'.$this->realm.'/'.$number;if(!is_dir($dir)&&!mkdir($dir,0700,true))throw new RuntimeException('Voicemail storage is unavailable.');$path=$dir.'/msg_'.$id.'.wav';if(!copy($media['file_path'],$path))throw new RuntimeException('A voicemail could not be restored.');chmod($path,0600);$this->mediaFiles[]=$path;
            $this->query('update v_pbx_media set owner_number=:n,created_at=:date,duration=:duration where media_uuid=:id',['n'=>$number,'date'=>$this->date($r['created_time']),'duration'=>(int)$r['duration'],'id'=>$media['media_uuid']]);$restored[$media['media_uuid']]=true;$count++;}
        // The supplied backup has audio that is absent from its stale voicemail index.
        // Recover those messages from their owning folder and original timestamp.
        foreach($this->media as $m){if($m['category']!=='voicemails'||isset($restored[$m['media_uuid']])||!$m['owner_number'])continue;$number=$m['owner_number'];$u=$this->policy['users'][$number];$name=basename($m['source_path']);$date=null;$caller='';if(preg_match('/^vmail_(.*?)_[0-9]+_([0-9]{14})\.wav$/iD',$name,$parts)){$date=$this->date($parts[2].'.00');$caller=$parts[1];}
            $id=uuid();$length=$this->wavDuration($m['file_path']);$this->insert('v_voicemail_messages',['voicemail_message_uuid'=>$id,'domain_uuid'=>$this->domain,'voicemail_uuid'=>$u['voicemail_uuid'],'created_epoch'=>strtotime($date??'now'),'caller_id_number'=>$caller,'caller_id_name'=>'','message_length'=>$length,'message_status'=>'new']);$dir='/var/lib/freeswitch/storage/voicemail/default/'.$this->realm.'/'.$number;if(!is_dir($dir))mkdir($dir,0700,true);$path=$dir.'/msg_'.$id.'.wav';if(!copy($m['file_path'],$path))throw new RuntimeException('A voicemail could not be restored.');chmod($path,0600);$this->mediaFiles[]=$path;$this->query('update v_pbx_media set created_at=:date,duration=:duration where media_uuid=:id',['date'=>$date,'duration'=>$length,'id'=>$m['media_uuid']]);$count++;
        }
        return $count;
    }
    private function wavDuration(string $path): int {
        $f=fopen($path,'rb');fseek($f,12);$rate=0;$data=0;
        try{for($i=0;$i<30&&!feof($f);$i++){$h=fread($f,8);if(strlen($h)!==8)break;$size=unpack('V',substr($h,4))[1];if(substr($h,0,4)==='fmt '){$v=fread($f,min($size,32));if(strlen($v)>=12)$rate=unpack('V',substr($v,8,4))[1];if($size>strlen($v))fseek($f,$size-strlen($v),SEEK_CUR);}elseif(substr($h,0,4)==='data'){$data=$size;break;}else fseek($f,$size+($size%2),SEEK_CUR);}}finally{fclose($f);}return $rate?max(1,(int)round($data/$rate)):1;
    }
    private function recordings(ZipArchive $z): void {
        foreach($this->csv($z,'DbTables/recordings.csv') as $r){$url=urldecode(str_replace('\\','/',$r['recording_url']));foreach($this->media as $m)if($m['category']==='recordings'&&str_ends_with($m['source_path'],$url)){$start=$this->date($r['start_time']);$end=$this->date($r['end_time']);$this->query('update v_pbx_media set created_at=:date,duration=:duration where media_uuid=:id',['date'=>$start,'duration'=>$start&&$end?max(0,strtotime($end)-strtotime($start)):null,'id'=>$m['media_uuid']]);break;}}
    }
    public function rollbackFiles(): void {
        foreach(array_reverse($this->mediaFiles) as $path){if(is_file($path))unlink($path);elseif(is_dir($path)){foreach(glob($path.'/*.wav')?:[] as $f)unlink($f);rmdir($path);}}$this->mediaFiles=[];
    }
}
