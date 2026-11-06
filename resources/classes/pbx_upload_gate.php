<?php
/** Body-free, read-only nginx auth_request admission for large encrypted uploads. */
class pbx_upload_gate_denied extends RuntimeException {
    public function __construct(public int $status=403){parent::__construct('Upload admission refused.');}
}
class pbx_upload_gate {
    private PDO $db;
    public function __construct(?PDO $db=null){$this->db=$db??database::new()->db;}
    protected function available(): float|false {$root=pbx_paths::state().'/protection-inbox';return is_dir($root)&&!is_link($root)?disk_free_space($root):false;}
    public static function request(array $server): array {
        if(($server['OPENWEB_UPLOAD_GATE']??null)!=='1')throw new pbx_upload_gate_denied(404);
        if(($server['OPENWEB_UPLOAD_METHOD']??null)!=='POST')throw new pbx_upload_gate_denied;
        $uri=$server['OPENWEB_UPLOAD_URI']??null;
        if(!is_string($uri)||strlen($uri)>512||preg_match('/[\x00-\x20\x7f%\\\\]/',$uri))throw new pbx_upload_gate_denied;
        if(preg_match('~^/api/v2/(instance/backups/import|tenants/([a-f0-9-]+)/backups/import)$~D',$uri,$m))return ['api'=>true,'route'=>'/'.$m[1],'tenant'=>$m[2]??''];
        if(preg_match('~^/app/pbx_protection/upload.php(?:\?tenant=([a-f0-9-]*))?$~D',$uri,$m))return ['api'=>false,'route'=>'','tenant'=>$m[1]??''];
        throw new pbx_upload_gate_denied;
    }
    public function authorize(array $server): void {
        $request=self::request($server);
        if(!in_array($server['HTTPS']??'',['on','1'],true))throw new pbx_upload_gate_denied;
        if($request['api']) {
            $authorization=$server['HTTP_AUTHORIZATION']??'';if(!is_string($authorization)||$authorization==='')throw new pbx_upload_gate_denied(401);
            if(isset($server['HTTP_ORIGIN']))throw new pbx_upload_gate_denied;
            $host=strtolower((string)($server['HTTP_HOST']??''));if(str_ends_with($host,':443'))$host=substr($host,0,-4);
            if($host!==(string)config::load()->get('openweb.public_host','call.openweb.co.za'))throw new pbx_upload_gate_denied;
            (new pbx_reseller_api($this->db))->authorizeBackupUpload($request['route'],$authorization,(string)($server['REMOTE_ADDR']??''));
        }else{
            if(empty($_SESSION['authorized'])||!is_uuid($_SESSION['user_uuid']??''))throw new pbx_upload_gate_denied(401);
            if(!pbx_protection::uploadToken($server['HTTP_X_OPENWEB_TOKEN_NAME']??'',$server['HTTP_X_OPENWEB_TOKEN']??'',false))throw new pbx_upload_gate_denied;
            $p=new pbx_protection($this->db);$allowed=false;
            if($request['tenant']==='')$allowed=$p->instance();else foreach($p->tenants() as $tenant)if($tenant['tenant_uuid']===$request['tenant']){$allowed=true;break;}
            if(!$allowed)throw new pbx_upload_gate_denied;
        }
        if(($server['CONTENT_TYPE']??$server['HTTP_CONTENT_TYPE']??'')!=='application/octet-stream')throw new pbx_upload_gate_denied;
        $length=$server['OPENWEB_UPLOAD_LENGTH']??null;if(!is_string($length)||!preg_match('/^[0-9]{1,10}$/D',$length))throw new pbx_upload_gate_denied;
        $size=(int)$length;if($size<52||$size>2147483648)throw new pbx_upload_gate_denied;
        $encoded=$server['HTTP_X_BACKUP_PASSWORD']??'';$password=is_string($encoded)&&strlen($encoded)<=344?base64_decode($encoded,true):false;
        if(!is_string($password)||base64_encode($password)!==$encoded||strlen($password)<12||strlen($password)>256||preg_match('/[\x00-\x1f]/',$password))throw new pbx_upload_gate_denied;
        $free=$this->available();if($free===false||$free<10737418240+2*$size)throw new pbx_upload_gate_denied;
    }
}
