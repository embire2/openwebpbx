<?php
/** SPDX-License-Identifier: AGPL-3.0-or-later. Bounded Windows global queue dispatch. */
if(PHP_SAPI!=='cli'||PHP_OS_FAMILY!=='Windows')exit(2);
set_exception_handler(static function(Throwable $error): void {fwrite(STDERR,"Windows mail dispatch failed. Review the private server configuration.\n");exit(1);});
$web=$argv[1]??'';
if($web===''||!is_file($web.'/resources/require.php'))throw new RuntimeException('Installed web root unavailable.');
require $web.'/resources/require.php';
$db=$database->db;$db->setAttribute(PDO::ATTR_ERRMODE,PDO::ERRMODE_EXCEPTION);
// Check the global transport before any attempt/status mutation. Unconfigured
// queues remain waiting and retain their retry allowance.
try{(new outgoing_mail($db))->transport();}
catch(outgoing_mail_configuration_required){echo json_encode(['configured'=>false,'selected'=>0,'attempts_consumed'=>0]),PHP_EOL;exit;}
$q=$db->prepare("select email_queue_uuid from v_email_queue where email_status in ('waiting','trying') and lower(hostname)=lower(?) order by email_date,email_queue_uuid limit 10");$q->execute([gethostname()]);$ids=$q->fetchAll(PDO::FETCH_COLUMN);$processed=0;
$deadline=microtime(true)+90;
foreach($ids as $id){
    if(microtime(true)>$deadline-5)break;
    if(!is_uuid($id))throw new RuntimeException('Invalid queued identifier.');
    // NUL prevents message bodies, credentials and unbounded SMTP diagnostic
    // output from reaching a public task log or blocking an unread pipe.
    $process=proc_open([PHP_BINARY,$web.'/app/email_queue/resources/jobs/email_send.php','email_queue_uuid='.$id.'&hostname='.rawurlencode(gethostname())],[0=>['file','NUL','r'],1=>['file','NUL','w'],2=>['file','NUL','w']],$pipes,null,null,['bypass_shell'=>true]);
    if(!is_resource($process))throw new RuntimeException('Mail dispatch process unavailable.');
    $expires=min($deadline,microtime(true)+45);$exit=null;
    try{
        do{
            $status=proc_get_status($process);
            if(!$status['running']){$exit=$status['exitcode'];break;}
            if(microtime(true)>$expires){proc_terminate($process);throw new RuntimeException('Mail dispatch exceeded its bounded execution time.');}
            usleep(100000);
        }while(true);
    }finally{
        $closed=proc_close($process);
        if($exit===null||$exit<0)$exit=$closed;
    }
    if($exit!==0)throw new RuntimeException('Mail dispatch did not finish.');
    $processed++;
}
echo json_encode(['configured'=>true,'selected'=>count($ids),'processed'=>$processed],JSON_THROW_ON_ERROR),PHP_EOL;
