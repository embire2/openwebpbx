<?php
/** SPDX-License-Identifier: AGPL-3.0-or-later.
 * Private evidence and owned fixtures for TWO disposable Windows installations.
 * Never copies source database identity onto the replacement, creates media, or
 * starts services. The caller owns encrypted archives, native peers and ACLs.
 */

function restore_fixture_canonical(mixed $value): mixed {
    if (is_object($value)) {
        $values=get_object_vars($value);ksort($values,SORT_STRING);
        foreach($values as &$item)$item=restore_fixture_canonical($item);unset($item);
        return (object)$values;
    }
    if (!is_array($value)) return $value;
    if (!array_is_list($value)) ksort($value,SORT_STRING);
    foreach($value as &$item)$item=restore_fixture_canonical($item);unset($item);
    return $value;
}

function restore_fixture_digest(mixed $value,string $key): string {
    if(strlen($key)!==32)throw new RuntimeException('An independent 32-byte audit key is required.');
    return hash_hmac('sha256',json_encode(restore_fixture_canonical($value),JSON_THROW_ON_ERROR|JSON_UNESCAPED_SLASHES|JSON_PRESERVE_ZERO_FRACTION),$key);
}

function restore_fixture_uuid(mixed $value): bool {
    return is_string($value)&&preg_match('/^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$/Di',$value)===1;
}

function restore_fixture_contract(array $s,array $environment,array $installation,string $scope): void {
    if(($environment['GITHUB_ACTIONS']??'')!=='true'||($environment['RUNNER_ENVIRONMENT']??'')!=='github-hosted'
        ||($environment['GITHUB_REPOSITORY']??'')!=='embire2/openwebpbx'||($environment['OPENWEB_WINDOWS_RESTORE_TEST']??'')!=='1'
        ||!preg_match('/^[1-9][0-9]{0,19}$/D',$environment['GITHUB_RUN_ID']??''))throw new RuntimeException('Only an explicitly disposable hosted qualification is permitted.');
    if(($s['schema']??null)!==1||($s['disposable']??null)!==true||($s['github_actions']??null)!==true
        ||($s['runner_environment']??'')!=='github-hosted'||($s['repository']??'')!=='embire2/openwebpbx'
        ||!preg_match('/^[a-f0-9]{24}$/D',$scope)||($s['scope']??'')!==$scope||($s['run_id']??'')!==$environment['GITHUB_RUN_ID']
        ||!in_array($s['role']??'', ['source','target'],true))throw new RuntimeException('The exact private restore qualification contract is required.');
    if(($installation['RestoreServer']??null)!==true||($installation['Completed']??null)!==true
        ||($installation['DomainName']??'')!=='windowsqa.example.invalid'||($installation['AdminEmail']??'')!==($s['admin_email']??'')
        ||!is_string($s['admin_email']??null)||!filter_var($s['admin_email'],FILTER_VALIDATE_EMAIL))throw new RuntimeException('A completed fictional restore server is required.');
    if(!is_string($s['service_name']??null)||strlen($s['service_name'])>120||!str_contains($s['service_name'],$scope)
        ||preg_match('/[\x00-\x1f\x7f]/',$s['service_name']))throw new RuntimeException('The PBX service name must contain the exact qualification scope.');
}

function restore_fixture_owned(array $owned,string $adminId): void {
    foreach(['service_uuid','domain_uuid','tenant_uuid','home_domain_uuid','owner_user_uuid'] as $key)
        if(!restore_fixture_uuid($owned[$key]??null))throw new RuntimeException('Owned service identifiers are required.');
    if($owned['domain_uuid']===$owned['home_domain_uuid']||$owned['owner_user_uuid']!==$adminId
        ||!preg_match('/^pbx-[a-f0-9]{12}\.company-[a-f0-9]{12}\.windowsqa\.example\.invalid$/D',$owned['domain_name']??''))throw new RuntimeException('The exact fictional tenant and realm are required.');
}

function restore_fixture_job(array $row,array $s): void {
    $id=$s['owned_job_uuid']??'';
    if(!restore_fixture_uuid($id)||($row['job_uuid']??'')!==$id||($row['domain_uuid']??'')!==($s['owned']['domain_uuid']??'')
        ||($row['kind']??'')!=='wakeup'||($row['target_number']??'')!=='8100'
        ||!in_array($row['internal_target']??null,[true,'t','1',1],true)
        ||($row['request_key']??'')!=='restore-qualification/'.$s['scope'].'/'.$id)throw new RuntimeException('Only the recorded internal qualification job is permitted.');
}

function restore_fixture_room(array $room,array $s): void {
    if(($room['domain_uuid']??'')!==($s['owned']['domain_uuid']??'')||($room['number']??'')!=='8100'
        ||!in_array($room['occupied']??null,[true,'t','1',1],true)
        ||!is_string($room['room_name']??null)||!str_contains($room['room_name'],$s['scope']))throw new RuntimeException('The normal checked-in qualification room is required.');
}

function restore_fixture_backup_command(array $row,string $id,string $admin,array $baseline,bool $scheduled): void {
    if(!restore_fixture_uuid($id)||in_array($id,$baseline,true)||($row['command_uuid']??'')!==$id
        ||!in_array($row['status']??'', ['completed','failed'],true)
        ||!array_key_exists('requested_by',$row)
        ||($scheduled?$row['requested_by']!==null:$row['requested_by']!==$admin))
        throw new RuntimeException('Only the exact completed owned manual or scheduled backup command is permitted.');
}

function restore_fixture_rows_digest(array $rows,string $key): string {
    // PostgreSQL physical order and JSON object key order are not evidence.
    $encoded=[];
    foreach($rows as $row)$encoded[]=json_encode(restore_fixture_canonical($row),JSON_THROW_ON_ERROR|JSON_UNESCAPED_SLASHES|JSON_PRESERVE_ZERO_FRACTION);
    sort($encoded,SORT_STRING);
    return restore_fixture_digest($encoded,$key);
}

