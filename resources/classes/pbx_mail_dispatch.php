<?php
/** Cross-process queue ownership; PostgreSQL releases the lock on process exit. */
class pbx_mail_dispatch {
    public static function claim(PDO $db, string $queue): bool {
        if (!is_uuid($queue)) throw new InvalidArgumentException('Choose a queued message.');
        $key = 'openwebpbx-mail:'.$queue;
        $statement = $db->prepare('select pg_try_advisory_lock(hashtextextended(?,0))');
        $statement->execute([$key]);
        if (!in_array($statement->fetchColumn(), [true, 1, '1', 't'], true)) return false;
        register_shutdown_function(static function () use ($db, $key): void {
            try {
                $statement = $db->prepare('select pg_advisory_unlock(hashtextextended(?,0))');
                $statement->execute([$key]);
            } catch (Throwable $ignored) { /* Closing the connection releases it. */ }
        });
        return true;
    }
}
