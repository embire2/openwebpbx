# Server migration — 8 November 2026

## Follow-up — 9 November

Switchtel confirms that it has no IP blocks on the new address. Both stored and
loaded gateway configuration use `sip.switchtel.co.za:5060` over UDP, with the
new 139.84.227.194 advertised address. ICMP 30-hop and UDP/TCP 25-hop traces receive
replies through hop 5, then none. One unauthenticated OPTIONS probe also receives
no answer in 5 seconds. These observations do not establish a block or its owner.
The private owner report is `/root/SWITCHTEL-TRACERT-2026-11-09.txt`; registration
remains FAIL_WAIT. No provider credentials or routing were changed.

The 500 GB volume now supports an actual full PBX/media backup. Its completed
3,098,453,525-byte encrypted archive and authenticated HTTPS download match.
Independent replacement recovery is documented in the
[9 November qualification](backup-recovery-2026-11-09.md). Production is not
restored or stopped for that test; all seven desk phones remain Reachable.

## Final verified state — updated 19:33 SAST

| Item | Result |
|---|---|
| Active primary | `139.84.227.194`, hosted 1.0.25, data on the 500 GB volume |
| Website DNS | Scheduled change **completed at 19:30 SAST**; authoritative, Cloudflare and Google DNS verify the new IP |
| Website HTTPS/content | Homepage, www, legal pages, API docs and wizard pass; 33 disk files and 32 public resources match |
| Desk phones | `1049–1051`, `1055–1058`: all registered under OpenWebPBX and Reachable |
| Services | All 19 application/security services active; generations unchanged during final observation |
| Mail | MX/mail remain on `129.232.187.189`; Google relay accepts verified-TLS checks without sending a message |
| Old host | User powered it off; retained for recovery, not deleted or restarted |
| Switchtel | **Still disconnected**; provider/new-IP network investigation required |
| Real call audio | User confirms one incoming and one outgoing call with sound both ways; not attributed specifically to Switchtel |

The infrastructure and website move is verified. Full telephony acceptance
remains open for Switchtel; no broader success is inferred.


The active primary is now `139.84.227.194`, running Debian 13 and hosted
OpenWebPBX 1.0.25. The single-writer handover completed at 14:30 UTC / 16:30 SAST
on 8 November. The user has now powered off the former server, `173.214.174.68`,
which remains a recovery copy and no longer forwards requests. Checks of its
SSH and HTTPS ports time out. Its writer-retirement guards remain in place.
Do not power it on, deploy to its workspace or restart its writers as part of
ordinary production work. This verification session runs on the new server.

This migration does not publish a new installer or change signed update feeds.
Public Debian/Windows 1.0.23 and Android 1.0.19 remain unchanged.

## Storage

The newly attached 500 GB volume is mounted by filesystem UUID at
`/srv/openwebpbx`. The development checkout is available at `/root/openwebpbx`;
`/root/fusionpbx` is a compatibility link for existing development sessions.
Persistent bind mounts put the web application, native services, PostgreSQL,
recordings, voicemail, prompts, recovery archives, Codex configuration and PBX
configuration/certificates on this volume. Application units require the volume.
The operating system and its distribution packages remain on the boot disk.

The destination has 2 GB RAM and swap. Increase RAM to at least 4 GB for Claude
Code's documented minimum; installation and a smoke test do not qualify PBX or
development capacity under load. The attached volume had about 311 GB available
after the historical files were copied.

## Database and identity

The actual application uses local PostgreSQL 18.6, database `fusionpbx`, rather
than the separate database configured at `userza1004.openweb.direct`. Both the
PBX and `openweb_domain_registry` databases and PostgreSQL roles must migrate.
Preserve encryption keys, SIP credentials, QR enrollment, tenant and installation
identities. The remote PostgreSQL server is not modified.

The final copy was taken with old writers stopped. All 202 PBX and five registry
public tables match, normalizing only two explicit RTP public-address rows from
the old address to the new address. The target also explicitly verifies zero
old and two new RTP address rows. Dumps preserve schema, roles, secrets and
identities. Final runtime, media, configurations, sessions and operational state
were copied before new workers were activated. Never restart old producers
without a separately planned recovery that accounts for new-primary writes.

## DNS and external services

The cPanel API controls `openwebpbx.com`. Use the stable cPanel endpoint
`https://cpanel.openwebpbx.com:2083`, whose address stays at the original hosting
provider. Do not use the migrating website apex as the cPanel API address.

Before migration, the apex MX and mail CNAME depended on the website address.
They were separated before cutover: `mail.openwebpbx.com` is now an A record for
`129.232.187.189`, MX points to that mail host, and calendar/contact SRV targets
remain on the original hosting service. Mail TXT and unrelated records were
preserved. The old reference TTL is the reason for the website's 19:30 window.

DNS status at the handover:

- `openwebpbx.com` A → `139.84.227.194` **completed at 19:30 SAST on
  8 November**. The scheduled service starts at 19:30:00, exits successfully at
  19:30:01, and the independent DNS/HTTPS/content verifier passes at 19:30:09.
  Both authoritative nameservers and Cloudflare/Google resolve the new address.
  `www` follows its CNAME. Mail and all unrelated zone records are preserved.
