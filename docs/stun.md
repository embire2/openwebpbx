# Optional Debian STUN service

**Hosted OpenWeb activation —19 October2026:** `openweb.sip.openwebpbx.com:3478` now answers UDP STUN. The dedicated managed service is enabled, runs as a non-root DynamicUser, and listens on the instance IPv4/IPv6 addresses. Actual external requests from31.6.62.65 passed both RFC5389 and RFC3489 Binding with exact transaction IDs and the correct mapped address; TURN Allocate was ignored. The first external attempt was blocked by the existing IPv4 default-drop firewall. Exactly one UDP3478 accept rule was added to its live INPUT chain and existing persistent file, preserving every earlier rule/order and avoiding a firewall reload. External IPv6 delivery and physical W60B audio are not inferred from these checks. The vendor coturn service remains disabled/inactive, with no installation mask or package journal left behind.

The managed Debian service answers UDP STUN Binding requests on port **3478**. A phone can use the existing public SIP hostname, for example `openweb.sip.openwebpbx.com`, as its STUN server. Its SIP registrar and outbound proxy remain the PBX SIP service; STUN does not replace or forward SIP requests.

This is **STUN only**, with no TURN relay, TCP, TLS/DTLS, CLI, alternate port or anonymous media relay. Coturn supports modern RFC5389 and legacy RFC3489 basic Binding requests. NAT-type discovery using alternate addresses/ports is disabled. The legacy response may include coturn's version even with its modern SOFTWARE attribute disabled. Binding/client-address logs are disabled; systemd retains bounded service failure diagnostics.

STUN discovers a mapping; it does not guarantee traversal through symmetric NAT/CGNAT or restrictive firewalls. The PBX normally anchors RTP and performs its existing RTP address adjustment. SIP TCP/TLS, a controlled VPN or authenticated TURN would be separate choices when required. This feature does not configure TURN, a VPN, handset line assignment, carrier routing or firewall rules, and does not demonstrate physical handset audio.

## Installation

Ordinary installs and upgrades only deliver the three STUN helper/template files to `/opt/openwebpbx/tools`. They do not install coturn or open a listener. On a new Debian13 server, the fresh installer additionally accepts `--stun --address <local-address>` as an explicit opt-in.

On an existing server, first review the installed helper and public address. For an explicitly approved server installation:

```sh
sudo python3 /opt/openwebpbx/tools/install-stun.py \
  --install-package --listen-ip <installed-public-IP> --activate
```

Repeat `--listen-ip` for each installed IPv4/IPv6 address that should listen. Wildcard, multicast, loopback, nonnumeric and nonlocal addresses refuse. The hostname must resolve to the server, and an administrator must separately permit incoming UDP3478 in applicable host/provider firewalls. There are no automatic DNS, firewall, SIP profile, extension or media-policy changes.

Without `--activate`, the helper stages the managed unit/configuration only. Explicit activation enables and starts `openwebpbx-stun.service`; its coturn process uses a dedicated systemd DynamicUser, an isolated runtime directory and no capabilities. Configuration is `/etc/openwebpbx-stun.conf`; the protected ownership record is `/var/lib/openwebpbx/stun/installation.json`.

Existing coturn services, configuration, STUN listeners, other turnserver processes, custom drop-ins, links or altered managed files refuse for operator review. The helper does not adopt, overwrite, stop or unmask an operator's service. An existing managed service's enabled/disabled choice is preserved unless activation is explicitly requested. Stop only that managed service before changing its addresses or unit.

If coturn is absent and `--install-package` is requested, the helper creates an owned **persistent** mask only for the previously absent vendor `coturn.service`, before APT. It records recovery responsibility, installs the Debian package, disables the newly created vendor service, verifies its enable link is absent, then removes only its own mask. The separate managed STUN service starts only after its configuration exists. The persistent mask prevents an interrupted installation/reboot from starting the unconfigured vendor TURN daemon.

After an interrupted package operation, inspect the protected package transaction, unit/mask and package status before running:

```sh
sudo python3 /opt/openwebpbx/tools/install-stun.py --recover-package
```

Recovery requires the exact owned mask and an inactive vendor process; failed disable or unexpected ownership keeps the mask/journal for review. Interruption before mask creation or after mask removal may require manual review of the retained journal. Recovery does not uninstall packages or discard existing configuration. A failed explicit service activation retains its managed files for diagnosis rather than reporting success.

## Verification and scope

Verify actual RFC5389 and legacy RFC3489 replies from an external network and compare the mapped address/port with that client. Confirm a TURN Allocate request is ignored and inspect the socket/service identity. A successful local test is distinct from external delivery, a phone's actual STUN configuration, physical ringing and decoded two-way media. No Windows service or Windows qualification accompanies this Debian-only addition.

The exact coturn4.6.1 behavior is documented by the [official configuration example](https://github.com/coturn/coturn/blob/4.6.1/examples/etc/turnserver.conf), [server manual](https://github.com/coturn/coturn/blob/4.6.1/README.turnserver) and [STUN server implementation](https://github.com/coturn/coturn/blob/4.6.1/src/server/ns_turn_server.c). The implementation uses `stun-only`; disabling both relay transports is not a valid coturn4.6.1 configuration.
