<?php
/** Bounded, exact Debian iptables operations for Phone Health and safe chain setup. */
class pbx_phone_health_firewall {
    private string $binary;
    private const FILTERS=['sip-auth-ip','sip-auth-fail'];
    public function __construct(string $binary) {
        $real=realpath($binary);
        if($real===false||!str_starts_with($binary,'/')||!is_file($real)||!is_executable($real)||fileowner($real)!==0||(fileperms($real)&0022)!==0||!in_array(basename($real),['iptables','iptables-nft','iptables-legacy','xtables-nft-multi','xtables-legacy-multi'],true))throw new RuntimeException('The system firewall executable needs review.');
        $this->binary=$binary;
    }
    protected function run(array $args): array {
        $pipes=[];$p=@proc_open(array_merge([$this->binary,'-w','2'],$args),[0=>['pipe','r'],1=>['pipe','w'],2=>['pipe','w']],$pipes,null,['PATH'=>'/usr/sbin:/usr/bin:/sbin:/bin','LC_ALL'=>'C']);
        if(!is_resource($p))return ['exit'=>null,'stderr'=>''];
        fclose($pipes[0]);stream_set_blocking($pipes[1],false);stream_set_blocking($pipes[2],false);$out='';$err='';$deadline=microtime(true)+3.0;$exit=null;$refused=false;
        while(true){$out.=stream_get_contents($pipes[1],8192);$err.=stream_get_contents($pipes[2],8192);$s=proc_get_status($p);
            if(strlen($out)+strlen($err)>65536||microtime(true)>$deadline){$refused=true;proc_terminate($p,9);break;}
            if(!$s['running']){
                // A short-lived child may exit while its final bytes are still in the pipe.
                $out.=stream_get_contents($pipes[1],65537);$err.=stream_get_contents($pipes[2],65537);
                if(strlen($out)+strlen($err)>65536||microtime(true)>$deadline)$refused=true;
                else $exit=$s['exitcode'];
                break;
            }usleep(10000);
        }
        fclose($pipes[1]);fclose($pipes[2]);$closed=proc_close($p);if(!$refused&&$exit===null&&$closed>=0)$exit=$closed;
        return ['exit'=>$refused?null:$exit,'stderr'=>$err];
    }
    private static function missing(array $r): bool {return $r['exit']===1&&str_contains($r['stderr'],'Bad rule (does a matching rule exist in that chain?)');}
    public function state(string $address,string $filter): string {
        if(!in_array($filter,self::FILTERS,true)||!filter_var($address,FILTER_VALIDATE_IP,FILTER_FLAG_IPV4))return 'unknown';
        // iptables-nft can return the same "Bad rule" text for a missing chain.
        // Verify the requested chain exists before interpreting a failed -C as absence.
        if($this->run(['-S',$filter])['exit']!==0)return 'unknown';
        $r=$this->run(['-C',$filter,'-s',inet_ntop(inet_pton($address)),'-j','DROP']);
        return $r['exit']===0?'present':(self::missing($r)?'absent':'unknown');
    }
    public function remove(string $address,string $filter): bool {
        if($filter!=='sip-auth-fail'||!filter_var($address,FILTER_VALIDATE_IP,FILTER_FLAG_IPV4))return false;
        for($i=0;$i<32;$i++){
            $state=$this->state($address,$filter);if($state==='absent')return true;if($state!=='present')return false;
            if($this->run(['-D',$filter,'-s',inet_ntop(inet_pton($address)),'-j','DROP'])['exit']!==0)return false;
        }
        return $this->state($address,$filter)==='absent';
    }
    /** Restarting the guard must preserve existing chain rules and INPUT jump order. */
    public function ensureChains(): void {
        foreach(self::FILTERS as$filter){
            $r=$this->run(['-S',$filter]);
            if($r['exit']!==0){
                if($r['exit']!==1||!str_contains($r['stderr'],'No chain/target/match by that name'))throw new RuntimeException('Cannot inspect the firewall security chain.');
                if($this->run(['-N',$filter])['exit']!==0&&$this->run(['-S',$filter])['exit']!==0)throw new RuntimeException('Cannot create the firewall security chain.');
            }
            $r=$this->run(['-C','INPUT','-j',$filter]);
            if($r['exit']===0)continue;
            if(!self::missing($r)||$this->run(['-I','INPUT','-j',$filter])['exit']!==0)throw new RuntimeException('Cannot connect the firewall security chain.');
        }
    }
}
