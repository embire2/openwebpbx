<?php
/** CLI-only authorization, encrypted settings and request checks in a disposable PostgreSQL schema. */
if(PHP_SAPI!=='cli'){http_response_code(404);exit;}
require dirname(__DIR__).'/resources/require.php';
class backup_fixture extends pbx_backups {
 public bool $permission=true;public string $key;public string $downloads;
 protected function allowed():bool{return $this->permission;}
 protected function keyFile():string{return $this->key;}
 protected function downloadRoot():string{return $this->downloads;}
}
$db=$database->db;$db->setAttribute(PDO::ATTR_ERRMODE,PDO::ERRMODE_EXCEPTION);
$schema='openweb_backups_test_'.bin2hex(random_bytes(6));
$private='/var/lib/openwebpbx/backup-tests-'.bin2hex(random_bytes(6));mkdir($private,0700);
$checks=0;
$q=function($sql,$params=[])use($db){$s=$db->prepare($sql);$s->execute($params);return $s;};
$check=function($ok,$msg)use(&$checks){if(!$ok)throw new RuntimeException($msg);$checks++;};
$deny=function($action,$msg)use($check){try{$action();}catch(DomainException|InvalidArgumentException|OverflowException|RuntimeException){$check(true,$msg);return;}$check(false,$msg);};
try{
 $db->exec('create schema '.$schema);$db->exec('set search_path to '.$schema.',public');
 foreach(['v_users','v_permissions','v_groups','v_group_permissions']as$table)$db->exec('create table '.$table.' (like public.'.$table.' including all)');
 foreach(['v_permissions','v_groups','v_group_permissions']as$table)$db->exec('insert into '.$table.' select * from public.'.$table);
 $sql=file_get_contents(dirname(__DIR__).'/app/pbx_backups/resources/install.sql');$db->exec($sql);$db->exec($sql);
 $check((int)$q('select count(*) from v_pbx_backup_settings')->fetchColumn()===1,'Migration is repeatable');
 $admin=uuid();$q("insert into v_users(user_uuid,username,user_enabled) values(?,'fixture','true')",[$admin]);
 $_SESSION=['authorized'=>true,'user_uuid'=>$admin];
 $b=new backup_fixture($db);$b->key=$private.'/key';$b->downloads=$private.'/downloads';mkdir($b->downloads,0700);file_put_contents($b->key,random_bytes(32));chmod($b->key,0600);
 $check($b->canView(),'Enabled authenticated instance administrator allowed');
 $s=$b->settings();$check(!$s['enabled']&&!$s['has_passphrase']&&!isset($s['passphrase_secret'],$s['sftp_identity_secret']),'Defaults are disabled and expose no secrets');
 $deny(fn()=>$b->request('create'),'Backup refused until password saved');
 $input=['schedule_hour'=>'2','retention'=>'7','include_media'=>'1','passphrase'=>'FixtureBackupPasswordOnly'];
 $b->save($input+['enabled'=>'1']);$s=$b->settings();
 $check($s['enabled']&&$s['has_passphrase']&&$s['include_media'],'Schedule and media choice saved');
 $secret=$q('select passphrase_secret from v_pbx_backup_settings')->fetchColumn();
 $check(str_starts_with($secret,'v1:')&&!str_contains($secret,$input['passphrase']),'Password encrypted at rest');
 $raw=base64_decode(substr($secret,3));$plain=openssl_decrypt(substr($raw,28),'aes-256-gcm',hash('sha256',file_get_contents($b->key).'/openwebpbx/backups/v1',true),OPENSSL_RAW_DATA,substr($raw,0,12),substr($raw,12,16),'openwebpbx-backup-settings-v1');
 $check($plain===$input['passphrase'],'Encrypted password uses interoperable authenticated envelope');
 $b->save(array_replace($input,['passphrase'=>'']));$check($q('select passphrase_secret from v_pbx_backup_settings')->fetchColumn()===$secret,'Blank password retains existing secret');
 foreach([['schedule_hour'=>'24'],['retention'=>'1'],['retention'=>'91'],['enabled'=>[]],['passphrase'=>'short'],['passphrase'=>"bad\nvalue"]]as$bad)$deny(fn()=>$b->save(array_replace($input,$bad)),'Invalid configuration refused');
 $first=$b->request('create');$check($b->request('create')===$first,'Duplicate pending backup requests coalesced');
 $deny(fn()=>$b->request('restore'),'Restore and arbitrary actions refused in web requests');
 $deny(fn()=>$b->request('verify',uuid()),'Unknown backup verification refused');
 $q("update v_pbx_backup_commands set status='completed',finished_at=now()");
 $id=uuid();$q("insert into v_pbx_backups(backup_uuid,filename,status,include_media,app_version,size_bytes,sha256) values(?,?,'ready',true,'1.0.9',3,?)",[$id,$id.'.owpbx',hash('sha256','abc')]);
 file_put_contents($b->downloads.'/'.$id.'.owpbx','abc');
 $download=$b->download($id);$check(stream_get_contents($download['handle'])==='abc'&&$download['size']===3,'Authorized encrypted download opens only indexed ordinary file');fclose($download['handle']);
 $deny(fn()=>$b->download('../config.conf'),'Traversal download refused');
 $deny(fn()=>$b->download(uuid()),'Unknown indexed file refused');
 unlink($b->downloads.'/'.$id.'.owpbx');symlink($b->key,$b->downloads.'/'.$id.'.owpbx');
 $deny(fn()=>$b->download($id),'Symlink download refused');unlink($b->downloads.'/'.$id.'.owpbx');file_put_contents($b->downloads.'/'.$id.'.owpbx','changed');
 $deny(fn()=>$b->download($id),'Changed encrypted file length refused');
 $verify=$b->request('verify',$id);$check($b->request('verify',$id)===$verify,'Duplicate verify request coalesced');
 $deny(fn()=>$b->request('create'),'Different request blocked while verification is pending');
 $hostKey='ssh-ed25519 '.base64_encode(random_bytes(64));$identity="-----BEGIN OPENSSH PRIVATE KEY-----\n".base64_encode(random_bytes(100))."\n-----END OPENSSH PRIVATE KEY-----\n";
 $remote=$input+['sftp_enabled'=>'1','sftp_host'=>'backup.example.invalid','sftp_port'=>'22','sftp_user'=>'backup','sftp_directory'=>'/backups/pbx','sftp_host_key'=>$hostKey,'sftp_identity'=>$identity];
 $b->save($remote);$s=$b->settings();$check($s['sftp_enabled']&&$s['has_identity']&&!isset($s['sftp_identity_secret']),'SFTP private identity is encrypted and never returned');
 foreach([['sftp_host'=>'-oProxyCommand=unsafe'],['sftp_user'=>'x;sh'],['sftp_directory'=>'/tmp/../root'],['sftp_directory'=>'/back ups'],['sftp_host_key'=>'not a trusted key'],['sftp_identity'=>'invalid']]as$bad)$deny(fn()=>$b->save(array_replace($remote,$bad)),'Unsafe remote settings refused');
 $b->save($input);$s=$b->settings();$check(!$s['sftp_enabled']&&!$s['has_identity']&&$s['sftp_host']==='','Disabling SFTP clears connection and identity');
 $q("update v_pbx_backup_status set message='Fixture ready',updated_at=now()");$check($b->status()['service_online'],'Recent worker heartbeat detected');
 $q("update v_pbx_backup_status set updated_at=now()-interval '4 minutes'");$check(!$b->status()['service_online'],'Stale worker heartbeat detected');
 $b->permission=false;$check(!$b->canView(),'Tenant and missing permission denied');$deny(fn()=>$b->settings(),'Tenant cannot read global settings');$deny(fn()=>$b->save($input),'Tenant cannot change backups');$deny(fn()=>$b->request('create'),'Tenant cannot queue export');$deny(fn()=>$b->download($id),'Tenant cannot download global data');
 $b->permission=true;$_SESSION['authorized']=false;$check(!$b->canView(),'Unauthenticated session denied');$_SESSION['authorized']=true;
 $q("update v_users set user_enabled='false' where user_uuid=?",[$admin]);$check(!$b->canView(),'Disabled administrator denied');
 $check((int)$q("select count(*) from v_group_permissions where group_name='tenant_admin' and permission_name='pbx_backup_instance'")->fetchColumn()===0,'Tenant group never receives instance backup permission');
 echo 'PASS: '.$checks." PostgreSQL backup authorization, encryption, validation and request checks\n";
}finally{
 if($db->inTransaction())$db->rollBack();$db->exec('set search_path to public');$db->exec('drop schema if exists '.$schema.' cascade');
 foreach(glob($private.'/downloads/*')?:[]as$file)unlink($file);if(is_dir($private.'/downloads'))rmdir($private.'/downloads');unlink($private.'/key');rmdir($private);
}
