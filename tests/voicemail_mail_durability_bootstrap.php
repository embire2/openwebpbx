<?php
/** Copied beside the exact worker in a disposable runtime; no installed config is loaded. */
error_reporting(E_ALL);
set_error_handler(static function($severity,$message){
 if (!(error_reporting() & $severity)) return false; // Preserve normal explicit @ suppression for absent optional intro files.
 throw new ErrorException($message,0,$severity);
});
$fixture=json_decode(file_get_contents(dirname(__DIR__).'/fixture.json'),true,512,JSON_THROW_ON_ERROR);
$root=$fixture['source'];set_include_path($root.PATH_SEPARATOR.get_include_path());
define('PROJECT_ROOT',$root);
function valid_email($value){return filter_var($value,FILTER_VALIDATE_EMAIL)!==false;}
function is_uuid($value){return is_string($value)&&preg_match('/^[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}$/iD',$value);}
class database {
 public PDO $db;
 public static function new(){return $GLOBALS['database'];}
 public function select($sql,$params=[],$mode='all'){
  $s=$this->db->prepare($sql);$s->execute($params);
  return $mode==='row'?$s->fetch(PDO::FETCH_ASSOC):($mode==='column'?$s->fetchColumn():$s->fetchAll(PDO::FETCH_ASSOC));
 }
 public function execute($sql,$params=[]){$s=$this->db->prepare($sql);return $s->execute($params);}
}
class settings {
 public function __construct($unused=[]){}
 public function get($category,$key,$default=null){
  return ['email_queue.retry_limit'=>5,'email_queue.save_response'=>true,'transcribe.enabled'=>false,'voicemail.storage_type'=>'file'][$category.'.'.$key]??$default;
 }
}
class event_socket {
 public static function create(){return new self;}
 public function is_connected(){return false;} // Never contacts an installed calling engine.
}
$database=new database;
$database->db=new PDO($fixture['dsn'],'postgres',null,[PDO::ATTR_ERRMODE=>PDO::ERRMODE_EXCEPTION]);
foreach(['pbx_mail_dispatch','pbx_mobile_welcome','pbx_voicemail_mail','outgoing_mail','email'] as $class)require $root.'/resources/classes/'.$class.'.php';
if (($argv[1]??'')==='--qr') {
 require $root.'/resources/classes/pbx_mobile.php';
 echo base64_encode(pbx_mobile::qrPng(file_get_contents($argv[2])));exit;
}
if (in_array($argv[1]??'',['--clear','--clear-unprivileged'],true)) {
 $queue=$argv[2];$domain=$argv[3];$message=$argv[4];
 $s=$database->db->prepare('select * from v_email_queue_attachments where email_queue_uuid=? order by email_queue_attachment_uuid');$s->execute([$queue]);
 $rows=$s->fetchAll(PDO::FETCH_ASSOC);$unprivileged=($argv[1]==='--clear-unprivileged');
 if($unprivileged){$identity=posix_getpwnam('www-data');if(!$identity||!posix_setegid($identity['gid'])||!posix_seteuid($identity['uid']))throw new RuntimeException('Owned sender identity fixture unavailable.');}
 try{$cleared=pbx_voicemail_mail::clearDeleted($database->db,$queue,$domain,$message,$rows);}
 finally{if($unprivileged){posix_seteuid(0);posix_setegid(0);}}
 echo json_encode(['cleared'=>$cleared,'unprivileged_sender'=>$unprivileged]);exit;
}
if (($argv[1]??'')==='--generic') {
 $email=new email(['database'=>$database,'settings'=>new settings]);$email->method='direct';$email->recipients='sink@example.invalid';$email->subject='Owned generic fixture';$email->body='Fictional generic message <img src="cid:owned-qr">';
 $email->attachments=json_decode(file_get_contents($argv[2]),true,512,JSON_THROW_ON_ERROR);
 echo json_encode(['sent'=>$email->send(),'error'=>$email->error]);exit;
}
