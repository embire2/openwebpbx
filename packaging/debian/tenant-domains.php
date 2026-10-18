<?php
/** Root worker IPC. No HTTP/admin endpoint and no DNS provider credentials. */
if(PHP_SAPI!=='cli'||(function_exists('posix_geteuid')&&posix_geteuid()!==0))exit(2);
$web=$argv[1]??'';$action=$argv[2]??'';
if(!is_file($web.'/resources/require.php'))throw new RuntimeException('Installed web tree required.');
require $web.'/resources/require.php';$db=$database->db;
if($action==='discover'){
 $due=pbx_tenant_domains::discover($db);$all=pbx_tenant_domains::installed($db)?$db->query('select * from v_pbx_tenant_domains order by domain_uuid limit 50')->fetchAll(PDO::FETCH_ASSOC):[];
 $email=$db->query("select u.user_email from v_users u join v_user_groups g using(user_uuid)where g.group_name='superadmin'and u.user_enabled='true'order by u.user_uuid limit 1")->fetchColumn();
 echo json_encode(['server_host'=>pbx_paths::host(),'contact_email'=>is_string($email)?$email:'','aliases'=>$due,'inventory'=>$all],JSON_THROW_ON_ERROR);
}
elseif($action==='record'){$data=stream_get_contents(STDIN,8193);if(strlen($data)>8192)throw new RuntimeException('Bounded worker result required.');pbx_tenant_domains::record($db,json_decode($data,true,8,JSON_THROW_ON_ERROR));echo "{}\n";}
else throw new RuntimeException('Unknown local worker operation.');
