<?php
/**
 * Bounded 3CX configuration migration reader. This never runs or extracts archive files.
 *
 * Native layout evidence (read structurally, never copied with credentials):
 * - https://github.com/ninjanody/Elastix5Converter/tree/master/templates
 *   PhoneSystem/header/version 14.0.0.0, Tenants/Tenant/DN and Gateways.
 * - A public converter artifact uses the same envelope in 16.0.1.273.
 * - https://www.3cx.com/docs/configure-pbx-automatically/ documents SetupConfig.
 *
 * This is deliberately a configuration migration, not a 3CX binary/service restore.
 * Unmapped behavior is reported and requires a separate partial-import decision.
 */
final class threecx_backup {
    public const MAX_UPLOAD_BYTES = 134217728;
    public const MAX_XML_BYTES = 8388608;
    public const MAX_ARCHIVE_BYTES = 536870912;
    public const MAX_ENTRIES = 5000;
    private const MAX_NODES = 100000;
    private const MAX_RECORDS = 2000;
    private array $plan;

    private function __construct() {
        $this->plan = ['source_version'=>'unknown', 'source_format'=>'unknown', 'supported'=>false,
            'users'=>[], 'trunks'=>[], 'ring_groups'=>[], 'inbound_rules'=>[], 'outbound_rules'=>[],
            'warnings'=>[], 'unsupported'=>[]];
    }

    /** Private normalized result: callers must encrypt/store it outside the web root. */
    public static function analyze(string $path): array {
        $reader = new self();
        if (str_contains($path,'://') || !is_file($path) || is_link($path) || !is_readable($path)) {
            throw new InvalidArgumentException('The uploaded backup is unavailable.');
        }
        $size = filesize($path);
        if ($size === false || $size < 1 || $size > self::MAX_UPLOAD_BYTES) {
            throw new InvalidArgumentException('The backup must be between 1 byte and 128 MB.');
        }
        $handle = fopen($path, 'rb');
        if (!$handle) throw new InvalidArgumentException('The uploaded backup is unavailable.');
        $magic = fread($handle, 4); fclose($handle);
        if (str_starts_with($magic, 'PK')) {
            [$xml, $files] = $reader->archive($path);
            $reader->parse($xml, true);
            foreach ($files as $category=>$count) {
                $reader->unsupported($category, $count, 'Archive attachments are not restored by configuration migration.');
            }
        } else {
            if ($size > self::MAX_XML_BYTES) throw new InvalidArgumentException('Configuration XML is limited to 8 MB.');
            $xml = file_get_contents($path);
            if ($xml === false) throw new InvalidArgumentException('The uploaded backup is unavailable.');
            // Encrypted 3CX containers need not be ZIP files. Never attempt to decrypt or execute one.
            if (!preg_match('/^\s*(?:\xEF\xBB\xBF)?\s*</', $xml)) {
                $reader->unsupported('archive_format', 1, 'Encrypted or unknown backup container. Export an unencrypted ZIP backup.');
                return $reader->plan;
            }
            $reader->parse($xml, false);
        }
        foreach (['users','trunks','ring_groups','inbound_rules','outbound_rules'] as $kind) {
            if (count($reader->plan[$kind]) > self::MAX_RECORDS) throw new InvalidArgumentException('The backup contains too many configuration records.');
        }
        if ($reader->plan['supported'] && !array_sum(array_map(fn($k)=>count($reader->plan[$k]), ['users','trunks','ring_groups','inbound_rules','outbound_rules']))) {
            $reader->plan['supported'] = false;
            $reader->unsupported('empty_configuration', 1, 'No safely migratable users or call configuration were found.');
        }
        $reader->plan['warnings'] = array_values(array_unique($reader->plan['warnings']));
        return $reader->plan;
    }

