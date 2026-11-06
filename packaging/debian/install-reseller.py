#!/usr/bin/env python3
"""Stage Debian reseller API and recovery jobs, retaining administrator task choices."""
import argparse
import os
from pathlib import Path
import re
import subprocess
import tempfile

PACKAGE = Path(__file__).resolve().parent
TOOLS = Path('/opt/openwebpbx/tools')
UNIT = Path('/etc/systemd/system/openwebpbx-protection.service')
TIMER = Path('/etc/systemd/system/openwebpbx-protection.timer')
POOL = Path('/etc/php/8.4/fpm/pool.d/openwebpbx-uploads.conf')
LINKS = [Path('/etc/systemd/system/timers.target.wants/openwebpbx-protection.timer'),
         Path('/etc/systemd/system/openwebpbx-updater.service.wants/openwebpbx-protection.timer')]
PROGRAMS = ('protection.py', 'install-reseller.py', 'openwebpbx-protection.service', 'openwebpbx-protection.timer', 'openwebpbx-uploads.pool.conf')
SITES = (Path('/etc/nginx/sites-available/openwebpbx'), Path('/etc/nginx/sites-available/openweb-call.conf'))
MAINTENANCE = Path('/var/lib/openwebpbx/updates/maintenance')
INBOX = Path('/var/lib/openwebpbx/protection-inbox')
API = ''' location ^~ /api/v2/ {
  location ~ "^/api/v2/(?:instance|tenants/[a-f0-9-]{36})/backups/import$" {
   include fastcgi_params;
   fastcgi_param SCRIPT_FILENAME /var/www/fusionpbx/api/v2/index.php;
   fastcgi_param SCRIPT_NAME /api/v2/index.php;
   fastcgi_param HTTP_AUTHORIZATION $http_authorization;
   fastcgi_pass unix:/run/php/openwebpbx-uploads.sock;
   set $openweb_upload_method $request_method;
   set $openweb_upload_length $content_length;
   set $openweb_upload_type $content_type;
   set $openweb_upload_uri $request_uri;
   auth_request /_openwebpbx/upload-authorize;
   error_page 401 = @openweb_upload_unauthorized;
   error_page 403 = @openweb_upload_forbidden;
   fastcgi_request_buffering off;
   fastcgi_read_timeout 900s;
   client_max_body_size 2049m;
  }
  include fastcgi_params;
  fastcgi_param SCRIPT_FILENAME /var/www/fusionpbx/api/v2/index.php;
  fastcgi_param SCRIPT_NAME /api/v2/index.php;
  fastcgi_param HTTP_AUTHORIZATION $http_authorization;
  fastcgi_pass unix:/run/php/php8.4-fpm.sock;
  fastcgi_read_timeout 90s;
  client_max_body_size 34m;
 }
 location = /app/pbx_protection/upload.php {
  include fastcgi_params;
  fastcgi_param SCRIPT_FILENAME /var/www/fusionpbx/app/pbx_protection/upload.php;
  fastcgi_pass unix:/run/php/openwebpbx-uploads.sock;
  set $openweb_upload_method $request_method;
  set $openweb_upload_length $content_length;
  set $openweb_upload_type $content_type;
  set $openweb_upload_uri $request_uri;
  auth_request /_openwebpbx/upload-authorize;
  error_page 401 = @openweb_upload_unauthorized;
  error_page 403 = @openweb_upload_forbidden;
  fastcgi_request_buffering off;
  fastcgi_read_timeout 900s;
  client_max_body_size 2049m;
 }
 location = /_openwebpbx/upload-authorize {
  internal;
  include fastcgi_params;
  fastcgi_param SCRIPT_FILENAME /var/www/fusionpbx/app/pbx_protection/upload_gate.php;
  fastcgi_param SCRIPT_NAME /app/pbx_protection/upload_gate.php;
  fastcgi_param REQUEST_METHOD GET;
  fastcgi_param CONTENT_LENGTH "";
  fastcgi_param CONTENT_TYPE $openweb_upload_type;
  fastcgi_param HTTP_AUTHORIZATION $http_authorization;
  fastcgi_param OPENWEB_UPLOAD_GATE 1;
  fastcgi_param OPENWEB_UPLOAD_METHOD $openweb_upload_method;
  fastcgi_param OPENWEB_UPLOAD_LENGTH $openweb_upload_length;
  fastcgi_param OPENWEB_UPLOAD_URI $openweb_upload_uri;
  fastcgi_pass_request_body off;
  fastcgi_pass unix:/run/php/openwebpbx-uploads.sock;
 }
 location = /app/pbx_protection/upload_gate.php { return 404; }
 location @openweb_upload_unauthorized {
  default_type application/json;
  return 401 '{"error":{"code":"upload_sign_in","message":"Sign in again or send a valid API key."},"request_id":"$request_id"}';
 }
 location @openweb_upload_forbidden {
  default_type application/json;
  return 403 '{"error":{"code":"upload_refused","message":"Upload refused. Check access, backup password, file size and available storage."},"request_id":"$request_id"}';
 }
'''


def ordinary(path):
    for item in (path, *path.parents):
        if item.is_symlink():
            raise ValueError('Review linked reseller installation paths.')
    if path.exists() and not path.is_file():
        raise ValueError('Reseller installation requires ordinary files.')


