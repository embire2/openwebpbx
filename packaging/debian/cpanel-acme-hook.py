#!/usr/bin/env python3
"""Certbot manual HTTP/DNS hooks. Root-only configuration; credentials never enter the web tree."""
import hashlib
import json
import os
import re
import subprocess
import sys
import time
import urllib.parse
import urllib.request
from pathlib import Path

CONFIG = Path('/etc/openwebpbx/cpanel-acme.json')
STATE = Path('/var/lib/openwebpbx/acme-cpanel')


def configuration():
    if os.geteuid() != 0 or CONFIG.is_symlink():
        raise ValueError('A root-owned private DNS configuration is required.')
    status = CONFIG.stat()
    if status.st_uid != 0 or status.st_mode & 0o077:
        raise ValueError('The DNS configuration must be accessible only to root.')
    settings = json.loads(CONFIG.read_text())
    endpoint = urllib.parse.urlparse(settings['endpoint'])
    if endpoint.scheme != 'https' or not endpoint.hostname or endpoint.username or endpoint.password or endpoint.query or endpoint.fragment:
        raise ValueError('Use the trusted HTTPS cPanel endpoint.')
    return settings


def api(settings, operation, **values):
    parameters = dict(cpanel_jsonapi_user=settings['username'], cpanel_jsonapi_apiversion=2,
                      cpanel_jsonapi_module='ZoneEdit', cpanel_jsonapi_func=operation, **values)
    request = urllib.request.Request(settings['endpoint'].rstrip('/') + '/json-api/cpanel?' + urllib.parse.urlencode(parameters),
                                     headers={'Authorization': 'cpanel ' + settings['username'] + ':' + settings['token']})
    with urllib.request.urlopen(request, timeout=15) as response:
        result = json.load(response)['cpanelresult']
    if result.get('error') or result.get('event', {}).get('result') != 1:
        raise RuntimeError('The DNS operation did not succeed.')
    return result.get('data', [])


def matching(rows, name, validation):
    return [row for row in rows if row.get('type') == 'TXT' and row.get('name', '').rstrip('.').lower() == name
            and row.get('txtdata', '').strip('"') == validation]


def run(action):
    settings = configuration()
    domain = os.environ['CERTBOT_DOMAIN'].removeprefix('*.').lower()
    validation = os.environ['CERTBOT_VALIDATION']
    token = os.environ.get('CERTBOT_TOKEN', '')
    if action not in ('auth', 'cleanup') or not re.fullmatch(r'[A-Za-z0-9_-]{20,200}(?:\.[A-Za-z0-9_-]{20,200})?', validation):
        raise ValueError('Invalid certificate challenge.')
    if token:
        if domain not in settings.get('http_domains', []) or not re.fullmatch(r'[A-Za-z0-9_-]{20,200}', token):
            raise ValueError('This HTTP challenge is outside the configured domains.')
        folder = Path(settings['webroot']) / '.well-known/acme-challenge'
        for parent in [folder, *folder.parents]:
            if parent.is_symlink():
                raise ValueError('The challenge path must not contain symbolic links.')
        folder.mkdir(parents=True, exist_ok=True)
        target = folder / token
        if target.is_symlink():
            raise ValueError('The challenge file must not be a symbolic link.')
        if action == 'auth':
            if target.exists() and target.read_text() != validation:
                raise ValueError('Another HTTP challenge owns this file.')
            target.write_text(validation)
            target.chmod(0o644)
        elif target.is_file() and target.read_text() == validation:
            target.unlink()
        return
    if domain not in settings.get('dns_domains', []) or not domain.endswith('.' + settings['zone']):
        raise ValueError('This DNS challenge is outside the configured namespace.')
    name = '_acme-challenge.' + domain
    STATE.mkdir(parents=True, exist_ok=True, mode=0o700)
    if STATE.is_symlink() or STATE.stat().st_uid != 0 or STATE.stat().st_mode & 0o077:
        raise ValueError('Private DNS challenge storage is required.')
    record = STATE / (hashlib.sha256((name + '\0' + validation).encode()).hexdigest() + '.json')
    if record.is_symlink():
        raise ValueError('The DNS ownership record must not be a symbolic link.')
    rows = api(settings, 'fetchzone_records', domain=settings['zone'])
    current = matching(rows, name, validation)
    if action == 'cleanup':
        if record.is_file() and json.loads(record.read_text()).get('created'):
            for row in current:
                api(settings, 'remove_zone_record', domain=settings['zone'], line=row['line'])
        record.unlink(missing_ok=True)
        return
    if not current:
        api(settings, 'add_zone_record', domain=settings['zone'], name=name + '.', type='TXT', txtdata=validation, ttl=300, **{'class': 'IN'})
        current = matching(api(settings, 'fetchzone_records', domain=settings['zone']), name, validation)
        if len(current) != 1:
            raise RuntimeError('The created DNS challenge could not be verified.')
        record.write_text(json.dumps({'created': True, 'name': name}))
        record.chmod(0o600)
    elif not record.exists():
        record.write_text(json.dumps({'created': False, 'name': name}))
        record.chmod(0o600)
    deadline = time.monotonic() + 50
    while time.monotonic() < deadline:
        results = [subprocess.run(['dig', '+short', '+time=2', '+tries=1', '@' + server, name, 'TXT'],
                                  capture_output=True, text=True, timeout=5) for server in settings['nameservers']]
        if results and all(result.returncode == 0 and validation in [line.strip('"') for line in result.stdout.splitlines()] for result in results):
            return
        time.sleep(2)
    raise RuntimeError('The DNS challenge is not yet visible on every configured nameserver.')


if __name__ == '__main__':
    try:
        run(sys.argv[1])
    except Exception as error:
        # Exception strings may contain URLs/private provider responses; expose only their type.
        print('Certificate challenge failed (' + type(error).__name__ + '). Check the private DNS configuration.', file=sys.stderr)
        raise SystemExit(1)
