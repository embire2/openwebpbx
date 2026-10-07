<?php
/** Tenant-scoped callbacks and hotel operations. Callers must also enforce CSRF. */
class pbx_operations {
    private PDO $db;
    private string $domain;
    private pbx_admin $admin;
    public function __construct(?PDO $db=null) {
        $this->db=$db??database::new()->db;$this->admin=new pbx_admin($this->db);$this->domain=$_SESSION['domain_uuid'];
    }
    private function query(string $sql,array $params=[]): PDOStatement {
        $s=$this->db->prepare($sql);$s->execute($params);return $s;
    }
    public function jobs(string $kind): array {
        if(!in_array($kind,['callback','wakeup'],true))throw new InvalidArgumentException('Choose a call type.');
        return $this->query('select job_uuid,queue_number,target_number,state,due_at,created_at,attempts,max_attempts,last_result from v_pbx_jobs where domain_uuid=:d and kind=:k order by created_at desc limit 200',['d'=>$this->domain,'k'=>$kind])->fetchAll(PDO::FETCH_ASSOC);
    }
    public function jobAction(string $id,string $action): void {
        if(!is_uuid($id)||!in_array($action,['cancel','retry'],true))throw new InvalidArgumentException('Choose a call request.');
        if($action==='cancel')$s=$this->query("update v_pbx_jobs set state='cancelled',updated_at=now(),last_result='Cancelled by administrator' where domain_uuid=:d and job_uuid=:id and state in ('waiting','starting')",['d'=>$this->domain,'id'=>$id]);
        else $s=$this->query("update v_pbx_jobs set state='waiting',attempts=0,due_at=now(),expires_at=now()+interval '1 day',last_result='Retry requested',updated_at=now(),agent_number=null,lease_until=null where domain_uuid=:d and job_uuid=:id and state='failed'",['d'=>$this->domain,'id'=>$id]);
        if(!$s->rowCount())throw new InvalidArgumentException('This request has changed. Refresh the page. Calls already in progress cannot be cancelled here.');
    }
    public function rooms(): array {return $this->query('select * from v_pbx_hotel_rooms where domain_uuid=:d order by room_name,number',['d'=>$this->domain])->fetchAll(PDO::FETCH_ASSOC);}
    public function events(): array {return $this->query('select room_number,action,detail,created_at from v_pbx_hotel_events where domain_uuid=:d order by created_at desc limit 100',['d'=>$this->domain])->fetchAll(PDO::FETCH_ASSOC);}
    private function text(array $input,string $key,int $max=80): string {
        $v=$input[$key]??'';if(!is_string($v)||mb_strlen($v)>$max||preg_match('/[\x00-\x1f\x7f<>"&]/',$v))throw new InvalidArgumentException('Enter a valid '.str_replace('_',' ',$key).'.');return trim($v);
    }
    public function hotelAction(array $in): void {
        $action=$this->text($in,'action');$number=$this->text($in,'number',10);
        $c=$this->admin->config();if(!isset($c['users'][$number]))throw new InvalidArgumentException('Choose a room phone from this PBX.');
        $this->db->beginTransaction();
        try {
            $c=$this->admin->config(true);
            $room=$this->query('select * from v_pbx_hotel_rooms where domain_uuid=:d and number=:n for update',['d'=>$this->domain,'n'=>$number])->fetch(PDO::FETCH_ASSOC);
            $detail='';
            if($action==='add_room') {
                if($room)throw new InvalidArgumentException('This phone is already a room.');
                $name=$this->text($in,'room_name');if($name==='')throw new InvalidArgumentException('Enter a room name.');
                $this->query('insert into v_pbx_hotel_rooms(domain_uuid,number,room_name) values(:d,:n,:name)',['d'=>$this->domain,'n'=>$number,'name'=>$name]);$detail=$name;
            } else {
                if(!$room)throw new InvalidArgumentException('Choose a room.');
                if($action==='check_in') {
                    if($room['occupied'])throw new InvalidArgumentException('Check out the previous guest first.');
                    $name=$this->text($in,'guest_name');if($name==='')throw new InvalidArgumentException('Enter the guest name.');
                    $this->resetMailbox($number,$c);
                    $this->query('update v_pbx_hotel_rooms set occupied=true,guest_name=:name,do_not_disturb=false,checked_in_at=now(),updated_at=now() where domain_uuid=:d and number=:n',['d'=>$this->domain,'n'=>$number,'name'=>$name]);$detail=$name;
                } elseif($action==='check_out') {
                    if(!$room['occupied'])throw new InvalidArgumentException('This room is already checked out.');
                    $this->resetMailbox($number,$c);
                    $this->query("update v_pbx_hotel_rooms set occupied=false,guest_name='',do_not_disturb=false,room_status='dirty',checked_in_at=null,updated_at=now() where domain_uuid=:d and number=:n",['d'=>$this->domain,'n'=>$number]);
                    $this->query("update v_pbx_jobs set state='cancelled',last_result='Room checked out',updated_at=now() where domain_uuid=:d and target_number=:n and kind='wakeup' and state in ('waiting','starting')",['d'=>$this->domain,'n'=>$number]);
                } elseif($action==='room_settings') {
                    $status=$this->text($in,'room_status');if(!in_array($status,['clean','dirty','inspected','maintenance'],true))throw new InvalidArgumentException('Choose a room status.');
                    $this->query('update v_pbx_hotel_rooms set room_status=:status,do_not_disturb=cast(:dnd as boolean),updated_at=now() where domain_uuid=:d and number=:n',['d'=>$this->domain,'n'=>$number,'status'=>$status,'dnd'=>empty($in['do_not_disturb'])?'false':'true']);$detail=$status;
                } elseif($action==='wakeup') {
                    if(!$room['occupied'])throw new InvalidArgumentException('Check in the guest first.');
                    $zone=$this->text($in,'timezone');if(!in_array($zone,DateTimeZone::listIdentifiers(),true))throw new InvalidArgumentException('Choose a timezone.');
                    $value=$this->text($in,'wake_at',16);$time=DateTimeImmutable::createFromFormat('!Y-m-d\TH:i',$value,new DateTimeZone($zone));
                    if(!$time||$time->format('Y-m-d\TH:i')!==$value||$time->getTimestamp()<=time()||$time->getTimestamp()>time()+604800)throw new InvalidArgumentException('Choose a wake-up time within the next seven days.');
                    $id=uuid();$this->query("insert into v_pbx_jobs(job_uuid,domain_uuid,kind,target_number,internal_target,request_key,due_at,expires_at) values(:id,:d,'wakeup',:n,true,:key,:due,:expires)",['id'=>$id,'d'=>$this->domain,'n'=>$number,'key'=>'wakeup/'.$id,'due'=>$time->format(DATE_ATOM),'expires'=>$time->modify('+20 minutes')->format(DATE_ATOM)]);$detail=$time->format('Y-m-d H:i').' '.$zone;
                } elseif($action==='remove_room') {
                    if($room['occupied'])throw new InvalidArgumentException('Check out this room first.');
                    $this->query('delete from v_pbx_hotel_rooms where domain_uuid=:d and number=:n',['d'=>$this->domain,'n'=>$number]);
                } else throw new InvalidArgumentException('Choose a hotel action.');
            }
            $this->query('insert into v_pbx_hotel_events(event_uuid,domain_uuid,room_number,action,detail,user_uuid) values(:id,:d,:n,:a,:detail,:u)',['id'=>uuid(),'d'=>$this->domain,'n'=>$number,'a'=>$action,'detail'=>$detail,'u'=>$_SESSION['user_uuid']]);
            $this->db->commit();
            if(in_array($action,['check_in','check_out'],true)){settings::clear_cache();(new cache)->delete('voicemail:'.$_SESSION['domain_name'].':'.$number);}
        } catch(Throwable $e) {if($this->db->inTransaction())$this->db->rollBack();throw $e;}
    }
    private function resetMailbox(string $number,array $config): void {
        $user=$config['users'][$number];
        if(empty($user['voicemail_uuid']))return;
        $this->query('delete from v_voicemail_messages where domain_uuid=:d and voicemail_uuid=:v',['d'=>$this->domain,'v'=>$user['voicemail_uuid']]);
        $this->query("delete from v_pbx_media where domain_uuid=:d and owner_number=:n and category='voicemails'",['d'=>$this->domain,'n'=>$number]);
        // Files remain in private storage for the operator's retention policy, but previous
        // guests' messages are removed from both the phone mailbox and the protected web index.
        $this->query('update v_voicemails set greeting_id=null,voicemail_password=:pin,voicemail_tutorial=true where domain_uuid=:d and voicemail_uuid=:v',['pin'=>(string)random_int(100000,999999),'d'=>$this->domain,'v'=>$user['voicemail_uuid']]);
        $config['users'][$number]['greeting_id']='';
        $this->query('update v_pbx_restore set config=cast(:c as jsonb) where domain_uuid=:d',['c'=>json_encode($config,JSON_THROW_ON_ERROR),'d'=>$this->domain]);
    }
}
