<?php
/** Private, administrator-invoked Windows phone certificate and listener setup. */
if (PHP_SAPI !== 'cli') { http_response_code(404); exit; }
function openweb_phone_tls_failure_record(Throwable $error, string $inputFile, string $stage, string $programData): bool {
    try {
        $root=realpath(rtrim($programData,'/\\').'/OpenWebPBX/backups');
        $input=realpath($inputFile);
        if($root===false||$input===false||is_link($inputFile)||!is_file($inputFile)||basename($input)!=='request.json')return false;
        $root=rtrim(str_replace('\\','/',$root),'/');$input=str_replace('\\','/',$input);$directory=dirname($input);
        if(!str_starts_with(strtolower($directory),strtolower($root).'/')||dirname(strtolower($directory))!==strtolower($root)||!preg_match('/^phone-tls-[0-9]{8}-[0-9]{6}-[a-f0-9]{8}$/D',basename($directory)))return false;
        $type=basename(str_replace('\\','/',get_class($error)));if(!preg_match('/^[A-Za-z0-9_]{1,80}$/D',$type))$type='Throwable';
        $source=basename(str_replace('\\','/',$error->getFile()));
        if(!in_array($source,['phone-tls.php','phone-tls-chain.php','pbx_phone_auth.php','pbx_sip_domain.php','event_socket.php','config.php','database.php'],true))$source='external_component';
        $stage=in_array($stage,['idle','bind','resume','ready','apply','rollback'],true)?$stage:'initialization';
        $line=$error->getLine();if($line<1||$line>100000)$line=1;
        $bytes=json_encode(['schema'=>1,'error_type'=>$type,'source_basename'=>$source,'source_line'=>$line,'stage'=>$stage],JSON_THROW_ON_ERROR);
        if(strlen($bytes)>2048)return false;
        // Keep the first failure even when a subsequent recovery step fails.
        $stream=@fopen($input.'.failure.json','xb');if($stream===false)return false;
        try{return fwrite($stream,$bytes)===strlen($bytes)&&fflush($stream);}finally{fclose($stream);}
    }catch(Throwable $ignored){return false;}
}
set_exception_handler(static function (Throwable $error): void {
    global $argv;
    openweb_phone_tls_failure_record($error,(string)($argv[2]??''),(string)($argv[3]??''),(string)(getenv('ProgramData')?:'C:/ProgramData'));
    fwrite(STDERR, "Phone TLS setup did not complete. Review the private server configuration.\n");exit(1);
});
[$script, $web, $inputFile, $stage] = $argv + ['', '', '', ''];
require $web.'/resources/require.php';
$input = json_decode(file_get_contents($inputFile), true, 512, JSON_THROW_ON_ERROR);
$db = $database->db;
$db->setAttribute(PDO::ATTR_ERRMODE, PDO::ERRMODE_EXCEPTION);
$names = ['tls','tls-only','tls-sip-port','tls-cert-dir','tls-version','tls-bind-params','inbound-reg-force-matching-username','ext-sip-ip','ext-rtp-ip'];
$profile = $db->query("select sip_profile_uuid from v_sip_profiles where sip_profile_name='internal'")->fetchColumn();
if (!$profile) { throw new RuntimeException('Native phone profile missing.'); }
$query = static function (string $sql, array $values = []) use ($db): PDOStatement {
    $statement=$db->prepare($sql);
    foreach($values as $index=>$value){
        $type=match(true){is_bool($value)=>PDO::PARAM_BOOL,$value===null=>PDO::PARAM_NULL,is_int($value)=>PDO::PARAM_INT,default=>PDO::PARAM_STR};
        $statement->bindValue($index+1,$value,$type);
    }
    $statement->execute();return $statement;
};
$configuration = $input['configuration'];
$setReady = static function (bool $ready) use ($configuration): void {
    $text=file_get_contents($configuration);
    $text=preg_replace('/^openweb\.mobile_tls_ready\s*=.*\R?/m','',$text);
    if(file_put_contents($configuration,rtrim($text)."\r\nopenweb.mobile_tls_ready = ".($ready?'true':'false')."\r\n")===false)throw new RuntimeException('Private configuration update failed.');
};
if ($stage === 'idle' || $stage==='bind') {
    if($stage==='idle'){
        if(trim(event_socket::api('fsctl pause_check'))!=='false'){fwrite(STDERR,"Finish existing call maintenance before configuring phone TLS.\n");exit(75);}
        if(!str_starts_with(event_socket::api('fsctl pause'),'+OK'))throw new RuntimeException('The call engine could not enter certificate maintenance.');
        file_put_contents($inputFile.'.paused','1');
        try{
            foreach(['show channels as json','show calls as json'] as $command){
                $status=json_decode(event_socket::api($command),true);
                if (!isset($status['row_count'])) throw new RuntimeException('The call engine did not return a usable call count.');
                if ((int)$status['row_count']!==0) { event_socket::api('fsctl resume');unlink($inputFile.'.paused');fwrite(STDERR,"Finish active calls before configuring phone TLS.\n"); exit(75); }
            }
        }catch(Throwable $error){event_socket::api('fsctl resume');@unlink($inputFile.'.paused');throw $error;}
    }
    $profileStatus=event_socket::api('sofia status profile internal');
    if(!preg_match('/^SIP-IP\s+([^\s]+)\s*$/m',$profileStatus,$address)||!filter_var($address[1],FILTER_VALIDATE_IP,FILTER_FLAG_IPV4))throw new RuntimeException('The native phone listener address is unavailable.');
    file_put_contents($inputFile.'.bind',$address[1]==='0.0.0.0'?'127.0.0.1':$address[1]);
    echo "Call engine is idle.\n";exit;
}
if($stage==='resume'){
    if(is_file($inputFile.'.paused')){
        if(!str_starts_with(event_socket::api('fsctl resume'),'+OK'))throw new RuntimeException('The call engine could not leave certificate maintenance.');
        unlink($inputFile.'.paused');
    }
    echo "Certificate maintenance released.\n";exit;
}
if ($stage === 'ready') { $setReady(true);echo "Phone TLS readiness recorded.\n";exit; }
if ($stage === 'apply') {
    pbx_phone_auth::requireWindowsNative();
    if(!pbx_phone_auth::guarded((string)config::load()->get('switch.scripts.dir')))throw new RuntimeException('Install the guarded phone directory before enabling secure phones.');
    $certificates=[];
    if(!openssl_pkcs12_read(file_get_contents($input['pfx']),$certificates,$input['password']))throw new RuntimeException('Certificate could not be opened.');
    if(!openssl_x509_check_private_key($certificates['cert'],$certificates['pkey']))throw new RuntimeException('Certificate key mismatch.');
    require_once __DIR__.'/phone-tls-chain.php';
    $chain=openweb_phone_tls_chain($certificates['cert'],$input['chain']);
    $leaf=openssl_x509_parse($certificates['cert']);$certificateNames=[];
    foreach(explode(',',(string)($leaf['extensions']['subjectAltName']??'')) as $name){
        if(preg_match('/^DNS:((?:\*\.)?[a-zA-Z0-9.-]+)$/D',trim($name),$match))$certificateNames[]=strtolower($match[1]);
    }
    if(!$certificateNames)throw new RuntimeException('The phone certificate has no usable DNS names.');
    if(!pbx_sip_domain::certificateCovers((string)($input['hostname']??''),$certificateNames))throw new RuntimeException('The phone certificate does not cover this server name.');
    $text=file_get_contents($configuration);
    $text=preg_replace('/^openweb\.sip_tls_names\s*=.*\R?/m','',$text);
    if(file_put_contents($configuration,rtrim($text)."\r\nopenweb.sip_tls_names = ".implode(',',$certificateNames)."\r\n")===false)throw new RuntimeException('Certificate names could not be recorded.');
    foreach(['agent.pem'=>$certificates['pkey']."\n".$chain,'cafile.pem'=>$chain] as $name=>$contents){
        if(file_put_contents($input['directory'].'/'.$name,$contents)===false)throw new RuntimeException('Private certificate could not be saved.');
    }
    $settings=['tls'=>'true','tls-only'=>'false','tls-sip-port'=>'5061','tls-cert-dir'=>str_replace('\\','/',$input['directory']),'tls-version'=>'tlsv1.2','tls-bind-params'=>'transport=tls','inbound-reg-force-matching-username'=>'false'];
    $address=(string)config::load()->get('openweb.public_ip','');
    if($address!==''){
        if(!filter_var($address,FILTER_VALIDATE_IP,FILTER_FLAG_IPV4))throw new RuntimeException('Set a valid public IPv4 address before configuring remote phones.');
        $settings['ext-sip-ip']=$address;$settings['ext-rtp-ip']=$address;
    }
    $profiles=[$profile=>['names'=>$names,'settings'=>$settings]];
    if($address!==''){
        foreach($query("select sip_profile_uuid from v_sip_profiles where sip_profile_name='external' and sip_profile_enabled=true")->fetchAll(PDO::FETCH_COLUMN) as $external){
            $profiles[$external]=['names'=>['ext-sip-ip','ext-rtp-ip'],'settings'=>['ext-sip-ip'=>$address,'ext-rtp-ip'=>$address]];
        }
    }
    $previous=['schema'=>2,'profiles'=>[]];
    foreach($profiles as $id=>$choice){
        $previous['profiles'][$id]=['names'=>$choice['names'],'rows'=>$query('select * from v_sip_profile_settings where sip_profile_uuid=? and sip_profile_setting_name in ('.implode(',',array_fill(0,count($choice['names']),'?')).')',[$id,...$choice['names']])->fetchAll(PDO::FETCH_ASSOC)];
    }
    if(file_put_contents($input['previous'],json_encode($previous,JSON_THROW_ON_ERROR))===false)throw new RuntimeException('The profile recovery inventory could not be saved.');
    $db->beginTransaction();
    try {
        foreach($profiles as $id=>$choice)foreach($choice['settings'] as $name=>$value){
            $query('delete from v_sip_profile_settings where sip_profile_uuid=? and sip_profile_setting_name=?',[$id,$name]);
            $query('insert into v_sip_profile_settings(sip_profile_setting_uuid,sip_profile_uuid,sip_profile_setting_name,sip_profile_setting_value,sip_profile_setting_enabled) values(?,?,?,?,true)',[uuid(),$id,$name,$value]);
        }
        $db->commit();
    }catch(Throwable $e){$db->rollBack();throw $e;}
    $setReady(false);
} elseif ($stage === 'rollback') {
    $previous=json_decode(file_get_contents($input['previous']),true,512,JSON_THROW_ON_ERROR);
    $profiles=($previous['schema']??0)===2?$previous['profiles']:[$profile=>['names'=>$names,'rows'=>$previous]];
    $db->beginTransaction();try{
        foreach($profiles as $id=>$choice){
        $query('delete from v_sip_profile_settings where sip_profile_uuid=? and sip_profile_setting_name in ('.implode(',',array_fill(0,count($choice['names']),'?')).')',[$id,...$choice['names']]);
        foreach($choice['rows'] as $row){
            $columns=array_keys($row);
            $query('insert into v_sip_profile_settings('.implode(',',$columns).') values('.implode(',',array_fill(0,count($columns),'?')).')',array_values($row));
        }
        }
        $db->commit();
    }catch(Throwable $e){$db->rollBack();throw $e;}
} else { throw new InvalidArgumentException('Choose a phone TLS setup stage.'); }
settings::clear_cache();
$cache=new cache();$cache->delete('configuration:sofia.conf');$cache->delete(gethostname().':configuration:sofia.conf');
echo "Native phone listener configuration updated.\n";