function restore_fixture_meeting_rebind(PDO $db,array $rows,string $key): array {
    // The actual restore rebinds exactly three settings on the installer's
    // fixed private Meet profile. Validate each installation's configured
    // values before projecting ONLY their value cells. Every complete row,
    // UUID, other column and other profile remains in this table digest.
    $profile='cfb1c835-c30c-409b-bff7-a893a7e84df1';
    foreach([
        ['v_sip_profiles','sip_profile_uuid','sip_profile_name',$profile],
        ['v_conference_profiles','conference_profile_uuid','profile_name','b26410e0-b732-4c72-b9cf-cc045c395a57']
    ] as [$table,$id,$name,$expected]) {
        $query=$db->prepare("select $id,$name from $table where $id=? or $name='openweb-meet'");$query->execute([$expected]);$owned=$query->fetchAll(PDO::FETCH_ASSOC);
        if(count($owned)!==1||$owned[0][$id]!==$expected||$owned[0][$name]!=='openweb-meet')
            throw new RuntimeException('The disposable qualification requires the exact installed private meeting identities.');
    }
    $address=pbx_paths::address();if($address==='')$address=pbx_paths::host();
    $conf=(string)config::load()->get('switch.conf.dir');
    if((!filter_var($address,FILTER_VALIDATE_IP)&&!filter_var($address,FILTER_VALIDATE_DOMAIN,FILTER_FLAG_HOSTNAME))
        ||$conf===''||strpbrk($conf,"\r\n\0")!==false)throw new RuntimeException('The actual local meeting binding is invalid.');
    $expected=['rtp-ip'=>$address,'ext-rtp-ip'=>$address,'tls-cert-dir'=>rtrim($conf,'/\\').'/tls/openweb-meet'];
    $seen=[];$projected=[];
    foreach($rows as $row) {
        if(!is_object($row))throw new RuntimeException('Complete PostgreSQL meeting rows are required.');
        $copy=clone $row;
        if(($row->sip_profile_uuid??null)===$profile&&array_key_exists($row->sip_profile_setting_name??'', $expected)) {
            $name=$row->sip_profile_setting_name;
            if(isset($seen[$name])||!restore_fixture_uuid($row->sip_profile_setting_uuid??null)
                ||!in_array($row->sip_profile_setting_enabled??null,['true',true,'t'],true)
                ||($row->sip_profile_setting_value??null)!==$expected[$name])
                throw new RuntimeException('The private meeting value must match this installation before comparison.');
            $seen[$name]=true;$copy->sip_profile_setting_value='__openweb_restore_owned_meeting_binding__';
        }
        $projected[]=$copy;
    }
    if(count($seen)!==3)throw new RuntimeException('All three exact installer-owned meeting values are required.');
    return ['rows'=>count($rows),'hmac'=>restore_fixture_rows_digest($projected,$key),'binding'=>restore_fixture_digest($expected,$key)];
}

function restore_fixture_snapshot_shape(array $out): void {
    if(($out['schema']??null)!==1||!in_array($out['role']??'', ['source','target'],true)
        ||!preg_match('/^[a-f0-9]{24}$/D',$out['scope']??'')||!preg_match('/^[a-z0-9-]{1,48}$/D',$out['label']??''))throw new RuntimeException('Private snapshot identity is incomplete.');
    foreach(['target_owned'=>['database_identity','cluster','roles','memberships','role_settings','database_credentials'],
        'schema_metadata'=>['schema','tables','columns']] as $group=>$keys) {
        if(!is_array($out[$group]??null)||count($out[$group])!==count($keys))throw new RuntimeException('Private snapshot protection fields are incomplete.');
        foreach($keys as $name)if(!preg_match('/^[a-f0-9]{64}$/D',$out[$group][$name]??''))throw new RuntimeException('Private snapshot HMAC evidence is incomplete.');
    }
    foreach(['all_table_values','scoped_values'] as $group) {
        if(!is_array($out[$group]??null))throw new RuntimeException('Private database row evidence is incomplete.');
        foreach($out[$group] as $table=>$row)if(!preg_match('/^v_[a-z0-9_]+$/D',$table)||!is_array($row)
            ||!is_int($row['rows']??null)||$row['rows']<0||!preg_match('/^[a-f0-9]{64}$/D',$row['hmac']??''))throw new RuntimeException('Private row evidence is malformed.');
    }
    foreach(['v_pbx_backup_settings','v_pbx_backups','v_pbx_backup_commands','v_pbx_update_commands'] as $table)
        if(!isset($out['restore_projections'][$table]['rows'],$out['restore_projections'][$table]['hmac'])
            ||!is_int($out['restore_projections'][$table]['rows'])||!preg_match('/^[a-f0-9]{64}$/D',$out['restore_projections'][$table]['hmac']))
            throw new RuntimeException('Exact unchanged restore-transformation projections are required.');
    foreach(['v_users','v_domains','v_extensions','v_gateways','v_dialplans','v_voicemails','v_voicemail_messages','v_recordings','v_pbx_media','v_pbx_jobs','v_pbx_services','v_pbx_tenants','v_pbx_restore'] as $table)
        if(!isset($out['all_table_values'][$table]))throw new RuntimeException('A required PBX table is missing from the snapshot.');
    if(isset($out['all_table_values']['v_pbx_phone_health_recoveries'])){
        $proof=$out['health_recovery_restore']??null;
        if(!is_array($proof)||array_keys($proof)!==['rows','hmac','pending']||!is_int($proof['rows'])||!is_int($proof['pending'])
            ||$proof['rows']!==$out['all_table_values']['v_pbx_phone_health_recoveries']['rows']
            ||$proof['rows']<0||$proof['pending']<0||$proof['pending']>$proof['rows']||!preg_match('/^[a-f0-9]{64}$/D',$proof['hmac']))
            throw new RuntimeException('Exact restored phone recovery transformation evidence is required.');
    }
    if(isset($out['all_table_values']['v_sip_profile_settings'])) {
        $proof=$out['meeting_rebind']??null;
        if(!is_array($proof)||array_keys($proof)!==['rows','hmac','binding']||!is_int($proof['rows'])||$proof['rows']<3
            ||$proof['rows']!==$out['all_table_values']['v_sip_profile_settings']['rows']
            ||!preg_match('/^[a-f0-9]{64}$/D',$proof['hmac'])||!preg_match('/^[a-f0-9]{64}$/D',$proof['binding']))
            throw new RuntimeException('The complete validated local meeting rebind evidence is required.');
    }
    if(!array_key_exists('source_phone_tuples',$out)||($out['source_phone_tuples']!==null&&!preg_match('/^[a-f0-9]{64}$/D',$out['source_phone_tuples'])))throw new RuntimeException('Private phone preservation evidence is malformed.');
}

