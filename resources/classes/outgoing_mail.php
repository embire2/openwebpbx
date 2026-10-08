<?php
/** Mail stays queued until the instance administrator configures its relay. */
class outgoing_mail_configuration_required extends RuntimeException {}

/** Global SMTP configuration shared by direct mail and the email queue. */
class outgoing_mail {
    private PDO $db;
    private const DEFAULTS = [
        'smtp_global' => 'false', 'smtp_host' => '', 'smtp_port' => '587',
        'smtp_secure' => 'tls', 'smtp_auth' => 'true', 'smtp_username' => '',
        'smtp_password' => '', 'smtp_from' => '', 'smtp_from_name' => 'OpenWeb PBX',
        'smtp_hostname' => '', 'smtp_validate_certificate' => 'true',
    ];

    public function __construct(?PDO $db = null) {
        $this->db = $db ?? database::new()->db;
    }

    public function canManage(): bool {
        return permission_exists('smtp_settings_manage') || permission_exists('default_setting_edit');
    }

    /** Read defaults directly so tenant overrides and stale settings caches cannot change the relay. */
    private function values(): array {
        $stmt = $this->db->query("select default_setting_subcategory, default_setting_value from v_default_settings
            where default_setting_category='email' and default_setting_enabled=true order by default_setting_order asc");
        $values = self::DEFAULTS;
        foreach ($stmt->fetchAll(PDO::FETCH_ASSOC) as $row) {
            $key = $row['default_setting_subcategory'];
            if (array_key_exists($key, $values)) $values[$key] = (string)$row['default_setting_value'];
        }
        return $values;
    }

    public function view(): array {
        if (!$this->canManage()) throw new RuntimeException('Outgoing mail administration permission is required.');
        $values = $this->values();
        $values['has_password'] = $values['smtp_password'] !== '';
        try {
            $this->transport();
            $values['is_configured'] = true;
        } catch (outgoing_mail_configuration_required $e) {
            $values['is_configured'] = false;
        }
        unset($values['smtp_password']);
        return $values;
    }

    /** Every instance uses its saved global relay. Never fall back to a tenant or local relay. */
    public function transport(): array {
        $values = $this->values();
        $auth = filter_var($values['smtp_auth'], FILTER_VALIDATE_BOOLEAN, FILTER_NULL_ON_FAILURE);
        $host = trim($values['smtp_host']);
        $literal = trim($host, '[]');
        $validHost = strlen($host) <= 253 && (filter_var($literal, FILTER_VALIDATE_IP)
            || preg_match('/^(?=.{1,253}$)[a-z0-9](?:[a-z0-9.-]*[a-z0-9])?$/iD', $host));
        $validPort = filter_var($values['smtp_port'], FILTER_VALIDATE_INT, ['options'=>['min_range'=>1,'max_range'=>65535]]);
        if (!filter_var($values['smtp_global'], FILTER_VALIDATE_BOOLEAN) || !$validHost || !$validPort
            || !in_array($values['smtp_secure'], ['tls','ssl','none'], true) || $auth === null
            || !filter_var($values['smtp_from'], FILTER_VALIDATE_EMAIL)
            || ($auth && ($values['smtp_username'] === '' || $values['smtp_password'] === ''))) {
            throw new outgoing_mail_configuration_required('Configure global outgoing mail in SMTP Outgoing Mail before sending emails.');
        }
        $smtp = [];
        foreach ($values as $key => $value) {
            if ($key !== 'smtp_global') $smtp[substr($key, 5)] = $value;
        }
        $smtp['auth'] = $auth;
        $smtp['validate_certificate'] = true;
        if (!$smtp['auth']) {
            $smtp['username'] = '';
            $smtp['password'] = '';
        }
        return $smtp;
    }

    public function save(array $input): void {
        if (!$this->canManage()) throw new RuntimeException('Outgoing mail administration permission is required.');
        $previous = $this->values();
        $host = trim($input['smtp_host'] ?? '');
        $literal = trim($host, '[]');
        if (strlen($host) > 253 || !(filter_var($literal, FILTER_VALIDATE_IP)
            || preg_match('/^(?=.{1,253}$)[a-z0-9](?:[a-z0-9.-]*[a-z0-9])?$/iD', $host))) {
            throw new InvalidArgumentException('Enter an SMTP hostname or IP address, without a URL or port.');
        }
        if (filter_var($literal, FILTER_VALIDATE_IP)) {
            $host = filter_var($literal, FILTER_VALIDATE_IP, FILTER_FLAG_IPV6) ? '['.$literal.']' : $literal;
        }
        $port = filter_var($input['smtp_port'] ?? '', FILTER_VALIDATE_INT, ['options'=>['min_range'=>1,'max_range'=>65535]]);
        if (!$port) throw new InvalidArgumentException('Enter an SMTP port between 1 and 65535.');
        $secure = $input['smtp_secure'] ?? 'tls';
        if (!in_array($secure, ['tls','ssl','none'], true)) throw new InvalidArgumentException('Choose a valid connection security option.');
        // The checkbox is the current form control; retain the earlier authentication field
        // for existing clients. An unchecked checkbox explicitly selects credential authentication.
        if (array_key_exists('smtp_ip_whitelisted', $input)) {
            $whitelisted = is_scalar($input['smtp_ip_whitelisted'])
                ? filter_var($input['smtp_ip_whitelisted'], FILTER_VALIDATE_BOOLEAN, FILTER_NULL_ON_FAILURE) : null;
            if ($whitelisted === null) throw new InvalidArgumentException('Choose whether your server IP address is whitelisted.');
            $authentication = $whitelisted ? 'ip' : 'password';
        } else {
            $authentication = $input['authentication'] ?? '';
        }
        if (!in_array($authentication, ['password','ip'], true)) throw new InvalidArgumentException('Choose an authentication method.');
        $from = trim($input['smtp_from'] ?? '');
        if (!filter_var($from, FILTER_VALIDATE_EMAIL)) throw new InvalidArgumentException('Enter a valid sender email address.');
        $name = trim($input['smtp_from_name'] ?? '');
        if (mb_strlen($name) > 128 || preg_match('/[\x00-\x1f\x7f]/', $name)) throw new InvalidArgumentException('Enter a valid sender name.');
        $username = $password = '';
        if ($authentication === 'password') {
            $username = trim($input['smtp_username'] ?? '');
            $password = $input['smtp_password'] ?? '';
            if ($password === '' && $host === $previous['smtp_host'] && $username === $previous['smtp_username']
                && filter_var($previous['smtp_auth'], FILTER_VALIDATE_BOOLEAN)) $password = $previous['smtp_password'];
            if ($username === '' || $password === '') throw new InvalidArgumentException('Username and password are required for credential authentication.');
            if (strlen($username)>256 || strlen($password)>1024 || preg_match('/[\x00-\x1f\x7f]/', $username.$password)) {
                throw new InvalidArgumentException('Enter valid SMTP credentials.');
            }
        }
        $values = [
            'smtp_global'=>'true', 'smtp_host'=>$host, 'smtp_port'=>(string)$port,
            'smtp_secure'=>$secure, 'smtp_auth'=>$authentication === 'password' ? 'true' : 'false',
            'smtp_username'=>$username, 'smtp_password'=>$password, 'smtp_from'=>$from,
            'smtp_from_name'=>$name, 'smtp_validate_certificate'=>'true',
        ];
        $this->db->beginTransaction();
        try {
            // Serialize concurrent saves, including the case where a setting has not been created yet.
            $this->db->exec('lock table v_default_settings in share row exclusive mode');
            foreach ($values as $key => $value) {
                $stmt = $this->db->prepare("select default_setting_uuid from v_default_settings where default_setting_category='email' and default_setting_subcategory=:key");
                $stmt->execute(['key'=>$key]);
                if ($stmt->fetchColumn()) {
                    $stmt = $this->db->prepare("update v_default_settings set default_setting_value=:value,default_setting_name=:type,default_setting_enabled=true
                        where default_setting_category='email' and default_setting_subcategory=:key");
                    $params = ['key'=>$key,'value'=>$value,'type'=>$key === 'smtp_port' ? 'numeric' : 'text'];
                } else {
                    $stmt = $this->db->prepare("insert into v_default_settings(default_setting_uuid,default_setting_category,default_setting_subcategory,default_setting_name,default_setting_value,default_setting_enabled,default_setting_order)
                        values(:id,'email',:key,:type,:value,true,100)");
                    $params = ['id'=>uuid(),'key'=>$key,'value'=>$value,'type'=>$key === 'smtp_port' ? 'numeric' : 'text'];
                }
                $stmt->execute($params);
            }
            $this->db->commit();
        } catch (Throwable $e) {
            if ($this->db->inTransaction()) $this->db->rollBack();
            throw $e;
        }
        settings::clear_cache();
    }

    /** Check the saved SMTP connection/authentication without sending a message. */
    public function checkConnection(): bool {
        if (!$this->canManage()) throw new RuntimeException('Outgoing mail administration permission is required.');
        $smtp = $this->transport();
        require_once PROJECT_ROOT.'/resources/phpmailer/class.phpmailer.php';
        require_once PROJECT_ROOT.'/resources/phpmailer/class.smtp.php';
        $mail = new PHPMailer();
        $mail->isSMTP();
        $mail->Host = $smtp['host'];
        $mail->Port = (int)$smtp['port'];
        if ($smtp['hostname'] !== '') $mail->Hostname = $smtp['hostname'];
        $mail->SMTPAuth = $smtp['auth'];
        $mail->Username = $smtp['username'];
        $mail->Password = $smtp['password'];
        $mail->SMTPSecure = $smtp['secure'] === 'none' ? '' : $smtp['secure'];
        $mail->SMTPAutoTLS = $smtp['secure'] !== 'none';
        $mail->Timeout = 10;
        $mail->SMTPDebug = 0;
        try {
            return $mail->smtpConnect();
        } finally {
            $mail->smtpClose();
        }
    }
}