    /** Explicit allowlist: secret-bearing fields never reach JSON, HTML or the browser. */
    public static function preview(array $plan): array {
        $out = [
            'source_version'=>(string)($plan['source_version'] ?? 'unknown'),
            'source_format'=>(string)($plan['source_format'] ?? 'unknown'),
            'supported'=>!empty($plan['supported']),
            'warnings'=>array_values($plan['warnings'] ?? []),
            'unsupported'=>array_values($plan['unsupported'] ?? []),
            'counts'=>[], 'users'=>[], 'trunks'=>[], 'ring_groups'=>[], 'inbound_rules'=>[], 'outbound_rules'=>[],
        ];
        $fields = [
            'users'=>['number','name','email','enabled'],
            'trunks'=>['source_id','name','host','port','transport','register','enabled'],
            'ring_groups'=>['number','name','strategy','members','timeout'],
            'inbound_rules'=>['number','name','destination_type','destination','trunk_id'],
            'outbound_rules'=>['name','prefix','lengths','strip','prepend','trunk_id'],
        ];
        foreach ($fields as $kind=>$allowed) {
            foreach ($plan[$kind] ?? [] as $row) {
                $safe = array_intersect_key($row, array_flip($allowed));
                if ($kind === 'users') {
                    $safe['has_password'] = !empty($row['password']);
                    $safe['has_auth_id'] = !empty($row['auth_id']);
                    $safe['has_voicemail_pin'] = !empty($row['voicemail_pin']);
                }
                if ($kind === 'trunks') {
                    $safe['has_username'] = !empty($row['username']);
                    $safe['has_password'] = !empty($row['password']);
                }
                $out[$kind][] = $safe;
            }
            $out['counts'][$kind] = count($out[$kind]);
        }
        return $out;
    }

    private function unsupported(string $category, int $count, string $reason): void {
        if ($count < 1) return;
        foreach ($this->plan['unsupported'] as &$item) {
            if ($item['category'] === $category && $item['reason'] === $reason) { $item['count'] += $count; return; }
        }
        unset($item);
        $this->plan['unsupported'][] = ['category'=>$category, 'count'=>$count, 'reason'=>$reason];
    }

    private function archive(string $path): array {
        if (!class_exists('ZipArchive')) throw new RuntimeException('ZIP backup support requires the PHP zip extension.');
        $zip = new ZipArchive();
        if ($zip->open($path, ZipArchive::RDONLY) !== true) throw new InvalidArgumentException('The backup is not a readable unencrypted ZIP archive.');
        try {
            if ($zip->numFiles < 1 || $zip->numFiles > self::MAX_ENTRIES) throw new InvalidArgumentException('The backup contains too many archive entries.');
            $candidates = []; $total = 0; $names = []; $files = [];
            for ($i=0; $i<$zip->numFiles; $i++) {
                $stat = $zip->statIndex($i);
                if (!$stat) throw new InvalidArgumentException('The ZIP directory is invalid.');
                $name = $stat['name'];
                if (strlen($name)>512 || preg_match('/[\x00-\x1f\x7f\\\\]/', $name) || str_starts_with($name, '/') || preg_match('/^[a-z]:/i', $name)
                    || preg_match('#(?:^|/)\.\.(?:/|$)#', $name) || preg_match('#(?:^|/)\.(?:/|$)#', $name)) {
                    throw new InvalidArgumentException('The archive contains an unsafe file path.');
                }
                $folded = strtolower($name);
                if (isset($names[$folded])) throw new InvalidArgumentException('The archive contains duplicate or ambiguous paths.');
                $names[$folded] = true;
                if (!$zip->getExternalAttributesIndex($i, $opsys, $attributes)) throw new InvalidArgumentException('The archive file metadata is invalid.');
                $type = ($attributes >> 16) & 0170000;
                if ($type && !in_array($type, [0100000,0040000], true)) throw new InvalidArgumentException('The archive contains links or special files.');
                if (!empty($stat['encryption_method'])) throw new InvalidArgumentException('Encrypted ZIP backups are not supported. Export a backup without encryption.');
                if (!in_array($stat['comp_method'], [ZipArchive::CM_STORE, ZipArchive::CM_DEFLATE], true)) throw new InvalidArgumentException('The archive uses an unsupported compression method.');
                $total += $stat['size'];
                if ($total > self::MAX_ARCHIVE_BYTES || $stat['size'] > self::MAX_ARCHIVE_BYTES || ($stat['size'] > 1048576 && $stat['size'] > max(1,$stat['comp_size'])*200)) {
                    throw new InvalidArgumentException('The archive exceeds safe size or compression limits.');
                }
                if (str_ends_with($name, '/')) continue;
                if (strpos($name, '/') === false && (preg_match('/^[0-9]+Db\.xml$/iD', $name) || in_array($folded, ['backupdb.xml','setupconfig.xml'], true))) {
                    if ($stat['size'] > self::MAX_XML_BYTES) throw new InvalidArgumentException('Configuration XML is limited to 8 MB.');
                    $candidates[] = $i;
                } else {
                    $category = preg_match('/(?:voicemail|voice.?mail|\/vm\/)/i', $name) ? 'voicemail_audio' :
                        (preg_match('/record/i', $name) ? 'recordings' :
                        (preg_match('/(?:prompt|ivr)/i', $name) ? 'audio_prompts' :
                        (preg_match('/(?:callhistory|call_history|\.csv$)/i', $name) ? 'call_history' : 'archive_files')));
                    $files[$category] = ($files[$category] ?? 0) + 1;
                }
            }
            if (count($candidates) !== 1) throw new InvalidArgumentException('The archive must contain exactly one root 3CX database XML or setupconfig.xml.');
            $stream = $zip->getStreamIndex($candidates[0]);
            if (!$stream) throw new InvalidArgumentException('The configuration file is encrypted or unreadable.');
            try { $xml = stream_get_contents($stream, self::MAX_XML_BYTES+1); }
            finally { fclose($stream); }
            if ($xml === false || strlen($xml) > self::MAX_XML_BYTES) throw new InvalidArgumentException('Configuration XML is limited to 8 MB.');
            if (strlen($xml) !== $zip->statIndex($candidates[0])['size']) throw new InvalidArgumentException('The configuration file is truncated.');
            return [$xml,$files];
        } finally { $zip->close(); }
    }

