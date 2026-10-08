<?php
/** Private temporary domain for sip_trunk_live.py; never enables a customer gateway. */
if (PHP_SAPI !== 'cli' || getenv('OPENWEB_LIVE_TRUNK_TEST') !== '1') { exit(2); }
require dirname(__DIR__).'/resources/require.php';
$db=$database->db;
$db->setAttribute(PDO::ATTR_ERRMODE,PDO::ERRMODE_EXCEPTION);
$path=$argv[2]??'';
if (!str_starts_with($path,sys_get_temp_dir().'/openweb-trunk-check-') || is_link($path)) throw new RuntimeException('Private fixture path required.');
$query=function(string $sql,array $params=[])use($db){$s=$db->prepare($sql);$s->execute($params);return $s;};
$registrationIds=function(array $state): array {
    $ids=$state['registration_call_ids']??[];
    if(!is_array($ids)||count($ids)>10)throw new RuntimeException('Invalid fixture registration identifiers.');
    foreach($ids as $id)if(!is_string($id)||!preg_match('/^[a-f0-9]{24}@localfixture$/D',$id))throw new RuntimeException('Invalid fixture registration identifier.');
    return array_values(array_unique($ids));
};
$registrationCount=function(array $ids): int {
    $raw=event_socket::api('sofia status profile internal reg');
    if(!is_string($raw)||strlen($raw)>8388608||str_starts_with(trim($raw),'-ERR'))throw new RuntimeException('Native registration state is unavailable.');
    $count=0;
    foreach($ids as $id)if(preg_match('/(?:^|\r?\n)Call-ID:\s*'.preg_quote($id,'/').'(?:\r?\n|$)/',$raw))$count++;
    // The native listing contains phone accounts; never return or print it.
    return $count;
};
$switchChannels=function(): array {
    $raw=event_socket::api('show channels as json');
    if(!is_string($raw)||strlen($raw)>8388608)throw new RuntimeException('Native channel state is unavailable.');
    $data=json_decode($raw,true,512,JSON_THROW_ON_ERROR);
    if(!is_array($data)||(!isset($data['rows'])&&!in_array($data['row_count']??null,[0,'0'],true)))throw new RuntimeException('Native channel state is unavailable.');
    $rows=$data['rows']??[];
    if(!is_array($rows))throw new RuntimeException('Native channel state is unavailable.');
    return $rows;
};
$cleanup=function(array $state)use($db,$query,$path,$switchChannels,$registrationIds,$registrationCount){
    $domain=$state['domain']??'';$realm=$state['realm']??'';
    if(!is_uuid($domain)||!preg_match('/^carrier-check-[a-f0-9]{12}\.invalid$/D',$realm))throw new RuntimeException('Unknown fixture domain.');
    $stored=$query('select domain_name from v_domains where domain_uuid=?',[$domain])->fetchColumn();
    if($stored && $stored!==$realm)throw new RuntimeException('Fixture ownership mismatch.');
    $registrations=$registrationIds($state);
    // Sofia identifies these contacts by the original REGISTER Call-ID; a new
    // expires=0 transaction can return 200 without removing the old contact.
    foreach($registrations as $callId)event_socket::api('sofia profile internal flush_inbound_reg '.$callId);
    $registrationDeadline=microtime(true)+3;
    while($registrationCount($registrations)>0){
        if(microtime(true)>$registrationDeadline)throw new RuntimeException('Fixture SIP registrations remain; private state retained.');
        usleep(50000);
    }
    $gateways=$query('select gateway_uuid from v_gateways where domain_uuid=?',[$domain])->fetchAll(PDO::FETCH_COLUMN);
    $queues=$query('select queue_extension from v_call_center_queues where domain_uuid=?',[$domain])->fetchAll(PDO::FETCH_COLUMN);
    $agents=$query('select call_center_agent_uuid from v_call_center_agents where domain_uuid=?',[$domain])->fetchAll(PDO::FETCH_COLUMN);
    // Keep native identifiers for a safe retry if final verification fails after
    // the domain rows have already been removed. The state stays private.
    foreach(['gateways'=>&$gateways,'queues'=>&$queues,'agents'=>&$agents] as $kind=>&$ids){
        $saved=$state['cleanup_ids'][$kind]??[];
        if(!is_array($saved)||count($saved)>100)throw new RuntimeException('Invalid fixture cleanup identifiers.');
        $ids=array_values(array_unique(array_merge($ids,$saved)));
        foreach($ids as $value)if(!is_string($value)||($kind==='queues'?!preg_match('/^[0-9]{2,10}$/D',$value):!is_uuid($value)))throw new RuntimeException('Invalid fixture cleanup identifier.');
        $state['cleanup_ids'][$kind]=$ids;
    }unset($ids);
    $callIds=$state['call_ids']??[];if(!is_array($callIds)||count($callIds)>500)throw new RuntimeException('Invalid fixture call identifiers.');
    foreach($callIds as $callId)if(!is_string($callId)||!preg_match('/^[A-Za-z0-9_.@:+-]{1,200}$/D',$callId))throw new RuntimeException('Invalid fixture call identifier.');
    $saveState=function()use(&$state,&$callIds,$path): void {
        $state['call_ids']=array_values(array_unique($callIds));
        if(file_put_contents($path,json_encode($state,JSON_THROW_ON_ERROR),LOCK_EX)===false||!chmod($path,0600))throw new RuntimeException('Private cleanup state could not be retained.');
    };
    $saveState();
    $deadline=microtime(true)+50;
    $ownChannels=function()use($switchChannels,$domain,&$callIds,$deadline): array {
        $owned=[];
        foreach($switchChannels() as $row){
            if(microtime(true)>$deadline)throw new RuntimeException('Fixture cleanup timed out; private state retained.');
            $id=$row['uuid']??'';
            if(!is_string($id)||!is_uuid($id))throw new RuntimeException('Native channel identifier is unavailable.');
            if(trim((string)event_socket::api('uuid_getvar '.$id.' domain_uuid'))!==$domain)continue;
            $owned[]=$id;
            $sip=trim((string)event_socket::api('uuid_getvar '.$id.' sip_call_id'));
            if(preg_match('/^[A-Za-z0-9_.@:+-]{1,200}$/D',$sip)&&!in_array($sip,$callIds,true))$callIds[]=$sip;
            if(count($callIds)>500)throw new RuntimeException('Too many fixture call identifiers.');
        }
        return $owned;
    };
    // Close only this generated PBX before draining it. A real provider pilot
    // elsewhere must keep its channels, gateways and background worker running.
    $query('update v_domains set domain_enabled=false where domain_uuid=?',[$domain]);
    $query('update v_gateways set enabled=false where domain_uuid=?',[$domain]);
    $query("update v_pbx_jobs set state='cancelled',lease_until=null,agent_number=null,last_result='Local fixture cleanup' where domain_uuid=? and state in ('waiting','starting','calling')",[$domain]);
    foreach($gateways as $gateway)event_socket::api('sofia profile external killgw '.$gateway);
    $quietSince=null;$channelDeadline=microtime(true)+35;
    do{
        $active=$ownChannels();$saveState();
        // Repeat the scoped hangup to catch a Lua delivery already between its
        // job claim and agent originate when cancellation was recorded.
        event_socket::api('hupall NORMAL_CLEARING domain_uuid '.$domain);
        $quietSince=$active?null:($quietSince??microtime(true));
        if($quietSince!==null&&microtime(true)-$quietSince>=2)break;
        if(microtime(true)>$channelDeadline)throw new RuntimeException('Fixture channels did not become quiet; private state retained.');
        usleep(100000);
    }while(true);
    $log=rtrim((string)config::load()->get('switch.log.dir','/var/log/freeswitch'),'/').'/xml_cdr';
    $children=$query("select distinct c.table_name from information_schema.columns c join information_schema.tables t using(table_schema,table_name) where c.table_schema='public' and c.column_name='xml_cdr_uuid' and c.table_name like 'v_%' and t.table_type='BASE TABLE'")->fetchAll(PDO::FETCH_COLUMN);
    usort($children,fn($a,$b)=>($a==='v_xml_cdr')<=>($b==='v_xml_cdr'));
    $drainCdr=function()use($db,$query,$domain,$log,$state,&$callIds,$children,$ownChannels,$deadline): void {
        $quietSince=null;
        do{
            if(microtime(true)>$deadline)throw new RuntimeException('Fixture CDR drain timed out; private state retained.');
            if($ownChannels())throw new RuntimeException('A fixture channel restarted during cleanup; private state retained.');
            $removed=0;
            if(is_dir($log)&&!is_link($log)){
                $files=new RecursiveIteratorIterator(new RecursiveDirectoryIterator($log,FilesystemIterator::SKIP_DOTS));
                $old=libxml_use_internal_errors(true);
                try{foreach($files as $file){
                    if(microtime(true)>$deadline)throw new RuntimeException('Fixture CDR drain timed out; private state retained.');
                    if(!$file->isFile()||$file->isLink()||$file->getSize()>5242880||$file->getMTime()<($state['created_epoch']??time())||!str_ends_with($file->getFilename(),'.xml'))continue;
                    $name=$file->getPathname();$raw=@file_get_contents($name);if($raw===false)continue;
                    // The XML CDR importer also accepts a whole percent-encoded
                    // document. Decode before rejecting unsafe XML constructs.
                    if(str_starts_with($raw,'%'))$raw=urldecode($raw);
                    if(strlen($raw)>5242880||preg_match('/<!\s*(?:DOCTYPE|ENTITY)/i',$raw))continue;
                    $doc=new DOMDocument();if(!$doc->loadXML($raw,LIBXML_NONET))continue;
                    $owned=($doc->getElementsByTagName('domain_uuid')->item(0)?->textContent??'')===$domain;
                    $sip=urldecode($doc->getElementsByTagName('sip_call_id')->item(0)?->textContent??'');
                    if($owned||in_array($sip,$callIds,true)){
                        $removed++;
                        if(!@unlink($name)&&is_file($name))throw new RuntimeException('A fixture CDR file could not be removed; private state retained.');
                    }
                }}finally{libxml_clear_errors();libxml_use_internal_errors($old);}
            }
            // Query after each file sweep: the importer may have read a file
            // before it was removed and committed its rows during the sweep.
            $cdrIds=$query('select xml_cdr_uuid from v_xml_cdr where domain_uuid=?'.($callIds?' or sip_call_id in ('.implode(',',array_fill(0,count($callIds),'?')).')':''),array_merge([$domain],$callIds))->fetchAll(PDO::FETCH_COLUMN);
            if($cdrIds){
                $db->beginTransaction();
                try{foreach($children as $table)if(preg_match('/^v_[a-z0-9_]+$/D',$table))$query('delete from '.$table.' where xml_cdr_uuid in ('.implode(',',array_fill(0,count($cdrIds),'?')).')',$cdrIds);$db->commit();}
                catch(Throwable $e){if($db->inTransaction())$db->rollBack();throw $e;}
            }
            $quietSince=$removed||$cdrIds?null:($quietSince??microtime(true));
            if($quietSince!==null&&microtime(true)-$quietSince>=3)return;
            usleep(100000);
        }while(true);
    };
    $drainCdr();$saveState();
    $db->beginTransaction();
    // Remove only rows belonging to the independently generated fixture domain.
    try{
        $tables=$query("select c.table_name from information_schema.columns c join information_schema.tables t using(table_schema,table_name) where c.table_schema='public' and c.column_name='domain_uuid' and c.table_name like 'v_%' and t.table_type='BASE TABLE'")->fetchAll(PDO::FETCH_COLUMN);
        foreach($tables as $table)if($table!=='v_domains'&&preg_match('/^v_[a-z0-9_]+$/D',$table))$query('delete from '.$table.' where domain_uuid=?',[$domain]);
        $query('delete from v_domains where domain_uuid=?',[$domain]);$db->commit();
    }catch(Throwable $e){if($db->inTransaction())$db->rollBack();throw $e;}
    $cache=new cache;
    foreach(['dialplan:'.$realm,'dialplan:ingress@'.$realm,'dialplan:openweb-incoming:'.gethostname(),gethostname().':configuration:sofia.conf','configuration:callcenter.conf',gethostname().':configuration:callcenter.conf','configuration:acl.conf',gethostname().':configuration:acl.conf'] as $key)$cache->delete($key);
    foreach(['ow-1000','ow-1001','1000','1001'] as $user)$cache->delete('directory:'.$user.'@'.$realm);
    event_socket::api('reloadxml');event_socket::api('reloadacl');
    foreach($queues as $number){
        foreach($agents as $agent)event_socket::api('callcenter_config tier del '.$number.'@'.$realm.' '.$agent);
        event_socket::api('callcenter_config queue unload '.$number.'@'.$realm);
    }
    foreach($agents as $agent)event_socket::api('callcenter_config agent del '.$agent);
    $drainCdr();$saveState();
    $root=pbx_paths::media().'/'.$domain;
    if(is_link($root))throw new RuntimeException('Fixture media root is unsafe; private state retained.');
    if(is_dir($root)){
        $files=new RecursiveIteratorIterator(new RecursiveDirectoryIterator($root,FilesystemIterator::SKIP_DOTS),RecursiveIteratorIterator::CHILD_FIRST);
        foreach($files as $file){
            $name=$file->getPathname();
            $removed=$file->isDir()&&!$file->isLink()?@rmdir($name):@unlink($name);
            if(!$removed&&(is_file($name)||is_dir($name)||is_link($name)))throw new RuntimeException('Fixture media could not be removed; private state retained.');
        }
        if(!@rmdir($root)&&is_dir($root))throw new RuntimeException('Fixture media directory remains; private state retained.');
    }
    foreach($agents as $agent)if(str_contains((string)event_socket::api('callcenter_config agent list '.$agent),$agent))throw new RuntimeException('A fixture agent remains in native memory.');
    if(str_contains((string)event_socket::api('callcenter_config queue list'),$realm)||str_contains((string)event_socket::api('callcenter_config tier list'),$realm))throw new RuntimeException('A fixture queue remains in native memory.');
};
if(($argv[1]??'')==='cleanup'){
    $cleanup(json_decode(file_get_contents($path),true,512,JSON_THROW_ON_ERROR));echo "Fixture removed.\n";exit;
}
if(($argv[1]??'')==='registration-status'){
    $state=json_decode(file_get_contents($path),true,512,JSON_THROW_ON_ERROR);$domain=$state['domain']??'';$realm=$state['realm']??'';
    if(!is_uuid($domain)||!preg_match('/^carrier-check-[a-f0-9]{12}\.invalid$/D',$realm)||($query('select domain_name from v_domains where domain_uuid=?',[$domain])->fetchColumn()?:$realm)!==$realm)throw new RuntimeException('Fixture registration ownership mismatch.');
    echo json_encode(['registrations'=>$registrationCount($registrationIds($state))],JSON_THROW_ON_ERROR)."\n";exit;
}
if(($argv[1]??'')==='disable'){
    $state=json_decode(file_get_contents($path),true,512,JSON_THROW_ON_ERROR);
    $domain=$state['domain']??'';$realm=$state['realm']??'';
    if(!is_uuid($domain)||!preg_match('/^carrier-check-[a-f0-9]{12}\.invalid$/D',$realm)||$query('select domain_name from v_domains where domain_uuid=?',[$domain])->fetchColumn()!==$realm)throw new RuntimeException('Fixture ownership mismatch.');
    $_SESSION=['user_uuid'=>uuid(),'domain_uuid'=>$domain,'domain_name'=>$realm,'user'=>['domain_uuid'=>$domain]];
    $admin=new pbx_admin($db);$key=$state['trunks'][0];$trunk=$admin->config()['trunks'][$key];
    $admin->save('trunk',$key,['name'=>$trunk['name'],'host'=>$trunk['host'],'enabled'=>'']);
    echo "Local fixture provider disabled.\n";exit;
}
if(in_array($argv[1]??'',['callback-start','callback-status','callback-agent-status'],true)){
    $state=json_decode(file_get_contents($path),true,512,JSON_THROW_ON_ERROR);$domain=$state['domain']??'';$realm=$state['realm']??'';$target=$argv[3]??'99101';
    if(!is_uuid($domain)||!preg_match('/^carrier-check-[a-f0-9]{12}\.invalid$/D',$realm)||$query('select domain_name from v_domains where domain_uuid=?',[$domain])->fetchColumn()!==$realm||!in_array($target,['99101','99104'],true))throw new RuntimeException('Fixture callback ownership mismatch.');
    if(($argv[1]??'')==='callback-agent-status'){
        if(($state['callback_queue']??'')!=='9100')throw new RuntimeException('Fixture callback queue is missing.');
        $agents=$query("select distinct a.call_center_agent_uuid from v_call_center_agents a join v_call_center_tiers t on t.call_center_agent_uuid=a.call_center_agent_uuid and t.domain_uuid=a.domain_uuid join v_call_center_queues q on q.call_center_queue_uuid=t.call_center_queue_uuid and q.domain_uuid=a.domain_uuid where a.domain_uuid=? and a.agent_id='1001' and q.queue_extension=?",[$domain,$state['callback_queue']])->fetchAll(PDO::FETCH_COLUMN);
        if(count($agents)!==1||!is_uuid($agents[0]))throw new RuntimeException('Fixture callback agent is missing.');
        $agent=$agents[0];$native=[];
        $raw=event_socket::api('callcenter_config agent list '.$agent);
        if(!is_string($raw)||strlen($raw)>65536)throw new RuntimeException('Native fixture agent state is unavailable.');
        $lines=preg_split('/\r?\n/',trim($raw));$keys=explode('|',array_shift($lines));
        foreach($lines as $line){$values=explode('|',$line);if(count($values)!==count($keys))continue;$row=array_combine($keys,$values);if(($row['name']??'')===$agent){$native=$row;break;}}
        $config=json_decode($query('select config from v_pbx_restore where domain_uuid=?',[$domain])->fetchColumn(),true,512,JSON_THROW_ON_ERROR);
        $auth=$config['users']['1001']['auth_id']??'';
        if(!is_string($auth)||!preg_match('/^[A-Za-z0-9_.+%-]{1,128}$/D',$auth))throw new RuntimeException('Fixture callback contact is missing.');
        $active=(int)($native['external_calls_count']??0)>0;
        foreach($switchChannels() as $row){
            if(!in_array($row['presence_id']??'',['1001@'.$realm,$auth.'@'.$realm],true))continue;
            $id=$row['uuid']??'';if(!is_string($id)||!is_uuid($id))throw new RuntimeException('Native fixture channel is unavailable.');
            if(trim((string)event_socket::api('uuid_getvar '.$id.' domain_uuid'))===$domain)$active=true;
        }
        $contact=trim((string)event_socket::api('sofia_contact '.$auth.'@'.$realm));
        $status=$native['status']??'Unknown';$agentState=$native['state']??'Unknown';
        foreach([$status,$agentState] as $value)if(!is_string($value)||!preg_match('/^[A-Za-z0-9 ()_-]{1,40}$/D',$value))throw new RuntimeException('Native fixture agent state is invalid.');
        $readyTime=(int)($native['ready_time']??0);$now=time();
        $ready=($native['name']??'')===$agent&&$agentState==='Waiting'&&in_array($status,['Available','Available (On Demand)'],true)
            &&$readyTime<=$now&&(int)($native['last_bridge_end']??0)+(int)($native['wrap_up_time']??0)<=$now
            &&(int)($native['external_calls_count']??0)===0&&!$active&&preg_match('~^sofia/[^/]+/.+~D',$contact)===1;
        // Never print the native contact, agent UUID, account or phone secret.
        echo json_encode(['ready'=>$ready,'status'=>$status,'state'=>$agentState,'ready_time'=>$readyTime,'active'=>$active],JSON_THROW_ON_ERROR)."\n";exit;
    }
    if(($argv[1]??'')==='callback-start'){
        // Only generated local gateways may carry these synthetic outside calls.
        foreach($state['gateway_ids']??[] as $gateway){$native=$query('select proxy,register from v_gateways where domain_uuid=? and gateway_uuid=?',[$domain,$gateway])->fetch(PDO::FETCH_ASSOC);if(!$native||$native['register']||!preg_match('/^127\.0\.0\.1:[0-9]{4,5}$/D',$native['proxy']))throw new RuntimeException('A callback provider is not a local nonregistering fixture.');}
        if(count($state['gateway_ids']??[])!==2||($state['callback_queue']??'')!=='9100')throw new RuntimeException('Fixture callback queue is missing.');
        $job=uuid();$call=uuid();
        // Match the durable lease produced by the C# worker; bypass request UX only.
        $query("insert into v_pbx_jobs(job_uuid,domain_uuid,kind,queue_number,target_number,internal_target,state,due_at,expires_at,lease_until,call_uuid,max_attempts,request_key) values(?,?,'callback',?,?,false,'starting',now(),now()+interval '5 minutes',now()+interval '2 minutes',?,1,?)",[$job,$domain,$state['callback_queue'],$target,$call,'local-carrier/'.$job]);
        $state['callback_jobs'][$target]=$job;file_put_contents($path,json_encode($state,JSON_THROW_ON_ERROR));chmod($path,0600);
        $result=event_socket::api('luarun app/pbx_setup/jobs.lua '.$job);if(!is_string($result)||!str_starts_with(trim($result),'+OK'))throw new RuntimeException('The local engine did not start the callback.');
        echo "Local external callback started.\n";exit;
    }
    $job=$state['callback_jobs'][$target]??'';if(!is_uuid($job))throw new RuntimeException('Fixture callback is missing.');
    $row=$query('select state,attempts,last_result,internal_target,lease_until,agent_number from v_pbx_jobs where domain_uuid=? and job_uuid=?',[$domain,$job])->fetch(PDO::FETCH_ASSOC);if(!$row)throw new RuntimeException('Fixture callback belongs to another PBX.');
    echo json_encode($row,JSON_THROW_ON_ERROR)."\n";exit;
}
$ports=array_map('intval',array_slice($argv,3));
if(count($ports)!==2||min($ports)<1024||max($ports)>65535)throw new RuntimeException('Two local provider ports required.');
$domain=uuid();$realm='carrier-check-'.bin2hex(random_bytes(6)).'.invalid';
$state=['domain'=>$domain,'realm'=>$realm,'created_epoch'=>time()];
file_put_contents($path,json_encode($state,JSON_THROW_ON_ERROR));chmod($path,0600);
try {
    $query('insert into v_domains(domain_uuid,domain_name,domain_enabled,domain_description) values(?,?,true,?)',[$domain,$realm,'Temporary local carrier validation']);
    $_SESSION=['user_uuid'=>uuid(),'domain_uuid'=>$domain,'domain_name'=>$realm,'user'=>['domain_uuid'=>$domain]];
    $admin=new pbx_admin($db);$db->beginTransaction();$admin->initialize($realm);$db->commit();
    foreach(['1000','1001'] as $number)$admin->save('user','new',['number'=>$number,'name'=>'Local Fixture '.$number,'profile'=>'Available','enabled'=>'1','timeout'=>'10']);
    $state['users']=[];
    foreach(['1000','1001'] as $number){$c=$admin->credentials($number);$state['users'][]=['number'=>$number,'auth'=>$c['account'],'password'=>$c['password']];}
    $trunks=[];$state['provider_auth']=['username'=>'fixture-auth','password'=>bin2hex(random_bytes(18))];
    foreach($ports as $i=>$port){
        $input=['name'=>'Local carrier '.($i+1),'host'=>'127.0.0.1','port'=>(string)$port,'transport'=>'udp','authentication'=>'ip','allowed_ips'=>'127.0.0.1','main_number'=>'+2710000000'.($i+1),'caller_id'=>'','caller_id_in_from'=>'1','sip_cid_type'=>'rpid','codecs'=>'PCMU,PCMA','enabled'=>'1'];
        if($i===0)$input=array_merge($input,['authentication'=>'password','register'=>'0','username'=>'fixture-account','auth_username'=>$state['provider_auth']['username'],'password'=>$state['provider_auth']['password']]);
        $trunks[]=$admin->save('trunk','new',$input);
    }
    $admin->save('outbound','new',['name'=>'Only local fixture calls','prefix'=>'99','lengths'=>'5','routes'=>[
        ['trunk_id'=>$trunks[0],'strip'=>'2','prepend'=>'55','caller_id'=>''],
        ['trunk_id'=>$trunks[1],'strip'=>'2','prepend'=>'55','caller_id'=>'']
    ]]);
    $incoming=$admin->save('incoming','new',['trunk_id'=>$trunks[0],'number'=>'999100001','office'=>'Extension:1001','enabled'=>'1']);
    $config=$admin->config();
    // Model the source backup's To header DID selector and caller-ID header policy.
    foreach($trunks as $key){$config['trunks'][$key]['source_field']='ToUserPart';$config['trunks'][$key]['codecs']=['PCMU','PCMA'];$config['trunks'][$key]['headers']=['FromUserPart'=>'$OutboundCallerId','FromDisplayName'=>'$OutboundCallerId','FromHostPart'=>'$GWHostPort','ContactUser'=>'$OutboundCallerId','RemotePartyIDCallingPartyUserPart'=>'$OutboundCallerId'];}
    $query('update v_pbx_restore set config=cast(? as jsonb) where domain_uuid=?',[json_encode($config,JSON_THROW_ON_ERROR),$domain]);
    $admin->save('incoming',$incoming,['office'=>'Extension:1001','enabled'=>'1']);
    $state['callback_queue']=$admin->save('queue','new',['number'=>'9100','name'=>'Local external callback fixture','members'=>['1001'],'timeout'=>'60','ring_timeout'=>'10','wrap_up'=>'0','callback_mode'=>'request','callback_after'=>'10','callback_attempts'=>'1','callback_prefix'=>'','destination'=>'None:']);
    $state['trunks']=$trunks;
    $state['gateway_ids']=array_map(fn($key)=>$config['trunks'][$key]['gateway_uuid'],$trunks);
    file_put_contents($path,json_encode($state,JSON_THROW_ON_ERROR));chmod($path,0600);
    echo "Local fixture prepared.\n";
} catch(Throwable $e){if($db->inTransaction())$db->rollBack();$cleanup($state);throw $e;}
