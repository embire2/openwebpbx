<?php
/** Actual-source PostgreSQL/filesystem regression. Requires a separately copied disposable web tree. */
if (PHP_SAPI !== 'cli' || getenv('OPENWEB_WINDOWS_UPGRADE_TEST') !== '1') exit(2);
$configFile = $argv[1] ?? ''; $previousRoot = $argv[2] ?? '';
if (!is_file($configFile) || !is_dir($previousRoot) || !str_starts_with(basename(dirname($configFile)), 'ow-additive-pg-')) throw new RuntimeException('An explicit disposable configuration is required.');
require dirname(__DIR__).'/resources/classes/config.php'; config::load($configFile);
if (config::load()->get('database.0.host') !== '127.0.0.1' || config::load()->get('database.0.port') !== '27671' || config::load()->get('switch.event_socket.port') !== '1') throw new RuntimeException('The isolated PostgreSQL/native-off fixture is required.');
require dirname(__DIR__).'/resources/require.php';
$db = $database->db; $db->setAttribute(PDO::ATTR_ERRMODE, PDO::ERRMODE_EXCEPTION); $checks = 0;
$legacyWarnings=[];
set_error_handler(static function($severity, $message, $file, $line) use (&$legacyWarnings) {
 if (!(error_reporting() & $severity)) return false;
 if (basename($file)==='pbx_upgrade_defaults.php' || basename($file)==='pbx_windows_upgrade_defaults.php') throw new ErrorException($message, 0, $severity, $file, $line);
 $legacyWarnings[]=['source'=>basename($file),'line'=>$line,'severity'=>$severity];return true;
});
$check = static function($ok, $label) use (&$checks) { if (!$ok) throw new RuntimeException($label); $checks++; };
$q = static function($sql, $values = []) use ($db) { $s=$db->prepare($sql); foreach(array_values($values) as $i=>$v)$s->bindValue($i+1,$v,$v===null?PDO::PARAM_NULL:(is_bool($v)?PDO::PARAM_BOOL:PDO::PARAM_STR));$s->execute();return $s; };
$snapshot = static function($tables) use ($db) { $out=[];foreach($tables as $table)$out[$table]=$db->query('select row_to_json(t)::text from '.$table.' t order by row_to_json(t)::text')->fetchAll(PDO::FETCH_COLUMN);return $out; };
$refuse = static function($action, $label) use ($check) { try{$action();}catch(InvalidArgumentException|RuntimeException|LogicException $e){$check(true,$label);return;}throw new RuntimeException($label); };
$tables = ['v_default_settings','v_permissions','v_groups','v_group_permissions','v_menus','v_menu_items','v_menu_languages','v_menu_item_groups','v_domains','v_users','v_dialplans','v_dialplan_details'];
$domain = uuid(); $other = uuid();
$q("insert into v_domains(domain_uuid,domain_name,domain_enabled) values(?,'first.upgrade-fixture.invalid',true)",[$domain]);
$_SESSION=['domain_uuid'=>$domain,'domain_name'=>'first.upgrade-fixture.invalid'];
(new groups)->defaults(); (new menu)->menu_default();
$dialplan=new dialplan(['database'=>$database]);$dialplan->import($q('select * from v_domains')->fetchAll(PDO::FETCH_ASSOC));
$domains_processed=1;include PROJECT_ROOT.'/app/dialplans/app_defaults.php';
$before=$snapshot(['v_dialplans','v_dialplan_details']); usleep(20000);include PROJECT_ROOT.'/app/dialplans/app_defaults.php';
$check($before===$snapshot(['v_dialplans','v_dialplan_details']),'Unchanged stock XML does not refresh any dialplan audit columns');
$q("insert into v_domains(domain_uuid,domain_name,domain_enabled) values(?,'second.upgrade-fixture.invalid',true)",[$other]);
$dialplan->import([['domain_uuid'=>$other,'domain_name'=>'second.upgrade-fixture.invalid']]);
foreach($before as $table=>$rows)foreach($rows as $row)$check(in_array($row,$snapshot([$table])[$table],true),'Scoped new-domain import preserves every previous/global row');

