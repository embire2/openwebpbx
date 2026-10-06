<?php
/** OpenWeb PBX tenant provisioning. All records are copied into a tenant-owned PBX domain. */
class pbx_tenants {
    private PDO $db;
    public function __construct(?PDO $db = null) { $this->db = $db ?? database::new()->db; $this->db->setAttribute(PDO::ATTR_ERRMODE, PDO::ERRMODE_EXCEPTION); }
    private function query(string $sql, array $params = []): PDOStatement { $s=$this->db->prepare($sql); foreach($params as $key=>$value)$s->bindValue(':'.$key,$value,$value===null?PDO::PARAM_NULL:(is_bool($value)?PDO::PARAM_BOOL:(is_int($value)?PDO::PARAM_INT:PDO::PARAM_STR)));$s->execute();return $s; }
    public function installed(): bool { return (bool)$this->query("select to_regclass('v_pbx_tenants')")->fetchColumn(); }
    protected function allowed(string $name): bool { return permission_exists($name); }
    public function platform(): bool { return $this->allowed('pbx_tenant_manage'); }
    public function tenant(): ?array {
        return $this->query('select t.* from v_pbx_tenants t join v_users u on u.user_uuid=:user where t.owner_user_uuid=u.user_uuid or t.home_domain_uuid=u.domain_uuid or exists(select 1 from v_pbx_services s where s.tenant_uuid=t.tenant_uuid and s.domain_uuid=u.domain_uuid)', ['user'=>$_SESSION['user_uuid'] ?? '00000000-0000-0000-0000-000000000000'])->fetch(PDO::FETCH_ASSOC) ?: null;
    }
    public function workspaceOnly(): bool { $t=$this->tenant(); return $t && $t['home_domain_uuid'] === ($_SESSION['domain_uuid'] ?? ''); }
    public function canDomain(string $domain): bool {
        if ($this->platform() || $this->allowed('domain_all')) return true;
        $t=$this->tenant();
        if (!$t) return $domain === ($_SESSION['user']['domain_uuid'] ?? '');
        if (!$t['enabled']) return false;
        if ($t['owner_user_uuid'] !== ($_SESSION['user_uuid'] ?? '')) return $domain === ($_SESSION['user']['domain_uuid'] ?? '');
        return $domain === $t['home_domain_uuid'] || (bool)$this->query('select 1 from v_pbx_services where tenant_uuid=:tenant and domain_uuid=:domain',['tenant'=>$t['tenant_uuid'],'domain'=>$domain])->fetchColumn();
    }
    public function guard(): void {
        if (!$this->installed() || empty($_SESSION['authorized']) || $this->allowed('domain_all')) return;
        $t=$this->tenant(); if (!$t) return;
        $enabled=$this->query('select user_enabled from v_users where user_uuid=:user',['user'=>$_SESSION['user_uuid']])->fetchColumn();
        if (!$enabled || !$t['enabled'] || !$this->canDomain($_SESSION['domain_uuid'])) { http_response_code(403); exit('This tenant account or PBX service is unavailable.'); }
        $path=parse_url($_SERVER['REQUEST_URI']??'',PHP_URL_PATH);
        if($this->workspaceOnly() && !str_starts_with($path,'/app/tenant_services/') && !str_starts_with($path,'/app/pbx_setup/') && !str_starts_with($path,'/core/desktop/') && !in_array($path,['/','/index.php','/login.php','/logout.php','/core/users/user_profile.php','/core/dashboard/'],true)) {
            http_response_code(403);exit('Create or open a PBX service from Tenant Services to use this application.');
        }
    }
    public function tenants(): array {
        if ($this->platform()) return $this->query('select t.*, (select count(*) from v_pbx_services s where s.tenant_uuid=t.tenant_uuid) service_count from v_pbx_tenants t order by created_at desc')->fetchAll(PDO::FETCH_ASSOC);
        $t=$this->tenant();return $t ? [$t] : [];
    }
    public function assertTenant(string $id, bool $owner = false): array {
        $t=$this->query('select * from v_pbx_tenants where tenant_uuid=:id',['id'=>$this->id($id)])->fetch(PDO::FETCH_ASSOC);
        $mine=$this->tenant();
        if (!$t || (!$this->platform() && (!$mine || $mine['tenant_uuid'] !== $id || ($owner && $t['owner_user_uuid'] !== $_SESSION['user_uuid'])))) throw new RuntimeException('Tenant access denied.');
        if (!$t['enabled']) throw new RuntimeException('This tenant is suspended.');
        return $t;
    }
    private function id(string $value): string { if (!is_uuid($value)) throw new InvalidArgumentException('Invalid record identifier.');return $value; }
    private function label(string $value, int $max = 120): string { $value=trim($value);if ($value==='' || mb_strlen($value)>$max || preg_match('/[\x00-\x1f]/',$value)) throw new InvalidArgumentException('Enter a valid name.');return $value; }
    private function slug(string $value): string { $value=strtolower(trim($value));if (!preg_match('/^[a-z0-9](?:[a-z0-9-]{0,38}[a-z0-9])?$/D',$value)) throw new InvalidArgumentException('Use a short name with letters, numbers, and hyphens.');return $value; }
    private function key(): string {
        $key=@file_get_contents('/etc/fusionpbx/openweb-template.key');
        if ($key===false || strlen($key)!==SODIUM_CRYPTO_SECRETBOX_KEYBYTES) throw new RuntimeException('Template encryption is not configured.');return $key;
    }
    private function seal(array $data): string { $nonce=random_bytes(SODIUM_CRYPTO_SECRETBOX_NONCEBYTES);return base64_encode($nonce.sodium_crypto_secretbox(json_encode($data,JSON_THROW_ON_ERROR),$nonce,$this->key())); }
    private function unseal(string $data): array {
        $raw=base64_decode($data,true);if (!$raw || strlen($raw)<40) throw new RuntimeException('Template data is unavailable.');
        $plain=sodium_crypto_secretbox_open(substr($raw,24),substr($raw,0,24),$this->key());if ($plain===false) throw new RuntimeException('Template data is unavailable.');return json_decode($plain,true,512,JSON_THROW_ON_ERROR);
    }
    private function insert(string $table,array $row): void {
        // Table and column identifiers are exclusively supplied by this class.
        $columns=array_keys($row);$this->query('insert into '.$table.'('.implode(',',$columns).') values('.implode(',',array_map(fn($v)=>':'.$v,$columns)).')',$row);
    }
    public function invite(array $input): string {
        if (!$this->platform()) throw new RuntimeException('Tenant management permission is required.');
        $name=$this->label($input['tenant_name'] ?? '');$slug=$this->slug($input['slug'] ?? '');$email=strtolower(trim($input['email'] ?? ''));
        if (!filter_var($email,FILTER_VALIDATE_EMAIL)) throw new InvalidArgumentException('Enter a valid administrator email.');
        if ($this->query('select 1 from v_users where lower(username)=:email or lower(user_email)=:email',['email'=>$email])->fetchColumn()) throw new InvalidArgumentException('This email already has an account.');
        $limit=filter_var($input['service_limit'] ?? 10,FILTER_VALIDATE_INT,['options'=>['min_range'=>1,'max_range'=>100]]);if (!$limit) throw new InvalidArgumentException('Service limit must be between 1 and 100.');
        $token=bin2hex(random_bytes(32));$domain=uuid();$id=uuid();
        $this->db->beginTransaction();try {
            $this->insert('v_domains',['domain_uuid'=>$domain,'domain_name'=>$slug.'.call.openweb.co.za','domain_description'=>$name.' workspace','domain_enabled'=>'true']);
            $this->insert('v_pbx_tenants',['tenant_uuid'=>$id,'tenant_name'=>$name,'slug'=>$slug,'home_domain_uuid'=>$domain,'invite_email'=>$email,'invite_hash'=>hash('sha256',$token),'invite_expires'=>gmdate('c',time()+604800),'service_limit'=>$limit]);
            $this->db->commit();
        }catch(Throwable $e){if($this->db->inTransaction())$this->db->rollBack();throw $e;}
        return '/app/tenant_services/accept.php?invite='.$token;
    }
    public function invitation(string $token): ?array {
        if (!preg_match('/^[a-f0-9]{64}$/D',$token)) return null;
        return $this->query('select * from v_pbx_tenants where invite_hash=:hash and invite_expires>now() and owner_user_uuid is null and enabled=true',['hash'=>hash('sha256',$token)])->fetch(PDO::FETCH_ASSOC) ?: null;
    }
    public function renewInvitation(string $id): string {
        if (!$this->platform()) throw new RuntimeException('Tenant management permission is required.');
        $token=bin2hex(random_bytes(32));
        $updated=$this->query('update v_pbx_tenants set invite_hash=:hash,invite_expires=:expires where tenant_uuid=:id and owner_user_uuid is null and enabled=true returning tenant_uuid',['hash'=>hash('sha256',$token),'expires'=>gmdate('c',time()+604800),'id'=>$this->id($id)])->fetchColumn();
        if (!$updated) throw new RuntimeException('Only active, unaccepted invitations can be renewed.');
        return '/app/tenant_services/accept.php?invite='.$token;
    }
    public function accept(string $token,string $password): void {
        if (strlen($password)<10 || strlen($password)>72 || str_contains($password,"\0")) throw new InvalidArgumentException('Choose a password between 10 and 72 bytes.');
        $this->db->beginTransaction();try {
            $t=$this->query('select * from v_pbx_tenants where invite_hash=:hash and invite_expires>now() and owner_user_uuid is null and enabled=true for update',['hash'=>hash('sha256',$token)])->fetch(PDO::FETCH_ASSOC);
            if (!$t) throw new RuntimeException('This invitation has expired or has already been used.');
            if ($this->query('select 1 from v_users where lower(username)=:email or lower(user_email)=:email',['email'=>$t['invite_email']])->fetchColumn()) throw new RuntimeException('This email already has an account.');
            $user=uuid();$group=$this->query("select group_uuid from v_groups where group_name='tenant_admin' and domain_uuid is null")->fetchColumn();
            $this->insert('v_users',['user_uuid'=>$user,'domain_uuid'=>$t['home_domain_uuid'],'username'=>$t['invite_email'],'user_email'=>$t['invite_email'],'password'=>password_hash($password,PASSWORD_DEFAULT),'user_enabled'=>'true','user_type'=>'default']);
            $this->insert('v_user_groups',['user_group_uuid'=>uuid(),'domain_uuid'=>$t['home_domain_uuid'],'user_uuid'=>$user,'group_uuid'=>$group,'group_name'=>'tenant_admin']);
            $this->query('update v_pbx_tenants set owner_user_uuid=:user,invite_hash=null,invite_expires=null where tenant_uuid=:id',['user'=>$user,'id'=>$t['tenant_uuid']]);$this->db->commit();
        }catch(Throwable $e){if($this->db->inTransaction())$this->db->rollBack();throw $e;}
    }
    public function suspend(string $id,bool $enabled): void {
        if (!$this->platform()) throw new RuntimeException('Tenant management permission is required.');
        $this->query('update v_pbx_tenants set enabled=:enabled where tenant_uuid=:id',['id'=>$this->id($id),'enabled'=>$enabled?'true':'false']);
    }
    public function templates(bool $manage = false): array {
        $t=$this->tenant();$params=['tenant'=>$t['tenant_uuid'] ?? '00000000-0000-0000-0000-000000000000'];
        $filter=$this->platform() ? ($manage ? 'true' : 'published=true') : ($manage ? 'tenant_uuid=:tenant' : 'published=true and (tenant_uuid is null or tenant_uuid=:tenant)');
        if ($this->platform()) $params=[];
        return $this->query('select template_uuid,tenant_uuid,template_name,description,published,version,updated_at from v_pbx_templates where '.$filter.' order by template_name',$params)->fetchAll(PDO::FETCH_ASSOC);
    }
    public function template(string $id,bool $manage = false): array {
        $r=$this->query('select * from v_pbx_templates where template_uuid=:id',['id'=>$this->id($id)])->fetch(PDO::FETCH_ASSOC);$t=$this->tenant();
        if (!$r || (!$this->platform() && (($manage && $r['tenant_uuid']!==($t['tenant_uuid']??'')) || (!$manage && (!$r['published'] || ($r['tenant_uuid']!==null && $r['tenant_uuid']!==($t['tenant_uuid']??''))))))) throw new RuntimeException('Template access denied.');
        if (!$manage && !$r['published']) throw new RuntimeException('Choose a published template.');
        $r['config']=$this->unseal($r['payload_ciphertext']);unset($r['payload_ciphertext']);return $r;
    }
    public static function settingAllowed(string $category,string $subcategory,string $type): bool {
        // Allow domain-level business settings, never authentication, roles, executable paths, or global configuration.
        $categories=['dialplan','voicemail','email','smtp','timezone','limit','recordings','call_recording','ivr','ring_group','ring_groups','call_center','conference','fax','extension','extensions','device','devices','provision','cdr','xml_cdr','contacts','sip','number_translation'];
        return in_array($category,$categories,true) && preg_match('/^[a-z][a-z0-9_]{0,79}$/D',$subcategory) && !preg_match('/(path|directory|command|script|url|domain|user_uuid|enabled_languages|security|api_key)/i',$subcategory) && in_array($type,['text','numeric','boolean','array'],true);
    }
    private function config(array $c,array $previous=[]): array {
        $c=array_intersect_key($c,array_flip(['timezone','extension_start','extension_count','extension_limit','caller_id_name','caller_id_number','trunks','rules','settings']));
        $c['timezone']=$c['timezone'] ?? 'Africa/Johannesburg';if (!in_array($c['timezone'],DateTimeZone::listIdentifiers(),true)) throw new InvalidArgumentException('Choose a valid timezone.');
        foreach(['extension_start'=>[100,999999999],'extension_count'=>[0,100],'extension_limit'=>[1,10000]] as $key=>$range){$c[$key]=filter_var($c[$key]??($key==='extension_start'?100:($key==='extension_limit'?100:0)),FILTER_VALIDATE_INT,['options'=>['min_range'=>$range[0],'max_range'=>$range[1]]]);if($c[$key]===false)throw new InvalidArgumentException('Invalid extension range or limit.');}
        if($c['extension_count']>$c['extension_limit'])throw new InvalidArgumentException('Initial extensions exceed the extension limit.');
        $c['caller_id_name']=trim($c['caller_id_name']??'');$c['caller_id_number']=trim($c['caller_id_number']??'');
        if(strlen($c['caller_id_name'])>80 || preg_match('/[\x00-\x1f]/',$c['caller_id_name']) || !preg_match('/^[+0-9]{0,20}$/D',$c['caller_id_number']))throw new InvalidArgumentException('Invalid caller ID.');
        $c['trunks']=array_values($c['trunks']??[]);$c['rules']=array_values($c['rules']??[]);$c['settings']=array_values($c['settings']??[]);
        if(count($c['trunks'])>10 || count($c['rules'])>30 || count($c['settings'])>100)throw new InvalidArgumentException('This template has too many entries.');
        foreach($c['trunks'] as $i=>&$g){
            $g=array_intersect_key($g,array_flip(['name','proxy','username','password','transport','register','enabled']));$g['name']=$this->label($g['name']??'',60);
            foreach(['proxy','username'] as $key){$g[$key]=trim($g[$key]??'');if(strlen($g[$key])>200 || preg_match('/[\x00-\x20<>"\'\\\\]/',$g[$key]))throw new InvalidArgumentException('Invalid SIP proxy or username.');}
            if($g['proxy']==='' || !preg_match('/^[a-zA-Z0-9.\-\[\]:]+$/D',$g['proxy']))throw new InvalidArgumentException('Enter a SIP proxy hostname or address.');
            if(!in_array($g['transport']??'udp',['udp','tcp','tls'],true))throw new InvalidArgumentException('Invalid SIP transport.');$g['transport']=$g['transport']??'udp';
            if(($g['password']??'')===''){$g['password']='';foreach($previous['trunks']??[] as $old)if($old['name']===$g['name']&&$old['proxy']===$g['proxy']&&$old['username']===$g['username'])$g['password']=$old['password'];}
            if(strlen($g['password'])>256 || preg_match('/[\x00-\x1f]/',$g['password']))throw new InvalidArgumentException('Invalid SIP password.');
            $g['register']=!empty($g['register']);$g['enabled']=!empty($g['enabled']);
        }unset($g);
        foreach($c['rules'] as &$r){$r=array_intersect_key($r,array_flip(['name','pattern','trunk','prefix']));$r['name']=$this->label($r['name']??'',60);$r['pattern']=trim($r['pattern']??'');$r['trunk']=(int)($r['trunk']??-1);$r['prefix']=trim($r['prefix']??'');
            if(strlen($r['pattern'])>180 || !str_starts_with($r['pattern'],'^') || !str_ends_with($r['pattern'],'$') || !preg_match('/\((?!\?)/',$r['pattern']) || preg_match('/[\x00-\x1f~<>]/',$r['pattern']) || @preg_match('~'.$r['pattern'].'~','')===false)throw new InvalidArgumentException('Call rules need a valid anchored pattern with a capture group for the dialled number.');
            if(!isset($c['trunks'][$r['trunk']]) || !preg_match('/^[+0-9]{0,10}$/D',$r['prefix']))throw new InvalidArgumentException('Choose a trunk and a numeric dial prefix.');
        }unset($r);
        foreach($c['settings'] as $i=>&$s){$s=array_intersect_key($s,array_flip(['category','subcategory','type','value']));if(!self::settingAllowed($s['category']??'',$s['subcategory']??'',$s['type']??''))throw new InvalidArgumentException('This domain setting is not permitted in a tenant template.');
            if($s['category']==='limit'&&$s['subcategory']==='extensions')throw new InvalidArgumentException('Set the extension limit in the PBX defaults section.');
            if(preg_match('/password|secret|token/i',$s['subcategory']) && ($s['value']??'')==='')foreach($previous['settings']??[] as $old)if($old['category']===$s['category']&&$old['subcategory']===$s['subcategory']&&$old['type']===$s['type'])$s['value']=$old['value'];
            $s['value']=(string)($s['value']??'');if(strlen($s['value'])>4096 || str_contains($s['value'],"\0"))throw new InvalidArgumentException('Setting value is too long.');
            if($s['type']==='numeric'&&!is_numeric($s['value']))throw new InvalidArgumentException('A numeric setting requires a number.');
            if($s['type']==='boolean'&&!in_array($s['value'],['true','false'],true))throw new InvalidArgumentException('A boolean setting requires true or false.');
        }unset($s);return $c;
    }
    public function saveTemplate(array $input): string {
        if(!$this->allowed('pbx_template_manage'))throw new RuntimeException('Template management permission is required.');
        $id=!empty($input['template_uuid'])?$this->id($input['template_uuid']):uuid();$previous=!empty($input['template_uuid'])?$this->template($id,true):null;
        $c=$this->config($input['config']??[],$previous['config']??[]);$tenant=$previous['tenant_uuid']??($this->platform()?null:($this->tenant()['tenant_uuid']??null));if(!$this->platform()&&!$tenant)throw new RuntimeException('A tenant account is required.');
        $name=$this->label($input['template_name']??'');$description=trim($input['description']??'');if(strlen($description)>2000)throw new InvalidArgumentException('Description is too long.');
        $params=['id'=>$id,'tenant'=>$tenant,'name'=>$name,'description'=>$description,'published'=>!empty($input['published'])?'true':'false','payload'=>$this->seal($c)];
        if($previous){unset($params['tenant']);$this->query('update v_pbx_templates set template_name=:name,description=:description,published=:published,payload_ciphertext=:payload,version=version+1,updated_at=now() where template_uuid=:id',$params);}
        else $this->query('insert into v_pbx_templates(template_uuid,tenant_uuid,template_name,description,published,payload_ciphertext) values(:id,:tenant,:name,:description,:published,:payload)',$params);
        return $id;
    }
    public function services(): array {
        if($this->platform())return $this->query('select s.*,d.domain_name,t.tenant_name,t.enabled from v_pbx_services s join v_domains d using(domain_uuid) join v_pbx_tenants t using(tenant_uuid) order by s.created_at desc')->fetchAll(PDO::FETCH_ASSOC);
        $t=$this->tenant();if(!$t)return [];
        $params=['tenant'=>$t['tenant_uuid']];$filter='';if($t['owner_user_uuid']!==$_SESSION['user_uuid']){$filter=' and s.domain_uuid=:domain';$params['domain']=$_SESSION['user']['domain_uuid'];}
        return $this->query('select s.*,d.domain_name,t.tenant_name,t.enabled from v_pbx_services s join v_domains d using(domain_uuid) join v_pbx_tenants t using(tenant_uuid) where s.tenant_uuid=:tenant'.$filter.' order by s.created_at desc',$params)->fetchAll(PDO::FETCH_ASSOC);
    }
    public function switchService(string $id): void {
        $s=$this->query('select s.*,d.domain_name from v_pbx_services s join v_domains d using(domain_uuid) where service_uuid=:id',['id'=>$this->id($id)])->fetch(PDO::FETCH_ASSOC);
        if(!$s || !$this->canDomain($s['domain_uuid']))throw new RuntimeException('PBX service access denied.');$this->assertTenant($s['tenant_uuid']);
        $_SESSION['previous_domain_uuid']=$_SESSION['domain_uuid'];$_SESSION['domain_uuid']=$s['domain_uuid'];$_SESSION['domain_name']=$s['domain_name'];$_SESSION['context']=$s['domain_name'];unset($_SESSION['extension_array'],$_SESSION['menu']);
        (new domains)->set();settings::clear_cache();
    }
    private function defaults(string $domain,string $name): void {
        // Copy only standard application dialplans from the platform, never another tenant's PBX.
        $source=$this->query("select domain_uuid,domain_name from v_domains where domain_name='call.openweb.co.za'")->fetch(PDO::FETCH_ASSOC);
        if(!$source)throw new RuntimeException('The platform PBX domain is unavailable.');
        $stock=[];
        foreach (glob(PROJECT_ROOT.'/app/dialplans/resources/switch/conf/dialplan/*.xml') as $file) {
            $xml=new DOMDocument();
            if (!$xml->load($file,LIBXML_NONET)) throw new RuntimeException('A standard PBX dialplan template is unavailable.');
            $extension=$xml->documentElement;
            if ($extension->tagName!=='extension' || !str_contains($extension->getAttribute('context'),'${domain_name}')) continue;
            $stock[$extension->getAttribute('app_uuid').'|'.$extension->getAttribute('name')]=str_replace('${domain_name}',$source['domain_name'],$extension->getAttribute('context'));
        }
        $plans=$this->query('select * from v_dialplans where domain_uuid=:id and app_uuid is not null',['id'=>$source['domain_uuid']])->fetchAll(PDO::FETCH_ASSOC);
        $plans=array_filter($plans,fn($row)=>isset($stock[$row['app_uuid'].'|'.$row['dialplan_name']]) && $stock[$row['app_uuid'].'|'.$row['dialplan_name']]===$row['dialplan_context']);
        if(!$plans)throw new RuntimeException('Standard PBX dialplans are unavailable.');
        foreach($plans as $row){$old=$row['dialplan_uuid'];$row['dialplan_uuid']=uuid();$row['domain_uuid']=$domain;$row['dialplan_context']=str_replace($source['domain_name'],$name,$row['dialplan_context']??$name);$row['dialplan_xml']=str_replace([$source['domain_name'],$source['domain_uuid']],[$name,$domain],$row['dialplan_xml']??'');foreach(['insert_date','update_date','insert_user','update_user'] as $key)unset($row[$key]);$this->insert('v_dialplans',$row);
            foreach($this->query('select * from v_dialplan_details where dialplan_uuid=:id',['id'=>$old])->fetchAll(PDO::FETCH_ASSOC) as $detail){$detail['dialplan_detail_uuid']=uuid();$detail['dialplan_uuid']=$row['dialplan_uuid'];$detail['domain_uuid']=$domain;$detail['dialplan_detail_data']=str_replace([$source['domain_name'],$source['domain_uuid']],[$name,$domain],$detail['dialplan_detail_data']??'');foreach(['insert_date','update_date','insert_user','update_user'] as $key)unset($detail[$key]);$this->insert('v_dialplan_details',$detail);}
        }
    }
    private function domainSetting(string $domain,string $category,string $subcategory,string $type,string $value): void {
        $this->insert('v_domain_settings',['domain_setting_uuid'=>uuid(),'domain_uuid'=>$domain,'domain_setting_category'=>$category,'domain_setting_subcategory'=>$subcategory,'domain_setting_name'=>$type,'domain_setting_value'=>$value,'domain_setting_enabled'=>'true','domain_setting_order'=>100]);
    }
    public function provision(array $input, bool $deferCommit = false): string {
        if ($deferCommit && !$this->db->inTransaction()) throw new LogicException('A caller transaction is required.');
        if (!$deferCommit && $this->db->inTransaction()) throw new LogicException('Service provisioning requires its own transaction.');
        if(!$this->allowed('pbx_service_create'))throw new RuntimeException('Service creation permission is required.');
        $tenant=$this->assertTenant($input['tenant_uuid']??'',true);$template=$this->template($input['template_uuid']??'');
        if($template['tenant_uuid']!==null&&$template['tenant_uuid']!==$tenant['tenant_uuid'])throw new RuntimeException('This template belongs to another tenant.');
        $name=$this->label($input['service_name']??'');$slug=$this->slug($input['slug']??'');$request=$this->id($input['request_uuid']??'');$c=$template['config'];
        foreach($c['trunks'] as $i=>&$g){foreach(['username','password'] as $key){$v=$input['credentials'][$i][$key]??'';if($v!=='')$g[$key]=$v;}if($g['register']&&($g['username']===''||$g['password']===''))$g['enabled']=false;}unset($g);$c=$this->config($c);
        $domain=uuid();$service=uuid();$realm=$slug.'.'.$tenant['slug'].'.call.openweb.co.za';
        if (!$deferCommit) $this->db->beginTransaction();try {
            $this->query('select tenant_uuid from v_pbx_tenants where tenant_uuid=:id for update',['id'=>$tenant['tenant_uuid']]);
            $existing=$this->query('select service_uuid,tenant_uuid from v_pbx_services where request_uuid=:id',['id'=>$request])->fetch(PDO::FETCH_ASSOC);if($existing){if($existing['tenant_uuid']!==$tenant['tenant_uuid'])throw new RuntimeException('Invalid service request.');if (!$deferCommit) $this->db->commit();return $existing['service_uuid'];}
            if(!$this->query('select enabled from v_pbx_tenants where tenant_uuid=:id',['id'=>$tenant['tenant_uuid']])->fetchColumn())throw new RuntimeException('This tenant is suspended.');
            if($this->query('select count(*) from v_pbx_services where tenant_uuid=:id',['id'=>$tenant['tenant_uuid']])->fetchColumn()>=$tenant['service_limit'])throw new RuntimeException('This tenant has reached its PBX service limit.');
            $this->insert('v_domains',['domain_uuid'=>$domain,'domain_name'=>$realm,'domain_description'=>$tenant['tenant_name'].' / '.$name,'domain_enabled'=>'true']);$this->defaults($domain,$realm);
            $this->domainSetting($domain,'domain','time_zone','text',$c['timezone']);$this->domainSetting($domain,'limit','extensions','numeric',(string)$c['extension_limit']);
            foreach($c['settings'] as $s)$this->domainSetting($domain,$s['category'],$s['subcategory'],$s['type'],$s['value']);
            for($i=0;$i<$c['extension_count'];$i++){$number=(string)($c['extension_start']+$i);$this->insert('v_extensions',['extension_uuid'=>uuid(),'domain_uuid'=>$domain,'extension'=>$number,'password'=>bin2hex(random_bytes(16)),'accountcode'=>$realm,'user_context'=>$realm,'dial_domain'=>$realm,'effective_caller_id_name'=>$c['caller_id_name']?:$tenant['tenant_name'],'effective_caller_id_number'=>$number,'outbound_caller_id_name'=>$c['caller_id_name'],'outbound_caller_id_number'=>$c['caller_id_number'],'enabled'=>'true','directory_visible'=>'true','directory_exten_visible'=>'true','call_timeout'=>'30','max_registrations'=>'1','limit_max'=>'5','limit_destination'=>'!USER_BUSY','extension_type'=>'default','description'=>'Created from '.$template['template_name']]);
                $this->insert('v_voicemails',['voicemail_uuid'=>uuid(),'domain_uuid'=>$domain,'voicemail_id'=>$number,'voicemail_password'=>(string)random_int(10000000,99999999),'voicemail_enabled'=>'true','voicemail_tutorial'=>'true','voicemail_file'=>'attach','voicemail_local_after_email'=>'true']);}
            $gateways=[];foreach($c['trunks'] as $g){$gid=uuid();$gateways[]=$gid;$this->insert('v_gateways',['gateway_uuid'=>$gid,'domain_uuid'=>$domain,'gateway'=>$g['name'].'-'.$slug,'proxy'=>$g['proxy'],'username'=>$g['username'],'password'=>$g['password'],'register_transport'=>$g['transport'],'register'=>$g['register']?'true':'false','enabled'=>$g['enabled']?'true':'false','context'=>'public','profile'=>'external','expire_seconds'=>'3600','retry_seconds'=>'30','description'=>'Created from '.$template['template_name']]);}
            foreach($c['rules'] as $i=>$r){$pid=uuid();$bridge='sofia/gateway/'.$gateways[$r['trunk']].'/'.$r['prefix'].'$1';$xml=new DOMDocument('1.0','UTF-8');$extension=$xml->appendChild($xml->createElement('extension'));$extension->setAttribute('name',$r['name']);$extension->setAttribute('continue','false');$condition=$extension->appendChild($xml->createElement('condition'));$condition->setAttribute('field','destination_number');$condition->setAttribute('expression',$r['pattern']);$action=$condition->appendChild($xml->createElement('action'));$action->setAttribute('application','bridge');$action->setAttribute('data',$bridge);
                $this->insert('v_dialplans',['dialplan_uuid'=>$pid,'domain_uuid'=>$domain,'dialplan_name'=>$r['name'],'dialplan_number'=>'','dialplan_context'=>$realm,'dialplan_order'=>(string)(1000+$i*10),'dialplan_continue'=>'false','dialplan_enabled'=>'true','dialplan_xml'=>$xml->saveXML($extension),'dialplan_description'=>'Template outbound rule']);
                foreach([['condition','destination_number',$r['pattern'],10],['action','bridge',$bridge,20]] as $detail)$this->insert('v_dialplan_details',['dialplan_detail_uuid'=>uuid(),'domain_uuid'=>$domain,'dialplan_uuid'=>$pid,'dialplan_detail_tag'=>$detail[0],'dialplan_detail_type'=>$detail[1],'dialplan_detail_data'=>$detail[2],'dialplan_detail_order'=>$detail[3],'dialplan_detail_group'=>0,'dialplan_detail_enabled'=>'true']);}
            $this->insert('v_pbx_services',['service_uuid'=>$service,'tenant_uuid'=>$tenant['tenant_uuid'],'domain_uuid'=>$domain,'template_uuid'=>$template['template_uuid'],'template_name'=>$template['template_name'],'template_version'=>$template['version'],'service_name'=>$name,'request_uuid'=>$request,'created_by'=>$_SESSION['user_uuid']]);if (!$deferCommit) $this->db->commit();
        }catch(Throwable $e){if(!$deferCommit && $this->db->inTransaction())$this->db->rollBack();throw $e;}
        if ($deferCommit) return $service;
        settings::clear_cache();$cache=new cache;$cache->delete(gethostname().':configuration:sofia.conf');
        try{event_socket::api('reloadxml');event_socket::api('sofia profile external rescan');}catch(Throwable $e){error_log('OpenWeb PBX: service provisioned; SIP rescan unavailable');}
        return $service;
    }
}
