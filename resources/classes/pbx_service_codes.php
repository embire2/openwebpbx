<?php
/** Fixed services take precedence over user and outgoing-number routes. */
class pbx_service_codes {
    public const NUMBERS = ['121', '1026'];
    public static function isReserved(mixed $number): bool {
        return (is_string($number) || is_int($number)) && in_array((string)$number, self::NUMBERS, true);
    }
    public static function rangeContainsService(mixed $start, mixed $count = 1): bool {
        if (!is_scalar($start) || !is_numeric($start)) return false;
        $start=(int)$start; $count=max(1,is_scalar($count)?(int)$count:1);
        foreach (self::NUMBERS as $code) if ((int)$code >= $start && (int)$code - $start < $count) return true;
        return false;
    }
    /** CSV rows can have distinct SIP auth IDs; reserve their visible alias only. */
    public static function assertRows(array $rows): void {
        foreach ($rows['extensions'] ?? [] as $row) self::assertAvailable(!empty($row['number_alias']) ? $row['number_alias'] : ($row['extension'] ?? ''));
        foreach ($rows['voicemails'] ?? [] as $row) self::assertAvailable($row['voicemail_id'] ?? '');
    }
    public static function assertAvailable(mixed $number): void {
        if (self::isReserved($number)) throw new InvalidArgumentException('121 is reserved for your voicemail and 1026 for the talking clock. Choose another extension.');
    }
}