// The actual first-install administrator stage must finish its intended type,
// before any preservation baseline or future defaults are considered.
$secrets=dirname($configFile).'/admin.private.json';file_put_contents($secrets,json_encode(['AdminEmail'=>'owner@upgrade-fixture.invalid','AdminPassword'=>bin2hex(random_bytes(20))],JSON_THROW_ON_ERROR));
$child=dirname($configFile).'/admin-stage.php';file_put_contents($child,'<?php require '.var_export(PROJECT_ROOT.'/resources/classes/config.php',true).';config::load('.var_export($configFile,true).');$argv=["bootstrap",'.var_export(PROJECT_ROOT,true).',"admin"];require '.var_export(PROJECT_ROOT.'/packaging/windows/bootstrap.php',true).';');
$process=proc_open([PHP_BINARY,$child],[0=>['pipe','r'],1=>['pipe','w'],2=>['pipe','w']],$pipes,null,array_merge(getenv(),['OPENWEB_SETUP_SECRETS'=>$secrets,'OPENWEB_RESTORE_SERVER'=>'true']));
fclose($pipes[0]);$stdout=stream_get_contents($pipes[1]);$stderr=stream_get_contents($pipes[2]);fclose($pipes[1]);fclose($pipes[2]);$exit=proc_close($process);
if($exit!==0){file_put_contents(dirname($configFile).'/admin-error.private.log',$stderr);throw new RuntimeException('Actual administrator bootstrap failed');}
$check($q("select user_type from v_users where username='owner@upgrade-fixture.invalid'")->fetchColumn()==='default','Actual fresh administrator has intended user type immediately');

$menu=$q("select * from v_menus where menu_name='default'")->fetch(PDO::FETCH_ASSOC);
$parent=$q('select * from v_menu_items where menu_uuid=? and menu_item_parent_uuid is null and uuid is not null limit 1',[$menu['menu_uuid']])->fetch(PDO::FETCH_ASSOC);
$q("update v_menu_items set menu_item_title='Custom owner title',menu_item_description='Custom description' where menu_item_uuid=?",[$parent['menu_item_uuid']]);
$customMenu=uuid();$q("insert into v_menu_items(menu_item_uuid,menu_uuid,menu_item_title,menu_item_link,menu_item_parent_uuid) values(?,?,'Private custom menu','/owned/custom',?)",[$customMenu,$menu['menu_uuid'],$parent['menu_item_uuid']]);
$oldLeaf=$q('select menu_item_uuid from v_menu_items where menu_uuid=? and menu_item_parent_uuid is not null limit 1',[$menu['menu_uuid']])->fetchColumn();
foreach(['v_menu_item_groups','v_menu_languages','v_menu_items'] as $table)$q('delete from '.$table.' where menu_item_uuid=?',[$oldLeaf]);
$adminGroup=$q("select group_uuid from v_groups where group_name='admin' and domain_uuid is null")->fetchColumn();
$permission=$q("select * from v_group_permissions where group_name='admin' and domain_uuid is null limit 1")->fetch(PDO::FETCH_ASSOC);
$q("update v_group_permissions set permission_assigned='false',permission_protected='true' where group_permission_uuid=?",[$permission['group_permission_uuid']]);
$q("insert into v_group_permissions(group_permission_uuid,domain_uuid,group_uuid,group_name,permission_name,permission_assigned) values(?,?,?,'admin',?,'false')",[uuid(),$domain,$adminGroup,$permission['permission_name']]);
$deletedPlan=$q('select * from v_dialplans where domain_uuid=? and app_uuid is not null limit 1',[$domain])->fetch(PDO::FETCH_ASSOC);
$q('delete from v_dialplan_details where dialplan_uuid=?',[$deletedPlan['dialplan_uuid']]);$q('delete from v_dialplans where dialplan_uuid=?',[$deletedPlan['dialplan_uuid']]);
$disabledPlan=$q('select dialplan_uuid from v_dialplans where domain_uuid=? limit 1',[$domain])->fetchColumn();
$q("update v_dialplans set dialplan_enabled=false,dialplan_description='Custom disabled routing',dialplan_xml=null where dialplan_uuid=?",[$disabledPlan]);
$baseline=$snapshot($tables);$initializer=new pbx_upgrade_defaults($db,PROJECT_ROOT,$previousRoot);
$check($initializer->apply()===['settings'=>0,'permission_catalog'=>0,'permissions'=>0,'menus'=>0,'dialplan_applications'=>0],'Same metadata has no additive defaults');
$check($baseline===$snapshot($tables),'Existing UUIDs, denies, custom/deleted/disabled rows stay byte-equivalent');
if (is_dir(dirname($previousRoot).'/previous-106')) {
 $legacyInitializer=new pbx_upgrade_defaults($db,PROJECT_ROOT,dirname($previousRoot).'/previous-106');$before=$snapshot($tables);$legacyInitializer->apply();
 foreach($before as $table=>$rows){$currentRows=$snapshot([$table])[$table];foreach($rows as $row)$check(in_array($row,$currentRows,true),'Actual 1.0.6 metadata delta preserves every original row');}
 $check((int)$q("select count(*) from v_permissions where permission_name='pbx_mobile_review'")->fetchColumn()===1,'Actual group-less Android permission enters catalog');
 $check((int)$q("select count(*) from v_group_permissions where permission_name='pbx_mobile_review'")->fetchColumn()===0,'Actual group-less Android permission adds no grant');
 $check((int)$q("select count(distinct p.permission_name) from v_permissions p join v_group_permissions g using(permission_name) where p.permission_name in('pbx_core_view','pbx_core_control','pbx_core_supervise')")->fetchColumn()===3,'Actual Switchboard permissions remain administrable through the real join');
 $before=$snapshot($tables);$legacyInitializer->apply();$check($before===$snapshot($tables),'Actual 1.0.6 metadata upgrade repeats without drift');
}

