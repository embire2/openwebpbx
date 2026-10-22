<?php
// SPDX-License-Identifier: AGPL-3.0-or-later
// No PBX/bootstrap/database access: private PEM bytes never leave this process.
ini_set('display_errors', '0');
function openweb_dtls_inspect(string $path): array {
    if (!file_exists($path)) return ['schema'=>1, 'state'=>'missing'];
    if (!is_file($path) || is_link($path) || filesize($path)>65536) throw new RuntimeException('Invalid certificate file.');
    $pem=file_get_contents($path);
    $cert=@openssl_x509_read($pem); $key=@openssl_pkey_get_private($pem);
    if (!$cert || !$key || !openssl_x509_check_private_key($cert,$key)) return ['schema'=>1,'state'=>'foreign_invalid'];
    $details=openssl_pkey_get_details($key); $parsed=openssl_x509_parse($cert);
    if (!$details || !$parsed || $details['type']!==OPENSSL_KEYTYPE_RSA || $details['bits']<4096) return ['schema'=>1,'state'=>'foreign_invalid'];
    $before=$parsed['validFrom_time_t']??null; $after=$parsed['validTo_time_t']??null;
    if (!is_int($before) || !is_int($after)) return ['schema'=>1,'state'=>'foreign_invalid'];
    if ($before<=time() && $after>time()) return ['schema'=>1,'state'=>'valid'];
    // Exact official Windows 36500-day generator overflow; unrelated/custom
    // expired certificates require administrator review and remain byte-exact.
    $stock=($parsed['subject']??null)===['C'=>'US','CN'=>'FreeSWITCH']
        && ($parsed['issuer']??null)===($parsed['subject']??null)
        && ($parsed['serialNumberHex']??null)==='0'
        && ($after-$before)===-1140762496
        && openssl_x509_verify($cert,openssl_pkey_get_public($cert))===1;
    return ['schema'=>1,'state'=>$stock?'stock_overflow':'foreign_invalid'];
}
function openweb_dtls_generate(string $path,string $config): void {
    if (file_exists($path) || !is_file($config) || is_link($config)) throw new RuntimeException('Invalid generation destination.');
    $options=['config'=>$config,'private_key_type'=>OPENSSL_KEYTYPE_RSA,'private_key_bits'=>4096,'digest_alg'=>'sha256'];
    $key=openssl_pkey_new($options);
    $request=$key?openssl_csr_new(['C'=>'ZA','O'=>'OpenWeb PBX','CN'=>'OpenWebPBX DTLS'],$key,$options):false;
    $cert=$request?openssl_csr_sign($request,null,$key,3650,$options,random_int(1,2147483647)):false;
    if (!$cert || !openssl_pkey_export($key,$private,null,$options) || !openssl_x509_export($cert,$public)) throw new RuntimeException('Certificate generation failed.');
    $stream=fopen($path,'xb'); if (!$stream) throw new RuntimeException('Certificate staging failed.');
    try { $pem=$private.$public; if (fwrite($stream,$pem)!==strlen($pem) || !fflush($stream) || (function_exists('fsync') && !fsync($stream))) throw new RuntimeException('Certificate staging failed.'); }
    finally { fclose($stream); }
    if (openweb_dtls_inspect($path)['state']!=='valid') throw new RuntimeException('Generated certificate did not validate.');
}
if (realpath($_SERVER['SCRIPT_FILENAME']??'')===__FILE__) {
    try {
        if (PHP_SAPI!=='cli' || !in_array($argv[1]??'', ['inspect','generate'],true) || !isset($argv[2])) throw new RuntimeException('Invalid invocation.');
        if ($argv[1]==='generate') { if (!isset($argv[3])) throw new RuntimeException('Missing private configuration.'); openweb_dtls_generate($argv[2],$argv[3]); }
        echo json_encode(openweb_dtls_inspect($argv[2]),JSON_THROW_ON_ERROR).PHP_EOL;
    } catch (Throwable $error) { fwrite(STDERR,"The private DTLS certificate operation failed.\n"); exit(1); }
}
