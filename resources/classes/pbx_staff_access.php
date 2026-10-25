<?php
/** Department-bound web access. Native/global administrator permissions are never granted here. */
class pbx_staff_denied extends RuntimeException {}
class pbx_staff_access {
    private PDO $db;
    public readonly string $domain;
    public readonly string $actor;
    private const ROLES = [
        'user'=>['personal'],
        'receptionist'=>['personal','live','control','override'],
        'supervisor'=>['personal','live','queues','reports'],
        'department_admin'=>['personal','users','routing','providers','hours','phones'],
        'manager'=>['personal','live','control','override','queues','reports','recordings','users'],
        'owner'=>['personal','live','control','override','queues','reports','recordings','users','routing','providers','hours','phones','staff'],
    ];
    public function __construct(?PDO $db=null,?string $domain=null) {
        $this->db=$db??database::new()->db;$this->domain=$domain??(string)($_SESSION['domain_uuid']??'');$this->actor=(string)($_SESSION['user_uuid']??'');
    }
    public static function roles(): array {return ['user'=>'User','receptionist'=>'Receptionist','supervisor'=>'Supervisor','department_admin'=>'Department Administrator','manager'=>'Manager','owner'=>'Owner'];}
    private function q(string $sql,array $args=[]): PDOStatement {$s=$this->db->prepare($sql);$s->execute($args);return $s;}
    public function installed(): bool {return (bool)$this->q("select to_regclass('v_pbx_staff_roles')")->fetchColumn();}
    public function owner(): bool {return !empty($_SESSION['authorized'])&&is_uuid($this->actor)&&is_uuid($this->domain)&&(new pbx_setup($this->db))->canManage()&&(new pbx_tenants($this->db))->canDomain($this->domain);}
    public function config(bool $lock=false): array {
        if(!is_uuid($this->domain))throw new pbx_staff_denied('Choose your PBX.');
        $v=$this->q("select r.config from v_pbx_restore r join v_domains d using(domain_uuid) where r.domain_uuid=? and d.domain_enabled='true' and not exists(select 1 from v_pbx_services s join v_pbx_tenants t using(tenant_uuid) where s.domain_uuid=d.domain_uuid and not t.enabled)".($lock?' for update of r':''),[$this->domain])->fetchColumn();
        if(!$v)throw new pbx_staff_denied('This PBX is unavailable.');return json_decode($v,true,512,JSON_THROW_ON_ERROR);
    }
    /** Re-read membership/roles on every decision so revoked or moved staff lose access. */
    public function grants(?array $c=null): array {
        if(empty($_SESSION['authorized'])||!is_uuid($this->actor)||!is_uuid($this->domain)||!$this->installed())return [];
        $c??=$this->config();$out=[];
        $rows=$this->q("select r.*,e.number_alias from v_pbx_staff_roles r join v_users u on u.user_uuid=r.user_uuid join v_extensions e on e.extension_uuid=r.extension_uuid and e.domain_uuid=r.domain_uuid where r.domain_uuid=? and r.user_uuid=? and r.enabled and u.user_enabled='true' and e.enabled='true'",[$this->domain,$this->actor])->fetchAll(PDO::FETCH_ASSOC);
        foreach($rows as$r)foreach($c['users']??[] as$n=>$u)if($u['extension_uuid']===$r['extension_uuid']&&!empty($u['enabled'])&&in_array($r['department_id'],pbx_departments::memberships($c,(string)$n),true)&&isset(self::ROLES[$r['role']])){$r['number']=(string)$n;$out[]=$r;break;}
        return $out;
    }
    public function active(): bool {try{return $this->grants()!==[];}catch(Throwable){return false;}}
    public function ownNumber(?array $c=null): string {$g=$this->grants($c);return $g[0]['number']??'';}
    public function departments(string $cap,?array $c=null): array {
        $c??=$this->config();if($this->owner())return array_map('strval',array_column($c['departments']??[],'number'));
        $out=[];foreach($this->grants($c)as$g)if(in_array($cap,self::ROLES[$g['role']],true))$out[]=$g['department_id'];return array_values(array_unique($out));
    }
    public function can(string $cap,?array $c=null): bool {return $this->owner()||$this->departments($cap,$c)!==[];}
    public function permits(string $cap,string $number,?array $c=null,bool $all=false): bool {
        $c??=$this->config();if($this->owner())return true;
        if($cap==='personal')return $number!==''&&$number===$this->ownNumber($c);
        $ids=pbx_departments::memberships($c,$number);$allowed=$this->departments($cap,$c);
        return $ids!==[]&&($all?array_diff($ids,$allowed)===[]:array_intersect($ids,$allowed)!==[]);
    }
    public function requireNumber(string $cap,string $number,?array $c=null,bool $all=false): void {if(!$this->permits($cap,$number,$c,$all))throw new pbx_staff_denied('Your role does not allow this action in that department.');}
    public function visible(string $number,?array $c=null): bool {$c??=$this->config();return $this->owner()||($this->active()&&pbx_departments::visible($c,$this->ownNumber($c),$number));}
    public function filtered(array $c): array {
        if($this->owner())return $c;$copy=$c;$own=$this->ownNumber($c);
        foreach($copy['users']??[]as$n=>$u)if(!$this->visible((string)$n,$c))unset($copy['users'][$n]);
        foreach(['queues','ring_groups','receptionists','trunks','scripts']as$kind)$copy[$kind]=array_values(array_filter($c[$kind]??[],fn($o)=>$this->permits($kind==='trunks'?'providers':($kind==='queues'?'queues':'routing'),(string)$o['number'],$c)||$this->permits('live',(string)$o['number'],$c)||$this->permits('routing',(string)$o['number'],$c)));
        // Trunks are keyed by their stable source number, not their array position.
        $copy['trunks']=[];foreach($c['trunks']??[]as$id=>$t)if($this->permits('providers',(string)$id,$c))$copy['trunks'][$id]=$t;
        $ids=[];foreach(['personal','hours','override','staff','users','routing','providers']as$cap)$ids=array_merge($ids,$this->departments($cap,$c));
        $copy['departments']=array_values(array_filter($c['departments']??[],fn($d)=>in_array((string)$d['number'],$ids,true)));
        foreach($copy['departments']as&$d)$d['members']=array_values(array_filter($d['members']??[],fn($m)=>isset($copy['users'][$m['number']])||$this->permits('routing',(string)$m['number'],$c)));unset($d);
        $copy['inbound_rules']=[];$copy['outbound_rules']=[];$copy['phones']=[];$copy['contacts']=[];$copy['calling_rules']=[];
        foreach($copy['users']as&$u)unset($u['phone_properties']);unset($u);return $copy;
    }
    public function validateEdit(string $type,string $key,array $in,array $c): void {
        if($this->owner())return;$cap=match($type){'user'=>'users','hours'=>'hours','trunk'=>'providers','queue','ring_group','receptionist'=>'routing',default=>throw new pbx_staff_denied('This setting is managed by the PBX owner.')};
        if($type==='hours'){if(!in_array($key,$this->departments('hours',$c),true))throw new pbx_staff_denied('Choose your department.');return;}
        if($key!=='new')$this->requireNumber($cap,$key,$c,true);
        if($key!=='new'&&in_array($type,['queue','ring_group'],true)){foreach($c[$type==='queue'?'queues':'ring_groups']as$o)if((string)$o['number']===$key)foreach($o['members']??[]as$m)$this->requireNumber('routing',(string)$m['number'],$c,true);}
        if($type==='user'&&$key!=='new'){
            $rank=['user'=>0,'receptionist'=>1,'supervisor'=>2,'manager'=>3,'department_admin'=>3,'owner'=>4];$mine=0;
            foreach($this->grants($c)as$g)$mine=max($mine,$rank[$g['role']]);
            $target=$this->q('select role from v_pbx_staff_roles where domain_uuid=? and extension_uuid=? and enabled',[$this->domain,$c['users'][$key]['extension_uuid']])->fetchAll(PDO::FETCH_COLUMN);
            foreach($target as$r)if(($rank[$r]??99)>=$mine&&$key!==$this->ownNumber($c))throw new pbx_staff_denied('Only the PBX owner may change this staff account.');
        }
        $department=$in['department']??'';
        if($key==='new'&&(!is_string($department)||!in_array($department,$this->departments($cap,$c),true)))throw new pbx_staff_denied('Choose a department you manage.');
        foreach(array_merge($department!==''?[$department]:[],$in['departments']??[])as$id)if(!is_string($id)||!in_array($id,$this->departments($cap,$c),true))throw new pbx_staff_denied('You cannot move an item to another department.');
        foreach($in['members']??[]as$n)$this->requireNumber($cap,(string)$n,$c,true);
        foreach($in['options']??[] as$o)if(is_array($o)&&isset($o['destination'])&&is_string($o['destination'])){[$kind,$n]=array_pad(explode(':',$o['destination'],2),2,'');if($n!==''&&!$this->visible($n,$c))throw new pbx_staff_denied('Choose a visible menu destination.');}
        foreach(['no_answer','busy','not_registered','away','office_closed','office_break','office_holiday','office_open_route','office_closed_route','destination','timeout_destination']as$f)if(isset($in[$f])&&is_string($in[$f])){[$kind,$n]=array_pad(explode(':',$in[$f],2),2,'');if($n!==''&&!$this->visible($n,$c))throw new pbx_staff_denied('Choose a visible destination.');}
    }
    public function audit(string $action,string $target,string $result='accepted'): void {
        $this->q('insert into v_pbx_staff_audit(audit_uuid,domain_uuid,actor_uuid,action,target,result) values(?,?,?,?,?,?)',[uuid(),$this->domain,$this->actor,$action,$target,$result]);
    }
    public function staff(): array {
        if(!$this->can('staff'))throw new pbx_staff_denied('Staff administration is not allowed.');$ids=$this->departments('staff');
        $rows=$this->q('select r.staff_role_uuid,r.department_id,r.role,r.enabled,r.extension_uuid,u.username,u.user_enabled from v_pbx_staff_roles r join v_users u using(user_uuid) where r.domain_uuid=? order by u.username,r.department_id',[$this->domain])->fetchAll(PDO::FETCH_ASSOC);
        return $this->owner()?$rows:array_values(array_filter($rows,fn($r)=>in_array($r['department_id'],$ids,true)));
    }
    public function overrideHours(array $in): void {
        $id=$in['department']??null;$state=$in['state']??null;$minutes=filter_var($in['minutes']??null,FILTER_VALIDATE_INT,['options'=>['min_range'=>1,'max_range'=>1440]]);
        if(!is_string($id)||!in_array($state,['open','closed','automatic'],true)||$minutes===false)throw new InvalidArgumentException('Choose a department, opening status and duration up to 24 hours.');
        $this->db->beginTransaction();try{$c=$this->config(true);if(!in_array($id,$this->departments('override',$c),true))throw new pbx_staff_denied('Office-hour override is not allowed for this department.');
            foreach($c['departments']as&$d)if((string)$d['number']===$id)$d['office_override']=$state==='automatic'?[]:['state'=>$state,'expires'=>time()+$minutes*60];unset($d);
            $this->q('update v_pbx_restore set config=?::jsonb where domain_uuid=?',[json_encode($c,JSON_THROW_ON_ERROR),$this->domain]);$this->audit('hours_override',$id.'/'.$state);$this->db->commit();
        }catch(Throwable$e){if($this->db->inTransaction())$this->db->rollBack();throw$e;}
    }
}