$feature=PROJECT_ROOT.'/app/upgrade_fixture';mkdir($feature.'/resources/switch/conf/dialplan',0755,true);
$ids=['setting'=>uuid(),'array'=>uuid(),'menu'=>uuid(),'child'=>uuid(),'plan'=>uuid()];
$stockCases=[];
foreach(['010_user_exists.xml'=>3,'050_record_all.xml'=>4] as $name=>$conditionCount){
 $stock=file_get_contents(PROJECT_ROOT.'/app/dialplans/resources/switch/conf/dialplan/'.$name);$stockId=uuid();
 $stock=preg_replace('/app_uuid="[a-f0-9-]+"/','app_uuid="'.$stockId.'"',$stock,1);
 file_put_contents($feature.'/resources/switch/conf/dialplan/'.$name,$stock);
 $stockCases[]=['id'=>$stockId,'source'=>$stock,'conditions'=>$conditionCount,'global'=>$name==='010_user_exists.xml'];
}
$q("insert into v_group_permissions(group_permission_uuid,group_uuid,group_name,permission_name,permission_assigned) values(?,?,'admin','ow_new_global_denied','false')",[uuid(),$adminGroup]);
$scopedGroup=uuid();$q("insert into v_groups(group_uuid,domain_uuid,group_name,group_protected) values(?,?,'admin',false)",[$scopedGroup,$other]);
$q("insert into v_group_permissions(group_permission_uuid,domain_uuid,group_uuid,group_name,permission_name,permission_assigned) values(?,?,?,'admin','ow_new_scoped_denied','false')",[uuid(),$other,$scopedGroup]);
$writeFeature=static function($ids)use($feature,$parent){
 $settings=[['default_setting_uuid'=>$ids['setting'],'default_setting_category'=>'ow_upgrade_fixture','default_setting_subcategory'=>'new_feature','default_setting_name'=>'text','default_setting_value'=>'new default','default_setting_enabled'=>'true'],['default_setting_uuid'=>$ids['array'],'default_setting_category'=>'ow_upgrade_fixture','default_setting_subcategory'=>'options','default_setting_name'=>'array','default_setting_value'=>null,'default_setting_order'=>null,'default_setting_enabled'=>'false']];
 $perms=[['name'=>'ow_new_no_groups','groups'=>[]]];foreach(['ow_new_allowed','ow_new_global_denied','ow_new_scoped_denied'] as $name)$perms[]=['name'=>$name,'groups'=>['admin']];
 file_put_contents($feature.'/app_config.php','<?php $apps[$x] = '.var_export(['name'=>'Upgrade fixture','uuid'=>'68f3e55a-2fa3-45d2-b3e3-5140a2eea734','default_settings'=>$settings,'permissions'=>$perms],true).';');
 $menus=[['uuid'=>$ids['menu'],'parent_uuid'=>$parent['uuid'],'title'=>['en-us'=>'New capability','en-gb'=>'New capability GB'],'path'=>'/app/upgrade_fixture/','category'=>'internal','groups'=>['admin']],['uuid'=>$ids['child'],'parent_uuid'=>$ids['menu'],'title'=>['en-us'=>'New child'],'path'=>'/app/upgrade_fixture/child','category'=>'internal','groups'=>['admin']]];
 file_put_contents($feature.'/app_menu.php','<?php $apps[$x]["menu"] = '.var_export($menus,true).';');
 file_put_contents($feature.'/resources/switch/conf/dialplan/new.xml','<extension name="new-capability" app_uuid="'.$ids['plan'].'" context="{v_context}" order="777" enabled="true"><condition field="destination_number" expression="^98765$"><action application="set" data="fixture=true"/></condition><condition field="fixture" expression="^true$"><action application="hangup" data="NORMAL_CLEARING"/></condition></extension>');
};
$writeFeature($ids);$baseline=$snapshot($tables);
$counts=$initializer->apply();$check($counts===['settings'=>2,'permission_catalog'=>4,'permissions'=>1,'menus'=>2,'dialplan_applications'=>3],'Only genuinely new catalog/settings, allowed permission, menu and stock applications are inserted');
$check((int)$q("select count(*) from v_permissions where permission_name='ow_new_no_groups'")->fetchColumn()===1&&(int)$q("select count(*) from v_group_permissions where permission_name='ow_new_no_groups'")->fetchColumn()===0,'A catalog-only permission receives no implicit group grant');
$check((int)$q("select count(*) from v_permissions p join v_group_permissions g using(permission_name) where p.permission_name='ow_new_allowed' and g.group_name='admin'")->fetchColumn()===1,'New catalog entry is visible through the actual group permission join');
foreach($baseline as $table=>$rows){$after=$snapshot([$table])[$table];foreach($rows as $row)$check(in_array($row,$after,true),'Every original complete row survives additive initialization');}
$check((int)$q('select count(*) from v_dialplans where app_uuid=?',[$ids['plan']])->fetchColumn()===2,'New scoped stock application reaches both domains');
$check((int)$q('select count(*) from v_dialplans where app_uuid=? and dialplan_xml is not null',[$ids['plan']])->fetchColumn()===2,'New native XML is generated within the transaction');
foreach($stockCases as $case){
 $document=new DOMDocument();$document->loadXML($case['source'],LIBXML_NONET);$expected=[];$order=5;$group=0;
 foreach($document->documentElement->childNodes as $condition){
  if($condition->nodeType!==XML_ELEMENT_NODE)continue;
  $expected[]=['dialplan_detail_tag'=>'condition','dialplan_detail_type'=>$condition->getAttribute('field'),'dialplan_detail_data'=>$condition->getAttribute('expression'),'dialplan_detail_order'=>$order,'dialplan_detail_group'=>$group];$order+=5;$hasAction=false;
  foreach($condition->childNodes as $action){
   if($action->nodeType!==XML_ELEMENT_NODE)continue;$hasAction=true;
   $expected[]=['dialplan_detail_tag'=>$action->nodeName,'dialplan_detail_type'=>$action->getAttribute('application'),'dialplan_detail_data'=>$action->getAttribute('data'),'dialplan_detail_order'=>$order,'dialplan_detail_group'=>$group];$order+=5;
  }
  if($hasAction)$group++;$order+=5;
 }
 $plans=$q('select * from v_dialplans where app_uuid=?',[$case['id']])->fetchAll(PDO::FETCH_ASSOC);
 $check(count($plans)===($case['global']?1:2),'Actual multi-condition stock shape creates exactly one header per intended scope');
 foreach($plans as $plan){
  $actual=$q('select dialplan_detail_tag,dialplan_detail_type,dialplan_detail_data,dialplan_detail_order,dialplan_detail_group from v_dialplan_details where dialplan_uuid=? order by dialplan_detail_order',[$plan['dialplan_uuid']])->fetchAll(PDO::FETCH_ASSOC);
  foreach($actual as &$detail){$detail['dialplan_detail_order']=(int)$detail['dialplan_detail_order'];$detail['dialplan_detail_group']=(int)$detail['dialplan_detail_group'];}unset($detail);
  $check($actual===$expected,'Actual stock condition/action data, order and groups match source exactly');
  $check((int)$q("select count(*) from v_dialplan_details where dialplan_uuid=? and dialplan_detail_tag='condition'",[$plan['dialplan_uuid']])->fetchColumn()===$case['conditions'],'All actual stock conditions survive filtered import');
  $check((int)$q('select count(*) from v_dialplan_details where dialplan_uuid=? and domain_uuid is distinct from ?',[$plan['dialplan_uuid'],$plan['domain_uuid']])->fetchColumn()===0,'Every native child retains exact parent/domain ownership');
  $generated=new DOMDocument();$check($generated->loadXML($plan['dialplan_xml'],LIBXML_NONET)&&(new DOMXPath($generated))->query('/extension/condition')->length===$case['conditions'],'Generated stock native XML retains all conditions');
  $check($case['global']?$plan['domain_uuid']===null:in_array($plan['domain_uuid'],[$domain,$other],true),'Global and domain ownership remain exact');
 }
}
$newMenu=$q('select * from v_menu_items where uuid=?',[$ids['menu']])->fetch(PDO::FETCH_ASSOC);$newChild=$q('select * from v_menu_items where uuid=?',[$ids['child']])->fetch(PDO::FETCH_ASSOC);
$check($newMenu['menu_item_parent_uuid']===$parent['menu_item_uuid']&&$newChild['menu_item_parent_uuid']===$newMenu['menu_item_uuid'],'New parent links use preserved installed UUIDs');
$check((int)$q("select count(*) from v_group_permissions where domain_uuid is null and permission_name in('ow_new_global_denied','ow_new_scoped_denied') and permission_assigned='true'")->fetchColumn()===0,'Global and tenant scoped denies cannot be widened');
$after=$snapshot($tables);$initializer->apply();$check($after===$snapshot($tables),'Repeated additive initialization is exactly idempotent');
$check((int)$q('select count(*) from v_dialplans where domain_uuid=? and app_uuid=?',[$domain,$deletedPlan['app_uuid']])->fetchColumn()===0,'Intentionally deleted old stock routing is not reintroduced');

