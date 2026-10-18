<?php
/** Local installation only. Adds a separate loopback WebSocket phone profile. */
final class pbx_meet_install {
    public static function apply(PDO $db): void {
        if(PHP_SAPI!=='cli')throw new RuntimeException('Local installation required.');
        // Refuse contradictory identities before touching configuration.
        self::dialplans($db,false);
        self::profiles($db);
        $db->exec(file_get_contents(dirname(__DIR__,2).'/app/pbx_meet/resources/install.sql'));
        pbx_video::configure($db);
        $q=static function($sql,$args=[])use($db){$s=$db->prepare($sql);$s->execute($args);return $s;};
        $id='cfb1c835-c30c-409b-bff7-a893a7e84df1';
        $q("insert into v_sip_profiles(sip_profile_uuid,sip_profile_name,sip_profile_enabled,sip_profile_description) values(?,'openweb-meet',true,'Private browser meeting transport') on conflict(sip_profile_uuid) do nothing",[$id]);
        $settings=['sip-ip'=>'127.0.0.1','sip-port'=>'5078','ws-binding'=>'127.0.0.1:5079','wss-binding'=>'127.0.0.1:7444','tls-cert-dir'=>rtrim((string)config::load()->get('switch.conf.dir'),'/\\').'/tls/openweb-meet','rtp-ip'=>pbx_paths::address()?:pbx_paths::host(),'ext-rtp-ip'=>pbx_paths::address()?:pbx_paths::host(),
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
    /** Only these private, fixed identities belong to the meeting installer. */
    private static function profiles(PDO $db): bool {
        $exists=false;
        foreach([
            ['v_sip_profiles','sip_profile_uuid','sip_profile_name','cfb1c835-c30c-409b-bff7-a893a7e84df1'],
            ['v_conference_profiles','conference_profile_uuid','profile_name','b26410e0-b732-4c72-b9cf-cc045c395a57']
        ] as[$table,$key,$name,$id]){
            $q=$db->prepare("select $key,$name from $table where $key=? or $name='openweb-meet'");$q->execute([$id]);$rows=$q->fetchAll(PDO::FETCH_ASSOC);
            if(count($rows)>1||$rows&&($rows[0][$key]!==$id||$rows[0][$name]!=='openweb-meet'))throw new RuntimeException('The meeting profile identity needs administrator review.');
            if($table==='v_sip_profiles')$exists=(bool)$rows;
        }
        return $exists;
    }
    /** A separate-server restore rebinds only the installer-owned media address. */
    public static function rebind(PDO $db,?string $address=null,?string $conf=null): int {
        if(PHP_SAPI!=='cli')throw new RuntimeException('Local installation required.');
        $address??=pbx_paths::address();if($address==='')$address=pbx_paths::host();
        if(!filter_var($address,FILTER_VALIDATE_IP)&&!filter_var($address,FILTER_VALIDATE_DOMAIN,FILTER_FLAG_HOSTNAME))throw new RuntimeException('The replacement server address is invalid.');
        $conf??=(string)config::load()->get('switch.conf.dir');
        if($conf===''||strpbrk($conf,"\r\n\0")!==false)throw new RuntimeException('The replacement call-engine path is invalid.');
        if(!self::profiles($db))return 0; // Legacy backups without meetings retain their own schema/configuration.
        $owned=!$db->inTransaction();if($owned)$db->beginTransaction();$changed=0;
        try{
            $id='cfb1c835-c30c-409b-bff7-a893a7e84df1';
            $db->prepare('select sip_profile_uuid from v_sip_profiles where sip_profile_uuid=? for update')->execute([$id]);
            $changes=[];
            foreach(['rtp-ip'=>$address,'ext-rtp-ip'=>$address,'tls-cert-dir'=>rtrim($conf,'/\\').'/tls/openweb-meet']as$name=>$value){
                $q=$db->prepare('select sip_profile_setting_uuid,sip_profile_setting_value,sip_profile_setting_enabled from v_sip_profile_settings where sip_profile_uuid=? and sip_profile_setting_name=? for update');$q->execute([$id,$name]);$rows=$q->fetchAll(PDO::FETCH_ASSOC);
                if(count($rows)!==1||!in_array($rows[0]['sip_profile_setting_enabled'],['true',true,'t'],true))throw new RuntimeException('The meeting media-address settings need administrator review.');
                if($rows[0]['sip_profile_setting_value']===$value)continue;
                $changes[]=[$value,$rows[0]['sip_profile_setting_uuid']];
            }
            foreach($changes as$args){$q=$db->prepare('update v_sip_profile_settings set sip_profile_setting_value=? where sip_profile_setting_uuid=?');$q->execute($args);$changed+=$q->rowCount();}
            if($owned)$db->commit();return $changed;
        }catch(Throwable $e){if($owned&&$db->inTransaction())$db->rollBack();throw $e;}
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
        foreach([$pem,$ca]as$path){
            for($p=$path;;$p=dirname($p)){if(is_link($p))throw new RuntimeException('Review the meeting certificate location.');if($p===dirname($p))break;}
            if(file_exists($path)&&!is_file($path))throw new RuntimeException('The meeting certificate location is not an ordinary file.');
            for($p=dirname($path);!is_dir($p);$p=dirname($p))if(file_exists($p)||$p===dirname($p))throw new RuntimeException('The meeting certificate parent is unavailable.');
        }
        if(!is_file($pem)&&file_exists($ca))throw new RuntimeException('The meeting trust certificate has no matching private endpoint.');
        if(is_file($pem)){
            $bytes=file_get_contents($pem);$cert=openssl_x509_read($bytes);$key=openssl_pkey_get_private($bytes);$info=$cert?openssl_x509_parse($cert):false;
            if(!$key||!$cert||!openssl_x509_check_private_key($cert,$key)||($info['subject']['CN']??'')!=='openweb-meet.internal'||($info['validTo_time_t']??0)<time()+86400)throw new RuntimeException('The meeting certificate needs review before replacement.');
            openssl_x509_export($cert,$certificate);
        }else{
            $key=openssl_pkey_new(['private_key_bits'=>2048,'private_key_type'=>OPENSSL_KEYTYPE_RSA]);$csr=openssl_csr_new(['commonName'=>'openweb-meet.internal'],$key,['digest_alg'=>'sha256']);$cert=openssl_csr_sign($csr,null,$key,3650,['digest_alg'=>'sha256']);
            if(!$cert||!openssl_pkey_export($key,$private)||!openssl_x509_export($cert,$certificate))throw new RuntimeException('The meeting certificate could not be created.');
        }
        if(is_file($ca)&&!hash_equals(file_get_contents($ca),$certificate))throw new RuntimeException('The meeting trust certificate differs from the private endpoint.');
        $created=[];$directories=[];
        try{
            foreach([dirname($pem),dirname($ca)]as$parent){$missing=[];for($p=$parent;!is_dir($p);$p=dirname($p))$missing[]=$p;foreach(array_reverse($missing)as$p){if(!mkdir($p,0750)||!chmod($p,0750))throw new RuntimeException('Meeting certificate storage is unavailable.');if(PHP_OS_FAMILY==='Linux'){chown($p,'www-data');chgrp($p,'www-data');}$directories[]=$p;}}
            foreach([$pem=>[$private??null,0640],$ca=>[$certificate,0644]]as$path=>[$bytes,$mode]){
                if(is_file($path))continue;
                if($path===$pem)$bytes.=$certificate;
                $temp=$path.'.'.bin2hex(random_bytes(6));
                try{if(file_put_contents($temp,$bytes,LOCK_EX)!==strlen($bytes)||!chmod($temp,$mode))throw new RuntimeException('The meeting certificate could not be written.');if(PHP_OS_FAMILY==='Linux'){chown($temp,$path===$pem?'www-data':'root');chgrp($temp,$path===$pem?'www-data':'root');}if(!rename($temp,$path))throw new RuntimeException('The meeting certificate could not be installed.');$created[]=$path;}finally{if(is_file($temp))unlink($temp);}
            }
        }catch(Throwable $e){foreach(array_reverse($created)as$path)unlink($path);foreach(array_reverse($directories)as$path)rmdir($path);throw $e;}
        return ['certificate'=>$pem,'trust'=>$ca];
    }
}
