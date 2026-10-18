<?php
/** Add the common open video codec without changing the established audio preference order. */
final class pbx_video {
    public static function configure(PDO $db): int {
        if(PHP_SAPI!=='cli')throw new RuntimeException('Local installation required.');
        $s=$db->query("select s.sip_profile_setting_uuid,s.sip_profile_setting_value from v_sip_profile_settings s join v_sip_profiles p using(sip_profile_uuid) where p.sip_profile_name in ('internal','internal-ipv6') and p.sip_profile_enabled=true and s.sip_profile_setting_enabled=true and s.sip_profile_setting_name in ('inbound-codec-prefs','outbound-codec-prefs')");$n=0;
        foreach($s->fetchAll(PDO::FETCH_ASSOC)as$row){$value=$row['sip_profile_setting_value'];if(!is_string($value)||trim($value)==='')continue;if(preg_match('/(?:^|,)\s*VP8\s*(?:,|$)/i',$value))continue;$q=$db->prepare('update v_sip_profile_settings set sip_profile_setting_value=? where sip_profile_setting_uuid=? and sip_profile_setting_value=?');$q->execute([rtrim($value,',').',VP8',$row['sip_profile_setting_uuid'],$value]);$n+=$q->rowCount();}return $n;
    }
    public static function ready(): bool {
        try{$text=(string)event_socket::api('sofia status profile internal');return preg_match('/^CODECS IN[^\r\n]*\bVP8\b/m',$text)&&preg_match('/^CODECS OUT[^\r\n]*\bVP8\b/m',$text)&&str_contains((string)event_socket::api('show codecs'),'VP8 Video');}catch(Throwable){return false;}
    }
}
