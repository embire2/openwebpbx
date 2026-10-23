<?php
/** SPDX-License-Identifier: AGPL-3.0-or-later. Drain only the disposable fixture's actual CDR spool. */
require __DIR__.'/windows-native-cleanup-rows.php';
function windows_native_cleanup_drain(PDO $db,array $s,array $domains):array{
    $worker=new class($db) extends pbx_call_records {public function spool():string{return $this->directory();}};
    $dir=$worker->spool();
    if(!$domains){
        // Before discover there are no recorded owned IDs. Never infer them or
        // kill/import a call here. The unchanged fixture performs its own exact
        // service lookup and factory/identity checks, including its no-service path.
        $inventory=json_decode(event_socket::api('show channels as json'),true,64,JSON_THROW_ON_ERROR);$rows=$inventory['rows']??[];
        if(!is_array($rows)||$rows!==[]||($inventory['row_count']??null)!==0||is_link($dir)||(file_exists($dir)&&!is_dir($dir)))throw new RuntimeException('An idle pre-owned factory is required.');
        if(is_dir($dir))foreach(new DirectoryIterator($dir)as$f)if(preg_match('/^(?:a_)?[a-f0-9-]{36}\.cdr\.xml$/D',$f->getFilename()))throw new RuntimeException('Unscoped pre-owned spool is not empty.');
        return ['schema'=>1,'state'=>'passed','pre_owned'=>true,'owned_channels_ended'=>0,'actual_importer'=>false,'spool_empty_stable_ms'=>0,'imported'=>0,'foreign_records_imported'=>false];
    }
    $realm=$s['owned']['domain_name'];
    $check=$db->prepare('select count(*) from v_domains where domain_uuid=? and domain_name=?');$check->execute([$domains[0],$realm]);
    if((int)$check->fetchColumn()!==1)throw new RuntimeException('The exact disposable service must still exist before draining.');
    $callIds=[];$deadline=hrtime(true)+20000000000;
    do{
        $rows=json_decode(event_socket::api('show channels as json'),true,64,JSON_THROW_ON_ERROR)['rows']??[];
        if(!is_array($rows)||count($rows)>128)throw new RuntimeException('Bounded channel inventory required.');
        $owned=[];
        foreach($rows as$row)if(($row['context']??'')===$realm||str_ends_with($row['presence_id']??'','@'.$realm)){
            $id=$row['uuid']??'';if(!is_uuid($id))throw new RuntimeException('Invalid owned channel.');$owned[]=$id;
            if(!isset($callIds[$id])){event_socket::api('uuid_kill '.$id.' NORMAL_CLEARING');$callIds[$id]=true;}
        }
        if(!$owned)break;
        if(hrtime(true)>$deadline)throw new RuntimeException('Owned channels did not settle.');usleep(100000);
    }while(true);
    // Expose only the real importer's configured directory, with unchanged tick().
    if(!is_dir($dir)||is_link($dir))throw new RuntimeException('Ordinary native spool required.');
    $quiet=null;$imported=0;
    do{
        $files=[];
        foreach(new DirectoryIterator($dir)as$f){
            if($f->isDot()||$f->isDir())continue;$name=$f->getFilename();
            if(!preg_match('/^(?:a_)?([a-f0-9-]{36})\.cdr\.xml$/D',$name,$m))continue;
            if(!$f->isFile()||$f->isLink()||$f->getSize()>3000000||count($files)>=256)throw new RuntimeException('Ordinary bounded fixture spool required.');
            $v=pbx_call_records::variables(file_get_contents($f->getPathname()));
            if(!in_array($v['domain_uuid']??null,$domains,true)||($v['domain_name']??'')!==$realm||($v['uuid']??$v['call_uuid']??'')!==$m[1])throw new RuntimeException('Foreign native spool record refused before importing.');
            $files[]=$name;
        }
        if($files){$quiet=null;$result=$worker->tick(256);if($result['quarantined']||$result['retained'])throw new RuntimeException('Owned native records could not be durably imported.');$imported+=$result['imported'];}
        elseif($quiet===null){$quiet=hrtime(true);}
        elseif(hrtime(true)-$quiet>=3000000000)break;
        if(hrtime(true)>$deadline)throw new RuntimeException('Owned native record drain timed out.');usleep(100000);
    }while(true);
    return ['schema'=>1,'state'=>'passed','pre_owned'=>false,'owned_channels_ended'=>count($callIds),'actual_importer'=>true,'spool_empty_stable_ms'=>3000,'imported'=>min(1000000,$imported),'foreign_records_imported'=>false];
}
if(realpath($_SERVER['SCRIPT_FILENAME']??'')===__FILE__){
 try{[$s,$domains]=windows_native_cleanup_input($argv[1]??'',true);require 'C:/OpenWebPBX/web/resources/require.php';echo json_encode(windows_native_cleanup_drain($database->db,$s,$domains),JSON_THROW_ON_ERROR),PHP_EOL;}
 catch(Throwable$e){fwrite(STDERR,'The owned disposable record drain refused: '.get_class($e).PHP_EOL);exit(1);}
}
