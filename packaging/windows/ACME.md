# Windows public certificates

`Enable-PublicAccess.ps1 -DomainName pbx.your-domain.tld -Email administrator@your-domain.tld` runs after the installed server is running. Public DNS must have one distinct public IPv4 A record pointing to the server or its forwarding router. `-PublicAddress` is optional; an explicit value must match DNS. Forward TCP80/443 and the actual configured public SIP listeners to the server. The standard phone listener uses TCP/UDP5060, the standard provider listener uses TCP/UDP5080, and phone TLS uses TCP5061 after its trusted certificate is active. The supported automatic audio range is UDP16384–32768; native STUN binding uses UDP3478. This helper does not configure an external router or DNS account.

The public HTTPS binding uses SNI on port 443 for that exact hostname. The existing local-test binding and unrelated IIS sites/bindings/certificates remain intact. A separate owned, empty ACME site holds only the hostname's HTTP80 binding; it does not serve Admin through plain HTTP. simple-acme's temporary HTTP.sys listener answers the challenge path. Before changing public configuration, the helper reads enabled profiles from protected local PostgreSQL, resolves their bounded authenticated loopback event-socket status and verifies native socket/process ownership. It validates the complete named-rule plan and prospective phone-TLS port5061 before mutation. HTTP/HTTPS, configured active SIP ports and the standard audio range receive exact owned program/port rules; TLS rules are added only when actually bound. Existing standard rule names remain compatible. Unfamiliar same-name address/interface/authentication/program/filter settings are preserved and refused. The helper never enables/disables Defender profiles or opens PostgreSQL5433, event socket8021 or local API8087. Outside router rules and management SSH/RDP access remain separate.

`Renew-PhoneCertificate.ps1 -Renew` checks only the dedicated renewal. `Renew-PhoneCertificate.ps1` applies pending certificates without forcing issuance. The daily **OpenWebPBX Certificate Renewal** task and five-minute **OpenWebPBX Pending Phone Certificate** task run as SYSTEM. Both hold `ProgramData\OpenWebPBX\upgrade.lock` and freshly respect every backup/restore hold. The ACME installation callback uses `-RecordOnly`: it records a thumbprint in the private child and never reenters its parent's lock or changes a listener. The parent then forwards its owned stream to `Enable-PhoneTLS.ps1 -MaintenanceLock`.

A renewed web certificate can be applied while the existing phone certificate stays in service. A confirmed active-call result leaves `pending.json` and `phone_certificate_status=waiting_for_idle`; FreeSWITCH is not restarted. Other certificate/profile/verification errors remain failures. Successful SIP application requires the guarded native helper's trusted hostname/chain/listener checks. Certificate expiry must not be interpreted as ready merely because a prior setup succeeded.

Automatic public setup currently refuses explicit `rtp-start-port` or `rtp-end-port` overrides before any public rule/configuration change. The stock effective core configuration and exact supported native DLL identify the configured default range; this is not an in-process getter for manually edited runtime settings. Custom audio ranges need administrator review. No call-engine restart is added to infer an unknown range. Existing guarded certificate application keeps its normal idle-call behavior.

Private account/configuration/output files live under `ProgramData\OpenWebPBX\public-access`, restricted to SYSTEM and Administrators. Existing certificates are retained with `--keepexisting`. Backup restoration keeps target active certificate/account settings; restored source metadata is inactive and does not prove machine-bound DPAPI portability.

Build the unmodified pinned client from the official ZIP:

```bash
curl -fL https://github.com/simple-acme/simple-acme/releases/download/v2.4.1/simple-acme.v2.4.1.2444.win-x64.trimmed.zip -o /private/build/simple-acme.zip
python3 packaging/windows/build-acme-runtime.py --archive /private/build/simple-acme.zip --output /private/build/acme
```

The builder verifies ZIP SHA-256 `b53fd863dfe4e02ec8618e9676b331d805fa1d688b83251f797f9339d221dada`, extracts safe ordinary files and adds the reviewed license/source inventory. Package that directory as `acme`; install it under `C:\OpenWebPBX\acme`. Persistent helpers and callbacks belong under `C:\OpenWebPBX\tools`, not an extracted archive that can be deleted afterward. Runtime configuration is regenerated beside the client under the maintenance lock, pointing to its private account/log directories and an exportable LocalMachine\My key.

The upstream source is commit `b21505a1b21e0f7738d95b2aea00306cdf9260f2` from `simple-acme/simple-acme`, tag `v2.4.1`. Its original tarball SHA-256 is `68f60e945a36d9a55e1f4f58e71e1ef9c36223b3b2d5ae557deec12e10a0a326`. A reproducible source checkout includes both exact submodules:

```bash
git clone https://github.com/simple-acme/simple-acme.git
git -C simple-acme checkout b21505a1b21e0f7738d95b2aea00306cdf9260f2
git -C simple-acme submodule update --init --recursive
```

`packaging/licenses/simple-acme/inventory.json` records the two submodule revisions and licenses, .NET10.0.12 notices, MPL2 public-suffix license and all 32 NuGet dependencies from the actual official executable. NuGet package content hashes were checked using `NuGet.Packaging.PackageArchiveReader.GetContentHash`; repository-signature bytes make a raw archive SHA512 different. Original HTTP archive SHA256 values are retained separately. Full license texts and source URLs remain in the inventory; no upstream runtime files were modified.

Executable source checks cover input/DNS selection, atomic state, lock contention, restore holds, exact-host refusal, busy deferral and strict failure/recovery. Their certificate/IIS/native doubles are explicit. Actual Windows service/pool access, IIS/SNI, outside ACME issuance/renewal, expiry and guarded native calls require machine qualification; these source checks do not establish those outcomes.

Official interfaces: [release](https://github.com/simple-acme/simple-acme/releases/tag/v2.4.1), [self-hosted HTTP validation](https://simple-acme.com/reference/plugins/validation/http/selfhosting), [certificate store](https://simple-acme.com/reference/plugins/store/certificatestore), [script callback](https://simple-acme.com/reference/plugins/installation/script), [CLI](https://simple-acme.com/reference/cli).
