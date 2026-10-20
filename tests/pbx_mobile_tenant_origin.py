"""Run mobile tenant-origin checks in a new disposable PostgreSQL cluster."""
from pathlib import Path
import argparse
import os
import pwd
import shutil
import socket
import subprocess
import tempfile


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--mobile-source", type=Path)
    parser.add_argument("--api-source", type=Path)
    parser.add_argument("--minimal", action="store_true")
    parser.add_argument("--password-regression", action="store_true")
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    base = Path(tempfile.mkdtemp(prefix="openweb-mobile-origin-"))
    owner = pwd.getpwnam("postgres")
    os.chown(base, owner.pw_uid, owner.pw_gid)
    pg = Path("/usr/lib/postgresql/18/bin")
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        port = sock.getsockname()[1]
    started = False
    env = os.environ.copy()
    env["OPENWEB_TEST_DSN"] = f"pgsql:host=127.0.0.1;port={port};dbname=postgres"
    for name, value in (
        ("OPENWEB_MOBILE_TEST_SOURCE", args.mobile_source),
        ("OPENWEB_MOBILE_API_SOURCE", args.api_source),
    ):
        env.pop(name, None)
        if value:
            env[name] = str(value.resolve(strict=True))
    env["OPENWEB_MOBILE_MINIMAL"] = "1" if args.minimal else "0"

    def run(command):
        return subprocess.run(
            ["runuser", "-u", "postgres", "--", *map(str, command)],
            check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        )

    try:
        run([pg / "initdb", "-D", base / "data", "--auth=trust", "--no-locale", "--encoding=UTF8"])
        run([pg / "pg_ctl", "-D", base / "data", "-l", base / "postgres.private.log",
             "-o", f"-h 127.0.0.1 -p {port} -k {base} -c fsync=off", "-w", "start"])
        started = True
        subprocess.run(["php", str(root / "tests/pbx_mobile_tenant_origin.php")],
                       env=env, check=True, timeout=90)
        if args.password_regression:
            assert not args.minimal
            subprocess.run(["php", str(root / "tests/pbx_mobile_password.php")],
                           env=env, check=True, timeout=90)
    finally:
        if started:
            run([pg / "pg_ctl", "-D", base / "data", "-m", "immediate", "-w", "stop"])
        shutil.rmtree(base)


if __name__ == "__main__":
    main()
