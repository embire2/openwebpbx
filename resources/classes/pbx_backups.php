<?php
/** Instance-only backup settings. The privileged worker owns archive files and restore operations. */
class pbx_backups {
    private PDO $db;
    public function __construct(?PDO $db = null) {
        $this->db = $db ?? database::new()->db;
        $this->db->setAttribute(PDO::ATTR_ERRMODE, PDO::ERRMODE_EXCEPTION);
    }
    private function q(string $sql, array $params = []): PDOStatement {
        $s = $this->db->prepare($sql);
        foreach ($params as $key=>$value) $s->bindValue(':'.$key,$value,is_int($value)?PDO::PARAM_INT:($value===null?PDO::PARAM_NULL:PDO::PARAM_STR));
        $s->execute(); return $s;
    }
    protected function allowed(): bool { return permission_exists('pbx_backup_instance'); }
    protected function keyFile(): string { return pbx_paths::key(); }
    protected function downloadRoot(): string { return pbx_paths::state().'/backup-downloads'; }
    public function canView(): bool {
        $id = $_SESSION['user_uuid'] ?? '';
        return !empty($_SESSION['authorized']) && is_uuid($id) && $this->allowed()
            && (bool)$this->q("select 1 from v_users where user_uuid=:id and user_enabled='true'",['id'=>$id])->fetchColumn();
    }
    private function access(): void { if (!$this->canView()) throw new DomainException('Instance administrator access is required.'); }
    private function seal(string $plain): string {
        $key = @file_get_contents($this->keyFile());
        if (!is_string($key) || strlen($key)!==32) throw new RuntimeException('The private encryption key is unavailable.');
        $nonce = random_bytes(12); $tag = '';
        $cipher = openssl_encrypt($plain,'aes-256-gcm',hash('sha256',$key.'/openwebpbx/backups/v1',true),OPENSSL_RAW_DATA,$nonce,$tag,'openwebpbx-backup-settings-v1');
        if (!is_string($cipher)) throw new RuntimeException('Backup encryption is unavailable.');
        return 'v1:'.base64_encode($nonce.$tag.$cipher);
    }
    private function text(array $input,string $key,int $max): string {
        $value=$input[$key]??'';
        if (!is_string($value) || strlen($value)>$max || preg_match('/[\x00-\x1f\x7f]/',$value)) throw new InvalidArgumentException('Enter a valid '.str_replace('_',' ',$key).'.');
        return $value;
    }
    private function checkbox(array $input,string $key): bool {
        $value=$input[$key]??'0';
        if (!in_array($value,['0','1',0,1,false,true],true)) throw new InvalidArgumentException('Choose a valid backup option.');
        return in_array($value,['1',1,true],true);
    }
    public function settings(): array {
        $this->access();
        $row=$this->q('select enabled,schedule_hour,retention,include_media,sftp_enabled,sftp_host,sftp_port,sftp_user,sftp_directory,sftp_host_key,updated_at,passphrase_secret<>\'\' has_passphrase,sftp_identity_secret<>\'\' has_identity from v_pbx_backup_settings where singleton=1')->fetch(PDO::FETCH_ASSOC);
        if (!$row) throw new RuntimeException('Backup settings are unavailable.');
        foreach(['enabled','include_media','sftp_enabled','has_passphrase','has_identity'] as $field) $row[$field]=filter_var($row[$field],FILTER_VALIDATE_BOOLEAN);
        return $row;
    }
    public function save(array $input): void {
        $this->access();
        $enabled=$this->checkbox($input,'enabled'); $media=$this->checkbox($input,'include_media'); $remote=$this->checkbox($input,'sftp_enabled');
        $hour=filter_var($input['schedule_hour']??null,FILTER_VALIDATE_INT,['options'=>['min_range'=>0,'max_range'=>23]]);
        $retention=filter_var($input['retention']??null,FILTER_VALIDATE_INT,['options'=>['min_range'=>2,'max_range'=>90]]);
        if ($hour===false || $retention===false) throw new InvalidArgumentException('Choose an hour from 0 to 23 and keep 2 to 90 backups.');
        $pass=$this->text($input,'passphrase',256);
        if ($pass!=='' && mb_strlen($pass)<12) throw new InvalidArgumentException('Use a backup password with at least 12 characters. Keep it separately: it is needed to restore.');
        $host=$this->text($input,'sftp_host',253); $user=$this->text($input,'sftp_user',64); $directory=$this->text($input,'sftp_directory',512);
        $hostKey=$this->text($input,'sftp_host_key',4096);
        $port=filter_var($input['sftp_port']??'22',FILTER_VALIDATE_INT,['options'=>['min_range'=>1,'max_range'=>65535]]);
        $identity=$input['sftp_identity']??'';
        if (!is_string($identity) || strlen($identity)>32768 || str_contains($identity,"\0")) throw new InvalidArgumentException('Paste a valid private SSH key.');
        if ($remote) {
            if (!filter_var($host,FILTER_VALIDATE_DOMAIN,FILTER_FLAG_HOSTNAME) || !preg_match('/^[a-zA-Z0-9][a-zA-Z0-9_.-]{0,63}$/D',$user)
                || !preg_match('#^(/[a-zA-Z0-9_.-]+)+/?$#D',$directory) || in_array('..',explode('/',$directory),true) || in_array('.',explode('/',$directory),true) || $port===false)
                throw new InvalidArgumentException('Enter a valid SFTP server, port, user and absolute folder. Folder names can contain letters, numbers, dots, dashes and underscores.');
            if (!preg_match('/^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp256) ([A-Za-z0-9+\/]+={0,2})(?: [^\r\n]*)?$/D',$hostKey,$match)
                || ($decoded=base64_decode($match[2],true))===false || strlen($decoded)<32 || strlen($decoded)>4096)
                throw new InvalidArgumentException('Paste the server’s trusted public SSH host key. Obtain it directly from the server owner.');
            $hostKey=$match[1].' '.$match[2];
            if ($identity!=='' && !preg_match('/\A-----BEGIN (OPENSSH |RSA )?PRIVATE KEY-----\r?\n[\s\S]+\r?\n-----END (OPENSSH |RSA )?PRIVATE KEY-----\s*\z/',$identity))
                throw new InvalidArgumentException('Paste an unencrypted private SSH key. Password authentication is not supported.');
        }
        $this->db->beginTransaction();
        try {
            $old=$this->q('select * from v_pbx_backup_settings where singleton=1 for update')->fetch(PDO::FETCH_ASSOC);
            if (!$old) throw new RuntimeException('Backup settings are unavailable.');
            $passSecret=$pass!==''?$this->seal($pass):$old['passphrase_secret'];
            if ($passSecret==='') throw new InvalidArgumentException('Set a backup password before saving. Keep it somewhere separate from this server.');
            $identitySecret=$identity!==''?$this->seal($identity):$old['sftp_identity_secret'];
            if ($remote && $identitySecret==='') throw new InvalidArgumentException('Paste the private SSH key for the SFTP account.');
            $this->q('update v_pbx_backup_settings set enabled=:enabled,schedule_hour=:hour,retention=:retention,include_media=:media,passphrase_secret=:pass,sftp_enabled=:remote,sftp_host=:host,sftp_port=:port,sftp_user=:user,sftp_directory=:directory,sftp_host_key=:host_key,sftp_identity_secret=:identity,updated_by=:admin,updated_at=now() where singleton=1',
                ['enabled'=>$enabled?'true':'false','hour'=>$hour,'retention'=>$retention,'media'=>$media?'true':'false','pass'=>$passSecret,'remote'=>$remote?'true':'false','host'=>$remote?$host:'','port'=>$port===false?22:$port,'user'=>$remote?$user:'','directory'=>$remote?$directory:'','host_key'=>$remote?$hostKey:'','identity'=>$remote?$identitySecret:'','admin'=>$_SESSION['user_uuid']]);
            $this->db->commit();
        } catch(Throwable $e) { if($this->db->inTransaction())$this->db->rollBack(); throw $e; }
    }
    public function request(string $action,string $backup=''): string {
        $this->access();
        if (!in_array($action,['create','verify'],true)) throw new InvalidArgumentException('Choose a supported backup action.');
        if ($action==='verify' && (!is_uuid($backup) || !$this->q("select 1 from v_pbx_backups where backup_uuid=:id and status='ready'",['id'=>$backup])->fetchColumn())) throw new InvalidArgumentException('Choose an available backup to check.');
        $this->db->beginTransaction();
        try {
            $this->q('select pg_advisory_xact_lock(741103109)');
            if (!$this->q("select 1 from v_pbx_backup_settings where singleton=1 and passphrase_secret<>''")->fetchColumn()) throw new InvalidArgumentException('Save a backup password first.');
            $pending=$this->q("select command_uuid,action,backup_uuid from v_pbx_backup_commands where status in ('pending','running') order by created_at limit 1")->fetch(PDO::FETCH_ASSOC);
            if ($pending) {
                if ($pending['action']!==$action || ($pending['backup_uuid']??'')!==$backup) throw new OverflowException('Another backup request is running. Wait for it to finish.');
                $this->db->commit(); return $pending['command_uuid'];
            }
            if ((int)$this->q("select count(*) from v_pbx_backup_commands where created_at>now()-interval '1 hour'")->fetchColumn()>=12) throw new OverflowException('Please wait before requesting another backup.');
            $id=uuid();
            $this->q('insert into v_pbx_backup_commands(command_uuid,action,backup_uuid,requested_by) values(:id,:action,:backup,:user)', ['id'=>$id,'action'=>$action,'backup'=>$action==='verify'?$backup:null,'user'=>$_SESSION['user_uuid']]);
            $this->db->commit();return $id;
        } catch(Throwable $e) { if($this->db->inTransaction())$this->db->rollBack(); throw $e; }
    }
    public function status(): array {
        $this->access();
        $status=$this->q('select state,left(message,500) message,updated_at from v_pbx_backup_status where singleton=1')->fetch(PDO::FETCH_ASSOC) ?: ['state'=>'waiting','message'=>'Waiting for the backup service.','updated_at'=>null];
        $status['service_online']=strtotime($status['updated_at']??'')>time()-180;
        $status['backups']=$this->q('select backup_uuid,status,include_media,app_version,size_bytes,sha256,remote_status,left(message,500) message,created_at,completed_at,verified_at from v_pbx_backups order by created_at desc limit 100')->fetchAll(PDO::FETCH_ASSOC);
        $status['recent']=$this->q('select action,status,left(message,500) message,created_at,finished_at from v_pbx_backup_commands order by created_at desc limit 10')->fetchAll(PDO::FETCH_ASSOC);
        return $status;
    }
    /** The download directory is root-owned and read-only to the web account. Return an opened ordinary file. */
    public function download(string $id): array {
        $this->access();
        if (!is_uuid($id)) throw new InvalidArgumentException('Backup unavailable.');
        $row=$this->q("select filename,size_bytes,sha256 from v_pbx_backups where backup_uuid=:id and status='ready'",['id'=>$id])->fetch(PDO::FETCH_ASSOC);
        if (!$row || $row['filename']!==$id.'.owpbx') throw new InvalidArgumentException('Backup unavailable.');
        $root=$this->downloadRoot();$file=$root.'/'.$row['filename'];
        if (is_link($file) || !pbx_paths::contains($root,$file) || !is_file($file) || ($handle=@fopen($file,'rb'))===false) throw new RuntimeException('The encrypted download is unavailable. Ask your instance administrator to check backup storage.');
        $stat=fstat($handle);
        if (!$stat || ($stat['mode']&0170000)!==0100000 || $stat['size']!==(int)$row['size_bytes']) { fclose($handle);throw new RuntimeException('The encrypted backup has changed. Run Check backup before downloading.'); }
        return ['handle'=>$handle,'size'=>$stat['size'],'filename'=>$row['filename'],'sha256'=>$row['sha256']];
    }
}
