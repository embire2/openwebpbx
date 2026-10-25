<?php
/** Immutable voicemail attachments must exist in PostgreSQL before delivery/deletion. */
class pbx_voicemail_mail {
    private const MAX_AUDIO = 32 * 1024 * 1024;
    public const REQUIRED = 'voicemail-attachment-v1';

    private static function audio(string $bytes, string $kind): bool {
        $size = strlen($bytes);
        if ($size < 1 || $size > self::MAX_AUDIO) return false;
        if ($kind === 'wav') {
            if ($size < 44 || substr($bytes,0,4) !== 'RIFF' || substr($bytes,8,4) !== 'WAVE') return false;
            $limit = unpack('V',substr($bytes,4,4))[1] + 8;
            if ($limit > $size || $limit < 44) return false;
            $format = false; $data = false;
            for ($offset=12; $offset+8 <= $limit;) {
                $name=substr($bytes,$offset,4);$length=unpack('V',substr($bytes,$offset+4,4))[1];
                if ($length > $limit-$offset-8) return false;
                if ($name === 'fmt ' && $length >= 16) $format=true;
                if ($name === 'data' && $length > 0) $data=true;
                $offset += 8 + $length + ($length % 2);
            }
            return $format && $data;
        }
        if ($kind === 'ogg' || $kind === 'opus') return $size > 27 && substr($bytes,0,4) === 'OggS';
        if ($kind === 'mp3') {
            $offset=0;
            if ($size >= 10 && substr($bytes,0,3) === 'ID3') {
                $tag=unpack('C4',substr($bytes,6,4));
                foreach ($tag as $value) if ($value & 128) return false;
                $offset=10+($tag[1]<<21)+($tag[2]<<14)+($tag[3]<<7)+$tag[4];
            }
            return $offset+4 < $size && ord($bytes[$offset]) === 255 && (ord($bytes[$offset+1]) & 224) === 224;
        }
        return false;
    }

    private static function read(array $row): string {
        $encoded = $row['email_attachment_base64'] ?? '';
        if ($encoded !== '') {
            if (!is_string($encoded) || strlen($encoded) > 4 * (int)ceil(self::MAX_AUDIO / 3)) throw new RuntimeException('Voicemail attachment exceeds its bound.');
            $bytes=base64_decode($encoded,true);
            if ($bytes === false || base64_encode($bytes) !== preg_replace('/\s+/', '', $encoded)) throw new RuntimeException('Voicemail attachment encoding is invalid.');
            return $bytes;
        }
        $path=($row['email_attachment_path'] ?? '').'/'.($row['email_attachment_name'] ?? '');
        $file=@fopen($path,'rb');
        if (!$file) throw new RuntimeException('Voicemail attachment is unavailable.');
        try {
            $stat=fstat($file);
            if (!$stat || ($stat['mode'] & 0170000) !== 0100000 || $stat['size'] < 1 || $stat['size'] > self::MAX_AUDIO) throw new RuntimeException('Voicemail attachment is unavailable.');
            $bytes=stream_get_contents($file,self::MAX_AUDIO+1);
            $after=fstat($file);
            if (!is_string($bytes) || strlen($bytes) !== $stat['size'] || !$after || $after['size'] !== $stat['size']) throw new RuntimeException('Voicemail attachment changed during staging.');
            return $bytes;
        } finally { fclose($file); }
    }

    /** Return complete rows, retaining original paths solely for post-success mailbox cleanup. */
    public static function stage(PDO $db, string $queue, string $domain, string $message): array {
        if ($db->inTransaction()) throw new RuntimeException('Voicemail staging requires its own completed transaction.');
        if (!$db->beginTransaction()) throw new RuntimeException('Voicemail staging transaction could not start.');
        try {
            $stmt=$db->prepare("select email_uuid from v_email_queue where email_queue_uuid=? and domain_uuid=? and email_status in('waiting','trying') for update");
            $stmt->execute([$queue,$domain]);
            if ($stmt->fetchColumn() !== $message) throw new RuntimeException('Voicemail queue ownership changed.');
            $stmt=$db->prepare('select * from v_email_queue_attachments where email_queue_uuid=? order by email_queue_attachment_uuid for update');
            $stmt->execute([$queue]);$rows=$stmt->fetchAll(PDO::FETCH_ASSOC);
            if (!$rows) throw new RuntimeException('Required voicemail attachment is missing.');
            $total=0;
            foreach ($rows as &$row) {
                if ($row['domain_uuid'] !== $domain) throw new RuntimeException('Voicemail attachment ownership differs.');
                $name=$row['email_attachment_name'];
                if (!is_string($name) || $name !== basename($name) || preg_match('/[\\\\\x00-\x1f\x7f]/',$name)) throw new RuntimeException('Voicemail attachment name is invalid.');
                $kind=strtolower(pathinfo($name,PATHINFO_EXTENSION));$bytes=self::read($row);$total+=strlen($bytes);
                if ($total > self::MAX_AUDIO || !self::audio($bytes,$kind)) throw new RuntimeException('Required voicemail audio is empty or invalid.');
                $row['email_attachment_base64']=base64_encode($bytes);
                $row['email_attachment_mime_type']=['wav'=>'audio/x-wav','mp3'=>'audio/mpeg','ogg'=>'audio/ogg','opus'=>'audio/opus'][$kind];
                $row['email_attachment_cid']=null;
                $stmt=$db->prepare('update v_email_queue_attachments set email_attachment_base64=?,email_attachment_mime_type=?,email_attachment_cid=null where email_queue_attachment_uuid=? and email_queue_uuid=? and domain_uuid=?');
                $stmt->execute([$row['email_attachment_base64'],$row['email_attachment_mime_type'],$row['email_queue_attachment_uuid'],$queue,$domain]);
                if ($stmt->rowCount() !== 1) throw new RuntimeException('Voicemail attachment was not retained.');
            }
            unset($row);
            $stmt=$db->prepare("update v_email_queue set email_action_before='voicemail-attachment-v1' where email_queue_uuid=? and domain_uuid=?");$stmt->execute([$queue,$domain]);
            // Enforce WAL acknowledgement even if an outer instance default was relaxed.
            if ($db->exec("set local synchronous_commit=on") === false || !$db->commit()) throw new RuntimeException('Voicemail staging did not complete.');
            return $rows;
        } catch (Throwable $error) {
            if ($db->inTransaction()) $db->rollBack();
            throw $error;
        }
    }

