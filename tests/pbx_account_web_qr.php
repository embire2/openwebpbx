<?php
/** Web-key QR routing; native password-generation sessions are a separate authority. */
if(PHP_SAPI!=='cli')exit(2);
class pbx_api_access_denied extends DomainException {}
class pbx_staff_denied extends RuntimeException {}
class pbx_staff_access {
    public function __construct(?PDO $db=null) {}
    public function active(): bool {return $GLOBALS['active'];}
    public function ownNumber(): string {return $GLOBALS['number'];}
}
class pbx_mobile {
    public static array $codes=['100'=>'original-private-100','101'=>'original-private-101'];
    public function __construct(?PDO $db=null) {}
    public function adminExtension(string $number): array {
        if(!$GLOBALS['active']||$number!==$GLOBALS['number'])throw new pbx_staff_denied;
        // A web staff binding deliberately has no native app password generation.
        return ['number'=>$number,'domain_uuid'=>$_SESSION['domain_uuid'],'extension_uuid'=>'bound-'.$number];
    }
    public function createCode(string $number): array {
        $this->adminExtension($number);
        return ['payload'=>self::$codes[$number],'expires_at'=>null,'enrollment_uuid'=>'enrollment-'.$number];
    }
    public function resetCode(string $number): array {
        $this->adminExtension($number);self::$codes[$number].='-explicit-reset';return $this->createCode($number);
    }
    public function personalCode(array $e): never {throw new UnexpectedValueException('Native app password generation required.');}
    public function personalResetCode(array $e): never {throw new UnexpectedValueException('Native app password generation required.');}
}
require dirname(__DIR__).'/resources/classes/pbx_account_api.php';
class web_qr_unused_pdo extends PDO {public function __construct() {}}
$db=new web_qr_unused_pdo;$checks=0;
$ok=static function($value,string $why)use(&$checks){if(!$value)throw new RuntimeException($why);$checks++;};
$deny=static function(callable $run,string $why)use($ok){try{$run();}catch(pbx_api_access_denied|pbx_staff_denied|InvalidArgumentException){$ok(true,$why);return;}$ok(false,$why);};
$_SESSION=['authorized'=>true,'user_uuid'=>'web-user','domain_uuid'=>'own-pbx'];$GLOBALS['active']=true;$GLOBALS['number']='100';
$key=['owner_user_uuid'=>'web-user','domain_uuid'=>'own-pbx','scopes'=>['me:credentials','me:write']];
$api=new pbx_account_api($db,$key);$original=pbx_mobile::$codes;
$qr=$api->handle('POST','/me/phone-qr',[]);$ok($qr['payload']===$original['100']&&$qr['expires_at']===null,'A web key reads its bound QR without an app-password generation.');
$ok($qr===$api->handle('POST','/me/phone-qr',[]),'Repeated web reads preserve the full stable identity.');
foreach(['domain_uuid','extension_uuid','owner_user_uuid','user_uuid']as$field)$deny(fn()=>$api->handle('POST','/me/phone-qr',[$field=>'foreign']),'Caller identity must never select another phone.');
$deny(fn()=>$api->handle('POST','/me/phone-qr-reset',[]),'Reset must be explicitly confirmed.');
$deny(fn()=>$api->handle('POST','/me/phone-qr-reset',['confirmed'=>'true']),'Reset confirmation must be a boolean.');
$read=new pbx_account_api($db,array_replace($key,['scopes'=>['me:credentials']]));
$deny(fn()=>$read->handle('POST','/me/phone-qr-reset',['confirmed'=>true]),'Reset requires write permission.');
$nocredentials=new pbx_account_api($db,array_replace($key,['scopes'=>['me:write']]));
$deny(fn()=>$nocredentials->handle('POST','/me/phone-qr',[]),'Reading QR requires credential permission.');
$ok(pbx_mobile::$codes===$original,'Rejected resets preserve every QR.');
$reset=$api->handle('POST','/me/phone-qr-reset',['confirmed'=>true]);
$ok($reset['payload']!==$qr['payload'],'Explicitly authorized reset replaces the bound QR.');
$ok(pbx_mobile::$codes['101']===$original['101'],'Reset cannot alter the other phone.');
$ok($reset===$api->handle('POST','/me/phone-qr',[]),'The replacement becomes the next stable identity.');
$GLOBALS['active']=false;$deny(fn()=>$api->handle('POST','/me/phone-qr',[]),'Withdrawn roles cannot read QR.');
$deny(fn()=>$api->handle('POST','/me/phone-qr-reset',['confirmed'=>true]),'Withdrawn roles cannot reset QR.');
$GLOBALS['active']=true;
foreach(['domain_uuid'=>'foreign-pbx','owner_user_uuid'=>'foreign-user']as$field=>$value){$foreign=new pbx_account_api($db,array_replace($key,[$field=>$value]));$deny(fn()=>$foreign->handle('POST','/me/phone-qr',[]),'A foreign key binding cannot read QR.');}
echo 'PASS '.$checks." web-key QR identity, confirmation, scope and withdrawal controls. Native QR encryption and live staff authorization have separate integration coverage.\n";
