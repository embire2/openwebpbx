#!/usr/bin/env python3
"""Exercise the Windows readiness helper through real local TLS and HTTP.

Run on Linux with Python's cryptography package and PowerShell 7:
    python3 tests/windows_web_readiness_test.py --powershell /path/to/pwsh

The fixture CA is trusted only by the child process through OpenSSL environment
variables. No system certificate, DNS, proxy or firewall settings change. This
protocol regression supplements, and does not replace, native Windows tests.
"""

import argparse
import datetime as dt
import hashlib
import json
import os
from pathlib import Path
import shutil
import socket
import ssl
import subprocess
import sys
import tempfile
import threading
import time

from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import rsa
from cryptography.x509.oid import ExtendedKeyUsageOID, NameOID


HOSTNAME = "readiness.example.invalid"
BODY = b'<html><form><input name="username"><input name="password"></form></html>'
CASES = (
    "good", "chunked", "http500", "not_form", "not_html", "wrong_hostname",
    "untrusted", "ambiguous", "duplicate_length", "truncated", "bad_chunk",
    "oversize", "stalled_tls", "stalled_http", "slow_trickle",
)
RUNNER = """param([string]$HelperPath,[string]$ServerName,[int]$TestPort)
$ErrorActionPreference='Stop'
. $HelperPath
$items=@(Test-OpenWebTrustedLogin $ServerName $TestPort)
[Console]::WriteLine((@{
 ready=[bool]$items[-1]
 output_count=$items.Count
 output_types=@($items | ForEach-Object {$_.GetType().FullName})
}|ConvertTo-Json -Compress))
"""


def make_certificates(directory, label):
    now = dt.datetime.now(dt.timezone.utc)
    ca_key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    ca_name = x509.Name([
        x509.NameAttribute(NameOID.COMMON_NAME, "OpenWeb readiness fixture " + label)
    ])
    ca = (
        x509.CertificateBuilder().subject_name(ca_name).issuer_name(ca_name)
        .public_key(ca_key.public_key()).serial_number(x509.random_serial_number())
        .not_valid_before(now - dt.timedelta(minutes=5))
        .not_valid_after(now + dt.timedelta(days=1))
        .add_extension(x509.BasicConstraints(ca=True, path_length=0), critical=True)
        .sign(ca_key, hashes.SHA256())
    )
    leaf_key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    leaf = (
        x509.CertificateBuilder()
        .subject_name(x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, HOSTNAME)]))
        .issuer_name(ca_name).public_key(leaf_key.public_key())
        .serial_number(x509.random_serial_number())
        .not_valid_before(now - dt.timedelta(minutes=5))
        .not_valid_after(now + dt.timedelta(days=1))
        .add_extension(x509.BasicConstraints(ca=False, path_length=None), critical=True)
        .add_extension(x509.SubjectAlternativeName([x509.DNSName(HOSTNAME)]), critical=False)
        .add_extension(x509.ExtendedKeyUsage([ExtendedKeyUsageOID.SERVER_AUTH]), critical=False)
        .sign(ca_key, hashes.SHA256())
    )
    files = {
        "ca": ca.public_bytes(serialization.Encoding.PEM),
        "leaf": leaf.public_bytes(serialization.Encoding.PEM),
        "key": leaf_key.private_bytes(
            serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8,
            serialization.NoEncryption(),
        ),
    }
    paths = {}
    for name, value in files.items():
        path = directory / (label + "-" + name + ".pem")
        path.write_bytes(value)
        paths[name] = path
    return paths


