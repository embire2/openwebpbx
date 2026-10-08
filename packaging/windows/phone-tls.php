<?php
/** Private, administrator-invoked Windows phone certificate and listener setup. */
if (PHP_SAPI !== 'cli') { http_response_code(404); exit; }
set_exception_handler(static function (Throwable $error): void { fwrite(STDERR, "Phone TLS setup did not complete. Review the private server configuration.\n"); exit(1); });
[$script, $web, $inputFile, $stage] = $argv + ['', '', '', ''];
require $web.'/resources/require.php';
$input = json_decode(file_get_contents($inputFile), true, 512, JSON_THROW_ON_ERROR);
$db = $database->db;
$db->setAttribute(PDO::ATTR_ERRMODE, PDO::ERRMODE_EXCEPTION);
$names = ['tls','tls-only','tls-sip-port','tls-cert-dir','tls-version','tls-bind-params','inbound-reg-force-matching-username'];
$profile = $db->query("select sip_profile_uuid from v_sip_profiles where sip_profile_name='internal'")->fetchColumn();
if (!$profile) { throw new RuntimeException('Native phone profile missing.'); }
$query = static function (string $sql, array $values = []) use ($db): PDOStatement { $statement=$db->prepare($sql);$statement->execute($values);return $statement; };
$configuration = $input['configuration'];
$setReady = static function (bool $ready) use ($configuration): void {
    $text=file_get_contents($configuration);
    $text=preg_replace('/^openweb\.mobile_tls_ready\s*=.*\R?/m','',$text);
    if(file_put_contents($configuration,rtrim($text)."\r\nopenweb.mobile_tls_ready = ".($ready?'true':'false')."\r\n")===false)throw new RuntimeException('Private configuration update failed.');
};
if ($stage === 'idle') {
    $status=json_decode(event_socket::api('show channels as json'),true);
    if (!isset($status['row_count']) || (int)$status['row_count']!==0) throw new RuntimeException('Finish active calls before configuring phone TLS.');
    $profileStatus=event_socket::api('sofia status profile internal');
    if(!preg_match('/^SIP-IP\s+([^\s]+)\s*$/m',$profileStatus,$address)||!filter_var($address[1],FILTER_VALIDATE_IP,FILTER_FLAG_IPV4))throw new RuntimeException('The native phone listener address is unavailable.');
    file_put_contents($inputFile.'.bind',$address[1]==='0.0.0.0'?'127.0.0.1':$address[1]);
    echo "Call engine is idle.\n";exit;
}
if ($stage === 'ready') { $setReady(true);echo "Phone TLS readiness recorded.\n";exit; }
if ($stage === 'apply') {
    $certificates=[];
    if(!openssl_pkcs12_read(file_get_contents($input['pfx']),$certificates,$input['password']))throw new RuntimeException('Certificate could not be opened.');
    if(!openssl_x509_check_private_key($certificates['cert'],$certificates['pkey']))throw new RuntimeException('Certificate key mismatch.');
    require_once __DIR__.'/phone-tls-chain.php';
    $chain=openweb_phone_tls_chain($certificates['cert'],$input['chain']);
    foreach(['agent.pem'=>$certificates['pkey']."\n".$chain,'cafile.pem'=>$chain] as $name=>$contents){
        if(file_put_contents($input['directory'].'/'.$name,$contents)===false)throw new RuntimeException('Private certificate could not be saved.');
    }
    $previous=$query('select * from v_sip_profile_settings where sip_profile_uuid=? and sip_profile_setting_name in ('.implode(',',array_fill(0,count($names),'?')).')',[$profile,...$names])->fetchAll(PDO::FETCH_ASSOC);
    file_put_contents($input['previous'],json_encode($previous,JSON_THROW_ON_ERROR));
    $settings=['tls'=>'true','tls-only'=>'false','tls-sip-port'=>'5061','tls-cert-dir'=>str_replace('\\','/',$input['directory']),'tls-version'=>'tlsv1.2','tls-bind-params'=>'transport=tls','inbound-reg-force-matching-username'=>'true'];
    $db->beginTransaction();
    try {
        foreach($settings as $name=>$value){
            $query('delete from v_sip_profile_settings where sip_profile_uuid=? and sip_profile_setting_name=?',[$profile,$name]);
            $query('insert into v_sip_profile_settings(sip_profile_setting_uuid,sip_profile_uuid,sip_profile_setting_name,sip_profile_setting_value,sip_profile_setting_enabled) values(?,?,?,?,true)',[uuid(),$profile,$name,$value]);
        }
        $db->commit();
    }catch(Throwable $e){$db->rollBack();throw $e;}
    $setReady(false);
} elseif ($stage === 'rollback') {
    $previous=json_decode(file_get_contents($input['previous']),true,512,JSON_THROW_ON_ERROR);
    $db->beginTransaction();try{
        $query('delete from v_sip_profile_settings where sip_profile_uuid=? and sip_profile_setting_name in ('.implode(',',array_fill(0,count($names),'?')).')',[$profile,...$names]);
        foreach($previous as $row){
            $columns=array_keys($row);
            $query('insert into v_sip_profile_settings('.implode(',',$columns).') values('.implode(',',array_fill(0,count($columns),'?')).')',array_values($row));
        }
        $db->commit();
    }catch(Throwable $e){$db->rollBack();throw $e;}
} else { throw new InvalidArgumentException('Choose a phone TLS setup stage.'); }
settings::clear_cache();
$cache=new cache();$cache->delete('configuration:sofia.conf');$cache->delete(gethostname().':configuration:sofia.conf');
echo "Native phone listener configuration updated.\n";
