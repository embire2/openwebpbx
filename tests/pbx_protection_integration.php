<?php
/** Fresh database permissions and streaming import checks in an owned temporary schema. */
if(PHP_SAPI!=='cli'){http_response_code(404);exit;}
require dirname(__DIR__).'/resources/require.php';
class protection_fixture extends pbx_protection {
    public string $inbox;public string $downloads;
    protected function inboxRoot():string{return $this->inbox;}
    protected function downloadRoot():string{return $this->downloads;}
}
$db=$database->db;$db->setAttribute(PDO::ATTR_ERRMODE,PDO::ERRMODE_EXCEPTION);
$schema='openweb_protection_'.bin2hex(random_bytes(6));$root='/var/lib/openwebpbx/protection-tests-'.bin2hex(random_bytes(6));mkdir($root,0700);mkdir($root.'/inbox',0700);mkdir($root.'/downloads',0700);
$checks=0;$q=function($sql,$p=[])use($db){$s=$db->prepare($sql);$s->execute($p);return $s;};
$check=function($ok,$msg)use(&$checks){if(!$ok)throw new RuntimeException($msg);$checks++;};
$deny=function($fn,$msg)use($check){try{$fn();}catch(DomainException|InvalidArgumentException|OverflowException|OutOfBoundsException|RuntimeException){$check(true,$msg);return;}$check(false,$msg);};
try{
 $db->exec('create schema '.$schema);$db->exec('set search_path to '.$schema.',public');
 foreach([
  'create table v_users(user_uuid uuid primary key,user_enabled text,domain_uuid uuid)',
  'create table v_user_groups(user_uuid uuid,group_uuid uuid,domain_uuid uuid)',
  'create table v_group_permissions(group_uuid uuid,permission_name text,permission_assigned text,domain_uuid uuid)',
  'create table v_pbx_tenants(tenant_uuid uuid primary key,tenant_name text,home_domain_uuid uuid,owner_user_uuid uuid,enabled boolean,reseller_user_uuid uuid)',
  'create table v_pbx_services(service_uuid uuid,tenant_uuid uuid,domain_uuid uuid)',
  "create table v_pbx_protection_jobs(job_uuid uuid primary key,tenant_uuid uuid,requested_by uuid,action text,backup_uuid uuid,secret_ciphertext text,request jsonb,status text default 'pending',message text default '',created_at timestamptz default now(),finished_at timestamptz)",
  'create table v_pbx_tenant_backups(backup_uuid uuid primary key,tenant_uuid uuid,filename text,status text,app_version text,size_bytes bigint,sha256 text,media_count integer,created_at timestamptz default now(),verified_at timestamptz,message text)',
  'create table v_pbx_backups(backup_uuid uuid primary key,status text)',
 ]as$sql)$db->exec($sql);
 [$ua,$ub,$admin,$ta,$tb,$ga,$gb,$gp,$ba,$bb]=array_map(fn()=>uuid(),range(1,10));
 foreach([$ua,$ub,$admin]as$u)$q("insert into v_users(user_uuid,user_enabled,domain_uuid) values(?,'true',?)",[$u,uuid()]);
 foreach([[$ua,$ga],[$ub,$gb],[$admin,$gp]]as$r)$q('insert into v_user_groups(user_uuid,group_uuid) values(?,?)',$r);
 foreach([$ga,$gb]as$g)$q("insert into v_group_permissions(group_uuid,permission_name,permission_assigned) values(?,'pbx_tenant_backup','true')",[$g]);
 $q("insert into v_group_permissions(group_uuid,permission_name,permission_assigned) values(?,'pbx_backup_instance','true')",[$gp]);
 foreach([[$ta,'Alpha',$ua],[$tb,'Beta',$ub]]as[$t,$n,$u])$q('insert into v_pbx_tenants values(?,?,?,?,true,null)',[$t,$n,uuid(),$u]);
 foreach([[$ba,$ta],[$bb,$tb]]as[$b,$t])$q("insert into v_pbx_tenant_backups values(?,?,?,'ready','1.0.25',3,?,1,now(),now(),'fixture')",[$b,$t,$b.'.owtenant',hash('sha256','abc')]);
 $_SESSION=['authorized'=>true,'user_uuid'=>$ua,'permissions'=>['domain_all'=>true,'pbx_backup_instance'=>true]];
 $p=new protection_fixture($db);$p->inbox=$root.'/inbox';$p->downloads=$root.'/downloads';
 $check(!$p->instance(),'Session claims cannot grant instance backup access');
 $foreign=uuid();$foreignDomain=uuid();$q('insert into v_user_groups values(?,?,?)',[$ua,$foreign,$foreignDomain]);$q("insert into v_group_permissions(group_uuid,permission_name,permission_assigned) values(?,'pbx_backup_instance','true')",[$foreign]);
 $check(!$p->instance(),'Foreign-domain role assignment cannot grant full-instance backup');
 $q('update v_user_groups set domain_uuid=null where group_uuid=?',[$foreign]);$q('update v_group_permissions set domain_uuid=? where group_uuid=?',[$foreignDomain,$foreign]);
 $check(!$p->instance(),'Foreign-domain permission cannot grant full-instance backup');$q('delete from v_user_groups where group_uuid=?',[$foreign]);
 $check(count($p->tenants())===1&&$p->tenants()[0]['tenant_uuid']===$ta,'Only owned enabled tenant listed');
 $deny(fn()=>$p->status($tb),'Cross-tenant catalogue denied');$deny(fn()=>$p->request('instance_verify','',['backup_uuid'=>$ba,'password'=>'fixture-password-125']),'Full-instance operations denied to tenant');
 $deny(fn()=>$p->request('tenant_verify',$ta,['backup_uuid'=>$bb,'password'=>'fixture-password-125']),'Foreign backup verification denied');
 $deny(fn()=>$p->request('tenant_create',$ta,['password'=>'short']),'Weak backup password denied');
 $deny(fn()=>$p->request('tenant_import',$ta,['password'=>'fixture-password-125']),'Import cannot bypass the protected stream');
 $id=$p->request('tenant_create',$ta,['password'=>'fixture-password-125']);
 $row=$q('select * from v_pbx_protection_jobs where job_uuid=?',[$id])->fetch(PDO::FETCH_ASSOC);
 $check(str_starts_with($row['secret_ciphertext'],'v1:')&&!str_contains($row['secret_ciphertext'],'fixture-password-125'),'Queued password encrypted at rest');
 $check($p->status($ta)['jobs'][0]['job_uuid']===$id&&!isset($p->status($ta)['jobs'][0]['secret_ciphertext']),'Job results hide secrets');
 $deny(fn()=>$p->request('tenant_create',$ta,['password'=>'fixture-password-125']),'Duplicate concurrent operation refused');
 $q("update v_pbx_protection_jobs set status='completed',finished_at=now()");
 $deny(fn()=>$p->request('tenant_restore',$ta,['backup_uuid'=>$ba,'password'=>'fixture-password-125','confirm_tenant'=>'Alpha','confirm_replace'=>true]),'Restore requires prior successful check');
 $verify=$p->request('tenant_verify',$ta,['backup_uuid'=>$ba,'password'=>'fixture-password-125']);$q("update v_pbx_protection_jobs set status='completed',finished_at=now() where job_uuid=?",[$verify]);
 foreach([['confirm_tenant'=>'Beta','confirm_replace'=>true],['confirm_tenant'=>'Alpha','confirm_replace'=>false]]as$extra)$deny(fn()=>$p->request('tenant_restore',$ta,$extra+['backup_uuid'=>$ba,'password'=>'fixture-password-125']),'Explicit correct replacement confirmation required');
 $restore=$p->request('tenant_restore',$ta,['backup_uuid'=>$ba,'password'=>'fixture-password-125','confirm_tenant'=>'Alpha','confirm_replace'=>true]);
 $check((bool)$q('select 1 from v_pbx_protection_jobs where job_uuid=? and action=\'tenant_restore\' and tenant_uuid=?',[$restore,$ta])->fetchColumn(),'Verified same-tenant restore queues');
 $q("update v_pbx_protection_jobs set status='completed',finished_at=now()-interval '31 minutes'");
 $deny(fn()=>$p->request('tenant_restore',$ta,['backup_uuid'=>$ba,'password'=>'fixture-password-125','confirm_tenant'=>'Alpha','confirm_replace'=>true]),'Expired restore check refused');
 file_put_contents($root.'/downloads/'.$ba.'.owtenant','abc');$file=$p->download($ta,$ba);$check(stream_get_contents($file['handle'])==='abc','Own encrypted download allowed');fclose($file['handle']);
 $deny(fn()=>$p->download($ta,$bb),'Foreign encrypted download denied');
 unlink($root.'/downloads/'.$ba.'.owtenant');symlink('/etc/passwd',$root.'/downloads/'.$ba.'.owtenant');$deny(fn()=>$p->download($ta,$ba),'Linked download denied');unlink($root.'/downloads/'.$ba.'.owtenant');
 $stream=fopen('php://temp','w+b');fwrite($stream,'OWPBXB01'.str_repeat('x',64));rewind($stream);
 $deny(fn()=>$p->importStream($tb,$stream,72,'fixture-password-125'),'Foreign upload denied before consuming stream');$check(ftell($stream)===0,'Denied upload body was not consumed');
 $deny(fn()=>$p->importStream($ta,$stream,2147483649,'fixture-password-125'),'Oversized upload denied before body');$check(ftell($stream)===0,'Oversize body was not consumed');
 $import=$p->importStream($ta,$stream,72,'fixture-password-125');fclose($stream);
 $row=$q('select action,request,secret_ciphertext from v_pbx_protection_jobs where job_uuid=?',[$import])->fetch(PDO::FETCH_ASSOC);$request=json_decode($row['request'],true);
 $check($row['action']==='tenant_import'&&$request['size']===72&&$request['sha256']===hash('sha256','OWPBXB01'.str_repeat('x',64)),'Streaming upload queues exact size and checksum');
 $path=$root.'/inbox/'.$request['upload_uuid'].'.upload';$check(file_get_contents($path)==='OWPBXB01'.str_repeat('x',64)&&(fileperms($path)&0777)===0600,'Streaming upload is private and byte-exact');
 $q("update v_pbx_protection_jobs set status='completed',finished_at=now()");
 $stream=fopen('php://temp','w+b');fwrite($stream,str_repeat('x',72));rewind($stream);$count=count(glob($root.'/inbox/*'));
 $deny(fn()=>$p->importStream($ta,$stream,72,'fixture-password-125'),'Nonbackup upload rejected');fclose($stream);$check(count(glob($root.'/inbox/*'))===$count,'Rejected upload cleans partial file');
 $q('update v_pbx_tenants set owner_user_uuid=? where tenant_uuid=?',[$ub,$ta]);$deny(fn()=>$p->status($ta),'Ownership changes revoke backup access immediately');
 $q('update v_pbx_tenants set owner_user_uuid=?,enabled=false where tenant_uuid=?',[$ua,$ta]);$deny(fn()=>$p->status($ta),'Suspension revokes backup access immediately');
 $q('update v_pbx_tenants set enabled=true where tenant_uuid=?',[$ta]);$q("update v_group_permissions set permission_assigned='false' where group_uuid=?",[$ga]);$deny(fn()=>$p->status($ta),'Role revocation is checked freshly');
 $q("update v_group_permissions set permission_assigned='true' where group_uuid=?",[$ga]);$q("insert into v_group_permissions(group_uuid,permission_name,permission_assigned) values(?,'pbx_reseller_manage','true')",[$ga]);$q('update v_pbx_tenants set reseller_user_uuid=? where tenant_uuid=?',[$ua,$tb]);
 $check(count($p->tenants())===2&&count($p->status($tb)['backups'])===1,'Authorised reseller can protect its own client tenant');
 $q('update v_pbx_tenants set reseller_user_uuid=null where tenant_uuid=?',[$tb]);$deny(fn()=>$p->status($tb),'Transferred client tenant is immediately unavailable to old reseller');
 $_SESSION=['authorized'=>true,'user_uuid'=>$admin];$check($p->instance()&&count($p->tenants())===2,'Enabled instance administrator can protect all tenants');
 $q("update v_users set user_enabled='false' where user_uuid=?",[$admin]);$deny(fn()=>$p->tenants(),'Disabled instance owner denied');
 echo 'PASS: '.$checks." fresh permission, tenant isolation, confirmation, encrypted queue and streaming import controls\n";
}finally{
 if($db->inTransaction())$db->rollBack();$db->exec('set search_path to public');$db->exec('drop schema if exists '.$schema.' cascade');
 foreach(glob($root.'/inbox/*')?:[]as$f)unlink($f);foreach(glob($root.'/downloads/*')?:[]as$f)unlink($f);rmdir($root.'/inbox');rmdir($root.'/downloads');rmdir($root);
}