    /** Purge only this delivered/deleted voicemail's unchanged snapshot, after verified cleanup. */
    public static function clearDeleted(PDO $db, string $queue, string $domain, string $message, array $delivered): bool {
        if ($db->inTransaction() || !$delivered) return false;
        try {
            if (!$db->beginTransaction()) return false;
            $s=$db->prepare("select email_uuid from v_email_queue where email_queue_uuid=? and domain_uuid=? and email_status='sent' and email_action_after='delete' and email_action_before='voicemail-attachment-v1' for update");
            $s->execute([$queue,$domain]);
            if ($s->fetchColumn() !== $message) throw new RuntimeException('Delivered voicemail ownership changed.');
            $s=$db->prepare('select count(*) from v_voicemail_messages where domain_uuid=? and voicemail_message_uuid=?');$s->execute([$domain,$message]);
            if ((int)$s->fetchColumn() !== 0) throw new RuntimeException('Mailbox cleanup is incomplete.');
            $s=$db->prepare('select * from v_email_queue_attachments where email_queue_uuid=? order by email_queue_attachment_uuid for update');$s->execute([$queue]);$current=$s->fetchAll(PDO::FETCH_ASSOC);
            if (count($current) !== count($delivered)) throw new RuntimeException('Delivered attachments changed.');
            $expected=[];foreach($delivered as $row)$expected[$row['email_queue_attachment_uuid']]=$row;
            foreach ($current as $row) {
                $old=$expected[$row['email_queue_attachment_uuid']]??null;
                if (!$old || $row['domain_uuid'] !== $domain) throw new RuntimeException('Delivered attachment ownership changed.');
                foreach (['email_attachment_base64','email_attachment_name','email_attachment_path','email_attachment_type','email_attachment_mime_type','email_attachment_cid'] as $key) {
                    if (($row[$key]??null) !== ($old[$key]??null)) throw new RuntimeException('Delivered attachment bytes or metadata changed.');
                }
                $path=$row['email_attachment_path'];$name=$row['email_attachment_name'];
                if ($path !== '') {
                    $plain=str_replace(['msg_','intro_'],'',pathinfo($name,PATHINFO_BASENAME));
                    $expected_names=array_fill_keys(array_map('strtolower',array_unique([$name,'intro_'.$plain,'msg_'.$plain,'intro_msg_'.$plain])),true);
                    // Stat false alone is not absence: an unsearchable parent also
                    // makes file_exists/is_link return false. Enumerate the parent
                    // successfully (portable to Windows ACLs) before purging audio.
                    clearstatcache(true,$path);
                    if (!is_dir($path) || is_link($path) || !($directory=@opendir($path))) throw new RuntimeException('Recording cleanup cannot be verified.');
                    try {
                        $count=0;
                        while (false !== ($leaf=readdir($directory))) {
                            if (++$count > 100000 || isset($expected_names[strtolower($leaf)])) throw new RuntimeException('Recording cleanup is incomplete.');
                        }
                    } finally { closedir($directory); }
                }
            }
            $s=$db->prepare('update v_email_queue_attachments set email_attachment_base64=null where email_queue_attachment_uuid=? and email_queue_uuid=? and domain_uuid=? and email_attachment_base64=?');
            foreach ($current as $row) {
                $s->execute([$row['email_queue_attachment_uuid'],$queue,$domain,$row['email_attachment_base64']]);
                if ($s->rowCount() !== 1) throw new RuntimeException('Delivered attachment cleanup changed.');
            }
            if ($db->exec('set local synchronous_commit=on') === false || !$db->commit()) throw new RuntimeException('Delivered attachment cleanup did not complete.');
            return true;
        } catch (Throwable $error) {
            if ($db->inTransaction()) $db->rollBack();
            return false; // Keep the durable audio on every ambiguous/partial cleanup.
        }
    }
}
