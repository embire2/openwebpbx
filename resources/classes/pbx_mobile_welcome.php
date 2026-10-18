<?php
/** Password-free, one-use phone setup through the existing global SMTP outbox. */
final class pbx_mobile_welcome {
    public function __construct(private PDO $db) {}
    private function q(string $sql,array $args=[]): PDOStatement {$s=$this->db->prepare($sql);$s->execute($args);return $s;}
    public function queue(string $number): array {
        $mobile=new pbx_mobile($this->db);$e=$mobile->adminExtension($number);$recipient=(string)($e['user']['email']??'');
        if(!filter_var($recipient,FILTER_VALIDATE_EMAIL))throw new InvalidArgumentException('Save an email address for this user before sending a welcome message.');
        $mobile->rate('welcome:'.($_SESSION['user_uuid']??''),20,600);
        $this->db->beginTransaction();try{
            $this->q('select extension_uuid from v_extensions where extension_uuid=? and domain_uuid=? for update',[$e['extension_uuid'],$e['domain_uuid']]);
            // Unsent messages become obsolete before their one-use replacement is issued.
            $this->q("update v_email_queue q set email_status='cancelled',update_date=now() from v_pbx_mobile_welcome w where w.email_queue_uuid=q.email_queue_uuid and w.domain_uuid=? and w.extension_uuid=? and q.email_status in('waiting','trying')",[$e['domain_uuid'],$e['extension_uuid']]);
            $code=$mobile->welcomeCode($number);$id=uuid();$welcome=uuid();$cid='openweb-setup-'.$id;$url=json_decode($code['payload'],true,512,JSON_THROW_ON_ERROR)['server'];
            $h=static fn($v)=>htmlspecialchars((string)$v,ENT_QUOTES,'UTF-8');$expiry=gmdate('j M Y H:i \U\T\C',strtotime($code['expires_at']));
            $body='<h1>Welcome to OpenWeb PBX</h1><p>Hello '.$h($e['user']['name']??$number).',</p><p>Your extension is <strong>'.$h($number).'</strong>.</p><ol><li>Install <a href="https://openwebpbx.com/#downloads">OpenWebPBX Free Phone</a>.</li><li>Open the attached <strong>OpenWebPBX-'.$h($number).'.openwebpbx</strong> setup file on your phone, or choose Scan QR Code in the app and scan this image.</li><li>Confirm your company server: <strong>'.$h($url).'</strong>.</li></ol><p><img src="cid:'.$cid.'" width="325" height="325" alt="One-use OpenWeb PBX phone setup QR code"></p><p>This invitation works once and expires '.$h($expiry).'. Keep it private. A new invitation replaces unused older codes.</p><p>You do not need a password for this setup file or QR code. Your administrator can give you a separate app password if you prefer manual sign-in. Your phone and SIP passwords are never included in this email.</p><p>Need another invitation? Ask your PBX administrator.</p>';
            $this->q("insert into v_email_queue(email_queue_uuid,domain_uuid,hostname,email_date,email_from,email_to,email_subject,email_body,email_status) values(?,?,?,now(),'',?,?,?,'waiting')",[$id,$e['domain_uuid'],gethostname(),$recipient,'Welcome to OpenWeb PBX - extension '.$number,$body]);
            foreach([['png','OpenWebPBX-'.$number.'-QR.png','image/png',pbx_mobile::qrPng($code['payload']),$cid],['openwebpbx','OpenWebPBX-'.$number.'.openwebpbx','application/vnd.openwebpbx.config+json',$code['payload'],null]]as[$type,$name,$mime,$bytes,$contentId])$this->q('insert into v_email_queue_attachments(email_queue_attachment_uuid,email_queue_uuid,domain_uuid,email_attachment_type,email_attachment_name,email_attachment_mime_type,email_attachment_path,email_attachment_base64,email_attachment_cid)values(?,?,?,?,?,?,\'\',?,?)',[uuid(),$id,$e['domain_uuid'],$type,$name,$mime,base64_encode($bytes),$contentId]);
            $this->q('insert into v_pbx_mobile_welcome(welcome_uuid,domain_uuid,extension_uuid,email_queue_uuid,enrollment_uuid,recipient,created_by,expires_at)values(?,?,?,?,?,?,?,?)',[$welcome,$e['domain_uuid'],$e['extension_uuid'],$id,$code['enrollment_uuid'],$recipient,is_uuid($_SESSION['user_uuid']??'')?$_SESSION['user_uuid']:null,$code['expires_at']]);
            $this->db->commit();return ['queued'=>true,'queue_uuid'=>$id,'recipient'=>$recipient,'expires_at'=>$code['expires_at']];
        }catch(Throwable $ex){if($this->db->inTransaction())$this->db->rollBack();throw $ex;}
    }
    public function latest(string $number): ?array {
        $e=(new pbx_mobile($this->db))->adminExtension($number);$r=$this->q('select w.recipient,w.created_at,w.expires_at,q.email_status,q.email_retry_count,q.email_response,e.used_at,e.enrollment_uuid active_enrollment_uuid from v_pbx_mobile_welcome w left join v_email_queue q using(email_queue_uuid) left join v_pbx_mobile_enrollments e using(enrollment_uuid) where w.domain_uuid=? and w.extension_uuid=? order by w.created_at desc,w.welcome_uuid desc limit 1',[$e['domain_uuid'],$e['extension_uuid']])->fetch(PDO::FETCH_ASSOC);if(!$r)return null;
        $status=$r['email_status']??'unavailable';$state=$r['used_at']?'used':(strtotime($r['expires_at'])<time()?'expired':(!$r['active_enrollment_uuid']?'cancelled':$status));$code=preg_match('/\bsmtp_reply_code:\s*([45][0-9]{2})\b/',(string)$r['email_response'],$m)?$m[1]:'';
        $message=match($state){'used'=>'The setup invitation has been used.','sent'=>'The outgoing server accepted the welcome message. Inbox delivery is not confirmed.','waiting'=>'Welcome message queued for the global outgoing mail server.','trying'=>'The outgoing server has not accepted this message yet. It will retry.','failed'=>'The outgoing server could not deliver this welcome message.'.($code!==''?' Server response '.$code.'.':''),'expired'=>'This setup invitation has expired. Send a new welcome message.','cancelled'=>'This welcome message was replaced or cancelled.','unavailable'=>'The delivery record is unavailable.',default=>'The welcome message is awaiting delivery.'};
        return ['recipient'=>$r['recipient'],'created_at'=>$r['created_at'],'expires_at'=>$r['expires_at'],'state'=>$state,'message'=>$message];
    }
    /** Optional queue-worker guard. Ordinary mail remains unaffected. */
    public static function beforeDelivery(PDO $db,string $queue): bool {
        if(!is_uuid($queue))throw new InvalidArgumentException('Choose a queued message.');
        if(!$db->query("select to_regclass('v_pbx_mobile_welcome')")->fetchColumn())return true;
        $s=$db->prepare('select e.used_at,e.expires_at,e.enrollment_uuid from v_pbx_mobile_welcome w left join v_pbx_mobile_enrollments e using(enrollment_uuid) where w.email_queue_uuid=?');$s->execute([$queue]);$r=$s->fetch(PDO::FETCH_ASSOC);if(!$r)return true;
        if($r['enrollment_uuid']&&$r['used_at']===null&&strtotime($r['expires_at'])>time())return true;
        $s=$db->prepare("update v_email_queue set email_status='cancelled',update_date=now() where email_queue_uuid=? and email_status in('waiting','trying')");$s->execute([$queue]);return false;
    }
}