    private function document(string $xml): DOMDocument {
        if (strlen($xml) > self::MAX_XML_BYTES || str_contains($xml, "\0") || !mb_check_encoding($xml,'UTF-8')
            || preg_match('/<!\s*(?:DOCTYPE|ENTITY)/i', $xml) || preg_match('/<\?xml[^>]*encoding\s*=\s*[\'"](?!(?:utf-8|us-ascii)[\'"])/i', $xml)) {
            throw new InvalidArgumentException('Use UTF-8 XML without DTDs or entities.');
        }
        $old = libxml_use_internal_errors(true);
        try {
            $r = new XMLReader();
            if (!$r->XML($xml, null, LIBXML_NONET)) throw new InvalidArgumentException('The backup XML is invalid.');
            $nodes = 0;
            try {
                while ($r->read()) {
                    if (++$nodes > self::MAX_NODES || $r->depth > 32 || $r->nodeType === XMLReader::DOC_TYPE || $r->nodeType === XMLReader::ENTITY_REF) {
                        throw new InvalidArgumentException('The backup XML exceeds safe complexity limits.');
                    }
                    if ($r->nodeType === XMLReader::ELEMENT && $r->namespaceURI !== '') throw new InvalidArgumentException('Namespaced configuration elements are not supported.');
                }
            } finally { $r->close(); }
            if (libxml_get_errors()) throw new InvalidArgumentException('The backup XML is invalid.');
            $dom = new DOMDocument();
            if (!$dom->loadXML($xml, LIBXML_NONET|LIBXML_NOBLANKS) || !$dom->documentElement) throw new InvalidArgumentException('The backup XML is invalid.');
            return $dom;
        } finally { libxml_clear_errors(); libxml_use_internal_errors($old); }
    }

