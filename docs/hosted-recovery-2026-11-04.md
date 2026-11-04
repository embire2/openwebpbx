# Hosted PBX recovery — 4 November 2026

The live `call.openweb.co.za` site returned HTTP500 after its PostgreSQL18/main cluster stopped during a checkpoint with `No space left on device`. Accumulated development and test work occupied the shared filesystem. The generic PostgreSQL umbrella unit still reported active; the actual cluster was failed.

The cluster recovered through PostgreSQL's normal WAL recovery after it was started with available disk space. Canonical and OpenWeb tenant login pages return HTTP200. A real browser verifies both login forms with no page errors; PostgreSQL accepts connections and the application extension inventory remains27. FreeSWITCH continued running during this repair.

The server now has approximately11GiB free. Retrievable APT package downloads from two old test filesystems were cleared. Inactive Windows source trees and four old Debian test root filesystems were archived privately, preserving their contents and stored metadata. GNUtar comparison passed before each expanded copy was removed. Archive paths, SHA256 values and original locations are recorded under `/var/lib/openwebpbx/site-recovery-20261104T111109Z`. Live database files, production recordings, published archives and current qualification inputs were retained.

Unexpected database failures now restart after30 seconds through a host-specific systemd override:

```ini
# /etc/systemd/system/postgresql@18-main.service.d/openwebpbx-recovery.conf
[Service]
Restart=on-failure
RestartSec=30s
```

The policy was read back after `systemctl daemon-reload`; the running database PID stayed unchanged. Planned maintenance uses `systemctl stop postgresql@18-main`. Other installations must use their own cluster name from `pg_lsclusters`.

Future build, download and extraction work on this shared filesystem requires10GiB of reserve plus its maximum expected staging/output size. Larger builds belong on a separate builder or volume. Check actual database readiness and the live page after operational work:

```sh
pg_isready -h 127.0.0.1 -p 5432
sudo -u postgres psql -X -d fusionpbx -Atc 'select 1'
systemctl is-active postgresql@18-main
curl -L --max-time 15 -o /dev/null -w '%{http_code}\n' https://call.openweb.co.za/
```

Archived test workspaces can be extracted into an empty private directory with GNUtar using `--acls --xattrs --numeric-owner --zstd -xpf`. Verify the retained archive checksum and original path mapping first. An archived root is test evidence and requires extraction before reuse.

This repair changes hosted operations and documentation. The published Windows1.0.22 package, source tag and platform feeds retain their original identities.
