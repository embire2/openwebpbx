<?php
/** Incoming destinations on the trunk page. No gateway, phone or DID enablement writes. */
class pbx_trunk_routes {
    public const VERSION='1.0.19';
    private PDO $db;
    private string $domain;
    private string $actor;
    public function __construct(?PDO $db=null){
        $this->db=$db??database::new()->db;
        $this->domain=(string)($_SESSION['domain_uuid']??'');$this->actor=(string)($_SESSION['user_uuid']??'');
        $this->owner();
    }
    private function owner(): void {
        if($this->domain!==($_SESSION['domain_uuid']??null)||$this->actor!==($_SESSION['user_uuid']??null)||!(new pbx_staff_access($this->db))->owner()||!$this->q("select 1 from v_domains d join v_users u on u.user_uuid=:u where d.domain_uuid=:d and d.domain_enabled='true' and u.user_enabled='true'",['d'=>$this->domain,'u'=>$this->actor])->fetchColumn())throw new RuntimeException('PBX owner access is required to change incoming routing.');
    }
    private function q(string $sql,array $params=[]): PDOStatement {$s=$this->db->prepare($sql);$s->execute($params);return $s;}
    private function text(array $in,string $key,int $max=100): string {$v=$in[$key]??'';if(!is_string($v)||strlen($v)>$max||preg_match('/[\x00-\x1f\x7f]/',$v))throw new InvalidArgumentException('Choose a valid incoming route.');return $v;}
    private function callback(string $rule,bool $lock=false): ?array {
        if(!$this->q("select to_regclass('v_pbx_cmb_services') is not null")->fetchColumn())return null;
        return $this->q('select service_uuid,name,enabled,prompt_state,prompt_version,prompt_sha256,route_owner,updated_at from v_pbx_cmb_services where domain_uuid=:d and incoming_rule_uuid=:r'.($lock?' for update':''),['d'=>$this->domain,'r'=>$rule])->fetch(PDO::FETCH_ASSOC)?:null;
    }
    private function revision(array $rule,?array $service): string {return hash('sha256',json_encode([$rule,$service],JSON_THROW_ON_ERROR));}
    public static function label(array $dest,array $c): string {
        $n=(string)($dest['number']??'');$type=$dest['type']??'None';
        if($type==='Extension'||$type==='VoiceMail')return ($type==='VoiceMail'?'Voicemail':'Extension').' · '.$n.' · '.($c['users'][$n]['name']??'Unavailable user');
        foreach(['RingGroup'=>['ring_groups','Ring Group'],'IVR'=>['receptionists','Digital Receptionist'],'Queue'=>['queues','Call Queue'],'RoutePoint'=>['scripts','Call Script']] as $kind=>[$key,$title])if($type===$kind){foreach($c[$key]??[] as $row)if((string)$row['number']===$n)return $title.' · '.$n.' · '.$row['name'];return $title.' · '.$n.' · Unavailable';}
        return match($type){'None','EndCall'=>'End Call','External'=>'External Number · '.($dest['external']??''),default=>$type.' · '.$n};
    }
    /** The first selected destination, following the same schedule order as incoming Lua. */
    public static function current(array $rule,array $c,?int $now=null): array {
        $now??=time();$dest=$rule['office'];$dept=pbx_schedule::department($c,(string)($rule['office_department']??$dest['number']??''));
        $clock=(new DateTimeImmutable('@'.$now))->setTimezone(new DateTimeZone($c['timezone']??'UTC'));
        $office=$dept?pbx_schedule::office($dept,$c['timezone']??'UTC',$now):['open'=>pbx_schedule::inside($c['default_hours']??[],(int)$clock->format('w'),$clock->format('H:i')),'holiday'=>false];
        if(($rule['hours']['type']??'OfficeHours')!=='OfficeHours')$office['open']=pbx_schedule::inside($rule['hours']??[],(int)$clock->format('w'),$clock->format('H:i'));
        $slot='office';if($office['holiday']&&!empty($rule['use_holiday']))$slot='holiday';elseif(!$office['open']&&!empty($rule['use_outside']))$slot='outside';
        return ['slot'=>$slot,'destination'=>$rule[$slot]??['type'=>'None'],'label'=>self::label($rule[$slot]??['type'=>'None'],$c)];
    }
    public function snapshot(string $trunk): array {
        $this->owner();$c=(new pbx_admin($this->db))->config();if(!isset($c['trunks'][$trunk]))throw new InvalidArgumentException('Choose a trunk from this PBX.');
        $rules=[];foreach($c['inbound_rules'] as $r)if((string)$r['trunk_id']===$trunk){$service=$this->callback($r['rule_id']);$current=self::current($r,$c);if($service&&$service['enabled']&&$service['prompt_state']==='ready')$current=['slot'=>'callback','label'=>'Call Me Back · '.$service['name']];$rules[]=['rule'=>$r,'callback'=>$service,'revision'=>$this->revision($r,$service),'current'=>$current];}
        return ['config'=>$c,'rules'=>$rules];
    }
    private function destination(array $in,string $slot,array $c,array $old): array {
        $value=$this->text($in,$slot,50);if($value==='keep')return $old;
        $choices=(new pbx_admin($this->db))->destinations($c);if(!isset($choices[$value]))throw new InvalidArgumentException('Choose a destination from this PBX.');
        [$type,$number]=explode(':',$value,2);$external='';if($type==='External'){$external=$this->text($in,$slot.'_external',32);if(!preg_match('/^\+?[0-9]{1,32}$/D',$external))throw new InvalidArgumentException('Enter a valid outside number.');}
        if($type==='Extension'&&empty($c['users'][$number]['enabled']))throw new InvalidArgumentException('Choose an enabled extension.');
        return ['type'=>$type,'number'=>$number,'external'=>$external];
    }
    public function save(string $trunk,array $in): void {
        $this->owner();$rule=$this->text($in,'incoming_rule',36);$revision=$this->text($in,'route_revision',64);
        $this->db->beginTransaction();try{
            $c=(new pbx_admin($this->db))->config(true);if(!isset($c['trunks'][$trunk]))throw new InvalidArgumentException('Choose a trunk from this PBX.');
            $i=null;foreach($c['inbound_rules'] as $index=>$r)if($r['rule_id']===$rule&&(string)$r['trunk_id']===$trunk){$i=$index;break;}if($i===null)throw new InvalidArgumentException('Choose an incoming number belonging to this trunk.');
            $r=&$c['inbound_rules'][$i];$callback=$this->callback($rule,true);if(!hash_equals($this->revision($r,$callback),$revision))throw new RuntimeException('This route changed since you opened it. Refresh before saving again.');
            $value=$this->text($in,'office',50);$cmb=str_starts_with($value,'CallMeBack:')?substr($value,11):null;
            if($cmb!==null){if(!is_uuid($cmb))throw new InvalidArgumentException('Set up Call Me Back for this number first.');}
            else {
                foreach(['office','outside','holiday'] as $slot)$r[$slot]=$this->destination($in,$slot,$c,$r[$slot]??['type'=>'None','number'=>'','external'=>'']);
                $department=$this->text($in,'office_department',40);if($department!==''&&!in_array($department,array_map('strval',array_column($c['departments']??[],'number')),true))throw new InvalidArgumentException('Choose an office-hours department from this PBX.');
                if($department!==($r['office_department']??'')){if($department!==''){$r['office_department']=$department;$r['hours']=['type'=>'OfficeHours','periods'=>[]];}else unset($r['office_department']);}
                foreach(['use_outside','use_holiday'] as $flag){if(isset($in[$flag])&&$in[$flag]!=='1')throw new InvalidArgumentException('Choose a valid office-hours option.');$r[$flag]=isset($in[$flag]);}
            }
            if($callback||$cmb!==null)(new pbx_call_me_back($this->db))->routeIncoming($c,$rule,$cmb,($in['confirm_callback']??'')==='1');
            $this->q('update v_pbx_restore set config=cast(:c as jsonb) where domain_uuid=:d',['d'=>$this->domain,'c'=>json_encode($c,JSON_THROW_ON_ERROR)]);
            (new pbx_staff_access($this->db))->audit('incoming_route',$rule);
            $this->db->commit();
        }catch(Throwable $e){if($this->db->inTransaction())$this->db->rollBack();throw $e;}
        // Each new call reads this rule from PostgreSQL. There is no provider reload.
    }
}
