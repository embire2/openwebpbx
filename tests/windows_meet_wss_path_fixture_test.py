#!/usr/bin/env python3
"""Actual helper C# against owned loopback TLS/WSS, with child-only CA trust."""
import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import re
import socket
import ssl
import struct
import subprocess
import tempfile
import threading
import time


checks = 0


def check(value):
    global checks
    if not value:
        raise AssertionError("An owned local WSS fixture control failed")
    checks += 1


def openssl(directory, *arguments):
    subprocess.run(["openssl", *arguments], cwd=directory, check=True,
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=15)


def exact(stream, length):
    data = b""
    while len(data) < length:
        part = stream.recv(length - len(data))
        if not part:
            raise EOFError()
        data += part
    return data


def receive_frame(stream):
    header = exact(stream, 2)
    length = header[1] & 127
    if length == 126:
        length = struct.unpack("!H", exact(stream, 2))[0]
    elif length == 127:
        length = struct.unpack("!Q", exact(stream, 8))[0]
    if not header[1] & 128 or length > 16384:
        raise ValueError("Invalid fictional client framing")
    mask = exact(stream, 4)
    data = exact(stream, length)
    return header[0], bytes(value ^ mask[index % 4] for index, value in enumerate(data))


def receive_message(stream):
    first, body = receive_frame(stream)
    frames = [(first & 15, bool(first & 128), len(body), time.monotonic())]
    if first & 15 != 1:
        raise ValueError("Expected fictional text OPTIONS")
    while not first & 128:
        first, part = receive_frame(stream)
        frames.append((first & 15, bool(first & 128), len(part), time.monotonic()))
        if first & 15 != 0 or len(body) + len(part) > 16384:
            raise ValueError("Invalid fictional continuation")
        body += part
    return body, frames


def frame(body, opcode=1, final=True):
    first = opcode | (128 if final else 0)
    if len(body) < 126:
        return bytes((first, len(body))) + body
    if len(body) < 65536:
        return bytes((first, 126)) + struct.pack("!H", len(body)) + body
    return bytes((first, 127)) + struct.pack("!Q", len(body)) + body


