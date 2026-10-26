<?php
/** Actual isolated PostgreSQL and HTTP-dispatch checks. No live PBX or SIP engine. */
if(PHP_SAPI!=='cli'&&PHP_SAPI!=='cli-server')exit;
define('PROJECT_ROOT',dirname(__DIR__));
function is_uuid($s):bool{return is_string($s)&&preg_match('/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/D',$s);}
function uuid():string{$h=bin2hex(random_bytes(16));return substr($h,0,8).'-'.substr($h,8,4).'-'.substr($h,12,4).'-'.substr($h,16,4).'-'.substr($h,20);}
function permission_exists($s):bool{return true;}
class config{static function load(){return new self;}function get($key,$default=''){return $key==='openweb.mobile_tls_ready'?'true':$default;}}
class cache{function delete($s){}}
class event_socket{static array $commands=[];static function api($s){self::$commands[]=$s;return '+OK';}}
class pbx_paths{static function host(){return 'original.example.invalid';}static function url(){return 'https://'.self::host();}static function state(){return $GLOBALS['state'];}}
class pbx_mobile_push{function __construct($db){}function client(){return ['enabled'=>false];}}
class pbx_video{static function ready(){return false;}}
class pbx_setup{function __construct($db){}function canManage(){return true;}}
class pbx_tenants{function __construct($db){}function canDomain($d){return true;}}
class pbx_admin{function __construct(private PDO $db,$staff=null){}function config(){return json_decode($this->db->query("select config from v_pbx_restore where domain_uuid='".$_SESSION['domain_uuid']."'")->fetchColumn(),true);}}
class database{static function new(){return(object)['db'=>$GLOBALS['httpDb']];}}
require PROJECT_ROOT.'/resources/classes/pbx_tenant_domains.php';
require PROJECT_ROOT.'/resources/classes/pbx_mobile_password.php';
require getenv('OPENWEB_MOBILE_TEST_SOURCE')?:PROJECT_ROOT.'/resources/classes/pbx_mobile.php';
require PROJECT_ROOT.'/resources/classes/pbx_mobile_welcome.php';
$dsn=getenv('OPENWEB_TEST_DSN');if(!$dsn)throw new RuntimeException('Use an isolated PostgreSQL DSN.');
$db=new PDO($dsn,'postgres',null,[PDO::ATTR_ERRMODE=>PDO::ERRMODE_EXCEPTION]);
if(defined('OPENWEB_ORIGIN_HTTP_BOOT')) {
    $db->exec('set search_path to '.$GLOBALS['httpFixture']['schema']);$GLOBALS['state']=$GLOBALS['httpFixture']['state'];$GLOBALS['httpDb']=$db;return;
}
$schema='mobile_origin_'.bin2hex(random_bytes(6));$state=sys_get_temp_dir().'/'.$schema;mkdir($state,0700);$GLOBALS['state']=$state;
$minimal=getenv('OPENWEB_MOBILE_MINIMAL')==='1';$n=0;$process=null;
$q=function($sql,$args=[])use($db){$s=$db->prepare($sql);$s->execute($args);return$s;};
$check=function($ok,$why)use(&$n){if(!$ok)throw new RuntimeException($why);$n++;};
$reject=function($fn,$why)use($check){try{$fn();}catch(InvalidArgumentException|RuntimeException){$check(true,$why);return;}$check(false,$why);};
try {
    $db->exec('create schema '.$schema.';set search_path to '.$schema);
    $db->exec("create table v_domains(domain_uuid uuid primary key,domain_name text,domain_enabled text);create table v_users(user_uuid uuid primary key);create table v_extensions(extension_uuid uuid primary key,domain_uuid uuid references v_domains,extension text,number_alias text,password text,effective_caller_id_name text,enabled text);create table v_pbx_restore(domain_uuid uuid primary key,config jsonb);create table v_pbx_tenants(tenant_uuid uuid primary key,enabled boolean);create table v_pbx_services(service_uuid uuid primary key,tenant_uuid uuid,domain_uuid uuid);create table v_email_queue(email_queue_uuid uuid primary key,email_status text,update_date timestamptz,domain_uuid uuid,hostname text,email_date timestamptz,email_from text,email_to text,email_subject text,email_body text);create table v_email_queue_attachments(email_queue_attachment_uuid uuid primary key,email_queue_uuid uuid,domain_uuid uuid,email_attachment_type text,email_attachment_name text,email_attachment_mime_type text,email_attachment_path text,email_attachment_base64 text,email_attachment_cid text)");
    $sql=file_get_contents(PROJECT_ROOT.'/app/pbx_mobile/resources/install.sql');
    if($minimal)$sql=substr($sql,0,strpos($sql,'-- App sign-in'))."COMMIT;\n";
    $db->exec($sql);$db->exec(file_get_contents(PROJECT_ROOT.'/app/pbx_tenant_domains/resources/install.sql'));
    $actor=uuid();$q('insert into v_users values(?)',[$actor]);$_SESSION=['user_uuid'=>$actor,'authorized'=>true];
    $domains=[];$extensions=[];$tenants=[];$hosts=[];$key=bin2hex(random_bytes(32));$aliases=[];
    for($i=0;$i<2;$i++) {
        $d=uuid();$x=uuid();$t=uuid();$service=uuid();$realm='owned-'.$i.'.example.invalid';$host='qa-'.bin2hex(random_bytes(6)).'.openwebpbx.com';
        $domains[]=$d;$extensions[]=$x;$tenants[]=$t;$hosts[]=$host;$aliases[$host]=gmdate('c',time()+86400);
        $q('insert into v_domains values(?,?,?)',[$d,$realm,'true']);$q('insert into v_extensions values(?,?,?,?,?,?,?)',[$x,$d,'original-auth','100','original-phone-password','Fictional User','true']);
        $q('insert into v_pbx_restore values(?,?::jsonb)',[$d,json_encode(['realm'=>$realm,'users'=>['100'=>['extension_uuid'=>$x,'enabled'=>true,'auth_id'=>'original-auth','name'=>'Fictional User','email'=>'setup@example.invalid']]])]);
        $q('insert into v_pbx_tenants values(?,true)',[$t]);$q('insert into v_pbx_services values(?,?,?)',[$service,$t,$d]);
        $q("insert into v_pbx_tenant_domains(domain_uuid,tenant_uuid,service_uuid,requested_label,hostname,server_host,key_hash,revision,state,desired_enabled,certificate_not_after)values(?,?,?,'fixture',?,?,?,1,'ready',true,now()+interval '1 day')",[$d,$t,$service,$host,pbx_paths::host(),$key]);
    }
    mkdir($state.'/tenant-domains',0750);$marker=$state.'/tenant-domains/ready.json';
    $write=function($values)use($marker,$key){file_put_contents($marker,json_encode(['schema'=>1,'server_host'=>pbx_paths::host(),'key_hash'=>$key,'aliases'=>$values]));chmod($marker,0640);};
    $write($aliases);$_SESSION['domain_uuid']=$domains[0];$mobile=new pbx_mobile($db);
    $original=$db->query('select * from v_extensions order by extension_uuid')->fetchAll(PDO::FETCH_ASSOC);
    $restore=$db->query('select * from v_pbx_restore order by domain_uuid')->fetchAll(PDO::FETCH_ASSOC);
    $caps=$mobile->capabilities(['HTTP_HOST'=>$hosts[0]],'cap-ip');
    $check($caps['schema']===1&&$caps['app_password']===!$minimal,'Capabilities reflect complete optional schema');
    $check($caps['tenant_uuid']===$tenants[0]&&$caps['domain_uuid']===$domains[0]&&$caps['server']==='https://'.$hosts[0]&&$caps['canonical_origin']===pbx_paths::url(),'Public capabilities bind exact tenant and canonical origin');
    $check(array_keys($caps)===['schema','tenant_uuid','domain_uuid','server','canonical_origin','app_password','windows_phone'],'Public capabilities contain only the exact declared metadata');
    foreach([pbx_paths::host(),'unknown.openwebpbx.com','openwebpbx.com',$hosts[0].'.evil.invalid',$hosts[0].':444',$hosts[0].'.',$hosts[0].'@evil.invalid']as$bad)$reject(fn()=>$mobile->capabilities(['HTTP_HOST'=>$bad],'cap-ip'),'Unowned/ambiguous/canonical capability origin refused');
    $check($mobile->capabilities(['HTTP_HOST'=>strtoupper($hosts[0]).':443'],'cap-ip')['server']==='https://'.$hosts[0],'Case and standard port normalize');
    $code=json_decode($mobile->createCode('100')['payload'],true);$check($code['server']==='https://'.$hosts[0],'QR selects ready alias');$check($code['extension']==='100'&&$code['type']==='openwebpbx'&&$code['version']===1&&preg_match('/^[a-f0-9]{64}$/D',$code['code']),'QR supplies extension, HTTPS tenant URL and one-use code only');
    $devicesBefore=(int)$db->query('select count(*) from v_pbx_mobile_devices')->fetchColumn();
    $reject(fn()=>$mobile->enroll(['code'=>$code['code'],'device_name'=>'Wrong tenant'],'enroll-ip',['HTTP_HOST'=>$hosts[1]]),'Foreign alias cannot redeem code');
    $check((int)$db->query('select count(*) from v_pbx_mobile_devices')->fetchColumn()===$devicesBefore,'Foreign code created no phone');
    $check(!$q('select used_at from v_pbx_mobile_enrollments where code_hash=?',[hash('sha256',$code['code'])])->fetchColumn(),'Foreign attempt does not consume code');
    $a=$mobile->enroll(['code'=>$code['code'],'device_name'=>'Owned phone'],'enroll-ip',['HTTP_HOST'=>$hosts[0]]);
    $account=$mobile->authenticate($a['token']);$mobile->assertHost($account,['HTTP_HOST'=>$hosts[0]]);
    $check($a['account']['tenant_uuid']===$tenants[0]&&$a['account']['domain_uuid']===$domains[0]&&$a['account']['extension_uuid']===$extensions[0],'Authenticated account has exact tenant/domain/extension identities');
    $check($a['account']['server']==='https://'.$hosts[0]&&$a['account']['canonical_origin']===pbx_paths::url(),'Authenticated account origin descriptors');
    $check($a['sip']['server']===pbx_paths::host()&&$a['sip']['domain']==='owned-0.example.invalid','SIP address and realm are independent of alias');
    $check($a['network']===['schema'=>1,'media'=>'pbx','stun_enabled'=>true,'stun_server'=>'openweb.sip.openwebpbx.com:3478','ice_enabled'=>false,'turn_enabled'=>false,'upnp_enabled'=>false],'Enrollment receives managed PBX/STUN policy without changing SIP credentials');
    $reject(fn()=>$mobile->enroll(['code'=>$code['code'],'device_name'=>'Replay'],'enroll-ip',['HTTP_HOST'=>$hosts[0]]),'Used setup code cannot connect another phone');
    $before=$q('select * from v_pbx_mobile_devices where device_uuid=?',[$a['device_id']])->fetch(PDO::FETCH_ASSOC);
    foreach([$hosts[1],'unknown.openwebpbx.com',$hosts[0].':444',$hosts[0].'.','evil.invalid']as$bad)$reject(fn()=>$mobile->assertHost($account,['HTTP_HOST'=>$bad]),'Foreign/invalid bearer recipient refused');
    foreach([pbx_paths::host(),pbx_paths::host().':443',$hosts[0],strtoupper($hosts[0]).':443']as$good){$mobile->assertHost($account,['HTTP_HOST'=>$good]);$check(true,'Owned alias and existing canonical callers remain compatible');}
    $check(!isset($mobile->bootstrap($account)['sip']['password']),'Bootstrap never returns SIP password');
    $reject(fn()=>$mobile->enroll(['code'=>$code['code'],'device_name'=>'Replay'],'enroll-ip',['HTTP_HOST'=>$hosts[0]]),'Used code replay refused');
    $q("update v_pbx_tenant_domains set state='pending_tls' where domain_uuid=?",[$domains[0]]);
    $reject(fn()=>$mobile->createCode('100'),'No canonical QR fallback during pending TLS');
    $reject(fn()=>$mobile->capabilities(['HTTP_HOST'=>$hosts[0]],'cap-ip'),'Pending alias capabilities refuse');
    $reject(fn()=>$mobile->assertHost($account,['HTTP_HOST'=>$hosts[0]]),'Pending alias bearer refuses');
    $q("update v_pbx_tenant_domains set state='ready' where domain_uuid=?",[$domains[0]]);
    $write([$hosts[0]=>gmdate('c',time()-1),$hosts[1]=>$aliases[$hosts[1]]]);
    $reject(fn()=>$mobile->createCode('100'),'Expired actual transport cannot issue code');$write($aliases);
    chmod($marker,0666);$reject(fn()=>$mobile->capabilities(['HTTP_HOST'=>$hosts[0]],'cap-ip'),'Writable readiness marker refuses');chmod($marker,0640);
    $q('update v_pbx_tenants set enabled=false where tenant_uuid=?',[$tenants[0]]);
    $reject(fn()=>$mobile->capabilities(['HTTP_HOST'=>$hosts[0]],'cap-ip'),'Disabled tenant refuses capabilities');
    $reject(fn()=>$mobile->authenticate($a['token']),'Disabled tenant refuses token');$q('update v_pbx_tenants set enabled=true where tenant_uuid=?',[$tenants[0]]);
    if(!$minimal) {
        foreach(["alter table v_pbx_mobile_accounts drop column generation","drop table v_pbx_mobile_accounts","drop table v_pbx_mobile_welcome","alter table v_pbx_mobile_enrollments drop column purpose"]as$ddl) {
            $db->beginTransaction();$db->exec($ddl);
            $check(!$mobile->appPasswordAvailable()&&!in_array('app_password',$mobile->bootstrap($account)['features'],true),'Incomplete optional schema is not advertised');
            $reject(fn()=>$mobile->passwordPrincipal(['extension'=>'100','password'=>'NotARealPassword118'],'login-ip',['HTTP_HOST'=>$hosts[0]]),'Incomplete schema rejects password sign-in before queries');
            $reject(fn()=>$mobile->changePassword($account,['new_password'=>'NotARealPassword118']),'Incomplete schema rejects password change before writes');
            $db->rollBack();
        }
    } else {
        $check(!$db->query("select to_regclass('v_pbx_mobile_accounts')")->fetchColumn()&&!$db->query("select to_regclass('v_pbx_mobile_welcome')")->fetchColumn(),'Stable16 acceptance did not install optional tables');
    }
    // Execute the exact API dispatcher through a private HTTP server. HTTPS is
    // injected by this fixture router; this checks dispatch, not TLS transport.
    $tree=$state.'/http';mkdir($tree.'/app/pbx_mobile',0700,true);mkdir($tree.'/resources',0700);
    copy(getenv('OPENWEB_MOBILE_API_SOURCE')?:PROJECT_ROOT.'/app/pbx_mobile/api.php',$tree.'/app/pbx_mobile/api.php');
    $fixture=['schema'=>$schema,'state'=>$state];
    file_put_contents($tree.'/resources/require.php','<?php define("OPENWEB_ORIGIN_HTTP_BOOT",true); $GLOBALS["httpFixture"]='.var_export($fixture,true).';require '.var_export(__FILE__,true).';');
    file_put_contents($tree.'/router.php','<?php $_SERVER["HTTPS"]="on";return false;');
    $socket=stream_socket_server('tcp://127.0.0.1:0');$port=(int)substr(strrchr(stream_socket_get_name($socket,false),':'),1);fclose($socket);
    $process=proc_open([PHP_BINARY,'-S','127.0.0.1:'.$port,'-t',$tree,$tree.'/router.php'],[0=>['file','/dev/null','r'],1=>['file',$state.'/http.private.log','a'],2=>['file',$state.'/http.private.log','a']],$pipes);
    for($i=0;$i<100;$i++){if($s=@stream_socket_client('tcp://127.0.0.1:'.$port,$errno,$error,0.05)){fclose($s);break;}usleep(10000);}
    $request=function($host,$action,$token=null,$body=null)use($port){$headers="Host: $host\r\nConnection: close\r\n";if($token!==null)$headers.="Authorization: Bearer $token\r\n";if($body!==null)$headers.="Content-Type: application/json\r\n";$context=stream_context_create(['http'=>['method'=>$body!==null?'POST':'GET','header'=>$headers,'content'=>$body!==null?json_encode($body):'','ignore_errors'=>true,'timeout'=>5]]);$raw=file_get_contents('http://127.0.0.1:'.$port.'/app/pbx_mobile/api.php?action='.$action,false,$context);preg_match('~HTTP/1\.[01] ([0-9]+)~',$http_response_header[0],$m);return[(int)$m[1],json_decode($raw,true)];};
    [$status,$value]=$request($hosts[0],'bootstrap',$a['token']);$check($status===200&&$value['account']['domain_uuid']===$domains[0],'Exact API accepts own alias token');
    [$status]=$request($hosts[1],'bootstrap',$a['token']);$check($status===401,'Exact API rejects other tenant token before action');
    [$status,$value]=$request($hosts[0],'capabilities');$check($status===200&&$value===$caps,'Exact API public capabilities dispatch');
    [$status]=$request(pbx_paths::host(),'capabilities');$check($status===404,'Canonical capabilities endpoint refuses');
    [$status]=$request(pbx_paths::host(),'bootstrap',$a['token']);$check($status===200,'Canonical old-phone bootstrap retained');
    [$status]=$request($hosts[1],'revoke',$a['token'],[]);$check($status===401,'Foreign revoke action blocked');
    $check($mobile->authenticate($a['token'])['device_uuid']===$a['device_id'],'Foreign revoke did not change device');
    $next=json_decode($mobile->createCode('100')['payload'],true);
    [$status]=$request($hosts[1],'enroll',null,['code'=>$next['code'],'device_name'=>'Foreign']);$check($status===401,'Exact API passes request origin to enrollment');
    [$status,$value]=$request($hosts[0],'enroll',null,['code'=>$next['code'],'device_name'=>'Owned']);$check($status===200&&$value['account']['domain_uuid']===$domains[0],'Exact API correct alias redeems unconsumed code');
    if($minimal){[$status]=$request($hosts[0],'login',null,['extension'=>'100','password'=>'NotARealPassword118']);$check($status===404,'Minimal hosted overlay does not enable password endpoint');}
    if(!$minimal){
        $welcome=(new pbx_mobile_welcome($db))->queue('100');
        $parts=$q('select * from v_email_queue_attachments where email_queue_uuid=?',[$welcome['queue_uuid']])->fetchAll(PDO::FETCH_ASSOC);
        $setup=array_values(array_filter($parts,fn($p)=>$p['email_attachment_type']==='openwebpbx'));
        $images=array_values(array_filter($parts,fn($p)=>$p['email_attachment_type']==='png'));
        $check(count($setup)===1&&count($images)===1,'Welcome contains one setup file and one inline QR');
        $payload=base64_decode($setup[0]['email_attachment_base64'],true);$invitation=json_decode($payload,true,512,JSON_THROW_ON_ERROR);
        $check($invitation['server']==='https://'.$hosts[0]&&$invitation['extension']==='100'&&!isset($invitation['password'])&&!isset($invitation['token'])&&!isset($invitation['sip']),'Welcome setup carries exact tenant URL and extension without credentials');
        $body=$q('select email_body from v_email_queue where email_queue_uuid=?',[$welcome['queue_uuid']])->fetchColumn();
        $check(str_contains($body,'filled in automatically')&&str_contains($body,$hosts[0])&&str_contains($body,'cid:'.$images[0]['email_attachment_cid']),'Welcome explains automatic server setup and embeds its QR');
        $output=getenv('OPENWEB_QR_MIME_OUTPUT');if($output){file_put_contents($output.'/setup.private.json',$payload);file_put_contents($output.'/setup.private.png',base64_decode($images[0]['email_attachment_base64'],true));}
        $reject(fn()=>$mobile->enroll(['code'=>$invitation['code'],'device_name'=>'Foreign welcome'],'welcome-ip',['HTTP_HOST'=>$hosts[1]]),'Welcome code refuses another tenant without consuming it');
        $joined=$mobile->enroll(['code'=>$invitation['code'],'device_name'=>'Welcome QR'],'welcome-ip',['HTTP_HOST'=>$hosts[0]]);
        $check($joined['account']['extension']==='100'&&$joined['account']['domain_uuid']===$domains[0]&&$joined['network']===$a['network'],'Welcome QR obtains its own complete account and PBX/STUN policy');
        $reject(fn()=>$mobile->enroll(['code'=>$invitation['code'],'device_name'=>'Welcome replay'],'welcome-ip',['HTTP_HOST'=>$hosts[0]]),'Welcome QR cannot be replayed');
        $expired=json_decode($mobile->createCode('100')['payload'],true);$q("update v_pbx_mobile_enrollments set expires_at=now()-interval '1 second' where code_hash=?",[hash('sha256',$expired['code'])]);
        $reject(fn()=>$mobile->enroll(['code'=>$expired['code'],'device_name'=>'Expired'],'expiry-ip',['HTTP_HOST'=>$hosts[0]]),'Expired QR cannot connect a phone');
    }
    $check($before===$q('select * from v_pbx_mobile_devices where device_uuid=?',[$a['device_id']])->fetch(PDO::FETCH_ASSOC),'Existing device row/token/SIP tuple remains exact');
    $check($original===$db->query('select * from v_extensions order by extension_uuid')->fetchAll(PDO::FETCH_ASSOC),'Every original phone row/password remains exact');
    $check($restore===$db->query('select * from v_pbx_restore order by domain_uuid')->fetchAll(PDO::FETCH_ASSOC),'All restored routing/config remains exact');
    $check(event_socket::$commands===[],'No engine commands or phone changes');
    echo 'PASS '.$n.' actual PostgreSQL/HTTP tenant-origin controls ('.($minimal?'minimal stable16':'full source').")\n";
} finally {
    if(is_resource($process)){proc_terminate($process);proc_close($process);}
    if($db->inTransaction())$db->rollBack();$db->exec('set search_path to public');$db->exec('drop schema '.$schema.' cascade');
    $items=new RecursiveIteratorIterator(new RecursiveDirectoryIterator($state,FilesystemIterator::SKIP_DOTS),RecursiveIteratorIterator::CHILD_FIRST);
    foreach($items as$p){if($p->isDir())rmdir($p->getPathname());else unlink($p->getPathname());}rmdir($state);
}
