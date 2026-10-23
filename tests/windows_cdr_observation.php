<?php
/** Read-only correlation of one fictional native call; never runs an importer. */
function windows_native_cdr_observation(PDO $db,string $domain,string $realm,string $callId,array $users,string $spool):array {
    $uuid=static fn(mixed $v):bool=>is_string($v)&&preg_match('/^[a-f0-9]{8}(?:-[a-f0-9]{4}){3}-[a-f0-9]{12}$/D',$v)===1;
    if(!$uuid($domain)||!preg_match('/^pbx-[a-f0-9]{12}\.[A-Za-z0-9.-]+$/D',$realm)||!preg_match('/^[a-f0-9]{24}@localfixture$/D',$callId)||$db->inTransaction())throw new RuntimeException('Exact owned native call required.');
    $pair=[];foreach($users as $u)if(in_array($u['number']??null,['8100','8101'],true)){
        $n=$u['number'];if(isset($pair[$n])||!$uuid($u['extension_uuid']??null)||($u['domain_uuid']??null)!==$domain)throw new RuntimeException('Exact owned caller pair required.');$pair[$n]=$u;
    }
    if(count($pair)!==2||$pair['8100']['extension_uuid']===$pair['8101']['extension_uuid'])throw new RuntimeException('Exact owned caller pair required.');
    if($spool===''||strpbrk($spool,"\r\n\0")!==false||!is_dir($spool)||is_link($spool))throw new RuntimeException('Ordinary installed spool required.');
    for($p=$spool;;$p=dirname($p)){if(is_link($p))throw new RuntimeException('Ordinary installed spool required.');if($p===dirname($p))break;}
    $out=['schema'=>1,'state'=>'observed','read_only'=>true,'scope'=>'owned_call','cdr_rows'=>0,'answered_cdr_rows'=>0,'history_rows'=>0,'history_owner_rows'=>0,'spool_files_present'=>0,'quarantined_files_present'=>0,'record_scope_exact'=>false,'history_sources_exact'=>false,'spool_absent'=>false,'completed'=>false];
    $query=static function(string $sql,array $args=[])use($db):PDOStatement{$q=$db->prepare($sql);$q->execute($args);return$q;};
    $db->beginTransaction();
    try {
        $db->exec('set transaction isolation level repeatable read read only');$db->exec("set local statement_timeout='3s'");
        if((int)$query('select count(*) from v_domains where domain_uuid=? and domain_name=?',[$domain,$realm])->fetchColumn()!==1)throw new RuntimeException('Owned native domain differs.');
        foreach($pair as $u)if((int)$query('select count(*) from v_extensions where domain_uuid=? and extension_uuid=? and extension=?',[$domain,$u['extension_uuid'],$u['auth']??''])->fetchColumn()!==1)throw new RuntimeException('Owned native phone differs.');
        // Search by the independently observed caller SIP Call-ID first, so a
        // same-ID row in a foreign domain cannot disappear behind a scope filter.
        $rows=$query("select xml_cdr_uuid,domain_uuid,extension_uuid,caller_id_number,destination_number,direction,billsec,json::jsonb as json from v_xml_cdr where json::jsonb #>> '{variables,sip_call_id}'=? limit 2",[$callId])->fetchAll(PDO::FETCH_ASSOC);
        if(count($rows)>1)throw new RuntimeException('Ambiguous native call identity.');
        if(!$rows)return$out;
        $r=$rows[0];$v=json_decode($r['json'],true,64,JSON_THROW_ON_ERROR)['variables']??null;
        if(!$uuid($r['xml_cdr_uuid'])||$r['domain_uuid']!==$domain||$r['extension_uuid']!==$pair['8100']['extension_uuid']||$r['caller_id_number']!=='8100'||$r['destination_number']!=='8101'||$r['direction']!=='local'||!is_array($v)||($v['sip_call_id']??null)!==$callId||($v['openweb_scope_origin']??null)!=='8100'||($v['openweb_scope_target']??null)!=='8101')throw new RuntimeException('Native call ownership differs.');
        $id=$r['xml_cdr_uuid'];$out['cdr_rows']=1;$out['record_scope_exact']=true;$out['answered_cdr_rows']=is_numeric($r['billsec'])&&(float)$r['billsec']>0?1:0;
        $history=$query('select domain_uuid,owner_number,party_number,call_type,end_status,source_id from v_pbx_call_history where source_id like ? limit 3',['native/'.$id.'/%'])->fetchAll(PDO::FETCH_ASSOC);
        if(count($history)>2)throw new RuntimeException('Ambiguous native call history.');
        $owners=[];
        foreach($history as $h){$n=$h['owner_number'];if(!in_array($n,['8100','8101'],true)||isset($owners[$n])||$h['domain_uuid']!==$domain||$h['source_id']!=='native/'.$id.'/'.$n||$h['party_number']!==($n==='8100'?'8101':'8100')||$h['call_type']!==($n==='8100'?'InternalOutbound':'InternalInbound')||$h['end_status']!=='Answered')throw new RuntimeException('Native call history ownership differs.');$owners[$n]=true;}
        $out['history_rows']=count($history);$out['history_owner_rows']=count($owners);$out['history_sources_exact']=count($owners)===2;
        // Only the correlated record names are inspected. No foreign spool is
        // read, imported, renamed, removed or projected into the report.
        $names=[$id.'.cdr.xml','a_'.$id.'.cdr.xml'];
        $countNames=static function(string $dir)use($names):int{
            if(is_link($dir)||!is_dir($dir))throw new RuntimeException('Ordinary scoped record directory required.');$count=0;$entries=0;
            foreach(new DirectoryIterator($dir)as $entry){if(++$entries>4096)throw new RuntimeException('Bounded record directory required.');if(in_array(strtolower($entry->getFilename()),$names,true)){if(!$entry->isFile()||$entry->isLink())throw new RuntimeException('Ordinary scoped record required.');$count++;}}
            return$count;
        };
        $out['spool_files_present']=$countNames($spool);
        // Establish nested absence by listing the accessible parent; a failed
        // stat/permission check is not evidence that quarantine is absent.
        $child=static function(string $dir,string $name):?string{$found=null;$entries=0;foreach(new DirectoryIterator($dir)as $entry){if(++$entries>4096)throw new RuntimeException('Bounded record directory required.');if(strcasecmp($entry->getFilename(),$name)===0){if($found!==null||!$entry->isDir()||$entry->isLink())throw new RuntimeException('Ordinary quarantine directory required.');$found=$entry->getPathname();}}return$found;};
        $failed=$child($spool,'failed');$quarantine=$failed===null?null:$child($failed,'openweb');
        if($quarantine!==null)$out['quarantined_files_present']=$countNames($quarantine);
        $out['spool_absent']=$out['spool_files_present']===0&&$out['quarantined_files_present']===0;
        $out['completed']=$out['answered_cdr_rows']===1&&$out['history_sources_exact']&&$out['spool_absent'];
        return$out;
    } finally {if($db->inTransaction())$db->rollBack();}
}
