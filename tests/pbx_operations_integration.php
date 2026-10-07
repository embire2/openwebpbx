<?php
if(PHP_SAPI!=='cli'){http_response_code(404);exit;}
require dirname(__DIR__).'/resources/require.php';
$db=$database->db;$db->setAttribute(PDO::ATTR_ERRMODE,PDO::ERRMODE_EXCEPTION);
$schema='openweb_jobs_check_'.bin2hex(random_bytes(6));$n=0;
$ok=function($value,$message)use(&$n){if(!$value)throw new RuntimeException($message);$n++;};
$reject=function(callable $fn,$message)use($ok){try{$fn();}catch(InvalidArgumentException|PDOException){$ok(true,$message);return;}$ok(false,$message);};
try{
 $db->exec('create schema '.$schema);$db->exec('set search_path to '.$schema.',public');
 foreach(['v_domains','v_pbx_restore','v_voicemails','v_voicemail_messages','v_pbx_media'] as $t)$db->exec('create table '.$t.'(like public.'.$t.' including all)');
 $db->exec(file_get_contents(dirname(__DIR__).'/app/pbx_setup/resources/jobs.sql'));
 $domain=uuid();$foreign=uuid();$user=uuid();$vm=uuid();
 foreach([$domain,$foreign] as $d){$s=$db->prepare('insert into v_domains(domain_uuid,domain_name,domain_enabled) values(?,?,true)');$s->execute([$d,$d.'.invalid']);$s=$db->prepare('insert into v_pbx_restore(domain_uuid,source_version,config) values(?,?,cast(? as jsonb))');$s->execute([$d,'fixture',json_encode(['users'=>['100'=>['number'=>'100','name'=>'Room phone','voicemail_uuid'=>$vm,'greeting_id'=>'100']],'queues'=>[]])]);}
 $_SESSION=['user_uuid'=>$user,'domain_uuid'=>$domain,'domain_name'=>$domain.'.invalid','user'=>['domain_uuid'=>$domain]];
 $s=$db->prepare("insert into v_voicemails(voicemail_uuid,domain_uuid,voicemail_id,voicemail_password,greeting_id) values(?,?,?,'123456',100)");$s->execute([$vm,$domain,'100']);
 $s=$db->prepare("insert into v_voicemail_messages(voicemail_message_uuid,domain_uuid,voicemail_uuid) values(?,?,?)");$s->execute([uuid(),$domain,$vm]);
 $s=$db->prepare("insert into v_pbx_media(media_uuid,domain_uuid,category,owner_number,source_path,file_path,title) values(?,?,'voicemails','100','test','test','Test')");$s->execute([uuid(),$domain]);
 $ops=new pbx_operations($db);
 $ops->hotelAction(['action'=>'add_room','number'=>'100','room_name'=>'Room 1']);
 $ok(count($ops->rooms())===1&&!$ops->rooms()[0]['occupied'],'Room starts vacant');
 $reject(fn()=>$ops->hotelAction(['action'=>'add_room','number'=>'100','room_name'=>'Duplicate']),'Duplicate room rejected');
 $reject(fn()=>$ops->hotelAction(['action'=>'add_room','number'=>'999','room_name'=>'Foreign']),'Foreign user rejected');
 $ops->hotelAction(['action'=>'check_in','number'=>'100','guest_name'=>'Test guest']);$ok($ops->rooms()[0]['occupied'],'Check-in');
 $ok(!$db->query('select 1 from v_voicemail_messages')->fetchColumn()&&!$db->query('select 1 from v_pbx_media')->fetchColumn(),'Prior guest voicemail indexes cleared');
 $v=$db->query('select voicemail_password,greeting_id from v_voicemails')->fetch(PDO::FETCH_ASSOC);$ok($v['voicemail_password']!=='123456'&&$v['greeting_id']===null,'Guest PIN rotated and greeting cleared');
 $ok((new pbx_admin($db))->config()['users']['100']['greeting_id']==='','Active greeting selection reset');
 $reject(fn()=>$ops->hotelAction(['action'=>'check_in','number'=>'100','guest_name'=>'Other guest']),'No overwrite of checked-in guest');
 $ops->hotelAction(['action'=>'room_settings','number'=>'100','room_status'=>'inspected','do_not_disturb'=>'1']);$ok($ops->rooms()[0]['do_not_disturb'],'Do not disturb');
 $ops->hotelAction(['action'=>'wakeup','number'=>'100','timezone'=>'UTC','wake_at'=>gmdate('Y-m-d\TH:i',time()+600)]);
 $ok(count($ops->jobs('wakeup'))===1,'Wake-up scheduled');
 $reject(fn()=>$ops->hotelAction(['action'=>'wakeup','number'=>'100','timezone'=>'UTC','wake_at'=>'2020-01-01T10:00']),'Past wake-up rejected');
 $reject(fn()=>$ops->hotelAction(['action'=>'wakeup','number'=>'100','timezone'=>'UTC','wake_at'=>gmdate('Y-m-d\TH:i',time()+600)]),'Duplicate active wake-up rejected');
 $id=$ops->jobs('wakeup')[0]['job_uuid'];
 $_SESSION['domain_uuid']=$foreign;$other=new pbx_operations($db);$ok(!$other->jobs('wakeup')&&!$other->rooms(),'Tenant read isolation');
 $reject(fn()=>$other->jobAction($id,'cancel'),'Tenant write isolation');
 $_SESSION['domain_uuid']=$domain;
 $ops->hotelAction(['action'=>'check_out','number'=>'100']);$ok(!$ops->rooms()[0]['occupied']&&$ops->rooms()[0]['guest_name']===''&&$ops->rooms()[0]['room_status']==='dirty','Checkout resets guest and room');
 $ok($ops->jobs('wakeup')[0]['state']==='cancelled','Checkout cancels wake-ups');
 $reject(fn()=>$ops->hotelAction(['action'=>'wakeup','number'=>'100','timezone'=>'UTC','wake_at'=>gmdate('Y-m-d\TH:i',time()+600)]),'Vacant room cannot schedule wake-up');
 $ops->hotelAction(['action'=>'remove_room','number'=>'100']);$ok(!$ops->rooms(),'Remove room');
 $ok(count($ops->events())===6,'Hotel audit trail');
 $s=$db->prepare("insert into v_pbx_jobs(job_uuid,domain_uuid,kind,queue_number,target_number,request_key) values(?,?,'callback','800','123456','fixture')");$job=uuid();$s->execute([$job,$domain]);
 $reject(fn()=>$db->exec("insert into v_pbx_jobs(job_uuid,domain_uuid,kind,queue_number,target_number,request_key) values('".uuid()."','$domain','callback','800','123456','duplicate')"),'Callback duplicate blocked');
 $ops->jobAction($job,'cancel');$ok($ops->jobs('callback')[0]['state']==='cancelled','Callback cancellation');
 $db->exec("update v_pbx_jobs set state='failed',attempts=3 where job_uuid='$job'");$ops->jobAction($job,'retry');$ok($ops->jobs('callback')[0]['attempts']===0,'Failed callback retry');
 echo "PASS: $n callback, hotel and tenant checks\n";
}finally{if($db->inTransaction())$db->rollBack();$db->exec('set search_path to public');$db->exec('drop schema if exists '.$schema.' cascade');}
