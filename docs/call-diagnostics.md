# Call progress and PBX audio

The hosted OpenWeb tenant now explicitly keeps both call legs' audio through the PBX. Direct media and transparent media proxying are disabled for ordinary restored calls and their new bridge legs. RTP address learning remains enabled; existing encryption and recording choices are retained.

The PBX generates audible ringback when a destination sends a ringing response. It does not answer the call to do this. Genuine early audio from a provider, such as an announcement, continues to pass through. Recording still waits for answer, so an unanswered ringing call creates no recording.

## Incoming calls

On 19 October 2026, all three already-enabled hosted providers had disabled restored incoming rules. The owner requested acceptance of incoming calls on enabled connections. Their existing incoming rules were activated for **Porta Bizvoip International Lighting**, **OpenWeb Porta** and **International Lighting Incoming**. Existing numbers, destinations, office hours, provider credentials, registration and disabled providers were preserved. This did not enable Call Me Back on any number.

Turning a provider on now also activates its saved incoming numbers; turning it off closes those routes. Ordinary edits preserve individually disabled numbers. The provider handover action can repair incoming rules for an already-connected provider without restarting its registration. These remain explicit owner actions and retain provider ownership, source-address and assigned-number checks. A provider being connected does not authorise calls to another tenant or to arbitrary undeclared numbers.

Closed-hours destinations and member availability still apply. International Lighting's restored ring group excludes members whose automatic **Out of office** profile disables ring-group calls, then follows its saved fallback. Allowing direct internal calls after hours does not change that separate group policy.

## Private diagnostics

The Debian helper is `packaging/debian/call-diagnostics.py`. Installation and upgrades stage it and its service template under `/opt/openwebpbx/tools`; recording diagnostics is an explicit operator action, not an enabled-by-default service.

To start a one-hour trace on an installed Debian server, as root:

```sh
install -m 0644 /opt/openwebpbx/tools/openwebpbx-call-diagnostics.service /etc/systemd/system/openwebpbx-call-diagnostics.service
systemctl daemon-reload
python3 /opt/openwebpbx/tools/call-diagnostics.py --enable --all-domains --minutes 60
systemctl start openwebpbx-call-diagnostics.service
```

Use `--domain <domain-uuid>` instead of `--all-domains` for a tenant trace. Unknown/unmatched incoming calls can lack a tenant identity, so instance-wide scope is needed to investigate those failures. The hosted diagnostic session was explicitly configured for eight hours on 19 October; the absolute expiry survives observer restarts. The maximum permitted session is 24 hours. Expiry stops collection; it does not erase retained diagnostic files.

Files are under `/var/log/openwebpbx-call-diagnostics/events.jsonl`, with four rotated copies and a 5 MiB limit per file. The directory is root-only and files are mode 0600. Configuration, including private event-socket access, is root-owned mode 0600 outside the web tree. The observer connects only to the local engine and cannot control calls.

The positive field allowlist records call/leg identifiers, tenant, routing stage, selected provider, progress/answer/failure, codec, network/media addresses, packet counters and audio policy. Outside numbers are masked; SIP Call-IDs are hashed. Raw SIP, passwords, authentication headers, SDP, encryption keys, DTMF and audio are excluded. No web log-download endpoint is exposed.

```sh
systemctl status openwebpbx-call-diagnostics.service
tail -n 50 /var/log/openwebpbx-call-diagnostics/events.jsonl
systemctl stop openwebpbx-call-diagnostics.service
```

## Verification and limits

Actual disposable software-phone calls on the final hosted code decoded 3.18 seconds of generated ringback before answer or rejection, with 400/450 Hz energy fraction 0.99963. Both answered directions decoded their independent test tones at 0.9998. A separate real early-media tone passed through before answer at 0.9820 and retained two-way answered audio. Native events confirmed disabled bypass/proxy settings on both legs and nonzero media packet counters. An unanswered call left existing recording rows unchanged.

Six diagnostic framing/redaction/rotation/expiry controls, 48 isolated PostgreSQL provider controls, 66 restore/provider controls, 218 call-policy decisions, 32 recording controls, media-policy controls, 12 STUN installer controls and 17 updater checks passed. The updater retains its existing ResourceWarning. The first observer attempt required the existing configuration API's explicit null default; the custom event subscription then required its explicit subclass. Test-harness dependency and reused-recording-baseline failures were corrected before final acceptance; they are not passed product cases.

This qualifies hosted/source behavior and controlled software calls. The owner's Android retry, physical W60B handset ringing, answered customer/carrier audio and restrictive-network coverage remain separate checks. Public core/APK downloads and the Android minimum remain **1.0.16**; no complete new installer, Windows or Play release is claimed.

FreeSWITCH documents [media modes](https://developer.signalwire.com/freeswitch/media-and-codecs/handling/) and the relevant [channel variables](https://developer.signalwire.com/freeswitch/reference/channel-variables/). Those protocol settings do not establish a physical handset test.
