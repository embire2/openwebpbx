<?php
/** Actual PostgreSQL controls called inside the isolated Meet install fixture. */
function pbx_meet_candidate_checks(PDO $db,callable $check,array $tables): void {
 $profile='cfb1c835-c30c-409b-bff7-a893a7e84df1';$acl='d0b34c75-5fc7-4a2f-9a32-411ab068f662';
 $candidateMethod=new ReflectionMethod(pbx_meet_install::class,'candidates');
 $snapshot=static function()use($db,$tables){$rows=[];foreach($tables as$table)$rows[$table]=$db->query("select coalesce(json_agg(x order by row_to_json(x)::text),'[]')from ".$table.' x')->fetchColumn();return$rows;};
 $check($db->query("select sip_profile_setting_value from v_sip_profile_settings where sip_profile_uuid='$profile' and sip_profile_setting_name='apply-candidate-acl' and sip_profile_setting_enabled=true")->fetchAll(PDO::FETCH_COLUMN)===['openweb-meet-candidates'],'Exactly one explicit candidate policy belongs to Meet');
 $check((int)$db->query("select count(*) from v_sip_profile_settings where sip_profile_uuid<>'$profile' and sip_profile_setting_name='apply-candidate-acl'")->fetchColumn()===0,'Ordinary SIP profiles gain no candidate policy');
 $check($db->query("select access_control_name,access_control_default from v_access_controls where access_control_uuid='$acl'")->fetch(PDO::FETCH_ASSOC)===['access_control_name'=>'openweb-meet-candidates','access_control_default'=>'deny'],'Meeting ACL has a fixed identity and default deny');
 $expected=[['allow','0.0.0.0/0'],['deny','0.0.0.0/8'],['deny','169.254.0.0/16'],['deny','224.0.0.0/4'],['deny','240.0.0.0/4'],['allow','2000::/3'],['allow','fc00::/7'],['allow','::1/128']];sort($expected);
 $actual=$db->query("select node_type,node_cidr from v_access_control_nodes where access_control_uuid='$acl'")->fetchAll(PDO::FETCH_NUM);sort($actual);
 $check($actual===$expected,'Exact meeting unicast ranges exclude unspecified, APIPA, multicast and reserved addresses');
 foreach([true,false,null]as$enabled){
  $db->beginTransaction();try{
   $db->exec("delete from v_sip_profile_settings where sip_profile_uuid='$profile' and sip_profile_setting_name='apply-candidate-acl'");
   $db->prepare("insert into v_sip_profile_settings(sip_profile_setting_uuid,sip_profile_uuid,sip_profile_setting_name,sip_profile_setting_value,sip_profile_setting_enabled)values(?,?,'apply-candidate-acl','administrator-chosen',?)")->execute([uuid(),$profile,$enabled===null?null:($enabled?'true':'false')]);
   $db->exec("update v_access_controls set access_control_default='allow' where access_control_uuid='$acl'");$before=$snapshot();$candidateMethod->invoke(null,$db,true);
   $check($before===$snapshot(),'Existing explicit/disabled/inherited candidate policy and custom ACL remain exact');$check($db->inTransaction(),'Existing candidate policy retains caller transaction');
  }finally{$db->rollBack();}
 }
 $db->beginTransaction();try{
  $db->exec("delete from v_sip_profile_settings where sip_profile_uuid='$profile' and sip_profile_setting_name='apply-candidate-acl'");
  $before=$db->query("select coalesce(json_agg(x order by row_to_json(x)::text),'[]')from v_access_control_nodes x")->fetchColumn();$candidateMethod->invoke(null,$db,true);
  $check($db->inTransaction(),'Missing-policy upgrade retains caller transaction');
  $check($before===$db->query("select coalesce(json_agg(x order by row_to_json(x)::text),'[]')from v_access_control_nodes x")->fetchColumn(),'Missing-policy upgrade retains exact owned node UUIDs');
  $check((int)$db->query("select count(*)from v_sip_profile_settings where sip_profile_uuid='$profile' and sip_profile_setting_name='apply-candidate-acl'")->fetchColumn()===1,'Existing profile gains exactly one missing policy');
 }finally{$db->rollBack();}
 $db->beginTransaction();try{
  $db->exec("delete from v_sip_profile_settings where sip_profile_uuid='$profile' and sip_profile_setting_name='apply-candidate-acl';delete from v_access_control_nodes where access_control_uuid='$acl';delete from v_access_controls where access_control_uuid='$acl'");
  $db->exec("create function reject_meet_candidate()returns trigger language plpgsql as \$\$begin if new.sip_profile_setting_name='apply-candidate-acl' then raise exception 'owned candidate transaction fault';end if;return new;end\$\$;create trigger reject_meet_candidate before insert on v_sip_profile_settings for each row execute function reject_meet_candidate()");
  $before=$snapshot();$refused=false;try{$candidateMethod->invoke(null,$db,true);}catch(PDOException){$refused=true;}
  $check($refused,'Late setting fault occurs after actual candidate ACL/node inserts');$check($db->inTransaction(),'Late candidate fault retains the outer transaction');$check($before===$snapshot(),'Late candidate fault rolls back every owned ACL/node/setting write');
 }finally{$db->rollBack();}
 foreach(['name','uuid','duplicate_name','default','node_missing','node_changed','node_duplicate','orphan']as$case){
  $db->beginTransaction();try{
   $db->exec("delete from v_sip_profile_settings where sip_profile_uuid='$profile' and sip_profile_setting_name='apply-candidate-acl'");
   if($case==='name')$db->exec("update v_access_controls set access_control_name='customer-list'where access_control_uuid='$acl'");
   elseif($case==='uuid')$db->prepare('update v_access_controls set access_control_uuid=? where access_control_uuid=?')->execute([uuid(),$acl]);
   elseif($case==='duplicate_name')$db->prepare("insert into v_access_controls(access_control_uuid,access_control_name,access_control_default)values(?,'openweb-meet-candidates','deny')")->execute([uuid()]);
   elseif($case==='default')$db->exec("update v_access_controls set access_control_default='allow'where access_control_uuid='$acl'");
   elseif($case==='node_missing')$db->exec("delete from v_access_control_nodes where access_control_uuid='$acl'and node_cidr='224.0.0.0/4'");
   elseif($case==='node_changed')$db->exec("update v_access_control_nodes set node_type='allow'where access_control_uuid='$acl'and node_cidr='224.0.0.0/4'");
   elseif($case==='node_duplicate')$db->prepare("insert into v_access_control_nodes(access_control_node_uuid,access_control_uuid,node_type,node_cidr)values(?,?,'allow','0.0.0.0/0')")->execute([uuid(),$acl]);
   else$db->exec("delete from v_access_controls where access_control_uuid='$acl'");
   $before=$snapshot();$refused=false;try{pbx_meet_install::apply($db);}catch(RuntimeException){$refused=true;}
   $check($refused,'Candidate identity/rule contradiction refuses: '.$case);$check($db->inTransaction(),'Candidate refusal retains caller transaction: '.$case);$check($before===$snapshot(),'Candidate preflight refuses before writes: '.$case);
  }finally{$db->rollBack();}
 }
}
