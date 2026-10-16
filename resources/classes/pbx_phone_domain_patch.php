<?php
/** Change only selected SIP hostname fields in a complete, unmasked phone export. */
class pbx_phone_domain_patch {
    public static function patch(string $bytes,string $model,int $line,string $old,string $new,array $identity): array {
        if(strlen($bytes)>2097152||str_contains($bytes,"\0")||preg_match('/<!DOCTYPE|<!ENTITY/i',$bytes))throw new InvalidArgumentException('Use a plain phone configuration export up to 2 MB, without external entities.');
        $old=pbx_sip_domain::validate($old);$new=pbx_sip_domain::validate($new);
        if($old===''||$new===''||$old===$new)throw new InvalidArgumentException('Enter different old and new phone domains.');
        if(!isset($identity['auth_id'],$identity['password'],$identity['number'])||!is_string($identity['password'])||$identity['password']==='')throw new InvalidArgumentException('Original phone credentials are unavailable.');
        return match($model){'yealink_w60b'=>self::yealink($bytes,$line,$old,$new,$identity),'fanvil_v62w'=>self::fanvil($bytes,$line,$old,$new,$identity),default=>throw new InvalidArgumentException('Choose Yealink W60B or Fanvil V62W.')};
    }
    private static function user(string $value,array $identity,string $old): bool {
        $parts=explode('@',$value,2);return in_array($parts[0],array_unique([$identity['number'],$identity['sip_user']??$identity['number'],$identity['auth_id']]),true)&&(count($parts)===1||strtolower($parts[1])===$old);
    }
    private static function host(string $value,string $old,string $new): string {
        // Keep an explicit port, transport parameters and whitespace exactly.
        if(preg_match('/^(\s*)((?:sips?:)?(?:\/\/)?)'.preg_quote($old,'/').'((?::[0-9]{1,5})?(?:;transport=(?:udp|tcp|tls))?)(\s*)$/iD',$value,$m))return $m[1].$m[2].$new.$m[3].$m[4];
        return $value;
    }
    private static function yealink(string $bytes,int $line,string $old,string $new,array $id): array {
        if($line<1||$line>8)throw new InvalidArgumentException('Choose the existing W60B account, from 1 to 8.');
        $pattern='/^(\h*account\.'.(string)$line.'\.([a-z0-9_.]+)\h*=\h*)([^\r\n]*)(\r?)$/m';$values=[];
        preg_replace_callback($pattern,static function($m)use(&$values){if(isset($values[$m[2]]))throw new InvalidArgumentException('This phone export repeats a selected account setting.');$values[$m[2]]=trim($m[3]);return $m[0];},$bytes);
        if(!isset($values['user_name'],$values['auth_name'],$values['password'])||!self::user($values['user_name'],$id,$old)||!hash_equals($id['auth_id'],$values['auth_name'])||!hash_equals($id['password'],$values['password']))throw new InvalidArgumentException('The selected account does not match the restored user and unmasked SIP password. Keep the original account and change its domain manually, or upload its complete unmasked export.');
        $fields=[];$patched=preg_replace_callback($pattern,static function($m)use($old,$new,&$fields){$v=$m[3];if(preg_match('/^(?:sip_server\.[12]\.address|outbound_proxy\.[12]\.address|outbound_host|sip_server\.domain|sip_server\.[12]\.domain)$/D',$m[2]))$v=self::host($v,$old,$new);
            elseif($m[2]==='user_name'&&str_ends_with(strtolower(trim($v)),'@'.$old))$v=preg_replace('/@'.preg_quote($old,'/').'(?=\h*$)/i','@'.$new,$v);
            if($v!==$m[3])$fields[]='account.'.$m[2];return $m[1].$v.$m[4];},$bytes);
        if(!$fields||!in_array('account.sip_server.1.address',$fields,true))throw new InvalidArgumentException('The selected primary SIP server does not match the old phone domain.');
        return ['bytes'=>$patched,'changed_fields'=>$fields,'format'=>'cfg','sip_port'=>$values['sip_server.1.port']??$values['sip_server_port']??null,'transport'=>['0'=>'udp','1'=>'tcp','2'=>'tls'][$values['transport']??'']??null,'credentials_unchanged'=>true,'other_accounts_unchanged'=>true];
    }
    private static function fanvil(string $bytes,int $line,string $old,string $new,array $id): array {
        if($line<1||$line>6)throw new InvalidArgumentException('Choose the existing Fanvil SIP line, from 1 to 6.');
        $previous=libxml_use_internal_errors(true);$doc=new DOMDocument;try{if(!$doc->loadXML($bytes,LIBXML_NONET)||$doc->doctype||$doc->documentElement?->tagName!=='sysConf')throw new InvalidArgumentException('Use the complete plain Fanvil sysConf XML export. Encrypted or other formats need a manual domain change.');$xp=new DOMXPath($doc);$nodes=$xp->query('/sysConf/sip/line[@index="'.$line.'"]');if($nodes->length!==1)throw new InvalidArgumentException('The selected Fanvil line is missing or repeated.');$node=$nodes->item(0);$values=[];foreach($node->childNodes as$child)if($child instanceof DOMElement){if(isset($values[$child->tagName]))throw new InvalidArgumentException('This export repeats a selected SIP line setting.');$values[$child->tagName]=$child->textContent;}
            if(!isset($values['PhoneNumber'],$values['RegisterUser'],$values['RegisterPswd'])||!self::user($values['PhoneNumber'],$id,$old)||!hash_equals($id['auth_id'],$values['RegisterUser'])||!hash_equals($id['password'],$values['RegisterPswd']))throw new InvalidArgumentException('The selected SIP line does not match the restored user and unmasked password.');
            foreach(['ProxyUser'=>$id['auth_id'],'ProxyPswd'=>$id['password']]as$f=>$expected)if(($values[$f]??'')!==''&&!hash_equals($expected,$values[$f]))throw new InvalidArgumentException('The proxy account differs from the restored account; review it manually.');
        }finally{libxml_clear_errors();libxml_use_internal_errors($previous);}
        $fields=[];$matches=0;$pattern='/<line\b[^>]*\bindex\h*=\h*([\'"])'.(string)$line.'\1[^>]*>.*?<\/line\h*>/s';
        $patched=preg_replace_callback('/<sip\b[^>]*>.*?<\/sip\h*>/s',static function($sip)use($pattern,$old,$new,&$fields,&$matches){return preg_replace_callback($pattern,static function($block)use($old,$new,&$fields,&$matches){$matches++;
            return preg_replace_callback('/(<(RegisterAddr|BackupAddr|ProxyAddr|BakProxyAddr|LocalDomain|PhoneNumber)>)([^<]*)(<\/\2>)/s',static function($m)use($old,$new,&$fields){$v=$m[3];if($m[2]==='PhoneNumber'){if(str_ends_with(strtolower($v),'@'.$old))$v=substr($v,0,-strlen($old)).$new;}else $v=self::host($v,$old,$new);if($v!==$m[3])$fields[]=$m[2];return $m[1].$v.$m[4];},$block[0]);},$sip[0]);},$bytes);
        if($matches!==1||!in_array('RegisterAddr',$fields,true))throw new InvalidArgumentException('The selected primary SIP server does not match the old phone domain.');
        return ['bytes'=>$patched,'changed_fields'=>$fields,'format'=>'xml','sip_port'=>$values['RegisterPort']??null,'transport'=>['0'=>'udp','1'=>'tcp','3'=>'tls'][$values['Transport']??'']??null,'credentials_unchanged'=>true,'other_accounts_unchanged'=>true];
    }
}
