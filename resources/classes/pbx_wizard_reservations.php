<?php
/** Owner-verified pre-build names and strictly scoped, revocation-only controls. */
class pbx_wizard_reservations {
    public function __construct(private PDO $db,private pbx_tenant_api $api){}
    /** Serialize grant issuance and cleanup without nesting their transactions. */
    public static function lockDevice(PDO $db,string $bootstrap):string{
        if(!is_uuid($bootstrap))throw new InvalidArgumentException('Use a valid setup identifier.');$name='wizard:device-control:'.$bootstrap;
        $q=$db->prepare('select pg_try_advisory_lock(hashtextextended(?,0))');$q->execute([$name]);
        if(!in_array($q->fetchColumn(),[true,'t',1,'1'],true))throw new pbx_tenant_api_error(409,'setup_busy','This server setup is busy. Try again shortly and keep its resources reserved.');return $name;
    }
    public static function unlockDevice(PDO $db,string $name):void{
        $q=$db->prepare('select pg_advisory_unlock(hashtextextended(?,0))');$q->execute([$name]);
        if(!in_array($q->fetchColumn(),[true,'t',1,'1'],true))throw new RuntimeException('The setup control lock was not held.');
    }
    private function q(string $sql,array $values=[]):PDOStatement{$q=$this->db->prepare($sql);$q->execute($values);return $q;}
    private function fields(array $v,array $required,array $optional=[]):void{if(array_diff($required,array_keys($v))||array_diff(array_keys($v),array_merge($required,$optional)))throw new InvalidArgumentException('Check the setup information.');}
    private function id(mixed $v):string{if(!is_string($v)||!is_uuid($v)||strtolower($v)!==$v||$v==='00000000-0000-0000-0000-000000000000')throw new InvalidArgumentException('Use a valid setup identifier.');return $v;}
    private function label(mixed $v):string{$label=pbx_tenant_api_domains::label(is_string($v)?$v:'');if(str_starts_with($label,'node-'))throw new InvalidArgumentException('Choose another tenant name.');return $label;}
    protected function rpc(string $operation,array $body):array{
        if(!in_array($operation,['label-availability','reserve-label','renew-label','release-label','bind-label','revoke-instance'],true))throw new LogicException('Unknown reservation operation.');
        $c=curl_init('http://127.0.0.1:5095/internal/v1/'.$operation);$raw='';curl_setopt_array($c,[CURLOPT_POST=>true,CURLOPT_POSTFIELDS=>json_encode($body,JSON_THROW_ON_ERROR),CURLOPT_HTTPHEADER=>['Content-Type: application/json','Accept: application/json'],CURLOPT_FOLLOWLOCATION=>false,CURLOPT_PROXY=>'',CURLOPT_CONNECTTIMEOUT=>3,CURLOPT_TIMEOUT=>35,CURLOPT_PROTOCOLS=>CURLPROTO_HTTP,CURLOPT_WRITEFUNCTION=>static function($h,string $chunk)use(&$raw):int{if(strlen($raw)+strlen($chunk)>8192)return 0;$raw.=$chunk;return strlen($chunk);}]);
        $ok=curl_exec($c);$status=curl_getinfo($c,CURLINFO_RESPONSE_CODE);curl_close($c);
        if($ok===false||$status!==200){$code='registration_preparing';if($status===409)$code='reservation_conflict';if($status===404)$code='reservation_unavailable';throw new pbx_tenant_api_error(in_array($status,[400,404,409],true)?$status:503,$code,$operation==='revoke-instance'?'Server cleanup is not confirmed. Its address must remain reserved.':'This address cannot be reserved yet. Check availability or choose another address.');}
        $out=json_decode($raw,true,8,JSON_THROW_ON_ERROR);if(!is_array($out))throw new RuntimeException('Reservation response unavailable.');return $out;
    }
    protected function encryptionKey():string{$key=file_get_contents(pbx_paths::key());if(strlen($key)!==SODIUM_CRYPTO_SECRETBOX_KEYBYTES)throw new RuntimeException('Protected setup storage is unavailable.');return $key;}
    private function seal(string $token):string{$nonce=random_bytes(SODIUM_CRYPTO_SECRETBOX_NONCEBYTES);return base64_encode($nonce.sodium_crypto_secretbox($token,$nonce,$this->encryptionKey()));}
    private function unseal(string $cipher):string{$raw=base64_decode($cipher,true);if(!is_string($raw)||strlen($raw)<40||!is_string($token=sodium_crypto_secretbox_open(substr($raw,24),substr($raw,0,24),$this->encryptionKey())))throw new RuntimeException('Protected setup control is unavailable.');return $token;}
    private function own(array $account,string $id):array{$r=$this->q('select * from v_pbx_wizard_reservation_controls where reservation_uuid=? and account_tenant_uuid=? and account_user_uuid=?',[$id,$account['tenant_uuid'],$account['user_uuid']])->fetch(PDO::FETCH_ASSOC);if(!$r)throw new pbx_tenant_api_error(404,'reservation_unavailable','This setup reservation is unavailable.');return $r;}
    private function reply(array $v):array{
        $id=$this->id($v['reservationUuid']??null);$label=$this->label($v['label']??null);if(($v['hostname']??'')!==$label.'.openwebpbx.com'||!in_array($v['state']??'',['reserved','consumed','released'],true))throw new RuntimeException('Unexpected reservation response.');
        return ['reservation_uuid'=>$id,'label'=>$label,'hostname'=>$v['hostname'],'state'=>$v['state'],'expires_at'=>(new DateTimeImmutable($v['expiresAt']))->setTimezone(new DateTimeZone('UTC'))->format(DATE_RFC3339)];
    }
    public function availability(array $input,string $ip):array{
        $this->fields($input,['label']);$label=$this->label($input['label']);$this->api->rate('wizard:availability:'.$ip,60,60);
        $global=$this->rpc('label-availability',['label'=>$label]);$local=(new pbx_tenant_api_domains($this->db))->availability($label);
        if(($global['label']??'')!==$label||($global['hostname']??'')!==$label.'.openwebpbx.com'||!is_bool($global['available']??null))throw new RuntimeException('Address check unavailable.');
        return ['label'=>$label,'hostname'=>$global['hostname'],'available'=>$global['available']&&$local['available'],'scope'=>'global','reservation_confirmed'=>false];
    }
    public function reserve(array $account,array $input):array{
        $this->fields($input,['label','request_uuid']);$label=$this->label($input['label']);$request=$this->id($input['request_uuid']);$this->api->rate('wizard:reserve:'.$account['tenant_uuid'],20,3600);
        $existing=$this->q('select reservation_uuid from v_pbx_wizard_reservation_controls where account_tenant_uuid=? and request_uuid=?',[$account['tenant_uuid'],$request])->fetchColumn();
        if(!$existing&&!(new pbx_tenant_api_domains($this->db))->availability($label)['available'])throw new pbx_tenant_api_error(409,'subdomain_unavailable','Choose another tenant address.');
        $reply=$this->reply($this->rpc('reserve-label',['accountTenantUuid'=>$account['tenant_uuid'],'requestUuid'=>$request,'label'=>$label]));
        if($reply['label']!==$label||($existing&&$existing!==$reply['reservation_uuid']))throw new RuntimeException('Reservation ownership mismatch.');
        $token='owpc_'.bin2hex(random_bytes(32));$cipher=$this->seal($token);
        $this->q("insert into v_pbx_wizard_reservation_controls(reservation_uuid,account_tenant_uuid,account_user_uuid,request_uuid,label,control_hash,control_ciphertext)values(?,?,?,?,?,?,?)on conflict(reservation_uuid)do nothing",[$reply['reservation_uuid'],$account['tenant_uuid'],$account['user_uuid'],$request,$label,hash('sha256',$token),$cipher]);
        $row=$this->own($account,$reply['reservation_uuid']);if($row['label']!==$label||$row['request_uuid']!==$request)throw new RuntimeException('Reservation ownership mismatch.');
        return $reply+['control_token'=>$this->unseal($row['control_ciphertext'])];
    }
    public function action(array $account,array $input,bool $release):array{
        $this->fields($input,['reservation_uuid']);$id=$this->id($input['reservation_uuid']);$row=$this->own($account,$id);$this->api->rate('wizard:reservation-action:'.$account['tenant_uuid'],60,3600);
        $reply=$this->reply($this->rpc($release?'release-label':'renew-label',['accountTenantUuid'=>$account['tenant_uuid'],'reservationUuid'=>$id]));
        if($release&&$reply['state']==='released')$this->q("update v_pbx_wizard_reservation_controls set state='released',updated_at=now() where reservation_uuid=?",[$id]);return $reply;
    }
    public function bind(array $account,array $device,string $id,string $label):void{
        $row=$this->own($account,$this->id($id));if($row['label']!==$label||!in_array($row['state'],['reserved','bound'],true))throw new pbx_tenant_api_error(409,'reservation_conflict','This tenant address reservation cannot be used.');
        if($row['bootstrap_uuid']!==null&&($row['bootstrap_uuid']!==$device['bootstrap_uuid']||$row['key_hash']!==$device['key_hash']||$row['domain_uuid']!==$device['domain_uuid']||$row['server_address']!==$device['server_address']))throw new pbx_tenant_api_error(409,'reservation_conflict','This reservation belongs to another server.');
        $reply=$this->rpc('bind-label',['accountTenantUuid'=>$account['tenant_uuid'],'reservationUuid'=>$id,'label'=>$label,'keyHash'=>$device['key_hash'],'domainUuid'=>$device['domain_uuid'],'localTenantUuid'=>$device['local_tenant_uuid'],'bootstrapUuid'=>$device['bootstrap_uuid']]);if(($reply['bound']??null)!==true)throw new RuntimeException('Reservation binding unavailable.');
        $q=$this->q("update v_pbx_wizard_reservation_controls set bootstrap_uuid=?,key_hash=?,domain_uuid=?,server_address=?,state='bound',updated_at=now() where reservation_uuid=? and state in ('reserved','bound') and (bootstrap_uuid is null or bootstrap_uuid=?)",[$device['bootstrap_uuid'],$device['key_hash'],$device['domain_uuid'],$device['server_address'],$id,$device['bootstrap_uuid']]);if($q->rowCount()!==1)throw new pbx_tenant_api_error(409,'reservation_conflict','The setup reservation changed.');
    }
    public function revoke(array $input,string $ip):array{
        $this->fields($input,['reservation_uuid','control_token','expected_server_address'],['expected_server_host','expected_key_hash']);$id=$this->id($input['reservation_uuid']);$token=$input['control_token'];
        $this->api->rate('wizard:cleanup:'.$ip,30,60);if(!is_string($token)||!preg_match('/^owpc_[a-f0-9]{64}$/D',$token))throw new pbx_tenant_api_error(401,'control_invalid','The server cleanup control is invalid.');
        $r=$this->q('select * from v_pbx_wizard_reservation_controls where reservation_uuid=? and control_hash=?',[$id,hash('sha256',$token)])->fetch(PDO::FETCH_ASSOC);if(!$r||!hash_equals($r['control_hash'],hash('sha256',$token)))throw new pbx_tenant_api_error(401,'control_invalid','The server cleanup control is invalid.');
        $address=pbx_wizard_api::address(is_string($input['expected_server_address'])?$input['expected_server_address']:'');
        if($r['server_address']!==null&&$r['server_address']!==$address)throw new pbx_tenant_api_error(409,'cleanup_binding_changed','The server address changed. Keep its resources reserved for review.');
        $host=$r['bootstrap_uuid']!==null?'node-'.str_replace('-','',$r['bootstrap_uuid']).'.openwebpbx.com':null;
        if((isset($input['expected_server_host'])&&$input['expected_server_host']!==$host)||(isset($input['expected_key_hash'])&&$input['expected_key_hash']!==$r['key_hash']))throw new pbx_tenant_api_error(409,'cleanup_binding_changed','The server identity changed. Keep its resources reserved for review.');
        $guard=$r['bootstrap_uuid']!==null?self::lockDevice($this->db,$r['bootstrap_uuid']):null;try{
        $this->db->beginTransaction();try{
            // Claim locks device before control; cleanup uses the same order.
            $device=null;if($r['bootstrap_uuid']!==null){
                $device=$this->q('select * from v_pbx_wizard_devices where bootstrap_uuid=? for update',[$r['bootstrap_uuid']])->fetch(PDO::FETCH_ASSOC);
                if($device){
                    foreach(['account_tenant_uuid','account_user_uuid','key_hash','domain_uuid','server_address','label']as$field)if($device[$field]!==$r[$field])throw new pbx_tenant_api_error(409,'cleanup_binding_changed','This server belongs to a different setup. Keep its resources reserved for review.');
                    if($device['server_host']!==null&&$device['server_host']!==$host)throw new pbx_tenant_api_error(409,'cleanup_binding_changed','The server identity changed. Keep its resources reserved for review.');
                }
            }
            $locked=$this->q('select * from v_pbx_wizard_reservation_controls where reservation_uuid=? and control_hash=? for update',[$id,hash('sha256',$token)])->fetch(PDO::FETCH_ASSOC);
            foreach(['account_tenant_uuid','account_user_uuid','label','bootstrap_uuid','key_hash','domain_uuid','server_address','control_hash']as$field)if(!$locked||$locked[$field]!==$r[$field])throw new pbx_tenant_api_error(409,'cleanup_binding_changed','The setup binding changed. Keep its resources reserved and retry cleanup.');
            $this->q("update v_pbx_wizard_reservation_controls set state='revoking',updated_at=now() where reservation_uuid=?",[$id]);
            if($r['bootstrap_uuid']!==null){
                if($device){$changed=$this->q("update v_pbx_wizard_devices set state='revoked',updated_at=now() where bootstrap_uuid=? and key_hash=? and domain_uuid=? and account_tenant_uuid=? and account_user_uuid=?",[$r['bootstrap_uuid'],$r['key_hash'],$r['domain_uuid'],$r['account_tenant_uuid'],$r['account_user_uuid']]);if($changed->rowCount()!==1)throw new pbx_tenant_api_error(409,'cleanup_binding_changed','The setup binding changed. Keep its resources reserved.');}
                $this->q("update v_pbx_installation_authorizations set state='revoked',updated_at=now() where key_hash=? and domain_uuid=? and account_tenant_uuid=?",[$r['key_hash'],$r['domain_uuid'],$r['account_tenant_uuid']]);
            }
            $this->db->commit();
        }catch(Throwable $e){if($this->db->inTransaction())$this->db->rollBack();throw $e;}
        $out=$this->rpc('revoke-instance',['accountTenantUuid'=>$r['account_tenant_uuid'],'reservationUuid'=>$id,'serverAddress'=>$address,'expectedServerHost'=>$host,'expectedKeyHash'=>$r['key_hash']]);
        if(($out['cleanupConfirmed']??null)!==true||!in_array($out['scope']??'',['instance','reservation_only','bound_without_dns'],true))throw new RuntimeException('Server cleanup is not confirmed.');
        $this->q("update v_pbx_wizard_reservation_controls set state='revoked',updated_at=now() where reservation_uuid=?",[$id]);
        return ['cleanup_confirmed'=>true,'state'=>'revoked','scope'=>$out['scope']];
        }finally{if($guard!==null)self::unlockDevice($this->db,$guard);}
    }
}
