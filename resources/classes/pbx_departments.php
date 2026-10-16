<?php
/** Department membership and visibility inside one PBX configuration. */
class pbx_departments {
    public static function objects(array $config): array {
        $out=[];
        foreach($config['users']??[] as $number=>$user)$out[(string)$number]=['number'=>(string)$number,'name'=>$user['name']??(string)$number,'kind'=>'User'];
        foreach(['queues'=>'Call Queue','ring_groups'=>'Ring Group','receptionists'=>'Digital Receptionist','scripts'=>'Call Script','trunks'=>'SIP Trunk'] as $key=>$kind)
            foreach($config[$key]??[] as $object){$number=(string)$object['number'];$out[$number]??=['number'=>$number,'name'=>$object['name']??$number,'kind'=>$kind];}
        return $out;
    }
    public static function find(array $config,string $id): array {
        foreach($config['departments']??[] as $department)if((string)$department['number']===$id)return $department;
        throw new InvalidArgumentException('Choose a department from this PBX.');
    }
    public static function memberships(array $config,string $number): array {
        $out=[];foreach($config['departments']??[] as $department)foreach($department['members']??[] as $member)
            if((string)$member['number']===$number){$out[]=(string)$department['number'];break;}
        return $out;
    }
    public static function assign(array &$config,string $number,string $primary,?array $additional=null): void {
        if($primary!=='')self::find($config,$primary);
        $ids=$additional??($primary===''?[]:self::memberships($config,$number));
        if(count($ids)>1000)throw new InvalidArgumentException('Choose departments from this PBX.');
        foreach($ids as $id){if(!is_string($id))throw new InvalidArgumentException('Choose departments from this PBX.');self::find($config,$id);}
        if($primary!=='')$ids[]=$primary;
        $ids=array_values(array_unique($ids));$primary=$primary!==''?$primary:($ids[0]??'');
        foreach($config['departments'] as &$department){
            $found=false;$members=[];
            foreach($department['members']??[] as $member){
                if((string)$member['number']!==$number){$members[]=$member;continue;}
                if(in_array((string)$department['number'],$ids,true)&&!$found){$member['primary']=(string)$department['number']===$primary;$members[]=$member;$found=true;}
            }
            if(!$found&&in_array((string)$department['number'],$ids,true))$members[]=['number'=>$number,'primary'=>(string)$department['number']===$primary];
            $department['members']=$members;
        }unset($department);
    }
    public static function visible(array $config,string $viewer,string $target): bool {
        if($viewer===$target)return true;
        $targetDepartments=self::memberships($config,$target);
        if(!$targetDepartments)return true;
        $own=self::memberships($config,$viewer);
        foreach($targetDepartments as $id){$department=self::find($config,$id);if(($department['publish_information']??true)||in_array($id,$own,true))return true;}
        return false;
    }
    public static function outboundIds(array $config,array $rule): array {
        $ids=array_map('strval',$rule['department_ids']??[]);
        foreach($config['departments']??[] as $department)if(in_array($department['name'],$rule['departments']??[],true))$ids[]=(string)$department['number'];
        return array_values(array_unique($ids));
    }
}
