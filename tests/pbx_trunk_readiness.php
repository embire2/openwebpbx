<?php
/** CLI-only, generic fixtures: no PBX service or provider connection is touched. */
if (PHP_SAPI!=='cli') { http_response_code(404);exit; }
require dirname(__DIR__).'/resources/classes/pbx_trunk_readiness.php';
$checks=0;
$assert=static function(bool $ok,string $message)use(&$checks){if(!$ok)throw new RuntimeException($message);$checks++;};
$reject=static function(callable $operation,string $message)use($assert){try{$operation();}catch(InvalidArgumentException){$assert(true,$message);return;}$assert(false,$message);};
class readiness_fixture extends pbx_trunk_readiness {
    public array $addresses=['8.8.8.8'];
    public array $attempts=[];
    public bool $connected=true;
    public array $local=[];
    protected function resolveHost(string $host): array {return $this->addresses;}
    protected function localAddresses(): array {return $this->local;}
    protected function connectAddress(string $address,int $port,string $transport,string $host): bool {$this->attempts[]=[$address,$port,$transport,$host];return $this->connected;}
}
$uuid='1e8835dc-cd63-4a3e-91ea-080635e4a82a';
$trunk=['host'=>'provider.example.invalid','port'=>5060,'transport'=>'udp','register'=>true,'auth_mode'=>'credentials','enabled'=>false,'allowed_ips'=>['198.51.100.10']];
$gateway=['has_username'=>true,'has_password'=>true];
$status=pbx_trunk_readiness::describe($trunk,$gateway,['state'=>'REGED']);
$assert($status['status']==='Off'&&!$status['calls_verified'],'An off trunk appeared connected or call verified');
$trunk['enabled']=true;
$status=pbx_trunk_readiness::describe($trunk,$gateway,['state'=>'REGED']);
$assert($status['status']==='Registered'&&!$status['calls_verified']&&str_contains($status['next_step'],'two-way audio'),'Registration hid carrier verification');
$audioTrunk=$trunk+['codecs'=>['PCMU','PCMA','G729']];
$audioStatus=pbx_trunk_readiness::describe($audioTrunk,$gateway,['state'=>'REGED','g729_transcoding'=>false]);
$assert($audioStatus['status']==='Needs settings'&&$audioStatus['missing_audio_support']&&str_contains($audioStatus['next_step'],'extra server support'),'A passthrough-only G729 installation appeared usable for carrier audio');
$assert(!pbx_trunk_readiness::describe($audioTrunk,$gateway,['state'=>'REGED','g729_transcoding'=>true])['missing_audio_support'],'Installed G729 audio support was ignored');
$assert(!pbx_trunk_readiness::describe($trunk,$gateway,['state'=>'REGED','g729_transcoding'=>false])['missing_audio_support'],'A provider without G729 required that audio component');
$assert(!pbx_trunk_readiness::describe($audioTrunk,$gateway,['state'=>'REGED'])['missing_audio_support'],'An unreadable engine response was misreported as absent audio support');
$trunk['register']=false;$gateway['has_password']=false;
$assert(pbx_trunk_readiness::describe($trunk,$gateway,['state'=>'NOREG'])['missing_credentials'],'Non-registering digest authentication lost credential readiness');
$trunk['auth_mode']='ip';
$assert(pbx_trunk_readiness::describe($trunk,$gateway,['state'=>'NOREG','availability'=>'UP'])['status']==='Configured','IP trunks incorrectly require registration');
$assert(pbx_trunk_readiness::describe($trunk,$gateway,['state'=>'NOREG','availability'=>'DOWN'])['status']==='Connection failed','A down IP trunk appeared connected');
$trunk['type']='BridgeMaster';
$assert(str_contains(implode(' ',pbx_trunk_readiness::describe($trunk,$gateway)['issues']),'replacement connection'),'3CX bridge replacement was omitted');
$xml='<gateway name="'.$uuid.'"><state>REGED</state><status>UP</status><username>private-fixture-identity</username><password>private-fixture-password</password></gateway>';
$runtime=pbx_trunk_readiness::gatewayState($xml,$uuid);
$assert($runtime===['state'=>'REGED','availability'=>'UP'],'Gateway registration state was not parsed');
$assert(!str_contains(json_encode($runtime),'private-fixture'),'A raw engine credential escaped in status');
$assert(pbx_trunk_readiness::gatewayState($xml,'84be6e1b-f87a-45bf-a1e8-497ce8a43c36')['state']==='unknown','A different gateway was used');
$assert(pbx_trunk_readiness::gatewayState('<!DOCTYPE gateway [<!ENTITY secret SYSTEM "file:///etc/passwd">]><gateway><state>&secret;</state></gateway>',$uuid)['state']==='unknown','Unsafe status XML was accepted');
$assert(pbx_trunk_readiness::gatewayState('Invalid Gateway!',$uuid)['state']==='not_loaded','An unloaded gateway was not identified');
$fixture=new readiness_fixture;
$probe=['host'=>'provider.example.invalid','port'=>5060,'transport'=>'udp'];
$result=$fixture->checkProvider($probe);
$assert($result['connection']==='Not checked (UDP)'&&!$fixture->attempts,'A UDP DNS result was treated as a connection');
$fixture->addresses=[];
$assert($fixture->checkProvider($probe)['dns']==='Failed'&&!$fixture->attempts,'Missing DNS opened a connection');
$fixture->addresses=['127.0.0.1','10.0.0.1','::1'];$probe['transport']='tcp';
$assert($fixture->checkProvider($probe)['connection']==='Not checked'&&!$fixture->attempts,'Tenant check opened a private connection');
$fixture->addresses=['127.0.0.1','8.8.8.8'];
$fixture->local=['8.8.8.8'];
$assert($fixture->checkProvider($probe)['connection']==='Not checked'&&!$fixture->attempts,'Tenant check opened the instance public address');
$fixture->local=[];
$assert($fixture->checkProvider($probe)['connection']==='TCP connected'&&$fixture->attempts===[['8.8.8.8',5060,'tcp','provider.example.invalid']],'TCP check used an unvalidated DNS address');
$fixture->attempts=[];$fixture->connected=false;$probe['transport']='tls';$probe['port']=5061;$fixture->addresses=['8.8.8.8','1.1.1.1','9.9.9.9'];
$assert($fixture->checkProvider($probe)['connection']==='Failed'&&count($fixture->attempts)===2,'TLS failure was unbounded or marked verified');
$reject(fn()=>$fixture->checkProvider(['host'=>'https://provider.example.invalid','port'=>5060,'transport'=>'udp']),'A URL instead of a saved SIP host was accepted');
$reject(fn()=>$fixture->checkProvider(['host'=>'provider.example.invalid','port'=>0,'transport'=>'udp']),'An invalid provider port was accepted');
echo 'PASS: '.$checks." readiness, secret-free runtime status, carrier-verification, DNS, private-address protection and bounded transport checks\n";
