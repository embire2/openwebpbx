<?php
/** SPDX-License-Identifier: AGPL-3.0-or-later. Synthetic upload/call fixture only. */
function windows_threecx_https_require(bool $condition): void {
    if (!$condition) throw new RuntimeException('Synthetic HTTPS import invariant refused.');
}
function windows_threecx_https_inventory(string $directory): array {
    if (!file_exists($directory)) return [];
    windows_threecx_https_require(is_dir($directory) && !is_link($directory));
    $out=[];
    foreach (new DirectoryIterator($directory) as $entry) {
        if ($entry->isDot()) continue;
        windows_threecx_https_require($entry->isFile() && !$entry->isLink() && $entry->getSize()<=1048576 && count($out)<16);
        $out[$entry->getFilename()]=hash_file('sha256',$entry->getPathname());
    }
    ksort($out);return $out;
}
function windows_threecx_https_foreign_identity(array $s,array $intent): void {
    $fields=['schema','realm','aor','auth','address','port','contact','call_id','tag'];$keys=array_keys($intent);sort($fields);sort($keys);
    windows_threecx_https_require($keys===$fields && ($intent['schema']??null)===1 && preg_match('/^[a-f0-9]{24}$/D',$s['scope']??'')===1);
    windows_threecx_https_require($intent['realm']==='foreign-'.$s['scope'].'.example.invalid' && $intent['aor']==='9100' && $intent['auth']==='source-login-9100');
    windows_threecx_https_require(is_string($intent['address']) && filter_var($intent['address'],FILTER_VALIDATE_IP,FILTER_FLAG_IPV4)!==false && is_int($intent['port']) && $intent['port']>=1 && $intent['port']<=65535);
    windows_threecx_https_require($intent['contact']==='sip:9100@'.$intent['address'].':'.$intent['port'].';transport=udp' && is_string($intent['call_id']) && preg_match('/^[a-f0-9]{32}@fictional$/D',$intent['call_id'])===1 && is_string($intent['tag']) && preg_match('/^[a-f0-9]{24}$/D',$intent['tag'])===1);
}
function windows_threecx_https_foreign_file(array $s): string {
    $directory=str_replace('\\','/',$s['evidence_directory']??'');
    windows_threecx_https_require(is_dir($directory) && !is_link($directory) && basename($directory)==='evidence' && basename(dirname($directory))===($s['scope']??null));
    return $directory.'/threecx-foreign-registration.json';
}
function windows_threecx_https_foreign_prepare(array $s,array $intent,callable $api): void {
    windows_threecx_https_foreign_identity($s,$intent);$file=windows_threecx_https_foreign_file($s);
    windows_threecx_https_require(!file_exists($file) && !is_link($file));
    $profile=$api('sofia status profile internal');
    windows_threecx_https_require(is_string($profile) && strlen($profile)<=65536 && preg_match('/^\s*SIP-IP\s+([0-9.]+)\s*$/m',$profile,$match)===1 && $match[1]===$intent['address']);
    // Exclusive protected evidence file; complete bytes and fsync must finish
    // before the caller is permitted to send even its first REGISTER.
    $bytes=json_encode($intent,JSON_THROW_ON_ERROR);windows_threecx_https_require(strlen($bytes)<=2048);
    $stream=fopen($file,'xb');windows_threecx_https_require(is_resource($stream));
    try{windows_threecx_https_require(fwrite($stream,$bytes)===strlen($bytes) && fflush($stream) && fsync($stream));}finally{fclose($stream);}
    windows_threecx_https_require(hash_file('sha256',$file)===hash('sha256',$bytes));
}
function windows_threecx_https_foreign_absence(array $s,callable $api): void {
    $file=windows_threecx_https_foreign_file($s);
    if(!file_exists($file) && !is_link($file)){windows_threecx_https_require(!isset($s['foreign_registration_intent']));return;} // The first REGISTER was never permitted.
    windows_threecx_https_require(is_file($file) && !is_link($file) && filesize($file)>0 && filesize($file)<=2048);
    $intent=json_decode(file_get_contents($file),true,16,JSON_THROW_ON_ERROR);windows_threecx_https_foreign_identity($s,$intent);
    if(isset($s['foreign_registration_intent']))windows_threecx_https_require($s['foreign_registration_intent']===$intent);
    $raw=$api('show registrations as json');windows_threecx_https_require(is_string($raw) && strlen($raw)<=65536);
    $registrations=json_decode($raw,true,32,JSON_THROW_ON_ERROR);
    windows_threecx_https_require(is_array($registrations) && is_int($registrations['row_count']??null) && $registrations['row_count']>=0 && $registrations['row_count']<=16);
    $rows=$registrations['rows']??[];windows_threecx_https_require(is_array($rows) && array_is_list($rows) && count($rows)===$registrations['row_count']);
    $endpoint='@'.preg_quote($intent['address'], '~').':'.$intent['port'].'(?=[;>/?]|$)';
    foreach($rows as $row){
        windows_threecx_https_require(is_array($row) && is_string($row['reg_user']??null) && is_string($row['realm']??null) && is_string($row['url']??null) && strlen($row['url'])<=8192);
        // A failed realm guard might canonicalize to the imported domain. The
        // exact attempted socket endpoint must also be absent in every row.
        windows_threecx_https_require($row['realm']!==$intent['realm'] && preg_match('~'.$endpoint.'~D',$row['url'])!==1);
    }
    foreach([$intent['auth'],$intent['aor']] as $user){$reply=$api('sofia_contact '.$user.'@'.$intent['realm']);windows_threecx_https_require(is_string($reply) && strlen($reply)<=8192 && str_starts_with(trim($reply),'error/'));}
}
function windows_threecx_https_uploads(array &$s,callable $save,bool $cleanup=false): void {
    if (!isset($s['import_fixture'])) return;
    $i=&$s['import_fixture'];$directory=pbx_paths::uploads();
    $current=windows_threecx_https_inventory($directory);$before=$i['uploads_before'];
    foreach ($before as $name=>$hash) windows_threecx_https_require(($current[$name]??null)===$hash);
    $new=array_diff_key($current,$before);
    windows_threecx_https_require(count($new)<=1);
    foreach ($new as $name=>$hash) {
        windows_threecx_https_require(preg_match('/^[a-f0-9]{8}(?:-[a-f0-9]{4}){3}-[a-f0-9]{12}\.zip$/D',$name)===1 && hash_equals($i['archive_sha256'],$hash));
        if (isset($i['uploaded_name'])) windows_threecx_https_require($i['uploaded_name']===$name);
        $i['uploaded_name']=$name;$save(); // Durable identity before any removal.
        if ($cleanup) windows_threecx_https_require(unlink($directory.'/'.$name));
    }
    if ($cleanup) {
        windows_threecx_https_require(windows_threecx_https_inventory($directory)===$before);
        if (!$i['uploads_existed'] && is_dir($directory)) windows_threecx_https_require(rmdir($directory));
        $s['import_upload_cleanup']=true;$save();
    }
}
function windows_threecx_https_before(string $action,array &$s,callable $q,callable $save,callable $factory,string $argument=''): void {
    windows_threecx_https_require(($s['threecx_import_only']??null)===true && ($s['native_diagnostics_only']??null)===true && empty($s['hold_diagnostics_only']));
    if ($action==='import-archive') {
        $factory();windows_threecx_https_require(!isset($s['import_fixture']) && $s['drafts_before']===[]);
        $directory=str_replace('\\','/',$s['evidence_directory']);
        windows_threecx_https_require(basename($directory)==='evidence' && basename(dirname($directory))===$s['scope'] && !is_link($directory));
        $uploads=pbx_paths::uploads();
        windows_threecx_https_require(!file_exists($uploads) || is_dir($uploads) && !is_link($uploads) && count(array_diff(scandir($uploads),['.','..']))===0);
        $before=windows_threecx_https_inventory($uploads);
        // Empty factory: refuse unrelated upload content instead of reading customer backups.
        windows_threecx_https_require($before===[]);
        require_once __DIR__.'/windows_threecx_fixture.php';$fixture=windows_threecx_fixture($directory);
        $s['import_fixture']=['archive'=>$fixture['archive'],'archive_sha256'=>hash_file('sha256',$fixture['archive']),
            'users'=>$fixture['users'],'media'=>array_map(static fn($bytes)=>hash('sha256',$bytes),$fixture['media']),
            'uploads_before'=>$before,'uploads_existed'=>is_dir($uploads)];
        $save();echo "{\"synthetic_archive_ready\":true}\n";exit;
    }
    if ($action==='import-empty') {
        $factory();windows_threecx_https_require(isset($s['import_fixture']) && windows_threecx_https_inventory(pbx_paths::uploads())===$s['import_fixture']['uploads_before']);
        $drafts=$q('select draft_uuid from v_pbx_setup_drafts')->fetchAll(PDO::FETCH_COLUMN);
        sort($drafts);$before=$s['drafts_before'];sort($before);windows_threecx_https_require($drafts===$before);
        echo "{\"no_upload_or_draft_created\":true}\n";exit;
    }
    if ($action==='import-upload') {
        windows_threecx_https_require(isset($s['import_fixture']));windows_threecx_https_uploads($s,$save);
        windows_threecx_https_require(isset($s['import_fixture']['uploaded_name']));
        $rows=$q("select draft_uuid,kind,completed_domain_uuid,payload_ciphertext is not null as has_payload from v_pbx_setup_drafts where user_uuid=?",[$s['factory_admin']['user_uuid']])->fetchAll(PDO::FETCH_ASSOC);
        $rows=array_values(array_filter($rows,static fn($row)=>!in_array($row['draft_uuid'],$s['drafts_before'],true)));
        windows_threecx_https_require(count($rows)===1 && $rows[0]['kind']==='import' && $rows[0]['completed_domain_uuid']===null && $rows[0]['has_payload']===true);
        $s['import_fixture']['draft_uuid']=$rows[0]['draft_uuid'];$save();
        echo "{\"uploaded_archive_exact\":true,\"owned_draft\":true}\n";exit;
    }
    if ($action==='import-foreign-intent') {
        windows_threecx_https_require(isset($s['users'],$s['import_fixture']['draft_uuid']) && strlen($argument)<=2048);
        $intent=json_decode($argument,true,16,JSON_THROW_ON_ERROR);
        windows_threecx_https_foreign_prepare($s,$intent,static fn(string $command):string=>(string)event_socket::api($command));
        $s['foreign_registration_intent']=$intent;$save();
        echo "{\"foreign_registration_intent_saved\":true}\n";exit;
    }
    if ($action==='cleanup') {
        windows_threecx_https_foreign_absence($s,static fn(string $command):string=>(string)event_socket::api($command));
        windows_threecx_https_uploads($s,$save,true);
    }
}
function windows_threecx_https_discover(array &$s,array $c,string $domain,string $realm,callable $q,callable $save): void {
    windows_threecx_https_require(isset($s['import_fixture']['draft_uuid']));$i=$s['import_fixture'];
    $draft=$q('select user_uuid,kind,completed_domain_uuid,payload_ciphertext from v_pbx_setup_drafts where draft_uuid=?',[$i['draft_uuid']])->fetch(PDO::FETCH_ASSOC);
    windows_threecx_https_require($draft && $draft['user_uuid']===$s['factory_admin']['user_uuid'] && $draft['kind']==='import' && $draft['completed_domain_uuid']===$domain && $draft['payload_ciphertext']===null);
    windows_threecx_https_require(count($c['users'])===2);
    $users=[];
    foreach ($i['users'] as $index=>$u) {
        $row=$q('select extension_uuid,extension,password,accountcode,user_context,effective_caller_id_number from v_extensions where domain_uuid=? and extension=?',[$domain,$u['auth']])->fetch(PDO::FETCH_ASSOC);
        windows_threecx_https_require($row && hash_equals($u['password'],$row['password']) && $row['extension']===$u['auth'] && $row['effective_caller_id_number']===$u['number'] && $row['accountcode']===$realm && $row['user_context']===$realm && ($c['users'][$u['number']]['auth_id']??null)===$u['auth']);
        $users[]=$u+['extension_uuid'=>$row['extension_uuid'],'domain_uuid'=>$domain,'tone_hz'=>440+$index*110];
    }
    windows_threecx_https_require((int)$q('select count(*) from v_extensions where domain_uuid=?',[$domain])->fetchColumn()===2);
    $tuples=$q('select extension_uuid,extension,password from v_extensions where domain_uuid=? order by extension_uuid',[$domain])->fetchAll(PDO::FETCH_ASSOC);
    if (isset($s['original_phone_tuples'])) windows_threecx_https_require($s['original_phone_tuples']===$tuples);
    windows_threecx_https_require((int)$q('select count(*) from v_gateways where domain_uuid=?',[$domain])->fetchColumn()===1 && (int)$q("select count(*) from v_gateways where domain_uuid=? and enabled='true'",[$domain])->fetchColumn()===0);
    windows_threecx_https_require((int)$q("select count(*) from v_destinations where domain_uuid=? and destination_enabled='true'",[$domain])->fetchColumn()===0);
    windows_threecx_https_require(count($c['ring_groups'])===1 && $c['ring_groups'][0]['number']==='9180' && array_column($c['ring_groups'][0]['members'],'number')===['9101','9100']);
    $line=$q('select user_id,auth_id,password,server_address from v_device_lines where domain_uuid=?',[$domain])->fetchAll(PDO::FETCH_ASSOC);
    windows_threecx_https_require(count($line)===1 && $line[0]['user_id']==='9100' && $line[0]['auth_id']===$users[0]['auth'] && hash_equals($users[0]['password'],$line[0]['password']) && $line[0]['server_address']===$realm);
    $media=$q('select source_path,file_path from v_pbx_media where domain_uuid=?',[$domain])->fetchAll(PDO::FETCH_ASSOC);
    windows_threecx_https_require(count($media)===count($i['media']));
    $expected=array_keys($i['media']);sort($expected);$sources=[];$destinations=[];
    windows_threecx_https_require(!is_link(pbx_paths::media().'/'.$domain) && !is_link(pbx_paths::voicemail().'/default/'.$realm));
    foreach($media as $m){
        windows_threecx_https_require(is_string($m['source_path']??null) && is_string($m['file_path']??null) && strlen($m['source_path'])<=1024 && strlen($m['file_path'])<=4096 && isset($i['media'][$m['source_path']]));
        $sources[]=$m['source_path'];$actual=realpath($m['file_path']);
        windows_threecx_https_require($actual!==false && is_file($m['file_path']) && !is_link($m['file_path']) && filesize($m['file_path'])>0 && filesize($m['file_path'])<=1048576);
        $actual=str_replace('\\','/',$actual);$mediaRoot=str_replace('\\','/',(string)realpath(pbx_paths::media().'/'.$domain));$voicemailRoot=str_replace('\\','/',(string)realpath(pbx_paths::voicemail().'/default/'.$realm));
        windows_threecx_https_require(($mediaRoot!=='' && pbx_paths::contains($mediaRoot,$actual)) || ($voicemailRoot!=='' && pbx_paths::contains($voicemailRoot,$actual)));
        $destinations[]=PHP_OS_FAMILY==='Windows'?strtolower($actual):$actual;
    }
    sort($sources);windows_threecx_https_require($sources===$expected && count(array_unique($destinations,SORT_STRING))===count($media));
    foreach($media as $m)windows_threecx_https_require(hash_file('sha256',$m['file_path'])===$i['media'][$m['source_path']]);
    $custom=$c['users']['9100']['greetings'][0]['id']??'';
    windows_threecx_https_require(preg_match('/^[0-9]{1,9}$/D',$custom)===1);
    $greeting=pbx_paths::voicemail().'/default/'.$realm.'/9100/greeting_'.$custom.'.wav';
    windows_threecx_https_require(is_file($greeting) && !is_link($greeting) && filesize($greeting)<=1048576 && pbx_paths::contains(pbx_paths::voicemail().'/default/'.$realm,(string)realpath($greeting)) && hash_file('sha256',$greeting)===$i['media']['vmailprompts/9100/custom greeting.wav']);
    $s['users']=$users;$s['realm']=$realm;$s['domain']=$domain;$s['original_phone_tuples']=$tuples;$save();
    echo "{\"original_credentials_exact\":true,\"phone_line_exact\":true,\"restored_media_exact\":true,\"provider_disabled\":true,\"owned_draft_completed\":true}\n";
}
