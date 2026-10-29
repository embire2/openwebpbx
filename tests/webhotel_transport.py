#!/usr/bin/env python3
"""Actual loopback TLS: IPv4 resolution, SNI, trusted hostname checks and redirect refusal."""
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import importlib.util
import json
from pathlib import Path
import socket
import ssl
import subprocess
import tempfile
import threading
import urllib.error
import urllib.request
from unittest.mock import patch

root = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('onboarding_transport', root/'packaging/debian/webhotel-onboarding.py')
m = importlib.util.module_from_spec(spec);spec.loader.exec_module(m)
with tempfile.TemporaryDirectory(prefix='openweb-image-tls-') as temporary:
    directory = Path(temporary)
    key, certificate = directory/'key.pem', directory/'cert.pem'
    subprocess.run(['openssl','req','-x509','-newkey','rsa:2048','-nodes','-days','1','-subj','/CN=localhost',
                    '-addext','subjectAltName=DNS:localhost','-keyout',str(key),'-out',str(certificate)], check=True, capture_output=True)
    requests = [];names = [];families = []
    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *args):
            pass
        def do_GET(self):
            requests.append(self.path)
            if self.path == '/redirect':
                self.send_response(302);self.send_header('Location','/must-not-follow');self.end_headers();return
            self.send_response(200);self.send_header('Content-Type','application/json');self.end_headers();self.wfile.write(b'{"verified":true}')
    server = ThreadingHTTPServer(('127.0.0.1',0),Handler)
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER);context.load_cert_chain(certificate,key)
    context.sni_callback = lambda stream, name, ctx: names.append(name)
    server.socket = context.wrap_socket(server.socket,server_side=True)
    thread = threading.Thread(target=server.serve_forever,daemon=True);thread.start()
    original = socket.getaddrinfo
    def addresses(host, port, family=0, *args, **kwargs):
        families.append(family)
        return original(host,port,family,*args,**kwargs)
    trusted = ssl.create_default_context(cafile=str(certificate))
    transport = urllib.request.build_opener(urllib.request.ProxyHandler({}),m.NoRedirect(),m.IPv4HTTPSHandler(context=trusted))
    base = 'https://localhost:'+str(server.server_port)
    count = 0
    try:
        with patch.object(socket,'getaddrinfo',side_effect=addresses):
            with transport.open(base+'/ok',timeout=3) as response:
                assert json.load(response) == {'verified':True};count += 1
            assert families and all(family == socket.AF_INET for family in families);count += 1
            assert names == ['localhost'];count += 1
            try:
                transport.open(base+'/redirect',timeout=3)
                raise AssertionError('Followed an onboarding redirect')
            except urllib.error.HTTPError as error:
                assert error.code == 302;count += 1
            assert '/must-not-follow' not in requests;count += 1
            # Same trusted certificate with the wrong hostname must still fail.
            try:
                transport.open('https://127.0.0.1:'+str(server.server_port)+'/wrong-name',timeout=3)
                raise AssertionError('Accepted a wrong TLS hostname')
            except urllib.error.URLError as error:
                assert isinstance(error.reason,ssl.SSLCertVerificationError);count += 1
            untrusted = urllib.request.build_opener(urllib.request.ProxyHandler({}),m.NoRedirect(),m.IPv4HTTPSHandler(context=ssl.create_default_context()))
            try:
                untrusted.open(base+'/wrong-ca',timeout=3)
                raise AssertionError('Accepted an untrusted TLS certificate')
            except urllib.error.URLError as error:
                assert isinstance(error.reason,ssl.SSLCertVerificationError);count += 1
        print(json.dumps({'passed':count,'scope':'Actual owned loopback TLS; IPv4-only resolution, SNI and strict CA/hostname validation; no public transport claim'}))
    finally:
        server.shutdown();server.server_close();thread.join(timeout=3)
