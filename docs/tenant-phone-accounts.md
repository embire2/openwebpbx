# Tenant addresses and phone accounts

Candidate implementation after 1.0.16. Deployment and final acceptance are recorded in AGENTS.md; this guide does not announce a published candidate.

## Connect a phone

Your administrator supplies your company's `name.openwebpbx.com` address. Open **OpenWebPBX Free Phone**, choose manual sign-in, enter that name, your extension and your app password. The app uses HTTPS for sign-in and obtains its secure calling settings automatically.

Alternatively, scan the administrator's QR code, or open the `.openwebpbx` file attached to your welcome message. Confirm the company server shown by the app. If your mail reader does not offer the phone app for an attachment, save it and choose **Import setup file** in the app. Manual sign-in does not require a camera.

Screen QR codes last ten minutes. Welcome invitations last 48 hours and work once; a new invitation replaces unused older invitations. Both the inline image and attached file contain a connection secret. Do not forward or publish them. The welcome email does not contain your app password or your desk-phone SIP password.

## More than one company

Open **Settings → Accounts** to add, select, rename, reconnect or remove an account. Up to ten accounts can be saved. The selected account supplies the keypad, contacts, voicemail and outgoing calls. Other connected accounts can still receive calls, and incoming calls show their account. Call records remain associated with the account used for that call.

Account changes wait until calls have ended. Removing an account revokes that phone connection and removes its local details after server confirmation. If the server is unavailable, a second explicit confirmation can remove only the local profile; ask your administrator to revoke its server connection later. Removal does not delete your extension, server records or other saved accounts. Use **Remove my data** for the separate account-deletion request route.

## Change your app password

Use **Settings → App password** for the selected account. Enter the current password and your new password. The new password must have 12–128 characters and no line breaks. This changes the app sign-in password; it preserves the restored desk-phone authentication details and the current phone's calling credentials.

Other phone connections for that extension are revoked for future access. An established call is allowed to finish. Your other tenant accounts are unaffected. A freshly QR-connected phone with no app password may set its first password during the first ten minutes; otherwise ask your administrator for a new invitation or password reset.

## Administrator setup and welcome messages

When adding a user, enter their email address and, for manual sign-in, choose an app password. The welcome option queues the inline QR and setup attachment through the instance's global SMTP server. **Phone Provisioning** provides resend/reset and delivery status. Phone setup permissions are required for private invitations and app-password administration.

Queued means waiting for the outgoing server. Accepted means the SMTP server accepted the message; it does not prove inbox delivery. Failed or expired invitations need attention or a new invitation. Tenants do not configure their own mail transport.

## Domain custody and installations

Open ISP cc operates the central name registry and holds the `openwebpbx.com` domain. An installation proves control of its configured public HTTPS hostname using a private instance key. The registry reserves each tenant/service name and configures DNS without giving installations the central DNS credential. A conflicting requested name receives a stable suffix. Additional PBX services receive separate names so overlapping extension numbers remain unambiguous.

Each instance obtains and renews certificates for its assigned names. Names become available only after DNS, the local certificate and exact tenant mapping are ready. During an outage or certificate delay, existing canonical-address QR setup remains available; manual tenant-address login waits for its address to become ready. There is no insecure HTTP or certificate-validation fallback.

Tenant aliases change the user-facing HTTPS address. They do not rewrite restored SIP realms, authentication IDs or passwords. Use the phone migration guide for physical desk phones rather than changing their SIP settings from this app guide.

The instance key and lease revision are included in private instance backups. A restored server must verify its actual local certificate before advertising an alias. Moving an alias to another canonical server is an explicit ownership operation with the current revision; old and restored copies cannot silently move the name back and forth. Disabled names remain reserved pending custodian review.

The Debian installer and updater include automatic name and certificate setup. Windows source includes a scheduled worker and IIS integration, but native Windows qualification and automatic activation through the older 1.0.13 updater remain open; no new Windows release is announced here.

The initial central service limits each installation to 50 aliases. Certificates are batched and reused. Public certificate-authority limits apply across the registered domain; deployment at larger scale needs a verified capacity arrangement. The broker does not receive call audio, recordings, voicemail or phone passwords.

## Submission links

The app opens [Terms](https://openwebpbx.com/terms), [Privacy](https://openwebpbx.com/privacy) and [Account and data deletion](https://openwebpbx.com/delete) in the external browser from onboarding and Settings. See the [Google Play audit](google-play-audit-1.0.17.md) for the separate submission and device-testing requirements.
