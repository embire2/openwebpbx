<?php
/** Native objects and a domain-bound routing policy for the inspected V20 backup. */
final class pbx_v20_restore {
    public const MEDIA_ROOT='/var/lib/freeswitch/storage/openwebpbx';
    private PDO $db;
    private string $domain;
    private string $realm;
    private array $policy;
    private array $media=[];
    private array $mediaFiles=[];
    private array $missingPrompts=[];
    public function __construct(PDO $db){$this->db=$db;}
    private function query(string $sql,array $params=[]): PDOStatement {
        $s=$this->db->prepare($sql);
        foreach($params as $k=>$v)$s->bindValue(':'.$k,$v,$v===null?PDO::PARAM_NULL:(is_bool($v)?PDO::PARAM_BOOL:(is_int($v)?PDO::PARAM_INT:PDO::PARAM_STR)));
        $s->execute();return $s;
    }
    private function insert(string $table,array $row): void {
        $keys=array_keys($row);$this->query('insert into '.$table.'('.implode(',',$keys).') values('.implode(',',array_map(fn($k)=>':'.$k,$keys)).')',$row);
    }
    /** Pure gateway mapping shared by setup, native restore and the provider editor.
     * Credentials are private input/output: never include this array in a preview.
     * SIP authentication and REGISTER are independent provider requirements.
     */
    public static function gatewaySettings(array $trunk): array {
        $text=static function(mixed $value,string $label,int $max=253):string {
            if(!is_string($value)&&!is_int($value)&&$value!==null)throw new InvalidArgumentException('Invalid '.$label.'.');
            $value=trim((string)$value);if(strlen($value)>$max||preg_match('/[\x00-\x1f\x7f]/',$value)||str_contains($value,'${'))throw new InvalidArgumentException('Invalid '.$label.'.');return $value;
        };
        $flag=static function(mixed $value,string $label):bool {return match($value){true,'true','1',1=>true,false,'false','0',0=>false,default=>throw new InvalidArgumentException('Invalid '.$label.'.')};};
        $integer=static function(mixed $value,string $label,int $min,int $max):int {if(is_bool($value)||(!is_int($value)&&!is_string($value)))throw new InvalidArgumentException('Invalid '.$label.'.');$v=filter_var($value,FILTER_VALIDATE_INT,['options'=>['min_range'=>$min,'max_range'=>$max]]);if($v===false)throw new InvalidArgumentException('Invalid '.$label.'.');return $v;};
        $host=static function(mixed $value,string $label)use($text):string {
            $v=strtolower($text($value,$label));$ip=trim($v,'[]');
            if(!filter_var($ip,FILTER_VALIDATE_IP)&&!preg_match('/^(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)*[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$/D',$v))throw new InvalidArgumentException('Invalid '.$label.'.');
            return str_contains($ip,':')?'['.$ip.']':$v;
        };
        $endpoint=static function(mixed $value,string $label)use($text,$host,$integer):string {
            $v=$text($value,$label);if($v==='')return '';
            if(preg_match('/^\[([^\]]+)\](?::([0-9]+))?$/D',$v,$m))return $host($m[1],$label).(isset($m[2])?':'.$integer($m[2],$label.' port',1,65535):'');
            if(filter_var($v,FILTER_VALIDATE_IP,FILTER_FLAG_IPV6))return $host($v,$label);
            if(preg_match('/^([^:]+)(?::([0-9]+))?$/D',$v,$m))return $host($m[1],$label).(isset($m[2])?':'.$integer($m[2],$label.' port',1,65535):'');
            throw new InvalidArgumentException('Invalid '.$label.'.');
        };
        $identity=static function(mixed $value,string $label)use($text):string {$v=$text($value,$label,128);if(!preg_match('/^[A-Za-z0-9_.+@*!-]{0,128}$/D',$v))throw new InvalidArgumentException('Invalid '.$label.'.');return $v;};
        $server=$host($trunk['host']??'','SIP server');$transport=strtolower($text($trunk['transport']??'udp','SIP transport',3));if(!in_array($transport,['udp','tcp','tls'],true))throw new InvalidArgumentException('Unsupported SIP transport.');
        $port=$integer($trunk['port']??($transport==='tls'?5061:5060),'SIP port',1,65535);$register=$flag($trunk['register']??false,'SIP registration');
        $username=$identity($trunk['username']??'','SIP username');$password=$trunk['password']??'';
        if(!is_string($password)||strlen($password)>256||preg_match('/[\x00-\x1f\x7f]/',$password)||str_contains($password,'${'))throw new InvalidArgumentException('The SIP password cannot be represented safely.');
        $mode=strtolower($text($trunk['auth_mode']??(($username!==''||$password!==''||$register)?'credentials':'ip'),'SIP authentication mode',16));
        if(!in_array($mode,['credentials','ip'],true))throw new InvalidArgumentException('Invalid SIP authentication mode.');
        if($mode==='ip'&&$register)throw new InvalidArgumentException('IP authentication must not send REGISTER.');
        $auth=$identity($trunk['auth_username']??$username,'SIP authentication ID');if($mode==='ip'){$username='';$password='';$auth='';}
        $headers=$trunk['headers']??[];if(!is_array($headers))throw new InvalidArgumentException('Invalid provider header settings.');
        $fromHeader=$headers['FromUserPart']??'';$hostHeader=$headers['FromHostPart']??'';$contactHeader=$headers['ContactUser']??'';
        $fromUser=$trunk['from_user']??($fromHeader==='$AuthID'?$username:(!str_starts_with($fromHeader,'$')?$fromHeader:''));
        $fromDomain=$trunk['from_domain']??($hostHeader==='$GWHostPort'?$server.':'.$port:($hostHeader===''?$server:$hostHeader));
        $contact=$trunk['contact_user']??($trunk['extension']??($contactHeader==='$AuthID'?$username:(!str_starts_with($contactHeader,'$')?$contactHeader:'')));
        $callerInFrom=$flag($trunk['caller_id_in_from']??in_array($fromHeader,['$OutboundCallerId','$CallerNum'],true),'From caller ID');
        $codecs=$trunk['codecs']??[];if(!is_array($codecs)||!array_is_list($codecs)||count($codecs)>16)throw new InvalidArgumentException('Invalid provider codecs.');
        foreach($codecs as $codec)if(!is_string($codec)||!in_array($codec,['PCMU','PCMA','G729','G722','GSM','SPEEX','OPUS','iLBC','L16'],true))throw new InvalidArgumentException('Unsupported provider codec.');
        $cid=$trunk['sip_cid_type']??(isset($headers['RemotePartyIDCallingPartyUserPart'])?'rpid':(isset($headers['PAssertedIdentityUserPart'])?'pid':'none'));if(!in_array($cid,['none','rpid','pid'],true))throw new InvalidArgumentException('Invalid caller ID header type.');
        return ['proxy'=>$server.':'.$port,'username'=>$username,'password'=>$password,'auth_username'=>$auth,'realm'=>$text($trunk['realm']??'','SIP realm',128),
            'from_user'=>$identity($fromUser,'From user'),'from_domain'=>$endpoint($fromDomain,'From domain'),'register_proxy'=>$endpoint($trunk['register_proxy']??'','Registration proxy'),'outbound_proxy'=>$endpoint($trunk['outbound_proxy']??'','Outbound proxy'),
            'expire_seconds'=>$integer($trunk['expires']??3600,'Registration expiry',1,86400),'register'=>$register,'register_transport'=>$transport,'caller_id_in_from'=>$callerInFrom,'codec_prefs'=>implode(',',array_unique($codecs)),
            'channels'=>$integer($trunk['limit']??10,'Concurrent calls',1,10000),'extension'=>$identity($contact,'Contact user'),'extension_in_contact'=>$flag($trunk['extension_in_contact']??($contact!==''),'Contact user override')?'true':'false','sip_cid_type'=>$cid];
    }
    /** Declared numbers bound to one source provider; no global fallback wildcard. */
    public static function incomingNumbers(array $trunk): array {
        $dids=$trunk['dids']??'';if(is_string($dids))$dids=preg_split('/[,;\r\n]+/',$dids);if(!is_array($dids)||!array_is_list($dids)||count($dids)>1000)throw new InvalidArgumentException('Invalid provider incoming numbers.');
        $numbers=[];foreach(array_merge([$trunk['main_number']??''],$dids) as $number){if(!is_string($number))throw new InvalidArgumentException('Invalid provider incoming number.');$number=trim($number);if($number==='')continue;if(!preg_match('/^\*?\+?[0-9]{1,32}$/D',$number))throw new InvalidArgumentException('Invalid provider incoming number.');$numbers[]=$number;}
        return array_values(array_unique($numbers));
    }
    public static function incomingOrder(array $rule,int $index=0): int {
        if($index<0||$index>500)throw new InvalidArgumentException('Invalid incoming order.');
        return match($rule['condition']??''){'BasedOnDID'=>(str_starts_with($rule['number']??'','*')?500:100)+$index,'ForwardAll'=>1000+$index,default=>throw new InvalidArgumentException('Invalid incoming condition.')};
    }
    public static function incomingGatewayCondition(array $trunk): array {
        $id=$trunk['gateway_uuid']??'';if(!is_uuid($id))throw new InvalidArgumentException('An incoming provider has no native binding.');
        return ['${sip_gateway}','^(?:'.preg_quote($id,'~').')?$'];
    }
    /** The XML condition and Lua checks must select the same original SIP field. */
    public static function incomingCondition(array $rule,array $trunk): array {
        $field=match($trunk['source_field']??'ToUserPart'){'','ToUserPart'=>'${sip_to_user}','RequestLineURIUser'=>'${sip_req_user}',default=>throw new InvalidArgumentException('Unsupported incoming number source.')};
        $pattern=static fn(string $number)=>'\\+?'.(str_starts_with($number,'*')?'[0-9]*':'').preg_quote(ltrim($number,'*+'),'~');
        if(($rule['condition']??'')==='ForwardAll'){$numbers=self::incomingNumbers($trunk);$patterns=array_values(array_unique(array_map($pattern,$numbers)));return [$field,$patterns?'^'.(count($patterns)>1?'(?:'.implode('|',$patterns).')':$patterns[0]).'$':'^(?!)$'];}
        $number=$rule['number']??'';if(($rule['condition']??'')!=='BasedOnDID'||!is_string($number)||!preg_match('/^\*?\+?[0-9]{1,32}$/D',$number))throw new InvalidArgumentException('Invalid incoming number.');
        return [$field,'^'.$pattern($number).'$'];
    }
    /** Repair only provider metadata/native fields and DID selection of an existing restore.
     * Caller owns the transaction and deployment/reload. Dry run returns field counts only.
     * Existing enablement, IP bindings, UUIDs, routes, users and media are retained.
     */
    public function refreshTrunks(string $domain,array $plan,bool $dryRun=true,bool $allowChangedProviderIdentity=false): array {
        self::validate($plan);if(!$this->db->inTransaction()||!is_uuid($domain))throw new LogicException('Provider reconciliation requires a PBX transaction.');
        $stored=$this->query('select source_version,config from v_pbx_restore where domain_uuid=:d for update',['d'=>$domain])->fetch(PDO::FETCH_ASSOC);
        if(!$stored||$stored['source_version']!==$plan['source_version'])throw new InvalidArgumentException('The target PBX is not this verified restore.');
        $policy=json_decode($stored['config'],true,512,JSON_THROW_ON_ERROR);$source=$plan['v20'];
        if(count($policy['trunks']??[])!==count($plan['trunks'])||count($policy['inbound_rules']??[])!==count($source['inbound_rules']))throw new InvalidArgumentException('The restored provider or incoming-rule inventory has changed.');
        $expected=[];$nativeIds=[];$gatewayUpdates=[];$dialplanUpdates=[];$detailUpdates=[];$detailInserts=[];$gatewayDiffs=[];$policyDiffs=[];$incomingDiffs=0;$orderDiffs=0;$bindingDiffs=0;
        $same=static function(mixed $actual,mixed $want):bool {if(is_bool($want))return in_array($actual,[true,'true','t','1',1],true)===$want;if(is_int($want))return (string)$actual===(string)$want;return ($actual??'')===$want;};
        $canonical=static function(mixed $value)use(&$canonical):mixed {if(!is_array($value))return $value;if(!array_is_list($value))ksort($value);foreach($value as $key=>$item)$value[$key]=$canonical($item);return $value;};
        foreach($plan['trunks'] as $t){$key=$t['source_id'];$old=$policy['trunks'][$key]??null;$meta=$source['trunks'][$key]??null;
            if(!is_array($old)||!is_array($meta)||!is_uuid($old['gateway_uuid']??'')||isset($nativeIds[$old['gateway_uuid']]))throw new InvalidArgumentException('A source provider has no unique native mapping.');$nativeIds[$old['gateway_uuid']]=true;
            $row=$this->query('select * from v_gateways where domain_uuid=:d and gateway_uuid=:g for update',['d'=>$domain,'g'=>$old['gateway_uuid']])->fetch(PDO::FETCH_ASSOC);
            if(!$row)throw new InvalidArgumentException('A source provider belongs to another PBX or is missing.');
            $native=self::gatewaySettings(array_merge($meta,$t));
            if(!$allowChangedProviderIdentity&&(($old['host']??'')!==$t['host']||(int)($old['port']??0)!==$t['port']||($old['transport']??'udp')!==$t['transport']||($row['proxy']??'')!==$native['proxy']||!hash_equals((string)$row['username'],$native['username'])||!hash_equals((string)$row['password'],$native['password'])||!hash_equals((string)($row['auth_username']??''),$native['auth_username'])))throw new InvalidArgumentException('A provider address or authentication mapping was changed after restore. Review it before replacing those fields.');
            if(!$allowChangedProviderIdentity){
                $behavior=array_merge($meta,array_intersect_key($native,array_flip(['auth_username','realm','from_user','from_domain','register_proxy','outbound_proxy','caller_id_in_from','sip_cid_type','register'])));$behavior['contact_user']=$native['extension'];$behavior['extension_in_contact']=$native['extension_in_contact']==='true';
                foreach($behavior as $field=>$value){if(!array_key_exists($field,$old)||$canonical($old[$field])===$canonical($value))continue;
                    if($field==='extension_in_contact'&&in_array($old[$field],[true,'true','1',1],true)===$value)continue;
                    // Earlier restore versions lost the Name attribute and mistook
                    // caller-ID formatting XML for an actual outgoing number.
                    if($field==='source_field'&&$old[$field]==='')continue;
                    if($field==='caller_id'&&$old[$field]!==''&&$old[$field]===($meta['caller_id_rules']??''))continue;
                    throw new InvalidArgumentException('Provider behavior was changed after restore. Review the source reconciliation before replacing those fields.');
                }
            }
            $changed=[];foreach($native as $field=>$value)if(!$same($row[$field]??null,$value)){$changed[$field]=$value;$gatewayDiffs[$field]=($gatewayDiffs[$field]??0)+1;}
            if($changed)$gatewayUpdates[]=['id'=>$old['gateway_uuid'],'fields'=>$changed];
            $new=array_merge($old,$meta,['name'=>$t['name'],'host'=>$t['host'],'port'=>$t['port'],'transport'=>$t['transport'],'register'=>$t['register']]);
            foreach(['auth_username','realm','from_user','from_domain','register_proxy','outbound_proxy','caller_id_in_from','sip_cid_type'] as $field)$new[$field]=$native[$field];$new['contact_user']=$native['extension'];$new['extension_in_contact']=$native['extension_in_contact']==='true';
            // Explicitly retain operational state even if a future source includes it.
            foreach(['gateway_uuid','enabled','allowed_ips'] as $field)if(array_key_exists($field,$old))$new[$field]=$old[$field];
            foreach($new as $field=>$value)if($canonical($old[$field]??null)!==$canonical($value))$policyDiffs[$field]=($policyDiffs[$field]??0)+1;
            $policy['trunks'][$key]=$new;
        }
        foreach($source['inbound_rules'] as $r){$key=json_encode([(string)$r['trunk_id'],$r['condition'],$r['number']],JSON_THROW_ON_ERROR);$expected[$key]=($expected[$key]??0)+1;}
        foreach($policy['inbound_rules'] as $index=>$r){$key=json_encode([(string)$r['trunk_id'],$r['condition'],$r['number']],JSON_THROW_ON_ERROR);if(($expected[$key]??0)<1)throw new InvalidArgumentException('An incoming number changed after restore.');$expected[$key]--;
            if(!is_uuid($r['dialplan_uuid']??''))throw new InvalidArgumentException('An incoming number has no native rule.');
            $row=$this->query('select dialplan_xml,dialplan_order from v_dialplans where domain_uuid=:d and dialplan_uuid=:id for update',['d'=>$domain,'id'=>$r['dialplan_uuid']])->fetch(PDO::FETCH_ASSOC);if(!$row)throw new InvalidArgumentException('An incoming rule belongs to another PBX or is missing.');
            [$field,$expression]=self::incomingCondition($r,$policy['trunks'][$r['trunk_id']]);$doc=new DOMDocument();
            if(preg_match('/<!\s*(?:DOCTYPE|ENTITY)/i',$row['dialplan_xml'])||!$doc->loadXML($row['dialplan_xml'],LIBXML_NONET))throw new InvalidArgumentException('An incoming rule XML is invalid.');
            $nodes=[];foreach($doc->getElementsByTagName('condition') as $node)if(in_array($node->getAttribute('field'),['destination_number','${sip_to_user}','${sip_req_user}'],true))$nodes[]=$node;
            if(count($nodes)!==1)throw new InvalidArgumentException('An incoming rule has ambiguous number conditions.');$changed=$nodes[0]->getAttribute('field')!==$field||$nodes[0]->getAttribute('expression')!==$expression;
            [$bindingField,$bindingExpression]=self::incomingGatewayCondition($policy['trunks'][$r['trunk_id']]);$bindings=[];foreach($doc->getElementsByTagName('condition') as $node)if($node->getAttribute('field')===$bindingField)$bindings[]=$node;if(count($bindings)>1)throw new InvalidArgumentException('An incoming provider binding is ambiguous.');
            $first=null;foreach($doc->documentElement->childNodes as $child)if($child instanceof DOMElement){$first=$child;break;}
            $bindingChanged=!$bindings||$bindings[0]->getAttribute('expression')!==$bindingExpression||$bindings[0]!==$first;
            if(!$bindings){$binding=$doc->createElement('condition');$binding->setAttribute('field',$bindingField);$binding->setAttribute('expression',$bindingExpression);$doc->documentElement->insertBefore($binding,$doc->documentElement->firstChild);}elseif($bindingChanged){$bindings[0]->setAttribute('expression',$bindingExpression);$doc->documentElement->insertBefore($bindings[0],$doc->documentElement->firstChild);}
            if($bindingChanged)$bindingDiffs++;
            $order=self::incomingOrder($r,$index);$orderChanged=(int)$row['dialplan_order']!==$order;
            if($changed||$orderChanged||$bindingChanged){$nodes[0]->setAttribute('field',$field);$nodes[0]->setAttribute('expression',$expression);$dialplanUpdates[]=['id'=>$r['dialplan_uuid'],'xml'=>$doc->saveXML($doc->documentElement),'order'=>$order,'destination'=>$r['rule_id']];if($changed||$bindingChanged)$incomingDiffs++;if($orderChanged)$orderDiffs++;}
            $details=$this->query("select dialplan_detail_uuid,dialplan_detail_type,dialplan_detail_data from v_dialplan_details where domain_uuid=:d and dialplan_uuid=:id and dialplan_detail_tag='condition' and dialplan_detail_type in ('destination_number','\${sip_to_user}','\${sip_req_user}') for update",['d'=>$domain,'id'=>$r['dialplan_uuid']])->fetchAll(PDO::FETCH_ASSOC);
            if(count($details)>1)throw new InvalidArgumentException('An incoming rule has ambiguous stored conditions.');
            foreach($details as $detail)if($detail['dialplan_detail_type']!==$field||$detail['dialplan_detail_data']!==$expression)$detailUpdates[]=['id'=>$detail['dialplan_detail_uuid'],'field'=>$field,'expression'=>$expression];
            $bindings=$this->query("select dialplan_detail_uuid,dialplan_detail_data from v_dialplan_details where domain_uuid=:d and dialplan_uuid=:id and dialplan_detail_tag='condition' and dialplan_detail_type='\${sip_gateway}' for update",['d'=>$domain,'id'=>$r['dialplan_uuid']])->fetchAll(PDO::FETCH_ASSOC);if(count($bindings)>1)throw new InvalidArgumentException('An incoming stored provider binding is ambiguous.');
            if(!$bindings)$detailInserts[]=['dialplan'=>$r['dialplan_uuid'],'field'=>$bindingField,'expression'=>$bindingExpression];elseif($bindings[0]['dialplan_detail_data']!==$bindingExpression)$detailUpdates[]=['id'=>$bindings[0]['dialplan_detail_uuid'],'field'=>$bindingField,'expression'=>$bindingExpression];
        }
        if(array_sum($expected)!==0)throw new InvalidArgumentException('A source incoming rule is missing.');
        $result=['dry_run'=>$dryRun,'trunks'=>count($plan['trunks']),'gateways_changed'=>count($gatewayUpdates),'gateway_field_changes'=>$gatewayDiffs,'policy_field_changes'=>$policyDiffs,'incoming_rules'=>count($policy['inbound_rules']),'incoming_xml_changed'=>$incomingDiffs,'incoming_order_changed'=>$orderDiffs,'incoming_bindings_changed'=>$bindingDiffs,'incoming_details_changed'=>count($detailUpdates),'incoming_details_inserted'=>count($detailInserts)];
        if(!$dryRun){foreach($gatewayUpdates as $update){$set=[];foreach(array_keys($update['fields']) as $field)$set[]=$field.'=:'.$field;$this->query('update v_gateways set '.implode(',',$set).' where domain_uuid=:d and gateway_uuid=:id',$update['fields']+['d'=>$domain,'id'=>$update['id']]);}
            foreach($dialplanUpdates as $update){$this->query('update v_dialplans set dialplan_xml=:xml,dialplan_order=:o where domain_uuid=:d and dialplan_uuid=:id',['xml'=>$update['xml'],'o'=>$update['order'],'d'=>$domain,'id'=>$update['id']]);$this->query('update v_destinations set destination_order=:o where domain_uuid=:d and destination_uuid=:id',['o'=>$update['order'],'d'=>$domain,'id'=>$update['destination']]);}
            foreach($detailUpdates as $update)$this->query('update v_dialplan_details set dialplan_detail_type=:field,dialplan_detail_data=:expression where domain_uuid=:d and dialplan_detail_uuid=:id',['field'=>$update['field'],'expression'=>$update['expression'],'d'=>$domain,'id'=>$update['id']]);
            foreach($detailInserts as $update)$this->insert('v_dialplan_details',['dialplan_detail_uuid'=>uuid(),'domain_uuid'=>$domain,'dialplan_uuid'=>$update['dialplan'],'dialplan_detail_tag'=>'condition','dialplan_detail_type'=>$update['field'],'dialplan_detail_data'=>$update['expression'],'dialplan_detail_order'=>0,'dialplan_detail_group'=>0,'dialplan_detail_enabled'=>true]);
            if($policyDiffs)$this->query('update v_pbx_restore set config=:c where domain_uuid=:d',['c'=>json_encode($policy,JSON_THROW_ON_ERROR),'d'=>$domain]);
        }
        return $result;
    }
    public static function validate(array $plan): void {
        $v=$plan['v20']??null;
        if(!is_array($v)||($plan['source_version']??'')!=='20.0.9.995')throw new InvalidArgumentException('This backup update has not been checked.');
        $known=[];
        foreach($plan['users'] as $u)$known[$u['number']]='Extension';
        foreach(['queues'=>'Queue','ring_groups'=>'RingGroup','receptionists'=>'IVR','scripts'=>'RoutePoint','specials'=>'Special'] as $key=>$kind){
            if(count($v[$key]??[])>500)throw new InvalidArgumentException('The backup has too many call handling entries.');
            foreach($v[$key] as $r){if(isset($known[$r['number']]))throw new InvalidArgumentException('Two call handling entries use the same extension.');$known[$r['number']]=$kind;}
        }
        $check=function(array $d)use($known){
            if(!in_array($d['type']??'', ['None','EndCall','External','Boomerang','Extension','VoiceMail','RingGroup','Queue','IVR','RoutePoint','Fax'],true))throw new InvalidArgumentException('A call destination needs a restore update.');
            if(in_array($d['type'],['None','EndCall'],true))return;
            if($d['type']==='External'){if(!preg_match('/^\+?[0-9*#]{1,32}$/D',$d['external']??''))throw new InvalidArgumentException('A forwarding number is missing.');return;}
            if(($d['number']??'')!==''&&!isset($known[$d['number']]))throw new InvalidArgumentException('A call destination is missing from the backup.');
        };
        foreach(['queues','ring_groups'] as $key)foreach($v[$key] as $r){foreach($r['members'] as $m)if(($known[$m['number']]??'')!=='Extension')throw new InvalidArgumentException('A call group contains a missing user.');$check($r['destination']);if(!in_array($r['strategy'],['PollingStrategyRingAll','RingAll','RingStrategyRingAll'],true))throw new InvalidArgumentException('This ringing order needs a restore update.');}
        foreach($v['receptionists'] as $r){$check($r['timeout_destination']);foreach($r['options'] as $o)$check($o['destination']);}
        foreach($v['users'] as $u){if(!isset($u['profiles'][$u['profile']]))throw new InvalidArgumentException('A user status is missing.');foreach($u['profiles'] as $p){foreach($p['available'] as $a){$check($a['all']);$check($a['internal']);}foreach($p['away'] as $a){$check($a['all']);$check($a['outside']);}}}
        $providers=[];foreach($plan['trunks'] as $t)$providers[$t['name']]=$t['source_id'];
        if(count($v['trunks']??[])!==count($plan['trunks']))throw new InvalidArgumentException('The source provider inventory is inconsistent.');
        foreach($plan['trunks'] as $t){if(!isset($v['trunks'][$t['source_id']]))throw new InvalidArgumentException('A provider has no native settings.');self::gatewaySettings(array_merge($v['trunks'][$t['source_id']],$t));}
        foreach($v['inbound_rules'] as $r){if(!isset($v['trunks'][$r['trunk_id']]))throw new InvalidArgumentException('An incoming rule has no trunk.');foreach(['office','outside','holiday'] as $k)$check($r[$k]);self::incomingCondition($r,$v['trunks'][$r['trunk_id']]);}
        foreach($v['outbound_rules'] as $r){foreach(explode(',',$r['prefix']) as $prefix)if(!preg_match('/^\+?[0-9]{0,20}$/D',trim($prefix)))throw new InvalidArgumentException('An outbound prefix is invalid.');if(!preg_match('/^[0-9,\- ]{0,120}$/D',$r['lengths']))throw new InvalidArgumentException('An outbound length is invalid.');foreach($r['routes'] as $route){if(!isset($providers[$route['provider']]))throw new InvalidArgumentException('An outbound rule has no trunk.');if(!preg_match('/^\+?[0-9]{0,20}$/D',$route['prepend']))throw new InvalidArgumentException('An outbound prefix is invalid.');}}
        foreach($v['scripts'] as $s)foreach($s['pin_map'] as $target)if(!preg_match('/^[0-9]{2,10}$/D',(string)$target))throw new InvalidArgumentException('A call menu destination is invalid.');
    }
    private function dialplan(string $number,string $mode,string $key,int $order=80,string $context='',bool $enabled=true,string $app='',?array $condition=null,?array $binding=null): string {
        $id=uuid();$d=new DOMDocument('1.0','UTF-8');$x=$d->appendChild($d->createElement('extension'));$x->setAttribute('name','OpenWeb '.$mode.' '.$number);$x->setAttribute('uuid',$id);$x->setAttribute('continue','false');
        $condition??=['destination_number',$number===''?'^.+$':'^'.preg_quote($number,'~').'$'];
        if($binding){$c=$x->appendChild($d->createElement('condition'));$c->setAttribute('field',$binding[0]);$c->setAttribute('expression',$binding[1]);}
        $c=$x->appendChild($d->createElement('condition'));$c->setAttribute('field',$condition[0]);$c->setAttribute('expression',$condition[1]);
        $actions=[['set','domain_uuid='.$this->domain],['set','domain_name='.$this->realm],['lua','app.lua pbx_setup '.$mode.' '.$key]];
        foreach($actions as [$a,$v]){$n=$c->appendChild($d->createElement('action'));$n->setAttribute('application',$a);$n->setAttribute('data',$v);}
        $this->insert('v_dialplans',['dialplan_uuid'=>$id,'domain_uuid'=>$this->domain,'app_uuid'=>$app?:null,'dialplan_name'=>'OpenWeb '.$mode.' '.$number,'dialplan_number'=>$number,'dialplan_context'=>$context?:$this->realm,'dialplan_order'=>$order,'dialplan_continue'=>false,'dialplan_enabled'=>$enabled,'dialplan_xml'=>$d->saveXML($x),'dialplan_description'=>'Restored 3CX call handling. Edit in Admin.']);
        $rows=$binding?[['condition',$binding[0],$binding[1]]]:[];$rows[]=['condition',$condition[0],$condition[1]];foreach($actions as [$a,$v])$rows[]=['action',$a,$v];
        foreach($rows as $i=>[$tag,$type,$data])$this->insert('v_dialplan_details',['dialplan_detail_uuid'=>uuid(),'domain_uuid'=>$this->domain,'dialplan_uuid'=>$id,'dialplan_detail_tag'=>$tag,'dialplan_detail_type'=>$type,'dialplan_detail_data'=>$data,'dialplan_detail_order'=>10+$i*10,'dialplan_detail_group'=>0,'dialplan_detail_enabled'=>true]);
        return $id;
    }
    /** All changes share the setup transaction. Extraction rolls back if any stage fails. */
    public function apply(string $domain,string $realm,array $plan,?string $archive=null): array {
        self::validate($plan);if(!$this->db->inTransaction())throw new LogicException('A restore requires a transaction.');
        if(!is_uuid($domain)||!preg_match('/^[a-z0-9.-]+$/D',$realm))throw new InvalidArgumentException('Invalid PBX.');
        $this->domain=$domain;$this->realm=$realm;$this->policy=$plan['v20'];$this->policy['realm']=$realm;
        if($archive)$this->extract($archive);
        foreach($plan['users'] as $u){$p=&$this->policy['users'][$u['number']];$native=$this->query('select extension_uuid from v_extensions where domain_uuid=:d and extension=:e',['d'=>$domain,'e'=>$u['auth_id']])->fetchColumn();
            $p['auth_id']=$u['auth_id'];$p['extension_uuid']=$native;$p['name']=$u['name'];$p['email']=$u['email'];$p['enabled']=$u['enabled'];
            $this->query('update v_extensions set call_timeout=:timeout,outbound_caller_id_number=:cid,description=:name,max_registrations=5 where extension_uuid=:id and domain_uuid=:d',['timeout'=>$p['profiles'][$p['profile']]['timeout'],'cid'=>$p['outbound_caller_id'],'name'=>$u['name'],'id'=>$native,'d'=>$domain]);
            $this->query('update v_voicemails set voicemail_enabled=:on,voicemail_tutorial=false,voicemail_mail_to=:email,voicemail_file=:file,voicemail_local_after_email=:keep where domain_uuid=:d and voicemail_id=:n',['on'=>$p['voicemail_enabled'],'email'=>$p['voicemail_email']==='None'?'':$u['email'],'file'=>in_array($p['voicemail_email'],['Attachment','AttachmentAndDelete'],true)?'attach':'link','keep'=>$p['voicemail_email']!=='AttachmentAndDelete','d'=>$domain,'n'=>$u['number']]);
            // Do not send imported mail or reuse the old hosted email relay.
            $p['voicemail_uuid']=$this->query('select voicemail_uuid from v_voicemails where domain_uuid=:d and voicemail_id=:n',['d'=>$domain,'n'=>$u['number']])->fetchColumn();
            $p['dialplan_uuid']=$this->dialplan($u['number'],'user',$u['number'],80);
            unset($p);
        }
        $providers=[];foreach($plan['trunks'] as $t){$id=$this->query('select gateway_uuid from v_gateways where domain_uuid=:d and gateway=:n',['d'=>$domain,'n'=>$t['name']])->fetchColumn();$p=&$this->policy['trunks'][$t['source_id']];$p['gateway_uuid']=$id;$p['name']=$t['name'];$p['host']=$t['host'];$p['port']=$t['port'];$p['transport']=$t['transport'];$p['register']=$t['register'];$p['enabled']=false;$p['allowed_ips']=[];$providers[$t['name']]=$t['source_id'];
            $native=self::gatewaySettings(array_merge($p,$t));$set=[];foreach(array_keys($native) as $field)$set[]=$field.'=:'.$field;
            $this->query('update v_gateways set '.implode(',',$set).',enabled=false where domain_uuid=:d and gateway_uuid=:id',$native+['d'=>$domain,'id'=>$id]);
            foreach(['auth_mode','auth_username','realm','from_user','from_domain','register_proxy','outbound_proxy','caller_id_in_from','extension_in_contact','sip_cid_type'] as $field)$p[$field]=$field==='auth_mode'?($p[$field]??($native['username']!==''||$native['password']!==''?'credentials':'ip')):$native[$field];$p['contact_user']=$native['extension'];$p['extension_in_contact']=$native['extension_in_contact']==='true';unset($p);}
        foreach($this->policy['outbound_rules'] as $i=>&$r){$r['rule_id']=uuid();foreach($r['routes'] as &$route){$route['trunk_id']=$providers[$route['provider']];unset($route['provider']);}unset($route);}$this->dialplan('','outbound','all',900);unset($r);
        foreach($this->policy['ring_groups'] as &$r){$r['uuid']=uuid();$r['dialplan_uuid']=$this->dialplan($r['number'],'group',$r['number'],80,'',true,'1d61fb65-1eec-bc73-a6ee-a6203b4fe6f2');$this->insert('v_ring_groups',['ring_group_uuid'=>$r['uuid'],'domain_uuid'=>$domain,'dialplan_uuid'=>$r['dialplan_uuid'],'ring_group_name'=>$r['name'],'ring_group_extension'=>$r['number'],'ring_group_strategy'=>'simultaneous','ring_group_call_timeout'=>$r['timeout'],'ring_group_context'=>$realm,'ring_group_enabled'=>true,'ring_group_timeout_app'=>'lua','ring_group_timeout_data'=>'app.lua pbx_setup group_timeout '.$r['number'],'ring_group_description'=>'Restored from 3CX']);foreach($r['members'] as $m)$this->insert('v_ring_group_destinations',['ring_group_destination_uuid'=>uuid(),'domain_uuid'=>$domain,'ring_group_uuid'=>$r['uuid'],'destination_number'=>$m['number'],'destination_timeout'=>$r['timeout'],'destination_enabled'=>true]);}unset($r);
        $agents=[];foreach($this->policy['queues'] as &$r){$r['uuid']=uuid();$r['dialplan_uuid']=$this->dialplan($r['number'],'queue',$r['number'],80,'',true,'e95a2bd9-07fb-409b-84aa-1cbd0ea9a3cf');$r['intro']=$this->prompt($r['intro']);$r['moh']=$this->prompt($r['moh']);
            $this->insert('v_call_center_queues',['call_center_queue_uuid'=>$r['uuid'],'domain_uuid'=>$domain,'dialplan_uuid'=>$r['dialplan_uuid'],'queue_name'=>$r['name'],'queue_extension'=>$r['number'],'queue_strategy'=>'ring-all','queue_moh_sound'=>$r['moh']?:'local_stream://default','queue_greeting'=>$r['intro'],'queue_max_wait_time'=>in_array($r['callback_mode']??'disabled',['offer','automatic'],true)?min($r['timeout'],$r['callback_after']):$r['timeout'],'queue_max_wait_time_with_no_agent'=>in_array($r['callback_mode']??'disabled',['offer','automatic'],true)?min($r['timeout'],$r['callback_after']):$r['timeout'],'queue_time_base_score'=>'system','queue_tier_rules_apply'=>false,'queue_tier_rule_no_agent_no_wait'=>false,'queue_discard_abandoned_after'=>60,'queue_abandoned_resume_allowed'=>false,'queue_announce_position'=>$r['announce_position'],'queue_announce_frequency'=>$r['announce_interval'],'queue_context'=>$realm,'queue_timeout_action'=>'lua:app.lua pbx_setup queue_timeout '.$r['number'],'queue_description'=>'Restored from 3CX']);
            foreach($r['members'] as $i=>&$m){$aKey=$r['number'].'-'.$m['number'];if(!isset($agents[$aKey])){$a=uuid();$agents[$aKey]=$a;$u=$this->policy['users'][$m['number']];$contact='[leg_timeout='.$r['ring_timeout'].',domain_uuid='.$domain.',domain_name='.$realm.']user/'.$u['auth_id'].'@'.$realm;$this->insert('v_call_center_agents',['call_center_agent_uuid'=>$a,'domain_uuid'=>$domain,'agent_name'=>$u['name'].' '.$r['number'],'agent_type'=>'callback','agent_id'=>$m['number'],'agent_contact'=>$contact,'agent_status'=>$m['status']==='LoggedIn'&&$u['queue_status']==='LoggedIn'?'Available':'Logged Out','agent_max_no_answer'=>0,'agent_call_timeout'=>$r['ring_timeout'],'agent_wrap_up_time'=>$r['wrap_up'],'agent_reject_delay_time'=>2,'agent_busy_delay_time'=>2,'agent_no_answer_delay_time'=>2]);}$m['agent_uuid']=$agents[$aKey];$this->insert('v_call_center_tiers',['call_center_tier_uuid'=>uuid(),'domain_uuid'=>$domain,'call_center_queue_uuid'=>$r['uuid'],'call_center_agent_uuid'=>$m['agent_uuid'],'queue_name'=>$r['number'].'@'.$realm,'agent_name'=>$m['agent_uuid'],'tier_level'=>1,'tier_position'=>$i+1]);}unset($m);
        }unset($r);
        foreach($this->policy['receptionists'] as &$r){$r['uuid']=uuid();$r['dialplan_uuid']=$this->dialplan($r['number'],'ivr',$r['number']);$r['prompt']=$this->prompt($r['prompt']);$this->insert('v_ivr_menus',['ivr_menu_uuid'=>$r['uuid'],'domain_uuid'=>$domain,'dialplan_uuid'=>$r['dialplan_uuid'],'ivr_menu_name'=>$r['name'],'ivr_menu_extension'=>$r['number'],'ivr_menu_greet_long'=>$r['prompt'],'ivr_menu_greet_short'=>$r['prompt'],'ivr_menu_timeout'=>$r['timeout']*1000,'ivr_menu_inter_digit_timeout'=>2000,'ivr_menu_max_failures'=>3,'ivr_menu_max_timeouts'=>1,'ivr_menu_digit_len'=>1,'ivr_menu_context'=>$realm,'ivr_menu_enabled'=>true,'ivr_menu_description'=>'Restored from 3CX']);foreach($r['options'] as $i=>$o)$this->insert('v_ivr_menu_options',['ivr_menu_option_uuid'=>uuid(),'domain_uuid'=>$domain,'ivr_menu_uuid'=>$r['uuid'],'ivr_menu_option_digits'=>$o['digit'],'ivr_menu_option_action'=>'menu-exec-app','ivr_menu_option_param'=>'lua app.lua pbx_setup ivr_key '.$r['number'].':'.$o['digit'],'ivr_menu_option_order'=>$i+1,'ivr_menu_option_enabled'=>true]);}unset($r);
        foreach($this->policy['scripts'] as &$r){$r['dialplan_uuid']=$this->dialplan($r['number'],'script',$r['number']);}unset($r);
        foreach($this->policy['inbound_rules'] as $i=>&$r){$r['rule_id']=uuid();$r['enabled']=false;$trunk=$this->policy['trunks'][$r['trunk_id']];$r['dialplan_uuid']=$this->dialplan($r['condition']==='BasedOnDID'?$r['number']:$trunk['main_number'],'incoming',$r['rule_id'],self::incomingOrder($r,$i),'ingress@'.$realm,false,'c03b422e-13a8-bd1b-e42b-b6b9b4d27ce4',self::incomingCondition($r,$trunk),self::incomingGatewayCondition($trunk));$this->insert('v_destinations',['destination_uuid'=>$r['rule_id'],'domain_uuid'=>$domain,'dialplan_uuid'=>$r['dialplan_uuid'],'destination_type'=>'inbound','destination_number'=>$r['number']?:$trunk['main_number'],'destination_context'=>'ingress@'.$realm,'destination_app'=>'lua','destination_data'=>'app.lua pbx_setup incoming '.$r['rule_id'],'destination_enabled'=>false,'destination_type_voice'=>1,'destination_description'=>$r['name'],'destination_order'=>self::incomingOrder($r,$i)]);}unset($r);
        foreach($this->policy['phones'] as &$r){$r['uuid']=uuid();$u=$this->policy['users'][$r['number']];$vendor=str_contains($r['template'],'fanvil')?'fanvil':'generic';$this->insert('v_devices',['device_uuid'=>$r['uuid'],'domain_uuid'=>$domain,'device_address'=>$r['mac'],'device_label'=>$u['name'],'device_vendor'=>$vendor,'device_template'=>$vendor==='fanvil'?'fanvil/x4':'generic','device_enabled'=>true,'device_description'=>'Restored phone. Set the new server address.']);$password=$this->query('select password from v_extensions where domain_uuid=:d and extension_uuid=:id',['d'=>$domain,'id'=>$u['extension_uuid']])->fetchColumn();$this->insert('v_device_lines',['device_line_uuid'=>uuid(),'domain_uuid'=>$domain,'device_uuid'=>$r['uuid'],'line_number'=>1,'server_address'=>pbx_paths::host(),'server_address_primary'=>pbx_paths::host(),'outbound_proxy_primary'=>pbx_paths::host(),'label'=>$u['number'],'display_name'=>$u['name'],'user_id'=>$u['auth_id'],'auth_id'=>$u['auth_id'],'password'=>$password,'sip_port'=>'5060','sip_transport'=>'udp','register_expires'=>180,'enabled'=>true]);
            $this->phoneKeys($r);unset($r['settings']);}unset($r);
        foreach($this->policy['contacts'] as $r){$id=uuid();$this->insert('v_contacts',['contact_uuid'=>$id,'domain_uuid'=>$domain,'contact_type'=>'person','contact_name_given'=>$r['first_name'],'contact_name_family'=>$r['last_name'],'contact_organization'=>$r['company'],'contact_note'=>'Imported address book for '.$r['owner']]);if($r['phone']!=='')$this->insert('v_contact_phones',['contact_phone_uuid'=>uuid(),'domain_uuid'=>$domain,'contact_uuid'=>$id,'phone_number'=>$r['phone'],'phone_type_voice'=>1,'phone_primary'=>true]);}
        foreach($this->policy['specials'] as $r){if($r['kind']==='SpecialMenu')$this->dialplan($r['number'],'voicemail_login',$r['number']);elseif($r['kind']==='ParkExtension'&&str_starts_with($r['number'],'SP'))$this->dialplan($r['number'],'park',$r['number']);}
        $greetings=$this->importGreetings($domain,$realm,$this->policy['users']);
        $history=0;$vm=0;if($archive){$zip=new ZipArchive();if($zip->open($archive,ZipArchive::RDONLY)!==true)throw new RuntimeException('The backup is unavailable.');try{$history=$this->history($zip);$vm=$this->voicemail($zip);$this->recordings($zip);}finally{$zip->close();}}
        $notes=$plan['unsupported'];
        if($this->missingPrompts)$notes[]=['category'=>'Audio files','count'=>count($this->missingPrompts),'reason'=>'These call prompts are named in the settings but are missing from the original backup. Upload replacements in Call Handling.'];
        if($greetings['selection_required'])$notes[]=['category'=>'Voicemail greetings','count'=>$greetings['selection_required'],'reason'=>'Greeting files are restored. The backup does not identify the active greeting; choose it under Users → Voicemail.'];
        $report=threecx_v20::counts($plan)+['recordings'=>count(array_filter($this->media,fn($m)=>$m['category']==='recordings')),'voicemail_files'=>count(array_filter($this->media,fn($m)=>$m['category']==='voicemails')),'voicemail_messages'=>$vm,'voicemail_greetings'=>$greetings['files'],'prompts'=>count(array_filter($this->media,fn($m)=>$m['category']==='prompts')),'call_history'=>$history,'contacts'=>count($this->policy['contacts']),'notes'=>$notes];
        $this->insert('v_pbx_restore',['domain_uuid'=>$domain,'source_version'=>$plan['source_version'],'config'=>json_encode($this->policy,JSON_THROW_ON_ERROR),'report'=>json_encode($report,JSON_THROW_ON_ERROR)]);
        return $report;
    }
    /** Also supports an idempotent upgrade of an already restored, privately stored PBX. */
    public function importGreetings(string $domain,string $realm,array &$users): array {
        if(!$this->db->inTransaction()||!is_uuid($domain)||!preg_match('/^[a-z0-9.-]+$/D',$realm))throw new LogicException('Greeting restore requires a PBX transaction.');
        $files=0;$owners=[];
        $rows=$this->query("select media_uuid,owner_number,file_path,title from v_pbx_media where domain_uuid=:d and category='prompts' and source_path like 'vmailprompts/%' order by source_path",['d'=>$domain])->fetchAll(PDO::FETCH_ASSOC);
        foreach($rows as $m){$number=$m['owner_number'];if(!isset($users[$number]))continue;
            $source='Imported audio '.$m['media_uuid'];$id=$this->query('select greeting_id from v_voicemail_greetings where domain_uuid=:d and voicemail_id=:n and greeting_description=:f',['d'=>$domain,'n'=>$number,'f'=>$source])->fetchColumn();
            if($id===false){$id=max(100,(int)$this->query('select coalesce(max(greeting_id),0)+1 from v_voicemail_greetings where domain_uuid=:d and voicemail_id=:n',['d'=>$domain,'n'=>$number])->fetchColumn());
                $dir=pbx_paths::voicemail().'/default/'.$realm.'/'.$number;if(!is_dir($dir)&&!mkdir($dir,0700,true))throw new RuntimeException('Voicemail storage is unavailable.');$path=$dir.'/greeting_'.$id.'.wav';
                if(file_exists($path)||!copy($m['file_path'],$path))throw new RuntimeException('A voicemail greeting could not be restored.');chmod($path,0600);$this->mediaFiles[]=$path;
                $this->insert('v_voicemail_greetings',['voicemail_greeting_uuid'=>uuid(),'domain_uuid'=>$domain,'voicemail_id'=>$number,'greeting_id'=>$id,'greeting_filename'=>'greeting_'.$id.'.wav','greeting_description'=>$source,'greeting_name'=>$m['title']]);
            }
            if(!isset($owners[$number])){$users[$number]['greetings']=[];$owners[$number]=true;}
            $users[$number]['greetings'][]=['id'=>(string)$id,'title'=>$m['title'],'media_uuid'=>$m['media_uuid']];$files++;
        }
        $choices=0;foreach(array_keys($owners) as $number){$id=$this->query('select greeting_id from v_voicemails where domain_uuid=:d and voicemail_id=:n',['d'=>$domain,'n'=>$number])->fetchColumn();$users[$number]['greeting_id']=$id===null||$id===false?'':(string)$id;if($users[$number]['greeting_id']==='')$choices++;}
        return ['files'=>$files,'selection_required'=>$choices];
    }
    private function extract(string $archive): void {
        // Recheck the entire archive before writing. Never extractAll or trust filenames.
        threecx_backup::analyze($archive);$root=pbx_paths::media().'/'.$this->domain;
        if(file_exists($root))throw new RuntimeException('This PBX already has restored files.');
        if(!is_dir(pbx_paths::media())&&!mkdir(pbx_paths::media(),0700,true))throw new RuntimeException('Backup storage is unavailable.');
        if(!mkdir($root,0700))throw new RuntimeException('Backup storage is unavailable.');$this->mediaFiles[]=$root;
        $zip=new ZipArchive();$zip->open($archive,ZipArchive::RDONLY);$total=0;
        try{for($i=0;$i<$zip->numFiles;$i++){$s=$zip->statIndex($i);$name=$s['name'];if(!preg_match('#^(recordings|voicemails|httpprompts|vmailprompts)/.+\.wav$#iD',$name,$m))continue;
            if($s['size']>268435456)throw new InvalidArgumentException('A recording is too large.');$id=uuid();$target=$root.'/'.$id.'.wav';$in=$zip->getStreamIndex($i);$out=fopen($target,'xb');if(!$in||!$out)throw new RuntimeException('A recording could not be restored.');$written=0;$header='';
            try{while(!feof($in)){$buf=fread($in,1048576);if($buf===false)throw new RuntimeException('A recording could not be read.');if($written===0)$header=substr($buf,0,12);$written+=strlen($buf);$total+=strlen($buf);if($written>$s['size']||$total>threecx_backup::MAX_ARCHIVE_BYTES)throw new InvalidArgumentException('The recordings exceed the backup limit.');if(fwrite($out,$buf)!==strlen($buf))throw new RuntimeException('Backup storage is full.');}}finally{fclose($in);fclose($out);}
            if($written!==$s['size']||substr($header,0,4)!=='RIFF'||substr($header,8,4)!=='WAVE')throw new InvalidArgumentException('The backup contains an invalid WAV recording.');chmod($target,0600);
            $category=in_array($m[1],['httpprompts','vmailprompts'],true)?'prompts':$m[1];$owner=explode('/',$name)[1]??'';$row=['media_uuid'=>$id,'domain_uuid'=>$this->domain,'category'=>$category,'source_path'=>$name,'file_path'=>$target,'title'=>basename($name),'owner_number'=>isset($this->policy['users'][$owner])?$owner:null];$this->insert('v_pbx_media',$row);$this->media[$name]=$row;
            if($category==='prompts')$this->insert('v_recordings',['recording_uuid'=>uuid(),'domain_uuid'=>$this->domain,'recording_filename'=>$target,'recording_name'=>basename($name),'recording_description'=>'Restored 3CX prompt']);
        }}finally{$zip->close();}
    }
    private function prompt(string $source): string {
        if($source==='')return '';$source=str_replace('\\','/',$source);$base=basename($source);$matches=[];
        foreach($this->media as $name=>$m)if($m['category']==='prompts'&&strcasecmp(basename($name),$base)===0)$matches[$m['file_path']]=true;
        if(isset($this->media[$source]))return $this->media[$source]['file_path'];
        if(count($matches)===1)return array_key_first($matches);
        // Some backups include identical global prompts under two user directories.
        if(count($matches)>1){$paths=array_keys($matches);$hash=hash_file('sha256',$paths[0]);if(count(array_filter($paths,fn($p)=>hash_file('sha256',$p)!==$hash))===0)return $paths[0];}
        if($matches)throw new InvalidArgumentException('A call prompt has conflicting copies.');
        $this->missingPrompts[$base]=true;return '';
    }
    private function phoneKeys(array $phone): void {
        if($phone['settings']==='')return;if(preg_match('/<!\s*(?:DOCTYPE|ENTITY)/i',$phone['settings']))throw new InvalidArgumentException('A phone configuration is invalid.');$d=new DOMDocument();if(!$d->loadXML($phone['settings'],LIBXML_NONET|LIBXML_NOBLANKS))throw new InvalidArgumentException('A phone configuration is invalid.');$xp=new DOMXPath($d);$i=0;
        foreach($xp->query('//BLFS/*') as $blf){$value=$blf->getAttribute('value')?:$blf->getAttribute('extension');if($value===''||!preg_match('/^[0-9*#SP]{1,15}$/D',$value))continue;$this->insert('v_device_keys',['device_key_uuid'=>uuid(),'domain_uuid'=>$this->domain,'device_uuid'=>$phone['uuid'],'device_key_id'=>++$i,'device_key_category'=>'line','device_key_vendor'=>str_contains($phone['template'],'fanvil')?'fanvil':'generic','device_key_type'=>'blf','device_key_value'=>$value,'device_key_extension'=>$phone['number'],'device_key_line'=>'1']);}
    }
    private function csv(ZipArchive $z,string $name): Generator {
        $i=$z->locateName($name);if($i===false)return;$s=$z->getStreamIndex($i);if(!$s)throw new RuntimeException('Call history is unreadable.');$bytes=0;$rows=0;
        try{$header=fgetcsv($s,1048576,',','"','');if(!$header)return;$header[0]=ltrim($header[0],"\xef\xbb\xbf");while(($row=fgetcsv($s,1048576,',','"',''))!==false){$bytes+=array_sum(array_map('strlen',$row));if(++$rows>200000||$bytes>268435456)throw new InvalidArgumentException('Call history exceeds the restore limit.');if(count($row)!==count($header))throw new InvalidArgumentException('Call history contains a damaged row.');yield array_combine($header,$row);}}finally{fclose($s);}
    }
    private function date(string $value): ?string {
        if($value===''||$value==='0')return null;if(preg_match('/^\d{14}\.\d+$/D',$value)){$d=DateTimeImmutable::createFromFormat('YmdHis',substr($value,0,14),new DateTimeZone('UTC'));return $d?$d->format('c'):null;}
        try{return (new DateTimeImmutable($value,new DateTimeZone('UTC')))->format('c');}catch(Throwable){return null;}
    }
    private function history(ZipArchive $z): int {
        $sql='insert into v_pbx_call_history(history_uuid,domain_uuid,owner_number,party_number,party_name,call_type,start_time,answer_time,end_time,end_status,source_id) values(:id,:d,:owner,:party,:name,:type,:start,:answer,:end,:status,:source)';$s=$this->db->prepare($sql);$count=0;
        foreach($this->csv($z,'DbTables/myphone_callhistory_v14.csv') as $r){$s->execute(['id'=>uuid(),'d'=>$this->domain,'owner'=>$r['dnowner'],'party'=>$r['party_dn']?:$r['party_callerid'],'name'=>$r['party_name'],'type'=>$r['calltype'],'start'=>$this->date($r['start_time']),'answer'=>$this->date($r['established_time']),'end'=>$this->date($r['end_time']),'status'=>$r['end_status'],'source'=>$r['idmpch14']]);$count++;}return $count;
    }
    private function voicemail(ZipArchive $z): int {
        $map=[];$raw=$z->getFromName('OtherSettings/MappingTable.xml');if($raw!==false){if(strlen($raw)>1048576||preg_match('/<!\s*(?:DOCTYPE|ENTITY)/i',$raw))throw new InvalidArgumentException('The voicemail index is invalid.');$d=new DOMDocument();$d->loadXML($raw,LIBXML_NONET);foreach($d->getElementsByTagName('DN') as $n)$map[$n->getAttribute('ID')]=$n->getAttribute('No');}
        $count=0;$restored=[];foreach($this->csv($z,'DbTables/s_voicemail.csv') as $r){$number=$map[$r['callee']]??$r['callee'];$u=$this->policy['users'][$number]??null;$source='voicemails/'.$number.'/'.basename(str_replace('\\','/',$r['wav_file'])).(str_ends_with(strtolower($r['wav_file']),'.wav')?'':'.wav');$media=$this->media[$source]??null;
            if(!$media){foreach($this->media as $m)if($m['category']==='voicemails'&&basename($m['source_path'])===basename($r['wav_file']).(str_ends_with(strtolower($r['wav_file']),'.wav')?'':'.wav')){$media=$m;break;}}
            if(!$u||!$media||in_array(strtolower($r['removed']),['true','t','1'],true))continue;
            $id=uuid();$epoch=strtotime($this->date($r['created_time'])??'now');$heard=in_array(strtolower($r['heard']),['true','t','1'],true);$this->insert('v_voicemail_messages',['voicemail_message_uuid'=>$id,'domain_uuid'=>$this->domain,'voicemail_uuid'=>$u['voicemail_uuid'],'created_epoch'=>$epoch,'read_epoch'=>$heard?strtotime($this->date($r['heard_time'])??'now'):null,'caller_id_name'=>$r['caller_name'],'caller_id_number'=>$r['caller'],'message_length'=>(int)$r['duration'],'message_status'=>$heard?'saved':'new','message_transcription'=>$r['transcription']]);
            $dir=pbx_paths::voicemail().'/default/'.$this->realm.'/'.$number;if(!is_dir($dir)&&!mkdir($dir,0700,true))throw new RuntimeException('Voicemail storage is unavailable.');$path=$dir.'/msg_'.$id.'.wav';if(!copy($media['file_path'],$path))throw new RuntimeException('A voicemail could not be restored.');chmod($path,0600);$this->mediaFiles[]=$path;
            $this->query('update v_pbx_media set owner_number=:n,created_at=:date,duration=:duration where media_uuid=:id',['n'=>$number,'date'=>$this->date($r['created_time']),'duration'=>(int)$r['duration'],'id'=>$media['media_uuid']]);$restored[$media['media_uuid']]=true;$count++;}
        // The supplied backup has audio that is absent from its stale voicemail index.
        // Recover those messages from their owning folder and original timestamp.
        foreach($this->media as $m){if($m['category']!=='voicemails'||isset($restored[$m['media_uuid']])||!$m['owner_number'])continue;$number=$m['owner_number'];$u=$this->policy['users'][$number];$name=basename($m['source_path']);$date=null;$caller='';if(preg_match('/^vmail_(.*?)_[0-9]+_([0-9]{14})\.wav$/iD',$name,$parts)){$date=$this->date($parts[2].'.00');$caller=$parts[1];}
            $id=uuid();$length=$this->wavDuration($m['file_path']);$this->insert('v_voicemail_messages',['voicemail_message_uuid'=>$id,'domain_uuid'=>$this->domain,'voicemail_uuid'=>$u['voicemail_uuid'],'created_epoch'=>strtotime($date??'now'),'caller_id_number'=>$caller,'caller_id_name'=>'','message_length'=>$length,'message_status'=>'new']);$dir=pbx_paths::voicemail().'/default/'.$this->realm.'/'.$number;if(!is_dir($dir))mkdir($dir,0700,true);$path=$dir.'/msg_'.$id.'.wav';if(!copy($m['file_path'],$path))throw new RuntimeException('A voicemail could not be restored.');chmod($path,0600);$this->mediaFiles[]=$path;$this->query('update v_pbx_media set created_at=:date,duration=:duration where media_uuid=:id',['date'=>$date,'duration'=>$length,'id'=>$m['media_uuid']]);$count++;
        }
        return $count;
    }
    private function wavDuration(string $path): int {
        $f=fopen($path,'rb');fseek($f,12);$rate=0;$data=0;
        try{for($i=0;$i<30&&!feof($f);$i++){$h=fread($f,8);if(strlen($h)!==8)break;$size=unpack('V',substr($h,4))[1];if(substr($h,0,4)==='fmt '){$v=fread($f,min($size,32));if(strlen($v)>=12)$rate=unpack('V',substr($v,8,4))[1];if($size>strlen($v))fseek($f,$size-strlen($v),SEEK_CUR);}elseif(substr($h,0,4)==='data'){$data=$size;break;}else fseek($f,$size+($size%2),SEEK_CUR);}}finally{fclose($f);}return $rate?max(1,(int)round($data/$rate)):1;
    }
    private function recordings(ZipArchive $z): void {
        foreach($this->csv($z,'DbTables/recordings.csv') as $r){$url=urldecode(str_replace('\\','/',$r['recording_url']));foreach($this->media as $m)if($m['category']==='recordings'&&str_ends_with($m['source_path'],$url)){$start=$this->date($r['start_time']);$end=$this->date($r['end_time']);$this->query('update v_pbx_media set created_at=:date,duration=:duration where media_uuid=:id',['date'=>$start,'duration'=>$start&&$end?max(0,strtotime($end)-strtotime($start)):null,'id'=>$m['media_uuid']]);break;}}
    }
    public function rollbackFiles(): void {
        foreach(array_reverse($this->mediaFiles) as $path){if(is_file($path))unlink($path);elseif(is_dir($path)){foreach(glob($path.'/*.wav')?:[] as $f)unlink($f);rmdir($path);}}$this->mediaFiles=[];
    }
}