    private function parse(string $xml, bool $zip): void {
        $root = $this->document($xml)->documentElement;
        if ($root->tagName === 'PhoneSystem') {
            $this->plan['source_format'] = '3cx-native-'.($zip?'zip':'xml');
            $version = $this->text($this->child($root,'header'), 'version');
            $validVersion=preg_match('/^\d{1,3}\.\d{1,3}\.\d{1,8}(?:\.\d{1,8})?$/D',$version);
            if ($validVersion) $this->plan['source_version'] = $version;
            if (!$validVersion || !preg_match('/^(?:14|16)\./',$version)) {
                $this->unsupported('source_version',1,'Only the verified legacy v14/v16 XML layout can currently be migrated. This version needs a sample and adapter validation.');
                return;
            }
            $tenants = $this->children($this->child($root,'Tenants'),'Tenant');
            if (count($tenants)!==1 || !$this->child($tenants[0]??null,'DN')) {
                $this->unsupported('database_layout',1,'The backup does not use the verified single-tenant PhoneSystem/Tenants/Tenant/DN layout.');
                return;
            }
            $this->plan['supported'] = true;
            $this->native($root,$tenants[0]);
            $this->plan['warnings'][] = 'Legacy 3CX configuration migration: this does not restore 3CX software, licenses, phone apps, certificates or service behavior.';
        } elseif ($root->tagName === 'SetupConfig' && $this->child($root,'tcxinit') && $this->child($root,'extensions')) {
            $this->plan['source_format'] = '3cx-setupconfig-'.($zip?'zip':'xml');
            $this->plan['source_version'] = 'documented setup schema';
            $this->plan['supported'] = true;
            $this->setup($root);
            $this->plan['warnings'][] = 'This is a 3CX setup configuration export, not a native system backup.';
        } else {
            $this->unsupported('database_layout',1,'The XML does not match a verified 3CX native backup or documented setup configuration.');
        }
        if ($this->plan['trunks']) $this->plan['warnings'][] = 'Imported SIP trunks and inbound routes remain disabled until carrier authentication and inbound source restrictions are checked.';
        $this->references();
    }

    private function child(?DOMElement $node,string $name): ?DOMElement {
        $items = $this->children($node,$name);
        if (count($items)>1) throw new InvalidArgumentException('The configuration has duplicate scalar fields or containers.');
        return $items[0] ?? null;
    }
    private function children(?DOMElement $node,?string $name=null): array {
        $out=[];
        if ($node) foreach ($node->childNodes as $child) if ($child instanceof DOMElement && ($name===null || $child->tagName===$name)) $out[]=$child;
        return $out;
    }
    private function text(?DOMElement $node,string $name,string $default=''): string {
        $field=$this->child($node,$name);
        if (!$field) return $default;
        if ($this->children($field) || $field->attributes->length) throw new InvalidArgumentException('Scalar configuration fields must contain plain text.');
        $value=trim($field->textContent);
        if (strlen($value)>1024 || preg_match('/[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]/',$value)) throw new InvalidArgumentException('A configuration field is too long or contains control characters.');
        return $value;
    }
    private function known(?DOMElement $node,array $allowed,string $category): void {
        $count=0;
        foreach ($this->children($node) as $field) if (!in_array($field->tagName,$allowed,true)) $count++;
        $this->unsupported($category,$count,'Additional source fields or behavior are not mapped and require manual configuration.');
    }
    private function number(string $value): string {
        if (!preg_match('/^[0-9]{2,9}$/D',$value)) throw new InvalidArgumentException('An extension number is invalid or outside the supported 2–9 digit range.');
        return $value;
    }
    private function boolean(string $value,bool $default): bool {
        if ($value==='') return $default;
        return match(strtolower($value)) {'true','1','yes'=>true,'false','0','no'=>false,default=>throw new InvalidArgumentException('A source boolean is invalid.')};
    }
    private function integer(string $value,int $default,int $min,int $max): int {
        if ($value==='') return $default;
        if (!ctype_digit($value) || (int)$value<$min || (int)$value>$max) throw new InvalidArgumentException('A source numeric setting is invalid.');
        return (int)$value;
    }
    private function credential(string $value,string $category,bool $extensionPassword=false): string {
        if ($value === '') return '';
        if (strlen($value)>256 || preg_match('/[\r\n]/',$value) || str_contains($value,'${')
            || ($extensionPassword && preg_match('/["<>&]/',$value)) || preg_match('/^(?:\$2[aby]\$|\$argon2|(?:encrypted|enc|sha256|sha512|hash):)/i',$value)) {
            $this->unsupported($category,1,'An encrypted, hashed or incompatible credential cannot be preserved; issue new endpoint credentials.');
            return '';
        }
        return $value;
    }

