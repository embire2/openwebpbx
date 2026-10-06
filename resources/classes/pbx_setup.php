<?php
/** Guided setup and reviewed configuration migration into isolated OpenWeb PBX services. */
class pbx_setup {
    private PDO $db;
    public function __construct(?PDO $db = null) {
        $this->db = $db ?? database::new()->db;
        $this->db->setAttribute(PDO::ATTR_ERRMODE, PDO::ERRMODE_EXCEPTION);
    }
    protected function allowed(string $permission): bool { return permission_exists($permission); }
    protected function tenantManager(): pbx_tenants { return new pbx_tenants($this->db); }
    private function query(string $sql, array $params = []): PDOStatement {
        $statement = $this->db->prepare($sql);
        foreach ($params as $key => $value) $statement->bindValue(':'.$key, $value, $value === null ? PDO::PARAM_NULL : (is_bool($value) ? PDO::PARAM_BOOL : (is_int($value) ? PDO::PARAM_INT : PDO::PARAM_STR)));
        $statement->execute(); return $statement;
    }
    public function canManage(): bool {
        if (!$this->allowed('pbx_service_create') || empty($_SESSION['user_uuid'])) return false;
        $tenants = $this->tenantManager();
        if ($tenants->platform()) return true;
        $tenant = $tenants->tenant();
        return $tenant && $tenant['enabled'] && $tenant['owner_user_uuid'] === $_SESSION['user_uuid'];
    }
    private function requireManage(): void { if (!$this->canManage()) throw new RuntimeException('PBX setup administrator access is required.'); }
    private function id(string $value): string { if (!is_uuid($value)) throw new InvalidArgumentException('Invalid setup identifier.'); return $value; }
    private function inputText(array $input, string $key, string $default = ''): string {
        $value=$input[$key]??$default;
        if (!is_string($value)) throw new InvalidArgumentException('Enter a text value for '.str_replace('_',' ',$key).'.');
        return $value;
    }
    private function label(string $value, int $maximum = 120): string {
        $value = trim($value);
        if ($value === '' || mb_strlen($value) > $maximum || preg_match('/[\x00-\x1f]/', $value)) throw new InvalidArgumentException('Enter a valid company or service name.');
        return $value;
    }
    private function key(): string {
        $key = @file_get_contents('/etc/fusionpbx/openweb-template.key');
        if ($key === false || strlen($key) !== SODIUM_CRYPTO_SECRETBOX_KEYBYTES) throw new RuntimeException('Setup encryption is not configured.');
        return $key;
    }
    private function seal(array $payload): string {
        $nonce = random_bytes(SODIUM_CRYPTO_SECRETBOX_NONCEBYTES);
        return base64_encode($nonce.sodium_crypto_secretbox(json_encode($payload, JSON_THROW_ON_ERROR), $nonce, $this->key()));
    }
    private function unseal(string $ciphertext): array {
        $raw = base64_decode($ciphertext, true);
        if (!$raw || strlen($raw) < 40) throw new RuntimeException('The setup draft is unavailable.');
        $plain = sodium_crypto_secretbox_open(substr($raw, 24), substr($raw, 0, 24), $this->key());
        if ($plain === false) throw new RuntimeException('The setup draft is unavailable.');
        return json_decode($plain, true, 512, JSON_THROW_ON_ERROR);
    }
    public function options(): array {
        $this->requireManage(); $manager = $this->tenantManager(); $mine = $manager->tenant();
        $tenants = array_values(array_filter($manager->tenants(), fn($tenant) => $tenant['enabled'] && !empty($tenant['owner_user_uuid'])));
        $timezone = $this->query("select domain_setting_value from v_domain_settings where domain_uuid=:domain and domain_setting_category='domain' and domain_setting_subcategory='time_zone' and domain_setting_enabled='true' limit 1", ['domain'=>$_SESSION['domain_uuid']])->fetchColumn();
        return ['tenants'=>array_map(fn($tenant)=>['tenant_uuid'=>$tenant['tenant_uuid'], 'tenant_name'=>$tenant['tenant_name']], $tenants),
            'timezones'=>DateTimeZone::listIdentifiers(), 'current_tenant_uuid'=>$mine['tenant_uuid'] ?? '',
            'default_timezone'=>in_array($timezone, DateTimeZone::listIdentifiers(), true) ? $timezone : 'Africa/Johannesburg',
            'default_company_name'=>$mine['tenant_name'] ?? 'My company'];
    }
    public function overview(): array {
        $this->requireManage(); $manager = $this->tenantManager(); $domain = $this->id($_SESSION['domain_uuid']);
        if (!$manager->canDomain($domain)) throw new RuntimeException('PBX service access denied.');
        $params = ['domain'=>$domain]; $counts = [];
        foreach (['users'=>'v_extensions', 'trunks'=>'v_gateways', 'numbers'=>'v_destinations', 'ring_groups'=>'v_ring_groups'] as $key=>$table) $counts[$key] = (int)$this->query('select count(*) from '.$table.' where domain_uuid=:domain', $params)->fetchColumn();
        $users = $this->query("select e.extension_uuid,e.extension,e.number_alias,e.effective_caller_id_name,e.description,e.enabled,coalesce(nullif(e.number_alias,''),e.extension) as number,e.effective_caller_id_name as name,v.voicemail_mail_to as email from v_extensions e left join v_voicemails v on v.domain_uuid=e.domain_uuid and v.voicemail_id=coalesce(nullif(e.number_alias,''),e.extension) where e.domain_uuid=:domain order by number limit 100", $params)->fetchAll(PDO::FETCH_ASSOC);
        $trunks = $this->query('select gateway_uuid,gateway,proxy,enabled,register from v_gateways where domain_uuid=:domain order by gateway limit 100', $params)->fetchAll(PDO::FETCH_ASSOC);
        $groups = $this->query('select ring_group_uuid,ring_group_name,ring_group_extension,ring_group_strategy,ring_group_enabled from v_ring_groups where domain_uuid=:domain order by ring_group_extension limit 100', $params)->fetchAll(PDO::FETCH_ASSOC);
        $numbers = $this->query('select destination_uuid,destination_number,destination_description,destination_enabled from v_destinations where domain_uuid=:domain order by destination_number limit 100', $params)->fetchAll(PDO::FETCH_ASSOC);
        $enabledTrunks = count(array_filter($trunks, fn($row)=>filter_var($row['enabled'], FILTER_VALIDATE_BOOLEAN)));
        $enabledNumbers = count(array_filter($numbers, fn($row)=>filter_var($row['destination_enabled'], FILTER_VALIDATE_BOOLEAN)));
        return ['domain_name'=>$_SESSION['domain_name'], 'company_name'=>$manager->tenant()['tenant_name'] ?? 'OpenWeb PBX', 'counts'=>$counts,
            'users'=>$users, 'trunks'=>$trunks, 'ring_groups'=>$groups, 'inbound_rules'=>$numbers,
            'checklist'=>[
                ['title'=>'Add your team', 'description'=>'Create users and voicemail, then connect their phones.', 'complete'=>$counts['users']>0, 'url'=>'?view=users'],
                ['title'=>'Connect a voice provider', 'description'=>'Verify your SIP trunk and enable it after a connection test.', 'complete'=>$enabledTrunks>0, 'url'=>'?view=voice'],
                ['title'=>'Route your phone numbers', 'description'=>'Check inbound numbers, provider ingress, and outbound rules.', 'complete'=>$enabledNumbers>0, 'url'=>'?view=handling'],
                ['title'=>'Make a test call', 'description'=>'Test incoming, outgoing, and emergency calling with your provider.', 'complete'=>false, 'url'=>'?view=handling']]];
    }
    private function metadata(array $input): array {
        $options = $this->options(); $tenant = trim($this->inputText($input,'tenant_uuid',$options['current_tenant_uuid']));
        if ($tenant !== '') $this->tenantManager()->assertTenant($this->id($tenant), true);
        elseif (!$this->tenantManager()->platform()) throw new RuntimeException('Choose your tenant workspace.');
        $timezone = $this->inputText($input,'timezone',$options['default_timezone']);
        if (!in_array($timezone, DateTimeZone::listIdentifiers(), true)) throw new InvalidArgumentException('Choose a valid timezone.');
        return ['company_name'=>$this->label($this->inputText($input,'company_name',$options['default_company_name'])),
            'service_name'=>$this->label($this->inputText($input,'service_name','Main office')), 'tenant_uuid'=>$tenant, 'timezone'=>$timezone];
    }
    public function reviewSetup(array $input): array {
        $this->requireManage(); $metadata = $this->metadata($input); $users = [];
        if (!is_array($input['users'] ?? null) || count($input['users']) > 100) throw new InvalidArgumentException('Add between one and 100 users.');
        foreach ($input['users'] as $user) {
            if (!is_array($user)) throw new InvalidArgumentException('Invalid user entry.');
            if (trim($this->inputText($user,'number')) === '' && trim($this->inputText($user,'name')) === '' && trim($this->inputText($user,'email')) === '') continue;
            $users[] = ['number'=>trim($this->inputText($user,'number')), 'name'=>$this->label($this->inputText($user,'name'), 80),
                'email'=>strtolower(trim($this->inputText($user,'email'))), 'auth_id'=>trim($this->inputText($user,'number')),
                'password'=>bin2hex(random_bytes(16)), 'voicemail_pin'=>(string)random_int(10000000,99999999), 'enabled'=>true];
        }
        if (!$users) throw new InvalidArgumentException('Add at least one user.');
        $plan = ['source_format'=>'guided_setup', 'source_version'=>'', 'supported'=>true, 'users'=>$users, 'trunks'=>[], 'ring_groups'=>[], 'inbound_rules'=>[], 'outbound_rules'=>[], 'warnings'=>[], 'unsupported'=>[]];
        $trunk = $input['trunk'] ?? [];
        if (!is_array($trunk)) throw new InvalidArgumentException('Invalid voice provider.');
        if (trim($this->inputText($trunk,'host')) !== '') {
            $auth = $trunk['authentication'] ?? 'ip';
            if (!in_array($auth, ['ip','password'], true)) throw new InvalidArgumentException('Choose IP or password authentication.');
            if ($auth === 'password' && (trim($this->inputText($trunk,'username')) === '' || $this->inputText($trunk,'password') === '')) throw new InvalidArgumentException('Enter the SIP trunk username and password.');
            $plan['trunks'][] = ['source_id'=>'wizard-trunk', 'name'=>$this->label($this->inputText($trunk,'name','Voice provider'), 60), 'host'=>trim($this->inputText($trunk,'host')),
                'port'=>$trunk['port'] ?? 5060, 'transport'=>$trunk['transport'] ?? 'udp', 'username'=>$auth==='password'?$this->inputText($trunk,'username'):'',
                'password'=>$auth==='password'?$this->inputText($trunk,'password'):'', 'register'=>$auth==='password', 'enabled'=>false];
            $outbound=$input['outbound']??[];if(!is_array($outbound))throw new InvalidArgumentException('Invalid outbound calling rule.');
            $prefix = trim($this->inputText($outbound,'prefix'));
            if ($prefix !== '') $plan['outbound_rules'][] = ['name'=>'Outgoing calls', 'prefix'=>$prefix, 'lengths'=>[], 'strip'=>$outbound['strip'] ?? 0, 'prepend'=>trim($this->inputText($outbound,'prepend')), 'trunk_id'=>'wizard-trunk'];
            else $plan['warnings'][] = 'No outbound rule was supplied. Add your provider-approved calling rules before making external calls.';
            $plan['warnings'][] = 'The voice provider starts disabled. Verify its settings, caller ID, provider ingress, and emergency routes before enabling calling.';
        }
        $number = trim($this->inputText($input,'inbound_number'));
        if ($number !== '') {
            if (!$plan['trunks']) throw new InvalidArgumentException('Add a voice provider for the incoming phone number.');
            $plan['inbound_rules'][] = ['number'=>$number, 'name'=>'Main number', 'destination_type'=>'extension', 'destination'=>trim($this->inputText($input,'inbound_destination',$users[0]['number'])), 'trunk_id'=>'wizard-trunk'];
            $plan['warnings'][] = 'The incoming number remains disabled until the provider ingress is verified for this PBX service.';
        }
        $plan = array_replace($plan, (new pbx_setup_provisioner($this->db))->validate($plan));
        return $this->saveDraft('setup', ['metadata'=>$metadata, 'plan'=>$plan], $this->preview($metadata, $plan));
    }
    private function preview(array $metadata, array $plan): array {
        $public = threecx_backup::preview($plan);
        $counts = ['users'=>count($plan['users']), 'trunks'=>count($plan['trunks']), 'numbers'=>count($plan['inbound_rules']), 'ring_groups'=>count($plan['ring_groups']), 'outbound_rules'=>count($plan['outbound_rules'])];
        return array_merge($public, ['summary'=>array_merge($metadata, ['user_count'=>$counts['users'], 'trunk_count'=>$counts['trunks'], 'number_count'=>$counts['numbers'], 'ring_group_count'=>$counts['ring_groups'], 'source_version'=>$plan['source_version'], 'source_format'=>$plan['source_format']]), 'counts'=>$counts]);
    }
    public function analyzeUpload(array $upload): array {
        $this->requireManage();
        if (($upload['error'] ?? UPLOAD_ERR_NO_FILE) !== UPLOAD_ERR_OK || !isset($upload['tmp_name']) || !is_string($upload['tmp_name']) || !is_uploaded_file($upload['tmp_name'])) throw new InvalidArgumentException('Upload a ZIP backup or XML configuration file within the 50 MB limit.');
        if (($upload['size'] ?? 0) > 50*1024*1024) throw new InvalidArgumentException('The upload exceeds the 50 MB limit.');
        $plan = threecx_backup::analyze($upload['tmp_name']);
        if ($plan['supported']) $plan = array_replace($plan, (new pbx_setup_provisioner($this->db))->validate($plan));
        $options = $this->options();
        $metadata = $this->metadata(['company_name'=>$options['default_company_name'], 'service_name'=>'Imported PBX']);
        $plan['warnings'][] = 'Phones must be reprovisioned for OpenWeb PBX. 3CX applications are not migrated; configure suitable SIP clients. A successful configuration import does not verify calls.';
        return $this->saveDraft('import', ['metadata'=>$metadata, 'plan'=>$plan], $this->preview($metadata, $plan));
    }
    private function saveDraft(string $kind, array $payload, array $preview): array {
        // Expired drafts lose their encrypted credentials even if nobody reopens them.
        $this->query('delete from v_pbx_setup_drafts where expires_at<now() and completed_domain_uuid is null');
        $active = (int)$this->query('select count(*) from v_pbx_setup_drafts where user_uuid=:user and expires_at>now() and completed_domain_uuid is null', ['user'=>$_SESSION['user_uuid']])->fetchColumn();
        if ($active >= 10) throw new RuntimeException('You have ten pending setup drafts. Complete one or wait for its one-hour expiry.');
        $id = uuid(); $preview['draft_id'] = $id;
        $this->query('insert into v_pbx_setup_drafts(draft_uuid,user_uuid,kind,payload_ciphertext,preview,expires_at) values(:id,:user,:kind,:payload,cast(:preview as jsonb),now()+interval \'1 hour\')',
            ['id'=>$id,'user'=>$_SESSION['user_uuid'],'kind'=>$kind,'payload'=>$this->seal($payload),'preview'=>json_encode($preview, JSON_THROW_ON_ERROR)]);
        return $preview;
    }
    private function loadDraft(string $id, ?string $kind = null, bool $lock = false): array {
        $this->requireManage();
        $row = $this->query('select * from v_pbx_setup_drafts where draft_uuid=:id and user_uuid=:user and (expires_at>now() or completed_domain_uuid is not null)'.($lock?' for update':''), ['id'=>$this->id($id),'user'=>$_SESSION['user_uuid']])->fetch(PDO::FETCH_ASSOC);
        if (!$row || ($kind !== null && $row['kind'] !== $kind)) throw new RuntimeException('This setup draft has expired or belongs to another administrator.');
        $row['public'] = json_decode($row['preview'], true, 512, JSON_THROW_ON_ERROR);
        if ($row['payload_ciphertext'] !== null) $row['payload'] = $this->unseal($row['payload_ciphertext']);
        return $row;
    }
    public function draft(string $id): array { return $this->loadDraft($id, 'setup')['public']; }
    public function importPreview(string $id): array { return $this->loadDraft($id, 'import')['public']; }
    public function createSetup(string $id): string { return $this->create($id, 'setup', []); }
    public function createImport(string $id, array $input): string {
        if (empty($input['acknowledge_limitations'])) throw new InvalidArgumentException('Acknowledge the migration limitations before creating the PBX.');
        return $this->create($id, 'import', $input);
    }
    private function ownCompany(string $name): array {
        $manager = $this->tenantManager(); $mine = $manager->tenant();
        if ($mine) return $manager->assertTenant($mine['tenant_uuid'], true);
        if (!$manager->platform()) throw new RuntimeException('A tenant workspace is required.');
        $user = $this->query('select domain_uuid,user_email,username from v_users where user_uuid=:id and user_enabled=\'true\' for update', ['id'=>$_SESSION['user_uuid']])->fetch(PDO::FETCH_ASSOC);
        if (!$user) throw new RuntimeException('This administrator is unavailable.');
        $mine = $manager->tenant(); if ($mine) return $manager->assertTenant($mine['tenant_uuid'], true);
        $email = strtolower($user['user_email'] ?: $user['username']);
        if (!filter_var($email, FILTER_VALIDATE_EMAIL)) throw new InvalidArgumentException('Set your administrator email before creating your company.');
        $tenant = uuid(); $home=uuid(); $slug = 'company-'.substr(str_replace('-', '', $tenant), 0, 12);
        // Keep a company workspace separate from the shared platform administration domain.
        $this->query('insert into v_domains(domain_uuid,domain_name,domain_description,domain_enabled) values(:id,:name,:description,\'true\')',
            ['id'=>$home,'name'=>$slug.'.call.openweb.co.za','description'=>$name.' workspace']);
        $this->query('insert into v_pbx_tenants(tenant_uuid,tenant_name,slug,home_domain_uuid,owner_user_uuid,invite_email) values(:id,:name,:slug,:domain,:user,:email)',
            ['id'=>$tenant,'name'=>$name,'slug'=>$slug,'domain'=>$home,'user'=>$_SESSION['user_uuid'],'email'=>$email]);
        return $manager->assertTenant($tenant, true);
    }
    private function create(string $id, string $kind, array $input): string {
        $this->requireManage(); $manager = $this->tenantManager();
        $this->db->beginTransaction();
        try {
            $draft = $this->loadDraft($id, $kind, true);
            if ($draft['completed_domain_uuid']) {
                if (!$manager->canDomain($draft['completed_domain_uuid'])) throw new RuntimeException('PBX service access denied.');
                $this->db->commit(); return $draft['completed_domain_uuid'];
            }
            $payload = $draft['payload']; $plan = $payload['plan'];
            if (!$plan['supported']) throw new RuntimeException('This backup format is not supported. No PBX was created.');
            $metadata = $kind === 'import' ? $this->metadata($input) : $payload['metadata'];
            $tenant = $metadata['tenant_uuid'] !== '' ? $manager->assertTenant($metadata['tenant_uuid'], true) : $this->ownCompany($metadata['company_name']);
            $plan = array_replace($plan, (new pbx_setup_provisioner($this->db))->validate($plan));
            $template = uuid(); $templateName = $kind === 'import' ? '3CX configuration migration' : 'Guided PBX setup';
            $config = ['timezone'=>$metadata['timezone'],'extension_start'=>100,'extension_count'=>0,'extension_limit'=>max(100,count($plan['users'])),'caller_id_name'=>'','caller_id_number'=>'','trunks'=>[],'rules'=>[],'settings'=>[]];
            $this->query('insert into v_pbx_templates(template_uuid,tenant_uuid,template_name,published,payload_ciphertext) values(:id,:tenant,:name,true,:payload)',
                ['id'=>$template,'tenant'=>$tenant['tenant_uuid'],'name'=>$templateName,'payload'=>$this->seal($config)]);
            $slug = 'pbx-'.substr(str_replace('-', '', $id), 0, 12);
            $service = $manager->provision(['tenant_uuid'=>$tenant['tenant_uuid'],'template_uuid'=>$template,'service_name'=>$metadata['service_name'],'slug'=>$slug,'request_uuid'=>$id], true);
            $domain = $this->query('select domain_uuid,domain_name from v_domains where domain_uuid=(select domain_uuid from v_pbx_services where service_uuid=:id)', ['id'=>$service])->fetch(PDO::FETCH_ASSOC);
            $result = (new pbx_setup_provisioner($this->db))->apply($domain['domain_uuid'], $domain['domain_name'], $plan);
            $public = $this->preview($metadata, $plan); $public['draft_id'] = $id; $public['warnings'] = array_values(array_unique(array_merge($public['warnings'] ?? [], $result['warnings'] ?? [])));
            $this->query('delete from v_pbx_templates where template_uuid=:id', ['id'=>$template]);
            $this->query('update v_pbx_setup_drafts set completed_domain_uuid=:domain,payload_ciphertext=null,preview=cast(:preview as jsonb) where draft_uuid=:id', ['id'=>$id,'domain'=>$domain['domain_uuid'],'preview'=>json_encode($public,JSON_THROW_ON_ERROR)]);
            $this->db->commit();
        } catch (Throwable $exception) { if ($this->db->inTransaction()) $this->db->rollBack(); throw $exception; }
        settings::clear_cache(); (new cache)->delete(gethostname().':configuration:sofia.conf');
        try { event_socket::api('reloadxml'); } catch (Throwable $exception) { error_log('OpenWeb PBX: setup saved; telephony reload unavailable'); }
        return $domain['domain_uuid'];
    }
    public function switchDomain(string $domain): void {
        $this->requireManage();
        $service = $this->query('select service_uuid from v_pbx_services where domain_uuid=:domain', ['domain'=>$this->id($domain)])->fetchColumn();
        if (!$service) throw new RuntimeException('PBX service access denied.');
        $this->tenantManager()->switchService($service);
    }
}