def site_content():
    site = SITES[0]
    if not site.exists():
        site = SITES[1]
    ordinary(site)
    if not site.exists():
        if os.environ.get('OPENWEB_FRESH_INSTALL') == '1':
            return site, None
        raise ValueError('Review the installation HTTPS site before adding the API.')
    text = site.read_text()
    if '/api/v2/' in text:
        if text.count(API) != 1:
            raise ValueError('Preserve and review the existing custom API configuration.')
        return site, text
    active = re.sub(r'(?m)^\s*#.*$', '', text)
    roots = list(re.finditer(r'(?m)^[ \t]*root[ \t]+/var/www/fusionpbx;[ \t]*$', text))
    if len(re.findall(r'(?m)^\s*listen\s+443\s+ssl', active)) != 1:
        raise ValueError('Review the installation HTTPS site before adding the API.')
    # Existing hosted installations have a public front controller and a
    # server-level legacy API rewrite. Add a sibling location before that
    # exact known rewrite, and exempt both versioned APIs from it.
    legacy = 'if ($uri ~* "^(?!/api/v1/).*/api/.*$")'
    if legacy in text:
        if text.count(legacy) != 1 or len(re.findall(r'(?m)^\s*root\s+/var/www/fusionpbx/public;', active)) != 1:
            raise ValueError('Review the legacy API front controller before adding the API.')
        line = text.rfind('\n', 0, text.index(legacy)) + 1
        return site, text[:line] + API + text[line:].replace(legacy, 'if ($uri ~* "^(?!/api/v[12]/).*/api/.*$")', 1)
    if len(roots) != 1:
        raise ValueError('Review the installation HTTPS site before adding the API.')
    at = roots[0].end()
    return site, text[:at] + '\n' + API + text[at:]


def targets():
    site, _ = site_content()
    return [site, UNIT, TIMER, POOL, *[TOOLS / n for n in PROGRAMS],
            *[p for p in LINKS if not p.exists() and not p.is_symlink()]]


def write(path, data):
    ordinary(path)
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o755)
    with tempfile.NamedTemporaryFile(dir=path.parent, prefix='.reseller-', delete=False) as stream:
        staged = Path(stream.name)
        try:
            stream.write(data); stream.flush(); os.fsync(stream.fileno())
            os.fchmod(stream.fileno(), 0o644)
            os.replace(staged, path)
        finally:
            staged.unlink(missing_ok=True)


def ensure_upload_inbox():
    for path in (INBOX, *INBOX.parents):
        if path.is_symlink():
            raise ValueError('Review the linked encrypted-upload location.')
    if not INBOX.exists():
        INBOX.mkdir(mode=0o730)
        os.chown(INBOX, 0, 33)
        os.chmod(INBOX, 0o730)
    info = INBOX.stat()
    if not INBOX.is_dir() or info.st_uid != 0 or info.st_gid != 33 or info.st_mode & 0o777 != 0o730:
        raise ValueError('The encrypted-upload location needs its owner to review permissions.')


def install(activate=False):
    if os.geteuid() != 0:
        raise ValueError('Run the installation helper as root.')
    site, text = site_content()
    existed = TIMER.exists()
    previous_pool = POOL.read_bytes() if POOL.exists() else None
    # Validate all inputs before changing the proxy or job definitions.
    inputs = [(TOOLS / n, PACKAGE / n) for n in PROGRAMS] + [(UNIT, PACKAGE / UNIT.name), (TIMER, PACKAGE / TIMER.name), (POOL, PACKAGE / 'openwebpbx-uploads.pool.conf')]
    for target, source in inputs:
        ordinary(source)
        if not source.is_file():
            raise ValueError('Use the complete corresponding Debian package.')
        ordinary(target)
        if target in (UNIT, TIMER, POOL) and target.exists() and target.read_bytes() != source.read_bytes():
            raise ValueError('Preserve and review the custom recovery task before continuing.')
    ensure_upload_inbox()
    for target, source in inputs:
        write(target, source.read_bytes())
    try:
        subprocess.run(['php-fpm8.4', '-t'], check=True, timeout=30)
    except BaseException:
        if previous_pool is None:
            POOL.unlink(missing_ok=True)
        else:
            write(POOL, previous_pool)
        raise
    if text is not None:
        previous = site.read_bytes()
        if previous != text.encode():
            write(site, text.encode())
            try:
                subprocess.run(['nginx', '-t'], check=True, timeout=30)
            except BaseException:
                write(site, previous)
                raise
    subprocess.run(['systemctl', 'daemon-reload'], check=True, timeout=30)
    state = subprocess.run(['systemctl', 'is-enabled', TIMER.name], capture_output=True, text=True, timeout=30).stdout.strip()
    if state not in ('enabled', 'enabled-runtime', 'disabled', 'masked', 'masked-runtime', 'static', 'indirect'):
        raise ValueError('Review recovery job enablement before continuing.')
    # Initial installation creates a wanted link; custom disabled/masked existing
    # tasks are preserved. No pending job starts during an upgrade migration.
    if not existed and state == 'disabled':
        subprocess.run(['systemctl', 'enable', TIMER.name], check=True, timeout=30)
    if activate:
        if MAINTENANCE.exists():
            raise ValueError('Finish update recovery before starting recovery jobs.')
        subprocess.run(['nginx', '-t'], check=True, timeout=30)
        subprocess.run(['systemctl', 'reload', 'php8.4-fpm'], check=True, timeout=30)
        subprocess.run(['systemctl', 'reload', 'nginx'], check=True, timeout=30)
        if not existed or state in ('enabled', 'enabled-runtime'):
            subprocess.run(['systemctl', 'start', TIMER.name], check=True, timeout=30)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--activate', action='store_true')
    install(parser.parse_args().activate)
