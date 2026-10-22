<?php
/** QA-only, read-only media negotiation evidence. No SDP, keys, addresses or raw errors leave this script. */
function windows_meet_diagnostic_certificate(string $file): array {
    $row=array_fill_keys(['observed','ordinary_file','certificate_parsed','private_key_parsed','key_matches','current_validity','rsa_at_least_4096','sha256_fingerprint'],false);
    if(!is_file($file))return $row;
    for($parent=$file;;$parent=dirname($parent)){if(is_link($parent))return $row;if($parent===dirname($parent))break;}
    $row['observed']=true;$size=filesize($file);
    if(!is_int($size)||$size<1||$size>65536)return $row;
    $row['ordinary_file']=true;$bytes=file_get_contents($file);
    if(!is_string($bytes))return $row;
    $cert=@openssl_x509_read($bytes);$key=@openssl_pkey_get_private($bytes);
    $row['certificate_parsed']=$cert!==false;$row['private_key_parsed']=$key!==false;
    $row['key_matches']=$cert!==false&&$key!==false&&openssl_x509_check_private_key($cert,$key);
    $details=$key!==false?openssl_pkey_get_details($key):false;
    $row['rsa_at_least_4096']=is_array($details)&&($details['type']??null)===OPENSSL_KEYTYPE_RSA&&is_int($details['bits']??null)&&$details['bits']>=4096;
    $info=$cert!==false?openssl_x509_parse($cert):false;$now=time();
    $row['current_validity']=is_array($info)&&is_int($info['validFrom_time_t']??null)&&is_int($info['validTo_time_t']??null)&&$info['validFrom_time_t']<=$now&&$info['validTo_time_t']>$now;
    $row['sha256_fingerprint']=$cert!==false&&is_string($fingerprint=openssl_x509_fingerprint($cert,'sha256'))&&preg_match('/^[a-f0-9]{64}$/i',$fingerprint)===1;
    while(openssl_error_string()!==false){} // Never export the OpenSSL error queue.
    return $row;
}
function windows_meet_diagnostic_runtime(callable $api): array {
    $modules=['sofia'=>'mod_sofia','conference'=>'mod_conference','hash'=>'mod_hash','vpx'=>'mod_vpx','opus'=>'mod_opus'];
    $row=['schema'=>1,'read_only'=>true,'observed'=>false,'modules'=>array_fill_keys(array_keys($modules),false),'codecs'=>array_fill_keys(['query_valid','pcmu','pcma','vp8','opus'],false),'profile'=>array_fill_keys(['query_valid','loopback_signalling','pcmu','pcma','vp8'],false),'certificate_directory_owned'=>false,'dtls_certificate'=>windows_meet_diagnostic_certificate('')];
    foreach($modules as $name=>$module)$row['modules'][$name]=trim((string)$api('module_exists '.$module))==='true';
    $raw=$api('show codecs as json');
    if(is_string($raw)&&strlen($raw)<=65536){
        $json=json_decode($raw,true,32);
        if(is_array($json)&&isset($json['rows'])&&is_array($json['rows'])&&count($json['rows'])<=512){
            $row['codecs']['query_valid']=true;
            foreach($json['rows']as$codec){if(!is_array($codec)||($codec['type']??'')!=='codec')continue;
                foreach(['pcmu'=>'G.711 ulaw','pcma'=>'G.711 alaw','vp8'=>'VP8 Video','opus'=>'OPUS (Voice)']as$key=>$name)if(($codec['name']??null)===$name)$row['codecs'][$key]=true;
            }
        }
    }
    $profile=$api('sofia status profile openweb-meet');
    if(is_string($profile)&&strlen($profile)<=65536){
        $row['profile']['query_valid']=preg_match('/^Name\s+openweb-meet\s*$/m',$profile)===1;
        $row['profile']['loopback_signalling']=preg_match('/^SIP-IP\s+127\.0\.0\.1\s*$/m',$profile)===1;
        if(preg_match('/^CODECS IN\s+([^\r\n]+)\s*$/m',$profile,$matches)===1){$names=array_map('trim',explode(',',$matches[1]));foreach(['pcmu'=>'PCMU','pcma'=>'PCMA','vp8'=>'VP8']as$key=>$name)$row['profile'][$key]=in_array($name,$names,true);}
    }
    $directory=trim((string)$api('global_getvar certs_dir'));
    if($directory!==''&&strlen($directory)<=1024&&strpos($directory,"\0")===false){
        $actual=realpath($directory);
        if($actual!==false){
            $actual=str_replace('\\','/',$actual);$allowed=['C:/Program Files/FreeSWITCH/',rtrim(str_replace('\\','/',getenv('ProgramData')?:'C:/ProgramData'),'/').'/OpenWebPBX/'];
            foreach($allowed as$root)if(str_starts_with(strtolower(rtrim($actual,'/').'/'),strtolower($root))){$row['certificate_directory_owned']=true;$row['dtls_certificate']=windows_meet_diagnostic_certificate($actual.'/dtls-srtp.pem');break;}
        }
    }
    $row['observed']=$row['modules']['sofia']&&$row['codecs']['query_valid'];return $row;
}
if(realpath($_SERVER['SCRIPT_FILENAME']??'')===__FILE__){
    if(PHP_SAPI!=='cli'||PHP_OS_FAMILY!=='Windows'||$argc!==2||$argv[1]!=='--read-only')exit(2);
    ini_set('display_errors','0');
    try{require 'C:/OpenWebPBX/web/resources/require.php';echo json_encode(windows_meet_diagnostic_runtime(static fn(string $command)=>event_socket::api($command)),JSON_THROW_ON_ERROR),PHP_EOL;}
    catch(Throwable $error){fwrite(STDERR,"Read-only media evidence unavailable.\n");exit(1);}
}