    private function user(DOMElement $node,bool $setup=false): void {
        $number=$this->number($this->text($node,'Number'));
        foreach ($this->plan['users'] as $existing) if ($existing['number']===$number) throw new InvalidArgumentException('The backup contains duplicate extension numbers.');
        $email=$this->text($node,'EmailAddress');
        if ($email!=='' && !filter_var($email,FILTER_VALIDATE_EMAIL)) throw new InvalidArgumentException('A source user email address is invalid.');
        $password=$this->credential($this->text($node,'AuthPassword'),'extension_credentials',true);
        $pin=$this->text($node,'VMPIN');
        if ($pin!=='' && !preg_match('/^[0-9]{4,12}$/D',$pin)) { $pin='';$this->unsupported('voicemail_pin',1,'The voicemail PIN requires regeneration.'); }
        $auth=$this->credential($this->text($node,'AuthID',$number),'extension_credentials');
        if ($auth!=='' && !preg_match('/^[a-zA-Z0-9_.-]{2,64}$/D',$auth)) { $auth='';$this->unsupported('extension_authentication',1,'The SIP authentication identifier requires endpoint reprovisioning.'); }
        $name=trim($this->text($node,'FirstName').' '.$this->text($node,'LastName'));
        if (mb_strlen($name)>80 || preg_match('/["<>&]/',$name)) {
            $name=$number;$this->unsupported('extension_display_name',1,'A display name cannot be represented by the native SIP directory; the extension number is used until its name is updated.');
        }
        $this->plan['users'][]=['number'=>$number,'name'=>$name?:$number,'email'=>$email,'auth_id'=>$auth?:$number,
            'password'=>$password,'voicemail_pin'=>$pin,'enabled'=>$this->boolean($this->text($node,'Enabled'),true)];
        $this->known($node,['Number','FirstName','LastName','EmailAddress','AuthID','AuthPassword','VMPIN','Enabled'],'extension_behavior');
        if (!$password) $this->plan['warnings'][]='Some user SIP passwords are unavailable. New unique SIP passwords will be generated and those phones must be reprovisioned.';
        if (!$pin) $this->plan['warnings'][]='Some voicemail PINs are unavailable. New unique PINs will be generated.';
        if ($auth && $auth!==$number) $this->plan['warnings'][]='Some SIP authentication identifiers differ from visible extension numbers. Phones must use the imported identifier and the new PBX realm.';
    }

    private function native(DOMElement $root,DOMElement $tenant): void {
        $this->known($root,['header','Tenants','Gateways'],'system_configuration');
        $this->known($this->child($root,'Tenants'),['Tenant'],'tenant_layout');
        $this->known($tenant,['DN','OutboundRules'],'tenant_configuration');
        $dn=$this->child($tenant,'DN');
        foreach ($this->children($dn) as $entity) {
            if ($entity->tagName==='Extension') $this->user($entity);
            elseif ($entity->tagName!=='ExternalLine') $this->unsupported('special_extensions',1,'A non-user directory object (ring group, queue, IVR, park, fax or conference) uses a layout that is not yet mapped.');
        }
        $providers=[];
        foreach ($this->children($this->child($root,'Gateways')) as $node) {
            if ($node->tagName!=='VoipProvider' && $node->tagName!=='Gateway') { $this->unsupported('provider_layout',1,'An unknown gateway provider cannot be mapped.');continue; }
            $name=$this->text($node,'Name');
            if ($name==='' || isset($providers[$name])) { $this->unsupported('provider_mapping',1,'Duplicate or unnamed provider references cannot be mapped.');continue; }
            $providers[$name]=$node;
        }
        $providerIds=[];
        foreach ($this->children($dn,'ExternalLine') as $line) {
            $name=$this->text($line,'Gateway');
            if (!isset($providers[$name])) { $this->unsupported('trunk_reference',1,'A trunk references a provider that is absent or unsupported.');continue; }
            try {
                $id=$this->number($this->text($line,'Number'));
                $this->trunk($providers[$name],$line,$id,$name);
                $providerIds[$name][]=$id;
                $this->nativeInbound($line,$id,$name);
            } catch (InvalidArgumentException $e) {
                $this->unsupported('trunk_configuration',1,'A legacy trunk contains invalid or unsupported core settings.');
            }
            $this->known($line,['Number','Gateway','AuthID','AuthPassword','DIDNumbers','ExternalNumber','RoutingRules'],'trunk_behavior');
        }
        foreach ($providers as $name=>$provider) if (!isset($providerIds[$name])) $this->unsupported('unused_providers',1,'A provider without a safely mapped external line is not migrated.');
        foreach ($this->orderedOutbound($this->child($tenant,'OutboundRules')) as $rule) $this->outbound($rule,$providerIds);
        $this->known($this->child($tenant,'OutboundRules'),['OutboundRule'],'outbound_rule_layout');
    }

