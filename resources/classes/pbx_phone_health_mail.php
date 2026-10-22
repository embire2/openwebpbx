<?php
/** Transactional, optional Phone Health notifications through the global outbox. */
final class pbx_phone_health_mail {
    private const LABELS = [
        'phone_offline' => 'A phone is offline',
        'phone_unavailable' => 'A phone needs a status review',
        'office_blocked' => 'An office connection is blocked',
        'provider_failed' => 'A phone provider needs attention',
        'status_unavailable' => 'Phone status is temporarily unavailable',
    ];

    /** Called only inside the monitor's issue-transition transaction. */
    public static function queue(PDO $db, array $transition): bool {
        if (PHP_SAPI !== 'cli' || !$db->inTransaction()) {
            throw new RuntimeException('Health notifications require the managed observation transaction.');
        }
        $q = static function(string $sql, array $params = []) use ($db): PDOStatement {
            $statement = $db->prepare($sql);
            $statement->execute($params);
            return $statement;
        };
        $domain = $transition['domain_uuid'] ?? '';
        $issue = $transition['issue_uuid'] ?? '';
        $key = $transition['issue_key'] ?? '';
        $state = $transition['state'] ?? '';
        if (!is_string($domain) || !is_string($issue) || !is_uuid($domain) || !is_uuid($issue)
            || !is_string($key) || strlen($key) > 256 || !in_array($state, ['opened', 'resolved'], true)) {
            throw new InvalidArgumentException('A current health transition is required.');
        }
        // Never trust the incoming kind, label, recipient or cached preference.
        $row = $q('select issue_uuid,kind,first_seen,last_seen,resolved_at,notified_at,resolved_notified_at
            from v_pbx_phone_health_issues where domain_uuid=? and issue_uuid=? and issue_key=? for update',
            [$domain, $issue, $key])->fetch(PDO::FETCH_ASSOC);
        if (!$row || !isset(self::LABELS[$row['kind']])) return false;
        if ($state === 'opened' && ($row['resolved_at'] !== null || $row['notified_at'] !== null)) return false;
        if ($state === 'resolved' && ($row['resolved_at'] === null || $row['notified_at'] === null
            || $row['resolved_notified_at'] !== null)) return false;
        $enabled = $q('select alerts_enabled from v_pbx_phone_health_settings where domain_uuid=? for share', [$domain])->fetchColumn();
        if (!in_array($enabled, [true, 't', 'true', 1, '1'], true)) return false;
        $active = $q("select domain_uuid from v_domains where domain_uuid=? and domain_enabled::text='true' for share", [$domain])->fetchColumn();
        if (!$active) return false;
        // Home-domain and service-domain ownership follow the same tenant model
        // as the portal. Ambiguous, suspended or ownerless tenants get no mail.
        $tenants = $q('select t.tenant_uuid,t.owner_user_uuid from v_pbx_tenants t
            where t.enabled=true and (t.home_domain_uuid=? or exists(
                select 1 from v_pbx_services s where s.tenant_uuid=t.tenant_uuid and s.domain_uuid=?))
            for share of t', [$domain, $domain])->fetchAll(PDO::FETCH_ASSOC);
        if (count($tenants) !== 1 || !is_uuid($tenants[0]['owner_user_uuid'] ?? '')) return false;
        $owner = $q("select user_email from v_users where user_uuid=? and user_enabled::text='true' for share",
            [$tenants[0]['owner_user_uuid']])->fetchColumn();
        if (!is_string($owner) || strlen($owner) > 254 || !filter_var($owner, FILTER_VALIDATE_EMAIL)
            || preg_match('/[\x00-\x1f\x7f]/', $owner)) return false;
        $label = self::LABELS[$row['kind']];
        $title = $state === 'resolved' ? 'Recovered: '.$label : $label;
        $h = static fn(string $text): string => htmlspecialchars($text, ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8');
        $body = '<h1>'.$h($title).'</h1><p>'.($state === 'resolved'
            ? 'The latest check shows this issue has recovered.'
            : 'OpenWeb PBX detected an issue that needs your attention.').'</p>'
            .'<p>Open your PBX administrator panel and choose <strong>Phone Health</strong> for the affected phones, the cause and safe recovery options.</p>'
            .'<p>This is an automatic notification from OpenWeb PBX. No phone password, security rule or call route was changed by this check.</p>';
        $q("insert into v_email_queue(email_queue_uuid,domain_uuid,hostname,email_date,email_from,email_to,email_subject,email_body,email_status)
            values(?,?,?,now(),'',?,?,?,'waiting')", [uuid(), $domain, gethostname(), $owner, 'OpenWeb PBX: '.$title, $body]);
        $column = $state === 'resolved' ? 'resolved_notified_at' : 'notified_at';
        $q('update v_pbx_phone_health_issues set '.$column.'=now() where domain_uuid=? and issue_uuid=?', [$domain, $issue]);
        return true;
    }
}
