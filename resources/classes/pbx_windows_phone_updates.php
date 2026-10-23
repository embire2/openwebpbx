<?php
/** Windows Phone policy only. Server Windows and Android policies remain separate. */
class pbx_windows_phone_updates {
    public const COMPONENT='windows-free-phone';
    public const FEED_URL='https://github.com/embire2/openwebpbx/releases/download/windows-phone-stable/windows-phone-update-manifest.json';
    public const FORM='/app/pbx_updates/windows_phone.php';
    private PDO $db;
    private pbx_updates $authorization;
    public function __construct(?PDO $db=null,?pbx_updates $authorization=null){$this->db=$db??database::new()->db;$this->authorization=$authorization??new pbx_updates($this->db);}
    private function q(string $sql,array $params=[]):PDOStatement{$s=$this->db->prepare($sql);foreach($params as$k=>$v)$s->bindValue(':'.$k,$v,$v===null?PDO::PARAM_NULL:PDO::PARAM_STR);$s->execute();return$s;}
    public function canView():bool{return $this->authorization->canView();}
    public function instanceAdmin():bool{return $this->authorization->instanceAdmin();}
    public function tenants():array{return $this->authorization->tenants();}
    private function access(bool $instance=false):void{if(!$this->canView()||($instance&&!$this->instanceAdmin()))throw new DomainException('Windows phone update administrator access is required.');}
    private function tenant(string $tenant):void{
        $this->access();if(!is_uuid($tenant))throw new InvalidArgumentException('Choose a tenant.');
        if(!in_array($tenant,array_column($this->tenants(),'tenant_uuid'),true))throw new DomainException('Windows phone settings are outside your tenant permissions.');
    }
    private function policy(string $scope):array{return $this->q('select mode,minimum_version,updated_at from v_pbx_windows_phone_policies where scope_key=:s',['s'=>$scope])->fetch(PDO::FETCH_ASSOC)?:['mode'=>'notify','minimum_version'=>'','updated_at'=>null];}
    /** Only accepted signed metadata can activate a release; an API call never fetches it. */
    protected function publishedVersion():string{return(new pbx_windows_phone_catalogue)->publishedVersion();}
    private function release():string{
        $value=$this->publishedVersion();if($value!==''&&!self::versionValid($value))throw new RuntimeException('The Windows phone release metadata is unavailable.');return$value;
    }
    private static function versionValid(mixed $value):bool{
        if(!is_string($value)||!preg_match('/^(0|[1-9][0-9]{0,4})\.(0|[1-9][0-9]{0,4})\.(0|[1-9][0-9]{0,4})$/D',$value))return false;
        foreach(explode('.',$value)as$part)if((int)$part>65535)return false;return true;
    }
    public function instancePolicy():array{$this->access(true);$latest=$this->release();return $this->policy('instance')+['component'=>self::COMPONENT,'feed_url'=>self::FEED_URL,'latest_version'=>$latest,'release_available'=>$latest!==''];}
    public function tenantPolicy(string $tenant):array{$this->tenant($tenant);return$this->policy('tenant:'.$tenant);}
    public function saveTenant(string $tenant,array $input):void{
        $this->tenant($tenant);$mode=$input['mode']??null;if(!is_string($mode)||!in_array($mode,['notify','download','required'],true))throw new InvalidArgumentException('Choose a Windows phone update option.');
        $this->q("insert into v_pbx_windows_phone_policies(scope_key,mode,updated_by) values(:s,:m,:u) on conflict(scope_key) do update set mode=excluded.mode,updated_by=excluded.updated_by,updated_at=now()",['s'=>'tenant:'.$tenant,'m'=>$mode,'u'=>$_SESSION['user_uuid']]);
    }
    public function saveInstance(array $input):void{
        $this->access(true);$minimum=$input['minimum_version']??null;$latest=$this->release();
        if(!is_string($minimum)||($minimum!==''&&(!self::versionValid($minimum)||$latest===''||version_compare($minimum,$latest,'>'))))throw new InvalidArgumentException('Choose a verified published Windows phone release, or clear the requirement.');
        $this->q("update v_pbx_windows_phone_policies set minimum_version=:v,updated_by=:u,updated_at=now() where scope_key='instance'",['v'=>$minimum,'u'=>$_SESSION['user_uuid']]);
    }
    public function saveBrowserRequest(string $tenant,array $input):void{
        $this->access();if(!isset($_SESSION['tokens'][self::FORM])||!(new token)->validate(self::FORM))throw new DomainException('Your form expired. Refresh this page.');
        if(($input['action']??null)==='save_tenant'){$this->saveTenant($tenant,$input);return;}
        if(($input['action']??null)==='save_instance'){$this->saveInstance($input);return;}
        throw new InvalidArgumentException('Choose a Windows phone update action.');
    }
    public function phonePolicy(array $account):array{
        if(($account['platform']??null)!=='windows')throw new InvalidArgumentException('Use this policy only with the Windows phone app.');
        $domain=$account['domain_uuid']??null;if(!is_string($domain)||!is_uuid($domain)||!$this->q("select 1 from v_domains where domain_uuid=:d and domain_enabled='true'",['d'=>$domain])->fetchColumn())throw new UnexpectedValueException('This phone is no longer connected.');
        $owners=$this->q('select s.tenant_uuid,t.enabled from v_pbx_services s join v_pbx_tenants t using(tenant_uuid) where s.domain_uuid=:d',['d'=>$domain])->fetchAll(PDO::FETCH_ASSOC);
        if(count($owners)>1||(count($owners)===1&&!filter_var($owners[0]['enabled'],FILTER_VALIDATE_BOOLEAN)))throw new UnexpectedValueException('This phone is no longer connected.');
        $tenantMode=count($owners)===1?$this->policy('tenant:'.$owners[0]['tenant_uuid'])['mode']:'notify';$latest=$this->release();$minimum=$latest!==''?$this->policy('instance')['minimum_version']:'';
        if($minimum!==''&&(!self::versionValid($minimum)||version_compare($minimum,$latest,'>')))throw new RuntimeException('The Windows phone release requirement needs administrator review.');
        return ['schema'=>1,'component'=>self::COMPONENT,'channel'=>'stable','mode'=>$minimum!==''?'required':$tenantMode,'tenant_mode'=>$tenantMode,'required_by_instance'=>$minimum!=='','minimum_version'=>$minimum,'latest_version'=>$latest,'feed_url'=>self::FEED_URL,'release_available'=>$latest!==''];
    }
}
