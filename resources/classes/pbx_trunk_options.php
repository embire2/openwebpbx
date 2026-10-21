<?php
/** Independent, tenant-owned provider options. Never writes phone identities or incoming destinations. */
class pbx_trunk_options {
    public const VERSION='1.0.20';
    private PDO $db;
    private string $domain;
    private string $actor;
    public function __construct(?PDO $db=null){$this->db=$db??database::new()->db;$this->domain=(string)($_SESSION['domain_uuid']??'');$this->actor=(string)($_SESSION['user_uuid']??'');$this->owner();}
    protected function engine(string $command): string {return (string)event_socket::api($command);}
    protected function clearGatewayCache(): void {(new cache)->delete(gethostname().':configuration:sofia.conf');}
    private function q(string $sql,array $params=[]): PDOStatement {$s=$this->db->prepare($sql);$s->execute($params);return $s;}
    private function owner(): void {
        if($this->domain!==($_SESSION['domain_uuid']??null)||$this->actor!==($_SESSION['user_uuid']??null)||!(new pbx_staff_access($this->db))->owner()||!$this->q("select 1 from v_domains d join v_users u on u.user_uuid=:u where d.domain_uuid=:d and d.domain_enabled='true' and u.user_enabled='true'",['d'=>$this->domain,'u'=>$this->actor])->fetchColumn())throw new RuntimeException('PBX owner access is required to change trunk options.');
    }
    private function native(array $trunk,bool $lock=false): array {
        $id=$trunk['gateway_uuid']??'';if(!is_uuid($id))throw new InvalidArgumentException('Choose a trunk belonging to this PBX.');
        $r=$this->q('select gateway_uuid,enabled,profile,channels,register_transport,expire_seconds,outbound_proxy from v_gateways where domain_uuid=:d and gateway_uuid=:g'.($lock?' for update':''),['d'=>$this->domain,'g'=>$id])->fetch(PDO::FETCH_ASSOC);
        if(!$r)throw new InvalidArgumentException('Choose a trunk belonging to this PBX.');return $r;
    }
    private function canonical(array $value): array {if(!array_is_list($value))ksort($value);foreach($value as &$item)if(is_array($item))$item=$this->canonical($item);unset($item);return $value;}
    private function sameOptions(array $left,array $right): bool {return $this->canonical($left)===$this->canonical($right);}
    private function revision(array $trunk,array $native): string {return hash('sha256',json_encode([$trunk,$native],JSON_THROW_ON_ERROR));}
    public static function defaults(array $trunk,array $native): array {
        return ['schema'=>1,'allow_incoming'=>true,'allow_outgoing'=>true,'support_reinvite'=>true,'srtp_mode'=>'inherit','scope_department'=>'','connection_pending'=>false];
    }
    public function snapshot(string $key): array {
        $this->owner();$c=(new pbx_admin($this->db))->config();$t=$c['trunks'][$key]??null;if(!$t)throw new InvalidArgumentException('Choose a trunk belonging to this PBX.');$n=$this->native($t);
        $o=($t['options']??[])+self::defaults($t,$n);
        return ['config'=>$c,'trunk'=>$t,'native'=>$n,'options'=>$o,'revision'=>$this->revision($t,$n)];
    }
    private function text(array $in,string $key,int $max): string {$v=$in[$key]??'';if(!is_string($v)||strlen($v)>$max||preg_match('/[\x00-\x20\x7f]/',$v))throw new InvalidArgumentException('Enter a valid '.str_replace('_',' ',$key).'.');return $v;}
    private function integer(array $in,string $key,int $min,int $max): int {$v=$in[$key]??null;if(!is_string($v)||!preg_match('/^[0-9]+$/D',$v)||filter_var($v,FILTER_VALIDATE_INT,['options'=>['min_range'=>$min,'max_range'=>$max]])===false)throw new InvalidArgumentException('Enter a valid '.str_replace('_',' ',$key).'.');return (int)$v;}
    private function flag(array $in,string $key): bool {if(!isset($in[$key]))return false;if($in[$key]!=='1')throw new InvalidArgumentException('Choose a valid '.str_replace('_',' ',$key).'.');return true;}
    private function endpoint(string $v): string {
        if($v==='')return '';
        if(preg_match('/^\[([0-9a-fA-F:]+)\](?::([0-9]{1,5}))?$/D',$v,$m)){$host=$m[1];if(!filter_var($host,FILTER_VALIDATE_IP,FILTER_FLAG_IPV6))throw new InvalidArgumentException('Enter a valid outbound proxy.');}
        elseif(preg_match('/^([A-Za-z0-9.-]+)(?::([0-9]{1,5}))?$/D',$v,$m)){$host=$m[1];if(!filter_var($host,FILTER_VALIDATE_IP,FILTER_FLAG_IPV4)&&(!filter_var($host,FILTER_VALIDATE_DOMAIN,FILTER_FLAG_HOSTNAME)||strlen($host)>253))throw new InvalidArgumentException('Enter a valid outbound proxy.');}
        else throw new InvalidArgumentException('Enter a host name or IP address for the outbound proxy.');
        if(isset($m[2])&&((int)$m[2]<1||(int)$m[2]>65535))throw new InvalidArgumentException('Enter a valid outbound proxy port.');return strtolower($v);
    }
    private function ready(): void {if(trim($this->engine('module_exists mod_hash'))!=='true')throw new RuntimeException('Trunk capacity protection is unavailable. Ask the instance administrator to repair the calling service before saving.');}
    private function idle(): void {$r=json_decode($this->engine('show channels as json'),true);if(!is_array($r)||!array_key_exists('row_count',$r)||!is_numeric($r['row_count'])||(int)$r['row_count']!==0)throw new RuntimeException('Wait until current calls have ended before changing this connection.');}
    /** Return an honest status if a saved connection cannot be refreshed immediately. */
    public function save(string $key,array $in): string {
        $this->owner();$revision=$this->text($in,'options_revision',64);$locked=false;$refresh=false;$native=[];$savedOptions=[];$savedTrunk=[];
        // Keep this form's post-commit scoped reconnects in order, without an engine-wide lock.
        $lock='trunk-options:'.$this->domain.':'.$key;
        try{
            $this->q('select pg_advisory_lock(hashtextextended(:k,0))',['k'=>$lock]);$locked=true;
            $this->db->beginTransaction();
            try{
                $this->owner();$c=(new pbx_admin($this->db))->config(true);$t=$c['trunks'][$key]??null;if(!$t)throw new InvalidArgumentException('Choose a trunk belonging to this PBX.');$native=$this->native($t,true);
                if(!hash_equals($this->revision($t,$native),$revision))throw new RuntimeException('These trunk options changed since you opened them. Refresh before saving again.');
                $scope=$this->text($in,'scope_department',40);if($scope!==''&&(!preg_match('/^[A-Za-z0-9_-]+$/D',$scope)||!in_array($scope,array_map('strval',array_column($c['departments']??[],'number')),true)))throw new InvalidArgumentException('Choose a department from this PBX.');
                $mode=$this->text($in,'srtp_mode',20);if(!in_array($mode,['inherit','disabled','optional','required'],true))throw new InvalidArgumentException('Choose a secure audio setting.');
                $transport=$this->text($in,'transport',8);if(!in_array($transport,['udp','tcp','tls'],true))throw new InvalidArgumentException('Choose UDP, TCP or TLS transport.');
                $limit=$this->integer($in,'limit',1,10000);$expires=$this->integer($in,'expires',1,86400);
                $rawProxy=$in['outbound_proxy']??'';$proxy=is_string($rawProxy)&&$rawProxy===(string)($native['outbound_proxy']??'')?$rawProxy:$this->endpoint($this->text($in,'outbound_proxy',300));
                $options=['schema'=>1,'allow_incoming'=>$this->flag($in,'allow_incoming'),'allow_outgoing'=>$this->flag($in,'allow_outgoing'),'support_reinvite'=>$this->flag($in,'support_reinvite'),'srtp_mode'=>$mode,'scope_department'=>$scope,'connection_pending'=>false];
                $connectionChanged=$transport!==($native['register_transport']?:'udp')||$expires!==(int)($native['expire_seconds']?:3600)||$proxy!==($native['outbound_proxy']??'');
                $refresh=filter_var($native['enabled'],FILTER_VALIDATE_BOOLEAN)&&($connectionChanged||!empty($t['options']['connection_pending']));
                if($refresh){if(!$this->flag($in,'confirm_connection'))throw new InvalidArgumentException('Confirm refreshing this trunk connection before saving connection changes.');$this->idle();}
                $this->ready();
                $options['connection_pending']=$refresh;$savedOptions=$options;
                $c['trunks'][$key]['options']=$options;$c['trunks'][$key]['limit']=$limit;
                // Only explicitly changed connection columns are written. Every other native field is preserved.
                $updates=[];$params=['d'=>$this->domain,'g'=>$native['gateway_uuid']];
                foreach(['channels'=>(string)$limit,'register_transport'=>$transport,'expire_seconds'=>(string)$expires,'outbound_proxy'=>$proxy] as $field=>$value){
                    $old=(string)($native[$field]??'');$effective=match($field){'register_transport'=>$old?:'udp','expire_seconds'=>$old?:'3600',default=>$old};
                    if($value!==$effective){$updates[]=$field.'=:'.$field;$params[$field]=$value;$native[$field]=$value;}
                }
                if($updates)$this->q('update v_gateways set '.implode(',',$updates).' where domain_uuid=:d and gateway_uuid=:g',$params);
                // Synchronize the existing public connection projection; never store credentials here.
                if($connectionChanged){$c['trunks'][$key]['transport']=$transport;$c['trunks'][$key]['expires']=$expires;$c['trunks'][$key]['outbound_proxy']=$proxy;}
                $savedTrunk=$c['trunks'][$key];
                $this->q('update v_pbx_restore set config=cast(:c as jsonb) where domain_uuid=:d',['d'=>$this->domain,'c'=>json_encode($c,JSON_THROW_ON_ERROR)]);
                (new pbx_staff_access($this->db))->audit('trunk_options',$key);$this->db->commit();
            }catch(Throwable $e){if($this->db->inTransaction())$this->db->rollBack();throw $e;}
            if(!$refresh)return 'Trunk options saved. New calls use these settings; the provider connection was not restarted.';
            try{
                $profile=$native['profile']?:'external';if(!preg_match('/^[A-Za-z0-9_.-]{1,64}$/D',$profile))throw new RuntimeException('Invalid provider profile.');
                $this->db->beginTransaction();$this->owner();$current=(new pbx_admin($this->db))->config(true);
                if(!isset($current['trunks'][$key])||!$this->sameOptions($current['trunks'][$key],$savedTrunk)||$this->native($current['trunks'][$key],true)!==$native)throw new RuntimeException('The connection changed before its refresh.');
                // Hold both rows through the exact scoped refresh. Another normal
                // admin Save cannot replace this gateway while it is reloaded.
                $this->idle();
                $this->clearGatewayCache();
                foreach(['sofia profile '.$profile.' killgw '.$native['gateway_uuid'],'sofia profile '.$profile.' rescan'] as $command){$response=trim($this->engine($command));if($response===''||str_starts_with($response,'-ERR')||stripos($response,'invalid profile')!==false)throw new RuntimeException('Provider refresh unavailable.');}
                $current['trunks'][$key]['options']['connection_pending']=false;$this->q('update v_pbx_restore set config=cast(:c as jsonb) where domain_uuid=:d',['d'=>$this->domain,'c'=>json_encode($current,JSON_THROW_ON_ERROR)]);
                $this->db->commit();return 'Trunk options saved and this provider connection refreshed. Check its registration before making a test call.';
            }catch(Throwable){if($this->db->inTransaction())$this->db->rollBack();return 'Trunk options saved. The provider connection still needs a refresh; wait until calls end, confirm the connection refresh and save these options again.';}
        }finally{if($locked)$this->q('select pg_advisory_unlock(hashtextextended(:k,0))',['k'=>$lock]);}
    }
}
