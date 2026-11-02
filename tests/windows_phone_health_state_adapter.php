<?php
/** Native Windows Defender Firewall adapter. Helpers and rules are instance owned. */
class openweb_diag_event_guard_windows implements event_guard_interface {
    public const BASE_SOURCE_SHA256='0e0311083519120dfb9041bec9816bb5d62096909e9cd5e9e35f9a9034d6f72c';
    public array $lastRun=[];public ?string $lastExecutor=null;
    public function neutral():?string {if($this->lastExecutor===null)return null;return $this->run([$this->lastExecutor,'-NoProfile','-NonInteractive','-Command',"[Console]::Out.WriteLine(12345)"]);}
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
    protected function spoolDirectory(): string {return pbx_paths::state().'/phone-health-runtime';}
    /** Anonymous Windows pipes cannot provide a reliable nonblocking deadline.
     * Use only the installed SYSTEM/Admin protected spool, never writable TEMP.
     * Pass the file HANDLE, poll bounded metadata, and close/delete on exit. */
    protected function run(array $arguments): ?string {
        $started=microtime(true);$this->lastExecutor=$arguments[0]??null;$this->lastRun=['started'=>true,'process_created'=>false,'cutoff'=>'none','native_exit'=>null,'close_exit'=>null,'last_running'=>null,'output_bytes'=>null,'raw_returned'=>false,'json_state'=>'unobserved','elapsed_ms'=>null];
        $directory=$this->spoolDirectory();if(!is_dir($directory)||is_link($directory)){$this->lastRun['cutoff']='spool_directory';return null;}
        $file=$directory.'/.result-'.bin2hex(random_bytes(16)).'.tmp';$output=@fopen($file,'x+b');if(!is_resource($output)){$this->lastRun['cutoff']='spool_open';return null;}
        $null=PHP_OS_FAMILY==='Windows'?'NUL':'/dev/null';$p=null;$exit=null;$refused=false;
        try{
            $p=@proc_open($arguments,[0=>['file',$null,'r'],1=>$output,2=>['file',$null,'w']],$pipes,null,null,['bypass_shell'=>true]);
            if(!is_resource($p)){$this->lastRun['cutoff']='proc_open';return null;}$this->lastRun['process_created']=true;$deadline=microtime(true)+15;
            do{$status=proc_get_status($p);$size=fstat($output)['size'];$this->lastRun['last_running']=(bool)$status['running'];$this->lastRun['native_exit']=(int)$status['exitcode'];$this->lastRun['output_bytes']=(int)$size;if($size>8192||microtime(true)>$deadline){$this->lastRun['cutoff']=$size>8192?'output_size':'15s_deadline';$refused=true;proc_terminate($p);break;}if(!$status['running']){$exit=$status['exitcode'];break;}usleep(20000);}while(true);
            $closed=proc_close($p);$this->lastRun['close_exit']=$closed;$p=null;if($exit===null||$exit<0)$exit=$closed;
            if($refused||$exit!==0||fstat($output)['size']>8192){if($this->lastRun['cutoff']==='none')$this->lastRun['cutoff']=$exit!==0?'native_exit':'output_size';return null;}
            rewind($output);$raw=stream_get_contents($output,8193);try{$this->lastRun['raw_returned']=is_string($raw)&&strlen($raw)<=8192;$j=is_string($raw)?json_decode($raw,true,8,JSON_THROW_ON_ERROR):null;$this->lastRun['json_state']=is_array($j)&&in_array($j['state']??null,['present','absent','unknown'],true)?$j['state']:'other';}catch(Throwable){$this->lastRun['json_state']='invalid';}return is_string($raw)&&strlen($raw)<=8192?$raw:null;
        }finally{$this->lastRun['elapsed_ms']=(int)round((microtime(true)-$started)*1000);if(is_resource($p)){proc_terminate($p);proc_close($p);}fclose($output);@unlink($file);}
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
