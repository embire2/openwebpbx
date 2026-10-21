<?php
/** First-party audio/video meetings. Guest credentials can reach only their admitted room. */
class pbx_meet {
    protected PDO $db;
    public function __construct(?PDO $db=null){$this->db=$db??database::new()->db;}
    protected function q(string $sql,array $args=[]): PDOStatement {$s=$this->db->prepare($sql);$s->execute($args);return $s;}
    protected function engine(string $command): string {return (string)event_socket::api($command);}
    protected function access(): pbx_staff_access {return new pbx_staff_access($this->db);}
    private static function websocketUrl(string $origin): string {
        $parts=parse_url($origin);
        if($parts===false||($parts['scheme']??'')!=='https'||empty($parts['host'])||isset($parts['user'])||isset($parts['pass'])||isset($parts['query'])||isset($parts['fragment']))throw new RuntimeException('Configure a trusted HTTPS address before starting meetings.');
        return 'wss://'.$parts['host'].(isset($parts['port'])&&$parts['port']!==443?':'.$parts['port']:'').'/meet-sip/';
    }
    private function actor(): array {
        $a=$this->access();if(!$a->owner()&&!$a->active())throw new DomainException('Sign in with your PBX staff account.');
        $a->config();return [$a->domain,$a->actor,$a->owner()];
    }
    private function text(array $in,string $key,int $max): string {
        $v=$in[$key]??'';if(!is_string($v)||mb_strlen(trim($v))>$max||preg_match('/[\x00-\x08\x0b\x0c\x0e-\x1f]/',$v)||($key!=='notes'&&preg_match('/[\r\n]/',$v)))throw new InvalidArgumentException('Check the meeting details.');return trim($v);
    }
    private function id(string $id): void {if(!is_uuid($id))throw new OutOfBoundsException('Meeting unavailable.');}
    public function meetings(): array {
        [$d,$u,$owner]=$this->actor();return $this->q('select meeting_uuid,subject,notes,starts_at,ends_at,dial_number,video_enabled,lobby_required,locked,started_at,ended_at from v_pbx_meetings where domain_uuid=?'.($owner?'':' and owner_uuid=?').' order by starts_at desc limit 100',$owner?[$d]:[$d,$u])->fetchAll(PDO::FETCH_ASSOC);
    }
    private function owned(string $id,bool $lock=false): array {
        $this->id($id);[$d,$u,$owner]=$this->actor();$r=$this->q('select * from v_pbx_meetings where meeting_uuid=? and domain_uuid=?'.($owner?'':' and owner_uuid=?').($lock?' for update':''),$owner?[$id,$d]:[$id,$d,$u])->fetch(PDO::FETCH_ASSOC);
        if(!$r)throw new OutOfBoundsException('Meeting unavailable.');return $r;
    }
    public function create(array $in): array {
        [$d,$u]=$this->actor();$title=$this->text($in,'subject',120);if($title==='')throw new InvalidArgumentException('Give your meeting a name.');
        $start=$this->text($in,'starts_at',40);$start=$start===''?time():strtotime($start);$minutes=filter_var($in['minutes']??60,FILTER_VALIDATE_INT,['options'=>['min_range'=>15,'max_range'=>480]]);
        if($start===false||$start<time()-300||$start>time()+31536000||$minutes===false)throw new InvalidArgumentException('Choose a start time and a duration from 15 minutes to 8 hours.');
        $id=uuid();$secret=bin2hex(random_bytes(32));$number='98'.str_pad((string)random_int(0,999999),6,'0',STR_PAD_LEFT);
        // The advisory lock also serializes concurrent allocation in this PBX.
        $this->db->beginTransaction();try{
            $this->q('select pg_advisory_xact_lock(hashtext(?))',[$d]);
            for($i=0;$i<20;$i++){
                $collision=$this->q("select exists(select 1 from v_dialplans where domain_uuid=? and dialplan_number=? union all select 1 from v_extensions where domain_uuid=? and (extension=? or number_alias=?) union all select 1 from v_pbx_meetings where domain_uuid=? and dial_number=?)",[$d,$number,$d,$number,$number,$d,$number])->fetchColumn();
                if(!$collision)break;$number='98'.str_pad((string)random_int(0,999999),6,'0',STR_PAD_LEFT);
            }
            if($collision)throw new RuntimeException('Could not allocate a meeting number. Try again.');
            $this->q('insert into v_pbx_meetings(meeting_uuid,domain_uuid,owner_uuid,subject,notes,starts_at,ends_at,invite_hash,dial_number,video_enabled,lobby_required) values(?,?,?,?,?,?,?,?,?,?::boolean,?::boolean)',[$id,$d,$u,$title,$this->text($in,'notes',2000),gmdate('c',$start),gmdate('c',$start+$minutes*60),hash('sha256',$secret),$number,empty($in['audio_only'])?'true':'false',empty($in['open_join'])?'true':'false']);
            $this->db->commit();
        }catch(Throwable $e){if($this->db->inTransaction())$this->db->rollBack();throw $e;}
        return ['id'=>$id,'url'=>pbx_paths::url().'/app/pbx_meet/join.php#'.$secret,'dial_number'=>$number];
    }
    public function invite(string $id): array {
        $m=$this->owned($id);$secret=bin2hex(random_bytes(32));$this->q('update v_pbx_meetings set invite_hash=? where meeting_uuid=?',[hash('sha256',$secret),$id]);
        return ['id'=>$id,'url'=>pbx_paths::url().'/app/pbx_meet/join.php#'.$secret,'dial_number'=>$m['dial_number']];
    }
    public function emailInvitations(string $id,string $url,string $addresses): int {
        $m=$this->owned($id);$this->calendar($id,$url);$secret=explode('#',$url)[1];
        if(!hash_equals($m['invite_hash'],hash('sha256',$secret)))throw new InvalidArgumentException('Use the latest invitation link.');
        $emails=array_values(array_unique(array_filter(array_map('trim',explode(',',$addresses)))));
        if(!$emails||count($emails)>20)throw new InvalidArgumentException('Enter up to 20 email addresses, separated by commas.');
        foreach($emails as$email)if(strlen($email)>254||!filter_var($email,FILTER_VALIDATE_EMAIL)||preg_match('/[\r\n]/',$email))throw new InvalidArgumentException('Check the email addresses.');
        $body="You are invited to ".$m['subject'].".\n\nStarts: ".gmdate('Y-m-d H:i',strtotime($m['starts_at']))." UTC\n\n".$m['notes']."\n\nJoin using your browser: ".$url."\n\nEnter your name. The host may ask you to wait for admission.\nPBX extension dial-in: ".$m['dial_number']."\n";
        $this->db->beginTransaction();try{foreach($emails as$email)$this->q("insert into v_email_queue(email_queue_uuid,domain_uuid,hostname,email_date,email_to,email_subject,email_body,email_status) values(?,?,?,now(),?,?,?,'waiting')",[uuid(),$m['domain_uuid'],gethostname(),$email,'Meeting invitation: '.$m['subject'],$body]);$this->db->commit();}catch(Throwable$e){if($this->db->inTransaction())$this->db->rollBack();throw$e;}return count($emails);
    }
    public function cancel(string $id): void {
        $this->owned($id);$this->endMeeting($id);
    }
    public function calendar(string $id,string $url): string {
        $m=$this->owned($id);if(!preg_match('~^'.preg_quote(pbx_paths::url().'/app/pbx_meet/join.php#','~').'[a-f0-9]{64}$~D',$url))throw new InvalidArgumentException('Use the current meeting link.');
        $escape=static fn($v)=>str_replace(["\\","\r","\n",',',';'],['\\\\','', '\\n','\\,','\\;'],$v);
        $calendar="BEGIN:VCALENDAR\r\nVERSION:2.0\r\nPRODID:-//OpenWebPBX//Meet//EN\r\nBEGIN:VEVENT\r\nUID:".$id."@openwebpbx\r\nDTSTAMP:".gmdate('Ymd\THis\Z')."\r\nDTSTART:".gmdate('Ymd\THis\Z',strtotime($m['starts_at']))."\r\nDTEND:".gmdate('Ymd\THis\Z',strtotime($m['ends_at']))."\r\nSUMMARY:".$escape($m['subject'])."\r\nDESCRIPTION:".$escape($m['notes']."\nJoin: ".$url."\nPBX meeting number: ".$m['dial_number'])."\r\nURL:".$url."\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n";
        $lines=[];foreach(explode("\r\n",$calendar)as$line){$width=75;while(strlen($line)>$width){$part=mb_strcut($line,0,$width,'UTF-8');$lines[]=$part;$line=' '.substr($line,strlen($part));$width=75;}$lines[]=$line;}return implode("\r\n",$lines);
    }
    private function available(array $m): void {
        if($m['ended_at']||time()<strtotime($m['starts_at'])-900||time()>strtotime($m['ends_at']))throw new OutOfBoundsException('This meeting has not opened yet or has ended.');
    }
    private function member(array $m,string $name,bool $host): array {
        $this->available($m);$token=bin2hex(random_bytes(32));$password=bin2hex(random_bytes(24));$user='owc-'.bin2hex(random_bytes(16));$id=uuid();
        if(!$host&&$m['locked'])throw new DomainException('The host has locked this meeting.');
        $this->q("delete from v_pbx_meeting_members where meeting_uuid=? and call_uuid is null and (state='left' or seen_at<now()-interval '2 minutes')",[$m['meeting_uuid']]);
        $n=$this->q("select count(*) from v_pbx_meeting_members where meeting_uuid=? and state in ('waiting','admitted')",[$m['meeting_uuid']])->fetchColumn();
        if($n>=($host?25:24))throw new DomainException('This meeting is full (25 people, including the host).');
        $state=$host||!$m['lobby_required']?'admitted':'waiting';
        $this->q('insert into v_pbx_meeting_members(member_uuid,meeting_uuid,member_name,role,state,token_hash,sip_username,sip_a1_hash) values(?,?,?,?,?,?,?,?)',[$id,$m['meeting_uuid'],$name,$host?'host':'guest',$state,hash('sha256',$token),$user,md5($user.':'.$m['domain_name'].':'.$password)]);
        return ['member'=>$id,'token'=>$token,'username'=>$user,'password'=>$password,'domain'=>$m['domain_name'],'number'=>$m['dial_number'],'websocket'=>self::websocketUrl(pbx_paths::url()),'video'=>(bool)$m['video_enabled'],'state'=>$state];
    }
    public function host(string $id): array {
        // Read availability from the locked row. A cancellation committed while
        // this request waits must not issue fresh credentials from stale data.
        $this->db->beginTransaction();try{$m=$this->owned($id,true);$m['domain_name']=$this->q('select domain_name from v_domains where domain_uuid=?',[$m['domain_uuid']])->fetchColumn();$r=$this->member($m,'Host',true);$this->q('update v_pbx_meetings set started_at=coalesce(started_at,now()) where meeting_uuid=?',[$id]);$this->db->commit();return $r;}catch(Throwable $e){if($this->db->inTransaction())$this->db->rollBack();throw $e;}
    }
    public function join(array $in): array {
        $secret=$this->text($in,'invite',64);$name=$this->text($in,'name',80);if(!preg_match('/^[a-f0-9]{64}$/D',$secret)||$name==='')throw new InvalidArgumentException('Enter your name and use a valid invitation.');
        $this->db->beginTransaction();try{
            $m=$this->q("select m.*,d.domain_name from v_pbx_meetings m join v_domains d using(domain_uuid) where invite_hash=? and d.domain_enabled='true' and not exists(select 1 from v_pbx_services s join v_pbx_tenants t using(tenant_uuid) where s.domain_uuid=m.domain_uuid and not t.enabled) for update of m",[hash('sha256',$secret)])->fetch(PDO::FETCH_ASSOC);
            if(!$m)throw new OutOfBoundsException('Meeting unavailable.');$r=$this->member($m,$name,false);$this->db->commit();return $r;
        }catch(Throwable $e){if($this->db->inTransaction())$this->db->rollBack();throw $e;}
    }
    private function authenticated(string $token): array {
        if(!preg_match('/^[a-f0-9]{64}$/D',$token))throw new DomainException('Rejoin using your meeting invitation.');
        $r=$this->q("select m.*,p.domain_uuid,p.subject,p.starts_at,p.ends_at,p.started_at,p.ended_at,p.locked,p.video_enabled from v_pbx_meeting_members m join v_pbx_meetings p using(meeting_uuid) join v_domains d on d.domain_uuid=p.domain_uuid where token_hash=? and d.domain_enabled='true' and not exists(select 1 from v_pbx_services s join v_pbx_tenants t using(tenant_uuid) where s.domain_uuid=d.domain_uuid and not t.enabled)",[hash('sha256',$token)])->fetch(PDO::FETCH_ASSOC);
        if(!$r||in_array($r['state'],['left','removed'],true))throw new DomainException('You have left this meeting.');$this->available($r);return $r;
    }
    public function status(string $token): array {
        $m=$this->authenticated($token);$this->q('update v_pbx_meeting_members set seen_at=now() where member_uuid=?',[$m['member_uuid']]);
        $fields=$m['role']==='host'?"('waiting','admitted')":"('admitted')";
        $people=$this->q('select member_uuid,member_name,role,state,muted,call_uuid is not null as connected from v_pbx_meeting_members where meeting_uuid=? and state in '.$fields.' order by created_at',[$m['meeting_uuid']])->fetchAll(PDO::FETCH_ASSOC);
        return ['subject'=>$m['subject'],'state'=>$m['state'],'role'=>$m['role'],'started'=>(bool)$m['started_at'],'locked'=>(bool)$m['locked'],'video'=>(bool)$m['video_enabled'],'people'=>$people,'ends_at'=>$m['ends_at']];
    }
    public function action(string $token,array $in): array {
        $m=$this->authenticated($token);$action=$this->text($in,'action',20);
        if($action==='leave'){$current=$this->q("update v_pbx_meeting_members set state='left' where member_uuid=? returning *",[$m['member_uuid']])->fetch(PDO::FETCH_ASSOC);if($current)$this->disconnect($current);return ['ok'=>true];}
        if($m['role']!=='host'||$m['state']!=='admitted')throw new DomainException('Only the host can do that.');
        if(in_array($action,['lock','unlock','end'],true)){
            if($action==='end'){$this->endMeeting($m['meeting_uuid']);}
            else $this->q('update v_pbx_meetings set locked=?::boolean where meeting_uuid=?',[$action==='lock'?'true':'false',$m['meeting_uuid']]);return ['ok'=>true];
        }
        $id=$this->text($in,'member',36);$this->id($id);$target=$this->q('select * from v_pbx_meeting_members where member_uuid=? and meeting_uuid=?',[$id,$m['meeting_uuid']])->fetch(PDO::FETCH_ASSOC);
        if(!$target||$target['role']==='host')throw new OutOfBoundsException('Choose a guest in this meeting.');
        if($action==='admit'){$this->q("update v_pbx_meeting_members set state='admitted' where member_uuid=? and state='waiting'",[$id]);}
        elseif($action==='remove'){$target=$this->q("update v_pbx_meeting_members set state='removed' where member_uuid=? and meeting_uuid=? and role='guest' returning *",[$id,$m['meeting_uuid']])->fetch(PDO::FETCH_ASSOC);if($target)$this->disconnect($target);}
        elseif(in_array($action,['mute','unmute'],true)){
            $muted=$action==='mute';$target=$this->q('update v_pbx_meeting_members set muted=?::boolean where member_uuid=? and meeting_uuid=? returning *',[$muted?'true':'false',$id,$m['meeting_uuid']])->fetch(PDO::FETCH_ASSOC);
            if($target['call_uuid']&&is_uuid($target['call_uuid'])&&trim($this->engine('uuid_getvar '.$target['call_uuid'].' openweb_meeting_member'))===$id){
                // Read-side muting also covers a claimed channel still entering
                // its conference, before conference_member_id becomes available.
                $this->engine('uuid_audio '.$target['call_uuid'].($muted?' start read mute':' stop read'));
                $member=trim($this->engine('uuid_getvar '.$target['call_uuid'].' conference_member_id'));
                if(ctype_digit($member))$this->engine('conference owmeet-'.$m['meeting_uuid'].' '.$action.' '.$member);
            }
        }else throw new InvalidArgumentException('Choose a meeting action.');return ['ok'=>true];
    }
    private function endMeeting(string $id): void {
        // Claims lock this meeting row first. Once ended is committed, a new
        // claim cannot slip between the participant inventory and native kicks.
        $this->q('update v_pbx_meetings set ended_at=coalesce(ended_at,now()) where meeting_uuid=?',[$id]);
        foreach($this->q('select * from v_pbx_meeting_members where meeting_uuid=? and call_uuid is not null',[$id])->fetchAll(PDO::FETCH_ASSOC)as$member)$this->disconnect($member);
        $this->engine('conference owmeet-'.$id.' kick all');
    }
    private function disconnect(array $m): void {
        if(is_uuid($m['call_uuid']??'')&&trim($this->engine('uuid_getvar '.$m['call_uuid'].' openweb_meeting_member'))===$m['member_uuid'])$this->engine('uuid_kill '.$m['call_uuid'].' NORMAL_CLEARING');
    }
}