// Simulate a later feature inside the caller's rollback boundary.
$next=array_map(static fn()=>uuid(),$ids);$writeFeature($next);$before=$snapshot($tables);$db->beginTransaction();$initializer->apply();$check($db->inTransaction(),'Initializer retains caller transaction ownership');$db->rollBack();$check($before===$snapshot($tables),'Rollback restores all additive rows and generated native details');$writeFeature($ids);
$next=array_map(static fn()=>uuid(),$ids);$writeFeature($next);$before=$snapshot($tables);
$db->exec("create function ow_upgrade_late_fault() returns trigger language plpgsql as 'begin if NEW.uuid = ''".$next['child']."''::uuid then raise exception ''owned late fault''; end if; return NEW; end;'");
$db->exec('create trigger ow_upgrade_late_fault before insert on v_menu_items for each row execute function ow_upgrade_late_fault()');
$refuse(fn()=>$initializer->apply(),'Actual PostgreSQL late insertion fault is propagated');
$check(!$db->inTransaction()&&$before===$snapshot($tables),'Automatic rollback restores earlier defaults/catalog/grants/parent inserts after a late fault');
$db->exec('drop trigger ow_upgrade_late_fault on v_menu_items');$db->exec('drop function ow_upgrade_late_fault()');$writeFeature($ids);
$before=$snapshot($tables);$db->beginTransaction();
$refuse(fn()=>(new dialplan)->import([],['not-a-uuid']),'Invalid application filter refuses');
$refuse(fn()=>(new dialplan)->import([],[$ids['plan'],strtoupper($ids['plan'])]),'Case-duplicate application filter refuses');
$refuse(fn()=>(new dialplan)->import([],[uuid()]),'Unknown application filter refuses');
$db->rollBack();$check($before===$snapshot($tables),'Rejected filters never mutate data');
file_put_contents($feature.'/resources/switch/conf/dialplan/duplicate.xml',file_get_contents($feature.'/resources/switch/conf/dialplan/new.xml'));
$refuse(fn()=>$initializer->apply(),'Ambiguous stock metadata refuses before any write');unlink($feature.'/resources/switch/conf/dialplan/duplicate.xml');
$check($before===$snapshot($tables),'Ambiguous metadata preserves the complete database');

