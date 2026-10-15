<?php
/** Deterministic DNS-only controls. No network, database, SIP or provider is contacted. */
if(PHP_SAPI!=='cli')exit(2);
require dirname(__DIR__).'/resources/classes/pbx_provider_dns.php';
require dirname(__DIR__).'/resources/classes/pbx_trunk_readiness.php';
$checks=0;$check=static function(bool $ok,string $label)use(&$checks){if(!$ok)throw new RuntimeException($label);$checks++;};
$reject=static function(callable $run,string $label)use($check){try{$run();}catch(InvalidArgumentException|RuntimeException){$check(true,$label);return;}throw new RuntimeException($label);};
class provider_dns_fixture extends pbx_provider_dns {
    public array $records=[],$calls=[];
    protected function lookup(string $name,int $type): array {$this->calls[]=[$name,$type];return $this->records[$name.':'.$type]??[];}
}
$type=DNS_A|DNS_AAAA|DNS_CNAME;
$a=static fn(string $host,string $ip)=>['host'=>$host,'type'=>str_contains($ip,':')?'AAAA':'A',str_contains($ip,':')?'ipv6':'ip'=>$ip];
$srv=static fn(string $host,string $target,int $port=5060)=>['host'=>$host,'type'=>'SRV','target'=>$target,'port'=>$port,'pri'=>0,'weight'=>1];
$dns=new provider_dns_fixture;
foreach(['10.20.30.40','127.0.0.1','8.8.8.8','fd00::123','2001:4860:4860::8888'] as $ip){$check($dns->addresses(['host'=>$ip])===[inet_ntop(inet_pton($ip))],'Literal unicast needs no duplicate input');$check($dns->calls===[],'Literal address caused a DNS request');}
foreach(['0.0.0.0','224.0.0.1','255.255.255.255','::','ff02::1','::ffff:239.1.1.1'] as $ip)$check($dns->addresses(['host'=>$ip])===[],'Non-unicast address accepted');
foreach(['https://provider.invalid','provider.invalid/path','provider.invalid;transport=udp','user@provider.invalid','provider.invalid:0',"provider.invalid\n",'0.0.0.0/0','*.provider.invalid'] as $host)$reject(fn()=>$dns->addresses(['host'=>$host]),'Unsafe endpoint accepted');
$dns->records=['sip.provider.invalid:'.$type=>[$a('sip.provider.invalid','10.20.30.40'),$a('sip.provider.invalid.','2001:DB8::1'),$a('sip.provider.invalid','10.20.30.40'),$a('foreign.invalid','8.8.8.8'),$a('sip.provider.invalid','224.1.2.3')]];
$check($dns->addresses(['host'=>'SIP.PROVIDER.INVALID'])===['10.20.30.40','2001:db8::1'],'A/AAAA ownership, unicast, canonical form or duplicate control failed');
$dns->records=['alias.invalid:'.$type=>[['host'=>'alias.invalid','type'=>'CNAME','target'=>'target.invalid.']], 'target.invalid:'.$type=>[$a('target.invalid','192.168.4.5')]];
$check($dns->addresses(['host'=>'alias.invalid'])===['192.168.4.5'],'Owned CNAME chain failed');
$dns->records['target.invalid:'.$type]=[['host'=>'target.invalid','type'=>'CNAME','target'=>'alias.invalid']];
$check($dns->addresses(['host'=>'alias.invalid'])===[],'CNAME loop did not terminate');
foreach(['udp'=>'_sip._udp.','tcp'=>'_sip._tcp.','tls'=>'_sips._tcp.'] as $transport=>$prefix){
    $service=$prefix.'service.invalid';
    $dns->records=[$service.':'.DNS_SRV=>[$srv($service,'one.invalid.',5070),$srv($service,'two.invalid.',5071)],'one.invalid:'.$type=>[$a('one.invalid','172.16.3.4')],'two.invalid:'.$type=>[$a('two.invalid','2001:db8::5')]];
    $dns->calls=[];$check($dns->addresses(['host'=>'service.invalid','provider_port_auto'=>true,'transport'=>$transport])===['172.16.3.4','2001:db8::5'],'Transport SRV targets were not resolved');
    $check(in_array([$service,DNS_SRV],$dns->calls,true),'Wrong SIP service queried');
    $dns->calls=[];$check($dns->addresses(['host'=>'service.invalid','port'=>5070,'transport'=>$transport])===[],'Explicit numeric port unexpectedly used SRV');
    $check(!array_filter($dns->calls,static fn($v)=>$v[1]===DNS_SRV),'Explicit numeric port caused an SRV request');
}
$dns->records=['server.invalid:'.$type=>[$a('server.invalid','10.1.1.1')], 'out.invalid:'.$type=>[$a('out.invalid','10.1.1.2')], '_sip._udp.out.invalid:'.DNS_SRV=>[$srv('_sip._udp.out.invalid','edge.invalid')], 'edge.invalid:'.$type=>[$a('edge.invalid','10.1.1.3')]];
$check($dns->addresses(['host'=>'server.invalid','outbound_proxy'=>'out.invalid'])===['10.1.1.1','10.1.1.2','10.1.1.3'],'Configured outgoing proxy DNS was omitted');
$check($dns->addresses(['host'=>'server.invalid','outbound_proxy'=>'out.invalid:5070'])===['10.1.1.1','10.1.1.2'],'Explicit proxy port did not suppress SRV');
$check($dns->addresses(['host'=>'server.invalid','register_proxy'=>'[fd00::44]:5061'])===['10.1.1.1','fd00::44'],'Literal registration proxy was omitted');
$dns->records=['unavailable.invalid:'.$type=>[$a('unavailable.invalid','10.2.3.4')], '_sip._udp.unavailable.invalid:'.DNS_SRV=>[$srv('_sip._udp.unavailable.invalid','.')]];
$check($dns->addresses(['host'=>'unavailable.invalid','provider_port_auto'=>true])===[],'Explicit unavailable SIP service fell back to an unrelated A record');
$dns->records=['_sip._udp.service.invalid:'.DNS_SRV=>[$srv('_sip._udp.foreign.invalid','one.invalid'),$srv('_sip._udp.service.invalid','https://bad.invalid'),$srv('_sip._udp.service.invalid','one.invalid',0)],'one.invalid:'.$type=>[$a('one.invalid','10.1.1.1')]];
$check($dns->addresses(['host'=>'service.invalid','provider_port_auto'=>true])===[],'Unowned or malformed SRV answer accepted');
$dns->records=['many.invalid:'.$type=>array_fill(0,65,$a('many.invalid','10.1.1.1'))];$reject(fn()=>$dns->addresses(['host'=>'many.invalid']),'Unbounded records accepted');
$dns->records=['_sip._udp.service.invalid:'.DNS_SRV=>array_map(static fn($n)=>$srv('_sip._udp.service.invalid','node'.$n.'.invalid'),range(1,9))];$reject(fn()=>$dns->addresses(['host'=>'service.invalid','provider_port_auto'=>true]),'Unbounded service targets accepted');
$check(pbx_provider_dns::inputAddresses(['allowed_ips'=>['10.1.1.1','2001:DB8::1']])==='10.1.1.1, 2001:DB8::1','Legacy manual values were normalized or hidden');
$check(pbx_provider_dns::inputAddresses(['allowed_ips'=>['10.1.1.1'],'allowed_ips_source'=>'dns'])==='','Derived addresses became a manual override on the next edit');
class provider_dns_readiness_fixture extends pbx_trunk_readiness {
    public provider_dns_fixture $dns;public array $attempts=[];
    protected function resolveProvider(array $trunk): array {return $this->dns->addresses($trunk);}
    protected function localAddresses(): array {return [];}
    protected function connectAddress(string $address,int $port,string $transport,string $host): bool {$this->attempts[]=[$address,$port,$transport,$host];return true;}
}
$ready=new provider_dns_readiness_fixture;$ready->dns=new provider_dns_fixture;
foreach(['tcp'=>'_sip._tcp.','tls'=>'_sips._tcp.'] as $transport=>$prefix){
    $service=$prefix.'service.invalid';$ready->dns->records=[$service.':'.DNS_SRV=>[$srv($service,'edge.invalid',5075)],'edge.invalid:'.$type=>[$a('edge.invalid','8.8.8.8')]];
    $result=$ready->checkProvider(['host'=>'service.invalid','port'=>$transport==='tls'?5061:5060,'provider_port_auto'=>true,'transport'=>$transport]);
    $check($result['dns']==='Found'&&$result['connection']==='Not checked'&&$ready->attempts===[]&&str_contains($result['message'],'two-way audio'),'SRV service was probed at a guessed port or reported connected');
}
$ready->dns->records=['server.invalid:'.$type=>[$a('server.invalid','8.8.8.8')],'out.invalid:'.$type=>[$a('out.invalid','1.1.1.1')]];
foreach(['register_proxy','outbound_proxy'] as $proxy){$result=$ready->checkProvider(['host'=>'server.invalid','port'=>5061,'transport'=>'tls',$proxy=>'out.invalid:5075']);$check($result['dns']==='Found'&&$result['connection']==='Not checked'&&$ready->attempts===[],'Proxy address was probed with the primary server port or TLS name');}
$result=$ready->checkProvider(['host'=>'server.invalid','port'=>5090,'transport'=>'tls']);
$check($result['connection']==='TLS verified'&&$ready->attempts===[['8.8.8.8',5090,'tls','server.invalid']],'Legacy explicit primary endpoint check changed');
$ready->attempts=[];$ready->dns->records=[];$result=$ready->checkProvider(['host'=>'service.invalid','port'=>5061,'transport'=>'tls','provider_port_auto'=>true]);
$check($result['dns']==='Failed'&&$ready->attempts===[],'Automatic-port DNS failure was concealed');
echo 'PASS '.$checks." exact provider DNS/unicast/SRV/ownership/bounds controls; no network or calling activity\n";
