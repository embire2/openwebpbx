<?php
/** Company and personal contacts. All identifiers and ownership are server controlled. */
class pbx_contacts {
    public function __construct(private PDO $db,private ?string $personal=null) {}
    private function config(bool $lock=false): array {
        $s=$this->db->prepare('select config from v_pbx_restore where domain_uuid=?'.($lock?' for update':''));$s->execute([$_SESSION['domain_uuid']]);$value=$s->fetchColumn();
        if(!$value)throw new OutOfBoundsException('PBX unavailable.');return json_decode($value,true,512,JSON_THROW_ON_ERROR);
    }
    public function listing(): array {
        $rows=[];foreach($this->config()['contacts']??[] as $index=>$c){$owner=(string)($c['owner']??'');if($this->personal!==null&&$owner!==''&&$owner!==$this->personal)continue;
            $rows[]=array_intersect_key($c,array_flip(['first_name','last_name','company','phone','email','owner']))+['id'=>$c['id']??'legacy-'.$index];}
        return $rows;
    }
    public function save(string $id,array $in,bool $delete=false): array {
        $this->db->beginTransaction();try{
            $c=$this->config(true);$index=null;
            if($id!=='')foreach($c['contacts']??[] as $i=>$row)if(($row['id']??'legacy-'.$i)===$id){$index=$i;break;}
            if(($id!==''&&$index===null)||($delete&&$id===''))throw new OutOfBoundsException('Contact unavailable.');
            if($index!==null&&$this->personal!==null&&($c['contacts'][$index]['owner']??'')!==$this->personal)throw new pbx_api_access_denied('Only the owner can change this contact.');
            if($delete){if(($in['confirm_delete']??false)!==true)throw new InvalidArgumentException('Confirm deletion.');unset($c['contacts'][$index]);}
            else {
                $row=[];foreach(['first_name'=>100,'last_name'=>100,'company'=>200,'phone'=>32,'email'=>254] as $field=>$max){$v=$in[$field]??'';if(!is_string($v)||mb_strlen($v)>$max||preg_match('/[\x00-\x1f\x7f]/',$v))throw new InvalidArgumentException('Check contact details.');$row[$field]=trim($v);}
                if(!preg_match('/^\+?[0-9*#]{1,32}$/D',$row['phone'])||($row['email']!==''&&!filter_var($row['email'],FILTER_VALIDATE_EMAIL)))throw new InvalidArgumentException('Choose a valid phone number and email.');
                $owner=$this->personal??($in['owner']??'');if(!is_string($owner)||($owner!==''&&!isset($c['users'][$owner])))throw new InvalidArgumentException('Choose a contact owner in this PBX.');
                if($this->personal!==null&&isset($in['owner'])&&$in['owner']!==$this->personal)throw new pbx_api_access_denied('A personal contact cannot be assigned to another user.');
                if($id===''&&count($c['contacts']??[])>=10000)throw new OverflowException('This PBX has reached its contact limit.');
                $id=$id!==''?$id:uuid();$row+=['id'=>$id,'owner'=>$owner];if($index===null)$c['contacts'][]=$row;else $c['contacts'][$index]=$row;
            }
            // Preserve positions of imported legacy contacts; deleting one must not change others' IDs.
            $c['contacts']??=[];foreach($c['contacts'] as $i=>&$row)$row['id']??='legacy-'.$i;unset($row);$c['contacts']=array_values($c['contacts']);
            $s=$this->db->prepare('update v_pbx_restore set config=?::jsonb where domain_uuid=?');$s->execute([json_encode($c,JSON_THROW_ON_ERROR),$_SESSION['domain_uuid']]);$this->db->commit();return $delete?['deleted'=>true]:['id'=>$id];
        }catch(Throwable $e){if($this->db->inTransaction())$this->db->rollBack();throw $e;}
    }
}
