<?php
// Actual PHP/OpenSSL and read-only command classifier, using fictional files.
require __DIR__.'/windows_meet_native_diagnostics.php';
$checks=0;
function check(bool $value): void {global $checks;if(!$value)throw new RuntimeException('Native media diagnostic control failed at '.debug_backtrace(DEBUG_BACKTRACE_IGNORE_ARGS,1)[0]['line']);$checks++;}
$private=sys_get_temp_dir().'/openweb-meet-diag-'.bin2hex(random_bytes(10));mkdir($private,0700);
try{
    $missing=windows_meet_diagnostic_certificate($private.'/missing.pem');check(count($missing)===8&&count(array_filter($missing))===0);
    file_put_contents($private.'/invalid.pem','PRIVATE_CERTIFICATE_SECRET');$invalid=windows_meet_diagnostic_certificate($private.'/invalid.pem');check($invalid['observed']&&$invalid['ordinary_file']&&!$invalid['certificate_parsed']&&!$invalid['private_key_parsed']);
    file_put_contents($private.'/oversize.pem',str_repeat('x',65537));$oversize=windows_meet_diagnostic_certificate($private.'/oversize.pem');check($oversize['observed']&&!$oversize['ordinary_file']);
    $keys=[];$certs=[];
    foreach([2048,4096]as$bits){
        $key=openssl_pkey_new(['private_key_type'=>OPENSSL_KEYTYPE_RSA,'private_key_bits'=>$bits]);check($key!==false);
        $request=openssl_csr_new(['commonName'=>'Fictional private diagnostic'],$key,['digest_alg'=>'sha256']);$cert=openssl_csr_sign($request,null,$key,2,['digest_alg'=>'sha256']);check($cert!==false);
        openssl_pkey_export($key,$privateKey);openssl_x509_export($cert,$certificate);$keys[$bits]=$privateKey;$certs[$bits]=$certificate;
        $path=$private.'/'.$bits.'.pem';file_put_contents($path,$privateKey.$certificate);$row=windows_meet_diagnostic_certificate($path);
        check($row['observed']&&$row['ordinary_file']&&$row['certificate_parsed']&&$row['private_key_parsed']&&$row['key_matches']&&$row['current_validity']&&$row['sha256_fingerprint']);check($row['rsa_at_least_4096']===($bits===4096));
        foreach($row as$value)check(is_bool($value));
        check(!str_contains(json_encode($row),'BEGIN')&&!str_contains(json_encode($row),'Fictional'));
    }
    file_put_contents($private.'/mismatch.pem',$keys[2048].$certs[4096]);$mismatch=windows_meet_diagnostic_certificate($private.'/mismatch.pem');check($mismatch['certificate_parsed']&&$mismatch['private_key_parsed']&&!$mismatch['key_matches']);
    if(PHP_OS_FAMILY!=='Windows'){symlink($private.'/4096.pem',$private.'/linked.pem');check(!windows_meet_diagnostic_certificate($private.'/linked.pem')['observed']);}
    $commands=[];$replies=[
        'show codecs as json'=>json_encode(['rows'=>array_map(static fn($name)=>['type'=>'codec','name'=>$name,'private'=>'PRIVATE_RUNTIME_SECRET'],['G.711 ulaw','G.711 alaw','VP8 Video','OPUS (Voice)'])]),
        'sofia status profile openweb-meet'=>"Name\topenweb-meet\nSIP-IP\t127.0.0.1\nCODECS IN\tPCMU,PCMA,VP8\nPRIVATE_RUNTIME_SECRET\n",
        'global_getvar certs_dir'=>$private,
    ];
    $api=static function(string $command)use(&$commands,&$replies){$commands[]=$command;return $replies[$command]??'true';};
    $report=windows_meet_diagnostic_runtime($api);check($report['observed']&&$report['read_only']);
    foreach(['pcmu','pcma','vp8','opus']as$key)check($report['codecs'][$key]);
    foreach($report['profile']as$value)check($value===true);
    check(!$report['certificate_directory_owned']&&!$report['dtls_certificate']['observed']);
    check($commands===['module_exists mod_sofia','module_exists mod_conference','module_exists mod_hash','module_exists mod_vpx','module_exists mod_opus','show codecs as json','sofia status profile openweb-meet','global_getvar certs_dir']);
    check(!str_contains(json_encode($report),'PRIVATE')&&!str_contains(json_encode($report),$private));
    foreach(['[]','{"rows":false}','PRIVATE_RUNTIME_SECRET',str_repeat('x',65537)]as$bad){$replies['show codecs as json']=$bad;$report=windows_meet_diagnostic_runtime($api);check(!$report['observed']&&!$report['codecs']['query_valid']);check(!str_contains(json_encode($report),'PRIVATE'));}
    $replies['sofia status profile openweb-meet']="Name\tforeign\nSIP-IP\t192.0.2.5\nCODECS IN\tG729,H264\n";$report=windows_meet_diagnostic_runtime($api);foreach($report['profile']as$value)check($value===false);
    echo json_encode(['state'=>'passed','checks'=>$checks,'actual_php_openssl'=>true,'native_windows_runtime'=>false],JSON_THROW_ON_ERROR),PHP_EOL;
}finally{foreach(scandir($private)as$name)if($name!=='.'&&$name!=='..')unlink($private.'/'.$name);rmdir($private);}
