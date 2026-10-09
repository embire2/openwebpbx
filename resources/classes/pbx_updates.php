<?php
/** Release policy and authenticated requests. Privileged installation belongs to the updater service. */
class pbx_updates {
    public const FEED_URL = 'https://github.com/embire2/openwebpbx/releases/latest/download/update-manifest.json';
    private PDO $db;
    public function __construct(?PDO $db = null) {
        $this->db = $db ?? database::new()->db;
        $this->db->setAttribute(PDO::ATTR_ERRMODE, PDO::ERRMODE_EXCEPTION);
    }
    private function q(string $sql, array $params = []): PDOStatement {
        $s = $this->db->prepare($sql);
        foreach ($params as $key => $value) $s->bindValue(':'.$key, $value, is_int($value) ? PDO::PARAM_INT : ($value === null ? PDO::PARAM_NULL : PDO::PARAM_STR));
        $s->execute(); return $s;
    }
    protected function allowed(string $permission): bool { return permission_exists($permission); }
    public static function version(): string {
        $version = trim((string)@file_get_contents(PROJECT_ROOT.'/VERSION'));
        return preg_match('/^\d+\.\d+\.\d+$/D', $version) ? $version : 'unknown';
    }
    public function instanceAdmin(): bool { return $this->allowed('pbx_update_instance'); }
    public function canView(): bool {
        $id = $_SESSION['user_uuid'] ?? '';
        if (empty($_SESSION['authorized']) || !is_uuid($id) || !$this->allowed('pbx_update_manage')) return false;
        if (!$this->q("select 1 from v_users where user_uuid=:id and user_enabled='true'", ['id'=>$id])->fetchColumn()) return false;
        return $this->instanceAdmin() || (bool)$this->q('select 1 from v_pbx_tenants where owner_user_uuid=:id and enabled=true', ['id'=>$id])->fetchColumn();
    }
    private function access(bool $instance = false): void {
        if (!$this->canView() || ($instance && !$this->instanceAdmin())) throw new DomainException('Update administrator access is required.');
    }
    public function tenants(): array {
        $this->access();
        return $this->q('select tenant_uuid,tenant_name from v_pbx_tenants where enabled=true'.($this->instanceAdmin() ? '' : ' and owner_user_uuid=:user').' order by tenant_name', $this->instanceAdmin() ? [] : ['user'=>$_SESSION['user_uuid']])->fetchAll(PDO::FETCH_ASSOC);
    }
    private function tenant(string $id): void {
        $this->access();
        if (!is_uuid($id)) throw new InvalidArgumentException('Choose a tenant.');
        $row = $this->q('select owner_user_uuid,enabled from v_pbx_tenants where tenant_uuid=:id', ['id'=>$id])->fetch(PDO::FETCH_ASSOC);
        if (!$row || !filter_var($row['enabled'], FILTER_VALIDATE_BOOLEAN) || (!$this->instanceAdmin() && $row['owner_user_uuid'] !== $_SESSION['user_uuid'])) throw new DomainException('Tenant update settings are unavailable.');
    }
    private function policy(string $scope): array {
        return $this->q('select mode,channel,maintenance_hour,maintenance_duration,updated_at from v_pbx_update_policies where scope_key=:scope', ['scope'=>$scope])->fetch(PDO::FETCH_ASSOC)
            ?: ['mode'=>'notify','channel'=>'stable','maintenance_hour'=>2,'maintenance_duration'=>2,'updated_at'=>null];
    }
    public function instancePolicy(): array { $this->access(true); return $this->policy('instance'); }
    public function tenantPolicy(string $tenant): array { $this->tenant($tenant); return $this->policy('tenant:'.$tenant); }
    public function saveInstance(array $input): void {
        $this->access(true);
        $mode = $input['mode'] ?? null;
        if (!in_array($mode, ['notify','download','automatic'], true)) throw new InvalidArgumentException('Choose a server update option.');
        $hour = filter_var($input['maintenance_hour'] ?? null, FILTER_VALIDATE_INT, ['options'=>['min_range'=>0,'max_range'=>23]]);
        $duration = filter_var($input['maintenance_duration'] ?? null, FILTER_VALIDATE_INT, ['options'=>['min_range'=>1,'max_range'=>6]]);
        if ($hour === false || $duration === false) throw new InvalidArgumentException('Choose a valid update window in UTC.');
        $this->save('instance', $mode, $hour, $duration);
    }
    public function saveTenant(string $tenant, array $input): void {
        $this->tenant($tenant); $mode = $input['mode'] ?? null;
        if (!in_array($mode, ['notify','download','required'], true)) throw new InvalidArgumentException('Choose an Android update option.');
        $this->save('tenant:'.$tenant, $mode, 2, 2);
    }
    private function save(string $scope, string $mode, int $hour, int $duration): void {
        $this->q("insert into v_pbx_update_policies(scope_key,mode,maintenance_hour,maintenance_duration,updated_by) values(:scope,:mode,:hour,:duration,:user)
            on conflict(scope_key) do update set mode=excluded.mode,maintenance_hour=excluded.maintenance_hour,maintenance_duration=excluded.maintenance_duration,updated_by=excluded.updated_by,updated_at=now()",
            ['scope'=>$scope,'mode'=>$mode,'hour'=>$hour,'duration'=>$duration,'user'=>$_SESSION['user_uuid']]);
    }
    public function request(string $action): string {
        $this->access(true);
        if (!in_array($action, ['check','download','install'], true)) throw new InvalidArgumentException('Choose a supported update action.');
        $this->db->beginTransaction();
        try {
            $this->q('select pg_advisory_xact_lock(741103104)');
            $pending = $this->q("select command_uuid,action from v_pbx_update_commands where status in ('pending','running') order by created_at limit 1")->fetch(PDO::FETCH_ASSOC);
            if ($pending) {
                if ($pending['action'] !== $action) throw new OverflowException('Another update request is running. Wait for it to finish, then choose this action again.');
                $this->db->commit(); return $pending['command_uuid'];
            }
            if ((int)$this->q("select count(*) from v_pbx_update_commands where created_at>now()-interval '10 minutes'")->fetchColumn() >= 20) throw new OverflowException('Please wait before requesting another update check.');
            $id = uuid();
            $this->q('insert into v_pbx_update_commands(command_uuid,action,requested_by) values(:id,:action,:user)', ['id'=>$id,'action'=>$action,'user'=>$_SESSION['user_uuid']]);
            $this->db->commit(); return $id;
        } catch (Throwable $e) { if ($this->db->inTransaction()) $this->db->rollBack(); throw $e; }
    }
    public function status(): array {
        $this->access(true);
        $row = $this->q('select status_json,updated_at from v_pbx_update_status where singleton=1')->fetch(PDO::FETCH_ASSOC);
        $data = json_decode($row['status_json'] ?? '{}', true);
        $data = is_array($data) ? $data : [];
        // Do not expose paths, installer output, arbitrary worker fields or exception details.
        $out = ['state'=>'waiting','message'=>'Waiting for the update service.','installed_version'=>self::version(),'available_version'=>'','progress_bytes'=>0,'total_bytes'=>0,'checked_at'=>''];
        foreach (['state','message','installed_version','available_version','checked_at','last_success_version'] as $key)
            if (isset($data[$key]) && is_string($data[$key])) $out[$key] = mb_substr($data[$key], 0, $key === 'message' ? 500 : 80);
        foreach (['progress_bytes','total_bytes'] as $key) if (isset($data[$key]) && is_numeric($data[$key])) $out[$key] = max(0, (int)$data[$key]);
        $out['updated_at'] = $row['updated_at'] ?? null;
        $out['service_online'] = !empty($data) && strtotime($row['updated_at'] ?? '') > time()-180;
        $out['recent'] = $this->q('select action,status,left(message,500) message,created_at,finished_at from v_pbx_update_commands order by created_at desc limit 10')->fetchAll(PDO::FETCH_ASSOC);
        return $out;
    }
    /** Called only after pbx_mobile has authenticated the device and its active extension. */
    public function phonePolicy(array $account): array {
        $domain = $account['domain_uuid'] ?? '';
        if (!is_uuid($domain)) throw new InvalidArgumentException('Phone account unavailable.');
        $row = $this->q('select t.tenant_uuid,t.enabled from v_pbx_services s join v_pbx_tenants t using(tenant_uuid) where s.domain_uuid=:domain', ['domain'=>$domain])->fetch(PDO::FETCH_ASSOC);
        if ($row && !filter_var($row['enabled'], FILTER_VALIDATE_BOOLEAN)) throw new UnexpectedValueException('This phone is no longer connected.');
        $policy = $row ? $this->policy('tenant:'.$row['tenant_uuid']) : ['mode'=>'notify'];
        return ['schema'=>1,'mode'=>in_array($policy['mode'], ['notify','download','required'], true) ? $policy['mode'] : 'notify','channel'=>'stable','server_version'=>self::version(),'feed_url'=>self::FEED_URL];
    }
}
