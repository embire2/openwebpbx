<?php
/** Explicit administration API. No class names, SQL or switch commands come from callers. */
class pbx_api_file {
    public function __construct(public array $file,public string $mime='application/octet-stream') {}
}
/** Keep platform-owned restricted keys inside their selected tenant workspace. */
class pbx_api_tenants extends pbx_tenants {
    private PDO $apiDb;
    private array $apiKey;
    private pbx_access_keys $apiKeys;
    public function __construct(PDO $db,array $key){parent::__construct($db);$this->apiDb=$db;$this->apiKey=$key;$this->apiKeys=new pbx_access_keys($db);}
    public function platform(): bool {return $this->apiKey['instance'];}
    protected function allowed(string $name): bool {if(!$this->platform()&&in_array($name,['domain_all','pbx_tenant_manage'],true))return false;return $this->apiKeys->grant($this->apiKey['owner_user_uuid'],$name);}
    public function tenant(): ?array {if(!$this->apiKey['tenant_uuid'])return parent::tenant();$s=$this->apiDb->prepare('select * from v_pbx_tenants where tenant_uuid=? and enabled');$s->execute([$this->apiKey['tenant_uuid']]);return $s->fetch(PDO::FETCH_ASSOC)?:null;}
    public function template(string $id,bool $manage=false): array {
        if(!is_uuid($id))throw new InvalidArgumentException('Choose a template.');$s=$this->apiDb->prepare('select tenant_uuid,published from v_pbx_templates where template_uuid=?');$s->execute([$id]);$row=$s->fetch(PDO::FETCH_ASSOC);
        if(!$row||(!$this->platform()&&(($manage&&$row['tenant_uuid']!==$this->apiKey['tenant_uuid'])||($row['tenant_uuid']!==null&&$row['tenant_uuid']!==$this->apiKey['tenant_uuid']))))throw new pbx_api_access_denied('Template unavailable to this key.');return parent::template($id,$manage);
    }
    private function child(string $id): bool {
        $t=$this->tenant();if(!$t||$t['owner_user_uuid']!==$this->apiKey['owner_user_uuid']||!in_array('reseller:manage',$this->apiKey['scopes'],true)||!$this->apiKeys->grant($this->apiKey['owner_user_uuid'],'pbx_reseller_manage'))return false;
        $s=$this->apiDb->prepare('select 1 from v_pbx_tenants where tenant_uuid=? and reseller_user_uuid=? and enabled');$s->execute([$id,$this->apiKey['owner_user_uuid']]);return (bool)$s->fetchColumn();
    }
    public function tenants(): array {
        if($this->platform())return parent::tenants();$t=$this->tenant();if(!$t)return [];$out=[$t];
        if(in_array('reseller:manage',$this->apiKey['scopes'],true)&&$t['owner_user_uuid']===$this->apiKey['owner_user_uuid']&&$this->apiKeys->grant($this->apiKey['owner_user_uuid'],'pbx_reseller_manage')){$s=$this->apiDb->prepare('select * from v_pbx_tenants where reseller_user_uuid=? order by tenant_name');$s->execute([$this->apiKey['owner_user_uuid']]);$out=array_merge($out,$s->fetchAll(PDO::FETCH_ASSOC));}return $out;
    }
    public function services(): array {
        if($this->platform())return parent::services();$ids=array_column($this->tenants(),'tenant_uuid');if(!$ids)return [];$s=$this->apiDb->prepare('select s.*,d.domain_name,t.tenant_name,t.enabled from v_pbx_services s join v_domains d using(domain_uuid) join v_pbx_tenants t using(tenant_uuid) where s.tenant_uuid in ('.implode(',',array_fill(0,count($ids),'?')).') order by s.created_at desc');$s->execute($ids);return $s->fetchAll(PDO::FETCH_ASSOC);
    }
    public function assertTenant(string $id,bool $owner=false): array {
        if($this->platform())return parent::assertTenant($id,$owner);$t=$this->tenant();
        if($this->child($id)){$s=$this->apiDb->prepare('select * from v_pbx_tenants where tenant_uuid=? and enabled');$s->execute([$id]);return $s->fetch(PDO::FETCH_ASSOC);}
        if(!$t||$t['tenant_uuid']!==$id||(!$this->apiKeys->tenantOwned($this->apiKey['owner_user_uuid'],$id)&&!$this->apiKeys->instance($this->apiKey['owner_user_uuid'])))throw new pbx_api_access_denied('Tenant access denied.');return $t;
    }
}
class pbx_api_setup extends pbx_setup {
    private PDO $apiDb;private array $apiKey;
    public function __construct(PDO $db,array $key){parent::__construct($db);$this->apiDb=$db;$this->apiKey=$key;}
    protected function tenantManager(): pbx_tenants {return new pbx_api_tenants($this->apiDb,$this->apiKey);}
    protected function allowed(string $p): bool {return (new pbx_access_keys($this->apiDb))->grant($this->apiKey['owner_user_uuid'],$p);}
    public function canManage(): bool {return $this->allowed('pbx_service_create')&&($this->apiKey['instance']||($this->apiKey['tenant_uuid']&&((new pbx_access_keys($this->apiDb))->tenantOwned($this->apiKey['owner_user_uuid'],$this->apiKey['tenant_uuid'])||(new pbx_access_keys($this->apiDb))->instance($this->apiKey['owner_user_uuid']))));}
}
class pbx_reseller_api {
    private PDO $db;
    private pbx_access_keys $keys;
    private array $key=[];
    public const RESOURCES=['users'=>['users','user'],'trunks'=>['trunks','trunk'],'departments'=>['departments','department'],'office-hours'=>['departments','hours'],'queues'=>['queues','queue'],'ring-groups'=>['ring_groups','ring_group'],'receptionists'=>['receptionists','receptionist'],'outgoing-rules'=>['outbound_rules','outbound'],'dids'=>['inbound_rules','incoming'],'scripts'=>['scripts','script']];
    /** The operation catalogue is also the source of the public OpenAPI document. */
    public const OPERATIONS=[
        'overview'=>['GET','pbx:read','PBX configuration, with secrets and server paths removed'],
        'restore-report'=>['GET','pbx:read','Review imported configuration differences'],
        'next-extension'=>['GET','pbx:read','Find the next available extension'],
        'trunk-options'=>['POST','pbx:read','Read provider transport, capacity and advanced options with revision'],
        'trunk-options-save'=>['POST','pbx:write','Save reviewed provider connection and media options'],
        'trunk-readiness'=>['GET','pbx:read','Inspect provider registration and setup'],
        'live'=>['GET','pbx:read','Live calls, phones and queues'],
        'network'=>['GET','pbx:read','Calling network readiness'],
        'history'=>['GET','pbx:read','Paginated call history'],
        'queue-report'=>['GET','pbx:read','Queue and callback statistics'],
        'media'=>['GET','pbx:read','Paginated recordings, voicemail and prompts'],
        'credentials'=>['POST','credentials:read','Read an extension phone configuration'],
        'call-control'=>['POST','calls:control','Transfer, pickup, park, retrieve or end a call'],
        'agent'=>['POST','calls:control','Change queue agent availability'],
        'queue-rules'=>['POST','pbx:write','Save queue announcements, overflow and callbacks'],
        'first-calls'=>['POST','pbx:read','Review first-call checks for a provider'],
        'call-plan'=>['POST','pbx:read','Preview outgoing routing without a call'],
        'test-call'=>['POST','calls:control','Start an explicitly requested controlled call test'],
        'record-call-check'=>['POST','pbx:write','Record the outcome of an actual call check'],
        'route-preview'=>['POST','pbx:read','Preview incoming routing and office hours'],
        'provider-check'=>['POST','pbx:read','Check the provider address and transport'],
        'add-provider'=>['POST','pbx:write','Add a SIP provider'],
        'connect-provider'=>['POST','pbx:write','Connect an existing provider'],
        'did-editor'=>['POST','pbx:read','Get the single DID editor, choices and current revision'],
        'trunk-incoming'=>['POST','pbx:read','Show effective incoming destinations on a trunk'],
        'add-trunk-number'=>['POST','pbx:write','Add a DID through the single routing editor'],
        'enable-call-features'=>['POST','pbx:write','Enable supported calling services'],
        'greetings'=>['GET','pbx:read','List reusable tenant greetings'],
        'greeting-create'=>['POST','pbx:write','Record a greeting by phone or Keoma text'],
        'greeting-rename'=>['POST','pbx:write','Rename a reusable greeting'],
        'greeting-action'=>['POST','pbx:write','Retry or archive a greeting'],
        'greeting-assign'=>['POST','pbx:write','Assign a greeting to selected destinations'],
        'greeting-unassign'=>['POST','pbx:write','Remove a greeting assignment'],
        'greeting-uses'=>['POST','pbx:read','Show destinations using a greeting'],
        'call-me-back'=>['GET','pbx:read','Callback services, accounts, scripts and speed dials'],
        'call-me-back-action'=>['POST','pbx:write','Manage callbacks, accounts, scripts and nine speed dials'],
        'jobs'=>['GET','pbx:read','Scheduled callbacks or hotel wakeup calls'],
        'job-action'=>['POST','calls:control','Cancel or retry an owned call request'],
        'hotel'=>['GET','pbx:read','Hotel rooms and recent service events'],
        'hotel-action'=>['POST','pbx:write','Check in, check out and manage room services'],
        'meetings'=>['GET','pbx:read','Scheduled audio and video conferences'],
        'meeting-create'=>['POST','pbx:write','Create a conference invitation'],
        'meeting-invite'=>['POST','pbx:write','Replace a conference invitation link'],
        'meeting-email'=>['POST','pbx:write','Email a valid conference invitation'],
        'meeting-status'=>['POST','pbx:read','Inspect an owned meeting participant session'],
        'meeting-control'=>['POST','calls:control','Admit, remove, mute or manage an owned conference'],
        'meeting-cancel'=>['POST','pbx:write','End an owned conference'],
        'meeting-host'=>['POST','credentials:read','Join as conference host'],
        'phone-health'=>['GET','pbx:read','Phone status and explainable recovery'],
        'phone-alerts'=>['POST','pbx:write','Configure phone health administrator alerts'],
        'phone-recover'=>['POST','calls:control','Request a confirmed controlled phone recovery'],
        'staff'=>['GET','pbx:read','Department staff roles'],
        'staff-grant'=>['POST','pbx:write','Grant an allowed department staff role'],
        'staff-renew'=>['POST','pbx:write','Renew a staff invitation'],
        'staff-revoke'=>['POST','pbx:write','Revoke a department staff role'],
        'hours-override'=>['POST','pbx:write','Temporarily open or close a department'],
        'sip-domains'=>['GET','pbx:read','SIP addresses and connection readiness'],
        'sip-domain-save'=>['POST','pbx:write','Save a PBX SIP address'],
        'sip-domain-disable'=>['POST','pbx:write','Disable a PBX SIP address'],
        'phone-migration'=>['GET','pbx:read','Restore-to-phone migration checks'],
        'migration-prepare'=>['POST','pbx:write','Prepare a preserved-identity phone migration'],
        'migration-record'=>['POST','pbx:write','Record an actual migration check'],
        'migration-limitation'=>['POST','pbx:write','Record an accepted migration limitation'],
        'phone-devices'=>['POST','pbx:read','List an extension registered app profiles'],
        'phone-qr'=>['POST','credentials:read','Get the stable extension QR setup payload'],
        'phone-qr-reset'=>['POST','credentials:read','Explicitly replace extension QR setup'],
        'phone-device-revoke'=>['POST','pbx:write','Revoke one extension app profile'],
        'phone-password'=>['POST','pbx:write','Set an extension app password'],
        'welcome-email'=>['POST','pbx:write','Queue the extension welcome email'],
        'resource-usage'=>['GET','pbx:read','Allocated and used extensions and calls'],
        'resource-orders'=>['GET','pbx:read','Resource orders for this PBX'],
        'resource-order'=>['POST','pbx:write','Request a quoted resource upgrade'],
        'audio-upload'=>['POST','pbx:write','Upload a WAV greeting for this PBX'],
        'migration-inspect'=>['POST','pbx:write','Review an uploaded desk-phone configuration'],
        'migration-export'=>['POST','credentials:read','Download a prepared preserved-identity phone configuration'],
    ];
    public function __construct(?PDO $db=null){$this->db=$db??database::new()->db;$this->keys=new pbx_access_keys($this->db);}
    private function tenants(): pbx_api_tenants {if($this->key['domain_uuid'])throw new pbx_api_access_denied('Use a tenant-wide key for tenant services and templates.');return new pbx_api_tenants($this->db,$this->key);}
    private function q(string $sql,array $p=[]): PDOStatement {$s=$this->db->prepare($sql);$s->execute($p);return $s;}
    private function need(string $scope): void {if(!in_array($scope,$this->key['scopes'],true))throw new pbx_api_access_denied('This key does not allow this action.');}
    private function permission(string $p): void {if(!$this->keys->grant($this->key['owner_user_uuid'],$p))throw new pbx_api_access_denied('The account no longer permits this action.');}
    private function instance(): void {if(!$this->key['instance'])throw new pbx_api_access_denied('An instance administrator key is required.');$this->need('system:manage');}
    private static function text(array $in,string $key,string $default='',int $max=200): string {$v=$in[$key]??$default;if(!is_string($v)||strlen($v)>$max||preg_match('/[\x00-\x1f\x7f]/',$v))throw new InvalidArgumentException('Check '.$key.'.');return $v;}
    private static function integer(array $in,string $key,int $default=0,int $max=10000): int {$v=$in[$key]??$default;if(is_bool($v)||filter_var($v,FILTER_VALIDATE_INT,['options'=>['min_range'=>0,'max_range'=>$max]])===false)throw new InvalidArgumentException('Check '.$key.'.');return (int)$v;}
    /** Secrets remain write-only unless a narrowly named credentials endpoint is selected. */
    public static function publicData(mixed $data): mixed {
        if(is_object($data))$data=(array)$data;if(!is_array($data))return $data;
        if(isset($data['subcategory'])&&is_string($data['subcategory'])&&preg_match('/password|secret|token|key/i',$data['subcategory'])){unset($data['value']);$data['has_secret']=true;}
        $out=[];foreach($data as $k=>$v){
            if(is_string($k)&&(preg_match('/password|passwd|secret|ciphertext|(?:^|_)token(?:_|$)|auth_id|a1_hash|invite_hash|identity_hash|south_african_id|id_number|pin_map|private_key|file_path|(?:^|_)(?:path|directory|root)(?:_|$)/i',$k)||in_array($k,['hold_music','moh','prompt','intro','announce_sound'],true)&&is_string($v)&&(str_starts_with($v,'/')||preg_match('~^[A-Za-z]:[\\/]~',$v))))continue;
            $out[$k]=self::publicData($v);
        }return $out;
    }
    public static function publicConfig(array $config): array {
        $out=array_intersect_key($config,array_flip(['realm','timezone','origin','company_name','phone_domain','number_country_code','caller_id_name','caller_id_number','users','trunks','queues','ring_groups','receptionists','departments','inbound_rules','outbound_rules','contacts','specials','scripts']));
        $fields=[
            'users'=>['number','name','first_name','last_name','email','enabled','extension_uuid','voicemail_uuid','voicemail_enabled','voicemail_email','voicemail_delete','greeting_id','status','office_routing','forwarding','departments','groups','caller_id','caller_id_name','caller_id_number','outbound_caller_id_number','outbound_caller_id_name','mobile','mobile_number','ring_timeout','timeout','recording','recording_mode','use_group_hours','office_hours','out_of_office','phone_model','profiles','profile','internal_after_hours','auto_status','record_calls','outbound_caller_id','department','greetings'],
            'trunks'=>['id','number','name','gateway_uuid','enabled','register','proxy','outbound_proxy','registrar','transport','port','allowed_ips','did_numbers','numbers','main_number','caller_id','caller_id_name','caller_id_number','options','provider','provider_name','auth_type','description','host','type','auth_mode','realm','expires','limit','dids','source_field','allowed_ips_source','provider_port_auto','codecs','sip_cid_type','has_credentials'],
            'scripts'=>['number','name','type','description','enabled','dialplan_uuid'],
        ];
        foreach($fields as $collection=>$allowed)foreach($out[$collection]??[] as $id=>$row){if(!is_array($row)){unset($out[$collection][$id]);continue;}$out[$collection][$id]=array_intersect_key($row,array_flip($allowed));}
        foreach($out['trunks']??[] as $id=>$row)if(isset($row['options']))$out['trunks'][$id]['options']=array_intersect_key(is_array($row['options'])?$row['options']:[],array_flip(['schema','allow_incoming','allow_outgoing','support_reinvite','scope_department','connection_pending','transport','register','registration','registration_expiry','proxy_port','registrar_port','outbound_proxy_port','supports_reinvite','supports_replaces','pbx_delivers_audio','stun','srtp','srtp_mode','media_encryption','codec','codecs','direction','incoming','outgoing','number_format','use_ip_auth','force_contact','rport']));
        return self::publicData($out);
    }
    private function upload(): array {$file=$_FILES['file']??$_FILES['backup']??null;if(!is_array($file)||!is_string($file['tmp_name']??null)||!is_uploaded_file($file['tmp_name']))throw new InvalidArgumentException('Upload the file in a multipart request.');return $file;}
    private function childTenant(string $tenant): bool {
        if(!$this->key['tenant_uuid']||$this->key['domain_uuid']||!in_array('reseller:manage',$this->key['scopes'],true)||!$this->keys->grant($this->key['owner_user_uuid'],'pbx_reseller_manage')||!is_uuid($tenant))return false;
        return (bool)$this->q('select 1 from v_pbx_tenants parent join v_pbx_tenants child on child.reseller_user_uuid=parent.owner_user_uuid where parent.tenant_uuid=? and parent.owner_user_uuid=? and parent.enabled and child.tenant_uuid=? and child.enabled',[$this->key['tenant_uuid'],$this->key['owner_user_uuid'],$tenant])->fetchColumn();
    }
    private function tenant(string $id): void {
        if(!is_uuid($id)||($this->key['tenant_uuid']&&$this->key['tenant_uuid']!==$id&&!$this->childTenant($id))||($this->key['domain_uuid']))throw new pbx_api_access_denied('This key does not allow this tenant operation.');
        if(!$this->q('select 1 from v_pbx_tenants where tenant_uuid=? and enabled',[$id])->fetchColumn()||(!$this->key['instance']&&!$this->keys->tenantOwned($this->key['owner_user_uuid'],$id)))throw new pbx_api_access_denied('Tenant unavailable.');
    }
    private function bind(string $domain): void {
        if(!is_uuid($domain)||($this->key['domain_uuid']&&$domain!==$this->key['domain_uuid']))throw new pbx_api_access_denied('This key does not allow this PBX.');
        $row=$this->q('select d.domain_uuid,d.domain_name,s.tenant_uuid,t.owner_user_uuid,t.enabled tenant_enabled from v_domains d left join v_pbx_services s using(domain_uuid) left join v_pbx_tenants t using(tenant_uuid) where d.domain_uuid=? and d.domain_enabled',[$domain])->fetch(PDO::FETCH_ASSOC);
        $scopedOperator=$this->key['domain_uuid']===$domain&&$this->keys->instance($this->key['owner_user_uuid']);
        if(!$row||($row['tenant_uuid']&&!$row['tenant_enabled'])||($this->key['tenant_uuid']&&$row['tenant_uuid']!==$this->key['tenant_uuid']&&!$this->childTenant((string)$row['tenant_uuid']))||(!$this->key['instance']&&!$scopedOperator&&!($row['tenant_uuid']&&$this->keys->tenantOwned($this->key['owner_user_uuid'],$row['tenant_uuid']))&&!$this->keys->domainAdmin($this->key['owner_user_uuid'],$domain)&&!($this->key['tenant_uuid']&&$this->keys->instance($this->key['owner_user_uuid']))))throw new pbx_api_access_denied('This PBX is unavailable to the key.');
        $this->context($domain,$row['domain_name']);
        if(!$this->keys->domainAdmin($this->key['owner_user_uuid'],$domain))$this->permission('pbx_service_create');
    }
    private function context(string $domain,string $name): void {
        global $domain_uuid,$user_uuid;
        $domain_uuid=$domain;$user_uuid=$this->key['owner_user_uuid'];
        $_SESSION=['authorized'=>true,'user_uuid'=>$user_uuid,'domain_uuid'=>$domain,'domain_name'=>$name,'context'=>$name,'user'=>['domain_uuid'=>$this->key['owner_domain_uuid']],'permissions'=>$this->keys->permissions($user_uuid,$domain)];
        permissions::reset();
    }
    private function establish(string $authorization,string $ip,bool $recordUsage=true): void {
        $this->key=$this->keys->authenticate($authorization,$ip,$recordUsage);
        $owner=$this->q('select domain_name from v_domains where domain_uuid=?',[$this->key['owner_domain_uuid']])->fetchColumn();
        $this->context($this->key['owner_domain_uuid'],(string)$owner);
    }
    /** Internal nginx admission only: no body, jobs, status writes or key usage update. */
    public function authorizeBackupUpload(string $route,string $authorization,string $ip): void {
        if($route!=='/instance/backups/import'&&!preg_match('~^/tenants/([a-f0-9-]+)/backups/import$~D',$route,$match))throw new pbx_api_access_denied('Unknown backup upload route.');
        $this->establish($authorization,$ip,false);$this->need('backups:write');$protection=new pbx_protection($this->db);
        if($route==='/instance/backups/import'){$this->instance();if(!$protection->instance())throw new pbx_api_access_denied('Instance backup permission is required.');return;}
        $this->tenant($match[1]);foreach($protection->tenants() as $tenant)if($tenant['tenant_uuid']===$match[1])return;
        throw new pbx_api_access_denied('Tenant backup permission is required.');
    }
    public function handle(string $method,string $route,array $in,string $authorization,string $ip): mixed {
        if(!in_array($method,['GET','POST','DELETE'],true))throw new InvalidArgumentException('Use GET, POST or DELETE.');
        if(!preg_match('~^/[a-zA-Z0-9/_-]{0,240}$~D',$route)||str_contains($route,'//'))throw new InvalidArgumentException('Use an exact API path.');
        $this->establish($authorization,$ip);
        $result=$this->dispatch($method,rtrim($route,'/')?:'/',$in);
        if($method!=='GET')$this->q('insert into v_pbx_reseller_audit(event_uuid,actor_uuid,tenant_uuid,domain_uuid,event_type,details) values(?,?,?,?,?,?::jsonb)',[uuid(),$this->key['owner_user_uuid'],$this->key['tenant_uuid'],$_SESSION['domain_uuid']??null,'api.request',json_encode(['key_uuid'=>$this->key['key_uuid'],'method'=>$method,'route'=>$route],JSON_THROW_ON_ERROR)]);
        return $result;
    }
    private function dispatch(string $method,string $route,array $in): mixed {
        if($method==='GET'&&$route==='/capabilities')return ['api_version'=>'2.1','software_version'=>pbx_updates::version(),'scopes'=>$this->key['scopes'],'boundary'=>['tenant_uuid'=>$this->key['tenant_uuid'],'domain_uuid'=>$this->key['domain_uuid'],'account_only'=>$this->key['account_only']],'account_endpoints'=>pbx_account_api::ROUTES,'documentation'=>'https://openwebpbx.com/api-docs'];
        if($this->key['account_only']&&!in_array($route,['/','/keys'],true)&&!str_starts_with($route,'/keys/')&&!str_starts_with($route,'/me')&&!str_starts_with($route,'/staff/'))throw new pbx_api_access_denied('Use your account key with personal or department endpoints.');
        if(str_starts_with($route,'/me')||str_starts_with($route,'/staff/'))return (new pbx_account_api($this->db,$this->key))->handle($method,$route,$in);
        if($this->key['domain_uuid']&&!str_starts_with($route,'/pbx/')&&!in_array($route,['/','/keys'],true)&&!str_starts_with($route,'/keys/'))throw new pbx_api_access_denied('Use this service key with its PBX endpoints.');
        if($method==='GET'&&$route==='/')return ['version'=>'2','software_version'=>pbx_updates::version(),'pbx_resources'=>self::RESOURCES,'operations'=>self::OPERATIONS,'account_endpoints'=>pbx_account_api::ROUTES,'documentation'=>'https://openwebpbx.com/api-docs','key'=>['id'=>$this->key['key_uuid'],'tenant_uuid'=>$this->key['tenant_uuid'],'domain_uuid'=>$this->key['domain_uuid'],'scopes'=>$this->key['scopes'],'expires_at'=>$this->key['expires_at']]];
        if(preg_match('~^/setup/(options|review|draft|create|import-review|import-preview|import-create)$~D',$route,$sm)) {
            $this->need($method==='GET'?'templates:read':'templates:write');$this->permission('pbx_service_create');$setup=new pbx_api_setup($this->db,$this->key);$id=self::text($in,'id');
            if($method==='GET'&&$sm[1]==='options')return self::publicData($setup->options());
            if($method==='POST'&&$sm[1]==='review')return self::publicData($setup->reviewSetup($in));
            if($method==='GET'&&$sm[1]==='draft')return self::publicData($setup->draft($id));
            if($method==='POST'&&$sm[1]==='create')return ['domain_uuid'=>$setup->createSetup($id)];
            if($method==='POST'&&$sm[1]==='import-review')return self::publicData($setup->analyzeUpload($this->upload()));
            if($method==='GET'&&$sm[1]==='import-preview')return self::publicData($setup->importPreview($id));
            if($method==='POST'&&$sm[1]==='import-create')return ['domain_uuid'=>$setup->createImport($id,$in)];
        }
        if(preg_match('~^/tenants/([a-f0-9-]+)/update-policy$~D',$route,$pm)){$this->tenant($pm[1]);$this->need($method==='GET'?'pbx:read':'pbx:write');$updates=new pbx_updates($this->db);if($method==='GET')return $updates->tenantPolicy($pm[1]);if($method==='POST'){$updates->saveTenant($pm[1],$in);return ['saved'=>true];}}
        if(preg_match('~^/tenants/([a-f0-9-]+)/backups/import$~D',$route,$bm)&&$method==='POST'){$this->tenant($bm[1]);$this->need('backups:write');return $this->importStream($bm[1],$in);}
        if($route==='/keys') {
            $this->need('keys:manage');
            if($method==='GET')return array_values(array_filter($this->keys->listing(),fn($r)=>$this->sameKeyBoundary($r)));
            if($method==='POST'){$scopes=$in['scopes']??[];if(!is_array($scopes)||!array_is_list($scopes)||array_filter($scopes,static fn($s)=>!is_string($s))||array_diff($scopes,$this->key['scopes']))throw new pbx_api_access_denied('A key cannot delegate permissions it does not have.');$in['tenant_uuid']=$this->key['tenant_uuid'];$in['domain_uuid']=$this->key['domain_uuid'];return $this->keys->delegate($in,$this->key['key_uuid']);}
        }
        if(preg_match('~^/keys/([a-f0-9-]+)(?:/(rotate))?$~D',$route,$km)) {
            $this->need('keys:manage');$old=null;foreach($this->keys->listing() as $r)if($r['key_uuid']===$km[1]&&$this->sameKeyBoundary($r))$old=$r;if(!$old)throw new OutOfBoundsException('API key unavailable.');
            if($method==='DELETE'&&empty($km[2])){$this->keys->revoke($km[1]);return ['revoked'=>true];}
            if($method==='POST'&&($km[2]??'')==='rotate')return $this->keys->rotate($km[1]);
        }
        if($route==='/services') {
            if($method==='GET'){$this->need('templates:read');$rows=$this->tenants()->services();return array_values(array_filter($rows,fn($r)=>(!$this->key['tenant_uuid']||$r['tenant_uuid']===$this->key['tenant_uuid']||$this->childTenant($r['tenant_uuid']))&&(!$this->key['domain_uuid']||$r['domain_uuid']===$this->key['domain_uuid'])));}
            if($method==='POST'){$this->need('templates:write');$this->permission('pbx_service_create');$id=self::text($in,'tenant_uuid');$this->tenant($id);return ['service_uuid'=>$this->tenants()->provision($in)];}
        }
        if($route==='/tenants'&&$method==='GET'){$this->need('templates:read');$rows=$this->tenants()->tenants();return self::publicData(array_values(array_filter($rows,fn($r)=>!$this->key['tenant_uuid']||$r['tenant_uuid']===$this->key['tenant_uuid']||$this->childTenant($r['tenant_uuid']))));}
        if($route==='/tenants'&&$method==='POST'){if($this->key['instance'])$this->instance();else{$this->need('reseller:manage');$this->permission('pbx_reseller_manage');if(!$this->key['tenant_uuid']||$this->key['domain_uuid']||!$this->q('select 1 from v_pbx_tenants where tenant_uuid=? and owner_user_uuid=? and enabled',[$this->key['tenant_uuid'],$this->key['owner_user_uuid']])->fetchColumn())throw new pbx_api_access_denied('Create customer tenants from your own active reseller workspace.');}return ['invitation_url'=>$this->tenants()->invite($in)];}
        if(preg_match('~^/tenants/([a-f0-9-]+)/(enabled|invitation)$~D',$route,$m)&&$method==='POST') {
            if(!is_uuid($m[1]))throw new InvalidArgumentException('Choose a tenant.');
            if($this->key['instance'])$this->instance();else{$this->need('reseller:manage');$this->permission('pbx_reseller_manage');if(!$this->key['tenant_uuid']||$this->key['domain_uuid']||!$this->q('select 1 from v_pbx_tenants parent join v_pbx_tenants child on child.reseller_user_uuid=parent.owner_user_uuid where parent.tenant_uuid=? and parent.owner_user_uuid=? and parent.enabled and child.tenant_uuid=?',[$this->key['tenant_uuid'],$this->key['owner_user_uuid'],$m[1]])->fetchColumn())throw new pbx_api_access_denied('This customer is unavailable to the key.');}
            if($m[2]==='invitation')return ['invitation_url'=>$this->tenants()->renewInvitation($m[1])];
            if(!is_bool($in['enabled']??null))throw new InvalidArgumentException('Choose enabled true or false.');$this->tenants()->suspend($m[1],$in['enabled']);return ['saved'=>true];
        }
        if($route==='/templates'&&$method==='GET'){$this->need('templates:read');return $this->tenants()->templates(!empty($in['manage']));}
        if($route==='/templates'&&$method==='POST'){$this->need('templates:write');$this->permission('pbx_template_manage');if($this->key['domain_uuid'])throw new pbx_api_access_denied('Use a tenant-wide key to manage templates.');return ['template_uuid'=>$this->tenants()->saveTemplate($in)];}
        if(preg_match('~^/templates/([a-f0-9-]+)$~D',$route,$m)&&$method==='GET'){$this->need('templates:read');return self::publicData($this->tenants()->template($m[1],!empty($in['manage'])));}
        if($route==='/plans/ceiling'&&$method==='GET'){$this->need('templates:read');return (new pbx_reseller($this->db))->ceiling();}
        if($route==='/plans') {
            $this->need($method==='GET'?'templates:read':'reseller:manage');if($method!=='GET'){$this->permission('pbx_reseller_manage');if(!$this->key['instance']&&$this->keys->instance($this->key['owner_user_uuid']))throw new pbx_api_access_denied('Use an instance-wide key to edit operator packages.');}$r=new pbx_reseller($this->db);
            if($method==='GET'){$plans=$r->plans();if(!$this->key['instance']&&$this->keys->instance($this->key['owner_user_uuid'])){$ids=$this->q('select resource_plan_uuid from v_pbx_tenants where tenant_uuid=? union select e.plan_uuid from v_pbx_service_entitlements e join v_pbx_services s using(domain_uuid) where s.tenant_uuid=? union select resource_plan_uuid from v_pbx_templates where tenant_uuid=?',[$this->key['tenant_uuid'],$this->key['tenant_uuid'],$this->key['tenant_uuid']])->fetchAll(PDO::FETCH_COLUMN);$plans=array_values(array_filter($plans,fn($p)=>in_array($p['plan_uuid'],$ids,true)));}return $plans;}if($method==='POST')return ['plan_uuid'=>$r->savePlan($in)];
        }
        if($route==='/resellers'&&$method==='POST'){$this->instance();$this->permission('pbx_reseller_manage');(new pbx_reseller($this->db))->setReseller($in);return ['saved'=>true];}
        if($route==='/plans/assign'&&$method==='POST'){$this->need('reseller:manage');$this->permission('pbx_reseller_manage');$domain=self::text($in,'domain_uuid');$this->bind($domain);(new pbx_reseller($this->db))->assign($in);return ['saved'=>true];}
        if($route==='/plans/assign-tenant'&&$method==='POST'){$this->need('reseller:manage');$this->permission('pbx_reseller_manage');$this->tenant(self::text($in,'tenant_uuid'));(new pbx_reseller($this->db))->assignTenant($in);return ['saved'=>true];}
        if(preg_match('~^/orders/([a-f0-9-]+)/(approve|cancel)$~D',$route,$m)&&$method==='POST'){$this->need('reseller:manage');$this->permission('pbx_reseller_manage');if(!$this->key['instance']){$d=$this->q('select domain_uuid from v_pbx_resource_orders where order_uuid=?',[is_uuid($m[1])?$m[1]:'00000000-0000-0000-0000-000000000000'])->fetchColumn();$this->bind((string)$d);}$r=new pbx_reseller($this->db);if($m[2]==='approve')$r->approve($m[1]);else $r->cancel($m[1]);return ['saved'=>true];}
        if(preg_match('~^/tenants/([a-f0-9-]+)/backups(?:/([a-f0-9-]+)(?:/(verify|restore|download))?)?$~D',$route,$m)) {
            $this->tenant($m[1]);$this->need($method==='GET'?'backups:read':'backups:write');$p=new pbx_protection($this->db);
            if($method==='GET'&&empty($m[2]))return $p->status($m[1]);
            if($method==='GET'&&($m[3]??'')==='download')return new pbx_api_file($p->download($m[1],$m[2]));
            if($method==='POST'&&empty($m[2]))return ['job_uuid'=>$p->request('tenant_create',$m[1],$in)];
            if($method==='POST'&&in_array($m[3]??'',['verify','restore'],true))return ['job_uuid'=>$p->request('tenant_'.$m[3],$m[1],array_merge($in,['backup_uuid'=>$m[2]]))];
        }
        if(str_starts_with($route,'/instance/'))return $this->instanceOperation($method,substr($route,10),$in);
        if(preg_match('~^/pbx/([a-f0-9-]+)/contacts(?:/([^/]+))?$~D',$route,$m)){
            $this->bind($m[1]);$this->need($method==='GET'?'pbx:read':'pbx:write');new pbx_admin($this->db);$contacts=new pbx_contacts($this->db);
            if($method==='GET')return $contacts->listing();$this->permission('extension_edit');return $contacts->save($m[2]??'',$in,$method==='DELETE');
        }
        if(preg_match('~^/pbx/([a-f0-9-]+)/([^/]+)(?:/([^/]+))?$~D',$route,$m)) {
            $this->bind($m[1]);$name=$m[2];$id=$m[3]??'';
            if(isset(self::RESOURCES[$name])) {
                $this->need($method==='GET'?'pbx:read':'pbx:write');$admin=new pbx_admin($this->db);[$collection,$type]=self::RESOURCES[$name];
                if($method==='GET'){$c=self::publicConfig($admin->config());if($id==='')return $c[$collection]??[];foreach($c[$collection]??[] as $k=>$r)if((string)($r['number']??$k)===$id||(string)($r['id']??'')===$id||(string)($r['rule_id']??'')===$id)return $r;throw new OutOfBoundsException('This item is unavailable.');}
                if($method==='DELETE'){if(($in['confirm_delete']??false)!==true)throw new InvalidArgumentException('Confirm deletion.');$admin->delete($type,$id);return ['deleted'=>true];}
                if($method==='POST')return ['id'=>$type==='incoming'?$admin->saveDid($id?:'new',$in):$admin->save($type,$id?:'new',$in),'message'=>$admin->saveNotice()];
            }
            if($name==='actions'&&isset(self::OPERATIONS[$id])){[$expected,$scope]=self::OPERATIONS[$id];if($method!==$expected)throw new InvalidArgumentException('Use '.$expected.' for this operation.');$this->need($scope);$value=$this->operation($id,$in);return $value instanceof pbx_api_file?$value:(in_array($id,['credentials','phone-qr','phone-qr-reset','meeting-host','meeting-create','meeting-invite','staff-grant','staff-renew'],true)?$value:self::publicData($value));}
            if($name==='audio'&&$method==='GET'){$this->need('pbx:read');return $this->audio((new pbx_admin($this->db))->mediaFile($id));}
            if($name==='greeting-audio'&&$method==='GET'){$this->need('pbx:read');return $this->audio((new pbx_greetings($this->db))->media($id));}
        }
        throw new OutOfBoundsException('This API endpoint is unavailable.');
    }
    private function importStream(string $tenant,array $in): array {
        if(!is_resource($in['_stream']??null)||!is_int($in['_size']??null)||!is_string($in['_password']??null))throw new InvalidArgumentException('Use an authenticated binary backup upload.');
        return ['job_uuid'=>(new pbx_protection($this->db))->importStream($tenant,$in['_stream'],$in['_size'],$in['_password'])];
    }
    private function sameKeyBoundary(array $row): bool {
        if($row['tenant_uuid']!==$this->key['tenant_uuid']||$row['domain_uuid']!==$this->key['domain_uuid']||array_diff(json_decode($row['scopes'],true,16,JSON_THROW_ON_ERROR),$this->key['scopes']))return false;
        if($row['key_uuid']===$this->key['key_uuid'])return true;
        // Equal permissions are not equal authority: a short-lived child must
        // never rotate a parent, sibling or independent UI key to escape expiry.
        return (bool)$this->q('with recursive chain as (select parent_key_uuid,1 depth from v_pbx_access_keys where key_uuid=? union all select p.parent_key_uuid,c.depth+1 from v_pbx_access_keys p join chain c on p.key_uuid=c.parent_key_uuid where c.depth<32) select 1 from chain where parent_key_uuid=? limit 1',[$row['key_uuid'],$this->key['key_uuid']])->fetchColumn();
    }
    private function audio(array $r): pbx_api_file {
        $path=$r['file_path']??'';if(!is_string($path)||is_link($path))throw new OutOfBoundsException('Audio unavailable.');$before=lstat($path);$h=fopen($path,'rb');if(!$h)throw new OutOfBoundsException('Audio unavailable.');$after=fstat($h);if(!$before||!$after||($after['mode']&0170000)!==0100000||$after['ino']!==$before['ino']||$after['dev']!==$before['dev']){fclose($h);throw new OutOfBoundsException('Audio unavailable.');}return new pbx_api_file(['handle'=>$h,'size'=>$after['size'],'filename'=>'openweb-audio.wav'],'audio/wav');
    }
    private function instanceOperation(string $method,string $name,array $in): mixed {
        $this->instance();
        if($name==='backups/import'&&$method==='POST'){$this->need('backups:write');return $this->importStream('',$in);}
        if($name==='protection'&&$method==='GET'){$this->need('backups:read');return (new pbx_protection($this->db))->status('');}
        if($name==='updates'&&$method==='GET')return (new pbx_updates($this->db))->status();
        if($name==='updates'&&$method==='POST')return ['command_uuid'=>(new pbx_updates($this->db))->request(self::text($in,'action'))];
        if($name==='update-policy'&&$method==='GET')return (new pbx_updates($this->db))->instancePolicy();
        if($name==='update-policy'&&$method==='POST'){(new pbx_updates($this->db))->saveInstance($in);return ['saved'=>true];}
        if($name==='android-minimum'&&$method==='POST'){(new pbx_updates($this->db))->saveClientMinimumVersion($in);return ['saved'=>true];}
        if($name==='mail'&&$method==='GET')return self::publicData((new outgoing_mail($this->db))->view());
        if($name==='mail'&&$method==='POST'){(new outgoing_mail($this->db))->save($in);return ['saved'=>true];}
        if($name==='mail-check'&&$method==='POST')return ['connected'=>(new outgoing_mail($this->db))->checkConnection()];
        if($name==='reseller-policy'){$r=new pbx_reseller($this->db);if($method==='GET')return $r->policy();if($method==='POST')return $r->policy($in);}
        if($name==='backups'&&$method==='GET'){$this->need('backups:read');return (new pbx_backups($this->db))->status();}
        if($name==='backups'&&$method==='POST'){$this->need('backups:write');return ['command_uuid'=>(new pbx_backups($this->db))->request('create','',true)];}
        if($name==='backup-settings'&&$method==='GET'){$this->need('backups:read');return (new pbx_backups($this->db))->settings();}
        if($name==='backup-settings'&&$method==='POST'){$this->need('backups:write');(new pbx_backups($this->db))->save($in);return ['saved'=>true];}
        if(preg_match('~^backups/([a-f0-9-]+)/(download|verify|restore)$~D',$name,$m)) {
            $this->need($method==='GET'?'backups:read':'backups:write');
            if($method==='GET'&&$m[2]==='download')return new pbx_api_file((new pbx_backups($this->db))->download($m[1]));
            if($method==='POST'&&in_array($m[2],['verify','restore'],true))return ['job_uuid'=>(new pbx_protection($this->db))->request('instance_'.$m[2],'',array_merge($in,['backup_uuid'=>$m[1]]))];
        }
        throw new OutOfBoundsException('This instance API endpoint is unavailable.');
    }
    private function operation(string $name,array $in): mixed {
        $id=self::text($in,'id');$number=self::text($in,'number','',32);$trunk=self::text($in,'trunk');$page=self::integer($in,'page');
        switch($name) {
            case 'overview':return self::publicConfig((new pbx_admin($this->db))->config());
            case 'restore-report':return (new pbx_admin($this->db))->report();
            case 'next-extension':return ['extension'=>(new pbx_admin($this->db))->nextExtension()];
            case 'trunk-options':$snapshot=(new pbx_trunk_options($this->db))->snapshot($trunk);$snapshot['config']=self::publicConfig($snapshot['config']);$snapshot['trunk']=self::publicConfig(['trunks'=>[$trunk=>$snapshot['trunk']]])['trunks'][$trunk];return $snapshot;
            case 'trunk-options-save':return ['message'=>(new pbx_trunk_options($this->db))->save($trunk,$in)];
            case 'trunk-readiness':return (new pbx_admin($this->db))->trunkReadiness();
            case 'live':return (new pbx_core($this->db))->live();
            case 'network':return (new pbx_core($this->db))->network();
            case 'history':return (new pbx_admin($this->db))->history($page);
            case 'queue-report':return (new pbx_core($this->db))->queueReport(self::integer($in,'days',1,90));
            case 'media':return (new pbx_admin($this->db))->media(self::text($in,'category','recordings'),$page);
            case 'credentials':return (new pbx_admin($this->db))->credentials($number);
            case 'call-control':return ['message'=>(new pbx_core($this->db))->control($in)];
            case 'agent':return ['message'=>(new pbx_core($this->db))->agent($in)];
            case 'queue-rules':(new pbx_core($this->db))->saveRules($in);break;
            case 'first-calls':return (new pbx_core($this->db))->firstCalls($trunk);
            case 'call-plan':return (new pbx_core($this->db))->callPlan($in);
            case 'test-call':return ['test_uuid'=>(new pbx_core($this->db))->startCallTest($in)];
            case 'record-call-check':(new pbx_core($this->db))->recordCheck($in);break;
            case 'route-preview':return (new pbx_core($this->db))->preview($in);
            case 'provider-check':return (new pbx_admin($this->db))->checkTrunkProvider($trunk);
            case 'add-provider':return (new pbx_admin($this->db))->addProvider($in);
            case 'connect-provider':return ['connected'=>(new pbx_admin($this->db))->connectProvider($trunk,$in)];
            case 'did-editor':$editor=(new pbx_did_routes($this->db))->editor($id?:'new',$trunk);$editor['config']=self::publicConfig($editor['config']);return $editor;
            case 'trunk-incoming':$snapshot=(new pbx_trunk_routes($this->db))->snapshot($trunk);$snapshot['config']=self::publicConfig($snapshot['config']);return $snapshot;
            case 'add-trunk-number':return ['id'=>(new pbx_admin($this->db))->addTrunkNumber($trunk,$in)];
            case 'enable-call-features':(new pbx_admin($this->db))->enableCallFeatures();break;
            case 'greetings':return ['greetings'=>(new pbx_greetings($this->db))->all(),'readiness'=>(new pbx_greetings($this->db))->readiness()];
            case 'greeting-create':return ['greeting_uuid'=>(new pbx_greetings($this->db))->create($in)];
            case 'greeting-rename':(new pbx_greetings($this->db))->rename($id,$in);break;
            case 'greeting-action':(new pbx_greetings($this->db))->action($id,self::text($in,'action'));break;
            case 'greeting-assign':$targets=$in['targets']??[];if(!is_array($targets))throw new InvalidArgumentException('Choose greeting destinations.');(new pbx_greetings($this->db))->assign($id,self::text($in,'kind'),$targets);break;
            case 'greeting-unassign':(new pbx_greetings($this->db))->unassign($id,self::text($in,'kind'),$number);break;
            case 'greeting-uses':return (new pbx_greetings($this->db))->uses($id);
            case 'call-me-back':return (new pbx_call_me_back($this->db))->dashboard();
            case 'call-me-back-action':return ['message'=>(new pbx_call_me_back($this->db))->action($in)];
            case 'jobs':return (new pbx_operations($this->db))->jobs(self::text($in,'kind','callback'));
            case 'job-action':(new pbx_operations($this->db))->jobAction($id,self::text($in,'action'));break;
            case 'hotel':$o=new pbx_operations($this->db);return ['rooms'=>$o->rooms(),'events'=>$o->events()];
            case 'hotel-action':(new pbx_operations($this->db))->hotelAction($in);break;
            case 'meetings':return (new pbx_meet($this->db))->meetings();
            case 'meeting-create':return (new pbx_meet($this->db))->create($in);
            case 'meeting-invite':return (new pbx_meet($this->db))->invite($id);
            case 'meeting-email':return ['queued'=>(new pbx_meet($this->db))->emailInvitations($id,self::text($in,'url'),self::text($in,'addresses','',5500))];
            case 'meeting-status':case 'meeting-control':$token=self::text($in,'member_token','',64);if(!preg_match('/^[a-f0-9]{64}$/D',$token)||!$this->q('select 1 from v_pbx_meeting_members p join v_pbx_meetings m using(meeting_uuid) where p.token_hash=? and m.domain_uuid=?',[hash('sha256',$token),$_SESSION['domain_uuid']])->fetchColumn())throw new pbx_api_access_denied('This meeting session is unavailable to the key.');return $name==='meeting-status'?(new pbx_meet($this->db))->status($token):(new pbx_meet($this->db))->action($token,$in);
            case 'meeting-cancel':(new pbx_meet($this->db))->cancel($id);break;
            case 'meeting-host':return (new pbx_meet($this->db))->host($id);
            case 'phone-health':return ['snapshot'=>(new pbx_phone_health($this->db))->snapshot(),'alerts'=>(new pbx_phone_health($this->db))->alertSettings()];
            case 'phone-alerts':if(!is_bool($in['enabled']??null))throw new InvalidArgumentException('Choose enabled true or false.');(new pbx_phone_health($this->db))->saveAlertSettings($in['enabled']);break;
            case 'phone-recover':return (new pbx_phone_health($this->db))->recover($id,self::text($in,'revision'),($in['confirmed']??false)===true);
            case 'staff':return (new pbx_staff_access($this->db))->staff();
            case 'staff-grant':return (new pbx_staff_accounts($this->db))->grant($in);
            case 'staff-renew':return (new pbx_staff_accounts($this->db))->renew($id,($in['email_invitation']??false)===true);
            case 'staff-revoke':(new pbx_staff_accounts($this->db))->revoke($id);break;
            case 'hours-override':(new pbx_staff_access($this->db))->overrideHours($in);break;
            case 'sip-domains':$s=new pbx_sip_domains($this->db);return ['addresses'=>$s->addresses(),'readiness'=>$s->readiness()];
            case 'sip-domain-save':return ['address'=>(new pbx_sip_domains($this->db))->save($in)];
            case 'sip-domain-disable':(new pbx_sip_domains($this->db))->disable($in);break;
            case 'phone-migration':return (new pbx_phone_migration($this->db))->overview();
            case 'migration-prepare':return ['migration_uuid'=>(new pbx_phone_migration($this->db))->prepare($in)];
            case 'migration-record':(new pbx_phone_migration($this->db))->record($in);break;
            case 'migration-limitation':(new pbx_phone_migration($this->db))->acceptLimitation($in);break;
            case 'phone-devices':return (new pbx_mobile($this->db))->devices($number);
            case 'phone-qr':return (new pbx_mobile($this->db))->createCode($number);
            case 'phone-qr-reset':$this->need('pbx:write');if(($in['confirmed']??false)!==true)throw new InvalidArgumentException('Confirm replacing this stable QR setup.');return (new pbx_mobile($this->db))->resetCode($number);
            case 'phone-device-revoke':(new pbx_mobile($this->db))->adminRevoke($number,$id);break;
            case 'phone-password':return (new pbx_mobile($this->db))->adminPassword($number,$in['password']??null);
            case 'welcome-email':return (new pbx_mobile_welcome($this->db))->queue($number);
            case 'resource-usage':return (new pbx_reseller($this->db))->usage($_SESSION['domain_uuid']);
            case 'resource-orders':return (new pbx_reseller($this->db))->orders($_SESSION['domain_uuid']);
            case 'audio-upload':return ['media_uuid'=>(new pbx_admin($this->db))->uploadAudio($this->upload())];
            case 'migration-inspect':return self::publicData((new pbx_phone_migration($this->db))->inspectUpload($this->upload()));
            case 'migration-export':$f=(new pbx_phone_migration($this->db))->export($id,($in['original']??false)===true);$h=fopen('php://temp','w+b');fwrite($h,$f['bytes']);rewind($h);return new pbx_api_file(['handle'=>$h,'size'=>strlen($f['bytes']),'filename'=>$f['filename']]);
            case 'resource-order':return (new pbx_reseller($this->db))->order(array_merge($in,['domain_uuid'=>$_SESSION['domain_uuid']]));
            default:throw new OutOfBoundsException('This operation is unavailable.');
        }return ['saved'=>true];
    }
}
