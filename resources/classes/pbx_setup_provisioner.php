<?php
/**
 * Converts a reviewed setup/import plan into native, domain-owned PBX records.
 * The caller checks authorization, creates the domain and standard dialplans,
 * and owns the transaction. This class never commits, reloads SIP, or sends mail.
 */
class pbx_setup_provisioner {
    private PDO $db;

    public function __construct(PDO $db) {
        $this->db = $db;
        $this->db->setAttribute(PDO::ATTR_ERRMODE, PDO::ERRMODE_EXCEPTION);
    }

    private function query(string $sql, array $params = []): PDOStatement {
        $statement = $this->db->prepare($sql);
        foreach ($params as $name => $value) {
            $type = $value === null ? PDO::PARAM_NULL : (is_bool($value) ? PDO::PARAM_BOOL : (is_int($value) ? PDO::PARAM_INT : PDO::PARAM_STR));
            $statement->bindValue(':'.$name, $value, $type);
        }
        $statement->execute();
        return $statement;
    }

    private function insert(string $table, array $row): void {
        // Only fixed identifiers from this class reach this helper.
        $columns = array_keys($row);
        $this->query('insert into '.$table.' ('.implode(',', $columns).') values ('.implode(',', array_map(fn($key) => ':'.$key, $columns)).')', $row);
    }

    private function uuid(): string {
        $bytes = random_bytes(16);
        $bytes[6] = chr((ord($bytes[6]) & 15) | 64);
        $bytes[8] = chr((ord($bytes[8]) & 63) | 128);
        $hex = bin2hex($bytes);
        return substr($hex,0,8).'-'.substr($hex,8,4).'-'.substr($hex,12,4).'-'.substr($hex,16,4).'-'.substr($hex,20);
    }

    private function text(mixed $value, string $field, int $maximum = 120, bool $required = true): string {
        if (!is_string($value) && !is_int($value) && $value !== null) throw new InvalidArgumentException('Invalid '.$field.'.');
        $value = trim((string)$value);
        if (($required && $value === '') || mb_strlen($value) > $maximum || preg_match('/[\x00-\x1f\x7f]/', $value)) throw new InvalidArgumentException('Invalid '.$field.'.');
        return $value;
    }

    private function number(mixed $value, string $field, bool $did = false): string {
        $value = $this->text($value, $field, 32);
        if (!preg_match($did ? '/^\+?[0-9]{2,32}$/D' : '/^[0-9]{2,10}$/D', $value)) throw new InvalidArgumentException('Invalid '.$field.'.');
        return $value;
    }

    private function integer(mixed $value, string $field, int $minimum, int $maximum): int {
        if (is_bool($value) || (!is_int($value) && !is_string($value))) throw new InvalidArgumentException('Invalid '.$field.'.');
        $result = filter_var($value, FILTER_VALIDATE_INT, ['options'=>['min_range'=>$minimum, 'max_range'=>$maximum]]);
        if ($result === false) throw new InvalidArgumentException('Invalid '.$field.'.');
        return $result;
    }

    private function flag(mixed $value, string $field): bool {
        if (is_bool($value)) return $value;
        if ($value === 'true' || $value === 1 || $value === '1') return true;
        if ($value === 'false' || $value === 0 || $value === '0') return false;
        throw new InvalidArgumentException('Invalid '.$field.'.');
    }

    private function secret(mixed $value, string $field, bool $extension = false): string {
        if (!is_string($value) || strlen($value) > 256 || preg_match('/[\x00-\x1f\x7f]/', $value) || str_contains($value, '${') || ($extension && preg_match('/["<>&]/', $value))) {
            throw new InvalidArgumentException('The '.$field.' cannot be represented safely. Set a new credential before importing.');
        }
        return $value;
    }

    private function fields(array $record, array $allowed, string $type): void {
        foreach ($record as $key => $value) {
            if (!in_array($key, $allowed, true) && $value !== null && $value !== '' && $value !== false && $value !== []) {
                throw new InvalidArgumentException('Unsupported '.$type.' setting: '.$this->text($key, 'setting name', 80).'. Review it before importing.');
            }
        }
    }

