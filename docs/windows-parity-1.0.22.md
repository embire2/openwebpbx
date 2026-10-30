# Windows Server 1.0.22 qualification

Windows 1.0.22 is being qualified. The downloadable Windows release remains
[1.0.21](https://github.com/embire2/openwebpbx/releases/tag/v1.0.21).
Debian 1.0.22 and Android 1.0.19 retain their existing packages and feeds.

The new Windows installer uses the same [public setup wizard](https://openwebpbx.com/wizard)
as Debian: connect an account, verify its email, choose the tenant address,
and let the server obtain its managed DNS, HTTPS certificates and installation
authorization. The PostgreSQL database remains on the Windows server.

The native manager opens the validated setup link after managed installation,
refreshes expired links and waits for a pending link without sending the user
to an unpublished server address. A Windows certificate check now distinguishes
the locally trusted temporary setup certificate from an issued certificate,
allowing automatic public certificate setup to proceed.

| Check | Current evidence |
|---|---|
| Native server, manager and updater build | [41075157082](https://github.com/embire2/openwebpbx/actions/runs/41075157082) passed; all three assemblies are 1.0.22 and the manager opens a responsive window |
| Native protocol checks | 41 installation-grant, 57 protocol, 82 updater and 20,050 STUN checks passed |
| Manager setup-link validation | 31 C# controls passed |
| Temporary-certificate correction | Six real loopback TLS checks and 132 isolated registration-worker controls passed; the actual Windows test server confirms that the correction rejects its locally trusted self-signed leaf |
| Public wizard | Windows wording is live; desktop/mobile layout, required links and browser console checks passed |
| Protection of the existing test server | Full encrypted 1.0.21 backup verified, including media, with a protected off-server copy; original backup settings restored |
| Genuine public 1.0.21 to actual candidate 1.0.22 | Full installer, upgrade, rollback and software suite in progress |
| Fresh Windows registration | Pending actual installation, account verification, managed DNS, public HTTPS and calling checks |
| Reboot and final publication | Pending |

The upgrade fixture installs the immutable public 1.0.21 ZIP, then uses the
actual candidate 1.0.22 helper. It checks the original database, credentials,
media, Windows tasks and security, including removal of the new registration
task on rollback. A version-only canary does not qualify this transition.
Fresh registration is a separate requirement: an older fictional-host test
cannot satisfy the new installation authorization requirement.

Earlier runs remain failed: 41079281740 stopped at an outdated task-security
source contract; 41081098365 at a changed test phase anchor; and 41082501822 at
a backup-observer version pin. All stopped before server installation. Their
corrections retain the original protections. The current run is
[41083933798](https://github.com/embire2/openwebpbx/actions/runs/41083933798),
source `f4b8f7e996004dec2abd31b5aec5faa44d88bab7`.

These checks do not establish physical-phone, carrier, camera or Store
approval coverage. Windows 10/11 server installation and cross-platform
instance-backup restoration remain unsupported; the Windows calling client
is a separate project. The broader [feature roadmap](../3CX.md) totals are
unchanged.