class Fixture:
    def __init__(self, directory, mode):
        self.mode = mode
        self.requests = []
        self.fragments = []
        self.finished = False
        self.failed = False
        self.listener = socket.socket()
        self.listener.bind(("127.0.0.1", 0))
        self.listener.listen(1)
        self.listener.settimeout(6)
        self.port = self.listener.getsockname()[1]
        self.context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        certificate = "wrong.pem" if mode in ("wrong_san", "fragmented_send_wrong_san") else "server.pem"
        self.context.load_cert_chain(directory / certificate, directory / "server.key")
        self.thread = threading.Thread(target=self.run, daemon=False)
        self.thread.start()

    def run(self):
        try:
            connection, _ = self.listener.accept()
            connection.settimeout(6)
            with connection, self.context.wrap_socket(connection, server_side=True) as stream:
                request = b""
                while not request.endswith(b"\r\n\r\n"):
                    request += exact(stream, 1)
                    if len(request) > 16384:
                        raise ValueError("Fixture handshake exceeded its bound")
                headers = dict(line.split(b":", 1) for line in request.split(b"\r\n")[1:] if b":" in line)
                check(headers[b"Sec-WebSocket-Protocol"].strip() == b"sip")
                if self.mode == "http_refusal":
                    stream.sendall(b"HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
                    return
                accept = base64.b64encode(hashlib.sha1(headers[b"Sec-WebSocket-Key"].strip() + b"258EAFA5-E914-47DA-95CA-C5AB0DC85B11").digest())
                stream.sendall(b"HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Protocol: sip\r\nSec-WebSocket-Accept: " + accept + b"\r\n\r\n")
                for index in range(2):
                    message, frames = receive_message(stream)
                    self.requests.append(message)
                    self.fragments.append(frames)
                    if index == 1 and self.mode.startswith("fragmented_send"):
                        check(len(frames) == 2)
                        check(frames[0][:3] == (1, False, 4096))
                        check(frames[1][:3] == (0, True, 4096))
                        check(0.08 <= frames[1][3] - frames[0][3] < 4.5)
                    else:
                        check(len(frames) == 1 and frames[0][:2] == (1, True))
                    check(message.startswith(b"OPTIONS sip:openweb-meet.internal SIP/2.0\r\n"))
                    check(b"Authorization:" not in message and b"INVITE" not in message and b"REGISTER" not in message)
                    check(message.endswith(b"Content-Length: 0\r\n\r\n"))
                    check(len(message) == 8192 if index else len(message) < 2048)
                    call_id = re.search(rb"\r\nCall-ID: ([^\r\n]+)\r\n", message).group(1)
                    response = b"SIP/2.0 200 Fictional\r\nCall-ID: " + call_id + b"\r\nCSeq: 1 OPTIONS\r\nContent-Length: 0\r\n\r\n"
                    if self.mode in ("stall", "fragmented_send_first_stall") or (self.mode in ("large_stall", "fragmented_send_large_stall") and index == 1):
                        while stream.recv(1024):
                            pass
                        return
                    if self.mode == "oversize":
                        stream.sendall(frame(response + b"x" * 16385))
                        return
                    if self.mode == "binary":
                        stream.sendall(frame(response, opcode=2))
                        return
                    if self.mode == "wrong_correlation":
                        bad = response.replace(call_id, b"PRIVATE_FIXTURE_WRONG_ID")
                        stream.sendall(frame(bad) * 4)
                        return
                    if self.mode in ("fragmented", "fragmented_send_response"):
                        midpoint = len(response) // 2
                        stream.sendall(frame(response[:midpoint], final=False) + frame(response[midpoint:], opcode=0))
                    else:
                        stream.sendall(frame(response))
        except (ssl.SSLError, EOFError, ConnectionError, OSError):
            # Expected for natural certificate denial and client Abort cleanup.
            pass
        except Exception:
            self.failed = True
        finally:
            self.listener.close()
            self.finished = True

    def close(self):
        self.listener.close()
        self.thread.join(7)
        check(self.finished and not self.thread.is_alive() and not self.failed)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--pwsh", default="/var/lib/openwebpbx/windows113-core/powershell/pwsh")
    parser.add_argument("--source-root", type=Path, default=Path(__file__).resolve().parents[1])
    arguments = parser.parse_args()
    source = arguments.source_root / "tests/windows-meet-wss-path.ps1"
    with tempfile.TemporaryDirectory(prefix="openweb-wss-path-fixture-") as temporary:
        directory = Path(temporary)
        (directory / "empty-roots").mkdir()
        openssl(directory, "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-sha256", "-days", "1", "-subj", "/CN=OwnedWssFixtureRoot", "-addext", "basicConstraints=critical,CA:TRUE", "-keyout", "ca.key", "-out", "ca.pem")
        openssl(directory, "req", "-new", "-newkey", "rsa:2048", "-nodes", "-subj", "/CN=localhost", "-keyout", "server.key", "-out", "server.csr")
        for name, hostname in (("server", "localhost"), ("wrong", "wrong.localhost.invalid")):
            (directory / "extensions").write_text("basicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature,keyEncipherment\nextendedKeyUsage=serverAuth\nsubjectAltName=DNS:" + hostname + "\n")
            openssl(directory, "x509", "-req", "-in", "server.csr", "-CA", "ca.pem", "-CAkey", "ca.key", "-CAcreateserial", "-days", "1", "-sha256", "-extfile", "extensions", "-out", name + ".pem")
        openssl(directory, "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-sha256", "-days", "1", "-subj", "/CN=OtherOwnedWssFixtureRoot", "-addext", "basicConstraints=critical,CA:TRUE", "-keyout", "other.key", "-out", "other.pem")
        bootstrap = directory / "probe.ps1"
        bootstrap.write_text(r'''param([string]$Source,[string]$Target,[string]$ProbeMethodName='ProbeUri')
$ErrorActionPreference='Stop';$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile($Source,[ref]$tokens,[ref]$errors)
if($errors.Count){throw 'Fixture source did not parse.'}
$nodes=@($ast.FindAll({param($node)$node -is [Management.Automation.Language.StringConstantExpressionAst] -and $node.Value.Contains('public static class OpenWebMeetWssPathProbe')},$true))
if($nodes.Count -ne 1){throw 'One actual fixture core is required.'};Add-Type -TypeDefinition $nodes[0].Value
$projector=@($ast.FindAll({param($node)$node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq 'Get-MeetWssPathFields'},$true));Invoke-Expression $projector[0].Extent.Text
$method=[OpenWebMeetWssPathProbe].GetMethod($ProbeMethodName,[Reflection.BindingFlags]'NonPublic,Static')
$result=$method.Invoke($null,@([Uri]$Target));$safe=Get-MeetWssPathFields $result
if(!$safe){throw 'Fixture result did not have the closed schema.'};$safe|ConvertTo-Json -Depth 4 -Compress
''')
        fields = {"observed", "connected", "sent", "response_received", "large_sent", "large_response_received", "status_code", "large_status_code", "phase", "error_kind", "closed_exact", "elapsed_ms"}
        for mode in ("valid", "fragmented", "http_refusal", "wrong_san", "untrusted_ca", "oversize", "binary", "wrong_correlation", "stall", "large_stall", "fragmented_send", "fragmented_send_response", "fragmented_send_wrong_san", "fragmented_send_first_stall", "fragmented_send_large_stall"):
            fixture = Fixture(directory, mode)
            environment = os.environ.copy()
            environment["SSL_CERT_FILE"] = str(directory / ("other.pem" if mode == "untrusted_ca" else "ca.pem"))
            environment["SSL_CERT_DIR"] = str(directory / "empty-roots")
            started = time.monotonic()
            try:
                method = "ProbeFragmentedUri" if mode.startswith("fragmented_send") else "ProbeUri"
                process = subprocess.run([arguments.pwsh, "-NoLogo", "-NoProfile", "-File", str(bootstrap), "-Source", str(source), "-Target", f"wss://localhost:{fixture.port}/", "-ProbeMethodName", method], env=environment, capture_output=True, text=True, timeout=12)
                check(process.returncode == 0)
                report = json.loads(process.stdout)
                check(set(report) == fields)
                check(report["observed"] is True and report["closed_exact"] is True)
                check(0 <= report["elapsed_ms"] <= 5500 and time.monotonic() - started < 12)
                check("PRIVATE_FIXTURE" not in process.stdout and "localhost" not in process.stdout and "Call-ID" not in process.stdout)
                if mode in ("valid", "fragmented", "fragmented_send", "fragmented_send_response"):
                    check(report["connected"] and report["sent"] and report["response_received"] and report["large_sent"] and report["large_response_received"])
                    check(report["status_code"] == report["large_status_code"] == 200 and report["phase"] == "complete" and report["error_kind"] == "none")
                    check(len(fixture.requests) == 2)
                elif mode in ("wrong_san", "untrusted_ca", "fragmented_send_wrong_san"):
                    check(not report["connected"] and not report["sent"] and report["error_kind"] == "tls" and report["phase"] == "connect")
                elif mode == "http_refusal":
                    check(not report["connected"] and not report["sent"] and report["error_kind"] == "websocket")
                elif mode in ("large_stall", "fragmented_send_large_stall"):
                    check(report["response_received"] and report["status_code"] == 200 and report["large_sent"] and not report["large_response_received"])
                    check(report["error_kind"] == "timeout" and report["phase"] == "receive" and report["elapsed_ms"] >= 4000)
                else:
                    check(report["connected"] and report["sent"] and not report["response_received"] and not report["large_sent"])
                    check(report["phase"] == "receive" and report["error_kind"] == ("timeout" if mode in ("stall", "fragmented_send_first_stall") else "websocket"))
                check(0 <= report["status_code"] <= 699 and 0 <= report["large_status_code"] <= 699)
            finally:
                fixture.close()
    print(f"PASS {checks} actual local default-trust TLS/WSS framing/deadline/privacy/cleanup controls; no external request or global trust change")


if __name__ == "__main__":
    main()