    private function trunk(DOMElement $provider,DOMElement $credentials,string $id,string $name): void {
        if ($name==='' || mb_strlen($name)>80) throw new InvalidArgumentException('A trunk display name is invalid.');
        foreach ($this->plan['trunks'] as $existing) if ($existing['source_id']===$id) throw new InvalidArgumentException('Duplicate trunk identifiers are not supported.');
        $host=$this->text($provider,'Host');
        if ($host==='' || strlen($host)>253 || !preg_match('/^[a-zA-Z0-9][a-zA-Z0-9.:-]*$/D',$host)) throw new InvalidArgumentException('A trunk host is invalid.');
        $transport=strtolower($this->text($provider,'TransportProtocol','udp'));
        if ($transport==='') $transport='udp';
        if (!in_array($transport,['udp','tcp','tls'],true)) throw new InvalidArgumentException('A trunk transport is not supported.');
        $registration=$this->text($provider,'RequireRegistrationFor','InOutCalls');
        if (!in_array($registration,['InOutCalls','InCalls','OutCalls','NoCalls'],true)) throw new InvalidArgumentException('A source registration mode is not supported.');
        $username=$this->credential($this->text($credentials,'AuthID'),'trunk_credentials');
        $password=$this->credential($this->text($credentials,'AuthPassword'),'trunk_credentials');
        if (!preg_match('/^[A-Za-z0-9_.+@-]{0,128}$/D',$username)) throw new InvalidArgumentException('A trunk username is invalid.');
        $this->plan['trunks'][]=['source_id'=>$id,'name'=>$name,'host'=>$host,'port'=>$this->integer($this->text($provider,'Port'),5060,1,65535),
            'transport'=>$transport,'username'=>$username,'password'=>$password,'register'=>$registration!=='NoCalls','enabled'=>false];
        $this->known($provider,['Name','Host','Port','RequireRegistrationFor','TransportProtocol'],'provider_behavior');
        if ($registration!=='NoCalls' && (!$username || !$password)) $this->plan['warnings'][]='Some registering SIP trunks lack usable credentials and require provider details before activation.';
    }

    private function nativeInbound(DOMElement $line,string $trunkId,string $name): void {
        $rules=$this->children($this->child($line,'RoutingRules'),'ExternalLineRule');
        if (!$rules) return;
        $destinations=[]; $hours=[]; $valid=true;
        foreach ($rules as $rule) {
            $conditions=$this->child($rule,'RuleConditionGroup');
            $call=$this->child($conditions,'CallType');$condition=$this->child($conditions,'Condition');$hour=$this->child($conditions,'Hours');
            if (!$call || !$condition || !$hour || $call->getAttribute('Type')!=='AllCalls' || $condition->getAttribute('Type')!=='ForwardAll'
                || !in_array($hour->getAttribute('Type'),['OfficeHours','OutOfOfficeHours'],true) || count($this->children($conditions))!==3) $valid=false;
            foreach ([$call,$condition,$hour] as $field) if (!$field || $field->attributes->length!==1 || $this->children($field) || trim($field->textContent)!=='') $valid=false;
            $hours[]=$hour?->getAttribute('Type');
            $destination=$this->child($rule,'Destination');
            $type=$this->text($destination,'To');
            $internal=$this->child($destination,'Internal');
            $number=$internal?->getAttribute('DN')??'';
            if ($internal && ($internal->attributes->length!==1 || $this->children($internal) || trim($internal->textContent)!=='')) $valid=false;
            if (!in_array($type,['Extension','VoiceMail','None'],true) || ($type!=='None' && !preg_match('/^[0-9]{2,9}$/D',$number))) $valid=false;
            $destinations[]=['destination_type'=>match($type){'Extension'=>'extension','VoiceMail'=>'voicemail',default=>'hangup'},'destination'=>$type==='None'?'':$number];
            $this->known($rule,['RuleConditionGroup','Destination'],'inbound_rule_behavior');
            if ($destination) $this->known($destination,['To','Internal'],'inbound_destination_behavior');
        }
        sort($hours);
        if (!$valid || count($rules)!==2 || $hours!==['OfficeHours','OutOfOfficeHours'] || $destinations[0]!==$destinations[1]) {
            $this->unsupported('inbound_schedules',count($rules),'Only identical destinations for the complete office-hours/out-of-office-hours pair can be migrated without changing routing.');return;
        }
        $dids=$this->text($line,'DIDNumbers',$this->text($line,'ExternalNumber'));
        foreach ($this->didList($dids) as $did) $this->plan['inbound_rules'][]=['number'=>$did,'name'=>$name.' '.$did,'trunk_id'=>$trunkId]+$destinations[0];
    }

