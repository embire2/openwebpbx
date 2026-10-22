#!/usr/bin/env python3
"""Two actual health notifications through the global queue and loopback SMTP only."""
from email.parser import BytesParser
from email.policy import default
from pathlib import Path
import socketserver
import subprocess
import threading
from smtp_transport_integration import SMTPFixture


if __name__ == '__main__':
    with socketserver.ThreadingTCPServer(('127.0.0.1', 0), SMTPFixture) as fixture:
        fixture.deliveries = []
        fixture.connections = []
        fixture.envelopes = []
        fixture.record_lock = threading.Lock()
        fixture.daemon_threads = True
        thread = threading.Thread(target=fixture.serve_forever, daemon=True)
        thread.start()
        try:
            subprocess.run(['php', str(Path(__file__).with_suffix('.php')), str(fixture.server_address[1])],
                           cwd=Path(__file__).resolve().parents[1], check=True, timeout=90)
            assert len(fixture.deliveries) == 2
            subjects = []
            for _, raw in fixture.deliveries:
                mail = BytesParser(policy=default).parsebytes(raw)
                assert mail['From'].addresses[0].addr_spec == 'health-system@example.invalid'
                assert mail['Reply-To'].addresses[0].addr_spec == 'health-reply@example.invalid'
                assert mail['To'].addresses[0].addr_spec == 'current-owner@example.invalid'
                assert b'PRIVATE_' not in raw and b'attacker@' not in raw
                subjects.append(str(mail['Subject']))
            assert any('Recovered:' in subject for subject in subjects)
            assert fixture.connections == [(False, 0), (False, 0)]
            assert fixture.envelopes == ['MAIL FROM:<health-system@example.invalid>'] * 2
            print('PASS: actual global sender/reply-to/owner recipient, no AUTH, private metadata omitted, recovered notice')
        finally:
            fixture.shutdown()
            thread.join(timeout=2)
