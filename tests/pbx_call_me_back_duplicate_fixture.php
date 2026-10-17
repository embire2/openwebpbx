<?php
/** Native-only duplicate-delivery probe against a generated fictional tenant. */
if(PHP_SAPI!=='cli'||gethostname()!=='owpbx-native112-fresh'||trim(@file_get_contents('/run/systemd/container'))!=='systemd-nspawn')exit(2);
require dirname(__DIR__).'/resources/require.php';$path=$argv[1]??'';
if(!preg_match('~^/tmp/openweb-trunk-check-cmb-[a-f0-9]{12}\.json$~D',$path))exit(2);
$f=json_decode(file_get_contents($path),true,512,JSON_THROW_ON_ERROR);$db=$database->db;
$q=$db->prepare("select request_uuid from v_pbx_cmb_requests r join v_domains d using(domain_uuid) where r.domain_uuid=? and r.state='connected' and d.domain_name=? order by r.created_at desc limit 1");$q->execute([$f['domain'],$f['realm']]);$id=$q->fetchColumn();if(!is_uuid($id)||!preg_match('/^carrier-check-[a-f0-9]{12}\.invalid$/D',$f['realm']))throw new RuntimeException('Active owned fixture required.');
$tasks=function()use($id){$data=json_decode(event_socket::api('show tasks as json'),true,512,JSON_THROW_ON_ERROR);$count=0;foreach($data['rows']??[]as$r)if(str_contains(json_encode($r),'openweb-cmb-active-'.$id))$count++;return$count;};
$channels=static function(): int{$data=json_decode(event_socket::api('show channels as json'),true,512,JSON_THROW_ON_ERROR);return count($data['rows']??[]);};$legsBefore=$channels();if($legsBefore!==2)throw new RuntimeException('Exactly two owned fixture call legs required.');
$before=$tasks();if($before!==2)throw new RuntimeException('Both native call cutoffs were not installed.');
$result=event_socket::api('luarun app/pbx_setup/call_me_back.lua '.$id);if(!str_starts_with(trim($result),'+OK'))throw new RuntimeException('Duplicate internal probe refused.');usleep(250000);$after=$tasks();
$legsAfter=$channels();if($legsAfter!==2)throw new RuntimeException('Duplicate delivery created an extra call leg.');
if($after!==2)throw new RuntimeException('Unclaimed duplicate removed native call cutoffs.');echo json_encode(['duplicate_invocation_accepted'=>true,'timers_before'=>$before,'timers_after'=>$after,'call_legs_before'=>$legsBefore,'call_legs_after'=>$legsAfter,'no_new_callback_claim'=>true]);
