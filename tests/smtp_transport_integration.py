"""Run the real PHP mail transport against a local SMTP sink; no mail leaves this machine."""
from pathlib import Path
import base64
import socketserver
import subprocess
import threading


class SMTPFixture(socketserver.StreamRequestHandler):
    def handle(self):
        self.request.settimeout(15)
        authenticated = False
        sender = recipient = False
        self.reply("220 fixture.example ESMTP")
        while True:
            line = self.rfile.readline().decode().rstrip("\r\n")
            if not line:
                break
            command = line.split(" ", 1)[0].upper()
            if command in ("EHLO", "HELO"):
                self.reply("250-fixture.example\r\n250-AUTH LOGIN PLAIN\r\n250 SIZE 1000000")
            elif command == "AUTH":
                mechanism = line.split(" ")[1].upper()
                if mechanism == "LOGIN":
                    self.reply("334 " + base64.b64encode(b"Username:").decode())
                    username = base64.b64decode(self.rfile.readline().strip())
                    self.reply("334 " + base64.b64encode(b"Password:").decode())
                    password = base64.b64decode(self.rfile.readline().strip())
                elif mechanism == "PLAIN":
                    payload = line.split(" ", 2)
                    if len(payload) == 2:
                        self.reply("334 ")
                        payload.append(self.rfile.readline().decode().strip())
                    _, username, password = base64.b64decode(payload[2]).split(b"\0")
                else:
                    self.reply("504 Unsupported mechanism")
                    continue
                authenticated = username == b"fixture-user" and password == b"fixture-password"
                self.reply("235 Authenticated" if authenticated else "535 Invalid fixture credentials")
            elif command == "MAIL":
                sender = True
                self.reply("250 Sender accepted")
            elif command == "RCPT":
                recipient = True
                self.reply("250 Recipient accepted")
            elif command == "DATA":
                assert sender and recipient
                self.reply("354 End with a dot")
                message = bytearray()
                while True:
                    part = self.rfile.readline()
                    if part == b".\r\n":
                        break
                    assert part, "Unexpected disconnect while sending fixture mail"
                    message.extend(part)
                with self.server.record_lock:
                    self.server.deliveries.append((authenticated, bytes(message)))
                self.reply("250 Captured locally")
            elif command == "RSET":
                self.reply("250 Reset")
            elif command == "QUIT":
                with self.server.record_lock:
                    self.server.connections.append(authenticated)
                self.reply("221 Bye")
                break
            else:
                self.reply("502 Unsupported fixture command")

    def reply(self, text):
        self.wfile.write((text + "\r\n").encode())
        self.wfile.flush()


if __name__ == "__main__":
    with socketserver.ThreadingTCPServer(("127.0.0.1", 0), SMTPFixture) as fixture:
        fixture.deliveries = []
        fixture.connections = []
        fixture.record_lock = threading.Lock()
        fixture.daemon_threads = True
        worker = threading.Thread(target=fixture.serve_forever, daemon=True)
        worker.start()
        repo = Path(__file__).resolve().parents[1]
        try:
            subprocess.run(["php", str(repo / "tests/smtp_transport_integration.php"), str(fixture.server_address[1])], cwd=repo, check=True, timeout=60)
            assert fixture.connections == [False, False, True, True], "Unexpected SMTP authentication on the wire"
            assert [auth for auth, _ in fixture.deliveries] == [False, True], "Both authentication modes were not delivered"
            assert all(b"From: SMTP Fixture <pbx@example.invalid>" in message for _, message in fixture.deliveries), "Global sender defaults were not used"
            print("PASS: SMTP wire capture confirmed no AUTH for IP mode and successful AUTH for password mode; both messages stayed local")
        finally:
            fixture.shutdown()
            worker.join(timeout=2)
