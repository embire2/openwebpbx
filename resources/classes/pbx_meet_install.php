<?php
/** Local installation only. Adds a separate loopback WebSocket phone profile. */
final class pbx_meet_install {
    public static function apply(PDO $db): void {
        if(PHP_SAPI!=='cli')throw new RuntimeException('Local installation required.');
        // Refuse contradictory identities before touching configuration.
        self::dialplans($db,false);
        $db->exec(file_get_contents(dirname(__DIR__,2).'/app/pbx_meet/resources/install.sql'));
        pbx_video::configure($db);
        $q=static function($sql,$args=[])use($db){$s=$db->prepare($sql);$s->execute($args);return $s;};
        $id='cfb1c835-c30c-409b-bff7-a893a7e84df1';
        $q("insert into v_sip_profiles(sip_profile_uuid,sip_profile_name,sip_profile_enabled,sip_profile_description) values(?,'openweb-meet',true,'Private browser meeting transport') on conflict(sip_profile_uuid) do nothing",[$id]);
        $settings=['sip-ip'=>'127.0.0.1','sip-port'=>'5078','ws-binding'=>'127.0.0.1:5079','wss-binding'=>'127.0.0.1:7444','tls-cert-dir'=>rtrim((string)config::load()->get('switch.conf.dir'),'/\\').'/tls/openweb-meet','rtp-ip'=>pbx_paths::address(),'ext-rtp-ip'=>pbx_paths::address(),
            'context'=>'openweb-meet-only','dialplan'=>'XML','auth-calls'=>'true','auth-all-packets'=>'false','challenge-realm'=>'auto_from',
            'inbound-codec-prefs'=>'PCMU,PCMA,VP8','outbound-codec-prefs'=>'PCMU,PCMA,VP8','inbound-codec-negotiation'=>'generous',
            'disable-transcoding'=>'false','manage-presence'=>'false','rtp-timeout-sec'=>'60','rtp-hold-timeout-sec'=>'300',
            'dtmf-type'=>'rfc2833','inbound-reg-force-matching-username'=>'true','accept-blind-reg'=>'false','accept-blind-auth'=>'false'];
        foreach($settings as $name=>$value){if(!$q('select 1 from v_sip_profile_settings where sip_profile_uuid=? and sip_profile_setting_name=?',[$id,$name])->fetchColumn())$q('insert into v_sip_profile_settings(sip_profile_setting_uuid,sip_profile_uuid,sip_profile_setting_name,sip_profile_setting_value,sip_profile_setting_enabled) values(?,?,?,?,true)',[uuid(),$id,$name,$value]);}
        $profile='b26410e0-b732-4c72-b9cf-cc045c395a57';
        $q("insert into v_conference_profiles(conference_profile_uuid,profile_name,profile_enabled,profile_description) values(?,'openweb-meet',true,'OpenWeb audio and camera meetings') on conflict(conference_profile_uuid) do nothing",[$profile]);
        $params=['rate'=>'8000','interval'=>'20','energy-level'=>'100','comfort-noise'=>'false','caller-controls'=>'none','moderator-controls'=>'none',
            'max-members'=>'25','video-mode'=>'mux','video-layout-name'=>'group:grid','video-canvas-size'=>'640x360','video-fps'=>'15','video-codec-bandwidth'=>'512kb',
            'enter-sound'=>'tone_stream://%(100,0,700)','exit-sound'=>'tone_stream://%(100,0,500)','alone-sound'=>'silence_stream://1000','moh-sound'=>'silence_stream://1000'];
        foreach($params as$name=>$value)if(!$q('select 1 from v_conference_profile_params where conference_profile_uuid=? and profile_param_name=?',[$profile,$name])->fetchColumn())$q('insert into v_conference_profile_params(conference_profile_param_uuid,conference_profile_uuid,profile_param_name,profile_param_value,profile_param_enabled) values(?,?,?,?,true)',[uuid(),$profile,$name,$value]);
        self::dialplans($db,true);
        $menu='c6b624b2-a54f-4828-a706-13ddf6b6f891';$menuId=$q('select menu_uuid from v_menus order by menu_name limit 1')->fetchColumn();
        if($menuId){$q("insert into v_menu_items(menu_item_uuid,menu_uuid,menu_item_title,menu_item_link,menu_item_category,menu_item_order,menu_item_icon) values(?,?,'Meet','/app/pbx_meet/','internal',15,'fa-solid fa-video') on conflict(menu_item_uuid) do nothing",[$menu,$menuId]);
            foreach($q("select group_uuid,group_name from v_groups where group_name in ('superadmin','tenant_admin','openweb_staff')")->fetchAll(PDO::FETCH_ASSOC)as$g)if(!$q('select 1 from v_menu_item_groups where menu_item_uuid=? and group_uuid=?',[$menu,$g['group_uuid']])->fetchColumn())$q('insert into v_menu_item_groups(menu_item_group_uuid,menu_uuid,menu_item_uuid,group_uuid,group_name) values(?,?,?,?,?)',[uuid(),$menuId,$menu,$g['group_uuid'],$g['group_name']]);
            // menu_array requires a matching language row, even for English.
            // Keep existing translations exact and cover installed languages
            // without changing another menu item or its visibility grants.
            $languages=$q("select distinct menu_language from v_menu_languages where menu_language is not null and menu_language<>'' union select menu_language from v_menus where menu_uuid=? and menu_language is not null and menu_language<>'' union select 'en-us'",[$menuId])->fetchAll(PDO::FETCH_COLUMN);
            foreach($languages as$language)if(!$q('select 1 from v_menu_languages where menu_uuid=? and menu_item_uuid=? and menu_language=?',[$menuId,$menu,$language])->fetchColumn())$q('insert into v_menu_languages(menu_language_uuid,menu_uuid,menu_item_uuid,menu_language,menu_item_title) values(?,?,?,?,?)',[uuid(),$menuId,$menu,$language,'Meet']);
        }
        // Existing PBXs must see the additive meeting route without waiting for cache expiry.
        $cache=new cache;foreach($q('select domain_name from v_domains')->fetchAll(PDO::FETCH_COLUMN)as$domain)$cache->delete('dialplan:'.$domain);
    }
    /** Share application identity with the stock XML importer; never duplicate its rows. */
    private static function dialplans(PDO $db,bool $write): void {
        $own=$write&&!$db->inTransaction();if($own)$db->beginTransaction();
        try{
            // Stock imports do not take our advisory locks. Serialize this short
            // configuration transaction with their INSERT/UPDATE operations too.
            if($write)$db->exec('lock table v_dialplans in share row exclusive mode');
            $plans=[];
            foreach(['global'=>'0f56aaac-01ba-46e6-944d-58eaa8712170','openweb-meet-only'=>'78c3e839-69bb-4e44-8932-edc4fbc92bf7']as$context=>$app){
                $q=$db->prepare('select dialplan_uuid,app_uuid,domain_uuid,dialplan_name,dialplan_context from v_dialplans where app_uuid=? or dialplan_uuid=?');$q->execute([$app,$app]);$rows=$q->fetchAll(PDO::FETCH_ASSOC);
                if(count($rows)>1)throw new RuntimeException('Duplicate meeting route identities need administrator review.');
                $row=$rows[0]??null;$names=$context==='global'?['OpenWeb meeting']:['OpenWeb meeting','OpenWeb browser meeting'];
                if($row&&($row['domain_uuid']!==null||$row['dialplan_context']!==$context||!in_array($row['dialplan_name'],$names,true)||($row['app_uuid']!==null&&$row['app_uuid']!==''&&$row['app_uuid']!==$app)))throw new RuntimeException('The existing meeting route identity or context needs administrator review.');
                $plans[]=[$context,$app,$row];
            }
            if($write)foreach($plans as[$context,$app,$row]){
                $name=$row['dialplan_name']??($context==='global'?'OpenWeb meeting':'OpenWeb browser meeting');
                $expression=$context==='global'?'^98[0-9]{6}$':'^.*$';$continue=$context==='global'?'true':'false';
                $xml='<extension name="'.$name.'" continue="'.$continue.'"><condition field="destination_number" expression="'.$expression.'"><action application="lua" data="app/pbx_services/meeting.lua"/></condition></extension>';
                if($row){
                    $q=$db->prepare('update v_dialplans set app_uuid=?,dialplan_xml=?,dialplan_continue=?::boolean where dialplan_uuid=? and (app_uuid is distinct from ?::uuid or dialplan_xml is distinct from ? or dialplan_continue is distinct from ?::boolean)');$q->execute([$app,$xml,$continue,$row['dialplan_uuid'],$app,$xml,$continue]);
                }else{
                    $q=$db->prepare('insert into v_dialplans(dialplan_uuid,app_uuid,dialplan_name,dialplan_context,dialplan_order,dialplan_enabled,dialplan_xml,dialplan_continue) values(?,?,?,?,1,true,?,?::boolean)');$q->execute([$app,$app,$name,$context,$xml,$continue]);
                }
            }
            if($own)$db->commit();
        }catch(Throwable $e){if($own&&$db->inTransaction())$db->rollBack();throw $e;}
    }
    /** A unique private certificate pins the encrypted loopback hop behind public HTTPS. */
    public static function tls(?string $conf=null,?string $state=null): array {
        if(PHP_SAPI!=='cli')throw new RuntimeException('Local installation required.');
        $conf??=(string)config::load()->get('switch.conf.dir');$state??=PHP_OS_FAMILY==='Linux'?'/etc/openwebpbx':pbx_paths::state();
        $dir=rtrim($conf,'/\\').'/tls/openweb-meet';$pem=$dir.'/wss.pem';$ca=rtrim($state,'/\\').'/meet-ca.pem';
        foreach([$dir,dirname($dir),$pem,$ca]as$path)if(is_link($path))throw new RuntimeException('Review the meeting certificate location.');
        if(!is_dir($dir)&&!mkdir($dir,0750,true))throw new RuntimeException('Meeting certificate storage is unavailable.');
        if(!is_dir(dirname($ca))&&!mkdir(dirname($ca),0750,true))throw new RuntimeException('Meeting trust storage is unavailable.');
        if(is_file($pem)){
            $bytes=file_get_contents($pem);$cert=openssl_x509_read($bytes);$key=openssl_pkey_get_private($bytes);$info=$cert?openssl_x509_parse($cert):false;
            if(!$key||!$cert||!openssl_x509_check_private_key($cert,$key)||($info['subject']['CN']??'')!=='openweb-meet.internal'||($info['validTo_time_t']??0)<time()+86400)throw new RuntimeException('The meeting certificate needs review before replacement.');
            openssl_x509_export($cert,$certificate);
        }else{
            $key=openssl_pkey_new(['private_key_bits'=>2048,'private_key_type'=>OPENSSL_KEYTYPE_RSA]);$csr=openssl_csr_new(['commonName'=>'openweb-meet.internal'],$key,['digest_alg'=>'sha256']);$cert=openssl_csr_sign($csr,null,$key,3650,['digest_alg'=>'sha256']);
            if(!$cert||!openssl_pkey_export($key,$private)||!openssl_x509_export($cert,$certificate))throw new RuntimeException('The meeting certificate could not be created.');
            $temp=$pem.'.'.bin2hex(random_bytes(6));file_put_contents($temp,$private.$certificate,LOCK_EX);chmod($temp,0640);if(PHP_OS_FAMILY==='Linux'){chown($temp,'www-data');chgrp($temp,'www-data');chown($dir,'www-data');chgrp($dir,'www-data');}if(!rename($temp,$pem))throw new RuntimeException('The meeting certificate could not be installed.');
        }
        if(is_file($ca)&&!hash_equals(file_get_contents($ca),$certificate))throw new RuntimeException('The meeting trust certificate differs from the private endpoint.');
        if(!is_file($ca)){$temp=$ca.'.'.bin2hex(random_bytes(6));file_put_contents($temp,$certificate,LOCK_EX);chmod($temp,0644);if(!rename($temp,$ca))throw new RuntimeException('The meeting trust certificate could not be installed.');}
        return ['certificate'=>$pem,'trust'=>$ca];
    }
}
