<?php
// Actual OpenSSL cryptography and exact overflow-shape refusal controls.
require dirname(__DIR__).'/packaging/windows/configure-dtls.php';
$directory=$argv[1]??(sys_get_temp_dir().'/openweb-dtls-'.bin2hex(random_bytes(8)));
if (file_exists($directory)) throw new RuntimeException('Use an absent owned fixture directory.');
mkdir($directory,0700,true);$checks=0;
function dtls_check(bool $value): void {global $checks;if(!$value)throw new RuntimeException('The DTLS certificate control failed.');$checks++;}
function dtls_tlv(string $der,int &$offset): array {
    $tag=ord($der[$offset++]);$length=ord($der[$offset++]);
    if($length&128){$count=$length&127;$length=0;while($count--)$length=($length<<8)|ord($der[$offset++]);}
    $body=substr($der,$offset,$length);$offset+=$length;return [$tag,$body];
}
function dtls_encode(int $tag,string $body): string {
    $length=strlen($body);$size=$length<128?chr($length):'';
    if($length>=128){$n=$length;while($n){$size=chr($n&255).$size;$n>>=8;}$size=chr(128|strlen($size)).$size;}
    return chr($tag).$size.$body;
}
function dtls_children(string $body): array {$offset=0;$result=[];while($offset<strlen($body))$result[]=dtls_tlv($body,$offset);return $result;}
function dtls_rewrite(string $pem,string $before,string $after): string {
    preg_match('/-----BEGIN CERTIFICATE-----\s*(.*?)-----END CERTIFICATE-----/s',$pem,$match);
    $der=base64_decode(preg_replace('/\s+/','',$match[1]),true);$offset=0;$outer=dtls_tlv($der,$offset);$parts=dtls_children($outer[1]);$tbs=dtls_children($parts[0][1]);
    $validity=$tbs[0][0]===160?4:3;
    $tbs[$validity]=[48,dtls_encode(23,$before).dtls_encode(23,$after)];
    $body='';foreach($tbs as [$tag,$value])$body.=dtls_encode($tag,$value);$body=dtls_encode(48,$body);
    if(!openssl_sign($body,$signature,openssl_pkey_get_private($pem),OPENSSL_ALGO_SHA256))throw new RuntimeException('Fixture signing failed.');
    $certificate=dtls_encode(48,$body.dtls_encode(...$parts[1]).dtls_encode(3,"\0".$signature));
    preg_match('/-----BEGIN (?:RSA )?PRIVATE KEY-----.*?-----END (?:RSA )?PRIVATE KEY-----/s',$pem,$private);
    return $private[0]."\n-----BEGIN CERTIFICATE-----\n".chunk_split(base64_encode($certificate),64,"\n")."-----END CERTIFICATE-----\n";
}
try {
    $config=$directory.'/generate.cnf';file_put_contents($config,"[req]\ndistinguished_name=dn\n[dn]\n");
    $valid=$directory.'/valid.pem';dtls_check(openweb_dtls_inspect($valid)['state']==='missing');
    openweb_dtls_generate($valid,$config);dtls_check(openweb_dtls_inspect($valid)['state']==='valid');
    $pem=file_get_contents($valid);$cert=openssl_x509_parse($pem);$key=openssl_pkey_get_details(openssl_pkey_get_private($pem));
    dtls_check($key['bits']===4096);dtls_check($cert['signatureTypeSN']==='RSA-SHA256');
    dtls_check($cert['validTo_time_t']-$cert['validFrom_time_t']===3650*86400);
    dtls_check(openssl_x509_check_private_key($pem,openssl_pkey_get_private($pem)));
    $hash=hash_file('sha256',$valid);$failed=false;try{openweb_dtls_generate($valid,$config);}catch(Throwable $e){$failed=true;}dtls_check($failed&&hash_file('sha256',$valid)===$hash);
    $key=openssl_pkey_get_private($pem);$options=['config'=>$config,'digest_alg'=>'sha256'];
    $request=openssl_csr_new(['C'=>'US','CN'=>'FreeSWITCH'],$key,$options);
    $stockCert=openssl_csr_sign($request,null,$key,3650,$options,0);openssl_x509_export($stockCert,$stockPublic);openssl_pkey_export($key,$private,null,$options);
    $stock=$directory.'/stock.pem';file_put_contents($stock,dtls_rewrite($private.$stockPublic,'260930213744Z','900807150928Z'));
    dtls_check(openweb_dtls_inspect($stock)['state']==='stock_overflow');
    $custom=$directory.'/custom.pem';file_put_contents($custom,dtls_rewrite($pem,'260930213744Z','900807150928Z'));dtls_check(openweb_dtls_inspect($custom)['state']==='foreign_invalid');
    $expired=$directory.'/expired.pem';file_put_contents($expired,dtls_rewrite($private.$stockPublic,'200101000000Z','210101000000Z'));dtls_check(openweb_dtls_inspect($expired)['state']==='foreign_invalid');
    $adjacent=$directory.'/adjacent.pem';file_put_contents($adjacent,dtls_rewrite($private.$stockPublic,'260930213744Z','900807150929Z'));dtls_check(openweb_dtls_inspect($adjacent)['state']==='foreign_invalid');
    $malformed=$directory.'/malformed.pem';file_put_contents($malformed,'not a certificate');dtls_check(openweb_dtls_inspect($malformed)['state']==='foreign_invalid');
    echo json_encode(['schema'=>1,'state'=>'passed','checks'=>$checks,'actual_openssl'=>true,'directory'=>$directory],JSON_THROW_ON_ERROR).PHP_EOL;
} catch(Throwable $error) {fwrite(STDERR,"The DTLS certificate controls failed.\n");exit(1);}
