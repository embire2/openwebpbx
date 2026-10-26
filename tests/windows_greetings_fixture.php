<?php
/** Disposable-native QA only, after the original tenant and administrator guards. */
function windows_greetings_native_snapshot(PDO $db,string $domain,string $exclude): array {
    $result=[];
    foreach(['v_pbx_greetings'=>'greeting_uuid','v_pbx_media'=>'media_uuid','v_recordings'=>'recording_uuid'] as $table=>$key){
        $sql="select * from $table where $key<>? order by $key limit 129";
        $p=$db->prepare($sql);$p->execute([$exclude]);$rows=$p->fetchAll(PDO::FETCH_ASSOC);
        if(count($rows)>128)throw new RuntimeException('A bounded empty-factory greeting inventory is required.');
        $result[$table]=$rows;
    }
    $uses=$db->query('select * from v_pbx_greeting_uses order by domain_uuid,kind,target_number limit 129')->fetchAll(PDO::FETCH_ASSOC);
    if(count($uses)>128)throw new RuntimeException('A bounded greeting assignment inventory is required.');
    $result['v_pbx_greeting_uses']=$uses;
    return $result;
}
function windows_greetings_native_ordinary(string $path): void {
    for($item=$path;$item!==''&&$item!=='.';$item=dirname($item)){
        if(is_link($item))throw new RuntimeException('Redirected greeting storage is refused.');
        if(dirname($item)===$item)break;
    }
}
function windows_greetings_native_fixture(string $action,PDO $db,array &$s,string $domain,string $realm,callable $q,callable $save): array {
    if(!in_array($action,['greetings-paths','greetings-prepare','greetings-arm','greetings-status','greetings-cleanup'],true)||($s['owned']['domain_uuid']??null)!==$domain||($s['realm']??null)!==$realm||!is_uuid($domain)||!preg_match('/^[a-f0-9]{24}$/D',$s['scope']??''))throw new RuntimeException('Owned greeting qualification required.');
    $base=pbx_paths::greetings();
    if($action==='greetings-paths')return ['schema'=>1,'default_greeting_root'=>$base];
    if($action==='greetings-prepare'){
        if(isset($s['greeting_native']))throw new RuntimeException('The greeting fixture is already occupied.');
        $scripts=rtrim(str_replace('\\','/',trim((string)event_socket::api('global_getvar script_dir'))),'/');
        $bindings=[];
        foreach(['call.lua','recording.lua'] as $leaf){
            $relative='app/pbx_setup/resources/switch/scripts/app/pbx_greetings/'.$leaf;
            $installed=$scripts.'/app/pbx_greetings/'.$leaf;$web='C:/OpenWebPBX/web/'.$relative;$source=rtrim(str_replace('\\','/',$s['source_root']),'/').'/'.$relative;
            foreach([$installed,$web,$source] as $file){windows_greetings_native_ordinary($file);if(!is_file($file)||filesize($file)<1)throw new RuntimeException('The actual installed greeting Lua is missing.');}
            $sha=hash_file('sha256',$source);if(!is_string($sha)||!preg_match('/^[a-f0-9]{64}$/D',$sha)||hash_file('sha256',$installed)!==$sha||hash_file('sha256',$web)!==$sha)throw new RuntimeException('The actual installed greeting Lua differs.');
            $bindings[$leaf]=$sha;
        }
        $id=uuid();$canary=uuid();$other=$s['owned']['home_domain_uuid']??'';
        if(!is_uuid($other)||$other===$domain||!$q('select 1 from v_domains where domain_uuid=?',[$other])->fetchColumn())throw new RuntimeException('A distinct owned tenant-home canary is required.');
        $root=$base.'/'.$domain.'/greetings/'.$id;$custom=$base.'/'.$other.'/greetings/'.$canary;
        $parents=[];foreach([$base,$base.'/'.$domain,$base.'/'.$domain.'/greetings',$base.'/'.$other,$base.'/'.$other.'/greetings'] as $parent){windows_greetings_native_ordinary($parent);$parents[$parent]=is_dir($parent);}
        if(file_exists($root)||file_exists($custom))throw new RuntimeException('Fresh greeting names are required.');
        // Seed cancelled first. No worker may originate until the phone and observer are ready.
        $s['greeting_native']=['id'=>$id,'canary'=>$canary,'other'=>$other,'root'=>$root,'custom'=>$custom,'parents'=>$parents,'bindings'=>$bindings,'recording_uuid'=>null];$save();
        foreach([$root,$custom] as $directory)if(!mkdir($directory,0770,true))throw new RuntimeException('Owned greeting storage could not be prepared.');
        $wave=static function(int $hz):string{$pcm='';for($i=0;$i<32000;$i++)$pcm.=pack('v',(int)(6500*sin(2*M_PI*$hz*$i/16000))&65535);return 'RIFF'.pack('V',36+strlen($pcm)).'WAVEfmt '.pack('VvvVVvv',16,1,1,16000,32000,2,16).'data'.pack('V',strlen($pcm)).$pcm;};
        foreach(['instruction.wav'=>770,'replay.wav'=>660,'saved.wav'=>880] as $leaf=>$hz){$file=$root.'/'.$leaf;$raw=$wave($hz);$h=fopen($file,'xb');if(!$h)throw new RuntimeException('A fresh instruction file is required.');try{if(fwrite($h,$raw)!==strlen($raw)||!fflush($h))throw new RuntimeException('Instruction write failed.');}finally{fclose($h);}}
        $customBytes=$wave(990);$h=fopen($custom.'/audio.wav','xb');if(!$h)throw new RuntimeException('A fresh canary file is required.');try{if(fwrite($h,$customBytes)!==strlen($customBytes)||!fflush($h))throw new RuntimeException('Canary write failed.');}finally{fclose($h);}
        $q("insert into v_pbx_greetings(greeting_uuid,domain_uuid,created_by,name,category,source,company_name,target_number,caller_extension,state) values(?,?,?,'Owned native greeting','voicemail','phone','Fictional Windows Greetings','8101','8100','cancelled')",[$id,$domain,$s['factory_admin']['user_uuid']]);
        $q("insert into v_pbx_greetings(greeting_uuid,domain_uuid,created_by,name,category,source,company_name,state,media_uuid) values(?,?,?,'Owned other-domain custom audio','voicemail','phone','Other fictional domain','archived',?)",[$canary,$other,$s['factory_admin']['user_uuid'],$canary]);
        $q("insert into v_pbx_media(media_uuid,domain_uuid,category,source_path,file_path,title,created_at) values(?,?,'prompts',?,?,'Other-domain custom audio',now())",[$canary,$other,'greetings/'.$canary,$custom.'/audio.wav']);
        $s['greeting_native']['custom_sha256']=hash('sha256',$customBytes);$s['greeting_native']['preserved']=windows_greetings_native_snapshot($db,$domain,$id);$save();
        return ['schema'=>1,'installed_lua_bound'=>true,'prepared_only'=>true,'greeting_uuid'=>$id,'directory'=>$root];
    }
    $g=$s['greeting_native']??null;
    if(!is_array($g)||!is_uuid($g['id']??'')||!is_uuid($g['canary']??'')||$g['root']!==$base.'/'.$domain.'/greetings/'.$g['id']||$g['custom']!==$base.'/'.$g['other'].'/greetings/'.$g['canary'])throw new RuntimeException('The owned greeting identity changed.');
    $row=$q('select * from v_pbx_greetings where greeting_uuid=? and domain_uuid=?',[$g['id'],$domain])->fetch(PDO::FETCH_ASSOC);
    if(!$row)throw new RuntimeException('The owned greeting row is unavailable.');
    $checkCanary=static function()use($db,$domain,$g):bool{return windows_greetings_native_snapshot($db,$domain,$g['id'])===$g['preserved']&&is_file($g['custom'].'/audio.wav')&&!is_link($g['custom'].'/audio.wav')&&hash_file('sha256',$g['custom'].'/audio.wav')===$g['custom_sha256'];};
    if($action==='greetings-arm'){
        if(!$checkCanary()||$row['state']!=='cancelled'||$row['call_uuid']!==null||!$q("update v_pbx_greetings set state='ready_to_call',updated_at=now() where greeting_uuid=? and domain_uuid=? and state='cancelled' and call_uuid is null returning greeting_uuid",[$g['id'],$domain])->fetchColumn())throw new RuntimeException('The owned greeting could not be armed.');
        return ['schema'=>1,'ready_to_call'=>true];
    }
    $file=$g['root'].'/audio.wav';$recordings=$q('select recording_uuid,recording_filename,recording_name from v_recordings where domain_uuid=? and recording_filename=?',[$domain,$file])->fetchAll(PDO::FETCH_ASSOC);
    $media=$q('select media_uuid,domain_uuid,category,source_path,file_path,title from v_pbx_media where media_uuid=?',[$g['id']])->fetch(PDO::FETCH_ASSOC);
    // The new recording row has an independent UUID; exclude only that one
    // exact owned row from the retained pre-existing/custom inventory.
    if(count($recordings)===1&&is_uuid($recordings[0]['recording_uuid'])){
        $s['greeting_native']['recording_uuid']=$recordings[0]['recording_uuid'];$save();
        $now=windows_greetings_native_snapshot($db,$domain,$g['id']);
        $now['v_recordings']=array_values(array_filter($now['v_recordings'],static fn($r)=>$r['recording_uuid']!==$recordings[0]['recording_uuid']));
        $preserved=$now===$g['preserved']&&is_file($g['custom'].'/audio.wav')&&hash_file('sha256',$g['custom'].'/audio.wav')===$g['custom_sha256'];
    }else $preserved=$checkCanary();
    if($action==='greetings-status')return ['schema'=>1,'state'=>$row['state'],'call_uuid'=>$row['call_uuid'],'media_uuid'=>$row['media_uuid'],'directory'=>$g['root'],'file_exists'=>is_file($file)&&!is_link($file),'file_sha256'=>is_file($file)?hash_file('sha256',$file):null,'partial_absent'=>!file_exists($g['root'].'/recording.partial.wav'),'media_exact'=>$media&&$media===['media_uuid'=>$g['id'],'domain_uuid'=>$domain,'category'=>'prompts','source_path'=>'greetings/'.$g['id'],'file_path'=>$file,'title'=>$row['name']],'recording_exact'=>count($recordings)===1&&$recordings[0]['recording_name']===$row['name'],'preserved'=>$preserved];
    if(!$preserved)throw new RuntimeException('Other-domain or custom greeting data changed.');
    // No ready/calling deletion: the actual worker/Lua must have completed.
    if(!in_array($row['state'],['ready','cancelled','failed'],true))throw new RuntimeException('The greeting call has not finished.');
    if($row['call_uuid']!==null&&trim((string)event_socket::api('uuid_exists '.$row['call_uuid']))!=='false')throw new RuntimeException('The owned greeting call is still present.');
    $q('delete from v_recordings where domain_uuid=? and recording_filename=?',[$domain,$file]);
    $q('delete from v_pbx_greetings where greeting_uuid=? and domain_uuid=?',[$g['id'],$domain]);$q('delete from v_pbx_media where media_uuid=? and domain_uuid=?',[$g['id'],$domain]);
    $q('delete from v_pbx_greetings where greeting_uuid=? and domain_uuid=?',[$g['canary'],$g['other']]);$q('delete from v_pbx_media where media_uuid=? and domain_uuid=?',[$g['canary'],$g['other']]);
    foreach([$g['root']=>['instruction.wav','replay.wav','saved.wav','recording.partial.wav','audio.wav'],$g['custom']=>['audio.wav']] as $directory=>$leaves){
        windows_greetings_native_ordinary($directory);foreach($leaves as $leaf)if(is_file($directory.'/'.$leaf)&&!is_link($directory.'/'.$leaf))unlink($directory.'/'.$leaf);
        if(is_dir($directory)&&!rmdir($directory))throw new RuntimeException('Owned greeting directory cleanup refused.');
    }
    foreach(array_reverse($g['parents'],true)as$parent=>$existed)if(!$existed&&is_dir($parent)&&count(array_diff(scandir($parent),['.','..']))===0)rmdir($parent);
    $s['greeting_native']['cleaned']=true;$save();return ['schema'=>1,'owned_rows_and_files_removed'=>true,'other_domain_and_custom_preserved_before_cleanup'=>true];
}
