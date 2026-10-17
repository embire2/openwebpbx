<?php
/** Execute the production Lua authentication branch against real, disposable PostgreSQL. */
if(PHP_SAPI!=='cli'||!getenv('OPENWEB_CMB_TEST_DSN'))exit(2);
function auth_reason_db(): PDO{return new PDO(getenv('OPENWEB_CMB_TEST_DSN'),getenv('OPENWEB_CMB_TEST_USER')?:'postgres',null,[PDO::ATTR_ERRMODE=>PDO::ERRMODE_EXCEPTION]);}
if(($argv[1]??'')==='query'){
 $job=json_decode(file_get_contents($argv[2]),true,512,JSON_THROW_ON_ERROR);
 if(!preg_match('/^cmb_authreason_[a-f0-9]{12}$/D',$job['schema']??''))exit(2);
 $db=auth_reason_db();$db->exec('set search_path to '.$job['schema']);$q=$db->prepare($job['sql']);$q->execute($job['args']);echo json_encode($q->fetchAll(PDO::FETCH_ASSOC),JSON_THROW_ON_ERROR);exit;
}
function is_uuid($v):bool{return is_string($v)&&(bool)preg_match('/^[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}$/Di',$v);}
function auth_reason_uuid():string{$h=bin2hex(random_bytes(16));return substr($h,0,8).'-'.substr($h,8,4).'-'.substr($h,12,4).'-'.substr($h,16,4).'-'.substr($h,20);}
require dirname(__DIR__).'/resources/classes/pbx_call_me_back.php';
$root=dirname(__DIR__);$schema='cmb_authreason_'.bin2hex(random_bytes(6));$work=sys_get_temp_dir().'/'.$schema;mkdir($work,0700);$db=auth_reason_db();$checks=0;
$q=static function($sql,$args=[])use($db){$s=$db->prepare($sql);$s->execute($args);return$s;};
$ok=static function(bool $v,string $message)use(&$checks){if(!$v)throw new RuntimeException($message);$checks++;};
$makeId=static function($prefix){for($n=0;$n<10;$n++)if(pbx_call_me_back::validSouthAfricanId($prefix.$n))return$prefix.$n;throw new RuntimeException('Could not create fictional identity.');};
$lua= <<<'LUA'
local fixture_file=assert(arg[1]);local handle=assert(io.open(fixture_file,'rb'));local encoded=handle:read('*a');handle:close()
local base=fixture_file:match('^(.*)/[^/]+$');local bootstrap=assert(io.open(base..'/root.txt','rb'));local root=bootstrap:read('*a');bootstrap:close()
package.path=root..'/app/switch/resources/scripts/?.lua;'..package.path
local json=require'resources.functions.lunajson';local fixture=json.decode(encoded)
local function quote(v)return "'"..v:gsub("'","'\\''").."'"end
local serial=0
local function query(sql,args,callback)
 serial=serial+1;local path=base..'/query-'..serial..'.json';local file=assert(io.open(path,'wb'));file:write(json.encode({schema=fixture.schema,sql=sql,args=args}));file:close()
 local child=assert(io.popen('php '..quote(fixture.helper)..' query '..quote(path),'r'));local data=child:read('*a');assert(child:close(),'Private database helper failed')
 local rows=json.decode(data);if callback then for _,row in ipairs(rows)do callback(row)end end;return true
