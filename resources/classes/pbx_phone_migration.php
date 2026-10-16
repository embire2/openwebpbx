<?php
/** Guided phone handover, keeping source identity proofs separate from hardware acceptance. */
class pbx_phone_migration {
    protected PDO $db;
    private string $domain;
    private pbx_admin $admin;
    public function __construct(?PDO $db=null){$this->db=$db??database::new()->db;$this->domain=$_SESSION['domain_uuid'];$this->admin=new pbx_admin($this->db);}
    protected function engine(string $command): string {return (string)event_socket::api($command);}
    protected function key(): string {$key=@file_get_contents(pbx_paths::key());if(!is_string($key)||strlen($key)!==32)throw new RuntimeException('Private phone-setting encryption is unavailable.');return $key;}
    protected function address(): string {return (new pbx_sip_domains($this->db))->primary();}
    public function connection(int $port,string $transport): array {
        $raw=$this->engine('sofia status');$running=[];
        foreach(['internal','internal-ipv6']as$name)if(preg_match('/^\s*'.preg_quote($name,'/').($transport==='tls'?'\:\:tls':'').'\s+profile\s+.*\sRUNNING/m',$raw))$running[]=$name;
        $rows=$this->q("select p.sip_profile_name,s.sip_profile_setting_name,s.sip_profile_setting_value from v_sip_profiles p join v_sip_profile_settings s using(sip_profile_uuid) where p.sip_profile_enabled=true and p.sip_profile_name in ('internal','internal-ipv6') and s.sip_profile_setting_enabled=true and s.sip_profile_setting_name in ('sip-port','tls-sip-port','tls')")->fetchAll(PDO::FETCH_ASSOC);$profiles=[];
        foreach($rows as$r)$profiles[$r['sip_profile_name']][$r['sip_profile_setting_name']]=$r['sip_profile_setting_value'];$ok=false;
        foreach($profiles as$name=>$settings)if(in_array($name,$running,true)&&(int)($settings[$transport==='tls'?'tls-sip-port':'sip-port']??0)===$port&&($transport!=='tls'||filter_var($settings['tls']??false,FILTER_VALIDATE_BOOLEAN)))$ok=true;
        $ready=(new pbx_sip_domains($this->db))->readiness();if($transport==='tls'&&!$ready['tls'])$ok=false;
        return ['listener'=>$ok,'dns'=>(bool)$ready['dns'],'tls'=>$transport!=='tls'||(bool)$ready['tls'],'message'=>$ok?'The saved phone port and connection type are enabled.':'The saved phone port or connection type is not ready. Ask the instance administrator to enable that same phone listener; keep the phone credentials unchanged.'];
    }
    private function q(string $sql,array $p=[]): PDOStatement {$s=$this->db->prepare($sql);$s->execute($p);return $s;}
    private function text(array $in,string $key,int $max=120): string {$v=$in[$key]??'';if(!is_string($v)||strlen($v)>$max||preg_match('/[\x00-\x1f\x7f]/',$v))throw new InvalidArgumentException('Enter a valid '.str_replace('_',' ',$key).'.');return trim($v);}
    public static function identityProof(string $domain,string $number,string $auth,string $password,string $key): string {
        if(!is_uuid($domain)||strlen($key)!==32)throw new RuntimeException('Original identity proof is unavailable.');
        return hash_hmac('sha256',json_encode([$domain,$number,$auth,$password],JSON_THROW_ON_ERROR),$key);
    }
    private function identity(array $c,string $number): array {
        $u=$c['users'][$number]??null;if(!$u)throw new InvalidArgumentException('Choose a user in this PBX.');
        $r=$this->q('select extension,password,number_alias from v_extensions where domain_uuid=? and extension_uuid=?',[$this->domain,$u['extension_uuid']])->fetch(PDO::FETCH_ASSOC);
        if(!$r||!hash_equals($u['auth_id'],(string)$r['extension'])||!is_string($r['password'])||$r['password']==='')throw new RuntimeException('The saved phone identity needs review. Do not reset its password.');
        return ['number'=>$number,'sip_user'=>$u['contact_user']??$number,'auth_id'=>$u['auth_id'],'password'=>$r['password'],'extension_uuid'=>$u['extension_uuid']];
    }
    private function proof(array $id): string {return self::identityProof($this->domain,$id['number'],$id['auth_id'],$id['password'],$this->key());}
    private function policy(array $c,array $move): string {
        $policy=[];foreach(['users','trunks','departments','ring_groups','queues','receptionists','scripts','inbound_rules','outbound_rules','calling_rules']as$k)$policy[$k]=$c[$k]??[];
        return hash_hmac('sha256',json_encode([$this->domain,$move['number'],$move['model'],$move['phone_domain'],(int)$move['sip_port'],$move['transport'],$policy],JSON_THROW_ON_ERROR),$this->key());
    }
    /** A read-only comparison with a backup can add proofs; it never reapplies its settings. */
    public function inspectBackup(string $path): array {
        $plan=threecx_backup::analyze($path);if(($plan['source_version']??'')!=='20.0.9.995'||!isset($plan['v20']))throw new InvalidArgumentException('Use a supported 3CX V20 Update 9 backup.');
        $this->db->beginTransaction();try{$c=$this->admin->config(true);$matched=[];$issues=[];
            foreach($plan['users']as$u){$n=(string)$u['number'];if(!isset($c['users'][$n])){$issues[]=['number'=>$n,'reason'=>'This source user has not been restored.'];continue;}$id=$this->identity($c,$n);
                if(!hash_equals($id['auth_id'],$u['auth_id'])||!hash_equals($id['password'],$u['password'])){$issues[]=['number'=>$n,'reason'=>'The saved authentication ID or SIP password differs from the backup.'];continue;}
                $c['users'][$n]['restore_identity_hmac']=$this->proof($id);$matched[]=$n;
            }
            $this->q('update v_pbx_restore set config=?::jsonb where domain_uuid=?',[json_encode($c,JSON_THROW_ON_ERROR),$this->domain]);$this->db->commit();
            return ['matched'=>count($matched),'source_users'=>count($plan['users']),'issues'=>$issues,'credentials_changed'=>false,'settings_reapplied'=>false];
        }catch(Throwable$e){if($this->db->inTransaction())$this->db->rollBack();throw$e;}
    }
    public function inspectUpload(array $file): array {
        if(($file['error']??UPLOAD_ERR_NO_FILE)!==UPLOAD_ERR_OK||!is_uploaded_file($file['tmp_name']??'')||($file['size']??0)>threecx_backup::MAX_UPLOAD_BYTES)throw new InvalidArgumentException('Upload the original supported 3CX backup.');
        return $this->inspectBackup($file['tmp_name']);
    }
    public function prepare(array $in,?string $configuration=null): string {
        $number=$this->text($in,'number',10);$model=$this->text($in,'model',30);$firmware=$this->text($in,'firmware',80);$old=pbx_sip_domain::validate($this->text($in,'old_domain',253));$mac=strtolower(str_replace(['-',':'],'',$this->text($in,'mac',32)));$transport=$this->text($in,'transport',3);
        $line=filter_var($in['line_number']??null,FILTER_VALIDATE_INT,['options'=>['min_range'=>1,'max_range'=>$model==='fanvil_v62w'?6:8]]);$port=filter_var($in['sip_port']??null,FILTER_VALIDATE_INT,['options'=>['min_range'=>1,'max_range'=>65535]]);
        if(!in_array($model,['yealink_w60b','fanvil_v62w'],true)||$firmware===''||$old===''||($mac!==''&&!preg_match('/^[a-f0-9]{12}$/D',$mac))||!in_array($transport,['udp','tcp','tls'],true)||$line===false||$port===false)throw new InvalidArgumentException('Enter the existing phone model, firmware, SIP account, port and connection type.');
        $this->db->beginTransaction();try{$c=$this->admin->config(true);$identity=$this->identity($c,$number);$proof=$this->proof($identity);$verified=isset($c['users'][$number]['restore_identity_hmac'])&&hash_equals($c['users'][$number]['restore_identity_hmac'],$proof);
            if(!$verified&&empty($in['new_phone']))throw new InvalidArgumentException('Check the source backup first. For a new phone without an original backup, choose New Phone explicitly.');
            $target=$this->address();if($target===$old)throw new InvalidArgumentException('Choose a new phone domain before moving this phone.');
            $cipher=null;$sha=null;
            if($configuration!==null){$patch=pbx_phone_domain_patch::patch($configuration,$model,$line,$old,$target,$identity);if(($patch['sip_port']!==null&&(int)$patch['sip_port']!==$port)||($patch['transport']!==null&&$patch['transport']!==$transport))throw new InvalidArgumentException('Keep the port and connection type shown in the original phone export.');$sha=hash('sha256',$configuration);$nonce=random_bytes(SODIUM_CRYPTO_SECRETBOX_NONCEBYTES);$cipher=base64_encode($nonce.sodium_crypto_secretbox(json_encode(['domain'=>$this->domain,'number'=>$number,'original'=>$configuration,'sha256'=>$sha],JSON_THROW_ON_ERROR),$nonce,$this->key()));}
            $move=['number'=>$number,'model'=>$model,'phone_domain'=>$target,'sip_port'=>$port,'transport'=>$transport];$hash=$this->policy($c,$move);$id=uuid();
            $this->q('insert into v_pbx_phone_moves(move_uuid,domain_uuid,extension_uuid,number,model,firmware,line_number,mac,old_domain,phone_domain,sip_port,transport,identity_hmac,policy_hmac,backup_verified,provisioning_reviewed,source_ciphertext,source_sha256,created_by) values(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?::boolean,?::boolean,?,?,?) on conflict(domain_uuid,extension_uuid,mac,line_number) do update set model=excluded.model,firmware=excluded.firmware,old_domain=excluded.old_domain,phone_domain=excluded.phone_domain,sip_port=excluded.sip_port,transport=excluded.transport,identity_hmac=excluded.identity_hmac,policy_hmac=excluded.policy_hmac,backup_verified=excluded.backup_verified,provisioning_reviewed=excluded.provisioning_reviewed,source_ciphertext=excluded.source_ciphertext,source_sha256=excluded.source_sha256,export_expires=now()+interval \'48 hours\',created_at=now(),created_by=excluded.created_by returning move_uuid',[$id,$this->domain,$identity['extension_uuid'],$number,$model,$firmware,$line,$mac,$old,$target,$port,$transport,$proof,$hash,$verified?'true':'false',!empty($in['provisioning_reviewed'])?'true':'false',$cipher,$sha,$_SESSION['user_uuid']]);
            $id=$this->q('select move_uuid from v_pbx_phone_moves where domain_uuid=? and extension_uuid=? and mac=? and line_number=?',[$this->domain,$identity['extension_uuid'],$mac,$line])->fetchColumn();$this->db->commit();return $id;
        }catch(Throwable$e){if($this->db->inTransaction())$this->db->rollBack();throw$e;}
    }
    private function move(string $id): array {
        if(!is_uuid($id))throw new InvalidArgumentException('Choose a saved phone.');$r=$this->q('select * from v_pbx_phone_moves where domain_uuid=? and move_uuid=?',[$this->domain,$id])->fetch(PDO::FETCH_ASSOC);if(!$r)throw new InvalidArgumentException('Choose a saved phone from this PBX.');return $r;
    }
    private function current(array $move,array $c): void {
        if($move['phone_domain']!==$this->address()||!hash_equals($move['identity_hmac'],$this->proof($this->identity($c,$move['number'])))||!hash_equals($move['policy_hmac'],$this->policy($c,$move)))throw new InvalidArgumentException('Phone details or call routes changed. Prepare this phone again and repeat its call checks.');
    }
    public function export(string $id,bool $original=false): array {
        $move=$this->move($id);$c=$this->admin->config();$this->current($move,$c);
        if(!$move['source_ciphertext']||strtotime($move['export_expires'])<=time())throw new InvalidArgumentException('This private export expired. Upload the phone configuration again.');
        $raw=base64_decode($move['source_ciphertext'],true);if(!$raw||strlen($raw)<40)throw new RuntimeException('The private phone export is unavailable.');$plain=sodium_crypto_secretbox_open(substr($raw,24),substr($raw,0,24),$this->key());if($plain===false)throw new RuntimeException('The private phone export could not be verified.');$payload=json_decode($plain,true,512,JSON_THROW_ON_ERROR);
        if($payload['domain']!==$this->domain||$payload['number']!==$move['number']||!hash_equals($payload['sha256'],hash('sha256',$payload['original'])))throw new RuntimeException('Phone export ownership or integrity differs.');
        $patch=pbx_phone_domain_patch::patch($payload['original'],$move['model'],(int)$move['line_number'],$move['old_domain'],$move['phone_domain'],$this->identity($c,$move['number']));
        return ['bytes'=>$original?$payload['original']:$patch['bytes'],'filename'=>'openwebpbx-'.$move['number'].($original?'-original':'-new-domain').'.'.$patch['format'],'changed_fields'=>$patch['changed_fields']];
    }
    public function overview(): array {
        $c=$this->admin->config();$connections=[];$rows=$this->q('select move_uuid,number,model,firmware,line_number,mac,old_domain,phone_domain,sip_port,transport,identity_hmac,policy_hmac,backup_verified,provisioning_reviewed,source_ciphertext is not null as has_export,created_at from v_pbx_phone_moves where domain_uuid=? order by number,mac,line_number',[$this->domain])->fetchAll(PDO::FETCH_ASSOC);
        foreach($rows as&$r){try{$this->current($r,$c);$r['current']=true;}catch(InvalidArgumentException){$r['current']=false;}$r['checks']=$this->q('select distinct check_kind from v_pbx_phone_move_checks where domain_uuid=? and move_uuid=? and policy_hmac=?',[$this->domain,$r['move_uuid'],$r['policy_hmac']])->fetchAll(PDO::FETCH_COLUMN);$r['registered']=false;
            if($r['current']){try{$u=$c['users'][$r['number']];foreach(array_unique([$r['phone_domain'],$c['realm']])as$realm){$contact=trim($this->engine('sofia_contact '.$u['auth_id'].'@'.$realm));if(str_starts_with($contact,'sofia/')){$r['registered']=true;break;}}}catch(Throwable){}}
            $connectionKey=$r['sip_port'].'/'.$r['transport'];$r['connection']=$connections[$connectionKey]??=$this->connection((int)$r['sip_port'],$r['transport']);$r['ready']=$r['current']&&$r['registered']&&$r['connection']['listener']&&$r['connection']['dns']&&$r['provisioning_reviewed']&&count(array_diff(self::steps(),$r['checks']))===0;unset($r['identity_hmac'],$r['policy_hmac']);
        }unset($r);return $rows;
    }
    public static function steps(): array {return ['internal_out','internal_in','incoming','outgoing','hold_resume','transfer','group_queue','voicemail'];}
    public function record(array $in): void {
        $move=$this->move($this->text($in,'move',36));$c=$this->admin->config();$this->current($move,$c);$kind=$this->text($in,'step',24);$id=$this->text($in,'call_uuid',36);
        if(!in_array($kind,self::steps(),true)||!is_uuid($id)||empty($in['confirmed_phone'])||empty($in['confirmed_audio']))throw new InvalidArgumentException('Select the completed test call and confirm the actual phone and two-way sound.');
        $call=$this->q('select direction,caller_id_number,destination_number,extension_uuid,billsec,start_stamp,json from v_xml_cdr where domain_uuid=? and xml_cdr_uuid=? and start_stamp>=? and start_stamp>now()-interval \'48 hours\'',[$this->domain,$id,$move['created_at']])->fetch(PDO::FETCH_ASSOC);
        if(!$call||(int)$call['billsec']<=0)throw new InvalidArgumentException('Choose an answered call made after preparing this phone.');
        $variables=[];if(is_string($call['json'])&&strlen($call['json'])<=2097152){$decoded=json_decode($call['json'],true);$variables=is_array($decoded['variables']??null)?$decoded['variables']:[];}
        $n=$move['number'];$origin=(string)($variables['openweb_scope_origin']??'');$target=(string)($variables['openweb_scope_target']??'');$related=$call['extension_uuid']===$move['extension_uuid']||in_array($n,[$origin,$target],true);
        if(!$related)throw new InvalidArgumentException('This call does not identify the selected extension.');
        if(in_array($kind,['internal_out','internal_in'],true)&&$call['direction']!=='local')throw new InvalidArgumentException('Choose an internal call.');
        if($kind==='internal_out'&&$origin!==$n)throw new InvalidArgumentException('Choose a call made from this phone.');
        if($kind==='internal_in'&&$target!==$n&&$call['extension_uuid']!==$move['extension_uuid'])throw new InvalidArgumentException('Choose a call received by this phone.');
        if($kind==='incoming'&&$target!==$n&&$call['extension_uuid']!==$move['extension_uuid'])throw new InvalidArgumentException('Choose a call received by this phone.');
        if($kind==='outgoing'&&$origin!==$n)throw new InvalidArgumentException('Choose a call made by this phone.');
        if(in_array($kind,['incoming','outgoing'],true)&&$call['direction']!==($kind==='incoming'?'inbound':'outbound'))throw new InvalidArgumentException('Choose the call in the required direction.');
        if($kind==='group_queue'){ $service=(string)($variables['openweb_scope_service']??'');$found=false;foreach(array_merge($c['ring_groups'],$c['queues'])as$object)if((string)$object['number']===$service)$found=true;if(!$found)throw new InvalidArgumentException('Choose a call received through a Ring Group or Call Queue.');}
        $this->q('insert into v_pbx_phone_move_checks(check_uuid,domain_uuid,move_uuid,check_kind,call_uuid,policy_hmac,note,checked_by)values(?,?,?,?,?,?,?,?)',[uuid(),$this->domain,$move['move_uuid'],$kind,$id,$move['policy_hmac'],$this->text($in,'note',500),$_SESSION['user_uuid']]);
    }
    public function calls(string $id): array {$r=$this->move($id);return $this->q("select xml_cdr_uuid,direction,caller_id_number,destination_number,billsec,start_stamp from v_xml_cdr where domain_uuid=? and billsec>0 and start_stamp>=? order by start_stamp desc limit 100",[$this->domain,$r['created_at']])->fetchAll(PDO::FETCH_ASSOC);}
    public function acceptLimitation(array $in): void {
        $hash=$this->text($in,'note_hash',64);$explanation=$this->text($in,'explanation',500);if(strlen($explanation)<15||empty($in['confirmed']))throw new InvalidArgumentException('Explain the source-data limitation and confirm acceptance.');$known=[];foreach($this->admin->report()['notes']??[]as$n)$known[]=hash('sha256',json_encode($n,JSON_THROW_ON_ERROR));if(!in_array($hash,$known,true))throw new InvalidArgumentException('Choose an unchanged Restore Report item.');
        $this->q("insert into v_pbx_migration_resolutions(resolution_uuid,domain_uuid,note_hash,decision,explanation,actor_uuid)values(?,?,?,'accepted_source_limitation',?,?)",[uuid(),$this->domain,$hash,$explanation,$_SESSION['user_uuid']]);
    }
    public function limitations(): array {return $this->q('select note_hash,explanation,created_at from v_pbx_migration_resolutions where domain_uuid=? order by created_at desc',[$this->domain])->fetchAll(PDO::FETCH_ASSOC);}
}
