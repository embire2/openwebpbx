<?php
/** Privileged, bounded local IPC; never served by HTTP. */
if(PHP_SAPI!=='cli'||(function_exists('posix_geteuid')&&posix_geteuid()!==0))exit(2);
define('OPENWEB_ONBOARDING_WORKER',true);
$web=$argv[1]??'';$action=$argv[2]??'';
if(!is_file($web.'/resources/require.php'))throw new RuntimeException('Installed application required.');
require $web.'/resources/require.php';$db=$database->db;
$raw=stream_get_contents(STDIN,65537);if(strlen($raw)>65536)throw new RuntimeException('Bounded setup request required.');
$v=$raw===''?[]:json_decode($raw,true,8,JSON_THROW_ON_ERROR);if(!is_array($v))throw new RuntimeException('Setup object required.');
$worker=new pbx_onboarding($db);
switch($action){
case 'policy':$out=['required'=>pbx_onboarding::required($db)];break;
case 'identity':
 if(!pbx_onboarding::required($db)){$out=['required'=>false];break;}
 $host=pbx_paths::host();$hash=$v['key_hash']??'';
 if(($v['server_host']??'')!==$host||!preg_match('/^[0-9a-f]{64}$/D',$hash))throw new RuntimeException('Installed identity mismatch.');
 $q=$db->prepare("update v_pbx_onboarding_policy set canonical_host=?,instance_key_hash=? where singleton and (canonical_host='' or canonical_host=?) and (instance_key_hash='' or instance_key_hash=?)");$q->execute([$host,$hash,$host,$hash]);
 if($q->rowCount()!==1)throw new RuntimeException('Installed identity changed.');
 $out=['required'=>true,'server_host'=>$host,'services'=>$db->query("select s.service_uuid,s.tenant_uuid as local_tenant_uuid,s.domain_uuid,u.user_email from v_pbx_services s join v_pbx_tenants t using(tenant_uuid) join v_users u on u.user_uuid=t.owner_user_uuid where t.enabled and u.user_enabled='true' order by s.created_at,s.service_uuid")->fetchAll(PDO::FETCH_ASSOC)];break;
case 'jobs':$out=$worker->workerJobs();break;
case 'record':$worker->workerRecord($v);$out=['recorded'=>true];break;
case 'store':$out=$worker->workerImport($v);break;
case 'reconcile':$out=$worker->workerReconcile($v['domain_uuid']??null);break;
case 'grants':
 $out=[];if(pbx_onboarding::required($db))foreach($db->query("select domain_uuid,encode(sha256(convert_to(activation::text,'UTF8')),'hex') grant_hash,to_char(grant_expires_at at time zone 'UTC','YYYY-MM-DD\"T\"HH24:MI:SS\"Z\"') grant_expires_at from v_pbx_onboarding where activation is not null")->fetchAll(PDO::FETCH_ASSOC)as $r)if(pbx_onboarding::authorizedDomain($db,$r['domain_uuid']))$out[$r['domain_uuid']]=['grant_hash'=>$r['grant_hash'],'expires_at'=>$r['grant_expires_at']];break;
case 'status':
 $domain=$v['domain_uuid']??'';if(!is_uuid($domain))throw new RuntimeException('Installed domain required.');
 $ready=pbx_onboarding::required($db)&&pbx_onboarding::allowsDomain($db,$domain);$url=$ready?pbx_tenant_domains::url($db,$domain):null;
 $out=['ready'=>$ready,'hostname'=>$ready?parse_url($url,PHP_URL_HOST):null,'url'=>$url];break;
default:throw new RuntimeException('Unknown local setup operation.');
}
echo json_encode($out,JSON_THROW_ON_ERROR|JSON_UNESCAPED_SLASHES)."\n";