class LocalServer:
    def __init__(self, mode, trusted, untrusted):
        self.mode = mode
        self.certificates = untrusted if mode == "untrusted" else trusted
        self.stop = threading.Event()
        self.socket = socket.socket()
        self.socket.bind(("127.0.0.1", 0))
        self.port = self.socket.getsockname()[1]
        self.socket.listen(2)
        self.socket.settimeout(0.2)
        self.sni = []
        self.request_valid = False
        self.thread = threading.Thread(target=self.run, daemon=True)
        self.thread.start()

    def response(self):
        data = BODY
        status = "500 Internal Server Error" if self.mode == "http500" else "200 OK"
        content_type = b"application/json" if self.mode == "not_html" else b"text/html; charset=utf-8"
        if self.mode == "not_form":
            data = b"<html>Loading</html>"
        if self.mode == "oversize":
            data = b"X" * (1024**2 + 1)
        if self.mode in ("chunked", "ambiguous", "bad_chunk"):
            first, second = data[:23], data[23:]
            data = (
                f"{len(first):x}\r\n".encode() + first + b"\r\n"
                + f"{len(second):x}\r\n".encode() + second
                + b"\r\n0\r\nX-Fixture: test\r\n\r\n"
            )
            if self.mode == "bad_chunk":
                data = b"ZZ\r\nignored\r\n0\r\n\r\n"
            framing = b"Transfer-Encoding: chunked\r\n"
            if self.mode == "ambiguous":
                framing += f"Content-Length: {len(data)}\r\n".encode()
        else:
            length = len(data) + (5 if self.mode == "truncated" else 0)
            framing = f"Content-Length: {length}\r\n".encode()
            if self.mode == "duplicate_length":
                framing += framing
        return (
            f"HTTP/1.1 {status}\r\n".encode() + b"Content-Type: " + content_type
            + b"\r\n" + framing + b"Connection: close\r\n\r\n" + data
        )

    def run(self):
        connection = None
        try:
            while not self.stop.is_set():
                try:
                    connection, _ = self.socket.accept()
                    break
                except socket.timeout:
                    continue
            if connection is None:
                return
            connection.settimeout(3)
            if self.mode == "stalled_tls":
                self.stop.wait(14)
                return
            context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
            context.load_cert_chain(self.certificates["leaf"], self.certificates["key"])
            context.set_servername_callback(lambda _socket, name, _context: self.sni.append(name))
            connection = context.wrap_socket(connection, server_side=True)
            request = b""
            while b"\r\n\r\n" not in request:
                chunk = connection.recv(2048)
                if not chunk:
                    return
                request += chunk
                if len(request) > 16384:
                    return
            hostname = "wrong.example.invalid" if self.mode == "wrong_hostname" else HOSTNAME
            self.request_valid = (
                request.startswith(b"GET /login.php HTTP/1.1\r\n")
                and f"Host: {hostname}:{self.port}\r\n".encode() in request
                and b"cookie:" not in request.lower()
                and b"authorization:" not in request.lower()
            )
            if self.mode == "stalled_http":
                self.stop.wait(14)
                return
            response = self.response()
            if self.mode == "slow_trickle":
                for value in response:
                    if self.stop.wait(0.35):
                        break
                    connection.sendall(bytes([value]))
            else:
                connection.sendall(response)
        except (ssl.SSLError, ConnectionError, OSError):
            # Refusing a certificate or oversized response closes the peer early.
            pass
        finally:
            if connection is not None:
                connection.close()

    def close(self):
        self.stop.set()
        self.socket.close()
        self.thread.join(3)
        if self.thread.is_alive():
            raise AssertionError("Owned fixture thread did not stop")


