<?php
/** QA-only actions, called only after the existing native fixture's tenant/admin guards. */
function windows_voicemail_delete_fixture(string $action,PDO $db,array &$s,array $c,string $domain,string $realm,string $input,callable $q,callable $save,string $probe=''): array {
    if(!in_array($action,['voicemail-delete-prepare','voicemail-delete-status'],true)||!is_uuid($domain)||($s['owned']['domain_uuid']??'')!==$domain||($s['realm']??'')!==$realm||!preg_match('/^[a-f0-9]{24}$/D',$s['scope']??''))throw new RuntimeException('Owned native voicemail fixture required.');
    if(!in_array($probe,['','settled','drain','baseline','restored'],true))throw new RuntimeException('Choose the owned consumer probe.');
    if(in_array($probe,['baseline','restored'],true)){
        if($action!=='voicemail-delete-status')throw new RuntimeException('Choose the owned settings check.');
        $settings=['mode'=>$c['users']['8103']['voicemail_email']??null,'mailbox'=>$q("select voicemail_uuid,voicemail_enabled,voicemail_file,voicemail_local_after_email,voicemail_mail_to from v_voicemails where domain_uuid=? and voicemail_id='8103'",[$domain])->fetch(PDO::FETCH_ASSOC),'smtp'=>$q("select * from v_default_settings where default_setting_category='email' order by default_setting_uuid")->fetchAll(PDO::FETCH_ASSOC)];
        if($probe==='baseline'){
            $box=$settings['mailbox'];if(isset($s['delete_mail_settings'])||$settings['mode']!=='Attachment'||!$box||!is_uuid($box['voicemail_uuid'])||!in_array($box['voicemail_local_after_email'],[true,'true','t',1,'1'],true)||$box['voicemail_file']!=='attach'||$box['voicemail_mail_to']!=='sink@example.invalid')throw new RuntimeException('The actual owned keep-local baseline is required.');
            $s['delete_mail_settings']=$settings;$save();return ['schema'=>1,'settings_snapshot_owned'=>true];
        }
        if(!isset($s['delete_mail_settings'])||$settings!==$s['delete_mail_settings'])throw new RuntimeException('The actual original mailbox and global SMTP settings were not restored.');
        return ['schema'=>1,'mode_and_smtp_restored'=>true];
    }
    $released=false;
    if($probe!==''){
        $owned=$s['delete_mail']??null;
        if($owned===null&&$probe==='drain')return ['schema'=>1,'consumer_released'=>true];
        foreach(['message','queue','attachment']as$key)if(!is_uuid($owned[$key]??''))throw new RuntimeException('The owned probe identity is unavailable.');
        $key='openwebpbx-mail:'.$owned['queue'];$released=$q('select pg_try_advisory_lock(hashtextextended(?,0))',[$key])->fetchColumn()===true;
        if($released&&$q('select pg_advisory_unlock(hashtextextended(?,0))',[$key])->fetchColumn()!==true)throw new RuntimeException('The owned consumer probe did not release.');
        if($probe==='drain'){
            $queued=$q('select email_uuid,email_status from v_email_queue where email_queue_uuid=? and domain_uuid=?',[$owned['queue'],$domain])->fetch(PDO::FETCH_ASSOC);
            if($queued&&$queued['email_uuid']!==$owned['message'])throw new RuntimeException('The owned drain target changed.');
            return ['schema'=>1,'consumer_released'=>$released&&(!$queued||$queued['email_status']==='sent')];
        }
    }
    $mailbox=$q("select * from v_voicemails where domain_uuid=? and voicemail_id='8103'",[$domain])->fetch(PDO::FETCH_ASSOC);
    if(!$mailbox||!is_uuid($mailbox['voicemail_uuid'])||($c['users']['8103']['voicemail_email']??'')!=='AttachmentAndDelete'||!in_array($mailbox['voicemail_local_after_email'],[false,'false','f',0,'0'],true)||$mailbox['voicemail_file']!=='attach'||$mailbox['voicemail_mail_to']!=='sink@example.invalid')throw new RuntimeException('Actual owned Attach and Delete option is required.');
    $directory=pbx_paths::voicemail().'/default/'.$realm.'/8103';
    if(!is_dir($directory)||is_link($directory))throw new RuntimeException('The owned recording directory is unavailable.');
    if($action==='voicemail-delete-prepare'){
        if(isset($s['delete_mail']))throw new RuntimeException('The owned delete fixture is already occupied.');
        $source=$q('select * from v_voicemail_messages where domain_uuid=? and voicemail_uuid=? order by created_epoch limit 1',[$domain,$mailbox['voicemail_uuid']])->fetch(PDO::FETCH_ASSOC);
        if(!$source||!is_uuid($source['voicemail_message_uuid']))throw new RuntimeException('The actual native recording is required.');
        $original=$directory.'/msg_'.$source['voicemail_message_uuid'].'.wav';
        if(!is_file($original)||is_link($original)||!pbx_paths::contains($directory,$original)||filesize($original)<=4096||filesize($original)>33554432)throw new RuntimeException('The original native WAV is unavailable.');
        $bytes=file_get_contents($original);if(!is_string($bytes)||substr($bytes,0,4)!=='RIFF'||substr($bytes,8,4)!=='WAVE')throw new RuntimeException('Native WAV bytes are required.');
        $message=uuid();$queue=uuid();$attachment=uuid();$file=$directory.'/msg_'.$message.'.wav';
        $s['delete_mail']=['message'=>$message,'source_message'=>$source['voicemail_message_uuid'],'queue'=>$queue,'attachment'=>$attachment,'sha256'=>hash('sha256',$bytes),'bytes'=>strlen($bytes)];$save();
        $handle=fopen($file,'xb');if(!$handle)throw new RuntimeException('A fresh owned recording is required.');
        try{if(fwrite($handle,$bytes)!==strlen($bytes)||!fflush($handle))throw new RuntimeException('The owned recording copy failed.');}finally{fclose($handle);}
        $source['voicemail_message_uuid']=$message;$keys=array_keys($source);foreach($keys as$key)if(!preg_match('/^[a-z_]+$/D',$key))throw new RuntimeException('The recording schema needs review.');
        $q('insert into v_voicemail_messages('.implode(',',$keys).') values('.implode(',',array_fill(0,count($keys),'?')).')',array_values($source));
        $scriptDir=trim((string)event_socket::api('global_getvar script_dir'));$installed=rtrim(str_replace('\\','/',$scriptDir),'/').'/resources/functions/voicemail_mail_queue.lua';
        $reviewed=rtrim(str_replace('\\','/',$s['source_root']),'/').'/app/switch/resources/scripts/resources/functions/voicemail_mail_queue.lua';
        if(!is_file($installed)||is_link($installed)||!is_file($reviewed)||hash_file('sha256',$installed)!==hash_file('sha256',$reviewed))throw new RuntimeException('The actual installed atomic voicemail helper differs.');
        $producer=dirname($input).'/delete-mail-'.$queue.'.private.json';
        $data=['tag'=>'openweb-native-windows-voicemail-delete-v1','scope'=>$s['scope'],'domain'=>$domain,'realm'=>$realm,'service_name'=>$s['service_name'],'mailbox'=>$mailbox['voicemail_uuid'],'message'=>$message,'queue'=>$queue,'attachment'=>$attachment,'audio'=>$file,'hostname'=>gethostname(),'helper'=>$installed];
        $raw=json_encode($data,JSON_THROW_ON_ERROR);$handle=fopen($producer,'xb');if(!$handle)throw new RuntimeException('A new producer input is required.');try{if(fwrite($handle,$raw)!==strlen($raw)||!fflush($handle))throw new RuntimeException('Producer input could not be retained.');}finally{fclose($handle);}
        $script=rtrim(str_replace('\\','/',$s['source_root']),'/').'/tests/windows_voicemail_delete_producer.lua';
        // The native Lua API splits the script filename at its first space;
        // the hosted checkout path is fixed and must not need filename quoting.
        if(preg_match('/[\x00\r\n"\s]/',$script)||preg_match('/[\x00\r\n"\s]/',$producer))throw new RuntimeException('The owned producer path is invalid.');
        $result=json_decode(trim((string)event_socket::api('lua '.$script.' '.$producer)),true,16,JSON_THROW_ON_ERROR);
        $expected=['schema'=>1,'state'=>'queued','actual_native_dbh'=>true,'installed_atomic_helper'=>true];if(!is_array($result))throw new RuntimeException('Actual native atomic enqueue did not complete.');ksort($result);ksort($expected);
        if($result!==$expected)throw new RuntimeException('Actual native atomic enqueue did not complete.');
    }
    $owned=$s['delete_mail']??null;foreach(['message','source_message','queue','attachment']as$key)if(!is_uuid($owned[$key]??''))throw new RuntimeException('The owned message identity is unavailable.');
    $file=$directory.'/msg_'.$owned['message'].'.wav';
    $rows=$q('select * from v_email_queue_attachments where email_queue_uuid=? and domain_uuid=?',[$owned['queue'],$domain])->fetchAll(PDO::FETCH_ASSOC);
    if(count($rows)!==1||$rows[0]['email_queue_attachment_uuid']!==$owned['attachment'])throw new RuntimeException('The owned attachment changed.');
    $row=$q('select email_uuid,email_status,email_action_before,email_action_after,email_retry_count from v_email_queue where email_queue_uuid=? and domain_uuid=?',[$owned['queue'],$domain])->fetch(PDO::FETCH_ASSOC);
    if(!$row||$row['email_uuid']!==$owned['message']||$row['email_action_before']!=='voicemail-attachment-v1'||$row['email_action_after']!=='delete')throw new RuntimeException('The owned queued message changed.');
    $encoded=$rows[0]['email_attachment_base64'];$decoded=is_string($encoded)?base64_decode($encoded,true):false;
    clearstatcache(true,$file);$exists=is_file($file)&&!is_link($file);
    $original=$directory.'/msg_'.$owned['source_message'].'.wav';clearstatcache(true,$original);
    $preserved=is_file($original)&&!is_link($original)&&hash_file('sha256',$original)===$owned['sha256']&&(int)$q('select count(*) from v_voicemail_messages where domain_uuid=? and voicemail_message_uuid=?',[$domain,$owned['source_message']])->fetchColumn()===1;
    return ['schema'=>1,'message_exists'=>(int)$q('select count(*) from v_voicemail_messages where domain_uuid=? and voicemail_message_uuid=?',[$domain,$owned['message']])->fetchColumn()===1,'file_exists'=>$exists,'file_exact'=>$exists&&hash_file('sha256',$file)===$owned['sha256'],'snapshot_exact'=>is_string($decoded)&&strlen($decoded)===$owned['bytes']&&hash('sha256',$decoded)===$owned['sha256'],'snapshot_cleared'=>$encoded===null,'queue_state'=>$row['email_status'],'actual_admin_delete_option'=>true,'actual_native_atomic_producer'=>true,'original_recording_preserved'=>$preserved,'consumer_released'=>$released,'expected_sha256'=>$owned['sha256']];
}
