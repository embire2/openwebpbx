<?php
/** Fictional empty-factory lease; no DNS broker or customer identity writes. */
if(PHP_SAPI!=='cli'||PHP_OS_FAMILY!=='Windows'||getenv('GITHUB_ACTIONS')!=='true'||getenv('RUNNER_ENVIRONMENT')!=='github-hosted'||getenv('GITHUB_REPOSITORY')!=='embire2/openwebpbx')exit(2);
require 'C:/OpenWebPBX/web/resources/require.php';
$path=realpath($argv[2]??'');$base=realpath(pbx_paths::state().'/tenant-domain-qualification');
if(!$path||!$base||is_link($path)||basename($path)!=='input.json'||strtolower(dirname(dirname($path)))!==strtolower($base)||!preg_match('/^[a-f0-9]{32}$/D',basename(dirname($path))))throw new RuntimeException('Private tenant fixture required.');
$v=json_decode(file_get_contents($path),true,32,JSON_THROW_ON_ERROR);$db=$database->db;$db->setAttribute(PDO::ATTR_ERRMODE,PDO::ERRMODE_EXCEPTION);
if(($v['alias']??'')!=='qa-'.basename(dirname($path)).'.openwebpbx.com')throw new RuntimeException('Exact owned alias required.');
function q($sql,$p=[]){global$db;$s=$db->prepare($sql);$s->execute($p);return$s;}
function snapshot(){ $r=[];foreach(['v_domains'=>'domain_uuid','v_users'=>'user_uuid','v_pbx_tenants'=>'tenant_uuid','v_pbx_services'=>'service_uuid','v_pbx_tenant_domains'=>'domain_uuid']as$t=>$key){$rows=q('select row_to_json(x)::text from '.$t.' x order by '.$key)->fetchAll(PDO::FETCH_COLUMN);$r[$t]=['count'=>count($rows),'sha256'=>hash('sha256',implode("\n",$rows))];}return$r;}
function save(){global$v,$path;file_put_contents($path,json_encode($v,JSON_THROW_ON_ERROR|JSON_PRETTY_PRINT));}
function check($condition){if(!$condition)throw new RuntimeException('Owned tenant-domain assertion failed.');}
$action=$argv[1]??'';
if($action==='prepare'){
 foreach(['v_pbx_tenants','v_pbx_services','v_pbx_tenant_domains','v_extensions','v_gateways']as$t)check((int)q('select count(*) from '.$t)->fetchColumn()===0);
 $owner=q("select user_uuid from v_users where user_enabled='true' order by user_uuid")->fetchAll(PDO::FETCH_COLUMN);check(count($owner)===1);$v['before']=snapshot();$v['domain']=uuid();$v['tenant']=uuid();$v['service']=uuid();$v['server_host']=pbx_paths::host();$v['realm']='owned-'.basename(dirname($path)).'.invalid';save();
 $db->beginTransaction();try{
 q("insert into v_domains(domain_uuid,domain_name,domain_enabled)values(?,?,true)",[$v['domain'],$v['realm']]);
 q("insert into v_pbx_tenants(tenant_uuid,tenant_name,slug,home_domain_uuid,owner_user_uuid,invite_email,enabled)values(?,?,?,?,?,?,true)",[$v['tenant'],'Owned Windows tenant QA','qa-'.basename(dirname($path)),$v['domain'],$owner[0],'qa-'.basename(dirname($path)).'@example.invalid']);
 q("insert into v_pbx_services(service_uuid,tenant_uuid,domain_uuid,template_name,template_version,service_name,request_uuid,created_by)values(?,?,?,'Owned fixture',1,'Owned fixture',?,?)",[$v['service'],$v['tenant'],$v['domain'],uuid(),$owner[0]]);
 pbx_tenant_domains::discover($db);$db->commit();}catch(Throwable$e){$db->rollBack();throw$e;}
 echo json_encode(['server_host'=>$v['server_host']]);exit;
}
$owned=static function()use($v){return q('select 1 from v_pbx_services s join v_domains d using(domain_uuid) where s.service_uuid=? and s.tenant_uuid=? and s.domain_uuid=? and d.domain_name=?',[$v['service'],$v['tenant'],$v['domain'],$v['realm']])->fetchColumn();};
if($action==='cleanup'){
 $db->beginTransaction();try{q('delete from v_pbx_tenant_domains where domain_uuid=? and tenant_uuid=? and service_uuid=?',[$v['domain'],$v['tenant'],$v['service']]);q('delete from v_pbx_services where service_uuid=? and tenant_uuid=? and domain_uuid=?',[$v['service'],$v['tenant'],$v['domain']]);q('delete from v_pbx_tenants where tenant_uuid=? and home_domain_uuid=?',[$v['tenant'],$v['domain']]);q('delete from v_domains where domain_uuid=? and domain_name=?',[$v['domain'],$v['realm']]);$db->commit();}catch(Throwable$e){$db->rollBack();throw$e;}
 check(snapshot()===$v['before']);echo json_encode(['original_database_exact'=>true]);exit;
}
check((bool)$owned());
$record=['domain_uuid'=>$v['domain'],'hostname'=>$v['alias'],'server_host'=>$v['server_host'],'key_hash'=>$v['key_hash'],'revision'=>1,'state'=>'ready','error_category'=>'','certificate_not_after'=>$v['not_after'],'retry_seconds'=>86400];
if($action==='ready'){pbx_tenant_domains::record($db,$record);check(pbx_tenant_domains::requestDomain($db,['HTTP_HOST'=>$v['alias']])===$v['domain']);echo '{"bound":true}';exit;}
if($action==='pending'){q("update v_pbx_tenant_domains set state='pending_tls' where domain_uuid=?",[$v['domain']]);echo '{}';exit;}
if($action==='verify'){
 $n=0;$test=static function($b)use(&$n){check($b);$n++;};
 $test(pbx_tenant_domains::requestDomain($db,['HTTP_HOST'=>$v['alias']])===$v['domain']);$test(pbx_tenant_domains::url($db,$v['domain'])==='https://'.$v['alias']);$test(pbx_tenant_domains::requestDomain($db,['HTTP_HOST'=>'foreign-'.$v['alias']])==='');$test(pbx_tenant_domains::requestDomain($db,['HTTP_HOST'=>$v['alias'].':444'])==='');
 $_SESSION=[];$_GET=[];pbx_tenant_domains::guardRequest($db,['HTTP_HOST'=>$v['alias']]);$test(($_SESSION['domain_uuid']??'')===$v['domain']&&($_SESSION['domain_name']??'')===$v['realm']&&empty($_SESSION['authorized']));
 $before=snapshot();foreach(['key_hash'=>str_repeat('f',64),'revision'=>0]as$k=>$bad){$r=$record;$r[$k]=$bad;$failed=false;try{pbx_tenant_domains::record($db,$r);}catch(Throwable){$failed=true;}$test($failed&&snapshot()===$before);}
 $db->beginTransaction();q('update v_pbx_tenant_domains set service_uuid=? where domain_uuid=?',[uuid(),$v['domain']]);$test(pbx_tenant_domains::requestDomain($db,['HTTP_HOST'=>$v['alias']])==='');$db->rollBack();
 echo json_encode(['checks'=>$n,'owner_and_revision_refusals'=>true]);exit;
}
throw new RuntimeException('Unknown owned fixture action.');
