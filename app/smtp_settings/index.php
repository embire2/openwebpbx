<?php
require_once dirname(__DIR__, 2).'/resources/require.php';
require_once PROJECT_ROOT.'/resources/check_auth.php';
$mailSettings = new outgoing_mail;
if (!$mailSettings->canManage()) { http_response_code(403); exit('Access denied.'); }
header('Cache-Control: no-store');
header('Referrer-Policy: no-referrer');
$escape = fn($value) => htmlspecialchars((string)$value, ENT_QUOTES, 'UTF-8');
$error = '';
if ($_SERVER['REQUEST_METHOD'] === 'POST') {
    try {
        if (!(new token)->validate('/app/smtp_settings/index.php')) {
            http_response_code(403);
            throw new RuntimeException('Your form expired. Refresh the page and try again.');
        }
        if (($_POST['action'] ?? '') === 'save') {
            $mailSettings->save($_POST);
            $_SESSION['smtp_notice'] = 'Outgoing mail settings saved for all tenants.';
        } elseif (($_POST['action'] ?? '') === 'check') {
            if (!$mailSettings->checkConnection()) {
                throw new RuntimeException('The SMTP connection or authentication failed. Check the server, port, security, and relay permissions.');
            }
            $_SESSION['smtp_notice'] = 'SMTP connection succeeded. No email was sent. Your relay must also permit messages from this server.';
        } else {
            throw new InvalidArgumentException('Choose an action.');
        }
        header('Location: /app/smtp_settings/');
        exit;
    } catch (PDOException $e) {
        error_log('OpenWeb PBX outgoing mail configuration failed: '.$e->getCode());
        $error = 'The mail settings could not be saved. Please try again.';
    } catch (Throwable $e) {
        $error = $e->getMessage();
    }
}
$saved = $mailSettings->view();
$values = $saved;
$authentication = filter_var($saved['smtp_auth'], FILTER_VALIDATE_BOOLEAN) ? 'password' : 'ip';
if ($error && ($_POST['action'] ?? '') === 'save') {
    foreach (['smtp_host','smtp_port','smtp_secure','smtp_username','smtp_from','smtp_from_name','smtp_reply_to'] as $key) {
        $values[$key] = $_POST[$key] ?? $values[$key];
    }
    if (array_key_exists('smtp_ip_whitelisted', $_POST)) {
        $authentication = filter_var($_POST['smtp_ip_whitelisted'], FILTER_VALIDATE_BOOLEAN) ? 'ip' : 'password';
    } else {
        $authentication = $_POST['authentication'] ?? $authentication;
    }
}
$active = $saved['is_configured'];
$notice = $_SESSION['smtp_notice'] ?? '';
unset($_SESSION['smtp_notice']);
$sourceIp = filter_var($_SERVER['SERVER_ADDR'] ?? '', FILTER_VALIDATE_IP) ?: 'Unavailable';
$formToken = (new token)->create('/app/smtp_settings/index.php');
$csrf = function() use ($formToken, $escape) {
    echo '<input type="hidden" name="'.$escape($formToken['name']).'" value="'.$escape($formToken['hash']).'">';
};
$document['title'] = 'SMTP Outgoing Mail';
require_once PROJECT_ROOT.'/resources/header.php';
?>
<link rel="stylesheet" href="/app/smtp_settings/mail.css?v=2">
<script src="/app/smtp_settings/mail.js?v=2" defer></script>
<main class="mail-workspace">
    <header class="mail-heading">
        <div><span class="mail-eyebrow">OPENWEB PBX · SYSTEM</span><h1>SMTP Outgoing Mail</h1><p>One outgoing mail server for every tenant and PBX service.</p></div>
        <span class="mail-status <?= $active ? 'active' : '' ?>"><?= $active ? 'Global server configured' : 'Awaiting configuration' ?></span>
    </header>
    <?php if ($notice): ?><div class="mail-message" role="status"><?= $escape($notice) ?></div><?php endif; ?>
    <?php if ($error): ?><div class="mail-message error" role="alert"><?= $escape($error) ?></div><?php endif; ?>
    <?php if (!$active): ?><div class="mail-message" role="status">Configure global outgoing mail to enable emails for this instance. Queued messages wait until a server is saved.</div><?php endif; ?>
    <aside class="mail-ip-card"><span class="mail-icon"><i class="fa-solid fa-network-wired"></i></span><div><strong>This server's IP address</strong><code id="smtp-source-ip"><?= $escape($sourceIp) ?></code><p>For IP authentication, add this address to your SMTP relay's allowed senders.</p></div><button type="button" class="mail-button" id="copy-source-ip">Copy IP</button></aside>
    <form method="post" class="mail-card" id="smtp-settings-form" autocomplete="off">
        <?php $csrf(); ?><input type="hidden" name="action" value="save">
        <h2>Server connection</h2>
        <div class="mail-grid">
            <label class="mail-wide">SMTP server<input name="smtp_host" value="<?= $escape($values['smtp_host']) ?>" required maxlength="253" placeholder="smtp.example.com"><small>Hostname or IP address.</small></label>
            <label>Port<input type="number" name="smtp_port" value="<?= $escape($values['smtp_port']) ?>" min="1" max="65535" required></label>
            <label>Connection security<select name="smtp_secure"><?php foreach (['tls'=>'STARTTLS','ssl'=>'TLS / SSL','none'=>'None'] as $key=>$label): ?><option value="<?= $key ?>" <?= $values['smtp_secure'] === $key ? 'selected' : '' ?>><?= $label ?></option><?php endforeach; ?></select><small>Common ports: STARTTLS 587, TLS 465, relay 25.</small></label>
        </div>
        <h2>Authentication</h2>
        <input type="hidden" name="smtp_ip_whitelisted" value="0">
        <label class="mail-checkbox"><input type="checkbox" name="smtp_ip_whitelisted" id="smtp-ip-whitelisted" value="1" <?= $authentication === 'ip' ? 'checked' : '' ?> aria-describedby="ip-authentication-hint"><span>My IP address is whitelisted</span></label>
        <p class="mail-hint" id="ip-authentication-hint">Check this when your mail provider allows this server's IP address. OpenWeb PBX sends without SMTP AUTH, a username, or a password. Leave it unchecked to use a username and password. Connection security is a separate choice.</p>
        <div class="mail-grid" id="smtp-credentials">
            <label>Username<input name="smtp_username" value="<?= $escape($values['smtp_username']) ?>" maxlength="256" autocomplete="off"></label>
            <label>Password<input type="password" name="smtp_password" value="" maxlength="1024" autocomplete="new-password" data-password-stored="<?= $saved['has_password'] ? 'true' : 'false' ?>"><small><?= $saved['has_password'] ? 'Leave blank to keep the saved password for this server and username.' : 'Enter your SMTP password.' ?></small></label>
        </div>
        <h2>System sender</h2>
        <div class="mail-grid">
            <label>From email address<input type="email" name="smtp_from" value="<?= $escape($values['smtp_from']) ?>" required maxlength="254" placeholder="hello@example.com"></label>
            <label>From name<input name="smtp_from_name" value="<?= $escape($values['smtp_from_name']) ?>" maxlength="128" placeholder="OpenWebPBX System"></label>
            <label class="mail-wide">Reply-to email address<input type="email" name="smtp_reply_to" value="<?= $escape($values['smtp_reply_to']) ?>" maxlength="254" placeholder="hello@example.com"><small>Optional. Leave blank to send replies to the From address.</small></label>
        </div>
        <div class="mail-actions"><p>Every outgoing email uses this server, From address, name, and reply address, including voicemail, fax, and system notifications.</p><button type="submit" class="mail-button primary">Save outgoing mail server</button></div>
    </form>
    <section class="mail-card mail-check"><div><h2>Check the saved connection</h2><p>Verify the connection and authentication without sending an email.</p></div><form method="post"><?php $csrf(); ?><input type="hidden" name="action" value="check"><button type="submit" class="mail-button" <?= $active ? '' : 'disabled' ?>>Test SMTP connection</button></form></section>
</main>
<?php require_once PROJECT_ROOT.'/resources/footer.php'; ?>