- `call.openweb.co.za` A → `139.84.227.194` is confirmed. The existing tenant
  CNAMEs follow it, and trusted public HTTPS succeeds without the old host.
  No AAAA was present at handover.
- `sip.openwebpbx.com` and `*.sip.openwebpbx.com` A now point to `139.84.227.194`.
- Existing tenant/registry CNAMEs pointing to `call.openweb.co.za` follow that
  change. Windows node addresses and unrelated tenant servers stay unchanged.

The user confirmed Google's IPv4 whitelist change. A STARTTLS relay check gets
250 for sender and recipient, followed by RSET/QUIT without sending a message.
Eight of nine trunks register on the new primary. **Switchtel is outstanding**:
outgoing REGISTER packets advertise the correct new address, but no response
arrives. Identical unauthenticated OPTIONS checks receive 401 from the old IP
and no response from the new IP. This indicates an upstream address restriction
or path issue; it does not prove the exact policy. The user has been asked to
approve the new IP in Switchtel or provide settings access. Do not claim that
trunk or its numbers are working until verified.

Cached phone DNS may require expiry or a handset/base restart. All seven desk
phones now register to this host and report Reachable. Keep the old machine
powered off as a recovery copy until phone/carrier acceptance is complete.
The temporary HTTPS bridge used verified TLS at depth four for the retained
Let's Encrypt chain. It is no longer active after shutdown. The new server's
special trust for the old host's forwarded client headers has been removed.

## Development continuation

Codex configuration, credentials and local session/history files are copied
privately, outside the public web root. SQLite history requires a consistent
snapshot; copying an active database without its WAL is not sufficient.
An available chat export and handover are retained privately on the destination.
Do not commit chat exports, authentication files, `.env`, keys or database dumps.
Copied local history does not move an active ChatGPT connection to another host.

Codex 0.167.0 is installed and an actual ephemeral, read-only API request passes
on the new server. Claude Code 2.1.311 is installed separately; no Claude login
was available to transfer, so its first use still requires sign-in. Private
continuation instructions are in `/root/OPENWEBPBX-HANDOVER.md` on the new host.
Read this record, `AGENTS.md` and the Debian-to-Windows ledger before development.

## Acceptance status

The single-writer infrastructure transition passes. Preparation has 42 trusted
HTTPS checks, 24 browser checks and the complete final table comparison. Another
24 actual browser checks pass after activation. The separate native engine lab
passes authenticated UDP, wrong-password refusal, trusted TLS and decoded
two-way audio between two fictional loopback users. Public UDP STUN passes.
These are not new physical-phone or carrier-audio acceptance results.

All four historical-state transfer shards finish with exit zero. A later
optional global hardlink-reconciliation walk was stopped before activation;
cross-shard inode identity is not claimed. No archive receiver overlaps the
new workers. Historical evidence and old files remain retained privately.

Switchtel investigation and real-phone/carrier audio confirmation remain explicit follow-up
items. The operation's evidence is private; never publish credentials, source
database dumps, development authentication or chat archives.

Seventeen required services are active and six critical paths are verified on
the data volume; `findmnt --verify` passes. Key-only SSH was preserved and a
fresh public-key connection passes. Scheduled malware/audit monitoring is
enabled; explicit scan roots cover the new bind-mounted application directories.
The new-host persistence reference retains the old reference separately. No
full-system malware scan or reboot qualification is claimed. Seven private
signing files match the source hashes and modes.

The first post-cutover registration observation had three entries owned by the
new hostname and four cached entries under the former hostname. The later
post-shutdown observation has all seven owned by `OpenWebPBX` and Reachable:
International Lighting `1049–1051` and Global `1055–1058`. Registration and ping
success do not prove human two-way audio. Initial proxy HTTPS returned 502 because its default certificate
verification depth was too short; the explicit-depth correction retains TLS
verification and subsequent HTTPS succeeds. The first post-browser report's
old descriptive scope label is retained separately; corrected scope metadata
does not change its actual 24 passing checks.

The old instance's two daily backup/maintenance scripts and two application cron
entries are retired in place, and its certificate timer is disabled. The new
certificate timer is active. Original daily scripts retain exact source bytes
under private scheduled hooks on the new machine, with root-only cron wrappers
that refuse a missing data volume. The additional 48 MB legacy backup history
is on the data volume too. Keep `/srv/openwebpbx/migration`: it contains live
certificate/DNS renewal and scheduled hooks, in addition to evidence.

## Historical DNS confirmation and manual shutdown handover