function restore_fixture_schema_queries(): array {
    $acl="(select coalesce(jsonb_agg(jsonb_build_object('grantor',pg_get_userbyid(a.grantor),'grantee',case when a.grantee=0 then 'PUBLIC' else pg_get_userbyid(a.grantee) end,'privilege',a.privilege_type,'grantable',a.is_grantable) order by case when a.grantee=0 then 'PUBLIC' else pg_get_userbyid(a.grantee) end,pg_get_userbyid(a.grantor),a.privilege_type,a.is_grantable),'[]'::jsonb) from aclexplode(%s) a) grants";
    return ['schema'=>"select n.nspname,pg_get_userbyid(n.nspowner) owner_name,".sprintf($acl,"coalesce(n.nspacl,acldefault('n',n.nspowner))")." from pg_namespace n where n.nspname='public'",
        'tables'=>"select c.relname,pg_get_userbyid(c.relowner) owner_name,c.relkind,".sprintf($acl,"coalesce(c.relacl,acldefault('r',c.relowner))")." from pg_class c join pg_namespace n on n.oid=c.relnamespace where n.nspname='public' and c.relkind in ('r','p') order by c.relname",
        'columns'=>"select table_name,column_name,ordinal_position,data_type,udt_name,is_nullable,column_default from information_schema.columns where table_schema='public' order by table_name,ordinal_position"];
}

function restore_fixture_private_path(string $path,string $root): string {
    $directory=realpath(dirname($path));$base=realpath($root);$resolved=realpath($path);
    if($directory===false||$base===false||$resolved===false||!is_file($path)||is_link($path)||basename($path)!=='input.json'
        ||strtolower(str_replace('\\','/',dirname($directory)))!==strtolower(str_replace('\\','/',$base))
        ||!preg_match('/^[a-f0-9]{24}$/D',basename($directory))
        ||strtolower(str_replace('\\','/',$resolved))!==strtolower(str_replace('\\','/',$directory.'/input.json')))
        throw new RuntimeException('An ordinary private scoped input is required.');
    for($parent=$directory;;$parent=dirname($parent)) {
        if(is_link($parent))throw new RuntimeException('Qualification directory links are refused.');
        if(strtolower(str_replace('\\','/',$parent))===strtolower(str_replace('\\','/',$base)))break;
        if(dirname($parent)===$parent)throw new RuntimeException('Qualification input escaped its private root.');
    }
    return $directory;
}

function restore_fixture_failure_record(Throwable $error,string $input,string $action,string $step,string $root): bool {
    if($action!=='cleanup')return false;
    try {
        $directory=restore_fixture_private_path($input,$root);
        if(strtolower(str_replace('\\','/',dirname($input)))!==strtolower(str_replace('\\','/',$directory)))return false;
        $steps=['initialization','owned_lookup','gateway_guard','native_quiescence','native_contacts','backup_inventory','owned_rows_delete','update_commands_delete','backup_commands_delete','drafts_delete','archive_files_delete','cache_cleanup','native_reload','factory_guard','input_commit'];
        if(!in_array($step,$steps,true))return false;
        $reasons=[
            'Exactly one normal-setup owned PBX is required.'=>'owned_service_lookup',
            'The recorded source service identity changed.'=>'owned_service_lookup',
            'Cleanup refuses any enabled or registering gateway.'=>'enabled_gateway',
            'Cleanup refuses active native calls.'=>'active_calls',
            'Owned phone identity changed.'=>'phone_identity',
            'Unregister the exact owned peer before cleanup.'=>'live_contact',
            'A recorded owned backup command is missing.'=>'missing_backup_command',
            'Only the exact completed owned manual or scheduled backup command is permitted.'=>'backup_command_guard',
            'Only exact new owned encrypted backup metadata may be removed.'=>'backup_metadata_guard',
            'Linked backup cleanup is refused.'=>'backup_link',
            'Owned archive integrity changed before cleanup.'=>'backup_integrity',
            'An unowned original command cannot be removed.'=>'original_command',
            'Only exact completed qualification commands may be removed.'=>'command_ownership',
            'A recorded owned backup command changed.'=>'backup_command_changed',
            'An original draft cannot be removed.'=>'original_draft',
            'Only recorded owned drafts may be removed.'=>'draft_ownership',
            'An exact owned encrypted backup file could not be removed.'=>'archive_unlink',
            'A distinct empty factory is required.'=>'factory_not_empty',
        ];
        $type=get_class($error);$types=['RuntimeException','PDOException','JsonException','TypeError','ValueError','Error','Exception'];
        if(!in_array($type,$types,true))$type='external_error';
        $reason=$reasons[$error->getMessage()]??match($type){'PDOException'=>'database_error','JsonException'=>'json_error','TypeError','ValueError'=>'type_error','RuntimeException'=>'runtime_guard',default=>'external_error'};
        $source=basename(str_replace('\\','/',$error->getFile()));
        if(!in_array($source,['windows-restore-qualification.php','database.php','pbx_paths.php','cache.php','event_socket.php','config.php'],true))$source='external_component';
        $line=$error->getLine();if($line<1||$line>=1000000)return false;
        $raw=json_encode(['schema'=>1,'action'=>$action,'step'=>$step,'reason'=>$reason,'error_type'=>$type,'source_basename'=>$source,'source_line'=>$line],JSON_THROW_ON_ERROR);
        if(strlen($raw)>2048)return false;
        $stream=@fopen($input.'.cleanup.failure.json','xb');if(!$stream)return false;
        try{return fwrite($stream,$raw)===strlen($raw)&&fflush($stream);}finally{fclose($stream);}
    }catch(Throwable $ignored){return false;}
}

function restore_fixture_write(string $path,array $value): void {
    if(is_link($path)||(file_exists($path)&&!is_file($path)))throw new RuntimeException('Private evidence must be an ordinary file.');
    $raw=json_encode($value,JSON_THROW_ON_ERROR|JSON_PRETTY_PRINT|JSON_UNESCAPED_SLASHES);
    if(strlen($raw)>32*1024*1024)throw new RuntimeException('Private qualification evidence exceeds its bound.');
    $new=$path.'.new-'.bin2hex(random_bytes(8));$stream=fopen($new,'xb');
    if(!$stream)throw new RuntimeException('Private evidence could not be created.');
    try{if(fwrite($stream,$raw)!==strlen($raw)||!fflush($stream))throw new RuntimeException('Private evidence was not completely written.');}
    finally{fclose($stream);}
    if(!rename($new,$path)){unlink($new);throw new RuntimeException('Private evidence could not be committed.');}
}

function restore_fixture_media(string $path,array $roots): array {
    // Read evidence of media produced by a real native call; never invent WAVs.
    if(!is_file($path)||is_link($path))return ['exists'=>false];
    $file=realpath($path);$allowed=false;
    foreach($roots as $root){$root=realpath($root);if($root!==false&&str_starts_with(strtolower(str_replace('\\','/',$file)),strtolower(rtrim(str_replace('\\','/',$root),'/')).'/'))$allowed=true;}
    if(!$allowed)throw new RuntimeException('Indexed media escaped owned storage.');
    $size=filesize($file);if($size===false||$size>256*1024*1024)throw new RuntimeException('Owned indexed media exceeds its bound.');
    return ['exists'=>true,'path'=>str_replace('\\','/',$file),'size'=>$size,'sha256'=>hash_file('sha256',$file)];
}

