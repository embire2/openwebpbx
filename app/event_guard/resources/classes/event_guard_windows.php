<?php
/** Native Windows Defender Firewall adapter. Helpers and rules are instance owned. */
class event_guard_windows implements event_guard_interface {
    private const FILTERS=['sip-auth-ip','sip-auth-fail'];
    public function __construct(?settings $settings=null) {
        if(PHP_OS_FAMILY!=='Windows'||PHP_SAPI!=='cli')throw new RuntimeException('The managed Windows security worker is required.');
    }
    /** Global URLs advertise NAT addresses. Resolve actual native profile binds. */
    public static function ports(string $raw,?callable $status=null): array {
        if(strlen($raw)>1048576||stripos($raw,'<!DOCTYPE')!==false||stripos($raw,'<!ENTITY')!==false)throw new RuntimeException('Phone listener status needs review.');
        $xml=@simplexml_load_string($raw,'SimpleXMLElement',LIBXML_NONET|LIBXML_NOERROR|LIBXML_NOWARNING);
        if(!$xml||$xml->getName()!=='profiles')throw new RuntimeException('Phone listeners are unavailable.');
        $profiles=[];$seen=[];$rows=0;$deadline=microtime(true)+15;
        foreach($xml->profile as$p){
            if(++$rows>128)throw new RuntimeException('Too many native profile records.');
            foreach(['name','type','state','data']as$field)if(count($p->{$field})!==1)throw new RuntimeException('The native profile inventory is ambiguous.');
            $name=(string)$p->name;$state=(string)$p->state;
            if((string)$p->type!=='profile'||!preg_match('/^[A-Za-z0-9][A-Za-z0-9_.-]{0,63}$/D',$name))throw new RuntimeException('The native profile name is unsafe.');
            if(preg_match('/^DOWN(?: \([0-9]+\))?$/D',$state))continue;
            if(!preg_match('/^RUNNING(?: \([0-9]+\))?(?: \((TLS|WS|WSS)\))?$/D',$state,$match))throw new RuntimeException('The native profile state is ambiguous.');
            $kind=$match[1]??'plain';if(in_array($kind,['WS','WSS'],true))continue;
            $data=(string)$p->data;if(strlen($data)>2048||!preg_match('~^(sips?):[^@\s]+@(?:\[([^\]]+)\]|([^:;\s]+)):([0-9]{1,5})(?:;transport=(tcp|udp|tls))?$~D',$data,$advert)||((int)$advert[4])<1||((int)$advert[4])>65535)throw new RuntimeException('The native profile advertisement is malformed.');
            $key=$name.':'.$kind;if(isset($seen[$key]))throw new RuntimeException('The native profile record is duplicated.');$seen[$key]=true;$profiles[$name][$kind]=true;
            if(count($profiles)>32)throw new RuntimeException('Too many running phone profiles.');
        }
        if(!$profiles)throw new RuntimeException('Running phone profiles are unavailable.');
        $status??=static fn(string$name):string=>pbx_windows_health_stream::api('sofia status profile '.$name,$deadline);
        $ports=['tcp'=>[],'udp'=>[]];$bytes=0;
        foreach($profiles as$name=>$required){
            $name=(string)$name;
            if(microtime(true)>=$deadline)throw new RuntimeException('The native profile inventory timed out.');
            $rawStatus=$status($name);
            if(!is_string($rawStatus)||strlen($rawStatus)>65536||($bytes+=strlen($rawStatus))>1048576||str_contains($rawStatus,"\0")||microtime(true)>=$deadline)throw new RuntimeException('The native profile response needs review.');
            if(self::field($rawStatus,'Name')!==$name)throw new RuntimeException('The native profile response belongs to another profile.');
            $ip=self::field($rawStatus,'SIP-IP');if(!filter_var($ip,FILTER_VALIDATE_IP))throw new RuntimeException('The native SIP bind address is unavailable.');
            $plain=self::field($rawStatus,'BIND-URL',true);$tls=self::field($rawStatus,'TLS-BIND-URL',true);
            if($plain===null&&$tls===null)throw new RuntimeException('The native profile has no verified bind.');
            if((isset($required['plain'])&&$plain===null)||(isset($required['TLS'])&&$tls===null))throw new RuntimeException('A running native phone transport has no verified bind.');
            $bindings=[];if($plain!==null)$bindings=array_merge($bindings,self::binding($plain,$ip,false));if($tls!==null)$bindings=array_merge($bindings,self::binding($tls,$ip,true));
            $packed=inet_pton($ip);if((strlen($packed)===4&&ord($packed[0])===127)||$packed===inet_pton('::1')||(strlen($packed)===16&&substr($packed,0,12)===str_repeat("\0",10)."\xff\xff"&&ord($packed[12])===127))continue;
            foreach($bindings as$binding)foreach($binding['protocols']as$protocol)$ports[$protocol][$binding['port']]=$binding['port'];
        }
        foreach($ports as$protocol=>$values){sort($values,SORT_NUMERIC);if(count($values)>32)throw new RuntimeException('Too many phone listeners.');$ports[$protocol]=$values;}
        if(!$ports['tcp']||!$ports['udp'])throw new RuntimeException('Both running phone transports are required.');return $ports;
    }
    private static function field(string $status,string $name,bool $optional=false):?string {
        preg_match_all('/^'.preg_quote($name,'/').'[\t ]+([^\r\n]+)[\t ]*\r?$/m',$status,$m);
        if(!$m[1]&&$optional)return null;if(count($m[1])!==1)throw new RuntimeException('The native listener status is ambiguous.');return trim($m[1][0]);
    }
    /** Same SIP-IP/BIND-URL/maddr transport contract as the public listener plan. */
    private static function binding(string $value,string $ip,bool $tls):array {
        if(strlen($value)>2048||!preg_match('/^(sip|sips):[A-Za-z0-9_.-]+@(\[[0-9A-Fa-f:]+\]|[0-9.]+):([1-9][0-9]{0,4})((?:;[A-Za-z][A-Za-z0-9_-]*=[A-Za-z0-9_.:,\[\]-]+)*)$/D',$value,$m)||($m[1]==='sips')!==$tls)throw new RuntimeException('The native SIP bind URL is invalid.');
        $port=(int)$m[3];if($port<1||$port>65535||in_array($port,[22,80,443,3389,5985,5986],true))throw new RuntimeException('The phone listener overlaps a protected administration port.');
        $options=[];foreach(array_filter(explode(';',$m[4]))as$option){[$key,$val]=explode('=',$option,2);if(!in_array($key,['maddr','transport'],true)||isset($options[$key]))throw new RuntimeException('The native SIP binding option is ambiguous.');$options[$key]=$val;}
        $local=$options['maddr']??trim($m[2],'[]');if(!filter_var($local,FILTER_VALIDATE_IP)||inet_pton($local)!==inet_pton($ip))throw new RuntimeException('The native SIP bind address disagrees with its profile.');
        $transport=$options['transport']??($tls?'tls':'udp,tcp');$protocols=$tls?['tcp']:match($transport){'udp'=>['udp'],'tcp'=>['tcp'],'udp,tcp','tcp,udp'=>['udp','tcp'],default=>throw new RuntimeException('The native SIP transport is unsupported.')};
        if($tls&&$transport!=='tls')throw new RuntimeException('The native secure SIP transport is ambiguous.');return [['port'=>$port,'protocols'=>$protocols]];
    }
    protected function spoolDirectory(): string {return pbx_paths::state().'/phone-health-runtime';}
    /** Anonymous Windows pipes cannot provide a reliable nonblocking deadline.
     * Use only the installed SYSTEM/Admin protected spool, never writable TEMP.
     * Pass the file HANDLE, poll bounded metadata, and close/delete on exit. */
    protected function run(array $arguments): ?string {
        $directory=$this->spoolDirectory();if(!is_dir($directory)||is_link($directory))return null;
        $file=$directory.'/.result-'.bin2hex(random_bytes(16)).'.tmp';$output=@fopen($file,'x+b');if(!is_resource($output))return null;
        $null=PHP_OS_FAMILY==='Windows'?'NUL':'/dev/null';$p=null;$exit=null;$refused=false;
        try{
            $p=@proc_open($arguments,[0=>['file',$null,'r'],1=>$output,2=>['file',$null,'w']],$pipes,null,null,['bypass_shell'=>true]);
            if(!is_resource($p))return null;$deadline=microtime(true)+15;
            do{$status=proc_get_status($p);$size=fstat($output)['size'];if($size>8192||microtime(true)>$deadline){$refused=true;proc_terminate($p);break;}if(!$status['running']){$exit=$status['exitcode'];break;}usleep(20000);}while(true);
            $closed=proc_close($p);$p=null;if($exit===null||$exit<0)$exit=$closed;
            if($refused||$exit!==0||fstat($output)['size']>8192)return null;
            rewind($output);$raw=stream_get_contents($output,8193);return is_string($raw)&&strlen($raw)<=8192?$raw:null;
        }finally{if(is_resource($p)){proc_terminate($p);proc_close($p);}fclose($output);@unlink($file);}
    }
    protected function request(string $operation,string $address,string $filter): array {
        if(!in_array($operation,['State','Add','Remove'],true)||!in_array($filter,self::FILTERS,true)||!filter_var($address,FILTER_VALIDATE_IP,FILTER_FLAG_IPV4))return ['state'=>'unknown'];
        try{$ports=self::ports(pbx_windows_health_stream::api('sofia xmlstatus'));}catch(Throwable){return ['state'=>'unknown'];}
        $address=inet_ntop(inet_pton($address));$powershell=(getenv('SystemRoot')?:'C:\\Windows').'\\System32\\WindowsPowerShell\\v1.0\\powershell.exe';
        $helper='C:\\OpenWebPBX\\tools\\PhoneHealth-Firewall.ps1';
        $raw=$this->run([$powershell,'-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',$helper,'-Operation',$operation,'-Address',$address,'-Filter',$filter,'-TcpPorts',implode(',',$ports['tcp']),'-UdpPorts',implode(',',$ports['udp'])]);
        if($raw===null)return ['state'=>'unknown'];
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
