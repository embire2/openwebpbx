<?php
/** Private HTTP/PG fixture only; never installed in a PBX web root. */
if (!in_array(PHP_SAPI, ['cli', 'cli-server'], true)) exit(2);
$dsn = getenv('OPENWEB_TENANT_HTTP_DSN');
$state = getenv('OPENWEB_TENANT_HTTP_STATE');
if (!is_string($dsn) || !preg_match('/^pgsql:host=127\.0\.0\.1;port=\d+;dbname=postgres$/D', $dsn)
    || !is_string($state) || !is_dir($state)) throw new RuntimeException('An isolated HTTP fixture is required.');
define('PROJECT_ROOT', dirname(__DIR__));
define('PROJECT_PATH', '');
function uuid(): string {
    $b = random_bytes(16); $b[6] = chr((ord($b[6]) & 15) | 64); $b[8] = chr((ord($b[8]) & 63) | 128);
    $h = bin2hex($b); return substr($h, 0, 8).'-'.substr($h, 8, 4).'-'.substr($h, 12, 4).'-'.substr($h, 16, 4).'-'.substr($h, 20);
}
function is_uuid(mixed $value): bool {return is_string($value) && preg_match('/^[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}$/D', $value) === 1;}
function permission_exists(string $name): bool {return !empty($_SESSION['permissions'][$name]);}
class config {
    public static function load(): self {return new self;}
    public function get(string $key, mixed $default = ''): mixed {
        $values = ['openweb.public_host'=>'server.example.test', 'openweb.public_url'=>'https://server.example.test',
            'openweb.tenant_api_enabled'=>'true', 'openweb.tenant_api_registration_enabled'=>'true',
            'openweb.tenant_api.enabled'=>'true', 'openweb.tenant_api.registration_enabled'=>'true'];
        return $values[$key] ?? $default;
    }
}
class database {
    public PDO $db;
    public function __construct() {$this->db = new PDO(getenv('OPENWEB_TENANT_HTTP_DSN'), 'postgres', null, [PDO::ATTR_ERRMODE=>PDO::ERRMODE_EXCEPTION]);}
    public static function new(): self {return $GLOBALS['database'] ??= new self;}
}
class settings {public static function clear_cache(): void {}}
class cache {public function delete(string $value): void {}}
class event_socket {
    public static function api(string $command): string {
        file_put_contents(getenv('OPENWEB_TENANT_HTTP_STATE').'/engine.fixture.jsonl', json_encode($command)."\n", FILE_APPEND | LOCK_EX);
        return '+OK';
    }
}
class pbx_paths {
    public static function host(): string {return 'server.example.test';}
    public static function url(): string {return 'https://server.example.test';}
    public static function state(): string {return getenv('OPENWEB_TENANT_HTTP_STATE');}
    public static function key(): string {return self::state().'/template.key';}
}
$database = database::new(); $db = $database->db;
foreach (['pbx_service_codes','pbx_voicemail_policy','pbx_sip_domain','pbx_tenants','pbx_tenant_domains','pbx_tenant_api_domains','pbx_updates','pbx_setup_provisioner','pbx_tenant_api_setup','pbx_tenant_api','pbx_onboarding','outgoing_mail'] as $class) {
    require_once PROJECT_ROOT.'/resources/classes/'.$class.'.php';
}
if (PHP_SAPI !== 'cli') return;
if (in_array($argv[1] ?? '', ['gui-check','gui-path'], true)) {
    $tenant=$db->prepare('select * from v_pbx_tenants where tenant_uuid=?');$tenant->execute([$argv[2]??'']);$tenant=$tenant->fetch(PDO::FETCH_ASSOC);
    if (!$tenant) throw new RuntimeException('Owned synthetic tenant required.');
    $p=$db->prepare("select distinct p.permission_name from v_user_groups ug join v_group_permissions p using(group_uuid) where ug.user_uuid=? and p.permission_assigned='true'");$p->execute([$tenant['owner_user_uuid']]);
    $_SESSION=['authorized'=>true,'user_uuid'=>$tenant['owner_user_uuid'],'domain_uuid'=>$tenant['home_domain_uuid'],'user'=>['domain_uuid'=>$tenant['home_domain_uuid']],'permissions'=>array_fill_keys($p->fetchAll(PDO::FETCH_COLUMN),true)];
    $app=new pbx_tenants($db);
    if (($argv[1] ?? '') === 'gui-path') {
        $s=$db->prepare('select domain_uuid from v_pbx_services where tenant_uuid=? and service_uuid=?');$s->execute([$tenant['tenant_uuid'],$argv[3]??'']);$domain=$s->fetchColumn();
        if (!is_string($domain)) throw new RuntimeException('Owned synthetic service required.');
        $_SESSION['domain_uuid']=$domain;$_SERVER['REQUEST_URI']=$argv[4]??'';
        $app->guard();echo 'FIXTURE_PATH_ALLOWED';return;
    }
    $result=['templates'=>array_column($app->templates(),'template_uuid')];
    foreach (['template'=>fn()=>$app->template($argv[3]),'provision'=>fn()=>$app->provision(['tenant_uuid'=>$tenant['tenant_uuid'],'template_uuid'=>$argv[3],'service_name'=>'Blocked private template','slug'=>'blocked-template','request_uuid'=>uuid()])] as $key=>$fn) {
        try {$fn();$result[$key.'_blocked']=false;}catch(RuntimeException $e){$result[$key.'_blocked']=true;}
    }
    if (isset($argv[4])) {try {$app->template($argv[4]);$result['unsafe_template_blocked']=false;}catch(RuntimeException $e){$result['unsafe_template_blocked']=true;}}
    if (isset($argv[5])) $result['foreign_domain_allowed']=$app->canDomain($argv[5]);
    $mail=new outgoing_mail($db);$result['smtp_manage']=$mail->canManage();
    foreach (['view'=>fn()=>$mail->view(),'save'=>fn()=>$mail->save([])] as $key=>$fn) {
        try {$fn();$result['smtp_'.$key.'_blocked']=false;}catch(RuntimeException $e){$result['smtp_'.$key.'_blocked']=true;}
    }
    $result['global_grants']=array_values(array_filter(array_keys($_SESSION['permissions']),static fn($p)=>preg_match('/^(smtp_settings_manage|default_setting_|domain_all$|user_domain$|group_|user_group_)/',$p)));
    echo json_encode($result,JSON_THROW_ON_ERROR)."\n";return;
}
if (($argv[1] ?? '') === 'legacy-check') {
    $platform=$db->query("select domain_uuid from v_domains where domain_name='server.example.test'")->fetchColumn();
    $owner=$db->query("select user_uuid from v_users where username='platform@fixture.invalid'")->fetchColumn();
    $_SESSION=['user_uuid'=>$owner,'domain_uuid'=>$platform,'user'=>['domain_uuid'=>$platform],
        'permissions'=>['pbx_tenant_manage'=>true,'pbx_template_manage'=>true,'pbx_service_create'=>true]];
    $app=new pbx_tenants($db);$link=$app->invite(['tenant_name'=>'Trusted invited company','slug'=>'legacy-company','email'=>'legacy@fixture.invalid','service_limit'=>1]);
    parse_str(parse_url($link,PHP_URL_QUERY),$params);$app->accept($params['invite'],'Legacy synthetic 2026!');
    $tenant=$db->query("select * from v_pbx_tenants where slug='legacy-company'")->fetch(PDO::FETCH_ASSOC);
    $_SESSION=['authorized'=>true,'user_uuid'=>$tenant['owner_user_uuid'],'domain_uuid'=>$tenant['home_domain_uuid'],'user'=>['domain_uuid'=>$tenant['home_domain_uuid']],
        'permissions'=>['pbx_template_manage'=>true,'pbx_service_create'=>true]];
    $app=new pbx_tenants($db);echo json_encode(['templates'=>array_column($app->templates(),'template_uuid')],JSON_THROW_ON_ERROR)."\n";return;
}
if (($argv[1] ?? '') !== 'setup') return;
$db->exec("create table v_domains(domain_uuid uuid primary key,domain_name text unique,domain_description text,domain_enabled text);
create table v_users(user_uuid uuid primary key,domain_uuid uuid,username text unique,user_email text,password text,user_enabled text,user_type text);
create table v_groups(group_uuid uuid primary key,domain_uuid uuid,group_name text,group_level int,group_description text,group_protected text);
create table v_user_groups(user_group_uuid uuid primary key,domain_uuid uuid,user_uuid uuid,group_uuid uuid,group_name text);
create table v_permissions(permission_uuid uuid primary key,permission_name text,application_name text,application_uuid uuid,permission_description text);
create table v_group_permissions(group_permission_uuid uuid primary key,group_uuid uuid,group_name text,permission_name text,permission_assigned text,domain_uuid uuid);
create table v_menus(menu_uuid uuid primary key,menu_name text);
create table v_menu_items(menu_item_uuid uuid primary key,menu_uuid uuid,menu_item_title text,menu_item_link text,menu_item_category text,menu_item_order int,menu_item_icon text);
create table v_menu_languages(menu_language_uuid uuid primary key,menu_uuid uuid,menu_item_uuid uuid,menu_language text,menu_item_title text);
create table v_menu_item_groups(menu_item_group_uuid uuid primary key,menu_uuid uuid,menu_item_uuid uuid,group_uuid uuid,group_name text);
create table v_default_settings(default_setting_uuid uuid primary key,default_setting_category text,default_setting_subcategory text,default_setting_value text,default_setting_enabled text);
create table v_domain_settings(domain_setting_uuid uuid primary key,domain_uuid uuid,domain_setting_category text,domain_setting_subcategory text,domain_setting_name text,domain_setting_value text,domain_setting_enabled text,domain_setting_order int);
create table v_dialplans(dialplan_uuid uuid primary key,domain_uuid uuid,app_uuid uuid,dialplan_name text,dialplan_number text,dialplan_context text,dialplan_order text,dialplan_continue text,dialplan_enabled text,dialplan_xml text,dialplan_description text);
create table v_dialplan_details(dialplan_detail_uuid uuid primary key,domain_uuid uuid,dialplan_uuid uuid,dialplan_detail_tag text,dialplan_detail_type text,dialplan_detail_data text,dialplan_detail_order int,dialplan_detail_group int,dialplan_detail_enabled text);
create table v_extensions(extension_uuid uuid primary key,domain_uuid uuid,extension text,number_alias text,password text,accountcode text,user_context text,dial_domain text,effective_caller_id_name text,effective_caller_id_number text,outbound_caller_id_name text,outbound_caller_id_number text,enabled text,directory_visible text,directory_exten_visible text,call_timeout text,max_registrations text,limit_max text,limit_destination text,extension_type text,description text);
create table v_voicemails(voicemail_uuid uuid primary key,domain_uuid uuid,voicemail_id text,voicemail_password text,voicemail_enabled text,voicemail_tutorial text,voicemail_file text,voicemail_local_after_email text);
create table v_gateways(gateway_uuid uuid primary key,domain_uuid uuid,gateway text,proxy text,username text,password text,register_transport text,register text,enabled text,context text,profile text,expire_seconds text,retry_seconds text,description text);
create table v_email_queue(email_queue_uuid uuid primary key,domain_uuid uuid,hostname text,email_date timestamptz,email_from text,email_to text,email_subject text,email_body text,email_status text);
create table v_pbx_restore(domain_uuid uuid primary key,source_version text,config jsonb,report jsonb,restored_at timestamptz default now());");
$db->exec(file_get_contents(PROJECT_ROOT.'/app/tenant_services/resources/install.sql'));
$db->exec(file_get_contents(PROJECT_ROOT.'/app/pbx_tenant_domains/resources/install.sql'));
$db->exec(file_get_contents(PROJECT_ROOT.'/app/tenant_api/resources/install.sql'));
$platform = uuid(); $owner = uuid(); $q = static function(string $sql,array $p=[])use($db): PDOStatement {$s=$db->prepare($sql);$s->execute($p);return $s;};
$q("insert into v_domains values(?,'server.example.test','Synthetic platform','true')",[$platform]);
$q("insert into v_users values(?,?,'platform@fixture.invalid','platform@fixture.invalid',?,'true','default')",[$owner,$platform,password_hash('Fixture platform only 2026!',PASSWORD_DEFAULT)]);
$q("insert into v_dialplans(dialplan_uuid,domain_uuid,app_uuid,dialplan_name,dialplan_context,dialplan_order,dialplan_continue,dialplan_enabled,dialplan_xml)values(?,?,'9f356fe7-8cf8-4c14-8fe2-6daf89304458','domain-variables','server.example.test','20','true','true','<extension name=\"domain-variables\"/>')",[uuid(),$platform]);
$groups = [];
foreach (['tenant_admin','superadmin'] as $name) {
    $id=$q('select group_uuid from v_groups where group_name=? and domain_uuid is null',[$name])->fetchColumn();
    if (!$id) {$id=uuid();$q('insert into v_groups(group_uuid,group_name,group_level)values(?,?,40)',[$id,$name]);}
    $groups[$name]=$id;
}
foreach (['pbx_service_create','pbx_template_manage'] as $permission) $q("insert into v_group_permissions(group_permission_uuid,group_uuid,group_name,permission_name,permission_assigned)values(?,?,'tenant_admin',?,'true')",[uuid(),$groups['tenant_admin'],$permission]);
$_SESSION = ['user_uuid'=>$owner,'domain_uuid'=>$platform,'user'=>['domain_uuid'=>$platform],
    'permissions'=>['pbx_tenant_manage'=>true,'pbx_template_manage'=>true,'pbx_service_create'=>true]];
$app = new pbx_tenants($db);
$basic = ['timezone'=>'Africa/Johannesburg','extension_start'=>100,'extension_count'=>2,'extension_limit'=>5,'trunks'=>[],'rules'=>[],'settings'=>[]];
$safe = $app->saveTemplate(['template_name'=>'Safe Office','published'=>true,'config'=>$basic]);
$notOpted = $app->saveTemplate(['template_name'=>'Legacy administrator template','published'=>true,'config'=>$basic]);
$withSecret = $basic; $withSecret['trunks'] = [['name'=>'Not for public use','proxy'=>'sip.fixture.invalid','username'=>'shared-provider','password'=>'SHARED_PROVIDER_MUST_NOT_LEAK','transport'=>'udp','register'=>true,'enabled'=>true]];
$unsafe = $app->saveTemplate(['template_name'=>'Private carrier credentials','published'=>true,'config'=>$withSecret]);
$q('update v_pbx_templates set api_enabled=true where template_uuid in(?,?)',[$safe,$unsafe]);
echo json_encode(['safe_template'=>$safe,'unsafe_template'=>$unsafe,'not_opted_template'=>$notOpted,'platform_domain'=>$platform,'platform_user'=>$owner],JSON_THROW_ON_ERROR)."\n";