    private function didList(string $text): array {
        if ($text==='') { $this->unsupported('inbound_numbers',1,'An inbound route without an explicit DID cannot be migrated.');return []; }
        $numbers=array_values(array_unique(array_map('trim',explode(',',$text))));
        if (count($numbers)>1000) throw new InvalidArgumentException('The backup contains too many direct dial numbers.');
        foreach ($numbers as $number) if (!preg_match('/^\+?[0-9]{2,20}$/D',$number)) throw new InvalidArgumentException('An inbound DID pattern is not a supported exact phone number.');
        return $numbers;
    }

    private function outbound(DOMElement $rule,array $providerIds): void {
        $known=['Name','Prefix','NumberLengthRanges','OutboundRoutes','NumberOfRoutes','Priority','DNGroups','DNRanges'];
        foreach ($this->children($rule) as $field) if (!in_array($field->tagName,$known,true)) {
            $this->unsupported('outbound_behavior',1,'An outbound rule with unrecognized behavior is not migrated.');return;
        }
        $routes=array_values(array_filter($this->children($this->child($rule,'OutboundRoutes'),'OutboundRoute'),fn($r)=>$this->text($r,'Gateway')!==''));
        if (count($routes)!==1 || $this->children($this->child($rule,'DNGroups')) || $this->children($this->child($rule,'DNRanges'))
            || trim($this->child($rule,'DNGroups')?->textContent??'')!=='' || trim($this->child($rule,'DNRanges')?->textContent??'')!=='') {
            $this->unsupported('outbound_restrictions',1,'Backup routes or extension/department restrictions are not translated into an unrestricted outbound rule.');return;
        }
        $route=$routes[0];$name=$this->text($route,'Gateway');
        foreach ($this->children($route) as $field) if (!in_array($field->tagName,['Gateway','Prepend','StripDigits'],true)) {
            $this->unsupported('outbound_route_behavior',1,'An outbound route with unrecognized behavior is not migrated.');return;
        }
        if (count($providerIds[$name]??[])!==1) { $this->unsupported('outbound_trunk_reference',1,'An outbound provider reference is missing or maps to more than one external line.');return; }
        $prefix=$this->text($rule,'Prefix');$prepend=$this->text($route,'Prepend');
        if (!preg_match('/^\+?[0-9]{0,20}$/D',$prefix) || !preg_match('/^\+?[0-9]{0,20}$/D',$prepend)) { $this->unsupported('outbound_patterns',1,'Only one literal digit prefix and prepend can be migrated.');return; }
        $lengths=[];$raw=$this->text($rule,'NumberLengthRanges');
        if ($raw!=='') foreach (explode(',',$raw) as $length) {
            $length=trim($length);
            if (!ctype_digit($length) || (int)$length<2 || (int)$length>32) { $this->unsupported('outbound_lengths',1,'Number-length ranges or unsupported lengths require a manual rule.');return; }
            $lengths[]=(int)$length;
        }
        $lengths=array_values(array_unique($lengths));sort($lengths);
        if ($prefix==='' && !$lengths) { $this->unsupported('unrestricted_outbound',1,'A catch-all outbound rule requires a deliberate manual calling policy.');return; }
        $this->plan['outbound_rules'][]=['name'=>$this->text($rule,'Name')?:'Imported outbound rule','prefix'=>$prefix,'lengths'=>$lengths,
            'strip'=>$this->integer($this->text($route,'StripDigits'),0,0,31),'prepend'=>$prepend,'trunk_id'=>$providerIds[$name][0]];
        $this->known($rule,['Name','Prefix','NumberLengthRanges','OutboundRoutes','NumberOfRoutes','Priority','DNGroups','DNRanges'],'outbound_behavior');
        $this->known($route,['Gateway','Prepend','StripDigits'],'outbound_route_behavior');
    }