    private function records(array $plan, string $key, int $maximum): array {
        $records = $plan[$key] ?? [];
        if (!is_array($records) || !array_is_list($records) || count($records) > $maximum) throw new InvalidArgumentException('Invalid '.$key.' list or too many records.');
        foreach ($records as $record) if (!is_array($record)) throw new InvalidArgumentException('Invalid '.$key.' record.');
        return $records;
    }

    /** Validate without writing, for the review screen. Unknown behavior is rejected. */
    public function validate(array $plan): array {
        $output = ['users'=>[], 'trunks'=>[], 'ring_groups'=>[], 'inbound_rules'=>[], 'outbound_rules'=>[]];
        $this->fields($plan, ['users','trunks','ring_groups','inbound_rules','outbound_rules','source_version','source_format','supported','warnings','unsupported','v20','media_counts'], 'configuration');
        $numbers = []; $identities = []; $trunkIds = []; $groupNumbers = []; $didNumbers = [];
        foreach ($this->records($plan, 'users', 1000) as $user) {
            $this->fields($user, ['number','name','email','auth_id','password','voicemail_pin','enabled'], 'user');
            $number = $this->number($user['number'] ?? '', 'extension number');
            if (isset($numbers[$number])) throw new InvalidArgumentException('Duplicate extension number '.$number.'.');
            $authId = $this->text($user['auth_id'] ?? $number, 'SIP authentication ID', 64);
            if (!preg_match('/^[A-Za-z0-9_.!-]{1,64}$/D', $authId)) throw new InvalidArgumentException('A SIP authentication ID contains unsupported characters.');
            if (isset($identities[strtolower($authId)])) throw new InvalidArgumentException('Duplicate SIP authentication ID.');
            $name = $this->text($user['name'] ?? $number, 'user name', 80);
            // The native PHP directory writer also places caller names directly in XML.
            if (preg_match('/["<>&]/', $name)) throw new InvalidArgumentException('A user name contains characters unsupported by the native directory.');
            $email = $this->text($user['email'] ?? '', 'user email', 254, false);
            if ($email !== '' && !filter_var($email, FILTER_VALIDATE_EMAIL)) throw new InvalidArgumentException('Invalid user email.');
            $password = $this->secret($user['password'] ?? '', 'SIP password', true);
            $pin = $this->text($user['voicemail_pin'] ?? '', 'voicemail PIN', 12, false);
            if ($pin !== '' && !preg_match('/^[0-9]{4,12}$/D', $pin)) throw new InvalidArgumentException('A voicemail PIN must contain 4 to 12 digits.');
            $output['users'][] = ['number'=>$number, 'auth_id'=>$authId, 'name'=>$name, 'email'=>$email, 'password'=>$password, 'voicemail_pin'=>$pin, 'enabled'=>$this->flag($user['enabled'] ?? true, 'extension status')];
            $numbers[$number] = true; $identities[strtolower($authId)] = $number;
        }
        foreach ($identities as $authId => $number) {
            if (!isset($plan['v20']) && isset($numbers[$authId]) && (string)$authId !== $number) throw new InvalidArgumentException('A SIP authentication ID collides with another extension number.');
        }
        foreach ($this->records($plan, 'trunks', 50) as $trunk) {
            $advanced=['auth_mode','auth_username','realm','from_user','from_domain','register_proxy','outbound_proxy','expires','limit','codecs','contact_user','extension_in_contact','sip_cid_type','caller_id_in_from'];
            $this->fields($trunk, array_merge(['source_id','name','host','port','transport','username','password','register','enabled'],$advanced), 'trunk');
            $id = $this->text($trunk['source_id'] ?? '', 'source trunk ID', 80);
            if (!preg_match('/^[A-Za-z0-9_.-]{1,80}$/D', $id) || isset($trunkIds[$id])) throw new InvalidArgumentException('Invalid or duplicate source trunk ID.');
            $host = strtolower($this->text($trunk['host'] ?? '', 'SIP server', 253));
            $ip = trim($host, '[]');
            if (!filter_var($ip, FILTER_VALIDATE_IP) && !preg_match('/^(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)*[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$/D', $host)) throw new InvalidArgumentException('Invalid SIP server hostname or address.');
            if (str_contains($host, ':')) $host = '['.$ip.']';
            $transport = strtolower($this->text($trunk['transport'] ?? 'udp', 'SIP transport', 3));
            if (!in_array($transport, ['udp','tcp','tls'], true)) throw new InvalidArgumentException('Unsupported SIP transport.');
            $port = $this->integer($trunk['port'] ?? ($transport === 'tls' ? 5061 : 5060), 'SIP port', 1, 65535);
            $username = $this->text($trunk['username'] ?? '', 'SIP trunk username', 128, false);
            if (!preg_match('/^[A-Za-z0-9_.+@-]{0,128}$/D', $username)) throw new InvalidArgumentException('A SIP trunk username contains unsupported characters.');
            $normalized=['source_id'=>$id, 'name'=>$this->text($trunk['name'] ?? $id, 'trunk name', 80), 'host'=>$host, 'port'=>$port, 'transport'=>$transport, 'username'=>$username, 'password'=>$this->secret($trunk['password'] ?? '', 'SIP trunk password'), 'register'=>$this->flag($trunk['register'] ?? true, 'SIP registration'), 'enabled'=>$this->flag($trunk['enabled'] ?? false, 'trunk status')];
            foreach($advanced as $field)if(array_key_exists($field,$trunk))$normalized[$field]=$trunk[$field];
            $native=pbx_v20_restore::gatewaySettings($normalized);
            $normalized['username']=$native['username'];$normalized['password']=$native['password'];
            // Keep the editor's complete private model in normalized plans.
            foreach(['auth_mode'=>'auth_mode','auth_username'=>'auth_username','realm'=>'realm','from_user'=>'from_user','from_domain'=>'from_domain','register_proxy'=>'register_proxy','outbound_proxy'=>'outbound_proxy','expires'=>'expire_seconds','limit'=>'channels','contact_user'=>'extension','extension_in_contact'=>'extension_in_contact','sip_cid_type'=>'sip_cid_type','caller_id_in_from'=>'caller_id_in_from'] as $field=>$column)if(array_key_exists($field,$normalized))$normalized[$field]=$field==='auth_mode'?strtolower((string)$normalized[$field]):$native[$column];
            if(isset($normalized['codecs']))$normalized['codecs']=$native['codec_prefs']===''?[]:explode(',',$native['codec_prefs']);
            $output['trunks'][]=$normalized;
            $trunkIds[$id] = true;
        }
        foreach ($this->records($plan, 'ring_groups', 100) as $group) {
            $this->fields($group, ['number','name','strategy','members','timeout'], 'ring group');
            $number = $this->number($group['number'] ?? '', 'ring group number');
            if (isset($numbers[$number]) || isset($identities[strtolower($number)]) || isset($groupNumbers[$number])) throw new InvalidArgumentException('A ring group number is already used.');
            $strategy = strtolower($this->text($group['strategy'] ?? 'simultaneous', 'ring group strategy', 20));
            if (!in_array($strategy, ['simultaneous','sequence'], true)) throw new InvalidArgumentException('Unsupported ring group strategy.');
            $members = $group['members'] ?? [];
            if (!is_array($members) || !array_is_list($members) || count($members) < 1 || count($members) > 100) throw new InvalidArgumentException('A ring group needs between 1 and 100 local members.');
            $seen = [];
            foreach ($members as &$member) {
                $member = $this->number($member, 'ring group member');
                if (!isset($numbers[$member]) || isset($seen[$member])) throw new InvalidArgumentException('A ring group member is missing or duplicated.');
                $seen[$member] = true;
            }
            unset($member);
            $output['ring_groups'][] = ['number'=>$number, 'name'=>$this->text($group['name'] ?? $number, 'ring group name', 80), 'strategy'=>$strategy, 'members'=>$members, 'timeout'=>$this->integer($group['timeout'] ?? 30, 'ring group timeout', 5, 300)];
            $groupNumbers[$number] = true;
        }
        foreach ($this->records($plan, 'inbound_rules', 500) as $rule) {
            $this->fields($rule, ['number','name','destination_type','destination','trunk_id'], 'inbound rule');
            $number = $this->number($rule['number'] ?? '', 'DID number', true);
            if (isset($didNumbers[$number]) || isset($numbers[$number]) || isset($groupNumbers[$number])) throw new InvalidArgumentException('A DID number is duplicated or conflicts with an internal number.');
            $type = $this->text($rule['destination_type'] ?? '', 'inbound destination type', 20);
            if (!in_array($type, ['extension','ring_group','voicemail','hangup'], true)) throw new InvalidArgumentException('Unsupported inbound destination.');
            $destination = $type === 'hangup' ? '' : $this->number($rule['destination'] ?? '', 'inbound destination');
            if (($type === 'extension' || $type === 'voicemail') && !isset($numbers[$destination])) throw new InvalidArgumentException('The inbound destination extension is missing.');
            if ($type === 'ring_group' && !isset($groupNumbers[$destination])) throw new InvalidArgumentException('The inbound destination ring group is missing.');
            $trunk = $this->text($rule['trunk_id'] ?? '', 'inbound trunk ID', 80, false);
            if ($trunk !== '' && !isset($trunkIds[$trunk])) throw new InvalidArgumentException('The inbound source trunk is missing.');
            $output['inbound_rules'][] = ['number'=>$number, 'name'=>$this->text($rule['name'] ?? $number, 'inbound rule name', 80), 'destination_type'=>$type, 'destination'=>$destination, 'trunk_id'=>$trunk];
            $didNumbers[$number] = true;
        }
        foreach ($this->records($plan, 'outbound_rules', 200) as $rule) {
            $this->fields($rule, ['name','prefix','lengths','strip','prepend','trunk_id'], 'outbound rule');
            $prefix = $this->text($rule['prefix'] ?? '', 'outbound prefix', 20, false);
            $prepend = $this->text($rule['prepend'] ?? '', 'outbound prepend', 20, false);
            if (!preg_match('/^(?:\+?[0-9]*)$/D', $prefix) || !preg_match('/^(?:\+?[0-9]*)$/D', $prepend)) throw new InvalidArgumentException('Outbound prefixes must contain a leading plus and/or digits.');
            $lengths = $rule['lengths'] ?? [];
            if (!is_array($lengths) || !array_is_list($lengths) || count($lengths) > 31) throw new InvalidArgumentException('Invalid outbound number lengths.');
            foreach ($lengths as &$length) $length = $this->integer($length, 'outbound number length', 2, 32);
            unset($length);
            $lengths = array_values(array_unique($lengths)); sort($lengths);
            if ($prefix === '' && $lengths === []) throw new InvalidArgumentException('An outbound rule must specify a prefix or number lengths.');
            $strip = $this->integer($rule['strip'] ?? 0, 'outbound strip count', 0, 20);
            $minimum = $lengths ? min($lengths) : max(strlen($prefix), $strip + 1, 2);
            if ($strip >= $minimum || ($lengths && max(strlen($prefix), 2) > $minimum)) throw new InvalidArgumentException('An outbound strip count or prefix exceeds its number lengths.');
            $trunk = $this->text($rule['trunk_id'] ?? '', 'outbound trunk ID', 80);
            if (!isset($trunkIds[$trunk])) throw new InvalidArgumentException('The outbound rule references a missing trunk.');
            $output['outbound_rules'][] = ['name'=>$this->text($rule['name'] ?? '', 'outbound rule name', 80), 'prefix'=>$prefix, 'lengths'=>$lengths, 'strip'=>$strip, 'prepend'=>$prepend, 'trunk_id'=>$trunk];
        }
        return $output;
    }

