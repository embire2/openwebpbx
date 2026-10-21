<?php
// Exercise the actual pure origin formatter without a PBX/database mutation.
if(PHP_SAPI!=='cli')exit(2);
require dirname(__DIR__).'/resources/classes/pbx_meet.php';
$formatter=new ReflectionMethod(pbx_meet::class,'websocketUrl');$checks=0;
foreach([
    'https://pbx.example.invalid'=>'wss://pbx.example.invalid/meet-sip/',
    'https://pbx.example.invalid/'=>'wss://pbx.example.invalid/meet-sip/',
    'https://pbx.example.invalid:443'=>'wss://pbx.example.invalid/meet-sip/',
    'https://windowsqa.example.invalid:8443'=>'wss://windowsqa.example.invalid:8443/meet-sip/',
    'https://pbx.example.invalid:9443/'=>'wss://pbx.example.invalid:9443/meet-sip/',
    'https://[::1]:8443'=>'wss://[::1]:8443/meet-sip/',
    'https://[::1]:443'=>'wss://[::1]/meet-sip/',
]as$origin=>$expected){if($formatter->invoke(null,$origin)!==$expected)throw new RuntimeException('Meeting address lost its trusted authority.');$checks++;}
foreach(['http://pbx.example.invalid','ftp://pbx.example.invalid','https:///','https://user@pbx.example.invalid','https://user:password@pbx.example.invalid','https://pbx.example.invalid?next=foreign','https://pbx.example.invalid#foreign','not-an-origin']as$origin){$refused=false;try{$formatter->invoke(null,$origin);}catch(RuntimeException$e){$refused=true;}if(!$refused)throw new RuntimeException('An unsuitable meeting origin was accepted.');$checks++;}
echo json_encode(['checks'=>$checks,'trusted_origin_ports_preserved'=>true,'database_mutations'=>0],JSON_THROW_ON_ERROR),PHP_EOL;