    private function setup(DOMElement $root): void {
        $this->known($root,['tcxinit','extensions','siptrunk','OutboundRules'],'setup_configuration');
        $options=[];
        foreach ($this->children($this->child($root,'tcxinit'),'option') as $option) $options[$this->text($option,'code')]=$this->text($option,'answer');
        if (($options['InstallationType']??'new')==='restore' || !empty($options['BackupFile'])) {
            $this->plan['supported']=false;
            $this->unsupported('backup_reference',1,'Setup XML references an external backup. Upload the actual unencrypted backup; remote paths are never fetched.');return;
        }
        if ($options) $this->unsupported('installation_settings',count($options),'Host, network, licensing, certificate, timezone and global mail setup values require explicit OpenWeb PBX configuration.');
        foreach ($this->children($this->child($root,'extensions'),'extension') as $user) $this->user($user,true);
        $this->known($this->child($root,'extensions'),['extension'],'setup_extension_layout');
        $ids=[];
        foreach ($this->children($root,'siptrunk') as $i=>$trunk) {
            $name=$this->text($trunk,'Name');$id='setup-'.($i+1);
            if ($name==='' || isset($ids[$name])) { $this->unsupported('provider_mapping',1,'Duplicate or unnamed setup providers cannot be mapped.');continue; }
            $this->trunk($trunk,$trunk,$id,$name);$ids[$name]=[$id];
            $rules=$this->children($this->child($trunk,'InboundRules'),'InboundRule');
            foreach ($rules as $rule) {
                $inType=$this->text($rule,'OfficeHoursDestinationType');$outType=$this->text($rule,'OutOfOfficeHoursDestinationType',$inType);
                $in=$this->text($rule,'OfficeHoursDestination');$out=$this->text($rule,'OutOfOfficeHoursDestination',$in);
                if ($inType!==$outType || $in!==$out || $this->children($this->child($rule,'SpecificHours')) || !in_array($inType,['Extension','VoiceMail','None'],true)) {
                    $this->unsupported('inbound_schedules',1,'Inbound schedules or destination types require manual routing.');continue;
                }
                foreach ($this->didList($this->text($rule,'DID')) as $did) $this->plan['inbound_rules'][]=['number'=>$did,'name'=>$this->text($rule,'Name')?:$did,'trunk_id'=>$id,
                    'destination_type'=>match($inType){'Extension'=>'extension','VoiceMail'=>'voicemail',default=>'hangup'},'destination'=>$inType==='None'?'':$this->number($in)];
                $this->known($rule,['Name','DID','OfficeHoursDestinationType','OfficeHoursDestination','OutOfOfficeHoursDestinationType','OutOfOfficeHoursDestination','SpecificHours'],'inbound_rule_behavior');
            }
        }
        foreach ($this->orderedOutbound($this->child($root,'OutboundRules')) as $rule) $this->outbound($rule,$ids);
    }

    private function orderedOutbound(?DOMElement $container): array {
        $rows=[];
        foreach ($this->children($container,'OutboundRule') as $index=>$rule) {
            $rows[]=['node'=>$rule,'priority'=>$this->integer($this->text($rule,'Priority'),$index,0,2147483647),'index'=>$index];
        }
        usort($rows,fn($a,$b)=>[$a['priority'],$a['index']]<=>[$b['priority'],$b['index']]);
        return array_column($rows,'node');
    }

    private function references(): void {
        $users=array_column($this->plan['users'],'number');$groups=array_column($this->plan['ring_groups'],'number');
        $seen=[];
        foreach ($this->plan['inbound_rules'] as $i=>$rule) {
            $valid=match($rule['destination_type']) {'extension','voicemail'=>in_array($rule['destination'],$users,true),'ring_group'=>in_array($rule['destination'],$groups,true),'hangup'=>true,default=>false};
            if (!$valid || isset($seen[$rule['number']])) {
                unset($this->plan['inbound_rules'][$i]);$this->unsupported('inbound_destination',1,'An inbound DID has an absent destination or duplicate number and is not migrated.');
            } else $seen[$rule['number']]=true;
        }
        $this->plan['inbound_rules']=array_values($this->plan['inbound_rules']);
    }
}
