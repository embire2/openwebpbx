<?php
// SPDX-License-Identifier: AGPL-3.0-or-later
/** Read-only public-listener policy. Never changes profiles, ports or credentials. */
final class windows_public_listener_review extends RuntimeException {}
final class windows_public_listeners {
    public const CORE_SHA256='8553d88348093d5067d93369aa9793b38fe9e3c9c9ca0c38216791700bd7f726';
    public static function port(string $value): int {
        if(!preg_match('/^[1-9][0-9]{0,4}$/D',$value)||($port=(int)$value)<1024||$port>65535||in_array($port,[3389,5432,5433,8021,8087],true))throw new RuntimeException('A configured public port is unsafe or unavailable.');
        return $port;
    }
    public static function resolve(string $value,callable $api): string {
        if(preg_match('/^\$\$\{([A-Za-z_][A-Za-z0-9_]{0,63})\}$/D',$value,$m))$value=trim($api('global_getvar '.$m[1]));
        if($value===''||strlen($value)>256||preg_match('/[\x00-\x20\x7f$]/',$value))throw new RuntimeException('A configured listener variable could not be resolved.');
        return $value;
    }
    private static function boolean(string $value,callable $api): bool {
        return match(strtolower(self::resolve($value,$api))){'true','yes','on','1'=>true,'false','no','off','0'=>false,default=>throw new RuntimeException('A configured listener flag is ambiguous.')};
    }
    private static function field(string $status,string $name,bool $optional=false): ?string {
        preg_match_all('/^'.preg_quote($name,'/').'[\t ]+([^\r\n]+)[\t ]*$/m',$status,$m);
        if(!$m[1]&&$optional)return null;
        if(count($m[1])!==1)throw new RuntimeException('The native listener status is ambiguous.');
        return trim($m[1][0]);
    }
    private static function binding(string $value,string $ip,int $port,bool $tls): array {
        if(strlen($value)>2048||!preg_match('/^(sip|sips):[A-Za-z0-9_.-]+@(\[[0-9A-Fa-f:]+\]|[0-9.]+):([1-9][0-9]{0,4})((?:;[A-Za-z][A-Za-z0-9_-]*=[A-Za-z0-9_.:,\[\]-]+)*)$/D',$value,$m)||($m[1]==='sips')!==$tls||(int)$m[3]!==$port)throw new RuntimeException('The actual SIP binding differs from its configured port.');
        $host=trim($m[2],'[]');$options=[];
        foreach(array_filter(explode(';',$m[4])) as $option){[$key,$val]=explode('=',$option,2);if(isset($options[$key]))throw new RuntimeException('A native SIP binding option is duplicated.');$options[$key]=$val;}
        $local=$options['maddr']??$host;
        if(!filter_var($local,FILTER_VALIDATE_IP)||inet_pton($local)!==inet_pton($ip))throw new RuntimeException('The actual SIP bind address differs from its native profile.');
        $transport=$options['transport']??($tls?'tls':'udp,tcp');$protocols=$tls?['TCP']:match($transport){'udp'=>['UDP'],'tcp'=>['TCP'],'udp,tcp','tcp,udp'=>['TCP','UDP'],default=>throw new RuntimeException('The actual SIP transport is unsupported.')};
        if($tls&&$transport!=='tls')throw new RuntimeException('The actual secure SIP transport is ambiguous.');
        return array_map(fn($protocol)=>['address'=>$ip,'port'=>$port,'protocol'=>$protocol,'tls'=>$tls],$protocols);
    }
    public static function snapshot(PDO $db,callable $api,string $coreHash,array $privatePorts=[5433,8021,8087]): array {
        $db->beginTransaction();try{
            $db->exec("set transaction read only;set local statement_timeout='5s';set local search_path=public");
            $rows=$db->query("select p.sip_profile_uuid,p.sip_profile_name,s.sip_profile_setting_name,s.sip_profile_setting_value from public.v_sip_profiles p left join public.v_sip_profile_settings s on s.sip_profile_uuid=p.sip_profile_uuid and s.sip_profile_setting_enabled=true and s.sip_profile_setting_name in ('sip-port','tls-sip-port','tls','tls-only') where p.sip_profile_enabled=true order by p.sip_profile_name,s.sip_profile_setting_name limit 8193")->fetchAll(PDO::FETCH_ASSOC);
            if(count($rows)>8192)throw new RuntimeException('The configured listener inventory exceeds its bound.');
            $profiles=[];$owners=[];foreach($rows as $row){$name=$row['sip_profile_name'];if(!preg_match('/^[A-Za-z0-9][A-Za-z0-9_.-]{0,63}$/D',$name))throw new RuntimeException('A native SIP profile name is unsafe.');$owner=$row['sip_profile_uuid'];if(isset($owners[$name])&&$owners[$name]!==$owner)throw new RuntimeException('A native SIP profile name is duplicated.');$owners[$name]=$owner;$key=$row['sip_profile_setting_name'];if(in_array($key,['sip-port','tls-sip-port','tls','tls-only'],true)){if(isset($profiles[$name][$key]))throw new RuntimeException('A configured SIP setting is duplicated.');$profiles[$name][$key]=(string)$row['sip_profile_setting_value'];}else $profiles[$name]??=[];}
            if(!$profiles||count($profiles)>32)throw new RuntimeException('The enabled native SIP profiles need review.');
            $listeners=[];$skipped=[];$loopback=[];
            foreach($profiles as $name=>$settings){
                $status=$api('sofia status profile '.$name);
                // A configured IPv6-only profile may not start on an IPv4-only
                // host. It creates no allow rule and is never called qualified.
                if(str_ends_with($name,'-ipv6')&&trim($status)==='Invalid Profile!'){$skipped[]=$name;continue;}
                if(strlen($status)>65536||self::field($status,'Name')!==$name)throw new RuntimeException('The native SIP profile is unavailable.');
                $ip=self::field($status,'SIP-IP');if(!filter_var($ip,FILTER_VALIDATE_IP))throw new RuntimeException('The native SIP bind address is unavailable.');
                $profileListeners=[];
                $only=self::boolean($settings['tls-only']??'false',$api);$secure=self::boolean($settings['tls']??'false',$api);
                if(!$secure||!$only){$port=self::port(self::resolve($settings['sip-port']??'',$api));$profileListeners=array_merge($profileListeners,self::binding(self::field($status,'BIND-URL'),$ip,$port,false));}
                if($secure){$port=self::port(self::resolve($settings['tls-sip-port']??'',$api));$profileListeners=array_merge($profileListeners,self::binding(self::field($status,'TLS-BIND-URL'),$ip,$port,true));}
                elseif(self::field($status,'TLS-BIND-URL',true)!==null)throw new RuntimeException('The secure native listener disagrees with its configured flag.');
                $packed=inet_pton($ip);if((strlen($packed)===4&&ord($packed[0])===127)||$packed===inet_pton('::1')){$loopback[]=$name;continue;}
                $listeners=array_merge($listeners,$profileListeners);
            }
            foreach($listeners as $listener)if(in_array($listener['port'],$privatePorts,true))throw new RuntimeException('A SIP listener overlaps the configured private service.');
            if(!$listeners||count($listeners)>128)throw new RuntimeException('No bounded native SIP listener plan is available.');
            $xml=$api('xml_locate configuration configuration name switch.conf');
            if(strlen($xml)>262144||stripos($xml,'<!DOCTYPE')!==false||stripos($xml,'<!ENTITY')!==false)throw new RuntimeException('The core audio configuration is unavailable.');
            $prior=libxml_use_internal_errors(true);try{$document=simplexml_load_string($xml,SimpleXMLElement::class,LIBXML_NONET);if(!$document)throw new RuntimeException('The core audio configuration is invalid.');}finally{libxml_clear_errors();libxml_use_internal_errors($prior);}
            $configs=$document->getName()==='configuration'&&((string)$document['name'])==='switch.conf'?[$document]:$document->xpath('//configuration[@name="switch.conf"]');
            if(count($configs)!==1)throw new RuntimeException('The core audio configuration is ambiguous.');
            // This release deliberately supports only the stock core range.
            // Current XML is not an in-process getter after a manual runtime
            // change. Explicit overrides therefore require administrator review.
            foreach($configs[0]->xpath('./settings/param') as $parameter)if(in_array(strtolower((string)$parameter['name']),['rtp-start-port','rtp-end-port'],true))throw new windows_public_listener_review('custom_audio_range');
            if($coreHash!==self::CORE_SHA256)throw new RuntimeException('Unknown native core audio defaults were refused.');
            $range=[16384,32768];$defaults=true;
            $db->rollBack();
            usort($listeners,fn($a,$b)=>[$a['address'],$a['port'],$a['protocol'],$a['tls']]<=>[$b['address'],$b['port'],$b['protocol'],$b['tls']]);$listeners=array_values(array_map('unserialize',array_unique(array_map('serialize',$listeners))));
            return ['schema'=>1,'listeners'=>$listeners,'rtp_start'=>$range[0],'rtp_end'=>$range[1],'rtp_supported_core_defaults'=>$defaults,'rtp_proof'=>'supported_core_configured_default','skipped_inactive_ipv6_profiles'=>$skipped,'skipped_loopback_profiles'=>$loopback,'private_ports'=>array_values(array_unique(array_merge([3389,5432,5433,8021,8087],$privatePorts))),'database_read_only'=>true];
        }catch(Throwable $error){if($db->inTransaction())$db->rollBack();throw $error;}
    }
}