    private function dialplan(string $domain, string $context, string $name, string $number, int $order, array $conditions, array $actions, bool $enabled, string $description, ?string $app = null): string {
        $id = $this->uuid();
        $document = new DOMDocument('1.0', 'UTF-8');
        $extension = $document->appendChild($document->createElement('extension'));
        $extension->setAttribute('name', $name); $extension->setAttribute('continue', 'false'); $extension->setAttribute('uuid', $id);
        $detailOrder = 10;
        $details = [];
        foreach ($conditions as $condition) {
            $node = $extension->appendChild($document->createElement('condition'));
            $node->setAttribute('field', $condition[0]); $node->setAttribute('expression', $condition[1]);
            $details[] = ['dialplan_detail_tag'=>'condition', 'dialplan_detail_type'=>$condition[0], 'dialplan_detail_data'=>$condition[1], 'dialplan_detail_order'=>$detailOrder];
            $detailOrder += 10;
        }
        foreach ($actions as $action) {
            $nodeAction = $node->appendChild($document->createElement('action'));
            $nodeAction->setAttribute('application', $action[0]); $nodeAction->setAttribute('data', $action[1]);
            if (!empty($action[2])) $nodeAction->setAttribute('inline', 'true');
            $details[] = ['dialplan_detail_tag'=>'action', 'dialplan_detail_type'=>$action[0], 'dialplan_detail_data'=>$action[1], 'dialplan_detail_inline'=>!empty($action[2]) ? 'true' : null, 'dialplan_detail_order'=>$detailOrder];
            $detailOrder += 10;
        }
        $this->insert('v_dialplans', ['dialplan_uuid'=>$id, 'domain_uuid'=>$domain, 'app_uuid'=>$app, 'dialplan_name'=>$name, 'dialplan_number'=>$number, 'dialplan_context'=>$context, 'dialplan_order'=>$order, 'dialplan_continue'=>false, 'dialplan_enabled'=>$enabled, 'dialplan_xml'=>$document->saveXML($extension), 'dialplan_description'=>$description]);
        foreach ($details as $detail) $this->insert('v_dialplan_details', $detail + ['dialplan_detail_uuid'=>$this->uuid(), 'domain_uuid'=>$domain, 'dialplan_uuid'=>$id, 'dialplan_detail_group'=>0, 'dialplan_detail_enabled'=>true]);
        return $id;
    }