// Execute the retained exact legacy-title SQL, preserving custom titles and translations.
$titleIds=[];foreach(['PBX Setup','Custom administration'] as $title){$id=uuid();$titleIds[]=$id;$q("insert into v_menu_items(menu_item_uuid,menu_uuid,menu_item_link,menu_item_title) values(?,?,'/app/pbx_setup/',?)",[$id,$menu['menu_uuid'],$title]);foreach(['PBX Setup','Custom translation'] as $text)$q('insert into v_menu_languages(menu_language_uuid,menu_item_uuid,menu_item_title) values(?,?,?)',[uuid(),$id,$text]);}
$db->exec(file_get_contents(PROJECT_ROOT.'/app/pbx_setup/resources/restore.sql'));
$check($q('select menu_item_title from v_menu_items where menu_item_uuid=?',[$titleIds[0]])->fetchColumn()==='Admin','Exact legacy title migrates');
$check($q('select menu_item_title from v_menu_items where menu_item_uuid=?',[$titleIds[1]])->fetchColumn()==='Custom administration','Custom matching-path title stays unchanged');
$check((int)$q("select count(*) from v_menu_languages where menu_item_uuid in(?,?) and menu_item_title='Custom translation'",$titleIds)->fetchColumn()===2,'Custom translations remain unchanged independently');

