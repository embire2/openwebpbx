<?php
/** Explicitly bounded staff access, including when a platform owner chooses a limited key. */
class pbx_api_staff_access extends pbx_staff_access {public function owner(): bool {return false;}}
class pbx_api_personal_access extends pbx_api_staff_access {
    public function can(string $cap,?array $c=null): bool {return in_array($cap,['live','control'],true)?$this->active():parent::can($cap,$c);}
    public function permits(string $cap,string $number,?array $c=null,bool $all=false): bool {return in_array($cap,['live','control'],true)?($number!==''&&$number===$this->ownNumber($c)):parent::permits($cap,$number,$c,$all);}
}
class pbx_account_api {
    public const ROUTES=[
        '/me'=>['GET','me:read','Read your extension, profile and current role'],
        '/me/directory'=>['GET','me:read','Read the directory visible to your extension'],
        '/me/availability'=>['GET','me:read','Read your status and queue memberships'],
        '/me/status'=>['POST','me:write','Set your status and optional duration'],
        '/me/queues'=>['POST','me:write','Join or leave a queue you belong to'],
        '/me/calls'=>['GET','me:read','Read your recent call history'],
        '/me/live'=>['GET','me:read','Read only live calls involving your extension'],
        '/me/call-control'=>['POST','me:calls','Hold, resume, transfer, park or end your own call'],
        '/me/voicemail'=>['GET','me:read','Read your voicemail mailbox'],
        '/me/voicemail/{id}/audio'=>['GET','me:read','Download your own voicemail audio'],
        '/me/voicemail/{id}/read'=>['POST','me:write','Mark your voicemail message read'],
        '/me/voicemail/{id}'=>['DELETE','me:write','Delete your own voicemail with confirmation'],
        '/me/phone-qr'=>['POST','me:credentials','Read your stable QR setup without rotating it'],
        '/me/phone-qr-reset'=>['POST','me:credentials','Explicitly replace your own QR setup'],
        '/me/app-password'=>['POST','me:write','Change your app password using your current password'],
        '/me/devices'=>['GET','me:read','List your own registered app profiles'],
        '/me/devices/{id}'=>['DELETE','me:write','Revoke one of your own app profiles'],
        '/me/contacts'=>['GET','me:read','Read company and your personal contacts'],
        '/me/contacts/{id}'=>['POST','me:write','Edit one of your personal contacts'],
        '/me/contacts/{id}/delete'=>['POST','me:write','Delete one of your personal contacts'],
        '/me/contacts/create'=>['POST','me:write','Create a personal contact'],
        '/me/speed-dials'=>['GET','me:read','List your linked callback accounts and speed dials'],
        '/me/speed-dials/{id}'=>['POST','me:write','Save the nine slots of your own linked callback account'],
        '/me/meetings'=>['GET','me:read','List conferences created by your own web account'],
        '/me/meetings/create'=>['POST','me:write','Create an audio/video conference'],
        '/me/meetings/{id}/invite'=>['POST','me:credentials','Replace your own conference invitation'],
        '/me/meetings/{id}/host'=>['POST','me:credentials','Join your own conference as host'],
        '/me/meetings/{id}/cancel'=>['POST','me:write','Cancel your own conference'],
        '/staff/overview'=>['GET','staff:read','Read a department-filtered PBX configuration'],
        '/staff/history'=>['GET','staff:read','Read call history allowed by your current department role'],
        '/staff/media'=>['GET','staff:read','List permitted recordings or voicemail'],
        '/staff/audio/{id}'=>['GET','staff:read','Download permitted department audio'],
        '/staff/live'=>['GET','staff:read','Read live calls allowed by your current department role'],
        '/staff/call-control'=>['POST','staff:calls','Control a call in your permitted departments'],
        '/staff/agent'=>['POST','staff:calls','Manage queue availability within your department permissions'],
        '/staff/queue-report'=>['GET','staff:read','Read department queue reports'],
        '/staff/queue-rules'=>['POST','staff:write','Save permitted queue rules'],
        '/staff/hours-override'=>['POST','staff:write','Temporarily open or close an allowed department'],
        '/staff/roles'=>['GET','staff:read','List staff assignments you may manage'],
        '/staff/roles/grant'=>['POST','staff:write','Delegate an allowed department role'],
        '/staff/roles/{id}/renew'=>['POST','staff:write','Renew a permitted staff invitation'],
        '/staff/roles/{id}/revoke'=>['POST','staff:write','Revoke a permitted staff assignment'],
    ];
    public function __construct(private PDO $db,private array $key) {}
    private function need(string $scope): void {if(!in_array($scope,$this->key['scopes'],true))throw new pbx_api_access_denied('This key does not allow this operation.');}
    private function q(string $sql,array $in=[]): PDOStatement {$s=$this->db->prepare($sql);$s->execute($in);return $s;}
    private function confirmed(array $in,string $field): void {if(($in[$field]??false)!==true)throw new InvalidArgumentException('Explicit confirmation is required.');}
    public static function route(string $route): ?array {
        foreach(self::ROUTES as $path=>$definition){$pattern='~^'.str_replace('\\{id\\}','([^/]+)',preg_quote($path,'~')).'$~D';if(preg_match($pattern,$route,$m))return [$definition,$m[1]??''];}return null;
    }
    private function audio(array $a): pbx_api_file {
        if(isset($a['file'])){if(is_link($a['file']))throw new OutOfBoundsException('Audio unavailable.');$h=fopen($a['file'],'rb');}
        else{$h=fopen('php://temp/maxmemory:1048576','w+b');fwrite($h,$a['data']);rewind($h);}
        if(!$h)throw new OutOfBoundsException('Audio unavailable.');$stat=fstat($h);return new pbx_api_file(['handle'=>$h,'size'=>$stat['size'],'filename'=>'openweb-audio.wav'],$a['type']??'audio/wav');
    }
    public function handle(string $method,string $route,array $in): mixed {
        if(!$this->key['domain_uuid']||$this->key['domain_uuid']!==$_SESSION['domain_uuid']||$this->key['owner_user_uuid']!==$_SESSION['user_uuid'])throw new pbx_api_access_denied('Use your own account key.');
        $access=new pbx_api_staff_access($this->db);if(!$access->active())throw new pbx_api_access_denied('Your staff access has been withdrawn.');
        $match=self::route($route);$id='';
        if($match){[[$expected,$scope],$id]=$match;if($method!==$expected)throw new InvalidArgumentException('Use '.$expected.' for this endpoint.');$this->need($scope);}
        elseif(preg_match('~^/staff/(users|queues|ring-groups|receptionists|trunks|office-hours)(?:/([^/]+))?$~D',$route,$m)){
            $this->need($method==='GET'?'staff:read':'staff:write');$admin=new pbx_admin($this->db,$access);[$collection,$type]=pbx_reseller_api::RESOURCES[$m[1]];$id=$m[2]??'';
            if($method==='GET'){$c=$this->staffConfig($access,$admin);$rows=$c[$collection]??[];if($id==='')return $rows;foreach($rows as $k=>$r)if((string)($r['number']??$k)===$id)return $r;throw new OutOfBoundsException('Item unavailable.');}
            if($method==='POST')return ['id'=>$admin->save($type,$id?:'new',$in),'message'=>$admin->saveNotice()];
            if($method==='DELETE'){$this->confirmed($in,'confirm_delete');if($id===''||$id===$access->ownNumber())throw new pbx_api_access_denied('This item cannot be deleted.');$admin->delete($type,$id);return ['deleted'=>true];}
            throw new InvalidArgumentException('Unsupported method.');
        }else throw new OutOfBoundsException('Account endpoint unavailable.');
        if(str_starts_with($route,'/staff/'))return $this->staff($route,$id,$in,$access);
        // The extension comes exclusively from the live staff binding, never from caller input.
        $number=$access->ownNumber();$mobile=new pbx_mobile($this->db);$e=$mobile->adminExtension($number);
        foreach(['domain_uuid','extension_uuid','owner_user_uuid','user_uuid'] as $field)if(isset($in[$field]))throw new InvalidArgumentException('Personal endpoints derive identity from the key.');
        if($route==='/me')return ['number'=>$number,'name'=>$e['user']['name'],'domain_uuid'=>$e['domain_uuid'],'roles'=>array_column($access->grants(),'role'),'availability'=>(new pbx_mobile_state($this->db))->read($e)];
        if($route==='/me/directory')return $mobile->directory($e);
        if($route==='/me/availability')return (new pbx_mobile_state($this->db))->read($e);
        if($route==='/me/status')return (new pbx_mobile_state($this->db))->status($e,$in);
        if($route==='/me/queues')return (new pbx_mobile_state($this->db))->queue($e,$in);
        if($route==='/me/calls')return $this->q('select owner_number,party_number,party_name,call_type,start_time,end_time,end_status from v_pbx_call_history where domain_uuid=? and owner_number=? order by start_time desc nulls last limit 100 offset '.($this->page($in)*100),[$e['domain_uuid'],$number])->fetchAll(PDO::FETCH_ASSOC);
        if($route==='/me/live')return (new pbx_core($this->db,new pbx_api_personal_access($this->db)))->live();
        if($route==='/me/call-control')return ['message'=>(new pbx_core($this->db,new pbx_api_personal_access($this->db)))->control($in)];
        if($route==='/me/voicemail')return $mobile->voicemail($e);
        if(preg_match('~^/me/voicemail/[^/]+/audio$~D',$route))return $this->audio($mobile->voicemailAudio($e,$id));
        if(preg_match('~^/me/voicemail/[^/]+/read$~D',$route))return $mobile->voicemailRead($e,$id);
        if(preg_match('~^/me/voicemail/[^/]+$~D',$route)){$this->confirmed($in,'confirm_delete');return $mobile->voicemailDelete($e,$id);}
        if($route==='/me/phone-qr')return $mobile->personalCode($e);
        if($route==='/me/phone-qr-reset'){$this->need('me:write');$this->confirmed($in,'confirmed');return $mobile->personalResetCode($e);}
        if($route==='/me/app-password')return $mobile->changePassword($e,$in);
        if($route==='/me/devices')return $mobile->devices($number);
        if(str_starts_with($route,'/me/devices/')){$this->confirmed($in,'confirm_revoke');$mobile->adminRevoke($number,$id);return ['revoked'=>true];}
        if($route==='/me/contacts')return (new pbx_contacts($this->db,$number))->listing();
        if(str_starts_with($route,'/me/contacts/'))return (new pbx_contacts($this->db,$number))->save($route==='/me/contacts/create'?'':$id,$in,str_ends_with($route,'/delete'));
        if($route==='/me/speed-dials'){$dials=new pbx_cmb_speed_dials($this->db);$rows=$dials->accounts();foreach($rows as &$row)$row['slots']=$dials->slots($row['account_uuid']);return $rows;}
        if(str_starts_with($route,'/me/speed-dials/')){(new pbx_cmb_speed_dials($this->db))->save($id,$in);return ['saved'=>true];}
        if($route==='/me/meetings')return $this->q('select meeting_uuid,subject,notes,starts_at,ends_at,dial_number,video_enabled,lobby_required,locked,ended_at from v_pbx_meetings where domain_uuid=? and owner_uuid=? order by starts_at desc limit 100',[$e['domain_uuid'],$this->key['owner_user_uuid']])->fetchAll(PDO::FETCH_ASSOC);
        if($route==='/me/meetings/create')return (new pbx_meet($this->db))->create($in);
        if(str_starts_with($route,'/me/meetings/')){
            if(!is_uuid($id)||!$this->q('select 1 from v_pbx_meetings where meeting_uuid=? and domain_uuid=? and owner_uuid=?',[$id,$e['domain_uuid'],$this->key['owner_user_uuid']])->fetchColumn())throw new OutOfBoundsException('Meeting unavailable.');
            $meet=new pbx_meet($this->db);if(str_ends_with($route,'/invite')){$this->need('me:write');return $meet->invite($id);}if(str_ends_with($route,'/host'))return $meet->host($id);$this->confirmed($in,'confirmed');$meet->cancel($id);return ['cancelled'=>true];
        }
        throw new OutOfBoundsException('Account endpoint unavailable.');
    }
    private function page(array $in): int {$p=$in['page']??0;if(is_bool($p)||filter_var($p,FILTER_VALIDATE_INT,['options'=>['min_range'=>0,'max_range'=>10000]])===false)throw new InvalidArgumentException('Choose a page.');return (int)$p;}
    private function days(array $in): int {$d=$in['days']??7;if(is_bool($d)||filter_var($d,FILTER_VALIDATE_INT,['options'=>['min_range'=>1,'max_range'=>90]])===false)throw new InvalidArgumentException('Choose between 1 and 90 days.');return (int)$d;}
    private function staffConfig(pbx_staff_access $a,pbx_admin $admin): array {
        $full=$admin->config();$c=pbx_reseller_api::publicConfig($a->filtered($full));
        foreach($c['users']??[] as $number=>$user)if((string)$number!==$a->ownNumber($full)&&!$a->permits('users',(string)$number,$full))$c['users'][$number]=array_intersect_key($user,array_flip(['number','name','enabled','status','profile']));
        return $c;
    }
    private function staff(string $route,string $id,array $in,pbx_staff_access $a): mixed {
        $admin=new pbx_admin($this->db,$a);
        return match($route){
            '/staff/overview'=>$this->staffConfig($a,$admin),
            '/staff/history'=>$admin->history($this->page($in)),
            '/staff/media'=>pbx_reseller_api::publicData($admin->media((string)($in['category']??'recordings'),$this->page($in))),
            '/staff/live'=>(new pbx_core($this->db,$a))->live(),
            '/staff/call-control'=>['message'=>(new pbx_core($this->db,$a))->control($in)],
            '/staff/agent'=>['message'=>(new pbx_core($this->db,$a))->agent($in)],
            '/staff/queue-report'=>(new pbx_core($this->db,$a))->queueReport($this->days($in)),
            '/staff/queue-rules'=>(function()use($a,$in){(new pbx_core($this->db,$a))->saveRules($in);return ['saved'=>true];})(),
            '/staff/hours-override'=>(function()use($a,$in){$a->overrideHours($in);return ['saved'=>true];})(),
            '/staff/roles'=>$a->staff(),
            '/staff/roles/grant'=>(new pbx_staff_accounts($this->db,$a))->grant($in),
            default=>$this->staffItem($route,$id,$in,$a,$admin),
        };
    }
    private function staffItem(string $route,string $id,array $in,pbx_staff_access $a,pbx_admin $admin): mixed {
        if(str_starts_with($route,'/staff/audio/'))return $this->audio(['file'=>$admin->mediaFile($id)['file_path'],'type'=>'audio/wav']);
        $accounts=new pbx_staff_accounts($this->db,$a);
        if(str_ends_with($route,'/renew'))return $accounts->renew($id,($in['email_invitation']??false)===true);
        if(str_ends_with($route,'/revoke')){$accounts->revoke($id);return ['revoked'=>true];}
        throw new OutOfBoundsException('Account endpoint unavailable.');
    }
}
