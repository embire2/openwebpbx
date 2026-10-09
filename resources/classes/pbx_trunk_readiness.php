<?php
/** Read-only trunk checks. No SIP messages, registrations or calls are sent. */
class pbx_trunk_readiness {
    private static function on(mixed $value): bool { return filter_var($value, FILTER_VALIDATE_BOOLEAN); }

    /** Loaded modules alone are insufficient: passthrough can shadow a converter. */
    public static function g729Transcoding(string $response): ?bool {
        if (strlen($response)>262144) return null;
        $inventory=json_decode($response,true);
        if (!is_array($inventory) || !isset($inventory['rows']) || !is_array($inventory['rows'])) return null;
        $converter=false;
        foreach ($inventory['rows'] as $codec) {
            if (!is_array($codec) || ($codec['type']??'')!=='codec' || !in_array($codec['name']??'', ['G.729','G729'],true)) continue;
            if (($codec['ikey']??'')==='mod_g729') return false;
            if (in_array($codec['ikey']??'', ['mod_bcg729','mod_com_g729'],true)) $converter=true;
        }
        return $converter;
    }

    public static function gatewayState(string $response, string $gateway): array {
        if (strlen($response)>262144 || str_contains(strtoupper($response),'<!DOCTYPE')) return ['state'=>'unknown'];
        if (trim($response)==='Invalid Gateway!' || str_starts_with(trim($response),'-ERR')) return ['state'=>'not_loaded'];
        $xml=new DOMDocument;
        $previous=libxml_use_internal_errors(true);
        try {
            if (!$xml->loadXML($response,LIBXML_NONET)) return ['state'=>'unknown'];
            $nodes=$xml->getElementsByTagName('gateway');
            foreach ($nodes as $node) {
                $name=$node->getAttribute('name');
                if ($name!=='' && strtolower($name)!==strtolower($gateway)) continue;
                $state=strtoupper(trim($node->getElementsByTagName('state')->item(0)?->textContent??''));
                $status=strtoupper(trim($node->getElementsByTagName('status')->item(0)?->textContent??''));
                // Only allowlisted status words leave the engine response.
                return ['state'=>in_array($state,['REGED','NOREG','UNREGED','TRYING','REGISTER','FAILED','FAIL_WAIT','EXPIRED','REJECTED'],true)?$state:'unknown',
                    'availability'=>in_array($status,['UP','DOWN'],true)?$status:'unknown'];
            }
            return ['state'=>'unknown'];
        } finally { libxml_clear_errors();libxml_use_internal_errors($previous); }
    }

    public static function describe(array $trunk, ?array $gateway, array $runtime=[]): array {
        $issues=[];
        if (!$gateway) $issues[]='The saved provider connection is missing. Save this trunk again.';
        if (empty($trunk['host'])) $issues[]='Enter the provider server.';
        if (($trunk['type']??'')==='BridgeMaster') $issues[]='This 3CX bridge needs a replacement connection.';
        $registration=self::on($trunk['register']??false);
        $authentication=$trunk['auth_mode']??($registration?'credentials':'ip');
        if ($authentication==='credentials' && (empty($gateway['has_username']) || empty($gateway['has_password']))) $issues[]='Add the provider authentication ID and password.';
        if (empty($trunk['allowed_ips'])) $issues[]='Add the provider IP addresses for incoming calls.';
        $missingAudio=in_array('G729',$trunk['codecs']??[],true) && ($runtime['g729_transcoding']??null)===false;
        if ($missingAudio) $issues[]='One of the saved audio formats needs extra server support. Ask your instance administrator to enable G729 audio support, then test a call.';
        $enabled=self::on($trunk['enabled']??false);
        $state=$runtime['state']??'unknown';
        if (!$enabled) {$status='Off';$tone='muted';$next='Review provider settings and arrange the change from 3CX before enabling this trunk.';}
        elseif ($issues) {$status='Needs settings';$tone='warning';$next=$issues[0];}
        elseif ($state==='REGED') {$status='Registered';$tone='success';$next='Registration passed. Incoming and outgoing calls, caller ID and two-way audio still need testing.';}
        elseif ($state==='NOREG' && !$registration && ($runtime['availability']??'')!=='DOWN') {$status='Configured';$tone='neutral';$next=$authentication==='credentials'?'Provider authentication is saved without registration. Incoming and outgoing carrier calls still need testing.':'Ask your provider to whitelist this server and confirm incoming delivery. Carrier calls are not verified.';}
        elseif (in_array($state,['FAILED','FAIL_WAIT','REJECTED','EXPIRED','UNREGED'],true) || ($runtime['availability']??'')==='DOWN') {$status='Connection failed';$tone='warning';$next='Check the provider settings, authentication and firewall. Use Check provider for a connection check.';}
        elseif ($state==='not_loaded') {$status='Not connected';$tone='warning';$next='The running PBX has not loaded this trunk. An instance administrator must review the saved connection.';}
        elseif (in_array($state,['TRYING','REGISTER'],true)) {$status='Connecting';$tone='neutral';$next='The PBX is waiting for the provider. Refresh this page and check the provider settings if it does not connect.';}
        else {$status='Status unavailable';$tone='muted';$next='The provider status could not be read. Check that the PBX service is running.';}
        return ['status'=>$status,'tone'=>$tone,'configuration'=>$issues?'Needs settings':'Configured','issues'=>$issues,'next_step'=>$next,
            'enabled'=>$enabled,'missing_credentials'=>$authentication==='credentials'&&(empty($gateway['has_username'])||empty($gateway['has_password'])),
            'missing_provider_ips'=>empty($trunk['allowed_ips']),'missing_audio_support'=>$missingAudio,'calls_verified'=>false];
    }

