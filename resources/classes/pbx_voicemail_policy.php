<?php
/** Mailbox access is tied to the authenticated phone; retired PINs are ignored. */
class pbx_voicemail_policy {
    public static function apply(PDO $db): void {
        if ($db->getAttribute(PDO::ATTR_DRIVER_NAME) !== 'pgsql') throw new RuntimeException('The voicemail migration requires this instance’s PostgreSQL database.');
        $sql = file_get_contents(dirname(__DIR__, 2).'/app/voicemails/resources/voicemail_without_pins.sql');
        if ($sql === false || trim($sql) === '') throw new RuntimeException('The voicemail access migration is unavailable.');
        $ownTransaction = !$db->inTransaction();
        if ($ownTransaction) $db->beginTransaction();
        try {
            $db->exec($sql);
            if ($ownTransaction) $db->commit();
        } catch (Throwable $error) {
            if ($ownTransaction && $db->inTransaction()) $db->rollBack();
            throw $error;
        }
    }
    public static function retiredSetting(string $category, string $subcategory): bool {
        return strtolower($category) === 'voicemail' && in_array(strtolower($subcategory), ['password_length','password_complexity','password_min_length','remote_access'], true);
    }
    public static function withoutPins(array $data): array {
        foreach ($data as $key=>$value) {
            if (is_string($key) && in_array(strtolower($key), ['voicemail_pin','voicemail_password','vmpin'], true)) { unset($data[$key]); continue; }
            if (is_array($value)) $data[$key] = self::withoutPins($value);
        }
        return $data;
    }
    /** Validate exactly the fields offered by the current import schema. */
    public static function importable(array $schema, mixed $table, mixed $field): bool {
        if (!is_string($table) || !is_string($field) || $field === 'voicemail_password') return false;
        foreach ($schema as $row) if (($row['table'] ?? null) === $table && in_array($field, $row['fields'] ?? [], true)) return true;
        return false;
    }
}