def run_tests(args, fixture, evidence):
    helper_bytes = args.helper.read_bytes()
    helper_sha = hashlib.sha256(helper_bytes).hexdigest()
    helper = fixture / "Web-Readiness.ps1"
    helper.write_bytes(helper_bytes)
    if evidence:
        (evidence / helper.name).write_bytes(helper_bytes)
    runner = fixture / "run.ps1"
    runner.write_text(RUNNER, encoding="utf-8")
    trusted = make_certificates(fixture, "trusted")
    untrusted = make_certificates(fixture, "untrusted")
    empty_ca_directory = fixture / "empty-ca-directory"
    empty_ca_directory.mkdir()
    environment = dict(
        os.environ, SSL_CERT_FILE=str(trusted["ca"]), SSL_CERT_DIR=str(empty_ca_directory),
        POWERSHELL_TELEMETRY_OPTOUT="1", POWERSHELL_UPDATECHECK="Off",
        XDG_CACHE_HOME=str(fixture / "cache"),
    )
    results = []
    for mode in CASES:
        server = LocalServer(mode, trusted, untrusted)
        started = time.monotonic()
        result = {"case": mode, "expected": mode in ("good", "chunked")}
        try:
            process = subprocess.run(
                [
                    str(args.powershell), "-NoLogo", "-NoProfile", "-NonInteractive",
                    "-File", str(runner), "-HelperPath", str(helper), "-ServerName",
                    "wrong.example.invalid" if mode == "wrong_hostname" else HOSTNAME,
                    "-TestPort", str(server.port),
                ],
                env=environment, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=16,
            )
            result["elapsed_seconds"] = round(time.monotonic() - started, 3)
            if evidence:
                (evidence / (mode + ".stdout.private")).write_bytes(process.stdout)
                (evidence / (mode + ".stderr.private")).write_bytes(process.stderr)
            if process.returncode:
                raise AssertionError(f"PowerShell exited {process.returncode}")
            actual = json.loads(process.stdout)
            # A Task's VoidTaskResult must not turn a false result into a truthy array.
            if not (
                actual["output_count"] == 1
                and actual["output_types"] == ["System.Boolean"]
                and type(actual["ready"]) is bool
                and actual["ready"] == result["expected"]
            ):
                raise AssertionError(f"Expected a single Boolean: {actual!r}")
            if result["elapsed_seconds"] >= 13:
                raise AssertionError("Whole-call deadline exceeded, including process startup")
            if result["expected"] and not (server.request_valid and server.sni == [HOSTNAME]):
                raise AssertionError("Expected direct local GET with verified hostname/SNI")
            result["state"] = "passed"
        except (AssertionError, KeyError, ValueError, subprocess.TimeoutExpired) as error:
            result.update(state="failed", reason=str(error))
        finally:
            server.close()
        results.append(result)
    source_unchanged = hashlib.sha256(args.helper.read_bytes()).hexdigest() == helper_sha
    report = {
        "state": "passed" if source_unchanged and all(r["state"] == "passed" for r in results) else "failed",
        "helper_sha256": helper_sha,
        "scope": "Linux PowerShell/.NET TLS and HTTP; not native Windows acceptance",
        "actual_TLS_HTTP_cases": len(results),
        "source_unchanged": source_unchanged,
        "process_only_fixture_CA": True,
        "results": results,
    }
    if evidence:
        (evidence / "qualification.safe.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report, indent=2))
    return 0 if report["state"] == "passed" else 1


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--powershell", type=Path, default=shutil.which("pwsh"))
    parser.add_argument(
        "--helper", type=Path,
        default=Path(__file__).resolve().parents[1] / "packaging/windows/Web-Readiness.ps1",
    )
    parser.add_argument("--evidence-dir", type=Path, help="New private directory for source and receipts")
    args = parser.parse_args()
    if not sys.platform.startswith("linux"):
        parser.error("Process-local OpenSSL trust fixture requires Linux; use native qualification on Windows")
    if not args.powershell or not Path(args.powershell).is_file():
        parser.error("Supply an installed PowerShell 7 executable with --powershell")
    args.powershell = Path(args.powershell).resolve()
    args.helper = args.helper.resolve(strict=True)
    previous_umask = os.umask(0o077)
    try:
        if args.evidence_dir:
            args.evidence_dir = args.evidence_dir.resolve()
            args.evidence_dir.mkdir(mode=0o700, parents=True, exist_ok=False)
        with tempfile.TemporaryDirectory(prefix="openweb-readiness-") as directory:
            return run_tests(args, Path(directory), args.evidence_dir)
    finally:
        os.umask(previous_umask)


if __name__ == "__main__":
    raise SystemExit(main())