function restore_fixture_main(array $argv): void {
    if(PHP_SAPI!=='cli'||PHP_OS_FAMILY!=='Windows')exit(2);
    $GLOBALS['restore_fixture_failure_step']='initialization';
    $environment=[];foreach(['OPENWEB_WINDOWS_RESTORE_TEST','GITHUB_ACTIONS','RUNNER_ENVIRONMENT','GITHUB_REPOSITORY','GITHUB_RUN_ID'] as $name)$environment[$name]=getenv($name)?:'';
    // Refuse before loading any installed application or credential file.
    if($environment['OPENWEB_WINDOWS_RESTORE_TEST']!=='1'||$environment['GITHUB_ACTIONS']!=='true'
        ||$environment['RUNNER_ENVIRONMENT']!=='github-hosted'||$environment['GITHUB_REPOSITORY']!=='embire2/openwebpbx')exit(2);
    $action=$argv[1]??'';
    if(!in_array($action,['baseline','discover','status','snapshot','seed-job','seed-health','job-status','cleanup'],true))throw new RuntimeException('Unknown private restore fixture operation.');
    require 'C:/OpenWebPBX/web/resources/require.php';
    $path=$argv[2]??'';$directory=restore_fixture_private_path($path,pbx_paths::state().'/restore-qualification');
    if(filesize($path)>2*1024*1024)throw new RuntimeException('Private fixture input exceeds its bound.');
    $s=json_decode(file_get_contents($path),true,64,JSON_THROW_ON_ERROR);
    $installation=json_decode(file_get_contents(pbx_paths::state().'/installation.json'),true,32,JSON_THROW_ON_ERROR);
    restore_fixture_contract($s,$environment,$installation,basename($directory));
    $db=$database->db;$db->setAttribute(PDO::ATTR_ERRMODE,PDO::ERRMODE_EXCEPTION);
    $q=static function(string $sql,array $args=[])use($db):PDOStatement{
        $p=$db->prepare($sql);foreach(array_values($args) as $i=>$value)$p->bindValue($i+1,$value,$value===null?PDO::PARAM_NULL:(is_bool($value)?PDO::PARAM_BOOL:(is_int($value)?PDO::PARAM_INT:PDO::PARAM_STR)));$p->execute();return $p;
    };
    $phones=static function(array $c,string $domain)use($q):array {
        $users=[];if(count($c['users']??[])!==2)throw new RuntimeException('The normal setup must contain exactly two fictional users.');
        foreach(['8100','8101'] as $number) {
            $u=$c['users'][$number]??null;
            if(!$u||!restore_fixture_uuid($u['extension_uuid']??null)||!preg_match('/^[A-Za-z0-9_.+%-]{1,128}$/D',$u['auth_id']??''))throw new RuntimeException('The original normal-setup phone identity is missing.');
            $native=$q('select extension_uuid,extension,password from v_extensions where domain_uuid=? and extension_uuid=?',[$domain,$u['extension_uuid']])->fetch(PDO::FETCH_ASSOC);
            if(!$native||$native['extension']!==$u['auth_id']||!is_string($native['password'])||$native['password']==='')throw new RuntimeException('Native and normal-setup phone credentials differ.');
            if(!restore_fixture_uuid($u['voicemail_uuid']??null))throw new RuntimeException('The original normal-setup mailbox identity is missing.');
            $mailbox=$q('select voicemail_password from v_voicemails where domain_uuid=? and voicemail_uuid=?',[$domain,$u['voicemail_uuid']])->fetch(PDO::FETCH_ASSOC);
            if(!$mailbox||$mailbox['voicemail_password']!==null||pbx_voicemail_policy::withoutPins($u)!==$u)throw new RuntimeException('The normal PIN-free mailbox is missing or contains a retired credential.');
            $users[]=['number'=>$number,'auth'=>$native['extension'],'password'=>$native['password'],'extension_uuid'=>$native['extension_uuid'],'voicemail_uuid'=>$u['voicemail_uuid'],'tone_hz'=>$number==='8100'?440:550];
        }
        return $users;
    };
    $save=static function()use(&$s,$path):void{restore_fixture_write($path,$s);};
    $factory=static function()use($q):void{
        foreach(['v_extensions','v_pbx_tenants','v_pbx_services','v_pbx_restore','v_gateways','v_call_center_queues','v_pbx_jobs','v_recordings','v_voicemail_messages','v_pbx_media'] as $table)
            if((int)$q('select count(*) from '.$table)->fetchColumn()!==0)throw new RuntimeException('A distinct empty factory is required.');
        if((int)$q('select count(*) from v_users')->fetchColumn()!==1||(int)$q('select count(*) from v_domains')->fetchColumn()!==1)throw new RuntimeException('A distinct empty factory is required.');
    };
    $adminRows=$q('select user_uuid,domain_uuid,username,user_email,password,salt,user_enabled from v_users where username=?',[$s['admin_email']])->fetchAll(PDO::FETCH_ASSOC);
    if(count($adminRows)!==1||!restore_fixture_uuid($adminRows[0]['user_uuid'])||!restore_fixture_uuid($adminRows[0]['domain_uuid']))throw new RuntimeException('The actual current administrator is required.');
    $admin=$adminRows[0];
    if($action==='baseline') {
        if(isset($s['baseline']))throw new RuntimeException('A baseline cannot replace existing original evidence.');
        $factory();$s['baseline']=['admin'=>$admin,'domains'=>$q('select * from v_domains order by domain_uuid')->fetchAll(PDO::FETCH_ASSOC),
            'drafts'=>$q('select draft_uuid from v_pbx_setup_drafts order by draft_uuid')->fetchAll(PDO::FETCH_COLUMN),
            'update_commands'=>$q('select command_uuid from v_pbx_update_commands order by command_uuid')->fetchAll(PDO::FETCH_COLUMN),
            'backup_commands'=>$q('select command_uuid from v_pbx_backup_commands order by command_uuid')->fetchAll(PDO::FETCH_COLUMN)];
        $s['baseline']['backups']=$q('select backup_uuid from v_pbx_backups order by backup_uuid')->fetchAll(PDO::FETCH_COLUMN);
        $save();echo "{\"factory_empty\":true,\"baseline_captured\":true}\n";return;
    }
    if(!isset($s['baseline']['admin']))throw new RuntimeException('An independent original baseline is required.');
    $lookup=static function()use($q,$s,$admin):array{
        $rows=$q('select s.service_uuid,s.domain_uuid,s.tenant_uuid,d.domain_name,t.home_domain_uuid,t.owner_user_uuid from v_pbx_services s join v_domains d using(domain_uuid) join v_pbx_tenants t using(tenant_uuid) where s.service_name=? and t.owner_user_uuid=?',[$s['service_name'],$admin['user_uuid']])->fetchAll(PDO::FETCH_ASSOC);
        if(count($rows)!==1)throw new RuntimeException('Exactly one normal-setup owned PBX is required.');
        restore_fixture_owned($rows[0],$admin['user_uuid']);
        if(isset($s['owned'])&&restore_fixture_canonical($s['owned'])!==restore_fixture_canonical($rows[0]))throw new RuntimeException('The recorded source service identity changed.');
        return $rows[0];
    };
    if($action==='discover') {
        $s['owned']=$lookup();$s['domain']=$s['owned']['domain_uuid'];$s['realm']=$s['owned']['domain_name'];
        unset($_SESSION['permissions']);
        $permissions=(new permissions($database,$admin['domain_uuid'],$admin['user_uuid']))->get_permissions();
        if(empty($permissions['pbx_tenant_manage'])||empty($permissions['pbx_service_create']))throw new RuntimeException('The current genuine instance administrator is required.');
        $_SESSION=['authorized'=>true,'user_uuid'=>$admin['user_uuid'],'domain_uuid'=>$s['domain'],'domain_name'=>$s['realm'],'user'=>['domain_uuid'=>$admin['domain_uuid']],'permissions'=>$permissions];
        $c=(new pbx_admin($db))->config();$users=$phones($c,$s['domain']);
        if(isset($s['users'])&&restore_fixture_canonical($s['users'])!==restore_fixture_canonical($users))throw new RuntimeException('The restored original phone tuples changed.');
        $s['users']=$users;$configuration=config::load();
        $host=$configuration->get('switch.event_socket.host',null)??$configuration->get('event_socket.ip_address',null)??'127.0.0.1';
        if(!in_array($host,['127.0.0.1','localhost'],true))throw new RuntimeException('Only the disposable loopback engine listener is permitted.');
        $port=$configuration->get('switch.event_socket.port',null)??$configuration->get('event_socket.port',null)??'8021';
        $password=$configuration->get('switch.event_socket.password',null)??$configuration->get('event_socket.password',null);
        if(!ctype_digit($port)||(int)$port<1||(int)$port>65535||!is_string($password)||$password==='')throw new RuntimeException('The actual private engine listener is required.');
        $s['event_socket']=['host'=>$host,'port'=>(int)$port,'password'=>$password];
        $runtime=json_decode(file_get_contents(pbx_paths::state().'/runtime.json'),true,64,JSON_THROW_ON_ERROR);
        if(!is_array($runtime))throw new RuntimeException('The private installed runtime is missing.');
        $s['runtime']=$runtime;$save();echo "{\"normal_setup_discovered\":true,\"phones\":2,\"mailbox\":true}\n";return;
    }
    if($action==='snapshot') {
        $label=$s['snapshot_label']??'';
        if(!is_string($label)||!preg_match('/^[a-z0-9-]{1,48}$/D',$label))throw new RuntimeException('An exact private snapshot label is required.');
        $keyFile=$directory.'/audit.key';if(!is_file($keyFile)||is_link($keyFile)||filesize($keyFile)!==32)throw new RuntimeException('The independent private audit key is required.');
        $key=file_get_contents($keyFile);$digest=static fn(mixed $v):string=>restore_fixture_digest($v,$key);
        $adminDb=new PDO('pgsql:host=127.0.0.1;port=5433;dbname=fusionpbx','postgres',$installation['PostgresPassword'],[PDO::ATTR_ERRMODE=>PDO::ERRMODE_EXCEPTION]);
        $aq=static fn(string $sql):array=>$adminDb->query($sql)->fetchAll(PDO::FETCH_ASSOC);
        $configuration=config::load();$credentials=[];
        foreach(['type','host','port','name','username','password'] as $field)$credentials[$field]=$configuration->get('database.0.'.$field,null);
        $credentials['installation_database_password']=$installation['DatabasePassword']??null;$credentials['installation_postgres_password']=$installation['PostgresPassword']??null;
        $out=['schema'=>1,'label'=>$label,'scope'=>$s['scope'],'role'=>$s['role'],'target_owned'=>[
            'database_identity'=>$digest($aq("select datname,oid,datdba,datacl::text from pg_database where datname=current_database()")),
            'cluster'=>$digest($aq('select system_identifier,pg_control_version,catalog_version_no from pg_control_system()')),
            'roles'=>$digest($aq('select * from pg_authid order by oid')),'memberships'=>$digest($aq('select * from pg_auth_members order by roleid,member,grantor')),
            'role_settings'=>$digest($aq('select * from pg_db_role_setting order by setdatabase,setrole')),'database_credentials'=>$digest($credentials)],
            // Source and target clusters may allocate different role OIDs.
            // Compare schema ownership/grants by names while target_owned
            // retains the replacement's exact numeric identities separately.
            'schema_metadata'=>[],
            'all_table_values'=>[],'scoped_values'=>[],'restore_projections'=>[],'source_phone_tuples'=>null];
        // Only these explicit lifecycle fields change during native restore.
        // Password/connection secrets and every other backup setting stay exact.
        $projectionQueries=[
            'v_pbx_backup_settings'=>"select to_jsonb(t)-'enabled'-'sftp_enabled' from v_pbx_backup_settings t",
            'v_pbx_backups'=>'select row_to_json(t) from (select backup_uuid,command_uuid,filename,include_media,app_version,created_at from v_pbx_backups) t',
            'v_pbx_backup_commands'=>'select row_to_json(t) from (select command_uuid,action,backup_uuid,requested_by,created_at from v_pbx_backup_commands) t',
            'v_pbx_update_commands'=>'select row_to_json(t) from (select command_uuid,action,requested_by,created_at from v_pbx_update_commands) t'];
        foreach($projectionQueries as $table=>$sql){$rows=array_map(static fn(string $r):mixed=>json_decode($r,false,512,JSON_THROW_ON_ERROR),$q($sql)->fetchAll(PDO::FETCH_COLUMN));$out['restore_projections'][$table]=['rows'=>count($rows),'hmac'=>restore_fixture_rows_digest($rows,$key)];}
        foreach(restore_fixture_schema_queries() as $name=>$sql)$out['schema_metadata'][$name]=$digest($aq($sql));
        $owned=isset($s['owned'])?$lookup():null;
        if($owned) {
            $c=json_decode($q('select config from v_pbx_restore where domain_uuid=?',[$owned['domain_uuid']])->fetchColumn(),true,512,JSON_THROW_ON_ERROR);
            $actualPhones=$phones($c,$owned['domain_uuid']);
            if(!isset($s['users'])||restore_fixture_canonical($actualPhones)!==restore_fixture_canonical($s['users']))throw new RuntimeException('The actual recorded native phone tuples changed.');
            $out['source_phone_tuples']=$digest($actualPhones);
        }
        foreach($q("select tablename from pg_tables where schemaname='public' order by tablename")->fetchAll(PDO::FETCH_COLUMN) as $table) {
            if(!preg_match('/^v_[a-z0-9_]+$/D',$table))throw new RuntimeException('An unexpected public table prevents complete qualification evidence.');
            $sql='select row_to_json(t) from "'.$table.'" t';$rows=array_map(static fn(string $r):mixed=>json_decode($r,false,512,JSON_THROW_ON_ERROR),$q($sql)->fetchAll(PDO::FETCH_COLUMN));
            $out['all_table_values'][$table]=['rows'=>count($rows),'hmac'=>restore_fixture_rows_digest($rows,$key)];
            if($table==='v_sip_profile_settings')$out['meeting_rebind']=restore_fixture_meeting_rebind($db,$rows,$key);
            if($table==='v_pbx_phone_health_recoveries'){
                // Every column and row is included. Only the documented
                // pending -> refused execution-state transform is permitted.
                $projected=[];$pending=0;
                foreach($rows as $row){$copy=clone $row;if($copy->status==='pending'){$copy->status='refused';$pending++;}$projected[]=$copy;}
                $out['health_recovery_restore']=['rows'=>count($rows),'hmac'=>restore_fixture_rows_digest($projected,$key),'pending'=>$pending];
            }
            if(!$owned)continue;
            $columns=$q("select column_name from information_schema.columns where table_schema='public' and table_name=? and column_name in ('domain_uuid','tenant_uuid')",[$table])->fetchAll(PDO::FETCH_COLUMN);
            $where=[];$parameters=[];
            if(in_array('domain_uuid',$columns,true)){$where[]='domain_uuid in (?,?)';$parameters[]=$owned['domain_uuid'];$parameters[]=$owned['home_domain_uuid'];}
            if(in_array('tenant_uuid',$columns,true)){$where[]='tenant_uuid=?';$parameters[]=$owned['tenant_uuid'];}
            if(!$where)continue;
            $rows=array_map(static fn(string $r):mixed=>json_decode($r,false,512,JSON_THROW_ON_ERROR),$q($sql.' where '.implode(' or ',$where),$parameters)->fetchAll(PDO::FETCH_COLUMN));
            $out['scoped_values'][$table]=['rows'=>count($rows),'hmac'=>restore_fixture_rows_digest($rows,$key)];
        }
        restore_fixture_snapshot_shape($out);restore_fixture_write($directory.'/'.$label.'-database.json',$out);
        echo json_encode(['private_hmac_inventory'=>true,'tables'=>count($out['all_table_values']),'scoped_tables'=>count($out['scoped_values']),'target_identity_separate'=>true],JSON_THROW_ON_ERROR),PHP_EOL;return;
    }
    $GLOBALS['restore_fixture_failure_step']='owned_lookup';
    $owned=$lookup();$domain=$owned['domain_uuid'];$realm=$owned['domain_name'];
    if($action==='seed-health'){
        if($s['role']!=='source'||isset($s['health_recovery_fixture'])
            ||(int)$q('select count(*) from v_pbx_phone_health_recoveries where domain_uuid=?',[$domain])->fetchColumn()!==0)
            throw new RuntimeException('Only an empty owned source health history may be seeded.');
        $instance=pbx_phone_health::instanceId();if(!is_string($instance)||!preg_match('/^[a-f0-9]{64}$/D',$instance))throw new RuntimeException('The protected source health identity is required.');
        $db->beginTransaction();
        try{foreach(['pending','pending','acknowledged','refused','dispatch_failed'] as $status)
            $q("insert into v_pbx_phone_health_recoveries(recovery_uuid,domain_uuid,actor_uuid,block_uuid,source_address,status,instance_id,acknowledged_at) values(?,?,?,?,?::inet,?,?,case when ?='acknowledged' then now() else null end)",
                [uuid(),$domain,$admin['user_uuid'],uuid(),'192.0.2.252',$status,$instance,$status]);$db->commit();}
        catch(Throwable $error){if($db->inTransaction())$db->rollBack();throw $error;}
        $s['health_recovery_fixture']=true;$save();echo '{"owned_health_history":5,"pending":2,"firewall_actions":0}',PHP_EOL;return;
    }
    if($action==='status') {
        $status=(string)event_socket::api('sofia status profile internal');$bind=preg_match('/^\s*SIP-IP\s+([0-9.]+)\s*$/m',$status,$match)?$match[1]:null;
        $messages=$q('select m.voicemail_message_uuid,m.message_length,m.voicemail_uuid,v.voicemail_id from v_voicemail_messages m join v_voicemails v using(voicemail_uuid,domain_uuid) where m.domain_uuid=? order by m.voicemail_message_uuid',[$domain])->fetchAll(PDO::FETCH_ASSOC);
        $mediaRoots=[pbx_paths::media().'/'.$domain,pbx_paths::voicemail().'/default/'.$realm,pbx_paths::storage().'/recordings/'.$realm];
        foreach($messages as &$message){$file=pbx_paths::voicemail().'/default/'.$realm.'/'.$message['voicemail_id'].'/msg_'.$message['voicemail_message_uuid'].'.wav';$message['media']=restore_fixture_media($file,$mediaRoots);}unset($message);
        $recordings=$q("select media_uuid,title,owner_number,duration,file_path from v_pbx_media where domain_uuid=? and category='recordings' order by media_uuid",[$domain])->fetchAll(PDO::FETCH_ASSOC);
        foreach($recordings as &$recording){$recording['media']=restore_fixture_media($recording['file_path'],$mediaRoots);unset($recording['file_path']);}unset($recording);
        echo json_encode(['bind'=>$bind,'domain'=>$domain,'realm'=>$realm,'jobs'=>$q('select job_uuid,kind,state,attempts,last_result,call_uuid,due_at,expires_at,request_key from v_pbx_jobs where domain_uuid=? order by job_uuid',[$domain])->fetchAll(PDO::FETCH_ASSOC),
            'voicemail'=>$messages,'recordings'=>$recordings,'gateways'=>$q('select gateway_uuid,enabled,register,proxy from v_gateways where domain_uuid=? order by gateway_uuid',[$domain])->fetchAll(PDO::FETCH_ASSOC)],JSON_THROW_ON_ERROR),PHP_EOL;return;
    }
    if($action==='seed-job'||$action==='job-status') {
        if($action==='seed-job') {
            $room=$q('select domain_uuid,number,room_name,occupied from v_pbx_hotel_rooms where domain_uuid=? and number=?',[$domain,'8100'])->fetch(PDO::FETCH_ASSOC);
            if(!$room)throw new RuntimeException('Create and check in the owned room through normal HTTPS first.');
            restore_fixture_room($room,$s);
        }
        if($action==='seed-job'&&!isset($s['owned_job_uuid'])) {
            if($s['role']!=='source'||($s['job_due']??false)!==false)throw new RuntimeException('Only the source can create the original future job.');
            if((int)$q('select count(*) from v_pbx_jobs where domain_uuid=?',[$domain])->fetchColumn()!==0)throw new RuntimeException('The fictional source already contains a job.');
            $id=uuid();$s['owned_job_uuid']=$id;$save();
            $q("insert into v_pbx_jobs(job_uuid,domain_uuid,kind,target_number,internal_target,request_key,due_at,expires_at,max_attempts) values(?,?,'wakeup','8100',true,?,now()+interval '1 day',now()+interval '2 days',1)",[$id,$domain,'restore-qualification/'.$s['scope'].'/'.$id]);
        }
        $id=$s['owned_job_uuid']??'';if(!restore_fixture_uuid($id))throw new RuntimeException('A recorded original qualification job is required.');
        $row=$q('select * from v_pbx_jobs where job_uuid=? and domain_uuid=?',[$id,$domain])->fetch(PDO::FETCH_ASSOC);
        if(!$row)throw new RuntimeException('The original restored job is missing.');restore_fixture_job($row,$s);
        if($action==='seed-job'&&($s['job_due']??false)===true) {
            if($s['role']!=='target'||$row['state']!=='waiting'||(int)$row['attempts']!==0)throw new RuntimeException('Only the unchanged restored job can become due.');
            $updated=$q("update v_pbx_jobs set due_at=now(),expires_at=now()+interval '20 minutes' where job_uuid=? and domain_uuid=? and state='waiting' and attempts=0 and request_key=?",[$id,$domain,$row['request_key']]);
            if($updated->rowCount()!==1)throw new RuntimeException('The qualification job changed concurrently.');
            $row=$q('select * from v_pbx_jobs where job_uuid=? and domain_uuid=?',[$id,$domain])->fetch(PDO::FETCH_ASSOC);restore_fixture_job($row,$s);
        }
        $future=$q('select due_at>now() from v_pbx_jobs where job_uuid=? and domain_uuid=?',[$id,$domain])->fetchColumn();
        echo json_encode(['job_uuid'=>$id,'kind'=>$row['kind'],'state'=>$row['state'],'attempts'=>(int)$row['attempts'],'last_result'=>$row['last_result'],'call_uuid'=>$row['call_uuid'],'future'=>in_array($future,[true,'t','1',1],true),'internal_target'=>true],JSON_THROW_ON_ERROR),PHP_EOL;return;
    }
    if($action==='cleanup') {
        $GLOBALS['restore_fixture_failure_step']='gateway_guard';
        // No unqualified gateway or live call can be hidden by fixture removal.
        foreach($q('select enabled,register from v_gateways where domain_uuid=?',[$domain])->fetchAll(PDO::FETCH_ASSOC) as $gateway)
            if(filter_var($gateway['enabled'],FILTER_VALIDATE_BOOLEAN)||filter_var($gateway['register'],FILTER_VALIDATE_BOOLEAN))throw new RuntimeException('Cleanup refuses any enabled or registering gateway.');
        if(($s['cleanup_native']??false)===true) {
            $GLOBALS['restore_fixture_failure_step']='native_quiescence';
            $channels=json_decode(event_socket::api('show channels as json'),true,32,JSON_THROW_ON_ERROR);
            if(!isset($channels['row_count'])||(int)$channels['row_count']!==0)throw new RuntimeException('Cleanup refuses active native calls.');
            foreach($q('select call_center_agent_uuid from v_call_center_agents where domain_uuid=?',[$domain])->fetchAll(PDO::FETCH_COLUMN) as $id)
                if(restore_fixture_uuid($id))event_socket::api('callcenter_config agent del '.$id);
            foreach($q('select queue_extension from v_call_center_queues where domain_uuid=?',[$domain])->fetchAll(PDO::FETCH_COLUMN) as $number)
                if(preg_match('/^[0-9]{2,10}$/D',$number))event_socket::api('callcenter_config queue unload '.$number.'@'.$realm);
            foreach($q('select gateway_uuid from v_gateways where domain_uuid=?',[$domain])->fetchAll(PDO::FETCH_COLUMN) as $id)
                if(restore_fixture_uuid($id))event_socket::api('sofia profile external killgw '.$id);
            $GLOBALS['restore_fixture_failure_step']='native_contacts';
            foreach($s['users']??[] as $user) {
                if(!preg_match('/^[A-Za-z0-9_.+%-]{1,128}$/D',$user['auth']??''))throw new RuntimeException('Owned phone identity changed.');
                if(!str_starts_with(trim(event_socket::api('sofia_contact '.$user['auth'].'@'.$realm)),'error/'))throw new RuntimeException('Unregister the exact owned peer before cleanup.');
            }
        }
        $GLOBALS['restore_fixture_failure_step']='backup_inventory';$backupFiles=[];
        foreach([false=>'owned_backup_commands',true=>'owned_scheduled_backup_commands'] as $scheduled=>$list)foreach($s[$list]??[] as $id) {
            $row=$q('select command_uuid,status,requested_by from v_pbx_backup_commands where command_uuid=?',[$id])->fetch(PDO::FETCH_ASSOC);
            if(!$row)throw new RuntimeException('A recorded owned backup command is missing.');
            restore_fixture_backup_command($row,$id,$admin['user_uuid'],$s['baseline']['backup_commands'],(bool)$scheduled);
            foreach($q('select backup_uuid,filename,sha256 from v_pbx_backups where command_uuid=?',[$id])->fetchAll(PDO::FETCH_ASSOC) as $backup) {
                if(!restore_fixture_uuid($backup['backup_uuid'])||in_array($backup['backup_uuid'],$s['baseline']['backups']??[],true)
                    ||$backup['filename']!==$backup['backup_uuid'].'.owpbx')throw new RuntimeException('Only exact new owned encrypted backup metadata may be removed.');
                foreach(['automatic-backups','backup-downloads'] as $child) {
                    $directory=pbx_paths::state().'/'.$child;$path=$directory.'/'.$backup['filename'];
                    if(is_link($directory)||is_link($path))throw new RuntimeException('Linked backup cleanup is refused.');
                    if(file_exists($path)) {
                        if(!is_file($path)||realpath(dirname($path))!==realpath($directory)||!preg_match('/^[a-f0-9]{64}$/D',$backup['sha256']??'')
                            ||hash_file('sha256',$path)!==$backup['sha256'])throw new RuntimeException('Owned archive integrity changed before cleanup.');
                        $backupFiles[]=$path;
                    }
                }
            }
        }
        $GLOBALS['restore_fixture_failure_step']='owned_rows_delete';$db->beginTransaction();
        try {
            // completed_domain_uuid cascades when its owned domain is removed;
            // validate the recorded draft while its original row still exists.
            $GLOBALS['restore_fixture_failure_step']='drafts_delete';
            foreach($s['owned_draft_ids']??[] as $id) {
                if(!restore_fixture_uuid($id)||in_array($id,$s['baseline']['drafts'],true))throw new RuntimeException('An original draft cannot be removed.');
                $row=$q('select user_uuid from v_pbx_setup_drafts where draft_uuid=?',[$id])->fetch(PDO::FETCH_ASSOC);
                if(!$row||$row['user_uuid']!==$admin['user_uuid'])throw new RuntimeException('Only recorded owned drafts may be removed.');
                $q('delete from v_pbx_setup_drafts where draft_uuid=? and user_uuid=?',[$id,$admin['user_uuid']]);
            }
            $GLOBALS['restore_fixture_failure_step']='owned_rows_delete';
            foreach(['domain_uuid'=>[$domain,$owned['home_domain_uuid']],'tenant_uuid'=>[$owned['tenant_uuid']]] as $column=>$ids) {
                $tables=$q("select distinct c.table_name from information_schema.columns c join information_schema.tables t using(table_schema,table_name) where c.table_schema='public' and c.column_name=? and c.table_name like 'v_%' and t.table_type='BASE TABLE' order by c.table_name",[$column])->fetchAll(PDO::FETCH_COLUMN);
                foreach($tables as $table)if($table!=='v_domains'&&preg_match('/^v_[a-z0-9_]+$/D',$table))foreach($ids as $id)$q('delete from '.$table.' where '.$column.'=?',[$id]);
            }
            foreach([$domain,$owned['home_domain_uuid']] as $id)$q('delete from v_domains where domain_uuid=?',[$id]);
            // IDs are captured by the parent immediately after normal HTTPS;
            // never delete a global row merely because it is new or same user.
            $GLOBALS['restore_fixture_failure_step']='update_commands_delete';
            foreach(['update'=>'v_pbx_update_commands'] as $kind=>$table)foreach($s['owned_'.$kind.'_commands']??[] as $id) {
                if(!restore_fixture_uuid($id)||in_array($id,$s['baseline'][$kind.'_commands']??[],true))throw new RuntimeException('An unowned original command cannot be removed.');
                $row=$q('select status,requested_by from '.$table.' where command_uuid=?',[$id])->fetch(PDO::FETCH_ASSOC);
                if(!$row||!in_array($row['status'],['completed','failed'],true)||$row['requested_by']!==$admin['user_uuid'])throw new RuntimeException('Only exact completed qualification commands may be removed.');
                $q('delete from '.$table.' where command_uuid=? and requested_by=?',[$id,$admin['user_uuid']]);
            }
            $GLOBALS['restore_fixture_failure_step']='backup_commands_delete';
            foreach([false=>'owned_backup_commands',true=>'owned_scheduled_backup_commands'] as $scheduled=>$list)foreach($s[$list]??[] as $id) {
                $row=$q('select command_uuid,status,requested_by from v_pbx_backup_commands where command_uuid=? for update',[$id])->fetch(PDO::FETCH_ASSOC);
                if(!$row)throw new RuntimeException('A recorded owned backup command changed.');
                restore_fixture_backup_command($row,$id,$admin['user_uuid'],$s['baseline']['backup_commands'],(bool)$scheduled);
                $q('delete from v_pbx_backups where command_uuid=?',[$id]);$q('delete from v_pbx_backup_commands where command_uuid=?',[$id]);
            }
            $db->commit();
        } catch(Throwable $error){if($db->inTransaction())$db->rollBack();throw $error;}
        $GLOBALS['restore_fixture_failure_step']='archive_files_delete';
        foreach($backupFiles as $file)if(!unlink($file))throw new RuntimeException('An exact owned encrypted backup file could not be removed.');
        $GLOBALS['restore_fixture_failure_step']='cache_cleanup';
        $cache=new cache;foreach(['dialplan:'.$realm,'dialplan:ingress@'.$realm,'configuration:callcenter.conf',gethostname().':configuration:callcenter.conf','configuration:acl.conf',gethostname().':configuration:acl.conf',gethostname().':configuration:sofia.conf','dialplan:openweb-incoming:'.gethostname()] as $name)$cache->delete($name);
        foreach($s['users']??[] as $user)foreach(array_unique([$user['number'],$user['auth']]) as $number)$cache->delete('directory:'.$number.'@'.$realm);
        $GLOBALS['restore_fixture_failure_step']='native_reload';
        if(($s['cleanup_native']??false)===true){event_socket::api('reloadxml');event_socket::api('reloadacl');}
        $GLOBALS['restore_fixture_failure_step']='factory_guard';$factory();$s['cleanup_completed']=true;
        $GLOBALS['restore_fixture_failure_step']='input_commit';$save();
        echo "{\"owned_rows\":0,\"factory_empty\":true,\"owned_media_cleanup_caller_required\":true}\n";return;
    }
}

if(!defined('OPENWEB_RESTORE_FIXTURE_LIBRARY_ONLY')) {
    set_exception_handler(static function(Throwable $error):void {
        // SQL/runtime/phone credentials never appear in runner console output.
        global $argv;
        restore_fixture_failure_record($error,(string)($argv[2]??''),(string)($argv[1]??''),(string)($GLOBALS['restore_fixture_failure_step']??'initialization'),rtrim((string)(getenv('ProgramData')?:'C:/ProgramData'),'/\\').'/OpenWebPBX/restore-qualification');
        fwrite(STDERR,"Private Windows restore qualification fixture failed.\n");exit(1);
    });
    restore_fixture_main($argv);
}
