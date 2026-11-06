<?php
/** Encrypted tenant recovery and explicitly confirmed whole-instance recovery. */
class pbx_protection {
    /** Binary requests carry the ordinary form token in headers, not $_REQUEST. */
    public static function uploadToken(string $name,string $hash,bool $consume=false): bool {
        if(!preg_match('/^[a-f0-9]{64}$/D',$name)||!preg_match('/^[a-f0-9]{64}$/D',$hash))return false;
        $path='/app/pbx_protection/index.php';
        foreach($_SESSION['tokens'][$path]??[] as $i=>$token){
            if(!is_array($token)||!is_string($token['name']??null)||!is_string($token['hash']??null))continue;
            if(hash_equals($token['name'],$name)&&hash_equals($token['hash'],$hash)){
                if($consume)$_SESSION['tokens'][$path][$i]['validated']=true;
                return true;
            }
        }
        return false;
    }
    private PDO $db;
    public function __construct(?PDO $db=null){$this->db=$db??database::new()->db;}
    private function q(string $sql,array $p=[]): PDOStatement {$s=$this->db->prepare($sql);$s->execute($p);return $s;}
    private function actor(): string {$u=$_SESSION['user_uuid']??'';if(empty($_SESSION['authorized'])||!is_uuid($u)||!$this->q("select 1 from v_users where user_uuid=? and user_enabled='true'",[$u])->fetchColumn())throw new DomainException('Administrator sign-in is required.');return $u;}
    private function granted(string $permission): bool {return (bool)$this->q("select 1 from v_users actor join v_user_groups u on u.user_uuid=actor.user_uuid join v_group_permissions p using(group_uuid) where actor.user_uuid=? and p.permission_name=? and p.permission_assigned='true' and (u.domain_uuid is null or u.domain_uuid=actor.domain_uuid) and (p.domain_uuid is null or p.domain_uuid=actor.domain_uuid)",[$this->actor(),$permission])->fetchColumn();}
    public function instance(): bool {return $this->granted('pbx_backup_instance');}
    private function reseller(): bool {return $this->granted('pbx_reseller_manage')&&(bool)$this->q('select 1 from v_pbx_tenants where owner_user_uuid=? and enabled',[$this->actor()])->fetchColumn();}
    public function tenants(): array {
        $actor=$this->actor();if(!$this->granted('pbx_tenant_backup')&&!$this->instance())throw new DomainException('Backup permission is required.');
        $instance=$this->instance();$reseller=$this->reseller();
        return $this->q('select tenant_uuid,tenant_name,home_domain_uuid from v_pbx_tenants where enabled'.($instance?'':($reseller?' and (owner_user_uuid=? or reseller_user_uuid=?)':' and owner_user_uuid=?')).' order by tenant_name',$instance?[]:($reseller?[$actor,$actor]:[$actor]))->fetchAll(PDO::FETCH_ASSOC);
    }
    private function tenant(string $id): array {if(!is_uuid($id))throw new InvalidArgumentException('Choose a tenant.');foreach($this->tenants() as $t)if($t['tenant_uuid']===$id)return $t;throw new DomainException('This tenant is unavailable.');}
    private function seal(string $password): string {
        $key=@file_get_contents(pbx_paths::key());if(!is_string($key)||strlen($key)!==32)throw new RuntimeException('Private backup encryption is not configured.');
        $nonce=random_bytes(12);$tag='';$cipher=openssl_encrypt($password,'aes-256-gcm',hash('sha256',$key.'/openwebpbx/backups/v1',true),OPENSSL_RAW_DATA,$nonce,$tag,'openwebpbx-backup-settings-v1');
        if(!is_string($cipher))throw new RuntimeException('Private backup encryption is unavailable.');return 'v1:'.base64_encode($nonce.$tag.$cipher);
    }
    public function status(string $tenant): array {
        if($tenant===''){if(!$this->instance())throw new DomainException('Instance administrator access is required.');$where='tenant_uuid is null';$p=[];$instanceStatus=(new pbx_backups($this->db))->status();$backups=$instanceStatus['backups'];}
        else {$this->tenant($tenant);$where='tenant_uuid=?';$p=[$tenant];$backups=$this->q('select backup_uuid,status,app_version,size_bytes,sha256,media_count,created_at,verified_at,message from v_pbx_tenant_backups where tenant_uuid=? order by created_at desc limit 100',[$tenant])->fetchAll(PDO::FETCH_ASSOC);}
        $jobs=$this->q('select job_uuid,action,backup_uuid,status,message,created_at,finished_at from v_pbx_protection_jobs where '.$where.' order by created_at desc limit 30',$p)->fetchAll(PDO::FETCH_ASSOC);
        if($tenant===''){
            foreach($instanceStatus['recent'] as $j)$jobs[]=['job_uuid'=>$j['command_uuid'],'action'=>'instance_'.$j['action'],'backup_uuid'=>$j['backup_uuid'],'status'=>$j['status'],'message'=>$j['message'],'created_at'=>$j['created_at'],'finished_at'=>$j['finished_at']];
            $root=pbx_paths::state().'/protection-status';$receipts=[];
            foreach(glob($root.'/*.json')?:[] as $path){if(is_link($path)||!pbx_paths::contains($root,$path)||filesize($path)>8192)continue;$r=json_decode((string)@file_get_contents($path),true);if(!is_array($r)||!is_uuid($r['job_uuid']??'')||!in_array($r['action']??'',['instance_verify','instance_restore','instance_import'],true))continue;$receipts[$r['job_uuid']]=array_intersect_key($r,array_flip(['job_uuid','action','backup_uuid','status','message','created_at','finished_at']));}
            foreach($jobs as $j)if(!isset($receipts[$j['job_uuid']]))$receipts[$j['job_uuid']]=$j;
            $jobs=array_values($receipts);usort($jobs,fn($a,$b)=>strcmp($b['created_at']??'',$a['created_at']??''));$jobs=array_slice($jobs,0,30);
        }
        return ['backups'=>$backups,'jobs'=>$jobs];
    }
    public function request(string $action,string $tenant,array $in): string {
        $actor=$this->actor();$instance=str_starts_with($action,'instance_');
        if(!in_array($action,['tenant_create','tenant_verify','tenant_restore','instance_verify','instance_restore'],true))throw new InvalidArgumentException('Choose a backup action.');
        if($instance){if($tenant!==''||!$this->instance())throw new DomainException('Instance administrator access is required.');$tenant=null;$name=pbx_paths::host();}
        else {$t=$this->tenant($tenant);$name=$t['tenant_name'];}
        $password=$in['password']??'';if(!is_string($password)||strlen($password)<12||strlen($password)>256||preg_match('/[\x00-\x1f]/',$password))throw new InvalidArgumentException('Enter the backup password, using 12 to 256 characters. Keep it separately.');
        $backup=$in['backup_uuid']??null;
        if($action==='tenant_create'&&$backup!==null)throw new InvalidArgumentException('A new backup cannot reuse another backup identifier.');
        if($action!=='tenant_create'){
            if(!is_string($backup)||!is_uuid($backup))throw new InvalidArgumentException('Choose a completed backup.');
            $r=$instance?$this->q("select 1 from v_pbx_backups where backup_uuid=? and status='ready'",[$backup])->fetchColumn():$this->q("select 1 from v_pbx_tenant_backups where tenant_uuid=? and backup_uuid=? and status='ready'",[$tenant,$backup])->fetchColumn();
            if(!$r)throw new DomainException('This backup is unavailable in the selected workspace.');
        }
        $request=[];
        if(str_ends_with($action,'_restore')){
            $confirm=$in[$instance?'confirm_server':'confirm_tenant']??null;
            if(!is_string($confirm)||!hash_equals($name,$confirm)||!in_array($in['confirm_replace']??false,[true,1,'1'],true))throw new InvalidArgumentException('Confirm the exact name and accept replacement before restoring.');
            $verify=$instance?'instance_verify':'tenant_verify';
            if(!$this->q("select 1 from v_pbx_protection_jobs where backup_uuid=? and action=? and status='completed' and finished_at>now()-interval '30 minutes' and tenant_uuid is not distinct from ?::uuid",[$backup,$verify,$tenant])->fetchColumn())throw new InvalidArgumentException('Check this backup successfully first, then review and confirm the restore within 30 minutes.');
            $request=['confirmed_name'=>$name,'replace'=>true];
        }
        $this->db->beginTransaction();try {
            $this->q('select pg_advisory_xact_lock(741103125)');
            if($this->q("select 1 from v_pbx_protection_jobs where status in ('pending','running') and (tenant_uuid is null or ?::uuid is null or tenant_uuid=?::uuid)",[$tenant,$tenant])->fetchColumn())throw new OverflowException('Another backup or restore is waiting or running. Wait for it to finish.');
            if((int)$this->q("select count(*) from v_pbx_protection_jobs where requested_by=? and created_at>now()-interval '1 hour'",[$actor])->fetchColumn()>=12)throw new OverflowException('Please wait before requesting another backup operation.');
            $id=uuid();$this->q('insert into v_pbx_protection_jobs(job_uuid,tenant_uuid,requested_by,action,backup_uuid,secret_ciphertext,request) values(?,?,?,?,?,?,?::jsonb)',[$id,$tenant,$actor,$action,$backup,$this->seal($password),json_encode($request,JSON_THROW_ON_ERROR)]);
            $this->db->commit();return $id;
        }catch(Throwable $e){if($this->db->inTransaction())$this->db->rollBack();throw $e;}
    }
    protected function downloadRoot(): string {return pbx_paths::state().'/tenant-backup-downloads';}
    protected function inboxRoot(): string {return pbx_paths::state().'/protection-inbox';}
    public function importStream(string $tenant,mixed $source,int $size,string $password): string {
        $actor=$this->actor();if($tenant===''){if(!$this->instance())throw new DomainException('Instance administrator access is required.');$tenant=null;}else $this->tenant($tenant);
        if(strlen($password)<12||strlen($password)>256||preg_match('/[\x00-\x1f]/',$password))throw new InvalidArgumentException('Enter the original backup password using 12 to 256 characters.');
        if(!is_resource($source)||get_resource_type($source)!=='stream'||$size<52||$size>2147483648)throw new InvalidArgumentException('Upload one encrypted OpenWeb PBX backup, up to 2 GB.');
        $root=$this->inboxRoot();
        if(!is_dir($root)||is_link($root)||disk_free_space($root)<10737418240+2*$size)throw new OverflowException('Not enough protected storage to receive and check this backup while keeping the server safety reserve.');
        if($this->q("select 1 from v_pbx_protection_jobs where status in ('pending','running') and (tenant_uuid is null or ?::uuid is null or tenant_uuid=?::uuid)",[$tenant,$tenant])->fetchColumn())throw new OverflowException('Another backup request is waiting or running. Wait for it to finish.');
        $upload=uuid();$path=$root.'/'.$upload.'.upload';
        $target=@fopen($path,'xb');if($target===false)throw new RuntimeException('The protected upload could not be stored.');chmod($path,0600);
        try {
            $total=0;$hash=hash_init('sha256');$prefix='';
            while(!feof($source)){
                $chunk=fread($source,min(1048576,$size-$total+1));if($chunk===false||($chunk===''&&!feof($source)))throw new RuntimeException('The upload stopped before completion. Retry the upload.');
                $total+=strlen($chunk);if($total>$size)throw new InvalidArgumentException('The upload exceeded its declared size.');
                $prefix.=substr($chunk,0,max(0,8-strlen($prefix)));if(strlen($prefix)===8&&$prefix!=='OWPBXB01')throw new InvalidArgumentException('Choose an encrypted OpenWeb PBX backup.');
                if(disk_free_space($root)<10737418240+strlen($chunk))throw new OverflowException('Storage reached the safety reserve. The upload was cancelled.');
                if(@fwrite($target,$chunk)!==strlen($chunk))throw new RuntimeException('The protected upload could not be written.');hash_update($hash,$chunk);
            }
            fflush($target);if(function_exists('fsync'))fsync($target);fclose($target);$target=null;
            if($total!==$size)throw new InvalidArgumentException('The upload did not match its declared size.');
            $request=['upload_uuid'=>$upload,'size'=>$size,'sha256'=>hash_final($hash)];$id=uuid();
            $this->db->beginTransaction();$this->q('select pg_advisory_xact_lock(741103125)');
            if($this->q("select 1 from v_pbx_protection_jobs where status in ('pending','running') and (tenant_uuid is null or ?::uuid is null or tenant_uuid=?::uuid)",[$tenant,$tenant])->fetchColumn())throw new OverflowException('Another backup request is waiting or running. Wait for it to finish.');
            if((int)$this->q("select count(*) from v_pbx_protection_jobs where requested_by=? and created_at>now()-interval '1 hour'",[$actor])->fetchColumn()>=12)throw new OverflowException('Please wait before requesting another backup operation.');
            $this->q('insert into v_pbx_protection_jobs(job_uuid,tenant_uuid,requested_by,action,secret_ciphertext,request) values(?,?,?,?,?,?::jsonb)',[$id,$tenant,$actor,$tenant===null?'instance_import':'tenant_import',$this->seal($password),json_encode($request,JSON_THROW_ON_ERROR)]);
            $this->db->commit();return $id;
        }catch(Throwable $error){if(is_resource($target))fclose($target);if($this->db->inTransaction())$this->db->rollBack();unlink($path);throw $error;}
    }
    public function download(string $tenant,string $backup): array {
        $this->tenant($tenant);if(!is_uuid($backup))throw new InvalidArgumentException('Choose a backup.');
        $row=$this->q("select filename,size_bytes,sha256 from v_pbx_tenant_backups where tenant_uuid=? and backup_uuid=? and status='ready'",[$tenant,$backup])->fetch(PDO::FETCH_ASSOC);
        $root=$this->downloadRoot();$path=$root.'/'.$backup.'.owtenant';
        if(!$row||$row['filename']!==$backup.'.owtenant'||is_link($path)||!pbx_paths::contains($root,$path)||!is_file($path)||($handle=@fopen($path,'rb'))===false)throw new OutOfBoundsException('Encrypted backup unavailable.');
        $stat=fstat($handle);if(!$stat||($stat['mode']&0170000)!==0100000||$stat['size']!==(int)$row['size_bytes']){fclose($handle);throw new RuntimeException('The backup file changed. Check the backup before downloading.');}
        return ['handle'=>$handle,'size'=>$stat['size'],'filename'=>$row['filename'],'sha256'=>$row['sha256']];
    }
}
