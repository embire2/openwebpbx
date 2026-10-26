<?php
/** Actual bootstrap defaults with explicit configuration/account adapters; no DB or SIP. */
if(PHP_SAPI!=='cli')exit;
class config {public static mixed $stun=null;static function load(){return new self;}function get($key,$default=''){return $key==='openweb.mobile_stun_server'?(self::$stun??$default):$default;}}
class pbx_paths {static function host(){return 'sip.example.invalid';}}
class pbx_mobile_push {function __construct($db){}function client(){return ['enabled'=>false];}}
class pbx_video {static function ready(){return false;}}
require getenv('OPENWEB_MOBILE_TEST_SOURCE')?:dirname(__DIR__).'/resources/classes/pbx_mobile.php';
final class unused_fixture_database extends PDO {public function __construct(){}}
final class network_fixture_mobile extends pbx_mobile {
    public function __construct(){parent::__construct(new unused_fixture_database);}
    public function appPasswordAvailable(): bool {return false;}
    protected function accountIdentity(array $e): array {return ['extension'=>'1000'];}
}
$mobile=new network_fixture_mobile;$count=0;
$check=function($ok,$why)use(&$count){if(!$ok)throw new RuntimeException($why);$count++;};
$e=['sip_username'=>'owm-fictional','device_uuid'=>'fictional-device','domain_name'=>'preserved.realm'];
$a=$mobile->bootstrap($e);$expected=['schema'=>1,'media'=>'pbx','stun_enabled'=>true,'stun_server'=>'openweb.sip.openwebpbx.com:3478','ice_enabled'=>false,'turn_enabled'=>false,'upnp_enabled'=>false];
$check($a['network']===$expected,'Safe PBX/STUN defaults missing');
$sip=$a['sip'];$check($sip===['server'=>'sip.example.invalid','domain'=>'preserved.realm','username'=>'owm-fictional','auth_username'=>'owm-fictional','port'=>5061,'transport'=>'tls','media_encryption'=>'srtp'],'Existing SIP tuple changed');
foreach(['STUN.EXAMPLE.ORG'=>'stun.example.org:3478','stun.example.org:3479'=>'stun.example.org:3479','192.0.2.10:3478'=>'192.0.2.10:3478']as$input=>$endpoint){config::$stun=$input;$b=$mobile->bootstrap($e);$check($b['network']===array_replace($expected,['stun_server'=>$endpoint]),'Configured STUN normalization failed');$check($b['sip']===$sip,'STUN changed phone credentials or address');}
foreach(['https://evil.test','user:password@evil.test','evil.test/path','evil.test?secret=x','evil.test:0','evil.test:65536',"evil.test\r\n",'999.999.999.999','evil.test.','[::1]:3478',[],42]as$input){config::$stun=$input;$check($mobile->bootstrap($e)['network']===$expected,'Invalid setting broke safe calling defaults');}
config::$stun=null;$windows=$mobile->bootstrap($e+['platform'=>'windows']);$check(!array_key_exists('network',$windows),'Windows protocol changed');$check($windows['sip']===$sip,'Windows SIP credentials changed');
echo json_encode(['schema'=>1,'checks'=>$count,'actual_bootstrap'=>true,'controlled_config_and_account_adapters'=>true,'database_or_SIP_used'=>false],JSON_THROW_ON_ERROR)."\n";
