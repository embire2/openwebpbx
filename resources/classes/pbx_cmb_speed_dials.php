<?php
/** Nine private slots per callback account; web users never choose another account. */
class pbx_cmb_speed_dials {
    private PDO $db;private string $domain;private string $actor;
    public function __construct(?PDO $db=null){
        $this->db=$db??database::new()->db;$this->domain=(string)($_SESSION['domain_uuid']??'');$this->actor=(string)($_SESSION['user_uuid']??'');
        $this->access();
    }
    private function access(): void {
        $access=new pbx_staff_access($this->db);
        if(empty($_SESSION['authorized'])||!is_uuid($this->domain)||!is_uuid($this->actor)||$this->domain!==($_SESSION['domain_uuid']??'')||$this->actor!==($_SESSION['user_uuid']??'')||(!$access->owner()&&!$access->active()))throw new DomainException('Sign in to your own PBX account to manage speed dials.');
        $access->config();
    }
    private function q(string $sql,array $args=[]): PDOStatement {$s=$this->db->prepare($sql);$s->execute($args);return $s;}
    public function accounts(): array {
        $this->access();return $this->q('select a.account_uuid,a.name,s.name service_name from v_pbx_cmb_accounts a join v_pbx_cmb_services s using(domain_uuid,service_uuid) where a.domain_uuid=? and a.web_user_uuid=? and a.enabled and a.id_last4 is not null order by a.name',[$this->domain,$this->actor])->fetchAll(PDO::FETCH_ASSOC);
    }
    public function slots(string $account): array {
        if(!is_uuid($account)||!in_array($account,array_column($this->accounts(),'account_uuid'),true))throw new DomainException('This speed-dial account is not available to your login.');
        return $this->q('select slot,label,phone_number from v_pbx_cmb_speed_dials where domain_uuid=? and account_uuid=? order by slot',[$this->domain,$account])->fetchAll(PDO::FETCH_ASSOC);
    }
    public function save(string $account,array $input): void {
        $this->access();
        if(!is_uuid($account))throw new DomainException('Choose your speed-dial account.');
        if($this->db->inTransaction())throw new LogicException('Speed dials need their own transaction.');
        $this->db->beginTransaction();try{
            $row=$this->q('select account_uuid,service_uuid from v_pbx_cmb_accounts where domain_uuid=? and account_uuid=? and web_user_uuid=? and enabled and id_last4 is not null for update',[$this->domain,$account,$this->actor])->fetch(PDO::FETCH_ASSOC);
            if(!$row)throw new DomainException('This speed-dial account is not available to your login.');
            self::write($this->db,$this->domain,$row,$input);$this->db->commit();
        }catch(Throwable $e){if($this->db->inTransaction())$this->db->rollBack();throw $e;}
    }
    public static function write(PDO $db,string $domain,array $account,array $input): void {
        if(!$db->inTransaction())throw new LogicException('Lock the account before saving speed dials.');
        $slots=[];
        for($slot=1;$slot<=9;$slot++){
            $number=$input['speed_number_'.$slot]??'';$label=$input['speed_label_'.$slot]??'';
            if(!is_string($number)||!is_string($label)||!mb_check_encoding($label,'UTF-8')||mb_strlen($label)>80||preg_match('/[\x00-\x1f\x7f]/u',$label))throw new InvalidArgumentException('Enter valid speed-dial labels and telephone numbers.');
            $number=trim($number);$label=trim($label);
            if($number!==''&&!preg_match('/^\+?[0-9]{7,16}$/D',$number))throw new InvalidArgumentException('Enter a telephone number with 7–16 digits, optionally starting with +. Leave a slot blank to remove it.');
            $slots[$slot]=[$number,$label];
        }
        foreach($slots as $slot=>[$number,$label]){
            $q=$db->prepare('delete from v_pbx_cmb_speed_dials where domain_uuid=? and account_uuid=? and slot=?');$q->execute([$domain,$account['account_uuid'],$slot]);
            if($number!==''){$q=$db->prepare('insert into v_pbx_cmb_speed_dials(domain_uuid,service_uuid,account_uuid,slot,label,phone_number) values(?,?,?,?,?,?)');$q->execute([$domain,$account['service_uuid'],$account['account_uuid'],$slot,$label,$number]);}
        }
    }
}
