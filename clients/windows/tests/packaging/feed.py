#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-or-later
"""Two public development-package resources, bound only to this disposable loopback."""
import http.server
import json
import os
from pathlib import Path
import re
import sys


def main():
    if sys.platform != 'win32' or os.environ.get('GITHUB_ACTIONS') != 'true' or os.environ.get('RUNNER_ENVIRONMENT') != 'github-hosted' or os.environ.get('GITHUB_REPOSITORY') != 'embire2/openwebpbx':
        raise RuntimeError('A disposable Windows runner is required.')
    if len(sys.argv) != 2:
        raise ValueError('One owned root is required.')
    root = Path(sys.argv[1]).resolve(strict=True)
    if root.parent != Path(os.environ['RUNNER_TEMP']).resolve(strict=True) or not re.fullmatch(r'phone-package-[a-f0-9]{32}', root.name):
        raise ValueError('Owned package root differs.')

    class Handler(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            name = {'/catalogue': 'catalogue.json', '/package': 'update.msixbundle'}.get(self.path)
            if name is None:
                self.send_error(404)
                return
            path = root / name
            if path.is_symlink() or not path.is_file():
                self.send_error(404)
                return
            with path.open('rb') as source:
                self.send_response(200)
                self.send_header('Content-Type', 'application/octet-stream')
                self.send_header('Content-Length', str(os.fstat(source.fileno()).st_size))
                self.end_headers()
                while chunk := source.read(65536):
                    self.wfile.write(chunk)

        def log_message(self, *_):
            pass

    server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
    with (root / 'feed-ready.json').open('x', encoding='utf-8') as output:
        json.dump({'schema': 1, 'pid': os.getpid(), 'port': server.server_port}, output)
        output.flush()
        os.fsync(output.fileno())
    try:
        server.serve_forever()
    finally:
        server.server_close()


if __name__ == '__main__':
    main()
