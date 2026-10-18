<?php
if(PHP_SAPI!=='cli')exit;
require dirname(__DIR__).'/resources/require.php';
$db=$database->db;$db->setAttribute(PDO::ATTR_ERRMODE,PDO::ERRMODE_EXCEPTION);$schema='meet_install_check_'.bin2hex(random_bytes(6));$n=0;
$check=static function($v,$why)use(&$n){if(!$v)throw new RuntimeException($why);$n++;};
try{
 $db->exec('create schema '.$schema.';set search_path to '.$schema.',public');
 $tables=['v_domains','v_users','v_sip_profiles','v_sip_profile_settings','v_conference_profiles','v_conference_profile_params','v_dialplans','v_dialplan_details','v_menus','v_menu_items','v_menu_languages','v_groups','v_menu_item_groups'];
 foreach($tables as$t)$db->exec('create table '.$t.' (like public.'.$t.' including all)');
 $menuId=uuid();$otherItem=uuid();$meetMenu='c6b624b2-a54f-4828-a706-13ddf6b6f891';
 $db->prepare("insert into v_menus(menu_uuid,menu_name,menu_language)values(?,'default','de-de')")->execute([$menuId]);
 $db->prepare("insert into v_menu_items(menu_item_uuid,menu_uuid,menu_item_title,menu_item_link)values(?,?,'Existing','/existing')")->execute([$otherItem,$menuId]);
 foreach(['fr-fr','en-us']as$language)$db->prepare("insert into v_menu_languages(menu_language_uuid,menu_uuid,menu_item_uuid,menu_language,menu_item_title)values(?,?,?,?,?)")->execute([uuid(),$menuId,$otherItem,$language,'Existing '.$language]);
 foreach(['superadmin','tenant_admin','openweb_staff','user']as$group)$db->prepare('insert into v_groups(group_uuid,group_name)values(?,?)')->execute([uuid(),$group]);
 $profile=uuid();$db->prepare("insert into v_sip_profiles(sip_profile_uuid,sip_profile_name,sip_profile_enabled) values(?,'internal',true)")->execute([$profile]);
 foreach(['inbound-codec-prefs'=>'G722,PCMU,PCMA','outbound-codec-prefs'=>'$${global_codec_prefs}']as$name=>$value)$db->prepare('insert into v_sip_profile_settings(sip_profile_setting_uuid,sip_profile_uuid,sip_profile_setting_name,sip_profile_setting_value,sip_profile_setting_enabled) values(?,?,?,?,true)')->execute([uuid(),$profile,$name,$value]);
 pbx_meet_install::apply($db);
 $check($db->query("select count(*) from v_sip_profiles where sip_profile_name='openweb-meet'")->fetchColumn()==1,'Private meeting profile installed');
 $prefs=$db->query("select sip_profile_setting_value from v_sip_profile_settings where sip_profile_uuid='$profile' order by sip_profile_setting_name")->fetchAll(PDO::FETCH_COLUMN);
 $check($prefs===['G722,PCMU,PCMA,VP8','$${global_codec_prefs},VP8'],'Audio preferences preserved with VP8 appended');
 $check($db->query("select sip_profile_setting_value from v_sip_profile_settings where sip_profile_setting_name='ws-binding'")->fetchColumn()==='127.0.0.1:5079','Unencrypted WebSocket hop is loopback only');
 $check($db->query("select sip_profile_setting_value from v_sip_profile_settings where sip_profile_setting_name='auth-calls'")->fetchColumn()==='true','Browser profile requires authentication');
 $check($db->query("select profile_param_value from v_conference_profile_params where profile_param_name='video-mode'")->fetchColumn()==='mux','Shared conference video mixing selected');
 $check($db->query("select count(*) from v_dialplans where dialplan_context='openweb-meet-only' and dialplan_xml like '%^.*$%'")->fetchColumn()==1,'All browser destinations pass the room-only guard');
 $languageRows=$db->prepare('select menu_language,menu_item_title from v_menu_languages where menu_item_uuid=? order by menu_language');$languageRows->execute([$meetMenu]);
 $check($languageRows->fetchAll(PDO::FETCH_KEY_PAIR)===['de-de'=>'Meet','en-us'=>'Meet','fr-fr'=>'Meet'],'Meet covers English, configured and existing menu languages');
 // The same language and role predicates as menu::menu_array, rather than
 // merely checking that a menu item exists, caught the missing registration.
 $visible=static function($language,$group)use($db,$menuId,$meetMenu){$q=$db->prepare('select i.menu_item_uuid,l.menu_item_title from v_menu_items i,v_menu_languages l where i.menu_item_uuid=l.menu_item_uuid and l.menu_language=? and l.menu_uuid=? and i.menu_uuid=? and i.menu_item_parent_uuid is null and i.menu_item_uuid in(select menu_item_uuid from v_menu_item_groups where menu_uuid=? and group_name=? and menu_item_uuid is not null) and i.menu_item_uuid=? order by i.menu_item_order asc');$q->execute([$language,$menuId,$menuId,$menuId,$group,$meetMenu]);return$q->fetchAll(PDO::FETCH_ASSOC);};
 foreach(['en-us','de-de','fr-fr']as$language)foreach(['superadmin','tenant_admin','openweb_staff']as$group)$check(count($visible($language,$group))===1,'Normal menu language/group lookup includes Meet: '.$language.'/'.$group);
 $check($visible('en-us','user')===[],'Language registration grants no unapproved group');
 $check($visible('xx-unknown','superadmin')===[],'Menu lookup retains exact language selection');
 $db->prepare('update v_menu_languages set menu_item_title=? where menu_item_uuid=? and menu_language=?')->execute(['Rencontre personnalisée',$meetMenu,'fr-fr']);
 $existingLanguages=$db->query("select coalesce(json_agg(x order by row_to_json(x)::text),'[]') from v_menu_languages x")->fetchColumn();
 pbx_meet_install::apply($db);
 $check($existingLanguages===$db->query("select coalesce(json_agg(x order by row_to_json(x)::text),'[]') from v_menu_languages x")->fetchColumn(),'Repeat install preserves custom translations and all existing language row UUIDs');
 $check($visible('fr-fr','tenant_admin')[0]['menu_item_title']==='Rencontre personnalisée','Normal menu lookup returns retained custom translation');
 $before=[];foreach($tables as$t)$before[$t]=$db->query('select coalesce(json_agg(x order by row_to_json(x)::text),\'[]\') from '.$t.' x')->fetchColumn();
 pbx_meet_install::apply($db);
 foreach($tables as$t)$check($before[$t]===$db->query('select coalesce(json_agg(x order by row_to_json(x)::text),\'[]\') from '.$t.' x')->fetchColumn(),'Repeated installation preserved '.$t);
 $apps=['global'=>'0f56aaac-01ba-46e6-944d-58eaa8712170','openweb-meet-only'=>'78c3e839-69bb-4e44-8932-edc4fbc92bf7'];
 $domain=uuid();$secondDomain=uuid();foreach([$domain,$secondDomain]as$d)$db->prepare("insert into v_domains(domain_uuid,domain_name,domain_enabled) values(?,?,true)")->execute([$d,$d.'.invalid']);
 $domains=[['domain_uuid'=>$domain,'domain_name'=>$domain.'.invalid'],['domain_uuid'=>$secondDomain,'domain_name'=>$secondDomain.'.invalid']];
 foreach($apps as$context=>$app){$q=$db->prepare('select dialplan_uuid,app_uuid,domain_uuid from v_dialplans where dialplan_context=?');$q->execute([$context]);$r=$q->fetch(PDO::FETCH_ASSOC);$check($r['dialplan_uuid']===$app&&$r['app_uuid']===$app&&$r['domain_uuid']===null,'Fresh routes share XML application identity');}
 $import=static function()use($db,$domains,$apps){$db->beginTransaction();try{(new dialplan)->import($domains,array_values($apps));$db->commit();}catch(Throwable$e){if($db->inTransaction())$db->rollBack();throw$e;}};
 $snapshot=static function()use($db,$tables){$out=[];foreach($tables as$t)$out[$t]=$db->query("select coalesce(json_agg(x order by row_to_json(x)::text),'[]')from ".$t.' x')->fetchColumn();return$out;};
 $before=$snapshot();$import();$check($before===$snapshot(),'Actual filtered defaults import does not duplicate installed identities across two domains');
 // A previously hosted installation has fixed UUIDs but no app_uuid marker.
 $db->exec('update v_dialplans set app_uuid=null');$fixed=$db->query('select dialplan_uuid from v_dialplans order by dialplan_uuid')->fetchAll(PDO::FETCH_COLUMN);pbx_meet_install::apply($db);
 $check($fixed===$db->query('select dialplan_uuid from v_dialplans order by dialplan_uuid')->fetchAll(PDO::FETCH_COLUMN),'Legacy hosted route UUIDs preserved');
 $check((int)$db->query('select count(*)from v_dialplans where app_uuid=dialplan_uuid')->fetchColumn()===2,'Legacy hosted routes gain application markers');
 // Conversely, defaults can run first and assign their own random row UUIDs.
 $db->exec('delete from v_dialplan_details;delete from v_dialplans');$import();$imported=$db->query('select app_uuid,dialplan_uuid from v_dialplans order by app_uuid')->fetchAll(PDO::FETCH_KEY_PAIR);
 $check(count($imported)===2&&$imported[$apps['global']]!==$apps['global']&&$imported[$apps['openweb-meet-only']]!==$apps['openweb-meet-only'],'Actual XML importer created one global row per app across two domains');
 $details=$db->query("select coalesce(json_agg(x order by row_to_json(x)::text),'[]')from v_dialplan_details x")->fetchColumn();pbx_meet_install::apply($db);
 $check($imported===$db->query('select app_uuid,dialplan_uuid from v_dialplans order by app_uuid')->fetchAll(PDO::FETCH_KEY_PAIR),'Installer adopts imported row UUIDs without another copy');
 $check($details===$db->query("select coalesce(json_agg(x order by row_to_json(x)::text),'[]')from v_dialplan_details x")->fetchColumn(),'Imported detail rows remain exact');
 $before=$snapshot();$import();pbx_meet_install::apply($db);$check($before===$snapshot(),'Import then installer remain exactly idempotent');
 // Contradictions refuse before schema/configuration work, retaining caller transactions.
 foreach(['context','domain','name','duplicate','fixed_app','second_conflict']as$case){
  $db->beginTransaction();$first=$imported[$apps['global']];$last=$imported[$apps['openweb-meet-only']];
  if($case==='context')$db->prepare('update v_dialplans set dialplan_context=? where dialplan_uuid=?')->execute(['other-context',$first]);
  elseif($case==='domain')$db->prepare('update v_dialplans set domain_uuid=? where dialplan_uuid=?')->execute([$domain,$first]);
  elseif($case==='name')$db->prepare('update v_dialplans set dialplan_name=? where dialplan_uuid=?')->execute(['Customer route',$first]);
  elseif($case==='duplicate')$db->prepare("insert into v_dialplans(dialplan_uuid,app_uuid,dialplan_context,dialplan_name) values(?,?,'global','OpenWeb meeting')")->execute([uuid(),$apps['global']]);
  elseif($case==='fixed_app'){$db->prepare('delete from v_dialplan_details where dialplan_uuid=?')->execute([$first]);$db->prepare('delete from v_dialplans where dialplan_uuid=?')->execute([$first]);$db->prepare("insert into v_dialplans(dialplan_uuid,app_uuid,dialplan_context,dialplan_name) values(?,?,'global','OpenWeb meeting')")->execute([$apps['global'],uuid()]);}
  else{$db->prepare('delete from v_dialplan_details where dialplan_uuid=?')->execute([$first]);$db->prepare('update v_dialplans set app_uuid=null,dialplan_uuid=? where dialplan_uuid=?')->execute([$apps['global'],$first]);$db->prepare('update v_dialplans set dialplan_context=? where dialplan_uuid=?')->execute(['other-context',$last]);}
  $expected=$snapshot();$refused=false;try{pbx_meet_install::apply($db);}catch(RuntimeException){$refused=true;}
  $check($refused,'Contradictory route refused: '.$case);$check($db->inTransaction(),'Refusal preserves caller transaction: '.$case);$check($expected===$snapshot(),'Refusal changes no fixture configuration: '.$case);$db->rollBack();
 }
 // A separate-server restore changes only the three owned address/path values.
 $meet='cfb1c835-c30c-409b-bff7-a893a7e84df1';$custom=uuid();
 $db->prepare("insert into v_sip_profiles(sip_profile_uuid,sip_profile_name,sip_profile_enabled)values(?,'custom-provider',true)")->execute([$custom]);
 $db->prepare("insert into v_sip_profile_settings(sip_profile_setting_uuid,sip_profile_uuid,sip_profile_setting_name,sip_profile_setting_value,sip_profile_setting_enabled)values(?,?,'rtp-ip','192.0.2.9',true)")->execute([uuid(),$custom]);
 $settings=static function()use($db){return$db->query('select *from v_sip_profile_settings order by sip_profile_setting_uuid')->fetchAll(PDO::FETCH_ASSOC);};
 $before=$settings();$count=pbx_meet_install::rebind($db,'198.51.100.42','/srv/target-config');
 $check($count===3,'Cross-IP restore rebinds both owned RTP addresses and owned TLS path');
 $expected=['rtp-ip'=>'198.51.100.42','ext-rtp-ip'=>'198.51.100.42','tls-cert-dir'=>'/srv/target-config/tls/openweb-meet'];
 foreach($before as&$r)if($r['sip_profile_uuid']===$meet&&isset($expected[$r['sip_profile_setting_name']]))$r['sip_profile_setting_value']=$expected[$r['sip_profile_setting_name']];unset($r);
 $check($before===$settings(),'Rebind preserves every other setting field, UUID, profile and customer value');
 $check(pbx_meet_install::rebind($db,'198.51.100.42','/srv/target-config')===0,'Repeated rebind is exactly idempotent');
 foreach(['bad ip','host..invalid','bad/host',"host\n.invalid"]as$address){$before=$snapshot();$refused=false;try{pbx_meet_install::rebind($db,$address,'/srv/target-config');}catch(RuntimeException){$refused=true;}$check($refused&&$before===$snapshot(),'Invalid media address refuses without mutations');}
 foreach(['duplicate','missing','disabled','profile_name','duplicate_profile','conference_name']as$case){
  $db->beginTransaction();
  if($case==='duplicate')$db->prepare("insert into v_sip_profile_settings(sip_profile_setting_uuid,sip_profile_uuid,sip_profile_setting_name,sip_profile_setting_value,sip_profile_setting_enabled)values(?,?,'tls-cert-dir','/duplicate',true)")->execute([uuid(),$meet]);
  elseif($case==='missing')$db->prepare("delete from v_sip_profile_settings where sip_profile_uuid=? and sip_profile_setting_name='tls-cert-dir'")->execute([$meet]);
  elseif($case==='disabled')$db->prepare("update v_sip_profile_settings set sip_profile_setting_enabled=false where sip_profile_uuid=? and sip_profile_setting_name='tls-cert-dir'")->execute([$meet]);
  elseif($case==='profile_name')$db->prepare("update v_sip_profiles set sip_profile_name='customer-profile'where sip_profile_uuid=?")->execute([$meet]);
  elseif($case==='duplicate_profile')$db->prepare("insert into v_sip_profiles(sip_profile_uuid,sip_profile_name,sip_profile_enabled)values(?,'openweb-meet',true)")->execute([uuid()]);
  else$db->exec("update v_conference_profiles set profile_name='customer-conference'where conference_profile_uuid='b26410e0-b732-4c72-b9cf-cc045c395a57'");
  $before=$snapshot();$refused=false;try{pbx_meet_install::rebind($db,'203.0.113.55','/different');}catch(RuntimeException){$refused=true;}
  $check($refused&&$db->inTransaction(),'Contradictory rebind refuses, retains caller transaction: '.$case);
  $check($before===$snapshot(),'Failed rebind leaves no partial settings writes: '.$case);
  if(in_array($case,['profile_name','duplicate_profile','conference_name'],true)){$refused=false;try{pbx_meet_install::apply($db);}catch(RuntimeException){$refused=true;}$check($refused&&$before===$snapshot(),'Installer refuses conflicting private-profile identity before writes: '.$case);}
  $db->rollBack();
 }
 // Empty preferences inherit native defaults; disabled/custom profiles remain exact.
 foreach([null,'',' PCMU, VP8 ,PCMA','PCMU,PCMA,']as$value)$db->prepare("insert into v_sip_profile_settings(sip_profile_setting_uuid,sip_profile_uuid,sip_profile_setting_name,sip_profile_setting_value,sip_profile_setting_enabled)values(?,?,'inbound-codec-prefs',?,true)")->execute([uuid(),$profile,$value]);
 $db->prepare("insert into v_sip_profile_settings(sip_profile_setting_uuid,sip_profile_uuid,sip_profile_setting_name,sip_profile_setting_value,sip_profile_setting_enabled)values(?,?,'outbound-codec-prefs','PCMU',true)")->execute([uuid(),$custom]);
 $check(pbx_video::configure($db)===1,'VP8 appended once only to enabled explicit internal preferences');
 $check(pbx_video::configure($db)===0,'Whitespace/case capability detection avoids duplicate VP8 and preserves inherited defaults');
 $q=$db->prepare("select sip_profile_setting_value from v_sip_profile_settings where sip_profile_uuid=? and sip_profile_setting_name='outbound-codec-prefs'");$q->execute([$custom]);$check($q->fetchColumn()==='PCMU','Custom provider codec preferences are preserved');
 echo 'PASS '.$n." actual PostgreSQL install/import/identity/idempotence controls\n";
}finally{if($db->inTransaction())$db->rollBack();$db->exec('set search_path to public;drop schema if exists '.$schema.' cascade');}
