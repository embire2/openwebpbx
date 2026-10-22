# Windows private media identity

The Windows installer prepares a private DTLS certificate before starting the
calling engine. Browser meetings and video calls need a currently valid DTLS
certificate in addition to their HTTPS and SIP WebSocket certificates.

The pinned Windows engine's automatic certificate generator requests 36,500
days using a 32-bit Windows `long` seconds calculation. The resulting overflow
can produce a certificate whose expiry is earlier than its start date. A
read-only native test found exactly that shape; the existing certificate and
its permissions were preserved during diagnosis.

`Install-Dtls.ps1` uses isolated OpenSSL code without loading the PBX or opening
the database. Under the installation's exclusive maintenance lock, with the
owned calling service stopped, it:

- Preserves valid matching RSA certificates of at least 4096 bits, including
  custom certificates and their exact permissions.
- Repairs an absent certificate or the precise self-signed stock overflow
  shape. Unrelated invalid, expired, malformed or custom certificates require
  administrator review and remain unchanged.
- Generates an RSA4096/SHA256 certificate with a ten-year lifetime. Its private
  file grants access only to administrators, SYSTEM and the actual calling
  service identity. An existing certificate directory retains its permissions and unrelated
  files. For a fresh MSI installation, the known absent directory is created
  atomically with protected administrator/SYSTEM access and directory access
  for the calling service. Its original absence is recorded before creation.
- Retains protected original bytes and permissions, desired bytes, and a
  flushed machine-bound journal before replacing the installed file. Recovery
  refuses foreign file bytes, permissions, service identity or damaged backups.

Generation occurs in a private `staging-<GUID>` directory. No installed
certificate is changed until a complete transaction is atomically promoted.
If generation or the first journal write is interrupted, `-Recover` retains
that evidence as `abandoned-<GUID>`; it does not delete keys or alter the
installed identity. Unknown staging entries require administrator review.
Promoted transactions restore the exact original certificate or its original
absence. The helper never starts services, changes firewall rules, or adds
trust certificates.

The complete Windows suite requires real native NTFS transaction tests, real
OpenSSL tests and a read-only check of the fresh installed private certificate,
its protected permissions, ownership journal and unchanged engine process.
These preconditions do not establish decoded browser media: the separate
two-way audio and VP8 meeting tests must also pass.

Portable backup restore preserves the destination's media identity. Failed
installation/upgrade recovery instead restores the original machine's exact
certificate bytes, permissions, original parent-directory presence and
transaction state. A newly created parent is removed only after verifying its
owned permissions and that no unrelated files remain. Do not copy an old
invalid certificate over a repaired installation or publish an older archive
as if it contained this correction.