    /** @return array{counts:array,warnings:array} No credentials are returned. */
    public function apply(string $domainUuid, string $domainName, array $plan): array {
        if (!$this->db->inTransaction()) throw new LogicException('Setup provisioning requires a caller-owned transaction.');
        if (!preg_match('/^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/Di', $domainUuid)) throw new InvalidArgumentException('Invalid PBX domain identifier.');
        $domainName = strtolower($this->text($domainName, 'PBX domain', 253));
        if (!preg_match('/^(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$/D', $domainName)) throw new InvalidArgumentException('Invalid PBX domain name.');
        // V20 keeps dialled numbers in its routing table, separately from SIP accounts.
        // An authentication ID can legitimately equal another person's dialled number.
        $v20 = isset($plan['v20']);
        $plan = $this->validate($plan);
        $domain = $this->query('select domain_name,domain_enabled from v_domains where domain_uuid=:id for update', ['id'=>$domainUuid])->fetch(PDO::FETCH_ASSOC);
        if (!$domain || $domain['domain_name'] !== $domainName || !$domain['domain_enabled']) throw new RuntimeException('The target PBX domain is unavailable or does not match.');
        foreach (['v_extensions','v_voicemails','v_gateways','v_ring_groups','v_destinations'] as $table) {
            if ($this->query('select 1 from '.$table.' where domain_uuid=:domain limit 1', ['domain'=>$domainUuid])->fetchColumn()) throw new RuntimeException('Setup and backup import require a new, empty PBX service. Existing records were left unchanged.');
        }
        $counts = ['users'=>0, 'voicemails'=>0, 'trunks'=>0, 'ring_groups'=>0, 'inbound_rules'=>0, 'outbound_rules'=>0];
        $warnings = []; $generatedPasswords = 0; $generatedPins = 0; $aliasedUsers = 0;
        // The installed XML handler treats '@' contexts as exact-context only:
        // shared global extension and outbound behaviors cannot run at ingress.
        $ingressContext = 'ingress@'.$domainName;
        foreach ($plan['users'] as $user) {
            $password = $user['password']; if ($password === '') { $password = bin2hex(random_bytes(20)); $generatedPasswords++; }
            $pin = $user['voicemail_pin']; if ($pin === '') { $pin = (string)random_int(10000000,99999999); $generatedPins++; }
            $alias = $v20 || $user['auth_id'] === $user['number'] ? null : $user['number'];
            if ($alias !== null) $aliasedUsers++;
            $parts = explode(' ', $user['name'], 2);
            $this->insert('v_extensions', ['extension_uuid'=>$this->uuid(), 'domain_uuid'=>$domainUuid, 'extension'=>$user['auth_id'], 'number_alias'=>$alias, 'password'=>$password, 'accountcode'=>$domainName, 'user_context'=>$domainName, 'dial_domain'=>$domainName, 'directory_first_name'=>$parts[0], 'directory_last_name'=>$parts[1] ?? '', 'effective_caller_id_name'=>$user['name'], 'effective_caller_id_number'=>$user['number'], 'directory_visible'=>true, 'directory_exten_visible'=>true, 'call_timeout'=>30, 'max_registrations'=>'1', 'limit_max'=>'5', 'limit_destination'=>'!USER_BUSY', 'extension_type'=>'default', 'enabled'=>$user['enabled'], 'description'=>'Created from reviewed PBX setup']);
            $this->insert('v_voicemails', ['voicemail_uuid'=>$this->uuid(), 'domain_uuid'=>$domainUuid, 'voicemail_id'=>$user['number'], 'voicemail_password'=>$pin, 'voicemail_mail_to'=>$user['email'], 'voicemail_enabled'=>$user['enabled'], 'voicemail_tutorial'=>true, 'voicemail_file'=>'attach', 'voicemail_local_after_email'=>true, 'voicemail_description'=>$user['name']]);
            $counts['users']++; $counts['voicemails']++;
        }
        $gateways = [];
        foreach ($plan['trunks'] as $trunk) {
            $id = $this->uuid(); $gateways[$trunk['source_id']] = $id;
            $this->insert('v_gateways', pbx_v20_restore::gatewaySettings($trunk)+['gateway_uuid'=>$id, 'domain_uuid'=>$domainUuid, 'gateway'=>$trunk['name'], 'enabled'=>false, 'context'=>$ingressContext, 'profile'=>'external', 'retry_seconds'=>30, 'description'=>'Source trunk '.$trunk['source_id'].'. Disabled pending carrier verification and secure ingress binding.']);
            $counts['trunks']++;
        }
        foreach ($plan['ring_groups'] as $group) {
            $id = $this->uuid();
            $dialplan = $this->dialplan($domainUuid, $domainName, $group['name'], $group['number'], 101, [['destination_number', '^'.preg_quote($group['number'], '~').'$']], [['ring_ready',''], ['set','ring_group_uuid='.$id], ['set','record_stereo=true'], ['lua','app.lua ring_groups']], true, 'Created from reviewed PBX setup', '1d61fb65-1eec-bc73-a6ee-a6203b4fe6f2');
            $this->insert('v_ring_groups', ['ring_group_uuid'=>$id, 'domain_uuid'=>$domainUuid, 'ring_group_name'=>$group['name'], 'ring_group_extension'=>$group['number'], 'ring_group_strategy'=>$group['strategy'], 'ring_group_call_timeout'=>$group['timeout'], 'ring_group_context'=>$domainName, 'ring_group_enabled'=>true, 'ring_group_call_screen_enabled'=>false, 'ring_group_call_forward_enabled'=>false, 'ring_group_follow_me_enabled'=>false, 'ring_group_forward_enabled'=>false, 'ring_group_timeout_app'=>'hangup', 'ring_group_timeout_data'=>'NO_ANSWER', 'ring_group_description'=>'Created from reviewed PBX setup; unanswered calls end after the configured timeout.', 'dialplan_uuid'=>$dialplan]);
            foreach ($group['members'] as $position => $member) $this->insert('v_ring_group_destinations', ['ring_group_destination_uuid'=>$this->uuid(), 'domain_uuid'=>$domainUuid, 'ring_group_uuid'=>$id, 'destination_number'=>$member, 'destination_delay'=>$group['strategy'] === 'sequence' ? $position : 0, 'destination_timeout'=>$group['timeout'], 'destination_prompt'=>0, 'destination_enabled'=>true]);
            $counts['ring_groups']++;
        }
        foreach ($plan['inbound_rules'] as $position => $rule) {
            $application = $rule['destination_type'] === 'hangup' ? 'hangup' : 'transfer';
            $data = $application === 'hangup' ? 'NORMAL_CLEARING' : ($rule['destination_type'] === 'voicemail' ? '*99' : '').$rule['destination'].' XML '.$domainName;
            $pattern = '^'.preg_quote($rule['number'], '~').'$';
            // These rules never enter the shared public context. A carrier must be
            // identified at the SIP ingress before its gateway/context is enabled.
            $description = 'Disabled pending verified carrier ingress; '.($rule['trunk_id'] !== '' ? 'source trunk '.$rule['trunk_id'].'.' : 'source trunk must be selected.');
            $dialplan = $this->dialplan($domainUuid, $ingressContext, $rule['name'], $rule['number'], 110+$position, [['destination_number',$pattern]], [['export','call_direction=inbound',true], ['set','domain_uuid='.$domainUuid,true], ['set','domain_name='.$domainName,true], [$application,$data]], false, $description, 'c03b422e-13a8-bd1b-e42b-b6b9b4d27ce4');
            $this->insert('v_destinations', ['destination_uuid'=>$this->uuid(), 'domain_uuid'=>$domainUuid, 'dialplan_uuid'=>$dialplan, 'destination_type'=>'inbound', 'destination_number'=>$rule['number'], 'destination_number_regex'=>$pattern, 'destination_condition_field'=>'destination_number', 'destination_context'=>$ingressContext, 'destination_app'=>$application, 'destination_data'=>$data, 'destination_actions'=>json_encode([['destination_app'=>$application,'destination_data'=>$data]], JSON_THROW_ON_ERROR), 'destination_enabled'=>false, 'destination_type_voice'=>1, 'destination_order'=>110+$position, 'destination_description'=>$description]);
            $counts['inbound_rules']++;
        }
        if ($counts['trunks'] || $counts['inbound_rules']) $this->dialplan($domainUuid, $ingressContext, 'Reject unconfigured incoming calls', '', 9999, [['destination_number','^.*$']], [['hangup','UNALLOCATED_NUMBER']], true, 'Private ingress deny rule. Only verified, explicitly enabled incoming number routes can transfer into the PBX.');
        foreach ($plan['outbound_rules'] as $position => $rule) {
            $length = $rule['lengths'] ? '(?='.implode('|', array_map(fn($length) => '.{'.$length.'}$', $rule['lengths'])).')' : '(?=.{'.max(strlen($rule['prefix']),$rule['strip']+1,2).',32}$)';
            $pattern = '^(?='.preg_quote($rule['prefix'],'~').')(?=\+?[0-9]+$)'.$length.'[+0-9]{'.$rule['strip'].'}([+0-9]+)$';
            $this->dialplan($domainUuid, $domainName, $rule['name'], '', 1000+$position*10, [['destination_number',$pattern]], [['set','hangup_after_bridge=true'], ['set','continue_on_fail=false'], ['bridge','sofia/gateway/'.$gateways[$rule['trunk_id']].'/'.$rule['prepend'].'$1']], true, 'Created from reviewed PBX setup. Source trunk '.$rule['trunk_id'].' is disabled pending verification.', '8c914ec3-9fc0-8ab5-4cda-6c9288bdc9a3');
            $counts['outbound_rules']++;
        }
        if ($generatedPasswords) $warnings[] = 'New SIP passwords were generated for '.$generatedPasswords.' user(s) whose backup did not contain a password. Reprovision those endpoints.';
        if ($generatedPins) $warnings[] = 'New voicemail PINs were generated for '.$generatedPins.' user(s) whose backup did not contain a PIN.';
        if ($aliasedUsers) $warnings[] = 'Distinct SIP authentication IDs were preserved for '.$aliasedUsers.' user(s). Reprovision endpoints with the new PBX realm and use the authentication ID as both SIP user and authentication user.';
        if ($counts['trunks']) $warnings[] = 'All '.$counts['trunks'].' SIP trunk(s) are disabled until provider credentials, caller ID, emergency routing and ingress authentication are verified.';
        if ($counts['inbound_rules']) $warnings[] = 'All '.$counts['inbound_rules'].' incoming number rule(s) are disabled in a private ingress context that rejects unconfigured calls. Bind a verified provider before enabling inbound calls; no shared public DID routes were created.';
        return ['counts'=>$counts, 'warnings'=>$warnings];
    }
}
