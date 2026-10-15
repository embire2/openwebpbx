<?php
/** Resolve only configured provider endpoints into a saved, exact IP allowlist. */
class pbx_provider_dns {
    private array $cache=[];
    private int $queries=0;
    protected function lookup(string $name,int $type): array {return @dns_get_record($name,$type)?:[];}
    private function records(string $name,int $type): array {
        $key=$type.':'.$name;
        if(isset($this->cache[$key]))return $this->cache[$key];
        if(++$this->queries>32)throw new RuntimeException('The provider DNS response is too large. Enter its incoming addresses in Advanced settings.');
        $rows=$this->lookup($name,$type);
        if(count($rows)>64)throw new RuntimeException('The provider DNS response is too large. Enter its incoming addresses in Advanced settings.');
        return $this->cache[$key]=$rows;
    }
    private static function host(string $value): string {
        $value=strtolower(rtrim($value,'.'));
        if(strlen($value)>253||!preg_match('/^(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)*[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$/D',$value))throw new InvalidArgumentException('Enter a valid provider server name.');
        return $value;
    }
    /** Private/on-premise unicast providers are supported; no networks or wildcards. */
    public static function address(string $value): ?string {
        if(!filter_var($value,FILTER_VALIDATE_IP))return null;
        $bytes=inet_pton($value);
        if(strlen($bytes)===4){if(ord($bytes[0])===0||ord($bytes[0])>=224)return null;}
        elseif($bytes===str_repeat("\0",16)||ord($bytes[0])===255)return null;
        elseif(substr($bytes,0,12)===str_repeat("\0",10)."\xff\xff"&&self::address(inet_ntop(substr($bytes,12)))===null)return null;
        return inet_ntop($bytes);
    }
    private static function endpoint(string $value): array {
        if($value===''||strlen($value)>260||preg_match('/[\x00-\x20\x7f$@;\/\\\\]/',$value))throw new InvalidArgumentException('Enter a valid provider server or proxy.');
        $port=null;
        if(preg_match('/^\[([^\]]+)\](?::([0-9]+))?$/D',$value,$m)){$host=$m[1];$port=$m[2]??null;if(!filter_var($host,FILTER_VALIDATE_IP,FILTER_FLAG_IPV6))throw new InvalidArgumentException('Enter a valid provider proxy.');}
        elseif(filter_var($value,FILTER_VALIDATE_IP,FILTER_FLAG_IPV6))$host=$value;
        elseif(preg_match('/^([^:]+)(?::([0-9]+))?$/D',$value,$m)){$host=$m[1];$port=$m[2]??null;}
        else throw new InvalidArgumentException('Enter a valid provider proxy.');
        if($port!==null&&filter_var($port,FILTER_VALIDATE_INT,['options'=>['min_range'=>1,'max_range'=>65535]])===false)throw new InvalidArgumentException('Enter a valid provider port.');
        if(!filter_var($host,FILTER_VALIDATE_IP))$host=self::host($host);
        return [$host,$port!==null];
    }
    private function addressesAt(string $host,array $seen=[]): array {
        if(filter_var($host,FILTER_VALIDATE_IP))return self::address($host)!==null?[self::address($host)]:[];
        if(isset($seen[$host])||count($seen)>=6)return [];
        $seen[$host]=true;$addresses=[];
        foreach($this->records($host,DNS_A|DNS_AAAA|DNS_CNAME) as $row){
            if(!is_array($row)||!is_string($row['host']??null)||strtolower(rtrim($row['host'],'.'))!==$host)continue;
            if(in_array($row['type']??'',['A','AAAA'],true)){
                $ip=$row[($row['type']==='A'?'ip':'ipv6')]??null;
                if(is_string($ip)&&($ip=self::address($ip))!==null)$addresses[]=$ip;
            }elseif(($row['type']??'')==='CNAME'&&is_string($row['target']??null)){
                try{$target=self::host($row['target']);}catch(InvalidArgumentException){continue;}
                $addresses=array_merge($addresses,$this->addressesAt($target,$seen));
            }
        }
        return array_values(array_unique($addresses));
    }
    public function addresses(array $trunk): array {
        $transport=$trunk['transport']??'udp';
        if(!in_array($transport,['udp','tcp','tls'],true))throw new InvalidArgumentException('Choose a valid provider transport.');
        $this->cache=[];$this->queries=0;$addresses=[];
        foreach(['host','register_proxy','outbound_proxy'] as $field){
            $value=$trunk[$field]??'';if($value==='')continue;
            if(!is_string($value))throw new InvalidArgumentException('Enter a valid provider server or proxy.');
            [$host,$explicitPort]=self::endpoint($value);
            $automatic=$field==='host'?!empty($trunk['provider_port_auto']):!$explicitPort;
            $found=$this->addressesAt($host);
            if($automatic&&!filter_var($host,FILTER_VALIDATE_IP)){
                $service=($transport==='tls'?'_sips._tcp.':'_sip._'.$transport.'.').$host;$targets=[];
                foreach($this->records($service,DNS_SRV) as $row){
                    if(!is_array($row)||($row['type']??'')!=='SRV'||!is_string($row['host']??null)||strtolower(rtrim($row['host'],'.'))!==$service)continue;
                    if(($row['target']??'')==='.'){$found=[];$targets=[];break;}
                    if(!is_string($row['target']??null)||filter_var(rtrim($row['target'],'.'),FILTER_VALIDATE_IP)||is_bool($row['port']??null)||filter_var($row['port']??null,FILTER_VALIDATE_INT,['options'=>['min_range'=>1,'max_range'=>65535]])===false)continue;
                    try{$target=self::host($row['target']);}catch(InvalidArgumentException){continue;}
                    $targets[$target]=true;
                    if(count($targets)>8)throw new RuntimeException('The provider DNS response is too large. Enter its incoming addresses in Advanced settings.');
                }
                foreach(array_keys($targets) as $target)$found=array_merge($found,$this->addressesAt($target));
            }
            $addresses=array_values(array_unique(array_merge($addresses,$found)));
            if(count($addresses)>64)throw new RuntimeException('The provider DNS response is too large. Enter its incoming addresses in Advanced settings.');
        }
        return $addresses;
    }
    public static function inputAddresses(array $trunk): string {return ($trunk['allowed_ips_source']??'')==='dns'?'':implode(', ',$trunk['allowed_ips']??[]);}
}