// Supported historical filesystem migration, including selected path SQL.
$conf=dirname($configFile).'/phrase-conf';mkdir($conf.'/lang/en/vm',0755,true);
$main='<document><X-PRE-PROCESS cmd="include" data="lang/en/en.xml"/><X-PRE-PROCESS data="lang/de/*.xml" cmd="include"/><X-PRE-PROCESS cmd="include" data="lang/es/es_ES.xml"/><X-PRE-PROCESS cmd="include" data="custom/*.xml"/></document>';
$language='<include><X-PRE-PROCESS cmd="include" data="vm/sounds.xml"/></include>';
file_put_contents($conf.'/freeswitch.xml',$main);file_put_contents($conf.'/lang/en/en.xml',$language);
$selected=uuid();$disabled=uuid();$customSetting=uuid();
foreach([[$selected,$conf.'/lang',true],[$disabled,$conf.'/lang',false],[$customSetting,$conf.'/custom',true]] as [$id,$path,$enabled])$q("insert into v_default_settings(default_setting_uuid,default_setting_category,default_setting_subcategory,default_setting_name,default_setting_value,default_setting_enabled) values(?,'switch','languages','dir',?,?)",[$id,$path,$enabled]);
$counts=$initializer->voicemailFiles($conf);
$check($counts===['language_paths'=>1,'includes'=>2,'phrase_files'=>1],'Only selected legacy language layout and absent phrase migrate');
$check(file_get_contents($conf.'/freeswitch.xml')===str_replace('data="lang/','data="languages/',$main),'Real legacy per-language include suffixes and all other bytes are preserved');
$check(file_get_contents($conf.'/languages/en/en.xml')===str_replace('data="vm/sounds.xml"','data="vm/*.xml"',$language),'Language include changes exact bytes only');
$check($q('select default_setting_value from v_default_settings where default_setting_uuid=?',[$selected])->fetchColumn()===$conf.'/languages','Only exact enabled old global setting redirects');
$check($q('select default_setting_value from v_default_settings where default_setting_uuid=?',[$disabled])->fetchColumn()===$conf.'/lang','Disabled path remains untouched');
$check($q('select default_setting_value from v_default_settings where default_setting_uuid=?',[$customSetting])->fetchColumn()===$conf.'/custom','Custom path remains untouched');
$customPhrase='<include><!-- owned custom voicemail --></include>';file_put_contents($conf.'/languages/en/vm/voicemail.xml',$customPhrase);
$counts=$initializer->voicemailFiles($conf);$check($counts===['language_paths'=>0,'includes'=>0,'phrase_files'=>0]&&file_get_contents($conf.'/languages/en/vm/voicemail.xml')===$customPhrase,'Current/custom phrase bytes survive repeat');
$vanillaFile=dirname($configFile).'/native-vanilla.xml';
if(is_file($vanillaFile)){
 $vanilla=file_get_contents($vanillaFile);$document=new DOMDocument();$check($document->loadXML($vanilla,LIBXML_NONET),'Pinned native vanilla XML is valid');
 $expected=$vanilla;$nodes=(new DOMXPath($document))->query('//X-PRE-PROCESS[@cmd="include" and starts-with(@data,"lang/")]');
 $check($nodes->length===7,'Pinned vanilla fixture contains its seven actual legacy language includes');
 foreach($nodes as $node){$old=$node->getAttribute('data');$expected=str_replace('data="'.$old.'"','data="languages/'.substr($old,5).'"',$expected);}
 file_put_contents($conf.'/freeswitch.xml',$vanilla);$initializer->voicemailFiles($conf);
 $check(file_get_contents($conf.'/freeswitch.xml')===$expected,'Actual pinned vanilla suffixes and disabled/noninclude bytes remain exact');
}
$phraseTables=$snapshot($tables);
foreach(['<include><broken></include>','<!DOCTYPE include [<!ENTITY bad "blocked">]><include>&bad;</include>'] as $bad){
 file_put_contents($conf.'/languages/en/en.xml',$bad);
 $refuse(fn()=>$initializer->voicemailFiles($conf),'Malformed and DTD/entity phrase XML refuses without publication');
 $check(file_get_contents($conf.'/languages/en/en.xml')===$bad&&file_get_contents($conf.'/languages/en/vm/voicemail.xml')===$customPhrase,'Invalid phrase XML cannot overwrite custom target bytes');
}
$check($phraseTables===$snapshot($tables),'Filesystem refusal does not replay unrelated SQL defaults');
file_put_contents($conf.'/languages/en/en.xml',str_replace('data="vm/sounds.xml"','data="vm/*.xml"',$language));
mkdir($conf.'/lang');$q('update v_default_settings set default_setting_value=? where default_setting_uuid=?',[$conf.'/lang',$selected]);$before=$snapshot(['v_default_settings']);
$refuse(fn()=>$initializer->voicemailFiles($conf),'Two existing language trees refuse ambiguous redirection');$check($before===$snapshot(['v_default_settings']),'Ambiguous directories preserve original setting rows');
$check(glob($conf.'/languages/en/vm/*.upgrade-*')===[],'No temporary phrase files remain');

restore_error_handler();
file_put_contents(dirname($configFile).'/safe-result.json',json_encode(['state'=>'passed','checks'=>$checks,'actual_postgresql'=>true,'exact_original_rows_preserved'=>true,'same_version_idempotent'=>true,'caller_rollback_preserved'=>true,'owned_scoped_domain_import'=>true,'voicemail_filesystem_compatibility'=>true],JSON_PRETTY_PRINT|JSON_THROW_ON_ERROR));
echo $checks." actual PostgreSQL/filesystem preservation checks passed.\n";
