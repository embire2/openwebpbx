# SMTP Outgoing Mail

Open **SMTP Outgoing Mail** from the OpenWeb PBX desktop, or visit https://call.openweb.co.za/app/smtp_settings/ as a platform administrator. Tenant administrators cannot view or change this global configuration.

Enter the SMTP hostname/IP, port, connection security, and sender defaults, then select **Save outgoing mail server**. This is the only outgoing relay for the instance: all tenants use it for direct system messages and queued voicemail/fax mail. Tenants do not need their own outgoing mail server. Until a complete global server is saved, direct sends return **Configure global outgoing mail**, while queued messages stay **waiting** without consuming delivery retries. There is no tenant or local-mail-server fallback. SMTP provider details have not been supplied on this deployment, so the page initially shows **Awaiting configuration**.

**My IP address is whitelisted** sends without SMTP AUTH, a username, or a password. Add **173.214.174.68** to your relay's IP allowlist, check this box, and save. Both the local interface and outbound public IPv4 address were verified as this address on 2026-10-06. The page displays the address of the server handling the request and provides a copy button. The checkbox records your relay's configuration; it does not add the address to your provider's allowlist. IP authentication and TLS are independent; choose the security mode your provider requires.

Leave **My IP address is whitelisted** unchecked to enable SMTP authentication using a **Username** and **Password**. Saved passwords are never populated into the form. Leaving the password blank retains the existing secret only when the server and username match the saved credential configuration. Checking the whitelist box clears the stored SMTP username and password. Changing to a different server or username requires a new password. Both modes can also be saved without JavaScript. Existing integrations that submit `authentication=ip` or `authentication=password` remain supported; when present, the checkbox field determines the mode.

Connection options are STARTTLS (`tls`, commonly port 587), TLS/SSL (`ssl`, commonly port 465), and no encryption (`none`, commonly port 25 for a permitted relay). Certificate validation remains enabled for encrypted connections. Application-supplied sender addresses remain supported; the page's sender address and name provide defaults.

**Test SMTP connection** checks the saved server connection, TLS, and SMTP authentication. It sends no email. A successful connection does not confirm permission to relay a particular message or final inbox delivery; the SMTP provider must also allow this server and the sender addresses used by the PBX.

## Installation and operations

The page and mail transport use the native `v_default_settings` email fields. The `smtp_global` flag records that an administrator saved a global server; an absent/false flag or incomplete configuration means outgoing mail must wait. It is not a switch to enable tenant relays. The shared PHP `email` class reads only the global SMTP transport directly from the database; domain/template/user relay overrides cannot replace it. The existing email queue service sends through the same PHP mail transport, including FreeSWITCH-generated notifications. Its worker preserves waiting messages, attachments and retry counts until global configuration is complete, then resumes delivery on the next run. Global SMTP wire debugging is disabled even if a caller or queue job requests it, because the bundled mail library includes encoded authentication credentials in that output. Database storage and backups must remain private because the native SMTP password setting stores the credential for mail delivery.

Deploy `app/smtp_settings/`, `resources/classes/outgoing_mail.php`, `resources/classes/email.php`, and `app/email_queue/resources/jobs/email_send.php`. Register the permission and menu using:

```sh
runuser -u postgres -- psql -d fusionpbx -v ON_ERROR_STOP=1 < app/smtp_settings/resources/install.sql
```

The migration can be rerun and does not change an existing configured relay. The page requires `smtp_settings_manage` or the existing global `default_setting_edit` permission, with authentication and CSRF checks. SMTP Outgoing Mail is included in the superadmin menu. Reload PHP-FPM when deploying updated assets or restoring settings outside the application to clear cached native settings.

Operator backups made before this feature are under `/var/backups/openwebpbx/smtp-setup`. Test settings and temporary accounts were removed after validation. No actual provider relay has been configured or tested.

## Verification

```sh
python3 tests/smtp_transport_integration.py
```

This starts a loopback SMTP sink and runs the real PHP mail class against a temporary PostgreSQL schema. No mail leaves the server. It configures a working tenant relay and proves that neither an absent nor incomplete global configuration sends through it. A message is inserted through the real PHP queue API, processed twice by the native CLI job while unconfigured, and remains waiting with its retry count unchanged. After a global server is saved, the original message is delivered by the same native job. Wire capture counts AUTH commands: legacy IP mode and the whitelist checkbox send zero AUTH commands, while credential mode authenticates with the fixture. Exactly three intended messages are captured locally with the global sender defaults. Checks also cover checkbox validation and precedence, masked/retained/cleared credentials, disabled SMTP debug output, permissions and input validation. The PHP integration runner refuses web execution and removes its private test schema.

Earlier live checks covered the desktop launcher, IP mode saving/reloading and connection testing against a local fixture. On 2026-10-08, live Chromium checks passed for the whitelist checkbox, hidden/disabled credentials and submitted fields, the global configuration notice, 390px layout and the existing desktop light/dark theme contract, with zero console errors/warnings. Live HTTPS requests rejected missing CSRF tokens and denied global settings GET/POST access to an ordinary tenant administrator. No actual provider relay or inbox delivery was tested.