    protected function resolveHost(string $host): array {
        if (filter_var($host,FILTER_VALIDATE_IP)) return [$host];
        $records=@dns_get_record($host,DNS_A|DNS_AAAA);
        $addresses=[];
        foreach ($records?:[] as $record) if (isset($record['ip']) || isset($record['ipv6'])) $addresses[]=$record['ip']??$record['ipv6'];
        return array_values(array_unique($addresses));
    }

    protected function localAddresses(): array {
        $addresses=[$_SERVER['SERVER_ADDR']??''];
        if(class_exists('pbx_paths'))$addresses[]=pbx_paths::address();
        return array_values(array_filter($addresses,static fn($ip)=>filter_var($ip,FILTER_VALIDATE_IP)));
    }

    protected function connectAddress(string $address, int $port, string $transport, string $host): bool {
        $context=stream_context_create(['ssl'=>['verify_peer'=>true,'verify_peer_name'=>true,'peer_name'=>$host,'SNI_enabled'=>true]]);
        $target=($transport==='tls'?'tls':'tcp').'://'.(str_contains($address,':')?'['.$address.']':$address).':'.$port;
        $socket=@stream_socket_client($target,$errorCode,$errorMessage,2,STREAM_CLIENT_CONNECT,$context);
        if (!$socket) return false;
        fclose($socket);
        return true;
    }

    public function checkProvider(array $trunk): array {
        $host=$trunk['host']??'';$port=$trunk['port']??5060;$transport=$trunk['transport']??'udp';
        if (!is_string($host) || strlen($host)>253 || (!filter_var($host,FILTER_VALIDATE_IP)
            && !preg_match('/^(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)*[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$/iD',$host))
            || filter_var($port,FILTER_VALIDATE_INT,['options'=>['min_range'=>1,'max_range'=>65535]])===false
            || !in_array($transport,['udp','tcp','tls'],true)) {
            throw new InvalidArgumentException('Save a valid provider server, port and transport first.');
        }
        $addresses=$this->resolveHost($host);
        if (!$addresses) return ['dns'=>'Failed','connection'=>'Not checked','tone'=>'warning','message'=>'The provider server could not be found. Check its spelling and your server DNS settings.'];
        // Do not probe private networks or this instance's known local/public addresses.
        $local=array_map('inet_pton',$this->localAddresses());
        $public=array_values(array_filter($addresses,static fn($ip)=>filter_var($ip,FILTER_VALIDATE_IP,FILTER_FLAG_NO_PRIV_RANGE|FILTER_FLAG_NO_RES_RANGE)&&!in_array(inet_pton($ip),$local,true)));
        if(!$public&&array_filter($addresses,static fn($ip)=>in_array(@inet_pton($ip),$local,true)))return ['dns'=>'Found','connection'=>'Not checked','tone'=>'warning','message'=>'The saved provider points back to this PBX. Check the provider server address. No connection was attempted.'];
        if (!$public) return ['dns'=>'Found','connection'=>'Not checked','tone'=>'neutral','message'=>'The server resolves to a private or reserved address. An instance administrator must check that connection directly.'];
        if ($transport==='udp') return ['dns'=>'Found','connection'=>'Not checked (UDP)','tone'=>'neutral','message'=>'The provider server was found. UDP cannot be confirmed without sending SIP traffic. No registration or call was attempted.'];
        $connected=false;
        foreach (array_slice($public,0,2) as $address) if ($this->connectAddress($address,(int)$port,$transport,$host)) {$connected=true;break;}
        return ['dns'=>'Found','connection'=>$connected?($transport==='tls'?'TLS verified':'TCP connected'):'Failed','tone'=>$connected?'success':'warning',
            'message'=>$connected?'The provider accepted a connection. No SIP message or call was sent. Provider authentication, incoming calls and audio still need testing.':
                ($transport==='tls'?'The secure connection failed. Check the provider port, certificate and firewall.':'The provider connection failed. Check the provider port and firewall.')];
    }
}
