<?php
/** Preserve a restored phone's identities/settings; provisioning needs an identified model. */
final class pbx_phone_restore {
    private static function text(mixed $value, int $maximum = 4096): string {
        if (!is_string($value) || strlen($value) > $maximum || !mb_check_encoding($value, 'UTF-8') || preg_match('/[\x00-\x08\x0b\x0c\x0e-\x1f]/', $value)) throw new InvalidArgumentException('A source phone setting is invalid.');
        return $value;
    }
    private static function identity(mixed $value): string {
        $value = self::text($value, 128);
        if (!preg_match('/^[A-Za-z0-9_.!-]{1,128}$/D', $value)) throw new InvalidArgumentException('A source phone identity is unsupported.');
        return $value;
    }
    private static function integer(?string $value): ?int {
        if ($value === null || $value === '') return null;
        if (!ctype_digit($value) || (int)$value < 1 || (int)$value > 65535) throw new InvalidArgumentException('A source phone port or interval is invalid.');
        return (int)$value;
    }
    /** Return PRIVATE source_payload separately; callers must seal it before persistence. */
    public static function plan(array $phone, array $user, string $realm): array {
        if (!preg_match('/^(?=.{1,253}$)[a-z0-9](?:[a-z0-9.-]*[a-z0-9])?$/D', $realm) || str_contains($realm, '..')) throw new InvalidArgumentException('Choose a valid tenant SIP domain.');
        $number = self::identity($user['number'] ?? $phone['number'] ?? '');
        $auth = self::identity($user['auth_id'] ?? '');
        $password = self::text($user['password'] ?? '', 4096);
        if ($password === '' || preg_match('/[\r\n]/', $password) || str_contains($password, '${')) throw new InvalidArgumentException('The original SIP password is required and must not contain line breaks or interpolation.');
        $settings = self::text($phone['settings'] ?? '', 32768);
        $flat = []; $codecs = []; $keys = []; $options = []; $rootAttributes = [];
        if ($settings !== '') {
            if (preg_match('/<!\s*(?:DOCTYPE|ENTITY)/i', $settings)) throw new InvalidArgumentException('A phone configuration contains unsafe XML.');
            $previous = libxml_use_internal_errors(true);
            try {
                $document = new DOMDocument();
                if (!$document->loadXML($settings, LIBXML_NONET | LIBXML_NOBLANKS) || $document->documentElement?->tagName !== 'PhoneDevice') throw new InvalidArgumentException('A source phone configuration is invalid.');
                foreach ($document->documentElement->attributes as $attribute) $rootAttributes[$attribute->name] = $attribute->value;
                foreach ($document->getElementsByTagName('*') as $element) {
                    if ($element->tagName === 'option') {
                        $name = $element->getAttribute('name');
                        if ($name === '' || isset($options[$name])) throw new InvalidArgumentException('A source phone option is repeated or unnamed.');
                        $options[$name] = $element->getAttribute('value');
                    }
                    if ($element->tagName === 'Codec') {
                        $attributes = []; foreach ($element->attributes as $attribute) $attributes[$attribute->name] = $attribute->value;
                        $codecs[] = $attributes;
                    }
                    foreach ($element->attributes as $attribute) {
                        $key = strtolower($attribute->name);
                        if (in_array($key, ['sipuser','sipusername','authid','authuser','password','transport','siptransport','sipport','serverport','outboundproxy','proxy','registerexpires','model','phonemodel'], true)) {
                            if (isset($flat[$key]) && $flat[$key] !== $attribute->value) throw new InvalidArgumentException('A source phone has conflicting account settings.');
                            $flat[$key] = $attribute->value;
                        }
                    }
                }
                $blfs = $document->getElementsByTagName('BLFS')->item(0);
                if ($blfs) foreach ($blfs->childNodes as $blf) if ($blf instanceof DOMElement) {
                    $attributes = []; foreach ($blf->attributes as $attribute) $attributes[$attribute->name] = $attribute->value;
                    $keys[] = ['source_element' => $blf->tagName, 'attributes' => $attributes, 'text' => $blf->textContent];
                }
            } finally { libxml_clear_errors(); libxml_use_internal_errors($previous); }
        }
        $properties = $user['phone_properties'] ?? [];
        if (!is_array($properties)) throw new InvalidArgumentException('A source phone has invalid user settings.');
        $sipUser = self::identity($phone['sip_user'] ?? $flat['sipuser'] ?? $flat['sipusername'] ?? $number);
        if (isset($flat['authid']) && $flat['authid'] !== $auth || isset($flat['authuser']) && $flat['authuser'] !== $auth || isset($flat['password']) && $flat['password'] !== $password) throw new InvalidArgumentException('The source phone and user credentials disagree.');
        $transport = $phone['transport'] ?? $flat['siptransport'] ?? $flat['transport'] ?? null;
        if ($transport !== null && $transport !== '') {
            $transport = strtolower(self::text($transport, 16));
            if (!in_array($transport, ['udp','tcp','tls'], true)) throw new InvalidArgumentException('A source phone transport needs explicit compatibility review.');
        } else $transport = null;
        $port = self::integer($phone['sip_port'] ?? $flat['sipport'] ?? $flat['serverport'] ?? null);
        $expires = self::integer($phone['register_expires'] ?? $flat['registerexpires'] ?? null);
        $proxy = $phone['outbound_proxy'] ?? $flat['outboundproxy'] ?? $flat['proxy'] ?? null;
        if ($proxy !== null) $proxy = self::text($proxy, 1024);
        $template = self::text($phone['template'] ?? '', 255);
        $vendor = str_contains(strtolower($template), 'fanvil') ? 'fanvil' : (str_contains(strtolower($template), 'genericphone') ? 'generic' : null);
        $model = $phone['model'] ?? $flat['model'] ?? $flat['phonemodel'] ?? null;
        if ($model !== null) $model = self::text($model, 128);
        $mac = self::text($phone['mac'] ?? '', 12);
        if ($mac !== '' && !preg_match('/^[0-9a-f]{12}$/D', $mac)) throw new InvalidArgumentException('A source phone address is invalid.');
        $dependencies = [];
        if ($model === null || $model === '') $dependencies[] = 'The backup does not identify the exact phone model; automatic provisioning is unavailable.';
        if ($transport === null) $dependencies[] = 'The backup does not identify the active SIP transport; keep and verify the existing phone transport.';
        if ($port === null) $dependencies[] = 'The backup does not identify the registrar port; the new server must listen on the existing phone port.';
        if ($proxy !== null && $proxy !== '') $dependencies[] = 'A source outbound proxy is preserved; verify that it can route to the new tenant SIP domain.';
        if ($phone['interface'] ?? '') $dependencies[] = 'The source interface is preserved; verify LAN, SBC or router-phone reachability before handover.';
        $dependencies[] = 'Existing provisioning/RPS/DHCP settings can overwrite a manual domain change; review their original source before handover.';
        return [
            'device' => ['device_address'=>$mac, 'device_label'=>self::text($user['name'] ?? $number, 255), 'device_vendor'=>$vendor, 'device_model'=>$model, 'device_template'=>null, 'device_enabled'=>false, 'device_description'=>'Original phone settings preserved; no automatic reprovisioning template selected.'],
            'line' => ['line_number'=>1, 'server_address'=>$realm, 'server_address_primary'=>$realm, 'outbound_proxy_primary'=>$proxy, 'label'=>$number, 'display_name'=>self::text($user['name'] ?? $number, 255), 'user_id'=>$sipUser, 'auth_id'=>$auth, 'password'=>$password, 'sip_port'=>$port === null ? null : (string)$port, 'sip_transport'=>$transport, 'register_expires'=>$expires, 'enabled'=>($user['enabled'] ?? true) === true],
            'keys' => [], // Retain exact source BLF records; model-specific translation must be reviewed.
            'source_payload' => ['schema'=>1, 'phone'=>$phone, 'settings_xml'=>$settings, 'root_attributes'=>$rootAttributes, 'options'=>$options, 'codecs'=>$codecs, 'blfs'=>$keys, 'sip_user'=>$sipUser, 'auth_id'=>$auth, 'password'=>$password, 'phone_properties'=>$properties],
            'summary' => ['source_template'=>$template, 'vendor'=>$vendor, 'model'=>$model, 'settings_preserved'=>$settings !== '', 'codec_count'=>count($codecs), 'blf_count'=>count($keys), 'option_count'=>count($options), 'separate_authentication_id'=>$sipUser !== $auth, 'automatic_provisioning'=>false, 'transport_known'=>$transport !== null, 'port_known'=>$port !== null, 'proxy_present'=>$proxy !== null && $proxy !== ''],
            'dependencies' => $dependencies,
        ];
    }
}
