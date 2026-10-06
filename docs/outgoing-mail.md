# SMTP Outgoing Mail

Open **SMTP Outgoing Mail** from the OpenWeb PBX desktop, or visit https://call.openweb.co.za/app/smtp_settings/ as a platform administrator. Tenant administrators cannot view or change this global configuration.

Enter the SMTP hostname/IP, port, connection security, authentication method, and sender defaults, then select **Save outgoing mail server**. Saving makes this server the relay for all tenants, including direct system messages and queued voicemail/fax mail. Before the first save, the existing mail configuration remains in effect. SMTP provider details have not been supplied on this deployment, so the page initially shows **Awaiting configuration**.

**IP Authentication** requires no username or password. Add **173.214.174.68** to your relay's IP allowlist, select IP Authentication, and save. Both the local interface and outbound public IPv4 address were verified as this address on 2026-10-06. The page displays the address of the server handling the request and provides a copy button. IP authentication and TLS are independent; choose the security mode your provider requires.

**Username & password** enables SMTP authentication. Saved passwords are never populated into the form. Leaving the password blank retains the existing secret only when the server and username match the saved credential configuration. Switching to IP Authentication clears the stored SMTP username and password. Changing to a different server or username requires a new password.

Connection options are STARTTLS (`tls`, commonly port 587), TLS/SSL (`ssl`, commonly port 465), and no encryption (`none`, commonly port 25 for a permitted relay). Certificate validation remains enabled for encrypted connections. Application-supplied sender addresses remain supported; the page's sender address and name provide defaults.

**Test SMTP connection** checks the saved server connection, TLS, and SMTP authentication. It sends no email. A successful connection does not confirm permission to relay a particular message or final inbox delivery; the SMTP provider must also allow this server and the sender addresses used by the PBX.

## Installation and operations

The page and mail transport use the native `v_default_settings` email fields. A `smtp_global` flag controls precedence. Once enabled, the shared PHP `email` class reads the global SMTP configuration directly from the database; domain/template/user relay overrides cannot replace it. The existing email queue service sends through the same PHP mail transport. Database storage and backups must remain private because the native SMTP password setting stores the credential for mail delivery.

Deploy the new page, `resources/classes/outgoing_mail.php`, the updated `resources/classes/email.php`, and desktop assets. Register the permission and menu using:

```sh
runuser -u postgres -- psql -d fusionpbx -v ON_ERROR_STOP=1 < app/smtp_settings/resources/install.sql
```

The migration can be rerun and does not change an existing configured relay. The page requires `smtp_settings_manage` or the existing global `default_setting_edit` permission, with authentication and CSRF checks. SMTP Outgoing Mail is included in the superadmin menu. Reload PHP-FPM when deploying updated assets or restoring settings outside the application to clear cached native settings.

Operator backups made before this feature are under `/var/backups/openwebpbx/smtp-setup`. Test settings and temporary accounts were removed after validation. No actual provider relay has been configured or tested.

## Verification

```sh
python3 tests/smtp_transport_integration.py
```

This starts a loopback SMTP sink and runs the real PHP mail class against a temporary PostgreSQL schema. No mail leaves the server. The test captures SMTP traffic and verifies that IP mode sends no AUTH command, credential mode authenticates with the fixture, both messages are delivered to the local sink, domain relay overrides cannot replace the global server, passwords remain masked/retained appropriately, and IP mode clears stored credentials. It also covers permissions and input validation. The PHP integration runner refuses web execution.

Live Chromium checks covered the desktop launcher/embedded page, IP mode, saving/reloading, the connection check against a local fixture, mobile layout, light/dark appearance, and zero console errors/warnings. Live HTTPS requests verified CSRF rejection and denied global settings access to a temporary tenant administrator.
