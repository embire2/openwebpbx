<?php
if(PHP_SAPI!=='cli')exit;
require dirname(__DIR__).'/resources/require.php';
class MeetAccessFixture extends pbx_staff_access {
 public bool $isOwner=true;public bool $isActive=true;
 public function owner():bool{return $this->isOwner;}
 public function active():bool{return $this->isActive;}
 public function config(bool $lock=false):array{return [];}
}
class MeetFixture extends pbx_meet {
 public MeetAccessFixture $staff;public array $commands=[];public array $bindings=[];
 public function __construct(PDO $db){parent::__construct($db);$this->staff=new MeetAccessFixture($db);}
 protected function access():pbx_staff_access{return $this->staff;}
 protected function engine(string $command):string{$this->commands[]=$command;if(preg_match('/^uuid_getvar ([a-f0-9-]{36}) openweb_meeting_member$/D',$command,$m))return $this->bindings[$m[1]]??'_undef_';return '+OK';}
}
class MeetHostRaceFixture extends MeetFixture {
 public ?Closure $beforeHostLock=null;public ?Closure $afterHostLock=null;
 protected function q(string $sql,array $args=[]):PDOStatement {
  $lock=str_contains($sql,'v_pbx_meetings')&&str_contains($sql,'for update');
  if($lock&&$this->beforeHostLock){$callback=$this->beforeHostLock;$this->beforeHostLock=null;$callback();}
  $result=parent::q($sql,$args);
  if($lock&&$this->afterHostLock){$callback=$this->afterHostLock;$this->afterHostLock=null;$callback();}
  return$result;
 }
}
$db=$database->db;$db->setAttribute(PDO::ATTR_ERRMODE,PDO::ERRMODE_EXCEPTION);$schema='meet_check_'.bin2hex(random_bytes(6));$n=0;
$check=static function($v,$why)use(&$n){if(!$v)throw new RuntimeException($why);$n++;};
$refuse=static function($fn,$why)use($check){try{$fn();}catch(DomainException|OutOfBoundsException|InvalidArgumentException){$check(true,$why);return;}$check(false,$why);};
try{
 $db->exec('create schema '.$schema.';set search_path to '.$schema);
 $db->exec('create table v_domains(domain_uuid uuid primary key,domain_name text,domain_enabled text);create table v_users(user_uuid uuid primary key);create table v_extensions(domain_uuid uuid,extension text,number_alias text);create table v_dialplans(domain_uuid uuid,dialplan_number text);create table v_pbx_tenants(tenant_uuid uuid primary key,enabled boolean);create table v_pbx_services(domain_uuid uuid,tenant_uuid uuid)');
 $db->exec(file_get_contents(dirname(__DIR__).'/app/pbx_meet/resources/install.sql'));
 $db->exec('create table v_email_queue(email_queue_uuid uuid,domain_uuid uuid,hostname text,email_date timestamptz,email_to text,email_subject text,email_body text,email_status text)');
 $domain=uuid();$other=uuid();$actor=uuid();$second=uuid();
 foreach([$domain,$other]as$d)$db->prepare("insert into v_domains values(?,?,'true')")->execute([$d,$d.'.invalid']);
 foreach([$actor,$second]as$u)$db->prepare('insert into v_users values(?)')->execute([$u]);
 $_SESSION=['domain_uuid'=>$domain,'user_uuid'=>$actor,'authorized'=>true];$meet=new MeetFixture($db);
 $room=$meet->create(['subject'=>'Own meeting <script>','notes'=>'Private notes','minutes'=>60]);
 $check(count($meet->meetings())===1,'Meeting created and listed');$check((bool)preg_match('/^98\d{6}$/D',$room['dial_number']),'Tenant meeting number allocated');
 $secret=explode('#',$room['url'])[1];$check(strlen($secret)===64,'Invitation entropy');
 $stored=$db->query('select invite_hash from v_pbx_meetings')->fetchColumn();$check($stored===hash('sha256',$secret)&&$stored!==$secret,'Invite is hashed at rest');
 $guest=$meet->join(['invite'=>$secret,'name'=>'Guest']);$check($guest['state']==='waiting','Guest waits for admission');
 $check($meet->status($guest['token'])['people']===[],'Waiting guest cannot enumerate other waiting guests');
 $refuse(fn()=>$meet->action($guest['token'],['action'=>'end']),'Guest cannot end meeting');
 $host=$meet->host($room['id']);$status=$meet->status($host['token']);$check($status['role']==='host'&&$status['started'],'Host starts room');$check(count($status['people'])===2,'Host can see lobby and admitted people');
 $meet->action($host['token'],['action'=>'admit','member'=>$guest['member']]);$check($meet->status($guest['token'])['state']==='admitted','Host admits guest');
 $meet->action($host['token'],['action'=>'mute','member'=>$guest['member']]);$check($meet->status($guest['token'])['people'][0]['muted'],'Host mutes guest');
 $meet->action($host['token'],['action'=>'unmute','member'=>$guest['member']]);$check(!$meet->status($guest['token'])['people'][0]['muted'],'Host permits microphone again');
 $meet->action($host['token'],['action'=>'lock']);$refuse(fn()=>$meet->join(['invite'=>$secret,'name'=>'Late guest']),'Lock refuses new guests');$meet->action($host['token'],['action'=>'unlock']);
 $new=$meet->invite($room['id']);$refuse(fn()=>$meet->join(['invite'=>$secret,'name'=>'Old link']),'Old invite invalid after renewal');$check($meet->status($guest['token'])['state']==='admitted','Renewing invite preserves admitted participant');
 $ics=$meet->calendar($room['id'],$new['url']);$check(str_contains($ics,'BEGIN:VEVENT')&&str_contains(str_replace("\r\n ",'',$ics),$new['url']),'Calendar has meeting and private join URL');
 $check(max(array_map('strlen',explode("\r\n",$ics)))<=75,'Calendar lines use RFC5545 folding');
 $refuse(fn()=>$meet->calendar($room['id'],"https://other.invalid\r\nX:injected"),'Calendar rejects injected URL');
 $refuse(fn()=>$meet->calendar($room['id'],pbx_paths::url().'/app/pbx_meet/join.php#'."\r\nATTENDEE:x#".str_repeat('a',64)),'Calendar rejects injection after the legitimate origin');
 $refuse(fn()=>$meet->create(['subject'=>"Injected\r\nBcc:x",'minutes'=>60]),'Subject cannot inject mail headers');
 $check($meet->emailInvitations($room['id'],$new['url'],'one@example.invalid, two@example.invalid')===2,'Mail invitations queued atomically');
 $check((int)$db->query('select count(*) from v_email_queue')->fetchColumn()===2,'Only requested invitations queued');
 $refuse(fn()=>$meet->emailInvitations($room['id'],$new['url'],"one@example.invalid\r\nBcc: injected@example.invalid"),'Email header injection refused');
 $refuse(fn()=>$meet->emailInvitations($room['id'],$room['url'],'one@example.invalid'),'Stale invitation cannot be emailed');
 $_SESSION['domain_uuid']=$other;$foreign=new MeetFixture($db);$check($foreign->meetings()===[],'Other tenant cannot list meeting');$refuse(fn()=>$foreign->host($room['id']),'Other tenant cannot host meeting');$refuse(fn()=>$foreign->invite($room['id']),'Other tenant cannot renew invite');
 $_SESSION['domain_uuid']=$domain;$_SESSION['user_uuid']=$second;$staff=new MeetFixture($db);$staff->staff->isOwner=false;$check($staff->meetings()===[],'Staff sees only owned meetings');$refuse(fn()=>$staff->host($room['id']),'Other staff cannot take host role');
 $staff->staff->isActive=false;$refuse(fn()=>$staff->create(['subject'=>'Denied']),'Inactive staff denied');
 $_SESSION['user_uuid']=$actor;
 $another=$meet->create(['subject'=>'Second meeting','minutes'=>15,'open_join'=>1,'audio_only'=>1]);$otherHost=$meet->host($another['id']);
 $refuse(fn()=>$meet->action($otherHost['token'],['action'=>'remove','member'=>$guest['member']]),'Host cannot control another meeting');
 $audioGuest=$meet->join(['invite'=>explode('#',$another['url'])[1],'name'=>'Audio guest']);$check(!$audioGuest['video']&&$audioGuest['state']==='admitted','Audio room and open admission honored');
 $pendingCall=uuid();$meet->bindings[$pendingCall]=$guest['member'];$db->prepare('update v_pbx_meeting_members set call_uuid=? where member_uuid=?')->execute([$pendingCall,$guest['member']]);
 $meet->action($host['token'],['action'=>'remove','member'=>$guest['member']]);$refuse(fn()=>$meet->status($guest['token']),'Removed token denied');
 $check(in_array('uuid_kill '.$pendingCall.' NORMAL_CLEARING',$meet->commands,true),'Removal kills claimed pre-conference channel');
 $pendingHost=uuid();$meet->bindings[$pendingHost]=$host['member'];$db->prepare('update v_pbx_meeting_members set call_uuid=? where member_uuid=?')->execute([$pendingHost,$host['member']]);
 $meet->action($host['token'],['action'=>'end']);$refuse(fn()=>$meet->status($host['token']),'Ended meeting token denied');$refuse(fn()=>$meet->join(['invite'=>explode('#',$new['url'])[1],'name'=>'Ended']),'Ended meeting refuses join');
 $check(in_array('uuid_kill '.$pendingHost.' NORMAL_CLEARING',$meet->commands,true),'Ending kills claimed host before conference entry');
 $refuse(fn()=>$meet->create(['subject'=>'Past','starts_at'=>'2020-01-01T00:00:00Z']),'Past schedule denied');$refuse(fn()=>$meet->create(['subject'=>'Long','minutes'=>481]),'Oversize duration denied');$refuse(fn()=>$meet->join(['invite'=>[], 'name'=>'Wrong']),'Nontext invite denied');
 // Two real PG connections interleave cancellation at the host-lock boundary.
 // This fails the former read-before-lock implementation: it minted a host
 // credential using its stale pre-cancellation meeting row.
 $cancelConnection=new database(['config'=>config::load()]);$cancelDb=$cancelConnection->db;$cancelDb->setAttribute(PDO::ATTR_ERRMODE,PDO::ERRMODE_EXCEPTION);$cancelDb->exec('set search_path to '.$schema);
 $race=new MeetHostRaceFixture($db);$cancelled=$meet->create(['subject'=>'Concurrent cancellation','minutes'=>15]);
 $race->beforeHostLock=static function()use($cancelDb,$cancelled){$q=$cancelDb->prepare('update v_pbx_meetings set ended_at=now() where meeting_uuid=?');$q->execute([$cancelled['id']]);};
 $refuse(fn()=>$race->host($cancelled['id']),'Cancellation committed before host lock refuses credentials');
 $q=$db->prepare('select count(*) from v_pbx_meeting_members where meeting_uuid=?');$q->execute([$cancelled['id']]);$check((int)$q->fetchColumn()===0,'Cancelled host request creates no participant credentials');
 $q=$db->prepare('select started_at is null and ended_at is not null from v_pbx_meetings where meeting_uuid=?');$q->execute([$cancelled['id']]);$check((bool)$q->fetchColumn(),'Cancelled meeting stays ended and unstarted');$check(!$db->inTransaction(),'Host cancellation refusal rolls back transaction');
 $locked=$meet->create(['subject'=>'Host wins row lock','minutes'=>15]);$cancelBlocked=false;
 $race->afterHostLock=static function()use($cancelDb,$locked,&$cancelBlocked){$cancelDb->exec("set lock_timeout='80ms'");try{$q=$cancelDb->prepare('update v_pbx_meetings set ended_at=now() where meeting_uuid=?');$q->execute([$locked['id']]);}catch(PDOException$e){$cancelBlocked=$e->getCode()==='55P03';}finally{$cancelDb->exec('set lock_timeout=0');}};
 $lockedHost=$race->host($locked['id']);$check($cancelBlocked,'Host row lock prevents concurrent cancellation while issuing credentials');$check(isset($lockedHost['token']),'Host holding current row lock can issue credentials');
 $q=$cancelDb->prepare('update v_pbx_meetings set ended_at=now() where meeting_uuid=?');$q->execute([$locked['id']]);$refuse(fn()=>$race->status($lockedHost['token']),'Cancellation after host commit revokes new host credentials');
 $cancelDb=null;$cancelConnection=null;
 $db->prepare("update v_domains set domain_enabled='false' where domain_uuid=?")->execute([$domain]);$refuse(fn()=>$meet->status($audioGuest['token']),'Disabled PBX token denied');
 echo 'PASS '.$n." actual PostgreSQL meeting lifecycle and isolation checks\n";
}finally{if($db->inTransaction())$db->rollBack();$db->exec('set search_path to public;drop schema if exists '.$schema.' cascade');}
