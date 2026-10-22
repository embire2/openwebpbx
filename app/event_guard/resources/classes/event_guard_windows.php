<?php
/** Native Windows Defender Firewall adapter. Helpers and rules are instance owned. */
class event_guard_windows implements event_guard_interface {
    private const FILTERS=['sip-auth-ip','sip-auth-fail'];
    public function __construct(?settings $settings=null) {
        if(PHP_OS_FAMILY!=='Windows'||PHP_SAPI!=='cli')throw new RuntimeException('The managed Windows security worker is required.');
    }
    /** Read running profile listeners, never a hard-coded assumed SIP port. */
    public static function ports(string $raw): array {
        if(strlen($raw)>1048576||str_contains($raw,'<!DOCTYPE')||str_contains($raw,'<!ENTITY'))throw new RuntimeException('Phone listener status needs review.');
        $xml=@simplexml_load_string($raw,'SimpleXMLElement',LIBXML_NONET|LIBXML_NOERROR|LIBXML_NOWARNING);
        if(!$xml||$xml->getName()!=='profiles')throw new RuntimeException('Phone listeners are unavailable.');
        $ports=['tcp'=>[],'udp'=>[]];$reserved=[22,80,443,3389,5985,5986];
        foreach($xml->profile as$p){$data=(string)$p->data;if((string)$p->type!=='profile'||!str_starts_with((string)$p->state,'RUNNING')||str_contains($data,'transport=ws'))continue;
            if(!preg_match('~^(sips?):[^@\s]+@(?:\[([^\]]+)\]|([^:;\s]+)):([0-9]{1,5})(?:;transport=(tcp|udp|tls))?$~D',$data,$m))throw new RuntimeException('Phone listener status needs review.');
            $host=$m[2]?:$m[3];if($host==='127.0.0.1'||$host==='::1')continue;$port=(int)$m[4];if($port<1||$port>65535||in_array($port,$reserved,true))throw new RuntimeException('The phone listener overlaps a protected administration port.');
            $ports['tcp'][$port]=$port;if($m[1]==='sip'&&($m[5]??'')!=='tcp')$ports['udp'][$port]=$port;
        }
        foreach($ports as$protocol=>$values){sort($values,SORT_NUMERIC);if(count($values)>32)throw new RuntimeException('Too many phone listeners.');$ports[$protocol]=$values;}
        if(!$ports['tcp']||!$ports['udp'])throw new RuntimeException('Both running phone transports are required.');return $ports;
    }
    protected function request(string $operation,string $address,string $filter): array {
        if(!in_array($operation,['State','Add','Remove'],true)||!in_array($filter,self::FILTERS,true)||!filter_var($address,FILTER_VALIDATE_IP,FILTER_FLAG_IPV4))return ['state'=>'unknown'];
        try{$ports=self::ports(pbx_windows_health_stream::api('sofia xmlstatus'));}catch(Throwable){return ['state'=>'unknown'];}
        $address=inet_ntop(inet_pton($address));$powershell=(getenv('SystemRoot')?:'C:\\Windows').'\\System32\\WindowsPowerShell\\v1.0\\powershell.exe';
        $helper='C:\\OpenWebPBX\\tools\\PhoneHealth-Firewall.ps1';
        $p=@proc_open([$powershell,'-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',$helper,'-Operation',$operation,'-Address',$address,'-Filter',$filter,'-TcpPorts',implode(',',$ports['tcp']),'-UdpPorts',implode(',',$ports['udp'])],[0=>['file','NUL','r'],1=>['pipe','w'],2=>['file','NUL','w']],$pipes,null,null,['bypass_shell'=>true]);
        if(!is_resource($p))return ['state'=>'unknown'];
        stream_set_blocking($pipes[1],false);$raw='';$exit=null;$deadline=microtime(true)+15;
        try{do{$raw.=stream_get_contents($pipes[1],8193);$s=proc_get_status($p);if(strlen($raw)>8192||microtime(true)>$deadline){proc_terminate($p);return ['state'=>'unknown'];}if(!$s['running']){$raw.=stream_get_contents($pipes[1],8193);$exit=$s['exitcode'];break;}usleep(20000);}while(true);}
        finally{fclose($pipes[1]);$closed=proc_close($p);if($exit===null||$exit<0)$exit=$closed;}
        if($exit!==0||strlen($raw)>8192)return ['state'=>'unknown'];
        try{$r=json_decode($raw,true,8,JSON_THROW_ON_ERROR);}catch(Throwable){return ['state'=>'unknown'];}
        if(!is_array($r)||array_keys($r)!==['state']||!in_array($r['state'],['present','absent','unknown'],true))return ['state'=>'unknown'];
        return $r;
    }
    public function block_state_exact(string $address,string $filter): string {return $this->request('State',$address,$filter)['state'];}
    public function healthy(): bool {return $this->block_state_exact('198.18.0.254','sip-auth-fail')!=='unknown';}
    public function block_delete_exact(string $address,string $filter): bool {return $filter==='sip-auth-fail'&&$this->request('Remove',$address,$filter)['state']==='absent';}
    public function block_add(string $address,string $filter): bool {return $this->request('Add',$address,$filter)['state']==='present';}
    public function block_exists(string $address,string $filter): bool {return $this->block_state_exact($address,$filter)==='present';}
    public function block_delete(string $address,string $filter): bool {
        // The broad legacy web action is deliberately unavailable. Health requests
        // must pass fresh tenant/source/actor checks before the exact method runs.
        return false;
    }
}
