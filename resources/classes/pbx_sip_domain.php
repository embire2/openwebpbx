<?php
/** A tenant's SIP address is an exact realm, never a cross-tenant fallback. */
final class pbx_sip_domain {
    public static function assigned(string $serviceSlug,string $tenantSlug,string $host,string $suffix=''): string {
        $suffix=self::validate($suffix);
        if($suffix==='')return self::validate($serviceSlug.'.'.$tenantSlug.'.'.$host);
        $label=$serviceSlug.'-'.$tenantSlug;
        if(strlen($label)>63)$label=substr($label,0,50).'-'.substr(hash('sha256',$label),0,12);
        return self::validate($label.'.'.$suffix);
    }
    public static function certificateCovers(string $domain,array $names): bool {
        foreach($names as $name){
            $name=strtolower(trim($name));if($domain===$name)return true;
            if(str_starts_with($name,'*.')){$suffix=substr($name,1);if(str_ends_with($domain,$suffix)&&!str_contains(substr($domain,0,-strlen($suffix)),'.')&&strlen($domain)>strlen($suffix))return true;}
        }
        return false;
    }
    public static function validate(mixed $value): string {
        if(!is_string($value))throw new InvalidArgumentException('Enter the new phone domain.');
        $value=strtolower(rtrim(trim($value),'.'));
        if($value==='')return '';
        if(strlen($value)>253||filter_var($value,FILTER_VALIDATE_IP)||!preg_match('/^(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z](?:[a-z0-9-]{0,61}[a-z0-9])?$/D',$value))throw new InvalidArgumentException('Enter a domain such as phones.yourcompany.com, without https, a port or a path.');
        return $value;
    }
}