end
local file=assert(io.open(root..'/app/pbx_setup/resources/switch/scripts/app/pbx_setup/call_me_back.lua','rb'));local production=file:read('*a');file:close()
local start=assert(production:find(' local known=false;local remaining=0',1,true));local stop=assert(production:find(' if not call:ready() or not active() then',start,true))
local fs=assert(production:find('local function finish(result,seconds)',1,true));local fe=assert(production:find('local function active()',fs,true))
local played={};local inputs=0
local call={ready=function()return true end,playAndGetDigits=function()inputs=inputs+1;return fixture.identity end,streamFile=function(_,name)played[#played+1]=name end}
local request=fixture.request;local service={service_uuid=fixture.request.service_uuid};local id=request.request_uuid;local key=fixture.key;local greeting='controlled-greeting'
local Crypto=assert(loadfile(root..'/app/pbx_setup/resources/switch/scripts/app/pbx_setup/cmb_crypto.lua'))()
local function sound(name)return name end
local body='return function(query,call,request,service,id,key,greeting,Crypto,sound)\n'..production:sub(fs,fe-1)..'\nlocal function play(name)if call and call:ready() then call:streamFile(sound(name))end end\n'..production:sub(start,stop-1)..'\nreturn true end'
local execute=assert(load(body,'@production-call-me-back-auth-branch'))()
local continued=execute(query,call,request,service,id,key,greeting,Crypto,sound)
print(json.encode({played=played,inputs=inputs,continued=continued==true}))
LUA;
try{
 file_put_contents($work.'/branch.lua',$lua);file_put_contents($work.'/root.txt',$root);chmod($work.'/branch.lua',0600);chmod($work.'/root.txt',0600);
 $db->exec('create schema '.$schema.';set search_path to '.$schema);$db->exec('create table v_domains(domain_uuid uuid primary key,domain_enabled boolean default true);create table v_pbx_tenants(tenant_uuid uuid primary key,enabled boolean);create table v_pbx_services(domain_uuid uuid,tenant_uuid uuid)');$db->exec(file_get_contents($root.'/app/pbx_setup/resources/call_me_back.sql'));
 $domain=auth_reason_uuid();$foreign=auth_reason_uuid();$service=auth_reason_uuid();$otherService=auth_reason_uuid();$foreignService=auth_reason_uuid();$account=auth_reason_uuid();$correct=$makeId('600101000008');$wrong=$makeId('610101000008');$key=str_repeat('F',32);
 $q('insert into v_domains(domain_uuid) values(?),(?)',[$domain,$foreign]);
 foreach([[$service,$domain],[$otherService,$domain],[$foreignService,$foreign]]as[$s,$d])$q("insert into v_pbx_cmb_services(service_uuid,domain_uuid,name,incoming_rule_uuid,route_owner,prompt_state,prompt_sha256,enabled) values(?,?,'Independent auth reason',?,'1000','ready',repeat('a',64),true)",[$s,$d,auth_reason_uuid()]);
 foreach(['first-zero','first-busy','wrong-id','disabled-id','foreign-tenant','other-service','known-zero','usable']as$case){
  $q('delete from v_pbx_cmb_requests');$q('delete from v_pbx_cmb_bindings');$q('delete from v_pbx_cmb_accounts');
  $accountDomain=$case==='foreign-tenant'?$foreign:$domain;$accountService=$case==='foreign-tenant'?$foreignService:($case==='other-service'?$otherService:$service);$total=in_array($case,['first-zero','known-zero'],true)?0:1000;$reserved=$case==='first-busy'?600:0;
  $proof=pbx_call_me_back::identityHash($accountDomain,$correct,$key);
  $q('insert into v_pbx_cmb_accounts(account_uuid,domain_uuid,service_uuid,name,id_hmac,id_last4,total_seconds,reserved_seconds,enabled) values(?,?,?,?,?,?,?,?,cast(? as boolean))',[$account,$accountDomain,$accountService,'Fictional account',$proof,substr($correct,-4),$total,$reserved,$case==='disabled-id'?'false':'true']);
  if($case==='first-busy')$q("insert into v_pbx_cmb_requests(domain_uuid,service_uuid,account_uuid,inbound_uuid,caller_number,state,reserved_seconds) values(?,?,?,?,'+27820000002','dialling',600)",[$domain,$service,$account,auth_reason_uuid()]);
  if($case==='known-zero')$q("insert into v_pbx_cmb_bindings(domain_uuid,service_uuid,account_uuid,phone_number) values(?,?,?,'+27820000001')",[$domain,$service,$account]);
  $request=auth_reason_uuid();$q("insert into v_pbx_cmb_requests(request_uuid,domain_uuid,service_uuid,inbound_uuid,caller_number,state) values(?,?,?,?,'+27820000001','authenticating')",[$request,$domain,$service,auth_reason_uuid()]);
  $fixture=['schema'=>$schema,'helper'=>__FILE__,'identity'=>$case==='wrong-id'?$wrong:$correct,'key'=>$key,'request'=>['request_uuid'=>$request,'domain_uuid'=>$domain,'service_uuid'=>$service,'caller_number'=>'+27820000001']];$path=$work.'/fixture.json';file_put_contents($path,json_encode($fixture,JSON_THROW_ON_ERROR));chmod($path,0600);
  $pipes=[];$process=proc_open(['lua5.4',$work.'/branch.lua',$path],[0=>['pipe','r'],1=>['pipe','w'],2=>['pipe','w']],$pipes);if(!is_resource($process))throw new RuntimeException('Could not run the production Lua branch.');fclose($pipes[0]);$out=stream_get_contents($pipes[1]);$err=stream_get_contents($pipes[2]);fclose($pipes[1]);fclose($pipes[2]);$exit=proc_close($process);$ok($exit===0&&$err==='','Production Lua branch or real PostgreSQL helper failed for '.$case);$result=json_decode($out,true,512,JSON_THROW_ON_ERROR);
  $row=$q('select state,last_result,reserved_seconds from v_pbx_cmb_requests where request_uuid=?',[$request])->fetch(PDO::FETCH_ASSOC);
  $expected=match($case){'first-zero','known-zero'=>'quota_exhausted','first-busy'=>'account_busy','usable'=>'',default=>'authentication_failed'};
  $prompt=match($expected){'quota_exhausted'=>'quota-exhausted','account_busy'=>'unavailable',''=>'authenticated',default=>'invalid-id'};
  $ok($row['last_result']===$expected&&$result['played']===[$prompt],'Correct/wrong ID or exhausted/busy result was misclassified for '.$case);
  $ok($result['inputs']===($case==='known-zero'?0:1),'Saved caller was reprompted, or a new caller bypassed ID input.');
  $ok($result['continued']===($case==='usable'),'A refused callback reached destination entry, or an allowed one could not continue.');
  if($expected!=='authentication_failed')$ok((int)$q("select count(*) from v_pbx_cmb_requests where last_result='authentication_failed'")->fetchColumn()===0,'Correct identity polluted authentication-failure throttling.');
  $accountState=$q('select used_seconds,reserved_seconds from v_pbx_cmb_accounts where account_uuid=?',[$account])->fetch(PDO::FETCH_ASSOC);$ok($accountState===['used_seconds'=>0,'reserved_seconds'=>$case==='usable'?600:$reserved],'Authentication result changed another call’s reservation or consumed unused minutes.');
 }
 echo "PASS: $checks production Lua authentication-reason, real PostgreSQL/HMAC, exhausted/busy, wrong/disabled/foreign identity and reservation controls\n";
}finally{
 if($db->inTransaction())$db->rollBack();$db->exec('set search_path to public;drop schema if exists '.$schema.' cascade');$files=new RecursiveIteratorIterator(new RecursiveDirectoryIterator($work,FilesystemIterator::SKIP_DOTS),RecursiveIteratorIterator::CHILD_FIRST);foreach($files as$file){if($file->isDir())rmdir($file->getPathname());else unlink($file->getPathname());}rmdir($work);
}
