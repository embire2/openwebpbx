<?php
/** Durable native CDR import. Delete a spool file only after its CDR and scoped history are saved. */
class pbx_call_records {
    private PDO $db;
    public function __construct(?PDO $db=null){if(PHP_SAPI!=='cli')throw new RuntimeException('Call-record import requires the local service.');$this->db=$db??database::new()->db;}
    protected function directory(): string {return rtrim((string)(new settings)->get('switch','log','/var/log/freeswitch'),'/\\').'/xml_cdr';}
    private function q(string $sql,array $p=[]): PDOStatement {$s=$this->db->prepare($sql);$s->execute($p);return$s;}
    public static function variables(string $xml): array {
        if(strlen($xml)>3000000||preg_match('/<!\s*(?:DOCTYPE|ENTITY)/i',$xml))throw new InvalidArgumentException('Unsafe native call record.');
        $old=libxml_use_internal_errors(true);try{$doc=new DOMDocument;if(!$doc->loadXML($xml,LIBXML_NONET)||$doc->doctype||$doc->documentElement?->tagName!=='cdr')throw new InvalidArgumentException('Invalid native call record.');$v=[];$xp=new DOMXPath($doc);foreach($xp->query('/cdr/variables/*')as$n){ $value=urldecode($n->textContent);if(isset($v[$n->nodeName])&&$v[$n->nodeName]!==$value&&in_array($n->nodeName,['uuid','call_uuid','domain_uuid','domain_name','extension_uuid','openweb_scope_origin','openweb_scope_target','openweb_scope_service'],true))throw new InvalidArgumentException('Conflicting call-record identity variable.');$v[$n->nodeName]=$value;}return$v;}finally{libxml_clear_errors();libxml_use_internal_errors($old);}
    }
    public function tick(int $limit=100): array {
        $dir=$this->directory();$counts=['imported'=>0,'retained'=>0,'quarantined'=>0];if(!is_dir($dir)||is_link($dir))return$counts;
        $lock=fopen($dir.'/.openweb-import.lock','c');if(!$lock||!flock($lock,LOCK_EX|LOCK_NB)){if($lock)fclose($lock);return$counts;}
        try{foreach(new DirectoryIterator($dir)as$f){if(array_sum($counts)>=max(1,min(500,$limit)))break;$name=$f->getFilename();if(!$f->isFile()||$f->isLink()||!preg_match('/^(?:a_)?([a-f0-9-]{36})\.cdr\.xml$/D',$name,$m)||$f->getMTime()>time()-2)continue;$path=$f->getPathname();
            try{
                if($f->getSize()>3000000)throw new InvalidArgumentException('Oversized native call record.');$bytes=file_get_contents($path);$v=self::variables($bytes);$id=$v['uuid']??$v['call_uuid']??'';$d=$v['domain_uuid']??'';
                if(!is_uuid($id)||$id!==$m[1]||!is_uuid($d))throw new InvalidArgumentException('Call-record identity differs.');
                $raw=$this->q('select r.config from v_pbx_restore r join v_domains d using(domain_uuid) where r.domain_uuid=? and d.domain_name=?',[$d,$v['domain_name']??''])->fetchColumn();if(!$raw)throw new InvalidArgumentException('Call-record PBX is no longer available.');$c=json_decode($raw,true,512,JSON_THROW_ON_ERROR);
                $existing=$this->q('select domain_uuid from v_xml_cdr where xml_cdr_uuid=?',[$id])->fetchColumn();if($existing&&$existing!==$d)throw new InvalidArgumentException('Call-record ownership differs.');
                if(!$existing){$import=new xml_cdr(['database'=>database::new()]);$import->file='.openweb-retain-'.bin2hex(random_bytes(16));$import->xml_array(0,str_starts_with($name,'a_')?'a':'b',$bytes);}
                $this->db->beginTransaction();try{
                    $r=$this->q('select * from v_xml_cdr where xml_cdr_uuid=? and domain_uuid=? for update',[$id,$d])->fetch(PDO::FETCH_ASSOC);if(!$r)throw new RuntimeException('Call-record storage will retry.');
                    $json=json_decode($r['json']??'{}',true);if(!is_array($json))$json=[];if(!is_array($json['variables']??null))$json['variables']=[];
                    foreach(['openweb_scope_origin','openweb_scope_target','openweb_scope_service','extension_uuid','provider_uuid','queue_extension']as$k)if(isset($v[$k]))$json['variables'][$k]=$v[$k];
                    $answered=$this->q("select provider_uuid from v_pbx_provider_attempts where domain_uuid=? and call_uuid=? and state='answered'",[$d,$id])->fetchAll(PDO::FETCH_COLUMN);if(count($answered)===1){$this->q('update v_xml_cdr set provider_uuid=? where domain_uuid=? and xml_cdr_uuid=?',[$answered[0],$d,$id]);$json['variables']['provider_uuid']=$answered[0];}
                    $this->q('update v_xml_cdr set json=? where domain_uuid=? and xml_cdr_uuid=?',[json_encode($json,JSON_THROW_ON_ERROR),$d,$id]);
                    $owners=[];foreach(['openweb_scope_origin','openweb_scope_target']as$k)if(isset($c['users'][$v[$k]??'']))$owners[]=$v[$k];foreach($c['users']as$n=>$u)if(($r['extension_uuid']??'')===$u['extension_uuid'])$owners[]=(string)$n;
                    foreach(array_unique($owners)as$n){$out=($v['openweb_scope_origin']??'')===$n;$party=$out?($r['destination_number']??''):($r['caller_id_number']??'');$kind=$out?'Outbound':'Inbound';if(($r['direction']??'')==='local')$kind=$out?'InternalOutbound':'InternalInbound';
                        $this->q('insert into v_pbx_call_history(history_uuid,domain_uuid,owner_number,party_number,party_name,call_type,start_time,answer_time,end_time,end_status,source_id)values(?,?,?,?,?,?,to_timestamp(?),to_timestamp(nullif(?,0)),to_timestamp(nullif(?,0)),?,?) on conflict(domain_uuid,source_id) do nothing',[uuid(),$d,$n,$party,$out?($c['users'][$party]['name']??$party):($r['caller_id_name']??$party),$kind,(int)($r['start_epoch']??0),(int)($r['answer_epoch']??0),(int)($r['end_epoch']??0),(int)$r['billsec']>0?'Answered':($r['hangup_cause']??'Missed'),'native/'.$id.'/'.$n]);
                    }
                    $this->db->commit();
                }catch(Throwable$e){if($this->db->inTransaction())$this->db->rollBack();throw$e;}
                if(is_file($path)&&hash_equals(hash('sha256',$bytes),hash_file('sha256',$path)))unlink($path);$counts['imported']++;
            }catch(InvalidArgumentException$e){error_log('OpenWeb PBX call record: '.$e->getMessage());$failed=$dir.'/failed/openweb';if(!is_dir($failed))mkdir($failed,0770,true);if(!is_link($failed)&&!file_exists($failed.'/'.$name)&&rename($path,$failed.'/'.$name))$counts['quarantined']++;else $counts['retained']++;}
            catch(Throwable){$counts['retained']++;}
        }}finally{flock($lock,LOCK_UN);fclose($lock);}return$counts;
    }
}
