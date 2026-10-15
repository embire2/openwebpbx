<?php
/** Installation bridge: relaxed registrar equality requires the stricter per-tenant directory guard. */
final class pbx_phone_auth {
    public const POLICY='same-tenant-auth-pair-before-cache-v1';
    public static function guarded(string $scripts): bool {
        $base=rtrim($scripts,'/\\').'/app/xml_handler/resources/scripts/directory/';
        $binding=@file_get_contents($base.'auth_binding.lua');$directory=@file_get_contents($base.'directory.lua');
        return is_string($binding)&&strlen($binding)<65536&&str_contains($binding,self::POLICY)&&is_string($directory)&&strlen($directory)<262144&&str_contains($directory,'auth_binding = binding.lookup(')&&str_contains($directory,"action ~= 'sip_auth'");
    }
    public static function configure(PDO $db,?string $scripts=null): int {
        if(PHP_SAPI!=='cli'||(PHP_OS_FAMILY==='Linux'&&(!function_exists('posix_geteuid')||posix_geteuid()!==0)))throw new RuntimeException('Phone authentication setup requires the local instance administrator.');
        if(PHP_OS_FAMILY==='Windows')self::requireWindowsNative();
        $scripts??=(string)config::load()->get('switch.scripts.dir',PHP_OS_FAMILY==='Windows'?'C:/Program Files/FreeSWITCH/scripts':'/usr/share/freeswitch/scripts');
        if(!self::guarded($scripts))throw new RuntimeException('The guarded phone directory must be installed before restoring separate phone login IDs.');
        $owned=!$db->inTransaction();if($owned)$db->beginTransaction();
        try {
            $s=$db->prepare("select sip_profile_uuid from v_sip_profiles where sip_profile_name in ('internal','internal-ipv6') and sip_profile_enabled=true and (sip_profile_hostname is null or sip_profile_hostname='' or sip_profile_hostname=:host)");$s->execute(['host'=>gethostname()]);$profiles=$s->fetchAll(PDO::FETCH_COLUMN);
            if(!$profiles)throw new RuntimeException('An enabled phone profile is required.');
            foreach($profiles as $profile){
                $s=$db->prepare("update v_sip_profile_settings set sip_profile_setting_value='false',sip_profile_setting_enabled=true where sip_profile_uuid=:profile and sip_profile_setting_name='inbound-reg-force-matching-username'");$s->execute(['profile'=>$profile]);
                if(!$s->rowCount()){$s=$db->prepare("insert into v_sip_profile_settings(sip_profile_setting_uuid,sip_profile_uuid,sip_profile_setting_name,sip_profile_setting_value,sip_profile_setting_enabled) values(:id,:profile,'inbound-reg-force-matching-username','false',true)");$s->execute(['id'=>uuid(),'profile'=>$profile]);}
            }
            if($owned)$db->commit();
        }catch(Throwable $e){if($owned&&$db->inTransaction())$db->rollBack();throw $e;}
        return count($profiles);
    }
    public static function requireWindowsNative(): void {
        $path=rtrim((string)(getenv('ProgramData')?:'C:/ProgramData'),'/\\').'/OpenWebPBX/native-engine.json';
        $bytes=@file_get_contents($path);
        if(!is_string($bytes)||strlen($bytes)>65536)throw new RuntimeException('Install the verified Windows phone-registration module first.');
        $manifest=json_decode($bytes,true,32,JSON_THROW_ON_ERROR);
        $engine=rtrim((string)config::load()->get('switch.conf.dir','C:/Program Files/FreeSWITCH/conf'),'/\\');
        $engine=dirname($engine);
        $expected=$manifest['files']['mod/mod_sofia.dll']??'';
        $coreExpected=$manifest['core_sha256']??'';
        if(($manifest['schema']??null)!==1||($manifest['upstream_commit']??'')!=='ef32e205295e29f034f1453ad245ba5efb07b94a'||
            ($manifest['source_reg_sha256']??'')!=='8cee43d5f88b7e1cd158f125b2780409b0c52c7cbac37fd3039a2a8981ddc317'||
            !is_string($expected)||!preg_match('/^[a-f0-9]{64}$/D',$expected)||
            !is_string($coreExpected)||!preg_match('/^[a-f0-9]{64}$/D',$coreExpected)||
            !hash_equals($expected,(string)@hash_file('sha256',$engine.'/mod/mod_sofia.dll'))||
            !hash_equals($coreExpected,(string)@hash_file('sha256',$engine.'/FreeSwitch.dll'))){
            throw new RuntimeException('The Windows phone-registration module does not match the installed call engine.');
        }
    }
}