- call.openweb.co.za now resolves to 139.84.227.194; openweb and domains tenant CNAMEs follow it. Trusted public HTTPS passes for both portals and registry /health. Primary Core25 is Running; seven critical services have zero restarts. Latest registration ownership is {"OpenWebPBX": 7}; 8/9 gateways are registered. A transient additional gateway retry recovered; Switchtel remains the pending provider.
- The user states Switchtel responds only after the OLD MACHINE is powered off. Old FreeSWITCH/Core/updater/registry/PostgreSQL are already stopped; nginx still runs. The user is to validate their new key-based SSH/Codex session first, then POWER OFF ONLY 173.214.174.68 in the hosting panel. Do not delete it or power off 139.84.227.194. Shutdown has NOT been performed by this agent.
- The new server independently schedules the website A change at 19:30 SAST on 8 November. It uses cPanel at129.232.187.189, so it does not depend on the old173 host. Confirm actual DNS/result after that time; do not report scheduled work as complete.
- Continue production work locally on the NEW server at /root/openwebpbx. The existing browser/tool workspace is still on old173 and will lose execution access when that host stops. Codex resume checkpoint and private human history are copied; current handover/AGENTS status supersede older pending-DNS notes in the archived conversation. After shutdown verify Switchtel, refresh any stale phone registration, perform real incoming/outgoing two-way-audio checks and retain the powered-off recovery host until accepted.


## Post-shutdown verification — 8 November

This session runs locally on `OpenWebPBX`, `/root/openwebpbx`. The user confirmed
that the old machine is off; independent TCP checks of its ports 22 and 443 time
out. All 17 application services plus auditd and Fail2Ban are active. The seven
critical service generations remain stable with zero restarts. Six critical
paths are on the attached data volume and fstab validates. Timezone is
Africa/Johannesburg and NTP reports synchronized.

The initial Fail2Ban failure was a copied file-log configuration referring to
missing auth.log/syslog files. The first correction addressed the stock `sshd`
jail, but the copied custom `ssh` jail still failed validation; that failed
attempt is retained. The final journal configuration passes and all five
previously enabled jails run. SSH actions are limited to TCP 22 and web actions
to TCP 80/443, replacing inherited all-port actions. SIP jails remain disabled;
a web or SSH login failure cannot block desk-phone signalling or audio.

The exact temporary migration SSH key was removed after administration moved
to the new machine. The owner's Nova key remains. The security reference was
updated only for that reviewed, exact authorized_keys change, with the previous
reference retained; the guard reports no_change_detected. No ports were closed.

All seven phones repeatedly report Reachable under the new hostname. Eight of
nine gateways register; one additional short retry recovered during observation.
Switchtel is still FAIL_WAIT after the old host was powered off and after a
scoped registration refresh. Primary and secondary Switchtel UDP OPTIONS probes
receive no response, and TCP checks on 5060/5061 time out. No credentials or call
routes were changed. Provider/new-IP network-path investigation is outstanding;
shutdown alone has not solved it. The user has been asked for that action and
for an incoming/outgoing human audio check; no answer is assumed.

After shutdown, trusted public HTTPS succeeds for both portals and registry
health. The SMTP relay again accepts MAIL and RCPT over verified STARTTLS with
RSET/QUIT and no DATA. All 33 website files match the copied inventory. Website
DNS and live HTTPS/content verification completed successfully at 19:30 SAST.

## Final closure evidence

The scheduled website service actually ran and exited zero; this is no longer
a scheduled-only claim. Independent verification covers 28 authoritative/public
DNS answers, all 33 on-disk website files, 32 exact public HTTPS resources and
seven canonical/legal/API/wizard routes served from the new IP. No unrelated
DNS records or mail endpoints moved with the apex.

Twenty-six monitoring samples over approximately 21 minutes retain healthy core
services and all seven reachable phones. Short REGISTER → REGED transitions on
the other trunks are observed, including recovery within about three seconds;
they are not relabelled as Switchtel failures. Final gateway state is eight
registered and Switchtel FAIL_WAIT. The original provider setup email confirms
the configured registrar. The provider's own Client Zone also times out from
the new IPv4; no portal login, password reset, support message or financial
action was submitted. The temporary extracted credential copy was removed.
The exact upstream restriction or route problem is not established.

A new encrypted database/configuration checkpoint verifies 328 files in 6.114
seconds (9,821,380 bytes). It excludes media and the separate registry database;
no restore was run. Its password and archive remain root-private. The initial
operator wrapper incorrectly requested a ten-second lock wait; the product
refused it before archive creation. That failure remains recorded, and a
separate correct five-second admission succeeds without changing product limits.

Current evidence is under the private closure directory referenced by
`/srv/openwebpbx/migration/active-closure-path.txt`, including
`migration-closure.safe.json` and `website-final-acceptance.safe.json`.
AGENTS.md and the private handover reflect this result. Keep the old host off
and retained. Public installers/releases/feeds remain unchanged.

## User audio confirmation and provider credential check

The user subsequently confirms both controlled incoming/outgoing calls work
with sound both ways. This is human audio evidence for the reported calls,
not proof of calls through Switchtel or individual testing of all seven phones.
Their supplied Switchtel username, auth ID and password match the configured
gateway exactly; registration and the gateway remain enabled. No credentials
or routes were changed. A password-free support request is prepared privately;
sending it is awaiting explicit authorization. Switchtel remains the only
outstanding connection issue.
