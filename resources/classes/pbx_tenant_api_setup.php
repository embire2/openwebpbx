<?php
/** Prepare the current Desktop policy for a new, provider-free API PBX. */
final class pbx_tenant_api_setup {
    public function __construct(private PDO $db) {}
    private function query(string $sql,array $values=[]): PDOStatement {
        $q=$this->db->prepare($sql);$q->execute($values);return $q;
    }
    private function dialplan(string $domain,string $realm,string $number,string $mode,int $order): string {
        $id=uuid();$xml=new DOMDocument('1.0','UTF-8');$root=$xml->appendChild($xml->createElement('extension'));
        $name='OpenWeb API '.($number!==''?'user '.$number:'outbound');$root->setAttribute('name',$name);
        $condition=$root->appendChild($xml->createElement('condition'));$condition->setAttribute('field','destination_number');
        $pattern=$number!==''?'^'.preg_quote($number,'~').'$':'^.+$';$condition->setAttribute('expression',$pattern);
        $actions=[['set','domain_uuid='.$domain],['set','domain_name='.$realm],['lua','app.lua pbx_setup '.$mode.' '.($number!==''?$number:'all')]];
        foreach($actions as[$application,$data]){$action=$condition->appendChild($xml->createElement('action'));$action->setAttribute('application',$application);$action->setAttribute('data',$data);}
        $this->query("insert into v_dialplans(dialplan_uuid,domain_uuid,dialplan_name,dialplan_number,dialplan_context,dialplan_order,dialplan_continue,dialplan_enabled,dialplan_xml,dialplan_description)
            values(?,?,?,?,?,?,'false','true',?,'Created through the tenant API; manage this service in Admin.')",[$id,$domain,$name,$number,$realm,(string)$order,$xml->saveXML($root)]);
        $details=[['condition','destination_number',$pattern],...array_map(static fn($a)=>['action',$a[0],$a[1]],$actions)];
        foreach($details as$i=>[$tag,$type,$data])$this->query("insert into v_dialplan_details(dialplan_detail_uuid,domain_uuid,dialplan_uuid,dialplan_detail_tag,dialplan_detail_type,dialplan_detail_data,dialplan_detail_order,dialplan_detail_group,dialplan_detail_enabled)
            values(?,?,?,?,?,?,?,0,'true')",[uuid(),$domain,$id,$tag,$type,$data,10+$i*10]);
        return $id;
    }
    public function initialize(array $account,array $service,array $template): void {
        if (!$this->db->inTransaction()) throw new LogicException('PBX initialization requires the service creation transaction.');
        $id=$service['service_uuid']??'';
        if (!is_uuid($id) || !is_uuid($account['tenant_uuid']??'') || !is_uuid($account['user_uuid']??'')) throw new InvalidArgumentException('PBX service unavailable.');
        $row=$this->query("select s.domain_uuid,d.domain_name from v_pbx_services s
            join v_pbx_tenants t using(tenant_uuid) join v_domains d on d.domain_uuid=s.domain_uuid
            join v_users u on u.user_uuid=t.owner_user_uuid
            where s.service_uuid=? and s.tenant_uuid=? and s.created_by=? and u.user_uuid=?
            and t.enabled=true and d.domain_enabled::text='true' and u.user_enabled::text='true' for update of s,d",
            [$id,$account['tenant_uuid'],$account['user_uuid'],$account['user_uuid']])->fetch(PDO::FETCH_ASSOC);
        if (!$row) throw new OutOfBoundsException('PBX service unavailable.');
        $domain=$row['domain_uuid'];$realm=$row['domain_name'];$config=$template['config']??[];
        if (!empty($config['trunks']) || !empty($config['rules'])) throw new InvalidArgumentException('Choose a provider-free starter template.');
        $timezone=$config['timezone']??'Africa/Johannesburg';
        if (!in_array($timezone,DateTimeZone::listIdentifiers(),true) || pbx_sip_domain::validate($realm)!==$realm) throw new InvalidArgumentException('PBX template unavailable.');
        if ($this->query('select 1 from v_pbx_restore where domain_uuid=?',[$domain])->fetchColumn()) throw new DomainException('This PBX is already initialized.');
        $users=$this->query('select extension_uuid,extension,coalesce(nullif(number_alias,\'\'),extension) number,effective_caller_id_name from v_extensions where domain_uuid=? order by extension',[$domain])->fetchAll(PDO::FETCH_ASSOC);
        if (count($users)!==(int)($config['extension_count']??0)) throw new RuntimeException('PBX template extension count differs from the new service.');
        $policy=['realm'=>$realm,'timezone'=>$timezone,'origin'=>'OpenWeb PBX','users'=>[],'trunks'=>new stdClass];
        foreach(['queues','ring_groups','receptionists','departments','inbound_rules','outbound_rules','phones','contacts','specials','scripts']as$key)$policy[$key]=[];
        $mapper=new pbx_setup_provisioner($this->db);$seen=[];
        foreach($users as$user){
            $number=(string)$user['number'];$start=(int)($config['extension_start']??100);
            if (!ctype_digit($number) || (int)$number<$start || (int)$number>=$start+count($users) || isset($seen[$number])) throw new RuntimeException('PBX template extension range differs from the new service.');
            pbx_service_codes::assertAvailable($number);$seen[$number]=true;
            $mailbox=$this->query('select voicemail_uuid from v_voicemails where domain_uuid=? and voicemail_id=?',[$domain,$number])->fetchColumn();
            if (!is_string($mailbox) || !is_uuid($mailbox)) throw new RuntimeException('PBX template voicemail is unavailable.');
            $dialplan=$this->dialplan($domain,$realm,$number,'user',80);
            $policy['users'][$number]=$mapper->guidedUser(['number'=>$number,'auth_id'=>$user['extension'],
                'name'=>$user['effective_caller_id_name']?:'Extension '.$number,'email'=>'','enabled'=>true],$user['extension_uuid'],$mailbox,$dialplan);
        }
        $this->dialplan($domain,$realm,'','outbound',900);$policy['users']=(object)$policy['users'];
        $this->query("insert into v_pbx_restore(domain_uuid,source_version,config,report) values(?,?,cast(? as jsonb),cast(? as jsonb))",
            [$domain,'OpenWeb PBX '.pbx_updates::version(),json_encode($policy,JSON_THROW_ON_ERROR),json_encode(['origin'=>'tenant_api','counts'=>['users'=>count($users),'voicemails'=>count($users),'trunks'=>0]],JSON_THROW_ON_ERROR)]);
    }
}
